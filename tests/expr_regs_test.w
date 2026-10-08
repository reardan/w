# wbuild: x64
# wbuild: step="bin/wv2 --no-expr-regs tests/expr_regs_test.w -o bin/expr_regs_noexpr_test"
# wbuild: step="bin/expr_regs_noexpr_test"
# wbuild: step="bin/wv2 x64 --no-expr-regs tests/expr_regs_test.w -o bin/expr_regs_noexpr_64_test"
# wbuild: step="bin/expr_regs_noexpr_64_test"
# wbuild: step="bin/wv2 --no-regs tests/expr_regs_test.w -o bin/expr_regs_noregs_test"
# wbuild: step="bin/expr_regs_noregs_test"
# wbuild: step="bin/wv2 x64 --no-regs tests/expr_regs_test.w -o bin/expr_regs_noregs_64_test"
# wbuild: step="bin/expr_regs_noregs_64_test"
# wbuild: step="bin/wv2 --inline tests/expr_regs_test.w -o bin/expr_regs_inline_test"
# wbuild: step="bin/expr_regs_inline_test"
# wbuild: step="bin/wv2 x64 --inline tests/expr_regs_test.w -o bin/expr_regs_inline_64_test"
# wbuild: step="bin/expr_regs_inline_64_test"
# wbuild: step="bin/wv2 --no-inline --no-loop-rotate tests/expr_regs_test.w -o bin/expr_regs_noinline_test"
# wbuild: step="bin/expr_regs_noinline_test"
# wbuild: step="bin/wv2 x64 --no-inline --no-loop-rotate tests/expr_regs_test.w -o bin/expr_regs_noinline_64_test"
# wbuild: step="bin/expr_regs_noinline_64_test"
# The expression register stack (docs/projects/codegen_gap_plan.md §2.3,
# unit A3; code_generator/x86.w's ers_* section): a binary operator's
# left operand, and the address or loaded value an assignment keeps for
# its store, wait in a scratch register (x64: rcx rdx r8-r11, x86: ecx
# edx) instead of on the stack while the other side runs, and go to the
# real stack only when the sequence is exhausted or something between
# the park and its use may write the register: a call, a branch, a
# variable shift, a division. Every case asserts computed values only,
# so it passes whether or not a given operand was parked -- what it
# pins is that parking never changes what a program computes: through
# sequence exhaustion (eight nested parks), calls, shifts by a variable,
# division and modulo at every nesting position, ternaries and
# condition chains as operands of parked expressions and vice versa,
# loops that own r8-r11 (R3), the SHA-256 rotate idiom, struct-returning
# calls, floats, defer, compound assignment through parked addresses,
# the limb and bit intrinsics, atomics, narrow stores, pointer
# arithmetic and comparisons. The extra steps build the same program
# with --no-expr-regs and --no-regs, with --inline (unit A5: a parked
# operand at a call site whose callee's body is emitted in place) and
# with --no-inline --no-loop-rotate (unit A7: the rotated loops below
# top-tested again): every build must pass the same assertions.
import lib.assert
import lib.lib


struct pair:
	int a
	int b


struct wide:
	int8 tag
	int16 half
	int32 word
	int full


int identity(int v):
	return v


int add3(int a, int b, int c):
	return a + b + c


pair make_pair(int a, int b):
	pair p
	p.a = a
	p.b = b
	return p


int global_hits


int counted(int v):
	global_hits = global_hits + 1
	return v


# --- nesting past the sequence: eight parks live at once ---------------------
int deep_right(int a, int b, int c, int d, int e, int f, int g, int h, int i):
	# every '-' parks its left operand while the parenthesized right
	# side runs: nine operands, eight parks deep
	return a - (b - (c - (d - (e - (f - (g - (h - i)))))))


int deep_mixed(int a, int b, int c, int d, int e, int f, int g, int h, int i):
	return (a * (b + (c * (d + (e * (f + (g * (h + i)))))))) & 0xffff


int deep_with_calls(int a, int b, int c, int d, int e):
	return a - (counted(b) - (c - (counted(d) - (e - (counted(a) - (b - (c - counted(d))))))))


void test_deep():
	assert_equal(5, deep_right(1, 2, 3, 4, 5, 6, 7, 8, 9))
	assert_equal(7678, deep_mixed(2, 3, 4, 5, 6, 7, 8, 9, 10))
	global_hits = 0
	assert_equal(5, deep_with_calls(1, 2, 3, 4, 5))
	assert_equal(4, global_hits)
	# the parks survive across a deep nesting on the left as well
	int x = ((((((((1 + 2) * 3) - 4) * 5) + 6) * 7) - 8) * 9)
	assert_equal(1881, x)


