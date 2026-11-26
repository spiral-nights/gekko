import filepath
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import project/fs
import project/paths
import simplifile
import wit/gleam_gen
import wit/parser as wit_parser

/// Create a new Gleam+gekko project directory `<name>` with starter files.
pub fn new_project(
  name: String,
  with_wit: Bool,
) -> Result(List(String), String) {
  use _ <- result.try(validate_project_name(name))
  use exists <- result.try(
    simplifile.is_directory(name)
    |> result.map_error(fn(err) {
      "Failed to check directory '"
      <> name
      <> "': "
      <> simplifile.describe_error(err)
    }),
  )
  use _ <- result.try(case exists {
    False -> Ok(Nil)
    True ->
      case simplifile.read_directory(at: name) {
        Ok([]) -> Ok(Nil)
        Ok(_) ->
          Error("Directory '" <> name <> "' already exists and is not empty")
        Error(err) ->
          Error(
            "Directory '"
            <> name
            <> "' already exists: "
            <> simplifile.describe_error(err),
          )
      }
  })
  use _ <- result.try(
    simplifile.create_directory_all(name)
    |> result.map_error(fn(err) {
      "Failed to create directory '"
      <> name
      <> "': "
      <> simplifile.describe_error(err)
    }),
  )
  scaffold_into_dir(name, name, with_wit)
}

/// Initialize `gekko` starter files inside an existing directory `root`
/// without overwriting an existing `gleam.toml`.
pub fn init_project(
  root: String,
  with_wit: Bool,
) -> Result(List(String), String) {
  let toml_path = filepath.join(root, "gleam.toml")
  case simplifile.is_file(toml_path) {
    Ok(True) -> Error("Refusing to overwrite existing " <> toml_path)
    _ -> {
      let abs = paths.absolute(root)
      let base = filepath.base_name(abs)
      let name = case validate_project_name(base) {
        Ok(n) -> n
        Error(_) -> "app"
      }
      scaffold_into_dir(root, name, with_wit)
    }
  }
}

fn scaffold_into_dir(
  root: String,
  name: String,
  with_wit: Bool,
) -> Result(List(String), String) {
  let gleam_toml =
    "name = \""
    <> name
    <> "\"\n"
    <> "version = \"0.1.0\"\n"
    <> "\n"
    <> "[dependencies]\n"
    <> "gleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n"
    <> "gekko_stdlib = { git = \"https://github.com/spiral-nights/gekko_stdlib.git\", ref = \"main\" }\n"
    <> "\n"
    <> "[dev-dependencies]\n"
    <> "gleeunit = \">= 1.0.0 and < 2.0.0\"\n"
    <> "\n"
    <> "[tools.gekko.use_shims]\n"
    <> "gleam_stdlib = \"gekko_stdlib\"\n"

  let gitignore =
    "build/\ndist/\n/_build/\n/moon.work\n/moonbit/gprelude/\n/patches/moon.mod\n/patches/gprelude/\n/patches/_build/\n/patches/.mooncakes/\npatches/**/moon.pkg\npatches/**/*.g.mbt\npkg.generated.mbti\n*.wasm\n*.exe\n"

  let main_src =
    "import gleam/io\n\n"
    <> "pub fn main() -> Nil {\n"
    <> "  io.println(\"Hello from "
    <> name
    <> "!\")\n"
    <> "}\n"

  let test_src =
    "import gleeunit\n\n"
    <> "pub fn main() -> Nil {\n"
    <> "  gleeunit.main()\n"
    <> "}\n\n"
    <> "pub fn hello_test() -> Nil {\n"
    <> "  assert 1 + 1 == 2\n"
    <> "}\n"

  let files = [
    #("gleam.toml", gleam_toml),
    #(".gitignore", gitignore),
    #("src/" <> name <> ".gleam", main_src),
    #("test/" <> name <> "_test.gleam", test_src),
  ]

  use rev_written <- result.try(
    list.try_fold(files, [], fn(acc, entry) {
      let #(rel, content) = entry
      let full = filepath.join(root, rel)
      use _ <- result.try(fs.write_text(full, content))
      Ok([rel, ..acc])
    }),
  )

  case with_wit {
    False -> Ok(list.reverse(rev_written))
    True -> {
      let wit_rel = "wit/world.wit"
      let wit_src =
        "package "
        <> string.replace(name, "_", "-")
        <> ":component@0.1.0;\n\n"
        <> "world app {\n"
        <> "  export greet: func(name: string) -> string;\n"
        <> "}\n"
      let wit_dir = filepath.join(root, "wit")
      use _ <- result.try(fs.write_text(filepath.join(root, wit_rel), wit_src))
      use resolved <- result.try(wit_parser.load_wit_dir(wit_dir, None))
      use report <- result.try(gleam_gen.generate_project_bindings(
        resolved,
        root,
      ))
      Ok(
        list.flatten([
          list.reverse(rev_written),
          [wit_rel],
          report.written_files,
        ]),
      )
    }
  }
}

fn validate_project_name(name: String) -> Result(String, String) {
  case name == "" || string.ends_with(name, "_test") {
    True ->
      Error(
        "Invalid project name '"
        <> name
        <> "': must be non-empty snake_case and must not end with '_test'",
      )
    False -> {
      let chars = string.to_graphemes(name)
      let valid = case chars {
        [first, ..rest] ->
          is_lower_alpha(first)
          && list.all(rest, fn(c) {
            is_lower_alpha(c) || is_digit(c) || c == "_"
          })
        [] -> False
      }
      case valid {
        True -> Ok(name)
        False ->
          Error(
            "Invalid project name '"
            <> name
            <> "': use lowercase letters, digits, and underscores (starting with a letter)",
          )
      }
    }
  }
}

fn is_lower_alpha(c: String) -> Bool {
  case string.to_utf_codepoints(c) {
    [cp] -> {
      let n = string.utf_codepoint_to_int(cp)
      n >= 97 && n <= 122
    }
    _ -> False
  }
}

fn is_digit(c: String) -> Bool {
  case string.to_utf_codepoints(c) {
    [cp] -> {
      let n = string.utf_codepoint_to_int(cp)
      n >= 48 && n <= 57
    }
    _ -> False
  }
}
