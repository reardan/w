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
- **Shipped (2026-07-17): cross-line call-tail absorption now warns.**
  `postfix_expr`'s call tail warns `call arguments continue from the
  previous line` when its `(` opens on a different line than the
  expression it attaches to (`int b = 2` / `(a + b)++` no longer
  silently merges into `2(a + b)` with no diagnostic; still
  non-breaking — a same-line-only hard rule stays a future decision);
  fixtures `tests/cross_line_call_warning_fixture.w` and
  `tests/cross_line_call_increment_fixture.w`.
- **Multi-error reporting.** The compiler stops at the first error
  (single-pass, no recovery). Documented limitation; real fix is parser
  recovery, which stays a research project. Cheap partial win: after an
  error in file A, agents re-check to find errors behind it — nothing to
  build, just keep the limitation documented in skills.
- **Shipped (2026-07-25): the same-file forward-call prototype hint.**
  See `ai_tooling.md`'s status section; `Cannot find symbol` now appends
  the forward-declaration hint when the name is visibly defined later in
  the current file (`compiler/symbol_table.w`'s `sym_not_found_error`).
- **Shipped (2026-07-17, wave 2f): the bool-bitwise condition hint is
  now on by default for every call-free join.** See `ai_tooling.md`'s
  status section for the shipped description; `--bool-ops` survives as
  the narrower "also report call-containing joins" superset (it used to
  gate the comparison-result widening itself, before the wave-2
  mechanical sweep converted every side-effect-free site tree-wide).
- **`w check --bool-ops`'s position/chain bugs — all three fixed**
  (2026-07-17, wave 2f; (1) fixed 2026-07-19, wave 1b). Consolidates
  four overlapping reports from wave-2 sweep chunks 2a/2b/2d/2e, all
  downstream of the same three bugs: (1) a warning inside an *imported*
  (non-root) file reported its line number +1 high (`debugger/
  memory.w:52` vs. actual line 51) — **fixed**: `compiler/compiler.w`'s
  `compile_save` saved `line_number + 1` instead of `line_number` before
  compiling the import and restored the inflated value on return, but
  that was only half of it — a paired defect meant the naive "just drop
  the `+ 1`" fix undercounted instead: `compile_attempt`'s priming
  `nextc = get_character()` call for the *new* file read the importer's
  still-pending lookahead (the unconsumed newline at the end of the
  `import ...` line) and spuriously bumped the freshly-reset
  `line_number` from 0 to 1 before the imported file's first byte was
  even read, while `compile_save` never saved/restored `nextc` itself,
  so the importer's own resumption silently lost the newline crossing
  it needed on the way back out. Fixed by resetting `nextc = 0` right
  before `compile_attempt`'s priming read (mirroring the existing
  `grammar/generic.w:generic_reparse_start` idiom for re-parsing a
  generic definition) and saving/restoring `nextc` in `compile_save`
  alongside `line_number` (now saved verbatim, no `+ 1`). Every
  diagnostic in every imported file across a full `check --bool-ops` of
  `w.w` shifted by exactly one line (135/135 sites, spot-checked against
  real source); regression pinned by `tests/imported_diagnostic_line_
  fixture.w` + `tests/imported_diagnostic_line_leaf.w` (`warning_test`),
  asserting both the imported file's own line and the importing file's
  post-import line stay exact. (2) the reported line/column was wherever
  the tokenizer's one-token
  lookahead sat once the *whole* condition finished parsing, not the
  `&`/`|` itself — **fixed**: `grammar/binary_op.w`'s
  `warn_bool_bitwise_at` snapshots `line_number`/`diag_token_line`/
  `diag_token_column`/`token` when `accept()`'s peek recognizes the
  operator, before consuming it moves the lookahead, and restores them
  around the `warning()` call. (3) a same-precedence chain of 3+ terms
  only ever flagged the first pairing, because
  `binary2_finish_pop`/`binary2_finish` return the untyped placeholder
  type `3`, erasing the fold's bool-ness before the next pairing's check
  ran — **fixed**: `bitwise_and_expr`/`bitwise_or_expr` now track
  `chain_is_bool`/`chain_is_pure` alongside the running fold instead of
  re-deriving them from the (erased) type, so every qualifying pairing
  gets its own diagnostic (`tests/bool_bitwise_chain_fixture.w` pins two
  distinct positions for a 3-term chain). The precedence-grouping
  observation from the original reports still holds — converting a
  join can newly expose the next fold in a chain as bool-vs-bool — but
  no longer needs a re-enumeration pass to catch: the default hint now
  walks the whole chain in one `check` pass.
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
  non-closure `lib/stats.w` negative. Residue (inherited `X`-entry
  semantics): a failed `deps w.w` run — e.g. `bin/wtest` invoked while
  `bin/wv2` is missing — caches the failure against w.w's own content
  hash, so the derived rule silently stays on the prefix floor until
  w.w itself changes even after the compiler reappears; rule (b) has
  always cached root failures this way (its literal matching covers
  the gap there), but for the seed rule the only cover is the floor.
  If that bites in practice, invalidate failure entries on `bin/wv2`'s
  mtime/hash too.
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
- **(2026-07-28, issue #360 item 5) Editing an auto-imported runtime
  file selects essentially the whole manifest.** `structures/w_list.w`
  is in every program's import closure, so `git diff --name-only
  origin/main | wtest changed` for the list-slice work printed ~450
  targets — correct but useless as a *selection* (it includes every
  platform-gated cuda/darwin/win64 target this host cannot run).
  Suggested direction: when a changed file's closure covers more than
  some large fraction of the manifest, collapse the selection to the
  umbrella targets (`verify`, `verify_x64`, `tests`) plus the literal
  step references, and say so in one line, instead of enumerating the
  world; a `--runnable-here` filter (skip targets whose steps need
  binaries/hosts this machine lacks) would compose well with that.
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
- **Shipped (2026-07-19, wave plan C task 4b): `wtest changed A..B`
  commit-ranged selection MVP** (issue #251 direction 4b). `changed`
  (not `for`) now treats a single positional argument containing `..`
  as a git revision range instead of a changed-file path -- no tracked
  path in this tree ever contains `..`, so the two never collide, and
  only the first such argument is honored. `A..B` and `A...B` (three-dot:
  wtest resolves the real `git merge-base A B` itself as the comparison
  base, `wtest_range_setup`) work as expected; an open `A..` means "`A`
  versus the worktree" -- getting that to actually reach the worktree
  needed care, since git itself resolves a range's omitted side to HEAD
  (a commit), never the working tree, so `wtest_range_expand` builds its
  own `git diff --no-renames --name-only <left> [<right>]` invocation
  from wtest's *resolved* endpoints (a bare single argument when the
  right side is open) rather than passing the ambiguous dotted text
  straight through. `--no-renames` so a rename surfaces as an ordinary
  old-path-deleted + new-path-added pair (residue rule (c) already
  covers it) instead of git's default of showing only the new name. Two
  existing pieces generalize rather than duplicate: `--defhash` (task
  2g) now compares `git show <left>:<path>` against `git show
  <right>:<path>` (or the worktree) instead of always HEAD-vs-worktree,
  and the "does this .w file still exist" check rule (c) uses for the
  deleted-file residue is evaluated against the range's right-hand
  endpoint instead of unconditionally the live filesystem. An invalid
  revision on either side is a hard error (exit 1, no selection printed)
  rather than a silent fallback -- unlike `--defhash`'s own per-file
  fail-open, a bad range makes the whole invocation meaningless, not
  just one file's precision. **Deliberately not attempted**: rule (b)'s
  import-closure computation stays keyed to the CURRENT worktree via the
  same `bin/.wtest_deps_cache` every invocation already uses --
  recomputing historical closures per commit, and true definition-level
  (not file-level) precision across a range, is the deferred "persistent
  semantic index over history" work (`docs/projects/
  build_system_next.md` direction 4b's now-updated wording); this MVP
  only reuses the live import graph, which is exact for the common case
  and can only ever over-select. Tested by
  `tools/wtest_range_scratch_test.sh` (`wtest_range_test`,
  `build.base.json`) -- a throwaway `git init` repo making a
  comment-only commit, a real edit, and a file deletion, asserting
  two-dot/three-dot/open-range selection with and without `--defhash`
  for each, plus the no-range-argument path stays byte-identical.
## Build manifest (`tools/wbuildgen.w`)

Friction found migrating bucket D of `build_system_next.md`'s hand-written
`build.base.json` inventory (wave plan C task 2a). Three of the four
directive gaps logged here shipped 2026-07-25 (`arch_only=`, `.w`-valued
`deps=`, generated cache `"inputs"`/`"outputs"` — summarized in
`ai_tooling.md`); the fourth shipped 2026-07-28:

- **Shipped (2026-07-28, wave plan P1.3): `wasm` arch value, `flags=`,
  and `group=`/`group_only` aggregate directives.** `arch=wasm` /
  `arch_only=wasm` generate the wasm compile+run shape (`bin/wv2 wasm
  ... -o bin/X_wasm`, run via `sh tools/run_wasm.sh`; no umbrella, like
  arm64), with the `wasm` selector word also taught to `bin/wexec`'s
  compile-root scan (deps-driven cache keys now compute the *wasm*
  closure for wasm roots), its direct-file mode, and `bin/wtest`'s rule
  (b) closures + `--available` (a wasm run step needs wasmtime or
  node) — `lib/__arch__/wasm/` edits used to fall through to the full
  `tests` fallback and now select exactly the wasm targets
  (`map_expectations.expect`). `flags=<args>` injects extra compiler
  arguments between the arch selector and the source of every compile
  command generated from the source. `group=<target>@<arch>` collects
  several sources' compile+run pairs into one aggregate target with a
  shared `echo <target> OK` epilogue (member run steps carry the
  member's own run-field directives; member binaries follow the
  hand-written smoke convention, `bin/lib_wasm_test`); `group_only`
  suppresses a member's standalone targets. Migrated out of
  `build.base.json`: `arm64_smoke_test`, `wasm_smoke_test`,
  `wasm_json_test` (group), `float_abi_test_x64` (group at x64, its
  two `x64_*` members via `group_only`), `pac_full_test_arm64`
  (`arch_only=arm64 flags=--pac=full`; its cosmetic trailing echo step
  is gone — the `expect_stdout` assertion remains), and `net_darwin`
  (`name=net_darwin arch_only=arm64_darwin`; its binary is now
  `bin/net_darwin`, `tools/mac/run_darwin_tests.sh` updated). All six
  also gained cache `"inputs"`/`"outputs"` (they were FORCE targets).
  Residue: the arm64_darwin multi-source bundles
  (`arm64_darwin_smoke_test`, `graphics_darwin`, `pac_darwin`) stay
  hand-written. `graphics_darwin` is structurally blocked: it compiles
  non-`_test.w` sources (`graphics/demo.w`) the scan never sees, and
  its member binaries (`bin/graphics_gl_smoke_darwin`,
  `bin/dynamic_darwin_test`) do not follow the derived convention that
  `tools/mac/run_darwin_tests.sh`'s Mac-side run leg has pinned.
  `arm64_darwin_smoke_test` and `pac_darwin` are now *expressible* —
  their member binaries (`bin/lib_darwin_test`,
  `bin/pac_corrupt_fnptr_darwin_test`, ...) happen to match the
  derived convention exactly, and `pac_full_test.w`'s new
  `flags=--pac=full` would carry into a `pac_darwin` membership — but
  their run leg executes only on a Mac, so that migration is deferred
  until someone can run `run_darwin_tests.sh` while making it (the
  `pac_corrupt_*` fixtures would move from `generate.exclude` to
  `group_only` memberships in the same change).

## Definition hashing (`w defhash`)

- **Shipped (2026-07-19, wave plan C task 2g): `wtest --defhash` opt-in
  refinement.** `tools/test_map.w`'s rule (b) now accepts `--defhash`
  (`changed` and `for` both take it): per changed `.w` path it shells out
  to `bin/wv2 defhash` on the worktree copy and on `git show
  HEAD:<path>` (staged to `bin/.wtest_defhash_head.w`), and skips that
  path's import-closure additions when the recorded definition name set
  and every name's hash come back identical — rule (a) literals and the
  rule (c) residue mappings (`parser_generator_w_test`, `metadata_check`,
  ...) still apply, so a comment/formatting-only edit just stops
  recommending every importer. Fails open in every other case (a path
  new to HEAD, a git/defhash error, a real definition change) — see
  `wtest_defhash_unchanged`. At ship time the documented generic/operator
  blind spot (below) was handled by a dedicated textual pre-check,
  `wtest_defhash_risky_text`; task 4f (next bullet) closed the coverage
  gap directly and retired that pre-check. Selection without `--defhash`
  is unchanged byte-for-byte (checked directly: the original
  `tools/test_map.w` and the new one produce identical `wtest changed`
  output on the same inputs when the flag is not passed). Tested by
  `tools/wtest_defhash_scratch_test.sh` (`wtest_defhash_test`,
  `build.base.json`) — a throwaway `git init` repo (symlinking in
  `bin/wv2`/`bin/wtest` and the `lib`/`structures`/`code_generator` trees
  every compile needs) exercising real HEAD-vs-worktree comparisons.
- **Shipped (2026-07-19, wave plan C task 4f): generic/operator defhash
  coverage + `--closure` map lookup.** `grammar/generic.w`'s three
  registration points (`generic_register_struct`,
  `generic_declaration_scan`, `generic_declaration_scan_generic_return`)
  now call `defhash_note` over the exact `[offset, end)` span already
  recorded there for instantiation re-parsing, so a generic definition's
  own token stream is hashed like any other: `name` is the base
  identifier with no `[T]` (stable across instantiation-only changes
  elsewhere, since the definition itself is what's hashed), `kind` is
  `generic_function`/`generic_struct` (distinct from plain
  `function`/`struct` so a same-named definition in the sibling
  namespace, or a same-named non-generic one, is still distinguishable).
  `grammar/operator_overload.w`'s `operator_definition` — compiled
  immediately, not deferred like a generic, so there is no separate
  registry span to reuse — instead returns a freshly built synthetic name
  (`operator_defhash_name`: `"operator<spelling>(<left>, <right>)"`, e.g.
  `"operator+(vec3, vec3)"`, built from the same operand-type spellings
  the real mangled symbol name uses) for `grammar/program.w`'s operator
  branch to pass to `defhash_note` alongside the ordinary declaration
  span; `kind` is `operator`. `bin/wtest`'s `wtest_defhash_risky_text`
  textual stand-in (2g, above) is retired now that the gap it covered for
  is closed — `wtest_defhash_unchanged` no longer runs it, and
  `wtest_defhash_test` gained comment-only-edit/real-edit/rename cases
  per kind (`tests/defhash_generic_fixture*.w`) proving both the SKIP and
  the FALLBACK paths still fire correctly; `wtest_defhash_scratch_test.sh`
  gained a matching real-git-history case proving a file with both a
  generic and an operator overload now SKIPs on a comment-only edit
  (previously always fell back). `--closure`'s `defhash_is_known_definition`
  (`compiler/compiler.w`) also moved off its linear scan over every
  recorded definition (fine at this repo's own scale -- a single file by
  default, ~360 definitions for the whole `lib.lib` closure under
  `--closure` -- but not O(1) for a program an order of magnitude
  bigger) to a `map[char*, int]` existence index populated by
  `defhash_note` --
  the same string-set idiom `libs/extras/c_import/importer.w`'s
  `ci_imported_functions` already uses (both compile under the pinned
  seed), so this introduces no new pattern. The `return name in
  defhash_name_index` direct-return segfault originally found here was
  never an `in`/codegen defect at all: root cause was
  `code_generator/dwarf.w`'s `debug_local_note` realloc'ing the
  word-sized `debug_local_names` pointer array with 4-byte-int sizes
  (fixed 2026-07-19, f13ab7f) — heap corruption gated on the compiled
  tree crossing >4096 recorded locals, which is why source-shape
  changes here appeared to matter and an isolated repro never
  reproduced. The `int found = ...; return found` split was reverted
  2026-07-25 (direct return restored); see `ai_tooling.md`'s status
  entry for the full trio closure.

## Build manifest (`wbuildgen`)

- **Shipped (2026-07-19, wave plan C task 2d): path-based target deps.**
  `# wbuild: tool=<path>` resolves a tool's own `.w` source (e.g.
  "tools/wvc.w") to the name of the existing `build.base.json` target
  that compiles it and adds it to a generated target's "deps" alongside
  "wv2" (`wbg_find_target_by_source`/`wbg_resolve_tool_name`,
  `tools/wbuildgen.w`); `# wbuild: fixture_group=<name>` groups several
  `tests/*_fixture.w` files sharing a group name into one generated
  `bin/wfixture` invocation. Migrated 11 of `build_system_next.md`'s
  bucket K (18): the 9 wfixture-driven targets (`buffer_field_assign_test`,
  `array_error_test`, `syscall_arity_test`, `int_literal_width_test`,
  `prefixed_string_literal_test`, `warning_test`, `type_system_error_test`,
  `type_system_warning_test`, `operator_overload_error_test`) via
  `fixture_group=`, plus `wvc_e2e_test`/`wexec_remote_cache_test` via a
  bare `tool=` directive on their existing conventional `_test.w`
  sources (these two needed no new generation mode at all — they were
  already single-source compile+run shaped; the missing "deps" entry
  was the *only* blocker, which is exactly bucket K's own framing of
  the gap). Fixture-group member order is alphabetical by path, not the
  hand-picked order some base targets had; verified behavior-preserving
  (each fixture's pass/fail is independent, wfixture's exit status is
  an aggregate) by diffing generated vs. committed JSON before merging.
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
- **(2026-07-19 review) protobuf stage 1 hardening backlog**: duplicate
  STRING/BYTES/MESSAGE occurrences of the same field leak the first
  allocation and diverge from proto3's merge-submessages rule
  (last-one-wins is only spec-correct for scalars/strings); decode-error
  paths leak allocations already stored into `out`;
  `pb_decode_message_field` recurses with no depth limit (attacker input
  nesting one length-delimited field per 2 bytes can overflow the
  stack); varint classifies a buffer ending at exactly 10 continuation
  bytes as TRUNCATED though it is already provably malformed, and
  `pb_skip_or_error` maps every skip failure to TRUNCATED (unknown-field
  11-byte varints misreport as truncation).
  *(2026-07-25: all five addressed -- PB_MAX_DECODE_DEPTH()/
  PB_ERR_DEPTH_EXCEEDED depth cap, proto3 last-one-wins for
  strings/bytes + recursive MERGE for duplicate submessages,
  pb_free_decoded error-path sweep, varint 10-continuation-byte
  reclassification, pb_skip_or_error error-kind propagation; asserted
  by tests/protobuf_test.w's hardening section and
  tests/protobuf_leak_test.w's debug-allocator leak checks.)*
- **(2026-07-19 review) attach-mode polish**: a non-SIGTRAP signal stop
  during the step-over-breakpoint single step (in both `at_continue` and
  `at_finish`) is silently discarded instead of stored in
  `attach_pending_sig`; the step bail-out messages say "continuing" but
  return to the prompt with the tracee stopped; `frame x` (non-numeric)
  silently selects frame 0; `tools/attach_test.sh`'s "frame selection:
  caller arg" case cannot detect a regression (both frames' `n` holds
  the same value) and run_case has no timeout (a re-arm regression hangs
  CI rather than failing).
  *(2026-07-25: all four addressed -- `at_hold_signal` stores the
  non-SIGTRAP stop for redelivery on the next resume in both paths; the
  step bail-outs now say "stopped" and print the stop location; `frame
  <non-number>` errors with `frame: not a number`; attach_test.sh wraps
  every wdbg run in `timeout 30`, counts two distinct breakpoint stops
  on both arches, and the fixture's fixed +7000000 call-site offset lets
  the frame-selection cases assert the caller's `n` differs from frame
  0's by exactly that delta. Hardware watchpoints -- the #123 remainder
  -- stay open, concretely scoped in docs/projects/debugger_attach.md's
  "Remaining" section.)*
