import emit/moonbit
import emit/moonbit_decl
import emit/pkg_config
import emit/trait_bounds.{type ProjectTraitBounds}
import filepath
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import index/symbol_table.{type SymbolTable}
import lower/desugar
import lower/ir.{type IrModule}
import lower/ir_util
import lower/mangle
import lower/tco
import moonbit/ffi_meta.{type FfiMetadata}
import project/ffi_config
import project/fs
import project/interface.{PackageInterface}
import project/loader
import project/patch_discovery
import project/prepass.{type PrepassResult}
import project/staging
import project/type_baseline
import simplifile
import tom

/// Target language for scaffolding shim stubs.
pub type ShimStyle {
  GleamShim
  MoonBitShim
}

type ShimWorkspace {
  ShimWorkspace(
    project_name: String,
    version: String,
    overlays: ffi_config.MergedOverlays,
    root_overlay: ffi_config.PackageOverlay,
    discovered_versions: Dict(String, String),
    all_modules: List(#(String, String, glance.Module, PrepassResult)),
    module_pkg_by_name: Dict(String, String),
    table: SymbolTable,
    ffi_metadata: FfiMetadata,
    ir_modules: List(IrModule),
    project_bounds: ProjectTraitBounds,
    resolved_pkg_dirs: Dict(String, String),
  )
}

type UnmappedType {
  UnmappedType(
    mod_name: String,
    type_name: String,
    type_params: List(String),
    publicity: glance.Publicity,
  )
}

type MissingFn {
  MissingFn(mod_name: String, fn_name: String, stub_block: String)
}

/// Inspect a shim repository (defaulting to `[tools.gekko.shim_for]`) or a
/// resolved dependency `target_pkg_opt` in `project_root`.
pub fn inspect_package(
  project_root: String,
  target_pkg_opt: Option(String),
) -> Result(String, String) {
  use ws <- result.try(load_shim_workspace(project_root))
  use target_pkg <- result.try(resolve_target_pkg(ws, target_pkg_opt))
  let target_ver =
    dict.get(ws.discovered_versions, target_pkg) |> result.unwrap("unknown")

  let target_ir_mods =
    list.filter(ws.ir_modules, fn(m) {
      dict.get(ws.module_pkg_by_name, m.module_name) == Ok(target_pkg)
    })

  let missing_fns = collect_missing_fns(ws, target_ir_mods)
  let unmapped_types =
    collect_unmapped_types(
      ws.overlays.gleam_type_patches,
      target_pkg,
      target_ir_mods,
    )

  let #(_moonbit_types, moonbit_fns) =
    count_patched_decls(ws.overlays.module_patches, target_pkg)
  let gleam_fns = count_gleam_patch_decls(ws.overlays.overrides, target_pkg)
  let gleam_types =
    count_gleam_type_patches(ws.overlays.gleam_type_patches, target_pkg)
  let patched_types =
    count_patched_types(ws.overlays.type_overrides, target_pkg) + gleam_types
  let patched_fns = moonbit_fns + gleam_fns
  let unmatched = count_unmatched_entries(ws, target_pkg)
  let drift_status = case
    type_baseline.check_baselines(
      project_root,
      ws.module_pkg_by_name,
      ws.ir_modules,
      ws.discovered_versions,
    )
  {
    Ok(Nil) -> "clean"
    Error(err) -> "DRIFT DETECTED\n" <> err
  }
  let semver_note = case ws.root_overlay.shim {
    Some(meta) if meta.target == target_pkg ->
      case meta.version {
        Some(v) -> " (constraint: " <> v <> ")"
        None -> ""
      }
    _ -> ""
  }

  let header =
    "Shim inspection for "
    <> target_pkg
    <> " ("
    <> target_ver
    <> ")"
    <> semver_note
    <> ":\n"
    <> "  Patched declarations: "
    <> int.to_string(patched_types + patched_fns)
    <> " ("
    <> int.to_string(patched_types)
    <> " types, "
    <> int.to_string(patched_fns)
    <> " functions)\n"
    <> "  Unmatched entries: "
    <> int.to_string(list.length(unmatched))
    <> "\n"
    <> "  Type drift: "
    <> drift_status

  let types_section = case unmapped_types {
    [] -> "\nZero-variant external types: none"
    tys -> {
      let lines =
        list.map(tys, fn(t) {
          let params = case t.type_params {
            [] -> ""
            ps -> "(" <> string.join(ps, ", ") <> ")"
          }
          "  - " <> t.mod_name <> "." <> t.type_name <> params
        })
      "\nZero-variant external types ("
      <> int.to_string(list.length(tys))
      <> "):\n"
      <> string.join(lines, "\n")
    }
  }

  let fns_section = case missing_fns {
    [] -> "\nMissing external functions: none"
    fns -> {
      let lines =
        list.map(fns, fn(f) { "  - " <> f.mod_name <> "." <> f.fn_name })
      "\nMissing external functions ("
      <> int.to_string(list.length(fns))
      <> "):\n"
      <> string.join(lines, "\n")
    }
  }

  let unmatched_section = case unmatched {
    [] -> ""
    items -> "\nUnmatched entries:\n  - " <> string.join(items, "\n  - ")
  }

  Ok(header <> types_section <> fns_section <> unmatched_section)
}

/// Scaffold a brand-new companion shim repository for `target_pkg`
/// (defaulting to `<project_root>/gekko_<target_pkg>`).
pub fn new_shim(
  project_root: String,
  target_pkg: String,
  out_dir: Option(String),
) -> Result(String, String) {
  new_shim_with_style(project_root, target_pkg, out_dir, MoonBitShim)
}

/// Like `new_shim`, scaffolding either Gleam `/// @patch(...)` stubs or raw
/// MoonBit `patches/` stubs depending on `style`.
pub fn new_shim_with_style(
  project_root: String,
  target_pkg: String,
  out_dir: Option(String),
  style: ShimStyle,
) -> Result(String, String) {
  use ws <- result.try(load_shim_workspace(project_root))
  use _ <- result.try(ensure_dep_present(ws, target_pkg))
  let target_ver =
    dict.get(ws.discovered_versions, target_pkg) |> result.unwrap("0.1.0")
  let shim_dir =
    option.unwrap(out_dir, filepath.join(project_root, "gekko_" <> target_pkg))
  let shim_name = case filepath.base_name(shim_dir) {
    "" | "." -> "gekko_" <> target_pkg
    base -> string.replace(base, "-", "_")
  }

  use _ <- result.try(ensure_empty_or_new_dir(shim_dir))

  let target_ir_mods =
    list.filter(ws.ir_modules, fn(m) {
      dict.get(ws.module_pkg_by_name, m.module_name) == Ok(target_pkg)
    })
  let missing_fns = collect_missing_fns(ws, target_ir_mods)
  let unmapped_types =
    collect_unmapped_types(
      ws.overlays.gleam_type_patches,
      target_pkg,
      target_ir_mods,
    )

  let gleam_toml =
    "name = \""
    <> shim_name
    <> "\"\nversion = \"0.1.0\"\ndescription = \"Shim overlay for "
    <> target_pkg
    <> "\"\n\n"
    <> "[dependencies]\n"
    <> target_pkg
    <> " = \""
    <> suggest_semver_constraint(target_ver)
    <> "\"\n\n"
    <> render_shim_gleam_toml_section(target_pkg, target_ver)
  let gitignore =
    "build/\ndist/\n/_build/\n/moon.work\n/moonbit/gprelude/\n/patches/moon.mod\n/patches/gprelude/\n/patches/_build/\n/patches/.mooncakes/\npatches/**/moon.pkg\npatches/**/*.g.mbt\npkg.generated.mbti\n"
  let placeholder_gleam =
    "//// Companion shim overlay for `"
    <> target_pkg
    <> "`.\n\npub const target = \""
    <> target_pkg
    <> "\"\n"
  let patch_files = case style {
    MoonBitShim -> render_new_patch_files(ws, unmapped_types, missing_fns)
    GleamShim ->
      render_new_gleam_shim_files(ws, shim_name, target_pkg, target_ir_mods)
  }

  let files = [
    #("gleam.toml", gleam_toml),
    #(".gitignore", gitignore),
    #("src/" <> shim_name <> ".gleam", placeholder_gleam),
    ..patch_files
  ]

  use _ <- result.try(
    list.try_each(files, fn(entry) {
      let #(rel, contents) = entry
      fs.write_text(filepath.join(shim_dir, rel), contents)
    }),
  )

  let created =
    list.map(files, fn(e) { "  " <> filepath.join(shim_dir, e.0) })
    |> string.join("\n")
  let type_note = case style, unmapped_types {
    GleamShim, [_, ..] ->
      "\n\nNote: "
      <> int.to_string(list.length(unmapped_types))
      <> " zero-variant external type(s) can be implemented in Gleam using `/// @patch_type(...)` or configured via `[tools.gekko.type_overrides]`."
    _, _ -> ""
  }
  Ok(
    "Created companion shim '"
    <> shim_name
    <> "' for '"
    <> target_pkg
    <> "':\n"
    <> created
    <> type_note
    <> "\n\nConsumers should enable this shim in their root gleam.toml:\n\n  [tools.gekko.use_shims]\n  "
    <> target_pkg
    <> " = \""
    <> shim_name
    <> "\"",
  )
}

/// Scaffold all missing `@external` implementations inside an existing shim
/// repository (targeting `[tools.gekko.shim_for] package`).
pub fn init_in_place(project_root: String) -> Result(String, String) {
  init_in_place_with_style(project_root, MoonBitShim)
}

/// Like `init_in_place`, choosing Gleam `/// @patch(...)` or MoonBit `patches/`.
pub fn init_in_place_with_style(
  project_root: String,
  style: ShimStyle,
) -> Result(String, String) {
  use ws <- result.try(load_shim_workspace(project_root))
  use target_pkg <- result.try(case ws.root_overlay.shim {
    Some(meta) -> Ok(meta.target)
    None ->
      Error(
        "No [tools.gekko.shim_for] found in gleam.toml (use 'gekko shim new <pkg>' to create a new companion shim repo)",
      )
  })
  use _ <- result.try(ensure_dep_present(ws, target_pkg))

  let target_ir_mods =
    list.filter(ws.ir_modules, fn(m) {
      dict.get(ws.module_pkg_by_name, m.module_name) == Ok(target_pkg)
    })
  case style {
    MoonBitShim -> {
      let missing = collect_missing_fns(ws, target_ir_mods)
      case missing {
        [] ->
          Ok(
            "All external functions in '"
            <> target_pkg
            <> "' are already patched.",
          )
        _ -> {
          let by_mod =
            list.fold(missing, dict.new(), fn(acc, mf) {
              let existing = dict.get(acc, mf.mod_name) |> result.unwrap([])
              dict.insert(acc, mf.mod_name, list.append(existing, [mf]))
            })
          use results <- result.try(
            dict.to_list(by_mod)
            |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
            |> list.try_map(fn(entry) {
              let #(mod_name, fns) = entry
              let decls =
                list.map(fns, fn(f) { #(f.fn_name, f.fn_name, f.stub_block) })
              append_decls_to_module_patch(project_root, mod_name, decls)
            }),
          )
          Ok(string.join(results, "\n"))
        }
      }
    }
    GleamShim -> {
      let mods_with_missing =
        list.filter(target_ir_mods, fn(ir_mod) {
          list.any(ir_mod.functions, ir_util.needs_shim)
        })
      case mods_with_missing {
        [] ->
          Ok(
            "All external functions in '"
            <> target_pkg
            <> "' are already patched.",
          )
        _ -> {
          use results <- result.try(
            mods_with_missing
            |> list.sort(fn(a, b) {
              string.compare(a.module_name, b.module_name)
            })
            |> list.try_map(fn(ir_mod) {
              let missing_fns =
                list.filter(ir_mod.functions, ir_util.needs_shim)
              append_gleam_fns_for_module(
                project_root,
                ws,
                ir_mod.module_name,
                missing_fns,
              )
            }),
          )
          Ok(string.join(results, "\n"))
        }
      }
    }
  }
}

/// Scaffold a single declaration `<module>.<decl>` into `patches/<module>/`.
pub fn patch_decl(
  project_root: String,
  target_spec: String,
) -> Result(String, String) {
  patch_decl_with_style(project_root, target_spec, MoonBitShim)
}

/// Like `patch_decl`, choosing Gleam `/// @patch(...)` or MoonBit `patches/`.
pub fn patch_decl_with_style(
  project_root: String,
  target_spec: String,
  style: ShimStyle,
) -> Result(String, String) {
  let clean_spec = case string.split_once(target_spec, ":") {
    Ok(#(_, rhs)) -> rhs
    Error(_) -> target_spec
  }
  use #(mod_name, decl_name) <- result.try(
    split_last_dot(clean_spec)
    |> result.map_error(fn(_) {
      "Expected `<module>.<decl>` (got '" <> target_spec <> "')"
    }),
  )
  use ws <- result.try(load_shim_workspace(project_root))
  use ir_mod <- result.try(
    list.find(ws.ir_modules, fn(m) { m.module_name == mod_name })
    |> result.map_error(fn(_) {
      "Module '" <> mod_name <> "' was not found in loaded packages"
    }),
  )

  let emit_ctx = make_emit_ctx(ws, mod_name)
  case
    list.find(ir_mod.functions, fn(f) {
      f.unmangled_name == decl_name || f.name == decl_name
    })
  {
    Ok(ir_fn) ->
      case style {
        MoonBitShim -> {
          let #(block, _) = moonbit.emit_function_scaffold(ir_fn, emit_ctx)
          append_decls_to_module_patch(project_root, mod_name, [
            #(ir_fn.unmangled_name, ir_fn.name, block),
          ])
        }
        GleamShim ->
          append_gleam_fns_for_module(project_root, ws, mod_name, [ir_fn])
      }
    Error(_) ->
      case
        list.find(ir_mod.types, fn(td) {
          td.unmangled_name == decl_name || td.name == decl_name
        })
      {
        Ok(td) ->
          case style {
            GleamShim ->
              case td.variants == [] {
                True ->
                  append_gleam_type_for_module(project_root, ws, mod_name, td)
                False ->
                  Error(
                    "Type '"
                    <> mod_name
                    <> "."
                    <> decl_name
                    <> "' already defines variants; import '"
                    <> ws.project_name
                    <> "/internal/upstream/"
                    <> mod_name
                    <> " as upstream' to construct or match it, or pass `--moonbit`",
                  )
              }
            MoonBitShim -> {
              let unpatched_td = ir.IrTypeDef(..td, external_type: None)
              let #(raw_type_src, _) =
                moonbit_decl.emit_type_def(unpatched_td, emit_ctx)
              let attr = case td.name == td.unmangled_name {
                True -> "#gekko.patch"
                False -> "#gekko.patch(\"" <> td.unmangled_name <> "\")"
              }
              let block = case raw_type_src {
                "///|\n" <> rest -> "///|\n" <> attr <> "\n" <> rest
                _ -> "///|\n" <> attr <> "\n" <> raw_type_src
              }
              append_decls_to_module_patch(project_root, mod_name, [
                #(td.unmangled_name, td.name, block),
              ])
            }
          }
        Error(_) ->
          Error(
            "Declaration '"
            <> decl_name
            <> "' was not found in module '"
            <> mod_name
            <> "'",
          )
      }
  }
}

/// Scaffold every missing `@external` function in `mod_name` into
/// `patches/<mod_name>/`.
pub fn patch_module(
  project_root: String,
  mod_name: String,
) -> Result(String, String) {
  patch_module_with_style(project_root, mod_name, MoonBitShim)
}

/// Like `patch_module`, choosing Gleam `/// @patch(...)` or MoonBit `patches/`.
pub fn patch_module_with_style(
  project_root: String,
  mod_name: String,
  style: ShimStyle,
) -> Result(String, String) {
  use ws <- result.try(load_shim_workspace(project_root))
  use ir_mod <- result.try(
    list.find(ws.ir_modules, fn(m) { m.module_name == mod_name })
    |> result.map_error(fn(_) {
      "Module '" <> mod_name <> "' was not found in loaded packages"
    }),
  )
  case style {
    MoonBitShim -> {
      let missing = collect_missing_fns(ws, [ir_mod])
      case missing {
        [] ->
          Ok(
            "No missing external functions in module '"
            <> mod_name
            <> "' (0 changes).",
          )
        _ -> {
          let decls =
            list.map(missing, fn(f) { #(f.fn_name, f.fn_name, f.stub_block) })
          append_decls_to_module_patch(project_root, mod_name, decls)
        }
      }
    }
    GleamShim -> {
      let missing_fns = list.filter(ir_mod.functions, ir_util.needs_shim)
      case missing_fns {
        [] ->
          Ok(
            "No missing external functions in module '"
            <> mod_name
            <> "' (0 changes).",
          )
        _ ->
          append_gleam_fns_for_module(project_root, ws, mod_name, missing_fns)
      }
    }
  }
}

/// Migrate single-file patches under `patches/` into package directories and
/// move non-generated `patches/**/moon.pkg` imports into `gleam.toml` under
/// `[tools.gekko.patches."<module>"]`.
pub fn migrate_shims(project_root: String) -> Result(String, String) {
  let patches_dir = filepath.join(project_root, "patches")
  use _ <- result.try(case simplifile.is_directory(patches_dir) {
    Ok(True) -> Ok(Nil)
    _ -> Error("No patches/ directory found in '" <> project_root <> "'")
  })

  let loaded_mods = case load_shim_workspace(project_root) {
    Ok(ws) ->
      ws.ir_modules
      |> list.map(fn(m) { m.module_name })
      |> set.from_list
    Error(_) -> set.new()
  }

  use moved <- result.try(
    migrate_single_file_patches(patches_dir, "", loaded_mods, []),
  )

  let pkg_name = case loader.read_project_meta(project_root) {
    Ok(#(n, _)) -> n
    Error(_) -> ""
  }
  use migrated_pkgs <- result.try(
    migrate_moon_pkg_imports(project_root, patches_dir, "", pkg_name, []),
  )

  let lines =
    list.flatten([
      list.map(moved, fn(pair) { "Moved " <> pair.0 <> " -> " <> pair.1 }),
      list.map(migrated_pkgs, fn(m) {
        "Migrated patches/" <> m <> "/moon.pkg imports -> gleam.toml"
      }),
    ])
  case lines {
    [] -> Ok("Nothing to migrate under '" <> patches_dir <> "'.")
    _ -> Ok(string.join(lines, "\n"))
  }
}

/// Record or update `patches/.gekko_baseline/<module>.toml` type baselines.
pub fn ack_shims(project_root: String) -> Result(String, String) {
  use ws <- result.try(load_shim_workspace(project_root))
  use written <- result.try(type_baseline.ack_baselines(
    project_root,
    ws.root_overlay.module_patches,
    ws.module_pkg_by_name,
    ws.ir_modules,
    ws.discovered_versions,
  ))
  case written {
    [] -> Ok("No patched modules found to baseline under patches/.")
    _ ->
      Ok(
        "Updated type baselines:\n"
        <> string.join(list.map(written, fn(p) { "  " <> p }), "\n"),
      )
  }
}

fn load_shim_workspace(project_root: String) -> Result(ShimWorkspace, String) {
  use ctx <- result.try(loader.load_project_context(project_root, False))
  let project_name = ctx.project_name
  let version = ctx.version
  let discovered_versions =
    list.fold(
      ctx.dependencies,
      dict.from_list([#(project_name, version)]),
      fn(acc, dep) { dict.insert(acc, dep.package_name, dep.version) },
    )
  use root_overlay <- result.try(ffi_config.load_package_overlay(
    project_root,
    project_name,
  ))
  use loaded_deps <- result.try(
    loader.load_discovered_dependencies_with_validation(
      project_root,
      ctx.dependencies,
      ctx.overlays.overrides,
      ctx.overlays.target_branches,
      Some(ctx.packages_hash),
      False,
    ),
  )

  let staging_dir = filepath.join(project_root, "build/.gekko_staging")
  use root_iface <- result.try(
    staging.extract_project_interface_with_packages_hash(
      project_root,
      staging_dir,
      False,
      Some(ctx.packages_hash),
    ),
  )
  let dep_modules_iface =
    list.fold(loaded_deps, dict.new(), fn(acc, dep) {
      case dep.interface {
        Some(iface) -> dict.merge(acc, iface.modules)
        None -> acc
      }
    })
  let merged_iface =
    PackageInterface(
      ..root_iface,
      modules: dict.merge(dep_modules_iface, root_iface.modules),
    )

  let src_dir = filepath.join(project_root, "src")
  use src_modules <- result.try(case simplifile.is_directory(src_dir) {
    Ok(True) -> loader.discover_and_parse(src_dir, None)
    _ -> Ok([])
  })
  let dep_tagged =
    list.flat_map(loaded_deps, fn(dep) {
      list.map(dep.modules, fn(entry) {
        let #(mod_name, ast_mod, pre) = entry
        #(dep.package_name, mod_name, ast_mod, pre)
      })
    })
  let root_tagged =
    list.map(src_modules, fn(entry) {
      let #(mod_name, ast_mod, pre) = entry
      #(project_name, mod_name, ast_mod, pre)
    })
  let all_modules = list.append(dep_tagged, root_tagged)
  let module_pkg_by_name =
    list.fold(all_modules, dict.new(), fn(acc, entry) {
      dict.insert(acc, entry.1, entry.0)
    })

  let ffi_roots =
    list.append(list.map(loaded_deps, fn(dep) { dep.package_root }), [
      project_root,
    ])
  let base_ffi_metadata =
    ffi_meta.scan_package_roots_excluding(
      ffi_roots,
      ctx.overlays.patched_source_files,
    )
  let table =
    symbol_table.index_project_with_overlays(
      project_name,
      all_modules,
      Some(merged_iface),
      ctx.overlays.overrides,
      ctx.overlays.type_overrides,
      ctx.overlays.target_branches,
      base_ffi_metadata,
    )
  let resolved_pkg_dirs =
    all_modules
    |> list.map(fn(entry) { entry.1 })
    |> pkg_config.resolve_module_pkg_dirs

  let ir_modules =
    list.map(all_modules, fn(entry) {
      let #(_, mod_name, ast_mod, _) = entry
      desugar.desugar_module(ast_mod, table, mod_name)
      |> tco.optimize_module
    })
  let project_bounds =
    trait_bounds.analyze_project(ir_modules, Some(table), base_ffi_metadata)

  Ok(ShimWorkspace(
    project_name:,
    version:,
    overlays: ctx.overlays,
    root_overlay:,
    discovered_versions:,
    all_modules:,
    module_pkg_by_name:,
    table:,
    ffi_metadata: base_ffi_metadata,
    ir_modules:,
    project_bounds:,
    resolved_pkg_dirs:,
  ))
}

fn resolve_target_pkg(
  ws: ShimWorkspace,
  target_pkg_opt: Option(String),
) -> Result(String, String) {
  case target_pkg_opt {
    Some(p) ->
      ensure_dep_present(ws, p)
      |> result.map(fn(_) { p })
    None ->
      case ws.root_overlay.shim {
        Some(meta) ->
          ensure_dep_present(ws, meta.target)
          |> result.map(fn(_) { meta.target })
        None ->
          Error(
            "Expected `<pkg>` after `gekko shim inspect` or [tools.gekko.shim_for] in gleam.toml",
          )
      }
  }
}

fn ensure_dep_present(
  ws: ShimWorkspace,
  target_pkg: String,
) -> Result(Nil, String) {
  case dict.has_key(ws.discovered_versions, target_pkg) {
    True -> Ok(Nil)
    False -> {
      let available =
        dict.keys(ws.discovered_versions)
        |> list.filter(fn(k) { k != ws.project_name })
        |> list.sort(string.compare)
        |> string.join(", ")
      let suffix = case available {
        "" -> " (no dependencies found in build/packages)"
        _ -> " (available: " <> available <> ")"
      }
      Error("Dependency '" <> target_pkg <> "' was not found" <> suffix)
    }
  }
}

fn make_emit_ctx(ws: ShimWorkspace, mod_name: String) -> moonbit_decl.EmitCtx {
  moonbit_decl.EmitCtx(
    current_module: mod_name,
    local_ctors: dict.new(),
    local_external_types: dict.new(),
    local_vars: set.new(),
    table: Some(ws.table),
    ffi_metadata: ws.ffi_metadata,
    project_bounds: ws.project_bounds,
    module_pkg_dirs: ws.resolved_pkg_dirs,
    pkg_to_alias: dict.new(),
    used_aliases: set.new(),
  )
}

fn collect_missing_fns(
  ws: ShimWorkspace,
  ir_mods: List(IrModule),
) -> List(MissingFn) {
  list.flat_map(ir_mods, fn(ir_mod) {
    let mod_name = ir_mod.module_name
    let emit_ctx = make_emit_ctx(ws, mod_name)
    list.filter_map(ir_mod.functions, fn(ir_fn) {
      case ir_util.needs_shim(ir_fn) {
        False -> Error(Nil)
        True -> {
          let #(stub_block, _) = moonbit.emit_function_scaffold(ir_fn, emit_ctx)
          Ok(MissingFn(mod_name:, fn_name: ir_fn.unmangled_name, stub_block:))
        }
      }
    })
  })
}

fn collect_unmapped_types(
  gleam_type_patches: Dict(String, prepass.GleamTypePatch),
  target_pkg: String,
  ir_mods: List(IrModule),
) -> List(UnmappedType) {
  list.flat_map(ir_mods, fn(ir_mod) {
    list.filter_map(ir_mod.types, fn(td) {
      let qual_key =
        target_pkg <> ":" <> ir_mod.module_name <> "." <> td.unmangled_name
      let short_key = ir_mod.module_name <> "." <> td.unmangled_name
      let patched_in_gleam =
        dict.has_key(gleam_type_patches, qual_key)
        || dict.has_key(gleam_type_patches, short_key)
      case td.variants == [] && td.external_type == None && !patched_in_gleam {
        True ->
          Ok(UnmappedType(
            mod_name: ir_mod.module_name,
            type_name: td.unmangled_name,
            type_params: td.type_params,
            publicity: td.publicity,
          ))
        False -> Error(Nil)
      }
    })
  })
}

fn count_gleam_type_patches(
  gleam_type_patches: Dict(String, prepass.GleamTypePatch),
  target_pkg: String,
) -> Int {
  dict.fold(gleam_type_patches, 0, fn(acc, key, _) {
    let matches_pkg =
      string.starts_with(key, target_pkg <> ":") || !string.contains(key, ":")
    case matches_pkg {
      True -> acc + 1
      False -> acc
    }
  })
}

fn count_patched_decls(
  module_patches: Dict(String, ffi_config.ModulePatch),
  target_pkg: String,
) -> #(Int, Int) {
  dict.fold(module_patches, #(0, 0), fn(acc, mod_key, patch) {
    let matches_pkg =
      string.starts_with(mod_key, target_pkg <> ":")
      || !string.contains(mod_key, ":")
    case matches_pkg {
      False -> acc
      True -> #(
        acc.0 + list.length(patch.types) + list.length(patch.type_aliases),
        acc.1 + list.length(patch.functions),
      )
    }
  })
}

fn count_patched_types(
  type_overrides: Dict(String, prepass.ExternalType),
  target_pkg: String,
) -> Int {
  dict.fold(type_overrides, 0, fn(acc, key, _) {
    let matches_pkg =
      string.starts_with(key, target_pkg <> ":") || !string.contains(key, ":")
    case matches_pkg {
      True -> acc + 1
      False -> acc
    }
  })
}

fn count_gleam_patch_decls(
  overrides: Dict(String, prepass.FfiKind),
  target_pkg: String,
) -> Int {
  dict.fold(overrides, 0, fn(acc, key, kind) {
    case kind {
      prepass.GleamPatch(_, _) -> {
        let matches_pkg =
          string.starts_with(key, target_pkg <> ":")
          || !string.contains(key, ":")
        case matches_pkg {
          True -> acc + 1
          False -> acc
        }
      }
      _ -> acc
    }
  })
}

fn count_unmatched_entries(
  ws: ShimWorkspace,
  target_pkg: String,
) -> List(String) {
  let mod_keys =
    list.fold(ws.all_modules, set.new(), fn(s, entry) {
      let #(pkg_name, mod_name, _, _) = entry
      s
      |> set.insert(pkg_name <> ":" <> mod_name)
      |> set.insert(mod_name)
    })
  let fn_keys =
    list.fold(ws.all_modules, set.new(), fn(s, entry) {
      let #(pkg_name, mod_name, _, _) = entry
      case dict.get(ws.table.modules, mod_name) {
        Error(_) -> s
        Ok(ms) ->
          dict.fold(ms.functions, s, fn(acc, fn_name, _) {
            acc
            |> set.insert(pkg_name <> ":" <> mod_name <> "." <> fn_name)
            |> set.insert(mod_name <> "." <> fn_name)
          })
      }
    })
  let ty_keys =
    list.fold(ws.all_modules, set.new(), fn(s, entry) {
      let #(pkg_name, mod_name, _, _) = entry
      case dict.get(ws.table.modules, mod_name) {
        Error(_) -> s
        Ok(ms) ->
          dict.fold(ms.types, s, fn(acc, ty_name, _) {
            acc
            |> set.insert(pkg_name <> ":" <> mod_name <> "." <> ty_name)
            |> set.insert(mod_name <> "." <> ty_name)
          })
      }
    })
  let unmatched_mods =
    dict.keys(ws.overlays.module_patches)
    |> list.filter(fn(k) {
      let for_target =
        string.starts_with(k, target_pkg <> ":") || !string.contains(k, ":")
      for_target && !set.contains(mod_keys, k)
    })
  let unmatched_gleam =
    dict.to_list(ws.overlays.overrides)
    |> list.filter_map(fn(entry) {
      let #(k, kind) = entry
      case kind {
        prepass.GleamPatch(_, _) -> {
          let for_target =
            string.starts_with(k, target_pkg <> ":") || !string.contains(k, ":")
          case for_target && !set.contains(fn_keys, k) {
            True -> Ok(k)
            False -> Error(Nil)
          }
        }
        _ -> Error(Nil)
      }
    })
  let unmatched_gleam_types =
    dict.keys(ws.overlays.gleam_type_patches)
    |> list.filter(fn(k) {
      let for_target =
        string.starts_with(k, target_pkg <> ":") || !string.contains(k, ":")
      for_target && !set.contains(ty_keys, k)
    })
  list.flatten([unmatched_mods, unmatched_gleam, unmatched_gleam_types])
  |> list.sort(string.compare)
}

// -----------------------------------------------------------------------------
// Gleam shim stub rendering (`/// @patch(...)`, `/// @patch_type(...)`)
// and upstream mirror generation (`src/<pkg>/internal/upstream/<mod>.gleam`)
// -----------------------------------------------------------------------------

type GleamRenderState {
  GleamRenderState(alias_map: Dict(String, String), used_aliases: Set(String))
}

type MirrorRenderContext {
  MirrorRenderContext(
    target_mod: String,
    mirror_mod: String,
    mirrored_types: Set(String),
  )
}

/// Regenerate all `//// @patch_mirror(...)` files found under `<project_root>/src/`.
pub fn sync_shims(project_root: String) -> Result(String, String) {
  use ws <- result.try(load_shim_workspace(project_root))
  let src_dir = filepath.join(project_root, "src")
  use rel_paths <- result.try(case simplifile.is_directory(src_dir) {
    Ok(True) -> collect_gleam_paths(src_dir, "")
    _ -> Ok([])
  })
  let mirror_entries =
    list.filter_map(list.sort(rel_paths, string.compare), fn(rel) {
      let mod_name = filepath.strip_extension(rel)
      let full = filepath.join(src_dir, rel)
      case simplifile.read(from: full) {
        Ok(src) -> {
          let res = prepass.preprocess_module(mod_name, src)
          case res.patch_mirror {
            Some(info) -> Ok(#(rel, full, info))
            None -> Error(Nil)
          }
        }
        Error(_) -> Error(Nil)
      }
    })

  case mirror_entries {
    [] -> Ok("No @patch_mirror files found in " <> src_dir <> ".")
    _ -> {
      let allowed_pkgs =
        read_allowed_gleam_packages(project_root, ws.project_name)
      use #(rev_updated, rev_unchanged) <- result.try(
        list.try_fold(mirror_entries, #([], []), fn(acc, entry) {
          let #(upd, unch) = acc
          let #(_rel, full, info) = entry
          let #(target_pkg_opt, target_mod_name) = case
            string.split_once(info.target, ":")
          {
            Ok(#(p, m)) -> #(Some(p), m)
            Error(_) -> #(None, info.target)
          }
          use ir_mod <- result.try(
            list.find(ws.ir_modules, fn(m) { m.module_name == target_mod_name })
            |> result.map_error(fn(_) {
              "Cannot sync mirror '"
              <> full
              <> "': target module '"
              <> info.target
              <> "' was not found in loaded packages"
            }),
          )
          let target_pkg = case target_pkg_opt {
            Some(p) -> p
            None ->
              dict.get(ws.module_pkg_by_name, target_mod_name)
              |> result.unwrap("")
          }
          let ast_mod_opt = find_ast_module(ws.all_modules, target_mod_name)
          case
            render_upstream_mirror(
              ws,
              target_pkg,
              ir_mod,
              ast_mod_opt,
              allowed_pkgs,
            )
          {
            Some(new_content) -> {
              let changed = simplifile.read(from: full) != Ok(new_content)
              use _ <- result.try(fs.write_text_if_changed(full, new_content))
              case changed {
                True -> Ok(#([full, ..upd], unch))
                False -> Ok(#(upd, [full, ..unch]))
              }
            }
            None ->
              Ok(#(upd, [full <> " (no mirrorable declarations)", ..unch]))
          }
        }),
      )
      let lines = case list.reverse(rev_updated) {
        [] -> ["All @patch_mirror files are already up to date:"]
        upds ->
          list.append(
            ["Updated @patch_mirror file(s):"],
            list.map(upds, fn(p) { "  " <> p }),
          )
      }
      let unch_lines = case list.reverse(rev_unchanged) {
        [] -> []
        unch ->
          list.append(
            ["Unchanged @patch_mirror file(s):"],
            list.map(unch, fn(p) { "  " <> p }),
          )
      }
      Ok(string.join(list.append(lines, unch_lines), "\n"))
    }
  }
}

fn collect_gleam_paths(
  base_dir: String,
  rel_prefix: String,
) -> Result(List(String), String) {
  let current = case rel_prefix {
    "" -> base_dir
    _ -> filepath.join(base_dir, rel_prefix)
  }
  use entries <- result.try(
    simplifile.read_directory(at: current)
    |> result.map_error(fn(err) {
      "Failed to read directory '"
      <> current
      <> "': "
      <> simplifile.describe_error(err)
    }),
  )
  list.try_fold(entries, [], fn(acc, entry) {
    case fs.is_ignored_entry(entry) {
      True -> Ok(acc)
      False -> {
        let rel = case rel_prefix {
          "" -> entry
          _ -> filepath.join(rel_prefix, entry)
        }
        let full = filepath.join(base_dir, rel)
        case simplifile.is_directory(full) {
          Ok(True) -> {
            use nested <- result.try(collect_gleam_paths(base_dir, rel))
            Ok(list.append(acc, nested))
          }
          Ok(False) ->
            case string.ends_with(entry, ".gleam") {
              True -> Ok([rel, ..acc])
              False -> Ok(acc)
            }
          Error(err) ->
            Error(
              "Failed to stat '"
              <> full
              <> "': "
              <> simplifile.describe_error(err),
            )
        }
      }
    }
  })
}

fn read_allowed_gleam_packages(
  project_root: String,
  project_name: String,
) -> Set(String) {
  let base = set.from_list(["", "gleam", project_name])
  let toml_path = filepath.join(project_root, "gleam.toml")
  case simplifile.read(from: toml_path) {
    Error(_) -> base
    Ok(content) ->
      case tom.parse(content) {
        Error(_) -> base
        Ok(parsed) -> {
          let add_table_keys = fn(acc, path) {
            case tom.get_table(parsed, path) {
              Ok(tbl) -> list.fold(dict.keys(tbl), acc, set.insert)
              Error(_) -> acc
            }
          }
          base
          |> add_table_keys(["dependencies"])
          |> add_table_keys(["dev-dependencies"])
        }
      }
  }
}

fn find_ast_module(
  all_modules: List(#(String, String, glance.Module, PrepassResult)),
  mod_name: String,
) -> Option(glance.Module) {
  list.find(all_modules, fn(entry) { entry.1 == mod_name })
  |> option.from_result
  |> option.map(fn(entry) { entry.2 })
}

fn mirrored_type_names_for_mod(ir_mod: IrModule) -> Set(String) {
  let from_types =
    list.fold(ir_mod.types, set.new(), fn(acc, td) {
      case
        td.publicity == glance.Private || { td.opaque_ && td.variants != [] }
      {
        True -> set.insert(acc, td.unmangled_name)
        False -> acc
      }
    })
  list.fold(ir_mod.type_aliases, from_types, fn(acc, ta) {
    case ta.publicity == glance.Private {
      True -> set.insert(acc, ta.name)
      False -> acc
    }
  })
}

fn gleam_patch_target_string(
  ws: ShimWorkspace,
  mod_name: String,
  decl_unmangled_name: String,
) -> String {
  let mod_pkg = dict.get(ws.module_pkg_by_name, mod_name) |> result.unwrap("")
  let use_short = case ws.root_overlay.shim {
    Some(meta) if meta.target == mod_pkg -> True
    _ -> False
  }
  case use_short || mod_pkg == "" {
    True -> mod_name <> "." <> decl_unmangled_name
    False -> mod_pkg <> ":" <> mod_name <> "." <> decl_unmangled_name
  }
}

fn render_new_gleam_shim_files(
  ws: ShimWorkspace,
  shim_name: String,
  target_pkg: String,
  target_ir_mods: List(IrModule),
) -> List(#(String, String)) {
  let allowed_pkgs = set.from_list(["", "gleam", shim_name, target_pkg])
  target_ir_mods
  |> list.flat_map(fn(ir_mod) {
    let missing_fns = list.filter(ir_mod.functions, ir_util.needs_shim)
    case missing_fns {
      [] -> []
      _ -> {
        let ast_mod_opt = find_ast_module(ws.all_modules, ir_mod.module_name)
        let mirror_mod =
          shim_name <> "/internal/upstream/" <> ir_mod.module_name
        let mirrored_types = mirrored_type_names_for_mod(ir_mod)
        let mirror_ctx =
          Some(MirrorRenderContext(
            target_mod: ir_mod.module_name,
            mirror_mod:,
            mirrored_types:,
          ))
        let mirror_opt =
          render_upstream_mirror(
            ws,
            target_pkg,
            ir_mod,
            ast_mod_opt,
            allowed_pkgs,
          )
        let init_st = GleamRenderState(dict.new(), set.new())
        let #(_, blocks_rev, final_st) =
          list.fold(missing_fns, #(set.new(), [], init_st), fn(acc, ir_fn) {
            let #(used_names, b_acc, st) = acc
            let target_str = ir_mod.module_name <> "." <> ir_fn.unmangled_name
            let #(local_name, next_used) =
              pick_gleam_fn_name(ir_fn.unmangled_name, used_names, 0)
            let #(block, next_st) =
              render_gleam_fn_stub(
                ir_fn,
                local_name,
                target_str,
                ir_mod.module_name,
                ws.table,
                mirror_ctx,
                st,
              )
            #(next_used, [block, ..b_acc], next_st)
          })
        let imports_block =
          render_gleam_import_lines(final_st.alias_map, set.new())
        let body = case imports_block {
          [] -> string.join(list.reverse(blocks_rev), "\n\n") <> "\n"
          _ ->
            string.join(imports_block, "\n")
            <> "\n\n"
            <> string.join(list.reverse(blocks_rev), "\n\n")
            <> "\n"
        }
        let shim_file = #(
          "src/" <> shim_name <> "/" <> ir_mod.module_name <> ".gleam",
          body,
        )
        case mirror_opt {
          Some(mirror_src) -> [
            #("src/" <> mirror_mod <> ".gleam", mirror_src),
            shim_file,
          ]
          None -> [shim_file]
        }
      }
    }
  })
}

fn append_gleam_fns_for_module(
  project_root: String,
  ws: ShimWorkspace,
  mod_name: String,
  target_fns: List(ir.IrFunction),
) -> Result(String, String) {
  let rel_mod = ws.project_name <> "/shims/" <> mod_name
  let target_path = filepath.join(project_root, "src/" <> rel_mod <> ".gleam")
  let existing = case simplifile.read(from: target_path) {
    Ok(c) -> c
    Error(_) -> ""
  }
  let pre = prepass.preprocess_module(rel_mod, existing)
  let existing_targets =
    list.fold(pre.gleam_patches, set.new(), fn(acc, entry) {
      let short = case string.split_once(entry.target, ":") {
        Ok(#(_, rhs)) -> rhs
        Error(_) -> entry.target
      }
      acc |> set.insert(entry.target) |> set.insert(short)
    })

  let #(existing_imports, init_st, existing_fn_names) =
    parse_existing_gleam_file_state(existing, pre)

  let mirror_mod = ws.project_name <> "/internal/upstream/" <> mod_name
  let ir_mod_opt =
    list.find(ws.ir_modules, fn(m) { m.module_name == mod_name })
    |> option.from_result
  let mirror_ctx = case ir_mod_opt {
    Some(ir_mod) ->
      Some(MirrorRenderContext(
        target_mod: mod_name,
        mirror_mod:,
        mirrored_types: mirrored_type_names_for_mod(ir_mod),
      ))
    None -> None
  }

  let maybe_write_mirror = case ir_mod_opt {
    None -> Ok(None)
    Some(ir_mod) -> {
      let target_pkg =
        dict.get(ws.module_pkg_by_name, mod_name) |> result.unwrap("")
      let allowed_pkgs =
        read_allowed_gleam_packages(project_root, ws.project_name)
        |> set.insert(target_pkg)
      let ast_mod_opt = find_ast_module(ws.all_modules, mod_name)
      case
        render_upstream_mirror(
          ws,
          target_pkg,
          ir_mod,
          ast_mod_opt,
          allowed_pkgs,
        )
      {
        None -> Ok(None)
        Some(mirror_src) -> {
          let mirror_path =
            filepath.join(project_root, "src/" <> mirror_mod <> ".gleam")
          use _ <- result.try(fs.write_text_if_changed(mirror_path, mirror_src))
          Ok(Some(mirror_path))
        }
      }
    }
  }
  use written_mirror_opt <- result.try(maybe_write_mirror)

  let #(_, rev_blocks, added_names, final_st) =
    list.fold(target_fns, #(existing_fn_names, [], [], init_st), fn(acc, ir_fn) {
      let #(used_names, b_acc, n_acc, st) = acc
      let target_str =
        gleam_patch_target_string(ws, mod_name, ir_fn.unmangled_name)
      let short_key = mod_name <> "." <> ir_fn.unmangled_name
      case
        set.contains(existing_targets, target_str)
        || set.contains(existing_targets, short_key)
      {
        True -> acc
        False -> {
          let #(local_name, next_used) =
            pick_gleam_fn_name(ir_fn.unmangled_name, used_names, 0)
          let #(block, next_st) =
            render_gleam_fn_stub(
              ir_fn,
              local_name,
              target_str,
              mod_name,
              ws.table,
              mirror_ctx,
              st,
            )
          #(
            next_used,
            [block, ..b_acc],
            [mod_name <> "." <> ir_fn.unmangled_name, ..n_acc],
            next_st,
          )
        }
      }
    })

  case rev_blocks {
    [] -> Ok("Already patched in " <> target_path <> " (0 changes).")
    _ -> {
      let new_import_lines =
        render_gleam_import_lines(final_st.alias_map, existing_imports)
      let with_imports = insert_gleam_imports(existing, new_import_lines)
      let sep = case with_imports {
        "" -> ""
        _ ->
          case
            string.ends_with(with_imports, "\n\n"),
            string.ends_with(with_imports, "\n")
          {
            True, _ -> ""
            False, True -> "\n"
            False, False -> "\n\n"
          }
      }
      let blocks_str = string.join(list.reverse(rev_blocks), "\n\n")
      let next_content = with_imports <> sep <> blocks_str <> "\n"
      use _ <- result.try(fs.write_text(target_path, next_content))
      let mirror_note = case written_mirror_opt {
        Some(mp) -> " (mirror: " <> mp <> ")"
        None -> ""
      }
      Ok(
        "Scaffolded into "
        <> target_path
        <> ": "
        <> string.join(list.reverse(added_names), ", ")
        <> mirror_note,
      )
    }
  }
}

fn append_gleam_type_for_module(
  project_root: String,
  ws: ShimWorkspace,
  mod_name: String,
  td: ir.IrTypeDef,
) -> Result(String, String) {
  let rel_mod = ws.project_name <> "/shims/" <> mod_name
  let target_path = filepath.join(project_root, "src/" <> rel_mod <> ".gleam")
  let existing = case simplifile.read(from: target_path) {
    Ok(c) -> c
    Error(_) -> ""
  }
  let pre = prepass.preprocess_module(rel_mod, existing)
  let target_str = gleam_patch_target_string(ws, mod_name, td.unmangled_name)
  let short_key = mod_name <> "." <> td.unmangled_name
  let already_patched =
    list.any(pre.gleam_type_patches, fn(entry) {
      entry.target == target_str || entry.target == short_key
    })
  case already_patched {
    True -> Ok("Already patched in " <> target_path <> " (0 changes).")
    False -> {
      let params_str = case td.type_params {
        [] -> ""
        ps -> "(" <> string.join(list.map(ps, string.lowercase), ", ") <> ")"
      }
      let block =
        "/// @patch_type(\""
        <> target_str
        <> "\")\npub type "
        <> td.unmangled_name
        <> params_str
        <> " {\n  "
        <> td.unmangled_name
        <> "\n}"
      let sep = case existing {
        "" -> ""
        _ ->
          case
            string.ends_with(existing, "\n\n"),
            string.ends_with(existing, "\n")
          {
            True, _ -> ""
            False, True -> "\n"
            False, False -> "\n\n"
          }
      }
      use _ <- result.try(fs.write_text(
        target_path,
        existing <> sep <> block <> "\n",
      ))
      Ok(
        "Scaffolded into "
        <> target_path
        <> ": "
        <> mod_name
        <> "."
        <> td.unmangled_name,
      )
    }
  }
}

fn parse_existing_gleam_file_state(
  existing: String,
  pre: PrepassResult,
) -> #(set.Set(String), GleamRenderState, set.Set(String)) {
  case existing {
    "" -> #(set.new(), GleamRenderState(dict.new(), set.new()), set.new())
    _ ->
      case glance.module(pre.cleaned_source) {
        Error(_) -> #(
          set.new(),
          GleamRenderState(dict.new(), set.new()),
          set.new(),
        )
        Ok(ast) -> {
          let #(imp_mods, alias_map, used_aliases) =
            list.fold(
              ast.imports,
              #(set.new(), dict.new(), set.new()),
              fn(acc, def) {
                let #(mods, am, ua) = acc
                let imp = def.definition
                case imp.alias {
                  Some(glance.Discarded(_)) -> acc
                  Some(glance.Named(a)) -> #(
                    set.insert(mods, imp.module),
                    dict.insert(am, imp.module, a),
                    set.insert(ua, a),
                  )
                  None -> {
                    let base = filepath.base_name(imp.module)
                    #(
                      set.insert(mods, imp.module),
                      dict.insert(am, imp.module, base),
                      set.insert(ua, base),
                    )
                  }
                }
              },
            )
          let fn_names =
            list.fold(ast.functions, set.new(), fn(acc, def) {
              set.insert(acc, def.definition.name)
            })
          #(imp_mods, GleamRenderState(alias_map, used_aliases), fn_names)
        }
      }
  }
}

fn pick_gleam_fn_name(
  base: String,
  used: set.Set(String),
  attempt: Int,
) -> #(String, set.Set(String)) {
  let candidate = case attempt {
    0 -> base
    1 -> base <> "_impl"
    _ -> base <> "_impl_" <> int.to_string(attempt)
  }
  case set.contains(used, candidate) {
    False -> #(candidate, set.insert(used, candidate))
    True -> pick_gleam_fn_name(base, used, attempt + 1)
  }
}

fn render_gleam_fn_stub(
  ir_fn: ir.IrFunction,
  local_name: String,
  patch_target: String,
  mod_name: String,
  table: SymbolTable,
  mirror_ctx: Option(MirrorRenderContext),
  st: GleamRenderState,
) -> #(String, GleamRenderState) {
  let #(#(rev_params, st1), _) =
    list.index_fold(ir_fn.params, #(#([], st), 0), fn(acc, p, idx) {
      let #(#(ps, cur_st), _) = acc
      let #(ty_str, next_st) =
        render_gleam_type(p.param_type, mod_name, table, mirror_ctx, cur_st)
      let p_name = case p.name {
        "_" -> "_arg_" <> int.to_string(idx)
        n -> n
      }
      #(#([p_name <> ": " <> ty_str, ..ps], next_st), idx + 1)
    })
  let #(ret_str, st2) =
    render_gleam_type(ir_fn.return_type, mod_name, table, mirror_ctx, st1)
  let params_str = string.join(list.reverse(rev_params), ", ")
  let block =
    "/// @patch(\""
    <> patch_target
    <> "\")\npub fn "
    <> local_name
    <> "("
    <> params_str
    <> ") -> "
    <> ret_str
    <> " {\n  todo\n}"
  #(block, st2)
}

