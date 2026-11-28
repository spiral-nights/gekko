import emit/trait_bounds.{type ProjectTraitBounds}
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string
import index/symbol_table.{type SymbolTable}
import lower/ir.{
  type IrBinOp, type IrCallArg, type IrClause, type IrConstant, type IrExpr,
  type IrFunction, type IrModule, type IrStmt, AssertAbort, IrAbort, IrAddFloat,
  IrAddInt, IrAnd, IrBinOp, IrBitString, IrBlock, IrBool, IrBreak, IrCall,
  IrConstructor, IrContinue, IrDivFloat, IrDivInt, IrEcho, IrEq, IrFloat, IrFn,
  IrForLoop, IrGetterCall, IrGtEqFloat, IrGtEqInt, IrGtFloat, IrGtInt, IrInt,
  IrList, IrLtEqFloat, IrLtEqInt, IrLtFloat, IrLtInt, IrMatch, IrModuleRef,
  IrMultFloat, IrMultInt, IrNegateBool, IrNegateInt, IrNotEq, IrOr, IrParam,
  IrPatDiscard, IrPatUnit, IrPatVar, IrRemInt, IrStmtAssert, IrStmtExpr,
  IrStmtGuard, IrStmtLet, IrString, IrStringConcat, IrSubFloat, IrSubInt,
  IrTuple, IrTupleIndex, IrTypeAlias, IrTypeDef, IrUnit, IrVar, LetAssertAbort,
  PanicAbort, TodoAbort,
}

import lower/ir_util
import lower/mangle
import moonbit/ffi_meta.{type FfiMetadata}
import project/prepass.{GleamPatch, PackageCall, Patched, WasmImport}

import emit/moonbit_decl.{
  type EmitCtx, EmitCtx, add_gprelude_import, add_module_import,
  align_call_args_tracked, collect_public_referenced_local_names,
  collect_visible_alias_names, emit_constructor_prefix, emit_constructor_value,
  emit_fn_param, emit_getter, emit_pattern, emit_type, emit_type_alias,
  emit_type_def, escape_plain_string, escape_string_literal,
  format_function_type_params, format_type_params, infer_fn_param_types,
  is_polymorphic_constant, lookup_callee_with_bounds, lookup_ctor_field_labels,
  lookup_ctor_info, lookup_fn_param_labels, map_acc, map_index_acc,
  pattern_is_irrefutable, register_import, visibility, wrap_if_compound,
}

/// Render a lowered `IrModule` into MoonBit source code and the list of
/// `#(pkg_or_dir, alias)` imports needed for its `moon.pkg`.
pub fn emit_module(module: IrModule) -> #(String, List(#(String, String))) {
  let meta = ffi_meta.base_metadata()
  let bounds = trait_bounds.analyze_project([module], None, meta)
  emit_module_inner(module, None, meta, bounds, dict.new())
}

/// Render a lowered `IrModule` with full `SymbolTable` access (enabling
/// higher-order eta-expansion for imported constructors).
pub fn emit_module_with_table(
  module: IrModule,
  table: SymbolTable,
) -> #(String, List(#(String, String))) {
  let meta = ffi_meta.base_metadata()
  let bounds = trait_bounds.analyze_project([module], Some(table), meta)
  emit_module_inner(module, Some(table), meta, bounds, dict.new())
}

/// Render a lowered `IrModule` with pre-scanned FFI metadata and whole-project
/// inferred trait bounds.
pub fn emit_module_with_context(
  module: IrModule,
  table: Option(SymbolTable),
  ffi_metadata: FfiMetadata,
  project_bounds: ProjectTraitBounds,
) -> #(String, List(#(String, String))) {
  emit_module_inner(module, table, ffi_metadata, project_bounds, dict.new())
}

/// Like `emit_module_with_context`, using an explicit `module_name -> pkg_dir`
/// mapping so colliding module paths resolve to distinct MoonBit packages.
pub fn emit_module_with_pkg_dirs(
  module: IrModule,
  table: Option(SymbolTable),
  ffi_metadata: FfiMetadata,
  project_bounds: ProjectTraitBounds,
  module_pkg_dirs: Dict(String, String),
) -> #(String, List(#(String, String))) {
  emit_module_inner(
    module,
    table,
    ffi_metadata,
    project_bounds,
    module_pkg_dirs,
  )
}

/// Return True if this root module defines a 0-argument `main()` entrypoint.
pub fn module_has_main(module: IrModule) -> Bool {
  module.module_name == module.package_name
  && list.any(module.functions, fn(f) {
    f.unmangled_name == "main" && f.params == []
  })
}

fn emit_module_inner(
  module: IrModule,
  table: Option(SymbolTable),
  ffi_metadata: FfiMetadata,
  project_bounds: ProjectTraitBounds,
  module_pkg_dirs: Dict(String, String),
) -> #(String, List(#(String, String))) {
  let local_ctors =
    list.fold(module.types, dict.new(), fn(acc, td) {
      let variant_count = list.length(td.variants)
      list.fold(td.variants, acc, fn(inner, v) {
        let labels = list.map(v.fields, fn(f) { f.label })
        dict.insert(inner, v.name, #(variant_count, labels))
      })
    })

  let local_external_types =
    list.fold(module.types, dict.new(), fn(acc, td) {
      case td.external_type {
        Some(ext) ->
          acc
          |> dict.insert(td.name, ext)
          |> dict.insert(td.unmangled_name, ext)
        None -> acc
      }
    })

  let own_pkg_dir = case dict.get(module_pkg_dirs, module.module_name) {
    Ok(d) -> d
    Error(_) -> module.module_name
  }
  let own_default_alias = case string.split(own_pkg_dir, "/") |> list.last {
    Ok(seg) -> seg
    Error(_) -> own_pkg_dir
  }

  let ctx0 =
    EmitCtx(
      current_module: module.module_name,
      local_ctors:,
      local_external_types:,
      local_vars: set.new(),
      table:,
      ffi_metadata:,
      project_bounds:,
      module_pkg_dirs:,
      pkg_to_alias: dict.new(),
      used_aliases: set.from_list([
        "gprelude",
        own_default_alias,
        mangle.mangle_ident(own_default_alias),
      ]),
    )

  let pub_referenced_names = collect_public_referenced_local_names(module)
  let effective_types =
    list.map(module.types, fn(td) {
      case
        td.publicity == glance.Private
        && set.contains(pub_referenced_names, td.name)
      {
        True -> IrTypeDef(..td, publicity: glance.Public, opaque_: True)
        False -> td
      }
    })
  let #(raw_type_blocks, ctx1) = map_acc(effective_types, ctx0, emit_type_def)
  let type_blocks = list.filter(raw_type_blocks, fn(b) { b != "" })

  let visible_alias_names = collect_visible_alias_names(module)
  let visible_aliases =
    list.filter_map(module.type_aliases, fn(ta) {
      case set.contains(visible_alias_names, ta.name) {
        False -> Error(Nil)
        True ->
          case
            ta.publicity == glance.Private
            && set.contains(pub_referenced_names, ta.name)
          {
            True -> Ok(IrTypeAlias(..ta, publicity: glance.Public))
            False -> Ok(ta)
          }
      }
    })
  let #(alias_blocks, ctx2) = map_acc(visible_aliases, ctx1, emit_type_alias)

  let #(getter_blocks, ctx3) = map_acc(module.getters, ctx2, emit_getter)

  let #(const_blocks, ctx4) = map_acc(module.constants, ctx3, emit_constant)

  let #(fn_blocks, ctx5) = map_acc(module.functions, ctx4, emit_function)

  let main_blocks = case module_has_main(module) {
    True -> ["///|\nfn main {\n  @prelude.ignore(main_())\n}"]
    False -> []
  }

  let all_blocks =
    list.flatten([
      type_blocks,
      alias_blocks,
      getter_blocks,
      const_blocks,
      fn_blocks,
      main_blocks,
    ])

  let source = case all_blocks {
    [] -> ""
    _ -> string.join(all_blocks, "\n\n") <> "\n"
  }

  let import_list =
    ctx5.pkg_to_alias
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.1, b.1) })

  #(source, import_list)
}

