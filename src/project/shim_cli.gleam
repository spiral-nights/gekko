import emit/moonbit
import emit/moonbit_decl
import emit/trait_bounds.{type ProjectTraitBounds}
import filepath
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import lower/ir.{type IrModule}
import lower/ir_util
import project/analysis.{type ProjectAnalysis}
import project/ffi_config
import project/fs
import project/loader
import project/prepass
import project/shim_gleam_render
import project/shim_migrate
import project/type_baseline
import simplifile

/// Target language for scaffolding shim stubs.
pub type ShimStyle {
  GleamShim
  MoonBitShim
}

type ShimWorkspace {
  ShimWorkspace(analysis: ProjectAnalysis, project_bounds: ProjectTraitBounds)
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
    dict.get(ws.analysis.discovered_versions, target_pkg)
    |> result.unwrap("unknown")

  let target_ir_mods =
    list.filter(ws.analysis.ir_modules, fn(m) {
      dict.get(ws.analysis.module_pkg_by_name, m.module_name) == Ok(target_pkg)
    })

  let missing_fns = collect_missing_fns(ws, target_ir_mods)
  let unmapped_types =
    collect_unmapped_types(
      ws.analysis.overlays.gleam_type_patches,
      target_pkg,
      target_ir_mods,
    )

  let #(_moonbit_types, moonbit_fns) =
    count_patched_decls(ws.analysis.overlays.module_patches, target_pkg)
  let gleam_fns =
    count_gleam_patch_decls(ws.analysis.overlays.overrides, target_pkg)
  let gleam_types =
    count_gleam_type_patches(
      ws.analysis.overlays.gleam_type_patches,
      target_pkg,
    )
  let patched_types =
    count_patched_types(ws.analysis.overlays.type_overrides, target_pkg)
    + gleam_types
  let patched_fns = moonbit_fns + gleam_fns
  let unmatched = count_unmatched_entries(ws, target_pkg)
  let drift_status = case
    type_baseline.check_baselines(
      project_root,
      ws.analysis.module_pkg_by_name,
      ws.analysis.ir_modules,
      ws.analysis.discovered_versions,
    )
  {
    Ok(Nil) -> "clean"
    Error(err) -> "DRIFT DETECTED\n" <> err
  }
  let semver_note = case ws.analysis.root_overlay.shim {
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
    dict.get(ws.analysis.discovered_versions, target_pkg)
    |> result.unwrap("0.1.0")
  let shim_dir =
    option.unwrap(out_dir, filepath.join(project_root, "gekko_" <> target_pkg))
  let shim_name = case filepath.base_name(shim_dir) {
    "" | "." -> "gekko_" <> target_pkg
    base -> string.replace(base, "-", "_")
  }

  use _ <- result.try(shim_migrate.ensure_empty_or_new_dir(shim_dir))

  let target_ir_mods =
    list.filter(ws.analysis.ir_modules, fn(m) {
      dict.get(ws.analysis.module_pkg_by_name, m.module_name) == Ok(target_pkg)
    })
  let missing_fns = collect_missing_fns(ws, target_ir_mods)
  let unmapped_types =
    collect_unmapped_types(
      ws.analysis.overlays.gleam_type_patches,
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
    <> shim_migrate.suggest_semver_constraint(target_ver)
    <> "\"\n\n"
    <> shim_migrate.render_shim_gleam_toml_section(target_pkg, target_ver)
  let gitignore =
    "build/\ndist/\n/_build/\n/moon.work\n/moonbit/gprelude/\n/patches/moon.mod\n/patches/gprelude/\n/patches/_build/\n/patches/.mooncakes/\npatches/**/moon.pkg\npatches/**/*.g.mbt\npkg.generated.mbti\n"
  let placeholder_gleam =
    "//// Companion shim overlay for `"
    <> target_pkg
    <> "`.\n\npub const target = \""
    <> target_pkg
    <> "\"\n"
  let patch_files = case style {
    MoonBitShim ->
      shim_migrate.render_new_patch_files(
        ws.analysis.ir_modules,
        make_emit_ctx(ws, _),
        list.map(unmapped_types, fn(t) { #(t.mod_name, t.type_name) }),
        list.map(missing_fns, fn(f) { #(f.mod_name, f.fn_name, f.stub_block) }),
      )
    GleamShim ->
      shim_gleam_render.render_new_gleam_shim_files(
        ws.analysis,
        shim_name,
        target_pkg,
        target_ir_mods,
      )
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
  use target_pkg <- result.try(case ws.analysis.root_overlay.shim {
    Some(meta) -> Ok(meta.target)
    None ->
      Error(
        "No [tools.gekko.shim_for] found in gleam.toml (use 'gekko shim new <pkg>' to create a new companion shim repo)",
      )
  })
  use _ <- result.try(ensure_dep_present(ws, target_pkg))

  let target_ir_mods =
    list.filter(ws.analysis.ir_modules, fn(m) {
      dict.get(ws.analysis.module_pkg_by_name, m.module_name) == Ok(target_pkg)
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
              shim_migrate.append_decls_to_module_patch(
                project_root,
                mod_name,
                decls,
              )
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
              shim_gleam_render.append_gleam_fns_for_module(
                project_root,
                ws.analysis,
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
    shim_migrate.split_last_dot(clean_spec)
    |> result.map_error(fn(_) {
      "Expected `<module>.<decl>` (got '" <> target_spec <> "')"
    }),
  )
  use ws <- result.try(load_shim_workspace(project_root))
  use ir_mod <- result.try(
    list.find(ws.analysis.ir_modules, fn(m) { m.module_name == mod_name })
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
          shim_migrate.append_decls_to_module_patch(project_root, mod_name, [
            #(ir_fn.unmangled_name, ir_fn.name, block),
          ])
        }
        GleamShim ->
          shim_gleam_render.append_gleam_fns_for_module(
            project_root,
            ws.analysis,
            mod_name,
            [ir_fn],
          )
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
                  shim_gleam_render.append_gleam_type_for_module(
                    project_root,
                    ws.analysis,
                    mod_name,
                    td,
                  )
                False ->
                  Error(
                    "Type '"
                    <> mod_name
                    <> "."
                    <> decl_name
                    <> "' already defines variants; import '"
                    <> ws.analysis.project_name
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
              shim_migrate.append_decls_to_module_patch(project_root, mod_name, [
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
    list.find(ws.analysis.ir_modules, fn(m) { m.module_name == mod_name })
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
          shim_migrate.append_decls_to_module_patch(
            project_root,
            mod_name,
            decls,
          )
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
          shim_gleam_render.append_gleam_fns_for_module(
            project_root,
            ws.analysis,
            mod_name,
            missing_fns,
          )
      }
    }
  }
}

/// Regenerate all `//// @patch_mirror(...)` files found under `<project_root>/src/`.
pub fn sync_shims(project_root: String) -> Result(String, String) {
  use ws <- result.try(load_shim_workspace(project_root))
  shim_gleam_render.sync_mirrors(project_root, ws.analysis)
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
      ws.analysis.ir_modules
      |> list.map(fn(m) { m.module_name })
      |> set.from_list
    Error(_) -> set.new()
  }

  use moved <- result.try(
    shim_migrate.migrate_single_file_patches(patches_dir, "", loaded_mods, []),
  )

  let pkg_name = case loader.read_project_meta(project_root) {
    Ok(#(n, _)) -> n
    Error(_) -> ""
  }
  use migrated_pkgs <- result.try(
    shim_migrate.migrate_moon_pkg_imports(
      project_root,
      patches_dir,
      "",
      pkg_name,
      [],
    ),
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
    ws.analysis.root_overlay.module_patches,
    ws.analysis.module_pkg_by_name,
    ws.analysis.ir_modules,
    ws.analysis.discovered_versions,
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
  use pa <- result.try(analysis.load_project_analysis(
    project_root,
    False,
    False,
    False,
  ))
  let project_bounds =
    trait_bounds.analyze_project(pa.ir_modules, Some(pa.table), pa.ffi_metadata)
  Ok(ShimWorkspace(analysis: pa, project_bounds:))
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
      case ws.analysis.root_overlay.shim {
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
  case dict.has_key(ws.analysis.discovered_versions, target_pkg) {
    True -> Ok(Nil)
    False -> {
      let available =
        dict.keys(ws.analysis.discovered_versions)
        |> list.filter(fn(k) { k != ws.analysis.project_name })
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
    table: Some(ws.analysis.table),
    ffi_metadata: ws.analysis.ffi_metadata,
    project_bounds: ws.project_bounds,
    module_pkg_dirs: ws.analysis.resolved_pkg_dirs,
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
    list.fold(ws.analysis.all_modules, set.new(), fn(s, entry) {
      let #(pkg_name, mod_name, _, _) = entry
      s
      |> set.insert(pkg_name <> ":" <> mod_name)
      |> set.insert(mod_name)
    })
  let fn_keys =
    list.fold(ws.analysis.all_modules, set.new(), fn(s, entry) {
      let #(pkg_name, mod_name, _, _) = entry
      case dict.get(ws.analysis.table.modules, mod_name) {
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
    list.fold(ws.analysis.all_modules, set.new(), fn(s, entry) {
      let #(pkg_name, mod_name, _, _) = entry
      case dict.get(ws.analysis.table.modules, mod_name) {
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
    dict.keys(ws.analysis.overlays.module_patches)
    |> list.filter(fn(k) {
      let for_target =
        string.starts_with(k, target_pkg <> ":") || !string.contains(k, ":")
      for_target && !set.contains(mod_keys, k)
    })
  let unmatched_gleam =
    dict.to_list(ws.analysis.overlays.overrides)
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
    dict.keys(ws.analysis.overlays.gleam_type_patches)
    |> list.filter(fn(k) {
      let for_target =
        string.starts_with(k, target_pkg <> ":") || !string.contains(k, ":")
      for_target && !set.contains(ty_keys, k)
    })
  list.flatten([unmatched_mods, unmatched_gleam, unmatched_gleam_types])
  |> list.sort(string.compare)
}
