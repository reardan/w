# AI Tooling MVP

Status: **MVP implemented** for the first implementation milestone of
[reardan/w#25](https://github.com/reardan/w/issues/25) (AI Tooling).

> **July 2026 update**: the integration layer this doc describes beyond
> the compiler surfaces — the MCP servers (`wmcp`/`wimcp`/`wdmcp`), the
> LSP server (`wlsp`), the semantic index (`windex`/`windexd`) and the
> edit-check hook (`whook`) — moved out of this repo, along with their
> design docs (`lsp.md`, `semantic_index.md`, `index_daemon.md`,
> `debug_mcp.md`) and their backlog. `w check --json`, `w symbols --json`
> and `bin/wtest` remain here. Sections below covering the moved tools
> are kept as the historical design record; their paths refer to this
> repo's layout at the time.

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
2. **`wtest changed`** — map changed files to the smallest useful build
   targets, with `./wbuild tests` as the fallback.
3. **`w-toolchain-mcp`** — a dependency-free stdio MCP server exposing
   build / verify / check / compile / run / run_tests / repl_eval /
   test_changed.
4. **Docs** — a "Tooling for agents" section in the README mapping
   workflows to tools.

Deferred (section "Out of scope" below, each with rationale): LSP server,
`wfmt` (writing mode), semantic indexer + `w-index-mcp`, `w reduce`,
`w inspect`, Tree-sitter grammar, `w-debug-mcp`/DAP, `w-parsergen-mcp`.

## Implementation status

Shipped from the next-steps backlog:

- **`bin/wfixture` arch-selector directive** (2026-07-19): a
  `# wfixture: <selector>` header line (e.g. `# wfixture: x64`) inserts
  `<selector>` into the compiler argv between the compiler path and the
  fixture path, so a fixture that only reproduces under a non-default
  target (`bin/wv2 x64 ...`) can single-source its expectations again
  instead of falling back to a hand-written `expect_fail`/`expect_stderr`
  `build.base.json` step. Does not itself count toward a fixture's
  required directive count — an expect_stderr/reject_stderr/expect_fail
  is still needed to assert anything. Payoff: `cuda_diagnostics_test`'s
  13 hand-written x64-gated gpu/atomics/launch diagnostic steps all
  migrated into their fixtures' own headers (`tests/gpu_call_error_fixture.w`
  and 12 siblings), leaving one `bin/wfixture` invocation over 15
  fixtures; `tests/gpu_x64_required_fixture.w` (no selector — it asserts
  the *default* 32-bit target's gate error) and the migrated fixtures
  together exercise both directions of the mechanism.
  `tools/wfixture.w`.
- **`wexec` single-writer lock on its managed `bin/` directory**
  (2026-07-19, wave 1f): fixes "Two `./wbuild`/`wexec` invocations
  racing in the same worktree corrupt each other's build with no useful
  diagnostic" (a backgrounded `./wbuild test_changed` still compiling
  when a foreground `./wbuild verify` starts in the same worktree used
  to die with a bare "could not open output file" — both processes
  writing/executing the same `bin/wv2`). `main()` now takes an advisory
  lock (`bin/.wexec_lock`, `O_CREAT|O_EXCL`, own pid written inside)
  before running any requested target's steps; a losing invocation reads
  the pid back, and if `kill(pid, 0)` says it's dead (crash, SIGKILL, or
  a direct `exit()` that bypassed `defer`) reclaims the stale lock and
  retries once, otherwise prints `wexec: another build is running in
  this directory (pid N); remove bin/.wexec_lock if stale` and exits 1.
  Scoped per `bin/` directory (relative to cwd), not global. wexec's own
  test harness (`wexec_test` and friends) runs nested `bin/wexec`
  invocations against that same `bin/` as steps of an outer,
  already-locked wexec; the outer process marks `WEXEC_LOCK_HELD=1` in
  the environment on acquire (inherited through `execve`, transitively,
  even through intermediate programs like `bin/wtest`'s own `--run`), so
  a nested wexec sees the marker and skips locking, trusting the
  ancestor. `--list`/`--explain-cache`/`--trace` return before the lock
  is ever taken (out of scope: no steps run, or, for `--trace`, a
  separate manual audit path). Covered by `wexec_lock_test`
  (`build.base.json`; `tests/wexec/lock_scratch.json`), which plants a
  manually-created live/stale pid lock file to stand in for a real
  second concurrent process rather than racing a real backgrounded
  build (which would be flaky to assert against), and runs its nested
  `bin/wexec` invocations through `sh -c "unset WEXEC_LOCK_HELD; exec
  bin/wexec ..."` (not `env -u`, which resolves to a stray non-executable
  `~/.local/bin/env` ahead of the real one on this sandbox's `PATH` — see
  the next-steps backlog's `wexec_resolve_program` entry) so they
  exercise a fresh, non-reentrant acquire instead of inheriting the
  outer test-runner's own lock marker. Design: `docs/projects/wexec.md`'s
  "Locking" section; block comment above `wexec_lock_file` in
  `tools/wexec.w`.
- Portable `lib/stat.w` + Linux `statx`/`chmod`/`utimensat`/`readlink`/
  `symlink` wrappers in `lib/__arch__/{x86,x64,arm64}/syscalls.w`
  (2026-07-19): `file_stat_path` / `file_lstat_path`, mode predicates,
  and thin `file_chmod` / `file_touch` / `file_readlink` helpers.
  `libs/extras/vcs/index.w` now uses `file_stat_path` instead of the
  VCS-scoped `vcs_statx`. Dogfooded by `tools/{stat,chmod,touch,readlink}.w`
  and `stat_test` / `unix_tools_test`. Darwin/win64/wasm stubs return -1.
- Unix metadata/process primitives for wunix (2026-07-19): explicit
  `file_utimens`, `file_chown`/`file_lchown` (`fchownat`),
  `lib/passwd.w` (`/etc/passwd`+`/etc/group`, no NSS), and
  `process_wait_any` for `xargs -P`-style pools. Design:
  `docs/projects/unix_primitives.md`.
- **`wv2 defhash [--closure] <file.w>...`** (2026-07-18, issue #251
  D4a): emits one NDJSON record per top-level definition (function,
  global, struct/union/enum, type alias, generic function, generic
  struct, operator overload) declared directly in the root file(s) —
  `{"file", "name", "kind", "hash", "refs"}` — with `hash` a sha256 over
  the definition's own token stream (whitespace/comments excluded, so
  reformatting leaves it unchanged) and `refs` the other recorded
  definitions it references; `--closure` widens scope to the whole
  compiled program (matching `deps`'s closure). Generic and operator
  coverage shipped 2026-07-19 (wave plan C task 4f) — see the
  "Definition hashing" section below for the full writeup, including the
  `--closure` name lookup's map-based rewrite and the coverage-completion
  cleanup in `bin/wtest`'s `--defhash` consumer. Known limitations:
  `refs` is a token-text match against the definition-name set, not real
  scope resolution (a field/enum-constant name collision or a shadowing
  local reads as a false positive — documented in `defhash_main`'s doc
  comment, accepted as out of D4a's scope); an operator overload's
  synthetic name is never itself a `refs` target (operators are invoked
  through their token, `a + b`, not by name). See `ai_tooling_next_steps.md`
  for the remaining open items.
- **Compiler-wide silent-exit-1 audit (2026-07-18).** Every
  `error(...)` call site funnels through `warning()`/`error()` in
  `compiler/tokenizer.w`, which always prints before exiting; a
  systematic review confirmed all 312 sites (not the ~95 this doc's
  "Current state" section originally estimated) are safe by
  construction, along with every direct `exit()`/`asserts()` call and
  driver-path syscall (`open`/`read`/`write`/`getcwd`/`mmap`) in the
  compile/link/deps/symbols paths. One new gap found and fixed:
  `lib/memory_debug.w`'s `debug_tbl_ensure_capacity()` had 5 unchecked
  bookkeeping-table `mmap()` calls (opt-in debug allocator only), now
  guarded by `debug_tbl_mmap_failed()` with a clear message before
  `exit(1)`. Remaining residue (`getchar()`'s read-error/EOF
  conflation, `lib/generator.w`'s unchecked coroutine-stack `mmap()`,
  unbounded parser recursion, an unrecognized-CLI-flag UX nit, and the
  c_import/preprocessor `diag_part` migration gap) is tracked in
  `ai_tooling_next_steps.md`/the active wave plan. The original
  2026-07-09 darwin-seed silent-exit report itself remains
  unreproduced — most likely explained by the seed-generation skew the
  single-tag `SEEDS` pin (`CLAUDE.md` "Seed promotion") was written to
  eliminate — but confirming it needs the specific stale, unarchived
  `w_darwin` seed from that date, which no longer exists in any
  accessible form.
- **c_import/preprocessor `diag_part` migration (2026-07-19, wave plan
  C task 3d)**, closing the gap the audit above tracked. All 6 sites
  that composed a diagnostic from raw `print_error(...)` fragments
  before calling `error(c"")`/`error(c"'")` — `libs/extras/c_import/
  importer.w`'s `ci_lookup_type` (unsupported C type) and
  `ci_skip_extern_function` (skipped-extern warning), and
  `libs/extras/c_preprocessor/{pp_directives,pp_macro}.w`'s
  include-not-found, `#error`, could-not-read, and invalid-token-paste
  errors — bypassed the JSON funnel: `print_error` always writes
  straight to stderr, so `--json` mode's NDJSON `message` field only
  ever got the final fragment passed to `error()`/`warning()` (verified
  against the pre-migration binary: `""` for three sites, `"'"` for
  `ci_lookup_type`) while the human-readable text landed on stderr
  as before. Migrated every fragment to `diag_part(...)`, which routes
  through the same accumulator `warning()`/`error()` already flush; a
  differential run of the pre- and post-migration compiler over
  crafted repro headers confirms human-mode stderr is byte-identical
  and the JSON `message` now carries the full composed text. Two
  residues logged in `ai_tooling_next_steps.md` rather than fixed here:
  `ci_skip_extern_function`'s warning is gated on `verbosity >= 1`,
  which nothing in the compiler/REPL/`wdbg` ever raises above the `-1`
  every entry point sets it to (dead code pending a `-v` flag), and
  `cpp_preprocess_file_into`'s could-not-read path is a TOCTOU window
  between an existence check and the real read that this sandbox
  cannot trigger deterministically (root bypasses permission bits).
- **`itoa(INT_MIN)`/`intstrlen(INT_MIN)` fixes (2026-07-17).** Both
  pre-negated their input before extracting digits, which overflows
  back to the same negative value for `INT_MIN` in two's complement, so
  the digit loop never ran; fixed by extracting digits from the
  (possibly negative) value directly. `itoa`'s buffer also grew from 16
  to 24 bytes (a 64-bit `INT_MIN` string is 21 bytes with the NUL).
  Covered by `test_itoa_int_min`/`test_intstrlen_int_min` in
  `lib/lib_test.w` (both word sizes via the file's `# wbuild: x64`
  twin).
- **`stream_peek_byte` 0xFF masking (2026-07-17).** `lib/stream.w`'s
  `stream_peek_byte` sign-extended raw bytes, so 0xFF collided with the
  `-1` EOF sentinel and truncated `stream_read_byte`/`stream_read_line`/
  `file_read_text`/`file_read_lines` at the first 0xFF byte; fixed by
  masking (`& 255`). Covered by `stream_binary_test`.
- **`wexec --explain-cache <target>`** and **`wexec --list --json`**
  (2026-07-17): two read-only introspection surfaces on `tools/wexec.w`.
  `--explain-cache` states, without running anything, whether a target
  can ever get a cache key — does it declare `"inputs"`, and does every
  dependency, transitively, also declare `"inputs"` (the same
  `wexec_keys` gate `wexec_cache_key` checks one dependency layer at a
  time)? — and names the specific dependency, and the chain down to it,
  that breaks caching for everything downstream: the documented
  silent-permanent-miss trap where a `deps: [...]` entry without its
  own `"inputs"` disables caching with no diagnostic. `--list --json`
  prints one NDJSON object per target — `name`, `step_count`, `deps`,
  `compile_roots`, `shells_out`, `generate_exclude` — instead of bare
  `--list`'s newline-separated names, which is unchanged. Covered by
  new `wexec_test` cases (`tests/wexec/explain_cache.json`,
  `tests/wexec/list_json.json`).
- `w check` usability triple (2026-07-16): command-line roots dedupe
  against the import registry (multi-root `check w.w
  compiler/compiler.w` and auto-imported-runtime roots like
  `lib/stack_trace.w` no longer report bogus `symbol redefined`);
  check mode drops the `_main` requirement on every backend, so
  main-less library modules check standalone; compiler-internal roots
  (compiler/, grammar/, code_generator/, debugger/) substitute `w.w`
  with a `check: <file> is compiler-internal; checking w.w` stderr
  note. Covered by `check_roots_test`.
- `wexec --keep-going` + early-stop visibility (2026-07-16): failures
  no longer silently cancel umbrella runs — independent subgraphs keep
  running, dependents report as skipped with a summary, and default
  fail-fast mode prints `wexec: stopped early after failure: N of M
  targets not attempted`. Covered by `wexec_keep_going_test`.
- `wtest` empty-selection visibility + focused leaf selection
  (2026-07-16): empty selections print `wtest: 0 targets selected` on
  stderr; `./wbuild test_changed` falls back to the origin/main
  merge-base diff on a clean tree; a build.json diff that is exactly
  wbuildgen-shaped leaf test-target additions/removals selects just
  those targets + `manifest_check` + `wexec_test` (new
  `--base-manifest` flag) instead of the whole `tests` umbrella.
  Covered by `wtest_map_test`/`wtest_run_test`.
- `lib.assert` standalone import fix (2026-07-16): lib/assert.w
  imports lib.lib for the printers it calls; pinned by
  `assert_standalone_test`.
- Import lines accept trailing `#` comments; mid-line tabs are owned by
  the w.pg surface via an opt-in `inline_tabs` skip token (2026-07-16):
  pinned by `import_test`, `midline_tab_test`, and the PG parser tests.
- Literal width guards (2026-07-13, extended 2026-07-16): a hex or
  binary literal with more than 32 significant bits (leading zeros
  don't count) is a compile error instead of silently wrapping
  (`int_literal_width_check()`, `grammar/int_literal.w`) — previously
  the tokenizer kept only a rolling 32-bit window of a literal's
  digits, so on x64 `0x7ff0000000000000` parsed to `0` and
  `0x000fffffffffffff` parsed to `0xffffffffffffffff` with no
  diagnostic. Decimal literals get the same guard
  (`int_literal_decimal_check()`: more than 10 significant digits, or
  exactly 10 comparing above 4294967295, is the same compile error).
  The sweep for newly-rejected literals caught a real casualty: the
  win64 FILETIME epoch offset `11644473600` in
  `lib/__arch__/win64/syscalls.w` had been silently wrapping — win64
  `linux_time()` returned garbage — and is now computed at runtime.
  Covered by `int_literal_width_test`, `tests/int_literal_bounds_test.w`,
  and `tests/warning_clean_fixture.w` (pins the still-legal wide
  spellings).
- `wtest changed --run` (2026-07-16): after printing the selection,
  `wtest` can spawn `bin/wexec` itself with that target list
  (inheriting stdio so build output streams live) and exit with its
  status, instead of a caller piping through `./wbuild test_changed`'s
  `xargs -r ./wbuild`. A companion `-f manifest.json` flag overrides
  the manifest for both selection and, under `--run`, execution — used
  to test `--run` in isolation (`wtest_run_test`,
  `tests/wtest/run_fixture.json`) without recursing through the live
  manifest. `tools/test_map.w`.
- `.txt` doc-only filter no longer swallows runtime fixture data
  (2026-07-16, issue #171): `wtest_doc_only` in `tools/test_map.w`
  treated every `*.txt` path as documentation, so
  `tests/asm/corpus_{x86,x64,arm64}.txt` never reached the `tests/asm/`
  residue rule and `wtest changed` selected nothing for a corpus-only
  change; fixed by excluding `tests/asm/` before the extension check,
  pinned by a `wtest_map_test` case.
- Direct-file UX (2026-07-16, issue #323 stage 1): `./wbuild [selector]
  path/to/file.w` and `bin/wtest for path/... [--run]` now work without
  a `build.json` entry — `wexec` resolves the file to the manifest
  target that already compiles it, or synthesizes a throwaway
  compile(+run, for `*_test.w`) target with the same content-hash
  caching every other cacheable target gets; `wtest for` mirrors
  `changed`'s selection with paths as required positional args instead
  of an optional stdin list. See `tools/wexec.w`'s "Direct-file UX"
  section and `docs/projects/build_system_next.md`'s stage-1 inventory
  for the remaining shell-script/hand-written-target migration roadmap
  (stage 2, not yet scheduled).
- `parser_generator_w_test` batching (2026-07-12, extended 2026-07-16):
  `test_parse_all_tracked_w_files` parsed every tracked `.w` file in
  one process, retaining every AST, so the 32-bit gate segfaulted once
  tracked source crossed ~3.7MB; `tools/parser_generator_w_batches.sh`
  reruns the test binary once per 150-file slice of the manifest,
  bounding memory at batch size (~21s total) rather than freeing
  per-file (which was correct but turned the gate into a 90-CPU-minute
  crawl under the first-fit allocator's quadratic free/malloc
  behavior). That allocator residual is itself fixed by issue #322
  (2026-07-16): `lib/memory_freelist.w` now uses 41 segregated
  size-class bins with O(1) free, so the batching is a memory bound
  only, no longer a speed workaround.
- **`wtest changed` cold-cache progress note** (2026-07-16): the first
  `changed` invocation to touch an import closure after a build (or a
  large merge) prints one `wtest: building import-closure cache (first
  run after a build; this can take a minute)...` line to stderr before
  the `bin/wv2 deps` shell-outs that can otherwise take minutes on a big
  tree with nothing printed — previously indistinguishable from a hang.
  A warm cache stays silent. `tools/test_map.w`.
- **`./wbuild test_changed` flag forwarding + `wtest --available`**
  (2026-07-16): flags after `test_changed` (e.g. `--keep-going`) now
  reach the final `./wbuild` invocation instead of being swallowed by
  the hard-coded `xargs -r ./wbuild` pipeline. `bin/wtest` also gained
  an opt-in `--available` flag that drops selected targets whose runner
  (`qemu-aarch64-static`, `wine`/`wine64`, a `tools/mac/` script) is not
  present on the host, printing a `wtest: dropped N unavailable
  target(s) (<reason>)` line per reason; `./wbuild test_changed` passes
  `--available` by default, so a printed selection is runnable as-is.
  `tools/test_map.w`, `wbuild`; pinned by `wtest_map_test` cases.
- **`wtest_map_check` `noorder` opt-out** (2026-07-16): a `-f`
  fixture-manifest case can add a `noorder` line to skip the checker's
  implicit "selected names are real `build.json` targets, in
  `build.json`'s relative order" properties, so a fixture-only case can
  use self-descriptive target names instead of being forced to reuse
  real ones. `tools/wtest_map_check.w`.
- **`wexec --ordered-output`** (2026-07-16): under `-j` > 1, buffers
  each target's whole captured stdout/stderr and prints it as one
  atomic block headed by `wexec: --- <target> ---` in completion order,
  instead of the default start-order live streaming that could
  interleave a finished target's output next to an unrelated target's
  failure and misattribute the failure during fixture debugging.
  Default (streaming) output is unchanged; composes with
  `--keep-going`. `tools/wexec.w`.
- **`w check --imports`** (2026-07-16): opt-in warning for the
  transitive-import-reliance failure class (#145, #147) — an
  unqualified identifier that resolves to a global symbol whose
  declaring module is neither the referencing file itself, one of its
  direct imports, nor the auto-imported container-runtime closure now
  warns `symbol 'X' resolves through a transitive import (defined in
  '<module>'); import it directly`. Off by default, so plain
  `check`/build output is unchanged. `compiler/compiler.w`,
  `grammar/import_statement.w`, `compiler/symbol_table.w`; covered by
  `check_imports_test`.
- `--quiet` flag (2026-07-10): `w check --json --quiet file.w` (and any
  other invocation carrying `--quiet`) suppresses the non-diagnostic
  stderr chatter — the per-file `compiling '...'` banner, the
  `Compiling in <target> mode` banner, and the
  `using filename as path directly:` notice — so hook/LSP/MCP consumers
  get pure NDJSON on stdout and an empty stderr on clean files.
  Diagnostics are never suppressed. Covered by `check_json_test`.
- Bit-31 literal warning (2026-07-10, #249 stage 5): a hex or binary
  literal with bit 31 set warns
  (`integer literal has bit 31 set and sign-extends to a negative int
  on every target; use cast(int, ...) if the bit pattern is intended`)
  at the literal, since it sign-extends into the word-sized `int` on
  every target (`0xffffffff` is `-1` even on x64). `cast(T, ...)`
  operands are exempt — `cast(int, 0xd503201f)` is the idiom for an
  intentional 32-bit pattern (used by `libs/asm/arm64_*.w` and the
  float-bits tests). Covered by `warning_test`
  (`tests/bit31_literal_warning_fixture.w`).
- Bool-bitwise condition hint (2026-07-10, widened default 2026-07-17):
  `|`/`&` joining two bool-typed or comparison-result operands inside an
  if/while condition warns by default
  (`bitwise '|' on bool operands in a condition does not short-circuit;
  did you mean '||'?`, same shape for `&`/`&&`) whenever both operands
  are call-free — that is exactly the subset where converting to
  `&&`/`||` is semantics-preserving, since short-circuiting a
  call-containing operand could skip a call the current `&`/`|` code
  always executes. Call purity is tracked with a global call counter
  (`emitted_call_count`, bumped by `code_generator/x86.w`'s `call_eax`
  and `code_generator/ffi.w`'s `emit_ffi_call_inline`) snapshotted
  around each operand's parse (`grammar/binary_op.w`'s
  `operand_is_pure`). `w check --bool-ops` is now the narrower
  "also report call-containing joins" superset (2026-07-10 through
  2026-07-17 it gated the comparison-result widening itself; the
  wave-2 mechanical sweep converted every side-effect-free site
  tree-wide, so that gate became the unconditional default). A
  same-precedence chain of 3+ terms now gets a diagnostic per
  qualifying pairing, and every diagnostic's line/column point at the
  `&`/`|` operator itself rather than wherever the tokenizer's
  lookahead lands once the whole condition finishes parsing. Covered by
  `warning_test` (`tests/bool_bitwise_warning_fixture.w`,
  `tests/bool_bitwise_chain_fixture.w`) and `check_bool_ops_test`
  (`tests/bool_ops_warn_fixture.w`, `tests/bool_ops_clean_fixture.w`).
- Missing-file diagnostics (2026-07-10, #190): the compiler's
  file-not-found path no longer serializes a freed path buffer — the
  garbled `check --json` `file` field and the garbled
  "abandoning search in" stderr are gone. Top-level inputs (command
  line, REPL/wdbg targets) fail fast with `no such file: '<path>'`
  and no upward directory walk; a failed import search reports one
  `cannot locate '<module path>'` line pointing at the importing
  file's import statement, with the per-directory retry spam moved
  behind `verbosity >= 1`. Covered by `missing_file_test`.
- Manifest generation for conventional test targets (2026-07-10):
  `build.json` is now generated (still committed) by `tools/wbuildgen.w`
  from the hand-maintained `build.base.json` plus every `*_test.w`
  source under tests/, lib/, structures/, graphics/, libs/ and tools/
  (a `# wbuild: x64` directive in the source adds the 64-bit twin), so
  adding a plain test is creating one file and running
  `./wbuild manifest` instead of hand-editing a 3000-line manifest.
  `./wbuild manifest_check` (a `tests` member, following
  `metadata_check`) fails on drift, and `bin/wtest` maps
  `build.base.json`, `tools/wbuildgen.w` and every `*_test.w` change to
  that gate. Design: the "Manifest generation" section of
  `docs/projects/wexec.md`.
- Array-to-pointer decay (2026-07-10): passing a fixed array or slice
  where a `T*` (or `void*`) parameter, assignment, initializer, return,
  container key/element, membership key, or switch case expects a pointer
  now passes the descriptor's data pointer, matching C decay semantics
  (`type_decays_to_pointer` in `compiler/type_table.w`, decay emission in
  `coerce()`), instead of warning and emitting the descriptor's own
  address — which let callees overwrite the {data-pointer, length} header
  (the #113 corruption). Covered by `array_decay_test` /
  `array_decay_64_test`. Three narrower edge cases were consciously left
  out (C-variadic tails, `cast(int, arr)` vs `cast(char*, arr)`, and one
  arm of a conditional expression) — none corrupt memory, tracked in
  issue #229.

The MVP described here has landed:

- `w check [--json]` compiles to `/dev/null` and emits NDJSON diagnostics
  in JSON mode while keeping default human diagnostics byte-compatible.
- `tools/test_map.w` builds to `bin/wtest`; `wtest changed` and
  `./wbuild test_changed` map changed paths to focused build targets.
- `bin/wtest`'s target registry is parsed from `build.json` at startup
  (manifest order, catch-all `tests` forced last), replacing the
  hand-maintained list in `wtest_init_targets()` that silently drifted
  when a target was added only to the manifest (July 2026).
- `tools/mcp/w_toolchain_mcp.w` builds to `bin/wmcp`, a W-native stdio MCP
  server registered by `.cursor/mcp.json`. (It began life as stdlib-only
  Python and was ported to W once `lib/process.w` landed.)
- README agent tooling guidance and regression targets (`check_json_test`,
  `wtest_map_test`, `mcp_test`) are wired into `./wbuild tests`.
- `tools/wfixture.w` builds to `bin/wfixture` (2026-07): pure
  compile-diagnostic fixture targets (`warning_test`,
  `type_system_error_test`, `type_system_warning_test`,
  `array_error_test`, `buffer_field_assign_test`) single-source their
  frozen message text as `# expect_stderr:` / `# reject_stderr:` /
  `# expect_fail` directives in the fixture headers, LLVM-lit style,
  instead of `expect_stderr` fields on `build.json` steps; substring
  semantics match wexec's exactly. Targets that also run the produced
  binary keep their step-field expectations.
- `lib/testing.w` test discovery is a compiler-synthesized static
  registry (`compiler/test_registry.w`, issue #147): `__w_test_main`
  calls each defined zero-argument `test_*` function in definition
  order, so discovery works on ELF, Mach-O, and PE alike and survives
  stripped binaries. It replaced the ELF section-header walk that
  aborted natively on arm64_darwin ("No symbol table addr") and the
  per-arch `lib/__arch__/*/elf_introspect.w` modules.
- **`w deps [--json]`** (2026-07-10): prints a program's transitive
  import closure — root, imports, auto-imported container runtime —
  one repo-relative path per line (NDJSON `{"file": ...}` records with
  `--json`), by running the `check` front-end and recording every file
  the compiler opens. Asserted by `deps_test`. Default target only,
  like `check`.
- **`wtest changed` selection is manifest-driven** (2026-07-10):
  building on the manifest-parsed registry above, the per-path mapping
  rules themselves now come from `build.json`, which resolved three
  more backlog entries.  *Unmapped paths*: any target whose steps name a
  changed path (fixtures, scripts, data) or whose compile roots'
  import closures (via `bin/wv2 deps`, content-hash-cached in
  `bin/.wtest_deps_cache`) contain a changed `.w` file is selected, so
  e.g. `tools/test_map.w` now maps to `wtest_map_test` instead of the
  full suite. *`.w` diffs → `parser_generator_w_test`* (the PR #151
  escape) and *deleted modules → `metadata_check`* (the #145 escape)
  are blanket residue rules; the remaining residue rules (compiler
  tree → `verify`, `lib/__arch__/`, `graphics/`, c_import machinery,
  run-time fixture data) are documented at the top of
  `tools/test_map.w`.
- **`wtest archs <file>... [--check]`** (2026-07-19, wave plan C task
  3e): closes the "import breaks a different compile target" gap —
  `tools/wexec.w` is compiled three ways (default `x86`, `win64`,
  `arm64_darwin`), and an import that resolves for one arch's `lib/
  __arch__/` tree but not another's (e.g. a `lib.net` call with no
  `lib/__arch__/win64/syscalls.w` counterpart, "Cannot find symbol:
  'sys_socket'") used to compile clean under a plain `w check` and only
  fail at that target's next full build. `wtest archs` enumerates every
  distinct `(arch, root)` pair whose manifest-recorded compile root is
  the file itself or whose `bin/wv2 deps`-computed closure (shared
  cache, `bin/.wtest_deps_cache`) contains it, one line per pair with
  the owning target(s) for context; `--check` additionally runs
  `bin/wv2 [arch] check <root>` per distinct pair (root-deduped, not
  per target) and reports pass/fail, so the break is visible pre-build.
  Root discovery does not filter `wtest_never_emit` targets the way
  `changed`/`for` selection does (that filter is about which targets
  this host can *run*, not which archs exist) and recognizes
  `bin/wv2_darwin` as a compiler program alongside `bin/wv2`/`./w`, so
  `wexec_darwin`'s `arm64_darwin` root — otherwise invisible, since it
  is the only target that compiles a non-`w.w` root with that selector
  through a program other than plain `bin/wv2` — is included.
  `tools/test_map.w`; `wtest_archs_test` (synthetic manifest + a tiny
  `__arch__`-dispatched fixture with no `win64` implementation,
  modeling the incident above at unit-test scale).

The out-of-scope items at the end of this document remain deferred; the
living backlog (deferred items plus friction found while dogfooding) is
`docs/projects/ai_tooling_next_steps.md`, kept current by agents per
`.cursor/rules/ai-tooling-feedback.mdc`.

## Post-MVP: agent-side configuration (implemented)

The MVP built the tools; a follow-up made agents actually reach for them
by committing the agent-facing configuration Cursor reads from the repo:

- **Edit hook**: `.cursor/hooks.json` registers a `postToolUse` command
  hook (`.cursor/hooks/check_after_edit.sh`) that bootstraps
  `tools/hooks/w_check_hook.w` → `bin/whook` and pipes the payload
  through. After any agent edit to a `.w` file the hook runs
  `./bin/wv2 check --json` and emits
  `{"additional_context": "<diagnostics>"}`, so the agent sees compiler
  feedback without being asked. Compiler-tree modules are checked through
  `w.w` (they do not compile standalone), `*fixture*` paths are skipped
  (their diagnostics are intentional), non-edit tools and non-`.w` paths
  produce `{}`, and every failure path fails open. `postToolUse` is used
  rather than `afterFileEdit` because only the former has a documented
  context-injection output field, and both run in Cloud Agents.
  Asserted by `hook_test` (`build.json`, in the `tests`
  umbrella; `tools/hooks/`, `.cursor/hooks*` map to it in `wtest`).
- **Skills**: `.cursor/skills/{w-check-diagnostics,w-select-tests,
  w-debug-wdbg,w-repl-explore}/SKILL.md` — task-scoped SOPs for
  structured diagnostics, focused test selection, scripted `wdbg`
  debugging, and scripted REPL exploration.
- **Rules**: `.cursor/rules/{w-source,compiler-core,tests-and-fixtures}.mdc`
  — glob-scoped guardrails that auto-attach when the agent touches W
  sources, the seed-compiled compiler tree, or tests/fixtures.
- **AGENTS.md**: gained a directive "Tooling for agents" edit loop
  (check → wtest → full suite; symbols/repl/wdbg instead of
  grep/throwaway files/print debugging), since AGENTS.md is the one file
  injected into every agent session.
- **Bootstrap friction**: `./wbuild` creates `bin/` and self-bootstraps
  `wv2` for every target, so the documented commands work from a fresh
  clone without ceremony.
- **MCP caveat**: the committed `.cursor/mcp.json` works in the Cursor
  IDE, but Cloud Agents only load MCP servers registered in the Cloud
  Agents dashboard — documented in the README, with the shell commands
  as the cloud-side equivalent.

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
  changed file to its targets; agents run `./wbuild tests` (~all targets) or
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
only" by the presence of records, not the exit code. With `--strict`
(accepted by `w`, `w check`, and `w symbols`), warnings are promoted to
a failing exit: after the compile the driver prints
`error: N warning(s) treated as errors (--strict)` and exits 1 before
any output is written. The self-host build stages (`./wbuild build`,
`./wbuild build`) compile with `--strict`.

### Output format

One JSON object per line (NDJSON) on **stdout**, emitted as each
diagnostic fires. NDJSON rather than a JSON array because `error()`
terminates the process at the first error: every record already written
is complete and parseable, no closing bracket needed.

```json
{"file": "tests/warning_fixture.w", "line": 12, "column": 9, "severity": "warning", "message": "assignment type mismatch: expected 'char*', got 'int*'", "token": "=", "arch": "x86"}
```

- `line`, `column`: 1-based, from the current token's start position.
  `column` counts codepoints, not bytes: a multi-byte UTF-8 character
  earlier on the line advances it by one (#287 stage 1, 2026-07-16).
  All-ASCII lines are unaffected. The tokenizer's `byte_offset` /
  `token_start_offset` stay byte-exact (`grammar/generic.w` re-seeks by
  them); human output has no column and is unchanged.
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
- A local JSON string escaper (`\"`, `\\`, control characters as
  `\u00XX`). Deliberately **not** `structures/json.w`: that would pull
  hash_map and array_list into the compiler binary to escape one string,
  and the diagnostics module should stay dependency-free so `repl.w` and
  `wdbg` inherit it trivially. Since #287 stage 1 it also guarantees the
  emitted NDJSON is always valid UTF-8 (and therefore valid JSON): bytes
  >= 0x80 pass through raw only as part of a well-formed UTF-8 sequence;
  any stray byte reflected into `message`/`token`/`file` from invalid
  source input is escaped as `\u00XX` (its byte value). Guarded by the
  `check_json_utf8_test` target via `tests/ndjson_utf8_validator.w`.

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
Makefile, read stdin, print). W could not spawn `git` or `make` at the
time, so the tool *prints* targets and a build target does the
orchestration:

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
   - `docs/*`, `*.md`, `*.txt` → nothing
4. **Fallback**: any other file → `tests`.

Output: unique targets, one per line, in Makefile declaration order.
`--verbose` prints `file -> target` explanations to stderr. Reading file
names from arguments (`./bin/wtest changed a.w b.w`) works the same as
stdin, for MCP use.

## C. `w-toolchain-mcp`

`tools/mcp/w_toolchain_mcp.w` (built by `./wbuild wmcp` to `bin/wmcp`): a
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
| `build` | — | `./wbuild build` |
| `verify` | `arch?` | `./wbuild verify` / `./wbuild verify_x64` |
| `run_tests` | `targets: string[]` | `./wbuild <targets>` (names validated against `^[a-z0-9_]+$`) |
| `check` | `file, arch?` | `./bin/wv2 check --json [x64] <file>`, NDJSON parsed into a diagnostics array |
| `compile` | `file, arch?, output?` | `./bin/wv2 [x64] <file> -o <output>` |
| `run` | `path, args?, stdin?` | the binary, output captured |
| `repl_eval` | `entries: string[]` | pipes entries + `:quit` to `./bin/repl` |
| `test_changed` | `files: string[]` | `./bin/wtest changed <files>`, returns target list |
| `escape_hatch` (debug only, off by default) | `tool_call_name, parameters?, description?` | logs one NDJSON line to stderr, echoes the arguments back with an empty `result`; never dispatches to a real handler |

Convenience: tools that need `bin/wv2` trigger `./wbuild build` once when it
is missing, so a fresh clone works without ceremony.

`escape_hatch` exists to probe "what if this tool existed" for a
theoretical/not-yet-built compiler tool without wiring up a real handler
first. It is absent from `tools/list` and unreachable by name unless the
server's environment sets `W_MCP_ESCAPE_HATCH` to a non-empty value other
than `0` (`mcp_escape_hatch_enabled()` in `tools/mcp/w_toolchain_mcp.w`).
`bin/wmcp` also works as a one-shot CLI — `./bin/wmcp call <tool>
['<json-arguments>']` — which runs any tool (including `escape_hatch`,
once enabled) through the same dispatcher without a JSON-RPC client.

Registration is committed as `.cursor/mcp.json`:

```json
{"mcpServers": {"w-toolchain": {"command": "sh", "args": ["-c", "./wbuild wmcp >&2 && exec ./bin/wmcp"]}}}
```

The registration builds the server from source before launching it, so a
fresh clone works without ceremony; the build log goes to stderr because
MCP owns stdout.

## D. Documentation

- README gains a **"Tooling for agents"** section: which tool for which
  workflow (`w check --json` to diagnose a file, `./wbuild test_changed` /
  `wtest changed` to pick tests, the MCP server for programmatic access,
  `./wbuild verify` before merge as always), plus the first-error-only
  limitation of `check`.
- This document is updated per phase from plan to implemented, in the
  style of `docs/projects/repl.md`.
- `docs/mvp.txt`'s "Structured diagnostics / formatter / editor tooling"
  line splits into done/remaining parts when phases land.

## Testing

New build targets, wired into the `tests` umbrella:

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
  diagnostics) end to end. It also asserts `escape_hatch` is absent from
  `tools/list` and unreachable by name on a default-env server, then
  spawns a second server with `W_MCP_ESCAPE_HATCH=1` and calls
  `escape_hatch` end to end.

Regression gates for every compiler-touching commit: `./wbuild verify`
(self-host fixpoint), `warning_test` + `type_system_*_test` +
`self_host_warning_test` (human text frozen), and full `./wbuild tests`
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
| Target mapper recommends/runs focused tests | `wtest changed` + `./wbuild test_changed` (B) |
| MCP exposes build/verify/compile/run/warning-test/REPL | `w-toolchain-mcp` (C); warning-test runs via `run_tests(["warning_test"])` |
| Docs explain which tool to use | README section (D) |
| Semantic indexer / `w-index-mcp` | `bin/windex` (`tools/index/w_index.w`) and `bin/wimcp` (`tools/mcp/w_index_mcp.w`); see `docs/projects/semantic_index.md` |
| LSP hover/references/rename | `bin/wlsp`, see `docs/projects/lsp.md` |
| `w-debug-mcp` | `bin/wdmcp` (`tools/mcp/w_debug_mcp.w`); see `docs/projects/debug_mcp.md` |

## Out of scope for the MVP (deferred, with rationale)

- **LSP server**: since built — `bin/wlsp` (`tools/lsp/w_lsp.w`) is the
  thin adapter described here: `w check --json` on open/save translated
  to `publishDiagnostics`, plus go-to-definition over `w symbols --json`
  (globals, functions, and user types only). See `docs/projects/lsp.md`.
- **Semantic indexer / `w-index-mcp`**: since built — `bin/windex`
  (`tools/index/w_index.w`) layers cross-file references, callers/
  callees, struct fields, and imports over `w symbols --json` plus a
  textual scan, and `bin/wimcp` (`tools/mcp/w_index_mcp.w`) exposes it
  as `find_symbol`/`find_references`/`get_type`/`get_struct_fields`/
  `imports_for`/`callers`/`callees`/`changed_file_test_targets`. See
  `docs/projects/semantic_index.md` for the exact contract and known
  gaps (textual reference finding, indentation-approximated call spans).
- **`wfmt` (writing mode)**: the two style warnings (spaces indentation,
  missing trailing newline) already surface through `check`; a rewriting
  formatter needs a lossless token stream the single-pass tokenizer does
  not keep.
- **`w reduce`, `w inspect`**: conveniences, not enablers; `w inspect`
  is mostly `readelf`/`objdump` wrapping.
- **Tree-sitter grammar**: valuable for editors but external to this
  repo's toolchain; no other MVP piece depends on it.
- **`w-debug-mcp`**: since built — `bin/wdmcp` (`tools/mcp/w_debug_mcp.w`)
  keeps a real interactive `wdbg` session alive across MCP tool calls
  (`debug_start`/`debug_send`/`debug_stop`), unlike the one-shot
  subprocess-per-call shape of `w-toolchain-mcp`/`w-index-mcp` — needed
  once an agent workflow (diagnosing a live crash) actually wanted
  programmatic stepping. DAP proper remains out of scope; see
  `docs/projects/debug_mcp.md`.
- **`w-parsergen-mcp`**: ParserGenerator exists, but no agent workflow
  needs it programmatically yet.

## Risks and mitigations

- **Self-host fixpoint breakage**: every compiler change is gated on
  `./wbuild verify`; diagnostics code is compile-time-only and deterministic.
- **Seed compatibility**: new compiler modules are compiled by the
  committed seed `./w` on every `./wbuild build`; `compiler/diagnostics.w`
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
