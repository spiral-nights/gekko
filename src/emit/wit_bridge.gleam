import emit/pkg_config
import filepath
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import lower/mangle
import project/cmd
import project/fs
import project/workspace
import simplifile
import wit/ast.{
  type ResolvedWit, type WitFunc, type WitInterface, type WitPackageId,
  type WitType, type WitTypeDef, ResourceConstructor, ResourceMethod,
  ResourceStatic, WitAlias, WitBool, WitBorrow, WitChar, WitEnum, WitF32, WitF64,
  WitFlags, WitList, WitNamed, WitOption, WitOwn, WitRecord, WitResource,
  WitResult, WitS16, WitS32, WitS64, WitS8, WitString, WitTuple, WitU16, WitU32,
  WitU64, WitU8, WitVariant, WorldExportFunc, WorldExportIface, WorldImportFunc,
  WorldImportIface, WorldUse, gleam_export_module, gleam_type_name,
  gleam_types_module, gleam_value_ident, gleam_variant_name,
  gleam_world_export_module, iface_key, kebab_to_screaming, kebab_to_snake,
  lookup_interface, moonbit_imp_adapter_pkg, moonbit_world_imp_adapter_pkg,
  wit_bindgen_iface_gen_dir, wit_bindgen_iface_raw_dir,
  wit_bindgen_world_gen_dir, wit_bindgen_world_raw_dir,
}
import wit/gleam_gen
import wit/parser

/// Output summary produced after wiring a WIT workspace onto transpiled Gleam
/// MoonBit packages via `wit-bindgen`.
pub type WitBridgeSummary {
  WitBridgeSummary(
    project_name: String,
    world_name: String,
    out_dir: String,
    wit_dir: String,
    core_wasm_path: String,
    warnings: List(String),
  )
}

type PendingHelper {
  PendingHelper(
    id: String,
    dir: ConvDir,
    iface_key: String,
    iface: WitInterface,
    wit_type_name: String,
    type_def: WitTypeDef,
  )
}

type ConvDir {
  W2G
  G2W
}

type AdapterState {
  AdapterState(
    project_name: String,
    resolved: ResolvedWit,
    // iface_key -> raw prefix ("" for current package, "@alias." for others)
    raw_prefixes: Dict(String, String),
    // gtypes_mod -> "@alias."
    gtypes_prefixes: Dict(String, String),
    // pkg_path -> alias (without "@") for moon.pkg
    pkg_imports: Dict(String, String),
    used_aliases: Set(String),
    next_id: Int,
    emitted_helpers: Set(String),
    pending_helpers: List(PendingHelper),
  )
}

/// Parse `wit_dir`, transpile the Gleam project into `out_dir`, invoke
/// `wit-bindgen moonbit`, and generate all import adapters and export stubs.
pub fn bridge_wit_workspace(
  project_root: String,
  out_dir: String,
  wit_dir: String,
  world_name: Option(String),
) -> Result(WitBridgeSummary, String) {
  use resolved <- result.try(parser.load_wit_dir(wit_dir, world_name))
  use transpile_summary <- result.try(workspace.transpile_project_with_tests(
    project_root,
    out_dir,
    False,
  ))

  let bindgen_probe =
    cmd.run(command: "wit-bindgen", args: ["--version"], cwd: project_root)
  use _ <- result.try(case bindgen_probe.exit_code {
    0 -> Ok(Nil)
    _ ->
      Error(
        "`wit-bindgen` CLI not found or failed. Install it with `cargo install wit-bindgen-cli`.\n"
        <> bindgen_probe.output,
      )
  })

  let project_name = transpile_summary.project_name
  let base_args = [
    "moonbit",
    wit_dir,
    "--out-dir",
    out_dir,
    "--project-name",
    project_name,
    "--ignore-module-file",
  ]
  let bindgen_args = case world_name {
    Some(w) -> list.append(base_args, ["--world", w])
    None -> base_args
  }
  let bindgen_res =
    cmd.run(command: "wit-bindgen", args: bindgen_args, cwd: ".")
  use _ <- result.try(case bindgen_res.exit_code {
    0 -> Ok(Nil)
    code ->
      Error(
        "`wit-bindgen moonbit` exited with code "
        <> int.to_string(code)
        <> ":\n"
        <> bindgen_res.output,
      )
  })

  // Emit import adapters for every imported interface.
  let imported_ifaces =
    list.filter_map(resolved.world.items, fn(item) {
      case item {
        WorldImportIface(ref) ->
          lookup_interface(resolved.interfaces, resolved.root_pkg, ref)
        _ -> Error(Nil)
      }
    })
  use _ <- result.try(
    list.try_each(imported_ifaces, fn(iface) {
      emit_iface_import_adapter(out_dir, project_name, resolved, iface)
    }),
  )

  // Emit world-level import adapter if world declares top-level `import fn`.
  let world_imports =
    list.filter_map(resolved.world.items, fn(item) {
      case item {
        WorldImportFunc(f) -> Ok(f)
        _ -> Error(Nil)
      }
    })
  use _ <- result.try(case world_imports {
    [] -> Ok(Nil)
    funcs -> emit_world_import_adapter(out_dir, project_name, resolved, funcs)
  })

  // Emit export stubs for every exported interface.
  let exported_ifaces =
    list.filter_map(resolved.world.items, fn(item) {
      case item {
        WorldExportIface(ref) ->
          lookup_interface(resolved.interfaces, resolved.root_pkg, ref)
        _ -> Error(Nil)
      }
    })
  use _ <- result.try(
    list.try_each(exported_ifaces, fn(iface) {
      emit_iface_export_stub(out_dir, project_name, resolved, iface)
    }),
  )

  // Emit world-level export stub if world declares top-level `export fn`.
  let world_exports =
    list.filter_map(resolved.world.items, fn(item) {
      case item {
        WorldExportFunc(f) -> Ok(f)
        _ -> Error(Nil)
      }
    })
  use _ <- result.try(case world_exports {
    [] -> Ok(Nil)
    funcs -> emit_world_export_stub(out_dir, project_name, resolved, funcs)
  })

  let core_wasm_path =
    filepath.join(out_dir, "_build/wasm/debug/build/gen/gen.wasm")
  Ok(WitBridgeSummary(
    project_name:,
    world_name: resolved.world.name,
    out_dir:,
    wit_dir:,
    core_wasm_path:,
    warnings: transpile_summary.warnings,
  ))
}

/// Run `moon check --target wasm` in the bridged workspace.
pub fn check_wit_workspace(
  summary: WitBridgeSummary,
) -> Result(String, String) {
  let res =
    cmd.run_moon_with_auto_update(
      ["check", "--target", "wasm"],
      summary.out_dir,
    )
  case res.exit_code {
    0 -> Ok(res.output)
    _ -> Error(res.output)
  }
}

/// Build the core linear-Wasm module via `moon build --target wasm`, then bundle
/// it into a Wasm Component via `wasm-tools component embed` and `component new`.
pub fn bundle_component(
  summary: WitBridgeSummary,
  world_name: Option(String),
  output_wasm: String,
) -> Result(String, String) {
  bundle_component_with_profile(summary, world_name, output_wasm, False)
}

