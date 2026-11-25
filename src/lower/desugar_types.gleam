import glance
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import index/symbol_table.{
  type FunctionInfo, type ModuleSymbols, type SymbolTable, type TypeInfo,
}
import lower/ir.{
  type IrExpr, type IrGetter, type IrParam, type IrType, type IrTypeDef,
  IrBitString, IrBool, IrCall, IrConstructor, IrFloat, IrGetter, IrInt, IrList,
  IrModuleRef, IrNegateBool, IrNegateInt, IrString, IrTuple, IrTypeBitArray,
  IrTypeBool, IrTypeDef, IrTypeDouble, IrTypeFn, IrTypeInt64, IrTypeList,
  IrTypeNamed, IrTypeResult, IrTypeString, IrTypeTuple, IrTypeUnit, IrTypeVar,
  IrUnit, IrVar, IrVariant, IrVariantField,
}
import lower/mangle
import project/interface.{
  type ResolvedType, FnType, NamedType, TupleType, VariableType,
}
import project/prepass.{ExternalType}

pub type LowerCtx {
  LowerCtx(
    table: SymbolTable,
    current_module: String,
    mod_syms: ModuleSymbols,
    local_vars: Set(String),
    local_var_types: dict.Dict(String, IrType),
    ast_type_vars: dict.Dict(String, String),
    next_id: Int,
  )
}

pub fn lower_type_def(
  type_info: TypeInfo,
  mod_syms: ModuleSymbols,
  table: SymbolTable,
) -> IrTypeDef {
  let type_params = list.map(type_info.parameters, mangle.mangle_type_param)
  let variants =
    list.map(type_info.variants, fn(variant) {
      let fields =
        list.map(variant.fields, fn(field) {
          let field_type = case field.resolved_type {
            Some(rt) ->
              resolved_type_to_ir_with_table(
                rt,
                Some(type_info.parameters),
                mod_syms,
                Some(table),
              )
            None ->
              lower_ast_type_with_table(
                field.ast_type,
                mod_syms,
                "",
                Some(table),
              )
          }
          IrVariantField(
            label: option.map(field.label, mangle.mangle_ident),
            unmangled_label: field.label,
            field_type:,
          )
        })
      IrVariant(name: variant.name, fields:)
    })

  let ir_name = case type_info.external_type {
    Some(ExternalType(package:, type_name: target))
      if { package == "" || package == "builtin" } && target == type_info.name
    -> type_info.name
    _ -> mangle.mangle_type_name(type_info.name)
  }

  IrTypeDef(
    name: ir_name,
    unmangled_name: type_info.name,
    publicity: type_info.publicity,
    opaque_: type_info.opaque_,
    type_params:,
    variants:,
    external_type: type_info.external_type,
    derive_eq_debug_hash: !type_info.has_function_field,
  )
}

pub fn synthesize_getters(
  type_info: TypeInfo,
  mod_syms: ModuleSymbols,
  table: SymbolTable,
) -> List(IrGetter) {
  let type_params = list.map(type_info.parameters, mangle.mangle_type_param)
  let variants =
    list.map(type_info.variants, fn(v) {
      let positional = list.count(v.fields, fn(f) { option.is_none(f.label) })
      #(v.name, positional)
    })
  type_info.shared_fields
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.map(fn(entry) {
    let #(field_name, resolved_ty) = entry
    IrGetter(
      type_name: mangle.mangle_type_name(type_info.name),
      type_params:,
      publicity: type_info.publicity,
      field_name: mangle.mangle_ident(field_name),
      return_type: resolved_type_to_ir_with_table(
        resolved_ty,
        Some(type_info.parameters),
        mod_syms,
        Some(table),
      ),
      variants:,
    )
  })
}

