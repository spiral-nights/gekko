import filepath
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import index/symbol_table.{type SymbolTable}
import lower/ir.{type IrModule}
import lower/ir_util
import lower/mangle
import project/analysis.{type ProjectAnalysis}
import project/fs
import project/prepass.{type PrepassResult}
import simplifile
import tom

type GleamRenderState {
  GleamRenderState(alias_map: Dict(String, String), used_aliases: Set(String))
}

type MirrorRenderContext {
  MirrorRenderContext(
    target_mod: String,
    mirror_mod: String,
    mirrored_types: Set(String),
  )
}

/// Regenerate all `//// @patch_mirror(...)` files found under `<project_root>/src/`.
pub fn sync_mirrors(
  project_root: String,
  ws: ProjectAnalysis,
) -> Result(String, String) {
  let src_dir = filepath.join(project_root, "src")
  use rel_paths <- result.try(case simplifile.is_directory(src_dir) {
    Ok(True) -> collect_gleam_paths(src_dir, "")
    _ -> Ok([])
  })
  let mirror_entries =
    list.filter_map(list.sort(rel_paths, string.compare), fn(rel) {
      let mod_name = filepath.strip_extension(rel)
      let full = filepath.join(src_dir, rel)
      case simplifile.read(from: full) {
        Ok(src) -> {
          let res = prepass.preprocess_module(mod_name, src)
          case res.patch_mirror {
            Some(info) -> Ok(#(rel, full, info))
            None -> Error(Nil)
          }
        }
        Error(_) -> Error(Nil)
      }
    })

  case mirror_entries {
    [] -> Ok("No @patch_mirror files found in " <> src_dir <> ".")
    _ -> {
      let allowed_pkgs =
        read_allowed_gleam_packages(project_root, ws.project_name)
      use #(rev_updated, rev_unchanged) <- result.try(
        list.try_fold(mirror_entries, #([], []), fn(acc, entry) {
          let #(upd, unch) = acc
          let #(_rel, full, info) = entry
          let #(target_pkg_opt, target_mod_name) = case
            string.split_once(info.target, ":")
          {
            Ok(#(p, m)) -> #(Some(p), m)
            Error(_) -> #(None, info.target)
          }
          use ir_mod <- result.try(
            list.find(ws.ir_modules, fn(m) { m.module_name == target_mod_name })
            |> result.map_error(fn(_) {
              "Cannot sync mirror '"
              <> full
              <> "': target module '"
              <> info.target
              <> "' was not found in loaded packages"
            }),
          )
          let target_pkg = case target_pkg_opt {
            Some(p) -> p
            None ->
              dict.get(ws.module_pkg_by_name, target_mod_name)
              |> result.unwrap("")
          }
          let ast_mod_opt = find_ast_module(ws.all_modules, target_mod_name)
          case
            render_upstream_mirror(
              ws,
              target_pkg,
              ir_mod,
              ast_mod_opt,
              allowed_pkgs,
            )
          {
            Some(new_content) -> {
              let changed = simplifile.read(from: full) != Ok(new_content)
              use _ <- result.try(fs.write_text_if_changed(full, new_content))
              case changed {
                True -> Ok(#([full, ..upd], unch))
                False -> Ok(#(upd, [full, ..unch]))
              }
            }
            None ->
              Ok(#(upd, [full <> " (no mirrorable declarations)", ..unch]))
          }
        }),
      )
      let lines = case list.reverse(rev_updated) {
        [] -> ["All @patch_mirror files are already up to date:"]
        upds ->
          list.append(
            ["Updated @patch_mirror file(s):"],
            list.map(upds, fn(p) { "  " <> p }),
          )
      }
      let unch_lines = case list.reverse(rev_unchanged) {
        [] -> []
        unch ->
          list.append(
            ["Unchanged @patch_mirror file(s):"],
            list.map(unch, fn(p) { "  " <> p }),
          )
      }
      Ok(string.join(list.append(lines, unch_lines), "\n"))
    }
  }
}

pub fn render_new_gleam_shim_files(
  ws: ProjectAnalysis,
  shim_name: String,
  target_pkg: String,
  target_ir_mods: List(IrModule),
) -> List(#(String, String)) {
  let allowed_pkgs = set.from_list(["", "gleam", shim_name, target_pkg])
  target_ir_mods
  |> list.flat_map(fn(ir_mod) {
    let missing_fns = list.filter(ir_mod.functions, ir_util.needs_shim)
    case missing_fns {
      [] -> []
      _ -> {
        let ast_mod_opt = find_ast_module(ws.all_modules, ir_mod.module_name)
        let mirror_mod =
          shim_name <> "/internal/upstream/" <> ir_mod.module_name
        let mirrored_types = mirrored_type_names_for_mod(ir_mod)
        let mirror_ctx =
          Some(MirrorRenderContext(
            target_mod: ir_mod.module_name,
            mirror_mod:,
            mirrored_types:,
          ))
        let mirror_opt =
          render_upstream_mirror(
            ws,
            target_pkg,
            ir_mod,
            ast_mod_opt,
            allowed_pkgs,
          )
        let init_st = GleamRenderState(dict.new(), set.new())
        let #(_, blocks_rev, final_st) =
          list.fold(missing_fns, #(set.new(), [], init_st), fn(acc, ir_fn) {
            let #(used_names, b_acc, st) = acc
            let target_str = ir_mod.module_name <> "." <> ir_fn.unmangled_name
            let #(local_name, next_used) =
              pick_gleam_fn_name(ir_fn.unmangled_name, used_names, 0)
            let #(block, next_st) =
              render_gleam_fn_stub(
                ir_fn,
                local_name,
                target_str,
                ir_mod.module_name,
                ws.table,
                mirror_ctx,
                st,
              )
            #(next_used, [block, ..b_acc], next_st)
          })
        let imports_block =
          render_gleam_import_lines(final_st.alias_map, set.new())
        let body = case imports_block {
          [] -> string.join(list.reverse(blocks_rev), "\n\n") <> "\n"
          _ ->
            string.join(imports_block, "\n")
            <> "\n\n"
            <> string.join(list.reverse(blocks_rev), "\n\n")
            <> "\n"
        }
        let shim_file = #(
          "src/" <> shim_name <> "/" <> ir_mod.module_name <> ".gleam",
          body,
        )
        case mirror_opt {
          Some(mirror_src) -> [
            #("src/" <> mirror_mod <> ".gleam", mirror_src),
            shim_file,
          ]
          None -> [shim_file]
        }
      }
    }
  })
}

pub fn append_gleam_fns_for_module(
  project_root: String,
  ws: ProjectAnalysis,
  mod_name: String,
  target_fns: List(ir.IrFunction),
) -> Result(String, String) {
  let rel_mod = ws.project_name <> "/shims/" <> mod_name
  let target_path = filepath.join(project_root, "src/" <> rel_mod <> ".gleam")
  let existing = case simplifile.read(from: target_path) {
    Ok(c) -> c
    Error(_) -> ""
  }
  let pre = prepass.preprocess_module(rel_mod, existing)
  let existing_targets =
    list.fold(pre.gleam_patches, set.new(), fn(acc, entry) {
      let short = case string.split_once(entry.target, ":") {
        Ok(#(_, rhs)) -> rhs
        Error(_) -> entry.target
      }
      acc |> set.insert(entry.target) |> set.insert(short)
    })

  let #(existing_imports, init_st, existing_fn_names) =
    parse_existing_gleam_file_state(existing, pre)

  let mirror_mod = ws.project_name <> "/internal/upstream/" <> mod_name
  let ir_mod_opt =
    list.find(ws.ir_modules, fn(m) { m.module_name == mod_name })
    |> option.from_result
  let mirror_ctx = case ir_mod_opt {
    Some(ir_mod) ->
      Some(MirrorRenderContext(
        target_mod: mod_name,
        mirror_mod:,
        mirrored_types: mirrored_type_names_for_mod(ir_mod),
      ))
    None -> None
  }

  let maybe_write_mirror = case ir_mod_opt {
    None -> Ok(None)
    Some(ir_mod) -> {
      let target_pkg =
        dict.get(ws.module_pkg_by_name, mod_name) |> result.unwrap("")
      let allowed_pkgs =
        read_allowed_gleam_packages(project_root, ws.project_name)
        |> set.insert(target_pkg)
      let ast_mod_opt = find_ast_module(ws.all_modules, mod_name)
      case
        render_upstream_mirror(
          ws,
          target_pkg,
          ir_mod,
          ast_mod_opt,
          allowed_pkgs,
        )
      {
        None -> Ok(None)
        Some(mirror_src) -> {
          let mirror_path =
            filepath.join(project_root, "src/" <> mirror_mod <> ".gleam")
          use _ <- result.try(fs.write_text_if_changed(mirror_path, mirror_src))
          Ok(Some(mirror_path))
        }
      }
    }
  }
  use written_mirror_opt <- result.try(maybe_write_mirror)

  let #(_, rev_blocks, added_names, final_st) =
    list.fold(target_fns, #(existing_fn_names, [], [], init_st), fn(acc, ir_fn) {
      let #(used_names, b_acc, n_acc, st) = acc
      let target_str =
        gleam_patch_target_string(ws, mod_name, ir_fn.unmangled_name)
      let short_key = mod_name <> "." <> ir_fn.unmangled_name
      case
        set.contains(existing_targets, target_str)
        || set.contains(existing_targets, short_key)
      {
        True -> acc
        False -> {
          let #(local_name, next_used) =
            pick_gleam_fn_name(ir_fn.unmangled_name, used_names, 0)
          let #(block, next_st) =
            render_gleam_fn_stub(
              ir_fn,
              local_name,
              target_str,
              mod_name,
              ws.table,
              mirror_ctx,
              st,
            )
          #(
            next_used,
            [block, ..b_acc],
            [mod_name <> "." <> ir_fn.unmangled_name, ..n_acc],
            next_st,
          )
        }
      }
    })

  case rev_blocks {
    [] -> Ok("Already patched in " <> target_path <> " (0 changes).")
    _ -> {
      let new_import_lines =
        render_gleam_import_lines(final_st.alias_map, existing_imports)
      let with_imports = insert_gleam_imports(existing, new_import_lines)
      let sep = case with_imports {
        "" -> ""
        _ ->
          case
            string.ends_with(with_imports, "\n\n"),
            string.ends_with(with_imports, "\n")
          {
            True, _ -> ""
            False, True -> "\n"
            False, False -> "\n\n"
          }
      }
      let blocks_str = string.join(list.reverse(rev_blocks), "\n\n")
      let next_content = with_imports <> sep <> blocks_str <> "\n"
      use _ <- result.try(fs.write_text(target_path, next_content))
      let mirror_note = case written_mirror_opt {
        Some(mp) -> " (mirror: " <> mp <> ")"
        None -> ""
      }
      Ok(
        "Scaffolded into "
        <> target_path
        <> ": "
        <> string.join(list.reverse(added_names), ", ")
        <> mirror_note,
      )
    }
  }
}