- **Shipped (2026-07-25): all three driver arg-loop notes from the
  2026-07-19 review** (up-front unrecognized-option detection, the
  NDJSON record under `--json`, and the `ci_skip_extern_function`
  `warning()`/`--strict` interaction, resolved by demoting the skip
  notice to a plain `-v`-gated note). See `ai_tooling.md`'s status
  section. Residue: the `verbosity >= 1` internal debug traces
  (`promote()`, `sym_declare()`, per-field type dumps, ...) are now
  reachable from the CLI via `-v -v` — they run to completion (the
  cold-start null-`filename` crash in `compile_save`'s "back to" banner
  is fixed), but at ~45k lines for a hello-world they are a
  developer-only firehose; nothing distinguishes trace lines from real
  diagnostics, and several print to stdout. Fine for level >= 1; do not
  move anything user-facing onto those levels without a sweep.
- **(2026-07-19 review) recursion-guard coverage**: the expression guard
  triggers only on `(`-grouping re-entry; other deep shapes (60k nested
  calls, index/ternary/unary chains) still exhaust the real stack with
  no diagnostic. The tokenizer.w block comment overstates coverage.
  **Fixed (2026-07-25)**: the `(`-site counter moved to the entry of
  `grammar/unary_expression.w`'s `unary_expression()` — the one function
  every operand-position recursion (parens, call arguments, index
  subscripts, stacked unary operators, cast/constructor/literal
  arguments) descends through per nesting level — plus two increments
  for the cycles that recurse *above* the operand level, where each
  level's operand has already returned before the recursion happens:
  `grammar/conditional_expr.w`'s ternary branch (else-arm
  `conditional_expr()` / then-arm `expression()`; unguarded SIGSEGV
  measured by 2M levels) and `grammar/expression.w`'s `=`/compound
  right-hand sides (`a = a = ... = 1`, same shape). Same shared
  counter, 1000 limit and "expression nesting too deep" message at all
  three sites, so the existing 900-paren clean / 1500-paren error
  fixtures pass unchanged; call/index/ternary/unary/assignment chains
  are pinned by the new `*_nesting_error_fixture.w` fixtures in
  `recursion_depth_test` (plus a 900-level ternary clean companion).
  Still uncovered (unchanged): `lib/shell_commands.w`'s `wc` derives
  counts from `strlen`, so a file containing NUL truncates its counts.

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
- **`wexec_resolve_program` (tools/wexec.w) resolves a bare command name
  to the first *readable* file on `PATH`, not the first *executable*
  one — a manifest step naming `"env"` failed with a bare "command
  failed with exit status 127" while writing wave 1f's `wexec_lock_test`
  (2026-07-19), even though `/usr/bin/env` was on `PATH`: this sandbox
  also has a non-executable `~/.local/bin/env` (a `pyvenv`-style config
  file, `-rw-r--r--`) earlier in `PATH`, and `wexec_resolve_program`'s
  loop treats `open(candidate, O_RDONLY, 0) >= 0` as "found" without
  ever checking the executable bit, so it silently resolves to that file
  and `execve()` on it fails — with no diagnostic pointing at *why*
  (exit 127 alone looks identical to "not found anywhere"). Worked
  around in that test by using `sh -c "unset VAR; exec cmd..."` instead
  of `env -u VAR cmd`. Not fixed here (out of scope for wave 1f, and
  every other `PATH`-resolved command name already used across
  `build.base.json` — `diff`, `cmp`, `grep`, `timeout`, `wine`, ... —
  happens not to collide with a same-named non-executable file on any
  tested host, so this is latent rather than currently breaking a real
  target). Real fix: check the executable bit (or `access(path, X_OK)`)
  in the `PATH` search loop, and ideally have the exit-127 path name the
  resolved-but-unusable candidate instead of just "exit status 127".
  Fixed (2026-07-25): `wexec_candidate_is_executable` (lib/stat.w's
  statx wrapper, `mode & 0111`; a failed stat — the darwin/win64 stubs
  return -1 — degrades to the old readable-only answer so those
  platforms are unchanged) now filters the `PATH` loop, and the
  shadowing scenario is a regression step in `wexec_test`
  (tests/wexec/path_xok.json). The exit-127 diagnostic now names what
  `PATH` resolution actually did (2026-07-28,
  `wexec_status_127_message`): the readable-but-non-executable candidate
  it skipped and/or the plain nothing-found case, asserted by further
  `wexec_test` steps against the same fixture.
