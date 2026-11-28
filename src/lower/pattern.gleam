import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import index/symbol_table.{type SymbolTable}
import lower/bit_pattern
import lower/ir.{
  type IrExpr, type IrPattern, IrBool, IrPatArg, IrPatAs, IrPatBitString,
  IrPatBool, IrPatDiscard, IrPatFloat, IrPatInt, IrPatString, IrPatStringPrefix,
  IrPatTuple, IrPatUnit, IrPatVar, IrPatVariant, IrString, IrVar,
}
import lower/mangle

/// Result of lowering a Gleam `glance.Pattern` along with any synthetic
/// string-prefix guards/bindings and newly bound local variable names.
pub type LoweredPattern {
  LoweredPattern(
    pattern: IrPattern,
    guards: List(IrExpr),
    prefix_bindings: List(#(String, IrExpr)),
    bound_names: List(String),
    is_synthetic_root: Bool,
    next_id: Int,
  )
}

/// Lower a `glance.Pattern` into an `IrPattern`, extracting synthetic prefix
/// checks (`"pre" <> rest`), expanding shorthand variant fields, and converting
/// list patterns (`[h, ..t]`) into `@prelude.Cons` / `@prelude.Nil`.
pub fn lower_pattern(
  pattern: glance.Pattern,
  table: SymbolTable,
  current_module: String,
  next_id: Int,
) -> LoweredPattern {
  case pattern {
    glance.PatternInt(value:, ..) ->
      LoweredPattern(
        pattern: IrPatInt(value),
        guards: [],
        prefix_bindings: [],
        bound_names: [],
        is_synthetic_root: False,
        next_id:,
      )

    glance.PatternFloat(value:, ..) ->
      LoweredPattern(
        pattern: IrPatFloat(value),
        guards: [],
        prefix_bindings: [],
        bound_names: [],
        is_synthetic_root: False,
        next_id:,
      )

    glance.PatternString(value:, ..) ->
      LoweredPattern(
        pattern: IrPatString(value),
        guards: [],
        prefix_bindings: [],
        bound_names: [],
        is_synthetic_root: False,
        next_id:,
      )

    glance.PatternDiscard(..) ->
      LoweredPattern(
        pattern: IrPatDiscard,
        guards: [],
        prefix_bindings: [],
        bound_names: [],
        is_synthetic_root: False,
        next_id:,
      )

    glance.PatternVariable(name:, ..) -> {
      let mangled = mangle.mangle_ident(name)
      LoweredPattern(
        pattern: IrPatVar(mangled),
        guards: [],
        prefix_bindings: [],
        bound_names: [name],
        is_synthetic_root: False,
        next_id:,
      )
    }

    glance.PatternTuple(elements:, ..) -> {
      let #(rev_pats, guards, bindings, names, cur_id) =
        lower_pattern_list(elements, table, current_module, next_id)
      LoweredPattern(
        pattern: IrPatTuple(list.reverse(rev_pats)),
        guards:,
        prefix_bindings: bindings,
        bound_names: names,
        is_synthetic_root: False,
        next_id: cur_id,
      )
    }

    glance.PatternList(elements:, tail:, ..) -> {
      let #(tail_pat, guards, bindings, names, cur_id) = case tail {
        None -> #(
          IrPatVariant(Some("gprelude"), None, "Nil", [], False),
          [],
          [],
          [],
          next_id,
        )
        Some(t) -> {
          let lt = lower_pattern(t, table, current_module, next_id)
          #(
            lt.pattern,
            lt.guards,
            lt.prefix_bindings,
            lt.bound_names,
            lt.next_id,
          )
        }
      }

      let #(rev_els, el_guards, el_bindings, el_names, final_id) =
        lower_pattern_list(elements, table, current_module, cur_id)

      let list_pat =
        list.fold(rev_els, tail_pat, fn(acc_tail, el_pat) {
          IrPatVariant(
            module_alias: Some("gprelude"),
            target_module: None,
            constructor: "Cons",
            args: [IrPatArg(None, el_pat), IrPatArg(None, acc_tail)],
            with_spread: False,
          )
        })

      LoweredPattern(
        pattern: list_pat,
        guards: list.append(el_guards, guards),
        prefix_bindings: list.append(el_bindings, bindings),
        bound_names: list.append(el_names, names),
        is_synthetic_root: False,
        next_id: final_id,
      )
    }

    glance.PatternAssignment(pattern: inner, name:, ..) -> {
      let lowered = lower_pattern(inner, table, current_module, next_id)
      let mangled = mangle.mangle_ident(name)
      case lowered.pattern, lowered.is_synthetic_root {
        IrPatVar(existing), True ->
          LoweredPattern(
            pattern: IrPatVar(existing),
            guards: lowered.guards,
            prefix_bindings: [
              #(mangled, IrVar(existing)),
              ..lowered.prefix_bindings
            ],
            bound_names: [name, ..lowered.bound_names],
            is_synthetic_root: True,
            next_id: lowered.next_id,
          )
        _, _ ->
          LoweredPattern(
            pattern: IrPatAs(lowered.pattern, mangled),
            guards: lowered.guards,
            prefix_bindings: lowered.prefix_bindings,
            bound_names: [name, ..lowered.bound_names],
            is_synthetic_root: lowered.is_synthetic_root,
            next_id: lowered.next_id,
          )
      }
    }

    glance.PatternConcatenate(prefix:, prefix_name:, rest_name:, ..) -> {
      let #(pfx_bindings, pfx_names) = case prefix_name {
        Some(glance.Named(p_name)) -> #(
          [#(mangle.mangle_ident(p_name), IrString(prefix))],
          [p_name],
        )
        Some(glance.Discarded(_)) | None -> #([], [])
      }

      let #(rest_opt, rest_names) = case rest_name {
        glance.Named(r_name) -> #(Some(mangle.mangle_ident(r_name)), [r_name])
        glance.Discarded(_) -> #(None, [])
      }

      // Lower empty prefix directly to the rest binding (or discard) so
      // fallback arms don't trigger MoonBit's [0012] unreachable-code warning.
      let pat = case prefix {
        "" ->
          case rest_opt {
            Some(mangled_r) -> IrPatVar(mangled_r)
            None -> IrPatDiscard
          }
        _ -> IrPatStringPrefix(prefix:, rest: rest_opt)
      }

      LoweredPattern(
        pattern: pat,
        guards: [],
        prefix_bindings: pfx_bindings,
        bound_names: list.append(pfx_names, rest_names),
        is_synthetic_root: False,
        next_id:,
      )
    }

    glance.PatternBitString(segments:, ..) ->
      lower_bit_string_pattern(segments, next_id)

    glance.PatternVariant(module:, constructor:, arguments:, with_spread:, ..) ->
      lower_pattern_variant(
        module,
        constructor,
        arguments,
        with_spread,
        table,
        current_module,
        next_id,
      )
  }
}

