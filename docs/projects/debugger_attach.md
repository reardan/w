# Debugger: Attach to a Running Process (out-of-process ptrace mode)

Status: **partially implemented** — read-only inspection and execution
control landed (`debugger/attach.w`, `wdbg --attach <pid> [file.w]`, tests
in `tools/attach_test.sh` / the `attach_test` build target). Locals/args
inspection, expression evaluation and hardware watchpoints in attach mode
are not yet wired; see "Implemented" and "Remaining" below.

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
  Calibration compares the compiled image's first bytes against the running
  process and falls back to raw mode on any mismatch. Enables `l`, `bt`,
  `list`-free source lines, `i functions`, and symbol/`file:line` break
  targets.
- **Breakpoints and stepping.** `b <function | file:line | 0xADDR>`, `d`,
  `c`, `si` via `PTRACE_POKEDATA` int3 patching and a `wait4` stop loop with
  the disarm / single-step / re-arm dance; `detach` restores original bytes.

Design choice: rather than thread a shared in-process/ptrace "seam" through
the seed-compiled memory and register modules (original phase 2), attach
mode is a parallel implementation. That keeps the invasive, self-host-risky
refactor out of the core while delivering the same capability; the seam can
still be pursued later if locals/eval reuse justifies it.

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
| memory (`debugger/memory.w`) | direct loads/stores; bad pointers probed via `/dev/null` writes | `PTRACE_PEEKDATA` / `PTRACE_POKEDATA` (peek's errno ambiguity replaces the probe trick) |
| registers (`debugger/sigcontext.w`) | offsets into the kernel signal frame | `PTRACE_GETREGS` / `PTRACE_SETREGS` into a `user_regs_struct` buffer |
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

Plan: **recompile the same source inside wdbg** to regenerate the
tables, without executing the result.

    wdbg --attach <pid> file.w

- `./wbuild verify`'s byte-equality fixpoint is what makes this
  trustworthy: the same compiler over the same source produces identical
  code, so table addresses match the running text exactly.
- Validate rather than hope: compare the recompiled code bytes against
  the target's text (read via ptrace, or against `/proc/<pid>/exe`) and
  refuse source-level commands on mismatch — stale source or a different
  compiler version must degrade to raw-address mode (registers, memory,
  raw stack still work), not silently lie.
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
2. **Target-access seam.** Introduce read/write-word and register
   accessor dispatch (in-process direct vs. ptrace) and route
   `debugger/memory.w` users and the sigcontext accessors through it.
   No behavior change for the in-process path; `verify` byte-identity
   plus the existing `debug_test`/`debug_test_x64` targets are the gate.
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
- Mismatch path: attach with deliberately edited source and assert the
  degradation-to-raw-mode diagnostic (frozen text — add to
  `warning_test`-style fixtures if worded as a diagnostic).
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
