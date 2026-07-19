# wbuild: x64
# 'return' (and '?') out of a for loop over a generator must free the
# suspended generator's 64KB stack and its object, exactly like the
# loop's normal-exit and break edges do (docs/projects/iteration.md).
import lib.testing
import lib.generator
import lib.result
import lib.file


generator int counter(int n):
	int i = 0
	while (i < n):
		yield i
		i = i + 1


# Block locals between the loop's hidden slots and the return stress the
# stack_pos-anchored addressing of the emitted gen_free call.
int first_value_plus(int n):
	for int x in counter(n):
		int bonus = 100
		if (x == 2):
			int extra = bonus + x
			return extra
	return 0 - 1


# A return inside two nested generator loops must free both suspended
# generators.
int nested_return_value(int n):
	for int x in counter(n):
		for int y in counter(n):
			if (y == 1):
				return x * 100 + y
	return 0 - 1


# Returning from a plain loop nested inside the generator loop still
# frees the enclosing generator.
int return_through_inner_while(int n):
	for int x in counter(n):
		int i = 0
		while (i < 10):
			if ((x == 1) && (i == 3)):
				return x * 10 + i
			i = i + 1
	return 0 - 1


int defer_side_effect


void bump_side_effect():
	defer_side_effect = defer_side_effect + 1


# Deferred statements still run on the way out, after the generator is
# freed, with the return value preserved around both.
int return_with_defer(int n):
	defer bump_side_effect()
	for int x in counter(n):
		if (x == 1):
			return x + 40
	return 0 - 1


# 'return' inside a generator body that is itself iterating another
# generator must free the inner one before finishing.
generator int early_pairs(int n):
	for int x in counter(n):
		if (x == 2):
			return
		yield x * 2


int consume_early_pairs(int n):
	int sum = 0
	for int v in early_pairs(n):
		sum = sum + v
	return sum


wresult[int]* find_number(int key):
	if (key < 0):
		return result_new_error[int](-2)
	return result_new_ok[int](key * 10)


# '?' error propagation is a function exit like 'return': the error
# path must free the suspended generator too.
wresult[int]* pick_number(int n, int key):
	for int x in counter(n):
		if (x == 3):
			int v = find_number(key)?
			return result_new_ok[int](v + x)
	return result_new_error[int](0 - 1)


int pick_number_code(int n, int key):
	wresult[int]* r = pick_number(n, key)
	int code = result_code[int](r)
	if (result_is_ok[int](r)):
		code = result_value[int](r)
	result_free[int](r)
	return code


void test_return_value_from_generator_loop():
	assert_equal(102, first_value_plus(1000))


void test_return_from_nested_generator_loops():
	assert_equal(1, nested_return_value(1000))


void test_return_from_inner_while_in_generator_loop():
	assert_equal(13, return_through_inner_while(1000))


void test_defer_runs_after_return_from_generator_loop():
	defer_side_effect = 0
	assert_equal(41, return_with_defer(1000))
	assert_equal(1, defer_side_effect)


void test_return_inside_generator_body_frees_inner():
	assert_equal(2, consume_early_pairs(1000)) /* yields 0, 2, then returns */


void test_result_propagation_from_generator_loop():
	assert_equal(-2, pick_number_code(1000, 0 - 5)) /* error path */
	assert_equal(53, pick_number_code(1000, 5))     /* ok path: 5*10 + 3 */


# Total program size in pages, from /proc/self/statm (field 1). Every
# leaked generator stack holds a 64KB mapping, so leaks show up here.
int vsz_pages():
	char* text = file_read_text(c"/proc/self/statm")
	asserts(c"/proc/self/statm is readable", cast(int, text) != 0)
	int pages = 0
	int i = 0
	while ((text[i] >= '0') && (text[i] <= '9')):
		pages = pages * 10 + (text[i] - '0')
		i = i + 1
	free(text)
	return pages


void leak_round(int n):
	assert_equal(102, first_value_plus(n))
	assert_equal(1, nested_return_value(n))
	assert_equal(13, return_through_inner_while(n))
	assert_equal(41, return_with_defer(n))
	assert_equal(2, consume_early_pairs(n))
	assert_equal(-2, pick_number_code(n, 0 - 5))


void test_early_function_exits_do_not_leak_generator_stacks():
	# Warm up the allocator and stream buffers so the measured window
	# only sees the loops under test
	int i = 0
	while (i < 8):
		leak_round(1000)
		vsz_pages()
		i = i + 1

	int before = vsz_pages()
	i = 0
	while (i < 256):
		leak_round(1000)
		i = i + 1
	int after = vsz_pages()

	# Each round abandons 7 suspended generators mid-iteration; leaking
	# them would map 256 * 7 * 16 pages (112MB). Allow generous slack
	# for allocator growth.
	asserts(c"early function exits leaked generator stacks", after - before < 1024)
