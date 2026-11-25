import gleam/string

/// Names that directory scans consistently skip: hidden entries, MoonBit's
/// `_build` output, and the legacy `target` directory.
pub fn is_ignored_entry(name: String) -> Bool {
  string.starts_with(name, ".") || name == "_build" || name == "target"
}
