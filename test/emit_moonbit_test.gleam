import emit/moonbit
import emit/pkg_config
import emit/prelude_runtime
import emit/trait_bounds
import filepath
import glance
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import index/symbol_table
import lower/desugar
import lower/ir
import lower/tco
import moonbit/ffi_meta
import project/cmd
import project/prepass
import project/workspace
import simplifile
import test_helpers

pub fn prelude_runtime_matches_disk_files_test() {
  let assert Ok(disk_mbt) = simplifile.read("runtime/prelude/gprelude.mbt")
  let assert Ok(disk_pkg) = simplifile.read("runtime/prelude/moon.pkg")
  assert prelude_runtime.gprelude_mbt() == disk_mbt
  assert prelude_runtime.moon_pkg() == disk_pkg
}

pub fn pkg_config_generation_test() {
  assert pkg_config.module_to_pkg_dir("app/auth/token") == "app/auth/token"
  assert pkg_config.module_to_pkg_dir("prelude") == "mod_prelude"
  assert pkg_config.module_to_pkg_dir("gprelude") == "mod_gprelude"
  assert pkg_config.module_to_pkg_dir("gprelude/sub") == "mod_gprelude/sub"

  let mod_str = pkg_config.emit_moon_mod("demo", "0.2.0")
  assert string.contains(mod_str, "name = \"demo\"")
  assert string.contains(mod_str, "version = \"0.2.0\"")

  let pkg_str =
    pkg_config.emit_moon_pkg(
      "demo",
      [
        #("gprelude", "gprelude"),
        #("demo_math", "math"),
        #("demo_math", "math"),
        #("my_org/wit_fs", "my_org_wit_fs"),
      ],
      True,
    )
  assert string.contains(pkg_str, "\"demo/gprelude\" @gprelude,")
  assert string.contains(pkg_str, "\"demo/demo_math\" @math,")
  assert string.contains(pkg_str, "\"my_org/wit_fs\" @my_org_wit_fs,")
  assert string.contains(pkg_str, "pkgtype(kind: \"executable\")")
}