fn emit_constant(c: IrConstant, ctx: EmitCtx) -> #(String, EmitCtx) {
  let vis = visibility(c.publicity)
  let type_params = ir_util.collect_type_vars_in_type(c.value_type)
  case type_params {
    [] -> {
      let #(ty_str, ctx1) = emit_type(c.value_type, ctx)
      let #(val_str, ctx2) = emit_expr(c.value, ctx1)
      #(
        "///|\n"
          <> vis
          <> "let "
          <> c.name
          <> " : "
          <> ty_str
          <> " = "
          <> val_str,
        ctx2,
      )
    }
    _ -> {
      let #(ty_str, ctx1) = emit_type(c.value_type, ctx)
      let #(val_str, ctx2) = emit_expr(c.value, ctx1)
      #(
        "///|\n"
          <> vis
          <> "fn"
          <> format_type_params(type_params)
          <> " "
          <> c.name
          <> "() -> "
          <> ty_str
          <> " {\n  "
          <> val_str
          <> "\n}",
        ctx2,
      )
    }
  }
}

fn normalize_unnamed_params(f: IrFunction) -> IrFunction {
  let named_params =
    list.index_map(f.params, fn(p, idx) {
      case p.name {
        "_" -> IrParam(..p, name: "__arg_" <> int.to_string(idx))
        _ -> p
      }
    })
  ir.IrFunction(..f, params: named_params)
}

fn emit_function_header(
  f: IrFunction,
  ctx: EmitCtx,
) -> #(String, String, String, EmitCtx) {
  let vis = visibility(f.publicity)
  let #(generics, ctx0) = format_function_type_params(f, ctx)
  let #(param_strs, ctx1) = map_acc(f.params, ctx0, emit_fn_param)
  let #(ret_str, ctx2) = emit_type(f.return_type, ctx1)

  let header =
    vis
    <> "fn"
    <> generics
    <> " "
    <> f.name
    <> "("
    <> string.join(param_strs, ", ")
    <> ") -> "
    <> ret_str
  #(header, generics, ret_str, ctx2)
}

/// Emit a `#gekko.patch` scaffold for `f` using its exact lowered MoonBit
/// signature and an `abort("TODO")` body.
pub fn emit_function_scaffold(
  f: IrFunction,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let f = normalize_unnamed_params(f)
  let #(header, _, _, ctx2) = emit_function_header(f, ctx)
  let attr = case f.name == f.unmangled_name {
    True -> "#gekko.patch"
    False -> "#gekko.patch(\"" <> f.unmangled_name <> "\")"
  }
  #("///|\n" <> attr <> "\n" <> header <> " {\n  abort(\"TODO\")\n}", ctx2)
}

fn emit_function(f: IrFunction, ctx: EmitCtx) -> #(String, EmitCtx) {
  let f = case f.ffi {
    Some(_) -> normalize_unnamed_params(f)
    None -> f
  }
  let #(header, generics, ret_str, ctx2) = emit_function_header(f, ctx)

  let #(fn_block, ctx3) = case f.ffi {
    Some(PackageCall(pkg, target_fn)) -> {
      let #(ffi_alias, ctx_imp) = case pkg {
        "gprelude" -> #("gprelude", add_gprelude_import(ctx2))
        _ -> {
          let default_alias = mangle.module_to_alias(pkg)
          register_import(ctx2, pkg, default_alias, default_alias)
        }
      }
      let call_args =
        list.map(f.params, fn(p) { p.name })
        |> string.join(", ")
      let body =
        "  @" <> ffi_alias <> "." <> target_fn <> "(" <> call_args <> ")"
      #("///|\n" <> header <> " {\n" <> body <> "\n}", ctx_imp)
    }

    Some(Patched) -> {
      let #(sig_params_rev, _) =
        list.index_fold(f.params, #([], ctx2), fn(acc, p, idx) {
          let #(ps, c) = acc
          let #(ty_str, next_c) = emit_type(p.param_type, c)
          let p_name = "__p" <> int.to_string(idx)
          #([p_name <> " : " <> ty_str, ..ps], next_c)
        })
      let sig_args =
        list.index_map(f.params, fn(_, idx) { "__p" <> int.to_string(idx) })
        |> string.join(", ")
      let sig_header =
        "fn"
        <> generics
        <> " __gekko_sigcheck_"
        <> f.name
        <> "("
        <> string.join(list.reverse(sig_params_rev), ", ")
        <> ") -> "
        <> ret_str
      let body = "  " <> f.name <> "(" <> sig_args <> ")"
      #("///|\n" <> sig_header <> " {\n" <> body <> "\n}", ctx2)
    }

    Some(WasmImport(wasm_mod, imp_name)) -> {
      let stub_name = "__ffi_" <> f.name
      let #(stub_param_types, ctx_stub) =
        map_acc(f.params, ctx2, fn(p, c) { emit_type(p.param_type, c) })
      let stub_decl =
        "///|\nfn "
        <> stub_name
        <> "("
        <> string.join(stub_param_types, ", ")
        <> ") -> "
        <> ret_str
        <> " = \""
        <> wasm_mod
        <> "\" \""
        <> imp_name
        <> "\""
      let call_args =
        list.map(f.params, fn(p) { p.name })
        |> string.join(", ")
      let wrapper =
        "///|\n"
        <> header
        <> " {\n  "
        <> stub_name
        <> "("
        <> call_args
        <> ")\n}"
      #(stub_decl <> "\n\n" <> wrapper, ctx_stub)
    }

    Some(GleamPatch(src_mod, src_fn)) -> {
      let msg =
        escape_plain_string(
          "Unspliced Gleam patch " <> src_mod <> "." <> src_fn,
        )
      #(
        "///|\n" <> header <> " {\n  @prelude.abort(\"" <> msg <> "\")\n}",
        ctx2,
      )
    }

    None -> {
      let saved_locals = ctx2.local_vars
      let fn_locals =
        list.fold(f.params, saved_locals, fn(acc, p) {
          case p.name {
            "_" -> acc
            name -> set.insert(acc, name)
          }
        })
      let #(body_lines, ctx_body) =
        emit_stmts(f.body, "  ", EmitCtx(..ctx2, local_vars: fn_locals))
      let body_str = case body_lines {
        [] -> "  ()"
        lines -> string.join(lines, "\n")
      }
      #(
        "///|\n" <> header <> " {\n" <> body_str <> "\n}",
        EmitCtx(..ctx_body, local_vars: saved_locals),
      )
    }
  }

  let test_suffix = case
    f.params == [] && string.ends_with(f.unmangled_name, "_test")
  {
    True ->
      "\n\n///|\ntest \""
      <> escape_plain_string(f.unmangled_name)
      <> "\" {\n  @prelude.ignore("
      <> f.name
      <> "())\n}"
    False -> ""
  }

  #(fn_block <> test_suffix, ctx3)
}

