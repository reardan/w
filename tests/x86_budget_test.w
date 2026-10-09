# wbuild: x64
# wbuild: step="bin/wv2 --no-x86-budget tests/x86_budget_test.w -o bin/x86_budget_nobudget_test"
# wbuild: step="bin/x86_budget_nobudget_test"
# wbuild: step="bin/wv2 --no-regs tests/x86_budget_test.w -o bin/x86_budget_noregs_test"
# wbuild: step="bin/x86_budget_noregs_test"
# wbuild: step="bin/wv2 -O0 tests/x86_budget_test.w -o bin/x86_budget_o0_test"
# wbuild: step="bin/x86_budget_o0_test"
# wbuild: step="bin/wv2 --no-expr-regs tests/x86_budget_test.w -o bin/x86_budget_noexpr_test"
# wbuild: step="bin/x86_budget_noexpr_test"
# wbuild: step="bin/wv2 --no-loop-rotate tests/x86_budget_test.w -o bin/x86_budget_norotate_test"
# wbuild: step="bin/x86_budget_norotate_test"
# wbuild: step="bin/wv2 --inline tests/x86_budget_test.w -o bin/x86_budget_inline_test"
# wbuild: step="bin/x86_budget_inline_test"
# wbuild: step="bin/wv2 x64 --inline tests/x86_budget_test.w -o bin/x86_budget_inline_64_test"
# wbuild: step="bin/x86_budget_inline_64_test"
# The x86-32 register budget (docs/projects/codegen_gap_plan.md §2.7
# and §8, unit A9; compiler/regalloc_scan.w's loop pass): on x86 a loop
# whose body never shifts by a variable, divides or takes a modulo may
# own ecx/edx for its hottest written locals, subscript bases and
# indices, the registers A3's expression parks use otherwise, and the
# emitters that write ecx/edx anyway (the shift count, the division's
# high half, the limb and bit intrinsics) park an owned register in its
# home around the sequence. Every case asserts computed values only, so
# it passes whether or not a loop took a register -- what it pins is
# that the budget never changes what a program computes: through
# literal and variable shifts, division and modulo in the loop, in a
# nested loop only, and in an inlined callee, calls and hidden calls,
# range loops, pointer arguments as bases, break/continue/return exit
# edges, the bit intrinsics, rotated loops and the --no-x86-budget,
# --no-regs, -O0, --no-expr-regs, --no-loop-rotate and --inline twins
# (and x64, where nothing changes). The expected values are the
# --no-regs build's.
import lib.lib
import lib.assert


# --- a clean loop: three written locals beyond the two esi/edi take ---------
int budget_plain(int n):
	int i = 0
	int s = 0
	int t = 1
	int u = 7
	while (i < n):
		s = s + i
		t = t + s
		u = u ^ (t + 3)
		i = i + 1
	return s * 3 + t + u


# --- literal shifts keep the loop eligible; a variable shift declines it ---
int budget_shift_literal(int n):
	int i = 0
	int x = 1
	int acc = 0
	while (i < n):
		x = ((x << 3) | (x >> 29)) & 0x7fffffff
		acc = acc + (x >> 1)
		i = i + 1
	return acc ^ x


int budget_shift_variable(int n, int sh):
	int i = 0
	int x = 1
	int acc = 0
	while (i < n):
		x = ((x << sh) | (x >> (31 - sh))) & 0x7fffffff
		acc = acc + (x >> sh)
		i = i + 1
	return acc ^ x


# --- division and modulo in the loop, in the inner loop only, in the outer only
int budget_div(int n):
	int i = 1
	int s = 0
	int q = 0
	while (i <= n):
		s = s + i / 3 + i % 7
		q = q + (s / i)
		i = i + 1
	return s * 5 + q


int budget_div_inner(int n):
	int i = 0
	int s = 0
	int t = 0
	while (i < n):
		int j = 1
		while (j <= i):
			s = s + j / 2
			j = j + 1
		t = t + s
		i = i + 1
	return s + t * 3


int budget_div_outer(int n):
	int i = 1
	int s = 0
	int t = 0
	while (i <= n):
		int j = 0
		while (j < i):
			s = s + j
			t = t ^ s
			j = j + 1
		s = s / 2 + i % 5
		i = i + 1
	return s * 7 + t


# --- calls and hidden calls decline the loop; spills around them are correct
int budget_callee(int a, int b):
	return a * 3 + b


int budget_calls(int n):
	int i = 0
	int s = 0
	int t = 0
	while (i < n):
		s = s + budget_callee(i, t)
		t = t + 1
		i = i + 1
	return s + t


int budget_hidden_calls(int n):
	list[int] xs = new list[int]
	int i = 0
	int s = 0
	while (i < n):
		xs.push(i * 2)
		s = s + i
		i = i + 1
	int t = 0
	i = 0
	while (i < xs.length):
		t = t + xs[i] + s
		i = i + 1
	return t


# --- range loops: the loop variable, hidden end and step words ------------
int budget_ranges(int n):
	int s = 0
	int t = 0
	for i in range(n):
		for j in range(i):
			s = s + j
			t = t ^ (s + i)
	for k in range(1, n, 3):
		s = s + k
	return s * 3 + t


