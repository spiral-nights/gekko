import filepath
import gekko
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/cmd
import project/diagnostics
import project/ffi_config
import project/loader
import project/patch_discovery
import project/prepass.{
  ExternalType, GleamPatch, GleamPatchEntry, PackageCall, PreferErlang,
  PreferJavascript, WasmImport,
}
import project/shim_cli
import project/workspace
import simplifile

pub fn parse_overlay_sections_gekko_and_gleam_toml_test() {
  let gekko_toml =
    "
[shim_for]
package = \"simplifile\"
version = \">= 2.0.0 and < 3.0.0\"

[type_overrides.\"simplifile:simplifile.FileInfo\"]
package = \"simplifile_ffi\"
type = \"FileInfo\"

[overrides.\"simplifile:simplifile.read_bits\"]
package = \"simplifile_ffi\"
function = \"read_bits\"

[overrides.\"simplifile:simplifile.raw_op\"]
wasm_module = \"wasi\"
import_name = \"op\"

[patch.\"simplifile:simplifile\"]
file = \"patches/simplifile.mbt\"
imports = [\"gleam/string_tree as st\"]
types = [\"FileInfo\"]
functions = [\"parse_info\"]

[target_branch.\"simplifile:simplifile\"]
prefer = \"javascript\"
"

  let assert Ok(Some(shim)) = ffi_config.parse_shim_gekko_toml(gekko_toml)
  assert shim.target == "simplifile"
  assert shim.version == Some(">= 2.0.0 and < 3.0.0")

  let assert Ok(tys) = ffi_config.parse_type_overrides_gekko_toml(gekko_toml)
  assert dict.get(tys, "simplifile:simplifile.FileInfo")
    == Ok(ExternalType(package: "simplifile_ffi", type_name: "FileInfo"))

  let assert Ok(ovrs) = ffi_config.parse_gekko_toml(gekko_toml)
  assert dict.get(ovrs, "simplifile:simplifile.read_bits")
    == Ok(PackageCall(package: "simplifile_ffi", function: "read_bits"))
  assert dict.get(ovrs, "simplifile:simplifile.raw_op")
    == Ok(WasmImport(wasm_module: "wasi", import_name: "op"))

  let assert Ok(patches) = ffi_config.parse_module_patch_gekko_toml(gekko_toml)
  let assert Ok(patch) = dict.get(patches, "simplifile:simplifile")
  assert patch.files
    == [
      ffi_config.ModulePatchFile(
        source_path: "patches/simplifile.mbt",
        dest_filename: "simplifile.mbt",
        source_pkg: "",
      ),
    ]
  assert patch.imports
    == [
      ffi_config.ModulePatchImport(
        package: "gleam/string_tree",
        alias: Some("st"),
      ),
    ]
  assert patch.types == ["FileInfo"]
  assert patch.functions == ["parse_info"]

  let assert Ok(branches) =
    ffi_config.parse_target_branch_gekko_toml(gekko_toml)
  assert dict.get(branches, "simplifile:simplifile") == Ok(PreferJavascript)

  // Equivalent [tools.gekko.*] sections in gleam.toml
  let gleam_toml =
    "
name = \"my_shim\"
version = \"0.1.0\"

[tools.gekko.shim_for]
package = \"simplifile\"
version = \"~> 2.1\"

[tools.gekko.type_overrides.\"simplifile:simplifile.FileInfo\"]
package = \"simplifile_ffi\"
type = \"FileInfo\"

[tools.gekko.overrides.\"simplifile:simplifile.read_bits\"]
package = \"simplifile_ffi\"
function = \"read_bits\"

[tools.gekko.patch.\"simplifile:simplifile\"]
files = [\"patches/a.mbt\"]
imports = [\"simplifile_ffi @sffi\"]
functions = [\"parse_info\"]

[tools.gekko.target_branch.\"simplifile:simplifile\"]
prefer = \"erlang\"
"
  let assert Ok(Some(g_shim)) = ffi_config.parse_shim_gleam_toml(gleam_toml)
  assert g_shim.target == "simplifile"
  assert g_shim.version == Some("~> 2.1")
  let assert Ok(g_tys) = ffi_config.parse_type_overrides_gleam_toml(gleam_toml)
  assert dict.get(g_tys, "simplifile:simplifile.FileInfo")
    == Ok(ExternalType(package: "simplifile_ffi", type_name: "FileInfo"))
  let assert Ok(g_ovrs) = ffi_config.parse_gleam_toml_overrides(gleam_toml)
  assert dict.get(g_ovrs, "simplifile:simplifile.read_bits")
    == Ok(PackageCall(package: "simplifile_ffi", function: "read_bits"))
  let assert Ok(g_patches) =
    ffi_config.parse_module_patch_gleam_toml(gleam_toml)
  let assert Ok(g_patch) = dict.get(g_patches, "simplifile:simplifile")
  assert g_patch.imports
    == [
      ffi_config.ModulePatchImport(
        package: "simplifile_ffi",
        alias: Some("sffi"),
      ),
    ]
  assert g_patch.functions == ["parse_info"]
  let assert Ok(g_br) = ffi_config.parse_target_branch_gleam_toml(gleam_toml)
  assert dict.get(g_br, "simplifile:simplifile") == Ok(PreferErlang)

  // Invalid patch (both file & files) & branch checks
  let bad_patch = "[patch.\"m\"]\nfile = \"a.mbt\"\nfiles = [\"b.mbt\"]\n"
  let assert Error(_) = ffi_config.parse_module_patch_gekko_toml(bad_patch)

  let bad_branch = "[target_branch.\"m\"]\nprefer = \"python\"\n"
  let assert Error(_) = ffi_config.parse_target_branch_gekko_toml(bad_branch)
}

pub fn semver_constraint_matching_test() {
  assert ffi_config.version_matches_constraint("2.1.3", ">= 2.0.0 and < 3.0.0")
    == Ok(True)
  assert ffi_config.version_matches_constraint("3.0.0", ">= 2.0.0 and < 3.0.0")
    == Ok(False)
  assert ffi_config.version_matches_constraint("1.4.2", "~> 1.2") == Ok(True)
  assert ffi_config.version_matches_constraint("2.0.0", "~> 1.2") == Ok(False)
  assert ffi_config.version_matches_constraint("1.2.5", "~> 1.2.3") == Ok(True)
  assert ffi_config.version_matches_constraint("1.3.0", "~> 1.2.3") == Ok(False)
  assert ffi_config.version_matches_constraint("0.2.3", "^0.2.1") == Ok(True)
  assert ffi_config.version_matches_constraint("0.3.0", "^0.2.1") == Ok(False)
  assert ffi_config.version_matches_constraint("1.0.0-alpha.1", ">= 1.0.0")
    == Ok(False)
  assert ffi_config.version_matches_constraint("1.0.0", ">= 1.0.0-alpha.1")
    == Ok(True)
  assert ffi_config.version_matches_constraint("1.2.0", "== 1.2.0") == Ok(True)
  assert ffi_config.version_matches_constraint("1.2.1", "!= 1.2.0") == Ok(True)
  let assert Error(_) = ffi_config.version_matches_constraint("1.0.0", "bogus")
}

pub fn overlay_merging_conflict_and_root_resolution_test() {
  let empty_ov = fn(pkg) {
    ffi_config.PackageOverlay(
      source_pkg: pkg,
      shim: None,
      authorized_shims: dict.new(),
      overrides: dict.new(),
      type_overrides: dict.new(),
      gleam_type_patches: dict.new(),
      patch_mirrors: dict.new(),
      module_patches: dict.new(),
      target_branches: dict.new(),
    )
  }

  let shim_a =
    ffi_config.PackageOverlay(
      ..empty_ov("shim_a"),
      shim: Some(ffi_config.ShimMeta(target: "lib", version: None)),
      overrides: dict.from_list([
        #("lib:lib.foo", PackageCall("ffi_a", "foo")),
      ]),
    )
  let shim_b =
    ffi_config.PackageOverlay(
      ..empty_ov("shim_b"),
      shim: Some(ffi_config.ShimMeta(target: "lib", version: None)),
      overrides: dict.from_list([
        #("lib:lib.foo", PackageCall("ffi_b", "foo")),
      ]),
    )
  let shim_c =
    ffi_config.PackageOverlay(
      ..empty_ov("shim_c"),
      shim: Some(ffi_config.ShimMeta(target: "lib", version: None)),
      overrides: dict.from_list([
        #("lib:lib.bar", PackageCall("ffi_c", "bar")),
      ]),
    )

  let root_with_auth = fn(auth_list) {
    ffi_config.PackageOverlay(
      ..empty_ov("app"),
      authorized_shims: dict.from_list(auth_list),
    )
  }

  // Non-conflicting shims merge cleanly when authorized by root
  let assert Ok(ok_merged) =
    ffi_config.merge_overlays(
      [shim_a, shim_c],
      root_with_auth([#("lib", "shim_a")]),
    )
    |> fn(res) {
      case res {
        Error(_) ->
          // Note: two shims for the same target "lib" cannot both be authorized simultaneously
          ffi_config.merge_overlays(
            [shim_a],
            root_with_auth([#("lib", "shim_a")]),
          )
        Ok(_) -> res
      }
    }
  assert dict.get(ok_merged.overrides, "lib:lib.foo")
    == Ok(PackageCall("ffi_a", "foo"))

  // Unresolved conflict: authorizing shim_a rejects shim_b for the same target
  let assert Error(conflict_err) =
    ffi_config.merge_overlays(
      [shim_a, shim_b],
      root_with_auth([#("lib", "shim_a")]),
    )
  assert string.contains(conflict_err, "Security error")
  assert string.contains(conflict_err, "shim_b")
}

pub fn multi_error_unmapped_externals_and_shim_cli_test() {
  let root = "/tmp/gekko_shim_cli_proj"
  let dep_dir = filepath.join(root, "deps/raw_lib")
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(dep_dir, "src"))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(dep_dir, "gleam.toml"),
      contents: "name = \"raw_lib\"\nversion = \"1.2.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(dep_dir, "src/raw_lib.gleam"),
      contents: "pub type OpaqueHandle\n\n@external(erlang, \"raw\", \"one\")\npub fn first(x: Int) -> OpaqueHandle\n\n@external(erlang, \"raw\", \"two\")\npub fn second(h: OpaqueHandle) -> String\n",
    )
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\nraw_lib = { path = \"deps/raw_lib\" }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/app.gleam"),
      contents: "import raw_lib\npub fn main() { raw_lib.second(raw_lib.first(1)) }\n",
    )
    == Ok(Nil)

  // Loader must report BOTH unmapped functions in one error
  let assert Error(err) = loader.load_dependencies(root, dict.new())
  assert string.contains(err, "raw_lib:raw_lib.first")
  assert string.contains(err, "raw_lib:raw_lib.second")

  // `gekko shim inspect raw_lib` must list both functions and the opaque type
  let assert Ok(report) = shim_cli.inspect_package(root, Some("raw_lib"))
  assert string.contains(report, "raw_lib.OpaqueHandle")
  assert string.contains(report, "raw_lib.first")
  assert string.contains(report, "raw_lib.second")

  // `gekko shim new raw_lib` scaffolds [tools.gekko.shim_for] in gleam.toml and
  // #gekko.patch stubs in patches/<mod>/ without creating gekko.toml or moon.pkg
  let shim_out = filepath.join(root, "gekko_raw_lib")
  let assert Ok(_) = shim_cli.new_shim(root, "raw_lib", Some(shim_out))
  assert simplifile.is_file(filepath.join(shim_out, "gekko.toml")) != Ok(True)
  let assert Ok(shim_toml) =
    simplifile.read(filepath.join(shim_out, "gleam.toml"))
  assert string.contains(shim_toml, "[tools.gekko.shim_for]")
  assert string.contains(shim_toml, "package = \"raw_lib\"")
  assert string.contains(shim_toml, ">= 1.0.0 and < 2.0.0")
  assert simplifile.is_file(filepath.join(shim_out, "patches/raw_lib/moon.pkg"))
    != Ok(True)
  let assert Ok(stub_mbt) =
    simplifile.read(filepath.join(shim_out, "patches/raw_lib/raw_lib.mbt"))
  assert string.contains(stub_mbt, "#gekko.patch")
  assert string.contains(stub_mbt, "pub(all) enum OpaqueHandle")
  assert string.contains(stub_mbt, "pub fn first(")
  assert string.contains(stub_mbt, "pub fn second(")

  let _ = simplifile.delete(file_or_dir_at: root)
}

pub fn companion_shim_end_to_end_moon_test() {
  let root = "/tmp/gekko_shim_e2e_proj"
  let upstream_dir = filepath.join(root, "deps/upstream_lib")
  let shim_dir = filepath.join(root, "deps/gekko_upstream_lib")
  let out_dir = filepath.join(root, "build/moonbit")
  let _ = simplifile.delete(file_or_dir_at: root)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(upstream_dir, "src"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(shim_dir, "src"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(
      shim_dir,
      "patches/upstream_lib",
    ))
    == Ok(Nil)

  // 1. Completely unmodified upstream library (zero @external(moonbit) pragmas)
  assert simplifile.write(
      to: filepath.join(upstream_dir, "gleam.toml"),
      contents: "name = \"upstream_lib\"\nversion = \"1.2.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(upstream_dir, "src/upstream_helper.gleam"),
      contents: "pub fn helper_tag() -> String { \"ok\" }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(upstream_dir, "src/upstream_lib.gleam"),
      contents: "import upstream_helper\n\npub type Handle\n\npub type LibError {\n  Empty\n  BadCode(Int)\n}\n\n@external(erlang, \"erl_mod\", \"make_handle\")\npub fn make_handle(n: Int) -> Result(Handle, LibError)\n\n@external(erlang, \"erl_mod\", \"read_handle\")\npub fn read_handle(h: Handle) -> Int\n\n@target(erlang)\n@external(erlang, \"erl_mod\", \"platform_double\")\npub fn platform_double(x: Int) -> Int\n\n@target(javascript)\npub fn platform_double(x: Int) -> Int {\n  let _ = upstream_helper.helper_tag()\n  x * 2\n}\n",
    )
    == Ok(Nil)

  // 2. Companion shim package using zero gekko.toml: [tools.gekko.*] in gleam.toml
  //    + moon.pkg + #gekko.patch attributes
  assert simplifile.write(
      to: filepath.join(shim_dir, "gleam.toml"),
      contents: "name = \"gekko_upstream_lib\"\nversion = \"0.1.0\"\n\n[tools.gekko.shim_for]\npackage = \"upstream_lib\"\nversion = \">= 1.0.0 and < 2.0.0\"\n\n[tools.gekko.target_branch.\"upstream_lib:upstream_lib\"]\nprefer = \"javascript\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(shim_dir, "patches/upstream_lib/moon.pkg"),
      contents: "import {\n  \"upstream_helper\",\n  \"moonbitlang/core/math\",\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(shim_dir, "patches/upstream_lib/upstream_lib.mbt"),
      contents: "///|\n#gekko.patch\npub struct Handle {\n  value : Int64\n}\n\n///|\nfn private_helper(n : Int64) -> Int64 {\n  n\n}\n\n///|\n#gekko.patch\npub fn make_handle(n : Int64) -> Result[Handle, LibError] {\n  if n == 0L {\n    Err(Empty)\n  } else if n < 0L {\n    Err(BadCode(n))\n  } else {\n    let _ = @upstream_helper.helper_tag()\n    let _ = @math.floor(1.5)\n    Ok({ value: private_helper(n) })\n  }\n}\n\n///|\n#gekko.patch(\"read_handle\")\npub fn read_handle(h : Handle) -> Int64 {\n  h.value\n}\n",
    )
    == Ok(Nil)

  // 3. Root app depending on BOTH unmodified upstream_lib and gekko_upstream_lib,
  //    authorizing gekko_upstream_lib in [tools.gekko.use_shims]
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\nupstream_lib = { path = \"deps/upstream_lib\" }\ngekko_upstream_lib = { path = \"deps/gekko_upstream_lib\" }\n\n[tools.gekko.use_shims]\nupstream_lib = \"gekko_upstream_lib\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/app.gleam"),
      contents: "import upstream_lib\npub fn compute(x: Int) -> Result(Int, upstream_lib.LibError) {\n  case upstream_lib.make_handle(x) {\n    Ok(h) -> Ok(upstream_lib.read_handle(h) + upstream_lib.platform_double(x))\n    Error(e) -> Error(e)\n  }\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/app_suite.gleam"),
      contents: "import app\nimport upstream_lib\n\npub fn shim_e2e_test() {\n  assert app.compute(21) == Ok(63)\n  assert app.compute(0) == Error(upstream_lib.Empty)\n  assert app.compute(-5) == Error(upstream_lib.BadCode(-5))\n}\n",
    )
    == Ok(Nil)

  let assert Ok(summary) = workspace.transpile_project(root, out_dir)
  assert summary.warnings == []

  let chk =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert chk.exit_code == 0

  let test_run =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert test_run.exit_code == 0

  // 4. Verify version mismatch warning, unmatched override error, and stale patch cleanup
  assert simplifile.write(
      to: filepath.join(shim_dir, "gleam.toml"),
      contents: "name = \"gekko_upstream_lib\"\nversion = \"0.1.0\"\n\n[tools.gekko.shim_for]\npackage = \"upstream_lib\"\nversion = \">= 2.0.0\"\n\n[tools.gekko.target_branch.\"upstream_lib:upstream_lib\"]\nprefer = \"javascript\"\n",
    )
    == Ok(Nil)
  let assert Ok(summary2) = workspace.transpile_project(root, out_dir)
  assert list.any(summary2.warnings, fn(w) {
    string.contains(w, "expects 'upstream_lib' (>= 2.0.0)")
  })

  assert simplifile.write(
      to: filepath.join(shim_dir, "gleam.toml"),
      contents: "name = \"gekko_upstream_lib\"\nversion = \"0.1.0\"\n\n[tools.gekko.shim_for]\npackage = \"upstream_lib\"\nversion = \">= 1.0.0 and < 2.0.0\"\n\n[tools.gekko.overrides.\"upstream_lib:upstream_lib.nonexistent_fn\"]\npackage = \"upstream_ffi\"\nfunction = \"nope\"\n\n[tools.gekko.target_branch.\"upstream_lib:upstream_lib\"]\nprefer = \"javascript\"\n",
    )
    == Ok(Nil)
  let assert Error(unmatched_err) = workspace.transpile_project(root, out_dir)
  assert string.contains(
    unmatched_err,
    "upstream_lib:upstream_lib.nonexistent_fn",
  )

  // Remove patches/ and verify stale __gekko_patch_*.mbt is deleted
  let _ = simplifile.delete(file_or_dir_at: filepath.join(shim_dir, "patches"))
  assert simplifile.write(
      to: filepath.join(shim_dir, "gleam.toml"),
      contents: "name = \"gekko_upstream_lib\"\nversion = \"0.1.0\"\n\n[tools.gekko.shim_for]\npackage = \"upstream_lib\"\nversion = \">= 2.0.0\"\n\n[tools.gekko.type_overrides.\"upstream_lib:upstream_lib.Handle\"]\npackage = \"gprelude\"\ntype = \"Dynamic\"\n\n[tools.gekko.overrides.\"upstream_lib:upstream_lib.make_handle\"]\npackage = \"gprelude\"\nfunction = \"ignore\"\n\n[tools.gekko.overrides.\"upstream_lib:upstream_lib.read_handle\"]\npackage = \"gprelude\"\nfunction = \"ignore\"\n\n[tools.gekko.target_branch.\"upstream_lib:upstream_lib\"]\nprefer = \"javascript\"\n",
    )
    == Ok(Nil)
  let _ = workspace.transpile_project(root, out_dir)
  let stale_patch =
    filepath.join(out_dir, "upstream_lib/__gekko_patch_1_upstream_lib.mbt")
  assert simplifile.is_file(stale_patch) != Ok(True)

  let _ = simplifile.delete(file_or_dir_at: root)
}

pub fn local_closure_trait_bound_propagation_test() {
  let root = "/tmp/gekko_local_closure_bounds_proj"
  let out_dir = filepath.join(root, "build/moonbit")
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"closure_bounds\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/closure_bounds.gleam"),
      contents: "fn apply_all(items: List(k), init: acc, f: fn(acc, k) -> acc) -> acc {\n  case items {\n    [] -> init\n    [x, ..xs] -> apply_all(xs, f(init, x), f)\n  }\n}\n\npub fn count_equal(items: List(k), target: k) -> Int {\n  let step = fn(acc, item) {\n    case item == target {\n      True -> acc + 1\n      False -> acc\n    }\n  }\n  apply_all(items, 0, step)\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/closure_bounds_suite.gleam"),
      contents: "import closure_bounds\npub fn count_equal_test() {\n  assert closure_bounds.count_equal([1, 2, 1, 3, 1], 1) == 3\n}\n",
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)
  let chk =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert chk.exit_code == 0
  let tst =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert tst.exit_code == 0

  let _ = simplifile.delete(file_or_dir_at: root)
}

pub fn patch_discovery_attributes_and_moon_pkg_test() {
  let mbt_src =
    "// #gekko.patch inside comment must be ignored\n"
    <> "let s = \"#gekko.patch inside string\"\n"
    <> "#gekko.patch\n"
    <> "#derive(Eq)\n"
    <> "priv struct TransientDict[K, V] {\n  x : Int\n}\n\n"
    <> "#gekko.patch(\"println\")\n"
    <> "pub fn println_(s : String) -> Unit {\n  println(s)\n}\n\n"
    <> "#gekko.patch\n"
    <> "pub type Dynamic = @gprelude.Dynamic\n\n"
    <> "#gekko.patch\n"
    <> "pub type Option[T] = @prelude.Option[T]\n\n"
    <> "#gekko.patch\n"
    <> "pub fn[K : Eq + Hash, V] get_or(k : K, v : V) -> V {\n  v\n}\n\n"
    <> "fn private_helper() -> Unit { () }\n"
  let assert Ok(attrs) =
    patch_discovery.parse_mbt_patch_attributes(mbt_src, "test.mbt")
  assert attrs
    == [
      patch_discovery.DiscoveredPatchAttr(
        kind: patch_discovery.PatchType,
        mbt_name: "TransientDict",
        target_override: None,
        type_alias: None,
        line: 3,
        is_pub: False,
        param_count: None,
      ),
      patch_discovery.DiscoveredPatchAttr(
        kind: patch_discovery.PatchFn,
        mbt_name: "println_",
        target_override: Some("println"),
        type_alias: None,
        line: 9,
        is_pub: True,
        param_count: Some(1),
      ),
      patch_discovery.DiscoveredPatchAttr(
        kind: patch_discovery.PatchType,
        mbt_name: "Dynamic",
        target_override: None,
        type_alias: Some(#("gprelude", "Dynamic")),
        line: 14,
        is_pub: True,
        param_count: None,
      ),
      patch_discovery.DiscoveredPatchAttr(
        kind: patch_discovery.PatchType,
        mbt_name: "Option",
        target_override: None,
        type_alias: Some(#("builtin", "Option")),
        line: 17,
        is_pub: True,
        param_count: None,
      ),
      patch_discovery.DiscoveredPatchAttr(
        kind: patch_discovery.PatchFn,
        mbt_name: "get_or",
        target_override: None,
        type_alias: None,
        line: 20,
        is_pub: True,
        param_count: Some(2),
      ),
    ]

  // Unknown #gekko.* attribute must fail
  let assert Error(unk_err) =
    patch_discovery.parse_mbt_patch_attributes(
      "#gekko.bogus\npub fn f() -> Unit { () }\n",
      "bad.mbt",
    )
  assert string.contains(unk_err, "Unknown attribute '#gekko.bogus'")

  // Dangling #gekko.patch must fail
  let assert Error(dangling_err) =
    patch_discovery.parse_mbt_patch_attributes("#gekko.patch\n", "dangling.mbt")
  assert string.contains(
    dangling_err,
    "must precede a fn, struct, enum, or type",
  )

  // moon.pkg import parsing
  let moon_pkg_src =
    "// comment\n"
    <> "import {\n"
    <> "  \"moonbitlang/core/json\",\n"
    <> "  \"moonbitlang/core/string\" @str,\n"
    <> "  \"gleam/dict\" as @d,\n"
    <> "  \"my_shim/gprelude\",\n"
    <> "}\n\n"
    <> "test_import {\n"
    <> "  \"ignored/test_pkg\",\n"
    <> "}\n"
  let assert Ok(imps) =
    patch_discovery.parse_moon_pkg_imports(moon_pkg_src, "my_shim")
  assert imps
    == [
      patch_discovery.DiscoveredImport("moonbitlang/core/json", None),
      patch_discovery.DiscoveredImport("moonbitlang/core/string", Some("str")),
      patch_discovery.DiscoveredImport("gleam/dict", Some("d")),
    ]
}

pub fn dependency_overlay_security_scoping_test() {
  let empty_ov = fn(pkg) {
    ffi_config.PackageOverlay(
      source_pkg: pkg,
      shim: None,
      authorized_shims: dict.new(),
      overrides: dict.new(),
      type_overrides: dict.new(),
      gleam_type_patches: dict.new(),
      patch_mirrors: dict.new(),
      module_patches: dict.new(),
      target_branches: dict.new(),
    )
  }

  // 1. Dependency with overrides and NO [tools.gekko.shim_for] must fail
  let rogue_dep =
    ffi_config.PackageOverlay(
      ..empty_ov("rogue"),
      overrides: dict.from_list([
        #("gleam_stdlib:gleam/io.println", PackageCall("evil", "log")),
      ]),
    )
  let assert Error(no_shim_err) =
    ffi_config.merge_overlays([rogue_dep], empty_ov("app"))
  assert string.contains(no_shim_err, "Security error")
  assert string.contains(no_shim_err, "rogue")

  // 2. Dependency declaring [tools.gekko.shim_for] package = "gleam_crypto" NOT in root
  //    [tools.gekko.use_shims] must fail with copy-pasteable [tools.gekko.use_shims] hint
  let unauth_dep =
    ffi_config.PackageOverlay(
      ..empty_ov("evil_dep"),
      shim: Some(ffi_config.ShimMeta(target: "gleam_crypto", version: None)),
      overrides: dict.from_list([
        #("gleam_crypto:gleam/crypto.verify", PackageCall("evil", "verify")),
      ]),
    )
  let assert Error(unauth_err) =
    ffi_config.merge_overlays([unauth_dep], empty_ov("app"))
  assert string.contains(unauth_err, "Security error")
  assert string.contains(unauth_err, "[tools.gekko.use_shims]")
  assert string.contains(unauth_err, "gleam_crypto = \"evil_dep\"")

  // 3. Dependency targeting pkg_a when root authorized "other_shim" must fail
  let wrong_shim =
    ffi_config.PackageOverlay(
      ..empty_ov("shim_a"),
      shim: Some(ffi_config.ShimMeta(target: "pkg_a", version: None)),
      overrides: dict.from_list([
        #("pkg_a:pkg_a.fn1", PackageCall("ffi_a", "fn1")),
      ]),
    )
  let root_other =
    ffi_config.PackageOverlay(
      ..empty_ov("app"),
      authorized_shims: dict.from_list([#("pkg_a", "other_shim")]),
    )
  let assert Error(wrong_err) =
    ffi_config.merge_overlays([wrong_shim], root_other)
  assert string.contains(wrong_err, "Security error")
  assert string.contains(wrong_err, "other_shim")

  // 4. Authorized shim targeting pkg_a cannot patch pkg_b
  let cross_target_shim =
    ffi_config.PackageOverlay(
      ..empty_ov("shim_a"),
      shim: Some(ffi_config.ShimMeta(target: "pkg_a", version: None)),
      overrides: dict.from_list([
        #("pkg_b:pkg_b.fn1", PackageCall("evil", "fn1")),
      ]),
    )
  let root_auth_a =
    ffi_config.PackageOverlay(
      ..empty_ov("app"),
      authorized_shims: dict.from_list([#("pkg_a", "shim_a")]),
    )
  let assert Error(cross_err) =
    ffi_config.merge_overlays([cross_target_shim], root_auth_a)
  assert string.contains(cross_err, "Security error")
  assert string.contains(cross_err, "pkg_a")
  assert string.contains(cross_err, "pkg_b:pkg_b.fn1")

  // 5. Dependency declaring [tools.gekko.use_shims] cannot authorize itself or another dep
  let self_auth_dep =
    ffi_config.PackageOverlay(
      ..empty_ov("evil_dep"),
      shim: Some(ffi_config.ShimMeta(target: "gleam_crypto", version: None)),
      authorized_shims: dict.from_list([#("gleam_crypto", "evil_dep")]),
      overrides: dict.from_list([
        #("gleam_crypto:gleam/crypto.verify", PackageCall("evil", "verify")),
      ]),
    )
  let assert Error(self_auth_err) =
    ffi_config.merge_overlays([self_auth_dep], empty_ov("app"))
  assert string.contains(self_auth_err, "Security error")

  // 6. Root project without [tools.gekko.use_shims] can override any package
  let root_ov =
    ffi_config.PackageOverlay(
      ..empty_ov("app"),
      overrides: dict.from_list([
        #("pkg_b:pkg_b.fn1", PackageCall("local_ffi", "fn1")),
      ]),
    )
  let assert Ok(_) = ffi_config.merge_overlays([], root_ov)
}

pub fn patches_mirror_lsp_scaffold_guards_and_clean_test() {
  let root = "build/test_fixtures/shim_lsp_mirror_proj"
  let dep_dir = filepath.join(root, "deps/up_lib")
  let out_dir = filepath.join(root, "build/moonbit")
  let patches_dir = filepath.join(root, "patches")
  let _ = simplifile.delete(file_or_dir_at: root)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(dep_dir, "src/up"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(patches_dir, "up/alpha"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(patches_dir, "up/gamma"))
    == Ok(Nil)

  // Upstream package with patched (up/alpha) -> unpatched (up/beta) -> patched (up/gamma)
  assert simplifile.write(
      to: filepath.join(dep_dir, "gleam.toml"),
      contents: "name = \"up_lib\"\nversion = \"1.0.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(dep_dir, "src/up/gamma.gleam"),
      contents: "@external(erlang, \"erl_g\", \"tag_num\")\npub fn tag_num(x: Int) -> Int {\n  let _ = x\n  panic as \"todo\"\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(dep_dir, "src/up/beta.gleam"),
      contents: "import up/gamma\npub fn wrap_tag(x: Int) -> Int { gamma.tag_num(x) + 1 }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(dep_dir, "src/up/alpha.gleam"),
      contents: "import up/beta\n\npub type Mode {\n  Fast\n  Slow(Int)\n}\n\n@external(erlang, \"erl_a\", \"scale\")\npub fn scale(x: Int) -> Float\n\n@external(erlang, \"erl_a\", \"fallback_todo\")\npub fn fallback_todo(x: Int) -> Int {\n  let _ = x\n  todo\n}\n\npub fn pure_compute(m: Mode, x: Int) -> Int {\n  case m {\n    Fast -> beta.wrap_tag(x)\n    Slow(k) -> beta.wrap_tag(x) + k\n  }\n}\n",
    )
    == Ok(Nil)

  // Shim repo root using [tools.gekko.shim_for] and [tools.gekko.patches."up/alpha"]
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"gekko_up_lib\"\nversion = \"0.1.0\"\n\n[dependencies]\nup_lib = { path = \"deps/up_lib\" }\n\n[tools.gekko.shim_for]\npackage = \"up_lib\"\nversion = \">= 1.0.0 and < 2.0.0\"\n\n[tools.gekko.patches.\"up/alpha\"]\nimports = [\"moonbitlang/core/math\"]\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/gekko_up_lib.gleam"),
      contents: "pub fn main() -> Nil { Nil }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(patches_dir, "up/gamma/gamma.mbt"),
      contents: "///|\n#gekko.patch\npub fn tag_num(x : Int64) -> Int64 {\n  x * 10L\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(patches_dir, "up/alpha/alpha.mbt"),
      contents: "///|\n#gekko.patch\npub fn scale(x : Int64) -> Double {\n  @math.floor(x.to_double())\n}\n",
    )
    == Ok(Nil)

  // 1. Before patching fallback_todo, missing_externals includes it and --strict fails
  let assert Ok(summary0) =
    workspace.transpile_project_with_tests(root, out_dir, False)
  assert list.contains(
    summary0.missing_externals,
    "up_lib:up/alpha.fallback_todo",
  )
  let assert Error(strict_err) =
    gekko.build_project_with_strict_options(
      root,
      None,
      Some(out_dir),
      "wasm",
      ".",
      False,
      True,
    )
  assert string.contains(strict_err, "up/alpha.fallback_todo")

  // 2. Mirror-equality check: patches/ matches build/moonbit byte-for-byte
  let assert Ok(b_mod) = simplifile.read(filepath.join(out_dir, "moon.mod"))
  let assert Ok(p_mod) = simplifile.read(filepath.join(patches_dir, "moon.mod"))
  assert b_mod == p_mod

  let assert Ok(b_alpha_pkg) =
    simplifile.read(filepath.join(out_dir, "up/alpha/moon.pkg"))
  let assert Ok(p_alpha_pkg) =
    simplifile.read(filepath.join(patches_dir, "up/alpha/moon.pkg"))
  assert b_alpha_pkg == p_alpha_pkg

  let assert Ok(b_beta_pkg) =
    simplifile.read(filepath.join(out_dir, "up/beta/moon.pkg"))
  let assert Ok(p_beta_pkg) =
    simplifile.read(filepath.join(patches_dir, "up/beta/moon.pkg"))
  assert b_beta_pkg == p_beta_pkg

  let assert Ok(b_alpha_mbt) =
    simplifile.read(filepath.join(out_dir, "up/alpha/alpha.mbt"))
  let assert Ok(p_alpha_mbt) =
    simplifile.read(filepath.join(patches_dir, "up/alpha/alpha.g.mbt"))
  assert b_alpha_mbt == p_alpha_mbt

  let assert Ok(b_beta_mbt) =
    simplifile.read(filepath.join(out_dir, "up/beta/beta.mbt"))
  let assert Ok(p_beta_mbt) =
    simplifile.read(filepath.join(patches_dir, "up/beta/beta.g.mbt"))
  assert b_beta_mbt == p_beta_mbt

  // 3. moon check --deny-warn passes BOTH inside patches/ AND at root via moon.work
  let chk_patches =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: patches_dir,
    )
  assert chk_patches.exit_code == 0
  let chk_root =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: root,
    )
  assert chk_root.exit_code == 0

  // 4. Scaffolding: `gekko shim init` scaffolds missing `fallback_todo`, idempotency,
  //    `patch_decl` for type `Mode`, and `inspect` reports 0 missing
  let assert Ok(init_msg) = shim_cli.init_in_place(root)
  assert string.contains(init_msg, "up/alpha.fallback_todo")
  let assert Ok(alpha_after_init) =
    simplifile.read(filepath.join(patches_dir, "up/alpha/alpha.mbt"))
  assert string.contains(
    alpha_after_init,
    "pub fn fallback_todo(x : Int64) -> Int64",
  )
  // Idempotent second call leaves file untouched
  let assert Ok(_) = shim_cli.patch_decl(root, "up/alpha.fallback_todo")
  assert simplifile.read(filepath.join(patches_dir, "up/alpha/alpha.mbt"))
    == Ok(alpha_after_init)

  // Scaffold type Mode (must compile inside patches/)
  let assert Ok(_) = shim_cli.patch_decl(root, "up/alpha.Mode")
  let assert Ok(inspect_clean) = shim_cli.inspect_package(root, None)
  assert string.contains(inspect_clean, "Missing external functions: none")
  assert string.contains(inspect_clean, "Unmatched entries: 0")

  let assert Ok(summary1) =
    workspace.transpile_project_with_tests(root, out_dir, False)
  assert summary1.missing_externals == []
  let chk_after_scaffold =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: patches_dir,
    )
  assert chk_after_scaffold.exit_code == 0

  // Unannotated declaration conflict must error
  assert simplifile.write(
      to: filepath.join(patches_dir, "up/alpha/alpha.mbt"),
      contents: alpha_after_init
        <> "\n///|\npub fn pure_compute(m : Mode, x : Int64) -> Int64 {\n  x\n}\n",
    )
    == Ok(Nil)
  let assert Error(unannotated_err) =
    shim_cli.patch_decl(root, "up/alpha.pure_compute")
  assert string.contains(unannotated_err, "without #gekko.patch")

  // Restore clean alpha.mbt
  assert simplifile.write(
      to: filepath.join(patches_dir, "up/alpha/alpha.mbt"),
      contents: alpha_after_init,
    )
    == Ok(Nil)

  // 5. Guard #3: Type baseline & drift detection + ack
  let assert Ok(_) = shim_cli.ack_shims(root)
  assert simplifile.is_file(filepath.join(
      patches_dir,
      ".gekko_baseline/up/alpha.toml",
    ))
    == Ok(True)

  // Mutate upstream Mode variant
  assert simplifile.write(
      to: filepath.join(dep_dir, "src/up/alpha.gleam"),
      contents: "import up/beta\n\npub type Mode {\n  Fast\n  Slow(Int)\n  Turbo\n}\n\n@external(erlang, \"erl_a\", \"scale\")\npub fn scale(x: Int) -> Float\n\n@external(erlang, \"erl_a\", \"fallback_todo\")\npub fn fallback_todo(x: Int) -> Int {\n  let _ = x\n  todo\n}\n\npub fn pure_compute(m: Mode, x: Int) -> Int {\n  case m {\n    Fast -> beta.wrap_tag(x)\n    Slow(k) -> beta.wrap_tag(x) + k\n    Turbo -> 0\n  }\n}\n",
    )
    == Ok(Nil)
  let assert Error(drift_err) =
    workspace.transpile_project_with_tests(root, out_dir, False)
  assert string.contains(drift_err, "Type drift")
  assert string.contains(drift_err, "up/alpha.Mode")
  assert string.contains(drift_err, "gekko shim ack")

  let assert Ok(_) = shim_cli.ack_shims(root)
  let assert Ok(_) =
    workspace.transpile_project_with_tests(root, out_dir, False)

  // 6. Guard #2: Visibility/arity pre-check + __gekko_sigcheck_* sourcemap annotation
  assert simplifile.write(
      to: filepath.join(patches_dir, "up/gamma/gamma.mbt"),
      contents: "///|\n#gekko.patch\nfn tag_num(x : Int64) -> Int64 {\n  x\n}\n",
    )
    == Ok(Nil)
  let assert Error(vis_err) =
    workspace.transpile_project_with_tests(root, out_dir, False)
  assert string.contains(vis_err, "Signature mismatch")
  assert string.contains(vis_err, "patches/up/gamma/gamma.mbt:2")

  // Arity check
  assert simplifile.write(
      to: filepath.join(patches_dir, "up/gamma/gamma.mbt"),
      contents: "///|\n#gekko.patch\npub fn tag_num(x : Int64, extra : Int64) -> Int64 {\n  x + extra\n}\n",
    )
    == Ok(Nil)
  let assert Error(arity_err) =
    workspace.transpile_project_with_tests(root, out_dir, False)
  assert string.contains(arity_err, "expects 1 parameter(s), got 2")

  // Wrong return type (passes pre-check arity, caught by moon check via __gekko_sigcheck_tag_num)
  assert simplifile.write(
      to: filepath.join(patches_dir, "up/gamma/gamma.mbt"),
      contents: "///|\n#gekko.patch\npub fn tag_num(x : Int64) -> String {\n  x.to_string()\n}\n",
    )
    == Ok(Nil)
  let assert Ok(_) =
    workspace.transpile_project_with_tests(root, out_dir, False)
  let bad_chk =
    cmd.run(command: "moon", args: ["check", "--target", "wasm"], cwd: out_dir)
  assert bad_chk.exit_code != 0
  let annotated_sig = diagnostics.annotate_moon_output(out_dir, bad_chk.output)
  assert string.contains(
    annotated_sig,
    "Patch source: patches/up/gamma/gamma.mbt:2",
  )

  // Restore gamma.mbt and verify gekko clean preserves tracked .mbt + .gekko_baseline
  assert simplifile.write(
      to: filepath.join(patches_dir, "up/gamma/gamma.mbt"),
      contents: "///|\n#gekko.patch\npub fn tag_num(x : Int64) -> Int64 {\n  x * 10L\n}\n",
    )
    == Ok(Nil)
  let assert Ok(_) = gekko.clean_project(root)
  assert simplifile.is_file(filepath.join(patches_dir, "up/gamma/gamma.mbt"))
    == Ok(True)
  assert simplifile.is_file(filepath.join(
      patches_dir,
      ".gekko_baseline/up/alpha.toml",
    ))
    == Ok(True)
  assert simplifile.is_file(filepath.join(patches_dir, "moon.mod")) != Ok(True)
  assert simplifile.is_file(filepath.join(patches_dir, "up/alpha/moon.pkg"))
    != Ok(True)
  assert simplifile.is_file(filepath.join(patches_dir, "up/alpha/alpha.g.mbt"))
    != Ok(True)
  assert simplifile.is_file(filepath.join(root, "moon.work")) != Ok(True)

  let _ = simplifile.delete(file_or_dir_at: root)
  Nil
}

pub fn shim_migrate_single_file_and_moon_pkg_test() {
  let root = "build/test_fixtures/shim_migrate_proj"
  let patches_dir = filepath.join(root, "patches")
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(filepath.join(patches_dir, "gleam/sub"))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"my_shim\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(patches_dir, "top.mbt"),
      contents: "///|\n#gekko.patch\npub fn hi() -> Unit { () }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(patches_dir, "gleam/dict.mbt"),
      contents: "///|\n#gekko.patch\npub fn size() -> Int64 { 0L }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(patches_dir, "gleam/sub/moon.pkg"),
      contents: "import {\n  \"moonbitlang/core/math\",\n  \"my_shim/gprelude\",\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(patches_dir, "gleam/sub/sub.mbt"),
      contents: "///|\n#gekko.patch\npub fn f() -> Double { @math.floor(1.0) }\n",
    )
    == Ok(Nil)

  let assert Ok(_) = shim_cli.migrate_shims(root)
  assert simplifile.is_file(filepath.join(patches_dir, "top/top.mbt"))
    == Ok(True)
  assert simplifile.is_file(filepath.join(patches_dir, "gleam/dict/dict.mbt"))
    == Ok(True)
  assert simplifile.is_file(filepath.join(patches_dir, "gleam/sub/moon.pkg"))
    != Ok(True)
  let assert Ok(toml) = simplifile.read(filepath.join(root, "gleam.toml"))
  assert string.contains(toml, "[tools.gekko.patches.\"gleam/sub\"]")
  assert string.contains(toml, "\"moonbitlang/core/math\"")

  let _ = simplifile.delete(file_or_dir_at: root)
  Nil
}

pub fn prepass_gleam_patch_pragmas_test() {
  let src =
    "/// @patch(\"mod/alpha.fn_a\")
/// @gekko.patch(\"pkg:mod/alpha.fn_b\")
pub fn impl_ab(x: Int) -> Int {
  x + 1
}

/// @patch(\"mod/alpha.priv_fn\")
fn impl_priv() -> Bool {
  False
}
"
  let res = prepass.preprocess_module("my/shim", src)
  assert res.cleaned_source == src
  assert res.ffi_entries == []
  assert res.gleam_patches
    == [
      GleamPatchEntry(
        source_module: "my/shim",
        source_function: "impl_ab",
        target: "mod/alpha.fn_a",
        line: 1,
      ),
      GleamPatchEntry(
        source_module: "my/shim",
        source_function: "impl_ab",
        target: "pkg:mod/alpha.fn_b",
        line: 2,
      ),
      GleamPatchEntry(
        source_module: "my/shim",
        source_function: "impl_priv",
        target: "mod/alpha.priv_fn",
        line: 7,
      ),
    ]
}

pub fn ffi_config_gleam_patch_discovery_and_scope_test() {
  let root = "build/test_fixtures/gleam_patch_discovery"
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(filepath.join(root, "src/shims"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"gekko_up\"\nversion = \"0.1.0\"\n[tools.gekko.shim_for]\npackage = \"upstream\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/shims/up.gleam"),
      contents: "/// @patch(\"up.foo\")\npub fn foo_impl() -> Int { 1 }\n\n/// @gekko.patch(\"upstream:up.bar\")\nfn bar_impl() -> Bool { True }\n",
    )
    == Ok(Nil)

  let assert Ok(ov) = ffi_config.load_package_overlay(root, "gekko_up")
  assert dict.get(ov.overrides, "upstream:up.foo")
    == Ok(GleamPatch(source_module: "shims/up", source_function: "foo_impl"))
  assert dict.get(ov.overrides, "upstream:up.bar")
    == Ok(GleamPatch(source_module: "shims/up", source_function: "bar_impl"))

  // Duplicate target in same shim package errors
  assert simplifile.write(
      to: filepath.join(root, "src/shims/dup.gleam"),
      contents: "/// @patch(\"up.foo\")\npub fn dup_foo() -> Int { 2 }\n",
    )
    == Ok(Nil)
  assert ffi_config.load_package_overlay(root, "gekko_up") |> is_error

  // Conflict between MoonBit #gekko.patch and Gleam @patch errors
  let _ =
    simplifile.delete(file_or_dir_at: filepath.join(root, "src/shims/dup.gleam"))
  assert simplifile.create_directory_all(filepath.join(root, "patches/up"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "patches/up/up.mbt"),
      contents: "///|\n#gekko.patch\npub fn foo() -> Int64 { 3L }\n",
    )
    == Ok(Nil)
  let assert Error(conflict_err) =
    ffi_config.load_package_overlay(root, "gekko_up")
  assert string.contains(conflict_err, "Conflicting")

  let _ = simplifile.delete(file_or_dir_at: root)
  Nil
}

pub fn gleam_patch_end_to_end_splicing_test() {
  let base = "build/test_fixtures/gleam_patch_e2e"
  let up_dir = filepath.join(base, "upstream")
  let shim_dir = filepath.join(base, "gekko_upstream")
  let app_dir = filepath.join(base, "consumer_app")
  let _ = simplifile.delete(file_or_dir_at: base)

  assert simplifile.create_directory_all(filepath.join(up_dir, "src/up"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(shim_dir, "src"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(app_dir, "src"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(app_dir, "test"))
    == Ok(Nil)

  // Upstream package with public & private @external(erlang, ...) + generic eq fn + custom type
  assert simplifile.write(
      to: filepath.join(up_dir, "gleam.toml"),
      contents: "name = \"upstream\"\nversion = \"1.0.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(up_dir, "src/up/fs.gleam"),
      contents: "pub type FileErr {
  NotFound
  BadPath(reason: String)
}

pub fn helper_tag() -> String {
  \"UP\"
}

@external(erlang, \"up_ffi\", \"read_data\")
pub fn read_data(path: String) -> Result(String, FileErr)

@external(erlang, \"up_ffi\", \"is_win\")
fn is_win() -> Bool

@external(erlang, \"up_ffi\", \"same_val\")
pub fn same_val(a: x, b: x) -> Bool

pub fn check_path(p: String) -> String {
  case is_win() {
    True -> \"win:\" <> p
    False -> \"posix:\" <> p
  }
}
",
    )
    == Ok(Nil)

  // Companion shim package written purely in Gleam importing up/fs!
  assert simplifile.write(
      to: filepath.join(shim_dir, "gleam.toml"),
      contents: "name = \"gekko_upstream\"
version = \"0.1.0\"

[dependencies]
upstream = { path = \"../upstream\" }

[tools.gekko.shim_for]
package = \"upstream\"
version = \">= 1.0.0 and < 2.0.0\"
",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(shim_dir, "src/gekko_upstream.gleam"),
      contents: "import up/fs.{type FileErr, BadPath, NotFound}

const sep = \":\"

fn format_rec(prefix tag: String, name val: String, count n: Int) -> String {
  case n <= 0 {
    True -> tag <> sep <> val
    False -> format_rec(name: val, prefix: tag, count: n - 1)
  }
}

/// @patch(\"up/fs.read_data\")
pub fn read_data(path: String) -> Result(String, FileErr) {
  case path {
    \"\" -> Error(NotFound)
    \"bad\" -> Error(BadPath(reason: format_rec(prefix: fs.helper_tag(), name: path, count: 1)))
    _ -> {
      let sep = \"=\"
      Ok(fs.helper_tag() <> sep <> path)
    }
  }
}

/// @patch(\"up/fs.is_win\")
fn is_win_impl() -> Bool {
  False
}

/// @patch(\"up/fs.same_val\")
pub fn same_val_impl(first: t, second: t) -> Bool {
  first == second
}
",
    )
    == Ok(Nil)

  // Downstream consumer app enabling the Gleam companion shim
  assert simplifile.write(
      to: filepath.join(app_dir, "gleam.toml"),
      contents: "name = \"consumer_app\"
version = \"0.1.0\"

[dependencies]
upstream = { path = \"../upstream\" }
gekko_upstream = { path = \"../gekko_upstream\" }

[tools.gekko.use_shims]
upstream = \"gekko_upstream\"
",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "src/consumer_app.gleam"),
      contents: "import up/fs.{BadPath, NotFound}

pub fn run_all() -> #(Result(String, fs.FileErr), Result(String, fs.FileErr), Result(String, fs.FileErr), String, Bool) {
  #(
    fs.read_data(\"\"),
    fs.read_data(\"bad\"),
    fs.read_data(\"ok.txt\"),
    fs.check_path(\"/tmp\"),
    fs.same_val(42, 42) && !fs.same_val(1, 2),
  )
}
",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "test/consumer_app_test.gleam"),
      contents: "import consumer_app
import up/fs.{BadPath, NotFound}

pub fn patch_behavior_test() {
  assert consumer_app.run_all()
    == #(
      Error(NotFound),
      Error(BadPath(reason: \"UP:bad\")),
      Ok(\"UP=ok.txt\"),
      \"posix:/tmp\",
      True,
    )
}
",
    )
    == Ok(Nil)

  let out_dir = filepath.join(app_dir, "build/moonbit")
  let assert Ok(summary) = workspace.transpile_project(app_dir, out_dir)
  assert summary.missing_externals == []

  // Verify private is_win_impl was pruned from gekko_upstream.mbt (zero unused warnings)
  let assert Ok(shim_mbt) =
    simplifile.read(filepath.join(out_dir, "gekko_upstream/gekko_upstream.mbt"))
  assert !string.contains(shim_mbt, "is_win_impl")

  let chk =
    cmd.run("moon", ["check", "--deny-warn", "--target", "wasm"], out_dir)
  assert chk.exit_code == 0

  let tst = cmd.run("moon", ["test", "--target", "wasm"], out_dir)
  assert tst.exit_code == 0

  // Also test signature mismatch rejection
  let mismatch_src =
    "import up/fs.{type FileErr}
/// @patch(\"up/fs.read_data\")
pub fn read_data(path: Int) -> Result(String, FileErr) {
  let _ = path
  todo
}

/// @patch(\"up/fs.is_win\")
fn is_win_impl() -> Bool {
  False
}

/// @patch(\"up/fs.same_val\")
pub fn same_val_impl(first: t, second: t) -> Bool {
  first == second
}
"
  assert simplifile.write(
      to: filepath.join(shim_dir, "src/gekko_upstream.gleam"),
      contents: mismatch_src,
    )
    == Ok(Nil)
  let assert Error(sig_err) = workspace.transpile_project(app_dir, out_dir)
  assert string.contains(sig_err, "mismatch")

  let _ = simplifile.delete(file_or_dir_at: base)
  Nil
}

pub fn shim_cli_gleam_scaffolding_test() {
  let base = "build/test_fixtures/shim_cli_gleam"
  let up_dir = filepath.join(base, "raw_pkg")
  let app_dir = filepath.join(base, "my_app")
  let shim_dir = filepath.join(base, "gekko_raw_pkg")
  let _ = simplifile.delete(file_or_dir_at: base)

  assert simplifile.create_directory_all(filepath.join(up_dir, "src/raw"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(app_dir, "src"))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(up_dir, "gleam.toml"),
      contents: "name = \"raw_pkg\"\nversion = \"1.2.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(up_dir, "src/raw/io.gleam"),
      contents: "pub type IoErr { Failed }
@external(erlang, \"e\", \"read\")
pub fn read_txt(path: String) -> Result(String, IoErr)

@external(erlang, \"e\", \"ok_check\")
fn ok_check(flag: Bool) -> Bool

pub fn use_ok(flag: Bool) -> Bool {
  ok_check(flag)
}
",
    )
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(app_dir, "gleam.toml"),
      contents: "name = \"my_app\"\nversion = \"0.1.0\"\n[dependencies]\nraw_pkg = { path = \"../raw_pkg\" }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "src/my_app.gleam"),
      contents: "pub fn main() -> Int { 0 }\n",
    )
    == Ok(Nil)

  // 1. new_shim_with_style GleamShim scaffolds src/<shim>/<mod>.gleam
  let assert Ok(new_msg) =
    shim_cli.new_shim_with_style(
      app_dir,
      "raw_pkg",
      Some(shim_dir),
      shim_cli.GleamShim,
    )
  assert string.contains(new_msg, "Created companion shim")
  let generated_gleam =
    filepath.join(shim_dir, "src/gekko_raw_pkg/raw/io.gleam")
  let assert Ok(content) = simplifile.read(generated_gleam)
  assert string.contains(content, "import raw/io")
  assert string.contains(content, "/// @patch(\"raw/io.read_txt\")")
  assert string.contains(content, "/// @patch(\"raw/io.ok_check\")")
  assert string.contains(content, "Result(String, io.IoErr)")

  // Generated companion repo should pass `gleam check` cleanly
  assert simplifile.write(
      to: filepath.join(shim_dir, "gleam.toml"),
      contents: "name = \"gekko_raw_pkg\"\nversion = \"0.1.0\"\n[dependencies]\nraw_pkg = { path = \"../raw_pkg\" }\n[tools.gekko.shim_for]\npackage = \"raw_pkg\"\nversion = \">= 1.0.0 and < 2.0.0\"\n",
    )
    == Ok(Nil)
  let gchk = cmd.run("gleam", ["check"], shim_dir)
  assert gchk.exit_code == 0

  // 2. inspect_package counts Gleam patches
  let assert Ok(report) = shim_cli.inspect_package(shim_dir, None)
  assert string.contains(
    report,
    "Patched declarations: 2 (0 types, 2 functions)",
  )
  assert string.contains(report, "Missing external functions: none")

  // 3. patch_decl_with_style in-app scaffolds src/my_app/shims/raw/io.gleam
  let assert Ok(_) =
    shim_cli.patch_decl_with_style(
      app_dir,
      "raw_pkg:raw/io.ok_check",
      shim_cli.GleamShim,
    )
  let app_shim = filepath.join(app_dir, "src/my_app/shims/raw/io.gleam")
  let assert Ok(app_shim_src) = simplifile.read(app_shim)
  assert string.contains(
    app_shim_src,
    "/// @patch(\"raw_pkg:raw/io.ok_check\")",
  )
  let gchk2 = cmd.run("gleam", ["check"], app_dir)
  assert gchk2.exit_code == 0

  let _ = simplifile.delete(file_or_dir_at: base)
  Nil
}

pub fn gleam_patch_combined_external_and_same_basename_test() {
  let base = "build/test_fixtures/gleam_patch_ext_combo"
  let up_dir = filepath.join(base, "upstream")
  let app_dir = filepath.join(base, "my_app")
  let _ = simplifile.delete(file_or_dir_at: base)

  assert simplifile.create_directory_all(filepath.join(up_dir, "src/up"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(app_dir, "src/shims/up"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(
      app_dir,
      "moonbit/up_ffi",
    ))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(app_dir, "test"))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(up_dir, "gleam.toml"),
      contents: "name = \"upstream\"\nversion = \"1.0.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(up_dir, "src/up/fs.gleam"),
      contents: "pub type Tag { MkTag(label: String) }

@external(erlang, \"up_ffi\", \"eq_wrap\")
pub fn eq_wrap(a: k, b: k) -> Tag

@external(erlang, \"up_ffi\", \"direct_eq\")
pub fn direct_eq(a: k, b: k) -> Bool
",
    )
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(app_dir, "gleam.toml"),
      contents: "name = \"my_app\"\nversion = \"0.1.0\"\n[dependencies]\nupstream = { path = \"../upstream\" }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "moonbit/up_ffi/up_ffi.mbt"),
      contents: "///|\npub fn[K : Eq] eq_check(a : K, b : K) -> Bool {\n  a == b\n}\n",
    )
    == Ok(Nil)
  // Combined @patch + @external(moonbit, ...) directly alongside same-basename import
  assert simplifile.write(
      to: filepath.join(app_dir, "src/shims/up/fs.gleam"),
      contents: "import up/fs.{type Tag, MkTag}

/// @external(moonbit, \"up_ffi\", \"eq_check\")
/// @patch(\"upstream:up/fs.direct_eq\")
pub fn direct_eq_impl(a: k, b: k) -> Bool {
  let _ = a
  let _ = b
  panic as \"ffi\"
}

/// @patch(\"upstream:up/fs.eq_wrap\")
pub fn eq_wrap_impl(a: k, b: k) -> Tag {
  case direct_eq_impl(a, b) {
    True -> MkTag(\"same\")
    False -> MkTag(\"diff\")
  }
}
",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "src/my_app.gleam"),
      contents: "import up/fs
pub fn run() -> fs.Tag {
  fs.eq_wrap(1, 1)
}
",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "test/my_app_test.gleam"),
      contents: "import my_app
import up/fs.{MkTag}
pub fn eq_wrap_test() {
  assert my_app.run() == MkTag(\"same\")
  assert fs.eq_wrap(1, 2) == MkTag(\"diff\")
  assert fs.direct_eq(5, 5) == True
  assert fs.direct_eq(5, 6) == False
}
",
    )
    == Ok(Nil)

  let out_dir = filepath.join(app_dir, "build/moonbit")
  let assert Ok(_) = workspace.transpile_project(app_dir, out_dir)
  let chk =
    cmd.run("moon", ["check", "--deny-warn", "--target", "wasm"], out_dir)
  assert chk.exit_code == 0
  assert !string.contains(chk.output, "Warning:")
  let tst = cmd.run("moon", ["test", "--target", "wasm"], out_dir)
  assert tst.exit_code == 0

  let _ = simplifile.delete(file_or_dir_at: base)
  Nil
}

pub fn gleam_patch_prunes_unreferenced_private_types_test() {
  let base = "build/test_fixtures/gleam_patch_prune_priv"
  let up_dir = filepath.join(base, "upstream")
  let app_dir = filepath.join(base, "my_app")
  let _ = simplifile.delete(file_or_dir_at: base)

  assert simplifile.create_directory_all(filepath.join(up_dir, "src/up"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(app_dir, "src/shims"))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(up_dir, "gleam.toml"),
      contents: "name = \"upstream\"\nversion = \"1.0.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(up_dir, "src/up/m.gleam"),
      contents: "type UnusedPriv(k, v) { UnusedPriv(k) }

fn make_priv(x: a) -> UnusedPriv(a, b) {
  UnusedPriv(x)
}

pub fn compute(x: Int) -> Int {
  let _ = make_priv(x)
  x
}
",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "gleam.toml"),
      contents: "name = \"my_app\"\nversion = \"0.1.0\"\n[dependencies]\nupstream = { path = \"../upstream\" }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "src/shims/m_shim.gleam"),
      contents: "/// @patch(\"upstream:up/m.compute\")
pub fn compute_shim(x: Int) -> Int {
  x + 1
}
",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "src/my_app.gleam"),
      contents: "import up/m
pub fn main() -> Int {
  m.compute(1)
}
",
    )
    == Ok(Nil)

  let out_dir = filepath.join(app_dir, "build/moonbit")
  let assert Ok(_) = workspace.transpile_project(app_dir, out_dir)
  let assert Ok(mbt) =
    simplifile.read(from: filepath.join(out_dir, "up/m/m.mbt"))
  assert !string.contains(mbt, "UnusedPriv")
  let chk =
    cmd.run("moon", ["check", "--deny-warn", "--target", "wasm"], out_dir)
  assert chk.exit_code == 0

  let _ = simplifile.delete(file_or_dir_at: base)
  Nil
}

pub fn prepass_and_ffi_config_patch_type_and_mirror_test() {
  let mirror_src =
    "//// @patch_mirror(\"upstream:up/m\")
import up/m as target_m

/// @mirror_type(\"PrivNode\")
pub type PrivNode {
  Leaf(Int)
}

/// @mirror_opaque(\"Tok\")
pub type Tok {
  Tok(value: Int)
}

/// @mirror_to_public(\"Tok\")
pub fn to_tok(value: Tok) -> target_m.Tok {
  let _ = value
  panic as \"gekko @patch_mirror stub\"
}

/// @mirror_from_public(\"Tok\")
pub fn from_tok(value: target_m.Tok) -> Tok {
  let _ = value
  panic as \"gekko @patch_mirror stub\"
}

/// @mirror_const(\"tag\")
pub const tag: String = \"\"

/// @mirror_fn(\"helper\")
pub fn helper(x: Int) -> PrivNode {
  let _ = x
  panic as \"gekko @patch_mirror stub\"
}
"
  let mirror_res =
    prepass.preprocess_module("s/internal/upstream/up/m", mirror_src)
  let assert Some(info) = mirror_res.patch_mirror
  assert info.target == "upstream:up/m"
  assert list.length(info.decls) == 6

  let shim_src =
    "/// @patch_type(\"up/m.Handle\")
pub type Handle {
  Handle(id: Int)
}
"
  let shim_res = prepass.preprocess_module("s/up/m", shim_src)
  assert shim_res.gleam_type_patches
    == [
      prepass.GleamTypePatchEntry(
        source_module: "s/up/m",
        source_type: "Handle",
        target: "up/m.Handle",
        line: 1,
      ),
    ]

  // Discovery + duplicate & conflict checks + security confinement
  let root = "build/test_fixtures/patch_type_mirror_cfg"
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(filepath.join(
      root,
      "src/s/internal/upstream/up",
    ))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"gekko_up\"\nversion = \"0.1.0\"\n[tools.gekko.shim_for]\npackage = \"upstream\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/s/m.gleam"),
      contents: shim_src,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/s/internal/upstream/up/m.gleam"),
      contents: mirror_src,
    )
    == Ok(Nil)

  let assert Ok(ov) = ffi_config.load_package_overlay(root, "gekko_up")
  assert dict.get(ov.gleam_type_patches, "upstream:up/m.Handle")
    == Ok(prepass.GleamTypePatch(source_module: "s/m", source_type: "Handle"))
  assert dict.get(ov.patch_mirrors, "s/internal/upstream/up/m")
    == Ok("upstream:up/m")

  // Unauthorized dependency mirror/type patch must fail security check
  assert ffi_config.merge_overlays(
      [ov],
      ffi_config.PackageOverlay(
        source_pkg: "app",
        shim: None,
        authorized_shims: dict.new(),
        overrides: dict.new(),
        type_overrides: dict.new(),
        gleam_type_patches: dict.new(),
        patch_mirrors: dict.new(),
        module_patches: dict.new(),
        target_branches: dict.new(),
      ),
    )
    |> is_error

  // Conflict with [tools.gekko.type_overrides] errors
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"gekko_up\"\nversion = \"0.1.0\"\n[tools.gekko.shim_for]\npackage = \"upstream\"\n[tools.gekko.type_overrides.\"upstream:up/m.Handle\"]\npackage = \"gprelude\"\ntype = \"Dynamic\"\n",
    )
    == Ok(Nil)
  let assert Error(conf_err) = ffi_config.load_package_overlay(root, "gekko_up")
  assert string.contains(conf_err, "Conflicting")

  let _ = simplifile.delete(file_or_dir_at: root)
  Nil
}

pub fn gleam_patch_type_end_to_end_test() {
  let base = "build/test_fixtures/patch_type_e2e"
  let up_dir = filepath.join(base, "upstream")
  let shim_dir = filepath.join(base, "gekko_upstream")
  let app_dir = filepath.join(base, "consumer_app")
  let _ = simplifile.delete(file_or_dir_at: base)

  assert simplifile.create_directory_all(filepath.join(up_dir, "src/up"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(
      shim_dir,
      "src/gekko_upstream/ffi",
    ))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(
      shim_dir,
      "src/gekko_upstream/up",
    ))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(app_dir, "src"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(app_dir, "test"))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(up_dir, "gleam.toml"),
      contents: "name = \"upstream\"\nversion = \"1.0.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(up_dir, "src/up/box.gleam"),
      contents: "pub type ExtBox

type Transient(k, v)

@external(erlang, \"e\", \"new_b\")
pub fn new_box(x: a) -> ExtBox

@external(erlang, \"e\", \"to_t\")
fn to_transient(k: k, v: v) -> Transient(k, v)

@external(erlang, \"e\", \"read_t\")
fn read_transient(t: Transient(k, v)) -> #(k, v)

pub fn roundtrip(k: k, v: v) -> #(k, v) {
  read_transient(to_transient(k, v))
}

pub fn box_roundtrip(b: ExtBox) -> String {
  unbox(to_ext_t(b))
}

@external(erlang, \"e\", \"to_et\")
fn to_ext_t(b: ExtBox) -> ExtTransient

@external(erlang, \"e\", \"unbox\")
fn unbox(t: ExtTransient) -> String

type ExtTransient

pub type Handle

@external(erlang, \"e\", \"mk_h\")
pub fn make_handle(n: Int) -> Handle

@external(erlang, \"e\", \"get_h\")
pub fn read_handle(h: Handle) -> Int
",
    )
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(shim_dir, "gleam.toml"),
      contents: "name = \"gekko_upstream\"\nversion = \"0.1.0\"\n[dependencies]\nupstream = { path = \"../upstream\" }\n[tools.gekko.shim_for]\npackage = \"upstream\"\nversion = \">= 1.0.0 and < 2.0.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(shim_dir, "src/gekko_upstream/ffi/ext.gleam"),
      contents: "/// @external_type(moonbit, \"gprelude\", \"Dynamic\")
pub type DynBox

/// @external(moonbit, \"gprelude\", \"to_dynamic\")
pub fn box_val(x: a) -> DynBox {
  let _ = x
  panic as \"Implemented in MoonBit\"
}

pub fn unwrap_or(b: DynBox, fallback: String) -> String {
  let _ = b
  fallback
}
",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(shim_dir, "src/gekko_upstream/up/box.gleam"),
      contents: "import gekko_upstream/ffi/ext

/// @patch_type(\"upstream:up/box.ExtBox\")
pub type ExtBox =
  ext.DynBox

/// @patch_type(\"upstream:up/box.ExtTransient\")
pub type ExtTransient =
  ExtBox

/// @patch(\"upstream:up/box.new_box\")
pub fn new_box(x: a) -> ExtBox {
  ext.box_val(x)
}

/// @patch(\"upstream:up/box.to_ext_t\")
pub fn to_ext_t(b: ExtBox) -> ExtTransient {
  b
}

/// @patch(\"upstream:up/box.unbox\")
pub fn unbox(t: ExtTransient) -> String {
  ext.unwrap_or(t, \"unboxed\")
}

/// @patch_type(\"upstream:up/box.Transient\")
pub type Transient(k, v) =
  #(k, v)

/// @patch(\"upstream:up/box.to_transient\")
pub fn to_transient(k: k, v: v) -> Transient(k, v) {
  #(k, v)
}

/// @patch(\"upstream:up/box.read_transient\")
pub fn read_transient(t: Transient(k, v)) -> #(k, v) {
  t
}

/// @patch_type(\"upstream:up/box.Handle\")
pub type Handle {
  Handle(id: Int)
}

/// @patch(\"upstream:up/box.make_handle\")
pub fn make_handle(n: Int) -> Handle {
  Handle(id: n * 2)
}

/// @patch(\"upstream:up/box.read_handle\")
pub fn read_handle(h: Handle) -> Int {
  h.id
}
",
    )
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(app_dir, "gleam.toml"),
      contents: "name = \"consumer_app\"\nversion = \"0.1.0\"\n[dependencies]\nupstream = { path = \"../upstream\" }\ngekko_upstream = { path = \"../gekko_upstream\" }\n[tools.gekko.use_shims]\nupstream = \"gekko_upstream\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "src/consumer_app.gleam"),
      contents: "import up/box

pub fn run() -> #(#(String, Int), Int, String) {
  #(
    box.roundtrip(\"a\", 7),
    box.read_handle(box.make_handle(21)),
    box.box_roundtrip(box.new_box(\"ok\")),
  )
}
",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "test/consumer_app_test.gleam"),
      contents: "import consumer_app

pub fn patch_type_e2e_test() {
  assert consumer_app.run() == #(#(\"a\", 7), 42, \"unboxed\")
}
",
    )
    == Ok(Nil)

  let gchk = cmd.run("gleam", ["check"], shim_dir)
  assert gchk.exit_code == 0

  let out_dir = filepath.join(app_dir, "build/moonbit")
  let assert Ok(summary) = workspace.transpile_project(app_dir, out_dir)
  assert summary.missing_externals == []

  let chk =
    cmd.run("moon", ["check", "--deny-warn", "--target", "wasm"], out_dir)
  assert chk.exit_code == 0
  let tst = cmd.run("moon", ["test", "--target", "wasm"], out_dir)
  assert tst.exit_code == 0

  let _ = simplifile.delete(file_or_dir_at: base)
  Nil
}

pub fn gleam_patch_mirror_e2e_and_sync_test() {
  let base = "build/test_fixtures/patch_mirror_e2e"
  let up_dir = filepath.join(base, "upstream")
  let shim_dir = filepath.join(base, "gekko_upstream")
  let app_dir = filepath.join(base, "consumer_app")
  let _ = simplifile.delete(file_or_dir_at: base)

  assert simplifile.create_directory_all(filepath.join(up_dir, "src/up"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(app_dir, "src"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(app_dir, "test"))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(up_dir, "gleam.toml"),
      contents: "name = \"upstream\"\nversion = \"1.0.0\"\n",
    )
    == Ok(Nil)
  let initial_up_src =
    "type Node {
  Leaf(Int)
  Pair(Node, Node)
}

const prefix = \"v1:\"

fn format_node(prefix_tag tag: String, node n: Node) -> String {
  case n {
    Leaf(x) -> tag <> case x > 0 { True -> \"+\" False -> \"0\" }
    Pair(a, b) -> format_node(prefix_tag: tag, node: a) <> \",\" <> format_node(prefix_tag: tag, node: b)
  }
}

pub fn show_leaf(x: Int) -> String {
  format_node(prefix_tag: prefix, node: Leaf(x))
}

pub opaque type Token {
  Ident(name: String)
  Number(value: Int)
  Eof
}

pub fn format_token(t: Token) -> String {
  case t {
    Ident(name:) -> \"id:\" <> name
    Number(_) -> \"num\"
    Eof -> \"eof\"
  }
}

@external(erlang, \"e\", \"tok\")
pub fn tokenize(src: String) -> Token

@external(erlang, \"e\", \"eval\")
fn eval_node(x: Int) -> String

pub fn run_eval(x: Int) -> String {
  eval_node(x)
}
"
  assert simplifile.write(
      to: filepath.join(up_dir, "src/up/tok.gleam"),
      contents: initial_up_src,
    )
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(app_dir, "gleam.toml"),
      contents: "name = \"consumer_app\"\nversion = \"0.1.0\"\n[dependencies]\nupstream = { path = \"../upstream\" }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "src/consumer_app.gleam"),
      contents: "pub fn placeholder() -> Int { 0 }\n",
    )
    == Ok(Nil)

  // Scaffold companion shim with internal/upstream mirror
  let assert Ok(_) =
    shim_cli.new_shim_with_style(
      app_dir,
      "upstream",
      Some(shim_dir),
      shim_cli.GleamShim,
    )
  let mirror_path =
    filepath.join(shim_dir, "src/gekko_upstream/internal/upstream/up/tok.gleam")
  let assert Ok(mirror_src) = simplifile.read(mirror_path)
  assert string.contains(mirror_src, "//// @patch_mirror(\"upstream:up/tok\")")
  assert string.contains(mirror_src, "/// @mirror_type(\"Node\")")
  assert string.contains(mirror_src, "/// @mirror_opaque(\"Token\")")
  assert string.contains(mirror_src, "/// @mirror_to_public(\"Token\")")
  assert string.contains(mirror_src, "/// @mirror_from_public(\"Token\")")
  assert string.contains(mirror_src, "/// @mirror_const(\"prefix\")")
  assert string.contains(mirror_src, "/// @mirror_fn(\"format_node\")")

  // Point shim gleam.toml at local ../upstream and check generated stubs pass gleam check
  assert simplifile.write(
      to: filepath.join(shim_dir, "gleam.toml"),
      contents: "name = \"gekko_upstream\"\nversion = \"0.1.0\"\n[dependencies]\nupstream = { path = \"../upstream\" }\n[tools.gekko.shim_for]\npackage = \"upstream\"\nversion = \">= 1.0.0 and < 2.0.0\"\n",
    )
    == Ok(Nil)
  let gchk0 = cmd.run("gleam", ["check"], shim_dir)
  assert gchk0.exit_code == 0

  // Write pure-Gleam patches using upstream private items & opaque bridges
  assert simplifile.write(
      to: filepath.join(shim_dir, "src/gekko_upstream/up/tok.gleam"),
      contents: "import gekko_upstream/internal/upstream/up/tok as upstream
import up/tok

/// @patch(\"up/tok.tokenize\")
pub fn tokenize(src: String) -> upstream.Token {
  let local = case src {
    \"\" -> upstream.Eof
    \"num\" -> upstream.Number(value: 7)
    s -> upstream.Ident(name: s)
  }
  let pub_tok = upstream.to_token(local)
  case tok.format_token(pub_tok) {
    \"eof\" -> upstream.Eof
    _ -> upstream.from_token(pub_tok)
  }
}

/// @patch(\"up/tok.eval_node\")
pub fn eval_node(x: Int) -> String {
  let tree = upstream.Pair(upstream.Leaf(x), upstream.Leaf(0))
  upstream.format_node(prefix_tag: upstream.prefix, node: tree)
}
",
    )
    == Ok(Nil)
  let gchk1 = cmd.run("gleam", ["check"], shim_dir)
  assert gchk1.exit_code == 0

  assert simplifile.write(
      to: filepath.join(app_dir, "gleam.toml"),
      contents: "name = \"consumer_app\"\nversion = \"0.1.0\"\n[dependencies]\nupstream = { path = \"../upstream\" }\ngekko_upstream = { path = \"../gekko_upstream\" }\n[tools.gekko.use_shims]\nupstream = \"gekko_upstream\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "src/consumer_app.gleam"),
      contents: "import up/tok

pub fn run() -> #(String, String, String, String) {
  #(
    tok.format_token(tok.tokenize(\"\")),
    tok.format_token(tok.tokenize(\"num\")),
    tok.format_token(tok.tokenize(\"abc\")),
    tok.run_eval(5),
  )
}
",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "test/consumer_app_test.gleam"),
      contents: "import consumer_app

pub fn mirror_e2e_test() {
  assert consumer_app.run() == #(\"eof\", \"num\", \"id:abc\", \"v1:+,v1:0\")
}
",
    )
    == Ok(Nil)

  let out_dir = filepath.join(app_dir, "build/moonbit")
  let assert Ok(summary) = workspace.transpile_project(app_dir, out_dir)
  assert summary.missing_externals == []
  assert simplifile.is_directory(filepath.join(
      out_dir,
      "gekko_upstream/internal/upstream/up/tok",
    ))
    != Ok(True)

  let chk =
    cmd.run("moon", ["check", "--deny-warn", "--target", "wasm"], out_dir)
  assert chk.exit_code == 0
  let tst = cmd.run("moon", ["test", "--target", "wasm"], out_dir)
  assert tst.exit_code == 0

  // Drift detection + gekko shim sync
  let mutated_up_src = string.replace(initial_up_src, "prefix_tag", "label")
  assert simplifile.write(
      to: filepath.join(up_dir, "src/up/tok.gleam"),
      contents: mutated_up_src,
    )
    == Ok(Nil)
  // Clear cached dep build so updated upstream source is reloaded
  let _ = simplifile.delete(file_or_dir_at: filepath.join(app_dir, "build"))
  let _ = simplifile.delete(file_or_dir_at: filepath.join(shim_dir, "build"))
  let assert Error(drift_err) = workspace.transpile_project(app_dir, out_dir)
  assert string.contains(drift_err, "Mirror drift")
  assert string.contains(drift_err, "gekko shim sync")

  let assert Ok(sync_msg) = shim_cli.sync_shims(shim_dir)
  assert string.contains(sync_msg, "Updated @patch_mirror")
  let assert Ok(synced_mirror) = simplifile.read(mirror_path)
  assert string.contains(synced_mirror, "label tag: String")

  let _ = simplifile.delete(file_or_dir_at: base)
  Nil
}

pub fn gleam_patch_stray_mirror_ref_rejected_test() {
  let base = "build/test_fixtures/stray_mirror_ref"
  let up_dir = filepath.join(base, "upstream")
  let app_dir = filepath.join(base, "my_app")
  let _ = simplifile.delete(file_or_dir_at: base)

  assert simplifile.create_directory_all(filepath.join(up_dir, "src/up"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(
      app_dir,
      "src/my_app/internal/upstream/up",
    ))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(up_dir, "gleam.toml"),
      contents: "name = \"upstream\"\nversion = \"1.0.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(up_dir, "src/up/m.gleam"),
      contents: "const secret = 99
pub fn ok() -> Int { 1 }
",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "gleam.toml"),
      contents: "name = \"my_app\"\nversion = \"0.1.0\"\n[dependencies]\nupstream = { path = \"../upstream\" }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "src/my_app/internal/upstream/up/m.gleam"),
      contents: "//// @patch_mirror(\"upstream:up/m\")

/// @mirror_const(\"secret\")
pub const secret: Int = 0
",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(app_dir, "src/my_app.gleam"),
      contents: "import my_app/internal/upstream/up/m as upstream

pub fn leak() -> Int {
  upstream.secret
}
",
    )
    == Ok(Nil)

  let out_dir = filepath.join(app_dir, "build/moonbit")
  let assert Error(err) = workspace.transpile_project(app_dir, out_dir)
  assert string.contains(err, "outside of a @patch targeting")

  let _ = simplifile.delete(file_or_dir_at: base)
  Nil
}

fn is_error(res: Result(a, b)) -> Bool {
  case res {
    Ok(_) -> False
    Error(_) -> True
  }
}
