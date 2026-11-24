# Companion Shim & Overlay Packages (`gekko`)

`gekko` lets you compile **unmodified upstream Hex packages** to MoonBit and WebAssembly by pairing them with a **companion shim (overlay) package**—without maintaining a source fork or fragile line-based diffs.

---

## Why Co-Located Module Patches (`patches/` + `#gekko.patch`)?

Most Gleam libraries are 90–99% pure Gleam with a small pocket of `@external(erlang, ...)` / `@external(javascript, ...)` functions and opaque external types.

In MoonBit, every directory is a package, and MoonBit forbids circular package imports (`pkg_a` $\leftrightarrow$ `pkg_b`). Because Gleam modules often define error enums (like `DecodeError`) in the *same* module as their `@external` functions, putting FFI in a separate MoonBit package creates circular dependencies.

**`gekko` solves this by placing each module's MoonBit patch directly inside that module's own transpiled MoonBit package:**

```text
gekko_json/                # companion shim package
├── gleam.toml             # [tools.gekko.shim] metadata + normal Gleam deps
├── src/
│   └── gekko_json.gleam
└── patches/               # co-located .mbt files mirroring upstream modules
    └── gleam/
        └── json/
            ├── moon.pkg   # standard MoonBit imports for this patch
            └── json.mbt   # #gekko.patch-annotated MoonBit implementations
```

Because Gleam already forbids circular imports between `.gleam` modules, co-located module patches keep MoonBit's package graph **100% acyclic**—with zero `__shim_` prefixes, zero extra packages, and direct access to same-module error enums and private helpers.

In your application's `gleam.toml`, depend on **both** the unmodified upstream library and its companion shim, and explicitly authorize the shim in `[tools.gekko.shims]`:

```toml
[dependencies]
gleam_json = ">= 3.0.0 and < 4.0.0"
gekko_json = { git = "https://github.com/...", ref = "main" }

[tools.gekko.shims]
gleam_json = "gekko_json"
```

- `gleam check` and `gleam test` (BEAM/JS) ignore `[tools.gekko.*]` and `patches/`, so standard Gleam tooling continues working untouched.
- **Root-only authorization:** Dependencies can never silently patch another package. Only shims explicitly listed under `[tools.gekko.shims]` in your **root** `gleam.toml` are permitted to apply patches.

---

## Configuration Reference

Package-level shim metadata lives under **`[tools.gekko.*]` in `gleam.toml`**.

### 1. `[tools.gekko.shims]` *(Root `gleam.toml`)* & `[tools.gekko.shim]` *(Shim `gleam.toml`)*

Your **root** `gleam.toml` authorizes which shim package may patch each target dependency:

```toml
[tools.gekko.shims]
gleam_stdlib = "gekko_stdlib"
gleam_json = "gekko_json"
```

And the **shim** package's `gleam.toml` declares which upstream package it targets and the SemVer range it was written against:

```toml
[tools.gekko.shim]
target = "gleam_json"
version = ">= 3.0.0 and < 4.0.0"
```

Supported SemVer constraint operators: `>=`, `<=`, `>`, `<`, `==`, `!=`, `~>`, `^`, and compound clauses joined by `and` (or `&&` / `,`). If the resolved version of `target` in `manifest.toml` does not satisfy `version` (or `target` is not a dependency), `gekko` emits a clear warning.

**Security Confinement:**
1. Any dependency package that ships `patches/` or `[tools.gekko.*]` overrides **must** declare `[tools.gekko.shim] target = "<pkg>"` in its `gleam.toml`.
2. That dependency is **only** permitted if the root `gleam.toml` explicitly authorizes `<pkg> = "<shim_pkg>"` in `[tools.gekko.shims]`, and every patched/overridden symbol must belong to `<pkg>`.
3. If an unexpected or transitive dependency attempts to patch any package without root authorization, compilation fails immediately with a security error. (Root projects may override any dependency without `[tools.gekko.shims]`.)

---

### 2. `patches/` + `#gekko.patch` — Co-Located Module Patches *(Primary Mechanism)*

`gekko` automatically discovers `.mbt` files under `<pkg_root>/patches/` in two layouts:

- **Package-directory layout (`patches/<mod>/moon.pkg` + `*.mbt`):** Used whenever a patch needs extra MoonBit imports. All direct `.mbt` files in that directory are copied into the transpiled module's package (`build/moonbit/<mod>/`), and `moon.pkg`'s `import { ... }` entries are merged automatically.
- **Single-file layout (`patches/<mod>.mbt`):** Used when no extra imports beyond `@gprelude` and same-module types are needed.

Inside a patch `.mbt` file, annotate every patched type or function with `#gekko.patch`:

```moonbit
// patches/gleam/json/moon.pkg
import {
  "moonbitlang/core/json",
  "moonbitlang/core/string" @str,
}
```

```moonbit
// patches/gleam/json/json.mbt
///|
#gekko.patch
pub(all) struct Json {
  raw : @json.Json
}

///|
#gekko.patch
fn decode_string(a : String) -> Result[@gprelude.Dynamic, DecodeError] {
  ... // constructs UnexpectedEndOfInput / UnexpectedByte directly
}

///|
#gekko.patch
pub fn to_string_tree(json : Json) -> @string_tree.StringTree {
  @string_tree.from_string(do_to_string(json))
}

// No #gekko.patch -> private helper, never treated as an upstream override
fn json_to_dynamic(j : @json.Json) -> @gprelude.Dynamic { ... }
```

