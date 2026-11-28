import emit/pkg_config
import emit/trait_bounds.{type ProjectTraitBounds}
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import index/symbol_table.{type SymbolTable}
import lower/ir.{
  type IrCallArg, type IrExpr, type IrFnParam, type IrFunction, type IrGetter,
  type IrModule, type IrParam, type IrPatArg, type IrPattern, type IrStmt,
  type IrType, type IrTypeAlias, type IrTypeDef, type IrVariant,
  type IrVariantField, IrAddFloat, IrAddInt, IrAnd, IrBinOp, IrBitString,
  IrBlock, IrBreak, IrCall, IrCallArg, IrContinue, IrDivFloat, IrDivInt, IrEcho,
  IrEq, IrFn, IrForLoop, IrGetterCall, IrGtEqFloat, IrGtEqInt, IrGtFloat,
  IrGtInt, IrList, IrLtEqFloat, IrLtEqInt, IrLtFloat, IrLtInt, IrMatch,
  IrMultFloat, IrMultInt, IrNegateBool, IrNegateInt, IrNotEq, IrOr, IrPatArg,
  IrPatAs, IrPatBitString, IrPatBool, IrPatDiscard, IrPatFloat, IrPatInt,
  IrPatString, IrPatTuple, IrPatUnit, IrPatVar, IrPatVariant, IrRemInt,
  IrStmtAssert, IrStmtExpr, IrStmtGuard, IrStmtLet, IrStringConcat, IrSubFloat,
  IrSubInt, IrTuple, IrTupleIndex, IrTypeBitArray, IrTypeBool, IrTypeDouble,
  IrTypeFn, IrTypeInt64, IrTypeList, IrTypeNamed, IrTypeResult, IrTypeString,
  IrTypeTuple, IrTypeUnit, IrTypeVar, IrVar,
}
import lower/ir_util
import lower/mangle
import moonbit/ffi_meta.{type FfiMetadata}
import project/interface.{
  type ResolvedType, FnType, NamedType, TupleType, VariableType,
}
import project/prepass.{type ExternalType, ExternalType}

pub type EmitCtx {
  EmitCtx(
    current_module: String,
    local_ctors: Dict(String, #(Int, List(Option(String)))),
    local_external_types: Dict(String, ExternalType),
    local_vars: Set(String),
    table: Option(SymbolTable),
    ffi_metadata: FfiMetadata,
    project_bounds: ProjectTraitBounds,
    module_pkg_dirs: Dict(String, String),
    pkg_to_alias: Dict(String, String),
    used_aliases: Set(String),
  )
}

fn resolve_pkg_dir(ctx: EmitCtx, target_module: String) -> String {
  case dict.get(ctx.module_pkg_dirs, target_module) {
    Ok(dir) -> dir
    Error(_) -> pkg_config.module_to_pkg_dir(target_module)
  }
}

pub fn add_gprelude_import(ctx: EmitCtx) -> EmitCtx {
  EmitCtx(
    ..ctx,
    pkg_to_alias: dict.insert(ctx.pkg_to_alias, "gprelude", "gprelude"),
  )
}

pub fn add_module_import(
  ctx: EmitCtx,
  target_module: String,
  alias_opt: Option(String),
) -> #(String, EmitCtx) {
  case target_module {
    "gprelude" -> #("gprelude", add_gprelude_import(ctx))
    _ -> {
      let pkg_dir = resolve_pkg_dir(ctx, target_module)
      let full_fallback = mangle.module_to_alias(target_module)
      let preferred = case alias_opt {
        Some(a) -> safe_alias(a)
        None -> full_fallback
      }
      register_import(ctx, pkg_dir, preferred, full_fallback)
    }
  }
}

pub fn register_import(
  ctx: EmitCtx,
  pkg_key: String,
  preferred: String,
  fallback: String,
) -> #(String, EmitCtx) {
  case dict.get(ctx.pkg_to_alias, pkg_key) {
    Ok(existing) -> #(existing, ctx)
    Error(_) -> {
      let chosen = case set.contains(ctx.used_aliases, preferred) {
        False -> preferred
        True ->
          case set.contains(ctx.used_aliases, fallback) {
            False -> fallback
            True -> pkg_config.pick_unique(fallback, "_", 2, ctx.used_aliases)
          }
      }
      #(
        chosen,
        EmitCtx(
          ..ctx,
          pkg_to_alias: dict.insert(ctx.pkg_to_alias, pkg_key, chosen),
          used_aliases: set.insert(ctx.used_aliases, chosen),
        ),
      )
    }
  }
}

fn safe_alias(alias: String) -> String {
  case alias {
    "prelude" -> "mod_prelude"
    _ -> mangle.mangle_ident(alias)
  }
}

pub fn emit_type_def(td: IrTypeDef, ctx: EmitCtx) -> #(String, EmitCtx) {
  let generics = format_type_params(td.type_params)
  case td.external_type {
    Some(ExternalType(package:, type_name:)) -> {
      let vis = visibility(td.publicity)
      let defined_in_patch =
        dict.has_key(ctx.ffi_metadata.types, #(ctx.current_module, td.name))
      case
        package == ""
        || package == "builtin"
        || package == "moonbitlang/core/builtin"
        || package == ctx.current_module
        || defined_in_patch,
        type_name == td.name
      {
        True, True -> #("", ctx)
        _, _ -> {
          let #(target_str, ctx1) = case package {
            "" | "builtin" | "moonbitlang/core/builtin" -> #(
              type_name <> generics,
              ctx,
            )
            "gprelude" -> #(
              "@gprelude." <> type_name <> generics,
              add_gprelude_import(ctx),
            )
            _ -> {
              let default_alias = mangle.module_to_alias(package)
              let #(ffi_alias, ctx_imp) =
                register_import(ctx, package, default_alias, default_alias)
              #("@" <> ffi_alias <> "." <> type_name <> generics, ctx_imp)
            }
          }
          #(
            "///|\n"
              <> vis
              <> "type "
              <> td.name
              <> generics
              <> " = "
              <> target_str,
            ctx1,
          )
        }
      }
    }

    None -> {
      let vis = case td.publicity, td.opaque_ {
        glance.Public, False -> "pub(all) "
        glance.Public, True -> "pub "
        glance.Private, _ -> "priv "
      }
      let dict_key_params = case
        dict.get(ctx.project_bounds.type_eq_hash_params, #(
          ctx.current_module,
          td.name,
        ))
      {
        Ok(indices) ->
          list.index_fold(td.type_params, set.new(), fn(acc, tp, idx) {
            case set.contains(indices, idx) {
              True -> set.insert(acc, tp)
              False -> acc
            }
          })
        Error(_) -> set.new()
      }
      let needs_manual_dict_eq =
        td.derive_eq_debug_hash
        && td.type_params != []
        && !set.is_empty(dict_key_params)
      let derive_line = case td.derive_eq_debug_hash, needs_manual_dict_eq {
        True, False -> "#derive(Eq, Debug, Hash)\n"
        True, True -> "#derive(Debug, Hash)\n"
        False, _ -> ""
      }
      let #(variant_lines, ctx1) = map_acc(td.variants, ctx, emit_variant)
      let body = case variant_lines {
        [] -> "{}"
        lines -> "{\n" <> string.join(lines, "\n") <> "\n}"
      }
      let enum_decl =
        "///|\n"
        <> derive_line
        <> vis
        <> "enum "
        <> td.name
        <> generics
        <> " "
        <> body
      let eq_block = case needs_manual_dict_eq {
        True -> "\n\n" <> emit_type_eq_impl(td, dict_key_params)
        False -> ""
      }
      let #(inspect_impl, ctx2) = emit_type_inspect_impl(td, ctx1)
      #(enum_decl <> eq_block <> "\n\n" <> inspect_impl, ctx2)
    }
  }
}

