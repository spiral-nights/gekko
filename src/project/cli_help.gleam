import gleam/string

/// Help topic identifying the top-level CLI, a command group, or a subcommand.
pub type HelpTopic {
  HelpTopLevel
  HelpVersion
  HelpNew
  HelpInit
  HelpClean
  HelpDoctor
  HelpCheck
  HelpBuild
  HelpTest
  HelpRun
  HelpWit
  HelpWitGen
  HelpWitCheck
  HelpWitBuild
  HelpMoonbit
  HelpMoonbitBind
  HelpShim
  HelpShimNew
  HelpShimInit
  HelpShimInspect
  HelpShimPatch
  HelpShimSync
  HelpShimMigrate
  HelpShimAck
}

/// Every supported CLI help topic.
pub fn all_topics() -> List(HelpTopic) {
  [
    HelpTopLevel,
    HelpVersion,
    HelpNew,
    HelpInit,
    HelpClean,
    HelpDoctor,
    HelpCheck,
    HelpBuild,
    HelpTest,
    HelpRun,
    HelpWit,
    HelpWitGen,
    HelpWitCheck,
    HelpWitBuild,
    HelpMoonbit,
    HelpMoonbitBind,
    HelpShim,
    HelpShimNew,
    HelpShimInit,
    HelpShimInspect,
    HelpShimPatch,
    HelpShimSync,
    HelpShimMigrate,
    HelpShimAck,
  ]
}

/// Resolve a list of CLI command tokens (with `-h`/`--help` stripped) into a
/// `HelpTopic`, or return an error for unknown commands or subcommands.
pub fn resolve_topic(tokens: List(String)) -> Result(HelpTopic, String) {
  case tokens {
    [] -> Ok(HelpTopLevel)
    ["help", ..rest] -> resolve_topic(rest)
    ["version", ..] -> Ok(HelpVersion)
    ["new", ..] -> Ok(HelpNew)
    ["init", ..] -> Ok(HelpInit)
    ["clean", ..] -> Ok(HelpClean)
    ["doctor", ..] -> Ok(HelpDoctor)
    ["check", ..] -> Ok(HelpCheck)
    ["build", ..] -> Ok(HelpBuild)
    ["test", ..] -> Ok(HelpTest)
    ["run", ..] -> Ok(HelpRun)
    ["wit", ..rest] -> resolve_wit_topic(rest)
    ["moonbit", ..rest] -> resolve_moonbit_topic(rest)
    ["shim", ..rest] -> resolve_shim_topic(rest)
    [first, ..] ->
      case string.starts_with(first, "-") {
        True -> Ok(HelpTopLevel)
        False -> Error("Unknown subcommand: " <> first)
      }
  }
}

fn resolve_wit_topic(tokens: List(String)) -> Result(HelpTopic, String) {
  case tokens {
    [] -> Ok(HelpWit)
    ["help", ..tail] -> resolve_wit_topic(tail)
    ["gen", ..] -> Ok(HelpWitGen)
    ["check", ..] -> Ok(HelpWitCheck)
    ["build", ..] -> Ok(HelpWitBuild)
    [first, ..] ->
      case string.starts_with(first, "-") {
        True -> Ok(HelpWit)
        False -> Error("Unknown subcommand: wit " <> first)
      }
  }
}

fn resolve_moonbit_topic(tokens: List(String)) -> Result(HelpTopic, String) {
  case tokens {
    [] -> Ok(HelpMoonbit)
    ["help", ..tail] -> resolve_moonbit_topic(tail)
    ["bind", ..] -> Ok(HelpMoonbitBind)
    [first, ..] ->
      case string.starts_with(first, "-") {
        True -> Ok(HelpMoonbit)
        False -> Error("Unknown subcommand: moonbit " <> first)
      }
  }
}

fn resolve_shim_topic(tokens: List(String)) -> Result(HelpTopic, String) {
  case tokens {
    [] -> Ok(HelpShim)
    ["help", ..tail] -> resolve_shim_topic(tail)
    ["new", ..] -> Ok(HelpShimNew)
    ["init", ..] -> Ok(HelpShimInit)
    ["inspect", ..] -> Ok(HelpShimInspect)
    ["patch", ..] -> Ok(HelpShimPatch)
    ["sync", ..] -> Ok(HelpShimSync)
    ["migrate", ..] -> Ok(HelpShimMigrate)
    ["ack", ..] -> Ok(HelpShimAck)
    [first, ..] ->
      case string.starts_with(first, "-") {
        True -> Ok(HelpShim)
        False -> Error("Unknown subcommand: shim " <> first)
      }
  }
}

