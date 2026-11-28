import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import index/symbol_table.{type SymbolTable}
import lower/ir.{
  type IrCallArg, type IrExpr, type IrFunction, type IrModule, type IrStmt,
  type IrType, IrAbort, IrBinOp, IrBitString, IrBlock, IrBool, IrBreak, IrCall,
  IrConstructor, IrContinue, IrEcho, IrEq, IrFloat, IrFn, IrForLoop,
  IrGetterCall, IrInt, IrList, IrMatch, IrModuleRef, IrNegateBool, IrNegateInt,
  IrNotEq, IrParam, IrPatVar, IrStmtAssert, IrStmtExpr, IrStmtGuard, IrStmtLet,
  IrString, IrTuple, IrTupleIndex, IrTypeBitArray, IrTypeBool, IrTypeDouble,
  IrTypeFn, IrTypeInt64, IrTypeList, IrTypeNamed, IrTypeResult, IrTypeString,
  IrTypeTuple, IrTypeUnit, IrTypeVar, IrUnit, IrVar,
}

import lower/ir_util
import moonbit/ffi_meta.{type FfiMetadata, type MbtType}
import project/prepass.{ExternalType, PackageCall, Patched}

import emit/trait_infer.{
  type AnalyzeCtx, AnalyzeCtx, GetterSig, align_ir_call_args,
  apply_call_ret_subst, bind_fn_param_types_opt, bind_pattern_types,
  collect_inspectable_type_vars, collect_type_var_names, expand_type_alias,
  freshen_ir_type, infer_expr_type, is_nullary_multi_variant_ctor, list_at_idx,
  lookup_ctor, lookup_external_type, unify_aligned_args, unify_ir_types,
}

/// Generic trait bounds inferred for a single top-level function.
pub type FnTraitBounds {
  FnTraitBounds(
    eq_vars: Set(String),
    to_dynamic_vars: Set(String),
    inspect_vars: Set(String),
    show_vars: Set(String),
  )
}

