# wbuild: x64 arch=arm64
# Loop rotation (unit A7 of docs/projects/codegen_gap_plan.md §2.5,
# grammar/loop_rotate.w): while and for loops are entered by a jump to
# their condition, which sits after the body and branches back to the
# body's head while it holds. A while loop's condition is skipped,
# parsed after the body and the lexer returned to the body's end, so
# the shapes below pin what a program computes under every path the
# skip can take -- the ':' and '{' block openers, a ternary, brackets
# and typed container literals in the condition, a template string
# (declined: top-tested), a body longer than the lexer's 8 KiB read
# window (the return to the condition is a real seek) -- and the loop
# machinery that moves with the condition: zero and one iterations,
# break/continue in nested loops, a register-resident for variable, a
# condition that calls a function with side effects (exactly one call
# per iteration plus the exit test), &&/||/! chains in the bottom test
# (unit A6's branch-on-flags in the inverted polarity), defer in a body,
# goto out of and back into a loop, generators looping, infinite loops
# left by break (the constant-condition fold), and every for-in shape.
# regalloc_diff_test compares every test program built with and without
# --no-loop-rotate; the self-host fixpoints are the other gate.
import lib.lib
import lib.assert
import lib.generator
import lib.utf8


# --- probes: each call records its id and returns its value ----------------
int trace
int calls


int probe(int id, int value):
	trace = trace * 10 + id
	calls = calls + 1
	return value


void reset():
	trace = 0
	calls = 0


# --- zero, one and many iterations -----------------------------------------
int count_while(int n):
	int i = 0
	int body = 0
	while (i < n):
		body = body + 1
		i = i + 1
	return body * 100 + i


int count_for(int n):
	int body = 0
	int last = -1
	for i in range(n):
		body = body + 1
		last = i
	return body * 100 + (last + 1)


int count_for_from(int a, int b):
	int sum = 0
	for i in range(a, b): sum = sum + i
	return sum


int count_for_step(int a, int b, int step):
	int sum = 0
	int n = 0
	for i in range(a, b, step):
		sum = sum + i
		n = n + 1
	return sum * 100 + n


void test_iteration_counts():
	assert_equal(0, count_while(0))
	assert_equal(0, count_while(-3))
	assert_equal(101, count_while(1))
	assert_equal(707, count_while(7))
	assert_equal(0, count_for(0))
	assert_equal(0, count_for(-1))
	assert_equal(101, count_for(1))
	assert_equal(505, count_for(5))
	assert_equal(0, count_for_from(5, 5))
	assert_equal(0, count_for_from(6, 5))
	assert_equal(5, count_for_from(5, 6))
	assert_equal(5 + 6 + 7 + 8 + 9, count_for_from(5, 10))
	assert_equal(0, count_for_step(0, 0, 3))
	assert_equal((0 + 3 + 6 + 9) * 100 + 4, count_for_step(0, 10, 3))
	assert_equal((2 + 7) * 100 + 2, count_for_step(2, 12, 5))


# --- the condition is evaluated once per iteration, plus the exit test ----
int next_value
int cond_calls


int next_below(int limit):
	cond_calls = cond_calls + 1
	next_value = next_value + 1
	return next_value < limit


int count_side_effects(int limit):
	next_value = 0
	cond_calls = 0
	int body = 0
	while (next_below(limit)): body = body + 1
	return body * 100 + cond_calls


void test_condition_calls():
	# n iterations: n body runs, n + 1 condition calls
	assert_equal(0 * 100 + 1, count_side_effects(1))
	assert_equal(1 * 100 + 2, count_side_effects(2))
	assert_equal(4 * 100 + 5, count_side_effects(5))
	# the same for a chain whose first operand calls
	reset()
	int k = 0
	while (probe(1, k < 3) && probe(2, 1)):
		k = k + 1
	assert_equal(3, k)
	assert_equal(7, calls)
	assert_equal(1212121, trace)
	reset()
	k = 0
	while (probe(1, k >= 3) || probe(2, k < 2)):
		k = k + 1
	assert_equal(2, k)
	assert_equal(6, calls)
	assert_equal(121212, trace)


# --- chains and negation as the bottom test ----------------------------------
int chain_and(int a, int b):
	int i = 0
	int n = 0
	while ((i < a) && (i < b)):
		n = n + 1
		i = i + 1
	return n