fn render_gleam_type(
  ty: ir.IrType,
  cur_mod: String,
  table: SymbolTable,
  mirror_ctx: Option(MirrorRenderContext),
  st: GleamRenderState,
) -> #(String, GleamRenderState) {
  case ty {
    ir.IrTypeInt64 -> #("Int", st)
    ir.IrTypeDouble -> #("Float", st)
    ir.IrTypeString -> #("String", st)
    ir.IrTypeBool -> #("Bool", st)
    ir.IrTypeUnit -> #("Nil", st)
    ir.IrTypeBitArray -> #("BitArray", st)
    ir.IrTypeVar(v) -> #(string.lowercase(v), st)
    ir.IrTypeList(inner) -> {
      let #(in_str, st1) =
        render_gleam_type(inner, cur_mod, table, mirror_ctx, st)
      #("List(" <> in_str <> ")", st1)
    }
    ir.IrTypeResult(ok_t, err_t) -> {
      let #(o_str, st1) =
        render_gleam_type(ok_t, cur_mod, table, mirror_ctx, st)
      let #(e_str, st2) =
        render_gleam_type(err_t, cur_mod, table, mirror_ctx, st1)
      #("Result(" <> o_str <> ", " <> e_str <> ")", st2)
    }
    ir.IrTypeTuple(els) -> {
      let #(rev_s, st1) =
        list.fold(els, #([], st), fn(acc, el) {
          let #(es, c_st) = acc
          let #(s, n_st) =
            render_gleam_type(el, cur_mod, table, mirror_ctx, c_st)
          #([s, ..es], n_st)
        })
      #("#(" <> string.join(list.reverse(rev_s), ", ") <> ")", st1)
    }
    ir.IrTypeFn(params, ret) -> {
      let #(rev_s, st1) =
        list.fold(params, #([], st), fn(acc, p) {
          let #(ps, c_st) = acc
          let #(s, n_st) =
            render_gleam_type(p, cur_mod, table, mirror_ctx, c_st)
          #([s, ..ps], n_st)
        })
      let #(r_str, st2) =
        render_gleam_type(ret, cur_mod, table, mirror_ctx, st1)
      #(
        "fn(" <> string.join(list.reverse(rev_s), ", ") <> ") -> " <> r_str,
        st2,
      )
    }
    ir.IrTypeNamed(module:, name:, args:, ..) -> {
      let resolved_mod = case module {
        "" -> cur_mod
        m -> m
      }
      case resolved_mod, name {
        "gleam", "UtfCodepoint" -> #("UtfCodepoint", st)
        "gleam", "Dynamic" -> {
          let #(alias, st1) = register_gleam_import("gleam/dynamic", st)
          #(alias <> ".Dynamic", st1)
        }
        _, _ -> {
          let #(unmangled_name, _is_priv) =
            lookup_gleam_type_info(table, resolved_mod, name)
          let #(alias, st1) = case mirror_ctx {
            Some(mc) if resolved_mod == mc.target_mod ->
              case set.contains(mc.mirrored_types, unmangled_name) {
                True -> register_gleam_import_as(mc.mirror_mod, "upstream", st)
                False -> register_gleam_import(resolved_mod, st)
              }
            _ -> register_gleam_import(resolved_mod, st)
          }
          let #(rev_args, st2) =
            list.fold(args, #([], st1), fn(acc, arg) {
              let #(as_acc, c_st) = acc
              let #(s, n_st) =
                render_gleam_type(arg, cur_mod, table, mirror_ctx, c_st)
              #([s, ..as_acc], n_st)
            })
          let suffix = case args {
            [] -> ""
            _ -> "(" <> string.join(list.reverse(rev_args), ", ") <> ")"
          }
          #(alias <> "." <> unmangled_name <> suffix, st2)
        }
      }
    }
  }
}

