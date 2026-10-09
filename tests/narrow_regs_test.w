# wbuild: x64
# wbuild: step="bin/wv2 --no-narrow-regs tests/narrow_regs_test.w -o bin/narrow_regs_nonarrow_test"
# wbuild: step="bin/narrow_regs_nonarrow_test" expect_stdout="narrow_regs_test passed"
# wbuild: step="bin/wv2 x64 --no-narrow-regs tests/narrow_regs_test.w -o bin/narrow_regs_nonarrow_64_test"
# wbuild: step="bin/narrow_regs_nonarrow_64_test" expect_stdout="narrow_regs_test passed"
# wbuild: step="bin/wv2 --no-regs tests/narrow_regs_test.w -o bin/narrow_regs_noregs_test"
# wbuild: step="bin/narrow_regs_noregs_test" expect_stdout="narrow_regs_test passed"
# wbuild: step="bin/wv2 x64 --no-regs tests/narrow_regs_test.w -o bin/narrow_regs_noregs_64_test"
# wbuild: step="bin/narrow_regs_noregs_64_test" expect_stdout="narrow_regs_test passed"
# wbuild: step="bin/wv2 --inline tests/narrow_regs_test.w -o bin/narrow_regs_inline_test"
# wbuild: step="bin/narrow_regs_inline_test" expect_stdout="narrow_regs_test passed"
# wbuild: step="bin/wv2 x64 --inline tests/narrow_regs_test.w -o bin/narrow_regs_inline_64_test"
# wbuild: step="bin/narrow_regs_inline_64_test" expect_stdout="narrow_regs_test passed"
# Narrow integer promotion (unit A8, docs/projects/codegen_gap_plan.md
# §2.7; compiler/regalloc_scan.w's regalloc_type_ok and
# regalloc_reg_kind_of_type, code_generator/x86.w's regalloc_reg_kind
# and the register writers that consult it). An int32/uint32 local or
# argument of a function with a loop lives in a callee-saved register
# (r12-r15) or a loop register (rsi rdi r8-r11) on x64 and in esi/edi
# on x86, where the 32-bit types are the word. On x64 the register
# holds the value exactly as the stack path's load would promote it --
# zero-extended for uint32, sign-extended for int32 -- and every write
# is a 32-bit form ('mov r12d,eax', 'add r12d,1', 'movsxd r12,eax', ...),
# so wrap-around on add/sub/mul/shift/neg/not, sign versus zero
# extension into a wider expression, signed and unsigned comparisons,
# narrow arguments, narrow locals across calls (callee-saved registers
# and the loop registers' spill/reload around a hidden call), rotated
# loops, inlined callees (--inline) and the rotate intrinsics must all
# compute what the memory path computes. Every expected value below is
# written in host-portable form (no literal with bit 31 set; the mask
# is built at run time), so the same assertions hold on x86, where the
# wider context is the 32-bit word, and on x64. The twins build the
# test with --no-narrow-regs, --no-regs and --inline; regalloc_diff_test
# sweeps the whole suite the same way.
import lib.lib
import lib.assert


# 2^32 - 1 as a word: 4294967295 on x64, -1 on x86 (the product wraps).
int mask32():
	int h = 1 << 16
	return h * h - 1


# -2^31 as a word on either width: 1 << 31 is 2147483648 on x64 and
# the negative word on x86; negating it gives -2147483648 on both.
int min32():
	return 0 - (1 << 31)


# --- wrap-around on add, sub, mul -----------------------------------------
int u32_add_wrap(int n):
	uint32 u = mask32() - 2
	int i = 0
	while (i < n):
		u = u + 1
		i = i + 1
	return u


int i32_add_wrap(int n):
	int32 s = (1 << 30) + ((1 << 30) - 1)
	int i = 0
	while (i < n):
		s = s + 1
		i = i + 1
	return s


int u32_sub_wrap(int n):
	uint32 u = 1
	int i = 0
	while (i < n):
		u = u - 1
		i = i + 1
	return u


int i32_sub_wrap(int n):
	int32 s = min32() + 1
	int i = 0
	while (i < n):
		s = s - 1
		i = i + 1
	return s


int u32_mul_wrap(int n):
	uint32 u = 1
	int i = 0
	while (i < n):
		u = u * 65537
		i = i + 1
	return u


int i32_mul_wrap(int n):
	int32 s = 65536
	int i = 0
	while (i < n):
		s = s * 32768
		i = i + 1
	return s


