import glance
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import lower/ir.{
  type IrBitSize, type IrExpr, type IrPatArg, type IrPattern, type IrStmt,
  type IrType, IrAbort, IrBinOp, IrBitSizeBinOp, IrBitString, IrBlock, IrBreak,
  IrCall, IrCallArg, IrClause, IrContinue, IrEcho, IrFn, IrFnParam, IrForLoop,
  IrGetterCall, IrList, IrMatch, IrNegateBool, IrNegateInt, IrPatArg, IrPatAs,
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

// -----------------------------------------------------------------------------
// Generic IR Traversal Combinators
// -----------------------------------------------------------------------------

/// Callbacks for pre-order fallible traversal over IR nodes.
/// Create with `default_visitor()` and override only the needed hooks.
pub type IrVisitor(a, e) {
  IrVisitor(
    on_expr: fn(a, IrExpr) -> Result(a, e),
    on_stmt: fn(a, IrStmt) -> Result(a, e),
    on_pattern: fn(a, IrPattern) -> Result(a, e),
    on_type: fn(a, IrType) -> Result(a, e),
    on_bit_size: fn(a, IrBitSize) -> Result(a, e),
  )
}

/// Construct a no-op `IrVisitor` that passes every node through unchanged.
pub fn default_visitor() -> IrVisitor(a, e) {
  IrVisitor(
    on_expr: fn(acc, _) { Ok(acc) },
    on_stmt: fn(acc, _) { Ok(acc) },
    on_pattern: fn(acc, _) { Ok(acc) },
    on_type: fn(acc, _) { Ok(acc) },
    on_bit_size: fn(acc, _) { Ok(acc) },
  )
}

/// Transform immediate child `IrType`s of `ty` using `f`.
pub fn map_type_children(ty: IrType, f: fn(IrType) -> IrType) -> IrType {
  case ty {
    IrTypeInt64
    | IrTypeDouble
    | IrTypeString
    | IrTypeBool
    | IrTypeUnit
    | IrTypeBitArray
    | IrTypeVar(_) -> ty
    IrTypeList(inner) -> IrTypeList(f(inner))
    IrTypeResult(ok, err) -> IrTypeResult(f(ok), f(err))
    IrTypeTuple(els) -> IrTypeTuple(list.map(els, f))
    IrTypeFn(params, ret) -> IrTypeFn(list.map(params, f), f(ret))
    IrTypeNamed(module_alias:, package:, module:, name:, args:) ->
      IrTypeNamed(
        module_alias:,
        package:,
        module:,
        name:,
        args: list.map(args, f),
      )
  }
}

/// Pre-order fallible fold over `ty` and all nested `IrType` children.
pub fn try_fold_type(
  ty: IrType,
  acc: a,
  f: fn(a, IrType) -> Result(a, e),
) -> Result(a, e) {
  use acc <- result.try(f(acc, ty))
  case ty {
    IrTypeInt64
    | IrTypeDouble
    | IrTypeString
    | IrTypeBool
    | IrTypeUnit
    | IrTypeBitArray
    | IrTypeVar(_) -> Ok(acc)
    IrTypeList(inner) -> try_fold_type(inner, acc, f)
    IrTypeResult(ok, err) -> {
      use acc <- result.try(try_fold_type(ok, acc, f))
      try_fold_type(err, acc, f)
    }
    IrTypeTuple(els) ->
      list.try_fold(els, acc, fn(a_acc, el) { try_fold_type(el, a_acc, f) })
    IrTypeFn(params, ret) -> {
      use acc <- result.try(
        list.try_fold(params, acc, fn(a_acc, p) { try_fold_type(p, a_acc, f) }),
      )
      try_fold_type(ret, acc, f)
    }
    IrTypeNamed(args:, ..) ->
      list.try_fold(args, acc, fn(a_acc, arg) { try_fold_type(arg, a_acc, f) })
  }
}

/// Pre-order fold over `ty` and all nested `IrType` children.
pub fn fold_type(ty: IrType, acc: a, f: fn(a, IrType) -> a) -> a {
  let assert Ok(res) = try_fold_type(ty, acc, fn(a_acc, t) { Ok(f(a_acc, t)) })
  res
}

/// Transform immediate child `IrBitSize` nodes of `sz` using `f`.
pub fn map_bit_size_children(
  sz: IrBitSize,
  f: fn(IrBitSize) -> IrBitSize,
) -> IrBitSize {
  case sz {
    ir.IrBitSizeInt(_) | ir.IrBitSizeVar(_) -> sz
    IrBitSizeBinOp(op:, left:, right:) ->
      IrBitSizeBinOp(op:, left: f(left), right: f(right))
  }
}

/// Pre-order fallible fold over `sz` and all nested `IrBitSize` children.
pub fn try_fold_bit_size(
  sz: IrBitSize,
  acc: a,
  f: fn(a, IrBitSize) -> Result(a, e),
) -> Result(a, e) {
  use acc <- result.try(f(acc, sz))
  case sz {
    ir.IrBitSizeInt(_) | ir.IrBitSizeVar(_) -> Ok(acc)
    IrBitSizeBinOp(left:, right:, ..) -> {
      use acc <- result.try(try_fold_bit_size(left, acc, f))
      try_fold_bit_size(right, acc, f)
    }
  }
}

/// Transform immediate child `IrPattern` and `IrBitSize` nodes of `pat`.
pub fn map_pattern_children(
  pat: IrPattern,
  on_pat: fn(IrPattern) -> IrPattern,
  on_size: fn(IrBitSize) -> IrBitSize,
) -> IrPattern {
  case pat {
    IrPatInt(_)
    | IrPatFloat(_)
    | IrPatString(_)
    | IrPatBool(_)
    | IrPatUnit
    | IrPatDiscard
    | IrPatVar(_) -> pat
    IrPatAs(inner, alias) -> IrPatAs(on_pat(inner), alias)
    IrPatTuple(els) -> IrPatTuple(list.map(els, on_pat))
    IrPatVariant(
      module_alias:,
      target_module:,
      constructor:,
      args:,
      with_spread:,
    ) ->
      IrPatVariant(
        module_alias:,
        target_module:,
        constructor:,
        args: list.map(args, fn(arg) {
          IrPatArg(label: arg.label, pattern: on_pat(arg.pattern))
        }),
        with_spread:,
      )
    IrPatBitString(segments:) ->
      IrPatBitString(
        list.map(segments, fn(seg) {
          let new_opts =
            list.map(seg.1, fn(opt) {
              case opt {
                glance.SizeValueOption(sz) ->
                  glance.SizeValueOption(on_size(sz))
                other -> other
              }
            })
          #(on_pat(seg.0), new_opts)
        }),
      )
  }
}

/// Pre-order fallible fold over `pat`, nested `IrPattern`s, and `IrBitSize`s.
pub fn try_fold_pattern_with(
  pat: IrPattern,
  acc: a,
  on_pat: fn(a, IrPattern) -> Result(a, e),
  on_size: fn(a, IrBitSize) -> Result(a, e),
) -> Result(a, e) {
  use acc <- result.try(on_pat(acc, pat))
  case pat {
    IrPatInt(_)
    | IrPatFloat(_)
    | IrPatString(_)
    | IrPatBool(_)
    | IrPatUnit
    | IrPatDiscard
    | IrPatVar(_) -> Ok(acc)
    IrPatAs(inner, _) -> try_fold_pattern_with(inner, acc, on_pat, on_size)
    IrPatTuple(els) ->
      list.try_fold(els, acc, fn(a_acc, el) {
        try_fold_pattern_with(el, a_acc, on_pat, on_size)
      })
    IrPatVariant(args:, ..) ->
      list.try_fold(args, acc, fn(a_acc, arg) {
        try_fold_pattern_with(arg.pattern, a_acc, on_pat, on_size)
      })
    IrPatBitString(segments:) ->
      list.try_fold(segments, acc, fn(a_acc, seg) {
        use a_acc <- result.try(try_fold_pattern_with(
          seg.0,
          a_acc,
          on_pat,
          on_size,
        ))
        list.try_fold(seg.1, a_acc, fn(opt_acc, opt) {
          case opt {
            glance.SizeValueOption(sz) ->
              try_fold_bit_size(sz, opt_acc, on_size)
            _ -> Ok(opt_acc)
          }
        })
      })
  }
}

/// Pre-order fallible fold over `pat` and all nested `IrPattern` children.
pub fn try_fold_pattern(
  pat: IrPattern,
  acc: a,
  f: fn(a, IrPattern) -> Result(a, e),
) -> Result(a, e) {
  try_fold_pattern_with(pat, acc, f, fn(a_acc, _) { Ok(a_acc) })
}

/// Pre-order fold over `pat` and all nested `IrPattern` children.
pub fn fold_pattern(pat: IrPattern, acc: a, f: fn(a, IrPattern) -> a) -> a {
  let assert Ok(res) =
    try_fold_pattern(pat, acc, fn(a_acc, p) { Ok(f(a_acc, p)) })
  res
}

fn try_fold_opt(
  opt: Option(x),
  acc: a,
  f: fn(a, x) -> Result(a, e),
) -> Result(a, e) {
  case opt {
    Some(v) -> f(acc, v)
    None -> Ok(acc)
  }
}

/// Pre-order fallible traversal over a single `IrStmt` and all nested IR nodes.
pub fn try_fold_stmt(
  stmt: IrStmt,
  acc: a,
  visitor: IrVisitor(a, e),
) -> Result(a, e) {
  use acc <- result.try(visitor.on_stmt(acc, stmt))
  case stmt {
    IrStmtLet(pattern:, annotation:, value:) -> {
      use acc <- result.try(try_fold_pattern_with(
        pattern,
        acc,
        visitor.on_pattern,
        visitor.on_bit_size,
      ))
      use acc <- result.try(
        try_fold_opt(annotation, acc, fn(a_acc, ty) {
          try_fold_type(ty, a_acc, visitor.on_type)
        }),
      )
      try_fold_expr(value, acc, visitor)
    }
    IrStmtGuard(
      value:,
      pattern:,
      guard_condition:,
      abort_message:,
      post_bindings:,
    ) -> {
      use acc <- result.try(try_fold_expr(value, acc, visitor))
      use acc <- result.try(try_fold_pattern_with(
        pattern,
        acc,
        visitor.on_pattern,
        visitor.on_bit_size,
      ))
      use acc <- result.try(
        try_fold_opt(guard_condition, acc, fn(a_acc, g) {
          try_fold_expr(g, a_acc, visitor)
        }),
      )
      use acc <- result.try(
        try_fold_opt(abort_message, acc, fn(a_acc, m) {
          try_fold_expr(m, a_acc, visitor)
        }),
      )
      list.try_fold(post_bindings, acc, fn(a_acc, pb) {
        try_fold_expr(pb.1, a_acc, visitor)
      })
    }
    IrStmtAssert(condition:, abort_message:) -> {
      use acc <- result.try(try_fold_expr(condition, acc, visitor))
      try_fold_opt(abort_message, acc, fn(a_acc, m) {
        try_fold_expr(m, a_acc, visitor)
      })
    }
    IrStmtExpr(e) -> try_fold_expr(e, acc, visitor)
  }
}

/// Pre-order fallible traversal over a list of `IrStmt`s.
pub fn try_fold_stmts(
  stmts: List(IrStmt),
  acc: a,
  visitor: IrVisitor(a, e),
) -> Result(a, e) {
  list.try_fold(stmts, acc, fn(a_acc, stmt) {
    try_fold_stmt(stmt, a_acc, visitor)
  })
}

/// Pre-order fallible traversal over `expr` and all nested IR nodes.
pub fn try_fold_expr(
  expr: IrExpr,
  acc: a,
  visitor: IrVisitor(a, e),
) -> Result(a, e) {
  use acc <- result.try(visitor.on_expr(acc, expr))
  case expr {
    ir.IrInt(_)
    | ir.IrFloat(_)
    | ir.IrString(_)
    | ir.IrBool(_)
    | ir.IrUnit
    | IrVar(_)
    | ir.IrModuleRef(..)
    | ir.IrConstructor(..) -> Ok(acc)
    IrTuple(els) | IrContinue(els) ->
      list.try_fold(els, acc, fn(a_acc, el) {
        try_fold_expr(el, a_acc, visitor)
      })
    IrTupleIndex(tuple: inner, ..)
    | IrNegateInt(inner)
    | IrNegateBool(inner)
    | IrBreak(inner)
    | IrGetterCall(receiver: inner, ..) -> try_fold_expr(inner, acc, visitor)
    IrList(elements:, tail:) -> {
      use acc <- result.try(
        list.try_fold(elements, acc, fn(a_acc, el) {
          try_fold_expr(el, a_acc, visitor)
        }),
      )
      try_fold_opt(tail, acc, fn(a_acc, t) { try_fold_expr(t, a_acc, visitor) })
    }
    IrBitString(segments:) ->
      list.try_fold(segments, acc, fn(a_acc, seg) {
        use a_acc <- result.try(try_fold_expr(seg.0, a_acc, visitor))
        list.try_fold(seg.1, a_acc, fn(opt_acc, opt) {
          case opt {
            glance.SizeValueOption(size_expr) ->
              try_fold_expr(size_expr, opt_acc, visitor)
            _ -> Ok(opt_acc)
          }
        })
      })
    IrBinOp(left:, right:, ..) -> {
      use acc <- result.try(try_fold_expr(left, acc, visitor))
      try_fold_expr(right, acc, visitor)
    }
    IrCall(function:, args:) -> {
      use acc <- result.try(try_fold_expr(function, acc, visitor))
      list.try_fold(args, acc, fn(a_acc, arg) {
        try_fold_expr(arg.value, a_acc, visitor)
      })
    }
    IrBlock(stmts) -> try_fold_stmts(stmts, acc, visitor)
    IrFn(params:, return_type:, body:) -> {
      use acc <- result.try(
        list.try_fold(params, acc, fn(a_acc, p) {
          try_fold_opt(p.param_type, a_acc, fn(p_acc, ty) {
            try_fold_type(ty, p_acc, visitor.on_type)
          })
        }),
      )
      use acc <- result.try(
        try_fold_opt(return_type, acc, fn(a_acc, ty) {
          try_fold_type(ty, a_acc, visitor.on_type)
        }),
      )
      try_fold_stmts(body, acc, visitor)
    }
    IrForLoop(bindings:, body:) -> {
      use acc <- result.try(
        list.try_fold(bindings, acc, fn(a_acc, b) {
          try_fold_expr(b.1, a_acc, visitor)
        }),
      )
      try_fold_stmts(body, acc, visitor)
    }
    IrMatch(subjects:, clauses:) -> {
      use acc <- result.try(
        list.try_fold(subjects, acc, fn(a_acc, s) {
          try_fold_expr(s, a_acc, visitor)
        }),
      )
      list.try_fold(clauses, acc, fn(a_acc, cl) {
        use a_acc <- result.try(
          list.try_fold(cl.patterns, a_acc, fn(alts_acc, alt) {
            list.try_fold(alt, alts_acc, fn(pat_acc, pat) {
              try_fold_pattern_with(
                pat,
                pat_acc,
                visitor.on_pattern,
                visitor.on_bit_size,
              )
            })
          }),
        )
        use a_acc <- result.try(
          try_fold_opt(cl.guard, a_acc, fn(g_acc, g) {
            try_fold_expr(g, g_acc, visitor)
          }),
        )
        use a_acc <- result.try(
          list.try_fold(cl.prefix_bindings, a_acc, fn(pb_acc, pb) {
            try_fold_expr(pb.1, pb_acc, visitor)
          }),
        )
        try_fold_expr(cl.body, a_acc, visitor)
      })
    }
    IrEcho(expr: inner, message:, ..) -> {
      use acc <- result.try(try_fold_expr(inner, acc, visitor))
      try_fold_opt(message, acc, fn(a_acc, m) {
        try_fold_expr(m, a_acc, visitor)
      })
    }
    IrAbort(message:, ..) ->
      try_fold_opt(message, acc, fn(a_acc, m) {
        try_fold_expr(m, a_acc, visitor)
      })
  }
}

/// Pre-order infallible traversal over a list of `IrStmt`s.
pub fn fold_stmts(
  stmts: List(IrStmt),
  acc: a,
  visitor: IrVisitor(a, Nil),
) -> a {
  let assert Ok(res) = try_fold_stmts(stmts, acc, visitor)
  res
}

/// Pre-order infallible traversal over `expr` and all nested IR nodes.
pub fn fold_expr(expr: IrExpr, acc: a, visitor: IrVisitor(a, Nil)) -> a {
  let assert Ok(res) = try_fold_expr(expr, acc, visitor)
  res
}

/// Fold over only the immediate `IrExpr` children of `expr` (non-recursive).
pub fn fold_expr_direct_children(
  expr: IrExpr,
  acc: a,
  on_expr: fn(a, IrExpr) -> a,
) -> a {
  case expr {
    ir.IrInt(_)
    | ir.IrFloat(_)
    | ir.IrString(_)
    | ir.IrBool(_)
    | ir.IrUnit
    | IrVar(_)
    | ir.IrModuleRef(..)
    | ir.IrConstructor(..)
    | IrBlock(_)
    | IrFn(..) -> acc
    IrTuple(els) | IrContinue(els) -> list.fold(els, acc, on_expr)
    IrTupleIndex(tuple: inner, ..)
    | IrNegateInt(inner)
    | IrNegateBool(inner)
    | IrBreak(inner)
    | IrGetterCall(receiver: inner, ..) -> on_expr(acc, inner)
    IrList(elements:, tail:) -> {
      let acc = list.fold(elements, acc, on_expr)
      case tail {
        Some(t) -> on_expr(acc, t)
        None -> acc
      }
    }
    IrBitString(segments:) ->
      list.fold(segments, acc, fn(a_acc, seg) {
        let a_acc = on_expr(a_acc, seg.0)
        list.fold(seg.1, a_acc, fn(opt_acc, opt) {
          case opt {
            glance.SizeValueOption(size_expr) -> on_expr(opt_acc, size_expr)
            _ -> opt_acc
          }
        })
      })
    IrBinOp(left:, right:, ..) -> on_expr(on_expr(acc, left), right)
    IrCall(function:, args:) -> {
      let acc = on_expr(acc, function)
      list.fold(args, acc, fn(a_acc, arg) { on_expr(a_acc, arg.value) })
    }
    IrForLoop(bindings:, ..) ->
      list.fold(bindings, acc, fn(a_acc, b) { on_expr(a_acc, b.1) })
    IrMatch(subjects:, clauses:) -> {
      let acc = list.fold(subjects, acc, on_expr)
      list.fold(clauses, acc, fn(a_acc, cl) {
        let a_acc = case cl.guard {
          Some(g) -> on_expr(a_acc, g)
          None -> a_acc
        }
        let a_acc =
          list.fold(cl.prefix_bindings, a_acc, fn(pb_acc, pb) {
            on_expr(pb_acc, pb.1)
          })
        on_expr(a_acc, cl.body)
      })
    }
    IrEcho(expr: inner, message:, ..) -> {
      let acc = on_expr(acc, inner)
      case message {
        Some(m) -> on_expr(acc, m)
        None -> acc
      }
    }
    IrAbort(message:, ..) ->
      case message {
        Some(m) -> on_expr(acc, m)
        None -> acc
      }
  }
}

/// Transform immediate children of `stmt` without changing binding scope.
pub fn map_stmt_children(
  stmt: IrStmt,
  on_expr: fn(IrExpr) -> IrExpr,
  on_pat: fn(IrPattern) -> IrPattern,
  on_type: fn(IrType) -> IrType,
) -> IrStmt {
  case stmt {
    IrStmtLet(pattern:, annotation:, value:) ->
      IrStmtLet(
        pattern: on_pat(pattern),
        annotation: option.map(annotation, on_type),
        value: on_expr(value),
      )
    IrStmtGuard(
      value:,
      pattern:,
      guard_condition:,
      abort_message:,
      post_bindings:,
    ) ->
      IrStmtGuard(
        value: on_expr(value),
        pattern: on_pat(pattern),
        guard_condition: option.map(guard_condition, on_expr),
        abort_message: option.map(abort_message, on_expr),
        post_bindings: list.map(post_bindings, fn(pb) { #(pb.0, on_expr(pb.1)) }),
      )
    IrStmtAssert(condition:, abort_message:) ->
      IrStmtAssert(
        condition: on_expr(condition),
        abort_message: option.map(abort_message, on_expr),
      )
    IrStmtExpr(e) -> IrStmtExpr(on_expr(e))
  }
}

/// Transform immediate children of `expr` without altering binder scopes.
pub fn map_expr_children(
  expr: IrExpr,
  on_expr: fn(IrExpr) -> IrExpr,
  on_stmts: fn(List(IrStmt)) -> List(IrStmt),
  on_pat: fn(IrPattern) -> IrPattern,
  on_type: fn(IrType) -> IrType,
) -> IrExpr {
  case expr {
    ir.IrInt(_)
    | ir.IrFloat(_)
    | ir.IrString(_)
    | ir.IrBool(_)
    | ir.IrUnit
    | IrVar(_)
    | ir.IrModuleRef(..)
    | ir.IrConstructor(..) -> expr
    IrTuple(els) -> IrTuple(list.map(els, on_expr))
    IrContinue(els) -> IrContinue(list.map(els, on_expr))
    IrTupleIndex(tuple:, index:) -> IrTupleIndex(tuple: on_expr(tuple), index:)
    IrList(elements:, tail:) ->
      IrList(
        elements: list.map(elements, on_expr),
        tail: option.map(tail, on_expr),
      )
    IrBitString(segments:) ->
      IrBitString(
        list.map(segments, fn(seg) {
          let new_opts =
            list.map(seg.1, fn(opt) {
              case opt {
                glance.SizeValueOption(se) ->
                  glance.SizeValueOption(on_expr(se))
                other -> other
              }
            })
          #(on_expr(seg.0), new_opts)
        }),
      )
    IrNegateInt(inner) -> IrNegateInt(on_expr(inner))
    IrNegateBool(inner) -> IrNegateBool(on_expr(inner))
    IrBreak(inner) -> IrBreak(on_expr(inner))
    IrGetterCall(receiver:, field:) ->
      IrGetterCall(receiver: on_expr(receiver), field:)
    IrBinOp(op:, left:, right:) ->
      IrBinOp(op:, left: on_expr(left), right: on_expr(right))
    IrCall(function:, args:) ->
      IrCall(
        function: on_expr(function),
        args: list.map(args, fn(arg) {
          IrCallArg(label: arg.label, value: on_expr(arg.value))
        }),
      )
    IrBlock(stmts) -> IrBlock(on_stmts(stmts))
    IrFn(params:, return_type:, body:) ->
      IrFn(
        params: list.map(params, fn(p) {
          IrFnParam(name: p.name, param_type: option.map(p.param_type, on_type))
        }),
        return_type: option.map(return_type, on_type),
        body: on_stmts(body),
      )
    IrForLoop(bindings:, body:) ->
      IrForLoop(
        bindings: list.map(bindings, fn(b) { #(b.0, on_expr(b.1)) }),
        body: on_stmts(body),
      )
    IrMatch(subjects:, clauses:) ->
      IrMatch(
        subjects: list.map(subjects, on_expr),
        clauses: list.map(clauses, fn(cl) {
          IrClause(
            patterns: list.map(cl.patterns, fn(alt) { list.map(alt, on_pat) }),
            guard: option.map(cl.guard, on_expr),
            prefix_bindings: list.map(cl.prefix_bindings, fn(pb) {
              #(pb.0, on_expr(pb.1))
            }),
            body: on_expr(cl.body),
          )
        }),
      )
    IrEcho(expr: inner, message:, file_path:, line:) ->
      IrEcho(
        expr: on_expr(inner),
        message: option.map(message, on_expr),
        file_path:,
        line:,
      )
    IrAbort(kind:, message:) ->
      IrAbort(kind:, message: option.map(message, on_expr))
  }
}