fn register_gleam_import_as(
  mod_name: String,
  preferred_alias: String,
  st: GleamRenderState,
) -> #(String, GleamRenderState) {
  case dict.get(st.alias_map, mod_name) {
    Ok(existing) -> #(existing, st)
    Error(_) -> {
      let chosen = pick_unique_gleam_alias(preferred_alias, st.used_aliases, 0)
      #(
        chosen,
        GleamRenderState(
          alias_map: dict.insert(st.alias_map, mod_name, chosen),
          used_aliases: set.insert(st.used_aliases, chosen),
        ),
      )
    }
  }
}

fn render_upstream_mirror(
  ws: ShimWorkspace,
  target_pkg: String,
  ir_mod: IrModule,
  ast_mod_opt: Option(glance.Module),
  allowed_pkgs: Set(String),
) -> Option(String) {
  let mirrored_names = mirrored_type_names_for_mod(ir_mod)
  let init_st = GleamRenderState(alias_map: dict.new(), used_aliases: set.new())

  let #(type_blocks, st1) =
    list.fold(ir_mod.types, #([], init_st), fn(acc, td) {
      let #(blocks, st) = acc
      case
        td.publicity == glance.Private || { td.opaque_ && td.variants != [] }
      {
        False -> acc
        True -> {
          let attr = case td.publicity == glance.Private {
            True -> "/// @mirror_type(\"" <> td.unmangled_name <> "\")"
            False -> "/// @mirror_opaque(\"" <> td.unmangled_name <> "\")"
          }
          let params = case td.type_params {
            [] -> ""
            ps ->
              "(" <> string.join(list.map(ps, string.lowercase), ", ") <> ")"
          }
          let variants_res =
            list.try_fold(td.variants, #([], st), fn(v_acc, v) {
              let #(v_lines, cur_st) = v_acc
              case v.fields {
                [] -> Ok(#(["  " <> v.name, ..v_lines], cur_st))
                _ -> {
                  use #(rev_fields, next_st) <- result.try(
                    list.try_fold(v.fields, #([], cur_st), fn(f_acc, fld) {
                      let #(f_strs, fst) = f_acc
                      use #(ty_s, n_fst) <- result.try(render_mirror_type(
                        fld.field_type,
                        ir_mod.module_name,
                        ws,
                        mirrored_names,
                        allowed_pkgs,
                        fst,
                      ))
                      let f_str = case fld.unmangled_label {
                        Some(lbl) -> lbl <> ": " <> ty_s
                        None -> ty_s
                      }
                      Ok(#([f_str, ..f_strs], n_fst))
                    }),
                  )
                  Ok(#(
                    [
                      "  "
                        <> v.name
                        <> "("
                        <> string.join(list.reverse(rev_fields), ", ")
                        <> ")",
                      ..v_lines
                    ],
                    next_st,
                  ))
                }
              }
            })
          case variants_res {
            Error(skip_reason) -> {
              let msg =
                "// Skipped "
                <> td.unmangled_name
                <> ": references unavailable dependency ("
                <> skip_reason
                <> ")"
              #([msg, ..blocks], st)
            }
            Ok(#([], next_st)) -> {
              let blk = attr <> "\npub type " <> td.unmangled_name <> params
              #([blk, ..blocks], next_st)
            }
            Ok(#(rev_vlines, next_st)) -> {
              let blk =
                attr
                <> "\npub type "
                <> td.unmangled_name
                <> params
                <> " {\n"
                <> string.join(list.reverse(rev_vlines), "\n")
                <> "\n}"
              #([blk, ..blocks], next_st)
            }
          }
        }
      }
    })

  let #(alias_blocks, st2) =
    list.fold(ir_mod.type_aliases, #(type_blocks, st1), fn(acc, ta) {
      let #(blocks, st) = acc
      case ta.publicity == glance.Private {
        False -> acc
        True -> {
          let params = case ta.type_params {
            [] -> ""
            ps ->
              "(" <> string.join(list.map(ps, string.lowercase), ", ") <> ")"
          }
          case
            render_mirror_type(
              ta.aliased,
              ir_mod.module_name,
              ws,
              mirrored_names,
              allowed_pkgs,
              st,
            )
          {
            Error(skip_reason) -> #(
              [
                "// Skipped alias "
                  <> ta.name
                  <> ": references unavailable dependency ("
                  <> skip_reason
                  <> ")",
                ..blocks
              ],
              st,
            )
            Ok(#(rhs_str, next_st)) -> {
              let blk =
                "/// @mirror_type(\""
                <> ta.name
                <> "\")\npub type "
                <> ta.name
                <> params
                <> " = "
                <> rhs_str
              #([blk, ..blocks], next_st)
            }
          }
        }
      }
    })

  let used_local_fns =
    list.fold(ir_mod.functions, set.new(), fn(acc, f) {
      case f.publicity == glance.Private {
        True -> set.insert(acc, f.unmangled_name)
        False -> acc
      }
    })

  let #(_, opaque_blocks, st3) =
    list.fold(ir_mod.types, #(used_local_fns, alias_blocks, st2), fn(acc, td) {
      let #(used_names, blocks, st) = acc
      case td.publicity == glance.Public && td.opaque_ && td.variants != [] {
        False -> acc
        True -> {
          let snake = camel_to_snake(td.unmangled_name)
          let #(to_name, used1) =
            pick_gleam_fn_name("to_" <> snake, used_names, 0)
          let #(from_name, used2) =
            pick_gleam_fn_name("from_" <> snake, used1, 0)
          let target_base = "target_" <> filepath.base_name(ir_mod.module_name)
          let #(target_alias, st_imp) =
            register_gleam_import_as(ir_mod.module_name, target_base, st)
          let suffix = case td.type_params {
            [] -> ""
            ps ->
              "(" <> string.join(list.map(ps, string.lowercase), ", ") <> ")"
          }
          let local_ty = td.unmangled_name <> suffix
          let pub_ty = target_alias <> "." <> td.unmangled_name <> suffix
          let to_blk =
            "/// @mirror_to_public(\""
            <> td.unmangled_name
            <> "\")\npub fn "
            <> to_name
            <> "(value: "
            <> local_ty
            <> ") -> "
            <> pub_ty
            <> " {\n  let _ = value\n  panic as \"gekko @patch_mirror stub\"\n}"
          let from_blk =
            "/// @mirror_from_public(\""
            <> td.unmangled_name
            <> "\")\npub fn "
            <> from_name
            <> "(value: "
            <> pub_ty
            <> ") -> "
            <> local_ty
            <> " {\n  let _ = value\n  panic as \"gekko @patch_mirror stub\"\n}"
          #(used2, [from_blk, to_blk, ..blocks], st_imp)
        }
      }
    })

  let #(const_blocks, st4) =
    list.fold(ir_mod.constants, #(opaque_blocks, st3), fn(acc, c) {
      let #(blocks, st) = acc
      case c.publicity == glance.Private {
        False -> acc
        True ->
          case
            render_mirror_type(
              c.value_type,
              ir_mod.module_name,
              ws,
              mirrored_names,
              allowed_pkgs,
              st,
            )
          {
            Error(skip_reason) -> #(
              [
                "// Skipped private const "
                  <> c.unmangled_name
                  <> ": references unavailable dependency ("
                  <> skip_reason
                  <> ")",
                ..blocks
              ],
              st,
            )
            Ok(#(ty_str, next_st)) -> {
              let blk = case render_mirror_dummy_const(c.value_type) {
                Some(dummy) ->
                  "/// @mirror_const(\""
                  <> c.unmangled_name
                  <> "\")\npub const "
                  <> c.unmangled_name
                  <> ": "
                  <> ty_str
                  <> " = "
                  <> dummy
                None ->
                  "/// @mirror_const(\""
                  <> c.unmangled_name
                  <> "\")\npub fn "
                  <> c.unmangled_name
                  <> "() -> "
                  <> ty_str
                  <> " {\n  panic as \"gekko @patch_mirror stub\"\n}"
              }
              #([blk, ..blocks], next_st)
            }
          }
      }
    })

  let ast_fn_by_name = case ast_mod_opt {
    Some(ast_mod) ->
      list.fold(ast_mod.functions, dict.new(), fn(acc, def) {
        dict.insert(acc, def.definition.name, def.definition)
      })
    None -> dict.new()
  }

  let #(all_blocks_rev, final_st) =
    list.fold(ir_mod.functions, #(const_blocks, st4), fn(acc, f) {
      let #(blocks, st) = acc
      case f.publicity == glance.Private {
        False -> acc
        True -> {
          let ast_params = case dict.get(ast_fn_by_name, f.unmangled_name) {
            Ok(ast_fn) -> ast_fn.parameters
            Error(_) -> []
          }
          let params_res =
            render_mirror_fn_params(
              f.params,
              ast_params,
              ir_mod.module_name,
              ws,
              mirrored_names,
              allowed_pkgs,
              st,
            )
          case params_res {
            Error(skip_reason) -> #(
              [
                "// Skipped private fn "
                  <> f.unmangled_name
                  <> ": references unavailable dependency ("
                  <> skip_reason
                  <> ")",
                ..blocks
              ],
              st,
            )
            Ok(#(param_strs, bind_stmts, st_after_p)) ->
              case
                render_mirror_type(
                  f.return_type,
                  ir_mod.module_name,
                  ws,
                  mirrored_names,
                  allowed_pkgs,
                  st_after_p,
                )
              {
                Error(skip_reason) -> #(
                  [
                    "// Skipped private fn "
                      <> f.unmangled_name
                      <> ": references unavailable dependency ("
                      <> skip_reason
                      <> ")",
                    ..blocks
                  ],
                  st,
                )
                Ok(#(ret_str, next_st)) -> {
                  let body_lines =
                    list.append(bind_stmts, [
                      "  panic as \"gekko @patch_mirror stub\"",
                    ])
                  let blk =
                    "/// @mirror_fn(\""
                    <> f.unmangled_name
                    <> "\")\npub fn "
                    <> f.unmangled_name
                    <> "("
                    <> string.join(param_strs, ", ")
                    <> ") -> "
                    <> ret_str
                    <> " {\n"
                    <> string.join(body_lines, "\n")
                    <> "\n}"
                  #([blk, ..blocks], next_st)
                }
              }
          }
        }
      }
    })

  case all_blocks_rev {
    [] -> None
    _ -> {
      let target_spec = case target_pkg {
        "" -> ir_mod.module_name
        p -> p <> ":" <> ir_mod.module_name
      }
      let header =
        "//// @patch_mirror(\""
        <> target_spec
        <> "\")\n////\n//// Auto-generated by `gekko shim`. Do not edit manually.\n//// Run `gekko shim sync` if upstream private or opaque declarations change."
      let imports_block =
        render_gleam_import_lines(final_st.alias_map, set.new())
      let sections = case imports_block {
        [] -> [header, ..list.reverse(all_blocks_rev)]
        _ -> [
          header,
          string.join(imports_block, "\n"),
          ..list.reverse(all_blocks_rev)
        ]
      }
      Some(string.join(sections, "\n\n") <> "\n")
    }
  }
}

