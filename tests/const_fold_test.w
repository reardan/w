# wbuild: x64
# wbuild: step="bin/wv2 --streaming tests/const_fold_test.w -o bin/const_fold_streaming_test"
# wbuild: step="bin/const_fold_streaming_test"
# wbuild: step="bin/wv2 x64 --streaming tests/const_fold_test.w -o bin/const_fold_streaming_64_test"
# wbuild: step="bin/const_fold_streaming_64_test"
# wbuild: step="bin/wv2 --no-regs --no-expr-regs tests/const_fold_test.w -o bin/const_fold_noregs_test"
# wbuild: step="bin/const_fold_noregs_test"
# wbuild: step="bin/wv2 x64 --no-regs --no-expr-regs tests/const_fold_test.w -o bin/const_fold_noregs_64_test"
# wbuild: step="bin/const_fold_noregs_64_test"
# Constants (unit O1, code_generator/x86.w's exact constant folding and
# const-global note, grammar/promote.w): a read of a const integer
# global or an enum constant is an immediate, integer constant
# expressions fold to the value the target computes (32-bit wrap on
# x86, 64-bit values with 'mov rax,imm64' on x64, the hardware's shift
# count masking), and the code after a 'return' or an unconditional
# jump is not emitted. Every folded value is checked against the same
# operation done at run time on values the compiler cannot see through
# (opaque()), and against a value written out by hand per word size.
# Runs under both front ends, and without register promotion and
# expression registers (the folds then see real pushes).
import lib.lib
import lib.assert


const int K = 5
const int M = K * 3 + 1
const int8 NEG8 = -3
const uint8 BIG8 = 200
const int16 NEG16 = -1234
const uint16 BIG16 = 60000
const int32 NEG32 = -100000
const uint32 HIGH32 = 0x80000000
const int UNSET
const bool YES = true
int mutable_global = 41

enum Color:
	RED
	GREEN = 7
	BLUE


int opaque(int x):
	return x


int classify(int x):
	if (x == K): return 1
	if (x == M): return 2
	return 0


int color_of(Color c):
	if (c == GREEN): return 1
	if (c == BLUE): return 2
	return 0


void test_const_globals():
	assert_equal(1, classify(5))
	assert_equal(2, classify(16))
	assert_equal(0, classify(6))
	assert_equal(21, K + M)
	assert_equal(opaque(5) + 16, K + M)
	assert_equal(-3, NEG8)
	assert_equal(200, BIG8)
	assert_equal(-1234, NEG16)
	assert_equal(60000, BIG16)
	assert_equal(-100000, NEG32)
	assert_equal(0, UNSET)
	assert_equal(1, YES)
	int x = opaque(10)
	assert_equal(15, x + K)
	assert_equal(50, x * K)
	assert_equal(2, x / K)
	assert_equal(0, x % K)
	assert_equal(320, x << K)
	assert_equal(-8, ~(K + 2))
	assert_equal(-5, -K)
	int bits = 0 - NEG8
	assert_equal(3, bits)
	# the address of a const global still names its storage
	int* p = cast(int*, &K)
	assert_equal(5, p[0])
	assert_equal(5, *&K)
	# a uint32 const with bit 31 set zero-extends on x64
	if (__word_size__ == 8): assert1(HIGH32 > 0)
	else: assert1(HIGH32 != 0)
	assert_equal(1, color_of(GREEN))
	assert_equal(2, color_of(BLUE))
	assert_equal(0, color_of(RED))
	assert_equal(8, BLUE)
	assert_equal(15, GREEN + BLUE)
	assert_equal(41, mutable_global)
	mutable_global = mutable_global + K
	assert_equal(46, mutable_global)


# A 64-bit value from a high 32-bit half and the low half's two 16-bit
# pieces, assembled at run time (x64 only: literals are 32-bit).
int w64(int hi, int mid, int low):
	return (opaque(hi) << 32) + (opaque(mid) << 16) + opaque(low)


