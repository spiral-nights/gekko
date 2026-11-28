import filepath
import gekko
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import moonbit/bindgen
import moonbit/bindgen_adapter.{BindOptions}
import moonbit/ffi_meta
import moonbit/mbti
import moonbit/syntax
import project/cmd
import project/moonbit_ffi
import project/workspace
import simplifile

pub fn moonbit_ffi_collision_and_loose_file_error_test() {
  let root = "build/test_fixtures/mbt_ffi_errors"
  let out_dir = "build/test_fixtures/mbt_ffi_errors_out"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  // 1. Loose .mbt file in moonbit/ root must fail clearly.
  assert simplifile.create_directory_all(filepath.join(root, "moonbit"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "moonbit/stray.mbt"),
      contents: "pub fn x() -> Int { 1 }\n",
    )
    == Ok(Nil)
  let assert Error(loose_err) =
    moonbit_ffi.copy_local_packages(
      root,
      "demo",
      out_dir,
      set.from_list(["gprelude"]),
    )
  assert string.contains(loose_err, "Loose MoonBit file 'stray.mbt'")

  // 2. Package colliding with gprelude must fail clearly.
  let _ = simplifile.delete_file(at: filepath.join(root, "moonbit/stray.mbt"))
  assert simplifile.create_directory_all(filepath.join(root, "moonbit/gprelude"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "moonbit/gprelude/bad.mbt"),
      contents: "pub fn x() -> Int { 1 }\n",
    )
    == Ok(Nil)
  let assert Error(prelude_err) =
    moonbit_ffi.copy_local_packages(
      root,
      "demo",
      out_dir,
      set.from_list(["gprelude"]),
    )
  assert string.contains(
    prelude_err,
    "collides with generated package directory 'gprelude'",
  )

  // 3. Package colliding with a Gleam module directory in workspace.transpile_project must fail.
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "moonbit/demo"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"demo\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/demo.gleam"),
      contents: "pub fn main() -> Nil { Nil }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "moonbit/demo/extra.mbt"),
      contents: "pub fn x() -> Int { 1 }\n",
    )
    == Ok(Nil)
  let assert Error(mod_err) = workspace.transpile_project(root, out_dir)
  assert string.contains(
    mod_err,
    "collides with generated package directory 'demo'",
  )

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn moonbit_local_and_core_ffi_e2e_test() {
  let root = "build/test_fixtures/local_ffi"
  let out_dir = "build/test_fixtures/local_ffi_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "moonbit/auto_pkg"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(
      root,
      "moonbit/custom_pkg",
    ))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"local_ffi\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  let auto_pkg_mbt =
    "///|\n"
    <> "pub fn sum_list(xs : @gprelude.GList[Int64]) -> Int64 {\n"
    <> "  for cur = xs, acc = 0L {\n"
    <> "    match cur {\n"
    <> "      @gprelude.Nil => break acc\n"
    <> "      @gprelude.Cons(h, t) => continue t, acc + h\n"
    <> "    }\n"
    <> "  }\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub(all) struct Counter {\n"
    <> "  mut count : Int64\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn new_counter(start : Int64) -> Counter {\n"
    <> "  { count: start }\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn bump_counter(c : Counter, delta : Int64) -> Unit {\n"
    <> "  c.count = c.count + delta\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn read_counter(c : Counter) -> Int64 {\n"
    <> "  c.count\n"
    <> "}\n"

  let custom_pkg_cfg =
    "import {\n"
    <> "  \"local_ffi/gprelude\" @gprelude,\n"
    <> "  \"moonbitlang/core/buffer\" @buffer,\n"
    <> "}\n"

  let custom_pkg_mbt =
    "///|\n"
    <> "pub fn repeat_utf8_len(s : String, times : Int64) -> Int64 {\n"
    <> "  let buf = @buffer.Buffer()\n"
    <> "  let n = times.to_int()\n"
    <> "  let mut i = 0\n"
    <> "  while i < n {\n"
    <> "    buf.write_string_utf8(s[:])\n"
    <> "    i = i + 1\n"
    <> "  }\n"
    <> "  @gprelude.BitArray::from_bytes(buf.to_bytes()).byte_size()\n"
    <> "}\n"

  let lib_gleam =
    "/// @external_type(moonbit, \"auto_pkg\", \"Counter\")\n"
    <> "pub type Counter\n\n"
    <> "pub type NamedCounter {\n"
    <> "  NamedCounter(name: String, counter: Counter)\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"auto_pkg\", \"sum_list\")\n"
    <> "pub fn sum_list(xs: List(Int)) -> Int {\n"
    <> "  let _ = xs\n"
    <> "  panic as \"Implemented in MoonBit\"\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"auto_pkg\", \"new_counter\")\n"
    <> "pub fn new_counter(start: Int) -> Counter {\n"
    <> "  let _ = start\n"
    <> "  panic as \"Implemented in MoonBit\"\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"auto_pkg\", \"bump_counter\")\n"
    <> "pub fn bump_counter(c: Counter, delta: Int) -> Nil {\n"
    <> "  let _ = c\n"
    <> "  let _ = delta\n"
    <> "  panic as \"Implemented in MoonBit\"\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"auto_pkg\", \"read_counter\")\n"
    <> "pub fn read_counter(c: Counter) -> Int {\n"
    <> "  let _ = c\n"
    <> "  panic as \"Implemented in MoonBit\"\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"custom_pkg\", \"repeat_utf8_len\")\n"
    <> "pub fn repeat_utf8_len(s: String, times: Int) -> Int {\n"
    <> "  let _ = s\n"
    <> "  let _ = times\n"
    <> "  panic as \"Implemented in MoonBit\"\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"moonbitlang/core/math\", \"pow\")\n"
    <> "pub fn math_pow(base: Float, exp: Float) -> Float {\n"
    <> "  let _ = base\n"
    <> "  let _ = exp\n"
    <> "  panic as \"Implemented in MoonBit\"\n"
    <> "}\n\n"
    <> "pub fn check_all() -> Bool {\n"
    <> "  let c1 = new_counter(10)\n"
    <> "  let c2 = new_counter(100)\n"
    <> "  bump_counter(c1, 5)\n"
    <> "  let named = NamedCounter(name: \"hits\", counter: c1)\n"
    <> "  let list_total = sum_list([read_counter(named.counter), read_counter(c2)])\n"
    <> "  list_total == 115\n"
    <> "  && repeat_utf8_len(\"🌙\", 3) == 12\n"
    <> "  && math_pow(2.0, 10.0) == 1024.0\n"
    <> "}\n"

  let test_gleam =
    "import local_ffi\n\n"
    <> "pub fn main() -> Nil {\n  Nil\n}\n\n"
    <> "pub fn local_ffi_e2e_test() {\n"
    <> "  assert local_ffi.check_all()\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "moonbit/auto_pkg/auto_pkg.mbt"),
      contents: auto_pkg_mbt,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "moonbit/custom_pkg/moon.pkg"),
      contents: custom_pkg_cfg,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "moonbit/custom_pkg/custom_pkg.mbt"),
      contents: custom_pkg_mbt,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/local_ffi.gleam"),
      contents: lib_gleam,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/local_ffi_test.gleam"),
      contents: test_gleam,
    )
    == Ok(Nil)

  let assert Ok(summary) = workspace.transpile_project(root, out_dir)
  assert summary.project_name == "local_ffi"
  assert summary.local_moonbit_packages == ["auto_pkg", "custom_pkg"]

  // Verify auto-generated moon.pkg for auto_pkg and verbatim copy for custom_pkg.
  let assert Ok(gen_pkg) =
    simplifile.read(from: filepath.join(out_dir, "auto_pkg/moon.pkg"))
  assert string.contains(gen_pkg, "\"local_ffi/gprelude\" @gprelude")
  let assert Ok(copied_pkg) =
    simplifile.read(from: filepath.join(out_dir, "custom_pkg/moon.pkg"))
  assert string.contains(copied_pkg, "\"moonbitlang/core/buffer\" @buffer")

  let check_res =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert check_res.exit_code == 0

  let run_wasm =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert run_wasm.exit_code == 0
  assert string.contains(run_wasm.output, "passed: 1, failed: 0")

  let run_js =
    cmd.run(command: "moon", args: ["test", "--target", "js"], cwd: out_dir)
  assert run_js.exit_code == 0
  assert string.contains(run_js.output, "passed: 1, failed: 0")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn external_type_opaque_alias_and_record_embedding_e2e_test() {
  let root = "build/test_fixtures/ext_type"
  let out_dir = "build/test_fixtures/ext_type_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src/ext_type"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(
      root,
      "moonbit/native_box",
    ))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"ext_type\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  // Local MoonBit types deliberately do NOT derive Eq/Debug/Show.
  let native_mbt =
    "///|\n"
    <> "pub struct OpaqueHandle {\n  id : Int64\n}\n\n"
    <> "///|\n"
    <> "pub fn make_handle(id : Int64) -> OpaqueHandle {\n  { id: id }\n}\n\n"
    <> "///|\n"
    <> "pub fn handle_id(h : OpaqueHandle) -> Int64 {\n  h.id\n}\n\n"
    <> "///|\n"
    <> "pub struct NativeBox[T] {\n  item : T\n}\n\n"
    <> "///|\n"
    <> "pub fn[T] wrap_box(item : T) -> NativeBox[T] {\n  { item: item }\n}\n\n"
    <> "///|\n"
    <> "pub fn[T] unwrap_box(b : NativeBox[T]) -> T {\n  b.item\n}\n\n"
    <> "///|\n"
    <> "pub fn[T : @gprelude.GleamInspect] inspect_val(x : T) -> String {\n"
    <> "  @gprelude.GleamInspect::gleam_inspect(x)\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn str_contains(haystack : String, needle : String) -> Bool {\n"
    <> "  haystack.contains(needle)\n"
    <> "}\n"
  assert simplifile.write(
      to: filepath.join(root, "moonbit/native_box/native_box.mbt"),
      contents: native_mbt,
    )
    == Ok(Nil)

  let types_gleam =
    "/// @external_type(moonbit, \"native_box\", \"OpaqueHandle\")\n"
    <> "pub type Handle\n\n"
    <> "@external_type(moonbit, \"native_box\", \"NativeBox\")\n"
    <> "pub type Box(a)\n\n"
    <> "/// @external(moonbit, \"native_box\", \"make_handle\")\n"
    <> "pub fn make_handle(id: Int) -> Handle {\n"
    <> "  let _ = id\n"
    <> "  panic as \"mbt\"\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"native_box\", \"handle_id\")\n"
    <> "pub fn handle_id(h: Handle) -> Int {\n"
    <> "  let _ = h\n"
    <> "  panic as \"mbt\"\n"
    <> "}\n\n"
    <> "@external(moonbit, \"native_box\", \"wrap_box\")\n"
    <> "pub fn wrap_box(x: a) -> Box(a)\n\n"
    <> "@external(moonbit, \"native_box\", \"unwrap_box\")\n"
    <> "pub fn unwrap_box(b: Box(a)) -> a\n\n"
    <> "@external(moonbit, \"native_box\", \"inspect_val\")\n"
    <> "pub fn inspect_val(x: a) -> String\n\n"
    <> "@external(moonbit, \"native_box\", \"str_contains\")\n"
    <> "pub fn str_contains(haystack: String, needle: String) -> Bool\n"

  let main_gleam =
    "import ext_type/types.{type Box, type Handle}\n\n"
    <> "pub type Holder {\n"
    <> "  Holder(tag: String, handle: Handle, history: List(Handle), boxed: Result(Box(String), String))\n"
    <> "}\n\n"
    <> "pub fn verify_opaque_types() -> Bool {\n"
    <> "  let h1 = types.make_handle(10)\n"
    <> "  let h2 = types.make_handle(25)\n"
    <> "  let b = types.wrap_box(\"ok\")\n"
    <> "  let holder = Holder(tag: \"k\", handle: h1, history: [h1, h2], boxed: Ok(b))\n"
    <> "  let inspected = types.inspect_val(holder)\n"
    <> "  let box_val = case holder.boxed {\n"
    <> "    Ok(bx) -> types.unwrap_box(bx)\n"
    <> "    Error(_) -> \"bad\"\n"
    <> "  }\n"
    <> "  types.handle_id(holder.handle) == 10\n"
    <> "  && box_val == \"ok\"\n"
    <> "  && types.str_contains(inspected, \"Holder(\\\"k\\\", \\\"//external\\\"\")\n"
    <> "}\n"

  let test_gleam =
    "import ext_type\n\n"
    <> "pub fn main() -> Nil {\n  Nil\n}\n\n"
    <> "pub fn external_type_e2e_test() {\n"
    <> "  assert ext_type.verify_opaque_types()\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/ext_type/types.gleam"),
      contents: types_gleam,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/ext_type.gleam"),
      contents: main_gleam,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/ext_type_test.gleam"),
      contents: test_gleam,
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)

  let assert Ok(types_mbt) =
    simplifile.read(from: filepath.join(out_dir, "ext_type/types/types.mbt"))
  assert string.contains(
    types_mbt,
    "pub type Handle = @native_box.OpaqueHandle",
  )
  assert string.contains(
    types_mbt,
    "pub type Box[A] = @native_box.NativeBox[A]",
  )

  let assert Ok(main_mbt) =
    simplifile.read(from: filepath.join(out_dir, "ext_type/ext_type.mbt"))
  assert !string.contains(main_mbt, "#derive(Eq, Debug, Hash)")

  let check_res =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert check_res.exit_code == 0

  let test_wasm =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert test_wasm.exit_code == 0
  assert string.contains(test_wasm.output, "passed: 1, failed: 0")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn mbti_parser_stdlib_math_and_buffer_test() {
  let moon_home = case cmd.get_env("MOON_HOME") {
    Ok(v) if v != "" -> v
    _ -> {
      let assert Ok(h) = cmd.get_env("HOME")
      filepath.join(h, ".moon")
    }
  }

  let math_path = filepath.join(moon_home, "lib/core/math/pkg.generated.mbti")
  let assert Ok(math_src) = simplifile.read(from: math_path)
  let assert Ok(math_pkg) = mbti.parse_mbti(math_src)
  assert math_pkg.package_name == "moonbitlang/core/math"
  assert list.contains(math_pkg.imports, #("moonbitlang/core/bigint", "bigint"))
  assert list.contains(math_pkg.imports, #("moonbitlang/core/random", "random"))
  assert list.any(math_pkg.constants, fn(c) { c.name == "PI" })
  assert list.any(math_pkg.functions, fn(f) {
    f.name == "sin" && !f.is_deprecated
  })
  assert list.any(math_pkg.functions, fn(f) {
    f.name == "is_probable_prime" && list.length(f.params) == 3
  })
  assert list.any(math_pkg.functions, fn(f) {
    f.name == "maximum" && f.is_deprecated
  })

  let buf_path = filepath.join(moon_home, "lib/core/buffer/pkg.generated.mbti")
  let assert Ok(buf_src) = simplifile.read(from: buf_path)
  let assert Ok(buf_pkg) = mbti.parse_mbti(buf_src)
  assert buf_pkg.package_name == "moonbitlang/core/buffer"
  assert list.any(buf_pkg.functions, fn(f) {
    f.owner_type == Some("Buffer") && f.name == "Buffer"
  })
  assert list.any(buf_pkg.functions, fn(f) {
    f.owner_type == Some("Buffer") && f.name == "write_string_utf8"
  })
  assert list.any(buf_pkg.functions, fn(f) {
    f.name == "new" && f.is_deprecated
  })

  // Inline complex fixture covering pub(all) struct, enum, private-fields struct, tuple, and bounds.
  let inline_mbti =
    "// Generated\n"
    <> "package \"demo/sample\"\n\n"
    <> "pub(all) struct Summary {\n  count : Int32\n  total : Int64\n}\n\n"
    <> "pub struct Hidden {\n  tag : String\n  // private fields\n}\n\n"
    <> "pub(all) enum Mode {\n  Fast\n  Exact(Int32)\n}\n\n"
    <> "pub fn summarize(Array[Int32], scale? : Int32) -> Summary\n"
    <> "pub fn[T : Show] debug_str(T) -> String\n"
    <> "pub type Wrapped[F : (Int32, Int32) -> Unit]\n"
  let assert Ok(parsed_inline) = mbti.parse_mbti(inline_mbti)
  assert parsed_inline.package_name == "demo/sample"
  assert list.length(parsed_inline.types) == 4
  assert list.length(parsed_inline.functions) == 2
  assert list.any(parsed_inline.types, fn(t) {
    t.name == "Wrapped" && t.type_params == ["F : (Int32, Int32) -> Unit"]
  })
  Nil
}

pub fn moonbit_bindgen_stdlib_buffer_e2e_test() {
  let root = "build/test_fixtures/bindgen_buffer_e2e"
  let out_dir = "build/test_fixtures/bindgen_buffer_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src/gleam"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"bindgen_buf\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/gleam/option.gleam"),
      contents: "/// @external_type(moonbit, \"builtin\", \"Option\")\n"
        <> "pub type Option(a) {\n  Some(a)\n  None\n}\n\n"
        <> "pub fn is_some(o: Option(a)) -> Bool {\n  case o {\n    Some(_) -> True\n    None -> False\n  }\n}\n",
    )
    == Ok(Nil)

  let assert Ok(res) =
    bindgen.bind_package(
      root,
      "moonbitlang/core/buffer",
      Some("ffi/buffer"),
      out_dir,
    )
  assert res.gleam_module_path == "ffi/buffer"
  assert res.adapter_pkg_dir == Some("buffer_adapter")

  let main_src =
    "import ffi/buffer\n"
    <> "import gleam/option.{None, Some}\n\n"
    <> "pub fn main() -> Nil {\n"
    <> "  let b1 = buffer.new_buffer(None)\n"
    <> "  buffer.write_string_utf8(b1, \"hello \")\n"
    <> "  buffer.write_string_utf8(b1, \"moonbit\")\n"
    <> "  let len1 = buffer.length(b1)\n"
    <> "  let bytes1 = buffer.to_bytes(b1)\n"
    <> "  assert bytes1 == <<\"hello moonbit\":utf8>>\n"
    <> "  assert len1 == 13\n"
    <> "  let b2 = buffer.new_buffer(Some(32))\n"
    <> "  buffer.write_byte(b2, 65)\n"
    <> "  assert buffer.length(b2) == 1\n"
    <> "  assert buffer.to_bytes(b2) == <<65>>\n"
    <> "  let _ = echo \"buf=hello moonbit\"\n"
    <> "  Nil\n"
    <> "}\n"
  assert simplifile.write(
      to: filepath.join(root, "src/bindgen_buf.gleam"),
      contents: main_src,
    )
    == Ok(Nil)

  let check_gleam = cmd.run(command: "gleam", args: ["check"], cwd: root)
  assert check_gleam.exit_code == 0

  let assert Ok(_) = workspace.transpile_project(root, out_dir)

  let check_moon =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert check_moon.exit_code == 0

  let run_wasm =
    cmd.run(
      command: "moon",
      args: ["run", "bindgen_buf", "--target", "wasm"],
      cwd: out_dir,
    )
  assert run_wasm.exit_code == 0
  assert string.contains(run_wasm.output, "\"buf=hello moonbit\"")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn moonbit_bindgen_local_pkg_e2e_test() {
  let root = "build/test_fixtures/bindgen_local_e2e"
  let out_dir = "build/test_fixtures/bindgen_local_mbt"
  let info_out = "build/test_fixtures/bindgen_local_info_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  let _ = simplifile.delete(file_or_dir_at: info_out)

  assert simplifile.create_directory_all(filepath.join(root, "src/gleam"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "moonbit/stats"))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"bindgen_local\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/gleam/option.gleam"),
      contents: "/// @external_type(moonbit, \"builtin\", \"Option\")\n"
        <> "pub type Option(a) {\n  Some(a)\n  None\n}\n\n"
        <> "pub fn is_some(o: Option(a)) -> Bool {\n  case o {\n    Some(_) -> True\n    None -> False\n  }\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/bindgen_local.gleam"),
      contents: "pub fn main() -> Nil {\n  Nil\n}\n",
    )
    == Ok(Nil)

  let stats_mbt =
    "///|\n"
    <> "pub(all) struct Summary {\n  count : Int\n  total : Int64\n}\n\n"
    <> "///|\n"
    <> "pub(all) enum Mode {\n  Fast\n  Exact(Int)\n}\n\n"
    <> "///|\n"
    <> "pub fn summarize(xs : Array[Int], scale~ : Int = 1) -> Summary {\n"
    <> "  let mut sum = 0L\n"
    <> "  for x in xs {\n"
    <> "    sum = sum + (x * scale).to_int64()\n"
    <> "  }\n"
    <> "  { count: xs.length(), total: sum }\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn apply_mode(m : Mode, base : Int) -> Int {\n"
    <> "  match m {\n"
    <> "    Fast => base * 2\n"
    <> "    Exact(k) => base + k\n"
    <> "  }\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn checked_div(a : Int, b : Int) -> Int raise {\n"
    <> "  if b == 0 {\n"
    <> "    raise Failure::Failure(\"div by zero\")\n"
    <> "  }\n"
    <> "  a / b\n"
    <> "}\n"
  assert simplifile.write(
      to: filepath.join(root, "moonbit/stats/stats.mbt"),
      contents: stats_mbt,
    )
    == Ok(Nil)

  let assert Ok(res) =
    bindgen.bind_package(root, "moonbit/stats", Some("ffi/stats"), info_out)
  assert res.gleam_module_path == "ffi/stats"
  assert res.adapter_pkg_dir == Some("stats_adapter")

  let main_src =
    "import ffi/stats\n"
    <> "import gleam/option.{None, Some}\n\n"
    <> "pub fn main() -> Nil {\n"
    <> "  let s1 = stats.summarize([2, 3, 5], None)\n"
    <> "  assert stats.summary_count(s1) == 3\n"
    <> "  assert stats.summary_total(s1) == 10\n"
    <> "  let s2 = stats.summarize([2, 3], Some(10))\n"
    <> "  assert stats.summary_total(s2) == 50\n"
    <> "  let s3 = stats.make_summary(4, 99)\n"
    <> "  assert stats.summary_count(s3) == 4 && stats.summary_total(s3) == 99\n"
    <> "  assert stats.apply_mode(stats.mode_fast(), 6) == 12\n"
    <> "  assert stats.apply_mode(stats.mode_exact(7), 6) == 13\n"
    <> "  assert stats.checked_div(12, 3) == Ok(4)\n"
    <> "  let div_err = stats.checked_div(12, 0)\n"
    <> "  let assert Error(_) = div_err\n"
    <> "  let _ = echo \"stats_ok\"\n"
    <> "  Nil\n"
    <> "}\n"
  assert simplifile.write(
      to: filepath.join(root, "src/bindgen_local.gleam"),
      contents: main_src,
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)

  let check_moon =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert check_moon.exit_code == 0

  let run_wasm =
    cmd.run(
      command: "moon",
      args: ["run", "bindgen_local", "--target", "wasm"],
      cwd: out_dir,
    )
  assert run_wasm.exit_code == 0
  assert string.contains(run_wasm.output, "\"stats_ok\"")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  let _ = simplifile.delete(file_or_dir_at: info_out)
  Nil
}

