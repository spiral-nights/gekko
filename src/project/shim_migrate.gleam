import emit/moonbit_decl
import filepath
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import lower/ir.{type IrModule}
import project/fs
import project/patch_discovery
import simplifile

pub fn append_decls_to_module_patch(
  project_root: String,
  mod_name: String,
  decls: List(#(String, String, String)),
) -> Result(String, String) {
  let mod_dir = filepath.join(project_root, "patches/" <> mod_name)
  let user_files = case simplifile.read_directory(at: mod_dir) {
    Ok(entries) ->
      entries
      |> list.filter(fn(e) {
        string.ends_with(e, ".mbt") && !string.ends_with(e, ".g.mbt")
      })
      |> list.sort(string.compare)
    Error(_) -> []
  }

  use #(patched_names, unpatched_by_file) <- result.try(
    list.try_fold(user_files, #(set.new(), []), fn(acc, file) {
      let #(p_set, u_list) = acc
      let full = filepath.join(mod_dir, file)
      use content <- result.try(fs.read_text(full))
      use attrs <- result.try(patch_discovery.parse_mbt_patch_attributes(
        content,
        full,
      ))
      let next_p =
        list.fold(attrs, p_set, fn(s, a) {
          let s1 = set.insert(s, a.mbt_name)
          case a.target_override {
            Some(t) -> {
              let sym = case string.split(t, ".") |> list.last {
                Ok(last) -> last
                Error(_) -> t
              }
              s1 |> set.insert(t) |> set.insert(sym)
            }
            None -> s1
          }
        })
      let unpatched =
        patch_discovery.collect_unpatched_decl_names(content)
        |> set.from_list
      Ok(#(next_p, [#(full, unpatched), ..u_list]))
    }),
  )

  use rev_to_append <- result.try(
    list.try_fold(decls, [], fn(acc, decl) {
      let #(gleam_name, mbt_name, block) = decl
      case
        set.contains(patched_names, gleam_name)
        || set.contains(patched_names, mbt_name)
      {
        True -> Ok(acc)
        False -> {
          let conflict =
            list.find(unpatched_by_file, fn(entry) {
              set.contains(entry.1, gleam_name)
              || set.contains(entry.1, mbt_name)
            })
          case conflict {
            Ok(#(conflict_path, _)) ->
              Error(
                "Declaration '"
                <> gleam_name
                <> "' already exists in '"
                <> conflict_path
                <> "' without #gekko.patch; add #gekko.patch manually or rename it",
              )
            Error(_) -> Ok([#(gleam_name, block), ..acc])
          }
        }
      }
    }),
  )
  let to_append = list.reverse(rev_to_append)

  let canonical = filepath.base_name(mod_name) <> ".mbt"
  let target_filename = case list.contains(user_files, canonical), user_files {
    True, _ -> canonical
    False, [single] -> single
    _, _ -> canonical
  }
  let target_path = filepath.join(mod_dir, target_filename)

  case to_append {
    [] -> Ok("Already patched in " <> target_path <> " (0 changes).")
    _ -> {
      let existing = case simplifile.read(from: target_path) {
        Ok(c) -> c
        Error(_) -> ""
      }
      let blocks_str =
        to_append
        |> list.map(fn(p) { p.1 })
        |> string.join("\n\n")
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
      let next_content = existing <> sep <> blocks_str <> "\n"
      use _ <- result.try(fs.write_text(target_path, next_content))
      let names =
        to_append
        |> list.map(fn(p) { mod_name <> "." <> p.0 })
        |> string.join(", ")
      Ok("Scaffolded into " <> target_path <> ": " <> names)
    }
  }
}

pub fn migrate_single_file_patches(
  patches_dir: String,
  rel_dir: String,
  loaded_mods: Set(String),
  acc: List(#(String, String)),
) -> Result(List(#(String, String)), String) {
  let cur_dir = case rel_dir {
    "" -> patches_dir
    _ -> filepath.join(patches_dir, rel_dir)
  }
  use entries <- result.try(
    simplifile.read_directory(at: cur_dir)
    |> result.map(fn(es) { list.sort(es, string.compare) })
    |> result.map_error(fn(err) {
      "Failed to read '" <> cur_dir <> "': " <> simplifile.describe_error(err)
    }),
  )
  let visible =
    list.filter(entries, fn(e) {
      !fs.is_ignored_entry(e)
      && case rel_dir == "" {
        True -> e != "gprelude" && e != "moon.mod" && e != "moon.lock"
        False -> True
      }
    })
  let moon_pkg_path = filepath.join(cur_dir, "moon.pkg")
  let has_user_moon_pkg =
    list.contains(visible, "moon.pkg")
    && !fs.has_generated_marker(moon_pkg_path)

  use next_acc <- result.try(
    list.try_fold(visible, acc, fn(cur_acc, entry) {
      let full = filepath.join(cur_dir, entry)
      case simplifile.is_directory(full) {
        Ok(True) -> {
          let next_rel = case rel_dir {
            "" -> entry
            _ -> rel_dir <> "/" <> entry
          }
          migrate_single_file_patches(
            patches_dir,
            next_rel,
            loaded_mods,
            cur_acc,
          )
        }
        _ ->
          case
            string.ends_with(entry, ".mbt")
            && !string.ends_with(entry, ".g.mbt")
          {
            False -> Ok(cur_acc)
            True -> {
              let stem = string.drop_end(entry, 4)
              let candidate_mod = case rel_dir {
                "" -> stem
                _ -> rel_dir <> "/" <> stem
              }
              let is_single_file = case rel_dir == "" {
                True -> True
                False ->
                  !has_user_moon_pkg
                  && stem != filepath.base_name(rel_dir)
                  && {
                    set.is_empty(loaded_mods)
                    || set.contains(loaded_mods, candidate_mod)
                    || !set.contains(loaded_mods, rel_dir)
                  }
              }
              case is_single_file {
                False -> Ok(cur_acc)
                True -> {
                  let dst_dir = filepath.join(patches_dir, candidate_mod)
                  let dst_path = filepath.join(dst_dir, entry)
                  use _ <- result.try(case simplifile.is_file(dst_path) {
                    Ok(True) ->
                      Error(
                        "Cannot migrate '"
                        <> full
                        <> "' to '"
                        <> dst_path
                        <> "': destination already exists",
                      )
                    _ -> Ok(Nil)
                  })
                  use content <- result.try(fs.read_text(full))
                  use _ <- result.try(fs.write_text(dst_path, content))
                  use _ <- result.try(
                    simplifile.delete_file(at: full)
                    |> result.map_error(fn(err) {
                      "Failed to remove '"
                      <> full
                      <> "': "
                      <> simplifile.describe_error(err)
                    }),
                  )
                  let rel_src = case rel_dir {
                    "" -> entry
                    _ -> rel_dir <> "/" <> entry
                  }
                  let rel_dst = candidate_mod <> "/" <> entry
                  Ok([#(rel_src, rel_dst), ..cur_acc])
                }
              }
            }
          }
      }
    }),
  )
  Ok(next_acc)
}

pub fn migrate_moon_pkg_imports(
  project_root: String,
  patches_dir: String,
  rel_dir: String,
  pkg_name: String,
  acc: List(String),
) -> Result(List(String), String) {
  let cur_dir = case rel_dir {
    "" -> patches_dir
    _ -> filepath.join(patches_dir, rel_dir)
  }
  use entries <- result.try(
    simplifile.read_directory(at: cur_dir)
    |> result.map(fn(es) { list.sort(es, string.compare) })
    |> result.map_error(fn(err) {
      "Failed to read '" <> cur_dir <> "': " <> simplifile.describe_error(err)
    }),
  )
  let visible =
    list.filter(entries, fn(e) {
      !fs.is_ignored_entry(e)
      && case rel_dir == "" {
        True -> e != "gprelude"
        False -> True
      }
    })
  let moon_pkg_path = filepath.join(cur_dir, "moon.pkg")
  use next_acc <- result.try(
    case
      rel_dir != ""
      && list.contains(visible, "moon.pkg")
      && !fs.has_generated_marker(moon_pkg_path)
    {
      False -> Ok(acc)
      True -> {
        use pkg_src <- result.try(fs.read_text(moon_pkg_path))
        use imports <- result.try(patch_discovery.parse_moon_pkg_imports(
          pkg_src,
          pkg_name,
        ))
        use _ <- result.try(case imports {
          [] -> Ok(Nil)
          _ ->
            append_patch_imports_to_gleam_toml(project_root, rel_dir, imports)
        })
        use _ <- result.try(
          simplifile.delete_file(at: moon_pkg_path)
          |> result.map_error(fn(err) {
            "Failed to delete '"
            <> moon_pkg_path
            <> "': "
            <> simplifile.describe_error(err)
          }),
        )
        Ok([rel_dir, ..acc])
      }
    },
  )

  list.try_fold(visible, next_acc, fn(cur_acc, entry) {
    let full = filepath.join(cur_dir, entry)
    case simplifile.is_directory(full) {
      Ok(True) -> {
        let next_rel = case rel_dir {
          "" -> entry
          _ -> rel_dir <> "/" <> entry
        }
        migrate_moon_pkg_imports(
          project_root,
          patches_dir,
          next_rel,
          pkg_name,
          cur_acc,
        )
      }
      _ -> Ok(cur_acc)
    }
  })
}

fn append_patch_imports_to_gleam_toml(
  project_root: String,
  mod_name: String,
  imports: List(patch_discovery.DiscoveredImport),
) -> Result(Nil, String) {
  let toml_path = filepath.join(project_root, "gleam.toml")
  use content <- result.try(fs.read_text(toml_path))
  let header = "[tools.gekko.patches.\"" <> mod_name <> "\"]"
  case string.contains(content, header) {
    True -> Ok(Nil)
    False -> {
      let items =
        list.map(imports, fn(imp) {
          let spec = case imp.alias {
            Some(a) -> imp.package <> " @" <> a
            None -> imp.package
          }
          "  \"" <> spec <> "\","
        })
        |> string.join("\n")
      let section = "\n" <> header <> "\nimports = [\n" <> items <> "\n]\n"
      let sep = case string.ends_with(content, "\n") {
        True -> ""
        False -> "\n"
      }
      fs.write_text(toml_path, content <> sep <> section)
    }
  }
}

pub fn ensure_empty_or_new_dir(dir: String) -> Result(Nil, String) {
  case simplifile.is_directory(dir) {
    Ok(True) ->
      case simplifile.read_directory(at: dir) {
        Ok([]) -> Ok(Nil)
        Ok(_) ->
          Error(
            "Target shim directory '"
            <> dir
            <> "' already exists and is not empty",
          )
        Error(err) ->
          Error(
            "Failed to inspect directory '"
            <> dir
            <> "': "
            <> simplifile.describe_error(err),
          )
      }
    _ -> Ok(Nil)
  }
}

pub fn render_shim_gleam_toml_section(
  target_pkg: String,
  version: String,
) -> String {
  let ver_constraint = suggest_semver_constraint(version)
  "[tools.gekko.shim_for]\npackage = \""
  <> target_pkg
  <> "\"\nversion = \""
  <> ver_constraint
  <> "\"\n"
}

pub fn render_new_patch_files(
  ir_modules: List(IrModule),
  make_emit_ctx: fn(String) -> moonbit_decl.EmitCtx,
  unmapped_types: List(#(String, String)),
  missing_fns: List(#(String, String, String)),
) -> List(#(String, String)) {
  let mods =
    list.append(
      list.map(unmapped_types, fn(t) { t.0 }),
      list.map(missing_fns, fn(f) { f.0 }),
    )
    |> set.from_list
    |> set.to_list
    |> list.sort(string.compare)

  list.map(mods, fn(mod_name) {
    let type_decls =
      list.filter_map(unmapped_types, fn(t) {
        let #(t_mod, t_name) = t
        case t_mod == mod_name {
          False -> Error(Nil)
          True ->
            case
              list.find(ir_modules, fn(m) { m.module_name == mod_name })
              |> result.try(fn(m) {
                list.find(m.types, fn(td) { td.unmangled_name == t_name })
              })
            {
              Ok(td) -> {
                let emit_ctx = make_emit_ctx(mod_name)
                let #(raw, _) =
                  moonbit_decl.emit_type_def(
                    ir.IrTypeDef(..td, external_type: None),
                    emit_ctx,
                  )
                let block = case raw {
                  "///|\n" <> rest -> "///|\n#gekko.patch\n" <> rest
                  _ -> "///|\n#gekko.patch\n" <> raw
                }
                Ok(block)
              }
              Error(_) -> Error(Nil)
            }
        }
      })
    let fn_decls =
      list.filter_map(missing_fns, fn(f) {
        case f.0 == mod_name {
          False -> Error(Nil)
          True -> Ok(f.2)
        }
      })
    let body = case list.append(type_decls, fn_decls) {
      [] -> "///|\n// Add co-located MoonBit patch implementations here.\n"
      blocks -> string.join(blocks, "\n\n") <> "\n"
    }
    let base_name = filepath.base_name(mod_name)
    #("patches/" <> mod_name <> "/" <> base_name <> ".mbt", body)
  })
}

pub fn split_last_dot(s: String) -> Result(#(String, String), Nil) {
  case string.split(s, ".") |> list.reverse {
    [last, ..rev_rest] if rev_rest != [] && last != "" ->
      Ok(#(rev_rest |> list.reverse |> string.join("."), last))
    _ -> Error(Nil)
  }
}

pub fn suggest_semver_constraint(version: String) -> String {
  case string.split(version, ".") {
    [maj_s, min_s, ..] ->
      case int.parse(maj_s), int.parse(min_s) {
        Ok(0), Ok(min) ->
          ">= 0."
          <> int.to_string(min)
          <> ".0 and < 0."
          <> int.to_string(min + 1)
          <> ".0"
        Ok(maj), _ ->
          ">= "
          <> int.to_string(maj)
          <> ".0.0 and < "
          <> int.to_string(maj + 1)
          <> ".0.0"
        _, _ -> ">= " <> version
      }
    _ -> ">= " <> version
  }
}
