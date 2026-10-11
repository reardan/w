# wbuild: x64
# wbuild: step="bin/wv2 x64 --no-expr-regs tests/expr_retarget_test.w -o bin/expr_retarget_noexpr_64_test"
# wbuild: step="bin/expr_retarget_noexpr_64_test"
# wbuild: step="bin/wv2 x64 --streaming tests/expr_retarget_test.w -o bin/expr_retarget_streaming_64_test"
# wbuild: step="bin/expr_retarget_streaming_64_test"
# wbuild: step="bin/wv2 x64 --no-regs tests/expr_retarget_test.w -o bin/expr_retarget_noregs_64_test"
# wbuild: step="bin/expr_retarget_noregs_64_test"
# Operand retargeting (unit O6, code_generator/x86.w's xrt_* section):
# a binary operator whose left operand A3 parked in a scratch register
# and whose right operand is a straight-line run of recorded
# accumulator instructions is re-emitted with the right operand
# computed into the scratch register ('mov rcx,r14; ror ecx,11; xor
# rax,rcx' instead of 'mov rcx,rax; mov rax,r14; ror eax,11; xor
# rax,rcx'), or, for a commutative operator whose left operand was one
# register read, constant or word load, with the right operand left in
# the accumulator and the left one read in place ('xor rax,r13').
# Every case below compares an expression of that shape against the
# same computation done one operator at a time through calls (a call
# is a gap in the trace, so the reference is never retargeted). The
# cases cover each way a park gets its operand (the accumulator, a
# register, a constant, a stack word, a memory word, a memory word
# addressed through the accumulator), each recorded instruction kind
# (register and constant moves, word and narrow loads from the stack
# and from memory, register/immediate/stack ALU operands, shifts and
# 32-bit rotates by a constant, not, neg), the non-commutative operators
# (sub, the compares as values and as branches), imul, a right operand
# whose last load becomes the operator's memory operand, nested
# retargets, a trace too long to record, and right operands that must
# not be retargeted (calls, stores). The steps build it again with
# --no-expr-regs (no parks, so no retargets), with --streaming (the
# other front end emits through the same entry points) and with
# --no-regs (every local on the stack): every build passes.
import lib.assert
import lib.lib


struct cell:
	int lo
	int hi


int xr(int a, int b):
	return a ^ b

int ad(int a, int b):
	return a + b

int sb(int a, int b):
	return a - b

int an(int a, int b):
	return a & b

int orr(int a, int b):
	return a | b

int ml(int a, int b):
	return a * b

int lt(int a, int b):
	return a < b

int rr(uint32 v, int n):
	return rotr(v, n)

int rl(uint32 v, int n):
	return rotl(v, n)

int sh32(uint32 v, int n):
	return shr(v, n)


int bump_count


int bump(int v):
	bump_count = bump_count + 1
	return v + 1


# --- the SHA-256 shapes: rotates, not, and/xor chains ----------------------
void test_sha_shapes(uint32 a, uint32 b, uint32 c, uint32 e, uint32 f, uint32 g):
	uint32 bs1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
	assert_equal(xr(xr(rr(e, 6), rr(e, 11)), rr(e, 25)), bs1)
	uint32 ch = (e & f) ^ (~e & g)
	assert_equal(xr(an(e, f), an(~e, g)), ch)
	uint32 maj = (a & b) ^ (a & c) ^ (b & c)
	assert_equal(xr(xr(an(a, b), an(a, c)), an(b, c)), maj)
	uint32 s0 = rotr(a, 7) ^ rotr(a, 18) ^ shr(a, 3)
	assert_equal(xr(xr(rr(a, 7), rr(a, 18)), sh32(a, 3)), s0)
	uint32 s1 = rotl(b, 5) ^ rotl(b, 13)
	assert_equal(xr(rl(b, 5), rl(b, 13)), s1)


# --- the park's operand from a register (folded park, form 1) ---------------
void test_register_left(int x, int y, int z):
	# commutative: the right operand stays in the accumulator
	assert_equal(xr(x, an(y, z) + 3), x ^ ((y & z) + 3))
	assert_equal(ad(x, orr(y << 2, z)), x + ((y << 2) | z))
	assert_equal(ml(x, an(ad(y, 5), 0x7fffffff)), x * ((y + 5) & 0x7fffffff))
	# non-commutative: the left operand comes back first
	assert_equal(sb(x, an(y, z) + 3), x - ((y & z) + 3))
	# compares: 'cmp R,rax' with R the left operand's register
	int c = x < ((y & z) + 3)
	assert_equal(lt(x, an(y, z) + 3), c)
	int hits = 0
	if (x > ((y | z) - 100)): hits = hits + 1
	if (x <= ((y ^ z) + 1)): hits = hits + 2
	int want = 0
	if (lt(orr(y, z) - 100, x)): want = want + 1
	if (lt(x, xr(y, z) + 2)): want = want + 2
	assert_equal(want, hits)


