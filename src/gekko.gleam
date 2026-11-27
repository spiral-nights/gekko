import argv
import emit/pkg_config
import emit/wit_bridge
import filepath
import gleam/dict.{type Dict}
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import moonbit/bindgen
import moonbit/bindgen_adapter.{type BindOptions, BindOptions}
import project/cmd
import project/diagnostics
import project/fs
import project/scaffold
import project/shim_cli
import project/workspace
import simplifile
import wit/gleam_gen
import wit/parser as wit_parser

pub const version = "0.1.0"

/// Outcome returned by `build_project` / `build_project_in_dir`.
pub type BuildOutput {
  BuiltArtifact(path: String, warnings: String)
  BuiltLibrary(project_name: String, warnings: String)
}

pub type CliAction {
  CheckAction(
    root: String,
    out: Option(String),
    target: Option(String),
    strict: Bool,
  )
  BuildAction(
    root: String,
    out: Option(String),
    work_dir: Option(String),
    target: String,
    release: Bool,
    strict: Bool,
  )
  TestAction(
    root: String,
    out: Option(String),
    target: Option(String),
    strict: Bool,
  )
  RunAction(
    root: String,
    out: Option(String),
    target: Option(String),
    program_args: List(String),
  )
  NewAction(name: String, with_wit: Bool)
  InitAction(root: String, with_wit: Bool)
  CleanAction(root: String)
  DoctorAction
  WitGenAction(root: String, wit_dir: Option(String), world: Option(String))
  WitCheckAction(
    root: String,
    wit_dir: Option(String),
    world: Option(String),
    out: Option(String),
  )
  WitBuildAction(
    root: String,
    wit_dir: Option(String),
    world: Option(String),
    out: Option(String),
    output: Option(String),
    release: Bool,
  )
  MoonbitBindAction(
    root: String,
    package: String,
    module: Option(String),
    out: Option(String),
    only: List(String),
    map_types: Dict(String, #(String, String)),
    typed_errors: Bool,
    adapter: Option(String),
  )
  ShimNewAction(
    root: String,
    package: String,
    out: Option(String),
    moonbit: Bool,
  )
  ShimInitAction(root: String, moonbit: Bool)
  ShimInspectAction(root: String, package: Option(String))
  ShimPatchDeclAction(root: String, target: String, moonbit: Bool)
  ShimPatchModuleAction(root: String, module: String, moonbit: Bool)
  ShimSyncAction(root: String)
  ShimMigrateAction(root: String)
  ShimAckAction(root: String)
  HelpAction
  VersionAction
}

type BindFlags {
  BindFlags(
    root: String,
    package: Option(String),
    module: Option(String),
    out: Option(String),
    only: List(String),
    map_types: Dict(String, #(String, String)),
    typed_errors: Bool,
    adapter: Option(String),
  )
}

type WitFlags {
  WitFlags(
    root: String,
    wit_dir: Option(String),
    world: Option(String),
    out: Option(String),
    output: Option(String),
  )
}

pub fn main() -> Nil {
  let args = argv.load().arguments
  case parse_args(args) {
    Error(msg) -> {
      io.println_error("Error: " <> msg)
      print_usage()
      halt(1)
    }
    Ok(HelpAction) -> print_usage()
    Ok(VersionAction) -> io.println("gekko " <> version)
    Ok(CheckAction(root:, out:, target:, strict:)) -> {
      require_tools_or_halt(["gleam", "moon"])
      run_moon_workflow(root, out, "check", False, target, True, strict, [])
    }
    Ok(BuildAction(root:, out:, work_dir:, target:, release:, strict:)) -> {
      require_tools_or_halt(["gleam", "moon"])
      run_build(root, out, work_dir, target, release, strict)
    }
    Ok(TestAction(root:, out:, target:, strict:)) -> {
      require_tools_or_halt(["gleam", "moon"])
      run_moon_workflow(root, out, "test", False, target, True, strict, [])
    }
    Ok(RunAction(root:, out:, target:, program_args:)) -> {
      require_tools_or_halt(["gleam", "moon"])
      run_moon_workflow(
        root,
        out,
        "run",
        True,
        target,
        False,
        False,
        program_args,
      )
    }
    Ok(NewAction(name:, with_wit:)) -> run_new(name, with_wit)
    Ok(InitAction(root:, with_wit:)) -> run_init(root, with_wit)
    Ok(CleanAction(root:)) -> run_clean(root)
    Ok(DoctorAction) -> run_doctor_cmd()
    Ok(WitGenAction(root:, wit_dir:, world:)) ->
      run_wit_gen(root, wit_dir, world)
    Ok(WitCheckAction(root:, wit_dir:, world:, out:)) -> {
      require_tools_or_halt(["gleam", "moon", "wit-bindgen"])
      run_wit_check(root, wit_dir, world, out)
    }
    Ok(WitBuildAction(root:, wit_dir:, world:, out:, output:, release:)) -> {
      require_tools_or_halt(["gleam", "moon", "wit-bindgen", "wasm-tools"])
      run_wit_build(root, wit_dir, world, out, output, release)
    }
    Ok(MoonbitBindAction(
      root:,
      package:,
      module:,
      out:,
      only:,
      map_types:,
      typed_errors:,
      adapter:,
    )) -> {
      require_tools_or_halt(["moon"])
      run_moonbit_bind(
        root,
        package,
        module,
        out,
        BindOptions(only:, map_types:, typed_errors:, adapter_name: adapter),
      )
    }
    Ok(ShimNewAction(root:, package:, out:, moonbit:)) -> {
      require_tools_or_halt(["gleam"])
      run_shim_new(root, package, out, moonbit)
    }
    Ok(ShimInitAction(root:, moonbit:)) -> {
      require_tools_or_halt(["gleam"])
      run_shim_init(root, moonbit)
    }
    Ok(ShimInspectAction(root:, package:)) -> {
      require_tools_or_halt(["gleam"])
      run_shim_inspect(root, package)
    }
    Ok(ShimPatchDeclAction(root:, target:, moonbit:)) -> {
      require_tools_or_halt(["gleam"])
      run_shim_patch_decl(root, target, moonbit)
    }
    Ok(ShimPatchModuleAction(root:, module:, moonbit:)) -> {
      require_tools_or_halt(["gleam"])
      run_shim_patch_module(root, module, moonbit)
    }
    Ok(ShimSyncAction(root:)) -> {
      require_tools_or_halt(["gleam"])
      run_shim_sync(root)
    }
    Ok(ShimMigrateAction(root:)) -> {
      run_shim_migrate(root)
    }
    Ok(ShimAckAction(root:)) -> {
      require_tools_or_halt(["gleam"])
      run_shim_ack(root)
    }
  }
}

fn require_tools_or_halt(tools: List(String)) -> Nil {
  case cmd.require_tools(tools) {
    Error(msg) -> {
      io.println_error("gekko error: " <> msg)
      halt(1)
    }
    Ok(Nil) ->
      case list.contains(tools, "moon") {
        False -> Nil
        True ->
          case cmd.check_moon_version_compatible() {
            Ok(Nil) -> Nil
            Error(msg) -> {
              io.println_error("gekko error: " <> msg)
              halt(1)
            }
          }
      }
  }
}

fn run_moon_workflow(
  root: String,
  out: Option(String),
  moon_subcmd: String,
  pass_main_pkg: Bool,
  target: Option(String),
  include_tests: Bool,
  strict: Bool,
  program_args: List(String),
) -> Nil {
  let out_dir = option.unwrap(out, filepath.join(root, "build/moonbit"))
  case workspace.transpile_project_with_tests(root, out_dir, include_tests) {
    Error(err) -> {
      io.println_error("gekko error: " <> err)
      halt(1)
    }
    Ok(summary) -> {
      list.each(summary.warnings, io.println_error)
      case check_strict_missing(strict, summary.missing_externals) {
        Error(err) -> {
          io.println_error("gekko error: " <> err)
          halt(1)
        }
        Ok(Nil) -> Nil
      }
      let target_args = case target {
        Some(t) -> [moon_subcmd, "--target", t]
        None -> [moon_subcmd]
      }
      let pkg_args = case pass_main_pkg {
        True -> {
          let pkg_dir =
            dict.get(summary.module_pkg_dirs, summary.project_name)
            |> result.unwrap(pkg_config.module_to_pkg_dir(summary.project_name))
          list.append(target_args, [pkg_dir])
        }
        False -> target_args
      }
      let moon_args = case program_args {
        [] -> pkg_args
        _ -> list.flatten([pkg_args, ["--"], program_args])
      }
      let res =
        cmd.run_moon_streaming_with_auto_update(moon_args, summary.out_dir)
      case res.exit_code {
        0 -> Nil
        code -> {
          let annotated =
            diagnostics.annotate_moon_output(summary.out_dir, res.output)
          case annotated != res.output {
            True -> io.println_error("\n" <> annotated)
            False -> Nil
          }
          halt(code)
        }
      }
    }
  }
}

fn check_strict_missing(
  strict: Bool,
  missing_externals: List(String),
) -> Result(Nil, String) {
  case strict, missing_externals {
    True, [_, ..] ->
      Error(
        "Missing MoonBit implementations for @external functions (--strict):\n  - "
        <> string.join(missing_externals, "\n  - "),
      )
    _, _ -> Ok(Nil)
  }
}

fn run_build(
  root: String,
  out: Option(String),
  work_dir: Option(String),
  target: String,
  release: Bool,
  strict: Bool,
) -> Nil {
  case
    build_project_with_strict_options(
      root,
      out,
      work_dir,
      target,
      ".",
      release,
      strict,
    )
  {
    Error(err) -> {
      io.println_error("gekko error: " <> err)
      halt(1)
    }
    Ok(BuiltArtifact(path:, warnings:)) -> {
      case warnings {
        "" -> Nil
        text -> io.println(text)
      }
      io.println("Built " <> target <> ": " <> path)
    }
    Ok(BuiltLibrary(project_name:, warnings:)) -> {
      case warnings {
        "" -> Nil
        text -> io.println(text)
      }
      io.println(
        "Built library "
        <> project_name
        <> " ("
        <> target
        <> ") — no pub fn main() entrypoint; no standalone output file emitted.",
      )
    }
  }
}

/// Transpile and build a Gleam project, copying the built artifact to the
/// current working directory (or the path specified by `out`).
pub fn build_project(
  root: String,
  out: Option(String),
  target: String,
) -> Result(BuildOutput, String) {
  build_project_in_dir(root, out, target, ".")
}

/// Transpile and build a Gleam project, resolving relative `out` paths against
/// `output_base_dir` (defaults to `.` in CLI execution).
pub fn build_project_in_dir(
  root: String,
  out: Option(String),
  target: String,
  output_base_dir: String,
) -> Result(BuildOutput, String) {
  build_project_with_profile(root, out, target, output_base_dir, False)
}

/// Like `build_project_in_dir`, optionally building with `moon build --release`.
pub fn build_project_with_profile(
  root: String,
  out: Option(String),
  target: String,
  output_base_dir: String,
  release: Bool,
) -> Result(BuildOutput, String) {
  build_project_with_options(root, out, None, target, output_base_dir, release)
}

/// Like `build_project_with_profile`, with configurable intermediate `work_dir_opt`.
pub fn build_project_with_options(
  root: String,
  out: Option(String),
  work_dir_opt: Option(String),
  target: String,
  output_base_dir: String,
  release: Bool,
) -> Result(BuildOutput, String) {
  build_project_with_strict_options(
    root,
    out,
    work_dir_opt,
    target,
    output_base_dir,
    release,
    False,
  )
}

/// Like `build_project_with_options`, optionally failing when `--strict` finds
/// unimplemented `@external` functions.
pub fn build_project_with_strict_options(
  root: String,
  out: Option(String),
  work_dir_opt: Option(String),
  target: String,
  output_base_dir: String,
  release: Bool,
  strict: Bool,
) -> Result(BuildOutput, String) {
  let work_dir =
    option.unwrap(work_dir_opt, filepath.join(root, "build/moonbit"))
  use summary <- result.try(workspace.transpile_project_with_tests(
    root,
    work_dir,
    False,
  ))
  use _ <- result.try(check_strict_missing(strict, summary.missing_externals))

  let build_args = case release {
    True -> ["build", "--release", "--target", target]
    False -> ["build", "--target", target]
  }
  let res = cmd.run_moon_with_auto_update(build_args, summary.out_dir)
  use _ <- result.try(case res.exit_code {
    0 -> Ok(Nil)
    _ -> Error(diagnostics.annotate_moon_output(summary.out_dir, res.output))
  })

  let moon_warnings = filter_moon_build_warnings(res.output)
  let overlay_warnings = string.join(summary.warnings, "\n")
  let warnings = case overlay_warnings, moon_warnings {
    "", _ -> moon_warnings
    _, "" -> overlay_warnings
    _, _ -> overlay_warnings <> "\n" <> moon_warnings
  }
  let root_pkg_dir =
    dict.get(summary.module_pkg_dirs, summary.project_name)
    |> result.unwrap(pkg_config.module_to_pkg_dir(summary.project_name))
  let expected_pkg = summary.project_name <> "/" <> root_pkg_dir
  let parsed_artifacts = parse_moon_build_artifacts(res.output)

  let src_artifact =
    find_built_artifact(
      summary.out_dir,
      root_pkg_dir,
      expected_pkg,
      target,
      parsed_artifacts,
      release,
    )

  let apply_base = fn(rel_or_abs) {
    case output_base_dir != "." && !filepath.is_absolute(rel_or_abs) {
      True -> filepath.join(output_base_dir, rel_or_abs)
      False -> rel_or_abs
    }
  }

  case src_artifact {
    Some(src_path) -> {
      let default_name = filepath.base_name(src_path)
      use dest_display <- result.try(
        resolve_build_output_path(out, default_name, fn(p) {
          simplifile.is_directory(apply_base(p)) == Ok(True)
        }),
      )
      let dest_fs = apply_base(dest_display)
      use _ <- result.try(copy_built_artifact(src_path, dest_fs))
      Ok(BuiltArtifact(path: dest_display, warnings:))
    }
    None ->
      case out {
        None -> Ok(BuiltLibrary(project_name: summary.project_name, warnings:))
        Some(user_out) ->
          Error(
            "Cannot write '--out "
            <> user_out
            <> "': project '"
            <> summary.project_name
            <> "' has no 'pub fn main()' entrypoint in src/"
            <> summary.project_name
            <> ".gleam, so no standalone "
            <> target
            <> " artifact was produced.",
          )
      }
  }
}

fn find_built_artifact(
  work_dir: String,
  root_pkg_dir: String,
  expected_pkg: String,
  target: String,
  parsed_artifacts: List(#(String, String, String)),
  release: Bool,
) -> Option(String) {
  let resolve_in_work = fn(p) {
    case filepath.is_absolute(p) {
      True -> p
      False -> filepath.join(work_dir, p)
    }
  }
  let from_expected =
    list.find_map(parsed_artifacts, fn(entry) {
      let #(pkg, backend, path) = entry
      case pkg == expected_pkg && backend == target {
        True -> Ok(resolve_in_work(path))
        False -> Error(Nil)
      }
    })
  case from_expected {
    Ok(p) -> Some(p)
    Error(_) -> {
      let candidates = case target {
        "wasm" | "wasm-gc" -> [root_pkg_dir <> ".wasm"]
        "js" -> [root_pkg_dir <> ".js"]
        "native" -> [root_pkg_dir <> ".exe", root_pkg_dir]
        _ -> []
      }
      let base_dir =
        work_dir
        |> filepath.join("_build")
        |> filepath.join(target)
        |> filepath.join(case release {
          True -> "release"
          False -> "debug"
        })
        |> filepath.join("build")
        |> filepath.join(root_pkg_dir)
      let from_fallback =
        list.find_map(candidates, fn(name) {
          let p = filepath.join(base_dir, name)
          case simplifile.is_file(p) {
            Ok(True) -> Ok(p)
            _ -> Error(Nil)
          }
        })
      case from_fallback {
        Ok(p) -> Some(p)
        Error(_) ->
          case list.filter(parsed_artifacts, fn(entry) { entry.1 == target }) {
            [#(_, _, path)] -> Some(resolve_in_work(path))
            _ -> None
          }
      }
    }
  }
}

fn copy_built_artifact(
  src_path: String,
  dest_path: String,
) -> Result(Nil, String) {
  let parent = filepath.directory_name(dest_path)
  use _ <- result.try(case parent {
    "" | "." -> Ok(Nil)
    _ ->
      simplifile.create_directory_all(parent)
      |> result.map_error(fn(err) {
        "Failed to create output directory '"
        <> parent
        <> "': "
        <> simplifile.describe_error(err)
      })
  })

  let same_target = case
    simplifile.resolve(src_path),
    simplifile.resolve(dest_path)
  {
    Ok(a), Ok(b) -> a == b
    _, _ -> False
  }

  case same_target {
    True -> Ok(Nil)
    False -> {
      case simplifile.is_file(dest_path) {
        Ok(True) -> {
          let _ = simplifile.delete_file(at: dest_path)
          Nil
        }
        _ -> Nil
      }
      use _ <- result.try(
        simplifile.copy_file(at: src_path, to: dest_path)
        |> result.map_error(fn(err) {
          "Failed to copy built artifact to '"
          <> dest_path
          <> "': "
          <> simplifile.describe_error(err)
        }),
      )
      case simplifile.file_info(src_path) {
        Ok(info) ->
          simplifile.set_permissions_octal(
            for_file_at: dest_path,
            to: simplifile.file_info_permissions_octal(info),
          )
          |> result.map_error(fn(err) {
            "Failed to set permissions on '"
            <> dest_path
            <> "': "
            <> simplifile.describe_error(err)
          })
        Error(_) -> Ok(Nil)
      }
    }
  }
}

/// Resolve the destination file path for `gekko build` given `--out` / `-o`,
/// the artifact's default filename, and a directory existence check.
pub fn resolve_build_output_path(
  out: Option(String),
  default_name: String,
  is_dir: fn(String) -> Bool,
) -> Result(String, String) {
  case out {
    None -> Ok(default_name)
    Some("") -> Error("Output path cannot be empty.")
    Some(raw) ->
      case string.ends_with(raw, "/") {
        True -> Ok(filepath.join(raw, default_name))
        False ->
          case is_dir(raw) {
            True ->
              Error(
                "Output path '"
                <> raw
                <> "' is an existing directory. Pass a file path or append '/' to place "
                <> default_name
                <> " inside it.",
              )
            False -> Ok(raw)
          }
      }
  }
}

/// Parse the `Artifacts:` section printed by `moon build` into
/// `#(package, target_backend, artifact_path)` tuples.
pub fn parse_moon_build_artifacts(
  output: String,
) -> List(#(String, String, String)) {
  output
  |> string.split("\n")
  |> parse_artifact_lines(False, [])
}

fn parse_artifact_lines(
  lines: List(String),
  in_artifacts: Bool,
  rev_acc: List(#(String, String, String)),
) -> List(#(String, String, String)) {
  case lines {
    [] -> list.reverse(rev_acc)
    [raw_line, ..rest] -> {
      let line = strip_cr(raw_line)
      case in_artifacts {
        False ->
          case string.trim(line) == "Artifacts:" {
            True -> parse_artifact_lines(rest, True, rev_acc)
            False -> parse_artifact_lines(rest, False, rev_acc)
          }
        True ->
          case
            { string.starts_with(line, " ") || string.starts_with(line, "\t") }
            && string.trim(line) != ""
          {
            True ->
              case parse_single_artifact_line(line) {
                Ok(entry) ->
                  parse_artifact_lines(rest, True, [entry, ..rev_acc])
                Error(_) -> parse_artifact_lines(rest, True, rev_acc)
              }
            False ->
              case string.trim(line) == "Artifacts:" {
                True -> parse_artifact_lines(rest, True, rev_acc)
                False -> parse_artifact_lines(rest, False, rev_acc)
              }
          }
      }
    }
  }
}

fn parse_single_artifact_line(
  line: String,
) -> Result(#(String, String, String), Nil) {
  use #(pkg, rest1) <- result.try(take_token_and_rest(line))
  use #(backend, rest2) <- result.try(take_token_and_rest(rest1))
  let path = string.trim_end(rest2)
  case pkg != "" && backend != "" && path != "" {
    True -> Ok(#(pkg, backend, path))
    False -> Error(Nil)
  }
}

fn take_token_and_rest(input: String) -> Result(#(String, String), Nil) {
  let trimmed = skip_leading_ws(string.to_graphemes(input))
  case trimmed {
    [] -> Error(Nil)
    _ -> {
      let #(tok_chars, after_tok) = take_non_ws(trimmed, [])
      let rest_chars = skip_leading_ws(after_tok)
      Ok(#(string.concat(tok_chars), string.concat(rest_chars)))
    }
  }
}

fn skip_leading_ws(chars: List(String)) -> List(String) {
  case chars {
    [" ", ..rest] | ["\t", ..rest] -> skip_leading_ws(rest)
    _ -> chars
  }
}

fn take_non_ws(
  chars: List(String),
  rev_acc: List(String),
) -> #(List(String), List(String)) {
  case chars {
    [] -> #(list.reverse(rev_acc), [])
    [" ", ..] | ["\t", ..] -> #(list.reverse(rev_acc), chars)
    [ch, ..rest] -> take_non_ws(rest, [ch, ..rev_acc])
  }
}

fn filter_moon_build_warnings(output: String) -> String {
  let kept =
    output
    |> string.split("\n")
    |> filter_warning_lines(False, [])
    |> trim_blank_lines
  string.join(kept, "\n")
}

fn filter_warning_lines(
  lines: List(String),
  in_artifacts: Bool,
  rev_acc: List(String),
) -> List(String) {
  case lines {
    [] -> list.reverse(rev_acc)
    [raw_line, ..rest] -> {
      let line = strip_cr(raw_line)
      case in_artifacts {
        True ->
          case
            { string.starts_with(line, " ") || string.starts_with(line, "\t") }
            && string.trim(line) != ""
          {
            True -> filter_warning_lines(rest, True, rev_acc)
            False -> filter_warning_lines([raw_line, ..rest], False, rev_acc)
          }
        False -> {
          let trimmed = string.trim(line)
          case trimmed == "Artifacts:" {
            True -> filter_warning_lines(rest, True, rev_acc)
            False ->
              case string.starts_with(trimmed, "Finished. moon:") {
                True -> filter_warning_lines(rest, False, rev_acc)
                False -> filter_warning_lines(rest, False, [line, ..rev_acc])
              }
          }
        }
      }
    }
  }
}

fn trim_blank_lines(lines: List(String)) -> List(String) {
  lines
  |> drop_leading_blanks
  |> list.reverse
  |> drop_leading_blanks
  |> list.reverse
}

fn drop_leading_blanks(lines: List(String)) -> List(String) {
  case lines {
    [first, ..rest] ->
      case string.trim(first) == "" {
        True -> drop_leading_blanks(rest)
        False -> lines
      }
    [] -> []
  }
}

fn strip_cr(line: String) -> String {
  case string.ends_with(line, "\r") {
    True -> string.drop_end(line, 1)
    False -> line
  }
}

fn run_new(name: String, with_wit: Bool) -> Nil {
  case scaffold.new_project(name, with_wit) {
    Error(err) -> {
      io.println_error("gekko new error: " <> err)
      halt(1)
    }
    Ok(files) -> {
      io.println("Created project '" <> name <> "':")
      list.each(files, fn(f) { io.println("  " <> filepath.join(name, f)) })
    }
  }
}

fn run_init(root: String, with_wit: Bool) -> Nil {
  case scaffold.init_project(root, with_wit) {
    Error(err) -> {
      io.println_error("gekko init error: " <> err)
      halt(1)
    }
    Ok(files) -> {
      io.println("Initialized gekko project in '" <> root <> "':")
      list.each(files, fn(f) { io.println("  " <> f) })
    }
  }
}

/// Remove generated `gekko` staging and MoonBit workspace artifacts under `root`.
pub fn clean_project(root: String) -> Result(List(String), String) {
  let dir_targets = [
    filepath.join(root, "build/moonbit"),
    filepath.join(root, "build/.gekko_staging"),
    filepath.join(root, "build/.gekko_staging_deps"),
    filepath.join(root, "build/.gekko_gprelude"),
    filepath.join(root, "moonbit/gprelude"),
    filepath.join(root, "patches/gprelude"),
    filepath.join(root, "patches/_build"),
    filepath.join(root, "patches/.mooncakes"),
  ]
  use removed_dirs <- result.try(
    list.try_fold(dir_targets, [], fn(acc, path) {
      case simplifile.is_directory(path) {
        Ok(True) -> {
          use _ <- result.try(
            simplifile.delete(file_or_dir_at: path)
            |> result.map_error(fn(err) {
              "Failed to remove '"
              <> path
              <> "': "
              <> simplifile.describe_error(err)
            }),
          )
          Ok([path, ..acc])
        }
        _ -> Ok(acc)
      }
    }),
  )
  let file_targets = [
    filepath.join(root, "patches/moon.mod"),
    filepath.join(root, "patches/.gekko_generated"),
  ]
  use removed_files <- result.try(
    list.try_fold(file_targets, removed_dirs, fn(acc, path) {
      case simplifile.is_file(path) {
        Ok(True) -> {
          use _ <- result.try(
            simplifile.delete_file(at: path)
            |> result.map_error(fn(err) {
              "Failed to remove '"
              <> path
              <> "': "
              <> simplifile.describe_error(err)
            }),
          )
          Ok([path, ..acc])
        }
        _ -> Ok(acc)
      }
    }),
  )
  let patches_dir = filepath.join(root, "patches")
  use removed_patch_files <- result.try(
    case simplifile.is_directory(patches_dir) {
      Ok(True) ->
        clean_generated_in_patches_dir(patches_dir, patches_dir, removed_files)
      _ -> Ok(removed_files)
    },
  )
  let moon_work_path = filepath.join(root, "moon.work")
  use removed_all <- result.try(case fs.has_generated_marker(moon_work_path) {
    True -> {
      use _ <- result.try(
        simplifile.delete_file(at: moon_work_path)
        |> result.map_error(fn(err) {
          "Failed to remove '"
          <> moon_work_path
          <> "': "
          <> simplifile.describe_error(err)
        }),
      )
      Ok([moon_work_path, ..removed_patch_files])
    }
    False -> Ok(removed_patch_files)
  })
  Ok(list.reverse(removed_all))
}

fn clean_generated_in_patches_dir(
  dir: String,
  patches_root: String,
  acc: List(String),
) -> Result(List(String), String) {
  use entries <- result.try(
    simplifile.read_directory(at: dir)
    |> result.map_error(fn(err) {
      "Failed to read '" <> dir <> "': " <> simplifile.describe_error(err)
    }),
  )
  use next_acc <- result.try(
    list.try_fold(list.sort(entries, string.compare), acc, fn(cur, entry) {
      let full = filepath.join(dir, entry)
      case string.starts_with(entry, ".") {
        True -> Ok(cur)
        False ->
          case simplifile.is_directory(full) {
            Ok(True) -> clean_generated_in_patches_dir(full, patches_root, cur)
            _ -> {
              let should_delete =
                string.ends_with(entry, ".g.mbt")
                || { entry == "moon.pkg" && fs.has_generated_marker(full) }
              case should_delete {
                True -> {
                  use _ <- result.try(
                    simplifile.delete_file(at: full)
                    |> result.map_error(fn(err) {
                      "Failed to remove '"
                      <> full
                      <> "': "
                      <> simplifile.describe_error(err)
                    }),
                  )
                  Ok([full, ..cur])
                }
                False -> Ok(cur)
              }
            }
          }
      }
    }),
  )
  case dir != patches_root {
    True ->
      case simplifile.read_directory(at: dir) {
        Ok([]) -> {
          let _ = simplifile.delete(file_or_dir_at: dir)
          Ok(next_acc)
        }
        _ -> Ok(next_acc)
      }
    False -> Ok(next_acc)
  }
}

fn run_clean(root: String) -> Nil {
  case clean_project(root) {
    Error(err) -> {
      io.println_error("gekko clean error: " <> err)
      halt(1)
    }
    Ok([]) -> io.println("Nothing to clean under '" <> root <> "'.")
    Ok(removed) -> list.each(removed, fn(p) { io.println("Removed " <> p) })
  }
}

fn run_doctor_cmd() -> Nil {
  let statuses = cmd.run_doctor()
  list.each(statuses, fn(st) {
    let icon = case st.ok, st.warning {
      False, _ -> "FAIL"
      True, True -> "WARN"
      True, False -> "OK  "
    }
    let req_tag = case st.required {
      True -> "required"
      False -> "optional"
    }
    let ver_str = option.unwrap(st.version, "not found")
    let note_str = case st.note {
      "" -> ""
      n -> " (" <> n <> ")"
    }
    io.println(
      "["
      <> icon
      <> "] "
      <> st.name
      <> " ["
      <> req_tag
      <> "]: "
      <> ver_str
      <> note_str,
    )
  })
  case list.all(statuses, fn(st) { st.ok }) {
    True -> Nil
    False -> halt(1)
  }
}

fn run_wit_gen(
  root: String,
  wit_dir_opt: Option(String),
  world: Option(String),
) -> Nil {
  let wit_dir = option.unwrap(wit_dir_opt, filepath.join(root, "wit"))
  let res = {
    use resolved <- result.try(wit_parser.load_wit_dir(wit_dir, world))
    gleam_gen.generate_project_bindings(resolved, root)
  }
  case res {
    Error(err) -> {
      io.println_error("gekko wit gen error: " <> err)
      halt(1)
    }
    Ok(report) -> {
      list.each(report.written_files, fn(p) { io.println("Generated " <> p) })
      list.each(report.skipped_existing_stubs, fn(p) {
        io.println("Kept existing stub " <> p)
      })
    }
  }
}

fn run_wit_check(
  root: String,
  wit_dir_opt: Option(String),
  world: Option(String),
  out: Option(String),
) -> Nil {
  let wit_dir = option.unwrap(wit_dir_opt, filepath.join(root, "wit"))
  let out_dir = option.unwrap(out, filepath.join(root, "build/moonbit"))
  let res = {
    use summary <- result.try(wit_bridge.bridge_wit_workspace(
      root,
      out_dir,
      wit_dir,
      world,
    ))
    list.each(summary.warnings, io.println_error)
    wit_bridge.check_wit_workspace(summary)
    |> result.map_error(fn(err) {
      diagnostics.annotate_moon_output(summary.out_dir, err)
    })
  }
  case res {
    Error(err) -> {
      io.println_error("gekko wit check error: " <> err)
      halt(1)
    }
    Ok(output) ->
      case output {
        "" -> Nil
        text -> io.print(text)
      }
  }
}

fn run_wit_build(
  root: String,
  wit_dir_opt: Option(String),
  world: Option(String),
  out: Option(String),
  output_opt: Option(String),
  release: Bool,
) -> Nil {
  let wit_dir = option.unwrap(wit_dir_opt, filepath.join(root, "wit"))
  let out_dir = option.unwrap(out, filepath.join(root, "build/moonbit"))
  let res = {
    use summary <- result.try(wit_bridge.bridge_wit_workspace(
      root,
      out_dir,
      wit_dir,
      world,
    ))
    list.each(summary.warnings, io.println_error)
    let output_wasm =
      option.unwrap(
        output_opt,
        filepath.join(root, "dist/" <> summary.world_name <> ".wasm"),
      )
    wit_bridge.bundle_component_with_profile(
      summary,
      world,
      output_wasm,
      release,
    )
    |> result.map_error(fn(err) {
      diagnostics.annotate_moon_output(summary.out_dir, err)
    })
  }
  case res {
    Error(err) -> {
      io.println_error("gekko wit build error: " <> err)
      halt(1)
    }
    Ok(out_wasm) -> io.println("Built Wasm component: " <> out_wasm)
  }
}

fn run_moonbit_bind(
  root: String,
  package: String,
  module: Option(String),
  out: Option(String),
  options: BindOptions,
) -> Nil {
  let out_dir = option.unwrap(out, filepath.join(root, "build/moonbit"))
  case
    bindgen.bind_package_with_options(root, package, module, out_dir, options)
  {
    Error(err) -> {
      io.println_error("gekko moonbit bind error: " <> err)
      halt(1)
    }
    Ok(res) -> {
      let _ = workspace.sync_moonbit_lsp_workspace(root)
      io.println(
        "Generated Gleam module: src/" <> res.gleam_module_path <> ".gleam",
      )
      case res.adapter_pkg_dir {
        Some(dir) -> io.println("Generated MoonBit adapter: moonbit/" <> dir)
        None -> Nil
      }
      list.each(res.skipped_items, fn(s) {
        io.println_error("Warning (skipped " <> s.0 <> "): " <> s.1)
      })
    }
  }
}

fn shim_style_from_flag(moonbit: Bool) -> shim_cli.ShimStyle {
  case moonbit {
    True -> shim_cli.MoonBitShim
    False -> shim_cli.GleamShim
  }
}

fn run_shim_new(
  root: String,
  package: String,
  out: Option(String),
  moonbit: Bool,
) -> Nil {
  case
    shim_cli.new_shim_with_style(
      root,
      package,
      out,
      shim_style_from_flag(moonbit),
    )
  {
    Error(err) -> {
      io.println_error("gekko shim new error: " <> err)
      halt(1)
    }
    Ok(msg) -> io.println(msg)
  }
}

fn run_shim_init(root: String, moonbit: Bool) -> Nil {
  case shim_cli.init_in_place_with_style(root, shim_style_from_flag(moonbit)) {
    Error(err) -> {
      io.println_error("gekko shim init error: " <> err)
      halt(1)
    }
    Ok(msg) -> io.println(msg)
  }
}

fn run_shim_inspect(root: String, package: Option(String)) -> Nil {
  case shim_cli.inspect_package(root, package) {
    Error(err) -> {
      io.println_error("gekko shim inspect error: " <> err)
      halt(1)
    }
    Ok(report) -> io.println(report)
  }
}

fn run_shim_patch_decl(root: String, target: String, moonbit: Bool) -> Nil {
  case
    shim_cli.patch_decl_with_style(root, target, shim_style_from_flag(moonbit))
  {
    Error(err) -> {
      io.println_error("gekko shim patch error: " <> err)
      halt(1)
    }
    Ok(msg) -> io.println(msg)
  }
}

fn run_shim_patch_module(root: String, module: String, moonbit: Bool) -> Nil {
  case
    shim_cli.patch_module_with_style(
      root,
      module,
      shim_style_from_flag(moonbit),
    )
  {
    Error(err) -> {
      io.println_error("gekko shim patch error: " <> err)
      halt(1)
    }
    Ok(msg) -> io.println(msg)
  }
}

fn run_shim_sync(root: String) -> Nil {
  case shim_cli.sync_shims(root) {
    Error(err) -> {
      io.println_error("gekko shim sync error: " <> err)
      halt(1)
    }
    Ok(msg) -> io.println(msg)
  }
}

fn run_shim_migrate(root: String) -> Nil {
  case shim_cli.migrate_shims(root) {
    Error(err) -> {
      io.println_error("gekko shim migrate error: " <> err)
      halt(1)
    }
    Ok(msg) -> io.println(msg)
  }
}

fn run_shim_ack(root: String) -> Nil {
  case shim_cli.ack_shims(root) {
    Error(err) -> {
      io.println_error("gekko shim ack error: " <> err)
      halt(1)
    }
    Ok(msg) -> io.println(msg)
  }
}

pub fn parse_args(args: List(String)) -> Result(CliAction, String) {
  let #(pre_dash, program_args) = split_on_double_dash(args)
  let args = expand_eq_flags(pre_dash)
  case list.any(args, fn(a) { a == "--help" || a == "-h" }) {
    True -> Ok(HelpAction)
    False ->
      case args {
        [] | ["help", ..] -> Ok(HelpAction)
        ["--version"] | ["-V"] | ["version"] -> Ok(VersionAction)
        ["doctor"] -> Ok(DoctorAction)
        ["new", ..rest] -> parse_new_args(rest, None, False)
        ["init", ..rest] -> parse_init_args(rest, ".", False)
        ["clean", ..rest] -> parse_clean_args(rest, ".")
        ["check", ..rest] -> {
          let strict = list.contains(rest, "--strict")
          let rest = list.filter(rest, fn(a) { a != "--strict" })
          use #(root, out, target) <- result.try(parse_flags(
            rest,
            ".",
            None,
            None,
          ))
          Ok(CheckAction(root:, out:, target:, strict:))
        }
        ["build", ..rest] -> {
          let release = list.contains(rest, "--release")
          let strict = list.contains(rest, "--strict")
          let rest =
            list.filter(rest, fn(a) { a != "--release" && a != "--strict" })
          use #(root, out, work_dir, target) <- result.try(parse_build_flags(
            rest,
            ".",
            None,
            None,
            None,
          ))
          Ok(BuildAction(
            root:,
            out:,
            work_dir:,
            target: option.unwrap(target, "wasm"),
            release:,
            strict:,
          ))
        }
        ["test", ..rest] -> {
          let strict = list.contains(rest, "--strict")
          let rest = list.filter(rest, fn(a) { a != "--strict" })
          use #(root, out, target) <- result.try(parse_flags(
            rest,
            ".",
            None,
            None,
          ))
          Ok(TestAction(root:, out:, target:, strict:))
        }
        ["run", ..rest] -> {
          use #(root, out, target) <- result.try(parse_flags(
            rest,
            ".",
            None,
            None,
          ))
          Ok(RunAction(root:, out:, target:, program_args:))
        }
        ["wit", "gen", ..rest] -> {
          use f <- result.try(parse_wit_flags(rest, default_wit_flags()))
          Ok(WitGenAction(root: f.root, wit_dir: f.wit_dir, world: f.world))
        }
        ["wit", "check", ..rest] -> {
          use f <- result.try(parse_wit_flags(rest, default_wit_flags()))
          Ok(WitCheckAction(
            root: f.root,
            wit_dir: f.wit_dir,
            world: f.world,
            out: f.out,
          ))
        }
        ["wit", "build", ..rest] -> {
          let release = list.contains(rest, "--release")
          let rest = list.filter(rest, fn(a) { a != "--release" })
          use f <- result.try(parse_wit_flags(rest, default_wit_flags()))
          Ok(WitBuildAction(
            root: f.root,
            wit_dir: f.wit_dir,
            world: f.world,
            out: f.out,
            output: f.output,
            release:,
          ))
        }
        ["wit", ..] -> Error("Expected `gekko wit <gen|check|build> [flags]`")
        ["moonbit", "bind", ..rest] -> {
          use f <- result.try(parse_bind_flags(
            rest,
            BindFlags(
              root: ".",
              package: None,
              module: None,
              out: None,
              only: [],
              map_types: dict.new(),
              typed_errors: False,
              adapter: None,
            ),
          ))
          case f.package {
            Some(pkg) ->
              Ok(MoonbitBindAction(
                root: f.root,
                package: pkg,
                module: f.module,
                out: f.out,
                only: list.reverse(f.only),
                map_types: f.map_types,
                typed_errors: f.typed_errors,
                adapter: f.adapter,
              ))
            None -> Error("Expected `<pkg>` after `gekko moonbit bind`")
          }
        }
        ["moonbit", ..] -> Error("Expected `gekko moonbit bind <pkg> [flags]`")
        ["shim", "new", ..rest] -> {
          use #(root, pkg_opt, out, moonbit) <- result.try(parse_shim_new_flags(
            rest,
            ".",
            None,
            None,
            False,
          ))
          case pkg_opt {
            Some(pkg) -> Ok(ShimNewAction(root:, package: pkg, out:, moonbit:))
            None -> Error("Expected `<pkg>` after `gekko shim new`")
          }
        }
        ["shim", "init", ..rest] -> {
          use #(root, moonbit) <- result.try(parse_shim_init_flags(
            rest,
            ".",
            False,
          ))
          Ok(ShimInitAction(root:, moonbit:))
        }
        ["shim", "inspect", ..rest] -> {
          use #(root, pkg_opt) <- result.try(parse_shim_inspect_flags(
            rest,
            ".",
            None,
          ))
          Ok(ShimInspectAction(root:, package: pkg_opt))
        }
        ["shim", "patch", ..rest] ->
          parse_shim_patch_flags(rest, ".", None, None, False)
        ["shim", "sync", ..rest] -> {
          use root <- result.try(parse_shim_root_only_flags(rest, ".", "sync"))
          Ok(ShimSyncAction(root:))
        }
        ["shim", "migrate", ..rest] -> {
          use root <- result.try(parse_shim_root_only_flags(
            rest,
            ".",
            "migrate",
          ))
          Ok(ShimMigrateAction(root:))
        }
        ["shim", "ack", ..rest] -> {
          use root <- result.try(parse_shim_root_only_flags(rest, ".", "ack"))
          Ok(ShimAckAction(root:))
        }
        ["shim", ..] ->
          Error(
            "Expected `gekko shim <new|init|inspect|patch|sync|migrate|ack> [flags]`",
          )
        [unknown, ..] -> Error("Unknown subcommand: " <> unknown)
      }
  }
}

