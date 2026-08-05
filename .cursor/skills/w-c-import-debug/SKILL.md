---
name: w-c-import-debug
description: Debug c_import C-header interop failures and pin fixes as torture fixtures. Use when a c_import fails to preprocess, parse or import a header, when an imported function, constant or struct misbehaves at runtime, or when adding a c_import regression test.
---

# Debugging c_import interop

`c_import "libc.so.6" "/usr/include/stdio.h"` runs three stages, all
compiled into the compiler (design doc: `docs/projects/c_import.md`):

1. **Preprocess** — `libs/extras/c_preprocessor/`: macro expansion,
   conditionals, `#include` resolution, predefined platform macros
   keyed off the target word size.
2. **Parse** — `libs/extras/c_import/generated_c_parser.w`, a PEG
   parser generated from `tests/parser_generator/c.pg`.
3. **Import** — `libs/extras/c_import/importer.w`: lowers typedefs,
   structs (C-aligned via inserted `__ci_pad_*` filler fields),
   enums, and `extern` functions (as weak dynamic symbols); exports
   integer object-like macros as constants.

Reproduce failures cheaply with `./bin/wv2 check file.w` (insert `x64`
before `check` for the 64-bit target) — no binary is written.

## Failure shapes

- `c preprocessor: could not read <path>` — bad header path (the
  `c_import` path itself gets no existence pre-check).
- `c preprocessor: #error in <header>: <text>` — a live `#error`
  branch, usually a conditional the predefined macros do not satisfy.
- `<header>:line:col: syntax error: expected ..., found ...` followed
  by `c_import: header parse failed in <file>:<line>` — the parser
  reports the furthest token any parse attempt reached; usually a
  declaration shape the C grammar lacks.
- A function silently missing: first-definition-wins collision (W's
  own `open`/`read`/`malloc` wrappers keep priority over libc's), or
  a `static`/`inline` declaration, which is declared-but-skipped.
  Compile with `-v` to surface `note: c_import skipped '<name>': ...`
  (a note, not a warning — `-v --strict` still passes).
- A call that faults at runtime: imported functions are **weak**, so
  a symbol the library does not actually export loads as a null GOT
  slot instead of failing at startup. A hand-written `extern`
  declaration stays strong and fails at load time instead.
- Struct layout drift inside bit-field regions: bit-field members are
  skipped, so that region's layout is coarse.

## Pinning a fix: torture fixtures

Regressions go into the compile-only fixture group
`c_import_torture_test`, following `tests/c_import_torture_fixture.w`:
a `tests/<name>_fixture.w` + local `tests/<name>_fixture.h` pair whose
W body *uses* every imported shape, so an import regression fails the
compile. The fixture's header comment carries `# expect_stderr:` /
`# reject_stderr:` / `# expect_fail` directives asserted by
`bin/wfixture`, plus `# wbuild: fixture_group=c_import_torture_test`
to join the group; run `./wbuild manifest` to regenerate `build.json`,
then `./wbuild c_import_torture_test`.

## Env-blocked targets and their substitutes

`c_import_test`, `c_import_errno_test` and `c_import_libc_test`
produce 32-bit dynamically linked binaries that need the i386 loader
(`/lib/ld-linux.so.2`, package `libc6:i386`); without it they fail at
exec with "required file not found". On such hosts assert through the
compile-only fixture targets (`c_import_torture_test`,
`c_import_error_directive_test`, `c_import_missing_header_test`,
`c_import_verbose_note_test`) or the x64 twins
(`c_import_libc_64_test`, `x64_c_import_knr_test`), which run with the
host's own x86-64 loader.
