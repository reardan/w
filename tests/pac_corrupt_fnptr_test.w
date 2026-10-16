# Negative fixture for --pac=full on arm64: flipping a bit inside the
# PAC field of a stored function pointer MUST kill the process at the
# authenticating call (blraaz faults on FPAC hardware -- qemu -cpu max
# and Apple Silicon alike -- and yields a non-canonical branch target
# without FPAC). pac_corrupt_test_arm64 asserts this process dies by
# signal; reaching the final println means pointer authentication
# silently passed a forged pointer.
#
# The corruption must be deterministic. The PAC is computed over the
# pointer with its PAC field stripped, so flipping a bit INSIDE that
# field leaves the recomputed PAC unchanged and the comparison can never
# match (PAuth1 compares, PAuth2 XORs and checks for a residue -- both
# fail every time). Touching any bit OUTSIDE the field instead changes
# the PAC's input, and the fresh PAC collides with the stored one with
# probability 2^-(field width). That was this fixture's old bug: it
# added 1 << 58, but qemu-user runs guests with TBI0 on and TBID0 off,
# so for instruction addresses the top byte is an ignored tag, not PAC,
# and the field is only bits 54:48 (7 bits). With qemu-user's
# per-process random keys about 1 run in 128 authenticated the forged
# pointer and the call went through (CI flakes on PRs #660/#665;
# 10 escapes in 1500 local runs). Bit 54 is inside the field for every
# VA size up to 52 bits, with or without TBI, Linux or Darwin.
#
# The field flip alone would also kill a process whose PAC keys were
# disabled (paciza/blraaz degrade to a plain move/branch, and bit 54
# makes the target non-canonical), so first prove signing is live: at
# least one of eight independently signed pointers must carry PAC bits
# above the 48-bit user address range (all eight clear by chance:
# 2^-56 on qemu's 7-bit field).
import lib.lib


type pac_fn = fn(int) -> int


int pac_id(int x):
	return x


int pac_f1(int x):
	return x + 1


int pac_f2(int x):
	return x + 2


int pac_f3(int x):
	return x + 3


int pac_f4(int x):
	return x + 4


int pac_f5(int x):
	return x + 5


int pac_f6(int x):
	return x + 6


int pac_f7(int x):
	return x + 7


# Nonzero when the signed pointer carries bits above the user VA range,
# i.e. paciza actually inserted a PAC.
int pac_high_bits(pac_fn* f):
	return cast(int, f) >> 48


int main(int argc, int argv):
	int signed_bits = pac_high_bits(pac_id) | pac_high_bits(pac_f1)
	signed_bits = signed_bits | pac_high_bits(pac_f2) | pac_high_bits(pac_f3)
	signed_bits = signed_bits | pac_high_bits(pac_f4) | pac_high_bits(pac_f5)
	signed_bits = signed_bits | pac_high_bits(pac_f6) | pac_high_bits(pac_f7)
	if (signed_bits == 0):
		println(c"PAC inactive: no signed function pointer carries a PAC")
		return 3
	pac_fn* f = pac_id
	int forged = cast(int, f) ^ (1 << 54)
	f = cast(pac_fn*, forged)
	int r = f(41)
	println(c"NOT REACHED: forged function pointer survived authentication")
	return r - 41
# wbuild: target=pac_corrupt_test_arm64 tag=tests_arm64 dep=wv2 dep=wrun
# wbuild: step="bin/wv2 arm64 --pac=full tests/pac_corrupt_fnptr_test.w -o bin/pac_corrupt_fnptr_arm64_test"
# wbuild: step="bin/wrun arm64 bin/pac_corrupt_fnptr_arm64_test" expect_signal reject_stdout="NOT REACHED"
# wbuild: step="bin/wv2 arm64 tests/pac_corrupt_ret_test.w -o bin/pac_corrupt_ret_arm64_test"
# wbuild: step="bin/wrun arm64 bin/pac_corrupt_ret_arm64_test" expect_signal reject_stdout="NOT REACHED"
# wbuild: step="echo 'pac corruption tests OK (both fixtures died)'"
