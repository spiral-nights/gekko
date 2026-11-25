import filepath
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import lower/mangle
import simplifile
import wit/ast.{
  type ResolvedWit, type WitFunc, type WitInterface, type WitPackageId,
  type WitType, type WitTypeDef, type WitUse, ResourceConstructor,
  ResourceMethod, ResourceStatic, WitAlias, WitBool, WitBorrow, WitChar, WitEnum,
  WitF32, WitF64, WitFlags, WitList, WitNamed, WitOption, WitOwn, WitRecord,
  WitResource, WitResult, WitS16, WitS32, WitS64, WitS8, WitString, WitTuple,
  WitU16, WitU32, WitU64, WitU8, WitVariant, WorldExportFunc, WorldExportIface,
  WorldImportFunc, WorldImportIface, WorldInclude, WorldUse, gleam_export_module,
  gleam_import_module, gleam_type_name, gleam_types_module, gleam_value_ident,
  gleam_variant_name, gleam_world_export_module, gleam_world_import_module,
  kebab_to_snake, moonbit_imp_adapter_pkg, moonbit_world_imp_adapter_pkg,
  resolve_iface_key_in,
}

/// Summary of files generated or skipped by `gekko wit gen`.
pub type WitGenReport {
  WitGenReport(
    written_files: List(String),
    created_stubs: List(String),
    skipped_existing_stubs: List(String),
  )
}

type ImportCollector {
  ImportCollector(need_option: Bool, type_imports: Dict(String, Set(String)))
}

