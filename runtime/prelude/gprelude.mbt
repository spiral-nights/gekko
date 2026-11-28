// =============================================================================
// Section 1: Public Gleam FFI Types & Traits
// =============================================================================

///|
/// Immutable singly-linked list backing Gleam's `List(a)`.
#derive(Debug)
pub(all) enum GList[T] {
  Nil
  Cons(T, GList[T])
}

///|
pub impl[T : Eq] Eq for GList[T] with equal(self, other) {
  for a = self, b = other {
    match (a, b) {
      (Nil, Nil) => break true
      (Cons(ha, ta), Cons(hb, tb)) =>
        if ha == hb {
          continue ta, tb
        } else {
          break false
        }
      _ => break false
    }
  }
}

///|
pub impl[T : Hash] Hash for GList[T] with hash_combine(self, hasher) {
  let mut len = 0
  for cur = self {
    match cur {
      Nil => break
      Cons(head, tail) => {
        hasher.combine(head)
        len = len + 1
        continue tail
      }
    }
  }
  hasher.combine_int(len)
}

///|
/// Convert a Gleam `GList[T]` into a MoonBit `Array[T]`.
pub fn[T] GList::to_array(self : GList[T]) -> Array[T] {
  let out : Array[T] = []
  for cur = self {
    match cur {
      Nil => break out
      Cons(head, tail) => {
        out.push(head)
        continue tail
      }
    }
  }
}

///|
/// Construct a Gleam `GList[T]` from a MoonBit `ArrayView[T]`.
pub fn[T] GList::from_array(arr : ArrayView[T]) -> GList[T] {
  let mut acc : GList[T] = Nil
  let mut i = arr.length() - 1
  while i >= 0 {
    acc = Cons(arr[i], acc)
    i = i - 1
  }
  acc
}

///|
fn[T] GList::reverse(self : GList[T]) -> GList[T] {
  for cur = self, acc = Nil {
    match cur {
      Nil => break acc
      Cons(head, tail) => continue tail, Cons(head, acc)
    }
  }
}

///|
pub fn[A, B] GList::map(self : GList[A], f : (A) -> B) -> GList[B] {
  let mut rev : GList[B] = Nil
  for cur = self {
    match cur {
      Nil => break
      Cons(head, tail) => {
        rev = Cons(f(head), rev)
        continue tail
      }
    }
  }
  rev.reverse()
}

///|
/// Bit-accurate binary backing Gleam's `BitArray`.
#derive(Eq, Debug, Hash)
pub(all) struct BitArray {
  data : Bytes
  bit_length : Int64
}

///|
/// Return an empty `BitArray`.
pub fn BitArray::empty() -> BitArray {
  { data: b"", bit_length: 0L }
}

///|
/// Wrap a MoonBit `Bytes` buffer as a byte-aligned `BitArray`.
pub fn BitArray::from_bytes(b : Bytes) -> BitArray {
  { data: b, bit_length: b.length().to_int64() * 8L }
}

///|
/// Encode a `StringView` as UTF-8 bytes into a `BitArray`.
pub fn BitArray::from_string(s : StringView) -> BitArray {
  BitArray::from_bytes(@utf8.encode(s))
}

///|
/// Return the total number of bits in `self`.
pub fn BitArray::bit_size(self : BitArray) -> Int64 {
  self.bit_length
}

///|
pub fn bit_array_bit_size(ba : BitArray) -> Int64 {
  ba.bit_length
}

///|
/// Return the number of bytes in `self` (rounded up to full bytes in `data`).
pub fn BitArray::byte_size(self : BitArray) -> Int64 {
  self.data.length().to_int64()
}

///|
/// Pad a `BitArray` to a full byte boundary.
pub fn BitArray::pad_to_bytes(self : BitArray) -> BitArray {
  { data: self.data, bit_length: self.data.length().to_int64() * 8L }
}

///|
/// Concatenate an `ArrayView[BitArray]` into a single `BitArray`.
pub fn BitArray::concat(parts : ArrayView[BitArray]) -> BitArray {
  let mut total_bits = 0L
  let mut all_aligned = true
  for part in parts {
    total_bits = total_bits + part.bit_length
    if part.bit_length % 8L != 0L {
      all_aligned = false
    }
  }
  if total_bits == 0L {
    return BitArray::empty()
  }
  let buf = @buffer.Buffer()
  if all_aligned {
    for part in parts {
      if part.bit_length > 0L {
        buf.write_bytesview(part.data[:])
      }
    }
    return { data: buf.to_bytes(), bit_length: total_bits }
  }
  let mut acc = 0
  let mut acc_bits = 0
  for part in parts {
    if part.bit_length <= 0L {
      continue
    }
    let full_bytes = (part.bit_length / 8L).to_int()
    let rem = (part.bit_length % 8L).to_int()
    let mut i = 0
    while i < full_bytes {
      let b = part.data[i].to_int()
      if acc_bits == 0 {
        buf.write_byte(part.data[i])
      } else {
        let combined = (acc << 8) | b
        buf.write_byte(((combined >> acc_bits) & 0xFF).to_byte())
        acc = combined & ((1 << acc_bits) - 1)
      }
      i = i + 1
    }
    if rem > 0 {
      let v = part.data[full_bytes].to_int() >> (8 - rem)
      acc = (acc << rem) | v
      acc_bits = acc_bits + rem
      if acc_bits >= 8 {
        acc_bits = acc_bits - 8
        buf.write_byte(((acc >> acc_bits) & 0xFF).to_byte())
        acc = acc & ((1 << acc_bits) - 1)
      }
    }
  }
  if acc_bits > 0 {
    buf.write_byte((acc << (8 - acc_bits)).to_byte())
  }
  { data: buf.to_bytes(), bit_length: total_bits }
}

///|
pub fn bit_array_from_segments(parts : ArrayView[BitArray]) -> BitArray {
  BitArray::concat(parts)
}

///|
pub fn BitArray::bits_segment(self : BitArray, bits : Int64) -> BitArray {
  if bits <= 0L {
    BitArray::empty()
  } else if bits == self.bit_length {
    self
  } else {
    match bit_array_read_bits(self, 0L, bits) {
      Some(v) => v
      None => @prelude.abort("bit array segment shorter than specified size")
    }
  }
}

