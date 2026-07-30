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

# Every wdbg invocation runs under a timeout: an execution-control
# regression (e.g. continue failing to re-arm a stepped-over breakpoint)
# otherwise leaves wdbg blocked in wait4 forever and hangs CI instead of
# failing. A passing case takes ~1-2s standalone, but wdbg recompiles the
# fixture source on attach, and under a cold parallel `./wbuild tests`
# that compile competes with every other build job -- the old 30s was
# exceeded once under a cold 20-target run (2026-07-27,
# docs/projects/ai_tooling_next_steps.md), so the ceiling is 120s now:
# still a hard hang stop, with compile-load headroom. Override with
# ATTACH_TEST_TIMEOUT=<seconds> for slower machines. A timeout failure
# is reported as its own "FAIL (wdbg timed out ...)" banner so it is
# never misread as an assertion failure.
TIMEOUT_SECS="${ATTACH_TEST_TIMEOUT:-120}"
if command -v timeout >/dev/null 2>&1; then
	TIMEOUT="timeout $TIMEOUT_SECS"
else
	TIMEOUT=""
fi

# fail_banner <wdbg-exit-status> <description>
# The FAIL line for a case, distinguishing "wdbg timed out" (timeout(1)
# exits 124) from an ordinary assertion failure on wdbg's output.
fail_banner() {
	if [ "$1" -eq 124 ]; then
		echo "FAIL (wdbg timed out after ${TIMEOUT_SECS}s): $2"
	else
		echo "FAIL: $2"
	fi
}

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

	status=0
	if [ -n "$want_stderr" ]; then
		out=$(printf '%b' "$commands" | $TIMEOUT "$WDBG" --attach "$pid" $extra 2>&1) || status=$?
	else
		out=$(printf '%b' "$commands" | $TIMEOUT "$WDBG" --attach "$pid" $extra 2>/dev/null) || status=$?
	fi
	kill -9 "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true

	if printf '%s' "$out" | grep -qF "$expect"; then
		echo "ok: $desc"
	else
		fail_banner "$status" "$desc"
		echo "  expected substring: $expect"
		echo "  actual output:"
		printf '%s\n' "$out" | sed 's/^/    /'
		FAILED=1
	fi
}

# run_count_case <description> <wdbg-binary> <fixture-binary> <stdin> <substring> <min-count>
# Like run_case, but requires the substring to appear at least min-count
# times: a substring that the FIRST occurrence already satisfies (e.g.
# "hit breakpoint 1") cannot otherwise prove a second stop happened.
run_count_case() {
	desc="$1"
	dbg="$2"
	fixture="$3"
	commands="$4"
	expect="$5"
	min="$6"

	"$fixture" &
	pid=$!
	sleep 0.4

	status=0
	out=$(printf '%b' "$commands" | $TIMEOUT "$dbg" --attach "$pid" "$FIXTURE_SRC" 2>/dev/null) || status=$?
	kill -9 "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true

	got=$(printf '%s\n' "$out" | grep -cF "$expect" || true)
	if [ "$got" -ge "$min" ]; then
		echo "ok: $desc"
	else
		fail_banner "$status" "$desc"
		echo "  expected at least $min occurrences of: $expect (got $got)"
		echo "  actual output:"
		printf '%s\n' "$out" | sed 's/^/    /'
		FAILED=1
	fi
}

