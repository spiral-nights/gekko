import filepath
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import project/patch_discovery
import project/prepass.{
  type ExternalType, type FfiKind, type TargetBranch, ExternalType, PackageCall,
  Patched, PreferErlang, PreferJavascript, WasmImport,
}
import simplifile
import tom.{type Toml}

/// Metadata declared in `[tools.gekko.shim_for]` identifying the target package and SemVer range.
pub type ShimMeta {
  ShimMeta(target: String, version: Option(String))
}

/// A MoonBit source file patched directly into a transpiled module's package.
pub type ModulePatchFile {
  ModulePatchFile(
    source_path: String,
    dest_filename: String,
    source_pkg: String,
  )
}

/// An extra MoonBit package import required by a module's patch files.
pub type ModulePatchImport {
  ModulePatchImport(package: String, alias: Option(String))
}

/// Co-located MoonBit patch configuration for a single target Gleam module.
pub type ModulePatch {
  ModulePatch(
    files: List(ModulePatchFile),
    imports: List(ModulePatchImport),
    types: List(String),
    type_aliases: List(#(String, ExternalType)),
    functions: List(String),
  )
}

/// Complete overlay configuration loaded from a single package (`gleam.toml` + `gekko.toml`).
pub type PackageOverlay {
  PackageOverlay(
    source_pkg: String,
    shim: Option(ShimMeta),
    authorized_shims: Dict(String, String),
    overrides: Dict(String, FfiKind),
    type_overrides: Dict(String, ExternalType),
    module_patches: Dict(String, ModulePatch),
    target_branches: Dict(String, TargetBranch),
  )
}

/// Merged overlay configuration across all dependency shims and the root project.
pub type MergedOverlays {
  MergedOverlays(
    shims: List(#(String, ShimMeta)),
    authorized_shims: Dict(String, String),
    overrides: Dict(String, FfiKind),
    override_sources: Dict(String, String),
    type_overrides: Dict(String, ExternalType),
    type_override_sources: Dict(String, String),
    module_patches: Dict(String, ModulePatch),
    module_patch_sources: Dict(String, String),
    target_branches: Dict(String, TargetBranch),
    patched_source_files: Set(String),
  )
}

/// Parse FFI overrides from a `gekko.toml` file string (`[overrides."..."]`).
pub fn parse_gekko_toml(
  content: String,
) -> Result(Dict(String, FfiKind), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  case tom.get_table(parsed, ["overrides"]) {
    Ok(table) -> collect_overrides(table, [])
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(err) -> Error(format_get_error(err))
  }
}

/// Parse FFI overrides from a `gleam.toml` file string (`[tools.gekko.overrides."..."]`).
pub fn parse_gleam_toml_overrides(
  content: String,
) -> Result(Dict(String, FfiKind), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  case tom.get_table(parsed, ["tools", "gekko", "overrides"]) {
    Ok(table) -> collect_overrides(table, [])
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(err) -> Error(format_get_error(err))
  }
}

/// Load and merge FFI overrides from `<project_root>/gleam.toml` (`[tools.gekko.overrides]`)
/// and `<project_root>/gekko.toml` (`[overrides]`), with `gekko.toml` taking precedence.
pub fn load_project_overrides(
  project_root: String,
) -> Result(Dict(String, FfiKind), String) {
  use #(from_gleam, from_gekko) <- result.try(load_toml_pair(
    project_root,
    dict.new(),
    parse_gleam_toml_overrides,
    parse_gekko_toml,
  ))
  Ok(dict.merge(from_gleam, from_gekko))
}

/// Parse MoonBit third-party dependencies from `gekko.toml` (`[moonbit.deps]`).
pub fn parse_moonbit_deps_gekko_toml(
  content: String,
) -> Result(List(#(String, String)), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  use dep_map <- result.try(extract_string_table(parsed, ["moonbit", "deps"]))
  Ok(sort_dep_pairs(dep_map))
}

/// Parse MoonBit third-party dependencies from `gleam.toml`
/// (`[tools.gekko.moonbit.deps]` or `[gekko.moonbit.deps]`).
pub fn parse_moonbit_deps_gleam_toml(
  content: String,
) -> Result(List(#(String, String)), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  use tools_map <- result.try(
    extract_string_table(parsed, ["tools", "gekko", "moonbit", "deps"]),
  )
  use gekko_map <- result.try(
    extract_string_table(parsed, ["gekko", "moonbit", "deps"]),
  )
  Ok(sort_dep_pairs(dict.merge(tools_map, gekko_map)))
}

/// Load and merge MoonBit dependencies from `<project_root>/gleam.toml`,
/// `<project_root>/gekko.toml`, and `<project_root>/moonbit/moon.mod`, with
/// `moonbit/moon.mod` taking highest precedence.
pub fn load_project_moonbit_deps(
  project_root: String,
) -> Result(List(#(String, String)), String) {
  use #(from_gleam, from_gekko) <- result.try(load_toml_pair(
    project_root,
    [],
    parse_moonbit_deps_gleam_toml,
    parse_moonbit_deps_gekko_toml,
  ))
  let moon_mod_path = filepath.join(project_root, "moonbit/moon.mod")
  use from_moon_mod <- result.try(case simplifile.read(moon_mod_path) {
    Ok(content) -> parse_moon_mod_deps(content)
    Error(simplifile.Enoent) -> Ok([])
    Error(err) ->
      Error(
        "Failed to read "
        <> moon_mod_path
        <> ": "
        <> simplifile.describe_error(err),
      )
  })
  let insert_all = fn(acc, pairs) {
    list.fold(pairs, acc, fn(d, p) {
      let #(k, v) = p
      dict.insert(d, k, v)
    })
  }
  dict.new()
  |> insert_all(from_gleam)
  |> insert_all(from_gekko)
  |> insert_all(from_moon_mod)
  |> dict.delete("gekko/gprelude")
  |> sort_dep_pairs
  |> Ok
}

