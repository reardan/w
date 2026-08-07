# Issue audit (August 2026): disposition of all 26 open issues

Status: recommendation only. Nothing in this document changes code, and no
issue is closed by the PR that adds it. It exists so the close-out pass has
a written, checkable basis.

## 1. Scope and method

Audited all 26 open issues at 2026-08-07 (bodies + every comment) against
the tree at `c8e3612` — i.e. after program 2026-08b merged (#413–#427).
Every "shipped" claim below was spot-checked in the tree rather than taken
from a status comment, because two of this program's own units (protobuf
1.4, REPL-at-breakpoint 4.2) turned out to be *already implemented* and the
trackers were stale in the "not done" direction.

Headline: **five issues are complete and should close**, three more are
scoping/decision questions rather than work items, and the remaining
eighteen are genuinely open — but two of them carry stale text that makes
them look bigger than they are.

## 2. Close as complete

These have no remaining in-scope work. Each one's leftovers are either
explicitly recorded non-goals, already tracked elsewhere, or small enough
that a narrow issue serves better than an open epic.

| # | Title | Why it can close | Verified in tree |
|---|---|---|---|
| #123 | wdbg: attach to a running process | All six phases of `debugger_attach.md` landed. Residue (in-target inferior calls, dynamic/PIE targets) is *explicitly out of scope* in the design doc, not unfinished work. | `debugger/attach.w`, `debugger/attach_eval.w`; doc header reads "implemented (within scope)" |
| #276 | REPL: state, defects, v2 plan | Every verified defect D1–D8 fixed; P0–P3 landed; P4 item 13 (full REPL at breakpoints) shipped too. Two leftovers only: arm64/darwin REPL and the websocket server. | `repl/core.w`, `repl/scan.w`; `debugger/wdbg.w:908` has the `repl` subprompt |
| #327 | map: default-value factory / auto-vivification | `new map[K, V](value\|factory)` shipped with the trap-on-missing contract preserved — the design constraint the issue was written around. | `map_default_factory.md` §Status; `tests/map_default_test.w` |
| #360 | Golf ergonomics wave 2 | The whole priority list landed except item 7 (lambdas — closed not-planned as #107) and generic sliding-window helpers. `mode` from item 10 exists. | `lib/stats.w:287`, `lib/edit_distance.w` |
| #252 | Version control: `libs/extras/vcs` in four waves | Waves 1–4, compressed objects, and pack re-deltification (`wpack 2`) all landed. Git-format interop is a recorded non-goal in the design doc, not an open item. | `libs/extras/vcs/{cas,diff,dag,tree,commit,index,delta,merge3,sync,pack}.w` |

Follow-ups worth filing **at close time**, so nothing is silently dropped:

- from #276 — (a) arm64/darwin REPL (needs a Mac or qemu runner), (b)
  websocket REPL server (leave it gated on #231, don't file until that
  decision lands);
- from #360 — sliding-window stdlib helpers (one small `lib/` addition);
- from #123 / #252 — nothing; their leftovers are recorded non-goals.

Note that #276 and #360 each already carry **two** "recommend closing"
comments from prior audits (2026-08-04 and 2026-08-07). They should be
closed, not commented on a third time.

## 3. Decide, don't schedule

These three are not blocked on engineering. They are open because a scoping
question has never been answered, and each has been asked at least twice.
Leaving them open costs a re-audit every wave and produces no work.

### #338 — Libraries for Everything

`compilation_model.md` (PR #339) found the issue is really two asks with
opposite answers:

- *"CLI tools are thin wrappers"* — **already largely true**. `wvc`,
  `wmeta` and `w.w` are thin; `wexec` and `wbuildgen` are the
  counter-examples, and refactoring them needs **zero compiler work**.
- *"Every module is a static/shared library"* — **has no analog** in W's
  whole-program, no-object-file, no-linker architecture. The doc weighed
  four options and recommended building none of them without explicit
  sign-off.

**Recommendation: close as not-planned**, and file a narrow issue for the
`wexec`/`wbuildgen` thin-wrapper refactor if that part is wanted. Keeping
one issue open for "maybe build a linker someday" is what makes it
un-actionable.

### #337 — LLVM Offload

The assessment found the parser generator's AST is syntax-only (no types,
no symbols), and that an LLVM path would be the project's **first external
toolchain dependency for a host backend** — in direct tension with the
no-assembler / no-linker / no-libc identity that the whole project is built
around.

**Recommendation: close as not-planned.** If the curiosity is worth
satisfying, the bounded version (a leaf tool emitting LLVM IR text for a W
subset, compiled by external `llc`) is a research spike that deserves its
own narrowly-scoped issue with a stop condition — not an open "LLVM
backend" ticket implying intent to ship one.

### #27 — Matrix Class

The issue body is empty; its scope is whatever was originally meant. The
substrate shipped (`lib/ndarray.w` / `ndarray64.w`: rank 1–4 dense arrays,
matmul, views, elementwise ops), the `a[i, j]` grammar sugar shipped, and
stage 3 (frees + `parallel_for` integration) shipped in #421/#425.
`ndarray.md` now has exactly one deferred item: stage-4 aligned allocation,
blocked on a SIMD-builtins design that does not exist yet.

The question "does this want a *dedicated matrix type/API* on top of
ndarray?" has now been asked in two consecutive audits with no answer.

