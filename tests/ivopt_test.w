# wbuild: x64
# Induction-variable pointers (unit O7, compiler/ivopt.w): in an
# innermost call-free loop, a subscript whose base and other names the
# loop never writes and whose index is linear in the loop's induction
# variables ('a[i * n + k]', 'b[k * n + j]') is a pointer register set
# before the loop and stepped after every whole-line step of its
# variable. Each shape below computes the same value through the
# optimised loop and through a reference loop whose index goes through
# a call (a loop with a call is never transformed), so the x86 build
# (no pointers) and the x64 twin (pointers) must both agree with the
# reference: matrix walks, every step spelling, negative and named
# strides, two induction variables in one index, a conditional step,
# continue and break, a nested loop (only the innermost one walks),
# narrow and struct element types, stores and '&a[...]', an invariant
# address, a subscript in the while condition, range loops, aliasing
# stores through another pointer to the same array, and the shapes that
# must decline (an invariant written in the body, a multi-assignment,
# an address-taken index, a declaration in the body). The hidden-call
# shape (a list subscript in the loop) recomputes the pointers after
# the runtime call. regalloc_diff_test compares every test program
# built with and without --no-ivopts.
import lib.lib
import lib.assert


int ident(int x):
	return x


int* make_ints(int count, int seed):
	int* p = cast(int*, malloc(count * __word_size__))
	int s = seed
	for i in range(count):
		s = (s * 1103515245 + 12345) & 0x7fffffff
		p[i] = (s >> 8) & 0xffff
	return p


# --- matrix walks -------------------------------------------------------
int matmul_sum(int* a, int* b, int* out, int n):
	int i = 0
	while (i < n):
		int j = 0
		while (j < n):
			int acc = 0
			int k = 0
			while (k < n):
				acc = acc + a[i * n + k] * b[k * n + j]
				k = k + 1
			out[i * n + j] = acc
			j = j + 1
		i = i + 1
	int h = 0
	for q in range(n * n): h = h * 31 + out[q]
	return h


int matmul_ref(int* a, int* b, int* out, int n):
	int i = 0
	while (i < n):
		int j = 0
		while (j < n):
			int acc = 0
			int k = 0
			while (k < n):
				acc = acc + a[ident(i * n + k)] * b[ident(k * n + j)]
				k = k + 1
			out[ident(i * n + j)] = acc
			j = j + 1
		i = i + 1
	int h = 0
	for q in range(n * n): h = h * 31 + out[q]
	return h


void test_matmul():
	int n = 7
	int* a = make_ints(n * n, 1)
	int* b = make_ints(n * n, 2)
	int* out = make_ints(n * n, 3)
	assert_equal(matmul_ref(a, b, out, n), matmul_sum(a, b, out, n))


# --- step spellings ---------------------------------------------------------
int steps_plus(int* a, int n):
	int s = 0
	int k = 0
	while (k < n):
		s = s + a[k * 3 + 1]
		k += 1
	return s


int steps_inc(int* a, int n):
	int s = 0
	int k = 0
	while (k < n):
		s = s * 3 + a[2 * k + 1]
		k++
	return s


int steps_preinc(int* a, int n):
	int s = 0
	int k = 1
	while (k < n):
		s = s * 3 + a[(k + 1) * 2]
		++k
	return s


int steps_by_two(int* a, int n):
	int s = 0
	int k = 0
	while (k < n):
		s = s * 5 + a[k * 2 + 3]
		k = k + 2
	return s


int steps_ref(int* a, int n, int mul, int coef, int off, int start, int step):
	int s = 0
	int k = start
	while (k < n):
		s = s * mul + a[ident(k * coef + off)]
		k = k + step
	return s


void test_steps():
	int* a = make_ints(200, 4)
	assert_equal(steps_ref(a, 40, 1, 3, 1, 0, 1), steps_plus(a, 40))
	assert_equal(steps_ref(a, 40, 3, 2, 1, 0, 1), steps_inc(a, 40))
	assert_equal(steps_ref(a, 40, 3, 2, 2, 1, 1), steps_preinc(a, 40))
	assert_equal(steps_ref(a, 41, 5, 2, 3, 0, 2), steps_by_two(a, 41))
	assert_equal(0, steps_plus(a, 0))