/// Parse MoonBit third-party dependencies from the `import { ... }` block of
/// a native `moon.mod` file (such as `<project_root>/moonbit/moon.mod`).
pub fn parse_moon_mod_deps(
  content: String,
) -> Result(List(#(String, String)), String) {
  let stripped = strip_line_comments(content)
  use import_bodies <- result.try(
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
  use dep_map <- result.try(
    list.try_fold(import_bodies, dict.new(), fn(acc, body) {
      parse_import_block_entries(body, acc)
    }),
  )
  Ok(sort_dep_pairs(dep_map))
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
        True -> Error("Unclosed import block in moon.mod")
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

fn parse_import_block_entries(
  body: String,
  acc: Dict(String, String),
) -> Result(Dict(String, String), String) {
  let items =
    body
    |> string.replace("\n", ",")
    |> string.split(",")
  list.try_fold(items, acc, fn(d, raw_item) {
    let item = string.trim(raw_item)
    case item {
      "" -> Ok(d)
      _ -> {
        use #(pkg, ver) <- result.try(parse_moon_mod_dep_item(item))
        Ok(dict.insert(d, pkg, ver))
      }
    }
  })
}

fn parse_moon_mod_dep_item(item: String) -> Result(#(String, String), String) {
  case string.starts_with(item, "\"") {
    False -> Error("Invalid dependency entry in moon.mod: " <> item)
    True -> {
      let after_open = string.drop_start(item, 1)
      case string.split_once(after_open, "\"") {
        Error(_) -> Error("Invalid dependency entry in moon.mod: " <> item)
        Ok(#("", _)) -> Error("Invalid dependency entry in moon.mod: " <> item)
        Ok(#(spec, after_close)) -> {
          let rest = string.trim(after_close)
          let valid_trailing =
            rest == ""
            || string.starts_with(rest, "as ")
            || string.starts_with(rest, "as\t")
          case valid_trailing {
            False -> Error("Invalid dependency entry in moon.mod: " <> item)
            True ->
              case string.split_once(spec, "@") {
                Ok(#("", _)) ->
                  Error("Invalid dependency entry in moon.mod: " <> item)
                Ok(#(pkg, ver)) -> Ok(#(pkg, ver))
                Error(_) -> Ok(#(spec, ""))
              }
          }
        }
      }
    }
  }
}

fn is_ident_char(ch: String) -> Bool {
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

fn is_whitespace_char(ch: String) -> Bool {
  case ch {
    " " | "\t" | "\n" | "\r" -> True
    _ -> False
  }
}

fn load_toml_pair(
  project_root: String,
  empty: a,
  parse_gleam: fn(String) -> Result(a, String),
  parse_gekko: fn(String) -> Result(a, String),
) -> Result(#(a, a), String) {
  let gleam_toml_path = filepath.join(project_root, "gleam.toml")
  let gekko_toml_path = filepath.join(project_root, "gekko.toml")

  use from_gleam <- result.try(case simplifile.read(gleam_toml_path) {
    Ok(content) -> parse_gleam(content)
    Error(simplifile.Enoent) -> Ok(empty)
    Error(err) ->
      Error(
        "Failed to read "
        <> gleam_toml_path
        <> ": "
        <> simplifile.describe_error(err),
      )
  })

  use from_gekko <- result.try(case simplifile.read(gekko_toml_path) {
    Ok(content) -> parse_gekko(content)
    Error(simplifile.Enoent) -> Ok(empty)
    Error(err) ->
      Error(
        "Failed to read "
        <> gekko_toml_path
        <> ": "
        <> simplifile.describe_error(err),
      )
  })

  Ok(#(from_gleam, from_gekko))
}

fn extract_string_table(
  parsed: Dict(String, Toml),
  key_path: List(String),
) -> Result(Dict(String, String), String) {
  case tom.get_table(parsed, key_path) {
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(err) -> Error(format_get_error(err))
    Ok(table) ->
      dict.to_list(table)
      |> list.try_fold(dict.new(), fn(acc, entry) {
        let #(pkg, val) = entry
        case val {
          tom.String(ver) -> Ok(dict.insert(acc, pkg, ver))
          _ ->
            Error("MoonBit dependency '" <> pkg <> "' version must be a string")
        }
      })
  }
}

fn sort_dep_pairs(deps: Dict(String, String)) -> List(#(String, String)) {
  deps
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

fn collect_overrides(
  table: Dict(String, Toml),
  prefix: List(String),
) -> Result(Dict(String, FfiKind), String) {
  dict.to_list(table)
  |> list.try_fold(dict.new(), fn(acc, entry) {
    let #(key, value) = entry
    case value {
      tom.Table(sub) | tom.InlineTable(sub) ->
        case extract_ffi_kind(sub, [key, ..prefix]) {
          Ok(Some(kind)) -> {
            let full_key =
              [key, ..prefix]
              |> list.reverse
              |> string.join(".")
            Ok(dict.insert(acc, full_key, kind))
          }
          Ok(None) -> {
            use nested <- result.try(collect_overrides(sub, [key, ..prefix]))
            Ok(dict.merge(acc, nested))
          }
          Error(msg) -> Error(msg)
        }
      _ -> {
        let full_key =
          [key, ..prefix]
          |> list.reverse
          |> string.join(".")
        Error("Expected table for override key '" <> full_key <> "'")
      }
    }
  })
}

fn extract_ffi_kind(
  table: Dict(String, Toml),
  rev_key_parts: List(String),
) -> Result(Option(FfiKind), String) {
  let key_name =
    rev_key_parts
    |> list.reverse
    |> string.join(".")

  case dict.get(table, "package"), dict.get(table, "wasm_module") {
    Ok(tom.String(pkg)), Error(_) ->
      case dict.get(table, "function") {
        Ok(tom.String(func)) ->
          Ok(Some(PackageCall(package: pkg, function: func)))
        Ok(_) ->
          Error("Override '" <> key_name <> "' field 'function' must be String")
        Error(_) ->
          Error(
            "Override '"
            <> key_name
            <> "' with 'package' must also specify 'function'",
          )
      }

    Error(_), Ok(tom.String(wasm_mod)) ->
      case dict.get(table, "import_name") {
        Ok(tom.String(imp)) ->
          Ok(Some(WasmImport(wasm_module: wasm_mod, import_name: imp)))
        Ok(_) ->
          Error(
            "Override '" <> key_name <> "' field 'import_name' must be String",
          )
        Error(_) ->
          Error(
            "Override '"
            <> key_name
            <> "' with 'wasm_module' must also specify 'import_name'",
          )
      }

    Ok(_), Ok(_) ->
      Error(
        "Override '"
        <> key_name
        <> "' cannot specify both 'package' and 'wasm_module'",
      )

    Ok(_), Error(_) ->
      Error("Override '" <> key_name <> "' field 'package' must be String")

    Error(_), Ok(_) ->
      Error("Override '" <> key_name <> "' field 'wasm_module' must be String")

    Error(_), Error(_) ->
      case dict.get(table, "function"), dict.get(table, "import_name") {
        Ok(_), _ ->
          Error(
            "Override '"
            <> key_name
            <> "' specifies 'function' without 'package'",
          )
        _, Ok(_) ->
          Error(
            "Override '"
            <> key_name
            <> "' specifies 'import_name' without 'wasm_module'",
          )
        Error(_), Error(_) -> Ok(None)
      }
  }
}

fn format_parse_error(err: tom.ParseError) -> String {
  case err {
    tom.Unexpected(got:, expected:) ->
      "TOML parse error: unexpected " <> got <> ", expected " <> expected
    tom.KeyAlreadyInUse(key:) ->
      "TOML parse error: duplicate key '" <> string.join(key, ".") <> "'"
  }
}

fn format_get_error(err: tom.GetError) -> String {
  case err {
    tom.NotFound(key:) -> "TOML missing key '" <> string.join(key, ".") <> "'"
    tom.WrongType(key:, expected:, got:) ->
      "TOML type error at '"
      <> string.join(key, ".")
      <> "': expected "
      <> expected
      <> ", got "
      <> got
  }
}

// -----------------------------------------------------------------------------
// Overlay & Shim Parsers (`[shim]`, `[type_overrides]`, `[module_inject]`, `[target_branch]`)
// -----------------------------------------------------------------------------

/// Parse `[shim_for]` metadata from a `gekko.toml` string.
pub fn parse_shim_gekko_toml(
  content: String,
) -> Result(Option(ShimMeta), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  extract_shim_meta(parsed, ["shim_for"])
}

/// Parse `[tools.gekko.shim_for]` metadata from a `gleam.toml` string.
pub fn parse_shim_gleam_toml(
  content: String,
) -> Result(Option(ShimMeta), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  extract_shim_meta(parsed, ["tools", "gekko", "shim_for"])
}

fn extract_shim_meta(
  parsed: Dict(String, Toml),
  key_path: List(String),
) -> Result(Option(ShimMeta), String) {
  case tom.get_table(parsed, key_path) {
    Error(tom.NotFound(_)) -> Ok(None)
    Error(err) -> Error(format_get_error(err))
    Ok(table) -> {
      use target <- result.try(case dict.get(table, "package") {
        Ok(tom.String(t)) ->
          case string.trim(t) {
            "" -> Error("Shim 'package' must not be empty")
            trimmed -> Ok(trimmed)
          }
        Ok(_) -> Error("Shim 'package' must be String")
        Error(_) -> Error("[tools.gekko.shim_for] must specify 'package'")
      })
      use version <- result.try(case dict.get(table, "version") {
        Error(_) -> Ok(None)
        Ok(tom.String(v)) -> {
          use _ <- result.try(parse_version_constraint(v))
          Ok(Some(v))
        }
        Ok(_) -> Error("Shim 'version' must be String")
      })
      Ok(Some(ShimMeta(target:, version:)))
    }
  }
}

/// Parse `[type_overrides."..."]` from a `gekko.toml` string.
pub fn parse_type_overrides_gekko_toml(
  content: String,
) -> Result(Dict(String, ExternalType), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  case tom.get_table(parsed, ["type_overrides"]) {
    Ok(table) -> collect_nested_entries(table, [], extract_type_override)
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(err) -> Error(format_get_error(err))
  }
}

/// Parse `[tools.gekko.type_overrides."..."]` from a `gleam.toml` string.
pub fn parse_type_overrides_gleam_toml(
  content: String,
) -> Result(Dict(String, ExternalType), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  case tom.get_table(parsed, ["tools", "gekko", "type_overrides"]) {
    Ok(table) -> collect_nested_entries(table, [], extract_type_override)
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(err) -> Error(format_get_error(err))
  }
}

fn extract_type_override(
  table: Dict(String, Toml),
  rev_key_parts: List(String),
) -> Result(Option(ExternalType), String) {
  let key_name = rev_key_parts |> list.reverse |> string.join(".")
  case dict.get(table, "package"), dict.get(table, "type") {
    Ok(tom.String(pkg)), Ok(tom.String(ty)) ->
      case string.trim(ty) {
        "" ->
          Error(
            "Type override '" <> key_name <> "' field 'type' must not be empty",
          )
        _ -> Ok(Some(ExternalType(package: pkg, type_name: ty)))
      }
    Ok(tom.String(_)), Ok(_) ->
      Error("Type override '" <> key_name <> "' field 'type' must be String")
    Ok(tom.String(_)), Error(_) ->
      Error(
        "Type override '"
        <> key_name
        <> "' with 'package' must also specify 'type'",
      )
    Ok(_), _ ->
      Error("Type override '" <> key_name <> "' field 'package' must be String")
    Error(_), Ok(_) ->
      Error(
        "Type override '" <> key_name <> "' specifies 'type' without 'package'",
      )
    Error(_), Error(_) -> Ok(None)
  }
}

/// Parse `[patch."..."]` from a `gekko.toml` string.
pub fn parse_module_patch_gekko_toml(
  content: String,
) -> Result(Dict(String, ModulePatch), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  case tom.get_table(parsed, ["patch"]) {
    Ok(table) -> collect_nested_entries(table, [], extract_module_patch)
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(err) -> Error(format_get_error(err))
  }
}

/// Parse `[tools.gekko.patch."..."]` from a `gleam.toml` string.
pub fn parse_module_patch_gleam_toml(
  content: String,
) -> Result(Dict(String, ModulePatch), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  case tom.get_table(parsed, ["tools", "gekko", "patch"]) {
    Ok(table) -> collect_nested_entries(table, [], extract_module_patch)
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(err) -> Error(format_get_error(err))
  }
}

fn extract_module_patch(
  table: Dict(String, Toml),
  rev_key_parts: List(String),
) -> Result(Option(ModulePatch), String) {
  let key_name = rev_key_parts |> list.reverse |> string.join(".")
  let has_file = dict.has_key(table, "file")
  let has_files = dict.has_key(table, "files")
  let has_imports = dict.has_key(table, "imports")
  let has_types = dict.has_key(table, "types")
  let has_fns = dict.has_key(table, "functions")
  case has_file || has_files || has_imports || has_types || has_fns {
    False -> Ok(None)
    True -> {
      use files <- result.try(
        case dict.get(table, "file"), dict.get(table, "files") {
          Ok(_), Ok(_) ->
            Error(
              "Patch '"
              <> key_name
              <> "' cannot specify both 'file' and 'files'",
            )
          Ok(tom.String(path)), Error(_) ->
            case string.trim(path) {
              "" -> Error("Patch '" <> key_name <> "' 'file' must not be empty")
              p ->
                Ok([
                  ModulePatchFile(
                    source_path: p,
                    dest_filename: filepath.base_name(p),
                    source_pkg: "",
                  ),
                ])
            }
          Ok(_), Error(_) ->
            Error("Patch '" <> key_name <> "' field 'file' must be String")
          Error(_), Ok(tom.Array(items)) ->
            list.try_map(items, fn(item) {
              case item {
                tom.String(path) ->
                  case string.trim(path) {
                    "" ->
                      Error(
                        "Patch '"
                        <> key_name
                        <> "' 'files' entries must not be empty",
                      )
                    p ->
                      Ok(ModulePatchFile(
                        source_path: p,
                        dest_filename: filepath.base_name(p),
                        source_pkg: "",
                      ))
                  }
                _ ->
                  Error(
                    "Patch '"
                    <> key_name
                    <> "' field 'files' must be an array of Strings",
                  )
              }
            })
          Error(_), Ok(_) ->
            Error(
              "Patch '"
              <> key_name
              <> "' field 'files' must be an array of Strings",
            )
          Error(_), Error(_) ->
            Error("Patch '" <> key_name <> "' must specify 'file' or 'files'")
        },
      )
      case files {
        [] -> Error("Patch '" <> key_name <> "' must specify at least one file")
        _ -> {
          use imports <- result.try(case dict.get(table, "imports") {
            Error(_) -> Ok([])
            Ok(tom.Array(items)) ->
              list.try_map(items, fn(item) {
                case item {
                  tom.String(spec) -> parse_patch_import_spec(spec, key_name)
                  _ ->
                    Error(
                      "Patch '"
                      <> key_name
                      <> "' field 'imports' must be an array of Strings",
                    )
                }
              })
            Ok(_) ->
              Error(
                "Patch '"
                <> key_name
                <> "' field 'imports' must be an array of Strings",
              )
          })
          use types <- result.try(extract_string_array(table, "types", key_name))
          use functions <- result.try(extract_string_array(
            table,
            "functions",
            key_name,
          ))
          Ok(
            Some(ModulePatch(
              files:,
              imports:,
              types:,
              type_aliases: [],
              functions:,
            )),
          )
        }
      }
    }
  }
}

fn extract_string_array(
  table: Dict(String, Toml),
  field: String,
  key_name: String,
) -> Result(List(String), String) {
  case dict.get(table, field) {
    Error(_) -> Ok([])
    Ok(tom.Array(items)) ->
      list.try_map(items, fn(item) {
        case item {
          tom.String(s) ->
            case string.trim(s) {
              "" ->
                Error(
                  "Patch '"
                  <> key_name
                  <> "' '"
                  <> field
                  <> "' entries must not be empty",
                )
              trimmed -> Ok(trimmed)
            }
          _ ->
            Error(
              "Patch '"
              <> key_name
              <> "' field '"
              <> field
              <> "' must be an array of Strings",
            )
        }
      })
    Ok(_) ->
      Error(
        "Patch '"
        <> key_name
        <> "' field '"
        <> field
        <> "' must be an array of Strings",
      )
  }
}

fn parse_patch_import_spec(
  raw: String,
  key_name: String,
) -> Result(ModulePatchImport, String) {
  let trimmed = string.trim(raw)
  case trimmed {
    "" ->
      Error("Patch '" <> key_name <> "' 'imports' entries must not be empty")
    _ ->
      case string.split_once(trimmed, " @") {
        Ok(#(pkg, alias)) ->
          validate_patch_import(pkg, Some(alias), key_name, raw)
        Error(_) ->
          case string.split_once(trimmed, " as ") {
            Ok(#(pkg, alias)) ->
              validate_patch_import(pkg, Some(alias), key_name, raw)
            Error(_) -> Ok(ModulePatchImport(package: trimmed, alias: None))
          }
      }
  }
}

fn validate_patch_import(
  pkg: String,
  alias: Option(String),
  key_name: String,
  raw: String,
) -> Result(ModulePatchImport, String) {
  let p = string.trim(pkg)
  let a = option.map(alias, string.trim)
  case p, a {
    "", _ | _, Some("") ->
      Error(
        "Invalid import specification '"
        <> raw
        <> "' in patch '"
        <> key_name
        <> "'",
      )
    _, _ -> Ok(ModulePatchImport(package: p, alias: a))
  }
}

/// Parse `[target_branch."..."]` from a `gekko.toml` string.
pub fn parse_target_branch_gekko_toml(
  content: String,
) -> Result(Dict(String, TargetBranch), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  case tom.get_table(parsed, ["target_branch"]) {
    Ok(table) -> collect_nested_entries(table, [], extract_target_branch)
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(err) -> Error(format_get_error(err))
  }
}

/// Parse `[tools.gekko.target_branch."..."]` from a `gleam.toml` string.
pub fn parse_target_branch_gleam_toml(
  content: String,
) -> Result(Dict(String, TargetBranch), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  case tom.get_table(parsed, ["tools", "gekko", "target_branch"]) {
    Ok(table) -> collect_nested_entries(table, [], extract_target_branch)
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(err) -> Error(format_get_error(err))
  }
}

fn extract_target_branch(
  table: Dict(String, Toml),
  rev_key_parts: List(String),
) -> Result(Option(TargetBranch), String) {
  let key_name = rev_key_parts |> list.reverse |> string.join(".")
  case dict.get(table, "prefer") {
    Error(_) -> Ok(None)
    Ok(tom.String("erlang")) -> Ok(Some(PreferErlang))
    Ok(tom.String("javascript")) -> Ok(Some(PreferJavascript))
    Ok(tom.String(other)) ->
      Error(
        "Target branch '"
        <> key_name
        <> "' field 'prefer' must be 'erlang' or 'javascript', got '"
        <> other
        <> "'",
      )
    Ok(_) ->
      Error("Target branch '" <> key_name <> "' field 'prefer' must be String")
  }
}

fn collect_nested_entries(
  table: Dict(String, Toml),
  prefix: List(String),
  extractor: fn(Dict(String, Toml), List(String)) -> Result(Option(a), String),
) -> Result(Dict(String, a), String) {
  dict.to_list(table)
  |> list.try_fold(dict.new(), fn(acc, entry) {
    let #(key, value) = entry
    case value {
      tom.Table(sub) | tom.InlineTable(sub) ->
        case extractor(sub, [key, ..prefix]) {
          Ok(Some(item)) -> {
            let full_key = [key, ..prefix] |> list.reverse |> string.join(".")
            Ok(dict.insert(acc, full_key, item))
          }
          Ok(None) -> {
            use nested <- result.try(collect_nested_entries(
              sub,
              [key, ..prefix],
              extractor,
            ))
            Ok(dict.merge(acc, nested))
          }
          Error(msg) -> Error(msg)
        }
      _ -> {
        let full_key = [key, ..prefix] |> list.reverse |> string.join(".")
        Error("Expected table for overlay key '" <> full_key <> "'")
      }
    }
  })
}

/// Parse `[use_shims]` authorization allowlist from a `gekko.toml` string.
pub fn parse_authorized_shims_gekko_toml(
  content: String,
) -> Result(Dict(String, String), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  extract_authorized_shims(parsed, ["use_shims"])
}

/// Parse `[tools.gekko.use_shims]` authorization allowlist from a `gleam.toml` string.
pub fn parse_authorized_shims_gleam_toml(
  content: String,
) -> Result(Dict(String, String), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  extract_authorized_shims(parsed, ["tools", "gekko", "use_shims"])
}

fn extract_authorized_shims(
  parsed: Dict(String, Toml),
  key_path: List(String),
) -> Result(Dict(String, String), String) {
  case tom.get_table(parsed, key_path) {
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(err) -> Error(format_get_error(err))
    Ok(table) ->
      dict.to_list(table)
      |> list.try_fold(dict.new(), fn(acc, entry) {
        let #(target_pkg, val) = entry
        case val {
          tom.String(shim_pkg) ->
            case string.trim(shim_pkg) {
              "" ->
                Error(
                  "Shim authorization for '"
                  <> target_pkg
                  <> "' must not be empty",
                )
              trimmed -> Ok(dict.insert(acc, target_pkg, trimmed))
            }
          _ ->
            Error(
              "Shim authorization for '"
              <> target_pkg
              <> "' must be a String (shim package name)",
            )
        }
      })
  }
}

/// Load and merge all overlay sections (`shim_for`, `use_shims`, `overrides`, `type_overrides`,
/// `patch`, `target_branch`) from a package's `gleam.toml` and `gekko.toml`.
pub fn load_package_overlay(
  pkg_root: String,
  pkg_name: String,
) -> Result(PackageOverlay, String) {
  use #(shim_g, shim_k) <- result.try(load_toml_pair(
    pkg_root,
    None,
    parse_shim_gleam_toml,
    parse_shim_gekko_toml,
  ))
  use #(auth_g, auth_k) <- result.try(load_toml_pair(
    pkg_root,
    dict.new(),
    parse_authorized_shims_gleam_toml,
    parse_authorized_shims_gekko_toml,
  ))
  use #(ovr_g, ovr_k) <- result.try(load_toml_pair(
    pkg_root,
    dict.new(),
    parse_gleam_toml_overrides,
    parse_gekko_toml,
  ))
  use #(ty_g, ty_k) <- result.try(load_toml_pair(
    pkg_root,
    dict.new(),
    parse_type_overrides_gleam_toml,
    parse_type_overrides_gekko_toml,
  ))
  use #(pat_g, pat_k) <- result.try(load_toml_pair(
    pkg_root,
    dict.new(),
    parse_module_patch_gleam_toml,
    parse_module_patch_gekko_toml,
  ))
  use #(br_g, br_k) <- result.try(load_toml_pair(
    pkg_root,
    dict.new(),
    parse_target_branch_gleam_toml,
    parse_target_branch_gekko_toml,
  ))

  let shim = case shim_k {
    Some(_) -> shim_k
    None -> shim_g
  }
  let authorized_shims = dict.merge(auth_g, auth_k)
  let explicit_overrides = dict.merge(ovr_g, ovr_k)
  let explicit_type_overrides = dict.merge(ty_g, ty_k)
  let target_branches = dict.merge(br_g, br_k)
  let raw_patches = merge_module_patch_dicts(pat_g, pat_k)
  use resolved_toml_patches <- result.try(resolve_module_patch_files(
    pkg_root,
    pkg_name,
    raw_patches,
  ))
  let toml_patched_paths =
    dict.fold(resolved_toml_patches, set.new(), fn(acc, _k, patch) {
      list.fold(patch.files, acc, fn(s, f) { set.insert(s, f.source_path) })
    })
  let target_pkg = option.map(shim, fn(s) { s.target })
  use discovered_raw <- result.try(patch_discovery.discover_directory_patches(
    pkg_root,
    pkg_name,
    target_pkg,
    toml_patched_paths,
  ))
  let discovered_patches = convert_discovered_patches(discovered_raw)
  let resolved_patches =
    merge_module_patch_dicts(resolved_toml_patches, discovered_patches)

  let #(patch_fn_overrides, patch_type_overrides) =
    expand_patch_entries(resolved_patches)
  let overrides = dict.merge(patch_fn_overrides, explicit_overrides)
  let type_overrides = dict.merge(patch_type_overrides, explicit_type_overrides)

  Ok(PackageOverlay(
    source_pkg: pkg_name,
    shim:,
    authorized_shims:,
    overrides:,
    type_overrides:,
    module_patches: resolved_patches,
    target_branches:,
  ))
}

