# W repo: prioritized issue backlog + parallel-subagent wave execution plan

## Context

The repo has three issue sources: `docs/todo.txt` (working/missing inventory + "next
priorities"), `docs/projects/ai_tooling_next_steps.md` (a live friction queue — many
entries shipped 2026-07-19/25, but ~15 remain open), and 23 open GitHub issues. The
goal is to burn down as many well-scoped items as possible using waves of parallel
subagents, sequenced so file conflicts and dependencies don't collide. Recent
history matters: golf-wave-2 items 1–3 (inferred `for`, safer `:=`, prelude math)
and wasm stage 5 landed in the last merges, so those sub-items are already done.

## Environment constraints (this remote Linux x86_64 container)

- `node` YES → wasm gates run (`tools/run_wasm.sh`). `wasmtime` no.
- No `/lib/ld-linux.so.2` (i386 loader) → `dynamic_test`, `c_import_test`,
  `c_import_errno_test`, `c_import_libc_test`, `float_abi_test`, `varargs_test`,
  `extern_data_test` (all in the 296-target `tests` umbrella) will fail unless
  `libc6:i386` installs. Wave 0 attempts `dpkg --add-architecture i386 && apt-get
  install libc6:i386`; if it fails, these are recorded as env-blocked and excluded
  from local gates (CI covers them).
- No `qemu-aarch64` → `verify_arm64` blocked unless `qemu-user-static` installs
  (wave 0 attempts it; unblocks the "arm64 self-host regression UNCONFIRMED" item).
- No GPU (`cuda_test` impossible — GPU-less targets `gpu_ptx_emit_test` etc. still run).
  No Mac (all `*_darwin` validation excluded).
- `bin/` not built yet — wave 0 bootstraps.

## Prioritized issue inventory

### P0 — small, well-scoped fixes (high confidence, mostly tooling/leaf files)

| # | Item | Source | Files |
|---|------|--------|-------|
| P0.1 | `manifest`/`manifest_check` race under `test_changed` (temp-file+rename write, dep edge or drop `manifest` from selection, distinct "committed manifest failed to parse" drift message) | ai_tooling 2026-07-25 | `tools/wbuildgen.w`, `tools/test_map.w`, `build.base.json` |
| P0.2 | `format_test`/`format_64_test` race on fixed `/tmp/w_format_test.txt` (pid-scope) + the line-20 `args[1] = c"abc"` warning | ai_tooling 2026-07-25 | the format test source |
| P0.3 | `wtest --defhash` committed-clean-worktree footgun warning + cold-cache progress output + fix stale "~35s" figure in docs | ai_tooling (2 entries) | `tools/wtest.w`, CLAUDE.md/AGENTS.md/README |
| P0.4 | c_preprocessor `#error` never echoes the directive's message text | ai_tooling residue note | `libs/extras/c_preprocessor/pp_directives.w` + fixture |
| P0.5 | wexec exit-127 diagnostic should name the resolved-but-unusable candidate | ai_tooling (nice-to-have residue) | `tools/wexec.w` + `tests/wexec/` |
| P0.6 | line_edit residual gaps: multi-line paste renders bare newlines; arrow-key during Ctrl-R inserts literal `[A`; search while line wraps leaves stale rows | ai_tooling 2026-07-25 | `lib/line_edit.w`, `tests/line_edit_*` |
| P0.7 | `tools/pty_test.py` reusable pty harness (script canonical-mode keystrokes: Ctrl-R etc.) + wire one scripted Ctrl-R case | ai_tooling | new `tools/pty_test.py`, `build.base.json` |
| P0.8 | Stale-doc sweep: `wc`-strlen note contradicts its own "fixed" entry; move shipped entries to `ai_tooling.md` status | ai_tooling hygiene | docs only |

### P1 — compiler diagnostics & medium isolated features