pub fn append_gleam_type_for_module(
  project_root: String,
  ws: ProjectAnalysis,
  mod_name: String,
  td: ir.IrTypeDef,
) -> Result(String, String) {
  let rel_mod = ws.project_name <> "/shims/" <> mod_name
  let target_path = filepath.join(project_root, "src/" <> rel_mod <> ".gleam")
  let existing = case simplifile.read(from: target_path) {
    Ok(c) -> c
    Error(_) -> ""
  }
  let pre = prepass.preprocess_module(rel_mod, existing)
  let target_str = gleam_patch_target_string(ws, mod_name, td.unmangled_name)
  let short_key = mod_name <> "." <> td.unmangled_name
  let already_patched =
    list.any(pre.gleam_type_patches, fn(entry) {
      entry.target == target_str || entry.target == short_key
    })
  case already_patched {
    True -> Ok("Already patched in " <> target_path <> " (0 changes).")
    False -> {
      let params_str = case td.type_params {
        [] -> ""
        ps -> "(" <> string.join(list.map(ps, string.lowercase), ", ") <> ")"
      }
      let block =
        "/// @patch_type(\""
        <> target_str
        <> "\")\npub type "
        <> td.unmangled_name
        <> params_str
        <> " {\n  "
        <> td.unmangled_name
        <> "\n}"
      let sep = case existing {
        "" -> ""
        _ ->
          case
            string.ends_with(existing, "\n\n"),
            string.ends_with(existing, "\n")
          {
            True, _ -> ""
            False, True -> "\n"
            False, False -> "\n\n"
          }
      }
      use _ <- result.try(fs.write_text(
        target_path,
        existing <> sep <> block <> "\n",
      ))
      Ok(
        "Scaffolded into "
        <> target_path
        <> ": "
        <> mod_name
        <> "."
        <> td.unmangled_name,
      )
    }
  }
}