type FieldInspectKind {
  Inspectable
  UninspectableFn
  UninspectableExternal
}

fn classify_inspect_kind(ty: IrType, ctx: EmitCtx) -> FieldInspectKind {
  case ty {
    IrTypeFn(_, _) -> UninspectableFn
    IrTypeList(inner) -> classify_inspect_kind(inner, ctx)
    IrTypeResult(ok_t, err_t) ->
      case classify_inspect_kind(ok_t, ctx) {
        Inspectable -> classify_inspect_kind(err_t, ctx)
        other -> other
      }
    IrTypeTuple(els) -> classify_list_inspect_kind(els, ctx)
    IrTypeNamed(module:, name:, args:, ..) ->
      case is_external_named_type(module, name, ctx) {
        True -> UninspectableExternal
        False -> classify_list_inspect_kind(args, ctx)
      }
    _ -> Inspectable
  }
}

fn classify_list_inspect_kind(
  types: List(IrType),
  ctx: EmitCtx,
) -> FieldInspectKind {
  case types {
    [] -> Inspectable
    [head, ..tail] ->
      case classify_inspect_kind(head, ctx) {
        Inspectable -> classify_list_inspect_kind(tail, ctx)
        other -> other
      }
  }
}

fn is_external_named_type(module: String, name: String, ctx: EmitCtx) -> Bool {
  case module {
    "gleam" -> False
    _ ->
      case lookup_external_type(module, name, ctx) {
        None -> False
        Some(ext) ->
          !ffi_meta.is_inspectable(ctx.ffi_metadata, ext.package, ext.type_name)
      }
  }
}

fn lookup_external_type(
  module: String,
  name: String,
  ctx: EmitCtx,
) -> Option(ExternalType) {
  let resolved_mod = case module {
    "" -> ctx.current_module
    m -> m
  }
  case resolved_mod == ctx.current_module {
    True ->
      case dict.get(ctx.local_external_types, name) {
        Ok(ext) -> Some(ext)
        Error(_) -> lookup_external_type_in_table(resolved_mod, name, ctx.table)
      }
    False -> lookup_external_type_in_table(resolved_mod, name, ctx.table)
  }
}

fn lookup_external_type_in_table(
  module: String,
  name: String,
  table: Option(SymbolTable),
) -> Option(ExternalType) {
  case table {
    None -> None
    Some(tbl) ->
      case dict.get(tbl.modules, module) {
        Error(_) -> None
        Ok(ms) ->
          case dict.get(ms.types, name) {
            Ok(ti) -> ti.external_type
            Error(_) ->
              dict.values(ms.types)
              |> list.find(fn(ti) { mangle.mangle_type_name(ti.name) == name })
              |> option.from_result
              |> option.then(fn(ti) { ti.external_type })
          }
      }
  }
}

fn emit_type_inspect_impl(td: IrTypeDef, ctx: EmitCtx) -> #(String, EmitCtx) {
  let ctx1 = add_gprelude_import(ctx)
  let impl_vis = visibility(td.publicity)
  let inspectable_vars =
    list.fold(td.variants, set.new(), fn(acc, v) {
      list.fold(v.fields, acc, fn(inner, f) {
        case classify_inspect_kind(f.field_type, ctx) {
          Inspectable -> collect_non_fn_type_vars(f.field_type, ctx, inner)
          _ -> inner
        }
      })
    })
  let impl_generics = case td.type_params {
    [] -> ""
    tps ->
      "["
      <> {
        list.map(tps, fn(tp) {
          case set.contains(inspectable_vars, tp) {
            True -> tp <> " : @gprelude.GleamInspect"
            False -> tp
          }
        })
        |> string.join(", ")
      }
      <> "]"
  }
  let self_ty = td.name <> format_type_params(td.type_params)
  let body = case td.variants {
    [] -> "  @prelude.ignore(self)\n  \"\""
    variants -> {
      let arms =
        list.map(variants, fn(v) {
          case v.fields {
            [] -> "    " <> v.name <> " => \"" <> v.name <> "\""
            fields -> {
              let #(pat_parts, expr_parts) =
                list.index_fold(fields, #([], []), fn(acc, f, idx) {
                  let #(pats, exprs) = acc
                  let inspect_kind = classify_inspect_kind(f.field_type, ctx)
                  let bind_name = case inspect_kind {
                    Inspectable -> "f" <> int.to_string(idx)
                    _ -> "_"
                  }
                  let pat_part = case f.label {
                    Some(lbl) -> lbl <> "=" <> bind_name
                    None -> bind_name
                  }
                  let expr_part = case inspect_kind {
                    Inspectable ->
                      "@gprelude.GleamInspect::gleam_inspect("
                      <> bind_name
                      <> ")"
                    UninspectableFn -> "\"\\\"//fn(...) { ... }\\\"\""
                    UninspectableExternal -> "\"\\\"//external\\\"\""
                  }
                  #([pat_part, ..pats], [expr_part, ..exprs])
                })
              let pat_str =
                list.reverse(pat_parts)
                |> string.join(", ")
              let joined_fields =
                list.reverse(expr_parts)
                |> string.join(" + \", \" + ")
              "    "
              <> v.name
              <> "("
              <> pat_str
              <> ") => \""
              <> v.name
              <> "(\" + "
              <> joined_fields
              <> " + \")\""
            }
          }
        })
        |> string.join("\n")
      "  match self {\n" <> arms <> "\n  }"
    }
  }
  let code =
    "///|\n"
    <> impl_vis
    <> "impl"
    <> impl_generics
    <> " @gprelude.GleamInspect for "
    <> self_ty
    <> " with gleam_inspect(self) {\n"
    <> body
    <> "\n}"
  #(code, ctx1)
}

fn collect_non_fn_type_vars(
  ty: IrType,
  ctx: EmitCtx,
  acc: Set(String),
) -> Set(String) {
  case classify_inspect_kind(ty, ctx) {
    UninspectableFn | UninspectableExternal -> acc
    Inspectable ->
      case ty {
        IrTypeVar(v) -> set.insert(acc, v)
        IrTypeList(inner) -> collect_non_fn_type_vars(inner, ctx, acc)
        IrTypeResult(ok_t, err_t) ->
          collect_non_fn_type_vars(
            err_t,
            ctx,
            collect_non_fn_type_vars(ok_t, ctx, acc),
          )
        IrTypeTuple(els) ->
          list.fold(els, acc, fn(s, e) { collect_non_fn_type_vars(e, ctx, s) })
        IrTypeNamed(args:, ..) ->
          list.fold(args, acc, fn(s, a) { collect_non_fn_type_vars(a, ctx, s) })
        _ -> acc
      }
  }
}

fn emit_variant(v: IrVariant, ctx: EmitCtx) -> #(String, EmitCtx) {
  case v.fields {
    [] -> #("  " <> v.name, ctx)
    fields -> {
      let #(field_strs, ctx1) = map_acc(fields, ctx, emit_variant_field)
      #("  " <> v.name <> "(" <> string.join(field_strs, ", ") <> ")", ctx1)
    }
  }
}

fn emit_variant_field(f: IrVariantField, ctx: EmitCtx) -> #(String, EmitCtx) {
  let #(ty_str, ctx1) = emit_type(f.field_type, ctx)
  let s = case f.label {
    Some(lbl) -> lbl <> "~ : " <> ty_str
    None -> ty_str
  }
  #(s, ctx1)
}

