# wbuild: x64
# Comparison-branch semantics across every condition context, pinning the
# comparison-branch fusion contract (code_generator/x86.w, optimization.md
# §1.3): a bare comparison in an if/while/for/switch/ternary condition
# branches on the cmp's flags directly, while &&/|| — whose short-circuit
# edge carries the operand value to the booleanize step — and stored or
# argument-position comparisons keep the materialized 0/1.
import lib.assert

int side_calls

int side(int v):
	side_calls = side_calls + 1
	return v

int pick(int a, int b):
	if (a < b):
		return a
	return b

int count_below(int n):
	int i = 0
	int c = 0
	while (i < n):
		i = i + 1
		c = c + 1
	return c

int sum_to(int n):
	int total = 0
	for i in range(n):
		total = total + i
	return total

int classify(int x):
	switch (x):
		case 1, 2:
			return 10
		case 3:
			return 30
		default:
			return 99

int main():
	# if / elif with each comparison operator, both branch outcomes
	assert_equal(3, pick(3, 7))
	assert_equal(4, pick(9, 4))
	int ok = 0
	if (5 <= 5):
		ok = 1
	assert_equal(1, ok)
	if (5 >= 6):
		assert_equal(1, 0)
	if (5 > 5):
		assert_equal(1, 0)
	if (5 != 5):
		assert_equal(1, 0)
	ok = 0
	if (5 == 5):
		ok = 1
	assert_equal(1, ok)

	# while / for loop conditions
	assert_equal(7, count_below(7))
	assert_equal(0, count_below(0))
	assert_equal(10, sum_to(5))

	# switch multi-value and single-value cases
	assert_equal(10, classify(1))
	assert_equal(10, classify(2))
	assert_equal(30, classify(3))
	assert_equal(99, classify(8))

	# ternary condition, both outcomes
	assert_equal(1, (3 < 4) ? 1 : 2)
	assert_equal(2, (4 < 3) ? 1 : 2)

	# stored comparisons still materialize 0/1
	bool t = 3 < 4
	bool f = 4 < 3
	assert_equal(1, cast(int, t))
	assert_equal(0, cast(int, f))

	# && and || keep short-circuit order and booleanized results: the
	# short-circuit edge must deliver the operand value, not flags
	side_calls = 0
	if ((2 < 1) && (side(1) == 1)):
		assert_equal(1, 0)
	assert_equal(0, side_calls)
	side_calls = 0
	ok = 0
	if ((1 < 2) || (side(1) == 1)):
		ok = 1
	assert_equal(1, ok)
	assert_equal(0, side_calls)
	int v = ((3 < 2) && 7) ? 100 : 200
	assert_equal(200, v)
	v = ((3 < 2) || 7) ? 100 : 200
	assert_equal(100, v)
	assert_equal(1, cast(int, (5 > 1) && (2 != 3)))
	assert_equal(0, cast(int, (5 > 1) && (2 == 3)))

	# comparison as a call argument (not a branch)
	side_calls = 0
	assert_equal(1, side(cast(int, 1 < 2)))
	assert_equal(1, side_calls)

	# float comparisons in conditions (their own setcc path)
	float x = 1.5
	float y = 2.5
	ok = 0
	if (x < y):
		ok = 1
	assert_equal(1, ok)
	if (y < x):
		assert_equal(1, 0)

	println(c"comparison branch test OK")
	return 0