/// Render formatted help text for the given `HelpTopic`.
pub fn render(topic: HelpTopic, version: String) -> String {
  let lines = case topic {
    HelpTopLevel -> render_top_level(version)
    HelpVersion -> render_version(version)
    HelpNew -> render_new()
    HelpInit -> render_init()
    HelpClean -> render_clean()
    HelpDoctor -> render_doctor()
    HelpCheck -> render_check()
    HelpBuild -> render_build()
    HelpTest -> render_test()
    HelpRun -> render_run()
    HelpWit -> render_wit()
    HelpWitGen -> render_wit_gen()
    HelpWitCheck -> render_wit_check()
    HelpWitBuild -> render_wit_build()
    HelpMoonbit -> render_moonbit()
    HelpMoonbitBind -> render_moonbit_bind()
    HelpShim -> render_shim()
    HelpShimNew -> render_shim_new()
    HelpShimInit -> render_shim_init()
    HelpShimInspect -> render_shim_inspect()
    HelpShimPatch -> render_shim_patch()
    HelpShimSync -> render_shim_sync()
    HelpShimMigrate -> render_shim_migrate()
    HelpShimAck -> render_shim_ack()
  }
  string.join(lines, "\n")
}

fn render_top_level(version: String) -> List(String) {
  [
    "gekko " <> version <> " - Gleam-to-MoonBit & Wasm Component transpiler",
    "",
    "Usage:",
    "  gekko <command> [options]",
    "",
    "Commands:",
    "  new <name>       Create a new gekko project",
    "  init             Initialize gekko configuration in an existing project",
    "  clean            Remove generated MoonBit staging and build artifacts",
    "  doctor           Check required and optional toolchain binaries",
    "  check            Transpile and type-check with MoonBit",
    "  build            Transpile and compile a standalone executable or library",
    "  test             Transpile and run MoonBit tests",
    "  run              Transpile and execute main() via MoonBit",
    "  wit <subcmd>     Generate, check, and build WebAssembly Components (WIT)",
    "  moonbit <subcmd> Generate Gleam bindings from MoonBit packages",
    "  shim <subcmd>    Inspect, scaffold, patch, and maintain companion shims",
    "  version          Print the gekko version",
    "  help             Show help for gekko or a subcommand",
    "",
    "Options:",
    "  -V, --version    Print version information",
    "  -h, --help       Show help",
    "",
    "Run 'gekko <command> --help' for more information on a command.",
  ]
}

fn render_version(version: String) -> List(String) {
  [
    "gekko version - Print version information (current: " <> version <> ")",
    "",
    "Usage:",
    "  gekko version",
    "  gekko --version | -V",
    "",
    "Options:",
    "  -h, --help       Show help",
  ]
}

fn render_new() -> List(String) {
  [
    "gekko new - Create a new Gleam + MoonBit project directory",
    "",
    "Usage:",
    "  gekko new <name> [--wit]",
    "",
    "Arguments:",
    "  <name>           Name and directory of the new project",
    "",
    "Options:",
    "  --wit            Include a starter WIT component schema and config",
    "  -h, --help       Show help",
  ]
}

fn render_init() -> List(String) {
  [
    "gekko init - Initialize gekko files in an existing Gleam project",
    "",
    "Usage:",
    "  gekko init [--root <dir>] [--wit]",
    "",
    "Options:",
    "  --root <dir>     Project root directory (default: .)",
    "  --wit            Include a starter WIT component schema and config",
    "  -h, --help       Show help",
  ]
}

fn render_clean() -> List(String) {
  [
    "gekko clean - Remove generated MoonBit staging and workspace artifacts",
    "",
    "Usage:",
    "  gekko clean [--root <dir>]",
    "",
    "Options:",
    "  --root <dir>     Project root directory (default: .)",
    "  -h, --help       Show help",
  ]
}