# run_frame_delta_case <description> <wdbg-binary> <fixture-binary>
# Frame selection must address the CALLER's stack slot, not re-read frame
# 0's: the fixture passes bump its n plus a fixed 7000000 call-site
# offset, so 'p n' at frame 0 and again after 'up' (both at the same
# stop) must differ by exactly that offset. A frame-base regression that
# reads frame 0's slot twice yields delta 0 and fails; a plain substring
# check could not tell the two apart when both frames held the same value.
run_frame_delta_case() {
	desc="$1"
	dbg="$2"
	fixture="$3"

	"$fixture" &
	pid=$!
	sleep 0.4

	status=0
	out=$(printf 'b bump\nc\np n\nup\np n\nkill\n' | $TIMEOUT "$dbg" --attach "$pid" "$FIXTURE_SRC" 2>/dev/null) || status=$?
	kill -9 "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true

	# 'p n' prints "n = <decimal> (0x<hex>)"; the non-tty prompt is glued
	# to the front of the line, so match the value anywhere on the line.
	n0=$(printf '%s\n' "$out" | sed -n 's/.*n = \([0-9][0-9]*\) (0x.*/\1/p' | sed -n 1p)
	n1=$(printf '%s\n' "$out" | sed -n 's/.*n = \([0-9][0-9]*\) (0x.*/\1/p' | sed -n 2p)
	if [ -n "$n0" ] && [ -n "$n1" ] && [ "$((n0 - n1))" -eq 7000000 ]; then
		echo "ok: $desc"
	else
		fail_banner "$status" "$desc"
		echo "  frame 0 n='$n0' caller n='$n1' (want delta 7000000)"
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
# disarm/step-over/re-arm dance lets it hit again on the next iteration:
# require TWO "hit breakpoint 1" stops, since one grep hit is already
# satisfied by the first stop (a re-arm regression used to pass here,
# with the second 'c' hanging until the timeout instead of failing).
run_count_case "breakpoint hit twice (re-armed)" "$WDBG" "$FIXTURE_BIN" 'b slow_step\nc\nc\nkill\n' "hit breakpoint 1" 2

# Locals/frames through the seam (#123 phase 5): 'bump' is called from
# 'slow_step', which is called from 'main', so a breakpoint in bump gives a
# real two-level call stack to inspect.

# Argument inspection at the innermost frame (frame 0): visible immediately
# at function entry, unlike a not-yet-executed local.
run_case "args at breakpoint" "$FIXTURE_SRC" 'b bump\nc\ni a\nkill\n' "n = "

# print <name> resolves the same argument by name.
run_case "print arg at breakpoint" "$FIXTURE_SRC" 'b bump\nc\np n\nkill\n' "n = "

# Frame selection ('up') addresses the caller's (slow_step's) own argument,
# not bump's -- proves the frame list's base tracking, not just frame 0,
# by requiring the two frames' n to differ by the fixture's fixed offset.
run_frame_delta_case "frame selection: caller arg differs by the call-site offset" "$WDBG" "$FIXTURE_BIN"

# A non-numeric frame argument is an error, not a silent frame-0 select.
run_case "frame rejects a non-numeric argument" "$FIXTURE_SRC" 'f x\ndetach\n' "frame: not a number: x"

# 'bt' after 'up' shows the caller was selected without losing the list.
run_case "up then backtrace still names both frames" "$FIXTURE_SRC" 'b bump\nc\nup\nbt\nkill\n' "main ("

# Memory examine reads the target's ELF magic at the fixed load base.
run_case "examine memory" "$FIXTURE_SRC" 'x 0x8048000 1\ndetach\n' "0x464c457f"

# --- restricted expression eval (#123 phase 6, debugger/attach_eval.w) ---
# The fixture initializes attach_pair {first=1234, second=5678}, a struct
# pointer to it and a 4-element heap int array {111,222,333,444} before
# its spin loop, so these are stable at any stop.

# Field access on a struct value.
run_case "eval: struct field read" "$FIXTURE_SRC" 'p attach_pair.first\ndetach\n' "attach_pair.first = 1234"

# Field access through a struct pointer (one auto-deref, like compiled '.').
run_case "eval: field through a struct pointer" "$FIXTURE_SRC" 'p attach_pair_ref.second\ndetach\n' "attach_pair_ref.second = 5678"

# Dereference reads at the pointee's width through the ptrace seam.
run_case "eval: dereference" "$FIXTURE_SRC" 'p *attach_items\ndetach\n' "*attach_items = 111"

# Indexing scales by the element size (never the raw byte offset).
run_case "eval: indexing" "$FIXTURE_SRC" 'p attach_items[2]\ndetach\n' "attach_items[2] = 333"

# Arithmetic combines evaluated results: 222 + 1234.
run_case "eval: arithmetic on results" "$FIXTURE_SRC" 'p attach_items[1] + attach_pair.first\ndetach\n' "= 1456"

# set writes through a field lvalue and echoes the new value.
run_case "eval: set through a field" "$FIXTURE_SRC" 'set attach_pair.second 42\np attach_pair.second\ndetach\n' "attach_pair.second = 42"

# In-target calls are rejected with a clear diagnostic, not silently 0.
run_case "eval: function calls rejected" "$FIXTURE_SRC" 'p bump(3)\ndetach\n' "function calls are not supported in attach mode"

# --- hardware watchpoints (DR0-DR3; #123's last remaining phase) ---
# Native x86/x86-64 only: the debug registers are real hardware state
# (PTRACE_PEEKUSER/POKEUSER on the user area), which qemu-user does not
# emulate -- this suite already assumes a native host for ptrace itself.

# A write watch on the spinning counter stops the tracee on the next
# iteration's store and names the watchpoint that fired (DR6), with the
# same old -> new report shape as the in-process software scan.
run_case "hw watchpoint fires and names the watchpoint" "$FIXTURE_SRC" 'watch attach_counter\nc\nkill\n' "watchpoint 1: attach_counter changed: "

# The stop reports where the write happened (back in the fixture source).
run_case "hw watchpoint stop is located" "$FIXTURE_SRC" 'watch attach_counter\nc\nkill\n' "attach_target_fixture.w:"

# Four debug registers exist; a fifth watch is a hard error, never a
# silent degradation (attach mode has no software fallback scan).
run_case "hw watchpoint exhaustion" "$FIXTURE_SRC" 'watch attach_counter\nwatch attach_pair.first\nwatch attach_pair.second\nwatch attach_items[0]\nwatch attach_items[1]\nkill\n' "no free debug register"

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
# captured from the same process, in the same command substitution. The
# wdbg exit status rides along as its own wdbg_status= line so a FAIL
# below can tell a timed-out wdbg (124) from a detach regression.
out=$(
	"$FINITE_BIN" &
	pid=$!
	sleep 0.4
	wdbg_status=0
	printf 'b bump\nc\ndetach\n' | $TIMEOUT "$WDBG" --attach "$pid" "$FINITE_SRC" >/dev/null 2>/dev/null || wdbg_status=$?
	echo "wdbg_status=$wdbg_status"
	code=0
	wait "$pid" || code=$?
	echo "exit_code=$code"
)
if printf '%s' "$out" | grep -qF "attach_finite_done"; then
	echo "ok: detach lets the target print its final output"
else
	if printf '%s' "$out" | grep -qF "wdbg_status=124"; then
		echo "FAIL (wdbg timed out after ${TIMEOUT_SECS}s): detach lets the target print its final output"
	else
		echo "FAIL: detach lets the target print its final output"
	fi
	echo "  actual output:"
	printf '%s\n' "$out" | sed 's/^/    /'
	FAILED=1
fi
if printf '%s' "$out" | grep -qF "exit_code=42"; then
	echo "ok: detach lets the target exit naturally (code 42)"
else
	echo "FAIL: detach lets the target exit naturally (code 42): $out"
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

	status=0
	out=$(printf '%b' "$commands" | $TIMEOUT "$WDBG64" --attach "$pid" $extra 2>/dev/null) || status=$?
	kill -9 "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true

	if printf '%s' "$out" | grep -qF "$expect"; then
		echo "ok: $desc"
	else
		fail_banner "$status" "$desc"
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
run_count_case "x64: breakpoint hit twice (re-armed)" "$WDBG64" "$FIXTURE_BIN64" 'b slow_step\nc\nc\nkill\n' "hit breakpoint 1" 2
run_case_64 "x64: args through the seam" "$FIXTURE_SRC" 'b bump\nc\ni a\nkill\n' "n = "
run_frame_delta_case "x64: frame selection: caller arg differs by the call-site offset" "$WDBG64" "$FIXTURE_BIN64"
run_case_64 "x64: backtrace names main" "$FIXTURE_SRC" 'b bump\nc\nbt\nkill\n' "main ("

# x64: execution control twins (#123 phase 4 remainder).
run_case_64 "x64: next steps over a call" "$FIXTURE_SRC" 'b slow_step\nc\nn\nkill\n' "return step"
run_case_64 "x64: step steps into a call" "$FIXTURE_SRC" 'b slow_step\nc\ns\nkill\n' "bump ("
run_case_64 "x64: finish reports the returned value" "$FIXTURE_SRC" 'b bump\nc\nfin\nkill\n' "value returned = "

# x64: restricted eval + hardware watchpoint twins (#123 phase 6 / 5).
run_case_64 "x64: eval field through a struct pointer" "$FIXTURE_SRC" 'p attach_pair_ref.second\ndetach\n' "attach_pair_ref.second = 5678"
run_case_64 "x64: eval indexing" "$FIXTURE_SRC" 'p attach_items[2]\ndetach\n' "attach_items[2] = 333"
run_case_64 "x64: eval set through a field" "$FIXTURE_SRC" 'set attach_pair.second 42\np attach_pair.second\ndetach\n' "attach_pair.second = 42"
run_case_64 "x64: hw watchpoint fires and names the watchpoint" "$FIXTURE_SRC" 'watch attach_counter\nc\nkill\n' "watchpoint 1: attach_counter changed: "

# x64: detach truly restores patched bytes, same shape as the 32-bit case
# above (one subshell capturing both the fixture's stdout and its real
# exit code after 'wait').
FINITE_BIN64=bin/attach_finite_target64

out=$(
	"$FINITE_BIN64" &
	pid=$!
	sleep 0.4
	wdbg_status=0
	printf 'b bump\nc\ndetach\n' | $TIMEOUT "$WDBG64" --attach "$pid" "$FINITE_SRC" >/dev/null 2>/dev/null || wdbg_status=$?
	echo "wdbg_status=$wdbg_status"
	code=0
	wait "$pid" || code=$?
	echo "exit_code=$code"
)
if printf '%s' "$out" | grep -qF "attach_finite_done"; then
	echo "ok: x64: detach lets the target print its final output"
else
	if printf '%s' "$out" | grep -qF "wdbg_status=124"; then
		echo "FAIL (wdbg timed out after ${TIMEOUT_SECS}s): x64: detach lets the target print its final output"
	else
		echo "FAIL: x64: detach lets the target print its final output"
	fi
	echo "  actual output:"
	printf '%s\n' "$out" | sed 's/^/    /'
	FAILED=1
fi
if printf '%s' "$out" | grep -qF "exit_code=42"; then
	echo "ok: x64: detach lets the target exit naturally (code 42)"
else
	echo "FAIL: x64: detach lets the target exit naturally (code 42): $out"
	FAILED=1
fi

if [ "$FAILED" -eq 0 ]; then
	echo "attach test OK"
else
	echo "attach test FAILED"
	exit 1
fi
