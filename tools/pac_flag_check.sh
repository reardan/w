#!/bin/sh
# Artifact assertions for the --pac=off|ret|full flag: compile one
# fixture at each level and match the A64 instruction encodings in the
# output bytes. x86 hosts have no aarch64 objdump, so the byte patterns
# are matched directly (little-endian words):
#   pacia x30,x28 = 9e03c1da   autia x30,x28 = 9e13c1da
#   paciza x0     = e023c1da   blraaz x0     = 1f083fd6
# Also asserts the arm64e cpusubtype (0x81000002 at header offset 8)
# appears exactly when arm64_darwin is compiled with --pac=full.
# Usage: pac_flag_check.sh [path-to-wv2]   (default bin/wv2)
set -e
WV2="${1:-bin/wv2}"

hex() {
	od -An -v -tx1 "$1" | tr -d ' \n'
}

# default: pac=ret — return addresses signed, no code-pointer signing
"$WV2" arm64 tests/pac_full_test.w -o bin/pac_flag_ret
hex bin/pac_flag_ret > bin/pac_flag_ret.hex
grep -q 9e03c1da bin/pac_flag_ret.hex
grep -q 9e13c1da bin/pac_flag_ret.hex
! grep -q e023c1da bin/pac_flag_ret.hex
! grep -q 1f083fd6 bin/pac_flag_ret.hex

# --pac=off: no pointer authentication at all
"$WV2" arm64 --pac=off tests/pac_full_test.w -o bin/pac_flag_off
hex bin/pac_flag_off > bin/pac_flag_off.hex
! grep -q 9e03c1da bin/pac_flag_off.hex
! grep -q 9e13c1da bin/pac_flag_off.hex

# --pac=full: ret signing plus paciza/blraaz code-pointer signing
"$WV2" arm64 --pac=full tests/pac_full_test.w -o bin/pac_flag_full
hex bin/pac_flag_full > bin/pac_flag_full.hex
grep -q 9e03c1da bin/pac_flag_full.hex
grep -q e023c1da bin/pac_flag_full.hex
grep -q 1f083fd6 bin/pac_flag_full.hex

# arm64_darwin --pac=full marks the slice arm64e; plain stays ARM64_ALL
"$WV2" arm64_darwin --pac=full tests/pac_full_test.w -o bin/pac_flag_arm64e
od -An -j8 -N4 -tx1 bin/pac_flag_arm64e | tr -d ' ' | grep -q 02000081
"$WV2" arm64_darwin tests/pac_full_test.w -o bin/pac_flag_darwin
od -An -j8 -N4 -tx1 bin/pac_flag_darwin | tr -d ' ' | grep -q 00000000

echo "pac flag test OK"
