# `gekko` Authoring Guide

This guide walks through the five ways to build with `gekko`—from pure-Gleam apps to local MoonBit FFI, companion shims for Hex packages, and WebAssembly Components—and clears up where each file and configuration section belongs.

---

## 1. Which Mechanism Do I Use?

| Goal | Mechanism | Where Files Live |
| :--- | :--- | :--- |
| **Write a Gleam app** using existing shims (`gleam_stdlib`, `gleam_json`) | `[tools.gekko.use_shims]` in `gleam.toml` | `gleam.toml`, `src/` |
| **Call an existing MoonBit library** from Gleam | `moonbit/moon.mod` + `gekko moonbit bind <pkg>` | `moonbit/moon.mod`, `src/ffi/`, `moonbit/<pkg>_adapter/` |
| **Write custom MoonBit FFI** for your own project | `moonbit/<pkg>/` + `/// @external(moonbit, ...)` | `moonbit/<pkg>/`, `src/` |
| **Shim an unmodified Hex package** that has Erlang/JS externals | `[tools.gekko.shim_for]` + `/// @patch` / `/// @patch_type` + `internal/upstream/` *(or `patches/` escape hatch)* | `gleam.toml`, `src/<pkg>/` *(or `patches/<mod>/`)* |
| **Build a WebAssembly Component** (WASI Preview 2 / WIT host I/O) | `wit/*.wit` + `gekko wit gen` / `check` / `build` | `wit/`, `src/` |

> [!TIP]
> **Common Confusions Cleared Up**
> 1. **`moonbit/` vs `src/<pkg>/` shims vs `patches/`:**
>    Put *your own* standalone MoonBit FFI packages (or generated `gekko moonbit bind` adapters) in `moonbit/<pkg>/`. Put *Gleam shims* (`/// @patch`, `/// @patch_type`) for unmodified upstream Hex packages in `src/<pkg>/`, with auto-generated mirrors in `src/<pkg>/internal/upstream/`. Reserve `patches/<mod>/` (`#gekko.patch`) for the rare raw-MoonBit escape hatch.
> 2. **`[tools.gekko.use_shims]` vs `[tools.gekko.shim_for]`:**
>    - Applications **enable** shims in their root `gleam.toml` with `[tools.gekko.use_shims]` (`gleam_stdlib = "gekko_stdlib"`).
>    - Companion shim packages **declare which upstream package they patch** in their own `gleam.toml` with `[tools.gekko.shim_for]` (`package = "gleam_stdlib"`).
> 3. **`/// @external(moonbit, ...)` vs `@external(moonbit, ...)`:**
>    Always prefer the `/// @external(moonbit, ...)` doc-comment pragma with a Gleam fallback body (such as `panic as "Implemented in MoonBit"`). Standard `gleam check` ignores doc comments and stays 100% green, while `gekko` binds the function to MoonBit.
> 4. **`gekko test` vs `gleam test`:**
>    `gleam test` executes on Erlang/JS and cannot run MoonBit FFI code. Use `gekko test` to transpile and run your tests on MoonBit targets (`wasm`, `wasm-gc`, `js`, `native`).

---

## 2. Writing a Gleam Application

### Project Setup

Scaffold a new project with `gekko new`:

```bash
gekko new hello_gekko
cd hello_gekko
gekko run                  # auto-downloads deps, transpiles to MoonBit, and runs
gekko build --release      # emits portable WASI hello_gekko.wasm
```

In `gleam.toml`, depend on unmodified upstream Hex packages (`gleam_stdlib`, `gleam_json`, etc.) alongside their companion shim packages, and enable the shims in `[tools.gekko.use_shims]`:

```toml
name = "hello_gekko"
version = "0.1.0"

[dependencies]
gleam_stdlib = ">= 1.0.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
gekko_stdlib = { git = "https://github.com/spiral-nights/gekko_stdlib.git", ref = "main" }
gekko_json = { git = "https://github.com/spiral-nights/gekko_json.git", ref = "main" }

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"

[tools.gekko.use_shims]
gleam_stdlib = "gekko_stdlib"
gleam_json = "gekko_json"
```

