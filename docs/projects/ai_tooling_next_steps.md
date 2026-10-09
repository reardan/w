# AI Tooling — next steps

A living backlog for the agent-facing toolchain surfaces in this repo
(`w check`, `w symbols`, `bin/wtest`, skills/rules). The implemented
baseline is documented in `docs/projects/ai_tooling.md`. The integrations
built on these surfaces (`wlsp`, the MCP servers, `windex`, the
edit-check hook) moved out of this repo in July 2026; their backlog
moved with them.

**How this file is maintained** (enforced by
`.cursor/rules/ai-tooling-feedback.mdc`): when an agent or contributor
using the tooling hits friction, a bug, or a missing capability, they add
a short entry here (symptom, where observed, suggested direction) in the
same PR. When an item ships, its summary moves to the status section of
`ai_tooling.md` and the entry is deleted here. Keep entries terse; this
is a queue, not an archive.

## Diagnostics (`w check`)

- **Compiler-directory test roots are silently replaced (2026-10-07).**
  `w check --json compiler/type_table_test.w` checks `w.w`, so a clean
  result missed an unsafe allocation in the standalone test. Exempt
  standalone `*_test.w` roots from the compiler-internal root mapping,
  or expose an explicit option to check the supplied root.


- **`--json` codes, spans and related notes: what C3.2 left (2026-10-06).**
  Records now carry `code`, `end_line`, `end_column` and `related`
  (`docs/projects/lint.md` "JSON output"). Open: (a) related notes
  cover only "Cannot find symbol", the redefinitions, `:=` and the
  argument/return type mismatches. An unknown struct field could point
  at the struct, a duplicate label or import alias at the first one, and
  arity warnings at the callee, but the AST-mode arity replay
  (`ast_expression_replay_warning`) carries no callee symbol and
  `ast_expression_test` requires identical records from both front
  ends, so arity notes wait for that event to carry it. (b) The
  span is the reported token's. The plan also asked for a retained
  node's end "where one is live", but no closed node covers a
  diagnostic when it fires: expressions are retained after emission and
  an error exits during it. That needs tree-then-emit (checkpoint B).
  (c) Many diagnostics fire at the token after their construct (a
  `return` mismatch at the next line's first token, a redefinition at
  the `:`), so the span is accurate to the location but not the
  construct.

- **A `:=` local is reported unused at the following token (2026-10-06).**
  `int main():\n\tx := 1\n\treturn 0` under `w check --lint` reports
  `unused-local` at 3:2 (`return`), not 2:2. `:=` declares the symbol
  after parsing the initializer, so `sym_declare` records the token
  after it; the retained forest already keeps the name's position, and
  C3.2's related notes use a `--json`-only side table
  (`sym_note_inferred_location`). Fixing the record moves the human
  lint location, so it needs its own change with fixture updates.

- **Bool return coerces an already promoted integer twice (2026-10-03).**
  `bool truth(int n): return n` emits a second load through the integer
  value and crashes for `truth(7)`. Reproduced with both streaming emission
  and the saved compiler preceding AST return-node work. `coerce`'s bool
  branch calls `promote(got)` after the return parser already promoted the
  value; audit other coercion callers when fixing the value-type convention.

- **Color diagnostic test inherits `NO_COLOR` (2026-10-03).** Running
  `./wbuild tests` from an agent shell with `NO_COLOR=1` fails
  `did_you_mean_test`'s forced-color assertion: the inherited variable
  correctly overrides `FORCE_COLOR=1`. The target passes with `NO_COLOR`
  unset. Isolate the forced-color step's environment while retaining the
  separate assertion that `NO_COLOR` wins.

- **Missing implicit string-coercion helper (2026-10-03).** A standalone
  `list[string]` consumer pushing a C string without importing `lib.lib`
  fails with `Cannot find symbol: ')'`: coercion needs `str_from_cstr`,
  but the diagnostic names the current closing token. Name the missing
  helper and its supplying import, or load that helper lazily. Observed
  in the streaming baseline while adding AST list-method coverage.

- **Nested array descriptors in arrays of structs (2026-10-03).** During
  AST differential testing, `struct R: int[3] items` followed by local
  `R[2] records; records[1].items[2] = 64` (on separate W lines) checked
  cleanly but trapped with length zero in both compiler paths. Initialize
  embedded descriptors recursively or diagnose unsupported layouts. While
  inspecting that failure with `wdbg`, `p values[0]` for another local array
  failed with `type parameter name expected, found '0'`; cover fixed-array
  local evaluation in debugger regression tests. The same failure occurs
  for `p counts[8]` on a local map in
  `tests/ast_map_default_expression_fixture.w` (`counts.length` evaluates
  correctly); include container indexing in that coverage.

- **Multi-file `w check` shares one compilation unit, so two root
  programs cannot be checked in one invocation.** Observed 2026-08-07
  (shell-mode stage 4): `bin/wv2 x64 check --json
  tests/shell_commands_test.w repl.w` fails with `symbol redefined:
  'main'` — the second file's diagnostics are then wrong (the error
  is an artifact of accumulation, not of either file). The
  accumulation is what makes "skipping 'lib/x.w' (already compiled)"
  work for a library list, so the fix is not to isolate every file;
  cheap direction: reset (or fork) the unit at each ARGUMENT that
  declares `main`, or at least say "consider checking these roots
  separately" in the diagnostic. Workaround: one `check` invocation
  per root program.
- **Diagnostic position is the *reported* token, so the new caret can
  point one line past the offending code.** Observed 2026-08-07 right
  after the caret landed (#426): `int x = "hello"` on line 2 reports
  `... in file.w:3` with the caret under line 3's `return 0`. The line
  number itself is unchanged (fixtures have pinned `:3` all along) —
  the caret just makes the pre-existing imprecision visible: the
  single-pass compiler raises the diagnostic after the initializer's
  value is complete, by which time the current token has advanced past
  the newline. Direction: capture the token position at the START of
  the construct being diagnosed (the tokenizer already tracks a token
  start; `diag_token_line`/`diag_token_column` are set from the current
  token) and report from that, at least for initializer/assignment
  mismatches. Changing it moves pinned `file:line` needles in the
  fixture battery, so it is its own unit, not a caret follow-up.
  Started in #377's rustc-style pass: `struct field 'x' not found` now
  saves the member's own position and reports there (the pattern
  `warn_bool_bitwise_at` in grammar/binary_op.w already used); the
  other constructs still report at the token after.

- **Multi-error reporting.** The compiler stops at the first error
  (single-pass, no recovery). Documented limitation; real fix is parser
  recovery, which stays a research project. Cheap partial win: after an
  error in file A, agents re-check to find errors behind it — nothing to
  build, just keep the limitation documented in skills.
