import filepath
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile

/// Kind of MoonBit declaration annotated with `#gekko.patch`.
pub type PatchDeclKind {
  PatchFn
  PatchType
}

/// A single `#gekko.patch` attribute and its attached MoonBit declaration.
pub type DiscoveredPatchAttr {
  DiscoveredPatchAttr(
    kind: PatchDeclKind,
    mbt_name: String,
    target_override: Option(String),
    line: Int,
  )
}

/// A package import parsed from a `moon.pkg` `import { ... }` block.
pub type DiscoveredImport {
  DiscoveredImport(package: String, alias: Option(String))
}

/// A `.mbt` file discovered under `<pkg_root>/patches/`.
pub type DiscoveredPatchFile {
  DiscoveredPatchFile(
    source_path: String,
    dest_filename: String,
    source_pkg: String,
  )
}

/// Co-located patch bundle discovered from `<pkg_root>/patches/`.
pub type DiscoveredModulePatch {
  DiscoveredModulePatch(
    files: List(DiscoveredPatchFile),
    imports: List(DiscoveredImport),
    types: List(String),
    functions: List(String),
  )
}

type PendingAttr {
  PendingAttr(target_override: Option(String), line: Int)
}

/// Parse `import { ... }` entries from a MoonBit `moon.pkg` manifest.
pub fn parse_moon_pkg_imports(
  content: String,
  source_pkg: String,
) -> Result(List(DiscoveredImport), String) {
  let stripped = strip_line_comments(content)
  use blocks <- result.try(
    extract_import_blocks(
      string.to_graphemes(stripped),
      0,
      False,
      False,
      "",
      "",
      False,
      [],
      [],
    ),
  )
  use raw_imports <- result.try(
    list.try_fold(blocks, [], fn(acc, body) {
      let items =
        body
        |> string.replace("\n", ",")
        |> string.split(",")
      list.try_fold(items, acc, fn(inner_acc, raw_item) {
        let item = string.trim(raw_item)
        case item {
          "" -> Ok(inner_acc)
          _ -> {
            use parsed <- result.try(parse_moon_pkg_import_item(
              item,
              source_pkg,
            ))
            case parsed {
              Some(imp) -> Ok([imp, ..inner_acc])
              None -> Ok(inner_acc)
            }
          }
        }
      })
    }),
  )
  Ok(list.reverse(raw_imports))
}

