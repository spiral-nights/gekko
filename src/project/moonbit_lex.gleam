import gleam/list
import gleam/string

/// Remove `//` comments from each line while preserving string literals.
pub fn strip_line_comments(content: String) -> String {
  content
  |> string.split("\n")
  |> list.map(fn(line) {
    strip_comment_in_line(string.to_graphemes(line), False, False, [])
  })
  |> string.join("\n")
}

/// Remove a trailing `//` comment from a single line of source.
pub fn strip_line_comment(text: String) -> String {
  strip_comment_in_line(string.to_graphemes(text), False, False, [])
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

/// Extract the bodies of `import { ... }` blocks from source text. `label`
/// names the file kind in the unclosed-block error message.
pub fn extract_import_blocks(
  content: String,
  label: String,
) -> Result(List(String), String) {
  extract_import_blocks_loop(
    string.to_graphemes(strip_line_comments(content)),
    0,
    False,
    False,
    "",
    "",
    False,
    [],
    [],
    label,
  )
}

fn extract_import_blocks_loop(
  chars: List(String),
  depth: Int,
  in_string: Bool,
  escaped: Bool,
  current_ident: String,
  prev_ident: String,
  capturing: Bool,
  captured_rev: List(String),
  blocks_rev: List(String),
  label: String,
) -> Result(List(String), String) {
  case chars {
    [] ->
      case capturing {
        True -> Error("Unclosed import block in " <> label)
        False -> Ok(list.reverse(blocks_rev))
      }
    [ch, ..rest] ->
      case in_string {
        True -> {
          let #(next_in_str, next_esc) = case escaped {
            True -> #(True, False)
            False ->
              case ch {
                "\\" -> #(True, True)
                "\"" -> #(False, False)
                _ -> #(True, False)
              }
          }
          extract_import_blocks_loop(
            rest,
            depth,
            next_in_str,
            next_esc,
            "",
            "",
            capturing,
            capture(capturing, captured_rev, ch),
            blocks_rev,
            label,
          )
        }
        False ->
          case depth {
            0 ->
              case ch {
                "\"" ->
                  extract_import_blocks_loop(
                    rest,
                    0,
                    True,
                    False,
                    "",
                    "",
                    False,
                    [],
                    blocks_rev,
                    label,
                  )
                "{" -> {
                  let keyword = case current_ident {
                    "" -> prev_ident
                    _ -> current_ident
                  }
                  extract_import_blocks_loop(
                    rest,
                    1,
                    False,
                    False,
                    "",
                    "",
                    keyword == "import",
                    [],
                    blocks_rev,
                    label,
                  )
                }
                _ ->
                  case is_ident_char(ch), is_whitespace_char(ch) {
                    True, _ ->
                      extract_import_blocks_loop(
                        rest,
                        0,
                        False,
                        False,
                        current_ident <> ch,
                        prev_ident,
                        False,
                        [],
                        blocks_rev,
                        label,
                      )
                    False, True -> {
                      let next_prev = case current_ident {
                        "" -> prev_ident
                        _ -> current_ident
                      }
                      extract_import_blocks_loop(
                        rest,
                        0,
                        False,
                        False,
                        "",
                        next_prev,
                        False,
                        [],
                        blocks_rev,
                        label,
                      )
                    }
                    False, False ->
                      extract_import_blocks_loop(
                        rest,
                        0,
                        False,
                        False,
                        "",
                        "",
                        False,
                        [],
                        blocks_rev,
                        label,
                      )
                  }
              }
            _ ->
              case ch {
                "\"" ->
                  extract_import_blocks_loop(
                    rest,
                    depth,
                    True,
                    False,
                    "",
                    "",
                    capturing,
                    capture(capturing, captured_rev, ch),
                    blocks_rev,
                    label,
                  )
                "{" ->
                  extract_import_blocks_loop(
                    rest,
                    depth + 1,
                    False,
                    False,
                    "",
                    "",
                    capturing,
                    capture(capturing, captured_rev, ch),
                    blocks_rev,
                    label,
                  )
                "}" -> {
                  let next_depth = depth - 1
                  case next_depth == 0 && capturing {
                    True ->
                      extract_import_blocks_loop(
                        rest,
                        0,
                        False,
                        False,
                        "",
                        "",
                        False,
                        [],
                        [
                          captured_rev |> list.reverse |> string.concat,
                          ..blocks_rev
                        ],
                        label,
                      )
                    False ->
                      extract_import_blocks_loop(
                        rest,
                        next_depth,
                        False,
                        False,
                        "",
                        "",
                        capturing,
                        capture(capturing, captured_rev, ch),
                        blocks_rev,
                        label,
                      )
                  }
                }
                _ ->
                  extract_import_blocks_loop(
                    rest,
                    depth,
                    False,
                    False,
                    "",
                    "",
                    capturing,
                    capture(capturing, captured_rev, ch),
                    blocks_rev,
                    label,
                  )
              }
          }
      }
  }
}

fn capture(
  capturing: Bool,
  captured_rev: List(String),
  ch: String,
) -> List(String) {
  case capturing {
    True -> [ch, ..captured_rev]
    False -> captured_rev
  }
}

pub fn is_ident_char(ch: String) -> Bool {
  case ch {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "A"
    | "B"
    | "C"
    | "D"
    | "E"
    | "F"
    | "G"
    | "H"
    | "I"
    | "J"
    | "K"
    | "L"
    | "M"
    | "N"
    | "O"
    | "P"
    | "Q"
    | "R"
    | "S"
    | "T"
    | "U"
    | "V"
    | "W"
    | "X"
    | "Y"
    | "Z"
    | "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9"
    | "_" -> True
    _ -> False
  }
}

pub fn is_whitespace_char(ch: String) -> Bool {
  case ch {
    " " | "\t" | "\n" | "\r" -> True
    _ -> False
  }
}
