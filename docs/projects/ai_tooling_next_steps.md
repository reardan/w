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

- **One residue from the wave-3d c_import/preprocessor `diag_part`
  migration (2026-07-19; shipped summary in `ai_tooling.md`'s status
  section).** (The other — `ci_skip_extern_function`'s dead
  `verbosity` guard — shipped 2026-07-25 with the `-v`/`--verbose`
  flag; see `ai_tooling.md`.) `cpp_preprocess_file_into`'s
  (`libs/extras/c_preprocessor/pp_directives.w`) "could not read" error
  only fires when `cpp_find_include`'s existence check (`path_exists`,
  its own `open()`+`close()`) succeeds but the subsequent real `open()`
  in `pg_read_file_text` fails — a TOCTOU window with no reliable way
  to hit deterministically (root bypasses permission bits in this
  sandbox, and the two `open()` calls are microseconds apart with no
  yield point between them); the migration there was verified by
  inspection/mechanical parallel with the other 5 sites, not a runtime
  repro.

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

## Build manifest (`tools/wbuildgen.w`)

- **Open: the rest of bucket C/K has no compile-and-run shape at all.**
  `manifest`/`manifest_check` (invoke `bin/wbuildgen` directly),
  `metadata_check` (`bin/wmeta check package.wmeta`), `wvdiff_test`
  (`bin/wvdiff` over fixture text files), `wexec_keep_going_test`/
  `wexec_ordered_output_test` (`bin/wexec` over fixture JSON manifests)
  compile nothing themselves — there is no `*_test.w` source for a
  directive to live on, so `tool=`/`fixture_group=` can't reach them.
  Bucket C itself (the 11 tool binaries: `wtest`, `wbuildgen`,
  `wfixture`, `wtest_map_check`, `wmeta`, `wvdiff`, `wvc`, `wdbg`,
  `wdbg_x64`, `gen_stubs`, `rewrite_c_strings`) stays hand-written by
  design — `wbg_find_target_by_source` resolves *against* these, it
  doesn't generate them (they aren't `*_test.w`-shaped). `asm_seed_gate`
  is a distinct mismatch (`deps: []`, compiles via the raw seed `./w`,
  never `bin/wv2`) that a compiler-selector directive would fix, not a
  tool-dependency one. Closing these would need a new "invoke a tool
  as the whole target, no compile step" generation mode — a real design
  decision (what source/marker would such a target even scan for?),
  left open per the task's "enumerate, don't migrate" scope.

## Cleanup observed while dogfooding

- **`wbuildgen` can't express "this source's default-arch target is
  x64-only, don't also generate an unwanted 32-bit twin"** (wave 2b,
  bucket G migration). `wbg_scan`'s default-arch generation is
  unconditional: it always emits a target under the source's
  (`name=`-overridden or not) basename at the 32-bit default arch unless
  `build.base.json` already claims that exact name — there is no
  directive to opt a source *out* of the 32-bit default while still
  generating an x64 twin under the plain (non-`_64_test`-suffixed) name.
  Confirmed as a real behavior gap, not just redundant coverage: compiling
  `tests/x64_test.w` (bucket D, hand-written today as x64-only under its
  own basename) at the default arch builds clean but the binary silently
  exits 1 with no output. Blocks migrating `graphics_gl_smoke_test`,
  `extern_alias_test_x64`, `float_abi_test_x64` (bucket G) and bucket D's
  whole `x64_test`/`x64_float_test`/... family the same way — left
  hand-written, see `build_system_next.md`'s bucket G update. Fix would be
  a directive like `arch_only=x64` (or reusing `arch=x64` to mean "this
  IS the default" when no other arch is requested) that suppresses the
  unconditional 32-bit generation for that source.
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
- **(2026-07-27) `attach_test` failed once under a cold 20-target
  parallel run** (`sh tools/attach_test.sh` step, exit 1, right after
  two `condition on breakpoint 1 failed to compile` lines); standalone
  and warm-batch reruns are green. Plausibly a `timeout 30` wdbg
  invocation exceeded under compile load — if it recurs, bump the
  per-case timeout or serialize the script's x64 half.
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
- **wexec has no per-run-step timeout, so a deadlocked test hangs the
  whole `./wbuild` invocation silently.** The same lib/thread.w
  session produced (twice) a test binary that futex-waited forever; the
  `./wbuild thread_test ...` invocation produced zero output until the
  caller's own 300s timeout killed it, and the hung child survived
  that kill. A default (or per-step `build.json`) run timeout that
  fails the target with "timed out after Ns" would turn a silent hang
  into an actionable failure. Diagnosis that worked: `ps aux`, then
  `/proc/PID/wchan` + `/proc/PID/syscall` to see the exact futex the
  binary was parked on (op and expected-value arguments included),
  which pinpointed both bugs (private-flag waiter vs the kernel's
  shared CLEARTID wake; expected-value re-read racing the one-shot
  clear) without a debugger.
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

- **Minor: `parser_generator_w_test`'s batched failure output is hard
  to attribute** (multi-assign work, 2026-07-28).
  `tools/parser_generator_w_batches.sh` reruns the same binary once per
  150-file slice, so a failing run interleaves dozens of
  "test_parse_all_tracked_w_files() passed!" banners (the other
  batches) around one batch's stack trace, and `wexec` reports only
  "step 4: command failed" — an agent grepping for pass/fail sees both
  and has to rerun with a hand-trimmed
  `bin/parser_generator_w_files.txt` to isolate the culprit. The
  decisive "file:line:col: syntax error" line IS printed but is easy
  to lose in ~500 lines of per-test chatter. Cheap fix: have the batch
  script echo "batch N (files X..Y) FAILED" on non-zero exit, or have
  the manifest test print the failing path again right before exiting.

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