- **`#gekko.patch`:** Maps the MoonBit declaration to the same-named Gleam type, type alias, or function in the module. Annotating a MoonBit type alias (`pub type Dynamic = @gprelude.Dynamic` or `pub type Option[T] = @prelude.Option[T]`) automatically maps the upstream Gleam type to that MoonBit target without TOML configuration.
- **`#gekko.patch("gleam_name")`:** Maps to a different Gleam identifier (e.g. `#gekko.patch("println")` on `pub fn println_` when a Gleam name is a MoonBit keyword), or to an explicit `"mod.sym"` / `"pkg:mod.sym"` target.
- **`imports` (`moon.pkg`):** `@gprelude` is imported automatically. Any package already imported by the upstream Gleam module is deduplicated automatically.
- **Signature checks:** `gekko` emits zero-cost compile-time signature checks (`__gekko_sigcheck_<fn>`) so upstream type changes are caught immediately by `moon check`. Functions marked `pub` in Gleam must be `pub` in the `.mbt` patch file.

---

### 3. `[tools.gekko.target_branch."..."]` — Selecting `@target(javascript)` vs `@target(erlang)`

By default, `gekko` keeps `@target(erlang)` definitions and drops `@target(javascript)` definitions. When an upstream module has a pure-Gleam (or simpler) `@target(javascript)` branch, switch it per module or package:

```toml
[tools.gekko.target_branch."some_pkg:some/module"]
prefer = "javascript"   # "erlang" (default) | "javascript"
```

---

### 4. `[tools.gekko.moonbit.deps]` & `moonbit/<pkg>/` Packages

Shims can declare MoonBit registry dependencies in `moonbit/moon.mod` or `[tools.gekko.moonbit.deps]` in `gleam.toml`. If a shim also ships standalone `moonbit/<pkg>/` helper packages, `gekko` automatically rewrites `"<shim_pkg>/..."` imports in `moon.pkg` to `"<root_project>/..."`.

---

## Gleam ↔ MoonBit FFI & `@gprelude` Type Reference

| Gleam Type | MoonBit Type | Notes / Common Helpers |
| --- | --- | --- |
| `Int` | `Int64` | Signed 64-bit integer (`0L` literals) |
| `Float` | `Double` | IEEE-754 64-bit float |
| `Bool` | `Bool` | `true` / `false` |
| `String` | `String` | UTF-16 MoonBit `String` |
| `Nil` | `Unit` | `()` |
| `UtfCodepoint` | `Char` | Built-in MoonBit Unicode scalar (`ch.to_int()`, `n.unsafe_to_char()`) |
| `List(a)` | `@gprelude.GList[A]` | `Nil` \| `Cons(A, GList[A])`, `GList::from_array`, `GList::to_array` |
| `BitArray` | `@gprelude.BitArray` | `{ data: Bytes, bit_length: Int64 }`, `BitArray::empty`, `from_bytes`, `from_string`, `concat` |
| `Result(a, b)` | `Result[A, B]` | `Ok(a)` \| `Err(b)` |
| `Option(a)` | `Option[A]` | `Some(a)` \| `None` (via `gleam_stdlib` type override) |
| `Dynamic` | `@gprelude.Dynamic` | `DynNull`, `DynBool`, `DynInt`, `DynFloat`, `DynString`, `DynBitArray`, `DynList`, `DynArray`, `DynMap` |
| `#()`, `#(a)` | `@gprelude.Tuple0`, `@gprelude.Tuple1[A]` | Boxed 0-tuple and 1-tuple wrappers |
| `#(a, b, ...)` | `(A, B, ...)` | Native MoonBit tuples (2+ elements) |

---

## Precedence & Conflict Resolution

1. **Upstream source pragmas** (`/// @external(moonbit, ...)` / `/// @external_type(moonbit, ...)`) — lowest precedence.
2. **Dependency shims** (`[tools.gekko.*]` in `gleam.toml` and `#gekko.patch` in `patches/`) — strictly confined to the declared `[tools.gekko.shim] target`; if two dependency shims define *different* overrides for the same key, `gekko` fails with an error naming both shims.
3. **Root project `gleam.toml`** (`[tools.gekko.*]`) / `patches/` — overrides dependency shims (and resolves conflicts between two dependency shims).

---

## CLI Workflow (`gekko shim`)

Use `gekko shim inspect` and `gekko shim init` to audit any Hex dependency and scaffold a typed companion shim:

```bash
# 1. Inspect a resolved dependency for unmapped externals and opaque types
gekko shim inspect simplifile

# 2. Scaffold a starter companion shim package (defaults to ./gekko_<pkg>)
gekko shim init simplifile
gekko shim init simplifile --out ../gekko_simplifile
```

`gekko shim init` generates `gleam.toml` (with `[tools.gekko.shim]`) and `patches/<mod>/` (`moon.pkg` + `#gekko.patch`-annotated `.mbt` stubs matching upstream's exact lowered MoonBit signatures).

---

## Upgradability & Maintainability Best Practices

1. **Override at the right boundary:**
   - For libraries with a small, stable `@external` leaf layer, patch the leaf `@external` functions so you inherit all upstream pure-Gleam logic and bugfixes automatically.
   - For libraries wrapping churning Erlang/JS internals behind a stable public API, patch at the **public SemVer API**—`gekko` automatically prunes unreachable private `@external` helpers.
2. **Rely on MoonBit's type checker:** `gekko` emits `__gekko_sigcheck_<fn>` wrappers from upstream's `gleam export package-interface`. If an upstream upgrade changes a parameter, return type, or error variant, `moon check` catches it immediately at compile time.
3. **Heed stale-override and version warnings:** When an upstream upgrade renames or removes an overridden function, type, or module, `gekko` warns about the unmatched key so dead shim code doesn't accumulate silently.
4. **Test against upstream's test suite in CI:** Run `gekko test` against the upstream package's tests in your shim repository's CI so upstream upgrades are a version bump + `gekko test`.
