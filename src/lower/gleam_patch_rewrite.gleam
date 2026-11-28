import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import lower/gleam_patch_types.{
  type CollectedItems, type ModIndex, type PatchMaps, CollectedItems,
  is_patched_local_ctor_for_target, is_patched_local_type_for_target,
}
import lower/ir.{
  type IrBitSize, type IrConstant, type IrExpr, type IrFunction, type IrModule,
  type IrPattern, type IrStmt, type IrType, IrBitSizeBinOp, IrBitSizeInt,
  IrBitSizeVar, IrBlock, IrCall, IrCallArg, IrClause, IrConstructor, IrFn,
  IrFnParam, IrForLoop, IrMatch, IrModuleRef, IrPatArg, IrPatBitString,
  IrPatVariant, IrStmtAssert, IrStmtExpr, IrStmtGuard, IrStmtLet, IrTypeNamed,
  IrVar,
}
import lower/ir_util
import lower/mangle

// -----------------------------------------------------------------------------
// Transitive helper collection (worklist + scoped ref collection)
// -----------------------------------------------------------------------------

pub fn drain_worklist(
  pending_fns: List(String),
  pending_consts: List(String),
  source_mod_name: String,
  src_idx: ModIndex,
  same_target_map: Dict(String, String),
  col: CollectedItems,
) -> CollectedItems {
  case pending_fns, pending_consts {
    [], [] -> col
    [fname, ..rest_fns], _ -> {
      let before_fns = col.fn_names
      let before_consts = col.const_names
      let next_col = case dict.get(src_idx.fns_by_name, fname) {
        Error(_) -> col
        Ok(f) -> {
          let bound =
            list.fold(f.params, set.new(), fn(acc, p) {
              set.insert(acc, p.name)
            })
          collect_refs_in_stmts(
            f.body,
            bound,
            source_mod_name,
            src_idx,
            same_target_map,
            col,
          )
        }
      }
      let new_fns = diff_prepended(next_col.fn_names, before_fns)
      let new_consts = diff_prepended(next_col.const_names, before_consts)
      drain_worklist(
        list.append(rest_fns, new_fns),
        list.append(pending_consts, new_consts),
        source_mod_name,
        src_idx,
        same_target_map,
        next_col,
      )
    }
    [], [cname, ..rest_consts] -> {
      let before_fns = col.fn_names
      let before_consts = col.const_names
      let next_col = case dict.get(src_idx.consts_by_name, cname) {
        Error(_) -> col
        Ok(c) ->
          collect_refs_in_expr(
            c.value,
            set.new(),
            source_mod_name,
            src_idx,
            same_target_map,
            col,
          )
      }
      let new_fns = diff_prepended(next_col.fn_names, before_fns)
      let new_consts = diff_prepended(next_col.const_names, before_consts)
      drain_worklist(
        new_fns,
        list.append(rest_consts, new_consts),
        source_mod_name,
        src_idx,
        same_target_map,
        next_col,
      )
    }
  }
}

fn diff_prepended(after: List(String), before: List(String)) -> List(String) {
  let n = list.length(after) - list.length(before)
  list.take(after, int.max(0, n)) |> list.reverse
}

fn record_ref(
  name: String,
  src_idx: ModIndex,
  same_target_map: Dict(String, String),
  col: CollectedItems,
) -> CollectedItems {
  case dict.has_key(same_target_map, name) {
    True -> col
    False ->
      case set.contains(src_idx.fn_names, name) {
        True ->
          case set.contains(col.visited_fns, name) {
            True -> col
            False ->
              CollectedItems(
                ..col,
                fn_names: [name, ..col.fn_names],
                visited_fns: set.insert(col.visited_fns, name),
              )
          }
        False ->
          case set.contains(src_idx.const_names, name) {
            True ->
              case set.contains(col.visited_consts, name) {
                True -> col
                False ->
                  CollectedItems(
                    ..col,
                    const_names: [name, ..col.const_names],
                    visited_consts: set.insert(col.visited_consts, name),
                  )
              }
            False -> col
          }
      }
  }
}