fn split_on_double_dash(args: List(String)) -> #(List(String), List(String)) {
  split_dash_loop(args, [])
}

fn split_dash_loop(
  args: List(String),
  rev_before: List(String),
) -> #(List(String), List(String)) {
  case args {
    [] -> #(list.reverse(rev_before), [])
    ["--", ..after] -> #(list.reverse(rev_before), after)
    [head, ..tail] -> split_dash_loop(tail, [head, ..rev_before])
  }
}

fn parse_new_args(
  args: List(String),
  name: Option(String),
  with_wit: Bool,
) -> Result(CliAction, String) {
  case args {
    [] ->
      case name {
        Some(n) -> Ok(NewAction(name: n, with_wit:))
        None -> Error("Expected `<name>` after `gekko new`")
      }
    ["--wit", ..rest] -> parse_new_args(rest, name, True)
    [arg, ..rest] ->
      case string.starts_with(arg, "-") {
        True -> Error("Unknown flag for `gekko new`: " <> arg)
        False ->
          case name {
            None -> parse_new_args(rest, Some(arg), with_wit)
            Some(_) -> Error("Unexpected argument for `gekko new`: " <> arg)
          }
      }
  }
}

fn parse_init_args(
  args: List(String),
  root: String,
  with_wit: Bool,
) -> Result(CliAction, String) {
  case args {
    [] -> Ok(InitAction(root:, with_wit:))
    ["--wit", ..rest] -> parse_init_args(rest, root, True)
    ["--root", val, ..rest] -> parse_init_args(rest, val, with_wit)
    [flag, ..] -> Error("Unknown or incomplete flag: " <> flag)
  }
}

