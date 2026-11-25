import filepath
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile
import wit/ast.{
  type ResolvedWit, type WitFunc, type WitIfaceRef, type WitInterface,
  type WitPackageId, type WitResourceMethod, type WitType, type WitTypeDef,
  type WitUse, type WitWorld, type WitWorldItem, LocalIface, PkgIface,
  ResolvedWit, ResourceConstructor, ResourceMethod, ResourceStatic, WitAlias,
  WitBool, WitBorrow, WitChar, WitEnum, WitF32, WitF64, WitFlags, WitFunc,
  WitInterface, WitList, WitNamed, WitOption, WitOwn, WitPackageId, WitRecord,
  WitResource, WitResourceMethod, WitResult, WitS16, WitS32, WitS64, WitS8,
  WitString, WitTuple, WitU16, WitU32, WitU64, WitU8, WitUse, WitVariant,
  WitWorld, WorldExportFunc, WorldExportIface, WorldImportFunc, WorldImportIface,
  WorldInclude, WorldUse, iface_key, iface_versioned_key, lookup_interface,
  resolve_iface_key_in,
}

type WitToken {
  Ident(String)
  Arrow
  Colon
  Semi
  Comma
  Dot
  LBrace
  RBrace
  LParen
  RParen
  LAngle
  RAngle
  Equals
  At
  Slash
}

type PackageBlock {
  PackageBlock(
    pkg: Option(WitPackageId),
    interfaces: List(WitInterface),
    worlds: List(WitWorld),
  )
}

/// Load and resolve all `.wit` files in `wit_dir` (and `wit_dir/deps` recursively),
/// selecting `world_name` (or the unique world defined by the root package).
pub fn load_wit_dir(
  wit_dir: String,
  world_name: Option(String),
) -> Result(ResolvedWit, String) {
  use is_dir <- result.try(
    simplifile.is_directory(wit_dir)
    |> result.map_error(fn(err) {
      "Failed to access WIT directory '"
      <> wit_dir
      <> "': "
      <> simplifile.describe_error(err)
    }),
  )
  case is_dir {
    False -> Error("WIT directory does not exist: " <> wit_dir)
    True -> {
      use entries <- result.try(
        simplifile.read_directory(wit_dir)
        |> result.map_error(fn(err) {
          "Failed to read WIT directory '"
          <> wit_dir
          <> "': "
          <> simplifile.describe_error(err)
        }),
      )
      let root_wit_files =
        entries
        |> list.filter(fn(name) { string.ends_with(name, ".wit") })
        |> list.sort(string.compare)
        |> list.map(filepath.join(wit_dir, _))

      case root_wit_files {
        [] -> Error("No *.wit files found in " <> wit_dir)
        _ -> {
          use root_blocks <- result.try(parse_files_blocks(root_wit_files))
          use root_pkg <- result.try(resolve_root_package(root_blocks, wit_dir))
          let filled_root_blocks = fill_missing_packages(root_blocks, root_pkg)

          let deps_dir = filepath.join(wit_dir, "deps")
          use dep_files <- result.try(collect_wit_files_recursive(deps_dir))
          use dep_blocks <- result.try(parse_files_blocks(dep_files))

          let all_blocks = list.append(filled_root_blocks, dep_blocks)
          let interfaces = build_interface_index(all_blocks)
          let all_worlds = list.flat_map(all_blocks, fn(b) { b.worlds })

          let root_worlds =
            list.flat_map(filled_root_blocks, fn(b) { b.worlds })
          use raw_world <- result.try(select_world(
            root_worlds,
            world_name,
            wit_dir,
          ))
          use selected_world <- result.try(expand_world_includes(
            raw_world,
            all_worlds,
            set.new(),
          ))
          use _ <- result.try(validate_resolved(
            root_pkg,
            selected_world,
            interfaces,
          ))
          Ok(ResolvedWit(root_pkg:, world: selected_world, interfaces:))
        }
      }
    }
  }
}

fn parse_files_blocks(
  paths: List(String),
) -> Result(List(PackageBlock), String) {
  list.try_fold(paths, [], fn(acc, path) {
    use src <- result.try(
      simplifile.read(from: path)
      |> result.map_error(fn(err) {
        "Failed to read WIT file '"
        <> path
        <> "': "
        <> simplifile.describe_error(err)
      }),
    )
    use blocks <- result.try(parse_wit_blocks(src, path))
    Ok(list.append(acc, blocks))
  })
}

fn collect_wit_files_recursive(dir: String) -> Result(List(String), String) {
  case simplifile.is_directory(dir) {
    Ok(False) | Error(_) -> Ok([])
    Ok(True) -> {
      use all <- result.try(
        simplifile.get_files(in: dir)
        |> result.map_error(fn(err) {
          "Failed to walk WIT deps directory '"
          <> dir
          <> "': "
          <> simplifile.describe_error(err)
        }),
      )
      all
      |> list.filter(fn(p) { string.ends_with(p, ".wit") })
      |> list.sort(string.compare)
      |> Ok
    }
  }
}

fn resolve_root_package(
  blocks: List(PackageBlock),
  wit_dir: String,
) -> Result(WitPackageId, String) {
  let declared =
    list.filter_map(blocks, fn(b) {
      case b.pkg {
        Some(p) -> Ok(p)
        None -> Error(Nil)
      }
    })
  case declared {
    [] -> Error("Missing `package ns:name;` header in " <> wit_dir)
    [first, ..rest] -> {
      let conflict =
        list.find(rest, fn(p) {
          p.namespace != first.namespace || p.name != first.name
        })
      case conflict {
        Ok(other) ->
          Error(
            "Multiple packages found in "
            <> wit_dir
            <> ": "
            <> first.namespace
            <> ":"
            <> first.name
            <> " and "
            <> other.namespace
            <> ":"
            <> other.name,
          )
        Error(_) -> Ok(first)
      }
    }
  }
}