int chain_or(int a, int b):
	int i = 0
	int n = 0
	while ((i < a) || (i < b)):
		n = n + 1
		i = i + 1
	return n


int chain_mixed(int a, int b, int c):
	int i = 0
	int n = 0
	while (((i < a) && (i < b)) || ((i < c) && !(i >= 10))):
		n = n + 1
		i = i + 1
	return n


int chain_not(int limit):
	int i = 0
	int n = 0
	while (!(i >= limit)):
		n = n + 1
		i = i + 1
	while (!!(i < limit + 2)):
		n = n + 10
		i = i + 1
	return n


struct node:
	int value
	node* next


int chain_pointer(node* p):
	int n = 0
	while ((p != 0) && (p.value > 0)):
		n = n + p.value
		p = p.next
	return n


void test_chains():
	assert_equal(3, chain_and(3, 5))
	assert_equal(3, chain_and(5, 3))
	assert_equal(0, chain_and(0, 5))
	assert_equal(5, chain_or(3, 5))
	assert_equal(5, chain_or(5, 3))
	assert_equal(0, chain_or(0, 0))
	assert_equal(6, chain_mixed(2, 9, 6))
	assert_equal(9, chain_mixed(9, 9, 0))
	assert_equal(20, chain_mixed(20, 20, 20))
	assert_equal(0, chain_mixed(0, 0, 0))
	assert_equal(4 + 20, chain_not(4))
	assert_equal(20, chain_not(0))
	node c
	c.value = 3
	c.next = 0
	node b
	b.value = 2
	b.next = &c
	node a
	a.value = 1
	a.next = &b
	assert_equal(6, chain_pointer(&a))
	b.value = 0
	assert_equal(1, chain_pointer(&a))
	assert_equal(0, chain_pointer(0))


# --- break and continue in nested loops ---------------------------------------
int nested(int rows, int cols, int stop):
	int n = 0
	int i = 0
	while (i < rows):
		i = i + 1
		if (i == 2): continue
		int j = 0
		while (1):
			j = j + 1
			if (j > cols): break
			if (j == stop): continue
			n = n + 1
		if (i == 4): break
	return n * 10 + i


int nested_for(int rows, int cols):
	int n = 0
	for i in range(rows):
		for j in range(cols):
			if (j == i): continue
			if (j > 3): break
			n = n + 1
			for k in range(2, 6, 2):
				if (k == 4): continue
				n = n + 100
	return n


int for_continue_step(int n):
	int sum = 0
	for i in range(0, n, 2):
		if (i == 4): continue
		sum = sum + i
	return sum


void test_nested_break_continue():
	# rows 1, 3, 4 count: cols each minus the stopped one
	assert_equal((3 * 2) * 10 + 4, nested(9, 3, 2))
	assert_equal((3 * 3) * 10 + 4, nested(9, 3, 5))
	assert_equal(0 * 10 + 0, nested(0, 3, 1))
	assert_equal(1 * 10 + 1, nested(1, 1, 7))
	assert_equal(0, nested_for(0, 5))
	assert_equal(2 * 101, nested_for(1, 3))
	assert_equal((3 + 3 + 3) * 101, nested_for(3, 9))
	assert_equal(0 + 2 + 6 + 8, for_continue_step(10))


# --- a for variable the allocator keeps in a register ------------------------
int register_loop(int* a, int n):
	# n, i and sum are word-sized locals used in a loop: the pre-scan
	# promotes them, and the bottom test compares the register copy
	int sum = 0
	for i in range(n):
		a[i] = a[i] * 2 + i
		sum = sum + a[i]
	int back = 0
	int i = n
	while (i > 0):
		i = i - 1
		back = back + a[i]
	return sum - back


void test_register_loop():
	int[8] a
	for i in range(8): a[i] = i
	assert_equal(0, register_loop(&a[0], 8))
	assert_equal(3 + 6, a[1] + a[2])
	assert_equal(0, register_loop(&a[0], 0))
	assert_equal(0, register_loop(&a[0], 1))
	assert_equal(0, a[0])


# --- block openers and what may precede them ---------------------------------
int brace_while(int n):
	int i = 0
	while (i < n) {
		i = i + 1
	}
	int j = 0
	while (j < n) { j = j + 2; }
	return i * 100 + j


