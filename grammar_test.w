import testing


int test_arithmetic():
	assert_equal(7, 3 + 2 * 2)


int test_dereference():
	int x = 1337
	int* y = &x
	assert(x - *(y + 10 - 10))

# no main() method
# import only, no other declarations
