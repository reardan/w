# Sonnet wave plan B (late July 2026): open issues → parallel-subagent tasks

Status: plan (2026-07-17). Successor to
`docs/projects/sonnet_wave_plan_2026_07.md`, whose waves 1–5 are merged
(PR #331). Inputs: all 23 open GitHub issues (bodies + comments,
including the 2026-07-17 status comments PR #331 left on
#17/#27/#231/#251/#252/#276/#287/#323/#327/#329), the friction backlog
in `docs/projects/ai_tooling_next_steps.md`, the previous plan's
"remaining queue" (§ Execution status), and verification of head
(`9b0b12e`): `lib/shell.w`, `repl/core.w`, `libs/extras/compress/`
(inflate + fast-mode deflate), the full `libs/extras/vcs/` set, PG
milestones 1–2, `++`/`--`, float `m.add`, and UTF-8 stage 1 are all
in-tree.

Execution model (unchanged): waves of parallel **Sonnet 5** subagent
PRs, one task per agent in an isolated worktree, sequential merge after
green. Every task is specified with files, gates, and a care level.
**HIGH**-care tasks touch the seed import graph, `grammar/`,
`code_generator/`, or the compiler front end; at most one per wave, and
it merges **last and alone** with `./wbuild verify` (+ `verify_x64`)
green. Investigation tasks are timeboxed with a written diagnosis as the
acceptable fallback deliverable.

## Execution status (2026-07-17)

Wave 1 (7 tasks, 1a–1g) is **in flight**: parallel Sonnet 5 subagents,
each in its own isolated worktree, are running now. None have merged
yet, so §2's table is still the plan, not a record — this section
fills in per task as each one lands, following the predecessor plan's
"Execution status" convention.

## 0. Do NOT schedule (verified landed or already commented)

Everything in the previous plan's waves 1–5 (see its "Execution status"
and PR #331's per-issue comments). Notably: `lib/shell.w` + REPL agent
mode/`!` escape (#276 P0–P3), vcs index/delta/merge3/HTTP sync (#252),
compress stage 1 (inflater, CRC-32/Adler-32, zlib/gzip), shared build
cache `W_CACHE_URL` (#251 D3-2), direct-file UX (#323 stage 1), PG
milestones 1–2 (#329, ~4× sweep speedup), `++`/`--` (#103), float
`m.add` (#189), UTF-8 stage 1 (#287), ndarray v1 (#27), float
conformance vectors (#17), design docs for #327/#231/compress/#103/#287.

## 1. Prioritization rationale

1. **Dogfooding-found library bugs first** — `itoa(INT_MIN)` and the
   `stream_peek_byte` 0xFF truncation are small, verified, and sit in
   broadly imported files; both are logged in `ai_tooling_next_steps.md`
   with the fix sketched. Cheap to land, real correctness wins.
2. **Doc/tracker sync stays wave 1** — the standing lesson: stale
   backlogs cause duplicate agent work.
3. **The bool-bitwise stage-2 sweep is the ideal parallel-Sonnet
   workload** — ~490 mechanical sites, self-enumerating via
   `w check --bool-ops`, chunkable by disjoint file sets. It gets its
   own wave so nothing else races the same files.
4. **Continue shipped tracks** before opening new ones: compress
   stage 2 (unblocks `wvc` packing), REPL shell mode (#335 builds
   directly on `lib/shell.w` + the `!` escape), attach phase 2 (#123),
   PG milestone 3 (#329).
5. **Design docs unblock maintainer decisions** on the new epics
   (#334 UI framework, #338 libraries, #337 LLVM, #16/#110 protobuf,
   #332/#333 futures) — cheap tasks, run them inside the waves.
6. **Blocked work is listed, not scheduled** (§6): maintainer-decision
   gates and Mac-gated items.

Issue-tracker anomaly to flag (task 1a): **#110 is titled
"Optimization" but its body is a protobuf proposal duplicating #16** —
ask the maintainer whether #110's body was pasted over, and which issue
protobuf should live in.

## 2. Wave 1 — bug fixes, sync, tooling QoL (7 tasks)

| ID | Task | Source | Files | Care |
|----|------|--------|-------|------|
| 1a | **Doc/tracker sync**: prune `ai_tooling_next_steps.md` entries PR #331 resolved; move shipped summaries into `ai_tooling.md`; refresh `docs/todo.txt`; add the pointer-arithmetic rule (`T* + int` is a raw byte offset for every pointee width; use `&a[i]` or `p + i * sizeof`) to README.md + CLAUDE.md per the backlog entry; flag the #110/#16 duplicate on the tracker. Docs only. | backlog | `docs/*`, README, CLAUDE.md | LOW |
| 1b | **`itoa(INT_MIN)` fix**: digit extraction via `-(n % 10)` without pre-negating (match `intstrlen`'s handling); tests for INT_MIN on x86 (`-2147483648`) and x64 (`-9223372036854775808`). `lib/lib.w` is seed-closure: seed-era syntax only. Gates: `verify`, `verify_x64`, full tests. | backlog | `lib/lib.w`, `tests/` | MED |
| 1c | **`stream_peek_byte` 0xFF fix**: mask the load (`& 255`), audit every direct `s.buffer[...]` consumer in `lib/stream.w`, regression tests proving `file_read_text`/`file_read_lines` no longer truncate at a 0xFF byte. Seed-adjacent blast radius (stream feeds wexec/wmeta/web) — own PR, full gates. | backlog | `lib/stream.w`, `tests/` | MED |
| 1d | **wexec introspection pair**: `wexec --explain-cache <target>` (state why a target is/isn't cacheable — the silent-permanent-miss trap) and `wexec --list --json` (per-target structural facts: steps, compile roots, deps, shell-out, exclude membership). | backlog | `tools/wexec.w`, tests | MED |
| 1e | **Protobuf design doc** (#16, noting the #110 body): wire-format scope (v2 vs v3), struct alignment vs new keyword, codegen vs runtime reflection, the JSON-support precedent, staged plan. No code. | #16/#110 | `docs/projects/protobuf.md` | LOW |
| 1f | **REPL shell-mode design doc** (#335): what exists (`!` escape, `!cd`/`!export`, `lib/shell.w`), the issue's `ls -la` → `shell_commands.ls(...)` translation idea, a `:sh` command-first toggle, the internal-tools library surface (which coreutils to mirror natively vs farm out to native via `run()`), standalone-tool question. Recommendation + staged plan, no code. | #335 | `docs/projects/repl_shell_mode.md` | LOW |
| 1g | **Cross-line call-tail diagnostic**: a statement starting with `(` is absorbed as a call of the previous expression statement; emit a "call arguments continue from the previous line" note when a call tail crosses a newline (non-breaking; the same-line-only hard rule stays a future decision). Fixture for the note text. Merges **last & alone**. Gates: `verify`, `verify_x64`, `warning_test`, w.pg check. | backlog | `grammar/postfix_expr.w`, fixtures | **HIGH** |

## 3. Wave 2 — bool-bitwise stage 2: the mechanical sweep (6 tasks)

Stage 1 (PR #331) landed the generated-parser conversion and the opt-in
`w check --bool-ops` widening. Measured worklist: 471 fires across
`w check --bool-ops w.w` + 19 in the suppressed compiler-injected
runtime. Each chunk agent self-enumerates its file set with
`./bin/wv2 check --bool-ops <root>` and converts `|`→`||`, `&`→`&&`
**only where both operands are side-effect-free** (comparisons,
bool-typed reads — short-circuiting must not change evaluation);
anything with a call or other effect on the RHS is left in place and
logged in the PR description. Seed-graph files may be edited (`&&`/`||`
are seed-era syntax) but every chunk PR runs `verify` + `verify_x64`.
Chunks are file-disjoint; merge sequentially in ID order.

| ID | Chunk (file set) | Known top files | Care |
|----|------------------|-----------------|------|
| 2a | `debugger/` | `wdbg.w` (47) | MED |
| 2b | `libs/asm/` | `x86_decode.w` (36) | MED |
| 2c | `libs/extras/` — for `parser_generator/` change the *generator* where output is generated, else hand-edit; regenerate `generated_c_parser.w` | `parser_generator/lexer.w` (27) | MED |
| 2d | `grammar/` + `compiler/` + `code_generator/` (seed graph) | `string_literal.w` (27), `tokenizer.w` (24) | MED |
| 2e | Everything else: `lib/`, `structures/` (incl. the 19 suppressed auto-import/prelude sites), `tools/`, `repl*`, `tests/` non-fixture sites | — | MED |
| 2f | **Flip the default**: widen the on-by-default hint to comparison-result operands, retire `--bool-ops` to a no-op alias, update `warning_test` + `check_bool_ops_test` fixtures in the same commit. Requires 2a–2e merged (tree must be clean under the widened default — `--strict` self-host gate). Merges **last & alone**. | compiler warning site, fixtures | **HIGH** |

## 4. Wave 3 — features on shipped tracks (6 tasks)

| ID | Task | Issue | Files | Care |
|----|------|-------|-------|------|
| 3a | **Compress stage 2 — real DEFLATE**: static + dynamic Huffman encoding, lazy matching per `docs/projects/compress.md`; round-trip tests vs the stage-1 inflater plus external vectors (a zlib/gzip file the tests decode). Unblocks `wvc` packing (4a). | #252 | `libs/extras/compress/deflate.w`, tests | MED |
| 3b | **REPL shell mode MVP** per the 1f doc: `:sh` command-first toggle + first slice of the native tool set (`ls`/`cat`/`pwd`/... as `lib/shell_commands.w` over `lib/lib.w` dir walking), unknown commands farmed to native via `lib/shell.run` (the issue's stated MVP). Scripted `repl_test` session cases. | #335 | `repl.w`, `lib/shell_commands.w`, `build.base.json` | MED |
| 3c | **#123 phase 2 — target-access seam only**: route `debugger/memory.w` reads/writes and register accessors through an in-process/ptrace dispatch layer with the in-process path byte-identical (no ptrace semantics yet — that is phase 4). Gates: `verify` (debugger/ is seed-compiled via `--debug`), attach smoke (`tools/attach_test.sh`). | #123 | `debugger/` | MED |
| 3d | **Silent-exit-1 audit**: sweep the ~95 `error()` call sites and driver exit paths for exits with no diagnostic (three fixed in #331's round: output-write, EOF-in-literal, OOM); fix stragglers, add fixtures where messages are new; attempt a repro of the original 2026-07-09 darwin-seed silent exit on Linux and write up what remains Mac-only. | backlog | `compiler/`, `w.w`, fixtures | MED |
| 3e | **`string_free(b); free(b)` heap-corruption root cause** (timeboxed): the repl.w-context-only allocator corruption. Deliverable: a minimal repro + written diagnosis (allocator/JIT interaction) on a new issue, or a fix. The workaround stays either way. | backlog | investigation | MED |
| 3f | **PG milestone 3 — streaming mode** (#329): listener-callback streaming (`mode streaming` directive), w.pg left-factoring worklist from `--report`; AST default output unchanged, `generated_c_parser.w` byte-stable or regenerated intentionally. Merges **last & alone**. Gates: `verify`, full PG tests, `parser_generator_w_test` timing noted. | #329 | `libs/extras/parser_generator/` | **HIGH** |

## 5. Wave 4 — bigger bets + epic design docs (6 tasks)

| ID | Task | Issue | Files | Care |
|----|------|-------|-------|------|
| 4a | **`wvc` compressed objects**: zlib-deflate loose objects via compress stage 2 (3a), transparent on read via the stage-1 inflater; migration story for existing stores (header sniff). Round-trip + `wvc` porcelain tests. | #252 | `libs/extras/vcs/cas.w`, tests | MED |
| 4b | **#123 phase 3 — symbol/line recovery for attach**: `wdbg --attach <pid> file.w` recompiles in-process to regenerate compiler tables, validated against `/proc/<pid>/exe` + maps; source-level `bt`/`l`/`i functions` on a live process. | #123 | `debugger/` | MED |
| 4c | **#251 Direction 2 — traced dependencies**: ptrace-based input tracing for wexec steps (dogfoods `debugger/attach.w` plumbing); record files opened for read as a cache-key audit; optional `--hermetic` failure mode. Linux-only, flagged. | #251 | `tools/wexec.w`, `debugger/` reuse | MED |
| 4d | **UI framework design doc** (#334): survey what exists (`graphics/`, WebGL/wasm path, `tools/web/`), target set (desktop/mobile/web), retained vs immediate mode, forms/widgets v1, the grayscale-material default; staged plan sized for later waves. No code. | #334 | `docs/projects/ui_framework.md` | LOW |
| 4e | **Compilation-model design doc** (#338 + #337, one doc): libraries-for-everything (static-lib module format, CLI-as-thin-wrapper — relate to `wx_split.md`) and the LLVM-offload assessment (feeds on #231's AST options and PG milestone 2); include short scoping notes for the "Future:" issues #332 (streaming types) and #333 (type operators). No code. | #338/#337 | `docs/projects/compilation_model.md` | LOW |
| 4f | **defhash** (#251 D4a): `wv2 defhash` — per-top-level-definition token-stream hashes + referenced-symbol lists over the tokenizer/symbols machinery; wire into wexec cache keys and `wtest changed` at definition granularity behind a flag. Merges **last & alone**. Gates: `verify`, `verify_x64`, wtest selection tests. | #251 | `compiler/`, `tools/wexec.w`, `bin/wtest` | **HIGH** |

## 6. Blocked / gated — listed, not scheduled

Maintainer-decision gates (each has a doc or comment awaiting an answer):

- **#327** map default factory — surface pick requested in the 1e doc
  (2026-07-17 comment). Includes the incidental `new map[K,V](...)`
  w.pg/compiler mismatch, which should be reconciled when picked up.
- **#231** wbuildd — `docs/projects/wbuildd.md` §6 questions open;
  daemon phase 1 becomes schedulable once answered. The REPL websocket
  server (#276 P4) waits on the same decision.
- **#28** CUDA — surface model (raw CUDA vs Triton-style) still open;
  `cuda.md` staged plan is otherwise shovel-ready. **#17**'s bfloat16
  half is tied to this decision.
- **#287** stage 2 — UTF-8 identifiers is a policy call
  (`utf8_source.md` lays out PEP-3131 trade-offs).
- **#207** assembler into the seed graph — permanent seed-size budget
  call; the offline pipeline is drift-checked and working.
- **#27** matrix — ndarray v1 landed; whether a dedicated matrix
  type/sugar is wanted is a scoping call (see the 2026-07-17 comment).
- **#110** — title/body mismatch; blocked on the 1a clarification.

Mac-gated (ride the next Mac/darwin session): **#210**
`arm64_darwin_smoke_test` target, wexec darwin directory hashing,
arm64/darwin REPL (#276 P4).

Research-scale (no wave slot until scoped): multi-error reporting
(parser recovery), PG milestone 4 (actions/predicates — after M3
ships), #123 phases 4–6 (execution control, hw watchpoints, restricted
eval — after 3c/4b), `wvc` git-format interop (design-doc non-goal "for
now"), top-level `int x = 5` initialization sugar (the `:save`
round-trip asymmetry — needs a grammar decision first; the asymmetry is
documented in `:help` in the meantime), arch-aware "check every target
this file compiles under" mode.

## 7. Execution protocol (carried forward)

- One task per agent, isolated worktree, `claude/…` branch per task;
  sequential merge after green; on `build.json` conflict regenerate
  (`./wbuild manifest`), never hand-merge.
- Every PR: `git diff --name-only HEAD | ./bin/wtest changed` and run
  the printed targets (`--run` capable); compiler-tree or seed-graph
  diffs additionally `./wbuild verify` (+ `verify_x64` for
  word-size-sensitive work). Long suites run in the foreground with
  generous timeouts.
- Seed-graph files use seed-era syntax only; HIGH-care PRs merge last
  and alone in their wave.
- New tests follow the manifest convention (`tests/foo_test.w` +
  `# wbuild:` directives + `./wbuild manifest`); irregular steps go in
  `build.base.json`.
- Diagnostic text is frozen by fixtures — message changes update
  fixtures in the same commit.
- Friction found while executing goes into
  `docs/projects/ai_tooling_next_steps.md` in the same PR; wave 1a
  resets that file to accurate first.
- Orchestrator follow-through after each wave: comment progress on the
  touched issues (#331's per-issue status comments are the model),
  update this file's execution status, and surface §6 decision asks to
  the maintainer.