fn convert_discovered_patches(
  discovered: Dict(String, patch_discovery.DiscoveredModulePatch),
) -> Dict(String, ModulePatch) {
  dict.map_values(discovered, fn(_k, p) {
    let files =
      list.map(p.files, fn(f) {
        ModulePatchFile(
          source_path: f.source_path,
          dest_filename: f.dest_filename,
          source_pkg: f.source_pkg,
        )
      })
    let imports =
      list.map(p.imports, fn(i) {
        ModulePatchImport(package: i.package, alias: i.alias)
      })
    let type_aliases =
      list.map(p.type_aliases, fn(entry) {
        let #(ty_name, #(ext_pkg, ext_ty)) = entry
        #(ty_name, ExternalType(package: ext_pkg, type_name: ext_ty))
      })
    ModulePatch(
      files:,
      imports:,
      types: p.types,
      type_aliases:,
      functions: p.functions,
    )
  })
}

fn expand_patch_entries(
  patches: Dict(String, ModulePatch),
) -> #(Dict(String, FfiKind), Dict(String, ExternalType)) {
  dict.fold(patches, #(dict.new(), dict.new()), fn(acc, mod_key, patch) {
    let #(fn_acc, ty_acc) = acc
    let target_mod = case string.split_once(mod_key, ":") {
      Ok(#(_, m)) -> m
      Error(_) -> mod_key
    }
    let next_fns =
      list.fold(patch.functions, fn_acc, fn(m, fn_name) {
        dict.insert(m, mod_key <> "." <> fn_name, Patched)
      })
    let next_tys =
      list.fold(patch.types, ty_acc, fn(m, ty_name) {
        dict.insert(
          m,
          mod_key <> "." <> ty_name,
          ExternalType(package: target_mod, type_name: ty_name),
        )
      })
    let next_tys =
      list.fold(patch.type_aliases, next_tys, fn(m, entry) {
        let #(ty_name, ext_ty) = entry
        dict.insert(m, mod_key <> "." <> ty_name, ext_ty)
      })
    #(next_fns, next_tys)
  })
}

