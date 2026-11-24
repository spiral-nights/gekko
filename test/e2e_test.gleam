import filepath
import gekko
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/cmd
import project/scaffold
import project/workspace
import simplifile
import test_helpers

pub fn golden_pure_gleam_e2e_test() {
  let fixture_dir = "fixtures/golden/pure_gleam"
  let packages_dir = filepath.join(fixture_dir, "build/packages")
  let out_dir = "build/test_fixtures/golden_pure_mbt"
  let _ = simplifile.delete(file_or_dir_at: filepath.join(fixture_dir, "build"))
  let _ =
    simplifile.delete_file(at: filepath.join(fixture_dir, "manifest.toml"))
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  let stub_gleeunit = filepath.join(packages_dir, "gleeunit")
  assert simplifile.create_directory_all(filepath.join(stub_gleeunit, "src"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(stub_gleeunit, "gleam.toml"),
      contents: "name = \"gleeunit\"\nversion = \"1.11.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(stub_gleeunit, "src/gleeunit.gleam"),
      contents: "pub fn main() -> Nil {\n  Nil\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(packages_dir, "packages.toml"),
      contents: "[packages]\ngleeunit = \"1.11.0\"\n\n[git]\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(fixture_dir, "manifest.toml"),
      contents: "packages = [\n"
        <> "  { name = \"gleeunit\", version = \"1.11.0\", build_tools = [\"gleam\"], requirements = [], otp_app = \"gleeunit\", source = \"hex\", outer_checksum = \"00\" },\n"
        <> "]\n\n[requirements]\ngleeunit = { version = \">= 1.0.0 and < 2.0.0\" }\n",
    )
    == Ok(Nil)

  let assert Ok(summary) = workspace.transpile_project(fixture_dir, out_dir)

  assert summary.project_name == "pure_gleam"
  assert simplifile.is_file(filepath.join(out_dir, "moon.mod")) == Ok(True)
  assert simplifile.is_file(filepath.join(out_dir, "gprelude/gprelude.mbt"))
    == Ok(True)
  assert simplifile.is_file(filepath.join(out_dir, "pure_gleam/pure_gleam.mbt"))
    == Ok(True)
  assert simplifile.is_file(filepath.join(
      out_dir,
      "pure_gleam_models/pure_gleam_models.mbt",
    ))
    == Ok(True)
  assert simplifile.is_file(filepath.join(
      out_dir,
      "pure_gleam_math/pure_gleam_math.mbt",
    ))
    == Ok(True)
  assert simplifile.is_file(filepath.join(
      out_dir,
      "test_pure_gleam_test/test_pure_gleam_test.mbt",
    ))
    == Ok(True)

  let check_res =
    cmd.run(command: "moon", args: ["check", "--target", "wasm"], cwd: out_dir)
  assert check_res.exit_code == 0

  let build_res =
    cmd.run(
      command: "moon",
      args: ["build", "--target", "wasm-gc"],
      cwd: out_dir,
    )
  assert build_res.exit_code == 0

  test_helpers.assert_golden_snapshots(
    out_dir,
    filepath.join(fixture_dir, "expected"),
    [
      "pure_gleam/pure_gleam.mbt",
      "pure_gleam_math/pure_gleam_math.mbt",
      "pure_gleam_models/pure_gleam_models.mbt",
      "test_pure_gleam_test/test_pure_gleam_test.mbt",
    ],
  )

  let test_wasm =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert test_wasm.exit_code == 0
  assert string.contains(test_wasm.output, "passed: 4, failed: 0")

  let test_wasm_gc =
    cmd.run(
      command: "moon",
      args: ["test", "--target", "wasm-gc"],
      cwd: out_dir,
    )
  assert test_wasm_gc.exit_code == 0
  assert string.contains(test_wasm_gc.output, "passed: 4, failed: 0")

  let _ = simplifile.delete(file_or_dir_at: filepath.join(fixture_dir, "build"))
  let _ =
    simplifile.delete_file(at: filepath.join(fixture_dir, "manifest.toml"))
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn golden_multi_pkg_deps_e2e_test() {
  let fixture_dir = "fixtures/golden/multi_pkg_deps"
  let packages_dir = filepath.join(fixture_dir, "build/packages")
  let out_dir = "build/test_fixtures/golden_multi_pkg_mbt"

  let _ = simplifile.delete(file_or_dir_at: filepath.join(fixture_dir, "build"))
  let _ =
    simplifile.delete_file(at: filepath.join(fixture_dir, "manifest.toml"))
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  let stub_gleeunit = filepath.join(packages_dir, "gleeunit")
  assert simplifile.create_directory_all(filepath.join(stub_gleeunit, "src"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(stub_gleeunit, "gleam.toml"),
      contents: "name = \"gleeunit\"\nversion = \"1.11.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(stub_gleeunit, "src/gleeunit.gleam"),
      contents: "pub fn main() -> Nil {\n  Nil\n}\n",
    )
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(packages_dir, "packages.toml"),
      contents: "[packages]\ngleeunit = \"1.11.0\"\n\n[git]\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(fixture_dir, "manifest.toml"),
      contents: "packages = [\n"
        <> "  { name = \"gleeunit\", version = \"1.11.0\", build_tools = [\"gleam\"], requirements = [], otp_app = \"gleeunit\", source = \"hex\", outer_checksum = \"00\" },\n"
        <> "  { name = \"mini_ffi\", version = \"0.1.0\", build_tools = [\"gleam\"], requirements = [], otp_app = \"mini_ffi\", source = \"local\", path = \"vendor/mini_ffi\" },\n"
        <> "  { name = \"tiny_slug\", version = \"0.1.0\", build_tools = [\"gleam\"], requirements = [\"mini_ffi\"], otp_app = \"tiny_slug\", source = \"local\", path = \"vendor/tiny_slug\" },\n"
        <> "]\n\n[requirements]\ngleeunit = { version = \">= 1.0.0 and < 2.0.0\" }\nmini_ffi = { path = \"vendor/mini_ffi\" }\ntiny_slug = { path = \"vendor/tiny_slug\" }\n",
    )
    == Ok(Nil)

  let assert Ok(summary) = workspace.transpile_project(fixture_dir, out_dir)
  assert summary.project_name == "multi_pkg_deps"
  assert list.contains(summary.emitted_modules, "tiny_slug")
  assert list.contains(summary.emitted_modules, "mini_ffi/kv")
  assert simplifile.is_file(filepath.join(out_dir, "tiny_slug/tiny_slug.mbt"))
    == Ok(True)
  assert simplifile.is_file(filepath.join(
      out_dir,
      "mini_ffi_kv/mini_ffi_kv.mbt",
    ))
    == Ok(True)
  assert simplifile.is_file(filepath.join(
      out_dir,
      "mini_ffi_mbt/mini_ffi_mbt.mbt",
    ))
    == Ok(True)
  assert simplifile.is_file(filepath.join(
      out_dir,
      "test_multi_pkg_deps_test/test_multi_pkg_deps_test.mbt",
    ))
    == Ok(True)

  let check_res =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert check_res.exit_code == 0

  let build_res =
    cmd.run(
      command: "moon",
      args: ["build", "--target", "wasm-gc"],
      cwd: out_dir,
    )
  assert build_res.exit_code == 0

  test_helpers.assert_golden_snapshots(
    out_dir,
    filepath.join(fixture_dir, "expected"),
    [
      "multi_pkg_deps/multi_pkg_deps.mbt",
      "tiny_slug/tiny_slug.mbt",
      "test_multi_pkg_deps_test/test_multi_pkg_deps_test.mbt",
    ],
  )

  let test_wasm =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert test_wasm.exit_code == 0
  assert string.contains(test_wasm.output, "passed: 4, failed: 0")

  let test_wasm_gc =
    cmd.run(
      command: "moon",
      args: ["test", "--target", "wasm-gc"],
      cwd: out_dir,
    )
  assert test_wasm_gc.exit_code == 0
  assert string.contains(test_wasm_gc.output, "passed: 4, failed: 0")

  let _ = simplifile.delete(file_or_dir_at: filepath.join(fixture_dir, "build"))
  let _ =
    simplifile.delete_file(at: filepath.join(fixture_dir, "manifest.toml"))
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn bit_array_tier2_e2e_all_targets_test() {
  let root = "build/test_fixtures/bit_array_t2"
  let out_dir = "build/test_fixtures/bit_array_t2_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "moonbit/ba_map"))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"bit_array_t2\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  let ba_map_mbt =
    "///|\n"
    <> "pub(all) struct BaMap {\n"
    <> "  inner : Map[@gprelude.BitArray, String]\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn map_new() -> BaMap {\n"
    <> "  { inner: Default::default() }\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn map_insert(m : BaMap, k : @gprelude.BitArray, v : String) -> BaMap {\n"
    <> "  let copy = m.inner.copy()\n"
    <> "  copy.set(k, v)\n"
    <> "  { inner: copy }\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn map_size(m : BaMap) -> Int64 {\n"
    <> "  m.inner.length().to_int64()\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn map_get(m : BaMap, k : @gprelude.BitArray) -> Result[String, Unit] {\n"
    <> "  match m.inner.get(k) {\n"
    <> "    Some(v) => Ok(v)\n"
    <> "    None => Err(())\n"
    <> "  }\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "moonbit/ba_map/ba_map.mbt"),
      contents: ba_map_mbt,
    )
    == Ok(Nil)

  let lib_src =
    "/// @external_type(moonbit, \"ba_map\", \"BaMap\")\n"
    <> "pub type BaMap {\n"
    <> "  BaMap(List(#(BitArray, String)))\n"
    <> "}\n\n"
    <> "pub fn assoc_insert(\n"
    <> "  entries: List(#(BitArray, String)),\n"
    <> "  key: BitArray,\n"
    <> "  val: String,\n"
    <> ") -> List(#(BitArray, String)) {\n"
    <> "  case entries {\n"
    <> "    [] -> [#(key, val)]\n"
    <> "    [#(k, _), ..rest] if k == key -> [#(key, val), ..rest]\n"
    <> "    [first, ..rest] -> [first, ..assoc_insert(rest, key, val)]\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn assoc_len(entries: List(#(BitArray, String))) -> Int {\n"
    <> "  case entries {\n"
    <> "    [] -> 0\n"
    <> "    [_, ..rest] -> 1 + assoc_len(rest)\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn assoc_get(\n"
    <> "  entries: List(#(BitArray, String)),\n"
    <> "  key: BitArray,\n"
    <> ") -> Result(String, Nil) {\n"
    <> "  case entries {\n"
    <> "    [] -> Error(Nil)\n"
    <> "    [#(k, v), ..] if k == key -> Ok(v)\n"
    <> "    [_, ..rest] -> assoc_get(rest, key)\n"
    <> "  }\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"ba_map\", \"map_new\")\n"
    <> "pub fn ba_map_new() -> BaMap {\n"
    <> "  BaMap([])\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"ba_map\", \"map_insert\")\n"
    <> "pub fn ba_map_insert(m: BaMap, k: BitArray, v: String) -> BaMap {\n"
    <> "  let BaMap(entries) = m\n"
    <> "  BaMap(assoc_insert(entries, k, v))\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"ba_map\", \"map_size\")\n"
    <> "pub fn ba_map_size(m: BaMap) -> Int {\n"
    <> "  let BaMap(entries) = m\n"
    <> "  assoc_len(entries)\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"ba_map\", \"map_get\")\n"
    <> "pub fn ba_map_get(m: BaMap, k: BitArray) -> Result(String, Nil) {\n"
    <> "  let BaMap(entries) = m\n"
    <> "  assoc_get(entries, k)\n"
    <> "}\n\n"
    <> "pub type Packet {\n"
    <> "  Packet(version: Int, flags: Int, payload: BitArray, crc: Int)\n"
    <> "  EmptyFrame\n"
    <> "  RawTail(BitArray)\n"
    <> "}\n\n"
    <> "fn with_bits(b: BitArray, k: fn(BitArray) -> a) -> a {\n"
    <> "  k(b)\n"
    <> "}\n\n"
    <> "pub fn parse_packet(b: BitArray) -> Result(Packet, Nil) {\n"
    <> "  case b {\n"
    <> "    <<>> -> Ok(EmptyFrame)\n"
    <> "    <<0:3, _:5, rest:bytes>> -> Ok(RawTail(rest))\n"
    <> "    <<version:3, flags:5, len:8, payload:bytes-size(len), crc:16-big>> ->\n"
    <> "      Ok(Packet(version:, flags:, payload:, crc:))\n"
    <> "    _ -> Error(Nil)\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn check_dict_and_equality() -> Bool {\n"
    <> "  let d =\n"
    <> "    ba_map_new()\n"
    <> "    |> ba_map_insert(<<1:1>>, \"one_bit\")\n"
    <> "    |> ba_map_insert(<<0x80>>, \"byte_128\")\n"
    <> "    |> ba_map_insert(<<0:1>>, \"z1\")\n"
    <> "    |> ba_map_insert(<<0:2>>, \"z2\")\n"
    <> "    |> ba_map_insert(<<0xAB>>, \"ab\")\n"
    <> "  let d2 = ba_map_insert(d, <<0xA:4, 0xB:4>>, \"ab2\")\n"
    <> "  <<0:1>> != <<0:2>>\n"
    <> "  && <<1:1>> != <<0x80>>\n"
    <> "  && <<0xAB>> == <<0xA:4, 0xB:4>>\n"
    <> "  && ba_map_size(d) == 5\n"
    <> "  && ba_map_size(d2) == 5\n"
    <> "  && ba_map_get(d2, <<0xAB>>) == Ok(\"ab2\")\n"
    <> "  && ba_map_get(d2, <<1:1>>) == Ok(\"one_bit\")\n"
    <> "  && ba_map_get(d2, <<0x80>>) == Ok(\"byte_128\")\n"
    <> "}\n\n"
    <> "pub fn check_int_widths_and_endianness() -> Bool {\n"
    <> "  let zero = 0\n"
    <> "  let neg = -5\n"
    <> "  let dyn_zero = <<42:size(zero)>>\n"
    <> "  let dyn_neg = <<42:size(neg)>>\n"
    <> "  let assert <<zval:size(zero), rest:bits>> = <<1, 2>>\n"
    <> "  let neg_pat_ok = case <<1, 2>> {\n"
    <> "    <<_:size(neg), _:bits>> -> False\n"
    <> "    <<_:bits>> -> True\n"
    <> "  }\n"
    <> "  let assert <<u12:12-little>> = <<0x123:12-little>>\n"
    <> "  let assert <<s12:12-little-signed, u12b:12-little-unsigned>> =\n"
    <> "    <<-20:12-little, -20:12-little>>\n"
    <> "  let assert <<b127:127-big-signed, l127:127-little-signed>> =\n"
    <> "    <<-1:127-big, -1:127-little>>\n"
    <> "  let assert <<b127u:127-big-unsigned, l127u:127-little-unsigned>> =\n"
    <> "    <<1:127-big, 1:127-little>>\n"
    <> "  let assert <<nval:12-native-signed>> = <<-33:12-native>>\n"
    <> "  let src = <<0xAB, 0xCD>>\n"
    <> "  let bits190_ok = case <<-1:190>> {\n"
    <> "    <<_:190>> -> True\n"
    <> "    _ -> False\n"
    <> "  }\n"
    <> "  dyn_zero == <<>>\n"
    <> "  && dyn_neg == <<>>\n"
    <> "  && <<0:-8>> == <<>>\n"
    <> "  && zval == 0\n"
    <> "  && rest == <<1, 2>>\n"
    <> "  && neg_pat_ok\n"
    <> "  && <<0x123:12-little>> == <<35, 1:4>>\n"
    <> "  && <<-20:12-little>> == <<236, 15:4>>\n"
    <> "  && u12 == 0x123\n"
    <> "  && s12 == -20\n"
    <> "  && u12b == 4076\n"
    <> "  && b127 == -1\n"
    <> "  && l127 == -1\n"
    <> "  && b127u == 1\n"
    <> "  && l127u == 1\n"
    <> "  && bits190_ok\n"
    <> "  && nval == -33\n"
    <> "  && <<0x123:3-unit(4)-big>> == <<0x12, 3:4>>\n"
    <> "  && <<src:bits-size(4)>> == <<0xA:4>>\n"
    <> "  && <<src:bits-size(8)>> == <<0xAB>>\n"
    <> "}\n\n"
    <> "pub fn check_floats() -> Bool {\n"
    <> "  let bare = <<1.5>>\n"
    <> "  let assert <<f64:64-float>> = bare\n"
    <> "  let assert <<f16b:16-float-big, f16l:16-float-little>> =\n"
    <> "    <<-2.25:16-float-big, 5.960464477539063e-8:16-float-little>>\n"
    <> "  let assert <<f32b:32-float-big, f32l:32-float-little, f32n:32-float-native>> =\n"
    <> "    <<-3.25:32-float-big, 1.5:32-float-little, 2.5:32-float-native>>\n"
    <> "  let lit_mismatch = case <<0.1:32-float>> {\n"
    <> "    <<0.1:32-float>> -> False\n"
    <> "    _ -> True\n"
    <> "  }\n"
    <> "  let match_f16 = fn(bits: BitArray) {\n"
    <> "    case bits {\n"
    <> "      <<_:16-float-big>> -> True\n"
    <> "      _ -> False\n"
    <> "    }\n"
    <> "  }\n"
    <> "  let match_f32 = fn(bits: BitArray) {\n"
    <> "    case bits {\n"
    <> "      <<_:32-float-big>> -> True\n"
    <> "      _ -> False\n"
    <> "    }\n"
    <> "  }\n"
    <> "  let match_f64 = fn(bits: BitArray) {\n"
    <> "    case bits {\n"
    <> "      <<_:64-float-big>> -> True\n"
    <> "      _ -> False\n"
    <> "    }\n"
    <> "  }\n"
    <> "  f64 == 1.5\n"
    <> "  && <<1.5:16-float-big>> == <<62, 0>>\n"
    <> "  && <<1.5:16-float-little>> == <<0, 62>>\n"
    <> "  && <<1.5:32-float-little>> == <<0, 0, 192, 63>>\n"
    <> "  && <<0.0:16-float-big>> == <<0, 0>>\n"
    <> "  && <<-0.0:16-float-big>> == <<128, 0>>\n"
    <> "  && <<65504.0:16-float-big>> == <<123, 255>>\n"
    <> "  && <<65520.0:16-float-big>> == <<124, 0>>\n"
    <> "  && <<5.960464477539063e-8:16-float-big>> == <<0, 1>>\n"
    <> "  && f16b == -2.25\n"
    <> "  && f16l == 5.960464477539063e-8\n"
    <> "  && f32b == -3.25\n"
    <> "  && f32l == 1.5\n"
    <> "  && f32n == 2.5\n"
    <> "  && lit_mismatch\n"
    <> "  && !match_f16(<<0x7C, 0x00>>)\n"
    <> "  && !match_f16(<<0xFC, 0x00>>)\n"
    <> "  && !match_f16(<<0x7E, 0x00>>)\n"
    <> "  && !match_f32(<<0x7F, 0x80, 0x00, 0x00>>)\n"
    <> "  && !match_f32(<<0x7F, 0xC0, 0x00, 0x00>>)\n"
    <> "  && !match_f64(<<0x7F, 0xF8, 0, 0, 0, 0, 0, 0>>)\n"
    <> "}\n\n"
    <> "pub fn check_utf() -> Bool {\n"
    <> "  let assert <<emoji_cp:utf8_codepoint>> = <<\"😀\":utf8>>\n"
    <> "  let assert <<acute_cp:utf8_codepoint>> = <<\"é\":utf8>>\n"
    <> "  let encoded =\n"
    <> "    <<\"GET \":utf8, \"é\":utf16-little, \"😀\":utf16-big, \"😀\":utf32-little, 5:3>>\n"
    <> "  let assert <<\n"
    <> "    \"GET \":utf8,\n"
    <> "    \"é\":utf16-little,\n"
    <> "    \"😀\":utf16-big,\n"
    <> "    \"😀\":utf32-little,\n"
    <> "    tail:bits,\n"
    <> "  >> = encoded\n"
    <> "  let assert <<c8:utf8_codepoint, c16:utf16_codepoint-little, c32:utf32_codepoint-big, _:utf8, after:bits>> =\n"
    <> "    <<emoji_cp:utf8_codepoint, acute_cp:utf16_codepoint-little, emoji_cp:utf32_codepoint-big, \"a!\":utf8>>\n"
    <> "  let bad_utf8 = fn(bits: BitArray) {\n"
    <> "    case bits {\n"
    <> "      <<_:utf8>> -> False\n"
    <> "      _ -> True\n"
    <> "    }\n"
    <> "  }\n"
    <> "  let bad_utf16 = case <<0xD8, 0x00>> {\n"
    <> "    <<_:utf16_codepoint-big>> -> False\n"
    <> "    _ -> True\n"
    <> "  }\n"
    <> "  let bad_utf32 = case <<0x00, 0x00, 0xD8, 0x00>> {\n"
    <> "    <<_:utf32_codepoint-big>> -> False\n"
    <> "    _ -> True\n"
    <> "  }\n"
    <> "  <<emoji_cp:utf8_codepoint>> == <<240, 159, 152, 128>>\n"
    <> "  && <<emoji_cp:utf16_codepoint-little>> == <<61, 216, 0, 222>>\n"
    <> "  && <<emoji_cp:utf32_codepoint-big>> == <<0, 1, 246, 0>>\n"
    <> "  && tail == <<5:3>>\n"
    <> "  && <<c8:utf32_codepoint-big>> == <<128512:32-big>>\n"
    <> "  && <<c16:utf32_codepoint-big>> == <<233:32-big>>\n"
    <> "  && <<c32:utf32_codepoint-big>> == <<128512:32-big>>\n"
    <> "  && after == <<\"!\":utf8>>\n"
    <> "  && bad_utf8(<<0xC0, 0xAF>>)\n"
    <> "  && bad_utf8(<<0xED, 0xA0, 0x80>>)\n"
    <> "  && bad_utf8(<<0xE2, 0x82>>)\n"
    <> "  && bad_utf16\n"
    <> "  && bad_utf32\n"
    <> "}\n\n"
    <> "pub fn check_patterns_scoping_and_control_flow() -> Bool {\n"
    <> "  let n = 4\n"
    <> "  let assert <<a:size(n), n:4, b:size(n)>> = <<5:4, 2:4, 1:2>>\n"
    <> "  let assert <<m:4, v:size(m * 2 - 1), tail:bits>> = <<3:4, 21:5, 1:1>>\n"
    <> "  let assert <<ha:4, hb:4, hrest:bits>> = << <<5:4, 10:4>>:bits-size(8), 3:2 >>\n"
    <> "  let assert <<nlen:4, npay:bits-size(nlen)>> = << <<6:4>>:bits-size(4), 42:6 >>\n"
    <> "  let assert #(Ok(<<t0:3, t1:5>>), [<<t2:4, _:bits>>]) =\n"
    <> "    #(Ok(<<5:3, 19:5>>), [<<9:4, 1:1>>])\n"
    <> "  let assert <<w0:4, w1:4>> as whole = <<0x4E>>\n"
    <> "  let multi = case <<1:4, 9:4>>, <<2:4, 7:4>> {\n"
    <> "    <<1:4, x:4>>, <<2:4, y:4>> -> x + y\n"
    <> "    _, _ -> 0\n"
    <> "  }\n"
    <> "  let alt = fn(bits: BitArray) {\n"
    <> "    case bits {\n"
    <> "      <<1:4, x:4>> | <<2:4, x:4>> -> x\n"
    <> "      _ -> -1\n"
    <> "    }\n"
    <> "  }\n"
    <> "  let guard_prune = fn(bits: BitArray) {\n"
    <> "    case bits {\n"
    <> "      <<byte, rest:bits>> if byte < 128 -> rest\n"
    <> "      _ -> <<>>\n"
    <> "    }\n"
    <> "  }\n"
    <> "  let body_prune = fn(bits: BitArray) {\n"
    <> "    case bits {\n"
    <> "      <<len:8, _:bytes-size(len)>> -> True\n"
    <> "      _ -> False\n"
    <> "    }\n"
    <> "  }\n"
    <> "  let let_rest = {\n"
    <> "    let <<r:bits>> = <<1:3, 2:4>>\n"
    <> "    r\n"
    <> "  }\n"
    <> "  let assert <<ah:3, bh:5>> = <<0x7B>> as \"bad header\"\n"
    <> "  let use_res = {\n"
    <> "    use <<urest:bits>> <- with_bits(<<0x6D, 1:1>>)\n"
    <> "    urest\n"
    <> "  }\n"
    <> "  let pkt = <<3:3, 19:5, 2:8, 0xAA, 0xBB, 0x1234:16-big>>\n"
    <> "  a == 5\n"
    <> "  && n == 2\n"
    <> "  && b == 1\n"
    <> "  && m == 3\n"
    <> "  && v == 21\n"
    <> "  && tail == <<1:1>>\n"
    <> "  && ha == 5\n"
    <> "  && hb == 10\n"
    <> "  && hrest == <<3:2>>\n"
    <> "  && nlen == 6\n"
    <> "  && npay == <<42:6>>\n"
    <> "  && t0 == 5 && t1 == 19 && t2 == 9\n"
    <> "  && w0 == 4 && w1 == 14 && whole == <<0x4E>>\n"
    <> "  && multi == 16\n"
    <> "  && alt(<<1:4, 11:4>>) == 11\n"
    <> "  && alt(<<2:4, 12:4>>) == 12\n"
    <> "  && alt(<<3:4, 12:4>>) == -1\n"
    <> "  && guard_prune(<<10, 1:2>>) == <<1:2>>\n"
    <> "  && guard_prune(<<200, 1:2>>) == <<>>\n"
    <> "  && body_prune(<<2, 99, 100>>)\n"
    <> "  && !body_prune(<<2, 99>>)\n"
    <> "  && let_rest == <<1:3, 2:4>>\n"
    <> "  && ah == 3 && bh == 27\n"
    <> "  && use_res == <<0x6D, 1:1>>\n"
    <> "  && parse_packet(<<>>) == Ok(EmptyFrame)\n"
    <> "  && parse_packet(<<0:3, 5:5, 1, 2>>) == Ok(RawTail(<<1, 2>>))\n"
    <> "  && parse_packet(<<0:3, 5:5, 1, 2:3>>) == Error(Nil)\n"
    <> "  && parse_packet(pkt) == Ok(Packet(3, 19, <<0xAA, 0xBB>>, 0x1234))\n"
    <> "}\n"

  let test_src =
    "import bit_array_t2\n\n"
    <> "pub fn main() -> Nil {\n"
    <> "  dict_and_equality_test()\n"
    <> "  int_widths_and_endianness_test()\n"
    <> "  floats_test()\n"
    <> "  utf_test()\n"
    <> "  patterns_scoping_and_control_flow_test()\n"
    <> "  Nil\n"
    <> "}\n\n"
    <> "pub fn dict_and_equality_test() {\n"
    <> "  assert bit_array_t2.check_dict_and_equality()\n}\n\n"
    <> "pub fn int_widths_and_endianness_test() {\n"
    <> "  assert bit_array_t2.check_int_widths_and_endianness()\n}\n\n"
    <> "pub fn floats_test() {\n"
    <> "  assert bit_array_t2.check_floats()\n}\n\n"
    <> "pub fn utf_test() {\n"
    <> "  assert bit_array_t2.check_utf()\n}\n\n"
    <> "pub fn patterns_scoping_and_control_flow_test() {\n"
    <> "  assert bit_array_t2.check_patterns_scoping_and_control_flow()\n}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/bit_array_t2.gleam"),
      contents: lib_src,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/bit_array_t2_test.gleam"),
      contents: test_src,
    )
    == Ok(Nil)

  let gleam_res = cmd.run(command: "gleam", args: ["test"], cwd: root)
  assert gleam_res.exit_code == 0

  let assert Ok(_) = workspace.transpile_project(root, out_dir)
  test_helpers.assert_all_moonbit_targets_ok(out_dir, "passed: 5, failed: 0")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn cli_parse_args_help_and_version_test() {
  assert gekko.parse_args([]) == Ok(gekko.HelpAction)
  assert gekko.parse_args(["--help"]) == Ok(gekko.HelpAction)
  assert gekko.parse_args(["-h"]) == Ok(gekko.HelpAction)
  assert gekko.parse_args(["help"]) == Ok(gekko.HelpAction)
  assert gekko.parse_args(["check", "--help"]) == Ok(gekko.HelpAction)
  assert gekko.parse_args(["build", "-h"]) == Ok(gekko.HelpAction)
  assert gekko.parse_args(["wit", "build", "--help"]) == Ok(gekko.HelpAction)
  assert gekko.parse_args(["moonbit", "bind", "--help"]) == Ok(gekko.HelpAction)

  assert gekko.parse_args(["--version"]) == Ok(gekko.VersionAction)
  assert gekko.parse_args(["-V"]) == Ok(gekko.VersionAction)
  assert gekko.parse_args(["version"]) == Ok(gekko.VersionAction)

  assert gekko.parse_args(["build", "--root", "app", "--target", "native"])
    == Ok(gekko.BuildAction(
      root: "app",
      out: None,
      work_dir: None,
      target: "native",
      release: False,
    ))
  assert gekko.parse_args(["build", "--release"])
    == Ok(gekko.BuildAction(
      root: ".",
      out: None,
      work_dir: None,
      target: "wasm",
      release: True,
    ))
  assert gekko.parse_args(["build"])
    == Ok(gekko.BuildAction(
      root: ".",
      out: None,
      work_dir: None,
      target: "wasm",
      release: False,
    ))
  assert gekko.parse_args(["build", "--out", "myfile.exe", "--target", "native"])
    == Ok(gekko.BuildAction(
      root: ".",
      out: Some("myfile.exe"),
      work_dir: None,
      target: "native",
      release: False,
    ))
  assert gekko.parse_args(["build", "-o", "out.wasm"])
    == Ok(gekko.BuildAction(
      root: ".",
      out: Some("out.wasm"),
      work_dir: None,
      target: "wasm",
      release: False,
    ))
  assert gekko.parse_args([
      "build",
      "--root=app",
      "--out=myfile.exe",
      "--work-dir=tmp_mbt",
      "--target=native",
    ])
    == Ok(gekko.BuildAction(
      root: "app",
      out: Some("myfile.exe"),
      work_dir: Some("tmp_mbt"),
      target: "native",
      release: False,
    ))

  // All subcommands default --root to "."
  assert gekko.parse_args(["check"])
    == Ok(gekko.CheckAction(root: ".", out: None, target: None))
  assert gekko.parse_args(["check", "--work-dir", "mbt_out"])
    == Ok(gekko.CheckAction(root: ".", out: Some("mbt_out"), target: None))
  assert gekko.parse_args(["test"])
    == Ok(gekko.TestAction(root: ".", out: None, target: None))
  assert gekko.parse_args(["run"])
    == Ok(gekko.RunAction(root: ".", out: None, target: None, program_args: []))
  assert gekko.parse_args([
      "run",
      "--target",
      "native",
      "--",
      "--flag",
      "val",
    ])
    == Ok(
      gekko.RunAction(
        root: ".",
        out: None,
        target: Some("native"),
        program_args: ["--flag", "val"],
      ),
    )
  assert gekko.parse_args(["new", "my_app"])
    == Ok(gekko.NewAction(name: "my_app", with_wit: False))
  assert gekko.parse_args(["new", "my_app", "--wit"])
    == Ok(gekko.NewAction(name: "my_app", with_wit: True))
  assert gekko.parse_args(["init", "--root", "proj", "--wit"])
    == Ok(gekko.InitAction(root: "proj", with_wit: True))
  assert gekko.parse_args(["clean", "--root", "proj"])
    == Ok(gekko.CleanAction(root: "proj"))
  assert gekko.parse_args(["doctor"]) == Ok(gekko.DoctorAction)
  assert gekko.parse_args(["wit", "gen"])
    == Ok(gekko.WitGenAction(root: ".", wit_dir: None, world: None))
  assert gekko.parse_args(["wit", "check"])
    == Ok(gekko.WitCheckAction(root: ".", wit_dir: None, world: None, out: None))
  assert gekko.parse_args(["wit", "build"])
    == Ok(gekko.WitBuildAction(
      root: ".",
      wit_dir: None,
      world: None,
      out: None,
      output: None,
      release: False,
    ))
  assert gekko.parse_args(["wit", "build", "--release", "-o", "out.wasm"])
    == Ok(gekko.WitBuildAction(
      root: ".",
      wit_dir: None,
      world: None,
      out: None,
      output: Some("out.wasm"),
      release: True,
    ))
  assert gekko.parse_args(["moonbit", "bind", "pkg"])
    == Ok(gekko.MoonbitBindAction(
      root: ".",
      package: "pkg",
      module: None,
      out: None,
    ))
  assert gekko.parse_args(["shim", "inspect", "simplifile", "--root", "app"])
    == Ok(gekko.ShimInspectAction(root: "app", package: "simplifile"))
  assert gekko.parse_args([
      "shim", "init", "simplifile", "--root", "app", "-o", "out_shim",
    ])
    == Ok(gekko.ShimInitAction(
      root: "app",
      package: "simplifile",
      out: Some("out_shim"),
    ))
  assert gekko.parse_args(["shim", "--help"]) == Ok(gekko.HelpAction)

  // Parse `moon build` artifact lines
  let sample_build_out =
    "Finished. moon: ran 2 tasks, now up to date\n"
    <> "Artifacts:\n"
    <> "  app/app  native  /tmp/my dir/build/native/app.exe\n"
    <> "  app/helper  wasm  /tmp/other/helper.wasm\n"
  assert gekko.parse_moon_build_artifacts(sample_build_out)
    == [
      #("app/app", "native", "/tmp/my dir/build/native/app.exe"),
      #("app/helper", "wasm", "/tmp/other/helper.wasm"),
    ]
  assert gekko.parse_moon_build_artifacts(
      "Finished. moon: ran 5 tasks, now up to date\n",
    )
    == []

  // Resolve output path rules
  assert gekko.resolve_build_output_path(None, "app.exe", fn(_) { False })
    == Ok("app.exe")
  assert gekko.resolve_build_output_path(Some("myfile.exe"), "app.exe", fn(_) {
      False
    })
    == Ok("myfile.exe")
  assert gekko.resolve_build_output_path(
      Some("dist/myfile.exe"),
      "app.exe",
      fn(_) { False },
    )
    == Ok("dist/myfile.exe")
  assert gekko.resolve_build_output_path(Some("dist/"), "app.exe", fn(_) {
      True
    })
    == Ok("dist/app.exe")
  assert gekko.resolve_build_output_path(Some(""), "app.exe", fn(_) { False })
    == Error("Output path cannot be empty.")
  let assert Error(dir_err) =
    gekko.resolve_build_output_path(Some("dist"), "app.exe", fn(p) {
      p == "dist"
    })
  assert string.contains(dir_err, "existing directory")
}

pub fn build_outputs_artifact_and_skips_tests_e2e_test() {
  let root = "build/test_fixtures/build_cli_app"
  let out_cwd = "build/test_fixtures/build_cli_out"
  let tmp_check_out = "build/test_fixtures/build_cli_check_out"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_cwd)
  let _ = simplifile.delete(file_or_dir_at: tmp_check_out)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.create_directory_all(out_cwd) == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"build_cli_app\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/build_cli_app.gleam"),
      contents: "pub fn main() -> Nil {\n  echo \"build_cli_ok\"\n  Nil\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/overflow_test.gleam"),
      contents: "pub fn huge_test() -> Int {\n  9_223_372_036_854_775_808\n}\n",
    )
    == Ok(Nil)

  // `transpile_project` (and `gekko check` / `gekko test`) still includes `test/`
  let assert Error(test_err) = workspace.transpile_project(root, tmp_check_out)
  assert string.contains(test_err, "Integer literal")

  // `gekko build` skips `test/` and places native `--out myfile.exe` in cwd cleanly
  let assert Ok(gekko.BuiltArtifact(path: native_custom_path, ..)) =
    gekko.build_project_in_dir(root, Some("myfile.exe"), "native", out_cwd)
  assert native_custom_path == "myfile.exe"
  let custom_exe_fs = filepath.join(out_cwd, "myfile.exe")
  assert simplifile.is_file(custom_exe_fs) == Ok(True)
  assert simplifile.is_directory(custom_exe_fs) == Ok(False)
  let run_custom = cmd.run(command: custom_exe_fs, args: [], cwd: ".")
  assert run_custom.exit_code == 0
  assert string.contains(run_custom.output, "build_cli_ok")

  // Default `--out` puts `<project>.exe` in cwd
  let assert Ok(gekko.BuiltArtifact(path: native_default_path, ..)) =
    gekko.build_project_in_dir(root, None, "native", out_cwd)
  assert native_default_path == "build_cli_app.exe"
  let default_exe_fs = filepath.join(out_cwd, "build_cli_app.exe")
  assert simplifile.is_file(default_exe_fs) == Ok(True)
  let run_default = cmd.run(command: default_exe_fs, args: [], cwd: ".")
  assert run_default.exit_code == 0
  assert string.contains(run_default.output, "build_cli_ok")

  // `--target wasm --out nested/custom.wasm`
  let assert Ok(gekko.BuiltArtifact(path: wasm_custom_path, ..)) =
    gekko.build_project_in_dir(
      root,
      Some("nested/custom.wasm"),
      "wasm",
      out_cwd,
    )
  assert wasm_custom_path == "nested/custom.wasm"
  let custom_wasm_fs = filepath.join(out_cwd, "nested/custom.wasm")
  assert simplifile.is_file(custom_wasm_fs) == Ok(True)
  let run_wasm = cmd.run(command: "moonrun", args: [custom_wasm_fs], cwd: ".")
  assert run_wasm.exit_code == 0
  assert string.contains(run_wasm.output, "build_cli_ok")

  // Default wasm-gc and js outputs
  let assert Ok(gekko.BuiltArtifact(path: wasm_gc_default_path, ..)) =
    gekko.build_project_in_dir(root, None, "wasm-gc", out_cwd)
  assert wasm_gc_default_path == "build_cli_app.wasm"
  assert simplifile.is_file(filepath.join(out_cwd, "build_cli_app.wasm"))
    == Ok(True)

  let assert Ok(gekko.BuiltArtifact(path: js_default_path, ..)) =
    gekko.build_project_in_dir(root, None, "js", out_cwd)
  assert js_default_path == "build_cli_app.js"
  assert simplifile.is_file(filepath.join(out_cwd, "build_cli_app.js"))
    == Ok(True)

  // Existing directory without trailing slash errors; with trailing slash places inside dir
  let existing_dir = filepath.join(out_cwd, "existing_dir")
  assert simplifile.create_directory_all(existing_dir) == Ok(Nil)
  let assert Error(dir_err) =
    gekko.build_project_in_dir(root, Some("existing_dir"), "wasm", out_cwd)
  assert string.contains(dir_err, "existing directory")
  let assert Ok(gekko.BuiltArtifact(path: in_dir_path, ..)) =
    gekko.build_project_in_dir(root, Some("existing_dir/"), "wasm", out_cwd)
  assert in_dir_path == "existing_dir/build_cli_app.wasm"
  assert simplifile.is_file(filepath.join(existing_dir, "build_cli_app.wasm"))
    == Ok(True)

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_cwd)
  let _ = simplifile.delete(file_or_dir_at: tmp_check_out)
  Nil
}

