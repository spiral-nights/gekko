import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Extract a balanced delimiter-enclosed block starting at the beginning of `src`
/// (e.g. `(...)` or `[...]`), returning `#(inner_content, remaining_suffix)`.
fn take_balanced(
  src: String,
  open: String,
  close: String,
) -> Result(#(String, String), String) {
  case string.pop_grapheme(src) {
    Ok(#(first, rest)) if first == open ->
      take_balanced_loop(rest, open, close, 1, "")
    _ -> Error("Expected '" <> open <> "' in .mbti at: " <> src)
  }
}

fn take_balanced_loop(
  src: String,
  open: String,
  close: String,
  depth: Int,
  acc: String,
) -> Result(#(String, String), String) {
  case string.pop_grapheme(src) {
    Error(_) -> Error("Unclosed '" <> open <> "' in .mbti")
    Ok(#(g, rest)) ->
      case g == open, g == close {
        True, _ -> take_balanced_loop(rest, open, close, depth + 1, acc <> g)
        False, True ->
          case depth == 1 {
            True -> Ok(#(acc, rest))
            False -> take_balanced_loop(rest, open, close, depth - 1, acc <> g)
          }
        False, False -> take_balanced_loop(rest, open, close, depth, acc <> g)
      }
  }
}

/// Extract a balanced `(...)` block at the start of `src`.
pub fn take_balanced_parens(src: String) -> Result(#(String, String), String) {
  take_balanced(src, "(", ")")
}

/// Extract a balanced `[...]` block at the start of `src`.
pub fn take_balanced_brackets(
  src: String,
) -> Result(#(String, String), String) {
  take_balanced(src, "[", "]")
}

/// Option-returning variant of `take_balanced_parens`.
pub fn split_paren_block(s: String) -> Option(#(String, String)) {
  option.from_result(take_balanced(s, "(", ")"))
}

/// Option-returning variant of `take_balanced_brackets`.
pub fn split_bracket_block(s: String) -> Option(#(String, String)) {
  option.from_result(take_balanced(s, "[", "]"))
}

/// Return True when `s` is a single balanced `(...)` group covering the whole string.
pub fn is_outer_paren_wrapped(s: String) -> Bool {
  let trimmed = string.trim(s)
  case string.starts_with(trimmed, "(") && string.ends_with(trimmed, ")") {
    False -> False
    True ->
      case split_paren_block(trimmed) {
        Some(#(_, "")) -> True
        _ -> False
      }
  }
}

/// Split `s` on commas at parenthesis/bracket depth 0, trimming items and
/// dropping empty entries.
pub fn split_top_level_commas(s: String) -> List(String) {
  let chars = string.to_graphemes(s)
  split_commas_loop(chars, 0, 0, [], [])
  |> list.map(string.trim)
  |> list.filter(fn(item) { item != "" })
}

fn split_commas_loop(
  chars: List(String),
  parens: Int,
  brackets: Int,
  rev_cur: List(String),
  rev_items: List(String),
) -> List(String) {
  case chars {
    [] -> list.reverse([rev_str(rev_cur), ..rev_items])
    [c, ..rest] ->
      case c {
        "(" ->
          split_commas_loop(
            rest,
            parens + 1,
            brackets,
            [c, ..rev_cur],
            rev_items,
          )
        ")" ->
          split_commas_loop(
            rest,
            int.max(0, parens - 1),
            brackets,
            [c, ..rev_cur],
            rev_items,
          )
        "[" ->
          split_commas_loop(
            rest,
            parens,
            brackets + 1,
            [c, ..rev_cur],
            rev_items,
          )
        "]" ->
          split_commas_loop(
            rest,
            parens,
            int.max(0, brackets - 1),
            [c, ..rev_cur],
            rev_items,
          )
        "," if parens == 0 && brackets == 0 ->
          split_commas_loop(rest, 0, 0, [], [rev_str(rev_cur), ..rev_items])
        _ ->
          split_commas_loop(rest, parens, brackets, [c, ..rev_cur], rev_items)
      }
  }
}

/// Split `s` at the first occurrence of `sep` at parenthesis/bracket depth 0.
pub fn split_top_level_once(
  s: String,
  sep: String,
) -> Result(#(String, String), Nil) {
  let sep_chars = string.to_graphemes(sep)
  split_top_once_loop(string.to_graphemes(s), sep_chars, 0, 0, [])
}

fn split_top_once_loop(
  chars: List(String),
  sep_chars: List(String),
  parens: Int,
  brackets: Int,
  rev_left: List(String),
) -> Result(#(String, String), Nil) {
  case chars {
    [] -> Error(Nil)
    [c, ..rest] ->
      case parens == 0 && brackets == 0 {
        True ->
          case strip_prefix_list(chars, sep_chars) {
            Some(after_sep) ->
              Ok(#(rev_str(rev_left), string.concat(after_sep)))
            None -> {
              let #(np, nb) = step_depth(c, parens, brackets)
              split_top_once_loop(rest, sep_chars, np, nb, [c, ..rev_left])
            }
          }
        False -> {
          let #(np, nb) = step_depth(c, parens, brackets)
          split_top_once_loop(rest, sep_chars, np, nb, [c, ..rev_left])
        }
      }
  }
}

/// Split `src` at the first single `:` at depth 0 (skipping `::` method paths).
pub fn split_top_level_colon(src: String) -> Option(#(String, String)) {
  split_colon_loop(src, 0, "")
}

fn split_colon_loop(
  src: String,
  depth: Int,
  left: String,
) -> Option(#(String, String)) {
  case string.pop_grapheme(src) {
    Error(_) -> None
    Ok(#(g, rest)) ->
      case g {
        "(" | "[" | "{" -> split_colon_loop(rest, depth + 1, left <> g)
        ")" | "]" | "}" ->
          split_colon_loop(
            rest,
            case depth > 0 {
              True -> depth - 1
              False -> 0
            },
            left <> g,
          )
        ":" if depth == 0 ->
          case string.starts_with(rest, ":") {
            True ->
              split_colon_loop(string.drop_start(rest, 1), depth, left <> "::")
            False -> Some(#(left, rest))
          }
        _ -> split_colon_loop(rest, depth, left <> g)
      }
  }
}

/// Read an identifier prefix (letters, digits, `_`) from `src`, returning `#(ident, rest)`.
pub fn read_ident(src: String) -> #(String, String) {
  read_ident_loop(src, "")
}

fn read_ident_loop(src: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(src) {
    Error(_) -> #(acc, "")
    Ok(#(g, rest)) ->
      case is_ident_char(g) {
        True -> read_ident_loop(rest, acc <> g)
        False -> #(acc, src)
      }
  }
}

fn is_ident_char(g: String) -> Bool {
  case g {
    "_" -> True
    _ -> {
      let lower = string.lowercase(g)
      let upper = string.uppercase(g)
      lower != upper
      || g == "0"
      || g == "1"
      || g == "2"
      || g == "3"
      || g == "4"
      || g == "5"
      || g == "6"
      || g == "7"
      || g == "8"
      || g == "9"
    }
  }
}

/// Strip a `@pkg.` or `pkg.` qualifier from a MoonBit type or trait name.
pub fn strip_pkg_qualifier(name: String) -> String {
  let trimmed = string.trim(name)
  case string.split_once(trimmed, ".") {
    Ok(#(_, right)) -> string.trim(right)
    Error(_) -> trimmed
  }
}

fn strip_prefix_list(items: List(a), pfx: List(a)) -> Option(List(a)) {
  case pfx, items {
    [], _ -> Some(items)
    [ph, ..pt], [ih, ..it] if ph == ih -> strip_prefix_list(it, pt)
    _, _ -> None
  }
}

fn step_depth(c: String, parens: Int, brackets: Int) -> #(Int, Int) {
  case c {
    "(" -> #(parens + 1, brackets)
    ")" -> #(int.max(0, parens - 1), brackets)
    "[" -> #(parens, brackets + 1)
    "]" -> #(parens, int.max(0, brackets - 1))
    _ -> #(parens, brackets)
  }
}

pub fn rev_str(rev_buf: List(String)) -> String {
  rev_buf
  |> list.reverse
  |> string.concat
}
