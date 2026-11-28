///|
pub fn slugify(title : StringView) -> StringView {
  @text.trim_lower_dash(title)
}

///|
pub fn[T0] reverse_list(items : @gprelude.GList[T0]) -> @gprelude.GList[T0] {
  do_reverse(items, @gprelude.Nil)
}

///|
fn[T0] do_reverse(items : @gprelude.GList[T0], acc : @gprelude.GList[T0]) -> @gprelude.GList[T0] {
  for items = items, acc = acc {
    match items {
      @gprelude.Nil => break acc
      @gprelude.Cons(head, tail) => continue tail, @gprelude.Cons(head, acc)
    }
  }
}