# --- the park's operand a constant (form 2) ---------------------------------
void test_constant_left(int y, int z):
	assert_equal(ad(5, an(y, z) + 1), 5 + ((y & z) + 1))
	assert_equal(ml(-3, orr(y, z) + 1), -3 * ((y | z) + 1))
	assert_equal(sb(100, an(y, z) + 1), 100 - ((y & z) + 1))
	assert_equal(sb(0, xr(y, z) + 1), 0 - ((y ^ z) + 1))
	assert_equal(sb(-7, xr(y, z) + 1), -7 - ((y ^ z) + 1))


# --- the park's operand a stack word (form 3) and narrow stack loads -------
void test_stack_left(int y, int z):
	int s = y * 3
	int* ps = &s     # address taken: s stays on the stack
	assert_equal(ad(s, an(y, z) + 1), s + ((y & z) + 1))
	assert_equal(sb(s, an(y, z) + 1), s - ((y & z) + 1))
	assert_equal(ml(s, orr(y, z) + 1), s * ((y | z) + 1))
	*ps = s + 1
	uint32 u = 4000000000
	uint32* pu = &u
	int32 n = -5
	int32* pn = &n
	# a narrow stack load as the whole right operand (the shuttle leaves
	# it to the retarget on x64)
	assert_equal(ad(y + 1, cast(int, u)), (y + 1) + u)
	assert_equal(ad(y * 2, -5), (y * 2) + n)
	assert_equal(sb(y * 2, -5), (y * 2) - n)
	assert_equal(ad(y, cast(int, u)), y + u)
	assert_equal(ad(cast(int, u), -5), u + n)
	assert_equal(s, y * 3 + 1)
	assert1(pu != 0 && pn != 0)
	# a stack word as a right-side ALU operand inside the trace, with
	# parks live around it
	int t = z + 11
	int* pt = &t
	int r = (y * 7) ^ ((z & 255) + t)
	assert_equal(xr(ml(y, 7), ad(an(z, 255), t)), r)
	int r2 = (y + 1) - ((z * 3) - ((y & 15) + t))
	assert_equal(sb(ad(y, 1), sb(ml(z, 3), ad(an(y, 15), t))), r2)
	assert1(pt != 0)


# --- the park's operand a memory word (form 4), memory right operands ------
void test_memory(int* k, int* w, int i, int y):
	assert_equal(ad(k[i], an(y, 7) + 1), k[i] + ((y & 7) + 1))
	assert_equal(sb(k[i], an(y, 7) + 1), k[i] - ((y & 7) + 1))
	assert_equal(ml(k[i + 1], orr(y, 1) + 1), k[i + 1] * ((y | 1) + 1))
	# a word load as the right operand's last instruction: 'add rax,[mem]'
	int t1 = (y ^ 3) + k[i] + w[i] + k[i + 1]
	assert_equal(ad(ad(ad(xr(y, 3), k[i]), w[i]), k[i + 1]), t1)
	assert_equal(sb(xr(y, 3), w[i]), (y ^ 3) - w[i])
	assert_equal(ml(xr(y, 3), w[i + 1]), (y ^ 3) * w[i + 1])
	assert_equal(lt(xr(y, 3), k[i]), (y ^ 3) < k[i])
	# through a pointer held in the accumulator
	int** rows = cast(int**, malloc(2 * __word_size__))
	rows[0] = k
	rows[1] = w
	assert_equal(ad(rows[1][i], an(y, 6) + 2), rows[1][i] + ((y & 6) + 2))
	assert_equal(sb(rows[0][i], an(y, 6) + 2), rows[0][i] - ((y & 6) + 2))
	assert_equal(ad(xr(y, 9), rows[1][i]), (y ^ 9) + rows[1][i])
	free(cast(void*, rows))
	cell c
	c.lo = y + 4
	c.hi = y * 5
	cell* pc = &c
	assert_equal(ad(xr(y, 1), ad(pc.hi, 2)), (y ^ 1) + (pc.hi + 2))
	assert_equal(xr(ml(y, 3), orr(pc.lo, 8)), (y * 3) ^ (pc.lo | 8))
	assert_equal(ad(an(y, 12), pc.lo), (y & 12) + *cast(int*, pc))


