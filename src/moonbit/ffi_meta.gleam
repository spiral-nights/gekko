import emit/prelude_runtime
import filepath
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import moonbit/syntax
import project/fs
import project/paths
import simplifile

/// Trait implementations and `Eq`-required `Hash` parameter indices
/// discovered from MoonBit `.mbt` declarations.
pub type ExternalTypeTraits {
  ExternalTypeTraits(
    has_eq: Bool,
    has_debug: Bool,
    has_hash: Bool,
    has_inspect: Bool,
    eq_requires_hash_params: Set(Int),
  )
}

/// Generic MoonBit function signature and trait bounds discovered from `.mbt`.
pub type ExternalFnMeta {
  ExternalFnMeta(
    type_params: List(#(String, Set(String))),
    param_types: List(MbtType),
    return_type: Option(MbtType),
  )
}

/// Lightweight parsed MoonBit type expression from `.mbt` function signatures.
pub type MbtType {
  MbtVar(String)
  MbtNamed(name: String, args: List(MbtType))
  MbtTuple(List(MbtType))
  MbtFn(params: List(MbtType), return_type: MbtType)
}

/// Aggregated trait and FFI signature metadata scanned from MoonBit packages.
pub type FfiMetadata {
  FfiMetadata(
    types: Dict(#(String, String), ExternalTypeTraits),
    functions: Dict(#(String, String), ExternalFnMeta),
  )
}

fn empty_type_traits() -> ExternalTypeTraits {
  ExternalTypeTraits(
    has_eq: False,
    has_debug: False,
    has_hash: False,
    has_inspect: False,
    eq_requires_hash_params: set.new(),
  )
}

fn merge_traits(
  a: ExternalTypeTraits,
  b: ExternalTypeTraits,
) -> ExternalTypeTraits {
  ExternalTypeTraits(
    has_eq: a.has_eq || b.has_eq,
    has_debug: a.has_debug || b.has_debug,
    has_hash: a.has_hash || b.has_hash,
    has_inspect: a.has_inspect || b.has_inspect,
    eq_requires_hash_params: set.union(
      a.eq_requires_hash_params,
      b.eq_requires_hash_params,
    ),
  )
}

/// Return baseline MoonBit builtin + `gprelude` trait metadata.
pub fn base_metadata() -> FfiMetadata {
  let builtin_value_traits =
    ExternalTypeTraits(
      has_eq: True,
      has_debug: True,
      has_hash: True,
      has_inspect: False,
      eq_requires_hash_params: set.new(),
    )
  let builtin_names = [
    "Option",
    "Result",
    "Int",
    "Int64",
    "UInt",
    "UInt64",
    "Double",
    "Float",
    "Bool",
    "String",
    "Bytes",
    "Unit",
    "Char",
    "Byte",
  ]
  let initial_types =
    list.fold(builtin_names, dict.new(), fn(acc, name) {
      acc
      |> dict.insert(#("builtin", name), builtin_value_traits)
      |> dict.insert(#("", name), builtin_value_traits)
    })
  let seeded = FfiMetadata(types: initial_types, functions: dict.new())
  scan_mbt_source(seeded, "gprelude", prelude_runtime.gprelude_mbt())
}

/// Scan `<root>/moonbit/**` packages across all given package roots, starting
/// from `base_metadata()`, and skipping any `.mbt` file whose canonical path is
/// present in `excluded_files` (such as files injected via `[module_inject]`).
pub fn scan_package_roots_excluding(
  roots: List(String),
  excluded_files: Set(String),
) -> FfiMetadata {
  list.fold(roots, base_metadata(), fn(meta, root) {
    let moonbit_root = filepath.join(root, "moonbit")
    case simplifile.is_directory(moonbit_root) {
      Ok(True) -> scan_moonbit_root(meta, moonbit_root, excluded_files)
      _ -> meta
    }
  })
}

fn scan_moonbit_root(
  meta: FfiMetadata,
  moonbit_root: String,
  excluded_files: Set(String),
) -> FfiMetadata {
  case read_sorted_entries(moonbit_root) {
    Error(_) -> meta
    Ok(entries) ->
      list.fold(entries, meta, fn(acc, entry) {
        let full_path = filepath.join(moonbit_root, entry)
        case
          fs.is_ignored_entry(entry)
          || { entry == "gprelude" && fs.is_generated_gprelude_dir(full_path) }
        {
          True -> acc
          False ->
            case simplifile.is_directory(full_path) {
              Ok(True) -> visit_pkg_dir(acc, full_path, entry, excluded_files)
              _ -> acc
            }
        }
      })
  }
}

fn visit_pkg_dir(
  meta: FfiMetadata,
  cur_dir: String,
  rel_pkg: String,
  excluded_files: Set(String),
) -> FfiMetadata {
  case read_sorted_entries(cur_dir) {
    Error(_) -> meta
    Ok(entries) -> {
      let #(mbt_files, subdirs) =
        list.fold(entries, #([], []), fn(parts, entry) {
          let #(files_acc, dirs_acc) = parts
          case fs.is_ignored_entry(entry) {
            True -> parts
            False -> {
              let full = filepath.join(cur_dir, entry)
              case simplifile.is_directory(full) {
                Ok(True) -> #(files_acc, [entry, ..dirs_acc])
                _ ->
                  case
                    string.ends_with(entry, ".mbt")
                    && !string.ends_with(entry, "_test.mbt")
                    && !string.ends_with(entry, "_wbtest.mbt")
                  {
                    True -> {
                      let resolved = paths.absolute(full)
                      case set.contains(excluded_files, resolved) {
                        True -> parts
                        False -> #([full, ..files_acc], dirs_acc)
                      }
                    }
                    False -> parts
                  }
              }
            }
          }
        })
      let after_files =
        list.fold(list.reverse(mbt_files), meta, fn(acc, file_path) {
          case simplifile.read(from: file_path) {
            Ok(content) -> scan_mbt_source(acc, rel_pkg, content)
            Error(_) -> acc
          }
        })
      list.fold(list.reverse(subdirs), after_files, fn(acc, sub) {
        visit_pkg_dir(
          acc,
          filepath.join(cur_dir, sub),
          rel_pkg <> "/" <> sub,
          excluded_files,
        )
      })
    }
  }
}

fn read_sorted_entries(dir: String) -> Result(List(String), Nil) {
  simplifile.read_directory(at: dir)
  |> result.map(fn(xs) { list.sort(xs, string.compare) })
  |> result.replace_error(Nil)
}

/// Scan a single MoonBit `.mbt` file for type traits and generic FFI function signatures.
pub fn scan_mbt_source(
  meta: FfiMetadata,
  pkg_name: String,
  source: String,
) -> FfiMetadata {
  let decls = extract_top_decls(source)
  let #(final_meta, _) =
    list.fold(decls, #(meta, []), fn(state, decl) {
      let #(cur_meta, pending_derives) = state
      process_top_decl(decl, pkg_name, cur_meta, pending_derives, False)
    })
  final_meta
}

/// Scan an injected MoonBit `.mbt` file for generic function signatures
/// (including private `fn` declarations) indexed under `mod_name`.
pub fn scan_injected_mbt_source(
  meta: FfiMetadata,
  mod_name: String,
  source: String,
) -> FfiMetadata {
  let decls = extract_top_decls(source)
  let #(final_meta, _) =
    list.fold(decls, #(meta, []), fn(state, decl) {
      let #(cur_meta, pending_derives) = state
      process_top_decl(decl, mod_name, cur_meta, pending_derives, True)
    })
  final_meta
}

/// True if `(pkg, type_name)` implements `Eq`, `Debug`, and `Hash`.
pub fn is_derivable(meta: FfiMetadata, pkg: String, type_name: String) -> Bool {
  case dict.get(meta.types, #(pkg, type_name)) {
    Ok(t) -> t.has_eq && t.has_debug && t.has_hash
    Error(_) -> False
  }
}

/// True if `(pkg, type_name)` implements `@gprelude.GleamInspect`.
pub fn is_inspectable(
  meta: FfiMetadata,
  pkg: String,
  type_name: String,
) -> Bool {
  case dict.get(meta.types, #(pkg, type_name)) {
    Ok(t) -> t.has_inspect
    Error(_) -> False
  }
}

/// Return the 0-based type-parameter indices of `(pkg, type_name)` that require `Hash`
/// in its `Eq` implementation.
pub fn eq_requires_hash_params(
  meta: FfiMetadata,
  pkg: String,
  type_name: String,
) -> Set(Int) {
  case dict.get(meta.types, #(pkg, type_name)) {
    Ok(t) -> t.eq_requires_hash_params
    Error(_) -> set.new()
  }
}

/// Look up scanned generic function metadata by `(pkg, fn_name)`.
pub fn lookup_function(
  meta: FfiMetadata,
  pkg: String,
  fn_name: String,
) -> Option(ExternalFnMeta) {
  dict.get(meta.functions, #(pkg, fn_name)) |> option.from_result
}

// -----------------------------------------------------------------------------
// Top-level declaration extractor
// -----------------------------------------------------------------------------

type ScanMode {
  ModeNormal
  ModeLineComment
  ModeMultilineStr
  ModeString(escaped: Bool)
  ModeChar(escaped: Bool)
}

type ExtractState {
  ExtractState(
    mode: ScanMode,
    brace_depth: Int,
    paren_depth: Int,
    bracket_depth: Int,
    at_line_start: Bool,
    rev_buf: List(String),
    rev_decls: List(String),
  )
}

fn extract_top_decls(source: String) -> List(String) {
  let normalized =
    source
    |> string.replace("\r\n", "\n")
    |> string.replace("\r", "\n")
  let graphemes = string.to_graphemes(normalized)
  let st0 =
    ExtractState(
      mode: ModeNormal,
      brace_depth: 0,
      paren_depth: 0,
      bracket_depth: 0,
      at_line_start: True,
      rev_buf: [],
      rev_decls: [],
    )
  let st_end = step_graphemes(graphemes, st0)
  let final_decls = case collapse_ws(syntax.rev_str(st_end.rev_buf)) {
    "" -> st_end.rev_decls
    last -> [last, ..st_end.rev_decls]
  }
  list.reverse(final_decls)
}

fn step_graphemes(graphemes: List(String), st: ExtractState) -> ExtractState {
  case graphemes {
    [] -> st
    [ch, ..rest] ->
      case st.mode {
        ModeLineComment | ModeMultilineStr ->
          case ch {
            "\n" ->
              handle_normal_newline(rest, ExtractState(..st, mode: ModeNormal))
            _ -> step_graphemes(rest, st)
          }

        ModeString(escaped:) -> {
          let next_mode = case escaped {
            True -> ModeString(escaped: False)
            False ->
              case ch {
                "\\" -> ModeString(escaped: True)
                "\"" -> ModeNormal
                _ -> ModeString(escaped: False)
              }
          }
          let next_buf = case st.brace_depth == 0 {
            True -> [ch, ..st.rev_buf]
            False -> st.rev_buf
          }
          step_graphemes(
            rest,
            ExtractState(..st, mode: next_mode, rev_buf: next_buf),
          )
        }

        ModeChar(escaped:) ->
          case ch {
            "\n" ->
              handle_normal_newline(rest, ExtractState(..st, mode: ModeNormal))
            _ -> {
              let next_mode = case escaped {
                True -> ModeChar(escaped: False)
                False ->
                  case ch {
                    "\\" -> ModeChar(escaped: True)
                    "'" -> ModeNormal
                    _ -> ModeChar(escaped: False)
                  }
              }
              let next_buf = case st.brace_depth == 0 {
                True -> [ch, ..st.rev_buf]
                False -> st.rev_buf
              }
              step_graphemes(
                rest,
                ExtractState(..st, mode: next_mode, rev_buf: next_buf),
              )
            }
          }

        ModeNormal ->
          case ch, rest {
            "/", ["/", ..after_slash] ->
              step_graphemes(
                after_slash,
                ExtractState(..st, mode: ModeLineComment, at_line_start: False),
              )
            "#", ["|", ..after_pipe] if st.at_line_start ->
              step_graphemes(
                after_pipe,
                ExtractState(..st, mode: ModeMultilineStr, at_line_start: False),
              )
            "\n", _ -> handle_normal_newline(rest, st)
            "\"", _ -> {
              let next_buf = case st.brace_depth == 0 {
                True -> [ch, ..st.rev_buf]
                False -> st.rev_buf
              }
              step_graphemes(
                rest,
                ExtractState(
                  ..st,
                  mode: ModeString(False),
                  at_line_start: False,
                  rev_buf: next_buf,
                ),
              )
            }
            "'", _ -> {
              let next_buf = case st.brace_depth == 0 {
                True -> [ch, ..st.rev_buf]
                False -> st.rev_buf
              }
              step_graphemes(
                rest,
                ExtractState(
                  ..st,
                  mode: ModeChar(False),
                  at_line_start: False,
                  rev_buf: next_buf,
                ),
              )
            }
            "{", _ ->
              case st.brace_depth == 0 {
                True -> {
                  let decl = collapse_ws(syntax.rev_str(st.rev_buf))
                  let next_decls = case decl {
                    "" -> st.rev_decls
                    _ -> [decl, ..st.rev_decls]
                  }
                  step_graphemes(
                    rest,
                    ExtractState(
                      mode: ModeNormal,
                      brace_depth: 1,
                      paren_depth: 0,
                      bracket_depth: 0,
                      at_line_start: False,
                      rev_buf: [],
                      rev_decls: next_decls,
                    ),
                  )
                }
                False ->
                  step_graphemes(
                    rest,
                    ExtractState(
                      ..st,
                      brace_depth: st.brace_depth + 1,
                      at_line_start: False,
                    ),
                  )
              }
            "}", _ ->
              step_graphemes(
                rest,
                ExtractState(
                  ..st,
                  brace_depth: int.max(0, st.brace_depth - 1),
                  at_line_start: False,
                ),
              )
            _, _ ->
              case st.brace_depth == 0 {
                False -> {
                  let next_start =
                    st.at_line_start && { ch == " " || ch == "\t" }
                  step_graphemes(
                    rest,
                    ExtractState(..st, at_line_start: next_start),
                  )
                }
                True -> {
                  let next_paren = case ch {
                    "(" -> st.paren_depth + 1
                    ")" -> int.max(0, st.paren_depth - 1)
                    _ -> st.paren_depth
                  }
                  let next_bracket = case ch {
                    "[" -> st.bracket_depth + 1
                    "]" -> int.max(0, st.bracket_depth - 1)
                    _ -> st.bracket_depth
                  }
                  let buf_ch = case ch {
                    "\t" -> " "
                    _ -> ch
                  }
                  let next_start =
                    st.at_line_start && { ch == " " || ch == "\t" }
                  step_graphemes(
                    rest,
                    ExtractState(
                      ..st,
                      paren_depth: next_paren,
                      bracket_depth: next_bracket,
                      at_line_start: next_start,
                      rev_buf: [buf_ch, ..st.rev_buf],
                    ),
                  )
                }
              }
          }
      }
  }
}

fn handle_normal_newline(rest: List(String), st: ExtractState) -> ExtractState {
  case st.brace_depth == 0 {
    False -> step_graphemes(rest, ExtractState(..st, at_line_start: True))
    True ->
      case st.paren_depth > 0 || st.bracket_depth > 0 {
        True ->
          step_graphemes(
            rest,
            ExtractState(..st, at_line_start: True, rev_buf: [" ", ..st.rev_buf]),
          )
        False -> {
          let decl = collapse_ws(syntax.rev_str(st.rev_buf))
          case decl {
            "" ->
              step_graphemes(
                rest,
                ExtractState(..st, at_line_start: True, rev_buf: []),
              )
            _ ->
              case should_continue_across_newline(decl) {
                True ->
                  step_graphemes(
                    rest,
                    ExtractState(..st, at_line_start: True, rev_buf: [
                      " ",
                      ..st.rev_buf
                    ]),
                  )
                False ->
                  step_graphemes(
                    rest,
                    ExtractState(
                      ..st,
                      at_line_start: True,
                      rev_buf: [],
                      rev_decls: [decl, ..st.rev_decls],
                    ),
                  )
              }
          }
        }
      }
  }
}

fn should_continue_across_newline(decl: String) -> Bool {
  let no_vis = strip_vis_prefix(decl)
  let no_async = case string.starts_with(no_vis, "async ") {
    True -> string.drop_start(no_vis, 6) |> string.trim_start
    False -> no_vis
  }
  let is_block_header =
    string.starts_with(no_async, "fn ")
    || string.starts_with(no_async, "fn[")
    || string.starts_with(no_async, "impl ")
    || string.starts_with(no_async, "impl[")
    || string.starts_with(no_async, "struct ")
    || string.starts_with(no_async, "enum ")
    || string.starts_with(no_async, "trait ")
  is_block_header && !has_top_level_equals(decl)
}

fn has_top_level_equals(s: String) -> Bool {
  has_top_level_equals_loop(string.to_graphemes(s), 0, 0, False, False)
}

fn has_top_level_equals_loop(
  chars: List(String),
  parens: Int,
  brackets: Int,
  in_str: Bool,
  escaped: Bool,
) -> Bool {
  case chars {
    [] -> False
    [c, ..rest] ->
      case in_str {
        True ->
          case escaped {
            True ->
              has_top_level_equals_loop(rest, parens, brackets, True, False)
            False ->
              case c {
                "\\" ->
                  has_top_level_equals_loop(rest, parens, brackets, True, True)
                "\"" ->
                  has_top_level_equals_loop(
                    rest,
                    parens,
                    brackets,
                    False,
                    False,
                  )
                _ ->
                  has_top_level_equals_loop(rest, parens, brackets, True, False)
              }
          }
        False ->
          case c {
            "\"" ->
              has_top_level_equals_loop(rest, parens, brackets, True, False)
            "(" ->
              has_top_level_equals_loop(
                rest,
                parens + 1,
                brackets,
                False,
                False,
              )
            ")" ->
              has_top_level_equals_loop(
                rest,
                int.max(0, parens - 1),
                brackets,
                False,
                False,
              )
            "[" ->
              has_top_level_equals_loop(
                rest,
                parens,
                brackets + 1,
                False,
                False,
              )
            "]" ->
              has_top_level_equals_loop(
                rest,
                parens,
                int.max(0, brackets - 1),
                False,
                False,
              )
            "=" if parens == 0 && brackets == 0 ->
              case rest {
                [">", ..] | ["=", ..] ->
                  has_top_level_equals_loop(
                    rest,
                    parens,
                    brackets,
                    False,
                    False,
                  )
                _ -> True
              }
            _ -> has_top_level_equals_loop(rest, parens, brackets, False, False)
          }
      }
  }
}

fn collapse_ws(raw: String) -> String {
  raw
  |> string.replace("\n", " ")
  |> string.replace("\t", " ")
  |> string.split(" ")
  |> list.filter(fn(part) { part != "" })
  |> string.join(" ")
}

fn strip_vis_prefix(decl: String) -> String {
  let prefixes = [
    "pub(all) ",
    "pub(open) ",
    "pub(readonly) ",
    "pub ",
    "priv ",
  ]
  case list.find(prefixes, fn(pfx) { string.starts_with(decl, pfx) }) {
    Ok(pfx) -> string.drop_start(decl, string.length(pfx)) |> string.trim_start
    Error(_) -> decl
  }
}

// -----------------------------------------------------------------------------
// Declaration parser (#derive, types, impl, pub fn)
// -----------------------------------------------------------------------------

fn process_top_decl(
  decl: String,
  pkg_name: String,
  meta: FfiMetadata,
  pending_derives: List(String),
  include_private_fns: Bool,
) -> #(FfiMetadata, List(String)) {
  case string.starts_with(decl, "#derive(") {
    True -> {
      let derived = parse_derive_attr(decl)
      #(meta, list.append(pending_derives, derived))
    }
    False ->
      case string.starts_with(decl, "#") || string.starts_with(decl, "@") {
        True -> #(meta, pending_derives)
        False -> {
          let after_vis = strip_vis_prefix(decl)
          case
            string.starts_with(after_vis, "struct ")
            || string.starts_with(after_vis, "enum ")
            || string.starts_with(after_vis, "type ")
            || string.starts_with(after_vis, "typealias ")
          {
            True -> #(
              parse_type_decl_traits(after_vis, pkg_name, pending_derives, meta),
              [],
            )
            False ->
              case
                string.starts_with(after_vis, "impl ")
                || string.starts_with(after_vis, "impl[")
              {
                True -> #(parse_impl_header(after_vis, pkg_name, meta), [])
                False -> {
                  let is_pub_fn =
                    string.starts_with(decl, "pub fn ")
                    || string.starts_with(decl, "pub fn[")
                    || string.starts_with(decl, "pub async fn ")
                    || string.starts_with(decl, "pub async fn[")
                  let is_any_fn =
                    string.starts_with(after_vis, "fn ")
                    || string.starts_with(after_vis, "fn[")
                    || string.starts_with(after_vis, "async fn ")
                    || string.starts_with(after_vis, "async fn[")
                  case is_pub_fn || { include_private_fns && is_any_fn } {
                    True -> #(parse_fn_header(after_vis, pkg_name, meta), [])
                    False -> #(meta, [])
                  }
                }
              }
          }
        }
      }
  }
}

fn parse_derive_attr(decl: String) -> List(String) {
  case string.split_once(decl, "(") {
    Error(_) -> []
    Ok(#(_, after)) ->
      case split_last_char(after, ")") {
        Error(_) -> []
        Ok(#(inner, _)) ->
          string.split(inner, ",")
          |> list.map(string.trim)
          |> list.filter(fn(t) { t != "" })
      }
  }
}

fn parse_type_decl_traits(
  after_vis: String,
  pkg_name: String,
  pending_derives: List(String),
  meta: FfiMetadata,
) -> FfiMetadata {
  let after_kw = case string.split_once(after_vis, " ") {
    Ok(#(_, rest)) -> string.trim_start(rest)
    Error(_) -> ""
  }
  let type_name = take_ident(after_kw)
  case type_name {
    "" -> meta
    _ -> {
      let traits =
        list.fold(pending_derives, empty_type_traits(), fn(acc, d) {
          case d {
            "Eq" -> ExternalTypeTraits(..acc, has_eq: True)
            "Debug" -> ExternalTypeTraits(..acc, has_debug: True)
            "Hash" -> ExternalTypeTraits(..acc, has_hash: True)
            _ -> acc
          }
        })
      merge_type_entry(meta, pkg_name, type_name, traits)
    }
  }
}

fn merge_type_entry(
  meta: FfiMetadata,
  pkg_name: String,
  type_name: String,
  traits: ExternalTypeTraits,
) -> FfiMetadata {
  let key = #(pkg_name, type_name)
  let existing = case dict.get(meta.types, key) {
    Ok(t) -> t
    Error(_) -> empty_type_traits()
  }
  let merged = merge_traits(existing, traits)
  let next_types = dict.insert(meta.types, key, merged)
  let next_types = case
    pkg_name == "gprelude" && dict.has_key(next_types, #("builtin", type_name))
  {
    True -> {
      let b_key = #("builtin", type_name)
      let e_key = #("", type_name)
      let b_prev =
        dict.get(next_types, b_key) |> result.unwrap(empty_type_traits())
      let e_prev =
        dict.get(next_types, e_key) |> result.unwrap(empty_type_traits())
      next_types
      |> dict.insert(b_key, merge_traits(b_prev, traits))
      |> dict.insert(e_key, merge_traits(e_prev, traits))
    }
    False -> next_types
  }
  FfiMetadata(..meta, types: next_types)
}

fn parse_impl_header(
  after_vis: String,
  pkg_name: String,
  meta: FfiMetadata,
) -> FfiMetadata {
  let after_impl = string.drop_start(after_vis, 4) |> string.trim_start
  let #(tp_bounds, after_tps) = case string.starts_with(after_impl, "[") {
    True ->
      case syntax.split_bracket_block(after_impl) {
        Some(#(tp_inner, rest)) -> #(
          parse_type_param_bounds(tp_inner) |> dict.from_list,
          string.trim_start(rest),
        )
        None -> #(dict.new(), after_impl)
      }
    False -> #(dict.new(), after_impl)
  }
  case string.split_once(after_tps, " for ") {
    Error(_) -> meta
    Ok(#(raw_trait, after_for)) -> {
      let clean_trait =
        raw_trait
        |> string.trim
        |> strip_bracket_suffix
        |> syntax.strip_pkg_qualifier
      let target_part = case string.split_once(after_for, " with ") {
        Ok(#(left, _)) -> string.trim(left)
        Error(_) -> string.trim(after_for)
      }
      case string.starts_with(target_part, "(") {
        True -> meta
        False -> {
          let #(raw_target_name, target_args) = case
            split_target_type_args(target_part)
          {
            Some(#(nm, args)) -> #(nm, args)
            None -> #(take_qualified_ident(target_part), [])
          }
          let target_name = syntax.strip_pkg_qualifier(raw_target_name)
          case target_name {
            "" -> meta
            _ -> {
              let hash_indices = case clean_trait == "Eq" {
                True ->
                  list.index_fold(target_args, set.new(), fn(acc, arg, idx) {
                    let arg_name = string.trim(arg)
                    case dict.get(tp_bounds, arg_name) {
                      Ok(bounds) ->
                        case set.contains(bounds, "Hash") {
                          True -> set.insert(acc, idx)
                          False -> acc
                        }
                      Error(_) -> acc
                    }
                  })
                False -> set.new()
              }
              let trait_update = case clean_trait {
                "Eq" ->
                  Some(ExternalTypeTraits(
                    has_eq: True,
                    has_debug: False,
                    has_hash: False,
                    has_inspect: False,
                    eq_requires_hash_params: hash_indices,
                  ))
                "Debug" ->
                  Some(ExternalTypeTraits(
                    has_eq: False,
                    has_debug: True,
                    has_hash: False,
                    has_inspect: False,
                    eq_requires_hash_params: set.new(),
                  ))
                "Hash" ->
                  Some(ExternalTypeTraits(
                    has_eq: False,
                    has_debug: False,
                    has_hash: True,
                    has_inspect: False,
                    eq_requires_hash_params: set.new(),
                  ))
                "GleamInspect" ->
                  Some(ExternalTypeTraits(
                    has_eq: False,
                    has_debug: False,
                    has_hash: False,
                    has_inspect: True,
                    eq_requires_hash_params: set.new(),
                  ))
                _ -> None
              }
              case trait_update {
                Some(upd) -> merge_type_entry(meta, pkg_name, target_name, upd)
                None -> meta
              }
            }
          }
        }
      }
    }
  }
}

fn parse_fn_header(
  after_vis: String,
  pkg_name: String,
  meta: FfiMetadata,
) -> FfiMetadata {
  let after_async = case string.starts_with(after_vis, "async ") {
    True -> string.drop_start(after_vis, 6) |> string.trim_start
    False -> after_vis
  }
  let after_fn = string.drop_start(after_async, 2) |> string.trim_start
  let #(tp_list, fn_name, after_name_and_tps) = case
    string.starts_with(after_fn, "[")
  {
    True ->
      case syntax.split_bracket_block(after_fn) {
        Some(#(tp_inner, rest)) -> {
          let rest_t = string.trim_start(rest)
          let #(nm, after_nm) = split_fn_name_and_rest(rest_t)
          #(parse_type_param_bounds(tp_inner), nm, after_nm)
        }
        None -> #([], "", "")
      }
    False -> {
      let #(nm, after_nm) = split_fn_name_and_rest(after_fn)
      case string.starts_with(after_nm, "[") {
        True ->
          case syntax.split_bracket_block(after_nm) {
            Some(#(tp_inner, rest)) -> #(
              parse_type_param_bounds(tp_inner),
              nm,
              string.trim_start(rest),
            )
            None -> #([], "", "")
          }
        False -> #([], nm, after_nm)
      }
    }
  }
  let has_any_bounds = list.any(tp_list, fn(pair) { !set.is_empty(pair.1) })
  case
    fn_name != ""
    && !string.contains(fn_name, "::")
    && has_any_bounds
    && string.starts_with(after_name_and_tps, "(")
  {
    False -> meta
    True ->
      case syntax.split_paren_block(after_name_and_tps) {
        None -> meta
        Some(#(params_inner, after_parens)) -> {
          let tp_names =
            list.map(tp_list, fn(pair) { pair.0 })
            |> set.from_list
          let param_chunks = syntax.split_top_level_commas(params_inner)
          let parsed_params =
            list.try_map(param_chunks, fn(chunk) {
              parse_fn_param_type(chunk, tp_names)
            })
          case parsed_params {
            Error(_) -> meta
            Ok(param_types) -> {
              let ret_ty = parse_fn_return_type(after_parens, tp_names)
              let fn_meta =
                ExternalFnMeta(
                  type_params: tp_list,
                  param_types:,
                  return_type: ret_ty,
                )
              FfiMetadata(
                ..meta,
                functions: dict.insert(
                  meta.functions,
                  #(pkg_name, fn_name),
                  fn_meta,
                ),
              )
            }
          }
        }
      }
  }
}

fn split_fn_name_and_rest(s: String) -> #(String, String) {
  let chars = string.to_graphemes(s)
  let #(rev_nm, rem) = take_fn_name_chars(chars, [])
  #(
    rev_nm |> list.reverse |> string.concat,
    string.concat(rem) |> string.trim_start,
  )
}

fn take_fn_name_chars(
  chars: List(String),
  acc: List(String),
) -> #(List(String), List(String)) {
  case chars {
    [] -> #(acc, [])
    [c, ..rest] ->
      case c {
        "(" | "[" | " " -> #(acc, chars)
        ":" ->
          case rest {
            [":", ..after_second] ->
              take_fn_name_chars(after_second, [":", ":", ..acc])
            _ -> #(acc, chars)
          }
        _ -> take_fn_name_chars(rest, [c, ..acc])
      }
  }
}

fn parse_fn_param_type(
  chunk: String,
  tp_names: Set(String),
) -> Result(MbtType, Nil) {
  case syntax.split_top_level_once(chunk, ":") {
    Error(_) -> Error(Nil)
    Ok(#(_, after_colon)) -> {
      let clean_ty = case syntax.split_top_level_once(after_colon, "=") {
        Ok(#(ty_only, _)) -> ty_only
        Error(_) -> after_colon
      }
      Ok(parse_mbt_type(clean_ty, tp_names))
    }
  }
}

fn parse_fn_return_type(
  after_parens: String,
  tp_names: Set(String),
) -> Option(MbtType) {
  let trimmed = string.trim(after_parens)
  case string.starts_with(trimmed, "->") {
    False -> None
    True -> {
      let after_arrow = string.drop_start(trimmed, 2) |> string.trim
      let clean_ret =
        after_arrow
        |> strip_trailing_clause(" raise")
        |> strip_trailing_clause(" noraise")
        |> strip_trailing_equals_clause
        |> string.trim
      case clean_ret {
        "" -> None
        _ -> Some(parse_mbt_type(clean_ret, tp_names))
      }
    }
  }
}

fn strip_trailing_clause(s: String, marker: String) -> String {
  case syntax.split_top_level_once(s, marker) {
    Ok(#(left, _)) -> left
    Error(_) -> s
  }
}

fn strip_trailing_equals_clause(s: String) -> String {
  case syntax.split_top_level_once(s, "=") {
    Ok(#(left, _)) -> left
    Error(_) -> s
  }
}

fn parse_type_param_bounds(tp_inner: String) -> List(#(String, Set(String))) {
  syntax.split_top_level_commas(tp_inner)
  |> list.filter_map(fn(entry) {
    let trimmed = string.trim(entry)
    case trimmed {
      "" -> Error(Nil)
      _ ->
        case string.split_once(trimmed, ":") {
          Ok(#(raw_name, raw_bounds)) -> {
            let bounds =
              string.split(raw_bounds, "+")
              |> list.map(fn(b) { syntax.strip_pkg_qualifier(string.trim(b)) })
              |> list.filter(fn(b) { b != "" })
              |> set.from_list
            Ok(#(string.trim(raw_name), bounds))
          }
          Error(_) -> Ok(#(trimmed, set.new()))
        }
    }
  })
}

/// Parse a MoonBit type expression into `MbtType`.
pub fn parse_mbt_type(raw: String, tp_names: Set(String)) -> MbtType {
  let trimmed = string.trim(raw)
  case syntax.split_top_level_once(trimmed, "->") {
    Ok(#(left_raw, right_raw)) -> {
      let left = string.trim(left_raw)
      let param_inner = case syntax.is_outer_paren_wrapped(left) {
        True ->
          left
          |> string.drop_start(1)
          |> string.drop_end(1)
        False -> left
      }
      let params =
        syntax.split_top_level_commas(param_inner)
        |> list.map(parse_mbt_type(_, tp_names))
      let ret = parse_mbt_type(right_raw, tp_names)
      MbtFn(params:, return_type: ret)
    }
    Error(_) ->
      case string.ends_with(trimmed, "?") {
        True -> {
          let inner = string.drop_end(trimmed, 1) |> parse_mbt_type(tp_names)
          MbtNamed(name: "Option", args: [inner])
        }
        False ->
          case syntax.is_outer_paren_wrapped(trimmed) {
            True -> {
              let inner =
                trimmed
                |> string.drop_start(1)
                |> string.drop_end(1)
                |> string.trim
              let items = syntax.split_top_level_commas(inner)
              case items {
                [] -> MbtNamed(name: "Unit", args: [])
                [single] -> parse_mbt_type(single, tp_names)
                many -> MbtTuple(list.map(many, parse_mbt_type(_, tp_names)))
              }
            }
            False ->
              case split_target_type_args(trimmed) {
                Some(#(raw_name, raw_args)) -> {
                  let clean_name = syntax.strip_pkg_qualifier(raw_name)
                  let args = list.map(raw_args, parse_mbt_type(_, tp_names))
                  MbtNamed(name: clean_name, args:)
                }
                None ->
                  case set.contains(tp_names, trimmed) {
                    True -> MbtVar(trimmed)
                    False ->
                      MbtNamed(
                        name: syntax.strip_pkg_qualifier(trimmed),
                        args: [],
                      )
                  }
              }
          }
      }
  }
}

fn split_target_type_args(s: String) -> Option(#(String, List(String))) {
  let trimmed = string.trim(s)
  case string.ends_with(trimmed, "]") {
    False -> None
    True ->
      case string.split_once(trimmed, "[") {
        Error(_) -> None
        Ok(#(name_part, rest_with_close)) -> {
          let inner = string.drop_end(rest_with_close, 1)
          Some(#(string.trim(name_part), syntax.split_top_level_commas(inner)))
        }
      }
  }
}

fn strip_bracket_suffix(s: String) -> String {
  case string.split_once(s, "[") {
    Ok(#(head, _)) -> string.trim(head)
    Error(_) -> s
  }
}

fn take_ident(s: String) -> String {
  take_chars_while(string.to_graphemes(string.trim_start(s)), fn(c) {
    c != " " && c != "[" && c != "(" && c != "=" && c != ":" && c != "{"
  })
}

fn take_qualified_ident(s: String) -> String {
  take_chars_while(string.to_graphemes(string.trim_start(s)), fn(c) {
    c != " " && c != "[" && c != "(" && c != "{"
  })
}

fn take_chars_while(chars: List(String), pred: fn(String) -> Bool) -> String {
  take_chars_while_loop(chars, pred, [])
}

fn take_chars_while_loop(
  chars: List(String),
  pred: fn(String) -> Bool,
  acc: List(String),
) -> String {
  case chars {
    [] -> syntax.rev_str(acc)
    [c, ..rest] ->
      case pred(c) {
        True -> take_chars_while_loop(rest, pred, [c, ..acc])
        False -> syntax.rev_str(acc)
      }
  }
}

fn split_last_char(
  s: String,
  target: String,
) -> Result(#(String, String), Nil) {
  let rev_chars = string.to_graphemes(s) |> list.reverse
  case split_last_loop(rev_chars, target, []) {
    Error(Nil) -> Error(Nil)
    Ok(#(rev_before, after_rev)) ->
      Ok(#(
        rev_before |> list.reverse |> string.concat,
        string.concat(after_rev),
      ))
  }
}

fn split_last_loop(
  rev_chars: List(String),
  target: String,
  after_acc: List(String),
) -> Result(#(List(String), List(String)), Nil) {
  case rev_chars {
    [] -> Error(Nil)
    [c, ..rest] ->
      case c == target {
        True -> Ok(#(rest, after_acc))
        False -> split_last_loop(rest, target, [c, ..after_acc])
      }
  }
}
