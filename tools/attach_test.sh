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

# Locals/frames through the seam (#123 phase 5): 'bump' is called from
# 'slow_step', which is called from 'main', so a breakpoint in bump gives a
# real two-level call stack to inspect.

# Argument inspection at the innermost frame (frame 0): visible immediately
# at function entry, unlike a not-yet-executed local.
run_case "args at breakpoint" "$FIXTURE_SRC" 'b bump\nc\ni a\nkill\n' "n = "

# print <name> resolves the same argument by name.
run_case "print arg at breakpoint" "$FIXTURE_SRC" 'b bump\nc\np n\nkill\n' "n = "

# Frame selection ('up') addresses the caller's (slow_step's) own argument,
# not bump's -- proves the frame list's base tracking, not just frame 0.
run_case "frame selection: caller arg" "$FIXTURE_SRC" 'b bump\nc\nup\np n\nkill\n' "n = "

# 'bt' after 'up' shows the caller was selected without losing the list.
run_case "up then backtrace still names both frames" "$FIXTURE_SRC" 'b bump\nc\nup\nbt\nkill\n' "main ("

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

# --- execution control: s/n/fin (#123 phase 4 remainder) ---
# 'n' (next) steps over a call: from slow_step's call-site line, one 'next'
# runs bump to completion and stops at slow_step's own following statement,
# never reporting a stop inside bump itself.
run_case "next steps over a call" "$FIXTURE_SRC" 'b slow_step\nc\nn\nkill\n' "return step"

# 's' (step) steps into a call: from the same call-site line, one 'step'
# lands on bump's first statement instead.
run_case "step steps into a call" "$FIXTURE_SRC" 'b slow_step\nc\ns\nkill\n' "bump ("

# A second 'next' from inside bump (after stepping in) advances by source
# line within the same frame, same as wdbg.w's in-process 'n'.
run_case "next advances within a frame" "$FIXTURE_SRC" 'b bump\nc\nn\nkill\n' "return inc"

# 'fin' runs to the caller's return site and reports the returned value
# (bump's argument n plus one).
run_case "finish reports the returned value" "$FIXTURE_SRC" 'b bump\nc\nfin\nkill\n' "value returned = "

# After 'fin' reports the value it glides to the next statement boundary in
# the caller (slow_step's own 'return step'), matching wdbg.w's in-process
# 'fin' rather than stopping mid-statement at the bare return address.
run_case "finish lands on the caller's next statement" "$FIXTURE_SRC" 'b bump\nc\nfin\nkill\n' "return step"

# --- detach truly restores patched bytes (#123 phase 4) ---
# Every other case above kills the fixture with -9 after detaching, which
# never proves the patched int3 byte was put back: a leftover 0xcc would
# only show up if the process kept running past it. This drives a fixture
# that terminates on its own (attach_finite_fixture.w) through a real
# detach and waits for its natural exit instead of killing it, so a
# regression that skips the byte restore surfaces as a crash or a wrong
# exit code here instead of silently passing. Both the final printed line
# and the real process exit code (via $? after 'wait', appended as the
# subshell's own exit) are asserted from one run of the fixture.
FINITE_BIN=bin/attach_finite_target
FINITE_SRC=tests/attach_finite_fixture.w

# Runs entirely inside one subshell so the fixture's stdout (its final
# println) and its real exit code (via 'wait' immediately after) are both
# captured from the same process, in the same command substitution.
out=$(
	"$FINITE_BIN" &
	pid=$!
	sleep 0.4
	printf 'b bump\nc\ndetach\n' | "$WDBG" --attach "$pid" "$FINITE_SRC" >/dev/null 2>/dev/null
	code=0
	wait "$pid" || code=$?
	echo "exit_code=$code"
)
if printf '%s' "$out" | grep -qF "attach_finite_done"; then
	echo "ok: detach lets the target print its final output"