pub fn build_library_and_stale_test_cleanup_e2e_test() {
  let root = "build/test_fixtures/build_lib_pkg"
  let out_cwd = "build/test_fixtures/build_lib_out"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_cwd)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.create_directory_all(out_cwd) == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"build_lib_pkg\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/build_lib_pkg.gleam"),
      contents: "pub fn helper(x: Int) -> Int {\n  x + 1\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/lib_sample_test.gleam"),
      contents: "pub fn ok_test() -> Nil {\n  assert 1 == 1\n}\n",
    )
    == Ok(Nil)

  let work_dir = filepath.join(root, "build/moonbit")
  let assert Ok(_) = workspace.transpile_project(root, work_dir)
  assert simplifile.is_directory(filepath.join(work_dir, "test_lib_sample_test"))
    == Ok(True)

  // Now put an out-of-range test literal in test/ and run `build` (without `--out`)
  assert simplifile.write(
      to: filepath.join(root, "test/lib_sample_test.gleam"),
      contents: "pub fn huge_test() -> Int {\n  9_223_372_036_854_775_808\n}\n",
    )
    == Ok(Nil)

  let assert Ok(gekko.BuiltLibrary(project_name: "build_lib_pkg", ..)) =
    gekko.build_project_in_dir(root, None, "wasm", out_cwd)
  assert simplifile.is_directory(filepath.join(work_dir, "test_lib_sample_test"))
    == Ok(False)

  // Explicit `--out` on a library project without `pub fn main()` reports a clear error
  let assert Error(lib_err) =
    gekko.build_project_in_dir(root, Some("lib.wasm"), "wasm", out_cwd)
  assert string.contains(lib_err, "pub fn main()")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_cwd)
  Nil
}