fn collect_gleam_paths(
  base_dir: String,
  rel_prefix: String,
) -> Result(List(String), String) {
  let current = case rel_prefix {
    "" -> base_dir
    _ -> filepath.join(base_dir, rel_prefix)
  }
  use entries <- result.try(
    simplifile.read_directory(at: current)
    |> result.map_error(fn(err) {
      "Failed to read directory '"
      <> current
      <> "': "
      <> simplifile.describe_error(err)
    }),
  )
  list.try_fold(entries, [], fn(acc, entry) {
    case fs.is_ignored_entry(entry) {
      True -> Ok(acc)
      False -> {
        let rel = case rel_prefix {
          "" -> entry
          _ -> filepath.join(rel_prefix, entry)
        }
        let full = filepath.join(base_dir, rel)
        case simplifile.is_directory(full) {
          Ok(True) -> {
            use nested <- result.try(collect_gleam_paths(base_dir, rel))
            Ok(list.append(acc, nested))
          }
          Ok(False) ->
            case string.ends_with(entry, ".gleam") {
              True -> Ok([rel, ..acc])
              False -> Ok(acc)
            }
          Error(err) ->
            Error(
              "Failed to stat '"
              <> full
              <> "': "
              <> simplifile.describe_error(err),
            )
        }
      }
    }
  })
}

fn read_allowed_gleam_packages(
  project_root: String,
  project_name: String,
) -> Set(String) {
  let base = set.from_list(["", "gleam", project_name])
  let toml_path = filepath.join(project_root, "gleam.toml")
  case simplifile.read(from: toml_path) {
    Error(_) -> base
    Ok(content) ->
      case tom.parse(content) {
        Error(_) -> base
        Ok(parsed) -> {
          let add_table_keys = fn(acc, path) {
            case tom.get_table(parsed, path) {
              Ok(tbl) -> list.fold(dict.keys(tbl), acc, set.insert)
              Error(_) -> acc
            }
          }
          base
          |> add_table_keys(["dependencies"])
          |> add_table_keys(["dev-dependencies"])
        }
      }
  }
}

fn find_ast_module(
  all_modules: List(#(String, String, glance.Module, PrepassResult)),
  mod_name: String,
) -> Option(glance.Module) {
  list.find(all_modules, fn(entry) { entry.1 == mod_name })
  |> option.from_result
  |> option.map(fn(entry) { entry.2 })
}

fn mirrored_type_names_for_mod(ir_mod: IrModule) -> Set(String) {
  let from_types =
    list.fold(ir_mod.types, set.new(), fn(acc, td) {
      case
        td.publicity == glance.Private || { td.opaque_ && td.variants != [] }
      {
        True -> set.insert(acc, td.unmangled_name)
        False -> acc
      }
    })
  list.fold(ir_mod.type_aliases, from_types, fn(acc, ta) {
    case ta.publicity == glance.Private {
      True -> set.insert(acc, ta.name)
      False -> acc
    }
  })
}

fn gleam_patch_target_string(
  ws: ProjectAnalysis,
  mod_name: String,
  decl_unmangled_name: String,
) -> String {
  let mod_pkg = dict.get(ws.module_pkg_by_name, mod_name) |> result.unwrap("")
  let use_short = case ws.root_overlay.shim {
    Some(meta) if meta.target == mod_pkg -> True
    _ -> False
  }
  case use_short || mod_pkg == "" {
    True -> mod_name <> "." <> decl_unmangled_name
    False -> mod_pkg <> ":" <> mod_name <> "." <> decl_unmangled_name
  }
}

fn parse_existing_gleam_file_state(
  existing: String,
  pre: PrepassResult,
) -> #(Set(String), GleamRenderState, Set(String)) {
  case existing {
    "" -> #(set.new(), GleamRenderState(dict.new(), set.new()), set.new())
    _ ->
      case glance.module(pre.cleaned_source) {
        Error(_) -> #(
          set.new(),
          GleamRenderState(dict.new(), set.new()),
          set.new(),
        )
        Ok(ast) -> {
          let #(imp_mods, alias_map, used_aliases) =
            list.fold(
              ast.imports,
              #(set.new(), dict.new(), set.new()),
              fn(acc, def) {
                let #(mods, am, ua) = acc
                let imp = def.definition
                case imp.alias {
                  Some(glance.Discarded(_)) -> acc
                  Some(glance.Named(a)) -> #(
                    set.insert(mods, imp.module),
                    dict.insert(am, imp.module, a),
                    set.insert(ua, a),
                  )
                  None -> {
                    let base = filepath.base_name(imp.module)
                    #(
                      set.insert(mods, imp.module),
                      dict.insert(am, imp.module, base),
                      set.insert(ua, base),
                    )
                  }
                }
              },
            )
          let fn_names =
            list.fold(ast.functions, set.new(), fn(acc, def) {
              set.insert(acc, def.definition.name)
            })
          #(imp_mods, GleamRenderState(alias_map, used_aliases), fn_names)
        }
      }
  }
}

