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

- **`w check` on a generic-only module validates almost nothing**
  (observed 2026-07-28, heap/deque work). Uninstantiated generic
  definitions are captured but never parsed past the header, so
  `w check structures/heap.w` exits clean even when every body is
  ill-typed; bugs only surface when a consumer instantiates the
  functions (here: an undeclared local and a wrong-width field access
  both sailed through the module's own check and appeared as warnings/
  segfaults in the test binary). Cheap win: a `check` mode (or default)
  that self-instantiates each generic definition with a synthetic
  word-sized type argument (the inference placeholders in
  `grammar/generic.w` already know how to do a header-only bind) so
  module-local checks see the body at least once. Until then, agents
  should check a generic module by checking a consumer that
  instantiates it.
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

- **(2026-07-28, array-cast-warning work) a slash-and-extension import
  spelling produces a mangled path in the error, with no syntax hint.**
  `import lib/assert.w` — a natural guess, since that is the file's
  on-disk path — fails with `cannot locate 'lib/assert/w.w' (searched
  the current directory and every parent)`: the `.w` suffix is treated
  as one more dotted segment and re-expanded to `/w.w`, so the
  reported path matches nothing the author typed and nothing on disk.
  The message should either echo the import as written or, better,
  hint the dotted form (`import lib.assert`) when the spelling
  contains `/` or ends in `.w`.

## Test selection (`bin/wtest`)

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
- **(2026-07-29, --runnable-here work) the runnable-here needs scan is
  root-level only.** `wtest changed --runnable-here` reads
  `c_lib`/`c_import`/`import lib.cuda` off the ROOT source of each
  compiled-and-run binary, so a directive buried in an imported module
  is not attributed: `graphics_gl_smoke_test` (c_lib in
  `graphics/gl_linux.w`) and the `tensor_gpu_test`/`nn_train_gpu_test`
  family (libcuda via `lib/tensor.w`, deliberately CPU-fallback-capable
  but still needing `libcuda.so.1` installed to load) are never dropped
  on hosts that lack X11/libcuda. Closure-level attribution (scan every
  file in the root's cached closure, fall back to root-only when the
  closure is unknown) would close it using machinery rule (b) already
  has.
- **(2026-07-28, wave 4a) invoking the compiler from outside a
  checkout cannot resolve the auto-imported runtime.** With CWD in a
  scratch directory, `/path/to/repo/bin/wv2 check snippet.w` fails
  with "cannot locate 'structures/hash_table.w' (searched the current
  directory and every parent)": runtime-import resolution walks up
  from the CWD, ignoring where the compiler binary itself lives. Same
  invocation from the repo root (absolute snippet path) works. Agents
  compile throwaway snippets from scratch directories constantly;
  falling back to the running binary's own directory (argv[0]) before
  erroring would make that workflow just work. Workaround: always cd
  to the checkout and pass the snippet's absolute path.