fn resolve_module_patch_files(
  pkg_root: String,
  pkg_name: String,
  patches: Dict(String, ModulePatch),
) -> Result(Dict(String, ModulePatch), String) {
  let abs_root = simplifile.resolve(pkg_root) |> result.unwrap(pkg_root)
  dict.to_list(patches)
  |> list.try_fold(dict.new(), fn(acc, entry) {
    let #(mod_key, patch) = entry
    use resolved_files <- result.try(
      list.try_map(patch.files, fn(f) {
        let joined = case filepath.is_absolute(f.source_path) {
          True -> f.source_path
          False -> filepath.join(abs_root, f.source_path)
        }
        let normalized =
          simplifile.resolve(joined)
          |> result.unwrap(filepath.expand(joined) |> result.unwrap(joined))
        case simplifile.is_file(normalized) {
          Ok(True) ->
            Ok(ModulePatchFile(
              source_path: normalized,
              dest_filename: f.dest_filename,
              source_pkg: pkg_name,
            ))
          _ ->
            Error(
              "Patch MoonBit file '"
              <> f.source_path
              <> "' declared in package '"
              <> pkg_name
              <> "' for patch '"
              <> mod_key
              <> "' was not found at "
              <> normalized,
            )
        }
      }),
    )
    Ok(dict.insert(acc, mod_key, ModulePatch(..patch, files: resolved_files)))
  })
}

