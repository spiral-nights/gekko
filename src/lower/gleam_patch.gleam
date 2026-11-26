import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import index/symbol_table.{type SymbolTable}
import lower/ir.{
  type IrBitSize, type IrConstant, type IrExpr, type IrFunction, type IrModule,
  type IrPattern, type IrStmt, type IrType, type IrTypeAlias, IrAbort, IrBinOp,
  IrBitSizeBinOp, IrBitSizeInt, IrBitSizeVar, IrBitString, IrBlock, IrBool,
  IrBreak, IrCall, IrCallArg, IrClause, IrConstant, IrConstructor, IrContinue,
  IrEcho, IrFloat, IrFn, IrForLoop, IrFunction, IrGetterCall, IrInt, IrList,
  IrMatch, IrModule, IrModuleRef, IrNegateBool, IrNegateInt, IrParam, IrPatArg,
  IrPatAs, IrPatBitString, IrPatBool, IrPatDiscard, IrPatFloat, IrPatInt,
  IrPatString, IrPatTuple, IrPatUnit, IrPatVar, IrPatVariant, IrStmtAssert,
  IrStmtExpr, IrStmtGuard, IrStmtLet, IrString, IrTuple, IrTupleIndex,
  IrTypeBitArray, IrTypeBool, IrTypeDouble, IrTypeFn, IrTypeInt64, IrTypeList,
  IrTypeNamed, IrTypeResult, IrTypeString, IrTypeTuple, IrTypeUnit, IrTypeVar,
  IrUnit, IrVar,
}
import lower/ir_util
import lower/mangle
import project/prepass.{GleamPatch}

type ModIndex {
  ModIndex(
    fns_by_unmangled: Dict(String, IrFunction),
    fns_by_name: Dict(String, IrFunction),
    consts_by_name: Dict(String, IrConstant),
    const_names: Set(String),
    fn_names: Set(String),
    type_names: Set(String),
    ctor_names: Set(String),
  )
}

type SplicedTracker {
  SplicedTracker(
    /// `(source_module, mangled_fn_name)` entries that were spliced as `@patch`.
    spliced_fns: Set(#(String, String)),
  )
}

type TypeBijection {
  TypeBijection(s_to_t: Dict(String, String), t_to_s: Dict(String, String))
}

/// Splice Gleam-written `@patch("mod.fn")` functions (and their transitive
/// private/module helpers and constants) directly into target `IrModule`s so
/// shims can import target module types without creating MoonBit import cycles.
pub fn splice_gleam_patches(
  ir_modules: List(IrModule),
  _table: SymbolTable,
) -> Result(List(IrModule), String) {
  let mods_by_name =
    list.fold(ir_modules, dict.new(), fn(acc, m) {
      dict.insert(acc, m.module_name, m)
    })
  let indices = dict.map_values(mods_by_name, fn(_k, m) { build_mod_index(m) })
  let all_aliases = build_alias_map(ir_modules)
  let all_patches_by_source = collect_all_patches_by_source(ir_modules)

  use #(rev_updated, tracker) <- result.try(
    list.try_fold(ir_modules, #([], SplicedTracker(set.new())), fn(acc, mod) {
      let #(mods_acc, cur_tracker) = acc
      use #(next_mod, next_tracker) <- result.try(splice_target_module(
        mod,
        mods_by_name,
        indices,
        all_aliases,
        all_patches_by_source,
        cur_tracker,
      ))
      Ok(#([next_mod, ..mods_acc], next_tracker))
    }),
  )
  let spliced_modules = list.reverse(rev_updated)
  Ok(list.map(spliced_modules, prune_source_module(_, tracker, indices)))
}

fn build_mod_index(mod: IrModule) -> ModIndex {
  let fns_by_unmangled =
    list.fold(mod.functions, dict.new(), fn(acc, f) {
      dict.insert(acc, f.unmangled_name, f)
    })
  let fns_by_name =
    list.fold(mod.functions, dict.new(), fn(acc, f) {
      dict.insert(acc, f.name, f)
    })
  let consts_by_name =
    list.fold(mod.constants, dict.new(), fn(acc, c) {
      dict.insert(acc, c.name, c)
    })
  let fn_names =
    list.fold(mod.functions, set.new(), fn(acc, f) { set.insert(acc, f.name) })
  let const_names =
    list.fold(mod.constants, set.new(), fn(acc, c) { set.insert(acc, c.name) })
  let #(type_names, ctor_names) =
    list.fold(mod.types, #(set.new(), set.new()), fn(acc, td) {
      let #(tys, ctors) = acc
      let next_tys =
        tys
        |> set.insert(td.name)
        |> set.insert(td.unmangled_name)
      let next_ctors =
        list.fold(td.variants, ctors, fn(c_acc, v) { set.insert(c_acc, v.name) })
      #(next_tys, next_ctors)
    })
  ModIndex(
    fns_by_unmangled:,
    fns_by_name:,
    consts_by_name:,
    const_names:,
    fn_names:,
    type_names:,
    ctor_names:,
  )
}

fn build_alias_map(
  ir_modules: List(IrModule),
) -> Dict(#(String, String), IrTypeAlias) {
  list.fold(ir_modules, dict.new(), fn(acc, mod) {
    list.fold(mod.type_aliases, acc, fn(inner, ta) {
      dict.insert(inner, #(mod.module_name, ta.name), ta)
    })
  })
}

/// Map `source_module -> target_module -> Dict(source_fn_mangled_name -> target_fn_mangled_name)`.
fn collect_all_patches_by_source(
  ir_modules: List(IrModule),
) -> Dict(String, Dict(String, Dict(String, String))) {
  list.fold(ir_modules, dict.new(), fn(acc, target_mod) {
    list.fold(target_mod.functions, acc, fn(inner, target_fn) {
      case target_fn.ffi {
        Some(GleamPatch(source_module:, source_function:)) -> {
          let src_map =
            dict.get(inner, source_module) |> result.unwrap(dict.new())
          let tgt_map =
            dict.get(src_map, target_mod.module_name)
            |> result.unwrap(dict.new())
          // Store under both raw source_function and mangled form so callers resolve cleanly
          let next_tgt =
            tgt_map
            |> dict.insert(source_function, target_fn.name)
            |> dict.insert(mangle.mangle_ident(source_function), target_fn.name)
          dict.insert(
            inner,
            source_module,
            dict.insert(src_map, target_mod.module_name, next_tgt),
          )
        }
        _ -> inner
      }
    })
  })
}

fn splice_target_module(
  target_mod: IrModule,
  mods_by_name: Dict(String, IrModule),
  indices: Dict(String, ModIndex),
  all_aliases: Dict(#(String, String), IrTypeAlias),
  all_patches_by_source: Dict(String, Dict(String, Dict(String, String))),
  tracker: SplicedTracker,
) -> Result(#(IrModule, SplicedTracker), String) {
  let has_gleam_patches =
    list.any(target_mod.functions, fn(f) {
      case f.ffi {
        Some(GleamPatch(_, _)) -> True
        _ -> False
      }
    })
  case has_gleam_patches {
    False -> Ok(#(target_mod, tracker))
    True -> {
      let target_idx =
        dict.get(indices, target_mod.module_name)
        |> result.unwrap(build_mod_index(target_mod))
      let existing_names =
        set.union(target_idx.fn_names, target_idx.const_names)

      use #(rev_fns, extra_fns, extra_consts, next_tracker, _used) <- result.try(
        list.try_fold(
          target_mod.functions,
          #([], [], [], tracker, existing_names),
          fn(state, target_fn) {
            let #(fns_acc, helpers_acc, consts_acc, cur_tracker, used_names) =
              state
            case target_fn.ffi {
              Some(GleamPatch(source_module:, source_function:)) -> {
                use source_mod <- result.try(
                  dict.get(mods_by_name, source_module)
                  |> result.map_error(fn(_) {
                    "Gleam patch source module '"
                    <> source_module
                    <> "' for '"
                    <> target_mod.module_name
                    <> "."
                    <> target_fn.unmangled_name
                    <> "' was not found in loaded packages"
                  }),
                )
                let src_idx =
                  dict.get(indices, source_module)
                  |> result.unwrap(build_mod_index(source_mod))
                use source_fn <- result.try(lookup_source_fn(
                  src_idx,
                  source_module,
                  source_function,
                  target_mod.module_name,
                  target_fn.unmangled_name,
                ))
                use _ <- result.try(validate_patch_signature(
                  source_mod,
                  source_fn,
                  target_mod,
                  target_fn,
                  all_aliases,
                ))

                let same_target_map =
                  all_patches_by_source
                  |> dict.get(source_module)
                  |> result.unwrap(dict.new())
                  |> dict.get(target_mod.module_name)
                  |> result.unwrap(dict.new())

                use #(rewritten_fn, new_helpers, new_consts, next_used) <- result.try(
                  splice_single_patch(
                    source_mod,
                    src_idx,
                    source_fn,
                    target_mod,
                    target_fn,
                    same_target_map,
                    used_names,
                  ),
                )

                let next_tracker =
                  SplicedTracker(
                    set.insert(cur_tracker.spliced_fns, #(
                      source_module,
                      source_fn.name,
                    )),
                  )
                Ok(#(
                  [rewritten_fn, ..fns_acc],
                  list.append(helpers_acc, new_helpers),
                  list.append(consts_acc, new_consts),
                  next_tracker,
                  next_used,
                ))
              }
              _ ->
                Ok(#(
                  [target_fn, ..fns_acc],
                  helpers_acc,
                  consts_acc,
                  cur_tracker,
                  used_names,
                ))
            }
          },
        ),
      )

      let deduped_consts =
        dedup_constants(list.append(target_mod.constants, extra_consts))
      let deduped_fns =
        dedup_functions(list.append(list.reverse(rev_fns), extra_fns))
      Ok(#(
        IrModule(
          ..target_mod,
          constants: deduped_consts,
          functions: deduped_fns,
        ),
        next_tracker,
      ))
    }
  }
}