int ternary_condition(int n):
	int i = 0
	while (n > 5 ? i < n : i < 2 * n):
		i = i + 1
	return i


int bracket_condition(int* a, int n):
	int i = 0
	int s = 0
	while ((i < n) && (a[i] > 0) && (a[i] < (n > 3 ? 100 : 50))):
		s = s + a[i]
		i = i + 1
	return s


int literal_condition(int n):
	# typed container literals are the only braces an expression holds:
	# the skip must not take them for a block opener
	int i = 0
	while ((i in set[int]{0, 1, 2, 3}) && (i < n)):
		i = i + 1
	int j = 0
	while (j in map[int, int]{0: 1, 1: 1, 2: 1}) {
		j = j + 1
	}
	int k = 0
	while (k < list[int]{5, 6, 7}.length): k = k + 1
	return i * 100 + j * 10 + k


int multiline_condition(int a, int b):
	int i = 0
	while ((i < a) &&
			(i < b)):
		i = i + 1
	return i


int template_condition(int n):
	# a template string in the condition declines the rotation: the
	# loop is top-tested, and must still count right
	int i = 0
	while (f"{i}".length < n):
		i = i + 1
	return i


int single_line(int n):
	int i = 0
	while (i < n): i = i + 1
	int j = 0
	for k in range(n): j = j + k
	return i * 100 + j


void test_block_openers():
	assert_equal(3 * 100 + 4, brace_while(3))
	assert_equal(0, brace_while(0))
	assert_equal(8, ternary_condition(8))
	assert_equal(6, ternary_condition(3))
	int[5] a
	a[0] = 10
	a[1] = 20
	a[2] = 60
	a[3] = 5
	a[4] = -1
	assert_equal(30, bracket_condition(&a[0], 3))
	assert_equal(95, bracket_condition(&a[0], 5))
	assert_equal(0, bracket_condition(&a[0], 0))
	assert_equal(2 * 100 + 3 * 10 + 3, literal_condition(2))
	assert_equal(4 * 100 + 3 * 10 + 3, literal_condition(9))
	assert_equal(2, multiline_condition(2, 5))
	assert_equal(2, multiline_condition(5, 2))
	assert_equal(10, template_condition(2))
	assert_equal(0, template_condition(1))
	assert_equal(4 * 100 + 6, single_line(4))