/// Like `bundle_component`, optionally building the core Wasm module with
/// `moon build --release --target wasm`.
pub fn bundle_component_with_profile(
  summary: WitBridgeSummary,
  world_name: Option(String),
  output_wasm: String,
  release: Bool,
) -> Result(String, String) {
  let build_args = case release {
    True -> ["build", "--release", "--target", "wasm"]
    False -> ["build", "--target", "wasm"]
  }
  let build_res = cmd.run_moon_with_auto_update(build_args, summary.out_dir)
  use _ <- result.try(case build_res.exit_code {
    0 -> Ok(Nil)
    _ -> Error("`moon build --target wasm` failed:\n" <> build_res.output)
  })

  let core_wasm_path = case release {
    True ->
      filepath.join(summary.out_dir, "_build/wasm/release/build/gen/gen.wasm")
    False -> summary.core_wasm_path
  }

  use has_core <- result.try(
    simplifile.is_file(core_wasm_path)
    |> result.map_error(fn(err) {
      "Failed to check built Wasm module '"
      <> core_wasm_path
      <> "': "
      <> simplifile.describe_error(err)
    }),
  )
  use _ <- result.try(case has_core {
    True -> Ok(Nil)
    False ->
      Error(
        "`moon build --target wasm` succeeded, but expected core Wasm module was not found at "
        <> core_wasm_path,
      )
  })

  let tools_probe =
    cmd.run(command: "wasm-tools", args: ["--version"], cwd: ".")
  use _ <- result.try(case tools_probe.exit_code {
    0 -> Ok(Nil)
    _ ->
      Error(
        "Built core Wasm module at "
        <> core_wasm_path
        <> ", but `wasm-tools` is not installed to package it into a Wasm component.\n"
        <> "Install with: cargo install wasm-tools",
      )
  })

  let embedded_wasm = filepath.join(summary.out_dir, "embedded.wasm")
  let base_embed = [
    "component",
    "embed",
    "--encoding",
    "utf16",
    summary.wit_dir,
    core_wasm_path,
    "-o",
    embedded_wasm,
  ]
  let embed_args = case world_name {
    Some(w) -> list.append(base_embed, ["--world", w])
    None -> base_embed
  }
  let embed_res = cmd.run(command: "wasm-tools", args: embed_args, cwd: ".")
  use _ <- result.try(case embed_res.exit_code {
    0 -> Ok(Nil)
    _ -> Error("`wasm-tools component embed` failed:\n" <> embed_res.output)
  })

  let out_parent = filepath.directory_name(output_wasm)
  use _ <- result.try(case out_parent {
    "" | "." -> Ok(Nil)
    _ ->
      simplifile.create_directory_all(out_parent)
      |> result.map_error(fn(err) {
        "Failed to create component output directory '"
        <> out_parent
        <> "': "
        <> simplifile.describe_error(err)
      })
  })

  let new_res =
    cmd.run(
      command: "wasm-tools",
      args: ["component", "new", embedded_wasm, "-o", output_wasm],
      cwd: ".",
    )
  case new_res.exit_code {
    0 -> Ok(output_wasm)
    _ -> Error("`wasm-tools component new` failed:\n" <> new_res.output)
  }
}

// ---------------------------------------------------------------------------
// Import adapter packages
// ---------------------------------------------------------------------------

fn emit_iface_import_adapter(
  out_dir: String,
  project_name: String,
  resolved: ResolvedWit,
  iface: WitInterface,
) -> Result(Nil, String) {
  let adapter_pkg = moonbit_imp_adapter_pkg(iface)
  let raw_dir = wit_bindgen_iface_raw_dir(iface)
  let self_key = iface_key(iface.pkg, iface.name)
  let use_map = gleam_gen.build_use_map(iface.pkg, iface.uses)

  let init_state =
    new_adapter_state(project_name, resolved, [
      #(project_name <> "/gprelude", "gprelude"),
      #(project_name <> "/" <> raw_dir, "wit_raw"),
    ])
    |> set_raw_prefix(self_key, "@wit_raw.")

  let #(rev_fns, state1) =
    list.fold(iface.funcs, #([], init_state), fn(acc, f) {
      let #(fn_acc, st) = acc
      let #(code, next_st) =
        emit_import_wrapper_fn(f, self_key, iface.pkg, use_map, "@wit_raw.", st)
      #([code, ..fn_acc], next_st)
    })

  let #(rev_res_blocks, state2) =
    list.fold(iface.types, #(rev_fns, state1), fn(acc, td) {
      case td {
        WitResource(name:, methods:) ->
          emit_resource_import_wrappers(
            name,
            methods,
            self_key,
            use_map,
            acc.0,
            acc.1,
          )
        _ -> acc
      }
    })

  let #(rev_helpers, final_state) = drain_pending_helpers(state2, [])
  let mbt_src =
    "// Generated by gekko wit bridge.\n\n"
    <> string.join(
      list.append(list.reverse(rev_helpers), list.reverse(rev_res_blocks)),
      "\n\n",
    )
    <> "\n"
  let moon_pkg = pkg_config.render_moon_pkg(final_state.pkg_imports, None)

  let dir = filepath.join(out_dir, adapter_pkg)
  use _ <- result.try(fs.write_text_if_changed(
    filepath.join(dir, "moon.pkg"),
    moon_pkg,
  ))
  fs.write_text_if_changed(filepath.join(dir, adapter_pkg <> ".mbt"), mbt_src)
}

fn emit_resource_import_wrappers(
  res_name: String,
  methods: List(ast.WitResourceMethod),
  owner_key: String,
  use_map: Dict(String, #(String, String)),
  rev_blocks: List(String),
  state: AdapterState,
) -> #(List(String), AdapterState) {
  let ty_name = gleam_type_name(res_name)
  let res_snake = kebab_to_snake(res_name)
  let type_alias = "///|\npub type " <> ty_name <> " = @wit_raw." <> ty_name
  let rev_with_type = [type_alias, ..rev_blocks]

  let #(rev_after_methods, st1) =
    list.fold(methods, #(rev_with_type, state), fn(acc, m) {
      let #(blk_acc, st) = acc
      let #(fake_func, raw_prefix) = case m.kind {
        ResourceConstructor -> #(
          ast.WitFunc(
            name: "new-" <> res_name,
            params: m.params,
            result: Some(WitNamed(res_name)),
          ),
          "@wit_raw." <> ty_name <> "::",
        )
        ResourceMethod -> #(
          ast.WitFunc(
            name: res_snake <> "-" <> m.name,
            params: [#("self", WitNamed(res_name)), ..m.params],
            result: m.result,
          ),
          "@wit_raw." <> ty_name <> "::",
        )
        ResourceStatic -> #(
          ast.WitFunc(
            name: res_snake <> "-" <> m.name,
            params: m.params,
            result: m.result,
          ),
          "@wit_raw." <> ty_name <> "::",
        )
      }
      let raw_target_name = case m.kind {
        ResourceConstructor -> mangle.mangle_ident(kebab_to_snake(res_name))
        _ -> mangle.mangle_ident(kebab_to_snake(m.name))
      }
      let #(code, next_st) =
        emit_import_wrapper_with_target(
          fake_func,
          raw_prefix <> raw_target_name,
          owner_key,
          use_map,
          st,
        )
      #([code, ..blk_acc], next_st)
    })

  let drop_func =
    ast.WitFunc(
      name: "drop-" <> res_name,
      params: [#("self", WitNamed(res_name))],
      result: None,
    )
  let #(drop_code, st2) =
    emit_import_wrapper_with_target(
      drop_func,
      "@wit_raw." <> ty_name <> "::drop",
      owner_key,
      use_map,
      st1,
    )
  #([drop_code, ..rev_after_methods], st2)
}

