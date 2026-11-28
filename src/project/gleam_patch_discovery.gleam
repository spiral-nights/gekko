import filepath
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/fs
import project/prepass.{
  type FfiKind, type GleamTypePatch, GleamPatch, GleamTypePatch,
}
import simplifile

/// Discover `/// @patch("mod.fn")` / `/// @gekko.patch("mod.fn")` annotations
/// across Gleam modules under `<pkg_root>/src/`.
pub fn discover_gleam_patches(
  pkg_root: String,
  target_pkg: Option(String),
) -> Result(Dict(String, FfiKind), String) {
  use #(fn_patches, _, _) <- result.try(discover_gleam_patch_bundle(
    pkg_root,
    target_pkg,
  ))
  Ok(fn_patches)
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
  let src_dir = filepath.join(pkg_root, "src")
  case simplifile.is_directory(src_dir) {
    Ok(True) -> {
      use rel_paths <- result.try(collect_gleam_src_files(src_dir, ""))
      list.sort(rel_paths, string.compare)
      |> list.try_fold(#(dict.new(), dict.new(), dict.new()), fn(acc, rel) {
        let #(fn_acc, ty_acc, mirror_acc) = acc
        let mod_name = filepath.strip_extension(rel)
        let full_path = filepath.join(src_dir, rel)
        use src <- result.try(fs.read_text(full_path))
        case
          string.contains(src, "@patch") || string.contains(src, "@gekko.patch")
        {
          False -> Ok(acc)
          True -> {
            let res = prepass.preprocess_module(mod_name, src)
            use next_fn <- result.try(
              list.try_fold(res.gleam_patches, fn_acc, fn(inner_acc, entry) {
                use key <- result.try(qualify_gleam_patch_target(
                  entry.target,
                  target_pkg,
                  full_path,
                  entry.line,
                ))
                case dict.has_key(inner_acc, key) {
                  True ->
                    Error(
                      "Duplicate @patch target '"
                      <> key
                      <> "' at "
                      <> full_path
                      <> ":"
                      <> int.to_string(entry.line),
                    )
                  False ->
                    Ok(dict.insert(
                      inner_acc,
                      key,
                      GleamPatch(
                        source_module: entry.source_module,
                        source_function: entry.source_function,
                      ),
                    ))
                }
              }),
            )
            use next_ty <- result.try(
              list.try_fold(
                res.gleam_type_patches,
                ty_acc,
                fn(inner_acc, entry) {
                  use key <- result.try(qualify_gleam_patch_target(
                    entry.target,
                    target_pkg,
                    full_path,
                    entry.line,
                  ))
                  case dict.has_key(inner_acc, key) {
                    True ->
                      Error(
                        "Duplicate @patch_type target '"
                        <> key
                        <> "' at "
                        <> full_path
                        <> ":"
                        <> int.to_string(entry.line),
                      )
                    False ->
                      Ok(dict.insert(
                        inner_acc,
                        key,
                        GleamTypePatch(
                          source_module: entry.source_module,
                          source_type: entry.source_type,
                        ),
                      ))
                  }
                },
              ),
            )
            use next_mirror <- result.try(case res.patch_mirror {
              None -> Ok(mirror_acc)
              Some(info) -> {
                use qualified_mod <- result.try(qualify_mirror_target(
                  info.target,
                  target_pkg,
                  full_path,
                  info.line,
                ))
                Ok(dict.insert(mirror_acc, info.mirror_module, qualified_mod))
              }
            })
            Ok(#(next_fn, next_ty, next_mirror))
          }
        }
      })
    }
    _ -> Ok(#(dict.new(), dict.new(), dict.new()))
  }
}

fn qualify_mirror_target(
  target: String,
  target_pkg: Option(String),
  file_path: String,
  line: Int,
) -> Result(String, String) {
  let loc = file_path <> ":" <> int.to_string(line)
  let invalid = fn() {
    Error(
      "Invalid @patch_mirror target '"
      <> target
      <> "' at "
      <> loc
      <> " (expected \"module\" or \"pkg:module\")",
    )
  }
  case string.split_once(target, ":") {
    Ok(#(pkg, mod_part)) ->
      case pkg != "" && mod_part != "" && !string.contains(mod_part, ".") {
        True -> Ok(target)
        False -> invalid()
      }
    Error(_) ->
      case target != "" && !string.contains(target, ".") {
        True ->
          case target_pkg {
            Some(tp) -> Ok(tp <> ":" <> target)
            None -> Ok(target)
          }
        False -> invalid()
      }
  }
}

fn collect_gleam_src_files(
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
            use nested <- result.try(collect_gleam_src_files(base_dir, rel))
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

fn qualify_gleam_patch_target(
  target: String,
  target_pkg: Option(String),
  file_path: String,
  line: Int,
) -> Result(String, String) {
  let loc = file_path <> ":" <> int.to_string(line)
  let invalid = fn() {
    Error(
      "Invalid @patch target '"
      <> target
      <> "' at "
      <> loc
      <> " (expected \"module.fn\" or \"pkg:module.fn\")",
    )
  }
  let valid_mod_fn = fn(s: String) -> Bool {
    case string.split(s, ".") |> list.reverse {
      [fn_part, ..rev_rest] if rev_rest != [] && fn_part != "" -> {
        let mod_part = rev_rest |> list.reverse |> string.join(".")
        mod_part != ""
      }
      _ -> False
    }
  }
  case string.split_once(target, ":") {
    Ok(#(pkg, rest)) ->
      case pkg != "" && valid_mod_fn(rest) {
        True -> Ok(target)
        False -> invalid()
      }
    Error(_) ->
      case valid_mod_fn(target) {
        True ->
          case target_pkg {
            Some(tp) -> Ok(tp <> ":" <> target)
            None -> Ok(target)
          }
        False -> invalid()
      }
  }
}
