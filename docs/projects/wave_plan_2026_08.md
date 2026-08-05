# Backlog audit → parallel subagent waves (program 2026-08)

## Context

**Why now.** The previous program (`docs/projects/wave_plan_2026_07b.md`) executed
its waves 1–2 — units U1–U10 all merged as PRs #385–#395 on 2026-07-30 — and then
stalled: **waves 3–4 (U11–U19) were never launched** (no `pb-u11..u20` branches or
PRs exist; the repo has been idle since 2026-07-30). U20 (REPL fault recovery)
landed separately — `repl/core.w` installs SIGSEGV/SIGILL/SIGBUS/SIGFPE handlers
with entry rollback — so it is *not* rescheduled. The 07b doc's execution-status
table was stale in both directions; this program fixes it and carries the residue.

**Sources re-audited 2026-08-04**: all 26 open GitHub issues, `docs/todo.txt`,
`docs/projects/ai_tooling_next_steps.md` (the live friction queue — several new
entries were logged *during* the 07b execution itself), every
`docs/projects/*.md` remaining-work section, and the PR history (what actually
landed vs. what trackers claim).

**Verified already done — not rescheduled**: bracketed paste + tab completion
(`lib/line_edit.w`), REPL fault recovery (07b U20), multi-assign, list
slices/negative index, heap/deque, prelude math/`elif`/`any`/`all`/`sorted`,
map default factory (#327), wdbg attach incl. hardware watchpoints (#123 — all
six phases), crash stack traces (#378 core, PR #393), compiler `--help` (#377
first pass, PR #390), VCS waves 1–4 except object packing, the real DEFLATE
encoder, golf-ergonomics waves 1–4.

## Environment (this remote Linux x86_64 container, probed 2026-08-04)

4 cores, ~30 GB free disk, `node` present (wasm gates run via
`tools/run_wasm.sh`); **no** i386 loader, qemu-aarch64, GPU, Mac, or wine.
Env-blocked targets (CI-covered; listed in PR bodies, never chased locally):
`dynamic_test`, `c_import_test`, `c_import_errno_test`, `c_import_libc_test`,
`float_abi_test`, `varargs_test`, `extern_data_test`, `verify_arm64` + arm64 run
targets, all `*_darwin`, `tests_win64`, `cuda_test`.

## Work units — 15 units in 3 waves

Wave size ≤6 on 4 cores (20-way concurrency demonstrably causes flakes and
deps-cache timeouts; 5–6 was stable across two prior programs). Wave N+1
launches after wave N's agents report. Unit branches `claude/pb8-<id>-<slug>`
cut from `origin/main`, one draft PR each.

### Wave 1 — tooling + leaf libraries (no compiler files → no `verify` gate)

| # | Unit | Files owned | Change |
|---|---|---|---|
| 1.1 | wtest deps-cache robustness + cost UX | `tools/test_map.w`, `tools/wtest.w`, `build.base.json` (tool_targets), `tests/wtest/` | Don't persist timeout-shaped `X <arch> w.w` deps failures as permanent (retry once; stderr line when a closure shell-out fails); progress/ETA during cold cache builds; `./wbuild wtest_cache` pre-warm target. |
| 1.2 | wtest selection accuracy | runnable-here scan, `tools/wtest_map_check.w`, `tests/wtest/map_expectations.expect` | Closure-level `--runnable-here` attribution (imported-module `c_lib`/`c_import`/`lib.cuda` needs); `wtest_map_check` hints the `-f` fixture manifest-order rule on order failures. |
| 1.3 | http_server flake hardening | `libs/standard/web/` test fixtures, `build.base.json` | Raise client/handshake/read timeouts on the four server targets (+`https_e2e_test`); optionally serialize the server suites behind a shared wexec resource. |
| 1.4 | VCS object packing (#252 remainder) | new `libs/extras/vcs/pack.w`, `tools/wvc.w`, `libs/extras/vcs/cas.w`, tests | Pack-file format over `cas.w` + `wvc pack`/`unpack`; optionally zlib-wrapped loose objects (unblocked by the DEFLATE encoder). |
| 1.5 | wbuildd stage-1 prerequisites (#231) | `lib/inotify.w` (new), `lib/net.w`, tests | inotify syscall wrappers + unix-domain-socket bind/listen helpers, per `docs/projects/wbuildd.md`. No daemon yet. |
| 1.6 | Skills upkeep | `.cursor/skills/` (3 new) | ARM64-under-qemu testing, `./wbuild update` seed discipline, c_import interop debugging. `skills_test` stays green. |

### Wave 2 — compiler/runtime features A (seed graph → `verify` required)

| # | Unit | Files owned | Change |
|---|---|---|---|
| 2.1 | json codecs: floats + `map[string, V]` (07b U15) | `structures/json.w`, `structures/json_codec.w`, `grammar/json_builtin.w`, tests | Float fields and `map[string,V]` fields in `to_json`/`from_json`. `verify` + `verify_x64`. |
| 2.2 | x64 DWARF `address_size` (07b U14) | `code_generator/dwarf.w`, tests | Emit 8 for x64 (4 today); structural test parsing the emitted DWARF. `verify` + `verify_x64`. |
| 2.3 | threads: atomics + mutex + join reclamation (07b U13) | `lib/thread.w`, atomics builtin, `lib/__arch__/*`, `docs/projects/threads.md` | threads.md staging items 2+3: `lock xadd`/`cmpxchg` builtins (x86/x64), futex mutex, worker stack reclamation on join. Arch ports out of scope. |
| 2.4 | c_import bit-field layout fidelity | `libs/extras/c_import/importer.w`, fixtures + x64 run tests | The remaining c_import next-priority. Assert on x64 (i386 dynamic tests env-blocked). Seed-syntax-safe + `verify`. |

### Wave 3 — compiler/runtime features B + the risk item

| # | Unit | Files owned | Change |
|---|---|---|---|
| 3.1 | ndarray index sugar `m[i, j]` (07b U11, #27) | `grammar/postfix_expr.w`, `tests/parser_generator/w.pg`, tests, `docs/projects/ndarray.md` | Multi-index lowering onto `lib/ndarray.w` as a typed builtin (map/list precedent), not operator overloading. `verify` + `verify_x64`. |
| 3.2 | type-system next (07b U18) | `compiler/type_table.w`, grammar type-name resolution | `type.fields` for globals and imports; qualified type names through import aliases (`f.SomeStruct`). `symbol_table` byte blob untouched. `verify`. |
| 3.3 | wasm stage-5 residue (07b U19) | `code_generator/wasm.w`, `docs/projects/wasm_backend.md` | Real-signature exports + accumulator globals-vs-locals measurement. wasm64 deferred. `verify_wasm` + wasm tests via node. |
| 3.4 | container `free()` pseudo-method | `grammar/list_builtin.w`, `grammar/hash_builtin.w`, `structures/`, `lib/container.w`, tests | First-class `free()` for `list[T]`/`map[K,V]`/`set[K]` (typed_containers.md gap). `verify`. |
| 3.5 | **W^X split stages B+C (07b U16) — SOLO** | `code_generator/elf_64.w`, `elf.w`/`elf_32.w`, `grammar/extern_statement.w`, `libs/extras/c_import/importer.w`, `docs/projects/wx_split.md` | Stage B (x64): second R+W `PT_LOAD`, two-buffer write per `elf_arm64.w`, extern-data COPY relocs into `.data`; then Stage C (x86, bootstrap target). Full verify matrix. Launched alone after 3.1–3.4 report. |

**Dropped/deferred** (with reasons): 07b U17 miscompile investigation (timeboxed
research, low yield), `optimization.md` §1.1 dead-mov fix (must merge last &
alone — collides with 3.5's slot), UTF-8 identifiers (#287 stage 2 — seven
maintainer decisions), #333 (needs maintainer examples), #207 (maintainer
seed-size call), #231 daemon proper (architecture decision), #323 stage 2,
#361/#337/#334/#338/#110 (policy-gated per three prior audits), darwin-only
items (no Mac), multi-error reporting (research-scale).

## Execution rules (unchanged from 07b — they worked)

Workers: `isolation: worktree`, background, general-purpose; **first verify the
item is still open against the tree** (trackers go stale — U20 proved it);
never hand-edit `build.json` (`./wbuild manifest`); union-merge
`ai_tooling_next_steps.md` (delete only your own entry); no backgrounded test
runs; single `./wbuild` writer per worktree; draft PRs via the GitHub MCP tools
(no `gh` here); PR bodies note env-blocked targets and the
regenerate-on-conflict rule for `build.json`.

E2E recipe per worker: `./wbuild build` → `w check --json` per edit →
`./wbuild manifest && manifest_check` when tests change →
`git diff --name-only origin/main | ./bin/wtest changed` → `./wbuild
test_changed` (foreground; cold cache takes minutes) → `verify`/`verify_x64`/
`verify_wasm` when gated → compile-and-run the new test on both word sizes →
`./wbuild tests` minus env-blocked.

## Close-out

Status comments (not closures) on #17, #27, #123, #251, #252, #276, #287,
#327, #335, #360, #377, #378 recording what landed and what this program adds;
recommendations to close #123/#327/#276/#360 as done/superseded. Execution
status lives in the table below, updated as PRs open and land.

## Execution status

| Wave | Unit | Status | PR |
|---|---|---|---|
| 1 | 1.1 wtest deps-cache robustness | PR open | #398 |
| 1 | 1.2 wtest selection accuracy | PR open | #400 |
| 1 | 1.3 http_server flake hardening | PR open | #399 |
| 1 | 1.4 VCS object packing | PR open | #401 |
| 1 | 1.5 wbuildd prerequisites | PR open | #402 |
| 1 | 1.6 skills upkeep | PR open | #397 |
| 2 | 2.1 json codec floats + map[string,V] | PR open | #404 |
| 2 | 2.2 x64 DWARF address_size | PR open | #403 |
| 2 | 2.3 threads atomics/mutex | PR open | #405 |
| 2 | 2.4 c_import bit-fields | PR open | #406 |
| 3 | 3.1 ndarray index sugar | launched | — |
| 3 | 3.2 type-system next | launched | — |
| 3 | 3.3 wasm stage-5 residue | launched | — |
| 3 | 3.4 container free() | launched | — |
| 3 | 3.5 W^X split B+C (solo) | queued (after 3.1–3.4) | — |

Note (2026-08-05): a container restart mid-wave-1 killed three in-flight suite
runs; work survived in worktrees and was salvaged commit-first. Waves 2+ run
under amended rules: workers commit+push before any long run, per-worker gates
exclude the full `tests` umbrella (coordinator/CI covers it), no parked waits,
≤4 concurrent agents.