fn emit_stmts(
  stmts: List(IrStmt),
  indent: String,
  ctx: EmitCtx,
) -> #(List(String), EmitCtx) {
  emit_stmts_loop(stmts, indent, ctx, [])
}

fn emit_stmts_loop(
  stmts: List(IrStmt),
  indent: String,
  ctx: EmitCtx,
  rev_acc: List(String),
) -> #(List(String), EmitCtx) {
  case stmts {
    [] -> #(list.reverse(rev_acc), ctx)
    [last] -> {
      let #(line, next_ctx) = emit_stmt(last, indent, True, ctx)
      #(list.reverse([line, ..rev_acc]), next_ctx)
    }
    [head, ..tail] -> {
      let #(line, next_ctx) = emit_stmt(head, indent, False, ctx)
      emit_stmts_loop(tail, indent, next_ctx, [line, ..rev_acc])
    }
  }
}

fn emit_stmt(
  stmt: IrStmt,
  indent: String,
  is_last: Bool,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case stmt {
    IrStmtLet(pattern:, annotation:, value:) -> {
      let #(val_str, ctx1) = emit_expr(value, ctx)
      let #(pat_str, ctx2) = emit_pattern(pattern, ctx1)
      let #(ann_str, ctx3) = case annotation {
        Some(ann) -> {
          let #(t_str, c) = emit_type(ann, ctx2)
          #(" : " <> t_str, c)
        }
        None -> #("", ctx2)
      }
      let next_locals =
        set.union(ctx3.local_vars, ir_util.pattern_bound_vars(pattern))
      let ctx_after = EmitCtx(..ctx3, local_vars: next_locals)
      case is_last {
        False ->
          case pattern_is_irrefutable(pattern) {
            True -> #(
              indent <> "let " <> pat_str <> ann_str <> " = " <> val_str,
              ctx_after,
            )
            False -> #(
              indent
                <> "guard "
                <> paren_if_compound(value, val_str)
                <> " is "
                <> pat_str
                <> " else { @prelude.abort(\"let pattern match failed\") }",
              ctx_after,
            )
          }
        True ->
          case pattern_is_irrefutable(pattern), pattern {
            True, IrPatVar(v) -> #(
              indent
                <> "let "
                <> v
                <> ann_str
                <> " = "
                <> val_str
                <> "\n"
                <> indent
                <> v,
              ctx_after,
            )
            True, IrPatDiscard | True, IrPatUnit -> #(
              indent <> val_str,
              ctx_after,
            )
            True, _ -> #(
              indent
                <> "let __gekko_let_val"
                <> ann_str
                <> " = "
                <> val_str
                <> "\n"
                <> indent
                <> "let "
                <> pat_str
                <> " = __gekko_let_val\n"
                <> indent
                <> "__gekko_let_val",
              ctx_after,
            )
            False, _ -> #(
              indent
                <> "let __gekko_let_val"
                <> ann_str
                <> " = "
                <> val_str
                <> "\n"
                <> indent
                <> "guard __gekko_let_val is "
                <> pat_str
                <> " else { @prelude.abort(\"let pattern match failed\") }\n"
                <> indent
                <> "__gekko_let_val",
              ctx_after,
            )
          }
      }
    }

    IrStmtGuard(
      value:,
      pattern:,
      guard_condition:,
      abort_message:,
      post_bindings:,
    ) -> {
      let #(val_str, ctx1) = emit_expr(value, ctx)
      let #(msg_str, ctx2) = case abort_message {
        Some(m) -> emit_expr(m, ctx1)
        None -> #("\"let assert failed\"", ctx1)
      }
      let ctx_pat =
        EmitCtx(
          ..ctx2,
          local_vars: set.union(
            ctx2.local_vars,
            ir_util.pattern_bound_vars(pattern),
          ),
        )
      let #(guard_line, ret_expr_opt, ctx3) = case
        is_last,
        pattern,
        guard_condition
      {
        _, IrPatVar(v), Some(cond) -> {
          let #(cond_str, c) = emit_expr_indented(cond, indent, ctx_pat)
          let line =
            indent
            <> "let "
            <> v
            <> " = "
            <> val_str
            <> "\n"
            <> indent
            <> "guard "
            <> paren_if_match(cond, cond_str)
            <> " else { @prelude.abort("
            <> msg_str
            <> ") }"
          #(line, Some(v), c)
        }
        _, IrPatVar(v), None -> #(
          indent <> "let " <> v <> " = " <> val_str,
          Some(v),
          ctx_pat,
        )
        False, IrPatDiscard, None -> #(
          indent <> "@prelude.ignore(" <> val_str <> ")",
          None,
          ctx_pat,
        )
        True, IrPatDiscard, None ->
          case post_bindings {
            [] -> #(indent <> val_str, None, ctx_pat)
            _ -> #(
              indent <> "let __gekko_assert_val = " <> val_str,
              Some("__gekko_assert_val"),
              ctx_pat,
            )
          }
        _, _, _ -> {
          let #(pat_str, c1) = emit_pattern(pattern, ctx_pat)
          let #(cond_suffix, c2) = case guard_condition {
            Some(cond) -> {
              let #(cond_str, c) = emit_expr_indented(cond, indent, c1)
              #(" && " <> paren_if_compound(cond, cond_str), c)
            }
            None -> #("", c1)
          }
          case is_last {
            False -> #(
              indent
                <> "guard "
                <> paren_if_compound(value, val_str)
                <> " is "
                <> pat_str
                <> cond_suffix
                <> " else { @prelude.abort("
                <> msg_str
                <> ") }",
              None,
              c2,
            )
            True -> #(
              indent
                <> "let __gekko_assert_val = "
                <> val_str
                <> "\n"
                <> indent
                <> "guard __gekko_assert_val is "
                <> pat_str
                <> cond_suffix
                <> " else { @prelude.abort("
                <> msg_str
                <> ") }",
              Some("__gekko_assert_val"),
              c2,
            )
          }
        }
      }

      let #(binding_lines, ctx4) =
        map_acc(post_bindings, ctx3, fn(binding, c) {
          let #(name, expr) = binding
          let #(expr_str, c_next) = emit_expr(expr, c)
          let c_with_var =
            EmitCtx(..c_next, local_vars: set.insert(c_next.local_vars, name))
          #(indent <> "let " <> name <> " = " <> expr_str, c_with_var)
        })

      let with_bindings = [guard_line, ..binding_lines]
      let all = case is_last, ret_expr_opt {
        True, Some(ret_name) -> list.append(with_bindings, [indent <> ret_name])
        _, _ -> with_bindings
      }
      #(string.join(all, "\n"), ctx4)
    }

    IrStmtAssert(condition:, abort_message:) -> {
      let #(cond_str, ctx1) = emit_expr(condition, ctx)
      let #(msg_str, ctx2) = case abort_message {
        Some(m) -> emit_expr(m, ctx1)
        None -> #("\"assertion failed\"", ctx1)
      }
      #(
        indent
          <> "if !("
          <> cond_str
          <> ") {\n"
          <> indent
          <> "  @prelude.abort("
          <> msg_str
          <> ")\n"
          <> indent
          <> "}",
        ctx2,
      )
    }

    IrStmtExpr(expr) -> {
      let #(expr_str, ctx1) = emit_expr_indented(expr, indent, ctx)
      case is_last || stmt_expr_is_control_flow(expr) {
        True -> #(indent <> expr_str, ctx1)
        False -> #(indent <> "@prelude.ignore(" <> expr_str <> ")", ctx1)
      }
    }
  }
}

