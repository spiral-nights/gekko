import filepath
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import lower/ir.{type IrModule, type IrType, type IrTypeDef}
import project/ffi_config
import project/fs
import simplifile
import tom

const baseline_rel_dir = "patches/.gekko_baseline"

/// Produce a deterministic canonical fingerprint string for an upstream
/// `IrTypeDef` covering publicity, opacity, type-parameter arity, variants,
/// and field labels/types.
pub fn fingerprint_type_def(td: IrTypeDef) -> String {
  let pub_str = case td.publicity {
    glance.Public -> "pub"
    glance.Private -> "priv"
  }
  let opq_str = case td.opaque_ {
    True -> "opaque"
    False -> "transparent"
  }
  let arity_str = int.to_string(list.length(td.type_params))
  let variants_str =
    td.variants
    |> list.map(fn(v) {
      let fields_str =
        v.fields
        |> list.map(fn(f) {
          let lbl = option.unwrap(f.unmangled_label, "_")
          lbl <> ":" <> format_ir_type(f.field_type)
        })
        |> string.join(",")
      v.name <> "(" <> fields_str <> ")"
    })
    |> string.join("|")
  td.unmangled_name
  <> "|"
  <> pub_str
  <> "|"
  <> opq_str
  <> "|"
  <> arity_str
  <> "|["
  <> variants_str
  <> "]"
}

fn format_ir_type(ty: IrType) -> String {
  case ty {
    ir.IrTypeInt64 -> "Int"
    ir.IrTypeDouble -> "Float"
    ir.IrTypeString -> "String"
    ir.IrTypeBool -> "Bool"
    ir.IrTypeUnit -> "Nil"
    ir.IrTypeBitArray -> "BitArray"
    ir.IrTypeVar(name) -> "var:" <> name
    ir.IrTypeList(inner) -> "List(" <> format_ir_type(inner) <> ")"
    ir.IrTypeResult(ok_t, err_t) ->
      "Result(" <> format_ir_type(ok_t) <> "," <> format_ir_type(err_t) <> ")"
    ir.IrTypeTuple(els) ->
      "#(" <> string.join(list.map(els, format_ir_type), ",") <> ")"
    ir.IrTypeFn(params, ret) ->
      "fn("
      <> string.join(list.map(params, format_ir_type), ",")
      <> ")->"
      <> format_ir_type(ret)
    ir.IrTypeNamed(module:, name:, args:, ..) -> {
      let base = case module {
        "" -> name
        _ -> module <> "." <> name
      }
      case args {
        [] -> base
        _ ->
          base <> "(" <> string.join(list.map(args, format_ir_type), ",") <> ")"
      }
    }
  }
}

