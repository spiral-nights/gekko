import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

type SemVer {
  SemVer(major: Int, minor: Int, patch: Int, pre: Option(String))
}

pub opaque type VersionClause {
  VersionClause(
    op: String,
    major: Int,
    minor: Int,
    patch: Option(Int),
    pre: Option(String),
  )
}

/// Check whether `version` satisfies a Gleam/Hex SemVer `constraint`
/// (e.g. `">= 2.0.0 and < 3.0.0"`, `"~> 1.2"`, `"^3.0.0"`).
pub fn version_matches_constraint(
  version: String,
  constraint: String,
) -> Result(Bool, String) {
  use ver <- result.try(parse_semver(version))
  use clauses <- result.try(parse_version_constraint(constraint))
  Ok(list.all(clauses, fn(c) { eval_clause(ver, c) }))
}

/// Parse a Gleam/Hex SemVer constraint string into validated clauses.
pub fn parse_version_constraint(
  constraint: String,
) -> Result(List(VersionClause), String) {
  let normalized =
    constraint
    |> string.replace("&&", " and ")
    |> string.replace(",", " and ")
  let parts =
    string.split(normalized, " and ")
    |> list.map(string.trim)
    |> list.filter(fn(p) { p != "" })
  case parts {
    [] -> Error("Empty version constraint '" <> constraint <> "'")
    _ -> list.try_map(parts, parse_single_clause)
  }
}

fn parse_single_clause(clause: String) -> Result(VersionClause, String) {
  let trimmed = string.trim(clause)
  let #(op, rest) = case
    string.starts_with(trimmed, ">="),
    string.starts_with(trimmed, "<="),
    string.starts_with(trimmed, "=="),
    string.starts_with(trimmed, "!="),
    string.starts_with(trimmed, "~>"),
    string.starts_with(trimmed, ">"),
    string.starts_with(trimmed, "<"),
    string.starts_with(trimmed, "^"),
    string.starts_with(trimmed, "=")
  {
    True, _, _, _, _, _, _, _, _ -> #(">=", string.drop_start(trimmed, 2))
    _, True, _, _, _, _, _, _, _ -> #("<=", string.drop_start(trimmed, 2))
    _, _, True, _, _, _, _, _, _ -> #("==", string.drop_start(trimmed, 2))
    _, _, _, True, _, _, _, _, _ -> #("!=", string.drop_start(trimmed, 2))
    _, _, _, _, True, _, _, _, _ -> #("~>", string.drop_start(trimmed, 2))
    _, _, _, _, _, True, _, _, _ -> #(">", string.drop_start(trimmed, 1))
    _, _, _, _, _, _, True, _, _ -> #("<", string.drop_start(trimmed, 1))
    _, _, _, _, _, _, _, True, _ -> #("^", string.drop_start(trimmed, 1))
    _, _, _, _, _, _, _, _, True -> #("==", string.drop_start(trimmed, 1))
    _, _, _, _, _, _, _, _, _ -> #("==", trimmed)
  }
  let ver_str = string.trim(rest)
  let without_build = case string.split_once(ver_str, "+") {
    Ok(#(v, _)) -> v
    Error(_) -> ver_str
  }
  let #(core, pre) = case string.split_once(without_build, "-") {
    Ok(#(c, p)) -> #(c, Some(p))
    Error(_) -> #(without_build, None)
  }
  let nums = string.split(core, ".")
  case nums {
    [maj_s, min_s] -> {
      use maj <- result.try(parse_ver_int(maj_s, clause))
      use min <- result.try(parse_ver_int(min_s, clause))
      Ok(VersionClause(op:, major: maj, minor: min, patch: None, pre:))
    }
    [maj_s, min_s, pat_s] -> {
      use maj <- result.try(parse_ver_int(maj_s, clause))
      use min <- result.try(parse_ver_int(min_s, clause))
      use pat <- result.try(parse_ver_int(pat_s, clause))
      Ok(VersionClause(op:, major: maj, minor: min, patch: Some(pat), pre:))
    }
    _ -> Error("Invalid SemVer clause '" <> clause <> "'")
  }
}

fn parse_semver(raw: String) -> Result(SemVer, String) {
  let trimmed = string.trim(raw)
  let without_build = case string.split_once(trimmed, "+") {
    Ok(#(v, _)) -> v
    Error(_) -> trimmed
  }
  let #(core, pre) = case string.split_once(without_build, "-") {
    Ok(#(c, p)) -> #(c, Some(p))
    Error(_) -> #(without_build, None)
  }
  case string.split(core, ".") {
    [maj_s, min_s, pat_s] -> {
      use major <- result.try(parse_ver_int(maj_s, raw))
      use minor <- result.try(parse_ver_int(min_s, raw))
      use patch <- result.try(parse_ver_int(pat_s, raw))
      Ok(SemVer(major:, minor:, patch:, pre:))
    }
    _ -> Error("Invalid SemVer version '" <> raw <> "'")
  }
}

fn parse_ver_int(s: String, ctx: String) -> Result(Int, String) {
  case int.parse(s) {
    Ok(n) if n >= 0 -> Ok(n)
    _ -> Error("Invalid SemVer component '" <> s <> "' in '" <> ctx <> "'")
  }
}

fn eval_clause(ver: SemVer, clause: VersionClause) -> Bool {
  let target =
    SemVer(
      major: clause.major,
      minor: clause.minor,
      patch: option.unwrap(clause.patch, 0),
      pre: clause.pre,
    )
  let cmp = compare_semver(ver, target)
  case clause.op {
    "==" -> cmp == 0
    "!=" -> cmp != 0
    ">" -> cmp > 0
    ">=" -> cmp >= 0
    "<" -> cmp < 0
    "<=" -> cmp <= 0
    "~>" -> {
      let upper = case clause.patch {
        None -> SemVer(major: clause.major + 1, minor: 0, patch: 0, pre: None)
        Some(_) ->
          SemVer(
            major: clause.major,
            minor: clause.minor + 1,
            patch: 0,
            pre: None,
          )
      }
      cmp >= 0 && compare_semver(ver, upper) < 0
    }
    "^" -> {
      let upper = case clause.major, clause.minor {
        0, 0 -> SemVer(major: 0, minor: 0, patch: target.patch + 1, pre: None)
        0, _ -> SemVer(major: 0, minor: clause.minor + 1, patch: 0, pre: None)
        _, _ -> SemVer(major: clause.major + 1, minor: 0, patch: 0, pre: None)
      }
      cmp >= 0 && compare_semver(ver, upper) < 0
    }
    _ -> False
  }
}

fn compare_semver(a: SemVer, b: SemVer) -> Int {
  case int.compare(a.major, b.major) {
    order.Lt -> -1
    order.Gt -> 1
    order.Eq ->
      case int.compare(a.minor, b.minor) {
        order.Lt -> -1
        order.Gt -> 1
        order.Eq ->
          case int.compare(a.patch, b.patch) {
            order.Lt -> -1
            order.Gt -> 1
            order.Eq ->
              case a.pre, b.pre {
                None, None -> 0
                Some(_), None -> -1
                None, Some(_) -> 1
                Some(pa), Some(pb) ->
                  case string.compare(pa, pb) {
                    order.Lt -> -1
                    order.Gt -> 1
                    order.Eq -> 0
                  }
              }
          }
      }
  }
}
