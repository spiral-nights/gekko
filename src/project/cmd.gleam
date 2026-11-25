import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

/// Result of executing an external OS command.
pub type CommandResult {
  CommandResult(exit_code: Int, output: String)
}

/// Diagnostic status for a single toolchain executable checked by `gekko doctor`.
pub type ToolStatus {
  ToolStatus(
    name: String,
    required: Bool,
    found: Bool,
    version: Option(String),
    ok: Bool,
    warning: Bool,
    note: String,
  )
}

pub const min_moon_version = #(0, 1, 20_261_104)

pub const min_moonc_version = #(0, 10, 20)

/// MoonBit toolchain release gekko's test suite verifies against, in the format
/// accepted by the official installer (e.g. `0.10.22+124d61d05`). Keep in sync
/// with `.moonbit-version` (enforced by `pinned_moonbit_version_matches_disk_file_test`).
pub const pinned_moonbit_release = "0.10.22+124d61d05"

/// Parsed forms of the pinned release, reported by `moon --version` and `moonc -v`.
pub const pinned_moon_version = #(0, 1, 20_261_119)

pub const pinned_moonc_version = #(0, 10, 22)

@external(erlang, "gekko_ffi", "run_command")
fn ffi_run_command(
  command: String,
  args: List(String),
  cwd: String,
) -> #(Int, String)

@external(erlang, "gekko_ffi", "run_command_streaming")
fn ffi_run_command_streaming(
  command: String,
  args: List(String),
  cwd: String,
) -> #(Int, String)

@external(erlang, "gekko_ffi", "parallel_map")
fn ffi_parallel_map(items: List(a), f: fn(a) -> b) -> List(b)

@external(erlang, "gekko_ffi", "get_env")
fn ffi_get_env(name: String) -> Result(String, Nil)

@external(erlang, "gekko_ffi", "find_executable")
fn ffi_find_executable(command: String) -> Result(String, Nil)

@external(erlang, "gekko_ffi", "extract_zip_entry")
fn ffi_extract_zip_entry(
  zip_path: String,
  entry_path: String,
) -> Result(String, Nil)

/// Extract a single UTF-8 file entry from a `.zip` archive in memory using OTP `:zip`.
pub fn extract_zip_entry(
  zip_path: String,
  entry_path: String,
) -> Result(String, Nil) {
  ffi_extract_zip_entry(zip_path, entry_path)
}

@external(erlang, "gekko_ffi", "sha256_hex")
fn ffi_sha256_hex(data: String) -> String

/// Compute a lowercase hexadecimal SHA-256 digest of UTF-8 `data`.
pub fn sha256_hex(data: String) -> String {
  ffi_sha256_hex(data)
}

/// Read an OS environment variable as UTF-8, returning `Error(Nil)` if unset.
pub fn get_env(name: String) -> Result(String, Nil) {
  ffi_get_env(name)
}

/// Locate an executable on `PATH` (or at an explicit path), returning its resolved path.
pub fn find_executable(name: String) -> Result(String, Nil) {
  ffi_find_executable(name)
}

/// Verify that all required external tools are available on `PATH`.
pub fn require_tools(tools: List(String)) -> Result(Nil, String) {
  require_tools_with(tools, find_executable)
}

/// Testable version of `require_tools` accepting a custom executable lookup function.
pub fn require_tools_with(
  tools: List(String),
  finder: fn(String) -> Result(String, Nil),
) -> Result(Nil, String) {
  let missing =
    list.filter(tools, fn(tool) {
      case finder(tool) {
        Ok(_) -> False
        Error(_) -> True
      }
    })
  case missing {
    [] -> Ok(Nil)
    _ ->
      Error(
        "Missing required tool(s) on PATH: "
        <> string.join(missing, ", ")
        <> ". Please install them and ensure they are on your PATH.",
      )
  }
}

/// Run an external executable with arguments in `cwd` (or current directory if `""`).
pub fn run(
  command command: String,
  args args: List(String),
  cwd cwd: String,
) -> CommandResult {
  let #(exit_code, output) = ffi_run_command(command, args, cwd)
  CommandResult(exit_code:, output:)
}

/// Run an external executable, streaming stdout/stderr live while also capturing output.
pub fn run_streaming(
  command command: String,
  args args: List(String),
  cwd cwd: String,
) -> CommandResult {
  let #(exit_code, output) = ffi_run_command_streaming(command, args, cwd)
  CommandResult(exit_code:, output:)
}

/// Return True when `moon` output indicates a stale or uninitialized registry
/// index that can be resolved by running `moon update`.
pub fn needs_moon_update(output: String) -> Bool {
  string.contains(output, "moon update")
  || string.contains(output, "not found in the registry")
}

