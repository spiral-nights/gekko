import common/fs
import emit/pkg_config
import filepath
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile

/// Discover, validate, and copy local MoonBit FFI packages from
/// `<project_root>/moonbit/` into `<out_dir>/`.
///
/// Each subdirectory containing at least one `.mbt` file or a `moon.pkg` file
/// is treated as a local MoonBit package. When `moon.pkg` is omitted, a default
/// manifest importing `<project_name>/gprelude` is generated automatically.
pub fn copy_local_packages(
  project_root: String,
  project_name: String,
  out_dir: String,
  reserved_pkg_dirs: Set(String),
) -> Result(List(String), String) {
  copy_local_packages_for_package(
    project_root,
    project_name,
    project_name,
    out_dir,
    reserved_pkg_dirs,
  )
}

/// Copy local MoonBit FFI packages from `<pkg_root>/moonbit/` into `<out_dir>/`,
/// rewriting `"<source_pkg_name>/..."` module imports in copied `moon.pkg`
/// manifests to `"<project_name>/..."` when `source_pkg_name != project_name`.
pub fn copy_local_packages_for_package(
  pkg_root: String,
  source_pkg_name: String,
  project_name: String,
  out_dir: String,
  reserved_pkg_dirs: Set(String),
) -> Result(List(String), String) {
  copy_local_packages_for_package_excluding(
    pkg_root,
    source_pkg_name,
    project_name,
    out_dir,
    reserved_pkg_dirs,
    set.new(),
  )
}

/// Like `copy_local_packages_for_package`, skipping any file whose resolved
/// canonical path is present in `excluded_files` (such as files injected into
/// transpiled modules via `[module_inject]`).
pub fn copy_local_packages_for_package_excluding(
  pkg_root: String,
  source_pkg_name: String,
  project_name: String,
  out_dir: String,
  reserved_pkg_dirs: Set(String),
  excluded_files: Set(String),
) -> Result(List(String), String) {
  let moonbit_root = filepath.join(pkg_root, "moonbit")
  case simplifile.is_directory(moonbit_root) {
    Ok(True) -> {
      use entries <- result.try(read_sorted_dir(moonbit_root))
      use _ <- result.try(check_no_loose_root_files(moonbit_root, entries))
      use pkgs <- result.try(
        walk_root_subdirs(
          moonbit_root,
          entries,
          source_pkg_name,
          project_name,
          out_dir,
          reserved_pkg_dirs,
          excluded_files,
          [],
        ),
      )
      Ok(list.sort(pkgs, string.compare))
    }
    _ -> Ok([])
  }
}

fn read_sorted_dir(dir: String) -> Result(List(String), String) {
  simplifile.read_directory(at: dir)
  |> result.map(fn(entries) { list.sort(entries, string.compare) })
  |> result.map_error(fn(err) {
    "Failed to read directory " <> dir <> ": " <> simplifile.describe_error(err)
  })
}

fn check_no_loose_root_files(
  moonbit_root: String,
  entries: List(String),
) -> Result(Nil, String) {
  list.try_each(entries, fn(entry) {
    case fs.is_ignored_entry(entry) {
      True -> Ok(Nil)
      False -> {
        let full_path = filepath.join(moonbit_root, entry)
        case simplifile.is_directory(full_path) {
          Ok(True) -> Ok(Nil)
          _ ->
            case string.ends_with(entry, ".mbt") || entry == "moon.pkg" {
              True ->
                Error(
                  "Loose MoonBit file '"
                  <> entry
                  <> "' found directly in moonbit/. Place local MoonBit files inside a package subdirectory such as moonbit/<pkg>/"
                  <> entry,
                )
              False -> Ok(Nil)
            }
        }
      }
    }
  })
}

fn walk_root_subdirs(
  moonbit_root: String,
  entries: List(String),
  source_pkg_name: String,
  project_name: String,
  out_dir: String,
  reserved_pkg_dirs: Set(String),
  excluded_files: Set(String),
  acc: List(String),
) -> Result(List(String), String) {
  list.try_fold(entries, acc, fn(cur_acc, entry) {
    case fs.is_ignored_entry(entry) {
      True -> Ok(cur_acc)
      False -> {
        let full_path = filepath.join(moonbit_root, entry)
        case simplifile.is_directory(full_path) {
          Ok(True) ->
            visit_package_dir(
              full_path,
              entry,
              source_pkg_name,
              project_name,
              out_dir,
              reserved_pkg_dirs,
              excluded_files,
              cur_acc,
            )
          _ -> Ok(cur_acc)
        }
      }
    }
  })
}

