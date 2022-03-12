

/*int range(int max):
	int i = 0
	while (i < max):
		yield i
		i = i + 1


int main():
	print("printing two iterated elements: ")
	int it = range(4)
	print(itoa(it()))
	print(", ")
	print(itoa(it()))
	println(".")
	println("printing 0...9: ")

	return 0


void test_variable_range():
	int n = 10
	int c = 0
	for int i in range(n + 10):
		c = c + 1
	assert_equal(20, c)


int pint(int val):
	println2(itoa(val))
	return val

*/
import testing


void test_for_in_range_basic():
	int result = 0
	for int i in range 10:
		if (verbosity >= 1):
			print_int("i: ", i)
			print_int("result: ", result)
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
				print_int0("i: ", i)
				print_int0(", j: ", j)
				print_int(", result: ", result)
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