pub fn collect_refs_in_stmts(
  stmts: List(IrStmt),
  bound: Set(String),
  source_mod_name: String,
  src_idx: ModIndex,
  same_target_map: Dict(String, String),
  col: CollectedItems,
) -> CollectedItems {
  let #(_, out) =
    list.fold(stmts, #(bound, col), fn(acc, stmt) {
      let #(cur_bound, cur_col) = acc
      let rec_e = fn(e, b, c) {
        collect_refs_in_expr(e, b, source_mod_name, src_idx, same_target_map, c)
      }
      case stmt {
        IrStmtLet(pattern:, value:, ..) -> {
          let c1 = rec_e(value, cur_bound, cur_col)
          let c2 =
            collect_refs_in_pattern(
              pattern,
              cur_bound,
              src_idx,
              same_target_map,
              c1,
            )
          #(set.union(cur_bound, ir_util.pattern_bound_vars(pattern)), c2)
        }
        IrStmtGuard(
          value:,
          pattern:,
          guard_condition:,
          abort_message:,
          post_bindings:,
        ) -> {
          let c1 = rec_e(value, cur_bound, cur_col)
          let c2 =
            collect_refs_in_pattern(
              pattern,
              cur_bound,
              src_idx,
              same_target_map,
              c1,
            )
          let pat_bound =
            set.union(cur_bound, ir_util.pattern_bound_vars(pattern))
          let c3 = case guard_condition {
            Some(g) -> rec_e(g, pat_bound, c2)
            None -> c2
          }
          let c4 = case abort_message {
            Some(m) -> rec_e(m, pat_bound, c3)
            None -> c3
          }
          list.fold(post_bindings, #(pat_bound, c4), fn(p_acc, pb) {
            let #(b, c) = p_acc
            #(set.insert(b, pb.0), rec_e(pb.1, b, c))
          })
        }
        IrStmtAssert(condition:, abort_message:) -> {
          let c1 = rec_e(condition, cur_bound, cur_col)
          let c2 = case abort_message {
            Some(m) -> rec_e(m, cur_bound, c1)
            None -> c1
          }
          #(cur_bound, c2)
        }
        IrStmtExpr(expr) -> #(cur_bound, rec_e(expr, cur_bound, cur_col))
      }
    })
  out
}

fn collect_refs_in_expr(
  expr: IrExpr,
  bound: Set(String),
  source_mod_name: String,
  src_idx: ModIndex,
  same_target_map: Dict(String, String),
  col: CollectedItems,
) -> CollectedItems {
  let rec = fn(acc, e) {
    collect_refs_in_expr(
      e,
      bound,
      source_mod_name,
      src_idx,
      same_target_map,
      acc,
    )
  }
  case expr {
    IrVar(name) ->
      case set.contains(bound, name) {
        True -> col
        False -> record_ref(name, src_idx, same_target_map, col)
      }
    IrModuleRef(target_module:, symbol:, ..) ->
      case target_module == source_mod_name {
        True -> record_ref(symbol, src_idx, same_target_map, col)
        False -> col
      }
    IrBlock(stmts) ->
      collect_refs_in_stmts(
        stmts,
        bound,
        source_mod_name,
        src_idx,
        same_target_map,
        col,
      )
    IrFn(params:, body:, ..) -> {
      let fn_bound =
        list.fold(params, bound, fn(acc, p) { set.insert(acc, p.name) })
      collect_refs_in_stmts(
        body,
        fn_bound,
        source_mod_name,
        src_idx,
        same_target_map,
        col,
      )
    }
    IrForLoop(bindings:, body:) -> {
      let #(loop_bound, c1) =
        list.fold(bindings, #(bound, col), fn(acc, b) {
          let #(cur_b, cur_c) = acc
          #(set.insert(cur_b, b.0), rec(cur_c, b.1))
        })
      collect_refs_in_stmts(
        body,
        loop_bound,
        source_mod_name,
        src_idx,
        same_target_map,
        c1,
      )
    }
    IrMatch(subjects:, clauses:) -> {
      let c1 = list.fold(subjects, col, rec)
      list.fold(clauses, c1, fn(acc, cl) {
        let #(pat_bound, c_pat) =
          list.fold(cl.patterns, #(bound, acc), fn(p_acc, alt) {
            list.fold(alt, p_acc, fn(inner_acc, pat) {
              let #(ib, ic) = inner_acc
              let next_ic =
                collect_refs_in_pattern(pat, ib, src_idx, same_target_map, ic)
              #(set.union(ib, ir_util.pattern_bound_vars(pat)), next_ic)
            })
          })
        let c_guard = case cl.guard {
          Some(g) ->
            collect_refs_in_expr(
              g,
              pat_bound,
              source_mod_name,
              src_idx,
              same_target_map,
              c_pat,
            )
          None -> c_pat
        }
        let #(body_bound, c_pref) =
          list.fold(cl.prefix_bindings, #(pat_bound, c_guard), fn(b_acc, pb) {
            let #(b, c) = b_acc
            let nc =
              collect_refs_in_expr(
                pb.1,
                b,
                source_mod_name,
                src_idx,
                same_target_map,
                c,
              )
            #(set.insert(b, pb.0), nc)
          })
        collect_refs_in_expr(
          cl.body,
          body_bound,
          source_mod_name,
          src_idx,
          same_target_map,
          c_pref,
        )
      })
    }
    _ -> ir_util.fold_expr_direct_children(expr, col, rec)
  }
}