fn render_doctor() -> List(String) {
  [
    "gekko doctor - Verify required and optional toolchain binaries",
    "",
    "Usage:",
    "  gekko doctor",
    "",
    "Options:",
    "  -h, --help       Show help",
    "",
    "Notes:",
    "  Checks gleam, moon, moonc (required) and wit-bindgen, wasm-tools (optional).",
  ]
}

fn render_check() -> List(String) {
  [
    "gekko check - Transpile a Gleam project and run `moon check`",
    "",
    "Usage:",
    "  gekko check [--strict] [--target <wasm|wasm-gc|js|native>] [--root <dir>] [--work-dir <dir>]",
    "",
    "Options:",
    "  --strict                      Fail on unimplemented @external functions",
    "  --target <target>             MoonBit target (wasm, wasm-gc, js, native)",
    "  --root <dir>                  Project root directory (default: .)",
    "  --work-dir <dir>              Generated MoonBit workspace directory (default: <root>/build/moonbit)",
    "  --out <dir>                   Backwards-compatible alias for --work-dir",
    "  -h, --help                    Show help",
  ]
}

fn render_build() -> List(String) {
  [
    "gekko build - Transpile and build a MoonBit artifact or library",
    "",
    "Usage:",
    "  gekko build [--strict] [--release] [--target <wasm|wasm-gc|js|native>] [--root <dir>] [--output <path> | -o <path>] [--work-dir <dir>]",
    "",
    "Options:",
    "  --target <target>             Target backend: wasm, wasm-gc, js, native (default: wasm)",
    "  --release                     Build in MoonBit release profile",
    "  -o, --output <path>           Destination file path or directory ending in '/' (alias: --out)",
    "  --strict                      Fail on unimplemented @external functions",
    "  --root <dir>                  Project root directory (default: .)",
    "  --work-dir <dir>              Generated MoonBit workspace directory (default: <root>/build/moonbit)",
    "  -h, --help                    Show help",
    "",
    "Notes:",
    "  Copies the compiled executable/Wasm/JS file into the current directory by default,",
    "  unless the project has no pub fn main() entrypoint.",
  ]
}

fn render_test() -> List(String) {
  [
    "gekko test - Transpile a Gleam project and run `moon test`",
    "",
    "Usage:",
    "  gekko test [--strict] [--target <wasm|wasm-gc|js|native>] [--root <dir>] [--work-dir <dir>]",
    "",
    "Options:",
    "  --strict                      Fail on unimplemented @external functions",
    "  --target <target>             MoonBit target (wasm, wasm-gc, js, native)",
    "  --root <dir>                  Project root directory (default: .)",
    "  --work-dir <dir>              Generated MoonBit workspace directory (default: <root>/build/moonbit)",
    "  --out <dir>                   Backwards-compatible alias for --work-dir",
    "  -h, --help                    Show help",
  ]
}

fn render_run() -> List(String) {
  [
    "gekko run - Transpile and execute main() via `moon run`",
    "",
    "Usage:",
    "  gekko run [--target <wasm|wasm-gc|js|native>] [--root <dir>] [--work-dir <dir>] [-- <args>...]",
    "",
    "Options:",
    "  --target <target>             MoonBit target (wasm, wasm-gc, js, native)",
    "  --root <dir>                  Project root directory (default: .)",
    "  --work-dir <dir>              Generated MoonBit workspace directory (default: <root>/build/moonbit)",
    "  --out <dir>                   Backwards-compatible alias for --work-dir",
    "  -- <args>...                  Arguments forwarded to the executed program",
    "  -h, --help                    Show help",
  ]
}

fn render_wit() -> List(String) {
  [
    "gekko wit - Build and validate WebAssembly Component Model (WIT) projects",
    "",
    "Usage:",
    "  gekko wit <subcommand> [options]",
    "",
    "Subcommands:",
    "  gen       Generate src/wit/*.gleam bindings and starter implementation stubs",
    "  check     Bridge WIT bindings and type-check with MoonBit and wit-bindgen",
    "  build     Bundle a WASI 0.2 / Component Model .wasm artifact via wasm-tools",
    "",
    "Options:",
    "  -h, --help       Show help",
    "",
    "Run 'gekko wit <subcommand> --help' for more information on a subcommand.",
  ]
}