# The in-place forms: 'op R,imm', 'op R,[esp+d]' and 'op R,R' (R3's
# binop fold at 32 bits), with a stack-resident and a register operand.
int u32_inplace(int n, int step):
	uint32 u = mask32() - 5
	uint32 v = 3
	int big = step * 2
	int i = 0
	while (i < n):
		u = u + step
		u = u + big
		u = u + v
		v = v + 1
		i = i + 1
	return u


int i32_inplace(int n, int step):
	int32 s = (1 << 30) + ((1 << 30) - 10)
	int32 t = 2
	int big = step * 2
	int i = 0
	while (i < n):
		s = s + step
		s = s + big
		s = s + t
		t = t + 1
		i = i + 1
	return s


void test_wrap():
	assert_equal(mask32() - 1, u32_add_wrap(1))
	assert_equal(mask32(), u32_add_wrap(2))
	assert_equal(0, u32_add_wrap(3))
	assert_equal(2, u32_add_wrap(5))
	assert_equal((1 << 30) + ((1 << 30) - 1), i32_add_wrap(0))
	assert_equal(min32(), i32_add_wrap(1))
	assert_equal(min32() + 4, i32_add_wrap(5))
	assert_equal(0, u32_sub_wrap(1))
	assert_equal(mask32(), u32_sub_wrap(2))
	assert_equal(mask32() - 2, u32_sub_wrap(4))
	assert_equal(min32(), i32_sub_wrap(1))
	assert_equal((1 << 30) + ((1 << 30) - 1), i32_sub_wrap(2))
	assert_equal(65537, u32_mul_wrap(1))
	assert_equal(131073, u32_mul_wrap(2))
	assert_equal(min32(), i32_mul_wrap(1))
	assert_equal(0, i32_mul_wrap(2))
	# u: 2^32 - 5, each step adds step + 2*step + v with v = 3, 4, ...
	assert_equal(0, u32_inplace(1, 1))
	assert_equal(7, u32_inplace(2, 1))
	assert_equal(15, u32_inplace(3, 1))
	# s: 2^31 - 10, each step adds step + 2*step + t with t = 2, 3, ...
	assert_equal((1 << 30) + ((1 << 30) - 2), i32_inplace(1, 2))
	assert_equal(min32() + 7, i32_inplace(2, 2))


# --- shifts, negation, complement ---------------------------------------------
int u32_shl(int n):
	uint32 u = 1
	int i = 0
	while (i < n):
		u = u << 1
		i = i + 1
	return u


int i32_shl_sar(int n):
	int32 s = 1
	int i = 0
	while (i < n):
		s = s << 1
		i = i + 1
	s = s >> 1
	return s


int u32_shr(int n):
	uint32 u = mask32()
	int i = 0
	while (i < n):
		u = u >> 4
		i = i + 1
	return u


# A variable count at or past the register's width: the shift runs on
# the promoted word (64-bit on x64, so the bits leave; 32-bit on x86,
# where the count is taken mod 32) and the store truncates, exactly
# as the stack path does on that width.
int u32_shl_count(int count):
	uint32 u = 5
	int i = 0
	while (i < 1):
		u = u << count
		i = i + 1
	return u


int i32_neg(int n):
	int32 s = min32()
	int i = 0
	while (i < n):
		s = 0 - s
		i = i + 1
	return s


int u32_neg(int n):
	uint32 u = 1
	int i = 0
	while (i < n):
		u = 0 - u
		i = i + 1
	return u


int u32_not(int n):
	uint32 u = 61680   # 0xf0f0
	int i = 0
	while (i < n):
		u = ~u
		i = i + 1
	return u


void test_shifts():
	assert_equal(1 << 31, u32_shl(31))
	assert_equal(0, u32_shl(32))
	assert_equal(0, i32_shl_sar(32))
	assert_equal(0 - (1 << 30), i32_shl_sar(31))
	assert_equal(1 << 29, i32_shl_sar(30))
	assert_equal((1 << 28) - 1, u32_shr(1))
	assert_equal((1 << 24) - 1, u32_shr(2))
	assert_equal(0, u32_shr(8))
	assert_equal(5 << 3, u32_shl_count(3))
	if (__word_size__ == 8): assert_equal(0, u32_shl_count(33))
	else: assert_equal(10, u32_shl_count(33))
	assert_equal(min32(), i32_neg(1))
	assert_equal(min32(), i32_neg(2))
	assert_equal(mask32(), u32_neg(1))
	assert_equal(1, u32_neg(2))
	assert_equal(mask32() - 61680, u32_not(1))
	assert_equal(61680, u32_not(2))


