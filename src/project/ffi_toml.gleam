import filepath
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/moonbit_lex
import project/prepass.{
  type ExternalType, type FfiKind, type TargetBranch, ExternalType, PackageCall,
  PreferErlang, PreferJavascript, WasmImport,
}
import project/semver
import simplifile
import tom.{type Toml}

/// Parsed raw `[patch."..."]` table before conversion into `ffi_config.ModulePatch`.
pub type RawModulePatch {
  RawModulePatch(
    file_paths: List(String),
    imports: List(#(String, Option(String))),
    types: List(String),
    functions: List(String),
  )
}

/// Parse FFI overrides from a `gekko.toml` file string (`[overrides."..."]`).
pub fn parse_gekko_toml(
  content: String,
) -> Result(Dict(String, FfiKind), String) {
  parse_section(content, ["overrides"], dict.new(), fn(table) {
    collect_nested_entries(table, [], extract_ffi_kind)
  })
}

/// Parse FFI overrides from a `gleam.toml` file string (`[tools.gekko.overrides."..."]`).
pub fn parse_gleam_toml_overrides(
  content: String,
) -> Result(Dict(String, FfiKind), String) {
  parse_section(content, ["tools", "gekko", "overrides"], dict.new(), fn(table) {
    collect_nested_entries(table, [], extract_ffi_kind)
  })
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
  use dep_map <- result.try(parse_section(
    content,
    ["moonbit", "deps"],
    dict.new(),
    collect_string_entries,
  ))
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
  use import_bodies <- result.try(moonbit_lex.extract_import_blocks(
    content,
    "moon.mod",
  ))
  use dep_map <- result.try(
    list.try_fold(import_bodies, dict.new(), fn(acc, body) {
      parse_import_block_entries(body, acc)
    }),
  )
  Ok(sort_dep_pairs(dep_map))
}

/// Parse `[type_overrides."..."]` from a `gekko.toml` string.
pub fn parse_type_overrides_gekko_toml(
  content: String,
) -> Result(Dict(String, ExternalType), String) {
  parse_section(content, ["type_overrides"], dict.new(), fn(table) {
    collect_nested_entries(table, [], extract_type_override)
  })
}

/// Parse `[tools.gekko.type_overrides."..."]` from a `gleam.toml` string.
pub fn parse_type_overrides_gleam_toml(
  content: String,
) -> Result(Dict(String, ExternalType), String) {
  parse_section(
    content,
    ["tools", "gekko", "type_overrides"],
    dict.new(),
    fn(table) { collect_nested_entries(table, [], extract_type_override) },
  )
}

/// Parse `[target_branch."..."]` from a `gekko.toml` string.
pub fn parse_target_branch_gekko_toml(
  content: String,
) -> Result(Dict(String, TargetBranch), String) {
  parse_section(content, ["target_branch"], dict.new(), fn(table) {
    collect_nested_entries(table, [], extract_target_branch)
  })
}

/// Parse `[tools.gekko.target_branch."..."]` from a `gleam.toml` string.
pub fn parse_target_branch_gleam_toml(
  content: String,
) -> Result(Dict(String, TargetBranch), String) {
  parse_section(
    content,
    ["tools", "gekko", "target_branch"],
    dict.new(),
    fn(table) { collect_nested_entries(table, [], extract_target_branch) },
  )
}

/// Parse `[use_shims]` authorization allowlist from a `gekko.toml` string.
pub fn parse_authorized_shims_gekko_toml(
  content: String,
) -> Result(Dict(String, String), String) {
  parse_section(
    content,
    ["use_shims"],
    dict.new(),
    extract_authorized_shims_table,
  )
}

/// Parse `[tools.gekko.use_shims]` authorization allowlist from a `gleam.toml` string.
pub fn parse_authorized_shims_gleam_toml(
  content: String,
) -> Result(Dict(String, String), String) {
  parse_section(
    content,
    ["tools", "gekko", "use_shims"],
    dict.new(),
    extract_authorized_shims_table,
  )
}

pub fn load_toml_document(
  path: String,
) -> Result(Option(Dict(String, Toml)), String) {
  case simplifile.read(path) {
    Ok(content) -> {
      use parsed <- result.try(
        tom.parse(content)
        |> result.map_error(format_parse_error),
      )
      Ok(Some(parsed))
    }
    Error(simplifile.Enoent) -> Ok(None)
    Error(err) ->
      Error("Failed to read " <> path <> ": " <> simplifile.describe_error(err))
  }
}

pub fn parse_section(
  content: String,
  key_path: List(String),
  default: a,
  extractor: fn(Dict(String, Toml)) -> Result(a, String),
) -> Result(a, String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  section_from(Some(parsed), key_path, default, extractor)
}

pub fn section_from(
  parsed: Option(Dict(String, Toml)),
  key_path: List(String),
  default: a,
  extractor: fn(Dict(String, Toml)) -> Result(a, String),
) -> Result(a, String) {
  case parsed {
    None -> Ok(default)
    Some(parsed) ->
      case tom.get_table(parsed, key_path) {
        Ok(table) -> extractor(table)
        Error(tom.NotFound(_)) -> Ok(default)
        Error(err) -> Error(format_get_error(err))
      }
  }
}

pub fn collect_nested_entries(
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

pub fn extract_shim_tuple(
  table: Dict(String, Toml),
) -> Result(Option(#(String, Option(String))), String) {
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
      use _ <- result.try(semver.parse_version_constraint(v))
      Ok(Some(v))
    }
    Ok(_) -> Error("Shim 'version' must be String")
  })
  Ok(Some(#(target, version)))
}

pub fn extract_ffi_kind(
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

pub fn extract_type_override(
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

pub fn extract_target_branch(
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

pub fn extract_authorized_shims_table(
  table: Dict(String, Toml),
) -> Result(Dict(String, String), String) {
  dict.to_list(table)
  |> list.try_fold(dict.new(), fn(acc, entry) {
    let #(target_pkg, val) = entry
    case val {
      tom.String(shim_pkg) ->
        case string.trim(shim_pkg) {
          "" ->
            Error(
              "Shim authorization for '" <> target_pkg <> "' must not be empty",
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

pub fn extract_raw_module_patch(
  table: Dict(String, Toml),
  rev_key_parts: List(String),
) -> Result(Option(RawModulePatch), String) {
  let key_name = rev_key_parts |> list.reverse |> string.join(".")
  let has_file = dict.has_key(table, "file")
  let has_files = dict.has_key(table, "files")
  let has_imports = dict.has_key(table, "imports")
  let has_types = dict.has_key(table, "types")
  let has_fns = dict.has_key(table, "functions")
  case has_file || has_files || has_imports || has_types || has_fns {
    False -> Ok(None)
    True -> {
      use file_paths <- result.try(
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
              p -> Ok([p])
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
                    p -> Ok(p)
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
      case file_paths {
        [] -> Error("Patch '" <> key_name <> "' must specify at least one file")
        _ -> {
          use imports <- result.try(extract_imports_field(table, key_name))
          use types <- result.try(extract_string_array(table, "types", key_name))
          use functions <- result.try(extract_string_array(
            table,
            "functions",
            key_name,
          ))
          Ok(Some(RawModulePatch(file_paths:, imports:, types:, functions:)))
        }
      }
    }
  }
}

pub fn extract_patches_imports(
  table: Dict(String, Toml),
  rev_key_parts: List(String),
) -> Result(Option(List(#(String, Option(String)))), String) {
  let key_name = rev_key_parts |> list.reverse |> string.join(".")
  case dict.has_key(table, "imports") {
    False -> Ok(None)
    True -> {
      use imports <- result.try(extract_imports_field(table, key_name))
      Ok(Some(imports))
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
    Ok(table) -> collect_string_entries(table)
  }
}

fn collect_string_entries(
  table: Dict(String, Toml),
) -> Result(Dict(String, String), String) {
  dict.to_list(table)
  |> list.try_fold(dict.new(), fn(acc, entry) {
    let #(pkg, val) = entry
    case val {
      tom.String(ver) -> Ok(dict.insert(acc, pkg, ver))
      _ -> Error("MoonBit dependency '" <> pkg <> "' version must be a string")
    }
  })
}

fn sort_dep_pairs(deps: Dict(String, String)) -> List(#(String, String)) {
  deps
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

fn extract_imports_field(
  table: Dict(String, Toml),
  key_name: String,
) -> Result(List(#(String, Option(String))), String) {
  case dict.get(table, "imports") {
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
        "Patch '" <> key_name <> "' field 'imports' must be an array of Strings",
      )
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
) -> Result(#(String, Option(String)), String) {
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
            Error(_) -> Ok(#(trimmed, None))
          }
      }
  }
}

fn validate_patch_import(
  pkg: String,
  alias: Option(String),
  key_name: String,
  raw: String,
) -> Result(#(String, Option(String)), String) {
  let p = string.trim(pkg)
  let a =
    option.map(alias, fn(raw_a) {
      let t = string.trim(raw_a)
      case string.starts_with(t, "@") {
        True -> string.drop_start(t, 1)
        False -> t
      }
    })
  case p, a {
    "", _ | _, Some("") ->
      Error(
        "Invalid import specification '"
        <> raw
        <> "' in patch '"
        <> key_name
        <> "'",
      )
    _, _ -> Ok(#(p, a))
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