fn pick_gleam_fn_name(
  base: String,
  used: Set(String),
  attempt: Int,
) -> #(String, Set(String)) {
  let candidate = case attempt {
    0 -> base
    1 -> base <> "_impl"
    _ -> base <> "_impl_" <> int.to_string(attempt)
  }
  case set.contains(used, candidate) {
    False -> #(candidate, set.insert(used, candidate))
    True -> pick_gleam_fn_name(base, used, attempt + 1)
  }
}

fn render_gleam_fn_stub(
  ir_fn: ir.IrFunction,
  local_name: String,
  patch_target: String,
  mod_name: String,
  table: SymbolTable,
  mirror_ctx: Option(MirrorRenderContext),
  st: GleamRenderState,
) -> #(String, GleamRenderState) {
  let #(#(rev_params, st1), _) =
    list.index_fold(ir_fn.params, #(#([], st), 0), fn(acc, p, idx) {
      let #(#(ps, cur_st), _) = acc
      let #(ty_str, next_st) =
        render_gleam_type(p.param_type, mod_name, table, mirror_ctx, cur_st)
      let p_name = case p.name {
        "_" -> "_arg_" <> int.to_string(idx)
        n -> n
      }
      #(#([p_name <> ": " <> ty_str, ..ps], next_st), idx + 1)
    })
  let #(ret_str, st2) =
    render_gleam_type(ir_fn.return_type, mod_name, table, mirror_ctx, st1)
  let params_str = string.join(list.reverse(rev_params), ", ")
  let block =
    "/// @patch(\""
    <> patch_target
    <> "\")\npub fn "
    <> local_name
    <> "("
    <> params_str
    <> ") -> "
    <> ret_str
    <> " {\n  todo\n}"
  #(block, st2)
}

fn render_gleam_type(
  ty: ir.IrType,
  cur_mod: String,
  table: SymbolTable,
  mirror_ctx: Option(MirrorRenderContext),
  st: GleamRenderState,
) -> #(String, GleamRenderState) {
  case ty {
    ir.IrTypeInt64 -> #("Int", st)
    ir.IrTypeDouble -> #("Float", st)
    ir.IrTypeString -> #("String", st)
    ir.IrTypeBool -> #("Bool", st)
    ir.IrTypeUnit -> #("Nil", st)
    ir.IrTypeBitArray -> #("BitArray", st)
    ir.IrTypeVar(v) -> #(string.lowercase(v), st)
    ir.IrTypeList(inner) -> {
      let #(in_str, st1) =
        render_gleam_type(inner, cur_mod, table, mirror_ctx, st)
      #("List(" <> in_str <> ")", st1)
    }
    ir.IrTypeResult(ok_t, err_t) -> {
      let #(o_str, st1) =
        render_gleam_type(ok_t, cur_mod, table, mirror_ctx, st)
      let #(e_str, st2) =
        render_gleam_type(err_t, cur_mod, table, mirror_ctx, st1)
      #("Result(" <> o_str <> ", " <> e_str <> ")", st2)
    }
    ir.IrTypeTuple(els) -> {
      let #(rev_s, st1) =
        list.fold(els, #([], st), fn(acc, el) {
          let #(es, c_st) = acc
          let #(s, n_st) =
            render_gleam_type(el, cur_mod, table, mirror_ctx, c_st)
          #([s, ..es], n_st)
        })
      #("#(" <> string.join(list.reverse(rev_s), ", ") <> ")", st1)
    }
    ir.IrTypeFn(params, ret) -> {
      let #(rev_s, st1) =
        list.fold(params, #([], st), fn(acc, p) {
          let #(ps, c_st) = acc
          let #(s, n_st) =
            render_gleam_type(p, cur_mod, table, mirror_ctx, c_st)
          #([s, ..ps], n_st)
        })
      let #(r_str, st2) =
        render_gleam_type(ret, cur_mod, table, mirror_ctx, st1)
      #(
        "fn(" <> string.join(list.reverse(rev_s), ", ") <> ") -> " <> r_str,
        st2,
      )
    }
    ir.IrTypeNamed(module:, name:, args:, ..) -> {
      let resolved_mod = case module {
        "" -> cur_mod
        m -> m
      }
      case resolved_mod, name {
        "gleam", "UtfCodepoint" -> #("UtfCodepoint", st)
        "gleam", "Dynamic" -> {
          let #(alias, st1) = register_gleam_import("gleam/dynamic", st)
          #(alias <> ".Dynamic", st1)
        }
        _, _ -> {
          let #(unmangled_name, _is_priv) =
            lookup_gleam_type_info(table, resolved_mod, name)
          let #(alias, st1) = case mirror_ctx {
            Some(mc) if resolved_mod == mc.target_mod ->
              case set.contains(mc.mirrored_types, unmangled_name) {
                True -> register_gleam_import_as(mc.mirror_mod, "upstream", st)
                False -> register_gleam_import(resolved_mod, st)
              }
            _ -> register_gleam_import(resolved_mod, st)
          }
          let #(rev_args, st2) =
            list.fold(args, #([], st1), fn(acc, arg) {
              let #(as_acc, c_st) = acc
              let #(s, n_st) =
                render_gleam_type(arg, cur_mod, table, mirror_ctx, c_st)
              #([s, ..as_acc], n_st)
            })
          let suffix = case args {
            [] -> ""
            _ -> "(" <> string.join(list.reverse(rev_args), ", ") <> ")"
          }
          #(alias <> "." <> unmangled_name <> suffix, st2)
        }
      }
    }
  }
}

fn register_gleam_import_as(
  mod_name: String,
  preferred_alias: String,
  st: GleamRenderState,
) -> #(String, GleamRenderState) {
  case dict.get(st.alias_map, mod_name) {
    Ok(existing) -> #(existing, st)
    Error(_) -> {
      let chosen = pick_unique_gleam_alias(preferred_alias, st.used_aliases, 0)
      #(
        chosen,
        GleamRenderState(
          alias_map: dict.insert(st.alias_map, mod_name, chosen),
          used_aliases: set.insert(st.used_aliases, chosen),
        ),
      )
    }
  }
}