# --- sign and zero extension into a wider expression ---------------------
int i32_widen(int n):
	int32 s = 0 - 5
	int acc = 0
	int i = 0
	while (i < n):
		acc = acc + s * 2
		i = i + 1
	return acc


# u = 2^32 - 5: u / 2 is 2147483645 on both widths (an unsigned divide
# on x86, a divide of the zero-extended word on x64); (u + 10) & mask
# is 5 on both.
int u32_widen(int n, int* div_out):
	uint32 u = 0 - 5
	int sum = 0
	int i = 0
	while (i < n):
		sum = (sum + u + 10) & mask32()
		*div_out = u / 2
		i = i + 1
	return sum


# A negative int32 as an index: the extension is a sign extension, so
# the scaled index addresses the element the stack path addresses.
int i32_index(int* arr, int n):
	int32 s = 0 - 5
	int acc = 0
	int i = 0
	while (i < n):
		acc = acc + arr[s + 10]
		s = s + 1
		i = i + 1
	return acc


void test_extension():
	assert_equal(-30, i32_widen(3))
	int d = 0
	assert_equal(5, u32_widen(1, &d))
	assert_equal((1 << 30) + ((1 << 30) - 3), d)
	assert_equal(10, u32_widen(2, &d))
	int* arr = cast(int*, malloc(16 * __word_size__))
	int k = 0
	while (k < 16):
		arr[k] = k * 100
		k = k + 1
	assert_equal(500 + 600 + 700, i32_index(arr, 3))
	free(arr)


# --- comparisons ---------------------------------------------------------------
int i32_compare(int n):
	int32 a = 0 - 1
	int32 b = 1
	int hits = 0
	int i = 0
	while (i < n):
		if (a < b): hits = hits + 1
		if (a < 0): hits = hits + 10
		if (b > a): hits = hits + 100
		a = a - 1
		i = i + 1
	return hits


# ua = 2^32 - 1 compares above 1 on both widths: unsigned on x86, the
# zero-extended word on x64.
int u32_compare(int n):
	uint32 ua = 0 - 1
	uint32 ub = 1
	int hits = 0
	int i = 0
	while (i < n):
		if (ua > ub): hits = hits + 1
		if (ua < ub): hits = hits + 10
		if (ua == mask32()): hits = hits + 100
		if (ub == 1): hits = hits + 1000
		i = i + 1
	return hits


void test_compare():
	assert_equal(111, i32_compare(1))
	assert_equal(222, i32_compare(2))
	assert_equal(1101, u32_compare(1))


# --- narrow arguments ------------------------------------------------------
int narrow_args(int32 a, uint32 b, int n):
	int acc = 0
	int i = 0
	while (i < n):
		acc = acc + a * 3 + (b >> 28)
		a = a + 1
		b = b + 1
		i = i + 1
	return acc + a + (b & 15)


int32 narrow_return(int32 a, int n):
	int32 r = a
	int i = 0
	while (i < n):
		r = r * 2
		i = i + 1
	return r


void test_arguments():
	# acc -21 + 15, then a = -6 and b = 0
	assert_equal(-6 - 6 + 0, narrow_args(0 - 7, 0 - 1, 1))
	# acc -6 - 18 + 0, then a = -5 and b = 1
	assert_equal(-24 - 5 + 1, narrow_args(0 - 7, 0 - 1, 2))
	assert_equal(1 << 30, narrow_return(1, 30))
	assert_equal(min32(), narrow_return(1, 31))
	assert_equal(0, narrow_return(1, 32))
	assert_equal(-12, narrow_return(0 - 3, 2))


# --- across calls: callee-saved registers, and the loop registers' spill ---
int clobber(int x):
	int a = x * 3
	int b = a + 1
	int c = b * a
	return c - a - b


int narrow_across_calls(int n):
	uint32 u = mask32() - 1
	int32 s = min32() + 1
	int i = 0
	while (i < n):
		u = u + clobber(i) - clobber(i) + 1
		s = s - 1
		clobber(s)
		i = i + 1
	return (u & 255) + (s & 255) * 1000