fn lookup_source_fn(
  src_idx: ModIndex,
  source_module: String,
  source_function: String,
  target_module: String,
  target_fn_name: String,
) -> Result(IrFunction, String) {
  case dict.get(src_idx.fns_by_unmangled, source_function) {
    Ok(f) -> Ok(f)
    Error(_) ->
      case dict.get(src_idx.fns_by_name, source_function) {
        Ok(f) -> Ok(f)
        Error(_) ->
          Error(
            "Gleam patch function '"
            <> source_module
            <> "."
            <> source_function
            <> "' targeting '"
            <> target_module
            <> "."
            <> target_fn_name
            <> "' was not found",
          )
      }
  }
}

fn dedup_constants(consts: List(IrConstant)) -> List(IrConstant) {
  let #(_, rev) =
    list.fold(consts, #(set.new(), []), fn(acc, c) {
      let #(seen, out) = acc
      case set.contains(seen, c.name) {
        True -> acc
        False -> #(set.insert(seen, c.name), [c, ..out])
      }
    })
  list.reverse(rev)
}

fn dedup_functions(fns: List(IrFunction)) -> List(IrFunction) {
  let #(_, rev) =
    list.fold(fns, #(set.new(), []), fn(acc, f) {
      let #(seen, out) = acc
      case set.contains(seen, f.name) {
        True -> acc
        False -> #(set.insert(seen, f.name), [f, ..out])
      }
    })
  list.reverse(rev)
}

// -----------------------------------------------------------------------------
// Signature checking (parameter count, types, return type, type var bijection)
// -----------------------------------------------------------------------------

