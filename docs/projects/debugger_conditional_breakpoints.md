# Debugger: Conditional Breakpoints, Hit Counts & Logpoints

Status: **implemented** (`debugger/breakpoints.w`, `debugger/eval.w`,
`debugger/wdbg.w`; tests in `tests/debug_fixture3.w` and the `debug_test`
/ `debug_test_x64` Makefile targets).

Tracks the active remainder of
[reardan/w#38](https://github.com/reardan/w/issues/38) after PR #36 landed
stepping, breakpoints, watchpoints, inspection and fatal-signal
post-mortem. #38 also listed hardware watchpoints and a web UI debugger;
those are lower priority and out of scope here — see "Split off" below.

## Motivation

`wdbg` (`debugger/*.w`) is scriptable over stdin (`.cursor/skills/w-debug-wdbg`):
an agent pipes a fixed command sequence and greps the output instead of
sprinkling and reverting print statements. That story breaks down exactly
where a plain breakpoint is too blunt:

- **A bug only reproduces on iteration 4,301 of a loop.** Today the only
  tool is `break` + `c` repeated thousands of times, or a hand-edited `if`
  around a `debugger` statement in the source (which then has to be
  reverted). A conditional breakpoint stops once, exactly when the
  condition is true.
- **An agent wants a value's trajectory across a whole run**, not just its
  value at one stop. Today that means single-stepping (slow, and it
  changes the timing of anything racy) or adding temporary `println`
  calls (a source edit to make and revert). A logpoint prints and
  auto-continues, with no source edit and no stop-per-iteration
  round-trip.
- **Hit counts** ("stop the 10th time this line runs") are the standard
  complement to both: cheap to implement once conditions exist, and it is
  the natural way to skip past known-uninteresting early iterations.

All three are explicitly called out as "the pieces exist now (breakpoints
+ in-process eval); needs a command wiring them together" in #38.

## Split off (separate low-priority issues)

Hardware watchpoints and the web UI debugger are unrelated in
implementation shape (one needs a second ptrace'ing process; the other is
a new UI surface) and neither blocks or is blocked by this work. Moving
them off #38 onto their own issues:

- **Hardware watchpoints via an out-of-process ptrace mode** — today's
  software watchpoints (`debugger/watchpoints.w`) single-step the whole
  program at statement granularity, which is a large, sometimes
  prohibitive slowdown. Hardware (DR0-DR7) watchpoints need a supervising
  second process (in-process code cannot set its own debug registers
  usefully the way `wdbg` is built today), which is a different
  architecture from the rest of `wdbg`'s in-process model — worth its own
  design doc when it becomes a priority.
- **Web UI debugger** (from `docs/todo.txt`'s future list) — a new
  frontend over the same command surface; no design work done yet.

Action: file both as new low-priority GitHub issues, cross-linked from
#38, and drop them from #38's remaining-work list so #38 (or its
successor) tracks only conditional breakpoints/hit counts/logpoints.

## Scope of this increment

In scope:
1. `condition <n> <expr>` — attach or clear a boolean condition on
   breakpoint `n`.
2. `ignore <n> <count>` — skip the next `count` eligible (condition-true)
   hits before actually stopping.
3. `log <target> <expr>` (dprintf-style logpoint) — a breakpoint that
   evaluates `<expr>`, prints it, and auto-continues instead of stopping;
   composes with `condition`/`ignore` on the same slot.
4. `info breakpoints` (`i b`) and the "hit ..." announcement grow
   condition/ignore/hit-count fields.

Explicitly deferred to a fast-follow, not blocking this increment:
- Multi-expression logpoints (`log foo x, y, z` / printf-style format
  strings). MVP is one expression, matching `print`'s existing grammar
  exactly. Revisit once single-expression logpoints are dogfooded and the
  demand for a format string is real.