///|
pub fn BitArray::int_segment(
  val : Int64,
  bits : Int64,
  big_endian : Bool,
) -> BitArray {
  if bits <= 0L {
    return BitArray::empty()
  }
  let buf = @buffer.Buffer()
  if bits == 8L {
    buf.write_byte(val.to_byte())
  } else if bits == 16L {
    let hi = (val >> 8).to_byte()
    let lo = val.to_byte()
    if big_endian {
      buf.write_byte(hi)
      buf.write_byte(lo)
    } else {
      buf.write_byte(lo)
      buf.write_byte(hi)
    }
  } else if bits == 32L {
    if big_endian {
      buf.write_int_be(val.to_int())
    } else {
      buf.write_int_le(val.to_int())
    }
  } else if bits == 64L {
    if big_endian {
      buf.write_int64_be(val)
    } else {
      buf.write_int64_le(val)
    }
  } else if big_endian {
    let uval = val.reinterpret_as_uint64()
    let fill_byte = if val < 0L { b'\xFF' } else { b'\x00' }
    let sign_bit = if val < 0L { 1 } else { 0 }
    if bits > 64L {
      let extra = bits - 64L
      let extra_bytes = extra / 8L
      let mut bi = 0L
      while bi < extra_bytes {
        buf.write_byte(fill_byte)
        bi = bi + 1L
      }
      let mut cur = 0
      let mut cur_bits = 0
      let rem_extra = (extra % 8L).to_int()
      let mut ei = 0
      while ei < rem_extra {
        cur = (cur << 1) | sign_bit
        cur_bits = cur_bits + 1
        ei = ei + 1
      }
      let mut k = 63
      while k >= 0 {
        let b = ((uval >> k) & 1UL).to_int()
        cur = (cur << 1) | b
        cur_bits = cur_bits + 1
        if cur_bits == 8 {
          buf.write_byte(cur.to_byte())
          cur = 0
          cur_bits = 0
        }
        k = k - 1
      }
      if cur_bits > 0 {
        buf.write_byte((cur << (8 - cur_bits)).to_byte())
      }
    } else {
      let mut cur = 0
      let mut cur_bits = 0
      let mut k = bits.to_int() - 1
      while k >= 0 {
        let b = ((uval >> k) & 1UL).to_int()
        cur = (cur << 1) | b
        cur_bits = cur_bits + 1
        if cur_bits == 8 {
          buf.write_byte(cur.to_byte())
          cur = 0
          cur_bits = 0
        }
        k = k - 1
      }
      if cur_bits > 0 {
        buf.write_byte((cur << (8 - cur_bits)).to_byte())
      }
    }
  } else {
    let uval = val.reinterpret_as_uint64()
    let full_bytes = bits / 8L
    let rem = (bits % 8L).to_int()
    let fill_byte = if val < 0L { b'\xFF' } else { b'\x00' }
    let mut byte_idx = 0L
    while byte_idx < full_bytes {
      if byte_idx < 8L {
        buf.write_byte(((uval >> (byte_idx.to_int() * 8)) & 0xFFUL).to_byte())
      } else {
        buf.write_byte(fill_byte)
      }
      byte_idx = byte_idx + 1L
    }
    if rem > 0 {
      let top_bits = if full_bytes < 8L {
        ((uval >> (full_bytes.to_int() * 8)) & ((1UL << rem) - 1UL)).to_int()
      } else if val < 0L {
        (1 << rem) - 1
      } else {
        0
      }
      buf.write_byte((top_bits << (8 - rem)).to_byte())
    }
  }
  { data: buf.to_bytes(), bit_length: bits }
}

///|
fn write_u16(buf : @buffer.Buffer, v : Int, big_endian : Bool) -> Unit {
  let hi = ((v >> 8) & 0xFF).to_byte()
  let lo = (v & 0xFF).to_byte()
  if big_endian {
    buf.write_byte(hi)
    buf.write_byte(lo)
  } else {
    buf.write_byte(lo)
    buf.write_byte(hi)
  }
}

///|
fn write_u32(buf : @buffer.Buffer, v : Int, big_endian : Bool) -> Unit {
  if big_endian {
    buf.write_int_be(v)
  } else {
    buf.write_int_le(v)
  }
}

///|
fn double_to_f16_bits(val : Double) -> Int {
  let bits = val.reinterpret_as_uint64()
  let sign = ((bits >> 63) & 1UL).to_int() << 15
  let exp = ((bits >> 52) & 0x7FFUL).to_int()
  let frac = bits & 0x000F_FFFF_FFFF_FFFFUL
  if exp == 0x7FF {
    if frac == 0UL {
      sign | 0x7C00
    } else {
      sign | 0x7E00
    }
  } else if exp == 0 {
    sign
  } else {
    let unb = exp - 1023
    if unb > 15 {
      sign | 0x7C00
    } else if unb >= -14 {
      let mut rounded_exp = unb + 15
      let mant = (frac >> 42).to_int()
      let rem = frac & 0x0000_03FF_FFFF_FFFFUL
      let half = 0x0000_0200_0000_0000UL
      let mut rounded_mant = mant
      if rem > half || (rem == half && (mant & 1) == 1) {
        rounded_mant = rounded_mant + 1
        if rounded_mant == 1024 {
          rounded_mant = 0
          rounded_exp = rounded_exp + 1
          if rounded_exp >= 31 {
            return sign | 0x7C00
          }
        }
      }
      sign | (rounded_exp << 10) | rounded_mant
    } else if unb >= -25 {
      let shift = 28 - unb
      let sig = (1UL << 52) | frac
      let mant = (sig >> shift).to_int()
      let half = 1UL << (shift - 1)
      let rem = sig & ((1UL << shift) - 1UL)
      let mut final_mant = mant
      if rem > half || (rem == half && (mant & 1) == 1) {
        final_mant = final_mant + 1
      }
      sign | final_mant
    } else {
      sign
    }
  }
}

///|
fn f16_bits_to_double(h : Int) -> Option[Double] {
  let sign_bit = (h >> 15) & 1
  let exp = (h >> 10) & 0x1F
  let mant = h & 0x3FF
  if exp == 0x1F {
    None
  } else if exp == 0 {
    let mag = mant.to_double() * 5.960464477539063e-8
    Some(if sign_bit == 1 { -mag } else { mag })
  } else {
    let d_sign = sign_bit.to_uint64() << 63
    let d_exp = (exp - 15 + 1023).to_uint64() << 52
    let d_mant = mant.to_uint64() << 42
    Some((d_sign | d_exp | d_mant).reinterpret_as_double())
  }
}