fn parse_clean_args(
  args: List(String),
  root: String,
) -> Result(CliAction, String) {
  case args {
    [] -> Ok(CleanAction(root:))
    ["--root", val, ..rest] -> parse_clean_args(rest, val)
    [flag, ..] -> Error("Unknown or incomplete flag: " <> flag)
  }
}

fn parse_bind_flags(
  args: List(String),
  acc: BindFlags,
) -> Result(BindFlags, String) {
  case args {
    [] -> Ok(acc)
    ["--root", val, ..rest] ->
      parse_bind_flags(rest, BindFlags(..acc, root: val))
    ["--module", val, ..rest] ->
      parse_bind_flags(rest, BindFlags(..acc, module: Some(val)))
    ["--out", val, ..rest] | ["--work-dir", val, ..rest] ->
      parse_bind_flags(rest, BindFlags(..acc, out: Some(val)))
    ["--adapter", val, ..rest] ->
      parse_bind_flags(rest, BindFlags(..acc, adapter: Some(val)))
    ["--only", val, ..rest] ->
      parse_bind_flags(rest, BindFlags(..acc, only: [val, ..acc.only]))
    ["--map-type", val, ..rest] -> {
      use #(mbt_ty, target) <- result.try(bindgen.parse_map_type_arg(val))
      parse_bind_flags(
        rest,
        BindFlags(..acc, map_types: dict.insert(acc.map_types, mbt_ty, target)),
      )
    }
    ["--typed-errors", ..rest] ->
      parse_bind_flags(rest, BindFlags(..acc, typed_errors: True))
    [flag, ..] ->
      case string.starts_with(flag, "-") {
        True -> Error("Unknown or incomplete flag: " <> flag)
        False ->
          case args {
            [val, ..rest] ->
              case acc.package {
                None ->
                  parse_bind_flags(rest, BindFlags(..acc, package: Some(val)))
                Some(_) -> Error("Unknown or unexpected argument: " <> val)
              }
            [] -> Ok(acc)
          }
      }
  }
}