**Recommendation: close as satisfied by ndarray**, unless a distinct matrix
API is actually wanted — in which case that API deserves its own issue with
a described surface, and aligned allocation should ride with the SIMD
design whenever that happens.

## 4. Keep open — genuinely active

| # | Title | What actually remains |
|---|---|---|
| #110 | Optimization | Boolean-comparison materialization (~8.5k `cmp;setcc;movzx;test;jcc` sites) and per-operator push/pop shuttling. **See §6 — this issue's newest comment is already stale.** |
| #251 | Build system directions | Architecture-scale only: direction 2 (traced inputs / `--hermetic`), direction 3's CAS-over-HTTP cache server + `wexec --remote=`, 4c save-time watcher. 4b stays deferred on #252 — **which is about to close, so 4b becomes schedulable.** |
| #323 | Ban generated files in the repo | Acceptance criterion 1 is **not met**: `build.json` and `tools/test_map.w` are still committed, and 22 `.sh` files are still tracked. Stages 1–2 shipped real progress; the finish line is still ahead. |
| #335 | REPL shell mode | Pipes/redirection (blocked on the void-return convention → stream-output rework) and the standalone `wsh` extraction (waiting on a second front end). `find`/`sed` are now unblocked by `lib/regex.w` but unscheduled. |
| #377 | Compiler error messages | Open-ended umbrella by design. Caret/context landed (#426). The one structural limit — multi-error reporting needs parser recovery in a single-pass compiler — is recorded as research-scale. |
| #378 | Better stack trace | Live handler (#393) and core-dump *processing* (#419, `tools/wcore.w`) shipped. What remains is W **generating** its own richer dumps, plus the heuristic-backtrace caveat. |
| #16 | Protobuf support | Stage 1 (wire codec) is in tree. Stages 2 (`.proto` codegen) and 3 (language integration / the `message` keyword) are maintainer-gated by design, with §10 open questions untouched. |
| #17 | Floating point: float16/bfloat16 | float16 on arm64/wasm; bfloat16 (tied to the GPU track); x64 debugger float display — **but see §6, that third item rests on a stale premise.** |
| #287 | UTF-8 support in W source | Stage 1 landed. Stage 2 (identifiers) is implementation-ready and blocked on **seven** maintainer decisions in `utf8_source.md` §6. Answering those converts it into a well-scoped unit. |

## 5. Keep open — unstarted, specified or speculative

Nothing to verify here; these are recorded intent, and the audit's only
finding is that none has drifted.

- **Specified, unstarted:** #207 (import `libs/asm` into `code_generator/`
  — acceptance criteria already written, medium priority), #28 (CUDA
  backend — prerequisites landed, `cuda.md` staged, backend itself
  untouched), #334 (UI framework — design doc landed; font rendering is the
  long pole), #379 (Fonts — the #334 blocker, correctly filed separately).
- **Decision-gated:** #231 (wbuildd + AST codegen — six open questions in
  `wbuildd.md` §6; gates #276's websocket server and #110's v2 half, so it
  is the highest-leverage decision on the board).
- **Placeholders, low priority:** #98 (web UI debugger — explicitly "not a
  finished plan"), #332 (streaming types), #333 (type operators), #361
  (split repository). All four are idea capture. They are cheap to keep and
  should not be re-audited every wave; consider a `future` label so sweeps
  can skip them.

## 6. Corrections to existing issue text

Two open issues currently misstate their own state, both in the direction
of looking *less* done than they are. Worth fixing at close-out time so the
next audit doesn't re-derive it.

1. **#251's Direction-1 checklist is stale.** The SHA-256 cache-key
   widening and the full `# wbuild:` directive vocabulary (`timeout=`,
   `stdin=`, `expect_stdout=`, `arch=`, `deps=`) have shipped. Re-tick the
   boxes rather than re-scheduling the work. (Already flagged in a comment;
   the body itself was never edited.)

2. **#110's newest comment is stale by one merge.** It describes
   `optimization.md` §1.1 (the dead `mov eax, imm32` before every
   local/parameter `lea`) as "in-flight, with a draft PR being prepared".
   It **merged as #427**, with measured results: x86 −8.25%, x64 −7.23%,
   arm64 −10.72%, wasm −7.03% binary size, ~3% faster self-compile, and all
   fixpoints holding. The issue stays open for the two remaining v0 items,
   but its headline item is done.

3. **#17's third leftover needs re-verification before it is scheduled.**
   Both `float.md` and the issue's audit comment say x64 debugger float
   display is blocked "since `wdbg` is still x86-only". That premise looks
   stale: `bin/wdbg64` is a real build target with `debug_test_x64` cases
   running against it. Separately, the float32 stack-decode `f` command that
   `float.md`'s milestone 7 describes is **not present in `debugger/`** —
   `f` is bound to `frame` in both `wdbg.w` and `attach.w`. Someone should
   establish what the actual gap is before treating this as a known blocked
   item.

## 7. Suggested close-out order

1. Close #123, #276, #327, #360, #252 as completed — filing the three
   follow-ups named in §2 first, so they exist before the trackers go away.
2. Answer §3: close #338 and #337 as not-planned (or convert #337 into a
   bounded spike), and make the #27 call.
3. Fix #251's checkboxes and note #110's §1.1 completion in the bodies.
4. Optionally label #98/#332/#333/#361 `future` so the next sweep can skip
   them.

That takes the board from 26 open to 18 (or 21 if §3 goes the other way),
with every remaining issue either actively worked, decision-gated on a
named question, or deliberately parked.
