#!/bin/sh
# Natively execute arm64_darwin test binaries on the macOS host (Phase 6 of
# docs/projects/arm64_stage45_plan.md). The binaries are cross-compiled
# inside the w-dev container (tools/mac/wdev.sh); this half runs on the Mac
# because only the Mac can load and exec Mach-O.
#
# Usage: tools/mac/run_darwin_tests.sh bin/net_darwin [bin/more...]
#        tools/mac/run_darwin_tests.sh          # runs the default set
#
# The compiler self-signs its output (code_generator/macho_sign.w writes an
# ad-hoc CodeDirectory), so no host `codesign` step is needed — codesign -v
# accepts the signature as-is. Each binary is still copied to a fresh inode
# before exec, purely for the vnode gotcha: the kernel caches code-signature
# state per vnode, so an inode that was ever executed and killed keeps
# failing even after a valid re-sign (the Go/lld/Chrome rename gotcha).
set -e

cd "$(dirname "$0")/../.."

tests="$*"
must_die=""
if [ -z "$tests" ]; then
	# bin/net_darwin comes from `./wbuild net_darwin` (issue #200):
	# loopback socket + plaintext HTTP smoke for the Darwin
	# sockaddr/socket-ABI fixes. Linux CI only cross-compiles it; this
	# script is where it actually runs.
	tests="bin/dynamic_darwin_test bin/graphics_gl_smoke_darwin bin/pac_full_darwin_test bin/net_darwin"
	# Cocoa window input (#462): synthetic NSEvents through the real
	# AppKit queue; prints a SKIP line outside a GUI session.
	tests="$tests bin/graphics_cocoa_input_darwin"
	# The `./wbuild arm64_darwin_smoke_test` set (issue #210): the same
	# programs as the qemu-based arm64_smoke_test, cross-compiled to
	# Mach-O, so real-silicon smoke coverage does not need qemu. Like
	# net_darwin, Linux only cross-compiles them; this script is their
	# run leg.
	tests="$tests bin/lib_darwin_test bin/hash_table_darwin_test bin/map_set_builtin_darwin_test bin/generator_darwin_test bin/compound_assign_darwin_test bin/limb_builtin_darwin_test"
	# arm64e corruption fixtures (./wbuild pac_darwin): pointer authentication
	# is enforced natively, so these MUST die by signal before reaching
	# their NOT REACHED print.
	must_die="bin/pac_corrupt_fnptr_darwin_test bin/pac_corrupt_ret_darwin_test"
	# Crash reports (./wbuild crash_darwin, issue #378); checked below.
	crash_fixtures=1
fi

fail=0
for t in $tests; do
	if [ ! -f "$t" ]; then
		echo "run_darwin_tests: missing $t (compile it in the container first)" >&2
		fail=1
		continue
	fi
	cp "$t" "$t.run"
	if "./$t.run"; then
		echo "run_darwin_tests: PASS $t"
	else
		echo "run_darwin_tests: FAIL $t (exit $?)" >&2
		fail=1
	fi
	rm -f "$t.run"
done

for t in $must_die; do
	if [ ! -f "$t" ]; then
		echo "run_darwin_tests: missing $t (compile it in the container first)" >&2
		fail=1
		continue
	fi
	cp "$t" "$t.run"
	rc=0
	out=$("./$t.run" 2>&1) || rc=$?
	rm -f "$t.run"
	if [ "$rc" -ge 128 ] && [ "${out#*NOT REACHED}" = "$out" ]; then
		echo "run_darwin_tests: PASS $t (died with signal exit $rc, as required)"
	else
		echo "run_darwin_tests: FAIL $t (expected death by signal, got exit $rc)" >&2
		fail=1
	fi
done
# The crash_darwin fixtures: each prints an exact print_stack_trace() trace and
# then dies of SIGSEGV. The plain build must also print the full crash
# report; the --pac=full (arm64e) build must not, since the handler is
# not installed there (lib/crash.w crash_install_darwin).
# has_lines OUTPUT LINE...: every LINE appears, in this order.
has_lines() {
	rest="$1"
	shift
	for line in "$@"; do
		case "$rest" in
		*"$line"*) rest="${rest#*"$line"}" ;;
		*) echo "run_darwin_tests: missing line: $line" >&2; return 1 ;;
		esac
	done
}
if [ -n "$crash_fixtures" ]; then
	for t in bin/crash_darwin_fixture bin/crash_darwin_pac_fixture; do
		if [ ! -f "$t" ]; then
			echo "run_darwin_tests: missing $t (compile it in the container first)" >&2
			fail=1
			continue
		fi
		cp "$t" "$t.run"
		rc=0
		out=$(W_CRASH_TRACE=1 "./$t.run" 2>&1) || rc=$?
		rm -f "$t.run"
		ok=1
		[ "$rc" -eq 139 ] || { echo "run_darwin_tests: $t: want exit 139 (SIGSEGV), got $rc" >&2; ok=0; }
		has_lines "$out" "stack trace (most recent call first):" "  at crash_bottom" "  at crash_middle" "  at crash_top" "  at main" "traced" || ok=0
		if [ "$t" = bin/crash_darwin_fixture ]; then
			has_lines "$out" "traced" "fatal signal: SIGSEGV (invalid memory reference)" "faulting address 0x0000000000000010" "  x28=" "uuid: " "  at crash_bottom" "  at crash_middle" "  at crash_top" "  at main" "terminating with the default action for signal 11" || ok=0
			# The frame chain (x29 on the W stack) makes the walk exact.
			case "$out" in *"trace is heuristic"*) echo "run_darwin_tests: $t: crash trace fell back to the heuristic scan" >&2; ok=0 ;; esac
			case "$out" in *"at decoy_"*) echo "run_darwin_tests: $t: crash trace reported the decoy return address" >&2; ok=0 ;; esac
		else
			case "$out" in *"fatal signal"*) echo "run_darwin_tests: $t: arm64e image printed a crash report" >&2; ok=0 ;; esac
		fi
		if [ "$ok" -eq 1 ]; then
			echo "run_darwin_tests: PASS $t"
		else
			printf '%s\n' "$out" >&2
			echo "run_darwin_tests: FAIL $t" >&2
			fail=1
		fi
	done
fi
exit $fail
