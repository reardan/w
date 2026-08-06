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


## Test selection (`bin/wtest`)

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
- **(2026-08-04, closure-needs work) the dynamically-linked needs
  probe checks only the ELF interpreter, not the libraries a c_lib
  names.** With closure-level attribution shipped, a c_lib buried in
  an imported module now marks its importers dynamically linked — but
  bit 1's probe is still just "is the target word size's loader
  installed", so `graphics_gl_smoke_test` (libGL/libX11 via
  `graphics/gl_linux.w`) stays selected on a host that has
  `/lib64/ld-linux-x86-64.so.2` but no X11 libraries and fails at run
  time. Probing the named `c_lib` sonames themselves (ldconfig -p, or
  the standard lib dirs) would close the rest; the libcuda case is
  already covered by its own GPU bit.
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

- **No way to dump a struct's computed layout without running a
  binary.** Found 2026-08-05 validating imported C bit-field layout for
  the env-blocked i386 target: the only ways to see the field offsets
  and size the compiler computed are (a) compile-and-run an offset
  printer (impossible for an arch whose binaries can't run here) or
  (b) spelunk `-v -v` logs for `type_add_arg`'s "adding field" lines
  and decode `__ci_bytes_N` filler names by hand. A
  `w symbols --json`-style `--layout` view (per-field offset/size/
  alignment for a named struct, composing with the arch selectors like
  `check`/`deps` do) would make layout work assertable per target
  without an execution environment.
- **wtest availability probes miss three shapes** (2026-08-05, found
  running the container-free() gates on a Linux runner with no qemu, no
  GPU and no 32-bit loader). (1) A runner wrapped in `sh -c`:
  `pac_corrupt_test_arm64`'s run step is
  `["sh", "-c", "sh tools/run_arm64.sh ...; test $? -ge 128"]`, so
  `wtest_step_unavailable_reason`'s `["sh", "tools/run_arm64.sh", ...]`
  argv-shape check never sees the runner and `./wbuild test_changed`
  attempts it anyway (and without `--keep-going` that one failure
  aborts the whole run with 500+ targets unattempted). Scanning the
  `-c` string for the known runner paths would close it. (2)
  `--runnable-here`'s GPU probe attributes `import lib.cuda` at the
  root file only, so `tensor_gpu_test`/`autograd_gpu_test`/... (which
  reach lib.cuda transitively) stay selected on GPU-less hosts. (3)
  Umbrella collapse reintroduces dropped members: `--runnable-here`
  drops `dynamic_test` et al. (no `/lib/ld-linux.so.2`), then collapses
  the surviving selection into `tests`, which depends on the dropped
  targets anyway — the drop and the collapse need to compose (don't
  collapse into an umbrella whose member set includes an unavailable
  target, or emit the umbrella's available members instead).
  Workaround that worked: `./wbuild test_changed --keep-going`, then
  eyeball that every failure in the summary is env-shaped.
  (Point 2 was closed the same day by PR #400's closure-level
  `--runnable-here` attribution; points 1 and 3 remain open.)
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
  offsets. The full fix (per-arch dirent accessors, validated on a
  Mac) is still open; the accessor plan above stands.
- **wtest's deps fallback warning is anonymous.** While computing the
  import-closure cache, `wtest changed` printed "warning: 'bin/wv2
  deps' failed for 72 roots; falling back to literal matching for
  them" (2026-08-05, dwarf address_size work) without naming a single
  root or the failure reason, so an agent cannot tell whether the
  fallback lost selection coverage for its diff or which roots need
  fixing. Print the failing roots (or the first few plus a count) and
  the `deps` stderr for one of them, or record them in
  `bin/.wtest_deps_cache` so a follow-up `wtest why <root>` can
  explain.
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

## Skills / rules upkeep

- Skill command examples are kept in sync with CLI changes by the
  `skills_test` target (build.base.json): it asserts every compiler
  flag documented in AGENTS.md, README.md and `.cursor/skills/`
  appears in `w --help` / `w <subcommand> --help` output
  (`tools/skills_check.w`). When adding a compiler flag, add its help
  line in the same commit or `skills_test` fails.
- Candidate new skills as workflows stabilize: the first three shipped
  2026-08-04 as `w-arm64-qemu`, `w-seed-update` and `w-c-import-debug`
  (all registered with `skills_test`); add further candidates here as
  they emerge.