- **`T* + int` is a raw, unscaled byte offset for every pointee width,
  and nothing warns — the rule is now documented, and the ergonomic
  intrinsic half has shipped; the warning half has not.** Found
  2026-07-16 writing `libs/extras/compress/
  inflate.w`'s dynamic-Huffman block decoder: `wh_build(c, dist_huff,
  lengths + hlit, hdist)` (where `lengths` is `int*`) added `hlit`
  *bytes* to the pointer, not `hlit` ints — landing 4 (or 8, on x64)
  times too close to the start of the array on every word size, so the
  distance-code Huffman table silently built from the wrong slice.
  `./bin/wv2 check` reports nothing (it is well-typed: `int* + int ->
  int*`); the bug only surfaced as a runtime
  over-subscribed/incomplete-Huffman-table failure, and only for inputs
  exercising that exact code path (fixed-Huffman and simple dynamic
  blocks with `hlit`/small offsets near zero happened to still work).
  `lib/sha256.w` and every other manual-pointer-arithmetic call site in
  the tree already route around this by treating every pointer as
  `char*` and multiplying the index by the element size by hand
  (`p + i * 4`), which works but has no compiler backing — a typed
  `int*`/struct-pointer `+` is silently just as wrong as a `char*` one
  with a forgotten `* width`. `a[i]`/`&a[i]` *do* scale correctly (this
  is what made the bug non-obvious: indexing and "pointer plus offset"
  look interchangeable but are not). README.md/CLAUDE.md now document
  the rule explicitly (2026-07-17), citing `lib/sha256.w`'s `p + i * 4`
  idiom above. **Shipped (2026-07-19):** `lib/ptr.w`'s
  `ptr_add[T](p, n)` — a generic function, `return &p[n]`, so it
  inherits the compiler's already-correct indexing scale for any `T`
  with no `sizeof`/`__word_size__` bookkeeping needed in the caller —
  plus `ptr_diff[T]`, covered by `tests/ptr_add_test.w`
  (int/char/struct pointees, negative offsets, an explicit assertion
  that `ptr_add` and raw `p + n` disagree). The exemplar `inflate.w`
  bug site and two similar `char*` call sites in
  `libs/extras/compress/{inflate,deflate}.w` now use `&p[n]` directly.
  Still open: `./bin/wv2 check` still reports nothing on the raw `T* +
  int` form itself — a `w check` warning on
  `<non-char-pointer> + <int-not-a-multiple-of-known-stride>` is
  unrealizable statically in general, and nothing stops new code from
  writing `p + n` instead of reaching for `ptr_add`/`&p[n]`. The footgun
  is now avoidable, not eliminated.
- **An option flag before a subcommand is silently read as a source
  file.** Observed 2026-08-08 (compiler-performance measurement):
  `bin/wv3 --quiet check f.w` does not check anything — it dies with
  `no such file: 'check' in check:1` and exit 1, having compiled the
  auto-imported prelude first. Target selectors may precede the
  subcommand word (`w x64 check f.w`, handled in `w.w`'s `main`), so
  the asymmetry is easy to walk into when scripting, and the
  diagnostic names the subcommand as if it were a path rather than
  saying the flag came too early. It cost a whole batch of scripted
  measurements that silently reported prelude-only timings. Either
  accept global flags before the subcommand, or special-case a
  known-subcommand word appearing after a flag and say so.
  The AST suite audit (2026-10-03) also hit
  `check --ast-full-expressions --json f.w`: the AST flag ends the
  leading check-option scan, so `--json` becomes unrecognized. Appending
  the whole-program AST flag after the file list works; shared option
  parsing should allow global and subcommand flags to interleave.

- **`symbol redefined: 'X'` does not say where the first definition
  is.** Writing a new test with a plain `int main()` — the shape every
  non-test program uses — gets `symbol redefined: 'main'` pointing at
  the *new* one, with nothing to say the winner came from
  `lib/testing.w`, which supplies `main` and dispatches to `test_*`
  functions. The fix is a grep away once you suspect an import, but the
  message is one clause short of not needing the grep: it already has
  the previous record (that is how it detected the clash), so it could
  append `(first defined at <file>:<line>)` the way the
  declaration-location fields in `compiler/symbol_table.w` already
  allow. Worth doing for every redefinition, not just `main`.

- **`int32*` passes silently where `int*` is expected.** Observed
  2026-09-25 (#379 runtime fonts): `int32 gx; place(..., &gx)` with
  `int place(..., int* x)` checks clean on every arch, and on x64 the
  callee's 8-byte store overruns the 4-byte local into its stack
  neighbours. Found by review, not by `check` or the tests (the
  neighbour happened to be dead). Direction: a warning for passing or
  assigning a pointer whose pointee width differs from the target's
  (`int32*` vs `int*`, `char*` vs `int*`), at least where the pointer
  is `&local`; `cast(...)` stays the explicit opt-out.

- **`w check` (and every compile) SIGSEGVs on a `type ... = fn(...)`
  alias with more than 10 parameters.** Observed 2026-09-24 (cuBLAS
  workstream, `type g = fn(char*, int, ... 14 params) -> int` for
  `cublasSgemm_v2`): `grammar/type_alias_declaration.w` mallocs a
  10-slot parameter buffer and writes past it with no bound check, so
  the heap corrupts and the compiler dies later in an unrelated
  `malloc`/`free` (crash site depends on heap layout: 12+ params crash
  once `lib.lib` is imported, 14 did not crash in a bare file). The
  stack trace points nowhere near the alias. Direction: grow the buffer
  (or size it to `extern_max_params()`) and emit a real diagnostic past
  any cap. Workaround used: lib/dlcall.w's argv-form trampoline
  (`dl_trampoline_argv` + `dl_call`), one `int*` parameter.

## Test selection (`bin/wtest`)

- **Extra steps on architecture-only tests (2026-10-07).** Adding a native ABI
  fixture step after `arch_only=x64` in `sql_native_test.w` makes manifest
  generation fail because `step=` requires a default-arch target. Allow extra
  steps on the selected architecture; currently a separate source-owned target
  depending on the architecture-only test is required.

- **Expected-failure import fixtures cause repeated closure warnings (2026-10-04).**
  During wc2 retirement, `wtest changed` and `wtest archs` retried
  `bin/import_path_shaped_fixture.w`, whose invalid `import lib/assert.w` is
  intentional. `wtest why` treats `lib/assert.w` as a missing import that is
  now present, making the failure entry immediately stale. Distinguish malformed
  import diagnostics from missing files, and account for expected-failure compile
  steps when reporting closure failures; retain conservative test selection.

- **Color diagnostic fixtures inherit `NO_COLOR`.** Observed 2026-10-03
  while running the VM changes through `./wbuild tests`: the
  `did_you_mean_test` step sets `FORCE_COLOR=1` but fails when an agent
  environment already exports `NO_COLOR=1`. The compiler correctly gives
  `NO_COLOR` precedence. Have the force-color fixture explicitly unset
  `NO_COLOR`; workaround: `env -u NO_COLOR ./wbuild tests`.

- **Shipped (2026-08-04): cold deps-cache cost is now visible and
  payable up front.** (Logged 2026-07-29, crash-trace unit: a cold
  `bin/wtest changed` build exceeded 20 minutes wall on a loaded
  4-core container and was killed at a 10-minute tool timeout; the
  resume worked, but agents under per-command timeouts paid two long
  runs blind.) The cold-build progress line now carries elapsed wall
  time and an extrapolated time-left estimate ("20/370 roots
  computed, 90s elapsed, ~26m left"), and a manifest-driven
  `./wbuild wtest_cache` pre-warm target (`bin/wtest cache`, a
  `tool_targets` entry) builds `bin/wtest` and warms
  `bin/.wtest_deps_cache` for every root — the archs superset plus
  the seed `w.w` roots per arch — so CI and fresh checkouts can pay
  the cost once, deliberately (`wtest_cache_test`). Residue: the
  warmed cache is still per-checkout; CI publishing it as an artifact
  would make the cost shareable.

- **Manifest churn pays the full cold cache again** (2026-08-07,
  stage-4 UI work): after a `./wbuild manifest` regeneration (one
  build.base.json target edited), the next `bin/wtest changed` rebuilt
  the import-closure cache for all ~680 roots even though no import
  graph had changed — a two-minute-plus stall mid-edit-loop on this
  container (`./wbuild wtest_cache` in the background was the
  workaround). If the invalidation is keyed on manifest content
  rather than each root's own inputs, keying it on the root list +
  per-root content would keep warm caches across manifest-only churn.

- **Shipped (2026-08-07): `wtest_map_check` resumes wtest's cold
  cache build across its own timeout.** The cold deps-cache build
  crossed a new line: on the 4-core CI runner it now outlasts
  `wtest_map_check`'s 5-minute per-invocation `process_run` timeout
  (the log shows the progress estimate reaching "~3s left" before the
  kill), so `wtest_map_test` — and with it the whole `tests` umbrella
  — went red on main with a green local run. The harness's own
  timeout was the failure, not wtest. `check_run_case`
  (`tools/wtest_map_check.w`) now distinguishes
  `process_status_timeout()` from a real wtest failure and re-runs
  the case (up to 6 attempts), leaning on the cache's documented
  checkpoint-resume property so each attempt makes forward progress;
  any other nonzero status still fails immediately with the original
  message. Residue: `wtest_map_test` could instead depend on the
  `wtest_cache` pre-warm target so the first `bin/wtest changed` run
  never pays the cold build — and the artifact-published cache above
  would make both moot.

- **Shipped (2026-07-28, wave 4): the verify residue's compiler-tree
  set is now DERIVED from `bin/wv2 deps w.w`** instead of the
  hard-coded prefix list (three independent 2026-07-28 entries logged
  the gap: seed-graph `libs/extras/` edits, `lib/__arch__/<arch>/`
  runtime edits, and `debugger/`/`repl/` edits never selected the
  self-host gate). `tools/test_map.w`'s `wtest_seed_graph` consults
  the closure snapshot (cached in `bin/.wtest_deps_cache` under root
  id `x86 w.w`, same entry format and validation as rule (b)'s
  closures) and fails OPEN to the old prefix floor
  (`wtest_compiler_tree`) when `deps` is unavailable — never narrower
  than the historical behavior. `lib/__arch__/<arch>/` files found in
  that arch's own `bin/wv2 <arch> deps w.w` closure additionally
  select the arch's fixpoint (`verify_x64`/`verify_arm64`/
  `verify_wasm`/`verify_win`; `verify_darwin` stays never-emit). Rule
  (b)'s closure-scan skip stays keyed to the narrow prefix floor, so
  derived seed-graph files (debugger/, lib/stream.w, ...) keep their
  leaf-test closure selection alongside `verify`. The derivation is
  file-accurate, not tree-sloppy: `libs/extras/parser_generator/
  runtime.w` (in the closure) gets the gate, `generator.w` (pg-tool
  code the compiler never links) does not —
  `tests/wtest/map_expectations.expect` pins both directions plus a
  non-closure `lib/stats.w` negative. (The residue this entry used to
  carry — a failed `deps w.w` run cached against w.w's content hash
  silently pinning the rule to the prefix floor until w.w changed —
  shipped 2026-07-29: deps failures are never cached while `bin/wv2`
  is missing, a persisted compile failure is additionally keyed to
  `bin/wv2`'s hash and to the reported missing import staying absent,
  and the fallback announces itself on stderr; `wtest_nofailcache_test`.)
- **Shipped (2026-08-06): the dynamically-linked needs probe checks
  the c_lib-named sonames, not just the ELF interpreter** (found
  2026-08-04 during the closure-needs work). The c_lib/c_import scan
  in `tools/test_map.w` now retains each directive's quoted soname
  ('.so'-containing names only — wasm import modules and Mach-O/PE
  paths are other runners' business — and libcuda* stays on its GPU
  bit, since the driver installer puts libcuda.so.1 wherever it
  likes), unions them over the root's cached import closure, and
  `--runnable-here` probes each against the word size's standard
  library directories plus /etc/ld.so.cache as a byte substring
  (ldconfig's index knows libraries outside the standard dirs),
  naming the missing soname in the drop reason — so
  `graphics_gl_smoke_test` on a host with
  `/lib64/ld-linux-x86-64.so.2` but no libGL now drops with a reason
  naming libGL.so.1 instead of failing at run time. Asserted by the
  rn_dyn_missing (fictional soname, dropped everywhere) and
  rn_cuda_clib (GPU bit, never the soname probe) fixtures in
  `tools/wtest_runnable_e2e.w` +
  `tests/wtest/map_expectations.expect`.
- **Shipped (2026-08-04): timeout-shaped deps failures are never
  persisted, and every failed closure shell-out warns.** This bit
  twice for real on 2026-07-29: (U5 tool-target migration) a
  `./wbuild tests` run killed mid-way through the first cold
  `bin/.wtest_deps_cache` build left cached failure entries, and the
  next `wtest_map_test` failed two arch-closure expectations
  ("missing expected target: verify_arm64" / "verify_wasm") with
  nothing pointing at the cache; and (U4 dogfooding-fixes) during a
  cold build under three sibling checkouts' parallel `./wbuild tests`
  load, the non-default-arch `bin/wv2 deps <arch> w.w` runs (a
  near-full compile each, ~23s standalone) exceeded the 120s
  `process_run` budget for x64/arm64/arm64_darwin/win64 and all four
  were persisted as `X <arch> w.w` records keyed to w.w's content
  hash — silently skipping per-arch verify selection even after the
  load vanished, until the stale lines were hand-deleted. Now
  (`tools/test_map.w`): a timed-out `deps` run is retried once
  immediately, a still-timed-out root is a run-local memo that is
  NEVER written to the cache (only real nonzero compile exits
  persist, still keyed to `bin/wv2`'s hash), so the next run retries
  it; and every failed shell-out — timeout, nonzero exit, or spawn
  failure — prints one stderr line naming its root, so selection loss
  is visible instead of silent (`wtest_timeout_test`;
  `WTEST_DEPS_TIMEOUT_MS` shrinks the budget for tests).
- **(2026-07-29, U10 c_import work) a seed-graph diff's cold
  `wtest changed` exceeded a 10-minute budget under parallel wave
  load.** `libs/extras/c_import/importer.w` in the diff makes the
  closure build walk essentially every root (370 here); the first
  `wtest changed` run after `./wbuild build` was killed at the
  documented "several minutes" budget (10 min wall) and needed a
  second invocation to finish from the resumed cache — which worked
  exactly as documented, plus one load-induced `bin/wv2 deps` failure
  that correctly fell back to literal matching with a stderr warning
  instead of being cached (the 2026-07-29 no-fail-cache fix doing its
  job). Partly addressed 2026-08-04: `./wbuild wtest_cache` pays the
  cold walk deliberately (run it right after `./wbuild build`), and
  the progress lines now carry a time-left estimate, so the budget
  decision is informed. Residue: seed-graph edits could still prime
  the cache from the umbrella end (the selection is going to include
  `tests`/`verify` anyway) instead of computing all N root closures
  first, and `./wbuild build` could warm the cache automatically as a
  side effect so the first selection never pays the cold-walk cost
  unwarned.

- **(2026-08-06) a CI `./wbuild tests` run can fail with an empty log
  when the failing target is the last one scheduled.** Observed twice on
  PR runs (the docs-only #412 and #413): the job log ends at
  `wexec: target wbuild_platform_test_darwin` + its compile command and
  exits 1 with no diagnostic — the fail-fast reap path never named the
  failing target (only `--keep-going`'s epilogue did), the stopped-early
  epilogue is silent when nothing was left unattempted, and a worker
  that dies mid-step takes its process_run-captured output with it. The
  naming half is fixed (fail-fast now prints
  `wexec: failed: <target> (exit status N)` at reap time); the
  underlying flake — same last target, ~50% of runs that day, not
  reproducible locally and gone on rerun — is still undiagnosed; if it
  recurs the new line will say what actually died and how.

- **(2026-10-08) the fail-fast `wexec: failed: <target>` line is buried
  under -j > 1.** On the first CI run of PR #588 the `tests` leg failed
  with the reap-time line printed while a long target (the diff sweep)
  was the oldest in flight, so the held output of every younger worker
  (5000+ lines) was flushed after it and the last visible lines were
  `wexec: stopped early after failure: 1 of 932 targets not attempted`.
  The GitHub job-log API caps what it returns at the last few thousand
  lines and the raw log download is blocked from cloud sessions, so the
  failing target could not be named from the log at all. Fixed: the
  fail-fast epilogue now repeats every `wexec: failed: <target> (exit
  status N)` line just before the stopped-early count, so the tail of
  any run names what failed. Covered by `wexec_keep_going_test`.

- **(2026-08-07) `./wbuild -j 2 test_changed` fails with "unknown
  target test_changed".** The `test_changed` dispatcher in `wbuild`
  only matches `$1`, so leading flags fall through to wexec, which
  treats `test_changed` as a target name. Flags after the subcommand
  (`./wbuild test_changed -j 2`) work — either accept flags before the
  subcommand or say so in the error.

- **(2026-08-07) `test_changed --available` still selects
  libcuda-dependent GPU run targets.** `torch_infer_gpu_test` fails on
  a GPU-less box with `libcuda.so.1: cannot open shared object file`;
  the availability probe (post-#421 wave-1 1.1, which added c_lib
  soname probes for libGL) doesn't cover the cuda runtime targets, so a
  json-layer diff still pays — and fail-fast aborts on — a known-
  unrunnable GPU target (`--keep-going` needed to see the real
  selection through).

- **Shipped (2026-08-08): the deps-cache cost is gone at its root.**
  (Logged 2026-08-08 while profiling the compiler.) `w deps` runs the
  whole compiler and just records each path as it opens it
  (`deps_mode`/`deps_record`, `compiler/compiler.w:83`), so it cost a
  *full compile* per root — 14.8 s for `w.w`. That was `sym_lookup`'s
  O(symbols^2) scan, not anything about deps, and fixing the scan took
  `w deps w.w` to **0.85 s** (17x). Populating
  `bin/.wtest_deps_cache` is no longer a multi-minute wait, and the
  tokenizer-only import scanner floated as the fix is explicitly not
  worth building: it would have to duplicate `__arch__` resolution, the
  upward directory search and its `argv[0]` fallback, two layers of
  import dedup, the compiler-internal root substitution rule, and the
  four use-triggered deferred runtime imports the grammar decides — a
  second resolver free to diverge from the real one. See
  `docs/projects/compiler_performance.md` sections 8 and 9.

- **Fixed (2026-09-25): concurrent wtest runs lost each other's cache
  entries.** Every wtest process saved `bin/.wtest_deps_cache` from its
  own in-memory copy, so a run that loaded the cache before another run
  stored a root wrote that root back out. Under full-suite load this
  made `wbuildd_test` fail intermittently: the root it pre-warmed went
  cold again, and the one-shot printed "building import-closure cache"
  while the daemon did not. The #499 temp-file rename stopped torn
  reads but not these lost updates. `wtest_cache_save` now re-reads the
  file and carries over entries for roots it holds nothing for, except
  the exact entries it loaded and rejected as stale.

## Build manifest (`tools/wbuildgen.w`)

- **Shipped (2026-07-29): the "invoke a tool as the whole target"
  generation mode closes the bucket C/K residue.** `manifest`,
  `manifest_check`, `metadata_check`, `wvdiff_test`,
  `wexec_keep_going_test`, `wexec_ordered_output_test`, and
  `asm_seed_gate` now generate from `build.base.json`'s new
  `"generate": {"tool_targets": [...]}` array instead of living
  hand-written in `"targets"`: each entry carries `name` + `steps`
  (wexec's per-step JSON schema, verbatim — these targets' step lists
  are per-step structured with `expect_status`/`reject_*`/multi-line
  expectations, which is why a `# wbuild:` vocabulary extension lost
  the design call; full rationale in `build_system_next.md`'s "Design
  note: tool targets") plus optional `inputs`/`outputs`/`data`, and
  wbuildgen DERIVES `"deps"` from the step commands
  (`wbg_find_target_by_output` over base targets' declared outputs, so
  the staged `bin/wexec` resolves; the entry's own earlier-step `-o`
  products are self-satisfied, which is all `asm_seed_gate`'s
  raw-seed shape needed — no compiler-selector directive after all).
  Declaring `"deps"` by hand, an unknown entry key, a `bin/`-prefixed
  command word nothing produces, or an entry name still present in
  `"targets"` are all hard `./wbuild manifest` errors. Generated
  `build.json` objects verified byte-identical to the hand-written
  originals (only their array position moves to the generated,
  name-sorted section). Bucket C (the tool binaries) stays
  hand-written by design — it is what the deps derivation resolves
  against.

