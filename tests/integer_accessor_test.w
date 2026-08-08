# wbuild: x64
#
# Differential test for code_generator/integer.w's save_*/load_* family.
# The accessors were byte-at-a-time loops; they now issue native
# width-n loads and stores (a ~97% instruction-count drop on the
# compiler's hot path). This pins the observable contract that the loops
# defined -- exact store width, no neighbour clobber, and the
# zero/sign-extension each loader produced -- by checking every accessor
# against a reference implementation of the original loops.
import lib.testing
import lib.memory
import code_generator.integer


# The pre-optimization implementations, kept verbatim as the oracle.
void ref_save_i(char* p, int v, int n):
	int i = 0
	while (i < n):
		p[i] = v
		v = v >> 8
		i = i + 1


int ref_load_i(char* p, int n):
	int result = 0
	while (n > 0):
		result = (result << 8) + (p[n - 1] & 255)
		n = n - 1
	return result


int ref_load_int32(char* p):
	int result = ref_load_i(p, 4)
	if (__word_size__ == 8):
		result = (result << 32) >> 32
	return result


# Deterministic 32-bit LCG: the values under test must include negatives,
# high-bit-set patterns and small ints, on every run and every target.
int rng_state


int next_rand():
	rng_state = rng_state * 1103515245 + 12345
	return rng_state


# Both buffers are poisoned, written through the two implementations at
# the same offset, then compared byte for byte -- so a store that is too
# wide shows up as a neighbour mismatch, not just a wrong value.
void poison(char* p, int n):
	int i = 0
	while (i < n):
		p[i] = 0 - 86 /* 0xaa */
		i = i + 1


void assert_same_bytes(char* a, char* b, int n, char* what):
	int i = 0
	while (i < n):
		if ((a[i] & 255) != (b[i] & 255)):
			print(what)
			print(c": byte mismatch at offset ")
			print_int(c"", i)
			print(c"\x0a")
			assert_equal(a[i] & 255, b[i] & 255)
		i = i + 1


void test_accessors_match_the_byte_loops():
	rng_state = 987654321
	char* got = malloc(64)
	char* want = malloc(64)

	# Every width the generic entry points accept, at both an aligned and
	# a deliberately unaligned offset -- the symbol table packs 4-byte
	# fields at offset 2 (compiler/symbol_table.w), so unaligned access
	# is a live requirement, not a hypothetical.
	int trial = 0
	while (trial < 2000):
		int v = next_rand()
		int n = 1 + (((next_rand() >> 8) & 7) % 8)
		int off = (next_rand() >> 8) & 7
		poison(got, 64)
		poison(want, 64)
		save_i(&got[off], v, n)
		ref_save_i(&want[off], v, n)
		assert_same_bytes(got, want, 64, c"save_i")
		assert_equal(ref_load_i(&want[off], n), load_i(&got[off], n))
		trial = trial + 1

	# The named wrappers, against the widths and extensions they promised.
	trial = 0
	while (trial < 2000):
		int v = next_rand()
		int off = (next_rand() >> 8) & 7
		poison(got, 64)
		poison(want, 64)

		save_int8(&got[off], v)
		ref_save_i(&want[off], v, 1)
		assert_same_bytes(got, want, 64, c"save_int8")
		assert_equal(ref_load_i(&want[off], 1), load_int8(&got[off]))

		save_int16(&got[off + 8], v)
		ref_save_i(&want[off + 8], v, 2)
		assert_same_bytes(got, want, 64, c"save_int16")
		assert_equal(ref_load_i(&want[off + 8], 2), load_int16(&got[off + 8]))

		save_int32(&got[off + 16], v)
		ref_save_i(&want[off + 16], v, 4)
		assert_same_bytes(got, want, 64, c"save_int32")
		assert_equal(ref_load_int32(&want[off + 16]), load_int32(&got[off + 16]))

		save_int(&got[off + 24], v)
		ref_save_i(&want[off + 24], v, 4)
		assert_same_bytes(got, want, 64, c"save_int")
		assert_equal(ref_load_int32(&want[off + 24]), load_int(&got[off + 24]))

		save_int64(&got[off + 32], v)
		ref_save_i(&want[off + 32], v, 8)
		assert_same_bytes(got, want, 64, c"save_int64")
		assert_equal(ref_load_i(&want[off + 32], 8), load_int64(&got[off + 32]))

		save_ptr(&got[off + 48], v)
		ref_save_i(&want[off + 48], v, __word_size__)
		assert_same_bytes(got, want, 64, c"save_ptr")
		assert_equal(ref_load_i(&want[off + 48], __word_size__), load_ptr(&got[off + 48]))

		trial = trial + 1

	# A pointer slot must survive a full host word, including an address
	# above 4 GB on a 64-bit host -- the reason save_ptr exists at all.
	# The constant is assembled at runtime: a >32-bit literal is rejected
	# outright, and this file also compiles for the 32-bit target.
	if (__word_size__ == 8):
		int high = 0x7f123456
		int wide = (high << 16) | 0x7890
		save_ptr(&got[0], wide)
		assert_equal(wide, load_ptr(&got[0]))

	# A -1 in a 4-byte field still reads back as -1, not 0xffffffff.
	save_int32(&got[3], 0 - 1)
	assert_equal(0 - 1, load_int32(&got[3]))
	# ...while the 2- and 1-byte loaders stay zero-extending.
	save_int16(&got[3], 0 - 1)
	assert_equal(65535, load_int16(&got[3]))
	save_int8(&got[3], 0 - 1)
	assert_equal(255, load_int8(&got[3]))