# --- negative strides ---------------------------------------------------------
int down_sub(int* a, int n):
	int s = 0
	int k = n - 1
	while (k >= 0):
		s = s * 7 + a[k * 3 + 2]
		k = k - 1
	return s


int down_dec(int* a, int n):
	int s = 0
	int k = n
	while (k > 0):
		s = s * 7 + a[100 - k * 2]
		k--
	return s


int up_negative_coef(int* a, int n):
	int s = 0
	int k = 0
	while (k < n):
		s = s * 7 + a[n * 2 - k * 2]
		k -= -1
	return s


void test_negative():
	int* a = make_ints(200, 5)
	int s = 0
	int k = 29
	while (k >= 0):
		s = s * 7 + a[ident(k * 3 + 2)]
		k = k - 1
	assert_equal(s, down_sub(a, 30))
	s = 0
	k = 40
	while (k > 0):
		s = s * 7 + a[ident(100 - k * 2)]
		k = k - 1
	assert_equal(s, down_dec(a, 40))
	s = 0
	k = 0
	while (k < 33):
		s = s * 7 + a[ident(33 * 2 - k * 2)]
		k = k + 1
	assert_equal(s, up_negative_coef(a, 33))


# --- named strides and steps -------------------------------------------------
int named_step(char* p, int n, int stride):
	int s = 0
	int j = 1
	while (j < n):
		s = s * 3 + p[j * 2 + 1]
		j = j + stride
	return s


int named_coef(int* a, int rows, int cols, int col):
	int s = 0
	int r = 0
	while (r < rows):
		s = s * 3 + a[r * cols + col]
		r = r + 1
	return s


int named_coef_expr(int* a, int rows, int cols):
	int s = 0
	int r = 0
	while (r < rows):
		s = s * 3 + a[r * (cols + 1) + 2]
		r += 1
	return s


void test_named():
	char* p = cast(char*, make_ints(64, 6))
	int s = 0
	int j = 1
	while (j < 200):
		s = s * 3 + p[ident(j * 2 + 1)]
		j = j + 7
	assert_equal(s, named_step(p, 200, 7))
	int* a = make_ints(400, 7)
	s = 0
	int r = 0
	while (r < 19):
		s = s * 3 + a[ident(r * 13 + 5)]
		r = r + 1
	assert_equal(s, named_coef(a, 19, 13, 5))
	s = 0
	r = 0
	while (r < 19):
		s = s * 3 + a[ident(r * 14 + 2)]
		r = r + 1
	assert_equal(s, named_coef_expr(a, 19, 13))


# --- two induction variables, a conditional step, continue, break ----------
int two_ivs(int* a, int n):
	int s = 0
	int i = 0
	int j = 0
	while (i < n):
		s = s * 3 + a[i + j * 2 + 1]
		i = i + 1
		j = j + 2
	return s


int conditional_step(int* a, int n):
	int s = 0
	int k = 0
	int t = 0
	while (t < n):
		s = s * 3 + a[k * 4 + 1]
		if (a[t] & 1):
			k = k + 1
		t = t + 1
	return s


int with_continue(int* a, int n):
	int s = 0
	int k = 0
	while (k < n):
		k = k + 1
		if (k % 3 == 0): continue
		s = s * 3 + a[k * 2 + 1]
	return s


int with_break(int* a, int n, int stop):
	int s = 0
	int k = 0
	while (k < n):
		if (a[k * 2 + 1] == stop): break
		s = s * 3 + a[k * 2 + 1]
		k = k + 1
	return s * 100 + k