/// Run `moon` with `args` in `cwd`, automatically running `moon update` and
/// retrying once if the registry index is missing or stale.
pub fn run_moon_with_auto_update(
  args: List(String),
  cwd: String,
) -> CommandResult {
  run_moon_auto_update_with(args, cwd, fn(a, d) {
    run(command: "moon", args: a, cwd: d)
  })
}

/// Run `moon` with `args` in `cwd` using streaming output, automatically running
/// `moon update` and retrying once if the registry index is missing or stale.
pub fn run_moon_streaming_with_auto_update(
  args: List(String),
  cwd: String,
) -> CommandResult {
  run_moon_auto_update_with(args, cwd, fn(a, d) {
    run_streaming(command: "moon", args: a, cwd: d)
  })
}

fn run_moon_auto_update_with(
  args: List(String),
  cwd: String,
  runner: fn(List(String), String) -> CommandResult,
) -> CommandResult {
  let res = runner(args, cwd)
  case res.exit_code != 0 && needs_moon_update(res.output) {
    False -> res
    True -> {
      let update_res = run(command: "moon", args: ["update"], cwd:)
      case update_res.exit_code {
        0 -> runner(args, cwd)
        _ -> res
      }
    }
  }
}

/// Apply `f` to every item in `items` concurrently on BEAM processes,
/// preserving input order and returning the first `Error` in input order.
pub fn parallel_try_map(
  items: List(a),
  f: fn(a) -> Result(b, e),
) -> Result(List(b), e) {
  let results = ffi_parallel_map(items, f)
  list.try_map(results, fn(r) { r })
}

/// Parse a `moon --version` output string like `"moon 0.1.20261119 (738607b ...)"`
/// into `#(major, minor, patch_or_date)`.
pub fn parse_moon_date_version(output: String) -> Option(#(Int, Int, Int)) {
  parse_triplet_after_prefix(output, "moon ")
}

/// Parse a `moonc -v` output string like `"v0.10.22+124d61d05 ..."` or
/// `"moonc v0.10.22 ..."` into `#(major, minor, patch)`.
pub fn parse_moonc_version(output: String) -> Option(#(Int, Int, Int)) {
  let trimmed =
    output
    |> string.trim
    |> string.split("\n")
    |> list.first
    |> result.unwrap("")
    |> string.trim
  let after_moonc = case string.starts_with(trimmed, "moonc ") {
    True -> string.drop_start(trimmed, 6) |> string.trim_start
    False -> trimmed
  }
  let clean = case string.starts_with(after_moonc, "v") {
    True -> string.drop_start(after_moonc, 1)
    False -> after_moonc
  }
  parse_version_triplet(clean)
}

fn parse_triplet_after_prefix(
  output: String,
  prefix: String,
) -> Option(#(Int, Int, Int)) {
  let first_line =
    output
    |> string.trim
    |> string.split("\n")
    |> list.first
    |> result.unwrap("")
    |> string.trim
  let rest = case string.starts_with(first_line, prefix) {
    True -> string.drop_start(first_line, string.length(prefix))
    False -> first_line
  }
  let token =
    rest
    |> string.trim_start
    |> string.split(" ")
    |> list.first
    |> result.unwrap("")
  let clean = case string.starts_with(token, "v") {
    True -> string.drop_start(token, 1)
    False -> token
  }
  parse_version_triplet(clean)
}

