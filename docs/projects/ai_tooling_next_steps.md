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

- **Array-to-pointer decay corruption is fixed.** Issue #220 (found
  during the buffered-getchar work, #113, 2026-07-09) is closed: PR #225
  implemented real decay (`coerce()` in `grammar/promote.w` loads the
  descriptor's data pointer instead of passing the descriptor address)
  across call arguments, initialization, assignment, return, container
  literals/push/insert, membership keys and switch cases. Three narrower
  edge cases were consciously left out of that fix — C-variadic tails,
  `cast(int, arr)` vs `cast(char*, arr)`, and one arm of a conditional
  expression — none of which corrupt memory (wrong-but-visible descriptor
  address, or a lingering warning); they're tracked in issue #229.
- **Multi-error reporting.** The compiler stops at the first error
  (single-pass, no recovery). Documented limitation; real fix is parser
  recovery, which stays a research project. Cheap partial win: after an
  error in file A, agents re-check to find errors behind it — nothing to
  build, just keep the limitation documented in skills.
- **Compiler-internal files cannot be checked standalone, and the error
  points elsewhere.** `./bin/wv2 check --json code_generator/arm64.w`
  (hit while fixing #174, 2026-07-10) fails with `Cannot find symbol:
  'strlen'` reported *in code_generator/code_emitter.w* — the file only
  compiles inside `w.w`'s import graph, but the diagnostic names neither
  the checked file nor the real cause. Either make `check` on a
  compiler/grammar/code_generator path check `w.w` instead (that is the
  gate that matters), or emit a one-line "this file is not a standalone
  compilation root" hint.
- **Library modules cannot be checked standalone.** `./bin/wv2 check
  --json libs/standard/crypto/sha2.w` (hit while adding the TLS crypto
  modules, #195, 2026-07-10) fails with `Failed to find a _main()
  function` — `check` fully compiles, so a main-less library file can
  only be checked through a program that imports it (its `_test.w`).
  A `check` mode that stops after semantic analysis (no entry-point
  requirement) would let hooks check library modules directly.
- **Bool-bitwise condition warning is lvalue-scoped for now.** The
  shipped "did you mean `||`/`&&`?" hint (2026-07-10) only fires when
  both `|`/`&` operands are bool-typed *lvalues* in an if/while
  condition. Comparison-result operands — `(a == b) | (c == d)` — stay
  exempt because that spelling is the established style of the
  pre-`&&`/`||` compiler sources: enabling it fires 469 times in the
  seed graph alone, 80 of them in the *generated*
  `libs/extras/c_import/generated_c_parser.w`, so widening the scope
  needs a dedicated style-migration PR (a per-site short-circuit safety
  review plus a parser-generator emission change) first.

## Test selection (`bin/wtest`)

- **`wtest changed --run` — landed.** `wtest` now takes a `--run` flag:
  after printing the selection (unchanged), it spawns `bin/wexec` itself
  with that target list, inheriting stdio so build output streams live,
  and exits with its status — instead of a caller piping `wtest`'s
  output through `./wbuild test_changed`'s `xargs -r ./wbuild`. An empty
  selection is a no-op, matching `xargs -r`'s behavior on empty input.
  A companion `-f manifest.json` flag (mirroring `bin/wexec`'s own)
  overrides the manifest for both selection and, under `--run`,
  execution; it exists so `--run` can be tested in isolation
  (`wtest_run_test` in `build.base.json`, fixture at
  `tests/wtest/run_fixture.json`) without ever selecting a real target
  whose own steps shell out to `bin/wtest`, which would recurse through
  the live manifest.
- **`.txt` doc-only filter swallowed `tests/asm/` corpus fixtures — fixed
  (issue #171).** `wtest_doc_only` in `tools/test_map.w` treated every
  `*.txt` path as documentation (meant for `docs/todo.txt`), so
  `tests/asm/corpus_{x86,x64,arm64}.txt` — runtime fixture data for the
  whole asm test suite, not docs — never reached the `tests/asm/` residue
  rule; `wtest changed` silently selected nothing for a corpus-only
  change. Found while wiring the new `asm_fuzz_*` property/fuzz targets,
  which read those same fixtures. Fixed by excluding `tests/asm/` from
  the doc-only check before the extension test; pinned by a new
  `wtest_map_test` case (`build.base.json`).
- **`./wbuild test_changed` is silently a no-op once the work is
  committed.** The wbuild wrapper pipes `git diff --name-only HEAD`
  into `wtest changed`, so after `git commit` (the natural state right
  before pushing) it selects zero targets, prints nothing, and exits 0
  — indistinguishable from "all selected tests passed" (2026-07-11,
  found while validating the `https_e2e_test` flake fix; the real
  selection needed `git diff --name-only origin/main...HEAD | bin/wtest
  changed | xargs -r ./wbuild`). Either default the diff base to the
  upstream/merge base when the working tree is clean, or print an
  explicit `wtest: 0 targets selected (diff base HEAD)` line so an
  empty selection can't pass for a green run.

- **Adding a single new `_test.w` always selects the full `tests`
  umbrella, defeating "focused" selection.** Observed adding
  `tests/vcs_commit_test.w` (issue #252 V2b, 2026-07-11): the required
  workflow is create the test, run `./wbuild manifest` to regenerate
  `build.json` (both are committed together, per the `build.json` is
  GENERATED rule), then `git diff ... | bin/wtest changed`. But
  `tools/test_map.w`'s documented residue rule --
  `build.json / wbuild / build.base.json -> wexec_test + tests` ("the
  manifest drives every target") -- fires on every such diff, since the
  regenerated `build.json` is *always* part of it. The net effect: the
  single most common "add one test" workflow always recommends running
  the entire pre-merge suite (`tests`, which pulls in `verify` and
  hundreds of unrelated targets) instead of the one or two new targets
  that actually matter, even when nothing in the change touches the
  build system itself. A worthwhile refinement: special-case a
  `build.json` diff that is *exactly* the addition/removal of leaf test
  target entries (the common `wbuildgen`-generated shape) to select just
  those new/changed target names plus `manifest_check`, falling back to
  the full `tests` residue only when the diff also touches hand-written
  `build.base.json`-derived entries or existing target definitions.

## Debugger surface (consumed by the external integration tools)

- **Conditional breakpoints/hit counts/logpoints have landed** (design:
  `docs/projects/debugger_conditional_breakpoints.md`, status:
  implemented). They add new stable, grep-able output lines (`logpoint N
  hit H: expr = value`, extended `info breakpoints` fields) to the same
  text protocol — still worth keying a future structured wrapper off, and
  still worth a `w-debug-wdbg` skill example.

## Cleanup observed while dogfooding

- **`parser_generator_w_test` retained every parsed AST — fixed by
  batching (2026-07-12).** `test_parse_all_tracked_w_files` parsed all
  tracked `.w` files in one process, retaining every AST, so the
  32-bit gate segfaulted (exit 139) once tracked source crossed
  ~3.7MB — six new library files tipped it, and removing ANY one of
  them "fixed" it, a misleading bisect signature worth remembering.
  First attempt — freeing per-file ASTs/sources/diagnostics — was
  correct but catastrophically slow: recursive frees through the
  first-fit allocator turned the 2-minute gate into a 90-CPU-minute
  crawl (CI's 30-minute budget times out), and fragmentation kept RSS
  growing anyway. The landed fix is
  `tools/parser_generator_w_batches.sh`: rerun the test binary once
  per 150-file slice of the manifest, bounding memory at batch size
  forever (~21s total). Residual: the allocator's quadratic
  free/malloc behavior under millions of small blocks is real and
  will bite the next long-lived process too — an arena or size-class
  allocator is the durable fix.

- **Test sources can assert on their own raw bytes.** `defer_test.w`'s
  `test_defer_closes_file_descriptor` asserts the first byte of
  `tests/defer_test.w` is the `'i'` of `import`, so prepending the new
  `# wbuild: x64` manifest directive as line 1 broke it at runtime while
  every compile stayed clean (2026-07-10, manifest-generation
  migration; the directive lives on line 2 there now). When a tool
  rewrites test sources en masse, grep the touched files for their own
  paths first; longer term, self-referential assertions should read a
  dedicated fixture instead of the test's own source.
- **One-off targets assuming `bin/` exists — resolved.** The
  Makefile-to-`wbuild` migration handles it uniformly: `wbuild` and the
  manifest's `dirs` create `bin/` for every target.
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
- **wexec is fail-fast; one broken target silently cancels the rest of
  an umbrella run.** During the 2026-07-09 full-suite run, the
  `c_import_test` failure stopped scheduling with 58 of 116 `tests`
  targets attempted, and the `attach_test` failure later cut another 10
  — with no "N targets skipped" summary, so lost coverage is easy to
  miss. Add a `--keep-going` mode (run everything, summarize failures
  at the end) for test-suite runs, and print how many targets were
  skipped when stopping early.
- **The compiler can exit 1 with no diagnostic at all.** The pre-refresh
  darwin seed compiling current `w.w` (post-#128 `libs/extras`) printed
  only the `compiling 'w.w'` banner and exited 1 — nothing on stdout or
  stderr (2026-07-09; the same constructs in a small probe file produced
  a proper `list field 'append' not found` error, so some deep error
  path exits without a message). Audit compiler exit paths so every
  failure prints at least a one-line diagnostic; a silent exit cost a
  full bisect to find the offending construct.
- **Transitive-import reliance is invisible until it breaks.** Three
  times on 2026-07-09 alone, removing an import from one module broke a
  *different* file that had silently resolved symbols through it:
  `tools/lsp/w_lsp.w` used `hash_map` via `structures/json.w` (#145),
  and `bignum_test`/`type_table_test`/`c_preprocessor_test` used
  `error()`/`word_size` via `lib/testing.w`'s old compiler imports
  (#147). The unqualified-alias warning covers aliased imports only;
  plain imports re-export everything silently. A `w check` mode (or
  `windex` query) that flags symbols resolved from modules the file
  does not import directly would catch this class before CI does.
- **`w check` on multiple root files reports bogus `symbol redefined`
  errors.** `bin/wv2 check --json w.w compiler/compiler.w` fails with
  `symbol redefined: 'file_not_found_error'` because check links all
  arguments as one unit, so a root that is also inside another root's
  import closure gets compiled twice (2026-07-11). Agents naturally pass
  "the files I changed"; check should skip roots already reachable from
  earlier arguments (or check each argument as its own unit).
- **`|`/`&` in condition position deserve a warning.** The bitwise
  operators never short-circuit, and generated guard-heavy protocol
  code (libs/standard/distributed) keeps almost tripping on
  `if (p != 0 & p.field)`-style guards that read fine but evaluate
  `p.field` unconditionally. A `w check` warning when `|`/`&` appear
  directly in an `if`/`while` condition with comparison operands —
  suggesting `||`/`&&` — would turn a latent crash into a compile-time
  nudge. Semantics must not change (bitwise-in-guards is occasionally
  intentional; masking tricks in bitset.w/sha256.w rely on plain `&`),
  and the message text is new, so warning_test fixtures gain a case
  rather than reword one (2026-07-11).

## Skills / rules upkeep

- Keep skill command examples in sync with CLI changes (they are
  hand-verified snapshots, nothing asserts them). A cheap
  `skills_test` that greps the documented flags against `--help` output
  would catch drift once the compiler grows a help text.
- Candidate new skills as workflows stabilize: ARM64 testing under
  `qemu-aarch64` (see `docs/projects/arm64.md`), seed updates
  (`./wbuild update` discipline), and C interop debugging (`c_import`).
