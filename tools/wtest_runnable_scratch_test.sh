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
# The marker-path invocations select through a non-.w path, so they
# compute no import closures. The closure-level invocation at the
# bottom passes .w changed paths on purpose: rule (b) then computes
# the fixture roots' closures (touching bin/.wtest_deps_cache, which
# is safe — entries validate individually and wtest_archs_test
# already shares the file) so the filter can attribute needs declared
# in IMPORTED modules (ai_tooling_next_steps.md 2026-07-29).
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
for t in rn_dyn32 rn_dyn64 rn_gpu rn_static rn_compile_only rn_dyn_imp rn_gpu_imp rn_plain_imp rn_broken_imp; do
	echo "$out" | grep -qx "$t" || fail "--available dropped $t"
done

err_file=$(mktemp)
err_file2=$(mktemp)
trap 'rm -f "$err_file" "$err_file2"' EXIT
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

# Closure-level attribution (ai_tooling_next_steps.md 2026-07-29): the
# needy directives below live in imported modules, never in the roots,
# so this invocation passes the modules as .w changed paths — rule (b)
# selects the importing roots' targets AND computes their closures,
# which the filter then scans. broken_imp.w (a root whose closure can
# never be computed — its second import does not exist) rides along to
# pin the fallback: root-only scan, no directives, kept everywhere.
out=$(bin/wtest changed -f "$manifest" --runnable-here tests/wtest/runnable_fixture/dep_dyn.w tests/wtest/runnable_fixture/dep_gpu.w tests/wtest/runnable_fixture/dep_plain.w tests/wtest/runnable_fixture/broken_imp.w 2>"$err_file2")

# A clean import chain must not have needs invented for it, and the
# closure-less root must fall back to its own (directive-free) text.
echo "$out" | grep -qx rn_plain_imp || fail "closure scan dropped rn_plain_imp (clean import chain)"
echo "$out" | grep -qx rn_broken_imp || fail "closure-less root rn_broken_imp was dropped instead of falling back to the root text"

# dep_dyn.w carries the c_lib directive: the x86 root that merely
# imports it needs the i386 loader now.
if [ -e /lib/ld-linux.so.2 ]; then
	echo "$out" | grep -qx rn_dyn_imp || fail "host has /lib/ld-linux.so.2 but rn_dyn_imp was dropped"
else
	echo "$out" | grep -qx rn_dyn_imp && fail "no /lib/ld-linux.so.2 on this host but rn_dyn_imp was kept (imported c_lib not attributed)"
	grep -q "/lib/ld-linux.so.2 not found" "$err_file2" || fail "rn_dyn_imp drop reason did not name /lib/ld-linux.so.2"
fi

# dep_gpu.w imports lib.cuda: the root that merely imports IT needs
# the NVIDIA driver now (the lib/tensor.w shape).
if [ -e /dev/nvidiactl ] || [ -e /dev/nvidia0 ] || command -v nvidia-smi >/dev/null 2>&1; then
	echo "$out" | grep -qx rn_gpu_imp || fail "host has an NVIDIA GPU but rn_gpu_imp was dropped"
else
	echo "$out" | grep -qx rn_gpu_imp && fail "no NVIDIA GPU on this host but rn_gpu_imp was kept (imported lib.cuda not attributed)"
	grep -q "no NVIDIA GPU" "$err_file2" || fail "rn_gpu_imp drop reason did not name the missing GPU"
fi

echo "wtest_runnable_scratch_test: OK"
