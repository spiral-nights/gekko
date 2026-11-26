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
import gleam/set
import gleam/string
import index/symbol_table.{type SymbolTable}
import lower/desugar
import lower/ir.{type IrModule}
import lower/ir_util
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
  let unmapped_types = collect_unmapped_types(target_ir_mods)

  let #(patched_types, patched_fns) =
    count_patched_decls(ws.overlays.module_patches, target_pkg)
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
  let unmapped_types = collect_unmapped_types(target_ir_mods)

  let gleam_toml =
    "name = \""
    <> shim_name
    <> "\"\nversion = \"0.1.0\"\ndescription = \"MoonBit shim overlay for "
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
    "//// Companion MoonBit shim overlay for `"
    <> target_pkg
    <> "`.\n\npub const target = \""
    <> target_pkg
    <> "\"\n"
  let patch_files = render_new_patch_files(ws, unmapped_types, missing_fns)

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
  Ok(
    "Created companion shim '"
    <> shim_name
    <> "' for '"
    <> target_pkg
    <> "':\n"
    <> created
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
  let missing = collect_missing_fns(ws, target_ir_mods)
  case missing {
    [] ->
      Ok(
        "All external functions in '" <> target_pkg <> "' are already patched.",
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

/// Scaffold a single declaration `<module>.<decl>` into `patches/<module>/`.
pub fn patch_decl(
  project_root: String,
  target_spec: String,
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
    Ok(ir_fn) -> {
      let #(block, _) = moonbit.emit_function_scaffold(ir_fn, emit_ctx)
      append_decls_to_module_patch(project_root, mod_name, [
        #(ir_fn.unmangled_name, ir_fn.name, block),
      ])
    }
    Error(_) ->
      case
        list.find(ir_mod.types, fn(td) {
          td.unmangled_name == decl_name || td.name == decl_name
        })
      {
        Ok(td) -> {
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
  use ws <- result.try(load_shim_workspace(project_root))
  use ir_mod <- result.try(
    list.find(ws.ir_modules, fn(m) { m.module_name == mod_name })
    |> result.map_error(fn(_) {
      "Module '" <> mod_name <> "' was not found in loaded packages"
    }),
  )
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

fn collect_unmapped_types(ir_mods: List(IrModule)) -> List(UnmappedType) {
  list.flat_map(ir_mods, fn(ir_mod) {
    list.filter_map(ir_mod.types, fn(td) {
      case td.variants == [] && td.external_type == None {
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
  dict.keys(ws.overlays.module_patches)
  |> list.filter(fn(k) {
    let for_target =
      string.starts_with(k, target_pkg <> ":") || !string.contains(k, ":")
    for_target && !set.contains(mod_keys, k)
  })
  |> list.sort(string.compare)
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