# --- calls, variable shifts, division and modulo at every position ---------
int hazards_left(int a, int b, int s):
	return (a << s) + (b >> s) + (a / b) + (a % b) + (a << 3) + (b >> 1)


int hazards_right(int a, int b, int s):
	return a + (b << s) - (a >> s) * (b / 2) + (a % 7)


int hazards_nested(int a, int b, int s):
	# a park, then a shift by a variable inside the right operand, then
	# more parks under it
	return a * ((b << s) + (a / ((b >> s) + 1)) + ((a % b) << 1)) - (a + ((b << (s + 1)) % 5))


int hazards_calls(int a, int b, int s):
	return (a + identity(b << s)) * (identity(a) / (b + 1)) + (identity(a % b) + (b << identity(s)))


uint unsigned_shifts(uint a, uint b, uint s):
	return (a >> s) + (b >> 2) + ((a + b) >> s) + (a >> (s + 1))


void test_hazards():
	int a = 1000
	int b = 7
	assert_equal(16151, hazards_left(a, b, 3))
	assert_equal(687, hazards_right(a, b, 3))
	assert_equal(1066998, hazards_nested(a, b, 3))
	assert_equal(132062, hazards_calls(a, b, 3))
	uint ua = 0x70000000
	uint ub = 48
	uint us = 4
	assert_equal(293601295, cast(int, unsigned_shifts(ua, ub, us)))
	# a park below a variable shift's count (the count goes to cl)
	int s = 5
	int v = a + (b << s) + (a >> s)
	assert_equal(1255, v)
	# the division's high half (edx) and a park below it
	int q = b + a / 3 + a % 3 + b * (a / 7)
	assert_equal(1335, q)


# --- ternaries and condition chains as operands and as hosts ---------------
int tern_operand(int a, int b, int c):
	return a + (b > c ? b - c : c - b) * 2


int tern_host(int a, int b, int c):
	return (a + b > c ? a + b + c : a * b * c) - (a - b < c ? 1 : 2)


int chain_operand(int a, int b, int c):
	return a + (b && c) * 10 + (a || b) * 100 + (b > 1 && c > 1) * 1000


int chain_host(int a, int b, int c):
	int r = 0
	if (a + b * c > 10 && a - b < c): r = r + 1
	if (a * 2 + b * 3 == c || a + b + c == 6): r = r + 2
	if (!(a + b > c) || !(a - b > c)): r = r + 4
	return r


int nested_tern(int a, int b):
	return (a > b ? (a > 2 * b ? a + b : a - b) : (b > 2 * a ? b + a : b - a)) + a * b


void test_branches():
	assert_equal(1 + (5 - 2) * 2, tern_operand(1, 5, 2))
	assert_equal(1 + (5 - 2) * 2, tern_operand(1, 2, 5))
	assert_equal((2 + 3 + 4) - 1, tern_host(2, 3, 4))
	assert_equal((1 * 1 * 9) - 1, tern_host(1, 1, 9))
	assert_equal(1 + 10 + 100 + 1000, chain_operand(1, 2, 3))
	assert_equal(0 + 0 + 0 + 0, chain_operand(0, 0, 3))
	assert_equal(2 + 4, chain_host(1, 2, 3))
	assert_equal(0, chain_host(10, 1, 1))
	assert_equal((7 + 2) + 14, nested_tern(7, 2))
	assert_equal((3 - 2) + 6, nested_tern(3, 2))
	assert_equal((7 + 2) + 14, nested_tern(2, 7))


# --- loops owning caller-saved registers (R3) ---------------------------------
int loop_pressure(int n):
	int s = 0
	int t = 1
	int u = 2
	int v = 3
	int w = 4
	int i = 0
	while (i < n):
		# r8-r11 may belong to the loop's locals: the parks must use
		# only what is left and spill past it
		s = s + (t * (u + (v * (w + (i * (s + (t - u)))))))
		t = (t + u * 3) & 1023
		u = (u + v * 5 - (w * 2 + (i * 7 - s))) & 1023
		v = (v ^ (t << 3) ^ (u >> 2)) & 1023
		w = (w + (s & 15)) * 3 & 1023
		i = i + 1
	return s + t + u + v + w


