import filepath
import gleam/result
import simplifile

/// Normalize `path` to an absolute, expanded path, falling back to the input
/// when the filesystem cannot resolve it (for example a virtual path).
pub fn absolute(path: String) -> String {
  simplifile.resolve(path)
  |> result.unwrap(filepath.expand(path) |> result.unwrap(path))
}

/// Join `rel_or_abs` onto `base_dir` and normalize the result. Absolute
/// inputs are kept as-is.
pub fn resolve_against(base_dir: String, rel_or_abs: String) -> String {
  case filepath.is_absolute(rel_or_abs) {
    True -> absolute(rel_or_abs)
    False -> absolute(filepath.join(base_dir, rel_or_abs))
  }
}