fn parse_version_triplet(token: String) -> Option(#(Int, Int, Int)) {
  let base =
    token
    |> string.split("+")
    |> list.first
    |> result.unwrap(token)
    |> string.split("-")
    |> list.first
    |> result.unwrap(token)
  case string.split(base, ".") {
    [maj_s, min_s, pat_s, ..] ->
      case int.parse(maj_s), int.parse(min_s), int.parse(pat_s) {
        Ok(maj), Ok(min), Ok(pat) -> Some(#(maj, min, pat))
        _, _, _ -> None
      }
    _ -> None
  }
}

/// Compare two parsed versions lexicographically.
pub fn compare_versions(
  a: #(Int, Int, Int),
  b: #(Int, Int, Int),
) -> order.Order {
  let #(a1, a2, a3) = a
  let #(b1, b2, b3) = b
  case int.compare(a1, b1) {
    order.Eq ->
      case int.compare(a2, b2) {
        order.Eq -> int.compare(a3, b3)
        other -> other
      }
    other -> other
  }
}

/// Return True if `actual >= minimum` lexicographically.
pub fn is_version_at_least(
  actual: #(Int, Int, Int),
  minimum: #(Int, Int, Int),
) -> Bool {
  compare_versions(actual, minimum) != order.Lt
}

/// Return True if `actual` is newer than the toolchain version gekko verifies against.
pub fn is_version_newer(
  actual: #(Int, Int, Int),
  verified: #(Int, Int, Int),
) -> Bool {
  compare_versions(actual, verified) == order.Gt
}

/// Render a parsed version triple as `major.minor.patch`.
pub fn version_to_string(version: #(Int, Int, Int)) -> String {
  let #(major, minor, patch) = version
  int.to_string(major)
  <> "."
  <> int.to_string(minor)
  <> "."
  <> int.to_string(patch)
}

/// Verify that the installed `moon` CLI meets the minimum supported version
/// (`0.1.20261104`). Unparseable/dev version strings pass without error.
pub fn check_moon_version_compatible() -> Result(Nil, String) {
  let res = run(command: "moon", args: ["--version"], cwd: "")
  case res.exit_code {
    0 ->
      case parse_moon_date_version(res.output) {
        Some(ver) ->
          case is_version_at_least(ver, min_moon_version) {
            True -> Ok(Nil)
            False ->
              Error(
                "Installed MoonBit toolchain ("
                <> string.trim(res.output)
                <> ") is older than the minimum required version 0.1.20261104 (needed for declarative moon.mod / moon.pkg manifests). Please upgrade MoonBit.",
              )
          }
        None -> Ok(Nil)
      }
    _ -> Ok(Nil)
  }
}

/// Check required and optional external tools for `gekko doctor`.
pub fn run_doctor() -> List(ToolStatus) {
  [
    check_tool("gleam", True, ["--version"], fn(_) { #(True, False, "") }),
    check_tool("moon", True, ["--version"], validate_moon_version),
    check_tool("moonc", True, ["-v"], validate_moonc_version),
    check_tool("wit-bindgen", False, ["--version"], fn(_) {
      #(True, False, "needed for `gekko wit check` / `wit build`")
    }),
    check_tool("wasm-tools", False, ["--version"], fn(_) {
      #(True, False, "needed for `gekko wit build`")
    }),
    check_tool("wasmtime", False, ["--version"], fn(_) {
      #(True, False, "optional WASI Preview 2 component runner")
    }),
  ]
}

fn validate_moon_version(output: String) -> #(Bool, Bool, String) {
  case parse_moon_date_version(output) {
    Some(ver) ->
      case compare_versions(ver, min_moon_version) {
        order.Lt -> #(
          False,
          False,
          "requires >= " <> version_to_string(min_moon_version),
        )
        _ ->
          case is_version_newer(ver, pinned_moon_version) {
            True -> #(
              True,
              True,
              "newer than verified "
                <> version_to_string(pinned_moon_version)
                <> "; MoonBit may have introduced breaking changes",
            )
            False -> #(True, False, "")
          }
      }
    None -> #(True, False, "")
  }
}

fn validate_moonc_version(output: String) -> #(Bool, Bool, String) {
  case parse_moonc_version(output) {
    Some(ver) ->
      case compare_versions(ver, min_moonc_version) {
        order.Lt -> #(
          False,
          False,
          "requires >= " <> version_to_string(min_moonc_version),
        )
        _ ->
          case is_version_newer(ver, pinned_moonc_version) {
            True -> #(
              True,
              True,
              "newer than verified "
                <> version_to_string(pinned_moonc_version)
                <> "; MoonBit may have introduced breaking changes",
            )
            False -> #(True, False, "")
          }
      }
    None -> #(True, False, "")
  }
}

fn check_tool(
  name: String,
  required: Bool,
  args: List(String),
  validate: fn(String) -> #(Bool, Bool, String),
) -> ToolStatus {
  case find_executable(name) {
    Error(_) ->
      ToolStatus(
        name:,
        required:,
        found: False,
        version: None,
        ok: !required,
        warning: False,
        note: case required {
          True -> "not found on PATH"
          False -> "not found on PATH (optional)"
        },
      )
    Ok(_) -> {
      let res = run(command: name, args:, cwd: "")
      let first_line =
        res.output
        |> string.trim
        |> string.split("\n")
        |> list.first
        |> result.unwrap("")
        |> string.trim
      let ver = case first_line {
        "" -> None
        v -> Some(v)
      }
      case res.exit_code {
        0 -> {
          let #(valid, warning, note) = validate(res.output)
          ToolStatus(
            name:,
            required:,
            found: True,
            version: ver,
            ok: valid,
            warning:,
            note:,
          )
        }
        _ ->
          ToolStatus(
            name:,
            required:,
            found: True,
            version: ver,
            ok: !required,
            warning: False,
            note: "exited with non-zero status",
          )
      }
    }
  }
}