fn emit_world_import_adapter(
  out_dir: String,
  project_name: String,
  resolved: ResolvedWit,
  funcs: List(WitFunc),
) -> Result(Nil, String) {
  let adapter_pkg = moonbit_world_imp_adapter_pkg(resolved.world)
  let raw_dir = wit_bindgen_world_raw_dir(resolved.world)
  let world_uses =
    list.filter_map(resolved.world.items, fn(item) {
      case item {
        WorldUse(u) -> Ok(u)
        _ -> Error(Nil)
      }
    })
  let use_map = gleam_gen.build_use_map(resolved.root_pkg, world_uses)
  let dummy_key = "__world__:" <> resolved.world.name

  let init_state =
    new_adapter_state(project_name, resolved, [
      #(project_name <> "/gprelude", "gprelude"),
      #(project_name <> "/" <> raw_dir, "wit_raw"),
    ])

  let #(rev_fns, state1) =
    list.fold(funcs, #([], init_state), fn(acc, f) {
      let #(fn_acc, st) = acc
      let #(code, next_st) =
        emit_import_wrapper_fn(
          f,
          dummy_key,
          resolved.root_pkg,
          use_map,
          "@wit_raw.",
          st,
        )
      #([code, ..fn_acc], next_st)
    })

  let #(rev_helpers, final_state) = drain_pending_helpers(state1, [])
  let mbt_src =
    "// Generated by gekko wit bridge.\n\n"
    <> string.join(
      list.append(list.reverse(rev_helpers), list.reverse(rev_fns)),
      "\n\n",
    )
    <> "\n"
  let moon_pkg = pkg_config.render_moon_pkg(final_state.pkg_imports, None)

  let dir = filepath.join(out_dir, adapter_pkg)
  use _ <- result.try(fs.write_text_if_changed(
    filepath.join(dir, "moon.pkg"),
    moon_pkg,
  ))
  fs.write_text_if_changed(filepath.join(dir, adapter_pkg <> ".mbt"), mbt_src)
}

fn emit_import_wrapper_fn(
  f: WitFunc,
  owner_key: String,
  _owner_pkg: WitPackageId,
  use_map: Dict(String, #(String, String)),
  raw_call_prefix: String,
  state: AdapterState,
) -> #(String, AdapterState) {
  let wit_fn_name = mangle.mangle_ident(kebab_to_snake(f.name))
  emit_import_wrapper_with_target(
    f,
    raw_call_prefix <> wit_fn_name,
    owner_key,
    use_map,
    state,
  )
}

fn emit_import_wrapper_with_target(
  f: WitFunc,
  raw_callee: String,
  owner_key: String,
  use_map: Dict(String, #(String, String)),
  state: AdapterState,
) -> #(String, AdapterState) {
  let fn_ident = mangle.mangle_ident(gleam_value_ident(f.name))

  let #(rev_params, rev_args, st1) =
    list.fold(f.params, #([], [], state), fn(acc, param) {
      let #(p_acc, a_acc, st) = acc
      let #(pname, pty) = param
      let g_pname = mangle.mangle_ident(gleam_value_ident(pname))
      let #(g_ty, st_ty) = gleam_mbt_type(pty, owner_key, use_map, st)
      let #(arg_expr, st_arg) =
        conv_g2w_expr(pty, owner_key, use_map, g_pname, st_ty)
      #([g_pname <> " : " <> g_ty, ..p_acc], [arg_expr, ..a_acc], st_arg)
    })

  let #(ret_ty, call_wrapped, st2) = case f.result {
    None -> {
      let call =
        raw_callee <> "(" <> string.join(list.reverse(rev_args), ", ") <> ")"
      #("Unit", call, st1)
    }
    Some(rty) -> {
      let #(g_rty, st_r) = gleam_mbt_type(rty, owner_key, use_map, st1)
      let call =
        raw_callee <> "(" <> string.join(list.reverse(rev_args), ", ") <> ")"
      let #(wrapped, st_w) = conv_w2g_expr(rty, owner_key, use_map, call, st_r)
      #(g_rty, wrapped, st_w)
    }
  }

  let code =
    "///|\n"
    <> "pub fn "
    <> fn_ident
    <> "("
    <> string.join(list.reverse(rev_params), ", ")
    <> ") -> "
    <> ret_ty
    <> " {\n"
    <> "  "
    <> call_wrapped
    <> "\n}"
  #(code, st2)
}

// ---------------------------------------------------------------------------
// Export stubs inside `gen/.../stub.mbt`
// ---------------------------------------------------------------------------

fn emit_iface_export_stub(
  out_dir: String,
  project_name: String,
  resolved: ResolvedWit,
  iface: WitInterface,
) -> Result(Nil, String) {
  let gen_dir = wit_bindgen_iface_gen_dir(iface)
  let pkg_dir = filepath.join(out_dir, gen_dir)
  let pkg_file = filepath.join(pkg_dir, "moon.pkg")

  use #(existing_imports, warnings_line) <- result.try(read_moon_pkg(pkg_file))
  let export_mod = gleam_export_module(resolved.root_pkg, iface)
  let export_pkg_dir = pkg_config.module_to_pkg_dir(export_mod)

  let seed_imports =
    existing_imports
    |> list.append([
      #(project_name <> "/gprelude", "gprelude"),
      #(project_name <> "/" <> export_pkg_dir, "gleam_export"),
    ])

  let raw_prefixes =
    extract_raw_prefixes_from_imports(project_name, existing_imports)
    |> dict.insert(iface_key(iface.pkg, iface.name), "")

  let self_key = iface_key(iface.pkg, iface.name)
  let use_map = gleam_gen.build_use_map(iface.pkg, iface.uses)

  let init_state =
    new_adapter_state_with_prefixes(
      project_name,
      resolved,
      seed_imports,
      raw_prefixes,
    )

  let #(rev_fns, state1) =
    list.fold(iface.funcs, #([], init_state), fn(acc, f) {
      let #(fn_acc, st) = acc
      let #(code, next_st) = emit_export_stub_fn(f, self_key, use_map, st)
      #([code, ..fn_acc], next_st)
    })

  let #(rev_helpers, final_state) = drain_pending_helpers(state1, [])
  let stub_src =
    "// Generated by gekko wit bridge.\n\n"
    <> string.join(
      list.append(list.reverse(rev_helpers), list.reverse(rev_fns)),
      "\n\n",
    )
    <> "\n"
  let moon_pkg =
    pkg_config.render_moon_pkg(final_state.pkg_imports, warnings_line)

  use _ <- result.try(fs.write_text_if_changed(pkg_file, moon_pkg))
  fs.write_text_if_changed(filepath.join(pkg_dir, "stub.mbt"), stub_src)
}

