import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import lower/ir.{
  type IrConstant, type IrFunction, type IrModule, type IrType, type IrTypeAlias,
  type IrTypeDef, IrTypeBitArray, IrTypeBool, IrTypeDouble, IrTypeFn,
  IrTypeInt64, IrTypeList, IrTypeNamed, IrTypeResult, IrTypeString, IrTypeTuple,
  IrTypeUnit, IrTypeVar,
}
import lower/ir_util
import lower/mangle
import project/prepass

pub type ModIndex {
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

pub type SplicedTracker {
  SplicedTracker(
    /// `(source_module, mangled_fn_name)` entries that were spliced as `@patch`.
    spliced_fns: Set(#(String, String)),
    /// `(source_module, ir_type_name)` entries that were spliced as `@patch_type`.
    spliced_type_defs: Set(#(String, String)),
    /// `(source_module, ir_alias_name)` entries that were spliced as `@patch_type`.
    spliced_type_aliases: Set(#(String, String)),
  )
}

pub type TypeBijection {
  TypeBijection(s_to_t: Dict(String, String), t_to_s: Dict(String, String))
}

pub type MirrorMap {
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

pub type PatchMaps {
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

pub type CollectedItems {
  CollectedItems(
    fn_names: List(String),
    const_names: List(String),
    visited_fns: Set(String),
    visited_consts: Set(String),
  )
}

pub fn build_mod_index(mod: IrModule) -> ModIndex {
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

pub fn build_alias_map(
  ir_modules: List(IrModule),
) -> Dict(#(String, String), IrTypeAlias) {
  list.fold(ir_modules, dict.new(), fn(acc, mod) {
    list.fold(mod.type_aliases, acc, fn(inner, ta) {
      dict.insert(inner, #(mod.module_name, ta.name), ta)
    })
  })
}

pub fn find_ir_type(mod: IrModule, name: String) -> Option(IrTypeDef) {
  let mangled = mangle.mangle_type_name(name)
  list.find(mod.types, fn(td) {
    td.unmangled_name == name || td.name == name || td.name == mangled
  })
  |> option.from_result
}

pub fn find_ir_alias(mod: IrModule, name: String) -> Option(IrTypeAlias) {
  let mangled = mangle.mangle_type_name(name)
  list.find(mod.type_aliases, fn(ta) { ta.name == name || ta.name == mangled })
  |> option.from_result
}

pub fn find_ir_fn(mod: IrModule, name: String) -> Option(IrFunction) {
  let mangled = mangle.mangle_ident(name)
  list.find(mod.functions, fn(f) {
    f.unmangled_name == name || f.name == name || f.name == mangled
  })
  |> option.from_result
}

pub fn find_ir_const(mod: IrModule, name: String) -> Option(IrConstant) {
  let mangled = mangle.mangle_ident(name)
  list.find(mod.constants, fn(c) {
    c.unmangled_name == name || c.name == name || c.name == mangled
  })
  |> option.from_result
}

pub fn is_patched_local_type_for_target(
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

pub fn is_patched_local_ctor_for_target(
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

// -----------------------------------------------------------------------------
// Signature checking (parameter count, types, return type, type var bijection)
// -----------------------------------------------------------------------------

pub fn validate_patch_signature(
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

pub fn normalize_type_for_patch(
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
  let rec = canonicalize_external_types(_, mods_by_name)
  case ty {
    IrTypeNamed(module_alias:, package:, module:, name:, args:) -> {
      let norm_args = list.map(args, rec)
      case dict.get(mods_by_name, module) {
        Error(_) ->
          IrTypeNamed(module_alias:, package:, module:, name:, args: norm_args)
        Ok(m) ->
          case find_ir_type(m, name) {
            option.Some(td) ->
              case td.external_type {
                option.Some(prepass.ExternalType(
                  package: ext_pkg,
                  type_name: ext_ty,
                )) -> {
                  let norm_pkg = case ext_pkg {
                    "" | "builtin" -> "moonbitlang/core/builtin"
                    other -> other
                  }
                  case norm_pkg, ext_ty, norm_args {
                    "moonbitlang/core/builtin", "String", []
                    | "moonbitlang/core/builtin", "StringView", []
                    -> IrTypeString
                    "moonbitlang/core/builtin", "Int64", [] -> IrTypeInt64
                    "moonbitlang/core/builtin", "Double", [] -> IrTypeDouble
                    "moonbitlang/core/builtin", "Bool", [] -> IrTypeBool
                    "moonbitlang/core/builtin", "Unit", [] -> IrTypeUnit
                    _, _, _ ->
                      IrTypeNamed(
                        module_alias: option.None,
                        package: "",
                        module: "__external__:" <> norm_pkg,
                        name: ext_ty,
                        args: norm_args,
                      )
                  }
                }
                option.None ->
                  IrTypeNamed(
                    module_alias:,
                    package:,
                    module:,
                    name:,
                    args: norm_args,
                  )
              }
            option.None ->
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
    _ -> ir_util.map_type_children(ty, rec)
  }
}

fn remap_type_for_patch_compare(
  ty: IrType,
  cur_mod: String,
  target_mod_name: String,
  patch_maps: PatchMaps,
) -> IrType {
  let rec = remap_type_for_patch_compare(
    _,
    cur_mod,
    target_mod_name,
    patch_maps,
  )
  case ty {
    IrTypeNamed(module_alias:, package:, module:, name:, args:) -> {
      let resolved_mod = case module {
        "" -> cur_mod
        m -> m
      }
      let new_args = list.map(args, rec)
      case dict.get(patch_maps.mirrors_by_mod, resolved_mod) {
        Ok(mm) if mm.target_mod_name == target_mod_name ->
          case dict.get(mm.type_map, name) {
            Ok(target_name) ->
              IrTypeNamed(
                module_alias: option.None,
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
                module_alias: option.None,
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
    _ -> ir_util.map_type_children(ty, rec)
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
  let rec = normalize_type_loop(_, cur_mod, all_aliases, visited)
  case ty {
    IrTypeNamed(module_alias:, package:, module:, name:, args:) -> {
      let resolved_mod = case module {
        "" -> cur_mod
        m -> m
      }
      let norm_args = list.map(args, rec)
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
    _ -> ir_util.map_type_children(ty, rec)
  }
}

fn subst_type(ty: IrType, subst: Dict(String, IrType)) -> IrType {
  case ty {
    IrTypeVar(v) -> dict.get(subst, v) |> result.unwrap(ty)
    _ -> ir_util.map_type_children(ty, subst_type(_, subst))
  }
}

pub fn unify_sig_types(
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

pub fn format_ir_type(ty: IrType) -> String {
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
