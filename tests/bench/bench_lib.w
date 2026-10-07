/*
Shared helpers for the benchmark corpus in tests/bench/ (docs/testing.md
"Performance", docs/projects/register_allocation_pgo.md §5).

Every program in the corpus is compute-bound and deterministic, takes an
optional size argument (argv[1]; the default is sized to run 0.3-2 s on
the x86 build of 2026-10) and prints exactly one line:

	<name> size=<n> checksum=<hex>

so the same source compiled by two compilers -- or its C twin in
tests/bench/c/ built by gcc/clang -- can be compared byte for byte. The
checksums are 32-bit values computed with the masked-word convention of
lib/sha256.w: the low 32 bits of an int are the same on the 32-bit and
64-bit targets as long as every intermediate that could differ (left
shifts, right shifts of values with bit 31 set) is masked, so a program
prints the same line whichever width it was compiled for.
*/
import lib.lib


# 0xffffffff built at run time: the literal would sign-extend to -1 on
# every target (CLAUDE.md). On the 32-bit target this IS -1, so masking
# with it is a no-op there, which is exactly right.
int bench_mask32():
	int h = 1 << 16
	return h * h - 1


# The size argument: argv[1] when present, else the program's default.
int bench_size(int argc, char** argv, int default_size):
	if (argc < 2): return default_size
	int n = atoi(argv[1])
	if (n < 1): return default_size
	return n


# Eight lowercase hex digits of the low 32 bits of v (malloc'd).
char* bench_hex32(int v):
	char* digits = c"0123456789abcdef"
	char* out = malloc(9)
	int i = 7
	while (i >= 0):
		out[i] = digits[v & 15]
		v = v >> 4
		i = i - 1
	out[8] = 0
	return out


# The one output line: "<name> size=<n> checksum=<hex>".
void bench_report(char* name, int size, int checksum):
	print(name)
	print(c" size=")
	print(itoa(size))
	print(c" checksum=")
	println(bench_hex32(checksum))


# Fold one 32-bit word into a running checksum: h = h * 31 + v, masked.
# Multiplication and addition keep the low 32 bits equal on both word
# sizes, so the mask only trims the 64-bit host.
int bench_fold(int h, int v):
	return (h * 31 + v) & bench_mask32()


# xorshift32 (Marsaglia), width-independent: the left shifts are masked
# back to 32 bits and the right shift masks away the sign copies a
# 32-bit host's arithmetic shift would smear in from bit 31.
int bench_rand(int* state):
	int mask = bench_mask32()
	int x = state[0]
	x = x ^ ((x << 13) & mask)
	x = x ^ ((x >> 17) & 0x7fff)
	x = x ^ ((x << 5) & mask)
	state[0] = x
	return x