fn fill_missing_packages(
  blocks: List(PackageBlock),
  default_pkg: WitPackageId,
) -> List(PackageBlock) {
  list.map(blocks, fn(b) {
    case b.pkg {
      Some(_) -> b
      None -> {
        let interfaces =
          list.map(b.interfaces, fn(i) { WitInterface(..i, pkg: default_pkg) })
        let worlds =
          list.map(b.worlds, fn(w) { WitWorld(..w, pkg: default_pkg) })
        PackageBlock(pkg: Some(default_pkg), interfaces:, worlds:)
      }
    }
  })
}

fn select_world(
  worlds: List(WitWorld),
  requested: Option(String),
  wit_dir: String,
) -> Result(WitWorld, String) {
  case requested, worlds {
    None, [single] -> Ok(single)
    None, [] -> Error("No `world` declaration found in " <> wit_dir)
    None, many -> {
      let names =
        list.map(many, fn(w) { w.name })
        |> string.join(", ")
      Error(
        "Multiple worlds found in "
        <> wit_dir
        <> " ("
        <> names
        <> "); pass --world <name>.",
      )
    }
    Some(target), _ -> {
      let matched =
        list.find(worlds, fn(w) {
          w.name == target
          || w.pkg.namespace <> ":" <> w.pkg.name <> "/" <> w.name == target
        })
      case matched {
        Ok(w) -> Ok(w)
        Error(_) -> {
          let names =
            list.map(worlds, fn(w) { w.name })
            |> string.join(", ")
          Error(
            "World '"
            <> target
            <> "' not found in "
            <> wit_dir
            <> " (available: "
            <> names
            <> ")",
          )
        }
      }
    }
  }
}

fn build_interface_index(
  blocks: List(PackageBlock),
) -> Dict(String, WitInterface) {
  let all_ifaces = list.flat_map(blocks, fn(b) { b.interfaces })
  let by_unversioned =
    list.fold(all_ifaces, dict.new(), fn(acc, iface) {
      let base = iface_key(iface.pkg, iface.name)
      let prev = dict.get(acc, base) |> result.unwrap([])
      dict.insert(acc, base, [iface, ..prev])
    })
  list.fold(all_ifaces, dict.new(), fn(acc, iface) {
    let vkey = iface_versioned_key(iface.pkg, iface.name)
    let base = iface_key(iface.pkg, iface.name)
    let acc1 = dict.insert(acc, vkey, iface)
    case dict.get(by_unversioned, base) {
      Ok([_]) -> dict.insert(acc1, base, iface)
      _ -> acc1
    }
  })
}

fn expand_world_includes(
  world: WitWorld,
  all_worlds: List(WitWorld),
  visiting: Set(String),
) -> Result(WitWorld, String) {
  let wkey = iface_versioned_key(world.pkg, world.name)
  case set.contains(visiting, wkey) {
    True -> Error("Cyclic WIT world `include` involving '" <> wkey <> "'")
    False -> {
      let next_visiting = set.insert(visiting, wkey)
      use expanded_items <- result.try(
        list.try_fold(world.items, [], fn(acc, item) {
          case item {
            WorldInclude(target:, with_renames:) -> {
              use inc_world <- result.try(find_world_for_ref(
                world.pkg,
                target,
                all_worlds,
              ))
              use expanded_inc <- result.try(expand_world_includes(
                inc_world,
                all_worlds,
                next_visiting,
              ))
              let rebased =
                list.map(expanded_inc.items, fn(sub_item) {
                  rebase_included_world_item(
                    sub_item,
                    expanded_inc.pkg,
                    with_renames,
                  )
                })
              Ok(list.append(list.reverse(rebased), acc))
            }
            _ -> Ok([item, ..acc])
          }
        }),
      )
      Ok(WitWorld(..world, items: list.reverse(expanded_items)))
    }
  }
}

fn find_world_for_ref(
  default_pkg: WitPackageId,
  ref: WitIfaceRef,
  all_worlds: List(WitWorld),
) -> Result(WitWorld, String) {
  let matched = case ref {
    LocalIface(name) ->
      list.find(all_worlds, fn(w) {
        w.pkg.namespace == default_pkg.namespace
        && w.pkg.name == default_pkg.name
        && w.name == name
      })
    PkgIface(pkg, name) ->
      list.find(all_worlds, fn(w) {
        w.pkg.namespace == pkg.namespace
        && w.pkg.name == pkg.name
        && w.name == name
        && case pkg.version {
          None -> True
          Some(v) -> w.pkg.version == Some(v)
        }
      })
  }
  case matched {
    Ok(w) -> Ok(w)
    Error(_) ->
      Error(
        "Unknown WIT world '"
        <> ast.resolve_iface_ref(default_pkg, ref)
        <> "' referenced by `include`",
      )
  }
}