pub fn emit_type_alias(ta: IrTypeAlias, ctx: EmitCtx) -> #(String, EmitCtx) {
  let vis = visibility(ta.publicity)
  let generics = format_type_params(ta.type_params)
  let #(aliased_str, ctx1) = emit_type(ta.aliased, ctx)
  #(
    "///|\n" <> vis <> "type " <> ta.name <> generics <> " = " <> aliased_str,
    ctx1,
  )
}

pub fn emit_getter(g: IrGetter, ctx: EmitCtx) -> #(String, EmitCtx) {
  let vis = visibility(g.publicity)
  let generics = format_type_params(g.type_params)
  let self_ty = g.type_name <> generics
  let #(ret_str, ctx1) = emit_type(g.return_type, ctx)
  let arms =
    list.map(g.variants, fn(v) {
      let #(v_name, positional) = v
      let placeholders = list.repeat("_", positional)
      let pat_args =
        list.append(placeholders, [g.field_name <> "~", ".."])
        |> string.join(", ")
      "    " <> v_name <> "(" <> pat_args <> ") => " <> g.field_name
    })
    |> string.join("\n")
  let code =
    "///|\n"
    <> vis
    <> "fn"
    <> generics
    <> " "
    <> g.type_name
    <> "::"
    <> g.field_name
    <> "(self : "
    <> self_ty
    <> ") -> "
    <> ret_str
    <> " {\n"
    <> "  match self {\n"
    <> arms
    <> "\n  }\n}"
  #(code, ctx1)
}

pub fn is_polymorphic_constant(
  target_module: String,
  mangled_name: String,
  ctx: EmitCtx,
) -> Bool {
  case dict.get(ctx.project_bounds.all_consts, #(target_module, mangled_name)) {
    Ok(ty) -> ir_util.collect_type_vars_in_type(ty) != []
    Error(_) ->
      case ctx.table {
        None -> False
        Some(tbl) ->
          case dict.get(tbl.modules, target_module) {
            Error(_) -> False
            Ok(ms) -> {
              let found = case dict.get(ms.constants, mangled_name) {
                Ok(ci) -> Ok(ci)
                Error(_) ->
                  dict.values(ms.constants)
                  |> list.find(fn(ci) {
                    mangle.mangle_ident(ci.name) == mangled_name
                  })
              }
              case found {
                Ok(ci) ->
                  case ci.resolved_type {
                    Some(rt) -> resolved_type_has_var(rt)
                    None -> False
                  }
                Error(_) -> False
              }
            }
          }
      }
  }
}

fn resolved_type_has_var(rt: ResolvedType) -> Bool {
  case rt {
    VariableType(_) -> True
    NamedType(parameters:, ..) -> list.any(parameters, resolved_type_has_var)
    TupleType(elements:) -> list.any(elements, resolved_type_has_var)
    FnType(parameters:, return:) ->
      list.any(parameters, resolved_type_has_var)
      || resolved_type_has_var(return)
  }
}

pub fn emit_fn_param(p: IrParam, ctx: EmitCtx) -> #(String, EmitCtx) {
  let #(ty_str, ctx1) = emit_type(p.param_type, ctx)
  #(p.name <> " : " <> ty_str, ctx1)
}

pub fn emit_constructor_prefix(
  module_alias: Option(String),
  target_module: Option(String),
  ctor_name: String,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case target_module {
    Some(tm) ->
      case is_builtin_external_ctor(tm, ctor_name, ctx) {
        True -> #("", ctx)
        False ->
          case tm != ctx.current_module {
            True -> {
              let #(alias, ctx1) = add_module_import(ctx, tm, module_alias)
              #("@" <> alias <> ".", ctx1)
            }
            False ->
              case module_alias {
                Some("gprelude") -> #("@gprelude.", add_gprelude_import(ctx))
                _ -> #("", ctx)
              }
          }
      }
    None ->
      case module_alias {
        Some("gprelude") -> #("@gprelude.", add_gprelude_import(ctx))
        _ -> #("", ctx)
      }
  }
}

fn is_builtin_external_ctor(
  target_module: String,
  ctor_name: String,
  ctx: EmitCtx,
) -> Bool {
  case ctx.table {
    None -> False
    Some(tbl) ->
      case dict.get(tbl.modules, target_module) {
        Error(_) -> False
        Ok(ms) ->
          case dict.get(ms.constructors, ctor_name) {
            Error(_) -> False
            Ok(ctor) ->
              case dict.get(ms.types, ctor.type_name) {
                Ok(ti) ->
                  case ti.external_type {
                    Some(ExternalType(package: pkg, ..)) ->
                      pkg == "" || pkg == "builtin"
                    _ -> False
                  }
                Error(_) -> False
              }
          }
      }
  }
}

pub fn emit_constructor_value(
  module_alias: Option(String),
  target_module: Option(String),
  name: String,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let #(prefix, ctx1) =
    emit_constructor_prefix(module_alias, target_module, name, ctx)
  let qualified = prefix <> name
  // MoonBit forbids using multi-arg constructors directly as first-class function values
  let field_labels = lookup_ctor_field_labels(target_module, name, ctx1)
  case field_labels {
    Some([]) -> #(qualified, ctx1)
    Some(labels) -> {
      let params =
        list.index_map(labels, fn(_, idx) { "__c_" <> int.to_string(idx) })
      let call_args =
        list.index_map(labels, fn(lbl_opt, idx) {
          let arg_var = "__c_" <> int.to_string(idx)
          case lbl_opt {
            Some(lbl) -> mangle.mangle_ident(lbl) <> "=" <> arg_var
            None -> arg_var
          }
        })
      #(
        "fn("
          <> string.join(params, ", ")
          <> ") { "
          <> qualified
          <> "("
          <> string.join(call_args, ", ")
          <> ") }",
        ctx1,
      )
    }
    None ->
      case name {
        "Ok" | "Err" | "Some" -> #(
          "fn(__c_0) { " <> qualified <> "(__c_0) }",
          ctx1,
        )
        _ -> #(qualified, ctx1)
      }
  }
}