fn render_upstream_mirror(
  ws: ProjectAnalysis,
  target_pkg: String,
  ir_mod: IrModule,
  ast_mod_opt: Option(glance.Module),
  allowed_pkgs: Set(String),
) -> Option(String) {
  let mirrored_names = mirrored_type_names_for_mod(ir_mod)
  let init_st = GleamRenderState(alias_map: dict.new(), used_aliases: set.new())

  let #(type_blocks, st1) =
    list.fold(ir_mod.types, #([], init_st), fn(acc, td) {
      let #(blocks, st) = acc
      case
        td.publicity == glance.Private || { td.opaque_ && td.variants != [] }
      {
        False -> acc
        True -> {
          let attr = case td.publicity == glance.Private {
            True -> "/// @mirror_type(\"" <> td.unmangled_name <> "\")"
            False -> "/// @mirror_opaque(\"" <> td.unmangled_name <> "\")"
          }
          let params = case td.type_params {
            [] -> ""
            ps ->
              "(" <> string.join(list.map(ps, string.lowercase), ", ") <> ")"
          }
          let variants_res =
            list.try_fold(td.variants, #([], st), fn(v_acc, v) {
              let #(v_lines, cur_st) = v_acc
              case v.fields {
                [] -> Ok(#(["  " <> v.name, ..v_lines], cur_st))
                _ -> {
                  use #(rev_fields, next_st) <- result.try(
                    list.try_fold(v.fields, #([], cur_st), fn(f_acc, fld) {
                      let #(f_strs, fst) = f_acc
                      use #(ty_s, n_fst) <- result.try(render_mirror_type(
                        fld.field_type,
                        ir_mod.module_name,
                        ws,
                        mirrored_names,
                        allowed_pkgs,
                        fst,
                      ))
                      let f_str = case fld.unmangled_label {
                        Some(lbl) -> lbl <> ": " <> ty_s
                        None -> ty_s
                      }
                      Ok(#([f_str, ..f_strs], n_fst))
                    }),
                  )
                  Ok(#(
                    [
                      "  "
                        <> v.name
                        <> "("
                        <> string.join(list.reverse(rev_fields), ", ")
                        <> ")",
                      ..v_lines
                    ],
                    next_st,
                  ))
                }
              }
            })
          case variants_res {
            Error(skip_reason) -> {
              let msg =
                "// Skipped "
                <> td.unmangled_name
                <> ": references unavailable dependency ("
                <> skip_reason
                <> ")"
              #([msg, ..blocks], st)
            }
            Ok(#([], next_st)) -> {
              let blk = attr <> "\npub type " <> td.unmangled_name <> params
              #([blk, ..blocks], next_st)
            }
            Ok(#(rev_vlines, next_st)) -> {
              let blk =
                attr
                <> "\npub type "
                <> td.unmangled_name
                <> params
                <> " {\n"
                <> string.join(list.reverse(rev_vlines), "\n")
                <> "\n}"
              #([blk, ..blocks], next_st)
            }
          }
        }
      }
    })

  let #(alias_blocks, st2) =
    list.fold(ir_mod.type_aliases, #(type_blocks, st1), fn(acc, ta) {
      let #(blocks, st) = acc
      case ta.publicity == glance.Private {
        False -> acc
        True -> {
          let params = case ta.type_params {
            [] -> ""
            ps ->
              "(" <> string.join(list.map(ps, string.lowercase), ", ") <> ")"
          }
          case
            render_mirror_type(
              ta.aliased,
              ir_mod.module_name,
              ws,
              mirrored_names,
              allowed_pkgs,
              st,
            )
          {
            Error(skip_reason) -> #(
              [
                "// Skipped alias "
                  <> ta.name
                  <> ": references unavailable dependency ("
                  <> skip_reason
                  <> ")",
                ..blocks
              ],
              st,
            )
            Ok(#(rhs_str, next_st)) -> {
              let blk =
                "/// @mirror_type(\""
                <> ta.name
                <> "\")\npub type "
                <> ta.name
                <> params
                <> " = "
                <> rhs_str
              #([blk, ..blocks], next_st)
            }
          }
        }
      }
    })

  let used_local_fns =
    list.fold(ir_mod.functions, set.new(), fn(acc, f) {
      case f.publicity == glance.Private {
        True -> set.insert(acc, f.unmangled_name)
        False -> acc
      }
    })

  let #(_, opaque_blocks, st3) =
    list.fold(ir_mod.types, #(used_local_fns, alias_blocks, st2), fn(acc, td) {
      let #(used_names, blocks, st) = acc
      case td.publicity == glance.Public && td.opaque_ && td.variants != [] {
        False -> acc
        True -> {
          let snake = camel_to_snake(td.unmangled_name)
          let #(to_name, used1) =
            pick_gleam_fn_name("to_" <> snake, used_names, 0)
          let #(from_name, used2) =
            pick_gleam_fn_name("from_" <> snake, used1, 0)
          let target_base = "target_" <> filepath.base_name(ir_mod.module_name)
          let #(target_alias, st_imp) =
            register_gleam_import_as(ir_mod.module_name, target_base, st)
          let suffix = case td.type_params {
            [] -> ""
            ps ->
              "(" <> string.join(list.map(ps, string.lowercase), ", ") <> ")"
          }
          let local_ty = td.unmangled_name <> suffix
          let pub_ty = target_alias <> "." <> td.unmangled_name <> suffix
          let to_blk =
            "/// @mirror_to_public(\""
            <> td.unmangled_name
            <> "\")\npub fn "
            <> to_name
            <> "(value: "
            <> local_ty
            <> ") -> "
            <> pub_ty
            <> " {\n  let _ = value\n  panic as \"gekko @patch_mirror stub\"\n}"
          let from_blk =
            "/// @mirror_from_public(\""
            <> td.unmangled_name
            <> "\")\npub fn "
            <> from_name
            <> "(value: "
            <> pub_ty
            <> ") -> "
            <> local_ty
            <> " {\n  let _ = value\n  panic as \"gekko @patch_mirror stub\"\n}"
          #(used2, [from_blk, to_blk, ..blocks], st_imp)
        }
      }
    })

  let #(const_blocks, st4) =
    list.fold(ir_mod.constants, #(opaque_blocks, st3), fn(acc, c) {
      let #(blocks, st) = acc
      case c.publicity == glance.Private {
        False -> acc
        True ->
          case
            render_mirror_type(
              c.value_type,
              ir_mod.module_name,
              ws,
              mirrored_names,
              allowed_pkgs,
              st,
            )
          {
            Error(skip_reason) -> #(
              [
                "// Skipped private const "
                  <> c.unmangled_name
                  <> ": references unavailable dependency ("
                  <> skip_reason
                  <> ")",
                ..blocks
              ],
              st,
            )
            Ok(#(ty_str, next_st)) -> {
              let blk = case render_mirror_dummy_const(c.value_type) {
                Some(dummy) ->
                  "/// @mirror_const(\""
                  <> c.unmangled_name
                  <> "\")\npub const "
                  <> c.unmangled_name
                  <> ": "
                  <> ty_str
                  <> " = "
                  <> dummy
                None ->
                  "/// @mirror_const(\""
                  <> c.unmangled_name
                  <> "\")\npub fn "
                  <> c.unmangled_name
                  <> "() -> "
                  <> ty_str
                  <> " {\n  panic as \"gekko @patch_mirror stub\"\n}"
              }
              #([blk, ..blocks], next_st)
            }
          }
      }
    })

  let ast_fn_by_name = case ast_mod_opt {
    Some(ast_mod) ->
      list.fold(ast_mod.functions, dict.new(), fn(acc, def) {
        dict.insert(acc, def.definition.name, def.definition)
      })
    None -> dict.new()
  }

  let #(all_blocks_rev, final_st) =
    list.fold(ir_mod.functions, #(const_blocks, st4), fn(acc, f) {
      let #(blocks, st) = acc
      case f.publicity == glance.Private {
        False -> acc
        True -> {
          let ast_params = case dict.get(ast_fn_by_name, f.unmangled_name) {
            Ok(ast_fn) -> ast_fn.parameters
            Error(_) -> []
          }
          let params_res =
            render_mirror_fn_params(
              f.params,
              ast_params,
              ir_mod.module_name,
              ws,
              mirrored_names,
              allowed_pkgs,
              st,
            )
          case params_res {
            Error(skip_reason) -> #(
              [
                "// Skipped private fn "
                  <> f.unmangled_name
                  <> ": references unavailable dependency ("
                  <> skip_reason
                  <> ")",
                ..blocks
              ],
              st,
            )
            Ok(#(param_strs, bind_stmts, st_after_p)) ->
              case
                render_mirror_type(
                  f.return_type,
                  ir_mod.module_name,
                  ws,
                  mirrored_names,
                  allowed_pkgs,
                  st_after_p,
                )
              {
                Error(skip_reason) -> #(
                  [
                    "// Skipped private fn "
                      <> f.unmangled_name
                      <> ": references unavailable dependency ("
                      <> skip_reason
                      <> ")",
                    ..blocks
                  ],
                  st,
                )
                Ok(#(ret_str, next_st)) -> {
                  let body_lines =
                    list.append(bind_stmts, [
                      "  panic as \"gekko @patch_mirror stub\"",
                    ])
                  let blk =
                    "/// @mirror_fn(\""
                    <> f.unmangled_name
                    <> "\")\npub fn "
                    <> f.unmangled_name
                    <> "("
                    <> string.join(param_strs, ", ")
                    <> ") -> "
                    <> ret_str
                    <> " {\n"
                    <> string.join(body_lines, "\n")
                    <> "\n}"
                  #([blk, ..blocks], next_st)
                }
              }
          }
        }
      }
    })

  case all_blocks_rev {
    [] -> None
    _ -> {
      let target_spec = case target_pkg {
        "" -> ir_mod.module_name
        p -> p <> ":" <> ir_mod.module_name
      }
      let header =
        "//// @patch_mirror(\""
        <> target_spec
        <> "\")\n////\n//// Auto-generated by `gekko shim`. Do not edit manually.\n//// Run `gekko shim sync` if upstream private or opaque declarations change."
      let imports_block =
        render_gleam_import_lines(final_st.alias_map, set.new())
      let sections = case imports_block {
        [] -> [header, ..list.reverse(all_blocks_rev)]
        _ -> [
          header,
          string.join(imports_block, "\n"),
          ..list.reverse(all_blocks_rev)
        ]
      }
      Some(string.join(sections, "\n\n") <> "\n")
    }
  }
}

