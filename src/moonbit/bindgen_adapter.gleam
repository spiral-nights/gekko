import common/gleam_ident
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import moonbit/mbti.{
  type MbtiConst, type MbtiFnDecl, type MbtiPackage, type MbtiParam,
  type MbtiType, type MbtiTypeDecl, MbtiEnum, MbtiNamed, MbtiStruct,
}

pub type TypeConv {
  Direct
  NarrowInt32
  NarrowUInt32
  NarrowInt16
  NarrowUInt16
  NarrowByte
  ReinterpretUInt64
  Float32
  StringConv
  CharConv
  BytesConv
  BytesViewConv
  ArrayConv(TypeConv)
  ArrayViewConv(TypeConv)
  FixedArrayConv(TypeConv)
  MapConv(TypeConv, TypeConv)
  OptionConv(TypeConv)
  ResultConv(TypeConv, TypeConv)
  TupleConv(List(TypeConv))
  FnConv(List(TypeConv), TypeConv)
}

pub type BindOptions {
  BindOptions(
    only: List(String),
    map_types: Dict(String, #(String, String)),
    typed_errors: Bool,
    adapter_name: Option(String),
  )
}

pub fn default_bind_options() -> BindOptions {
  BindOptions(
    only: [],
    map_types: dict.new(),
    typed_errors: False,
    adapter_name: None,
  )
}

pub type ResolvedTypeSpec {
  ResolvedTypeSpec(
    gleam_ty: String,
    adapter_ty: String,
    mbt_ty: String,
    conv: TypeConv,
    needs_option: Bool,
    needs_gprelude: Bool,
    needs_float_pkg: Bool,
    needs_int16_pkg: Bool,
    used_external_types: Dict(String, ExternalTypeRef),
    mapped_imports: Set(#(String, String)),
    extra_pkgs: Dict(String, String),
  )
}

pub type ExternalTypeRef {
  ExternalTypeRef(
    gleam_name: String,
    pkg_path: String,
    mbt_name: String,
    arity: Int,
  )
}

pub type BindContext {
  BindContext(
    mbti: MbtiPackage,
    project_name: String,
    target_alias: String,
    adapter_pkg_name: String,
    local_type_arities: Dict(String, Int),
    import_alias_to_pkg: Dict(String, String),
    options: BindOptions,
  )
}

pub type EmittedFn {
  EmittedFn(
    gleam_stub: String,
    adapter_fn: Option(String),
    needs_option: Bool,
    needs_gprelude: Bool,
    needs_float_pkg: Bool,
    needs_int16_pkg: Bool,
    needs_debug_pkg: Bool,
    helper_kinds: Set(String),
    ext_types: Dict(String, ExternalTypeRef),
    mapped_imports: Set(#(String, String)),
    extra_imports: Dict(String, String),
  )
}

pub fn is_builtin_pkg(pkg: String) -> Bool {
  pkg == "moonbitlang/core/builtin" || pkg == "builtin" || pkg == ""
}

pub fn target_pkg_prefix(bctx: BindContext) -> String {
  case is_builtin_pkg(bctx.mbti.package_name) {
    True -> ""
    False -> "@" <> bctx.target_alias <> "."
  }
}

pub fn format_bound_for_adapter(bound: String) -> #(String, Bool, Bool) {
  case bound {
    "ToDynamic" | "@gprelude.ToDynamic" -> #("@gprelude.ToDynamic", True, False)
    "GleamInspect" | "@gprelude.GleamInspect" -> #(
      "@gprelude.GleamInspect",
      True,
      False,
    )
    "Debug" | "@debug.Debug" -> #("@debug.Debug", False, True)
    _ -> #(bound, False, False)
  }
}

pub fn build_adapter_fn(
  bctx: BindContext,
  f: MbtiFnDecl,
  gleam_name: String,
  fn_type_params: List(#(String, List(String))),
  param_names: List(String),
  resolved_params: List(#(MbtiParam, ResolvedTypeSpec)),
  resolved_ret: ResolvedTypeSpec,
  resolved_err: Option(ResolvedTypeSpec),
) -> #(
  Option(String),
  Set(String),
  Bool,
  Bool,
  Bool,
  Bool,
  Dict(String, String),
) {
  let #(rev_tp_strs, bound_gprelude, bound_debug) =
    list.fold(fn_type_params, #([], False, False), fn(acc, tp) {
      let #(parts, acc_gp, acc_dbg) = acc
      let #(tp_name, bounds) = tp
      case bounds {
        [] -> #([tp_name, ..parts], acc_gp, acc_dbg)
        _ -> {
          let #(rev_b, gp, dbg) =
            list.fold(bounds, #([], acc_gp, acc_dbg), fn(b_acc, b) {
              let #(bs, g0, d0) = b_acc
              let #(rendered, needs_g, needs_d) = format_bound_for_adapter(b)
              #([rendered, ..bs], g0 || needs_g, d0 || needs_d)
            })
          let tp_str =
            tp_name <> " : " <> string.join(list.reverse(rev_b), " + ")
          #([tp_str, ..parts], gp, dbg)
        }
      }
    })
  let generics = case rev_tp_strs {
    [] -> ""
    _ -> "[" <> string.join(list.reverse(rev_tp_strs), ", ") <> "]"
  }

  let param_sig =
    list.zip(param_names, resolved_params)
    |> list.map(fn(pair) {
      let #(pname, #(_, spec)) = pair
      mangle_moon_ident(pname) <> " : " <> spec.adapter_ty
    })
    |> string.join(", ")

  let ret_sig = case f.raises, resolved_err {
    True, Some(err_spec) ->
      "Result[" <> resolved_ret.adapter_ty <> ", " <> err_spec.adapter_ty <> "]"
    True, None -> "Result[" <> resolved_ret.adapter_ty <> ", StringView]"
    False, _ -> resolved_ret.adapter_ty
  }

  let #(helper_kinds_params, arg_exprs) =
    list.zip(param_names, resolved_params)
    |> list.map_fold(set.new(), fn(hk, pair) {
      let #(pname, #(mbti_p, spec)) = pair
      let m_pname = mangle_moon_ident(pname)
      let #(val_expr, hk1) = expr_to_mbt(spec.conv, m_pname, hk, 0)
      let formatted = case mbti_p.label {
        None -> val_expr
        Some(lbl) ->
          case mbti_p.is_optional {
            True -> lbl <> "?=" <> val_expr
            False -> lbl <> "=" <> val_expr
          }
      }
      #(hk1, formatted)
    })

  let pfx = target_pkg_prefix(bctx)
  let free_pfx = case is_builtin_pkg(bctx.mbti.package_name) {
    True -> "@prelude."
    False -> pfx
  }
  let callee = case f.owner_type {
    Some(owner) if owner == f.name -> pfx <> owner
    Some(owner) -> pfx <> owner <> "::" <> f.name
    None -> free_pfx <> f.name
  }
  let raw_call = callee <> "(" <> string.join(arg_exprs, ", ") <> ")"

  let #(body, helper_kinds) = case f.raises, resolved_err {
    False, _ -> {
      let #(ret_expr, hk_final) =
        expr_from_mbt(resolved_ret.conv, raw_call, helper_kinds_params, 0)
      #("  " <> ret_expr, hk_final)
    }
    True, Some(err_spec) -> {
      let #(ok_expr, hk1) =
        expr_from_mbt(resolved_ret.conv, "__res", helper_kinds_params, 0)
      let #(err_expr, hk_final) = expr_from_mbt(err_spec.conv, "__err", hk1, 0)
      let body_str =
        "  try {\n    let __res = "
        <> raw_call
        <> "\n    Ok("
        <> ok_expr
        <> ")\n  } catch {\n    __err => Err("
        <> err_expr
        <> ")\n  }"
      #(body_str, hk_final)
    }
    True, None -> {
      let #(ok_expr, hk_final) =
        expr_from_mbt(resolved_ret.conv, "__res", helper_kinds_params, 0)
      let body_str =
        "  try {\n    let __res = "
        <> raw_call
        <> "\n    Ok("
        <> ok_expr
        <> ")\n  } catch {\n    __err => Err((Error::to_string(__err)).to_string_view())\n  }"
      #(body_str, hk_final)
    }
  }

  let err_specs = case resolved_err {
    Some(e) -> [e]
    None -> []
  }
  let all_specs = [
    resolved_ret,
    ..list.append(list.map(resolved_params, fn(rp) { rp.1 }), err_specs)
  ]

  let needs_gprelude =
    bound_gprelude
    || bctx.mbti.package_name == "gprelude"
    || list.any(all_specs, fn(s) { s.needs_gprelude })
  let needs_float = list.any(all_specs, fn(s) { s.needs_float_pkg })
  let needs_int16 = list.any(all_specs, fn(s) { s.needs_int16_pkg })
  let needs_debug = bound_debug

  let extra_imports = specs_extra_imports(bctx, all_specs)

  let mbt_fn =
    "///|\npub fn"
    <> generics
    <> " "
    <> mangle_moon_ident(gleam_name)
    <> "("
    <> param_sig
    <> ") -> "
    <> ret_sig
    <> " {\n"
    <> body
    <> "\n}"

  #(
    Some(mbt_fn),
    helper_kinds,
    needs_gprelude,
    needs_float,
    needs_int16,
    needs_debug,
    extra_imports,
  )
}