### Choosing a Target & Running

`gekko` supports four MoonBit compilation targets via `--target`:

| Target | Command | Notes |
| :--- | :--- | :--- |
| **`wasm`** *(default)* | `gekko build --release` | Linear-memory WASI Preview 1 (`wasi_snapshot_preview1::fd_write`). Runs in `wasmtime`, `wasmer`, `wazero`, `moonrun`. |
| **`wasm-gc`** | `gekko build --target wasm-gc --release` | Compact WasmGC with no linear memory; stdout imports `spectest::print_char(i32)`. |
| **`js`** | `gekko build --target js` | JavaScript module output. |
| **`native`** | `gekko build --target native -o app.exe` | Native executable. |

Use `gekko test --target <target>` to run tests, and `gekko run -- <args>...` to forward CLI arguments to `main()`.

---

## 3. Calling MoonBit from Your Own Gleam Code (FFI)

### Option A: Bind an Existing MoonBit Package (`gekko moonbit bind`)

If you want to call a MoonBit standard-library or third-party registry package (like `moonbitlang/x/fs` or `moonbitlang/core/env`) without writing glue by hand:

1. Declare any third-party MoonBit dependency in `moonbit/moon.mod` (standard-library `moonbitlang/core/*` packages need no entry):

   ```moonbit
   // moonbit/moon.mod
   name = "file_io_mbt"
   version = "0.1.0"

   import {
     "moonbitlang/x@0.5.7",
   }
   ```

2. Generate Gleam stubs and any needed MoonBit adapter package:

   ```bash
   gekko moonbit bind moonbitlang/x/fs --module ffi/fs
   ```

   This writes:
   - `src/ffi/fs.gleam` — typed Gleam functions and `/// @external_type(moonbit, ...)` / `/// @external(moonbit, ...)` declarations.
   - `moonbit/fs_adapter/` — a small MoonBit adapter converting between MoonBit types (`Bytes`, `Array[T]`, `Int`) and `@gprelude` types (`BitArray`, `GList[T]`, `Int64`) where needed.

3. Import `ffi/fs` in your Gleam modules as usual.

### Option B: Write Custom Local MoonBit Code (`moonbit/<pkg>/`)

For custom MoonBit code, place packages under `<project_root>/moonbit/<pkg>/`:

```text
my_app/
├── gleam.toml
├── src/
│   └── my_app.gleam
└── moonbit/
    ├── moon.mod              # optional (needed for third-party deps & LSP)
    └── text_ffi/
        ├── moon.pkg          # optional (auto-generated if omitted)
        └── text_ffi.mbt
```

In `moonbit/text_ffi/text_ffi.mbt`:

```moonbit
///|
pub fn shout(s : String) -> String {
  s.to_upper() + "!"
}

///|
pub fn sum_squares(xs : @gprelude.GList[Int64]) -> Int64 {
  for cur = xs, acc = 0L {
    match cur {
      @gprelude.Nil => break acc
      @gprelude.Cons(h, t) => continue t, acc + h * h
    }
  }
}
```

In `src/my_app.gleam`, bind both local `moonbit/` functions and MoonBit standard-library functions directly with `/// @external(moonbit, "<pkg>", "<fn>")`:

```gleam
/// @external(moonbit, "text_ffi", "shout")
pub fn shout(s: String) -> String {
  let _ = s
  panic as "Implemented in MoonBit"
}

/// @external(moonbit, "text_ffi", "sum_squares")
pub fn sum_squares(xs: List(Int)) -> Int {
  let _ = xs
  panic as "Implemented in MoonBit"
}

/// @external(moonbit, "moonbitlang/core/math", "sin")
pub fn math_sin(x: Float) -> Float {
  let _ = x
  panic as "Implemented in MoonBit"
}
```

For opaque MoonBit types, pair `/// @external_type(moonbit, "<pkg>", "<Type>")` with your functions:

```gleam
/// @external_type(moonbit, "text_ffi", "Counter")
pub type Counter
```

