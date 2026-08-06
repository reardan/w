#!/bin/sh
# End-to-end test for the core-dump processor (tools/wcore.w).
#
# Crashes the null-deref crash fixture (a real kernel SIGSEGV) with core
# dumps enabled, then runs bin/wcore on the resulting ET_CORE file and
# asserts the report symbolizes the faulting function and shows a
# plausible backtrace, for both a 32-bit and a 64-bit fixture binary.
#
# Real kernel cores need a cooperative environment: a plain-filename
# /proc/sys/kernel/core_pattern (so the core lands in the crashing
# process's cwd) and a raisable RLIMIT_CORE. When either is missing --
# a piped core_pattern (apport/systemd-coredump, common on CI hosts) or
# a hard core limit of 0 -- the test SKIPS cleanly, printing the reason
# to stderr and the OK banner to stdout so the build step still passes.
# Prerequisites, built by the wcore_test target before this runs:
# bin/wcore, bin/wcore_fixture32, bin/wcore_fixture64.
set -u

WCORE=bin/wcore
FAILED=0

skip() {
	echo "wcore test SKIP: $1" >&2
	echo "wcore test OK"
	exit 0
}

PATTERN=$(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo "")
case "$PATTERN" in
	\|*) skip "core_pattern is piped ($PATTERN): no core file lands in the cwd" ;;
esac

# expect <case> <output> <substring>
expect() {
	case "$2" in
		*"$3"*) ;;
		*)
			echo "FAIL: $1: output does not contain '$3'"
			FAILED=1
			;;
	esac
}

# run_case <description> <fixture-binary> <ip-register-name>
run_case() {
	desc="$1"
	fixture="$2"
	ipreg="$3"
	dir="bin/wcore_test_dir_$ipreg"
	rm -rf "$dir"
	mkdir -p "$dir"
	# Crash the fixture with cores enabled, in its own directory so the
	# "core" file cannot collide with another case. W_CRASH_TRACE=0
	# keeps the fixture's own in-process crash report out of the way;
	# the kernel core dump is what this test is about.
	root=$(pwd)
	( cd "$dir" && ulimit -c unlimited 2>/dev/null && W_CRASH_TRACE=0 "$root/$fixture" ) >/dev/null 2>&1
	core=$(ls "$dir"/core* 2>/dev/null | head -n 1)
	if [ -z "$core" ]; then
		skip "$desc: no core file appeared (RLIMIT_CORE hard-capped, or core_pattern '$PATTERN' points elsewhere)"
	fi

	out=$("$WCORE" "$core" "$fixture" 2>&1)
	expect "$desc" "$out" "SIGSEGV"
	expect "$desc" "$out" "faulting address: 0x00000000"
	expect "$desc" "$out" "crash_deep (tests/crash_null_deref_fixture.w:"
	expect "$desc" "$out" "at main ("
	expect "$desc" "$out" "  $ipreg 0x"
	expect "$desc" "$out" "stack trace (most recent call first):"

	json=$("$WCORE" --json "$core" "$fixture" 2>&1)
	expect "$desc (--json)" "$json" '"signal":11'
	expect "$desc (--json)" "$json" '"signal_name":"SIGSEGV"'
	expect "$desc (--json)" "$json" '"function":"crash_deep"'
	expect "$desc (--json)" "$json" "\"$ipreg\":\"0x"

	rm -rf "$dir"
}

run_case "32-bit core" bin/wcore_fixture32 eip
run_case "64-bit core" bin/wcore_fixture64 rip

if [ "$FAILED" -ne 0 ]; then
	exit 1
fi
echo "wcore test OK"
