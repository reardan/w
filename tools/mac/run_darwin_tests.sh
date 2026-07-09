#!/bin/sh
# Sign and natively execute arm64_darwin test binaries on the macOS host
# (Phase 6 of docs/projects/arm64_stage45_plan.md). The binaries are
# cross-compiled inside the w-dev container (tools/mac/wdev.sh); this half
# runs on the Mac because only the Mac can codesign and load Mach-O.
#
# Usage: tools/mac/run_darwin_tests.sh bin/hello_darwin [bin/more...]
#        tools/mac/run_darwin_tests.sh          # runs the default set
#
# codesign -s - (ad-hoc) is the interim signing path until the in-house
# CodeDirectory writer (macho_sign.w, Phase 5) lands.
#
# Signing happens on a fresh copy which is renamed over the original: the
# kernel caches code-signature state per vnode, and an inode that was ever
# executed with a different signature (or killed unsigned) keeps failing
# even after a valid re-sign (the Go/lld/Chrome write-then-rename gotcha).
set -e

cd "$(dirname "$0")/../.."

tests="$*"
must_die=""
if [ -z "$tests" ]; then
	tests="bin/hello_darwin bin/dynamic_darwin_test bin/graphics_gl_smoke_darwin bin/pac_full_darwin_test"
	# arm64e corruption fixtures (./wbuild pac_darwin): pointer authentication
	# is enforced natively, so these MUST die by signal before reaching
	# their NOT REACHED print.
	must_die="bin/pac_corrupt_fnptr_darwin_test bin/pac_corrupt_ret_darwin_test"
fi

sign() {
	cp "$1" "$1.signing"
	codesign -f -s - "$1.signing"
	mv -f "$1.signing" "$1"
}

fail=0
for t in $tests; do
	if [ ! -f "$t" ]; then
		echo "run_darwin_tests: missing $t (compile it in the container first)" >&2
		fail=1
		continue
	fi
	sign "$t"
	if "./$t"; then
		echo "run_darwin_tests: PASS $t"
	else
		echo "run_darwin_tests: FAIL $t (exit $?)" >&2
		fail=1
	fi
done

for t in $must_die; do
	if [ ! -f "$t" ]; then
		echo "run_darwin_tests: missing $t (compile it in the container first)" >&2
		fail=1
		continue
	fi
	sign "$t"
	rc=0
	out=$("./$t" 2>&1) || rc=$?
	if [ "$rc" -ge 128 ] && [ "${out#*NOT REACHED}" = "$out" ]; then
		echo "run_darwin_tests: PASS $t (died with signal exit $rc, as required)"
	else
		echo "run_darwin_tests: FAIL $t (expected death by signal, got exit $rc)" >&2
		fail=1
	fi
done
exit $fail
