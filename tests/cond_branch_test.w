# wbuild: x64
# Branch-on-flags for &&, || and ! in condition context (unit A6 of
# docs/projects/codegen_gap_plan.md §2.6, grammar/cond_branch.w): an
# if/elif/while condition, the condition of a ?: inside one, a '!'
# operand inside one and their parenthesized sub-chains branch per
# operand straight to the consumer's target, with no boolean word and
# no final booleanize. Every shape below is asserted by value only, so
# the test passes whether or not a chain was lowered that way -- what
# it pins is that the lowering never changes what a program computes:
# short-circuit evaluation order and side effects, mixed and nested
# chains, grouped sub-chains, negation, non-comparison operands (calls,
# pointers, map elements, constants, floats, unsigned words, strings),
# chains whose values are stored, returned, passed or used in
# arithmetic inside and outside conditions, ternaries, assignments in
# conditions, loops with break/continue, elif chains and switch.
# regalloc_diff_test compares every test program built with and
# without --no-cond-branch; the self-host fixpoint is the third gate.
import lib.lib
import lib.assert


struct node:
	int value
	node* next


# --- evaluation order: each probe records its id and returns its value ------
int trace
int probes


int probe(int id, int value):
	trace = trace * 10 + id
	probes = probes + 1
	return value


void trace_reset():
	trace = 0
	probes = 0


# --- bare comparisons and flat chains ----------------------------------------
int flat_chains(int a, int b, int c):
	int n = 0
	if (a < b): n = n + 1
	if ((a < b) && (b < c)): n = n + 2
	if ((a < b) || (b < c)): n = n + 4
	if ((a < b) && (b < c) && (c < 10)): n = n + 8
	if ((a > b) || (b > c) || (c > 10)): n = n + 16
	if (a == b): n = n + 32
	if ((a != b) && (b != c) && (a != c)): n = n + 64
	return n


void test_flat_chains():
	assert_equal(1 + 2 + 4 + 8 + 64, flat_chains(1, 2, 3))
	assert_equal(4 + 16 + 64, flat_chains(3, 2, 5))
	assert_equal(32, flat_chains(2, 2, 2))
	assert_equal(1 + 2 + 4 + 16 + 64, flat_chains(1, 2, 11))


# --- mixed and grouped chains --------------------------------------------------
int mixed_chains(int a, int b, int c, int d, int e):
	int n = 0
	if (a && b || c && d): n = n + 1
	if ((a || b) && (c || d)): n = n + 2
	if (((a && b) || (c && d)) && e): n = n + 4
	if ((a && (b || c)) || (d && e)): n = n + 8
	if (a && (b && (c && (d && e)))): n = n + 16
	if (a || (b || (c || (d || e)))): n = n + 32
	if ((a < b) && ((b < c) || (c < d)) && (d < e)): n = n + 64
	if (((a))): n = n + 128
	if (((a < b))): n = n + 256
	return n


void test_mixed_chains():
	assert_equal(1 + 2 + 4 + 8 + 16 + 32 + 64 + 128 + 256, mixed_chains(1, 2, 3, 4, 5))
	assert_equal(32, mixed_chains(0, 0, 0, 0, 5))
	assert_equal(1 + 2 + 8 + 32 + 128, mixed_chains(1, 1, 1, 1, 0))
	assert_equal(2 + 8 + 32 + 64 + 256, mixed_chains(0, 2, 0, 4, 5))
	assert_equal(0, mixed_chains(0, 0, 0, 0, 0))


# --- negation --------------------------------------------------------------------
int negations(int a, int b, int c):
	int n = 0
	if (!a): n = n + 1
	if (!!a): n = n + 2
	if (!(a < b)): n = n + 4
	if (!(a && b)): n = n + 8
	if (!(a || b)): n = n + 16
	if (!(a && b) || c): n = n + 32
	if (!(a || b) && !c): n = n + 64
	if (!(!(a))): n = n + 128
	if (!(a < b) && !(b < c)): n = n + 256
	if (!((a < b) || (b < c))): n = n + 512
	if (!(a ? b : c)): n = n + 1024
	if (!(a && !b)): n = n + 2048
	return n


void test_negations():
	assert_equal(2 + 32 + 128 + 2048, negations(1, 2, 3))
	assert_equal(1 + 8 + 16 + 32 + 64 + 4 + 256 + 512 + 1024 + 2048, negations(0, 0, 0))
	assert_equal(2 + 4 + 128 + 256 + 512 + 2048, negations(2, 1, 0))
	assert_equal(2 + 4 + 32 + 128 + 256 + 512 + 2048, negations(3, 2, 1))


# --- short-circuit evaluation order ---------------------------------------------
int order_and(int a, int b, int c):
	trace_reset()
	if (probe(1, a) && probe(2, b) && probe(3, c)): trace = trace * 10 + 9
	return trace


