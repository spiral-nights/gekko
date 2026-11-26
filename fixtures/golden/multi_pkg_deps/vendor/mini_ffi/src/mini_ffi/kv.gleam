import mini_ffi/option.{type Option, None, Some}

/// @external_type(moonbit, "mini_ffi_mbt", "MiniMap")
pub type MiniMap(k, v)

/// @external(moonbit, "mini_ffi_mbt", "map_new")
pub fn new() -> MiniMap(k, v) {
  panic as "Implemented in MoonBit"
}

/// @external(moonbit, "mini_ffi_mbt", "map_insert")
pub fn insert(
  into map: MiniMap(k, v),
  for key: k,
  insert value: v,
) -> MiniMap(k, v) {
  let _ = #(map, key, value)
  panic as "Implemented in MoonBit"
}

/// @external(moonbit, "mini_ffi_mbt", "map_get")
pub fn get(from map: MiniMap(k, v), get key: k) -> Result(v, Nil) {
  let _ = #(map, key)
  panic as "Implemented in MoonBit"
}

/// @external(moonbit, "mini_ffi_mbt", "map_fold")
pub fn fold(
  over map: MiniMap(k, v),
  from initial: acc,
  with fun: fn(acc, k, v) -> acc,
) -> acc {
  let _ = #(map, initial, fun)
  panic as "Implemented in MoonBit"
}

pub fn upsert(
  in map: MiniMap(k, v),
  update key: k,
  with fun: fn(Option(v)) -> v,
) -> MiniMap(k, v) {
  case get(from: map, get: key) {
    Ok(val) -> insert(into: map, for: key, insert: fun(Some(val)))
    Error(Nil) -> insert(into: map, for: key, insert: fun(None))
  }
}
