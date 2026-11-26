import glance
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import lower/ir.{
  type IrExpr, type IrPatArg, type IrPattern, type IrStmt, type IrType, IrAbort,
  IrBinOp, IrBitString, IrBlock, IrBreak, IrCall, IrContinue, IrEcho, IrFn,
  IrForLoop, IrGetterCall, IrList, IrMatch, IrNegateBool, IrNegateInt, IrPatAs,
  IrPatBitString, IrPatBool, IrPatDiscard, IrPatFloat, IrPatInt, IrPatString,
  IrPatTuple, IrPatUnit, IrPatVar, IrPatVariant, IrStmtAssert, IrStmtExpr,
  IrStmtGuard, IrStmtLet, IrTuple, IrTupleIndex, IrTypeBitArray, IrTypeBool,
  IrTypeDouble, IrTypeFn, IrTypeInt64, IrTypeList, IrTypeNamed, IrTypeResult,
  IrTypeString, IrTypeTuple, IrTypeUnit, IrTypeVar, IrVar,
}

/// Return the set of mangled variable names bound by `pat`.
pub fn pattern_bound_vars(pat: IrPattern) -> Set(String) {
  case pat {
    IrPatInt(_)
    | IrPatFloat(_)
    | IrPatString(_)
    | IrPatBool(_)
    | IrPatUnit
    | IrPatDiscard -> set.new()
    IrPatVar(name) -> set.from_list([name])
    IrPatAs(inner, alias) -> set.insert(pattern_bound_vars(inner), alias)
    IrPatTuple(els) ->
      list.fold(els, set.new(), fn(acc, el) {
        set.union(acc, pattern_bound_vars(el))
      })
    IrPatVariant(args:, ..) ->
      list.fold(args, set.new(), fn(acc, arg: IrPatArg) {
        set.union(acc, pattern_bound_vars(arg.pattern))
      })
    IrPatBitString(segments:) ->
      list.fold(segments, set.new(), fn(acc, seg) {
        set.union(acc, pattern_bound_vars(seg.0))
      })
  }
}

/// Return True if `name` appears free in `expr`.
pub fn expr_uses_var(expr: IrExpr, name: String) -> Bool {
  set.contains(free_vars_expr(expr), name)
}

/// Collect free variable names in an optional `IrExpr`.
pub fn free_vars_opt_expr(opt: Option(IrExpr)) -> Set(String) {
  case opt {
    Some(e) -> free_vars_expr(e)
    None -> set.new()
  }
}

/// Compute free variables across a sequential list of `IrStmt`s.
pub fn free_vars_stmts(stmts: List(IrStmt)) -> Set(String) {
  list.fold_right(stmts, set.new(), fn(rest_fv, stmt) {
    case stmt {
      IrStmtLet(pattern:, value:, ..) ->
        set.union(
          free_vars_expr(value),
          set.difference(rest_fv, pattern_bound_vars(pattern)),
        )
      IrStmtGuard(
        value:,
        pattern:,
        guard_condition:,
        abort_message:,
        post_bindings:,
      ) -> {
        let pat_vars = pattern_bound_vars(pattern)
        let after_posts = free_after_bindings(post_bindings, rest_fv)
        let cond_fv = free_vars_opt_expr(guard_condition)
        let msg_fv = free_vars_opt_expr(abort_message)
        set.union(
          free_vars_expr(value),
          set.union(
            msg_fv,
            set.difference(set.union(cond_fv, after_posts), pat_vars),
          ),
        )
      }
      IrStmtAssert(condition:, abort_message:) ->
        set.union(
          rest_fv,
          set.union(
            free_vars_expr(condition),
            free_vars_opt_expr(abort_message),
          ),
        )
      IrStmtExpr(e) -> set.union(rest_fv, free_vars_expr(e))
    }
  })
}