fn merge_module_patch_dicts(
  base: Dict(String, ModulePatch),
  extra: Dict(String, ModulePatch),
) -> Dict(String, ModulePatch) {
  dict.fold(extra, base, fn(acc, key, patch) {
    case dict.get(acc, key) {
      Error(_) -> dict.insert(acc, key, patch)
      Ok(existing) -> dict.insert(acc, key, merge_two_patches(existing, patch))
    }
  })
}

fn merge_two_patches(a: ModulePatch, b: ModulePatch) -> ModulePatch {
  let files =
    list.append(a.files, b.files)
    |> dedup_by(fn(f) { #(f.source_path, f.dest_filename) })
  let imports =
    list.append(a.imports, b.imports)
    |> dedup_by(fn(i) { #(i.package, i.alias) })
  let types =
    list.append(a.types, b.types)
    |> dedup_by(fn(t) { t })
  let type_aliases =
    list.append(a.type_aliases, b.type_aliases)
    |> dedup_by(fn(t) { t })
  let functions =
    list.append(a.functions, b.functions)
    |> dedup_by(fn(f) { f })
  ModulePatch(files:, imports:, types:, type_aliases:, functions:)
}

fn dedup_by(items: List(a), key_fn: fn(a) -> k) -> List(a) {
  let #(_, rev) =
    list.fold(items, #(set.new(), []), fn(acc, item) {
      let #(seen, out) = acc
      let k = key_fn(item)
      case set.contains(seen, k) {
        True -> acc
        False -> #(set.insert(seen, k), [item, ..out])
      }
    })
  list.reverse(rev)
}

/// Merge dependency shim overlays and the root project's overlay.
/// Conflicting overrides between two dependency shims produce an error unless
/// the root project explicitly overrides the same key.
pub fn merge_overlays(
  dep_overlays: List(PackageOverlay),
  root_overlay: PackageOverlay,
) -> Result(MergedOverlays, String) {
  use _ <- result.try(
    list.try_each(dep_overlays, fn(dep) {
      validate_dep_overlay_scope(dep, root_overlay.authorized_shims)
    }),
  )

  let shims =
    list.filter_map(dep_overlays, fn(ov) {
      case ov.shim {
        Some(meta) -> Ok(#(ov.source_pkg, meta))
        None -> Error(Nil)
      }
    })
  let shims = case root_overlay.shim {
    Some(meta) -> list.append(shims, [#(root_overlay.source_pkg, meta)])
    None -> shims
  }

  use #(ovr_map, ovr_src) <- result.try(merge_keyed_with_root(
    dep_overlays,
    root_overlay,
    fn(ov) { ov.overrides },
    "override",
  ))
  use #(ty_map, ty_src) <- result.try(merge_keyed_with_root(
    dep_overlays,
    root_overlay,
    fn(ov) { ov.type_overrides },
    "type_override",
  ))
  use #(br_map, _) <- result.try(merge_keyed_with_root(
    dep_overlays,
    root_overlay,
    fn(ov) { ov.target_branches },
    "target_branch",
  ))

  let #(patch_map, patch_src) =
    list.fold(
      list.append(dep_overlays, [root_overlay]),
      #(dict.new(), dict.new()),
      fn(acc, ov) {
        let #(m, s) = acc
        let next_m = merge_module_patch_dicts(m, ov.module_patches)
        let next_s =
          dict.fold(ov.module_patches, s, fn(s_acc, k, _v) {
            dict.insert(s_acc, k, ov.source_pkg)
          })
        #(next_m, next_s)
      },
    )

  let patched_source_files =
    dict.fold(patch_map, set.new(), fn(acc, _k, patch) {
      list.fold(patch.files, acc, fn(s, f) { set.insert(s, f.source_path) })
    })

  Ok(MergedOverlays(
    shims:,
    authorized_shims: root_overlay.authorized_shims,
    overrides: ovr_map,
    override_sources: ovr_src,
    type_overrides: ty_map,
    type_override_sources: ty_src,
    module_patches: patch_map,
    module_patch_sources: patch_src,
    target_branches: br_map,
    patched_source_files:,
  ))
}