## Cleanup observed while dogfooding

- **A `cast(T*, x)` result takes no postfix suffix, so
  `cast(int*, t)[218]` and `cast(rec*, p).field` do not parse.**
  Observed 2026-08-08 (record-table indexing): `compiler_performance.md`
  §10 proposed `cast(int*, t)[218]` as the replacement for
  `load_ptr(t + 218 * __word_size__)` and it does not compile —
  `grammar/unary_expression.w:269` handles `cast`, `expect(c")")`s and
  returns `type_value(want)` immediately, never reaching
  `postfix_expr`'s `[`/`.` suffix loop, which is only entered through
  `unary_expression_operand`'s final fallthrough. What you actually get
  for `return cast(int*, p)[0]` is a red herring first — `warning:
  return type mismatch: expected 'int', got 'int*'`, because the cast
  alone was taken as the whole expression — and only then `';' expected,
  found '['`. Neither says a cast takes no suffix. Two spellings do
  work, both already house style: an intermediate typed local
  (`int* p = cast(int*, t)` then `p[218]`), or parenthesizing
  (`(cast(int*, t))[218]`, the `(t - 1)[0]` shape from
  `tests/pointer_arith_type_test.w:20`). Direction: let the `cast` arm
  fall into the suffix loop rather than returning — it is the one
  primary-shaped construct that does not, and the asymmetry is
  invisible until you hit it. Cheap alternative: name it in the error.
  Cost here was a planning round, since the proposed spelling was in a
  committed design doc and read as known-good.

