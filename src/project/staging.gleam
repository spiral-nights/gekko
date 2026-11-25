import filepath
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import glexer
import glexer/token.{type Token}
import project/cmd
import project/interface.{
  type ModuleInterface, type PackageInterface, type ResolvedType, FnType,
  ModuleInterface, NamedType, PackageInterface, ResolvedConstant,
  ResolvedFunction, ResolvedParam, ResolvedTypeAlias, ResolvedTypeDef,
  ResolvedVariant, ResolvedVariantField, TupleType, VariableType,
}
import project/paths
import project/prepass

import project/text_edit.{
  type TextEdit, TextEdit, apply_edits, skip_trivia, token_end,
}
import simplifile
import tom

/// Preprocess `@external(moonbit, ...)` directives and promote all top-level
/// private `fn`, `type`, `opaque type`, and `const` declarations to `pub`
/// (stripping `@internal` attributes) so `gleam export package-interface`
/// outputs compiler-inferred Hindley-Milner signatures for every item.
pub fn promote_private_to_pub(source: String) -> String {
  let cleaned = prepass.preprocess_module("", source).cleaned_source
  let tokens =
    glexer.new(cleaned)
    |> glexer.lex

  let edits = collect_pub_edits(tokens, 0, False, False, False, [])
  apply_edits(cleaned, edits)
}

/// Remove any root-table `internal_modules = [...]` setting in `gleam.toml`
/// and prepend `internal_modules = []` so internal modules are included in
/// `gleam export package-interface`.
pub fn override_gleam_toml_internal_modules(toml_src: String) -> String {
  let lines = string.split(toml_src, "\n")
  let filtered = filter_root_internal_modules(lines, True, False, 0, [])
  "internal_modules = []\n" <> string.join(filtered, "\n")
}

/// Merge `[dev-dependencies]` entries into `[dependencies]` (creating
/// `[dependencies]` if missing) and remove `[dev-dependencies]` so staged
/// `test/` modules have access to dev-dependencies during
/// `gleam export package-interface`.
pub fn merge_dev_dependencies_into_dependencies(toml_src: String) -> String {
  let lines = string.split(toml_src, "\n")
  let #(deps_keys, dev_lines, stripped_lines) =
    extract_dev_deps_and_keys(lines, 0, set.new(), [], [])
  let missing_dev_lines =
    list.filter(dev_lines, fn(line) {
      case parse_toml_key(line) {
        Some(key) -> !set.contains(deps_keys, key)
        None -> False
      }
    })
  case missing_dev_lines {
    [] -> string.join(stripped_lines, "\n")
    _ -> insert_into_dependencies_section(stripped_lines, missing_dev_lines)
  }
}

fn extract_dev_deps_and_keys(
  lines: List(String),
  section: Int,
  deps_keys: Set(String),
  rev_dev_lines: List(String),
  rev_out: List(String),
) -> #(Set(String), List(String), List(String)) {
  // section: 0 = other, 1 = [dependencies], 2 = [dev-dependencies]
  case lines {
    [] -> #(deps_keys, list.reverse(rev_dev_lines), list.reverse(rev_out))
    [line, ..rest] -> {
      let header = strip_toml_line_comment(line)
      let trimmed = string.trim(line)
      case
        string.starts_with(header, "[") && !string.starts_with(header, "[[")
      {
        True ->
          case header {
            "[dependencies]" ->
              extract_dev_deps_and_keys(rest, 1, deps_keys, rev_dev_lines, [
                line,
                ..rev_out
              ])
            "[dev-dependencies]" ->
              extract_dev_deps_and_keys(
                rest,
                2,
                deps_keys,
                rev_dev_lines,
                rev_out,
              )
            _ ->
              extract_dev_deps_and_keys(rest, 0, deps_keys, rev_dev_lines, [
                line,
                ..rev_out
              ])
          }
        False ->
          case section {
            1 -> {
              let next_keys = case parse_toml_key(trimmed) {
                Some(k) -> set.insert(deps_keys, k)
                None -> deps_keys
              }
              extract_dev_deps_and_keys(rest, 1, next_keys, rev_dev_lines, [
                line,
                ..rev_out
              ])
            }
            2 -> {
              let next_dev = case
                trimmed != "" && !string.starts_with(trimmed, "#")
              {
                True -> [line, ..rev_dev_lines]
                False -> rev_dev_lines
              }
              extract_dev_deps_and_keys(rest, 2, deps_keys, next_dev, rev_out)
            }
            _ ->
              extract_dev_deps_and_keys(rest, 0, deps_keys, rev_dev_lines, [
                line,
                ..rev_out
              ])
          }
      }
    }
  }
}

fn parse_toml_key(line: String) -> Option(String) {
  let trimmed = string.trim(line)
  case trimmed == "" || string.starts_with(trimmed, "#") {
    True -> None
    False ->
      case string.split_once(trimmed, "=") {
        Ok(#(lhs, _)) -> {
          let key = string.trim(lhs)
          case key == "" {
            True -> None
            False -> Some(key)
          }
        }
        Error(_) -> None
      }
  }
}

fn insert_into_dependencies_section(
  lines: List(String),
  dev_lines: List(String),
) -> String {
  let #(found, rev_out) = insert_deps_loop(lines, False, False, dev_lines, [])
  let final_lines = case found {
    True -> list.reverse(rev_out)
    False ->
      list.flatten([
        list.reverse(rev_out),
        ["", "[dependencies]", ..dev_lines],
      ])
  }
  string.join(final_lines, "\n")
}

fn insert_deps_loop(
  lines: List(String),
  in_deps: Bool,
  inserted: Bool,
  dev_lines: List(String),
  rev_acc: List(String),
) -> #(Bool, List(String)) {
  case lines {
    [] ->
      case in_deps && !inserted {
        True -> #(True, list.append(list.reverse(dev_lines), rev_acc))
        False -> #(inserted, rev_acc)
      }
    [line, ..rest] -> {
      let header = strip_toml_line_comment(line)
      case
        string.starts_with(header, "[") && !string.starts_with(header, "[[")
      {
        True ->
          case in_deps && !inserted {
            True -> {
              let with_dev = list.append(list.reverse(dev_lines), rev_acc)
              insert_deps_loop(
                rest,
                header == "[dependencies]",
                True,
                dev_lines,
                [line, ..with_dev],
              )
            }
            False ->
              insert_deps_loop(
                rest,
                header == "[dependencies]",
                inserted,
                dev_lines,
                [line, ..rev_acc],
              )
          }
        False ->
          insert_deps_loop(rest, in_deps, inserted, dev_lines, [line, ..rev_acc])
      }
    }
  }
}