fn render_mirror_fn_params(
  ir_params: List(ir.IrParam),
  ast_params: List(glance.FunctionParameter),
  cur_mod: String,
  ws: ShimWorkspace,
  mirrored_names: Set(String),
  allowed_pkgs: Set(String),
  st: GleamRenderState,
) -> Result(#(List(String), List(String), GleamRenderState), String) {
  let has_exact_ast = list.length(ir_params) == list.length(ast_params)
  let paired = case has_exact_ast {
    True ->
      list.zip(ir_params, ast_params)
      |> list.map(fn(p) { #(p.0, Some(p.1)) })
    False -> list.map(ir_params, fn(p) { #(p, None) })
  }
  use #(#(rev_p, rev_b, final_st), _) <- result.try(
    list.try_fold(paired, #(#([], [], st), 0), fn(acc, item) {
      let #(#(p_acc, b_acc, cur_st), idx) = acc
      let #(ip, ap_opt) = item
      use #(ty_str, next_st) <- result.try(render_mirror_type(
        ip.param_type,
        cur_mod,
        ws,
        mirrored_names,
        allowed_pkgs,
        cur_st,
      ))
      let #(sig_name, maybe_bind) = case ap_opt {
        Some(ap) -> {
          let #(local_n, need_bind) = case ap.name {
            glance.Named(n) -> #(n, True)
            glance.Discarded(d) ->
              case d {
                "" -> #("_arg_" <> int.to_string(idx), False)
                _ -> #("_" <> d, False)
              }
          }
          let full_sig = case ap.label {
            Some(lbl) -> lbl <> " " <> local_n
            None -> local_n
          }
          let bind = case need_bind {
            True -> Some("  let _ = " <> local_n)
            False -> None
          }
          #(full_sig, bind)
        }
        None -> {
          let #(local_n, need_bind) = case ip.name {
            "_" -> #("_arg_" <> int.to_string(idx), False)
            n -> #(n, True)
          }
          let full_sig = case ip.label {
            Some(lbl) -> lbl <> " " <> local_n
            None -> local_n
          }
          let bind = case need_bind {
            True -> Some("  let _ = " <> local_n)
            False -> None
          }
          #(full_sig, bind)
        }
      }
      let next_b = case maybe_bind {
        Some(stmt) -> [stmt, ..b_acc]
        None -> b_acc
      }
      Ok(#(#([sig_name <> ": " <> ty_str, ..p_acc], next_b, next_st), idx + 1))
    }),
  )
  Ok(#(list.reverse(rev_p), list.reverse(rev_b), final_st))
}

