#!/bin/sh
# Natively execute arm64_darwin test binaries on the macOS host (Phase 6 of
# docs/projects/arm64_stage45_plan.md). The binaries are cross-compiled
# inside the w-dev container (tools/mac/wdev.sh); this half runs on the Mac
# because only the Mac can load and exec Mach-O.
#
# Usage: tools/mac/run_darwin_tests.sh bin/hello_darwin [bin/more...]
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
	# bin/net_darwin_smoke_test comes from `./wbuild net_darwin` (issue
	# #200): loopback socket + plaintext HTTP smoke for the Darwin
	# sockaddr/socket-ABI fixes. Linux CI only cross-compiles it; this
	# script is where it actually runs.
	tests="bin/hello_darwin bin/dynamic_darwin_test bin/graphics_gl_smoke_darwin bin/pac_full_darwin_test bin/net_darwin_smoke_test"
	# arm64e corruption fixtures (./wbuild pac_darwin): pointer authentication
	# is enforced natively, so these MUST die by signal before reaching
	# their NOT REACHED print.
	must_die="bin/pac_corrupt_fnptr_darwin_test bin/pac_corrupt_ret_darwin_test"
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
exit $fail
