import testing


void test_1():
	assert_equal(4, 1 + 3)


void test_2():
	assert_equal(4, 1 + 3)


void test_itoa_0():
	assert_equal(strcmp("0", itoa(0)), 0)


void test_fail():
	assert(1)
