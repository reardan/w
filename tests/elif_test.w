# 'elif cond:' is pure sugar for 'else if cond:' (issue #360): a chain
# compiles exactly like the spelled-out nesting, binds by indent level
# like 'else', mixes with a trailing 'else', and supports the same-line
# body form.
# wbuild: x64
import lib.assert


int classify(int x):
	if x < 0:
		return -1
	elif x == 0:
		return 0
	elif x < 10:
		return 1
	else:
		return 2


# elif without a trailing else: no branch taken leaves the value alone
int no_else(int x):
	r := 0
	if x == 1:
		r = 10
	elif x == 2:
		r = 20
	elif x == 3:
		r = 30
	return r


# Parenthesized conditions work like they do for if
int with_parens(int x):
	if (x == 1):
		return 100
	elif (x == 2):
		return 200
	return 0


# Same-line bodies: 'elif cond: statement' mirrors 'if cond: statement'
int same_line(int x):
	if x == 1: return 1
	elif x == 2: return 2
	elif x == 3: return 3
	else: return 4


# An elif only binds to an if at the same indent level: the inner
# if/elif chain closes before the outer elif
int nested(int a, int b):
	if a:
		if b:
			return 3
		elif a > 1:
			return 2
	elif b:
		return 1
	return 0


# elif conditions short-circuit: later conditions must not evaluate
# once an earlier branch was taken
int side_effect_count
int bump():
	side_effect_count = side_effect_count + 1
	return 1


int short_circuit(int x):
	if x == 1:
		return 1
	elif bump():
		return 2
	return 3


int main():
	assert_equal(-1, classify(-5))
	assert_equal(0, classify(0))
	assert_equal(1, classify(5))
	assert_equal(2, classify(50))

	assert_equal(10, no_else(1))
	assert_equal(20, no_else(2))
	assert_equal(30, no_else(3))
	assert_equal(0, no_else(9))

	assert_equal(100, with_parens(1))
	assert_equal(200, with_parens(2))
	assert_equal(0, with_parens(3))

	assert_equal(1, same_line(1))
	assert_equal(2, same_line(2))
	assert_equal(3, same_line(3))
	assert_equal(4, same_line(4))

	assert_equal(3, nested(1, 1))
	assert_equal(2, nested(2, 0))
	assert_equal(1, nested(0, 1))
	assert_equal(0, nested(0, 0))

	side_effect_count = 0
	assert_equal(1, short_circuit(1))
	assert_equal(0, side_effect_count)
	assert_equal(2, short_circuit(2))
	assert_equal(1, side_effect_count)

	# A long chain: every branch lands where it should
	total := 0
	for i in range(6):
		if i == 0:
			total += 1
		elif i == 1:
			total += 10
		elif i == 2:
			total += 100
		elif i == 3:
			total += 1000
		elif i == 4:
			total += 10000
		else:
			total += 100000
	assert_equal(111111, total)

	println(c"elif_test passed")
	return 0