/// Whole-project trait bounds and `Eq`-`Hash` propagation results.
pub type ProjectTraitBounds {
  ProjectTraitBounds(
    fn_bounds: Dict(#(String, String), FnTraitBounds),
    type_eq_hash_params: Dict(#(String, String), Set(Int)),
    all_fns: Dict(#(String, String), IrFunction),
    all_consts: Dict(#(String, String), IrType),
  )
}

/// Empty `FnTraitBounds` value.
pub fn empty_fn_bounds() -> FnTraitBounds {
  FnTraitBounds(
    eq_vars: set.new(),
    to_dynamic_vars: set.new(),
    inspect_vars: set.new(),
    show_vars: set.new(),
  )
}

/// Look up inferred trait bounds for `(module_name, fn_name)`.
pub fn lookup_fn_bounds(
  bounds: ProjectTraitBounds,
  module_name: String,
  fn_name: String,
) -> FnTraitBounds {
  case dict.get(bounds.fn_bounds, #(module_name, fn_name)) {
    Ok(fb) -> fb
    Error(_) -> empty_fn_bounds()
  }
}

/// Return True when `param_idx` is a pure inspect sink: its type is a bare
/// `IrTypeVar(v)` present in `bounds.inspect_vars`, and `v` neither escapes
/// into `f.return_type` nor appears in any other parameter of `f`.
pub fn param_is_pure_inspect_sink(
  f: IrFunction,
  param_idx: Int,
  bounds: FnTraitBounds,
) -> Bool {
  case list_at_idx(f.params, param_idx) {
    Some(IrParam(param_type: IrTypeVar(tp), ..)) ->
      case set.contains(bounds.inspect_vars, tp) {
        False -> False
        True -> {
          let ret_vars = collect_type_var_names(f.return_type, set.new())
          let other_vars =
            list.index_fold(f.params, set.new(), fn(acc, p, idx) {
              case idx == param_idx {
                True -> acc
                False -> collect_type_var_names(p.param_type, acc)
              }
            })
          !set.contains(ret_vars, tp) && !set.contains(other_vars, tp)
        }
      }
    _ -> False
  }
}

/// Infer trait bounds and `Eq`->`Hash` type-parameter dependencies across all modules.
pub fn analyze_project(
  modules: List(IrModule),
  table: Option(SymbolTable),
  ffi_metadata: FfiMetadata,
) -> ProjectTraitBounds {
  let ctx = build_analyze_ctx(modules, table, ffi_metadata)
  let type_eq_hash_params = compute_type_eq_hash_params(modules, ctx)
  let initial_bounds = seed_all_fn_bounds(modules, ctx)
  let fn_bounds = propagate_fixpoint(modules, ctx, initial_bounds, 1024)
  ProjectTraitBounds(
    fn_bounds:,
    type_eq_hash_params:,
    all_fns: ctx.all_fns,
    all_consts: ctx.all_consts,
  )
}

fn build_analyze_ctx(
  modules: List(IrModule),
  table: Option(SymbolTable),
  ffi_metadata: FfiMetadata,
) -> AnalyzeCtx {
  let #(
    all_fns,
    all_consts,
    all_types,
    all_type_aliases,
    all_ctors,
    all_getters,
  ) =
    list.fold(
      modules,
      #(dict.new(), dict.new(), dict.new(), dict.new(), dict.new(), dict.new()),
      fn(acc, mod) {
        let #(fns, consts, types, aliases, ctors, getters) = acc
        let next_fns =
          list.fold(mod.functions, fns, fn(m, f) {
            dict.insert(m, #(mod.module_name, f.name), f)
          })
        let next_consts =
          list.fold(mod.constants, consts, fn(m, c) {
            dict.insert(m, #(mod.module_name, c.name), c.value_type)
          })
        let next_types =
          list.fold(mod.types, types, fn(m, td) {
            m
            |> dict.insert(#(mod.module_name, td.name), td)
            |> dict.insert(#(mod.module_name, td.unmangled_name), td)
          })
        let next_aliases =
          list.fold(mod.type_aliases, aliases, fn(m, ta) {
            dict.insert(m, #(mod.module_name, ta.name), ta)
          })
        let next_ctors =
          list.fold(mod.types, ctors, fn(m, td) {
            list.fold(td.variants, m, fn(cm, v) {
              dict.insert(cm, #(mod.module_name, v.name), #(td, v))
            })
          })
        let next_getters =
          list.fold(mod.getters, getters, fn(m, g) {
            let sig =
              GetterSig(type_params: g.type_params, return_type: g.return_type)
            dict.insert(m, #(mod.module_name, g.type_name, g.field_name), sig)
          })
        #(
          next_fns,
          next_consts,
          next_types,
          next_aliases,
          next_ctors,
          next_getters,
        )
      },
    )
  AnalyzeCtx(
    all_fns:,
    all_consts:,
    all_types:,
    all_type_aliases:,
    all_ctors:,
    all_getters:,
    table:,
    ffi_metadata:,
  )
}

// -----------------------------------------------------------------------------
// Stage 1: Compute type parameters requiring `Hash` for `Eq` across types
// -----------------------------------------------------------------------------

fn compute_type_eq_hash_params(
  modules: List(IrModule),
  ctx: AnalyzeCtx,
) -> Dict(#(String, String), Set(Int)) {
  let seeded =
    list.fold(modules, dict.new(), fn(acc, mod) {
      list.fold(mod.types, acc, fn(inner, td) {
        case td.external_type {
          Some(ExternalType(package:, type_name:)) -> {
            let req =
              ffi_meta.eq_requires_hash_params(
                ctx.ffi_metadata,
                package,
                type_name,
              )
            case set.is_empty(req) {
              True -> inner
              False -> dict.insert(inner, #(mod.module_name, td.name), req)
            }
          }
          None -> inner
        }
      })
    })
  iterate_type_eq_hash_params(modules, ctx, seeded, 1024)
}

fn iterate_type_eq_hash_params(
  modules: List(IrModule),
  ctx: AnalyzeCtx,
  cur: Dict(#(String, String), Set(Int)),
  iters_left: Int,
) -> Dict(#(String, String), Set(Int)) {
  case iters_left <= 0 {
    True -> cur
    False -> {
      let #(next, changed) =
        list.fold(modules, #(cur, False), fn(acc, mod) {
          list.fold(mod.types, acc, fn(inner, td) {
            let #(map, ch) = inner
            case td.external_type, td.derive_eq_debug_hash, td.type_params {
              None, True, [_, ..] -> {
                let key = #(mod.module_name, td.name)
                let existing = case dict.get(map, key) {
                  Ok(s) -> s
                  Error(_) -> set.new()
                }
                let used_vars =
                  list.fold(td.variants, set.new(), fn(v_acc, v) {
                    list.fold(v.fields, v_acc, fn(f_acc, fld) {
                      collect_type_hash_vars(
                        fld.field_type,
                        mod.module_name,
                        map,
                        ctx,
                        f_acc,
                      )
                    })
                  })
                let new_indices =
                  list.index_fold(td.type_params, existing, fn(s, tp, idx) {
                    case set.contains(used_vars, tp) {
                      True -> set.insert(s, idx)
                      False -> s
                    }
                  })
                let grew = set.size(new_indices) > set.size(existing)
                let next_map = case set.is_empty(new_indices) {
                  True -> map
                  False -> dict.insert(map, key, new_indices)
                }
                #(next_map, ch || grew)
              }
              _, _, _ -> inner
            }
          })
        })
      case changed {
        True -> iterate_type_eq_hash_params(modules, ctx, next, iters_left - 1)
        False -> next
      }
    }
  }
}

fn collect_type_hash_vars(
  ty: IrType,
  cur_mod: String,
  type_map: Dict(#(String, String), Set(Int)),
  ctx: AnalyzeCtx,
  acc: Set(String),
) -> Set(String) {
  case expand_type_alias(ty, cur_mod, ctx) {
    IrTypeNamed(module:, name:, args:, ..) -> {
      let resolved_mod = case module {
        "" -> cur_mod
        m -> m
      }
      let req_indices = case dict.get(type_map, #(resolved_mod, name)) {
        Ok(s) -> s
        Error(_) ->
          case lookup_external_type(resolved_mod, name, ctx) {
            Some(ext) ->
              ffi_meta.eq_requires_hash_params(
                ctx.ffi_metadata,
                ext.package,
                ext.type_name,
              )
            None -> set.new()
          }
      }
      let after_req =
        list.index_fold(args, acc, fn(s, arg_ty, idx) {
          case set.contains(req_indices, idx) {
            True -> collect_type_var_names(arg_ty, s)
            False -> s
          }
        })
      list.fold(args, after_req, fn(s, arg_ty) {
        collect_type_hash_vars(arg_ty, cur_mod, type_map, ctx, s)
      })
    }
    IrTypeList(inner) ->
      collect_type_hash_vars(inner, cur_mod, type_map, ctx, acc)
    IrTypeResult(ok_t, err_t) ->
      collect_type_hash_vars(
        err_t,
        cur_mod,
        type_map,
        ctx,
        collect_type_hash_vars(ok_t, cur_mod, type_map, ctx, acc),
      )
    IrTypeTuple(els) ->
      list.fold(els, acc, fn(s, e) {
        collect_type_hash_vars(e, cur_mod, type_map, ctx, s)
      })
    IrTypeFn(_, _)
    | IrTypeVar(_)
    | IrTypeInt64
    | IrTypeDouble
    | IrTypeString
    | IrTypeBool
    | IrTypeUnit
    | IrTypeBitArray -> acc
  }
}

// -----------------------------------------------------------------------------
// Stage 2: Seed generic FFI bounds from MoonBit `.mbt` signatures
// -----------------------------------------------------------------------------

fn seed_all_fn_bounds(
  modules: List(IrModule),
  ctx: AnalyzeCtx,
) -> Dict(#(String, String), FnTraitBounds) {
  list.fold(modules, dict.new(), fn(acc, mod) {
    list.fold(mod.functions, acc, fn(inner, f) {
      let key = #(mod.module_name, f.name)
      let seeded = case f.ffi, f.type_params {
        Some(PackageCall(pkg, target_fn)), [_, ..] ->
          case ffi_meta.lookup_function(ctx.ffi_metadata, pkg, target_fn) {
            Some(ext_meta) ->
              extract_ffi_bounds(f, mod.module_name, ext_meta, ctx)
            None -> empty_fn_bounds()
          }
        Some(Patched), [_, ..] -> {
          let meta_opt = case
            ffi_meta.lookup_function(ctx.ffi_metadata, mod.module_name, f.name)
          {
            Some(m) -> Some(m)
            None ->
              ffi_meta.lookup_function(
                ctx.ffi_metadata,
                mod.module_name,
                f.unmangled_name,
              )
          }
          case meta_opt {
            Some(ext_meta) ->
              extract_ffi_bounds(f, mod.module_name, ext_meta, ctx)
            None -> empty_fn_bounds()
          }
        }
        _, _ -> empty_fn_bounds()
      }
      dict.insert(inner, key, seeded)
    })
  })
}

fn extract_ffi_bounds(
  f: IrFunction,
  mod_name: String,
  ext_meta: ffi_meta.ExternalFnMeta,
  ctx: AnalyzeCtx,
) -> FnTraitBounds {
  let param_tys = list.map(f.params, fn(p) { p.param_type })
  let subst0 =
    list.fold(list.zip(ext_meta.param_types, param_tys), dict.new(), fn(s, pr) {
      unify_mbt_ir(pr.0, pr.1, mod_name, ctx, s)
    })
  let subst = case ext_meta.return_type {
    Some(ret_mbt) -> unify_mbt_ir(ret_mbt, f.return_type, mod_name, ctx, subst0)
    None -> subst0
  }
  let allowed = set.from_list(f.type_params)
  let raw =
    list.fold(ext_meta.type_params, empty_fn_bounds(), fn(acc, tp_entry) {
      let #(mbt_tp, traits) = tp_entry
      let matched_ir = dict.get(subst, mbt_tp) |> result.unwrap([])
      let raw_vars =
        list.fold(matched_ir, set.new(), fn(s, t) {
          collect_type_var_names(t, s)
        })
      let inspectable_vars =
        list.fold(matched_ir, set.new(), fn(s, t) {
          collect_inspectable_type_vars(t, mod_name, ctx, s)
        })
      let eq_v = case
        set.contains(traits, "Eq") || set.contains(traits, "Hash")
      {
        True -> set.union(acc.eq_vars, raw_vars)
        False -> acc.eq_vars
      }
      let dyn_v = case set.contains(traits, "ToDynamic") {
        True -> set.union(acc.to_dynamic_vars, raw_vars)
        False -> acc.to_dynamic_vars
      }
      let insp_v = case set.contains(traits, "GleamInspect") {
        True -> set.union(acc.inspect_vars, inspectable_vars)
        False -> acc.inspect_vars
      }
      let show_v = case set.contains(traits, "Show") {
        True -> set.union(acc.show_vars, raw_vars)
        False -> acc.show_vars
      }
      FnTraitBounds(
        eq_vars: eq_v,
        to_dynamic_vars: dyn_v,
        inspect_vars: insp_v,
        show_vars: show_v,
      )
    })
  clamp_bounds(raw, allowed)
}

fn unify_mbt_ir(
  mbt_ty: MbtType,
  ir_ty: IrType,
  cur_mod: String,
  ctx: AnalyzeCtx,
  subst: Dict(String, List(IrType)),
) -> Dict(String, List(IrType)) {
  let expanded = expand_type_alias(ir_ty, cur_mod, ctx)
  case mbt_ty, expanded {
    ffi_meta.MbtVar(v), _ -> {
      let prev = dict.get(subst, v) |> result.unwrap([])
      dict.insert(subst, v, [expanded, ..prev])
    }
    ffi_meta.MbtNamed("GList", [m_in]), IrTypeList(ir_in) ->
      unify_mbt_ir(m_in, ir_in, cur_mod, ctx, subst)
    ffi_meta.MbtNamed("Result", [m_ok, m_err]), IrTypeResult(ir_ok, ir_err) ->
      unify_mbt_ir(
        m_err,
        ir_err,
        cur_mod,
        ctx,
        unify_mbt_ir(m_ok, ir_ok, cur_mod, ctx, subst),
      )
    ffi_meta.MbtNamed("Tuple1", [m_el]), IrTypeTuple([ir_el]) ->
      unify_mbt_ir(m_el, ir_el, cur_mod, ctx, subst)
    ffi_meta.MbtTuple(m_els), IrTypeTuple(ir_els) ->
      list.fold(list.zip(m_els, ir_els), subst, fn(s, pr) {
        unify_mbt_ir(pr.0, pr.1, cur_mod, ctx, s)
      })
    ffi_meta.MbtFn(m_ps, m_r), IrTypeFn(ir_ps, ir_r) -> {
      let s1 =
        list.fold(list.zip(m_ps, ir_ps), subst, fn(s, pr) {
          unify_mbt_ir(pr.0, pr.1, cur_mod, ctx, s)
        })
      unify_mbt_ir(m_r, ir_r, cur_mod, ctx, s1)
    }
    ffi_meta.MbtNamed(_, m_args), IrTypeNamed(args: ir_args, ..) ->
      list.fold(list.zip(m_args, ir_args), subst, fn(s, pr) {
        unify_mbt_ir(pr.0, pr.1, cur_mod, ctx, s)
      })
    _, _ -> subst
  }
}

// -----------------------------------------------------------------------------
// Stage 3: Cross-module fixpoint propagation
// -----------------------------------------------------------------------------

fn propagate_fixpoint(
  modules: List(IrModule),
  ctx: AnalyzeCtx,
  cur: Dict(#(String, String), FnTraitBounds),
  iters_left: Int,
) -> Dict(#(String, String), FnTraitBounds) {
  case iters_left <= 0 {
    True -> cur
    False -> {
      let #(next, changed) =
        list.fold(modules, #(cur, False), fn(acc, mod) {
          let const_env = build_module_const_env(mod)
          list.fold(mod.functions, acc, fn(inner, f) {
            let #(bmap, ch) = inner
            case f.ffi, f.type_params {
              None, [_, ..] -> {
                let key = #(mod.module_name, f.name)
                let existing = case dict.get(bmap, key) {
                  Ok(b) -> b
                  Error(_) -> empty_fn_bounds()
                }
                let allowed = set.from_list(f.type_params)
                let env0 =
                  list.fold(f.params, const_env, fn(e, p) {
                    dict.insert(e, p.name, p.param_type)
                  })
                let computed =
                  walk_stmts(
                    f.body,
                    env0,
                    dict.new(),
                    mod.module_name,
                    f,
                    Some(f.return_type),
                    ctx,
                    bmap,
                    allowed,
                    existing,
                  )
                let clamped = clamp_bounds(computed, allowed)
                let grew = bounds_grew(existing, clamped)
                #(dict.insert(bmap, key, clamped), ch || grew)
              }
              _, _ -> inner
            }
          })
        })
      case changed {
        True -> propagate_fixpoint(modules, ctx, next, iters_left - 1)
        False -> next
      }
    }
  }
}

fn bounds_grew(old: FnTraitBounds, new: FnTraitBounds) -> Bool {
  set.size(new.eq_vars) > set.size(old.eq_vars)
  || set.size(new.to_dynamic_vars) > set.size(old.to_dynamic_vars)
  || set.size(new.inspect_vars) > set.size(old.inspect_vars)
  || set.size(new.show_vars) > set.size(old.show_vars)
}

fn clamp_bounds(b: FnTraitBounds, allowed: Set(String)) -> FnTraitBounds {
  FnTraitBounds(
    eq_vars: set.intersection(b.eq_vars, allowed),
    to_dynamic_vars: set.intersection(b.to_dynamic_vars, allowed),
    inspect_vars: set.intersection(b.inspect_vars, allowed),
    show_vars: set.intersection(b.show_vars, allowed),
  )
}

fn build_module_const_env(mod: IrModule) -> Dict(String, IrType) {
  list.fold(mod.constants, dict.new(), fn(acc, c) {
    dict.insert(acc, c.name, freshen_ir_type(c.value_type))
  })
}

fn walk_stmts(
  stmts: List(IrStmt),
  env: Dict(String, IrType),
  local_fns: Dict(String, #(IrExpr, Dict(String, IrType))),
  cur_mod: String,
  cur_fn: IrFunction,
  expected_ret: Option(IrType),
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  case stmts {
    [] -> acc
    [stmt, ..rest] -> {
      let stmt_expected = case rest {
        [] -> expected_ret
        _ -> None
      }
      case stmt {
        IrStmtLet(pattern:, annotation:, value:) -> {
          let val_expected = case annotation {
            Some(_) -> annotation
            None -> stmt_expected
          }
          let acc1 =
            walk_expr(
              value,
              env,
              local_fns,
              cur_mod,
              cur_fn,
              val_expected,
              ctx,
              bmap,
              allowed,
              acc,
            )
          let val_ty = case annotation {
            Some(t) -> Some(t)
            None -> infer_expr_type(value, env, cur_mod, ctx)
          }
          let env1 = case val_ty {
            Some(ty) -> bind_pattern_types(pattern, ty, cur_mod, ctx, env)
            None -> env
          }
          let local_fns1 = case pattern, value {
            IrPatVar(name), IrFn(..) ->
              dict.insert(local_fns, name, #(value, env))
            IrPatVar(name), _ -> dict.delete(local_fns, name)
            _, _ -> local_fns
          }
          walk_stmts(
            rest,
            env1,
            local_fns1,
            cur_mod,
            cur_fn,
            expected_ret,
            ctx,
            bmap,
            allowed,
            acc1,
          )
        }

        IrStmtGuard(
          value:,
          pattern:,
          guard_condition:,
          abort_message:,
          post_bindings:,
        ) -> {
          let acc1 =
            walk_expr(
              value,
              env,
              local_fns,
              cur_mod,
              cur_fn,
              None,
              ctx,
              bmap,
              allowed,
              acc,
            )
          let env1 = case infer_expr_type(value, env, cur_mod, ctx) {
            Some(ty) -> bind_pattern_types(pattern, ty, cur_mod, ctx, env)
            None -> env
          }
          let env2 =
            list.fold(post_bindings, env1, fn(e, b) {
              case infer_expr_type(b.1, e, cur_mod, ctx) {
                Some(ty) -> dict.insert(e, b.0, ty)
                None -> e
              }
            })
          let acc2 = case guard_condition {
            Some(g) ->
              walk_expr(
                g,
                env2,
                local_fns,
                cur_mod,
                cur_fn,
                Some(IrTypeBool),
                ctx,
                bmap,
                allowed,
                acc1,
              )
            None -> acc1
          }
          let acc3 = case abort_message {
            Some(m) ->
              walk_expr(
                m,
                env2,
                local_fns,
                cur_mod,
                cur_fn,
                Some(IrTypeString),
                ctx,
                bmap,
                allowed,
                acc2,
              )
            None -> acc2
          }
          let acc4 =
            list.fold(post_bindings, acc3, fn(a, b) {
              walk_expr(
                b.1,
                env1,
                local_fns,
                cur_mod,
                cur_fn,
                None,
                ctx,
                bmap,
                allowed,
                a,
              )
            })
          walk_stmts(
            rest,
            env2,
            local_fns,
            cur_mod,
            cur_fn,
            expected_ret,
            ctx,
            bmap,
            allowed,
            acc4,
          )
        }

        IrStmtAssert(condition:, abort_message:) -> {
          let acc1 =
            walk_expr(
              condition,
              env,
              local_fns,
              cur_mod,
              cur_fn,
              Some(IrTypeBool),
              ctx,
              bmap,
              allowed,
              acc,
            )
          let acc2 = case abort_message {
            Some(m) ->
              walk_expr(
                m,
                env,
                local_fns,
                cur_mod,
                cur_fn,
                Some(IrTypeString),
                ctx,
                bmap,
                allowed,
                acc1,
              )
            None -> acc1
          }
          walk_stmts(
            rest,
            env,
            local_fns,
            cur_mod,
            cur_fn,
            expected_ret,
            ctx,
            bmap,
            allowed,
            acc2,
          )
        }

        IrStmtExpr(expr) -> {
          let acc1 =
            walk_expr(
              expr,
              env,
              local_fns,
              cur_mod,
              cur_fn,
              stmt_expected,
              ctx,
              bmap,
              allowed,
              acc,
            )
          walk_stmts(
            rest,
            env,
            local_fns,
            cur_mod,
            cur_fn,
            expected_ret,
            ctx,
            bmap,
            allowed,
            acc1,
          )
        }
      }
    }
  }
}

fn walk_expr(
  expr: IrExpr,
  env: Dict(String, IrType),
  local_fns: Dict(String, #(IrExpr, Dict(String, IrType))),
  cur_mod: String,
  cur_fn: IrFunction,
  expected_ret: Option(IrType),
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  case expr {
    IrBinOp(op: IrEq, left:, right:) | IrBinOp(op: IrNotEq, left:, right:) -> {
      let acc_children =
        walk_expr(
          left,
          env,
          local_fns,
          cur_mod,
          cur_fn,
          None,
          ctx,
          bmap,
          allowed,
          acc,
        )
        |> walk_expr(
          right,
          env,
          local_fns,
          cur_mod,
          cur_fn,
          None,
          ctx,
          bmap,
          allowed,
          _,
        )
      case
        is_nullary_multi_variant_ctor(left, cur_mod, ctx),
        is_nullary_multi_variant_ctor(right, cur_mod, ctx)
      {
        False, True | True, False -> acc_children
        _, _ -> {
          let next_eq = case
            infer_expr_type(left, env, cur_mod, ctx),
            infer_expr_type(right, env, cur_mod, ctx)
          {
            Some(ty), _ -> collect_type_var_names(ty, acc_children.eq_vars)
            None, Some(ty) -> collect_type_var_names(ty, acc_children.eq_vars)
            None, None -> acc_children.eq_vars
          }
          FnTraitBounds(..acc_children, eq_vars: next_eq)
        }
      }
    }

    IrEcho(expr: inner, message:, ..) -> {
      let acc1 =
        walk_expr(
          inner,
          env,
          local_fns,
          cur_mod,
          cur_fn,
          None,
          ctx,
          bmap,
          allowed,
          acc,
        )
      let acc2 = case message {
        Some(m) ->
          walk_expr(
            m,
            env,
            local_fns,
            cur_mod,
            cur_fn,
            Some(IrTypeString),
            ctx,
            bmap,
            allowed,
            acc1,
          )
        None -> acc1
      }
      let next_insp = case infer_expr_type(inner, env, cur_mod, ctx) {
        Some(ty) ->
          collect_inspectable_type_vars(ty, cur_mod, ctx, acc2.inspect_vars)
        None ->
          list.fold(
            [
              cur_fn.return_type,
              ..list.map(cur_fn.params, fn(p) { p.param_type })
            ],
            acc2.inspect_vars,
            fn(s, t) { collect_inspectable_type_vars(t, cur_mod, ctx, s) },
          )
      }
      FnTraitBounds(..acc2, inspect_vars: next_insp)
    }

    IrCall(function:, args:) ->
      walk_call(
        function,
        args,
        env,
        local_fns,
        cur_mod,
        cur_fn,
        expected_ret,
        ctx,
        bmap,
        allowed,
        acc,
      )

    IrContinue(args) -> {
      let paired_params = list.map(cur_fn.params, fn(p) { Some(p.param_type) })
      walk_positional_loop(
        args,
        paired_params,
        env,
        local_fns,
        cur_mod,
        cur_fn,
        ctx,
        bmap,
        allowed,
        acc,
      )
    }

    IrVar(name) ->
      case dict.get(local_fns, name), expected_ret {
        Ok(#(fn_expr, def_env)), Some(IrTypeFn(..)) ->
          walk_expr(
            fn_expr,
            def_env,
            dict.delete(local_fns, name),
            cur_mod,
            cur_fn,
            expected_ret,
            ctx,
            bmap,
            allowed,
            acc,
          )
        _, Some(IrTypeFn(exp_ps, exp_r)) ->
          case dict.has_key(env, name) {
            False ->
              walk_bare_fn_ref(cur_mod, name, exp_ps, exp_r, bmap, ctx, acc)
            True -> acc
          }
        _, _ -> acc
      }

    IrModuleRef(target_module:, symbol:, ..) ->
      case expected_ret {
        Some(IrTypeFn(exp_ps, exp_r)) ->
          walk_bare_fn_ref(target_module, symbol, exp_ps, exp_r, bmap, ctx, acc)
        _ -> acc
      }

    IrFn(params:, body:, ..) -> {
      let #(exp_ps, exp_r) = case expected_ret {
        Some(IrTypeFn(ps, r)) -> #(list.map(ps, Some), Some(r))
        _ -> #([], None)
      }
      let fn_env = bind_fn_param_types_opt(params, exp_ps, env)
      walk_stmts(
        body,
        fn_env,
        local_fns,
        cur_mod,
        cur_fn,
        exp_r,
        ctx,
        bmap,
        allowed,
        acc,
      )
    }

    IrBlock(stmts) ->
      walk_stmts(
        stmts,
        env,
        local_fns,
        cur_mod,
        cur_fn,
        expected_ret,
        ctx,
        bmap,
        allowed,
        acc,
      )

    IrForLoop(bindings:, body:) -> {
      let #(acc1, env1) =
        list.fold(bindings, #(acc, env), fn(st, b) {
          let #(a, e) = st
          let a1 =
            walk_expr(
              b.1,
              env,
              local_fns,
              cur_mod,
              cur_fn,
              None,
              ctx,
              bmap,
              allowed,
              a,
            )
          let e1 = case infer_expr_type(b.1, env, cur_mod, ctx) {
            Some(ty) -> dict.insert(e, b.0, ty)
            None -> e
          }
          #(a1, e1)
        })
      walk_stmts(
        body,
        env1,
        local_fns,
        cur_mod,
        cur_fn,
        expected_ret,
        ctx,
        bmap,
        allowed,
        acc1,
      )
    }

    IrMatch(subjects:, clauses:) -> {
      let acc1 =
        list.fold(subjects, acc, fn(a, s) {
          walk_expr(
            s,
            env,
            local_fns,
            cur_mod,
            cur_fn,
            None,
            ctx,
            bmap,
            allowed,
            a,
          )
        })
      let subj_tys =
        list.map(subjects, fn(s) { infer_expr_type(s, env, cur_mod, ctx) })
      list.fold(clauses, acc1, fn(a, c) {
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
        let a1 = case c.guard {
          Some(g) ->
            walk_expr(
              g,
              c_env2,
              local_fns,
              cur_mod,
              cur_fn,
              Some(IrTypeBool),
              ctx,
              bmap,
              allowed,
              a,
            )
          None -> a
        }
        let a2 =
          list.fold(c.prefix_bindings, a1, fn(x, b) {
            walk_expr(
              b.1,
              c_env,
              local_fns,
              cur_mod,
              cur_fn,
              None,
              ctx,
              bmap,
              allowed,
              x,
            )
          })
        walk_expr(
          c.body,
          c_env2,
          local_fns,
          cur_mod,
          cur_fn,
          expected_ret,
          ctx,
          bmap,
          allowed,
          a2,
        )
      })
    }

    IrBreak(inner) ->
      walk_expr(
        inner,
        env,
        local_fns,
        cur_mod,
        cur_fn,
        expected_ret,
        ctx,
        bmap,
        allowed,
        acc,
      )

    IrBinOp(..)
    | IrNegateInt(_)
    | IrNegateBool(_)
    | IrGetterCall(..)
    | IrTupleIndex(..)
    | IrTuple(_) ->
      ir_util.fold_expr_direct_children(expr, acc, fn(a, child) {
        walk_expr(
          child,
          env,
          local_fns,
          cur_mod,
          cur_fn,
          None,
          ctx,
          bmap,
          allowed,
          a,
        )
      })

    IrList(elements:, tail:) -> {
      let elem_expected = case expected_ret {
        Some(IrTypeList(inner)) -> Some(inner)
        _ -> None
      }
      let acc1 =
        list.fold(elements, acc, fn(a, e) {
          walk_expr(
            e,
            env,
            local_fns,
            cur_mod,
            cur_fn,
            elem_expected,
            ctx,
            bmap,
            allowed,
            a,
          )
        })
      case tail {
        Some(t) ->
          walk_expr(
            t,
            env,
            local_fns,
            cur_mod,
            cur_fn,
            expected_ret,
            ctx,
            bmap,
            allowed,
            acc1,
          )
        None -> acc1
      }
    }

    IrBitString(segments:) ->
      list.fold(segments, acc, fn(a, seg) {
        let a1 =
          walk_expr(
            seg.0,
            env,
            local_fns,
            cur_mod,
            cur_fn,
            None,
            ctx,
            bmap,
            allowed,
            a,
          )
        list.fold(seg.1, a1, fn(inner_a, opt) {
          case opt {
            glance.SizeValueOption(size_expr) ->
              walk_expr(
                size_expr,
                env,
                local_fns,
                cur_mod,
                cur_fn,
                Some(IrTypeInt64),
                ctx,
                bmap,
                allowed,
                inner_a,
              )
            _ -> inner_a
          }
        })
      })

    IrAbort(message: Some(m), ..) ->
      walk_expr(
        m,
        env,
        local_fns,
        cur_mod,
        cur_fn,
        Some(IrTypeString),
        ctx,
        bmap,
        allowed,
        acc,
      )

    IrAbort(message: None, ..)
    | IrConstructor(..)
    | IrInt(_)
    | IrFloat(_)
    | IrString(_)
    | IrBool(_)
    | IrUnit -> acc
  }
}

fn walk_call(
  function: IrExpr,
  args: List(IrCallArg),
  env: Dict(String, IrType),
  local_fns: Dict(String, #(IrExpr, Dict(String, IrType))),
  cur_mod: String,
  cur_fn: IrFunction,
  expected_ret: Option(IrType),
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  case function {
    IrVar(name) ->
      case dict.get(env, name) {
        Ok(var_ty) ->
          case var_ty {
            IrTypeFn(params: exp_ps, ..) -> {
              let arg_vals = list.map(args, fn(a) { a.value })
              walk_positional_loop(
                arg_vals,
                list.map(exp_ps, Some),
                env,
                local_fns,
                cur_mod,
                cur_fn,
                ctx,
                bmap,
                allowed,
                acc,
              )
            }
            _ ->
              walk_untyped_call_args(
                args,
                env,
                local_fns,
                cur_mod,
                cur_fn,
                ctx,
                bmap,
                allowed,
                acc,
              )
          }
        Error(_) ->
          case dict.get(ctx.all_fns, #(cur_mod, name)) {
            Ok(callee) ->
              walk_known_fn_call(
                cur_mod,
                callee,
                args,
                env,
                local_fns,
                cur_mod,
                cur_fn,
                expected_ret,
                ctx,
                bmap,
                allowed,
                acc,
              )
            Error(_) ->
              walk_untyped_call_args(
                args,
                env,
                local_fns,
                cur_mod,
                cur_fn,
                ctx,
                bmap,
                allowed,
                acc,
              )
          }
      }

    IrModuleRef(target_module:, symbol:, ..) ->
      case dict.get(ctx.all_fns, #(target_module, symbol)) {
        Ok(callee) ->
          walk_known_fn_call(
            target_module,
            callee,
            args,
            env,
            local_fns,
            cur_mod,
            cur_fn,
            expected_ret,
            ctx,
            bmap,
            allowed,
            acc,
          )
        Error(_) ->
          walk_untyped_call_args(
            args,
            env,
            local_fns,
            cur_mod,
            cur_fn,
            ctx,
            bmap,
            allowed,
            acc,
          )
      }

    IrConstructor(target_module:, name:, ..) -> {
      let ctor_mod = option.unwrap(target_module, cur_mod)
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
          let ordered_args = align_ir_call_args(field_params, args)
          let subst0 =
            unify_aligned_args(field_params, ordered_args, env, cur_mod, ctx)
          let td_type =
            IrTypeNamed(
              module_alias: None,
              package: "",
              module: ctor_mod,
              name: td.name,
              args: list.map(td.type_params, IrTypeVar),
            )
          let subst = case expected_ret {
            Some(exp_ty) ->
              unify_ir_types(td_type, exp_ty, cur_mod, ctx, subst0)
            None -> subst0
          }
          let exp_types =
            list.map(field_params, fn(p) {
              Some(apply_call_ret_subst(p.param_type, subst))
            })
          walk_aligned_opt_args(
            ordered_args,
            exp_types,
            env,
            local_fns,
            cur_mod,
            cur_fn,
            ctx,
            bmap,
            allowed,
            acc,
          )
        }
        None ->
          walk_untyped_call_args(
            args,
            env,
            local_fns,
            cur_mod,
            cur_fn,
            ctx,
            bmap,
            allowed,
            acc,
          )
      }
    }

    _ -> {
      let acc1 =
        walk_expr(
          function,
          env,
          local_fns,
          cur_mod,
          cur_fn,
          None,
          ctx,
          bmap,
          allowed,
          acc,
        )
      walk_untyped_call_args(
        args,
        env,
        local_fns,
        cur_mod,
        cur_fn,
        ctx,
        bmap,
        allowed,
        acc1,
      )
    }
  }
}

fn walk_known_fn_call(
  callee_mod: String,
  callee: IrFunction,
  args: List(IrCallArg),
  env: Dict(String, IrType),
  local_fns: Dict(String, #(IrExpr, Dict(String, IrType))),
  cur_mod: String,
  cur_fn: IrFunction,
  expected_ret: Option(IrType),
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  let ordered_args = align_ir_call_args(callee.params, args)
  let subst0 =
    unify_aligned_args(callee.params, ordered_args, env, cur_mod, ctx)
  let subst = case expected_ret {
    Some(exp_ty) ->
      unify_ir_types(callee.return_type, exp_ty, cur_mod, ctx, subst0)
    None -> subst0
  }
  let callee_bounds = case dict.get(bmap, #(callee_mod, callee.name)) {
    Ok(b) -> b
    Error(_) -> empty_fn_bounds()
  }
  let acc1 =
    apply_callee_bounds_via_subst(callee_bounds, subst, cur_mod, ctx, acc)
  let exp_param_tys =
    list.map(callee.params, fn(p) {
      Some(apply_call_ret_subst(p.param_type, subst))
    })
  walk_aligned_opt_args(
    ordered_args,
    exp_param_tys,
    env,
    local_fns,
    cur_mod,
    cur_fn,
    ctx,
    bmap,
    allowed,
    acc1,
  )
}

fn walk_bare_fn_ref(
  ref_mod: String,
  ref_name: String,
  exp_params: List(IrType),
  exp_ret: IrType,
  bmap: Dict(#(String, String), FnTraitBounds),
  ctx: AnalyzeCtx,
  acc: FnTraitBounds,
) -> FnTraitBounds {
  case
    dict.get(ctx.all_fns, #(ref_mod, ref_name)),
    dict.get(bmap, #(ref_mod, ref_name))
  {
    Ok(ref_fn), Ok(ref_bounds) -> {
      let ref_fn_ty =
        IrTypeFn(
          params: list.map(ref_fn.params, fn(p) { p.param_type }),
          return: ref_fn.return_type,
        )
      let subst =
        unify_ir_types(
          ref_fn_ty,
          IrTypeFn(exp_params, exp_ret),
          ref_mod,
          ctx,
          dict.new(),
        )
      apply_callee_bounds_via_subst(ref_bounds, subst, ref_mod, ctx, acc)
    }
    _, _ -> acc
  }
}

fn apply_callee_bounds_via_subst(
  callee_bounds: FnTraitBounds,
  subst: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
  acc: FnTraitBounds,
) -> FnTraitBounds {
  let next_eq =
    set.fold(callee_bounds.eq_vars, acc.eq_vars, fn(s, tp) {
      case dict.get(subst, tp) {
        Ok(caller_ty) -> collect_type_var_names(caller_ty, s)
        Error(_) -> s
      }
    })
  let next_dyn =
    set.fold(callee_bounds.to_dynamic_vars, acc.to_dynamic_vars, fn(s, tp) {
      case dict.get(subst, tp) {
        Ok(caller_ty) -> collect_type_var_names(caller_ty, s)
        Error(_) -> s
      }
    })
  let next_insp =
    set.fold(callee_bounds.inspect_vars, acc.inspect_vars, fn(s, tp) {
      case dict.get(subst, tp) {
        Ok(caller_ty) ->
          collect_inspectable_type_vars(caller_ty, cur_mod, ctx, s)
        Error(_) -> s
      }
    })
  let next_show =
    set.fold(callee_bounds.show_vars, acc.show_vars, fn(s, tp) {
      case dict.get(subst, tp) {
        Ok(caller_ty) -> collect_type_var_names(caller_ty, s)
        Error(_) -> s
      }
    })
  FnTraitBounds(
    eq_vars: next_eq,
    to_dynamic_vars: next_dyn,
    inspect_vars: next_insp,
    show_vars: next_show,
  )
}

fn walk_aligned_opt_args(
  ordered_args: List(Option(IrExpr)),
  expected_types: List(Option(IrType)),
  env: Dict(String, IrType),
  local_fns: Dict(String, #(IrExpr, Dict(String, IrType))),
  cur_mod: String,
  cur_fn: IrFunction,
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  list.fold(list.zip(ordered_args, expected_types), acc, fn(a, pair) {
    case pair.0 {
      Some(arg_val) ->
        walk_expr(
          arg_val,
          env,
          local_fns,
          cur_mod,
          cur_fn,
          pair.1,
          ctx,
          bmap,
          allowed,
          a,
        )
      None -> a
    }
  })
}

fn walk_positional_loop(
  args: List(IrExpr),
  expected_types: List(Option(IrType)),
  env: Dict(String, IrType),
  local_fns: Dict(String, #(IrExpr, Dict(String, IrType))),
  cur_mod: String,
  cur_fn: IrFunction,
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  case args {
    [] -> acc
    [arg, ..rest_args] -> {
      let #(exp_ty, rest_exps) = case expected_types {
        [e, ..re] -> #(e, re)
        [] -> #(None, [])
      }
      let next_acc =
        walk_expr(
          arg,
          env,
          local_fns,
          cur_mod,
          cur_fn,
          exp_ty,
          ctx,
          bmap,
          allowed,
          acc,
        )
      walk_positional_loop(
        rest_args,
        rest_exps,
        env,
        local_fns,
        cur_mod,
        cur_fn,
        ctx,
        bmap,
        allowed,
        next_acc,
      )
    }
  }
}

fn walk_untyped_call_args(
  args: List(IrCallArg),
  env: Dict(String, IrType),
  local_fns: Dict(String, #(IrExpr, Dict(String, IrType))),
  cur_mod: String,
  cur_fn: IrFunction,
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  list.fold(args, acc, fn(a, arg) {
    walk_expr(
      arg.value,
      env,
      local_fns,
      cur_mod,
      cur_fn,
      None,
      ctx,
      bmap,
      allowed,
      a,
    )
  })
}