fn stmt_expr_is_control_flow(expr: IrExpr) -> Bool {
  case expr {
    IrBreak(_) | IrContinue(_) | IrAbort(_, _) -> True
    _ -> False
  }
}

fn emit_expr(expr: IrExpr, ctx: EmitCtx) -> #(String, EmitCtx) {
  emit_expr_indented(expr, "", ctx)
}

fn emit_expr_indented(
  expr: IrExpr,
  indent: String,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case expr {
    IrInt(val) -> #(val <> "L", ctx)
    IrFloat(val) -> #(val, ctx)
    IrString(val) -> #("\"" <> escape_string_literal(val) <> "\"", ctx)
    IrBool(True) -> #("true", ctx)
    IrBool(False) -> #("false", ctx)
    IrUnit -> #("()", ctx)
    IrVar(name) ->
      case
        !set.contains(ctx.local_vars, name)
        && is_polymorphic_constant(ctx.current_module, name, ctx)
      {
        True -> #(name <> "()", ctx)
        False -> #(name, ctx)
      }

    IrModuleRef(module_alias:, target_module:, symbol:) -> {
      let #(alias, ctx1) = add_module_import(ctx, target_module, module_alias)
      case is_polymorphic_constant(target_module, symbol, ctx1) {
        True -> #("@" <> alias <> "." <> symbol <> "()", ctx1)
        False -> #("@" <> alias <> "." <> symbol, ctx1)
      }
    }

    IrConstructor(module_alias:, target_module:, name:) ->
      emit_constructor_value(module_alias, target_module, name, ctx)

    IrTuple(elements) ->
      case elements {
        [] -> #("@gprelude.Tuple0", add_gprelude_import(ctx))
        [el] -> {
          let #(el_str, ctx1) = emit_expr(el, add_gprelude_import(ctx))
          #("@gprelude.Tuple1(" <> el_str <> ")", ctx1)
        }
        _ -> {
          let #(el_strs, ctx1) = map_acc(elements, ctx, emit_expr)
          #("(" <> string.join(el_strs, ", ") <> ")", ctx1)
        }
      }

    IrTupleIndex(tuple:, index:) -> {
      let #(tuple_str, ctx1) = emit_expr(tuple, ctx)
      #(wrap_if_compound(tuple, tuple_str) <> "." <> int.to_string(index), ctx1)
    }

    IrList(elements:, tail:) -> emit_list_expr(elements, tail, ctx)

    IrBitString(segments:) -> emit_bit_string_expr(segments, ctx)

    IrNegateInt(inner) -> {
      let #(inner_str, ctx1) = emit_expr(inner, ctx)
      #("-(" <> inner_str <> ")", ctx1)
    }

    IrNegateBool(inner) -> {
      let #(inner_str, ctx1) = emit_expr(inner, ctx)
      #("!(" <> inner_str <> ")", ctx1)
    }

    IrBinOp(op:, left:, right:) -> emit_bin_op_expr(op, left, right, ctx)

    IrCall(function:, args:) -> emit_call_expr(function, args, ctx)

    IrGetterCall(receiver:, field:) -> {
      let #(recv_str, ctx1) = emit_expr(receiver, ctx)
      #(wrap_if_compound(receiver, recv_str) <> "." <> field <> "()", ctx1)
    }

    IrBlock(stmts) ->
      case stmts {
        [] -> #("()", ctx)
        _ -> {
          let saved_locals = ctx.local_vars
          let inner_indent = indent <> "  "
          let #(lines, ctx1) = emit_stmts(stmts, inner_indent, ctx)
          #(
            "{\n" <> string.join(lines, "\n") <> "\n" <> indent <> "}",
            EmitCtx(..ctx1, local_vars: saved_locals),
          )
        }
      }

    IrFn(params:, return_type:, body:) -> {
      let saved_locals = ctx.local_vars
      let inferred_param_types = infer_fn_param_types(params, body)
      let #(param_strs, ctx1) =
        map_acc(params, ctx, fn(p, c) {
          let effective_ty = case p.param_type {
            Some(pt) -> Some(pt)
            None -> dict.get(inferred_param_types, p.name) |> option.from_result
          }
          case effective_ty {
            Some(pt) -> {
              let #(t_str, c_next) = emit_type(pt, c)
              #(p.name <> " : " <> t_str, c_next)
            }
            None -> #(p.name, c)
          }
        })
      let #(ret_ann, ctx2) = case return_type {
        Some(rt) -> {
          let #(t_str, c_next) = emit_type(rt, ctx1)
          #(" -> " <> t_str, c_next)
        }
        None -> #("", ctx1)
      }
      let fn_locals =
        list.fold(params, saved_locals, fn(acc, p) {
          case p.name {
            "_" -> acc
            name -> set.insert(acc, name)
          }
        })
      let inner_indent = indent <> "  "
      let #(body_lines, ctx3) =
        emit_stmts(body, inner_indent, EmitCtx(..ctx2, local_vars: fn_locals))
      let body_str = case body_lines {
        [] -> inner_indent <> "()"
        lines -> string.join(lines, "\n")
      }
      #(
        "fn("
          <> string.join(param_strs, ", ")
          <> ")"
          <> ret_ann
          <> " {\n"
          <> body_str
          <> "\n"
          <> indent
          <> "}",
        EmitCtx(..ctx3, local_vars: saved_locals),
      )
    }

    IrMatch(subjects:, clauses:) ->
      emit_match_expr(subjects, clauses, indent, ctx)

    IrForLoop(bindings:, body:) -> {
      let saved_locals = ctx.local_vars
      let #(binding_strs, ctx1) =
        map_acc(bindings, ctx, fn(b, c) {
          let #(name, init_expr) = b
          let #(init_str, c_next) = emit_expr(init_expr, c)
          #(name <> " = " <> init_str, c_next)
        })
      let header = case binding_strs {
        [] -> "for ;; {"
        bs -> "for " <> string.join(bs, ", ") <> " {"
      }
      let loop_locals =
        list.fold(bindings, saved_locals, fn(acc, b) { set.insert(acc, b.0) })
      let inner_indent = indent <> "  "
      let #(body_lines, ctx2) =
        emit_stmts(body, inner_indent, EmitCtx(..ctx1, local_vars: loop_locals))
      #(
        header <> "\n" <> string.join(body_lines, "\n") <> "\n" <> indent <> "}",
        EmitCtx(..ctx2, local_vars: saved_locals),
      )
    }

    IrContinue(args) ->
      case args {
        [] -> #("continue", ctx)
        _ -> {
          let #(arg_strs, ctx1) = map_acc(args, ctx, emit_expr)
          #("continue " <> string.join(arg_strs, ", "), ctx1)
        }
      }

    IrBreak(val) -> {
      let #(val_str, ctx1) = emit_expr(val, ctx)
      #("break " <> val_str, ctx1)
    }

    IrAbort(kind:, message:) -> {
      let default_msg = case kind {
        LetAssertAbort -> "\"let assert failed\""
        AssertAbort -> "\"assertion failed\""
        PanicAbort -> "\"panic\""
        TodoAbort -> "\"not yet implemented\""
      }
      let #(msg_str, ctx1) = case message {
        Some(m) -> emit_expr(m, ctx)
        None -> #(default_msg, ctx)
      }
      #("@prelude.abort(" <> msg_str <> ")", ctx1)
    }

    IrEcho(expr: inner, message:, file_path:, line:) -> {
      let ctx1 = add_gprelude_import(ctx)
      let #(inner_str, ctx2) = emit_expr(inner, ctx1)
      let #(msg_str, ctx3) = case message {
        Some(m) -> emit_expr(m, ctx2)
        None -> #("\"\"", ctx2)
      }
      let loc_str =
        "\""
        <> escape_plain_string(file_path)
        <> ":"
        <> int.to_string(line)
        <> "\""
      #(
        "@gprelude.echo_val("
          <> inner_str
          <> ", "
          <> loc_str
          <> ", "
          <> msg_str
          <> ")",
        ctx3,
      )
    }
  }
}