int order_or(int a, int b, int c):
	trace_reset()
	if (probe(1, a) || probe(2, b) || probe(3, c)): trace = trace * 10 + 9
	return trace


int order_mixed(int a, int b, int c, int d):
	trace_reset()
	if ((probe(1, a) && probe(2, b)) || (probe(3, c) && probe(4, d))): trace = trace * 10 + 9
	return trace


int order_not(int a, int b):
	trace_reset()
	if (!(probe(1, a) || probe(2, b))): trace = trace * 10 + 9
	return trace


int order_while(int a, int b):
	trace_reset()
	int i = 0
	while (probe(1, i < a) && probe(2, i < b)):
		i = i + 1
	return trace * 10 + i


int order_compare(int a, int b, int c):
	trace_reset()
	if ((probe(1, a) < probe(2, b)) && (probe(3, b) < probe(4, c))): trace = trace * 10 + 9
	return trace


void test_order():
	assert_equal(1239, order_and(1, 1, 1))
	assert_equal(12, order_and(1, 0, 1))
	assert_equal(1, order_and(0, 1, 1))
	assert_equal(19, order_or(1, 0, 0))
	assert_equal(129, order_or(0, 1, 0))
	assert_equal(123, order_or(0, 0, 0))
	assert_equal(1239, order_or(0, 0, 1))
	assert_equal(129, order_mixed(1, 1, 0, 0))
	assert_equal(12349, order_mixed(1, 0, 1, 1))
	assert_equal(134, order_mixed(0, 1, 1, 0))
	assert_equal(13, order_mixed(0, 0, 0, 1))
	assert_equal(129, order_not(0, 0))
	assert_equal(1, order_not(1, 0))
	assert_equal(12, order_not(0, 1))
	assert_equal(1212121 * 10 + 3, order_while(3, 5))
	assert_equal(1212 * 10 + 1, order_while(3, 1))
	assert_equal(1 * 10 + 0, order_while(0, 5))
	assert_equal(12349, order_compare(1, 2, 3))
	assert_equal(12, order_compare(2, 1, 3))
	assert_equal(1234, order_compare(1, 2, 2))


# --- non-comparison operands: pointers, fields, calls, constants ---------------
int pointer_operands(node* p):
	int n = 0
	if (p && p.value): n = n + 1
	if (p && p.next && p.next.value): n = n + 2
	if ((p == 0) || (p.value == 0)): n = n + 4
	if (p && (p.value > 1) && (p.next == 0)): n = n + 8
	if (!p || !p.next): n = n + 16
	if (1 && p): n = n + 32
	if (p || 0): n = n + 64
	if (0 || (p && 1)): n = n + 128
	return n


void test_pointer_operands():
	node b
	b.value = 7
	b.next = 0
	node a
	a.value = 3
	a.next = &b
	node z
	z.value = 0
	z.next = 0
	assert_equal(1 + 2 + 32 + 64 + 128, pointer_operands(&a))
	assert_equal(1 + 8 + 16 + 32 + 64 + 128, pointer_operands(&b))
	assert_equal(4 + 16 + 32 + 64 + 128, pointer_operands(&z))
	assert_equal(4 + 16, pointer_operands(0))


int is_even(int x): return (x & 1) == 0
int is_small(int x): return x < 10


int call_operands(int x):
	int n = 0
	if (is_even(x) && is_small(x)): n = n + 1
	if (is_even(x) || is_small(x)): n = n + 2
	if (!is_even(x) && !is_small(x)): n = n + 4
	if (is_even(x) && (x > 2) || is_small(x) && (x < 0)): n = n + 8
	return n


void test_call_operands():
	assert_equal(1 + 2 + 8, call_operands(4))
	assert_equal(2, call_operands(3))
	assert_equal(2 + 8, call_operands(12))
	assert_equal(4, call_operands(13))
	assert_equal(1 + 2 + 8, call_operands(-4))


# --- other comparison kinds as operands -----------------------------------------
int other_kinds(uint w, float32 f, char* s, int k):
	int n = 0
	map[int, int] m = new map[int, int]
	m[3] = 30
	m[5] = 0
	set[int] members = set[int]{1, 2, 3}
	if ((w > 5) && (f < 2.5)): n = n + 1
	if ((w < 5) || (f > 2.5)): n = n + 2
	if ((strcmp(s, c"abc") == 0) && (k in members)): n = n + 4
	if ((strcmp(s, c"abc") != 0) || !(k in members)): n = n + 8
	if ((k in m) && m[k]): n = n + 16
	if (!(k in m) || !m[k]): n = n + 32
	if (m[k] && (k == 3)): n = n + 64
	if ((f == 2.5) || (w == 0 - 1)): n = n + 128
	return n