/// Stage a transformed copy of `project_root` inside `staging_dir`, run
/// `gleam export package-interface --out interface.json`, and decode the result.
pub fn extract_project_interface(
  project_root: String,
  staging_dir: String,
) -> Result(PackageInterface, String) {
  extract_project_interface_with_options(project_root, staging_dir, True)
}

/// Stage a transformed copy of `project_root` inside `staging_dir` (optionally
/// including `test/` modules and `[dev-dependencies]`), run
/// `gleam export package-interface --out interface.json`, and decode the result.
pub fn extract_project_interface_with_options(
  project_root: String,
  staging_dir: String,
  include_tests: Bool,
) -> Result(PackageInterface, String) {
  extract_package_interface_impl(
    project_root,
    project_root,
    staging_dir,
    include_tests,
    None,
  )
}

/// Like `extract_project_interface_with_options`, reusing a precomputed hash
/// of `build/packages` when provided.
pub fn extract_project_interface_with_packages_hash(
  project_root: String,
  staging_dir: String,
  include_tests: Bool,
  packages_hash: Option(String),
) -> Result(PackageInterface, String) {
  extract_package_interface_impl(
    project_root,
    project_root,
    staging_dir,
    include_tests,
    packages_hash,
  )
}

pub fn extract_package_interface_with_packages_hash(
  pkg_root: String,
  deps_root: String,
  staging_dir: String,
  packages_hash: Option(String),
) -> Result(PackageInterface, String) {
  let is_root_pkg = paths.absolute(pkg_root) == paths.absolute(deps_root)
  extract_package_interface_impl(
    pkg_root,
    deps_root,
    staging_dir,
    is_root_pkg,
    packages_hash,
  )
}

/// Compute a deterministic SHA-256 hash of `<root_dir>/build/packages` (or `""`
/// if the directory does not exist) so callers can share it across staging calls.
pub fn compute_packages_dir_hash(root_dir: String) -> Result(String, String) {
  let packages_dir = filepath.join(root_dir, filepath.join("build", "packages"))
  case simplifile.is_directory(packages_dir) {
    Ok(True) -> hash_packages_dir(packages_dir)
    _ -> Ok("")
  }
}

fn extract_package_interface_impl(
  pkg_root: String,
  deps_root: String,
  staging_dir: String,
  include_tests: Bool,
  precomputed_packages_hash: Option(String),
) -> Result(PackageInterface, String) {
  let is_root_pkg = paths.absolute(pkg_root) == paths.absolute(deps_root)
  let hash_path = filepath.join(staging_dir, ".gekko_iface_hash")
  let test_mods_path = filepath.join(staging_dir, ".gekko_test_mods")
  let json_path = filepath.join(staging_dir, "interface.json")
  let fingerprint_res =
    compute_staging_fingerprint(
      pkg_root,
      deps_root,
      include_tests,
      precomputed_packages_hash,
    )

  let cached = case fingerprint_res {
    Ok(fingerprint) ->
      case
        simplifile.read(hash_path),
        simplifile.read(json_path),
        simplifile.read(test_mods_path)
      {
        Ok(saved_hash), Ok(json_str), Ok(test_mods_raw)
          if saved_hash == fingerprint
        ->
          case interface.decode_package_interface(json_str) {
            Ok(iface) -> {
              let staged_test_mods =
                test_mods_raw
                |> string.split("\n")
                |> list.filter(fn(s) { s != "" })
              Some(remap_staged_test_modules(iface, staged_test_mods))
            }
            Error(_) -> None
          }
        _, _, _ -> None
      }
    Error(_) -> None
  }

  case cached {
    Some(iface) -> Ok(iface)
    None -> {
      use _ <- result.try(prepare_staging_dir(staging_dir))
      use _ <- result.try(stage_toml_and_deps(
        pkg_root,
        deps_root,
        staging_dir,
        include_tests,
      ))
      use _ <- result.try(stage_sources(pkg_root, staging_dir))
      use staged_test_mods <- result.try(case is_root_pkg && include_tests {
        True -> stage_test_sources(pkg_root, staging_dir)
        False -> Ok([])
      })

      let res =
        cmd.run(
          command: "gleam",
          args: ["export", "package-interface", "--out", "interface.json"],
          cwd: staging_dir,
        )

      case res.exit_code {
        0 -> {
          use json_str <- result.try(
            simplifile.read(json_path)
            |> result.map_error(fn(err) {
              "Failed to read staged interface.json: "
              <> simplifile.describe_error(err)
            }),
          )
          use iface <- result.try(interface.decode_package_interface(json_str))
          case fingerprint_res {
            Ok(fingerprint) -> {
              let _ =
                simplifile.write(
                  to: test_mods_path,
                  contents: string.join(staged_test_mods, "\n"),
                )
              let _ = simplifile.write(to: hash_path, contents: fingerprint)
              Nil
            }
            Error(_) -> Nil
          }
          Ok(remap_staged_test_modules(iface, staged_test_mods))
        }
        code ->
          Error(
            "gleam export package-interface failed (exit "
            <> int.to_string(code)
            <> "):\n"
            <> res.output,
          )
      }
    }
  }
}

fn compute_staging_fingerprint(
  pkg_root: String,
  deps_root: String,
  include_tests: Bool,
  precomputed_packages_hash: Option(String),
) -> Result(String, String) {
  let is_root_pkg = paths.absolute(pkg_root) == paths.absolute(deps_root)
  let inc_flag = case include_tests {
    True -> "1"
    False -> "0"
  }
  use pkg_toml <- result.try(
    read_optional_text(filepath.join(pkg_root, "gleam.toml")),
  )
  use deps_toml <- result.try(
    read_optional_text(filepath.join(deps_root, "gleam.toml")),
  )
  use manifest_toml <- result.try(
    read_optional_text(filepath.join(deps_root, "manifest.toml")),
  )
  use src_hash <- result.try(hash_gleam_tree(filepath.join(pkg_root, "src")))
  use test_hash <- result.try(case is_root_pkg && include_tests {
    True -> hash_gleam_tree(filepath.join(pkg_root, "test"))
    False -> Ok("")
  })
  use pkgs_hash <- result.try(case precomputed_packages_hash {
    Some(h) -> Ok(h)
    None -> {
      let packages_dir =
        first_existing_path(
          deps_root,
          pkg_root,
          filepath.join("build", "packages"),
          simplifile.is_directory,
        )
      case packages_dir {
        Some(dir) -> hash_packages_dir(dir)
        None -> Ok("")
      }
    }
  })
  let payload =
    string.join(
      [
        inc_flag,
        pkg_toml,
        deps_toml,
        manifest_toml,
        src_hash,
        test_hash,
        pkgs_hash,
      ],
      "\n<<GEKKO_SEP>>\n",
    )
  Ok(cmd.sha256_hex(payload))
}

