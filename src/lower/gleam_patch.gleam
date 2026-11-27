import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import index/symbol_table.{type SymbolTable, ConstructorInfo}
import lower/ir.{
  type IrBitSize, type IrCallArg, type IrConstant, type IrExpr, type IrFunction,
  type IrGetter, type IrModule, type IrPattern, type IrStmt, type IrType,
  type IrTypeAlias, type IrTypeDef, IrAbort, IrBinOp, IrBitSizeBinOp,
  IrBitSizeInt, IrBitSizeVar, IrBitString, IrBlock, IrBool, IrBreak, IrCall,
  IrCallArg, IrClause, IrConstant, IrConstructor, IrContinue, IrEcho, IrFloat,
  IrFn, IrFnParam, IrForLoop, IrFunction, IrGetter, IrGetterCall, IrInt, IrList,
  IrMatch, IrModule, IrModuleRef, IrNegateBool, IrNegateInt, IrParam, IrPatArg,
  IrPatAs, IrPatBitString, IrPatBool, IrPatDiscard, IrPatFloat, IrPatInt,
  IrPatString, IrPatTuple, IrPatUnit, IrPatVar, IrPatVariant, IrStmtAssert,
  IrStmtExpr, IrStmtGuard, IrStmtLet, IrString, IrTuple, IrTupleIndex,
  IrTypeAlias, IrTypeBitArray, IrTypeBool, IrTypeDef, IrTypeDouble, IrTypeFn,
  IrTypeInt64, IrTypeList, IrTypeNamed, IrTypeResult, IrTypeString, IrTypeTuple,
  IrTypeUnit, IrTypeVar, IrUnit, IrVar, IrVariant, IrVariantField,
}
import lower/ir_util
import lower/mangle
import project/prepass.{
  type GleamTypePatch, type MirrorDeclEntry, type PatchMirrorInfo, GleamPatch,
  MirrorConst, MirrorFn, MirrorFromPublic, MirrorOpaque, MirrorToPublic,
  MirrorType,
}

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
    /// `(source_module, ir_type_name)` entries that were spliced as `@patch_type`.
    spliced_type_defs: Set(#(String, String)),
    /// `(source_module, ir_alias_name)` entries that were spliced as `@patch_type`.
    spliced_type_aliases: Set(#(String, String)),
  )
}

type TypeBijection {
  TypeBijection(s_to_t: Dict(String, String), t_to_s: Dict(String, String))
}

type MirrorMap {
  MirrorMap(
    mirror_mod_name: String,
    target_mod_name: String,
    target_pkg_name: String,
    type_map: Dict(String, String),
    ctor_map: Dict(String, String),
    to_public_fns: Set(String),
    from_public_fns: Set(String),
    fn_map: Dict(String, String),
    const_map: Dict(String, String),
    const_fn_map: Dict(String, String),
  )
}