///|
pub fn BitArray::float_segment(
  val : Double,
  bits : Int64,
  big_endian : Bool,
) -> BitArray {
  let buf = @buffer.Buffer()
  if bits == 16L {
    write_u16(buf, double_to_f16_bits(val), big_endian)
  } else if bits == 32L {
    let f = Float::from_double(val)
    if big_endian {
      buf.write_float_be(f)
    } else {
      buf.write_float_le(f)
    }
  } else if bits == 64L {
    if big_endian {
      buf.write_double_be(val)
    } else {
      buf.write_double_le(val)
    }
  } else {
    @prelude.abort("unsupported float bit segment width in BitArray")
  }
  { data: buf.to_bytes(), bit_length: bits }
}

///|
fn write_utf8_cp(buf : @buffer.Buffer, c : Int) -> Unit {
  if c <= 0x7F {
    buf.write_byte(c.to_byte())
  } else if c <= 0x7FF {
    buf.write_byte((0xC0 | (c >> 6)).to_byte())
    buf.write_byte((0x80 | (c & 0x3F)).to_byte())
  } else if c <= 0xFFFF {
    buf.write_byte((0xE0 | (c >> 12)).to_byte())
    buf.write_byte((0x80 | ((c >> 6) & 0x3F)).to_byte())
    buf.write_byte((0x80 | (c & 0x3F)).to_byte())
  } else {
    buf.write_byte((0xF0 | (c >> 18)).to_byte())
    buf.write_byte((0x80 | ((c >> 12) & 0x3F)).to_byte())
    buf.write_byte((0x80 | ((c >> 6) & 0x3F)).to_byte())
    buf.write_byte((0x80 | (c & 0x3F)).to_byte())
  }
}

///|
fn write_utf16_cp(buf : @buffer.Buffer, c : Int, big_endian : Bool) -> Unit {
  if c <= 0xFFFF {
    write_u16(buf, c, big_endian)
  } else {
    let u = c - 0x10000
    let hi = 0xD800 | (u >> 10)
    let lo = 0xDC00 | (u & 0x3FF)
    write_u16(buf, hi, big_endian)
    write_u16(buf, lo, big_endian)
  }
}

///|
pub fn BitArray::from_utf16(s : StringView, big_endian : Bool) -> BitArray {
  let buf = @buffer.Buffer()
  for ch in s {
    write_utf16_cp(buf, ch.to_int(), big_endian)
  }
  BitArray::from_bytes(buf.to_bytes())
}

///|
pub fn BitArray::from_utf32(s : StringView, big_endian : Bool) -> BitArray {
  let buf = @buffer.Buffer()
  for ch in s {
    write_u32(buf, ch.to_int(), big_endian)
  }
  BitArray::from_bytes(buf.to_bytes())
}

///|
pub fn BitArray::utf8_codepoint_segment(cp : Char) -> BitArray {
  let buf = @buffer.Buffer()
  write_utf8_cp(buf, cp.to_int())
  BitArray::from_bytes(buf.to_bytes())
}

///|
pub fn BitArray::utf16_codepoint_segment(
  cp : Char,
  big_endian : Bool,
) -> BitArray {
  let buf = @buffer.Buffer()
  write_utf16_cp(buf, cp.to_int(), big_endian)
  BitArray::from_bytes(buf.to_bytes())
}

///|
pub fn BitArray::utf32_codepoint_segment(
  cp : Char,
  big_endian : Bool,
) -> BitArray {
  let buf = @buffer.Buffer()
  write_u32(buf, cp.to_int(), big_endian)
  BitArray::from_bytes(buf.to_bytes())
}

///|
fn bit_array_read_byte_at(ba : BitArray, offset : Int64) -> Int {
  let byte_idx = (offset / 8L).to_int()
  let bit_off = (offset % 8L).to_int()
  if bit_off == 0 {
    ba.data[byte_idx].to_int()
  } else {
    let b0 = ba.data[byte_idx].to_int()
    let b1 = if byte_idx + 1 < ba.data.length() {
      ba.data[byte_idx + 1].to_int()
    } else {
      0
    }
    ((b0 << bit_off) | (b1 >> (8 - bit_off))) & 0xFF
  }
}

///|
fn bit_array_read_small_bits(ba : BitArray, offset : Int64, n : Int) -> Int {
  bit_array_read_byte_at(ba, offset) >> (8 - n)
}

///|
pub fn[T] bit_array_unwrap(opt : Option[T]) -> T {
  match opt {
    Some(v) => v
    None => @prelude.abort("bit array pattern match internal error")
  }
}

///|
pub fn bit_array_has_bits(
  ba : BitArray,
  offset : Int64,
  bits : Int64,
) -> Bool {
  bits >= 0L && offset >= 0L && offset + bits <= ba.bit_length
}

///|
pub fn bit_array_rest_is_bytes(ba : BitArray, offset : Int64) -> Bool {
  offset >= 0L && offset <= ba.bit_length && (ba.bit_length - offset) % 8L == 0L
}