void test_other_kinds():
	assert_equal(1 + 4 + 16 + 64, other_kinds(7, 1.0, c"abc", 3))
	assert_equal(2 + 8 + 16 + 64 + 128, other_kinds(0 - 1, 3.0, c"abd", 3))
	assert_equal(2 + 8 + 32 + 128, other_kinds(2, 2.5, c"abc", 5))
	assert_equal(1 + 8 + 32, other_kinds(9, 0.0, c"abc", 5))


# --- chain values outside condition context stay 0/1 words ----------------------
int values(int a, int b, int c):
	bool t = a && b
	bool u = (a || b) && c
	int v = (a && b) + (b || c) * 10
	int w = !(a && b) + !c * 10
	int r = 0
	if (t): r = r + 1
	if (u || t): r = r + 2
	return t + u * 10 + v * 100 + w * 10000 + r * 100000


int pass_through(int flag, int x): return flag * 1000 + x


int returned(int a, int b): return (a < b) && (b < 10)


int values_in_calls(int a, int b, int c):
	int n = pass_through(a && b, c || b)
	n = n + pass_through(!(a || b), (a && b) ? 7 : 8) * 10000
	return n + returned(a, b) * 100000000


void test_values():
	assert_equal(1 + 10 + 1100 + 0 + 300000, values(1, 2, 3))
	assert_equal(0 + 10 + 1000 + 10000 + 200000, values(0, 2, 3))
	assert_equal(0 + 0 + 0 + 110000 + 0, values(0, 0, 0))
	assert_equal(1 + 0 + 1100 + 100000 + 300000, values(1, 1, 0))
	assert_equal(1001 + 70000 + 100000000, values_in_calls(1, 2, 3))
	assert_equal(1 + 10080000 + 0, values_in_calls(0, 0, 1))
	assert_equal(1001 + 70000 + 0, values_in_calls(2, 1, 0))


# --- chain values read inside a condition (materialized on demand) --------------
int values_in_conditions(int a, int b, int c):
	int n = 0
	if ((a || b) == 1): n = n + 1
	if (((a && b) + (b || c)) == 2): n = n + 2
	if ((a || b) + 1 > 1): n = n + 4
	if (!(a || b) + 1 == 2): n = n + 8
	if (((a < b) && (b < c)) == ((a < c) || 0)): n = n + 16
	if ((a && b) * 3 == 3 && c): n = n + 32
	if ((!(a < b)) == (b <= a)): n = n + 64
	if ((a || b) == (b || a) && (a && b) == (b && a)): n = n + 128
	# '!!' in value position inside a condition must still booleanize
	if ((!!a) == 1): n = n + 256
	if ((!!(a || b)) == 1): n = n + 512
	if ((!!c) + (!!b) == 2): n = n + 1024
	return n


void test_values_in_conditions():
	assert_equal(1 + 2 + 4 + 16 + 32 + 64 + 128 + 256 + 512 + 1024, values_in_conditions(1, 2, 3))
	assert_equal(8 + 16 + 64 + 128, values_in_conditions(0, 0, 0))
	assert_equal(1 + 4 + 16 + 64 + 128 + 512, values_in_conditions(0, 1, 0))
	assert_equal(1 + 2 + 4 + 16 + 32 + 64 + 128 + 256 + 512 + 1024, values_in_conditions(3, 2, 1))


# --- ternaries --------------------------------------------------------------------
int ternaries(int a, int b, int c):
	int n = 0
	if (a ? b : c): n = n + 1
	if ((a && b) ? c : b): n = n + 2
	if ((a || b) ? (b && c) : !c): n = n + 4
	if (!(a ? b : c)): n = n + 8
	int v = (a && b) ? 10 : 20
	int w = ((a || b) && !c) ? 100 : 200
	if (((a < b) ? (b < c) : (c < b)) && a): n = n + 16
	return n + v + w


void test_ternaries():
	assert_equal(1 + 2 + 4 + 16 + 10 + 200, ternaries(1, 2, 3))
	assert_equal(2 + 8 + 20 + 100, ternaries(0, 2, 0))
	assert_equal(4 + 8 + 20 + 200, ternaries(0, 0, 0))
	assert_equal(8 + 20 + 200, ternaries(1, 0, 1))
	assert_equal(1 + 2 + 4 + 16 + 10 + 200, ternaries(3, 2, 1))


# --- assignments and map elements inside conditions -------------------------------
int next_value
int next():
	next_value = next_value + 1
	return next_value


