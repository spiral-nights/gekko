# Project Specification: `gekko` (Gleam-to-MoonBit & Wasm Component Transpiler)

## 1. Executive Summary & Architecture Goal

`gekko` is a source-to-source compiler written in **Gleam** that transpiles standard Gleam projects—including local modules and resolved Hex dependencies in `build/packages/`—into multi-package **MoonBit** workspaces (`build/moonbit/`). MoonBit then compiles the generated workspace to **`wasm-gc`**, **`wasm`**, **`js`**, **`native`**, or **WebAssembly Components (WIT / WASI Preview 2)** via `wit-bindgen` and `wasm-tools`.

### Core Design Principles

1. **Frontend in Gleam, Backend in MoonBit:** Use Gleam (`glance`, `simplifile`, `filepath`, `tom`, `gleam_json`, `argv`) for project discovery, AST parsing, lowering, and `.mbt` / `moon.mod` / `moon.pkg` code emission. Use MoonBit (`moon`, `wit-bindgen`, `wasm-tools`) as the target platform, local type checker, optimizer, multi-target backend, and Wasm Component bundler.
2. **Preserve Standard Gleam Tooling:** Target projects remain valid Gleam projects so `gleam check`, `gleam test`, and `gleam export package-interface` continue to work without modification.
3. **Hybrid Type Resolution (Shadow `pub` Interface Extraction + MoonBit Local Inference):**
   - MoonBit requires explicit parameter and return type annotations on all top-level functions, whereas Gleam allows private functions to omit annotations and `gleam export package-interface` only exports `pub` declarations.
   - To avoid re-implementing Hindley-Milner type inference in `gekko`, `gekko` copies modules to a staging directory (`build/.gekko_staging/` and `build/.gekko_staging_deps/<pkg>/`, cached by SHA-256 content fingerprint in `.gekko_iface_hash`) where private top-level `fn`, `type`, `opaque type`, and `const` declarations are temporarily promoted to `pub`, then runs `gleam export package-interface` to retrieve exact, compiler-verified Hindley-Milner signatures for **all** functions, constants, and types.
   - Inside function bodies, MoonBit's own compiler infers all local variables, closures, and pattern bindings.

---

## 2. End-to-End Compilation Pipeline