- `break similar` fuzzy target matching (also listed as remaining in #38)
  is independent of conditions/hit-counts/logpoints and can land
  separately whenever convenient.
- Locals-in-compiled-expressions is already solved (`debugger/eval.w`
  binds visible locals before compiling); nothing new needed here.

## Design

### Data model (`debugger/breakpoints.w`)

Extend the existing parallel-array-of-slots pattern (`bp_addrs`,
`bp_bytes`, `bp_armeds`, `bp_temps`) with three more arrays, sized like
the others (`bp_max()` slots):

- `bp_cond_exprs` — `char*` per slot, word-sized entries holding an
  owned copy of the condition text (0 = no condition), same ownership
  pattern as `dbg_watch_texts` in `debugger/watchpoints.w`.
- `bp_hit_counts` — `int` per slot: incremented every time execution
  reaches the breakpoint's address, regardless of condition. This is the
  raw "reached N times" counter — simple to implement, simple to assert
  in tests, and useful by itself for logpoints (each logged line can
  carry its hit number).
- `bp_ignore_counts` — `int` per slot: counts down. Decremented only on
  an *eligible* hit (condition true or absent); while `>0` the breakpoint
  does not stop even though its condition passed.
- `bp_log_exprs` — `char*` per slot, same ownership as `bp_cond_exprs`
  (0 = not a logpoint). When set, an eligible hit prints and
  auto-continues instead of entering the command loop.

`bp_delete`/`bp_delete_all` free `bp_cond_exprs[i]`/`bp_log_exprs[i]` when
non-null and reset the two counters to 0, mirroring
`dbg_watch_delete`'s `free()` of its owned text.

### Evaluation (`debugger/eval.w`)

`dbg_eval_compile` already compiles `return <expr>` in-process and
returns the compiled function's address (or 0 on a compile error);
`dbg_eval` is a thin wrapper that calls it, writes back any local
mutations, and prints `= <value>`. Add a non-printing sibling for
condition/logpoint use:

```
int dbg_eval_ok   /* set by dbg_eval_call: 0 = the expression failed to compile */

int dbg_eval_call(char* expr, int stop_addr, int esp):
    dbg_eval_ok = 0
    int f = dbg_eval_compile(expr, stop_addr, esp)
    if (f == 0):
        return 0
    int v = f()
    dbg_eval_writeback()
    dbg_eval_ok = 1
    return v
```

(Implementation note: the sketch above returns a sentinel `-1` on compile
failure; that collides with a real expression legitimately evaluating to
`-1`, which is truthy under W's C-like semantics — a condition of
`i == -1` would then misreport as "failed to compile". The landed version
uses a separate `dbg_eval_ok` out-of-band flag instead, which callers
check before trusting the return value.)

`dbg_eval` itself is rewritten in terms of it (a compile error already
prints its own diagnostic via the normal error path before returning 0,
so no duplicate message is needed).

**Compile-error policy for conditions**: fail closed the first time (stop
and print `condition <n>: <expr> failed to compile, stopping unconditionally`)
rather than silently never stopping — a condition that can't compile is a
typo the user needs to see, and stopping is the safe default (matches
`print`'s existing behavior of surfacing compile errors rather than
swallowing them).

### `wdbg_trap`'s breakpoint-hit path (`debugger/wdbg.w`)

Today (`ctx_trapno(context) == 3` branch, `bp = bp_find(addr)` case):
disarm, rewind eip, announce, delete-if-temp, enter the command loop.

New gating, inserted before the announce/stop:

```
bp_hit_counts[bp] += 1
int stop = 1
if (bp_cond_exprs[bp] != 0):
    stop = dbg_eval_call(bp_cond_exprs[bp], addr, ctx_esp(context)) != 0
if (stop):
    if (bp_ignore_counts[bp] > 0):
        bp_ignore_counts[bp] -= 1
        stop = 0
if (stop):
    if (bp_log_exprs[bp] != 0):
        dbg_log_report(bp, addr, ctx_esp(context))  # prints, does not stop
        stop = 0
if (stop == 0):
    dbg_prepare_resume(context, addr, dbg_step_none())
    return
```

then fall through to the existing announce / `bp_is_temp` delete / stop-loop
code unchanged. This reuses `dbg_prepare_resume`'s existing re-arm dance
verbatim: calling it with the breakpoint's own address as `stop_addr` finds
the (already disarmed) breakpoint again via `bp_find(ctx_eip(context))`
inside it, sets `dbg_rearm_bp` and the trap flag exactly as a normal `c`
does when resuming over an armed breakpoint — no new re-arm logic needed,
and it composes for free with live watchpoints (already handled inside
`dbg_prepare_resume`).

`bp_is_temp` deletion only happens when `stop == 1` and the code reaches
the existing announce path — a `tbreak` with a condition that hasn't
fired yet must not delete itself, which falls out of this ordering
automatically.

### New commands (`wdbg_command_loop`)

```
condition <n> [<expr>]   set/clear breakpoint n's condition (no expr clears)
ignore <n> <count>       set breakpoint n's ignore count (0 clears)
log <target> <expr>      like 'break', but the new slot is a logpoint:
                          evaluates <expr> and auto-continues on every hit
```

`log` reuses `bp_resolve_target` exactly like `break`/`tbreak` (same
`function | line | file:line` grammar), then calls a `bp_add`-like
constructor that also sets `bp_log_exprs[slot]`. `condition`/`ignore`
apply to any slot number as shown by `i b`, whether it was created by
`break`, `tbreak`, or `log`, so a conditional logpoint is just
`log foo x` followed by `condition <n> x > 10` — no combined syntax to
parse.

`dbg_log_report(bp, addr, esp)` prints one line:

```
logpoint <n> hit <hits>: <expr> = <value>
```

reusing `dbg_print_int_value`-style formatting already used by `print`
and watchpoints, so it looks and greps like the rest of `wdbg`'s output.

### `info breakpoints` / hit announcement

`bp_describe` (used by both `i b` and the "hit ..." line) grows optional
trailing fields, only present when set, so existing output for plain
breakpoints is byte-for-byte unchanged (no fixture churn for the 31
existing `debug_test` assertions):

```
breakpoint 2 at add (file.w:9)
breakpoint 3 at add (file.w:9), condition: x > 10, hits: 4, ignore: 2
logpoint 4 at add (file.w:9)
```

### Help text / docs

Update `dbg_help()`'s inline text, the `wdbg.w` header comment, and
`docs/debugging.txt`'s breakpoints section and "Future" list (move
hardware watchpoints and the web UI debugger out to the split-off issues;
mark conditional breakpoints/hit counts/logpoints as landed once merged).

