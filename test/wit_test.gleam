import emit/wit_bridge
import filepath
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/cmd
import simplifile
import wit/ast as wit_ast
import wit/gleam_gen
import wit/parser as wit_parser

pub fn wit_parser_and_deps_unit_test() {
  assert wit_ast.kebab_to_snake("my-greeting-error") == "my_greeting_error"
  assert wit_ast.kebab_to_pascal("my-greeting-error") == "MyGreetingError"
  assert wit_ast.kebab_to_screaming("debug-info") == "DEBUG_INFO"
  assert wit_ast.escape_gleam_ident("type") == "type_"
  assert wit_ast.escape_gleam_ident("test") == "test_"
  assert wit_ast.escape_gleam_ident("macro") == "macro_"
  assert wit_ast.escape_gleam_ident("greet") == "greet"
  assert wit_ast.escape_erlang_reserved_module("logger") == "logger_export"
  assert wit_ast.escape_erlang_reserved_module("api") == "api"

  let wit_dir = "build/test_fixtures/wit_parse_test"
  let deps_dir = filepath.join(wit_dir, "deps/ext-log")
  let _ = simplifile.delete(file_or_dir_at: wit_dir)
  assert simplifile.create_directory_all(deps_dir) == Ok(Nil)

  let dep_src =
    "package ext-ns:ext-pkg@0.2.0;\n\n"
    <> "interface ext-logger {\n"
    <> "  enum log-level { debug-info, fatal-err, }\n"
    <> "  write-line: func(lvl: log-level, msg: string);\n"
    <> "}\n"
  let root_src =
    "// Comment header\n"
    <> "/* block /* nested */ comment */\n"
    <> "package my-ns:my-pkg@0.1.0;\n\n"
    <> "interface my-api {\n"
    <> "  use ext-ns:ext-pkg/ext-logger@0.2.0.{log-level};\n"
    <> "  flags access-flags { read-only, write-all }\n"
    <> "  type id-alias = u64;\n"
    <> "  record my-rec {\n"
    <> "    %type: string,\n"
    <> "    flags: access-flags,\n"
    <> "    pair: tuple<string, u32>,\n"
    <> "    raw: list<u8>,\n"
    <> "    note: option<string>,\n"
    <> "  }\n"
    <> "  variant api-err {\n"
    <> "    empty,\n"
    <> "    bad-id(id-alias),\n"
    <> "  }\n"
    <> "  run-ok: func(r: my-rec, lvl: log-level) -> result<my-rec, api-err>;\n"
    <> "  fail-only: func() -> result<_, string>;\n"
    <> "  void-res: func() -> result;\n"
    <> "}\n\n"
    <> "world my-world {\n"
    <> "  import ext-ns:ext-pkg/ext-logger@0.2.0;\n"
    <> "  import host-clock: func() -> u64;\n"
    <> "  export my-api;\n"
    <> "  export ping: func(x: s32) -> s32;\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(deps_dir, "log.wit"),
      contents: dep_src,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(wit_dir, "world.wit"),
      contents: root_src,
    )
    == Ok(Nil)

  let assert Ok(resolved) = wit_parser.load_wit_dir(wit_dir, None)
  assert resolved.root_pkg.namespace == "my-ns"
  assert resolved.root_pkg.name == "my-pkg"
  assert resolved.world.name == "my-world"
  assert list.length(resolved.world.items) == 4
  assert dict.has_key(resolved.interfaces, "my-ns:my-pkg/my-api")
  assert dict.has_key(resolved.interfaces, "ext-ns:ext-pkg/ext-logger")

  let _ = simplifile.delete(file_or_dir_at: wit_dir)
  Nil
}