fn collect_refs_in_pattern(
  pat: IrPattern,
  bound: Set(String),
  src_idx: ModIndex,
  same_target_map: Dict(String, String),
  col: CollectedItems,
) -> CollectedItems {
  case pat {
    IrPatBitString(segments:) -> {
      let #(_, out) =
        list.fold(segments, #(bound, col), fn(acc, seg) {
          let #(cur_b, cur_c) = acc
          let c1 =
            collect_refs_in_pattern(
              seg.0,
              cur_b,
              src_idx,
              same_target_map,
              cur_c,
            )
          let c2 =
            list.fold(seg.1, c1, fn(inner, opt) {
              case opt {
                glance.SizeValueOption(bs) ->
                  collect_refs_in_bit_size(
                    bs,
                    cur_b,
                    src_idx,
                    same_target_map,
                    inner,
                  )
                _ -> inner
              }
            })
          #(set.union(cur_b, ir_util.pattern_bound_vars(seg.0)), c2)
        })
      out
    }
    _ ->
      ir_util.try_fold_pattern_with(
        pat,
        col,
        fn(acc, p) {
          case p {
            IrPatBitString(_) ->
              Ok(collect_refs_in_pattern(
                p,
                bound,
                src_idx,
                same_target_map,
                acc,
              ))
            _ -> Ok(acc)
          }
        },
        fn(acc, _) { Ok(acc) },
      )
      |> result.unwrap(col)
  }
}

fn collect_refs_in_bit_size(
  bs: IrBitSize,
  bound: Set(String),
  src_idx: ModIndex,
  same_target_map: Dict(String, String),
  col: CollectedItems,
) -> CollectedItems {
  case bs {
    IrBitSizeInt(_) -> col
    IrBitSizeVar(name) ->
      case set.contains(bound, name) {
        True -> col
        False -> record_ref(name, src_idx, same_target_map, col)
      }
    IrBitSizeBinOp(left:, right:, ..) -> {
      let c1 =
        collect_refs_in_bit_size(left, bound, src_idx, same_target_map, col)
      collect_refs_in_bit_size(right, bound, src_idx, same_target_map, c1)
    }
  }
}

// -----------------------------------------------------------------------------
// Local custom type / constructor cycle detection
// -----------------------------------------------------------------------------

pub fn check_no_local_type_refs(
  source_fn: IrFunction,
  helper_fns: List(IrFunction),
  helper_consts: List(IrConstant),
  source_mod: IrModule,
  src_idx: ModIndex,
  target_mod_name: String,
  patch_maps: PatchMaps,
) -> Result(Nil, String) {
  let visitor =
    local_type_visitor(
      source_mod.module_name,
      src_idx,
      target_mod_name,
      patch_maps,
    )
  let check_fn = fn(f: IrFunction) {
    use _ <- result.try(
      list.try_each(f.params, fn(p) {
        ir_util.try_fold_type(p.param_type, Nil, visitor.on_type)
      }),
    )
    use _ <- result.try(ir_util.try_fold_type(
      f.return_type,
      Nil,
      visitor.on_type,
    ))
    ir_util.try_fold_stmts(f.body, Nil, visitor)
  }
  use _ <- result.try(check_fn(source_fn))
  use _ <- result.try(list.try_each(helper_fns, check_fn))
  list.try_each(helper_consts, fn(c) {
    use _ <- result.try(ir_util.try_fold_type(
      c.value_type,
      Nil,
      visitor.on_type,
    ))
    ir_util.try_fold_expr(c.value, Nil, visitor)
  })
}

