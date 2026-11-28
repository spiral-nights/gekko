import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import index/symbol_table.{type SymbolTable}
import lower/gleam_patch_mirror.{
  validate_and_build_mirrors, validate_no_stray_mirror_refs,
}
import lower/gleam_patch_prune.{prune_source_module, prune_unused_private_types}
import lower/gleam_patch_rewrite.{
  check_no_local_type_refs, collect_refs_in_stmts, drain_worklist, rewrite_expr,
  rewrite_ir_type, rewrite_stmts,
}
import lower/gleam_patch_type_splice.{splice_all_type_patches}
import lower/gleam_patch_types.{
  type ModIndex, type PatchMaps, type SplicedTracker, CollectedItems, PatchMaps,
  SplicedTracker, build_alias_map, build_mod_index, validate_patch_signature,
}
import lower/ir.{
  type IrConstant, type IrFunction, type IrModule, type IrTypeAlias, IrConstant,
  IrFunction, IrModule, IrParam,
}
import lower/mangle
import project/prepass.{type GleamTypePatch, type PatchMirrorInfo, GleamPatch}

/// Splice Gleam-written `@patch("mod.fn")` functions (and their transitive
/// private/module helpers and constants) directly into target `IrModule`s so
/// shims can import target module types without creating MoonBit import cycles.
pub fn splice_gleam_patches(
  ir_modules: List(IrModule),
  table: SymbolTable,
) -> Result(List(IrModule), String) {
  use #(modules, _) <- result.try(splice_gleam_patches_with_overlays(
    ir_modules,
    table,
    dict.new(),
    dict.new(),
    dict.new(),
  ))
  Ok(modules)
}

/// Splice Gleam-written `@patch_type("mod.Type")` and `@patch("mod.fn")`
/// declarations, validate and erase `@patch_mirror` modules, and return the
/// updated IR modules and synchronized `SymbolTable`.
pub fn splice_gleam_patches_with_overlays(
  ir_modules: List(IrModule),
  table: SymbolTable,
  gleam_type_patches: Dict(String, GleamTypePatch),
  patch_mirrors: Dict(String, PatchMirrorInfo),
  module_pkg_by_name: Dict(String, String),
) -> Result(#(List(IrModule), SymbolTable), String) {
  let mods_by_name =
    list.fold(ir_modules, dict.new(), fn(acc, m) {
      dict.insert(acc, m.module_name, m)
    })
  let all_aliases = build_alias_map(ir_modules)

  // Phase 1: Validate all @patch_mirror modules against upstream IR & build MirrorMaps
  use mirrors_by_mod <- result.try(validate_and_build_mirrors(
    patch_mirrors,
    mods_by_name,
    all_aliases,
    module_pkg_by_name,
  ))

  // Phase 2: Collect & splice @patch_type definitions into target modules
  use
    #(
      after_types_mods,
      next_table,
      type_patch_map,
      type_patch_ctor_map,
      tracker0,
    )
  <- result.try(splice_all_type_patches(
    ir_modules,
    table,
    gleam_type_patches,
    mirrors_by_mod,
    mods_by_name,
    module_pkg_by_name,
  ))

  // Rebuild maps after @patch_type splicing so @patch fns see patched types/aliases
  let mods_by_name =
    list.fold(after_types_mods, dict.new(), fn(acc, m) {
      dict.insert(acc, m.module_name, m)
    })
  let indices = dict.map_values(mods_by_name, fn(_k, m) { build_mod_index(m) })
  let all_aliases = build_alias_map(after_types_mods)
  let patch_maps =
    PatchMaps(
      mirrors_by_mod:,
      type_patch_map:,
      type_patch_ctor_map:,
      mods_by_name:,
    )
  let all_patches_by_source = collect_all_patches_by_source(after_types_mods)

  // Phase 3: Splice @patch functions with mirror & @patch_type rewriting
  use #(rev_updated, tracker) <- result.try(
    list.try_fold(after_types_mods, #([], tracker0), fn(acc, mod) {
      let #(mods_acc, cur_tracker) = acc
      use #(next_mod, next_tracker) <- result.try(splice_target_module(
        mod,
        mods_by_name,
        indices,
        all_aliases,
        all_patches_by_source,
        patch_maps,
        cur_tracker,
      ))
      Ok(#([next_mod, ..mods_acc], next_tracker))
    }),
  )
  let spliced_modules = list.reverse(rev_updated)

  // Phase 4: Prune source modules, drop @patch_mirror modules, reject stray mirror refs
  let without_mirrors =
    list.filter(spliced_modules, fn(m) {
      !dict.has_key(mirrors_by_mod, m.module_name)
    })
  let pruned =
    list.map(without_mirrors, prune_source_module(
      _,
      tracker,
      indices,
      patch_maps,
    ))
  use _ <- result.try(validate_no_stray_mirror_refs(pruned, mirrors_by_mod))
  Ok(#(pruned, next_table))
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
  patch_maps: PatchMaps,
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
                  patch_maps,
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
                    patch_maps,
                    used_names,
                  ),
                )

                let next_tracker =
                  SplicedTracker(
                    ..cur_tracker,
                    spliced_fns: set.insert(cur_tracker.spliced_fns, #(
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
      let updated_mod =
        IrModule(
          ..target_mod,
          constants: deduped_consts,
          functions: deduped_fns,
        )
        |> prune_unused_private_types
      Ok(#(updated_mod, next_tracker))
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

fn splice_single_patch(
  source_mod: IrModule,
  src_idx: ModIndex,
  source_fn: IrFunction,
  target_mod: IrModule,
  target_fn: IrFunction,
  same_target_map: Dict(String, String),
  patch_maps: PatchMaps,
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
            patch_maps,
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
              patch_maps,
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
            patch_maps,
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
            patch_maps,
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
              patch_maps,
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
          patch_maps,
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
            patch_maps,
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
                  patch_maps,
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
              patch_maps,
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
              patch_maps,
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
              patch_maps,
            ),
            value: rewrite_expr(
              hc.value,
              set.new(),
              source_mod,
              src_idx,
              target_mod.module_name,
              patch_maps,
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