fn default_wit_flags() -> WitFlags {
  WitFlags(root: ".", wit_dir: None, world: None, out: None, output: None)
}

fn parse_wit_flags(
  args: List(String),
  acc: WitFlags,
) -> Result(WitFlags, String) {
  case args {
    [] -> Ok(acc)
    ["--root", val, ..rest] -> parse_wit_flags(rest, WitFlags(..acc, root: val))
    ["--wit", val, ..rest] ->
      parse_wit_flags(rest, WitFlags(..acc, wit_dir: Some(val)))
    ["--world", val, ..rest] ->
      parse_wit_flags(rest, WitFlags(..acc, world: Some(val)))
    ["--out", val, ..rest] | ["--work-dir", val, ..rest] ->
      parse_wit_flags(rest, WitFlags(..acc, out: Some(val)))
    ["--output", val, ..rest] | ["-o", val, ..rest] ->
      parse_wit_flags(rest, WitFlags(..acc, output: Some(val)))
    [flag, ..] -> Error("Unknown or incomplete flag: " <> flag)
  }
}

fn expand_eq_flags(args: List(String)) -> List(String) {
  list.flat_map(args, fn(arg) {
    case string.split_once(arg, "=") {
      Ok(#(flag, val)) ->
        case flag {
          "--root"
          | "--out"
          | "--work-dir"
          | "-o"
          | "--output"
          | "--target"
          | "--wit"
          | "--world"
          | "--module" -> [flag, val]
          _ -> [arg]
        }
      Error(_) -> [arg]
    }
  })
}

fn parse_build_flags(
  args: List(String),
  root: String,
  out: Option(String),
  work_dir: Option(String),
  target: Option(String),
) -> Result(#(String, Option(String), Option(String), Option(String)), String) {
  case args {
    [] -> Ok(#(root, out, work_dir, target))
    ["--root", val, ..rest] ->
      parse_build_flags(rest, val, out, work_dir, target)
    ["--out", val, ..rest] | ["--output", val, ..rest] | ["-o", val, ..rest] ->
      parse_build_flags(rest, root, Some(val), work_dir, target)
    ["--work-dir", val, ..rest] ->
      parse_build_flags(rest, root, out, Some(val), target)
    ["--target", val, ..rest] ->
      case val {
        "wasm" | "wasm-gc" | "js" | "native" ->
          parse_build_flags(rest, root, out, work_dir, Some(val))
        _ ->
          Error(
            "Invalid --target '"
            <> val
            <> "'. Expected wasm, wasm-gc, js, or native.",
          )
      }
    [flag, ..] -> Error("Unknown or incomplete flag: " <> flag)
  }
}

fn parse_flags(
  args: List(String),
  root: String,
  out: Option(String),
  target: Option(String),
) -> Result(#(String, Option(String), Option(String)), String) {
  case args {
    [] -> Ok(#(root, out, target))
    ["--root", val, ..rest] -> parse_flags(rest, val, out, target)
    ["--out", val, ..rest] | ["--work-dir", val, ..rest] ->
      parse_flags(rest, root, Some(val), target)
    ["--target", val, ..rest] ->
      case val {
        "wasm" | "wasm-gc" | "js" | "native" ->
          parse_flags(rest, root, out, Some(val))
        _ ->
          Error(
            "Invalid --target '"
            <> val
            <> "'. Expected wasm, wasm-gc, js, or native.",
          )
      }
    [flag, ..] -> Error("Unknown or incomplete flag: " <> flag)
  }
}

fn parse_shim_inspect_flags(
  args: List(String),
  root: String,
  pkg: Option(String),
) -> Result(#(String, Option(String)), String) {
  case args {
    [] -> Ok(#(root, pkg))
    ["--root", val, ..rest] -> parse_shim_inspect_flags(rest, val, pkg)
    [val, ..rest] ->
      case string.starts_with(val, "-"), pkg {
        True, _ -> Error("Unknown or incomplete flag: " <> val)
        False, None -> parse_shim_inspect_flags(rest, root, Some(val))
        False, Some(_) -> Error("Unexpected argument: " <> val)
      }
  }
}

fn parse_shim_new_flags(
  args: List(String),
  root: String,
  pkg: Option(String),
  out: Option(String),
  moonbit: Bool,
) -> Result(#(String, Option(String), Option(String), Bool), String) {
  case args {
    [] -> Ok(#(root, pkg, out, moonbit))
    ["--root", val, ..rest] ->
      parse_shim_new_flags(rest, val, pkg, out, moonbit)
    ["--out", val, ..rest] | ["--output", val, ..rest] | ["-o", val, ..rest] ->
      parse_shim_new_flags(rest, root, pkg, Some(val), moonbit)
    ["--moonbit", ..rest] -> parse_shim_new_flags(rest, root, pkg, out, True)
    [val, ..rest] ->
      case string.starts_with(val, "-"), pkg {
        True, _ -> Error("Unknown or incomplete flag: " <> val)
        False, None -> parse_shim_new_flags(rest, root, Some(val), out, moonbit)
        False, Some(_) -> Error("Unexpected argument: " <> val)
      }
  }
}

fn parse_shim_init_flags(
  args: List(String),
  root: String,
  moonbit: Bool,
) -> Result(#(String, Bool), String) {
  case args {
    [] -> Ok(#(root, moonbit))
    ["--root", val, ..rest] -> parse_shim_init_flags(rest, val, moonbit)
    ["--moonbit", ..rest] -> parse_shim_init_flags(rest, root, True)
    [val, ..] ->
      case string.starts_with(val, "-") {
        True -> Error("Unknown or incomplete flag: " <> val)
        False ->
          Error("Unexpected argument '" <> val <> "' for `gekko shim init`")
      }
  }
}

fn parse_shim_root_only_flags(
  args: List(String),
  root: String,
  subcmd: String,
) -> Result(String, String) {
  case args {
    [] -> Ok(root)
    ["--root", val, ..rest] -> parse_shim_root_only_flags(rest, val, subcmd)
    [val, ..] ->
      case string.starts_with(val, "-") {
        True -> Error("Unknown or incomplete flag: " <> val)
        False ->
          Error(
            "Unexpected argument '"
            <> val
            <> "' for `gekko shim "
            <> subcmd
            <> "`",
          )
      }
  }
}

fn parse_shim_patch_flags(
  args: List(String),
  root: String,
  target: Option(String),
  module: Option(String),
  moonbit: Bool,
) -> Result(CliAction, String) {
  case args {
    [] ->
      case target, module {
        Some(t), None -> Ok(ShimPatchDeclAction(root:, target: t, moonbit:))
        None, Some(m) -> Ok(ShimPatchModuleAction(root:, module: m, moonbit:))
        Some(_), Some(_) ->
          Error(
            "Specify either `<module>.<decl>` or `--module <module>`, not both",
          )
        None, None ->
          Error(
            "Expected `<module>.<decl>` or `--module <module>` after `gekko shim patch`",
          )
      }
    ["--root", val, ..rest] ->
      parse_shim_patch_flags(rest, val, target, module, moonbit)
    ["--module", val, ..rest] ->
      parse_shim_patch_flags(rest, root, target, Some(val), moonbit)
    ["--moonbit", ..rest] ->
      parse_shim_patch_flags(rest, root, target, module, True)
    [val, ..rest] ->
      case string.starts_with(val, "-"), target {
        True, _ -> Error("Unknown or incomplete flag: " <> val)
        False, None ->
          parse_shim_patch_flags(rest, root, Some(val), module, moonbit)
        False, Some(_) -> Error("Unexpected argument: " <> val)
      }
  }
}

fn print_usage() -> Nil {
  let lines = [
    "gekko " <> version <> " - Gleam-to-MoonBit & Wasm Component transpiler",
    "",
    "Usage:",
    "  gekko new <name> [--wit]",
    "  gekko init      [--root <dir>] [--wit]",
    "  gekko clean     [--root <dir>]",
    "  gekko doctor",
    "  gekko check     [--strict] [--target <wasm|wasm-gc|js|native>] [--root <dir>] [--work-dir <dir>]",
    "  gekko build     [--strict] [--release] [--target <wasm|wasm-gc|js|native>] [--root <dir>] [--output <file> | -o <file>] [--work-dir <dir>]",
    "  gekko test      [--strict] [--target <wasm|wasm-gc|js|native>] [--root <dir>] [--work-dir <dir>]",
    "  gekko run       [--target <wasm|wasm-gc|js|native>] [--root <dir>] [--work-dir <dir>] [-- <args>...]",
    "  gekko wit gen      [--root <dir>] [--wit <dir>] [--world <name>]",
    "  gekko wit check    [--root <dir>] [--wit <dir>] [--world <name>] [--work-dir <dir>]",
    "  gekko wit build    [--release] [--root <dir>] [--wit <dir>] [--world <name>] [--work-dir <dir>] [--output <file.wasm> | -o <file.wasm>]",
    "  gekko moonbit bind <pkg> [--root <dir>] [--module <gleam_mod>] [--adapter <pkg>] [--only <item> ...] [--map-type <Mbt=Gleam> ...] [--typed-errors] [--work-dir <dir>]",
    "  gekko shim new     <pkg> [--root <dir>] [--out <dir> | -o <dir>] [--moonbit]",
    "  gekko shim init    [--root <dir>] [--moonbit]",
    "  gekko shim inspect [<pkg>] [--root <dir>]",
    "  gekko shim patch   <module>.<decl> [--root <dir>] [--moonbit]",
    "  gekko shim patch   --module <module> [--root <dir>] [--moonbit]",
    "  gekko shim sync    [--root <dir>]",
    "  gekko shim migrate [--root <dir>]",
    "  gekko shim ack     [--root <dir>]",
    "  gekko --version | -V",
    "  gekko --help    | -h",
    "",
    "Notes:",
    "  --root defaults to the current working directory (.) for all commands.",
    "  --out is accepted as a backwards-compatible alias for --work-dir (and -o on build).",
    "  gekko build writes the compiled artifact into the current directory by",
    "  default (or to --output / -o), keeping intermediate files in <root>/build/moonbit.",
    "  gekko shim generates Gleam /// @patch stubs by default; pass --moonbit for patches/*.mbt.",
  ]
  list.each(lines, io.println)
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