fn render_mirror_type(
  ty: ir.IrType,
  cur_mod: String,
  ws: ShimWorkspace,
  mirrored_names: Set(String),
  allowed_pkgs: Set(String),
  st: GleamRenderState,
) -> Result(#(String, GleamRenderState), String) {
  case ty {
    ir.IrTypeInt64 -> Ok(#("Int", st))
    ir.IrTypeDouble -> Ok(#("Float", st))
    ir.IrTypeString -> Ok(#("String", st))
    ir.IrTypeBool -> Ok(#("Bool", st))
    ir.IrTypeUnit -> Ok(#("Nil", st))
    ir.IrTypeBitArray -> Ok(#("BitArray", st))
    ir.IrTypeVar(v) -> Ok(#(string.lowercase(v), st))
    ir.IrTypeList(inner) -> {
      use #(in_str, st1) <- result.try(render_mirror_type(
        inner,
        cur_mod,
        ws,
        mirrored_names,
        allowed_pkgs,
        st,
      ))
      Ok(#("List(" <> in_str <> ")", st1))
    }
    ir.IrTypeResult(ok_t, err_t) -> {
      use #(o_str, st1) <- result.try(render_mirror_type(
        ok_t,
        cur_mod,
        ws,
        mirrored_names,
        allowed_pkgs,
        st,
      ))
      use #(e_str, st2) <- result.try(render_mirror_type(
        err_t,
        cur_mod,
        ws,
        mirrored_names,
        allowed_pkgs,
        st1,
      ))
      Ok(#("Result(" <> o_str <> ", " <> e_str <> ")", st2))
    }
    ir.IrTypeTuple(els) -> {
      use #(rev_s, st1) <- result.try(
        list.try_fold(els, #([], st), fn(acc, el) {
          let #(es, c_st) = acc
          use #(s, n_st) <- result.try(render_mirror_type(
            el,
            cur_mod,
            ws,
            mirrored_names,
            allowed_pkgs,
            c_st,
          ))
          Ok(#([s, ..es], n_st))
        }),
      )
      Ok(#("#(" <> string.join(list.reverse(rev_s), ", ") <> ")", st1))
    }
    ir.IrTypeFn(params, ret) -> {
      use #(rev_s, st1) <- result.try(
        list.try_fold(params, #([], st), fn(acc, p) {
          let #(ps, c_st) = acc
          use #(s, n_st) <- result.try(render_mirror_type(
            p,
            cur_mod,
            ws,
            mirrored_names,
            allowed_pkgs,
            c_st,
          ))
          Ok(#([s, ..ps], n_st))
        }),
      )
      use #(r_str, st2) <- result.try(render_mirror_type(
        ret,
        cur_mod,
        ws,
        mirrored_names,
        allowed_pkgs,
        st1,
      ))
      Ok(#(
        "fn(" <> string.join(list.reverse(rev_s), ", ") <> ") -> " <> r_str,
        st2,
      ))
    }
    ir.IrTypeNamed(module:, name:, args:, ..) -> {
      let resolved_mod = case module {
        "" -> cur_mod
        m -> m
      }
      case resolved_mod, name {
        "gleam", "UtfCodepoint" -> Ok(#("UtfCodepoint", st))
        "gleam", "Dynamic" ->
          case set.contains(allowed_pkgs, "gleam_stdlib") {
            True -> {
              let #(alias, st1) = register_gleam_import("gleam/dynamic", st)
              Ok(#(alias <> ".Dynamic", st1))
            }
            False -> Error("gleam_stdlib")
          }
        _, _ -> {
          let #(unmangled_name, is_priv) =
            lookup_gleam_type_info(ws.table, resolved_mod, name)
          use #(head, st1) <- result.try(case resolved_mod == cur_mod {
            True ->
              case set.contains(mirrored_names, unmangled_name) {
                True -> Ok(#(unmangled_name, st))
                False -> {
                  let target_base = "target_" <> filepath.base_name(cur_mod)
                  let #(alias, s1) =
                    register_gleam_import_as(cur_mod, target_base, st)
                  Ok(#(alias <> "." <> unmangled_name, s1))
                }
              }
            False -> {
              let pkg =
                dict.get(ws.module_pkg_by_name, resolved_mod)
                |> result.unwrap("")
              case set.contains(allowed_pkgs, pkg), is_priv {
                False, _ -> Error(pkg)
                True, True ->
                  Error(
                    "private type " <> resolved_mod <> "." <> unmangled_name,
                  )
                True, False -> {
                  let #(alias, s1) = register_gleam_import(resolved_mod, st)
                  Ok(#(alias <> "." <> unmangled_name, s1))
                }
              }
            }
          })
          use #(rev_args, st2) <- result.try(
            list.try_fold(args, #([], st1), fn(acc, arg) {
              let #(a_acc, c_st) = acc
              use #(s, n_st) <- result.try(render_mirror_type(
                arg,
                cur_mod,
                ws,
                mirrored_names,
                allowed_pkgs,
                c_st,
              ))
              Ok(#([s, ..a_acc], n_st))
            }),
          )
          let suffix = case args {
            [] -> ""
            _ -> "(" <> string.join(list.reverse(rev_args), ", ") <> ")"
          }
          Ok(#(head <> suffix, st2))
        }
      }
    }
  }
}