/// Generate Gleam types, import external bindings, and non-overwriting starter
/// export stubs inside `project_root/src/`.
pub fn generate_project_bindings(
  resolved: ResolvedWit,
  project_root: String,
) -> Result(WitGenReport, String) {
  let reachable_keys = collect_reachable_iface_keys(resolved)

  // 1. Emit type modules (`src/wit/..._types.gleam`) for every reachable
  //    interface that declares types.
  use rev_written <- result.try(
    list.try_fold(reachable_keys, [], fn(acc, key) {
      case dict.get(resolved.interfaces, key) {
        Error(_) -> Ok(acc)
        Ok(iface) ->
          case iface.types {
            [] -> Ok(acc)
            _ -> {
              let mod_path = gleam_types_module(resolved.root_pkg, iface)
              let rel_path = "src/" <> mod_path <> ".gleam"
              let content = render_types_module(resolved, iface)
              use _ <- result.try(write_file(
                filepath.join(project_root, rel_path),
                content,
              ))
              Ok([rel_path, ..acc])
            }
          }
      }
    }),
  )

  // 2. Emit import modules (`src/wit/<iface>.gleam`) and starter export stubs
  //    (`src/<iface>.gleam`).
  let imported_iface_keys =
    list.filter_map(resolved.world.items, fn(item) {
      case item {
        WorldImportIface(ref) ->
          Ok(resolve_iface_key_in(resolved.interfaces, resolved.root_pkg, ref))
        _ -> Error(Nil)
      }
    })
    |> list.unique

  let exported_iface_keys =
    list.filter_map(resolved.world.items, fn(item) {
      case item {
        WorldExportIface(ref) ->
          Ok(resolve_iface_key_in(resolved.interfaces, resolved.root_pkg, ref))
        _ -> Error(Nil)
      }
    })
    |> list.unique

  use rev_written <- result.try(
    list.try_fold(imported_iface_keys, rev_written, fn(acc, key) {
      case dict.get(resolved.interfaces, key) {
        Error(_) -> Ok(acc)
        Ok(iface) -> {
          let mod_path = gleam_import_module(resolved.root_pkg, iface)
          let rel_path = "src/" <> mod_path <> ".gleam"
          let adapter_pkg = moonbit_imp_adapter_pkg(iface)
          let content = render_import_module(resolved, iface, adapter_pkg)
          use _ <- result.try(write_file(
            filepath.join(project_root, rel_path),
            content,
          ))
          Ok([rel_path, ..acc])
        }
      }
    }),
  )

  let world_imports =
    list.filter_map(resolved.world.items, fn(item) {
      case item {
        WorldImportFunc(f) -> Ok(f)
        _ -> Error(Nil)
      }
    })
  use rev_written <- result.try(case world_imports {
    [] -> Ok(rev_written)
    funcs -> {
      let mod_path = gleam_world_import_module(resolved.world)
      let rel_path = "src/" <> mod_path <> ".gleam"
      let adapter_pkg = moonbit_world_imp_adapter_pkg(resolved.world)
      let content = render_world_import_module(resolved, funcs, adapter_pkg)
      use _ <- result.try(write_file(
        filepath.join(project_root, rel_path),
        content,
      ))
      Ok([rel_path, ..rev_written])
    }
  })

  use #(rev_written, rev_created, rev_skipped) <- result.try(
    list.try_fold(exported_iface_keys, #(rev_written, [], []), fn(acc, key) {
      let #(w_acc, c_acc, s_acc) = acc
      case dict.get(resolved.interfaces, key) {
        Error(_) -> Ok(acc)
        Ok(iface) -> {
          let mod_path = gleam_export_module(resolved.root_pkg, iface)
          let rel_path = "src/" <> mod_path <> ".gleam"
          let full_path = filepath.join(project_root, rel_path)
          case simplifile.is_file(full_path) {
            Ok(True) -> Ok(#(w_acc, c_acc, [rel_path, ..s_acc]))
            _ -> {
              let content = render_export_stub_module(resolved, iface)
              use _ <- result.try(write_file(full_path, content))
              Ok(#([rel_path, ..w_acc], [rel_path, ..c_acc], s_acc))
            }
          }
        }
      }
    }),
  )

  let world_exports =
    list.filter_map(resolved.world.items, fn(item) {
      case item {
        WorldExportFunc(f) -> Ok(f)
        _ -> Error(Nil)
      }
    })
  use #(rev_written, rev_created, rev_skipped) <- result.try(
    case world_exports {
      [] -> Ok(#(rev_written, rev_created, rev_skipped))
      funcs -> {
        let mod_path = gleam_world_export_module(resolved.world)
        let rel_path = "src/" <> mod_path <> ".gleam"
        let full_path = filepath.join(project_root, rel_path)
        case simplifile.is_file(full_path) {
          Ok(True) -> Ok(#(rev_written, rev_created, [rel_path, ..rev_skipped]))
          _ -> {
            let content = render_world_export_stub_module(resolved, funcs)
            use _ <- result.try(write_file(full_path, content))
            Ok(#(
              [rel_path, ..rev_written],
              [rel_path, ..rev_created],
              rev_skipped,
            ))
          }
        }
      }
    },
  )

  Ok(WitGenReport(
    written_files: list.reverse(rev_written),
    created_stubs: list.reverse(rev_created),
    skipped_existing_stubs: list.reverse(rev_skipped),
  ))
}

/// Collect all interface keys reachable from `resolved.world` via
/// import/export/use edges, ordered dependencies-before-dependents.
pub fn collect_reachable_iface_keys(resolved: ResolvedWit) -> List(String) {
  let seeds =
    list.filter_map(resolved.world.items, fn(item) {
      case item {
        WorldImportIface(ref) | WorldExportIface(ref) ->
          Ok(resolve_iface_key_in(resolved.interfaces, resolved.root_pkg, ref))
        WorldUse(u) ->
          Ok(resolve_iface_key_in(
            resolved.interfaces,
            resolved.root_pkg,
            u.target,
          ))
        WorldImportFunc(_) | WorldExportFunc(_) | WorldInclude(_, _) ->
          Error(Nil)
      }
    })
  let #(_, rev_order) =
    list.fold(seeds, #(set.new(), []), fn(acc, key) {
      visit_iface_dfs(key, resolved.interfaces, acc.0, acc.1)
    })
  list.reverse(rev_order)
}