fn emit_world_export_stub(
  out_dir: String,
  project_name: String,
  resolved: ResolvedWit,
  funcs: List(WitFunc),
) -> Result(Nil, String) {
  let gen_dir = wit_bindgen_world_gen_dir(resolved.world)
  let pkg_dir = filepath.join(out_dir, gen_dir)
  let pkg_file = filepath.join(pkg_dir, "moon.pkg")

  use #(existing_imports, warnings_line) <- result.try(read_moon_pkg(pkg_file))
  let export_mod = gleam_world_export_module(resolved.world)
  let export_pkg_dir = pkg_config.module_to_pkg_dir(export_mod)

  let seed_imports =
    existing_imports
    |> list.append([
      #(project_name <> "/gprelude", "gprelude"),
      #(project_name <> "/" <> export_pkg_dir, "gleam_export"),
    ])

  let raw_prefixes =
    extract_raw_prefixes_from_imports(project_name, existing_imports)
  let world_uses =
    list.filter_map(resolved.world.items, fn(item) {
      case item {
        WorldUse(u) -> Ok(u)
        _ -> Error(Nil)
      }
    })
  let use_map = gleam_gen.build_use_map(resolved.root_pkg, world_uses)
  let dummy_key = "__world__:" <> resolved.world.name

  let init_state =
    new_adapter_state_with_prefixes(
      project_name,
      resolved,
      seed_imports,
      raw_prefixes,
    )

  let #(rev_fns, state1) =
    list.fold(funcs, #([], init_state), fn(acc, f) {
      let #(fn_acc, st) = acc
      let #(code, next_st) = emit_export_stub_fn(f, dummy_key, use_map, st)
      #([code, ..fn_acc], next_st)
    })

  let #(rev_helpers, final_state) = drain_pending_helpers(state1, [])
  let stub_src =
    "// Generated by gekko wit bridge.\n\n"
    <> string.join(
      list.append(list.reverse(rev_helpers), list.reverse(rev_fns)),
      "\n\n",
    )
    <> "\n"
  let moon_pkg =
    pkg_config.render_moon_pkg(final_state.pkg_imports, warnings_line)

  use _ <- result.try(fs.write_text_if_changed(pkg_file, moon_pkg))
  fs.write_text_if_changed(filepath.join(pkg_dir, "stub.mbt"), stub_src)
}

fn emit_export_stub_fn(
  f: WitFunc,
  owner_key: String,
  use_map: Dict(String, #(String, String)),
  state: AdapterState,
) -> #(String, AdapterState) {
  let wit_fn_name = mangle.mangle_ident(kebab_to_snake(f.name))
  let gleam_fn_name = mangle.mangle_ident(gleam_value_ident(f.name))

  let #(rev_params, rev_args, st1) =
    list.fold(f.params, #([], [], state), fn(acc, param) {
      let #(p_acc, a_acc, st) = acc
      let #(pname, pty) = param
      let w_pname = mangle.mangle_ident(kebab_to_snake(pname))
      let #(w_ty, st_ty) = wit_mbt_type(pty, owner_key, use_map, st)
      let #(arg_expr, st_arg) =
        conv_w2g_expr(pty, owner_key, use_map, w_pname, st_ty)
      #([w_pname <> " : " <> w_ty, ..p_acc], [arg_expr, ..a_acc], st_arg)
    })

  let gleam_call =
    "@gleam_export."
    <> gleam_fn_name
    <> "("
    <> string.join(list.reverse(rev_args), ", ")
    <> ")"

  let #(ret_ty, wrapped_call, st2) = case f.result {
    None -> #("Unit", gleam_call, st1)
    Some(rty) -> {
      let #(w_rty, st_r) = wit_mbt_type(rty, owner_key, use_map, st1)
      let #(wrapped, st_w) =
        conv_g2w_expr(rty, owner_key, use_map, gleam_call, st_r)
      #(w_rty, wrapped, st_w)
    }
  }

  let code =
    "///|\n"
    <> "pub fn "
    <> wit_fn_name
    <> "("
    <> string.join(list.reverse(rev_params), ", ")
    <> ") -> "
    <> ret_ty
    <> " {\n"
    <> "  "
    <> wrapped_call
    <> "\n}"
  #(code, st2)
}

// ---------------------------------------------------------------------------
// Type resolution & MoonBit boundary type names
// ---------------------------------------------------------------------------

type ResolvedNamed {
  UnfoldedAlias(target: WitType, source_iface_key: String)
  ConcreteDef(
    iface_key: String,
    iface: WitInterface,
    wit_type_name: String,
    def: WitTypeDef,
  )
}