pub fn emit_moonbit_ffi_and_constructs_test() {
  let src =
    "/// @external(moonbit, \"my_org/wit_fs\", \"read_file\")\n"
    <> "pub fn read_file(path: String) -> Result(String, Nil) {\n"
    <> "  Error(Nil)\n"
    <> "}\n"
    <> "\n"
    <> "@external(moonbit, \"wasm:env\", \"host_add\")\n"
    <> "pub fn host_add(a: Int, b: Int) -> Int\n"
    <> "\n"
    <> "pub fn greet(prefix p: String, name n: String) -> String {\n"
    <> "  p <> n\n"
    <> "}\n"
    <> "\n"
    <> "pub fn apply(x: a, f: fn(a) -> b) -> b {\n"
    <> "  f(x)\n"
    <> "}\n"
    <> "\n"
    <> "pub fn wrap_ok(x: Int) -> Result(Int, String) {\n"
    <> "  apply(x, Ok)\n"
    <> "}\n"

  let assert Ok(#(ast_mod, pre_res)) = prepass.parse_module("ffi_mod", src)
  let table =
    symbol_table.index_project(
      "ffi_pkg",
      [#("ffi_mod", ast_mod, pre_res)],
      None,
      dict.new(),
    )
  let ir_mod =
    desugar.desugar_module(ast_mod, table, "ffi_mod")
    |> tco.optimize_module
  let #(mbt, imports) = moonbit.emit_module(ir_mod)

  assert list.contains(imports, #("my_org/wit_fs", "my_org_wit_fs"))
  assert string.contains(mbt, "@my_org_wit_fs.read_file(path)")
  assert string.contains(
    mbt,
    "fn __ffi_host_add(Int64, Int64) -> Int64 = \"env\" \"host_add\"",
  )
  assert string.contains(mbt, "__ffi_host_add(a, b)")
  assert string.contains(
    mbt,
    "pub fn greet(p : String, n : String) -> String {",
  )
  assert string.contains(mbt, "apply(x, fn(__c_0) { Ok(__c_0) })")
}

pub fn runtime_no_unqualified_prelude_calls_test() {
  test_helpers.assert_no_unqualified_prelude_calls(
    prelude_runtime.gprelude_mbt(),
  )
}

pub fn prelude_shadowing_and_reserved_names_e2e_test() {
  let root = "build/test_fixtures/prelude_hardening"
  let out_dir = "build/test_fixtures/prelude_hardening_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"prelude_hardening\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  let lib_src =
    "pub type Error {\n"
    <> "  NotFound\n"
    <> "  Invalid(String)\n"
    <> "}\n\n"
    <> "pub fn abort(msg: String) -> String {\n"
    <> "  \"abort:\" <> msg\n"
    <> "}\n\n"
    <> "pub fn ignore(x: Int) -> Int {\n"
    <> "  x + 1\n"
    <> "}\n\n"
    <> "pub fn println(s: String) -> String {\n"
    <> "  \"println:\" <> s\n"
    <> "}\n\n"
    <> "pub fn module(declare: Int, extern: Int, yield: Int) -> Int {\n"
    <> "  declare + extern + yield\n"
    <> "}\n\n"
    <> "pub fn wrap_err(flag: Bool) -> Result(Int, Error) {\n"
    <> "  case flag {\n"
    <> "    True -> Ok(42)\n"
    <> "    False -> Error(NotFound)\n"
    <> "  }\n"
    <> "}\n"

  let test_src =
    "import prelude_hardening.{Invalid, NotFound}\n\n"
    <> "pub fn main() -> Nil {\n"
    <> "  let _ = prelude_hardening.println(\"ok\")\n"
    <> "  Nil\n"
    <> "}\n\n"
    <> "pub fn shadowing_and_reserved_test() {\n"
    <> "  assert prelude_hardening.abort(\"x\") == \"abort:x\"\n"
    <> "  assert prelude_hardening.ignore(10) == 11\n"
    <> "  assert prelude_hardening.println(\"y\") == \"println:y\"\n"
    <> "  assert prelude_hardening.module(1, 2, 3) == 6\n"
    <> "  let assert Ok(v) = prelude_hardening.wrap_err(True)\n"
    <> "  assert v == 42\n"
    <> "  assert prelude_hardening.wrap_err(False) == Error(NotFound)\n"
    <> "  let e = Invalid(\"bad\")\n"
    <> "  assert e != NotFound\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/prelude_hardening.gleam"),
      contents: lib_src,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/prelude_hardening_test.gleam"),
      contents: test_src,
    )
    == Ok(Nil)

  let assert Ok(summary) = workspace.transpile_project(root, out_dir)
  assert summary.project_name == "prelude_hardening"

  let check_res =
    cmd.run(command: "moon", args: ["check", "--target", "wasm"], cwd: out_dir)
  assert check_res.exit_code == 0

  let test_wasm =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert test_wasm.exit_code == 0
  assert string.contains(test_wasm.output, "passed: 1, failed: 0")

  let test_wasm_gc =
    cmd.run(
      command: "moon",
      args: ["test", "--target", "wasm-gc"],
      cwd: out_dir,
    )
  assert test_wasm_gc.exit_code == 0
  assert string.contains(test_wasm_gc.output, "passed: 1, failed: 0")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn record_update_e2e_test() {
  let root = "build/test_fixtures/record_update"
  let out_dir = "build/test_fixtures/record_update_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"record_update\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  let types_src =
    "pub type Person {\n"
    <> "  Person(name: String, age: Int, tags: List(String))\n"
    <> "}\n\n"
    <> "pub type Shape {\n"
    <> "  Circle(radius: Int, label: String)\n"
    <> "  Rect(w: Int, h: Int, label: String)\n"
    <> "}\n\n"
    <> "pub type Pair {\n"
    <> "  Pair(Int, second: String)\n"
    <> "}\n"

  let lib_src =
    "import record_update/types.{type Person, type Shape, Circle, Person, Rect}\n\n"
    <> "pub fn rename(p: Person, name: String) -> Person {\n"
    <> "  Person(..p, name:)\n"
    <> "}\n\n"
    <> "pub fn birthday(p: Person) -> Person {\n"
    <> "  Person(..p, age: p.age + 1)\n"
    <> "}\n\n"
    <> "pub fn make() -> Person {\n"
    <> "  Person(\"ann\", 30, [\"a\"])\n"
    <> "}\n\n"
    <> "pub fn relabel(s: Shape, label: String) -> Shape {\n"
    <> "  case s {\n"
    <> "    Circle(..) -> Circle(..s, label: label)\n"
    <> "    Rect(..) -> Rect(..s, label: label)\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn from_call() -> Person {\n"
    <> "  Person(..make(), name: \"bob\", tags: [])\n"
    <> "}\n"

  let test_src =
    "import record_update\n"
    <> "import record_update/types.{Circle, Pair, Person, Rect}\n\n"
    <> "pub fn main() -> Nil {\n  Nil\n}\n\n"
    <> "pub fn record_update_test() {\n"
    <> "  let p = record_update.make()\n"
    <> "  assert record_update.rename(p, \"zed\") == Person(\"zed\", 30, [\"a\"])\n"
    <> "  assert record_update.birthday(p) == Person(\"ann\", 31, [\"a\"])\n"
    <> "  assert p == Person(\"ann\", 30, [\"a\"])\n"
    <> "  assert record_update.from_call() == Person(\"bob\", 30, [])\n"
    <> "  let chained = Person(..Person(..p, age: 1), name: \"c\")\n"
    <> "  assert chained == Person(\"c\", 1, [\"a\"])\n"
    <> "  assert record_update.relabel(Circle(2, \"x\"), \"y\") == Circle(2, \"y\")\n"
    <> "  assert record_update.relabel(Rect(1, 2, \"x\"), \"y\") == Rect(1, 2, \"y\")\n"
    <> "  let pr = Pair(7, \"a\")\n"
    <> "  assert Pair(..pr, second: \"b\") == Pair(7, \"b\")\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/record_update.gleam"),
      contents: lib_src,
    )
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(
      root,
      "src/record_update",
    ))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/record_update/types.gleam"),
      contents: types_src,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/record_update_test.gleam"),
      contents: test_src,
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)

  let check_res =
    cmd.run(command: "moon", args: ["check", "--target", "wasm"], cwd: out_dir)
  assert check_res.exit_code == 0

  let test_wasm =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert test_wasm.exit_code == 0
  assert string.contains(test_wasm.output, "passed: 1, failed: 0")

  let test_gc =
    cmd.run(
      command: "moon",
      args: ["test", "--target", "wasm-gc"],
      cwd: out_dir,
    )
  assert test_gc.exit_code == 0
  assert string.contains(test_gc.output, "passed: 1, failed: 0")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn echo_exact_gleam_behavior_e2e_test() {
  let root = "build/test_fixtures/echo_e2e"
  let out_dir = "build/test_fixtures/echo_e2e_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "moonbit/echo_ffi"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"echo_e2e\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  let echo_ffi_mbt =
    "///|\n"
    <> "pub(all) struct MiniMap[K, V] {\n"
    <> "  inner : Map[K, V]\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub impl[K : @gprelude.GleamInspect, V : @gprelude.GleamInspect] @gprelude.GleamInspect for MiniMap[\n"
    <> "  K,\n"
    <> "  V,\n"
    <> "] with gleam_inspect(self) {\n"
    <> "  let mut s = \"mini_map([\"\n"
    <> "  let mut first = true\n"
    <> "  self.inner.each(fn(k, v) {\n"
    <> "    if !first {\n"
    <> "      s = s + \", \"\n"
    <> "    }\n"
    <> "    first = false\n"
    <> "    s = s + \"#(\" + @gprelude.GleamInspect::gleam_inspect(k) + \", \" + @gprelude.GleamInspect::gleam_inspect(v) + \")\"\n"
    <> "  })\n"
    <> "  s + \"])\"\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn[K : Eq + Hash, V] map_singleton(k : K, v : V) -> MiniMap[K, V] {\n"
    <> "  let m : Map[K, V] = Default::default()\n"
    <> "  m.set(k, v)\n"
    <> "  { inner: m }\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn[T : @gprelude.GleamInspect] inspect_val(x : T) -> String {\n"
    <> "  @gprelude.GleamInspect::gleam_inspect(x)\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "moonbit/echo_ffi/echo_ffi.mbt"),
      contents: echo_ffi_mbt,
    )
    == Ok(Nil)

  let src =
    "/// @external_type(moonbit, \"builtin\", \"Option\")\n"
    <> "pub type Maybe(a) {\n"
    <> "  Some(a)\n"
    <> "  None\n"
    <> "}\n\n"
    <> "/// @external_type(moonbit, \"echo_ffi\", \"MiniMap\")\n"
    <> "pub type MiniMap(k, v)\n\n"
    <> "/// @external(moonbit, \"echo_ffi\", \"map_singleton\")\n"
    <> "pub fn map_singleton(k: k, v: v) -> MiniMap(k, v) {\n"
    <> "  let _ = #(k, v)\n"
    <> "  panic as \"mbt\"\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"echo_ffi\", \"inspect_val\")\n"
    <> "pub fn inspect_val(x: a) -> String {\n"
    <> "  let _ = x\n"
    <> "  panic as \"mbt\"\n"
    <> "}\n\n"
    <> "pub type Person {\n"
    <> "  Person(name: String, age: Int, needs_glasses: Bool)\n"
    <> "}\n\n"
    <> "pub type Handler {\n"
    <> "  Handler(label: String, callback: fn(Int) -> Int)\n"
    <> "}\n\n"
    <> "fn generic_echo(x: a) -> a {\n"
    <> "  echo x\n"
    <> "}\n\n"
    <> "pub fn main() -> Nil {\n"
    <> "  let x = echo 41\n"
    <> "  assert x + 1 == 42\n"
    <> "  echo \"bare stmt\"\n"
    <> "  echo 3.0\n"
    <> "  echo True\n"
    <> "  echo False\n"
    <> "  echo Nil\n"
    <> "  echo \"hello \\\"world\\\"\"\n"
    <> "  echo [1, 2, 3]\n"
    <> "  echo #(1, 2.2, \"three\")\n"
    <> "  echo Ok(1)\n"
    <> "  echo Error(Nil)\n"
    <> "  echo Some(\"Nubi\")\n"
    <> "  echo None\n"
    <> "  echo <<3>>\n"
    <> "  echo <<6147:size(16)>>\n"
    <> "  echo Person(\"Amy\", 26, True)\n"
    <> "  echo Handler(\"cb\", fn(n) { n + 1 })\n"
    <> "  echo map_singleton(\"a\", 1)\n"
    <> "  echo 1 + 2 as \"sum msg\"\n"
    <> "  let _ = [1, 2] |> echo\n"
    <> "  let _ = generic_echo(99)\n"
    <> "  assert inspect_val(Person(\"Amy\", 26, True))\n"
    <> "    == \"Person(\\\"Amy\\\", 26, True)\"\n"
    <> "  Nil\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/echo_e2e.gleam"),
      contents: src,
    )
    == Ok(Nil)

  let assert Ok(summary) = workspace.transpile_project(root, out_dir)
  assert summary.project_name == "echo_e2e"

  let assert_echo_output = fn(output: String) {
    assert string.contains(output, "src/echo_e2e.gleam:35\n41\n")
    assert string.contains(output, "src/echo_e2e.gleam:37\n\"bare stmt\"\n")
    assert string.contains(output, "src/echo_e2e.gleam:38\n3.0\n")
    assert string.contains(output, "src/echo_e2e.gleam:39\nTrue\n")
    assert string.contains(output, "src/echo_e2e.gleam:40\nFalse\n")
    assert string.contains(output, "src/echo_e2e.gleam:41\nNil\n")
    assert string.contains(
      output,
      "src/echo_e2e.gleam:42\n\"hello \\\"world\\\"\"\n",
    )
    assert string.contains(output, "src/echo_e2e.gleam:43\n[1, 2, 3]\n")
    assert string.contains(
      output,
      "src/echo_e2e.gleam:44\n#(1, 2.2, \"three\")\n",
    )
    assert string.contains(output, "src/echo_e2e.gleam:45\nOk(1)\n")
    assert string.contains(output, "src/echo_e2e.gleam:46\nError(Nil)\n")
    assert string.contains(output, "src/echo_e2e.gleam:47\nSome(\"Nubi\")\n")
    assert string.contains(output, "src/echo_e2e.gleam:48\nNone\n")
    assert string.contains(output, "src/echo_e2e.gleam:49\n<<3>>\n")
    assert string.contains(output, "src/echo_e2e.gleam:50\n<<24, 3>>\n")
    assert string.contains(
      output,
      "src/echo_e2e.gleam:51\nPerson(\"Amy\", 26, True)\n",
    )
    assert string.contains(output, "src/echo_e2e.gleam:52\nHandler(\"cb\",")
    assert string.contains(
      output,
      "src/echo_e2e.gleam:53\nmini_map([#(\"a\", 1)])\n",
    )
    assert string.contains(output, "src/echo_e2e.gleam:54 sum msg\n3\n")
    assert string.contains(output, "src/echo_e2e.gleam:55\n[1, 2]\n")
    assert string.contains(output, "src/echo_e2e.gleam:31\n99\n")
  }

  let run_wasm =
    cmd.run(
      command: "moon",
      args: ["run", "echo_e2e", "--target", "wasm"],
      cwd: out_dir,
    )
  assert run_wasm.exit_code == 0
  assert_echo_output(run_wasm.output)

  let run_js =
    cmd.run(
      command: "moon",
      args: ["run", "echo_e2e", "--target", "js"],
      cwd: out_dir,
    )
  assert run_js.exit_code == 0
  assert_echo_output(run_js.output)

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn emit_guard_tuples_and_inspect_fn_test() {
  let match_expr =
    ir.IrMatch(subjects: [ir.IrVar("x")], clauses: [
      ir.IrClause(
        patterns: [[ir.IrPatInt("1")]],
        guard: None,
        prefix_bindings: [],
        body: ir.IrBool(True),
      ),
      ir.IrClause(
        patterns: [[ir.IrPatDiscard]],
        guard: None,
        prefix_bindings: [],
        body: ir.IrBool(False),
      ),
    ])
  let show_call =
    ir.IrCall(
      function: ir.IrModuleRef(
        module_alias: Some("fmt"),
        target_module: "fmt",
        symbol: "show",
      ),
      args: [
        ir.IrCallArg(
          label: None,
          value: ir.IrTuple([
            ir.IrFn(
              params: [ir.IrFnParam("a", None), ir.IrFnParam("b", None)],
              return_type: None,
              body: [ir.IrStmtExpr(ir.IrUnit)],
            ),
            ir.IrConstructor(
              module_alias: None,
              target_module: None,
              name: "Ok",
            ),
          ]),
        ),
      ],
    )
  let fmt_mod =
    ir.IrModule(
      module_name: "fmt",
      package_name: "demo",
      imports: [],
      types: [],
      type_aliases: [],
      getters: [],
      constants: [],
      functions: [
        ir.IrFunction(
          name: "show",
          unmangled_name: "show",
          publicity: glance.Public,
          type_params: ["T0"],
          params: [
            ir.IrParam(label: None, name: "x", param_type: ir.IrTypeVar("T0")),
          ],
          return_type: ir.IrTypeString,
          ffi: Some(prepass.PackageCall("custom_fmt", "show_any")),
          external: True,
          body: [],
        ),
      ],
    )
  let mod =
    ir.IrModule(
      module_name: "demo",
      package_name: "demo",
      imports: [],
      types: [],
      type_aliases: [],
      getters: [],
      constants: [],
      functions: [
        ir.IrFunction(
          name: "check_emit",
          unmangled_name: "check_emit",
          publicity: glance.Public,
          type_params: [],
          params: [
            ir.IrParam(label: None, name: "x", param_type: ir.IrTypeInt64),
            ir.IrParam(label: None, name: "t0", param_type: ir.IrTypeTuple([])),
            ir.IrParam(
              label: None,
              name: "t1",
              param_type: ir.IrTypeTuple([ir.IrTypeInt64]),
            ),
          ],
          return_type: ir.IrTypeBool,
          ffi: None,
          external: False,
          body: [
            ir.IrStmtGuard(
              value: match_expr,
              pattern: ir.IrPatBool(True),
              guard_condition: None,
              abort_message: None,
              post_bindings: [],
            ),
            ir.IrStmtExpr(show_call),
            ir.IrStmtExpr(ir.IrTuple([])),
            ir.IrStmtExpr(ir.IrTuple([ir.IrInt("7")])),
            ir.IrStmtGuard(
              value: ir.IrBool(True),
              pattern: ir.IrPatBool(True),
              guard_condition: None,
              abort_message: None,
              post_bindings: [],
            ),
          ],
        ),
      ],
    )
  let meta =
    ffi_meta.scan_mbt_source(
      ffi_meta.base_metadata(),
      "custom_fmt",
      "///|\npub fn[T : @gprelude.GleamInspect] show_any(x : T) -> String {\n  @gprelude.GleamInspect::gleam_inspect(x)\n}\n",
    )
  let bounds = trait_bounds.analyze_project([fmt_mod, mod], None, meta)
  let #(code, _) = moonbit.emit_module_with_context(mod, None, meta, bounds)
  assert string.contains(code, "guard (match x {")
  assert string.contains(code, "@gprelude.Tuple0")
  assert string.contains(code, "@gprelude.Tuple1[Int64]")
  assert string.contains(code, "@gprelude.Tuple1(7L)")
  assert string.contains(
    code,
    "@fmt.show((@gprelude.inspect_fn(2), @gprelude.inspect_fn(1)))",
  )
  assert string.contains(code, "let __gekko_assert_val = true")
  assert string.contains(code, "guard __gekko_assert_val is true")
}

