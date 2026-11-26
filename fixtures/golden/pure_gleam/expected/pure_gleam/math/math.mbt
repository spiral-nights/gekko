///|
pub fn add(a : Int64, b : Int64) -> Int64 {
  (a + b)
}

///|
pub fn safe_div(a : Int64, b : Int64) -> Int64 {
  @gprelude.int_div(a, b)
}

///|
pub fn safe_rem(a : Int64, b : Int64) -> Int64 {
  @gprelude.int_rem(a, b)
}

///|
pub fn safe_fdiv(a : Double, b : Double) -> Double {
  @gprelude.float_div(a, b)
}

///|
pub fn sum_list(items : @gprelude.GList[Int64], acc : Int64) -> Int64 {
  for items = items, acc = acc {
    match items {
      @gprelude.Nil => break acc
      @gprelude.Cons(x, rest) => continue rest, (acc + x)
    }
  }
}

///|
pub fn[T0] reverse_list(items : @gprelude.GList[T0], acc : @gprelude.GList[T0]) -> @gprelude.GList[T0] {
  for items = items, acc = acc {
    match items {
      @gprelude.Nil => break acc
      @gprelude.Cons(x, rest) => continue rest, @gprelude.Cons(x, acc)
    }
  }
}

///|
pub fn factorial(n : Int64, acc : Int64) -> Int64 {
  for n = n, acc = acc {
    match (n <= 1L) {
      true => break acc
      false => continue (n - 1L), (acc * n)
    }
  }
}

///|
pub fn build_range(n : Int64, acc : @gprelude.GList[Int64]) -> @gprelude.GList[Int64] {
  for n = n, acc = acc {
    match (n <= 0L) {
      true => break acc
      false => continue (n - 1L), @gprelude.Cons(n, acc)
    }
  }
}
