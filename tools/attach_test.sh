#!/bin/sh
# End-to-end test for wdbg's --attach mode (debugger/attach.w).
#
# Attach mode controls a separate running process through ptrace, so it
# cannot be exercised by build.json's single-command steps like the other
# debugger tests; this driver launches the spinning fixture, attaches wdbg
# to it with a piped command script, and greps the output.
#
# The fixture (tests/attach_target_fixture.w) calls PR_SET_PTRACER_ANY, so a
# sibling tracer can attach even under YAMA ptrace_scope=1. Prerequisites,
# built by the attach_test target before this script runs: bin/wdbg and
# bin/attach_target.
set -e

WDBG=bin/wdbg
FIXTURE_BIN=bin/attach_target
FIXTURE_SRC=tests/attach_target_fixture.w
# Any other compilable source proves the calibration mismatch path: it
# builds cleanly but is not the program actually running.
WRONG_SRC=tests/debug_fixture.w
FAILED=0

# run_case <description> <wdbg-args-after-pid> <stdin> <expected-substring> [want_stderr]
# Launches a fresh fixture, attaches, and checks the output contains the
# expected substring. The fixture is always killed afterwards. wdbg's
# stderr is normally discarded (it only ever carries the "compiling '...'"
# progress banner here, which no case asserts on); pass any non-empty
# want_stderr to merge it in for cases that assert on a println2
# diagnostic (attach.w's fatal/mismatch messages).
run_case() {
	desc="$1"
	extra="$2"
	commands="$3"
	expect="$4"
	want_stderr="$5"

	"$FIXTURE_BIN" &
	pid=$!
	# Let the fixture reach its spin loop before attaching.
	sleep 0.4

	if [ -n "$want_stderr" ]; then
		out=$(printf '%b' "$commands" | "$WDBG" --attach "$pid" $extra 2>&1 || true)
	else
		out=$(printf '%b' "$commands" | "$WDBG" --attach "$pid" $extra 2>/dev/null || true)
	fi
	kill -9 "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true

	if printf '%s' "$out" | grep -qF "$expect"; then
		echo "ok: $desc"
	else
		echo "FAIL: $desc"
		echo "  expected substring: $expect"
		echo "  actual output:"
		printf '%s\n' "$out" | sed 's/^/    /'
		FAILED=1
	fi
}

# Symbolized mode: the current location resolves to the fixture's source.
run_case "symbolized location" "$FIXTURE_SRC" 'l\ndetach\n' "attach_target_fixture.w:"

# Symbolized mode: the attach banner reports symbols were loaded.
run_case "symbols loaded banner" "$FIXTURE_SRC" 'detach\n' "symbols loaded"

# Registers dump works against the stopped process.
run_case "registers" "$FIXTURE_SRC" 'r\ndetach\n' "eip: 0x"

# A breakpoint set by function name is hit after continue, and the
# disarm/step-over/re-arm dance lets it hit again on the next iteration.
run_case "breakpoint hit twice" "$FIXTURE_SRC" 'b slow_step\nc\nc\nkill\n' "hit breakpoint 1"

# Memory examine reads the target's ELF magic at the fixed load base.
run_case "examine memory" "$FIXTURE_SRC" 'x 0x8048000 1\ndetach\n' "0x464c457f"

# Raw mode (no source): attach still works, reporting no symbols.
run_case "raw mode banner" "" 'detach\n' "raw mode: no symbols"

# A backtrace in symbolized mode names the fixture's main frame.
run_case "backtrace names main" "$FIXTURE_SRC" 'bt\ndetach\n' "main ("

# A backtrace taken while stopped inside a callee names both frames: the
# callee at #0 and its caller (main) further up the stack, proving the
# heuristic frame walk -- not just the current-ip line -- resolves symbols.
run_case "backtrace names fixture functions" "$FIXTURE_SRC" 'b slow_step\nc\nbt\nkill\n' "main ("

# 'list' shows a multi-line source window (not just the single current
# line 'l' prints), centered on wherever the process is stopped -- always
# somewhere in main's loop body, so this line is always in range.
run_case "list shows source" "$FIXTURE_SRC" 'list\ndetach\n' "attach_counter = slow_step"

# 'i functions' lists the debuggee's defined functions by name.
run_case "i functions lists symbols" "$FIXTURE_SRC" 'i functions\ndetach\n' "slow_step"

# 'i files' lists the debuggee's known source files.
run_case "i files lists source file" "$FIXTURE_SRC" 'i files\ndetach\n' "attach_target_fixture.w"

# Attaching with a source file that does not match the running binary
# (tests/debug_fixture.w, a different program) must be caught by the
# recompile-vs-/proc/<pid>/exe comparison, not silently trusted: a clear
# diagnostic and a fall back to raw mode, never wrong symbol names.
run_case "mismatched source: clean diagnostic" "$WRONG_SRC" 'detach\n' "does not match this source" 1
run_case "mismatched source: raw fallback" "$WRONG_SRC" 'detach\n' "raw mode: no symbols"

# Disassembly of a named function in symbolized mode shows its header.
run_case "disassemble function" "$FIXTURE_SRC" 'disas slow_step\ndetach\n' "slow_step:"

# No-argument disassembly marks the stopped instruction.
run_case "disassembly marks ip" "$FIXTURE_SRC" 'disas\ndetach\n' "=> 0x"

# Single-stepping shows the surrounding instructions automatically.
run_case "step shows instructions" "$FIXTURE_SRC" 'si\ndetach\n' "=> 0x"

# Raw mode still disassembles from the stopped ip (PTRACE_PEEKDATA reads).
run_case "raw mode disassembly" "" 'disas\ndetach\n' "=> 0x"

# Raw mode has no symbol table: function targets point at the address form.
run_case "raw mode disas boundary" "" 'disas slow_step\ndetach\n' "no symbols: disassemble by address"

if [ "$FAILED" -eq 0 ]; then
	echo "attach test OK"
else
	echo "attach test FAILED"
	exit 1
fi
