# Debugger: Attach to a Running Process (out-of-process ptrace mode)

Status: **partially implemented** — read-only inspection and execution
control landed (`debugger/attach.w`, `wdbg --attach <pid> [file.w]`, tests
in `tools/attach_test.sh` / the `attach_test` build target). Phase 2's
target-access seam is now complete for both memory (`debugger/memory.w`)
and registers (`debugger/registers.w`); phase 5's locals/args/frame
selection and phase 3's x86-64 symbolization have landed on top of it (see
"Implemented" below). Expression evaluation and hardware watchpoints in
attach mode are not yet wired; see "Remaining" below.

Tracks [reardan/w#123](https://github.com/reardan/w/issues/123). This is
the "out-of-process ptrace mode" design doc that
`debugger_conditional_breakpoints.md` ("Split off") deferred; hardware
watchpoints land here as a late phase because they need this
architecture.

## Implemented

`wdbg --attach <pid> [file.w]` (`debugger/attach.w`) is a self-contained
ptrace command loop, kept entirely separate from wdbg's in-process signal
model so it cannot perturb self-hosting (`./wbuild verify` stays
byte-identical). What works today:

- **Attach / detach / kill.** Attaches with `PTRACE_ATTACH`, stops the
  process, and on `detach`/`quit` restores any patched bytes and lets it
  continue; `kill` terminates it. EPERM/ESRCH are reported clearly.
- **Registers, memory, stack.** `r`, `x <addr> [count]`, `st` via
  `PTRACE_GETREGS` and `PTRACE_PEEKDATA`.
- **Symbolization** (`file.w` given, x86 and x86-64). The source is
  recompiled through the same ELF backend that built the on-disk binary
  (`wdbg_attach_compile` → `link_impl`), so `code_offset` is the load base
  and the symbol/line tables hold the target's real addresses — no delta.
  `wdbg_attach_compile` recompiles for whichever word size the running
  debugger binary itself was built for (passing the `"x64"` target
  selector when `__word_size__ == 8`, exactly like the in-process path's
  `word_size = __word_size__`), so `bin/wdbg64` symbolizes 64-bit attach
  targets and `bin/wdbg` symbolizes 32-bit ones — there is no cross-size
  attach. Calibration (`at_calibrate`) reads `/proc/<pid>/exe` and compares
  it byte-for-byte against the recompiled image (`code[0..codepos)`, the
  exact bytes the ELF backend would write to disk); any short read, open
  failure, or byte mismatch prints a clear diagnostic and falls back to raw
  mode instead of trusting stale tables. Enables `l`/`where`, `list` (a
  multi-line source window around the stopped line or an explicit line
  number), `bt` (a frame list built from the call-site-decode heuristic,
  not just the current ip), `f`/`frame [n]`/`up`/`down` (frame selection),
  `i functions`/`i files`/`i locals`/`i args`, `p`/`print <name>` and
  `set <name> <value>` (locals, args or globals by name — attach mode has
  no general expression compiler yet), and symbol/`file:line` break
  targets — all gated off in raw mode the same way `i functions` already
  was.
- **Breakpoints and execution control.** `b <function | file:line | 0xADDR>`,
  `d`/`delete`, `i b`/`i breakpoints` (list) via `PTRACE_POKEDATA` int3
  patching (original byte saved per slot) and a `wait4` stop loop.
  `c`/`continue` (`PTRACE_CONT`) and `si`/`stepi` (`PTRACE_SINGLESTEP`) use
  the disarm / single-step / re-arm dance around a breakpoint at the
  current pc; a non-`SIGTRAP` stop is held as `attach_pending_sig` and
  redelivered on the next resume (`PTRACE_CONT`/`SINGLESTEP` with the
  signal), matching gdb's default forwarding. `s`/`step` and `n`/`next`
  (#123 phase 4's remainder) drive the same `PTRACE_SINGLESTEP`+`wait4`
  loop instruction-by-instruction, checking the stop condition after each
  one (`at_step_should_stop`) exactly like `debugger/wdbg.w`'s in-process
  `dbg_step_should_stop`: `s` stops at the next statement boundary
  anywhere, `n` only at one at the same-or-shallower frame (esp compared
  against the frame base recorded when stepping started), so `n` glides
  straight through a call instead of stopping inside it. An armed
  breakpoint hit mid-step (rare: one inside the range `n` steps over)
  interrupts the step and reports it like a normal `continue`. `fin`/
  `finish` runs to the *current* (innermost) frame's return address — read
  from the frame walk's caller entry, one temporary `PTRACE_POKETEXT`
  breakpoint (reusing an already-set user breakpoint at the same address
  instead of duplicating it) — then reports `value returned = ` (eax/rax)
  and glides to the next statement boundary the same way `s` does, since
  landing exactly at the return address is usually mid-statement (the
  caller may still store the result). A recursive call returning to the
  same call site before the frame `fin` started in has actually unwound
  (checked by comparing sp against the sp recorded when `fin` began) is
  silently resumed rather than reported early. `detach`/`q` disarms (byte
  writeback via `PTRACE_POKEDATA`) every breakpoint before `PTRACE_DETACH`,
  including one at the current pc if the target is stopped there, so the
  target resumes with every instruction back to its original bytes; target
  exit mid-session (from `continue`/step commands or between prompts) is
  reported cleanly via the `wait4` status rather than assumed.

Design history: phase 1 initially shipped attach mode as a parallel
implementation rather than threading a shared in-process/ptrace seam
through the seed-compiled memory and register modules, to keep the
invasive, self-host-risky refactor out of the core while delivering the
same capability. Phase 2 has since built that seam for both halves:

- **Memory-access seam** (`debugger/memory.w`). `dbg_mem_readable`,
  `dbg_mem_read`/`dbg_mem_read_word` and `dbg_mem_write_word` dispatch
  through a registered reader/writer/prober triple — the same
  function-pointer convention `debugger/disas.w`'s `dbg_disas_read_fn`
  already used for instruction bytes. `dbg_memory_init()` installs the
  in-process (direct load/store, mincore-probed) triple by default, so
  every existing in-process caller (`debugger/wdbg.w`, `locals.w`,
  `watchpoints.w`) is byte-identical in behavior with no seam awareness
  needed. `debugger/attach.w` installs its own ptrace-backed triple
  (`at_mem_readable`/`at_mem_read`/`at_mem_write`, thin wrappers around the
  existing `PTRACE_PEEKDATA`/`PTRACE_POKEDATA`-based `at_read_word`/
  `at_write_word` — no new ptrace semantics) and routes `at_examine` (the
  `x`/`st` commands) and `at_set_command` (`set`) through the shared entry
  points instead of calling `at_read_word`/`at_write_word` directly, so
  `attach_test.sh`'s cases exercise the ptrace side of the same seam the
  in-process debugger uses. Breakpoint byte-patching
  (`debugger/breakpoints.w`) and eval's in-process locals-binding copy
  (`debugger/eval.w`'s `dbg_eval_copy`) are deliberately untouched: they
  are execution-control (phase 4) and eval (phase 6) concerns, not memory
  inspection.
- **Register seam** (`debugger/registers.w`). `dbg_reg_pc`/`dbg_reg_sp`
  dispatch through a registered pair of zero-argument readers, the same
  convention as the memory seam. The in-process backend reads
  `dbg_reg_context`, a plain global that `debugger/wdbg.w`'s `wdbg_trap`/
  `wdbg_fatal` set to the trapped sigcontext pointer once per stop (mirrors
  — does not replace — the explicit `context` parameter those functions
  already thread through the rest of their own call chain, so every
  existing in-process call site is unchanged and `debug_test`/
  `debug_test_x64` stay green with no behavior difference). `attach.w`
  installs its own pair (`dbg_reg_pc_attach`/`dbg_reg_sp_attach`, thin
  wrappers around the existing `PTRACE_GETREGS`-based `at_getregs`/
  `at_reg` — again no new ptrace semantics) and routes frame walking,
  breakpoint/continue/step's "current pc" lookups and `disas`/`list`/`l`
  through the shared entry points instead of calling `at_getregs`/`at_reg`
  directly.
- **Frame walking and locals through the seam** (phase 5,
  `debugger/attach.w`). `at_frames_compute` rebuilds attach mode's own
  frame list (pc + frame base per entry, mirroring `debugger/wdbg.w`'s
  in-process `dbg_fr_*` shape) on top of the two seams: the register seam
  for the trapped sp, the memory seam to walk the stack, and a small
  call-site-decode heuristic (`at_looks_like_return`, reading through
  `debugger/disas.w`'s byte-reader seam via the new `dbg_disas_read_byte`
  wrapper) to recognize return addresses — the same shape wdbg.w's
  in-process `dbg_looks_like_return` uses, minus the one in-process-only
  special case (main's caller there points into wdbg's own image, a
  different process's address space with no attach-mode equivalent; in
  attach mode main is called from the debuggee's own entry stub, so the
  walk just stops once it reaches main). `debugger/locals.w`'s stack-slot
  arithmetic (`dbg_frame_compute`, `dbg_local_runtime_addr`,
  `dbg_print_frame_vars`, …) needed no changes at all: it already takes a
  plain pc/esp pair and reads through `dbg_mem_*`, so supplying those two
  values for attach mode's selected frame (`at_sel_pc`/`at_sel_esp`) was
  enough to light up `i locals`/`i args`/`p`/`set`/`f`/`up`/`down`
  unmodified. wdbg.w's own in-process frame walker is untouched (zero
  behavior-change risk); the two implementations share the *seam idiom*,
  not one literal module, which is why `debugger/locals.w` needed no
  attach-awareness to begin with.

## Remaining

- **Expression evaluation** (`p <expr>` beyond a name lookup): reads
  through ptrace; in-target calls stay out of scope.
- **Hardware watchpoints** via `PTRACE_POKEUSER` on DR0–DR7.
- **Dynamic/PIE symbolization**: out of scope (see "Scope" below); raw
  mode works regardless.

## Motivation

`wdbg` cannot attach to an already-running process, and its architecture
is why: it is an in-process debugger (`debugger/wdbg.w`). It compiles the
target into an executable mmap buffer, calls the debuggee's `main()`
inside its own process, and does all execution control from signal
handlers — `int3` lands in `wdbg_trap`, stepping sets the trap flag in
the signal frame's eflags. That model is simple and fast, but it means
the debugger only exists for processes that were *started* under it.

The cases attach unlocks:

- **A W program is hung or spinning right now.** Today the only move is
  to kill it and hope the hang reproduces under `wdbg` from `main()`.
  Attach + `bt` + `i locals` answers "where is it stuck" in seconds.
- **A bug that takes minutes of run-time or external input to reach.**
  Restarting under the debugger loses the state; attaching keeps it.
- **Unplanned inspection.** Post-mortem via fatal-signal trapping only
  works if the process was launched by `wdbg`; attach removes that
  requirement for live processes.
- **Hardware watchpoints.** DR0-DR7 watchpoints need a supervising
  second process (`debugger/watchpoints.w` notes this; in-process code
  cannot usefully set its own debug registers). Today's software
  watchpoints single-step the whole program statement-by-statement — a
  large, sometimes prohibitive slowdown. The ptrace plumbing built here
  is exactly what hardware watchpoints need.

## What assumes "same address space" today

Every layer of `debugger/` bakes in the in-process model. The design
below is mostly about giving each one a seam.

| Layer | Today | Attach needs |
| --- | --- | --- |
| memory (`debugger/memory.w`) | **done (phase 2):** `dbg_mem_readable`/`dbg_mem_read`/`dbg_mem_write_word` dispatch through a registered triple, mincore-probed direct loads/stores by default | **done:** attach installs a `PTRACE_PEEKDATA`/`POKEDATA`-backed triple (peek's errno ambiguity replaces the probe trick); wired for `at_examine` and `set` alike |
| registers (`debugger/registers.w`, `debugger/sigcontext.w`) | **done (phase 2):** `dbg_reg_pc`/`dbg_reg_sp` dispatch through a registered pair, backed in-process by `dbg_reg_context` (mirrors the explicit sigcontext parameter `wdbg.w` already threads) | **done:** attach installs a `PTRACE_GETREGS`-backed pair (`at_getregs`/`at_reg`, already used standalone by raw-mode commands, now also the seam's backend) |
| execution control | return-from-handler with TF set; re-armed int3 bytes | `PTRACE_CONT` / `PTRACE_SINGLESTEP` + a `wait4` stop loop — **done** (phase 1/4, `debugger/attach.w`'s `at_continue`/`at_step`/`at_step_line_mode`/`at_finish`) |
| symbols/lines/stack slots (`debugger/symbols.w`, `debugger/lines.w`) | live compiler tables from the just-finished in-process compile; `debug_line_stack_pos` is **never emitted into the ELF** (`code_generator/dwarf.w`) | **done:** regenerated by recompiling the same source, now word-size-matched (phase 3) |
| frames/locals (`debugger/locals.w`) | `dbg_frame_compute`/`dbg_local_runtime_addr`/`dbg_print_frame_vars` take a plain pc/esp pair, needing no seam awareness of their own | **done (phase 5):** attach's `at_frames_compute`/`at_sel_pc`/`at_sel_esp` supply that pair from the register + memory seams for any selected frame |
| eval (`debugger/eval.w`) | compiles an expression and runs it in-process against debuggee globals | name lookups only (`p`/`set`) are wired through the seams; general expression evaluation is still out of scope (phase 6) |

One thing does **not** need work: address translation. wdbg already
works in debuggee-relative addresses (`rel = absolute - code_offset`)
everywhere. W's Linux binaries are statically linked `ET_EXEC` ELFs
loaded at a fixed base (`base_code_offset = 0x08048000` in
`code_generator/elf_32.w`; the x64 equivalent likewise) with no ASLR, so
attach mode simply sets `code_offset` to the ELF base and the entire
line/symbol layer works unchanged.

## Symbols without the in-process compile

The compiler tables (symbol table, `debug_line_*` arrays including
`stack_pos`) cannot be recovered from the target binary: only
`.debug_line`/`.debug_info` go into the ELF, and locals addressing and
unwinding need `stack_pos`, which deliberately stays in memory.

Plan (**implemented**): **recompile the same source inside wdbg** to
regenerate the tables, without executing the result.

    wdbg --attach <pid> file.w

- `./wbuild verify`'s byte-equality fixpoint is what makes this
  trustworthy: the same compiler over the same source produces identical
  code, so table addresses match the running text exactly.
- Validate rather than hope: `at_calibrate` reads `/proc/<pid>/exe` and
  compares it byte-for-byte against the recompiled code buffer, then
  refuses source-level commands on mismatch — stale source or a different
  compiler version must degrade to raw-address mode (registers, memory,
  raw stack still work), not silently lie. (An earlier version of this
  check only compared the first 32 bytes — the shared runtime entry stub,
  identical across nearly every W binary — which never actually caught a
  source mismatch; comparing the full image against `/proc/<pid>/exe`
  fixed that, and `tools/attach_test.sh`'s "mismatched source" cases guard
  against the regression.)
- `--attach <pid>` without a source file is legal and gives raw-address
  mode only.

A W-specific ELF section carrying `stack_pos` (so attach works from the
binary alone) is a possible follow-up, deliberately out of scope: it
grows every shipped binary to serve only this feature, and the
recompile path is strictly more capable (it also restores the symbol
table and eval's type information).

## Scope

In: x86 and x86-64 statically linked Linux ELF targets — the primary
backends — attached on the same machine, single-threaded debuggees
(everything W produces today).

Out (initially): `elf_dynamic`/PIE targets, arm64 / darwin / win64,
in-target function calls from `print`, attach over the network, and
multi-process/multi-thread control.

## Phases

Each phase is independently landable and gated by `./wbuild verify` —
`debugger/` is imported by `w.w` (for `--debug`), so it is seed-compiled
and must not use syntax newer than the seed.

1. **Syscall plumbing + read-only attach.** Add `ptrace` (i386: 26,
   x86-64: 101) and `kill` wrappers to `lib/__arch__/{x86,x64}/syscalls.w`
   (`fork`, `wait4`, `rt_sigaction` already exist). New
   `debugger/attach.w`: `PTRACE_ATTACH`, `wait4` for the stop,
   `PTRACE_GETREGS`, peek-based memory reads; wire `--attach <pid>` into
   `wdbg_main` argument parsing. Deliverable: attach to a spinning
   process, `r`, `x`, `st`, `detach` — raw addresses only.
2. **Target-access seam — done (memory and registers).** Read/write
   dispatch (in-process direct vs. ptrace) routes every debuggee memory
   access in `debugger/memory.w`, `wdbg.w`, `locals.w` and `watchpoints.w`
   through `dbg_mem_readable`/`dbg_mem_read`/`dbg_mem_write_word`, with
   `debugger/attach.w` installing its `PTRACE_PEEKDATA`/`POKEDATA`-backed
   triple and routing `at_examine`/`set` through it. The register half
   (`debugger/registers.w`) dispatches `dbg_reg_pc`/`dbg_reg_sp` the same
   way: in-process reads a `dbg_reg_context` global that `wdbg.w`'s
   `wdbg_trap`/`wdbg_fatal` set once per stop (additively — the explicit
   `context` parameter those functions already thread through the rest of
   their call chain is unchanged), while attach installs a
   `PTRACE_GETREGS`-backed pair. No behavior change for the in-process path
   (`./wbuild verify` and `verify_x64` stay green; `debug_test`/
   `debug_test_x64`/`wdbg`/`repl_test`(`_x64`) and `attach_test` all pass
   unchanged).
3. **Symbol/line recovery — done, both word sizes.** The recompile-and-
   validate scheme above, extended so `wdbg_attach_compile` passes the
   `"x64"` target selector when the running debugger binary is 64-bit
   (`__word_size__ == 8`) — attach symbolization no longer silently
   compiles a 32-bit table set for a 64-bit target and failing calibration
   by byte-mismatch. Deliverable: `bt`, `l`, `list`, `i functions|files`
   against a live process, for both `bin/wdbg` and `bin/wdbg64`.
4. **Execution control — done.** Breakpoints as `PTRACE_POKETEXT` int3
   patches (same original-byte bookkeeping as `debugger/breakpoints.w`);
   the stop loop is `wait4`-driven with `PTRACE_CONT`/`SINGLESTEP` instead
   of return-from-handler; `c`/`si` work above the seam (conditional
   breakpoints/logpoints are an in-process-only feature, not yet ported to
   attach mode). `s`/`n` add source-line stepping on top of the same
   `PTRACE_SINGLESTEP` loop (mirroring `wdbg.w`'s `dbg_step_should_stop`
   frame-base arithmetic instead of a new algorithm), and `fin` adds a
   temporary breakpoint at the current frame's return address (read off
   the phase-5 frame walk) for a `continue`-speed "run to caller" instead
   of single-stepping the whole callee. Non-`SIGTRAP` stops are held
   pending and redelivered on the next resume, matching gdb's signal
   forwarding. `q`/`detach` restores every patched byte before
   `PTRACE_DETACH`, including one at the current pc if stopped there;
   target exit mid-session is reported cleanly via the `wait4` status.
5. **Locals, frames — done; hardware watchpoints remaining.** `i
   locals|args`, `p`, `set` and frame selection (`f`/`up`/`down`) go
   through the register + memory seams (`debugger/attach.w`'s
   `at_frames_compute`/`at_sel_pc`/`at_sel_esp`), reusing
   `debugger/locals.w`'s stack-slot arithmetic unmodified. Hardware
   watchpoints via `PTRACE_POKEUSER` on DR0-DR7 (4 max; fall back to the
   software scan beyond that) are still open — closes the split-off item
   from `debugger_conditional_breakpoints.md` once landed.
6. **Eval, restricted.** `p <expr>`/`set <expr>` currently resolve a
   local/arg/global by name only (`debugger/attach.w`'s `at_print_command`/
   `at_set_command`); a general expression compiler where variable/global
   loads go through the seam, with in-target calls rejected, is still
   open. gdb-style inferior calls are a separate future project.

## Testing

- Per repo convention: `tests/attach_test.w` (drives `wdbg --attach`
  against a spawned looping fixture via `lib/process.w`), a `build.json`
  target, membership in the `tests` umbrella, and a `tools/test_map.w`
  entry. Reuse the piped-stdin command-script style of the existing
  `debug_test` targets.
- Fixture: a small W program that increments a global in a loop, so the
  test can attach, read the global twice, and assert it advanced —
  proving both attach and memory reads without timing races.
  `tests/attach_target_fixture.w`'s loop body is a two-level call
  (`slow_step` calling `bump`, each with its own argument and local), so
  the same fixture also exercises frame selection and locals/args through
  the seam (**done**): breaking in `bump` and running `i a`/`p n`/`up`/
  `p n` again proves both frame 0's and the caller's argument resolve
  correctly, not just the innermost one.
- x86-64 attach (**done**): the same cases run again against `bin/wdbg64`
  attached to a 64-bit-compiled copy of the fixture
  (`bin/attach_target64`), so symbolization, register dumps and
  locals/frames are all verified for both word sizes, not just x86.
- Mismatch path (**done**): `tools/attach_test.sh`'s "mismatched source"
  cases attach with a different, unrelated source file (`tests/debug_fixture.w`
  against the running `attach_target` fixture) and assert both the
  degradation diagnostic and the raw-mode fallback banner — the shell
  harness's `grep -qF` is the freeze on that text, same convention as the
  rest of the suite.
- Execution control (**done**, phase 4): `next` steps over `bump` from
  `slow_step`'s call-site line and lands on `slow_step`'s own following
  statement; `step` from the same line lands inside `bump` instead;
  `finish` from inside `bump` reports the returned value and glides to
  the caller's next statement. All three reuse `attach_target_fixture.w`
  (no new fixture needed — a step/next/finish test only needs process
  control, not a fresh program shape). x64 twins run the same `next`/
  `step`/`finish` cases against `bin/wdbg64`.
- Detach truly restores patched bytes (**done**): every other case above
  kills the fixture with `-9` after detaching, which would never notice a
  leftover `int3` byte (the process is gone either way). A dedicated
  fixture, `tests/attach_finite_fixture.w`, loops a small, fixed number of
  times (`sleep_ms` between iterations so it reliably outlives the
  harness's post-fork settle delay without a long test) and then exits on
  its own with a distinct final `println` and exit code. The test breaks
  at `bump`, continues to hit it once, detaches, and `wait`s for the real
  process (not `kill -9`) to finish, asserting both the final output and
  the exit code — a regression that skipped the byte restore would show up
  here as a crash or a signal-terminated exit instead of the clean one. x64
  twin included.
- Not covered end-to-end: recursion during `finish` (the fixture has no
  recursive call, so the "still-nested return to the same call site" path
  in `at_finish` is exercised by reasoning about the sp comparison, not by
  a test); `finish`/`up`/`bt` beyond two live frames, since
  `at_frames_compute`'s call-site-decode heuristic does not reliably find
  a third frame from this fixture's shape (`slow_step`'s own caller,
  `main`) — `fin`/`up` correctly refuse ("no caller frame") rather than
  guess when the walk comes up short, but that also means they cannot be
  demonstrated past two frames with the current fixture.
- Linux-only (ssh host `w` from the Mac checkout); `ptrace` under
  containers may need `CAP_SYS_PTRACE` / `ptrace_scope` — the test
  should spawn the debuggee as a child of the test process so
  `YAMA ptrace_scope=1` still permits it.

## Risks

- **Seed constraint.** All new `debugger/` code is seed-compiled; no
  post-seed syntax until an `update` promotes one.
- **Recompile mismatch.** Handled by validating text bytes and degrading
  loudly (see above); never trust tables that don't match the target.
- **Peek/poke errno ambiguity.** `PTRACE_PEEKDATA` returns the word in
  the return value, so -1 is ambiguous; the wrapper must clear/check
  errno explicitly — this replaces `memory.w`'s `/dev/null` probing on
  the remote path.
- **Stop-loop/int3 semantics differ subtly from the signal-frame model**
  (eip already past the int3 on x86 stops, re-arm ordering). Phase 4
  re-derives the re-arm dance for ptrace rather than assuming the
  in-process sequencing transfers.