# The loop has no visible call, so its narrow locals take loop
# registers; the list push is a hidden runtime call that spills and
# reloads them at the narrow width.
int narrow_hidden_call(int n):
	list[int] seen = new list[int]
	uint32 u = mask32()
	int32 s = min32()
	int i = 0
	while (i < n):
		u = u + 1
		s = s + 1
		int uw = u
		int sw = s
		seen.push(uw)
		seen.push(sw)
		i = i + 1
	return (seen[0] == u) + (seen[1] == s) * 10 + seen.length * 100 + (u & 255) * 1000 + (s & 255) * 100000


void test_calls():
	# u = 2^32 - 1, s = -2^31
	assert_equal(255 + 0 * 1000, narrow_across_calls(1))
	# u = 0, s = 2^31 - 1
	assert_equal(0 + 255 * 1000, narrow_across_calls(2))
	# seen = [0, -2^31 + 1], u = 0, s = -2^31 + 1
	assert_equal(1 + 10 + 200 + 0 + 1 * 100000, narrow_hidden_call(1))
	# seen = [0, -2^31 + 1, 1, -2^31 + 2], u = 1, s = -2^31 + 2
	assert_equal(0 + 0 + 400 + 1000 + 2 * 100000, narrow_hidden_call(2))


# --- a loop-local narrow declaration and rotated for loops --------------
int narrow_loop_local(int n):
	int acc = 0
	for i in range(n):
		uint32 t = mask32() - i
		t = t + 2
		int32 d = 0 - i
		d = d - 1
		acc = acc + t + d
	return acc


# Fibonacci modulo 2^32 through multi-assignment of two uint32 locals.
int u32_fib(int n):
	uint32 a = 0
	uint32 b = 1
	for i in range(n):
		a, b = b, a + b
	return a


void test_loops():
	assert_equal(1 - 1, narrow_loop_local(1))
	assert_equal((1 - 1) + (0 - 2), narrow_loop_local(2))
	assert_equal(55, u32_fib(10))
	assert_equal(1836311903, u32_fib(46))
	# fib(47) = 2971215073 = 2^31 + 823731425 still fits 32 bits;
	# fib(48) = 4807526976 wraps to 512559680
	assert_equal((1 << 31) + 823731425, u32_fib(47))
	assert_equal(512559680, u32_fib(48))


# --- compound assignment and increments ---------------------------------
int u32_compound(int n):
	uint32 u = mask32() - 3
	int i = 0
	while (i < n):
		u += 2
		u++
		u -= 1
		u *= 1
		u ^= 0
		u <<= 0
		u |= 0
		i = i + 1
	return u


int i32_compound(int n):
	int32 s = (1 << 30) + ((1 << 30) - 3)
	int i = 0
	while (i < n):
		s += 1
		s++
		s--
		s += 1
		i = i + 1
	return s


void test_compound():
	assert_equal(mask32() - 1, u32_compound(1))
	assert_equal(0, u32_compound(2))
	assert_equal(2, u32_compound(3))
	assert_equal((1 << 30) + ((1 << 30) - 1), i32_compound(1))
	assert_equal(min32() + 1, i32_compound(2))


# --- constants into narrow registers ----------------------------------------
int narrow_constants(int n):
	uint32 u = 0
	int32 s = 0
	int acc = 0
	int i = 0
	while (i < n):
		u = 0 - 1
		acc = acc + (u == mask32())
		u = 5
		acc = acc + u
		s = min32()
		acc = acc + (s < 0)
		s = 0 - 7
		acc = acc + s
		i = i + 1
	return acc


void test_constants():
	assert_equal(1 + 5 + 1 - 7, narrow_constants(1))
	assert_equal(0, narrow_constants(2))


# --- stores of narrow registers into memory -------------------------------
int narrow_stores(int* words, uint32* dwords, int n):
	uint32 u = mask32() - 1
	int32 s = min32()
	int i = 0
	while (i < n):
		words[i] = u
		dwords[i] = s
		words[i + 4] = s
		dwords[i + 4] = u
		u = u + 1
		s = s + 1
		i = i + 1
	return words[0] + dwords[0] + words[4] + dwords[4]


void test_stores():
	int* words = cast(int*, malloc(8 * __word_size__))
	uint32* dwords = cast(uint32*, malloc(8 * 4))
	int r = narrow_stores(words, dwords, 2)
	assert_equal(mask32() - 1, words[0])
	assert_equal(mask32(), words[1])
	assert_equal(1 << 31, dwords[0])
	assert_equal((1 << 31) + 1, dwords[1])
	assert_equal(min32(), words[4])
	assert_equal(mask32() - 1, dwords[4])
	assert_equal(mask32() - 1 + (1 << 31) + min32() + mask32() - 1, r)
	free(words)
	free(dwords)