- **Test sources can assert on their own raw bytes.** `defer_test.w`'s
  `test_defer_closes_file_descriptor` asserts the first byte of
  `tests/defer_test.w` is the `'i'` of `import`, so prepending the new
  `# wbuild: x64` manifest directive as line 1 broke it at runtime while
  every compile stayed clean (2026-07-10, manifest-generation
  migration; the directive lives on line 2 there now). When a tool
  rewrites test sources en masse, grep the touched files for their own
  paths first; longer term, self-referential assertions should read a
  dedicated fixture instead of the test's own source.
- **A fixed-size array (`T[N]`) struct field is not flat inline
  storage — it carries a hidden runtime header before its data.**
  Found writing `libs/extras/protobuf/`'s generic, descriptor-driven
  encode/decode (wave plan C task 4d), which reads/writes struct fields
  generically via `addr + offset` byte arithmetic (the same style
  `structures/json_codec.w` already uses). A `char[8]` field tried as
  cheap `int64`-free storage for a "raw 8 bytes" test case: indexed
  access (`s.field[i]`) reads back correctly, but `cast(char*, &s)`
  at that field's offset shows 8 bytes of header (what looks like a
  capacity/pointer word followed by a length word equal to `N`) *before*
  the real element bytes, which start `2 * __word_size__` bytes later
  than the field's own offset. Root cause: `type_push_array()`
  (`compiler/type_table.w:233-245`) sets the array type's `type_get_size`
  to `(2 * word_size) + (length * element_size)`, not just
  `length * element_size` — confirmed by reading the function, not
  inferred. Any hand-rolled, reflection-style codec that computes a
  field's byte range via `type_get_size`/offset arithmetic (rather than
  going through the compiler's own array-aware codegen) will silently
  read/write the header instead of the data for a `T[N]` field. Worked
  around in `tests/protobuf_test.w` by using plain scalar fields (two
  adjacent `int32`s) instead of a `char[N]` field wherever the test
  needed raw-byte-range access; not otherwise a live bug since ordinary
  `s.field[i]` indexing is unaffected.
  *(2026-07-28: shipped -- `type_array_element_offset()` in
  `compiler/type_table.w` returns the 2-word data offset, with the
  header layout documented next to `type_push_array`'s size formula;
  the sibling trap, casting an array/slice expression to a pointer
  type the decay does not cover, now warns at the cast
  (`grammar/unary_expression.w`, frozen by
  `tests/array_cast_warning_fixture.w`).)*
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
- **Shipped (2026-07-28): the compiler no longer conflates a genuine
  `read()` error with EOF.** First half (2026-07-25):
  `getchar_checked`/`getchar_unbuffered_checked` in `lib/lib.w` return
  `GETCHAR_EOF()` (-1) at end of file and `GETCHAR_READ_ERROR()` (-2)
  when `read()` fails, sharing the per-fd buffer state with the (still
  byte-identical) legacy functions; pinned by
  `tests/getchar_checked_test.w`. Second half: `compiler/tokenizer.w`'s
  `getc()` — the single choke point every compiler source read flows
  through (`compile_attempt` for the root and each import, the
  generic/defer reparses, the defhash rehash, the REPL entry loader, all
  of which point `filename` at the file before reading) — now reads via
  `getchar_checked` and reports `read error while reading '<file>'`
  through the normal `error()` path (positioned at the current
  line/column, works under `--json`, REPL recovery unwinds it) instead
  of treating the failure as EOF and silently truncating the source into
  a clean-looking parse (or a misleadingly-positioned parse error).
  Exercised for real, no root tricks needed, by the new
  `read_error_test` (`build.base.json`): on Linux `open()` on a
  directory succeeds and `read()` on its fd fails with `EISDIR`, so
  compiling a directory path — which previously exited 0, parsing the
  failed read as an empty file — now fails with the diagnostic, checked
  as a root file (human and `--json` modes) and as an import.