fn rebase_included_world_item(
  item: WitWorldItem,
  inc_pkg: WitPackageId,
  with_renames: List(#(String, String)),
) -> WitWorldItem {
  let rebase_ref = fn(r: WitIfaceRef) {
    case r {
      LocalIface(n) -> PkgIface(inc_pkg, n)
      PkgIface(_, _) -> r
    }
  }
  let rename_fn = fn(f: WitFunc) {
    case list.key_find(with_renames, f.name) {
      Ok(new_name) -> WitFunc(..f, name: new_name)
      Error(_) -> f
    }
  }
  case item {
    WorldImportIface(r) -> WorldImportIface(rebase_ref(r))
    WorldExportIface(r) -> WorldExportIface(rebase_ref(r))
    WorldImportFunc(f) -> WorldImportFunc(rename_fn(f))
    WorldExportFunc(f) -> WorldExportFunc(rename_fn(f))
    WorldUse(u) -> WorldUse(WitUse(..u, target: rebase_ref(u.target)))
    WorldInclude(target:, with_renames:) ->
      WorldInclude(target: rebase_ref(target), with_renames:)
  }
}

fn validate_resolved(
  root_pkg: WitPackageId,
  world: WitWorld,
  interfaces: Dict(String, WitInterface),
) -> Result(Nil, String) {
  use _ <- result.try(
    list.try_each(world.items, fn(item) {
      case item {
        WorldImportIface(ref) -> {
          case lookup_interface(interfaces, root_pkg, ref) {
            Ok(_) -> Ok(Nil)
            Error(_) ->
              Error(
                "Unknown WIT interface '"
                <> resolve_iface_key_in(interfaces, root_pkg, ref)
                <> "' referenced in world '"
                <> world.name
                <> "'",
              )
          }
        }
        WorldExportIface(ref) -> {
          case lookup_interface(interfaces, root_pkg, ref) {
            Ok(iface) -> {
              let has_resource =
                list.any(iface.types, fn(td) {
                  case td {
                    WitResource(..) -> True
                    _ -> False
                  }
                })
              case has_resource {
                True ->
                  Error(
                    "Exported WIT resource in interface '"
                    <> iface.name
                    <> "' is not supported yet (imported resources are supported)",
                  )
                False -> Ok(Nil)
              }
            }
            Error(_) ->
              Error(
                "Unknown WIT interface '"
                <> resolve_iface_key_in(interfaces, root_pkg, ref)
                <> "' referenced in world '"
                <> world.name
                <> "'",
              )
          }
        }
        WorldUse(u) -> {
          case lookup_interface(interfaces, root_pkg, u.target) {
            Ok(_) -> Ok(Nil)
            Error(_) ->
              Error(
                "Unknown WIT interface '"
                <> resolve_iface_key_in(interfaces, root_pkg, u.target)
                <> "' in world `use` of '"
                <> world.name
                <> "'",
              )
          }
        }
        WorldImportFunc(_) | WorldExportFunc(_) | WorldInclude(_, _) -> Ok(Nil)
      }
    }),
  )
  dict.to_list(interfaces)
  |> list.try_each(fn(entry) {
    let #(_, iface) = entry
    list.try_each(iface.uses, fn(u) {
      case lookup_interface(interfaces, iface.pkg, u.target) {
        Ok(_) -> Ok(Nil)
        Error(_) ->
          Error(
            "Unknown WIT interface '"
            <> resolve_iface_key_in(interfaces, iface.pkg, u.target)
            <> "' referenced by `use` in interface '"
            <> iface.name
            <> "'",
          )
      }
    })
  })
}

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

fn lex_wit(
  source: String,
  file_label: String,
) -> Result(List(WitToken), String) {
  let chars = string.to_graphemes(source)
  lex_loop(chars, file_label, 1, [])
}

fn lex_loop(
  chars: List(String),
  file_label: String,
  line: Int,
  acc: List(WitToken),
) -> Result(List(WitToken), String) {
  case chars {
    [] -> Ok(list.reverse(acc))
    ["\n", ..rest] -> lex_loop(rest, file_label, line + 1, acc)
    [" ", ..rest] | ["\t", ..rest] | ["\r", ..rest] ->
      lex_loop(rest, file_label, line, acc)

    ["/", "/", ..rest] -> {
      let after = skip_line_comment(rest)
      lex_loop(after, file_label, line, acc)
    }

    ["/", "*", ..rest] -> {
      use #(after, next_line) <- result.try(skip_block_comment(
        rest,
        file_label,
        line,
        1,
      ))
      lex_loop(after, file_label, next_line, acc)
    }

    ["-", ">", ..rest] -> lex_loop(rest, file_label, line, [Arrow, ..acc])
    [":", ..rest] -> lex_loop(rest, file_label, line, [Colon, ..acc])
    [";", ..rest] -> lex_loop(rest, file_label, line, [Semi, ..acc])
    [",", ..rest] -> lex_loop(rest, file_label, line, [Comma, ..acc])
    [".", ..rest] -> lex_loop(rest, file_label, line, [Dot, ..acc])
    ["{", ..rest] -> lex_loop(rest, file_label, line, [LBrace, ..acc])
    ["}", ..rest] -> lex_loop(rest, file_label, line, [RBrace, ..acc])
    ["(", ..rest] -> lex_loop(rest, file_label, line, [LParen, ..acc])
    [")", ..rest] -> lex_loop(rest, file_label, line, [RParen, ..acc])
    ["<", ..rest] -> lex_loop(rest, file_label, line, [LAngle, ..acc])
    [">", ..rest] -> lex_loop(rest, file_label, line, [RAngle, ..acc])
    ["=", ..rest] -> lex_loop(rest, file_label, line, [Equals, ..acc])
    ["@", ..rest] -> lex_loop(rest, file_label, line, [At, ..acc])
    ["/", ..rest] -> lex_loop(rest, file_label, line, [Slash, ..acc])

    ["%", ..rest] -> {
      let #(word, remaining) = take_ident_chars(rest, [])
      case word {
        "" ->
          Error(
            "Invalid `%` escape at " <> file_label <> ":" <> int.to_string(line),
          )
        _ -> lex_loop(remaining, file_label, line, [Ident(word), ..acc])
      }
    }

    [c, ..rest] ->
      case is_ident_start(c) {
        True -> {
          let #(word, remaining) = take_ident_chars(rest, [c])
          lex_loop(remaining, file_label, line, [Ident(word), ..acc])
        }
        False ->
          Error(
            "Unexpected character '"
            <> c
            <> "' in "
            <> file_label
            <> ":"
            <> int.to_string(line),
          )
      }
  }
}

