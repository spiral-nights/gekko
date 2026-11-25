import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import lower/mangle
import moonbit/ffi_meta.{type FfiMetadata}
import project/interface.{
  type PackageInterface, type ResolvedFunction, type ResolvedType,
  type ResolvedTypeDef, FnType, NamedType, TupleType, VariableType,
}
import project/prepass.{
  type ExternalType, type FfiKind, type PrepassResult, type TargetBranch,
  PreferErlang, PreferJavascript,
}

/// Global symbol index for a Gleam package (and its staged/parsed modules).
pub type SymbolTable {
  SymbolTable(package_name: String, modules: Dict(String, ModuleSymbols))
}

/// Indexed symbols and import resolution tables for a single Gleam module.
pub type ModuleSymbols {
  ModuleSymbols(
    name: String,
    source: String,
    target_branch: TargetBranch,
    imports: List(ImportInfo),
    alias_to_module: Dict(String, String),
    unqualified_values: Dict(String, #(String, String)),
    unqualified_types: Dict(String, #(String, String)),
    types: Dict(String, TypeInfo),
    type_aliases: Dict(String, glance.TypeAlias),
    constructors: Dict(String, ConstructorInfo),
    functions: Dict(String, FunctionInfo),
    mangled_functions: Dict(String, FunctionInfo),
    constants: Dict(String, ConstantInfo),
  )
}

/// Construct an empty `ModuleSymbols` record for `name`.
pub fn empty_module_symbols(name: String) -> ModuleSymbols {
  ModuleSymbols(
    name:,
    source: "",
    target_branch: PreferErlang,
    imports: [],
    alias_to_module: dict.new(),
    unqualified_values: dict.new(),
    unqualified_types: dict.new(),
    types: dict.new(),
    type_aliases: dict.new(),
    constructors: dict.new(),
    functions: dict.new(),
    mangled_functions: dict.new(),
    constants: dict.new(),
  )
}

/// Normalized import declaration metadata.
pub type ImportInfo {
  ImportInfo(
    module: String,
    alias: Option(String),
    unqualified_types: List(glance.UnqualifiedImport),
    unqualified_values: List(glance.UnqualifiedImport),
  )
}

/// A variant constructor field with AST and optional HM-resolved type.
pub type FieldInfo {
  FieldInfo(
    label: Option(String),
    ast_type: glance.Type,
    resolved_type: Option(ResolvedType),
  )
}

/// A single variant of a custom type.
pub type VariantInfo {
  VariantInfo(name: String, fields: List(FieldInfo))
}

/// Indexed metadata for a Gleam `CustomType`.
pub type TypeInfo {
  TypeInfo(
    module: String,
    name: String,
    publicity: glance.Publicity,
    opaque_: Bool,
    parameters: List(String),
    variants: List(VariantInfo),
    is_single_variant: Bool,
    shared_fields: Dict(String, ResolvedType),
    external_type: Option(ExternalType),
    has_function_field: Bool,
  )
}

/// Constructor lookup record linking a variant constructor to its parent type.
pub type ConstructorInfo {
  ConstructorInfo(
    module: String,
    type_name: String,
    variant_name: String,
    fields: List(FieldInfo),
  )
}

/// Indexed metadata for a function parameter.
pub type ParamInfo {
  ParamInfo(
    label: Option(String),
    name: glance.AssignmentName,
    ast_type: Option(glance.Type),
    resolved_type: Option(ResolvedType),
  )
}

/// Indexed metadata for a top-level function.
pub type FunctionInfo {
  FunctionInfo(
    module: String,
    name: String,
    publicity: glance.Publicity,
    arity: Int,
    parameters: List(ParamInfo),
    return_type: Option(ResolvedType),
    resolved: Option(ResolvedFunction),
    ffi: Option(FfiKind),
    has_erlang_or_js_external: Bool,
    has_gleam_body: Bool,
  )
}

/// Indexed metadata for a module constant.
pub type ConstantInfo {
  ConstantInfo(
    module: String,
    name: String,
    publicity: glance.Publicity,
    resolved_type: Option(ResolvedType),
  )
}

/// Build a project-wide `SymbolTable` from parsed modules, optional `PackageInterface`,
/// and `gekko.toml` / `gleam.toml` FFI overrides.
pub fn index_project(
  package_name: String,
  modules: List(#(String, glance.Module, PrepassResult)),
  pkg_interface: Option(PackageInterface),
  ffi_overrides: Dict(String, FfiKind),
) -> SymbolTable {
  let tagged =
    list.map(modules, fn(entry) {
      let #(mod_name, ast_mod, pre) = entry
      #(package_name, mod_name, ast_mod, pre)
    })
  index_project_with_packages(
    package_name,
    tagged,
    pkg_interface,
    ffi_overrides,
  )
}

/// Build a project-wide `SymbolTable` where each module carries its owning package name.
pub fn index_project_with_packages(
  root_package_name: String,
  package_modules: List(#(String, String, glance.Module, PrepassResult)),
  pkg_interface: Option(PackageInterface),
  ffi_overrides: Dict(String, FfiKind),
) -> SymbolTable {
  index_project_with_ffi_meta(
    root_package_name,
    package_modules,
    pkg_interface,
    ffi_overrides,
    ffi_meta.base_metadata(),
  )
}

/// Build a project-wide `SymbolTable` with explicit MoonBit FFI trait metadata.
pub fn index_project_with_ffi_meta(
  root_package_name: String,
  package_modules: List(#(String, String, glance.Module, PrepassResult)),
  pkg_interface: Option(PackageInterface),
  ffi_overrides: Dict(String, FfiKind),
  ffi_metadata: FfiMetadata,
) -> SymbolTable {
  index_project_with_overlays(
    root_package_name,
    package_modules,
    pkg_interface,
    ffi_overrides,
    dict.new(),
    dict.new(),
    ffi_metadata,
  )
}

/// Build a project-wide `SymbolTable` with full overlay support (`ffi_overrides`,
/// `type_overrides`, `target_branches`) and MoonBit FFI trait metadata.
pub fn index_project_with_overlays(
  root_package_name: String,
  package_modules: List(#(String, String, glance.Module, PrepassResult)),
  pkg_interface: Option(PackageInterface),
  ffi_overrides: Dict(String, FfiKind),
  type_overrides: Dict(String, ExternalType),
  target_branches: Dict(String, TargetBranch),
  ffi_metadata: FfiMetadata,
) -> SymbolTable {
  let mod_to_pkg =
    list.fold(package_modules, dict.new(), fn(acc, entry) {
      dict.insert(acc, entry.1, entry.0)
    })

  let raw_modules =
    list.fold(package_modules, dict.new(), fn(acc, entry) {
      let #(pkg_name, mod_name, ast_mod, prepass_res) = entry
      let mod_iface = get_module_interface(pkg_interface, mod_name)
      let indexed =
        index_module(
          pkg_name,
          mod_name,
          ast_mod,
          prepass_res,
          mod_iface,
          ffi_overrides,
          type_overrides,
          target_branches,
          mod_to_pkg,
        )
      dict.insert(acc, mod_name, indexed)
    })

  let computed_modules =
    compute_transitive_type_flags(raw_modules, mod_to_pkg, ffi_metadata)
  SymbolTable(package_name: root_package_name, modules: computed_modules)
}

/// Return True if a top-level definition should be excluded when compiling
/// under `branch` (`PreferErlang` excludes `@target(javascript)`,
/// `PreferJavascript` excludes `@target(erlang)`).
pub fn is_excluded_for_branch(
  attributes: List(glance.Attribute),
  branch: TargetBranch,
) -> Bool {
  let excluded = case branch {
    PreferErlang -> "javascript"
    PreferJavascript -> "erlang"
  }
  list.any(attributes, fn(attr) {
    case attr.name, attr.arguments {
      "target", [glance.Variable(name:, ..)] -> name == excluded
      _, _ -> False
    }
  })
}

/// Resolve the active `@target(...)` branch for `(package_name, mod_name)`.
pub fn resolve_target_branch(
  package_name: String,
  mod_name: String,
  target_branches: Dict(String, TargetBranch),
) -> TargetBranch {
  let candidates = [
    package_name <> ":" <> mod_name,
    package_name <> "." <> mod_name,
    mod_name,
    package_name,
  ]
  case list.find_map(candidates, fn(k) { dict.get(target_branches, k) }) {
    Ok(branch) -> branch
    Error(_) -> PreferErlang
  }
}

/// Look up a function in `current_module`, resolving module qualifiers and
/// unqualified imports.
pub fn lookup_function(
  table: SymbolTable,
  current_module: String,
  qualifier: Option(String),
  fn_name: String,
) -> Option(FunctionInfo) {
  case dict.get(table.modules, current_module) {
    Error(_) -> None
    Ok(mod_syms) ->
      case qualifier {
        Some(alias) ->
          case dict.get(mod_syms.alias_to_module, alias) {
            Ok(target_mod) ->
              lookup_function_in_module(table, target_mod, fn_name)
            Error(_) -> None
          }
        None ->
          case dict.get(mod_syms.functions, fn_name) {
            Ok(info) -> Some(info)
            Error(_) ->
              case dict.get(mod_syms.unqualified_values, fn_name) {
                Ok(#(target_mod, orig_name)) ->
                  lookup_function_in_module(table, target_mod, orig_name)
                Error(_) -> None
              }
          }
      }
  }
}

fn lookup_function_in_module(
  table: SymbolTable,
  module_name: String,
  fn_name: String,
) -> Option(FunctionInfo) {
  case dict.get(table.modules, module_name) {
    Ok(mod_syms) ->
      case dict.get(mod_syms.functions, fn_name) {
        Ok(info) -> Some(info)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

/// Look up a constructor in `current_module`, respecting optional module qualifier
/// (`mod.Ctor`) or unqualified imports (`import m.{Ctor}`).
pub fn lookup_constructor(
  table: SymbolTable,
  current_module: String,
  qualifier: Option(String),
  ctor_name: String,
) -> Option(ConstructorInfo) {
  case dict.get(table.modules, current_module) {
    Error(_) -> None
    Ok(mod_syms) ->
      case qualifier {
        Some(alias) ->
          case dict.get(mod_syms.alias_to_module, alias) {
            Ok(target_mod_name) ->
              lookup_constructor_in_module(table, target_mod_name, ctor_name)
            Error(_) -> None
          }
        None ->
          case dict.get(mod_syms.constructors, ctor_name) {
            Ok(info) -> Some(info)
            Error(_) ->
              case dict.get(mod_syms.unqualified_values, ctor_name) {
                Ok(#(target_mod_name, original_name)) ->
                  lookup_constructor_in_module(
                    table,
                    target_mod_name,
                    original_name,
                  )
                Error(_) -> None
              }
          }
      }
  }
}

/// Look up a custom type definition from `current_module`, resolving local types
/// and unqualified type imports.
pub fn lookup_type(
  table: SymbolTable,
  current_module: String,
  qualifier: Option(String),
  type_name: String,
) -> Option(TypeInfo) {
  case dict.get(table.modules, current_module) {
    Error(_) -> None
    Ok(mod_syms) ->
      case qualifier {
        Some(alias) ->
          case dict.get(mod_syms.alias_to_module, alias) {
            Ok(target_mod_name) ->
              lookup_type_in_module(table, target_mod_name, type_name)
            Error(_) -> None
          }
        None ->
          case dict.get(mod_syms.types, type_name) {
            Ok(info) -> Some(info)
            Error(_) ->
              case dict.get(mod_syms.unqualified_types, type_name) {
                Ok(#(target_mod_name, original_name)) ->
                  lookup_type_in_module(table, target_mod_name, original_name)
                Error(_) -> None
              }
          }
      }
  }
}

fn lookup_constructor_in_module(
  table: SymbolTable,
  module_name: String,
  ctor_name: String,
) -> Option(ConstructorInfo) {
  case dict.get(table.modules, module_name) {
    Ok(mod_syms) ->
      case dict.get(mod_syms.constructors, ctor_name) {
        Ok(info) -> Some(info)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

fn lookup_type_in_module(
  table: SymbolTable,
  module_name: String,
  type_name: String,
) -> Option(TypeInfo) {
  case dict.get(table.modules, module_name) {
    Ok(mod_syms) ->
      case dict.get(mod_syms.types, type_name) {
        Ok(info) -> Some(info)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

fn get_module_interface(
  pkg_interface: Option(PackageInterface),
  mod_name: String,
) -> Option(interface.ModuleInterface) {
  case pkg_interface {
    None -> None
    Some(iface) ->
      case dict.get(iface.modules, mod_name) {
        Ok(mod_iface) -> Some(mod_iface)
        Error(_) -> None
      }
  }
}

fn index_module(
  package_name: String,
  mod_name: String,
  ast_mod: glance.Module,
  prepass_res: PrepassResult,
  mod_iface: Option(interface.ModuleInterface),
  ffi_overrides: Dict(String, FfiKind),
  type_overrides: Dict(String, ExternalType),
  target_branches: Dict(String, TargetBranch),
  mod_to_pkg: Dict(String, String),
) -> ModuleSymbols {
  let #(imports, alias_to_module, unqualified_values, unqualified_types) =
    index_imports(ast_mod.imports)

  let branch = resolve_target_branch(package_name, mod_name, target_branches)

  let active_type_aliases =
    list.filter(ast_mod.type_aliases, fn(def) {
      !is_excluded_for_branch(def.attributes, branch)
    })
  let active_custom_types =
    list.filter(ast_mod.custom_types, fn(def) {
      !is_excluded_for_branch(def.attributes, branch)
    })
  let active_functions =
    list.filter(ast_mod.functions, fn(def) {
      !is_excluded_for_branch(def.attributes, branch)
    })
  let active_constants =
    list.filter(ast_mod.constants, fn(def) {
      !is_excluded_for_branch(def.attributes, branch)
    })

  let type_aliases =
    list.fold(active_type_aliases, dict.new(), fn(acc, def) {
      dict.insert(acc, def.definition.name, def.definition)
    })

  let #(types, constructors) =
    index_custom_types(
      package_name,
      mod_name,
      active_custom_types,
      prepass_res,
      type_overrides,
      mod_iface,
      alias_to_module,
      unqualified_types,
      mod_to_pkg,
    )

  let functions =
    index_functions(
      package_name,
      mod_name,
      active_functions,
      prepass_res,
      mod_iface,
      ffi_overrides,
      alias_to_module,
      unqualified_types,
      mod_to_pkg,
    )

  let mangled_functions =
    dict.fold(functions, dict.new(), fn(acc, _k, fi) {
      dict.insert(acc, mangle.mangle_ident(fi.name), fi)
    })

  let constants =
    index_constants(
      package_name,
      mod_name,
      active_constants,
      mod_iface,
      alias_to_module,
      unqualified_types,
      mod_to_pkg,
    )

  ModuleSymbols(
    name: mod_name,
    source: prepass_res.cleaned_source,
    target_branch: branch,
    imports:,
    alias_to_module:,
    unqualified_values:,
    unqualified_types:,
    types:,
    type_aliases:,
    constructors:,
    functions:,
    mangled_functions:,
    constants:,
  )
}

fn index_imports(
  import_defs: List(glance.Definition(glance.Import)),
) -> #(
  List(ImportInfo),
  Dict(String, String),
  Dict(String, #(String, String)),
  Dict(String, #(String, String)),
) {
  let #(rev_imports, alias_map, unqual_vals, unqual_types) =
    list.fold(
      import_defs,
      #([], dict.new(), dict.new(), dict.new()),
      fn(acc, def) {
        let #(imps, aliases, uvals, utypes) = acc
        let imp = def.definition
        let alias = resolve_import_alias(imp.module, imp.alias)
        let info =
          ImportInfo(
            module: imp.module,
            alias:,
            unqualified_types: imp.unqualified_types,
            unqualified_values: imp.unqualified_values,
          )
        let aliases = case alias {
          Some(a) -> dict.insert(aliases, a, imp.module)
          None -> aliases
        }
        let uvals =
          list.fold(imp.unqualified_values, uvals, fn(m, u) {
            let local_name = option.unwrap(u.alias, u.name)
            dict.insert(m, local_name, #(imp.module, u.name))
          })
        let utypes =
          list.fold(imp.unqualified_types, utypes, fn(m, u) {
            let local_name = option.unwrap(u.alias, u.name)
            dict.insert(m, local_name, #(imp.module, u.name))
          })
        #([info, ..imps], aliases, uvals, utypes)
      },
    )
  #(list.reverse(rev_imports), alias_map, unqual_vals, unqual_types)
}

fn resolve_import_alias(
  module_path: String,
  alias: Option(glance.AssignmentName),
) -> Option(String) {
  case alias {
    Some(glance.Named(name)) -> Some(name)
    Some(glance.Discarded(_)) -> None
    None ->
      module_path
      |> string.split("/")
      |> list.last
      |> option.from_result
  }
}

/// Resolve any MoonBit `@external_type` mapping from `type_overrides` or source pragmas.
pub fn resolve_type_override(
  package_name: String,
  mod_name: String,
  type_name: String,
  prepass_res: PrepassResult,
  type_overrides: Dict(String, ExternalType),
) -> Option(ExternalType) {
  let candidate_keys = [
    package_name <> ":" <> mod_name <> "." <> type_name,
    package_name <> "." <> mod_name <> "." <> type_name,
    mod_name <> "." <> type_name,
  ]
  case list.find_map(candidate_keys, fn(k) { dict.get(type_overrides, k) }) {
    Ok(ext) -> Some(ext)
    Error(_) ->
      list.find(prepass_res.external_types, fn(entry) {
        entry.gleam_type_name == type_name
      })
      |> option.from_result
      |> option.map(fn(entry) { entry.target })
  }
}

fn index_custom_types(
  package_name: String,
  mod_name: String,
  type_defs: List(glance.Definition(glance.CustomType)),
  prepass_res: PrepassResult,
  type_overrides: Dict(String, ExternalType),
  mod_iface: Option(interface.ModuleInterface),
  alias_to_module: Dict(String, String),
  unqualified_types: Dict(String, #(String, String)),
  mod_to_pkg: Dict(String, String),
) -> #(Dict(String, TypeInfo), Dict(String, ConstructorInfo)) {
  list.fold(type_defs, #(dict.new(), dict.new()), fn(acc, def) {
    let #(types_acc, ctors_acc) = acc
    let ct = def.definition
    let iface_type = lookup_iface_type(mod_iface, ct.name)
    let external_type =
      resolve_type_override(
        package_name,
        mod_name,
        ct.name,
        prepass_res,
        type_overrides,
      )

    let variants =
      list.map(ct.variants, fn(variant) {
        let iface_variant = lookup_iface_variant(iface_type, variant.name)
        let fields =
          index_variant_fields(
            variant.fields,
            iface_variant,
            ct.parameters,
            package_name,
            mod_name,
            alias_to_module,
            unqualified_types,
            mod_to_pkg,
          )
        VariantInfo(name: variant.name, fields:)
      })

    let is_single_variant = list.length(variants) == 1
    let shared_fields = compute_shared_fields(variants)

    let type_info =
      TypeInfo(
        module: mod_name,
        name: ct.name,
        publicity: ct.publicity,
        opaque_: ct.opaque_,
        parameters: ct.parameters,
        variants:,
        is_single_variant:,
        shared_fields:,
        external_type:,
        has_function_field: False,
      )

    let ctors_acc =
      list.fold(variants, ctors_acc, fn(m, v) {
        let ctor =
          ConstructorInfo(
            module: mod_name,
            type_name: ct.name,
            variant_name: v.name,
            fields: v.fields,
          )
        dict.insert(m, v.name, ctor)
      })

    #(dict.insert(types_acc, ct.name, type_info), ctors_acc)
  })
}

fn lookup_iface_type(
  mod_iface: Option(interface.ModuleInterface),
  type_name: String,
) -> Option(ResolvedTypeDef) {
  case mod_iface {
    None -> None
    Some(mi) ->
      case dict.get(mi.types, type_name) {
        Ok(td) -> Some(td)
        Error(_) -> None
      }
  }
}

fn lookup_iface_variant(
  iface_type: Option(ResolvedTypeDef),
  variant_name: String,
) -> Option(interface.ResolvedVariant) {
  case iface_type {
    None -> None
    Some(td) ->
      list.find(td.constructors, fn(v) { v.name == variant_name })
      |> option.from_result
  }
}

fn index_variant_fields(
  ast_fields: List(glance.VariantField),
  iface_variant: Option(interface.ResolvedVariant),
  type_params: List(String),
  package_name: String,
  mod_name: String,
  alias_to_module: Dict(String, String),
  unqualified_types: Dict(String, #(String, String)),
  mod_to_pkg: Dict(String, String),
) -> List(FieldInfo) {
  let iface_fields = case iface_variant {
    Some(v) -> list.map(v.parameters, Some)
    None -> list.repeat(None, list.length(ast_fields))
  }

  let pairs = case list.length(iface_fields) == list.length(ast_fields) {
    True -> list.zip(ast_fields, iface_fields)
    False -> list.zip(ast_fields, list.repeat(None, list.length(ast_fields)))
  }

  list.map(pairs, fn(pair) {
    let #(ast_field, maybe_iface_field) = pair
    let #(label, ast_type) = case ast_field {
      glance.LabelledVariantField(item:, label:) -> #(Some(label), item)
      glance.UnlabelledVariantField(item:) -> #(None, item)
    }
    let resolved_type = case maybe_iface_field {
      Some(rf) -> Some(rf.type_)
      None ->
        Some(ast_type_to_resolved(
          ast_type,
          type_params,
          package_name,
          mod_name,
          alias_to_module,
          unqualified_types,
          mod_to_pkg,
        ))
    }
    FieldInfo(label:, ast_type:, resolved_type:)
  })
}

fn compute_shared_fields(
  variants: List(VariantInfo),
) -> Dict(String, ResolvedType) {
  case variants {
    [] -> dict.new()
    [single] ->
      list.fold(single.fields, dict.new(), fn(acc, field) {
        case field.label, field.resolved_type {
          Some(lbl), Some(ty) -> dict.insert(acc, lbl, ty)
          _, _ -> acc
        }
      })
    [first, ..rest] ->
      list.fold(first.fields, dict.new(), fn(acc, field) {
        case field.label, field.resolved_type {
          Some(lbl), Some(ty) -> {
            let present_in_all =
              list.all(rest, fn(variant) {
                list.any(variant.fields, fn(other) {
                  other.label == Some(lbl) && other.resolved_type == Some(ty)
                })
              })
            case present_in_all {
              True -> dict.insert(acc, lbl, ty)
              False -> acc
            }
          }
          _, _ -> acc
        }
      })
  }
}

fn index_functions(
  package_name: String,
  mod_name: String,
  fn_defs: List(glance.Definition(glance.Function)),
  prepass_res: PrepassResult,
  mod_iface: Option(interface.ModuleInterface),
  ffi_overrides: Dict(String, FfiKind),
  alias_to_module: Dict(String, String),
  unqualified_types: Dict(String, #(String, String)),
  mod_to_pkg: Dict(String, String),
) -> Dict(String, FunctionInfo) {
  list.fold(fn_defs, dict.new(), fn(acc, def) {
    let func = def.definition
    let resolved_fn = case mod_iface {
      None -> None
      Some(mi) ->
        case dict.get(mi.functions, func.name) {
          Ok(rf) -> Some(rf)
          Error(_) -> None
        }
    }

    let params =
      build_param_infos(
        func.parameters,
        resolved_fn,
        package_name,
        mod_name,
        alias_to_module,
        unqualified_types,
        mod_to_pkg,
      )

    let return_type = case resolved_fn {
      Some(rf) -> Some(rf.return)
      None ->
        option.map(func.return, fn(ret_ast) {
          ast_type_to_resolved(
            ret_ast,
            [],
            package_name,
            mod_name,
            alias_to_module,
            unqualified_types,
            mod_to_pkg,
          )
        })
    }

    let ffi =
      resolve_function_ffi(
        package_name,
        mod_name,
        func.name,
        prepass_res,
        ffi_overrides,
      )

    let has_ext_attr =
      list.any(def.attributes, fn(attr) {
        case attr.name, attr.arguments {
          "external", [glance.Variable(name: "erlang", ..), ..]
          | "external", [glance.Variable(name: "javascript", ..), ..]
          -> True
          _, _ -> False
        }
      })

    let has_iface_ext = case resolved_fn {
      Some(rf) ->
        rf.implementations.uses_erlang_externals
        || rf.implementations.uses_javascript_externals
      None -> False
    }

    let info =
      FunctionInfo(
        module: mod_name,
        name: func.name,
        publicity: func.publicity,
        arity: list.length(func.parameters),
        parameters: params,
        return_type:,
        resolved: resolved_fn,
        ffi:,
        has_erlang_or_js_external: has_ext_attr || has_iface_ext,
        has_gleam_body: func.body != [],
      )
    dict.insert(acc, func.name, info)
  })
}

fn build_param_infos(
  ast_params: List(glance.FunctionParameter),
  resolved_fn: Option(ResolvedFunction),
  package_name: String,
  mod_name: String,
  alias_to_module: Dict(String, String),
  unqualified_types: Dict(String, #(String, String)),
  mod_to_pkg: Dict(String, String),
) -> List(ParamInfo) {
  let iface_params = case resolved_fn {
    Some(rf) -> list.map(rf.parameters, Some)
    None -> list.repeat(None, list.length(ast_params))
  }
  let pairs = case list.length(iface_params) == list.length(ast_params) {
    True -> list.zip(ast_params, iface_params)
    False -> list.zip(ast_params, list.repeat(None, list.length(ast_params)))
  }

  list.map(pairs, fn(pair) {
    let #(ast_p, maybe_iface_p) = pair
    let resolved_type = case maybe_iface_p {
      Some(rp) -> Some(rp.type_)
      None ->
        option.map(ast_p.type_, fn(t) {
          ast_type_to_resolved(
            t,
            [],
            package_name,
            mod_name,
            alias_to_module,
            unqualified_types,
            mod_to_pkg,
          )
        })
    }
    ParamInfo(
      label: ast_p.label,
      name: ast_p.name,
      ast_type: ast_p.type_,
      resolved_type:,
    )
  })
}

/// Resolve any MoonBit FFI mapping configured in `ffi_overrides` or `@external(moonbit, ...)` pragmas.
pub fn resolve_function_ffi(
  package_name: String,
  mod_name: String,
  fn_name: String,
  prepass_res: PrepassResult,
  ffi_overrides: Dict(String, FfiKind),
) -> Option(FfiKind) {
  let candidate_keys = [
    package_name <> ":" <> mod_name <> "." <> fn_name,
    package_name <> "." <> mod_name <> "." <> fn_name,
    mod_name <> "." <> fn_name,
  ]
  case list.find_map(candidate_keys, fn(k) { dict.get(ffi_overrides, k) }) {
    Ok(kind) -> Some(kind)
    Error(_) -> {
      let matching =
        list.filter(prepass_res.ffi_entries, fn(e) {
          e.module == mod_name && e.function_name == fn_name
        })
      let raw = list.find(matching, fn(e) { e.source == prepass.RawAttribute })
      case raw {
        Ok(e) -> Some(e.kind)
        Error(_) ->
          case list.last(matching) {
            Ok(e) -> Some(e.kind)
            Error(_) -> None
          }
      }
    }
  }
}

fn index_constants(
  package_name: String,
  mod_name: String,
  const_defs: List(glance.Definition(glance.Constant)),
  mod_iface: Option(interface.ModuleInterface),
  alias_to_module: Dict(String, String),
  unqualified_types: Dict(String, #(String, String)),
  mod_to_pkg: Dict(String, String),
) -> Dict(String, ConstantInfo) {
  list.fold(const_defs, dict.new(), fn(acc, def) {
    let c = def.definition
    let resolved_type = case mod_iface {
      Some(mi) ->
        case dict.get(mi.constants, c.name) {
          Ok(rc) -> Some(rc.type_)
          Error(_) ->
            option.map(c.annotation, fn(t) {
              ast_type_to_resolved(
                t,
                [],
                package_name,
                mod_name,
                alias_to_module,
                unqualified_types,
                mod_to_pkg,
              )
            })
        }
      None ->
        option.map(c.annotation, fn(t) {
          ast_type_to_resolved(
            t,
            [],
            package_name,
            mod_name,
            alias_to_module,
            unqualified_types,
            mod_to_pkg,
          )
        })
    }
    let info =
      ConstantInfo(
        module: mod_name,
        name: c.name,
        publicity: c.publicity,
        resolved_type:,
      )
    dict.insert(acc, c.name, info)
  })
}

fn ast_type_to_resolved(
  ty: glance.Type,
  type_params: List(String),
  package_name: String,
  current_module: String,
  alias_to_module: Dict(String, String),
  unqualified_types: Dict(String, #(String, String)),
  mod_to_pkg: Dict(String, String),
) -> ResolvedType {
  case ty {
    glance.NamedType(name:, module: mod_opt, parameters:, ..) -> {
      let #(resolved_pkg, resolved_mod, resolved_name) = case mod_opt {
        Some(alias) -> {
          let target_mod =
            dict.get(alias_to_module, alias)
            |> result.unwrap(alias)
          let target_pkg =
            dict.get(mod_to_pkg, target_mod)
            |> result.unwrap(package_name)
          #(target_pkg, target_mod, name)
        }
        None ->
          case dict.get(unqualified_types, name) {
            Ok(#(target_mod, orig_name)) -> {
              let target_pkg =
                dict.get(mod_to_pkg, target_mod)
                |> result.unwrap(package_name)
              #(target_pkg, target_mod, orig_name)
            }
            Error(_) ->
              case is_builtin_prelude_type(name) {
                True -> #("", "gleam", name)
                False -> #(package_name, current_module, name)
              }
          }
      }
      let resolved_params =
        list.map(parameters, fn(p) {
          ast_type_to_resolved(
            p,
            type_params,
            package_name,
            current_module,
            alias_to_module,
            unqualified_types,
            mod_to_pkg,
          )
        })
      NamedType(
        name: resolved_name,
        package: resolved_pkg,
        module: resolved_mod,
        parameters: resolved_params,
      )
    }

    glance.TupleType(elements:, ..) ->
      TupleType(
        elements: list.map(elements, fn(el) {
          ast_type_to_resolved(
            el,
            type_params,
            package_name,
            current_module,
            alias_to_module,
            unqualified_types,
            mod_to_pkg,
          )
        }),
      )

    glance.FunctionType(parameters:, return:, ..) ->
      FnType(
        parameters: list.map(parameters, fn(p) {
          ast_type_to_resolved(
            p,
            type_params,
            package_name,
            current_module,
            alias_to_module,
            unqualified_types,
            mod_to_pkg,
          )
        }),
        return: ast_type_to_resolved(
          return,
          type_params,
          package_name,
          current_module,
          alias_to_module,
          unqualified_types,
          mod_to_pkg,
        ),
      )

    glance.VariableType(name:, ..) | glance.HoleType(name:, ..) ->
      VariableType(id: find_type_param_index(type_params, name, 0))
  }
}

fn find_type_param_index(
  params: List(String),
  target: String,
  idx: Int,
) -> Int {
  case params {
    [] -> idx
    [head, ..tail] ->
      case head == target {
        True -> idx
        False -> find_type_param_index(tail, target, idx + 1)
      }
  }
}

fn is_builtin_prelude_type(name: String) -> Bool {
  case name {
    "Int"
    | "Float"
    | "String"
    | "Bool"
    | "Nil"
    | "List"
    | "Result"
    | "BitArray"
    | "UtfCodepoint" -> True
    _ -> False
  }
}

fn compute_transitive_type_flags(
  modules: Dict(String, ModuleSymbols),
  mod_to_pkg: Dict(String, String),
  ffi_metadata: FfiMetadata,
) -> Dict(String, ModuleSymbols) {
  let all_types =
    dict.fold(modules, dict.new(), fn(acc, mod_name, mod_syms) {
      dict.fold(mod_syms.types, acc, fn(inner, type_name, type_info) {
        dict.insert(inner, #(mod_name, type_name), #(
          type_info.external_type,
          type_info.variants,
        ))
      })
    })

  let all_aliases =
    dict.fold(modules, dict.new(), fn(acc, mod_name, mod_syms) {
      let pkg_name = dict.get(mod_to_pkg, mod_name) |> result.unwrap("")
      dict.fold(mod_syms.type_aliases, acc, fn(inner, alias_name, ta) {
        let resolved =
          ast_type_to_resolved(
            ta.aliased,
            ta.parameters,
            pkg_name,
            mod_name,
            mod_syms.alias_to_module,
            mod_syms.unqualified_types,
            mod_to_pkg,
          )
        dict.insert(inner, #(mod_name, alias_name), resolved)
      })
    })

  dict.map_values(modules, fn(mod_name, mod_syms) {
    let updated_types =
      dict.map_values(mod_syms.types, fn(type_name, type_info) {
        let has_fn =
          type_key_has_function_field(
            #(mod_name, type_name),
            all_types,
            all_aliases,
            ffi_metadata,
            set.new(),
          )
        TypeInfo(..type_info, has_function_field: has_fn)
      })
    ModuleSymbols(..mod_syms, types: updated_types)
  })
}

fn type_key_has_function_field(
  key: #(String, String),
  all_types: Dict(#(String, String), #(Option(ExternalType), List(VariantInfo))),
  all_aliases: Dict(#(String, String), ResolvedType),
  ffi_metadata: FfiMetadata,
  visited: Set(#(String, String)),
) -> Bool {
  case set.contains(visited, key) {
    True -> False
    False ->
      case dict.get(all_types, key) {
        Error(_) ->
          case dict.get(all_aliases, key) {
            Ok(aliased_ty) ->
              resolved_type_has_function(
                aliased_ty,
                all_types,
                all_aliases,
                ffi_metadata,
                set.insert(visited, key),
              )
            Error(_) -> False
          }
        Ok(#(Some(ext), _)) ->
          !ffi_meta.is_derivable(ffi_metadata, ext.package, ext.type_name)
        Ok(#(None, variants)) -> {
          let next_visited = set.insert(visited, key)
          list.any(variants, fn(variant) {
            list.any(variant.fields, fn(field) {
              case field.resolved_type {
                Some(ty) ->
                  resolved_type_has_function(
                    ty,
                    all_types,
                    all_aliases,
                    ffi_metadata,
                    next_visited,
                  )
                None -> False
              }
            })
          })
        }
      }
  }
}

fn resolved_type_has_function(
  ty: ResolvedType,
  all_types: Dict(#(String, String), #(Option(ExternalType), List(VariantInfo))),
  all_aliases: Dict(#(String, String), ResolvedType),
  ffi_metadata: FfiMetadata,
  visited: Set(#(String, String)),
) -> Bool {
  case ty {
    FnType(_, _) -> True
    VariableType(_) -> False
    TupleType(elements:) ->
      list.any(elements, fn(el) {
        resolved_type_has_function(
          el,
          all_types,
          all_aliases,
          ffi_metadata,
          visited,
        )
      })
    NamedType(name:, module:, parameters:, ..) ->
      list.any(parameters, fn(p) {
        resolved_type_has_function(
          p,
          all_types,
          all_aliases,
          ffi_metadata,
          visited,
        )
      })
      || type_key_has_function_field(
        #(module, name),
        all_types,
        all_aliases,
        ffi_metadata,
        visited,
      )
  }
}

/// Compute the set of function names in `ast_mod` that are reachable from
/// public functions, `main`, `*_test` tests, and public constants, stopping at
/// functions mapped to a MoonBit FFI target.
pub fn reachable_private_functions(
  ast_mod: glance.Module,
  functions: Dict(String, FunctionInfo),
) -> Set(String) {
  reachable_private_functions_for_branch(ast_mod, functions, PreferErlang)
}

/// Like `reachable_private_functions`, filtering `@target(...)` definitions
/// according to `branch`.
pub fn reachable_private_functions_for_branch(
  ast_mod: glance.Module,
  functions: Dict(String, FunctionInfo),
  branch: TargetBranch,
) -> Set(String) {
  let active_fns =
    ast_mod.functions
    |> list.filter(fn(def) { !is_excluded_for_branch(def.attributes, branch) })
    |> list.map(fn(def) { def.definition })

  let fn_map =
    list.fold(active_fns, dict.new(), fn(acc, f) { dict.insert(acc, f.name, f) })

  let active_consts =
    ast_mod.constants
    |> list.filter(fn(def) { !is_excluded_for_branch(def.attributes, branch) })
    |> list.map(fn(def) { def.definition })

  let const_map =
    list.fold(active_consts, dict.new(), fn(acc, c) {
      dict.insert(acc, c.name, c.value)
    })

  let fn_roots =
    list.filter_map(active_fns, fn(f) {
      let is_root =
        f.publicity == glance.Public
        || f.name == "main"
        || string.ends_with(f.name, "_test")
      case is_root {
        True -> Ok(f.name)
        False -> Error(Nil)
      }
    })

  let const_roots =
    list.filter_map(active_consts, fn(c) {
      case c.publicity {
        glance.Public -> Ok(c.name)
        glance.Private -> Error(Nil)
      }
    })

  bfs_reachable_fns(
    fn_roots,
    const_roots,
    set.from_list(fn_roots),
    set.from_list(const_roots),
    fn_map,
    const_map,
    functions,
  )
}

fn bfs_reachable_fns(
  fn_queue: List(String),
  const_queue: List(String),
  visited_fns: Set(String),
  visited_consts: Set(String),
  fn_map: Dict(String, glance.Function),
  const_map: Dict(String, glance.Expression),
  functions: Dict(String, FunctionInfo),
) -> Set(String) {
  case fn_queue, const_queue {
    [], [] -> visited_fns
    [fn_name, ..rest_fns], _ -> {
      let has_ffi = case dict.get(functions, fn_name) {
        Ok(info) -> info.ffi != None
        Error(_) -> False
      }
      case has_ffi, dict.get(fn_map, fn_name) {
        False, Ok(f) -> {
          let param_bound =
            list.fold(f.parameters, set.new(), fn(b, p) {
              case p.name {
                glance.Named(n) -> set.insert(b, n)
                glance.Discarded(_) -> b
              }
            })
          let refs = collect_stmts_var_refs(f.body, param_bound, set.new())
          enqueue_refs(
            refs,
            rest_fns,
            const_queue,
            visited_fns,
            visited_consts,
            fn_map,
            const_map,
            functions,
          )
        }
        _, _ ->
          bfs_reachable_fns(
            rest_fns,
            const_queue,
            visited_fns,
            visited_consts,
            fn_map,
            const_map,
            functions,
          )
      }
    }
    [], [const_name, ..rest_consts] ->
      case dict.get(const_map, const_name) {
        Ok(expr) -> {
          let refs = collect_expr_var_refs(expr, set.new(), set.new())
          enqueue_refs(
            refs,
            [],
            rest_consts,
            visited_fns,
            visited_consts,
            fn_map,
            const_map,
            functions,
          )
        }
        Error(_) ->
          bfs_reachable_fns(
            [],
            rest_consts,
            visited_fns,
            visited_consts,
            fn_map,
            const_map,
            functions,
          )
      }
  }
}

fn enqueue_refs(
  refs: Set(String),
  fn_queue: List(String),
  const_queue: List(String),
  visited_fns: Set(String),
  visited_consts: Set(String),
  fn_map: Dict(String, glance.Function),
  const_map: Dict(String, glance.Expression),
  functions: Dict(String, FunctionInfo),
) -> Set(String) {
  let #(next_fn_q, next_const_q, next_vfns, next_vconsts) =
    set.fold(
      refs,
      #(fn_queue, const_queue, visited_fns, visited_consts),
      fn(acc, name) {
        let #(fq, cq, vf, vc) = acc
        let #(fq1, vf1) = case
          dict.has_key(fn_map, name) && !set.contains(vf, name)
        {
          True -> #([name, ..fq], set.insert(vf, name))
          False -> #(fq, vf)
        }
        case dict.has_key(const_map, name) && !set.contains(vc, name) {
          True -> #(fq1, [name, ..cq], vf1, set.insert(vc, name))
          False -> #(fq1, cq, vf1, vc)
        }
      },
    )
  bfs_reachable_fns(
    next_fn_q,
    next_const_q,
    next_vfns,
    next_vconsts,
    fn_map,
    const_map,
    functions,
  )
}

fn glance_pattern_bound_vars(
  pat: glance.Pattern,
  acc: Set(String),
) -> Set(String) {
  case pat {
    glance.PatternVariable(name:, ..) -> set.insert(acc, name)
    glance.PatternAssignment(pattern:, name:, ..) ->
      glance_pattern_bound_vars(pattern, set.insert(acc, name))
    glance.PatternTuple(elements:, ..) ->
      list.fold(elements, acc, fn(a, p) { glance_pattern_bound_vars(p, a) })
    glance.PatternList(elements:, tail:, ..) -> {
      let a1 =
        list.fold(elements, acc, fn(a, p) { glance_pattern_bound_vars(p, a) })
      case tail {
        Some(t) -> glance_pattern_bound_vars(t, a1)
        None -> a1
      }
    }
    glance.PatternVariant(arguments:, ..) ->
      list.fold(arguments, acc, fn(a, arg) {
        case arg {
          glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
            glance_pattern_bound_vars(item, a)
          glance.ShorthandField(label:, ..) -> set.insert(a, label)
        }
      })
    glance.PatternConcatenate(prefix_name:, rest_name:, ..) -> {
      let a1 = case prefix_name {
        Some(glance.Named(n)) -> set.insert(acc, n)
        _ -> acc
      }
      case rest_name {
        glance.Named(n) -> set.insert(a1, n)
        glance.Discarded(_) -> a1
      }
    }
    glance.PatternBitString(segments:, ..) ->
      list.fold(segments, acc, fn(a, seg) {
        glance_pattern_bound_vars(seg.0, a)
      })
    glance.PatternInt(..)
    | glance.PatternFloat(..)
    | glance.PatternString(..)
    | glance.PatternDiscard(..) -> acc
  }
}

fn collect_stmts_var_refs(
  stmts: List(glance.Statement),
  bound: Set(String),
  acc: Set(String),
) -> Set(String) {
  case stmts {
    [] -> acc
    [stmt, ..rest] -> {
      let #(next_bound, next_acc) = case stmt {
        glance.Expression(expr) -> #(
          bound,
          collect_expr_var_refs(expr, bound, acc),
        )
        glance.Use(patterns:, function:, ..) -> {
          let acc1 = collect_expr_var_refs(function, bound, acc)
          let b1 =
            list.fold(patterns, bound, fn(b, up) {
              glance_pattern_bound_vars(up.pattern, b)
            })
          #(b1, acc1)
        }
        glance.Assignment(kind:, pattern:, value:, ..) -> {
          let acc1 = collect_expr_var_refs(value, bound, acc)
          let acc2 = case kind {
            glance.LetAssert(message: Some(msg)) ->
              collect_expr_var_refs(msg, bound, acc1)
            _ -> acc1
          }
          #(glance_pattern_bound_vars(pattern, bound), acc2)
        }
        glance.Assert(expression:, message:, ..) -> {
          let acc1 = collect_expr_var_refs(expression, bound, acc)
          let acc2 = case message {
            Some(msg) -> collect_expr_var_refs(msg, bound, acc1)
            None -> acc1
          }
          #(bound, acc2)
        }
      }
      collect_stmts_var_refs(rest, next_bound, next_acc)
    }
  }
}

fn collect_field_var_refs(
  fields: List(glance.Field(glance.Expression)),
  bound: Set(String),
  acc: Set(String),
) -> Set(String) {
  list.fold(fields, acc, fn(a, f) {
    case f {
      glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
        collect_expr_var_refs(item, bound, a)
      glance.ShorthandField(label:, ..) ->
        case set.contains(bound, label) {
          True -> a
          False -> set.insert(a, label)
        }
    }
  })
}

fn collect_expr_var_refs(
  expr: glance.Expression,
  bound: Set(String),
  acc: Set(String),
) -> Set(String) {
  case expr {
    glance.Int(..) | glance.Float(..) | glance.String(..) -> acc
    glance.Variable(name:, ..) ->
      case set.contains(bound, name) {
        True -> acc
        False -> set.insert(acc, name)
      }
    glance.NegateInt(value:, ..) | glance.NegateBool(value:, ..) ->
      collect_expr_var_refs(value, bound, acc)
    glance.Block(statements:, ..) ->
      collect_stmts_var_refs(statements, bound, acc)
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      case message {
        Some(msg) -> collect_expr_var_refs(msg, bound, acc)
        None -> acc
      }
    glance.Tuple(elements:, ..) ->
      list.fold(elements, acc, fn(a, e) { collect_expr_var_refs(e, bound, a) })
    glance.List(elements:, rest:, ..) -> {
      let acc1 =
        list.fold(elements, acc, fn(a, e) { collect_expr_var_refs(e, bound, a) })
      case rest {
        Some(r) -> collect_expr_var_refs(r, bound, acc1)
        None -> acc1
      }
    }
    glance.Fn(arguments:, body:, ..) -> {
      let fn_bound =
        list.fold(arguments, bound, fn(b, arg) {
          case arg.name {
            glance.Named(n) -> set.insert(b, n)
            glance.Discarded(_) -> b
          }
        })
      collect_stmts_var_refs(body, fn_bound, acc)
    }
    glance.RecordUpdate(record:, fields:, ..) -> {
      let acc1 = collect_expr_var_refs(record, bound, acc)
      list.fold(fields, acc1, fn(a, f) {
        case f.item {
          Some(item) -> collect_expr_var_refs(item, bound, a)
          None ->
            case set.contains(bound, f.label) {
              True -> a
              False -> set.insert(a, f.label)
            }
        }
      })
    }
    glance.FieldAccess(container:, ..) ->
      collect_expr_var_refs(container, bound, acc)
    glance.Call(function:, arguments:, ..) ->
      collect_field_var_refs(
        arguments,
        bound,
        collect_expr_var_refs(function, bound, acc),
      )
    glance.TupleIndex(tuple:, ..) -> collect_expr_var_refs(tuple, bound, acc)
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      collect_expr_var_refs(function, bound, acc)
      |> collect_field_var_refs(arguments_before, bound, _)
      |> collect_field_var_refs(arguments_after, bound, _)
    glance.BitString(segments:, ..) ->
      list.fold(segments, acc, fn(a, seg) {
        let #(inner, opts) = seg
        let a1 = collect_expr_var_refs(inner, bound, a)
        list.fold(opts, a1, fn(a2, opt) {
          case opt {
            glance.SizeValueOption(size_expr) ->
              collect_expr_var_refs(size_expr, bound, a2)
            _ -> a2
          }
        })
      })
    glance.Case(subjects:, clauses:, ..) -> {
      let acc1 =
        list.fold(subjects, acc, fn(a, s) { collect_expr_var_refs(s, bound, a) })
      list.fold(clauses, acc1, fn(a, clause) {
        let clause_bound =
          list.fold(clause.patterns, bound, fn(b, alt) {
            list.fold(alt, b, fn(b2, p) { glance_pattern_bound_vars(p, b2) })
          })
        let a1 = case clause.guard {
          Some(g) -> collect_expr_var_refs(g, clause_bound, a)
          None -> a
        }
        collect_expr_var_refs(clause.body, clause_bound, a1)
      })
    }
    glance.BinaryOperator(left:, right:, ..) ->
      collect_expr_var_refs(
        right,
        bound,
        collect_expr_var_refs(left, bound, acc),
      )
    glance.Echo(expression:, message:, ..) -> {
      let acc1 = case expression {
        Some(e) -> collect_expr_var_refs(e, bound, acc)
        None -> acc
      }
      case message {
        Some(m) -> collect_expr_var_refs(m, bound, acc1)
        None -> acc1
      }
    }
  }
}
