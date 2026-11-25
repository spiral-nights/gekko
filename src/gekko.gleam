import argv
import emit/pkg_config
import emit/wit_bridge
import filepath
import gleam/dict
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import moonbit/bindgen
import project/cmd
import project/diagnostics
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
  CheckAction(root: String, out: Option(String), target: Option(String))
  BuildAction(
    root: String,
    out: Option(String),
    work_dir: Option(String),
    target: String,
    release: Bool,
  )
  TestAction(root: String, out: Option(String), target: Option(String))
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
  )
  ShimInspectAction(root: String, package: String)
  ShimInitAction(root: String, package: String, out: Option(String))
  HelpAction
  VersionAction
}

type BindFlags {
  BindFlags(
    root: String,
    package: Option(String),
    module: Option(String),
    out: Option(String),
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
    Ok(CheckAction(root:, out:, target:)) -> {
      require_tools_or_halt(["gleam", "moon"])
      run_moon_workflow(root, out, "check", False, target, True, [])
    }
    Ok(BuildAction(root:, out:, work_dir:, target:, release:)) -> {
      require_tools_or_halt(["gleam", "moon"])
      run_build(root, out, work_dir, target, release)
    }
    Ok(TestAction(root:, out:, target:)) -> {
      require_tools_or_halt(["gleam", "moon"])
      run_moon_workflow(root, out, "test", False, target, True, [])
    }
    Ok(RunAction(root:, out:, target:, program_args:)) -> {
      require_tools_or_halt(["gleam", "moon"])
      run_moon_workflow(root, out, "run", True, target, False, program_args)
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
    Ok(MoonbitBindAction(root:, package:, module:, out:)) -> {
      require_tools_or_halt(["moon"])
      run_moonbit_bind(root, package, module, out)
    }
    Ok(ShimInspectAction(root:, package:)) -> {
      require_tools_or_halt(["gleam"])
      run_shim_inspect(root, package)
    }
    Ok(ShimInitAction(root:, package:, out:)) -> {
      require_tools_or_halt(["gleam"])
      run_shim_init(root, package, out)
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

fn run_build(
  root: String,
  out: Option(String),
  work_dir: Option(String),
  target: String,
  release: Bool,
) -> Nil {
  case build_project_with_options(root, out, work_dir, target, ".", release) {
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
  let work_dir =
    option.unwrap(work_dir_opt, filepath.join(root, "build/moonbit"))
  use summary <- result.try(workspace.transpile_project_with_tests(
    root,
    work_dir,
    False,
  ))

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

/// Remove generated `gekko` staging and MoonBit workspace directories under `root`.
pub fn clean_project(root: String) -> Result(List(String), String) {
  let targets = [
    filepath.join(root, "build/moonbit"),
    filepath.join(root, "build/.gekko_staging"),
    filepath.join(root, "build/.gekko_staging_deps"),
    filepath.join(root, "build/.gekko_gprelude"),
  ]
  use removed_dirs <- result.try(
    list.try_fold(targets, [], fn(acc, path) {
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
  let moon_work_path = filepath.join(root, "moon.work")
  use removed_all <- result.try(case simplifile.read(moon_work_path) {
    Ok(content) ->
      case string.starts_with(content, "// Generated by gekko") {
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
          Ok([moon_work_path, ..removed_dirs])
        }
        False -> Ok(removed_dirs)
      }
    _ -> Ok(removed_dirs)
  })
  Ok(list.reverse(removed_all))
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
) -> Nil {
  let out_dir = option.unwrap(out, filepath.join(root, "build/moonbit"))
  case bindgen.bind_package(root, package, module, out_dir) {
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

fn run_shim_inspect(root: String, package: String) -> Nil {
  case shim_cli.inspect_package(root, package) {
    Error(err) -> {
      io.println_error("gekko shim inspect error: " <> err)
      halt(1)
    }
    Ok(report) -> io.println(report)
  }
}

fn run_shim_init(root: String, package: String, out: Option(String)) -> Nil {
  case shim_cli.init_shim(root, package, out) {
    Error(err) -> {
      io.println_error("gekko shim init error: " <> err)
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
          use #(root, out, target) <- result.try(parse_flags(
            rest,
            ".",
            None,
            None,
          ))
          Ok(CheckAction(root:, out:, target:))
        }
        ["build", ..rest] -> {
          let release = list.contains(rest, "--release")
          let rest = list.filter(rest, fn(a) { a != "--release" })
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
          ))
        }
        ["test", ..rest] -> {
          use #(root, out, target) <- result.try(parse_flags(
            rest,
            ".",
            None,
            None,
          ))
          Ok(TestAction(root:, out:, target:))
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
            BindFlags(root: ".", package: None, module: None, out: None),
          ))
          case f.package {
            Some(pkg) ->
              Ok(MoonbitBindAction(
                root: f.root,
                package: pkg,
                module: f.module,
                out: f.out,
              ))
            None -> Error("Expected `<pkg>` after `gekko moonbit bind`")
          }
        }
        ["moonbit", ..] -> Error("Expected `gekko moonbit bind <pkg> [flags]`")
        ["shim", "inspect", ..rest] -> {
          use #(root, pkg_opt) <- result.try(parse_shim_inspect_flags(
            rest,
            ".",
            None,
          ))
          case pkg_opt {
            Some(pkg) -> Ok(ShimInspectAction(root:, package: pkg))
            None -> Error("Expected `<pkg>` after `gekko shim inspect`")
          }
        }
        ["shim", "init", ..rest] -> {
          use #(root, pkg_opt, out) <- result.try(parse_shim_init_flags(
            rest,
            ".",
            None,
            None,
          ))
          case pkg_opt {
            Some(pkg) -> Ok(ShimInitAction(root:, package: pkg, out:))
            None -> Error("Expected `<pkg>` after `gekko shim init`")
          }
        }
        ["shim", ..] ->
          Error("Expected `gekko shim <inspect|init> <pkg> [flags]`")
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
    [val, ..rest] ->
      case acc.package {
        None -> parse_bind_flags(rest, BindFlags(..acc, package: Some(val)))
        Some(_) -> Error("Unknown or unexpected argument: " <> val)
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

fn parse_shim_init_flags(
  args: List(String),
  root: String,
  pkg: Option(String),
  out: Option(String),
) -> Result(#(String, Option(String), Option(String)), String) {
  case args {
    [] -> Ok(#(root, pkg, out))
    ["--root", val, ..rest] -> parse_shim_init_flags(rest, val, pkg, out)
    ["--out", val, ..rest] | ["--output", val, ..rest] | ["-o", val, ..rest] ->
      parse_shim_init_flags(rest, root, pkg, Some(val))
    [val, ..rest] ->
      case string.starts_with(val, "-"), pkg {
        True, _ -> Error("Unknown or incomplete flag: " <> val)
        False, None -> parse_shim_init_flags(rest, root, Some(val), out)
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
    "  gekko check     [--target <wasm|wasm-gc|js|native>] [--root <dir>] [--work-dir <dir>]",
    "  gekko build     [--release] [--target <wasm|wasm-gc|js|native>] [--root <dir>] [--output <file> | -o <file>] [--work-dir <dir>]",
    "  gekko test      [--target <wasm|wasm-gc|js|native>] [--root <dir>] [--work-dir <dir>]",
    "  gekko run       [--target <wasm|wasm-gc|js|native>] [--root <dir>] [--work-dir <dir>] [-- <args>...]",
    "  gekko wit gen      [--root <dir>] [--wit <dir>] [--world <name>]",
    "  gekko wit check    [--root <dir>] [--wit <dir>] [--world <name>] [--work-dir <dir>]",
    "  gekko wit build    [--release] [--root <dir>] [--wit <dir>] [--world <name>] [--work-dir <dir>] [--output <file.wasm> | -o <file.wasm>]",
    "  gekko moonbit bind <pkg> [--root <dir>] [--module <gleam_mod>] [--work-dir <dir>]",
    "  gekko shim inspect <pkg> [--root <dir>]",
    "  gekko shim init    <pkg> [--root <dir>] [--out <dir> | -o <dir>]",
    "  gekko --version | -V",
    "  gekko --help    | -h",
    "",
    "Notes:",
    "  --root defaults to the current working directory (.) for all commands.",
    "  --out is accepted as a backwards-compatible alias for --work-dir (and -o on build).",
    "  gekko build writes the compiled artifact into the current directory by",
    "  default (or to --output / -o), keeping intermediate files in <root>/build/moonbit.",
  ]
  list.each(lines, io.println)
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
