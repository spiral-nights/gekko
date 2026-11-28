import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import lower/gleam_patch_rewrite.{drain_worklist}
import lower/gleam_patch_types.{
  type MirrorMap, type ModIndex, type PatchMaps, type SplicedTracker,
  CollectedItems, build_mod_index,
}
import lower/ir.{
  type IrFunction, type IrGetter, type IrModule, type IrType, type IrTypeDef,
  IrConstructor, IrModule, IrModuleRef, IrPatVariant, IrTypeNamed, IrVar,
}
import lower/ir_util

// -----------------------------------------------------------------------------
// Prune unreachable private spliced functions/helpers in source modules
// -----------------------------------------------------------------------------

pub fn prune_source_module(
  mod: IrModule,
  tracker: SplicedTracker,
  indices: Dict(String, ModIndex),
  patch_maps: PatchMaps,
) -> IrModule {
  let mod_idx =
    dict.get(indices, mod.module_name) |> result.unwrap(build_mod_index(mod))
  let kept_types =
    list.filter(mod.types, fn(td) {
      !set.contains(tracker.spliced_type_defs, #(mod.module_name, td.name))
    })
  let kept_getters =
    list.filter(mod.getters, fn(g) {
      !set.contains(tracker.spliced_type_defs, #(mod.module_name, g.type_name))
    })
  let kept_aliases =
    list.filter(mod.type_aliases, fn(ta) {
      !set.contains(tracker.spliced_type_aliases, #(mod.module_name, ta.name))
    })
  let pruned_local_types =
    list.fold(mod.types, set.new(), fn(acc, td) {
      case
        set.contains(tracker.spliced_type_defs, #(mod.module_name, td.name))
      {
        True ->
          acc
          |> set.insert(td.name)
          |> set.insert(td.unmangled_name)
        False -> acc
      }
    })
  let pruned_local_types =
    list.fold(mod.type_aliases, pruned_local_types, fn(acc, ta) {
      case
        set.contains(tracker.spliced_type_aliases, #(mod.module_name, ta.name))
      {
        True -> set.insert(acc, ta.name)
        False -> acc
      }
    })
  let pruned_local_ctors =
    list.fold(mod.types, set.new(), fn(acc, td) {
      case
        set.contains(tracker.spliced_type_defs, #(mod.module_name, td.name))
      {
        False -> acc
        True ->
          list.fold(td.variants, acc, fn(inner, v) { set.insert(inner, v.name) })
      }
    })

  let should_prune_spliced_fn = fn(f: IrFunction) {
    set.contains(tracker.spliced_fns, #(mod.module_name, f.name))
    && {
      f.publicity == glance.Private
      || fn_uses_mirror_or_pruned(
        f,
        mod.module_name,
        patch_maps.mirrors_by_mod,
        pruned_local_types,
        pruned_local_ctors,
      )
    }
  }
  let has_pruned_fns = list.any(mod.functions, should_prune_spliced_fn)
  let mod_after_types =
    IrModule(
      ..mod,
      types: kept_types,
      type_aliases: kept_aliases,
      getters: kept_getters,
    )
  case has_pruned_fns {
    False -> mod_after_types
    True -> {
      let root_fns =
        list.filter_map(mod_after_types.functions, fn(f) {
          case should_prune_spliced_fn(f) {
            False -> Ok(f.name)
            True -> Error(Nil)
          }
        })
      let root_consts =
        list.filter_map(mod_after_types.constants, fn(c) {
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
          mod_after_types.module_name,
          mod_idx,
          dict.new(),
          init_col,
        )
      let kept_fns =
        list.filter(mod_after_types.functions, fn(f) {
          set.contains(reachable.visited_fns, f.name)
        })
      let kept_consts =
        list.filter(mod_after_types.constants, fn(c) {
          set.contains(reachable.visited_consts, c.name)
        })
      IrModule(..mod_after_types, functions: kept_fns, constants: kept_consts)
    }
  }
}

fn fn_uses_mirror_or_pruned(
  f: IrFunction,
  cur_mod: String,
  mirrors: Dict(String, MirrorMap),
  pruned_types: Set(String),
  pruned_ctors: Set(String),
) -> Bool {
  let type_uses = fn(ty: IrType) {
    ir_util.try_fold_type(ty, Nil, fn(_, t) {
      case t {
        IrTypeNamed(module:, name:, ..) -> {
          let resolved = case module {
            "" -> cur_mod
            m -> m
          }
          case
            dict.has_key(mirrors, resolved)
            || { resolved == cur_mod && set.contains(pruned_types, name) }
          {
            True -> Error(Nil)
            False -> Ok(Nil)
          }
        }
        _ -> Ok(Nil)
      }
    })
  }
  let visitor =
    ir_util.IrVisitor(
      ..ir_util.default_visitor(),
      on_type: fn(_, t) { type_uses(t) },
      on_expr: fn(_, e) {
        case e {
          IrModuleRef(target_module:, ..) ->
            case dict.has_key(mirrors, target_module) {
              True -> Error(Nil)
              False -> Ok(Nil)
            }
          IrConstructor(target_module:, name:, ..) ->
            case target_module {
              Some(m) ->
                case
                  dict.has_key(mirrors, m)
                  || { m == cur_mod && set.contains(pruned_ctors, name) }
                {
                  True -> Error(Nil)
                  False -> Ok(Nil)
                }
              None ->
                case set.contains(pruned_ctors, name) {
                  True -> Error(Nil)
                  False -> Ok(Nil)
                }
            }
          _ -> Ok(Nil)
        }
      },
      on_pattern: fn(_, p) {
        case p {
          IrPatVariant(target_module:, constructor:, ..) ->
            case target_module {
              Some(m) ->
                case
                  dict.has_key(mirrors, m)
                  || { m == cur_mod && set.contains(pruned_ctors, constructor) }
                {
                  True -> Error(Nil)
                  False -> Ok(Nil)
                }
              None ->
                case set.contains(pruned_ctors, constructor) {
                  True -> Error(Nil)
                  False -> Ok(Nil)
                }
            }
          _ -> Ok(Nil)
        }
      },
    )

  let res = {
    use _ <- result.try(
      list.try_each(f.params, fn(p) { type_uses(p.param_type) }),
    )
    use _ <- result.try(type_uses(f.return_type))
    ir_util.try_fold_stmts(f.body, Nil, visitor)
  }
  result.is_error(res)
}

// -----------------------------------------------------------------------------
// Prune unreachable private types in patched target modules
// -----------------------------------------------------------------------------

pub fn prune_unused_private_types(mod: IrModule) -> IrModule {
  let private_types =
    list.filter(mod.types, fn(td) { td.publicity == glance.Private })
  case private_types {
    [] -> mod
    _ -> {
      let private_by_name =
        list.fold(private_types, dict.new(), fn(acc, td) {
          dict.insert(acc, td.name, td)
        })
      let ctor_to_type =
        list.fold(private_types, dict.new(), fn(acc, td) {
          list.fold(td.variants, acc, fn(inner_acc, variant) {
            dict.insert(inner_acc, variant.name, td.name)
          })
        })
      let visitor = type_ref_visitor(mod.module_name, ctor_to_type)

      let root_refs = set.new()
      let root_refs =
        list.fold(mod.types, root_refs, fn(acc, td) {
          case td.publicity == glance.Private {
            True -> acc
            False -> collect_type_def_refs(td, mod.module_name, acc)
          }
        })
      let root_refs =
        list.fold(mod.type_aliases, root_refs, fn(acc, ta) {
          collect_type_refs(ta.aliased, mod.module_name, acc)
        })
      let root_refs =
        list.fold(mod.getters, root_refs, fn(acc, g: IrGetter) {
          case dict.has_key(private_by_name, g.type_name) {
            True -> acc
            False -> collect_type_refs(g.return_type, mod.module_name, acc)
          }
        })
      let root_refs =
        list.fold(mod.constants, root_refs, fn(acc, c) {
          let acc = collect_type_refs(c.value_type, mod.module_name, acc)
          ir_util.fold_expr(c.value, acc, visitor)
        })
      let root_refs =
        list.fold(mod.functions, root_refs, fn(acc, f) {
          let acc =
            list.fold(f.params, acc, fn(p_acc, p) {
              collect_type_refs(p.param_type, mod.module_name, p_acc)
            })
          let acc = collect_type_refs(f.return_type, mod.module_name, acc)
          ir_util.fold_stmts(f.body, acc, visitor)
        })

      let initial_private =
        list.filter(set.to_list(root_refs), dict.has_key(private_by_name, _))
      let reachable_private =
        drain_private_type_worklist(
          initial_private,
          set.from_list(initial_private),
          mod.module_name,
          private_by_name,
          mod.getters,
        )

      let kept_types =
        list.filter(mod.types, fn(td) {
          td.publicity != glance.Private
          || set.contains(reachable_private, td.name)
        })
      let kept_getters =
        list.filter(mod.getters, fn(g: IrGetter) {
          !dict.has_key(private_by_name, g.type_name)
          || set.contains(reachable_private, g.type_name)
        })
      IrModule(..mod, types: kept_types, getters: kept_getters)
    }
  }
}

fn drain_private_type_worklist(
  queue: List(String),
  visited: Set(String),
  mod_name: String,
  private_by_name: Dict(String, IrTypeDef),
  getters: List(IrGetter),
) -> Set(String) {
  case queue {
    [] -> visited
    [name, ..rest] -> {
      let refs = case dict.get(private_by_name, name) {
        Ok(td) -> collect_type_def_refs(td, mod_name, set.new())
        Error(_) -> set.new()
      }
      let refs =
        list.fold(getters, refs, fn(acc, g: IrGetter) {
          case g.type_name == name {
            True -> collect_type_refs(g.return_type, mod_name, acc)
            False -> acc
          }
        })
      let #(next_queue, next_visited) =
        set.fold(refs, #(rest, visited), fn(acc, ref_name) {
          let #(q, vis) = acc
          case
            dict.has_key(private_by_name, ref_name)
            && !set.contains(vis, ref_name)
          {
            True -> #([ref_name, ..q], set.insert(vis, ref_name))
            False -> acc
          }
        })
      drain_private_type_worklist(
        next_queue,
        next_visited,
        mod_name,
        private_by_name,
        getters,
      )
    }
  }
}

fn collect_type_def_refs(
  td: IrTypeDef,
  mod_name: String,
  acc: Set(String),
) -> Set(String) {
  list.fold(td.variants, acc, fn(v_acc, v) {
    list.fold(v.fields, v_acc, fn(f_acc, f) {
      collect_type_refs(f.field_type, mod_name, f_acc)
    })
  })
}

fn collect_type_refs(
  ty: IrType,
  mod_name: String,
  acc: Set(String),
) -> Set(String) {
  ir_util.fold_type(ty, acc, fn(t_acc, t) {
    case t {
      IrTypeNamed(module:, name:, ..) if module == "" || module == mod_name ->
        set.insert(t_acc, name)
      _ -> t_acc
    }
  })
}

fn type_ref_visitor(
  mod_name: String,
  ctor_to_type: Dict(String, String),
) -> ir_util.IrVisitor(Set(String), Nil) {
  ir_util.IrVisitor(
    ..ir_util.default_visitor(),
    on_type: fn(acc, t) {
      case t {
        IrTypeNamed(module:, name:, ..) if module == "" || module == mod_name ->
          Ok(set.insert(acc, name))
        _ -> Ok(acc)
      }
    },
    on_expr: fn(acc, e) {
      case e {
        IrVar(name) -> Ok(record_ctor_type_ref(name, ctor_to_type, acc))
        IrModuleRef(target_module:, symbol:, ..) if target_module == mod_name ->
          Ok(record_ctor_type_ref(symbol, ctor_to_type, acc))
        IrConstructor(target_module:, name:, ..)
          if target_module == None || target_module == Some(mod_name)
        -> Ok(record_ctor_type_ref(name, ctor_to_type, acc))
        _ -> Ok(acc)
      }
    },
    on_pattern: fn(acc, p) {
      case p {
        IrPatVariant(target_module:, constructor:, ..)
          if target_module == None || target_module == Some(mod_name)
        -> Ok(record_ctor_type_ref(constructor, ctor_to_type, acc))
        _ -> Ok(acc)
      }
    },
  )
}

fn record_ctor_type_ref(
  name: String,
  ctor_to_type: Dict(String, String),
  acc: Set(String),
) -> Set(String) {
  case dict.get(ctor_to_type, name) {
    Ok(type_name) -> set.insert(acc, type_name)
    Error(_) -> acc
  }
}