fn visit_iface_dfs(
  key: String,
  interfaces: Dict(String, WitInterface),
  visited: Set(String),
  rev_order: List(String),
) -> #(Set(String), List(String)) {
  case set.contains(visited, key) {
    True -> #(visited, rev_order)
    False -> {
      let visited1 = set.insert(visited, key)
      let #(visited2, rev_order2) = case dict.get(interfaces, key) {
        Ok(iface) ->
          list.fold(iface.uses, #(visited1, rev_order), fn(acc, u) {
            let dep_key = resolve_iface_key_in(interfaces, iface.pkg, u.target)
            visit_iface_dfs(dep_key, interfaces, acc.0, acc.1)
          })
        Error(_) -> #(visited1, rev_order)
      }
      #(visited2, [key, ..rev_order2])
    }
  }
}

/// Build `local_wit_type_name -> #(source_iface_key, remote_wit_type_name)`
/// from a list of `WitUse` clauses.
pub fn build_use_map(
  default_pkg: WitPackageId,
  uses: List(WitUse),
) -> Dict(String, #(String, String)) {
  list.fold(uses, dict.new(), fn(acc, u) {
    let src_key = ast.resolve_iface_ref(default_pkg, u.target)
    list.fold(u.names, acc, fn(inner, entry) {
      let #(remote, alias_opt) = entry
      let local = option.unwrap(alias_opt, remote)
      dict.insert(inner, local, #(src_key, remote))
    })
  })
}

fn render_types_module(resolved: ResolvedWit, iface: WitInterface) -> String {
  let use_map = build_use_map(iface.pkg, iface.uses)
  let init_coll = ImportCollector(need_option: False, type_imports: dict.new())

  let #(rev_defs, final_coll) =
    list.fold(iface.types, #([], init_coll), fn(acc, td) {
      let #(defs_acc, coll) = acc
      let #(code, next_coll) =
        render_type_def(td, iface, use_map, resolved, coll)
      #([code, ..defs_acc], next_coll)
    })

  let self_mod = gleam_types_module(resolved.root_pkg, iface)
  let header = "// Generated by gekko wit gen — DO NOT EDIT.\n\n"
  let imports = render_imports_excluding(final_coll, Some(self_mod))
  header <> imports <> string.join(list.reverse(rev_defs), "\n\n") <> "\n"
}

