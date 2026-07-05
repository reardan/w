# AI Tooling MVP

Status: **MVP implemented** for the first implementation milestone of
[reardan/w#25](https://github.com/reardan/w/issues/25) (AI Tooling).

Issue #25 proposes a broad surface: structured diagnostics, a formatter, a
target mapper, a semantic indexer, a reducer, an inspector, an LSP server,
and four MCP servers. This document scopes the MVP: the smallest slice that
lets an AI agent check W code, get machine-readable diagnostics, pick the
right tests for a change, and drive the toolchain through MCP — plus the
documentation that tells it which tool to use when.

## MVP scope

In scope, in implementation order:

1. **`w check [--json]`** — compile-only mode with structured NDJSON
   diagnostics (file, line, column, severity, message, token, arch).
2. **`wtest changed`** — map changed files to the smallest useful Makefile
   targets, with `make tests` as the fallback.
3. **`w-toolchain-mcp`** — a dependency-free stdio MCP server exposing
   build / verify / check / compile / run / run_tests / repl_eval /
   test_changed.
4. **Docs** — a "Tooling for agents" section in the README mapping
   workflows to tools.

Deferred (section "Out of scope" below, each with rationale): LSP server,
`wfmt` (writing mode), semantic indexer + `w-index-mcp`, `w reduce`,
`w inspect`, Tree-sitter grammar, `w-debug-mcp`/DAP, `w-parsergen-mcp`.

## Implementation status

The MVP described here has landed:

- `w check [--json]` compiles to `/dev/null` and emits NDJSON diagnostics
  in JSON mode while keeping default human diagnostics byte-compatible.
- `tools/test_map.w` builds to `bin/wtest`; `wtest changed` and
  `make test_changed` map changed paths to focused Makefile targets.
- `tools/mcp/w_toolchain_mcp.w` builds to `bin/wmcp`, a W-native stdio MCP
  server registered by `.cursor/mcp.json`. (It began life as stdlib-only
  Python and was ported to W once `lib/process.w` landed.)
- README agent tooling guidance and regression targets (`check_json_test`,
  `wtest_map_test`, `mcp_test`) are wired into `make tests`.

The out-of-scope items at the end of this document remain deferred.

## Current state (verified against source at head)

- **Every diagnostic funnels through two functions**: `warning(char* s)`
  and `error(char* s)` in `compiler/tokenizer.w`. They print
  `<message> in <filename>:<line+1>` to stderr; `error()` then exits 1
  (or long-jumps back to the REPL prompt when `repl_recovery` is set).
- **Composed messages are assembled from fragments.** Sites like
  `expect()` (`'X' expected, found 'Y'`), `sym_get_value()`
  (`Cannot find symbol: 'x'`), and `warn_type_mismatch()` in
  `grammar/promote.w` print the message head with `print_error(...)`
  calls and pass only the tail to `warning()`/`error()`. There are ~95
  `error()` call sites across `grammar/`, `compiler/`,
  `code_generator/`, and `libs/extras/`; roughly a third have fragment
  prefixes.
- **Line is tracked, column is not.** `line_number` lives in the
  tokenizer; there is no `column_number` and no record of where the
  current token started.
- **There is no compile-only mode.** The ELF goes to stdout or `-o`;
  `output_fd` lives in `code_generator/code_emitter.w`.
- **The compiler stops at the first error** (single-pass, `exit(1)`), but
  accumulates any number of warnings before that.
- **Reusable pieces already exist**: `lib/args.w` (CLI flags),
  `structures/json.w` (JSON parse/serialize with escaping),
  `lib/testing.w`, and Makefile grep-based fixture tests
  (`warning_test` et al.).
- **Human output is frozen.** `warning_test`, `type_system_error_test`,
  and friends grep exact message text from stderr, and
  `self_host_warning_test` requires a warning-free self-compile. Any
  diagnostics work must keep default output byte-identical.
- **The test API is Makefile targets.** There is no mapping from a
  changed file to its targets; agents run `make tests` (~all targets) or
  guess.
- **Python 3 is available** and was used for offline codegen in `tools/`
  when this was written, but nothing at build or test time depends on it.
  (All `tools/` programs have since been ported to W; the toolchain is
  seed + make only.)

## A. Structured diagnostics: `w check [--json]`

### CLI

```sh
w check [x64] file.w            # compile-only, human diagnostics, no ELF
w check --json [x64] file.w     # same, NDJSON diagnostics on stdout
```

`w.w`'s `main()` already dispatches `--debug` to `wdbg_main`; `check`
becomes the second dispatch: recognize `check` as the first argument and
call a `check_main(argc, argv)` in `compiler/compiler.w` that sets the
check flags and reuses `link()`. To suppress the ELF with zero codegen
changes, `check_main` opens `/dev/null` as `output_fd` — the compile runs
in full (single-pass parsing and emission cannot be separated), the bytes
just go nowhere.

Exit codes: `0` = compiled clean or warnings only, `1` = error. This is
what `error()` already does; agents distinguish "clean" from "warnings
only" by the presence of records, not the exit code.

### Output format

One JSON object per line (NDJSON) on **stdout**, emitted as each
diagnostic fires. NDJSON rather than a JSON array because `error()`
terminates the process at the first error: every record already written
is complete and parseable, no closing bracket needed.

```json
{"file": "tests/warning_fixture.w", "line": 12, "column": 9, "severity": "warning", "message": "assignment type mismatch: expected 'char*', got 'int*'", "token": "=", "arch": "x86"}
```

- `line`, `column`: 1-based, from the current token's start position.
- `severity`: `"warning"` or `"error"`, derived from which funnel fired.
  The literal `warning: ` prefix that call sites bake into their message
  strings is stripped in the funnel (one `strncmp`), so the field and the
  text do not duplicate each other.
- `token`: the tokenizer's current `token` text — the issue's
  "token/context" field, free to include.
- `arch`: `"x86"` or `"x64"` from `word_size`.
- The issue also asks for a `phase` field; dropped. The compiler is
  single-pass with no AST or IR — tokenizing, parsing, type checking, and
  emission are one interleaved pass, so there is no meaningful phase to
  report.

### Implementation: a fragment buffer behind the existing funnel

New module `compiler/diagnostics.w`, imported at the top of
`compiler/tokenizer.w` (before `warning()`/`error()` are defined):

- Globals: `int diag_json` (0 = human, 1 = NDJSON), a growable
  `char* diag_buffer` (same realloc pattern as the tokenizer's `token`
  buffer), and `int diag_token_line` / `int diag_token_column` captured
  at token start.
- `void diag_part(char* s)`: in human mode, `print_error` immediately —
  byte-identical to today. In JSON mode, append to `diag_buffer`.
- `void diag_part_type(int type_index)`: the existing
  `print_error_type()` logic from `grammar/promote.w` (type name plus
  pointer stars) rerouted through `diag_part`.
- A local ~20-line JSON string escaper (`\"`, `\\`, control characters as
  `\u00XX`). Deliberately **not** `structures/json.w`: that would pull
  hash_map and array_list into the compiler binary to escape one string,
  and the diagnostics module should stay dependency-free so `repl.w` and
  `wdbg` inherit it trivially.

`warning(s)` and `error(s)` keep their signatures and their human path
untouched. In JSON mode they emit one record — message = accumulated
buffer + `s`, prefix stripped — then clear the buffer; `error()` keeps
its existing `repl_recovery` long-jump and `exit(1)` behavior.

Call-site migration is mechanical: replace the `print_error(...)`
fragments that precede a `warning()`/`error()` call with `diag_part(...)`.
The MVP migrates the sites whose messages are asserted by existing tests
(and are the ones agents hit constantly):

- `compiler/tokenizer.w`: `expect()`, `expect_or_newline()`
- `compiler/symbol_table.w`: `sym_get_value()`, `sym_define_global()`,
  the unknown-visibility error
- `grammar/promote.w`: `warn_type_mismatch()` + `print_error_type()`
- `grammar/postfix_expr.w`: function argument count/type checks
- `compiler/compiler.w`: `file_not_found_error()`

The long tail (`grammar/unary_expression.w`, `for_statement.w`,
`string_literal.w`, `type_name.w`, `code_generator/*`, `libs/extras/*`)
follows as mechanical follow-up commits; until then those sites still
print their fragment heads to stderr while the JSON record carries the
tail — degraded but not wrong, and each migration commit is
independently `verify`-gated.

### Column tracking

Small tokenizer addition: `column_number` incremented in
`get_character()` and reset on newline; `get_token()` records
`diag_token_line`/`diag_token_column` after skipping whitespace. Human
output keeps printing only `file:line` (frozen by tests); the JSON records
carry the column. Pure addition, so the self-host fixpoint only needs the
recompile to converge as usual.

### REPL interplay

`repl_compile_entry` checkpoints and rolls back compiler globals on a
failed entry; the rollback (and `error()`'s long-jump path) must also
clear `diag_buffer` so a half-assembled message from a failed entry
cannot prefix the next diagnostic. One line in the checkpoint, one in the
funnel.

### Known MVP limitation

At most one `error` record per run (the compiler exits at the first
error), all `warning` records before it. Multi-error reporting would need
parser recovery, which single-pass emission makes a research project —
explicitly out of scope, documented in the README section.

## B. Target mapper: `wtest changed`

A W program, `tools/test_map.w`, compiled to `bin/wtest` — dogfooding the
language for its own tooling, and it needs no capability W lacks (read
Makefile, read stdin, print). W cannot spawn `git` or `make`, so the tool
*prints* targets and a Makefile target does the orchestration:

```make
test_changed: w FORCE
	./bin/wv2 tools/test_map.w -o ./bin/wtest
	git diff --name-only HEAD | ./bin/wtest changed | xargs -r $(MAKE)
```

### Mapping algorithm

1. **Parse the Makefile** for target names (lines matching
   `name:` at column 0) and recipe text. This keeps the mapper honest as
   targets evolve: it never emits a target that does not exist.
2. **Literal-mention rule**: a changed file whose path appears in a
   recipe maps to that recipe's target. This covers every
   `tests/foo_test.w`, every fixture (`warning_fixture.w` →
   `warning_test`), and the parser-generator grammars for free.
3. **Directory rules** for files that recipes do not name directly:
   - `w.w`, `grammar.w`, `codegen.w`, `compiler/*`, `grammar/*`,
     `code_generator/*` → `verify self_host_warning_test` (and print a
     note recommending full `tests` before merge)
   - `lib/foo.w` → `foo_test` when that target exists, else `lib_test`;
     `lib/__arch__/*` additionally → `lib_64_test`
   - `structures/foo.w` → `foo_test`
   - `repl.w` → `repl_test`; `debugger/*` → `debug_test`
   - `libs/extras/c_import/*`, `libs/extras/c_preprocessor/*` →
     `c_import_test c_preprocessor_test c_import_errno_test
     c_import_libc_test`
   - `libs/extras/parser_generator/*`, `tools/parser_generator.w` →
     `parser_generator_test parser_generator_w_test
     parser_generator_c_test`
   - `Makefile` → `tests`
   - `docs/*`, `*.md`, `*.txt` → nothing
4. **Fallback**: any other file → `tests`.

Output: unique targets, one per line, in Makefile declaration order.
`--verbose` prints `file -> target` explanations to stderr. Reading file
names from arguments (`./bin/wtest changed a.w b.w`) works the same as
stdin, for MCP use.

## C. `w-toolchain-mcp`

`tools/mcp/w_toolchain_mcp.w` (built by `make wmcp` to `bin/wmcp`): a
W-native stdio MCP server (JSON-RPC 2.0 over `lib/framing.w`,
`initialize`, `notifications/initialized`, `tools/list`, `tools/call`).
The MVP shipped this server in stdlib-only Python 3 because `lib/` had
no fork/exec/wait wrappers; once `lib/process.w` landed
(docs/projects/process.md) the server was ported to W behavior-for-
behavior — subprocesses run through `process_run` with pipes and
timeouts, and the wire format is unchanged.

Tools, all executed from the repo root with `bin/` ensured and a
configurable timeout, each returning
`{exit_code, stdout, stderr, duration_ms}` (output truncated to a fixed
cap):

| Tool | Arguments | Runs |
|---|---|---|
| `build` | — | `make build` |
| `verify` | `arch?` | `make verify` / `make verify_x64` |
| `run_tests` | `targets: string[]` | `make <targets>` (names validated against `^[a-z0-9_]+$`) |
| `check` | `file, arch?` | `./bin/wv2 check --json [x64] <file>`, NDJSON parsed into a diagnostics array |
| `compile` | `file, arch?, output?` | `./bin/wv2 [x64] <file> -o <output>` |
| `run` | `path, args?, stdin?` | the binary, output captured |
| `repl_eval` | `entries: string[]` | pipes entries + `:quit` to `./bin/repl` |
| `test_changed` | `files: string[]` | `./bin/wtest changed <files>`, returns target list |

Convenience: tools that need `bin/wv2` trigger `make build` once when it
is missing, so a fresh clone works without ceremony.

Registration is committed as `.cursor/mcp.json`:

```json
{"mcpServers": {"w-toolchain": {"command": "sh", "args": ["-c", "mkdir -p bin && make -s wmcp >&2 && exec ./bin/wmcp"]}}}
```

The registration builds the server from source before launching it, so a
fresh clone works without ceremony; the build log goes to stderr because
MCP owns stdout.

## D. Documentation

- README gains a **"Tooling for agents"** section: which tool for which
  workflow (`w check --json` to diagnose a file, `make test_changed` /
  `wtest changed` to pick tests, the MCP server for programmatic access,
  `make verify` before merge as always), plus the first-error-only
  limitation of `check`.
- This document is updated per phase from plan to implemented, in the
  style of `docs/projects/repl.md`.
- `docs/mvp.txt`'s "Structured diagnostics / formatter / editor tooling"
  line splits into done/remaining parts when phases land.

## Testing

New Makefile targets, wired into the `tests` umbrella:

- `check_json_test`:
  - `w check --json tests/warning_fixture.w` exits 0 and yields records
    grep-matching `"severity": "warning"`, `"file":`, `"line":`, and the
    known message substrings;
  - `w check --json` on an error fixture (reusing
    `tests/type_system_error_fixture.w`) exits 1 with a
    `"severity": "error"` record;
  - `w check --json tests/warning_clean_fixture.w` exits 0 with empty
    stdout;
  - dogfooding: a small W test program parses the captured NDJSON with
    `structures/json.w` and asserts field types and 1-based positions —
    the in-repo JSON parser validates the compiler's JSON writer.
- `wtest_map_test`: pipe known paths through `bin/wtest changed` and
  assert exact target lines (`grammar/promote.w` → `verify`,
  `structures/json.w` → `json_test`, unknown path → `tests`,
  `docs/todo.txt` → empty).
- `mcp_test`: a W driver (`tools/mcp/mcp_test.w`) spawns `bin/wmcp` with
  piped stdio, performs the initialize handshake, lists tools, and calls
  `test_changed` and `check` (on `tests/hello.w`, asserting zero
  diagnostics) end to end.

Regression gates for every compiler-touching commit: `make verify`
(self-host fixpoint), `warning_test` + `type_system_*_test` +
`self_host_warning_test` (human text frozen), and full `make tests`
before merge.

## Sequencing (implemented)

1. `compiler/diagnostics.w` + `check` subcommand + JSON emission for the
   funnel-only messages; human output byte-identical; `check_json_test`.
2. Column tracking in the tokenizer; `column`/`token` fields; test
   assertions for positions.
3. Fragment migration for the test-asserted message set (promote,
   symbol_table, expect, postfix_expr, compiler); long-tail migrations as
   mechanical follow-ups.
4. `tools/test_map.w`, `test_changed` target, `wtest_map_test`.
5. `tools/mcp/w_toolchain_mcp.py`, `.cursor/mcp.json`, `mcp_test`
   (later ported to `tools/mcp/w_toolchain_mcp.w` / `tools/mcp/mcp_test.w`).
6. README "Tooling for agents" section; update this doc and
   `docs/mvp.txt`.

## Acceptance criteria (issue #25) vs. MVP

| Criterion | MVP coverage |
|---|---|
| Agents get machine-readable diagnostics | `w check --json` (A) |
| Editors get diagnostics + navigation via LSP | `bin/wlsp` (`tools/lsp/w_lsp.w`, see `docs/projects/lsp.md`) — diagnostics from `w check --json`, go-to-definition from `w symbols --json` |
| Target mapper recommends/runs focused tests | `wtest changed` + `make test_changed` (B) |
| MCP exposes build/verify/compile/run/warning-test/REPL | `w-toolchain-mcp` (C); warning-test runs via `run_tests(["warning_test"])` |
| Docs explain which tool to use | README section (D) |

## Out of scope for the MVP (deferred, with rationale)

- **LSP server**: since built — `bin/wlsp` (`tools/lsp/w_lsp.w`) is the
  thin adapter described here: `w check --json` on open/save translated
  to `publishDiagnostics`, plus go-to-definition over `w symbols --json`
  (globals, functions, and user types only). See `docs/projects/lsp.md`.
- **Semantic indexer / `w-index-mcp`**: declaration file/line per symbol
  is now recorded in `compiler/symbol_table.w` and dumped by
  `w symbols --json`; a cross-file reference index and `w-index-mcp`
  remain unbuilt.
- **`wfmt` (writing mode)**: the two style warnings (spaces indentation,
  missing trailing newline) already surface through `check`; a rewriting
  formatter needs a lossless token stream the single-pass tokenizer does
  not keep.
- **`w reduce`, `w inspect`**: conveniences, not enablers; `w inspect`
  is mostly `readelf`/`objdump` wrapping.
- **Tree-sitter grammar**: valuable for editors but external to this
  repo's toolchain; no other MVP piece depends on it.
- **`w-debug-mcp` / DAP**: wdbg's command loop is already scriptable over
  stdin (see `debug_test`); structured wrapping is straightforward but
  not needed for the check/test/build loop the MVP targets.
- **`w-parsergen-mcp`**: ParserGenerator exists, but no agent workflow
  needs it programmatically yet.

## Risks and mitigations

- **Self-host fixpoint breakage**: every compiler change is gated on
  `make verify`; diagnostics code is compile-time-only and deterministic.
- **Seed compatibility**: new compiler modules are compiled by the
  committed seed `./w` on every `make build`; `compiler/diagnostics.w`
  restricts itself to constructs the existing `compiler/` modules already
  use (globals, functions, `realloc` buffers — no new syntax).
- **Frozen human output**: the human path through `warning()`/`error()`
  and `diag_part()` is byte-identical by construction; the frozen-text
  test set is the gate.
- **stdout discipline**: `check` writes NDJSON to stdout and never an
  ELF (`output_fd` = `/dev/null`), so parsers cannot receive mixed
  streams.
- **Python dependency**: eliminated. The MCP server and its test are W
  programs; the whole toolchain — compiler, `check`, `wtest`, MCP —
  is seed + make only.
