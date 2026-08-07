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
  `tools/wtest_runnable_scratch_test.sh` +
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
  (`tools/run_arm64.sh`, `tools/run_wasm.sh`) and applies the same
  probes, still positive-evidence-only — asserted deterministically in
  `tools/wtest_runnable_scratch_test.sh` by controlling PATH and
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
  offsets. The full fix (per-arch dirent accessors, validated on a
  Mac) is still open; the accessor plan above stands.
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