pub fn check_local_type_in_type(
  ty: IrType,
  source_mod_name: String,
  src_idx: ModIndex,
  target_mod_name: String,
  patch_maps: PatchMaps,
) -> Result(Nil, String) {
  let visitor =
    local_type_visitor(source_mod_name, src_idx, target_mod_name, patch_maps)
  ir_util.try_fold_type(ty, Nil, visitor.on_type)
}

fn local_type_visitor(
  source_mod_name: String,
  src_idx: ModIndex,
  target_mod_name: String,
  patch_maps: PatchMaps,
) -> ir_util.IrVisitor(Nil, String) {
  ir_util.IrVisitor(
    ..ir_util.default_visitor(),
    on_type: fn(_, ty) {
      case ty {
        IrTypeNamed(module:, name:, ..) -> {
          let is_local = module == "" || module == source_mod_name
          let patched =
            is_patched_local_type_for_target(
              source_mod_name,
              name,
              target_mod_name,
              patch_maps,
            )
          case is_local && set.contains(src_idx.type_names, name) && !patched {
            True -> Error(cycle_error(source_mod_name, target_mod_name, name))
            False -> Ok(Nil)
          }
        }
        _ -> Ok(Nil)
      }
    },
    on_expr: fn(_, expr) {
      case expr {
        IrConstructor(target_module:, name:, ..) -> {
          let is_local =
            target_module == None || target_module == Some(source_mod_name)
          let patched =
            is_patched_local_ctor_for_target(
              source_mod_name,
              name,
              target_mod_name,
              patch_maps,
            )
          case is_local && set.contains(src_idx.ctor_names, name) && !patched {
            True -> Error(cycle_error(source_mod_name, target_mod_name, name))
            False -> Ok(Nil)
          }
        }
        _ -> Ok(Nil)
      }
    },
    on_pattern: fn(_, pat) {
      case pat {
        IrPatVariant(target_module:, constructor:, ..) -> {
          let is_local =
            target_module == None || target_module == Some(source_mod_name)
          let patched =
            is_patched_local_ctor_for_target(
              source_mod_name,
              constructor,
              target_mod_name,
              patch_maps,
            )
          case
            is_local
            && set.contains(src_idx.ctor_names, constructor)
            && !patched
          {
            True ->
              Error(cycle_error(source_mod_name, target_mod_name, constructor))
            False -> Ok(Nil)
          }
        }
        _ -> Ok(Nil)
      }
    },
  )
}

fn cycle_error(
  source_mod_name: String,
  target_mod_name: String,
  item_name: String,
) -> String {
  "Gleam patch in '"
  <> source_mod_name
  <> "' targeting '"
  <> target_mod_name
  <> "' references local type/constructor '"
  <> item_name
  <> "' defined in '"
  <> source_mod_name
  <> "', which would create a circular import; move helper types to a separate module that does not import '"
  <> target_mod_name
  <> "'"
}

// -----------------------------------------------------------------------------
// IR rewriting from source_mod context into target_mod context
// -----------------------------------------------------------------------------