pub fn expr_to_mbt(
  conv: TypeConv,
  expr: String,
  helpers: Set(String),
  depth: Int,
) -> #(String, Set(String)) {
  case conv {
    Direct -> #(expr, helpers)
    NarrowInt32 -> #("__to_int32(" <> expr <> ")", set.insert(helpers, "int32"))
    NarrowUInt32 -> #(
      "__to_uint32(" <> expr <> ")",
      set.insert(helpers, "uint32"),
    )
    NarrowInt16 -> #("__to_int16(" <> expr <> ")", set.insert(helpers, "int16"))
    NarrowUInt16 -> #(
      "__to_uint16(" <> expr <> ")",
      set.insert(helpers, "uint16"),
    )
    NarrowByte -> #("__to_byte(" <> expr <> ")", set.insert(helpers, "byte"))
    ReinterpretUInt64 -> #("(" <> expr <> ").reinterpret_as_uint64()", helpers)
    Float32 -> #("@float.Float::from_double(" <> expr <> ")", helpers)
    StringConv -> #("(" <> expr <> ").to_owned()", helpers)
    CharConv -> #("__to_char(" <> expr <> ")", set.insert(helpers, "char"))
    BytesConv -> #("(" <> expr <> ").data", helpers)
    BytesViewConv -> #("(" <> expr <> ").data[:]", helpers)

    ArrayConv(Direct) -> #("(" <> expr <> ").to_array()", helpers)
    ArrayConv(inner) -> {
      let v = "x" <> int.to_string(depth)
      let #(inner_e, h1) = expr_to_mbt(inner, v, helpers, depth + 1)
      #(
        "(" <> expr <> ").to_array().map(fn(" <> v <> ") { " <> inner_e <> " })",
        h1,
      )
    }

    ArrayViewConv(Direct) -> #("(" <> expr <> ").to_array()[:]", helpers)
    ArrayViewConv(inner) -> {
      let v = "x" <> int.to_string(depth)
      let #(inner_e, h1) = expr_to_mbt(inner, v, helpers, depth + 1)
      #(
        "("
          <> expr
          <> ").to_array().map(fn("
          <> v
          <> ") { "
          <> inner_e
          <> " })[:]",
        h1,
      )
    }

    FixedArrayConv(Direct) -> #(
      "FixedArray::from_array((" <> expr <> ").to_array()[:])",
      helpers,
    )
    FixedArrayConv(inner) -> {
      let v = "x" <> int.to_string(depth)
      let #(inner_e, h1) = expr_to_mbt(inner, v, helpers, depth + 1)
      #(
        "FixedArray::from_array(("
          <> expr
          <> ").to_array().map(fn("
          <> v
          <> ") { "
          <> inner_e
          <> " })[:])",
        h1,
      )
    }

    MapConv(k_c, v_c) ->
      case k_c == Direct && v_c == Direct {
        True -> #(expr, helpers)
        False -> {
          let kv = "mk" <> int.to_string(depth)
          let vv = "mv" <> int.to_string(depth)
          let m_var = "map" <> int.to_string(depth)
          let #(k_e, h1) = expr_to_mbt(k_c, kv, helpers, depth + 1)
          let #(v_e, h2) = expr_to_mbt(v_c, vv, h1, depth + 1)
          #(
            "{ let "
              <> m_var
              <> " = Map([]); ("
              <> expr
              <> ").each(fn("
              <> kv
              <> ", "
              <> vv
              <> ") { "
              <> m_var
              <> "["
              <> k_e
              <> "] = "
              <> v_e
              <> " }); "
              <> m_var
              <> " }",
            h2,
          )
        }
      }

    OptionConv(inner) ->
      case inner {
        Direct -> #(expr, helpers)
        _ -> {
          let v = "x" <> int.to_string(depth)
          let #(inner_e, h1) = expr_to_mbt(inner, v, helpers, depth + 1)
          #("(" <> expr <> ").map(fn(" <> v <> ") { " <> inner_e <> " })", h1)
        }
      }

    ResultConv(Direct, Direct) -> #(expr, helpers)
    ResultConv(ok_c, err_c) -> {
      let ok_v = "ok_v" <> int.to_string(depth)
      let err_v = "err_v" <> int.to_string(depth)
      let #(ok_e, h1) = expr_to_mbt(ok_c, ok_v, helpers, depth + 1)
      let #(err_e, h2) = expr_to_mbt(err_c, err_v, h1, depth + 1)
      #(
        "match "
          <> expr
          <> " { Ok("
          <> ok_v
          <> ") => Ok("
          <> ok_e
          <> "); Err("
          <> err_v
          <> ") => Err("
          <> err_e
          <> ") }",
        h2,
      )
    }

    TupleConv(els) ->
      case list.all(els, fn(c) { c == Direct }) {
        True -> #(expr, helpers)
        False -> {
          let #(h1, binds_and_exprs) =
            list.index_map(els, fn(c, i) { #(c, i) })
            |> list.map_fold(helpers, fn(acc_h, pair) {
              let v =
                "t" <> int.to_string(depth) <> "_" <> int.to_string(pair.1)
              let #(ce, next_h) = expr_to_mbt(pair.0, v, acc_h, depth + 1)
              #(next_h, #(v, ce))
            })
          let pat =
            "("
            <> {
              list.map(binds_and_exprs, fn(p) { p.0 })
              |> string.join(", ")
            }
            <> ")"
          let out =
            "("
            <> {
              list.map(binds_and_exprs, fn(p) { p.1 })
              |> string.join(", ")
            }
            <> ")"
          #("{ let " <> pat <> " = " <> expr <> "; " <> out <> " }", h1)
        }
      }

    FnConv(p_convs, r_conv) ->
      case r_conv == Direct && list.all(p_convs, fn(c) { c == Direct }) {
        True -> #(expr, helpers)
        False -> {
          let #(h1, params_and_args) =
            list.index_map(p_convs, fn(c, i) { #(c, i) })
            |> list.map_fold(helpers, fn(acc_h, pair) {
              let pname =
                "cb" <> int.to_string(depth) <> "_" <> int.to_string(pair.1)
              let #(arg_e, next_h) =
                expr_from_mbt(pair.0, pname, acc_h, depth + 1)
              #(next_h, #(pname, arg_e))
            })
          let raw_call =
            "("
            <> expr
            <> ")("
            <> {
              list.map(params_and_args, fn(p) { p.1 })
              |> string.join(", ")
            }
            <> ")"
          let #(ret_e, h2) = expr_to_mbt(r_conv, raw_call, h1, depth + 1)
          let pnames =
            list.map(params_and_args, fn(p) { p.0 })
            |> string.join(", ")
          #("fn(" <> pnames <> ") { " <> ret_e <> " }", h2)
        }
      }
  }
}

pub fn expr_from_mbt(
  conv: TypeConv,
  expr: String,
  helpers: Set(String),
  depth: Int,
) -> #(String, Set(String)) {
  case conv {
    Direct -> #(expr, helpers)
    NarrowInt32 | NarrowUInt32 | NarrowUInt16 | NarrowByte -> #(
      "(" <> expr <> ").to_int64()",
      helpers,
    )
    NarrowInt16 -> #("@int16.Int16::to_int64(" <> expr <> ")", helpers)
    ReinterpretUInt64 -> #("(" <> expr <> ").reinterpret_as_int64()", helpers)
    Float32 -> #("@float.Float::to_double(" <> expr <> ")", helpers)
    StringConv -> #("(" <> expr <> ").to_string_view()", helpers)
    CharConv -> #("(" <> expr <> ").to_string().to_string_view()", helpers)
    BytesConv -> #("@gprelude.BitArray::from_bytes(" <> expr <> ")", helpers)
    BytesViewConv -> #(
      "@gprelude.BitArray::from_bytes((" <> expr <> ").to_bytes())",
      helpers,
    )

    ArrayConv(Direct) -> #(
      "@gprelude.GList::from_array((" <> expr <> ")[:])",
      helpers,
    )
    ArrayConv(inner) -> {
      let v = "x" <> int.to_string(depth)
      let #(inner_e, h1) = expr_from_mbt(inner, v, helpers, depth + 1)
      #(
        "@gprelude.GList::from_array(("
          <> expr
          <> ").map(fn("
          <> v
          <> ") { "
          <> inner_e
          <> " })[:])",
        h1,
      )
    }

    ArrayViewConv(Direct) -> #(
      "@gprelude.GList::from_array(" <> expr <> ")",
      helpers,
    )
    ArrayViewConv(inner) -> {
      let v = "x" <> int.to_string(depth)
      let #(inner_e, h1) = expr_from_mbt(inner, v, helpers, depth + 1)
      #(
        "@gprelude.GList::from_array(("
          <> expr
          <> ").map(fn("
          <> v
          <> ") { "
          <> inner_e
          <> " })[:])",
        h1,
      )
    }

    FixedArrayConv(Direct) -> #(
      "@gprelude.GList::from_array((" <> expr <> ").iter().to_array()[:])",
      helpers,
    )
    FixedArrayConv(inner) -> {
      let v = "x" <> int.to_string(depth)
      let #(inner_e, h1) = expr_from_mbt(inner, v, helpers, depth + 1)
      #(
        "@gprelude.GList::from_array(("
          <> expr
          <> ").iter().map(fn("
          <> v
          <> ") { "
          <> inner_e
          <> " }).to_array()[:])",
        h1,
      )
    }

    MapConv(k_c, v_c) ->
      case k_c == Direct && v_c == Direct {
        True -> #(expr, helpers)
        False -> {
          let kv = "mk" <> int.to_string(depth)
          let vv = "mv" <> int.to_string(depth)
          let m_var = "map" <> int.to_string(depth)
          let #(k_e, h1) = expr_from_mbt(k_c, kv, helpers, depth + 1)
          let #(v_e, h2) = expr_from_mbt(v_c, vv, h1, depth + 1)
          #(
            "{ let "
              <> m_var
              <> " = Map([]); ("
              <> expr
              <> ").each(fn("
              <> kv
              <> ", "
              <> vv
              <> ") { "
              <> m_var
              <> "["
              <> k_e
              <> "] = "
              <> v_e
              <> " }); "
              <> m_var
              <> " }",
            h2,
          )
        }
      }

    OptionConv(inner) ->
      case inner {
        Direct -> #(expr, helpers)
        _ -> {
          let v = "x" <> int.to_string(depth)
          let #(inner_e, h1) = expr_from_mbt(inner, v, helpers, depth + 1)
          #("(" <> expr <> ").map(fn(" <> v <> ") { " <> inner_e <> " })", h1)
        }
      }

    ResultConv(Direct, Direct) -> #(expr, helpers)
    ResultConv(ok_c, err_c) -> {
      let ok_v = "ok_v" <> int.to_string(depth)
      let err_v = "err_v" <> int.to_string(depth)
      let #(ok_e, h1) = expr_from_mbt(ok_c, ok_v, helpers, depth + 1)
      let #(err_e, h2) = expr_from_mbt(err_c, err_v, h1, depth + 1)
      #(
        "match "
          <> expr
          <> " { Ok("
          <> ok_v
          <> ") => Ok("
          <> ok_e
          <> "); Err("
          <> err_v
          <> ") => Err("
          <> err_e
          <> ") }",
        h2,
      )
    }

    TupleConv(els) ->
      case list.all(els, fn(c) { c == Direct }) {
        True -> #(expr, helpers)
        False -> {
          let #(h1, binds_and_exprs) =
            list.index_map(els, fn(c, i) { #(c, i) })
            |> list.map_fold(helpers, fn(acc_h, pair) {
              let v =
                "t" <> int.to_string(depth) <> "_" <> int.to_string(pair.1)
              let #(ce, next_h) = expr_from_mbt(pair.0, v, acc_h, depth + 1)
              #(next_h, #(v, ce))
            })
          let pat =
            "("
            <> {
              list.map(binds_and_exprs, fn(p) { p.0 })
              |> string.join(", ")
            }
            <> ")"
          let out =
            "("
            <> {
              list.map(binds_and_exprs, fn(p) { p.1 })
              |> string.join(", ")
            }
            <> ")"
          #("{ let " <> pat <> " = " <> expr <> "; " <> out <> " }", h1)
        }
      }

    FnConv(p_convs, r_conv) ->
      case r_conv == Direct && list.all(p_convs, fn(c) { c == Direct }) {
        True -> #(expr, helpers)
        False -> {
          let #(h1, params_and_args) =
            list.index_map(p_convs, fn(c, i) { #(c, i) })
            |> list.map_fold(helpers, fn(acc_h, pair) {
              let pname =
                "cb" <> int.to_string(depth) <> "_" <> int.to_string(pair.1)
              let #(arg_e, next_h) =
                expr_to_mbt(pair.0, pname, acc_h, depth + 1)
              #(next_h, #(pname, arg_e))
            })
          let raw_call =
            "("
            <> expr
            <> ")("
            <> {
              list.map(params_and_args, fn(p) { p.1 })
              |> string.join(", ")
            }
            <> ")"
          let #(ret_e, h2) = expr_from_mbt(r_conv, raw_call, h1, depth + 1)
          let pnames =
            list.map(params_and_args, fn(p) { p.0 })
            |> string.join(", ")
          #("fn(" <> pnames <> ") { " <> ret_e <> " }", h2)
        }
      }
  }
}

pub fn generate_const_items(
  bctx: BindContext,
  consts: List(MbtiConst),
  used_names: Set(String),
  resolve_type: fn(BindContext, MbtiType, Dict(String, String)) ->
    Result(ResolvedTypeSpec, String),
) -> #(List(EmittedFn), List(#(String, String)), Set(String)) {
  let #(rev_items, rev_skipped, next_used) =
    list.fold(consts, #([], [], used_names), fn(acc, c) {
      let #(items, skipped, used) = acc
      case c.is_deprecated {
        True -> #(items, [#(c.name, "deprecated"), ..skipped], used)
        False ->
          case resolve_type(bctx, c.const_type, dict.new()) {
            Error(reason) -> #(items, [#(c.name, reason), ..skipped], used)
            Ok(spec) -> {
              let gleam_name =
                pick_unique_gleam_name(to_snake_case(c.name), used)
              let next_u = set.insert(used, gleam_name)
              let gleam_stub =
                "/// @external(moonbit, \""
                <> bctx.adapter_pkg_name
                <> "\", \""
                <> gleam_name
                <> "\")\n"
                <> "pub fn "
                <> gleam_name
                <> "() -> "
                <> spec.gleam_ty
                <> " {\n  panic as \"Implemented in MoonBit\"\n}"
              let const_pfx = case is_builtin_pkg(bctx.mbti.package_name) {
                True -> "@prelude."
                False -> target_pkg_prefix(bctx)
              }
              let #(ret_e, hk) =
                expr_from_mbt(spec.conv, const_pfx <> c.name, set.new(), 0)
              let adapter_fn =
                "///|\npub fn "
                <> mangle_moon_ident(gleam_name)
                <> "() -> "
                <> spec.adapter_ty
                <> " {\n  "
                <> ret_e
                <> "\n}"
              let item =
                EmittedFn(
                  gleam_stub:,
                  adapter_fn: Some(adapter_fn),
                  needs_option: spec.needs_option,
                  needs_gprelude: spec.needs_gprelude
                    || bctx.mbti.package_name == "gprelude",
                  needs_float_pkg: spec.needs_float_pkg,
                  needs_int16_pkg: spec.needs_int16_pkg,
                  needs_debug_pkg: False,
                  helper_kinds: hk,
                  ext_types: spec.used_external_types,
                  mapped_imports: spec.mapped_imports,
                  extra_imports: specs_extra_imports(bctx, [spec]),
                )
              #([item, ..items], skipped, next_u)
            }
          }
      }
    })
  #(list.reverse(rev_items), list.reverse(rev_skipped), next_used)
}