fn parse_moon_pkg_import_item(
  item: String,
  source_pkg: String,
) -> Result(Option(DiscoveredImport), String) {
  case string.starts_with(item, "\"") {
    False -> Error("Invalid import entry in moon.pkg: " <> item)
    True -> {
      let after_open = string.drop_start(item, 1)
      case string.split_once(after_open, "\"") {
        Error(_) -> Error("Invalid import entry in moon.pkg: " <> item)
        Ok(#("", _)) -> Error("Invalid import entry in moon.pkg: " <> item)
        Ok(#(raw_pkg, after_close)) -> {
          let rest = string.trim(after_close)
          use alias <- result.try(parse_moon_pkg_alias(rest, item))
          let pkg = normalize_moon_pkg_name(raw_pkg, source_pkg)
          case pkg, alias {
            "gprelude", None | "gprelude", Some("gprelude") -> Ok(None)
            _, _ -> Ok(Some(DiscoveredImport(package: pkg, alias:)))
          }
        }
      }
    }
  }
}

fn parse_moon_pkg_alias(
  rest: String,
  full_item: String,
) -> Result(Option(String), String) {
  case rest {
    "" -> Ok(None)
    _ -> {
      let raw_alias = case
        string.starts_with(rest, "@"),
        string.starts_with(rest, "as "),
        string.starts_with(rest, "as\t")
      {
        True, _, _ -> Ok(string.drop_start(rest, 1))
        _, True, _ -> Ok(string.trim(string.drop_start(rest, 3)))
        _, _, True -> Ok(string.trim(string.drop_start(rest, 3)))
        _, _, _ -> Error("Invalid import alias in moon.pkg: " <> full_item)
      }
      use candidate <- result.try(raw_alias)
      let stripped = case string.starts_with(candidate, "@") {
        True -> string.drop_start(candidate, 1)
        False -> candidate
      }
      let trimmed = string.trim(stripped)
      case trimmed != "" && is_valid_ident(trimmed) {
        True -> Ok(Some(trimmed))
        False -> Error("Invalid import alias in moon.pkg: " <> full_item)
      }
    }
  }
}

fn normalize_moon_pkg_name(raw_pkg: String, source_pkg: String) -> String {
  case raw_pkg == "gprelude" || string.ends_with(raw_pkg, "/gprelude") {
    True -> "gprelude"
    False ->
      case source_pkg != "" && string.starts_with(raw_pkg, source_pkg <> "/") {
        True -> string.drop_start(raw_pkg, string.length(source_pkg) + 1)
        False -> raw_pkg
      }
  }
}

/// Parse top-level `#gekko.patch` custom attributes from a MoonBit source file.
pub fn parse_mbt_patch_attributes(
  content: String,
  file_path: String,
) -> Result(List(DiscoveredPatchAttr), String) {
  let lines = string.split(content, "\n")
  scan_mbt_lines(lines, 1, 0, False, None, [], file_path)
}

fn scan_mbt_lines(
  lines: List(String),
  line_num: Int,
  brace_depth: Int,
  in_string: Bool,
  pending: Option(PendingAttr),
  rev_acc: List(DiscoveredPatchAttr),
  file_path: String,
) -> Result(List(DiscoveredPatchAttr), String) {
  case lines {
    [] ->
      case pending {
        Some(p) ->
          Error(
            "#gekko.patch at "
            <> file_path
            <> ":"
            <> int.to_string(p.line)
            <> " must precede a fn, struct, enum, or type declaration",
          )
        None -> Ok(list.reverse(rev_acc))
      }
    [raw_line, ..rest] -> {
      let trimmed = string.trim(raw_line)
      case in_string {
        True -> {
          let #(next_depth, next_str) =
            step_code_state(raw_line, brace_depth, True)
          scan_mbt_lines(
            rest,
            line_num + 1,
            next_depth,
            next_str,
            pending,
            rev_acc,
            file_path,
          )
        }
        False ->
          case brace_depth == 0 {
            False -> {
              let #(next_depth, next_str) =
                step_code_state(raw_line, brace_depth, False)
              scan_mbt_lines(
                rest,
                line_num + 1,
                next_depth,
                next_str,
                pending,
                rev_acc,
                file_path,
              )
            }
            True ->
              case is_skippable_top_line(trimmed) {
                True ->
                  scan_mbt_lines(
                    rest,
                    line_num + 1,
                    0,
                    False,
                    pending,
                    rev_acc,
                    file_path,
                  )
                False ->
                  case string.starts_with(trimmed, "#gekko.") {
                    True ->
                      case pending {
                        Some(p) ->
                          Error(
                            "#gekko.patch at "
                            <> file_path
                            <> ":"
                            <> int.to_string(p.line)
                            <> " must precede a fn, struct, enum, or type declaration",
                          )
                        None -> {
                          use next_pending <- result.try(parse_gekko_attr_line(
                            trimmed,
                            file_path,
                            line_num,
                          ))
                          scan_mbt_lines(
                            rest,
                            line_num + 1,
                            0,
                            False,
                            Some(next_pending),
                            rev_acc,
                            file_path,
                          )
                        }
                      }
                    False ->
                      case string.starts_with(trimmed, "#") {
                        True ->
                          scan_mbt_lines(
                            rest,
                            line_num + 1,
                            0,
                            False,
                            pending,
                            rev_acc,
                            file_path,
                          )
                        False ->
                          case pending {
                            None -> {
                              let #(next_depth, next_str) =
                                step_code_state(raw_line, 0, False)
                              scan_mbt_lines(
                                rest,
                                line_num + 1,
                                next_depth,
                                next_str,
                                None,
                                rev_acc,
                                file_path,
                              )
                            }
                            Some(p) -> {
                              use #(kind, mbt_name) <- result.try(
                                parse_decl_header(
                                  [raw_line, ..rest],
                                  file_path,
                                  p.line,
                                ),
                              )
                              let attr =
                                DiscoveredPatchAttr(
                                  kind:,
                                  mbt_name:,
                                  target_override: p.target_override,
                                  line: p.line,
                                )
                              let #(next_depth, next_str) =
                                step_code_state(raw_line, 0, False)
                              scan_mbt_lines(
                                rest,
                                line_num + 1,
                                next_depth,
                                next_str,
                                None,
                                [attr, ..rev_acc],
                                file_path,
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
}

fn is_skippable_top_line(trimmed: String) -> Bool {
  trimmed == ""
  || string.starts_with(trimmed, "//")
  || string.starts_with(trimmed, "#|")
}

fn parse_gekko_attr_line(
  trimmed: String,
  file_path: String,
  line_num: Int,
) -> Result(PendingAttr, String) {
  let loc = file_path <> ":" <> int.to_string(line_num)
  let after_prefix = string.drop_start(trimmed, string.length("#gekko."))
  let #(attr_name, rest) = read_ident(after_prefix)
  case attr_name {
    "patch" -> {
      let rest_trimmed = strip_trailing_line_comment(string.trim(rest))
      case rest_trimmed {
        "" -> Ok(PendingAttr(target_override: None, line: line_num))
        _ ->
          case
            string.starts_with(rest_trimmed, "(")
            && string.ends_with(rest_trimmed, ")")
          {
            False ->
              Error(
                "Invalid #gekko.patch attribute syntax at "
                <> loc
                <> " (expected #gekko.patch or #gekko.patch(\"name\"))",
              )
            True -> {
              let inner =
                rest_trimmed
                |> string.drop_start(1)
                |> string.drop_end(1)
                |> string.trim
              case parse_quoted_string(inner) {
                Ok(arg) if arg != "" ->
                  Ok(PendingAttr(target_override: Some(arg), line: line_num))
                _ ->
                  Error(
                    "Invalid #gekko.patch argument at "
                    <> loc
                    <> " (expected a single non-empty string literal)",
                  )
              }
            }
          }
      }
    }
    _ ->
      Error(
        "Unknown attribute '#gekko."
        <> attr_name
        <> "' in "
        <> loc
        <> " (supported: #gekko.patch)",
      )
  }
}

fn parse_quoted_string(s: String) -> Result(String, Nil) {
  case string.starts_with(s, "\"") && string.ends_with(s, "\"") {
    False -> Error(Nil)
    True -> {
      let inner = s |> string.drop_start(1) |> string.drop_end(1)
      case string.contains(inner, "\"") {
        True -> Error(Nil)
        False -> Ok(inner)
      }
    }
  }
}

fn strip_trailing_line_comment(s: String) -> String {
  strip_comment_in_line(string.to_graphemes(s), False, False, [])
  |> string.trim
}

fn parse_decl_header(
  remaining_lines: List(String),
  file_path: String,
  attr_line: Int,
) -> Result(#(PatchDeclKind, String), String) {
  let loc = file_path <> ":" <> int.to_string(attr_line)
  let joined =
    remaining_lines
    |> list.take(8)
    |> string.join(" ")
    |> string.trim
  let after_vis = strip_visibility_prefix(joined)
  case
    string.starts_with(after_vis, "fn["),
    string.starts_with(after_vis, "fn "),
    string.starts_with(after_vis, "fn\t"),
    read_keyword_decl(after_vis)
  {
    True, _, _, _ -> {
      let after_fn = string.trim(string.drop_start(after_vis, 2))
      use after_generics <- result.try(
        skip_balanced_brackets(after_fn)
        |> result.map_error(fn(_) {
          "#gekko.patch at "
          <> loc
          <> " has malformed generic parameter list on fn declaration"
        }),
      )
      let #(name, _) = read_ident(string.trim(after_generics))
      case name {
        "" ->
          Error(
            "#gekko.patch at "
            <> loc
            <> " must precede a named fn, struct, enum, or type declaration",
          )
        _ -> Ok(#(PatchFn, name))
      }
    }
    _, True, _, _ | _, _, True, _ -> {
      let after_fn = string.trim(string.drop_start(after_vis, 2))
      let #(name, _) = read_ident(after_fn)
      case name {
        "" ->
          Error(
            "#gekko.patch at "
            <> loc
            <> " must precede a named fn, struct, enum, or type declaration",
          )
        _ -> Ok(#(PatchFn, name))
      }
    }
    _, _, _, Some(#(kind, rest)) -> {
      let #(name, _) = read_ident(string.trim(rest))
      case name {
        "" ->
          Error(
            "#gekko.patch at "
            <> loc
            <> " must precede a named fn, struct, enum, or type declaration",
          )
        _ -> Ok(#(kind, name))
      }
    }
    _, _, _, None ->
      Error(
        "#gekko.patch at "
        <> loc
        <> " must precede a fn, struct, enum, or type declaration",
      )
  }
}

fn read_keyword_decl(s: String) -> Option(#(PatchDeclKind, String)) {
  let keywords = [
    #("struct", PatchType),
    #("enum", PatchType),
    #("type", PatchType),
    #("suberror", PatchType),
  ]
  list.find_map(keywords, fn(entry) {
    let #(kw, kind) = entry
    let len = string.length(kw)
    case
      string.starts_with(s, kw <> " ")
      || string.starts_with(s, kw <> "\t")
      || string.starts_with(s, kw <> "[")
    {
      True -> Ok(#(kind, string.drop_start(s, len)))
      False -> Error(Nil)
    }
  })
  |> option.from_result
}

fn strip_visibility_prefix(s: String) -> String {
  let trimmed = string.trim(s)
  let prefixes = ["pub(all)", "pub(open)", "pub(readonly)", "pub", "priv"]
  let stripped =
    list.find_map(prefixes, fn(pfx) {
      case string.starts_with(trimmed, pfx) {
        True -> {
          let rest = string.drop_start(trimmed, string.length(pfx))
          case
            rest == ""
            || string.starts_with(rest, " ")
            || string.starts_with(rest, "\t")
          {
            True -> Ok(string.trim(rest))
            False -> Error(Nil)
          }
        }
        False -> Error(Nil)
      }
    })
  case stripped {
    Ok(rest) -> rest
    Error(_) -> trimmed
  }
}

fn skip_balanced_brackets(s: String) -> Result(String, Nil) {
  case string.starts_with(s, "[") {
    False -> Ok(s)
    True -> skip_brackets_loop(string.to_graphemes(string.drop_start(s, 1)), 1)
  }
}

fn skip_brackets_loop(chars: List(String), depth: Int) -> Result(String, Nil) {
  case chars {
    [] -> Error(Nil)
    ["[", ..rest] -> skip_brackets_loop(rest, depth + 1)
    ["]", ..rest] ->
      case depth == 1 {
        True -> Ok(string.concat(rest))
        False -> skip_brackets_loop(rest, depth - 1)
      }
    [_, ..rest] -> skip_brackets_loop(rest, depth)
  }
}

/// Auto-discover patch modules under `<pkg_root>/patches/`.
pub fn discover_directory_patches(
  pkg_root: String,
  pkg_name: String,
  target_pkg: Option(String),
  toml_patched_paths: Set(String),
) -> Result(Dict(String, DiscoveredModulePatch), String) {
  let patches_root = filepath.join(pkg_root, "patches")
  case simplifile.is_directory(patches_root) {
    Ok(True) ->
      walk_patches_dir(
        patches_root,
        "",
        pkg_name,
        target_pkg,
        toml_patched_paths,
        dict.new(),
      )
    _ -> Ok(dict.new())
  }
}

fn walk_patches_dir(
  dir: String,
  rel_dir: String,
  pkg_name: String,
  target_pkg: Option(String),
  toml_patched_paths: Set(String),
  acc: Dict(String, DiscoveredModulePatch),
) -> Result(Dict(String, DiscoveredModulePatch), String) {
  use entries <- result.try(
    simplifile.read_directory(at: dir)
    |> result.map(fn(es) { list.sort(es, string.compare) })
    |> result.map_error(fn(err) {
      "Failed to read patches directory "
      <> dir
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  let visible = list.filter(entries, fn(e) { !is_ignored_entry(e) })
  let has_moon_pkg = list.contains(visible, "moon.pkg")

  let #(mbt_files, subdirs) =
    list.fold(visible, #([], []), fn(parts, entry) {
      let #(m_acc, d_acc) = parts
      let full = filepath.join(dir, entry)
      case simplifile.is_directory(full) {
        Ok(True) -> #(m_acc, [entry, ..d_acc])
        _ ->
          case string.ends_with(entry, ".mbt") {
            True -> #([entry, ..m_acc], d_acc)
            False -> parts
          }
      }
    })
  let mbt_files = list.reverse(mbt_files)
  let subdirs = list.reverse(subdirs)

  use acc_after_files <- result.try(case has_moon_pkg {
    True ->
      case mbt_files, rel_dir {
        [], _ -> Ok(acc)
        _, "" ->
          Error(
            "Found moon.pkg directly in patches/; place package-directory patches in patches/<module>/moon.pkg",
          )
        _, _ ->
          discover_pkg_dir_patch(
            dir,
            rel_dir,
            mbt_files,
            pkg_name,
            target_pkg,
            toml_patched_paths,
            acc,
          )
      }
    False ->
      list.try_fold(mbt_files, acc, fn(cur_acc, file) {
        let stem = string.drop_end(file, 4)
        let default_mod = case rel_dir {
          "" -> stem
          _ -> rel_dir <> "/" <> stem
        }
        discover_single_file_patch(
          filepath.join(dir, file),
          file,
          default_mod,
          pkg_name,
          target_pkg,
          toml_patched_paths,
          cur_acc,
        )
      })
  })

  list.try_fold(subdirs, acc_after_files, fn(cur_acc, sub) {
    let next_rel = case rel_dir {
      "" -> sub
      _ -> rel_dir <> "/" <> sub
    }
    walk_patches_dir(
      filepath.join(dir, sub),
      next_rel,
      pkg_name,
      target_pkg,
      toml_patched_paths,
      cur_acc,
    )
  })
}

fn discover_pkg_dir_patch(
  dir: String,
  default_mod: String,
  mbt_files: List(String),
  pkg_name: String,
  target_pkg: Option(String),
  toml_patched_paths: Set(String),
  acc: Dict(String, DiscoveredModulePatch),
) -> Result(Dict(String, DiscoveredModulePatch), String) {
  let moon_pkg_path = filepath.join(dir, "moon.pkg")
  use pkg_src <- result.try(
    simplifile.read(moon_pkg_path)
    |> result.map_error(fn(err) {
      "Failed to read "
      <> moon_pkg_path
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  use imports <- result.try(parse_moon_pkg_imports(pkg_src, pkg_name))

  use #(patch_files, attrs, all_in_toml) <- result.try(
    list.try_fold(mbt_files, #([], [], True), fn(state, file) {
      let #(f_acc, a_acc, toml_ok) = state
      let full = filepath.join(dir, file)
      let canon = canonical_path(full)
      use src <- result.try(
        simplifile.read(canon)
        |> result.map_error(fn(err) {
          "Failed to read patch file "
          <> canon
          <> ": "
          <> simplifile.describe_error(err)
        }),
      )
      use file_attrs <- result.try(parse_mbt_patch_attributes(src, canon))
      let pfile =
        DiscoveredPatchFile(
          source_path: canon,
          dest_filename: file,
          source_pkg: pkg_name,
        )
      Ok(#(
        [pfile, ..f_acc],
        list.append(a_acc, file_attrs),
        toml_ok && set.contains(toml_patched_paths, canon),
      ))
    }),
  )
  let patch_files = list.reverse(patch_files)

  case attrs, all_in_toml {
    [], False ->
      Error(
        "Patch directory '"
        <> dir
        <> "' has no #gekko.patch attributes; annotate patched declarations with #gekko.patch",
      )
    [], True ->
      // Legacy TOML [patch] owns these files; attach moon.pkg imports if any.
      case imports {
        [] -> Ok(acc)
        _ -> {
          let default_key = qualify_mod_key(target_pkg, default_mod)
          Ok(merge_discovered_patch(
            acc,
            default_key,
            DiscoveredModulePatch(
              files: patch_files,
              imports:,
              types: [],
              functions: [],
            ),
          ))
        }
      }
    _, _ -> {
      use by_mod <- result.try(group_attrs_by_module(
        attrs,
        default_mod,
        target_pkg,
      ))
      Ok(
        dict.fold(by_mod, acc, fn(m, mod_key, pair) {
          let #(types, functions) = pair
          merge_discovered_patch(
            m,
            mod_key,
            DiscoveredModulePatch(
              files: patch_files,
              imports:,
              types:,
              functions:,
            ),
          )
        }),
      )
    }
  }
}

fn discover_single_file_patch(
  file_path: String,
  filename: String,
  default_mod: String,
  pkg_name: String,
  target_pkg: Option(String),
  toml_patched_paths: Set(String),
  acc: Dict(String, DiscoveredModulePatch),
) -> Result(Dict(String, DiscoveredModulePatch), String) {
  let canon = canonical_path(file_path)
  use src <- result.try(
    simplifile.read(canon)
    |> result.map_error(fn(err) {
      "Failed to read patch file "
      <> canon
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  use attrs <- result.try(parse_mbt_patch_attributes(src, canon))
  case attrs, set.contains(toml_patched_paths, canon) {
    [], False ->
      Error(
        "Patch file '"
        <> canon
        <> "' has no #gekko.patch attributes; annotate patched declarations with #gekko.patch",
      )
    [], True -> Ok(acc)
    _, _ -> {
      let pfile =
        DiscoveredPatchFile(
          source_path: canon,
          dest_filename: filename,
          source_pkg: pkg_name,
        )
      use by_mod <- result.try(group_attrs_by_module(
        attrs,
        default_mod,
        target_pkg,
      ))
      Ok(
        dict.fold(by_mod, acc, fn(m, mod_key, pair) {
          let #(types, functions) = pair
          merge_discovered_patch(
            m,
            mod_key,
            DiscoveredModulePatch(
              files: [pfile],
              imports: [],
              types:,
              functions:,
            ),
          )
        }),
      )
    }
  }
}

fn group_attrs_by_module(
  attrs: List(DiscoveredPatchAttr),
  default_mod: String,
  target_pkg: Option(String),
) -> Result(Dict(String, #(List(String), List(String))), String) {
  list.try_fold(attrs, dict.new(), fn(acc, attr) {
    use #(mod_key, sym_name) <- result.try(resolve_attr_target(
      attr,
      default_mod,
      target_pkg,
    ))
    let #(tys, fns) = case dict.get(acc, mod_key) {
      Ok(existing) -> existing
      Error(_) -> #([], [])
    }
    let next_pair = case attr.kind {
      PatchType -> #(list.append(tys, [sym_name]), fns)
      PatchFn -> #(tys, list.append(fns, [sym_name]))
    }
    Ok(dict.insert(acc, mod_key, next_pair))
  })
}

fn resolve_attr_target(
  attr: DiscoveredPatchAttr,
  default_mod: String,
  target_pkg: Option(String),
) -> Result(#(String, String), String) {
  case attr.target_override {
    None -> Ok(#(qualify_mod_key(target_pkg, default_mod), attr.mbt_name))
    Some(raw) ->
      case string.contains(raw, ":") {
        True ->
          case split_last_dot(raw) {
            Ok(#(mod_key, sym)) if mod_key != "" && sym != "" ->
              Ok(#(mod_key, sym))
            _ ->
              Error(
                "Invalid #gekko.patch target '"
                <> raw
                <> "' at line "
                <> int.to_string(attr.line)
                <> " (expected \"pkg:mod.symbol\")",
              )
          }
        False ->
          case string.contains(raw, ".") {
            True ->
              case split_last_dot(raw) {
                Ok(#(mod_part, sym)) if mod_part != "" && sym != "" ->
                  Ok(#(qualify_mod_key(target_pkg, mod_part), sym))
                _ ->
                  Error(
                    "Invalid #gekko.patch target '"
                    <> raw
                    <> "' at line "
                    <> int.to_string(attr.line)
                    <> " (expected \"mod.symbol\")",
                  )
              }
            False -> Ok(#(qualify_mod_key(target_pkg, default_mod), raw))
          }
      }
  }
}

fn split_last_dot(s: String) -> Result(#(String, String), Nil) {
  case string.split(s, ".") |> list.reverse {
    [last, ..rev_rest] if rev_rest != [] ->
      Ok(#(rev_rest |> list.reverse |> string.join("."), last))
    _ -> Error(Nil)
  }
}

fn qualify_mod_key(target_pkg: Option(String), mod_name: String) -> String {
  case target_pkg {
    Some(pkg) -> pkg <> ":" <> mod_name
    None -> mod_name
  }
}

fn merge_discovered_patch(
  acc: Dict(String, DiscoveredModulePatch),
  key: String,
  patch: DiscoveredModulePatch,
) -> Dict(String, DiscoveredModulePatch) {
  case dict.get(acc, key) {
    Error(_) -> dict.insert(acc, key, patch)
    Ok(existing) ->
      dict.insert(
        acc,
        key,
        DiscoveredModulePatch(
          files: dedup(list.append(existing.files, patch.files)),
          imports: dedup(list.append(existing.imports, patch.imports)),
          types: dedup(list.append(existing.types, patch.types)),
          functions: dedup(list.append(existing.functions, patch.functions)),
        ),
      )
  }
}

fn dedup(items: List(a)) -> List(a) {
  let #(_, rev) =
    list.fold(items, #(set.new(), []), fn(acc, item) {
      let #(seen, out) = acc
      case set.contains(seen, item) {
        True -> acc
        False -> #(set.insert(seen, item), [item, ..out])
      }
    })
  list.reverse(rev)
}

fn canonical_path(path: String) -> String {
  simplifile.resolve(path)
  |> result.unwrap(filepath.expand(path) |> result.unwrap(path))
}

fn is_ignored_entry(name: String) -> Bool {
  string.starts_with(name, ".") || name == "_build" || name == "target"
}

// -----------------------------------------------------------------------------
// Low-level MoonBit lexical helpers
// -----------------------------------------------------------------------------

fn step_code_state(
  line: String,
  brace_depth: Int,
  in_string: Bool,
) -> #(Int, Bool) {
  step_code_chars(string.to_graphemes(line), brace_depth, in_string, False)
}

fn step_code_chars(
  chars: List(String),
  depth: Int,
  in_string: Bool,
  escaped: Bool,
) -> #(Int, Bool) {
  case chars {
    [] -> #(depth, in_string)
    [ch, ..rest] ->
      case in_string {
        True ->
          case escaped {
            True -> step_code_chars(rest, depth, True, False)
            False ->
              case ch {
                "\\" -> step_code_chars(rest, depth, True, True)
                "\"" -> step_code_chars(rest, depth, False, False)
                _ -> step_code_chars(rest, depth, True, False)
              }
          }
        False ->
          case ch, rest {
            "/", ["/", ..] -> #(depth, False)
            "\"", _ -> step_code_chars(rest, depth, True, False)
            "{", _ -> step_code_chars(rest, depth + 1, False, False)
            "}", _ -> step_code_chars(rest, int.max(0, depth - 1), False, False)
            _, _ -> step_code_chars(rest, depth, False, False)
          }
      }
  }
}

fn strip_line_comments(content: String) -> String {
  content
  |> string.split("\n")
  |> list.map(fn(line) {
    strip_comment_in_line(string.to_graphemes(line), False, False, [])
  })
  |> string.join("\n")
}

fn strip_comment_in_line(
  chars: List(String),
  in_string: Bool,
  escaped: Bool,
  acc: List(String),
) -> String {
  case chars {
    [] -> acc |> list.reverse |> string.concat
    [ch, ..rest] ->
      case in_string {
        True ->
          case escaped {
            True -> strip_comment_in_line(rest, True, False, [ch, ..acc])
            False ->
              case ch {
                "\\" -> strip_comment_in_line(rest, True, True, [ch, ..acc])
                "\"" -> strip_comment_in_line(rest, False, False, [ch, ..acc])
                _ -> strip_comment_in_line(rest, True, False, [ch, ..acc])
              }
          }
        False ->
          case ch, rest {
            "\"", _ -> strip_comment_in_line(rest, True, False, [ch, ..acc])
            "/", ["/", ..] -> acc |> list.reverse |> string.concat
            _, _ -> strip_comment_in_line(rest, False, False, [ch, ..acc])
          }
      }
  }
}

fn extract_import_blocks(
  chars: List(String),
  depth: Int,
  in_string: Bool,
  escaped: Bool,
  current_ident: String,
  prev_ident: String,
  capturing: Bool,
  captured_rev: List(String),
  blocks_rev: List(String),
) -> Result(List(String), String) {
  case chars {
    [] ->
      case capturing {
        True -> Error("Unclosed import block in moon.pkg")
        False -> Ok(list.reverse(blocks_rev))
      }
    [ch, ..rest] ->
      case in_string {
        True -> {
          let next_captured = case capturing {
            True -> [ch, ..captured_rev]
            False -> captured_rev
          }
          let #(next_in_str, next_esc) = case escaped {
            True -> #(True, False)
            False ->
              case ch {
                "\\" -> #(True, True)
                "\"" -> #(False, False)
                _ -> #(True, False)
              }
          }
          extract_import_blocks(
            rest,
            depth,
            next_in_str,
            next_esc,
            "",
            "",
            capturing,
            next_captured,
            blocks_rev,
          )
        }
        False ->
          case depth {
            0 ->
              case ch {
                "\"" ->
                  extract_import_blocks(
                    rest,
                    0,
                    True,
                    False,
                    "",
                    "",
                    False,
                    [],
                    blocks_rev,
                  )
                "{" -> {
                  let keyword = case current_ident {
                    "" -> prev_ident
                    _ -> current_ident
                  }
                  let start_capture = keyword == "import"
                  extract_import_blocks(
                    rest,
                    1,
                    False,
                    False,
                    "",
                    "",
                    start_capture,
                    [],
                    blocks_rev,
                  )
                }
                _ ->
                  case is_ident_char(ch), is_whitespace_char(ch) {
                    True, _ ->
                      extract_import_blocks(
                        rest,
                        0,
                        False,
                        False,
                        current_ident <> ch,
                        prev_ident,
                        False,
                        [],
                        blocks_rev,
                      )
                    False, True -> {
                      let next_prev = case current_ident {
                        "" -> prev_ident
                        _ -> current_ident
                      }
                      extract_import_blocks(
                        rest,
                        0,
                        False,
                        False,
                        "",
                        next_prev,
                        False,
                        [],
                        blocks_rev,
                      )
                    }
                    False, False ->
                      extract_import_blocks(
                        rest,
                        0,
                        False,
                        False,
                        "",
                        "",
                        False,
                        [],
                        blocks_rev,
                      )
                  }
              }
            _ ->
              case ch {
                "\"" -> {
                  let next_captured = case capturing {
                    True -> [ch, ..captured_rev]
                    False -> captured_rev
                  }
                  extract_import_blocks(
                    rest,
                    depth,
                    True,
                    False,
                    "",
                    "",
                    capturing,
                    next_captured,
                    blocks_rev,
                  )
                }
                "{" -> {
                  let next_captured = case capturing {
                    True -> [ch, ..captured_rev]
                    False -> captured_rev
                  }
                  extract_import_blocks(
                    rest,
                    depth + 1,
                    False,
                    False,
                    "",
                    "",
                    capturing,
                    next_captured,
                    blocks_rev,
                  )
                }
                "}" -> {
                  let next_depth = depth - 1
                  case next_depth == 0 && capturing {
                    True -> {
                      let body = captured_rev |> list.reverse |> string.concat
                      extract_import_blocks(
                        rest,
                        0,
                        False,
                        False,
                        "",
                        "",
                        False,
                        [],
                        [body, ..blocks_rev],
                      )
                    }
                    False -> {
                      let next_captured = case capturing {
                        True -> [ch, ..captured_rev]
                        False -> captured_rev
                      }
                      extract_import_blocks(
                        rest,
                        next_depth,
                        False,
                        False,
                        "",
                        "",
                        capturing,
                        next_captured,
                        blocks_rev,
                      )
                    }
                  }
                }
                _ -> {
                  let next_captured = case capturing {
                    True -> [ch, ..captured_rev]
                    False -> captured_rev
                  }
                  extract_import_blocks(
                    rest,
                    depth,
                    False,
                    False,
                    "",
                    "",
                    capturing,
                    next_captured,
                    blocks_rev,
                  )
                }
              }
          }
      }
  }
}

fn read_ident(s: String) -> #(String, String) {
  read_ident_loop(string.to_graphemes(s), [])
}

fn read_ident_loop(
  chars: List(String),
  rev_acc: List(String),
) -> #(String, String) {
  case chars {
    [ch, ..rest] ->
      case is_ident_char(ch) {
        True -> read_ident_loop(rest, [ch, ..rev_acc])
        False -> #(
          rev_acc |> list.reverse |> string.concat,
          string.concat(chars),
        )
      }
    [] -> #(rev_acc |> list.reverse |> string.concat, "")
  }
}

fn is_valid_ident(s: String) -> Bool {
  s != "" && list.all(string.to_graphemes(s), is_ident_char)
}

fn is_ident_char(ch: String) -> Bool {
  case ch {
    "_" -> True
    _ -> {
      let lower = string.lowercase(ch)
      let upper = string.uppercase(ch)
      lower != upper
      || ch == "0"
      || ch == "1"
      || ch == "2"
      || ch == "3"
      || ch == "4"
      || ch == "5"
      || ch == "6"
      || ch == "7"
      || ch == "8"
      || ch == "9"
    }
  }
}

fn is_whitespace_char(ch: String) -> Bool {
  case ch {
    " " | "\t" | "\n" | "\r" -> True
    _ -> False
  }
}