| # | Item | Source | Files |
|---|------|--------|-------|
| P1.1 | Warn on casting an array-typed expression (`T[N]`) to a pointer type (addresses the hidden runtime header, not data) + add `type_array_element_offset()` accessor + document layout | ai_tooling 2026-07-25 (cost a multi-step bisect) | `grammar/` cast site, `compiler/type_table.w`, fixtures |
| P1.2 | Plumb `GETCHAR_READ_ERROR` sentinel through the compiler's `get_character()` path (read-error ≠ EOF) | ai_tooling (partially shipped) | `compiler/tokenizer.w`, `lib/lib.w` |
| P1.3 | wbuildgen: `wasm` arch value + multi-program aggregate target directive + extra-compiler-flags directive; migrate `wasm_smoke_test`, `arm64_smoke_test`, `float_abi_test_x64`, `net_darwin` out of `build.base.json` | ai_tooling "Build manifest" + todo wasm-residue | `tools/wbuildgen.w`, `build.base.json` |
| P1.4 | ParserGenerator: accept a nullable non-empty factored suffix as the trailing fallback branch (currently over-rejected) | ai_tooling PG section | `libs/extras/parser_generator/analysis.w` + streaming emitter + `.pg` tests |
| P1.5 | REPL shell mode stage 2: more coreutils-alike commands + pipes (design staged in `docs/projects/repl_shell_mode.md`) | issue #335 | `repl/shell_translate.w`, `lib/shell_commands.w`, tests |
| P1.6 | fmath64: finish float64 transcendentals (in progress per todo) | issue #17 (partial) | `lib/fmath64.w` + tests |
| P1.7 | `socketcall` cleanup (net) + thread.w worker stack/handle reclamation on join | todo | `lib/net.w`, `lib/thread.w` |
| P1.8 | wdbg `--attach` remainder: restricted expression eval (`p`/`set` beyond name lookup); hardware watchpoints (DR0–DR7) | issue #123, todo | `debugger/*` |
| P1.9 | arm64 self-host regression re-check (`verify_arm64` under qemu, then delete the UNCONFIRMED entry) — only if qemu installs in wave 0 | ai_tooling | none (verification) or docs |

### P2 — language features (syntax-heavy: conflict-managed)

| # | Item | Source | Files |
|---|------|--------|-------|
| P2.1 | list negative index + slices `a[-1]`, `a[i:j]` (parity with buffers) | #360 item 5 | `grammar/` (postfix/index), `structures/w_list.w`, `w.pg`, tests |
| P2.2 | Multi-assign `a, b = b, a + b` | #360 item 6 | `grammar/expression.w`/statement, `w.pg`, tests |
| P2.3 | Heap + deque containers (no new syntax) | #360 item 8 | `structures/`, tests |
| P2.4 | Better strings: `input()` → `string`, `print` treats `char` as char, `isalnum`/`tolower` family | #360 item 4 | `lib/str.w`, prelude, print builtin |
| P2.5 | `elif` sugar + prelude `any`/`all`/`enumerate` + `sorted(a)` | #360 item 9 | `grammar/statement.w`, prelude, `w.pg`, tests |
| P2.6 | Top-level `int x = 5` initializer sugar so REPL `:save` transcripts round-trip (or, fallback: document the asymmetry in `:help`) | ai_tooling REPL section | `grammar/program.w`, `w.pg`, tests |
| P2.7 | Stdlib algorithms: `levenshtein`, sliding-window helpers | #360 item 10 | `lib/`, tests |
| P2.8 | map default-value factory / auto-vivification (design doc exists: `docs/projects/map_default_factory.md`) | #327 | compiler + `structures/hash_table.w` runtime |

### P3 — larger tracks (stretch; one dedicated agent each, serialized vs. other codegen work)

| # | Item | Source | Notes |
|---|------|--------|-------|
| P3.1 | DEFLATE encoder past fast-mode (fixed+dynamic Huffman), then vcs object packing | #252 remainder, todo | `libs/extras/compress/deflate.w` → `libs/extras/vcs/`; packing depends on encoder |
| P3.2 | #251 direction 1: deps-driven wexec cache keys via `wv2 deps`; arch-aware deps | #251 | `tools/wexec.w`, driver |
| P3.3 | W^X text/data split for x86/x64 (win64 HVCI is a real crash; design: `docs/projects/wx_split.md`) | todo next-priorities | `code_generator/elf_*` — high risk, solo agent, full verify matrix |
| P3.4 | ndarray grammar-level indexing sugar `m[i, j]` | #27 remainder | grammar + `w.pg` |
| P3.5 | Compiler `--help` text + `skills_test` asserting documented flags | ai_tooling skills section | driver, `build.base.json` |

### Explicitly skipped (too large / blocked / policy decisions)