fn resolve_named_type(
  wit_name: String,
  cur_iface_key: String,
  use_map: Dict(String, #(String, String)),
  resolved: ResolvedWit,
) -> Option(ResolvedNamed) {
  let #(target_key, remote_name) = case dict.get(use_map, wit_name) {
    Ok(#(src_key, rem)) -> #(src_key, rem)
    Error(_) -> #(cur_iface_key, wit_name)
  }
  case dict.get(resolved.interfaces, target_key) {
    Error(_) -> None
    Ok(target_iface) ->
      case
        list.find(target_iface.types, fn(td) {
          type_def_name(td) == remote_name
        })
      {
        Error(_) -> None
        Ok(WitAlias(target:, ..)) ->
          Some(UnfoldedAlias(target:, source_iface_key: target_key))
        Ok(concrete) ->
          Some(ConcreteDef(
            iface_key: target_key,
            iface: target_iface,
            wit_type_name: remote_name,
            def: concrete,
          ))
      }
  }
}

fn iface_use_map(
  iface_key_str: String,
  resolved: ResolvedWit,
) -> Dict(String, #(String, String)) {
  case dict.get(resolved.interfaces, iface_key_str) {
    Ok(iface) -> gleam_gen.build_use_map(iface.pkg, iface.uses)
    Error(_) -> dict.new()
  }
}

fn type_def_name(td: WitTypeDef) -> String {
  case td {
    WitRecord(name:, ..)
    | WitEnum(name:, ..)
    | WitVariant(name:, ..)
    | WitFlags(name:, ..)
    | WitAlias(name:, ..)
    | WitResource(name:, ..) -> name
  }
}

fn wit_mbt_type(
  ty: WitType,
  owner_key: String,
  use_map: Dict(String, #(String, String)),
  state: AdapterState,
) -> #(String, AdapterState) {
  case ty {
    WitBool -> #("Bool", state)
    WitS8 | WitS16 | WitS32 -> #("Int", state)
    WitS64 -> #("Int64", state)
    WitU8 -> #("Byte", state)
    WitU16 | WitU32 -> #("UInt", state)
    WitU64 -> #("UInt64", state)
    WitF32 -> #("Float", state)
    WitF64 -> #("Double", state)
    WitChar -> #("Char", state)
    WitString -> #("String", state)
    WitList(WitU8) -> #("FixedArray[Byte]", state)
    WitList(inner) -> {
      let #(s, st1) = wit_mbt_type(inner, owner_key, use_map, state)
      #("Array[" <> s <> "]", st1)
    }
    WitOption(inner) -> {
      let #(s, st1) = wit_mbt_type(inner, owner_key, use_map, state)
      #(s <> "?", st1)
    }
    WitResult(ok:, err:) -> {
      let #(ok_s, st1) = case ok {
        None -> #("Unit", state)
        Some(t) -> wit_mbt_type(t, owner_key, use_map, state)
      }
      let #(err_s, st2) = case err {
        None -> #("Unit", st1)
        Some(e) -> wit_mbt_type(e, owner_key, use_map, st1)
      }
      #("Result[" <> ok_s <> ", " <> err_s <> "]", st2)
    }
    WitTuple(els) -> {
      let #(rev_els, st1) =
        list.fold(els, #([], state), fn(acc, el) {
          let #(s, st_next) = wit_mbt_type(el, owner_key, use_map, acc.1)
          #([s, ..acc.0], st_next)
        })
      #("(" <> string.join(list.reverse(rev_els), ", ") <> ")", st1)
    }
    WitOwn(wit_name) | WitBorrow(wit_name) | WitNamed(wit_name) ->
      case resolve_named_type(wit_name, owner_key, use_map, state.resolved) {
        Some(UnfoldedAlias(target:, source_iface_key:)) ->
          wit_mbt_type(
            target,
            source_iface_key,
            iface_use_map(source_iface_key, state.resolved),
            state,
          )
        Some(ConcreteDef(iface_key: key, iface:, wit_type_name:, ..)) -> {
          let #(prefix, st1) = ensure_raw_prefix(state, key, iface)
          #(prefix <> gleam_type_name(wit_type_name), st1)
        }
        None -> #(gleam_type_name(wit_name), state)
      }
  }
}

fn gleam_mbt_type(
  ty: WitType,
  owner_key: String,
  use_map: Dict(String, #(String, String)),
  state: AdapterState,
) -> #(String, AdapterState) {
  case ty {
    WitBool -> #("Bool", state)
    WitS8 | WitS16 | WitS32 | WitS64 | WitU8 | WitU16 | WitU32 | WitU64 -> #(
      "Int64",
      state,
    )
    WitF32 | WitF64 -> #("Double", state)
    WitChar | WitString -> #("StringView", state)
    WitList(WitU8) -> #("@gprelude.BitArray", state)
    WitList(inner) -> {
      let #(s, st1) = gleam_mbt_type(inner, owner_key, use_map, state)
      #("@gprelude.GList[" <> s <> "]", st1)
    }
    WitOption(inner) -> {
      let #(s, st1) = gleam_mbt_type(inner, owner_key, use_map, state)
      #("Option[" <> s <> "]", st1)
    }
    WitResult(ok:, err:) -> {
      let #(ok_s, st1) = case ok {
        None -> #("Unit", state)
        Some(t) -> gleam_mbt_type(t, owner_key, use_map, state)
      }
      let #(err_s, st2) = case err {
        None -> #("Unit", st1)
        Some(e) -> gleam_mbt_type(e, owner_key, use_map, st1)
      }
      #("Result[" <> ok_s <> ", " <> err_s <> "]", st2)
    }
    WitTuple(els) -> {
      let #(rev_els, st1) =
        list.fold(els, #([], state), fn(acc, el) {
          let #(s, st_next) = gleam_mbt_type(el, owner_key, use_map, acc.1)
          #([s, ..acc.0], st_next)
        })
      #("(" <> string.join(list.reverse(rev_els), ", ") <> ")", st1)
    }
    WitOwn(wit_name) | WitBorrow(wit_name) | WitNamed(wit_name) ->
      case resolve_named_type(wit_name, owner_key, use_map, state.resolved) {
        Some(UnfoldedAlias(target:, source_iface_key:)) ->
          gleam_mbt_type(
            target,
            source_iface_key,
            iface_use_map(source_iface_key, state.resolved),
            state,
          )
        Some(ConcreteDef(
          iface_key: key,
          iface:,
          wit_type_name:,
          def: WitResource(..),
        )) -> {
          let #(prefix, st1) = ensure_raw_prefix(state, key, iface)
          #(prefix <> gleam_type_name(wit_type_name), st1)
        }
        Some(ConcreteDef(iface:, wit_type_name:, ..)) -> {
          let #(prefix, st1) = ensure_gtypes_prefix(state, iface)
          let gtype = mangle.mangle_type_name(gleam_type_name(wit_type_name))
          #(prefix <> gtype, st1)
        }
        None -> #(mangle.mangle_type_name(gleam_type_name(wit_name)), state)
      }
  }
}

// ---------------------------------------------------------------------------
// Conversion expressions & queued named-type converter functions
// ---------------------------------------------------------------------------