pub fn scaffold_init_and_clean_e2e_test() {
  let root = "build/test_fixtures/scaffold_demo"
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(root) == Ok(Nil)

  let assert Ok(files) = scaffold.init_project(root, True)
  assert list.contains(files, "gleam.toml")
  assert list.contains(files, "src/scaffold_demo.gleam")
  assert list.contains(files, "wit/world.wit")
  assert list.contains(files, "src/app.gleam")
  assert simplifile.is_file(filepath.join(root, "gleam.toml")) == Ok(True)
  let assert Ok(toml) = simplifile.read(filepath.join(root, "gleam.toml"))
  assert string.contains(toml, "gleam_stdlib = \">= 1.0.0 and < 2.0.0\"")
  assert string.contains(
    toml,
    "gekko_stdlib = { git = \"https://github.com/spiral-nights/gekko_stdlib.git\", ref = \"main\" }",
  )
  assert string.contains(toml, "[tools.gekko.shims]")
  assert string.contains(toml, "gleam_stdlib = \"gekko_stdlib\"")

  // Refuses to overwrite existing gleam.toml
  let assert Error(overwrite_err) = scaffold.init_project(root, False)
  assert string.contains(overwrite_err, "Refusing to overwrite")

  // Rejects invalid project names including `*_test`
  let assert Error(_) = scaffold.new_project("bad_test", False)

  // `gekko clean` removes generated build/moonbit and staging dirs
  let mbt_dir = filepath.join(root, "build/moonbit")
  let stage_dir = filepath.join(root, "build/.gekko_staging")
  assert simplifile.create_directory_all(mbt_dir) == Ok(Nil)
  assert simplifile.create_directory_all(stage_dir) == Ok(Nil)
  let assert Ok(removed) = gekko.clean_project(root)
  assert list.contains(removed, mbt_dir)
  assert list.contains(removed, stage_dir)
  assert simplifile.is_directory(mbt_dir) == Ok(False)
  assert simplifile.is_directory(stage_dir) == Ok(False)

  let _ = simplifile.delete(file_or_dir_at: root)
  Nil
}