fn read_optional_text(path: String) -> Result(String, String) {
  case simplifile.is_file(path) {
    Ok(True) ->
      simplifile.read(path)
      |> result.map_error(fn(err) {
        "Failed to read " <> path <> ": " <> simplifile.describe_error(err)
      })
    _ -> Ok("")
  }
}

fn hash_gleam_tree(dir: String) -> Result(String, String) {
  case simplifile.is_directory(dir) {
    Ok(True) -> {
      use rels <- result.try(walk_relative_files(dir, ""))
      let sorted =
        rels
        |> list.filter(fn(r) { filepath.extension(r) == Ok("gleam") })
        |> list.sort(string.compare)
      use parts <- result.try(
        list.try_map(sorted, fn(rel) {
          let full = filepath.join(dir, rel)
          use content <- result.try(
            simplifile.read(full)
            |> result.map_error(fn(err) {
              "Failed to read "
              <> full
              <> ": "
              <> simplifile.describe_error(err)
            }),
          )
          Ok(rel <> ":" <> content)
        }),
      )
      Ok(cmd.sha256_hex(string.join(parts, "\n<<F>>\n")))
    }
    _ -> Ok("")
  }
}

fn hash_packages_dir(packages_dir: String) -> Result(String, String) {
  use entries <- result.try(
    simplifile.read_directory(at: packages_dir)
    |> result.map_error(fn(err) {
      "Failed to read "
      <> packages_dir
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  let sorted_entries = list.sort(entries, string.compare)
  use parts <- result.try(
    list.try_map(sorted_entries, fn(entry) {
      let pkg_dir = filepath.join(packages_dir, entry)
      case simplifile.is_directory(pkg_dir) {
        Ok(True) -> {
          use toml <- result.try(
            read_optional_text(filepath.join(pkg_dir, "gleam.toml")),
          )
          use src_h <- result.try(
            hash_gleam_tree(filepath.join(pkg_dir, "src")),
          )
          Ok(entry <> ":" <> toml <> ":" <> src_h)
        }
        _ -> Ok("")
      }
    }),
  )
  Ok(cmd.sha256_hex(string.join(parts, "\n<<PKG>>\n")))
}

fn prepare_staging_dir(staging_dir: String) -> Result(Nil, String) {
  let staging_packages =
    staging_dir
    |> filepath.join("build")
    |> filepath.join("packages")
  let _ = simplifile.delete(file_or_dir_at: staging_packages)

  let staging_src = filepath.join(staging_dir, "src")
  let _ = simplifile.delete(file_or_dir_at: staging_src)
  let _ =
    simplifile.delete_file(at: filepath.join(staging_dir, "interface.json"))
  let _ =
    simplifile.delete_file(at: filepath.join(staging_dir, "manifest.toml"))

  simplifile.create_directory_all(staging_src)
  |> result.map_error(fn(err) {
    "Failed to create staging directory "
    <> staging_src
    <> ": "
    <> simplifile.describe_error(err)
  })
}

fn stage_toml_and_deps(
  pkg_root: String,
  deps_root: String,
  staging_dir: String,
  include_tests: Bool,
) -> Result(Nil, String) {
  let abs_pkg = paths.absolute(pkg_root)
  let abs_deps = paths.absolute(deps_root)
  let is_dep_staging = abs_pkg != abs_deps

  let packages_rel = filepath.join("build", "packages")
  use staged_pkg_paths <- result.try(
    case
      first_existing_path(
        deps_root,
        pkg_root,
        packages_rel,
        simplifile.is_directory,
      )
    {
      Some(src_packages) -> {
        let staging_build = filepath.join(staging_dir, "build")
        use _ <- result.try(
          simplifile.create_directory_all(staging_build)
          |> result.map_error(fn(err) {
            "Failed to create staging build dir: "
            <> simplifile.describe_error(err)
          }),
        )
        let dest_packages = filepath.join(staging_build, "packages")
        let _ = simplifile.delete(file_or_dir_at: dest_packages)
        use _ <- result.try(copy_packages_isolated(src_packages, dest_packages))
        collect_staged_package_paths(dest_packages)
      }
      None -> Ok(dict.new())
    },
  )

  let src_gleam_toml = filepath.join(pkg_root, "gleam.toml")
  let dest_gleam_toml = filepath.join(staging_dir, "gleam.toml")
  use toml_content <- result.try(
    simplifile.read(src_gleam_toml)
    |> result.map_error(fn(err) {
      "Failed to read "
      <> src_gleam_toml
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )

  case is_dep_staging {
    False -> {
      let base_toml = resolve_toml_relative_paths(toml_content, abs_pkg)
      let with_deps_toml = case include_tests {
        True -> merge_dev_dependencies_into_dependencies(base_toml)
        False -> base_toml
      }
      let rewritten_toml = override_gleam_toml_internal_modules(with_deps_toml)
      use _ <- result.try(
        simplifile.write(to: dest_gleam_toml, contents: rewritten_toml)
        |> result.map_error(fn(err) {
          "Failed to write "
          <> dest_gleam_toml
          <> ": "
          <> simplifile.describe_error(err)
        }),
      )
      let src_manifest =
        first_existing_path(
          deps_root,
          pkg_root,
          "manifest.toml",
          simplifile.is_file,
        )
      let dest_manifest = filepath.join(staging_dir, "manifest.toml")
      case src_manifest {
        Some(path) -> {
          use manifest_content <- result.try(
            simplifile.read(path)
            |> result.map_error(fn(err) {
              "Failed to read "
              <> path
              <> ": "
              <> simplifile.describe_error(err)
            }),
          )
          let rewritten_manifest =
            resolve_toml_relative_paths(manifest_content, abs_deps)
          simplifile.write(to: dest_manifest, contents: rewritten_manifest)
          |> result.map_error(fn(err) {
            "Failed to write staged manifest.toml: "
            <> simplifile.describe_error(err)
          })
        }
        None -> Ok(Nil)
      }
    }

    True -> {
      let local_dep_paths = collect_root_local_dep_paths(abs_deps)
      let dep_paths = dict.merge(staged_pkg_paths, local_dep_paths)
      use _ <- result.try(rewrite_staged_packages_tomls(
        staged_pkg_paths,
        dep_paths,
      ))
      let rewritten_toml =
        toml_content
        |> resolve_toml_relative_paths(abs_pkg)
        |> strip_dev_dependencies
        |> rewrite_dependencies_to_paths(dep_paths)
        |> override_gleam_toml_internal_modules
      simplifile.write(to: dest_gleam_toml, contents: rewritten_toml)
      |> result.map_error(fn(err) {
        "Failed to write "
        <> dest_gleam_toml
        <> ": "
        <> simplifile.describe_error(err)
      })
    }
  }
}

fn collect_staged_package_paths(
  dest_packages: String,
) -> Result(Dict(String, String), String) {
  let abs_dest = paths.absolute(dest_packages)
  use entries <- result.try(
    simplifile.read_directory(at: dest_packages)
    |> result.map_error(fn(err) {
      "Failed to read staged packages: " <> simplifile.describe_error(err)
    }),
  )
  Ok(
    list.fold(entries, dict.new(), fn(acc, entry) {
      let pkg_dir = filepath.join(abs_dest, entry)
      let toml_path = filepath.join(pkg_dir, "gleam.toml")
      case simplifile.is_directory(pkg_dir), simplifile.is_file(toml_path) {
        Ok(True), Ok(True) -> dict.insert(acc, entry, pkg_dir)
        _, _ -> acc
      }
    }),
  )
}

fn collect_root_local_dep_paths(abs_deps: String) -> Dict(String, String) {
  let from_manifest = case
    simplifile.read(filepath.join(abs_deps, "manifest.toml"))
  {
    Error(_) -> dict.new()
    Ok(content) ->
      case tom.parse(content) {
        Error(_) -> dict.new()
        Ok(parsed) ->
          case tom.get_array(parsed, ["packages"]) {
            Error(_) -> dict.new()
            Ok(items) ->
              list.fold(items, dict.new(), fn(acc, item) {
                case item {
                  tom.InlineTable(tbl) | tom.Table(tbl) ->
                    case
                      tom.get_string(tbl, ["source"]),
                      tom.get_string(tbl, ["path"]),
                      tom.get_string(tbl, ["name"])
                    {
                      Ok("local"), Ok(rel), Ok(name) ->
                        dict.insert(
                          acc,
                          name,
                          paths.resolve_against(abs_deps, rel),
                        )
                      _, _, _ -> acc
                    }
                  _ -> acc
                }
              })
          }
      }
  }
  case simplifile.read(filepath.join(abs_deps, "gleam.toml")) {
    Error(_) -> from_manifest
    Ok(content) ->
      case tom.parse(content) {
        Error(_) -> from_manifest
        Ok(parsed) ->
          case tom.get_table(parsed, ["dependencies"]) {
            Error(_) -> from_manifest
            Ok(tbl) ->
              dict.fold(tbl, from_manifest, fn(acc, name, val) {
                case val {
                  tom.InlineTable(dep_tbl) | tom.Table(dep_tbl) ->
                    case tom.get_string(dep_tbl, ["path"]) {
                      Ok(rel) ->
                        dict.insert(
                          acc,
                          name,
                          paths.resolve_against(abs_deps, rel),
                        )
                      Error(_) -> acc
                    }
                  _ -> acc
                }
              })
          }
      }
  }
}

fn rewrite_staged_packages_tomls(
  staged_pkg_paths: Dict(String, String),
  dep_paths: Dict(String, String),
) -> Result(Nil, String) {
  dict.values(staged_pkg_paths)
  |> list.try_each(fn(pkg_dir) {
    let toml_path = filepath.join(pkg_dir, "gleam.toml")
    use content <- result.try(
      simplifile.read(toml_path)
      |> result.map_error(fn(err) {
        "Failed to read " <> toml_path <> ": " <> simplifile.describe_error(err)
      }),
    )
    let updated =
      content
      |> strip_dev_dependencies
      |> rewrite_dependencies_to_paths(dep_paths)
    simplifile.write(to: toml_path, contents: updated)
    |> result.map_error(fn(err) {
      "Failed to write " <> toml_path <> ": " <> simplifile.describe_error(err)
    })
  })
}

fn strip_dev_dependencies(toml_src: String) -> String {
  let lines = string.split(toml_src, "\n")
  strip_section_loop(lines, False, [])
  |> string.join("\n")
}

fn strip_section_loop(
  lines: List(String),
  skipping: Bool,
  rev_acc: List(String),
) -> List(String) {
  case lines {
    [] -> list.reverse(rev_acc)
    [line, ..rest] -> {
      let header = strip_toml_line_comment(line)
      case
        string.starts_with(header, "[") && !string.starts_with(header, "[[")
      {
        True -> {
          let is_dev_deps = header == "[dev-dependencies]"
          let next_acc = case is_dev_deps {
            True -> rev_acc
            False -> [line, ..rev_acc]
          }
          strip_section_loop(rest, is_dev_deps, next_acc)
        }
        False ->
          case skipping {
            True -> strip_section_loop(rest, True, rev_acc)
            False -> strip_section_loop(rest, False, [line, ..rev_acc])
          }
      }
    }
  }
}

fn rewrite_dependencies_to_paths(
  toml_src: String,
  dep_paths: Dict(String, String),
) -> String {
  let lines = string.split(toml_src, "\n")
  rewrite_deps_loop(lines, False, dep_paths, [])
  |> string.join("\n")
}

fn rewrite_deps_loop(
  lines: List(String),
  in_deps: Bool,
  dep_paths: Dict(String, String),
  rev_acc: List(String),
) -> List(String) {
  case lines {
    [] -> list.reverse(rev_acc)
    [line, ..rest] -> {
      let header = strip_toml_line_comment(line)
      let trimmed = string.trim(line)
      case
        string.starts_with(header, "[") && !string.starts_with(header, "[[")
      {
        True ->
          rewrite_deps_loop(rest, header == "[dependencies]", dep_paths, [
            line,
            ..rev_acc
          ])
        False ->
          case in_deps {
            False ->
              rewrite_deps_loop(rest, False, dep_paths, [line, ..rev_acc])
            True ->
              case string.split_once(trimmed, "=") {
                Ok(#(lhs, _)) -> {
                  let key = string.trim(lhs)
                  case dict.get(dep_paths, key) {
                    Ok(abs_path) -> {
                      let new_line =
                        key
                        <> " = { path = \""
                        <> escape_toml_str(abs_path)
                        <> "\" }"
                      rewrite_deps_loop(rest, True, dep_paths, [
                        new_line,
                        ..rev_acc
                      ])
                    }
                    Error(_) ->
                      rewrite_deps_loop(rest, True, dep_paths, [line, ..rev_acc])
                  }
                }
                Error(_) ->
                  rewrite_deps_loop(rest, True, dep_paths, [line, ..rev_acc])
              }
          }
      }
    }
  }
}

fn escape_toml_str(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

/// Resolve any relative `path = "..."` TOML values against `abs_base_dir`,
/// ignoring comments and unrelated string literals.
fn resolve_toml_relative_paths(
  toml_src: String,
  abs_base_dir: String,
) -> String {
  scan_toml_chars(string.to_graphemes(toml_src), abs_base_dir, "", False, [])
  |> string.concat
}

fn scan_toml_chars(
  chars: List(String),
  base_dir: String,
  last_ident: String,
  saw_eq: Bool,
  rev_out: List(String),
) -> List(String) {
  case chars {
    [] -> list.reverse(rev_out)
    ["#", ..rest] -> {
      let #(comment, after) = take_until_newline(rest, ["#"])
      scan_toml_chars(after, base_dir, "", False, [comment, ..rev_out])
    }
    ["'", ..rest] -> {
      let #(lit, after) = take_single_quoted(rest, ["'"])
      scan_toml_chars(after, base_dir, "", False, [lit, ..rev_out])
    }
    ["\"", ..rest] -> {
      let #(raw_inner, raw_full, after) = take_double_quoted(rest, [], ["\""])
      let emitted = case last_ident == "path" && saw_eq && raw_inner != "" {
        True ->
          case filepath.is_absolute(raw_inner) {
            True -> raw_full
            False ->
              "\""
              <> escape_toml_str(paths.resolve_against(base_dir, raw_inner))
              <> "\""
          }
        False -> raw_full
      }
      scan_toml_chars(after, base_dir, "", False, [emitted, ..rev_out])
    }
    ["=", ..rest] ->
      scan_toml_chars(rest, base_dir, last_ident, last_ident != "", [
        "=",
        ..rev_out
      ])
    [" ", ..rest] | ["\t", ..rest] ->
      scan_toml_chars(rest, base_dir, last_ident, saw_eq, [
        case chars {
          ["\t", ..] -> "\t"
          _ -> " "
        },
        ..rev_out
      ])
    [ch, ..rest] ->
      case is_toml_ident_char(ch) {
        True -> {
          let next_ident = case saw_eq {
            True -> ch
            False -> last_ident <> ch
          }
          scan_toml_chars(rest, base_dir, next_ident, False, [ch, ..rev_out])
        }
        False -> scan_toml_chars(rest, base_dir, "", False, [ch, ..rev_out])
      }
  }
}

fn is_toml_ident_char(ch: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
    ch,
  )
}

fn take_until_newline(
  chars: List(String),
  rev_acc: List(String),
) -> #(String, List(String)) {
  case chars {
    [] -> #(list.reverse(rev_acc) |> string.concat, [])
    ["\n", ..rest] -> #(list.reverse(["\n", ..rev_acc]) |> string.concat, rest)
    [ch, ..rest] -> take_until_newline(rest, [ch, ..rev_acc])
  }
}

fn take_single_quoted(
  chars: List(String),
  rev_acc: List(String),
) -> #(String, List(String)) {
  case chars {
    [] -> #(list.reverse(rev_acc) |> string.concat, [])
    ["'", ..rest] -> #(list.reverse(["'", ..rev_acc]) |> string.concat, rest)
    [ch, ..rest] -> take_single_quoted(rest, [ch, ..rev_acc])
  }
}

fn take_double_quoted(
  chars: List(String),
  rev_inner: List(String),
  rev_full: List(String),
) -> #(String, String, List(String)) {
  case chars {
    [] -> #(
      list.reverse(rev_inner) |> string.concat,
      list.reverse(rev_full) |> string.concat,
      [],
    )
    ["\\", esc, ..rest] -> {
      let decoded = case esc {
        "n" -> "\n"
        "t" -> "\t"
        "r" -> "\r"
        _ -> esc
      }
      take_double_quoted(rest, [decoded, ..rev_inner], [esc, "\\", ..rev_full])
    }
    ["\"", ..rest] -> #(
      list.reverse(rev_inner) |> string.concat,
      list.reverse(["\"", ..rev_full]) |> string.concat,
      rest,
    )
    [ch, ..rest] ->
      take_double_quoted(rest, [ch, ..rev_inner], [ch, ..rev_full])
  }
}