pub fn rewrite_ir_type(
  ty: IrType,
  source_mod: IrModule,
  target_mod_name: String,
  patch_maps: PatchMaps,
) -> IrType {
  let rec = rewrite_ir_type(_, source_mod, target_mod_name, patch_maps)
  case ty {
    IrTypeNamed(module_alias:, package:, module:, name:, args:) -> {
      let new_args = list.map(args, rec)
      let resolved_mod = case module {
        "" -> source_mod.module_name
        m -> m
      }
      case dict.get(patch_maps.mirrors_by_mod, resolved_mod) {
        Ok(mm) if mm.target_mod_name == target_mod_name ->
          case dict.get(mm.type_map, name) {
            Ok(target_ty_name) ->
              IrTypeNamed(
                module_alias: None,
                package: mm.target_pkg_name,
                module: target_mod_name,
                name: target_ty_name,
                args: new_args,
              )
            Error(_) ->
              IrTypeNamed(
                module_alias:,
                package:,
                module:,
                name:,
                args: new_args,
              )
          }
        _ ->
          case dict.get(patch_maps.type_patch_map, #(resolved_mod, name)) {
            Ok(#(patched_mod, patched_name, patched_pkg)) ->
              case patched_mod == target_mod_name {
                True ->
                  IrTypeNamed(
                    module_alias: None,
                    package: patched_pkg,
                    module: patched_mod,
                    name: patched_name,
                    args: new_args,
                  )
                False ->
                  IrTypeNamed(
                    module_alias: Some(mangle.module_to_alias(patched_mod)),
                    package: patched_pkg,
                    module: patched_mod,
                    name: patched_name,
                    args: new_args,
                  )
              }
            Error(_) ->
              case module == target_mod_name {
                True ->
                  IrTypeNamed(
                    module_alias: None,
                    package:,
                    module:,
                    name:,
                    args: new_args,
                  )
                False ->
                  case module == "" {
                    True ->
                      IrTypeNamed(
                        module_alias: None,
                        package: source_mod.package_name,
                        module: source_mod.module_name,
                        name:,
                        args: new_args,
                      )
                    False ->
                      IrTypeNamed(
                        module_alias:,
                        package:,
                        module:,
                        name:,
                        args: new_args,
                      )
                  }
              }
          }
      }
    }
    _ -> ir_util.map_type_children(ty, rec)
  }
}

pub fn rewrite_stmts(
  stmts: List(IrStmt),
  bound: Set(String),
  source_mod: IrModule,
  src_idx: ModIndex,
  target_mod_name: String,
  patch_maps: PatchMaps,
  renames: Dict(String, String),
) -> List(IrStmt) {
  let #(_, rev_out) =
    list.fold(stmts, #(bound, []), fn(acc, stmt) {
      let #(cur_bound, rev_acc) = acc
      let rw_e = fn(e, b) {
        rewrite_expr(
          e,
          b,
          source_mod,
          src_idx,
          target_mod_name,
          patch_maps,
          renames,
        )
      }
      let rw_p = fn(p, b) {
        rewrite_pattern(
          p,
          b,
          source_mod,
          src_idx,
          target_mod_name,
          patch_maps,
          renames,
        )
      }
      let rw_t = rewrite_ir_type(_, source_mod, target_mod_name, patch_maps)
      case stmt {
        IrStmtLet(pattern:, annotation:, value:) -> {
          let next_bound =
            set.union(cur_bound, ir_util.pattern_bound_vars(pattern))
          #(next_bound, [
            IrStmtLet(
              pattern: rw_p(pattern, cur_bound),
              annotation: option.map(annotation, rw_t),
              value: rw_e(value, cur_bound),
            ),
            ..rev_acc
          ])
        }
        IrStmtGuard(
          value:,
          pattern:,
          guard_condition:,
          abort_message:,
          post_bindings:,
        ) -> {
          let pat_bound =
            set.union(cur_bound, ir_util.pattern_bound_vars(pattern))
          let #(after_bound, rev_posts) =
            list.fold(post_bindings, #(pat_bound, []), fn(p_acc, pb) {
              let #(b, out_p) = p_acc
              #(set.insert(b, pb.0), [#(pb.0, rw_e(pb.1, b)), ..out_p])
            })
          #(after_bound, [
            IrStmtGuard(
              value: rw_e(value, cur_bound),
              pattern: rw_p(pattern, cur_bound),
              guard_condition: option.map(guard_condition, rw_e(_, pat_bound)),
              abort_message: option.map(abort_message, rw_e(_, pat_bound)),
              post_bindings: list.reverse(rev_posts),
            ),
            ..rev_acc
          ])
        }
        IrStmtAssert(..) | IrStmtExpr(_) -> #(cur_bound, [
          ir_util.map_stmt_children(
            stmt,
            rw_e(_, cur_bound),
            rw_p(_, cur_bound),
            rw_t,
          ),
          ..rev_acc
        ])
      }
    })
  list.reverse(rev_out)
}