fn render_mirror_fn_params(
  ir_params: List(ir.IrParam),
  ast_params: List(glance.FunctionParameter),
  cur_mod: String,
  ws: ProjectAnalysis,
  mirrored_names: Set(String),
  allowed_pkgs: Set(String),
  st: GleamRenderState,
) -> Result(#(List(String), List(String), GleamRenderState), String) {
  let has_exact_ast = list.length(ir_params) == list.length(ast_params)
  let paired = case has_exact_ast {
    True ->
      list.zip(ir_params, ast_params)
      |> list.map(fn(p) { #(p.0, Some(p.1)) })
    False -> list.map(ir_params, fn(p) { #(p, None) })
  }
  use #(#(rev_p, rev_b, final_st), _) <- result.try(
    list.try_fold(paired, #(#([], [], st), 0), fn(acc, item) {
      let #(#(p_acc, b_acc, cur_st), idx) = acc
      let #(ip, ap_opt) = item
      use #(ty_str, next_st) <- result.try(render_mirror_type(
        ip.param_type,
        cur_mod,
        ws,
        mirrored_names,
        allowed_pkgs,
        cur_st,
      ))
      let #(sig_name, maybe_bind) = case ap_opt {
        Some(ap) -> {
          let #(local_n, need_bind) = case ap.name {
            glance.Named(n) -> #(n, True)
            glance.Discarded(d) ->
              case d {
                "" -> #("_arg_" <> int.to_string(idx), False)
                _ -> #("_" <> d, False)
              }
          }
          let full_sig = case ap.label {
            Some(lbl) -> lbl <> " " <> local_n
            None -> local_n
          }
          let bind = case need_bind {
            True -> Some("  let _ = " <> local_n)
            False -> None
          }
          #(full_sig, bind)
        }
        None -> {
          let #(local_n, need_bind) = case ip.name {
            "_" -> #("_arg_" <> int.to_string(idx), False)
            n -> #(n, True)
          }
          let full_sig = case ip.label {
            Some(lbl) -> lbl <> " " <> local_n
            None -> local_n
          }
          let bind = case need_bind {
            True -> Some("  let _ = " <> local_n)
            False -> None
          }
          #(full_sig, bind)
        }
      }
      let next_b = case maybe_bind {
        Some(stmt) -> [stmt, ..b_acc]
        None -> b_acc
      }
      Ok(#(#([sig_name <> ": " <> ty_str, ..p_acc], next_b, next_st), idx + 1))
    }),
  )
  Ok(#(list.reverse(rev_p), list.reverse(rev_b), final_st))
}