fn render_wit_gen() -> List(String) {
  [
    "gekko wit gen - Generate Gleam WIT bindings and starter stubs",
    "",
    "Usage:",
    "  gekko wit gen [--root <dir>] [--wit <dir>] [--world <name>]",
    "",
    "Options:",
    "  --root <dir>     Project root directory (default: .)",
    "  --wit <dir>      WIT schema directory (default: <root>/wit)",
    "  --world <name>   WIT world name to target",
    "  -h, --help       Show help",
  ]
}

fn render_wit_check() -> List(String) {
  [
    "gekko wit check - Transpile and type-check a WIT component project",
    "",
    "Usage:",
    "  gekko wit check [--root <dir>] [--wit <dir>] [--world <name>] [--work-dir <dir>]",
    "",
    "Options:",
    "  --root <dir>     Project root directory (default: .)",
    "  --wit <dir>      WIT schema directory (default: <root>/wit)",
    "  --world <name>   WIT world name to target",
    "  --work-dir <dir> Generated MoonBit workspace directory (alias: --out)",
    "  -h, --help       Show help",
    "",
    "Notes:",
    "  Requires gleam, moon, and wit-bindgen on PATH.",
  ]
}

fn render_wit_build() -> List(String) {
  [
    "gekko wit build - Compile and bundle a WebAssembly Component (.wasm)",
    "",
    "Usage:",
    "  gekko wit build [--release] [--root <dir>] [--wit <dir>] [--world <name>] [--work-dir <dir>] [--output <file.wasm> | -o <file.wasm>]",
    "",
    "Options:",
    "  --release                 Build MoonBit module in release mode",
    "  -o, --output <file.wasm>  Output component path (default: <root>/dist/<world>.wasm)",
    "  --root <dir>              Project root directory (default: .)",
    "  --wit <dir>               WIT schema directory (default: <root>/wit)",
    "  --world <name>            WIT world name to target",
    "  --work-dir <dir>          Generated MoonBit workspace directory (alias: --out)",
    "  -h, --help                Show help",
    "",
    "Notes:",
    "  Requires gleam, moon, wit-bindgen, and wasm-tools on PATH.",
  ]
}

fn render_moonbit() -> List(String) {
  [
    "gekko moonbit - MoonBit FFI binding tools",
    "",
    "Usage:",
    "  gekko moonbit <subcommand> [options]",
    "",
    "Subcommands:",
    "  bind             Generate Gleam FFI stubs and adapters from a MoonBit package",
    "",
    "Options:",
    "  -h, --help       Show help",
    "",
    "Run 'gekko moonbit <subcommand> --help' for more information on a subcommand.",
  ]
}

fn render_moonbit_bind() -> List(String) {
  [
    "gekko moonbit bind - Generate Gleam FFI stubs (+ optional adapter) from a MoonBit package (.mbti)",
    "",
    "Usage:",
    "  gekko moonbit bind <pkg> [--root <dir>] [--module <gleam_mod>] [--adapter <pkg>] [--only <item> ...] [--map-type <Mbt=Gleam> ...] [--typed-errors] [--work-dir <dir>]",
    "",
    "Arguments:",
    "  <pkg>                    MoonBit package path (e.g. moonbitlang/x/fs)",
    "",
    "Options:",
    "  --module <gleam_mod>     Target Gleam module path under src/",
    "  --adapter <pkg>          Custom MoonBit adapter package directory name under moonbit/",
    "  --only <item>            Bind only matching declarations (repeatable)",
    "  --map-type <Mbt=Gleam>   Map a MoonBit type to an existing Gleam type (repeatable)",
    "  --typed-errors           Preserve MoonBit error types in generated Gleam Result errors",
    "  --root <dir>             Project root directory (default: .)",
    "  --work-dir <dir>         MoonBit staging workspace directory (alias: --out)",
    "  -h, --help               Show help",
  ]
}

