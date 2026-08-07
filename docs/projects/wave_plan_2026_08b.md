# Backlog audit → parallel subagent waves (program 2026-08b)

## Context

**Why now.** The previous program (`docs/projects/wave_plan_2026_08.md`, PR #396)
fully executed: all 15 units merged as PRs #397–#411 on 2026-08-05, and the repo has
been idle since. This program schedules the residue: items that program deferred,
friction its own execution logged into `docs/projects/ai_tooling_next_steps.md`, and
newly-unblocked work.

**Sources re-audited 2026-08-06**: all 26 open GitHub issues (bodies + status
comments), `docs/todo.txt`, `docs/projects/ai_tooling_next_steps.md`, every
`docs/projects/*.md` remaining-work section, and the tree at HEAD (`dba9c97`).

**Verified already done — not rescheduled**: wtest deps-cache robustness (#398),
closure-level `--runnable-here` attribution (#400), VCS object packing (#401), json
float32 + `map[string, V]` codecs (#404), threads atomics/mutex/reclamation (#405),
c_import bit-field *layout* (#406), type-system next (#407), container `free()`
(#408), ndarray `m[i, j]` sugar (#409), wasm real-signature exports + acc-locals
default (#410), W^X stages B+C (#411), REPL P0–P3 complete (fault recovery,
bracketed paste, tab completion, late binding, `:sh` stages 1–3), golf-ergonomics
waves 1–4 (#360 is closeable), `wv2 defhash`, SHA-256 wexec cache keys, and the
`# wbuild:` directive vocabulary (`timeout=`/`stdin=`/`expect_stdout=`) — the last
two mean issue #251's Direction-1 checklist is partly stale.

## Environment (this remote Linux x86_64 container, probed 2026-08-06)

4 cores; `node` present (wasm gates runnable); **no** i386 loader, qemu-aarch64,
GPU, Mac, or wine. Env-blocked targets (CI-covered — `ci.yml` runs the full
`./wbuild tests` with `libc6:i386` on every PR — listed in PR bodies, never chased
locally): `dynamic_test`, `c_import_test`, `c_import_errno_test`,
`c_import_libc_test`, `float_abi_test`, `varargs_test`, `extern_data_test`,
`verify_arm64` + arm64 run targets, all `*_darwin`, `tests_win64`, `cuda_test`.

Fresh worktrees have **no seed and no `bin/`** (both gitignored): each worker's
first `./wbuild build` downloads the pinned seed per `SEEDS` and bootstraps.
Amended rules carried from the 08 program's incident log: **≤4 concurrent agents**,
workers commit+push before any long run, per-worker gates exclude the full `tests`
umbrella (coordinator/CI covers it), single `./wbuild` writer per worktree,
`-j 2` per worker while more than two workers run.

**Maintainer decisions for this program**: auto-merge each wave into main after
per-merge gates (the 08 model); include the thread-pool unit; exclude bfloat16
(GPU-track coupling left open).

## Work units — 16 units in 5 waves

Unit branches `claude/pb9-<id>-<slug>` cut from `origin/main`, one draft PR each.
Wave N+1 launches after wave N is integrated.

### Wave 1 — tooling + leaf libraries (no seed-graph files → no `verify` gate)

| # | Unit | Files owned | Change |
|---|---|---|---|
| 1.1 | wtest availability probes | `tools/test_map.w`, `tests/wtest/`, `build.base.json` | (a) `wtest_step_unavailable_reason` scans `sh -c` command strings for known runner paths (today only argv[1], so `pac_corrupt_test_arm64` escapes); (b) umbrella collapse composes with the availability filter (never emit an umbrella whose dep set includes dropped targets — emit surviving members instead); (c) retain named `c_lib` sonames and probe them (std lib dirs/ldconfig cache), closing the `graphics_gl_smoke_test`/libGL false-select. |
| 1.2 | VCS pack re-deltification | `libs/extras/vcs/pack.w`, `tools/wvc.w`, tests | #252 remainder: cross-object delta compression inside `.wpack` (writer window/depth pairing, per-entry encoding tag, reader base-chain resolution); deterministic packs and byte-identical loose round-trip preserved. |
| 1.3 | `lib/regex.w` pattern core | new `lib/regex.w`, tests | The reusable pattern-matching core gating shell-mode grep/find/sed (#335). Bounded scope: literals, `.`, `[...]` classes, anchors, `*`/`+`/`?`; no backrefs. |
| 1.4 | protobuf wire codec + design doc | new `libs/extras/protobuf/`, `docs/projects/protobuf.md`, tests | #16 first increment: varint/zigzag/tag/length-delimited wire reader+writer as a plain library (proto3-first), design doc staging descriptor generation and later grammar integration. |

### Wave 2 — compiler surface A + remaining wtest work

| # | Unit | Files owned | Change |
|---|---|---|---|
| 2.1 | nested-map-key miscompile fix | `grammar/hash_builtin.w`, `grammar/postfix_expr.w` (map branch), tests | The known miscompile (todo.txt): `m[h[k]]` — `hash_index_*` pending slots are set before the key `expression()` runs and get clobbered by a nested map read. Fix: locals-then-commit-after-`]`, copying `grammar/ndarray_index.w`'s documented pattern. `verify` + `verify_x64`. |
| 2.2 | `w symbols --layout` | `compiler/compiler.w`, tests | Struct layout dump without running a binary (`ai_tooling_next_steps.md` 2026-08-05): flag loop in `symbols_main`, per-field `size` next to the existing `offset`, a `--layout` view, honest arch labels (arm64/win64 currently report "x64"). Arch-selector composition is already free. `verify`. |
| 2.3 | core-dump processor (#378 half 2) | new `tools/wcore.w`, tests | `ET_CORE` reader (PT_NOTE/NT_PRSTATUS + PT_LOAD) + CLI printing registers and a symbolized backtrace for kernel cores of W binaries, built on the out-of-process machinery from `wdbg --attach` (`debugger/symbols.w`, `debugger/lines.w`, `debugger/sigcontext.w`). |
| 2.4 | wtest deps-failure diagnostics | `tools/test_map.w`, `tests/wtest/` | The anonymous "deps failed for N roots" warning names failing roots + one root's stderr; failures recorded so a new `wtest why <root>` explains a root's selection story. |

### Wave 3 — compiler/runtime B

| # | Unit | Files owned | Change |
|---|---|---|---|
| 3.1 | c_import bit-field member access | `libs/extras/c_import/importer.w`, `grammar/postfix_expr.w` (member branch), tests | Side table {unit_offset, bit_offset, width, signed} captured in `ci_layout_bit_field` (today discarded); replace the dedicated error with read (load/shr/mask/sign-extend) and RMW write codegen. x64 run tests pinned against gcc. `verify` + `verify_x64`. |
| 3.2 | json codec float64 | `structures/json.w`, `structures/json_codec.w`, `grammar/json_builtin.w`, tests | float64 fields in `to_json`/`from_json` on 8-byte-word targets (float64 value slot + parse/format in json.w; `f64toa` exists); x86 rejection stays. `verify` + `verify_x64`. |
| 3.3 | ndarray stage 3 + frees | `lib/ndarray.w`, `lib/ndarray64.w`, slice-free helper, tests | Slice-level `array_free(T[] view)` per the staged shape, then `ndf_free`/`ndi_free`; parallel_for-chunked ops asserting bit-identical results vs serial (unblocked by #405). Outside the seed closure. |
| 3.4 | shell mode stage 4 | `lib/shell_commands.w`, `repl/shell_translate.w`, tests | `ln`/`df`/`ps` tools + translator arms, plus `grep` wired to wave 1's `lib/regex.w` (ships ln/df/ps only if 1.3 missed). Pipes/redirection stay deferred per the design doc. |

### Wave 4 — cross-cutting + integration-sensitive

| # | Unit | Files owned | Change |
|---|---|---|---|
| 4.1 | error caret/context (#377) | `compiler/tokenizer.w`, fixtures as needed | Keep the frozen `<msg> in <file>:<line>` line byte-identical; *add* the source line + caret underneath from the already-tracked line/column. Substring fixture needles should pass; update any exact-byte `.expect` sidecars that break. `verify` + `verify_x64`. |
| 4.2 | REPL at wdbg breakpoints (#276 P4) | `debugger/eval.w`, `repl/core.w`, tests | Replace `dbg_eval`'s hand-rolled subset with `repl/core.w`'s engine at breakpoints (multi-line entries, persistent definitions); locals scratch-binding stays as a pre-eval hook. `verify` + `verify_x64`. |
| 4.3 | thread pool | `lib/thread.w`, `docs/projects/threads.md`, tests | threads.md staging item 2: persistent worker pool behind `parallel_for` (no clone(2) per chunk); join-time reclamation semantics preserved. Both word sizes; no verify gate. |

### Wave 5 — solo risk item (merges last & alone)

| # | Unit | Files owned | Change |
|---|---|---|---|
| 5.1 | dead-mov removal (optimization §1.1) | `compiler/symbol_table.w`, `code_generator/`, asm fixtures | The measured dead address-materializing `mov` before every local/param reference (8.3% of `bin/wv2`'s bytes). Direct `sym_get_value` conditional per `optimization.md` §6.1. `verify` + `verify_x64` + asm fixtures. |

**Dropped/deferred** (with reasons): UTF-8 identifiers #287 stage 2 (seven maintainer
decisions, `utf8_source.md` §6); bfloat16 (maintainer call, GPU-track coupling);
wasm64 (deferred until engines make it boring); arm64/darwin/win64/GPU items
(env-blocked); #207 (seed-size call), #231 daemon (architecture decision), #323
stage 2, #333/#334/#337/#338/#361 and #110's v2 half (policy-gated per prior
audits); multi-error reporting (research-scale); shell pipes/redirection
(structural rework, staged in `repl_shell_mode.md`); #251 directions 2–3
(architecture-scale; the Direction-1 checklist is partly stale — see close-out).

## Execution rules (the 08 program's amended set)

Workers: `isolation: worktree`, background, general-purpose; **first verify the
item is still open against the tree**; never hand-edit `build.json`
(`./wbuild manifest`); union-merge `ai_tooling_next_steps.md` (add your own
entries, delete only entries your unit served); no backgrounded test runs; single
`./wbuild` writer per worktree; commit+push before any long run; draft PRs via the
GitHub MCP tools (no `gh` here); PR bodies note env-blocked targets and the
regenerate-on-conflict rule for `build.json`.

E2E recipe per worker: `./wbuild -j 2 build` → `w check --json` per edit →
`git add` new files → `./wbuild manifest && manifest_check` when tests change →
`./wbuild wtest && ./wbuild -j 2 wtest_cache` → `git diff --name-only origin/main |
./bin/wtest changed` → `./wbuild -j 2 test_changed` (foreground) →
`verify`/`verify_x64` when seed-graph files changed → compile-and-run new tests on
both word sizes.

Note (2026-08-06): GitHub Actions had a major outage during waves 1–2 (runs killed
at exactly 15:01 or failing silently mid-run — including on a docs-only diff and on
main itself). Per-merge local gates were the merge bar throughout, per the execution
rules; main's CI is re-run after recovery as the authoritative full-suite check.
The outage also restarted this session's container mid-wave-2: both in-flight
workers had committed and pushed first (per the amended rules), so no work was lost —
unit 2.4's PR was opened by the coordinator from the pushed branch.

## Close-out

Status comments (not closures) on #16, #27, #251, #252, #276, #335, #360, #377,
#378 recording what landed and what this program adds; recommendations to close
#276/#360 as done; a #251 comment noting the stale Direction-1 checkboxes.
`docs/todo.txt`'s nested-map known-bug entry and the served
`ai_tooling_next_steps.md` entries are updated by the owning units.

Program executed 2026-08-06/07: 14 units delivered as draft PRs (#413-#427,
plus the unscheduled #416 wexec diagnostics unit) and all merged into main by
sequential per-wave integration — per-merge gates (self-host fixpoints on every
affected target + the units' targeted suites + manifest_check), conflicts
resolved by union-merge (docs, distant regions of tools/test_map.w) and manifest
regeneration (build.json). Two scheduled units needed no PR: protobuf (1.4) and
REPL-at-breakpoint (4.2) were already implemented at HEAD — trackers stale in the
"not done" direction, corrected in status comments on #16 and #276.

Final unit 5.1 (dead address-slot removal) measured: x86 -8.25%, x64 -7.23%,
arm64 -10.72%, wasm -7.03% binary size; 32k dead mov+lea pairs to zero on both
x86 targets; self-compile ~3% faster; x86/x64/wasm fixpoints all hold.

## Execution status

| Wave | Unit | Status | PR |
|---|---|---|---|
| 0 | 0.1 wexec fail-fast diagnostics (unscheduled; found investigating CI) | merged | #416 |
| 1 | 1.1 wtest availability probes | merged | #414 |
| 1 | 1.2 VCS pack re-deltification | merged | #413 |
| 1 | 1.3 lib/regex.w pattern core | merged | #415 |
| 1 | 1.4 protobuf wire codec | already shipped at HEAD (wave 4d + PR #364; audit correction) | — |
| 2 | 2.1 nested-map-key miscompile fix | merged | #417 |
| 2 | 2.2 w symbols --layout | merged | #418 |
| 2 | 2.3 core-dump processor | merged | #419 |
| 2 | 2.4 wtest deps-failure diagnostics | merged | #420 |
| 3 | 3.1 c_import bit-field access | merged | #423 |
| 3 | 3.2 json codec float64 | merged | #424 |
| 3 | 3.3 ndarray stage 3 + frees | merged | #421 |
| 3 | 3.4 shell mode stage 4 | merged | #422 |
| 4 | 4.1 error caret/context | merged | #426 |
| 4 | 4.2 REPL at wdbg breakpoints | already shipped at HEAD (wdbg `repl` subprompt; audit correction) | — |
| 4 | 4.3 thread pool | merged | #425 |
| 5 | 5.1 dead-mov removal (solo) | merged | #427 |