fn merge_keyed_with_root(
  dep_overlays: List(PackageOverlay),
  root_overlay: PackageOverlay,
  getter: fn(PackageOverlay) -> Dict(String, a),
  kind_label: String,
) -> Result(#(Dict(String, a), Dict(String, String)), String) {
  let root_map = getter(root_overlay)
  let #(dep_map, dep_src, conflicts) =
    list.fold(dep_overlays, #(dict.new(), dict.new(), []), fn(acc, ov) {
      let #(cur_map, cur_src, cur_conflicts) = acc
      dict.fold(getter(ov), #(cur_map, cur_src, cur_conflicts), fn(st, k, v) {
        let #(m, s, c) = st
        case dict.get(m, k) {
          Error(_) -> #(
            dict.insert(m, k, v),
            dict.insert(s, k, ov.source_pkg),
            c,
          )
          Ok(existing) ->
            case existing == v {
              True -> st
              False -> {
                let prev_pkg = dict.get(s, k) |> result.unwrap("unknown")
                #(m, s, [#(k, prev_pkg, ov.source_pkg), ..c])
              }
            }
        }
      })
    })

  let unresolved =
    list.filter(list.reverse(conflicts), fn(c) { !dict.has_key(root_map, c.0) })
  case unresolved {
    [#(key, pkg_a, pkg_b), ..] ->
      Error(
        "Conflicting "
        <> kind_label
        <> " for '"
        <> key
        <> "' between shim packages '"
        <> pkg_a
        <> "' and '"
        <> pkg_b
        <> "' (override it in root gleam.toml [tools.gekko.*] to resolve)",
      )
    [] -> {
      let final_map = dict.merge(dep_map, root_map)
      let final_src =
        dict.fold(root_map, dep_src, fn(s, k, _v) {
          dict.insert(s, k, root_overlay.source_pkg)
        })
      Ok(#(final_map, final_src))
    }
  }
}

fn validate_dep_overlay_scope(
  dep: PackageOverlay,
  root_authorized_shims: Dict(String, String),
) -> Result(Nil, String) {
  let has_any =
    !dict.is_empty(dep.overrides)
    || !dict.is_empty(dep.type_overrides)
    || !dict.is_empty(dep.module_patches)
    || !dict.is_empty(dep.target_branches)
  case has_any, dep.shim {
    False, _ -> Ok(Nil)
    True, None ->
      Error(
        "Security error: dependency '"
        <> dep.source_pkg
        <> "' defines gekko patches or overrides without declaring [tools.gekko.shim_for] package = \"<pkg>\" in gleam.toml",
      )
    True, Some(ShimMeta(target:, ..)) -> {
      use _ <- result.try(case dict.get(root_authorized_shims, target) {
        Ok(allowed_shim) if allowed_shim == dep.source_pkg -> Ok(Nil)
        Ok(other_shim) ->
          Error(
            "Security error: dependency '"
            <> dep.source_pkg
            <> "' declares [tools.gekko.shim_for] for '"
            <> target
            <> "', but root gleam.toml authorizes '"
            <> other_shim
            <> "' for '"
            <> target
            <> "' in [tools.gekko.use_shims]",
          )
        Error(_) ->
          Error(
            "Security error: dependency '"
            <> dep.source_pkg
            <> "' declares [tools.gekko.shim_for] for '"
            <> target
            <> "', but is not enabled in root gleam.toml.\nTo allow and use this shim, add to your root gleam.toml:\n\n  [tools.gekko.use_shims]\n  "
            <> target
            <> " = \""
            <> dep.source_pkg
            <> "\"",
          )
      })
      let check_keys = fn(keys: List(String), allow_exact: Bool) {
        list.try_each(keys, fn(k) {
          let allowed =
            string.starts_with(k, target <> ":")
            || string.starts_with(k, target <> ".")
            || { allow_exact && k == target }
          case allowed {
            True -> Ok(Nil)
            False ->
              Error(
                "Security error: shim dependency '"
                <> dep.source_pkg
                <> "' declares [tools.gekko.shim_for] package '"
                <> target
                <> "' and cannot patch/override '"
                <> k
                <> "'",
              )
          }
        })
      }
      use _ <- result.try(check_keys(dict.keys(dep.overrides), False))
      use _ <- result.try(check_keys(dict.keys(dep.type_overrides), False))
      use _ <- result.try(check_keys(dict.keys(dep.module_patches), False))
      check_keys(dict.keys(dep.target_branches), True)
    }
  }
}

// -----------------------------------------------------------------------------
// SemVer Constraint Evaluation
// -----------------------------------------------------------------------------

type SemVer {
  SemVer(major: Int, minor: Int, patch: Int, pre: Option(String))
}

type VersionClause {
  VersionClause(
    op: String,
    major: Int,
    minor: Int,
    patch: Option(Int),
    pre: Option(String),
  )
}

/// Check whether `version` satisfies a Gleam/Hex SemVer `constraint`
/// (e.g. `">= 2.0.0 and < 3.0.0"`, `"~> 1.2"`, `"^3.0.0"`).
pub fn version_matches_constraint(
  version: String,
  constraint: String,
) -> Result(Bool, String) {
  use ver <- result.try(parse_semver(version))
  use clauses <- result.try(parse_version_constraint(constraint))
  Ok(list.all(clauses, fn(c) { eval_clause(ver, c) }))
}

/// Validate declared `[shim]` target presence and SemVer constraints against
/// discovered package versions.
pub fn check_shim_versions(
  shims: List(#(String, ShimMeta)),
  discovered_versions: Dict(String, String),
) -> Result(List(String), String) {
  list.try_map(shims, fn(entry) {
    let #(shim_pkg, meta) = entry
    case dict.get(discovered_versions, meta.target) {
      Error(_) ->
        Ok(Some(
          "Warning: shim '"
          <> shim_pkg
          <> "' targets package '"
          <> meta.target
          <> "', which is not a dependency of this project",
        ))
      Ok(actual_ver) ->
        case meta.version {
          None -> Ok(None)
          Some(constraint) -> {
            use matches <- result.try(version_matches_constraint(
              actual_ver,
              constraint,
            ))
            case matches {
              True -> Ok(None)
              False ->
                Ok(Some(
                  "Warning: shim '"
                  <> shim_pkg
                  <> "' expects '"
                  <> meta.target
                  <> "' ("
                  <> constraint
                  <> "), but resolved version is "
                  <> actual_ver,
                ))
            }
          }
        }
    }
  })
  |> result.map(fn(opts) { list.filter_map(opts, option.to_result(_, Nil)) })
}

/// Warn if any shim package enabled in root `[tools.gekko.use_shims]` is not a
/// resolved dependency of the project.
pub fn check_authorized_shims(
  authorized_shims: Dict(String, String),
  discovered_versions: Dict(String, String),
) -> List(String) {
  dict.to_list(authorized_shims)
  |> list.filter_map(fn(entry) {
    let #(target_pkg, shim_pkg) = entry
    case dict.has_key(discovered_versions, shim_pkg) {
      True -> Error(Nil)
      False ->
        Ok(
          "Warning: [tools.gekko.use_shims] enables '"
          <> shim_pkg
          <> "' for '"
          <> target_pkg
          <> "', but '"
          <> shim_pkg
          <> "' is not a dependency of this project",
        )
    }
  })
}

fn parse_version_constraint(
  constraint: String,
) -> Result(List(VersionClause), String) {
  let normalized =
    constraint
    |> string.replace("&&", " and ")
    |> string.replace(",", " and ")
  let parts =
    string.split(normalized, " and ")
    |> list.map(string.trim)
    |> list.filter(fn(p) { p != "" })
  case parts {
    [] -> Error("Empty version constraint '" <> constraint <> "'")
    _ -> list.try_map(parts, parse_single_clause)
  }
}

fn parse_single_clause(clause: String) -> Result(VersionClause, String) {
  let trimmed = string.trim(clause)
  let #(op, rest) = case
    string.starts_with(trimmed, ">="),
    string.starts_with(trimmed, "<="),
    string.starts_with(trimmed, "=="),
    string.starts_with(trimmed, "!="),
    string.starts_with(trimmed, "~>"),
    string.starts_with(trimmed, ">"),
    string.starts_with(trimmed, "<"),
    string.starts_with(trimmed, "^"),
    string.starts_with(trimmed, "=")
  {
    True, _, _, _, _, _, _, _, _ -> #(">=", string.drop_start(trimmed, 2))
    _, True, _, _, _, _, _, _, _ -> #("<=", string.drop_start(trimmed, 2))
    _, _, True, _, _, _, _, _, _ -> #("==", string.drop_start(trimmed, 2))
    _, _, _, True, _, _, _, _, _ -> #("!=", string.drop_start(trimmed, 2))
    _, _, _, _, True, _, _, _, _ -> #("~>", string.drop_start(trimmed, 2))
    _, _, _, _, _, True, _, _, _ -> #(">", string.drop_start(trimmed, 1))
    _, _, _, _, _, _, True, _, _ -> #("<", string.drop_start(trimmed, 1))
    _, _, _, _, _, _, _, True, _ -> #("^", string.drop_start(trimmed, 1))
    _, _, _, _, _, _, _, _, True -> #("==", string.drop_start(trimmed, 1))
    _, _, _, _, _, _, _, _, _ -> #("==", trimmed)
  }
  let ver_str = string.trim(rest)
  let without_build = case string.split_once(ver_str, "+") {
    Ok(#(v, _)) -> v
    Error(_) -> ver_str
  }
  let #(core, pre) = case string.split_once(without_build, "-") {
    Ok(#(c, p)) -> #(c, Some(p))
    Error(_) -> #(without_build, None)
  }
  let nums = string.split(core, ".")
  case nums {
    [maj_s, min_s] -> {
      use maj <- result.try(parse_ver_int(maj_s, clause))
      use min <- result.try(parse_ver_int(min_s, clause))
      Ok(VersionClause(op:, major: maj, minor: min, patch: None, pre:))
    }
    [maj_s, min_s, pat_s] -> {
      use maj <- result.try(parse_ver_int(maj_s, clause))
      use min <- result.try(parse_ver_int(min_s, clause))
      use pat <- result.try(parse_ver_int(pat_s, clause))
      Ok(VersionClause(op:, major: maj, minor: min, patch: Some(pat), pre:))
    }
    _ -> Error("Invalid SemVer clause '" <> clause <> "'")
  }
}

fn parse_semver(raw: String) -> Result(SemVer, String) {
  let trimmed = string.trim(raw)
  let without_build = case string.split_once(trimmed, "+") {
    Ok(#(v, _)) -> v
    Error(_) -> trimmed
  }
  let #(core, pre) = case string.split_once(without_build, "-") {
    Ok(#(c, p)) -> #(c, Some(p))
    Error(_) -> #(without_build, None)
  }
  case string.split(core, ".") {
    [maj_s, min_s, pat_s] -> {
      use major <- result.try(parse_ver_int(maj_s, raw))
      use minor <- result.try(parse_ver_int(min_s, raw))
      use patch <- result.try(parse_ver_int(pat_s, raw))
      Ok(SemVer(major:, minor:, patch:, pre:))
    }
    _ -> Error("Invalid SemVer version '" <> raw <> "'")
  }
}

fn parse_ver_int(s: String, ctx: String) -> Result(Int, String) {
  case int.parse(s) {
    Ok(n) if n >= 0 -> Ok(n)
    _ -> Error("Invalid SemVer component '" <> s <> "' in '" <> ctx <> "'")
  }
}

fn eval_clause(ver: SemVer, clause: VersionClause) -> Bool {
  let target =
    SemVer(
      major: clause.major,
      minor: clause.minor,
      patch: option.unwrap(clause.patch, 0),
      pre: clause.pre,
    )
  let cmp = compare_semver(ver, target)
  case clause.op {
    "==" -> cmp == 0
    "!=" -> cmp != 0
    ">" -> cmp > 0
    ">=" -> cmp >= 0
    "<" -> cmp < 0
    "<=" -> cmp <= 0
    "~>" -> {
      let upper = case clause.patch {
        None -> SemVer(major: clause.major + 1, minor: 0, patch: 0, pre: None)
        Some(_) ->
          SemVer(
            major: clause.major,
            minor: clause.minor + 1,
            patch: 0,
            pre: None,
          )
      }
      cmp >= 0 && compare_semver(ver, upper) < 0
    }
    "^" -> {
      let upper = case clause.major, clause.minor {
        0, 0 -> SemVer(major: 0, minor: 0, patch: target.patch + 1, pre: None)
        0, _ -> SemVer(major: 0, minor: clause.minor + 1, patch: 0, pre: None)
        _, _ -> SemVer(major: clause.major + 1, minor: 0, patch: 0, pre: None)
      }
      cmp >= 0 && compare_semver(ver, upper) < 0
    }
    _ -> False
  }
}

fn compare_semver(a: SemVer, b: SemVer) -> Int {
  case int.compare(a.major, b.major) {
    order.Lt -> -1
    order.Gt -> 1
    order.Eq ->
      case int.compare(a.minor, b.minor) {
        order.Lt -> -1
        order.Gt -> 1
        order.Eq ->
          case int.compare(a.patch, b.patch) {
            order.Lt -> -1
            order.Gt -> 1
            order.Eq ->
              case a.pre, b.pre {
                None, None -> 0
                Some(_), None -> -1
                None, Some(_) -> 1
                Some(pa), Some(pb) ->
                  case string.compare(pa, pb) {
                    order.Lt -> -1
                    order.Gt -> 1
                    order.Eq -> 0
                  }
              }
          }
      }
  }
}