void test_control():
	int* a = make_ints(400, 8)
	int s = 0
	int i = 0
	while (i < 50):
		s = s * 3 + a[ident(i + 4 * i + 1)]
		i = i + 1
	assert_equal(s, two_ivs(a, 50))
	s = 0
	int k = 0
	int t = 0
	while (t < 60):
		s = s * 3 + a[ident(k * 4 + 1)]
		if (a[t] & 1): k = k + 1
		t = t + 1
	assert_equal(s, conditional_step(a, 60))
	s = 0
	k = 0
	while (k < 70):
		k = k + 1
		if (k % 3 == 0): continue
		s = s * 3 + a[ident(k * 2 + 1)]
	assert_equal(s, with_continue(a, 70))
	int stop = a[2 * 37 + 1]
	s = 0
	k = 0
	while (k < 90):
		if (a[ident(k * 2 + 1)] == stop): break
		s = s * 3 + a[ident(k * 2 + 1)]
		k = k + 1
	assert_equal(s * 100 + k, with_break(a, 90, stop))
	s = 0
	k = 0
	while (k < 90):
		if (a[ident(k * 2 + 1)] == -1): break
		s = s * 3 + a[ident(k * 2 + 1)]
		k = k + 1
	assert_equal(k, 90)
	assert_equal(s * 100 + k, with_break(a, 90, -1))


# --- element types ---------------------------------------------------------------
struct ivpair:
	int x
	int y


int narrow_walk(char* c, int32* w, int16* h, int n):
	int s = 0
	int k = 0
	while (k < n):
		s = s * 3 + c[k * 3 + 1] + w[k * 2 + 1] + h[k * 2 + 3]
		k = k + 1
	return s


int struct_walk(ivpair* ps, int n):
	int s = 0
	for k in range(n):
		s = s * 3 + ps[k * 2 + 1].x - ps[k * 2 + 1].y
	return s


void test_types():
	char* c = cast(char*, make_ints(100, 9))
	int32* w = cast(int32*, make_ints(100, 10))
	int16* h = cast(int16*, make_ints(100, 11))
	int s = 0
	int k = 0
	while (k < 30):
		s = s * 3 + c[ident(k * 3 + 1)] + w[ident(k * 2 + 1)] + h[ident(k * 2 + 3)]
		k = k + 1
	assert_equal(s, narrow_walk(c, w, h, 30))
	ivpair* ps = cast(ivpair*, make_ints(200, 12))
	s = 0
	for q in range(40): s = s * 3 + ps[ident(q * 2 + 1)].x - ps[ident(q * 2 + 1)].y
	assert_equal(s, struct_walk(ps, 40))


# --- stores, addresses, aliasing, an invariant address, a while condition --
void store_walk(int* a, int n):
	int k = 0
	while (k < n):
		a[k * 2 + 1] = a[k * 2 + 1] * 3 + k
		k = k + 1


int address_walk(int* a, int n):
	int s = 0
	int k = 0
	while (k < n):
		int* p = &a[k * 3 + 2]
		s = s * 3 + *p
		k = k + 1
	return s


# b aliases a: stores through b change what a's pointer reads
int alias_walk(int* a, int* b, int n):
	int s = 0
	int k = 0
	while (k < n):
		b[k * 2 + 2] = a[k * 2 + 1] + 1
		s = s * 3 + a[k * 2 + 1]
		k = k + 1
	return s


int invariant_address(int* a, int n, int m):
	int s = 0
	int k = 0
	while (k < n):
		s = s * 3 + a[m * 2 + 1] + a[k * 5 + 1]
		k = k + 1
	return s


int condition_walk(int* a, int limit):
	int k = 0
	while (a[k * 2 + 1] < limit):
		k = k + 1
	return k


void test_memory():
	int* a = make_ints(200, 13)
	int* r = make_ints(200, 13)
	store_walk(a, 50)
	int k = 0
	while (k < 50):
		r[ident(k * 2 + 1)] = r[ident(k * 2 + 1)] * 3 + k
		k = k + 1
	for q in range(200): assert_equal(r[q], a[q])
	int s = 0
	k = 0
	while (k < 40):
		s = s * 3 + a[ident(k * 3 + 2)]
		k = k + 1
	assert_equal(s, address_walk(a, 40))
	int* b = make_ints(200, 14)
	int* c = make_ints(200, 14)
	int got = alias_walk(b, &b[1], 60)
	s = 0
	k = 0
	while (k < 60):
		c[ident(k * 2 + 1 + 2)] = c[ident(k * 2 + 1)] + 1
		s = s * 3 + c[ident(k * 2 + 1)]
		k = k + 1
	assert_equal(s, got)
	s = 0
	k = 0
	while (k < 30):
		s = s * 3 + a[ident(7 * 2 + 1)] + a[ident(k * 5 + 1)]
		k = k + 1
	assert_equal(s, invariant_address(a, 30, 7))
	int* d = make_ints(100, 15)
	for q in range(100): d[q] = q
	d[2 * 20 + 1] = 1000
	assert_equal(20, condition_walk(d, 999))


