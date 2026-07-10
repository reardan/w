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
- **stderr chatter.** `check --json` prints `compiling '...'` and
  `using filename as path directly: ...` progress text to stderr. Stdout
  is clean, so parsers are unaffected, but a `--quiet` flag would make
  hook/LSP/MCP logs less noisy.
- **Compiler-internal files cannot be checked standalone, and the error
  points elsewhere.** `./bin/wv2 check --json code_generator/arm64.w`
  (hit while fixing #174, 2026-07-10) fails with `Cannot find symbol:
  'strlen'` reported *in code_generator/code_emitter.w* — the file only
  compiles inside `w.w`'s import graph, but the diagnostic names neither
  the checked file nor the real cause. Either make `check` on a
  compiler/grammar/code_generator path check `w.w` instead (that is the
  gate that matters), or emit a one-line "this file is not a standalone
  compilation root" hint.
- **Arch-aware checking.** The hook and skills default to the x86 check;
  `lib/__arch__/x64/` files (and x64-only constructs like `int64`)
  deserve an automatic `check --json x64` pass when touched. Got worse
  with the graphics macOS backend (2026-07-09): `graphics/cocoa.w`
  declares `float64` extern parameters, so the default check reports
  "float64 requires the x64 target" on a perfectly healthy file — and
  there is no way to redirect it, because the target selector does not
  compose with the command (`wv2 x64 check --json f.w` parses "check"
  as a filename). Fix both: accept `wv2 <target> check` (or a
  `--arch=` flag), and infer the target from `__arch__` path segments
  and per-file markers so the hook picks the right one automatically.
  The new `w deps` subcommand (2026-07-10) inherits the same
  limitation: it resolves `__arch__` imports for the default target
  only, which is why `bin/wtest`'s closure selection needs residue
  rules for `lib/__arch__/` and `graphics/` — an arch-aware `deps`
  would let those rules retire too.
- **Library modules cannot be checked standalone.** `./bin/wv2 check
  --json libs/standard/crypto/sha2.w` (hit while adding the TLS crypto
  modules, #195, 2026-07-10) fails with `Failed to find a _main()
  function` — `check` fully compiles, so a main-less library file can
  only be checked through a program that imports it (its `_test.w`).
  A `check` mode that stops after semantic analysis (no entry-point
  requirement) would let hooks check library modules directly.
- **Bitwise `|`/`&` on `bool` operands deserves a "did you mean
  `||`/`&&`?" warning.** Agents keep drafting `a | b` guards expecting
  short-circuiting; it has bitten the conditional-breakpoint work
  (`docs/projects/debugger_conditional_breakpoints.md`), the stats
  library, and the plan-11 crypto wave (#193–#198, 2026-07). `bool` is a
  distinct type, so `bool | bool` / `bool & bool` in a condition is
  detectable; today it checks clean.
- **Hex literals with bit 31 set silently sign-extend into word-sized
  `int`.** `int mask = 0xffffffff` is `-1` on every target, so
  `x & 0xffffffff` is a no-op on x64 instead of a truncation; the plan-11
  crypto modules (2026-07) all work around it by building masks at
  runtime (`lib/sha256.w`'s `sha256_mask32`). A warning when a hex
  literal with bit 31 set (and no explicit-width type) binds to `int`
  would catch this class at edit time.

## Test selection (`bin/wtest`)

- **`wtest changed --run`.** Now that `lib/process.w` exists, `wtest`
  could execute the selected targets itself instead of relying on the
  `./wbuild test_changed` xargs pipeline.

## Debugger surface (consumed by the external integration tools)

- **Conditional breakpoints/hit counts/logpoints have landed** (design:
  `docs/projects/debugger_conditional_breakpoints.md`, status:
  implemented). They add new stable, grep-able output lines (`logpoint N
  hit H: expr = value`, extended `info breakpoints` fields) to the same
  text protocol — still worth keying a future structured wrapper off, and
  still worth a `w-debug-wdbg` skill example.

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

## Skills / rules upkeep

- Keep skill command examples in sync with CLI changes (they are
  hand-verified snapshots, nothing asserts them). A cheap
  `skills_test` that greps the documented flags against `--help` output
  would catch drift once the compiler grows a help text.
- Candidate new skills as workflows stabilize: ARM64 testing under
  `qemu-aarch64` (see `docs/projects/arm64.md`), seed updates
  (`./wbuild update` discipline), and C interop debugging (`c_import`).