pub fn lookup_ctor_info(
  target_module: Option(String),
  ctor_name: String,
  ctx: EmitCtx,
) -> Option(#(Int, List(Option(String)))) {
  case target_module, ctx.table {
    Some(tm), Some(tbl) ->
      case dict.get(tbl.modules, tm) {
        Ok(ms) ->
          case dict.get(ms.constructors, ctor_name) {
            Ok(ctor) -> {
              let variant_count = case dict.get(ms.types, ctor.type_name) {
                Ok(ti) -> list.length(ti.variants)
                Error(_) -> 1
              }
              Some(#(variant_count, list.map(ctor.fields, fn(f) { f.label })))
            }
            Error(_) -> None
          }
        Error(_) -> None
      }
    None, _ ->
      case dict.get(ctx.local_ctors, ctor_name) {
        Ok(info) -> Some(info)
        Error(_) -> None
      }
    Some(tm), None if tm == ctx.current_module ->
      case dict.get(ctx.local_ctors, ctor_name) {
        Ok(info) -> Some(info)
        Error(_) -> None
      }
    _, _ -> None
  }
}

pub fn lookup_ctor_field_labels(
  target_module: Option(String),
  ctor_name: String,
  ctx: EmitCtx,
) -> Option(List(Option(String))) {
  option.map(lookup_ctor_info(target_module, ctor_name, ctx), fn(p) { p.1 })
}

pub fn lookup_callee_with_bounds(
  target_module: String,
  fn_name: String,
  ctx: EmitCtx,
) -> Option(#(IrFunction, trait_bounds.FnTraitBounds)) {
  case dict.get(ctx.project_bounds.all_fns, #(target_module, fn_name)) {
    Ok(callee_fn) -> {
      let callee_bounds =
        trait_bounds.lookup_fn_bounds(
          ctx.project_bounds,
          target_module,
          fn_name,
        )
      Some(#(callee_fn, callee_bounds))
    }
    Error(_) -> None
  }
}

pub fn lookup_fn_param_labels(
  target_module: Option(String),
  fn_name: String,
  ctx: EmitCtx,
) -> Option(List(Option(String))) {
  let mod_name = option.unwrap(target_module, ctx.current_module)
  let from_table = case ctx.table {
    Some(tbl) ->
      case dict.get(tbl.modules, mod_name) {
        Ok(ms) ->
          case dict.get(ms.mangled_functions, fn_name) {
            Ok(fi) ->
              Some(
                list.map(fi.parameters, fn(p) {
                  option.map(p.label, mangle.mangle_ident)
                }),
              )
            Error(_) -> None
          }
        Error(_) -> None
      }
    None -> None
  }
  case from_table {
    Some(_) -> from_table
    None ->
      case dict.get(ctx.project_bounds.all_fns, #(mod_name, fn_name)) {
        Ok(f) -> Some(list.map(f.params, fn(p) { p.label }))
        Error(_) -> None
      }
  }
}

pub fn align_call_args_tracked(
  args: List(IrCallArg),
  target_labels: List(Option(String)),
  keep_labels: Bool,
) -> #(List(#(Int, IrCallArg)), Bool) {
  let indexed = list.index_map(args, fn(a, idx) { #(idx, a) })
  let has_labels = list.any(args, fn(a) { option.is_some(a.label) })
  case list.length(args) == list.length(target_labels) {
    False ->
      case keep_labels {
        True -> #(indexed, False)
        False -> #(
          list.map(indexed, fn(pair) {
            #(pair.0, IrCallArg(None, pair.1.value))
          }),
          False,
        )
      }
    True ->
      case !has_labels && !keep_labels {
        True -> #(indexed, False)
        False -> {
          let #(labeled_map, rev_positional) =
            list.fold(indexed, #(dict.new(), []), fn(acc, pair) {
              let #(lmap, pos) = acc
              let #(src_idx, arg) = pair
              case arg.label {
                Some(lbl) -> #(
                  dict.insert(lmap, lbl, #(src_idx, arg.value)),
                  pos,
                )
                None -> #(lmap, [#(src_idx, arg.value), ..pos])
              }
            })
          let #(rev_out, _) =
            list.fold(
              target_labels,
              #([], list.reverse(rev_positional)),
              fn(acc, lbl_opt) {
                let #(out, pos_q) = acc
                let out_lbl = case keep_labels {
                  True -> lbl_opt
                  False -> None
                }
                case lbl_opt {
                  Some(lbl) ->
                    case dict.get(labeled_map, lbl) {
                      Ok(#(src_idx, v)) -> #(
                        [#(src_idx, IrCallArg(out_lbl, v)), ..out],
                        pos_q,
                      )
                      Error(_) ->
                        case pos_q {
                          [#(src_idx, v), ..rest_pos] -> #(
                            [#(src_idx, IrCallArg(out_lbl, v)), ..out],
                            rest_pos,
                          )
                          [] -> #(out, pos_q)
                        }
                    }
                  None ->
                    case pos_q {
                      [#(src_idx, v), ..rest_pos] -> #(
                        [#(src_idx, IrCallArg(out_lbl, v)), ..out],
                        rest_pos,
                      )
                      [] -> #(out, pos_q)
                    }
                }
              },
            )
          let aligned = list.reverse(rev_out)
          let order_changed =
            list.index_fold(aligned, False, fn(acc, pair, idx) {
              acc || pair.0 != idx
            })
          #(aligned, order_changed)
        }
      }
  }
}

pub fn emit_pattern(pat: IrPattern, ctx: EmitCtx) -> #(String, EmitCtx) {
  case pat {
    IrPatInt(val) -> #(val <> "L", ctx)
    IrPatFloat(val) -> #(val, ctx)
    IrPatString(val) -> #("\"" <> escape_string_literal(val) <> "\"", ctx)
    IrPatBool(True) -> #("true", ctx)
    IrPatBool(False) -> #("false", ctx)
    IrPatUnit -> #("_", ctx)
    IrPatDiscard -> #("_", ctx)
    IrPatVar(name) -> #(name, ctx)

    IrPatTuple(els) ->
      case els {
        [] -> #("@gprelude.Tuple0", add_gprelude_import(ctx))
        [el] -> {
          let #(el_str, ctx1) = emit_pattern(el, add_gprelude_import(ctx))
          #("@gprelude.Tuple1(" <> el_str <> ")", ctx1)
        }
        _ -> {
          let #(el_strs, ctx1) = map_acc(els, ctx, emit_pattern)
          #("(" <> string.join(el_strs, ", ") <> ")", ctx1)
        }
      }

    IrPatAs(inner, alias) -> {
      let #(inner_str, ctx1) = emit_pattern(inner, ctx)
      #(inner_str <> " as " <> alias, ctx1)
    }

    IrPatVariant(
      module_alias:,
      target_module:,
      constructor:,
      args:,
      with_spread:,
    ) -> {
      let #(prefix, ctx1) =
        emit_constructor_prefix(module_alias, target_module, constructor, ctx)
      let normalized_args = case
        lookup_ctor_field_labels(target_module, constructor, ctx1)
      {
        Some(field_labels) -> align_pat_args(args, field_labels)
        None -> args
      }
      let #(arg_strs, ctx2) = map_acc(normalized_args, ctx1, emit_pat_arg)
      let all_args = case with_spread {
        True -> list.append(arg_strs, [".."])
        False -> arg_strs
      }
      case all_args {
        [] -> #(prefix <> constructor, ctx2)
        _ -> #(
          prefix <> constructor <> "(" <> string.join(all_args, ", ") <> ")",
          ctx2,
        )
      }
    }

    IrPatBitString(segments:) -> {
      let ctx1 = add_gprelude_import(ctx)
      case segments {
        [] -> #("{ bit_length: 0L, .. }", ctx1)
        _ -> #("_", ctx1)
      }
    }
  }
}

fn emit_pat_arg(arg: IrPatArg, ctx: EmitCtx) -> #(String, EmitCtx) {
  let #(pat_str, ctx1) = emit_pattern(arg.pattern, ctx)
  let s = case arg.label {
    Some(lbl) ->
      case arg.pattern {
        IrPatVar(v) if v == lbl -> lbl <> "~"
        _ -> lbl <> "=" <> pat_str
      }
    None -> pat_str
  }
  #(s, ctx1)
}

pub fn emit_type(ty: IrType, ctx: EmitCtx) -> #(String, EmitCtx) {
  case ty {
    IrTypeInt64 -> #("Int64", ctx)
    IrTypeDouble -> #("Double", ctx)
    IrTypeString -> #("StringView", ctx)
    IrTypeBool -> #("Bool", ctx)
    IrTypeUnit -> #("Unit", ctx)
    IrTypeBitArray -> #("@gprelude.BitArray", add_gprelude_import(ctx))
    IrTypeList(inner) -> {
      let ctx1 = add_gprelude_import(ctx)
      let #(inner_str, ctx2) = emit_type(inner, ctx1)
      #("@gprelude.GList[" <> inner_str <> "]", ctx2)
    }
    IrTypeResult(ok_t, err_t) -> {
      let #(ok_str, ctx1) = emit_type(ok_t, ctx)
      let #(err_str, ctx2) = emit_type(err_t, ctx1)
      #("Result[" <> ok_str <> ", " <> err_str <> "]", ctx2)
    }
    IrTypeTuple(els) ->
      case els {
        [] -> #("@gprelude.Tuple0", add_gprelude_import(ctx))
        [el] -> {
          let #(el_str, ctx1) = emit_type(el, add_gprelude_import(ctx))
          #("@gprelude.Tuple1[" <> el_str <> "]", ctx1)
        }
        _ -> {
          let #(el_strs, ctx1) = map_acc(els, ctx, emit_type)
          #("(" <> string.join(el_strs, ", ") <> ")", ctx1)
        }
      }
    IrTypeFn(params, ret) -> {
      let #(param_strs, ctx1) = map_acc(params, ctx, emit_type)
      let #(ret_str, ctx2) = emit_type(ret, ctx1)
      #("(" <> string.join(param_strs, ", ") <> ") -> " <> ret_str, ctx2)
    }
    IrTypeVar(name) -> #(name, ctx)
    IrTypeNamed(module_alias:, package: _, module:, name:, args:) ->
      case module, name {
        "gleam", "Dynamic" -> #("@gprelude.Dynamic", add_gprelude_import(ctx))
        "gleam", "UtfCodepoint" -> #("Char", ctx)
        _, _ ->
          case lookup_external_type(module, name, ctx) {
            Some(ExternalType(package: pkg, type_name: target))
              if pkg == ""
              || pkg == "builtin"
              || pkg == "moonbitlang/core/builtin"
            -> {
              let #(arg_strs, ctx1) = map_acc(args, ctx, emit_type)
              let suffix = case arg_strs {
                [] -> ""
                _ -> "[" <> string.join(arg_strs, ", ") <> "]"
              }
              #(target <> suffix, ctx1)
            }
            Some(ExternalType(package: "gprelude", type_name: target)) -> {
              let ctx0 = add_gprelude_import(ctx)
              let #(arg_strs, ctx1) = map_acc(args, ctx0, emit_type)
              let suffix = case arg_strs {
                [] -> ""
                _ -> "[" <> string.join(arg_strs, ", ") <> "]"
              }
              #("@gprelude." <> target <> suffix, ctx1)
            }
            Some(ExternalType(package: pkg, type_name: target))
              if module != ctx.current_module && pkg != module
            ->
              case string.contains(pkg, "/") {
                True -> {
                  let #(arg_strs, ctx1) = map_acc(args, ctx, emit_type)
                  let default_alias = mangle.module_to_alias(pkg)
                  let #(ffi_alias, ctx2) =
                    register_import(ctx1, pkg, default_alias, default_alias)
                  let suffix = case arg_strs {
                    [] -> ""
                    _ -> "[" <> string.join(arg_strs, ", ") <> "]"
                  }
                  #("@" <> ffi_alias <> "." <> target <> suffix, ctx2)
                }
                False -> {
                  let #(arg_strs, ctx1) = map_acc(args, ctx, emit_type)
                  let #(prefix, ctx2) = {
                    let #(alias, c) =
                      add_module_import(ctx1, module, module_alias)
                    #("@" <> alias <> ".", c)
                  }
                  let suffix = case arg_strs {
                    [] -> ""
                    _ -> "[" <> string.join(arg_strs, ", ") <> "]"
                  }
                  #(prefix <> name <> suffix, ctx2)
                }
              }
            _ -> {
              let #(arg_strs, ctx1) = map_acc(args, ctx, emit_type)
              let #(prefix, ctx2) = case module == ctx1.current_module {
                True -> #("", ctx1)
                False -> {
                  let #(alias, c) =
                    add_module_import(ctx1, module, module_alias)
                  #("@" <> alias <> ".", c)
                }
              }
              let suffix = case arg_strs {
                [] -> ""
                _ -> "[" <> string.join(arg_strs, ", ") <> "]"
              }
              #(prefix <> name <> suffix, ctx2)
            }
          }
      }
  }
}