# --- range loops -------------------------------------------------------------------
int range_walk(int* a, int n):
	int s = 0
	for k in range(n): s = s * 3 + a[k * 4 + 3]
	return s


int range_from(int* a, int lo, int hi):
	int s = 0
	for k in range(lo, hi):
		s = s * 3 + a[k * 2 + 1]
	return s


int range_step3(int* a, int n):
	int s = 0
	for k in range(0, n, 3):
		s = s * 3 + a[k * 2 + 1]
	return s


void test_ranges():
	int* a = make_ints(400, 16)
	int s = 0
	for k in range(50): s = s * 3 + a[ident(k * 4 + 3)]
	assert_equal(s, range_walk(a, 50))
	s = 0
	for k in range(5, 60): s = s * 3 + a[ident(k * 2 + 1)]
	assert_equal(s, range_from(a, 5, 60))
	assert_equal(0, range_from(a, 9, 3))
	s = 0
	for k in range(0, 90, 3): s = s * 3 + a[ident(k * 2 + 1)]
	assert_equal(s, range_step3(a, 90))


# --- shapes that must not walk ----------------------------------------------------
int invariant_written(int* a, int n):
	int s = 0
	int m = 3
	int k = 0
	while (k < n):
		s = s * 3 + a[k * m + 1]
		m = (m + 1) % 5
		k = k + 1
	return s


int multi_assign(int* a, int n):
	int s = 0
	int k = 0
	int m = 1
	while (k < n):
		s = s * 3 + a[k * 2 + m]
		k, m = k + 1, m
	return s


int address_taken(int* a, int n):
	int s = 0
	int k = 0
	int* pk = &k
	while (k < n):
		s = s * 3 + a[k * 2 + 1]
		*pk = *pk + 1
	return s


int declared_inside(int* a, int n):
	int s = 0
	int k = 0
	while (k < n):
		int m = k % 3
		s = s * 3 + a[k * 2 + m]
		k = k + 1
	return s


int step_by_written(int* a, int n):
	int s = 0
	int k = 0
	int d = 1
	while (k < n):
		s = s * 3 + a[k * 2 + 1]
		k = k + d
		d = 2 - d + 1
	return s


void test_declines():
	int* a = make_ints(400, 17)
	int s = 0
	int m = 3
	int k = 0
	while (k < 40):
		s = s * 3 + a[ident(k * m + 1)]
		m = (m + 1) % 5
		k = k + 1
	assert_equal(s, invariant_written(a, 40))
	s = 0
	for q in range(40): s = s * 3 + a[ident(q * 2 + 1)]
	assert_equal(s, multi_assign(a, 40))
	assert_equal(s, address_taken(a, 40))
	s = 0
	for q in range(40): s = s * 3 + a[ident(q * 2 + q % 3)]
	assert_equal(s, declared_inside(a, 40))
	s = 0
	k = 0
	int d = 1
	while (k < 60):
		s = s * 3 + a[ident(k * 2 + 1)]
		k = k + d
		d = 2 - d + 1
	assert_equal(s, step_by_written(a, 60))


# --- a hidden call in the loop: the pointers are recomputed after it ------------
int hidden_call(int* a, list[int] xs, int n):
	int s = 0
	int k = 0
	while (k < n):
		s = s * 3 + a[k * 2 + 1] + xs[k] + a[k * 3 + 2]
		k = k + 1
	return s


void test_hidden_call():
	int* a = make_ints(400, 18)
	list[int] xs = new list[int]
	for q in range(50): xs.push(q * 7)
	int s = 0
	for q in range(50): s = s * 3 + a[ident(q * 2 + 1)] + q * 7 + a[ident(q * 3 + 2)]
	assert_equal(s, hidden_call(a, xs, 50))


int main():
	test_matmul()
	test_steps()
	test_negative()
	test_named()
	test_control()
	test_types()
	test_memory()
	test_ranges()
	test_declines()
	test_hidden_call()
	println(c"ivopt_test passed")
	return 0