#361 split repo, #337 LLVM offload, #334 UI framework, #338 libraries-for-everything,
#110 optimization (vague), #332/#333 (future design), #98 web debugger UI (low
priority), #28 CUDA backend (no GPU here), #323 + #231 (build-daemon/no-generated-
files redesign — architecture decisions, overlap each other), #287 stage 2 (UTF-8
identifiers = explicit policy decision), #360 lambdas (#107 closed not-planned),
multi-error reporting (documented research limitation), darwin-only items (no Mac).

## Execution model

- **Isolation**: each subagent runs via the Agent tool with `isolation: "worktree"`
  on a task branch off the integration branch. First step in each worktree: copy the
  seed + built `bin/` from the main checkout (or `./wbuild build` fresh, ~minutes).
- **Branch/PR strategy (user-approved)**: one PR per wave. Each wave integrates its
  agents' work into a wave branch (`claude/wave1-fixes`, `claude/wave2-diagnostics`,
  `claude/wave3-features`, `claude/wave4-features2`, `claude/wave5-stretch`),
  verified, pushed, and opened as a draft PR; wave N+1 branches from wave N's head
  so later waves never wait on merges to main. The designated branch
  `claude/issue-prioritization-subagent-plan-4zsc5o` carries this plan document and
  tracks overall progress. User granted permission for the wave branches.
- **Wave discipline**: tasks inside a wave are file-disjoint by construction (the
  tables below note the conflict zone each task owns). At most 2 syntax-adding
  tasks per wave, in different grammar files; `tests/parser_generator/w.pg` overlap
  is resolved at integration (append-only rule additions merge trivially).
- **Generated-file rule**: agents NEVER hand-edit `build.json`; after each merge the
  integrator runs `./wbuild manifest` to regenerate, resolving any conflict by
  regeneration. `docs/projects/ai_tooling_next_steps.md` entry deletions are
  per-task (each agent touches only its own entry); integrator union-merges.
- **Per-merge gates** (integrator, after each task merge):
  1. `./wbuild manifest && ./wbuild manifest_check`
  2. `git diff --name-only <pre-merge> | ./bin/wtest changed` → `./wbuild test_changed`
     (10-minute budget for the first cold-cache run)
  3. `./wbuild verify` whenever `compiler/`, `grammar/`, `code_generator/`,
     `structures/` (auto-imported runtime), or seed-graph `lib/` files changed;
     `verify_x64` additionally for codegen/word-size changes
  4. Full `./wbuild tests` at wave close (minus env-blocked targets if the i386
     install failed)
- **Seed constraint check**: any task touching `compiler/`/`grammar/`/
  `code_generator/`/`structures/`/seed-graph `lib/` must stay seed-syntax-safe
  (new syntax only in `tests/` + leaf consumers). Agents are told this explicitly.

## Waves

### Wave 0 — serial setup (no parallelism)

1. Bootstrap: `./wbuild build` → `./wbuild verify` → `./wbuild verify_x64` baseline.
2. Env probe: attempt `libc6:i386` and `qemu-user-static` apt installs; record which
   of the umbrella targets are env-blocked. If qemu lands, run `./wbuild
   verify_arm64` (P1.9) and delete the UNCONFIRMED doc entry.
3. Baseline `./wbuild tests`; record pre-existing failures so wave gates only fail
   on regressions.

### Wave 1 — 6 parallel agents, small fixes, zero grammar overlap

| Agent | Task | Owned conflict zone |
|-------|------|---------------------|
| W1a | P0.1 manifest race | `tools/wbuildgen.w`, `tools/test_map.w`, `build.base.json` |
| W1b | P0.2 format_test race + warning | format test source only |
| W1c | P0.3 wtest defhash warning + progress + doc figures | `tools/wtest.w`, top-level docs |
| W1d | P0.4 `#error` message text | `libs/extras/c_preprocessor/` |
| W1e | P0.5 wexec 127 diagnostic | `tools/wexec.w`, `tests/wexec/` |
| W1f | P0.6 line_edit gaps + P0.7 pty harness (same test surface) | `lib/line_edit.w`, `tools/pty_test.py` |

P0.8 (doc sweep) is done by the integrator at wave close, when all entry deletions
have merged. Only W1a touches `build.base.json`; no compiler files touched anywhere
→ no verify runs needed except W1d/W1f's normal test gates.

### Wave 2 — 6 parallel agents, compiler diagnostics + isolated medium features

