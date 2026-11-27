import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import moonbit/syntax

/// Parsed representation of a MoonBit `pkg.generated.mbti` interface file.
pub type MbtiPackage {
  MbtiPackage(
    package_name: String,
    imports: List(#(String, String)),
    constants: List(MbtiConst),
    types: List(MbtiTypeDecl),
    functions: List(MbtiFnDecl),
  )
}

/// Public constant or global `let` binding in an `.mbti` package.
pub type MbtiConst {
  MbtiConst(name: String, const_type: MbtiType, is_deprecated: Bool)
}

/// Public or abstract type declaration in an `.mbti` package.
pub type MbtiTypeDecl {
  MbtiTypeDecl(
    name: String,
    type_params: List(String),
    kind: MbtiTypeKind,
    is_deprecated: Bool,
  )
}

/// Structural classification of an `.mbti` type declaration.
pub type MbtiTypeKind {
  MbtiOpaque
  MbtiStruct(
    public_all: Bool,
    fields: List(MbtiField),
    tuple_fields: List(MbtiType),
  )
  MbtiEnum(public_all: Bool, is_suberror: Bool, variants: List(MbtiVariant))
  MbtiAlias(target: MbtiType)
}

/// Visible field in a MoonBit `struct` declaration.
pub type MbtiField {
  MbtiField(name: String, mutable: Bool, field_type: MbtiType)
}

/// Variant constructor in a MoonBit `enum` declaration.
pub type MbtiVariant {
  MbtiVariant(name: String, params: List(#(Option(String), MbtiType)))
}

/// Public function or method declaration in an `.mbti` package.
pub type MbtiFnDecl {
  MbtiFnDecl(
    type_params: List(#(String, List(String))),
    owner_type: Option(String),
    name: String,
    params: List(MbtiParam),
    return_type: MbtiType,
    raises: Bool,
    raise_type: Option(MbtiType),
    poly_raise: Bool,
    is_async: Bool,
    is_deprecated: Bool,
  )
}

/// Function parameter in an `.mbti` signature.
pub type MbtiParam {
  MbtiParam(label: Option(String), is_optional: Bool, param_type: MbtiType)
}

/// Parsed MoonBit type expression from an `.mbti` signature.
pub type MbtiType {
  MbtiNamed(qualifier: Option(String), name: String, args: List(MbtiType))
  MbtiOption(MbtiType)
  MbtiTuple(List(MbtiType))
  MbtiFn(
    is_async: Bool,
    params: List(MbtiType),
    return_type: MbtiType,
    raises: Bool,
    poly_raise: Bool,
  )
  MbtiTraitObject(String)
}

/// Parse a MoonBit `pkg.generated.mbti` file into an `MbtiPackage`.
pub fn parse_mbti(source: String) -> Result(MbtiPackage, String) {
  let lines =
    source
    |> string.replace("\r\n", "\n")
    |> string.split("\n")

  let pkg0 =
    MbtiPackage(
      package_name: "",
      imports: [],
      constants: [],
      types: [],
      functions: [],
    )
  use pkg <- result.try(parse_lines(lines, False, pkg0))
  case pkg.package_name {
    "" -> Error("Missing `package \"...\"` header in .mbti file")
    _ ->
      Ok(MbtiPackage(
        package_name: pkg.package_name,
        imports: list.reverse(pkg.imports),
        constants: list.reverse(pkg.constants),
        types: list.reverse(pkg.types),
        functions: list.reverse(pkg.functions),
      ))
  }
}

fn parse_lines(
  lines: List(String),
  pending_deprecated: Bool,
  acc: MbtiPackage,
) -> Result(MbtiPackage, String) {
  case lines {
    [] -> Ok(acc)
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case trimmed {
        "" -> parse_lines(rest, False, acc)
        _ ->
          case string.starts_with(trimmed, "//") {
            True -> parse_lines(rest, False, acc)
            False ->
              case string.starts_with(trimmed, "#") {
                True -> {
                  let next_dep =
                    pending_deprecated
                    || string.starts_with(trimmed, "#deprecated")
                  parse_lines(rest, next_dep, acc)
                }
                False ->
                  parse_declaration_line(trimmed, rest, pending_deprecated, acc)
              }
          }
      }
    }
  }
}

fn parse_declaration_line(
  trimmed: String,
  rest: List(String),
  pending_deprecated: Bool,
  acc: MbtiPackage,
) -> Result(MbtiPackage, String) {
  case string.starts_with(trimmed, "package \"") {
    True -> {
      let after = string.drop_start(trimmed, 9)
      let name = case string.split_once(after, "\"") {
        Ok(#(pkg, _)) -> pkg
        Error(_) -> ""
      }
      parse_lines(rest, False, MbtiPackage(..acc, package_name: name))
    }
    False ->
      case string.starts_with(trimmed, "import {") {
        True -> {
          let #(block_lines, remaining) = take_until_closing_brace(rest, [])
          let imports = parse_import_block(block_lines)
          parse_lines(remaining, False, MbtiPackage(..acc, imports:))
        }
        False ->
          case is_ignored_decl(trimmed) {
            True -> {
              let remaining = skip_block_if_open(trimmed, rest)
              parse_lines(remaining, False, acc)
            }
            False ->
              case
                string.starts_with(trimmed, "pub fn")
                || string.starts_with(trimmed, "pub async fn")
              {
                True -> {
                  use fn_decl <- result.try(parse_fn_decl(
                    trimmed,
                    pending_deprecated,
                  ))
                  parse_lines(
                    rest,
                    False,
                    MbtiPackage(..acc, functions: [fn_decl, ..acc.functions]),
                  )
                }
                False ->
                  case
                    string.starts_with(trimmed, "pub const ")
                    || string.starts_with(trimmed, "pub let ")
                  {
                    True -> {
                      use c <- result.try(parse_const_decl(
                        trimmed,
                        pending_deprecated,
                      ))
                      parse_lines(
                        rest,
                        False,
                        MbtiPackage(..acc, constants: [c, ..acc.constants]),
                      )
                    }
                    False ->
                      parse_type_declaration(
                        trimmed,
                        rest,
                        pending_deprecated,
                        acc,
                      )
                  }
              }
          }
      }
  }
}

fn is_ignored_decl(trimmed: String) -> Bool {
  string.starts_with(trimmed, "pub impl")
  || string.starts_with(trimmed, "impl ")
  || string.starts_with(trimmed, "pub(open) trait ")
  || string.starts_with(trimmed, "pub trait ")
  || string.starts_with(trimmed, "trait ")
  || string.starts_with(trimmed, "pub using ")
  || string.starts_with(trimmed, "using ")
}

fn skip_block_if_open(trimmed: String, rest: List(String)) -> List(String) {
  case string.ends_with(trimmed, "{") {
    True -> {
      let #(_, remaining) = take_until_closing_brace(rest, [])
      remaining
    }
    False -> rest
  }
}

fn take_until_closing_brace(
  lines: List(String),
  rev_acc: List(String),
) -> #(List(String), List(String)) {
  case lines {
    [] -> #(list.reverse(rev_acc), [])
    [line, ..rest] ->
      case string.starts_with(string.trim(line), "}") {
        True -> #(list.reverse(rev_acc), rest)
        False -> take_until_closing_brace(rest, [line, ..rev_acc])
      }
  }
}

fn parse_import_block(lines: List(String)) -> List(#(String, String)) {
  list.filter_map(lines, fn(raw) {
    let line = string.trim(raw)
    case string.split_once(line, "\"") {
      Ok(#(_, after_q)) ->
        case string.split_once(after_q, "\"") {
          Ok(#(pkg_path, tail)) -> {
            let trimmed_tail = string.trim(tail)
            let alias = case string.split_once(trimmed_tail, "@") {
              Ok(#(_, raw_alias)) ->
                raw_alias
                |> string.replace(",", "")
                |> string.trim
              Error(_) ->
                pkg_path
                |> string.split("/")
                |> list.last
                |> result.unwrap(pkg_path)
            }
            Ok(#(pkg_path, alias))
          }
          Error(_) -> Error(Nil)
        }
      Error(_) -> Error(Nil)
    }
  })
}

fn parse_const_decl(
  line: String,
  is_deprecated: Bool,
) -> Result(MbtiConst, String) {
  let after_kw = case string.starts_with(line, "pub const ") {
    True -> string.drop_start(line, 10)
    False -> string.drop_start(line, 8)
  }
  use #(name_part, rest) <- result.try(
    string.split_once(after_kw, ":")
    |> result.map_error(fn(_) { "Invalid const/let line in .mbti: " <> line }),
  )
  let name = string.trim(name_part)
  let type_src = case split_at_top_level_equals(string.trim(rest)) {
    Some(#(ty_s, _)) -> string.trim(ty_s)
    None -> string.trim(rest)
  }
  use #(const_type, _) <- result.try(parse_type(type_src))
  Ok(MbtiConst(name:, const_type:, is_deprecated:))
}

fn parse_type_declaration(
  trimmed: String,
  rest: List(String),
  is_deprecated: Bool,
  acc: MbtiPackage,
) -> Result(MbtiPackage, String) {
  let #(public_all, after_vis) = case
    string.starts_with(trimmed, "pub(all) "),
    string.starts_with(trimmed, "pub ")
  {
    True, _ -> #(True, string.trim(string.drop_start(trimmed, 9)))
    False, True -> #(False, string.trim(string.drop_start(trimmed, 4)))
    False, False -> #(False, trimmed)
  }

  case
    string.starts_with(after_vis, "struct "),
    string.starts_with(after_vis, "enum "),
    string.starts_with(after_vis, "suberror "),
    string.starts_with(after_vis, "type ")
  {
    True, _, _, _ -> {
      let body = string.trim(string.drop_start(after_vis, 7))
      let #(decl_lines, remaining) = case string.ends_with(body, "{") {
        True -> take_until_closing_brace(rest, [])
        False -> #([], rest)
      }
      use td <- result.try(parse_struct_decl(
        body,
        public_all,
        decl_lines,
        is_deprecated,
      ))
      parse_lines(
        remaining,
        False,
        MbtiPackage(..acc, types: [td, ..acc.types]),
      )
    }

    _, True, _, _ -> {
      let body = string.trim(string.drop_start(after_vis, 5))
      let #(decl_lines, remaining) = case string.ends_with(body, "{") {
        True -> take_until_closing_brace(rest, [])
        False -> #([], rest)
      }
      use td <- result.try(parse_enum_decl(
        body,
        public_all,
        False,
        decl_lines,
        is_deprecated,
      ))
      parse_lines(
        remaining,
        False,
        MbtiPackage(..acc, types: [td, ..acc.types]),
      )
    }

    _, _, True, _ -> {
      let body = string.trim(string.drop_start(after_vis, 9))
      case string.ends_with(body, "{") {
        True -> {
          let #(decl_lines, remaining) = take_until_closing_brace(rest, [])
          use td <- result.try(parse_enum_decl(
            body,
            public_all,
            True,
            decl_lines,
            is_deprecated,
          ))
          parse_lines(
            remaining,
            False,
            MbtiPackage(..acc, types: [td, ..acc.types]),
          )
        }
        False -> {
          let header = strip_trailing_brace(body)
          let #(name, type_params, _) = split_name_and_type_params(header)
          let td =
            MbtiTypeDecl(name:, type_params:, kind: MbtiOpaque, is_deprecated:)
          parse_lines(rest, False, MbtiPackage(..acc, types: [td, ..acc.types]))
        }
      }
    }

    _, _, _, True -> {
      let body = string.trim(string.drop_start(after_vis, 5))
      let #(name, type_params, after_tp) = split_name_and_type_params(body)
      let after_tp = string.trim(after_tp)
      use kind <- result.try(case string.starts_with(after_tp, "=") {
        True -> {
          let target_src = string.trim(string.drop_start(after_tp, 1))
          use #(target, _) <- result.try(parse_type(target_src))
          Ok(MbtiAlias(target:))
        }
        False -> Ok(MbtiOpaque)
      })
      let td = MbtiTypeDecl(name:, type_params:, kind:, is_deprecated:)
      parse_lines(rest, False, MbtiPackage(..acc, types: [td, ..acc.types]))
    }

    _, _, _, _ -> {
      let remaining = skip_block_if_open(trimmed, rest)
      parse_lines(remaining, False, acc)
    }
  }
}

fn parse_struct_decl(
  header_line: String,
  public_all: Bool,
  field_lines: List(String),
  is_deprecated: Bool,
) -> Result(MbtiTypeDecl, String) {
  let clean_header = strip_trailing_brace(header_line)
  let #(name, type_params, after_tp) = split_name_and_type_params(clean_header)
  let after_tp = string.trim(after_tp)
  use tuple_fields <- result.try(case string.starts_with(after_tp, "(") {
    True -> {
      use #(inner, _) <- result.try(syntax.take_balanced_parens(after_tp))
      parse_comma_types(inner)
    }
    False -> Ok([])
  })
  use #(fields, has_private_marker) <- result.try(
    list.try_fold(field_lines, #([], False), fn(acc, raw) {
      let #(rev_fields, seen_priv) = acc
      let line = string.trim(raw)
      case line {
        "" -> Ok(acc)
        "// private fields" -> Ok(#(rev_fields, True))
        _ ->
          case string.starts_with(line, "//") {
            True -> Ok(acc)
            False -> {
              let #(mutable, after_mut) = case
                string.starts_with(line, "mut ")
              {
                True -> #(True, string.trim(string.drop_start(line, 4)))
                False -> #(False, line)
              }
              use #(fname, ftype_src) <- result.try(
                string.split_once(after_mut, ":")
                |> result.map_error(fn(_) {
                  "Invalid struct field in .mbti: " <> line
                }),
              )
              use #(field_type, _) <- result.try(
                parse_type(string.trim(ftype_src)),
              )
              let f = MbtiField(name: string.trim(fname), mutable:, field_type:)
              Ok(#([f, ..rev_fields], seen_priv))
            }
          }
      }
    }),
  )
  let effective_pub_all = public_all && !has_private_marker
  Ok(MbtiTypeDecl(
    name:,
    type_params:,
    kind: MbtiStruct(
      public_all: effective_pub_all,
      fields: list.reverse(fields),
      tuple_fields:,
    ),
    is_deprecated:,
  ))
}

fn parse_enum_decl(
  header_line: String,
  public_all: Bool,
  is_suberror: Bool,
  variant_lines: List(String),
  is_deprecated: Bool,
) -> Result(MbtiTypeDecl, String) {
  let clean_header = strip_trailing_brace(header_line)
  let #(name, type_params, _) = split_name_and_type_params(clean_header)
  use rev_variants <- result.try(
    list.try_fold(variant_lines, [], fn(acc, raw) {
      let line = string.trim(raw)
      case line == "" || string.starts_with(line, "//") {
        True -> Ok(acc)
        False -> {
          use v <- result.try(parse_enum_variant(line))
          Ok([v, ..acc])
        }
      }
    }),
  )
  Ok(MbtiTypeDecl(
    name:,
    type_params:,
    kind: MbtiEnum(
      public_all:,
      is_suberror:,
      variants: list.reverse(rev_variants),
    ),
    is_deprecated:,
  ))
}

fn parse_enum_variant(line: String) -> Result(MbtiVariant, String) {
  case string.split_once(line, "(") {
    Error(_) -> Ok(MbtiVariant(name: string.trim(line), params: []))
    Ok(#(vname, rest)) -> {
      use #(inner, _) <- result.try(syntax.take_balanced_parens("(" <> rest))
      let args = syntax.split_top_level_commas(inner)
      use parsed_params <- result.try(
        list.try_map(args, fn(arg) {
          let a = string.trim(arg)
          case syntax.split_top_level_colon(a) {
            Some(#(lbl_raw, ty_src)) -> {
              let lbl =
                lbl_raw
                |> string.trim
                |> strip_suffix("~")
              use #(ty, _) <- result.try(parse_type(string.trim(ty_src)))
              Ok(#(Some(lbl), ty))
            }
            None -> {
              use #(ty, _) <- result.try(parse_type(a))
              Ok(#(None, ty))
            }
          }
        }),
      )
      Ok(MbtiVariant(name: string.trim(vname), params: parsed_params))
    }
  }
}

fn parse_fn_decl(
  line: String,
  is_deprecated: Bool,
) -> Result(MbtiFnDecl, String) {
  let #(is_async, after_kw) = case string.starts_with(line, "pub async fn") {
    True -> #(True, string.trim(string.drop_start(line, 12)))
    False -> #(False, string.trim(string.drop_start(line, 6)))
  }

  use #(type_params, after_tp) <- result.try(parse_fn_type_params(after_kw))
  let after_tp = string.trim(after_tp)

  use #(name_raw, rest_after_name) <- result.try(
    string.split_once(after_tp, "(")
    |> result.map_error(fn(_) { "Invalid fn signature in .mbti: " <> line }),
  )
  let name_raw = string.trim(name_raw)
  let #(owner_type, name) = case string.split_once(name_raw, "::") {
    Ok(#(owner, method)) -> #(Some(string.trim(owner)), string.trim(method))
    Error(_) -> #(None, name_raw)
  }

  use #(params_src, after_params) <- result.try(syntax.take_balanced_parens(
    "(" <> rest_after_name,
  ))
  use params <- result.try(parse_fn_params(params_src))

  let after_params = string.trim(after_params)
  use ret_and_eff <- result.try(case string.starts_with(after_params, "->") {
    True -> Ok(string.trim(string.drop_start(after_params, 2)))
    False -> Error("Expected `->` in .mbti fn signature: " <> line)
  })

  use #(return_type, tail_eff) <- result.try(parse_type(ret_and_eff))
  let #(raises, poly_raise, raise_type) =
    parse_raise_suffix(string.trim(tail_eff))

  Ok(MbtiFnDecl(
    type_params:,
    owner_type:,
    name:,
    params:,
    return_type:,
    raises:,
    raise_type:,
    poly_raise:,
    is_async:,
    is_deprecated:,
  ))
}