/// Check any recorded `patches/.gekko_baseline/*.toml` baselines against
/// currently loaded upstream `IrModule`s.
pub fn check_baselines(
  project_root: String,
  module_pkg_by_name: Dict(String, String),
  ir_modules: List(IrModule),
  discovered_versions: Dict(String, String),
) -> Result(Nil, String) {
  let baseline_root = filepath.join(project_root, baseline_rel_dir)
  case simplifile.is_directory(baseline_root) {
    Ok(True) -> {
      use rel_files <- result.try(collect_toml_files(baseline_root, ""))
      let ir_by_mod =
        list.fold(ir_modules, dict.new(), fn(acc, m) {
          dict.insert(acc, m.module_name, m)
        })
      let rev_errors =
        list.fold(list.sort(rel_files, string.compare), [], fn(acc, rel) {
          let mod_name = string.drop_end(rel, 5)
          let full_path = filepath.join(baseline_root, rel)
          case read_baseline_file(full_path) {
            Error(err) -> [err, ..acc]
            Ok(#(up_pkg, up_ver, recorded_types)) ->
              case dict.get(ir_by_mod, mod_name) {
                Error(_) ->
                  case
                    up_pkg != "" && !dict.has_key(discovered_versions, up_pkg)
                  {
                    // Target package isn't loaded in this project.
                    True -> acc
                    False -> [
                      "Type drift in '"
                        <> mod_name
                        <> "': module in baseline ("
                        <> full_path
                        <> ") is no longer present upstream (review and run 'gekko shim ack')",
                      ..acc
                    ]
                  }
                Ok(ir_mod) -> {
                  let actual_pkg =
                    dict.get(module_pkg_by_name, mod_name) |> result.unwrap("")
                  case
                    up_pkg != "" && actual_pkg != "" && up_pkg != actual_pkg
                  {
                    True -> acc
                    False -> {
                      let cur_ver =
                        dict.get(discovered_versions, actual_pkg)
                        |> result.unwrap("unknown")
                      let td_map =
                        list.fold(ir_mod.types, dict.new(), fn(m, td) {
                          m
                          |> dict.insert(td.unmangled_name, td)
                          |> dict.insert(td.name, td)
                        })
                      dict.to_list(recorded_types)
                      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
                      |> list.fold(acc, fn(e_acc, entry) {
                        let #(ty_name, expected_fp) = entry
                        case dict.get(td_map, ty_name) {
                          Error(_) -> [
                            "Type drift in '"
                              <> mod_name
                              <> "."
                              <> ty_name
                              <> "': upstream type was removed or renamed (baseline "
                              <> up_ver
                              <> ", current "
                              <> cur_ver
                              <> "; review and run 'gekko shim ack')",
                            ..e_acc
                          ]
                          Ok(td) -> {
                            let actual_fp = fingerprint_type_def(td)
                            case actual_fp == expected_fp {
                              True -> e_acc
                              False -> [
                                "Type drift in '"
                                  <> mod_name
                                  <> "."
                                  <> ty_name
                                  <> "': upstream definition changed (baseline "
                                  <> up_ver
                                  <> ", current "
                                  <> cur_ver
                                  <> "; review and run 'gekko shim ack')\n  baseline: "
                                  <> expected_fp
                                  <> "\n  current:  "
                                  <> actual_fp,
                                ..e_acc
                              ]
                            }
                          }
                        }
                      })
                    }
                  }
                }
              }
          }
        })
      case rev_errors {
        [] -> Ok(Nil)
        _ -> Error(string.join(list.reverse(rev_errors), "\n"))
      }
    }
    _ -> Ok(Nil)
  }
}

/// Write or update `patches/.gekko_baseline/<module>.toml` for every module
/// patched by `root_module_patches` (plus any modules already tracked in
/// `patches/.gekko_baseline/`).
pub fn ack_baselines(
  project_root: String,
  root_module_patches: Dict(String, ffi_config.ModulePatch),
  module_pkg_by_name: Dict(String, String),
  ir_modules: List(IrModule),
  discovered_versions: Dict(String, String),
) -> Result(List(String), String) {
  let baseline_root = filepath.join(project_root, baseline_rel_dir)
  let ir_by_mod =
    list.fold(ir_modules, dict.new(), fn(acc, m) {
      dict.insert(acc, m.module_name, m)
    })

  let patch_mods =
    dict.keys(root_module_patches)
    |> list.map(strip_pkg_prefix)
    |> set.from_list

  let existing_mods = case simplifile.is_directory(baseline_root) {
    Ok(True) ->
      collect_toml_files(baseline_root, "")
      |> result.unwrap([])
      |> list.map(fn(rel) { string.drop_end(rel, 5) })
      |> set.from_list
    _ -> set.new()
  }

  let target_mods =
    set.union(patch_mods, existing_mods)
    |> set.to_list
    |> list.sort(string.compare)

  use written <- result.try(
    list.try_fold(target_mods, [], fn(acc, mod_name) {
      case dict.get(ir_by_mod, mod_name) {
        Error(_) -> Ok(acc)
        Ok(ir_mod) -> {
          let pkg_name =
            dict.get(module_pkg_by_name, mod_name) |> result.unwrap("")
          let pkg_ver =
            dict.get(discovered_versions, pkg_name) |> result.unwrap("0.1.0")
          let path = filepath.join(baseline_root, mod_name <> ".toml")
          let content = render_baseline_file(pkg_name, pkg_ver, ir_mod.types)
          use _ <- result.try(fs.write_text_if_changed(path, content))
          Ok([path, ..acc])
        }
      }
    }),
  )
  Ok(list.reverse(written))
}

/// Check if any recorded baseline has drift (returns True when drifted).
pub fn has_drift(
  project_root: String,
  module_pkg_by_name: Dict(String, String),
  ir_modules: List(IrModule),
  discovered_versions: Dict(String, String),
) -> Result(Nil, String) {
  check_baselines(
    project_root,
    module_pkg_by_name,
    ir_modules,
    discovered_versions,
  )
}

fn strip_pkg_prefix(key: String) -> String {
  case string.split_once(key, ":") {
    Ok(#(_, mod_part)) -> mod_part
    Error(_) -> key
  }
}

fn render_baseline_file(
  pkg_name: String,
  pkg_ver: String,
  types: List(IrTypeDef),
) -> String {
  let header =
    "# Generated by `gekko shim ack` — commit to track upstream type baselines.\n"
    <> "upstream_package = \""
    <> escape_toml_str(pkg_name)
    <> "\"\n"
    <> "upstream_version = \""
    <> escape_toml_str(pkg_ver)
    <> "\"\n"
  let type_sections =
    types
    |> list.sort(fn(a, b) { string.compare(a.unmangled_name, b.unmangled_name) })
    |> list.map(fn(td) {
      "\n[types.\""
      <> escape_toml_str(td.unmangled_name)
      <> "\"]\nfingerprint = \""
      <> escape_toml_str(fingerprint_type_def(td))
      <> "\"\n"
    })
  header <> string.concat(type_sections)
}

fn escape_toml_str(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
}

fn read_baseline_file(
  path: String,
) -> Result(#(String, String, Dict(String, String)), String) {
  use content <- result.try(fs.read_text(path))
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(fn(_) { "Failed to parse baseline TOML " <> path }),
  )
  let pkg = tom.get_string(parsed, ["upstream_package"]) |> result.unwrap("")
  let ver = tom.get_string(parsed, ["upstream_version"]) |> result.unwrap("")
  let types = case tom.get_table(parsed, ["types"]) {
    Error(_) -> dict.new()
    Ok(tbl) ->
      dict.fold(tbl, dict.new(), fn(acc, ty_name, entry) {
        case entry {
          tom.Table(inner) | tom.InlineTable(inner) ->
            case tom.get_string(inner, ["fingerprint"]) {
              Ok(fp) -> dict.insert(acc, ty_name, fp)
              Error(_) -> acc
            }
          _ -> acc
        }
      })
  }
  Ok(#(pkg, ver, types))
}

fn collect_toml_files(
  base_dir: String,
  rel_prefix: String,
) -> Result(List(String), String) {
  let dir = case rel_prefix {
    "" -> base_dir
    _ -> filepath.join(base_dir, rel_prefix)
  }
  use entries <- result.try(
    simplifile.read_directory(at: dir)
    |> result.map_error(fn(err) {
      "Failed to read baseline directory "
      <> dir
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  list.try_fold(entries, [], fn(acc, entry) {
    let rel = case rel_prefix {
      "" -> entry
      _ -> rel_prefix <> "/" <> entry
    }
    let full = filepath.join(base_dir, rel)
    case simplifile.is_directory(full) {
      Ok(True) -> {
        use nested <- result.try(collect_toml_files(base_dir, rel))
        Ok(list.append(acc, nested))
      }
      Ok(False) ->
        case string.ends_with(entry, ".toml") {
          True -> Ok([rel, ..acc])
          False -> Ok(acc)
        }
      Error(err) ->
        Error(
          "Failed to stat " <> full <> ": " <> simplifile.describe_error(err),
        )
    }
  })
}