pub fn generate_type_helper_items(
  bctx: BindContext,
  types: List(MbtiTypeDecl),
  used_names: Set(String),
  resolve_type: fn(BindContext, MbtiType, Dict(String, String)) ->
    Result(ResolvedTypeSpec, String),
) -> #(List(EmittedFn), List(#(String, String)), Set(String)) {
  let #(rev_items, rev_skipped, next_used) =
    list.fold(types, #([], [], used_names), fn(acc, td) {
      case td.is_deprecated {
        True -> acc
        False ->
          case td.kind {
            MbtiStruct(public_all:, fields:, tuple_fields: _) ->
              generate_struct_helpers(
                bctx,
                td,
                public_all,
                fields,
                acc,
                resolve_type,
              )
            MbtiEnum(public_all:, is_suberror: _, variants:) -> {
              let acc_ctors = case public_all {
                True ->
                  generate_enum_constructors(
                    bctx,
                    td,
                    variants,
                    acc,
                    resolve_type,
                  )
                False -> acc
              }
              case variants {
                [] -> acc_ctors
                _ ->
                  generate_enum_matcher(
                    bctx,
                    td,
                    variants,
                    acc_ctors,
                    resolve_type,
                  )
              }
            }
            _ -> acc
          }
      }
    })
  #(list.reverse(rev_items), list.reverse(rev_skipped), next_used)
}