pub fn ffi_meta_scanner_unit_test() {
  let base = ffi_meta.base_metadata()
  assert ffi_meta.is_derivable(base, "builtin", "Option")
  assert ffi_meta.is_inspectable(base, "builtin", "Option")
  assert ffi_meta.is_derivable(base, "gprelude", "Dynamic")
  assert ffi_meta.is_inspectable(base, "gprelude", "Dynamic")
  let assert Some(echo_meta) =
    ffi_meta.lookup_function(base, "gprelude", "echo_val")
  assert echo_meta.type_params == [#("T", set.from_list(["GleamInspect"]))]

  let mbt_src =
    "///|\n"
    <> "#derive(Debug)\n"
    <> "pub(all) struct CustomMap[K, V] {\n"
    <> "  inner : Map[K, V]\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub impl[K : Eq + Hash, V : Eq] Eq for CustomMap[K, V] with equal(self, other) {\n"
    <> "  self.inner == other.inner\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub impl[K : Hash, V : Hash] Hash for CustomMap[K, V] with hash_combine(self, hasher) {\n"
    <> "  ignore((self, hasher))\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub impl[\n"
    <> "  K : @gprelude.GleamInspect,\n"
    <> "  V : @gprelude.GleamInspect,\n"
    <> "] @gprelude.GleamInspect for CustomMap[\n"
    <> "  K,\n"
    <> "  V,\n"
    <> "] with gleam_inspect(self) {\n"
    <> "  \"{}\"\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn[K : Eq + Hash, V] map_insert(\n"
    <> "  m : CustomMap[K, V],\n"
    <> "  key : K,\n"
    <> "  val : V,\n"
    <> ") -> CustomMap[K, V] {\n"
    <> "  m\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn[T : @gprelude.ToDynamic] box_dyn(x : T) -> @gprelude.Dynamic {\n"
    <> "  @gprelude.ToDynamic::to_dynamic(x)\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn[T : @gprelude.GleamInspect] show_any(x : T) -> String {\n"
    <> "  @gprelude.GleamInspect::gleam_inspect(x)\n"
    <> "}\n"

  let scanned = ffi_meta.scan_mbt_source(base, "custom_ffi", mbt_src)
  assert ffi_meta.is_derivable(scanned, "custom_ffi", "CustomMap")
  assert ffi_meta.is_inspectable(scanned, "custom_ffi", "CustomMap")
  assert ffi_meta.eq_requires_hash_params(scanned, "custom_ffi", "CustomMap")
    == set.from_list([0])

  let assert Some(ins_meta) =
    ffi_meta.lookup_function(scanned, "custom_ffi", "map_insert")
  assert ins_meta.type_params
    == [#("K", set.from_list(["Eq", "Hash"])), #("V", set.new())]

  let assert Some(box_meta) =
    ffi_meta.lookup_function(scanned, "custom_ffi", "box_dyn")
  assert box_meta.type_params == [#("T", set.from_list(["ToDynamic"]))]

  let assert Some(show_meta) =
    ffi_meta.lookup_function(scanned, "custom_ffi", "show_any")
  assert show_meta.type_params == [#("T", set.from_list(["GleamInspect"]))]
}

pub fn generic_ffi_traits_and_cross_module_bounds_e2e_test() {
  let root = "build/test_fixtures/generic_traits"
  let out_dir = "build/test_fixtures/generic_traits_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(
      root,
      "src/generic_traits",
    ))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(
      root,
      "moonbit/custom_ffi",
    ))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"generic_traits\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  let ffi_mbt =
    "///|\n"
    <> "#derive(Debug)\n"
    <> "pub(all) struct CustomMap[K, V] {\n"
    <> "  inner : Map[K, V]\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub impl[K : Eq + Hash, V : Eq] Eq for CustomMap[K, V] with equal(self, other) {\n"
    <> "  self.inner == other.inner\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub impl[K : Hash, V : Hash] Hash for CustomMap[K, V] with hash_combine(self, hasher) {\n"
    <> "  hasher.combine_int(self.inner.length())\n"
    <> "  self.inner.each(fn(k, v) {\n"
    <> "    hasher.combine(k)\n"
    <> "    hasher.combine(v)\n"
    <> "  })\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub impl[K : @gprelude.GleamInspect, V : @gprelude.GleamInspect] @gprelude.GleamInspect for CustomMap[\n"
    <> "  K,\n"
    <> "  V,\n"
    <> "] with gleam_inspect(self) {\n"
    <> "  let mut s = \"{\"\n"
    <> "  let mut first = true\n"
    <> "  self.inner.each(fn(k, v) {\n"
    <> "    if !first { s = s + \", \" }\n"
    <> "    first = false\n"
    <> "    s = s + @gprelude.GleamInspect::gleam_inspect(k) + \": \" + @gprelude.GleamInspect::gleam_inspect(v)\n"
    <> "  })\n"
    <> "  s + \"}\"\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn[K, V] map_new() -> CustomMap[K, V] {\n"
    <> "  { inner: Default::default() }\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn[K : Eq + Hash, V] map_insert(\n"
    <> "  m : CustomMap[K, V],\n"
    <> "  key : K,\n"
    <> "  val : V,\n"
    <> ") -> CustomMap[K, V] {\n"
    <> "  let copy = m.inner.copy()\n"
    <> "  copy.set(key, val)\n"
    <> "  { inner: copy }\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn[K : Eq + Hash, V] map_get(\n"
    <> "  m : CustomMap[K, V],\n"
    <> "  key : K,\n"
    <> ") -> Result[V, Unit] {\n"
    <> "  match m.inner.get(key) {\n"
    <> "    Some(v) => Ok(v)\n"
    <> "    None => Err(())\n"
    <> "  }\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn[T : @gprelude.ToDynamic] box_dyn(x : T) -> @gprelude.Dynamic {\n"
    <> "  @gprelude.ToDynamic::to_dynamic(x)\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn is_dyn_int(d : @gprelude.Dynamic, expected : Int64) -> Bool {\n"
    <> "  d == @gprelude.DynInt(expected)\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn[T : @gprelude.GleamInspect] show_any(x : T) -> String {\n"
    <> "  @gprelude.GleamInspect::gleam_inspect(x)\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "moonbit/custom_ffi/custom_ffi.mbt"),
      contents: ffi_mbt,
    )
    == Ok(Nil)

  let lib_gleam =
    "/// @external_type(moonbit, \"builtin\", \"Option\")\n"
    <> "pub type Maybe(a) {\n"
    <> "  Some(a)\n"
    <> "  None\n"
    <> "}\n\n"
    <> "/// @external_type(moonbit, \"custom_ffi\", \"CustomMap\")\n"
    <> "pub type CustomMap(k, v)\n\n"
    <> "/// @external_type(moonbit, \"gprelude\", \"Dynamic\")\n"
    <> "pub type Dyn\n\n"
    <> "pub type Bag(a) {\n"
    <> "  Bag(items: CustomMap(a, Int))\n"
    <> "}\n\n"
    <> "@external(moonbit, \"custom_ffi\", \"map_new\")\n"
    <> "pub fn map_new() -> CustomMap(k, v)\n\n"
    <> "@external(moonbit, \"custom_ffi\", \"map_insert\")\n"
    <> "pub fn map_insert(m: CustomMap(k, v), k: k, v: v) -> CustomMap(k, v)\n\n"
    <> "@external(moonbit, \"custom_ffi\", \"map_get\")\n"
    <> "pub fn map_get(m: CustomMap(k, v), k: k) -> Result(v, Nil)\n\n"
    <> "@external(moonbit, \"custom_ffi\", \"box_dyn\")\n"
    <> "pub fn box_dyn(x: a) -> Dyn\n\n"
    <> "@external(moonbit, \"custom_ffi\", \"is_dyn_int\")\n"
    <> "pub fn is_dyn_int(d: Dyn, expected: Int) -> Bool\n\n"
    <> "@external(moonbit, \"custom_ffi\", \"show_any\")\n"
    <> "pub fn show_any(x: a) -> String\n\n"
    <> "pub fn contains(xs: List(a), target: a) -> Bool {\n"
    <> "  case xs {\n"
    <> "    [] -> False\n"
    <> "    [first, ..rest] if first == target -> True\n"
    <> "    [_, ..rest] -> contains(rest, target)\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn put_and_has(m: CustomMap(k, v), key: k, val: v) -> Result(v, Nil) {\n"
    <> "  let updated = map_insert(m, key, val)\n"
    <> "  map_get(updated, key)\n"
    <> "}\n\n"
    <> "pub fn wrap_box(x: a) -> Dyn {\n"
    <> "  box_dyn(x)\n"
    <> "}\n\n"
    <> "pub fn wrap_show(x: a) -> String {\n"
    <> "  show_any(x)\n"
    <> "}\n\n"
    <> "pub fn is_missing(m: Maybe(a)) -> Bool {\n"
    <> "  m == None\n"
    <> "}\n"

  let main_gleam =
    "import generic_traits/lib.{type Bag, Bag, None, Some}\n\n"
    <> "pub fn list_contains_via_cross_mod(xs: List(a), target: a) -> Bool {\n"
    <> "  lib.contains(xs, target)\n"
    <> "}\n\n"
    <> "pub fn bag_insert(b: Bag(k), k: k, v: Int) -> Bag(k) {\n"
    <> "  Bag(items: lib.map_insert(b.items, k, v))\n"
    <> "}\n\n"
    <> "pub fn bag_eq(a: Bag(k), b: Bag(k)) -> Bool {\n"
    <> "  a == b\n"
    <> "}\n\n"
    <> "pub fn check_all() -> Bool {\n"
    <> "  let b1 = bag_insert(Bag(items: lib.map_new()), \"k\", 42)\n"
    <> "  let b2 = bag_insert(Bag(items: lib.map_new()), \"k\", 42)\n"
    <> "  let dyn_ok = lib.is_dyn_int(lib.wrap_box(99), 99)\n"
    <> "  let fn_opt_ok = !lib.is_missing(Some(fn() { 1 })) && lib.is_missing(None)\n"
    <> "  let show_fn = lib.wrap_show(fn(a, b) { a + b })\n"
    <> "  list_contains_via_cross_mod([10, 20, 30], 20)\n"
    <> "  && lib.put_and_has(lib.map_new(), \"x\", 7) == Ok(7)\n"
    <> "  && bag_eq(b1, b2)\n"
    <> "  && dyn_ok\n"
    <> "  && fn_opt_ok\n"
    <> "  && show_fn == \"//fn(a, b) { ... }\"\n"
    <> "  && lib.wrap_show(b1) == \"Bag({\\\"k\\\": 42})\"\n"
    <> "}\n"

  let test_gleam =
    "import generic_traits\n\n"
    <> "pub fn main() -> Nil {\n  Nil\n}\n\n"
    <> "pub fn generic_traits_e2e_test() {\n"
    <> "  assert generic_traits.check_all()\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/generic_traits/lib.gleam"),
      contents: lib_gleam,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/generic_traits.gleam"),
      contents: main_gleam,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/generic_traits_test.gleam"),
      contents: test_gleam,
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)

  let assert Ok(main_mbt) =
    simplifile.read(from: filepath.join(
      out_dir,
      "generic_traits/generic_traits.mbt",
    ))
  assert string.contains(
    main_mbt,
    "pub fn[T0 : Eq + Hash] list_contains_via_cross_mod(",
  )
  assert string.contains(main_mbt, "@lib.wrap_show(@gprelude.inspect_fn(2))")

  let assert Ok(lib_mbt) =
    simplifile.read(from: filepath.join(out_dir, "generic_traits/lib/lib.mbt"))
  assert string.contains(lib_mbt, "pub impl[A : Eq + Hash] Eq for Bag[A]")
  assert string.contains(
    lib_mbt,
    "pub fn[T0 : @gprelude.GleamInspect] wrap_show(",
  )
  assert string.contains(lib_mbt, "pub fn[T0 : @gprelude.ToDynamic] wrap_box(")
  assert string.contains(lib_mbt, "(m) is None")

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

