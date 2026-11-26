# Plan: make `patches/` a real MoonBit workspace

Status: implemented.

## The model

One sentence for contributors:

> A patch is MoonBit you own. A `#gekko.patch` line takes that declaration out of the
> generated code. If it compiles, it is correct.

Everything else is tooling and compiler feedback. No new per-library concepts.

## Why shims exist

Upstream Gleam libraries are 90-99% pure Gleam. The part that cannot transpile is the pocket
of **bodyless `@external(...)` declarations**: functions with no Gleam body, whose only
implementations are Erlang/JavaScript. In `gleam_stdlib` there are 109 `@external` mappings
and 100 bodyless top-level functions across 10 modules; `gekko_stdlib` patches 117
declarations, so the patch set is essentially that external set.

An external with a real pure-Gleam fallback body is transpiled from that body and needs no
patch. A bodyless external gets `{ panic as "external" }` injected by the prepass
(`src/project/prepass.gleam:531`). Libraries also ship externals whose fallback body is
deliberately `panic`/`todo` as a placeholder, which looks identical after lowering. So
**a missing shim compiles fine and panics at runtime** in both cases.

Therefore a declaration needs a shim iff all three hold:

1. it carries an `@external(...)` attribute (any backend);
2. its effective body is a single `IrAbort(PanicAbort | TodoAbort, _)`
   (`src/lower/ir.gleam:122-126,178`), which covers both the injected stub and a
   hand-written `panic`/`todo` fallback;
3. it is not already resolved: `ffi` is not `PackageCall`/`WasmImport` (from an
   `@external(moonbit, ...)` mapping) and not `Patched`.

`IrFunction` (`src/lower/ir.gleam:88-99`) carries no "was external" flag today, so add one
(`external: Bool`, set during lowering) to evaluate (1); (2) and (3) are already available.
Making this derived checklist static is a core goal of this plan.

Beyond the externals themselves, a patch sometimes has to supply the opaque type those
externals operate on (`pub type Dict(key, value)` in `src/gleam/dict.gleam:17` has no
representation until you give it one) plus the `Eq`/`Debug`/`GleamInspect` impls MoonBit
expects. Those are collateral, not the goal.

## Vocabulary

- **Gleam package**: a Hex dependency, e.g. `gleam_stdlib`. The shim repo declares this
  with `[tools.gekko.shim_for] package = "gleam_stdlib"`.
- **Gleam module**: one source file inside that package, e.g. `gleam/float` is
  `src/gleam/float.gleam`. One module becomes one MoonBit package.
- **Declaration**: a top-level function, constant, or type inside a module, e.g.
  `gleam/float.parse`, `gleam/dict.Dict`.
- **Patch**: a MoonBit file (or directory) in `patches/` that overrides individual
  declarations of one module. The transpiler emits everything else.

A shim does *not* have to replace the whole package. Only the declarations whose generated
form is wrong or inadequate are patched; the rest is generated. Today `gekko_stdlib` patches
117 declarations and still keeps ~2.5k lines of generated code.

## Layout

```text
<root>/
  moon.work                                  generated, gitignored
  patches/
    moon.mod                                 generated, gitignored  (same bytes as build's)
    gprelude/{moon.pkg, gprelude.mbt}        generated, gitignored  (reserved dir)
    gleam/dict/moon.pkg                      generated, gitignored  (merged derived + extra imports)
    gleam/dict/dict.mbt                      tracked                (your patch, `#gekko.patch` markers)
    gleam/dict/dict.g.mbt                    generated, gitignored  (patch-pruned module)
    gleam/list/moon.pkg                      generated, gitignored  (unpatched sibling module)
    gleam/list/list.g.mbt                    generated, gitignored  (full generated module)
  build/moonbit/                             unchanged, NOT a moon.work member