fn skip_line_comment(chars: List(String)) -> List(String) {
  case chars {
    [] -> []
    ["\n", ..] -> chars
    [_, ..rest] -> skip_line_comment(rest)
  }
}

fn skip_block_comment(
  chars: List(String),
  file_label: String,
  line: Int,
  depth: Int,
) -> Result(#(List(String), Int), String) {
  case depth <= 0 {
    True -> Ok(#(chars, line))
    False ->
      case chars {
        [] -> Error("Unterminated block comment in " <> file_label)
        ["\n", ..rest] -> skip_block_comment(rest, file_label, line + 1, depth)
        ["*", "/", ..rest] ->
          skip_block_comment(rest, file_label, line, depth - 1)
        ["/", "*", ..rest] ->
          skip_block_comment(rest, file_label, line, depth + 1)
        [_, ..rest] -> skip_block_comment(rest, file_label, line, depth)
      }
  }
}

fn take_ident_chars(
  chars: List(String),
  rev_acc: List(String),
) -> #(String, List(String)) {
  case chars {
    ["-", ">", ..] -> #(list.reverse(rev_acc) |> string.concat, chars)
    [c, ..rest] ->
      case is_ident_continue(c) {
        True -> take_ident_chars(rest, [c, ..rev_acc])
        False -> #(list.reverse(rev_acc) |> string.concat, chars)
      }
    [] -> #(list.reverse(rev_acc) |> string.concat, [])
  }
}

fn is_ident_start(c: String) -> Bool {
  case string.to_utf_codepoints(c) {
    [cp] -> {
      let n = string.utf_codepoint_to_int(cp)
      { n >= 97 && n <= 122 }
      || { n >= 65 && n <= 90 }
      || { n >= 48 && n <= 57 }
      || n == 95
    }
    _ -> False
  }
}

fn is_ident_continue(c: String) -> Bool {
  c == "-" || is_ident_start(c)
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

fn parse_wit_blocks(
  source: String,
  file_label: String,
) -> Result(List(PackageBlock), String) {
  use tokens <- result.try(lex_wit(source, file_label))
  parse_top_blocks(tokens, None, [], [], [])
}

fn parse_top_blocks(
  tokens: List(WitToken),
  cur_pkg: Option(WitPackageId),
  cur_ifaces: List(WitInterface),
  cur_worlds: List(WitWorld),
  completed: List(PackageBlock),
) -> Result(List(PackageBlock), String) {
  case tokens {
    [] -> {
      let has_cur =
        option.is_some(cur_pkg) || cur_ifaces != [] || cur_worlds != []
      let all = case has_cur {
        True -> [
          PackageBlock(
            pkg: cur_pkg,
            interfaces: list.reverse(cur_ifaces),
            worlds: list.reverse(cur_worlds),
          ),
          ..completed
        ]
        False -> completed
      }
      Ok(list.reverse(all))
    }

    [Ident("package"), ..rest] -> {
      use #(pkg_id, after_pkg) <- result.try(parse_package_id(rest))
      case after_pkg {
        [Semi, ..tail] -> {
          let next_completed = case
            option.is_some(cur_pkg) || cur_ifaces != [] || cur_worlds != []
          {
            True -> [
              PackageBlock(
                pkg: cur_pkg,
                interfaces: list.reverse(cur_ifaces),
                worlds: list.reverse(cur_worlds),
              ),
              ..completed
            ]
            False -> completed
          }
          parse_top_blocks(tail, Some(pkg_id), [], [], next_completed)
        }
        [LBrace, ..body] -> {
          use #(ifaces, worlds, tail) <- result.try(
            parse_nested_package_body(body, pkg_id, [], []),
          )
          let blk =
            PackageBlock(
              pkg: Some(pkg_id),
              interfaces: list.reverse(ifaces),
              worlds: list.reverse(worlds),
            )
          parse_top_blocks(tail, cur_pkg, cur_ifaces, cur_worlds, [
            blk,
            ..completed
          ])
        }
        _ -> Error("Expected `;` or `{` after package declaration")
      }
    }

    [Ident("interface"), Ident(name), LBrace, ..body] -> {
      let pkg = option.unwrap(cur_pkg, WitPackageId("root", "pkg", None))
      use #(iface, tail) <- result.try(parse_interface_body(body, pkg, name))
      parse_top_blocks(
        tail,
        cur_pkg,
        [iface, ..cur_ifaces],
        cur_worlds,
        completed,
      )
    }

    [Ident("world"), Ident(name), LBrace, ..body] -> {
      let pkg = option.unwrap(cur_pkg, WitPackageId("root", "pkg", None))
      use #(world, tail) <- result.try(parse_world_body(body, pkg, name))
      parse_top_blocks(
        tail,
        cur_pkg,
        cur_ifaces,
        [world, ..cur_worlds],
        completed,
      )
    }

    [Ident("use"), ..] ->
      Error("Top-level `use` outside interface/world is not supported in WIT")
    [tok, ..] -> Error("Unexpected top-level WIT token: " <> token_label(tok))
  }
}