pub fn pattern_is_irrefutable(pat: IrPattern) -> Bool {
  case pat {
    IrPatVar(_) | IrPatDiscard | IrPatUnit -> True
    IrPatTuple(els) -> list.all(els, pattern_is_irrefutable)
    IrPatAs(inner, _) -> pattern_is_irrefutable(inner)
    IrPatInt(_)
    | IrPatFloat(_)
    | IrPatString(_)
    | IrPatBool(_)
    | IrPatVariant(_, _, _, _, _)
    | IrPatBitString(_) -> False
  }
}

pub fn wrap_if_compound(expr: IrExpr, rendered: String) -> String {
  case expr {
    IrFn(_, _, _) | IrBlock(_) | IrMatch(_, _) | IrForLoop(_, _) ->
      "(" <> rendered <> ")"
    _ -> rendered
  }
}

pub fn format_type_params(params: List(String)) -> String {
  case params {
    [] -> ""
    _ -> "[" <> string.join(params, ", ") <> "]"
  }
}

pub fn format_function_type_params(
  f: IrFunction,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case f.type_params {
    [] -> #("", ctx)
    tps -> {
      let fn_bounds =
        trait_bounds.lookup_fn_bounds(
          ctx.project_bounds,
          ctx.current_module,
          f.name,
        )
      let #(rev_formatted, final_ctx) =
        list.fold(tps, #([], ctx), fn(acc, tp) {
          let #(parts, cur_ctx) = acc
          let has_eq = set.contains(fn_bounds.eq_vars, tp)
          let has_inspect = set.contains(fn_bounds.inspect_vars, tp)
          let has_to_dyn = set.contains(fn_bounds.to_dynamic_vars, tp)
          let has_show = set.contains(fn_bounds.show_vars, tp)
          let traits =
            []
            |> fn(ts) {
              case has_show {
                True -> ["Show", ..ts]
                False -> ts
              }
            }
            |> fn(ts) {
              case has_to_dyn {
                True -> ["@gprelude.ToDynamic", ..ts]
                False -> ts
              }
            }
            |> fn(ts) {
              case has_inspect {
                True -> ["@gprelude.GleamInspect", ..ts]
                False -> ts
              }
            }
            |> fn(ts) {
              case has_eq {
                True -> ["Eq", "Hash", ..ts]
                False -> ts
              }
            }
          let #(entry, next_ctx) = case traits {
            [] -> #(tp, cur_ctx)
            _ -> {
              let ctx_g = case has_inspect || has_to_dyn {
                True -> add_gprelude_import(cur_ctx)
                False -> cur_ctx
              }
              #(tp <> " : " <> string.join(traits, " + "), ctx_g)
            }
          }
          #([entry, ..parts], next_ctx)
        })
      #(
        "["
          <> {
          list.reverse(rev_formatted)
          |> string.join(", ")
        }
          <> "]",
        final_ctx,
      )
    }
  }
}

pub fn infer_fn_param_types(
  params: List(IrFnParam),
  body: List(IrStmt),
) -> dict.Dict(String, IrType) {
  let untyped_names =
    list.fold(params, set.new(), fn(acc, p) {
      case p.param_type, p.name {
        None, "_" -> acc
        None, name -> set.insert(acc, name)
        Some(_), _ -> acc
      }
    })
  case set.is_empty(untyped_names) {
    True -> dict.new()
    False -> infer_stmts_var_types(body, untyped_names, dict.new())
  }
}