fn render_type_def(
  td: WitTypeDef,
  iface: WitInterface,
  use_map: Dict(String, #(String, String)),
  resolved: ResolvedWit,
  coll: ImportCollector,
) -> #(String, ImportCollector) {
  case td {
    WitRecord(name:, fields:) -> {
      let ty_name = gleam_type_name(name)
      let #(rev_fields, next_coll) =
        list.fold(fields, #([], coll), fn(acc, entry) {
          let #(f_acc, c) = acc
          let #(fname, fty) = entry
          let #(ty_str, c1) =
            render_type_in_iface(fty, Some(iface), use_map, resolved, c)
          let line = "    " <> gleam_value_ident(fname) <> ": " <> ty_str <> ","
          #([line, ..f_acc], c1)
        })
      let body = case rev_fields {
        [] -> "  " <> ty_name
        lines ->
          "  "
          <> ty_name
          <> "(\n"
          <> string.join(list.reverse(lines), "\n")
          <> "\n  )"
      }
      #("pub type " <> ty_name <> " {\n" <> body <> "\n}", next_coll)
    }

    WitEnum(name:, cases:) -> {
      let ty_name = gleam_type_name(name)
      let lines =
        list.map(cases, fn(c) { "  " <> gleam_variant_name(c) })
        |> string.join("\n")
      #("pub type " <> ty_name <> " {\n" <> lines <> "\n}", coll)
    }

    WitFlags(name:, flags:) -> {
      let ty_name = gleam_type_name(name)
      let field_lines =
        list.map(flags, fn(fl) { "    " <> gleam_value_ident(fl) <> ": Bool," })
        |> string.join("\n")
      let body = case flags {
        [] -> "  " <> ty_name
        _ -> "  " <> ty_name <> "(\n" <> field_lines <> "\n  )"
      }
      #("pub type " <> ty_name <> " {\n" <> body <> "\n}", coll)
    }

    WitVariant(name:, cases:) -> {
      let ty_name = gleam_type_name(name)
      let #(rev_cases, next_coll) =
        list.fold(cases, #([], coll), fn(acc, entry) {
          let #(c_acc, c) = acc
          let #(cname, payload_opt) = entry
          let vname = gleam_variant_name(cname)
          case payload_opt {
            None -> #(["  " <> vname, ..c_acc], c)
            Some(pty) -> {
              let #(ty_str, c1) =
                render_type_in_iface(pty, Some(iface), use_map, resolved, c)
              #(["  " <> vname <> "(" <> ty_str <> ")", ..c_acc], c1)
            }
          }
        })
      #(
        "pub type "
          <> ty_name
          <> " {\n"
          <> string.join(list.reverse(rev_cases), "\n")
          <> "\n}",
        next_coll,
      )
    }

    WitAlias(name:, target:) -> {
      let ty_name = gleam_type_name(name)
      let #(target_str, next_coll) =
        render_type_in_iface(target, Some(iface), use_map, resolved, coll)
      #("pub type " <> ty_name <> " =\n  " <> target_str, next_coll)
    }

    WitResource(name:, ..) -> {
      let ty_name = gleam_type_name(name)
      let adapter_pkg = moonbit_imp_adapter_pkg(iface)
      #(
        "/// @external_type(moonbit, \""
          <> adapter_pkg
          <> "\", \""
          <> ty_name
          <> "\")\npub type "
          <> ty_name,
        coll,
      )
    }
  }
}

fn render_import_module(
  resolved: ResolvedWit,
  iface: WitInterface,
  adapter_pkg: String,
) -> String {
  let use_map = build_use_map(iface.pkg, iface.uses)
  let init_coll = ImportCollector(need_option: False, type_imports: dict.new())

  let #(rev_fns, coll1) =
    list.fold(iface.funcs, #([], init_coll), fn(acc, f) {
      let #(fns_acc, coll) = acc
      let #(code, next_coll) =
        render_import_func(f, Some(iface), use_map, resolved, adapter_pkg, coll)
      #([code, ..fns_acc], next_coll)
    })

  let #(rev_res_fns, final_coll) =
    list.fold(iface.types, #(rev_fns, coll1), fn(acc, td) {
      case td {
        WitResource(name:, methods:) ->
          render_resource_import_funcs(
            name,
            methods,
            iface,
            use_map,
            resolved,
            adapter_pkg,
            acc.0,
            acc.1,
          )
        _ -> acc
      }
    })

  let header = "// Generated by gekko wit gen — DO NOT EDIT.\n\n"
  let imports = render_imports(final_coll)
  header <> imports <> string.join(list.reverse(rev_res_fns), "\n\n") <> "\n"
}

