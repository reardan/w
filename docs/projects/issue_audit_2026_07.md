# Issue + docs audit and wave-based fix plan (July 2026)

Status: plan. Nothing in this document is implemented by the PR that adds it.

## 1. Scope and method

Audited all 34 open GitHub issues (titles + full descriptions) against the
local documentation (`docs/todo.txt`, `docs/annoyances.txt`,
`docs/projects/*.md`, `README.md`, `AGENTS.md`) and spot-checked the tree
where the two disagreed. CI is a single job (`./wbuild tests` on
ubuntu-24.04 with `libc6:i386` and `ptrace_scope=0`), so "green" below
always means the full pre-merge suite.

Three headline findings:

1. **Several open issues are already implemented.** The tree has moved
   faster than the tracker: #179 (`m.add(key, delta)`, `m[k] op= v`) and
   #186 (`lib/fmath.w`) are landed and listed as working in
   `docs/todo.txt`; #33's line-editing/history item landed as
   `lib/line_edit.w`; #123 phase 1 (`wdbg --attach`, read-only) landed as
   `debugger/attach.w`.
2. **Several docs are stale in the other direction.**
   `docs/projects/ai_tooling_next_steps.md` still lists the
   array-decay-corrupts-memory bug that #225 fixed (residue is tracked in
   #229); `README.md` still lists REPL line editing/history as open;
   `docs/annoyances.txt` still lists for-loop container iteration;
   `docs/projects/typed_containers.md` still defers
   `insert`/`remove`/`clear`, which landed; `docs/projects/arm64.md` has
   not been updated for the landed stage 4/5 work in
   `arm64_stage45_plan.md`.
3. **The genuinely open work clusters well.** A small set of confirmed
   correctness bugs (#223, #228, #229, #189, plus doc-tracked wdbg/repl
   bugs), a mid-size tooling/ergonomics backlog
   (`ai_tooling_next_steps.md`, #146, #169, #171, #209), and a long tail
   of epics that need design docs before any implementation (#231, #235,
   #114, #104, #103, backends).

## 2. Prioritized list

### P0 — correctness bugs, confirmed current

| # | Item | Where | Size |
|---|------|-------|------|
| 1 | #223: `net/dns.w` hardcodes Linux errno values; TCP fallback broken on darwin | `libs/standard/net/dns.w` | S |
| 2 | #229: array-decay edge cases (C-variadic tails, `cast(int, arr)` vs `cast(char*, arr)`, conditional arms) | `grammar/postfix_expr.w`, `grammar/conditional_expr.w` | M |
| 3 | #228: compiler-emitted bounds traps are a bare `int3`/`brk` — no index/length diagnostic | `code_generator/x86.w:564-606`, `code_generator/arm64.w`, runtime helper | M |
| 4 | #189: `map[K, float]` has zero test coverage on any target | `tests/`, decision on float `.add` deferred | S |
| 5 | wdbg cannot compile programs using built-in containers (`list`/`map`/`set`) — blocks debugging most modern W code | `debugger/` (doc-tracked, `ai_tooling_next_steps.md`) | M–L |
| 6 | wdbg rejects valid imported bare `return` statements | `debugger/` (doc-tracked) | S |
| 7 | `syscall()` silently lowers exactly nr+3 args regardless of arity — silently broke a ptrace test | compiler/grammar diagnostic (doc-tracked) | S |
| 8 | Compiler can exit 1 with no diagnostic on some internal error paths | driver/error paths (doc-tracked) | S–M |
| 9 | `repl.w` has two type warnings at `repl.w:518`; not in the warning-free gate | `repl.w`, gate target | S |
| 10 | `for` loop `return` out of a generator leaks the suspended generator stack | codegen/runtime (`iteration.md`) | M |

### P1 — hygiene: make the tracker and docs true again

| # | Item | Action |
|---|------|--------|
| 11 | #179, #186 already implemented | verify against tests, close with a landing note |
| 12 | #33 epic checklist stale | tick line editing/history; point remaining items at #114 etc. |
| 13 | `ai_tooling_next_steps.md` stale entries | drop landed decay bug (point at #229 residue), landed conditional-breakpoints teaser |
| 14 | `README.md` "Current major open areas" stale | remove REPL line editing/history |
| 15 | `docs/annoyances.txt` stale | mark container iteration DONE |
| 16 | `docs/projects/typed_containers.md` stale | move landed pseudo-methods out of "deferred" |
| 17 | `docs/projects/arm64.md` out of sync with `arm64_stage45_plan.md` | fold in the "Execution update" outcomes |

### P2 — tooling and ergonomics, implementable without new design

| # | Item | Source | Size |
|---|------|--------|------|
| 18 | #146 stage 1: `string` → `char*` seam (`cstr(s)` or equivalent) | issue, `template_strings.md` | M |
| 19 | Diagnostics bundle: "did you mean `\|\|`/`&&`?" on bool `\|`/`&`; hex-literal bit-31 sign-extension warning; `--quiet` for `check --json` | `ai_tooling_next_steps.md` | M |
| 20 | #169: wdbg `disas` command + instruction context at stops | issue, `assembler_disassembler.md` | M–L |
| 21 | #171: asm property/fuzz round-trip harness + doc flip | issue | M |
| 22 | #209: `libs/x/unsafe` legacy crypto (md5/sha1/rc4 with RFC vectors) | issue | M |
| 23 | Struct method chaining (`p.child().move(1,2)`) | `struct_methods.md`, `grammar/postfix_expr.w` | S–M |
| 24 | `wtest changed --run` | `ai_tooling_next_steps.md` | S |
| 25 | #152: default dict — evaluate whether `.get(k, default)` + `.add` already cover it; else small design note first | issue | S |

### P3 — investigations and environment-gated work

| # | Item | Why gated |
|---|------|-----------|
| 26 | #236: openssl interop hangs on x64 (suspect the fork/exec harness, not TLS) | investigation; outcome may be a fix or a report |
| 27 | #134: committed seed segfaults on cold bootstrap (kernel 6.12) | any real fix implies `./wbuild update` + `update_darwin` — the twin-seed refresh needs a Mac and maintainer sign-off |
| 28 | #210: `arm64_darwin_smoke_test` target | needs the Mac; can only be *prepared* from Linux |
| 29 | `asm_test` segfault; `cuda_smoke` "symbol redefined: 'malloc'" | pre-existing bugs noted in `wexec.md`; cuda needs GPU to fully validate |

### P4 — epics: design doc first, excluded from the implementation waves

#231 (build daemon/AST), #235 (HTTP server framework), #114 (REPL
call-site indirection — explicitly flagged as needing a design doc and
tri-target verify), #123 phases 2–6, #97/#98 (hw watchpoints, web UI
debugger), #103/#104 (`++`/`--`, operator overloading), #207 (assembler
into the seed graph — a seed-size decision), #16/#27/#28/#30/#31
(protobuf, matrix, CUDA stage 2+, wasm, OpenGL), #17's float16 half,
#107 (lambdas — author leans wontfix), #110/#111 (placeholders).
CUDA stage 2 (PTX emitter) is the most "shovel-ready" of these — the
design in `cuda.md` is complete — and is the designated stretch item.