fn copy_packages_isolated(
  src_packages: String,
  dest_packages: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    simplifile.create_directory_all(dest_packages)
    |> result.map_error(fn(err) {
      "Failed to create staged packages dir: " <> simplifile.describe_error(err)
    }),
  )
  use entries <- result.try(
    simplifile.read_directory(at: src_packages)
    |> result.map_error(fn(err) {
      "Failed to read build/packages: " <> simplifile.describe_error(err)
    }),
  )
  list.try_each(entries, fn(entry) {
    let src_entry = filepath.join(src_packages, entry)
    let dest_entry = filepath.join(dest_packages, entry)
    let resolved = paths.absolute(src_entry)
    case simplifile.is_directory(resolved) {
      Ok(True) -> copy_package_dir_filtered(resolved, dest_entry)
      Ok(False) ->
        case simplifile.is_file(resolved) {
          Ok(True) ->
            simplifile.copy_file(at: resolved, to: dest_entry)
            |> result.map_error(fn(err) {
              "Failed to copy package file "
              <> entry
              <> ": "
              <> simplifile.describe_error(err)
            })
          _ -> Ok(Nil)
        }
      Error(err) ->
        Error(
          "Failed to stat package entry "
          <> entry
          <> ": "
          <> simplifile.describe_error(err),
        )
    }
  })
}