# --- a body longer than the lexer's read window ------------------------------
int long_body(int n):
	# Every line adds to acc; the loop runs n times. The body is over
	# 8 KiB of source, so returning to the condition after it seeks the
	# file, and returning to the body's end seeks again.
	int i = 0
	int acc = 0
	while (i < n):
		i = i + 1
		acc = acc + 1   # line 001 of the long body, padding the source past one read window
		acc = acc + 1   # line 002 of the long body, padding the source past one read window
		acc = acc + 1   # line 003 of the long body, padding the source past one read window
		acc = acc + 1   # line 004 of the long body, padding the source past one read window
		acc = acc + 1   # line 005 of the long body, padding the source past one read window
		acc = acc + 1   # line 006 of the long body, padding the source past one read window
		acc = acc + 1   # line 007 of the long body, padding the source past one read window
		acc = acc + 1   # line 008 of the long body, padding the source past one read window
		acc = acc + 1   # line 009 of the long body, padding the source past one read window
		acc = acc + 1   # line 010 of the long body, padding the source past one read window
		acc = acc + 1   # line 011 of the long body, padding the source past one read window
		acc = acc + 1   # line 012 of the long body, padding the source past one read window
		acc = acc + 1   # line 013 of the long body, padding the source past one read window
		acc = acc + 1   # line 014 of the long body, padding the source past one read window
		acc = acc + 1   # line 015 of the long body, padding the source past one read window
		acc = acc + 1   # line 016 of the long body, padding the source past one read window
		acc = acc + 1   # line 017 of the long body, padding the source past one read window
		acc = acc + 1   # line 018 of the long body, padding the source past one read window
		acc = acc + 1   # line 019 of the long body, padding the source past one read window
		acc = acc + 1   # line 020 of the long body, padding the source past one read window
		acc = acc + 1   # line 021 of the long body, padding the source past one read window
		acc = acc + 1   # line 022 of the long body, padding the source past one read window
		acc = acc + 1   # line 023 of the long body, padding the source past one read window
		acc = acc + 1   # line 024 of the long body, padding the source past one read window
		acc = acc + 1   # line 025 of the long body, padding the source past one read window
		acc = acc + 1   # line 026 of the long body, padding the source past one read window
		acc = acc + 1   # line 027 of the long body, padding the source past one read window
		acc = acc + 1   # line 028 of the long body, padding the source past one read window
		acc = acc + 1   # line 029 of the long body, padding the source past one read window
		acc = acc + 1   # line 030 of the long body, padding the source past one read window
		acc = acc + 1   # line 031 of the long body, padding the source past one read window
		acc = acc + 1   # line 032 of the long body, padding the source past one read window
		acc = acc + 1   # line 033 of the long body, padding the source past one read window
		acc = acc + 1   # line 034 of the long body, padding the source past one read window
		acc = acc + 1   # line 035 of the long body, padding the source past one read window
		acc = acc + 1   # line 036 of the long body, padding the source past one read window
		acc = acc + 1   # line 037 of the long body, padding the source past one read window
		acc = acc + 1   # line 038 of the long body, padding the source past one read window
		acc = acc + 1   # line 039 of the long body, padding the source past one read window
		acc = acc + 1   # line 040 of the long body, padding the source past one read window
		acc = acc + 1   # line 041 of the long body, padding the source past one read window
		acc = acc + 1   # line 042 of the long body, padding the source past one read window
		acc = acc + 1   # line 043 of the long body, padding the source past one read window
		acc = acc + 1   # line 044 of the long body, padding the source past one read window
		acc = acc + 1   # line 045 of the long body, padding the source past one read window
		acc = acc + 1   # line 046 of the long body, padding the source past one read window
		acc = acc + 1   # line 047 of the long body, padding the source past one read window
		acc = acc + 1   # line 048 of the long body, padding the source past one read window
		acc = acc + 1   # line 049 of the long body, padding the source past one read window
		acc = acc + 1   # line 050 of the long body, padding the source past one read window
		acc = acc + 1   # line 051 of the long body, padding the source past one read window
		acc = acc + 1   # line 052 of the long body, padding the source past one read window
		acc = acc + 1   # line 053 of the long body, padding the source past one read window
		acc = acc + 1   # line 054 of the long body, padding the source past one read window
		acc = acc + 1   # line 055 of the long body, padding the source past one read window
		acc = acc + 1   # line 056 of the long body, padding the source past one read window
		acc = acc + 1   # line 057 of the long body, padding the source past one read window
		acc = acc + 1   # line 058 of the long body, padding the source past one read window
		acc = acc + 1   # line 059 of the long body, padding the source past one read window
		acc = acc + 1   # line 060 of the long body, padding the source past one read window
		acc = acc + 1   # line 061 of the long body, padding the source past one read window
		acc = acc + 1   # line 062 of the long body, padding the source past one read window
		acc = acc + 1   # line 063 of the long body, padding the source past one read window
		acc = acc + 1   # line 064 of the long body, padding the source past one read window
		acc = acc + 1   # line 065 of the long body, padding the source past one read window
		acc = acc + 1   # line 066 of the long body, padding the source past one read window
		acc = acc + 1   # line 067 of the long body, padding the source past one read window
		acc = acc + 1   # line 068 of the long body, padding the source past one read window
		acc = acc + 1   # line 069 of the long body, padding the source past one read window
		acc = acc + 1   # line 070 of the long body, padding the source past one read window
		acc = acc + 1   # line 071 of the long body, padding the source past one read window
		acc = acc + 1   # line 072 of the long body, padding the source past one read window
		acc = acc + 1   # line 073 of the long body, padding the source past one read window
		acc = acc + 1   # line 074 of the long body, padding the source past one read window
		acc = acc + 1   # line 075 of the long body, padding the source past one read window
		acc = acc + 1   # line 076 of the long body, padding the source past one read window
		acc = acc + 1   # line 077 of the long body, padding the source past one read window
		acc = acc + 1   # line 078 of the long body, padding the source past one read window
		acc = acc + 1   # line 079 of the long body, padding the source past one read window
		acc = acc + 1   # line 080 of the long body, padding the source past one read window
		acc = acc + 1   # line 081 of the long body, padding the source past one read window
		acc = acc + 1   # line 082 of the long body, padding the source past one read window
		acc = acc + 1   # line 083 of the long body, padding the source past one read window
		acc = acc + 1   # line 084 of the long body, padding the source past one read window
		acc = acc + 1   # line 085 of the long body, padding the source past one read window
		acc = acc + 1   # line 086 of the long body, padding the source past one read window
		acc = acc + 1   # line 087 of the long body, padding the source past one read window
		acc = acc + 1   # line 088 of the long body, padding the source past one read window
		acc = acc + 1   # line 089 of the long body, padding the source past one read window
		acc = acc + 1   # line 090 of the long body, padding the source past one read window
		acc = acc + 1   # line 091 of the long body, padding the source past one read window
		acc = acc + 1   # line 092 of the long body, padding the source past one read window
		acc = acc + 1   # line 093 of the long body, padding the source past one read window
		acc = acc + 1   # line 094 of the long body, padding the source past one read window
		acc = acc + 1   # line 095 of the long body, padding the source past one read window
		acc = acc + 1   # line 096 of the long body, padding the source past one read window
		acc = acc + 1   # line 097 of the long body, padding the source past one read window
		acc = acc + 1   # line 098 of the long body, padding the source past one read window
		acc = acc + 1   # line 099 of the long body, padding the source past one read window
		acc = acc + 1   # line 100 of the long body, padding the source past one read window
		acc = acc + 1   # line 101 of the long body, padding the source past one read window
		acc = acc + 1   # line 102 of the long body, padding the source past one read window
		acc = acc + 1   # line 103 of the long body, padding the source past one read window
		acc = acc + 1   # line 104 of the long body, padding the source past one read window
		acc = acc + 1   # line 105 of the long body, padding the source past one read window
		acc = acc + 1   # line 106 of the long body, padding the source past one read window
		acc = acc + 1   # line 107 of the long body, padding the source past one read window
		acc = acc + 1   # line 108 of the long body, padding the source past one read window
		acc = acc + 1   # line 109 of the long body, padding the source past one read window
		acc = acc + 1   # line 110 of the long body, padding the source past one read window
		acc = acc + 1   # line 111 of the long body, padding the source past one read window
		acc = acc + 1   # line 112 of the long body, padding the source past one read window
		acc = acc + 1   # line 113 of the long body, padding the source past one read window
		acc = acc + 1   # line 114 of the long body, padding the source past one read window
		acc = acc + 1   # line 115 of the long body, padding the source past one read window
		acc = acc + 1   # line 116 of the long body, padding the source past one read window
		acc = acc + 1   # line 117 of the long body, padding the source past one read window
		acc = acc + 1   # line 118 of the long body, padding the source past one read window
		acc = acc + 1   # line 119 of the long body, padding the source past one read window
		acc = acc + 1   # line 120 of the long body, padding the source past one read window
	return acc * 1000 + i