```text
[ Target Gleam Project ]
  ├── gleam.toml & manifest.toml (`[tools.gekko.use_shims]`, etc.)
  ├── patches/ (optional `#gekko.patch` overlays)
  ├── src/**/*.gleam
  ├── build/packages/<pkg>/src/**/*.gleam
  └── wit/*.wit (optional Wasm Component interfaces)
          │
          ▼  (Step 1: Staging, Pre-Pass & Shadow `pub` Metadata Extraction)
  • Scan source files for `@external(moonbit, ...)` & `/// @external(moonbit, ...)` pragmas
  • Strip raw `@external(moonbit, ...)` lines in-memory before parsing with `glance`
  • Stage shadow copies in `build/.gekko_staging/` promoting private `fn`/`type`/`const` to `pub`
  • Run `gleam export package-interface` on root & deps (cached via `.gekko_iface_hash`) -> resolved HM signatures for ALL fns
          │
          ▼  (Step 2: Project-Wide Indexing Pass)
  • Parse all `.gleam` files via `glance`
  • Build Global Symbol Table:
      - CustomType definitions, constructor variants, field lists, and shared fields
      - `has_function_field` transitive reachability (controls `#derive(Eq, Debug, Hash)`)
      - Function arities, labeled argument positions, and resolved HM parameter/return types
      - Module import aliases (`import gleam/list as l`) and companion shim overlays (`patches/`, `[tools.gekko.*]`)
          │
          ▼  (Step 3: AST Desugaring & Lowering Pass)
  • Desugar `use` statements right-to-left into nested trailing closures
  • Desugar `let assert pat = expr` -> `guard expr is pat else { abort(...) }`
  • Desugar `todo` / `panic` -> `abort(...)`
  • Desugar function captures `f(a, _, c)` -> `fn(__capture_1) { f(a, __capture_1, c) }`
  • Lower pipelines (`|>`) using Symbol Table arity & label info (binding effectful LHS when needed)
  • Rewrite self-tail-recursive functions into MoonBit functional `for` state loops
  • Lower `FieldAccess` (`mod.fn` vs `expr.field()` via Uniform Getter Rule)
  • Lower `RecordUpdate` (`Variant(..r, field: v)`) into `match` reconstruction
  • Mangle reserved MoonBit keywords injectively and capitalize generic type parameters
          │
          ▼  (Step 4: Modern MoonBit Workspace & Code Emission)
  • Emit `build/moonbit/moon.mod`
  • Map each Gleam module `a/b.gleam` -> `build/moonbit/<pkg_dir>/` (with deterministic collision disambiguation)
    with declarative `moon.pkg`, `///|` block separators, write-if-changed incremental writes, and `.gekko_sourcemap`
  • Bundle `gprelude/` (`@gprelude`) and copy local `moonbit/` FFI packages
  • Run `wit-bindgen moonbit` if `wit/` exists and wire `stub.mbt` exports and resource/import adapters
          │
          ▼  (Step 5: Verification, Multi-Target Build & Component Packaging)
  • Run `moon check [--target <target>]` / `moon test [--target <target>]` (with `.gekko_sourcemap` error annotations)
  • Run `moon build [--release] [--target wasm-gc | wasm | js | native]`
  • For WIT components: `gekko wit build [--release]` runs `wasm-tools component embed` + `wasm-tools component new` -> `dist/<world>.wasm`
```

---

## 3. Repository Structure of `gekko`

```text
gekko/
├── gleam.toml                     # Deps: glance, simplifile, filepath, tom, gleam_json, argv
├── README.md
├── docs/
│   ├── GUIDE.md
│   ├── SHIMS.md
│   ├── SEMANTICS.md
│   ├── SPEC.md
│   └── ROADMAP.md
├── src/
│   ├── gekko.gleam                # CLI entrypoint (`check`, `build`, `test`, `run`, `wit`, `moonbit`)
│   ├── gekko_ffi.erl              # Erlang FFI (process runner, env, `:zip` reader, SHA-256)
│   ├── project/
│   │   ├── cmd.gleam              # External command runner & Erlang FFI bindings
│   │   ├── ffi_config.gleam       # Parses [tools.gekko.*] / legacy gekko.toml / moonbit/moon.mod
│   │   ├── interface.gleam        # Decodes package-interface JSON into type lookup tables
│   │   ├── loader.gleam           # Reads gleam.toml, manifest.toml, build/packages/*
│   │   ├── moonbit_ffi.gleam      # Discovers & copies local moonbit/ FFI packages
│   │   ├── prepass.gleam          # Extracts & strips `@external(moonbit, ...)` before glance
│   │   ├── staging.gleam          # Shadow `pub` source staging & cached `package-interface`
│   │   ├── text_edit.gleam        # UTF-8 byte-offset edits & line/column mapping
│   │   └── workspace.gleam        # Emits complete MoonBit workspace & collision checks
│   ├── index/
│   │   └── symbol_table.gleam     # Global index: types, variants, shared fields, arities, imports
│   ├── lower/
│   │   ├── bit_pattern.gleam      # Lowers BitArray segments into guards & decoded bindings
│   │   ├── desugar.gleam          # Lowers `use`, `let assert`, `FnCapture`, `|>`, labeled args
│   │   ├── desugar_types.gleam    # Lowers types, getters, arity, and scope/alias resolution
│   │   ├── ir.gleam               # Lowered IR types and expressions
│   │   ├── ir_util.gleam          # Shared free-var, pattern-var, and purity helpers
│   │   ├── mangle.gleam           # Injective keyword escaping & type variable normalization
│   │   ├── pattern.gleam          # Lowers List `[h, ..t]`, String prefixes, and patterns
│   │   ├── tco.gleam              # Self-tail-recursion -> MoonBit functional `for` loops
│   │   └── validate.gleam         # Validates Int64 literal ranges
│   ├── emit/
│   │   ├── moonbit.gleam          # Renders lowered IR functions/statements/exprs to `.mbt`
│   │   ├── moonbit_decl.gleam     # Emits MoonBit types, traits, patterns, imports & helpers
│   │   ├── pkg_config.gleam       # Generates `moon.mod` and parses/emits `moon.pkg` DSL files
│   │   ├── prelude_runtime.gleam  # Embedded `gprelude` runtime (synced via scripts/sync_prelude.sh)
│   │   ├── trait_bounds.gleam     # Whole-project `Eq`/`Hash`/`GleamInspect`/`ToDynamic` inference
│   │   ├── trait_infer.gleam      # Local IR type inference, unification, and alias expansion
│   │   └── wit_bridge.gleam       # Orchestrates `wit-bindgen moonbit` & boundary glue in `stub.mbt`
│   ├── moonbit/
│   │   ├── bindgen.gleam          # Generates Gleam FFI stubs from parsed `.mbti` packages
│   │   ├── bindgen_adapter.gleam  # Generates MoonBit adapter packages & type conversions
│   │   ├── ffi_meta.gleam         # Scans `.mbt` files for trait & generic signature metadata
│   │   ├── mbti.gleam             # Parses `pkg.generated.mbti` interface files
│   │   └── syntax.gleam           # Shared MoonBit delimiter & signature scanning helpers
│   └── wit/
│       ├── ast.gleam              # WIT AST & Gleam identifier escaping
│       ├── gleam_gen.gleam        # Generates Gleam stubs from WIT definitions
│       └── parser.gleam           # WIT parser
├── runtime/
│   └── prelude/                   # Bundled `@gprelude` MoonBit runtime (`gprelude.mbt`, `moon.pkg`)
├── fixtures/
│   └── golden/                    # End-to-end `.gleam` -> `.mbt` -> `moon test` golden fixture projects
└── test/                          # Split unit & E2E test suites (`gekko_test.gleam`, etc.)
```

---

## 4. Core Engineering & Lowering Specifications

### 4.1 External Hex Packages & FFI-Backed `gleam_stdlib` / `gleam_json` Strategy

Gleam downloads all resolved Hex dependencies into `build/packages/<package_name>/` with their own `gleam.toml` and `src/` trees.

1. **Package Discovery & Topological Order:**
   - Parse `manifest.toml` (and `build/packages/*/gleam.toml` using `tom`) to determine the exact dependency graph and active package versions, automatically running `gleam deps download` when remote dependencies are declared and `build/packages/` is absent.
2. **Deterministic Namespace Mapping:**
   - MoonBit enforces one package per directory and imports packages via `@alias.symbol` declared in `moon.pkg`.
   - Gleam module `a/b.gleam` (whether root or dependency) maps to `<out_dir>/a_b/` via `pkg_config.resolve_module_pkg_dirs`, keeping FFI `moon.pkg` package references uniform (e.g. `"<project>/gleam_order" @gleam_order`), while disambiguating collisions (e.g. `foo/bar.gleam` vs `foo_bar.gleam` → `foo_bar__2`).
3. **FFI-Backed `gleam_stdlib` and `gleam_json` Strategy:**
   - Most of `gleam_stdlib` and `gleam_json` is pure Gleam (or includes pure-Gleam fallback bodies below `@external(erlang, ...)`). Only a small set of leaf primitives actually invoke host FFI (`gleam/string`, `gleam/dict`, `gleam/bit_array`, `gleam/int`, `gleam/float`, `gleam/dynamic/decode`, `gleam/io`, and ~12 primitives in `gleam/json`).
   - Rather than re-implementing every stdlib module from scratch in MoonBit, `gekko` **transpiles the real `.gleam` files** of unmodified upstream [`gleam_stdlib`](https://hex.pm/packages/gleam_stdlib) and [`gleam_json`](https://hex.pm/packages/gleam_json) from `build/packages/`, applying co-located `patches/` (`#gekko.patch`) MoonBit implementations from companion shims [`gekko_stdlib`](https://github.com/spiral-nights/gekko_stdlib) and [`gekko_json`](https://github.com/spiral-nights/gekko_json) (authorized via `[tools.gekko.use_shims]`) so APIs and edge-case semantics match standard Gleam 100%.
   - Bundled `moonbit/` FFI packages inside those repositories implement only the leaf `@external(moonbit, ...)` primitives using MoonBit `core` types (`Map`, `@json.Json`, `Bytes`, `String`, `Int64`, `Double`, and `@gprelude.Dynamic`).
   - **Pure-Gleam Fallback Rule:** If a function in a dependency declares `@external(erlang, ...)` / `@external(javascript, ...)` and also provides a pure-Gleam body, emit the pure-Gleam body unless overridden in the FFI shim registry or `gekko.toml` / `[tools.gekko.overrides]` (allowing selective MoonBit fast-path overrides for hot functions like `list.reverse` or `string.join`).
   - **Hard External Error Reporting:** If a reachable function has Erlang/JS externals, no pure-Gleam fallback body, and no entry in the FFI registry or overrides, fail fast at compile time with the exact `package:module.function` path and `file:line:col` location.

