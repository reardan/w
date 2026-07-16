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
- **`wtest changed`'s deps cache cold-starts slowly after large merges.**
  Two agents hit first-run `bin/wv2 deps` closure rebuilds exceeding 2
  minutes (docs advertise ~35s) right after a many-file merge landed
  (2026-07-16). Not a correctness issue — later runs are sub-second —
  but the first `wtest changed` after an integration can look hung;
  consider a one-line progress note while the cache warms.
- **`./wbuild test_changed` cannot pass `--keep-going` through.** The
  wrapper hard-codes `xargs -r ./wbuild`, so a selection that hits one
  environment-gap target (missing qemu) abandons the rest; the caller
  has to replicate the pipeline by hand to add the flag (2026-07-16).
  Teach the wrapper to forward flags after the subcommand to wexec.
- **`wtest changed` selects targets the environment cannot run.**
  Touching any `lib/__arch__/*/syscalls.w` (or other whole-closure
  files) selects arm64/darwin/wine run-targets that need qemu, a Mac, or
  wine; there is no "skip unavailable runtimes" story, so agents either
  chase documented environment gaps or hand-prune the selection
  (2026-07-16). A `--available` filter (probe for qemu/wine/Mac once,
  drop targets whose runner is absent, print what was dropped) would
  make selections runnable as printed.
- **`wtest_map_check` fixture manifests are order-coupled to the real
  build.json.** The checker's implicit manifest-order property forces
  `-f` fixture manifests to reuse real target names in build.json
  relative order — a hidden coupling when writing new cases, documented
  in the checker header but still awkward (2026-07-16); a per-case
  opt-out or fixture-aware ordering would help.

## Debugger surface (consumed by the external integration tools)

- **Conditional breakpoints/hit counts/logpoints have landed** (design:
  `docs/projects/debugger_conditional_breakpoints.md`, status:
  implemented). They add new stable, grep-able output lines (`logpoint N
  hit H: expr = value`, extended `info breakpoints` fields) to the same
  text protocol — still worth keying a future structured wrapper off, and
  still worth a `w-debug-wdbg` skill example.

## Cleanup observed while dogfooding

- **Hex/binary literals wider than 32 bits were silently corrupted —
  resolved (2026-07-13).** The literal decoder kept only a rolling
  32-bit window of a literal's digits, so on the x64 target
  `0x7ff0000000000000` parsed to `0` and `0x000fffffffffffff` parsed
  to `0xffffffffffffffff` — no warning, no error. Distinct from the
  documented bit-31 sign-extension gotcha, and a straight bug for
  64-bit-word targets: until the tokenizer carries 64-bit (or bignum)
  literal values, wide constants must be assembled at runtime from
  sub-32-bit pieces (see `lib/sha256.w`'s runtime-built masks).
  Resolved by `int_literal_width_check()` (grammar/int_literal.w,
  shared by the expression, enum-value and parameter-default decode
  paths): any hex or binary literal with more than 32 significant bits
  is now a compile error instead of wrapping. Leading zeros carry no
  bits, so `0x00000000ffffffff` still compiles; the
  `int_literal_width_test` fixtures freeze the error message and
  `tests/warning_clean_fixture.w` pins the still-legal wide spellings.
  Extended 2026-07-16: decimal literals get the same guard
  (`int_literal_decimal_check()` — more than 10 significant digits, or
  exactly 10 comparing above 4294967295, is the same compile error;
  boundary spellings pinned by `tests/int_literal_bounds_test.w`), and
  the sweep for newly-rejected literals caught a real casualty: the
  win64 FILETIME epoch offset `11644473600` in
  `lib/__arch__/win64/syscalls.w` had been silently wrapping — win64
  `linux_time()` returned garbage — and is now computed at runtime.
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
- **wexec's interleaved parallel output can misattribute step
  failures.** Under `-j`, a passing step's stderr line rendered next to
  a later step's assertion made a green fixture case read as a
  cross-step failure while debugging expectations (2026-07-16). A
  `--no-parallel`/ordered-log mode (buffer each step's output, print in
  completion order) would make fixture debugging deterministic.
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