fn conv_w2g_expr(
  ty: WitType,
  owner_key: String,
  use_map: Dict(String, #(String, String)),
  expr: String,
  state: AdapterState,
) -> #(String, AdapterState) {
  case ty {
    WitBool | WitS64 | WitF64 -> #(expr, state)
    WitString -> #("(" <> expr <> ").to_string_view()", state)
    WitS8 | WitS16 | WitS32 -> #("(" <> expr <> ").to_int64()", state)
    WitU8 -> #("(" <> expr <> ").to_int().to_int64()", state)
    WitU16 | WitU32 -> #("(" <> expr <> ").to_int64()", state)
    WitU64 -> #("(" <> expr <> ").reinterpret_as_int64()", state)
    WitF32 -> #("(" <> expr <> ").to_double()", state)
    WitChar -> #("String::make(1, " <> expr <> ").to_string_view()", state)
    WitList(WitU8) -> #(
      "@gprelude.BitArray::from_bytes(Bytes::from_array((" <> expr <> ")[:]))",
      state,
    )
    WitList(inner) -> {
      let #(id, st1) = fresh_id(state)
      let el_var = "el_" <> id
      let #(inner_expr, st2) =
        conv_w2g_expr(inner, owner_key, use_map, el_var, st1)
      #(
        "@gprelude.GList::from_array(("
          <> expr
          <> ").map(fn("
          <> el_var
          <> ") { "
          <> inner_expr
          <> " })[:])",
        st2,
      )
    }
    WitOption(inner) -> {
      let #(id, st1) = fresh_id(state)
      let v_var = "v_" <> id
      let #(some_expr, st2) =
        conv_w2g_expr(inner, owner_key, use_map, v_var, st1)
      #(
        "match "
          <> expr
          <> " { Some("
          <> v_var
          <> ") => Some("
          <> some_expr
          <> "); None => None }",
        st2,
      )
    }
    WitResult(ok:, err:) -> {
      let #(id, st1) = fresh_id(state)
      let #(ok_arm, st2) = case ok {
        None -> #("Ok(()) => Ok(())", st1)
        Some(ok_t) -> {
          let v_var = "ok_" <> id
          let #(ok_expr, st_ok) =
            conv_w2g_expr(ok_t, owner_key, use_map, v_var, st1)
          #("Ok(" <> v_var <> ") => Ok(" <> ok_expr <> ")", st_ok)
        }
      }
      let #(err_arm, st3) = case err {
        None -> #("Err(()) => Err(())", st2)
        Some(err_t) -> {
          let e_var = "err_" <> id
          let #(err_expr, st_err) =
            conv_w2g_expr(err_t, owner_key, use_map, e_var, st2)
          #("Err(" <> e_var <> ") => Err(" <> err_expr <> ")", st_err)
        }
      }
      #("match " <> expr <> " { " <> ok_arm <> "; " <> err_arm <> " }", st3)
    }
    WitTuple(els) -> {
      let #(id, st1) = fresh_id(state)
      let tup_var = "tup_" <> id
      let #(rev_items, st2) =
        list.index_fold(els, #([], st1), fn(acc, el, idx) {
          let #(el_expr, st_next) =
            conv_w2g_expr(
              el,
              owner_key,
              use_map,
              tup_var <> "." <> int.to_string(idx),
              acc.1,
            )
          #([el_expr, ..acc.0], st_next)
        })
      #(
        "{ let "
          <> tup_var
          <> " = "
          <> expr
          <> "; ("
          <> string.join(list.reverse(rev_items), ", ")
          <> ") }",
        st2,
      )
    }
    WitOwn(wit_name) | WitBorrow(wit_name) | WitNamed(wit_name) ->
      case resolve_named_type(wit_name, owner_key, use_map, state.resolved) {
        Some(UnfoldedAlias(target:, source_iface_key:)) ->
          conv_w2g_expr(
            target,
            source_iface_key,
            iface_use_map(source_iface_key, state.resolved),
            expr,
            state,
          )
        Some(ConcreteDef(def: WitResource(..), ..)) -> #(expr, state)
        Some(ConcreteDef(iface_key: key, iface:, wit_type_name:, def:)) -> {
          let #(fn_name, st1) =
            enqueue_helper(state, W2G, key, iface, wit_type_name, def)
          #(fn_name <> "(" <> expr <> ")", st1)
        }
        None -> #(expr, state)
      }
  }
}

fn conv_g2w_expr(
  ty: WitType,
  owner_key: String,
  use_map: Dict(String, #(String, String)),
  expr: String,
  state: AdapterState,
) -> #(String, AdapterState) {
  case ty {
    WitBool | WitS64 | WitF64 -> #(expr, state)
    WitString -> #("(" <> expr <> ").to_owned()", state)
    WitS8 | WitS16 | WitS32 -> #("(" <> expr <> ").to_int()", state)
    WitU8 -> #("(" <> expr <> ").to_byte()", state)
    WitU16 | WitU32 -> #(
      "(" <> expr <> ").to_int().reinterpret_as_uint()",
      state,
    )
    WitU64 -> #("(" <> expr <> ").reinterpret_as_uint64()", state)
    WitF32 -> #("Float::from_double(" <> expr <> ")", state)
    WitChar -> #(
      "match (" <> expr <> ").get_char(0) { Some(c) => c; None => '\\u{0}' }",
      state,
    )
    WitList(WitU8) -> {
      let #(id, st1) = fresh_id(state)
      let ba_var = "ba_" <> id
      let idx_var = "i_" <> id
      #(
        "{ let "
          <> ba_var
          <> " = "
          <> expr
          <> "; FixedArray::makei("
          <> ba_var
          <> ".data.length(), fn("
          <> idx_var
          <> ") { "
          <> ba_var
          <> ".data["
          <> idx_var
          <> "] }) }",
        st1,
      )
    }
    WitList(inner) -> {
      let #(id, st1) = fresh_id(state)
      let el_var = "el_" <> id
      let #(inner_expr, st2) =
        conv_g2w_expr(inner, owner_key, use_map, el_var, st1)
      #(
        "("
          <> expr
          <> ").to_array().map(fn("
          <> el_var
          <> ") { "
          <> inner_expr
          <> " })",
        st2,
      )
    }
    WitOption(inner) -> {
      let #(id, st1) = fresh_id(state)
      let v_var = "v_" <> id
      let #(some_expr, st2) =
        conv_g2w_expr(inner, owner_key, use_map, v_var, st1)
      #(
        "match "
          <> expr
          <> " { Some("
          <> v_var
          <> ") => Some("
          <> some_expr
          <> "); None => None }",
        st2,
      )
    }
    WitResult(ok:, err:) -> {
      let #(id, st1) = fresh_id(state)
      let #(ok_arm, st2) = case ok {
        None -> #("Ok(()) => Ok(())", st1)
        Some(ok_t) -> {
          let v_var = "ok_" <> id
          let #(ok_expr, st_ok) =
            conv_g2w_expr(ok_t, owner_key, use_map, v_var, st1)
          #("Ok(" <> v_var <> ") => Ok(" <> ok_expr <> ")", st_ok)
        }
      }
      let #(err_arm, st3) = case err {
        None -> #("Err(()) => Err(())", st2)
        Some(err_t) -> {
          let e_var = "err_" <> id
          let #(err_expr, st_err) =
            conv_g2w_expr(err_t, owner_key, use_map, e_var, st2)
          #("Err(" <> e_var <> ") => Err(" <> err_expr <> ")", st_err)
        }
      }
      #("match " <> expr <> " { " <> ok_arm <> "; " <> err_arm <> " }", st3)
    }
    WitTuple(els) -> {
      let #(id, st1) = fresh_id(state)
      let tup_var = "tup_" <> id
      let #(rev_items, st2) =
        list.index_fold(els, #([], st1), fn(acc, el, idx) {
          let #(el_expr, st_next) =
            conv_g2w_expr(
              el,
              owner_key,
              use_map,
              tup_var <> "." <> int.to_string(idx),
              acc.1,
            )
          #([el_expr, ..acc.0], st_next)
        })
      #(
        "{ let "
          <> tup_var
          <> " = "
          <> expr
          <> "; ("
          <> string.join(list.reverse(rev_items), ", ")
          <> ") }",
        st2,
      )
    }
    WitOwn(wit_name) | WitBorrow(wit_name) | WitNamed(wit_name) ->
      case resolve_named_type(wit_name, owner_key, use_map, state.resolved) {
        Some(UnfoldedAlias(target:, source_iface_key:)) ->
          conv_g2w_expr(
            target,
            source_iface_key,
            iface_use_map(source_iface_key, state.resolved),
            expr,
            state,
          )
        Some(ConcreteDef(def: WitResource(..), ..)) -> #(expr, state)
        Some(ConcreteDef(iface_key: key, iface:, wit_type_name:, def:)) -> {
          let #(fn_name, st1) =
            enqueue_helper(state, G2W, key, iface, wit_type_name, def)
          #(fn_name <> "(" <> expr <> ")", st1)
        }
        None -> #(expr, state)
      }
  }
}