pub fn wit_gleam_gen_idempotent_stubs_test() {
  let root = "build/test_fixtures/wit_gen_test"
  let wit_dir = filepath.join(root, "wit")
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(wit_dir) == Ok(Nil)

  let world_wit =
    "package demo:sample@0.1.0;\n\n"
    <> "interface host-log {\n"
    <> "  record entry { tag: string, count: u32 }\n"
    <> "  emit: func(e: entry);\n"
    <> "}\n\n"
    <> "interface svc {\n"
    <> "  use host-log.{entry};\n"
    <> "  echo-entry: func(e: entry) -> option<string>;\n"
    <> "}\n\n"
    <> "world sample-world {\n"
    <> "  import host-log;\n"
    <> "  import world-tick: func() -> u32;\n"
    <> "  export svc;\n"
    <> "  export ping: func(n: s32) -> s32;\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(wit_dir, "world.wit"),
      contents: world_wit,
    )
    == Ok(Nil)
  let assert Ok(resolved) = wit_parser.load_wit_dir(wit_dir, None)

  let assert Ok(rep1) = gleam_gen.generate_project_bindings(resolved, root)
  assert list.contains(rep1.written_files, "src/wit/host_log_types.gleam")
  assert list.contains(rep1.written_files, "src/wit/host_log.gleam")
  assert list.contains(rep1.written_files, "src/wit/sample_world_imports.gleam")
  assert list.contains(rep1.created_stubs, "src/svc.gleam")
  assert list.contains(rep1.created_stubs, "src/sample_world.gleam")

  let assert Ok(imp_src) =
    simplifile.read(from: filepath.join(root, "src/wit/host_log.gleam"))
  assert string.contains(
    imp_src,
    "/// @external(moonbit, \"wit_imp_demo_sample_host_log\", \"emit\")",
  )

  // Customize starter stub; second generation must regenerate `src/wit/` and
  // preserve the user's edited `src/svc.gleam` and `src/sample_world.gleam`.
  let custom_stub =
    "// custom user implementation\npub fn ping(n: Int) -> Int { n + 42 }\n"
  assert simplifile.write(
      to: filepath.join(root, "src/sample_world.gleam"),
      contents: custom_stub,
    )
    == Ok(Nil)

  let assert Ok(rep2) = gleam_gen.generate_project_bindings(resolved, root)
  assert list.contains(rep2.written_files, "src/wit/host_log.gleam")
  assert list.contains(rep2.skipped_existing_stubs, "src/svc.gleam")
  assert list.contains(rep2.skipped_existing_stubs, "src/sample_world.gleam")
  let assert Ok(preserved) =
    simplifile.read(from: filepath.join(root, "src/sample_world.gleam"))
  assert preserved == custom_stub

  let _ = simplifile.delete(file_or_dir_at: root)
  Nil
}

