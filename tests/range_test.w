

import lib.testing


void test_variable_range():
	int n = 10
	int c = 0
	for int i in range(n + 10):
		c = c + 1
	assert_equal(20, c)


void test_for_in_range_basic():
	int result = 0
	for int i in range 10:
		if (verbosity >= 1):
			print_int(c"i: ", i)
			print_int(c"result: ", result)
		result = result + 10
	assert_equal(10, i)
	assert_equal(100, result)


void test_zero_value_nested():
	for int i in range 1:
		for int j in range 1:
			assert_equal(0, j)
			assert_equal(0, i)


void test_for_in_range_nested():
	int result = 0
	for int i in range 10:
		for int j in range 10:
			result = result + 10
			if (verbosity >= 1):
				print_int0(c"i: ", i)
				print_int0(c", j: ", j)
				print_int(c", result: ", result)
		assert_equal(10, j)
	assert_equal(10, i)
	assert_equal(1000, result)


void test_for_in_range_tri_nested():
	int result = 0
	for int i in range 10:
		for int j in range 10:
			for int k in range 10:
				result = result + 10
	assert_equal(10000, result)


void test_for_in_range_with_starter():
	int result = 0
	for int i in range 1, 10:
		result = result + 10
	assert_equal(90, result)


void test_range_start_end():
	int sum = 0
	for int i in range(5, 8):
		sum = sum + i
	assert_equal(18, sum)


void test_range_start_end_step():
	int sum = 0
	for int i in range(0, 10, 2):
		sum = sum + i
	assert_equal(20, sum)
	assert_equal(10, i)


void test_range_step_expressions():
	int start = 10
	int sum = 0
	for int i in range(start, start * 2, 5):
		sum = sum + i
	assert_equal(25, sum)


void test_for_break():
	int c = 0
	for int i in range 10:
		if (i == 3):
			break
		c = c + 1
	assert_equal(3, c)


void test_for_continue():
	int c = 0
	for int i in range 10:
		if (i % 2 == 0):
			continue
		c = c + 1
	assert_equal(5, c)


void test_nested_loop_break():
	int c = 0
	for int i in range 3:
		for int j in range 10:
			if (j == 2):
				break
			c = c + 1
	assert_equal(6, c)