fn parse_fn_type_params(
  src: String,
) -> Result(#(List(#(String, List(String))), String), String) {
  let s = string.trim(src)
  case string.starts_with(s, "[") {
    False -> Ok(#([], s))
    True -> {
      use #(inner, after) <- result.try(syntax.take_balanced_brackets(s))
      let parts = syntax.split_top_level_commas(inner)
      let parsed =
        list.filter_map(parts, fn(part) {
          let p = string.trim(part)
          case p {
            "" -> Error(Nil)
            _ ->
              case string.split_once(p, ":") {
                Ok(#(tp_name, bounds_raw)) -> {
                  let bounds =
                    bounds_raw
                    |> string.split("+")
                    |> list.map(string.trim)
                    |> list.filter(fn(b) { b != "" })
                  Ok(#(string.trim(tp_name), bounds))
                }
                Error(_) -> Ok(#(p, []))
              }
          }
        })
      Ok(#(parsed, after))
    }
  }
}

fn parse_fn_params(src: String) -> Result(List(MbtiParam), String) {
  let trimmed = string.trim(src)
  case trimmed {
    "" -> Ok([])
    _ -> {
      let parts = syntax.split_top_level_commas(trimmed)
      list.try_map(parts, fn(raw_part) {
        let p = string.trim(raw_part)
        case syntax.split_top_level_colon(p) {
          Some(#(lbl_raw, ty_src)) -> {
            let l = string.trim(lbl_raw)
            let #(label, is_optional) = case string.ends_with(l, "?") {
              True -> #(Some(strip_suffix(l, "?")), True)
              False -> #(Some(strip_suffix(l, "~")), False)
            }
            use #(param_type, _) <- result.try(parse_type(string.trim(ty_src)))
            Ok(MbtiParam(label:, is_optional:, param_type:))
          }
          None -> {
            use #(param_type, _) <- result.try(parse_type(p))
            Ok(MbtiParam(label: None, is_optional: False, param_type:))
          }
        }
      })
    }
  }
}

/// Parse one MoonBit type expression, returning `#(parsed_type, remaining_suffix)`.
pub fn parse_type(src: String) -> Result(#(MbtiType, String), String) {
  let s = string.trim_start(src)
  let #(is_async, after_async) = case string.starts_with(s, "async ") {
    True -> #(True, string.trim_start(string.drop_start(s, 6)))
    False -> #(False, s)
  }

  use #(base_ty, rest) <- result.try(
    case
      string.starts_with(after_async, "&"),
      string.starts_with(after_async, "(")
    {
      True, _ -> {
        let #(trait_name, rem) =
          take_type_atom(string.drop_start(after_async, 1))
        Ok(#(MbtiTraitObject(trait_name), rem))
      }

      False, True -> {
        use #(inner, after_paren) <- result.try(syntax.take_balanced_parens(
          after_async,
        ))
        let after_paren_trimmed = string.trim_start(after_paren)
        case string.starts_with(after_paren_trimmed, "->") {
          True -> {
            use param_types <- result.try(parse_comma_types(inner))
            let after_arrow =
              string.trim_start(string.drop_start(after_paren_trimmed, 2))
            use #(ret_type, after_ret) <- result.try(parse_type(after_arrow))
            let #(raises, poly_raise, rem) = consume_raise_suffix(after_ret)
            Ok(#(
              MbtiFn(
                is_async:,
                params: param_types,
                return_type: ret_type,
                raises:,
                poly_raise:,
              ),
              rem,
            ))
          }
          False -> {
            use tuple_els <- result.try(parse_comma_types(inner))
            let ty = case tuple_els {
              [single] -> single
              _ -> MbtiTuple(tuple_els)
            }
            Ok(#(ty, after_paren))
          }
        }
      }

      False, False -> {
        let #(qualifier, after_q) = case string.starts_with(after_async, "@") {
          True -> {
            let without_at = string.drop_start(after_async, 1)
            case string.split_once(without_at, ".") {
              Ok(#(q, rest_after_dot)) -> #(Some(q), rest_after_dot)
              Error(_) -> #(None, after_async)
            }
          }
          False -> #(None, after_async)
        }
        let #(name, after_name) = syntax.read_ident(after_q)
        case name {
          "" -> Error("Expected type name in .mbti at: " <> src)
          _ -> {
            let after_name_trim = string.trim_start(after_name)
            case string.starts_with(after_name_trim, "[") {
              True -> {
                use #(inner, after_br) <- result.try(
                  syntax.take_balanced_brackets(after_name_trim),
                )
                use args <- result.try(parse_comma_types(inner))
                Ok(#(MbtiNamed(qualifier:, name:, args:), after_br))
              }
              False -> Ok(#(MbtiNamed(qualifier:, name:, args: []), after_name))
            }
          }
        }
      }
    },
  )

  apply_postfix_option(base_ty, rest)
}

fn apply_postfix_option(
  ty: MbtiType,
  rest: String,
) -> Result(#(MbtiType, String), String) {
  let trimmed = string.trim_start(rest)
  case string.starts_with(trimmed, "?") {
    True -> apply_postfix_option(MbtiOption(ty), string.drop_start(trimmed, 1))
    False -> Ok(#(ty, rest))
  }
}

fn parse_comma_types(src: String) -> Result(List(MbtiType), String) {
  let trimmed = string.trim(src)
  case trimmed {
    "" -> Ok([])
    _ -> {
      let parts = syntax.split_top_level_commas(trimmed)
      list.try_map(parts, fn(part) {
        use #(ty, _) <- result.try(parse_type(string.trim(part)))
        Ok(ty)
      })
    }
  }
}

fn parse_raise_suffix(suffix: String) -> #(Bool, Bool, Option(MbtiType)) {
  let s = string.trim(suffix)
  case
    string.starts_with(s, "raise?"),
    string.starts_with(s, "raise"),
    string.starts_with(s, "noraise")
  {
    True, _, _ -> #(False, True, None)
    False, True, _ -> {
      let after_kw = string.trim_start(string.drop_start(s, 5))
      case after_kw {
        "" -> #(True, False, None)
        _ ->
          case parse_type(after_kw) {
            Ok(#(ty, _)) -> #(True, False, Some(ty))
            Error(_) -> #(True, False, None)
          }
      }
    }
    _, _, _ -> #(False, False, None)
  }
}

fn consume_raise_suffix(suffix: String) -> #(Bool, Bool, String) {
  let s = string.trim_start(suffix)
  case string.starts_with(s, "raise?") {
    True -> #(False, True, string.drop_start(s, 6))
    False ->
      case string.starts_with(s, "raise") {
        True -> {
          let after_kw = string.trim_start(string.drop_start(s, 5))
          // Only consume explicit error type if an identifier / @ starts immediately
          case
            after_kw != ""
            && !string.starts_with(after_kw, ",")
            && !string.starts_with(after_kw, ")")
            && !string.starts_with(after_kw, "]")
            && !string.starts_with(after_kw, "->")
          {
            True -> {
              let #(_, rem) = take_type_atom(after_kw)
              #(True, False, rem)
            }
            False -> #(True, False, after_kw)
          }
        }
        False ->
          case string.starts_with(s, "noraise") {
            True -> #(False, False, string.drop_start(s, 7))
            False -> #(False, False, suffix)
          }
      }
  }
}

fn split_name_and_type_params(
  header: String,
) -> #(String, List(String), String) {
  let h = string.trim(header)
  let #(name, after_name) = syntax.read_ident(h)
  let after_trim = string.trim_start(after_name)
  case string.starts_with(after_trim, "[") {
    True ->
      case syntax.take_balanced_brackets(after_trim) {
        Ok(#(inner, rem)) -> {
          #(name, syntax.split_top_level_commas(inner), rem)
        }
        Error(_) -> #(name, [], after_name)
      }
    False -> #(name, [], after_name)
  }
}