fn emit_call_expr(
  function: IrExpr,
  args: List(IrCallArg),
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case function {
    IrConstructor(module_alias:, target_module:, name:) -> {
      let field_labels = lookup_ctor_field_labels(target_module, name, ctx)
      emit_aligned_call(
        args,
        field_labels,
        True,
        True,
        fn(c) {
          let #(prefix, c1) =
            emit_constructor_prefix(module_alias, target_module, name, c)
          #(prefix <> name, c1)
        },
        fn(arg, _idx, c) { emit_call_arg(arg, c) },
        ctx,
      )
    }

    IrModuleRef(module_alias:, target_module:, symbol:) -> {
      let callee_info = lookup_callee_with_bounds(target_module, symbol, ctx)
      let param_labels =
        lookup_fn_param_labels(Some(target_module), symbol, ctx)
      emit_aligned_call(
        args,
        param_labels,
        False,
        False,
        fn(c) {
          let #(alias, c1) = add_module_import(c, target_module, module_alias)
          let callee_call = case
            is_polymorphic_constant(target_module, symbol, c1)
          {
            True -> "@" <> alias <> "." <> symbol <> "()"
            False -> "@" <> alias <> "." <> symbol
          }
          #(callee_call, c1)
        },
        fn(arg, idx, c) {
          emit_call_arg_with_inspect_check(arg.value, idx, callee_info, c)
        },
        ctx,
      )
    }

    IrVar(fn_name) ->
      case set.contains(ctx.local_vars, fn_name) {
        True -> {
          let #(arg_strs, ctx1) =
            map_acc(args, ctx, fn(a, c) { emit_expr(a.value, c) })
          #(fn_name <> "(" <> string.join(arg_strs, ", ") <> ")", ctx1)
        }
        False -> {
          let callee_info =
            lookup_callee_with_bounds(ctx.current_module, fn_name, ctx)
          let param_labels = lookup_fn_param_labels(None, fn_name, ctx)
          emit_aligned_call(
            args,
            param_labels,
            False,
            False,
            fn(c) {
              let callee_call = case
                is_polymorphic_constant(c.current_module, fn_name, c)
              {
                True -> fn_name <> "()"
                False -> fn_name
              }
              #(callee_call, c)
            },
            fn(arg, idx, c) {
              emit_call_arg_with_inspect_check(arg.value, idx, callee_info, c)
            },
            ctx,
          )
        }
      }

    _ -> {
      let #(arg_strs, ctx1) =
        map_acc(args, ctx, fn(a, c) { emit_expr(a.value, c) })
      let args_joined = string.join(arg_strs, ", ")
      let #(fn_str, ctx2) = emit_expr(function, ctx1)
      #(wrap_if_compound(function, fn_str) <> "(" <> args_joined <> ")", ctx2)
    }
  }
}

