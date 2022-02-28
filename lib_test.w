import testing










# Basic test cases

void test_1():
	assert_equal(4, 1 + 3)


void test_2():
	assert_equal(4, 1 + 3)


void test_itoa_0():
	assert_equal(strcmp("0", itoa(0)), 0)


void test_println():
	println("hi there!")


void test_fail():
	#assert1(0)
	assert1(1)
	asserts("test_fail", 1)
	int i


void test_reverse_n():
	char *hey = "hey there"
	reverse_n(hey, 3)
	assert_strings_equal("yeh there", hey)

# reverse_n():
# n > strlen() would have to be checked with O(n)
# unless we explicitly do this before reversing
# right now, we use a fixed n that is assumed to be within bounds
# we could then fix via min(n, strlen(str))


void test_reverse_odd():
	char *me = "reverseme"
	reverse(me)
	assert_strings_equal("emesrever", me)


void test_reverse_even():
	char *me = "even"
	reverse(me)
	assert_strings_equal("neve", me)


void test_large_reverse():
	int length = 1000
	# TODO