```

Changes to today's layout:

- **Single-file patches are retired.** `patches/gleam/dict.mbt` becomes
  `patches/gleam/dict/dict.mbt`. A file's directory *is* its package, so the single-file
  layout can never be LSP-valid. All four single-file patches already carry markers on every
  declaration (`dict.mbt`: 14 markers = 2 types + 12 functions; `dynamic.mbt`: 11/11;
  `io.mbt`: 4/4; `option.mbt`: 1/1), so the move changes nothing semantically. Verify how
  `is_builtin_alias_only_patch` (`option.mbt`'s `pub using @prelude { type Option }`)
  interacts with `patches/gleam/option/option.g.mbt` under `moon check`.
- **Use nested module directories in `build/moonbit/` too** (`gleam/dict/` instead of
  `gleam_dict/`), so package import paths (`"<project>/gleam/dict"`) match between
  `build/moonbit/` and `patches/` without rewriting. Verify nested packages like
  `gleam/dynamic/` + `gleam/dynamic/decode/` with pinned MoonBit `0.1.20261119`.
- **Emit the full module graph into `patches/`**: unpatched sibling and dependency
  modules (e.g. `gleam/list`, `gleam/order`, or `gleam_stdlib` in `gekko_json`) also get
  gitignored `moon.pkg` + `<stem>.g.mbt` under `patches/`. Otherwise `moon check` inside
  `patches/` fails on `patched -> unpatched -> patched` or cross-package imports.
- `patches/` gets its own `moon.mod` **with the same module name as the build module**.
  Because `build/moonbit` is not a `moon.work` member, there is no "conflicting versions"
  error (verified) and no import rewriting is needed: the generated bytes in `patches/` are
  identical to `build/moonbit/`.

## What gets written where

| Output | build/ | patches/ |
|---|---|---|
| `moon.mod` | `build/moonbit/moon.mod` | `patches/moon.mod` (identical) |
| merged `moon.pkg` | `build/moonbit/<mod>/moon.pkg` | `patches/<mod>/moon.pkg` (identical) |
| generated module (full or pruned) | `<mod>/<stem>.mbt` | `<mod>/<stem>.g.mbt` |
| patch files | `__gekko_patch_N_<name>.mbt` | original names (tracked) |
| prelude | `gprelude/` | `gprelude/` (identical) |

Both trees are written from the **same in-memory emission result** so they cannot drift.

## `moon.pkg` ownership

Generate and gitignore **all** `patches/**/moon.pkg`. Store extra patch-only imports
(such as `"moonbitlang/core/buffer"` or `"moonbitlang/core/json"`) in tracked
`[tools.gekko.patches."<module>"] imports` in `gleam.toml`.

Keeping `moon.pkg` generated avoids dirtying tracked files on upstream import changes,
retaining stale imports, and leaking the shim repo's module name into git.

## `moon.work`

```toml
// Generated by gekko for MoonBit LSP support
members = ["patches"]
# "moonbit" appended when moonbit/moon.mod exists
```

Drop `build/.gekko_gprelude` by applying the same self-contained pattern to `moonbit/`:

- When `moonbit/moon.mod` exists, generate gitignored `moonbit/gprelude/{moon.pkg, gprelude.mbt}`
  directly inside `moonbit/`.
- Rewrite `moonbit/` packages (including `examples/file_io` and `examples/moonbit_ffi`) to
  drop `"gekko/gprelude@0.1.0"` from `moonbit/moon.mod` and import
  `"<moon_mod_name>/gprelude" @gprelude` in `moonbit/<pkg>/moon.pkg`.
- `moonbit_ffi.gleam` rewrites `"<moon_mod_name>/gprelude"` -> `"<project_name>/gprelude"`
  when copying `moonbit/` packages into `build/moonbit/`.
- Ensure `moonbit/moon.mod` uses a distinct module name (e.g. `<project>_mbt`) whenever a
  project has both `patches/` and `moonbit/` in `moon.work` so MoonBit never sees
  duplicate module names.

## Commands

- `gekko shim new <pkg> [--out <dir>]` — create a brand-new companion shim repo from
  scratch (what `gekko shim init <pkg>` does today).
- `gekko shim patch <module>.<decl>` — scaffold one declaration. Run full
  `trait_bounds.analyze_project` so bounds are accurate. A function gets the exact emitted
  signature (reuse the `header` built in `src/emit/moonbit.gleam:240-256`) with an
  `abort("TODO")` body; a type gets `#gekko.patch` plus `emit_type_def(...)` from the
  unpatched `IrTypeDef` (`external_type: None`), which already returns the whole block
  (derive line + declaration + impls, `src/emit/moonbit_decl.gleam:203`). Validates that
  the declaration exists and that the signature matches.
- `gekko shim patch --module <module>` — scaffold every *unimplemented external* of one
  module, not every declaration. For `gleam/dict` that is the 10 bodyless externals; the
  pure-Gleam functions stay generated. It computes the set as
  `needs_shim(module) - already_patched(module)`.
- `gekko shim init` — inside a shim repo (using `[tools.gekko.shim_for]`), scaffold every
  missing unimplemented external in-place. Its completion criterion is objective:
  `gekko shim inspect` reports zero missing.
- `gekko shim inspect [pkg]` — inside a shim repo (defaulting to `[tools.gekko.shim_for]`)
  or for a given `<pkg>`, report patched declaration count, missing externals and unmapped
  zero-variant opaque types, unmatched count, pinned upstream version, and type drift.
- `gekko shim migrate` — moves single-file patches into module dirs and moves `moon.pkg`
  extra imports into `[tools.gekko.patches."<module>"] imports` in `gleam.toml`.
- `gekko shim ack` — accepts a type-drift baseline after review.

### `gekko shim patch` is additive, never destructive

`patch <module>.<decl>` and `patch --module <module>` must both append into the module's
existing patch file:

- Target file: the `.mbt` in `patches/<module>/` that already contains this declaration;
  else the canonical `<stem>.mbt`; else the only `.mbt` present; else create `<stem>.mbt`.
- Append `\n///|\n#gekko.patch\n` plus the emitted block at end of file. Existing bytes are
  never reformatted, reordered, or removed, so the diff is purely additive.