fn emit_aligned_call(
  args: List(IrCallArg),
  target_labels: Option(List(Option(String))),
  keep_labels: Bool,
  omit_empty_parens: Bool,
  emit_callee: fn(EmitCtx) -> #(String, EmitCtx),
  emit_arg: fn(IrCallArg, Int, EmitCtx) -> #(String, EmitCtx),
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let #(aligned_indexed, order_changed) = case target_labels {
    Some(labels) -> align_call_args_tracked(args, labels, keep_labels)
    None -> #(list.index_map(args, fn(a, idx) { #(idx, a) }), False)
  }
  let needs_temps =
    order_changed
    && list.any(args, fn(a) { !ir_util.is_effect_free_expr(a.value) })
  case needs_temps {
    False -> {
      let #(arg_strs, ctx1) =
        map_index_acc(aligned_indexed, ctx, fn(pair, idx, c) {
          emit_arg(pair.1, idx, c)
        })
      let #(callee_str, ctx2) = emit_callee(ctx1)
      case omit_empty_parens && aligned_indexed == [] {
        True -> #(callee_str, ctx2)
        False -> #(
          callee_str <> "(" <> string.join(arg_strs, ", ") <> ")",
          ctx2,
        )
      }
    }
    True -> {
      let #(rev_lets, ctx1) =
        list.index_fold(args, #([], ctx), fn(acc, orig_arg, src_idx) {
          let #(lets, c) = acc
          case ir_util.is_effect_free_expr(orig_arg.value) {
            True -> #(lets, c)
            False -> {
              let #(val_str, c1) = emit_expr(orig_arg.value, c)
              let binding =
                "let __gekko_arg_" <> int.to_string(src_idx) <> " = " <> val_str
              #([binding, ..lets], c1)
            }
          }
        })
      let let_bindings = list.reverse(rev_lets)
      let #(arg_strs, ctx2) =
        map_index_acc(aligned_indexed, ctx1, fn(pair, idx, c) {
          let #(src_idx, aligned_arg) = pair
          case ir_util.is_effect_free_expr(aligned_arg.value) {
            True -> emit_arg(aligned_arg, idx, c)
            False -> {
              let temp_name = "__gekko_arg_" <> int.to_string(src_idx)
              let rendered = case keep_labels, aligned_arg.label {
                True, Some(lbl) -> lbl <> "=" <> temp_name
                _, _ -> temp_name
              }
              #(rendered, c)
            }
          }
        })
      let #(callee_str, ctx3) = emit_callee(ctx2)
      let call_str = callee_str <> "(" <> string.join(arg_strs, ", ") <> ")"
      #(
        "({ " <> string.join(let_bindings, "; ") <> "; " <> call_str <> " })",
        ctx3,
      )
    }
  }
}

fn emit_call_arg_with_inspect_check(
  val: IrExpr,
  idx: Int,
  callee_info: Option(#(IrFunction, trait_bounds.FnTraitBounds)),
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case callee_info {
    Some(#(callee_fn, callee_bounds)) ->
      case
        trait_bounds.param_is_pure_inspect_sink(callee_fn, idx, callee_bounds)
      {
        True -> emit_inspect_arg(val, ctx)
        False -> emit_expr(val, ctx)
      }
    None -> emit_expr(val, ctx)
  }
}

fn emit_inspect_arg(expr: IrExpr, ctx: EmitCtx) -> #(String, EmitCtx) {
  case expr {
    IrFn(params:, ..) -> {
      let ctx1 = add_gprelude_import(ctx)
      #(
        "@gprelude.inspect_fn(" <> int.to_string(list.length(params)) <> ")",
        ctx1,
      )
    }
    IrConstructor(target_module:, name:, ..) -> {
      let arity = case lookup_ctor_field_labels(target_module, name, ctx) {
        Some(labels) -> list.length(labels)
        None ->
          case name {
            "Ok" | "Err" | "Some" -> 1
            _ -> 0
          }
      }
      case arity > 0 {
        True -> {
          let ctx1 = add_gprelude_import(ctx)
          #("@gprelude.inspect_fn(" <> int.to_string(arity) <> ")", ctx1)
        }
        False -> emit_expr(expr, ctx)
      }
    }
    IrTuple(elements) ->
      case elements {
        [] -> #("@gprelude.Tuple0", add_gprelude_import(ctx))
        [el] -> {
          let #(el_str, ctx1) = emit_inspect_arg(el, add_gprelude_import(ctx))
          #("@gprelude.Tuple1(" <> el_str <> ")", ctx1)
        }
        _ -> {
          let #(el_strs, ctx1) = map_acc(elements, ctx, emit_inspect_arg)
          #("(" <> string.join(el_strs, ", ") <> ")", ctx1)
        }
      }
    IrList(elements:, tail:) -> {
      let ctx1 = add_gprelude_import(ctx)
      let #(tail_str, ctx2) = case tail {
        Some(t) -> emit_inspect_arg(t, ctx1)
        None -> #("@gprelude.Nil", ctx1)
      }
      let #(el_strs, ctx3) = map_acc(elements, ctx2, emit_inspect_arg)
      let expr_str =
        el_strs
        |> list.reverse
        |> list.fold(tail_str, fn(acc, el) {
          "@gprelude.Cons(" <> el <> ", " <> acc <> ")"
        })
      #(expr_str, ctx3)
    }
    _ -> emit_expr(expr, ctx)
  }
}

fn emit_call_arg(arg: IrCallArg, ctx: EmitCtx) -> #(String, EmitCtx) {
  let #(val_str, ctx1) = emit_expr(arg.value, ctx)
  let s = case arg.label {
    Some(lbl) -> lbl <> "=" <> val_str
    None -> val_str
  }
  #(s, ctx1)
}

fn emit_list_expr(
  elements: List(IrExpr),
  tail: Option(IrExpr),
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let ctx1 = add_gprelude_import(ctx)
  let #(tail_str, ctx2) = case tail {
    Some(t) -> emit_expr(t, ctx1)
    None -> #("@gprelude.Nil", ctx1)
  }
  let #(el_strs, ctx3) = map_acc(elements, ctx2, emit_expr)
  let expr_str =
    el_strs
    |> list.reverse
    |> list.fold(tail_str, fn(acc, el) {
      "@gprelude.Cons(" <> el <> ", " <> acc <> ")"
    })
  #(expr_str, ctx3)
}