fn infer_stmts_var_types(
  stmts: List(IrStmt),
  tracked: Set(String),
  acc: dict.Dict(String, IrType),
) -> dict.Dict(String, IrType) {
  case stmts {
    [] -> acc
    [stmt, ..rest] ->
      case stmt {
        IrStmtLet(pattern:, value:, ..) -> {
          let acc1 = infer_expr_var_types(value, tracked, acc)
          let next_tracked =
            set.difference(tracked, ir_util.pattern_bound_vars(pattern))
          infer_stmts_var_types(rest, next_tracked, acc1)
        }
        IrStmtGuard(
          value:,
          pattern:,
          guard_condition:,
          abort_message:,
          post_bindings:,
        ) -> {
          let acc1 = infer_expr_var_types(value, tracked, acc)
          let after_pat =
            set.difference(tracked, ir_util.pattern_bound_vars(pattern))
          let after_post =
            list.fold(post_bindings, after_pat, fn(t, b) { set.delete(t, b.0) })
          let acc2 =
            list.fold(post_bindings, acc1, fn(a, b) {
              infer_expr_var_types(b.1, after_pat, a)
            })
          let acc3 = case guard_condition {
            Some(g) -> infer_expr_var_types(g, after_post, acc2)
            None -> acc2
          }
          let acc4 = case abort_message {
            Some(m) -> infer_expr_var_types(m, after_post, acc3)
            None -> acc3
          }
          infer_stmts_var_types(rest, after_post, acc4)
        }
        IrStmtAssert(condition:, abort_message:) -> {
          let acc1 = infer_expr_var_types(condition, tracked, acc)
          let acc2 = case abort_message {
            Some(m) -> infer_expr_var_types(m, tracked, acc1)
            None -> acc1
          }
          infer_stmts_var_types(rest, tracked, acc2)
        }
        IrStmtExpr(expr) ->
          infer_stmts_var_types(
            rest,
            tracked,
            infer_expr_var_types(expr, tracked, acc),
          )
      }
  }
}

fn infer_expr_var_types(
  expr: IrExpr,
  tracked: Set(String),
  acc: dict.Dict(String, IrType),
) -> dict.Dict(String, IrType) {
  case expr {
    IrNegateInt(inner) -> {
      let acc1 = record_tracked_var(inner, IrTypeInt64, tracked, acc)
      infer_expr_var_types(inner, tracked, acc1)
    }
    IrNegateBool(inner) -> {
      let acc1 = record_tracked_var(inner, IrTypeBool, tracked, acc)
      infer_expr_var_types(inner, tracked, acc1)
    }
    IrBinOp(op:, left:, right:) -> {
      let operand_ty = case op {
        IrAddInt
        | IrSubInt
        | IrMultInt
        | IrDivInt
        | IrRemInt
        | IrLtInt
        | IrLtEqInt
        | IrGtInt
        | IrGtEqInt -> Some(IrTypeInt64)
        IrAddFloat
        | IrSubFloat
        | IrMultFloat
        | IrDivFloat
        | IrLtFloat
        | IrLtEqFloat
        | IrGtFloat
        | IrGtEqFloat -> Some(IrTypeDouble)
        IrStringConcat -> Some(IrTypeString)
        IrAnd | IrOr -> Some(IrTypeBool)
        IrEq | IrNotEq -> None
      }
      let acc1 = case operand_ty {
        Some(ty) ->
          record_tracked_var(left, ty, tracked, acc)
          |> record_tracked_var(right, ty, tracked, _)
        None -> acc
      }
      infer_expr_var_types(left, tracked, acc1)
      |> infer_expr_var_types(right, tracked, _)
    }
    IrCall(function:, args:) -> {
      let acc1 = infer_expr_var_types(function, tracked, acc)
      list.fold(args, acc1, fn(a, arg) {
        infer_expr_var_types(arg.value, tracked, a)
      })
    }
    IrBlock(stmts) -> infer_stmts_var_types(stmts, tracked, acc)
    IrFn(params:, body:, ..) -> {
      let shadowed =
        list.fold(params, set.new(), fn(s, p) { set.insert(s, p.name) })
      let inner_tracked = set.difference(tracked, shadowed)
      infer_stmts_var_types(body, inner_tracked, acc)
    }
    IrMatch(subjects:, clauses:) -> {
      let acc1 =
        list.fold(subjects, acc, fn(a, s) {
          infer_expr_var_types(s, tracked, a)
        })
      list.fold(clauses, acc1, fn(a, c) {
        let pat_shadowed =
          list.fold(c.patterns, set.new(), fn(s, alt) {
            list.fold(alt, s, fn(s2, p) {
              set.union(s2, ir_util.pattern_bound_vars(p))
            })
          })
        let after_pat = set.difference(tracked, pat_shadowed)
        let after_post =
          list.fold(c.prefix_bindings, after_pat, fn(t, b) {
            set.delete(t, b.0)
          })
        let a1 =
          list.fold(c.prefix_bindings, a, fn(x, b) {
            infer_expr_var_types(b.1, after_pat, x)
          })
        let a2 = case c.guard {
          Some(g) -> infer_expr_var_types(g, after_post, a1)
          None -> a1
        }
        infer_expr_var_types(c.body, after_post, a2)
      })
    }
    IrTuple(els) | IrContinue(els) ->
      list.fold(els, acc, fn(a, e) { infer_expr_var_types(e, tracked, a) })
    IrList(elements:, tail:) -> {
      let acc1 =
        list.fold(elements, acc, fn(a, e) {
          infer_expr_var_types(e, tracked, a)
        })
      case tail {
        Some(t) -> infer_expr_var_types(t, tracked, acc1)
        None -> acc1
      }
    }
    IrGetterCall(receiver: inner, ..)
    | IrTupleIndex(tuple: inner, ..)
    | IrBreak(inner) -> infer_expr_var_types(inner, tracked, acc)
    IrForLoop(bindings:, body:) -> {
      let acc1 =
        list.fold(bindings, acc, fn(a, b) {
          infer_expr_var_types(b.1, tracked, a)
        })
      let shadowed =
        list.fold(bindings, set.new(), fn(s, b) { set.insert(s, b.0) })
      infer_stmts_var_types(body, set.difference(tracked, shadowed), acc1)
    }
    _ -> acc
  }
}

fn record_tracked_var(
  expr: IrExpr,
  ty: IrType,
  tracked: Set(String),
  acc: dict.Dict(String, IrType),
) -> dict.Dict(String, IrType) {
  case expr {
    IrVar(name) ->
      case set.contains(tracked, name) && !dict.has_key(acc, name) {
        True -> dict.insert(acc, name, ty)
        False -> acc
      }
    _ -> acc
  }
}

fn align_pat_args(
  args: List(IrPatArg),
  field_labels: List(Option(String)),
) -> List(IrPatArg) {
  let has_unlabelled_for_labelled =
    list.any(args, fn(a) { option.is_none(a.label) })
    && list.any(field_labels, option.is_some)
  case
    has_unlabelled_for_labelled
    && list.length(args) <= list.length(field_labels)
  {
    False -> args
    True -> {
      let #(labeled_map, rev_positional) =
        list.fold(args, #(dict.new(), []), fn(acc, arg) {
          let #(lmap, pos) = acc
          case arg.label {
            Some(lbl) -> #(dict.insert(lmap, lbl, arg.pattern), pos)
            None -> #(lmap, [arg.pattern, ..pos])
          }
        })
      let #(rev_out, _) =
        list.fold(
          field_labels,
          #([], list.reverse(rev_positional)),
          fn(acc, lbl_opt) {
            let #(out, pos_q) = acc
            case lbl_opt {
              Some(lbl) ->
                case dict.get(labeled_map, lbl) {
                  Ok(p) -> #([IrPatArg(Some(lbl), p), ..out], pos_q)
                  Error(_) ->
                    case pos_q {
                      [p, ..rest_pos] -> #(
                        [IrPatArg(Some(lbl), p), ..out],
                        rest_pos,
                      )
                      [] -> #(out, pos_q)
                    }
                }
              None ->
                case pos_q {
                  [p, ..rest_pos] -> #([IrPatArg(None, p), ..out], rest_pos)
                  [] -> #(out, pos_q)
                }
            }
          },
        )
      list.reverse(rev_out)
    }
  }
}