# --- pointer arguments and locals as bases, one-token indices --------------
int budget_bases(int* a, int* b, int n):
	int i = 0
	int s = 0
	int t = 0
	while (i < n):
		s = s + a[i] * b[i]
		b[i] = s
		t = t + a[i]
		i = i + 1
	return s + t


int budget_base_product(int* a, int* b, int n):
	int acc = 0
	int i = 0
	while (i < n):
		int j = 0
		while (j < n):
			acc = acc + a[i * n + j] * b[j * n + i]
			j = j + 1
		i = i + 1
	return acc & 0x7fffffff


int budget_byte_store(int n):
	char* flags = cast(char*, malloc(n + 1))
	int i = 0
	while (i <= n):
		flags[i] = 0
		i = i + 1
	i = 2
	int count = 0
	while (i * i <= n):
		if (flags[i] == 0):
			int j = i * i
			while (j <= n):
				flags[j] = 1
				j = j + i
			count = count + 1
		i = i + 1
	int c = 0
	i = 2
	while (i <= n):
		if (flags[i] == 0): c = c + 1
		i = i + 1
	free(flags)
	return c * 1000 + count


# --- exit edges: break, continue, return from inside the loop --------------
int budget_exits(int n):
	int i = 0
	int s = 0
	int t = 0
	while (i < n):
		i = i + 1
		if ((i & 3) == 0): continue
		s = s + i
		t = t + s
		if (t > 100000): break
	return s + t


int budget_return_inside(int n):
	int i = 0
	int s = 0
	int t = 5
	while (i < n):
		s = s + i * t
		t = t + 2
		if (s > 500): return s + t
		i = i + 1
	return s - t


# --- the bit intrinsics (ecx as the count, edx as the temporaries) ---------
int budget_intrinsics(int n):
	int i = 0
	int x = 0x12345678
	int s = 0
	while (i < n):
		x = rotl(x, 5) ^ rotr(x, 3)
		s = s + popcount(x) + clz(x | 1) + ctz(x | 0x100)
		i = i + 1
	return s ^ (x & 0x7fffffff)


# --- a small leaf with a division, inlined under --inline inside a loop ----
int budget_half(int x):
	return x / 2


int budget_third_rem(int x):
	return x % 3


int budget_shifted(int x, int by):
	return x >> by


int budget_inline_sites(int n):
	int i = 0
	int s = 0
	int t = 0
	while (i < n):
		s = s + budget_half(i) + budget_third_rem(s)
		t = t + budget_shifted(s, i & 3)
		i = i + 1
	return s * 3 + t


# --- heavy expressions: the operator pressure keeps the parks ------------------
int budget_pressure(int n):
	int i = 0
	int x = 3
	int y = 5
	int acc = 0
	while (i < n):
		int a = ((x >> 7) & 0x1ffffff) | ((x << 25) & 0x7fffffff)
		int b = ((y >> 11) & 0xfffff) | ((y << 21) & 0x7fffffff)
		acc = (acc + ((a ^ b) & (x | y)) + ((a & b) ^ (x & 0xffff))) & 0x7fffffff
		x = (x + acc) & 0x7fffffff
		y = (y ^ (acc + 1)) & 0x7fffffff
		i = i + 1
	return acc ^ x ^ y


# --- nested loops both owning registers ---------------------------------------
int budget_nested(int n):
	int i = 0
	int s = 0
	int t = 0
	int u = 0
	while (i < n):
		int j = 0
		int v = i
		while (j < n):
			v = v + j
			s = s + v
			j = j + 1
		t = t + s
		u = u ^ t
		i = i + 1
	return s + t * 3 + u


void test_budget():
	assert_equal(8, budget_plain(0))
	assert_equal(443, budget_plain(10))
	assert_equal(312109, budget_plain(100))
	assert_equal(1035393901, budget_shift_literal(20))
	assert_equal(51492, budget_shift_literal(5))
	assert_equal(766958445, budget_shift_variable(20, 3))
	assert_equal(2377875, budget_shift_variable(9, 7))
	assert_equal(239, budget_div(10))
	assert_equal(10806, budget_div(100))
	assert_equal(670, budget_div_inner(10))
	assert_equal(303, budget_div_outer(10))
	assert_equal(190, budget_calls(10))
	assert_equal(4180, budget_hidden_calls(20))
	assert_equal(824, budget_ranges(12))
	int* a = cast(int*, malloc(16 * __word_size__))
	int* b = cast(int*, malloc(16 * __word_size__))
	for i in range(16):
		a[i] = i * 3 + 1
		b[i] = 17 - i
	assert_equal(1208, budget_bases(a, b, 8))
	for i in range(16):
		a[i] = i + 1
		b[i] = (i * 7) & 15
	assert_equal(1044, budget_base_product(a, b, 4))
	assert_equal(25004, budget_byte_store(100))
	assert_equal(181, budget_exits(10))
	assert_equal(107407, budget_exits(200))
	assert_equal(-5, budget_return_inside(0))
	assert_equal(611, budget_return_inside(20))
	assert_equal(305419896, budget_intrinsics(0))
	assert_equal(194, budget_intrinsics(7))
	assert_equal(116, budget_inline_sites(10))
	assert_equal(1080609582, budget_pressure(50))
	assert_equal(716, budget_nested(4))


int main():
	test_budget()
	println(c"x86_budget_test passed")
	return 0
