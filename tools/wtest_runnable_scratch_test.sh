#!/bin/sh
# Fixture-driven checks for bin/wtest's --runnable-here filter
# (tools/test_map.w). The filter's probes ask about THIS host (is the
# 32-bit ELF loader installed? the 64-bit one? an NVIDIA GPU?), so a
# frozen expect-file case cannot assert both directions on every
# machine — the same lesson as manifest_unavailable.json's fictional
# tools/mac/ path (tests/wtest/map_expectations.expect). This script
# instead probes the host itself with the same evidence the filter
# uses and asserts the matching direction: on a host WITH the loader
# the target is kept, on one WITHOUT it the target is dropped and the
# stderr reason names the missing loader. Run from the repo root:
#   sh tools/wtest_runnable_scratch_test.sh
# The fixture manifest (tests/wtest/manifest_runnable.json) is selected
# through a non-.w marker path, so no import closures are computed and
# bin/.wtest_deps_cache is never touched — safe to run in parallel with
# the other wtest targets.
set -e

if [ ! -x bin/wtest ]; then
	echo "wtest_runnable_scratch_test: bin/wtest must be built first" >&2
	exit 1
fi

fail() {
	echo "wtest_runnable_scratch_test: FAIL: $1" >&2
	exit 1
}

manifest=tests/wtest/manifest_runnable.json

# --available alone must keep every fixture target: the loader/GPU
# probes are part of --runnable-here, not of the older flag.
out=$(bin/wtest changed -f "$manifest" --available widget/runnable.dat)
for t in rn_dyn32 rn_dyn64 rn_gpu rn_static rn_compile_only; do
	echo "$out" | grep -qx "$t" || fail "--available dropped $t"
done

err_file=$(mktemp)
trap 'rm -f "$err_file"' EXIT
out=$(bin/wtest changed -f "$manifest" --runnable-here widget/runnable.dat 2>"$err_file")

# A statically linked run target and a compile-only target are runnable
# on every host.
echo "$out" | grep -qx rn_static || fail "--runnable-here dropped the static target"
echo "$out" | grep -qx rn_compile_only || fail "--runnable-here dropped the compile-only target"

# 32-bit dynamically linked run target (root declares c_lib): needs the
# i386 ELF interpreter.
if [ -e /lib/ld-linux.so.2 ]; then
	echo "$out" | grep -qx rn_dyn32 || fail "host has /lib/ld-linux.so.2 but rn_dyn32 was dropped"
else
	echo "$out" | grep -qx rn_dyn32 && fail "no /lib/ld-linux.so.2 on this host but rn_dyn32 was kept"
	grep -q "/lib/ld-linux.so.2 not found" "$err_file" || fail "drop reason did not name /lib/ld-linux.so.2"
fi

# Same root compiled for x64: needs the 64-bit interpreter instead.
if [ -e /lib64/ld-linux-x86-64.so.2 ]; then
	echo "$out" | grep -qx rn_dyn64 || fail "host has the 64-bit loader but rn_dyn64 was dropped"
else
	echo "$out" | grep -qx rn_dyn64 && fail "no 64-bit loader on this host but rn_dyn64 was kept"
	grep -q "/lib64/ld-linux-x86-64.so.2 not found" "$err_file" || fail "drop reason did not name the 64-bit loader"
fi

# GPU run target (root imports lib.cuda): needs the NVIDIA driver.
if [ -e /dev/nvidiactl ] || [ -e /dev/nvidia0 ] || command -v nvidia-smi >/dev/null 2>&1; then
	echo "$out" | grep -qx rn_gpu || fail "host has an NVIDIA GPU but rn_gpu was dropped"
else
	echo "$out" | grep -qx rn_gpu && fail "no NVIDIA GPU on this host but rn_gpu was kept"
	grep -q "no NVIDIA GPU" "$err_file" || fail "drop reason did not name the missing GPU"
fi

echo "wtest_runnable_scratch_test: OK"