int assignments(int limit):
	next_value = 0
	int x = 0
	int n = 0
	if (x = next()): n = n + 1
	if ((x = next()) == 2): n = n + 2
	if ((x = next()) && (x < limit)): n = n + 4
	while ((x = next()) < limit): n = n + 10
	map[int, int] m = new map[int, int]
	m[1] = 5
	m[2] = 0
	if (m[1]): n = n + 100
	if (!m[2]): n = n + 200
	if (x && m[1]): n = n + 400
	if (m[2] || m[1]): n = n + 800
	if ((m[1] = 6) == 6): n = n + 1600
	if (m[1] == 6): n = n + 3200
	# A parked element read as the whole operand of a parenthesized
	# group is finished inside the chain; the value consumer outside
	# must see a value, not load it again
	if ((m[1]) == 6): n = n + 6400
	if ((m[1]) + 1 == 7): n = n + 12800
	if (((m[2])) || (m[1]) - 5): n = n + 25600
	return n * 10 + x


void test_assignments():
	assert_equal((1 + 2 + 4 + 20 + 100 + 200 + 400 + 800 + 1600 + 3200 + 6400 + 12800 + 25600) * 10 + 6, assignments(6))
	assert_equal((1 + 2 + 100 + 200 + 400 + 800 + 1600 + 3200 + 6400 + 12800 + 25600) * 10 + 4, assignments(3))


# --- loops: break, continue, nesting, register-resident locals ------------------
int loops(int n, int limit):
	int i = 0
	int s = 0
	int inner = 0
	while ((i < n) && (s < limit)):
		i = i + 1
		if ((i & 1) == 0 && i > 2): continue
		if (i > 6 || s > 90): break
		int j = 0
		while (j < i && (j < 3 || i == 5)):
			if ((j & 1) || (i == 1)): inner = inner + 1
			j = j + 1
		s = s + i * j
	for k in range(n):
		if ((k > 1) && (k < 4) || !(k != 0)): s = s + 1000
	return s * 100 + inner * 10 + i


void test_loops():
	# i=1: j runs to 1 (inner+1), s=1; i=2: j to 2 (inner+1), s=5; i=3: j to 3
	# (inner+1), s=14; i=4: skipped (even, > 2); i=5: j to 5 (inner+2), s=39;
	# i=6: skipped; i=7: break (or s < 20 fails after i=5). range: k=0,2,3
	# add 1000.
	assert_equal((39 + 3000) * 100 + 50 + 7, loops(8, 1000))
	assert_equal((39 + 3000) * 100 + 50 + 5, loops(8, 20))
	assert_equal(0, loops(0, 10))


# --- elif chains and switch ----------------------------------------------------
int classify(int a, int b):
	if ((a < 0) || (b < 0)): return 1
	elif (a == 0 && b == 0): return 2
	elif ((a > b) && !(b == 0)): return 3
	elif (!(a > b) || b == 0): return 4
	else: return 5


int switched(int k, int a, int b):
	int n = 0
	switch (k):
		case 1:
			if (a && b): n = 10
			else: n = 11
		case 2:
			while ((n < 5) && (a || b)): n = n + 1
		default:
			if (!(a || b)): n = 30
	return n


void test_elif_switch():
	assert_equal(1, classify(-1, 5))
	assert_equal(2, classify(0, 0))
	assert_equal(3, classify(5, 2))
	assert_equal(4, classify(2, 5))
	assert_equal(4, classify(5, 0))
	assert_equal(10, switched(1, 1, 1))
	assert_equal(11, switched(1, 1, 0))
	assert_equal(5, switched(2, 0, 1))
	assert_equal(0, switched(2, 0, 0))
	assert_equal(30, switched(3, 0, 0))
	assert_equal(0, switched(3, 1, 0))


# --- long chains with many operands -----------------------------------------------
int long_chain(int x):
	int n = 0
	if ((x > 0) && (x > 1) && (x > 2) && (x > 3) && (x > 4) && (x > 5) && (x > 6)): n = n + 1
	if ((x == 0) || (x == 1) || (x == 2) || (x == 3) || (x == 4) || (x == 5) || (x == 6)): n = n + 2
	if ((x > 0) && (x > 1) || (x > 2) && (x > 3) || (x > 4) && (x > 5) || (x > 6) && (x > 7)): n = n + 4
	if (!((x > 0) && (x > 1)) && !((x > 2) || (x > 3))): n = n + 8
	return n


void test_long_chain():
	assert_equal(1 + 4, long_chain(9))
	assert_equal(2 + 4, long_chain(3))
	assert_equal(2 + 8, long_chain(0))
	assert_equal(2 + 8, long_chain(1))
	assert_equal(2 + 4, long_chain(2))


int main():
	test_flat_chains()
	test_mixed_chains()
	test_negations()
	test_order()
	test_pointer_operands()
	test_call_operands()
	test_other_kinds()
	test_values()
	test_values_in_conditions()
	test_ternaries()
	test_assignments()
	test_loops()
	test_elif_switch()
	test_long_chain()
	println(c"cond_branch_test passed")
	return 0