/// Compute free variables in `tail_fv` after subtracting sequentially bound `bindings`
/// and adding free variables of any RHS expressions.
pub fn free_after_bindings(
  bindings: List(#(String, IrExpr)),
  tail_fv: Set(String),
) -> Set(String) {
  list.fold_right(bindings, tail_fv, fn(acc, b) {
    let #(name, expr) = b
    set.union(set.delete(acc, name), free_vars_expr(expr))
  })
}

/// Prune unused `bindings` whose variable name is not in `needed`, propagating
/// dependencies backward through earlier bindings.
pub fn prune_bindings(
  bindings: List(#(String, IrExpr)),
  needed: Set(String),
) -> List(#(String, IrExpr)) {
  let #(kept, _) =
    list.fold_right(bindings, #([], needed), fn(acc, b) {
      let #(kept_acc, need_set) = acc
      let #(name, expr) = b
      case set.contains(need_set, name) {
        True -> {
          let next_need =
            set.union(set.delete(need_set, name), free_vars_expr(expr))
          #([b, ..kept_acc], next_need)
        }
        False -> #(kept_acc, need_set)
      }
    })
  kept
}

/// Collect free variable names referenced in `expr`.
pub fn free_vars_expr(expr: IrExpr) -> Set(String) {
  case expr {
    IrVar(name) -> set.from_list([name])
    IrNegateInt(inner)
    | IrNegateBool(inner)
    | IrBreak(inner)
    | IrGetterCall(receiver: inner, ..)
    | IrTupleIndex(tuple: inner, ..) -> free_vars_expr(inner)
    IrBinOp(left:, right:, ..) ->
      set.union(free_vars_expr(left), free_vars_expr(right))
    IrTuple(els) | IrContinue(els) ->
      list.fold(els, set.new(), fn(acc, e) { set.union(acc, free_vars_expr(e)) })
    IrList(elements:, tail:) -> {
      let els_fv =
        list.fold(elements, set.new(), fn(acc, e) {
          set.union(acc, free_vars_expr(e))
        })
      set.union(els_fv, free_vars_opt_expr(tail))
    }
    IrBitString(segments:) ->
      list.fold(segments, set.new(), fn(acc, seg) {
        let seg_fv = set.union(acc, free_vars_expr(seg.0))
        list.fold(seg.1, seg_fv, fn(inner_acc, opt) {
          case opt {
            glance.SizeValueOption(size_expr) ->
              set.union(inner_acc, free_vars_expr(size_expr))
            _ -> inner_acc
          }
        })
      })
    IrCall(function:, args:) -> {
      let fn_fv = free_vars_expr(function)
      list.fold(args, fn_fv, fn(acc, arg) {
        set.union(acc, free_vars_expr(arg.value))
      })
    }
    IrBlock(stmts) -> free_vars_stmts(stmts)
    IrFn(params:, body:, ..) -> {
      let bound = set.from_list(list.map(params, fn(p) { p.name }))
      set.difference(free_vars_stmts(body), bound)
    }
    IrForLoop(bindings:, body:) -> {
      let bind_vals =
        list.fold(bindings, set.new(), fn(acc, b) {
          set.union(acc, free_vars_expr(b.1))
        })
      let bound = set.from_list(list.map(bindings, fn(b) { b.0 }))
      set.union(bind_vals, set.difference(free_vars_stmts(body), bound))
    }
    IrMatch(subjects:, clauses:) -> {
      let subj_fv =
        list.fold(subjects, set.new(), fn(acc, s) {
          set.union(acc, free_vars_expr(s))
        })
      list.fold(clauses, subj_fv, fn(acc, c) {
        let pat_vars =
          list.fold(c.patterns, set.new(), fn(s, alt) {
            list.fold(alt, s, fn(ps, p) { set.union(ps, pattern_bound_vars(p)) })
          })
        let body_tail =
          free_after_bindings(c.prefix_bindings, free_vars_expr(c.body))
        let g_fv = free_vars_opt_expr(c.guard)
        let clause_fv = set.difference(set.union(g_fv, body_tail), pat_vars)
        set.union(acc, clause_fv)
      })
    }
    IrEcho(expr: inner, message:, ..) ->
      set.union(free_vars_expr(inner), free_vars_opt_expr(message))
    IrAbort(message:, ..) -> free_vars_opt_expr(message)
    _ -> set.new()
  }
}

/// Collect distinct type variable names in left-to-right signature order.
pub fn collect_type_vars_in_sig(
  param_types: List(IrType),
  return_type: IrType,
) -> List(String) {
  let all_types = list.append(param_types, [return_type])
  let #(rev_vars, _) =
    list.fold(all_types, #([], set.new()), fn(acc, t) {
      collect_type_vars(t, acc.0, acc.1)
    })
  list.reverse(rev_vars)
}