pub fn moonbit_syntax_helpers_test() {
  assert syntax.take_balanced_parens("(a, (b, c)) rest")
    == Ok(#("a, (b, c)", " rest"))
  assert syntax.take_balanced_brackets("[K : Eq, V] fn_name")
    == Ok(#("K : Eq, V", " fn_name"))
  assert syntax.is_outer_paren_wrapped("(Int, (String, Bool))") == True
  assert syntax.is_outer_paren_wrapped("(Int) -> (Bool)") == False
  assert syntax.split_top_level_commas("Int, Map[String, Int], (Bool, Float)")
    == ["Int", "Map[String, Int]", "(Bool, Float)"]
  assert syntax.split_top_level_colon("label~ : @pkg.Map[String, Int]")
    == Some(#("label~ ", " @pkg.Map[String, Int]"))
  assert syntax.split_top_level_colon("@pkg.Type::method") == option.None
}

pub fn moonbit_lsp_workspace_moon_work_test() {
  let root = "build/test_fixtures/mbt_lsp_work"
  let out_dir = filepath.join(root, "build/moonbit")
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "moonbit/helper"))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"lsp_demo\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "moonbit/moon.mod"),
      contents: "name = \"lsp_demo_mbt\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "moonbit/helper/moon.pkg"),
      contents: "import {\n  \"lsp_demo_mbt/gprelude\" @gprelude,\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "moonbit/helper/helper.mbt"),
      contents: "///|\npub fn count_items(xs : @gprelude.GList[Int64]) -> Int64 {\n  xs.to_array().length().to_int64()\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/lsp_demo.gleam"),
      contents: "/// @external(moonbit, \"helper\", \"count_items\")\npub fn count_items(xs: List(Int)) -> Int {\n  let _ = xs\n  0\n}\n",
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)

  // moonbit/gprelude and root moon.work are generated
  assert simplifile.is_file(filepath.join(root, "moonbit/gprelude/gprelude.mbt"))
    == Ok(True)
  assert simplifile.is_file(filepath.join(root, "moonbit/gprelude/moon.pkg"))
    == Ok(True)
  assert simplifile.is_file(filepath.join(root, "moon.work")) == Ok(True)

  // build/moonbit/helper/moon.pkg rewrites "lsp_demo_mbt/gprelude" to "lsp_demo/gprelude"
  let assert Ok(out_pkg) =
    simplifile.read(filepath.join(out_dir, "helper/moon.pkg"))
  assert string.contains(out_pkg, "\"lsp_demo/gprelude\" @gprelude")
  assert !string.contains(out_pkg, "\"lsp_demo_mbt/gprelude\"")

  // moon check --deny-warn passes BOTH in out_dir AND directly at root (via moon.work)
  let chk_out =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert chk_out.exit_code == 0

  let chk_root =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: root,
    )
  assert chk_root.exit_code == 0

  // gekko.clean_project removes moonbit/gprelude and generated moon.work
  let assert Ok(_) = gekko.clean_project(root)
  assert simplifile.is_directory(filepath.join(root, "moonbit/gprelude"))
    != Ok(True)
  assert simplifile.is_file(filepath.join(root, "moon.work")) != Ok(True)

  // Hand-written moon.work is preserved by transpile_project and clean_project
  let custom_work = "members = [\n  \"moonbit\",\n]\n"
  assert simplifile.write(
      to: filepath.join(root, "moon.work"),
      contents: custom_work,
    )
    == Ok(Nil)
  let assert Ok(_) = workspace.transpile_project(root, out_dir)
  assert simplifile.read(filepath.join(root, "moon.work")) == Ok(custom_work)
  let assert Ok(_) = gekko.clean_project(root)
  assert simplifile.read(filepath.join(root, "moon.work")) == Ok(custom_work)

  let _ = simplifile.delete(file_or_dir_at: root)
  Nil
}