fn emit_bit_string_expr(
  segments: List(#(IrExpr, List(glance.BitStringSegmentOption(IrExpr)))),
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let ctx1 = add_gprelude_import(ctx)
  case segments {
    [] -> #("@gprelude.BitArray::empty()", ctx1)
    _ -> {
      let #(seg_strs, ctx2) =
        map_acc(segments, ctx1, fn(seg, c) { emit_bit_segment(seg.0, seg.1, c) })
      #(
        "@gprelude.bit_array_from_segments(["
          <> string.join(seg_strs, ", ")
          <> "])",
        ctx2,
      )
    }
  }
}

fn emit_bit_segment(
  val: IrExpr,
  opts: List(glance.BitStringSegmentOption(IrExpr)),
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let #(val_str, ctx1) = emit_expr(val, ctx)
  let has_bytes = list.contains(opts, glance.BytesOption)
  let has_bits = list.contains(opts, glance.BitsOption)
  let has_utf8 = list.contains(opts, glance.Utf8Option)
  let has_utf16 = list.contains(opts, glance.Utf16Option)
  let has_utf32 = list.contains(opts, glance.Utf32Option)
  let has_utf8_cp = list.contains(opts, glance.Utf8CodepointOption)
  let has_utf16_cp = list.contains(opts, glance.Utf16CodepointOption)
  let has_utf32_cp = list.contains(opts, glance.Utf32CodepointOption)
  let has_float = list.contains(opts, glance.FloatOption)
  let has_int = list.contains(opts, glance.IntOption)
  let has_size =
    list.any(opts, fn(o) {
      case o {
        glance.SizeOption(_) | glance.SizeValueOption(_) -> True
        _ -> False
      }
    })
  let big_endian =
    !list.any(opts, fn(o) {
      case o {
        glance.LittleOption | glance.NativeOption -> True
        _ -> False
      }
    })
  let endian_str = case big_endian {
    True -> "true"
    False -> "false"
  }

  case
    has_bytes || has_bits,
    has_utf8_cp,
    has_utf16_cp,
    has_utf32_cp,
    has_utf8,
    has_utf16,
    has_utf32
  {
    True, _, _, _, _, _, _ ->
      case has_size {
        False -> #(val_str, ctx1)
        True -> {
          let default_unit = case has_bytes {
            True -> 8
            False -> 1
          }
          let #(bits_str, ctx2) =
            compute_segment_bits(opts, 1, default_unit, ctx1)
          #(
            "@gprelude.BitArray::bits_segment("
              <> val_str
              <> ", "
              <> bits_str
              <> ")",
            ctx2,
          )
        }
      }
    _, True, _, _, _, _, _ -> #(
      "@gprelude.BitArray::utf8_codepoint_segment(" <> val_str <> ")",
      ctx1,
    )
    _, _, True, _, _, _, _ -> #(
      "@gprelude.BitArray::utf16_codepoint_segment("
        <> val_str
        <> ", "
        <> endian_str
        <> ")",
      ctx1,
    )
    _, _, _, True, _, _, _ -> #(
      "@gprelude.BitArray::utf32_codepoint_segment("
        <> val_str
        <> ", "
        <> endian_str
        <> ")",
      ctx1,
    )
    _, _, _, _, True, _, _ -> #(
      "@gprelude.BitArray::from_string(" <> val_str <> ")",
      ctx1,
    )
    _, _, _, _, _, True, _ -> #(
      "@gprelude.BitArray::from_utf16(" <> val_str <> ", " <> endian_str <> ")",
      ctx1,
    )
    _, _, _, _, _, _, True -> #(
      "@gprelude.BitArray::from_utf32(" <> val_str <> ", " <> endian_str <> ")",
      ctx1,
    )
    _, _, _, _, _, _, _ ->
      case val {
        IrString(_) if !has_int && !has_float -> #(
          "@gprelude.BitArray::from_string(" <> val_str <> ")",
          ctx1,
        )
        IrFloat(_) if !has_int -> {
          let #(bits_str, ctx2) = compute_segment_bits(opts, 64, 1, ctx1)
          #(
            "@gprelude.BitArray::float_segment("
              <> val_str
              <> ", "
              <> bits_str
              <> ", "
              <> endian_str
              <> ")",
            ctx2,
          )
        }
        _ if has_float -> {
          let #(bits_str, ctx2) = compute_segment_bits(opts, 64, 1, ctx1)
          #(
            "@gprelude.BitArray::float_segment("
              <> val_str
              <> ", "
              <> bits_str
              <> ", "
              <> endian_str
              <> ")",
            ctx2,
          )
        }
        _ -> {
          let #(bits_str, ctx2) = compute_segment_bits(opts, 8, 1, ctx1)
          #(
            "@gprelude.BitArray::int_segment("
              <> val_str
              <> ", "
              <> bits_str
              <> ", "
              <> endian_str
              <> ")",
            ctx2,
          )
        }
      }
  }
}

fn compute_segment_bits(
  opts: List(glance.BitStringSegmentOption(IrExpr)),
  default_size: Int,
  default_unit: Int,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let unit =
    list.fold(opts, default_unit, fn(acc, o) {
      case o {
        glance.UnitOption(u) -> u
        _ -> acc
      }
    })
  let size_opt =
    list.find_map(opts, fn(o) {
      case o {
        glance.SizeOption(n) -> Ok(Ok(n))
        glance.SizeValueOption(expr) -> Ok(Error(expr))
        _ -> Error(Nil)
      }
    })
  case size_opt {
    Ok(Ok(n)) -> #(int.to_string(n * unit) <> "L", ctx)
    Ok(Error(expr)) -> {
      let #(e_str, ctx1) = emit_expr(expr, ctx)
      case unit {
        1 -> #(e_str, ctx1)
        u -> #("(" <> e_str <> " * " <> int.to_string(u) <> "L)", ctx1)
      }
    }
    Error(_) -> #(int.to_string(default_size * unit) <> "L", ctx)
  }
}