### Enabling MoonBit LSP (`moon lsp`) for `moonbit/`

If you omit `moonbit/moon.mod` and `moon.pkg`, `gekko` generates them in `build/moonbit/`, which means your editor's MoonBit LSP won't see `@gprelude` while you edit `moonbit/<pkg>/*.mbt`.

To enable full MoonBit LSP autocomplete, type checking, and hover docs inside `moonbit/`:

1. Create `moonbit/moon.mod` (use a distinct module name such as `<project>_mbt`):

   ```moonbit
   // moonbit/moon.mod
   name = "my_app_mbt"
   version = "0.1.0"
   ```

2. Import `"<moon_mod_name>/gprelude" @gprelude` in `moonbit/<pkg>/moon.pkg`:

   ```moonbit
   // moonbit/text_ffi/moon.pkg
   import {
     "my_app_mbt/gprelude" @gprelude,
   }
   ```

3. Run `gekko check` (or `gekko moonbit bind`). `gekko` automatically materializes gitignored `moonbit/gprelude/` and writes a `moon.work` workspace file at your project root:

   ```moonbit
   // Generated by gekko for MoonBit LSP support
   members = [
     "moonbit",
   ]
   ```

   - Keep `build/`, `_build/`, `moonbit/gprelude/`, and `moon.work` in `.gitignore` (`gekko new` / `gekko init` add them automatically).
   - Hand-written `moon.work` files without the `// Generated by gekko` header are never overwritten.
   - When transpiling into `build/moonbit/`, `gekko` automatically rewrites `"<moon_mod_name>/gprelude"` imports to `"<project_name>/gprelude"`.

---

## 4. Writing a Shim for a Hex Package

Companion shims and local Gleam patches let you compile **unmodified upstream Hex packages** that contain `@external(erlang, ...)` / `@external(javascript, ...)` functions without forking them.

### Step 1: Inspect the Dependency

Inside a project that depends on the Hex package (after `gleam deps download`):

```bash
gekko shim inspect simplifile
```

`gekko` lists every unmapped `@external` function and every opaque external type.

### Step 2: Scaffold Gleam Shims (Recommended)

By default, `gekko shim` generates Gleam `/// @patch(...)` stubs so you get full Gleam LSP support, `gleam check`, and `gekko moonbit bind` without writing raw MoonBit:

```bash
# In your own app, scaffold stubs for one module or declaration in src/<app>/shims/:
gekko moonbit bind moonbitlang/x/fs --module ffi/fs
gekko shim patch --module simplifile
gekko shim patch filepath:filepath.is_windows

# Or scaffold a standalone companion shim repository:
gekko shim new simplifile --out ../gekko_simplifile
```

Inside a companion shim repo (which declares `[tools.gekko.shim_for] package = "simplifile"` in `gleam.toml`), `gekko shim init` and `gekko shim patch` write `/// @patch("simplifile.fn")` stubs directly into `src/<shim_name>/`.

*(Pass `--moonbit` to `new`, `init`, or `patch` only when you need low-level MoonBit `patches/` files—for example custom MoonBit trait `impl`s, replacing variant-bearing ADTs, or tight mutable loops.)*

### Step 3: Implement `/// @patch(...)` and `/// @patch_type(...)` in Gleam

```gleam
// src/my_app/shims/simplifile.gleam
import ffi/fs
import simplifile.{type FileError, Unknown}

/// @patch("simplifile:simplifile.read_bits")
pub fn read_bits(filepath: String) -> Result(BitArray, FileError) {
  case fs.read_file_to_bytes(filepath) {
    Ok(bytes) -> Ok(bytes)
    Error(err) -> Error(Unknown(fs.io_error_to_string(err)))
  }
}
```