pub fn infer_const_expr_type(expr: IrExpr) -> IrType {
  case expr {
    IrInt(_) | IrNegateInt(_) -> IrTypeInt64
    IrFloat(_) -> IrTypeDouble
    IrString(_) -> IrTypeString
    IrBool(_) | IrNegateBool(_) -> IrTypeBool
    IrUnit -> IrTypeUnit
    IrBitString(_) -> IrTypeBitArray
    IrTuple(els) -> IrTypeTuple(list.map(els, infer_const_expr_type))
    IrList(elements: [first, ..], ..) ->
      IrTypeList(infer_const_expr_type(first))
    IrList(elements: [], tail: Some(t)) -> infer_const_expr_type(t)
    IrList(elements: [], tail: None) -> IrTypeList(IrTypeVar("T0"))
    IrCall(IrConstructor(_, _, "Ok"), [arg]) ->
      IrTypeResult(infer_const_expr_type(arg.value), IrTypeVar("T0"))
    IrCall(IrConstructor(_, _, "Err"), [arg]) ->
      IrTypeResult(IrTypeVar("T0"), infer_const_expr_type(arg.value))
    _ -> IrTypeVar("T0")
  }
}

pub fn resolve_callee_arity(
  callee: glance.Expression,
  ctx: LowerCtx,
) -> Option(#(Int, List(Option(String)))) {
  case callee {
    glance.Variable(name:, ..) ->
      case set.contains(ctx.local_vars, name) {
        True ->
          case dict.get(ctx.local_var_types, name) {
            Ok(IrTypeFn(params:, ..)) ->
              Some(#(
                list.length(params),
                list.repeat(None, list.length(params)),
              ))
            _ -> None
          }
        False ->
          case dict.get(ctx.mod_syms.functions, name) {
            Ok(fn_info) -> Some(fn_info_arity_labels(fn_info))
            Error(_) ->
              case dict.get(ctx.mod_syms.constructors, name) {
                Ok(ctor) ->
                  Some(#(
                    list.length(ctor.fields),
                    list.map(ctor.fields, fn(f) { f.label }),
                  ))
                Error(_) ->
                  case dict.get(ctx.mod_syms.unqualified_values, name) {
                    Ok(#(target_mod, orig_name)) ->
                      lookup_remote_arity(ctx.table, target_mod, orig_name)
                    Error(_) -> None
                  }
              }
          }
      }

    glance.FieldAccess(container: glance.Variable(name: alias, ..), label:, ..) ->
      case resolve_module_alias_for_access(alias, label, ctx) {
        Some(target_mod) -> lookup_remote_arity(ctx.table, target_mod, label)
        None -> None
      }

    _ ->
      case infer_local_expr_type(callee, ctx) {
        Some(IrTypeFn(params:, ..)) ->
          Some(#(list.length(params), list.repeat(None, list.length(params))))
        _ -> None
      }
  }
}

pub fn infer_local_expr_type(
  expr: glance.Expression,
  ctx: LowerCtx,
) -> Option(IrType) {
  case expr {
    glance.Int(..) -> Some(IrTypeInt64)
    glance.Float(..) -> Some(IrTypeDouble)
    glance.String(..) -> Some(IrTypeString)
    glance.Variable(name:, ..) ->
      case set.contains(ctx.local_vars, name) {
        True -> dict.get(ctx.local_var_types, name) |> option.from_result
        False ->
          case dict.get(ctx.mod_syms.functions, name) {
            Ok(fi) -> Some(fn_info_to_ir_type(fi, ctx))
            Error(_) ->
              case dict.get(ctx.mod_syms.unqualified_values, name) {
                Ok(#(tm, orig)) ->
                  lookup_remote_fn_ir_type(ctx.table, tm, orig, ctx)
                Error(_) -> None
              }
          }
      }
    glance.FieldAccess(container: glance.Variable(name: alias, ..), label:, ..) ->
      case resolve_module_alias_for_access(alias, label, ctx) {
        Some(tm) -> lookup_remote_fn_ir_type(ctx.table, tm, label, ctx)
        None -> None
      }
    glance.Fn(arguments:, return_annotation:, body:, ..) -> {
      let #(rev_p_tys, body_vars, body_types) =
        list.fold(
          arguments,
          #([], ctx.local_vars, ctx.local_var_types),
          fn(acc, param) {
            let #(pts, vars, types) = acc
            let pt = case param.type_ {
              Some(t) ->
                lower_ast_type_with_vars(
                  t,
                  ctx.mod_syms,
                  ctx.table.package_name,
                  ctx.ast_type_vars,
                  Some(ctx.table),
                )
              None -> IrTypeVar("T0")
            }
            let #(next_vars, next_types) = case param.name {
              glance.Named(n) -> #(
                set.insert(vars, n),
                dict.insert(types, n, pt),
              )
              glance.Discarded(_) -> #(vars, types)
            }
            #([pt, ..pts], next_vars, next_types)
          },
        )
      let ret_ty = case return_annotation {
        Some(t) ->
          lower_ast_type_with_vars(
            t,
            ctx.mod_syms,
            ctx.table.package_name,
            ctx.ast_type_vars,
            Some(ctx.table),
          )
        None ->
          case body {
            [glance.Expression(inner)] ->
              infer_local_expr_type(
                inner,
                LowerCtx(
                  ..ctx,
                  local_vars: body_vars,
                  local_var_types: body_types,
                ),
              )
              |> option.unwrap(IrTypeVar("T0"))
            _ -> IrTypeVar("T0")
          }
      }
      Some(IrTypeFn(list.reverse(rev_p_tys), ret_ty))
    }
    glance.Call(function:, ..) ->
      case infer_local_expr_type(function, ctx) {
        Some(IrTypeFn(_, ret)) -> Some(ret)
        _ -> None
      }
    _ -> None
  }
}

