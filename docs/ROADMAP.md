# `gekko` Implementation Roadmap

This roadmap organizes the build-out of `gekko` into six sequential, test-gated phases. Each phase builds on the verified outputs of the previous phase.

---

## Phase 1: Project Scaffold, Shadow `pub` Interface Extractor, Pre-Pass & Symbol Indexer *(Completed)*

**Goal:** Parse any multi-module Gleam project (including FFI pragmas and private functions) and construct a complete, type-resolved Global Symbol Table.

### Deliverables
- [x] Initialize the `gekko` Gleam package (`gleam.toml` with `glance`, `simplifile`, `filepath`, `tom`, `gleam_json`, `argv`, and `gleeunit`).
- [x] **`src/project/prepass.gleam`**: Extract `/// @external(moonbit, ...)` / `/// @external_type(moonbit, ...)` pragmas and strip raw attributes while preserving line numbers.
- [x] **`src/project/ffi_config.gleam`**: Parse `gekko.toml`, `[tools.gekko.overrides]` in `gleam.toml`, and `moonbit/moon.mod`.
- [x] **`src/project/staging.gleam` & `src/project/interface.gleam`**: Stage shadow copies promoting private declarations to `pub` (cached by SHA-256 fingerprint) and decode `gleam export package-interface`.
- [x] **`src/index/symbol_table.gleam`**: Index modules, import aliases, custom type variants, shared fields, `has_function_field` flags, function arities, and labeled argument ordering.

### Verification Gate
- `gleam test` passes unit tests verifying FFI pragma extraction, shadow `pub` staging + `package-interface` decoding, and symbol indexing on multi-module Gleam fixtures with private functions, labeled arguments, and shared-field custom types.

---

## Phase 2: AST Lowering (Desugar, Functional `for` TCO, Uniform Enums & Uniform Getters)

**Goal:** Transform `glance` AST nodes + Symbol Table metadata into a clean, MoonBit-ready intermediate representation (IR).

### Deliverables
- **`src/lower/desugar.gleam`**:
  - Fold `use` statements right-to-left into trailing anonymous callbacks.
  - Lower `let assert pat = expr` to `guard` + `abort(...)`; lower `todo` and `panic` to `abort(...)`.
  - Lower `FnCapture` (`f(a, _, c)`) into anonymous functions.
  - Lower pipelines (`|>`) using Symbol Table function arities and labeled positions.
  - Lower `FieldAccess(expr, label)` unconditionally to method getter calls via the Uniform Getter Rule (distinguishing module access `mod.fn` via import lookup).
  - Lower `RecordUpdate` (`Variant(..r, field: val)`) using Symbol Table variant field lists into exhaustive/guarded `match` reconstructions.
- **`src/lower/tco.gleam`**:
  - Detect direct self-tail-recursive calls in function bodies and transform them into functional `for` state-loop IR (`for p = p { ... => continue ... / break ... }`).
- **`src/lower/pattern.gleam` & `src/lower/mangle.gleam`**:
  - Lower list patterns (`[]`, `[x, ..rest]`), string prefix patterns (`"pre" <> rest`), and Tier 1 byte-aligned bit-array patterns.
  - Escape MoonBit reserved keywords (`match` $\rightarrow$ `match_`, etc.) and capitalize generic type variables (`a` $\rightarrow$ `T_a` / `A`).

### Verification Gate
- Unit tests verify lowered IR trees across `use` chains, nested pipelines, `let assert`, self-tail-recursive loops, uniform field getters, and multi-variant record updates.

---

## Phase 3: Modern MoonBit Emitter (`moon.mod` / `moon.pkg` / `.mbt`) & Core `@prelude` Runtime

**Goal:** Emit valid, idiomatic modern MoonBit workspaces and compile pure-Gleam multi-module projects across MoonBit backends.

### Deliverables
- **`runtime/prelude/`**:
  - `glist.mbt`: Persistent `GList[T]` (`Nil`, `Cons`) with `#derive(Eq, Debug, Hash)` and `Array` conversion helpers.
  - `math.mbt`: Safe division/remainder helpers (`int_div`, `int_rem`, `float_div`) returning `0L` / `0.0` on divide-by-zero.
  - `dynamic.mbt`: Core `Dynamic` enum representation.
  - `bit_array.mbt`: Tier 1 byte-aligned `BitArray` backed by MoonBit `Bytes`.
- **`src/emit/moonbit.gleam`**:
  - Emit `///|`-separated `.mbt` source files covering `pub(all) enum` (with conditional `#derive(Eq, Debug, Hash)`), synthesized `Type::field(self)` getters, `fn`, `match`, functional `for` loops, `guard`, tuples, `Int64`/`Double` ops, and `@external(moonbit, ...)` / raw Wasm import stubs.