- **Zero-variant external types (`/// @patch_type`):** Implement upstream zero-variant types (public or private, e.g. `TransientDict` or external handles) in pure Gleam using an alias (`pub type Handle = ffi.Stat`) or a Gleam custom type (`pub type Handle { Handle(id: Int) }`) annotated with `/// @patch_type("pkg:mod.Type")`.
- **Private types, helpers & `pub opaque` internals (`internal/upstream/`):** When an upstream module contains private types, private functions/constants, or `pub opaque` types with constructors, `gekko shim` generates a `//// @patch_mirror(...)` mirror at `src/<pkg>/internal/upstream/<mod>.gleam`. Import it `as upstream` to match/construct private or opaque variants (`upstream.Token(...)`), call private helpers, or cross into upstream public functions with zero-cost `upstream.to_<type>` / `upstream.from_<type>` bridges.
- **Syncing mirrors:** If an upstream upgrade changes mirrored private or opaque declarations, `gekko` reports a clear drift error; run `gekko shim sync` to regenerate the `internal/upstream/` mirrors in place.

When transpiling, `gekko` checks that each `/// @patch(...)` signature matches the upstream function, validates mirrors against upstream IR, erases `to_`/`from_` bridges and mirror modules completely, and splices lowered bodies directly into the upstream module's MoonBit package—avoiding circular package imports while keeping `gleam check` green.

If you need raw MoonBit overrides (`patches/<mod>/<file>.mbt` + `#gekko.patch`), see **[`docs/SHIMS.md`](./SHIMS.md)**.

### Step 3b: Raw MoonBit Escape Hatch (`--moonbit`)

For low-level MoonBit patches, `[tools.gekko.shim_for]` scopes a companion repo in `gleam.toml`:

```toml
[tools.gekko.shim_for]
package = "simplifile"
version = ">= 2.0.0 and < 3.0.0"
```

In `patches/<mod>/<file>.mbt`, annotate every patched type, type alias, or function with `#gekko.patch` (helper functions without `#gekko.patch` stay private to the patch):

```moonbit
// patches/simplifile/moon.pkg
import {
  "moonbitlang/x/fs",
}
```

```moonbit
// patches/simplifile/simplifile.mbt
///|
#gekko.patch
pub(all) struct FileInfo {
  size : Int64
}

///|
#gekko.patch
pub fn read(filepath : String) -> Result[String, FileError] {
  ... // constructs upstream FileError variants directly!
}

// Map a Gleam identifier that collides with a MoonBit keyword:
///|
#gekko.patch("println")
pub fn println_(message : String) -> Unit {
  println(message)
}

// Map an upstream opaque type directly to a MoonBit type:
///|
#gekko.patch
pub type Dynamic = @gprelude.Dynamic

// Or re-export a built-in MoonBit type (such as reserved `Option`):
///|
#gekko.patch
pub using @prelude { type Option }
```

Because `patches/<mod>/*.mbt` files are copied directly into the transpiled module's MoonBit package, patches have direct access to same-module Gleam error enums and private helpers with zero circular package dependencies.

### Step 4: Enable the Shim in Your App

Dependencies can never silently patch another package. To use a companion shim in an application, depend on both packages and explicitly enable the shim under `[tools.gekko.use_shims]` in your **root** `gleam.toml`:

```toml
[dependencies]
simplifile = ">= 2.0.0 and < 3.0.0"
gekko_simplifile = { git = "https://github.com/...", ref = "main" }

[tools.gekko.use_shims]
simplifile = "gekko_simplifile"
```

### Step 5: Test Against Upstream