fn generate_struct_helpers(
  bctx: BindContext,
  td: MbtiTypeDecl,
  public_all: Bool,
  fields: List(mbti.MbtiField),
  acc: #(List(EmittedFn), List(#(String, String)), Set(String)),
  resolve_type: fn(BindContext, MbtiType, Dict(String, String)) ->
    Result(ResolvedTypeSpec, String),
) -> #(List(EmittedFn), List(#(String, String)), Set(String)) {
  let tp_map =
    list.fold(td.type_params, dict.new(), fn(m, tp) {
      dict.insert(m, tp, sanitize_gleam_type_var(tp))
    })
  let owner_ty =
    MbtiNamed(
      None,
      td.name,
      list.map(td.type_params, fn(tp) { MbtiNamed(None, tp, []) }),
    )
  let self_spec_res = resolve_type(bctx, owner_ty, tp_map)

  let acc_after_ctor = case public_all && fields != [], self_spec_res {
    True, Ok(self_spec) -> {
      let #(items, skipped, used) = acc
      let ctor_base = "make_" <> to_snake_case(td.name)
      let resolved_fields =
        list.try_map(fields, fn(fld) {
          use fspec <- result.try(resolve_type(bctx, fld.field_type, tp_map))
          Ok(#(fld, fspec))
        })
      case resolved_fields {
        Error(reason) -> #(items, [#(td.name, reason), ..skipped], used)
        Ok(r_fields) -> {
          let ctor_name = pick_unique_gleam_name(ctor_base, used)
          let next_u = set.insert(used, ctor_name)
          let generics = case td.type_params {
            [] -> ""
            tps -> "[" <> string.join(tps, ", ") <> "]"
          }
          let gleam_params =
            list.map(r_fields, fn(p) {
              escape_gleam_ident(to_snake_case({ p.0 }.name))
              <> ": "
              <> { p.1 }.gleam_ty
            })
            |> string.join(", ")
          let gleam_ignores =
            list.map(r_fields, fn(p) {
              "  let _ = " <> escape_gleam_ident(to_snake_case({ p.0 }.name))
            })
            |> string.join("\n")
          let gleam_stub =
            "/// @external(moonbit, \""
            <> bctx.adapter_pkg_name
            <> "\", \""
            <> ctor_name
            <> "\")\n"
            <> "pub fn "
            <> ctor_name
            <> "("
            <> gleam_params
            <> ") -> "
            <> self_spec.gleam_ty
            <> " {\n"
            <> gleam_ignores
            <> "\n  panic as \"Implemented in MoonBit\"\n}"

          let #(hk, mbt_field_inits) =
            list.map_fold(r_fields, set.new(), fn(acc_hk, p) {
              let fname = { p.0 }.name
              let safe = mangle_moon_ident(to_snake_case(fname))
              let #(val_e, next_hk) = expr_to_mbt({ p.1 }.conv, safe, acc_hk, 0)
              #(next_hk, fname <> ": " <> val_e)
            })
          let adapter_params =
            list.map(r_fields, fn(p) {
              mangle_moon_ident(to_snake_case({ p.0 }.name))
              <> " : "
              <> { p.1 }.adapter_ty
            })
            |> string.join(", ")
          let adapter_fn =
            "///|\npub fn"
            <> generics
            <> " "
            <> mangle_moon_ident(ctor_name)
            <> "("
            <> adapter_params
            <> ") -> "
            <> self_spec.adapter_ty
            <> " {\n  "
            <> target_pkg_prefix(bctx)
            <> td.name
            <> "::{\n    "
            <> string.join(mbt_field_inits, ",\n    ")
            <> ",\n  }\n}"
          let item_specs = [self_spec, ..list.map(r_fields, fn(p) { p.1 })]
          let item_ext_types =
            list.fold(r_fields, self_spec.used_external_types, fn(m, p) {
              dict.merge(m, { p.1 }.used_external_types)
            })
          let item_mapped =
            list.fold(r_fields, self_spec.mapped_imports, fn(m, p) {
              set.union(m, { p.1 }.mapped_imports)
            })
          let item =
            EmittedFn(
              gleam_stub:,
              adapter_fn: Some(adapter_fn),
              needs_option: self_spec.needs_option
                || list.any(r_fields, fn(p) { { p.1 }.needs_option }),
              needs_gprelude: self_spec.needs_gprelude
                || bctx.mbti.package_name == "gprelude"
                || list.any(r_fields, fn(p) { { p.1 }.needs_gprelude }),
              needs_float_pkg: list.any(r_fields, fn(p) {
                { p.1 }.needs_float_pkg
              }),
              needs_int16_pkg: list.any(r_fields, fn(p) {
                { p.1 }.needs_int16_pkg
              }),
              needs_debug_pkg: False,
              helper_kinds: hk,
              ext_types: item_ext_types,
              mapped_imports: item_mapped,
              extra_imports: specs_extra_imports(bctx, item_specs),
            )
          #([item, ..items], skipped, next_u)
        }
      }
    }
    _, _ -> acc
  }

  // Field getters for visible fields
  case self_spec_res {
    Error(_) -> acc_after_ctor
    Ok(self_spec) ->
      list.fold(fields, acc_after_ctor, fn(cur_acc, fld) {
        let #(items, skipped, used) = cur_acc
        case resolve_type(bctx, fld.field_type, tp_map) {
          Error(reason) -> #(
            items,
            [#(td.name <> "." <> fld.name, reason), ..skipped],
            used,
          )
          Ok(fspec) -> {
            let getter_base =
              to_snake_case(td.name) <> "_" <> to_snake_case(fld.name)
            let getter_name = pick_unique_gleam_name(getter_base, used)
            let next_u = set.insert(used, getter_name)
            let generics = case td.type_params {
              [] -> ""
              tps -> "[" <> string.join(tps, ", ") <> "]"
            }
            let gleam_stub =
              "/// @external(moonbit, \""
              <> bctx.adapter_pkg_name
              <> "\", \""
              <> getter_name
              <> "\")\n"
              <> "pub fn "
              <> getter_name
              <> "(self: "
              <> self_spec.gleam_ty
              <> ") -> "
              <> fspec.gleam_ty
              <> " {\n  let _ = self\n  panic as \"Implemented in MoonBit\"\n}"
            let #(ret_e, hk) =
              expr_from_mbt(fspec.conv, "self_." <> fld.name, set.new(), 0)
            let adapter_fn =
              "///|\npub fn"
              <> generics
              <> " "
              <> mangle_moon_ident(getter_name)
              <> "(self_ : "
              <> self_spec.adapter_ty
              <> ") -> "
              <> fspec.adapter_ty
              <> " {\n  "
              <> ret_e
              <> "\n}"
            let getter_ext =
              dict.merge(
                self_spec.used_external_types,
                fspec.used_external_types,
              )
            let getter_mapped =
              set.union(self_spec.mapped_imports, fspec.mapped_imports)
            let item =
              EmittedFn(
                gleam_stub:,
                adapter_fn: Some(adapter_fn),
                needs_option: self_spec.needs_option || fspec.needs_option,
                needs_gprelude: self_spec.needs_gprelude
                  || fspec.needs_gprelude
                  || bctx.mbti.package_name == "gprelude",
                needs_float_pkg: fspec.needs_float_pkg,
                needs_int16_pkg: fspec.needs_int16_pkg,
                needs_debug_pkg: False,
                helper_kinds: hk,
                ext_types: getter_ext,
                mapped_imports: getter_mapped,
                extra_imports: specs_extra_imports(bctx, [self_spec, fspec]),
              )
            #([item, ..items], skipped, next_u)
          }
        }
      })
  }
}