# --- the rotate intrinsics on narrow operands --------------------------------
int narrow_rotates(int n):
	uint32 u = 305419896   # 0x12345678
	int acc = 0
	int i = 0
	while (i < n):
		u = rotr(u, 4)
		acc = acc + (u == (1 << 31) + 19088743)   # 0x81234567
		u = rotl(u, 4)
		acc = acc + (u == 305419896) * 10
		int32 s = rotr(u, 8)
		acc = acc + (s == 2014458966) * 100   # 0x78123456
		uint32 x = rotl(s, i + 8)
		acc = acc + (x == 305419896) * 1000
		i = i + 1
	return acc


void test_rotates():
	assert_equal(1111, narrow_rotates(1))
	assert_equal(1111 + 111, narrow_rotates(2))


# --- an inlined leaf callee with narrow parameters and locals -------------
int32 inl_step(int32 x):
	int32 y = x + 1
	return y * 2


uint32 inl_mix(uint32 a, uint32 b):
	uint32 t = a * 3 + b
	return t


int narrow_inline(int n):
	int32 s = (1 << 30) - 1
	uint32 u = mask32() - 2
	int i = 0
	while (i < n):
		s = inl_step(s)
		u = inl_mix(u, 7)
		i = i + 1
	return (s & 255) + (u & 255) * 1000


void test_inline():
	# s: 2^30 - 1 -> 2^31 (wraps to -2^31) ; u: (2^32 - 3) * 3 + 7 = 2^32 - 2
	assert_equal(0 + 254 * 1000, narrow_inline(1))
	# s: -2^31 + 1 -> 2^32 - 2 * (2^31 - 1)... (-2^31 + 1) * 2 = 2 ; u: (2^32 - 2) * 3 + 7 = 1
	assert_equal(2 + 1 * 1000, narrow_inline(2))


# --- register pressure past the budget -------------------------------------
int narrow_pressure(int n):
	uint32 a = 1
	uint32 b = 2
	uint32 c = 3
	uint32 d = 4
	uint32 e = 5
	uint32 f = 6
	uint32 g = 7
	uint32 h = 8
	int32 p = 0 - 1
	int32 q = 0 - 2
	int32 r = 0 - 3
	int32 s = 0 - 4
	int i = 0
	while (i < n):
		a = a + b + c + d
		b = b * 3 + e
		c = c ^ f
		d = d + g * h
		e = rotl(e, 3)
		f = f - a
		g = g + 1
		h = h << 2
		p = p + q
		q = q - r
		r = r * s
		s = s - 1
		i = i + 1
	return (a & 255) + (b & 255) * 256 + (c & 15) + (d & 15) + (e & 15) + (f & 15) + (g & 15) + (h & 15) + p + q + r + s


void test_pressure():
	assert_equal(1 + 2 * 256 + 3 + 4 + 5 + 6 + 7 + 8 - 1 - 2 - 3 - 4, narrow_pressure(0))
	# n = 1: a=10, b=11, c=3^6=5, d=4+56=60 (&15=12), e=rotl(5,3)=40 (&15=8),
	# f=6-10 (&15=12), g=8, h=32 (&15=0), p=-3, q=1, r=12, s=-5
	assert_equal(10 + 11 * 256 + 5 + 12 + 8 + 12 + 8 + 0 - 3 + 1 + 12 - 5, narrow_pressure(1))
	# n = 2: a=10+11+5+60=86, b=33+40=73, c=5^(2^32-4)=2^32-7 (&15=9),
	# d=60+8*32=316 (&15=12), e=rotl(40,3)=320 (&15=0), f=2^32-4-86 (&15=6),
	# g=9, h=128 (&15=0), p=-2, q=1-12=-11, r=12*-5=-60, s=-6
	assert_equal(86 + 73 * 256 + 9 + 12 + 0 + 6 + 9 + 0 - 2 - 11 - 60 - 6, narrow_pressure(2))


int main():
	test_wrap()
	test_shifts()
	test_extension()
	test_compare()
	test_arguments()
	test_calls()
	test_loops()
	test_compound()
	test_constants()
	test_stores()
	test_rotates()
	test_inline()
	test_pressure()
	println(c"narrow_regs_test passed")
	return 0
