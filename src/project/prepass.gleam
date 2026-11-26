import glance
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glexer
import glexer/token.{type Token}
import project/text_edit.{
  type TextEdit, TextEdit, apply_edits, byte_offset_to_line, skip_trivia,
  stripped_comment_preserving_lines, token_end,
}

/// Target MoonBit binding kind for an `@external(moonbit, ...)` directive.
pub type FfiKind {
  /// Calls a function inside another MoonBit package: `@pkg_alias.function(...)`
  PackageCall(package: String, function: String)
  /// Emits a raw WebAssembly import stub: `fn __ffi_name(...) -> ... = "mod" "import"`
  WasmImport(wasm_module: String, import_name: String)
  /// Defined directly in a co-located `[patch]` `.mbt` file inside the same MoonBit package.
  Patched
  /// Implemented by a Gleam function in `source_module` that will be spliced
  /// into the target module's lowered IR (avoiding circular package imports).
  GleamPatch(source_module: String, source_function: String)
}

/// Which `@target(...)` branch to keep when compiling a Gleam module.
pub type TargetBranch {
  PreferErlang
  PreferJavascript
}

/// Target MoonBit type for an `@external_type(moonbit, "pkg", "Type")` directive.
pub type ExternalType {
  ExternalType(package: String, type_name: String)
}

/// How the FFI mapping was declared in the Gleam source file.
pub type FfiSource {
  DocPragma
  RawAttribute
}

/// An extracted `@external(moonbit, ...)` mapping bound to a top-level function.
pub type FfiEntry {
  FfiEntry(
    module: String,
    function_name: String,
    kind: FfiKind,
    source: FfiSource,
    line: Int,
  )
}

/// An extracted `/// @patch("mod.fn")` / `/// @gekko.patch("mod.fn")` mapping
/// attached to a top-level Gleam function.
pub type GleamPatchEntry {
  GleamPatchEntry(
    source_module: String,
    source_function: String,
    target: String,
    line: Int,
  )
}

/// An extracted `@external_type(moonbit, ...)` mapping bound to a custom type.
pub type ExternalTypeEntry {
  ExternalTypeEntry(
    module: String,
    gleam_type_name: String,
    target: ExternalType,
    source: FfiSource,
    line: Int,
  )
}

/// Output of running the source pre-pass over a single Gleam module.
pub type PrepassResult {
  PrepassResult(
    cleaned_source: String,
    ffi_entries: List(FfiEntry),
    external_types: List(ExternalTypeEntry),
    gleam_patches: List(GleamPatchEntry),
  )
}

type PendingFfi {
  PendingFfi(kind: FfiKind, source: FfiSource, line: Int)
}

type PendingExternalType {
  PendingExternalType(target: ExternalType, source: FfiSource, line: Int)
}

type PendingPatch {
  PendingPatch(target: String, line: Int)
}

type ScanState {
  ScanState(
    brace_depth: Int,
    pending_fns: List(PendingFfi),
    pending_types: List(PendingExternalType),
    pending_patches: List(PendingPatch),
    entries: List(FfiEntry),
    ext_types: List(ExternalTypeEntry),
    patch_entries: List(GleamPatchEntry),
    edits: List(TextEdit),
  )
}