else
	echo "FAIL: detach lets the target print its final output"
	echo "  actual output:"
	printf '%s\n' "$out" | sed 's/^/    /'
	FAILED=1
fi
if printf '%s' "$out" | grep -qF "exit_code=42"; then
	echo "ok: detach lets the target exit naturally (code 42)"
else
	echo "FAIL: detach lets the target exit naturally: $out"
	FAILED=1
fi

# --- x86-64 attach: symbolization, registers, locals/frames (#123 phase 3) ---
# Same fixture, compiled and attached as a 64-bit target: bin/wdbg64 (built
# with 'bin/wv2 x64 debugger/debugger.w') recompiles the source with the
# x64 selector too (debugger/wdbg.w's wdbg_attach_compile), so calibration
# validates against a 64-bit /proc/<pid>/exe instead of falling back to raw
# mode the way a 32-bit recompile always did against a 64-bit process.
WDBG64=bin/wdbg64
FIXTURE_BIN64=bin/attach_target64

run_case_64() {
	desc="$1"
	extra="$2"
	commands="$3"
	expect="$4"

	"$FIXTURE_BIN64" &
	pid=$!
	sleep 0.4

	out=$(printf '%b' "$commands" | "$WDBG64" --attach "$pid" $extra 2>/dev/null || true)
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

run_case_64 "x64: symbolized location" "$FIXTURE_SRC" 'l\ndetach\n' "attach_target_fixture.w:"
run_case_64 "x64: symbols loaded banner" "$FIXTURE_SRC" 'detach\n' "symbols loaded"
run_case_64 "x64: registers dump uses 64-bit names" "$FIXTURE_SRC" 'r\ndetach\n' "rip: 0x"
run_case_64 "x64: breakpoint hit names function" "$FIXTURE_SRC" 'b bump\nc\nkill\n' "hit breakpoint 1"
run_case_64 "x64: args through the seam" "$FIXTURE_SRC" 'b bump\nc\ni a\nkill\n' "n = "
run_case_64 "x64: frame selection reaches caller" "$FIXTURE_SRC" 'b bump\nc\nup\np n\nkill\n' "n = "
run_case_64 "x64: backtrace names main" "$FIXTURE_SRC" 'b bump\nc\nbt\nkill\n' "main ("

# x64: execution control twins (#123 phase 4 remainder).
run_case_64 "x64: next steps over a call" "$FIXTURE_SRC" 'b slow_step\nc\nn\nkill\n' "return step"
run_case_64 "x64: step steps into a call" "$FIXTURE_SRC" 'b slow_step\nc\ns\nkill\n' "bump ("
run_case_64 "x64: finish reports the returned value" "$FIXTURE_SRC" 'b bump\nc\nfin\nkill\n' "value returned = "

# x64: detach truly restores patched bytes, same shape as the 32-bit case
# above (one subshell capturing both the fixture's stdout and its real
# exit code after 'wait').
FINITE_BIN64=bin/attach_finite_target64

out=$(
	"$FINITE_BIN64" &
	pid=$!
	sleep 0.4
	printf 'b bump\nc\ndetach\n' | "$WDBG64" --attach "$pid" "$FINITE_SRC" >/dev/null 2>/dev/null
	code=0
	wait "$pid" || code=$?
	echo "exit_code=$code"
)
if printf '%s' "$out" | grep -qF "attach_finite_done"; then
	echo "ok: x64: detach lets the target print its final output"
else
	echo "FAIL: x64: detach lets the target print its final output"
	echo "  actual output:"
	printf '%s\n' "$out" | sed 's/^/    /'
	FAILED=1
fi
if printf '%s' "$out" | grep -qF "exit_code=42"; then
	echo "ok: x64: detach lets the target exit naturally (code 42)"
else
	echo "FAIL: x64: detach lets the target exit naturally: $out"
	FAILED=1
fi

if [ "$FAILED" -eq 0 ]; then
	echo "attach test OK"
else
	echo "attach test FAILED"
	exit 1
fi