fn generate_enum_constructors(
  bctx: BindContext,
  td: MbtiTypeDecl,
  variants: List(mbti.MbtiVariant),
  acc: #(List(EmittedFn), List(#(String, String)), Set(String)),
  resolve_type: fn(BindContext, MbtiType, Dict(String, String)) ->
    Result(ResolvedTypeSpec, String),
) -> #(List(EmittedFn), List(#(String, String)), Set(String)) {
  let tp_map =
    list.fold(td.type_params, dict.new(), fn(m, tp) {
      dict.insert(m, tp, sanitize_gleam_type_var(tp))
    })
  let owner_ty =
    MbtiNamed(
      None,
      td.name,
      list.map(td.type_params, fn(tp) { MbtiNamed(None, tp, []) }),
    )
  case resolve_type(bctx, owner_ty, tp_map) {
    Error(_) -> acc
    Ok(self_spec) ->
      list.fold(variants, acc, fn(cur_acc, v) {
        let #(items, skipped, used) = cur_acc
        let resolved_params =
          list.try_map(v.params, fn(vp) {
            use spec <- result.try(resolve_type(bctx, vp.1, tp_map))
            Ok(#(vp.0, spec))
          })
        case resolved_params {
          Error(reason) -> #(
            items,
            [#(td.name <> "::" <> v.name, reason), ..skipped],
            used,
          )
          Ok(r_params) -> {
            let fn_base = to_snake_case(td.name) <> "_" <> to_snake_case(v.name)
            let fn_name = pick_unique_gleam_name(fn_base, used)
            let next_u = set.insert(used, fn_name)
            let generics = case td.type_params {
              [] -> ""
              tps -> "[" <> string.join(tps, ", ") <> "]"
            }
            let arg_names =
              list.index_map(r_params, fn(rp, i) {
                case rp.0 {
                  Some(lbl) -> escape_gleam_ident(to_snake_case(lbl))
                  None -> "arg" <> int.to_string(i)
                }
              })
            let gleam_sig =
              list.zip(arg_names, r_params)
              |> list.map(fn(p) { p.0 <> ": " <> p.1.1.gleam_ty })
              |> string.join(", ")
            let gleam_ignores = case arg_names {
              [] -> ""
              _ ->
                {
                  list.map(arg_names, fn(n) { "  let _ = " <> n })
                  |> string.join("\n")
                }
                <> "\n"
            }
            let gleam_stub =
              "/// @external(moonbit, \""
              <> bctx.adapter_pkg_name
              <> "\", \""
              <> fn_name
              <> "\")\n"
              <> "pub fn "
              <> fn_name
              <> "("
              <> gleam_sig
              <> ") -> "
              <> self_spec.gleam_ty
              <> " {\n"
              <> gleam_ignores
              <> "  panic as \"Implemented in MoonBit\"\n}"

            let #(hk, mbt_args) =
              list.zip(arg_names, r_params)
              |> list.map_fold(set.new(), fn(acc_hk, pair) {
                let #(aname, #(lbl_opt, spec)) = pair
                let m_aname = mangle_moon_ident(aname)
                let #(val_e, next_hk) =
                  expr_to_mbt(spec.conv, m_aname, acc_hk, 0)
                let arg_str = case lbl_opt {
                  Some(lbl) -> lbl <> "=" <> val_e
                  None -> val_e
                }
                #(next_hk, arg_str)
              })
            let adapter_params =
              list.zip(arg_names, r_params)
              |> list.map(fn(pair) {
                mangle_moon_ident(pair.0) <> " : " <> pair.1.1.adapter_ty
              })
              |> string.join(", ")
            let pfx = target_pkg_prefix(bctx)
            let call_part = case mbt_args {
              [] -> pfx <> v.name
              _ -> pfx <> v.name <> "(" <> string.join(mbt_args, ", ") <> ")"
            }
            let adapter_fn =
              "///|\npub fn"
              <> generics
              <> " "
              <> mangle_moon_ident(fn_name)
              <> "("
              <> adapter_params
              <> ") -> "
              <> self_spec.adapter_ty
              <> " {\n  "
              <> call_part
              <> "\n}"
            let enum_ext =
              list.fold(r_params, self_spec.used_external_types, fn(m, p) {
                dict.merge(m, { p.1 }.used_external_types)
              })
            let enum_mapped =
              list.fold(r_params, self_spec.mapped_imports, fn(m, p) {
                set.union(m, { p.1 }.mapped_imports)
              })
            let enum_specs = [self_spec, ..list.map(r_params, fn(p) { p.1 })]
            let item =
              EmittedFn(
                gleam_stub:,
                adapter_fn: Some(adapter_fn),
                needs_option: self_spec.needs_option
                  || list.any(r_params, fn(p) { p.1.needs_option }),
                needs_gprelude: self_spec.needs_gprelude
                  || bctx.mbti.package_name == "gprelude"
                  || list.any(r_params, fn(p) { p.1.needs_gprelude }),
                needs_float_pkg: list.any(r_params, fn(p) {
                  p.1.needs_float_pkg
                }),
                needs_int16_pkg: list.any(r_params, fn(p) {
                  p.1.needs_int16_pkg
                }),
                needs_debug_pkg: False,
                helper_kinds: hk,
                ext_types: enum_ext,
                mapped_imports: enum_mapped,
                extra_imports: specs_extra_imports(bctx, enum_specs),
              )
            #([item, ..items], skipped, next_u)
          }
        }
      })
  }
}