/// Collect distinct type variable names in left-to-right order from a single `IrType`.
pub fn collect_type_vars_in_type(ty: IrType) -> List(String) {
  let #(rev_vars, _) = collect_type_vars(ty, [], set.new())
  list.reverse(rev_vars)
}

fn collect_type_vars(
  ty: IrType,
  rev_acc: List(String),
  seen: Set(String),
) -> #(List(String), Set(String)) {
  case ty {
    IrTypeVar(name) ->
      case set.contains(seen, name) {
        True -> #(rev_acc, seen)
        False -> #([name, ..rev_acc], set.insert(seen, name))
      }
    IrTypeInt64
    | IrTypeDouble
    | IrTypeString
    | IrTypeBool
    | IrTypeUnit
    | IrTypeBitArray -> #(rev_acc, seen)
    IrTypeList(inner) -> collect_type_vars(inner, rev_acc, seen)
    IrTypeResult(ok_t, err_t) -> {
      let #(acc1, seen1) = collect_type_vars(ok_t, rev_acc, seen)
      collect_type_vars(err_t, acc1, seen1)
    }
    IrTypeTuple(els) ->
      list.fold(els, #(rev_acc, seen), fn(acc, el) {
        collect_type_vars(el, acc.0, acc.1)
      })
    IrTypeFn(params, ret) -> {
      let #(acc1, seen1) =
        list.fold(params, #(rev_acc, seen), fn(acc, p) {
          collect_type_vars(p, acc.0, acc.1)
        })
      collect_type_vars(ret, acc1, seen1)
    }
    IrTypeNamed(args:, ..) ->
      list.fold(args, #(rev_acc, seen), fn(acc, a) {
        collect_type_vars(a, acc.0, acc.1)
      })
  }
}

/// Return True if evaluating `expr` is guaranteed to be pure and side-effect-free
/// (cannot perform calls, `echo`, or `abort`).
pub fn is_effect_free_expr(expr: IrExpr) -> Bool {
  case expr {
    ir.IrInt(_)
    | ir.IrFloat(_)
    | ir.IrString(_)
    | ir.IrBool(_)
    | ir.IrUnit
    | IrVar(_)
    | ir.IrModuleRef(..)
    | ir.IrConstructor(..)
    | IrFn(..) -> True
    IrNegateInt(inner)
    | IrNegateBool(inner)
    | IrTupleIndex(tuple: inner, ..)
    | IrGetterCall(receiver: inner, ..) -> is_effect_free_expr(inner)
    IrBinOp(left:, right:, ..) ->
      is_effect_free_expr(left) && is_effect_free_expr(right)
    IrTuple(els) -> list.all(els, is_effect_free_expr)
    IrList(elements:, tail:) ->
      list.all(elements, is_effect_free_expr)
      && case tail {
        Some(t) -> is_effect_free_expr(t)
        None -> True
      }
    IrBitString(segments:) ->
      list.all(segments, fn(seg) {
        is_effect_free_expr(seg.0)
        && list.all(seg.1, fn(opt) {
          case opt {
            glance.SizeValueOption(se) -> is_effect_free_expr(se)
            _ -> True
          }
        })
      })
    IrCall(function: ir.IrConstructor(..), args:) ->
      list.all(args, fn(a) { is_effect_free_expr(a.value) })
    _ -> False
  }
}

/// Return True if `f` is an `@external(...)` function whose effective body is
/// still a single `panic`/`todo` stub and has no MoonBit FFI mapping or patch.
pub fn needs_shim(f: ir.IrFunction) -> Bool {
  f.external && f.ffi == option.None && is_panic_or_todo_body(f.body)
}

fn is_panic_or_todo_body(body: List(IrStmt)) -> Bool {
  case body {
    [] -> True
    [IrStmtExpr(IrAbort(kind: ir.PanicAbort, ..))]
    | [IrStmtExpr(IrAbort(kind: ir.TodoAbort, ..))] -> True
    [IrStmtLet(pattern: ir.IrPatDiscard, annotation: option.None, ..), ..rest] ->
      is_panic_or_todo_body(rest)
    [IrStmtExpr(IrBlock(inner))] -> is_panic_or_todo_body(inner)
    _ -> False
  }
}