fn enqueue_helper(
  state: AdapterState,
  dir: ConvDir,
  key: String,
  iface: WitInterface,
  wit_type_name: String,
  def: WitTypeDef,
) -> #(String, AdapterState) {
  let prefix = case dir {
    W2G -> "__w2g_"
    G2W -> "__g2w_"
  }
  let fn_name =
    prefix
    <> sanitize_helper_part(key)
    <> "_"
    <> sanitize_helper_part(wit_type_name)
  case set.contains(state.emitted_helpers, fn_name) {
    True -> #(fn_name, state)
    False -> {
      let pending =
        PendingHelper(
          id: fn_name,
          dir:,
          iface_key: key,
          iface:,
          wit_type_name:,
          type_def: def,
        )
      let st1 =
        AdapterState(
          ..state,
          emitted_helpers: set.insert(state.emitted_helpers, fn_name),
          pending_helpers: [pending, ..state.pending_helpers],
        )
      // Ensure raw & gtypes prefixes are registered immediately.
      let #(_, st2) = ensure_raw_prefix(st1, key, iface)
      let #(_, st3) = ensure_gtypes_prefix(st2, iface)
      #(fn_name, st3)
    }
  }
}

fn drain_pending_helpers(
  state: AdapterState,
  rev_code: List(String),
) -> #(List(String), AdapterState) {
  case state.pending_helpers {
    [] -> #(rev_code, state)
    [item, ..rest] -> {
      let st0 = AdapterState(..state, pending_helpers: rest)
      let #(code, st1) = render_helper(item, st0)
      drain_pending_helpers(st1, [code, ..rev_code])
    }
  }
}

fn render_helper(
  item: PendingHelper,
  state: AdapterState,
) -> #(String, AdapterState) {
  let use_map = iface_use_map(item.iface_key, state.resolved)
  let iface = item.iface
  let #(w_prefix, st1) = ensure_raw_prefix(state, item.iface_key, iface)
  let #(g_prefix, st2) = ensure_gtypes_prefix(st1, iface)

  let w_type_name = gleam_type_name(item.wit_type_name)
  let g_type_name = mangle.mangle_type_name(w_type_name)
  let w_full = w_prefix <> w_type_name
  let g_full = g_prefix <> g_type_name

  case item.dir, item.type_def {
    W2G, WitRecord(fields:, ..) -> {
      let #(rev_args, st3) =
        list.fold(fields, #([], st2), fn(acc, entry) {
          let #(fname, fty) = entry
          let w_field = mangle.mangle_ident(kebab_to_snake(fname))
          let g_field = mangle.mangle_ident(gleam_value_ident(fname))
          let #(conv_expr, st_next) =
            conv_w2g_expr(fty, item.iface_key, use_map, "w." <> w_field, acc.1)
          #([g_field <> "=" <> conv_expr, ..acc.0], st_next)
        })
      let body = case rev_args {
        [] -> g_full
        args -> g_full <> "(" <> string.join(list.reverse(args), ", ") <> ")"
      }
      #(
        "///|\nfn "
          <> item.id
          <> "(w : "
          <> w_full
          <> ") -> "
          <> g_full
          <> " {\n  "
          <> body
          <> "\n}",
        st3,
      )
    }

    G2W, WitRecord(fields:, ..) -> {
      let #(rev_fields, st3) =
        list.fold(fields, #([], st2), fn(acc, entry) {
          let #(fname, fty) = entry
          let w_field = mangle.mangle_ident(kebab_to_snake(fname))
          let g_field = mangle.mangle_ident(gleam_value_ident(fname))
          let #(conv_expr, st_next) =
            conv_g2w_expr(
              fty,
              item.iface_key,
              use_map,
              "g." <> g_field <> "()",
              acc.1,
            )
          #([w_field <> ": " <> conv_expr, ..acc.0], st_next)
        })
      let body =
        w_full
        <> "::{\n    "
        <> string.join(list.reverse(rev_fields), ",\n    ")
        <> ",\n  }"
      #(
        "///|\nfn "
          <> item.id
          <> "(g : "
          <> g_full
          <> ") -> "
          <> w_full
          <> " {\n  "
          <> body
          <> "\n}",
        st3,
      )
    }

    W2G, WitEnum(cases:, ..) -> {
      let arms =
        list.map(cases, fn(c) {
          let w_c = kebab_to_screaming(c)
          let g_c = gleam_variant_name(c)
          "    " <> w_c <> " => " <> g_prefix <> g_type_name <> "::" <> g_c
        })
        |> string.join("\n")
      #(
        "///|\nfn "
          <> item.id
          <> "(w : "
          <> w_full
          <> ") -> "
          <> g_full
          <> " {\n  match w {\n"
          <> arms
          <> "\n  }\n}",
        st2,
      )
    }

    G2W, WitEnum(cases:, ..) -> {
      let arms =
        list.map(cases, fn(c) {
          let g_c = gleam_variant_name(c)
          let w_c = kebab_to_screaming(c)
          "    " <> g_c <> " => " <> w_full <> "::" <> w_c
        })
        |> string.join("\n")
      #(
        "///|\nfn "
          <> item.id
          <> "(g : "
          <> g_full
          <> ") -> "
          <> w_full
          <> " {\n  match g {\n"
          <> arms
          <> "\n  }\n}",
        st2,
      )
    }

    W2G, WitFlags(flags:, ..) -> {
      let args =
        list.map(flags, fn(fl) {
          let g_fl = mangle.mangle_ident(gleam_value_ident(fl))
          let w_fl = kebab_to_screaming(fl)
          g_fl <> "=w.is_set(" <> w_full <> "Flag::" <> w_fl <> ")"
        })
      let body = case args {
        [] -> g_full
        _ -> g_full <> "(" <> string.join(args, ", ") <> ")"
      }
      #(
        "///|\nfn "
          <> item.id
          <> "(w : "
          <> w_full
          <> ") -> "
          <> g_full
          <> " {\n  "
          <> body
          <> "\n}",
        st2,
      )
    }

    G2W, WitFlags(flags:, ..) -> {
      let body = case flags {
        [] -> "  " <> w_full <> "::default()"
        _ -> {
          let lines =
            list.map(flags, fn(fl) {
              let g_fl = mangle.mangle_ident(gleam_value_ident(fl))
              let w_fl = kebab_to_screaming(fl)
              "  if g."
              <> g_fl
              <> "() { acc = acc.set("
              <> w_full
              <> "Flag::"
              <> w_fl
              <> ") }"
            })
          "  let mut acc = "
          <> w_full
          <> "::default()\n"
          <> string.join(lines, "\n")
          <> "\n  acc"
        }
      }
      #(
        "///|\nfn "
          <> item.id
          <> "(g : "
          <> g_full
          <> ") -> "
          <> w_full
          <> " {\n"
          <> body
          <> "\n}",
        st2,
      )
    }

    W2G, WitVariant(cases:, ..) -> {
      let #(rev_arms, st3) =
        list.fold(cases, #([], st2), fn(acc, entry) {
          let #(cname, payload_opt) = entry
          let ctor = gleam_variant_name(cname)
          case payload_opt {
            None -> {
              let line = "    " <> ctor <> " => " <> g_full <> "::" <> ctor
              #([line, ..acc.0], acc.1)
            }
            Some(pty) -> {
              let #(conv_expr, st_next) =
                conv_w2g_expr(pty, item.iface_key, use_map, "p", acc.1)
              let line =
                "    "
                <> ctor
                <> "(p) => "
                <> g_full
                <> "::"
                <> ctor
                <> "("
                <> conv_expr
                <> ")"
              #([line, ..acc.0], st_next)
            }
          }
        })
      #(
        "///|\nfn "
          <> item.id
          <> "(w : "
          <> w_full
          <> ") -> "
          <> g_full
          <> " {\n  match w {\n"
          <> string.join(list.reverse(rev_arms), "\n")
          <> "\n  }\n}",
        st3,
      )
    }

    G2W, WitVariant(cases:, ..) -> {
      let #(rev_arms, st3) =
        list.fold(cases, #([], st2), fn(acc, entry) {
          let #(cname, payload_opt) = entry
          let ctor = gleam_variant_name(cname)
          case payload_opt {
            None -> {
              let line = "    " <> ctor <> " => " <> w_full <> "::" <> ctor
              #([line, ..acc.0], acc.1)
            }
            Some(pty) -> {
              let #(conv_expr, st_next) =
                conv_g2w_expr(pty, item.iface_key, use_map, "p", acc.1)
              let line =
                "    "
                <> ctor
                <> "(p) => "
                <> w_full
                <> "::"
                <> ctor
                <> "("
                <> conv_expr
                <> ")"
              #([line, ..acc.0], st_next)
            }
          }
        })
      #(
        "///|\nfn "
          <> item.id
          <> "(g : "
          <> g_full
          <> ") -> "
          <> w_full
          <> " {\n  match g {\n"
          <> string.join(list.reverse(rev_arms), "\n")
          <> "\n  }\n}",
        st3,
      )
    }

    _, WitAlias(..) | _, WitResource(..) -> #(
      "// unused alias or resource helper",
      st2,
    )
  }
}