fn render_resource_import_funcs(
  res_name: String,
  methods: List(ast.WitResourceMethod),
  iface: WitInterface,
  use_map: Dict(String, #(String, String)),
  resolved: ResolvedWit,
  adapter_pkg: String,
  rev_fns: List(String),
  coll: ImportCollector,
) -> #(List(String), ImportCollector) {
  let res_snake = kebab_to_snake(res_name)
  let res_type = WitNamed(res_name)
  let #(rev_after_methods, coll1) =
    list.fold(methods, #(rev_fns, coll), fn(acc, m) {
      let #(fns_acc, c) = acc
      let fake_func = case m.kind {
        ResourceConstructor ->
          ast.WitFunc(
            name: "new-" <> res_name,
            params: m.params,
            result: Some(res_type),
          )
        ResourceMethod ->
          ast.WitFunc(
            name: res_snake <> "-" <> m.name,
            params: [#("self", res_type), ..m.params],
            result: m.result,
          )
        ResourceStatic ->
          ast.WitFunc(
            name: res_snake <> "-" <> m.name,
            params: m.params,
            result: m.result,
          )
      }
      let #(code, next_c) =
        render_import_func(
          fake_func,
          Some(iface),
          use_map,
          resolved,
          adapter_pkg,
          c,
        )
      #([code, ..fns_acc], next_c)
    })
  let drop_func =
    ast.WitFunc(
      name: "drop-" <> res_name,
      params: [#("self", res_type)],
      result: None,
    )
  let #(drop_code, coll2) =
    render_import_func(
      drop_func,
      Some(iface),
      use_map,
      resolved,
      adapter_pkg,
      coll1,
    )
  #([drop_code, ..rev_after_methods], coll2)
}

fn render_world_import_module(
  resolved: ResolvedWit,
  funcs: List(WitFunc),
  adapter_pkg: String,
) -> String {
  let world_uses =
    list.filter_map(resolved.world.items, fn(item) {
      case item {
        WorldUse(u) -> Ok(u)
        _ -> Error(Nil)
      }
    })
  let use_map = build_use_map(resolved.root_pkg, world_uses)
  let init_coll = ImportCollector(need_option: False, type_imports: dict.new())

  let #(rev_fns, final_coll) =
    list.fold(funcs, #([], init_coll), fn(acc, f) {
      let #(fns_acc, coll) = acc
      let #(code, next_coll) =
        render_import_func(f, None, use_map, resolved, adapter_pkg, coll)
      #([code, ..fns_acc], next_coll)
    })

  let header = "// Generated by gekko wit gen — DO NOT EDIT.\n\n"
  let imports = render_imports(final_coll)
  header <> imports <> string.join(list.reverse(rev_fns), "\n\n") <> "\n"
}

fn render_import_func(
  f: WitFunc,
  owner_iface: Option(WitInterface),
  use_map: Dict(String, #(String, String)),
  resolved: ResolvedWit,
  adapter_pkg: String,
  coll: ImportCollector,
) -> #(String, ImportCollector) {
  let fn_ident = gleam_value_ident(f.name)
  let mbt_fn = mangle.mangle_ident(fn_ident)
  let #(sig_str, param_idents, next_coll) =
    render_fn_sig(f, fn_ident, owner_iface, use_map, resolved, coll)
  let ignore_lines = list.map(param_idents, fn(p) { "  let _ = " <> p })
  let body_lines =
    list.append(ignore_lines, [
      "  panic as \"WIT import only available when compiled as a Wasm component\"",
    ])
  let code =
    "/// @external(moonbit, \""
    <> adapter_pkg
    <> "\", \""
    <> mbt_fn
    <> "\")\n"
    <> "pub fn "
    <> sig_str
    <> " {\n"
    <> string.join(body_lines, "\n")
    <> "\n}"
  #(code, next_coll)
}

fn render_export_stub_module(
  resolved: ResolvedWit,
  iface: WitInterface,
) -> String {
  let use_map = build_use_map(iface.pkg, iface.uses)
  let init_coll = ImportCollector(need_option: False, type_imports: dict.new())

  let #(rev_fns, final_coll) =
    list.fold(iface.funcs, #([], init_coll), fn(acc, f) {
      let #(fns_acc, coll) = acc
      let #(code, next_coll) =
        render_export_stub_func(f, Some(iface), use_map, resolved, coll)
      #([code, ..fns_acc], next_coll)
    })

  let header = "// Starter stub generated by gekko wit gen — safe to edit.\n\n"
  let imports = render_imports(final_coll)
  header <> imports <> string.join(list.reverse(rev_fns), "\n\n") <> "\n"
}