int word_max():
	int top = 1 << (__word_size__ * 8 - 1)
	return top - 1


void test_shifts():
	int one = opaque(1)
	int bits = __word_size__ * 8
	assert_equal(one << (bits - 1), 1 << (__word_size__ * 8 - 1))
	assert_equal((one << (bits - 1)) - 1, word_max())
	assert_equal(1 << 63, one << 63)
	assert_equal(1 << 32, one << 32)
	assert_equal(1 << 31, one << 31)
	assert_equal(1 << 64, one << 64)
	assert_equal(1 << 40, one << 40)
	assert_equal(3 << 30, opaque(3) << 30)
	assert_equal(-1 >> 3, opaque(-1) >> 3)
	assert_equal(-64 >> 2, opaque(-64) >> 2)
	assert_equal(-16, -64 >> 2)
	assert_equal(0x7fff0000 >> 16, 0x7fff)
	assert_equal((1 << 40) >> 3, (one << 40) >> 3)
	assert_equal((1 << 40) >> 33, (one << 40) >> 33)
	assert_equal((-1 << 40) >> 36, (opaque(-1) << 40) >> 36)
	assert_equal(((1 << 40) + 5) << 3, ((one << 40) + 5) << 3)
	assert_equal(((1 << 40) + 5) << 33, ((one << 40) + 5) << 33)
	assert_equal(5 << 0, 5)
	if (__word_size__ == 8):
		assert_equal(w64(256, 0, 0), 1 << 40)
		assert_equal(w64(0x7fffffff, 0xffff, 0xffff), word_max())
		assert_equal(1, 1 << 64)
		assert_equal(w64(1, 0, 0), 1 << 32)
		assert_equal(w64(0, 0x8000, 0), 1 << 31)
	else:
		assert_equal(256, 1 << 40)
		assert_equal(2147483647, word_max())
		assert_equal(1, 1 << 32)
		assert_equal(-2147483647 - 1, 1 << 31)


void test_unsigned_shifts():
	uint u = cast(uint, opaque(-1))
	uint w = cast(uint, -1)
	assert1(u == w)
	assert1((u >> 4) == (w >> 4))
	assert1((u >> 0) == (w >> 0))
	uint big = cast(uint, opaque(1)) << (__word_size__ * 8 - 4)
	uint bigc = cast(uint, 1) << (__word_size__ * 8 - 4)
	assert1(big == bigc)
	assert1((big >> 2) == (bigc >> 2))
	assert1((big >> 32) == (bigc >> 32))
	assert1((big >> 33) == (bigc >> 33))
	assert1((big >> 31) == (bigc >> 31))
	uint m = cast(uint, -1) >> 1
	assert1(m == (u >> 1))


int mask32():
	int h = 1 << 16
	return h * h - 1


void test_products():
	int big = opaque(65536)
	assert_equal(big * big - 1, (1 << 16) * (1 << 16) - 1)
	assert_equal(mask32(), (1 << 16) * (1 << 16) - 1)
	assert_equal(big * big * big, (1 << 16) * (1 << 16) * (1 << 16))
	assert_equal(opaque(-7) * 123456789, -7 * 123456789)
	assert_equal(opaque(0x12345) * 0x6789a * 0x1f, 0x12345 * 0x6789a * 0x1f)
	assert_equal(opaque(-3) * (1 << 40), -3 * (1 << 40))
	assert_equal(opaque(2147483647) + 1, 2147483647 + 1)
	assert_equal(opaque(-2147483647) - 2, -2147483647 - 2)
	assert_equal(opaque(2147483647) * 2147483647, 2147483647 * 2147483647)
	assert_equal(0 - (opaque(-2147483647) - 1), 0 - (-2147483647 - 1))
	assert_equal(-(opaque(1) << 40), -(1 << 40))
	assert_equal((1 << 40) - (1 << 39), (opaque(1) << 40) - (opaque(1) << 39))
	assert_equal((1 << 40) + 7 - 3, (opaque(1) << 40) + 4)
	assert_equal(((1 << 40) | 3) & ((1 << 41) - 1), ((opaque(1) << 40) | 3) & ((opaque(1) << 41) - 1))
	assert_equal((1 << 40) ^ (1 << 33), (opaque(1) << 40) ^ (opaque(1) << 33))
	assert_equal(~(1 << 40), ~(opaque(1) << 40))
	assert_equal(~0, -1)
	assert_equal(12 & 10, 8)
	assert_equal(12 | 3, 15)
	assert_equal(12 ^ 10, 6)
	if (__word_size__ == 8):
		assert_equal(w64(0, 0xffff, 0xffff), mask32())
		assert_equal(w64(0, 0x8000, 0), 2147483647 + 1)
		assert_equal(w64(0x3fffffff, 0, 1), 2147483647 * 2147483647)
	else:
		assert_equal(-1, mask32())
		assert_equal(-2147483647 - 1, 2147483647 + 1)
		assert_equal(1, 2147483647 * 2147483647)