pub fn int_div_rem_int64_min_e2e_test() {
  let root = "build/test_fixtures/int_div_min"
  let out_dir = "build/test_fixtures/int_div_min_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"int_div_min\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  let lib_src =
    "pub fn div(a: Int, b: Int) -> Int {\n"
    <> "  a / b\n"
    <> "}\n\n"
    <> "pub fn rem(a: Int, b: Int) -> Int {\n"
    <> "  a % b\n"
    <> "}\n"

  let test_src =
    "import int_div_min\n\n"
    <> "pub fn main() -> Nil {\n"
    <> "  Nil\n"
    <> "}\n\n"
    <> "pub fn int_div_rem_min_test() {\n"
    <> "  let min = -9_223_372_036_854_775_808\n"
    <> "  assert int_div_min.div(min, -1) == min\n"
    <> "  assert int_div_min.rem(min, -1) == 0\n"
    <> "  assert -9_223_372_036_854_775_808 / -1 == min\n"
    <> "  assert -9_223_372_036_854_775_808 % -1 == 0\n"
    <> "  assert int_div_min.div(min, 0) == 0\n"
    <> "  assert int_div_min.rem(min, 0) == 0\n"
    <> "  assert int_div_min.div(10, -1) == -10\n"
    <> "  assert int_div_min.div(-10, -1) == 10\n"
    <> "  assert int_div_min.rem(10, -1) == 0\n"
    <> "  assert int_div_min.rem(-10, -1) == 0\n"
    <> "  let matched = case min {\n"
    <> "    -9_223_372_036_854_775_808 -> True\n"
    <> "    _ -> False\n"
    <> "  }\n"
    <> "  assert matched\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/int_div_min.gleam"),
      contents: lib_src,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/int_div_min_test.gleam"),
      contents: test_src,
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)

  list.each(["wasm", "wasm-gc", "js", "native"], fn(target) {
    let chk =
      cmd.run(
        command: "moon",
        args: ["check", "--deny-warn", "--target", target],
        cwd: out_dir,
      )
    assert chk.exit_code == 0

    let run =
      cmd.run(command: "moon", args: ["test", "--target", target], cwd: out_dir)
    assert run.exit_code == 0
    assert string.contains(run.output, "passed: 1, failed: 0")
  })

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn private_chained_type_aliases_and_string_escapes_test() {
  let src =
    "type Base = Int\n"
    <> "type Alias = Base\n"
    <> "pub fn use_alias(x: Alias) -> String {\n"
    <> "  let local_val: Alias = x\n"
    <> "  let f = fn(y: Alias) { y }\n"
    <> "  let _ = f(local_val)\n"
    <> "  \"\\\\{escaped}\"\n"
    <> "}\n"

  let assert Ok(#(ast_mod, pre)) = prepass.parse_module("app", src)
  let table =
    symbol_table.index_project(
      "app",
      [#("app", ast_mod, pre)],
      None,
      dict.new(),
    )
  let ir_mod = desugar.desugar_module(ast_mod, table, "app")
  let #(mbt, _) = moonbit.emit_module_with_table(ir_mod, table)
  assert string.contains(mbt, "type Base = Int64")
  assert string.contains(mbt, "type Alias = Base")
  assert !string.contains(mbt, "priv type ")
  assert string.contains(mbt, "\"\\\\{escaped}\"")
  assert !string.contains(mbt, "\"\\\\\\{escaped}\"")
}

pub fn pkg_config_nested_local_pkgs_test() {
  let mpkg =
    pkg_config.emit_moon_pkg_with_local_pkgs(
      "my_app",
      [#("nested/ffi", "nested_ffi"), #("moonbitlang/core/math", "math")],
      False,
      set.from_list(["nested/ffi"]),
    )
  assert string.contains(mpkg, "\"my_app/nested/ffi\" @nested_ffi,")
  assert string.contains(mpkg, "\"moonbitlang/core/math\" @math,")
}

pub fn gprelude_dynmap_hash_and_charlist_inspect_test() {
  let mbt = prelude_runtime.gprelude_mbt()
  assert string.contains(
    mbt,
    "sum = sum + (Hash::hash(k) * 31 + Hash::hash(v))",
  )
  assert string.contains(
    mbt,
    "\"charlist.from_string(\" + escape_gleam_string(char_buf.to_string()) + \")\"",
  )
}

pub fn local_closure_shadowing_inspect_sink_test() {
  let src =
    "pub fn wrap_show(x: a) -> String {\n"
    <> "  echo x\n"
    <> "  \"ok\"\n"
    <> "}\n\n"
    <> "pub fn caller() -> Int {\n"
    <> "  let wrap_show = fn(f: fn(Int) -> Int) -> Int { f(1) }\n"
    <> "  wrap_show(fn(x) { x + 1 })\n"
    <> "}\n"
  let assert Ok(#(ast_mod, pre)) = prepass.parse_module("app", src)
  let table =
    symbol_table.index_project(
      "app",
      [#("app", ast_mod, pre)],
      None,
      dict.new(),
    )
  let ir_mod = desugar.desugar_module(ast_mod, table, "app")
  let #(mbt, _) = moonbit.emit_module_with_table(ir_mod, table)
  assert !string.contains(mbt, "wrap_show(@gprelude.inspect_fn")
  assert string.contains(mbt, "wrap_show(fn(x : Int64) {")
}

pub fn polymorphic_constants_e2e_test() {
  let root = "build/test_fixtures/poly_consts"
  let out_dir = "build/test_fixtures/poly_consts_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"poly_consts\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  let defs_src = "pub const empty = []\n" <> "pub const ok_zero = Ok(0)\n"

  let main_src =
    "import defs\n\n"
    <> "pub const local_empty = []\n\n"
    <> "pub fn check_all() -> Bool {\n"
    <> "  let xs: List(Int) = defs.empty\n"
    <> "  let ys: List(String) = local_empty\n"
    <> "  let r1: Result(Int, String) = defs.ok_zero\n"
    <> "  let r2: Result(Int, Bool) = defs.ok_zero\n"
    <> "  xs == [] && ys == [] && r1 == Ok(0) && r2 == Ok(0)\n"
    <> "}\n"

  let test_src =
    "import poly_consts\n\n"
    <> "pub fn main() -> Nil {\n  Nil\n}\n\n"
    <> "pub fn poly_consts_e2e_test() {\n"
    <> "  assert poly_consts.check_all()\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/defs.gleam"),
      contents: defs_src,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/poly_consts.gleam"),
      contents: main_src,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/poly_consts_check.gleam"),
      contents: test_src,
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)

  list.each(["wasm", "wasm-gc"], fn(target) {
    let chk =
      cmd.run(
        command: "moon",
        args: ["check", "--deny-warn", "--target", target],
        cwd: out_dir,
      )
    assert chk.exit_code == 0

    let run =
      cmd.run(command: "moon", args: ["test", "--target", target], cwd: out_dir)
    assert run.exit_code == 0
    assert string.contains(run.output, "passed: 1, failed: 0")
  })

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn labeled_args_and_saturated_pipe_eval_order_e2e_test() {
  let root = "build/test_fixtures/eval_order"
  let out_dir = "build/test_fixtures/eval_order_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"eval_order\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  let lib_src =
    "pub fn sub(first a: Int, second b: Int) -> Int {\n"
    <> "  a - b\n"
    <> "}\n\n"
    <> "pub fn make_adder(x: Int) -> fn(Int) -> Int {\n"
    <> "  fn(y) { x + y }\n"
    <> "}\n\n"
    <> "pub fn step(n: Int) -> Int {\n"
    <> "  case n {\n"
    <> "    0 -> panic as \"boom_0\"\n"
    <> "    1 -> 10\n"
    <> "    _ -> n\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn call_reordered(a: Int, b: Int) -> Int {\n"
    <> "  sub(second: step(a), first: step(b))\n"
    <> "}\n\n"
    <> "pub fn pipe_saturated(a: Int, b: Int) -> Int {\n"
    <> "  step(a) |> make_adder(step(b))\n"
    <> "}\n"

  let test_src =
    "import eval_order\n\n"
    <> "pub fn main() -> Nil {\n  Nil\n}\n\n"
    <> "pub fn eval_order_e2e_test() {\n"
    <> "  assert eval_order.call_reordered(1, 2) == -8\n"
    <> "  assert eval_order.pipe_saturated(1, 2) == 12\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/eval_order.gleam"),
      contents: lib_src,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/eval_order_check.gleam"),
      contents: test_src,
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)
  let assert Ok(mbt) =
    simplifile.read(from: filepath.join(out_dir, "eval_order/eval_order.mbt"))
  assert string.contains(mbt, "let __gekko_arg_0 = step(a)")
  assert string.contains(mbt, "let __pipe_lhs_")

  list.each(["wasm", "wasm-gc"], fn(target) {
    let chk =
      cmd.run(
        command: "moon",
        args: ["check", "--deny-warn", "--target", target],
        cwd: out_dir,
      )
    assert chk.exit_code == 0

    let run =
      cmd.run(command: "moon", args: ["test", "--target", target], cwd: out_dir)
    assert run.exit_code == 0
    assert string.contains(run.output, "passed: 1, failed: 0")
  })

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn trait_bounds_unify_shared_external_type_aliases_test() {
  let ext_hashmap =
    Some(prepass.ExternalType(
      package: "moonbitlang/core/immut/hashmap",
      type_name: "HashMap",
    ))
  let ffi_hashmap_ty = fn(k, v) {
    ir.IrTypeNamed(
      module_alias: Some("mhashmap"),
      package: "demo",
      module: "my_ffi/hashmap",
      name: "HashMap",
      args: [k, v],
    )
  }
  let dict_ty = fn(k, v) {
    ir.IrTypeNamed(
      module_alias: None,
      package: "demo",
      module: "my_dict",
      name: "Dict",
      args: [k, v],
    )
  }

  let ffi_map_mod =
    ir.IrModule(
      module_name: "my_ffi/hashmap",
      package_name: "demo",
      imports: [],
      types: [
        ir.IrTypeDef(
          name: "HashMap",
          unmangled_name: "HashMap",
          publicity: glance.Public,
          opaque_: False,
          type_params: ["k", "v"],
          variants: [],
          external_type: ext_hashmap,
          derive_eq_debug_hash: False,
        ),
      ],
      type_aliases: [],
      getters: [],
      constants: [],
      functions: [
        ir.IrFunction(
          name: "put",
          unmangled_name: "put",
          publicity: glance.Public,
          type_params: ["T0", "T1"],
          params: [
            ir.IrParam(
              label: None,
              name: "map",
              param_type: ffi_hashmap_ty(ir.IrTypeVar("T0"), ir.IrTypeVar("T1")),
            ),
            ir.IrParam(label: None, name: "key", param_type: ir.IrTypeVar("T0")),
            ir.IrParam(
              label: None,
              name: "value",
              param_type: ir.IrTypeVar("T1"),
            ),
          ],
          return_type: ffi_hashmap_ty(ir.IrTypeVar("T0"), ir.IrTypeVar("T1")),
          ffi: Some(prepass.PackageCall("my_ffi_pkg", "put")),
          external: True,
          body: [],
        ),
      ],
    )

  let dict_mod =
    ir.IrModule(
      module_name: "my_dict",
      package_name: "demo",
      imports: [ir.IrImport(module: "my_ffi/hashmap", alias: Some("mhashmap"))],
      types: [
        ir.IrTypeDef(
          name: "Dict",
          unmangled_name: "Dict",
          publicity: glance.Public,
          opaque_: False,
          type_params: ["k", "v"],
          variants: [],
          external_type: ext_hashmap,
          derive_eq_debug_hash: False,
        ),
      ],
      type_aliases: [],
      getters: [],
      constants: [],
      functions: [
        ir.IrFunction(
          name: "fold",
          unmangled_name: "fold",
          publicity: glance.Public,
          type_params: ["T0", "T1", "T2"],
          params: [
            ir.IrParam(
              label: None,
              name: "d",
              param_type: ffi_hashmap_ty(ir.IrTypeVar("T0"), ir.IrTypeVar("T1")),
            ),
            ir.IrParam(
              label: None,
              name: "init",
              param_type: ir.IrTypeVar("T2"),
            ),
            ir.IrParam(
              label: None,
              name: "fun",
              param_type: ir.IrTypeFn(
                [ir.IrTypeVar("T2"), ir.IrTypeVar("T0"), ir.IrTypeVar("T1")],
                ir.IrTypeVar("T2"),
              ),
            ),
          ],
          return_type: ir.IrTypeVar("T2"),
          ffi: Some(prepass.PackageCall("my_ffi_pkg", "fold")),
          external: True,
          body: [],
        ),
        ir.IrFunction(
          name: "combine",
          unmangled_name: "combine",
          publicity: glance.Public,
          type_params: ["T0", "T1"],
          params: [
            ir.IrParam(
              label: None,
              name: "d",
              param_type: dict_ty(ir.IrTypeVar("T0"), ir.IrTypeVar("T1")),
            ),
            ir.IrParam(
              label: None,
              name: "acc",
              param_type: dict_ty(ir.IrTypeVar("T0"), ir.IrTypeVar("T1")),
            ),
          ],
          return_type: dict_ty(ir.IrTypeVar("T0"), ir.IrTypeVar("T1")),
          ffi: None,
          external: False,
          body: [
            ir.IrStmtExpr(
              ir.IrCall(function: ir.IrVar("fold"), args: [
                ir.IrCallArg(label: None, value: ir.IrVar("d")),
                ir.IrCallArg(label: None, value: ir.IrVar("acc")),
                ir.IrCallArg(
                  label: None,
                  value: ir.IrFn(
                    params: [
                      ir.IrFnParam("a", None),
                      ir.IrFnParam("key", None),
                      ir.IrFnParam("val", None),
                    ],
                    return_type: None,
                    body: [
                      ir.IrStmtExpr(
                        ir.IrCall(
                          function: ir.IrModuleRef(
                            module_alias: Some("mhashmap"),
                            target_module: "my_ffi/hashmap",
                            symbol: "put",
                          ),
                          args: [
                            ir.IrCallArg(label: None, value: ir.IrVar("a")),
                            ir.IrCallArg(label: None, value: ir.IrVar("key")),
                            ir.IrCallArg(label: None, value: ir.IrVar("val")),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ]),
            ),
          ],
        ),
      ],
    )

  let meta =
    ffi_meta.scan_mbt_source(
      ffi_meta.base_metadata(),
      "my_ffi_pkg",
      "///|\npub fn[K : Eq + Hash, V] put(\n  map : @hashmap.HashMap[K, V],\n  key : K,\n  value : V,\n) -> @hashmap.HashMap[K, V] {\n  map.add(key, value)\n}\n\n///|\npub fn[K, V, Acc] fold(\n  map : @hashmap.HashMap[K, V],\n  init : Acc,\n  fun : (Acc, K, V) -> Acc,\n) -> Acc {\n  map.fold(init~, fun)\n}\n",
    )

  let bounds = trait_bounds.analyze_project([ffi_map_mod, dict_mod], None, meta)
  let combine_bounds =
    trait_bounds.lookup_fn_bounds(bounds, "my_dict", "combine")
  assert set.contains(combine_bounds.eq_vars, "T0")
}

pub fn gprelude_iterative_list_tuples_and_to_dynamic_e2e_test() {
  let root = "build/test_fixtures/gprelude_extra"
  let out_dir = "build/test_fixtures/gprelude_extra_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "moonbit/dyn_ffi"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"gprelude_extra\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  let mbt_pkg =
    "import {\n"
    <> "  \"gprelude_extra/gprelude\" @gprelude,\n"
    <> "  \"moonbitlang/core/immut/hashmap\" @immut_hashmap,\n"
    <> "}\n"
  let mbt_src =
    "///|\n"
    <> "pub fn[T : Hash] hash_value(x : T) -> Int64 {\n"
    <> "  Hash::hash(x).to_int64()\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn[T : @gprelude.GleamInspect] inspect_val(x : T) -> String {\n"
    <> "  @gprelude.GleamInspect::gleam_inspect(x)\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn[T : @gprelude.ToDynamic] to_dyn_inspect(x : T) -> String {\n"
    <> "  @gprelude.GleamInspect::gleam_inspect(@gprelude.to_dynamic(x))\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn map_to_dyn_inspect() -> String {\n"
    <> "  let m = @immut_hashmap.HashMap([(\"k\", 1L)])\n"
    <> "  @gprelude.GleamInspect::gleam_inspect(@gprelude.to_dynamic(m))\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "moonbit/dyn_ffi/moon.pkg"),
      contents: mbt_pkg,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "moonbit/dyn_ffi/dyn_ffi.mbt"),
      contents: mbt_src,
    )
    == Ok(Nil)

  let gleam_src =
    "/// @external(moonbit, \"dyn_ffi\", \"hash_value\")\n"
    <> "pub fn hash_value(x: a) -> Int {\n"
    <> "  let _ = x\n"
    <> "  panic as \"mbt\"\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"dyn_ffi\", \"inspect_val\")\n"
    <> "pub fn inspect_val(x: a) -> String {\n"
    <> "  let _ = x\n"
    <> "  panic as \"mbt\"\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"dyn_ffi\", \"to_dyn_inspect\")\n"
    <> "pub fn to_dyn_inspect(x: a) -> String {\n"
    <> "  let _ = x\n"
    <> "  panic as \"mbt\"\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"dyn_ffi\", \"map_to_dyn_inspect\")\n"
    <> "pub fn map_to_dyn_inspect() -> String {\n"
    <> "  panic as \"mbt\"\n"
    <> "}\n\n"
    <> "pub fn make_range(n: Int, acc: List(Int)) -> List(Int) {\n"
    <> "  case n <= 0 {\n"
    <> "    True -> acc\n"
    <> "    False -> make_range(n - 1, [n, ..acc])\n"
    <> "  }\n"
    <> "}\n"

  let test_src =
    "import gprelude_extra\n\n"
    <> "pub fn main() -> Nil {\n  Nil\n}\n\n"
    <> "pub fn gprelude_extra_e2e_test() {\n"
    <> "  let xs = gprelude_extra.make_range(20_000, [])\n"
    <> "  let ys = gprelude_extra.make_range(20_000, [])\n"
    <> "  let zs = [0, ..ys]\n"
    <> "  assert xs == ys\n"
    <> "  assert xs != zs\n"
    <> "  assert gprelude_extra.hash_value(xs) == gprelude_extra.hash_value(ys)\n"
    <> "  let t7 = #(1, 2, 3, 4, 5, 6, 7)\n"
    <> "  let t8 = #(1, 2, 3, 4, 5, 6, 7, 8)\n"
    <> "  assert gprelude_extra.inspect_val(t7) == \"#(1, 2, 3, 4, 5, 6, 7)\"\n"
    <> "  assert gprelude_extra.inspect_val(t8) == \"#(1, 2, 3, 4, 5, 6, 7, 8)\"\n"
    <> "  assert gprelude_extra.to_dyn_inspect(#()) == \"[]\"\n"
    <> "  assert gprelude_extra.to_dyn_inspect(#(42)) == \"[42]\"\n"
    <> "  assert gprelude_extra.to_dyn_inspect(#(1, \"two\")) == \"[1, \\\"two\\\"]\"\n"
    <> "  assert gprelude_extra.to_dyn_inspect(t7) == \"[1, 2, 3, 4, 5, 6, 7]\"\n"
    <> "  assert gprelude_extra.to_dyn_inspect(t8) == \"[1, 2, 3, 4, 5, 6, 7, 8]\"\n"
    <> "  assert gprelude_extra.to_dyn_inspect(Ok(9)) == \"[\\\"ok\\\", 9]\"\n"
    <> "  assert gprelude_extra.to_dyn_inspect(Error(\"bad\")) == \"[\\\"error\\\", \\\"bad\\\"]\"\n"
    <> "  assert gprelude_extra.map_to_dyn_inspect() == \"dict.from_list([#(\\\"k\\\", 1)])\"\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/gprelude_extra.gleam"),
      contents: gleam_src,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/gprelude_extra_check.gleam"),
      contents: test_src,
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)
  test_helpers.assert_all_moonbit_targets_ok(out_dir, "passed: 1, failed: 0")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn opaque_type_referencing_private_type_emits_valid_visibility_test() {
  let src =
    "pub opaque type OpaqueBox {\n"
    <> "  OpaqueBox(mode: InnerMode, count: Int)\n"
    <> "}\n\n"
    <> "type InnerMode {\n"
    <> "  Direct(InnerDetail)\n"
    <> "}\n\n"
    <> "type InnerDetail {\n"
    <> "  Fast\n"
    <> "  Slow\n"
    <> "}\n\n"
    <> "type UnusedPrivate {\n"
    <> "  Unused\n"
    <> "}\n\n"
    <> "pub fn make() -> OpaqueBox {\n"
    <> "  OpaqueBox(mode: Direct(Fast), count: 1)\n"
    <> "}\n"

  let assert Ok(#(ast_mod, pre)) = prepass.parse_module("opaque_mod", src)
  let table =
    symbol_table.index_project(
      "opaque_pkg",
      [#("opaque_mod", ast_mod, pre)],
      None,
      dict.new(),
    )
  let ir_mod = desugar.desugar_module(ast_mod, table, "opaque_mod")
  let #(mbt, _) = moonbit.emit_module_with_table(ir_mod, table)

  assert string.contains(mbt, "pub enum OpaqueBox {")
  assert string.contains(mbt, "pub enum InnerMode {")
  assert string.contains(mbt, "pub enum InnerDetail {")
  assert !string.contains(mbt, "pub(all) enum InnerMode")
  assert !string.contains(mbt, "pub(all) enum InnerDetail")
  assert string.contains(mbt, "priv enum UnusedPrivate {")
  assert string.contains(mbt, "fn OpaqueBox::mode(self : OpaqueBox)")
  assert !string.contains(mbt, "pub fn OpaqueBox::mode(")
}

pub fn type_param_matching_local_type_name_is_prefixed_test() {
  let src =
    "pub type Definition(definition) {\n"
    <> "  Definition(value: definition)\n"
    <> "}\n"

  let assert Ok(#(ast_mod, pre)) = prepass.parse_module("def_mod", src)
  let table =
    symbol_table.index_project(
      "def_pkg",
      [#("def_mod", ast_mod, pre)],
      None,
      dict.new(),
    )
  let ir_mod = desugar.desugar_module(ast_mod, table, "def_mod")
  let #(mbt, _) = moonbit.emit_module_with_table(ir_mod, table)

  assert string.contains(mbt, "pub(all) enum Definition[T_Definition] {")
  assert string.contains(
    mbt,
    "for Definition[T_Definition] with gleam_inspect(self)",
  )
  assert string.contains(
    mbt,
    "pub fn[T_Definition] Definition::value(self : Definition[T_Definition]) -> T_Definition",
  )
  assert !string.contains(mbt, "Definition[Definition]")
}