- **REPL: an import fails when the session already defines one of
  its names.** Observed 2026-09-25 (issue #335 stage 5): at the prompt,
  `int ls(char* d): ...` and then `import lib.shell_commands` (which
  used to declare a bare `ls`) fails with `symbol redefined: 'ls'`,
  pointing into the library file, and the whole import rolls back.
  Redefining in the other order is fine (a later prompt definition
  shadows, #114), so which of two identical sessions works depends on
  typing order. Shell mode sidestepped it with prefixed tool names, but
  any `import` after a same-named prompt definition still hits it
  (`path_join`, `regex_search`, ...). Direction: let an import's
  declaration shadow a prompt-defined symbol the same way a prompt
  redefinition shadows an import's, or at least say in the error that
  the clash is with the session's own definition.

- **`./wbuild -j 2 test_changed` misparses as a target lookup**
  (2026-08-06, lib/regex.w run). `test_changed` is a wbuild script
  mode dispatched only when it is literally `$1`, so leading flags
  (`-j 2`) fall through to wexec, which dies with the misleading
  `unknown target test_changed`. Trailing flags work
  (`./wbuild test_changed -j 2`). Either scan past leading `-j`/
  `--*` arguments when detecting the mode, or have wexec's unknown-
  target error hint at the script modes (`test_changed`, `update`).
- **Shipped (2026-08-06): wtest availability probes cover all three
  missed shapes** (found 2026-08-05 running the container-free() gates
  on a Linux runner with no qemu, no GPU and no 32-bit loader). (1) A
  runner wrapped in `sh -c` (`pac_corrupt_test_arm64`'s
  `["sh", "-c", "sh tools/run_arm64.sh ...; test $? -ge 128"]`, which
  the argv[1]-shape check never saw): `wtest_step_unavailable_reason`
  now scans a `-c` command string for the two known wrapper paths
  (`tools/run_arm64.sh`, `tools/run_wasm.sh`; since 2026-09-25 the
  runner spellings `bin/wrun arm64` / `bin/wrun wasm`, which the
  direct-argv check now also recognizes) and applies the same
  probes, still positive-evidence-only — asserted deterministically in
  `tools/wtest_runnable_e2e.w` by controlling PATH and
  QEMU_ARM64. (2) Closure-level GPU attribution was closed the same
  day by PR #400. (3) Umbrella collapse and the availability filter
  now compose: an umbrella whose transitive dep closure (`tests` lists
  `tests_x64`) contains a filter-dropped target is never collapsed
  into — one stderr note names it — so `tests` no longer reintroduces
  `dynamic_test` et al. through its deps; the umbrella's surviving
  members stay listed individually
  (`tests/wtest/manifest_collapse_avail.json` cases in
  `map_expectations.expect` + the wtest_map_test inline steps).
- **Shipped (2026-08-06): `w symbols --layout` dumps computed struct
  layout without running a binary.** (Found 2026-08-05 validating
  imported C bit-field layout for the env-blocked i386 target.)
  `w symbols --layout [--json]` prints struct/union records only, each
  with its total size and per-field offset/size for the selected target,
  composing with the arch selectors in both spellings; c_import types
  (previously skipped for lack of a source location) are included with a
  `<c_import>` marker, making their `__ci_pad_`/`__ci_bytes` filler
  fields readable. The native type table still has no alignment
  metadata, so native offsets are documented as the compiler's packed
  layout; per-field *alignment* remains unexposed. `symbols --json` also
  gained `total_size`, per-field `size`, and correct `arch` labels for
  arm64/arm64_darwin/win64/wasm (previously all stamped from word size
  alone).
- **Test sources can assert on their own raw bytes.** `defer_test.w`'s
  `test_defer_closes_file_descriptor` asserts the first byte of
  `tests/defer_test.w` is the `'i'` of `import`, so prepending the new
  `# wbuild: x64` manifest directive as line 1 broke it at runtime while
  every compile stayed clean (2026-07-10, manifest-generation
  migration; the directive lives on line 2 there now). When a tool
  rewrites test sources en masse, grep the touched files for their own
  paths first; longer term, self-referential assertions should read a
  dedicated fixture instead of the test's own source.
- **wexec directory hashing is Linux-layout only.** Found while porting
  the darwin triad: `wexec_collect_dir` (tools/wexec.w) parses the Linux
  getdents record layout, so on macOS — where the `getdents` shim
  returns raw Darwin `getdirentries64` records (see the NOTE in
  `lib/__arch__/arm64_darwin/syscalls.w`) — a directory input silently
  hashes as an empty file list. The darwin build targets therefore
  declare no directory `"inputs"` (FORCE-style, always run). To unlock
  content-hash caching on macOS, add per-arch dirent accessors
  (`reclen`/`name`/`kind`) next to each `getdents` shim in
  `lib/__arch__/*/syscalls.w` and use them from `wexec_collect_dir`.
  Partially addressed (2026-07-25): the silent misparse is gone —
  `tools/__arch__/*/wexec_platform.w`'s `wexec_dirents_supported()`
  reports the layout gap per target, and `wexec_collect_dir` now warns
  once ("directory inputs are not hashed on this platform") and treats
  the directory as empty instead of parsing Darwin records with Linux
  offsets. The per-arch accessors now exist: `lib/dir.w` reads through
  `lib/__arch__/<target>/dirent.w`, which decodes getdirentries64 on
  arm64_darwin. What is still open is validating that decoding on a Mac
  (run `lib/dir_test.w` natively), then flipping the darwin
  `wexec_dirents_supported()` to 1 and giving the darwin targets
  `"inputs"`.
## ParserGenerator streaming codegen (`libs/extras/parser_generator/`)

The 2026-07 review findings and the nullable-suffix fallback all
shipped (last piece 2026-07-28) — see `ai_tooling.md`'s status section
and `docs/projects/parser_generator.md` for the record.

- **w.pg gotcha for statement-level list productions**: `gap_many`'s
  line continuation inside `binary_tail` means a line ending in an
  expression absorbs a following line's leading `*` as a
  multiplication (`int* p = &b` + `*q, ... = ...` reads as `&b * q`),
  so any new statement-level tail production (the multi-assign comma
  list) must also be reachable from every context that can end in an
  expression, not just `expression_stmt` — `local_suffix` needed the
  same `expr_stmt_tail*`. The compiler's tokenizer is newline-
  sensitive and never joins those lines, so the mismatch only
  surfaces as a `parser_generator_w_test` failure on the new test
  file, one gate late.
- **Parenthesized arithmetic followed by a comparison in an `if` can
  fail the PG gate.** Observed 2026-10-03 in the new AST differential
  fixture: `if (120 / 6 / 2) != 10: return 3` compiles with `wv2` but
  `parser_generator_w_test` rejects the fixture as `expected top_item,
  found if`. Wrapping the whole condition, `if ((120 / 6 / 2) != 10):`,
  passes both. Review `paren_expression_opt`'s early parenthesized
  alternative and add a regression for binary tails after that group.

## Skills / rules upkeep

- Skill command examples are kept in sync with CLI changes by the
  `skills_test` target (declared at the end of `tools/skills_check.w`): it asserts every compiler
  flag documented in AGENTS.md, README.md and `.cursor/skills/`
  appears in `w --help` / `w <subcommand> --help` output
  (`tools/skills_check.w`). When adding a compiler flag, add its help
  line in the same commit or `skills_test` fails.
- Candidate new skills as workflows stabilize: the first three shipped
  2026-08-04 as `w-arm64-qemu`, `w-seed-update` and `w-c-import-debug`
  (all registered with `skills_test`); add further candidates here as
  they emerge.

## `w check` on multiple files (2026-08-09, #441 round 1)

`bin/wv2 check --json a.w b.w` compiles the arguments as ONE
translation unit rather than checking each in turn, so passing two
files that legitimately define the same symbol — say
`graphics/window_web.w` and `graphics/window_stub.w`, two backends
behind the same `graphics.window` surface — reports
`symbol redefined: 'gfx_shader_header'` and exits 1. Nothing is wrong
with either file.

The failure mode is bad for an agent specifically: batching the files
in a diff into one `check` invocation is the obvious thing to do, it
"works" whenever the files happen not to collide, and when it does
collide the diagnostic points at real source with a real-sounding
error. The workaround is a shell loop, one file per invocation.

Options, cheapest first: (a) reject more than one positional argument
for `check` with a message naming the loop; (b) check each argument in
a fresh symbol table and merge the diagnostics, which is what the flag
reads as promising. (b) is the useful one — a single invocation over a
diff's worth of files is exactly the ergonomic win `check --json`
exists for.

## Display-dependent gates are runnable headlessly (2026-08-09, #441 round 1)

2026-10-03: a default-parallel `wbuild tests` run intermittently failed
`graphics_ui_smoke_test` with both button/background red channels reading
zero; the isolated retry passed without source changes. Investigate window
readiness or interference between concurrent display tests, and consider
serializing their execution. This was observed during the AST expression
work with the experimental compiler option off.

`graphics_ui_smoke_test` and `graphics_gl_smoke_test` SKIP with exit 0
when no display is reachable, which is the right default but means a
headless CI box or agent container silently never exercises the pixel
readback — the strongest end-to-end check the graphics tree has.

Both run fine under a software stack:

	apt-get install -y xvfb libgl1-mesa-dri libglx-mesa0
	Xvfb :99 -screen 0 1280x1024x24 &
	DISPLAY=:99 ./wbuild graphics_ui_smoke_test

Mesa's llvmpipe reports `direct rendering: Yes`, and the smoke tests
pass their pixel checks unmodified. The same setup captures
`docs/images/ui_demo_*.png` via `graphics/ui/demo.w --screenshot`.

Worth considering: a `wbuild` target (or a CI job) that starts Xvfb
around the display-dependent targets, so "SKIP (no display)" stops
being the normal result everywhere except a maintainer's desktop. The
SKIP path should stay — it is what makes the suite runnable anywhere —
but it currently hides a whole class of regression from every
automated run.

## An `extern` silently binds to the nearest preceding `c_lib` (2026-09-25, #378/#462)

On arm64_darwin, a file that declares `c_lib ".../ApplicationServices"`
and then, a few lines later, `extern int objc_msg_mouse(...) =
"objc_msgSend"` binds that extern to ApplicationServices, not libobjc.
It happened to resolve there (the framework re-exports it); the same
declaration after `import graphics.window` bound to OpenGL instead, and
the binary died at launch with dyld's `Symbol not found: _objc_msgSend
... Expected in: OpenGL`. `w check` and the compile were clean both
times.

Options: (a) a `check` warning when an extern follows a `c_lib` from a
different import unit (the binding is then almost certainly
accidental); (b) on Mach-O, verify at compile time that the named
dylib exports the symbol when the host has the dylib (a Mac, or an SDK
.tbd); (c) document the rule next to `c_lib` in the language docs. (a)
is cheap and catches the case that bit here.

## Darwin bootstrap from a clean checkout is broken with the pinned seeds (2026-09-25)

**Update (2026-09-25):** `SEEDS` now pins v0.3.0. Its `w-arm64-macos` is the
release workflow's native darwin fixpoint of current sources, which should
clear this. It has not yet been checked from a clean checkout on a Mac.

**Native validation (2026-10-07, #591):** the SHA256-verified v0.3.0 seed
compiled `c310878c` through native `wv2 -> wv3 -> wv4` with byte-identical
`wv3`/`wv4` on an M3 Pro running macOS 26.3; 119 native smoke tests and
dynamic linking passed. The old-seed failures below are historical, not a
failure of the current pin. The full cold `wbuild` executor path still needs
validation: this checkout's local seed differed from its pin and did not
finish bootstrap during observation, so tests used an isolated pinned seed.
The smoke target also depends on Linux `bin/wv2`; add a native compile/run
target using `bin/wv2_darwin`, and document an isolated pinned-seed retry
that preserves a local promotion. See [the Darwin VM plan](vms_darwin_plan.md).

Both released darwin seeds miscompile current main: v0.1.0's
`w_darwin` segfaults compiling `w.w` (first bad commit 2a9c034, July
19), and v0.2.0's compiles it but writes a corrupt Mach-O magic, so
the stage-1 compiler fails with "exec format error". Current sources
compiled by a current compiler are fine: a Linux-cross-built
`bin/wv2 arm64_darwin w.w` reaches a native fixpoint. `release.yml`
already works around this for CI by cross-building the darwin
bootstrap; a fresh Mac checkout has no such path, and `./wbuild` on a
Mac just segfaults. The fix is the documented seed promotion (tag a
release from current main, bump every `SEEDS` line). Worth adding
either way: a darwin smoke of the pinned seed against `w.w` in CI, so
the next divergence shows up the day it happens instead of two months
later.

## Native Windows build loop was never exercised end to end (2026-09-24)

On a real Windows 11 host (HVCI on), `wbuild.cmd verify_win` failed at
every layer before reaching a compile: the pinned v0.1.0 `w.exe` seed
and every current-main win64 binary crashed at the first kernel32 call
(zero-filled IAT slots, which Wine binds but Windows does not); wexec
forked workers (no fork on Windows); the manifest's `wv2` target ran
the Linux seed; `CreateProcessA` rejected `bin/wv2.exe` spelled with
`/`; `cmp`/`echo` are not programs on a plain Windows PATH; the
manifest generator's getdents-only tree walk dropped every
source-derived target (including the `generated` umbrella every run
builds first); and `open()` of a directory failed. A win64-hosted
compiler also hung forever on a missing import (the upward search never
terminates at `C:`) and evaluated `0xc0400000` as positive (literals
wrapped only because the Linux self-host is 32-bit). All fixed in the
same change; `win64_header_test` also stopped depending on binutils
`objdump`. What would have caught this: one CI job on a real Windows
runner running `wbuild.cmd verify_win tests_win64` (GitHub's
windows-latest has no Wine dependency and exercises the strict loader).
The pinned seed still needs a release after this fix before a cold
bootstrap works on such hosts.

## `lib/json_rpc.w` writers take ownership of params (2026-09-25, #483)

- **Fixed: `bin/wbuildd`'s query client freed its request params twice.**
  `jsonrpc_write_request` and `jsonrpc_write_notification` free the
  message they build, params included, but `wbd_query` also called
  `json_free(params)` afterwards. The free-list allocator tolerated it;
  the build RPC's larger allocations then crashed the daemon in
  unrelated `json_parse` calls, and only `W_DEBUG_ALLOC=1` pointed at
  the real site. Worth a sentence in `lib/json_rpc.w`'s header, or
  writers that take `const`-style borrowed params.

## A wexec that misvalidates its own cache cannot rebuild itself (2026-09-25)

- **Found while sharing the closure cache (tools/deps_cache.w).** A
  development build of `bin/wexec` whose closure-cache validation was
  wrong (a `new` struct's `checked` field was never initialized, so
  stale records read as valid) reported `wexec` itself as `(cached)`
  after the fix landed in the source, because the target's key comes
  from the executor's own closure validation. `./wbuild` then kept
  running the broken binary; only `./wbuild --no-cache wexec` (and
  deleting `bin/.wexec_deps_cache`) recovered. Two cheap guards: key
  the `wexec` target on its sources' plain file hashes as well as the
  closure (so an executor bug cannot hide its own rebuild), and have
  `w check --lint` flag a `new T` whose fields are read before any
  assignment. Related: `lib/str.w`'s `split` is quadratic (each piece
  calls `substring`, which runs `strlen` over the whole remaining
  text), which made a 600 KB cache parse take 20 s; the cache module
  scans lines by hand instead.

## Reliable-services libraries (2026-10-03, #514)

Observed by parallel agents building `lib/io.w`, `lib/fs.w`, the checked
streams, `lib/executor.w`, the W2 codecs and W5 transports.

- **`git diff --name-only HEAD | bin/wtest changed` misses untracked new
  files.** Every agent adding a new module had to append the paths by
  hand. Direction: a `--untracked` flag (or `git ls-files --others
  --exclude-standard` folded in), or document `git add -N` in AGENTS.md.
- **`bin/wtest changed` is useless for files in the compiler's closure.**
  A `lib/stream.w` edit selects 802 of 817 targets (collapsed into the
  umbrellas); `lib/bytes.w` alone pulls in `wexec`. Direction: report the
  closure-driven fan-out separately from direct users, so a caller can
  run the direct users plus `verify` first.
- **`bin/wtest archs <file> --check` cannot filter by arch.** For
  `lib/stream.w` it lists 245 pairs, 212 of them x86/x64; an agent wanting
  only the non-default arches had to script around it. Direction:
  `--arch <name>` / `--exclude-default`.
- **`check --lint` with several files compiles them as one batch**, giving
  false `duplicate-import` warnings and "symbol redefined" errors; lint
  one file per invocation (same root cause as the multi-file `w check`
  entry above).
- **`in` is a keyword, but `in = ...` at statement position reports
  "Could not find a valid primary expression, token: ="** without naming
  the cause. Direction: a keyword-as-identifier hint.
- **`tests/parser_generator/w.pg` rejects `for pass in range(3): stmt`**
  (single-line body) while the compiler accepts it, and the block form
  `for pass in range(4):` parses in both. Only `parser_generator_w_test`
  in the full suite caught it, as "expected top_item, found
  assert_equal" on the line after. Direction: make the grammar treat
  `pass` as an identifier wherever the compiler does, or warn in
  `w check`.
- **The worktree-isolation guard refuses ordinary shell loops** that run
  `bin/wv2` with a variable argument, and `$(cat targets)` inside a
  `./wbuild` command; agents had to write scratch scripts.
- **Test-name collisions** (`lib/clock_test.w` vs the existing
  distributed `clock_test`) surface only at manifest generation; `w
  check` or `bin/wtest` could warn when a new `*_test.w` name collides.
- **`mem_fill(&b.data[i], cast(char, 0), n)` fails type inference**
  ("got 'constant'") and needs an explicit `[char]`.
- **Language sharp edges hit along the way** (recorded here until each
  gets its own issue): narrow integer stores truncate silently (`uint16 x =
  70000` is 4464, no warning); decimal literals wrap to 32 bits even on x64
  (`4294967295` is -1); `free()` warns on a `T**` argument while `T*` is
  accepted; `new T()` leaves fields uninitialized and a partial positional
  `new T(a, b)` only warns.

## Import roots and the build caches (2026-10-03, #514 W6)

- **Closure scans read the target selector only at `cmd[1]`.**
  `wexec_deps_collect_roots` and wtest's `wtest_collect_own_roots` take
  the arch from the word right after `bin/wv2`. A hand-written step
  spelled `bin/wv2 --strict x64 f.w -o out` is keyed and selected on the
  x86 closure, which the compiler accepts but does not use. The generated
  steps and the `flags=` directive put the selector first, so nothing in
  the tree hits this today. Direction: share the compiler's selector scan,
  which skips flags and their values. Adding `--import-root` support
  already touched both loops.
- **A target's directory `data=`/`inputs` prefix drops its `.w` files once
  closures key the target.** A target that compiles a driver and then
  spawns `bin/wv2` over fixture modules (the e2e drivers) gets no cache
  invalidation from fixture edits unless each module is listed as an
  explicit file. Such drivers stay FORCE targets today, with no `input=`,
  so nothing goes stale yet. Direction: a directive marking a prefix as
  "run-time .w data, hash every file".

## `ast_expression_suite` is one wexec step (2026-10-06, AST plan P1.1)

- **The serial suite trips the default 15-minute step timeout on a busy
  host.** `ast_expression_suite` runs the whole required-mode manifest as
  a single `bin/wexec -f ... -j 1 tests` step, so the default
  `WEXEC_STEP_TIMEOUT_MS` (900000) bounds the entire suite, not one test.
  On a 4-core container shared by four agents (load average around 12)
  it was killed after 509 targets with nothing failing. Workaround:
  `WEXEC_STEP_TIMEOUT_MS=10800000 ./wbuild ast_expression_suite` (the
  variable is inherited by the nested wexec). Direction: give that step
  its own `timeout_ms` (or `0`), so only the nested per-target steps keep
  the default bound.
- **Profiling the compiler needs a symbol bridge.** `valgrind
  --tool=callgrind` runs `bin/wv2` fine, but `callgrind_annotate` reports
  bare `file:0xADDR` entries; mapping them through `nm -n bin/wv2` to the
  nearest preceding symbol gives usable self/inclusive tables. A small
  `tools/` script (or emitting ELF symbol sizes/types so valgrind names
  functions itself) would make "profile first" a one-liner.

## Parallel agents on one machine (2026-10-06, fundamentals audit #524–#539)

About eleven agents, each in its own worktree, implemented the audit
issues at once on a 4-CPU machine. Friction they reported:

- **`ast_expression_test` and `ast_expression_suite` exceed their 900 s
  step timeouts under load.** Each needs about 9 minutes of CPU and ran
  for 19 to 30 minutes of wall time with other builds running. Both
  pass when run alone and in CI. Sometimes the timeout showed up only as
  a silent exit 1. Direction: scale the timeout with the load, split the
  test into parallel shards, or print "timed out" whenever the step is
  killed.
- **`ast_expression_suite` rebuilds `bin/wv2` while other targets in the
  same batch are running it,** which fails with ETXTBSY. Also,
  `bin/.wexec_lock` makes every other `./wbuild` call in that checkout
  wait behind one slow target. The same executable-publication hazard
  affects `bin/wtest`: running `wtest archs --check` alongside a build
  that recompiles `tools/test_map.w` fails with ETXTBSY (2026-10-07,
  #589). Run those checks sequentially until the `wtest` target also
  publishes through a temporary file and rename.
- **`./wbuild --help` is rejected** as "unknown target --help", and
  `--keep-going` is mentioned only in `tools/wexec.w` and in the
  comments of `wbuild`, never in CLAUDE.md or AGENTS.md. Without it,
  agents running the full suite lost every result after the first
  timeout. `./wbuild --list` writes to stderr, and it doesn't list
  `test_changed`, because that is a wrapper command rather than a
  manifest target. One agent concluded from this that `test_changed`
  doesn't exist.
- **`bin/wtest changed` is either too broad or misses targets:**
  - A change in the compiler tree, or in any non-`.w` file at the root,
    selects close to the whole manifest.
  - Editing a `tag=` directive selects `ast_expression_test`.
  - Changes to block hooks don't select the `ast_*_verify` parity
    targets.
- **`symbols --json` gaps:**
  - It reports no parameters and no doc comments.
  - It leaves out generics that are never instantiated.
  - On failure it writes its diagnostics to stdout.
- **Running `check` over the whole tree takes about 25 minutes,** since
  each compiler root rebuilds `w.w`.
- **`wfixture` matches `expect_stderr` lines in order,** so a fixture
  breaks when diagnostics are reordered even though the set of messages
  is unchanged.
- **Editing compiler source while tests run** makes `verify_x64` fail
  spuriously, because a later stage picks up the new source.
- **wexec steps can't set `ulimit`/rlimits,** so a real out-of-memory
  test can't be expressed. `tests/alloc_safety_test.w` simulates OOM
  with a malloc hook instead.
- **Library gaps that tests kept working around:** there is no
  `strncmp` or `trim`, `print_int0` writes to stderr, and
  `file_write_text` creates files with mode 0755.
- **Language sharp edges, recorded here until each gets its own
  issue:**
  - `pass` can't be used as a variable name.
  - `cast(char*, p)[0]` doesn't parse.
  - With `lib/str.w` imported, `s.contains(x)` on a `set[int]` resolves
    to the free function `contains(char*, char*)`. It produces only a
    type-mismatch warning, then segfaults at run time.
  - 32-bit addresses at or above 0x80000000 compare as negative.
  - `hex_word` includes the `0x` prefix.
  - A crash-report frame at a function's first instruction is
    attributed to the last line of the previous file.

## `bin/wrun wasm` under Node 22 (2026-10-06, AST plan P1.4)

- **Node's WASI runner can crash the wasm self-host.** `verify_wasm` runs
  `bin/wv2_wasm` through `bin/wrun wasm`, which falls back to
  `node tools/run_wasm.mjs` when `wasmtime` is not on PATH. With the AST
  front end as the default, Node 22.22 segfaulted mid-compile of `w.w`:
  gdb shows a V8 garbage collection triggered by `uvwasi_fd_read`'s
  external-memory accounting inside a fast API call, crashing while it
  walks the wasm frames (`InnerPointerToCodeCache::GetCacheEntry`). The
  same module reaches the fixpoint under wasmtime 25 and under
  `node --no-turbo-fast-api-calls`, and the streaming front end happens
  not to hit it. It still crashes after the #569 heap fix, so it is
  Node's bug, not heap corruption. `tools/run_wasm.mjs` now sets
  `--no-turbo-fast-api-calls` with `v8.setFlagsFromString` before
  compiling the module. Still open: say in the `verify_wasm` output which
  runner was used.

## Register promotion (2026-10-07, unit R2 of register_allocation_pgo.md)

- **`lib/testing.w` prints each test function's code address** (`Run:
  'test_x()' -> 0x0806e2c4`), so comparing the output of two builds of
  one test program (`tests/regalloc_diff_test.w` builds every runnable
  test with and without `--no-regs`) needs the addresses blanked first.
  An option to print the name only would make outputs comparable as
  they are.
- **A compile-time-constant check on string globals:** `char* dir =
  c"bin/x"` at file scope is rejected ("initializer for global must be
  a compile-time constant"), and `const char*` is rejected the same
  way, so a tool that wants a named path constant writes a function
  returning the literal.
- **`for i in range(hi, 0, -2)` never iterates:** the range loop's
  condition is always `var < end`, so a negative step is accepted and
  silently runs zero times. A diagnostic for a constant negative step
  (or `>` for negative steps) would catch it.
- **Compiler-internal assertions need the symbol's name, not its record
  offset:** scope exits truncate the symbol table, so a record offset
  recorded earlier can alias a later record at the same offset. The
  promotion's slot assertion had two false positives from that before
  it compared names (`sym_probe(name) == offset`). Worth a helper on
  the symbol table ("is this record still the live declaration of this
  name").
- **Callgrind Ir of the compiler is not repeatable to better than
  ~3%:** `structures/hash_table.w` draws a per-process random siphash
  seed, so two runs of one `bin/wv2` on one input differ in
  collision patterns (7.51 G vs 7.72 G seen on `w.w`). An
  environment variable or flag that pins the seed would make
  `wbench --no-valgrind`'s opposite, Ir comparisons, trustworthy at
  the 1% level the PGO plan wants to read.

## Source-owned targets and the profile tooling (2026-10-07, PGO plan P1)

Friction met while adding `--profile-generate`, `bin/wprof` and
`./wbuild profile_refresh` (docs/projects/register_allocation_pgo.md §11):

- **A `# wbuild: target=` block with no `tag=` cannot live entirely in
  its source file**: `manifest_check` rejects a target that belongs to
  no umbrella unless `build.base.json`'s `generate.no_umbrella` lists
  it, so every hand-run maintenance target (`profile_refresh` joins
  `wbench_compare`, `update`) still touches the shared base file. A
  `# wbuild: no_umbrella="<reason>"` directive next to `target=` would
  keep such targets fully source-owned.
- **No `rm` in steps**: wexec runs commands without a shell and the
  repo has `tools/touch.w`/`tools/chmod.w` but nothing that removes or
  truncates a file, so `bin/wprof` grew a `clear` subcommand just to
  empty the O_APPEND dump before a profiled run.
- **`file_write_text` creates 0755 files** (already noted above):
  `bin/wprof` chmods its output to 0644 so committed `profiles/*.wprof`
  are not executable.
- **A `char*` global cannot be initialised from a `c"..."` literal**
  ("initializer for global must be a compile-time constant"); a
  zero-argument function returning the literal is the workaround used
  in tests/profile_generate_test.w.

## Benchmark corpus and `wbench --programs` (2026-10-07, regalloc/PGO plan B1)

- **valgrind does not read the symbol table of W binaries.**
  `callgrind_annotate` names every W function `file.w:0x<address>`
  (the DWARF line table gives it the file, the `.symtab` entries have
  no size so it never attributes addresses to them), while a gcc
  binary's functions are named directly. `bin/wbench --programs`
  works around it by resolving each address with `nm -n` against the
  binary (the symbols are there) and prints the address when `nm` is
  absent. Emitting `st_size` on the function symbols
  (`code_generator/elf_32.w`/`elf_64.w`) would make every valgrind
  tool, `perf` and `addr2line` name W functions without the detour.
- **Instruction counts overflow a 32-bit word.** The self-compile is
  7.2 G instructions; `bin/wbench` is an x86 binary, so it records
  callgrind's count in thousands (`kIr`) and parses the number by
  dropping its last three digits rather than dividing. A 64-bit
  `wbench` (`binary=wbench arch=x64`) would remove the unit, at the
  cost of needing an x86-64 host for the compile-speed baseline too.
- **The sandbox this unit ran in refuses `for p in ...; do bin/wv2
  ...` loops and heredocs with variables** as "too complex to verify";
  the workaround was to write each loop to a script file in the
  scratchpad and run `bash <file>`. Not a repo bug, but worth knowing
  for the next agent calibrating sizes across a corpus.

## Loop-scoped registers and the operand folds (2026-10-07, regalloc/PGO plan R3)

- **`list[list.length - 1] = v` is rejected as "cannot assign to
  read-only buffer field".** The grammar sees the `.length` read inside
  the index expression and treats the whole statement as a store to the
  field; `int last = list.length - 1` then `list[last] = v` compiles.
  A false positive in the lvalue check, worth fixing in `grammar/` (it
  bit `compiler/regalloc_scan.w`'s `rl_eligible` stack twice).
- **`wtest changed` maps every compiler-tree diff to `verify` alone.**
  A change under `code_generator/`, `grammar/` or `compiler/` prints
  `verify self_host_warning_test parser_generator_w_test`, so the
  targets that actually exercise an emitter change (`asm_x64_test`,
  `local_load_fold_test`, `regalloc_test`, `ast_retained_emit_test`,
  `repl_test`, the `defer_*`/`goto_*`/`generator_*` families) have to
  be named by hand from `./wbuild --list`. A residue rule in
  `tools/test_map.w` mapping `code_generator/x86.w` to the encode and
  fold suites (and `compiler/regalloc_scan.w` to the `regalloc_*`
  targets) would make the selection trustworthy for backend work.
- **The gcc oracle pattern worked well**: the new `regalloc_test`
  cases were written once in C with `intptr_t` locals, run at `-O0` to
  obtain the expected values, then transcribed; every expected number
  in `test_r3_shapes` / `test_r3_loops` comes from that run, so a
  wrong fold cannot hide behind an expectation computed by the same
  compiler. Values must still fit 32 bits for the x86 twin (two
  constants had to be shrunk).

## Profile-driven register scan (2026-10-07, PGO plan P2 phase B)

- **`check --lint`'s `void-pointer-conversion` points at the statement
  after the offending one.** `char* p = malloc(4)` on line 5 followed
  by `int j = 0` on line 6 is reported at `6:2` with line 6 quoted;
  the same happens for an assignment (`buf = malloc(n)`). The rule
  fires when the next token has already been consumed, so the
  position should be captured before the initializer is parsed
  (grammar/variable_declaration.w / the assignment path). Fixing the
  seven cases in compiler/profile_use.w needed the lines before the
  reported ones.
- **A profile's accounting cost is not visible from `--stats`.**
  Finding where `--profile-use`'s extra ~330 M instructions went took
  callgrind plus the `nm -n` address mapping from B1's note above;
  a `--stats` line with the number of bytes hashed (and the hash's
  share of the span bytes) would have answered it directly. Added
  nothing for it this time: the hashed byte count is the sum of the
  matched functions' span sizes, which `w defhash` can report.

## Asm function bodies (2026-10-07, docs/projects/asm_functions.md)

- **The text assembler accepted lines it could not encode.** `cmp byte
  [eax],0` came out as the dword `83 /7` form, an x86 block's `r8d`
  parsed as a label word, `mov rax,-1` loaded `0xffffffff`, an arm64
  mnemonic without an encoder (`ror x0,x0,#3`) became a zero word and
  `b.lo` an undefined condition, both faulting only at run time. The first three are fixed here and the
  asm-block front end now rejects unknown operand words and arm64 lines
  the encoder did not build. Direction: make `libs/asm` itself return an
  error for every form it does not encode, so the runtime stubs get the
  same protection.
- **Twin target names differ by architecture.** A source with `# wbuild:
  x64 arch=arm64` yields `foo_test`, `foo_64_test` and `foo_test_arm64`;
  guessing `foo_arm64_test` from the x64 pattern fails with `unknown
  target`. `./wbuild --list | grep foo` is the reliable lookup.
- **Diagnostics raised after the tokenizer has moved on point at the
  wrong line.** The human form prints the tokenizer's current line, not
  `diag_token_line`, so a check that runs after a whole block is read
  must move `line_number` back as well (as `compiler/lint.w` does and
  `asm_body_error` now does). A shared "report at line/column" helper
  would remove the trap.

## Branch-on-flags conditions (2026-10-07, codegen_gap_plan.md unit A6)

- **`wbench_compare` fails on an untouched compiler.** `tools/wbench_baseline.txt`
  was last refreshed in #552 (2026-10-06); on `main` at 1335f06 the
  counters it pins (`sym_lookup calls`, output bytes) are already 16-43%
  off, so the gate reports "4 workloads regressed" for a change that
  moves no counter (verified by running `bin/wbench` with the base
  commit's compiler: identical counters). A unit that must "refresh the
  baseline if deterministic counters moved" cannot tell its own effect
  from the drift without that extra run. Direction: have the PR check
  (or `wbench_compare` itself) say which commit wrote the baseline, or
  refresh it in the same PR that changes the compiler's lookup pattern.
- **The AST fixtures were the test that caught the unit's bugs.**
  `tests/cond_branch_test.w` covered every shape the unit's design
  listed and passed in four modes, yet `ast_expression_test` /
  `ast_retained_emit_test` found two miscompiles (a parenthesised parked
  map read as a whole operand, `(!!x) == 1`) because they compare
  streaming and tree emission byte for byte *and* run the fixtures over
  every expression form the grammar has. `wtest changed` listed both,
  so the loop worked; the lesson for the next unit is to run those two
  before the unit's own test is believed.
- **A `wexec` run died with exit 143 and no diagnostic.** One run of the
  focused target list stopped mid-`ast_expression_test` with
  `exit 143` (SIGTERM to wexec itself) and nothing in the log; the same
  list passed twice afterwards and the full suite passed. Not
  reproduced; noted so a second sighting is not dismissed as noise.

## Inlining small leaf callees (2026-10-07, codegen gap plan A5)

- **`wtest changed` selects by import closure, so a codegen unit's
  behavioural tests are invisible to it.** The diff of unit A5 touched
  `grammar/` and `compiler/` files only; `wtest changed` returned
  `verify`, the new `inline_test` twins, `regalloc_diff_test` and the
  residue targets, but not `direct_call_test`, `ast_expression_test`,
  `debug_test` or `attach_test`, which exercise exactly the paths the
  unit changed (call emission, the two emitters' parity, DWARF line
  notes). A unit has to carry its own list. Direction: let a source
  declare the compiler paths it pins (`# wbuild: covers=grammar/
  postfix_expr.w ...`) so a diff in those files selects it, the way
  `tools/test_map.w` residue rules work today for data files.
- **The wexec lock makes `./wbuild bench` (25+ minutes of callgrind)
  exclusive with every other target.** Running a focused test while the
  bench runs fails with `another build is running in this directory`;
  the workaround is hand compiles (`bin/wv2 tests/foo.w -o bin/x && bin/x`),
  which lose the manifest's expectations. Read-only or disjoint-output
  targets could share the lock.
- **`-v` levels are undocumented.** `-v` alone shows nothing beyond the
  default, `-v -v` turns on the per-definition traces (`inline_body_end`,
  `regalloc`), `-v -v -v` the per-site ones (`<name>: inlined`, `<name>:
  call`), and the third level makes a self-compile take minutes because
  every call prints. `--help` says only "repeat for compiler debug
  traces"; the levels should be named there.
- **A `wexec` run in one worktree can be killed from another.** During
  the merge gates, three consecutive `./wbuild` stages of a chained
  script (the focused gates at `ast_expression_test`, the full suite at
  `ftp_64_test`, then `bench_compare`) ended with exit 143 (SIGTERM)
  minutes apart, with nothing in their logs, while a sibling agent's
  `wexec` ran in a neighbouring worktree; the same chain, restarted
  under `setsid`, ran to the end. The suite's own `exit 143` sighting
  above is the same shape. A `pkill wexec` (or a process-group kill by
  an agent harness timing out a foreground command) has no way to
  tell worktrees apart. Direction: let `wexec` re-exec under a
  worktree-specific name (`wexec@lane-calls`) or document `setsid`
  for chained runs, and make `./wbuild` print "killed by signal N"
  for a stage that dies that way.

## The optimizer pass slot (2026-10-07, AST plan C3.5)

- **One bad directive hides every source-owned target.** A conventional
  test given `# wbuild: data=...` (that key belongs to `target=`/`binary=`
  targets; conventional ones spell run-time inputs `deps=`) made manifest
  generation fail, and wexec fell back to `build.base.json`'s targets
  only. `./wbuild manifest` then reported `tried to exec bin/wbuildgen,
  which does not exist` and `./wbuild wbuildgen` reported `unknown
  target`, because the tool targets are source-owned too. The real error
  is printed once, above the fallback notice. Direction: have wexec
  stop (or repeat the generation error at the end) when the requested
  target is unknown only because generation failed, and accept `data=`
  on conventional targets as a synonym, or name `deps=` in the error.


## Expression register stack (2026-10-07, codegen_gap_plan.md unit A3)

- **`./wbuild build` served a stale `bin/wv2`.** After a run of edits to
  `code_generator/x86.w`, `./wbuild build` reported `wv2 (cached)` and
  left a `bin/wv2` that did not match `./w w.w -o <fresh>` on the same
  tree, and hours of debugging chased miscompiles that the current
  source did not produce (the symptom: a test that failed under
  `bin/wv2` passed under a hand-built compiler of the identical
  source). `./wbuild --no-cache build` fixed it and the two binaries
  were byte-identical from then on. Not reproduced deliberately; the
  likely trigger is a source edit landing while a previous (killed)
  `wexec` had the content hash computed but not the output written.
  Direction: have `wexec` hash the output it recorded (not only its
  inputs) before serving a cached binary, or have `build` always
  re-verify the chain's first stage.
- **`regalloc_diff_test` reports a timing flake as a behaviour
  mismatch.** `raft_chunk_64_test` (a TCP slow-receiver test with a
  60 s budget) failed once in its `--no-expr-regs` build while the full
  suite and two other agents' runs loaded the machine; every rerun of
  the same binary passed. The sweep's own nondeterminism check (two
  runs of one build) cannot see a flake that hits one build once, so
  the gate reported `MISMATCH (behaviour)` for a miscompile that was
  not one. Direction: a `# wbuild:` tag (or the manifest's `timeout=`
  hint) that lets the sweep retry or skip timing-bound programs. The
  allocator churn test now emits only deterministic scan counts, so it
  stays in the sweep without wall-clock output mismatches; timing-bound
  networking tests still need an explicit policy.
- **The retained emitter is the differential test that found the
  pre-scan asymmetry.** `--ast-emit-retained` cannot be served by the
  pre-scan's line probe (the instantiation's bytes are in getchar's
  window only), so it always ran the full pass, and a per-function
  verdict that the probe path left different (`ers_hazard`) showed up
  as 14 "retained emission differs" lines rather than as a wrong
  program. Worth knowing before adding a pre-scan flag: anything the
  probe decides must be decided the same way by the full pass.
- **`wtest changed` on a runtime file selects suites the machine cannot
  run, and `wexec` then stops the whole run on the first of them.** A
  diff touching `structures/hash_table.w` (unit A8's SipHash rewrite)
  selects every target, which `wtest` collapses into the umbrellas
  `tests`, `tests_x64`, `tests_arm64`, `tests_wasm`, `tests_interop`,
  `tests_gpu`, `tests_win64`, `update_win`, ...; running that list as
  printed failed at `build_win` (`no executable 'wine' on PATH`) and
  `wexec` reported `stopped early after failure: 1065 of 1081 targets
  not attempted`, so one missing host tool cost the run of every
  runnable gate. Direction: let `wtest changed` (or `wexec`) mark an
  umbrella whose runner is absent (`wine`, `wasmtime`/`node`, a GPU) as
  skipped with a one-line reason instead of failing it, or add a
  `--keep-going` default for umbrella runs; the agent fell back to
  `./wbuild tests` plus `tests_arm64` by hand.
- **The arm64 dynamic tests need `QEMU_LD_PREFIX` that nothing sets.**
  `tests_arm64` fails `dynamic_test_arm64` and `float_abi_test_arm64`
  with `qemu-aarch64-static: Could not open '/lib/ld-linux-aarch64.so.1'`
  unless `QEMU_LD_PREFIX=/usr/aarch64-linux-gnu` is in the environment;
  the sysroot is installed. Direction: `bin/wrun arm64` could export the
  prefix itself when the sysroot exists and the variable is unset.
- **The wexec lock serialises every `./wbuild` call, including the
  one that builds `bin/wtest`.** While `regalloc_diff_test` held the
  lock for a quarter of an hour (unit A9), `./wbuild wtest` failed
  with "another build is running (wexec lock)", and the `bin/wtest`
  left over from an older tree then rejected the manifest with a
  wbuildgen error, so `wtest changed` could not be asked anything
  until the sweep finished; `./bin/wv2 tools/test_map.w -o bin/wtest`
  (the source that owns `binary=wtest` — there is no `tools/wtest.w`,
  which is where the name suggests looking) was the way out. Direction:
  let `./wbuild wtest` (and `--list`, `manifest`) run without taking
  the lock, since they write only their own outputs, or print the
  owning source's compile line in the lock message.
- **A target that reruns `./wbuild` from inside a step cannot keep
  using the binaries the nested run rebuilds.** (2026-10-09, compiler
  coverage.) `compiler_coverage` runs `wexec --no-cache tests` from a
  step; the nested run rebuilds `bin/wexec` and `bin/wcoverage` while
  the outer ones are executing, and the write fails with ETXTBSY. The
  workaround is to run both from copies under `bin/coverage/`.
  Direction: have wexec write tool binaries to a temporary name and
  rename over the old one, which is safe while the old one runs. Also,
  `timeout=0` (no limit) is rejected by wbuildgen, so a long-running
  target has to spell out a large value such as `timeout=7200000`.