Run `gekko test` in your shim package (and optionally test against upstream's own test suite in CI). `gekko` emits zero-cost `__gekko_sigcheck_<fn>` wrappers so `moon check` catches any upstream signature mismatch immediately.

For `[tools.gekko.target_branch]`, precedence rules, and legacy options, see **[`docs/SHIMS.md`](./SHIMS.md)**.

---

## 5. Building a WebAssembly Component (`gekko wit`)

Use `gekko wit` when you want a **WASI Preview 2 / Component Model** `.wasm` component driven by a `.wit` interface (`wit/*.wit`):

1. **Generate Gleam bindings & stubs:**
   ```bash
   gekko wit gen
   ```
   - `src/wit/*.gleam` — auto-regenerated WIT types and import bindings (**do not edit**).
   - `src/<iface>.gleam` (or `src/<world>.gleam`) — starter `todo` stubs for exported functions (**safe to edit**; never overwritten on subsequent `gekko wit gen` runs).
2. **Implement your exports** in `src/<iface>.gleam`, then type-check:
   ```bash
   gekko wit check
   ```
3. **Bundle the component** and run it with `wasmtime`:
   ```bash
   gekko wit build --release   # outputs dist/<world>.wasm
   wasm-tools component wit dist/<world>.wasm
   ```

> [!NOTE]
> MoonBit OS packages like `moonbitlang/x/fs` and `moonbitlang/core/env` emit MoonBit-specific Wasm host imports that require `moonrun` on Wasm targets. If you want portable host I/O on Wasm runtimes like `wasmtime`, use `gekko wit` (or target `native` / `js`).

---

## 6. Gleam ↔ MoonBit Type & `@gprelude` Cheat Sheet

| Gleam Type | MoonBit Type | Notes & Common Helpers |
| :--- | :--- | :--- |
| `Int` | `Int64` | Signed 64-bit integer (`0L`, `1L`). Wrapping overflow. |
| `Float` | `Double` | IEEE-754 64-bit float (`1.5`). |
| `Bool` | `Bool` | `true` / `false`. |
| `String` | `String` | UTF-16 MoonBit `String`. |
| `Nil` | `Unit` | `()`. |
| `UtfCodepoint` | `Char` | Built-in MoonBit Unicode scalar (`ch.to_int()`, `n.unsafe_to_char()`). |
| `List(a)` | `@gprelude.GList[A]` | `Nil` \| `Cons(A, GList[A])`; `xs.to_array()`, `GList::from_array(arr[:])`. |
| `BitArray` | `@gprelude.BitArray` | `BitArray::empty()`, `from_bytes(b)`, `from_string(s)`, `concat(parts[:])`. |
| `Result(a, b)` | `Result[A, B]` | `Ok(a)` \| `Err(b)`. |
| `Option(a)` | `Option[A]` | `Some(a)` \| `None` (built-in default for `gleam_stdlib`). |
| `Dynamic` | `@gprelude.Dynamic` | `DynNull`, `DynBool`, `DynInt`, `DynFloat`, `DynString`, `DynBitArray`, `DynList`, `DynArray`, `DynMap`, `ToDynamic::to_dynamic`. |
| `#()`, `#(a)` | `@gprelude.Tuple0`, `@gprelude.Tuple1[A]` | Boxed 0-tuple and 1-tuple wrappers. |
| `#(a, b, ...)` | `(A, B, ...)` | Native MoonBit tuples (2+ elements). |
| Custom `type` | `pub(all) enum` | Every Gleam custom type lowers to a MoonBit `enum` with `.field()` getters. |

For detailed runtime behavior and documented differences from Erlang/JS Gleam, see **[`docs/SEMANTICS.md`](./SEMANTICS.md)**.

---

## 7. Common Pitfalls & Troubleshooting

- **`Security error: dependency '...' declares [tools.gekko.shim_for] for '...', but is not enabled in root gleam.toml`:**
  Add the `[tools.gekko.use_shims]` mapping to your root `gleam.toml` (for example `gleam_stdlib = "gekko_stdlib"`).
- **`Unmapped external function` error on a Hex dependency:**
  The dependency has an `@external(erlang, ...)` / `@external(javascript, ...)` without a pure-Gleam fallback body. Run `gekko shim inspect <pkg>` and `gekko shim init <pkg>` to create a companion shim.
- **`gleam check` fails on `@external(moonbit, ...)`:**
  Use doc-comment syntax (`/// @external(moonbit, "pkg", "fn")`) with a valid Gleam fallback body instead of bare `@external(moonbit, ...)`.
- **`gleam test` panics with `"Implemented in MoonBit"`:**
  Standard `gleam test` runs on Erlang/JS. Run `gekko test` to execute tests on MoonBit targets.
- **`Invalid project name '...': must not end with '_test'`:**
  Gleam reserves `*_test` names; never name a project `foo_test`.