fn render_mirror_dummy_const(ty: ir.IrType) -> Option(String) {
  case ty {
    ir.IrTypeInt64 -> Some("0")
    ir.IrTypeDouble -> Some("0.0")
    ir.IrTypeString -> Some("\"\"")
    ir.IrTypeBool -> Some("False")
    ir.IrTypeUnit -> Some("Nil")
    ir.IrTypeBitArray -> Some("<<>>")
    ir.IrTypeList(_) -> Some("[]")
    ir.IrTypeTuple(els) -> {
      let parts =
        list.filter_map(els, fn(e) {
          render_mirror_dummy_const(e) |> option.to_result(Nil)
        })
      case list.length(parts) == list.length(els) {
        True -> Some("#(" <> string.join(parts, ", ") <> ")")
        False -> None
      }
    }
    _ -> None
  }
}

fn camel_to_snake(name: String) -> String {
  name
  |> string.to_graphemes
  |> list.index_fold("", fn(acc, ch, idx) {
    let lower = string.lowercase(ch)
    let is_upper = ch != lower && ch == string.uppercase(ch)
    case is_upper && idx > 0 {
      True -> acc <> "_" <> lower
      False -> acc <> lower
    }
  })
}

fn lookup_gleam_type_info(
  table: SymbolTable,
  mod_name: String,
  ir_type_name: String,
) -> #(String, Bool) {
  case dict.get(table.modules, mod_name) {
    Error(_) -> #(ir_type_name, False)
    Ok(ms) ->
      case dict.get(ms.types, ir_type_name) {
        Ok(ti) -> #(ti.name, ti.publicity == glance.Private)
        Error(_) ->
          case
            dict.values(ms.types)
            |> list.find(fn(ti) {
              mangle.mangle_type_name(ti.name) == ir_type_name
            })
          {
            Ok(ti) -> #(ti.name, ti.publicity == glance.Private)
            Error(_) ->
              case dict.get(ms.type_aliases, ir_type_name) {
                Ok(ta) -> #(ta.name, ta.publicity == glance.Private)
                Error(_) ->
                  case
                    dict.values(ms.type_aliases)
                    |> list.find(fn(ta) {
                      mangle.mangle_type_name(ta.name) == ir_type_name
                    })
                  {
                    Ok(ta) -> #(ta.name, ta.publicity == glance.Private)
                    Error(_) -> #(ir_type_name, False)
                  }
              }
          }
      }
  }
}