pub fn mbti_suberror_and_bindgen_options_unit_test() {
  let mbti_src =
    "package \"moonbitlang/core/json\"\n\n"
    <> "pub(all) suberror ParseError {\n"
    <> "  InvalidChar(Position, Char)\n"
    <> "  InvalidEof\n"
    <> "}\n\n"
    <> "pub(all) struct Position {\n"
    <> "  line : Int32\n"
    <> "  column : Int32\n"
    <> "}\n\n"
    <> "pub enum Json {\n"
    <> "  Null\n"
    <> "  Number(Double, repr~ : String?)\n"
    <> "  String(String)\n"
    <> "}\n\n"
    <> "pub fn parse(StringView, preserve_number_repr? : Bool) -> Json raise ParseError\n"
    <> "pub fn Json::stringify(Json) -> String\n"
    <> "pub fn unused_helper() -> Unit\n"

  let assert Ok(parsed) = mbti.parse_mbti(mbti_src)
  let assert Ok(parse_fn) =
    list.find(parsed.functions, fn(f) { f.name == "parse" })
  assert parse_fn.raises == True
  assert parse_fn.raise_type == Some(mbti.MbtiNamed(None, "ParseError", []))

  let assert Ok(err_td) =
    list.find(parsed.types, fn(td) { td.name == "ParseError" })
  let assert mbti.MbtiEnum(public_all: True, is_suberror: True, variants:) =
    err_td.kind
  assert list.length(variants) == 2

  let res =
    bindgen.generate_bindings_with_options(
      parsed,
      "demo",
      "ffi/json",
      "demo_mbt",
      BindOptions(
        only: ["parse", "Json::stringify", "Json", "ParseError"],
        map_types: dict.from_list([
          #("Json", #("gleam/json", "Json")),
          #("Char", #("", "UtfCodepoint")),
        ]),
        typed_errors: True,
        adapter_name: Some("custom_json_adapter"),
      ),
    )

  assert res.adapter_pkg_dir == Some("custom_json_adapter")
  assert string.contains(res.gleam_source, "import gleam/json.{type Json}")
  assert !string.contains(res.gleam_source, "pub type Json\n")
  assert !string.contains(res.gleam_source, "unused_helper")
  assert string.contains(
    res.gleam_source,
    "pub fn parse(arg0: String, preserve_number_repr: Option(Bool)) -> Result(Json, ParseError)",
  )
  assert string.contains(res.gleam_source, "pub fn match_json(")
  assert string.contains(res.gleam_source, "pub fn match_parse_error(")
  let assert Some(mbt_src) = res.adapter_mbt_source
  assert string.contains(
    mbt_src,
    ") -> Result[@moonbitlang_core_json.Json, @moonbitlang_core_json.ParseError]",
  )
  assert string.contains(
    mbt_src,
    "@moonbitlang_core_json.Number(v0, repr=v1) => on_number(v0, (v1).map(fn(x0) { (x0).to_string_view() }))",
  )
  assert string.contains(
    mbt_src,
    "@moonbitlang_core_json.InvalidEof => on_invalid_eof()",
  )
  assert string.contains(mbt_src, "pub fn[Ret] match_json(")
  Nil
}

