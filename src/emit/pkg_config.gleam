import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string

/// Map a Gleam module path (`"my_app/auth/token"`) into a MoonBit package
/// directory name under the workspace root (`"my_app_auth_token"`).
pub fn module_to_pkg_dir(module_name: String) -> String {
  let base = string.replace(module_name, "/", "_")
  case base {
    "gprelude" | "prelude" -> "mod_" <> base
    _ -> base
  }
}

/// Resolve a deterministic, collision-free mapping from Gleam module name to
/// MoonBit package directory name. Non-colliding modules keep `module_to_pkg_dir`;
/// flat module names (without `/`) take priority for their natural directory,
/// and colliding names receive `<base>__2`, `<base>__3`, ...
pub fn resolve_module_pkg_dirs(
  module_names: List(String),
) -> Dict(String, String) {
  let unique =
    module_names
    |> set.from_list
    |> set.to_list
  let #(flat, nested) =
    list.partition(unique, fn(m) { !string.contains(m, "/") })
  let ordered =
    list.append(
      list.sort(flat, string.compare),
      list.sort(nested, string.compare),
    )
  let initial_used = set.from_list(["gprelude"])
  let #(_, mapping) =
    list.fold(ordered, #(initial_used, dict.new()), fn(acc, mod_name) {
      let #(used, map) = acc
      let base = module_to_pkg_dir(mod_name)
      let chosen = pick_free_pkg_dir(base, used)
      #(set.insert(used, chosen), dict.insert(map, mod_name, chosen))
    })
  mapping
}

fn pick_free_pkg_dir(base: String, used: Set(String)) -> String {
  case set.contains(used, base) {
    False -> base
    True -> pick_numbered_pkg_dir(base, 2, used)
  }
}

fn pick_numbered_pkg_dir(base: String, idx: Int, used: Set(String)) -> String {
  pick_unique(base, "__", idx, used)
}

/// Pick `base <> separator <> idx`, incrementing `idx` until the candidate is
/// not already in `used`.
pub fn pick_unique(
  base: String,
  separator: String,
  idx: Int,
  used: Set(String),
) -> String {
  let candidate = base <> separator <> int.to_string(idx)
  case set.contains(used, candidate) {
    True -> pick_unique(base, separator, idx + 1, used)
    False -> candidate
  }
}

/// Generate the root `moon.mod` file for the transpiled MoonBit workspace.
pub fn emit_moon_mod(project_name: String, version: String) -> String {
  emit_moon_mod_with_deps(project_name, version, [])
}

