///|
pub fn golden_math_and_tco_test() -> Unit {
  if !((@math.safe_div(10L, 0L) == 0L)) {
    @prelude.abort("assertion failed")
  }
  if !((@math.safe_rem(10L, 0L) == 0L)) {
    @prelude.abort("assertion failed")
  }
  if !((@math.safe_fdiv(5.0, 0.0) == 0.0)) {
    @prelude.abort("assertion failed")
  }
  if !((@math.factorial(6L, 1L) == 720L)) {
    @prelude.abort("assertion failed")
  }
  if !((@math.reverse_list(@gprelude.Cons(1L, @gprelude.Cons(2L, @gprelude.Cons(3L, @gprelude.Nil))), @gprelude.Nil) == @gprelude.Cons(3L, @gprelude.Cons(2L, @gprelude.Cons(1L, @gprelude.Nil))))) {
    @prelude.abort("assertion failed")
  }
  let big = @math.build_range(10_000L, @gprelude.Nil)
  if !((@math.sum_list(big, 0L) == 50_005_000L)) {
    @prelude.abort("assertion failed")
  }
}

///|
test "golden_math_and_tco_test" {
  @prelude.ignore(golden_math_and_tco_test())
}

///|
pub fn golden_pipeline_use_and_strings_test() -> Unit {
  if !((@pure_gleam.run_pipeline(4L) == 28L)) {
    @prelude.abort("assertion failed")
  }
  if !((@pure_gleam.parse_command("cmd:build") == Ok("[cmd]:build"))) {
    @prelude.abort("assertion failed")
  }
  if !((@pure_gleam.parse_command("cmd:") == Err("empty"))) {
    @prelude.abort("assertion failed")
  }
  if !((@pure_gleam.parse_command("other") == Err("unknown"))) {
    @prelude.abort("assertion failed")
  }
}

///|
test "golden_pipeline_use_and_strings_test" {
  @prelude.ignore(golden_pipeline_use_and_strings_test())
}

///|
pub fn golden_models_getters_and_updates_test() -> Unit {
  let admin = @models.make_admin(7L, "Ada")
  let p = @models.Point(x=1.5, y=2.5)
  let (id, name, shifted, hook_val) = @pure_gleam.check_user(admin, p)
  if !((id == 7L)) {
    @prelude.abort("assertion failed")
  }
  if !((name == "Ada")) {
    @prelude.abort("assertion failed")
  }
  if !((shifted.x() == 6.5)) {
    @prelude.abort("assertion failed")
  }
  if !((shifted.y() == 2.5)) {
    @prelude.abort("assertion failed")
  }
  if !((hook_val == 50L)) {
    @prelude.abort("assertion failed")
  }
  let promoted = @models.promote(admin, 99L)
  if !((promoted == @models.Admin(id=7L, name="Ada", level=99L))) {
    @prelude.abort("assertion failed")
  }
}

///|
test "golden_models_getters_and_updates_test" {
  @prelude.ignore(golden_models_getters_and_updates_test())
}

///|
pub fn golden_assert_and_bits_test() -> Unit {
  if !((@pure_gleam.check_assert_and_bits(Ok(21L)) == 21L)) {
    @prelude.abort("assertion failed")
  }
}

///|
test "golden_assert_and_bits_test" {
  @prelude.ignore(golden_assert_and_bits_test())
}