pub fn wit_interfaces_import_export_e2e_test() {
  let root = "build/test_fixtures/wit_ifaces"
  let out_dir = "build/test_fixtures/wit_ifaces_mbt"
  let wit_dir = filepath.join(root, "wit")
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  assert simplifile.create_directory_all(wit_dir) == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"wit_ifaces\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(wit_dir, "world.wit"),
      contents: "package demo:ifaces@0.1.0;\n\n"
        <> "interface logger {\n"
        <> "  enum level {\n    info,\n    warn,\n  }\n"
        <> "  log: func(lvl: level, msg: string);\n"
        <> "}\n\n"
        <> "interface types {\n"
        <> "  flags perms {\n    read,\n    write,\n  }\n"
        <> "  record meta {\n    id: u64,\n    perms: perms,\n  }\n"
        <> "}\n\n"
        <> "interface api {\n"
        <> "  use types.{meta};\n\n"
        <> "  record user {\n"
        <> "    name: string,\n"
        <> "    age: u32,\n"
        <> "    tags: list<string>,\n"
        <> "    meta: meta,\n"
        <> "  }\n\n"
        <> "  variant greeting-error {\n"
        <> "    empty-name,\n"
        <> "    too-young(u32),\n"
        <> "  }\n\n"
        <> "  greet: func(u: user) -> result<string, greeting-error>;\n"
        <> "  sum-bytes: func(data: list<u8>) -> u64;\n"
        <> "}\n\n"
        <> "world app {\n"
        <> "  import logger;\n"
        <> "  export api;\n"
        <> "  export ping: func(x: s32) -> s32;\n"
        <> "}\n",
    )
    == Ok(Nil)

  let assert Ok(resolved) = wit_parser.load_wit_dir(wit_dir, None)
  let assert Ok(_) = gleam_gen.generate_project_bindings(resolved, root)

  assert simplifile.write(
      to: filepath.join(root, "src/app.gleam"),
      contents: "pub fn ping(x: Int) -> Int {\n  x + 1\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/api.gleam"),
      contents: "import wit/api_types.{type GreetingError, type User, EmptyName, TooYoung}\n"
        <> "import wit/logger\n"
        <> "import wit/logger_types.{Info, Warn}\n\n"
        <> "pub fn greet(u: User) -> Result(String, GreetingError) {\n"
        <> "  logger.log(Info, \"Checking user \" <> u.name)\n"
        <> "  case u.name == \"\" {\n"
        <> "    True -> {\n"
        <> "      logger.log(Warn, \"Empty user name rejected\")\n"
        <> "      Error(EmptyName)\n"
        <> "    }\n"
        <> "    False ->\n"
        <> "      case u.age < 13 {\n"
        <> "        True -> Error(TooYoung(u.age))\n"
        <> "        False -> {\n"
        <> "          let access = case u.meta.perms.read {\n"
        <> "            True -> \"read\"\n"
        <> "            False -> \"no-read\"\n"
        <> "          }\n"
        <> "          let first_tag = case u.tags {\n"
        <> "            [first, ..] -> first\n"
        <> "            [] -> \"none\"\n"
        <> "          }\n"
        <> "          Ok(\"Hello, \" <> u.name <> \" (\" <> access <> \", \" <> first_tag <> \")\")\n"
        <> "        }\n"
        <> "      }\n"
        <> "  }\n"
        <> "}\n\n"
        <> "pub fn sum_bytes(data: BitArray) -> Int {\n"
        <> "  case data {\n"
        <> "    <<a:8, b:8, _:bytes>> -> a + b\n"
        <> "    <<a:8>> -> a\n"
        <> "    _ -> 0\n"
        <> "  }\n"
        <> "}\n",
    )
    == Ok(Nil)

  let check_gleam = cmd.run(command: "gleam", args: ["check"], cwd: root)
  assert check_gleam.exit_code == 0

  let assert Ok(summary) =
    wit_bridge.bridge_wit_workspace(root, out_dir, wit_dir, None)
  assert summary.project_name == "wit_ifaces"
  assert summary.world_name == "app"

  let check_res =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert check_res.exit_code == 0

  let assert Ok(imp_adapter) =
    simplifile.read(from: filepath.join(
      out_dir,
      "wit_imp_demo_ifaces_logger/wit_imp_demo_ifaces_logger.mbt",
    ))
  assert string.contains(imp_adapter, "@wit_raw.log(")

  let assert Ok(api_stub) =
    simplifile.read(from: filepath.join(
      out_dir,
      "gen/interface/demo/ifaces/api/stub.mbt",
    ))
  assert string.contains(api_stub, "@gleam_export.greet(")
  assert string.contains(api_stub, "@gleam_export.sum_bytes(")

  let assert Ok(world_stub) =
    simplifile.read(from: filepath.join(out_dir, "gen/world/app/stub.mbt"))
  assert string.contains(world_stub, "@gleam_export.ping(")

  let comp_path = filepath.join(out_dir, "dist/app.wasm")
  case wit_bridge.bundle_component(summary, None, comp_path) {
    Ok(built) -> {
      assert built == comp_path
      assert simplifile.is_file(comp_path) == Ok(True)
    }
    Error(msg) -> {
      assert string.contains(msg, "wasm-tools")
      assert string.contains(msg, "gen.wasm")
      assert simplifile.is_file(summary.core_wasm_path) == Ok(True)
    }
  }

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn wit_wasmtime_runtime_e2e_test() {
  let root = "build/test_fixtures/wit_runtime_test"
  let out_dir = "build/test_fixtures/wit_runtime_mbt"
  let wit_dir = filepath.join(root, "wit")
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  assert simplifile.create_directory_all(wit_dir) == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"wit_runtime\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(wit_dir, "world.wit"),
      contents: "package demo:runtime@0.1.0;\n\nworld app {\n  export add: func(a: s32, b: s32) -> s32;\n  export echo-str: func(s: string) -> string;\n}\n",
    )
    == Ok(Nil)

  let assert Ok(resolved) = wit_parser.load_wit_dir(wit_dir, None)
  let assert Ok(_) = gleam_gen.generate_project_bindings(resolved, root)
  assert simplifile.write(
      to: filepath.join(root, "src/app.gleam"),
      contents: "pub fn add(a: Int, b: Int) -> Int {\n  a + b\n}\n\npub fn echo_str(s: String) -> String {\n  \"Hello, \" <> s\n}\n",
    )
    == Ok(Nil)

  let assert Ok(summary) =
    wit_bridge.bridge_wit_workspace(root, out_dir, wit_dir, None)
  let comp_path = filepath.join(out_dir, "dist/app.wasm")
  case wit_bridge.bundle_component(summary, None, comp_path) {
    Ok(built) -> {
      let wt_probe = cmd.run(command: "wasmtime", args: ["--version"], cwd: ".")
      case wt_probe.exit_code {
        0 -> {
          let r_add =
            cmd.run(
              command: "wasmtime",
              args: ["run", "--invoke", "add(20, 22)", built],
              cwd: ".",
            )
          assert r_add.exit_code == 0
          assert string.trim(r_add.output) == "42"

          let r_str =
            cmd.run(
              command: "wasmtime",
              args: ["run", "--invoke", "echo-str(\"Gleam! 🌙\")", built],
              cwd: ".",
            )
          assert r_str.exit_code == 0
          assert string.trim(r_str.output) == "\"Hello, Gleam! 🌙\""
        }
        _ -> Nil
      }
    }
    Error(msg) -> {
      assert string.contains(msg, "wasm-tools")
    }
  }

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn wit_g2w_record_and_flags_roundtrip_test() {
  let root = "build/test_fixtures/wit_g2w_roundtrip"
  let wit_dir = filepath.join(root, "wit")
  let out_dir = filepath.join(root, "build/moonbit")
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(wit_dir) == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"wit_g2w\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(wit_dir, "world.wit"),
      contents: "package demo:g2w@0.1.0;\n\n"
        <> "interface types {\n"
        <> "  flags perms { read, write }\n"
        <> "  record meta { active: bool, perms: perms }\n"
        <> "}\n\n"
        <> "interface api {\n"
        <> "  use types.{meta, perms};\n"
        <> "  roundtrip: func(m: meta) -> meta;\n"
        <> "}\n\n"
        <> "world app {\n"
        <> "  import api;\n"
        <> "  export api;\n"
        <> "}\n",
    )
    == Ok(Nil)

  let assert Ok(resolved) = wit_parser.load_wit_dir(wit_dir, None)
  let assert Ok(_) = gleam_gen.generate_project_bindings(resolved, root)

  assert simplifile.write(
      to: filepath.join(root, "src/api.gleam"),
      contents: "import wit/types_types.{type Meta}\n\n"
        <> "pub fn roundtrip(m: Meta) -> Meta {\n"
        <> "  m\n"
        <> "}\n",
    )
    == Ok(Nil)

  let check_gleam = cmd.run(command: "gleam", args: ["check"], cwd: root)
  assert check_gleam.exit_code == 0

  let assert Ok(summary) =
    wit_bridge.bridge_wit_workspace(root, out_dir, wit_dir, None)
  let assert Ok(_) = wit_bridge.check_wit_workspace(summary)

  let assert Ok(imp_adapter) =
    simplifile.read(from: filepath.join(
      out_dir,
      "wit_imp_demo_g2w_api/wit_imp_demo_g2w_api.mbt",
    ))
  assert string.contains(imp_adapter, "g.active()")
  assert string.contains(imp_adapter, "g.perms()")
  assert string.contains(imp_adapter, "g.read()")
  assert string.contains(imp_adapter, "g.write()")

  let _ = simplifile.delete(file_or_dir_at: root)
  Nil
}

