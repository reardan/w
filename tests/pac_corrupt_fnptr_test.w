# Negative fixture for --pac=full on arm64: flipping a bit inside the
# PAC signature field of a stored function pointer MUST kill the
# process at the authenticating call (blraaz faults on FPAC hardware —
# qemu -cpu max and Apple Silicon alike). pac_corrupt_test_arm64 asserts this
# process dies by signal; reaching the final println means pointer
# authentication silently passed a forged pointer.
import lib.lib


type pac_fn = fn(int) -> int


int pac_id(int x):
	return x


int main(int argc, int argv):
	pac_fn* f = pac_id
	# Bit 58 sits inside the PAC field for every 47/48-bit VA
	# configuration, so adding it breaks the signature.
	int forged = cast(int, f) + (1 << 58)
	f = cast(pac_fn*, forged)
	int r = f(41)
	println(c"NOT REACHED: forged function pointer survived authentication")
	return r - 41