fn lookup_remote_fn_ir_type(
  table: SymbolTable,
  target_mod: String,
  symbol: String,
  ctx: LowerCtx,
) -> Option(IrType) {
  case dict.get(table.modules, target_mod) {
    Ok(ms) ->
      case dict.get(ms.functions, symbol) {
        Ok(fi) -> Some(fn_info_to_ir_type(fi, ctx))
        Error(_) -> None
      }
    Error(_) -> None
  }
}

fn fn_info_to_ir_type(fi: FunctionInfo, ctx: LowerCtx) -> IrType {
  let param_tys =
    list.map(fi.parameters, fn(p) {
      case p.resolved_type {
        Some(rt) ->
          resolved_type_to_ir_with_table(
            rt,
            None,
            ctx.mod_syms,
            Some(ctx.table),
          )
        None -> IrTypeVar("T0")
      }
    })
  let ret_ty = case fi.return_type {
    Some(rt) ->
      resolved_type_to_ir_with_table(rt, None, ctx.mod_syms, Some(ctx.table))
    None -> IrTypeUnit
  }
  IrTypeFn(param_tys, ret_ty)
}

fn lookup_remote_arity(
  table: SymbolTable,
  target_mod: String,
  symbol: String,
) -> Option(#(Int, List(Option(String)))) {
  case dict.get(table.modules, target_mod) {
    Ok(ms) ->
      case dict.get(ms.functions, symbol) {
        Ok(fn_info) -> Some(fn_info_arity_labels(fn_info))
        Error(_) ->
          case dict.get(ms.constructors, symbol) {
            Ok(ctor) ->
              Some(#(
                list.length(ctor.fields),
                list.map(ctor.fields, fn(f) { f.label }),
              ))
            Error(_) -> None
          }
      }
    Error(_) -> None
  }
}

fn fn_info_arity_labels(fn_info: FunctionInfo) -> #(Int, List(Option(String))) {
  #(fn_info.arity, list.map(fn_info.parameters, fn(p) { p.label }))
}

pub fn find_pipe_slot_label(
  param_labels: List(Option(String)),
  supplied_args: List(glance.Field(glance.Expression)),
) -> Option(String) {
  let supplied_labels =
    list.fold(supplied_args, set.new(), fn(acc, arg) {
      case arg {
        glance.LabelledField(label:, ..) | glance.ShorthandField(label:, ..) ->
          set.insert(acc, label)
        glance.UnlabelledField(_) -> acc
      }
    })

  let remaining_params =
    list.filter(param_labels, fn(lbl_opt) {
      case lbl_opt {
        Some(lbl) -> !set.contains(supplied_labels, lbl)
        None -> True
      }
    })

  case remaining_params {
    [first, ..] -> option.map(first, mangle.mangle_ident)
    [] -> None
  }
}