fn lower_pattern_variant(
  module: Option(String),
  constructor: String,
  arguments: List(glance.Field(glance.Pattern)),
  with_spread: Bool,
  table: SymbolTable,
  current_module: String,
  next_id: Int,
) -> LoweredPattern {
  let shadowed_builtin =
    module == None
    && {
      constructor == "True" || constructor == "False" || constructor == "Nil"
    }
    && arguments == []
    && symbol_table.lookup_constructor(table, current_module, None, constructor)
    == None
  case shadowed_builtin, constructor {
    True, "True" -> LoweredPattern(IrPatBool(True), [], [], [], False, next_id)
    True, "False" ->
      LoweredPattern(IrPatBool(False), [], [], [], False, next_id)
    True, "Nil" -> LoweredPattern(IrPatUnit, [], [], [], False, next_id)
    _, _ -> {
      let #(rev_args, guards, bindings, names, cur_id) =
        list.fold(arguments, #([], [], [], [], next_id), fn(acc, field) {
          let #(args_acc, g_acc, b_acc, n_acc, id_acc) = acc
          case field {
            glance.UnlabelledField(item:) -> {
              let lp = lower_pattern(item, table, current_module, id_acc)
              #(
                [IrPatArg(None, lp.pattern), ..args_acc],
                list.append(g_acc, lp.guards),
                list.append(b_acc, lp.prefix_bindings),
                list.append(n_acc, lp.bound_names),
                lp.next_id,
              )
            }
            glance.LabelledField(label:, item:, ..) -> {
              let lp = lower_pattern(item, table, current_module, id_acc)
              #(
                [
                  IrPatArg(Some(mangle.mangle_ident(label)), lp.pattern),
                  ..args_acc
                ],
                list.append(g_acc, lp.guards),
                list.append(b_acc, lp.prefix_bindings),
                list.append(n_acc, lp.bound_names),
                lp.next_id,
              )
            }
            glance.ShorthandField(label:, ..) -> {
              let mangled = mangle.mangle_ident(label)
              #(
                [IrPatArg(Some(mangled), IrPatVar(mangled)), ..args_acc],
                g_acc,
                b_acc,
                [label, ..n_acc],
                id_acc,
              )
            }
          }
        })

      let #(mod_alias, target_mod, ctor_name) =
        resolve_variant_constructor(module, constructor, table, current_module)

      LoweredPattern(
        pattern: IrPatVariant(
          module_alias: mod_alias,
          target_module: target_mod,
          constructor: ctor_name,
          args: list.reverse(rev_args),
          with_spread:,
        ),
        guards:,
        prefix_bindings: bindings,
        bound_names: names,
        is_synthetic_root: False,
        next_id: cur_id,
      )
    }
  }
}

