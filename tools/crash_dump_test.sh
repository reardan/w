#!/bin/sh
# End-to-end test for W-generated crash dumps (lib/crash_dump.w) and
# their processing by tools/wcore.w.
#
# Runs the crash fixtures with W_CRASH_DUMP set, so the in-process
# fatal-signal handler writes its own ET_CORE dump. Unlike wcore_test
# (kernel cores), this needs no core_pattern/RLIMIT_CORE cooperation,
# so it never skips. For a 32-bit and a 64-bit fixture it checks:
#   * the stderr report carries registers, the build-id and the dump path,
#     and the process still dies of the original signal;
#   * "%p" in W_CRASH_DUMP expands to the pid;
#   * wcore finds the binary through the dump's "W" exe-path note (no
#     binary argument), verifies the build-id, and symbolizes the trace;
#   * a different same-architecture W binary is refused by build-id;
#   * an unwritable dump path is reported and the crash still happens.
# Prerequisites, built by the crash_dump_test target before this runs:
# bin/wcore, bin/crash_dump_fixture{32,64}, bin/crash_dump_div{32,64}.
set -u

WCORE=bin/wcore
FAILED=0

# expect <case> <output> <substring>
expect() {
	case "$2" in
		*"$3"*) ;;
		*)
			echo "FAIL: $1: output does not contain '$3'"
			echo "$2" | sed 's/^/    | /'
			FAILED=1
			;;
	esac
}

# run_case <description> <fixture> <div-fixture> <ip-register> <other-binary>
run_case() {
	desc="$1"
	fixture="$2"
	divfix="$3"
	ipreg="$4"
	other="$5"
	dir="bin/crash_dump_test_dir_$ipreg"
	rm -rf "$dir"
	mkdir -p "$dir"
	root=$(pwd)

	err=$(W_CRASH_DUMP="$root/$dir/w.%p.core" "$root/$fixture" 2>&1 >/dev/null)
	status=$?
	if [ "$status" -ne 139 ]; then
		echo "FAIL: $desc: expected death by SIGSEGV (status 139), got $status"
		FAILED=1
	fi
	expect "$desc (stderr)" "$err" "fatal signal: SIGSEGV"
	expect "$desc (stderr)" "$err" "registers:"
	expect "$desc (stderr)" "$err" " $ipreg=0x"
	expect "$desc (stderr)" "$err" "build-id: "
	expect "$desc (stderr)" "$err" "crash dump written to $root/$dir/w."
	core=$(ls "$dir"/w.*.core 2>/dev/null | head -n 1)
	if [ -z "$core" ]; then
		echo "FAIL: $desc: no dump file appeared in $dir"
		FAILED=1
		return
	fi
	case "$core" in
		*w.%p.core) echo "FAIL: $desc: %p was not expanded"; FAILED=1 ;;
	esac

	out=$("$WCORE" "$core" 2>&1)
	expect "$desc" "$out" "source: W crash handler dump"
	expect "$desc" "$out" "(core and binary match)"
	expect "$desc" "$out" "SIGSEGV (invalid memory reference)"
	expect "$desc" "$out" "faulting address: 0x00000000"
	expect "$desc" "$out" "at crash_deep ("
	expect "$desc" "$out" "at crash_mid ("
	expect "$desc" "$out" "at main ("
	expect "$desc" "$out" "crash_null_deref_fixture.w:"
	expect "$desc" "$out" "  $ipreg 0x"

	json=$("$WCORE" --json "$core" "$fixture" 2>&1)
	expect "$desc (--json)" "$json" '"source":"w_crash_dump"'
	expect "$desc (--json)" "$json" '"build_id_verified":true'
	expect "$desc (--json)" "$json" '"signal":11'
	expect "$desc (--json)" "$json" '"si_code":1'
	expect "$desc (--json)" "$json" '"function":"crash_deep"'

	if wrong=$("$WCORE" "$core" "$other" 2>&1); then
		echo "FAIL: $desc: wcore accepted a binary with a different build-id"
		FAILED=1
	fi
	expect "$desc (wrong binary)" "$wrong" "build-id mismatch"

	# SIGFPE: the faulting address is the pc.
	W_CRASH_DUMP="$dir/div.core" "$divfix" >/dev/null 2>&1
	out=$("$WCORE" "$dir/div.core" 2>&1)
	expect "$desc (SIGFPE)" "$out" "SIGFPE (arithmetic exception)"
	expect "$desc (SIGFPE)" "$out" "at crash_divide ("

	# Unwritable path: reported, and the process still dies of SIGSEGV.
	err=$(W_CRASH_DUMP="$dir/missing/x.core" "$fixture" 2>&1 >/dev/null)
	status=$?
	expect "$desc (unwritable)" "$err" "crash dump: cannot write $dir/missing/x.core"
	expect "$desc (unwritable)" "$err" "at crash_deep ("
	if [ "$status" -ne 139 ]; then
		echo "FAIL: $desc (unwritable): expected status 139, got $status"
		FAILED=1
	fi

	rm -rf "$dir"
}

run_case "32-bit dump" bin/crash_dump_fixture32 bin/crash_dump_div32 eip bin/crash_dump_div32
run_case "64-bit dump" bin/crash_dump_fixture64 bin/crash_dump_div64 rip bin/crash_dump_div64

if [ "$FAILED" -ne 0 ]; then
	exit 1
fi
echo "crash dump test OK"