pub fn resolve_module_alias_for_access(
  alias: String,
  label: String,
  ctx: LowerCtx,
) -> Option(String) {
  case dict.get(ctx.mod_syms.alias_to_module, alias) {
    Error(_) -> None
    Ok(target_mod) ->
      case set.contains(ctx.local_vars, alias) {
        False -> Some(target_mod)
        True ->
          case
            module_has_value(ctx.table, target_mod, label)
            && !scope_has_record_field(ctx.table, ctx.mod_syms, label)
          {
            True -> Some(target_mod)
            False -> None
          }
      }
  }
}

fn module_has_value(
  table: SymbolTable,
  target_mod: String,
  symbol: String,
) -> Bool {
  case dict.get(table.modules, target_mod) {
    Error(_) -> False
    Ok(ms) ->
      dict.has_key(ms.functions, symbol)
      || dict.has_key(ms.constructors, symbol)
      || dict.has_key(ms.constants, symbol)
  }
}

fn scope_has_record_field(
  table: SymbolTable,
  mod_syms: ModuleSymbols,
  label: String,
) -> Bool {
  let imported_mods = list.map(mod_syms.imports, fn(imp) { imp.module })
  let scope_mods = [mod_syms.name, ..imported_mods]
  list.any(scope_mods, fn(mod_name) {
    case dict.get(table.modules, mod_name) {
      Error(_) -> False
      Ok(ms) ->
        dict.values(ms.types)
        |> list.any(fn(ti) {
          dict.has_key(ti.shared_fields, label)
          || list.any(ti.variants, fn(v) {
            list.any(v.fields, fn(f) { f.label == Some(label) })
          })
        })
    }
  })
}

pub fn resolve_variable(name: String, ctx: LowerCtx) -> IrExpr {
  case set.contains(ctx.local_vars, name) {
    True -> IrVar(mangle.mangle_ident(name))
    False ->
      case dict.get(ctx.mod_syms.constructors, name) {
        Ok(ctor) -> IrConstructor(None, None, ctor.variant_name)
        Error(_) ->
          case dict.get(ctx.mod_syms.unqualified_values, name) {
            Ok(#(target_mod, orig_name)) -> {
              let alias = find_import_alias(ctx.mod_syms, target_mod)
              case
                symbol_table.lookup_constructor(
                  ctx.table,
                  ctx.current_module,
                  None,
                  name,
                )
              {
                Some(ctor) ->
                  IrConstructor(
                    module_alias: Some(alias),
                    target_module: Some(ctor.module),
                    name: ctor.variant_name,
                  )
                None ->
                  IrModuleRef(
                    module_alias: Some(alias),
                    target_module: target_mod,
                    symbol: mangle.mangle_ident(orig_name),
                  )
              }
            }
            Error(_) ->
              case name {
                "True" -> IrBool(True)
                "False" -> IrBool(False)
                "Nil" -> IrUnit
                "Ok" -> IrConstructor(None, None, "Ok")
                "Error" -> IrConstructor(None, None, "Err")
                _ -> IrVar(mangle.mangle_ident(name))
              }
          }
      }
  }
}

pub fn find_import_alias(
  mod_syms: ModuleSymbols,
  target_mod: String,
) -> String {
  case list.find(mod_syms.imports, fn(imp) { imp.module == target_mod }) {
    Ok(imp) ->
      case imp.alias {
        Some(a) -> a
        None -> mangle.module_to_alias(target_mod)
      }
    Error(_) -> mangle.module_to_alias(target_mod)
  }
}