pub fn escape_string_literal(raw: String) -> String {
  // Escape unescaped `\{` interpolation sequences (odd backslash count before `{`)
  // and raw CR/LF inside multiline Gleam strings.
  escape_string_literal_loop(string.to_graphemes(raw), False, [])
  |> list.reverse
  |> string.concat
}

fn escape_string_literal_loop(
  chars: List(String),
  prev_backslash: Bool,
  rev_acc: List(String),
) -> List(String) {
  case chars {
    [] -> rev_acc
    [ch, ..rest] ->
      case ch {
        "\\" ->
          escape_string_literal_loop(rest, !prev_backslash, [ch, ..rev_acc])
        "{" if prev_backslash ->
          escape_string_literal_loop(rest, False, ["\\{", ..rev_acc])
        "\r" -> escape_string_literal_loop(rest, False, ["\\r", ..rev_acc])
        "\n" -> escape_string_literal_loop(rest, False, ["\\n", ..rev_acc])
        _ -> escape_string_literal_loop(rest, False, [ch, ..rev_acc])
      }
  }
}

pub fn escape_plain_string(raw: String) -> String {
  raw
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\r", "\\r")
  |> string.replace("\n", "\\n")
  |> string.replace("\t", "\\t")
  |> string.replace("\\{", "\\\\{")
}

pub fn map_acc(
  items: List(a),
  ctx: EmitCtx,
  f: fn(a, EmitCtx) -> #(b, EmitCtx),
) -> #(List(b), EmitCtx) {
  let #(rev_out, final_ctx) =
    list.fold(items, #([], ctx), fn(acc, item) {
      let #(out_acc, cur_ctx) = acc
      let #(rendered, next_ctx) = f(item, cur_ctx)
      #([rendered, ..out_acc], next_ctx)
    })
  #(list.reverse(rev_out), final_ctx)
}

pub fn map_index_acc(
  items: List(a),
  ctx: EmitCtx,
  f: fn(a, Int, EmitCtx) -> #(b, EmitCtx),
) -> #(List(b), EmitCtx) {
  let #(rev_out, _, final_ctx) =
    list.fold(items, #([], 0, ctx), fn(acc, item) {
      let #(out_acc, idx, cur_ctx) = acc
      let #(rendered, next_ctx) = f(item, idx, cur_ctx)
      #([rendered, ..out_acc], idx + 1, next_ctx)
    })
  #(list.reverse(rev_out), final_ctx)
}

fn emit_type_eq_impl(td: IrTypeDef, dict_key_params: Set(String)) -> String {
  let vis = visibility(td.publicity)
  let impl_generics = case td.type_params {
    [] -> ""
    tps ->
      "["
      <> {
        list.map(tps, fn(tp) {
          case set.contains(dict_key_params, tp) {
            True -> tp <> " : Eq + Hash"
            False -> tp <> " : Eq"
          }
        })
        |> string.join(", ")
      }
      <> "]"
  }
  let self_ty = td.name <> format_type_params(td.type_params)
  let body = case td.variants {
    [] -> "  @prelude.ignore(self)\n  @prelude.ignore(other)\n  true"
    variants -> {
      let arms =
        list.map(variants, fn(v) {
          case v.fields {
            [] -> "    (" <> v.name <> ", " <> v.name <> ") => true"
            fields -> {
              let #(lhs_pats, rhs_pats, cmps) =
                list.index_fold(fields, #([], [], []), fn(acc, f, idx) {
                  let #(lp, rp, cs) = acc
                  let lname = "l" <> int.to_string(idx)
                  let rname = "r" <> int.to_string(idx)
                  let #(lpat, rpat) = case f.label {
                    Some(lbl) -> #(lbl <> "=" <> lname, lbl <> "=" <> rname)
                    None -> #(lname, rname)
                  }
                  #([lpat, ..lp], [rpat, ..rp], [lname <> " == " <> rname, ..cs])
                })
              let l_str =
                list.reverse(lhs_pats)
                |> string.join(", ")
              let r_str =
                list.reverse(rhs_pats)
                |> string.join(", ")
              let cmp_str =
                list.reverse(cmps)
                |> string.join(" && ")
              "    ("
              <> v.name
              <> "("
              <> l_str
              <> "), "
              <> v.name
              <> "("
              <> r_str
              <> ")) => "
              <> cmp_str
            }
          }
        })
      let all_arms = case list.length(variants) > 1 {
        True -> list.append(arms, ["    _ => false"])
        False -> arms
      }
      "  match (self, other) {\n" <> string.join(all_arms, "\n") <> "\n  }"
    }
  }
  "///|\n"
  <> vis
  <> "impl"
  <> impl_generics
  <> " Eq for "
  <> self_ty
  <> " with equal(self, other) {\n"
  <> body
  <> "\n}"
}

/// Collect local type and alias names transitively referenced by public types
/// or public type aliases so private dependencies of `pub opaque` types can be
/// emitted with `pub` (non-`pub(all)`) visibility in MoonBit.
pub fn collect_public_referenced_local_names(module: IrModule) -> Set(String) {
  let seed_types =
    list.fold(module.types, set.new(), fn(acc, td) {
      case td.publicity {
        glance.Public -> set.insert(acc, td.name)
        glance.Private -> acc
      }
    })
  let seed =
    list.fold(module.type_aliases, seed_types, fn(acc, ta) {
      case ta.publicity {
        glance.Public -> set.insert(acc, ta.name)
        glance.Private -> acc
      }
    })
  expand_public_referenced_names(
    module.types,
    module.type_aliases,
    module.module_name,
    seed,
  )
}

fn expand_public_referenced_names(
  types: List(IrTypeDef),
  aliases: List(IrTypeAlias),
  cur_mod: String,
  pub_names: Set(String),
) -> Set(String) {
  let type_uses_either = fn(ty: IrType, name: String, unmangled: String) -> Bool {
    type_uses_local_name(ty, cur_mod, name)
    || { unmangled != name && type_uses_local_name(ty, cur_mod, unmangled) }
  }
  let is_referenced_by_pub = fn(
    name: String,
    unmangled: String,
    cur_set: Set(String),
  ) {
    list.any(types, fn(other_td) {
      other_td.external_type == None
      && set.contains(cur_set, other_td.name)
      && list.any(other_td.variants, fn(v) {
        list.any(v.fields, fn(f) {
          type_uses_either(f.field_type, name, unmangled)
        })
      })
    })
    || list.any(aliases, fn(other_ta) {
      set.contains(cur_set, other_ta.name)
      && type_uses_either(other_ta.aliased, name, unmangled)
    })
  }
  let #(next_from_types, changed_types) =
    list.fold(types, #(pub_names, False), fn(acc, td) {
      let #(cur_set, _ch) = acc
      case set.contains(cur_set, td.name) {
        True -> acc
        False ->
          case is_referenced_by_pub(td.name, td.unmangled_name, cur_set) {
            True -> #(set.insert(cur_set, td.name), True)
            False -> acc
          }
      }
    })
  let #(next_pub, changed_aliases) =
    list.fold(aliases, #(next_from_types, changed_types), fn(acc, ta) {
      let #(cur_set, _ch) = acc
      case set.contains(cur_set, ta.name) {
        True -> acc
        False ->
          case is_referenced_by_pub(ta.name, ta.name, cur_set) {
            True -> #(set.insert(cur_set, ta.name), True)
            False -> acc
          }
      }
    })
  case changed_aliases {
    True -> expand_public_referenced_names(types, aliases, cur_mod, next_pub)
    False -> next_pub
  }
}