fn take_type_atom(src: String) -> #(String, String) {
  take_type_atom_loop(src, "", 0)
}

fn take_type_atom_loop(
  src: String,
  acc: String,
  depth: Int,
) -> #(String, String) {
  case string.pop_grapheme(src) {
    Error(_) -> #(acc, "")
    Ok(#(g, rest)) ->
      case g {
        "[" | "(" -> take_type_atom_loop(rest, acc <> g, depth + 1)
        "]" | ")" if depth > 0 -> take_type_atom_loop(rest, acc <> g, depth - 1)
        "," | "]" | ")" | " " | "\t" if depth == 0 -> #(acc, src)
        _ -> take_type_atom_loop(rest, acc <> g, depth)
      }
  }
}

fn split_at_top_level_equals(src: String) -> Option(#(String, String)) {
  case string.split_once(src, "=") {
    Ok(pair) -> Some(pair)
    Error(_) -> None
  }
}

fn strip_trailing_brace(s: String) -> String {
  let trimmed = string.trim(s)
  case string.ends_with(trimmed, "{") {
    True -> string.trim(string.drop_end(trimmed, 1))
    False -> trimmed
  }
}

fn strip_suffix(s: String, suffix: String) -> String {
  case string.ends_with(s, suffix) {
    True -> string.drop_end(s, string.length(suffix))
    False -> s
  }
}
