# Debugger: Attach to a Running Process (out-of-process ptrace mode)

Status: **partially implemented** — read-only inspection and execution
control landed (`debugger/attach.w`, `wdbg --attach <pid> [file.w]`, tests
in `tools/attach_test.sh` / the `attach_test` build target), and phase 2's
memory-access seam has landed (`debugger/memory.w`; see "Implemented"
below) with the register seam still deferred. Locals/args inspection,
expression evaluation and hardware watchpoints in attach mode are not yet
wired; see "Implemented" and "Remaining" below.

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
- **Symbolization** (`file.w` given, x86 32-bit). The source is recompiled
  through the same ELF backend that built the on-disk binary
  (`wdbg_attach_compile` → `link_impl`), so `code_offset` is the load base
  and the symbol/line tables hold the target's real addresses — no delta.
  Calibration (`at_calibrate`) reads `/proc/<pid>/exe` and compares it
  byte-for-byte against the recompiled image (`code[0..codepos)`, the exact
  bytes the ELF backend would write to disk); any short read, open failure,
  or byte mismatch prints a clear diagnostic and falls back to raw mode
  instead of trusting stale tables. Enables `l`/`where`, `list` (a
  multi-line source window around the stopped line or an explicit line
  number), `bt` (a heuristic stack walk that names every frame it can
  resolve, not just the current ip), `i functions`/`i files`, and
  symbol/`file:line` break targets — all gated off in raw mode the same way
  `i functions` already was.
- **Breakpoints and stepping.** `b <function | file:line | 0xADDR>`, `d`,
  `c`, `si` via `PTRACE_POKEDATA` int3 patching and a `wait4` stop loop with
  the disarm / single-step / re-arm dance; `detach` restores original bytes.

Design history: phase 1 initially shipped attach mode as a parallel
implementation rather than threading a shared in-process/ptrace seam
through the seed-compiled memory and register modules, to keep the
invasive, self-host-risky refactor out of the core while delivering the
same capability. Phase 2 has since built that seam for the memory half:

- **Memory-access seam** (`debugger/memory.w`). `dbg_mem_readable`,
  `dbg_mem_read`/`dbg_mem_read_word` and `dbg_mem_write_word` dispatch
  through a registered reader/writer/prober triple — the same
  function-pointer convention `debugger/disas.w`'s `dbg_disas_read_fn`
  already used for instruction bytes. `dbg_memory_init()` installs the
  in-process (direct load/store, mincore-probed) triple by default, so
  every existing in-process caller (`debugger/wdbg.w`, `locals.w`,
  `watchpoints.w`) is byte-identical in behavior with no seam awareness
  needed. `debugger/attach.w` installs its own ptrace-backed triple
  (`at_mem_readable`/`at_mem_read`, thin wrappers around the existing
  `PTRACE_PEEKDATA`-based `at_read_word` — no new ptrace semantics) and
  routes `at_examine` (the `x`/`st` commands) through the shared entry
  points instead of calling `at_read_word` directly, so `attach_test.sh`'s
  "examine memory" case exercises the ptrace side of the same seam the
  in-process debugger uses. Breakpoint byte-patching
  (`debugger/breakpoints.w`) and eval's in-process locals-binding copy
  (`debugger/eval.w`'s `dbg_eval_copy`) are deliberately untouched: they
  are execution-control (phase 4) and eval (phase 6) concerns, not memory
  inspection.
- **Register seam: still deferred.** `debugger/sigcontext.w`'s `ctx_*`
  accessors take an explicit sigcontext pointer threaded through
  `debugger/wdbg.w`'s call chain, while attach mode reads an implicit
  global `user_regs_struct` (`attach_regs`, a different byte layout: e.g.
  `sigcontext_eax()` vs. `at_off_ip()`/the offsets in
  `at_print_registers`). Unifying the two needs either a global
  "current register buffer" convention in the in-process path or an
  explicit buffer parameter threaded through attach mode, both wider
  refactors than the memory seam; left for a follow-up once locals/eval
  reuse (phases 5-6) makes the register side worth it.

## Remaining

- **Locals / args / `set` / frames** in attach mode (original phase 5's
  variable side). The recompile already yields the `stack_pos` tables, so
  this is reading stack slots through ptrace and reusing `debugger/locals.w`
  arithmetic — the main open work item.
- **Expression evaluation** (`p <expr>`): reads through ptrace; in-target
  calls stay out of scope.
- **Hardware watchpoints** via `PTRACE_POKEUSER` on DR0–DR7.
- **x86-64 and dynamic/PIE symbolization**: today symbolization is x86
  (32-bit ELF) only; raw mode works regardless of word size.

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
| memory (`debugger/memory.w`) | **done (phase 2):** `dbg_mem_readable`/`dbg_mem_read`/`dbg_mem_write_word` dispatch through a registered triple, mincore-probed direct loads/stores by default | attach installs a `PTRACE_PEEKDATA`-backed triple (peek's errno ambiguity replaces the probe trick); wired for `at_examine`, not yet for `set`/watch in attach mode (no locals there yet) |
| registers (`debugger/sigcontext.w`) | offsets into the kernel signal frame, threaded via an explicit context parameter | **not yet seamed** (phase 2 remaining): `PTRACE_GETREGS` / `PTRACE_SETREGS` into a `user_regs_struct` buffer, already used standalone by `debugger/attach.w`'s own `at_reg`/`at_getregs` but not unified with `ctx_*` |
| execution control | return-from-handler with TF set; re-armed int3 bytes | `PTRACE_CONT` / `PTRACE_SINGLESTEP` + a `wait4` stop loop |
| symbols/lines/stack slots (`debugger/symbols.w`, `debugger/lines.w`) | live compiler tables from the just-finished in-process compile; `debug_line_stack_pos` is **never emitted into the ELF** (`code_generator/dwarf.w`) | regenerate the same tables by recompiling the same source (see below) |
| eval (`debugger/eval.w`) | compiles an expression and runs it in-process against debuggee globals | reads via ptrace; in-target calls are out of scope initially |

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
2. **Target-access seam — memory done, registers remaining.** Read/write
   dispatch (in-process direct vs. ptrace) now routes every debuggee
   memory access in `debugger/memory.w`, `wdbg.w`, `locals.w` and
   `watchpoints.w` through `dbg_mem_readable`/`dbg_mem_read`/
   `dbg_mem_write_word`, with `debugger/attach.w` installing its
   `PTRACE_PEEKDATA`-backed triple and routing `at_examine` through it.
   No behavior change for the in-process path (`./wbuild verify` and
   `verify_x64` stay green; `debug_test`/`debug_test_x64`/`wdbg`/
   `repl_test`(`_x64`) and `attach_test` all pass unchanged). The
   register half — dispatching `debugger/sigcontext.w`'s `ctx_*`
   accessors the same way — is still open: it needs either the
   in-process path to adopt a global "current register buffer"
   (today it threads an explicit sigcontext pointer through every call
   in `wdbg.w`) or attach mode to adopt an explicit buffer parameter
   (today it reads the implicit global `attach_regs`), and the two
   models use different byte layouts (sigcontext vs. `user_regs_struct`)
   for the same logical registers. Left for a follow-up.
3. **Symbol/line recovery.** The recompile-and-validate scheme above.
   Deliverable: `bt`, `l`, `list`, `i functions|files` against a live
   process.
4. **Execution control.** Breakpoints as `PTRACE_POKETEXT` int3 patches
   (same original-byte bookkeeping as `debugger/breakpoints.w`); the
   stop loop becomes `wait4`-driven with `PTRACE_CONT`/`SINGLESTEP`
   instead of return-from-handler; `c/s/n/si/fin` and conditional
   breakpoints/logpoints work unchanged above the seam. `q`/`detach`
   restores every patched byte before `PTRACE_DETACH`.
5. **Locals, frames, hardware watchpoints.** `i locals|args`, `p`,
   `set`, frame selection through the seam (stack_pos tables exist after
   phase 3). Hardware watchpoints via `PTRACE_POKEUSER` on DR0-DR7 (4
   max; fall back to the software scan beyond that) — closes the
   split-off item from `debugger_conditional_breakpoints.md`.
6. **Eval, restricted.** `p <expr>` where evaluation only needs reads:
   compile in wdbg as today, but variable/global loads go through the
   seam. Expressions that would *call* into the target are rejected
   with a clear diagnostic; gdb-style inferior calls are a separate
   future project.

## Testing

- Per repo convention: `tests/attach_test.w` (drives `wdbg --attach`
  against a spawned looping fixture via `lib/process.w`), a `build.json`
  target, membership in the `tests` umbrella, and a `tools/test_map.w`
  entry. Reuse the piped-stdin command-script style of the existing
  `debug_test` targets.
- Fixture: a small W program that increments a global in a loop, so the
  test can attach, read the global twice, and assert it advanced —
  proving both attach and memory reads without timing races.
- Mismatch path (**done**): `tools/attach_test.sh`'s "mismatched source"
  cases attach with a different, unrelated source file (`tests/debug_fixture.w`
  against the running `attach_target` fixture) and assert both the
  degradation diagnostic and the raw-mode fallback banner — the shell
  harness's `grep -qF` is the freeze on that text, same convention as the
  rest of the suite.
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