pub fn wit_include_multiversion_and_imported_resource_test() {
  let root = "build/test_fixtures/wit_res_inc"
  let wit_dir = filepath.join(root, "wit")
  let deps_dir = filepath.join(wit_dir, "deps")
  let out_dir = filepath.join(root, "build/moonbit")
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(deps_dir, "v1"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(deps_dir, "v2"))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"wit_res_inc\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  // Two versions of the same dependency interface in wit/deps must not collide
  assert simplifile.write(
      to: filepath.join(deps_dir, "v1/clock.wit"),
      contents: "package ext:clock@0.1.0;\ninterface wall {\n  now: func() -> u32;\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(deps_dir, "v2/clock.wit"),
      contents: "package ext:clock@0.2.0;\ninterface wall {\n  now: func() -> u64;\n}\n",
    )
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(wit_dir, "world.wit"),
      contents: "package demo:resinc@0.1.0;\n\n"
        <> "interface host {\n"
        <> "  resource counter {\n"
        <> "    constructor(init: u32);\n"
        <> "    inc: func(delta: u32) -> u32;\n"
        <> "    make-zero: static func() -> counter;\n"
        <> "  }\n"
        <> "  read-borrowed: func(c: borrow<counter>) -> u32;\n"
        <> "  consume-owned: func(c: own<counter>) -> u32;\n"
        <> "}\n\n"
        <> "world base {\n"
        <> "  import host;\n"
        <> "}\n\n"
        <> "world app {\n"
        <> "  include base;\n"
        <> "  import ext:clock/wall@0.2.0;\n"
        <> "  export run: func(step: u32) -> u64;\n"
        <> "}\n",
    )
    == Ok(Nil)

  let assert Ok(resolved) = wit_parser.load_wit_dir(wit_dir, Some("app"))
  assert dict.has_key(resolved.interfaces, "ext:clock/wall@0.1.0")
  assert dict.has_key(resolved.interfaces, "ext:clock/wall@0.2.0")

  let assert Ok(_) = gleam_gen.generate_project_bindings(resolved, root)

  assert simplifile.write(
      to: filepath.join(root, "src/app.gleam"),
      contents: "import wit/ext/clock/wall\n"
        <> "import wit/host\n\n"
        <> "pub fn run(step: Int) -> Int {\n"
        <> "  let c = host.new_counter(10)\n"
        <> "  let _ = host.counter_inc(c, step)\n"
        <> "  let b = host.read_borrowed(c)\n"
        <> "  let z = host.counter_make_zero()\n"
        <> "  let _ = host.consume_owned(z)\n"
        <> "  host.drop_counter(c)\n"
        <> "  b + wall.now()\n"
        <> "}\n",
    )
    == Ok(Nil)

  let check_gleam = cmd.run(command: "gleam", args: ["check"], cwd: root)
  assert check_gleam.exit_code == 0

  let assert Ok(summary) =
    wit_bridge.bridge_wit_workspace(root, out_dir, wit_dir, Some("app"))
  let check_res =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert check_res.exit_code == 0

  let comp_path = filepath.join(out_dir, "dist/app-rel.wasm")
  case
    wit_bridge.bundle_component_with_profile(
      summary,
      Some("app"),
      comp_path,
      True,
    )
  {
    Ok(built) -> {
      assert built == comp_path
      assert simplifile.is_file(comp_path) == Ok(True)
    }
    Error(msg) -> {
      assert string.contains(msg, "wasm-tools")
    }
  }

  let _ = simplifile.delete(file_or_dir_at: root)
  Nil
}

pub fn wit_exported_resource_reports_clear_error_test() {
  let wit_dir = "build/test_fixtures/wit_exp_res"
  let _ = simplifile.delete(file_or_dir_at: wit_dir)
  assert simplifile.create_directory_all(wit_dir) == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(wit_dir, "world.wit"),
      contents: "package demo:exp@0.1.0;\ninterface g {\n  resource box { constructor(v: s32); }\n}\nworld app { export g; }\n",
    )
    == Ok(Nil)

  let assert Error(err) = wit_parser.load_wit_dir(wit_dir, None)
  assert string.contains(err, "Exported WIT resource")
  let _ = simplifile.delete(file_or_dir_at: wit_dir)
  Nil
}
