import filepath
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import project/ffi_toml
import project/gleam_patch_discovery
import project/patch_discovery
import project/paths
import project/prepass.{
  type ExternalType, type FfiKind, type GleamTypePatch, type TargetBranch,
  ExternalType, Patched,
}
import project/semver
import simplifile
import tom.{type Toml}

/// Metadata declared in `[tools.gekko.shim_for]` identifying the target package and SemVer range.
pub type ShimMeta {
  ShimMeta(target: String, version: Option(String))
}

/// A MoonBit source file patched directly into a transpiled module's package.
pub type ModulePatchFile {
  ModulePatchFile(
    source_path: String,
    dest_filename: String,
    source_pkg: String,
  )
}

/// An extra MoonBit package import required by a module's patch files.
pub type ModulePatchImport {
  ModulePatchImport(package: String, alias: Option(String))
}

/// Co-located MoonBit patch configuration for a single target Gleam module.
pub type ModulePatch {
  ModulePatch(
    files: List(ModulePatchFile),
    imports: List(ModulePatchImport),
    types: List(String),
    type_aliases: List(#(String, ExternalType)),
    functions: List(String),
    decl_locs: List(patch_discovery.PatchDeclLoc),
  )
}

/// Complete overlay configuration loaded from a single package (`gleam.toml` + `gekko.toml`).
pub type PackageOverlay {
  PackageOverlay(
    source_pkg: String,
    shim: Option(ShimMeta),
    authorized_shims: Dict(String, String),
    overrides: Dict(String, FfiKind),
    type_overrides: Dict(String, ExternalType),
    gleam_type_patches: Dict(String, GleamTypePatch),
    patch_mirrors: Dict(String, String),
    module_patches: Dict(String, ModulePatch),
    target_branches: Dict(String, TargetBranch),
  )
}

/// Merged overlay configuration across all dependency shims and the root project.
pub type MergedOverlays {
  MergedOverlays(
    shims: List(#(String, ShimMeta)),
    authorized_shims: Dict(String, String),
    overrides: Dict(String, FfiKind),
    override_sources: Dict(String, String),
    type_overrides: Dict(String, ExternalType),
    type_override_sources: Dict(String, String),
    gleam_type_patches: Dict(String, GleamTypePatch),
    gleam_type_patch_sources: Dict(String, String),
    patch_mirrors: Dict(String, String),
    patch_mirror_sources: Dict(String, String),
    module_patches: Dict(String, ModulePatch),
    module_patch_sources: Dict(String, String),
    target_branches: Dict(String, TargetBranch),
    patched_source_files: Set(String),
  )
}

/// Parse FFI overrides from a `gekko.toml` file string (`[overrides."..."]`).
pub fn parse_gekko_toml(
  content: String,
) -> Result(Dict(String, FfiKind), String) {
  ffi_toml.parse_gekko_toml(content)
}

/// Parse FFI overrides from a `gleam.toml` file string (`[tools.gekko.overrides."..."]`).
pub fn parse_gleam_toml_overrides(
  content: String,
) -> Result(Dict(String, FfiKind), String) {
  ffi_toml.parse_gleam_toml_overrides(content)
}

/// Load and merge FFI overrides from `<project_root>/gleam.toml` (`[tools.gekko.overrides]`)
/// and `<project_root>/gekko.toml` (`[overrides]`), with `gekko.toml` taking precedence.
pub fn load_project_overrides(
  project_root: String,
) -> Result(Dict(String, FfiKind), String) {
  ffi_toml.load_project_overrides(project_root)
}

/// Parse MoonBit third-party dependencies from `gekko.toml` (`[moonbit.deps]`).
pub fn parse_moonbit_deps_gekko_toml(
  content: String,
) -> Result(List(#(String, String)), String) {
  ffi_toml.parse_moonbit_deps_gekko_toml(content)
}

/// Parse MoonBit third-party dependencies from `gleam.toml`
/// (`[tools.gekko.moonbit.deps]` or `[gekko.moonbit.deps]`).
pub fn parse_moonbit_deps_gleam_toml(
  content: String,
) -> Result(List(#(String, String)), String) {
  ffi_toml.parse_moonbit_deps_gleam_toml(content)
}

/// Load and merge MoonBit dependencies from `<project_root>/gleam.toml`,
/// `<project_root>/gekko.toml`, and `<project_root>/moonbit/moon.mod`, with
/// `moonbit/moon.mod` taking highest precedence.
pub fn load_project_moonbit_deps(
  project_root: String,
) -> Result(List(#(String, String)), String) {
  ffi_toml.load_project_moonbit_deps(project_root)
}

/// Parse MoonBit third-party dependencies from the `import { ... }` block of
/// a native `moon.mod` file (such as `<project_root>/moonbit/moon.mod`).
pub fn parse_moon_mod_deps(
  content: String,
) -> Result(List(#(String, String)), String) {
  ffi_toml.parse_moon_mod_deps(content)
}

/// Parse `[shim_for]` metadata from a `gekko.toml` string.
pub fn parse_shim_gekko_toml(
  content: String,
) -> Result(Option(ShimMeta), String) {
  ffi_toml.parse_section(content, ["shim_for"], None, extract_shim_meta)
}

/// Parse `[tools.gekko.shim_for]` metadata from a `gleam.toml` string.
pub fn parse_shim_gleam_toml(
  content: String,
) -> Result(Option(ShimMeta), String) {
  ffi_toml.parse_section(
    content,
    ["tools", "gekko", "shim_for"],
    None,
    extract_shim_meta,
  )
}

/// Parse `[type_overrides."..."]` from a `gekko.toml` string.
pub fn parse_type_overrides_gekko_toml(
  content: String,
) -> Result(Dict(String, ExternalType), String) {
  ffi_toml.parse_type_overrides_gekko_toml(content)
}

/// Parse `[tools.gekko.type_overrides."..."]` from a `gleam.toml` string.
pub fn parse_type_overrides_gleam_toml(
  content: String,
) -> Result(Dict(String, ExternalType), String) {
  ffi_toml.parse_type_overrides_gleam_toml(content)
}

/// Parse `[patch."..."]` from a `gekko.toml` string.
pub fn parse_module_patch_gekko_toml(
  content: String,
) -> Result(Dict(String, ModulePatch), String) {
  ffi_toml.parse_section(content, ["patch"], dict.new(), fn(table) {
    ffi_toml.collect_nested_entries(table, [], extract_module_patch)
  })
}

/// Parse `[tools.gekko.patch."..."]` from a `gleam.toml` string.
pub fn parse_module_patch_gleam_toml(
  content: String,
) -> Result(Dict(String, ModulePatch), String) {
  ffi_toml.parse_section(
    content,
    ["tools", "gekko", "patch"],
    dict.new(),
    fn(table) {
      ffi_toml.collect_nested_entries(table, [], extract_module_patch)
    },
  )
}

/// Parse `[target_branch."..."]` from a `gekko.toml` string.
pub fn parse_target_branch_gekko_toml(
  content: String,
) -> Result(Dict(String, TargetBranch), String) {
  ffi_toml.parse_target_branch_gekko_toml(content)
}

/// Parse `[tools.gekko.target_branch."..."]` from a `gleam.toml` string.
pub fn parse_target_branch_gleam_toml(
  content: String,
) -> Result(Dict(String, TargetBranch), String) {
  ffi_toml.parse_target_branch_gleam_toml(content)
}

/// Parse `[use_shims]` authorization allowlist from a `gekko.toml` string.
pub fn parse_authorized_shims_gekko_toml(
  content: String,
) -> Result(Dict(String, String), String) {
  ffi_toml.parse_authorized_shims_gekko_toml(content)
}

/// Parse `[tools.gekko.use_shims]` authorization allowlist from a `gleam.toml` string.
pub fn parse_authorized_shims_gleam_toml(
  content: String,
) -> Result(Dict(String, String), String) {
  ffi_toml.parse_authorized_shims_gleam_toml(content)
}

/// Discover `/// @patch("mod.fn")` / `/// @gekko.patch("mod.fn")` annotations
/// across Gleam modules under `<pkg_root>/src/`.
pub fn discover_gleam_patches(
  pkg_root: String,
  target_pkg: Option(String),
) -> Result(Dict(String, FfiKind), String) {
  gleam_patch_discovery.discover_gleam_patches(pkg_root, target_pkg)
}

/// Discover `@patch`, `@patch_type`, and `@patch_mirror` annotations across
/// Gleam modules under `<pkg_root>/src/`.
pub fn discover_gleam_patch_bundle(
  pkg_root: String,
  target_pkg: Option(String),
) -> Result(
  #(Dict(String, FfiKind), Dict(String, GleamTypePatch), Dict(String, String)),
  String,
) {
  gleam_patch_discovery.discover_gleam_patch_bundle(pkg_root, target_pkg)
}

/// Check whether `version` satisfies a Gleam/Hex SemVer `constraint`
/// (e.g. `">= 2.0.0 and < 3.0.0"`, `"~> 1.2"`, `"^3.0.0"`).
pub fn version_matches_constraint(
  version: String,
  constraint: String,
) -> Result(Bool, String) {
  semver.version_matches_constraint(version, constraint)
}

/// Load and merge all overlay sections (`shim_for`, `use_shims`, `overrides`, `type_overrides`,
/// `patch`, `target_branch`) from a package's `gleam.toml` and `gekko.toml`.
pub fn load_package_overlay(
  pkg_root: String,
  pkg_name: String,
) -> Result(PackageOverlay, String) {
  use gleam_doc <- result.try(
    ffi_toml.load_toml_document(filepath.join(pkg_root, "gleam.toml")),
  )
  use gekko_doc <- result.try(
    ffi_toml.load_toml_document(filepath.join(pkg_root, "gekko.toml")),
  )

  use shim_g <- result.try(ffi_toml.section_from(
    gleam_doc,
    ["tools", "gekko", "shim_for"],
    None,
    extract_shim_meta,
  ))
  use shim_k <- result.try(ffi_toml.section_from(
    gekko_doc,
    ["shim_for"],
    None,
    extract_shim_meta,
  ))
  use auth_g <- result.try(ffi_toml.section_from(
    gleam_doc,
    ["tools", "gekko", "use_shims"],
    dict.new(),
    ffi_toml.extract_authorized_shims_table,
  ))
  use auth_k <- result.try(ffi_toml.section_from(
    gekko_doc,
    ["use_shims"],
    dict.new(),
    ffi_toml.extract_authorized_shims_table,
  ))
  use ovr_g <- result.try(
    ffi_toml.section_from(
      gleam_doc,
      ["tools", "gekko", "overrides"],
      dict.new(),
      fn(table) {
        ffi_toml.collect_nested_entries(table, [], ffi_toml.extract_ffi_kind)
      },
    ),
  )
  use ovr_k <- result.try(
    ffi_toml.section_from(gekko_doc, ["overrides"], dict.new(), fn(table) {
      ffi_toml.collect_nested_entries(table, [], ffi_toml.extract_ffi_kind)
    }),
  )
  use ty_g <- result.try(
    ffi_toml.section_from(
      gleam_doc,
      ["tools", "gekko", "type_overrides"],
      dict.new(),
      fn(table) {
        ffi_toml.collect_nested_entries(
          table,
          [],
          ffi_toml.extract_type_override,
        )
      },
    ),
  )
  use ty_k <- result.try(
    ffi_toml.section_from(gekko_doc, ["type_overrides"], dict.new(), fn(table) {
      ffi_toml.collect_nested_entries(table, [], ffi_toml.extract_type_override)
    }),
  )
  use pat_g <- result.try(
    ffi_toml.section_from(
      gleam_doc,
      ["tools", "gekko", "patch"],
      dict.new(),
      fn(table) {
        ffi_toml.collect_nested_entries(table, [], extract_module_patch)
      },
    ),
  )
  use pat_k <- result.try(
    ffi_toml.section_from(gekko_doc, ["patch"], dict.new(), fn(table) {
      ffi_toml.collect_nested_entries(table, [], extract_module_patch)
    }),
  )
  use patches_imp_g <- result.try(
    ffi_toml.section_from(
      gleam_doc,
      ["tools", "gekko", "patches"],
      dict.new(),
      fn(table) {
        ffi_toml.collect_nested_entries(table, [], extract_patches_imports)
      },
    ),
  )
  use patches_imp_k <- result.try(
    ffi_toml.section_from(gekko_doc, ["patches"], dict.new(), fn(table) {
      ffi_toml.collect_nested_entries(table, [], extract_patches_imports)
    }),
  )
  use br_g <- result.try(
    ffi_toml.section_from(
      gleam_doc,
      ["tools", "gekko", "target_branch"],
      dict.new(),
      fn(table) {
        ffi_toml.collect_nested_entries(
          table,
          [],
          ffi_toml.extract_target_branch,
        )
      },
    ),
  )
  use br_k <- result.try(
    ffi_toml.section_from(gekko_doc, ["target_branch"], dict.new(), fn(table) {
      ffi_toml.collect_nested_entries(table, [], ffi_toml.extract_target_branch)
    }),
  )

  let shim = case shim_k {
    Some(_) -> shim_k
    None -> shim_g
  }
  let authorized_shims = dict.merge(auth_g, auth_k)
  let explicit_overrides = dict.merge(ovr_g, ovr_k)
  let explicit_type_overrides = dict.merge(ty_g, ty_k)
  let target_branches = dict.merge(br_g, br_k)
  let raw_patches = merge_module_patch_dicts(pat_g, pat_k)
  use resolved_toml_patches <- result.try(resolve_module_patch_files(
    pkg_root,
    pkg_name,
    raw_patches,
  ))
  let toml_patched_paths =
    dict.fold(resolved_toml_patches, set.new(), fn(acc, _k, patch) {
      list.fold(patch.files, acc, fn(s, f) { set.insert(s, f.source_path) })
    })
  let target_pkg = option.map(shim, fn(s) { s.target })
  let raw_import_patches =
    merge_module_patch_dicts(patches_imp_g, patches_imp_k)
  let import_patches = case target_pkg {
    None -> raw_import_patches
    Some(tp) ->
      dict.fold(raw_import_patches, dict.new(), fn(acc, k, v) {
        let qualified = case string.contains(k, ":") {
          True -> k
          False -> tp <> ":" <> k
        }
        dict.insert(acc, qualified, v)
      })
  }
  use discovered_raw <- result.try(patch_discovery.discover_directory_patches(
    pkg_root,
    pkg_name,
    target_pkg,
    toml_patched_paths,
  ))
  let discovered_patches = convert_discovered_patches(discovered_raw)
  let resolved_patches =
    merge_module_patch_dicts(resolved_toml_patches, discovered_patches)
    |> merge_module_patch_dicts(import_patches)

  let #(patch_fn_overrides, patch_type_overrides) =
    expand_patch_entries(resolved_patches)
  use #(gleam_patch_overrides, gleam_type_patches, patch_mirrors) <- result.try(
    discover_gleam_patch_bundle(pkg_root, target_pkg),
  )
  use _ <- result.try(
    dict.keys(gleam_patch_overrides)
    |> list.try_each(fn(k) {
      case dict.has_key(patch_fn_overrides, k) {
        True ->
          Error(
            "Conflicting MoonBit #gekko.patch and Gleam @patch for '"
            <> k
            <> "' in package '"
            <> pkg_name
            <> "'",
          )
        False -> Ok(Nil)
      }
    }),
  )
  use _ <- result.try(
    dict.keys(gleam_type_patches)
    |> list.try_each(fn(k) {
      case
        dict.has_key(patch_type_overrides, k)
        || dict.has_key(explicit_type_overrides, k)
      {
        True ->
          Error(
            "Conflicting MoonBit/config type_override and Gleam @patch_type for '"
            <> k
            <> "' in package '"
            <> pkg_name
            <> "'",
          )
        False -> Ok(Nil)
      }
    }),
  )
  let overrides =
    dict.merge(patch_fn_overrides, gleam_patch_overrides)
    |> dict.merge(explicit_overrides)
  let type_overrides = dict.merge(patch_type_overrides, explicit_type_overrides)

  Ok(PackageOverlay(
    source_pkg: pkg_name,
    shim:,
    authorized_shims:,
    overrides:,
    type_overrides:,
    gleam_type_patches:,
    patch_mirrors:,
    module_patches: resolved_patches,
    target_branches:,
  ))
}

/// Merge dependency shim overlays and the root project's overlay.
/// Conflicting overrides between two dependency shims produce an error unless
/// the root project explicitly overrides the same key.
pub fn merge_overlays(
  dep_overlays: List(PackageOverlay),
  root_overlay: PackageOverlay,
) -> Result(MergedOverlays, String) {
  use _ <- result.try(
    list.try_each(dep_overlays, fn(dep) {
      validate_dep_overlay_scope(dep, root_overlay.authorized_shims)
    }),
  )

  let shims =
    list.filter_map(dep_overlays, fn(ov) {
      case ov.shim {
        Some(meta) -> Ok(#(ov.source_pkg, meta))
        None -> Error(Nil)
      }
    })
  let shims = case root_overlay.shim {
    Some(meta) -> list.append(shims, [#(root_overlay.source_pkg, meta)])
    None -> shims
  }

  use #(ovr_map, ovr_src) <- result.try(merge_keyed_with_root(
    dep_overlays,
    root_overlay,
    fn(ov) { ov.overrides },
    "override",
  ))
  use #(ty_map, ty_src) <- result.try(merge_keyed_with_root(
    dep_overlays,
    root_overlay,
    fn(ov) { ov.type_overrides },
    "type_override",
  ))
  use #(g_ty_map, g_ty_src) <- result.try(merge_keyed_with_root(
    dep_overlays,
    root_overlay,
    fn(ov) { ov.gleam_type_patches },
    "gleam_type_patch",
  ))
  use #(mirror_map, mirror_src) <- result.try(merge_keyed_with_root(
    dep_overlays,
    root_overlay,
    fn(ov) { ov.patch_mirrors },
    "patch_mirror",
  ))
  use #(br_map, _) <- result.try(merge_keyed_with_root(
    dep_overlays,
    root_overlay,
    fn(ov) { ov.target_branches },
    "target_branch",
  ))

  let #(patch_map, patch_src) =
    list.fold(
      list.append(dep_overlays, [root_overlay]),
      #(dict.new(), dict.new()),
      fn(acc, ov) {
        let #(m, s) = acc
        let next_m = merge_module_patch_dicts(m, ov.module_patches)
        let next_s =
          dict.fold(ov.module_patches, s, fn(s_acc, k, _v) {
            dict.insert(s_acc, k, ov.source_pkg)
          })
        #(next_m, next_s)
      },
    )

  let patched_source_files =
    dict.fold(patch_map, set.new(), fn(acc, _k, patch) {
      list.fold(patch.files, acc, fn(s, f) { set.insert(s, f.source_path) })
    })

  Ok(MergedOverlays(
    shims:,
    authorized_shims: root_overlay.authorized_shims,
    overrides: ovr_map,
    override_sources: ovr_src,
    type_overrides: ty_map,
    type_override_sources: ty_src,
    gleam_type_patches: g_ty_map,
    gleam_type_patch_sources: g_ty_src,
    patch_mirrors: mirror_map,
    patch_mirror_sources: mirror_src,
    module_patches: patch_map,
    module_patch_sources: patch_src,
    target_branches: br_map,
    patched_source_files:,
  ))
}