fn generate_enum_matcher(
  bctx: BindContext,
  td: MbtiTypeDecl,
  variants: List(mbti.MbtiVariant),
  acc: #(List(EmittedFn), List(#(String, String)), Set(String)),
  resolve_type: fn(BindContext, MbtiType, Dict(String, String)) ->
    Result(ResolvedTypeSpec, String),
) -> #(List(EmittedFn), List(#(String, String)), Set(String)) {
  let tp_map =
    list.fold(td.type_params, dict.new(), fn(m, tp) {
      dict.insert(m, tp, sanitize_gleam_type_var(tp))
    })
  let owner_ty =
    MbtiNamed(
      None,
      td.name,
      list.map(td.type_params, fn(tp) { MbtiNamed(None, tp, []) }),
    )
  case resolve_type(bctx, owner_ty, tp_map) {
    Error(_) -> acc
    Ok(self_spec) -> {
      let #(items, skipped, used) = acc
      let resolved_variants =
        list.try_map(variants, fn(v) {
          use r_params <- result.try(
            list.try_map(v.params, fn(vp) {
              use spec <- result.try(resolve_type(bctx, vp.1, tp_map))
              Ok(#(vp.0, spec))
            }),
          )
          Ok(#(v.name, r_params))
        })
      case resolved_variants {
        Error(reason) -> #(
          items,
          [#("match_" <> td.name, reason), ..skipped],
          used,
        )
        Ok(r_variants) -> {
          let fn_name =
            pick_unique_gleam_name("match_" <> to_snake_case(td.name), used)
          let next_used = set.insert(used, fn_name)
          let gleam_ret_var =
            pick_unique_gleam_name("r", dict.values(tp_map) |> set.from_list)
          let mbt_ret_var =
            pick_unique_type_var("Ret", set.from_list(td.type_params))
          let clean_tps =
            list.map(td.type_params, fn(tp) {
              case string.split_once(tp, ":") {
                Ok(#(nm, _)) -> string.trim(nm)
                Error(_) -> string.trim(tp)
              }
            })
          let generics =
            "["
            <> string.join(list.append(clean_tps, [mbt_ret_var]), ", ")
            <> "]"

          let #(_, rev_handlers) =
            list.fold(r_variants, #(set.from_list(["value"]), []), fn(st, rv) {
              let #(used_p, rev_h) = st
              let h_name =
                pick_unique_gleam_name("on_" <> to_snake_case(rv.0), used_p)
              #(set.insert(used_p, h_name), [#(h_name, rv.0, rv.1), ..rev_h])
            })
          let handlers = list.reverse(rev_handlers)

          let gleam_handler_params =
            list.map(handlers, fn(h) {
              let #(h_name, _, params) = h
              let p_tys =
                list.map(params, fn(p) { { p.1 }.gleam_ty })
                |> string.join(", ")
              h_name <> ": fn(" <> p_tys <> ") -> " <> gleam_ret_var
            })
          let gleam_all_params = [
            "value: " <> self_spec.gleam_ty,
            ..gleam_handler_params
          ]
          let gleam_stub =
            "/// @external(moonbit, \""
            <> bctx.adapter_pkg_name
            <> "\", \""
            <> fn_name
            <> "\")\n"
            <> "pub fn "
            <> fn_name
            <> "("
            <> string.join(gleam_all_params, ", ")
            <> ") -> "
            <> gleam_ret_var
            <> " {\n"
            <> {
              list.map(["value", ..list.map(handlers, fn(h) { h.0 })], fn(pn) {
                "  let _ = " <> pn
              })
              |> string.join("\n")
            }
            <> "\n  panic as \"Implemented in MoonBit\"\n}"

          let adapter_handler_params =
            list.map(handlers, fn(h) {
              let #(h_name, _, params) = h
              let p_tys =
                list.map(params, fn(p) { { p.1 }.adapter_ty })
                |> string.join(", ")
              mangle_moon_ident(h_name)
              <> " : ("
              <> p_tys
              <> ") -> "
              <> mbt_ret_var
            })
          let adapter_all_params = [
            "value : " <> self_spec.adapter_ty,
            ..adapter_handler_params
          ]

          let pfx = target_pkg_prefix(bctx)
          let #(hk, rev_arms) =
            list.fold(handlers, #(set.new(), []), fn(st, h) {
              let #(acc_hk, arms) = st
              let #(h_name, v_name, params) = h
              let #(arm_hk, rev_binds) =
                list.index_fold(params, #(acc_hk, []), fn(pst, p, idx) {
                  let #(cur_hk, binds) = pst
                  let #(lbl_opt, spec) = p
                  let vname = "v" <> int.to_string(idx)
                  let pat_piece = case lbl_opt {
                    Some(lbl) -> lbl <> "=" <> vname
                    None -> vname
                  }
                  let #(arg_e, next_hk) =
                    expr_from_mbt(spec.conv, vname, cur_hk, 0)
                  #(next_hk, [#(pat_piece, arg_e), ..binds])
                })
              let binds = list.reverse(rev_binds)
              let pat_str = case binds {
                [] -> pfx <> v_name
                _ ->
                  pfx
                  <> v_name
                  <> "("
                  <> { list.map(binds, fn(b) { b.0 }) |> string.join(", ") }
                  <> ")"
              }
              let call_args =
                list.map(binds, fn(b) { b.1 }) |> string.join(", ")
              let arm_str =
                "    "
                <> pat_str
                <> " => "
                <> mangle_moon_ident(h_name)
                <> "("
                <> call_args
                <> ")"
              #(arm_hk, [arm_str, ..arms])
            })
          let adapter_fn =
            "///|\npub fn"
            <> generics
            <> " "
            <> mangle_moon_ident(fn_name)
            <> "("
            <> string.join(adapter_all_params, ", ")
            <> ") -> "
            <> mbt_ret_var
            <> " {\n  match value {\n"
            <> string.join(list.reverse(rev_arms), "\n")
            <> "\n  }\n}"

          let all_specs = [
            self_spec,
            ..list.flat_map(handlers, fn(h) { list.map(h.2, fn(p) { p.1 }) })
          ]
          let matcher_ext =
            list.fold(all_specs, dict.new(), fn(m, s) {
              dict.merge(m, s.used_external_types)
            })
          let matcher_mapped =
            list.fold(all_specs, set.new(), fn(m, s) {
              set.union(m, s.mapped_imports)
            })
          let item =
            EmittedFn(
              gleam_stub:,
              adapter_fn: Some(adapter_fn),
              needs_option: list.any(all_specs, fn(s) { s.needs_option }),
              needs_gprelude: bctx.mbti.package_name == "gprelude"
                || list.any(all_specs, fn(s) { s.needs_gprelude }),
              needs_float_pkg: list.any(all_specs, fn(s) { s.needs_float_pkg }),
              needs_int16_pkg: list.any(all_specs, fn(s) { s.needs_int16_pkg }),
              needs_debug_pkg: False,
              helper_kinds: hk,
              ext_types: matcher_ext,
              mapped_imports: matcher_mapped,
              extra_imports: specs_extra_imports(bctx, all_specs),
            )
          #([item, ..items], skipped, next_used)
        }
      }
    }
  }
}

