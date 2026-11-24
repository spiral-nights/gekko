import emit/moonbit
import emit/pkg_config
import emit/prelude_runtime
import emit/trait_bounds
import filepath
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import index/symbol_table
import lower/desugar
import lower/mangle
import lower/tco
import lower/validate
import moonbit/ffi_meta
import project/cmd
import project/diagnostics
import project/ffi_config
import project/interface.{type PackageInterface, PackageInterface}
import project/loader.{type LoadedDependency}
import project/moonbit_ffi
import project/prepass.{type PrepassResult}
import project/staging
import simplifile
import tom

/// Summary returned after transpiling a Gleam project into a MoonBit workspace.
pub type TranspileSummary {
  TranspileSummary(
    project_name: String,
    version: String,
    out_dir: String,
    emitted_modules: List(String),
    local_moonbit_packages: List(String),
    module_pkg_dirs: Dict(String, String),
    warnings: List(String),
  )
}

/// Transpile a Gleam project at `project_root` (including `test/` modules) into
/// a complete MoonBit workspace at `out_dir`.
pub fn transpile_project(
  project_root: String,
  out_dir: String,
) -> Result(TranspileSummary, String) {
  transpile_project_with_tests(project_root, out_dir, True)
}

/// Transpile a Gleam project at `project_root` into a complete MoonBit workspace
/// at `out_dir`, optionally including `test/` modules.
pub fn transpile_project_with_tests(
  project_root: String,
  out_dir: String,
  include_tests: Bool,
) -> Result(TranspileSummary, String) {
  use #(project_name, version) <- result.try(loader.read_project_meta(
    project_root,
  ))
  use _ <- result.try(ensure_deps_downloaded(project_root, include_tests))
  use packages_hash <- result.try(staging.compute_packages_dir_hash(
    project_root,
  ))
  use discovered_deps <- result.try(loader.discover_all_dependencies(
    project_root,
    include_tests,
  ))
  use dep_overlays <- result.try(
    list.try_map(discovered_deps, fn(dep) {
      ffi_config.load_package_overlay(dep.package_root, dep.package_name)
    }),
  )
  use root_overlay <- result.try(ffi_config.load_package_overlay(
    project_root,
    project_name,
  ))
  use overlays <- result.try(ffi_config.merge_overlays(
    dep_overlays,
    root_overlay,
  ))
  let discovered_versions =
    list.fold(
      discovered_deps,
      dict.from_list([#(project_name, version)]),
      fn(acc, dep) { dict.insert(acc, dep.package_name, dep.version) },
    )
  use version_warnings <- result.try(ffi_config.check_shim_versions(
    overlays.shims,
    discovered_versions,
  ))
  let auth_warnings =
    ffi_config.check_authorized_shims(
      overlays.authorized_shims,
      discovered_versions,
    )
  let version_warnings = list.append(version_warnings, auth_warnings)
  use root_moonbit_deps <- result.try(ffi_config.load_project_moonbit_deps(
    project_root,
  ))
  use loaded_deps <- result.try(loader.load_discovered_dependencies(
    project_root,
    discovered_deps,
    overlays.overrides,
    overlays.target_branches,
    Some(packages_hash),
  ))
  use dep_moonbit_deps <- result.try(
    list.try_map(loaded_deps, fn(dep) {
      ffi_config.load_project_moonbit_deps(dep.package_root)
    }),
  )
  let moonbit_deps =
    list.flatten(dep_moonbit_deps)
    |> list.append(root_moonbit_deps)
    |> list.fold(dict.new(), fn(acc, entry) {
      dict.insert(acc, entry.0, entry.1)
    })
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })

  let staging_dir = filepath.join(project_root, "build/.gekko_staging")
  use root_iface <- result.try(
    staging.extract_project_interface_with_packages_hash(
      project_root,
      staging_dir,
      include_tests,
      Some(packages_hash),
    ),
  )
  let merged_iface = merge_package_interfaces(root_iface, loaded_deps)

  let src_dir = filepath.join(project_root, "src")
  use src_modules <- result.try(loader.discover_and_parse(src_dir, None))

  let test_dir = filepath.join(project_root, "test")
  use test_modules <- result.try(
    case include_tests, simplifile.is_directory(test_dir) {
      True, Ok(True) -> {
        use parsed <- result.try(loader.discover_and_parse(
          test_dir,
          Some("test"),
        ))
        Ok(list.map(parsed, strip_gleeunit_harness))
      }
      _, _ -> Ok([])
    },
  )

  let dep_tagged =
    list.flat_map(loaded_deps, fn(dep) {
      list.map(dep.modules, fn(entry) {
        let #(mod_name, ast_mod, pre) = entry
        #(dep.package_name, mod_name, ast_mod, pre)
      })
    })
  let root_tagged =
    list.append(src_modules, test_modules)
    |> list.map(fn(entry) {
      let #(mod_name, ast_mod, pre) = entry
      #(project_name, mod_name, ast_mod, pre)
    })
  let all_modules = list.append(dep_tagged, root_tagged)

  let ffi_roots =
    list.append(list.map(loaded_deps, fn(dep) { dep.package_root }), [
      project_root,
    ])
  let base_ffi_metadata =
    ffi_meta.scan_package_roots_excluding(
      ffi_roots,
      overlays.patched_source_files,
    )
  use ffi_metadata <- result.try(scan_patched_metadata(
    base_ffi_metadata,
    all_modules,
    overlays.module_patches,
  ))

  let table =
    symbol_table.index_project_with_overlays(
      project_name,
      all_modules,
      Some(merged_iface),
      overlays.overrides,
      overlays.type_overrides,
      overlays.target_branches,
      ffi_metadata,
    )
  let stale_warnings =
    detect_stale_overlay_warnings(
      overlays,
      all_modules,
      table,
      discovered_versions,
    )

  use _ <- result.try(validate_all_int_literals(all_modules, table))

  let resolved_pkg_dirs =
    all_modules
    |> list.map(fn(entry) { entry.1 })
    |> pkg_config.resolve_module_pkg_dirs

  use _ <- result.try(
    simplifile.create_directory_all(out_dir)
    |> result.map_error(fn(err) {
      "Failed to create output workspace "
      <> out_dir
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )

  use _ <- result.try(write_text_file(
    filepath.join(out_dir, "moon.mod"),
    pkg_config.emit_moon_mod_with_deps(project_name, version, moonbit_deps),
  ))

  let gprelude_dir = filepath.join(out_dir, "gprelude")
  use _ <- result.try(write_text_file(
    filepath.join(gprelude_dir, "moon.pkg"),
    prelude_runtime.moon_pkg(),
  ))
  use _ <- result.try(write_text_file(
    filepath.join(gprelude_dir, "gprelude.mbt"),
    prelude_runtime.gprelude_mbt(),
  ))

  let module_pkg_dirs =
    list.map(all_modules, fn(entry) {
      dict.get(resolved_pkg_dirs, entry.1)
      |> result.unwrap(pkg_config.module_to_pkg_dir(entry.1))
    })
  let base_reserved =
    ["gprelude", ..module_pkg_dirs]
    |> set.from_list

  use #(copied_dep_pkgs, reserved_after_deps) <- result.try(
    list.try_fold(loaded_deps, #([], base_reserved), fn(acc, dep) {
      let #(pkgs_acc, cur_reserved) = acc
      use dep_pkgs <- result.try(
        moonbit_ffi.copy_local_packages_for_package_excluding(
          dep.package_root,
          dep.package_name,
          project_name,
          out_dir,
          cur_reserved,
          overlays.patched_source_files,
        ),
      )
      let next_reserved = list.fold(dep_pkgs, cur_reserved, set.insert)
      Ok(#(list.append(pkgs_acc, dep_pkgs), next_reserved))
    }),
  )

  use root_moonbit_packages <- result.try(
    moonbit_ffi.copy_local_packages_for_package_excluding(
      project_root,
      project_name,
      project_name,
      out_dir,
      reserved_after_deps,
      overlays.patched_source_files,
    ),
  )
  let local_moonbit_packages =
    list.append(copied_dep_pkgs, root_moonbit_packages)
    |> list.sort(string.compare)
  let local_pkg_set = set.from_list(local_moonbit_packages)

  let ir_modules =
    list.map(all_modules, fn(entry) {
      let #(_, mod_name, ast_mod, _) = entry
      desugar.desugar_module(ast_mod, table, mod_name)
      |> tco.optimize_module
    })

  let project_bounds =
    trait_bounds.analyze_project(ir_modules, Some(table), ffi_metadata)

  let module_meta_by_name =
    list.fold(all_modules, dict.new(), fn(acc, entry) {
      let #(pkg_name, mod_name, ast_mod, pre) = entry
      dict.insert(acc, mod_name, #(pkg_name, ast_mod, pre.cleaned_source))
    })

  use #(rev_emitted, rev_origins) <- result.try(
    list.try_fold(ir_modules, #([], []), fn(acc, ir_mod) {
      let #(names_acc, origins_acc) = acc
      let mod_name = ir_mod.module_name
      let #(mbt_src, imports) =
        moonbit.emit_module_with_pkg_dirs(
          ir_mod,
          Some(table),
          ffi_metadata,
          project_bounds,
          resolved_pkg_dirs,
        )
      let is_main = moonbit.module_has_main(ir_mod)
      let pkg_dir =
        dict.get(resolved_pkg_dirs, mod_name)
        |> result.unwrap(pkg_config.module_to_pkg_dir(mod_name))
      let target_dir = filepath.join(out_dir, pkg_dir)
      let mbt_rel = pkg_dir <> "/" <> pkg_dir <> ".mbt"

      let mod_pkg_name = case dict.get(module_meta_by_name, mod_name) {
        Ok(#(pn, _, _)) -> pn
        Error(_) -> project_name
      }
      let mod_patches =
        lookup_module_patches(mod_pkg_name, mod_name, overlays.module_patches)
      use merged_imports <- result.try(merge_patch_imports(
        mod_name,
        imports,
        mod_patches,
        resolved_pkg_dirs,
      ))

      use _ <- result.try(write_text_file(
        filepath.join(target_dir, "moon.pkg"),
        pkg_config.emit_moon_pkg_with_local_pkgs(
          project_name,
          merged_imports,
          is_main,
          local_pkg_set,
        ),
      ))
      use _ <- result.try(write_text_file(
        filepath.join(target_dir, pkg_dir <> ".mbt"),
        mbt_src,
      ))
      use _ <- result.try(sync_patched_files(target_dir, mod_patches))
      let mod_origins = case dict.get(module_meta_by_name, mod_name) {
        Ok(#(pkg_name, ast_mod, gleam_src)) ->
          diagnostics.collect_module_origins(
            project_name,
            pkg_name,
            mod_name,
            ast_mod,
            gleam_src,
            mbt_rel,
            mbt_src,
          )
        Error(_) -> []
      }
      Ok(#(
        [mod_name, ..names_acc],
        list.append(list.reverse(mod_origins), origins_acc),
      ))
    }),
  )

  use _ <- result.try(write_text_file(
    filepath.join(out_dir, diagnostics.sourcemap_filename),
    diagnostics.format_sourcemap(list.reverse(rev_origins)),
  ))

  let local_top_dirs =
    list.map(local_moonbit_packages, fn(pkg) {
      case string.split_once(pkg, "/") {
        Ok(#(top, _)) -> top
        Error(_) -> pkg
      }
    })
  let new_generated_dirs =
    list.append(module_pkg_dirs, local_top_dirs)
    |> list.filter(fn(d) { d != "" && d != "gprelude" })
    |> set.from_list
    |> set.to_list
    |> list.sort(string.compare)

  use _ <- result.try(clean_stale_generated_dirs(
    out_dir,
    new_generated_dirs,
    include_tests,
  ))

  use _ <- result.try(sync_moonbit_lsp_workspace(project_root))

  Ok(TranspileSummary(
    project_name:,
    version:,
    out_dir:,
    emitted_modules: list.reverse(rev_emitted),
    local_moonbit_packages:,
    module_pkg_dirs: resolved_pkg_dirs,
    warnings: list.append(version_warnings, stale_warnings),
  ))
}

fn clean_stale_generated_dirs(
  out_dir: String,
  new_generated_dirs: List(String),
  include_tests: Bool,
) -> Result(Nil, String) {
  let manifest_path = filepath.join(out_dir, ".gekko_generated")
  let from_manifest = case simplifile.read(from: manifest_path) {
    Ok(content) ->
      content
      |> string.split("\n")
      |> list.map(string.trim)
      |> list.filter(fn(line) { line != "" })
    Error(_) -> []
  }

  let legacy_test_dirs = case include_tests {
    True -> []
    False ->
      case simplifile.read_directory(at: out_dir) {
        Ok(entries) ->
          list.filter(entries, fn(entry) {
            case string.starts_with(entry, "test_") {
              False -> False
              True -> {
                let entry_dir = filepath.join(out_dir, entry)
                let pkg_file = filepath.join(entry_dir, "moon.pkg")
                simplifile.is_directory(entry_dir) == Ok(True)
                && simplifile.is_file(pkg_file) == Ok(True)
              }
            }
          })
        Error(_) -> []
      }
  }

  let protected =
    [
      "", ".", "..", "_build", ".mooncakes", "gprelude", ".gekko_generated",
      diagnostics.sourcemap_filename,
    ]
    |> set.from_list
  let keep = set.union(protected, set.from_list(new_generated_dirs))

  let stale =
    list.append(from_manifest, legacy_test_dirs)
    |> set.from_list
    |> set.to_list
    |> list.filter(fn(dir) { !set.contains(keep, dir) })

  use _ <- result.try(
    list.try_each(stale, fn(dir) {
      let path = filepath.join(out_dir, dir)
      case simplifile.is_directory(path) {
        Ok(True) ->
          simplifile.delete(file_or_dir_at: path)
          |> result.map_error(fn(err) {
            "Failed to clean stale package directory "
            <> path
            <> ": "
            <> simplifile.describe_error(err)
          })
        _ -> Ok(Nil)
      }
    }),
  )

  let manifest_body = case new_generated_dirs {
    [] -> ""
    _ -> string.join(new_generated_dirs, "\n") <> "\n"
  }
  write_text_file(manifest_path, manifest_body)
}

fn merge_package_interfaces(
  root_iface: PackageInterface,
  loaded_deps: List(LoadedDependency),
) -> PackageInterface {
  let dep_modules =
    list.fold(loaded_deps, dict.new(), fn(acc, dep) {
      case dep.interface {
        Some(iface) -> dict.merge(acc, iface.modules)
        None -> acc
      }
    })
  PackageInterface(
    ..root_iface,
    modules: dict.merge(dep_modules, root_iface.modules),
  )
}

fn strip_gleeunit_harness(
  entry: #(String, glance.Module, PrepassResult),
) -> #(String, glance.Module, PrepassResult) {
  let #(mod_name, mod, pre) = entry
  let has_gleeunit_import =
    list.any(mod.imports, fn(def) { def.definition.module == "gleeunit" })
  case has_gleeunit_import {
    False -> entry
    True -> {
      let filtered_imports =
        list.filter(mod.imports, fn(def) { def.definition.module != "gleeunit" })
      let filtered_functions =
        list.filter(mod.functions, fn(def) {
          let func = def.definition
          case func.name == "main" && func.parameters == [] {
            True -> !calls_gleeunit_main(func.body)
            False -> True
          }
        })
      let cleaned_mod =
        glance.Module(
          ..mod,
          imports: filtered_imports,
          functions: filtered_functions,
        )
      #(mod_name, cleaned_mod, pre)
    }
  }
}