void test_long_body():
	assert_equal(0, long_body(0))
	assert_equal(120 * 1000 + 1, long_body(1))
	assert_equal(3 * 120 * 1000 + 3, long_body(3))


# --- defer in a loop body: registered once, run at the function's exit -------
int deferred_seen


void note_deferred(int v):
	deferred_seen = deferred_seen * 10 + v


int defer_in_loop(int n):
	int i = 0
	while (i < n):
		i = i + 1
		defer note_deferred(i)
	for j in range(n):
		defer note_deferred(j)
	return i


void test_defer_in_loop():
	deferred_seen = 0
	assert_equal(3, defer_in_loop(3))
	# both spans re-parse at exit with the final values: j is 3, i is 3
	assert_equal(33, deferred_seen)
	deferred_seen = 0
	assert_equal(0, defer_in_loop(0))
	assert_equal(0, deferred_seen)


# --- goto out of a loop, and back to a label before one ----------------------
int goto_out(int target):
	int result = -1
	int i = 0
	while (i < 10):
		int j = 0
		while (j < 10):
			if (i * 10 + j == target):
				result = target
				goto found
			j = j + 1
		i = i + 1
	found:
	return result * 100 + i


int goto_back(int rounds):
	int n = 0
	int r = 0
	again:
	for i in range(3): n = n + 1
	r = r + 1
	if (r < rounds): goto again
	return n