type PatchMaps {
  PatchMaps(
    mirrors_by_mod: Dict(String, MirrorMap),
    /// `(source_mod, source_ir_or_unmangled_type) -> #(target_mod, target_ir_type, target_pkg)`
    type_patch_map: Dict(#(String, String), #(String, String, String)),
    /// `(source_mod, source_ctor) -> #(target_mod, target_ctor)`
    type_patch_ctor_map: Dict(#(String, String), #(String, String)),
    /// Modules indexed by name for `@patch_type` external-type inspection
    mods_by_name: Dict(String, IrModule),
  )
}

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

// -----------------------------------------------------------------------------
// Signature checking (parameter count, types, return type, type var bijection)
// -----------------------------------------------------------------------------

fn validate_patch_signature(
  source_mod: IrModule,
  source_fn: IrFunction,
  target_mod: IrModule,
  target_fn: IrFunction,
  all_aliases: Dict(#(String, String), IrTypeAlias),
  patch_maps: PatchMaps,
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
            normalize_type_for_patch(
              sp.param_type,
              source_mod.module_name,
              target_mod.module_name,
              all_aliases,
              patch_maps,
            )
          let nt =
            normalize_type_for_patch(
              tp.param_type,
              target_mod.module_name,
              target_mod.module_name,
              all_aliases,
              patch_maps,
            )
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
        normalize_type_for_patch(
          source_fn.return_type,
          source_mod.module_name,
          target_mod.module_name,
          all_aliases,
          patch_maps,
        )
      let nt_ret =
        normalize_type_for_patch(
          target_fn.return_type,
          target_mod.module_name,
          target_mod.module_name,
          all_aliases,
          patch_maps,
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

fn normalize_type_for_patch(
  ty: IrType,
  cur_mod: String,
  target_mod_name: String,
  all_aliases: Dict(#(String, String), IrTypeAlias),
  patch_maps: PatchMaps,
) -> IrType {
  let remapped =
    remap_type_for_patch_compare(ty, cur_mod, target_mod_name, patch_maps)
  let expanded = normalize_type(remapped, cur_mod, all_aliases)
  canonicalize_external_types(expanded, patch_maps.mods_by_name)
}

fn canonicalize_external_types(
  ty: IrType,
  mods_by_name: Dict(String, IrModule),
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
      IrTypeList(canonicalize_external_types(inner, mods_by_name))
    IrTypeResult(ok_t, err_t) ->
      IrTypeResult(
        canonicalize_external_types(ok_t, mods_by_name),
        canonicalize_external_types(err_t, mods_by_name),
      )
    IrTypeTuple(els) ->
      IrTypeTuple(list.map(els, canonicalize_external_types(_, mods_by_name)))
    IrTypeFn(ps, r) ->
      IrTypeFn(
        list.map(ps, canonicalize_external_types(_, mods_by_name)),
        canonicalize_external_types(r, mods_by_name),
      )
    IrTypeNamed(module_alias:, package:, module:, name:, args:) -> {
      let norm_args =
        list.map(args, canonicalize_external_types(_, mods_by_name))
      case dict.get(mods_by_name, module) {
        Error(_) ->
          IrTypeNamed(module_alias:, package:, module:, name:, args: norm_args)
        Ok(m) ->
          case find_ir_type(m, name) {
            Some(td) ->
              case td.external_type {
                Some(prepass.ExternalType(package: ext_pkg, type_name: ext_ty)) -> {
                  let norm_pkg = case ext_pkg {
                    "" | "builtin" -> "moonbitlang/core/builtin"
                    other -> other
                  }
                  case norm_pkg, ext_ty, norm_args {
                    "moonbitlang/core/builtin", "String", [] -> IrTypeString
                    "moonbitlang/core/builtin", "Int64", [] -> IrTypeInt64
                    "moonbitlang/core/builtin", "Double", [] -> IrTypeDouble
                    "moonbitlang/core/builtin", "Bool", [] -> IrTypeBool
                    "moonbitlang/core/builtin", "Unit", [] -> IrTypeUnit
                    _, _, _ ->
                      IrTypeNamed(
                        module_alias: None,
                        package: "",
                        module: "__external__:" <> norm_pkg,
                        name: ext_ty,
                        args: norm_args,
                      )
                  }
                }
                None ->
                  IrTypeNamed(
                    module_alias:,
                    package:,
                    module:,
                    name:,
                    args: norm_args,
                  )
              }
            None ->
              IrTypeNamed(
                module_alias:,
                package:,
                module:,
                name:,
                args: norm_args,
              )
          }
      }
    }
  }
}

fn remap_type_for_patch_compare(
  ty: IrType,
  cur_mod: String,
  target_mod_name: String,
  patch_maps: PatchMaps,
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
      IrTypeList(remap_type_for_patch_compare(
        inner,
        cur_mod,
        target_mod_name,
        patch_maps,
      ))
    IrTypeResult(ok_t, err_t) ->
      IrTypeResult(
        remap_type_for_patch_compare(ok_t, cur_mod, target_mod_name, patch_maps),
        remap_type_for_patch_compare(
          err_t,
          cur_mod,
          target_mod_name,
          patch_maps,
        ),
      )
    IrTypeTuple(els) ->
      IrTypeTuple(
        list.map(els, remap_type_for_patch_compare(
          _,
          cur_mod,
          target_mod_name,
          patch_maps,
        )),
      )
    IrTypeFn(ps, r) ->
      IrTypeFn(
        list.map(ps, remap_type_for_patch_compare(
          _,
          cur_mod,
          target_mod_name,
          patch_maps,
        )),
        remap_type_for_patch_compare(r, cur_mod, target_mod_name, patch_maps),
      )
    IrTypeNamed(module_alias:, package:, module:, name:, args:) -> {
      let resolved_mod = case module {
        "" -> cur_mod
        m -> m
      }
      let new_args =
        list.map(args, remap_type_for_patch_compare(
          _,
          cur_mod,
          target_mod_name,
          patch_maps,
        ))
      case dict.get(patch_maps.mirrors_by_mod, resolved_mod) {
        Ok(mm) if mm.target_mod_name == target_mod_name ->
          case dict.get(mm.type_map, name) {
            Ok(target_name) ->
              IrTypeNamed(
                module_alias: None,
                package: mm.target_pkg_name,
                module: mm.target_mod_name,
                name: target_name,
                args: new_args,
              )
            Error(_) ->
              IrTypeNamed(
                module_alias:,
                package:,
                module: resolved_mod,
                name:,
                args: new_args,
              )
          }
        _ ->
          case dict.get(patch_maps.type_patch_map, #(resolved_mod, name)) {
            Ok(#(tgt_mod, tgt_name, tgt_pkg)) ->
              IrTypeNamed(
                module_alias: None,
                package: tgt_pkg,
                module: tgt_mod,
                name: tgt_name,
                args: new_args,
              )
            Error(_) ->
              IrTypeNamed(
                module_alias:,
                package:,
                module: resolved_mod,
                name:,
                args: new_args,
              )
          }
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
      let clean_mod = case string.split_once(module, "__external__:") {
        Ok(#("", rest)) -> rest
        _ -> module
      }
      let base = case clean_mod {
        "" -> name
        _ -> clean_mod <> "." <> name
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
  patch_maps: PatchMaps,
) -> Result(Nil, String) {
  let check_fn = fn(f: IrFunction) {
    use _ <- result.try(
      list.try_each(f.params, fn(p) {
        check_local_type_in_type(
          p.param_type,
          source_mod.module_name,
          src_idx,
          target_mod_name,
          patch_maps,
        )
      }),
    )
    use _ <- result.try(check_local_type_in_type(
      f.return_type,
      source_mod.module_name,
      src_idx,
      target_mod_name,
      patch_maps,
    ))
    check_local_type_in_stmts(
      f.body,
      source_mod.module_name,
      src_idx,
      target_mod_name,
      patch_maps,
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
      patch_maps,
    ))
    check_local_type_in_expr(
      c.value,
      source_mod.module_name,
      src_idx,
      target_mod_name,
      patch_maps,
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

fn is_patched_local_type_for_target(
  source_mod_name: String,
  type_name: String,
  target_mod_name: String,
  patch_maps: PatchMaps,
) -> Bool {
  case dict.get(patch_maps.type_patch_map, #(source_mod_name, type_name)) {
    Ok(#(tgt_mod, _, _)) -> tgt_mod == target_mod_name
    Error(_) -> False
  }
}

fn is_patched_local_ctor_for_target(
  source_mod_name: String,
  ctor_name: String,
  target_mod_name: String,
  patch_maps: PatchMaps,
) -> Bool {
  case dict.get(patch_maps.type_patch_ctor_map, #(source_mod_name, ctor_name)) {
    Ok(#(tgt_mod, _)) -> tgt_mod == target_mod_name
    Error(_) -> False
  }
}

fn check_local_type_in_type(
  ty: IrType,
  source_mod_name: String,
  src_idx: ModIndex,
  target_mod_name: String,
  patch_maps: PatchMaps,
) -> Result(Nil, String) {
  case ty {
    IrTypeList(inner) ->
      check_local_type_in_type(
        inner,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      )
    IrTypeResult(o, e) -> {
      use _ <- result.try(check_local_type_in_type(
        o,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      ))
      check_local_type_in_type(
        e,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      )
    }
    IrTypeTuple(els) ->
      list.try_each(els, check_local_type_in_type(
        _,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      ))
    IrTypeFn(ps, r) -> {
      use _ <- result.try(
        list.try_each(ps, check_local_type_in_type(
          _,
          source_mod_name,
          src_idx,
          target_mod_name,
          patch_maps,
        )),
      )
      check_local_type_in_type(
        r,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      )
    }
    IrTypeNamed(module:, name:, args:, ..) -> {
      let is_local = module == "" || module == source_mod_name
      let patched_for_target =
        is_patched_local_type_for_target(
          source_mod_name,
          name,
          target_mod_name,
          patch_maps,
        )
      use _ <- result.try(
        case
          is_local
          && set.contains(src_idx.type_names, name)
          && !patched_for_target
        {
          True -> Error(cycle_error(source_mod_name, target_mod_name, name))
          False -> Ok(Nil)
        },
      )
      list.try_each(args, check_local_type_in_type(
        _,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
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
  patch_maps: PatchMaps,
) -> Result(Nil, String) {
  list.try_each(stmts, fn(stmt) {
    case stmt {
      IrStmtLet(pattern:, annotation:, value:) -> {
        use _ <- result.try(check_local_type_in_pattern(
          pattern,
          source_mod_name,
          src_idx,
          target_mod_name,
          patch_maps,
        ))
        use _ <- result.try(case annotation {
          Some(ann) ->
            check_local_type_in_type(
              ann,
              source_mod_name,
              src_idx,
              target_mod_name,
              patch_maps,
            )
          None -> Ok(Nil)
        })
        check_local_type_in_expr(
          value,
          source_mod_name,
          src_idx,
          target_mod_name,
          patch_maps,
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
          patch_maps,
        ))
        use _ <- result.try(check_local_type_in_pattern(
          pattern,
          source_mod_name,
          src_idx,
          target_mod_name,
          patch_maps,
        ))
        use _ <- result.try(case guard_condition {
          Some(g) ->
            check_local_type_in_expr(
              g,
              source_mod_name,
              src_idx,
              target_mod_name,
              patch_maps,
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
              patch_maps,
            )
          None -> Ok(Nil)
        })
        list.try_each(post_bindings, fn(pb) {
          check_local_type_in_expr(
            pb.1,
            source_mod_name,
            src_idx,
            target_mod_name,
            patch_maps,
          )
        })
      }
      IrStmtAssert(condition:, abort_message:) -> {
        use _ <- result.try(check_local_type_in_expr(
          condition,
          source_mod_name,
          src_idx,
          target_mod_name,
          patch_maps,
        ))
        case abort_message {
          Some(m) ->
            check_local_type_in_expr(
              m,
              source_mod_name,
              src_idx,
              target_mod_name,
              patch_maps,
            )
          None -> Ok(Nil)
        }
      }
      IrStmtExpr(e) ->
        check_local_type_in_expr(
          e,
          source_mod_name,
          src_idx,
          target_mod_name,
          patch_maps,
        )
    }
  })
}

fn check_local_type_in_expr(
  expr: IrExpr,
  source_mod_name: String,
  src_idx: ModIndex,
  target_mod_name: String,
  patch_maps: PatchMaps,
) -> Result(Nil, String) {
  case expr {
    IrConstructor(target_module:, name:, ..) -> {
      let is_local =
        target_module == None || target_module == Some(source_mod_name)
      let patched_for_target =
        is_patched_local_ctor_for_target(
          source_mod_name,
          name,
          target_mod_name,
          patch_maps,
        )
      case
        is_local
        && set.contains(src_idx.ctor_names, name)
        && !patched_for_target
      {
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
        patch_maps,
      ))
    IrTupleIndex(tuple:, ..) ->
      check_local_type_in_expr(
        tuple,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      )
    IrList(elements:, tail:) -> {
      use _ <- result.try(
        list.try_each(elements, check_local_type_in_expr(
          _,
          source_mod_name,
          src_idx,
          target_mod_name,
          patch_maps,
        )),
      )
      case tail {
        Some(t) ->
          check_local_type_in_expr(
            t,
            source_mod_name,
            src_idx,
            target_mod_name,
            patch_maps,
          )
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
          patch_maps,
        ))
        list.try_each(seg.1, fn(opt) {
          case opt {
            glance.SizeValueOption(e) ->
              check_local_type_in_expr(
                e,
                source_mod_name,
                src_idx,
                target_mod_name,
                patch_maps,
              )
            _ -> Ok(Nil)
          }
        })
      })
    IrNegateInt(i) | IrNegateBool(i) | IrBreak(i) ->
      check_local_type_in_expr(
        i,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      )
    IrGetterCall(receiver:, ..) ->
      check_local_type_in_expr(
        receiver,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      )
    IrBinOp(left:, right:, ..) -> {
      use _ <- result.try(check_local_type_in_expr(
        left,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      ))
      check_local_type_in_expr(
        right,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      )
    }
    IrCall(function:, args:) -> {
      use _ <- result.try(check_local_type_in_expr(
        function,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      ))
      list.try_each(args, fn(a) {
        check_local_type_in_expr(
          a.value,
          source_mod_name,
          src_idx,
          target_mod_name,
          patch_maps,
        )
      })
    }
    IrBlock(stmts) ->
      check_local_type_in_stmts(
        stmts,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
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
                patch_maps,
              )
            None -> Ok(Nil)
          }
        }),
      )
      use _ <- result.try(case return_type {
        Some(r) ->
          check_local_type_in_type(
            r,
            source_mod_name,
            src_idx,
            target_mod_name,
            patch_maps,
          )
        None -> Ok(Nil)
      })
      check_local_type_in_stmts(
        body,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      )
    }
    IrForLoop(bindings:, body:) -> {
      use _ <- result.try(
        list.try_each(bindings, fn(b) {
          check_local_type_in_expr(
            b.1,
            source_mod_name,
            src_idx,
            target_mod_name,
            patch_maps,
          )
        }),
      )
      check_local_type_in_stmts(
        body,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      )
    }
    IrMatch(subjects:, clauses:) -> {
      use _ <- result.try(
        list.try_each(subjects, check_local_type_in_expr(
          _,
          source_mod_name,
          src_idx,
          target_mod_name,
          patch_maps,
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
              patch_maps,
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
              patch_maps,
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
              patch_maps,
            )
          }),
        )
        check_local_type_in_expr(
          cl.body,
          source_mod_name,
          src_idx,
          target_mod_name,
          patch_maps,
        )
      })
    }
    IrEcho(expr: inner, message:, ..) -> {
      use _ <- result.try(check_local_type_in_expr(
        inner,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      ))
      case message {
        Some(m) ->
          check_local_type_in_expr(
            m,
            source_mod_name,
            src_idx,
            target_mod_name,
            patch_maps,
          )
        None -> Ok(Nil)
      }
    }
    IrAbort(message:, ..) ->
      case message {
        Some(m) ->
          check_local_type_in_expr(
            m,
            source_mod_name,
            src_idx,
            target_mod_name,
            patch_maps,
          )
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
  patch_maps: PatchMaps,
) -> Result(Nil, String) {
  case pat {
    IrPatTuple(els) ->
      list.try_each(els, check_local_type_in_pattern(
        _,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      ))
    IrPatAs(inner, _) ->
      check_local_type_in_pattern(
        inner,
        source_mod_name,
        src_idx,
        target_mod_name,
        patch_maps,
      )
    IrPatVariant(target_module:, constructor:, args:, ..) -> {
      let is_local =
        target_module == None || target_module == Some(source_mod_name)
      let patched_for_target =
        is_patched_local_ctor_for_target(
          source_mod_name,
          constructor,
          target_mod_name,
          patch_maps,
        )
      use _ <- result.try(
        case
          is_local
          && set.contains(src_idx.ctor_names, constructor)
          && !patched_for_target
        {
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
          patch_maps,
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
  patch_maps: PatchMaps,
) -> IrType {
  case ty {
    IrTypeList(inner) ->
      IrTypeList(rewrite_ir_type(inner, source_mod, target_mod_name, patch_maps))
    IrTypeResult(o, e) ->
      IrTypeResult(
        rewrite_ir_type(o, source_mod, target_mod_name, patch_maps),
        rewrite_ir_type(e, source_mod, target_mod_name, patch_maps),
      )
    IrTypeTuple(els) ->
      IrTypeTuple(
        list.map(els, rewrite_ir_type(
          _,
          source_mod,
          target_mod_name,
          patch_maps,
        )),
      )
    IrTypeFn(ps, r) ->
      IrTypeFn(
        list.map(ps, rewrite_ir_type(_, source_mod, target_mod_name, patch_maps)),
        rewrite_ir_type(r, source_mod, target_mod_name, patch_maps),
      )
    IrTypeNamed(module_alias:, package:, module:, name:, args:) -> {
      let new_args =
        list.map(args, rewrite_ir_type(
          _,
          source_mod,
          target_mod_name,
          patch_maps,
        ))
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
    _ -> ty
  }
}

fn rewrite_stmts(
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
      case stmt {
        IrStmtLet(pattern:, annotation:, value:) -> {
          let new_val =
            rewrite_expr(
              value,
              cur_bound,
              source_mod,
              src_idx,
              target_mod_name,
              patch_maps,
              renames,
            )
          let new_pat =
            rewrite_pattern(
              pattern,
              cur_bound,
              source_mod,
              src_idx,
              target_mod_name,
              patch_maps,
              renames,
            )
          let new_ann =
            option.map(annotation, rewrite_ir_type(
              _,
              source_mod,
              target_mod_name,
              patch_maps,
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
              patch_maps,
              renames,
            )
          let new_pat =
            rewrite_pattern(
              pattern,
              cur_bound,
              source_mod,
              src_idx,
              target_mod_name,
              patch_maps,
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
              patch_maps,
              renames,
            ))
          let new_abort =
            option.map(abort_message, rewrite_expr(
              _,
              pat_bound,
              source_mod,
              src_idx,
              target_mod_name,
              patch_maps,
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
                  patch_maps,
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
              patch_maps,
              renames,
            )
          let new_abort =
            option.map(abort_message, rewrite_expr(
              _,
              cur_bound,
              source_mod,
              src_idx,
              target_mod_name,
              patch_maps,
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
            patch_maps,
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
  patch_maps: PatchMaps,
  renames: Dict(String, String),
) -> IrExpr {
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
    IrInt(_) | IrFloat(_) | IrString(_) | IrBool(_) | IrUnit -> expr
    IrTuple(els) ->
      IrTuple(
        list.map(els, rewrite_expr(
          _,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          patch_maps,
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
          patch_maps,
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
          patch_maps,
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
          patch_maps,
          renames,
        )),
        tail: option.map(tail, rewrite_expr(
          _,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          patch_maps,
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
              patch_maps,
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
                    patch_maps,
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
        patch_maps,
        renames,
      ))
    IrNegateBool(inner) ->
      IrNegateBool(rewrite_expr(
        inner,
        bound,
        source_mod,
        src_idx,
        target_mod_name,
        patch_maps,
        renames,
      ))
    IrBreak(inner) ->
      IrBreak(rewrite_expr(
        inner,
        bound,
        source_mod,
        src_idx,
        target_mod_name,
        patch_maps,
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
          patch_maps,
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
          patch_maps,
          renames,
        ),
        right: rewrite_expr(
          right,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          patch_maps,
          renames,
        ),
      )
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
                True ->
                  rewrite_expr(
                    inner_val,
                    bound,
                    source_mod,
                    src_idx,
                    target_mod_name,
                    patch_maps,
                    renames,
                  )
                False ->
                  rewrite_ir_call(
                    function,
                    args,
                    bound,
                    source_mod,
                    src_idx,
                    target_mod_name,
                    patch_maps,
                    renames,
                  )
              }
            _ ->
              rewrite_ir_call(
                function,
                args,
                bound,
                source_mod,
                src_idx,
                target_mod_name,
                patch_maps,
                renames,
              )
          }
        IrModuleRef(target_module: m, symbol: sym, ..), [] ->
          case dict.get(patch_maps.mirrors_by_mod, m) {
            Ok(mm) if mm.target_mod_name == target_mod_name ->
              case dict.get(mm.const_fn_map, sym) {
                Ok(target_const_sym) -> IrVar(target_const_sym)
                Error(_) ->
                  rewrite_ir_call(
                    function,
                    args,
                    bound,
                    source_mod,
                    src_idx,
                    target_mod_name,
                    patch_maps,
                    renames,
                  )
              }
            _ ->
              rewrite_ir_call(
                function,
                args,
                bound,
                source_mod,
                src_idx,
                target_mod_name,
                patch_maps,
                renames,
              )
          }
        _, _ ->
          rewrite_ir_call(
            function,
            args,
            bound,
            source_mod,
            src_idx,
            target_mod_name,
            patch_maps,
            renames,
          )
      }
    IrBlock(stmts) ->
      IrBlock(rewrite_stmts(
        stmts,
        bound,
        source_mod,
        src_idx,
        target_mod_name,
        patch_maps,
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
              patch_maps,
            )),
          )
        })
      IrFn(
        params: new_params,
        return_type: option.map(return_type, rewrite_ir_type(
          _,
          source_mod,
          target_mod_name,
          patch_maps,
        )),
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
          let new_val =
            rewrite_expr(
              b.1,
              bound,
              source_mod,
              src_idx,
              target_mod_name,
              patch_maps,
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
          patch_maps,
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
          patch_maps,
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
    IrEcho(expr: inner, message:, file_path:, line:) ->
      IrEcho(
        expr: rewrite_expr(
          inner,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          patch_maps,
          renames,
        ),
        message: option.map(message, rewrite_expr(
          _,
          bound,
          source_mod,
          src_idx,
          target_mod_name,
          patch_maps,
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
          patch_maps,
          renames,
        )),
      )
  }
}

fn rewrite_ir_call(
  function: IrExpr,
  args: List(IrCallArg),
  bound: Set(String),
  source_mod: IrModule,
  src_idx: ModIndex,
  target_mod_name: String,
  patch_maps: PatchMaps,
  renames: Dict(String, String),
) -> IrExpr {
  IrCall(
    function: rewrite_expr(
      function,
      bound,
      source_mod,
      src_idx,
      target_mod_name,
      patch_maps,
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
          patch_maps,
          renames,
        ),
      )
    }),
  )
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
  patch_maps: PatchMaps,
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
          patch_maps,
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
          patch_maps,
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
          IrPatArg(
            label: arg.label,
            pattern: rewrite_pattern(
              arg.pattern,
              bound,
              source_mod,
              src_idx,
              target_mod_name,
              patch_maps,
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
  list.any(f.params, fn(p) {
    type_uses_mirror_or_pruned(p.param_type, cur_mod, mirrors, pruned_types)
  })
  || type_uses_mirror_or_pruned(f.return_type, cur_mod, mirrors, pruned_types)
  || stmts_use_mirror_or_pruned(
    f.body,
    cur_mod,
    mirrors,
    pruned_types,
    pruned_ctors,
  )
}

fn type_uses_mirror_or_pruned(
  ty: IrType,
  cur_mod: String,
  mirrors: Dict(String, MirrorMap),
  pruned_types: Set(String),
) -> Bool {
  case ty {
    IrTypeList(inner) ->
      type_uses_mirror_or_pruned(inner, cur_mod, mirrors, pruned_types)
    IrTypeResult(ok:, err:) ->
      type_uses_mirror_or_pruned(ok, cur_mod, mirrors, pruned_types)
      || type_uses_mirror_or_pruned(err, cur_mod, mirrors, pruned_types)
    IrTypeTuple(els) ->
      list.any(els, type_uses_mirror_or_pruned(
        _,
        cur_mod,
        mirrors,
        pruned_types,
      ))
    IrTypeFn(params:, return:) ->
      list.any(params, type_uses_mirror_or_pruned(
        _,
        cur_mod,
        mirrors,
        pruned_types,
      ))
      || type_uses_mirror_or_pruned(return, cur_mod, mirrors, pruned_types)
    IrTypeNamed(module:, name:, args:, ..) -> {
      let resolved = case module {
        "" -> cur_mod
        m -> m
      }
      dict.has_key(mirrors, resolved)
      || { resolved == cur_mod && set.contains(pruned_types, name) }
      || list.any(args, type_uses_mirror_or_pruned(
        _,
        cur_mod,
        mirrors,
        pruned_types,
      ))
    }
    _ -> False
  }
}

fn stmts_use_mirror_or_pruned(
  stmts: List(IrStmt),
  cur_mod: String,
  mirrors: Dict(String, MirrorMap),
  pruned_types: Set(String),
  pruned_ctors: Set(String),
) -> Bool {
  list.any(stmts, fn(stmt) {
    case stmt {
      IrStmtLet(pattern:, annotation:, value:) ->
        pattern_uses_mirror_or_pruned(pattern, cur_mod, mirrors, pruned_ctors)
        || case annotation {
          Some(t) ->
            type_uses_mirror_or_pruned(t, cur_mod, mirrors, pruned_types)
          None -> False
        }
        || expr_uses_mirror_or_pruned(
          value,
          cur_mod,
          mirrors,
          pruned_types,
          pruned_ctors,
        )
      IrStmtGuard(
        value:,
        pattern:,
        guard_condition:,
        abort_message:,
        post_bindings:,
      ) ->
        expr_uses_mirror_or_pruned(
          value,
          cur_mod,
          mirrors,
          pruned_types,
          pruned_ctors,
        )
        || pattern_uses_mirror_or_pruned(
          pattern,
          cur_mod,
          mirrors,
          pruned_ctors,
        )
        || case guard_condition {
          Some(g) ->
            expr_uses_mirror_or_pruned(
              g,
              cur_mod,
              mirrors,
              pruned_types,
              pruned_ctors,
            )
          None -> False
        }
        || case abort_message {
          Some(m) ->
            expr_uses_mirror_or_pruned(
              m,
              cur_mod,
              mirrors,
              pruned_types,
              pruned_ctors,
            )
          None -> False
        }
        || list.any(post_bindings, fn(pb) {
          expr_uses_mirror_or_pruned(
            pb.1,
            cur_mod,
            mirrors,
            pruned_types,
            pruned_ctors,
          )
        })
      IrStmtAssert(condition:, abort_message:) ->
        expr_uses_mirror_or_pruned(
          condition,
          cur_mod,
          mirrors,
          pruned_types,
          pruned_ctors,
        )
        || case abort_message {
          Some(m) ->
            expr_uses_mirror_or_pruned(
              m,
              cur_mod,
              mirrors,
              pruned_types,
              pruned_ctors,
            )
          None -> False
        }
      IrStmtExpr(e) ->
        expr_uses_mirror_or_pruned(
          e,
          cur_mod,
          mirrors,
          pruned_types,
          pruned_ctors,
        )
    }
  })
}

fn expr_uses_mirror_or_pruned(
  expr: IrExpr,
  cur_mod: String,
  mirrors: Dict(String, MirrorMap),
  pruned_types: Set(String),
  pruned_ctors: Set(String),
) -> Bool {
  case expr {
    IrModuleRef(target_module:, ..) -> dict.has_key(mirrors, target_module)
    IrConstructor(target_module:, name:, ..) ->
      case target_module {
        Some(m) ->
          dict.has_key(mirrors, m)
          || { m == cur_mod && set.contains(pruned_ctors, name) }
        None -> set.contains(pruned_ctors, name)
      }
    IrTuple(els) | IrContinue(els) ->
      list.any(els, expr_uses_mirror_or_pruned(
        _,
        cur_mod,
        mirrors,
        pruned_types,
        pruned_ctors,
      ))
    IrTupleIndex(tuple:, ..)
    | IrNegateInt(tuple)
    | IrNegateBool(tuple)
    | IrBreak(tuple) ->
      expr_uses_mirror_or_pruned(
        tuple,
        cur_mod,
        mirrors,
        pruned_types,
        pruned_ctors,
      )
    IrGetterCall(receiver:, ..) ->
      expr_uses_mirror_or_pruned(
        receiver,
        cur_mod,
        mirrors,
        pruned_types,
        pruned_ctors,
      )
    IrList(elements:, tail:) ->
      list.any(elements, expr_uses_mirror_or_pruned(
        _,
        cur_mod,
        mirrors,
        pruned_types,
        pruned_ctors,
      ))
      || case tail {
        Some(t) ->
          expr_uses_mirror_or_pruned(
            t,
            cur_mod,
            mirrors,
            pruned_types,
            pruned_ctors,
          )
        None -> False
      }
    IrBitString(segments:) ->
      list.any(segments, fn(seg) {
        expr_uses_mirror_or_pruned(
          seg.0,
          cur_mod,
          mirrors,
          pruned_types,
          pruned_ctors,
        )
      })
    IrBinOp(left:, right:, ..) ->
      expr_uses_mirror_or_pruned(
        left,
        cur_mod,
        mirrors,
        pruned_types,
        pruned_ctors,
      )
      || expr_uses_mirror_or_pruned(
        right,
        cur_mod,
        mirrors,
        pruned_types,
        pruned_ctors,
      )
    IrCall(function:, args:) ->
      expr_uses_mirror_or_pruned(
        function,
        cur_mod,
        mirrors,
        pruned_types,
        pruned_ctors,
      )
      || list.any(args, fn(a) {
        expr_uses_mirror_or_pruned(
          a.value,
          cur_mod,
          mirrors,
          pruned_types,
          pruned_ctors,
        )
      })
    IrBlock(stmts) ->
      stmts_use_mirror_or_pruned(
        stmts,
        cur_mod,
        mirrors,
        pruned_types,
        pruned_ctors,
      )
    IrFn(params:, return_type:, body:) ->
      list.any(params, fn(p) {
        case p.param_type {
          Some(t) ->
            type_uses_mirror_or_pruned(t, cur_mod, mirrors, pruned_types)
          None -> False
        }
      })
      || case return_type {
        Some(r) -> type_uses_mirror_or_pruned(r, cur_mod, mirrors, pruned_types)
        None -> False
      }
      || stmts_use_mirror_or_pruned(
        body,
        cur_mod,
        mirrors,
        pruned_types,
        pruned_ctors,
      )
    IrForLoop(bindings:, body:) ->
      list.any(bindings, fn(b) {
        expr_uses_mirror_or_pruned(
          b.1,
          cur_mod,
          mirrors,
          pruned_types,
          pruned_ctors,
        )
      })
      || stmts_use_mirror_or_pruned(
        body,
        cur_mod,
        mirrors,
        pruned_types,
        pruned_ctors,
      )
    IrMatch(subjects:, clauses:) ->
      list.any(subjects, expr_uses_mirror_or_pruned(
        _,
        cur_mod,
        mirrors,
        pruned_types,
        pruned_ctors,
      ))
      || list.any(clauses, fn(c) {
        list.any(c.patterns, fn(alt) {
          list.any(alt, pattern_uses_mirror_or_pruned(
            _,
            cur_mod,
            mirrors,
            pruned_ctors,
          ))
        })
        || case c.guard {
          Some(g) ->
            expr_uses_mirror_or_pruned(
              g,
              cur_mod,
              mirrors,
              pruned_types,
              pruned_ctors,
            )
          None -> False
        }
        || list.any(c.prefix_bindings, fn(pb) {
          expr_uses_mirror_or_pruned(
            pb.1,
            cur_mod,
            mirrors,
            pruned_types,
            pruned_ctors,
          )
        })
        || expr_uses_mirror_or_pruned(
          c.body,
          cur_mod,
          mirrors,
          pruned_types,
          pruned_ctors,
        )
      })
    IrEcho(expr: inner, message:, ..) ->
      expr_uses_mirror_or_pruned(
        inner,
        cur_mod,
        mirrors,
        pruned_types,
        pruned_ctors,
      )
      || case message {
        Some(m) ->
          expr_uses_mirror_or_pruned(
            m,
            cur_mod,
            mirrors,
            pruned_types,
            pruned_ctors,
          )
        None -> False
      }
    IrAbort(message:, ..) ->
      case message {
        Some(m) ->
          expr_uses_mirror_or_pruned(
            m,
            cur_mod,
            mirrors,
            pruned_types,
            pruned_ctors,
          )
        None -> False
      }
    _ -> False
  }
}

fn pattern_uses_mirror_or_pruned(
  pat: IrPattern,
  cur_mod: String,
  mirrors: Dict(String, MirrorMap),
  pruned_ctors: Set(String),
) -> Bool {
  case pat {
    IrPatTuple(els) ->
      list.any(els, pattern_uses_mirror_or_pruned(
        _,
        cur_mod,
        mirrors,
        pruned_ctors,
      ))
    IrPatAs(inner, _) ->
      pattern_uses_mirror_or_pruned(inner, cur_mod, mirrors, pruned_ctors)
    IrPatVariant(target_module:, constructor:, args:, ..) ->
      case target_module {
        Some(m) ->
          dict.has_key(mirrors, m)
          || { m == cur_mod && set.contains(pruned_ctors, constructor) }
        None -> set.contains(pruned_ctors, constructor)
      }
      || list.any(args, fn(a) {
        pattern_uses_mirror_or_pruned(a.pattern, cur_mod, mirrors, pruned_ctors)
      })
    IrPatBitString(segments:) ->
      list.any(segments, fn(seg) {
        pattern_uses_mirror_or_pruned(seg.0, cur_mod, mirrors, pruned_ctors)
      })
    _ -> False
  }
}

// -----------------------------------------------------------------------------
// Prune unreachable private types in patched target modules
// -----------------------------------------------------------------------------

fn prune_unused_private_types(mod: IrModule) -> IrModule {
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
          collect_expr_type_refs(c.value, mod.module_name, ctor_to_type, acc)
        })
      let root_refs =
        list.fold(mod.functions, root_refs, fn(acc, f) {
          collect_fn_type_refs(f, mod.module_name, ctor_to_type, acc)
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
  case ty {
    IrTypeList(inner) -> collect_type_refs(inner, mod_name, acc)
    IrTypeResult(ok:, err:) ->
      collect_type_refs(ok, mod_name, acc)
      |> fn(next) { collect_type_refs(err, mod_name, next) }
    IrTypeTuple(els) ->
      list.fold(els, acc, fn(el_acc, el) {
        collect_type_refs(el, mod_name, el_acc)
      })
    IrTypeFn(params:, return:) -> {
      let after_params =
        list.fold(params, acc, fn(p_acc, p) {
          collect_type_refs(p, mod_name, p_acc)
        })
      collect_type_refs(return, mod_name, after_params)
    }
    IrTypeNamed(module:, name:, args:, ..) -> {
      let acc = case module == "" || module == mod_name {
        True -> set.insert(acc, name)
        False -> acc
      }
      list.fold(args, acc, fn(a_acc, a) {
        collect_type_refs(a, mod_name, a_acc)
      })
    }
    IrTypeInt64
    | IrTypeDouble
    | IrTypeString
    | IrTypeBool
    | IrTypeUnit
    | IrTypeBitArray
    | IrTypeVar(_) -> acc
  }
}

fn collect_fn_type_refs(
  f: IrFunction,
  mod_name: String,
  ctor_to_type: Dict(String, String),
  acc: Set(String),
) -> Set(String) {
  let acc =
    list.fold(f.params, acc, fn(p_acc, p) {
      collect_type_refs(p.param_type, mod_name, p_acc)
    })
  let acc = collect_type_refs(f.return_type, mod_name, acc)
  collect_stmts_type_refs(f.body, mod_name, ctor_to_type, acc)
}

fn collect_stmts_type_refs(
  stmts: List(IrStmt),
  mod_name: String,
  ctor_to_type: Dict(String, String),
  acc: Set(String),
) -> Set(String) {
  list.fold(stmts, acc, fn(s_acc, stmt) {
    case stmt {
      IrStmtLet(pattern:, annotation:, value:) -> {
        let s_acc =
          collect_pattern_type_refs(pattern, mod_name, ctor_to_type, s_acc)
        let s_acc = case annotation {
          Some(ty) -> collect_type_refs(ty, mod_name, s_acc)
          None -> s_acc
        }
        collect_expr_type_refs(value, mod_name, ctor_to_type, s_acc)
      }
      IrStmtGuard(
        value:,
        pattern:,
        guard_condition:,
        abort_message:,
        post_bindings:,
      ) -> {
        let s_acc = collect_expr_type_refs(value, mod_name, ctor_to_type, s_acc)
        let s_acc =
          collect_pattern_type_refs(pattern, mod_name, ctor_to_type, s_acc)
        let s_acc = case guard_condition {
          Some(g) -> collect_expr_type_refs(g, mod_name, ctor_to_type, s_acc)
          None -> s_acc
        }
        let s_acc = case abort_message {
          Some(m) -> collect_expr_type_refs(m, mod_name, ctor_to_type, s_acc)
          None -> s_acc
        }
        list.fold(post_bindings, s_acc, fn(b_acc, b) {
          collect_expr_type_refs(b.1, mod_name, ctor_to_type, b_acc)
        })
      }
      IrStmtAssert(condition:, abort_message:) -> {
        let s_acc =
          collect_expr_type_refs(condition, mod_name, ctor_to_type, s_acc)
        case abort_message {
          Some(m) -> collect_expr_type_refs(m, mod_name, ctor_to_type, s_acc)
          None -> s_acc
        }
      }
      IrStmtExpr(expr) ->
        collect_expr_type_refs(expr, mod_name, ctor_to_type, s_acc)
    }
  })
}

fn collect_expr_type_refs(
  expr: IrExpr,
  mod_name: String,
  ctor_to_type: Dict(String, String),
  acc: Set(String),
) -> Set(String) {
  case expr {
    IrInt(_) | IrFloat(_) | IrString(_) | IrBool(_) | IrUnit -> acc
    IrVar(name) -> record_ctor_type_ref(name, ctor_to_type, acc)
    IrModuleRef(target_module:, symbol:, ..) ->
      case target_module == mod_name {
        True -> record_ctor_type_ref(symbol, ctor_to_type, acc)
        False -> acc
      }
    IrConstructor(target_module:, name:, ..) ->
      case target_module == None || target_module == Some(mod_name) {
        True -> record_ctor_type_ref(name, ctor_to_type, acc)
        False -> acc
      }
    IrTuple(els) | IrContinue(els) ->
      list.fold(els, acc, fn(e_acc, e) {
        collect_expr_type_refs(e, mod_name, ctor_to_type, e_acc)
      })
    IrTupleIndex(tuple:, ..) | IrNegateInt(tuple) | IrNegateBool(tuple) ->
      collect_expr_type_refs(tuple, mod_name, ctor_to_type, acc)
    IrList(elements:, tail:) -> {
      let acc =
        list.fold(elements, acc, fn(e_acc, e) {
          collect_expr_type_refs(e, mod_name, ctor_to_type, e_acc)
        })
      case tail {
        Some(t) -> collect_expr_type_refs(t, mod_name, ctor_to_type, acc)
        None -> acc
      }
    }
    IrBitString(segments:) ->
      list.fold(segments, acc, fn(seg_acc, seg) {
        let seg_acc =
          collect_expr_type_refs(seg.0, mod_name, ctor_to_type, seg_acc)
        list.fold(seg.1, seg_acc, fn(opt_acc, opt) {
          case opt {
            glance.SizeValueOption(v) ->
              collect_expr_type_refs(v, mod_name, ctor_to_type, opt_acc)
            _ -> opt_acc
          }
        })
      })
    IrBinOp(left:, right:, ..) -> {
      let acc = collect_expr_type_refs(left, mod_name, ctor_to_type, acc)
      collect_expr_type_refs(right, mod_name, ctor_to_type, acc)
    }
    IrCall(function:, args:) -> {
      let acc = collect_expr_type_refs(function, mod_name, ctor_to_type, acc)
      list.fold(args, acc, fn(a_acc, a) {
        collect_expr_type_refs(a.value, mod_name, ctor_to_type, a_acc)
      })
    }
    IrGetterCall(receiver:, ..) ->
      collect_expr_type_refs(receiver, mod_name, ctor_to_type, acc)
    IrBlock(stmts) ->
      collect_stmts_type_refs(stmts, mod_name, ctor_to_type, acc)
    IrFn(params:, return_type:, body:) -> {
      let acc =
        list.fold(params, acc, fn(p_acc, p) {
          case p.param_type {
            Some(ty) -> collect_type_refs(ty, mod_name, p_acc)
            None -> p_acc
          }
        })
      let acc = case return_type {
        Some(ty) -> collect_type_refs(ty, mod_name, acc)
        None -> acc
      }
      collect_stmts_type_refs(body, mod_name, ctor_to_type, acc)
    }
    IrMatch(subjects:, clauses:) -> {
      let acc =
        list.fold(subjects, acc, fn(s_acc, s) {
          collect_expr_type_refs(s, mod_name, ctor_to_type, s_acc)
        })
      list.fold(clauses, acc, fn(c_acc, c) {
        let c_acc =
          list.fold(c.patterns, c_acc, fn(ps_acc, ps) {
            list.fold(ps, ps_acc, fn(p_acc, p) {
              collect_pattern_type_refs(p, mod_name, ctor_to_type, p_acc)
            })
          })
        let c_acc = case c.guard {
          Some(g) -> collect_expr_type_refs(g, mod_name, ctor_to_type, c_acc)
          None -> c_acc
        }
        let c_acc =
          list.fold(c.prefix_bindings, c_acc, fn(b_acc, b) {
            collect_expr_type_refs(b.1, mod_name, ctor_to_type, b_acc)
          })
        collect_expr_type_refs(c.body, mod_name, ctor_to_type, c_acc)
      })
    }
    IrForLoop(bindings:, body:) -> {
      let acc =
        list.fold(bindings, acc, fn(b_acc, b) {
          collect_expr_type_refs(b.1, mod_name, ctor_to_type, b_acc)
        })
      collect_stmts_type_refs(body, mod_name, ctor_to_type, acc)
    }
    IrBreak(e) -> collect_expr_type_refs(e, mod_name, ctor_to_type, acc)
    IrAbort(message:, ..) ->
      case message {
        Some(m) -> collect_expr_type_refs(m, mod_name, ctor_to_type, acc)
        None -> acc
      }
    IrEcho(expr:, message:, ..) -> {
      let acc = collect_expr_type_refs(expr, mod_name, ctor_to_type, acc)
      case message {
        Some(m) -> collect_expr_type_refs(m, mod_name, ctor_to_type, acc)
        None -> acc
      }
    }
  }
}

fn collect_pattern_type_refs(
  pat: IrPattern,
  mod_name: String,
  ctor_to_type: Dict(String, String),
  acc: Set(String),
) -> Set(String) {
  case pat {
    IrPatInt(_)
    | IrPatFloat(_)
    | IrPatString(_)
    | IrPatBool(_)
    | IrPatUnit
    | IrPatDiscard
    | IrPatVar(_) -> acc
    IrPatAs(pattern:, ..) ->
      collect_pattern_type_refs(pattern, mod_name, ctor_to_type, acc)
    IrPatTuple(els) ->
      list.fold(els, acc, fn(p_acc, p) {
        collect_pattern_type_refs(p, mod_name, ctor_to_type, p_acc)
      })
    IrPatVariant(target_module:, constructor:, args:, ..) -> {
      let acc = case target_module == None || target_module == Some(mod_name) {
        True -> record_ctor_type_ref(constructor, ctor_to_type, acc)
        False -> acc
      }
      list.fold(args, acc, fn(a_acc, a) {
        collect_pattern_type_refs(a.pattern, mod_name, ctor_to_type, a_acc)
      })
    }
    IrPatBitString(segments:) ->
      list.fold(segments, acc, fn(seg_acc, seg) {
        collect_pattern_type_refs(seg.0, mod_name, ctor_to_type, seg_acc)
      })
  }
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

// -----------------------------------------------------------------------------
// Phase 1: Validate @patch_mirror modules and construct MirrorMaps
// -----------------------------------------------------------------------------

fn validate_and_build_mirrors(
  patch_mirrors: Dict(String, PatchMirrorInfo),
  mods_by_name: Dict(String, IrModule),
  all_aliases: Dict(#(String, String), IrTypeAlias),
  module_pkg_by_name: Dict(String, String),
) -> Result(Dict(String, MirrorMap), String) {
  dict.to_list(patch_mirrors)
  |> list.try_fold(dict.new(), fn(acc, entry) {
    let #(mirror_mod_name, info) = entry
    use mirror_mod <- result.try(
      dict.get(mods_by_name, mirror_mod_name)
      |> result.map_error(fn(_) {
        "Mirror module '" <> mirror_mod_name <> "' was not found in IR modules"
      }),
    )
    use target_mod <- result.try(resolve_mirror_target_mod(
      info,
      mods_by_name,
      module_pkg_by_name,
    ))
    let prelim = build_prelim_mirror_map(mirror_mod, target_mod, info.decls)
    use _ <- result.try(validate_mirror_decls(
      mirror_mod,
      target_mod,
      info,
      prelim,
      all_aliases,
    ))
    Ok(dict.insert(acc, mirror_mod_name, prelim))
  })
}

fn resolve_mirror_target_mod(
  info: PatchMirrorInfo,
  mods_by_name: Dict(String, IrModule),
  module_pkg_by_name: Dict(String, String),
) -> Result(IrModule, String) {
  let #(expected_pkg, mod_name) = case string.split_once(info.target, ":") {
    Ok(#(p, m)) -> #(Some(p), m)
    Error(_) -> #(None, info.target)
  }
  use target_mod <- result.try(
    dict.get(mods_by_name, mod_name)
    |> result.map_error(fn(_) {
      "Mirror module '"
      <> info.mirror_module
      <> "' (line "
      <> int.to_string(info.line)
      <> ") targets unknown module '"
      <> info.target
      <> "'"
    }),
  )
  case expected_pkg {
    Some(p) ->
      case dict.get(module_pkg_by_name, mod_name) {
        Ok(actual) if actual != p ->
          Error(
            "Mirror module '"
            <> info.mirror_module
            <> "' targets '"
            <> info.target
            <> "', but module '"
            <> mod_name
            <> "' belongs to package '"
            <> actual
            <> "'",
          )
        _ -> Ok(target_mod)
      }
    None -> Ok(target_mod)
  }
}

fn mirror_drift_error(
  mirror_mod_name: String,
  decl: MirrorDeclEntry,
  reason: String,
) -> String {
  "Mirror drift in '"
  <> mirror_mod_name
  <> "' (line "
  <> int.to_string(decl.line)
  <> "): "
  <> reason
  <> ". Run 'gekko shim sync' to regenerate."
}

fn find_ir_type(mod: IrModule, name: String) -> Option(IrTypeDef) {
  let mangled = mangle.mangle_type_name(name)
  list.find(mod.types, fn(td) {
    td.unmangled_name == name || td.name == name || td.name == mangled
  })
  |> option.from_result
}

fn find_ir_alias(mod: IrModule, name: String) -> Option(IrTypeAlias) {
  let mangled = mangle.mangle_type_name(name)
  list.find(mod.type_aliases, fn(ta) { ta.name == name || ta.name == mangled })
  |> option.from_result
}

fn find_ir_fn(mod: IrModule, name: String) -> Option(IrFunction) {
  let mangled = mangle.mangle_ident(name)
  list.find(mod.functions, fn(f) {
    f.unmangled_name == name || f.name == name || f.name == mangled
  })
  |> option.from_result
}

fn find_ir_const(mod: IrModule, name: String) -> Option(IrConstant) {
  let mangled = mangle.mangle_ident(name)
  list.find(mod.constants, fn(c) {
    c.unmangled_name == name || c.name == name || c.name == mangled
  })
  |> option.from_result
}

fn build_prelim_mirror_map(
  mirror_mod: IrModule,
  target_mod: IrModule,
  decls: List(MirrorDeclEntry),
) -> MirrorMap {
  let init =
    MirrorMap(
      mirror_mod_name: mirror_mod.module_name,
      target_mod_name: target_mod.module_name,
      target_pkg_name: target_mod.package_name,
      type_map: dict.new(),
      ctor_map: dict.new(),
      to_public_fns: set.new(),
      from_public_fns: set.new(),
      fn_map: dict.new(),
      const_map: dict.new(),
      const_fn_map: dict.new(),
    )
  list.fold(decls, init, fn(mm, decl) {
    let local_mangled = mangle.mangle_ident(decl.local_name)
    let local_ty_mangled = mangle.mangle_type_name(decl.local_name)
    case decl.kind {
      MirrorType(target_name) | MirrorOpaque(target_name) -> {
        let target_ir_name = case find_ir_type(target_mod, target_name) {
          Some(td) -> td.name
          None ->
            case find_ir_alias(target_mod, target_name) {
              Some(ta) -> ta.name
              None -> mangle.mangle_type_name(target_name)
            }
        }
        let next_type_map =
          mm.type_map
          |> dict.insert(decl.local_name, target_ir_name)
          |> dict.insert(local_ty_mangled, target_ir_name)
        let next_ctor_map = case find_ir_type(target_mod, target_name) {
          Some(td) ->
            list.fold(td.variants, mm.ctor_map, fn(cm, v) {
              dict.insert(cm, v.name, v.name)
            })
          None -> mm.ctor_map
        }
        MirrorMap(..mm, type_map: next_type_map, ctor_map: next_ctor_map)
      }
      MirrorToPublic(_) ->
        MirrorMap(
          ..mm,
          to_public_fns: mm.to_public_fns
            |> set.insert(decl.local_name)
            |> set.insert(local_mangled),
        )
      MirrorFromPublic(_) ->
        MirrorMap(
          ..mm,
          from_public_fns: mm.from_public_fns
            |> set.insert(decl.local_name)
            |> set.insert(local_mangled),
        )
      MirrorFn(target_name) -> {
        let tgt_fn_name = case find_ir_fn(target_mod, target_name) {
          Some(tf) -> tf.name
          None -> mangle.mangle_ident(target_name)
        }
        MirrorMap(
          ..mm,
          fn_map: mm.fn_map
            |> dict.insert(decl.local_name, tgt_fn_name)
            |> dict.insert(local_mangled, tgt_fn_name),
        )
      }
      MirrorConst(target_name) -> {
        let tgt_const_name = case find_ir_const(target_mod, target_name) {
          Some(tc) -> tc.name
          None -> mangle.mangle_ident(target_name)
        }
        case find_ir_const(mirror_mod, decl.local_name) {
          Some(_) ->
            MirrorMap(
              ..mm,
              const_map: mm.const_map
                |> dict.insert(decl.local_name, tgt_const_name)
                |> dict.insert(local_mangled, tgt_const_name),
            )
          None ->
            MirrorMap(
              ..mm,
              const_fn_map: mm.const_fn_map
                |> dict.insert(decl.local_name, tgt_const_name)
                |> dict.insert(local_mangled, tgt_const_name),
            )
        }
      }
    }
  })
}

fn normalize_mirror_type(
  ty: IrType,
  cur_mod: String,
  mm: MirrorMap,
  all_aliases: Dict(#(String, String), IrTypeAlias),
) -> IrType {
  let single = dict.from_list([#(mm.mirror_mod_name, mm)])
  let pm =
    PatchMaps(
      mirrors_by_mod: single,
      type_patch_map: dict.new(),
      type_patch_ctor_map: dict.new(),
      mods_by_name: dict.new(),
    )
  normalize_type_for_patch(ty, cur_mod, mm.target_mod_name, all_aliases, pm)
}

fn validate_mirror_decls(
  mirror_mod: IrModule,
  target_mod: IrModule,
  info: PatchMirrorInfo,
  mm: MirrorMap,
  all_aliases: Dict(#(String, String), IrTypeAlias),
) -> Result(Nil, String) {
  list.try_each(info.decls, fn(decl) {
    case decl.kind {
      MirrorType(target_name) ->
        validate_mirror_type_decl(
          mirror_mod,
          target_mod,
          decl,
          target_name,
          False,
          mm,
          all_aliases,
        )
      MirrorOpaque(target_name) ->
        validate_mirror_type_decl(
          mirror_mod,
          target_mod,
          decl,
          target_name,
          True,
          mm,
          all_aliases,
        )
      MirrorToPublic(target_type) ->
        validate_mirror_bridge_fn(
          mirror_mod,
          target_mod,
          decl,
          target_type,
          True,
          mm,
          all_aliases,
        )
      MirrorFromPublic(target_type) ->
        validate_mirror_bridge_fn(
          mirror_mod,
          target_mod,
          decl,
          target_type,
          False,
          mm,
          all_aliases,
        )
      MirrorFn(target_name) ->
        validate_mirror_fn_decl(
          mirror_mod,
          target_mod,
          decl,
          target_name,
          mm,
          all_aliases,
        )
      MirrorConst(target_name) ->
        validate_mirror_const_decl(
          mirror_mod,
          target_mod,
          decl,
          target_name,
          mm,
          all_aliases,
        )
    }
  })
}

fn validate_mirror_type_decl(
  mirror_mod: IrModule,
  target_mod: IrModule,
  decl: MirrorDeclEntry,
  target_name: String,
  require_opaque: Bool,
  mm: MirrorMap,
  all_aliases: Dict(#(String, String), IrTypeAlias),
) -> Result(Nil, String) {
  case
    find_ir_type(mirror_mod, decl.local_name),
    find_ir_type(target_mod, target_name)
  {
    Some(mtd), Some(ttd) -> {
      use _ <- result.try(case require_opaque && !ttd.opaque_ {
        True ->
          Error(mirror_drift_error(
            mirror_mod.module_name,
            decl,
            "'" <> target_name <> "' is no longer opaque",
          ))
        False -> Ok(Nil)
      })
      use _ <- result.try(
        case list.length(mtd.type_params) == list.length(ttd.type_params) {
          True -> Ok(Nil)
          False ->
            Error(mirror_drift_error(
              mirror_mod.module_name,
              decl,
              "type parameter count changed on '" <> target_name <> "'",
            ))
        },
      )
      use _ <- result.try(
        case list.length(mtd.variants) == list.length(ttd.variants) {
          True -> Ok(Nil)
          False ->
            Error(mirror_drift_error(
              mirror_mod.module_name,
              decl,
              "variant count changed on '" <> target_name <> "'",
            ))
        },
      )
      let param_pairs = list.zip(mtd.type_params, ttd.type_params)
      let init_bij =
        list.fold(
          param_pairs,
          TypeBijection(dict.new(), dict.new()),
          fn(b, pair) {
            TypeBijection(
              s_to_t: dict.insert(b.s_to_t, pair.0, pair.1),
              t_to_s: dict.insert(b.t_to_s, pair.1, pair.0),
            )
          },
        )
      list.zip(mtd.variants, ttd.variants)
      |> list.try_each(fn(v_pair) {
        let #(mv, tv) = v_pair
        use _ <- result.try(case mv.name == tv.name {
          True -> Ok(Nil)
          False ->
            Error(mirror_drift_error(
              mirror_mod.module_name,
              decl,
              "variant '" <> mv.name <> "' does not match '" <> tv.name <> "'",
            ))
        })
        use _ <- result.try(
          case list.length(mv.fields) == list.length(tv.fields) {
            True -> Ok(Nil)
            False ->
              Error(mirror_drift_error(
                mirror_mod.module_name,
                decl,
                "field count changed on variant '" <> tv.name <> "'",
              ))
          },
        )
        list.zip(mv.fields, tv.fields)
        |> list.try_each(fn(f_pair) {
          let #(mf, tf) = f_pair
          use _ <- result.try(case mf.unmangled_label == tf.unmangled_label {
            True -> Ok(Nil)
            False ->
              Error(mirror_drift_error(
                mirror_mod.module_name,
                decl,
                "field label changed on variant '" <> tv.name <> "'",
              ))
          })
          let nm =
            normalize_mirror_type(
              mf.field_type,
              mirror_mod.module_name,
              mm,
              all_aliases,
            )
          let nt =
            normalize_mirror_type(
              tf.field_type,
              target_mod.module_name,
              mm,
              all_aliases,
            )
          unify_sig_types(nm, nt, init_bij)
          |> result.map(fn(_) { Nil })
          |> result.map_error(fn(_) {
            mirror_drift_error(
              mirror_mod.module_name,
              decl,
              "field type changed on variant '" <> tv.name <> "'",
            )
          })
        })
      })
    }
    _, _ ->
      case
        !require_opaque,
        find_ir_alias(mirror_mod, decl.local_name),
        find_ir_alias(target_mod, target_name)
      {
        True, Some(mta), Some(tta) -> {
          use _ <- result.try(
            case list.length(mta.type_params) == list.length(tta.type_params) {
              True -> Ok(Nil)
              False ->
                Error(mirror_drift_error(
                  mirror_mod.module_name,
                  decl,
                  "type parameter count changed on alias '"
                    <> target_name
                    <> "'",
                ))
            },
          )
          let init_bij =
            list.zip(mta.type_params, tta.type_params)
            |> list.fold(TypeBijection(dict.new(), dict.new()), fn(b, pair) {
              TypeBijection(
                s_to_t: dict.insert(b.s_to_t, pair.0, pair.1),
                t_to_s: dict.insert(b.t_to_s, pair.1, pair.0),
              )
            })
          let nm =
            normalize_mirror_type(
              mta.aliased,
              mirror_mod.module_name,
              mm,
              all_aliases,
            )
          let nt =
            normalize_mirror_type(
              tta.aliased,
              target_mod.module_name,
              mm,
              all_aliases,
            )
          unify_sig_types(nm, nt, init_bij)
          |> result.map(fn(_) { Nil })
          |> result.map_error(fn(_) {
            mirror_drift_error(
              mirror_mod.module_name,
              decl,
              "aliased type changed on '" <> target_name <> "'",
            )
          })
        }
        _, _, _ ->
          Error(mirror_drift_error(
            mirror_mod.module_name,
            decl,
            "type '"
              <> target_name
              <> "' is missing or changed kind in '"
              <> target_mod.module_name
              <> "'",
          ))
      }
  }
}

fn validate_mirror_bridge_fn(
  mirror_mod: IrModule,
  target_mod: IrModule,
  decl: MirrorDeclEntry,
  target_type: String,
  is_to_public: Bool,
  mm: MirrorMap,
  all_aliases: Dict(#(String, String), IrTypeAlias),
) -> Result(Nil, String) {
  use ttd <- result.try(
    find_ir_type(target_mod, target_type)
    |> option.to_result(mirror_drift_error(
      mirror_mod.module_name,
      decl,
      "opaque target type '" <> target_type <> "' not found",
    )),
  )
  use mfn <- result.try(
    find_ir_fn(mirror_mod, decl.local_name)
    |> option.to_result(mirror_drift_error(
      mirror_mod.module_name,
      decl,
      "bridge function '" <> decl.local_name <> "' not found",
    )),
  )
  case mfn.params {
    [p] -> {
      let np =
        normalize_mirror_type(
          p.param_type,
          mirror_mod.module_name,
          mm,
          all_aliases,
        )
      let nr =
        normalize_mirror_type(
          mfn.return_type,
          mirror_mod.module_name,
          mm,
          all_aliases,
        )
      let _ = is_to_public
      let param_ok = case np {
        IrTypeNamed(module: m, name: n, args:, ..)
          if m == target_mod.module_name && n == ttd.name
        -> list.length(args) == list.length(ttd.type_params)
        _ -> False
      }
      case param_ok {
        False ->
          Error(mirror_drift_error(
            mirror_mod.module_name,
            decl,
            "bridge function '"
              <> decl.local_name
              <> "' parameter does not match '"
              <> target_type
              <> "'",
          ))
        True ->
          unify_sig_types(np, nr, TypeBijection(dict.new(), dict.new()))
          |> result.map(fn(_) { Nil })
          |> result.map_error(fn(_) {
            mirror_drift_error(
              mirror_mod.module_name,
              decl,
              "bridge function '"
                <> decl.local_name
                <> "' signature mismatch for '"
                <> target_type
                <> "'",
            )
          })
      }
    }
    _ ->
      Error(mirror_drift_error(
        mirror_mod.module_name,
        decl,
        "bridge function '" <> decl.local_name <> "' must take 1 parameter",
      ))
  }
}

fn validate_mirror_fn_decl(
  mirror_mod: IrModule,
  target_mod: IrModule,
  decl: MirrorDeclEntry,
  target_name: String,
  mm: MirrorMap,
  all_aliases: Dict(#(String, String), IrTypeAlias),
) -> Result(Nil, String) {
  use mfn <- result.try(
    find_ir_fn(mirror_mod, decl.local_name)
    |> option.to_result(mirror_drift_error(
      mirror_mod.module_name,
      decl,
      "mirror function '" <> decl.local_name <> "' not found",
    )),
  )
  use tfn <- result.try(
    find_ir_fn(target_mod, target_name)
    |> option.to_result(mirror_drift_error(
      mirror_mod.module_name,
      decl,
      "private function '"
        <> target_name
        <> "' no longer exists in '"
        <> target_mod.module_name
        <> "'",
    )),
  )
  use _ <- result.try(case list.length(mfn.params) == list.length(tfn.params) {
    True -> Ok(Nil)
    False ->
      Error(mirror_drift_error(
        mirror_mod.module_name,
        decl,
        "arity changed on '" <> target_name <> "'",
      ))
  })
  let init_bij = TypeBijection(dict.new(), dict.new())
  use bij_after_params <- result.try(
    list.zip(mfn.params, tfn.params)
    |> list.try_fold(init_bij, fn(cur_bij, pair) {
      let #(mp, tp) = pair
      use _ <- result.try(case mp.label == tp.label {
        True -> Ok(Nil)
        False ->
          Error(mirror_drift_error(
            mirror_mod.module_name,
            decl,
            "parameter label changed on '" <> target_name <> "'",
          ))
      })
      let nm =
        normalize_mirror_type(
          mp.param_type,
          mirror_mod.module_name,
          mm,
          all_aliases,
        )
      let nt =
        normalize_mirror_type(
          tp.param_type,
          target_mod.module_name,
          mm,
          all_aliases,
        )
      unify_sig_types(nm, nt, cur_bij)
      |> result.map_error(fn(_) {
        mirror_drift_error(
          mirror_mod.module_name,
          decl,
          "parameter type changed on '" <> target_name <> "'",
        )
      })
    }),
  )
  let nm_ret =
    normalize_mirror_type(
      mfn.return_type,
      mirror_mod.module_name,
      mm,
      all_aliases,
    )
  let nt_ret =
    normalize_mirror_type(
      tfn.return_type,
      target_mod.module_name,
      mm,
      all_aliases,
    )
  unify_sig_types(nm_ret, nt_ret, bij_after_params)
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(_) {
    mirror_drift_error(
      mirror_mod.module_name,
      decl,
      "return type changed on '" <> target_name <> "'",
    )
  })
}

fn validate_mirror_const_decl(
  mirror_mod: IrModule,
  target_mod: IrModule,
  decl: MirrorDeclEntry,
  target_name: String,
  mm: MirrorMap,
  all_aliases: Dict(#(String, String), IrTypeAlias),
) -> Result(Nil, String) {
  use tconst <- result.try(
    find_ir_const(target_mod, target_name)
    |> option.to_result(mirror_drift_error(
      mirror_mod.module_name,
      decl,
      "private constant '"
        <> target_name
        <> "' no longer exists in '"
        <> target_mod.module_name
        <> "'",
    )),
  )
  let mirror_ty_res = case find_ir_const(mirror_mod, decl.local_name) {
    Some(mc) -> Ok(mc.value_type)
    None ->
      case find_ir_fn(mirror_mod, decl.local_name) {
        Some(mfn) if mfn.params == [] -> Ok(mfn.return_type)
        _ ->
          Error(mirror_drift_error(
            mirror_mod.module_name,
            decl,
            "mirror constant '" <> decl.local_name <> "' not found",
          ))
      }
  }
  use m_ty <- result.try(mirror_ty_res)
  let nm = normalize_mirror_type(m_ty, mirror_mod.module_name, mm, all_aliases)
  let nt =
    normalize_mirror_type(
      tconst.value_type,
      target_mod.module_name,
      mm,
      all_aliases,
    )
  unify_sig_types(nm, nt, TypeBijection(dict.new(), dict.new()))
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(_) {
    mirror_drift_error(
      mirror_mod.module_name,
      decl,
      "constant type changed on '" <> target_name <> "'",
    )
  })
}

// -----------------------------------------------------------------------------
// Phase 2: Collect and splice @patch_type definitions
// -----------------------------------------------------------------------------

type TypePatchSourceDef {
  SourceTypeDef(IrTypeDef)
  SourceTypeAlias(IrTypeAlias)
}

type ResolvedTypePatch {
  ResolvedTypePatch(
    key: String,
    source_mod: IrModule,
    source_def: TypePatchSourceDef,
    target_mod_name: String,
    target_td: IrTypeDef,
  )
}

fn split_type_patch_key(key: String) -> #(String, String) {
  case string.split(key, ".") |> list.reverse {
    [ty_name, ..rev_rest] if rev_rest != [] -> #(
      rev_rest |> list.reverse |> string.join("."),
      ty_name,
    )
    _ -> #(key, "")
  }
}

fn splice_all_type_patches(
  ir_modules: List(IrModule),
  table: SymbolTable,
  gleam_type_patches: Dict(String, GleamTypePatch),
  mirrors_by_mod: Dict(String, MirrorMap),
  mods_by_name: Dict(String, IrModule),
  module_pkg_by_name: Dict(String, String),
) -> Result(
  #(
    List(IrModule),
    SymbolTable,
    Dict(#(String, String), #(String, String, String)),
    Dict(#(String, String), #(String, String)),
    SplicedTracker,
  ),
  String,
) {
  let empty_tracker = SplicedTracker(set.new(), set.new(), set.new())
  case dict.is_empty(gleam_type_patches) {
    True -> Ok(#(ir_modules, table, dict.new(), dict.new(), empty_tracker))
    False -> {
      use #(resolved_list, type_patch_map, type_ctor_map, tracker0) <- result.try(
        dict.to_list(gleam_type_patches)
        |> list.try_fold(
          #([], dict.new(), dict.new(), empty_tracker),
          fn(acc, entry) {
            let #(r_acc, t_map, c_map, tr) = acc
            let #(key, patch) = entry
            let #(mod_spec, target_ty_name) = split_type_patch_key(key)
            use target_mod <- result.try(
              list.find(ir_modules, fn(m) {
                let pkg =
                  dict.get(module_pkg_by_name, m.module_name)
                  |> result.unwrap("")
                m.module_name == mod_spec
                || { pkg != "" && pkg <> ":" <> m.module_name == mod_spec }
              })
              |> result.map_error(fn(_) {
                "Gleam @patch_type target module for '"
                <> key
                <> "' was not found"
              }),
            )
            use target_td <- result.try(
              list.find(target_mod.types, fn(td) {
                td.unmangled_name == target_ty_name
              })
              |> result.map_error(fn(_) {
                "Gleam @patch_type target '"
                <> key
                <> "' was not found as a custom type in '"
                <> target_mod.module_name
                <> "'"
              }),
            )
            use _ <- result.try(case target_td.variants == [] {
              True -> Ok(Nil)
              False ->
                Error(
                  "Gleam @patch_type can only patch zero-variant external types, but '"
                  <> key
                  <> "' has variants",
                )
            })
            use source_mod <- result.try(
              dict.get(mods_by_name, patch.source_module)
              |> result.map_error(fn(_) {
                "Gleam @patch_type source module '"
                <> patch.source_module
                <> "' for '"
                <> key
                <> "' was not found"
              }),
            )
            use source_def <- result.try(
              case find_ir_type(source_mod, patch.source_type) {
                Some(sd) -> Ok(SourceTypeDef(sd))
                None ->
                  case find_ir_alias(source_mod, patch.source_type) {
                    Some(sa) -> Ok(SourceTypeAlias(sa))
                    None ->
                      Error(
                        "Gleam @patch_type definition '"
                        <> patch.source_module
                        <> "."
                        <> patch.source_type
                        <> "' was not found",
                      )
                  }
              },
            )
            let next_t_map =
              t_map
              |> dict.insert(#(patch.source_module, patch.source_type), #(
                target_mod.module_name,
                target_td.name,
                target_mod.package_name,
              ))
              |> dict.insert(
                #(
                  patch.source_module,
                  mangle.mangle_type_name(patch.source_type),
                ),
                #(
                  target_mod.module_name,
                  target_td.name,
                  target_mod.package_name,
                ),
              )
            let #(next_c_map, next_tr) = case source_def {
              SourceTypeDef(sd) -> {
                let cm =
                  list.fold(sd.variants, c_map, fn(m, v) {
                    dict.insert(m, #(patch.source_module, v.name), #(
                      target_mod.module_name,
                      v.name,
                    ))
                  })
                let tr2 =
                  SplicedTracker(
                    ..tr,
                    spliced_type_defs: set.insert(tr.spliced_type_defs, #(
                      patch.source_module,
                      sd.name,
                    )),
                  )
                #(cm, tr2)
              }
              SourceTypeAlias(sa) -> {
                let tr2 =
                  SplicedTracker(
                    ..tr,
                    spliced_type_aliases: set.insert(tr.spliced_type_aliases, #(
                      patch.source_module,
                      sa.name,
                    )),
                  )
                #(c_map, tr2)
              }
            }
            let rp =
              ResolvedTypePatch(
                key:,
                source_mod:,
                source_def:,
                target_mod_name: target_mod.module_name,
                target_td:,
              )
            Ok(#([rp, ..r_acc], next_t_map, next_c_map, next_tr))
          },
        ),
      )

      let patch_maps =
        PatchMaps(
          mirrors_by_mod:,
          type_patch_map:,
          type_patch_ctor_map: type_ctor_map,
          mods_by_name:,
        )
      let indices =
        dict.map_values(mods_by_name, fn(_k, m) { build_mod_index(m) })
      let by_target =
        list.fold(list.reverse(resolved_list), dict.new(), fn(acc, rp) {
          let existing = dict.get(acc, rp.target_mod_name) |> result.unwrap([])
          dict.insert(acc, rp.target_mod_name, [rp, ..existing])
        })

      use #(rev_mods, next_table) <- result.try(
        list.try_fold(ir_modules, #([], table), fn(acc, mod) {
          let #(mods_acc, cur_table) = acc
          case dict.get(by_target, mod.module_name) {
            Error(_) -> Ok(#([mod, ..mods_acc], cur_table))
            Ok(rps) -> {
              use #(updated_mod, updated_table) <- result.try(
                apply_type_patches_to_module(
                  mod,
                  list.reverse(rps),
                  indices,
                  patch_maps,
                  cur_table,
                ),
              )
              Ok(#([updated_mod, ..mods_acc], updated_table))
            }
          }
        }),
      )
      Ok(#(
        list.reverse(rev_mods),
        next_table,
        type_patch_map,
        type_ctor_map,
        tracker0,
      ))
    }
  }
}

fn apply_type_patches_to_module(
  target_mod: IrModule,
  patches: List(ResolvedTypePatch),
  indices: Dict(String, ModIndex),
  patch_maps: PatchMaps,
  table: symbol_table.SymbolTable,
) -> Result(#(IrModule, symbol_table.SymbolTable), String) {
  list.try_fold(patches, #(target_mod, table), fn(acc, rp) {
    let #(cur_mod, cur_table) = acc
    let src_idx =
      dict.get(indices, rp.source_mod.module_name)
      |> result.unwrap(build_mod_index(rp.source_mod))
    let src_imports_target =
      rp.source_mod.module_name != cur_mod.module_name
      && list.any(rp.source_mod.imports, fn(imp) {
        imp.module == cur_mod.module_name
      })

    case rp.source_def {
      SourceTypeAlias(sa) -> {
        use _ <- result.try(
          case
            list.length(sa.type_params) == list.length(rp.target_td.type_params)
          {
            True -> Ok(Nil)
            False ->
              Error(
                "Gleam @patch_type type parameter count mismatch on '"
                <> rp.key
                <> "'",
              )
          },
        )
        use _ <- result.try(case src_imports_target {
          False -> Ok(Nil)
          True ->
            check_local_type_in_type(
              sa.aliased,
              rp.source_mod.module_name,
              src_idx,
              cur_mod.module_name,
              patch_maps,
            )
        })
        case detect_direct_external_alias(sa, patch_maps.mods_by_name) {
          Some(ext) -> {
            let new_types =
              list.map(cur_mod.types, fn(td) {
                case td.name == rp.target_td.name {
                  True -> IrTypeDef(..td, external_type: Some(ext))
                  False -> td
                }
              })
            let updated_table =
              update_table_type_external(
                cur_table,
                cur_mod.module_name,
                rp.target_td.unmangled_name,
                Some(ext),
              )
            Ok(#(IrModule(..cur_mod, types: new_types), updated_table))
          }
          None -> {
            let rewritten_aliased =
              rewrite_ir_type(
                sa.aliased,
                rp.source_mod,
                cur_mod.module_name,
                patch_maps,
              )
            let new_types =
              list.filter(cur_mod.types, fn(td) { td.name != rp.target_td.name })
            let new_alias =
              IrTypeAlias(
                name: rp.target_td.name,
                publicity: rp.target_td.publicity,
                type_params: sa.type_params,
                aliased: rewritten_aliased,
              )
            let new_aliases = list.append(cur_mod.type_aliases, [new_alias])
            Ok(#(
              IrModule(..cur_mod, types: new_types, type_aliases: new_aliases),
              cur_table,
            ))
          }
        }
      }
      SourceTypeDef(sd) -> {
        use _ <- result.try(
          case
            list.length(sd.type_params) == list.length(rp.target_td.type_params)
          {
            True -> Ok(Nil)
            False ->
              Error(
                "Gleam @patch_type type parameter count mismatch on '"
                <> rp.key
                <> "'",
              )
          },
        )
        let other_ctors =
          list.fold(cur_mod.types, set.new(), fn(s, td) {
            case td.name == rp.target_td.name {
              True -> s
              False ->
                list.fold(td.variants, s, fn(inner, v) {
                  set.insert(inner, v.name)
                })
            }
          })
        use _ <- result.try(
          list.try_each(sd.variants, fn(v) {
            use _ <- result.try(case set.contains(other_ctors, v.name) {
              True ->
                Error(
                  "Gleam @patch_type constructor '"
                  <> v.name
                  <> "' for '"
                  <> rp.key
                  <> "' collides with an existing constructor in '"
                  <> cur_mod.module_name
                  <> "'",
                )
              False -> Ok(Nil)
            })
            list.try_each(v.fields, fn(fld) {
              case src_imports_target {
                False -> Ok(Nil)
                True ->
                  check_local_type_in_type(
                    fld.field_type,
                    rp.source_mod.module_name,
                    src_idx,
                    cur_mod.module_name,
                    patch_maps,
                  )
              }
            })
          }),
        )
        let rewritten_variants =
          list.map(sd.variants, fn(v) {
            IrVariant(
              name: v.name,
              fields: list.map(v.fields, fn(fld) {
                IrVariantField(
                  label: fld.label,
                  unmangled_label: fld.unmangled_label,
                  field_type: rewrite_ir_type(
                    fld.field_type,
                    rp.source_mod,
                    cur_mod.module_name,
                    patch_maps,
                  ),
                )
              }),
            )
          })
        let spliced_td =
          IrTypeDef(
            name: rp.target_td.name,
            unmangled_name: rp.target_td.unmangled_name,
            publicity: rp.target_td.publicity,
            opaque_: rp.target_td.opaque_,
            type_params: sd.type_params,
            variants: rewritten_variants,
            external_type: sd.external_type,
            derive_eq_debug_hash: sd.derive_eq_debug_hash,
          )
        let new_types =
          list.map(cur_mod.types, fn(td) {
            case td.name == rp.target_td.name {
              True -> spliced_td
              False -> td
            }
          })
        let copied_getters =
          list.filter_map(rp.source_mod.getters, fn(g) {
            case g.type_name == sd.name {
              False -> Error(Nil)
              True ->
                Ok(IrGetter(
                  type_name: rp.target_td.name,
                  type_params: sd.type_params,
                  publicity: rp.target_td.publicity,
                  field_name: g.field_name,
                  return_type: rewrite_ir_type(
                    g.return_type,
                    rp.source_mod,
                    cur_mod.module_name,
                    patch_maps,
                  ),
                  variants: g.variants,
                ))
            }
          })
        let updated_table =
          copy_table_type_def(
            cur_table,
            rp.source_mod.module_name,
            sd,
            cur_mod.module_name,
            rp.target_td,
          )
        Ok(#(
          IrModule(
            ..cur_mod,
            types: new_types,
            getters: list.append(cur_mod.getters, copied_getters),
          ),
          updated_table,
        ))
      }
    }
  })
}

fn detect_direct_external_alias(
  sa: IrTypeAlias,
  mods_by_name: Dict(String, IrModule),
) -> Option(prepass.ExternalType) {
  case sa.aliased {
    IrTypeNamed(module:, name:, args:, ..) -> {
      let expected_vars = list.map(sa.type_params, fn(tp) { IrTypeVar(tp) })
      case args == expected_vars {
        False -> None
        True ->
          case dict.get(mods_by_name, module) {
            Error(_) -> None
            Ok(ext_mod) ->
              case find_ir_type(ext_mod, name) {
                Some(td) if td.variants == [] ->
                  case
                    list.length(td.type_params) == list.length(sa.type_params)
                  {
                    True -> td.external_type
                    False -> None
                  }
                _ -> None
              }
          }
      }
    }
    _ -> None
  }
}

fn update_table_type_external(
  table: symbol_table.SymbolTable,
  mod_name: String,
  type_unmangled: String,
  ext: Option(prepass.ExternalType),
) -> symbol_table.SymbolTable {
  case dict.get(table.modules, mod_name) {
    Error(_) -> table
    Ok(ms) ->
      case dict.get(ms.types, type_unmangled) {
        Error(_) -> table
        Ok(ti) -> {
          let next_ti = symbol_table.TypeInfo(..ti, external_type: ext)
          let next_ms =
            symbol_table.ModuleSymbols(
              ..ms,
              types: dict.insert(ms.types, type_unmangled, next_ti),
            )
          symbol_table.SymbolTable(
            ..table,
            modules: dict.insert(table.modules, mod_name, next_ms),
          )
        }
      }
  }
}

fn copy_table_type_def(
  table: symbol_table.SymbolTable,
  src_mod: String,
  src_td: IrTypeDef,
  tgt_mod: String,
  tgt_td: IrTypeDef,
) -> symbol_table.SymbolTable {
  case dict.get(table.modules, src_mod), dict.get(table.modules, tgt_mod) {
    Ok(ms_src), Ok(ms_tgt) ->
      case dict.get(ms_src.types, src_td.unmangled_name) {
        Error(_) ->
          update_table_type_external(
            table,
            tgt_mod,
            tgt_td.unmangled_name,
            src_td.external_type,
          )
        Ok(src_ti) -> {
          let next_ti =
            symbol_table.TypeInfo(
              ..src_ti,
              module: tgt_mod,
              name: tgt_td.unmangled_name,
              publicity: tgt_td.publicity,
              opaque_: tgt_td.opaque_,
            )
          let next_ctors =
            list.fold(src_td.variants, ms_tgt.constructors, fn(c_acc, v) {
              case dict.get(ms_src.constructors, v.name) {
                Ok(ci) ->
                  dict.insert(
                    c_acc,
                    v.name,
                    ConstructorInfo(
                      ..ci,
                      module: tgt_mod,
                      type_name: tgt_td.unmangled_name,
                    ),
                  )
                Error(_) -> c_acc
              }
            })
          let next_ms =
            symbol_table.ModuleSymbols(
              ..ms_tgt,
              types: dict.insert(ms_tgt.types, tgt_td.unmangled_name, next_ti),
              constructors: next_ctors,
            )
          symbol_table.SymbolTable(
            ..table,
            modules: dict.insert(table.modules, tgt_mod, next_ms),
          )
        }
      }
    _, _ -> table
  }
}

// -----------------------------------------------------------------------------
// Phase 4: Reject any remaining references to @patch_mirror modules
// -----------------------------------------------------------------------------

fn validate_no_stray_mirror_refs(
  modules: List(IrModule),
  mirrors: Dict(String, MirrorMap),
) -> Result(Nil, String) {
  case dict.is_empty(mirrors) {
    True -> Ok(Nil)
    False ->
      list.try_each(modules, fn(mod) {
        use _ <- result.try(
          list.try_each(mod.types, fn(td) {
            list.try_each(td.variants, fn(v) {
              list.try_each(v.fields, fn(fld) {
                check_type_no_mirror(fld.field_type, mod.module_name, mirrors)
              })
            })
          }),
        )
        use _ <- result.try(
          list.try_each(mod.type_aliases, fn(ta) {
            check_type_no_mirror(ta.aliased, mod.module_name, mirrors)
          }),
        )
        use _ <- result.try(
          list.try_each(mod.getters, fn(g) {
            check_type_no_mirror(g.return_type, mod.module_name, mirrors)
          }),
        )
        use _ <- result.try(
          list.try_each(mod.constants, fn(c) {
            use _ <- result.try(check_type_no_mirror(
              c.value_type,
              mod.module_name,
              mirrors,
            ))
            check_expr_no_mirror(c.value, mod.module_name, mirrors)
          }),
        )
        list.try_each(mod.functions, fn(f) {
          use _ <- result.try(
            list.try_each(f.params, fn(p) {
              check_type_no_mirror(p.param_type, mod.module_name, mirrors)
            }),
          )
          use _ <- result.try(check_type_no_mirror(
            f.return_type,
            mod.module_name,
            mirrors,
          ))
          check_stmts_no_mirror(f.body, mod.module_name, mirrors)
        })
      })
  }
}

fn stray_mirror_error(
  cur_mod: String,
  mirror_mod: String,
  mm: MirrorMap,
) -> String {
  "Module '"
  <> cur_mod
  <> "' references @patch_mirror module '"
  <> mirror_mod
  <> "' outside of a @patch targeting '"
  <> mm.target_mod_name
  <> "'"
}

fn check_type_no_mirror(
  ty: IrType,
  cur_mod: String,
  mirrors: Dict(String, MirrorMap),
) -> Result(Nil, String) {
  case ty {
    IrTypeList(inner) -> check_type_no_mirror(inner, cur_mod, mirrors)
    IrTypeResult(ok:, err:) -> {
      use _ <- result.try(check_type_no_mirror(ok, cur_mod, mirrors))
      check_type_no_mirror(err, cur_mod, mirrors)
    }
    IrTypeTuple(els) ->
      list.try_each(els, check_type_no_mirror(_, cur_mod, mirrors))
    IrTypeFn(params:, return:) -> {
      use _ <- result.try(
        list.try_each(params, check_type_no_mirror(_, cur_mod, mirrors)),
      )
      check_type_no_mirror(return, cur_mod, mirrors)
    }
    IrTypeNamed(module:, args:, ..) -> {
      use _ <- result.try(case dict.get(mirrors, module) {
        Ok(mm) -> Error(stray_mirror_error(cur_mod, module, mm))
        Error(_) -> Ok(Nil)
      })
      list.try_each(args, check_type_no_mirror(_, cur_mod, mirrors))
    }
    _ -> Ok(Nil)
  }
}

fn check_stmts_no_mirror(
  stmts: List(IrStmt),
  cur_mod: String,
  mirrors: Dict(String, MirrorMap),
) -> Result(Nil, String) {
  list.try_each(stmts, fn(stmt) {
    case stmt {
      IrStmtLet(pattern:, annotation:, value:) -> {
        use _ <- result.try(check_pattern_no_mirror(pattern, cur_mod, mirrors))
        use _ <- result.try(case annotation {
          Some(t) -> check_type_no_mirror(t, cur_mod, mirrors)
          None -> Ok(Nil)
        })
        check_expr_no_mirror(value, cur_mod, mirrors)
      }
      IrStmtGuard(
        value:,
        pattern:,
        guard_condition:,
        abort_message:,
        post_bindings:,
      ) -> {
        use _ <- result.try(check_expr_no_mirror(value, cur_mod, mirrors))
        use _ <- result.try(check_pattern_no_mirror(pattern, cur_mod, mirrors))
        use _ <- result.try(case guard_condition {
          Some(g) -> check_expr_no_mirror(g, cur_mod, mirrors)
          None -> Ok(Nil)
        })
        use _ <- result.try(case abort_message {
          Some(m) -> check_expr_no_mirror(m, cur_mod, mirrors)
          None -> Ok(Nil)
        })
        list.try_each(post_bindings, fn(pb) {
          check_expr_no_mirror(pb.1, cur_mod, mirrors)
        })
      }
      IrStmtAssert(condition:, abort_message:) -> {
        use _ <- result.try(check_expr_no_mirror(condition, cur_mod, mirrors))
        case abort_message {
          Some(m) -> check_expr_no_mirror(m, cur_mod, mirrors)
          None -> Ok(Nil)
        }
      }
      IrStmtExpr(e) -> check_expr_no_mirror(e, cur_mod, mirrors)
    }
  })
}

fn check_expr_no_mirror(
  expr: IrExpr,
  cur_mod: String,
  mirrors: Dict(String, MirrorMap),
) -> Result(Nil, String) {
  case expr {
    IrModuleRef(target_module:, ..) ->
      case dict.get(mirrors, target_module) {
        Ok(mm) -> Error(stray_mirror_error(cur_mod, target_module, mm))
        Error(_) -> Ok(Nil)
      }
    IrConstructor(target_module: Some(m), ..) ->
      case dict.get(mirrors, m) {
        Ok(mm) -> Error(stray_mirror_error(cur_mod, m, mm))
        Error(_) -> Ok(Nil)
      }
    IrTuple(els) | IrContinue(els) ->
      list.try_each(els, check_expr_no_mirror(_, cur_mod, mirrors))
    IrTupleIndex(tuple:, ..)
    | IrNegateInt(tuple)
    | IrNegateBool(tuple)
    | IrBreak(tuple)
    | IrGetterCall(receiver: tuple, ..) ->
      check_expr_no_mirror(tuple, cur_mod, mirrors)
    IrList(elements:, tail:) -> {
      use _ <- result.try(
        list.try_each(elements, check_expr_no_mirror(_, cur_mod, mirrors)),
      )
      case tail {
        Some(t) -> check_expr_no_mirror(t, cur_mod, mirrors)
        None -> Ok(Nil)
      }
    }
    IrBitString(segments:) ->
      list.try_each(segments, fn(seg) {
        check_expr_no_mirror(seg.0, cur_mod, mirrors)
      })
    IrBinOp(left:, right:, ..) -> {
      use _ <- result.try(check_expr_no_mirror(left, cur_mod, mirrors))
      check_expr_no_mirror(right, cur_mod, mirrors)
    }
    IrCall(function:, args:) -> {
      use _ <- result.try(check_expr_no_mirror(function, cur_mod, mirrors))
      list.try_each(args, fn(a) {
        check_expr_no_mirror(a.value, cur_mod, mirrors)
      })
    }
    IrBlock(stmts) -> check_stmts_no_mirror(stmts, cur_mod, mirrors)
    IrFn(params:, return_type:, body:) -> {
      use _ <- result.try(
        list.try_each(params, fn(p) {
          case p.param_type {
            Some(t) -> check_type_no_mirror(t, cur_mod, mirrors)
            None -> Ok(Nil)
          }
        }),
      )
      use _ <- result.try(case return_type {
        Some(r) -> check_type_no_mirror(r, cur_mod, mirrors)
        None -> Ok(Nil)
      })
      check_stmts_no_mirror(body, cur_mod, mirrors)
    }
    IrForLoop(bindings:, body:) -> {
      use _ <- result.try(
        list.try_each(bindings, fn(b) {
          check_expr_no_mirror(b.1, cur_mod, mirrors)
        }),
      )
      check_stmts_no_mirror(body, cur_mod, mirrors)
    }
    IrMatch(subjects:, clauses:) -> {
      use _ <- result.try(
        list.try_each(subjects, check_expr_no_mirror(_, cur_mod, mirrors)),
      )
      list.try_each(clauses, fn(c) {
        use _ <- result.try(
          list.try_each(c.patterns, fn(alt) {
            list.try_each(alt, check_pattern_no_mirror(_, cur_mod, mirrors))
          }),
        )
        use _ <- result.try(case c.guard {
          Some(g) -> check_expr_no_mirror(g, cur_mod, mirrors)
          None -> Ok(Nil)
        })
        use _ <- result.try(
          list.try_each(c.prefix_bindings, fn(pb) {
            check_expr_no_mirror(pb.1, cur_mod, mirrors)
          }),
        )
        check_expr_no_mirror(c.body, cur_mod, mirrors)
      })
    }
    IrEcho(expr: inner, message:, ..) -> {
      use _ <- result.try(check_expr_no_mirror(inner, cur_mod, mirrors))
      case message {
        Some(m) -> check_expr_no_mirror(m, cur_mod, mirrors)
        None -> Ok(Nil)
      }
    }
    IrAbort(message:, ..) ->
      case message {
        Some(m) -> check_expr_no_mirror(m, cur_mod, mirrors)
        None -> Ok(Nil)
      }
    _ -> Ok(Nil)
  }
}

fn check_pattern_no_mirror(
  pat: IrPattern,
  cur_mod: String,
  mirrors: Dict(String, MirrorMap),
) -> Result(Nil, String) {
  case pat {
    IrPatTuple(els) ->
      list.try_each(els, check_pattern_no_mirror(_, cur_mod, mirrors))
    IrPatAs(inner, _) -> check_pattern_no_mirror(inner, cur_mod, mirrors)
    IrPatVariant(target_module:, args:, ..) -> {
      use _ <- result.try(case target_module {
        Some(m) ->
          case dict.get(mirrors, m) {
            Ok(mm) -> Error(stray_mirror_error(cur_mod, m, mm))
            Error(_) -> Ok(Nil)
          }
        None -> Ok(Nil)
      })
      list.try_each(args, fn(a) {
        check_pattern_no_mirror(a.pattern, cur_mod, mirrors)
      })
    }
    IrPatBitString(segments:) ->
      list.try_each(segments, fn(seg) {
        check_pattern_no_mirror(seg.0, cur_mod, mirrors)
      })
    _ -> Ok(Nil)
  }
}