int loop_reference(int n):
	int s = 0
	int t = 1
	int u = 2
	int v = 3
	int w = 4
	int i = 0
	while (i < n):
		int p1 = w + (i * (s + (t - u)))
		int p2 = v * p1
		int p3 = u + p2
		int p4 = t * p3
		s = s + p4
		int t1 = u * 3
		t = (t + t1) & 1023
		int u1 = v * 5
		int u2 = w * 2
		int u3 = i * 7
		int u4 = u3 - s
		int u5 = u2 + u4
		u = (u + u1 - u5) & 1023
		int v1 = t << 3
		int v2 = u >> 2
		v = (v ^ v1 ^ v2) & 1023
		int w1 = s & 15
		w = (w + w1) * 3 & 1023
		i = i + 1
	return s + t + u + v + w


int loop_with_calls(int n):
	int s = 0
	int t = 3
	int i = 0
	while (i < n):
		s = s + t * (counted(i) + (t * (i + counted(s & 7))))
		t = (t + s) & 255
		i = i + 1
	return s + t


void test_loops():
	assert_equal(loop_reference(50), loop_pressure(50))
	assert_equal(loop_reference(7), loop_pressure(7))
	global_hits = 0
	int r = loop_with_calls(20)
	assert_equal(40, global_hits)
	int s = 0
	int t = 3
	int i = 0
	while (i < 20):
		int c1 = i
		int c2 = s & 7
		int m = t * (i + c2)
		s = s + t * (c1 + m)
		t = (t + s) & 255
		i = i + 1
	assert_equal(s + t, r)


# --- the SHA-256 rotate idiom (lib/sha256.w's inline rounds) -----------------
int rotr32_lit(int x):
	int mask = 0xffff + (0xffff << 16)
	return ((((x >> 7) & 0x1ffffff) | (x << 25)) ^ (((x >> 18) & 0x3fff) | (x << 14)) ^ ((x >> 3) & 0x1fffffff)) & mask


int rotr32_var(int x, int n):
	int mask = 0xffff + (0xffff << 16)
	int low = (1 << (32 - n)) - 1
	return (((x >> n) & low) | (x << (32 - n))) & mask


int round_like(int a, int b, int c, int e, int f, int g):
	int mask = 0xffff + (0xffff << 16)
	int bs1 = (((e >> 6) & 0x3ffffff) | (e << 26)) ^ (((e >> 11) & 0x1fffff) | (e << 21)) ^ (((e >> 25) & 0x7f) | (e << 7))
	int ch = (e & f) ^ ((e ^ mask) & g)
	int bs0 = (((a >> 2) & 0x3fffffff) | (a << 30)) ^ (((a >> 13) & 0x7ffff) | (a << 19)) ^ (((a >> 22) & 0x3ff) | (a << 10))
	int maj = (a & b) ^ (a & c) ^ (b & c)
	return ((bs1 & mask) + ch + (bs0 & mask) + maj) & mask


void test_rotate():
	int x = 0x12345678
	int r7 = rotr32_var(x, 7)
	int r18 = rotr32_var(x, 18)
	int s3 = (x >> 3) & 0x1fffffff
	assert_equal((r7 ^ r18 ^ s3) & (0xffff + (0xffff << 16)), rotr32_lit(x))
	assert_equal(0x091a2b3c, rotr32_var(0x12345678, 1))
	assert_equal(0x78123456, rotr32_var(0x12345678, 8))
	int v = round_like(0x6a09e667, 0x3b67ae85, 0x3c6ef372, 0x510e527f, 0x1b05688c, 0x1f83d9ab)
	# the reference computes the same thing one operator at a time
	int mask = 0xffff + (0xffff << 16)
	int e = 0x510e527f
	int t1 = ((e >> 6) & 0x3ffffff) | (e << 26)
	int t2 = ((e >> 11) & 0x1fffff) | (e << 21)
	int t3 = ((e >> 25) & 0x7f) | (e << 7)
	int bs1 = t1 ^ t2 ^ t3
	int ne = e ^ mask
	int ch = (e & 0x1b05688c) ^ (ne & 0x1f83d9ab)
	int a = 0x6a09e667
	int u1 = ((a >> 2) & 0x3fffffff) | (a << 30)
	int u2 = ((a >> 13) & 0x7ffff) | (a << 19)
	int u3 = ((a >> 22) & 0x3ff) | (a << 10)
	int bs0 = u1 ^ u2 ^ u3
	int maj = (a & 0x3b67ae85) ^ (a & 0x3c6ef372) ^ (0x3b67ae85 & 0x3c6ef372)
	int want = ((bs1 & mask) + ch + (bs0 & mask) + maj) & mask
	assert_equal(want, v)