void test_goto():
	assert_equal(4200 + 4, goto_out(42))
	assert_equal(-100 + 10, goto_out(1000))
	assert_equal(0 + 0, goto_out(0))
	assert_equal(9, goto_back(3))
	assert_equal(3, goto_back(0))


# --- generators looping ---------------------------------------------------------
generator int evens_below(int n):
	int i = 0
	while (i < n):
		yield i
		i = i + 2


generator int squares(int n):
	for i in range(n):
		if (i == 1): continue
		yield i * i


int sum_generator(generator* g):
	int sum = 0
	while (gen_next(g)): sum = sum + gen_value(g)
	gen_free(g)
	return sum


void test_generators():
	assert_equal(0 + 2 + 4 + 6, sum_generator(evens_below(7)))
	assert_equal(0, sum_generator(evens_below(0)))
	assert_equal(0 + 4 + 9 + 16, sum_generator(squares(5)))
	int sum = 0
	for v in squares(4): sum = sum + v
	assert_equal(0 + 4 + 9, sum)
	int none = 0
	for v in evens_below(-1): none = none + 1
	assert_equal(0, none)


# --- infinite loops left by break: the constant condition folds to a jump ------
int forever_break(int n):
	int i = 0
	while (1):
		if (i >= n): break
		i = i + 1
	int j = 0
	while 1:
		j = j + 1
		if (j >= n): break
	int k = 0
	while (true):
		if (k == n): break
		k = k + 1
	int m = 0
	while true:
		m = m + 1
		if (m > n): break
	# never entered: a constant-false condition
	int z = 0
	while (0): z = z + 1
	while 0: z = z + 1
	return i * 1000 + j * 100 + k * 10 + m + z


void test_forever():
	assert_equal(0 * 1000 + 1 * 100 + 0 * 10 + 1, forever_break(0))
	assert_equal(3 * 1000 + 3 * 100 + 3 * 10 + 4, forever_break(3))


# --- for-in over containers, empty and not ---------------------------------------
int sum_list(list[int] items):
	int sum = 0
	for v in items: sum = sum + v
	return sum


int sum_map(map[int, int] m):
	int sum = 0
	for int k, int v in m: sum = sum + k * v
	return sum


int count_slice(int[] s):
	int n = 0
	for v in s:
		if (v < 0): continue
		n = n + 1
	return n


int count_string(string s):
	int n = 0
	for c in s:
		if (c == 'x'): break
		n = n + 1
	return n


void test_containers():
	list[int] items = new list[int]
	assert_equal(0, sum_list(items))
	items.push(4)
	assert_equal(4, sum_list(items))
	items.push(5)
	items.push(6)
	assert_equal(15, sum_list(items))
	map[int, int] m = new map[int, int]
	assert_equal(0, sum_map(m))
	m[2] = 3
	m[4] = 5
	assert_equal(2 * 3 + 4 * 5, sum_map(m))
	int[6] raw
	for i in range(6): raw[i] = i - 2
	assert_equal(4, count_slice(raw[0:6]))
	assert_equal(0, count_slice(raw[0:0]))
	assert_equal(1, count_slice(raw[2:3]))
	assert_equal(3, count_string(s"abcxdef"))
	assert_equal(0, count_string(s""))
	assert_equal(2, count_string(s"ab"))


# --- break inside a switch inside a loop leaves the switch, not the loop --------
int switch_in_loop(int n):
	int i = 0
	int seen = 0
	while (i < n):
		i = i + 1
		switch (i):
			case 2:
				seen = seen + 10
				break
			case 3:
				seen = seen + 100
				continue
			default:
				seen = seen + 1
		seen = seen + 1000
	return seen


void test_switch_in_loop():
	assert_equal(0, switch_in_loop(0))
	assert_equal(1 + 1000, switch_in_loop(1))
	assert_equal(1 + 1000 + 10 + 1000 + 100 + 1 + 1000, switch_in_loop(4))


int main():
	test_iteration_counts()
	test_condition_calls()
	test_chains()
	test_nested_break_continue()
	test_register_loop()
	test_block_openers()
	test_long_body()
	test_defer_in_loop()
	test_goto()
	test_generators()
	test_forever()
	test_containers()
	test_switch_in_loop()
	println(c"loop_rotate_test passed")
	return 0