fn calls_gleeunit_main(stmts: List(glance.Statement)) -> Bool {
  case stmts {
    [
      glance.Expression(glance.Call(
        function: glance.FieldAccess(
          container: glance.Variable(name: "gleeunit", ..),
          label: "main",
          ..,
        ),
        ..,
      )),
    ] -> True
    _ -> False
  }
}

fn ensure_deps_downloaded(
  project_root: String,
  include_tests: Bool,
) -> Result(Nil, String) {
  let packages_dir = filepath.join(project_root, "build/packages")
  case simplifile.is_directory(packages_dir) {
    Ok(True) -> Ok(Nil)
    _ -> {
      let toml_path = filepath.join(project_root, "gleam.toml")
      case simplifile.read(toml_path) {
        Error(_) -> Ok(Nil)
        Ok(content) ->
          case tom.parse(content) {
            Error(_) -> Ok(Nil)
            Ok(parsed) -> {
              let has_remote_in = fn(section) {
                case tom.get_table(parsed, [section]) {
                  Error(_) -> False
                  Ok(tbl) ->
                    dict.values(tbl)
                    |> list.any(fn(val) {
                      case val {
                        tom.InlineTable(dep_tbl) | tom.Table(dep_tbl) ->
                          case tom.get_string(dep_tbl, ["path"]) {
                            Ok(_) -> False
                            Error(_) -> True
                          }
                        _ -> True
                      }
                    })
                }
              }
              let needs_download =
                has_remote_in("dependencies")
                || { include_tests && has_remote_in("dev-dependencies") }
              case needs_download {
                False -> Ok(Nil)
                True -> {
                  let res =
                    cmd.run(
                      command: "gleam",
                      args: ["deps", "download"],
                      cwd: project_root,
                    )
                  case res.exit_code {
                    0 -> Ok(Nil)
                    _ ->
                      Error(
                        "`gleam deps download` failed while fetching missing dependencies:\n"
                        <> res.output,
                      )
                  }
                }
              }
            }
          }
      }
    }
  }
}