pub fn resolved_type_to_ir_with_table(
  ty: ResolvedType,
  named_type_params: Option(List(String)),
  mod_syms: ModuleSymbols,
  table_opt: Option(SymbolTable),
) -> IrType {
  case ty {
    NamedType(name:, package:, module:, parameters:) -> {
      let lowered_args =
        list.map(parameters, fn(p) {
          resolved_type_to_ir_with_table(
            p,
            named_type_params,
            mod_syms,
            table_opt,
          )
        })
      case module, name, lowered_args {
        "gleam", "Int", [] -> IrTypeInt64
        "gleam", "Float", [] -> IrTypeDouble
        "gleam", "String", [] -> IrTypeString
        "gleam", "Bool", [] -> IrTypeBool
        "gleam", "Nil", [] -> IrTypeUnit
        "gleam", "BitArray", [] -> IrTypeBitArray
        "gleam", "List", [inner] -> IrTypeList(inner)
        "gleam", "Result", [ok_t, err_t] -> IrTypeResult(ok_t, err_t)
        _, _, _ -> {
          let alias = case module == mod_syms.name {
            True -> None
            False -> Some(find_import_alias(mod_syms, module))
          }
          IrTypeNamed(
            module_alias: alias,
            package:,
            module:,
            name: mangle_referenced_type_name(table_opt, module, name),
            args: lowered_args,
          )
        }
      }
    }

    TupleType(elements:) ->
      IrTypeTuple(
        list.map(elements, fn(el) {
          resolved_type_to_ir_with_table(
            el,
            named_type_params,
            mod_syms,
            table_opt,
          )
        }),
      )

    FnType(parameters:, return:) ->
      IrTypeFn(
        params: list.map(parameters, fn(p) {
          resolved_type_to_ir_with_table(
            p,
            named_type_params,
            mod_syms,
            table_opt,
          )
        }),
        return: resolved_type_to_ir_with_table(
          return,
          named_type_params,
          mod_syms,
          table_opt,
        ),
      )

    VariableType(id:) -> {
      let name = case named_type_params {
        Some(names) ->
          case list_at(names, id) {
            Some(n) -> mangle.mangle_type_param(n)
            None -> mangle.type_var_id_to_name(id)
          }
        None -> mangle.type_var_id_to_name(id)
      }
      IrTypeVar(name)
    }
  }
}

pub fn lower_ast_type_with_table(
  ty: glance.Type,
  mod_syms: ModuleSymbols,
  package_name: String,
  table_opt: Option(SymbolTable),
) -> IrType {
  lower_ast_type_with_vars(ty, mod_syms, package_name, dict.new(), table_opt)
}

