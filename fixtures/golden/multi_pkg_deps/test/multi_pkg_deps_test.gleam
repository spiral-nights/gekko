import gleeunit
import mini_ffi/kv
import mini_ffi/option.{None, Some}
import multi_pkg_deps.{User}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn user_record_and_option_test() {
  let u1 =
    User(name: "Akira", score: 42, nickname: Some("Aki"), tags: [
      "gleam",
      "wasm",
    ])
  let u2 = User(name: "Rei", score: 7, nickname: None, tags: [])
  assert multi_pkg_deps.format_user(u1) == "Akira:42:Aki"
  assert multi_pkg_deps.format_user(u2) == "Rei:7:none"
}

pub fn kv_upsert_and_fold_test() {
  let counts = multi_pkg_deps.count_tags(["a", "b", "a", "c", "a"])
  assert kv.get(from: counts, get: "a") == Ok(3)
  assert kv.get(from: counts, get: "b") == Ok(1)
  assert kv.get(from: counts, get: "missing") == Error(Nil)
  let sum = kv.fold(over: counts, from: 0, with: fn(acc, _k, v) { acc + v })
  assert sum == 5
}

pub fn dep_slug_and_bits_test() {
  assert multi_pkg_deps.format_badge("  Hello Gleam  ", True, 9)
    == "hello-gleam:True:9"
  assert multi_pkg_deps.check_bytes("moonbeam") == Ok("MOONBEAM")
}

pub fn reverse_dep_test() {
  assert multi_pkg_deps.reverse_through_dep([1, 2, 3]) == [3, 2, 1]
}
