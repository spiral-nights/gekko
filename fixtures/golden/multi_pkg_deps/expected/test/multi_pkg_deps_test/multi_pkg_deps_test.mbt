///|
pub fn user_record_and_option_test() -> Unit {
  let u1 = @multi_pkg_deps.User(name="Akira", score=42L, nickname=Some("Aki"), tags=@gprelude.Cons("gleam", @gprelude.Cons("wasm", @gprelude.Nil)))
  let u2 = @multi_pkg_deps.User(name="Rei", score=7L, nickname=None, tags=@gprelude.Nil)
  if !((@multi_pkg_deps.format_user(u1) == "Akira:42:Aki")) {
    @prelude.abort("assertion failed")
  }
  if !((@multi_pkg_deps.format_user(u2) == "Rei:7:none")) {
    @prelude.abort("assertion failed")
  }
}

///|
test "user_record_and_option_test" {
  @prelude.ignore(user_record_and_option_test())
}

///|
pub fn kv_upsert_and_fold_test() -> Unit {
  let counts = @multi_pkg_deps.count_tags(@gprelude.Cons("a", @gprelude.Cons("b", @gprelude.Cons("a", @gprelude.Cons("c", @gprelude.Cons("a", @gprelude.Nil))))))
  if !((@kv.get(counts, "a") == Ok(3L))) {
    @prelude.abort("assertion failed")
  }
  if !((@kv.get(counts, "b") == Ok(1L))) {
    @prelude.abort("assertion failed")
  }
  if !((@kv.get(counts, "missing") == Err(()))) {
    @prelude.abort("assertion failed")
  }
  let sum = @kv.fold(counts, 0L, fn(acc : Int64, _, v : Int64) {
  (acc + v)
})
  if !((sum == 5L)) {
    @prelude.abort("assertion failed")
  }
}

///|
test "kv_upsert_and_fold_test" {
  @prelude.ignore(kv_upsert_and_fold_test())
}

///|
pub fn dep_slug_and_bits_test() -> Unit {
  if !((@multi_pkg_deps.format_badge("  Hello Gleam  ", true, 9L) == "hello-gleam:True:9")) {
    @prelude.abort("assertion failed")
  }
  if !((@multi_pkg_deps.check_bytes("moonbeam") == Ok("MOONBEAM"))) {
    @prelude.abort("assertion failed")
  }
}

///|
test "dep_slug_and_bits_test" {
  @prelude.ignore(dep_slug_and_bits_test())
}

///|
pub fn reverse_dep_test() -> Unit {
  if !((@multi_pkg_deps.reverse_through_dep(@gprelude.Cons(1L, @gprelude.Cons(2L, @gprelude.Cons(3L, @gprelude.Nil)))) == @gprelude.Cons(3L, @gprelude.Cons(2L, @gprelude.Cons(1L, @gprelude.Nil))))) {
    @prelude.abort("assertion failed")
  }
}

///|
test "reverse_dep_test" {
  @prelude.ignore(reverse_dep_test())
}