fn register_gleam_import(
  mod_name: String,
  st: GleamRenderState,
) -> #(String, GleamRenderState) {
  case dict.get(st.alias_map, mod_name) {
    Ok(existing) -> #(existing, st)
    Error(_) -> {
      let base = filepath.base_name(mod_name)
      let chosen = pick_unique_gleam_alias(base, st.used_aliases, 0)
      #(
        chosen,
        GleamRenderState(
          alias_map: dict.insert(st.alias_map, mod_name, chosen),
          used_aliases: set.insert(st.used_aliases, chosen),
        ),
      )
    }
  }
}

fn pick_unique_gleam_alias(
  base: String,
  used: set.Set(String),
  attempt: Int,
) -> String {
  let candidate = case attempt {
    0 -> base
    _ -> base <> "_" <> int.to_string(attempt + 1)
  }
  case set.contains(used, candidate) {
    False -> candidate
    True -> pick_unique_gleam_alias(base, used, attempt + 1)
  }
}

fn render_gleam_import_lines(
  alias_map: Dict(String, String),
  already_imported: set.Set(String),
) -> List(String) {
  alias_map
  |> dict.to_list
  |> list.filter(fn(entry) { !set.contains(already_imported, entry.0) })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.map(fn(entry) {
    let #(mod_name, alias) = entry
    let default_alias = filepath.base_name(mod_name)
    case alias == default_alias {
      True -> "import " <> mod_name
      False -> "import " <> mod_name <> " as " <> alias
    }
  })
}

fn insert_gleam_imports(
  existing: String,
  new_import_lines: List(String),
) -> String {
  case new_import_lines {
    [] -> existing
    _ -> {
      let imp_block = string.join(new_import_lines, "\n")
      case existing {
        "" -> imp_block <> "\n"
        _ -> {
          let lines = string.split(existing, "\n")
          let last_imp_idx = find_last_import_line_idx(lines, 0, -1)
          case last_imp_idx {
            -1 -> imp_block <> "\n\n" <> existing
            idx -> {
              let before = list.take(lines, idx + 1)
              let after = list.drop(lines, idx + 1)
              string.join(list.flatten([before, new_import_lines, after]), "\n")
            }
          }
        }
      }
    }
  }
}

fn find_last_import_line_idx(
  lines: List(String),
  idx: Int,
  last_found: Int,
) -> Int {
  case lines {
    [] -> last_found
    [line, ..rest] -> {
      let next_found = case
        string.starts_with(string.trim_start(line), "import ")
      {
        True -> idx
        False -> last_found
      }
      find_last_import_line_idx(rest, idx + 1, next_found)
    }
  }
}

