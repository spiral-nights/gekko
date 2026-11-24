import emit/moonbit_decl
import emit/pkg_config
import emit/trait_bounds
import filepath
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import index/symbol_table.{type SymbolTable}
import lower/desugar
import lower/ir.{type IrFunction}
import lower/mangle
import moonbit/ffi_meta
import project/ffi_config
import project/loader
import project/staging
import project/text_edit
import simplifile

type UnmappedFn {
  UnmappedFn(
    mod_name: String,
    fn_name: String,
    line: Int,
    col: Int,
    mbt_stub: String,
  )
}

type UnmappedType {
  UnmappedType(
    mod_name: String,
    type_name: String,
    type_params: List(String),
    publicity: glance.Publicity,
  )
}

type InspectData {
  InspectData(
    pkg_name: String,
    version: String,
    unmapped_fns: List(UnmappedFn),
    unmapped_types: List(UnmappedType),
  )
}

/// Inspect a resolved dependency `target_pkg` in `project_root` and return a
/// formatted report of unmapped `@external` functions, zero-variant external
/// types, and starter `gleam.toml` + `#gekko.patch` snippets.
pub fn inspect_package(
  project_root: String,
  target_pkg: String,
) -> Result(String, String) {
  use data <- result.try(collect_inspect_data(project_root, target_pkg))
  let header =
    "Shim inspection for " <> data.pkg_name <> " (" <> data.version <> "):"

  let types_section = case data.unmapped_types {
    [] -> "\nZero-variant external types: none"
    tys -> {
      let lines =
        list.map(tys, fn(t) {
          let params = case t.type_params {
            [] -> ""
            ps -> "(" <> string.join(ps, ", ") <> ")"
          }
          "  - "
          <> t.mod_name
          <> "."
          <> t.type_name
          <> params
          <> "  (key: \""
          <> data.pkg_name
          <> ":"
          <> t.mod_name
          <> "."
          <> t.type_name
          <> "\")"
        })
      "\nZero-variant external types ("
      <> int.to_string(list.length(tys))
      <> "):\n"
      <> string.join(lines, "\n")
    }
  }

  let fns_section = case data.unmapped_fns {
    [] -> "\nUnmapped reachable external functions: none"
    fns -> {
      let lines =
        list.map(fns, fn(f) {
          "  - "
          <> f.mod_name
          <> "."
          <> f.fn_name
          <> " (src/"
          <> f.mod_name
          <> ".gleam:"
          <> int.to_string(f.line)
          <> ":"
          <> int.to_string(f.col)
          <> ")\n    "
          <> f.mbt_stub
        })
      "\nUnmapped reachable external functions ("
      <> int.to_string(list.length(fns))
      <> "):\n"
      <> string.join(lines, "\n")
    }
  }

  let toml_section = case data.unmapped_types, data.unmapped_fns {
    [], [] ->
      "\nAll reachable externals in '"
      <> data.pkg_name
      <> "' are already mapped."
    _, _ ->
      "\nSuggested gleam.toml:\n"
      <> render_shim_gleam_toml_section(data)
      <> "\nAnnotate each patched MoonBit declaration in patches/<mod>/ with #gekko.patch.\n"
  }

  Ok(header <> types_section <> fns_section <> toml_section)
}

