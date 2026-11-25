import common/gleam_ident
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option}
import gleam/string

/// Package identifier in a WIT document, e.g. `demo:greeter@0.1.0`.
pub type WitPackageId {
  WitPackageId(namespace: String, name: String, version: Option(String))
}

/// Core WIT type expressions (primitives, generics, tuples, named refs).
pub type WitType {
  WitBool
  WitS8
  WitS16
  WitS32
  WitS64
  WitU8
  WitU16
  WitU32
  WitU64
  WitF32
  WitF64
  WitChar
  WitString
  WitList(WitType)
  WitOption(WitType)
  WitResult(ok: Option(WitType), err: Option(WitType))
  WitTuple(List(WitType))
  WitOwn(String)
  WitBorrow(String)
  WitNamed(String)
}

/// Kind of method declared inside a WIT `resource` block.
pub type WitResourceMethodKind {
  ResourceConstructor
  ResourceMethod
  ResourceStatic
}

/// Method or constructor inside a WIT `resource` definition.
pub type WitResourceMethod {
  WitResourceMethod(
    name: String,
    kind: WitResourceMethodKind,
    params: List(#(String, WitType)),
    result: Option(WitType),
  )
}

/// Type definitions declared inside a WIT interface.
pub type WitTypeDef {
  WitRecord(name: String, fields: List(#(String, WitType)))
  WitEnum(name: String, cases: List(String))
  WitVariant(name: String, cases: List(#(String, Option(WitType))))
  WitFlags(name: String, flags: List(String))
  WitAlias(name: String, target: WitType)
  WitResource(name: String, methods: List(WitResourceMethod))
}

/// Function signature inside a WIT interface or world.
pub type WitFunc {
  WitFunc(
    name: String,
    params: List(#(String, WitType)),
    result: Option(WitType),
  )
}

/// Reference to either a local interface (`logger`) or external package
/// interface (`wasi:io/streams@0.2.0`).
pub type WitIfaceRef {
  LocalIface(name: String)
  PkgIface(pkg: WitPackageId, name: String)
}

/// `use` statement importing named types (with optional `as` rename).
pub type WitUse {
  WitUse(target: WitIfaceRef, names: List(#(String, Option(String))))
}

/// A named WIT interface within a package.
pub type WitInterface {
  WitInterface(
    pkg: WitPackageId,
    name: String,
    uses: List(WitUse),
    types: List(WitTypeDef),
    funcs: List(WitFunc),
  )
}

/// Individual declaration inside a WIT `world`.
pub type WitWorldItem {
  WorldImportIface(WitIfaceRef)
  WorldExportIface(WitIfaceRef)
  WorldImportFunc(WitFunc)
  WorldExportFunc(WitFunc)
  WorldUse(WitUse)
  WorldInclude(target: WitIfaceRef, with_renames: List(#(String, String)))
}

/// A WIT `world` declaration specifying host imports and component exports.
pub type WitWorld {
  WitWorld(pkg: WitPackageId, name: String, items: List(WitWorldItem))
}

/// Resolved WIT package directory centered around one selected `world`.
pub type ResolvedWit {
  ResolvedWit(
    root_pkg: WitPackageId,
    world: WitWorld,
    interfaces: Dict(String, WitInterface),
  )
}

/// Canonical package-qualified interface key omitting semver, e.g.
/// `"demo:greeter/api"`.
pub fn iface_key(pkg: WitPackageId, name: String) -> String {
  pkg.namespace <> ":" <> pkg.name <> "/" <> name
}

/// Version-aware package-qualified interface key, including `@version` when present.
pub fn iface_versioned_key(pkg: WitPackageId, name: String) -> String {
  let base = iface_key(pkg, name)
  case pkg.version {
    option.Some(ver) -> base <> "@" <> ver
    option.None -> base
  }
}

/// Resolve an interface reference relative to `default_pkg` (without version).
pub fn resolve_iface_ref(
  default_pkg: WitPackageId,
  ref: WitIfaceRef,
) -> String {
  case ref {
    LocalIface(name) -> iface_key(default_pkg, name)
    PkgIface(pkg, name) -> iface_key(pkg, name)
  }
}

/// Resolve an interface reference in `interfaces`, preferring an exact versioned
/// key when `@version` is specified on `ref` and falling back to unversioned `iface_key`.
pub fn resolve_iface_key_in(
  interfaces: Dict(String, WitInterface),
  default_pkg: WitPackageId,
  ref: WitIfaceRef,
) -> String {
  case ref {
    LocalIface(name) -> {
      let versioned = iface_versioned_key(default_pkg, name)
      case dict.has_key(interfaces, versioned) {
        True -> versioned
        False -> iface_key(default_pkg, name)
      }
    }
    PkgIface(pkg, name) -> {
      let versioned = iface_versioned_key(pkg, name)
      case pkg.version {
        option.Some(_) ->
          case dict.has_key(interfaces, versioned) {
            True -> versioned
            False -> iface_key(pkg, name)
          }
        option.None -> iface_key(pkg, name)
      }
    }
  }
}

/// Look up an interface in `interfaces` using version-aware resolution.
pub fn lookup_interface(
  interfaces: Dict(String, WitInterface),
  default_pkg: WitPackageId,
  ref: WitIfaceRef,
) -> Result(WitInterface, Nil) {
  dict.get(interfaces, resolve_iface_key_in(interfaces, default_pkg, ref))
}

/// Compare two package IDs by namespace and name (ignoring version).
pub fn is_root_pkg(root_pkg: WitPackageId, pkg: WitPackageId) -> Bool {
  root_pkg.namespace == pkg.namespace && root_pkg.name == pkg.name
}

/// Convert WIT `kebab-case` to Gleam/MoonBit `snake_case`.
pub fn kebab_to_snake(name: String) -> String {
  string.replace(name, "-", "_")
}

/// Convert WIT `kebab-case` to `PascalCase`.
pub fn kebab_to_pascal(name: String) -> String {
  name
  |> string.replace("-", "_")
  |> string.split("_")
  |> list.filter(fn(part) { part != "" })
  |> list.map(uppercase_first)
  |> string.concat
}

/// Convert WIT `kebab-case` to `SCREAMING_SNAKE_CASE`.
pub fn kebab_to_screaming(name: String) -> String {
  name
  |> string.replace("-", "_")
  |> string.uppercase
}

/// Append `_` if `name` is a reserved Gleam keyword.
pub fn escape_gleam_ident(name: String) -> String {
  gleam_ident.escape(name)
}

/// Map a WIT value/function/field/parameter name to a valid Gleam identifier.
pub fn gleam_value_ident(wit_name: String) -> String {
  wit_name
  |> kebab_to_snake
  |> escape_gleam_ident
}

/// Map a WIT type name to a Gleam `PascalCase` type name.
pub fn gleam_type_name(wit_name: String) -> String {
  kebab_to_pascal(wit_name)
}

/// Map a WIT enum/variant constructor name to a Gleam `PascalCase` variant name.
pub fn gleam_variant_name(wit_name: String) -> String {
  kebab_to_pascal(wit_name)
}

/// Gleam module path holding type definitions for an interface.
pub fn gleam_types_module(
  root_pkg: WitPackageId,
  iface: WitInterface,
) -> String {
  case is_root_pkg(root_pkg, iface.pkg) {
    True -> "wit/" <> kebab_to_snake(iface.name) <> "_types"
    False ->
      "wit/"
      <> kebab_to_snake(iface.pkg.namespace)
      <> "/"
      <> kebab_to_snake(iface.pkg.name)
      <> "/"
      <> kebab_to_snake(iface.name)
      <> "_types"
  }
}

/// Gleam module path holding `@external(moonbit, ...)` import functions.
pub fn gleam_import_module(
  root_pkg: WitPackageId,
  iface: WitInterface,
) -> String {
  case is_root_pkg(root_pkg, iface.pkg) {
    True -> "wit/" <> kebab_to_snake(iface.name)
    False ->
      "wit/"
      <> kebab_to_snake(iface.pkg.namespace)
      <> "/"
      <> kebab_to_snake(iface.pkg.name)
      <> "/"
      <> kebab_to_snake(iface.name)
  }
}

/// Suffix `_export` when a top-level generated Gleam export module name would
/// collide with a built-in Erlang/OTP module name during `gleam check`.
pub fn escape_erlang_reserved_module(name: String) -> String {
  case name {
    "application"
    | "array"
    | "asn1"
    | "base64"
    | "beam_lib"
    | "binary"
    | "calendar"
    | "code"
    | "compile"
    | "crypto"
    | "ct"
    | "dbg"
    | "dialyzer"
    | "diameter"
    | "dict"
    | "digraph"
    | "edlin"
    | "eldap"
    | "epp"
    | "erl_eval"
    | "erl_parse"
    | "erl_scan"
    | "erlang"
    | "error_logger"
    | "escript"
    | "ets"
    | "eunit"
    | "file"
    | "filelib"
    | "filename"
    | "ftp"
    | "gb_sets"
    | "gb_trees"
    | "gen_event"
    | "gen_server"
    | "gen_statem"
    | "gen_tcp"
    | "gen_udp"
    | "global"
    | "httpc"
    | "httpd"
    | "inet"
    | "inets"
    | "init"
    | "io"
    | "json"
    | "kernel"
    | "leex"
    | "lists"
    | "logger"
    | "maps"
    | "math"
    | "megaco"
    | "mnesia"
    | "net"
    | "observer"
    | "odbc"
    | "orddict"
    | "ordsets"
    | "os"
    | "parsetools"
    | "peer"
    | "pg"
    | "proc_lib"
    | "proplists"
    | "public_key"
    | "queue"
    | "rand"
    | "re"
    | "rpc"
    | "runtime_tools"
    | "sasl"
    | "sets"
    | "shell"
    | "snmp"
    | "socket"
    | "sofs"
    | "ssh"
    | "ssl"
    | "stdlib"
    | "string"
    | "supervisor"
    | "syntax_tools"
    | "sys"
    | "tar"
    | "tftp"
    | "timer"
    | "tools"
    | "typer"
    | "unicode"
    | "uri_string"
    | "user"
    | "xmerl"
    | "xref"
    | "yecc"
    | "zip"
    | "zlib" -> name <> "_export"
    _ -> name
  }
}

/// Gleam module path where user code implements an exported interface.
pub fn gleam_export_module(
  root_pkg: WitPackageId,
  iface: WitInterface,
) -> String {
  case is_root_pkg(root_pkg, iface.pkg) {
    True -> escape_erlang_reserved_module(kebab_to_snake(iface.name))
    False ->
      kebab_to_snake(iface.pkg.namespace)
      <> "/"
      <> kebab_to_snake(iface.pkg.name)
      <> "/"
      <> kebab_to_snake(iface.name)
  }
}

/// Gleam module path holding top-level `world` import functions.
pub fn gleam_world_import_module(world: WitWorld) -> String {
  "wit/" <> kebab_to_snake(world.name) <> "_imports"
}

/// Gleam module path where user code implements top-level `world` exports.
pub fn gleam_world_export_module(world: WitWorld) -> String {
  escape_erlang_reserved_module(kebab_to_snake(world.name))
}

/// Single-segment MoonBit package directory for an imported interface adapter.
pub fn moonbit_imp_adapter_pkg(iface: WitInterface) -> String {
  "wit_imp_"
  <> kebab_to_snake(iface.pkg.namespace)
  <> "_"
  <> kebab_to_snake(iface.pkg.name)
  <> "_"
  <> kebab_to_snake(iface.name)
}

/// Single-segment MoonBit package directory for world-level import adapters.
pub fn moonbit_world_imp_adapter_pkg(world: WitWorld) -> String {
  "wit_imp_world_" <> kebab_to_snake(world.name)
}

/// Directory generated by `wit-bindgen moonbit` for an interface package.
pub fn wit_bindgen_iface_raw_dir(iface: WitInterface) -> String {
  "interface/"
  <> iface.pkg.namespace
  <> "/"
  <> iface.pkg.name
  <> "/"
  <> iface.name
}

/// Directory generated by `wit-bindgen moonbit` for an exported interface stub.
pub fn wit_bindgen_iface_gen_dir(iface: WitInterface) -> String {
  "gen/interface/"
  <> iface.pkg.namespace
  <> "/"
  <> iface.pkg.name
  <> "/"
  <> iface.name
}

/// Directory generated by `wit-bindgen moonbit` for world-level imports.
pub fn wit_bindgen_world_raw_dir(world: WitWorld) -> String {
  "world/" <> world.name
}

/// Directory generated by `wit-bindgen moonbit` for world-level export stubs.
pub fn wit_bindgen_world_gen_dir(world: WitWorld) -> String {
  "gen/world/" <> world.name
}

fn uppercase_first(segment: String) -> String {
  case string.pop_grapheme(segment) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    Error(_) -> ""
  }
}