fn parse_nested_package_body(
  tokens: List(WitToken),
  pkg: WitPackageId,
  ifaces: List(WitInterface),
  worlds: List(WitWorld),
) -> Result(#(List(WitInterface), List(WitWorld), List(WitToken)), String) {
  case tokens {
    [RBrace, ..tail] -> Ok(#(ifaces, worlds, tail))
    [Ident("interface"), Ident(name), LBrace, ..body] -> {
      use #(iface, tail) <- result.try(parse_interface_body(body, pkg, name))
      parse_nested_package_body(tail, pkg, [iface, ..ifaces], worlds)
    }
    [Ident("world"), Ident(name), LBrace, ..body] -> {
      use #(world, tail) <- result.try(parse_world_body(body, pkg, name))
      parse_nested_package_body(tail, pkg, ifaces, [world, ..worlds])
    }
    [tok, ..] ->
      Error("Unexpected token inside `package { ... }`: " <> token_label(tok))
    [] -> Error("Unterminated `package { ... }` block")
  }
}

fn parse_package_id(
  tokens: List(WitToken),
) -> Result(#(WitPackageId, List(WitToken)), String) {
  case tokens {
    [Ident(ns), Colon, Ident(name), ..rest] ->
      case rest {
        [At, ..ver_tokens] -> {
          use #(ver, after_ver) <- result.try(parse_version(ver_tokens, []))
          Ok(#(WitPackageId(ns, name, Some(ver)), after_ver))
        }
        _ -> Ok(#(WitPackageId(ns, name, None), rest))
      }
    _ -> Error("Expected package identifier `namespace:name`")
  }
}

fn parse_version(
  tokens: List(WitToken),
  rev_parts: List(String),
) -> Result(#(String, List(WitToken)), String) {
  case tokens {
    [Ident(part), Dot, Ident(next), ..rest] ->
      parse_version([Ident(next), ..rest], [".", part, ..rev_parts])
    [Ident(part), ..rest] -> {
      let ver =
        list.reverse([part, ..rev_parts])
        |> string.concat
      Ok(#(ver, rest))
    }
    _ -> Error("Expected semver version after `@`")
  }
}

fn parse_interface_ref(
  tokens: List(WitToken),
) -> Result(#(WitIfaceRef, List(WitToken)), String) {
  case tokens {
    [Ident(ns), Colon, Ident(pkg_name), Slash, Ident(iface_name), ..rest] ->
      case rest {
        [At, ..ver_tokens] -> {
          use #(ver, after_ver) <- result.try(parse_version(ver_tokens, []))
          Ok(#(
            PkgIface(WitPackageId(ns, pkg_name, Some(ver)), iface_name),
            after_ver,
          ))
        }
        _ -> Ok(#(PkgIface(WitPackageId(ns, pkg_name, None), iface_name), rest))
      }
    [Ident(name), ..rest] -> Ok(#(LocalIface(name), rest))
    _ -> Error("Expected WIT interface reference")
  }
}

fn parse_use(
  tokens: List(WitToken),
) -> Result(#(WitUse, List(WitToken)), String) {
  use #(target, after_ref) <- result.try(parse_interface_ref(tokens))
  case after_ref {
    [Dot, LBrace, ..items_toks] -> {
      use #(names, after_items) <- result.try(parse_use_names(items_toks, []))
      case after_items {
        [Semi, ..tail] -> Ok(#(WitUse(target:, names:), tail))
        _ -> Error("Expected `;` after `use ... .{...}`")
      }
    }
    _ -> Error("Expected `.{...}` in `use` item")
  }
}

fn parse_use_names(
  tokens: List(WitToken),
  rev_acc: List(#(String, Option(String))),
) -> Result(#(List(#(String, Option(String))), List(WitToken)), String) {
  case tokens {
    [RBrace, ..rest] -> Ok(#(list.reverse(rev_acc), rest))
    [Ident(name), Ident("as"), Ident(alias), Comma, ..rest] ->
      parse_use_names(rest, [#(name, Some(alias)), ..rev_acc])
    [Ident(name), Ident("as"), Ident(alias), RBrace, ..rest] ->
      Ok(#(list.reverse([#(name, Some(alias)), ..rev_acc]), rest))
    [Ident(name), Comma, ..rest] ->
      parse_use_names(rest, [#(name, None), ..rev_acc])
    [Ident(name), RBrace, ..rest] ->
      Ok(#(list.reverse([#(name, None), ..rev_acc]), rest))
    _ -> Error("Malformed `use` import list")
  }
}

fn parse_interface_body(
  tokens: List(WitToken),
  pkg: WitPackageId,
  iface_name: String,
) -> Result(#(WitInterface, List(WitToken)), String) {
  parse_iface_items(tokens, pkg, iface_name, [], [], [])
}

fn parse_iface_items(
  tokens: List(WitToken),
  pkg: WitPackageId,
  iface_name: String,
  uses: List(WitUse),
  types: List(WitTypeDef),
  funcs: List(WitFunc),
) -> Result(#(WitInterface, List(WitToken)), String) {
  case tokens {
    [RBrace, ..rest] ->
      Ok(#(
        WitInterface(
          pkg:,
          name: iface_name,
          uses: list.reverse(uses),
          types: list.reverse(types),
          funcs: list.reverse(funcs),
        ),
        rest,
      ))

    [Ident("use"), ..rest] -> {
      use #(u, tail) <- result.try(parse_use(rest))
      parse_iface_items(tail, pkg, iface_name, [u, ..uses], types, funcs)
    }

    [Ident("record"), Ident(name), LBrace, ..rest] -> {
      use #(fields, tail) <- result.try(parse_record_fields(rest, []))
      parse_iface_items(
        tail,
        pkg,
        iface_name,
        uses,
        [WitRecord(name:, fields:), ..types],
        funcs,
      )
    }

    [Ident("enum"), Ident(name), LBrace, ..rest] -> {
      use #(cases, tail) <- result.try(parse_ident_list(rest, []))
      parse_iface_items(
        tail,
        pkg,
        iface_name,
        uses,
        [WitEnum(name:, cases:), ..types],
        funcs,
      )
    }

    [Ident("flags"), Ident(name), LBrace, ..rest] -> {
      use #(flags, tail) <- result.try(parse_ident_list(rest, []))
      parse_iface_items(
        tail,
        pkg,
        iface_name,
        uses,
        [WitFlags(name:, flags:), ..types],
        funcs,
      )
    }

    [Ident("variant"), Ident(name), LBrace, ..rest] -> {
      use #(cases, tail) <- result.try(parse_variant_cases(rest, []))
      parse_iface_items(
        tail,
        pkg,
        iface_name,
        uses,
        [WitVariant(name:, cases:), ..types],
        funcs,
      )
    }

    [Ident("type"), Ident(name), Equals, ..rest] -> {
      use #(target, after_ty) <- result.try(parse_type(rest))
      case after_ty {
        [Semi, ..tail] ->
          parse_iface_items(
            tail,
            pkg,
            iface_name,
            uses,
            [WitAlias(name:, target:), ..types],
            funcs,
          )
        _ -> Error("Expected `;` after type alias '" <> name <> "'")
      }
    }

    [Ident("resource"), Ident(name), Semi, ..tail] ->
      parse_iface_items(
        tail,
        pkg,
        iface_name,
        uses,
        [WitResource(name:, methods: []), ..types],
        funcs,
      )

    [Ident("resource"), Ident(name), LBrace, ..rest] -> {
      use #(methods, tail) <- result.try(parse_resource_methods(rest, name, []))
      parse_iface_items(
        tail,
        pkg,
        iface_name,
        uses,
        [WitResource(name:, methods:), ..types],
        funcs,
      )
    }

    [Ident(fn_name), Colon, Ident("func"), LParen, ..rest] -> {
      use #(f, tail) <- result.try(parse_func_sig(fn_name, rest))
      parse_iface_items(tail, pkg, iface_name, uses, types, [f, ..funcs])
    }

    [tok, ..] ->
      Error(
        "Unexpected token in interface '"
        <> iface_name
        <> "': "
        <> token_label(tok),
      )

    [] -> Error("Unterminated interface '" <> iface_name <> "'")
  }
}

fn parse_resource_methods(
  tokens: List(WitToken),
  resource_name: String,
  rev_acc: List(WitResourceMethod),
) -> Result(#(List(WitResourceMethod), List(WitToken)), String) {
  case tokens {
    [RBrace, ..rest] -> Ok(#(list.reverse(rev_acc), rest))
    [Ident("constructor"), LParen, ..rest] -> {
      use #(params, after_rparen) <- result.try(parse_func_params(rest, []))
      case after_rparen {
        [Semi, ..tail] -> {
          let m =
            WitResourceMethod(
              name: "constructor",
              kind: ResourceConstructor,
              params:,
              result: None,
            )
          parse_resource_methods(tail, resource_name, [m, ..rev_acc])
        }
        _ ->
          Error(
            "Expected `;` after constructor of resource '"
            <> resource_name
            <> "'",
          )
      }
    }
    [Ident(m_name), Colon, Ident("static"), Ident("func"), LParen, ..rest] -> {
      use #(f, tail) <- result.try(parse_func_sig(m_name, rest))
      let m =
        WitResourceMethod(
          name: f.name,
          kind: ResourceStatic,
          params: f.params,
          result: f.result,
        )
      parse_resource_methods(tail, resource_name, [m, ..rev_acc])
    }
    [Ident(m_name), Colon, Ident("func"), LParen, ..rest] -> {
      use #(f, tail) <- result.try(parse_func_sig(m_name, rest))
      let m =
        WitResourceMethod(
          name: f.name,
          kind: ResourceMethod,
          params: f.params,
          result: f.result,
        )
      parse_resource_methods(tail, resource_name, [m, ..rev_acc])
    }
    [tok, ..] ->
      Error(
        "Unexpected token in resource '"
        <> resource_name
        <> "': "
        <> token_label(tok),
      )
    [] -> Error("Unterminated resource '" <> resource_name <> "'")
  }
}

fn parse_record_fields(
  tokens: List(WitToken),
  rev_acc: List(#(String, WitType)),
) -> Result(#(List(#(String, WitType)), List(WitToken)), String) {
  case tokens {
    [RBrace, ..rest] -> Ok(#(list.reverse(rev_acc), rest))
    [Ident(field_name), Colon, ..rest] -> {
      use #(ty, after_ty) <- result.try(parse_type(rest))
      case after_ty {
        [Comma, ..tail] ->
          parse_record_fields(tail, [#(field_name, ty), ..rev_acc])
        [RBrace, ..tail] ->
          Ok(#(list.reverse([#(field_name, ty), ..rev_acc]), tail))
        _ ->
          Error("Expected `,` or `}` after record field '" <> field_name <> "'")
      }
    }
    _ -> Error("Malformed record field")
  }
}

fn parse_ident_list(
  tokens: List(WitToken),
  rev_acc: List(String),
) -> Result(#(List(String), List(WitToken)), String) {
  case tokens {
    [RBrace, ..rest] -> Ok(#(list.reverse(rev_acc), rest))
    [Ident(name), Comma, ..rest] -> parse_ident_list(rest, [name, ..rev_acc])
    [Ident(name), RBrace, ..rest] ->
      Ok(#(list.reverse([name, ..rev_acc]), rest))
    _ -> Error("Malformed enum/flags case list")
  }
}

fn parse_variant_cases(
  tokens: List(WitToken),
  rev_acc: List(#(String, Option(WitType))),
) -> Result(#(List(#(String, Option(WitType))), List(WitToken)), String) {
  case tokens {
    [RBrace, ..rest] -> Ok(#(list.reverse(rev_acc), rest))
    [Ident(case_name), LParen, ..rest] -> {
      use #(payload_ty, after_ty) <- result.try(parse_type(rest))
      case after_ty {
        [RParen, Comma, ..tail] ->
          parse_variant_cases(tail, [#(case_name, Some(payload_ty)), ..rev_acc])
        [RParen, RBrace, ..tail] ->
          Ok(#(list.reverse([#(case_name, Some(payload_ty)), ..rev_acc]), tail))
        _ -> Error("Expected `)` after variant payload '" <> case_name <> "'")
      }
    }
    [Ident(case_name), Comma, ..rest] ->
      parse_variant_cases(rest, [#(case_name, None), ..rev_acc])
    [Ident(case_name), RBrace, ..rest] ->
      Ok(#(list.reverse([#(case_name, None), ..rev_acc]), rest))
    _ -> Error("Malformed variant case")
  }
}

fn parse_func_sig(
  fn_name: String,
  tokens_after_lparen: List(WitToken),
) -> Result(#(WitFunc, List(WitToken)), String) {
  use #(params, after_rparen) <- result.try(
    parse_func_params(tokens_after_lparen, []),
  )
  case after_rparen {
    [Semi, ..rest] -> Ok(#(WitFunc(name: fn_name, params:, result: None), rest))
    [Arrow, ..after_arrow] -> {
      use #(ret_ty, after_ret) <- result.try(parse_type(after_arrow))
      case after_ret {
        [Semi, ..rest] ->
          Ok(#(WitFunc(name: fn_name, params:, result: Some(ret_ty)), rest))
        _ ->
          Error(
            "Expected `;` after return type of function '" <> fn_name <> "'",
          )
      }
    }
    _ -> Error("Expected `->` or `;` after parameters of '" <> fn_name <> "'")
  }
}

fn parse_func_params(
  tokens: List(WitToken),
  rev_acc: List(#(String, WitType)),
) -> Result(#(List(#(String, WitType)), List(WitToken)), String) {
  case tokens {
    [RParen, ..rest] -> Ok(#(list.reverse(rev_acc), rest))
    [Ident(param_name), Colon, ..rest] -> {
      use #(ty, after_ty) <- result.try(parse_type(rest))
      case after_ty {
        [Comma, ..tail] ->
          parse_func_params(tail, [#(param_name, ty), ..rev_acc])
        [RParen, ..tail] ->
          Ok(#(list.reverse([#(param_name, ty), ..rev_acc]), tail))
        _ -> Error("Expected `,` or `)` after parameter '" <> param_name <> "'")
      }
    }
    _ -> Error("Malformed function parameter list")
  }
}

fn parse_type(
  tokens: List(WitToken),
) -> Result(#(WitType, List(WitToken)), String) {
  case tokens {
    [Ident("bool"), ..rest] -> Ok(#(WitBool, rest))
    [Ident("s8"), ..rest] -> Ok(#(WitS8, rest))
    [Ident("s16"), ..rest] -> Ok(#(WitS16, rest))
    [Ident("s32"), ..rest] -> Ok(#(WitS32, rest))
    [Ident("s64"), ..rest] -> Ok(#(WitS64, rest))
    [Ident("u8"), ..rest] -> Ok(#(WitU8, rest))
    [Ident("u16"), ..rest] -> Ok(#(WitU16, rest))
    [Ident("u32"), ..rest] -> Ok(#(WitU32, rest))
    [Ident("u64"), ..rest] -> Ok(#(WitU64, rest))
    [Ident("f32"), ..rest] -> Ok(#(WitF32, rest))
    [Ident("f64"), ..rest] -> Ok(#(WitF64, rest))
    [Ident("char"), ..rest] -> Ok(#(WitChar, rest))
    [Ident("string"), ..rest] -> Ok(#(WitString, rest))

    [Ident("list"), LAngle, ..rest] -> {
      use #(inner, after_inner) <- result.try(parse_type(rest))
      case after_inner {
        [RAngle, ..tail] -> Ok(#(WitList(inner), tail))
        _ -> Error("Expected `>` after `list<...`")
      }
    }

    [Ident("option"), LAngle, ..rest] -> {
      use #(inner, after_inner) <- result.try(parse_type(rest))
      case after_inner {
        [RAngle, ..tail] -> Ok(#(WitOption(inner), tail))
        _ -> Error("Expected `>` after `option<...`")
      }
    }

    [Ident("own"), LAngle, Ident(res_name), RAngle, ..tail] ->
      Ok(#(WitOwn(res_name), tail))

    [Ident("borrow"), LAngle, Ident(res_name), RAngle, ..tail] ->
      Ok(#(WitBorrow(res_name), tail))

    [Ident("tuple"), LAngle, ..rest] -> {
      use #(els, tail) <- result.try(parse_tuple_types(rest, []))
      Ok(#(WitTuple(els), tail))
    }

    [Ident("result"), LAngle, ..rest] -> {
      use #(ok_opt, after_ok) <- result.try(case rest {
        [Ident("_"), ..r] -> Ok(#(None, r))
        _ -> {
          use #(t, r) <- result.try(parse_type(rest))
          Ok(#(Some(t), r))
        }
      })
      case after_ok {
        [RAngle, ..tail] -> Ok(#(WitResult(ok: ok_opt, err: None), tail))
        [Comma, ..after_comma] -> {
          use #(err_ty, after_err) <- result.try(parse_type(after_comma))
          case after_err {
            [RAngle, ..tail] ->
              Ok(#(WitResult(ok: ok_opt, err: Some(err_ty)), tail))
            _ -> Error("Expected `>` after `result<..., ...`")
          }
        }
        _ -> Error("Expected `,` or `>` in `result<...>`")
      }
    }

    [Ident("result"), ..rest] -> Ok(#(WitResult(ok: None, err: None), rest))

    [Ident(name), ..rest] -> Ok(#(WitNamed(name), rest))
    _ -> Error("Expected WIT type")
  }
}

fn parse_tuple_types(
  tokens: List(WitToken),
  rev_acc: List(WitType),
) -> Result(#(List(WitType), List(WitToken)), String) {
  use #(ty, after_ty) <- result.try(parse_type(tokens))
  case after_ty {
    [Comma, ..rest] -> parse_tuple_types(rest, [ty, ..rev_acc])
    [RAngle, ..rest] -> Ok(#(list.reverse([ty, ..rev_acc]), rest))
    _ -> Error("Expected `,` or `>` in `tuple<...>`")
  }
}

fn parse_world_body(
  tokens: List(WitToken),
  pkg: WitPackageId,
  world_name: String,
) -> Result(#(WitWorld, List(WitToken)), String) {
  parse_world_items(tokens, pkg, world_name, [])
}

fn parse_world_items(
  tokens: List(WitToken),
  pkg: WitPackageId,
  world_name: String,
  items: List(WitWorldItem),
) -> Result(#(WitWorld, List(WitToken)), String) {
  case tokens {
    [RBrace, ..rest] ->
      Ok(#(WitWorld(pkg:, name: world_name, items: list.reverse(items)), rest))

    [Ident("use"), ..rest] -> {
      use #(u, tail) <- result.try(parse_use(rest))
      parse_world_items(tail, pkg, world_name, [WorldUse(u), ..items])
    }

    [Ident("import"), ..rest] -> {
      use #(item, tail) <- result.try(parse_world_port(rest, True))
      parse_world_items(tail, pkg, world_name, [item, ..items])
    }

    [Ident("export"), ..rest] -> {
      use #(item, tail) <- result.try(parse_world_port(rest, False))
      parse_world_items(tail, pkg, world_name, [item, ..items])
    }

    [Ident("include"), ..rest] -> {
      use #(item, tail) <- result.try(parse_world_include(rest))
      parse_world_items(tail, pkg, world_name, [item, ..items])
    }

    [tok, ..] ->
      Error(
        "Unexpected token in world '" <> world_name <> "': " <> token_label(tok),
      )

    [] -> Error("Unterminated world '" <> world_name <> "'")
  }
}

fn parse_world_include(
  tokens: List(WitToken),
) -> Result(#(WitWorldItem, List(WitToken)), String) {
  use #(target, after_ref) <- result.try(parse_interface_ref(tokens))
  case after_ref {
    [Semi, ..tail] -> Ok(#(WorldInclude(target:, with_renames: []), tail))
    [Ident("with"), LBrace, ..rest] -> {
      use #(renames, after_renames) <- result.try(parse_include_with(rest, []))
      case after_renames {
        [Semi, ..tail] ->
          Ok(#(WorldInclude(target:, with_renames: renames), tail))
        _ -> Ok(#(WorldInclude(target:, with_renames: renames), after_renames))
      }
    }
    _ -> Error("Expected `;` or `with { ... }` after `include` target")
  }
}

fn parse_include_with(
  tokens: List(WitToken),
  rev_acc: List(#(String, String)),
) -> Result(#(List(#(String, String)), List(WitToken)), String) {
  case tokens {
    [RBrace, ..rest] -> Ok(#(list.reverse(rev_acc), rest))
    [Ident(from), Ident("as"), Ident(to), Comma, ..rest] ->
      parse_include_with(rest, [#(from, to), ..rev_acc])
    [Ident(from), Ident("as"), Ident(to), RBrace, ..rest] ->
      Ok(#(list.reverse([#(from, to), ..rev_acc]), rest))
    _ -> Error("Malformed `include ... with { ... }` clause")
  }
}

fn parse_world_port(
  tokens: List(WitToken),
  is_import: Bool,
) -> Result(#(WitWorldItem, List(WitToken)), String) {
  case tokens {
    [Ident(fn_name), Colon, Ident("func"), LParen, ..rest] -> {
      use #(f, tail) <- result.try(parse_func_sig(fn_name, rest))
      let item = case is_import {
        True -> WorldImportFunc(f)
        False -> WorldExportFunc(f)
      }
      Ok(#(item, tail))
    }
    _ -> {
      use #(iface_ref, after_ref) <- result.try(parse_interface_ref(tokens))
      case after_ref {
        [Semi, ..tail] -> {
          let item = case is_import {
            True -> WorldImportIface(iface_ref)
            False -> WorldExportIface(iface_ref)
          }
          Ok(#(item, tail))
        }
        _ -> Error("Expected `;` after world import/export interface")
      }
    }
  }
}

fn token_label(tok: WitToken) -> String {
  case tok {
    Ident(s) -> s
    Arrow -> "->"
    Colon -> ":"
    Semi -> ";"
    Comma -> ","
    Dot -> "."
    LBrace -> "{"
    RBrace -> "}"
    LParen -> "("
    RParen -> ")"
    LAngle -> "<"
    RAngle -> ">"
    Equals -> "="
    At -> "@"
    Slash -> "/"
  }
}