pub fn rewrite_expr(
  expr: IrExpr,
  bound: Set(String),
  source_mod: IrModule,
  src_idx: ModIndex,
  target_mod_name: String,
  patch_maps: PatchMaps,
  renames: Dict(String, String),
) -> IrExpr {
  let rec_e = rewrite_expr(
    _,
    bound,
    source_mod,
    src_idx,
    target_mod_name,
    patch_maps,
    renames,
  )
  let rec_s = rewrite_stmts(
    _,
    bound,
    source_mod,
    src_idx,
    target_mod_name,
    patch_maps,
    renames,
  )
  let rec_p = rewrite_pattern(
    _,
    bound,
    source_mod,
    src_idx,
    target_mod_name,
    patch_maps,
    renames,
  )
  let rec_t = rewrite_ir_type(_, source_mod, target_mod_name, patch_maps)

  case expr {
    IrVar(name) ->
      case set.contains(bound, name) {
        True -> expr
        False -> IrVar(rename_or_keep(name, renames))
      }
    IrModuleRef(module_alias:, target_module:, symbol:) ->
      case dict.get(patch_maps.mirrors_by_mod, target_module) {
        Ok(mm) if mm.target_mod_name == target_mod_name ->
          case
            set.contains(mm.to_public_fns, symbol)
            || set.contains(mm.from_public_fns, symbol)
          {
            True ->
              IrFn(
                params: [IrFnParam(name: "__gekko_id", param_type: None)],
                return_type: None,
                body: [IrStmtExpr(IrVar("__gekko_id"))],
              )
            False ->
              case dict.get(mm.fn_map, symbol) {
                Ok(target_fn_sym) -> IrVar(target_fn_sym)
                Error(_) ->
                  case dict.get(mm.const_map, symbol) {
                    Ok(target_const_sym) -> IrVar(target_const_sym)
                    Error(_) ->
                      case dict.get(mm.const_fn_map, symbol) {
                        Ok(target_const_sym) ->
                          IrFn(params: [], return_type: None, body: [
                            IrStmtExpr(IrVar(target_const_sym)),
                          ])
                        Error(_) ->
                          IrModuleRef(module_alias:, target_module:, symbol:)
                      }
                  }
              }
          }
        _ ->
          case target_module == target_mod_name {
            True -> IrVar(symbol)
            False ->
              case target_module == source_mod.module_name {
                True -> IrVar(rename_or_keep(symbol, renames))
                False -> IrModuleRef(module_alias:, target_module:, symbol:)
              }
          }
      }
    IrConstructor(module_alias:, target_module:, name:) -> {
      let resolved_ctor_mod = case target_module {
        Some(m) -> m
        None -> source_mod.module_name
      }
      case dict.get(patch_maps.mirrors_by_mod, resolved_ctor_mod) {
        Ok(mm) if mm.target_mod_name == target_mod_name ->
          case dict.get(mm.ctor_map, name) {
            Ok(target_ctor) ->
              IrConstructor(
                module_alias: None,
                target_module: None,
                name: target_ctor,
              )
            Error(_) -> IrConstructor(module_alias:, target_module:, name:)
          }
        _ ->
          case
            dict.get(patch_maps.type_patch_ctor_map, #(resolved_ctor_mod, name))
          {
            Ok(#(patched_mod, patched_ctor)) ->
              case patched_mod == target_mod_name {
                True ->
                  IrConstructor(
                    module_alias: None,
                    target_module: None,
                    name: patched_ctor,
                  )
                False ->
                  IrConstructor(
                    module_alias: Some(mangle.module_to_alias(patched_mod)),
                    target_module: Some(patched_mod),
                    name: patched_ctor,
                  )
              }
            Error(_) ->
              case target_module == Some(target_mod_name) {
                True ->
                  IrConstructor(module_alias: None, target_module: None, name:)
                False ->
                  case
                    target_module == None
                    && set.contains(src_idx.ctor_names, name)
                  {
                    True ->
                      IrConstructor(
                        module_alias: Some(mangle.module_to_alias(
                          source_mod.module_name,
                        )),
                        target_module: Some(source_mod.module_name),
                        name:,
                      )
                    False -> IrConstructor(module_alias:, target_module:, name:)
                  }
              }
          }
      }
    }
    IrCall(function:, args:) ->
      case function, args {
        IrModuleRef(target_module: m, symbol: sym, ..),
          [IrCallArg(value: inner_val, ..)]
        ->
          case dict.get(patch_maps.mirrors_by_mod, m) {
            Ok(mm) if mm.target_mod_name == target_mod_name ->
              case
                set.contains(mm.to_public_fns, sym)
                || set.contains(mm.from_public_fns, sym)
              {
                True -> rec_e(inner_val)
                False ->
                  ir_util.map_expr_children(expr, rec_e, rec_s, rec_p, rec_t)
              }
            _ -> ir_util.map_expr_children(expr, rec_e, rec_s, rec_p, rec_t)
          }
        IrModuleRef(target_module: m, symbol: sym, ..), [] ->
          case dict.get(patch_maps.mirrors_by_mod, m) {
            Ok(mm) if mm.target_mod_name == target_mod_name ->
              case dict.get(mm.const_fn_map, sym) {
                Ok(target_const_sym) -> IrVar(target_const_sym)
                Error(_) ->
                  ir_util.map_expr_children(expr, rec_e, rec_s, rec_p, rec_t)
              }
            _ -> ir_util.map_expr_children(expr, rec_e, rec_s, rec_p, rec_t)
          }
        _, _ -> ir_util.map_expr_children(expr, rec_e, rec_s, rec_p, rec_t)
      }
    IrFn(params:, return_type:, body:) -> {
      let fn_bound =
        list.fold(params, bound, fn(acc, p) { set.insert(acc, p.name) })
      let new_params =
        list.map(params, fn(p) {
          IrFnParam(name: p.name, param_type: option.map(p.param_type, rec_t))
        })
      IrFn(
        params: new_params,
        return_type: option.map(return_type, rec_t),
        body: rewrite_stmts(
          body,
          fn_bound,
          source_mod,
          src_idx,
          target_mod_name,
          patch_maps,
          renames,
        ),
      )
    }
    IrForLoop(bindings:, body:) -> {
      let #(loop_bound, rev_binds) =
        list.fold(bindings, #(bound, []), fn(acc, b) {
          let #(cur_b, out) = acc
          #(set.insert(cur_b, b.0), [#(b.0, rec_e(b.1)), ..out])
        })
      IrForLoop(
        bindings: list.reverse(rev_binds),
        body: rewrite_stmts(
          body,
          loop_bound,
          source_mod,
          src_idx,
          target_mod_name,
          patch_maps,
          renames,
        ),
      )
    }
    IrMatch(subjects:, clauses:) ->
      IrMatch(
        subjects: list.map(subjects, rec_e),
        clauses: list.map(clauses, fn(cl) {
          let #(pat_bound, rev_pats) =
            list.fold(cl.patterns, #(bound, []), fn(p_acc, alt) {
              let #(cur_b, alts_out) = p_acc
              let #(next_b, rev_alt) =
                list.fold(alt, #(cur_b, []), fn(inner_acc, pat) {
                  let #(ib, i_out) = inner_acc
                  let np =
                    rewrite_pattern(
                      pat,
                      ib,
                      source_mod,
                      src_idx,
                      target_mod_name,
                      patch_maps,
                      renames,
                    )
                  #(set.union(ib, ir_util.pattern_bound_vars(pat)), [
                    np,
                    ..i_out
                  ])
                })
              #(next_b, [list.reverse(rev_alt), ..alts_out])
            })
          let new_guard =
            option.map(cl.guard, rewrite_expr(
              _,
              pat_bound,
              source_mod,
              src_idx,
              target_mod_name,
              patch_maps,
              renames,
            ))
          let #(body_bound, rev_prefs) =
            list.fold(cl.prefix_bindings, #(pat_bound, []), fn(b_acc, pb) {
              let #(b, out) = b_acc
              let nv =
                rewrite_expr(
                  pb.1,
                  b,
                  source_mod,
                  src_idx,
                  target_mod_name,
                  patch_maps,
                  renames,
                )
              #(set.insert(b, pb.0), [#(pb.0, nv), ..out])
            })
          IrClause(
            patterns: list.reverse(rev_pats),
            guard: new_guard,
            prefix_bindings: list.reverse(rev_prefs),
            body: rewrite_expr(
              cl.body,
              body_bound,
              source_mod,
              src_idx,
              target_mod_name,
              patch_maps,
              renames,
            ),
          )
        }),
      )
    _ -> ir_util.map_expr_children(expr, rec_e, rec_s, rec_p, rec_t)
  }
}

