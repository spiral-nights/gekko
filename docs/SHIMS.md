# Companion Shim & Overlay Packages (`gekko`)

> [!TIP]
> New to `gekko` or writing your first shim? Start with the step-by-step walkthrough in **[`docs/GUIDE.md`](./GUIDE.md)**. This document is the full companion-shim reference.

`gekko` lets you compile **unmodified upstream Hex packages** to MoonBit and WebAssembly by pairing them with a **companion shim (overlay) package**—without maintaining a source fork or fragile line-based diffs.

---

## Why Co-Located Module Patches (`patches/` + `#gekko.patch`)?

Most Gleam libraries are 90–99% pure Gleam with a small pocket of `@external(erlang, ...)` / `@external(javascript, ...)` functions and opaque external types.

In MoonBit, every directory is a package, and MoonBit forbids circular package imports (`pkg_a` $\leftrightarrow$ `pkg_b`). Because Gleam modules often define error enums (like `DecodeError`) in the *same* module as their `@external` functions, putting FFI in a separate MoonBit package creates circular dependencies.

**`gekko` solves this by placing each module's MoonBit patch directly inside that module's own transpiled MoonBit package:**

```text
gekko_json/                # companion shim package
├── gleam.toml             # [tools.gekko.shim_for] + [tools.gekko.patches."..."] imports
├── src/
│   └── gekko_json.gleam
└── patches/               # co-located .mbt files mirroring upstream modules
    └── gleam/
        └── json/
            └── json.mbt   # #gekko.patch-annotated MoonBit implementations
```

Because Gleam already forbids circular imports between `.gleam` modules, co-located module patches keep MoonBit's package graph **100% acyclic**—with zero `__shim_` prefixes, zero extra packages, and direct access to same-module error enums and private helpers.

In your application's `gleam.toml`, depend on **both** the unmodified upstream library and its companion shim, and explicitly enable the shim in `[tools.gekko.use_shims]`:

```toml
[dependencies]
gleam_json = ">= 3.0.0 and < 4.0.0"
gekko_json = { git = "https://github.com/...", ref = "main" }

[tools.gekko.use_shims]
gleam_json = "gekko_json"
```

- `gleam check` and `gleam test` (BEAM/JS) ignore `[tools.gekko.*]` and `patches/`, so standard Gleam tooling continues working untouched.
- **Root-only authorization:** Dependencies can never silently patch another package. Only shims explicitly listed under `[tools.gekko.use_shims]` in your **root** `gleam.toml` are permitted to apply patches.

---

## Configuration Reference

Package-level shim metadata lives under **`[tools.gekko.*]` in `gleam.toml`**.

### 1. `[tools.gekko.use_shims]` *(Root `gleam.toml`)* & `[tools.gekko.shim_for]` *(Shim `gleam.toml`)*

Your **root** `gleam.toml` enables and authorizes which shim package may patch each target dependency:

```toml
[tools.gekko.use_shims]
gleam_stdlib = "gekko_stdlib"
gleam_json = "gekko_json"
```

And the **shim** package's `gleam.toml` declares which upstream package it targets and the SemVer range it was written against:

```toml
[tools.gekko.shim_for]
package = "gleam_json"
version = ">= 3.0.0 and < 4.0.0"
```

Supported SemVer constraint operators: `>=`, `<=`, `>`, `<`, `==`, `!=`, `~>`, `^`, and compound clauses joined by `and` (or `&&` / `,`). If the resolved version of `package` in `manifest.toml` does not satisfy `version` (or `package` is not a dependency), `gekko` emits a clear warning.

**Security Confinement:**
1. Any dependency package that ships `patches/` or `[tools.gekko.*]` overrides **must** declare `[tools.gekko.shim_for] package = "<pkg>"` in its `gleam.toml`.
2. That dependency is **only** permitted if the root `gleam.toml` explicitly enables `<pkg> = "<shim_pkg>"` in `[tools.gekko.use_shims]`, and every patched/overridden symbol must belong to `<pkg>`.
3. If an unexpected or transitive dependency attempts to patch any package without root authorization, compilation fails immediately with a security error. (Root projects may override any dependency without `[tools.gekko.use_shims]`.)

---

### 2. `patches/` + `#gekko.patch` — Co-Located Module Patches *(Primary Mechanism)*

`gekko` discovers `.mbt` files under `<pkg_root>/patches/<mod>/` (package-directory layout only; single-file `patches/<mod>.mbt` patches are retired — use `gekko shim migrate`).