- **(2026-07-29, U5 tool-target migration) the documented deps-cache
  failure-caching residue bit in practice.** A `./wbuild tests` run
  killed mid-way through `bin/.wtest_deps_cache`'s first cold build
  left cached failure entries, and the next `wtest_map_test` run then
  failed exactly two arch-closure expectations ("missing expected
  target: verify_arm64" / "verify_wasm" for `lib/__arch__/<arch>/
  syscalls.w`) with nothing pointing at the cache; `rm
  bin/.wtest_deps_cache` and a clean rebuild fixed both. This is the
  seed-graph rule's known fail-open-to-prefix-floor residue (see the
  2026-07-28 "verify residue derivation" entry) actually biting —
  the suggested invalidation of failure entries on `bin/wv2`'s
  mtime/hash (or on any interrupted run) is now motivated by a real
  debugging detour, not hypothetically.
- **(2026-07-29, U5 tool-target migration) `wtest_map_check`'s `-f`
  fixture manifests silently encode build.json's *relative target
  order*, and a manifest-layout change breaks them with a message
  that doesn't point at the fixture.** Moving `manifest_check` from
  build.base.json's hand-written section to wbuildgen's generated
  (name-sorted, appended) section changed its position relative to
  `wexec_test`, and five `map_expectations.expect` cases failed with
  "selection out of manifest order (or duplicate): wexec_test" — the
  real cause being that `tests/wtest/manifest_leaf_{base,add,retime}
  .json` must list their real-name targets in build.json's relative
  order (documented in `tools/wtest_map_check.w`'s header, but the
  FAIL message names neither the fixture file nor the rule). Fixed
  here by reordering the three fixtures; a cheap improvement would be
  the checker hinting "-f fixture manifests must mirror build.json's
  relative order (or add 'noorder')" when the case carries `-f`.

- **(2026-07-29, U4 dogfooding-fixes) the X-entry residue above DID
  bite, via a new route: `wtest_run_deps`'s 120s `process_run` timeout
  under parallel load.** During a cold `bin/.wtest_deps_cache` build
  while three sibling checkouts ran full `./wbuild tests` suites in the
  same container, the non-default-arch `bin/wv2 deps <arch> w.w` runs
  (a near-full compile each; ~23s standalone under moderate load)
  exceeded the 120s `process_run` budget for x64, arm64, arm64_darwin
  and win64 — all four were persisted as `X <arch> w.w` failure
  records keyed to w.w's content hash, so every later warm-cache run
  silently skipped the per-arch verify selection (no shell-out, no
  diagnostic) even after the load vanished, and `wtest_map_test`
  failed its `lib/__arch__/arm64/syscalls.w` case (`missing expected
  target: verify_arm64`) deterministically until the stale `X` lines
  were hand-deleted from the cache. A transient, timeout-shaped
  failure should not be cached as permanent: either skip persisting
  `X` records whose `deps` run timed out (persist only real nonzero
  exits), retry them once on the next run, or at minimum have
  `wtest_run_deps` print one stderr line when a closure shell-out
  fails so the selection loss is visible instead of silent.
- **(2026-07-29, U4 dogfooding-fixes) the four `http_server` targets
  flake under concurrent load.** In a 20-unit parallel program every
  unit's full `./wbuild tests` run failed `http_server_test` /
  `http_server_route_test` and their `_64` twins (plus
  `https_e2e_test` once), yet each target passes when run alone —
  and `./wbuild http_server_test http_server_route_test ...` in one
  invocation, where bin/wexec's scheduler runs all four server suites
  (and their compiles) concurrently, fails again on the same box that
  passes them serially minutes later. Not a port collision — the
  fixtures already bind 127.0.0.1:0 and read the kernel-assigned port
  back — so the suspect is timing under CPU contention (TLS handshake
  / client read timeouts while 4+ compilers and servers share the
  container; `test_https_request_context_round_trip`'s
  `assert_equal(0, resp.error)` was one observed failure point).
  Worth bounding: either raise the client/handshake timeouts the way
  attach_test's wdbg timeout was raised for the same reason
  (2026-07-29), or serialize the four targets behind a shared wexec
  resource so a parallel `tests` run cannot self-contend.

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
- **A still-running test binary turns the next rebuild into a
  misleading compiler assert.** While iterating on lib/thread.w join
  reclamation (2026-07-28), a deadlocked `bin/thread_64_test` from a
  killed `./wbuild` run kept running in the background; the next
  `./wbuild thread_64_test` then failed with `could not open output
  file` plus a compiler stack trace ending in `asserts` at
  `compiler/compiler.w:768` — which reads like a compiler bug, not
  like the actual ETXTBSY on an output path held by a live process.
  Two cheap fixes: the linker's "could not open output file" assert
  should include the path and errno (ETXTBSY strongly hints "old
  binary still running"), and wexec could kill run-step children it
  spawned when it is itself terminated so orphans don't linger.
- **Minor: a flag before the arch selector turns the selector into the
  input file, with a misleading error.** `bin/wv2 --strict x64 file.w
  -o out` fails with `no such file: 'x64' in x64:1` after printing
  `compiling 'x64'` — the arch token is consumed as the source path
  once any flag precedes it. `bin/wv2 x64 --strict file.w -o out`
  works. Found 2026-07-28 compiling a test's x64 twin by hand.
  Cheap fix: recognize arch-selector tokens anywhere before the input
  file (or error with "arch selector must come first"), so the
  diagnostic names the real problem instead of a phantom file.

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

- Keep skill command examples in sync with CLI changes (they are
  hand-verified snapshots, nothing asserts them). A cheap
  `skills_test` that greps the documented flags against `--help` output
  would catch drift once the compiler grows a help text.
- Candidate new skills as workflows stabilize: ARM64 testing under
  `qemu-aarch64` (see `docs/projects/arm64.md`), seed updates
  (`./wbuild update` discipline), and C interop debugging (`c_import`).