fn emit_bin_op_expr(
  op: IrBinOp,
  left: IrExpr,
  right: IrExpr,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case op {
    IrEq | IrNotEq ->
      case
        nullary_multi_variant_ctor(left, ctx),
        nullary_multi_variant_ctor(right, ctx)
      {
        None, Some(#(ctor, ctx_c)) ->
          emit_is_empty_op(op == IrEq, left, ctor, ctx_c)
        Some(#(ctor, ctx_c)), None ->
          emit_is_empty_op(op == IrEq, right, ctor, ctx_c)
        _, _ -> emit_regular_bin_op_expr(op, left, right, ctx)
      }
    _ -> emit_regular_bin_op_expr(op, left, right, ctx)
  }
}

fn nullary_multi_variant_ctor(
  expr: IrExpr,
  ctx: EmitCtx,
) -> Option(#(String, EmitCtx)) {
  case expr {
    IrList(elements: [], tail: None) ->
      Some(#("@gprelude.Nil", add_gprelude_import(ctx)))
    IrConstructor(module_alias:, target_module:, name:) ->
      case lookup_ctor_info(target_module, name, ctx) {
        Some(#(variant_count, [])) if variant_count >= 2 -> {
          let #(prefix, ctx1) =
            emit_constructor_prefix(module_alias, target_module, name, ctx)
          Some(#(prefix <> name, ctx1))
        }
        _ -> None
      }
    _ -> None
  }
}

fn emit_is_empty_op(
  is_eq: Bool,
  subject: IrExpr,
  ctor: String,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let #(subj_raw, ctx1) = emit_expr(subject, ctx)
  let base = "((" <> subj_raw <> ") is " <> ctor <> ")"
  case is_eq {
    True -> #(base, ctx1)
    False -> #("!(" <> base <> ")", ctx1)
  }
}

fn emit_regular_bin_op_expr(
  op: IrBinOp,
  left: IrExpr,
  right: IrExpr,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let #(l_raw, ctx1) = emit_expr(left, ctx)
  let #(r_raw, ctx2) = emit_expr(right, ctx1)
  let l_str = paren_if_compound(left, l_raw)
  let r_str = paren_if_compound(right, r_raw)

  case op {
    IrDivInt -> {
      let ctx3 = add_gprelude_import(ctx2)
      #("@gprelude.int_div(" <> l_str <> ", " <> r_str <> ")", ctx3)
    }
    IrRemInt -> {
      let ctx3 = add_gprelude_import(ctx2)
      #("@gprelude.int_rem(" <> l_str <> ", " <> r_str <> ")", ctx3)
    }
    IrDivFloat -> {
      let ctx3 = add_gprelude_import(ctx2)
      #("@gprelude.float_div(" <> l_str <> ", " <> r_str <> ")", ctx3)
    }
    _ -> {
      let sym = case op {
        IrAnd -> "&&"
        IrOr -> "||"
        IrEq -> "=="
        IrNotEq -> "!="
        IrLtInt | IrLtFloat -> "<"
        IrLtEqInt | IrLtEqFloat -> "<="
        IrGtInt | IrGtFloat -> ">"
        IrGtEqInt | IrGtEqFloat -> ">="
        IrAddInt | IrAddFloat | IrStringConcat -> "+"
        IrSubInt | IrSubFloat -> "-"
        IrMultInt | IrMultFloat -> "*"
        IrDivInt | IrRemInt | IrDivFloat -> ""
      }
      #("(" <> l_str <> " " <> sym <> " " <> r_str <> ")", ctx2)
    }
  }
}

/// A `match` used as an operand or as another match's subject must be
/// parenthesised for MoonBit to parse it.
fn paren_if_match(expr: IrExpr, emitted: String) -> String {
  case expr {
    IrMatch(_, _) -> "(" <> emitted <> ")"
    _ -> emitted
  }
}

fn paren_if_compound(expr: IrExpr, emitted: String) -> String {
  case expr {
    IrMatch(_, _) | IrBlock(_) -> "(" <> emitted <> ")"
    _ -> emitted
  }
}

fn emit_match_expr(
  subjects: List(IrExpr),
  clauses: List(IrClause),
  indent: String,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let #(subj_strs, ctx1) =
    map_acc(subjects, ctx, fn(s, c) {
      let #(str, c1) = emit_expr(s, c)
      #(paren_if_match(s, str), c1)
    })
  let is_multi = list.length(subjects) > 1
  let subj_header = case is_multi {
    True -> "(" <> string.join(subj_strs, ", ") <> ")"
    False -> string.join(subj_strs, ", ")
  }
  let arm_indent = indent <> "  "
  let #(arm_strs, ctx2) =
    map_acc(clauses, ctx1, fn(clause, c) {
      emit_clause(clause, is_multi, arm_indent, c)
    })
  #(
    "match "
      <> subj_header
      <> " {\n"
      <> string.join(arm_strs, "\n")
      <> "\n"
      <> indent
      <> "}",
    ctx2,
  )
}

fn emit_clause(
  clause: IrClause,
  is_multi: Bool,
  indent: String,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let saved_locals = ctx.local_vars
  let #(alt_strs, ctx1) =
    map_acc(clause.patterns, ctx, fn(alt, c) {
      let #(pat_strs, c_next) = map_acc(alt, c, emit_pattern)
      case is_multi {
        True -> #("(" <> string.join(pat_strs, ", ") <> ")", c_next)
        False -> #(string.join(pat_strs, ", "), c_next)
      }
    })
  let pat_part = string.join(alt_strs, " | ")

  let pat_locals =
    list.fold(clause.patterns, saved_locals, fn(acc, alt) {
      list.fold(alt, acc, fn(inner, p) {
        set.union(inner, ir_util.pattern_bound_vars(p))
      })
    })
  let ctx_guard = EmitCtx(..ctx1, local_vars: pat_locals)

  let #(guard_part, ctx2) = case clause.guard {
    Some(g) -> {
      let #(g_str, c_next) = emit_expr_indented(g, indent, ctx_guard)
      #(" if " <> paren_if_match(g, g_str), c_next)
    }
    None -> #("", ctx_guard)
  }

  let body_indent = indent <> "  "
  let #(body_str, ctx3) = case clause.prefix_bindings {
    [] -> emit_expr_indented(clause.body, indent, ctx2)
    bindings -> {
      let #(bind_lines, c_b) =
        map_acc(bindings, ctx2, fn(b, c) {
          let #(val_str, c_v) = emit_expr_indented(b.1, body_indent, c)
          let c_with_var =
            EmitCtx(..c_v, local_vars: set.insert(c_v.local_vars, b.0))
          #(body_indent <> "let " <> b.0 <> " = " <> val_str, c_with_var)
        })
      let #(b_str, c_end) = emit_expr_indented(clause.body, body_indent, c_b)
      let lines = list.append(bind_lines, [body_indent <> b_str])
      #("{\n" <> string.join(lines, "\n") <> "\n" <> indent <> "}", c_end)
    }
  }

  #(
    indent <> pat_part <> guard_part <> " => " <> body_str,
    EmitCtx(..ctx3, local_vars: saved_locals),
  )
}