/// Validate declared `[shim]` target presence and SemVer constraints against
/// discovered package versions.
pub fn check_shim_versions(
  shims: List(#(String, ShimMeta)),
  discovered_versions: Dict(String, String),
) -> Result(List(String), String) {
  list.try_map(shims, fn(entry) {
    let #(shim_pkg, meta) = entry
    case dict.get(discovered_versions, meta.target) {
      Error(_) ->
        Ok(Some(
          "Warning: shim '"
          <> shim_pkg
          <> "' targets package '"
          <> meta.target
          <> "', which is not a dependency of this project",
        ))
      Ok(actual_ver) ->
        case meta.version {
          None -> Ok(None)
          Some(constraint) -> {
            use matches <- result.try(version_matches_constraint(
              actual_ver,
              constraint,
            ))
            case matches {
              True -> Ok(None)
              False ->
                Ok(Some(
                  "Warning: shim '"
                  <> shim_pkg
                  <> "' expects '"
                  <> meta.target
                  <> "' ("
                  <> constraint
                  <> "), but resolved version is "
                  <> actual_ver,
                ))
            }
          }
        }
    }
  })
  |> result.map(fn(opts) { list.filter_map(opts, option.to_result(_, Nil)) })
}

/// Warn if any shim package enabled in root `[tools.gekko.use_shims]` is not a
/// resolved dependency of the project.
pub fn check_authorized_shims(
  authorized_shims: Dict(String, String),
  discovered_versions: Dict(String, String),
) -> List(String) {
  dict.to_list(authorized_shims)
  |> list.filter_map(fn(entry) {
    let #(target_pkg, shim_pkg) = entry
    case dict.has_key(discovered_versions, shim_pkg) {
      True -> Error(Nil)
      False ->
        Ok(
          "Warning: [tools.gekko.use_shims] enables '"
          <> shim_pkg
          <> "' for '"
          <> target_pkg
          <> "', but '"
          <> shim_pkg
          <> "' is not a dependency of this project",
        )
    }
  })
}

fn extract_shim_meta(
  table: Dict(String, Toml),
) -> Result(Option(ShimMeta), String) {
  use res <- result.try(ffi_toml.extract_shim_tuple(table))
  Ok(option.map(res, fn(pair) { ShimMeta(target: pair.0, version: pair.1) }))
}

fn extract_module_patch(
  table: Dict(String, Toml),
  rev_key_parts: List(String),
) -> Result(Option(ModulePatch), String) {
  use raw_opt <- result.try(ffi_toml.extract_raw_module_patch(
    table,
    rev_key_parts,
  ))
  Ok(
    option.map(raw_opt, fn(raw) {
      let files =
        list.map(raw.file_paths, fn(p) {
          ModulePatchFile(
            source_path: p,
            dest_filename: filepath.base_name(p),
            source_pkg: "",
          )
        })
      let imports =
        list.map(raw.imports, fn(i) {
          ModulePatchImport(package: i.0, alias: i.1)
        })
      ModulePatch(
        files:,
        imports:,
        types: raw.types,
        type_aliases: [],
        functions: raw.functions,
        decl_locs: [],
      )
    }),
  )
}

fn extract_patches_imports(
  table: Dict(String, Toml),
  rev_key_parts: List(String),
) -> Result(Option(ModulePatch), String) {
  use raw_opt <- result.try(ffi_toml.extract_patches_imports(
    table,
    rev_key_parts,
  ))
  Ok(
    option.map(raw_opt, fn(raw_imports) {
      let imports =
        list.map(raw_imports, fn(i) {
          ModulePatchImport(package: i.0, alias: i.1)
        })
      ModulePatch(
        files: [],
        imports:,
        types: [],
        type_aliases: [],
        functions: [],
        decl_locs: [],
      )
    }),
  )
}

fn convert_discovered_patches(
  discovered: Dict(String, patch_discovery.DiscoveredModulePatch),
) -> Dict(String, ModulePatch) {
  dict.map_values(discovered, fn(_k, p) {
    let files =
      list.map(p.files, fn(f) {
        ModulePatchFile(
          source_path: f.source_path,
          dest_filename: f.dest_filename,
          source_pkg: f.source_pkg,
        )
      })
    let imports =
      list.map(p.imports, fn(i) {
        ModulePatchImport(package: i.package, alias: i.alias)
      })
    let type_aliases =
      list.map(p.type_aliases, fn(entry) {
        let #(ty_name, #(ext_pkg, ext_ty)) = entry
        #(ty_name, ExternalType(package: ext_pkg, type_name: ext_ty))
      })
    ModulePatch(
      files:,
      imports:,
      types: p.types,
      type_aliases:,
      functions: p.functions,
      decl_locs: p.decl_locs,
    )
  })
}

fn expand_patch_entries(
  patches: Dict(String, ModulePatch),
) -> #(Dict(String, FfiKind), Dict(String, ExternalType)) {
  dict.fold(patches, #(dict.new(), dict.new()), fn(acc, mod_key, patch) {
    let #(fn_acc, ty_acc) = acc
    let target_mod = case string.split_once(mod_key, ":") {
      Ok(#(_, m)) -> m
      Error(_) -> mod_key
    }
    let next_fns =
      list.fold(patch.functions, fn_acc, fn(m, fn_name) {
        dict.insert(m, mod_key <> "." <> fn_name, Patched)
      })
    let next_tys =
      list.fold(patch.types, ty_acc, fn(m, ty_name) {
        dict.insert(
          m,
          mod_key <> "." <> ty_name,
          ExternalType(package: target_mod, type_name: ty_name),
        )
      })
    let next_tys =
      list.fold(patch.type_aliases, next_tys, fn(m, entry) {
        let #(ty_name, ext_ty) = entry
        dict.insert(m, mod_key <> "." <> ty_name, ext_ty)
      })
    #(next_fns, next_tys)
  })
}