Running `gekko check`, `gekko build`, or `gekko test` mirrors the full MoonBit module graph into `patches/` (`patches/moon.mod`, `patches/gprelude/`, generated `patches/**/moon.pkg`, and generated `patches/**/*.g.mbt`) and writes `moon.work` at the project root so MoonBit LSP and `moon check` work directly inside `patches/`. Extra MoonBit imports for a patched module are declared in `gleam.toml`:

```toml
[tools.gekko.patches."gleam/json"]
imports = [
  "moonbitlang/core/json",
  "moonbitlang/core/string @str",
]
```

Inside `patches/<mod>/<file>.mbt`, annotate every patched type or function with `#gekko.patch`:

```moonbit
// patches/gleam/json/json.mbt
///|
#gekko.patch
#derive(Eq, Debug)
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

- **`#gekko.patch`:** Maps the MoonBit declaration to the same-named Gleam type, type alias, or function in the module. Annotating a MoonBit type alias (`pub type Dynamic = @gprelude.Dynamic` or `pub using @prelude { type Option }` for reserved built-ins) automatically maps the upstream Gleam type to that MoonBit target without TOML configuration.
- **`#gekko.patch("gleam_name")`:** Maps to a different Gleam identifier (e.g. `#gekko.patch("println")` on `pub fn println_` when a Gleam name is a MoonBit keyword), or to an explicit `"mod.sym"` / `"pkg:mod.sym"` target.
- **`imports` (`[tools.gekko.patches."<mod>"]`):** `@gprelude` and upstream Gleam module imports are merged automatically into the generated `patches/<mod>/moon.pkg`.
- **Guards:** Unmatched patches/overrides, visibility or arity mismatches, and upstream type drift (compared against `patches/.gekko_baseline/`) fail compilation with errors pointing at `patches/...:line`. Use `gekko check --strict` to fail on any unimplemented `@external` function.

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
2. **Dependency shims** (`[tools.gekko.*]` in `gleam.toml` and `#gekko.patch` in `patches/`) — strictly confined to the declared `[tools.gekko.shim_for] package`; if two dependency shims define *different* overrides for the same key, `gekko` fails with an error naming both shims.
3. **Root project `gleam.toml`** (`[tools.gekko.*]`) / `patches/` — overrides dependency shims (and resolves conflicts between two dependency shims).

---

## CLI Workflow (`gekko shim`)

Use `gekko shim` to create, scaffold, inspect, migrate, and acknowledge companion shims:

```bash
# 1. Create a brand-new companion shim repository for a Hex dependency
gekko shim new simplifile --out ../gekko_simplifile

# 2. Inside a shim repository, scaffold all missing externals or one module/decl
gekko shim init
gekko shim patch --module simplifile
gekko shim patch simplifile.read_bits

# 3. Inspect patch coverage, unmatched entries, missing externals, and type drift
gekko shim inspect

# 4. Acknowledge reviewed upstream type changes in patches/.gekko_baseline/
gekko shim ack

# 5. Migrate legacy single-file patches & moon.pkg files into gleam.toml
gekko shim migrate
```

`gekko shim patch` is additive and idempotent: it appends `#gekko.patch` stubs matching upstream's exact lowered MoonBit signatures without altering existing declarations.

---

## Upgradability & Maintainability Best Practices

1. **Override at the right boundary:**
   - For libraries with a small, stable `@external` leaf layer, patch the leaf `@external` functions so you inherit all upstream pure-Gleam logic and bugfixes automatically.
   - For libraries wrapping churning Erlang/JS internals behind a stable public API, patch at the **public SemVer API**—`gekko` automatically prunes unreachable private `@external` helpers.
2. **Rely on MoonBit's type checker & baselines:** `gekko` emits `__gekko_sigcheck_<fn>` wrappers (remapped back to `patches/...:line`) and checks `patches/.gekko_baseline/` against upstream `IrTypeDef`s. If an upstream upgrade changes a signature or type, `gekko check` / `moon check` catches it immediately.
3. **Use `--strict` and `gekko shim inspect`:** `gekko check --strict` fails on any remaining `@external` function backed only by a `panic`/`todo` stub, and unmatched patch/override keys fail compilation immediately.
4. **Test against upstream's test suite in CI:** Run `gekko test` against the upstream package's tests in your shim repository's CI so upstream upgrades are a version bump + `gekko test`.