## 3. Merge-conflict hotspots

These files are touched by many PRs at once; the wave structure below
exists mainly to manage them.

- **`build.json`** — generated but committed; *every* PR that adds a test
  regenerates it. Rule: never hand-merge. On conflict, take either side,
  run `./wbuild manifest`, commit the regenerated file.
  `./wbuild manifest_check` in CI catches mistakes.
- **`docs/todo.txt` / `docs/projects/ai_tooling_next_steps.md`** — most
  PRs append status lines. Union-merge by hand; this is why the hygiene
  pass (Wave 0) goes first, so later PRs edit an already-accurate file.
- **`grammar/postfix_expr.w`** — #229 (decay arms), struct method
  chaining (#23 follow-up), and #228's tests all touch it. Serialize:
  #229 in Wave 1, chaining no earlier than Wave 3.
- **Warning fixtures (`warning_test`)** — diagnostic text is frozen by
  fixtures; every new warning edits the same fixture set. All new
  diagnostics ship as **one** bundled PR (item 19) rather than three.
- **Seed-graph files** (`grammar/`, `code_generator/`, `compiler/`,
  `structures/hash_table.w`, `w_list.w`, `lib/` files they import) — no
  post-seed syntax; every touching PR must pass `./wbuild verify`
  (and `verify_x64`/`verify_arm64` for codegen work).

## 4. Wave plan

Execution model: each wave = N parallel subagents, each on its own
`claude/…` branch cut from current `main`, each producing one PR that
passes `./wbuild tests` (plus the verify targets relevant to its diff,
via `git diff --name-only HEAD | ./bin/wtest changed`). After a wave's
PRs are all up: merge **sequentially** — wait for green, merge, rebase
the next PR onto the new `main`, resolve conflicts per §3 (regenerate
`build.json`, union-merge docs), wait for green again, merge. Only then
launch the next wave.

Model assignment rule: **Sonnet 5** for test-only PRs, docs, isolated
library fixes, and well-specified ports with test vectors. **Fable 5**
for anything touching `grammar/`, `code_generator/`, `compiler/`,
`debugger/` internals, or open-ended investigation.

### Wave 0 — hygiene (1 PR, sequential, do first)

| PR | Contents | Model |
|----|----------|-------|
| W0a | Items 11–17: refresh `todo.txt`, `annoyances.txt`, `ai_tooling_next_steps.md`, `README.md`, `typed_containers.md`, `arm64.md`; verify #179/#186 behavior with a quick test run; close/annotate stale issues | Sonnet 5 |

Rationale: every later PR touches these docs; landing the corrections
first prevents N-way conflicts on stale text.

### Wave 1 — small independent bugs (5 PRs in parallel)

| PR | Item | Files (primary) | Model |
|----|------|-----------------|-------|
| W1a | #223 dns errno accessors | `libs/standard/net/dns.w` | Sonnet 5 |
| W1b | #189 `map[K, float]` coverage (x86 + x64 twins; arm64 where the harness allows) | `tests/`, `build.json` regen | Sonnet 5 |
| W1c | Item 9: fix `repl.w:518` warnings, add repl to the warning-free gate | `repl.w`, `build.base.json` | Sonnet 5 |
| W1d | #229 decay edge cases + regression tests | `grammar/postfix_expr.w`, `grammar/conditional_expr.w` | Fable 5 |
| W1e | Item 7: `syscall()` arity diagnostic + fixture | compiler/grammar, `warning_test` fixtures | Fable 5 |

Conflicts: W1b/W1d/W1e all regenerate `build.json` (mechanical); W1e adds
a warning fixture — keep it the only fixture-touching PR in the wave.
Note W1a is compile-verified only on Linux; the darwin behavioral check
rides the next Mac session.

### Wave 2 — medium bugs and diagnostics (4 PRs in parallel)

| PR | Item | Files (primary) | Model |
|----|------|-----------------|-------|
| W2a | #228 bounds-trap diagnostics: `__w_bounds_trap(index, length)` helper + conditional-skip emission on both ISAs; update `bounds_trap_test`/`range_bounds_trap_test` to `expect_stderr`; `--bounds=off` still elides | `code_generator/x86.w`, `code_generator/arm64.w`, runtime, `build.base.json` | Fable 5 |
| W2b | Item 5 + 6: wdbg container-program compile bug and bare-`return` rejection | `debugger/` | Fable 5 |
| W2c | #146 stage 1: `cstr()` seam + one exemplar migration (`repl.w` or `tools/wexec.w`) | lib/grammar TBD by design in the PR | Fable 5 |
| W2d | Item 19 diagnostics bundle (bool bitwise hint, hex bit-31 warning, `--quiet`) — single PR because all three edit warning fixtures | compiler, `warning_test` fixtures | Fable 5 |

W2a needs `verify`, `verify_x64`, `verify_arm64`. If `cstr` in W2c ends
up needing new syntax, it also needs `tests/parser_generator/w.pg` and
must stay out of seed-graph files until a future seed update.

### Wave 3 — features and investigations (5 PRs in parallel)

| PR | Item | Notes | Model |
|----|------|-------|-------|
| W3a | #169 wdbg `disas` | grows the seed graph with `libs/asm` decode; isolate so a verify regression is attributable | Fable 5 |
| W3b | #171 asm fuzz harness | deterministic seed; flips `assembler_disassembler.md` to implemented-summary | Sonnet 5 |
| W3c | #209 `libs/x/unsafe` md5/sha1/rc4 | RFC 1321/3174/6229 vectors; hard rule: nothing under `libs/standard/` imports it | Sonnet 5 |
| W3d | Item 23 struct method chaining | `grammar/postfix_expr.w` — must land after W1d is merged | Fable 5 |
| W3e | #236 x64 openssl-interop hang investigation | timebox; deliverable is a fix or a written diagnosis on the issue | Fable 5 |

### Wave 4 — stretch (sequential, one at a time)

| PR | Item | Notes | Model |
|----|------|-------|-------|
| W4a | Item 10 generator-leak on `return` | codegen + runtime, all targets | Fable 5 |
| W4b | Item 24 `wtest changed --run`; item 25 #152 evaluation | tooling QoL | Sonnet 5 |
| W4c | #210 prep: define `arm64_darwin_smoke_test` target + docs | merge only after a Mac session validates it | Sonnet 5 |
| W4d | CUDA stage 2 PTX emitter (`code_generator/ptx.w`) | large; only if waves 0–3 land cleanly | Fable 5 |

### Explicitly not in any wave

Everything in P4 (needs design first), #134 (seed update requires the
Mac + maintainer), and #146 stage 2 (mass f-string/defer migration —
conflict-maximizing by nature; run it opportunistically as single-file
PRs during quiet periods, never inside a wave).