pub fn lower_ast_type_with_vars(
  ty: glance.Type,
  mod_syms: ModuleSymbols,
  package_name: String,
  ast_type_vars: dict.Dict(String, String),
  table_opt: Option(SymbolTable),
) -> IrType {
  case ty {
    glance.NamedType(name:, module: mod_opt, parameters:, ..) -> {
      let args =
        list.map(parameters, fn(p) {
          lower_ast_type_with_vars(
            p,
            mod_syms,
            package_name,
            ast_type_vars,
            table_opt,
          )
        })
      case mod_opt, name, args {
        None, "Int", [] -> IrTypeInt64
        None, "Float", [] -> IrTypeDouble
        None, "String", [] -> IrTypeString
        None, "Bool", [] -> IrTypeBool
        None, "Nil", [] -> IrTypeUnit
        None, "BitArray", [] -> IrTypeBitArray
        None, "UtfCodepoint", [] ->
          IrTypeNamed(
            module_alias: None,
            package: "gleam",
            module: "gleam",
            name: "UtfCodepoint",
            args: [],
          )
        None, "List", [inner] -> IrTypeList(inner)
        None, "Result", [ok_t, err_t] -> IrTypeResult(ok_t, err_t)
        Some(alias), _, _ -> {
          let target_mod = case dict.get(mod_syms.alias_to_module, alias) {
            Ok(m) -> m
            Error(_) -> alias
          }
          IrTypeNamed(
            module_alias: Some(alias),
            package: package_name,
            module: target_mod,
            name: mangle_referenced_type_name(table_opt, target_mod, name),
            args:,
          )
        }
        None, _, _ ->
          case dict.get(mod_syms.unqualified_types, name) {
            Ok(#(target_mod, orig_name)) ->
              IrTypeNamed(
                module_alias: Some(find_import_alias(mod_syms, target_mod)),
                package: package_name,
                module: target_mod,
                name: mangle_referenced_type_name(
                  table_opt,
                  target_mod,
                  orig_name,
                ),
                args:,
              )
            Error(_) ->
              IrTypeNamed(
                module_alias: None,
                package: package_name,
                module: mod_syms.name,
                name: mangle_referenced_type_name(
                  table_opt,
                  mod_syms.name,
                  name,
                ),
                args:,
              )
          }
      }
    }

    glance.TupleType(elements:, ..) ->
      IrTypeTuple(
        list.map(elements, fn(el) {
          lower_ast_type_with_vars(
            el,
            mod_syms,
            package_name,
            ast_type_vars,
            table_opt,
          )
        }),
      )

    glance.FunctionType(parameters:, return:, ..) ->
      IrTypeFn(
        params: list.map(parameters, fn(p) {
          lower_ast_type_with_vars(
            p,
            mod_syms,
            package_name,
            ast_type_vars,
            table_opt,
          )
        }),
        return: lower_ast_type_with_vars(
          return,
          mod_syms,
          package_name,
          ast_type_vars,
          table_opt,
        ),
      )

    glance.VariableType(name:, ..) | glance.HoleType(name:, ..) -> {
      let mangled = mangle.mangle_type_param(name)
      case dict.get(ast_type_vars, mangled) {
        Ok(canon) -> IrTypeVar(canon)
        Error(_) -> IrTypeVar(mangled)
      }
    }
  }
}

pub fn build_ast_type_var_map(
  ast_params: List(glance.FunctionParameter),
  ir_params: List(IrParam),
  ast_return: Option(glance.Type),
  ir_return: IrType,
  mod_syms: ModuleSymbols,
  package_name: String,
  table_opt: Option(SymbolTable),
) -> dict.Dict(String, String) {
  let acc0 =
    list.fold(list.zip(ast_params, ir_params), dict.new(), fn(acc, pair) {
      let #(ap, ip) = pair
      case ap.type_ {
        Some(ast_t) ->
          collect_ast_type_var_map(
            lower_ast_type_with_table(ast_t, mod_syms, package_name, table_opt),
            ip.param_type,
            mod_syms,
            package_name,
            table_opt,
            set.new(),
            acc,
          )
        None -> acc
      }
    })
  case ast_return {
    Some(ast_r) ->
      collect_ast_type_var_map(
        lower_ast_type_with_table(ast_r, mod_syms, package_name, table_opt),
        ir_return,
        mod_syms,
        package_name,
        table_opt,
        set.new(),
        acc0,
      )
    None -> acc0
  }
}

fn collect_ast_type_var_map(
  ast_ir: IrType,
  resolved_ir: IrType,
  mod_syms: ModuleSymbols,
  package_name: String,
  table_opt: Option(SymbolTable),
  visited: Set(#(String, String)),
  acc: dict.Dict(String, String),
) -> dict.Dict(String, String) {
  case ast_ir, resolved_ir {
    IrTypeVar(a), IrTypeVar(b) -> dict.insert(acc, a, b)
    IrTypeList(a), IrTypeList(b) ->
      collect_ast_type_var_map(
        a,
        b,
        mod_syms,
        package_name,
        table_opt,
        visited,
        acc,
      )
    IrTypeResult(ao, ae), IrTypeResult(bo, be) ->
      collect_ast_type_var_map(
        ae,
        be,
        mod_syms,
        package_name,
        table_opt,
        visited,
        collect_ast_type_var_map(
          ao,
          bo,
          mod_syms,
          package_name,
          table_opt,
          visited,
          acc,
        ),
      )
    IrTypeTuple(as_), IrTypeTuple(bs) ->
      list.fold(list.zip(as_, bs), acc, fn(s, pair) {
        collect_ast_type_var_map(
          pair.0,
          pair.1,
          mod_syms,
          package_name,
          table_opt,
          visited,
          s,
        )
      })
    IrTypeFn(ap, ar), IrTypeFn(bp, br) -> {
      let s1 =
        list.fold(list.zip(ap, bp), acc, fn(s, pair) {
          collect_ast_type_var_map(
            pair.0,
            pair.1,
            mod_syms,
            package_name,
            table_opt,
            visited,
            s,
          )
        })
      collect_ast_type_var_map(
        ar,
        br,
        mod_syms,
        package_name,
        table_opt,
        visited,
        s1,
      )
    }
    IrTypeNamed(module: am, name: an, args: a_args, ..),
      IrTypeNamed(module: rm, name: rn, args: b_args, ..)
      if am == rm && an == rn
    ->
      list.fold(list.zip(a_args, b_args), acc, fn(s, pair) {
        collect_ast_type_var_map(
          pair.0,
          pair.1,
          mod_syms,
          package_name,
          table_opt,
          visited,
          s,
        )
      })
    IrTypeNamed(module:, name:, args:, ..), _ ->
      case
        expand_ast_type_alias(
          module,
          name,
          args,
          mod_syms,
          package_name,
          table_opt,
          visited,
        )
      {
        Some(#(expanded, next_mod_syms)) ->
          collect_ast_type_var_map(
            expanded,
            resolved_ir,
            next_mod_syms,
            package_name,
            table_opt,
            set.insert(visited, #(module, name)),
            acc,
          )
        None -> acc
      }
    _, _ -> acc
  }
}

fn expand_ast_type_alias(
  module: String,
  name: String,
  args: List(IrType),
  mod_syms: ModuleSymbols,
  package_name: String,
  table_opt: Option(SymbolTable),
  visited: Set(#(String, String)),
) -> Option(#(IrType, ModuleSymbols)) {
  case set.contains(visited, #(module, name)) {
    True -> None
    False -> {
      let target_syms = case module == mod_syms.name || module == "" {
        True -> Some(mod_syms)
        False ->
          case table_opt {
            Some(tbl) -> dict.get(tbl.modules, module) |> option.from_result
            None -> None
          }
      }
      case target_syms {
        None -> None
        Some(ts) -> {
          let found =
            dict.values(ts.type_aliases)
            |> list.find(fn(ta) {
              ta.name == name || mangle.mangle_type_name(ta.name) == name
            })
          case found {
            Ok(ta) ->
              case list.length(ta.parameters) == list.length(args) {
                False -> None
                True -> {
                  let lowered_body =
                    lower_ast_type_with_table(
                      ta.aliased,
                      ts,
                      package_name,
                      table_opt,
                    )
                  let subst =
                    list.zip(
                      list.map(ta.parameters, mangle.mangle_type_param),
                      args,
                    )
                    |> dict.from_list
                  Some(#(substitute_ir_type_vars(lowered_body, subst), ts))
                }
              }
            Error(_) -> None
          }
        }
      }
    }
  }
}

fn substitute_ir_type_vars(
  ty: IrType,
  subst: dict.Dict(String, IrType),
) -> IrType {
  case ty {
    IrTypeVar(v) ->
      case dict.get(subst, v) {
        Ok(replacement) -> replacement
        Error(_) -> ty
      }
    IrTypeList(inner) -> IrTypeList(substitute_ir_type_vars(inner, subst))
    IrTypeResult(ok_t, err_t) ->
      IrTypeResult(
        substitute_ir_type_vars(ok_t, subst),
        substitute_ir_type_vars(err_t, subst),
      )
    IrTypeTuple(els) ->
      IrTypeTuple(list.map(els, substitute_ir_type_vars(_, subst)))
    IrTypeFn(ps, r) ->
      IrTypeFn(
        list.map(ps, substitute_ir_type_vars(_, subst)),
        substitute_ir_type_vars(r, subst),
      )
    IrTypeNamed(args:, ..) ->
      IrTypeNamed(..ty, args: list.map(args, substitute_ir_type_vars(_, subst)))
    _ -> ty
  }
}

fn is_builtin_external_type(
  table_opt: Option(SymbolTable),
  module: String,
  name: String,
) -> Bool {
  case table_opt {
    None -> False
    Some(tbl) ->
      case dict.get(tbl.modules, module) {
        Error(_) -> False
        Ok(ms) ->
          case dict.get(ms.types, name) {
            Ok(ti) ->
              case ti.external_type {
                Some(ExternalType(package: pkg, type_name:)) ->
                  { pkg == "" || pkg == "builtin" } && type_name == name
                _ -> False
              }
            Error(_) -> False
          }
      }
  }
}

fn mangle_referenced_type_name(
  table_opt: Option(SymbolTable),
  module: String,
  name: String,
) -> String {
  case module == "gleam" || is_builtin_external_type(table_opt, module, name) {
    True -> name
    False -> mangle.mangle_type_name(name)
  }
}

pub fn list_at(items: List(a), index: Int) -> Option(a) {
  case items, index {
    [], _ -> None
    [head, ..], 0 -> Some(head)
    [_, ..tail], i if i > 0 -> list_at(tail, i - 1)
    _, _ -> None
  }
}