void test_division():
	assert_equal(opaque(100) / 7, 100 / 7)
	assert_equal(opaque(-100) / 7, -100 / 7)
	assert_equal(opaque(100) % 7, 100 % 7)
	assert_equal(opaque(-100) % 7, -100 % 7)
	assert_equal(opaque(100) % -7, 100 % -7)
	assert_equal(-14, -100 / 7)
	assert_equal(-2, -100 % 7)
	assert_equal(K * 4 / 3, 6)
	# a wide operand keeps the run-time division
	assert_equal((opaque(1) << 40) / 4, (1 << 40) / 4)
	assert_equal((opaque(1) << 40) % 1000, (1 << 40) % 1000)


int early(int x):
	if (x > 10): return 1
	elif (x > 5): return 2
	else: return 3


int both_arms(int x):
	if (x & 1):
		return 1
	else:
		return 0


int loop_find(int n):
	int i = 0
	while (i < 100):
		if (i * i >= n): return i
		i = i + 1
	return -1


int loop_break(int n):
	int i = 0
	while (1):
		if (i >= n):
			break
		i = i + 2
	return i


int nested(int a, int b):
	if (a > 0):
		if (b > 0): return 1
		return 2
	if (b > 0): return 3
	return 4


int after_label(int x):
	if (x == 0):
		goto out
	return 7
	out:
	return 9


void nothing():
	pass


void void_return(int* p):
	if (p[0] == 0):
		p[0] = 1
		return
	p[0] = 2


int scoped(int x):
	if (x > 0):
		int y = x * 2
		return y
	int z = x - 1
	return z


int switchy(int x):
	switch (x):
		case 1:
			return 10
		case 2:
			return 20
		default:
			return 30


void test_dead_code():
	assert_equal(1, early(11))
	assert_equal(2, early(6))
	assert_equal(3, early(1))
	assert_equal(1, both_arms(3))
	assert_equal(0, both_arms(4))
	assert_equal(4, loop_find(16))
	assert_equal(5, loop_find(17))
	assert_equal(-1, loop_find(100000))
	assert_equal(6, loop_break(5))
	assert_equal(1, nested(1, 1))
	assert_equal(2, nested(1, 0))
	assert_equal(3, nested(0, 1))
	assert_equal(4, nested(0, 0))
	assert_equal(9, after_label(0))
	assert_equal(7, after_label(1))
	nothing()
	int v = 0
	void_return(&v)
	assert_equal(1, v)
	void_return(&v)
	assert_equal(2, v)
	assert_equal(10, scoped(5))
	assert_equal(-6, scoped(-5))
	assert_equal(10, switchy(1))
	assert_equal(20, switchy(2))
	assert_equal(30, switchy(3))


int main():
	test_const_globals()
	test_shifts()
	test_unsigned_shifts()
	test_products()
	test_division()
	test_dead_code()
	print("const_fold_test: OK\n")
	return 0