fn render_mirror_type(
  ty: ir.IrType,
  cur_mod: String,
  ws: ProjectAnalysis,
  mirrored_names: Set(String),
  allowed_pkgs: Set(String),
  st: GleamRenderState,
) -> Result(#(String, GleamRenderState), String) {
  case ty {
    ir.IrTypeInt64 -> Ok(#("Int", st))
    ir.IrTypeDouble -> Ok(#("Float", st))
    ir.IrTypeString -> Ok(#("String", st))
    ir.IrTypeBool -> Ok(#("Bool", st))
    ir.IrTypeUnit -> Ok(#("Nil", st))
    ir.IrTypeBitArray -> Ok(#("BitArray", st))
    ir.IrTypeVar(v) -> Ok(#(string.lowercase(v), st))
    ir.IrTypeList(inner) -> {
      use #(in_str, st1) <- result.try(render_mirror_type(
        inner,
        cur_mod,
        ws,
        mirrored_names,
        allowed_pkgs,
        st,
      ))
      Ok(#("List(" <> in_str <> ")", st1))
    }
    ir.IrTypeResult(ok_t, err_t) -> {
      use #(o_str, st1) <- result.try(render_mirror_type(
        ok_t,
        cur_mod,
        ws,
        mirrored_names,
        allowed_pkgs,
        st,
      ))
      use #(e_str, st2) <- result.try(render_mirror_type(
        err_t,
        cur_mod,
        ws,
        mirrored_names,
        allowed_pkgs,
        st1,
      ))
      Ok(#("Result(" <> o_str <> ", " <> e_str <> ")", st2))
    }
    ir.IrTypeTuple(els) -> {
      use #(rev_s, st1) <- result.try(
        list.try_fold(els, #([], st), fn(acc, el) {
          let #(es, c_st) = acc
          use #(s, n_st) <- result.try(render_mirror_type(
            el,
            cur_mod,
            ws,
            mirrored_names,
            allowed_pkgs,
            c_st,
          ))
          Ok(#([s, ..es], n_st))
        }),
      )
      Ok(#("#(" <> string.join(list.reverse(rev_s), ", ") <> ")", st1))
    }
    ir.IrTypeFn(params, ret) -> {
      use #(rev_s, st1) <- result.try(
        list.try_fold(params, #([], st), fn(acc, p) {
          let #(ps, c_st) = acc
          use #(s, n_st) <- result.try(render_mirror_type(
            p,
            cur_mod,
            ws,
            mirrored_names,
            allowed_pkgs,
            c_st,
          ))
          Ok(#([s, ..ps], n_st))
        }),
      )
      use #(r_str, st2) <- result.try(render_mirror_type(
        ret,
        cur_mod,
        ws,
        mirrored_names,
        allowed_pkgs,
        st1,
      ))
      Ok(#(
        "fn(" <> string.join(list.reverse(rev_s), ", ") <> ") -> " <> r_str,
        st2,
      ))
    }
    ir.IrTypeNamed(module:, name:, args:, ..) -> {
      let resolved_mod = case module {
        "" -> cur_mod
        m -> m
      }
      case resolved_mod, name {
        "gleam", "UtfCodepoint" -> Ok(#("UtfCodepoint", st))
        "gleam", "Dynamic" ->
          case set.contains(allowed_pkgs, "gleam_stdlib") {
            True -> {
              let #(alias, st1) = register_gleam_import("gleam/dynamic", st)
              Ok(#(alias <> ".Dynamic", st1))
            }
            False -> Error("gleam_stdlib")
          }
        _, _ -> {
          let #(unmangled_name, is_priv) =
            lookup_gleam_type_info(ws.table, resolved_mod, name)
          use #(head, st1) <- result.try(case resolved_mod == cur_mod {
            True ->
              case set.contains(mirrored_names, unmangled_name) {
                True -> Ok(#(unmangled_name, st))
                False -> {
                  let target_base = "target_" <> filepath.base_name(cur_mod)
                  let #(alias, s1) =
                    register_gleam_import_as(cur_mod, target_base, st)
                  Ok(#(alias <> "." <> unmangled_name, s1))
                }
              }
            False -> {
              let pkg =
                dict.get(ws.module_pkg_by_name, resolved_mod)
                |> result.unwrap("")
              case set.contains(allowed_pkgs, pkg), is_priv {
                False, _ -> Error(pkg)
                True, True ->
                  Error(
                    "private type " <> resolved_mod <> "." <> unmangled_name,
                  )
                True, False -> {
                  let #(alias, s1) = register_gleam_import(resolved_mod, st)
                  Ok(#(alias <> "." <> unmangled_name, s1))
                }
              }
            }
          })
          use #(rev_args, st2) <- result.try(
            list.try_fold(args, #([], st1), fn(acc, arg) {
              let #(a_acc, c_st) = acc
              use #(s, n_st) <- result.try(render_mirror_type(
                arg,
                cur_mod,
                ws,
                mirrored_names,
                allowed_pkgs,
                c_st,
              ))
              Ok(#([s, ..a_acc], n_st))
            }),
          )
          let suffix = case args {
            [] -> ""
            _ -> "(" <> string.join(list.reverse(rev_args), ", ") <> ")"
          }
          Ok(#(head <> suffix, st2))
        }
      }
    }
  }
}