# --- struct-returning calls as operands ---------------------------------------
int struct_operands(int x, int y):
	pair p = make_pair(x, y)
	return p.a * 10 + make_pair(y, x).a + (p.b + make_pair(x + y, x - y).b * 100) + make_pair(p.a, p.b).b * make_pair(1, 2).b


void test_struct_calls():
	assert_equal(3 * 10 + 4 + (4 + (3 - 4) * 100) + 4 * 2, struct_operands(3, 4))
	pair q
	q = make_pair(5, 6)
	int s = q.a + make_pair(q.b, q.a).b * 3
	assert_equal(5 + 5 * 3, s)
	pair[4] arr
	int i = 1
	arr[i + 1] = make_pair(7, 8)
	assert_equal(7, arr[2].a)
	assert_equal(8, arr[2].b)
	arr[i] = make_pair(arr[i + 1].b + 1, arr[i + 1].a - 1)
	assert_equal(9, arr[1].a)
	assert_equal(6, arr[1].b)


# --- floats mixed in -----------------------------------------------------------
int float_mix(int a, int b):
	float f = 1.5
	float g = 2.5
	float h = f * g + f
	int w = a + cast(int, h) * b
	float k = cast(float, a) * g + cast(float, b)
	return w + cast(int, k) + (a * (b + cast(int, f + g)))


void test_floats():
	assert_equal((3 + 5 * 4) + 11 + (3 * (4 + 4)), float_mix(3, 4))


# --- an expression spanning a defer-bearing scope ----------------------------
int defer_total


int with_defer(int a, int b):
	defer defer_total = defer_total + a * (b + 1)
	int r = a + (b * (a + identity(b)))
	if (a > b): return r * (a - b) + b * (a + b)
	return r - (a * b + (b - a) * 3)


void test_defer():
	defer_total = 0
	assert_equal((5 + (2 * (5 + 2))) * 3 + 2 * 7, with_defer(5, 2))
	assert_equal(5 * 3, defer_total)
	defer_total = 0
	assert_equal((2 + (5 * (2 + 5))) - (2 * 5 + 3 * 3), with_defer(2, 5))
	assert_equal(2 * 6, defer_total)


# --- compound assignment through parked addresses ----------------------------
void test_compound():
	int[8] arr
	int i = 0
	while (i < 8):
		arr[i] = i * 3
		i = i + 1
	int j = 2
	arr[j + 1] += arr[j] * (arr[j + 2] + 4)
	assert_equal(9 + 6 * 16, arr[3])
	arr[j] -= identity(arr[j + 1]) - (j * 2)
	assert_equal(6 - 105 + 4, arr[2])
	arr[j * 2] *= arr[j - 1] + (arr[j] << 1)
	assert_equal(12 * (3 + (-95 << 1)), arr[4])
	arr[j + 3] |= (arr[j] & 0xff) ^ (arr[j + 1] >> j)
	assert_equal(15 | ((-95 & 0xff) ^ (105 >> 2)), arr[5])
	arr[identity(j) + 4] += (arr[j + 1] % 7) + (arr[j + 2] / 2)
	assert_equal(18 + 0 - 1122, arr[6])
	arr[7]++
	arr[j + 5]++
	++arr[j + 5]
	assert_equal(24, arr[7])
	arr[j + 5]--
	assert_equal(23, arr[7])
	wide w
	w.tag = 3
	w.half = 300
	w.word = 70000
	w.full = 1
	wide* p = &w
	p.tag += p.half / 100 + (p.word >> 16)
	assert_equal(3 + 3 + 1, p.tag)
	p.half -= (p.tag * 10) + (p.full << 2)
	assert_equal(300 - 70 - 4, p.half)
	p.word += p.half * (p.tag + p.full)
	assert_equal(70000 + 226 * 8, p.word)
	p.full = p.word + (p.half * (p.tag + 100)) - identity(p.tag)
	assert_equal(71808 + 226 * 107 - 7, p.full)
	int* q = &arr[1]
	*q += arr[2] * (arr[3] - arr[4])
	assert_equal(3 + (-95) * (105 - (-2244)), arr[1])
	# a parked lhs address buried under a struct-returning call
	arr[j] = make_pair(arr[j + 1], arr[j + 2]).b + make_pair(j, j).a
	assert_equal(-2244 + 2, arr[2])
	# a multiple assignment with parked right sides
	int a = 3
	int b = 4
	a, b = b + (a * 2), a - (b * 2)
	assert_equal(10, a)
	assert_equal(-5, b)