- Idempotent: if the declaration is already present *with* a `#gekko.patch` marker, exit 0
  and change nothing. If the same name exists *without* a marker, error — the file needs a
  human decision.
- `--module` batches: one read, append all missing declarations in module order, one write.
- `patches/<module>/moon.pkg` is regenerated on build from derived imports plus
  `[tools.gekko.patches."<module>"] imports` in `gleam.toml`.

Consequence for `gekko shim inspect`: a patched declaration counts as satisfied regardless
of its body, including an `abort("TODO")` scaffold, so inspecting twice is stable.

## Guards, upgraded from warnings to errors

0. **Missing external implementation** → a completeness report, and an error under
   `--strict`. Today an unimplemented bodyless external silently becomes
   `panic as "external"` and only fails at runtime.
1. **Unmatched patch** → error. Today it is only
   `Warning: override 'calc.does_not_exist' (from demo) did not match any function in loaded packages`
   and the build succeeds.
2. **Signature mismatch** → keep `__gekko_sigcheck_*` so MoonBit's real type checker
   validates generics, trait bounds, and type aliases with zero false positives, and remap
   `__gekko_sigcheck_<fn>` diagnostics back to `patches/...:line` using
   `DiscoveredPatchAttr.line`. Reserve pre-emission checks for unambiguous errors
   (unmatched target, visibility mismatch, wrong arity).
3. **Type drift** → fingerprint the upstream `IrTypeDef`
   (`src/lower/ir.gleam:25-36`: publicity, opacity, type-param arity, variant names, field
   labels and types), store it in `patches/.gekko_baseline/<module>.toml` with the resolved
   upstream version, and compare upstream-now against upstream-baseline (never
   patch-vs-upstream). Any difference is an error until `gekko shim ack`.

## Implementation phases

1. **Nested layout + full mirror + workspace** — switch `build/moonbit/` to nested
   `<mod>/` directories (verifying nested packages in MoonBit `0.1.20261119`), emit the
   full module graph into `patches/` (`patches/moon.mod`, `patches/gprelude/`,
   `patches/**/moon.pkg`, `patches/**/<stem>.g.mbt`), prune stale generated files, generate
   `moonbit/gprelude/` when `moonbit/moon.mod` exists, and rewrite
   `sync_moonbit_lsp_workspace` (`:853-895`) to drop `build/.gekko_gprelude` and always
   write the new `moon.work`.
2. **Patch imports + layout consolidation** — support `[tools.gekko.patches."<module>"] imports`
   in `gleam.toml`, teach `walk_patches_dir` (`src/project/patch_discovery.gleam:665`) to
   skip reserved entries (`moon.mod`, `gprelude/`, `*.g.mbt`, generated `moon.pkg`), and
   add `gekko shim migrate`.
3. **Scaffolding** — `gekko shim new`, in-place `gekko shim init`, `gekko shim inspect`,
   and `gekko shim patch` using `trait_bounds.analyze_project` and
   `emit_function`/`emit_type_def` (with unpatched `IrTypeDef`) so the scaffold is exactly
   what the emitter would write.
4. **Guards** — unmatched = error, visibility/arity pre-checks + `__gekko_sigcheck_*` line
   remapping to `patches/...:line`, drift baseline + `ack`.
5. **Docs + migration** — `docs/SHIMS.md`, `docs/GUIDE.md`, gitignore template
   (`src/project/scaffold.gleam:97`), migrate stdlib/json/examples (`file_io`,
   `moonbit_ffi`).

## Clean and ignore

```gitignore
/_build/
/moon.work
/moonbit/gprelude/
/patches/moon.mod
/patches/gprelude/
/patches/_build/
/patches/.mooncakes/
patches/**/moon.pkg
patches/**/*.g.mbt
```

`gekko clean` (`src/gekko.gleam:717`) deletes only marker-bearing generated files (`*.g.mbt`,
generated `patches/**/moon.pkg`, `patches/moon.mod`, `patches/gprelude/`, `patches/_build/`,
`patches/.mooncakes/`, `moonbit/gprelude/`, `moon.work`) — never a tracked `.mbt`. Note
gitignore only applies to untracked files, so anything already committed needs one
`git rm --cached`.

## Tests

- Mirror-equality test: `patches/moon.mod`, `patches/<mod>/moon.pkg` and `<stem>.g.mbt` are
  byte-identical to their `build/moonbit` counterparts.
- `moon check` inside `patches/` for a scratch shim (gated on the pinned toolchain, like
  existing tests) — this is the real LSP guarantee.
- Scaffold tests: function scaffold compiles; type scaffold compiles; unmatched declaration
  errors; signature mismatch errors at the patch path; drift errors and clears after `ack`.
- Full gate: `gleam format src test` -> `gleam test` -> ecosystem script with the three
  `GEKKO_*_DIR` overrides.

## What is not automated

A wrong body, and a same-shape behavioural change upstream. Everything else — signature,
block shape, location, imports, staleness — becomes either a compiler error or a generated
artifact.