- **`src/emit/pkg_config.gleam`**:
  - Generate `build/moonbit/moon.mod` and per-directory `moon.pkg` files with accurate `import { ... }` blocks and `is-main` flags where applicable.
- **Initial CLI (`src/gekko.gleam`)**:
  - Support `gekko check`, `gekko build --target <target>`, and `gekko test`.

### Verification Gate
- Transpile multi-file pure-Gleam golden fixtures into `build/moonbit/` and pass `moon check` and `moon test` on `wasm-gc`, `wasm`, `js`, and `native`.

---

## Phase 4: Hex Dependency Loader & FFI-Backed `gleam_stdlib` + `gleam_json` Support *(Completed)*

**Goal:** Support real-world Gleam projects using Hex dependencies, `gleam_stdlib`, and `gleam_json`.

### Deliverables
- [x] **`src/project/loader.gleam`**: Parse `manifest.toml` and `build/packages/*/gleam.toml` in topological order, transpile pure-Gleam Hex dependencies, and fail fast with `package:module.function` + `file:line:col` errors when externals are unmapped.
- [x] **Companion `gleam_stdlib` shim (`gekko_stdlib`):** Transpiles unmodified upstream Hex `gleam_stdlib` with co-located `patches/` (`#gekko.patch`) MoonBit implementations (`gleam/string`, `gleam/int`, `gleam/float`, `gleam/dict`, `gleam/bit_array`, `gleam/dynamic/decode`, `gleam/io`, `gleam/string_tree`, `gleam/uri`, etc.).
- [x] **Companion `gleam_json` shim (`gekko_json`):** Transpiles unmodified upstream Hex `gleam_json` with a co-located `patches/` (`#gekko.patch`) MoonBit implementation backed by `moonbitlang/core/json`.

### Verification Gate
- Transpile non-trivial Gleam projects importing `gleam_stdlib`, `gleam_json`, and pure-Gleam third-party Hex packages.
- Verify identical execution and assertion results between `gleam test` and `gekko test` (`moon test`).

---

## Phase 5: Wasm Component Model (WIT / WASI Preview 2) & CLI Packaging *(Completed)*

**Goal:** Compile Gleam programs implementing WIT interfaces into standalone Wasm Components.

### Deliverables
- [x] **`src/wit/` & `src/emit/wit_bridge.gleam`**: Built-in WIT parser (including `include` and imported `resource` / `own<T>` / `borrow<T>`), `gekko wit gen` Gleam bindings, `wit-bindgen moonbit` orchestration, boundary type adapters, and `gekko wit check` / `gekko wit build [--release]`.
- [x] **CLI Packaging (`src/gekko.gleam`):** Complete CLI covering `new`, `init`, `clean`, `doctor`, `check`, `build [--release]`, `test`, `run -- <args>`, `moonbit bind`, and `wit gen|check|build`.

### Verification Gate
- Compile a Gleam application importing and exporting WIT interfaces (including records, lists, results, strings, and imported resources) into `dist/<world>.wasm`, validate with `wasm-tools component wit`, and execute via `wasmtime`.

---

## Phase 6: Ecosystem Hardening, BitArray Tier 2, Diagnostics & v1.0 *(In Progress)*

**Goal:** Close long-tail Gleam language edge cases and polish developer ergonomics for v1.0.

### Deliverables
- [x] **BitArray Tier 2:** Support arbitrary non-byte-aligned bit-level packing, `size(n)` expressions, signed/unsigned/endianness/float/UTF segments, and bit-level pattern matching in `gprelude.BitArray`.
- [x] **Source-Mapped Diagnostics:** Emit `.gekko_sourcemap` and annotate `moon` compiler errors with originating `.gleam` file/line hints, plus `file:line:col` range and unmapped-external diagnostics.
- [x] **Collision-Free Package Mapping & Incremental Builds:** Deterministic `resolve_module_pkg_dirs` disambiguation, write-if-changed emission, and parallel dependency interface extraction.
- [ ] **Mutual Tail Recursion & Exported WIT Resources:** Lower mutually recursive tail calls on linear `wasm` / `js` / `native` and support exporting WIT `resource` handles.
- [x] **Upstream Hex FFI Overlay Packs:** Companion shim packages (`[tools.gekko.use_shims]`, `[tools.gekko.shim_for]`, `patches/` + `#gekko.patch`, `[tools.gekko.target_branch]`, `gekko shim inspect|init` — see [`docs/SHIMS.md`](./SHIMS.md)) allowing unmodified upstream Hex packages to be transpiled without forking.

### Verification Gate
- Comprehensive golden test suite passes cleanly across `wasm-gc`, `wasm`, `js`, `native`, and Wasm Component targets with zero `moon check` warnings.