fn validate_all_int_literals(
  all_modules: List(#(String, String, glance.Module, PrepassResult)),
  table: symbol_table.SymbolTable,
) -> Result(Nil, String) {
  let errors =
    list.filter_map(all_modules, fn(entry) {
      let #(pkg_name, mod_name, ast_mod, _) = entry
      case
        validate.validate_module_int_literals_in_package(
          pkg_name,
          ast_mod,
          table,
          mod_name,
        )
      {
        Ok(Nil) -> Error(Nil)
        Error(err) -> Ok(err)
      }
    })
  case errors {
    [] -> Ok(Nil)
    _ -> Error(string.join(errors, "\n"))
  }
}

fn write_text_file(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.read(from: path) {
    Ok(existing) if existing == contents -> Ok(Nil)
    _ -> {
      let dir = filepath.directory_name(path)
      use _ <- result.try(
        simplifile.create_directory_all(dir)
        |> result.map_error(fn(err) {
          "Failed to create directory "
          <> dir
          <> ": "
          <> simplifile.describe_error(err)
        }),
      )
      simplifile.write(to: path, contents:)
      |> result.map_error(fn(err) {
        "Failed to write " <> path <> ": " <> simplifile.describe_error(err)
      })
    }
  }
}

fn scan_patched_metadata(
  base_meta: ffi_meta.FfiMetadata,
  all_modules: List(#(String, String, glance.Module, PrepassResult)),
  module_patches: Dict(String, ffi_config.ModulePatch),
) -> Result(ffi_meta.FfiMetadata, String) {
  list.try_fold(all_modules, base_meta, fn(meta_acc, entry) {
    let #(pkg_name, mod_name, _, _) = entry
    let patches = lookup_module_patches(pkg_name, mod_name, module_patches)
    list.try_fold(patches, meta_acc, fn(inner_acc, patch) {
      list.try_fold(patch.files, inner_acc, fn(file_acc, f) {
        use content <- result.try(
          simplifile.read(from: f.source_path)
          |> result.map_error(fn(err) {
            "Failed to read patch MoonBit file "
            <> f.source_path
            <> ": "
            <> simplifile.describe_error(err)
          }),
        )
        Ok(ffi_meta.scan_injected_mbt_source(file_acc, mod_name, content))
      })
    })
  })
}

fn lookup_module_patches(
  pkg_name: String,
  mod_name: String,
  module_patches: Dict(String, ffi_config.ModulePatch),
) -> List(ffi_config.ModulePatch) {
  let keys = [
    pkg_name <> ":" <> mod_name,
    pkg_name <> "." <> mod_name,
    mod_name,
  ]
  list.filter_map(keys, fn(k) { dict.get(module_patches, k) })
}

fn is_builtin_alias_only_patch(patch: ffi_config.ModulePatch) -> Bool {
  patch.types == []
  && patch.functions == []
  && patch.imports == []
  && patch.type_aliases != []
  && list.all(patch.type_aliases, fn(ta) {
    let #(ty_name, ext_ty) = ta
    ext_ty.package == "builtin" && ext_ty.type_name == ty_name
  })
}

fn merge_patch_imports(
  mod_name: String,
  base_imports: List(#(String, String)),
  patches: List(ffi_config.ModulePatch),
  resolved_pkg_dirs: Dict(String, String),
) -> Result(List(#(String, String)), String) {
  let active_patches =
    list.filter(patches, fn(p) { !is_builtin_alias_only_patch(p) })
  case active_patches {
    [] -> Ok(base_imports)
    _ -> {
      let alias_to_pkg =
        list.fold(base_imports, dict.new(), fn(acc, entry) {
          dict.insert(acc, entry.1, entry.0)
        })
      let pkg_to_alias =
        list.fold(base_imports, dict.new(), fn(acc, entry) {
          dict.insert(acc, entry.0, entry.1)
        })
      let raw_extra =
        list.flat_map(active_patches, fn(patch) {
          list.map(patch.imports, fn(imp) {
            let pkg_or_dir = case dict.get(resolved_pkg_dirs, imp.package) {
              Ok(mapped) -> mapped
              Error(_) -> imp.package
            }
            #(pkg_or_dir, imp.alias, default_patch_import_alias(imp.package))
          })
        })
      let with_prelude = case dict.has_key(pkg_to_alias, "gprelude") {
        True -> raw_extra
        False -> [#("gprelude", Some("gprelude"), "gprelude"), ..raw_extra]
      }
      use #(_, _, rev_added) <- result.try(
        list.try_fold(
          with_prelude,
          #(alias_to_pkg, pkg_to_alias, []),
          fn(state, triple) {
            let #(a_to_p, p_to_a, added) = state
            let #(pkg, alias_opt, default_alias) = triple
            case dict.get(p_to_a, pkg) {
              Ok(existing_alias) ->
                case alias_opt {
                  None -> Ok(state)
                  Some(requested) if requested == existing_alias -> Ok(state)
                  Some(requested) ->
                    Error(
                      "Patch import alias conflict for package '"
                      <> pkg
                      <> "' in module '"
                      <> mod_name
                      <> "': module already imports it as @"
                      <> existing_alias
                      <> ", cannot also alias as @"
                      <> requested,
                    )
                }
              Error(_) -> {
                let alias = case alias_opt {
                  Some(a) -> a
                  None -> default_alias
                }
                case dict.get(a_to_p, alias) {
                  Ok(existing_pkg) if existing_pkg != pkg ->
                    Error(
                      "Import alias conflict for @"
                      <> alias
                      <> " in module '"
                      <> mod_name
                      <> "': '"
                      <> existing_pkg
                      <> "' vs '"
                      <> pkg
                      <> "' (disambiguate with \""
                      <> pkg
                      <> " as <custom_alias>\")",
                    )
                  _ ->
                    Ok(
                      #(
                        dict.insert(a_to_p, alias, pkg),
                        dict.insert(p_to_a, pkg, alias),
                        [#(pkg, alias), ..added],
                      ),
                    )
                }
              }
            }
          },
        ),
      )
      Ok(list.append(base_imports, list.reverse(rev_added)))
    }
  }
}

fn default_patch_import_alias(raw_package: String) -> String {
  let segment =
    raw_package
    |> string.split("/")
    |> list.filter(fn(s) { s != "" })
    |> list.last
    |> result.unwrap(raw_package)
  mangle.mangle_ident(segment)
}

fn sync_patched_files(
  target_dir: String,
  patches: List(ffi_config.ModulePatch),
) -> Result(Nil, String) {
  let files =
    patches
    |> list.filter(fn(p) { !is_builtin_alias_only_patch(p) })
    |> list.flat_map(fn(patch) { patch.files })
  use written_names <- result.try(
    list.index_fold(files, Ok(set.new()), fn(acc_res, f, idx) {
      use acc <- result.try(acc_res)
      let dest_name =
        "__gekko_patch_" <> int.to_string(idx + 1) <> "_" <> f.dest_filename
      let dest_path = filepath.join(target_dir, dest_name)
      use content <- result.try(
        simplifile.read(from: f.source_path)
        |> result.map_error(fn(err) {
          "Failed to read patch MoonBit file "
          <> f.source_path
          <> ": "
          <> simplifile.describe_error(err)
        }),
      )
      use _ <- result.try(write_text_file(dest_path, content))
      Ok(set.insert(acc, dest_name))
    }),
  )
  case simplifile.read_directory(at: target_dir) {
    Ok(entries) ->
      list.try_each(entries, fn(entry) {
        let is_managed_patch =
          {
            string.starts_with(entry, "__gekko_patch_")
            || string.starts_with(entry, "__gekko_inject_")
          }
          && string.ends_with(entry, ".mbt")
        case is_managed_patch && !set.contains(written_names, entry) {
          True ->
            simplifile.delete(file_or_dir_at: filepath.join(target_dir, entry))
            |> result.map_error(fn(err) {
              "Failed to remove stale patch file "
              <> entry
              <> ": "
              <> simplifile.describe_error(err)
            })
          False -> Ok(Nil)
        }
      })
    Error(_) -> Ok(Nil)
  }
}

fn detect_stale_overlay_warnings(
  overlays: ffi_config.MergedOverlays,
  all_modules: List(#(String, String, glance.Module, PrepassResult)),
  table: symbol_table.SymbolTable,
  discovered_versions: Dict(String, String),
) -> List(String) {
  let missing_shim_targets =
    list.filter_map(overlays.shims, fn(entry) {
      let #(_, meta) = entry
      case dict.has_key(discovered_versions, meta.target) {
        True -> Error(Nil)
        False -> Ok(meta.target)
      }
    })
    |> set.from_list

  let #(fn_keys, type_keys, mod_keys) =
    list.fold(all_modules, #(set.new(), set.new(), set.new()), fn(acc, entry) {
      let #(fns, tys, mods) = acc
      let #(pkg_name, mod_name, _, _) = entry
      let next_mods =
        mods
        |> set.insert(pkg_name <> ":" <> mod_name)
        |> set.insert(pkg_name <> "." <> mod_name)
        |> set.insert(mod_name)
      case dict.get(table.modules, mod_name) {
        Error(_) -> #(fns, tys, next_mods)
        Ok(mod_syms) -> {
          let next_fns =
            dict.fold(mod_syms.functions, fns, fn(s, fn_name, _) {
              s
              |> set.insert(pkg_name <> ":" <> mod_name <> "." <> fn_name)
              |> set.insert(pkg_name <> "." <> mod_name <> "." <> fn_name)
              |> set.insert(mod_name <> "." <> fn_name)
            })
          let next_tys =
            dict.fold(mod_syms.types, tys, fn(s, ty_name, _) {
              s
              |> set.insert(pkg_name <> ":" <> mod_name <> "." <> ty_name)
              |> set.insert(pkg_name <> "." <> mod_name <> "." <> ty_name)
              |> set.insert(mod_name <> "." <> ty_name)
            })
          #(next_fns, next_tys, next_mods)
        }
      }
    })

  let check_keys = fn(
    entries: List(String),
    sources: Dict(String, String),
    known: Set(String),
    kind_label: String,
    entity_label: String,
  ) {
    list.filter_map(list.sort(entries, string.compare), fn(k) {
      case set.contains(known, k) {
        True -> Error(Nil)
        False -> {
          let targets_missing_pkg = case string.split_once(k, ":") {
            Ok(#(pkg, _)) -> set.contains(missing_shim_targets, pkg)
            Error(_) -> False
          }
          case targets_missing_pkg {
            True -> Error(Nil)
            False -> {
              let src = dict.get(sources, k) |> result.unwrap("root")
              Ok(
                "Warning: "
                <> kind_label
                <> " '"
                <> k
                <> "' (from "
                <> src
                <> ") did not match any "
                <> entity_label
                <> " in loaded packages",
              )
            }
          }
        }
      }
    })
  }

  let w_fns =
    check_keys(
      dict.keys(overlays.overrides),
      overlays.override_sources,
      fn_keys,
      "override",
      "function",
    )
  let w_tys =
    check_keys(
      dict.keys(overlays.type_overrides),
      overlays.type_override_sources,
      type_keys,
      "type_override",
      "type",
    )
  let w_mods =
    check_keys(
      dict.keys(overlays.module_patches),
      overlays.module_patch_sources,
      mod_keys,
      "patch",
      "module",
    )
  list.flatten([w_fns, w_tys, w_mods])
}

/// Materialize `build/.gekko_gprelude` and a generated `moon.work` at
/// `project_root` when `moonbit/moon.mod` exists, so MoonBit's LSP resolves
/// `"gekko/gprelude"` directly inside `moonbit/`.
pub fn sync_moonbit_lsp_workspace(project_root: String) -> Result(Nil, String) {
  let moon_mod_path = filepath.join(project_root, "moonbit/moon.mod")
  case simplifile.is_file(moon_mod_path) {
    Ok(True) -> {
      let lsp_gprelude_dir =
        filepath.join(project_root, "build/.gekko_gprelude")
      let lsp_moon_mod = "name = \"gekko/gprelude\"\nversion = \"0.1.0\"\n"
      use _ <- result.try(write_text_file(
        filepath.join(lsp_gprelude_dir, "moon.mod"),
        lsp_moon_mod,
      ))
      use _ <- result.try(write_text_file(
        filepath.join(lsp_gprelude_dir, "moon.pkg"),
        prelude_runtime.moon_pkg(),
      ))
      use _ <- result.try(write_text_file(
        filepath.join(lsp_gprelude_dir, "gprelude.mbt"),
        prelude_runtime.gprelude_mbt(),
      ))

      let moon_work_path = filepath.join(project_root, "moon.work")
      let moon_work_contents =
        "// Generated by gekko for MoonBit LSP support\n"
        <> "members = [\n"
        <> "  \"moonbit\",\n"
        <> "  \"build/.gekko_gprelude\",\n"
        <> "]\n"
      case simplifile.read(moon_work_path) {
        Ok(existing) ->
          case string.starts_with(existing, "// Generated by gekko") {
            True -> write_text_file(moon_work_path, moon_work_contents)
            False -> Ok(Nil)
          }
        Error(simplifile.Enoent) ->
          write_text_file(moon_work_path, moon_work_contents)
        Error(_) -> Ok(Nil)
      }
    }
    _ -> Ok(Nil)
  }
}
