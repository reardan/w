---
name: w-debug-wdbg
description: Debug a W program at runtime with the in-process debugger wdbg, scripted over stdin. Use when a W program crashes (SIGSEGV etc.), returns wrong values, or when you would otherwise add print statements to inspect state.
---

# Debugging W programs with wdbg

`wdbg` compiles and runs a program in-process, trapping on `debugger`
statements, patched breakpoints, and fatal signals into a gdb-flavored
command loop. It is fully scriptable over stdin — no interactive terminal
needed (this is exactly how the `debug_test` target drives it).

## Setup

```sh
./wbuild wdbg                    # builds bin/wdbg
./bin/wdbg file.w [args...]      # or: ./bin/wv2 --debug file.w
```

Put a `debugger` statement in the source where you want to stop, or set
breakpoints from the command loop (`break function`, `break file:line`,
`tbreak` for one-shot).

## Scripting pattern

Pipe commands; each stop consumes the next lines; `c` continues:

```sh
printf 'backtrace\ninfo locals\nprint some_var\nc\n' | ./bin/wdbg file.w
printf 'break my_function\nc\nprint x + y*2\nc\n' | ./bin/wdbg file.w
```

A crash (SIGSEGV and friends) drops into the same loop for post-mortem
inspection — run `backtrace`, `info locals`, `x`, `registers` there.

For a bug that only reproduces after many iterations, or to watch a
value's trajectory across a whole run, prefer a conditional breakpoint or
a logpoint over stepping/printing by hand:

```sh
# stop only on the iteration where the condition is true
printf 'break file.w:42\ncondition 1 i == 4301\nc\nprint x\nc\n' | ./bin/wdbg file.w

# log a value on every hit and auto-continue (no stop-per-iteration cost);
# runs to completion on a single 'c'
printf 'log file.w:42 x\nc\n' | ./bin/wdbg file.w

# skip the first N hits, or combine a logpoint with a condition
printf 'break file.w:42\nignore 1 100\nc\n' | ./bin/wdbg file.w
printf 'log file.w:42 x\ncondition 1 x < 0\nc\n' | ./bin/wdbg file.w
```

## Command reference (see docs/debugging.txt)

- Stepping: `step` / `next` / `stepi` / `finish`, `c` (continue)
- Breakpoints: `break function|line|file:line`, `tbreak`, `delete`
- Conditions/logpoints: `condition <n> [<expr>]`, `ignore <n> <count>`,
  `log <target> <expr>` (auto-continues; combine with `condition`)
- State: `print <name or any W expression>` (compiled on the fly),
  `set var value`, `x addr`, `backtrace`, `list`,
  `info locals|args|globals|breakpoints`, `registers`, `stack` (`st`)

Prefer a scripted wdbg session over sprinkling temporary print calls:
it needs no source edits, so there is nothing to revert afterwards.