// ---------------------------------------------------------------------------
// Adapter state & moon.pkg helpers
// ---------------------------------------------------------------------------

fn new_adapter_state(
  project_name: String,
  resolved: ResolvedWit,
  seed_imports: List(#(String, String)),
) -> AdapterState {
  new_adapter_state_with_prefixes(
    project_name,
    resolved,
    seed_imports,
    dict.new(),
  )
}

fn new_adapter_state_with_prefixes(
  project_name: String,
  resolved: ResolvedWit,
  seed_imports: List(#(String, String)),
  raw_prefixes: Dict(String, String),
) -> AdapterState {
  let #(pkg_imports, used_aliases) =
    list.fold(seed_imports, #(dict.new(), set.new()), fn(acc, entry) {
      let #(path, alias) = entry
      #(dict.insert(acc.0, path, alias), set.insert(acc.1, alias))
    })
  AdapterState(
    project_name:,
    resolved:,
    raw_prefixes:,
    gtypes_prefixes: dict.new(),
    pkg_imports:,
    used_aliases:,
    next_id: 0,
    emitted_helpers: set.new(),
    pending_helpers: [],
  )
}

fn set_raw_prefix(
  state: AdapterState,
  key: String,
  prefix: String,
) -> AdapterState {
  AdapterState(
    ..state,
    raw_prefixes: dict.insert(state.raw_prefixes, key, prefix),
  )
}

fn ensure_raw_prefix(
  state: AdapterState,
  key: String,
  iface: WitInterface,
) -> #(String, AdapterState) {
  case dict.get(state.raw_prefixes, key) {
    Ok(p) -> #(p, state)
    Error(_) -> {
      let full_pkg =
        state.project_name <> "/" <> wit_bindgen_iface_raw_dir(iface)
      let #(alias, st1) = ensure_pkg_import(state, full_pkg, "wit_raw")
      let prefix = "@" <> alias <> "."
      #(prefix, set_raw_prefix(st1, key, prefix))
    }
  }
}

fn ensure_gtypes_prefix(
  state: AdapterState,
  iface: WitInterface,
) -> #(String, AdapterState) {
  let mod_path = gleam_types_module(state.resolved.root_pkg, iface)
  case dict.get(state.gtypes_prefixes, mod_path) {
    Ok(p) -> #(p, state)
    Error(_) -> {
      let full_pkg =
        state.project_name <> "/" <> pkg_config.module_to_pkg_dir(mod_path)
      let #(alias, st1) = ensure_pkg_import(state, full_pkg, "gtypes")
      let prefix = "@" <> alias <> "."
      #(
        prefix,
        AdapterState(
          ..st1,
          gtypes_prefixes: dict.insert(st1.gtypes_prefixes, mod_path, prefix),
        ),
      )
    }
  }
}

fn ensure_pkg_import(
  state: AdapterState,
  full_pkg: String,
  base_alias: String,
) -> #(String, AdapterState) {
  case dict.get(state.pkg_imports, full_pkg) {
    Ok(existing_alias) -> #(existing_alias, state)
    Error(_) -> {
      let alias = pkg_config.pick_unique(base_alias, "_", 0, state.used_aliases)
      #(
        alias,
        AdapterState(
          ..state,
          pkg_imports: dict.insert(state.pkg_imports, full_pkg, alias),
          used_aliases: set.insert(state.used_aliases, alias),
        ),
      )
    }
  }
}

fn fresh_id(state: AdapterState) -> #(String, AdapterState) {
  let n = state.next_id
  #(int.to_string(n), AdapterState(..state, next_id: n + 1))
}

fn sanitize_helper_part(s: String) -> String {
  s
  |> string.replace(":", "_")
  |> string.replace("/", "_")
  |> string.replace("-", "_")
}

fn read_moon_pkg(
  path: String,
) -> Result(#(List(#(String, String)), Option(String)), String) {
  use content <- result.try(
    simplifile.read(from: path)
    |> result.map_error(fn(err) {
      "Failed to read '" <> path <> "': " <> simplifile.describe_error(err)
    }),
  )
  Ok(pkg_config.parse_moon_pkg(content))
}

fn extract_raw_prefixes_from_imports(
  project_name: String,
  imports: List(#(String, String)),
) -> Dict(String, String) {
  let pfx = project_name <> "/interface/"
  list.fold(imports, dict.new(), fn(acc, entry) {
    let #(pkg_path, alias) = entry
    case string.split_once(pkg_path, on: pfx) {
      Ok(#("", rest)) ->
        case string.split(rest, "/") {
          [ns, pkg, iface] ->
            dict.insert(
              acc,
              ns <> ":" <> pkg <> "/" <> iface,
              "@" <> alias <> ".",
            )
          _ -> acc
        }
      _ -> acc
    }
  })
}
