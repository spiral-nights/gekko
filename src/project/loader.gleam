import filepath
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import index/symbol_table
import project/cmd
import project/ffi_config
import project/interface.{type PackageInterface}
import project/paths
import project/prepass.{type FfiKind, type PrepassResult, type TargetBranch}
import project/staging
import project/text_edit
import simplifile
import tom

/// A discovered, validated, and parsed third-party Hex package dependency
/// loaded from `build/packages/<package>`.
pub type LoadedDependency {
  LoadedDependency(
    package_name: String,
    version: String,
    package_root: String,
    modules: List(#(String, glance.Module, PrepassResult)),
    interface: Option(PackageInterface),
  )
}

pub type DiscoveredPkg {
  DiscoveredPkg(
    package_name: String,
    version: String,
    package_root: String,
    deps: List(String),
  )
}

/// Everything the compiler learns about a project before lowering modules.
pub type ProjectContext {
  ProjectContext(
    project_name: String,
    version: String,
    packages_hash: String,
    dependencies: List(DiscoveredPkg),
    overlays: ffi_config.MergedOverlays,
  )
}

/// Read project metadata, fetch missing dependencies, discover packages, and
/// merge every package overlay into the configuration the compiler needs.
pub fn load_project_context(
  project_root: String,
  include_tests: Bool,
) -> Result(ProjectContext, String) {
  use #(project_name, version) <- result.try(read_project_meta(project_root))
  use _ <- result.try(ensure_deps_downloaded(project_root, include_tests))
  use packages_hash <- result.try(staging.compute_packages_dir_hash(
    project_root,
  ))
  use dependencies <- result.try(discover_all_dependencies(
    project_root,
    include_tests,
  ))
  use dep_overlays <- result.try(
    list.try_map(dependencies, fn(dep) {
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
  Ok(ProjectContext(
    project_name:,
    version:,
    packages_hash:,
    dependencies:,
    overlays:,
  ))
}

/// Make sure the `build/packages` directory exists so that dependency
/// discovery has something to walk.
///
/// Gleam normally populates that directory when it fetches dependencies. If it
/// is missing, this looks at the manifest for any dependency that is *not*
/// declared as a local `path` dependency (i.e. one that must come from Hex) and
/// runs `gleam deps download` to fetch it. All failures to read or parse the
/// manifest are treated as "nothing to do": the caller will report the real
/// error later, and this helper should not mask it.
fn ensure_deps_downloaded(
  project_root: String,
  include_tests: Bool,
) -> Result(Nil, String) {
  let packages_dir = filepath.join(project_root, "build/packages")

  // Dependencies are already fetched: nothing to check.
  case simplifile.is_directory(packages_dir) {
    Ok(True) -> Ok(Nil)
    _ -> fetch_missing_dependencies(project_root, include_tests)
  }
}

fn fetch_missing_dependencies(
  project_root: String,
  include_tests: Bool,
) -> Result(Nil, String) {
  let manifest_path = filepath.join(project_root, "gleam.toml")

  // A missing or unparsable manifest is not an error here; discovery and
  // overlays will report it with a useful message.
  case simplifile.read(manifest_path) {
    Error(_) -> Ok(Nil)
    Ok(content) ->
      case tom.parse(content) {
        Error(_) -> Ok(Nil)
        Ok(parsed_manifest) ->
          download_if_any_remote(parsed_manifest, project_root, include_tests)
      }
  }
}

fn download_if_any_remote(
  parsed_manifest: Dict(String, tom.Toml),
  project_root: String,
  include_tests: Bool,
) -> Result(Nil, String) {
  let needs_download =
    section_has_remote_dependency(parsed_manifest, "dependencies")
    || {
      include_tests
      && section_has_remote_dependency(parsed_manifest, "dev-dependencies")
    }

  case needs_download {
    False -> Ok(Nil)
    True -> run_deps_download(project_root)
  }
}

/// True when at least one entry in `section_name` lacks a `path` key, meaning
/// it has to be fetched from a package registry rather than read from disk.
fn section_has_remote_dependency(
  parsed_manifest: Dict(String, tom.Toml),
  section_name: String,
) -> Bool {
  case tom.get_table(parsed_manifest, [section_name]) {
    Error(_) -> False
    Ok(section_entries) ->
      section_entries
      |> dict.values
      |> list.any(is_remote_dependency)
  }
}

/// A dependency is local only when it is a table carrying a `path` string.
/// Bare strings (a version constraint) and tables without `path` are remote.
fn is_remote_dependency(entry: tom.Toml) -> Bool {
  case entry {
    tom.InlineTable(spec) | tom.Table(spec) ->
      case tom.get_string(spec, ["path"]) {
        Ok(_) -> False
        Error(_) -> True
      }
    _ -> True
  }
}

fn run_deps_download(project_root: String) -> Result(Nil, String) {
  let download =
    cmd.run(command: "gleam", args: ["deps", "download"], cwd: project_root)

  case download.exit_code {
    0 -> Ok(Nil)
    _ ->
      Error(
        "`gleam deps download` failed while fetching missing dependencies:\n"
        <> download.output,
      )
  }
}

/// Return True if `pkg_name` is a target-specific test/runtime package that
/// must not be transpiled from Erlang/JS sources.
pub fn is_intercepted_package(pkg_name: String) -> Bool {
  case pkg_name {
    "gleeunit" | "gleam_erlang" | "gleam_javascript" -> True
    _ -> False
  }
}

/// Read `(name, version)` from `<project_root>/gleam.toml`.
pub fn read_project_meta(
  project_root: String,
) -> Result(#(String, String), String) {
  let path = filepath.join(project_root, "gleam.toml")
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "Failed to read " <> path <> ": " <> simplifile.describe_error(err)
    }),
  )
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(fn(_) { "Failed to parse " <> path <> " as TOML" }),
  )
  use name <- result.try(
    tom.get_string(parsed, ["name"])
    |> result.map_error(fn(_) { "Missing or invalid 'name' field in " <> path }),
  )
  let version = case tom.get_string(parsed, ["version"]) {
    Ok(v) -> v
    Error(_) -> "0.1.0"
  }
  Ok(#(name, version))
}

/// Recursively discover and parse all `.gleam` modules under `base_dir`.
pub fn discover_and_parse(
  base_dir: String,
  mod_prefix: Option(String),
) -> Result(List(#(String, glance.Module, PrepassResult)), String) {
  use rel_paths <- result.try(collect_gleam_files(base_dir, ""))
  let sorted_paths = list.sort(rel_paths, string.compare)
  list.try_map(sorted_paths, fn(rel) {
    let full_path = filepath.join(base_dir, rel)
    let mod_base = filepath.strip_extension(rel)
    let mod_name = case mod_prefix {
      Some(pfx) -> pfx <> "/" <> mod_base
      None -> mod_base
    }
    use source <- result.try(
      simplifile.read(full_path)
      |> result.map_error(fn(err) {
        "Failed to read " <> full_path <> ": " <> simplifile.describe_error(err)
      }),
    )
    prepass.parse_module(mod_name, source)
    |> result.map(fn(pair) { #(mod_name, pair.0, pair.1) })
    |> result.map_error(fn(err) {
      "Failed to parse " <> full_path <> ": " <> format_glance_error(err)
    })
  })
}

/// Discover, topologically sort, parse, validate externals, and extract
/// compiler interfaces for all non-intercepted Hex and local-path dependencies
/// in `<project_root>/build/packages/` and `<project_root>/manifest.toml` /
/// `<project_root>/gleam.toml`.
pub fn load_dependencies(
  project_root: String,
  ffi_overrides: Dict(String, FfiKind),
) -> Result(List(LoadedDependency), String) {
  load_dependencies_with_options(project_root, ffi_overrides, True)
}

/// Discover and load dependencies with configurable test/dev-dependency inclusion.
pub fn load_dependencies_with_options(
  project_root: String,
  ffi_overrides: Dict(String, FfiKind),
  include_tests: Bool,
) -> Result(List(LoadedDependency), String) {
  load_dependencies_with_packages_hash(
    project_root,
    ffi_overrides,
    include_tests,
    None,
  )
}

/// Discover and topologically sort all non-intercepted Hex and local-path
/// dependencies for `project_root`.
pub fn discover_all_dependencies(
  project_root: String,
  include_tests: Bool,
) -> Result(List(DiscoveredPkg), String) {
  use #(root_name, _) <- result.try(read_project_meta(project_root))
  let packages_dir =
    project_root
    |> filepath.join("build")
    |> filepath.join("packages")

  use build_pkgs <- result.try(case simplifile.is_directory(packages_dir) {
    Ok(True) -> discover_packages(packages_dir, root_name)
    _ -> Ok([])
  })
  use local_pkgs <- result.try(discover_local_path_packages(
    project_root,
    root_name,
    include_tests,
  ))

  let combined_map =
    list.append(build_pkgs, local_pkgs)
    |> list.fold(dict.new(), fn(acc, pkg) {
      dict.insert(acc, pkg.package_name, pkg)
    })

  let discovered =
    combined_map
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(pair) { pair.1 })

  Ok(topo_sort_packages(discovered))
}

/// Like `load_dependencies_with_options`, reusing a precomputed `build/packages`
/// hash and extracting per-dependency compiler interfaces in parallel.
pub fn load_dependencies_with_packages_hash(
  project_root: String,
  ffi_overrides: Dict(String, FfiKind),
  include_tests: Bool,
  packages_hash: Option(String),
) -> Result(List(LoadedDependency), String) {
  use ordered <- result.try(discover_all_dependencies(
    project_root,
    include_tests,
  ))
  load_discovered_dependencies(
    project_root,
    ordered,
    ffi_overrides,
    dict.new(),
    packages_hash,
  )
}

/// Load, validate externals, and extract compiler interfaces for an already
/// discovered and topologically sorted list of dependencies.
pub fn load_discovered_dependencies(
  project_root: String,
  ordered: List(DiscoveredPkg),
  ffi_overrides: Dict(String, FfiKind),
  target_branches: Dict(String, TargetBranch),
  packages_hash: Option(String),
) -> Result(List(LoadedDependency), String) {
  load_discovered_dependencies_with_validation(
    project_root,
    ordered,
    ffi_overrides,
    target_branches,
    packages_hash,
    True,
  )
}

/// Like `load_discovered_dependencies`, optionally skipping the unmapped
/// external validation check (used by `gekko shim` inspection/scaffolding).
pub fn load_discovered_dependencies_with_validation(
  project_root: String,
  ordered: List(DiscoveredPkg),
  ffi_overrides: Dict(String, FfiKind),
  target_branches: Dict(String, TargetBranch),
  packages_hash: Option(String),
  validate_externals: Bool,
) -> Result(List(LoadedDependency), String) {
  cmd.parallel_try_map(ordered, fn(pkg) {
    load_single_dependency(
      project_root,
      pkg,
      ffi_overrides,
      target_branches,
      packages_hash,
      validate_externals,
    )
  })
}

fn discover_local_path_packages(
  project_root: String,
  root_name: String,
  include_tests: Bool,
) -> Result(List(DiscoveredPkg), String) {
  let manifest_path = filepath.join(project_root, "manifest.toml")
  use from_manifest <- result.try(case simplifile.is_file(manifest_path) {
    Ok(True) ->
      read_local_packages_from_manifest(manifest_path, project_root, root_name)
    _ -> Ok([])
  })
  let abs_root = paths.absolute(project_root)
  use from_toml <- result.try(collect_gleam_toml_path_deps(
    [project_root],
    root_name,
    abs_root,
    include_tests,
    set.new(),
    dict.new(),
  ))
  let by_name =
    list.fold(from_manifest, from_toml, fn(acc, pkg) {
      dict.insert(acc, pkg.package_name, pkg)
    })
  Ok(dict.values(by_name))
}

fn read_local_packages_from_manifest(
  manifest_path: String,
  project_root: String,
  root_name: String,
) -> Result(List(DiscoveredPkg), String) {
  use content <- result.try(
    simplifile.read(manifest_path)
    |> result.map_error(fn(err) {
      "Failed to read "
      <> manifest_path
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(fn(_) {
      "Failed to parse " <> manifest_path <> " as TOML"
    }),
  )
  case tom.get_array(parsed, ["packages"]) {
    Error(_) -> Ok([])
    Ok(items) ->
      Ok(
        list.filter_map(items, fn(item) {
          case item {
            tom.InlineTable(tbl) | tom.Table(tbl) ->
              case
                tom.get_string(tbl, ["source"]),
                tom.get_string(tbl, ["path"]),
                tom.get_string(tbl, ["name"])
              {
                Ok("local"), Ok(rel_or_abs), Ok(name) -> {
                  case name == root_name || is_intercepted_package(name) {
                    True -> Error(Nil)
                    False -> {
                      let pkg_root =
                        paths.resolve_against(project_root, rel_or_abs)
                      let version =
                        tom.get_string(tbl, ["version"])
                        |> result.unwrap("0.1.0")
                      let deps = case tom.get_array(tbl, ["requirements"]) {
                        Ok(reqs) ->
                          list.filter_map(reqs, fn(r) {
                            case r {
                              tom.String(s) -> Ok(s)
                              _ -> Error(Nil)
                            }
                          })
                        Error(_) -> []
                      }
                      Ok(DiscoveredPkg(
                        package_name: name,
                        version:,
                        package_root: pkg_root,
                        deps:,
                      ))
                    }
                  }
                }
                _, _, _ -> Error(Nil)
              }
            _ -> Error(Nil)
          }
        }),
      )
  }
}

fn collect_gleam_toml_path_deps(
  queue: List(String),
  root_name: String,
  abs_root: String,
  include_tests: Bool,
  visited_roots: Set(String),
  acc: Dict(String, DiscoveredPkg),
) -> Result(Dict(String, DiscoveredPkg), String) {
  case queue {
    [] -> Ok(acc)
    [cur_root, ..rest] -> {
      let norm_root = paths.absolute(cur_root)
      case set.contains(visited_roots, norm_root) {
        True ->
          collect_gleam_toml_path_deps(
            rest,
            root_name,
            abs_root,
            include_tests,
            visited_roots,
            acc,
          )
        False -> {
          let next_visited = set.insert(visited_roots, norm_root)
          let toml_path = filepath.join(norm_root, "gleam.toml")
          case simplifile.read(toml_path) {
            Error(_) ->
              collect_gleam_toml_path_deps(
                rest,
                root_name,
                abs_root,
                include_tests,
                next_visited,
                acc,
              )
            Ok(content) ->
              case tom.parse(content) {
                Error(_) ->
                  collect_gleam_toml_path_deps(
                    rest,
                    root_name,
                    abs_root,
                    include_tests,
                    next_visited,
                    acc,
                  )
                Ok(parsed) -> {
                  let raw_dep_tables = case
                    include_tests && norm_root == abs_root
                  {
                    True -> [
                      tom.get_table(parsed, ["dependencies"]),
                      tom.get_table(parsed, ["dev-dependencies"]),
                    ]
                    False -> [tom.get_table(parsed, ["dependencies"])]
                  }
                  let dep_tables = list.filter_map(raw_dep_tables, fn(r) { r })
                  let #(next_queue, next_acc) =
                    list.fold(dep_tables, #(rest, acc), fn(st, tbl) {
                      dict.fold(tbl, st, fn(st_inner, dep_name, val) {
                        let #(q, d_acc) = st_inner
                        case val {
                          tom.InlineTable(dep_tbl) | tom.Table(dep_tbl) ->
                            case tom.get_string(dep_tbl, ["path"]) {
                              Ok(rel_or_abs) -> {
                                let pkg_root =
                                  paths.resolve_against(norm_root, rel_or_abs)
                                let pkg_toml =
                                  filepath.join(pkg_root, "gleam.toml")
                                case
                                  simplifile.is_directory(pkg_root),
                                  simplifile.is_file(pkg_toml)
                                {
                                  Ok(True), Ok(True) -> {
                                    use_pkg(
                                      dep_name,
                                      pkg_root,
                                      pkg_toml,
                                      root_name,
                                      q,
                                      d_acc,
                                    )
                                  }
                                  _, _ -> st_inner
                                }
                              }
                              Error(_) -> st_inner
                            }
                          _ -> st_inner
                        }
                      })
                    })
                  collect_gleam_toml_path_deps(
                    next_queue,
                    root_name,
                    abs_root,
                    include_tests,
                    next_visited,
                    next_acc,
                  )
                }
              }
          }
        }
      }
    }
  }
}

fn use_pkg(
  fallback_name: String,
  pkg_root: String,
  pkg_toml: String,
  root_name: String,
  queue: List(String),
  acc: Dict(String, DiscoveredPkg),
) -> #(List(String), Dict(String, DiscoveredPkg)) {
  case read_package_manifest(pkg_toml, fallback_name) {
    Ok(#(name, version, deps)) ->
      case name == root_name || is_intercepted_package(name) {
        True -> #(queue, acc)
        False -> {
          let pkg =
            DiscoveredPkg(
              package_name: name,
              version:,
              package_root: pkg_root,
              deps:,
            )
          #([pkg_root, ..queue], dict.insert(acc, name, pkg))
        }
      }
    Error(_) -> #(queue, acc)
  }
}

fn discover_packages(
  packages_dir: String,
  root_name: String,
) -> Result(List(DiscoveredPkg), String) {
  use entries <- result.try(
    simplifile.read_directory(at: packages_dir)
    |> result.map_error(fn(err) {
      "Failed to read packages directory "
      <> packages_dir
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )

  let sorted_entries = list.sort(entries, string.compare)
  list.try_fold(sorted_entries, [], fn(acc, entry) {
    let pkg_root = filepath.join(packages_dir, entry)
    let toml_path = filepath.join(pkg_root, "gleam.toml")
    let src_dir = filepath.join(pkg_root, "src")
    case
      simplifile.is_directory(pkg_root),
      simplifile.is_file(toml_path),
      simplifile.is_directory(src_dir)
    {
      Ok(True), Ok(True), Ok(True) -> {
        use #(name, version, deps) <- result.try(read_package_manifest(
          toml_path,
          entry,
        ))
        case name == root_name || is_intercepted_package(name) {
          True -> Ok(acc)
          False ->
            Ok([
              DiscoveredPkg(
                package_name: name,
                version:,
                package_root: pkg_root,
                deps:,
              ),
              ..acc
            ])
        }
      }
      _, _, _ -> Ok(acc)
    }
  })
  |> result.map(list.reverse)
}

fn read_package_manifest(
  toml_path: String,
  fallback_name: String,
) -> Result(#(String, String, List(String)), String) {
  use content <- result.try(
    simplifile.read(toml_path)
    |> result.map_error(fn(err) {
      "Failed to read " <> toml_path <> ": " <> simplifile.describe_error(err)
    }),
  )
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(fn(_) { "Failed to parse " <> toml_path <> " as TOML" }),
  )
  let name = case tom.get_string(parsed, ["name"]) {
    Ok(n) -> n
    Error(_) -> fallback_name
  }
  let version = case tom.get_string(parsed, ["version"]) {
    Ok(v) -> v
    Error(_) -> "0.1.0"
  }
  let deps = case tom.get_table(parsed, ["dependencies"]) {
    Ok(tbl) ->
      tbl
      |> dict.keys
      |> list.sort(string.compare)
    Error(_) -> []
  }
  Ok(#(name, version, deps))
}

fn topo_sort_packages(pkgs: List(DiscoveredPkg)) -> List(DiscoveredPkg) {
  let by_name =
    list.fold(pkgs, dict.new(), fn(acc, pkg) {
      dict.insert(acc, pkg.package_name, pkg)
    })

  let #(_, rev_ordered) =
    list.fold(pkgs, #(set.new(), []), fn(state, pkg) {
      visit_pkg(pkg.package_name, by_name, set.new(), state)
    })
  list.reverse(rev_ordered)
}

fn visit_pkg(
  name: String,
  by_name: Dict(String, DiscoveredPkg),
  visiting: Set(String),
  state: #(Set(String), List(DiscoveredPkg)),
) -> #(Set(String), List(DiscoveredPkg)) {
  let #(visited, acc) = state
  case set.contains(visited, name) || set.contains(visiting, name) {
    True -> state
    False ->
      case dict.get(by_name, name) {
        Error(_) -> state
        Ok(pkg) -> {
          let next_visiting = set.insert(visiting, name)
          let #(visited1, acc1) =
            list.fold(pkg.deps, #(visited, acc), fn(st, dep) {
              visit_pkg(dep, by_name, next_visiting, st)
            })
          #(set.insert(visited1, name), [pkg, ..acc1])
        }
      }
  }
}

fn load_single_dependency(
  project_root: String,
  pkg: DiscoveredPkg,
  ffi_overrides: Dict(String, FfiKind),
  target_branches: Dict(String, TargetBranch),
  packages_hash: Option(String),
  validate_externals: Bool,
) -> Result(LoadedDependency, String) {
  let src_dir = filepath.join(pkg.package_root, "src")
  use modules <- result.try(case simplifile.is_directory(src_dir) {
    Ok(True) -> discover_and_parse(src_dir, None)
    _ -> Ok([])
  })
  case modules {
    [] ->
      Ok(LoadedDependency(
        package_name: pkg.package_name,
        version: pkg.version,
        package_root: pkg.package_root,
        modules: [],
        interface: None,
      ))
    _ -> {
      use _ <- result.try(case validate_externals {
        True ->
          validate_dependency_externals(
            pkg.package_name,
            modules,
            ffi_overrides,
            target_branches,
          )
        False -> Ok(Nil)
      })

      let dep_staging =
        project_root
        |> filepath.join("build")
        |> filepath.join(".gekko_staging_deps")
        |> filepath.join(pkg.package_name)
      use iface <- result.try(
        staging.extract_package_interface_with_packages_hash(
          pkg.package_root,
          project_root,
          dep_staging,
          packages_hash,
        ),
      )

      Ok(LoadedDependency(
        package_name: pkg.package_name,
        version: pkg.version,
        package_root: pkg.package_root,
        modules:,
        interface: Some(iface),
      ))
    }
  }
}

fn validate_dependency_externals(
  pkg_name: String,
  modules: List(#(String, glance.Module, PrepassResult)),
  ffi_overrides: Dict(String, FfiKind),
  target_branches: Dict(String, TargetBranch),
) -> Result(Nil, String) {
  let rev_errors =
    list.fold(modules, [], fn(acc, entry) {
      let #(mod_name, ast_mod, prepass_res) = entry
      let branch =
        symbol_table.resolve_target_branch(pkg_name, mod_name, target_branches)
      let active_fns =
        list.filter(ast_mod.functions, fn(fn_def) {
          !symbol_table.is_excluded_for_branch(fn_def.attributes, branch)
        })
      let fn_infos =
        list.fold(active_fns, dict.new(), fn(fn_acc, fn_def) {
          let fn_name = fn_def.definition.name
          let ffi =
            symbol_table.resolve_function_ffi(
              pkg_name,
              mod_name,
              fn_name,
              prepass_res,
              ffi_overrides,
            )
          let info =
            symbol_table.FunctionInfo(
              module: mod_name,
              name: fn_name,
              publicity: fn_def.definition.publicity,
              arity: list.length(fn_def.definition.parameters),
              parameters: [],
              return_type: None,
              resolved: None,
              ffi:,
              has_erlang_or_js_external: False,
              has_gleam_body: fn_def.definition.body != [],
            )
          dict.insert(fn_acc, fn_name, info)
        })
      let reachable =
        symbol_table.reachable_private_functions_for_branch(
          ast_mod,
          fn_infos,
          branch,
        )
      list.fold(active_fns, acc, fn(err_acc, fn_def) {
        let fn_name = fn_def.definition.name
        case set.contains(reachable, fn_name) {
          False -> err_acc
          True -> {
            let has_erl_or_js = has_erlang_or_js_external(fn_def.attributes)
            let has_ffi_mapping =
              symbol_table.resolve_function_ffi(
                pkg_name,
                mod_name,
                fn_name,
                prepass_res,
                ffi_overrides,
              )
              != None
            let has_fallback_body = fn_def.definition.body != []
            case has_erl_or_js && !has_ffi_mapping && !has_fallback_body {
              True -> {
                let #(line, col) =
                  text_edit.byte_offset_to_line_col(
                    prepass_res.cleaned_source,
                    fn_def.definition.location.start,
                  )
                let msg =
                  "Unmapped external function "
                  <> pkg_name
                  <> ":"
                  <> mod_name
                  <> "."
                  <> fn_name
                  <> " at "
                  <> pkg_name
                  <> ":src/"
                  <> mod_name
                  <> ".gleam:"
                  <> int.to_string(line)
                  <> ":"
                  <> int.to_string(col)
                  <> " (run 'gekko shim new "
                  <> pkg_name
                  <> "' to scaffold a companion shim, or add #gekko.patch in patches/)"
                [msg, ..err_acc]
              }
              False -> err_acc
            }
          }
        }
      })
    })
  case rev_errors {
    [] -> Ok(Nil)
    _ -> Error(string.join(list.reverse(rev_errors), "\n"))
  }
}

fn has_erlang_or_js_external(attributes: List(glance.Attribute)) -> Bool {
  list.any(attributes, fn(attr) {
    case attr.name, attr.arguments {
      "external", [glance.Variable(name: "erlang", ..), ..]
      | "external", [glance.Variable(name: "javascript", ..), ..]
      -> True
      _, _ -> False
    }
  })
}

fn collect_gleam_files(
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
      "Failed to read directory "
      <> current
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  list.try_fold(entries, [], fn(acc, entry) {
    let rel = case rel_prefix {
      "" -> entry
      _ -> filepath.join(rel_prefix, entry)
    }
    let full = filepath.join(base_dir, rel)
    case simplifile.is_directory(full) {
      Ok(True) -> {
        use nested <- result.try(collect_gleam_files(base_dir, rel))
        Ok(list.append(acc, nested))
      }
      Ok(False) ->
        case filepath.extension(rel) {
          Ok("gleam") -> Ok([rel, ..acc])
          _ -> Ok(acc)
        }
      Error(err) ->
        Error(
          "Failed to stat " <> full <> ": " <> simplifile.describe_error(err),
        )
    }
  })
}

fn format_glance_error(err: glance.Error) -> String {
  case err {
    glance.UnexpectedEndOfInput -> "unexpected end of input"
    glance.UnexpectedToken(token: _, position:) ->
      "unexpected token at byte offset " <> string.inspect(position.byte_offset)
  }
}