/// Scaffold a companion shim package for `target_pkg` (defaulting to
/// `<project_root>/gekko_<target_pkg>`).
pub fn init_shim(
  project_root: String,
  target_pkg: String,
  out_dir: Option(String),
) -> Result(String, String) {
  use data <- result.try(collect_inspect_data(project_root, target_pkg))
  let shim_dir =
    option.unwrap(out_dir, filepath.join(project_root, "gekko_" <> target_pkg))
  let shim_name = case filepath.base_name(shim_dir) {
    "" | "." -> "gekko_" <> target_pkg
    base -> string.replace(base, "-", "_")
  }

  use _ <- result.try(ensure_empty_or_new_dir(shim_dir))

  let gleam_toml =
    "name = \""
    <> shim_name
    <> "\"\nversion = \"0.1.0\"\ndescription = \"MoonBit shim overlay for "
    <> target_pkg
    <> "\"\n\n"
    <> render_shim_gleam_toml_section(data)
  let placeholder_gleam =
    "//// Companion MoonBit shim overlay for `"
    <> target_pkg
    <> "`.\n\npub const target = \""
    <> target_pkg
    <> "\"\n"
  let patch_files = render_patch_files(data)

  let files = [
    #("gleam.toml", gleam_toml),
    #("src/" <> shim_name <> ".gleam", placeholder_gleam),
    ..patch_files
  ]

  use _ <- result.try(
    list.try_each(files, fn(entry) {
      let #(rel, contents) = entry
      let full = filepath.join(shim_dir, rel)
      let dir = filepath.directory_name(full)
      use _ <- result.try(
        simplifile.create_directory_all(dir)
        |> result.map_error(fn(err) {
          "Failed to create directory "
          <> dir
          <> ": "
          <> simplifile.describe_error(err)
        }),
      )
      simplifile.write(to: full, contents:)
      |> result.map_error(fn(err) {
        "Failed to write " <> full <> ": " <> simplifile.describe_error(err)
      })
    }),
  )

  let created =
    list.map(files, fn(e) { "  " <> filepath.join(shim_dir, e.0) })
    |> string.join("\n")
  Ok(
    "Initialized companion shim '"
    <> shim_name
    <> "' for '"
    <> target_pkg
    <> "':\n"
    <> created
    <> "\n\nConsumers should enable this shim in their root gleam.toml:\n\n  [tools.gekko.use_shims]\n  "
    <> target_pkg
    <> " = \""
    <> shim_name
    <> "\"",
  )
}

fn ensure_empty_or_new_dir(dir: String) -> Result(Nil, String) {
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

fn collect_inspect_data(
  project_root: String,
  target_pkg: String,
) -> Result(InspectData, String) {
  use #(root_name, _) <- result.try(loader.read_project_meta(project_root))
  use discovered_deps <- result.try(loader.discover_all_dependencies(
    project_root,
    True,
  ))
  let target_opt =
    list.find(discovered_deps, fn(d) { d.package_name == target_pkg })
  use pkg <- result.try(case target_opt {
    Ok(p) -> Ok(p)
    Error(_) -> {
      let available =
        list.map(discovered_deps, fn(d) { d.package_name })
        |> string.join(", ")
      let suffix = case available {
        "" -> " (no dependencies found in build/packages)"
        _ -> " (available: " <> available <> ")"
      }
      Error(
        "Dependency '"
        <> target_pkg
        <> "' was not found in "
        <> project_root
        <> suffix,
      )
    }
  })

  use dep_overlays <- result.try(
    list.try_map(discovered_deps, fn(dep) {
      ffi_config.load_package_overlay(dep.package_root, dep.package_name)
    }),
  )
  use root_overlay <- result.try(ffi_config.load_package_overlay(
    project_root,
    root_name,
  ))
  use overlays <- result.try(ffi_config.merge_overlays(
    dep_overlays,
    root_overlay,
  ))

  let src_dir = filepath.join(pkg.package_root, "src")
  use modules <- result.try(case simplifile.is_directory(src_dir) {
    Ok(True) -> loader.discover_and_parse(src_dir, None)
    _ -> Ok([])
  })
  use packages_hash <- result.try(staging.compute_packages_dir_hash(
    project_root,
  ))
  let dep_staging =
    project_root
    |> filepath.join("build")
    |> filepath.join(".gekko_staging_deps")
    |> filepath.join(pkg.package_name)
  use iface <- result.try(staging.extract_package_interface_with_packages_hash(
    pkg.package_root,
    project_root,
    dep_staging,
    Some(packages_hash),
  ))

  let tagged =
    list.map(modules, fn(entry) {
      let #(mod_name, ast_mod, pre) = entry
      #(pkg.package_name, mod_name, ast_mod, pre)
    })
  let ffi_roots =
    list.append(list.map(discovered_deps, fn(d) { d.package_root }), [
      project_root,
    ])
  let ffi_metadata =
    ffi_meta.scan_package_roots_excluding(
      ffi_roots,
      overlays.patched_source_files,
    )
  let table =
    symbol_table.index_project_with_overlays(
      pkg.package_name,
      tagged,
      Some(iface),
      overlays.overrides,
      overlays.type_overrides,
      overlays.target_branches,
      ffi_metadata,
    )
  let resolved_pkg_dirs =
    tagged
    |> list.map(fn(e) { e.1 })
    |> pkg_config.resolve_module_pkg_dirs

  let #(rev_fns, rev_tys) =
    list.fold(modules, #([], []), fn(acc, entry) {
      let #(fn_acc, ty_acc) = acc
      let #(mod_name, ast_mod, pre) = entry
      let mod_syms =
        dict.get(table.modules, mod_name)
        |> result.unwrap(symbol_table.empty_module_symbols(mod_name))
      let ir_mod = desugar.desugar_module(ast_mod, table, mod_name)
      let emit_ctx =
        make_stub_emit_ctx(mod_name, table, ffi_metadata, resolved_pkg_dirs)

      let next_tys =
        list.fold(ir_mod.types, ty_acc, fn(t_acc, td) {
          case td.variants == [] && td.external_type == None {
            True -> [
              UnmappedType(
                mod_name:,
                type_name: td.name,
                type_params: td.type_params,
                publicity: td.publicity,
              ),
              ..t_acc
            ]
            False -> t_acc
          }
        })

      let reachable =
        symbol_table.reachable_private_functions_for_branch(
          ast_mod,
          mod_syms.functions,
          mod_syms.target_branch,
        )
      let ir_fn_map =
        list.fold(ir_mod.functions, dict.new(), fn(m, f) {
          dict.insert(m, f.name, f)
        })

      let next_fns =
        list.fold(ast_mod.functions, fn_acc, fn(f_acc, fn_def) {
          let fn_name = fn_def.definition.name
          let active =
            !symbol_table.is_excluded_for_branch(
              fn_def.attributes,
              mod_syms.target_branch,
            )
          case active && set.contains(reachable, fn_name) {
            False -> f_acc
            True -> {
              let has_erl_js = has_erl_or_js_attr(fn_def.attributes)
              let has_ffi =
                symbol_table.resolve_function_ffi(
                  pkg.package_name,
                  mod_name,
                  fn_name,
                  pre,
                  overlays.overrides,
                )
                != None
              let has_body = fn_def.definition.body != []
              case has_erl_js && !has_ffi && !has_body {
                False -> f_acc
                True -> {
                  let #(line, col) =
                    text_edit.byte_offset_to_line_col(
                      pre.cleaned_source,
                      fn_def.definition.location.start,
                    )
                  let stub = case dict.get(ir_fn_map, fn_name) {
                    Ok(ir_fn) -> format_mbt_fn_stub(ir_fn, emit_ctx)
                    Error(_) -> "pub fn " <> fn_name <> "() -> Unit"
                  }
                  [
                    UnmappedFn(mod_name:, fn_name:, line:, col:, mbt_stub: stub),
                    ..f_acc
                  ]
                }
              }
            }
          }
        })
      #(next_fns, next_tys)
    })

  Ok(InspectData(
    pkg_name: pkg.package_name,
    version: pkg.version,
    unmapped_fns: list.reverse(rev_fns),
    unmapped_types: list.reverse(rev_tys),
  ))
}