fn append_decls_to_module_patch(
  project_root: String,
  mod_name: String,
  decls: List(#(String, String, String)),
) -> Result(String, String) {
  let mod_dir = filepath.join(project_root, "patches/" <> mod_name)
  let user_files = case simplifile.read_directory(at: mod_dir) {
    Ok(entries) ->
      entries
      |> list.filter(fn(e) {
        string.ends_with(e, ".mbt") && !string.ends_with(e, ".g.mbt")
      })
      |> list.sort(string.compare)
    Error(_) -> []
  }

  use #(patched_names, unpatched_by_file) <- result.try(
    list.try_fold(user_files, #(set.new(), []), fn(acc, file) {
      let #(p_set, u_list) = acc
      let full = filepath.join(mod_dir, file)
      use content <- result.try(fs.read_text(full))
      use attrs <- result.try(patch_discovery.parse_mbt_patch_attributes(
        content,
        full,
      ))
      let next_p =
        list.fold(attrs, p_set, fn(s, a) {
          let s1 = set.insert(s, a.mbt_name)
          case a.target_override {
            Some(t) -> {
              let sym = case string.split(t, ".") |> list.last {
                Ok(last) -> last
                Error(_) -> t
              }
              s1 |> set.insert(t) |> set.insert(sym)
            }
            None -> s1
          }
        })
      let unpatched =
        patch_discovery.collect_unpatched_decl_names(content)
        |> set.from_list
      Ok(#(next_p, [#(full, unpatched), ..u_list]))
    }),
  )

  use rev_to_append <- result.try(
    list.try_fold(decls, [], fn(acc, decl) {
      let #(gleam_name, mbt_name, block) = decl
      case
        set.contains(patched_names, gleam_name)
        || set.contains(patched_names, mbt_name)
      {
        True -> Ok(acc)
        False -> {
          let conflict =
            list.find(unpatched_by_file, fn(entry) {
              set.contains(entry.1, gleam_name)
              || set.contains(entry.1, mbt_name)
            })
          case conflict {
            Ok(#(conflict_path, _)) ->
              Error(
                "Declaration '"
                <> gleam_name
                <> "' already exists in '"
                <> conflict_path
                <> "' without #gekko.patch; add #gekko.patch manually or rename it",
              )
            Error(_) -> Ok([#(gleam_name, block), ..acc])
          }
        }
      }
    }),
  )
  let to_append = list.reverse(rev_to_append)

  let canonical = filepath.base_name(mod_name) <> ".mbt"
  let target_filename = case list.contains(user_files, canonical), user_files {
    True, _ -> canonical
    False, [single] -> single
    _, _ -> canonical
  }
  let target_path = filepath.join(mod_dir, target_filename)

  case to_append {
    [] -> Ok("Already patched in " <> target_path <> " (0 changes).")
    _ -> {
      let existing = case simplifile.read(from: target_path) {
        Ok(c) -> c
        Error(_) -> ""
      }
      let blocks_str =
        to_append
        |> list.map(fn(p) { p.1 })
        |> string.join("\n\n")
      let sep = case existing {
        "" -> ""
        _ ->
          case
            string.ends_with(existing, "\n\n"),
            string.ends_with(existing, "\n")
          {
            True, _ -> ""
            False, True -> "\n"
            False, False -> "\n\n"
          }
      }
      let next_content = existing <> sep <> blocks_str <> "\n"
      use _ <- result.try(fs.write_text(target_path, next_content))
      let names =
        to_append
        |> list.map(fn(p) { mod_name <> "." <> p.0 })
        |> string.join(", ")
      Ok("Scaffolded into " <> target_path <> ": " <> names)
    }
  }
}

fn migrate_single_file_patches(
  patches_dir: String,
  rel_dir: String,
  loaded_mods: set.Set(String),
  acc: List(#(String, String)),
) -> Result(List(#(String, String)), String) {
  let cur_dir = case rel_dir {
    "" -> patches_dir
    _ -> filepath.join(patches_dir, rel_dir)
  }
  use entries <- result.try(
    simplifile.read_directory(at: cur_dir)
    |> result.map(fn(es) { list.sort(es, string.compare) })
    |> result.map_error(fn(err) {
      "Failed to read '" <> cur_dir <> "': " <> simplifile.describe_error(err)
    }),
  )
  let visible =
    list.filter(entries, fn(e) {
      !fs.is_ignored_entry(e)
      && case rel_dir == "" {
        True -> e != "gprelude" && e != "moon.mod" && e != "moon.lock"
        False -> True
      }
    })
  let moon_pkg_path = filepath.join(cur_dir, "moon.pkg")
  let has_user_moon_pkg =
    list.contains(visible, "moon.pkg")
    && !fs.has_generated_marker(moon_pkg_path)

  use next_acc <- result.try(
    list.try_fold(visible, acc, fn(cur_acc, entry) {
      let full = filepath.join(cur_dir, entry)
      case simplifile.is_directory(full) {
        Ok(True) -> {
          let next_rel = case rel_dir {
            "" -> entry
            _ -> rel_dir <> "/" <> entry
          }
          migrate_single_file_patches(
            patches_dir,
            next_rel,
            loaded_mods,
            cur_acc,
          )
        }
        _ ->
          case
            string.ends_with(entry, ".mbt")
            && !string.ends_with(entry, ".g.mbt")
          {
            False -> Ok(cur_acc)
            True -> {
              let stem = string.drop_end(entry, 4)
              let candidate_mod = case rel_dir {
                "" -> stem
                _ -> rel_dir <> "/" <> stem
              }
              let is_single_file = case rel_dir == "" {
                True -> True
                False ->
                  !has_user_moon_pkg
                  && stem != filepath.base_name(rel_dir)
                  && {
                    set.is_empty(loaded_mods)
                    || set.contains(loaded_mods, candidate_mod)
                    || !set.contains(loaded_mods, rel_dir)
                  }
              }
              case is_single_file {
                False -> Ok(cur_acc)
                True -> {
                  let dst_dir = filepath.join(patches_dir, candidate_mod)
                  let dst_path = filepath.join(dst_dir, entry)
                  use _ <- result.try(case simplifile.is_file(dst_path) {
                    Ok(True) ->
                      Error(
                        "Cannot migrate '"
                        <> full
                        <> "' to '"
                        <> dst_path
                        <> "': destination already exists",
                      )
                    _ -> Ok(Nil)
                  })
                  use content <- result.try(fs.read_text(full))
                  use _ <- result.try(fs.write_text(dst_path, content))
                  use _ <- result.try(
                    simplifile.delete_file(at: full)
                    |> result.map_error(fn(err) {
                      "Failed to remove '"
                      <> full
                      <> "': "
                      <> simplifile.describe_error(err)
                    }),
                  )
                  let rel_src = case rel_dir {
                    "" -> entry
                    _ -> rel_dir <> "/" <> entry
                  }
                  let rel_dst = candidate_mod <> "/" <> entry
                  Ok([#(rel_src, rel_dst), ..cur_acc])
                }
              }
            }
          }
      }
    }),
  )
  Ok(next_acc)
}

fn migrate_moon_pkg_imports(
  project_root: String,
  patches_dir: String,
  rel_dir: String,
  pkg_name: String,
  acc: List(String),
) -> Result(List(String), String) {
  let cur_dir = case rel_dir {
    "" -> patches_dir
    _ -> filepath.join(patches_dir, rel_dir)
  }
  use entries <- result.try(
    simplifile.read_directory(at: cur_dir)
    |> result.map(fn(es) { list.sort(es, string.compare) })
    |> result.map_error(fn(err) {
      "Failed to read '" <> cur_dir <> "': " <> simplifile.describe_error(err)
    }),
  )
  let visible =
    list.filter(entries, fn(e) {
      !fs.is_ignored_entry(e)
      && case rel_dir == "" {
        True -> e != "gprelude"
        False -> True
      }
    })
  let moon_pkg_path = filepath.join(cur_dir, "moon.pkg")
  use next_acc <- result.try(
    case
      rel_dir != ""
      && list.contains(visible, "moon.pkg")
      && !fs.has_generated_marker(moon_pkg_path)
    {
      False -> Ok(acc)
      True -> {
        use pkg_src <- result.try(fs.read_text(moon_pkg_path))
        use imports <- result.try(patch_discovery.parse_moon_pkg_imports(
          pkg_src,
          pkg_name,
        ))
        use _ <- result.try(case imports {
          [] -> Ok(Nil)
          _ ->
            append_patch_imports_to_gleam_toml(project_root, rel_dir, imports)
        })
        use _ <- result.try(
          simplifile.delete_file(at: moon_pkg_path)
          |> result.map_error(fn(err) {
            "Failed to delete '"
            <> moon_pkg_path
            <> "': "
            <> simplifile.describe_error(err)
          }),
        )
        Ok([rel_dir, ..acc])
      }
    },
  )

  list.try_fold(visible, next_acc, fn(cur_acc, entry) {
    let full = filepath.join(cur_dir, entry)
    case simplifile.is_directory(full) {
      Ok(True) -> {
        let next_rel = case rel_dir {
          "" -> entry
          _ -> rel_dir <> "/" <> entry
        }
        migrate_moon_pkg_imports(
          project_root,
          patches_dir,
          next_rel,
          pkg_name,
          cur_acc,
        )
      }
      _ -> Ok(cur_acc)
    }
  })
}

fn append_patch_imports_to_gleam_toml(
  project_root: String,
  mod_name: String,
  imports: List(patch_discovery.DiscoveredImport),
) -> Result(Nil, String) {
  let toml_path = filepath.join(project_root, "gleam.toml")
  use content <- result.try(fs.read_text(toml_path))
  let header = "[tools.gekko.patches.\"" <> mod_name <> "\"]"
  case string.contains(content, header) {
    True -> Ok(Nil)
    False -> {
      let items =
        list.map(imports, fn(imp) {
          let spec = case imp.alias {
            Some(a) -> imp.package <> " @" <> a
            None -> imp.package
          }
          "  \"" <> spec <> "\","
        })
        |> string.join("\n")
      let section = "\n" <> header <> "\nimports = [\n" <> items <> "\n]\n"
      let sep = case string.ends_with(content, "\n") {
        True -> ""
        False -> "\n"
      }
      fs.write_text(toml_path, content <> sep <> section)
    }
  }
}

fn ensure_empty_or_new_dir(dir: String) -> Result(Nil, String) {
  case simplifile.is_directory(dir) {
    Ok(True) ->
      case simplifile.read_directory(at: dir) {
        Ok([]) -> Ok(Nil)
        Ok(_) ->
          Error(
            "Target shim directory '"
            <> dir
            <> "' already exists and is not empty",
          )
        Error(err) ->
          Error(
            "Failed to inspect directory '"
            <> dir
            <> "': "
            <> simplifile.describe_error(err),
          )
      }
    _ -> Ok(Nil)
  }
}

fn render_shim_gleam_toml_section(
  target_pkg: String,
  version: String,
) -> String {
  let ver_constraint = suggest_semver_constraint(version)
  "[tools.gekko.shim_for]\npackage = \""
  <> target_pkg
  <> "\"\nversion = \""
  <> ver_constraint
  <> "\"\n"
}

fn render_new_patch_files(
  ws: ShimWorkspace,
  unmapped_types: List(UnmappedType),
  missing_fns: List(MissingFn),
) -> List(#(String, String)) {
  let mods =
    list.append(
      list.map(unmapped_types, fn(t) { t.mod_name }),
      list.map(missing_fns, fn(f) { f.mod_name }),
    )
    |> set.from_list
    |> set.to_list
    |> list.sort(string.compare)

  list.map(mods, fn(mod_name) {
    let type_decls =
      list.filter_map(unmapped_types, fn(t) {
        case t.mod_name == mod_name {
          False -> Error(Nil)
          True ->
            case
              list.find(ws.ir_modules, fn(m) { m.module_name == mod_name })
              |> result.try(fn(m) {
                list.find(m.types, fn(td) { td.unmangled_name == t.type_name })
              })
            {
              Ok(td) -> {
                let emit_ctx = make_emit_ctx(ws, mod_name)
                let #(raw, _) =
                  moonbit_decl.emit_type_def(
                    ir.IrTypeDef(..td, external_type: None),
                    emit_ctx,
                  )
                let block = case raw {
                  "///|\n" <> rest -> "///|\n#gekko.patch\n" <> rest
                  _ -> "///|\n#gekko.patch\n" <> raw
                }
                Ok(block)
              }
              Error(_) -> Error(Nil)
            }
        }
      })
    let fn_decls =
      list.filter_map(missing_fns, fn(f) {
        case f.mod_name == mod_name {
          False -> Error(Nil)
          True -> Ok(f.stub_block)
        }
      })
    let body = case list.append(type_decls, fn_decls) {
      [] -> "///|\n// Add co-located MoonBit patch implementations here.\n"
      blocks -> string.join(blocks, "\n\n") <> "\n"
    }
    let base_name = filepath.base_name(mod_name)
    #("patches/" <> mod_name <> "/" <> base_name <> ".mbt", body)
  })
}

fn split_last_dot(s: String) -> Result(#(String, String), Nil) {
  case string.split(s, ".") |> list.reverse {
    [last, ..rev_rest] if rev_rest != [] && last != "" ->
      Ok(#(rev_rest |> list.reverse |> string.join("."), last))
    _ -> Error(Nil)
  }
}

fn suggest_semver_constraint(version: String) -> String {
  case string.split(version, ".") {
    [maj_s, min_s, ..] ->
      case int.parse(maj_s), int.parse(min_s) {
        Ok(0), Ok(min) ->
          ">= 0."
          <> int.to_string(min)
          <> ".0 and < 0."
          <> int.to_string(min + 1)
          <> ".0"
        Ok(maj), _ ->
          ">= "
          <> int.to_string(maj)
          <> ".0.0 and < "
          <> int.to_string(maj + 1)
          <> ".0.0"
        _, _ -> ">= " <> version
      }
    _ -> ">= " <> version
  }
}