fn render_world_export_stub_module(
  resolved: ResolvedWit,
  funcs: List(WitFunc),
) -> String {
  let world_uses =
    list.filter_map(resolved.world.items, fn(item) {
      case item {
        WorldUse(u) -> Ok(u)
        _ -> Error(Nil)
      }
    })
  let use_map = build_use_map(resolved.root_pkg, world_uses)
  let init_coll = ImportCollector(need_option: False, type_imports: dict.new())

  let #(rev_fns, final_coll) =
    list.fold(funcs, #([], init_coll), fn(acc, f) {
      let #(fns_acc, coll) = acc
      let #(code, next_coll) =
        render_export_stub_func(f, None, use_map, resolved, coll)
      #([code, ..fns_acc], next_coll)
    })

  let header = "// Starter stub generated by gekko wit gen — safe to edit.\n\n"
  let imports = render_imports(final_coll)
  header <> imports <> string.join(list.reverse(rev_fns), "\n\n") <> "\n"
}

fn render_export_stub_func(
  f: WitFunc,
  owner_iface: Option(WitInterface),
  use_map: Dict(String, #(String, String)),
  resolved: ResolvedWit,
  coll: ImportCollector,
) -> #(String, ImportCollector) {
  let fn_ident = gleam_value_ident(f.name)
  let #(sig_str, _param_idents, next_coll) =
    render_fn_sig(f, fn_ident, owner_iface, use_map, resolved, coll)
  let code =
    "pub fn "
    <> sig_str
    <> " {\n"
    <> "  todo as \"Implement WIT export `"
    <> f.name
    <> "`\"\n}"
  #(code, next_coll)
}

fn render_fn_sig(
  f: WitFunc,
  fn_ident: String,
  owner_iface: Option(WitInterface),
  use_map: Dict(String, #(String, String)),
  resolved: ResolvedWit,
  coll: ImportCollector,
) -> #(String, List(String), ImportCollector) {
  let #(rev_params, rev_idents, coll1) =
    list.fold(f.params, #([], [], coll), fn(acc, p) {
      let #(p_acc, id_acc, c) = acc
      let #(pname, pty) = p
      let p_ident = gleam_value_ident(pname)
      let #(ty_str, c1) =
        render_type_in_iface(pty, owner_iface, use_map, resolved, c)
      #([p_ident <> ": " <> ty_str, ..p_acc], [p_ident, ..id_acc], c1)
    })
  let #(ret_str, coll2) = case f.result {
    None -> #("Nil", coll1)
    Some(rty) ->
      render_type_in_iface(rty, owner_iface, use_map, resolved, coll1)
  }
  let sig =
    fn_ident
    <> "("
    <> string.join(list.reverse(rev_params), ", ")
    <> ") -> "
    <> ret_str
  #(sig, list.reverse(rev_idents), coll2)
}

