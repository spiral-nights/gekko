import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import index/symbol_table.{type SymbolTable}
import lower/ir.{
  type IrCallArg, type IrExpr, type IrFunction, type IrParam, type IrPatArg,
  type IrPattern, type IrStmt, type IrType, type IrTypeDef, type IrVariant,
  IrAddFloat, IrAddInt, IrAnd, IrBinOp, IrBitString, IrBlock, IrBool, IrBreak,
  IrCall, IrConstructor, IrDivFloat, IrDivInt, IrEcho, IrEq, IrFloat, IrFn,
  IrForLoop, IrGetterCall, IrGtEqFloat, IrGtEqInt, IrGtFloat, IrGtInt, IrInt,
  IrList, IrLtEqFloat, IrLtEqInt, IrLtFloat, IrLtInt, IrMatch, IrModuleRef,
  IrMultFloat, IrMultInt, IrNegateBool, IrNegateInt, IrNotEq, IrOr, IrParam,
  IrPatAs, IrPatTuple, IrPatVar, IrPatVariant, IrRemInt, IrStmtAssert,
  IrStmtExpr, IrStmtGuard, IrStmtLet, IrString, IrStringConcat, IrSubFloat,
  IrSubInt, IrTuple, IrTupleIndex, IrTypeBitArray, IrTypeBool, IrTypeDouble,
  IrTypeFn, IrTypeInt64, IrTypeList, IrTypeNamed, IrTypeResult, IrTypeString,
  IrTypeTuple, IrTypeUnit, IrTypeVar, IrUnit, IrVar,
}
import lower/mangle
import moonbit/ffi_meta.{type FfiMetadata}
import project/prepass.{type ExternalType}

pub type GetterSig {
  GetterSig(type_params: List(String), return_type: IrType)
}