pub fn moonbit_bindgen_gprelude_and_builtin_e2e_test() {
  let root = "build/test_fixtures/bindgen_gp_e2e"
  let out_dir = "build/test_fixtures/bindgen_gp_mbt"
  let info_dir = "build/test_fixtures/bindgen_gp_info"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  let _ = simplifile.delete(file_or_dir_at: info_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src/gleam"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"bindgen_gp\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/gleam/option.gleam"),
      contents: "/// @external_type(moonbit, \"builtin\", \"Option\")\n"
        <> "pub type Option(a) {\n  Some(a)\n  None\n}\n\n"
        <> "pub fn is_some(o: Option(a)) -> Bool {\n  case o {\n    Some(_) -> True\n    None -> False\n  }\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/bindgen_gp.gleam"),
      contents: "pub fn main() -> Nil {\n  Nil\n}\n",
    )
    == Ok(Nil)

  let assert Ok(_) =
    bindgen.bind_package_with_options(
      root,
      "moonbitlang/core/builtin",
      Some("ffi/mbuiltin"),
      info_dir,
      BindOptions(
        only: ["String::to_lower", "Int64::to_string", "println"],
        map_types: dict.new(),
        typed_errors: False,
        adapter_name: Some("gp_builtin_adapter"),
      ),
    )

  let assert Ok(_) =
    bindgen.bind_package_with_options(
      root,
      "gprelude",
      Some("ffi/gprelude"),
      info_dir,
      BindOptions(
        only: [
          "Dynamic",
          "to_dynamic",
          "gleam_inspect",
          "BitArray::from_string",
        ],
        map_types: dict.new(),
        typed_errors: False,
        adapter_name: Some("gp_gprelude_adapter"),
      ),
    )

  let main_src =
    "import ffi/gprelude as mgp\n"
    <> "import ffi/mbuiltin as mb\n"
    <> "import gleam/option.{None}\n\n"
    <> "pub fn main() -> Nil {\n"
    <> "  let dyn = mgp.to_dynamic(42)\n"
    <> "  let is_42 = mgp.match_dynamic(\n"
    <> "    dyn,\n"
    <> "    fn() { False },\n"
    <> "    fn(_) { False },\n"
    <> "    fn(n) { n == 42 },\n"
    <> "    fn(_) { False },\n"
    <> "    fn(_) { False },\n"
    <> "    fn(_) { False },\n"
    <> "    fn(_) { False },\n"
    <> "    fn(_) { False },\n"
    <> "    fn(_) { False },\n"
    <> "  )\n"
    <> "  assert is_42\n"
    <> "  assert mgp.gleam_inspect(42) == \"42\"\n"
    <> "  assert mgp.from_string(\"ok\") == <<\"ok\":utf8>>\n"
    <> "  mb.println(mb.string_to_lower(\"GP_OK:\") <> mb.int64_to_string(42, None))\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/bindgen_gp.gleam"),
      contents: main_src,
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)

  let check_moon =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert check_moon.exit_code == 0

  let run_wasm =
    cmd.run(
      command: "moon",
      args: ["run", "bindgen_gp", "--target", "wasm"],
      cwd: out_dir,
    )
  assert run_wasm.exit_code == 0
  assert string.contains(run_wasm.output, "gp_ok:42")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  let _ = simplifile.delete(file_or_dir_at: info_dir)
  Nil
}

