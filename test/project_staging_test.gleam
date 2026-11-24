import emit/pkg_config
import filepath
import glance
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import index/symbol_table
import project/cmd
import project/diagnostics
import project/ffi_config
import project/interface
import project/loader
import project/prepass
import project/staging
import project/workspace
import simplifile

pub fn prepass_doc_pragma_and_raw_attribute_test() {
  let src =
    "/// Reads a file from MoonBit WASI FS.\n"
    <> "/// @external(moonbit, \"my_org/wit_fs\", \"read_file\")\n"
    <> "pub fn read_file(path: String) -> Result(String, Nil) {\n"
    <> "  Error(Nil)\n"
    <> "}\n"
    <> "\n"
    <> "@external(moonbit, \"my_org/math\", \"fast_sqrt\")\n"
    <> "pub fn fast_sqrt(x: Float) -> Float\n"
    <> "\n"
    <> "@external(moonbit, \"wasm:env\", \"host_add\")\n"
    <> "pub fn host_add(a: Int, b: Int) -> Int\n"

  let assert Ok(#(ast_mod, res)) = prepass.parse_module("app/fs", src)

  // Raw lines preserved 1:1
  assert list.length(string.split(res.cleaned_source, "\n"))
    == list.length(string.split(src, "\n"))

  assert list.length(ast_mod.functions) == 3

  assert res.ffi_entries
    == [
      prepass.FfiEntry(
        module: "app/fs",
        function_name: "read_file",
        kind: prepass.PackageCall("my_org/wit_fs", "read_file"),
        source: prepass.DocPragma,
        line: 2,
      ),
      prepass.FfiEntry(
        module: "app/fs",
        function_name: "fast_sqrt",
        kind: prepass.PackageCall("my_org/math", "fast_sqrt"),
        source: prepass.RawAttribute,
        line: 7,
      ),
      prepass.FfiEntry(
        module: "app/fs",
        function_name: "host_add",
        kind: prepass.WasmImport("env", "host_add"),
        source: prepass.RawAttribute,
        line: 10,
      ),
    ]

  // Bodyless external functions received injected panic bodies while read_file kept its body
  assert string.contains(
    res.cleaned_source,
    "pub fn fast_sqrt(x: Float) -> Float { panic as \"external\" }",
  )
  assert string.contains(
    res.cleaned_source,
    "pub fn host_add(a: Int, b: Int) -> Int { panic as \"external\" }",
  )
  assert !string.contains(res.cleaned_source, "Error(Nil) { panic")
}

pub fn prepass_multiline_attribute_preserves_line_numbers_test() {
  let src =
    "pub fn before() -> Int { 1 }\n"
    <> "\n"
    <> "@external(\n"
    <> "  moonbit,\n"
    <> "  \"pkg/multi\",\n"
    <> "  \"do_work\",\n"
    <> ")\n"
    <> "pub fn do_work(\n"
    <> "  x: Int,\n"
    <> ") -> Result(\n"
    <> "  Int,\n"
    <> "  String,\n"
    <> ")\n"
    <> "\n"
    <> "pub fn after() -> Int { 2 }\n"

  let assert Ok(#(ast_mod, res)) = prepass.parse_module("multi", src)
  assert list.length(ast_mod.functions) == 3

  let src_lines = string.split(src, "\n")
  let clean_lines = string.split(res.cleaned_source, "\n")
  assert list.length(clean_lines) == list.length(src_lines)

  // Line 15 ("pub fn after() -> Int { 2 }") remains at line 15 (index 14)
  assert list.drop(clean_lines, 14) == ["pub fn after() -> Int { 2 }", ""]
  assert res.ffi_entries
    == [
      prepass.FfiEntry(
        module: "multi",
        function_name: "do_work",
        kind: prepass.PackageCall("pkg/multi", "do_work"),
        source: prepass.RawAttribute,
        line: 3,
      ),
    ]
}

// -----------------------------------------------------------------------------
// 2. FFI config parser tests
// -----------------------------------------------------------------------------
pub fn ffi_config_parse_gekko_and_gleam_toml_test() {
  let gekko_toml =
    "[overrides.\"simplifile.read\"]\n"
    <> "package = \"wasi/filesystem\"\n"
    <> "function = \"read_to_string\"\n"
    <> "\n"
    <> "[overrides.\"host.raw_log\"]\n"
    <> "wasm_module = \"wasi:cli/stdout\"\n"
    <> "import_name = \"write_bytes\"\n"

  let assert Ok(parsed_gekko) = ffi_config.parse_gekko_toml(gekko_toml)
  assert dict.get(parsed_gekko, "simplifile.read")
    == Ok(prepass.PackageCall("wasi/filesystem", "read_to_string"))
  assert dict.get(parsed_gekko, "host.raw_log")
    == Ok(prepass.WasmImport("wasi:cli/stdout", "write_bytes"))

  let gleam_toml =
    "name = \"demo\"\n"
    <> "version = \"0.1.0\"\n"
    <> "\n"
    <> "[tools.gekko.overrides.\"gleam/io.println\"]\n"
    <> "package = \"gekko/io\"\n"
    <> "function = \"println\"\n"

  let assert Ok(parsed_gleam) =
    ffi_config.parse_gleam_toml_overrides(gleam_toml)
  assert dict.get(parsed_gleam, "gleam/io.println")
    == Ok(prepass.PackageCall("gekko/io", "println"))
}

pub fn ffi_config_load_project_overrides_precedence_test() {
  let fixture_dir = "build/test_fixtures/ffi_cfg_fixture"
  let _ = simplifile.delete(file_or_dir_at: fixture_dir)
  let assert Ok(Nil) = simplifile.create_directory_all(fixture_dir)

  let assert Ok(Nil) =
    simplifile.write(
      to: filepath.join(fixture_dir, "gleam.toml"),
      contents: "name = \"cfg\"\nversion = \"0.1.0\"\n\n[tools.gekko.overrides.\"a.fn1\"]\npackage = \"old/pkg\"\nfunction = \"old_fn\"\n\n[tools.gekko.overrides.\"a.fn2\"]\npackage = \"keep/pkg\"\nfunction = \"keep_fn\"\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      to: filepath.join(fixture_dir, "gekko.toml"),
      contents: "[overrides.\"a.fn1\"]\npackage = \"new/pkg\"\nfunction = \"new_fn\"\n",
    )

  let assert Ok(merged) = ffi_config.load_project_overrides(fixture_dir)
  assert dict.get(merged, "a.fn1")
    == Ok(prepass.PackageCall("new/pkg", "new_fn"))
  assert dict.get(merged, "a.fn2")
    == Ok(prepass.PackageCall("keep/pkg", "keep_fn"))

  let _ = simplifile.delete(file_or_dir_at: fixture_dir)
  Nil
}

// -----------------------------------------------------------------------------
// 3. Package-interface decoder tests
// -----------------------------------------------------------------------------
pub fn interface_decode_json_test() {
  let json_sample =
    "{\n"
    <> "  \"name\": \"sample\",\n"
    <> "  \"version\": \"0.1.0\",\n"
    <> "  \"modules\": {\n"
    <> "    \"sample/core\": {\n"
    <> "      \"type-aliases\": {\n"
    <> "        \"Pair\": {\n"
    <> "          \"parameters\": 1,\n"
    <> "          \"alias\": {\n"
    <> "            \"kind\": \"tuple\",\n"
    <> "            \"elements\": [\n"
    <> "              { \"kind\": \"variable\", \"id\": 0 },\n"
    <> "              { \"kind\": \"named\", \"name\": \"Int\", \"package\": \"\", \"module\": \"gleam\", \"parameters\": [] }\n"
    <> "            ]\n"
    <> "          }\n"
    <> "        }\n"
    <> "      },\n"
    <> "      \"types\": {\n"
    <> "        \"Box\": {\n"
    <> "          \"parameters\": 1,\n"
    <> "          \"constructors\": [\n"
    <> "            {\n"
    <> "              \"name\": \"Box\",\n"
    <> "              \"parameters\": [\n"
    <> "                { \"label\": \"item\", \"type\": { \"kind\": \"variable\", \"id\": 0 } }\n"
    <> "              ]\n"
    <> "            }\n"
    <> "          ]\n"
    <> "        }\n"
    <> "      },\n"
    <> "      \"constants\": {\n"
    <> "        \"version_num\": {\n"
    <> "          \"implementations\": { \"gleam\": true, \"uses-erlang-externals\": false, \"uses-javascript-externals\": false },\n"
    <> "          \"type\": { \"kind\": \"named\", \"name\": \"Int\", \"package\": \"\", \"module\": \"gleam\", \"parameters\": [] }\n"
    <> "        }\n"
    <> "      },\n"
    <> "      \"functions\": {\n"
    <> "        \"map_pair\": {\n"
    <> "          \"implementations\": { \"gleam\": true, \"uses-erlang-externals\": false, \"uses-javascript-externals\": false },\n"
    <> "          \"parameters\": [\n"
    <> "            { \"label\": \"value\", \"type\": { \"kind\": \"variable\", \"id\": 0 } },\n"
    <> "            { \"label\": null, \"type\": { \"kind\": \"fn\", \"parameters\": [{ \"kind\": \"variable\", \"id\": 0 }], \"return\": { \"kind\": \"variable\", \"id\": 1 } } }\n"
    <> "          ],\n"
    <> "          \"return\": { \"kind\": \"tuple\", \"elements\": [{ \"kind\": \"variable\", \"id\": 1 }] }\n"
    <> "        }\n"
    <> "      }\n"
    <> "    }\n"
    <> "  }\n"
    <> "}\n"

  let assert Ok(iface) = interface.decode_package_interface(json_sample)
  assert iface.name == "sample"
  let assert Ok(mod_iface) = dict.get(iface.modules, "sample/core")
  let assert Ok(fn_sig) = dict.get(mod_iface.functions, "map_pair")
  assert fn_sig.return == interface.TupleType([interface.VariableType(1)])
  assert fn_sig.parameters
    == [
      interface.ResolvedParam(Some("value"), interface.VariableType(0)),
      interface.ResolvedParam(
        None,
        interface.FnType([interface.VariableType(0)], interface.VariableType(1)),
      ),
    ]
}

// -----------------------------------------------------------------------------
// 4. Shadow `pub` staging & HM inference tests
// -----------------------------------------------------------------------------
pub fn staging_promote_private_to_pub_test() {
  let src =
    "import gleam/option.{type Option}\n"
    <> "\n"
    <> "type Secret {\n"
    <> "  Secret(code: Int)\n"
    <> "}\n"
    <> "\n"
    <> "pub opaque type Box(a) {\n"
    <> "  Box(inner: a)\n"
    <> "}\n"
    <> "\n"
    <> "opaque type LocalOpaque {\n"
    <> "  LocalOpaque(Int)\n"
    <> "}\n"
    <> "\n"
    <> "const magic = 42\n"
    <> "\n"
    <> "@internal\n"
    <> "pub fn hidden_pub(x) { x }\n"
    <> "\n"
    <> "fn private_helper(x, y) {\n"
    <> "  let f = fn(z) { z + 1 }\n"
    <> "  f(x) + y\n"
    <> "}\n"

  let promoted = staging.promote_private_to_pub(src)
  assert string.contains(promoted, "import gleam/option.{type Option}")
  assert string.contains(promoted, "pub type Secret")
  assert string.contains(promoted, "pub type Box(a)")
  assert string.contains(promoted, "pub type LocalOpaque")
  assert string.contains(promoted, "pub const magic = 42")
  assert !string.contains(promoted, "@internal")
  assert string.contains(promoted, "pub fn hidden_pub(x) { x }")
  assert string.contains(promoted, "pub fn private_helper(x, y)")
  assert string.contains(promoted, "let f = fn(z) { z + 1 }")
}

pub fn staging_end_to_end_shadow_pub_interface_test() {
  let fixture_root = "build/test_fixtures/staging_project"
  let staging_dir = "build/test_fixtures/staging_out"
  let _ = simplifile.delete(file_or_dir_at: fixture_root)
  let _ = simplifile.delete(file_or_dir_at: staging_dir)

  let assert Ok(Nil) =
    simplifile.create_directory_all(filepath.join(
      fixture_root,
      "src/staging_project/internal",
    ))

  let assert Ok(Nil) =
    simplifile.write(
      to: filepath.join(fixture_root, "gleam.toml"),
      contents: "name = \"staging_project\"\nversion = \"0.1.0\"\ninternal_modules = [\"staging_project/internal/*\"]\n",
    )

  let main_src =
    "import staging_project/internal/helper\n"
    <> "\n"
    <> "type Secret {\n"
    <> "  Secret(code: Int)\n"
    <> "}\n"
    <> "\n"
    <> "pub opaque type Box(a) {\n"
    <> "  Box(inner: a)\n"
    <> "}\n"
    <> "\n"
    <> "@external(moonbit, \"mbt/math\", \"native_abs\")\n"
    <> "fn native_abs(x: Int) -> Int\n"
    <> "\n"
    <> "@internal\n"
    <> "pub fn add_and_wrap(a, b) {\n"
    <> "  let s = Secret(code: helper.bump(a + b))\n"
    <> "  #(s, Box(inner: True))\n"
    <> "}\n"

  let helper_src = "fn bump(n) {\n" <> "  n + 1\n" <> "}\n"

  let assert Ok(Nil) =
    simplifile.write(
      to: filepath.join(fixture_root, "src/staging_project.gleam"),
      contents: main_src,
    )
  let assert Ok(Nil) =
    simplifile.write(
      to: filepath.join(
        fixture_root,
        "src/staging_project/internal/helper.gleam",
      ),
      contents: helper_src,
    )

  let assert Ok(iface) =
    staging.extract_project_interface(fixture_root, staging_dir)

  // Internal module was exposed and private fn `bump` got inferred Int -> Int
  let assert Ok(helper_iface) =
    dict.get(iface.modules, "staging_project/internal/helper")
  let assert Ok(bump_sig) = dict.get(helper_iface.functions, "bump")
  assert bump_sig.parameters
    == [
      interface.ResolvedParam(None, interface.NamedType("Int", "", "gleam", [])),
    ]
  assert bump_sig.return == interface.NamedType("Int", "", "gleam", [])

  // Main module: private `Secret`, opaque `Box`, bodyless `native_abs`, and `@internal` `add_and_wrap` all resolved!
  let assert Ok(main_iface) = dict.get(iface.modules, "staging_project")
  let assert Ok(secret_def) = dict.get(main_iface.types, "Secret")
  assert list.length(secret_def.constructors) == 1
  let assert Ok(box_def) = dict.get(main_iface.types, "Box")
  assert list.length(box_def.constructors) == 1
  let assert Ok(abs_sig) = dict.get(main_iface.functions, "native_abs")
  assert abs_sig.return == interface.NamedType("Int", "", "gleam", [])
  let assert Ok(add_wrap_sig) = dict.get(main_iface.functions, "add_and_wrap")
  assert add_wrap_sig.parameters
    == [
      interface.ResolvedParam(None, interface.NamedType("Int", "", "gleam", [])),
      interface.ResolvedParam(None, interface.NamedType("Int", "", "gleam", [])),
    ]
  assert add_wrap_sig.return
    == interface.TupleType([
      interface.NamedType("Secret", "staging_project", "staging_project", []),
      interface.NamedType("Box", "staging_project", "staging_project", [
        interface.NamedType("Bool", "", "gleam", []),
      ]),
    ])

  // Verify SymbolTable merges real Shadow-pub PackageInterface onto private AST functions
  let assert Ok(#(main_ast, main_pre)) =
    prepass.parse_module("staging_project", main_src)
  let table =
    symbol_table.index_project(
      "staging_project",
      [#("staging_project", main_ast, main_pre)],
      Some(iface),
      dict.new(),
    )
  let assert Ok(main_syms) = dict.get(table.modules, "staging_project")
  let assert Ok(native_abs_fn) = dict.get(main_syms.functions, "native_abs")
  assert native_abs_fn.ffi
    == Some(prepass.PackageCall("mbt/math", "native_abs"))
  assert native_abs_fn.return_type
    == Some(interface.NamedType("Int", "", "gleam", []))

  let _ = simplifile.delete(file_or_dir_at: fixture_root)
  let _ = simplifile.delete(file_or_dir_at: staging_dir)
  Nil
}

// -----------------------------------------------------------------------------
// 5. Global Symbol Table Indexer tests
// -----------------------------------------------------------------------------
pub fn symbol_table_multi_module_indexing_test() {
  let types_src =
    "pub type User {\n"
    <> "  Admin(id: Int, name: String, level: Int)\n"
    <> "  Member(id: Int, name: String)\n"
    <> "}\n"
    <> "\n"
    <> "pub type Conflict {\n"
    <> "  Left(value: Int)\n"
    <> "  Right(value: String)\n"
    <> "}\n"
    <> "\n"
    <> "pub type Point {\n"
    <> "  Point(x: Float, y: Float)\n"
    <> "}\n"
    <> "\n"
    <> "pub type Tree {\n"
    <> "  Leaf(Int)\n"
    <> "  Node(left: Tree, right: Tree)\n"
    <> "}\n"
    <> "\n"
    <> "pub type Handler {\n"
    <> "  Handler(cb: fn(Int) -> Bool)\n"
    <> "}\n"
    <> "\n"
    <> "pub type Box(a) {\n"
    <> "  Box(item: a)\n"
    <> "}\n"

  let app_src =
    "import demo/types as t\n"
    <> "import demo/types.{Admin, type Handler}\n"
    <> "\n"
    <> "pub type AppState {\n"
    <> "  AppState(handlers: List(Handler), meta: #(Int, t.Tree))\n"
    <> "}\n"
    <> "\n"
    <> "pub type BadTree {\n"
    <> "  BadLeaf(Int)\n"
    <> "  BadNode(next: BadTree, on_visit: fn(Int) -> Int)\n"
    <> "}\n"
    <> "\n"
    <> "/// @external(moonbit, \"mbt/net\", \"send\")\n"
    <> "pub fn send_packet(to dest: String, body payload: String) -> Bool {\n"
    <> "  False\n"
    <> "}\n"
    <> "\n"
    <> "fn private_compute(a, b) {\n"
    <> "  a + b\n"
    <> "}\n"

  let assert Ok(#(types_ast, types_pre)) =
    prepass.parse_module("demo/types", types_src)
  let assert Ok(#(app_ast, app_pre)) = prepass.parse_module("demo/app", app_src)

  // Simulate package-interface output for `private_compute`
  let fake_iface =
    interface.PackageInterface(
      name: "demo",
      version: "0.1.0",
      modules: dict.from_list([
        #(
          "demo/app",
          interface.ModuleInterface(
            type_aliases: dict.new(),
            types: dict.new(),
            constants: dict.new(),
            functions: dict.from_list([
              #(
                "private_compute",
                interface.ResolvedFunction(
                  parameters: [
                    interface.ResolvedParam(
                      None,
                      interface.NamedType("Int", "", "gleam", []),
                    ),
                    interface.ResolvedParam(
                      None,
                      interface.NamedType("Int", "", "gleam", []),
                    ),
                  ],
                  return: interface.NamedType("Int", "", "gleam", []),
                  implementations: interface.Implementations(True, False, False),
                ),
              ),
            ]),
          ),
        ),
      ]),
    )

  let overrides =
    dict.from_list([
      #("demo/app.send_packet", prepass.PackageCall("override/net", "send_v2")),
    ])

  let table =
    symbol_table.index_project(
      "demo",
      [
        #("demo/types", types_ast, types_pre),
        #("demo/app", app_ast, app_pre),
      ],
      Some(fake_iface),
      overrides,
    )

  // 1. Import aliases & constructor resolution
  let assert Some(admin_ctor) =
    symbol_table.lookup_constructor(table, "demo/app", None, "Admin")
  assert admin_ctor.module == "demo/types"
  assert admin_ctor.type_name == "User"

  let assert Some(member_ctor) =
    symbol_table.lookup_constructor(table, "demo/app", Some("t"), "Member")
  assert member_ctor.variant_name == "Member"

  // 2. Shared fields synthesis metadata
  let assert Some(user_type) =
    symbol_table.lookup_type(table, "demo/types", None, "User")
  assert user_type.is_single_variant == False
  assert dict.keys(user_type.shared_fields) == ["id", "name"]

  let assert Some(conflict_type) =
    symbol_table.lookup_type(table, "demo/types", None, "Conflict")
  assert dict.is_empty(conflict_type.shared_fields)

  let assert Some(point_type) =
    symbol_table.lookup_type(table, "demo/types", None, "Point")
  assert point_type.is_single_variant == True
  assert dict.keys(point_type.shared_fields) == ["x", "y"]

  // 3. Transitive `has_function_field`
  let assert Some(handler_type) =
    symbol_table.lookup_type(table, "demo/types", None, "Handler")
  assert handler_type.has_function_field == True

  let assert Some(tree_type) =
    symbol_table.lookup_type(table, "demo/types", None, "Tree")
  assert tree_type.has_function_field == False

  let assert Some(box_type) =
    symbol_table.lookup_type(table, "demo/types", None, "Box")
  assert box_type.has_function_field == False

  let assert Some(app_state_type) =
    symbol_table.lookup_type(table, "demo/app", None, "AppState")
  assert app_state_type.has_function_field == True

  let assert Some(bad_tree_type) =
    symbol_table.lookup_type(table, "demo/app", None, "BadTree")
  assert bad_tree_type.has_function_field == True

  // 4. Function arity, labels, FFI override precedence, and HM private types
  let assert Ok(app_syms) = dict.get(table.modules, "demo/app")
  let assert Ok(send_fn) = dict.get(app_syms.functions, "send_packet")
  assert send_fn.arity == 2
  assert list.map(send_fn.parameters, fn(p) { p.label })
    == [Some("to"), Some("body")]
  assert send_fn.ffi == Some(prepass.PackageCall("override/net", "send_v2"))

  let assert Ok(priv_fn) = dict.get(app_syms.functions, "private_compute")
  assert priv_fn.publicity == glance.Private
  assert priv_fn.return_type
    == Some(interface.NamedType("Int", "", "gleam", []))
}

// -----------------------------------------------------------------------------
// 6. Phase 2: Mangling tests
// -----------------------------------------------------------------------------
pub fn loader_dependency_fallback_and_unmapped_error_test() {
  assert !loader.is_intercepted_package("gleam_stdlib")
  assert !loader.is_intercepted_package("gleam_json")
  assert loader.is_intercepted_package("gleeunit")
  assert loader.is_intercepted_package("gleam_erlang")
  assert loader.is_intercepted_package("gleam_javascript")
  assert !loader.is_intercepted_package("tiny_slug")

  let root = "build/test_fixtures/loader_case"
  let _ = simplifile.delete(file_or_dir_at: root)
  let packages_dir = filepath.join(root, "build/packages")
  assert simplifile.create_directory_all(packages_dir) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"loader_app\"\nversion = \"0.1.0\"\n\n[dependencies]\nbase_pkg = \">= 0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/loader_app.gleam"),
      contents: "pub fn id(x: Int) -> Int { x }\n",
    )
    == Ok(Nil)

  let base_dir = filepath.join(packages_dir, "base_pkg")
  assert simplifile.create_directory_all(filepath.join(base_dir, "src"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(base_dir, "gleam.toml"),
      contents: "name = \"base_pkg\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(base_dir, "src/base_mod.gleam"),
      contents: "pub fn one() -> Int {\n  1\n}\n",
    )
    == Ok(Nil)

  // Dependency with Erlang external AND pure-Gleam fallback body
  let good_dir = filepath.join(packages_dir, "good_pkg")
  assert simplifile.create_directory_all(filepath.join(good_dir, "src"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(good_dir, "gleam.toml"),
      contents: "name = \"good_pkg\"\nversion = \"0.1.0\"\n\n[dependencies]\nbase_pkg = \">= 0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(good_dir, "src/good_mod.gleam"),
      contents: "@external(erlang, \"lists\", \"reverse\")\npub fn rev(xs: List(a)) -> List(a) { xs }\n",
    )
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(packages_dir, "packages.toml"),
      contents: "[packages]\nbase_pkg = \"0.1.0\"\ngood_pkg = \"0.1.0\"\n\n[git]\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "manifest.toml"),
      contents: "packages = [\n  { name = \"base_pkg\", version = \"0.1.0\", build_tools = [\"gleam\"], requirements = [], otp_app = \"base_pkg\", source = \"hex\", outer_checksum = \"00\" },\n  { name = \"good_pkg\", version = \"0.1.0\", build_tools = [\"gleam\"], requirements = [\"base_pkg\"], otp_app = \"good_pkg\", source = \"hex\", outer_checksum = \"00\" },\n]\n\n[requirements]\nbase_pkg = { version = \">= 0.1.0\" }\n",
    )
    == Ok(Nil)

  let assert Ok(loaded_good) = loader.load_dependencies(root, dict.new())
  assert list.map(loaded_good, fn(d) { d.package_name })
    == [
      "base_pkg",
      "good_pkg",
    ]

  // Dependency with bodyless Erlang external and no gekko.toml override must fail fast
  let bad_dir = filepath.join(packages_dir, "bad_pkg")
  assert simplifile.create_directory_all(filepath.join(bad_dir, "src"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(bad_dir, "gleam.toml"),
      contents: "name = \"bad_pkg\"\nversion = \"0.1.0\"\n\n[dependencies]\nbase_pkg = \">= 0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(bad_dir, "src/bad_mod.gleam"),
      contents: "@external(erlang, \"bad_erl\", \"missing\")\npub fn missing() -> Int\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(packages_dir, "packages.toml"),
      contents: "[packages]\nbase_pkg = \"0.1.0\"\ngood_pkg = \"0.1.0\"\nbad_pkg = \"0.1.0\"\n\n[git]\n",
    )
    == Ok(Nil)

  let assert Error(unmapped_err) = loader.load_dependencies(root, dict.new())
  assert string.contains(
    unmapped_err,
    "Unmapped external function bad_pkg:bad_mod.missing at bad_pkg:src/bad_mod.gleam:",
  )
  assert string.contains(unmapped_err, "gekko shim init")

  // Adding a gekko.toml override satisfies validation and loads both deps
  assert simplifile.write(
      to: filepath.join(root, "gekko.toml"),
      contents: "[overrides.\"bad_pkg:bad_mod.missing\"]\nwasm_module = \"env\"\nimport_name = \"missing\"\n",
    )
    == Ok(Nil)
  let assert Ok(overrides) = ffi_config.load_project_overrides(root)
  let assert Ok(loaded_both) = loader.load_dependencies(root, overrides)
  assert list.length(loaded_both) == 3

  let _ = simplifile.delete(file_or_dir_at: root)
  Nil
}

pub fn moonbit_deps_config_and_moon_mod_emission_test() {
  let gleam_toml =
    "name = \"dep_demo\"\nversion = \"0.1.0\"\n\n"
    <> "[gekko.moonbit.deps]\n"
    <> "\"moonbitlang/x\" = \"0.4.5\"\n"
    <> "\"alice/json_ext\" = \"0.1.0\"\n"
  let gekko_toml =
    "[moonbit.deps]\n"
    <> "\"moonbitlang/x\" = \"0.4.6\"\n"
    <> "\"bob/regex\" = \"0.2.1\"\n"
  let native_moon_mod =
    "// native MoonBit manifest\n"
    <> "name = \"dep_demo\"\n"
    <> "version = \"0.1.0\"\n"
    <> "description = \"import { not_parsed } // inline\"\n\n"
    <> "test_import {\n"
    <> "  \"only/test@9.9.9\",\n"
    <> "}\n\n"
    <> "import {\n"
    <> "  \"moonbitlang/x@0.5.7\", // overrides earlier versions\n"
    <> "  \"carol/csv@0.3.0\" as @csv,\n"
    <> "}\n"

  assert ffi_config.parse_moonbit_deps_gleam_toml(gleam_toml)
    == Ok([#("alice/json_ext", "0.1.0"), #("moonbitlang/x", "0.4.5")])
  assert ffi_config.parse_moonbit_deps_gekko_toml(gekko_toml)
    == Ok([#("bob/regex", "0.2.1"), #("moonbitlang/x", "0.4.6")])
  assert ffi_config.parse_moon_mod_deps(native_moon_mod)
    == Ok([#("carol/csv", "0.3.0"), #("moonbitlang/x", "0.5.7")])

  let bad_toml = "[moonbit.deps]\n\"moonbitlang/x\" = 42\n"
  let assert Error(bad_err) = ffi_config.parse_moonbit_deps_gekko_toml(bad_toml)
  assert string.contains(bad_err, "version must be a string")

  let unclosed_moon_mod =
    "name = \"demo\"\nimport {\n  \"moonbitlang/x@0.5.7\",\n"
  let assert Error(unclosed_err) =
    ffi_config.parse_moon_mod_deps(unclosed_moon_mod)
  assert string.contains(unclosed_err, "Unclosed import block")

  assert pkg_config.emit_moon_mod_with_deps("demo", "0.1.0", [])
    == pkg_config.emit_moon_mod("demo", "0.1.0")

  let rendered =
    pkg_config.emit_moon_mod_with_deps("demo", "0.1.0", [
      #("bob/regex", "0.2.1"),
      #("moonbitlang/x@0.5.7", ""),
    ])
  assert string.contains(
    rendered,
    "import {\n  \"bob/regex@0.2.1\",\n  \"moonbitlang/x@0.5.7\",\n}\n",
  )

  let root = "build/test_fixtures/moonbit_deps_cfg"
  let out_dir = "build/test_fixtures/moonbit_deps_cfg_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "moonbit/helper"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: gleam_toml,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gekko.toml"),
      contents: gekko_toml,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "moonbit/moon.mod"),
      contents: native_moon_mod,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "moonbit/helper/helper.mbt"),
      contents: "pub fn ping() -> Int { 1 }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/dep_demo.gleam"),
      contents: "pub fn main() -> Nil {\n  Nil\n}\n",
    )
    == Ok(Nil)

  let assert Ok(merged_deps) = ffi_config.load_project_moonbit_deps(root)
  assert merged_deps
    == [
      #("alice/json_ext", "0.1.0"),
      #("bob/regex", "0.2.1"),
      #("carol/csv", "0.3.0"),
      #("moonbitlang/x", "0.5.7"),
    ]

  let assert Ok(summary) = workspace.transpile_project(root, out_dir)
  assert list.contains(summary.local_moonbit_packages, "helper")
  let moon_mod_path = filepath.join(out_dir, "moon.mod")
  let assert Ok(moon_mod_src) = simplifile.read(from: moon_mod_path)
  assert string.contains(
    moon_mod_src,
    "import {\n  \"alice/json_ext@0.1.0\",\n  \"bob/regex@0.2.1\",\n  \"carol/csv@0.3.0\",\n  \"moonbitlang/x@0.5.7\",\n}\n",
  )

  let fmt_probe = cmd.run(command: "moonfmt", args: ["--help"], cwd: ".")
  case fmt_probe.exit_code {
    0 -> {
      let fmt_res =
        cmd.run(
          command: "moonfmt",
          args: ["-file-type", "mod", moon_mod_path],
          cwd: ".",
        )
      assert fmt_res.exit_code == 0
    }
    _ -> Nil
  }

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

// -----------------------------------------------------------------------------
// 11. Tier 2 BitArray lowering, emission, semantics & stdlib parity tests
// -----------------------------------------------------------------------------
pub fn cmd_require_tools_and_find_executable_test() {
  let assert Ok(_) = cmd.find_executable("gleam")
  let assert Ok(_) = cmd.find_executable("moon")
  assert cmd.find_executable("definitely_nonexistent_gekko_tool_xyz")
    == Error(Nil)

  let ok_finder = fn(_name) { Ok("/usr/bin/tool") }
  assert cmd.require_tools_with(["gleam", "moon"], ok_finder) == Ok(Nil)

  let partial_finder = fn(name) {
    case name {
      "gleam" -> Ok("/usr/bin/gleam")
      _ -> Error(Nil)
    }
  }
  let assert Error(msg) =
    cmd.require_tools_with(["gleam", "moon", "wasm-tools"], partial_finder)
  assert string.contains(msg, "moon, wasm-tools")
  assert !string.contains(msg, "gleam")
}

pub fn staging_dev_deps_and_test_remapping_test() {
  let with_deps =
    "name = \"app\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0\"\n\n[dev-dependencies]\ngleam_stdlib = \">= 1.0.0\"\ngleeunit = \">= 1.0.0\"\n"
  let merged_with_deps =
    staging.merge_dev_dependencies_into_dependencies(with_deps)
  assert !string.contains(merged_with_deps, "[dev-dependencies]")
  assert string.contains(merged_with_deps, "gleeunit = \">= 1.0.0\"")
  assert list.length(string.split(merged_with_deps, "gleam_stdlib")) == 2

  let without_deps =
    "name = \"app\"\n\n[dev-dependencies]\ngleeunit = \">= 1.0.0\"\n"
  let merged_without_deps =
    staging.merge_dev_dependencies_into_dependencies(without_deps)
  assert !string.contains(merged_without_deps, "[dev-dependencies]")
  assert string.contains(
    merged_without_deps,
    "[dependencies]\ngleeunit = \">= 1.0.0\"",
  )

  let local_type =
    interface.NamedType(
      name: "Box",
      package: "app",
      module: "helper_test",
      parameters: [],
    )
  let mod_iface =
    interface.ModuleInterface(
      type_aliases: dict.new(),
      types: dict.from_list([
        #(
          "Box",
          interface.ResolvedTypeDef(parameters: 0, constructors: [
            interface.ResolvedVariant(name: "Box", parameters: [
              interface.ResolvedVariantField(label: None, type_: local_type),
            ]),
          ]),
        ),
      ]),
      constants: dict.from_list([
        #(
          "c",
          interface.ResolvedConstant(
            type_: local_type,
            implementations: interface.Implementations(True, False, False),
          ),
        ),
      ]),
      functions: dict.from_list([
        #(
          "f",
          interface.ResolvedFunction(
            parameters: [
              interface.ResolvedParam(label: None, type_: local_type),
            ],
            return: local_type,
            implementations: interface.Implementations(True, False, False),
          ),
        ),
      ]),
    )
  let iface =
    interface.PackageInterface(
      name: "app",
      version: "0.1.0",
      modules: dict.from_list([#("helper_test", mod_iface)]),
    )
  let remapped = staging.remap_staged_test_modules(iface, ["helper_test"])
  assert !dict.has_key(remapped.modules, "helper_test")
  let assert Ok(rm) = dict.get(remapped.modules, "test/helper_test")
  let assert Ok(rf) = dict.get(rm.functions, "f")
  assert rf.return
    == interface.NamedType(
      name: "Box",
      package: "app",
      module: "test/helper_test",
      parameters: [],
    )
}

pub fn staging_rejects_duplicate_src_and_test_module_test() {
  let root = "build/test_fixtures/staging_dup_mod"
  let staging_dir = filepath.join(root, "build/.gekko_staging")
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"dup_app\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/dup.gleam"),
      contents: "pub fn a() -> Int { 1 }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/dup.gleam"),
      contents: "pub fn a_test() -> Nil { Nil }\n",
    )
    == Ok(Nil)

  let assert Error(msg) =
    staging.extract_project_interface_with_options(root, staging_dir, True)
  assert string.contains(msg, "Duplicate module 'dup'")

  let _ = simplifile.delete(file_or_dir_at: root)
  Nil
}

pub fn toml_internal_modules_brackets_in_strings_and_comments_test() {
  let toml =
    "name = \"app\"\n"
    <> "internal_modules = [\n"
    <> "  \"app/a[0]\", # ] comment bracket\n"
    <> "  \"app/b]\",\n"
    <> "] # trailing ]\n"
    <> "description = \"kept\"\n"
    <> "\n"
    <> "[dependencies] # deps\n"
    <> "gleam_stdlib = \">= 0.40.0\"\n"
    <> "\n"
    <> "[dev-dependencies] # dev deps\n"
    <> "gleeunit = \">= 1.0.0\"\n"

  let overridden = staging.override_gleam_toml_internal_modules(toml)
  assert string.contains(overridden, "internal_modules = []")
  assert !string.contains(overridden, "app/a[0]")
  assert !string.contains(overridden, "app/b]")
  assert string.contains(overridden, "description = \"kept\"")

  let merged = staging.merge_dev_dependencies_into_dependencies(overridden)
  assert string.contains(merged, "gleeunit = \">= 1.0.0\"")
  assert !string.contains(merged, "[dev-dependencies]")
}

pub fn pkg_config_parse_render_roundtrip_and_zip_missing_test() {
  let rendered =
    pkg_config.render_moon_pkg(
      dict.from_list([#("app/sub", "sub"), #("gprelude", "gprelude")]),
      Some("warnings = \"-unused_value\""),
    )
  let #(imports, warnings) = pkg_config.parse_moon_pkg(rendered)
  assert imports == [#("gprelude", "gprelude"), #("app/sub", "sub")]
  assert warnings == Some("warnings = \"-unused_value\"")
  assert cmd.extract_zip_entry("nonexistent_archive.zip", "pkg.generated.mbti")
    == Error(Nil)
}

pub fn staging_interface_cache_hit_and_invalidation_test() {
  let root = "build/test_fixtures/staging_cache"
  let staging_dir = "build/test_fixtures/staging_cache_out"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: staging_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"staging_cache\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/staging_cache.gleam"),
      contents: "pub fn value() -> Int { 1 }\n",
    )
    == Ok(Nil)

  let assert Ok(iface1) = staging.extract_project_interface(root, staging_dir)
  let assert Ok(hash1) =
    simplifile.read(filepath.join(staging_dir, ".gekko_iface_hash"))
  assert hash1 != ""

  // Second extraction with identical inputs hits cache and returns same interface
  let assert Ok(iface2) = staging.extract_project_interface(root, staging_dir)
  assert iface1 == iface2

  // Modifying source invalidates cache and reflects updated signature
  assert simplifile.write(
      to: filepath.join(root, "src/staging_cache.gleam"),
      contents: "pub fn value(x: String) -> String { x }\n",
    )
    == Ok(Nil)
  let assert Ok(iface3) = staging.extract_project_interface(root, staging_dir)
  let assert Ok(hash2) =
    simplifile.read(filepath.join(staging_dir, ".gekko_iface_hash"))
  assert hash2 != hash1
  let assert Ok(mod_iface) = dict.get(iface3.modules, "staging_cache")
  let assert Ok(fn_sig) = dict.get(mod_iface.functions, "value")
  assert fn_sig.return == interface.NamedType("String", "", "gleam", [])

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: staging_dir)
  Nil
}

pub fn toolchain_version_parallel_and_diagnostics_test() {
  assert cmd.parse_moon_date_version("moon 0.1.20261119 (738607b 2026-11-19)")
    == Some(#(0, 1, 20_261_119))
  assert cmd.parse_moonc_version("v0.10.22+124d61d05 (2026-11-19)")
    == Some(#(0, 10, 22))
  assert cmd.is_version_at_least(#(0, 1, 20_261_119), cmd.min_moon_version)
  assert !cmd.is_version_at_least(#(0, 1, 20_261_001), cmd.min_moon_version)

  // Parallel map preserves order and surfaces first error
  assert cmd.parallel_try_map([1, 2, 3, 4], fn(n) { Ok(n * 10) })
    == Ok([10, 20, 30, 40])
  assert cmd.parallel_try_map([1, 2, 3], fn(n) {
      case n == 2 {
        True -> Error("boom-2")
        False -> Ok(n)
      }
    })
    == Error("boom-2")

  // Source-map annotation attaches Gleam file & line to MoonBit errors
  let origins = [
    diagnostics.DeclOrigin(
      mbt_file: "app/app.mbt",
      start_line: 10,
      end_line: 18,
      gleam_file: "src/app.gleam",
      gleam_line: 42,
      symbol: "compute",
    ),
  ]
  let raw_moon_err =
    "error: type mismatch\n  ┌─ /tmp/build/moonbit/app/app.mbt:14:5\n"
  let annotated = diagnostics.annotate_with_origins(origins, raw_moon_err)
  assert string.contains(
    annotated,
    "↳ Gleam source: src/app.gleam:42 (compute)",
  )

  // Write-if-changed + .gekko_sourcemap E2E check
  let wroot = "build/test_fixtures/write_if_changed_app"
  let wout = "build/test_fixtures/write_if_changed_mbt"
  let _ = simplifile.delete(file_or_dir_at: wroot)
  let _ = simplifile.delete(file_or_dir_at: wout)
  assert simplifile.create_directory_all(filepath.join(wroot, "src")) == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(wroot, "gleam.toml"),
      contents: "name = \"write_if_changed_app\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(wroot, "src/write_if_changed_app.gleam"),
      contents: "pub fn add_one(x: Int) -> Int {\n  x + 1\n}\n",
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(wroot, wout)
  let gprelude_mbt = filepath.join(wout, "gprelude/gprelude.mbt")
  let assert Ok(info1) = simplifile.file_info(gprelude_mbt)
  let assert Ok(smap) =
    simplifile.read(filepath.join(wout, diagnostics.sourcemap_filename))
  assert string.contains(smap, "src/write_if_changed_app.gleam\t1\tadd_one")

  let assert Ok(_) = workspace.transpile_project(wroot, wout)
  let assert Ok(info2) = simplifile.file_info(gprelude_mbt)
  assert info1.mtime_seconds == info2.mtime_seconds

  let _ = simplifile.delete(file_or_dir_at: wroot)
  let _ = simplifile.delete(file_or_dir_at: wout)
  Nil
}

pub fn needs_moon_update_detection_test() {
  let ci_err =
    "Warning: you may need to run `moon update` to update the registry\n"
    <> "Error: Failed to resolve the module dependency graph\n\n"
    <> "Caused by:\n"
    <> "    Failed to resolve registry dependency `moonbitlang/x` for module `file_io`: module was not found in the registry\n"
  assert cmd.needs_moon_update(ci_err)
  assert cmd.needs_moon_update(
    "Failed to resolve registry dependency `foo/bar`: module was not found in the registry",
  )
  assert !cmd.needs_moon_update("error: type mismatch in app/app.mbt:14:5")
}
