import lib.testing

void test_range_one_arg():
	int result = 0
	for int i in range(10):
		result = result + 10
	assert_equal(100, result)
