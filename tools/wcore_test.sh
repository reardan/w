#!/bin/sh
# End-to-end test for the core-dump processor (tools/wcore.w).
#
# Crashes the null-deref crash fixture (a real kernel SIGSEGV) with core
# dumps enabled, then runs bin/wcore on the resulting ET_CORE file and
# asserts the report symbolizes the faulting function and shows a
# plausible backtrace, for both a 32-bit and a 64-bit fixture binary.
# It also checks the build-id cross-check: the core's copy of the
# fixture's build-id matches the fixture, a different same-architecture
# W binary is refused, and a core whose ELF header page was filtered out
# (coredump_filter without bit 4) is processed with an "unverified" note.
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

# run_case <description> <fixture-binary> <ip-register-name> <other-binary>
# <other-binary> is a different W binary of the same architecture, which
# wcore must refuse by build-id.
run_case() {
	desc="$1"
	fixture="$2"
	ipreg="$3"
	other="$4"
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
	# The .debug_line file table records the path the compiler saw, which
	# may be absolute: assert the basename, like crash_trace_test does.
	expect "$desc" "$out" "SIGSEGV"
	expect "$desc" "$out" "faulting address: 0x00000000"
	expect "$desc" "$out" "at crash_deep ("
	expect "$desc" "$out" "crash_null_deref_fixture.w:"
	expect "$desc" "$out" "at main ("
	expect "$desc" "$out" "  $ipreg 0x"
	expect "$desc" "$out" "stack trace (most recent call first):"

	json=$("$WCORE" --json "$core" "$fixture" 2>&1)
	expect "$desc (--json)" "$json" '"signal":11'
	expect "$desc (--json)" "$json" '"signal_name":"SIGSEGV"'
	expect "$desc (--json)" "$json" '"function":"crash_deep"'
	expect "$desc (--json)" "$json" "\"$ipreg\":\"0x"
	expect "$desc (--json)" "$json" '"build_id_verified":true'
	expect "$desc" "$out" "(core and binary match)"

	if wrong=$("$WCORE" "$core" "$other" 2>&1); then
		echo "FAIL: $desc: wcore accepted a binary with a different build-id"
		FAILED=1
	fi
	expect "$desc (wrong binary)" "$wrong" "build-id mismatch"

	# Drop coredump_filter bit 4 (ELF headers) so the core has no copy of
	# the binary's first page, hence no build-id: wcore still reports.
	rm -f "$dir"/core*
	( cd "$dir" && ulimit -c unlimited 2>/dev/null && echo 0x23 > /proc/self/coredump_filter && W_CRASH_TRACE=0 "$root/$fixture" ) >/dev/null 2>&1
	core=$(ls "$dir"/core* 2>/dev/null | head -n 1)
	if [ -n "$core" ]; then
		out=$("$WCORE" "$core" "$fixture" 2>&1)
		expect "$desc (no build-id in core)" "$out" "unverified: the core has no build-id"
		expect "$desc (no build-id in core)" "$out" "at crash_deep ("
	fi

	rm -rf "$dir"
}

run_case "32-bit core" bin/wcore_fixture32 eip bin/wv2
run_case "64-bit core" bin/wcore_fixture64 rip bin/wcore

if [ "$FAILED" -ne 0 ]; then
	exit 1
fi
echo "wcore test OK"
