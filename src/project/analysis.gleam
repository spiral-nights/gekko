import emit/pkg_config
import filepath
import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import index/symbol_table.{type SymbolTable}
import lower/desugar
import lower/ir.{type IrModule}
import lower/tco
import moonbit/ffi_meta.{type FfiMetadata}
import project/ffi_config
import project/interface.{type PackageInterface, PackageInterface}
import project/loader.{type DiscoveredPkg, type LoadedDependency}
import project/prepass.{type PrepassResult}
import project/staging
import simplifile

/// Complete lowered project analysis shared between compilation (`workspace`)
/// and companion shim tooling (`shim_cli`).
pub type ProjectAnalysis {
  ProjectAnalysis(
    project_name: String,
    version: String,
    packages_hash: String,
    discovered_deps: List(DiscoveredPkg),
    loaded_deps: List(LoadedDependency),
    discovered_versions: Dict(String, String),
    overlays: ffi_config.MergedOverlays,
    root_overlay: ffi_config.PackageOverlay,
    all_modules: List(#(String, String, glance.Module, PrepassResult)),
    non_mirror_modules: List(#(String, String, glance.Module, PrepassResult)),
    module_pkg_by_name: Dict(String, String),
    ffi_metadata: FfiMetadata,
    table: SymbolTable,
    resolved_pkg_dirs: Dict(String, String),
    ir_modules: List(IrModule),
  )
}

/// Load a project's context and run full project analysis (dependencies,
/// staged `package-interface`, parsing, FFI metadata, symbol table, lowering, TCO).
pub fn load_project_analysis(
  project_root: String,
  include_tests: Bool,
  validate_externals: Bool,
  scan_module_patches: Bool,
) -> Result(ProjectAnalysis, String) {
  use ctx <- result.try(loader.load_project_context(project_root, include_tests))
  analyze_project_context(
    project_root,
    ctx,
    include_tests,
    validate_externals,
    scan_module_patches,
  )
}

/// Run project analysis on an already-loaded `ProjectContext`.
pub fn analyze_project_context(
  project_root: String,
  ctx: loader.ProjectContext,
  include_tests: Bool,
  validate_externals: Bool,
  scan_module_patches: Bool,
) -> Result(ProjectAnalysis, String) {
  let project_name = ctx.project_name
  let version = ctx.version
  let packages_hash = ctx.packages_hash
  let discovered_deps = ctx.dependencies
  let overlays = ctx.overlays
  let discovered_versions =
    list.fold(
      discovered_deps,
      dict.from_list([#(project_name, version)]),
      fn(acc, dep) { dict.insert(acc, dep.package_name, dep.version) },
    )

  use loaded_deps <- result.try(
    loader.load_discovered_dependencies_with_validation(
      project_root,
      discovered_deps,
      overlays.overrides,
      overlays.target_branches,
      Some(packages_hash),
      validate_externals,
    ),
  )

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
  use src_modules <- result.try(case simplifile.is_directory(src_dir) {
    Ok(True) -> loader.discover_and_parse(src_dir, None)
    _ ->
      case validate_externals {
        True -> loader.discover_and_parse(src_dir, None)
        False -> Ok([])
      }
  })

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
  let non_mirror_modules =
    list.filter(all_modules, fn(entry) { entry.3.patch_mirror == None })
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
      overlays.patched_source_files,
    )
  use ffi_metadata <- result.try(case scan_module_patches {
    True ->
      scan_patched_metadata(
        base_ffi_metadata,
        all_modules,
        overlays.module_patches,
      )
    False -> Ok(base_ffi_metadata)
  })

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

  let resolved_pkg_dirs =
    non_mirror_modules
    |> list.map(fn(entry) { entry.1 })
    |> pkg_config.resolve_module_pkg_dirs

  let ir_modules =
    list.map(all_modules, fn(entry) {
      let #(_, mod_name, ast_mod, _) = entry
      desugar.desugar_module(ast_mod, table, mod_name)
      |> tco.optimize_module
    })

  Ok(ProjectAnalysis(
    project_name:,
    version:,
    packages_hash:,
    discovered_deps:,
    loaded_deps:,
    discovered_versions:,
    overlays:,
    root_overlay: ctx.root_overlay,
    all_modules:,
    non_mirror_modules:,
    module_pkg_by_name:,
    ffi_metadata:,
    table:,
    resolved_pkg_dirs:,
    ir_modules:,
  ))
}

/// Look up any co-located `ModulePatch` entries matching `pkg_name` and `mod_name`.
pub fn lookup_module_patches(
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

fn scan_patched_metadata(
  base_meta: FfiMetadata,
  all_modules: List(#(String, String, glance.Module, PrepassResult)),
  module_patches: Dict(String, ffi_config.ModulePatch),
) -> Result(FfiMetadata, String) {
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