fn render_shim() -> List(String) {
  [
    "gekko shim - Create, inspect, and maintain companion shim packages",
    "",
    "Usage:",
    "  gekko shim <subcommand> [options]",
    "",
    "Subcommands:",
    "  new       Create a new companion shim repository for an upstream package",
    "  init      Initialize an existing repository as a companion shim",
    "  inspect   Report patched coverage, unmapped types, missing FFI, and type drift",
    "  patch     Scaffold a patch stub for a declaration or an entire module",
    "  sync      Regenerate //// @patch_mirror(...) upstream mirror modules under src/",
    "  migrate   Migrate legacy single-file patches and moon.pkg imports",
    "  ack       Record or update type drift baselines under patches/.gekko_baseline/",
    "",
    "Options:",
    "  -h, --help       Show help",
    "",
    "Run 'gekko shim <subcommand> --help' for more information on a subcommand.",
  ]
}

fn render_shim_new() -> List(String) {
  [
    "gekko shim new - Create a new companion shim repository for a Hex package",
    "",
    "Usage:",
    "  gekko shim new <pkg> [--root <dir>] [--out <dir> | -o <dir>] [--moonbit]",
    "",
    "Arguments:",
    "  <pkg>            Upstream Gleam package name to shim",
    "",
    "Options:",
    "  -o, --out <dir>  Output directory for the shim repository (alias: --output)",
    "  --moonbit        Generate MoonBit patches/*.mbt stubs instead of Gleam /// @patch stubs",
    "  --root <dir>     Project root used to resolve upstream package metadata (default: .)",
    "  -h, --help       Show help",
  ]
}

fn render_shim_init() -> List(String) {
  [
    "gekko shim init - Initialize a companion shim in an existing repository",
    "",
    "Usage:",
    "  gekko shim init [--root <dir>] [--moonbit]",
    "",
    "Options:",
    "  --moonbit        Generate MoonBit patches/*.mbt stubs instead of Gleam /// @patch stubs",
    "  --root <dir>     Project root directory (default: .)",
    "  -h, --help       Show help",
  ]
}

fn render_shim_inspect() -> List(String) {
  [
    "gekko shim inspect - Inspect shim coverage, unmapped external types, missing FFI, and type drift",
    "",
    "Usage:",
    "  gekko shim inspect [<pkg>] [--root <dir>]",
    "",
    "Arguments:",
    "  [<pkg>]          Upstream package name (defaults to [tools.gekko.shim_for])",
    "",
    "Options:",
    "  --root <dir>     Project root directory (default: .)",
    "  -h, --help       Show help",
  ]
}

fn render_shim_patch() -> List(String) {
  [
    "gekko shim patch - Scaffold a patch stub for one declaration or an entire module",
    "",
    "Usage:",
    "  gekko shim patch <module>.<decl> [--root <dir>] [--moonbit]",
    "  gekko shim patch --module <module> [--root <dir>] [--moonbit]",
    "",
    "Arguments:",
    "  <module>.<decl>  Single declaration to patch (e.g. gleam/dict.get)",
    "",
    "Options:",
    "  --module <mod>   Patch all unmapped declarations in the given module",
    "  --moonbit        Generate MoonBit patches/*.mbt stubs instead of Gleam /// @patch stubs",
    "  --root <dir>     Project root directory (default: .)",
    "  -h, --help       Show help",
  ]
}

fn render_shim_sync() -> List(String) {
  [
    "gekko shim sync - Regenerate //// @patch_mirror(...) upstream mirror modules under src/",
    "",
    "Usage:",
    "  gekko shim sync [--root <dir>]",
    "",
    "Options:",
    "  --root <dir>     Project root directory (default: .)",
    "  -h, --help       Show help",
  ]
}

fn render_shim_migrate() -> List(String) {
  [
    "gekko shim migrate - Migrate legacy single-file patches and patches/**/moon.pkg imports",
    "",
    "Usage:",
    "  gekko shim migrate [--root <dir>]",
    "",
    "Options:",
    "  --root <dir>     Project root directory (default: .)",
    "  -h, --help       Show help",
    "",
    "Notes:",
    "  Moves single-file patches into package directories and imports into gleam.toml",
    "  under [tools.gekko.patches.\"<module>\"].",
  ]
}

fn render_shim_ack() -> List(String) {
  [
    "gekko shim ack - Record or update patches/.gekko_baseline/<module>.toml type baselines",
    "",
    "Usage:",
    "  gekko shim ack [--root <dir>]",
    "",
    "Options:",
    "  --root <dir>     Project root directory (default: .)",
    "  -h, --help       Show help",
  ]
}