## AI-tooling considerations

Another agent is separately extending the AI/LSP tooling surface
(`w check --json`, `wtest`, `wmcp`, `wlsp`); this feature stays entirely
inside `wdbg`'s existing stdin/stdout text protocol rather than adding a
parallel structured channel, consistent with the standing decision in
`docs/projects/ai_tooling_next_steps.md` ("`w-debug-mcp` / DAP... remains
deferred until an agent workflow actually needs programmatic stepping").
What *is* worth optimizing now, cheaply, since it costs nothing extra to
get right the first time:

- **One event, one line, always.** Every new event type (`logpoint N hit
  H: expr = value`, the extended `bp_describe` fields) is a single
  grep-able line with a stable prefix, matching the existing convention
  (`breakpoint hit at eip=`, `watchpoint N: ... changed: old -> new`).
  This is what makes a session like
  `printf 'log loop_body i\nc\n...\n' | ./bin/wdbg file.w | grep "^logpoint"`
  usable by an agent without any parsing beyond line-splitting.
- **Hit counts ride along for free.** Because `bp_hit_counts` is tracked
  regardless of condition/logpoint status, `i b` alone answers "how many
  times did we reach this line" without needing a logpoint at all — a
  common agent question ("is this loop even running?") that previously
  needed a manual counter variable in source.
- **No stop-per-iteration tax.** Logpoints are the direct fix for the
  scripting pattern `.cursor/skills/w-debug-wdbg/SKILL.md` already
  recommends over print-statement sprinkling: today that skill can only
  offer `watch` (slow, single-steps everything) or repeated `break`/`c`
  for anything that needs more than one stop. A logpoint auto-continues
  in the debuggee's normal (non-single-stepped) execution mode between
  hits, so it stays cheap over a long-running loop.
- **Keep the skill in sync.** Once this lands, add a `condition`/`log`
  example to `.cursor/skills/w-debug-wdbg/SKILL.md`'s "Scripting pattern"
  section, and append a one-line pointer in
  `docs/projects/ai_tooling_next_steps.md` under "MCP / LSP / cloud" so
  whoever eventually builds a structured `w-debug-mcp` wrapper knows these
  new line formats exist and are stable to key off. Land this as part of
  the same PR that lands the feature, not a follow-up, to avoid the two
  in-flight efforts (this and the AI/LSP tooling work) drifting apart.

No changes are needed to `w check`, `symbols --json`, `wlsp`, or `wmcp` —
this is purely a `wdbg` command-surface addition.

## Testing plan

Extend `tests/debug_fixture.w` / `tests/debug_fixture2.w` (or add a
`tests/debug_fixture3.w` with a small counting loop, since the existing
fixtures are straight-line/one-call shaped) with a loop whose body a
condition/ignore/logpoint can target, then add `debug_test` (and
`debug_test_x64`) Makefile assertions in the same `grep -q`/`grep -qE`
style as the existing 31:

- `condition <n> <expr>` stops only on the iteration where `<expr>` is
  true (assert the reported local's value at the stop).
- an unconditional breakpoint's `hits:` field increments across repeated
  `c`, matching the number of loop iterations run.
- `ignore <n> <count>` skips exactly `count` eligible hits before
  stopping.
- `condition` on a `tbreak` does not delete the temp breakpoint on a
  skipped (condition-false) hit, only on the eventual real stop.
- `log <target> <expr>` prints one `logpoint ...` line per iteration and
  never enters the command loop (the debuggee runs to completion on a
  single `c` piped after setting the logpoint, rather than needing one
  `c` per iteration) — mirrors the "end of input on stdin continues
  execution" property already relied on elsewhere in `debug_test`.
- a combined `log` + `condition` only logs on eligible hits.
- a condition compile error stops (fail-closed) and reports the error
  instead of silently continuing.

Both x86 (`debug_test`) and x64 (`debug_test_x64`) get the same
assertions since this logic lives in the arch-independent command loop
and trap handler, not `debugger/sigcontext.w`.

## Rollout sequence

1. `debugger/breakpoints.w`: add the three new arrays, extend
   `bp_add`/`bp_delete`/`bp_delete_all`/`bp_describe`.
2. `debugger/eval.w`: add `dbg_eval_call`.
3. `debugger/wdbg.w`: gate the breakpoint-hit path in `wdbg_trap`, add
   `condition`/`ignore`/`log` to `wdbg_command_loop` and `dbg_help()`,
   update the file header comment.
4. New fixture(s) + `debug_test`/`debug_test_x64` assertions.
5. Docs: `docs/debugging.txt`, `.cursor/skills/w-debug-wdbg/SKILL.md`,
   `docs/projects/ai_tooling_next_steps.md` (one-line pointer),
   `docs/todo.txt` (move this out of "next priorities" once merged).
6. `make verify` (breakpoints.w/eval.w/wdbg.w are outside the seed's
   compiled set — `debugger/` is not in the seed-constrained list in
   `CLAUDE.md` — so no seed-promotion concerns; `make tests` is the gate).

## Implementation notes

- **Functions must be defined before use within a file.** `wdbg.w` is
  compiled single-pass; a `dbg_eval_call` defined textually after its
  first caller failed with `Cannot find symbol`. `debugger/eval.w`
  defines `dbg_eval_call` before `dbg_eval` (which now calls it) for this
  reason — same convention the rest of the file already follows (every
  helper is defined before its call site).
- **`|` is bitwise-or, not short-circuiting `||`.** A first draft of
  `bp_set_condition(i, expr)` guarded with
  `if ((expr == 0) | (expr[0] == 0))`; both operands evaluate regardless
  of the first, so `expr[0]` dereferenced a null pointer whenever
  `bp_delete` called it with `expr = 0` to clear a condition — a real
  SIGSEGV crash on every `tbreak`+`condition` combination that reached
  its actual stop (caught by the manual `tbreak`+`condition` scenario
  below before it reached a committed test). Fixed with two sequential
  `if`s so the null case returns before the dereference. Worth flagging
  for future `debugger/` changes: any guard shaped like
  `(ptr == 0) | (ptr[0] == ...)` is a latent null-deref, not a safe
  short-circuit.
- **Sequencing commands against the initial `debugger` trap.** Every
  fixture used here starts with a `debugger` statement, so the *first*
  command read from stdin resumes past that initial stop. Breakpoints,
  conditions, ignore counts and logpoints must be set *before* that
  first `c` — setting them after does nothing, since the debuggee will
  have already run to completion by the time they'd be read. This isn't
  a code change, but it tripped up hand-writing the manual verification
  sequences and is worth calling out for anyone scripting `wdbg` for the
  first time.