fn validate_patch_signature(
  source_mod: IrModule,
  source_fn: IrFunction,
  target_mod: IrModule,
  target_fn: IrFunction,
  all_aliases: Dict(#(String, String), IrTypeAlias),
) -> Result(Nil, String) {
  let s_label = source_mod.module_name <> "." <> source_fn.unmangled_name
  let t_label = target_mod.module_name <> "." <> target_fn.unmangled_name
  let s_arity = list.length(source_fn.params)
  let t_arity = list.length(target_fn.params)
  case s_arity == t_arity {
    False ->
      Error(
        "Gleam patch arity mismatch: '"
        <> s_label
        <> "' takes "
        <> int.to_string(s_arity)
        <> " parameter(s), but '"
        <> t_label
        <> "' expects "
        <> int.to_string(t_arity),
      )
    True -> {
      let init_bij = TypeBijection(dict.new(), dict.new())
      let param_pairs = list.zip(source_fn.params, target_fn.params)
      use bij_after_params <- result.try(
        list.index_fold(param_pairs, Ok(init_bij), fn(acc, pair, idx) {
          use cur_bij <- result.try(acc)
          let #(sp, tp) = pair
          let ns =
            normalize_type(sp.param_type, source_mod.module_name, all_aliases)
          let nt =
            normalize_type(tp.param_type, target_mod.module_name, all_aliases)
          case unify_sig_types(ns, nt, cur_bij) {
            Ok(next_bij) -> Ok(next_bij)
            Error(detail) ->
              Error(
                "Gleam patch parameter "
                <> int.to_string(idx + 1)
                <> " type mismatch between '"
                <> s_label
                <> "' ("
                <> format_ir_type(ns)
                <> ") and '"
                <> t_label
                <> "' ("
                <> format_ir_type(nt)
                <> ")"
                <> detail,
              )
          }
        }),
      )
      let ns_ret =
        normalize_type(
          source_fn.return_type,
          source_mod.module_name,
          all_aliases,
        )
      let nt_ret =
        normalize_type(
          target_fn.return_type,
          target_mod.module_name,
          all_aliases,
        )
      case unify_sig_types(ns_ret, nt_ret, bij_after_params) {
        Ok(_) -> Ok(Nil)
        Error(detail) ->
          Error(
            "Gleam patch return type mismatch between '"
            <> s_label
            <> "' ("
            <> format_ir_type(ns_ret)
            <> ") and '"
            <> t_label
            <> "' ("
            <> format_ir_type(nt_ret)
            <> ")"
            <> detail,
          )
      }
    }
  }
}

fn normalize_type(
  ty: IrType,
  cur_mod: String,
  all_aliases: Dict(#(String, String), IrTypeAlias),
) -> IrType {
  normalize_type_loop(ty, cur_mod, all_aliases, set.new())
}

fn normalize_type_loop(
  ty: IrType,
  cur_mod: String,
  all_aliases: Dict(#(String, String), IrTypeAlias),
  visited: Set(#(String, String)),
) -> IrType {
  case ty {
    IrTypeInt64
    | IrTypeDouble
    | IrTypeString
    | IrTypeBool
    | IrTypeUnit
    | IrTypeBitArray
    | IrTypeVar(_) -> ty
    IrTypeList(inner) ->
      IrTypeList(normalize_type_loop(inner, cur_mod, all_aliases, visited))
    IrTypeResult(ok_t, err_t) ->
      IrTypeResult(
        normalize_type_loop(ok_t, cur_mod, all_aliases, visited),
        normalize_type_loop(err_t, cur_mod, all_aliases, visited),
      )
    IrTypeTuple(els) ->
      IrTypeTuple(
        list.map(els, normalize_type_loop(_, cur_mod, all_aliases, visited)),
      )
    IrTypeFn(params, ret) ->
      IrTypeFn(
        list.map(params, normalize_type_loop(_, cur_mod, all_aliases, visited)),
        normalize_type_loop(ret, cur_mod, all_aliases, visited),
      )
    IrTypeNamed(module_alias:, package:, module:, name:, args:) -> {
      let resolved_mod = case module {
        "" -> cur_mod
        m -> m
      }
      let norm_args =
        list.map(args, normalize_type_loop(_, cur_mod, all_aliases, visited))
      let key = #(resolved_mod, name)
      case set.contains(visited, key) {
        True ->
          IrTypeNamed(
            module_alias:,
            package:,
            module: resolved_mod,
            name:,
            args: norm_args,
          )
        False ->
          case dict.get(all_aliases, key) {
            Ok(ta) ->
              case list.length(ta.type_params) == list.length(norm_args) {
                False ->
                  IrTypeNamed(
                    module_alias:,
                    package:,
                    module: resolved_mod,
                    name:,
                    args: norm_args,
                  )
                True -> {
                  let subst =
                    list.zip(ta.type_params, norm_args) |> dict.from_list
                  let expanded = subst_type(ta.aliased, subst)
                  normalize_type_loop(
                    expanded,
                    resolved_mod,
                    all_aliases,
                    set.insert(visited, key),
                  )
                }
              }
            Error(_) ->
              IrTypeNamed(
                module_alias:,
                package:,
                module: resolved_mod,
                name:,
                args: norm_args,
              )
          }
      }
    }
  }
}

fn subst_type(ty: IrType, subst: Dict(String, IrType)) -> IrType {
  case ty {
    IrTypeVar(v) -> dict.get(subst, v) |> result.unwrap(ty)
    IrTypeList(inner) -> IrTypeList(subst_type(inner, subst))
    IrTypeResult(ok_t, err_t) ->
      IrTypeResult(subst_type(ok_t, subst), subst_type(err_t, subst))
    IrTypeTuple(els) -> IrTypeTuple(list.map(els, subst_type(_, subst)))
    IrTypeFn(params, ret) ->
      IrTypeFn(list.map(params, subst_type(_, subst)), subst_type(ret, subst))
    IrTypeNamed(args:, ..) ->
      IrTypeNamed(..ty, args: list.map(args, subst_type(_, subst)))
    _ -> ty
  }
}

fn unify_sig_types(
  a: IrType,
  b: IrType,
  bij: TypeBijection,
) -> Result(TypeBijection, String) {
  case a, b {
    IrTypeInt64, IrTypeInt64
    | IrTypeDouble, IrTypeDouble
    | IrTypeString, IrTypeString
    | IrTypeBool, IrTypeBool
    | IrTypeUnit, IrTypeUnit
    | IrTypeBitArray, IrTypeBitArray
    -> Ok(bij)
    IrTypeList(ia), IrTypeList(ib) -> unify_sig_types(ia, ib, bij)
    IrTypeResult(oa, ea), IrTypeResult(ob, eb) -> {
      use b1 <- result.try(unify_sig_types(oa, ob, bij))
      unify_sig_types(ea, eb, b1)
    }
    IrTypeTuple(ea), IrTypeTuple(eb) -> unify_sig_type_lists(ea, eb, bij)
    IrTypeFn(pa, ra), IrTypeFn(pb, rb) -> {
      use b1 <- result.try(unify_sig_type_lists(pa, pb, bij))
      unify_sig_types(ra, rb, b1)
    }
    IrTypeNamed(module: ma, name: na, args: aa, ..),
      IrTypeNamed(module: mb, name: nb, args: ab, ..)
      if ma == mb && na == nb
    -> unify_sig_type_lists(aa, ab, bij)
    IrTypeVar(va), IrTypeVar(vb) ->
      case dict.get(bij.s_to_t, va), dict.get(bij.t_to_s, vb) {
        Ok(expected_vb), Ok(expected_va) ->
          case expected_vb == vb && expected_va == va {
            True -> Ok(bij)
            False -> Error("")
          }
        Error(_), Error(_) ->
          Ok(TypeBijection(
            s_to_t: dict.insert(bij.s_to_t, va, vb),
            t_to_s: dict.insert(bij.t_to_s, vb, va),
          ))
        _, _ -> Error("")
      }
    _, _ -> Error("")
  }
}

fn unify_sig_type_lists(
  xs: List(IrType),
  ys: List(IrType),
  bij: TypeBijection,
) -> Result(TypeBijection, String) {
  case xs, ys {
    [], [] -> Ok(bij)
    [hx, ..tx], [hy, ..ty] -> {
      use b1 <- result.try(unify_sig_types(hx, hy, bij))
      unify_sig_type_lists(tx, ty, b1)
    }
    _, _ -> Error("")
  }
}

fn format_ir_type(ty: IrType) -> String {
  case ty {
    IrTypeInt64 -> "Int"
    IrTypeDouble -> "Float"
    IrTypeString -> "String"
    IrTypeBool -> "Bool"
    IrTypeUnit -> "Nil"
    IrTypeBitArray -> "BitArray"
    IrTypeList(i) -> "List(" <> format_ir_type(i) <> ")"
    IrTypeResult(o, e) ->
      "Result(" <> format_ir_type(o) <> ", " <> format_ir_type(e) <> ")"
    IrTypeTuple(els) ->
      "#(" <> string.join(list.map(els, format_ir_type), ", ") <> ")"
    IrTypeFn(ps, r) ->
      "fn("
      <> string.join(list.map(ps, format_ir_type), ", ")
      <> ") -> "
      <> format_ir_type(r)
    IrTypeVar(v) -> v
    IrTypeNamed(module:, name:, args:, ..) -> {
      let base = case module {
        "" -> name
        _ -> module <> "." <> name
      }
      case args {
        [] -> base
        _ ->
          base
          <> "("
          <> string.join(list.map(args, format_ir_type), ", ")
          <> ")"
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Transitive helper collection, cycle checking, and IR rewriting
// -----------------------------------------------------------------------------

type CollectedItems {
  CollectedItems(
    fn_names: List(String),
    const_names: List(String),
    visited_fns: Set(String),
    visited_consts: Set(String),
  )
}

fn splice_single_patch(
  source_mod: IrModule,
  src_idx: ModIndex,
  source_fn: IrFunction,
  target_mod: IrModule,
  target_fn: IrFunction,
  same_target_map: Dict(String, String),
  used_names: Set(String),
) -> Result(
  #(IrFunction, List(IrFunction), List(IrConstant), Set(String)),
  String,
) {
  let root_bound =
    list.fold(source_fn.params, set.new(), fn(acc, p) {
      set.insert(acc, p.name)
    })

  case source_fn.ffi {
    Some(_) as passthrough_ffi -> {
      let src_imports_target =
        source_mod.module_name != target_mod.module_name
        && list.any(source_mod.imports, fn(imp) {
          imp.module == target_mod.module_name
        })
      use _ <- result.try(case src_imports_target {
        False -> Ok(Nil)
        True ->
          check_no_local_type_refs(
            IrFunction(..source_fn, body: []),
            [],
            [],
            source_mod,
            src_idx,
            target_mod.module_name,
          )
      })
      let merged_params =
        list.zip(target_fn.params, source_fn.params)
        |> list.map(fn(pair) {
          let #(tp, sp) = pair
          IrParam(
            label: tp.label,
            name: sp.name,
            param_type: rewrite_ir_type(
              sp.param_type,
              source_mod,
              target_mod.module_name,
            ),
          )
        })
      let rewritten_target =
        IrFunction(
          name: target_fn.name,
          unmangled_name: target_fn.unmangled_name,
          publicity: target_fn.publicity,
          type_params: source_fn.type_params,
          params: merged_params,
          return_type: rewrite_ir_type(
            source_fn.return_type,
            source_mod,
            target_mod.module_name,
          ),
          ffi: passthrough_ffi,
          external: False,
          body: [],
        )
      Ok(#(rewritten_target, [], [], used_names))
    }
    None -> {
      let init_col = CollectedItems([], [], set.new(), set.new())
      let col0 =
        collect_refs_in_stmts(
          source_fn.body,
          root_bound,
          source_mod.module_name,
          src_idx,
          same_target_map,
          init_col,
        )
      let collected =
        drain_worklist(
          list.reverse(col0.fn_names),
          list.reverse(col0.const_names),
          source_mod.module_name,
          src_idx,
          same_target_map,
          col0,
        )

      let helper_fns =
        list.filter_map(list.reverse(collected.fn_names), fn(name) {
          dict.get(src_idx.fns_by_name, name)
        })
      let helper_consts =
        list.filter_map(list.reverse(collected.const_names), fn(name) {
          dict.get(src_idx.consts_by_name, name)
        })

      let #(helper_renames, used1) =
        assign_helper_names(
          helper_fns,
          helper_consts,
          source_mod.module_name,
          same_target_map,
          used_names,
        )

      let src_imports_target =
        source_mod.module_name != target_mod.module_name
        && list.any(source_mod.imports, fn(imp) {
          imp.module == target_mod.module_name
        })
      use _ <- result.try(case src_imports_target {
        False -> Ok(Nil)
        True ->
          check_no_local_type_refs(
            source_fn,
            helper_fns,
            helper_consts,
            source_mod,
            src_idx,
            target_mod.module_name,
          )
      })

      let merged_params =
        list.zip(target_fn.params, source_fn.params)
        |> list.map(fn(pair) {
          let #(tp, sp) = pair
          IrParam(
            label: tp.label,
            name: sp.name,
            param_type: rewrite_ir_type(
              sp.param_type,
              source_mod,
              target_mod.module_name,
            ),
          )
        })

      let rewritten_body =
        rewrite_stmts(
          source_fn.body,
          root_bound,
          source_mod,
          src_idx,
          target_mod.module_name,
          helper_renames,
        )

      let rewritten_target =
        IrFunction(
          name: target_fn.name,
          unmangled_name: target_fn.unmangled_name,
          publicity: target_fn.publicity,
          type_params: source_fn.type_params,
          params: merged_params,
          return_type: rewrite_ir_type(
            source_fn.return_type,
            source_mod,
            target_mod.module_name,
          ),
          ffi: None,
          external: False,
          body: rewritten_body,
        )

      let rewritten_helpers =
        list.map(helper_fns, fn(hf) {
          let new_name =
            dict.get(helper_renames, hf.name) |> result.unwrap(hf.name)
          let hf_bound =
            list.fold(hf.params, set.new(), fn(acc, p) {
              set.insert(acc, p.name)
            })
          let hf_params =
            list.map(hf.params, fn(p) {
              IrParam(
                label: p.label,
                name: p.name,
                param_type: rewrite_ir_type(
                  p.param_type,
                  source_mod,
                  target_mod.module_name,
                ),
              )
            })
          let hf_body =
            rewrite_stmts(
              hf.body,
              hf_bound,
              source_mod,
              src_idx,
              target_mod.module_name,
              helper_renames,
            )
          IrFunction(
            name: new_name,
            unmangled_name: new_name,
            publicity: glance.Private,
            type_params: hf.type_params,
            params: hf_params,
            return_type: rewrite_ir_type(
              hf.return_type,
              source_mod,
              target_mod.module_name,
            ),
            ffi: hf.ffi,
            external: hf.external,
            body: hf_body,
          )
        })

      let rewritten_consts =
        list.map(helper_consts, fn(hc) {
          let new_name =
            dict.get(helper_renames, hc.name) |> result.unwrap(hc.name)
          IrConstant(
            name: new_name,
            unmangled_name: new_name,
            publicity: glance.Private,
            value_type: rewrite_ir_type(
              hc.value_type,
              source_mod,
              target_mod.module_name,
            ),
            value: rewrite_expr(
              hc.value,
              set.new(),
              source_mod,
              src_idx,
              target_mod.module_name,
              helper_renames,
            ),
          )
        })

      Ok(#(rewritten_target, rewritten_helpers, rewritten_consts, used1))
    }
  }
}

fn assign_helper_names(
  helper_fns: List(IrFunction),
  helper_consts: List(IrConstant),
  source_module: String,
  same_target_map: Dict(String, String),
  used_names: Set(String),
) -> #(Dict(String, String), Set(String)) {
  let prefix = "__gekko_shim_" <> sanitize_mod_id(source_module) <> "_"
  let #(renames1, used1) =
    list.fold(helper_fns, #(same_target_map, used_names), fn(acc, f) {
      let #(r_acc, u_acc) = acc
      let base = prefix <> f.name
      let unique = pick_unique_name(base, u_acc, 0)
      #(dict.insert(r_acc, f.name, unique), set.insert(u_acc, unique))
    })
  list.fold(helper_consts, #(renames1, used1), fn(acc, c) {
    let #(r_acc, u_acc) = acc
    let base = prefix <> c.name
    let unique = pick_unique_name(base, u_acc, 0)
    #(dict.insert(r_acc, c.name, unique), set.insert(u_acc, unique))
  })
}

fn pick_unique_name(base: String, used: Set(String), attempt: Int) -> String {
  let candidate = case attempt {
    0 -> base
    _ -> base <> "_" <> int.to_string(attempt)
  }
  case set.contains(used, candidate) {
    False -> candidate
    True -> pick_unique_name(base, used, attempt + 1)
  }
}

fn sanitize_mod_id(mod_name: String) -> String {
  string.replace(mod_name, "/", "_")
}

fn drain_worklist(
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

fn collect_refs_in_stmts(
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
      case stmt {
        IrStmtLet(pattern:, value:, ..) -> {
          let c1 =
            collect_refs_in_expr(
              value,
              cur_bound,
              source_mod_name,
              src_idx,
              same_target_map,
              cur_col,
            )
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
          let c1 =
            collect_refs_in_expr(
              value,
              cur_bound,
              source_mod_name,
              src_idx,
              same_target_map,
              cur_col,
            )
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
            Some(g) ->
              collect_refs_in_expr(
                g,
                pat_bound,
                source_mod_name,
                src_idx,
                same_target_map,
                c2,
              )
            None -> c2
          }
          let c4 = case abort_message {
            Some(m) ->
              collect_refs_in_expr(
                m,
                pat_bound,
                source_mod_name,
                src_idx,
                same_target_map,
                c3,
              )
            None -> c3
          }
          list.fold(post_bindings, #(pat_bound, c4), fn(p_acc, pb) {
            let #(b, c) = p_acc
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
        }
        IrStmtAssert(condition:, abort_message:) -> {
          let c1 =
            collect_refs_in_expr(
              condition,
              cur_bound,
              source_mod_name,
              src_idx,
              same_target_map,
              cur_col,
            )
          let c2 = case abort_message {
            Some(m) ->
              collect_refs_in_expr(
                m,
                cur_bound,
                source_mod_name,
                src_idx,
                same_target_map,
                c1,
              )
            None -> c1
          }
          #(cur_bound, c2)
        }
        IrStmtExpr(expr) -> #(
          cur_bound,
          collect_refs_in_expr(
            expr,
            cur_bound,
            source_mod_name,
            src_idx,
            same_target_map,
            cur_col,
          ),
        )
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
    IrInt(_)
    | IrFloat(_)
    | IrString(_)
    | IrBool(_)
    | IrUnit
    | IrConstructor(_, _, _) -> col
    IrTuple(els) | IrContinue(els) ->
      list.fold(els, col, fn(acc, e) {
        collect_refs_in_expr(
          e,
          bound,
          source_mod_name,
          src_idx,
          same_target_map,
          acc,
        )
      })
    IrTupleIndex(tuple:, ..) ->
      collect_refs_in_expr(
        tuple,
        bound,
        source_mod_name,
        src_idx,
        same_target_map,
        col,
      )
    IrList(elements:, tail:) -> {
      let c1 =
        list.fold(elements, col, fn(acc, e) {
          collect_refs_in_expr(
            e,
            bound,
            source_mod_name,
            src_idx,
            same_target_map,
            acc,
          )
        })
      case tail {
        Some(t) ->
          collect_refs_in_expr(
            t,
            bound,
            source_mod_name,
            src_idx,
            same_target_map,
            c1,
          )
        None -> c1
      }
    }
    IrBitString(segments:) ->
      list.fold(segments, col, fn(acc, seg) {
        let c1 =
          collect_refs_in_expr(
            seg.0,
            bound,
            source_mod_name,
            src_idx,
            same_target_map,
            acc,
          )
        list.fold(seg.1, c1, fn(inner, opt) {
          case opt {
            glance.SizeValueOption(se) ->
              collect_refs_in_expr(
                se,
                bound,
                source_mod_name,
                src_idx,
                same_target_map,
                inner,
              )
            _ -> inner
          }
        })
      })
    IrNegateInt(inner) | IrNegateBool(inner) | IrBreak(inner) ->
      collect_refs_in_expr(
        inner,
        bound,
        source_mod_name,
        src_idx,
        same_target_map,
        col,
      )
    IrGetterCall(receiver:, ..) ->
      collect_refs_in_expr(
        receiver,
        bound,
        source_mod_name,
        src_idx,
        same_target_map,
        col,
      )
    IrBinOp(left:, right:, ..) -> {
      let c1 =
        collect_refs_in_expr(
          left,
          bound,
          source_mod_name,
          src_idx,
          same_target_map,
          col,
        )
      collect_refs_in_expr(
        right,
        bound,
        source_mod_name,
        src_idx,
        same_target_map,
        c1,
      )
    }
    IrCall(function:, args:) -> {
      let c1 =
        collect_refs_in_expr(
          function,
          bound,
          source_mod_name,
          src_idx,
          same_target_map,
          col,
        )
      list.fold(args, c1, fn(acc, arg) {
        collect_refs_in_expr(
          arg.value,
          bound,
          source_mod_name,
          src_idx,
          same_target_map,
          acc,
        )
      })
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
          let nc =
            collect_refs_in_expr(
              b.1,
              bound,
              source_mod_name,
              src_idx,
              same_target_map,
              cur_c,
            )
          #(set.insert(cur_b, b.0), nc)
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
      let c1 =
        list.fold(subjects, col, fn(acc, s) {
          collect_refs_in_expr(
            s,
            bound,
            source_mod_name,
            src_idx,
            same_target_map,
            acc,
          )
        })
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
    IrEcho(expr: inner, message:, ..) -> {
      let c1 =
        collect_refs_in_expr(
          inner,
          bound,
          source_mod_name,
          src_idx,
          same_target_map,
          col,
        )
      case message {
        Some(m) ->
          collect_refs_in_expr(
            m,
            bound,
            source_mod_name,
            src_idx,
            same_target_map,
            c1,
          )
        None -> c1
      }
    }
    IrAbort(message:, ..) ->
      case message {
        Some(m) ->
          collect_refs_in_expr(
            m,
            bound,
            source_mod_name,
            src_idx,
            same_target_map,
            col,
          )
        None -> col
      }
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
    IrPatTuple(els) ->
      list.fold(els, col, fn(acc, el) {
        collect_refs_in_pattern(el, bound, src_idx, same_target_map, acc)
      })
    IrPatAs(inner, _) ->
      collect_refs_in_pattern(inner, bound, src_idx, same_target_map, col)
    IrPatVariant(args:, ..) ->
      list.fold(args, col, fn(acc, arg) {
        collect_refs_in_pattern(
          arg.pattern,
          bound,
          src_idx,
          same_target_map,
          acc,
        )
      })
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
    _ -> col
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

fn check_no_local_type_refs(
  source_fn: IrFunction,
  helper_fns: List(IrFunction),
  helper_consts: List(IrConstant),
  source_mod: IrModule,
  src_idx: ModIndex,
  target_mod_name: String,
) -> Result(Nil, String) {
  let check_fn = fn(f: IrFunction) {
    use _ <- result.try(
      list.try_each(f.params, fn(p) {
        check_local_type_in_type(
          p.param_type,
          source_mod.module_name,
          src_idx,
          target_mod_name,
        )
      }),
    )
    use _ <- result.try(check_local_type_in_type(
      f.return_type,
      source_mod.module_name,
      src_idx,
      target_mod_name,
    ))
    check_local_type_in_stmts(
      f.body,
      source_mod.module_name,
      src_idx,
      target_mod_name,
    )
  }
  use _ <- result.try(check_fn(source_fn))
  use _ <- result.try(list.try_each(helper_fns, check_fn))
  list.try_each(helper_consts, fn(c) {
    use _ <- result.try(check_local_type_in_type(
      c.value_type,
      source_mod.module_name,
      src_idx,
      target_mod_name,
    ))
    check_local_type_in_expr(
      c.value,
      source_mod.module_name,
      src_idx,
      target_mod_name,
    )
  })
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

fn check_local_type_in_type(
  ty: IrType,
  source_mod_name: String,
  src_idx: ModIndex,
  target_mod_name: String,
) -> Result(Nil, String) {
  case ty {
    IrTypeList(inner) ->
      check_local_type_in_type(inner, source_mod_name, src_idx, target_mod_name)
    IrTypeResult(o, e) -> {
      use _ <- result.try(check_local_type_in_type(
        o,
        source_mod_name,
        src_idx,
        target_mod_name,
      ))
      check_local_type_in_type(e, source_mod_name, src_idx, target_mod_name)
    }
    IrTypeTuple(els) ->
      list.try_each(els, check_local_type_in_type(
        _,
        source_mod_name,
        src_idx,
        target_mod_name,
      ))
    IrTypeFn(ps, r) -> {
      use _ <- result.try(
        list.try_each(ps, check_local_type_in_type(
          _,
          source_mod_name,
          src_idx,
          target_mod_name,
        )),
      )
      check_local_type_in_type(r, source_mod_name, src_idx, target_mod_name)
    }
    IrTypeNamed(module:, name:, args:, ..) -> {
      let is_local = module == "" || module == source_mod_name
      use _ <- result.try(
        case is_local && set.contains(src_idx.type_names, name) {
          True -> Error(cycle_error(source_mod_name, target_mod_name, name))
          False -> Ok(Nil)
        },
      )
      list.try_each(args, check_local_type_in_type(
        _,
        source_mod_name,
        src_idx,
        target_mod_name,
      ))
    }
    _ -> Ok(Nil)
  }
}

fn check_local_type_in_stmts(
  stmts: List(IrStmt),
  source_mod_name: String,
  src_idx: ModIndex,
  target_mod_name: String,
) -> Result(Nil, String) {
  list.try_each(stmts, fn(stmt) {
    case stmt {
      IrStmtLet(pattern:, annotation:, value:) -> {
        use _ <- result.try(check_local_type_in_pattern(
          pattern,
          source_mod_name,
          src_idx,
          target_mod_name,
        ))
        use _ <- result.try(case annotation {
          Some(ann) ->
            check_local_type_in_type(
              ann,
              source_mod_name,
              src_idx,
              target_mod_name,
            )
          None -> Ok(Nil)
        })
        check_local_type_in_expr(
          value,
          source_mod_name,
          src_idx,
          target_mod_name,
        )
      }
      IrStmtGuard(
        value:,
        pattern:,
        guard_condition:,
        abort_message:,
        post_bindings:,
      ) -> {
        use _ <- result.try(check_local_type_in_expr(
          value,
          source_mod_name,
          src_idx,
          target_mod_name,
        ))
        use _ <- result.try(check_local_type_in_pattern(
          pattern,
          source_mod_name,
          src_idx,
          target_mod_name,
        ))
        use _ <- result.try(case guard_condition {
          Some(g) ->
            check_local_type_in_expr(
              g,
              source_mod_name,
              src_idx,
              target_mod_name,
            )
          None -> Ok(Nil)
        })
        use _ <- result.try(case abort_message {
          Some(m) ->
            check_local_type_in_expr(
              m,
              source_mod_name,
              src_idx,
              target_mod_name,
            )
          None -> Ok(Nil)
        })
        list.try_each(post_bindings, fn(pb) {
          check_local_type_in_expr(
            pb.1,
            source_mod_name,
            src_idx,
            target_mod_name,
          )
        })
      }
      IrStmtAssert(condition:, abort_message:) -> {
        use _ <- result.try(check_local_type_in_expr(
          condition,
          source_mod_name,
          src_idx,
          target_mod_name,
        ))
        case abort_message {
          Some(m) ->
            check_local_type_in_expr(
              m,
              source_mod_name,
              src_idx,
              target_mod_name,
            )
          None -> Ok(Nil)
        }
      }
      IrStmtExpr(e) ->
        check_local_type_in_expr(e, source_mod_name, src_idx, target_mod_name)
    }
  })
}

fn check_local_type_in_expr(
  expr: IrExpr,
  source_mod_name: String,
  src_idx: ModIndex,
  target_mod_name: String,
) -> Result(Nil, String) {
  case expr {
    IrConstructor(target_module:, name:, ..) -> {
      let is_local =
        target_module == None || target_module == Some(source_mod_name)
      case is_local && set.contains(src_idx.ctor_names, name) {
        True -> Error(cycle_error(source_mod_name, target_mod_name, name))
        False -> Ok(Nil)
      }
    }
    IrTuple(els) | IrContinue(els) ->
      list.try_each(els, check_local_type_in_expr(
        _,
        source_mod_name,
        src_idx,
        target_mod_name,
      ))
    IrTupleIndex(tuple:, ..) ->
      check_local_type_in_expr(tuple, source_mod_name, src_idx, target_mod_name)
    IrList(elements:, tail:) -> {
      use _ <- result.try(
        list.try_each(elements, check_local_type_in_expr(
          _,
          source_mod_name,
          src_idx,
          target_mod_name,
        )),
      )
      case tail {
        Some(t) ->
          check_local_type_in_expr(t, source_mod_name, src_idx, target_mod_name)
        None -> Ok(Nil)
      }
    }
    IrBitString(segments:) ->
      list.try_each(segments, fn(seg) {
        use _ <- result.try(check_local_type_in_expr(
          seg.0,
          source_mod_name,
          src_idx,
          target_mod_name,
        ))
        list.try_each(seg.1, fn(opt) {
          case opt {
            glance.SizeValueOption(e) ->
              check_local_type_in_expr(
                e,
                source_mod_name,
                src_idx,
                target_mod_name,
              )
            _ -> Ok(Nil)
          }
        })
      })
    IrNegateInt(i) | IrNegateBool(i) | IrBreak(i) ->
      check_local_type_in_expr(i, source_mod_name, src_idx, target_mod_name)
    IrGetterCall(receiver:, ..) ->
      check_local_type_in_expr(
        receiver,
        source_mod_name,
        src_idx,
        target_mod_name,
      )
    IrBinOp(left:, right:, ..) -> {
      use _ <- result.try(check_local_type_in_expr(
        left,
        source_mod_name,
        src_idx,
        target_mod_name,
      ))
      check_local_type_in_expr(right, source_mod_name, src_idx, target_mod_name)
    }
    IrCall(function:, args:) -> {
      use _ <- result.try(check_local_type_in_expr(
        function,
        source_mod_name,
        src_idx,
        target_mod_name,
      ))
      list.try_each(args, fn(a) {
        check_local_type_in_expr(
          a.value,
          source_mod_name,
          src_idx,
          target_mod_name,
        )
      })
    }
    IrBlock(stmts) ->
      check_local_type_in_stmts(
        stmts,
        source_mod_name,
        src_idx,
        target_mod_name,
      )
    IrFn(params:, return_type:, body:) -> {
      use _ <- result.try(
        list.try_each(params, fn(p) {
          case p.param_type {
            Some(t) ->
              check_local_type_in_type(
                t,
                source_mod_name,
                src_idx,
                target_mod_name,
              )
            None -> Ok(Nil)
          }
        }),
      )
      use _ <- result.try(case return_type {
        Some(r) ->
          check_local_type_in_type(r, source_mod_name, src_idx, target_mod_name)
        None -> Ok(Nil)
      })
      check_local_type_in_stmts(body, source_mod_name, src_idx, target_mod_name)
    }
    IrForLoop(bindings:, body:) -> {
      use _ <- result.try(
        list.try_each(bindings, fn(b) {
          check_local_type_in_expr(
            b.1,
            source_mod_name,
            src_idx,
            target_mod_name,
          )
        }),
      )
      check_local_type_in_stmts(body, source_mod_name, src_idx, target_mod_name)
    }
    IrMatch(subjects:, clauses:) -> {
      use _ <- result.try(
        list.try_each(subjects, check_local_type_in_expr(
          _,
          source_mod_name,
          src_idx,
          target_mod_name,
        )),
      )
      list.try_each(clauses, fn(cl) {
        use _ <- result.try(
          list.try_each(cl.patterns, fn(alt) {
            list.try_each(alt, check_local_type_in_pattern(
              _,
              source_mod_name,
              src_idx,
              target_mod_name,
            ))
          }),
        )
        use _ <- result.try(case cl.guard {
          Some(g) ->
            check_local_type_in_expr(
              g,
              source_mod_name,
              src_idx,
              target_mod_name,
            )
          None -> Ok(Nil)
        })
        use _ <- result.try(
          list.try_each(cl.prefix_bindings, fn(pb) {
            check_local_type_in_expr(
              pb.1,
              source_mod_name,
              src_idx,
              target_mod_name,
            )
          }),
        )
        check_local_type_in_expr(
          cl.body,
          source_mod_name,
          src_idx,
          target_mod_name,
        )
      })
    }
    IrEcho(expr: inner, message:, ..) -> {
      use _ <- result.try(check_local_type_in_expr(
        inner,
        source_mod_name,
        src_idx,
        target_mod_name,
      ))
      case message {
        Some(m) ->
          check_local_type_in_expr(m, source_mod_name, src_idx, target_mod_name)
        None -> Ok(Nil)
      }
    }
    IrAbort(message:, ..) ->
      case message {
        Some(m) ->
          check_local_type_in_expr(m, source_mod_name, src_idx, target_mod_name)
        None -> Ok(Nil)
      }
    _ -> Ok(Nil)
  }
}

fn check_local_type_in_pattern(
  pat: IrPattern,
  source_mod_name: String,
  src_idx: ModIndex,
  target_mod_name: String,
) -> Result(Nil, String) {
  case pat {
    IrPatTuple(els) ->
      list.try_each(els, check_local_type_in_pattern(
        _,
        source_mod_name,
        src_idx,
        target_mod_name,
      ))
    IrPatAs(inner, _) ->
      check_local_type_in_pattern(
        inner,
        source_mod_name,
        src_idx,
        target_mod_name,
      )
    IrPatVariant(target_module:, constructor:, args:, ..) -> {
      let is_local =
        target_module == None || target_module == Some(source_mod_name)
      use _ <- result.try(
        case is_local && set.contains(src_idx.ctor_names, constructor) {
          True ->
            Error(cycle_error(source_mod_name, target_mod_name, constructor))
          False -> Ok(Nil)
        },
      )
      list.try_each(args, fn(arg) {
        check_local_type_in_pattern(
          arg.pattern,
          source_mod_name,
          src_idx,
          target_mod_name,
        )
      })
    }
    _ -> Ok(Nil)
  }
}

// -----------------------------------------------------------------------------
// IR rewriting from source_mod context into target_mod context
// -----------------------------------------------------------------------------

fn rename_or_keep(name: String, renames: Dict(String, String)) -> String {
  dict.get(renames, name) |> result.unwrap(name)
}

fn rewrite_ir_type(
  ty: IrType,
  source_mod: IrModule,
  target_mod_name: String,
) -> IrType {
  case ty {
    IrTypeList(inner) ->
      IrTypeList(rewrite_ir_type(inner, source_mod, target_mod_name))
    IrTypeResult(o, e) ->
      IrTypeResult(
        rewrite_ir_type(o, source_mod, target_mod_name),
        rewrite_ir_type(e, source_mod, target_mod_name),
      )
    IrTypeTuple(els) ->
      IrTypeTuple(
        list.map(els, rewrite_ir_type(_, source_mod, target_mod_name)),
      )
    IrTypeFn(ps, r) ->
      IrTypeFn(
        list.map(ps, rewrite_ir_type(_, source_mod, target_mod_name)),
        rewrite_ir_type(r, source_mod, target_mod_name),
      )
    IrTypeNamed(module_alias:, package:, module:, name:, args:) -> {
      let new_args =
        list.map(args, rewrite_ir_type(_, source_mod, target_mod_name))
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
    _ -> ty
  }
}

fn rewrite_stmts(
  stmts: List(IrStmt),
  bound: Set(String),
  source_mod: IrModule,
  src_idx: ModIndex,
  target_mod_name: String,
  renames: Dict(String, String),
) -> List(IrStmt) {
  let #(_, rev_out) =
    list.fold(stmts, #(bound, []), fn(acc, stmt) {
      let #(cur_bound, rev_acc) = acc
      case stmt {
        IrStmtLet(pattern:, annotation:, value:) -> {
          let new_val =
            rewrite_expr(
              value,
              cur_bound,
              source_mod,
              src_idx,
              target_mod_name,
              renames,
            )
          let new_pat =
            rewrite_pattern(
              pattern,
              cur_bound,
              source_mod,
              src_idx,
              target_mod_name,
              renames,
            )
          let new_ann =
            option.map(annotation, rewrite_ir_type(
              _,
              source_mod,
              target_mod_name,
            ))
          let next_bound =
            set.union(cur_bound, ir_util.pattern_bound_vars(pattern))
          #(next_bound, [
            IrStmtLet(pattern: new_pat, annotation: new_ann, value: new_val),
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
          let new_val =
            rewrite_expr(
              value,
              cur_bound,
              source_mod,
              src_idx,
              target_mod_name,
              renames,
            )
          let new_pat =
            rewrite_pattern(
              pattern,
              cur_bound,
              source_mod,
              src_idx,
              target_mod_name,
              renames,
            )
          let pat_bound =
            set.union(cur_bound, ir_util.pattern_bound_vars(pattern))
          let new_guard =
            option.map(guard_condition, rewrite_expr(
              _,
              pat_bound,
              source_mod,
              src_idx,
              target_mod_name,
              renames,
            ))
          let new_abort =
            option.map(abort_message, rewrite_expr(
              _,
              pat_bound,
              source_mod,
              src_idx,
              target_mod_name,
              renames,
            ))
          let #(after_bound, rev_posts) =
            list.fold(post_bindings, #(pat_bound, []), fn(p_acc, pb) {
              let #(b, out_p) = p_acc
              let rewritten_pb =
                rewrite_expr(
                  pb.1,
                  b,
                  source_mod,
                  src_idx,
                  target_mod_name,
                  renames,
                )
              #(set.insert(b, pb.0), [#(pb.0, rewritten_pb), ..out_p])
            })
          #(after_bound, [
            IrStmtGuard(
              value: new_val,
              pattern: new_pat,
              guard_condition: new_guard,
              abort_message: new_abort,
              post_bindings: list.reverse(rev_posts),
            ),
            ..rev_acc
          ])
        }
        IrStmtAssert(condition:, abort_message:) -> {
          let new_cond =
            rewrite_expr(
              condition,
              cur_bound,
              source_mod,
              src_idx,
              target_mod_name,
              renames,
            )
          let new_abort =
            option.map(abort_message, rewrite_expr(
              _,
              cur_bound,
              source_mod,
              src_idx,
              target_mod_name,
              renames,
            ))
          #(cur_bound, [
            IrStmtAssert(condition: new_cond, abort_message: new_abort),
            ..rev_acc
          ])
        }
        IrStmtExpr(expr) -> #(cur_bound, [
          IrStmtExpr(rewrite_expr(
            expr,
            cur_bound,
            source_mod,
            src_idx,
            target_mod_name,
            renames,
          )),
          ..rev_acc
        ])
      }
    })
  list.reverse(rev_out)
}

fn rewrite_expr(
  expr: IrExpr,
  bound: Set(String),
  source_mod: IrModule,
  src_idx: ModIndex,
  target_mod_name: String,
  renames: Dict(String, String),
) -> IrExpr {
  case expr {
    IrVar(name) ->
      case set.contains(bound, name) {
        True -> expr
        False -> IrVar(rename_or_keep(name, renames))
      }
    IrModuleRef(module_alias:, target_module:, symbol:) ->
      case target_module == target_mod_name {
        True -> IrVar(symbol)
        False ->
          case target_module == source_mod.module_name {
            True -> IrVar(rename_or_keep(symbol, renames))
            False -> IrModuleRef(module_alias:, target_module:, symbol:)
          }
      }
    IrConstructor(module_alias:, target_module:, name:) ->
      case target_module == Some(target_mod_name) {
        True -> IrConstructor(module_alias: None, target_module: None, name:)
        False ->
          case target_module == None && set.contains(src_idx.ctor_names, name) {
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
    IrInt(_) | IrFloat(_) | IrString(_) | IrBool(_) | IrUnit -> expr
    IrTuple(els) ->
      IrTuple(
        list.map(els, rewrite_expr(
          _,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        )),
      )
    IrContinue(els) ->
      IrContinue(
        list.map(els, rewrite_expr(
          _,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        )),
      )
    IrTupleIndex(tuple:, index:) ->
      IrTupleIndex(
        tuple: rewrite_expr(
          tuple,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        ),
        index:,
      )
    IrList(elements:, tail:) ->
      IrList(
        elements: list.map(elements, rewrite_expr(
          _,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        )),
        tail: option.map(tail, rewrite_expr(
          _,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        )),
      )
    IrBitString(segments:) ->
      IrBitString(
        list.map(segments, fn(seg) {
          let new_v =
            rewrite_expr(
              seg.0,
              bound,
              source_mod,
              src_idx,
              target_mod_name,
              renames,
            )
          let new_opts =
            list.map(seg.1, fn(opt) {
              case opt {
                glance.SizeValueOption(se) ->
                  glance.SizeValueOption(rewrite_expr(
                    se,
                    bound,
                    source_mod,
                    src_idx,
                    target_mod_name,
                    renames,
                  ))
                other -> coerce_bit_opt(other)
              }
            })
          #(new_v, new_opts)
        }),
      )
    IrNegateInt(inner) ->
      IrNegateInt(rewrite_expr(
        inner,
        bound,
        source_mod,
        src_idx,
        target_mod_name,
        renames,
      ))
    IrNegateBool(inner) ->
      IrNegateBool(rewrite_expr(
        inner,
        bound,
        source_mod,
        src_idx,
        target_mod_name,
        renames,
      ))
    IrBreak(inner) ->
      IrBreak(rewrite_expr(
        inner,
        bound,
        source_mod,
        src_idx,
        target_mod_name,
        renames,
      ))
    IrGetterCall(receiver:, field:) ->
      IrGetterCall(
        receiver: rewrite_expr(
          receiver,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        ),
        field:,
      )
    IrBinOp(op:, left:, right:) ->
      IrBinOp(
        op:,
        left: rewrite_expr(
          left,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        ),
        right: rewrite_expr(
          right,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        ),
      )
    IrCall(function:, args:) ->
      IrCall(
        function: rewrite_expr(
          function,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        ),
        args: list.map(args, fn(arg) {
          IrCallArg(
            label: arg.label,
            value: rewrite_expr(
              arg.value,
              bound,
              source_mod,
              src_idx,
              target_mod_name,
              renames,
            ),
          )
        }),
      )
    IrBlock(stmts) ->
      IrBlock(rewrite_stmts(
        stmts,
        bound,
        source_mod,
        src_idx,
        target_mod_name,
        renames,
      ))
    IrFn(params:, return_type:, body:) -> {
      let fn_bound =
        list.fold(params, bound, fn(acc, p) { set.insert(acc, p.name) })
      let new_params =
        list.map(params, fn(p) {
          ir.IrFnParam(
            name: p.name,
            param_type: option.map(p.param_type, rewrite_ir_type(
              _,
              source_mod,
              target_mod_name,
            )),
          )
        })
      IrFn(
        params: new_params,
        return_type: option.map(return_type, rewrite_ir_type(
          _,
          source_mod,
          target_mod_name,
        )),
        body: rewrite_stmts(
          body,
          fn_bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        ),
      )
    }
    IrForLoop(bindings:, body:) -> {
      let #(loop_bound, rev_binds) =
        list.fold(bindings, #(bound, []), fn(acc, b) {
          let #(cur_b, out) = acc
          let new_val =
            rewrite_expr(
              b.1,
              bound,
              source_mod,
              src_idx,
              target_mod_name,
              renames,
            )
          #(set.insert(cur_b, b.0), [#(b.0, new_val), ..out])
        })
      IrForLoop(
        bindings: list.reverse(rev_binds),
        body: rewrite_stmts(
          body,
          loop_bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        ),
      )
    }
    IrMatch(subjects:, clauses:) ->
      IrMatch(
        subjects: list.map(subjects, rewrite_expr(
          _,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        )),
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
              renames,
            ),
          )
        }),
      )
    IrEcho(expr: inner, message:, file_path:, line:) ->
      IrEcho(
        expr: rewrite_expr(
          inner,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        ),
        message: option.map(message, rewrite_expr(
          _,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        )),
        file_path:,
        line:,
      )
    IrAbort(kind:, message:) ->
      IrAbort(
        kind:,
        message: option.map(message, rewrite_expr(
          _,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        )),
      )
  }
}

fn coerce_bit_opt(
  opt: glance.BitStringSegmentOption(IrExpr),
) -> glance.BitStringSegmentOption(IrExpr) {
  opt
}

fn rewrite_pattern(
  pat: IrPattern,
  bound: Set(String),
  source_mod: IrModule,
  src_idx: ModIndex,
  target_mod_name: String,
  renames: Dict(String, String),
) -> IrPattern {
  case pat {
    IrPatInt(_)
    | IrPatFloat(_)
    | IrPatString(_)
    | IrPatBool(_)
    | IrPatUnit
    | IrPatDiscard
    | IrPatVar(_) -> pat
    IrPatAs(inner, alias) ->
      IrPatAs(
        rewrite_pattern(
          inner,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        ),
        alias,
      )
    IrPatTuple(els) ->
      IrPatTuple(
        list.map(els, rewrite_pattern(
          _,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          renames,
        )),
      )
    IrPatVariant(
      module_alias:,
      target_module:,
      constructor:,
      args:,
      with_spread:,
    ) -> {
      let #(next_alias, next_target) = case
        target_module == Some(target_mod_name)
      {
        True -> #(None, None)
        False ->
          case
            target_module == None
            && set.contains(src_idx.ctor_names, constructor)
          {
            True -> #(
              Some(mangle.module_to_alias(source_mod.module_name)),
              Some(source_mod.module_name),
            )
            False -> #(module_alias, target_module)
          }
      }
      IrPatVariant(
        module_alias: next_alias,
        target_module: next_target,
        constructor:,
        args: list.map(args, fn(arg) {
          IrPatArg(
            label: arg.label,
            pattern: rewrite_pattern(
              arg.pattern,
              bound,
              source_mod,
              src_idx,
              target_mod_name,
              renames,
            ),
          )
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

// -----------------------------------------------------------------------------
// Prune unreachable private spliced functions/helpers in source modules
// -----------------------------------------------------------------------------

fn prune_source_module(
  mod: IrModule,
  tracker: SplicedTracker,
  indices: Dict(String, ModIndex),
) -> IrModule {
  let mod_idx =
    dict.get(indices, mod.module_name) |> result.unwrap(build_mod_index(mod))
  let has_private_spliced =
    list.any(mod.functions, fn(f) {
      f.publicity == glance.Private
      && set.contains(tracker.spliced_fns, #(mod.module_name, f.name))
    })
  case has_private_spliced {
    False -> mod
    True -> {
      let root_fns =
        list.filter_map(mod.functions, fn(f) {
          case
            f.publicity != glance.Private
            || !set.contains(tracker.spliced_fns, #(mod.module_name, f.name))
          {
            True -> Ok(f.name)
            False -> Error(Nil)
          }
        })
      let root_consts =
        list.filter_map(mod.constants, fn(c) {
          case c.publicity != glance.Private {
            True -> Ok(c.name)
            False -> Error(Nil)
          }
        })
      let init_col =
        CollectedItems(
          fn_names: list.reverse(root_fns),
          const_names: list.reverse(root_consts),
          visited_fns: set.from_list(root_fns),
          visited_consts: set.from_list(root_consts),
        )
      let reachable =
        drain_worklist(
          root_fns,
          root_consts,
          mod.module_name,
          mod_idx,
          dict.new(),
          init_col,
        )
      let kept_fns =
        list.filter(mod.functions, fn(f) {
          set.contains(reachable.visited_fns, f.name)
        })
      let kept_consts =
        list.filter(mod.constants, fn(c) {
          set.contains(reachable.visited_consts, c.name)
        })
      IrModule(..mod, functions: kept_fns, constants: kept_consts)
    }
  }
}