fn render_mirror_dummy_const(ty: ir.IrType) -> Option(String) {
  case ty {
    ir.IrTypeInt64 -> Some("0")
    ir.IrTypeDouble -> Some("0.0")
    ir.IrTypeString -> Some("\"\"")
    ir.IrTypeBool -> Some("False")
    ir.IrTypeUnit -> Some("Nil")
    ir.IrTypeBitArray -> Some("<<>>")
    ir.IrTypeList(_) -> Some("[]")
    ir.IrTypeTuple(els) -> {
      let parts =
        list.filter_map(els, fn(e) {
          render_mirror_dummy_const(e) |> option.to_result(Nil)
        })
      case list.length(parts) == list.length(els) {
        True -> Some("#(" <> string.join(parts, ", ") <> ")")
        False -> None
      }
    }
    _ -> None
  }
}

fn camel_to_snake(name: String) -> String {
  name
  |> string.to_graphemes
  |> list.index_fold("", fn(acc, ch, idx) {
    let lower = string.lowercase(ch)
    let is_upper = ch != lower && ch == string.uppercase(ch)
    case is_upper && idx > 0 {
      True -> acc <> "_" <> lower
      False -> acc <> lower
    }
  })
}

fn lookup_gleam_type_info(
  table: SymbolTable,
  mod_name: String,
  ir_type_name: String,
) -> #(String, Bool) {
  case dict.get(table.modules, mod_name) {
    Error(_) -> #(ir_type_name, False)
    Ok(ms) ->
      case dict.get(ms.types, ir_type_name) {
        Ok(ti) -> #(ti.name, ti.publicity == glance.Private)
        Error(_) ->
          case
            dict.values(ms.types)
            |> list.find(fn(ti) {
              mangle.mangle_type_name(ti.name) == ir_type_name
            })
          {
            Ok(ti) -> #(ti.name, ti.publicity == glance.Private)
            Error(_) ->
              case dict.get(ms.type_aliases, ir_type_name) {
                Ok(ta) -> #(ta.name, ta.publicity == glance.Private)
                Error(_) ->
                  case
                    dict.values(ms.type_aliases)
                    |> list.find(fn(ta) {
                      mangle.mangle_type_name(ta.name) == ir_type_name
                    })
                  {
                    Ok(ta) -> #(ta.name, ta.publicity == glance.Private)
                    Error(_) -> #(ir_type_name, False)
                  }
              }
          }
      }
  }
}

fn register_gleam_import(
  mod_name: String,
  st: GleamRenderState,
) -> #(String, GleamRenderState) {
  case dict.get(st.alias_map, mod_name) {
    Ok(existing) -> #(existing, st)
    Error(_) -> {
      let base = filepath.base_name(mod_name)
      let chosen = pick_unique_gleam_alias(base, st.used_aliases, 0)
      #(
        chosen,
        GleamRenderState(
          alias_map: dict.insert(st.alias_map, mod_name, chosen),
          used_aliases: set.insert(st.used_aliases, chosen),
        ),
      )
    }
  }
}

fn pick_unique_gleam_alias(
  base: String,
  used: Set(String),
  attempt: Int,
) -> String {
  let candidate = case attempt {
    0 -> base
    _ -> base <> "_" <> int.to_string(attempt + 1)
  }
  case set.contains(used, candidate) {
    False -> candidate
    True -> pick_unique_gleam_alias(base, used, attempt + 1)
  }
}

fn render_gleam_import_lines(
  alias_map: Dict(String, String),
  already_imported: Set(String),
) -> List(String) {
  alias_map
  |> dict.to_list
  |> list.filter(fn(entry) { !set.contains(already_imported, entry.0) })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.map(fn(entry) {
    let #(mod_name, alias) = entry
    let default_alias = filepath.base_name(mod_name)
    case alias == default_alias {
      True -> "import " <> mod_name
      False -> "import " <> mod_name <> " as " <> alias
    }
  })
}

fn insert_gleam_imports(
  existing: String,
  new_import_lines: List(String),
) -> String {
  case new_import_lines {
    [] -> existing
    _ -> {
      let imp_block = string.join(new_import_lines, "\n")
      case existing {
        "" -> imp_block <> "\n"
        _ -> {
          let lines = string.split(existing, "\n")
          let last_imp_idx = find_last_import_line_idx(lines, 0, -1)
          case last_imp_idx {
            -1 -> imp_block <> "\n\n" <> existing
            idx -> {
              let before = list.take(lines, idx + 1)
              let after = list.drop(lines, idx + 1)
              string.join(list.flatten([before, new_import_lines, after]), "\n")
            }
          }
        }
      }
    }
  }
}

fn find_last_import_line_idx(
  lines: List(String),
  idx: Int,
  last_found: Int,
) -> Int {
  case lines {
    [] -> last_found
    [line, ..rest] -> {
      let next_found = case
        string.starts_with(string.trim_start(line), "import ")
      {
        True -> idx
        False -> last_found
      }
      find_last_import_line_idx(rest, idx + 1, next_found)
    }
  }
}