///|
pub fn bit_array_read_int(
  ba : BitArray,
  offset : Int64,
  bits : Int64,
  signed : Bool,
  big_endian : Bool,
) -> Option[Int64] {
  if bits < 0L || offset < 0L || offset + bits > ba.bit_length {
    return None
  }
  if bits == 0L {
    return Some(0L)
  }
  if big_endian {
    if bits <= 64L {
      let full_bytes = (bits / 8L).to_int()
      let rem = (bits % 8L).to_int()
      let mut val = 0UL
      let mut i = 0
      while i < full_bytes {
        let b = bit_array_read_byte_at(ba, offset + i.to_int64() * 8L)
        val = (val << 8) | b.to_uint64()
        i = i + 1
      }
      if rem > 0 {
        let top = bit_array_read_small_bits(
          ba,
          offset + full_bytes.to_int64() * 8L,
          rem,
        )
        val = (val << rem) | top.to_uint64()
      }
      let b_int = bits.to_int()
      if signed && b_int < 64 && ((val >> (b_int - 1)) & 1UL) == 1UL {
        val = val | (0xFFFF_FFFF_FFFF_FFFFUL << b_int)
      }
      Some(val.reinterpret_as_int64())
    } else {
      let start = offset + (bits - 64L)
      let mut val = 0UL
      let mut i = 0
      while i < 8 {
        let b = bit_array_read_byte_at(ba, start + i.to_int64() * 8L)
        val = (val << 8) | b.to_uint64()
        i = i + 1
      }
      Some(val.reinterpret_as_int64())
    }
  } else {
    let full_bytes = bits / 8L
    let rem = (bits % 8L).to_int()
    let byte_count = if full_bytes < 8L { full_bytes.to_int() } else { 8 }
    let mut val = 0UL
    let mut i = 0
    while i < byte_count {
      let b = bit_array_read_byte_at(ba, offset + i.to_int64() * 8L)
      val = val | (b.to_uint64() << (i * 8))
      i = i + 1
    }
    if full_bytes < 8L && rem > 0 {
      let top = bit_array_read_small_bits(ba, offset + full_bytes * 8L, rem)
      val = val | (top.to_uint64() << (full_bytes.to_int() * 8))
    }
    if signed && bits < 64L {
      let b_int = bits.to_int()
      if ((val >> (b_int - 1)) & 1UL) == 1UL {
        val = val | (0xFFFF_FFFF_FFFF_FFFFUL << b_int)
      }
    }
    Some(val.reinterpret_as_int64())
  }
}

///|
pub fn bit_array_read_float(
  ba : BitArray,
  offset : Int64,
  bits : Int64,
  big_endian : Bool,
) -> Option[Double] {
  if bits == 16L {
    match bit_array_read_int(ba, offset, 16L, false, big_endian) {
      Some(i) => f16_bits_to_double(i.to_int())
      None => None
    }
  } else if bits == 32L {
    match bit_array_read_int(ba, offset, 32L, false, big_endian) {
      Some(i) => {
        let d = Float::reinterpret_from_uint(
          i.reinterpret_as_uint64().to_uint(),
        ).to_double()
        if d.is_nan() || d.is_inf() {
          None
        } else {
          Some(d)
        }
      }
      None => None
    }
  } else if bits == 64L {
    match bit_array_read_int(ba, offset, 64L, false, big_endian) {
      Some(i) => {
        let d = i.reinterpret_as_double()
        if d.is_nan() || d.is_inf() {
          None
        } else {
          Some(d)
        }
      }
      None => None
    }
  } else {
    None
  }
}

///|
pub fn bit_array_read_bits(
  ba : BitArray,
  offset : Int64,
  bits : Int64,
) -> Option[BitArray] {
  if bits < 0L || offset < 0L || offset + bits > ba.bit_length {
    return None
  }
  if bits == 0L {
    return Some(BitArray::empty())
  }
  let full_bytes = (bits / 8L).to_int()
  let rem = (bits % 8L).to_int()
  let buf = @buffer.Buffer()
  if offset % 8L == 0L {
    let start_byte = (offset / 8L).to_int()
    if full_bytes > 0 {
      buf.write_bytesview(ba.data[start_byte:start_byte + full_bytes])
    }
    if rem > 0 {
      let last_b = ba.data[start_byte + full_bytes].to_int()
      let mask = 0xFF ^ ((1 << (8 - rem)) - 1)
      buf.write_byte((last_b & mask).to_byte())
    }
    return Some({ data: buf.to_bytes(), bit_length: bits })
  }
  let mut i = 0
  while i < full_bytes {
    buf.write_byte(
      bit_array_read_byte_at(ba, offset + i.to_int64() * 8L).to_byte(),
    )
    i = i + 1
  }
  if rem > 0 {
    let top = bit_array_read_small_bits(
      ba,
      offset + full_bytes.to_int64() * 8L,
      rem,
    )
    buf.write_byte((top << (8 - rem)).to_byte())
  }
  Some({ data: buf.to_bytes(), bit_length: bits })
}

///|
pub fn bit_array_rest_bits(ba : BitArray, offset : Int64) -> Option[BitArray] {
  if offset < 0L || offset > ba.bit_length {
    None
  } else {
    bit_array_read_bits(ba, offset, ba.bit_length - offset)
  }
}

///|
pub fn bit_array_rest_bytes(ba : BitArray, offset : Int64) -> Option[BitArray] {
  if !bit_array_rest_is_bytes(ba, offset) {
    None
  } else {
    bit_array_read_bits(ba, offset, ba.bit_length - offset)
  }
}

///|
pub fn bit_array_match_bits(
  ba : BitArray,
  offset : Int64,
  expected : BitArray,
) -> Option[Int64] {
  if offset < 0L || offset + expected.bit_length > ba.bit_length {
    return None
  }
  let full_bytes = (expected.bit_length / 8L).to_int()
  let rem = (expected.bit_length % 8L).to_int()
  let mut i = 0
  while i < full_bytes {
    if bit_array_read_byte_at(ba, offset + i.to_int64() * 8L) !=
      expected.data[i].to_int() {
      return None
    }
    i = i + 1
  }
  if rem > 0 {
    let actual_rem = bit_array_read_small_bits(
      ba,
      offset + full_bytes.to_int64() * 8L,
      rem,
    )
    let exp_rem = expected.data[full_bytes].to_int() >> (8 - rem)
    if actual_rem != exp_rem {
      return None
    }
  }
  Some(offset + expected.bit_length)
}