# --- unary, shifts, imul, sub inside the right operand ----------------------
void test_shapes(int a, int b, int c, int d, uint u):
	assert_equal(ad(ad(a, b), 0 - xr(c, d)), (a + b) + -(c ^ d))
	assert_equal(sb(xr(a, b), an(c, d)), (a ^ b) - (c & d))
	assert_equal(ml(ad(a, b), sb(c, d)), (a + b) * (c - d))
	assert_equal(ad(xr(a, b), c * 2), (a ^ b) + (c << 1))
	assert_equal(ad(xr(a, b), c >> 3), (a ^ b) + (c >> 3))
	assert_equal(ad(orr(a, 1), cast(int, u >> 5)), (a | 1) + cast(int, u >> 5))
	assert_equal(xr(an(a, 255), ml(c, 7) + 1), (a & 255) ^ ((c * 7) + 1))
	assert_equal(ad(xr(a, b), xr(~c, d) & 255), (a ^ b) + ((~c ^ d) & 255))


# --- nested retargets ---------------------------------------------------------
void test_nested(uint32 a, uint32 b, uint32 c, uint32 d, uint32 e):
	uint32 x = a ^ ((b & c) ^ rotr(d, 5))
	assert_equal(xr(a, xr(an(b, c), rr(d, 5))), x)
	int y = (a * 3) + (b ^ (c & (d | rotr(e, 3))))
	assert_equal(ad(ml(a, 3), xr(b, an(c, orr(d, rr(e, 3))))), y)
	int z = (a + 1) - ((b ^ rotl(c, 9)) - (d & (e + 7)))
	assert_equal(sb(ad(a, 1), sb(xr(b, rl(c, 9)), an(d, ad(e, 7)))), z)


# --- a trace longer than the recorder holds ----------------------------------
int long_chain(uint32 v, int x):
	return (x * 3) + (rotr(v, 1) ^ rotr(v, 2) ^ rotr(v, 3) ^ rotr(v, 4) ^ rotr(v, 5) ^ rotr(v, 6) ^ rotr(v, 7) ^ rotr(v, 8) ^ rotr(v, 9) ^ rotr(v, 10) ^ rotr(v, 11) ^ rotr(v, 12) ^ rotr(v, 13) ^ rotr(v, 14) ^ rotr(v, 15) ^ rotr(v, 16) ^ rotr(v, 17) ^ rotr(v, 18) ^ rotr(v, 19) ^ rotr(v, 20))


int long_chain_ref(uint32 v, int x):
	int h = 0
	int n = 1
	while (n <= 20):
		h = xr(h, rr(v, n))
		n = n + 1
	return ad(ml(x, 3), h)


# --- right operands that keep the A3 form ------------------------------------
void test_gaps(int a, int b):
	bump_count = 0
	int s = 0
	assert_equal(ad(xr(a, 1), bump(b) & 7), (a ^ 1) + (bump(b) & 7))
	assert_equal(2, bump_count)
	int r = (a ^ 1) + ((s = b & 7) + 1)
	assert_equal(ad(xr(a, 1), an(b, 7) + 1), r)
	assert_equal(an(b, 7), s)


int main():
	test_sha_shapes(0x6a09e667, cast(int, 0xbb67ae85), 0x3c6ef372, 0x510e527f, cast(int, 0x9b05688c), 0x1f83d9ab)
	test_sha_shapes(1, 2, 3, 4, 5, 6)
	test_register_left(1000, 77, 1234)
	test_register_left(-5, 3, 9)
	test_constant_left(77, 1234)
	test_constant_left(-77, 12)
	test_stack_left(41, 1234)
	test_stack_left(-9, 3)
	int* k = cast(int*, malloc(8 * __word_size__))
	int* w = cast(int*, malloc(8 * __word_size__))
	int i = 0
	while (i < 8):
		k[i] = i * 1000 + 17
		w[i] = 0 - i * 31
		i = i + 1
	test_memory(k, w, 2, 99)
	test_memory(k, w, 5, -3)
	free(cast(void*, k))
	free(cast(void*, w))
	test_shapes(1000, 77, 1234, -5, 123456)
	test_shapes(-1, 2, 3, 4, 5)
	test_nested(0x6a09e667, cast(int, 0xbb67ae85), 0x3c6ef372, 0x510e527f, cast(int, 0x9b05688c))
	test_nested(1, 2, 3, 4, 5)
	assert_equal(long_chain_ref(cast(int, 0x9b05688c), 7), long_chain(cast(int, 0x9b05688c), 7))
	assert_equal(long_chain_ref(12345, -2), long_chain(12345, -2))
	test_gaps(1000, 77)
	println(c"expr_retarget_test passed")
	return 0