fn rewrite_pattern(
  pat: IrPattern,
  bound: Set(String),
  source_mod: IrModule,
  src_idx: ModIndex,
  target_mod_name: String,
  patch_maps: PatchMaps,
  renames: Dict(String, String),
) -> IrPattern {
  let rec_p = rewrite_pattern(
    _,
    bound,
    source_mod,
    src_idx,
    target_mod_name,
    patch_maps,
    renames,
  )
  case pat {
    IrPatVariant(
      module_alias:,
      target_module:,
      constructor:,
      args:,
      with_spread:,
    ) -> {
      let resolved_ctor_mod = case target_module {
        Some(m) -> m
        None -> source_mod.module_name
      }
      let #(next_alias, next_target, next_ctor) = case
        dict.get(patch_maps.mirrors_by_mod, resolved_ctor_mod)
      {
        Ok(mm) if mm.target_mod_name == target_mod_name ->
          case dict.get(mm.ctor_map, constructor) {
            Ok(target_ctor) -> #(None, None, target_ctor)
            Error(_) -> #(module_alias, target_module, constructor)
          }
        _ ->
          case
            dict.get(patch_maps.type_patch_ctor_map, #(
              resolved_ctor_mod,
              constructor,
            ))
          {
            Ok(#(patched_mod, patched_ctor)) ->
              case patched_mod == target_mod_name {
                True -> #(None, None, patched_ctor)
                False -> #(
                  Some(mangle.module_to_alias(patched_mod)),
                  Some(patched_mod),
                  patched_ctor,
                )
              }
            Error(_) ->
              case target_module == Some(target_mod_name) {
                True -> #(None, None, constructor)
                False ->
                  case
                    target_module == None
                    && set.contains(src_idx.ctor_names, constructor)
                  {
                    True -> #(
                      Some(mangle.module_to_alias(source_mod.module_name)),
                      Some(source_mod.module_name),
                      constructor,
                    )
                    False -> #(module_alias, target_module, constructor)
                  }
              }
          }
      }
      IrPatVariant(
        module_alias: next_alias,
        target_module: next_target,
        constructor: next_ctor,
        args: list.map(args, fn(arg) {
          IrPatArg(label: arg.label, pattern: rec_p(arg.pattern))
        }),
        with_spread:,
      )
    }
    IrPatBitString(segments:) -> {
      let #(_, rev_segs) =
        list.fold(segments, #(bound, []), fn(acc, seg) {
          let #(cur_b, out) = acc
          let new_p =
            rewrite_pattern(
              seg.0,
              cur_b,
              source_mod,
              src_idx,
              target_mod_name,
              patch_maps,
              renames,
            )
          let new_opts =
            list.map(seg.1, fn(opt) {
              case opt {
                glance.SizeValueOption(bs) ->
                  glance.SizeValueOption(rewrite_bit_size(bs, cur_b, renames))
                other -> other
              }
            })
          let next_b = set.union(cur_b, ir_util.pattern_bound_vars(seg.0))
          #(next_b, [#(new_p, new_opts), ..out])
        })
      IrPatBitString(list.reverse(rev_segs))
    }
    _ -> ir_util.map_pattern_children(pat, rec_p, fn(bs) { bs })
  }
}

fn rewrite_bit_size(
  bs: IrBitSize,
  bound: Set(String),
  renames: Dict(String, String),
) -> IrBitSize {
  case bs {
    IrBitSizeInt(_) -> bs
    IrBitSizeVar(name) ->
      case set.contains(bound, name) {
        True -> bs
        False -> IrBitSizeVar(rename_or_keep(name, renames))
      }
    IrBitSizeBinOp(op:, left:, right:) ->
      IrBitSizeBinOp(
        op:,
        left: rewrite_bit_size(left, bound, renames),
        right: rewrite_bit_size(right, bound, renames),
      )
  }
}

fn rename_or_keep(name: String, renames: Dict(String, String)) -> String {
  dict.get(renames, name) |> result.unwrap(name)
}