fn render_type_in_iface(
  ty: WitType,
  owner_iface: Option(WitInterface),
  use_map: Dict(String, #(String, String)),
  resolved: ResolvedWit,
  coll: ImportCollector,
) -> #(String, ImportCollector) {
  case ty {
    WitBool -> #("Bool", coll)
    WitS8 | WitS16 | WitS32 | WitS64 | WitU8 | WitU16 | WitU32 | WitU64 -> #(
      "Int",
      coll,
    )
    WitF32 | WitF64 -> #("Float", coll)
    WitChar | WitString -> #("String", coll)
    WitList(WitU8) -> #("BitArray", coll)
    WitList(inner) -> {
      let #(inner_s, c1) =
        render_type_in_iface(inner, owner_iface, use_map, resolved, coll)
      #("List(" <> inner_s <> ")", c1)
    }
    WitOption(inner) -> {
      let #(inner_s, c1) =
        render_type_in_iface(inner, owner_iface, use_map, resolved, coll)
      #("Option(" <> inner_s <> ")", ImportCollector(..c1, need_option: True))
    }
    WitTuple(els) -> {
      let #(rev_els, c1) =
        list.fold(els, #([], coll), fn(acc, el) {
          let #(e_s, c_next) =
            render_type_in_iface(el, owner_iface, use_map, resolved, acc.1)
          #([e_s, ..acc.0], c_next)
        })
      #("#(" <> string.join(list.reverse(rev_els), ", ") <> ")", c1)
    }
    WitResult(ok:, err:) -> {
      let #(ok_s, c1) = case ok {
        None -> #("Nil", coll)
        Some(t) -> render_type_in_iface(t, owner_iface, use_map, resolved, coll)
      }
      let #(err_s, c2) = case err {
        None -> #("Nil", c1)
        Some(e) -> render_type_in_iface(e, owner_iface, use_map, resolved, c1)
      }
      #("Result(" <> ok_s <> ", " <> err_s <> ")", c2)
    }
    WitOwn(wit_name) | WitBorrow(wit_name) | WitNamed(wit_name) ->
      case dict.get(use_map, wit_name) {
        Ok(#(src_key, remote_name)) -> {
          let remote_type = gleam_type_name(remote_name)
          let c1 = case dict.get(resolved.interfaces, src_key) {
            Ok(src_iface) -> {
              let src_mod = gleam_types_module(resolved.root_pkg, src_iface)
              add_type_import(coll, src_mod, remote_type)
            }
            Error(_) -> coll
          }
          #(remote_type, c1)
        }
        Error(_) -> {
          let local_type = gleam_type_name(wit_name)
          // When emitting inside the same `_types` module (`fn_mod == False`?):
          // caller is either `_types` (same file, no import needed) or an
          // import/export module needing `<iface>_types`. We detect `_types`
          // vs external callers cleanly via `record_self_type`!
          let c1 = case owner_iface {
            None -> coll
            Some(iface) -> {
              let self_mod = gleam_types_module(resolved.root_pkg, iface)
              add_type_import(coll, self_mod, local_type)
            }
          }
          #(local_type, c1)
        }
      }
  }
}

fn add_type_import(
  coll: ImportCollector,
  mod_path: String,
  type_name: String,
) -> ImportCollector {
  let existing = case dict.get(coll.type_imports, mod_path) {
    Ok(s) -> s
    Error(_) -> set.new()
  }
  ImportCollector(
    ..coll,
    type_imports: dict.insert(
      coll.type_imports,
      mod_path,
      set.insert(existing, type_name),
    ),
  )
}

fn render_imports(coll: ImportCollector) -> String {
  render_imports_excluding(coll, None)
}

fn render_imports_excluding(
  coll: ImportCollector,
  exclude_mod: Option(String),
) -> String {
  let opt_line = case coll.need_option {
    True -> ["import gleam/option.{type Option}"]
    False -> []
  }
  let type_lines =
    coll.type_imports
    |> dict.to_list
    |> list.filter(fn(entry) { Some(entry.0) != exclude_mod })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(entry) {
      let #(mod_path, names) = entry
      let sorted_names =
        set.to_list(names)
        |> list.sort(string.compare)
        |> list.map(fn(n) { "type " <> n })
        |> string.join(", ")
      "import " <> mod_path <> ".{" <> sorted_names <> "}"
    })
  case list.append(opt_line, type_lines) {
    [] -> ""
    lines -> string.join(lines, "\n") <> "\n\n"
  }
}

fn write_file(path: String, contents: String) -> Result(Nil, String) {
  let dir = filepath.directory_name(path)
  use _ <- result.try(
    simplifile.create_directory_all(dir)
    |> result.map_error(fn(err) {
      "Failed to create directory '"
      <> dir
      <> "': "
      <> simplifile.describe_error(err)
    }),
  )
  simplifile.write(to: path, contents:)
  |> result.map_error(fn(err) {
    "Failed to write '" <> path <> "': " <> simplifile.describe_error(err)
  })
}