# --- the limb and bit intrinsics, atomics ------------------------------------
void test_intrinsics():
	int high = 0
	int a = 0x12345
	int b = 0xabcd
	int r = a + mul_wide(a + 1, b * 2, &high) + (high * 7)
	assert_equal(0x12345 + ((0x86f2 << 16) + 0x021c) + 7, r)
	int carry = 0
	int s = b + add_carry(0xffff + (0xffff << 16), a + b, &carry) * 2 + carry * 3
	assert_equal(b + ((a + b - 1) & (0xffff + (0xffff << 16))) * 2 + 3, s)
	int hi = a * mul_hi(0xffff + (0xffff << 16), 0xffff + (0xffff << 16)) + b
	assert_equal(a * (0xfffe + (0xffff << 16)) + b, hi)
	int bits = a + popcount(b + a) * 3 + (clz(a >> 2) + ctz(b << 3)) * (a & 7)
	assert_equal(0x12345 + 9 * 3 + (17 + 3) * 5, bits)
	int rot = a + rotl(b, 8) + (rotr(a, 4) ^ shr(b, 2))
	assert_equal(a + 0xabcd00 + ((0x50001234) ^ 0x2af3), rot)
	int value = 10
	int t = a + atomic_add(&value, b + 2) * 2 + (atomic_cas(&value, a + 10, b * 3) & 0xffff)
	assert_equal(a + 10 * 2 + ((10 + 0xabcd + 2) & 0xffff), t)
	assert_equal(10 + 0xabcd + 2, value)


# --- narrow stores and pointer arithmetic ---------------------------------------
void test_narrow():
	char[16] bytes
	int16[8] halves
	int32[8] words
	int i = 3
	int j = 2
	int k = 0
	while (k < 16):
		bytes[k] = 0
		k = k + 1
	k = 0
	while (k < 8):
		halves[k] = 0
		words[k] = 0
		k = k + 1
	bytes[i + j] = (i * 40) + (j * 3)
	assert_equal(126, bytes[5])
	bytes[i * j] = bytes[i + j] - (i * (j + 1))
	assert_equal(117, bytes[6])
	halves[i - j] = (bytes[5] * 100) + (bytes[6] * (i - 1))
	assert_equal(12600 + 234, halves[1])
	words[j] = halves[1] * (bytes[5] + (bytes[6] * i))
	assert_equal(12834 * (126 + 351), words[2])
	char* p = cast(char*, bytes)
	(p + i)[j] = (p + 1)[4] + 1
	assert_equal(127, bytes[5])
	int[6] ints
	k = 0
	while (k < 6):
		ints[k] = k + 1
		k = k + 1
	int* q = &ints[i]
	assert_equal(5 + 3 * 3, q[1] + (&q[-1])[0] * 3)
	assert_equal(4 + 2 * (6 - 1), *q + 2 * (q[2] - (q + 0)[-3]))


# --- comparisons with parked operands ----------------------------------------
int compares(int a, int b, int c):
	int r = 0
	r = r + ((a + b * c) < (c + a * b))
	r = r + ((a * b - c) == (b * a - c)) * 2
	r = r + ((a + b + c) > (a * b * c)) * 4
	r = r + ((a - (b + c)) != (a - b - c)) * 8
	r = r + ((b + (c * (a + 1))) <= (c + (b * (a + 1)))) * 16
	r = r + ((identity(a) + b) >= (c + identity(b))) * 32
	uint ua = a
	uint ub = b
	r = r + ((ua + ub * 2) < (ub + ua * 2)) * 64
	return r


void test_compares():
	assert_equal(2, compares(2, 3, 4))
	assert_equal(2 + 4 + 16 + 32, compares(1, 1, 1))


# --- argument lists: parks around and inside pushes ---------------------------
void test_args():
	int a = 3
	int b = 4
	int r = a + add3(a * b, b + (a * (b + 1)), add3(a, b, a + b) * 2) * (b - 1)
	assert_equal(3 + (12 + 19 + 28) * 3, r)
	int s = add3(a + b, a - b, a * b) + (a + add3(b, a + b, b * (a + add3(1, 2, 3))))
	assert_equal(18 + (3 + (4 + 7 + 36)), s)