///|
pub fn bit_array_read_utf8_codepoint(
  ba : BitArray,
  offset : Int64,
) -> Option[(Char, Int64)] {
  if offset < 0L || offset + 8L > ba.bit_length {
    return None
  }
  let b0 = bit_array_read_byte_at(ba, offset)
  if b0 <= 0x7F {
    return Some((b0.unsafe_to_char(), offset + 8L))
  }
  if b0 >= 0xC2 && b0 <= 0xDF {
    if offset + 16L > ba.bit_length {
      return None
    }
    let b1 = bit_array_read_byte_at(ba, offset + 8L)
    if (b1 & 0xC0) != 0x80 {
      return None
    }
    let cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F)
    return Some((cp.unsafe_to_char(), offset + 16L))
  }
  if b0 >= 0xE0 && b0 <= 0xEF {
    if offset + 24L > ba.bit_length {
      return None
    }
    let b1 = bit_array_read_byte_at(ba, offset + 8L)
    let b2 = bit_array_read_byte_at(ba, offset + 16L)
    if (b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 {
      return None
    }
    if b0 == 0xE0 && b1 < 0xA0 {
      return None
    }
    if b0 == 0xED && b1 >= 0xA0 {
      return None
    }
    let cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
    return Some((cp.unsafe_to_char(), offset + 24L))
  }
  if b0 >= 0xF0 && b0 <= 0xF4 {
    if offset + 32L > ba.bit_length {
      return None
    }
    let b1 = bit_array_read_byte_at(ba, offset + 8L)
    let b2 = bit_array_read_byte_at(ba, offset + 16L)
    let b3 = bit_array_read_byte_at(ba, offset + 24L)
    if (b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80 {
      return None
    }
    if b0 == 0xF0 && b1 < 0x90 {
      return None
    }
    if b0 == 0xF4 && b1 > 0x8F {
      return None
    }
    let cp = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
    return Some((cp.unsafe_to_char(), offset + 32L))
  }
  None
}

///|
pub fn bit_array_read_utf16_codepoint(
  ba : BitArray,
  offset : Int64,
  big_endian : Bool,
) -> Option[(Char, Int64)] {
  match bit_array_read_int(ba, offset, 16L, false, big_endian) {
    None => None
    Some(u1) => {
      let w1 = u1.to_int()
      if w1 < 0xD800 || w1 > 0xDFFF {
        Some((w1.unsafe_to_char(), offset + 16L))
      } else if w1 <= 0xDBFF {
        match bit_array_read_int(ba, offset + 16L, 16L, false, big_endian) {
          None => None
          Some(u2) => {
            let w2 = u2.to_int()
            if w2 >= 0xDC00 && w2 <= 0xDFFF {
              let cp = 0x10000 + ((w1 - 0xD800) << 10) + (w2 - 0xDC00)
              Some((cp.unsafe_to_char(), offset + 32L))
            } else {
              None
            }
          }
        }
      } else {
        None
      }
    }
  }
}

///|
pub fn bit_array_read_utf32_codepoint(
  ba : BitArray,
  offset : Int64,
  big_endian : Bool,
) -> Option[(Char, Int64)] {
  match bit_array_read_int(ba, offset, 32L, false, big_endian) {
    None => None
    Some(cp) =>
      if cp >= 0L && cp <= 0x10FFFFL && !(cp >= 0xD800L && cp <= 0xDFFFL) {
        Some((cp.to_int().unsafe_to_char(), offset + 32L))
      } else {
        None
      }
  }
}

///|
/// Dynamically typed value backing `gleam/dynamic.Dynamic`.
#derive(Eq, Debug)
pub(all) enum Dynamic {
  DynNull
  DynBool(Bool)
  DynInt(Int64)
  DynFloat(Double)
  DynString(StringView)
  DynBitArray(BitArray)
  DynList(GList[Dynamic])
  DynArray(Array[Dynamic])
  DynMap(Map[Dynamic, Dynamic])
}

///|
pub impl Hash for Dynamic with hash_combine(self, hasher) {
  match self {
    DynNull => hasher.combine_int(0)
    DynBool(b) => {
      hasher.combine_int(1)
      hasher.combine(b)
    }
    DynInt(i) => {
      hasher.combine_int(2)
      hasher.combine(i)
    }
    DynFloat(f) => {
      hasher.combine_int(3)
      hasher.combine(f)
    }
    DynString(s) => {
      hasher.combine_int(4)
      hasher.combine(s)
    }
    DynBitArray(ba) => {
      hasher.combine_int(5)
      hasher.combine(ba)
    }
    DynList(xs) => {
      hasher.combine_int(6)
      hasher.combine(xs)
    }
    DynArray(arr) => {
      hasher.combine_int(7)
      hasher.combine_int(arr.length())
      for item in arr {
        hasher.combine(item)
      }
    }
    DynMap(m) => {
      hasher.combine_int(8)
      hasher.combine_int(m.length())
      let mut sum = 0
      m.each(fn(k, v) { sum = sum + (Hash::hash(k) * 31 + Hash::hash(v)) })
      hasher.combine_int(sum)
    }
  }
}

// =============================================================================
// Section 2: Compiler-Emitted Runtime Helpers
// (Emitted by `gekko` codegen; not intended for direct FFI authoring.)
// =============================================================================

///|
pub fn int_div(a : Int64, b : Int64) -> Int64 {
  if b == 0L {
    0L
  } else if b == -1L {
    -a
  } else {
    a / b
  }
}

///|
pub fn int_rem(a : Int64, b : Int64) -> Int64 {
  if b == 0L || b == -1L {
    0L
  } else {
    a % b
  }
}

///|
pub fn float_div(a : Double, b : Double) -> Double {
  if b == 0.0 {
    0.0
  } else {
    a / b
  }
}

///|
pub fn string_has_prefix(s : StringView, prefix : StringView) -> Bool {
  s.has_prefix(prefix)
}

///|
pub fn string_drop_prefix(s : StringView, prefix : StringView) -> StringView {
  match s.strip_prefix(prefix) {
    Some(rest) => rest
    None => s
  }
}

///|
/// Boxed 0-tuple wrapper for Gleam `#()`.
#derive(Eq, Debug, Hash)
pub(all) enum Tuple0 {
  Tuple0
}

///|
/// Boxed 1-tuple wrapper for Gleam `#(a)`.
#derive(Eq, Debug, Hash)
pub(all) struct Tuple1[A](A)

///|
pub(all) struct InspectFn {
  arity : Int
}

///|
pub fn inspect_fn(arity : Int) -> InspectFn {
  { arity, }
}

///|
/// Trait powering Gleam's `echo` and `string.inspect`.
pub(open) trait GleamInspect {
  gleam_inspect(Self) -> String
  gleam_inspect_as_char(Self) -> Int? = _
}

///|
pub impl GleamInspect for Char with gleam_inspect(self) {
  "UtfCodepoint(" + self.to_int().to_string() + ")"
}

///|
impl GleamInspect with gleam_inspect_as_char(_) {
  None
}

///|
pub impl GleamInspect for Tuple0 with gleam_inspect(_) {
  "#()"
}

///|
pub impl[A : GleamInspect] GleamInspect for Tuple1[A] with gleam_inspect(self) {
  "#(" + GleamInspect::gleam_inspect(self.0) + ")"
}

///|
pub impl GleamInspect for InspectFn with gleam_inspect(self) {
  let buf = StringBuilder()
  buf.write_string("//fn(")
  let mut i = 0
  while i < self.arity {
    if i > 0 {
      buf.write_string(", ")
    }
    buf.write_char((97 + i).unsafe_to_char())
    i = i + 1
  }
  buf.write_string(") { ... }")
  buf.to_string()
}

///|
fn write_hex4_upper(buf : StringBuilder, code : Int) -> Unit {
  let hex = "0123456789ABCDEF"
  buf.write_char(hex[(code >> 12) & 0xF].to_int().unsafe_to_char())
  buf.write_char(hex[(code >> 8) & 0xF].to_int().unsafe_to_char())
  buf.write_char(hex[(code >> 4) & 0xF].to_int().unsafe_to_char())
  buf.write_char(hex[code & 0xF].to_int().unsafe_to_char())
}

///|
fn escape_gleam_string(s : StringView) -> String {
  let buf = StringBuilder()
  buf.write_char('"')
  for ch in s {
    match ch {
      '\\' => buf.write_string("\\\\")
      '"' => buf.write_string("\\\"")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      '\u{000C}' => buf.write_string("\\f")
      _ => {
        let code = ch.to_int()
        if code < 0x20 || (code >= 0x7F && code <= 0x9F) {
          buf.write_string("\\u{")
          write_hex4_upper(buf, code)
          buf.write_char('}')
        } else {
          buf.write_char(ch)
        }
      }
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
pub impl GleamInspect for Int64 with gleam_inspect(self) {
  self.to_string()
}

///|
pub impl GleamInspect for Int64 with gleam_inspect_as_char(self) {
  if self >= 32L && self <= 126L {
    Some(self.to_int())
  } else {
    None
  }
}

///|
pub impl GleamInspect for Double with gleam_inspect(self) {
  let raw = self.to_string().replace_all(old="+", new="").replace_all(old="E", new="e")
  if raw.contains(".") {
    raw
  } else {
    match raw.find("e") {
      Some(idx) =>
        raw.unsafe_substring(start=0, end=idx) +
        ".0" +
        raw.unsafe_substring(start=idx, end=raw.length())
      None =>
        if raw != "NaN" && raw != "Infinity" && raw != "-Infinity" {
          raw + ".0"
        } else {
          raw
        }
    }
  }
}

///|
pub impl GleamInspect for Bool with gleam_inspect(self) {
  if self {
    "True"
  } else {
    "False"
  }
}

///|
pub impl GleamInspect for Unit with gleam_inspect(_) {
  "Nil"
}

///|
pub impl GleamInspect for StringView with gleam_inspect(self) {
  escape_gleam_string(self)
}

///|
pub impl GleamInspect for String with gleam_inspect(self) {
  escape_gleam_string(self.to_string_view())
}

///|
pub impl GleamInspect for BitArray with gleam_inspect(self) {
  let buf = StringBuilder()
  buf.write_string("<<")
  let full_bytes = (self.bit_length / 8L).to_int()
  let rem = (self.bit_length % 8L).to_int()
  let mut i = 0
  while i < full_bytes {
    if i > 0 {
      buf.write_string(", ")
    }
    buf.write_string(self.data[i].to_int().to_string())
    i = i + 1
  }
  if rem > 0 {
    if full_bytes > 0 {
      buf.write_string(", ")
    }
    let v = self.data[full_bytes].to_int() >> (8 - rem)
    buf.write_string(v.to_string() + ":size(" + rem.to_string() + ")")
  }
  buf.write_string(">>")
  buf.to_string()
}

///|
pub impl[T : GleamInspect] GleamInspect for GList[T] with gleam_inspect(self) {
  match self {
    Nil => "[]"
    _ => {
      let list_buf = StringBuilder()
      list_buf.write_char('[')
      let char_buf = StringBuilder()
      let mut all_char = true
      for cur = self, first = true {
        match cur {
          Nil => break
          Cons(head, tail) => {
            if !first {
              list_buf.write_string(", ")
            }
            list_buf.write_string(GleamInspect::gleam_inspect(head))
            if all_char {
              match GleamInspect::gleam_inspect_as_char(head) {
                Some(c) => char_buf.write_char(c.unsafe_to_char())
                None => all_char = false
              }
            }
            continue tail, false
          }
        }
      }
      list_buf.write_char(']')
      if all_char {
        "charlist.from_string(" +
        escape_gleam_string(char_buf.to_string().to_string_view()) +
        ")"
      } else {
        list_buf.to_string()
      }
    }
  }
}

///|
pub impl[T : GleamInspect, E : GleamInspect] GleamInspect for Result[T, E] with gleam_inspect(
  self,
) {
  match self {
    Ok(v) => "Ok(" + GleamInspect::gleam_inspect(v) + ")"
    Err(e) => "Error(" + GleamInspect::gleam_inspect(e) + ")"
  }
}

///|
pub impl[T : GleamInspect] GleamInspect for Option[T] with gleam_inspect(self) {
  match self {
    Some(v) => "Some(" + GleamInspect::gleam_inspect(v) + ")"
    None => "None"
  }
}

///|
pub impl[A : GleamInspect, B : GleamInspect] GleamInspect for (A, B) with gleam_inspect(
  self,
) {
  "#(" + GleamInspect::gleam_inspect(self.0) + ", " + GleamInspect::gleam_inspect(self.1) + ")"
}

///|
pub impl[A : GleamInspect, B : GleamInspect, C : GleamInspect] GleamInspect for (
  A,
  B,
  C,
) with gleam_inspect(self) {
  "#(" +
  GleamInspect::gleam_inspect(self.0) +
  ", " +
  GleamInspect::gleam_inspect(self.1) +
  ", " +
  GleamInspect::gleam_inspect(self.2) +
  ")"
}

///|
pub impl[A : GleamInspect, B : GleamInspect, C : GleamInspect, D : GleamInspect] GleamInspect for (
  A,
  B,
  C,
  D,
) with gleam_inspect(self) {
  "#(" +
  GleamInspect::gleam_inspect(self.0) +
  ", " +
  GleamInspect::gleam_inspect(self.1) +
  ", " +
  GleamInspect::gleam_inspect(self.2) +
  ", " +
  GleamInspect::gleam_inspect(self.3) +
  ")"
}

///|
pub impl[
  A : GleamInspect,
  B : GleamInspect,
  C : GleamInspect,
  D : GleamInspect,
  E : GleamInspect,
] GleamInspect for (A, B, C, D, E) with gleam_inspect(self) {
  "#(" +
  GleamInspect::gleam_inspect(self.0) +
  ", " +
  GleamInspect::gleam_inspect(self.1) +
  ", " +
  GleamInspect::gleam_inspect(self.2) +
  ", " +
  GleamInspect::gleam_inspect(self.3) +
  ", " +
  GleamInspect::gleam_inspect(self.4) +
  ")"
}

///|
pub impl[
  A : GleamInspect,
  B : GleamInspect,
  C : GleamInspect,
  D : GleamInspect,
  E : GleamInspect,
  F : GleamInspect,
] GleamInspect for (A, B, C, D, E, F) with gleam_inspect(self) {
  "#(" +
  GleamInspect::gleam_inspect(self.0) +
  ", " +
  GleamInspect::gleam_inspect(self.1) +
  ", " +
  GleamInspect::gleam_inspect(self.2) +
  ", " +
  GleamInspect::gleam_inspect(self.3) +
  ", " +
  GleamInspect::gleam_inspect(self.4) +
  ", " +
  GleamInspect::gleam_inspect(self.5) +
  ")"
}

///|
pub impl[
  A : GleamInspect,
  B : GleamInspect,
  C : GleamInspect,
  D : GleamInspect,
  E : GleamInspect,
  F : GleamInspect,
  G : GleamInspect,
] GleamInspect for (A, B, C, D, E, F, G) with gleam_inspect(self) {
  "#(" +
  GleamInspect::gleam_inspect(self.0) +
  ", " +
  GleamInspect::gleam_inspect(self.1) +
  ", " +
  GleamInspect::gleam_inspect(self.2) +
  ", " +
  GleamInspect::gleam_inspect(self.3) +
  ", " +
  GleamInspect::gleam_inspect(self.4) +
  ", " +
  GleamInspect::gleam_inspect(self.5) +
  ", " +
  GleamInspect::gleam_inspect(self.6) +
  ")"
}

///|
pub impl[
  A : GleamInspect,
  B : GleamInspect,
  C : GleamInspect,
  D : GleamInspect,
  E : GleamInspect,
  F : GleamInspect,
  G : GleamInspect,
  H : GleamInspect,
] GleamInspect for (A, B, C, D, E, F, G, H) with gleam_inspect(self) {
  "#(" +
  GleamInspect::gleam_inspect(self.0) +
  ", " +
  GleamInspect::gleam_inspect(self.1) +
  ", " +
  GleamInspect::gleam_inspect(self.2) +
  ", " +
  GleamInspect::gleam_inspect(self.3) +
  ", " +
  GleamInspect::gleam_inspect(self.4) +
  ", " +
  GleamInspect::gleam_inspect(self.5) +
  ", " +
  GleamInspect::gleam_inspect(self.6) +
  ", " +
  GleamInspect::gleam_inspect(self.7) +
  ")"
}

///|
pub impl GleamInspect for Dynamic with gleam_inspect(self) {
  match self {
    DynNull => "Nil"
    DynBool(b) => GleamInspect::gleam_inspect(b)
    DynInt(i) => GleamInspect::gleam_inspect(i)
    DynFloat(f) => GleamInspect::gleam_inspect(f)
    DynString(s) => GleamInspect::gleam_inspect(s)
    DynBitArray(ba) => GleamInspect::gleam_inspect(ba)
    DynList(xs) => GleamInspect::gleam_inspect(xs)
    DynArray(arr) => {
      let buf = StringBuilder()
      buf.write_char('[')
      for i = 0; i < arr.length(); i = i + 1 {
        if i > 0 {
          buf.write_string(", ")
        }
        buf.write_string(GleamInspect::gleam_inspect(arr[i]))
      }
      buf.write_char(']')
      buf.to_string()
    }
    DynMap(m) => {
      let buf = StringBuilder()
      buf.write_string("dict.from_list([")
      let mut first = true
      m.each(fn(k, v) {
        if !first {
          buf.write_string(", ")
        }
        first = false
        buf.write_string("#(")
        buf.write_string(GleamInspect::gleam_inspect(k))
        buf.write_string(", ")
        buf.write_string(GleamInspect::gleam_inspect(v))
        buf.write_char(')')
      })
      buf.write_string("])")
      buf.to_string()
    }
  }
}

///|
/// Trait for converting Gleam values into `@gprelude.Dynamic`.
pub(open) trait ToDynamic {
  to_dynamic(Self) -> Dynamic
}

///|
pub impl ToDynamic for Dynamic with to_dynamic(self) {
  self
}

///|
pub impl ToDynamic for StringView with to_dynamic(self) {
  DynString(self)
}

///|
pub impl ToDynamic for String with to_dynamic(self) {
  DynString(self.to_string_view())
}

///|
pub impl ToDynamic for Int64 with to_dynamic(self) {
  DynInt(self)
}

///|
pub impl ToDynamic for Double with to_dynamic(self) {
  DynFloat(self)
}

///|
pub impl ToDynamic for Bool with to_dynamic(self) {
  DynBool(self)
}

///|
pub impl ToDynamic for Unit with to_dynamic(_) {
  DynNull
}

///|
pub impl ToDynamic for BitArray with to_dynamic(self) {
  DynBitArray(self)
}

///|
pub impl ToDynamic for Char with to_dynamic(self) {
  DynInt(self.to_int().to_int64())
}

///|
pub impl[T : ToDynamic] ToDynamic for Option[T] with to_dynamic(self) {
  match self {
    Some(v) => ToDynamic::to_dynamic(v)
    None => DynNull
  }
}

///|
pub impl[T : ToDynamic] ToDynamic for GList[T] with to_dynamic(self) {
  let rev = for cur = self, acc = (Nil : GList[Dynamic]) {
    match cur {
      Nil => break acc
      Cons(x, rest) => continue rest, Cons(ToDynamic::to_dynamic(x), acc)
    }
  }
  DynList(rev.reverse())
}

///|
pub impl ToDynamic for Tuple0 with to_dynamic(_) {
  DynArray([])
}

///|
pub impl[A : ToDynamic] ToDynamic for Tuple1[A] with to_dynamic(self) {
  DynArray([ToDynamic::to_dynamic(self.0)])
}

///|
pub impl[A : ToDynamic, B : ToDynamic] ToDynamic for (A, B) with to_dynamic(self) {
  DynArray([ToDynamic::to_dynamic(self.0), ToDynamic::to_dynamic(self.1)])
}

///|
pub impl[A : ToDynamic, B : ToDynamic, C : ToDynamic] ToDynamic for (A, B, C) with to_dynamic(
  self,
) {
  DynArray([
    ToDynamic::to_dynamic(self.0),
    ToDynamic::to_dynamic(self.1),
    ToDynamic::to_dynamic(self.2),
  ])
}

///|
pub impl[A : ToDynamic, B : ToDynamic, C : ToDynamic, D : ToDynamic] ToDynamic for (
  A,
  B,
  C,
  D,
) with to_dynamic(self) {
  DynArray([
    ToDynamic::to_dynamic(self.0),
    ToDynamic::to_dynamic(self.1),
    ToDynamic::to_dynamic(self.2),
    ToDynamic::to_dynamic(self.3),
  ])
}

///|
pub impl[
  A : ToDynamic,
  B : ToDynamic,
  C : ToDynamic,
  D : ToDynamic,
  E : ToDynamic,
] ToDynamic for (A, B, C, D, E) with to_dynamic(self) {
  DynArray([
    ToDynamic::to_dynamic(self.0),
    ToDynamic::to_dynamic(self.1),
    ToDynamic::to_dynamic(self.2),
    ToDynamic::to_dynamic(self.3),
    ToDynamic::to_dynamic(self.4),
  ])
}

///|
pub impl[
  A : ToDynamic,
  B : ToDynamic,
  C : ToDynamic,
  D : ToDynamic,
  E : ToDynamic,
  F : ToDynamic,
] ToDynamic for (A, B, C, D, E, F) with to_dynamic(self) {
  DynArray([
    ToDynamic::to_dynamic(self.0),
    ToDynamic::to_dynamic(self.1),
    ToDynamic::to_dynamic(self.2),
    ToDynamic::to_dynamic(self.3),
    ToDynamic::to_dynamic(self.4),
    ToDynamic::to_dynamic(self.5),
  ])
}

///|
pub impl[
  A : ToDynamic,
  B : ToDynamic,
  C : ToDynamic,
  D : ToDynamic,
  E : ToDynamic,
  F : ToDynamic,
  G : ToDynamic,
] ToDynamic for (A, B, C, D, E, F, G) with to_dynamic(self) {
  DynArray([
    ToDynamic::to_dynamic(self.0),
    ToDynamic::to_dynamic(self.1),
    ToDynamic::to_dynamic(self.2),
    ToDynamic::to_dynamic(self.3),
    ToDynamic::to_dynamic(self.4),
    ToDynamic::to_dynamic(self.5),
    ToDynamic::to_dynamic(self.6),
  ])
}

///|
pub impl[
  A : ToDynamic,
  B : ToDynamic,
  C : ToDynamic,
  D : ToDynamic,
  E : ToDynamic,
  F : ToDynamic,
  G : ToDynamic,
  H : ToDynamic,
] ToDynamic for (A, B, C, D, E, F, G, H) with to_dynamic(self) {
  DynArray([
    ToDynamic::to_dynamic(self.0),
    ToDynamic::to_dynamic(self.1),
    ToDynamic::to_dynamic(self.2),
    ToDynamic::to_dynamic(self.3),
    ToDynamic::to_dynamic(self.4),
    ToDynamic::to_dynamic(self.5),
    ToDynamic::to_dynamic(self.6),
    ToDynamic::to_dynamic(self.7),
  ])
}

///|
pub impl[T : ToDynamic, E : ToDynamic] ToDynamic for Result[T, E] with to_dynamic(
  self,
) {
  match self {
    Ok(v) => DynArray([DynString("ok"), ToDynamic::to_dynamic(v)])
    Err(e) => DynArray([DynString("error"), ToDynamic::to_dynamic(e)])
  }
}

///|
pub impl[K : ToDynamic, V : ToDynamic] ToDynamic for @immut_hashmap.HashMap[
  K,
  V,
] with to_dynamic(self) {
  let m : Map[Dynamic, Dynamic] = Map([])
  self.each(fn(k, v) { m[ToDynamic::to_dynamic(k)] = ToDynamic::to_dynamic(v) })
  DynMap(m)
}

///|
pub impl[K : GleamInspect, V : GleamInspect] GleamInspect for @immut_hashmap.HashMap[
  K,
  V,
] with gleam_inspect(self) {
  let entries : Array[(String, String)] = []
  self.each(fn(k, v) {
    entries.push(
      (GleamInspect::gleam_inspect(k), GleamInspect::gleam_inspect(v)),
    )
  })
  entries.sort_by(fn(a, b) { a.0.compare(b.0) })
  let buf = StringBuilder()
  buf.write_string("dict.from_list([")
  let mut first = true
  for entry in entries {
    if !first {
      buf.write_string(", ")
    }
    first = false
    buf.write_string("#(")
    buf.write_string(entry.0)
    buf.write_string(", ")
    buf.write_string(entry.1)
    buf.write_char(')')
  }
  buf.write_string("])")
  buf.to_string()
}

///|
pub fn[T : ToDynamic] to_dynamic(val : T) -> Dynamic {
  ToDynamic::to_dynamic(val)
}

///|
pub fn[T : GleamInspect] gleam_inspect(val : T) -> StringView {
  GleamInspect::gleam_inspect(val).to_string_view()
}

///|
pub fn[T : GleamInspect] echo_val(
  val : T,
  loc : StringView,
  msg : StringView,
) -> T {
  let header = if msg == "" { loc } else { loc + " " + msg }
  @prelude.eprintln(header)
  @prelude.eprintln(GleamInspect::gleam_inspect(val))
  val
}
