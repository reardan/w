# Sonnet wave plan (mid-July 2026): open issues → parallel-subagent tasks

Status: plan (2026-07-16). Successor to
`docs/projects/consolidated_plan_2026_07.md`, most of whose Threads A
(manifest de-churn), B (REPL robustness/architecture) and C waves 1–2
(VCS foundations + working `wvc`) are now merged. Inputs: all 22 open
GitHub issues (bodies + comments), `docs/projects/ai_tooling_next_steps.md`,
`docs/projects/ai_tooling.md`, and verification of what actually exists
at head — several doc/issue entries lag the last three merged PRs
(#326, #328, #330).

Execution model: waves of parallel **Sonnet** subagent PRs, one task per
agent in an isolated worktree, sequential merge after green. Tasks are
deliberately specified more tightly than the previous (Fable-assisted)
program: each has files, gates, and a care level. HIGH-care tasks touch
the seed import graph or `grammar/`/`code_generator/` and must merge
**last and alone** in their wave with `./wbuild verify` (+`verify_x64`)
green.

## Execution status (2026-07-16/17)

Waves 1–4 executed and merged onto this branch. Every task below was
verified against the tree at merge time (files present, `build.json`
targets wired, design docs written) before being logged here. Wave 5 is
running in parallel with this sync and is **not** included as done —
see the note at the end of this section.

**Wave 1** (`docs/projects/*`, `lib/shell.w`, `repl.w`, 3 design docs):
1a doc sync (backlog/plan docs refreshed to shipped state); 1b
`lib/shell.w` (`sh`/`run`/`cd`/env helpers, `lib/shell_test.w` +
`shell_test`/`shell_64_test` targets); 1c REPL colon-commands
(`:symbols`/`:type`/`:time`/`:load`/`:reset`/`:save` in `repl.w`); 1d
`docs/projects/increment_decrement.md` (#103 design doc); 1e
`docs/projects/map_default_factory.md` (#327 design doc); 1f
`docs/projects/utf8_source.md` (#287 audit + design doc).

**Wave 2** (libraries + one seed-graph slot): 2a `libs/extras/vcs/index.w`
dirstate wired into `tools/wvc.w`'s fast path; 2b `libs/extras/vcs/delta.w`
binary deltas; 2c `docs/projects/compress.md` design doc; 2d HTTP server
framework phases 1–2 (`libs/standard/web/connection.w` + `http_server.w`,
`ConnectionContext`/base `ServerContext` accept loop); 2e `lib/ndarray.w` +
`lib/ndarray64.w` v1 (dense row-major arrays, #27 substrate); 2f PG
dispatch-table lexer, #329 milestone 1 (`libs/extras/parser_generator/`,
seed-safe, merged alone with `verify` green).

**Wave 3** (integration layers): 3a `libs/extras/compress/` stage 1
(`crc32.w`/`adler32.w`/`inflate.w`/`deflate.w`/`gzip.w`/`zlib.w` — a fully
conformant RFC 1951 inflater; DEFLATE encoder is fast-mode-only, matching
the stage-1 scope in the 2c doc); 3b `libs/extras/vcs/merge3.w`
three-way merge + `wvc merge` porcelain; 3c HTTP server phases 3–5
(`RequestContext`, routing/handler registration, HTTPS via `tls_accept`,
keep-alive; `examples/web/https_server.w` migrated onto the framework,
`http_server_route_test.w` covers an SSE streaming example via
`libs/standard/web/sse.w`); 3d REPL agent mode + `!` shell escape (`-e`,
`--json` NDJSON, banner/prompts to stderr off-tty, `!cmd`/`!cd`/`!export`
desugaring to `lib.shell`); 3e wexec remote build cache
(`W_CACHE_URL`, read-through HTTP cache over `vcs/cas.w`, local-fallback
on any transport failure); 3f PG LL(1) committed dispatch, #329
milestone 2 (FIRST/FOLLOW analysis + left-factored switch dispatch in
`libs/extras/parser_generator/`; measured `parser_generator_w_test`
whole-repo sweep speedup 78s → 19s, ~4x, per
`docs/projects/parser_generator.md`).

**Wave 4** (bigger bets): 4a wbuild/wtest direct-file UX (#323 stage 1):
`./wbuild path/to/file.w` and `bin/wtest for path/... [--run]` resolve
through the manifest/deps machinery without a `build.json` entry
(`tools/wexec.w`'s `wexec_resolve_direct_file`, `tools/test_map.w`'s
`for` subcommand), plus a committed stage-1 inventory of every remaining
shell script and hand-written target in `docs/projects/build_system_next.md`;
4b bool-bitwise style migration stage 1 (generated parsers in
`libs/extras/parser_generator/` now emit `&&`/`||` for every boolean
join, removing ~140 sites in `generated_c_parser.w`; opt-in `w check
--bool-ops` widens the hint to comparison-result operands; measured
stage-2 worklist ~490 hand-written sites, breakdown in
`ai_tooling_next_steps.md`); 4c `wvc` push/pull over HTTP (have/want
negotiation for loose objects, `tools/wvc.w`'s `serve`/`pull`/`push`
subcommands, built on the 2d/3c HTTP framework); 4d
`docs/projects/wbuildd.md` design doc (#231: `wbuildd` persistent
daemon + AST-options assessment, no code); 4e #17 float conformance
expansion (`tests/float_conformance_test.w`,
`tests/x64_float64_conformance_test.w` — TestFloat-derived NaN/subnormal/
rounding-boundary vectors — plus `docs/projects/float.md`'s "Known MVP
semantic differences" section and F16C requirement writeup).

**Wave 5 — complete** (merged after the 5d sync above was written): 5a
#103 `++`/`--` statements (statement-position-only sugar over the
compound-assign path, `grammar/increment.w`, w.pg additions,
`increment_test`/`increment_error_test`; raw-byte pointer stepping
pinned to match `+=`); 5b #189 float-valued `m.add` (float32
everywhere, float64 on x64 — type-dispatched lowering in
`grammar/hash_builtin.w` over `__w_map_get_or` + the float emitters +
`__w_map_set`, no runtime growth; float16 rejected with a pinned
message); 5c #287 UTF-8 stage 1 (JSON-escaper hardening in
`compiler/diagnostics.w` — invalid bytes become `\u00XX`, output is
always valid JSON; silent BOM strip in `compile_attempt`;
codepoint-based `column_number` for the JSON path;
`utf8_source_test`/`check_json_utf8_test`/`utf8_bom_test`); 5d this
execution-status sync. Each seed-graph task merged sequentially under
its own `./wbuild verify`/`verify_x64` + full-suite gate.

### Remaining queue

- **PG streaming milestone 3** (#329): listener-callback streaming mode,
  `mode streaming` directive, `w.pg` port with left-factoring.
- **#327 implementation**: per the 1e design doc, pending a maintainer
  surface pick (declaration-site factory vs. `m.setdefault(k)` vs.
  compiler-lowered auto-vivification).
- **Bool-bitwise stage 2**: the mechanical ~490-site sweep (breakdown by
  file in `ai_tooling_next_steps.md`), reviewed in ~50-site chunks;
  flipping the default comes after.
- **defhash** (#251, build system Direction 4a): definition-level
  content hashing (`wv2 defhash`), not yet started.
- **#123 attach phases 2–6**: `debugger/` target-access seam, symbol
  recovery, ptrace stepping — heaviest open project, recommend a
  seam-only refactor PR before any ptrace semantics.
- **`wvc` gzip/git-interop**: compress-based object packing once 3a's
  DEFLATE encoder grows past fast-mode-only, and the git-interop gateway
  compress.md flags as a non-goal "for now."
- **REPL P4**: websocket server (blocked on the #231 decision made in
  4d's doc), arm64/darwin REPL (Mac-gated).
- Plus the standing deferred list in §7 below (unchanged by this
  program): #210/darwin dir hashing, #28 CUDA, #110 Optimization, #98
  web-UI debugger, #31 graphics next stages, #16 protobuf, #207 asm
  into `code_generator/`, multi-error reporting.

### Issue status after this program

- **#252** (VCS): waves 1–4 shipped `cas.w`/`diff.w`/`dag.w`/`tree.w`/
  `commit.w`/`index.w`/`delta.w`/`merge3.w` plus HTTP sync (have/want
  push/pull) and `wvc` porcelain (`status`/`snapshot`/`merge`/`serve`/
  `pull`/`push`). Remaining: compress-based object packing (blocked on
  3a's DEFLATE encoder growing past fast-mode), git interop (explicitly
  a non-goal "for now" per `docs/projects/version_control.md`).
- **#235** (HTTP server framework): complete — phases 1–5 landed
  (`ConnectionContext`/`ServerContext`/`RequestContext`, routing, HTTPS,
  keep-alive) with `examples/web/https_server.w` migrated onto it and an
  SSE streaming example.
- **#329** (parser generator streaming): milestone 1 (dispatch-table
  lexer) and milestone 2 (LL(1) committed dispatch, ~4x sweep speedup)
  shipped; milestone 3 (streaming mode) queued, not started.
- **#276** (REPL): P0–P3 complete, including agent mode (`-e`/`--json`/
  `!` escape); P4 remaining (websocket server pending the #231 decision,
  arm64/darwin REPL — Mac-gated).
- **#251** (build system): Direction 1 (compiler as source of truth)
  and D3-1 (SHA-256 cache keys) were complete pre-program; D3-2 (shared
  HTTP build cache, wave 3e) is now complete, and direct-file UX (wave
  4a) shipped on top of Direction 1. Remaining: Direction 2 (traced
  dependencies), 4a defhash, 4c working-tree watcher (blocked on
  defhash).
- **#323** (build system de-churn): stage 1 (direct-file UX) plus the
  committed migration inventory shipped (wave 4a). Remaining work is
  staged in `docs/projects/build_system_next.md`.
- **#17** (float): conformance vectors + docs shipped (wave 4e).
  Remaining: `bfloat16`, explicitly deferred pending a GPU-backend
  decision.
- **#103**, **#287**, **#189**: design docs shipped in wave 1 (1d, 1f)
  or scoped for wave 5 (#189); implementations are in flight in wave 5,
  not yet in this tree.
- **#327**, **#231**: design docs shipped (wave 1e, wave 4d); both await
  a maintainer decision before implementation.
- **#27** (ndarray): v1 substrate shipped (wave 2e) — `lib/ndarray.w`/
  `lib/ndarray64.w`, stages 1–2 per `docs/projects/ndarray.md`. Grammar
  sugar remains explicitly out of scope.

## 0. Verified already-landed (do NOT schedule; several docs still list these as open)

- Consolidated plan Thread A: A1 (`wtest_map_check` + `noorder`), A2
  (`# wbuild:` directive vocabulary incl. `timeout=`/`stdin=`/
  `expect_*=`/`deps=`), A3 (deps-driven wexec cache keys via `wv2 deps`,
  SHA-256 digests = D3-1), A4 (platform axis in wbuildgen).
- Thread B: R1 (REPL runtime-fault recovery in `repl/core.w`), R2
  (float/struct echo), R3 (`repl/core.w` + `repl/scan.w` split), R4
  (#114 late binding — `repl_apply_late_bind`), R5 (`debugger/eval.w`
  re-based on `repl.core`).
- Thread C: V1a/b/c (`libs/extras/vcs/{cas,diff,dag}.w`), V2a/b/c
  (`tree.w`, `commit.w`, `tools/wvc.w`).
- ai_tooling friction items fixed by #328/#330 but still listed as open
  in `ai_tooling_next_steps.md`: cold-cache progress note,
  `test_changed` flag forwarding, `wtest --available`,
  `wtest_map_check` order opt-out, `wexec --ordered-output`,
  transitive-import audit (`w check --imports`), plus partial
  silent-exit-1 fixes (output-write checks, EOF-in-literal hang, OOM
  notice).
- Asm epic #163: #170 (stubs from text, offline), #169 (wdbg `disas`),
  #171 (`asm_fuzz_*` targets) are all in-tree — only #207 (assembler
  into the seed graph) remains, and it is its own issue.
- #189 coverage half (`map_float_test`, `x64_map_float64_test`) and
  #17's float16 storage tests + doc correction landed in #326.

## 1. Prioritization rationale

1. **Sync docs/issues to reality first** — stale backlogs cause
   duplicate agent work (observed: this plan's own audit).
2. **Well-specified leaf/library work next** — Sonnet's sweet spot:
   stdlib modules, tests, tools, docs. High value, low blast radius.
3. **Design-doc-only tasks run cheap and early** to unblock later
   waves and maintainer decisions (#103, #327, #287, compress, #231).
4. **Seed-graph / grammar work is rationed** — at most one HIGH-care
   task per wave, merged alone, verify-gated (#329 milestones, #189
   `.add`, bool-bitwise migration).
5. **Deferred**: anything Mac-gated, maintainer-decision-gated, or
   unscoped (see §7).

## 2. Wave 1 — sync + small leaf wins (6 parallel tasks)

| ID | Task | Issue | Files | Care |
|----|------|-------|-------|------|
| 1a | **Doc sync**: move the shipped entries listed in §0 out of `ai_tooling_next_steps.md` into `ai_tooling.md`'s status section; mark Threads A/B/C-waves-1-2 done in `consolidated_plan_2026_07.md` (pointer to this file); refresh `docs/todo.txt` REPL/VCS lines. Docs only, no code. | — | `docs/projects/*`, `docs/todo.txt` | LOW |
| 1b | **`lib/shell.w`**: `sh(cmd)` (`/bin/sh -c`, captured out/err + decoded status), `run(argv)`, `cd`, env get/set on top of `lib/process.w`/`lib/env.w`, per #276 research Q5. New `tests/shell_test.w` (+ `./wbuild manifest`). Standalone; the REPL `!` escape (task 3d) consumes it later. | #276 | `lib/shell.w`, `tests/shell_test.w` | LOW |
| 1c | **REPL `:commands`**: `:symbols` (wraps `print_symbol_table`), `:type expr` (compile, print echo type, discard), `:time expr`, `:load file`, `:reset`, `:save file` (concatenate staged entry files). CLI layer only (`repl.w`) — core stays untouched. Extend the scripted `repl_test` session in `build.base.json`. | #276 | `repl.w`, `build.base.json` | MED |
| 1d | **#103 design doc**: `docs/projects/increment_decrement.md` — pre/post `++`/`--` semantics, v1 scope recommendation (statement-position-only vs full expression), pointer stepping via the existing `+=` precedent (`grammar/expression.w`), w.pg impact. No code. | #103 | docs | LOW |
| 1e | **#327 design doc**: `docs/projects/map_default_factory.md` — the three surfaces from the issue (declaration-site factory, `m.setdefault(k)`, compiler-lowered auto-vivification for map-of-map/list), interaction with the trap-on-missing contract, recommendation. No code. | #327 | docs | LOW |
| 1f | **#287 audit + design doc**: probe current tokenizer behavior on UTF-8 in comments/strings/identifiers (no UTF-8 handling exists in `compiler/tokenizer.w`); write `docs/projects/utf8_source.md` staging identifiers vs strings vs diagnostics-column semantics, referencing Python 2→3 lessons per the issue. Probe fixtures allowed; no compiler changes. | #287 | docs, `tests/` probes | LOW |

Orchestrator (not subagent) follow-through after wave 1 merges: tick the
completed checkboxes on #251/#252, comment progress on #276/#163/#17,
close #163 if the maintainer agrees #207 supersedes it.

## 3. Wave 2 — libraries + one seed-graph slot (6 tasks)

| ID | Task | Issue | Files | Care |
|----|------|-------|-------|------|
| 2a | **`vcs/index.w` dirstate**: sorted path table + (size, mtime) stat cache, O(changed) `wvc status`, racy-mtime guard; wire into `tools/wvc.w` as the fast path. | #252 | `libs/extras/vcs/index.w`, `tools/wvc.w`, tests | MED |
| 2b | **`vcs/delta.w` binary deltas**: rolling-hash block table, copy/insert opcodes, bounded-depth chains + periodic snapshots; lands as an alternative CAS object encoding with round-trip tests. | #252 | `libs/extras/vcs/delta.w`, tests | MED |
| 2c | **Compress design doc**: `docs/projects/compress.md` for `libs/extras/compress/` (CRC32 + DEFLATE, inflate-first), per #252's "should get its own project doc when picked up"; consumers: VCS object store, web gzip, git interop gateway. No code. | #252 | docs | LOW |
| 2d | **HTTP server framework, phases 1–2** (#235): rename `url` → `URL` in `urlparse.w` (+ `http_client.w` consumer), add `ConnectionContext` (plain socket or `tls_conn`, buffered I/O, keep-alive state) and the base HTTP/1.1 `ServerContext` accept loop with request-line/header/body parsing (Content-Length + chunked, mirroring `http_client.w`'s response parser). PascalCase convention documented in-file per the issue. Tests: loopback request/response. | #235 | `libs/standard/web/*` | MED |
| 2e | **`lib/ndarray.w` v1** per `docs/projects/ndarray.md`'s library-only recommendation: dense row-major float arrays over `T[]` slice descriptors, shape/stride struct, get/set/fill/map, matmul on 2-D — the #27 substrate. Grammar sugar explicitly out of scope. | #27 | `lib/ndarray.w`, tests | MED |
| 2f | **PG streaming milestone 1 — dispatch-table lexer** (#329 comment doc §7.1): first-byte switch + literal trie + length-bucketed keyword table in `pg_emit_lexer`, preserving longest-match/priority semantics exactly; regenerate `generated_c_parser.w`; benchmark via `parser_generator_w_test`. Seed graph — seed-safe syntax only; merge last & alone; verify + `parser_generator_c_test` gates. | #329 | `libs/extras/parser_generator/`, generated files | **HIGH** |

## 4. Wave 3 — integration layers (6 tasks)

| ID | Task | Issue | Files | Care |
|----|------|-------|-------|------|
| 3a | **Compress implementation**: CRC32 + DEFLATE inflate (deflate optional v1) per the 2c doc; fixture round-trips against known vectors. Largest single chunk (~1–2k lines) — budget accordingly. | #252 | `libs/extras/compress/`, tests | MED |
| 3b | **`vcs/merge3.w`**: three-way merge over `diff.w` hunks with conflict markers; `wvc merge` porcelain + tests (clean merge, conflict, criss-cross via `dag.w` merge-base). | #252 | `libs/extras/vcs/merge3.w`, `tools/wvc.w`, tests | MED |
| 3c | **HTTP server phases 3–5** (#235): `RequestContext` (parsed request + `set_status`/`set_header`/`write_body`/streaming), handler registration, HTTPS via `tls_accept` when cert/key present, keep-alive; migrate `examples/web/https_server.w` onto the framework; reuse `sse.w` for a streaming example. | #235 | `libs/standard/web/*`, examples | MED |
| 3d | **REPL agent mode + `!` escape** (#276 P3): banner/prompts → stderr when stdin is not a tty; `-e "entry"` one-shot; `--json` NDJSON per entry (`{entry, output, echo, error}`); `!cmd` reader escape desugaring to `lib/shell` with inherited stdio, `!cd`/`!export` intercepted. Fixes the D5 scraping pain for MCP `repl_eval`. | #276 | `repl.w`, `build.base.json` | MED |
| 3e | **Shared build cache MVP (D3-2)**: dumb content-addressed HTTP cache over `vcs/cas.w` — wexec consults `W_CACHE_URL` for step results keyed by its SHA-256 target hashes, CI populates; fresh clones hit `(cached)` for tests and the verify chain. Design guardrail: read-through only, failures fall back to local build. | #251 | `tools/wexec.w`, `libs/extras/vcs/cas.w` client | MED |
| 3f | **PG streaming milestone 2 — LL(1) committed dispatch** (#329 §7.2): FIRST/FOLLOW over `pg_grammar`, switch-based rule bodies where alternatives are disjoint, auto-left-factoring of shared literal prefixes, conflict *reporting*; AST output unchanged. Merge last & alone; verify + full PG test gates. | #329 | `libs/extras/parser_generator/` | **HIGH** |

## 5. Wave 4 — bigger bets (5 tasks)

| ID | Task | Issue | Files | Care |
|----|------|-------|-------|------|
| 4a | **#323 stage 1 — direct-file UX**: `./wbuild path/to/file.w` (compile+cache) and `./wbuild path/to/foo_test.w` (build+run its target) resolved through the existing manifest/deps machinery; `wtest path/...` selection by path. Plus a committed inventory (in the PR description and `docs/projects/build_system_next.md`) of every remaining shell script / hand-written target with its migration blocker — the concrete step toward "no generated files", without yet removing `build.json`. | #323 | `wbuild`, `tools/wexec.w`, `tools/test_map.w` | MED |
| 4b | **Bool-bitwise style migration, stage 1**: make the parser generator emit `&&`/`||` for guard chains in generated parsers (removes 80 of the 469 blocked sites), regenerate; then widen the `w check` hint to comparison-result operands behind the existing lvalue scope note. Per-site sweep of the remaining ~389 seed-graph sites is stage 2 (next wave, mechanical, reviewed in 50-site chunks). | ai_tooling backlog | `libs/extras/parser_generator/`, `grammar/` warning site | **HIGH** |
| 4c | **`wvc` sync**: have/want negotiation over the HTTP stack (client from `http_client.w`, server via the 2d/3c framework), push/pull of loose objects; local-loopback e2e test. | #252 | `libs/extras/vcs/`, `tools/wvc.w` | MED |
| 4d | **#231 design doc only**: `wbuildd` persistent build daemon + AST-options assessment (the issue's options a/b/c), designed against the same event-loop/JSON-RPC stack as the deferred REPL websocket server, per the consolidated plan's note. Recommendation + staging, no code. | #231 | docs | LOW |
| 4e | **#17 conformance expansion**: TestFloat-derived edge-case vectors for float32/float64 (NaN propagation, subnormals, rounding at the boundaries) as data-driven tests; document known MVP semantic differences and the F16C requirement in `docs/projects/float.md`. | #17 | `tests/`, docs | LOW |

## 6. Wave 5 — queued behind decisions/results from waves 1–4

- **#103 `++`/`--` implementation** per the 1d doc (grammar +
  `tests/parser_generator/w.pg` + fixtures) — HIGH care, one slot.
- **#327 implementation** per the 1e doc once the maintainer picks a
  surface — HIGH care (grammar/hash_builtin lowering).
- **#189 float `.add` decision**: float-aware `__w_map_add` variant
  selected by value type, or documenting the `m.get(k, 0.0) + x` idiom —
  small but seed-closure (`structures/hash_table.w`,
  `grammar/hash_builtin.w`); fold into whichever of the two map tasks
  above lands first.
- **PG streaming milestone 3** (listener-callback streaming mode,
  `mode streaming` directive, `w.pg` port with left-factoring).
- **#287 UTF-8 stage 1** per the 1f doc (likely strings/comments first,
  identifiers behind a decision).
- **Bool-bitwise stage 2** mechanical sweep.
- **`wvc` gzip/git-interop** once 3a lands; **defhash (4a of #251)** —
  per-definition hashing is compiler-front-end surgery; spec it against
  the tokenizer before assigning.
- **#123 attach phases 2–6** (`debugger/` target-access seam, symbol
  recovery, ptrace stepping): heaviest open project; recommend keeping
  on the strongest model available or splitting phase 2 into a
  seam-only refactor PR (mechanical, testable in-process) before any
  ptrace semantics.

## 7. Deferred, with reasons

- **#210 + wexec darwin dir hashing + darwin/arm64 REPL** — Mac-gated;
  ride the next Mac session.
- **#28 CUDA backend** — explicitly pending a maintainer surface-model
  decision (raw CUDA vs Triton-style); prerequisites are in.
- **#110 Optimization** — no body/scope; needs a maintainer statement
  or a measurement-first research task before it is schedulable.
- **#98 web-UI debugger** — low priority per the issue; couples to the
  #231 design (4d) — revisit after that doc.
- **#31 graphics** — stage 1 landed (`graphics/`, WebGL); next stages
  need maintainer scoping.
- **#16 protobuf** — needs a design doc; candidate for a future
  design-only slot after #327/#103 prove the pattern.
- **#207 asm into code_generator** — medium priority per the issue, but
  it grows the seed graph permanently and the offline pipeline is
  drift-checked and working; propose deciding after PG milestones show
  how much seed-graph budget remains.
- **REPL websocket server, multi-error reporting** — blocked on #231
  design and parser recovery research respectively.

## 8. Execution protocol (carried forward + Sonnet-specific)

- One task per agent, isolated worktree, branch per task; sequential
  merge after green; rebase + `./wbuild manifest` regenerate (never
  hand-merge `build.json`).
- Every PR: `git diff --name-only HEAD | ./bin/wtest changed` and run
  the printed targets (now `--run`/`--available` capable); compiler-tree
  or seed-graph diffs additionally `./wbuild verify` (+ `verify_x64`
  for word-size-sensitive work). Long suites run in the foreground.
- Seed-graph files use seed-era syntax only; HIGH-care PRs merge last
  and alone in their wave.
- New tests follow the manifest convention (`tests/foo_test.w` +
  `# wbuild:` directives + `./wbuild manifest`); irregular steps go in
  `build.base.json`.
- Friction found while executing goes into
  `docs/projects/ai_tooling_next_steps.md` in the same PR (standing
  repo rule) — wave 1a resets that file to accurate.
- Diagnostic message text is frozen by fixtures; any new/changed
  message updates its fixture in the same commit.