# --- rotated loops (A7): parks and the loop's control-flow edges ----------------
# A while loop is entered by a jump over its body to its condition at
# the bottom, which branches back to the body's head; the entry jump,
# the head and the back edge are control-flow edges, so no park may be
# live across them (the condition's parks are consumed by its compare,
# the body's by its statements). The condition is re-parsed after the
# body, with the body's stack words popped.
int rotated_sum(int n):
	int i = 0
	int j = 1
	int total = 0
	while (((i * 3) + (j * 5)) < (n * 7)):
		total = total + ((i * j) + (i + j) * (j - i))
		i = i + 1
		j = j + (i * 2)
	return total + (i * 100) + (j * 1000)


int rotated_nested(int n):
	int acc = 0
	int i = 0
	while ((i * i) + (acc & 7) < (n * n) + 5):
		int k = 0
		while ((k + (i * 2)) * 2 < (n + i) * 3):
			acc = acc + ((k * i) + ((acc >> 1) & 3))
			k = k + 1
		i = i + 1
	return acc + (i * 1000)


int rotated_const(int n):
	int i = 0
	int total = 0
	while (1):
		total = total + ((i * 3) + (n * (i + 1)))
		i = i + 1
		if (((i * 2) + (n * 0)) >= (n + n)): break
	for k in range(n):
		total = total + ((k * k) + (total & 1) * (k + 2))
	return total


void test_rotated_loops():
	# n = 4: iterations until 3i + 5j >= 28 with j = 1, 3, 7, 13, 21: (0,1) 5, (1,3) 18, (2,7) 41 stop at i=2, j=7
	assert_equal((0 + (0 + 1) * 1) + (3 + (1 + 3) * 2) + 200 + 7000, rotated_sum(4))
	assert_equal(0 + 0 + 1000, rotated_sum(0))
	assert_equal(15, rotated_const(2))
	assert_equal(4040, rotated_nested(3))
	assert_equal(3000, rotated_nested(0))


# --- inlined call sites (A5): a park live at a site whose body is emitted in place
int seven():
	return 7


int twice(int x):
	return x + x


int clampz(int x):
	if (x < 0): return 0
	return x


int shl_by(int x, int n):
	return (x << n) & 65535


int addm(int a, int b):
	return (a * 3) + (b * 5)


# A body whose first instruction is itself a park (the product's left
# operand): a fold inside the body rolls that instruction back, and
# must not undo the site's spill that ended right before it
int wbits():
	return __word_size__ * 8


int mulfirst(int a, int b):
	return (a * b) + (a - b)


int inlined_sites(int x, int y, int n):
	int r = x + seven()
	r = r + ((x * y) + twice(x + y))
	r = r + (x + clampz(y - x) * (y + seven()))
	r = r + (x + shl_by(y, n))
	r = r + (seven() + x * (twice(y) + seven()))
	r = r + (x + addm(y, x) * (seven() - clampz(x - y)))
	r = r + ((1 << (wbits() - 1)) >> (wbits() - 3))
	r = r + (x + mulfirst(y, n) * (wbits() - mulfirst(x, 1)))
	int i = 0
	while ((i + seven()) < (x + 7)):
		r = r + ((i * seven()) + twice(i))
		i = i + 1
	return r


void test_inline_sites():
	# x = 3, y = 5, n = 2
	int r = 3 + 7
	r = r + (15 + 16)
	r = r + (3 + 2 * 12)
	r = r + (3 + 20)
	r = r + (7 + 3 * (10 + 7))
	r = r + (3 + (15 + 15) * 7)
	r = r - 4   # (1 << 31) >> 29, an arithmetic shift of the sign bit
	r = r + (3 + 13 * (__word_size__ * 8 - 5))
	r = r + (0 + 0) + (7 + 2) + (14 + 4)
	assert_equal(r, inlined_sites(3, 5, 2))
	assert_equal(inlined_sites(5, 3, 7), inlined_sites(5, 3, 7))


int main():
	test_deep()
	test_hazards()
	test_branches()
	test_loops()
	test_rotate()
	test_struct_calls()
	test_floats()
	test_defer()
	test_compound()
	test_intrinsics()
	test_narrow()
	test_compares()
	test_args()
	test_rotated_loops()
	test_inline_sites()
	println(c"expr_regs_test passed")
	return 0