- **Shipped (2026-07-19, wave plan C task 1c): `lib/generator.w`'s
  `__w_gen_create` coroutine-stack `mmap()` is now checked** —
  `__w_gen_mmap_failed()` mirrors `debug_tbl_mmap_failed()`'s convention;
  on failure prints `generator: out of memory (coroutine stack mmap
  failed)` and exits 1. No fixture (needs real memory exhaustion, same
  precedent as 35ed0f5).
- **Shipped (2026-07-19, wave plan C task 2h): recursion-depth guards
  close the last silent-`SIGSEGV` gap.** Two independent counters
  (`compiler/tokenizer.w`) catch runaway recursive-descent nesting before
  the parser's own call stack overflows: `expr_nesting_depth`, checked in
  `grammar/primary_expr.w`'s `'('` branch (the only place paren-grouping
  re-enters `expression()`, the top of the expression grammar), errors
  `expression nesting too deep` past 1000 levels; `stmt_nesting_depth`,
  wrapping the whole body of `grammar/statement.w`'s `statement()` (the
  single function every nested `{...}`/`:`-block/if/while/for/switch body
  recurses back through, so one guard there covers every statement-level
  recursion path), errors `statement nesting too deep` past 200. Both
  route through the normal `error()` path (works under `--json`, and
  unwinds a REPL recovery longjmp correctly) and reset to 0 at the start
  of every compile (`compiler/compiler.w`'s `compile_attempt`) and every
  REPL entry (`repl/core.w`'s `repl_compile_entry`), so a longjmp — which
  skips every pending decrement — can never poison the next compile/entry
  with a stale count. Manually confirmed: a 100000-deep nested-paren file
  that previously `SIGSEGV`'d now exits 1 with the diagnostic, both in
  plain and `--json` mode; a native paren-chain crash was measured
  between 40000 and 60000 levels deep before this change, so 1000 leaves
  large headroom. Fixtures: `tests/expression_nesting_{error,clean}_
  fixture.w` (1500 vs. 900 nested parens) and `tests/statement_nesting_
  {error,clean}_fixture.w` (220 vs. 150 branches of an `if`/`else if`
  chain — see the next entry for why the exact numbers matter), wired
  into the new `recursion_depth_test` target via `bin/wfixture`.
  `parser_generator_w_test` was checked against both new fixtures
  (`tests/parser_generator/w.pg` untouched — no new syntax) and stayed
  green with no depth-related PG issues found.
- **Found while shipping the above: `code_generator/x86.w`'s
  `ctrl_kind_stack`/`ctrl_val_stack` are fixed `int[256]` arrays, and
  nested control-flow statements can already exhaust them well short of
  any real call-stack limit.** Every open `if`/`while`/`for`/`switch`
  region holds one array slot (two, for an `if`, until its `else` arm
  starts) until it closes, so *true* nested bodies (an `if` whose body is
  another `if`, etc.) hit the array's bound at 129 nested `if`s (2 slots
  each) or 86 nested `for`s (3 slots each); an `if`/`else if` dispatch
  chain — which recurses `grammar/statement.w`'s `statement()` through
  the `else` arm exactly like true nesting, but only holds ~1 slot per
  branch since each branch's own second slot frees before the next
  `else` is parsed — survives to 255 branches, failing at 256 (all
  measured exactly). This is *why* task 2h's `stmt_nesting_depth` limit
  is 200 rather than a rounder, larger number: it has to clear the tree's
  longest legitimate chain (`lib/lib.w`'s errno-to-string dispatch, 132
  branches) while staying under 256, so it cannot also preempt the
  narrower 129/86 bounds for genuinely nested (non-chain) control flow —
  those two shapes still hit the pre-existing array bound first, which
  prints a real (if compiler-internal-looking) diagnostic via
  `__w_bounds_trap`/`__w_list_index_trap` — `index out of range: index
  256, length 256` plus a stack trace — rather than segfaulting silently,
  so it is not the same class of bug 2h closes, just a related, narrower
  gap. Real fix: make `ctrl_kind_stack`/`ctrl_val_stack` grow dynamically
  (or move them off a fixed-size array entirely) instead of picking a
  bigger constant. **Fixed**: the stacks are now malloc'd `int*` buffers
  (initial capacity 256, doubled on push by `ctrl_stack_reserve()` in
  `code_generator/x86.w`; byte sizes computed with `__word_size__` since
  the entries are word-sized ints — the f13ab7f lesson). One correction
  to the analysis above, measured while writing the regression test: a
  *genuinely* nested if/for level costs 2 `stmt_nesting_depth` units,
  not 1 (the statement and its `:` block each recurse `statement()`), so
  the 200-unit guard already fired at 100 pure nested ifs — before the
  129-if array bound, which was in practice reachable only by `for`
  nests (86, 3 slots each) and for-heavy mixed shapes. Post-fix the
  guard is the only nesting bound: ~99 genuinely nested levels, 200
  chain branches. `tests/deep_nesting_test.w` (a generated file) pins
  95 nested fors (285 ctrl slots at peak), an 88-for/9-if mix (282,
  with the if regions past slot 256), and a guard-max 97-if nest, all
  asserted to execute correctly on x86 and x64; the first two trapped
  at `index 256, length 256` on the pre-fix compiler.
- **Found while shipping 2h: piping a very long single line (10000+
  characters) containing deeply nested parens into the interactive REPL
  (`bin/repl < file`, no PTY) does not reliably reach the second REPL
  entry.** A 5000-deep nested-paren one-liner followed by further entries
  on their own lines: the nesting-too-deep diagnostic printed correctly,
  but the entries after it were never evaluated and the process exited
  0 instead of running them. Narrowed to the combination of extreme line
  length and deep nesting specifically — a plain long line (3000 `+`-
  joined terms, no nesting) recovers and evaluates the next entry
  normally, and a shorter deep-paren line (1100 levels, ~2200 characters,
  still past the 1000-level guard) also recovers correctly. Likely the
  REPL's own interactive line reader (distinct from the compiler's
  grammar-level recursion `compiler/tokenizer.w`'s counters guard)
  buffers or re-scans raw input in a way that behaves differently at
  that combined size; not investigated further since it falls outside a
  piped, non-PTY invocation `repl_test`'s `script -qc` fixtures don't
  exercise this exact shape either. Worth a closer look before relying on
  giant single-line REPL input in agent tooling.
  **Fixed (2026-07-25)**: the culprit was `repl.w`'s `repl_read_plain`
  (the piped/non-tty reader), whose fixed 4096-byte buffer consumed the
  whole physical line but silently kept only the first 4095 characters
  — a truncated deep-paren line left `repl_scan_depth` permanently
  positive, so every later line was swallowed as a `..` continuation of
  the same entry until EOF and the process exited 0 (exactly why the
  ~2200-char deep line and the flat 3000-term line both "recovered":
  one fit the buffer, the other truncated without unbalanced brackets).
  `repl_read_plain` now appends straight into the `repl_line`
  string_builder with no length cap; a 5000-deep 10001-char one-liner
  gets the normal per-entry "expression nesting too deep" rollback and
  the next entry runs, pinned by `tests/repl_giant_entry_fixture.txt`
  in `repl_test`/`repl_test_x64`. The interactive raw-mode editor
  (`lib/line_edit.w`) keeps its own 4096 buffer — typed/pasted lines at
  a real prompt, deliberately untouched here.
- **Shipped (2026-07-19, wave plan C task 1g): unrecognized CLI flags
  now get a real diagnostic.** `link_impl`'s flag loop (the common tail
  for link/check/deps/symbols/defhash) errors `unrecognized option:
  '<arg>'` and exits 1 for any unknown `-`-prefixed argument instead of
  treating it as an input filename; pinned by
  `unrecognized_option_test` (which also guards that `--bounds=off`
  still parses as a flag).
