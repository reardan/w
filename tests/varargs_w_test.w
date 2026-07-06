# W-native variadic functions: "T... name" as the last parameter collects
# the trailing arguments into a T[] slice built on the caller's stack.
# Distinct from variadic C imports (tests/varargs_test.w), which go through
# the inline C ABI path. See docs/projects/default_args_variadics.md.
import lib.testing


int vw_sum(int... values):
	int total = 0
	for int v in values:
		total = total + v
	return total


void test_sum_zero_one_many():
	assert_equal(0, vw_sum())
	assert_equal(5, vw_sum(5))
	assert_equal(6, vw_sum(1, 2, 3))
	assert_equal(55, vw_sum(1, 2, 3, 4, 5, 6, 7, 8, 9, 10))


int vw_count(int... values):
	return values.length


void test_length():
	assert_equal(0, vw_count())
	assert_equal(1, vw_count(42))
	assert_equal(4, vw_count(4, 3, 2, 1))


int vw_at(int index, int... values):
	return values[index]


void test_indexing_preserves_order():
	assert_equal(7, vw_at(0, 7, 8, 9))
	assert_equal(8, vw_at(1, 7, 8, 9))
	assert_equal(9, vw_at(2, 7, 8, 9))
	assert_equal(21, vw_at(1, 20, 21))


int vw_weighted(int factor, int offset, int... values):
	int total = offset
	for int v in values:
		total = total + v * factor
	return total


void test_variadic_after_fixed_params():
	assert_equal(100, vw_weighted(2, 100))
	assert_equal(112, vw_weighted(2, 100, 1, 2, 3))
	assert_equal(-6, vw_weighted(-1, 0, 1, 2, 3))


int vw_total_len(char*... parts):
	int total = 0
	for char* part in parts:
		total = total + strlen(part)
	return total


void test_char_pointer_elements():
	assert_equal(0, vw_total_len())
	assert_equal(5, vw_total_len(c"ab", c"cde"))
	assert_equal(9, vw_total_len(c"one", c"two", c"six"))


void test_computed_expressions():
	int x = 4
	int y = 10
	assert_equal(4 + 1 + 20 + 6, vw_sum(x + 1, y * 2, vw_count(1, 2, 3) * 2))


void test_nested_variadic_calls():
	assert_equal(6, vw_sum(vw_sum(1, 2), 3))
	assert_equal(21, vw_sum(vw_sum(1, 2), vw_sum(3, vw_sum(4, 5)), 6))
	assert_equal(3, vw_count(vw_count(), vw_count(1), vw_count(1, 2)))


void test_variadic_call_in_loop():
	int total = 0
	for int i in range(10):
		total = total + vw_sum(i, i, 1)
	assert_equal(90 + 10, total)


int vw_sum_by_index(int... values):
	int total = 0
	for int i in range(values.length):
		total = total + values[i]
	return total


void test_iterate_by_index():
	assert_equal(0, vw_sum_by_index())
	assert_equal(60, vw_sum_by_index(10, 20, 30))


struct vw_acc:
	int base


int vw_acc_add(vw_acc* self, int... values):
	int total = self.base
	for int v in values:
		total = total + v
	return total


void test_variadic_struct_method():
	vw_acc a
	a.base = 100
	assert_equal(100, a.add())
	assert_equal(106, a.add(1, 2, 3))