---

### 4.2 FFI into MoonBit Functions (`@external(moonbit, ...)` & Companion Shims)

Standard `gleam check` and `glance` restrict `@external(...)` targets to `erlang` and `javascript`. `gekko` supports three complementary mechanisms:

1. **Doc-Comment Pragma (100% compatible with unmodified `gleam check`):**
   ```gleam
   /// @external(moonbit, "my_org/wit_fs", "read_file")
   pub fn read_file(path: String) -> Result(String, FileError) {
     Error(UnsupportedPlatform)
   }
   ```
   `glance` preserves `///` comments in `Function.documentation`, letting `gekko` extract the target package and function cleanly.

2. **Source Pre-Pass for Raw `@external(moonbit, "pkg", "fn")`:**
   Before passing source strings to `glance.module(src)`, `project/prepass.gleam` scans line-by-line for `@external(moonbit, "<pkg>", "<fn>")`:
   - Records the FFI mapping against the immediately following `fn <name>` declaration.
   - Replaces the attribute line with `// @external_moonbit_stripped` (preserving exact line numbers for diagnostics).
   - Injects a dummy `{ panic }` body in the in-memory copy if the Gleam function is bodyless so `glance` and staging parse cleanly.

3. **Companion Shim Packages (`[tools.gekko.*]` & `patches/` + `#gekko.patch`):**
   Allows both root projects and standalone companion shim dependencies to bind unmodified third-party Hex dependency types and functions to MoonBit implementations without modifying `build/packages/` (see [`docs/SHIMS.md`](./SHIMS.md) for the full schema, including legacy `gekko.toml` support):
   - `[tools.gekko.use_shims]` (root `gleam.toml` allowlist enabling `<pkg> = "<shim_pkg>"`)
   - `[tools.gekko.shim_for]` (`package`, SemVer `version` constraint check)
   - `patches/<mod>/` (`moon.pkg` + `#gekko.patch`-annotated `.mbt` files co-located directly inside the transpiled module's MoonBit package to avoid circular imports)
   - `[tools.gekko.target_branch."pkg:mod"]` (`prefer = "erlang" | "javascript"`)

**FFI Emission Modes:**
- **Package Call Mode (`"pkg/path"`, `"fn_name"`):** Adds `"pkg/path"` to the package's `moon.pkg` `import { ... }` block and emits a wrapper function calling `@alias.fn_name(args...)`.
- **Co-Located Patch Mode (`patches/` + `#gekko.patch`):** Places the `.mbt` patch directly in the module's MoonBit package and emits a private `__gekko_sigcheck_<fn>` compile-time signature check.
- **Raw Wasm Import Mode (`"wasm:module_name"`, `"import_name"`):** Emits a MoonBit Wasm import declaration:
  ```moonbit
  ///|
  fn __ffi_import_name(arg : Int64) -> Int64 = "module_name" "import_name"
  ```

---

### 4.3 Tail-Call Optimization (TCO) via Functional `for` Loops

Gleam has no `for` or `while` loops; iteration relies on tail recursion. Without TCO, iterating over large lists traps with call stack exhaustion on linear `wasm` (and degrades performance on other targets).

- **Self-Tail-Call Lowering to MoonBit Functional `for` Loops:**
  Modern MoonBit (`0.1.20261104`) deprecated the `loop` keyword in favor of functional `for` loops with state bindings, `continue`, and `break`.
  In `lower/tco.gleam`, any function `f(p1, p2, ...)` with one or more tail calls to `f(e1, e2, ...)` is lowered to a functional `for` loop:

  **Gleam Input:**
  ```gleam
  fn sum_loop(items: List(Int), acc: Int) -> Int {
    case items {
      [] -> acc
      [x, ..rest] -> sum_loop(rest, acc + x)
    }
  }
  ```

  **Emitted MoonBit Output:**
  ```moonbit
  ///|
  fn sum_loop(items : @prelude.GList[Int64], acc : Int64) -> Int64 {
    for items = items, acc = acc {
      match (items, acc) {
        (Nil, acc) => break acc
        (Cons(x, rest), acc) => continue rest, acc + x
      }
    }
  }
  ```

  This compiles with zero deprecation warnings and guarantees $O(1)$ stack space across **every** MoonBit backend (`wasm-gc`, `wasm`, `js`, `native`).

- **Mutual Tail Recursion:**
  Mutually recursive tail calls (`even(n)` $\leftrightarrow$ `odd(n)`) are emitted as direct calls; `--target wasm-gc` leverages Wasm `return_call` instructions natively, while linear `--target wasm` can enable `--wasm-tail-call` where supported by the host runtime.

---

### 4.4 Immutable Linked Lists (`GList[T]`) vs. MoonBit `Array[T]`

MoonBit's `[1, 2, 3]` literal produces a mutable contiguous `Array[T]`. Mapping Gleam's persistent `List(a)` to `Array[T]` would turn $O(1)$ `[head, ..tail]` prepends and pattern-matching splits inside recursive loops into $O(n)$ copies ($O(n^2)$ total).

`runtime/prelude/glist.mbt` defines a dedicated persistent singly-linked list:

```moonbit
///|
#derive(Eq, Debug, Hash)
pub(all) enum GList[T] {
  Nil
  Cons(T, GList[T])
}
```

- **Expressions:** `[]` $\rightarrow$ `Nil`; `[a, b, ..tail]` $\rightarrow$ `Cons(a, Cons(b, tail))`.
- **Patterns:** `[]` $\rightarrow$ `Nil`; `[x]` $\rightarrow$ `Cons(x, Nil)`; `[x, y, ..rest]` $\rightarrow$ `Cons(x, Cons(y, rest))`.
- **Boundary Helpers:** `GList::to_array` and `GList::from_array` handle zero-overhead conversion at the WIT Canonical ABI boundary where WIT `list<T>` lowers to `Array[T]`.

---

### 4.5 Uniform Enum Representation, Uniform Getter Rule & Record Updates

Gleam unifies records and algebraic data types under `type`, whereas MoonBit distinguishes `struct` (curly-brace patterns/construction) from `enum` (constructor patterns/construction).

1. **Uniform Enum Representation:**
   Every Gleam `CustomType`—whether it has one variant or multiple variants, labeled fields or positional fields—is emitted as a MoonBit `pub(all) enum`.
   - Construction and pattern matching are 100% uniform across all types (`User(id~, name~)` or `Admin(id, name)`).
   - Types receive `#derive(Eq, Debug, Hash)` automatically **unless** the Symbol Table marks `has_function_field = True` (either directly holding a `fn(...) -> ...` field or transitively referencing a type that does), in which case `#derive(...)` is omitted so MoonBit compiles cleanly.

2. **Uniform Getter Rule (Shared & Single-Variant Fields):**
   MoonBit `enum`s do not support `value.field` dot-field projection natively. During Symbol Indexing, `gekko` collects:
   - All labeled fields of single-variant types.
   - All fields shared with identical names and types across *every* variant of a multi-variant type.

   For each accessible field, `gekko` emits a synthesized method on the enum:
   ```moonbit
   ///|
   pub fn User::id(self : User) -> Int64 {
     match self {
       Admin(id~, ..) => id
       Member(id~, ..) => id
     }
   }
   ```
   Every non-module `FieldAccess(expr, label)` in Gleam then compiles unconditionally to `expr.label()` in MoonBit—removing any ambiguity between module calls (`mod.fn(...)`), single-variant types, and multi-variant shared fields.

3. **Record Updates (`Variant(..expr, field: val)`):**
   Gleam record update syntax explicitly identifies the variant constructor (`User(..u, age: 30)` or `Admin(..u, role: "root")`). `gekko` looks up the full field list of that variant in the Symbol Table and emits a `match` reconstruction:
   ```moonbit
   match u {
     Admin(id~, name~, age~) => Admin(id~, name~, age=30L)
     _ => abort("unreachable record update variant")
   }
   ```
   *(For single-variant enums, the wildcard arm is omitted because the match is exhaustive.)*

---

### 4.6 Desugaring `use`, `let assert`, `todo`/`panic`, Pipelines, Captures & Labeled Args

1. **`use` Expressions:**
   In `lower/desugar.gleam`, blocks are folded right-to-left. When encountering `Statement::Use(patterns, call_expr)` at index $i$, all remaining statements $[s_{i+1} \dots s_n]$ are wrapped into `Expression::Fn(patterns, [s_{i+1} \dots s_n])` and appended as the final argument of `call_expr`.
2. **`let assert`, `todo`, and `panic`:**
   - `let assert Ok(x) = expr` lowers to MoonBit's `guard` statement:
     ```moonbit
     guard expr is Ok(x) else { abort("let assert failed at src/mod.gleam:42") }
     ```
   - `todo` and `panic as msg` lower to `abort(msg)` (with source location metadata).
3. **Pipelines (`a |> f(b)`):**
   Using function arity and label metadata from the Symbol Table:
   - If `f` is a known function of arity $k$ and the call passes $k - 1$ arguments, insert `a` into the first unfilled positional parameter slot.
   - Otherwise, emit `(f(b))(a)` (supporting curried/closure-returning expressions).
4. **Function Captures (`f(a, _, c)`):**
   Lower to `fn(__capture_1) { f(a, __capture_1, c) }`.
5. **Labeled Arguments & Evaluation Order:**
   - Top-level functions emit positional MoonBit parameters so any function can be passed as a first-class value without eta-wrapping; labeled call arguments are aligned to parameter order.
   - Whenever labeled-argument reordering (or a saturated pipe) reorders effectful expressions, source-order temporary `let` bindings (`let __gekko_arg_<i> = ...` / `let __pipe_lhs_<i> = ...`) are emitted so Gleam's strict left-to-right evaluation order is preserved.
6. **Polymorphic Constants:**
   - Concrete module constants emit as `pub let name : Type = ...`.
   - Module constants whose resolved type contains type variables (`IrTypeVar`, e.g. `pub const empty = []`) emit as zero-argument generic functions (`pub fn[T0] empty() -> @gprelude.GList[T0]`) and are invoked as `empty()` / `@alias.empty()` at reference sites.

---

### 4.7 Primitives, Operators, `Dynamic`, and Tiered `BitArray`

| Gleam Type | MoonBit Representation | Lowering & Semantic Rules |
| --- | --- | --- |
| `Int` | `Int64` | Append `L` to integer literals (`42` $\rightarrow$ `42L`). Gleam `x / 0` and `x % 0` return `0` rather than trapping, so `/` and `%` emit `@prelude.int_div(a, b)` and `@prelude.int_rem(a, b)` (`if b == 0L { 0L } else { a / b }`). |
| `Float` | `Double` | Lower `+.`, `-.`, `*.`, `/.` to `+`, `-`, `*`, `/` on `Double`. Gleam `x /. 0.0` returns `0.0`, so `/.` emits `@prelude.float_div(a, b)`. |
| `Bool` | `Bool` | `True` $\rightarrow$ `true`, `False` $\rightarrow$ `false`, `!b` $\rightarrow$ `!b`. |
| `String` | `String` | Direct literals. `a <> b` $\rightarrow$ `a + b`. String prefix patterns `"pre" <> rest` lower using `has_prefix` and string slicing/guards. |
| `Nil` | `Unit` | `Nil` type $\rightarrow$ `Unit`, `Nil` value $\rightarrow$ `()`. |
| `#()`, `#(a)` | `@gprelude.Tuple0`, `@gprelude.Tuple1[A]` | Boxed 0-tuple and 1-tuple wrappers in `@gprelude`. |
| `#(a, b, c)` | `(A, B, C)` | Positional tuple indexing (`t.0`, `t.1`) matches directly. |
| `Result(ok, err)` | `Result[Ok, Err]` | `Ok(v)` $\rightarrow$ `Ok(v)`, `Error(e)` $\rightarrow$ `Err(e)`. |
| `Dynamic` | `@prelude.Dynamic` | Tagged MoonBit sum type (`DynInt`, `DynFloat`, `DynString`, `DynBool`, `DynBytes`, `DynList`, `DynArray`, `DynMap`, `DynNull`, `DynCustom`) backing `gleam/dynamic/decode` and `gleam_json`. |
| `BitArray` | `@prelude.BitArray` | **Tier 1 (Phase 3/4):** Byte-aligned literals, slices, UTF-8 strings, and standard 8/16/32/64-bit integer segments backed by MoonBit `Bytes`. **Tier 2 (Phase 6):** Arbitrary bit-offset/bit-length packing and pattern matching (`size(3)`, `bits`). |

---

### 4.8 Modern MoonBit Workspace Config, Block Separators & Identifier Mangling

1. **Workspace Configuration (`moon.mod` & `moon.pkg`):**
   Target MoonBit `0.1.20261104+` using declarative `moon.mod` and `moon.pkg` DSL files (rather than deprecated `moon.pkg.json`):
   ```text
   // build/moonbit/moon.mod
   name = "<project_name>"
   version = "0.1.0"
   ```
   ```text
   // build/moonbit/src/app/main/moon.pkg
   import {
     "<project_name>/prelude",
     "<project_name>/deps/gleam_stdlib/gleam/list",
   }
   ```
   When emitting executable/component entrypoints (`main` or WIT exports), emit `"is-main": true` (or `options( "is-main": true )` in `moon.pkg`) as required by `moon`.
2. **Block Separators (`///|`):**
   Every top-level `enum`, `fn`, `let`, and `type` declaration is separated by `///|` so `moon fmt`, `moon info`, and incremental checks operate cleanly.
3. **Injective Identifier & Type Mangling:**
   - Maintain reserved keyword and type-name tables for MoonBit (`match`, `loop`, `for`, `Error`, `Option`, etc.). If stripping trailing `_`s yields a reserved name, append `_` injectively (`match` $\rightarrow$ `match_`, `match_` $\rightarrow$ `match__`, while non-reserved `foo_` remains `foo_`).
4. **Type Parameter Capitalization:**
   - Gleam uses `snake_case` generic parameters (`fn map(list: List(a), f: fn(a) -> b)`), while MoonBit requires `UpperCamelCase` (`pub fn[A, B] map(...)`). Normalize generic type parameters injectively (`_a` $\rightarrow$ `U_A`, `t0` $\rightarrow$ `T_T0`) so user parameters never collide with builtin MoonBit types or synthetic HM names (`T0`, `T1`, ...).
5. **Warning Suppressions:**
   - `moon.mod` retains `-unresolved_type_variable` for unconstrained local polymorphic expressions in Gleam such as `let _ = []` or `let _ = Ok(1)`.

---

### 4.9 Multi-Target Support & Wasm Component Model (WIT) Integration

Because `gekko` emits pure MoonBit backed by `moonbitlang/core`, transpiled Gleam projects compile across **all four MoonBit backends** automatically:
- `wasm` (linear memory, default for `gekko build` — standard WASI Preview 1 and required for the Wasm Component Model Canonical ABI)
- `wasm-gc` (host-GC WasmGC for browsers, JS engines, and `moonrun`)
- `js`
- `native`

#### Wasm Component Model Pipeline (Phase 5)
1. When `--wit <dir>` or `wit/` is present, run:
   ```bash
   wit-bindgen moonbit <wit_dir> --out-dir build/moonbit --derive-debug --derive-eq
   ```
2. `wit-bindgen moonbit` generates import interfaces under `build/moonbit/interface/...` and export stubs under `build/moonbit/gen/world/<world_name>/stub.mbt`.
3. `emit/wit_bridge.gleam` inspects the generated `stub.mbt` signatures and populates each export body by converting boundary types (`Array[T]` $\leftrightarrow$ `@gprelude.GList[T]`, `Option[T]` $\leftrightarrow$ `Option[T]`, `Result[T, E]` $\leftrightarrow$ `Result[T, E]`, imported `resource` handles via `@external_type`) and delegating to the transpiled Gleam module function.
4. `gekko wit build [--release]` runs:
   - `moon build [--release] --target wasm`
   - `wasm-tools component embed --encoding utf16 <wit_dir> <core.wasm> -o build/moonbit/embedded.wasm`
   - `wasm-tools component new build/moonbit/embedded.wasm -o dist/<world>.wasm`