## 5. Dependency graph (summary)

- Wave 0 → everything (doc-file conflicts).
- W1d (#229) → W3d (method chaining): same grammar file.
- W1e and W2d: both edit warning fixtures — different waves by design.
- W2a (#228) is independent of W1d but both add tests → `build.json`
  regen on rebase.
- W3a (#169) depends only on already-merged asm work (#165/#167/#168).
- W4d (CUDA) has no code dependency but consumes the whole review budget.
- #207 stays blocked on a maintainer decision (seed size); #114 stays
  blocked on its own design doc.

## 6. Per-PR checklist (applies to every subagent)

1. Branch from fresh `main`; tab indentation; trailing newline.
2. New tests: plain `tests/foo_test.w` (+ `# wbuild: x64` where it should
   twin), then `./wbuild manifest` — never hand-edit `build.json`.
3. Diagnostic-text changes update fixtures in the same commit.
4. Run `git diff --name-only HEAD | ./bin/wtest changed` and the printed
   targets; compiler-tree diffs additionally run `./wbuild verify`
   (+ `verify_x64`/`verify_arm64` for codegen).
5. Fix warnings, not just errors (`--strict` self-host gate).
6. Any agent-tooling friction found en route → add to
   `ai_tooling_next_steps.md` in the same PR.
7. Open the PR as draft; it merges only via the sequential protocol in §4.