| Agent | Task | Owned conflict zone | Verify? |
|-------|------|---------------------|---------|
| W2a | P1.1 T[N]-cast warning + accessor | `grammar/` cast path, `compiler/type_table.w` | yes |
| W2b | P1.2 getchar read-error sentinel | `compiler/tokenizer.w`, `lib/lib.w` | yes |
| W2c | P1.3 wbuildgen wasm/aggregate/flags directives (needs W1a merged) | `tools/wbuildgen.w`, `build.base.json` | no |
| W2d | P1.4 PG nullable-suffix fallback | `libs/extras/parser_generator/` | no |
| W2e | P1.5 shell mode stage 2 | `repl/shell_translate.w`, `lib/shell_commands.w` | no |
| W2f | P1.6 fmath64 transcendentals + P1.7 net/thread cleanup | `lib/fmath64.w`, `lib/net.w`, `lib/thread.w` | no |

W2a and W2b are the only compiler-touchers and live in disjoint files; integrator
merges them one at a time with `verify` + `verify_x64` between.

### Wave 3 — 5 parallel agents, feature work (syntax partitioned)

| Agent | Task | Owned conflict zone | Verify? |
|-------|------|---------------------|---------|
| W3a | P2.1 list negative index + slices | `grammar/` postfix/index, `structures/w_list.w`, `w.pg` | yes |
| W3b | P2.2 multi-assign | `grammar/expression.w`/statement entry, `w.pg` | yes |
| W3c | P2.3 heap + deque | `structures/` (new files), tests | yes (auto-import runtime) |
| W3d | P2.4 better strings | `lib/str.w`, prelude | yes (prelude) |
| W3e | P1.8 wdbg attach remainder | `debugger/` | yes (debugger in seed graph) |

Two `w.pg` touchers (W3a/W3b) — additive rule merges, integrator resolves and
re-runs `parser_generator_w_test`. All five are verify-gated at merge.

### Wave 4 — 5 parallel agents, second feature batch + stretch starts

| Agent | Task | Owned conflict zone | Verify? |
|-------|------|---------------------|---------|
| W4a | P2.5 elif + any/all/enumerate + sorted | `grammar/statement.w`, prelude, `w.pg` | yes |
| W4b | P2.6 top-level initializer sugar (`:save` round-trip) | `grammar/program.w`, `w.pg` | yes |
| W4c | P2.8 map default factory (#327) | map codegen + `structures/hash_table.w` | yes |
| W4d | P2.7 stdlib algorithms | `lib/` new files | no |
| W4e | P3.1 first half: DEFLATE real encoder | `libs/extras/compress/deflate.w` | no |

### Wave 5 — stretch (user-approved scope: run waves 1–4 fully, then wave 5 only if
everything integrated cleanly and budget remains)

| Agent | Task | Notes |
|-------|------|-------|
| W5a | P3.1 second half: vcs object packing | depends on W4e |
| W5b | P3.2 #251 direction-1 deps-driven cache keys | `tools/wexec.w` (after W1e) |
| W5c | P3.5 `--help` + skills_test | driver + `build.base.json` |
| W5d | P3.4 ndarray index sugar | grammar + `w.pg`, verify |
| W5e | P3.3 W^X split x86/x64 | SOLO risk item: only start once nothing else is in flight; full verify matrix |

### Close-out

- Final full `./wbuild tests` + verify matrix on the last wave branch; each wave
  already has its own draft PR with a task-by-task summary.
- Issue hygiene: comment on #360/#327/#123/#335/#252/#17/#27 listing what landed;
  every task deletes its shipped `ai_tooling_next_steps.md` entry in-PR per the
  repo's dogfooding rule.

## Dependency edges (why the waves are ordered this way)

- W1a → W2c (both rewrite `tools/wbuildgen.w`).
- W1e → W5b (both rewrite `tools/wexec.w`).
- W4e → W5a (packing consumes the encoder).
- Syntax tasks spread ≤2 per wave to keep `w.pg`/grammar merges trivial.
- W5e (W^X) last and alone: it perturbs ELF layout under every other test.
- Every wave's integration is serial: merge → manifest regen → targeted tests →
  verify (when gated) → next merge; wave N+1 branches from the integrated result.

## Verification (end-to-end)

After final integration on `claude/issue-prioritization-subagent-plan-4zsc5o`:
`./wbuild build && ./wbuild verify && ./wbuild verify_x64 && ./wbuild tests`
(plus `verify_arm64` if qemu installed, wasm gates via node), then push and open
the draft PR. Any env-blocked targets are listed in the PR body as CI-covered.
