///|
#derive(Debug)
pub(all) struct MiniMap[K, V] {
  inner : Map[K, V]
}

///|
pub impl[K : Eq + Hash, V : Eq] Eq for MiniMap[K, V] with equal(self, other) {
  self.inner == other.inner
}

///|
pub impl[K : Hash, V : Hash] Hash for MiniMap[K, V] with hash_combine(
  self,
  hasher,
) {
  hasher.combine_int(self.inner.length())
  self.inner.each(fn(k, v) {
    hasher.combine(k)
    hasher.combine(v)
  })
}

///|
pub impl[K : @gprelude.GleamInspect, V : @gprelude.GleamInspect] @gprelude.GleamInspect for MiniMap[
  K,
  V,
] with gleam_inspect(self) {
  let mut s = "mini_map(["
  let mut first = true
  self.inner.each(fn(k, v) {
    if !first {
      s = s + ", "
    }
    first = false
    s = s +
      "#(" +
      @gprelude.GleamInspect::gleam_inspect(k) +
      ", " +
      @gprelude.GleamInspect::gleam_inspect(v) +
      ")"
  })
  s + "])"
}

///|
pub fn[K, V] map_new() -> MiniMap[K, V] {
  { inner: Default::default() }
}

///|
pub fn[K : Eq + Hash, V] map_insert(
  m : MiniMap[K, V],
  key : K,
  val : V,
) -> MiniMap[K, V] {
  let copy = m.inner.copy()
  copy.set(key, val)
  { inner: copy }
}

///|
pub fn[K : Eq + Hash, V] map_get(m : MiniMap[K, V], key : K) -> Result[V, Unit] {
  match m.inner.get(key) {
    Some(v) => Ok(v)
    None => Err(())
  }
}

///|
pub fn[K, V, Acc] map_fold(
  m : MiniMap[K, V],
  initial : Acc,
  f : (Acc, K, V) -> Acc,
) -> Acc {
  let mut acc = initial
  m.inner.each(fn(k, v) { acc = f(acc, k, v) })
  acc
}

///|
pub fn trim_lower_dash(s : String) -> String {
  s
  .trim(chars=" \t\n\r")
  .to_owned()
  .to_lower()
  .replace_all(old=" ", new="-")
}

///|
pub fn uppercase(s : String) -> String {
  s.to_upper()
}

///|
pub fn int_to_string(n : Int64) -> String {
  n.to_string()
}

///|
pub fn string_to_bits(s : String) -> @gprelude.BitArray {
  @gprelude.BitArray::from_string(s)
}

///|
pub fn bits_to_string(bits : @gprelude.BitArray) -> Result[String, Unit] {
  if bits.bit_length % 8L != 0L {
    return Err(())
  }
  let buf = StringBuilder()
  let mut offset = 0L
  while offset < bits.bit_length {
    match @gprelude.bit_array_read_utf8_codepoint(bits, offset) {
      Some((cp, next)) => {
        buf.write_char(cp)
        offset = next
      }
      None => return Err(())
    }
  }
  Ok(buf.to_string())
}