fn pick_unique_type_var(base: String, used: Set(String)) -> String {
  case set.contains(used, base) {
    False -> base
    True -> pick_unique_type_var_loop(base, 2, used)
  }
}

fn pick_unique_type_var_loop(
  base: String,
  idx: Int,
  used: Set(String),
) -> String {
  let candidate = base <> int.to_string(idx)
  case set.contains(used, candidate) {
    False -> candidate
    True -> pick_unique_type_var_loop(base, idx + 1, used)
  }
}

pub fn build_external_type_decls(
  pkg: MbtiPackage,
  used_ext_types: Dict(String, ExternalTypeRef),
) -> List(String) {
  let type_param_names_by_name =
    list.fold(pkg.types, dict.new(), fn(acc, td) {
      dict.insert(acc, td.name, td.type_params)
    })

  used_ext_types
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.map(fn(entry) {
    let ext = entry.1
    let raw_params = case
      ext.pkg_path == pkg.package_name,
      dict.get(type_param_names_by_name, ext.mbt_name)
    {
      True, Ok(tps) if tps != [] -> list.map(tps, sanitize_gleam_type_var)
      _, _ -> int_range_names("t", ext.arity)
    }
    let tp_suffix = case raw_params {
      [] -> ""
      ps -> "(" <> string.join(ps, ", ") <> ")"
    }
    "/// @external_type(moonbit, \""
    <> ext.pkg_path
    <> "\", \""
    <> ext.mbt_name
    <> "\")\n"
    <> "pub type "
    <> ext.gleam_name
    <> tp_suffix
  })
}

pub fn emit_adapter_helpers(helper_kinds: Set(String)) -> List(String) {
  let checks = [
    #(
      "int32",
      "///|\nfn __to_int32(x : Int64) -> Int {\n  if x < -2147483648L || x > 2147483647L {\n    abort(\"Int64 out of Int32 range\")\n  }\n  x.to_int()\n}",
    ),
    #(
      "uint32",
      "///|\nfn __to_uint32(x : Int64) -> UInt {\n  if x < 0L || x > 4294967295L {\n    abort(\"Int64 out of UInt32 range\")\n  }\n  x.reinterpret_as_uint64().to_uint()\n}",
    ),
    #(
      "int16",
      "///|\nfn __to_int16(x : Int64) -> Int16 {\n  if x < -32768L || x > 32767L {\n    abort(\"Int64 out of Int16 range\")\n  }\n  @int16.Int16::from_int64(x)\n}",
    ),
    #(
      "uint16",
      "///|\nfn __to_uint16(x : Int64) -> UInt16 {\n  if x < 0L || x > 65535L {\n    abort(\"Int64 out of UInt16 range\")\n  }\n  x.to_uint16()\n}",
    ),
    #(
      "byte",
      "///|\nfn __to_byte(x : Int64) -> Byte {\n  if x < 0L || x > 255L {\n    abort(\"Int64 out of Byte range\")\n  }\n  x.to_byte()\n}",
    ),
    #(
      "char",
      "///|\nfn __to_char(s : StringView) -> Char {\n  match s.get_char(0) {\n    Some(c) => c\n    None => abort(\"Expected non-empty String for Char\")\n  }\n}",
    ),
  ]

  list.filter_map(checks, fn(entry) {
    case set.contains(helper_kinds, entry.0) {
      True -> Ok(entry.1)
      False -> Error(Nil)
    }
  })
}

pub fn emit_adapter_moon_pkg(
  bctx: BindContext,
  needs_gprelude: Bool,
  needs_float: Bool,
  needs_int16: Bool,
  extra_imports: Dict(String, String),
) -> String {
  emit_adapter_moon_pkg_with_options(
    bctx,
    bctx.project_name <> "/gprelude",
    needs_gprelude,
    needs_float,
    needs_int16,
    False,
    extra_imports,
  )
}

pub fn emit_adapter_moon_pkg_with_prelude(
  bctx: BindContext,
  gprelude_pkg: String,
  needs_gprelude: Bool,
  needs_float: Bool,
  needs_int16: Bool,
  extra_imports: Dict(String, String),
) -> String {
  emit_adapter_moon_pkg_with_options(
    bctx,
    gprelude_pkg,
    needs_gprelude,
    needs_float,
    needs_int16,
    False,
    extra_imports,
  )
}

