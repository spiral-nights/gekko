import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import index/symbol_table.{type SymbolTable, ConstructorInfo}
import lower/gleam_patch_rewrite.{check_local_type_in_type, rewrite_ir_type}
import lower/gleam_patch_types.{
  type MirrorMap, type ModIndex, type PatchMaps, type SplicedTracker, PatchMaps,
  SplicedTracker, build_mod_index, find_ir_alias, find_ir_type,
}
import lower/ir.{
  type IrModule, type IrTypeAlias, type IrTypeDef, IrGetter, IrModule,
  IrTypeAlias, IrTypeDef, IrTypeNamed, IrTypeVar, IrVariant, IrVariantField,
}
import lower/mangle
import project/prepass.{type GleamTypePatch}

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

pub fn splice_all_type_patches(
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
  table: SymbolTable,
) -> Result(#(IrModule, SymbolTable), String) {
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
  table: SymbolTable,
  mod_name: String,
  type_unmangled: String,
  ext: Option(prepass.ExternalType),
) -> SymbolTable {
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
  table: SymbolTable,
  src_mod: String,
  src_td: IrTypeDef,
  tgt_mod: String,
  tgt_td: IrTypeDef,
) -> SymbolTable {
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