pub fn collect_visible_alias_names(module: IrModule) -> Set(String) {
  let seed =
    list.fold(module.type_aliases, set.new(), fn(acc, ta) {
      case
        ta.publicity == glance.Public
        || is_alias_referenced_in_module(module, ta.name)
      {
        True -> set.insert(acc, ta.name)
        False -> acc
      }
    })
  expand_visible_aliases(module.type_aliases, module.module_name, seed)
}

fn expand_visible_aliases(
  aliases: List(IrTypeAlias),
  cur_mod: String,
  visible: Set(String),
) -> Set(String) {
  let #(next_visible, changed) =
    list.fold(aliases, #(visible, False), fn(acc, ta) {
      let #(vis_set, _ch) = acc
      case set.contains(vis_set, ta.name) {
        True -> acc
        False -> {
          let used_by_visible =
            list.any(aliases, fn(other) {
              set.contains(vis_set, other.name)
              && type_uses_local_name(other.aliased, cur_mod, ta.name)
            })
          case used_by_visible {
            True -> #(set.insert(vis_set, ta.name), True)
            False -> acc
          }
        }
      }
    })
  case changed {
    True -> expand_visible_aliases(aliases, cur_mod, next_visible)
    False -> next_visible
  }
}

fn is_alias_referenced_in_module(module: IrModule, alias_name: String) -> Bool {
  let cur_mod = module.module_name
  let in_types =
    list.any(module.types, fn(td) {
      td.external_type == None
      && list.any(td.variants, fn(v) {
        list.any(v.fields, fn(f) {
          type_uses_local_name(f.field_type, cur_mod, alias_name)
        })
      })
    })
  let in_aliases =
    list.any(module.type_aliases, fn(ta) {
      ta.publicity == glance.Public
      && type_uses_local_name(ta.aliased, cur_mod, alias_name)
    })
  let in_getters =
    list.any(module.getters, fn(g) {
      type_uses_local_name(g.return_type, cur_mod, alias_name)
    })
  let in_consts =
    list.any(module.constants, fn(c) {
      type_uses_local_name(c.value_type, cur_mod, alias_name)
    })
  let in_fns =
    list.any(module.functions, fn(f) {
      list.any(f.params, fn(p) {
        type_uses_local_name(p.param_type, cur_mod, alias_name)
      })
      || type_uses_local_name(f.return_type, cur_mod, alias_name)
      || stmts_use_local_type(f.body, cur_mod, alias_name)
    })
  in_types || in_aliases || in_getters || in_consts || in_fns
}

fn type_uses_local_name(
  ty: IrType,
  cur_mod: String,
  alias_name: String,
) -> Bool {
  case ty {
    IrTypeNamed(module:, name:, args:, ..) ->
      { { module == "" || module == cur_mod } && name == alias_name }
      || list.any(args, type_uses_local_name(_, cur_mod, alias_name))
    IrTypeList(inner) -> type_uses_local_name(inner, cur_mod, alias_name)
    IrTypeResult(ok_t, err_t) ->
      type_uses_local_name(ok_t, cur_mod, alias_name)
      || type_uses_local_name(err_t, cur_mod, alias_name)
    IrTypeTuple(els) ->
      list.any(els, type_uses_local_name(_, cur_mod, alias_name))
    IrTypeFn(ps, r) ->
      list.any(ps, type_uses_local_name(_, cur_mod, alias_name))
      || type_uses_local_name(r, cur_mod, alias_name)
    _ -> False
  }
}

fn stmts_use_local_type(
  stmts: List(IrStmt),
  cur_mod: String,
  alias_name: String,
) -> Bool {
  list.any(stmts, fn(s) {
    case s {
      IrStmtLet(annotation: Some(ann), value:, ..) ->
        type_uses_local_name(ann, cur_mod, alias_name)
        || expr_uses_local_type(value, cur_mod, alias_name)
      IrStmtLet(value:, ..) -> expr_uses_local_type(value, cur_mod, alias_name)
      IrStmtGuard(value:, guard_condition:, abort_message:, post_bindings:, ..) ->
        expr_uses_local_type(value, cur_mod, alias_name)
        || option.map(guard_condition, expr_uses_local_type(
          _,
          cur_mod,
          alias_name,
        ))
        == Some(True)
        || option.map(abort_message, expr_uses_local_type(
          _,
          cur_mod,
          alias_name,
        ))
        == Some(True)
        || list.any(post_bindings, fn(b) {
          expr_uses_local_type(b.1, cur_mod, alias_name)
        })
      IrStmtAssert(condition:, abort_message:) ->
        expr_uses_local_type(condition, cur_mod, alias_name)
        || option.map(abort_message, expr_uses_local_type(
          _,
          cur_mod,
          alias_name,
        ))
        == Some(True)
      IrStmtExpr(expr) -> expr_uses_local_type(expr, cur_mod, alias_name)
    }
  })
}

fn expr_uses_local_type(
  expr: IrExpr,
  cur_mod: String,
  alias_name: String,
) -> Bool {
  case expr {
    IrFn(params:, return_type:, body:) ->
      list.any(params, fn(p) {
        option.map(p.param_type, type_uses_local_name(_, cur_mod, alias_name))
        == Some(True)
      })
      || option.map(return_type, type_uses_local_name(_, cur_mod, alias_name))
      == Some(True)
      || stmts_use_local_type(body, cur_mod, alias_name)
    IrBlock(stmts) -> stmts_use_local_type(stmts, cur_mod, alias_name)
    IrForLoop(bindings:, body:) ->
      list.any(bindings, fn(b) {
        expr_uses_local_type(b.1, cur_mod, alias_name)
      })
      || stmts_use_local_type(body, cur_mod, alias_name)
    IrBinOp(left:, right:, ..) ->
      expr_uses_local_type(left, cur_mod, alias_name)
      || expr_uses_local_type(right, cur_mod, alias_name)
    IrNegateInt(i)
    | IrNegateBool(i)
    | IrBreak(i)
    | IrGetterCall(receiver: i, ..) ->
      expr_uses_local_type(i, cur_mod, alias_name)
    IrEcho(expr: i, message:, ..) ->
      expr_uses_local_type(i, cur_mod, alias_name)
      || option.map(message, expr_uses_local_type(_, cur_mod, alias_name))
      == Some(True)
    IrBitString(segments:) ->
      list.any(segments, fn(seg) {
        expr_uses_local_type(seg.0, cur_mod, alias_name)
        || list.any(seg.1, fn(opt) {
          case opt {
            glance.SizeValueOption(e) ->
              expr_uses_local_type(e, cur_mod, alias_name)
            _ -> False
          }
        })
      })
    IrTuple(els) | IrContinue(els) ->
      list.any(els, expr_uses_local_type(_, cur_mod, alias_name))
    IrTupleIndex(tuple:, ..) -> expr_uses_local_type(tuple, cur_mod, alias_name)
    IrList(elements:, tail:) ->
      list.any(elements, expr_uses_local_type(_, cur_mod, alias_name))
      || option.map(tail, expr_uses_local_type(_, cur_mod, alias_name))
      == Some(True)
    IrCall(function:, args:) ->
      expr_uses_local_type(function, cur_mod, alias_name)
      || list.any(args, fn(a) {
        expr_uses_local_type(a.value, cur_mod, alias_name)
      })
    IrMatch(subjects:, clauses:) ->
      list.any(subjects, expr_uses_local_type(_, cur_mod, alias_name))
      || list.any(clauses, fn(c) {
        expr_uses_local_type(c.body, cur_mod, alias_name)
      })
    _ -> False
  }
}

/// Render a Gleam publicity modifier as a MoonBit `pub ` prefix (or nothing).
pub fn visibility(publicity: glance.Publicity) -> String {
  case publicity {
    glance.Public -> "pub "
    glance.Private -> ""
  }
}