pub fn moonbit_bindgen_json_and_hashmap_e2e_test() {
  let root = "build/test_fixtures/bindgen_json_hm_e2e"
  let out_dir = "build/test_fixtures/bindgen_json_hm_mbt"
  let info_dir = "build/test_fixtures/bindgen_json_hm_info"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  let _ = simplifile.delete(file_or_dir_at: info_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src/gleam"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"bindgen_jh\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/gleam/option.gleam"),
      contents: "/// @external_type(moonbit, \"builtin\", \"Option\")\n"
        <> "pub type Option(a) {\n  Some(a)\n  None\n}\n\n"
        <> "pub fn is_some(o: Option(a)) -> Bool {\n  case o {\n    Some(_) -> True\n    None -> False\n  }\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/bindgen_jh.gleam"),
      contents: "pub fn main() -> Nil {\n  Nil\n}\n",
    )
    == Ok(Nil)

  let assert Ok(_) =
    bindgen.bind_package_with_options(
      root,
      "moonbitlang/core/immut/hashmap",
      Some("ffi/hashmap"),
      info_dir,
      BindOptions(
        only: [
          "HashMap::empty",
          "HashMap::insert",
          "HashMap::get",
          "HashMap::fold",
        ],
        map_types: dict.new(),
        typed_errors: False,
        adapter_name: Some("jh_hashmap_adapter"),
      ),
    )

  let assert Ok(_) =
    bindgen.bind_package_with_options(
      root,
      "moonbitlang/core/json",
      Some("ffi/json"),
      info_dir,
      BindOptions(
        only: ["parse", "Json::stringify", "Json", "ParseError"],
        map_types: dict.new(),
        typed_errors: True,
        adapter_name: Some("jh_json_adapter"),
      ),
    )

  let main_src =
    "import ffi/hashmap as mhm\n"
    <> "import ffi/json as mjson\n"
    <> "import gleam/option.{None, Some}\n\n"
    <> "pub fn main() -> Nil {\n"
    <> "  let hm = mhm.insert(mhm.insert(mhm.empty(), \"a\", 10), \"b\", 20)\n"
    <> "  assert mhm.get(hm, \"a\") == Some(10)\n"
    <> "  let total = mhm.fold(hm, 0, fn(acc, _k, v) { acc + v })\n"
    <> "  assert total == 30\n"
    <> "  let assert Ok(j) = mjson.parse(\"\\\"hi\\\"\", None, None)\n"
    <> "  let s = mjson.match_json(\n"
    <> "    j,\n"
    <> "    fn() { \"null\" },\n"
    <> "    fn() { \"true\" },\n"
    <> "    fn() { \"false\" },\n"
    <> "    fn(_, _) { \"num\" },\n"
    <> "    fn(str) { str },\n"
    <> "    fn(_) { \"arr\" },\n"
    <> "    fn(_) { \"obj\" },\n"
    <> "  )\n"
    <> "  assert s == \"hi\"\n"
    <> "  let assert Error(err) = mjson.parse(\"{\", None, None)\n"
    <> "  let err_tag = mjson.match_parse_error(\n"
    <> "    err,\n"
    <> "    fn(_, _) { \"char\" },\n"
    <> "    fn() { \"eof\" },\n"
    <> "    fn(_, _) { \"num\" },\n"
    <> "    fn(_) { \"esc\" },\n"
    <> "    fn(_, _) { \"dup\" },\n"
    <> "    fn() { \"depth\" },\n"
    <> "  )\n"
    <> "  assert err_tag == \"eof\"\n"
    <> "  let _ = echo total\n"
    <> "  Nil\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/bindgen_jh.gleam"),
      contents: main_src,
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)

  let check_moon =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert check_moon.exit_code == 0

  let run_wasm =
    cmd.run(
      command: "moon",
      args: ["run", "bindgen_jh", "--target", "wasm"],
      cwd: out_dir,
    )
  assert run_wasm.exit_code == 0
  assert string.contains(run_wasm.output, "30")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  let _ = simplifile.delete(file_or_dir_at: info_dir)
  Nil
}

