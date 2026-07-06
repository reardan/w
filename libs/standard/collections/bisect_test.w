import lib.testing
import libs.standard.collections.bisect


int* bisect_test_values():
	int* values = malloc(7 * __word_size__)
	values[0] = 1
	values[1] = 2
	values[2] = 2
	values[3] = 2
	values[4] = 5
	values[5] = 8
	values[6] = 13
	return values


void test_bisect_left_int():
	int* values = bisect_test_values()
	assert_equal(0, bisect_left_int(values, 7, 0))
	assert_equal(1, bisect_left_int(values, 7, 2))
	assert_equal(4, bisect_left_int(values, 7, 3))
	assert_equal(7, bisect_left_int(values, 7, 99))
	free(values)


void test_bisect_right_int():
	int* values = bisect_test_values()
	assert_equal(0, bisect_right_int(values, 7, 0))
	assert_equal(4, bisect_right_int(values, 7, 2))
	assert_equal(4, bisect_right_int(values, 7, 3))
	assert_equal(7, bisect_right_int(values, 7, 13))
	free(values)


void test_bisect_empty_and_negative_length():
	int* values = bisect_test_values()
	assert_equal(0, bisect_left_int(values, 0, 5))
	assert_equal(0, bisect_right_int(values, -3, 5))
	free(values)
