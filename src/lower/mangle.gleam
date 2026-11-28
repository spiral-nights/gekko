import gleam/int
import gleam/list
import gleam/set.{type Set}
import gleam/string

/// Return True if `name` collides with a MoonBit reserved keyword.
pub fn is_reserved_keyword(name: String) -> Bool {
  case name {
    "match"
    | "loop"
    | "for"
    | "while"
    | "break"
    | "continue"
    | "nobreak"
    | "struct"
    | "enum"
    | "trait"
    | "impl"
    | "guard"
    | "async"
    | "test"
    | "init"
    | "main"
    | "pub"
    | "priv"
    | "fn"
    | "let"
    | "mut"
    | "const"
    | "type"
    | "typealias"
    | "traitalias"
    | "suberror"
    | "raise"
    | "try"
    | "catch"
    | "noraise"
    | "nocancel"
    | "errdefer"
    | "defer"
    | "derive"
    | "extend"
    | "import"
    | "using"
    | "as"
    | "is"
    | "in"
    | "if"
    | "else"
    | "return"
    | "throw"
    | "and"
    | "dyn"
    | "true"
    | "false"
    | "Self"
    | "self"
    | "super"
    | "where"
    | "with"
    | "readonly"
    | "declare"
    | "extern"
    | "module"
    | "abstract"
    | "assert"
    | "assume"
    | "await"
    | "comptime"
    | "do"
    | "export"
    | "final"
    | "macro"
    | "member"
    | "move"
    | "namespace"
    | "opaque"
    | "override"
    | "package"
    | "protected"
    | "ref"
    | "sealed"
    | "static"
    | "typeof"
    | "unreachable"
    | "unsafe"
    | "use"
    | "var"
    | "virtual"
    | "void"
    | "volatile"
    | "yield"
    | "alias"
    | "anyframe"
    | "anytype"
    | "asm"
    | "atomic"
    | "constructor"
    | "define"
    | "downcast"
    | "dynclass"
    | "dynobj"
    | "dynrec"
    | "enumview"
    | "finally"
    | "fnalias"
    | "include"
    | "inherit"
    | "isnot"
    | "lazy"
    | "letrec"
    | "local"
    | "method"
    | "mixin"
    | "noasync"
    | "orelse"
    | "recur"
    | "resume"
    | "threadlocal"
    | "upcast"
    | "abort"
    | "eprintln"
    | "ignore"
    | "panic"
    | "println" -> True
    _ -> False
  }
}

/// Return True if `name` collides with a MoonBit reserved type name (`Error [4003]`).
pub fn is_reserved_type_name(name: String) -> Bool {
  case name {
    "Int"
    | "Int16"
    | "Int32"
    | "Int64"
    | "UInt"
    | "UInt16"
    | "UInt32"
    | "UInt64"
    | "Double"
    | "Float"
    | "String"
    | "Bool"
    | "Unit"
    | "Bytes"
    | "Byte"
    | "Char"
    | "FixedArray"
    | "ReadOnlyArray"
    | "Result"
    | "Option"
    | "Error"
    | "Self"
    | "FuncRef" -> True
    _ -> False
  }
}

fn is_builtin_moonbit_type(name: String) -> Bool {
  is_reserved_type_name(name)
  || case name {
    "Array" | "ArrayView" | "Json" | "Map" -> True
    _ -> False
  }
}

/// Escape MoonBit reserved keywords (and names ending in `_` whose stem is
/// a reserved keyword) by appending `_` so mangling is injective.
pub fn mangle_ident(name: String) -> String {
  let stem = strip_trailing_underscores(name)
  case is_reserved_keyword(stem) {
    True -> name <> "_"
    False -> name
  }
}

/// Escape MoonBit reserved type names (and names ending in `_` whose stem is
/// a reserved type name) by appending `_` so mangling is injective.
pub fn mangle_type_name(name: String) -> String {
  let stem = strip_trailing_underscores(name)
  case is_reserved_type_name(stem) {
    True -> name <> "_"
    False -> name
  }
}

/// Convert a Gleam `snake_case` type parameter into MoonBit `UpperCamelCase`,
/// preserving underscore distinctions injectively and prefixing `T_` if it
/// would collide with a MoonBit builtin type name or synthetic `T<digits>` name.
pub fn mangle_type_param(name: String) -> String {
  let base = case name {
    "" | "_" -> "T"
    _ -> {
      let parts = string.split(name, "_")
      case list.all(parts, fn(part) { part != "" }) {
        True ->
          parts
          |> list.map(uppercase_first)
          |> string.concat
        False ->
          parts
          |> list.map(fn(part) {
            case part {
              "" -> "U_"
              _ -> uppercase_first(part)
            }
          })
          |> string.concat
      }
    }
  }

  case
    is_builtin_moonbit_type(base)
    || is_synthetic_type_var_name(base)
    || string.starts_with(base, "T_")
  {
    True -> "T_" <> base
    False -> base
  }
}

/// Like `mangle_type_param`, additionally prefixing `T_` so the type
/// parameter never shadows any type name in `forbidden`.
pub fn mangle_type_param_avoiding(
  name: String,
  forbidden: Set(String),
) -> String {
  avoid_type_name_collision(mangle_type_param(name), forbidden)
}

fn avoid_type_name_collision(
  candidate: String,
  forbidden: Set(String),
) -> String {
  case set.contains(forbidden, candidate) {
    True -> avoid_type_name_collision("T_" <> candidate, forbidden)
    False -> candidate
  }
}

fn strip_trailing_underscores(s: String) -> String {
  case string.ends_with(s, "_") {
    True -> strip_trailing_underscores(string.drop_end(s, 1))
    False -> s
  }
}

fn is_synthetic_type_var_name(name: String) -> Bool {
  case name {
    "T" <> rest if rest != "" ->
      is_all_ascii_digits(string.to_utf_codepoints(rest))
    _ -> False
  }
}

fn is_all_ascii_digits(cps: List(UtfCodepoint)) -> Bool {
  case cps {
    [] -> True
    [cp, ..rest] -> {
      let n = string.utf_codepoint_to_int(cp)
      n >= 48 && n <= 57 && is_all_ascii_digits(rest)
    }
  }
}

/// Format a numeric Hindley-Milner variable ID from `package-interface` into
/// a valid MoonBit UpperCamelCase generic parameter name (`T0`, `T1`, ...).
pub fn type_var_id_to_name(id: Int) -> String {
  "T" <> int.to_string(id)
}

/// Convert a Gleam module path (`"my_app/auth/token"`) into a valid MoonBit
/// package import alias (`"my_app_auth_token"`).
pub fn module_to_alias(module_path: String) -> String {
  module_path
  |> string.replace("/", "_")
  |> mangle_ident
}

fn uppercase_first(segment: String) -> String {
  case string.pop_grapheme(segment) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    Error(_) -> ""
  }
}