pub fn emit_adapter_moon_pkg_with_options(
  bctx: BindContext,
  gprelude_pkg: String,
  needs_gprelude: Bool,
  needs_float: Bool,
  needs_int16: Bool,
  needs_debug: Bool,
  extra_imports: Dict(String, String),
) -> String {
  let base = case
    is_builtin_pkg(bctx.mbti.package_name)
    || bctx.mbti.package_name == "gprelude"
  {
    True -> dict.new()
    False ->
      dict.new()
      |> dict.insert(bctx.mbti.package_name, bctx.target_alias)
  }
  let base = case needs_gprelude || bctx.mbti.package_name == "gprelude" {
    True -> dict.insert(base, gprelude_pkg, "gprelude")
    False -> base
  }
  let base = case needs_float {
    True -> dict.insert(base, "moonbitlang/core/float", "float")
    False -> base
  }
  let base = case needs_int16 {
    True -> dict.insert(base, "moonbitlang/core/int16", "int16")
    False -> base
  }
  let base = case needs_debug {
    True -> dict.insert(base, "moonbitlang/core/debug", "debug")
    False -> base
  }
  let clean_extra =
    dict.filter(extra_imports, fn(pkg, _) {
      !is_builtin_pkg(pkg) && pkg != "gprelude"
    })
  let merged = dict.merge(clean_extra, base)
  case dict.is_empty(merged) {
    True -> "warnings = \"-alert_visibility\"\n"
    False -> {
      let entries =
        dict.to_list(merged)
        |> list.sort(fn(a, b) { string.compare(a.1, b.1) })
        |> list.map(fn(p) { "  \"" <> p.0 <> "\" @" <> p.1 <> "," })
        |> string.join("\n")

      "import {\n" <> entries <> "\n}\n\nwarnings = \"-alert_visibility\"\n"
    }
  }
}

pub fn render_gleam_source(
  needs_option: Bool,
  ext_type_decls: List(String),
  fn_stubs: List(String),
  skipped: List(#(String, String)),
) -> String {
  render_gleam_source_with_imports(
    needs_option,
    set.new(),
    ext_type_decls,
    fn_stubs,
    skipped,
  )
}

pub fn render_gleam_source_with_imports(
  needs_option: Bool,
  mapped_imports: Set(#(String, String)),
  ext_type_decls: List(String),
  fn_stubs: List(String),
  skipped: List(#(String, String)),
) -> String {
  let header = "// Generated by `gekko moonbit bind` - DO NOT EDIT."
  let all_type_imports = case needs_option {
    True -> set.insert(mapped_imports, #("gleam/option", "Option"))
    False -> mapped_imports
  }
  let grouped_imports =
    set.fold(all_type_imports, dict.new(), fn(acc, entry) {
      let #(mod_path, type_name) = entry
      case mod_path == "" {
        True -> acc
        False -> {
          let prev = dict.get(acc, mod_path) |> result.unwrap(set.new())
          dict.insert(acc, mod_path, set.insert(prev, type_name))
        }
      }
    })
  let imports =
    dict.to_list(grouped_imports)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(entry) {
      let #(mod_path, ty_set) = entry
      let ty_list =
        set.to_list(ty_set)
        |> list.sort(string.compare)
        |> list.map(fn(t) { "type " <> t })
        |> string.join(", ")
      "import " <> mod_path <> ".{" <> ty_list <> "}"
    })
  let skipped_block = case skipped {
    [] -> []
    _ -> [
      "// Skipped items:\n"
      <> {
        list.map(skipped, fn(s) { "// - " <> s.0 <> ": " <> s.1 })
        |> string.join("\n")
      },
    ]
  }
  let sections =
    list.flatten([[header], imports, ext_type_decls, fn_stubs, skipped_block])
    |> list.filter(fn(s) { s != "" })

  string.join(sections, "\n\n") <> "\n"
}

pub fn specs_extra_imports(
  bctx: BindContext,
  specs: List(ResolvedTypeSpec),
) -> Dict(String, String) {
  let from_ext =
    list.fold(specs, dict.new(), fn(acc, s) {
      dict.merge(acc, ext_types_to_extra_imports(bctx, s.used_external_types))
    })
  list.fold(specs, from_ext, fn(acc, s) { dict.merge(acc, s.extra_pkgs) })
}

pub fn ext_types_to_extra_imports(
  bctx: BindContext,
  ext_types: Dict(String, ExternalTypeRef),
) -> Dict(String, String) {
  ext_types
  |> dict.values
  |> list.fold(dict.new(), fn(acc, ext) {
    case
      ext.pkg_path == bctx.mbti.package_name
      || is_builtin_pkg(ext.pkg_path)
      || ext.pkg_path == "gprelude"
    {
      True -> acc
      False -> dict.insert(acc, ext.pkg_path, pkg_to_moon_alias(ext.pkg_path))
    }
  })
}

pub fn format_fn_label(f: MbtiFnDecl) -> String {
  case f.owner_type {
    Some(o) -> o <> "::" <> f.name
    None -> f.name
  }
}

pub fn pkg_to_moon_alias(pkg_path: String) -> String {
  pkg_path
  |> string.replace("/", "_")
  |> string.replace("-", "_")
  |> string.replace(".", "_")
}

pub fn last_segment_snake(pkg_path: String) -> String {
  pkg_path
  |> string.split("/")
  |> list.last
  |> result.unwrap(pkg_path)
  |> to_snake_case
}

pub fn to_snake_case(raw: String) -> String {
  raw
  |> string.replace("-", "_")
  |> camel_to_snake_loop("", False)
}

fn camel_to_snake_loop(
  src: String,
  acc: String,
  prev_lower_or_digit: Bool,
) -> String {
  case string.pop_grapheme(src) {
    Error(_) -> acc
    Ok(#(g, rest)) -> {
      let lower = string.lowercase(g)
      let upper = string.uppercase(g)
      let is_upper = lower != upper && g == upper
      let is_lower_or_digit =
        { lower != upper && g == lower }
        || g == "0"
        || g == "1"
        || g == "2"
        || g == "3"
        || g == "4"
        || g == "5"
        || g == "6"
        || g == "7"
        || g == "8"
        || g == "9"
      let next_acc = case is_upper && prev_lower_or_digit {
        True -> acc <> "_" <> lower
        False -> acc <> lower
      }
      camel_to_snake_loop(rest, next_acc, is_lower_or_digit)
    }
  }
}

pub fn sanitize_gleam_type_var(tp: String) -> String {
  let base = to_snake_case(tp)
  let clean = case base {
    "" -> "a"
    _ -> base
  }
  escape_gleam_ident(clean)
}

pub fn escape_gleam_ident(name: String) -> String {
  gleam_ident.escape(name)
}

pub fn mangle_moon_ident(name: String) -> String {
  case name {
    "match"
    | "loop"
    | "for"
    | "while"
    | "break"
    | "continue"
    | "struct"
    | "enum"
    | "trait"
    | "impl"
    | "guard"
    | "async"
    | "test"
    | "init"
    | "main"
    | "pub"
    | "priv"
    | "fn"
    | "let"
    | "mut"
    | "const"
    | "type"
    | "import"
    | "as"
    | "is"
    | "in"
    | "if"
    | "else"
    | "return"
    | "throw"
    | "true"
    | "false"
    | "raise"
    | "try"
    | "catch"
    | "extern"
    | "self"
    | "use"
    | "var" -> name <> "_"
    _ -> name
  }
}

pub fn pick_unique_gleam_name(base: String, used: Set(String)) -> String {
  let clean = escape_gleam_ident(base)
  case set.contains(used, clean) {
    False -> clean
    True -> pick_unique_suffix(clean, 2, used)
  }
}

fn pick_unique_suffix(base: String, idx: Int, used: Set(String)) -> String {
  let candidate = base <> "_" <> int.to_string(idx)
  case set.contains(used, candidate) {
    False -> candidate
    True -> pick_unique_suffix(base, idx + 1, used)
  }
}

pub fn int_range_names(prefix: String, count: Int) -> List(String) {
  int_range_loop(prefix, count - 1, [])
}

fn int_range_loop(prefix: String, idx: Int, acc: List(String)) -> List(String) {
  case idx < 0 {
    True -> acc
    False ->
      int_range_loop(prefix, idx - 1, [prefix <> int.to_string(idx), ..acc])
  }
}