fn resolve_variant_constructor(
  qualifier: Option(String),
  constructor: String,
  table: SymbolTable,
  current_module: String,
) -> #(Option(String), Option(String), String) {
  case
    symbol_table.lookup_constructor(
      table,
      current_module,
      qualifier,
      constructor,
    )
  {
    Some(ctor) ->
      case ctor.module == current_module {
        True -> #(None, None, ctor.variant_name)
        False -> {
          let alias =
            resolve_alias_for_module(
              table,
              current_module,
              ctor.module,
              qualifier,
            )
          #(alias, Some(ctor.module), ctor.variant_name)
        }
      }
    None ->
      case qualifier, constructor {
        None, "Ok" -> #(None, None, "Ok")
        None, "Error" -> #(None, None, "Err")
        _, _ -> #(qualifier, None, constructor)
      }
  }
}

fn resolve_alias_for_module(
  table: SymbolTable,
  current_module: String,
  target_module: String,
  fallback_qualifier: Option(String),
) -> Option(String) {
  case fallback_qualifier {
    Some(_) -> fallback_qualifier
    None ->
      case dict.get(table.modules, current_module) {
        Ok(mod_syms) -> {
          let found =
            list.find(mod_syms.imports, fn(imp) { imp.module == target_module })
          case found {
            Ok(imp) ->
              case imp.alias {
                Some(a) -> Some(a)
                None -> Some(mangle.module_to_alias(target_module))
              }
            Error(_) -> Some(mangle.module_to_alias(target_module))
          }
        }
        Error(_) -> Some(mangle.module_to_alias(target_module))
      }
  }
}

fn lower_pattern_list(
  patterns: List(glance.Pattern),
  table: SymbolTable,
  current_module: String,
  next_id: Int,
) -> #(
  List(IrPattern),
  List(IrExpr),
  List(#(String, IrExpr)),
  List(String),
  Int,
) {
  list.fold(patterns, #([], [], [], [], next_id), fn(acc, p) {
    let #(pats_acc, g_acc, b_acc, n_acc, id_acc) = acc
    let lp = lower_pattern(p, table, current_module, id_acc)
    #(
      [lp.pattern, ..pats_acc],
      list.append(g_acc, lp.guards),
      list.append(b_acc, lp.prefix_bindings),
      list.append(n_acc, lp.bound_names),
      lp.next_id,
    )
  })
}

fn lower_bit_string_pattern(
  segments: List(
    #(glance.Pattern, List(glance.BitStringSegmentOption(glance.BitArraySize))),
  ),
  next_id: Int,
) -> LoweredPattern {
  case segments {
    [] ->
      LoweredPattern(
        pattern: IrPatBitString([]),
        guards: [],
        prefix_bindings: [],
        bound_names: [],
        is_synthetic_root: False,
        next_id:,
      )
    [#(glance.PatternDiscard(..), opts)] ->
      case is_trivial_catch_all_bits(opts) {
        True ->
          LoweredPattern(
            pattern: IrPatDiscard,
            guards: [],
            prefix_bindings: [],
            bound_names: [],
            is_synthetic_root: False,
            next_id:,
          )
        False -> lower_non_empty_bit_string(segments, next_id)
      }
    [#(glance.PatternVariable(name:, ..), opts)] ->
      case is_trivial_catch_all_bits(opts) {
        True ->
          LoweredPattern(
            pattern: IrPatVar(mangle.mangle_ident(name)),
            guards: [],
            prefix_bindings: [],
            bound_names: [name],
            is_synthetic_root: False,
            next_id:,
          )
        False -> lower_non_empty_bit_string(segments, next_id)
      }
    _ -> lower_non_empty_bit_string(segments, next_id)
  }
}

fn is_trivial_catch_all_bits(
  opts: List(glance.BitStringSegmentOption(glance.BitArraySize)),
) -> Bool {
  list.contains(opts, glance.BitsOption)
  && !list.any(opts, fn(o) {
    case o {
      glance.BytesOption
      | glance.SizeOption(_)
      | glance.SizeValueOption(_)
      | glance.Utf8Option
      | glance.Utf16Option
      | glance.Utf32Option
      | glance.Utf8CodepointOption
      | glance.Utf16CodepointOption
      | glance.Utf32CodepointOption
      | glance.FloatOption
      | glance.IntOption -> True
      _ -> False
    }
  })
}

fn lower_non_empty_bit_string(
  segments: List(
    #(glance.Pattern, List(glance.BitStringSegmentOption(glance.BitArraySize))),
  ),
  next_id: Int,
) -> LoweredPattern {
  let synth_var = "__bits_" <> int.to_string(next_id)
  let #(guard_opt, bindings, names, final_id) =
    bit_pattern.lower_bit_string_for_subject(synth_var, segments, next_id + 1)
  let guards = case guard_opt {
    None -> []
    Some(IrBool(True)) -> []
    Some(g) -> [g]
  }
  LoweredPattern(
    pattern: IrPatVar(synth_var),
    guards:,
    prefix_bindings: bindings,
    bound_names: names,
    is_synthetic_root: True,
    next_id: final_id,
  )
}