/// Parse a target string + function name into `PackageCall` or `WasmImport`.
pub fn parse_ffi_kind(target: String, function: String) -> FfiKind {
  case string.split_once(target, on: "wasm:") {
    Ok(#("", wasm_module)) -> WasmImport(wasm_module:, import_name: function)
    _ -> PackageCall(package: target, function:)
  }
}

/// Scan `source` for `/// @external(moonbit, ...)` and `/// @external_type(moonbit, ...)`
/// doc-comment pragmas and raw `@external(...)` / `@external_type(...)` attributes,
/// strip raw attributes while preserving exact line numbers, and inject
/// `{ panic as "external" }` for bodyless FFI functions so `glance` and
/// `gleam export package-interface` succeed.
pub fn preprocess_module(module_name: String, source: String) -> PrepassResult {
  let tokens =
    glexer.new(source)
    |> glexer.lex

  let init_state =
    ScanState(
      brace_depth: 0,
      pending_fns: [],
      pending_types: [],
      pending_patches: [],
      entries: [],
      ext_types: [],
      patch_entries: [],
      edits: [],
    )
  let final = scan_tokens(tokens, source, module_name, init_state)

  let cleaned_source = apply_edits(source, final.edits)

  PrepassResult(
    cleaned_source:,
    ffi_entries: list.reverse(final.entries),
    external_types: list.reverse(final.ext_types),
    gleam_patches: list.reverse(final.patch_entries),
  )
}

/// Run the pre-pass and parse the cleaned source with `glance.module`.
pub fn parse_module(
  module_name: String,
  source: String,
) -> Result(#(glance.Module, PrepassResult), glance.Error) {
  let result = preprocess_module(module_name, source)
  use parsed <- result.try(glance.module(result.cleaned_source))
  Ok(#(parsed, result))
}

fn clear_pending(st: ScanState) -> ScanState {
  ScanState(..st, pending_fns: [], pending_types: [], pending_patches: [])
}

fn scan_tokens(
  tokens: List(#(Token, glexer.Position)),
  source: String,
  module_name: String,
  st: ScanState,
) -> ScanState {
  case tokens {
    [] -> st

    [#(token.LeftBrace, _), ..rest] ->
      scan_tokens(
        rest,
        source,
        module_name,
        clear_pending(ScanState(..st, brace_depth: st.brace_depth + 1)),
      )

    [#(token.RightBrace, _), ..rest] ->
      scan_tokens(
        rest,
        source,
        module_name,
        clear_pending(
          ScanState(..st, brace_depth: int.max(0, st.brace_depth - 1)),
        ),
      )

    // Skip whitespace & regular/module comments without dropping pending pragmas.
    [#(token.Space(_), _), ..rest]
    | [#(token.CommentNormal(_), _), ..rest]
    | [#(token.CommentModule(_), _), ..rest] ->
      scan_tokens(rest, source, module_name, st)

    // Doc comment at top level: check for `/// @external(...)`, `/// @external_type(...)`,
    // and `/// @patch(...)` / `/// @gekko.patch(...)`.
    [#(token.CommentDoc(doc_text), pos), ..rest] if st.brace_depth == 0 -> {
      let line = byte_offset_to_line(source, pos.byte_offset)
      let pending_fns = case parse_doc_pragma(doc_text) {
        Some(kind) -> [
          PendingFfi(kind:, source: DocPragma, line:),
          ..st.pending_fns
        ]
        None -> st.pending_fns
      }
      let pending_types = case parse_doc_external_type_pragma(doc_text) {
        Some(target) -> [
          PendingExternalType(target:, source: DocPragma, line:),
          ..st.pending_types
        ]
        None -> st.pending_types
      }
      let pending_patches =
        list.fold(
          parse_doc_patch_pragmas(doc_text),
          st.pending_patches,
          fn(acc, target) { [PendingPatch(target:, line:), ..acc] },
        )
      scan_tokens(
        rest,
        source,
        module_name,
        ScanState(..st, pending_fns:, pending_types:, pending_patches:),
      )
    }

    // Raw attribute at top level: `@external(moonbit, ...)` or `@external_type(moonbit, ...)`
    [#(token.At, pos), ..after_at] if st.brace_depth == 0 -> {
      case match_raw_external_moonbit(after_at) {
        Some(#(kind, end_offset, remaining)) -> {
          let start_offset = pos.byte_offset
          let line = byte_offset_to_line(source, start_offset)
          let replacement =
            stripped_comment_preserving_lines(
              source,
              start_offset,
              end_offset,
              "// @external_moonbit_stripped",
            )
          let edit =
            TextEdit(start: start_offset, end: end_offset, replacement:)
          let pending_fns = [
            PendingFfi(kind:, source: RawAttribute, line:),
            ..st.pending_fns
          ]
          scan_tokens(
            remaining,
            source,
            module_name,
            ScanState(..st, pending_fns:, edits: [edit, ..st.edits]),
          )
        }
        None ->
          case match_raw_external_type_moonbit(after_at) {
            Some(#(target, end_offset, remaining)) -> {
              let start_offset = pos.byte_offset
              let line = byte_offset_to_line(source, start_offset)
              let replacement =
                stripped_comment_preserving_lines(
                  source,
                  start_offset,
                  end_offset,
                  "// @external_type_moonbit_stripped",
                )
              let edit =
                TextEdit(start: start_offset, end: end_offset, replacement:)
              let pending_types = [
                PendingExternalType(target:, source: RawAttribute, line:),
                ..st.pending_types
              ]
              scan_tokens(
                remaining,
                source,
                module_name,
                ScanState(..st, pending_types:, edits: [edit, ..st.edits]),
              )
            }
            None -> scan_tokens(after_at, source, module_name, st)
          }
      }
    }

    // Top-level `pub ...`
    [#(token.Pub, _), ..after_pub] if st.brace_depth == 0 -> {
      let after_ws = skip_trivia(after_pub)
      case after_ws {
        [#(token.Fn, _), ..after_fn] ->
          handle_top_fn(after_fn, source, module_name, st)
        [#(token.Opaque, _), ..after_opaque] ->
          case skip_trivia(after_opaque) {
            [#(token.Type, _), ..after_type] ->
              handle_top_type(after_type, source, module_name, st)
            other -> scan_tokens(other, source, module_name, clear_pending(st))
          }
        [#(token.Type, _), ..after_type] ->
          handle_top_type(after_type, source, module_name, st)
        [#(token.Const, _), ..rest] ->
          scan_tokens(rest, source, module_name, clear_pending(st))
        _ -> scan_tokens(after_ws, source, module_name, clear_pending(st))
      }
    }

    [#(token.Fn, _), ..after_fn] if st.brace_depth == 0 ->
      handle_top_fn(after_fn, source, module_name, st)

    [#(token.Opaque, _), ..after_opaque] if st.brace_depth == 0 ->
      case skip_trivia(after_opaque) {
        [#(token.Type, _), ..after_type] ->
          handle_top_type(after_type, source, module_name, st)
        other -> scan_tokens(other, source, module_name, clear_pending(st))
      }

    [#(token.Type, _), ..after_type] if st.brace_depth == 0 ->
      handle_top_type(after_type, source, module_name, st)

    // Non-matching top-level declaration clears stray pending pragmas
    [#(token.Const, _), ..rest]
      | [#(token.Import, _), ..rest]
      if st.brace_depth == 0
    -> scan_tokens(rest, source, module_name, clear_pending(st))

    [_, ..rest] -> scan_tokens(rest, source, module_name, st)
  }
}

fn handle_top_type(
  after_type: List(#(Token, glexer.Position)),
  source: String,
  module_name: String,
  st: ScanState,
) -> ScanState {
  case skip_trivia(after_type) {
    [#(token.UpperName(type_name), _), ..rest] -> {
      let new_ext_types =
        st.pending_types
        |> list.reverse
        |> list.map(fn(p) {
          ExternalTypeEntry(
            module: module_name,
            gleam_type_name: type_name,
            target: p.target,
            source: p.source,
            line: p.line,
          )
        })
      let ext_types =
        list.fold(new_ext_types, st.ext_types, fn(acc, e) { [e, ..acc] })
      scan_tokens(
        rest,
        source,
        module_name,
        clear_pending(ScanState(..st, brace_depth: 0, ext_types:)),
      )
    }
    other ->
      scan_tokens(
        other,
        source,
        module_name,
        clear_pending(ScanState(..st, brace_depth: 0)),
      )
  }
}

fn handle_top_fn(
  after_fn: List(#(Token, glexer.Position)),
  source: String,
  module_name: String,
  st: ScanState,
) -> ScanState {
  case skip_trivia(after_fn) {
    [#(token.Name(fn_name), _), ..after_name] -> {
      case skip_trivia(after_name) {
        [#(token.LeftParen, _), ..] as params_tokens -> {
          let new_entries =
            st.pending_fns
            |> list.reverse
            |> list.map(fn(p) {
              FfiEntry(
                module: module_name,
                function_name: fn_name,
                kind: p.kind,
                source: p.source,
                line: p.line,
              )
            })
          let entries =
            list.fold(new_entries, st.entries, fn(acc, e) { [e, ..acc] })

          let new_patches =
            st.pending_patches
            |> list.reverse
            |> list.map(fn(p) {
              GleamPatchEntry(
                source_module: module_name,
                source_function: fn_name,
                target: p.target,
                line: p.line,
              )
            })
          let patch_entries =
            list.fold(new_patches, st.patch_entries, fn(acc, e) { [e, ..acc] })

          let #(edits, remaining) = case st.pending_fns {
            [] -> #(st.edits, params_tokens)
            [_, ..] ->
              case find_fn_signature_end(params_tokens) {
                Some(#(sig_end, has_body, rest_tokens)) ->
                  case has_body {
                    True -> #(st.edits, rest_tokens)
                    False -> {
                      let edit =
                        TextEdit(
                          start: sig_end,
                          end: sig_end,
                          replacement: " { panic as \"external\" }",
                        )
                      #([edit, ..st.edits], rest_tokens)
                    }
                  }
                None -> #(st.edits, params_tokens)
              }
          }
          scan_tokens(
            remaining,
            source,
            module_name,
            clear_pending(
              ScanState(..st, brace_depth: 0, entries:, patch_entries:, edits:),
            ),
          )
        }
        other ->
          scan_tokens(
            other,
            source,
            module_name,
            clear_pending(ScanState(..st, brace_depth: 0)),
          )
      }
    }
    other ->
      scan_tokens(
        other,
        source,
        module_name,
        clear_pending(ScanState(..st, brace_depth: 0)),
      )
  }
}

fn parse_doc_pragma(doc_text: String) -> Option(FfiKind) {
  use #(arg1, arg2) <- option.then(parse_doc_directive(doc_text, "external"))
  Some(parse_ffi_kind(arg1, arg2))
}

fn parse_doc_external_type_pragma(doc_text: String) -> Option(ExternalType) {
  use #(pkg, type_name) <- option.then(parse_doc_directive(
    doc_text,
    "external_type",
  ))
  Some(ExternalType(package: pkg, type_name:))
}

fn parse_doc_patch_pragmas(doc_text: String) -> List(String) {
  string.split(doc_text, "\n")
  |> scan_doc_patch_lines(False, [])
  |> list.reverse
}

fn scan_doc_patch_lines(
  lines: List(String),
  in_fence: Bool,
  rev_acc: List(String),
) -> List(String) {
  case lines {
    [] -> rev_acc
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case string.starts_with(trimmed, "```") {
        True -> scan_doc_patch_lines(rest, !in_fence, rev_acc)
        False -> {
          let next_acc = case
            !in_fence
            && {
              string.starts_with(trimmed, "@patch")
              || string.starts_with(trimmed, "@gekko.patch")
            }
          {
            True ->
              case parse_single_doc_patch(trimmed) {
                Some(target) if target != "" -> [target, ..rev_acc]
                _ -> rev_acc
              }
            False -> rev_acc
          }
          scan_doc_patch_lines(rest, in_fence, next_acc)
        }
      }
    }
  }
}

fn parse_single_doc_patch(trimmed: String) -> Option(String) {
  let tokens =
    glexer.new(trimmed)
    |> glexer.lex
  case tokens {
    [#(token.At, _), ..after_at] -> {
      let after_name = case skip_trivia(after_at) {
        [#(token.Name("patch"), _), ..rest] -> Some(rest)
        [#(token.Name("gekko"), _), ..after_gekko] ->
          case skip_trivia(after_gekko) {
            [#(token.Dot, _), ..after_dot] ->
              case skip_trivia(after_dot) {
                [#(token.Name("patch"), _), ..rest] -> Some(rest)
                _ -> None
              }
            _ -> None
          }
        _ -> None
      }
      case after_name {
        None -> None
        Some(rest) ->
          case skip_trivia(rest) {
            [#(token.LeftParen, _), ..after_lp] ->
              case skip_trivia(after_lp) {
                [#(token.String(target), _), ..after_str] ->
                  case match_trailing_close_paren(after_str, target, "") {
                    Some(#(t, _, _, remaining)) ->
                      case skip_trivia(remaining) {
                        [] -> Some(t)
                        _ -> None
                      }
                    None -> None
                  }
                _ -> None
              }
            _ -> None
          }
      }
    }
    _ -> None
  }
}

fn parse_doc_directive(
  doc_text: String,
  directive_name: String,
) -> Option(#(String, String)) {
  string.split(doc_text, "\n")
  |> scan_doc_directive_lines(directive_name, False, None)
}

fn scan_doc_directive_lines(
  lines: List(String),
  directive_name: String,
  in_fence: Bool,
  found: Option(#(String, String)),
) -> Option(#(String, String)) {
  case lines {
    [] -> found
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case string.starts_with(trimmed, "```") {
        True -> scan_doc_directive_lines(rest, directive_name, !in_fence, found)
        False ->
          case !in_fence && string.starts_with(trimmed, "@" <> directive_name) {
            True -> {
              let next_found = case
                parse_single_doc_directive(trimmed, directive_name)
              {
                Some(_) as hit -> hit
                None -> found
              }
              scan_doc_directive_lines(
                rest,
                directive_name,
                in_fence,
                next_found,
              )
            }
            False ->
              scan_doc_directive_lines(rest, directive_name, in_fence, found)
          }
      }
    }
  }
}

fn parse_single_doc_directive(
  trimmed: String,
  directive_name: String,
) -> Option(#(String, String)) {
  let tokens =
    glexer.new(trimmed)
    |> glexer.lex
  case tokens {
    [#(token.At, _), ..after_at] ->
      case match_raw_moonbit_directive(directive_name, after_at) {
        Some(#(arg1, arg2, _, remaining)) ->
          case skip_trivia(remaining) {
            [] -> Some(#(arg1, arg2))
            _ -> None
          }
        None -> None
      }
    _ -> None
  }
}

fn match_raw_external_moonbit(
  tokens: List(#(Token, glexer.Position)),
) -> Option(#(FfiKind, Int, List(#(Token, glexer.Position)))) {
  use #(target, fn_name, end_offset, rest) <- option.then(
    match_raw_moonbit_directive("external", tokens),
  )
  Some(#(parse_ffi_kind(target, fn_name), end_offset, rest))
}

fn match_raw_external_type_moonbit(
  tokens: List(#(Token, glexer.Position)),
) -> Option(#(ExternalType, Int, List(#(Token, glexer.Position)))) {
  use #(pkg, type_name, end_offset, rest) <- option.then(
    match_raw_moonbit_directive("external_type", tokens),
  )
  Some(#(ExternalType(package: pkg, type_name:), end_offset, rest))
}

fn match_raw_moonbit_directive(
  directive_name: String,
  tokens: List(#(Token, glexer.Position)),
) -> Option(#(String, String, Int, List(#(Token, glexer.Position)))) {
  case skip_trivia(tokens) {
    [#(token.Name(name), _), ..rest] if name == directive_name ->
      case skip_trivia(rest) {
        [#(token.LeftParen, _), ..rest] ->
          case skip_trivia(rest) {
            [#(token.Name("moonbit"), _), ..rest] ->
              case skip_trivia(rest) {
                [#(token.Comma, _), ..rest] ->
                  case skip_trivia(rest) {
                    [#(token.String(arg1), _), ..rest] ->
                      case skip_trivia(rest) {
                        [#(token.Comma, _), ..rest] ->
                          case skip_trivia(rest) {
                            [#(token.String(arg2), _), ..rest] ->
                              match_trailing_close_paren(rest, arg1, arg2)
                            _ -> None
                          }
                        _ -> None
                      }
                    _ -> None
                  }
                _ -> None
              }
            _ -> None
          }
        _ -> None
      }
    _ -> None
  }
}

fn match_trailing_close_paren(
  tokens: List(#(Token, glexer.Position)),
  arg1: String,
  arg2: String,
) -> Option(#(String, String, Int, List(#(Token, glexer.Position)))) {
  case skip_trivia(tokens) {
    [#(token.Comma, _), ..rest] ->
      case skip_trivia(rest) {
        [#(token.RightParen, pos), ..after] ->
          Some(#(arg1, arg2, pos.byte_offset + 1, after))
        _ -> None
      }
    [#(token.RightParen, pos), ..after] ->
      Some(#(arg1, arg2, pos.byte_offset + 1, after))
    _ -> None
  }
}

pub fn find_fn_signature_end(
  tokens: List(#(Token, glexer.Position)),
) -> Option(#(Int, Bool, List(#(Token, glexer.Position)))) {
  case tokens {
    [#(token.LeftParen, _), ..rest] -> {
      use #(params_end, after_params) <- option.then(consume_balanced_parens(
        rest,
        1,
      ))
      let #(sig_end, after_sig) = case skip_trivia(after_params) {
        [#(token.RightArrow, _), ..after_arrow] ->
          case skip_type(after_arrow) {
            Some(#(ret_end, after_ret)) -> #(ret_end, after_ret)
            None -> #(params_end, after_params)
          }
        _ -> #(params_end, after_params)
      }
      case skip_trivia(after_sig) {
        [#(token.LeftBrace, _), ..] -> Some(#(sig_end, True, after_sig))
        _ -> Some(#(sig_end, False, after_sig))
      }
    }
    _ -> None
  }
}

fn consume_balanced_parens(
  tokens: List(#(Token, glexer.Position)),
  depth: Int,
) -> Option(#(Int, List(#(Token, glexer.Position)))) {
  case tokens {
    [] -> None
    [#(token.LeftParen, _), ..rest] -> consume_balanced_parens(rest, depth + 1)
    [#(token.RightParen, pos), ..rest] ->
      case depth == 1 {
        True -> Some(#(pos.byte_offset + 1, rest))
        False -> consume_balanced_parens(rest, depth - 1)
      }
    [_, ..rest] -> consume_balanced_parens(rest, depth)
  }
}

fn skip_type(
  tokens: List(#(Token, glexer.Position)),
) -> Option(#(Int, List(#(Token, glexer.Position)))) {
  case skip_trivia(tokens) {
    [#(token.Fn, _), ..rest] ->
      case skip_trivia(rest) {
        [#(token.LeftParen, _), ..after_lp] -> {
          use #(_, after_rp) <- option.then(consume_balanced_parens(after_lp, 1))
          case skip_trivia(after_rp) {
            [#(token.RightArrow, _), ..after_arrow] -> skip_type(after_arrow)
            _ -> None
          }
        }
        _ -> None
      }

    [#(token.Hash, _), ..rest] ->
      case skip_trivia(rest) {
        [#(token.LeftParen, _), ..after_lp] ->
          consume_balanced_parens(after_lp, 1)
        _ -> None
      }

    [#(token.DiscardName(_) as tok, pos), ..rest] ->
      Some(#(token_end(tok, pos), rest))

    [#(token.Name(_) as tok, pos), ..rest]
    | [#(token.UpperName(_) as tok, pos), ..rest] -> {
      let #(end1, after_name) = case skip_trivia(rest) {
        [#(token.Dot, _), ..after_dot] ->
          case skip_trivia(after_dot) {
            [#(token.UpperName(_) as qual_tok, qual_pos), ..after_qual] -> #(
              token_end(qual_tok, qual_pos),
              after_qual,
            )
            _ -> #(token_end(tok, pos), rest)
          }
        _ -> #(token_end(tok, pos), rest)
      }
      case skip_trivia(after_name) {
        [#(token.LeftParen, _), ..after_lp] ->
          consume_balanced_parens(after_lp, 1)
        _ -> Some(#(end1, after_name))
      }
    }

    _ -> None
  }
}