fn resolve_module_patch_files(
  pkg_root: String,
  pkg_name: String,
  patches: Dict(String, ModulePatch),
) -> Result(Dict(String, ModulePatch), String) {
  let abs_root = paths.absolute(pkg_root)
  dict.to_list(patches)
  |> list.try_fold(dict.new(), fn(acc, entry) {
    let #(mod_key, patch) = entry
    use resolved_files <- result.try(
      list.try_map(patch.files, fn(f) {
        let normalized = paths.resolve_against(abs_root, f.source_path)
        case simplifile.is_file(normalized) {
          Ok(True) ->
            Ok(ModulePatchFile(
              source_path: normalized,
              dest_filename: f.dest_filename,
              source_pkg: pkg_name,
            ))
          _ ->
            Error(
              "Patch MoonBit file '"
              <> f.source_path
              <> "' declared in package '"
              <> pkg_name
              <> "' for patch '"
              <> mod_key
              <> "' was not found at "
              <> normalized,
            )
        }
      }),
    )
    Ok(dict.insert(acc, mod_key, ModulePatch(..patch, files: resolved_files)))
  })
}

fn merge_module_patch_dicts(
  base: Dict(String, ModulePatch),
  extra: Dict(String, ModulePatch),
) -> Dict(String, ModulePatch) {
  dict.fold(extra, base, fn(acc, key, patch) {
    case dict.get(acc, key) {
      Error(_) -> dict.insert(acc, key, patch)
      Ok(existing) -> dict.insert(acc, key, merge_two_patches(existing, patch))
    }
  })
}