fn copy_package_dir_filtered(
  src_dir: String,
  dest_dir: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    simplifile.create_directory_all(dest_dir)
    |> result.map_error(fn(err) {
      "Failed to create staged package dir "
      <> dest_dir
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  use entries <- result.try(
    simplifile.read_directory(at: src_dir)
    |> result.map_error(fn(err) {
      "Failed to read package dir "
      <> src_dir
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  list.try_each(entries, fn(entry) {
    case entry {
      ".git" | "build" | "_build" | "target" -> Ok(Nil)
      _ -> {
        let src_path = filepath.join(src_dir, entry)
        let dest_path = filepath.join(dest_dir, entry)
        let resolved = paths.absolute(src_path)
        case simplifile.is_directory(resolved) {
          Ok(True) ->
            simplifile.copy_directory(at: resolved, to: dest_path)
            |> result.map_error(fn(err) {
              "Failed to copy package dir "
              <> entry
              <> ": "
              <> simplifile.describe_error(err)
            })
          Ok(False) ->
            case simplifile.is_file(resolved) {
              Ok(True) ->
                simplifile.copy_file(at: resolved, to: dest_path)
                |> result.map_error(fn(err) {
                  "Failed to copy package file "
                  <> entry
                  <> ": "
                  <> simplifile.describe_error(err)
                })
              _ -> Ok(Nil)
            }
          Error(err) ->
            Error(
              "Failed to stat package entry "
              <> entry
              <> ": "
              <> simplifile.describe_error(err),
            )
        }
      }
    }
  })
}

fn first_existing_path(
  primary_root: String,
  fallback_root: String,
  rel_path: String,
  check: fn(String) -> Result(Bool, simplifile.FileError),
) -> Option(String) {
  let primary = filepath.join(primary_root, rel_path)
  case check(primary) {
    Ok(True) -> Some(primary)
    _ -> {
      let fallback = filepath.join(fallback_root, rel_path)
      case fallback != primary, check(fallback) {
        True, Ok(True) -> Some(fallback)
        _, _ -> None
      }
    }
  }
}

fn stage_sources(
  project_root: String,
  staging_dir: String,
) -> Result(Nil, String) {
  let src_root = filepath.join(project_root, "src")
  let dest_root = filepath.join(staging_dir, "src")
  use rel_files <- result.try(walk_relative_files(src_root, ""))
  list.try_each(rel_files, fn(rel_path) {
    let src_path = filepath.join(src_root, rel_path)
    let dest_path = filepath.join(dest_root, rel_path)
    use _ <- result.try(
      simplifile.create_directory_all(filepath.directory_name(dest_path))
      |> result.map_error(fn(err) {
        "Failed to create dir for "
        <> dest_path
        <> ": "
        <> simplifile.describe_error(err)
      }),
    )
    case filepath.extension(rel_path) {
      Ok("gleam") -> {
        use content <- result.try(
          simplifile.read(src_path)
          |> result.map_error(fn(err) {
            "Failed to read "
            <> src_path
            <> ": "
            <> simplifile.describe_error(err)
          }),
        )
        let promoted = promote_private_to_pub(content)
        simplifile.write(to: dest_path, contents: promoted)
        |> result.map_error(fn(err) {
          "Failed to write "
          <> dest_path
          <> ": "
          <> simplifile.describe_error(err)
        })
      }
      _ ->
        simplifile.copy_file(at: src_path, to: dest_path)
        |> result.map_error(fn(err) {
          "Failed to copy "
          <> src_path
          <> ": "
          <> simplifile.describe_error(err)
        })
    }
  })
}

fn stage_test_sources(
  project_root: String,
  staging_dir: String,
) -> Result(List(String), String) {
  let test_root = filepath.join(project_root, "test")
  case simplifile.is_directory(test_root) {
    Ok(True) -> {
      let dest_root = filepath.join(staging_dir, "src")
      use rel_files <- result.try(walk_relative_files(test_root, ""))
      list.try_fold(rel_files, [], fn(mods_acc, rel_path) {
        let src_path = filepath.join(test_root, rel_path)
        let dest_path = filepath.join(dest_root, rel_path)
        case simplifile.is_file(dest_path) {
          Ok(True) ->
            case filepath.extension(rel_path) {
              Ok("gleam") ->
                Error(
                  "Duplicate module '"
                  <> filepath.strip_extension(rel_path)
                  <> "' found in both src/ and test/",
                )
              _ -> Ok(mods_acc)
            }
          _ -> {
            use _ <- result.try(
              simplifile.create_directory_all(filepath.directory_name(dest_path))
              |> result.map_error(fn(err) {
                "Failed to create dir for "
                <> dest_path
                <> ": "
                <> simplifile.describe_error(err)
              }),
            )
            case filepath.extension(rel_path) {
              Ok("gleam") -> {
                use content <- result.try(
                  simplifile.read(src_path)
                  |> result.map_error(fn(err) {
                    "Failed to read "
                    <> src_path
                    <> ": "
                    <> simplifile.describe_error(err)
                  }),
                )
                let promoted = promote_private_to_pub(content)
                use _ <- result.try(
                  simplifile.write(to: dest_path, contents: promoted)
                  |> result.map_error(fn(err) {
                    "Failed to write "
                    <> dest_path
                    <> ": "
                    <> simplifile.describe_error(err)
                  }),
                )
                let mod_name =
                  rel_path
                  |> string.replace("\\", "/")
                  |> filepath.strip_extension
                Ok([mod_name, ..mods_acc])
              }
              _ -> {
                use _ <- result.try(
                  simplifile.copy_file(at: src_path, to: dest_path)
                  |> result.map_error(fn(err) {
                    "Failed to copy "
                    <> src_path
                    <> ": "
                    <> simplifile.describe_error(err)
                  }),
                )
                Ok(mods_acc)
              }
            }
          }
        }
      })
    }
    _ -> Ok([])
  }
}

pub fn remap_staged_test_modules(
  iface: PackageInterface,
  test_mod_names: List(String),
) -> PackageInterface {
  case test_mod_names {
    [] -> iface
    _ -> {
      let test_set = set.from_list(test_mod_names)
      let remapped_modules =
        dict.fold(iface.modules, dict.new(), fn(acc, mod_name, mod_iface) {
          let rewritten_mod =
            rewrite_module_interface_types(mod_iface, test_set)
          let target_name = case set.contains(test_set, mod_name) {
            True -> "test/" <> mod_name
            False -> mod_name
          }
          dict.insert(acc, target_name, rewritten_mod)
        })
      PackageInterface(..iface, modules: remapped_modules)
    }
  }
}

fn rewrite_module_interface_types(
  mod_iface: ModuleInterface,
  test_set: Set(String),
) -> ModuleInterface {
  let type_aliases =
    dict.map_values(mod_iface.type_aliases, fn(_, ta) {
      ResolvedTypeAlias(..ta, alias: rewrite_resolved_type(ta.alias, test_set))
    })
  let types =
    dict.map_values(mod_iface.types, fn(_, td) {
      let constructors =
        list.map(td.constructors, fn(v) {
          let parameters =
            list.map(v.parameters, fn(p) {
              ResolvedVariantField(
                ..p,
                type_: rewrite_resolved_type(p.type_, test_set),
              )
            })
          ResolvedVariant(..v, parameters:)
        })
      ResolvedTypeDef(..td, constructors:)
    })
  let constants =
    dict.map_values(mod_iface.constants, fn(_, c) {
      ResolvedConstant(..c, type_: rewrite_resolved_type(c.type_, test_set))
    })
  let functions =
    dict.map_values(mod_iface.functions, fn(_, f) {
      let parameters =
        list.map(f.parameters, fn(p) {
          ResolvedParam(..p, type_: rewrite_resolved_type(p.type_, test_set))
        })
      let return = rewrite_resolved_type(f.return, test_set)
      ResolvedFunction(..f, parameters:, return:)
    })
  ModuleInterface(type_aliases:, types:, constants:, functions:)
}

fn rewrite_resolved_type(
  ty: ResolvedType,
  test_set: Set(String),
) -> ResolvedType {
  case ty {
    NamedType(name:, package:, module:, parameters:) -> {
      let new_module = case set.contains(test_set, module) {
        True -> "test/" <> module
        False -> module
      }
      NamedType(
        name:,
        package:,
        module: new_module,
        parameters: list.map(parameters, rewrite_resolved_type(_, test_set)),
      )
    }
    TupleType(elements:) ->
      TupleType(
        elements: list.map(elements, rewrite_resolved_type(_, test_set)),
      )
    FnType(parameters:, return:) ->
      FnType(
        parameters: list.map(parameters, rewrite_resolved_type(_, test_set)),
        return: rewrite_resolved_type(return, test_set),
      )
    VariableType(_) -> ty
  }
}

fn walk_relative_files(
  base_dir: String,
  rel_prefix: String,
) -> Result(List(String), String) {
  let current_dir = case rel_prefix {
    "" -> base_dir
    _ -> filepath.join(base_dir, rel_prefix)
  }
  use entries <- result.try(
    simplifile.read_directory(at: current_dir)
    |> result.map_error(fn(err) {
      "Failed to read directory "
      <> current_dir
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  list.try_fold(entries, [], fn(acc, entry) {
    let rel_path = case rel_prefix {
      "" -> entry
      _ -> filepath.join(rel_prefix, entry)
    }
    let full_path = filepath.join(base_dir, rel_path)
    case simplifile.is_directory(full_path) {
      Ok(True) -> {
        use nested <- result.try(walk_relative_files(base_dir, rel_path))
        Ok(list.append(acc, nested))
      }
      Ok(False) -> Ok([rel_path, ..acc])
      Error(err) ->
        Error(
          "Failed to stat "
          <> full_path
          <> ": "
          <> simplifile.describe_error(err),
        )
    }
  })
}

fn collect_pub_edits(
  tokens: List(#(Token, glexer.Position)),
  brace_depth: Int,
  seen_pub: Bool,
  has_js_external: Bool,
  has_erl_external: Bool,
  edits: List(TextEdit),
) -> List(TextEdit) {
  case tokens {
    [] -> edits

    [#(token.LeftBrace, _), ..rest] ->
      collect_pub_edits(rest, brace_depth + 1, False, False, False, edits)

    [#(token.RightBrace, _), ..rest] ->
      collect_pub_edits(
        rest,
        int.max(0, brace_depth - 1),
        False,
        False,
        False,
        edits,
      )

    [#(token.Space(_), _), ..rest]
    | [#(token.CommentNormal(_), _), ..rest]
    | [#(token.CommentDoc(_), _), ..rest]
    | [#(token.CommentModule(_), _), ..rest] ->
      collect_pub_edits(
        rest,
        brace_depth,
        seen_pub,
        has_js_external,
        has_erl_external,
        edits,
      )

    [#(token.At, pos), ..after_at] if brace_depth == 0 ->
      case skip_trivia(after_at) {
        [#(token.Name("internal") as tok, name_pos), ..rest] -> {
          let edit =
            TextEdit(
              start: pos.byte_offset,
              end: token_end(tok, name_pos),
              replacement: "",
            )
          collect_pub_edits(
            rest,
            brace_depth,
            False,
            has_js_external,
            has_erl_external,
            [edit, ..edits],
          )
        }
        [#(token.Name("external"), _), ..after_ext] ->
          case skip_trivia(after_ext) {
            [#(token.LeftParen, _), ..after_lp] ->
              case skip_trivia(after_lp) {
                [#(token.Name("javascript"), _), ..] ->
                  collect_pub_edits(
                    after_at,
                    brace_depth,
                    False,
                    True,
                    has_erl_external,
                    edits,
                  )
                [#(token.Name("erlang"), _), ..] ->
                  collect_pub_edits(
                    after_at,
                    brace_depth,
                    False,
                    has_js_external,
                    True,
                    edits,
                  )
                _ ->
                  collect_pub_edits(
                    after_at,
                    brace_depth,
                    False,
                    has_js_external,
                    has_erl_external,
                    edits,
                  )
              }
            _ ->
              collect_pub_edits(
                after_at,
                brace_depth,
                False,
                has_js_external,
                has_erl_external,
                edits,
              )
          }
        _ ->
          collect_pub_edits(
            after_at,
            brace_depth,
            False,
            has_js_external,
            has_erl_external,
            edits,
          )
      }

    [#(token.Pub, _), ..rest] if brace_depth == 0 ->
      collect_pub_edits(
        rest,
        brace_depth,
        True,
        has_js_external,
        has_erl_external,
        edits,
      )

    [#(token.Fn, pos), ..rest] if brace_depth == 0 -> {
      let edits = case seen_pub, skip_trivia(rest) {
        False, [#(token.Name(_), _), ..after_name] -> {
          let skip_promote = case has_js_external && !has_erl_external {
            False -> False
            True ->
              case skip_trivia(after_name) {
                [#(token.LeftParen, _), ..] as params_tokens ->
                  case prepass.find_fn_signature_end(params_tokens) {
                    Some(#(_, False, _)) -> True
                    _ -> False
                  }
                _ -> False
              }
          }
          case skip_promote {
            True -> edits
            False -> [
              TextEdit(
                start: pos.byte_offset,
                end: pos.byte_offset,
                replacement: "pub ",
              ),
              ..edits
            ]
          }
        }
        _, _ -> edits
      }
      collect_pub_edits(rest, brace_depth, False, False, False, edits)
    }

    [#(token.Type, pos), ..rest] if brace_depth == 0 -> {
      let edits = case seen_pub, skip_trivia(rest) {
        False, [#(token.UpperName(_), _), ..] -> [
          TextEdit(
            start: pos.byte_offset,
            end: pos.byte_offset,
            replacement: "pub ",
          ),
          ..edits
        ]
        _, _ -> edits
      }
      collect_pub_edits(rest, brace_depth, False, False, False, edits)
    }

    [#(token.Opaque, pos), ..rest] if brace_depth == 0 ->
      case skip_trivia(rest) {
        [#(token.Type, type_pos), ..after_type] ->
          case skip_trivia(after_type) {
            [#(token.UpperName(_), _), ..] -> {
              let edit = case seen_pub {
                True ->
                  TextEdit(
                    start: pos.byte_offset,
                    end: type_pos.byte_offset,
                    replacement: "",
                  )
                False ->
                  TextEdit(
                    start: pos.byte_offset,
                    end: type_pos.byte_offset + 4,
                    replacement: "pub type",
                  )
              }
              collect_pub_edits(after_type, brace_depth, False, False, False, [
                edit,
                ..edits
              ])
            }
            _ ->
              collect_pub_edits(
                after_type,
                brace_depth,
                False,
                False,
                False,
                edits,
              )
          }
        other ->
          collect_pub_edits(other, brace_depth, False, False, False, edits)
      }

    [#(token.Const, pos), ..rest] if brace_depth == 0 -> {
      let edits = case seen_pub, skip_trivia(rest) {
        False, [#(token.Name(_), _), ..] -> [
          TextEdit(
            start: pos.byte_offset,
            end: pos.byte_offset,
            replacement: "pub ",
          ),
          ..edits
        ]
        _, _ -> edits
      }
      collect_pub_edits(rest, brace_depth, False, False, False, edits)
    }

    [#(token.Import, _), ..rest] if brace_depth == 0 ->
      collect_pub_edits(rest, brace_depth, False, False, False, edits)

    [_, ..rest] ->
      collect_pub_edits(
        rest,
        brace_depth,
        False,
        has_js_external,
        has_erl_external,
        edits,
      )
  }
}

fn filter_root_internal_modules(
  lines: List(String),
  in_root: Bool,
  skipping_array: Bool,
  bracket_balance: Int,
  acc: List(String),
) -> List(String) {
  case lines {
    [] -> list.reverse(acc)
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case skipping_array {
        True -> {
          let next_balance = bracket_balance + count_brackets(line)
          case next_balance <= 0 {
            True -> filter_root_internal_modules(rest, in_root, False, 0, acc)
            False ->
              filter_root_internal_modules(
                rest,
                in_root,
                True,
                next_balance,
                acc,
              )
          }
        }
        False ->
          case in_root {
            False ->
              filter_root_internal_modules(rest, False, False, 0, [line, ..acc])
            True ->
              case string.starts_with(trimmed, "[") {
                True ->
                  filter_root_internal_modules(rest, False, False, 0, [
                    line,
                    ..acc
                  ])
                False ->
                  case is_internal_modules_assignment(trimmed) {
                    True -> {
                      let balance = count_brackets(line)
                      case balance > 0 {
                        True ->
                          filter_root_internal_modules(
                            rest,
                            True,
                            True,
                            balance,
                            acc,
                          )
                        False ->
                          filter_root_internal_modules(
                            rest,
                            True,
                            False,
                            0,
                            acc,
                          )
                      }
                    }
                    False ->
                      filter_root_internal_modules(rest, True, False, 0, [
                        line,
                        ..acc
                      ])
                  }
              }
          }
      }
    }
  }
}

fn is_internal_modules_assignment(trimmed: String) -> Bool {
  case string.split_once(trimmed, "=") {
    Ok(#(lhs, _)) -> string.trim(lhs) == "internal_modules"
    Error(_) -> False
  }
}

fn count_brackets(line: String) -> Int {
  count_brackets_loop(string.to_graphemes(line), False, False, 0)
}

fn count_brackets_loop(
  chars: List(String),
  in_double: Bool,
  in_single: Bool,
  acc: Int,
) -> Int {
  case chars, in_double, in_single {
    [], _, _ -> acc
    ["\\", _, ..rest], True, False ->
      count_brackets_loop(rest, True, False, acc)
    ["\"", ..rest], True, False -> count_brackets_loop(rest, False, False, acc)
    [_, ..rest], True, False -> count_brackets_loop(rest, True, False, acc)
    ["'", ..rest], False, True -> count_brackets_loop(rest, False, False, acc)
    [_, ..rest], False, True -> count_brackets_loop(rest, False, True, acc)
    ["#", ..], False, False -> acc
    ["\"", ..rest], False, False -> count_brackets_loop(rest, True, False, acc)
    ["'", ..rest], False, False -> count_brackets_loop(rest, False, True, acc)
    ["[", ..rest], False, False ->
      count_brackets_loop(rest, False, False, acc + 1)
    ["]", ..rest], False, False ->
      count_brackets_loop(rest, False, False, acc - 1)
    [_, ..rest], False, False -> count_brackets_loop(rest, False, False, acc)
    _, _, _ -> acc
  }
}

fn strip_toml_line_comment(line: String) -> String {
  strip_toml_comment_loop(string.to_graphemes(line), False, False, [])
  |> string.trim
}

fn strip_toml_comment_loop(
  chars: List(String),
  in_double: Bool,
  in_single: Bool,
  rev_acc: List(String),
) -> String {
  case chars, in_double, in_single {
    [], _, _ -> list.reverse(rev_acc) |> string.concat
    ["\\", esc, ..rest], True, False ->
      strip_toml_comment_loop(rest, True, False, [esc, "\\", ..rev_acc])
    ["\"", ..rest], True, False ->
      strip_toml_comment_loop(rest, False, False, ["\"", ..rev_acc])
    [ch, ..rest], True, False ->
      strip_toml_comment_loop(rest, True, False, [ch, ..rev_acc])
    ["'", ..rest], False, True ->
      strip_toml_comment_loop(rest, False, False, ["'", ..rev_acc])
    [ch, ..rest], False, True ->
      strip_toml_comment_loop(rest, False, True, [ch, ..rev_acc])
    ["#", ..], False, False -> list.reverse(rev_acc) |> string.concat
    ["\"", ..rest], False, False ->
      strip_toml_comment_loop(rest, True, False, ["\"", ..rev_acc])
    ["'", ..rest], False, False ->
      strip_toml_comment_loop(rest, False, True, ["'", ..rev_acc])
    [ch, ..rest], False, False ->
      strip_toml_comment_loop(rest, False, False, [ch, ..rev_acc])
    _, _, _ -> list.reverse(rev_acc) |> string.concat
  }
}