pub fn mbti_label_migration_fill_false_test() {
  let src =
    "package \"demo/mod\"\n\n"
    <> "#label_migration(max_nesting_depth, fill=false)\n"
    <> "pub fn parse(StringView, max_nesting_depth? : Int32, reject_duplicate_keys? : Bool) -> Int\n\n"
    <> "#label_migration(len, fill=false, msg=\"Use slice\")\n"
    <> "pub fn copy(len? : Int32, dst : String) -> Unit\n\n"
    <> "#label_migration(capacity, alias=size_hint, msg=\"Use capacity= instead\")\n"
    <> "pub fn make(capacity? : Int32) -> Unit\n"

  let assert Ok(pkg) = mbti.parse_mbti(src)
  assert list.length(pkg.functions) == 3

  let assert [parse_fn, copy_fn, make_fn] = pkg.functions
  assert parse_fn.name == "parse"
  assert list.length(parse_fn.params) == 2
  let assert [_, p2] = parse_fn.params
  assert p2.label == Some("reject_duplicate_keys")

  assert copy_fn.name == "copy"
  assert list.length(copy_fn.params) == 1
  let assert [cp1] = copy_fn.params
  assert cp1.label == Some("dst")

  assert make_fn.name == "make"
  assert list.length(make_fn.params) == 1
  let assert [mp1] = make_fn.params
  assert mp1.label == Some("capacity")
}