fn visit_package_dir(
  cur_dir: String,
  rel_pkg: String,
  source_pkg_name: String,
  project_name: String,
  out_dir: String,
  reserved_pkg_dirs: Set(String),
  excluded_files: Set(String),
  acc: List(String),
) -> Result(List(String), String) {
  use entries <- result.try(read_sorted_dir(cur_dir))
  let #(rev_files, rev_subdirs) =
    list.fold(entries, #([], []), fn(parts, entry) {
      let #(files_acc, dirs_acc) = parts
      case fs.is_ignored_entry(entry) {
        True -> parts
        False -> {
          let full = filepath.join(cur_dir, entry)
          case simplifile.is_directory(full) {
            Ok(True) -> #(files_acc, [entry, ..dirs_acc])
            _ ->
              case simplifile.is_file(full) {
                Ok(True) -> {
                  let resolved = simplifile.resolve(full) |> result.unwrap(full)
                  case set.contains(excluded_files, resolved) {
                    True -> parts
                    False -> #([entry, ..files_acc], dirs_acc)
                  }
                }
                _ -> parts
              }
          }
        }
      }
    })
  let files = list.reverse(rev_files)
  let subdirs = list.reverse(rev_subdirs)

  let is_pkg =
    list.any(files, fn(f) { string.ends_with(f, ".mbt") || f == "moon.pkg" })

  use acc_after_pkg <- result.try(case is_pkg {
    False -> Ok(acc)
    True -> {
      use _ <- result.try(case set.contains(reserved_pkg_dirs, rel_pkg) {
        True ->
          Error(
            "Local MoonBit package 'moonbit/"
            <> rel_pkg
            <> "' collides with generated package directory '"
            <> rel_pkg
            <> "'",
          )
        False -> Ok(Nil)
      })
      let dest_dir = filepath.join(out_dir, rel_pkg)
      use _ <- result.try(
        simplifile.create_directory_all(dest_dir)
        |> result.map_error(fn(err) {
          "Failed to create local MoonBit package dir "
          <> dest_dir
          <> ": "
          <> simplifile.describe_error(err)
        }),
      )
      use _ <- result.try(
        list.try_each(files, fn(file) {
          let src_file = filepath.join(cur_dir, file)
          let dst_file = filepath.join(dest_dir, file)
          case file == "moon.pkg" {
            True ->
              rewrite_and_copy_moon_pkg(
                src_file,
                dst_file,
                source_pkg_name,
                project_name,
              )
            False -> copy_file(src_file, dst_file)
          }
        }),
      )
      use _ <- result.try(case list.contains(files, "moon.pkg") {
        True -> Ok(Nil)
        False -> {
          let generated_pkg =
            pkg_config.emit_moon_pkg(
              project_name,
              [#("gprelude", "gprelude")],
              False,
            )
          write_text_if_changed(
            filepath.join(dest_dir, "moon.pkg"),
            generated_pkg,
            "Failed to write generated moon.pkg for " <> rel_pkg,
          )
        }
      })
      Ok([rel_pkg, ..acc])
    }
  })

  list.try_fold(subdirs, acc_after_pkg, fn(cur_acc, sub) {
    visit_package_dir(
      filepath.join(cur_dir, sub),
      rel_pkg <> "/" <> sub,
      source_pkg_name,
      project_name,
      out_dir,
      reserved_pkg_dirs,
      excluded_files,
      cur_acc,
    )
  })
}

fn rewrite_and_copy_moon_pkg(
  src: String,
  dst: String,
  source_pkg_name: String,
  project_name: String,
) -> Result(Nil, String) {
  use content <- result.try(
    simplifile.read(from: src)
    |> result.map_error(fn(err) {
      "Failed to read local moon.pkg "
      <> src
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  let with_prelude =
    string.replace(
      content,
      "\"gekko/gprelude\"",
      "\"" <> project_name <> "/gprelude\"",
    )
  let updated = case source_pkg_name == project_name {
    True -> with_prelude
    False ->
      string.replace(
        with_prelude,
        "\"" <> source_pkg_name <> "/",
        "\"" <> project_name <> "/",
      )
  }
  write_text_if_changed(dst, updated, "Failed to write local moon.pkg " <> dst)
}

fn write_text_if_changed(
  dst: String,
  contents: String,
  err_prefix: String,
) -> Result(Nil, String) {
  case simplifile.read(from: dst) {
    Ok(existing) if existing == contents -> Ok(Nil)
    _ ->
      simplifile.write(to: dst, contents:)
      |> result.map_error(fn(err) {
        err_prefix <> ": " <> simplifile.describe_error(err)
      })
  }
}

fn copy_file(src: String, dst: String) -> Result(Nil, String) {
  use bytes <- result.try(
    simplifile.read_bits(from: src)
    |> result.map_error(fn(err) {
      "Failed to read local MoonBit file "
      <> src
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  case simplifile.read_bits(from: dst) {
    Ok(existing) if existing == bytes -> Ok(Nil)
    _ ->
      simplifile.write_bits(to: dst, bits: bytes)
      |> result.map_error(fn(err) {
        "Failed to write local MoonBit file "
        <> dst
        <> ": "
        <> simplifile.describe_error(err)
      })
  }
}