pub type AnalyzeCtx {
  AnalyzeCtx(
    all_fns: Dict(#(String, String), IrFunction),
    all_consts: Dict(#(String, String), IrType),
    all_types: Dict(#(String, String), IrTypeDef),
    all_type_aliases: Dict(#(String, String), ir.IrTypeAlias),
    all_ctors: Dict(#(String, String), #(IrTypeDef, IrVariant)),
    all_getters: Dict(#(String, String, String), GetterSig),
    table: Option(SymbolTable),
    ffi_metadata: FfiMetadata,
  )
}

pub fn freshen_ir_type(ty: IrType) -> IrType {
  case ty {
    IrTypeVar(v) ->
      case is_free_var(v) {
        True -> ty
        False -> IrTypeVar("__free_" <> v)
      }
    IrTypeList(inner) -> IrTypeList(freshen_ir_type(inner))
    IrTypeResult(ok_t, err_t) ->
      IrTypeResult(freshen_ir_type(ok_t), freshen_ir_type(err_t))
    IrTypeTuple(els) -> IrTypeTuple(list.map(els, freshen_ir_type))
    IrTypeFn(ps, r) ->
      IrTypeFn(list.map(ps, freshen_ir_type), freshen_ir_type(r))
    IrTypeNamed(args:, ..) ->
      IrTypeNamed(..ty, args: list.map(args, freshen_ir_type))
    _ -> ty
  }
}

pub fn unify_aligned_args(
  params: List(IrParam),
  ordered_args: List(Option(IrExpr)),
  env: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Dict(String, IrType) {
  list.fold(list.zip(params, ordered_args), dict.new(), fn(s, pair) {
    let #(pi, maybe_arg) = pair
    case maybe_arg {
      Some(arg_val) ->
        case infer_expr_type(arg_val, env, cur_mod, ctx) {
          Some(arg_ty) -> unify_ir_types(pi.param_type, arg_ty, cur_mod, ctx, s)
          None -> s
        }
      None -> s
    }
  })
}

pub fn infer_expr_type(
  expr: IrExpr,
  env: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Option(IrType) {
  case expr {
    IrInt(_) -> Some(IrTypeInt64)
    IrFloat(_) -> Some(IrTypeDouble)
    IrString(_) -> Some(IrTypeString)
    IrBool(_) -> Some(IrTypeBool)
    IrUnit -> Some(IrTypeUnit)
    IrBitString(_) -> Some(IrTypeBitArray)
    IrVar(name) ->
      case dict.get(env, name) {
        Ok(ty) -> Some(ty)
        Error(_) ->
          case dict.get(ctx.all_consts, #(cur_mod, name)) {
            Ok(c_ty) -> Some(freshen_ir_type(c_ty))
            Error(_) ->
              case dict.get(ctx.all_fns, #(cur_mod, name)) {
                Ok(f) -> Some(freshen_fn_type(f))
                Error(_) -> None
              }
          }
      }
    IrModuleRef(target_module:, symbol:, ..) ->
      case dict.get(ctx.all_consts, #(target_module, symbol)) {
        Ok(c_ty) -> Some(freshen_ir_type(c_ty))
        Error(_) ->
          case dict.get(ctx.all_fns, #(target_module, symbol)) {
            Ok(f) -> Some(freshen_fn_type(f))
            Error(_) -> None
          }
      }
    IrConstructor(target_module:, name:, ..) -> {
      let ctor_mod = option.unwrap(target_module, cur_mod)
      case lookup_ctor(ctx, ctor_mod, name) {
        Some(#(td, variant)) ->
          case variant.fields {
            [] ->
              Some(IrTypeNamed(
                module_alias: None,
                package: "",
                module: ctor_mod,
                name: td.name,
                args: list.map(td.type_params, fn(tp) {
                  IrTypeVar("__free_" <> tp)
                }),
              ))
            _ -> None
          }
        None -> None
      }
    }
    IrTuple(els) -> {
      let inferred =
        list.map(els, fn(e) { infer_expr_type(e, env, cur_mod, ctx) })
      case list.all(inferred, option.is_some) {
        True ->
          Some(IrTypeTuple(list.filter_map(inferred, option.to_result(_, Nil))))
        False -> None
      }
    }
    IrTupleIndex(tuple:, index:) ->
      case
        option.map(infer_expr_type(tuple, env, cur_mod, ctx), expand_type_alias(
          _,
          cur_mod,
          ctx,
        ))
      {
        Some(IrTypeTuple(els)) -> list_at_idx(els, index)
        _ -> None
      }
    IrList(elements:, tail:) ->
      case tail {
        Some(t) -> infer_expr_type(t, env, cur_mod, ctx)
        None ->
          case elements {
            [first, ..] ->
              option.map(infer_expr_type(first, env, cur_mod, ctx), IrTypeList)
            [] -> Some(IrTypeList(IrTypeVar("__free_elem")))
          }
      }
    IrBinOp(op:, ..) ->
      case op {
        IrEq
        | IrNotEq
        | IrAnd
        | IrOr
        | IrLtInt
        | IrLtEqInt
        | IrGtInt
        | IrGtEqInt
        | IrLtFloat
        | IrLtEqFloat
        | IrGtFloat
        | IrGtEqFloat -> Some(IrTypeBool)
        IrStringConcat -> Some(IrTypeString)
        IrAddInt | IrSubInt | IrMultInt | IrDivInt | IrRemInt ->
          Some(IrTypeInt64)
        IrAddFloat | IrSubFloat | IrMultFloat | IrDivFloat -> Some(IrTypeDouble)
      }
    IrNegateBool(_) -> Some(IrTypeBool)
    IrNegateInt(_) -> Some(IrTypeInt64)
    IrEcho(expr: inner, ..) -> infer_expr_type(inner, env, cur_mod, ctx)
    IrGetterCall(receiver:, field:) ->
      case
        option.map(
          infer_expr_type(receiver, env, cur_mod, ctx),
          expand_type_alias(_, cur_mod, ctx),
        )
      {
        Some(IrTypeNamed(module:, name:, args:, ..)) -> {
          let target_mod = case module {
            "" -> cur_mod
            m -> m
          }
          case dict.get(ctx.all_getters, #(target_mod, name, field)) {
            Ok(sig) -> {
              let subst =
                list.zip(sig.type_params, args)
                |> dict.from_list
              Some(apply_ir_subst(sig.return_type, subst))
            }
            Error(_) -> None
          }
        }
        _ -> None
      }
    IrCall(function:, args:) ->
      infer_call_expr_type(function, args, env, cur_mod, ctx)
    IrBlock(stmts) -> infer_stmts_tail_type(stmts, env, cur_mod, ctx)
    IrMatch(subjects:, clauses:) -> {
      let subj_tys =
        list.map(subjects, fn(s) { infer_expr_type(s, env, cur_mod, ctx) })
      list.find_map(clauses, fn(c) {
        let c_env = case c.patterns {
          [first_alt, ..] ->
            list.fold(list.zip(first_alt, subj_tys), env, fn(e, pair) {
              case pair.1 {
                Some(ty) -> bind_pattern_types(pair.0, ty, cur_mod, ctx, e)
                None -> e
              }
            })
          [] -> env
        }
        let c_env2 =
          list.fold(c.prefix_bindings, c_env, fn(e, b) {
            case infer_expr_type(b.1, e, cur_mod, ctx) {
              Some(ty) -> dict.insert(e, b.0, ty)
              None -> e
            }
          })
        case infer_expr_type(c.body, c_env2, cur_mod, ctx) {
          Some(ty) -> Ok(ty)
          None -> Error(Nil)
        }
      })
      |> option.from_result
    }
    IrForLoop(bindings:, body:) -> {
      let env1 =
        list.fold(bindings, env, fn(e, b) {
          case infer_expr_type(b.1, env, cur_mod, ctx) {
            Some(ty) -> dict.insert(e, b.0, ty)
            None -> e
          }
        })
      infer_for_break_type(body, env1, cur_mod, ctx)
    }
    IrBreak(inner) -> infer_expr_type(inner, env, cur_mod, ctx)
    IrFn(params:, return_type:, body:) ->
      case list.all(params, fn(p) { option.is_some(p.param_type) }) {
        False -> None
        True -> {
          let p_tys =
            list.filter_map(params, fn(p) {
              option.to_result(p.param_type, Nil)
            })
          let ret = case return_type {
            Some(r) -> Some(r)
            None -> {
              let fn_env =
                list.fold(params, env, fn(e, p) {
                  case p.param_type {
                    Some(pt) -> dict.insert(e, p.name, pt)
                    None -> e
                  }
                })
              infer_stmts_tail_type(body, fn_env, cur_mod, ctx)
            }
          }
          option.map(ret, fn(r) { IrTypeFn(p_tys, r) })
        }
      }
    _ -> None
  }
}

pub fn freshen_fn_type(f: IrFunction) -> IrType {
  let subst =
    list.fold(f.type_params, dict.new(), fn(acc, tp) {
      dict.insert(acc, tp, IrTypeVar("__free_" <> tp))
    })
  IrTypeFn(
    params: list.map(f.params, fn(p) { apply_ir_subst(p.param_type, subst) }),
    return: apply_ir_subst(f.return_type, subst),
  )
}

fn infer_call_expr_type(
  function: IrExpr,
  args: List(IrCallArg),
  env: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Option(IrType) {
  case function {
    IrVar(name) ->
      case dict.get(env, name) {
        Ok(IrTypeFn(return: ret, ..)) -> Some(ret)
        Ok(_) -> None
        Error(_) ->
          case dict.get(ctx.all_fns, #(cur_mod, name)) {
            Ok(callee) -> instantiate_fn_return(callee, args, env, cur_mod, ctx)
            Error(_) -> None
          }
      }
    IrModuleRef(target_module:, symbol:, ..) ->
      case dict.get(ctx.all_fns, #(target_module, symbol)) {
        Ok(callee) -> instantiate_fn_return(callee, args, env, cur_mod, ctx)
        Error(_) -> None
      }
    IrConstructor(target_module:, name:, ..) -> {
      let ctor_mod = option.unwrap(target_module, cur_mod)
      case name, args {
        "Ok", [ok_arg] ->
          option.map(infer_expr_type(ok_arg.value, env, cur_mod, ctx), fn(t) {
            IrTypeResult(t, IrTypeVar("__free_err"))
          })
        "Err", [err_arg] ->
          option.map(infer_expr_type(err_arg.value, env, cur_mod, ctx), fn(t) {
            IrTypeResult(IrTypeVar("__free_ok"), t)
          })
        _, _ ->
          case lookup_ctor(ctx, ctor_mod, name) {
            Some(#(td, variant)) -> {
              let field_params =
                list.map(variant.fields, fn(f) {
                  IrParam(
                    label: f.label,
                    name: option.unwrap(f.label, "_"),
                    param_type: f.field_type,
                  )
                })
              let ordered = align_ir_call_args(field_params, args)
              let subst =
                unify_aligned_args(field_params, ordered, env, cur_mod, ctx)
              let raw_ret =
                IrTypeNamed(
                  module_alias: None,
                  package: "",
                  module: ctor_mod,
                  name: td.name,
                  args: list.map(td.type_params, IrTypeVar),
                )
              Some(apply_call_ret_subst(raw_ret, subst))
            }
            None -> None
          }
      }
    }
    _ ->
      case infer_expr_type(function, env, cur_mod, ctx) {
        Some(IrTypeFn(return: ret, ..)) -> Some(ret)
        _ -> None
      }
  }
}

fn instantiate_fn_return(
  callee: IrFunction,
  args: List(IrCallArg),
  env: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Option(IrType) {
  let ordered = align_ir_call_args(callee.params, args)
  let subst = unify_aligned_args(callee.params, ordered, env, cur_mod, ctx)
  Some(apply_call_ret_subst(callee.return_type, subst))
}

pub fn infer_stmts_tail_type(
  stmts: List(IrStmt),
  env: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Option(IrType) {
  case stmts {
    [] -> None
    [IrStmtExpr(e)] -> infer_expr_type(e, env, cur_mod, ctx)
    [IrStmtLet(pattern:, annotation:, value:)] -> {
      let _ = pattern
      case annotation {
        Some(t) -> Some(t)
        None -> infer_expr_type(value, env, cur_mod, ctx)
      }
    }
    [IrStmtGuard(value:, ..)] -> infer_expr_type(value, env, cur_mod, ctx)
    [stmt, ..rest] -> {
      let next_env = case stmt {
        IrStmtLet(pattern:, annotation:, value:) -> {
          let val_ty = case annotation {
            Some(t) -> Some(t)
            None -> infer_expr_type(value, env, cur_mod, ctx)
          }
          case val_ty {
            Some(ty) -> bind_pattern_types(pattern, ty, cur_mod, ctx, env)
            None -> env
          }
        }
        IrStmtGuard(value:, pattern:, post_bindings:, ..) -> {
          let env1 = case infer_expr_type(value, env, cur_mod, ctx) {
            Some(ty) -> bind_pattern_types(pattern, ty, cur_mod, ctx, env)
            None -> env
          }
          list.fold(post_bindings, env1, fn(e, b) {
            case infer_expr_type(b.1, e, cur_mod, ctx) {
              Some(ty) -> dict.insert(e, b.0, ty)
              None -> e
            }
          })
        }
        IrStmtAssert(_, _) | IrStmtExpr(_) -> env
      }
      infer_stmts_tail_type(rest, next_env, cur_mod, ctx)
    }
  }
}

pub fn infer_for_break_type(
  stmts: List(IrStmt),
  env: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Option(IrType) {
  case stmts {
    [] -> None
    [stmt, ..rest] -> {
      let found = case stmt {
        IrStmtExpr(IrBreak(val)) -> infer_expr_type(val, env, cur_mod, ctx)
        IrStmtExpr(IrMatch(subjects:, clauses:)) -> {
          let subj_tys =
            list.map(subjects, fn(s) { infer_expr_type(s, env, cur_mod, ctx) })
          list.find_map(clauses, fn(c) {
            let c_env = case c.patterns {
              [first_alt, ..] ->
                list.fold(list.zip(first_alt, subj_tys), env, fn(e, pair) {
                  case pair.1 {
                    Some(ty) -> bind_pattern_types(pair.0, ty, cur_mod, ctx, e)
                    None -> e
                  }
                })
              [] -> env
            }
            case infer_expr_type(c.body, c_env, cur_mod, ctx) {
              Some(ty) -> Ok(ty)
              None -> Error(Nil)
            }
          })
          |> option.from_result
        }
        _ -> None
      }
      case found {
        Some(_) -> found
        None -> {
          let next_env = case stmt {
            IrStmtLet(pattern:, annotation:, value:) -> {
              let val_ty = case annotation {
                Some(t) -> Some(t)
                None -> infer_expr_type(value, env, cur_mod, ctx)
              }
              case val_ty {
                Some(ty) -> bind_pattern_types(pattern, ty, cur_mod, ctx, env)
                None -> env
              }
            }
            _ -> env
          }
          infer_for_break_type(rest, next_env, cur_mod, ctx)
        }
      }
    }
  }
}

pub fn bind_pattern_types(
  pat: IrPattern,
  ty: IrType,
  cur_mod: String,
  ctx: AnalyzeCtx,
  env: Dict(String, IrType),
) -> Dict(String, IrType) {
  let expanded_ty = expand_type_alias(ty, cur_mod, ctx)
  case pat, expanded_ty {
    IrPatVar(name), _ -> dict.insert(env, name, ty)
    IrPatAs(inner, alias), _ ->
      bind_pattern_types(inner, ty, cur_mod, ctx, dict.insert(env, alias, ty))
    IrPatTuple(pats), IrTypeTuple(tys) ->
      list.fold(list.zip(pats, tys), env, fn(e, pair) {
        bind_pattern_types(pair.0, pair.1, cur_mod, ctx, e)
      })
    IrPatVariant(constructor: "Cons", args: [h_arg, t_arg], ..), IrTypeList(in_)
    ->
      env
      |> bind_pattern_types(h_arg.pattern, in_, cur_mod, ctx, _)
      |> bind_pattern_types(t_arg.pattern, IrTypeList(in_), cur_mod, ctx, _)
    IrPatVariant(constructor: "Ok", args: [ok_arg], ..), IrTypeResult(ok_t, _)
    -> bind_pattern_types(ok_arg.pattern, ok_t, cur_mod, ctx, env)
    IrPatVariant(constructor: "Err", args: [err_arg], ..),
      IrTypeResult(_, err_t)
    -> bind_pattern_types(err_arg.pattern, err_t, cur_mod, ctx, env)
    IrPatVariant(target_module:, constructor:, args:, ..),
      IrTypeNamed(module: ty_mod, name: ty_name, args: ty_args, ..)
    -> {
      let ctor_mod = option.unwrap(target_module, cur_mod)
      let resolved_ty_mod = case ty_mod {
        "" -> cur_mod
        m -> m
      }
      case lookup_ctor(ctx, ctor_mod, constructor) {
        Some(#(td, variant))
          if ctor_mod == resolved_ty_mod
          && { td.name == ty_name || td.unmangled_name == ty_name }
        -> {
          let subst =
            list.zip(td.type_params, ty_args)
            |> dict.from_list
          bind_variant_pat_args(args, variant.fields, subst, cur_mod, ctx, env)
        }
        _ -> env
      }
    }
    _, _ -> env
  }
}

fn bind_variant_pat_args(
  pat_args: List(IrPatArg),
  fields: List(ir.IrVariantField),
  subst: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
  env: Dict(String, IrType),
) -> Dict(String, IrType) {
  let #(labelled, rev_pos) =
    list.fold(pat_args, #(dict.new(), []), fn(acc, arg) {
      let #(lm, pos) = acc
      case arg.label {
        Some(lbl) -> #(dict.insert(lm, lbl, arg.pattern), pos)
        None -> #(lm, [arg.pattern, ..pos])
      }
    })
  let #(next_env, _) =
    list.fold(fields, #(env, list.reverse(rev_pos)), fn(st, fld) {
      let #(e, pos_q) = st
      let fld_ty = apply_ir_subst(fld.field_type, subst)
      let matched_pat = case fld.label, fld.unmangled_label {
        Some(lbl), _ ->
          case dict.get(labelled, lbl) {
            Ok(p) -> #(Some(p), pos_q)
            Error(_) ->
              case fld.unmangled_label {
                Some(ul) ->
                  case dict.get(labelled, ul) {
                    Ok(p) -> #(Some(p), pos_q)
                    Error(_) -> pop_positional(pos_q)
                  }
                None -> pop_positional(pos_q)
              }
          }
        None, Some(ul) ->
          case dict.get(labelled, ul) {
            Ok(p) -> #(Some(p), pos_q)
            Error(_) -> pop_positional(pos_q)
          }
        None, None -> pop_positional(pos_q)
      }
      case matched_pat.0 {
        Some(pat) -> #(
          bind_pattern_types(pat, fld_ty, cur_mod, ctx, e),
          matched_pat.1,
        )
        None -> #(e, matched_pat.1)
      }
    })
  next_env
}

fn pop_positional(
  pos_q: List(IrPattern),
) -> #(Option(IrPattern), List(IrPattern)) {
  case pos_q {
    [p, ..rest] -> #(Some(p), rest)
    [] -> #(None, [])
  }
}

pub fn bind_fn_param_types_opt(
  params: List(ir.IrFnParam),
  expected: List(Option(IrType)),
  env: Dict(String, IrType),
) -> Dict(String, IrType) {
  case params {
    [] -> env
    [p, ..rest_ps] -> {
      let #(exp_opt, rest_exp) = case expected {
        [e, ..re] -> #(e, re)
        [] -> #(None, [])
      }
      let next_env = case option.or(p.param_type, exp_opt) {
        Some(ty) -> dict.insert(env, p.name, ty)
        None -> env
      }
      bind_fn_param_types_opt(rest_ps, rest_exp, next_env)
    }
  }
}

// -----------------------------------------------------------------------------
// Unification, substitution, and lookup helpers
// -----------------------------------------------------------------------------

pub fn align_ir_call_args(
  params: List(IrParam),
  args: List(IrCallArg),
) -> List(Option(IrExpr)) {
  let #(labelled, rev_pos) =
    list.fold(args, #(dict.new(), []), fn(st, a) {
      let #(lm, pos) = st
      case a.label {
        Some(lbl) -> #(dict.insert(lm, lbl, a.value), pos)
        None -> #(lm, [a.value, ..pos])
      }
    })
  let #(rev_out, _) =
    list.fold(params, #([], list.reverse(rev_pos)), fn(st, p) {
      let #(out, pos_q) = st
      case p.label {
        Some(lbl) ->
          case dict.get(labelled, lbl) {
            Ok(v) -> #([Some(v), ..out], pos_q)
            Error(_) ->
              case pos_q {
                [v, ..rest] -> #([Some(v), ..out], rest)
                [] -> #([None, ..out], pos_q)
              }
          }
        None ->
          case pos_q {
            [v, ..rest] -> #([Some(v), ..out], rest)
            [] -> #([None, ..out], pos_q)
          }
      }
    })
  list.reverse(rev_out)
}

pub fn unify_ir_types(
  pattern_ty: IrType,
  concrete_ty: IrType,
  cur_mod: String,
  ctx: AnalyzeCtx,
  subst: Dict(String, IrType),
) -> Dict(String, IrType) {
  let pat_exp =
    expand_type_alias(pattern_ty, cur_mod, ctx)
    |> canonicalize_builtin_external(cur_mod, ctx)
  let con_exp =
    expand_type_alias(concrete_ty, cur_mod, ctx)
    |> canonicalize_builtin_external(cur_mod, ctx)
  case pat_exp, con_exp {
    IrTypeVar(v), _ ->
      case is_free_var(v) {
        True -> subst
        False ->
          case con_exp {
            IrTypeVar(cv) ->
              case is_free_var(cv) {
                True -> subst
                False -> insert_or_merge_subst(subst, v, con_exp, cur_mod, ctx)
              }
            _ -> insert_or_merge_subst(subst, v, con_exp, cur_mod, ctx)
          }
      }
    IrTypeList(p_in), IrTypeList(c_in) ->
      unify_ir_types(p_in, c_in, cur_mod, ctx, subst)
    IrTypeResult(po, pe), IrTypeResult(co, ce) ->
      unify_ir_types(
        pe,
        ce,
        cur_mod,
        ctx,
        unify_ir_types(po, co, cur_mod, ctx, subst),
      )
    IrTypeTuple(ps), IrTypeTuple(cs) ->
      list.fold(list.zip(ps, cs), subst, fn(s, pair) {
        unify_ir_types(pair.0, pair.1, cur_mod, ctx, s)
      })
    IrTypeFn(pp, pr), IrTypeFn(cp, cr) -> {
      let s1 =
        list.fold(list.zip(pp, cp), subst, fn(s, pair) {
          unify_ir_types(pair.0, pair.1, cur_mod, ctx, s)
        })
      unify_ir_types(pr, cr, cur_mod, ctx, s1)
    }
    IrTypeNamed(module: pm, name: pn, args: pas, ..),
      IrTypeNamed(module: cm, name: cn, args: cas, ..)
    ->
      case same_named_type(pm, pn, cm, cn, cur_mod, ctx) {
        True ->
          list.fold(list.zip(pas, cas), subst, fn(s, pair) {
            unify_ir_types(pair.0, pair.1, cur_mod, ctx, s)
          })
        False -> subst
      }
    _, _ -> subst
  }
}

fn normalize_ext_pkg(pkg: String) -> String {
  case pkg {
    "" | "builtin" -> "moonbitlang/core/builtin"
    other -> other
  }
}

fn same_named_type(
  pm: String,
  pn: String,
  cm: String,
  cn: String,
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Bool {
  let res_pm = case pm {
    "" -> cur_mod
    m -> m
  }
  let res_cm = case cm {
    "" -> cur_mod
    m -> m
  }
  case res_pm == res_cm && pn == cn {
    True -> True
    False ->
      case
        lookup_external_type(res_pm, pn, ctx),
        lookup_external_type(res_cm, cn, ctx)
      {
        Some(ext1), Some(ext2) ->
          normalize_ext_pkg(ext1.package) == normalize_ext_pkg(ext2.package)
          && ext1.type_name == ext2.type_name
        _, _ -> False
      }
  }
}

fn canonicalize_builtin_external(
  ty: IrType,
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> IrType {
  case ty {
    IrTypeNamed(module:, name:, args: [], ..) -> {
      let res_mod = case module {
        "" -> cur_mod
        m -> m
      }
      case lookup_external_type(res_mod, name, ctx) {
        Some(ext) ->
          case normalize_ext_pkg(ext.package), ext.type_name {
            "moonbitlang/core/builtin", "String"
            | "moonbitlang/core/builtin", "StringView"
            -> IrTypeString
            "moonbitlang/core/builtin", "Int64" -> IrTypeInt64
            "moonbitlang/core/builtin", "Double" -> IrTypeDouble
            "moonbitlang/core/builtin", "Bool" -> IrTypeBool
            "moonbitlang/core/builtin", "Unit" -> IrTypeUnit
            _, _ -> ty
          }
        None -> ty
      }
    }
    _ -> ty
  }
}

fn is_free_var(name: String) -> Bool {
  case name {
    "__free_" <> _ -> True
    _ -> False
  }
}

fn insert_or_merge_subst(
  subst: Dict(String, IrType),
  key: String,
  val: IrType,
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Dict(String, IrType) {
  case dict.get(subst, key) {
    Ok(existing) ->
      dict.insert(subst, key, merge_bound_type(existing, val, cur_mod, ctx))
    Error(_) -> dict.insert(subst, key, val)
  }
}

fn merge_bound_type(
  existing: IrType,
  new: IrType,
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> IrType {
  case existing, new {
    IrTypeVar(v), _ ->
      case is_free_var(v) {
        True -> new
        False -> existing
      }
    IrTypeList(e_in), IrTypeList(n_in) ->
      IrTypeList(merge_bound_type(e_in, n_in, cur_mod, ctx))
    IrTypeResult(eo, ee), IrTypeResult(no, ne) ->
      IrTypeResult(
        merge_bound_type(eo, no, cur_mod, ctx),
        merge_bound_type(ee, ne, cur_mod, ctx),
      )
    IrTypeTuple(es), IrTypeTuple(ns) ->
      case list.length(es) == list.length(ns) {
        True ->
          IrTypeTuple(
            list.map(list.zip(es, ns), fn(p) {
              merge_bound_type(p.0, p.1, cur_mod, ctx)
            }),
          )
        False -> existing
      }
    IrTypeFn(ep, er), IrTypeFn(np, nr) ->
      case list.length(ep) == list.length(np) {
        True ->
          IrTypeFn(
            list.map(list.zip(ep, np), fn(p) {
              merge_bound_type(p.0, p.1, cur_mod, ctx)
            }),
            merge_bound_type(er, nr, cur_mod, ctx),
          )
        False -> existing
      }
    IrTypeNamed(module: em, name: en, args: eas, ..),
      IrTypeNamed(module: nm, name: nn, args: nas, ..)
    ->
      case same_named_type(em, en, nm, nn, cur_mod, ctx) {
        True ->
          case list.length(eas) == list.length(nas) {
            True ->
              IrTypeNamed(
                ..existing,
                args: list.map(list.zip(eas, nas), fn(p) {
                  merge_bound_type(p.0, p.1, cur_mod, ctx)
                }),
              )
            False -> existing
          }
        False -> existing
      }
    _, _ -> existing
  }
}

pub fn expand_type_alias(
  ty: IrType,
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> IrType {
  expand_type_alias_loop(ty, cur_mod, ctx, set.new())
}

fn expand_type_alias_loop(
  ty: IrType,
  cur_mod: String,
  ctx: AnalyzeCtx,
  visited: Set(#(String, String)),
) -> IrType {
  case ty {
    IrTypeNamed(module:, name:, args:, ..) -> {
      let resolved_mod = case module {
        "" -> cur_mod
        m -> m
      }
      let key = #(resolved_mod, name)
      case set.contains(visited, key) {
        True -> ty
        False ->
          case dict.get(ctx.all_type_aliases, key) {
            Ok(ta) ->
              case list.length(ta.type_params) == list.length(args) {
                False -> ty
                True -> {
                  let subst =
                    list.zip(ta.type_params, args)
                    |> dict.from_list
                  let expanded = apply_ir_subst(ta.aliased, subst)
                  expand_type_alias_loop(
                    expanded,
                    resolved_mod,
                    ctx,
                    set.insert(visited, key),
                  )
                }
              }
            Error(_) -> ty
          }
      }
    }
    _ -> ty
  }
}

pub fn apply_call_ret_subst(ty: IrType, subst: Dict(String, IrType)) -> IrType {
  case ty {
    IrTypeVar(v) ->
      case dict.get(subst, v) {
        Ok(t) -> t
        Error(_) ->
          case is_free_var(v) {
            True -> ty
            False -> IrTypeVar("__free_" <> v)
          }
      }
    IrTypeList(inner) -> IrTypeList(apply_call_ret_subst(inner, subst))
    IrTypeResult(ok_t, err_t) ->
      IrTypeResult(
        apply_call_ret_subst(ok_t, subst),
        apply_call_ret_subst(err_t, subst),
      )
    IrTypeTuple(els) ->
      IrTypeTuple(list.map(els, apply_call_ret_subst(_, subst)))
    IrTypeFn(ps, r) ->
      IrTypeFn(
        list.map(ps, apply_call_ret_subst(_, subst)),
        apply_call_ret_subst(r, subst),
      )
    IrTypeNamed(args:, ..) ->
      IrTypeNamed(..ty, args: list.map(args, apply_call_ret_subst(_, subst)))
    _ -> ty
  }
}

pub fn apply_ir_subst(ty: IrType, subst: Dict(String, IrType)) -> IrType {
  case ty {
    IrTypeVar(v) ->
      case dict.get(subst, v) {
        Ok(t) -> t
        Error(_) -> ty
      }
    IrTypeList(inner) -> IrTypeList(apply_ir_subst(inner, subst))
    IrTypeResult(ok_t, err_t) ->
      IrTypeResult(apply_ir_subst(ok_t, subst), apply_ir_subst(err_t, subst))
    IrTypeTuple(els) -> IrTypeTuple(list.map(els, apply_ir_subst(_, subst)))
    IrTypeFn(ps, r) ->
      IrTypeFn(list.map(ps, apply_ir_subst(_, subst)), apply_ir_subst(r, subst))
    IrTypeNamed(args:, ..) ->
      IrTypeNamed(..ty, args: list.map(args, apply_ir_subst(_, subst)))
    _ -> ty
  }
}

pub fn collect_type_var_names(ty: IrType, acc: Set(String)) -> Set(String) {
  case ty {
    IrTypeVar(v) -> set.insert(acc, v)
    IrTypeList(inner) -> collect_type_var_names(inner, acc)
    IrTypeResult(ok_t, err_t) ->
      collect_type_var_names(err_t, collect_type_var_names(ok_t, acc))
    IrTypeTuple(els) ->
      list.fold(els, acc, fn(s, e) { collect_type_var_names(e, s) })
    IrTypeFn(ps, r) ->
      collect_type_var_names(
        r,
        list.fold(ps, acc, fn(s, p) { collect_type_var_names(p, s) }),
      )
    IrTypeNamed(args:, ..) ->
      list.fold(args, acc, fn(s, a) { collect_type_var_names(a, s) })
    _ -> acc
  }
}

pub fn collect_inspectable_type_vars(
  ty: IrType,
  cur_mod: String,
  ctx: AnalyzeCtx,
  acc: Set(String),
) -> Set(String) {
  case expand_type_alias(ty, cur_mod, ctx) {
    IrTypeVar(v) -> set.insert(acc, v)
    IrTypeList(inner) -> collect_inspectable_type_vars(inner, cur_mod, ctx, acc)
    IrTypeResult(ok_t, err_t) ->
      collect_inspectable_type_vars(
        err_t,
        cur_mod,
        ctx,
        collect_inspectable_type_vars(ok_t, cur_mod, ctx, acc),
      )
    IrTypeTuple(els) ->
      list.fold(els, acc, fn(s, e) {
        collect_inspectable_type_vars(e, cur_mod, ctx, s)
      })
    IrTypeFn(_, _) -> acc
    IrTypeNamed(module:, name:, args:, ..) -> {
      let resolved_mod = case module {
        "" -> cur_mod
        m -> m
      }
      case is_uninspectable_external(resolved_mod, name, ctx) {
        True -> acc
        False ->
          list.fold(args, acc, fn(s, a) {
            collect_inspectable_type_vars(a, cur_mod, ctx, s)
          })
      }
    }
    _ -> acc
  }
}

pub fn is_uninspectable_external(
  module: String,
  name: String,
  ctx: AnalyzeCtx,
) -> Bool {
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

pub fn lookup_external_type(
  module: String,
  name: String,
  ctx: AnalyzeCtx,
) -> Option(ExternalType) {
  case dict.get(ctx.all_types, #(module, name)) {
    Ok(td) -> td.external_type
    Error(_) ->
      case ctx.table {
        None -> None
        Some(tbl) ->
          case dict.get(tbl.modules, module) {
            Error(_) -> None
            Ok(ms) ->
              case dict.get(ms.types, name) {
                Ok(ti) -> ti.external_type
                Error(_) ->
                  dict.values(ms.types)
                  |> list.find(fn(ti) {
                    mangle.mangle_type_name(ti.name) == name
                  })
                  |> option.from_result
                  |> option.then(fn(ti) { ti.external_type })
              }
          }
      }
  }
}

pub fn is_nullary_multi_variant_ctor(
  expr: IrExpr,
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Bool {
  case expr {
    IrList(elements: [], tail: None) -> True
    IrConstructor(target_module:, name:, ..) -> {
      let ctor_mod = option.unwrap(target_module, cur_mod)
      case lookup_ctor(ctx, ctor_mod, name) {
        Some(#(td, variant)) ->
          variant.fields == [] && list.length(td.variants) >= 2
        None ->
          case ctx.table {
            None -> False
            Some(tbl) ->
              case dict.get(tbl.modules, ctor_mod) {
                Error(_) -> False
                Ok(ms) ->
                  case dict.get(ms.constructors, name) {
                    Error(_) -> False
                    Ok(ctor) ->
                      case ctor.fields, dict.get(ms.types, ctor.type_name) {
                        [], Ok(ti) -> list.length(ti.variants) >= 2
                        _, _ -> False
                      }
                  }
              }
          }
      }
    }
    _ -> False
  }
}

pub fn lookup_ctor(
  ctx: AnalyzeCtx,
  mod_name: String,
  ctor_name: String,
) -> Option(#(IrTypeDef, IrVariant)) {
  dict.get(ctx.all_ctors, #(mod_name, ctor_name)) |> option.from_result
}

pub fn list_at_idx(items: List(a), index: Int) -> Option(a) {
  case items, index {
    [], _ -> None
    [head, ..], 0 -> Some(head)
    [_, ..tail], i if i > 0 -> list_at_idx(tail, i - 1)
    _, _ -> None
  }
}