/// Generate the root `moon.mod` file including third-party `moonbit/moon.mod`
/// dependency entries as an `import { ... }` block.
pub fn emit_moon_mod_with_deps(
  project_name: String,
  version: String,
  deps: List(#(String, String)),
) -> String {
  let base =
    "name = \""
    <> project_name
    <> "\"\n"
    <> "version = \""
    <> version
    <> "\"\n"
    // Keep only suppressions inherent to Gleam->MoonBit lowering:
    // - implicit_impl_as_method / unused_trait_bound: inferred generic trait bounds on FFI/wrapper fns
    // - unused_rest_mark / guard_redundant_else: uniform enum & `let` pattern/guard lowering
    // - unused_package / unused_value / unused_constructor / unused_loop_variable: valid Gleam patterns & TCO loops
    // - unresolved_type_variable: unconstrained polymorphic expressions like `let _ = []`
    <> "warnings = \"-implicit_impl_as_method-unused_rest_mark-unused_package-unused_value-unresolved_type_variable-unused_loop_variable-unused_constructor-guard_redundant_else-unused_trait_bound\"\n"

  case deps {
    [] -> base
    _ -> {
      let dep_lines =
        list.map(deps, fn(entry) {
          let #(pkg, ver) = entry
          let spec = case ver == "" || string.contains(pkg, "@") {
            True -> pkg
            False -> pkg <> "@" <> ver
          }
          "  \"" <> spec <> "\","
        })
        |> string.join("\n")
      base <> "\nimport {\n" <> dep_lines <> "\n}\n"
    }
  }
}

/// Generate a declarative `moon.pkg` file for a package given `#(pkg_or_dir, alias)`
/// pairs and an optional `is-main` entrypoint flag.
pub fn emit_moon_pkg(
  project_name: String,
  imports: List(#(String, String)),
  is_main: Bool,
) -> String {
  emit_moon_pkg_with_local_pkgs(project_name, imports, is_main, set.new())
}

/// Generate a declarative `moon.pkg` file, prefixing `project_name <> "/"`
/// for any multi-segment local package present in `local_pkgs`.
pub fn emit_moon_pkg_with_local_pkgs(
  project_name: String,
  imports: List(#(String, String)),
  is_main: Bool,
  local_pkgs: Set(String),
) -> String {
  let deduped = deduplicate_imports(project_name, imports, local_pkgs)

  let import_block = case deduped {
    [] -> ""
    entries -> {
      let lines =
        list.map(entries, fn(entry) {
          let #(pkg_path, alias) = entry
          "  \"" <> pkg_path <> "\" @" <> alias <> ","
        })
        |> string.join("\n")
      "import {\n" <> lines <> "\n}\n"
    }
  }

  let options_block = case is_main {
    False -> ""
    True -> {
      let prefix = case import_block {
        "" -> ""
        _ -> "\n"
      }
      prefix <> "options(\n  \"is-main\": true,\n)\n"
    }
  }

  import_block <> options_block
}

fn deduplicate_imports(
  project_name: String,
  imports: List(#(String, String)),
  local_pkgs: Set(String),
) -> List(#(String, String)) {
  imports
  |> list.fold(dict.new(), fn(acc, entry) {
    let #(pkg_or_dir, alias) = entry
    let full_pkg = case
      set.contains(local_pkgs, pkg_or_dir) || !string.contains(pkg_or_dir, "/")
    {
      True -> project_name <> "/" <> pkg_or_dir
      False -> pkg_or_dir
    }
    dict.insert(acc, alias, full_pkg)
  })
  |> dict.to_list
  |> list.map(fn(pair) { #(pair.1, pair.0) })
  |> list.sort(fn(a, b) { string.compare(a.1, b.1) })
}

/// Parse a `moon.pkg` file into its `import { "pkg" @alias, ... }` pairs and
/// optional `warnings = ...` directive line.
pub fn parse_moon_pkg(
  content: String,
) -> #(List(#(String, String)), Option(String)) {
  let lines = string.split(content, "\n")
  let #(_, rev_imports) =
    list.fold(lines, #(False, []), fn(acc, line) {
      let #(in_imp, imp_acc) = acc
      let trimmed = string.trim(line)
      case in_imp, trimmed {
        False, "import {" -> #(True, imp_acc)
        True, "}" -> #(False, imp_acc)
        True, _ ->
          case parse_import_line(trimmed) {
            Some(pair) -> #(True, [pair, ..imp_acc])
            None -> #(True, imp_acc)
          }
        _, _ -> #(in_imp, imp_acc)
      }
    })
  let warnings_line =
    list.find(lines, fn(l) { string.starts_with(string.trim(l), "warnings =") })
    |> option.from_result
    |> option.map(string.trim)
  #(list.reverse(rev_imports), warnings_line)
}

fn parse_import_line(trimmed: String) -> Option(#(String, String)) {
  let cleaned = case string.ends_with(trimmed, ",") {
    True -> string.drop_end(trimmed, 1) |> string.trim
    False -> trimmed
  }
  case string.split_once(cleaned, on: "\" @") {
    Ok(#(left, alias)) -> {
      let pkg = case string.starts_with(left, "\"") {
        True -> string.drop_start(left, 1)
        False -> left
      }
      case pkg != "" && alias != "" {
        True -> Some(#(pkg, alias))
        False -> None
      }
    }
    Error(_) -> None
  }
}

/// Render a `moon.pkg` file from a `pkg_path -> alias` dictionary and an
/// optional `warnings = ...` line.
pub fn render_moon_pkg(
  pkg_imports: Dict(String, String),
  warnings_line: Option(String),
) -> String {
  let entries =
    pkg_imports
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.1, b.1) })
    |> list.map(fn(entry) { "  \"" <> entry.0 <> "\" @" <> entry.1 <> "," })
    |> string.join("\n")
  let imp_block = case entries {
    "" -> ""
    _ -> "import {\n" <> entries <> "\n}\n"
  }
  let warn_block = case warnings_line {
    Some(w) -> "\n" <> w <> "\n"
    None -> ""
  }
  imp_block <> warn_block
}
