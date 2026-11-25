import gleam/bit_array
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import glexer
import glexer/token.{type Token}

/// A byte-offset text edit on a UTF-8 Gleam source string.
pub type TextEdit {
  TextEdit(start: Int, end: Int, replacement: String)
}

/// Sort non-overlapping `TextEdit`s and apply them to `source`.
pub fn apply_edits(source: String, edits: List(TextEdit)) -> String {
  case edits {
    [] -> source
    _ -> {
      let sorted =
        list.sort(edits, fn(a, b) {
          case int.compare(a.start, b.start) {
            order.Eq -> int.compare(a.end, b.end)
            other -> other
          }
        })
      let bytes = bit_array.from_string(source)
      let total_len = bit_array.byte_size(bytes)
      let #(chunks, cursor) =
        list.fold(sorted, #([], 0), fn(acc, edit) {
          let #(chunks, cursor) = acc
          let prefix = case
            edit.start > cursor && cursor >= 0 && edit.start <= total_len
          {
            True ->
              bit_array.slice(bytes, cursor, edit.start - cursor)
              |> result.unwrap(<<>>)
            False -> <<>>
          }
          let repl = bit_array.from_string(edit.replacement)
          #([repl, prefix, ..chunks], edit.end)
        })
      let tail = case cursor < total_len {
        True ->
          bit_array.slice(bytes, cursor, total_len - cursor)
          |> result.unwrap(<<>>)
        False -> <<>>
      }
      [tail, ..chunks]
      |> list.reverse
      |> bit_array.concat
      |> bit_array.to_string
      |> result.unwrap(source)
    }
  }
}

/// Skip whitespace and comment tokens.
pub fn skip_trivia(
  tokens: List(#(Token, glexer.Position)),
) -> List(#(Token, glexer.Position)) {
  case tokens {
    [#(token.Space(_), _), ..rest]
    | [#(token.CommentNormal(_), _), ..rest]
    | [#(token.CommentDoc(_), _), ..rest]
    | [#(token.CommentModule(_), _), ..rest] -> skip_trivia(rest)
    _ -> tokens
  }
}

/// Byte end offset of a token in source.
pub fn token_end(tok: Token, pos: glexer.Position) -> Int {
  pos.byte_offset + string.byte_size(token.to_source(tok))
}

/// Build a line-preserving comment replacement matching the newline count of `[start, end)`.
pub fn stripped_comment_preserving_lines(
  source: String,
  start: Int,
  end: Int,
  comment_line: String,
) -> String {
  let bytes = bit_array.from_string(source)
  let segment = case bit_array.slice(bytes, start, end - start) {
    Ok(slice) ->
      bit_array.to_string(slice)
      |> result.unwrap("")
    Error(_) -> ""
  }
  let line_count =
    segment
    |> string.split("\n")
    |> list.length
  list.repeat(comment_line, line_count)
  |> string.join("\n")
}

/// Convert a UTF-8 byte offset into a 1-based `#(line, column)` pair.
pub fn byte_offset_to_line_col(
  source: String,
  byte_offset: Int,
) -> #(Int, Int) {
  let src_bits = bit_array.from_string(source)
  let limit = int.min(int.max(byte_offset, 0), bit_array.byte_size(src_bits))
  case bit_array.slice(src_bits, at: 0, take: limit) {
    Ok(prefix) ->
      case bit_array.to_string(prefix) {
        Ok(prefix_str) -> {
          let lines = string.split(prefix_str, "\n")
          let line = list.length(lines)
          let col = case list.last(lines) {
            Ok(last) -> string.length(last) + 1
            Error(_) -> 1
          }
          #(line, col)
        }
        Error(_) -> #(count_newlines(prefix, 1), 1)
      }
    Error(_) -> #(1, 1)
  }
}

/// Convert a UTF-8 byte offset into a 1-based line number.
pub fn byte_offset_to_line(source: String, byte_offset: Int) -> Int {
  let #(line, _) = byte_offset_to_line_col(source, byte_offset)
  line
}

fn count_newlines(bits: BitArray, line: Int) -> Int {
  case bits {
    <<10, rest:bits>> -> count_newlines(rest, line + 1)
    <<_, rest:bits>> -> count_newlines(rest, line)
    _ -> line
  }
}

/// Remove a leading MoonBit visibility modifier (`pub`, `pub(all)`,
/// `pub(open)`, `pub(readonly)`, `priv`) and surrounding whitespace.
pub fn strip_visibility_prefix(s: String) -> String {
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