fn make_stub_emit_ctx(
  mod_name: String,
  table: SymbolTable,
  ffi_metadata: ffi_meta.FfiMetadata,
  resolved_pkg_dirs: Dict(String, String),
) -> moonbit_decl.EmitCtx {
  moonbit_decl.EmitCtx(
    current_module: mod_name,
    local_ctors: dict.new(),
    local_external_types: dict.new(),
    local_vars: set.new(),
    table: Some(table),
    ffi_metadata:,
    project_bounds: trait_bounds.ProjectTraitBounds(
      fn_bounds: dict.new(),
      type_eq_hash_params: dict.new(),
      all_fns: dict.new(),
      all_consts: dict.new(),
    ),
    module_pkg_dirs: resolved_pkg_dirs,
    pkg_to_alias: dict.new(),
    used_aliases: set.new(),
  )
}

fn format_mbt_fn_stub(f: IrFunction, ctx: moonbit_decl.EmitCtx) -> String {
  let generics = case f.type_params {
    [] -> ""
    tps -> "[" <> string.join(tps, ", ") <> "]"
  }
  let #(params_rev, ctx1) =
    list.fold(f.params, #([], ctx), fn(acc, p) {
      let #(ps, c) = acc
      let #(ty_str, next_c) = moonbit_decl.emit_type(p.param_type, c)
      let p_name = case p.name {
        "_" -> "_arg"
        n -> n
      }
      #([p_name <> " : " <> ty_str, ..ps], next_c)
    })
  let #(ret_str, _) = moonbit_decl.emit_type(f.return_type, ctx1)
  let mangled_name = mangle.mangle_ident(f.name)
  "pub fn"
  <> generics
  <> " "
  <> mangled_name
  <> "("
  <> string.join(list.reverse(params_rev), ", ")
  <> ") -> "
  <> ret_str
}

