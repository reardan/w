/*
Deterministic PRNG for the assembler/disassembler property/fuzz tests
(docs/projects/assembler_disassembler.md, issue #171): tests/
asm_fuzz_x86_test.w, asm_fuzz_x64_test.w and asm_fuzz_arm64_test.w all
seed from ASM_FUZZ_SEED() and draw from this single xorshift32 stream, so
a failing run is 100% reproducible — re-running the same binary always
generates the exact same instruction sequence and fails at the same
iteration index. To reproduce a specific failure: note the printed seed
and iteration index from the failing run's output, then re-run the same
test binary (it always replays identically from a fixed seed; there is
no other source of nondeterminism). To chase a bug with more coverage,
set W_ASM_FUZZ_ITERS to a larger count (see asm_fuzz_iterations below);
the first ASM_FUZZ_DEFAULT_ITERS() draws of a longer run are byte-for-byte
the same as a shorter run's, so widening the run never changes where an
existing failure is found.

Compiled by bin/wv2 only (not part of the seed graph): ordinary language
features are fine here.
*/
import lib.lib
import lib.env


# Fixed across every run so failures reproduce; a plain decimal literal
# (not hex/0b) so the bit-31 literal warning does not apply.
int ASM_FUZZ_SEED():
	return 123456789


# Default iteration count per architecture for the conventional (CI-budget)
# fuzz targets; W_ASM_FUZZ_ITERS overrides it for a manual deeper run, e.g.
#   W_ASM_FUZZ_ITERS=200000 ./bin/asm_fuzz_x86_test
int ASM_FUZZ_DEFAULT_ITERS():
	return 3000


int fuzz_rng_state


void fuzz_seed(int seed):
	fuzz_rng_state = seed
	if (fuzz_rng_state == 0):
		fuzz_rng_state = 1


# Logical (unmasked-sign) right shift: an arithmetic '>>' smears the sign
# bit into the vacated high bits, which xorshift's diffusion step must not
# do (see lib/sha256.w's sha256_shr for the same idiom).
int fuzz_shr(int x, int n):
	return (x >> n) & ((1 << (32 - n)) - 1)


# xorshift32 (Marsaglia): one step of the state, also returned. The
# result is a full-range signed int (may be negative); fuzz_range()
# folds it into a bounded non-negative value.
int fuzz_next():
	int x = fuzz_rng_state
	x = x ^ (x << 13)
	x = x ^ fuzz_shr(x, 17)
	x = x ^ (x << 5)
	fuzz_rng_state = x
	return x


# Non-negative value in [0, bound). bound must be > 0.
int fuzz_range(int bound):
	int v = fuzz_next()
	if (v < 0):
		v = 0 - v
		if (v < 0):
			# v was INT_MIN, whose negation overflows back to itself.
			v = 0
	return v % bound


# Effective iteration count: W_ASM_FUZZ_ITERS if set to a positive
# integer, else ASM_FUZZ_DEFAULT_ITERS().
int asm_fuzz_iterations():
	char* v = env_get(c"W_ASM_FUZZ_ITERS")
	if (v == 0):
		return ASM_FUZZ_DEFAULT_ITERS()
	int n = atoi(v)
	if (n <= 0):
		return ASM_FUZZ_DEFAULT_ITERS()
	return n
