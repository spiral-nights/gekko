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
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import index/symbol_table
import lower/gleam_patch
import lower/ir as lower_ir
import lower/ir_util
import lower/mangle
import lower/validate
import project/analysis
import project/diagnostics
import project/ffi_config
import project/fs
import project/loader
import project/moonbit_ffi
import project/paths
import project/prepass.{type PrepassResult}
import project/type_baseline
import simplifile

/// Summary returned after transpiling a Gleam project into a MoonBit workspace.
pub type TranspileSummary {
  TranspileSummary(
    project_name: String,
    version: String,
    out_dir: String,
    emitted_modules: List(String),
    local_moonbit_packages: List(String),
    module_pkg_dirs: Dict(String, String),
    missing_externals: List(String),
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
  use ctx <- result.try(loader.load_project_context(project_root, include_tests))
  let project_name = ctx.project_name
  let version = ctx.version
  let discovered_versions =
    list.fold(
      ctx.dependencies,
      dict.from_list([#(project_name, version)]),
      fn(acc, dep) { dict.insert(acc, dep.package_name, dep.version) },
    )
  use version_warnings <- result.try(ffi_config.check_shim_versions(
    ctx.overlays.shims,
    discovered_versions,
  ))
  let auth_warnings =
    ffi_config.check_authorized_shims(
      ctx.overlays.authorized_shims,
      discovered_versions,
    )
  let version_warnings = list.append(version_warnings, auth_warnings)
  use root_moonbit_deps <- result.try(ffi_config.load_project_moonbit_deps(
    project_root,
  ))
  use pa <- result.try(analysis.analyze_project_context(
    project_root,
    ctx,
    include_tests,
    True,
    True,
  ))
  let overlays = pa.overlays
  let loaded_deps = pa.loaded_deps
  let all_modules = pa.all_modules
  let non_mirror_modules = pa.non_mirror_modules
  let ffi_metadata = pa.ffi_metadata
  let table = pa.table
  let resolved_pkg_dirs = pa.resolved_pkg_dirs
  let ir_modules = pa.ir_modules

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

  use _ <- result.try(validate_overlay_matches(
    overlays,
    all_modules,
    table,
    discovered_versions,
  ))

  use _ <- result.try(validate_all_int_literals(all_modules, table))

  use _ <- result.try(
    simplifile.create_directory_all(out_dir)
    |> result.map_error(fn(err) {
      "Failed to create output workspace "
      <> out_dir
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )

  let moon_mod_src =
    pkg_config.emit_moon_mod_with_deps(project_name, version, moonbit_deps)
  use _ <- result.try(fs.write_text_if_changed(
    filepath.join(out_dir, "moon.mod"),
    moon_mod_src,
  ))

  let gprelude_dir = filepath.join(out_dir, "gprelude")
  let gprelude_pkg_src = prelude_runtime.moon_pkg()
  let gprelude_mbt_src = prelude_runtime.gprelude_mbt()
  use _ <- result.try(fs.write_text_if_changed(
    filepath.join(gprelude_dir, "moon.pkg"),
    gprelude_pkg_src,
  ))
  use _ <- result.try(fs.write_text_if_changed(
    filepath.join(gprelude_dir, "gprelude.mbt"),
    gprelude_mbt_src,
  ))

  let module_pkg_dirs =
    list.map(non_mirror_modules, fn(entry) {
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
  let all_local_pkgs =
    set.union(local_pkg_set, set.from_list(["gprelude", ..module_pkg_dirs]))

  let patch_mirrors =
    list.fold(all_modules, dict.new(), fn(acc, entry) {
      let #(_, mod_name, _, pre) = entry
      case pre.patch_mirror {
        Some(info) -> dict.insert(acc, mod_name, info)
        None -> acc
      }
    })
  let module_meta_by_name =
    list.fold(non_mirror_modules, dict.new(), fn(acc, entry) {
      let #(pkg_name, mod_name, ast_mod, pre) = entry
      dict.insert(acc, mod_name, #(pkg_name, ast_mod, pre.cleaned_source))
    })
  let module_pkg_by_name =
    dict.map_values(module_meta_by_name, fn(_k, v) { v.0 })

  use #(ir_modules, table) <- result.try(
    gleam_patch.splice_gleam_patches_with_overlays(
      ir_modules,
      table,
      overlays.gleam_type_patches,
      patch_mirrors,
      module_pkg_by_name,
    ),
  )

  let project_bounds =
    trait_bounds.analyze_project(ir_modules, Some(table), ffi_metadata)

  use _ <- result.try(validate_patch_decl_sigs(
    ir_modules,
    module_pkg_by_name,
    project_name,
    overlays.module_patches,
  ))

  use _ <- result.try(type_baseline.check_baselines(
    project_root,
    module_pkg_by_name,
    ir_modules,
    discovered_versions,
  ))

  let missing_externals =
    collect_missing_externals(ir_modules, module_pkg_by_name, project_name)
  let abs_root_slash = paths.absolute(project_root) <> "/"

  use #(rev_emitted, rev_origins, rev_mirror) <- result.try(
    list.try_fold(ir_modules, #([], [], []), fn(acc, ir_mod) {
      let #(names_acc, origins_acc, mirror_acc) = acc
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
      let mbt_stem = filepath.base_name(pkg_dir)
      let mbt_rel = pkg_dir <> "/" <> mbt_stem <> ".mbt"

      let mod_pkg_name = case dict.get(module_meta_by_name, mod_name) {
        Ok(#(pn, _, _)) -> pn
        Error(_) -> project_name
      }
      let mod_patches =
        analysis.lookup_module_patches(
          mod_pkg_name,
          mod_name,
          overlays.module_patches,
        )
      use merged_imports <- result.try(merge_patch_imports(
        mod_name,
        imports,
        mod_patches,
        resolved_pkg_dirs,
      ))

      let moon_pkg_src =
        fs.generated_marker
        <> "\n"
        <> pkg_config.emit_moon_pkg_with_local_pkgs(
          project_name,
          merged_imports,
          is_main,
          all_local_pkgs,
        )
      use _ <- result.try(fs.write_text_if_changed(
        filepath.join(target_dir, "moon.pkg"),
        moon_pkg_src,
      ))
      use _ <- result.try(fs.write_text_if_changed(
        filepath.join(target_dir, mbt_stem <> ".mbt"),
        mbt_src,
      ))
      use _ <- result.try(sync_patched_files(target_dir, mod_patches))
      let patch_fn_locs = build_patch_fn_loc_map(mod_patches, abs_root_slash)
      let sigcheck_origins =
        diagnostics.collect_patch_sigcheck_origins(
          mbt_rel,
          mbt_src,
          patch_fn_locs,
        )
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
      let combined_origins = list.append(sigcheck_origins, mod_origins)
      Ok(
        #(
          [mod_name, ..names_acc],
          list.append(list.reverse(combined_origins), origins_acc),
          [
            #(pkg_dir, mbt_stem, moon_pkg_src, mbt_src, mod_patches),
            ..mirror_acc
          ],
        ),
      )
    }),
  )

  use _ <- result.try(fs.write_text_if_changed(
    filepath.join(out_dir, diagnostics.sourcemap_filename),
    diagnostics.format_sourcemap(list.reverse(rev_origins)),
  ))

  let new_generated_dirs =
    list.append(module_pkg_dirs, local_moonbit_packages)
    |> list.filter(fn(d) { d != "" && d != "gprelude" })
    |> set.from_list
    |> set.to_list
    |> list.sort(string.compare)

  use _ <- result.try(clean_stale_generated_dirs(
    out_dir,
    new_generated_dirs,
    include_tests,
  ))

  use _ <- result.try(write_patches_mirror(
    project_root,
    out_dir,
    moon_mod_src,
    gprelude_pkg_src,
    gprelude_mbt_src,
    local_moonbit_packages,
    list.reverse(rev_mirror),
  ))

  use _ <- result.try(sync_moonbit_lsp_workspace(project_root))

  Ok(TranspileSummary(
    project_name:,
    version:,
    out_dir:,
    emitted_modules: list.reverse(rev_emitted),
    local_moonbit_packages:,
    module_pkg_dirs: resolved_pkg_dirs,
    missing_externals:,
    warnings: version_warnings,
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
    False -> {
      let flat_legacy = case simplifile.read_directory(at: out_dir) {
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
      let nested_test =
        find_pkg_dirs_under(filepath.join(out_dir, "test"), "test")
      list.append(flat_legacy, nested_test)
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
    |> list.sort(fn(a, b) {
      case int.compare(string.length(b), string.length(a)) {
        order.Eq -> string.compare(b, a)
        ord -> ord
      }
    })

  use _ <- result.try(
    list.try_each(stale, fn(dir) {
      let path = filepath.join(out_dir, dir)
      let has_kept_child =
        list.any(new_generated_dirs, fn(kept) {
          string.starts_with(kept, dir <> "/")
        })
      case simplifile.is_directory(path), has_kept_child {
        Ok(True), True -> remove_direct_files_in_dir(path)
        Ok(True), False -> {
          use _ <- result.try(
            simplifile.delete(file_or_dir_at: path)
            |> result.map_error(fn(err) {
              "Failed to clean stale package directory "
              <> path
              <> ": "
              <> simplifile.describe_error(err)
            }),
          )
          prune_empty_parent_dirs(filepath.directory_name(path), out_dir)
          Ok(Nil)
        }
        _, _ -> Ok(Nil)
      }
    }),
  )

  let manifest_body = case new_generated_dirs {
    [] -> ""
    _ -> string.join(new_generated_dirs, "\n") <> "\n"
  }
  fs.write_text_if_changed(manifest_path, manifest_body)
}

fn find_pkg_dirs_under(dir: String, rel_prefix: String) -> List(String) {
  case simplifile.read_directory(at: dir) {
    Error(_) -> []
    Ok(entries) -> {
      let here = case simplifile.is_file(filepath.join(dir, "moon.pkg")) {
        Ok(True) -> [rel_prefix]
        _ -> []
      }
      let nested =
        list.flat_map(entries, fn(entry) {
          let full = filepath.join(dir, entry)
          case simplifile.is_directory(full) {
            Ok(True) -> find_pkg_dirs_under(full, rel_prefix <> "/" <> entry)
            _ -> []
          }
        })
      list.append(here, nested)
    }
  }
}

fn remove_direct_files_in_dir(dir: String) -> Result(Nil, String) {
  case simplifile.read_directory(at: dir) {
    Error(_) -> Ok(Nil)
    Ok(entries) ->
      list.try_each(entries, fn(entry) {
        let full = filepath.join(dir, entry)
        case simplifile.is_file(full) {
          Ok(True) ->
            simplifile.delete_file(at: full)
            |> result.map_error(fn(err) {
              "Failed to clean stale file "
              <> full
              <> ": "
              <> simplifile.describe_error(err)
            })
          _ -> Ok(Nil)
        }
      })
  }
}

fn prune_empty_parent_dirs(dir: String, stop_dir: String) -> Nil {
  case dir == "" || dir == "." || dir == stop_dir {
    True -> Nil
    False ->
      case simplifile.read_directory(at: dir) {
        Ok([]) -> {
          let _ = simplifile.delete(file_or_dir_at: dir)
          prune_empty_parent_dirs(filepath.directory_name(dir), stop_dir)
        }
        _ -> Nil
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
      use _ <- result.try(fs.write_text_if_changed(dest_path, content))
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

fn validate_overlay_matches(
  overlays: ffi_config.MergedOverlays,
  all_modules: List(#(String, String, glance.Module, PrepassResult)),
  table: symbol_table.SymbolTable,
  discovered_versions: Dict(String, String),
) -> Result(Nil, String) {
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
              let hint = case kind_label == "patch" {
                False -> ""
                True ->
                  case dict.get(overlays.module_patches, k) {
                    Ok(mp) -> single_file_migration_hint(k, mp, mod_keys)
                    Error(_) -> ""
                  }
              }
              Ok(
                "Unmatched "
                <> kind_label
                <> " '"
                <> k
                <> "' (from "
                <> src
                <> ") did not match any "
                <> entity_label
                <> " in loaded packages"
                <> hint,
              )
            }
          }
        }
      }
    })
  }

  let e_fns =
    check_keys(
      dict.keys(overlays.overrides),
      overlays.override_sources,
      fn_keys,
      "override",
      "function",
    )
  let e_tys =
    check_keys(
      dict.keys(overlays.type_overrides),
      overlays.type_override_sources,
      type_keys,
      "type_override",
      "type",
    )
  let e_g_tys =
    check_keys(
      dict.keys(overlays.gleam_type_patches),
      overlays.gleam_type_patch_sources,
      type_keys,
      "gleam_type_patch",
      "type",
    )
  let e_mods =
    check_keys(
      dict.keys(overlays.module_patches),
      overlays.module_patch_sources,
      mod_keys,
      "patch",
      "module",
    )
  let e_mirrors =
    dict.to_list(overlays.patch_mirrors)
    |> list.filter_map(fn(entry) {
      let #(mirror_mod, target_mod_key) = entry
      case set.contains(mod_keys, target_mod_key) {
        True -> Error(Nil)
        False -> {
          let targets_missing_pkg = case
            string.split_once(target_mod_key, ":")
          {
            Ok(#(pkg, _)) -> set.contains(missing_shim_targets, pkg)
            Error(_) -> False
          }
          case targets_missing_pkg {
            True -> Error(Nil)
            False -> {
              let src =
                dict.get(overlays.patch_mirror_sources, mirror_mod)
                |> result.unwrap("root")
              Ok(
                "Unmatched patch_mirror '"
                <> target_mod_key
                <> "' in '"
                <> mirror_mod
                <> "' (from "
                <> src
                <> ") did not match any module in loaded packages",
              )
            }
          }
        }
      }
    })
  case list.flatten([e_fns, e_tys, e_g_tys, e_mods, e_mirrors]) {
    [] -> Ok(Nil)
    errs -> Error(string.join(errs, "\n"))
  }
}

fn single_file_migration_hint(
  mod_key: String,
  patch: ffi_config.ModulePatch,
  mod_keys: Set(String),
) -> String {
  let mod_part = case string.split_once(mod_key, ":") {
    Ok(#(_, m)) -> m
    Error(_) -> mod_key
  }
  let matched =
    list.find(patch.files, fn(f) {
      case string.ends_with(f.dest_filename, ".mbt") {
        False -> False
        True -> {
          let stem = string.drop_end(f.dest_filename, 4)
          let candidate = mod_part <> "/" <> stem
          set.contains(mod_keys, candidate)
        }
      }
    })
  case matched {
    Ok(f) -> {
      let stem = string.drop_end(f.dest_filename, 4)
      " (single-file patches are retired; move to patches/"
      <> mod_part
      <> "/"
      <> stem
      <> "/"
      <> f.dest_filename
      <> " or run 'gekko shim migrate')"
    }
    Error(_) -> ""
  }
}

fn validate_patch_decl_sigs(
  ir_modules: List(lower_ir.IrModule),
  module_pkg_by_name: Dict(String, String),
  project_name: String,
  module_patches: Dict(String, ffi_config.ModulePatch),
) -> Result(Nil, String) {
  let rev_errors =
    list.fold(ir_modules, [], fn(acc, ir_mod) {
      let mod_name = ir_mod.module_name
      let mod_pkg =
        dict.get(module_pkg_by_name, mod_name) |> result.unwrap(project_name)
      let mod_patches =
        analysis.lookup_module_patches(mod_pkg, mod_name, module_patches)
      let fn_map =
        list.fold(ir_mod.functions, dict.new(), fn(m, f) {
          m
          |> dict.insert(f.unmangled_name, f)
          |> dict.insert(f.name, f)
        })
      list.fold(mod_patches, acc, fn(p_acc, p) {
        list.fold(p.decl_locs, p_acc, fn(l_acc, loc) {
          case loc.param_count {
            None -> l_acc
            Some(actual_arity) ->
              case dict.get(fn_map, loc.gleam_name) {
                Error(_) -> l_acc
                Ok(ir_fn) -> {
                  let loc_str = loc.file_path <> ":" <> int.to_string(loc.line)
                  let err1 = case
                    ir_fn.publicity == glance.Public && !loc.is_pub
                  {
                    True -> [
                      "Signature mismatch at "
                        <> loc_str
                        <> ": patched function '"
                        <> mod_name
                        <> "."
                        <> loc.gleam_name
                        <> "' is 'pub' in Gleam and must be 'pub' in MoonBit",
                      ..l_acc
                    ]
                    False -> l_acc
                  }
                  let expected_arity = list.length(ir_fn.params)
                  case actual_arity != expected_arity {
                    True -> [
                      "Signature mismatch at "
                        <> loc_str
                        <> ": patched function '"
                        <> mod_name
                        <> "."
                        <> loc.gleam_name
                        <> "' expects "
                        <> int.to_string(expected_arity)
                        <> " parameter(s), got "
                        <> int.to_string(actual_arity),
                      ..err1
                    ]
                    False -> err1
                  }
                }
              }
          }
        })
      })
    })
  case rev_errors {
    [] -> Ok(Nil)
    _ -> Error(string.join(list.reverse(rev_errors), "\n"))
  }
}

fn collect_missing_externals(
  ir_modules: List(lower_ir.IrModule),
  module_pkg_by_name: Dict(String, String),
  project_name: String,
) -> List(String) {
  list.flat_map(ir_modules, fn(ir_mod) {
    let mod_name = ir_mod.module_name
    let mod_pkg =
      dict.get(module_pkg_by_name, mod_name) |> result.unwrap(project_name)
    list.filter_map(ir_mod.functions, fn(f) {
      case ir_util.needs_shim(f) {
        False -> Error(Nil)
        True ->
          case mod_pkg == project_name {
            True -> Ok(mod_name <> "." <> f.unmangled_name)
            False -> Ok(mod_pkg <> ":" <> mod_name <> "." <> f.unmangled_name)
          }
      }
    })
  })
  |> list.sort(string.compare)
}

fn build_patch_fn_loc_map(
  patches: List(ffi_config.ModulePatch),
  abs_root_slash: String,
) -> Dict(String, #(String, Int)) {
  list.fold(patches, dict.new(), fn(acc, p) {
    list.fold(p.decl_locs, acc, fn(inner, loc) {
      let disp_path = case string.starts_with(loc.file_path, abs_root_slash) {
        True -> string.drop_start(loc.file_path, string.length(abs_root_slash))
        False -> loc.file_path
      }
      let val = #(disp_path, loc.line)
      inner
      |> dict.insert(loc.gleam_name, val)
      |> dict.insert(mangle.mangle_ident(loc.gleam_name), val)
      |> dict.insert(loc.mbt_name, val)
    })
  })
}

fn write_patches_mirror(
  project_root: String,
  out_dir: String,
  moon_mod_src: String,
  gprelude_pkg_src: String,
  gprelude_mbt_src: String,
  local_moonbit_packages: List(String),
  mirror_entries: List(
    #(String, String, String, String, List(ffi_config.ModulePatch)),
  ),
) -> Result(Nil, String) {
  let patches_dir = filepath.join(project_root, "patches")
  case simplifile.is_directory(patches_dir) {
    Ok(True) -> {
      let abs_patches_dir = paths.absolute(patches_dir)
      let manifest_path = filepath.join(patches_dir, ".gekko_generated")
      let prev_generated = case simplifile.read(from: manifest_path) {
        Ok(content) ->
          content
          |> string.split("\n")
          |> list.map(string.trim)
          |> list.filter(fn(l) { l != "" })
        Error(_) -> []
      }

      use _ <- result.try(fs.write_text_if_changed(
        filepath.join(patches_dir, "moon.mod"),
        moon_mod_src,
      ))
      use _ <- result.try(fs.write_text_if_changed(
        filepath.join(patches_dir, "gprelude/moon.pkg"),
        gprelude_pkg_src,
      ))
      use _ <- result.try(fs.write_text_if_changed(
        filepath.join(patches_dir, "gprelude/gprelude.mbt"),
        gprelude_mbt_src,
      ))

      let base_files = [
        "moon.mod",
        "gprelude/moon.pkg",
        "gprelude/gprelude.mbt",
      ]

      use rev_local_files <- result.try(
        list.try_fold(local_moonbit_packages, [], fn(acc, local_pkg) {
          let src_pkg_dir = filepath.join(out_dir, local_pkg)
          let dst_pkg_dir = filepath.join(patches_dir, local_pkg)
          case simplifile.read_directory(at: src_pkg_dir) {
            Error(_) -> Ok(acc)
            Ok(entries) ->
              list.try_fold(
                list.sort(entries, string.compare),
                acc,
                fn(inner_acc, entry) {
                  let src_file = filepath.join(src_pkg_dir, entry)
                  case entry == "moon.pkg", string.ends_with(entry, ".mbt") {
                    True, _ -> {
                      use content <- result.try(fs.read_text(src_file))
                      let marked = case
                        string.starts_with(content, fs.generated_marker)
                      {
                        True -> content
                        False -> fs.generated_marker <> "\n" <> content
                      }
                      let rel = local_pkg <> "/moon.pkg"
                      use _ <- result.try(fs.write_text_if_changed(
                        filepath.join(dst_pkg_dir, "moon.pkg"),
                        marked,
                      ))
                      Ok([rel, ..inner_acc])
                    }
                    False, True -> {
                      use content <- result.try(fs.read_text(src_file))
                      let stem = string.drop_end(entry, 4)
                      let dst_name = stem <> ".g.mbt"
                      let rel = local_pkg <> "/" <> dst_name
                      use _ <- result.try(fs.write_text_if_changed(
                        filepath.join(dst_pkg_dir, dst_name),
                        content,
                      ))
                      Ok([rel, ..inner_acc])
                    }
                    _, _ -> Ok(inner_acc)
                  }
                },
              )
          }
        }),
      )

      use rev_mod_files <- result.try(
        list.try_fold(mirror_entries, [], fn(acc, entry) {
          let #(pkg_dir, mbt_stem, moon_pkg_src, mbt_src, mod_patches) = entry
          let target_dir = filepath.join(patches_dir, pkg_dir)
          let pkg_rel = pkg_dir <> "/moon.pkg"
          let mbt_rel = pkg_dir <> "/" <> mbt_stem <> ".g.mbt"
          use _ <- result.try(fs.write_text_if_changed(
            filepath.join(target_dir, "moon.pkg"),
            moon_pkg_src,
          ))
          use _ <- result.try(fs.write_text_if_changed(
            filepath.join(target_dir, mbt_stem <> ".g.mbt"),
            mbt_src,
          ))

          let mod_patches_dir_prefix =
            paths.absolute(filepath.join(abs_patches_dir, pkg_dir)) <> "/"
          let ext_patch_files =
            mod_patches
            |> list.filter(fn(p) { !is_builtin_alias_only_patch(p) })
            |> list.flat_map(fn(p) { p.files })
            |> list.filter(fn(f) {
              !string.starts_with(f.source_path, mod_patches_dir_prefix)
            })
          use rev_ext <- result.try(
            list.index_fold(ext_patch_files, Ok([]), fn(r_acc, f, idx) {
              use cur <- result.try(r_acc)
              let stem = case string.ends_with(f.dest_filename, ".mbt") {
                True -> string.drop_end(f.dest_filename, 4)
                False -> f.dest_filename
              }
              let dest_name =
                "__gekko_patch_"
                <> int.to_string(idx + 1)
                <> "_"
                <> stem
                <> ".g.mbt"
              let rel = pkg_dir <> "/" <> dest_name
              use content <- result.try(fs.read_text(f.source_path))
              use _ <- result.try(fs.write_text_if_changed(
                filepath.join(target_dir, dest_name),
                content,
              ))
              Ok([rel, ..cur])
            }),
          )
          Ok(
            list.flatten([
              rev_ext,
              [mbt_rel, pkg_rel],
              acc,
            ]),
          )
        }),
      )

      let new_files =
        list.flatten([
          base_files,
          list.reverse(rev_local_files),
          list.reverse(rev_mod_files),
        ])
        |> set.from_list
        |> set.to_list
        |> list.sort(string.compare)
      let new_set = set.from_list(new_files)

      let stale_files =
        list.filter(prev_generated, fn(rel) { !set.contains(new_set, rel) })
      use _ <- result.try(
        list.try_each(stale_files, fn(rel) {
          let full = filepath.join(patches_dir, rel)
          let safe_to_delete =
            string.ends_with(rel, ".g.mbt")
            || rel == "moon.mod"
            || string.starts_with(rel, "gprelude/")
            || {
              filepath.base_name(rel) == "moon.pkg"
              && fs.has_generated_marker(full)
            }
          case safe_to_delete, simplifile.is_file(full) {
            True, Ok(True) -> {
              use _ <- result.try(
                simplifile.delete_file(at: full)
                |> result.map_error(fn(err) {
                  "Failed to clean stale patch mirror file "
                  <> full
                  <> ": "
                  <> simplifile.describe_error(err)
                }),
              )
              prune_empty_parent_dirs(
                filepath.directory_name(full),
                patches_dir,
              )
              Ok(Nil)
            }
            _, _ -> Ok(Nil)
          }
        }),
      )

      let manifest_body = string.join(new_files, "\n") <> "\n"
      fs.write_text_if_changed(manifest_path, manifest_body)
    }
    _ -> Ok(Nil)
  }
}

/// Materialize `moonbit/gprelude/` (when `moonbit/moon.mod` exists) and a
/// generated `moon.work` at `project_root` (when `patches/` or `moonbit/moon.mod`
/// exists), enabling full MoonBit LSP support across both trees.
pub fn sync_moonbit_lsp_workspace(project_root: String) -> Result(Nil, String) {
  let patches_dir = filepath.join(project_root, "patches")
  let has_patches = simplifile.is_directory(patches_dir) == Ok(True)
  let moon_mod_path = filepath.join(project_root, "moonbit/moon.mod")
  let has_moonbit = simplifile.is_file(moon_mod_path) == Ok(True)

  use _ <- result.try(case has_patches, has_moonbit {
    True, True -> {
      let gleam_name = case loader.read_project_meta(project_root) {
        Ok(#(name, _)) -> Some(name)
        Error(_) -> None
      }
      let mbt_name = moonbit_ffi.read_moon_mod_name(moon_mod_path)
      case gleam_name, mbt_name {
        Some(gn), Some(mn) if gn == mn ->
          Error(
            "moonbit/moon.mod and gleam.toml share module name '"
            <> gn
            <> "'; rename moonbit/moon.mod (e.g. '"
            <> gn
            <> "_mbt') so moon.work has no duplicate module names",
          )
        _, _ -> Ok(Nil)
      }
    }
    _, _ -> Ok(Nil)
  })

  use _ <- result.try(case has_moonbit {
    False -> Ok(Nil)
    True -> {
      let lsp_gprelude_dir = filepath.join(project_root, "moonbit/gprelude")
      use _ <- result.try(fs.write_text_if_changed(
        filepath.join(lsp_gprelude_dir, "moon.pkg"),
        fs.generated_marker <> "\n" <> prelude_runtime.moon_pkg(),
      ))
      fs.write_text_if_changed(
        filepath.join(lsp_gprelude_dir, "gprelude.mbt"),
        prelude_runtime.gprelude_mbt(),
      )
    }
  })

  let members = case has_patches, has_moonbit {
    True, True -> ["patches", "moonbit"]
    True, False -> ["patches"]
    False, True -> ["moonbit"]
    False, False -> []
  }

  let moon_work_path = filepath.join(project_root, "moon.work")
  case members {
    [] ->
      case fs.has_generated_marker(moon_work_path) {
        True ->
          simplifile.delete_file(at: moon_work_path)
          |> result.map_error(fn(err) {
            "Failed to remove "
            <> moon_work_path
            <> ": "
            <> simplifile.describe_error(err)
          })
        False -> Ok(Nil)
      }
    _ -> {
      let member_lines =
        list.map(members, fn(m) { "  \"" <> m <> "\"," })
        |> string.join("\n")
      let moon_work_contents =
        fs.generated_marker
        <> " for MoonBit LSP support\n"
        <> "members = [\n"
        <> member_lines
        <> "\n]\n"
      case simplifile.read(moon_work_path) {
        Ok(existing) ->
          case string.starts_with(existing, fs.generated_marker) {
            True -> fs.write_text_if_changed(moon_work_path, moon_work_contents)
            False -> Ok(Nil)
          }
        Error(simplifile.Enoent) ->
          fs.write_text_if_changed(moon_work_path, moon_work_contents)
        Error(_) -> Ok(Nil)
      }
    }
  }
}