fn has_erl_or_js_attr(attributes: List(glance.Attribute)) -> Bool {
  list.any(attributes, fn(attr) {
    case attr.name, attr.arguments {
      "external", [glance.Variable(name: "erlang", ..), ..]
      | "external", [glance.Variable(name: "javascript", ..), ..]
      -> True
      _, _ -> False
    }
  })
}

fn collect_patched_modules(data: InspectData) -> List(String) {
  let from_tys = list.map(data.unmapped_types, fn(t) { t.mod_name })
  let from_fns = list.map(data.unmapped_fns, fn(f) { f.mod_name })
  list.append(from_tys, from_fns)
  |> set.from_list
  |> set.to_list
  |> list.sort(string.compare)
}

fn render_shim_gleam_toml_section(data: InspectData) -> String {
  let ver_constraint = suggest_semver_constraint(data.version)
  "[tools.gekko.shim_for]\npackage = \""
  <> data.pkg_name
  <> "\"\nversion = \""
  <> ver_constraint
  <> "\"\n"
}

fn render_patch_files(data: InspectData) -> List(#(String, String)) {
  let mods = collect_patched_modules(data)
  list.flat_map(mods, fn(mod_name) {
    let type_decls =
      list.filter_map(data.unmapped_types, fn(t) {
        case t.mod_name == mod_name {
          False -> Error(Nil)
          True -> {
            let params = case t.type_params {
              [] -> ""
              ps ->
                "[" <> string.join(list.map(ps, string.capitalise), ", ") <> "]"
            }
            let vis = case t.publicity {
              glance.Public -> "pub "
              _ -> ""
            }
            Ok(
              "///|\n#gekko.patch\n"
              <> vis
              <> "type "
              <> t.type_name
              <> params
              <> "\n",
            )
          }
        }
      })
    let fn_decls =
      list.filter_map(data.unmapped_fns, fn(f) {
        case f.mod_name == mod_name {
          False -> Error(Nil)
          True -> {
            let mangled = mangle.mangle_ident(f.fn_name)
            let attr = case mangled == f.fn_name {
              True -> "#gekko.patch"
              False -> "#gekko.patch(\"" <> f.fn_name <> "\")"
            }
            Ok(
              "///|\n"
              <> attr
              <> "\n"
              <> f.mbt_stub
              <> " {\n  abort(\"todo: "
              <> f.fn_name
              <> "\")\n}\n",
            )
          }
        }
      })
    let raw_body = case list.append(type_decls, fn_decls) {
      [] -> "///|\n// Add co-located MoonBit patch implementations here.\n"
      blocks -> string.join(blocks, "\n")
    }
    let hints = gprelude_hints_for_stub(raw_body)
    let body = case hints {
      "" -> raw_body
      _ -> hints <> "\n" <> raw_body
    }
    let base_name = filepath.base_name(mod_name)
    [
      #("patches/" <> mod_name <> "/moon.pkg", "import {\n}\n"),
      #("patches/" <> mod_name <> "/" <> base_name <> ".mbt", body),
    ]
  })
}

fn gprelude_hints_for_stub(body: String) -> String {
  let hints = []
  let hints = case string.contains(body, "@gprelude.Dynamic") {
    True -> [
      "// @gprelude.Dynamic: DynNull | DynBool | DynInt | DynFloat | DynString | DynBitArray | DynList | DynArray | DynMap",
      ..hints
    ]
    False -> hints
  }
  let hints = case string.contains(body, "@gprelude.BitArray") {
    True -> [
      "// @gprelude.BitArray: BitArray::empty / from_bytes / from_string / concat",
      ..hints
    ]
    False -> hints
  }
  let hints = case string.contains(body, "@gprelude.GList") {
    True -> [
      "// @gprelude.GList[T]: Nil | Cons(T, GList[T]), GList::from_array / to_array",
      ..hints
    ]
    False -> hints
  }
  case hints {
    [] -> ""
    _ -> string.join(hints, "\n") <> "\n"
  }
}

fn suggest_semver_constraint(version: String) -> String {
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