fn merge_two_patches(a: ModulePatch, b: ModulePatch) -> ModulePatch {
  let files =
    list.append(a.files, b.files)
    |> dedup_by(fn(f) { #(f.source_path, f.dest_filename) })
  let imports =
    list.append(a.imports, b.imports)
    |> dedup_by(fn(i) { #(i.package, i.alias) })
  let types =
    list.append(a.types, b.types)
    |> dedup_by(fn(t) { t })
  let type_aliases =
    list.append(a.type_aliases, b.type_aliases)
    |> dedup_by(fn(t) { t })
  let functions =
    list.append(a.functions, b.functions)
    |> dedup_by(fn(f) { f })
  let decl_locs =
    list.append(a.decl_locs, b.decl_locs)
    |> dedup_by(fn(l) { #(l.file_path, l.line, l.gleam_name) })
  ModulePatch(files:, imports:, types:, type_aliases:, functions:, decl_locs:)
}

fn dedup_by(items: List(a), key_fn: fn(a) -> k) -> List(a) {
  let #(_, rev) =
    list.fold(items, #(set.new(), []), fn(acc, item) {
      let #(seen, out) = acc
      let k = key_fn(item)
      case set.contains(seen, k) {
        True -> acc
        False -> #(set.insert(seen, k), [item, ..out])
      }
    })
  list.reverse(rev)
}

fn merge_keyed_with_root(
  dep_overlays: List(PackageOverlay),
  root_overlay: PackageOverlay,
  getter: fn(PackageOverlay) -> Dict(String, a),
  kind_label: String,
) -> Result(#(Dict(String, a), Dict(String, String)), String) {
  let root_map = getter(root_overlay)
  let #(dep_map, dep_src, conflicts) =
    list.fold(dep_overlays, #(dict.new(), dict.new(), []), fn(acc, ov) {
      let #(cur_map, cur_src, cur_conflicts) = acc
      dict.fold(getter(ov), #(cur_map, cur_src, cur_conflicts), fn(st, k, v) {
        let #(m, s, c) = st
        case dict.get(m, k) {
          Error(_) -> #(
            dict.insert(m, k, v),
            dict.insert(s, k, ov.source_pkg),
            c,
          )
          Ok(existing) ->
            case existing == v {
              True -> st
              False -> {
                let prev_pkg = dict.get(s, k) |> result.unwrap("unknown")
                #(m, s, [#(k, prev_pkg, ov.source_pkg), ..c])
              }
            }
        }
      })
    })

  let unresolved =
    list.filter(list.reverse(conflicts), fn(c) { !dict.has_key(root_map, c.0) })
  case unresolved {
    [#(key, pkg_a, pkg_b), ..] ->
      Error(
        "Conflicting "
        <> kind_label
        <> " for '"
        <> key
        <> "' between shim packages '"
        <> pkg_a
        <> "' and '"
        <> pkg_b
        <> "' (override it in root gleam.toml [tools.gekko.*] to resolve)",
      )
    [] -> {
      let final_map = dict.merge(dep_map, root_map)
      let final_src =
        dict.fold(root_map, dep_src, fn(s, k, _v) {
          dict.insert(s, k, root_overlay.source_pkg)
        })
      Ok(#(final_map, final_src))
    }
  }
}

fn validate_dep_overlay_scope(
  dep: PackageOverlay,
  root_authorized_shims: Dict(String, String),
) -> Result(Nil, String) {
  let has_any =
    !dict.is_empty(dep.overrides)
    || !dict.is_empty(dep.type_overrides)
    || !dict.is_empty(dep.gleam_type_patches)
    || !dict.is_empty(dep.patch_mirrors)
    || !dict.is_empty(dep.module_patches)
    || !dict.is_empty(dep.target_branches)
  case has_any, dep.shim {
    False, _ -> Ok(Nil)
    True, None ->
      Error(
        "Security error: dependency '"
        <> dep.source_pkg
        <> "' defines gekko patches or overrides without declaring [tools.gekko.shim_for] package = \"<pkg>\" in gleam.toml",
      )
    True, Some(ShimMeta(target:, ..)) -> {
      use _ <- result.try(case dict.get(root_authorized_shims, target) {
        Ok(allowed_shim) if allowed_shim == dep.source_pkg -> Ok(Nil)
        Ok(other_shim) ->
          Error(
            "Security error: dependency '"
            <> dep.source_pkg
            <> "' declares [tools.gekko.shim_for] for '"
            <> target
            <> "', but root gleam.toml authorizes '"
            <> other_shim
            <> "' for '"
            <> target
            <> "' in [tools.gekko.use_shims]",
          )
        Error(_) ->
          Error(
            "Security error: dependency '"
            <> dep.source_pkg
            <> "' declares [tools.gekko.shim_for] for '"
            <> target
            <> "', but is not enabled in root gleam.toml.\nTo allow and use this shim, add to your root gleam.toml:\n\n  [tools.gekko.use_shims]\n  "
            <> target
            <> " = \""
            <> dep.source_pkg
            <> "\"",
          )
      })
      let check_keys = fn(keys: List(String), allow_exact: Bool) {
        list.try_each(keys, fn(k) {
          let allowed =
            string.starts_with(k, target <> ":")
            || string.starts_with(k, target <> ".")
            || { allow_exact && k == target }
          case allowed {
            True -> Ok(Nil)
            False ->
              Error(
                "Security error: shim dependency '"
                <> dep.source_pkg
                <> "' declares [tools.gekko.shim_for] package '"
                <> target
                <> "' and cannot patch/override '"
                <> k
                <> "'",
              )
          }
        })
      }
      use _ <- result.try(check_keys(dict.keys(dep.overrides), False))
      use _ <- result.try(check_keys(dict.keys(dep.type_overrides), False))
      use _ <- result.try(check_keys(dict.keys(dep.gleam_type_patches), False))
      use _ <- result.try(check_keys(dict.values(dep.patch_mirrors), True))
      use _ <- result.try(check_keys(dict.keys(dep.module_patches), False))
      check_keys(dict.keys(dep.target_branches), True)
    }
  }
}
