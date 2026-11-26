import filepath
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import project/text_edit
import simplifile

pub const sourcemap_filename = ".gekko_sourcemap"

/// Maps a MoonBit declaration's line range in a generated `.mbt` file back to
/// its originating Gleam source file and line.
pub type DeclOrigin {
  DeclOrigin(
    mbt_file: String,
    start_line: Int,
    end_line: Int,
    gleam_file: String,
    gleam_line: Int,
    symbol: String,
  )
}

/// Build `DeclOrigin` entries for one transpiled Gleam module.
pub fn collect_module_origins(
  root_pkg_name: String,
  pkg_name: String,
  mod_name: String,
  ast_mod: glance.Module,
  gleam_source: String,
  mbt_rel_path: String,
  mbt_source: String,
) -> List(DeclOrigin) {
  let gleam_rel = format_gleam_rel_path(root_pkg_name, pkg_name, mod_name)
  let symbol_lines = collect_gleam_symbol_lines(ast_mod, gleam_source)
  let blocks = split_mbt_blocks(mbt_source)
  list.filter_map(blocks, fn(blk) {
    let #(start_line, end_line, sym_opt) = blk
    case sym_opt {
      None -> Error(Nil)
      Some(sym) ->
        case lookup_gleam_line(sym, symbol_lines) {
          Some(#(matched_sym, gleam_line)) ->
            Ok(DeclOrigin(
              mbt_file: mbt_rel_path,
              start_line:,
              end_line:,
              gleam_file: gleam_rel,
              gleam_line:,
              symbol: matched_sym,
            ))
          None -> Error(Nil)
        }
    }
  })
}

/// Build `DeclOrigin` entries mapping `__gekko_sigcheck_<fn>` stubs in a
/// generated `.mbt` file back to the originating `#gekko.patch` line.
pub fn collect_patch_sigcheck_origins(
  mbt_rel_path: String,
  mbt_source: String,
  patch_fn_locs: Dict(String, #(String, Int)),
) -> List(DeclOrigin) {
  case dict.is_empty(patch_fn_locs) {
    True -> []
    False ->
      split_mbt_blocks(mbt_source)
      |> list.filter_map(fn(blk) {
        let #(start_line, end_line, sym_opt) = blk
        case sym_opt {
          Some("__gekko_sigcheck_" <> fn_name) ->
            case dict.get(patch_fn_locs, fn_name) {
              Ok(#(patch_file, patch_line)) ->
                Ok(DeclOrigin(
                  mbt_file: mbt_rel_path,
                  start_line:,
                  end_line:,
                  gleam_file: patch_file,
                  gleam_line: patch_line,
                  symbol: fn_name,
                ))
              Error(_) -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
  }
}

fn format_gleam_rel_path(
  root_pkg_name: String,
  pkg_name: String,
  mod_name: String,
) -> String {
  let base = case string.starts_with(mod_name, "test/") {
    True -> mod_name <> ".gleam"
    False -> "src/" <> mod_name <> ".gleam"
  }
  case pkg_name == root_pkg_name || pkg_name == "" {
    True -> base
    False -> pkg_name <> ":" <> base
  }
}

fn collect_gleam_symbol_lines(
  ast_mod: glance.Module,
  source: String,
) -> Dict(String, Int) {
  let definitions =
    list.map(ast_mod.custom_types, fn(def) {
      #(def.definition.name, def.definition.location.start)
    })
    |> list.append(
      list.map(ast_mod.type_aliases, fn(def) {
        #(def.definition.name, def.definition.location.start)
      }),
    )
    |> list.append(
      list.map(ast_mod.constants, fn(def) {
        #(def.definition.name, def.definition.location.start)
      }),
    )
    |> list.append(
      list.map(ast_mod.functions, fn(def) {
        #(def.definition.name, def.definition.location.start)
      }),
    )
  list.fold(definitions, dict.new(), fn(acc, definition) {
    let #(name, offset) = definition
    dict.insert(acc, name, text_edit.byte_offset_to_line(source, offset))
  })
}

fn lookup_gleam_line(
  mbt_sym: String,
  symbol_lines: Dict(String, Int),
) -> Option(#(String, Int)) {
  let candidates = case string.split_once(mbt_sym, "::") {
    Ok(#(type_part, _)) -> [mbt_sym, type_part, trim_mangled_suffix(type_part)]
    Error(_) -> [mbt_sym, trim_mangled_suffix(mbt_sym)]
  }
  list.find_map(candidates, fn(cand) {
    case dict.get(symbol_lines, cand) {
      Ok(line) -> Ok(#(cand, line))
      Error(_) -> Error(Nil)
    }
  })
  |> option.from_result
}

fn trim_mangled_suffix(name: String) -> String {
  case string.ends_with(name, "_") {
    True -> string.drop_end(name, 1)
    False -> name
  }
}

fn split_mbt_blocks(mbt_source: String) -> List(#(Int, Int, Option(String))) {
  let lines = string.split(mbt_source, "\n")
  let #(cur_start, cur_sym, rev_blocks) =
    list.index_fold(lines, #(1, None, []), fn(acc, line, idx) {
      let line_no = idx + 1
      let #(start, sym_opt, blocks_acc) = acc
      let trimmed = string.trim(line)
      case trimmed == "///|" {
        True -> {
          let next_acc = case line_no > start {
            True -> [#(start, line_no - 1, sym_opt), ..blocks_acc]
            False -> blocks_acc
          }
          #(line_no, None, next_acc)
        }
        False -> {
          let next_sym = case sym_opt {
            Some(_) -> sym_opt
            None -> extract_decl_symbol(trimmed)
          }
          #(start, next_sym, blocks_acc)
        }
      }
    })
  let total_lines = list.length(lines)
  let all = case total_lines >= cur_start {
    True -> [#(cur_start, total_lines, cur_sym), ..rev_blocks]
    False -> rev_blocks
  }
  list.reverse(all)
}

fn extract_decl_symbol(trimmed: String) -> Option(String) {
  case
    trimmed == ""
    || string.starts_with(trimmed, "#")
    || string.starts_with(trimmed, "//")
  {
    True -> None
    False -> {
      let after_vis = text_edit.strip_visibility_prefix(trimmed)
      case after_vis {
        "enum " <> rest -> take_ident_before_delim(rest)
        "type " <> rest -> take_ident_before_delim(rest)
        "let " <> rest -> take_ident_before_delim(rest)
        "fn[" <> rest ->
          case string.split_once(rest, "]") {
            Ok(#(_, after_gen)) ->
              take_ident_before_delim(string.trim_start(after_gen))
            Error(_) -> None
          }
        "fn " <> rest -> take_ident_before_delim(rest)
        _ -> None
      }
    }
  }
}

fn take_ident_before_delim(s: String) -> Option(String) {
  let chars = string.to_graphemes(string.trim_start(s))
  let ident =
    take_while_ident(chars, [])
    |> list.reverse
    |> string.concat
  case ident {
    "" -> None
    _ -> Some(ident)
  }
}

fn take_while_ident(
  chars: List(String),
  rev_acc: List(String),
) -> List(String) {
  case chars {
    [] -> rev_acc
    [ch, ..rest] ->
      case ch {
        " " | "\t" | "(" | "[" | ":" if rest != [] ->
          case ch, rest {
            ":", [":", ..more] -> take_while_ident(more, ["::", ..rev_acc])
            _, _ -> rev_acc
          }
        " " | "\t" | "(" | "[" | ":" | "{" | "=" -> rev_acc
        _ -> take_while_ident(rest, [ch, ..rev_acc])
      }
  }
}

/// Serialize `DeclOrigin` entries into the `.gekko_sourcemap` format.
pub fn format_sourcemap(origins: List(DeclOrigin)) -> String {
  case origins {
    [] -> ""
    _ ->
      origins
      |> list.map(fn(o) {
        string.join(
          [
            o.mbt_file,
            int.to_string(o.start_line),
            int.to_string(o.end_line),
            o.gleam_file,
            int.to_string(o.gleam_line),
            o.symbol,
          ],
          "\t",
        )
      })
      |> string.join("\n")
      <> "\n"
  }
}

/// Parse a `.gekko_sourcemap` file back into `DeclOrigin` entries.
pub fn parse_sourcemap(content: String) -> List(DeclOrigin) {
  content
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    let trimmed = string.trim(line)
    case string.split(trimmed, "\t") {
      [mbt_file, s_str, e_str, gleam_file, g_str, symbol] ->
        case int.parse(s_str), int.parse(e_str), int.parse(g_str) {
          Ok(start_line), Ok(end_line), Ok(gleam_line) ->
            Ok(DeclOrigin(
              mbt_file:,
              start_line:,
              end_line:,
              gleam_file:,
              gleam_line:,
              symbol:,
            ))
          _, _, _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

/// Annotate `moon` compiler output with originating `.gleam` file/line hints
/// using `<out_dir>/.gekko_sourcemap`.
pub fn annotate_moon_output(out_dir: String, moon_output: String) -> String {
  let map_path = filepath.join(out_dir, sourcemap_filename)
  case simplifile.read(from: map_path) {
    Error(_) -> moon_output
    Ok(content) -> {
      let origins = parse_sourcemap(content)
      annotate_with_origins(origins, moon_output)
    }
  }
}

/// Pure helper that annotates `moon_output` using in-memory `origins`.
pub fn annotate_with_origins(
  origins: List(DeclOrigin),
  moon_output: String,
) -> String {
  case origins {
    [] -> moon_output
    _ -> {
      let lines = string.split(moon_output, "\n")
      let annotated =
        list.flat_map(lines, fn(line) {
          case find_mbt_location_in_line(line) {
            Some(#(mbt_path, line_no)) ->
              case lookup_origin(origins, mbt_path, line_no) {
                Some(origin) -> [
                  line,
                  "  ↳ "
                    <> case string.ends_with(origin.gleam_file, ".mbt") {
                    True -> "Patch source: "
                    False -> "Gleam source: "
                  }
                    <> origin.gleam_file
                    <> ":"
                    <> int.to_string(origin.gleam_line)
                    <> " ("
                    <> origin.symbol
                    <> ")",
                ]
                None -> [line]
              }
            None -> [line]
          }
        })
      string.join(annotated, "\n")
    }
  }
}

fn find_mbt_location_in_line(line: String) -> Option(#(String, Int)) {
  case string.split_once(line, ".mbt:") {
    Error(_) -> None
    Ok(#(before_ext, after_ext)) -> {
      let path_prefix = extract_path_token(before_ext)
      let line_digits =
        after_ext
        |> string.to_graphemes
        |> take_digits([])
        |> list.reverse
        |> string.concat
      case path_prefix != "", int.parse(line_digits) {
        True, Ok(line_no) -> Some(#(path_prefix <> ".mbt", line_no))
        _, _ -> None
      }
    }
  }
}

fn extract_path_token(before_ext: String) -> String {
  let rev_chars =
    before_ext
    |> string.to_graphemes
    |> list.reverse
  take_until_path_sep(rev_chars, [])
  |> string.concat
}

fn take_until_path_sep(
  rev_chars: List(String),
  acc: List(String),
) -> List(String) {
  case rev_chars {
    [] -> acc
    [ch, ..rest] ->
      case ch {
        " " | "\t" | "[" | "(" | "\"" | "'" | "`" -> acc
        _ -> take_until_path_sep(rest, [ch, ..acc])
      }
  }
}

fn take_digits(chars: List(String), rev_acc: List(String)) -> List(String) {
  case chars {
    [] -> rev_acc
    [ch, ..rest] ->
      case ch {
        "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ->
          take_digits(rest, [ch, ..rev_acc])
        _ -> rev_acc
      }
  }
}

fn lookup_origin(
  origins: List(DeclOrigin),
  mbt_path: String,
  line_no: Int,
) -> Option(DeclOrigin) {
  let norm_path = string.replace(mbt_path, "\\", "/")
  let matching_file =
    list.filter(origins, fn(o) {
      norm_path == o.mbt_file || string.ends_with(norm_path, "/" <> o.mbt_file)
    })
  let exact =
    list.find(matching_file, fn(o) {
      line_no >= o.start_line && line_no <= o.end_line
    })
  case exact {
    Ok(o) -> Some(o)
    Error(_) ->
      matching_file
      |> list.filter(fn(o) { o.start_line <= line_no })
      |> list.last
      |> option.from_result
  }
}