- **`lib/process.w`'s `process_run`/`process_run_windows` take `stdin_text`
  as a `char*` and compute its length with `strlen`, so a subprocess
  input containing an embedded `0x00` byte silently truncates at that
  byte instead of being written in full — stdout/stderr capture is fine
  (`process_capture_read` tracks byte counts, not a C string), only the
  *write* side has this gap. Not hit by wave plan C task 2e's zlib/gzip
  interop port (`tests/compress_zlib_interop.w`): that harness passes
  binary compressed bytes through scratch files instead of subprocess
  stdin/argv specifically to sidestep this (and to avoid interpolating
  bytes into a spawned script's source text at all). Worth fixing before
  any future harness needs to *pipe* binary data into a child process
  (a length-taking `process_run_bytes(path, argv, opts, char* stdin,
  int stdin_length, timeout_ms)` twin, or an overload, would cover it).
  **Shipped (2026-07-25): `process_run_bytes` (and
  `process_run_windows_bytes`) take that explicit `stdin_length`;
  `process_run`/`process_run_windows` are unchanged strlen-measuring
  delegates. Pinned by `tests/process_bytes_test.w` (embedded-NUL and
  >4KB payloads round-tripped through `/bin/cat`, plus the legacy
  truncation contract).**

## ParserGenerator streaming codegen (`libs/extras/parser_generator/`)

All three 2026-07 review findings here are resolved (trailing action-only
alternative accepted as epsilon dispatch; `$1`-runs-into-identifier
rejected at generation time; the shared-prefix nullable-suffix shape that
once segfaulted the streaming emitter is a `pg_report_choice`
generation-time rejection). The one residual ergonomic gap — a nullable,
non-empty factored suffix was rejected, not compiled — **shipped
2026-07-28**: `rule value = IDENT WS? | IDENT` (streaming) now compiles,
with the nullable suffix emitted as the choice's final fallback branch
and its dead strict-epsilon siblings dropped
(`pg_choice_unit_is_nullable_fallback` in `analysis.w`, live-unit trim in
`pg_emit_streaming_choice`; the suffix may also sit mid-alternatives
behind guarded siblings). A nullable suffix ahead of a *live* sibling —
the shape whose emission used to segfault — stays a generation-time
rejection, re-pinned by `tests/parser_generator/streaming_guard_reject.pg`
(now `rule value = IDENT WS? | IDENT NUMBER`) and
`generated_streaming_test.w`; the accepted shapes are pinned by
`streaming_fallback_sample.pg` / `generated_streaming_fallback_test.w`.
Details in `docs/projects/parser_generator.md`.

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

## REPL surface (`repl.w`, consumed by wtools' `repl_eval` and skills)

- **(2026-07-19 review) Paste/line-editor gaps found reviewing wave C's
  bracketed-paste + Ctrl-R work** (none block the piped/agent path).
  Fixed 2026-07-25 (`lib/line_edit.w`, unit-tested by
  `tests/line_edit_paste_test.w`): `le_paste_match_end`'s partial
  ESC-sequence mismatch now pushes every probed byte back through a new
  editor-local pushback stack (`le_pushback`/`le_getchar`, which every
  editor read goes through — the stack doubles as the unit-test input
  seam for the tty-only paths a plain pipe cannot script); pasted CRLF
  endings no longer inject a blank line per line (`le_paste_eat_crlf`
  consumes the pending LF with the CR); mid-paste line fragments are no
  longer pushed into history (`le_finish_line` skips accept while the
  paste is open — history stays strictly line-shaped, so the one line
  the user actually finishes with Enter after the paste closes is the
  entry); completion candidates no longer truncate at 64 (le_try_complete
  doubles the buffer while the hook reports it full, which also fixes the
  truncated set's over-inserted common prefix); `le_paste_consume`'s
  auto-indent-seed drop is byte-exact (`le_text_equals` against the
  seed's snapshot), so same-length typed text survives a paste. The
  remaining three gaps closed 2026-07-28: a pasted embedded newline now
  renders the completed line before accepting it (`le_paste_finish`), so
  a multi-line paste no longer shows one bare newline per line; an ESC
  during Ctrl-R probes for a following `[`/`O` before acting, so an
  arrow key ends the search (the match becomes the live buffer) and is
  re-delivered whole to the ordinary dispatch loop instead of
  half-cancelling and inserting a residual "[A"; and `le_render_search`
  climbs `le_prev_rows` before clearing, the way `le_render` does, so
  starting a search on a wrapped line repaints its stale wrapped rows.
- **(2026-07-19 review) shell-mode translator divergences** — fixed
  2026-07-25 (`repl/shell_translate.w`, pinned by
  `tests/shell_commands_test.w`): `echo` now honors `-n` only as a
  leading run (a later `-n` is literal text, matching real echo);
  `head`/`tail` no longer accept the inline `-n=5`/`--lines=5`
  spellings — those fail closed to native so the real tool's own
  acceptance or diagnostic applies verbatim; `mkdir`/`rm` (and the
  shared tokenizer teardown) free their `list[char*]` structs on every
  path. `wc` also stopped deriving its counts via strlen, which
  truncated all three figures at an embedded NUL byte
  (`lib/shell_commands.w` now reads through a stream and uses the true
  byte length).

- **Shipped (2026-07-28, wave 4): a top-level declaration may carry a
  compile-time constant initializer, so a typical `:save`d session
  round-trips.** `int x = 5` was valid at the REPL (`repl_entry_item`
  in `repl/core.w` special-cases a top-level "name = expression") but
  rejected standalone with `Could not find a valid primary expression,
  token: =`, so `:save`ing a session and compiling it back did not
  round-trip. `grammar/program.w`'s `global_initializer` now stores the
  constant straight into the bytes `define_global_variable` reserved —
  the C model, no init code before main, so nothing new enters the
  entry path on any backend (a runtime hook was rejected: `lib/lib.w`'s
  `_main` cannot call a driver-synthesized symbol the pinned seed does
  not define). Integer/char/enum constants and the fixed-width int
  types are supported; a value needing code to materialize (list, map,
  set, string, slice, array, struct, float) is refused by name
  (`cannot initialize global 'items' of type 'list[int]' at its
  declaration; assign it inside a function`), as is a non-constant
  initializer (`initializer for global 'computed' must be a
  compile-time constant, got 'compute'`) — both an improvement on the
  bare parse error. `tests/toplevel_init_test.w` plus the
  `toplevel_init_error_test` fixtures; `tests/parser_generator/w.pg`
  needed no change (its `global_suffix` already allowed `ASSIGN
  expression`). Float initializers are the obvious next step (their bit
  pattern is a compile-time constant too) and are deliberately not in
  this pass.

- **`string_free(b)` immediately followed by `free(b)` on the same
  `string_builder*` corrupted the heap, but only inside `repl.w`'s full
  startup context.** Found while adding the `--json` NDJSON mode (issue
  #276 P3, 2026-07-16): `repl_eval_json`'s helper built a `string_builder`,
  read a captured-output file into it, then did the textbook-looking
  `char* result = strclone(b.data); string_free(b); free(b); return
  result;` — the very next `json_object()`/`json_object_set()` call in the
  caller would then see a `json_value*` with a garbage `.type` field, or
  segfault outright on a later `malloc`/`free`. Confirmed via bisection
  across ~40 throwaway repro programs: (1) not reproducible standalone —
  a tight loop of `string_new()` + `string_append` + `string_free` +
  `free` in isolation (`structures.string` + `lib.lib` only) never
  corrupts; (2) reproducible once the program links `repl.w`'s full import
  set (`repl.core`, `debugger.wdbg`, `lib.shell`, etc.), calls
  `repl_init()` + the wdbg trap-handler install, and runs at least one
  `repl_eval()` before the `string_free`+`free` pair — the surrounding fd
  save/restore dance (`dup2`) and echo-hook wiring were *not* required
  once that much was present, so the trigger is somewhere in the
  interaction between `repl_eval`'s in-process JIT machinery (or the
  debugger/fault-handler setup) and the general-purpose allocator, not in
  `string_free`/`repl.w`'s own logic. Workaround applied in `repl.w`
  (`repl_format_echo`'s string-typed echo case and
  `repl_json_read_capture`): skip `string_free` and just take `b.data`
  directly before `free(b)` — the same ownership-transfer idiom
  `string_builder_to_string`/`__w_template_finish` already use, which
  sidesteps the bug entirely and needed no extra allocation. Every other
  `string_free(x); free(y)` pair in the tree already frees two *different*
  pointers (builder vs. some unrelated buffer); grepping confirms `repl.w`
  was the only place calling `string_free(b); free(b)` on the same `b`.
  Root-caused 2026-07-18 (`docs/projects/repl_allocator_interaction.md`):
  no REPL/JIT dependency at all — `string_free(b)` already frees `b`
  itself, so the pair is a plain double free, and `lib/memory_freelist.w`
  has no double-free detection, so the second `free()` corrupts that size
  class's free list into a permanent self-loop that aliases every later
  allocation of a matching size onto the same address (reproduced
  standalone with raw `malloc`/`free`, no `repl.w` imports). The doc
  covers why the earlier bisection looked REPL-specific, rules out the
  signal-handler and checkpoint/rollback hypotheses with citations, and
  recommends `W_DEBUG_ALLOC=1` for catching this class of bug in the
  future rather than hardening the production allocator under a timebox.

- **`script -qc bin/repl /dev/null` cannot script a keystroke bound to a
  canonical-mode special character (Ctrl-R, and by the same reasoning
  Ctrl-C/Ctrl-U/Ctrl-W/Ctrl-D/Ctrl-Q/Ctrl-S/Ctrl-\\) fed through a plain
  pipe.** Found while adding Ctrl-R incremental history search
  (`lib/line_edit.w`, issue #276 P2, wave 3a). `printf '...\x12...' |
  script -qc ./bin/repl /dev/null` silently drops the `\x12` (Ctrl-R)
  byte — confirmed with a temporary `getchar()`-return debug print that
  the process never observes the value 18 at all, even as the very first
  byte of stdin, with or without a prior successful entry ahead of it.
  Root cause: `script` delivers a piped, non-interactive stdin to the pty
  in one burst, and that burst lands in the kernel's tty input queue
  while the pty is still in its *default* (canonical, `ICANON` on) mode —
  `repl_init()` self-hosts a chunk of the stdlib into memory before the
  first `term_raw_mode()` call, which is enough wall-clock time for the
  whole burst to already be queued and processed under canonical rules.
  Canonical mode treats `Ctrl-R` as `VREPRINT`, a line-editing command
  the driver consumes on the spot (a no-op on an empty line) rather than
  queuing as data — once the byte is gone, no later `ioctl(TCSETS)` call
  un-consumes it. Plain characters, Enter and ESC-prefixed sequences
  (bracketed paste's `\x1b[200~`/`\x1b[201~`, arrow keys) are unaffected
  (no canonical-mode binding), which is why the paste and Tab-completion
  `script -qc` cases added alongside this one work reliably. Worked
  around by verifying Ctrl-R with a small ad hoc Python `pty` harness
  that waits for the "w> " prompt to actually appear on the master side
  (proof `term_raw_mode()` has already run) before writing the next
  keystroke, and by unit-testing the pure search-state transitions
  (`le_search_begin`/`le_search_refine`/`le_search_older`/
  `le_search_backspace` in `tests/line_edit_completion_test.w`) directly,
  bypassing `getchar()` entirely. **Shipped (2026-07-28):
  `tools/pty_test.py`** is that reusable harness — it spawns the command
  under a real pty and waits for a marker (e.g. the "w> " prompt, proof
  `term_raw_mode()` already ran) before writing each keystroke chunk,
  driven by a simple expect/send script format with `\xHH` escapes;
  `tests/repl_pty_ctrl_r.pty` scripts a Ctrl-R history search end to end
  against a fresh repl build (build.base.json's `repl_pty_test` target),
  so future agents can script this class of keystroke instead of
  falling back to manual verification each time.

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
- **`wtest changed` selects the near-full suite for any
  `lib/__arch__/*/syscalls.w` edit and says nothing about it.** The
  socketcall cleanup (2026-07-28) made `git diff --name-only
  origin/main | bin/wtest changed` print ~450 targets — correct
  (syscalls.w is in every program's closure, including the compiler's,
  so `verify` is also implied) but unhelpful as a "focused test" list,
  and the residue rules did not surface `verify` for it. When the
  selection exceeds some threshold (say half the manifest), a one-line
  summary like "selection is effectively the `tests` umbrella; run
  `./wbuild tests` (and `verify` — compiler closure touched)" would
  save agents from pasting hundreds of targets and from missing the
  verify gate.
- **Minor: a flag before the arch selector turns the selector into the
  input file, with a misleading error.** `bin/wv2 --strict x64 file.w
  -o out` fails with `no such file: 'x64' in x64:1` after printing
  `compiling 'x64'` — the arch token is consumed as the source path
  once any flag precedes it. `bin/wv2 x64 --strict file.w -o out`
  works. Found 2026-07-28 compiling a test's x64 twin by hand.
  Cheap fix: recognize arch-selector tokens anywhere before the input
  file (or error with "arch selector must come first"), so the
  diagnostic names the real problem instead of a phantom file.

## Skills / rules upkeep

- Keep skill command examples in sync with CLI changes (they are
  hand-verified snapshots, nothing asserts them). A cheap
  `skills_test` that greps the documented flags against `--help` output
  would catch drift once the compiler grows a help text.
- Candidate new skills as workflows stabilize: ARM64 testing under
  `qemu-aarch64` (see `docs/projects/arm64.md`), seed updates
  (`./wbuild update` discipline), and C interop debugging (`c_import`).
