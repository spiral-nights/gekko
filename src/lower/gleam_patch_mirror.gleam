import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import lower/gleam_patch_types.{
  type MirrorMap, MirrorMap, PatchMaps, TypeBijection, find_ir_alias,
  find_ir_const, find_ir_fn, find_ir_type, normalize_type_for_patch,
  unify_sig_types,
}
import lower/ir.{
  type IrModule, type IrType, type IrTypeAlias, IrConstructor, IrModuleRef,
  IrPatVariant, IrTypeNamed,
}
import lower/ir_util
import lower/mangle
import project/prepass.{
  type MirrorDeclEntry, type PatchMirrorInfo, MirrorConst, MirrorFn,
  MirrorFromPublic, MirrorOpaque, MirrorToPublic, MirrorType,
}

// -----------------------------------------------------------------------------
// Phase 1: Validate @patch_mirror modules and construct MirrorMaps
// -----------------------------------------------------------------------------

pub fn validate_and_build_mirrors(
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
// Phase 4: Reject any remaining references to @patch_mirror modules
// -----------------------------------------------------------------------------

pub fn validate_no_stray_mirror_refs(
  modules: List(IrModule),
  mirrors: Dict(String, MirrorMap),
) -> Result(Nil, String) {
  case dict.is_empty(mirrors) {
    True -> Ok(Nil)
    False ->
      list.try_each(modules, fn(mod) {
        let cur_mod = mod.module_name
        let check_ty = fn(ty) {
          ir_util.try_fold_type(ty, Nil, fn(_, t) {
            case t {
              IrTypeNamed(module:, ..) ->
                check_mirror_mod(cur_mod, module, mirrors)
              _ -> Ok(Nil)
            }
          })
        }
        let visitor =
          ir_util.IrVisitor(
            ..ir_util.default_visitor(),
            on_type: fn(_, t) {
              case t {
                IrTypeNamed(module:, ..) ->
                  check_mirror_mod(cur_mod, module, mirrors)
                _ -> Ok(Nil)
              }
            },
            on_expr: fn(_, e) {
              case e {
                IrModuleRef(target_module:, ..)
                | IrConstructor(target_module: Some(target_module), ..) ->
                  check_mirror_mod(cur_mod, target_module, mirrors)
                _ -> Ok(Nil)
              }
            },
            on_pattern: fn(_, p) {
              case p {
                IrPatVariant(target_module: Some(target_module), ..) ->
                  check_mirror_mod(cur_mod, target_module, mirrors)
                _ -> Ok(Nil)
              }
            },
          )
        use _ <- result.try(
          list.try_each(mod.types, fn(td) {
            list.try_each(td.variants, fn(v) {
              list.try_each(v.fields, fn(fld) { check_ty(fld.field_type) })
            })
          }),
        )
        use _ <- result.try(
          list.try_each(mod.type_aliases, fn(ta) { check_ty(ta.aliased) }),
        )
        use _ <- result.try(
          list.try_each(mod.getters, fn(g) { check_ty(g.return_type) }),
        )
        use _ <- result.try(
          list.try_each(mod.constants, fn(c) {
            use _ <- result.try(check_ty(c.value_type))
            ir_util.try_fold_expr(c.value, Nil, visitor)
          }),
        )
        list.try_each(mod.functions, fn(f) {
          use _ <- result.try(
            list.try_each(f.params, fn(p) { check_ty(p.param_type) }),
          )
          use _ <- result.try(check_ty(f.return_type))
          ir_util.try_fold_stmts(f.body, Nil, visitor)
        })
      })
  }
}

fn check_mirror_mod(
  cur_mod: String,
  target_mod: String,
  mirrors: Dict(String, MirrorMap),
) -> Result(Nil, String) {
  case dict.get(mirrors, target_mod) {
    Ok(mm) -> Error(stray_mirror_error(cur_mod, target_mod, mm))
    Error(_) -> Ok(Nil)
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
