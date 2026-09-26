# wbuild: x64
# wbuild: step="bin/wv2 tests/for_container_error_fixture.w -o bin/for_container_error_fixture" expect_fail expect_stderr="type 'point' is not iterable: point_iter_begin not found"
# wbuild: step="bin/wv2 tests/for_container_raw_pointer_error_fixture.w -o bin/for_container_raw_pointer_error_fixture" expect_fail expect_stderr="type 'int*' is not iterable: expected a pointer to a container struct"
# wbuild: step="bin/wv2 tests/for_container_non_function_error_fixture.w -o bin/for_container_non_function_error_fixture" expect_fail expect_stderr="type 'bad_iter_symbol' is not iterable: bad_iter_symbol_iter_begin is not a function"
# wbuild: step="bin/wv2 tests/for_container_wrong_arity_error_fixture.w -o bin/for_container_wrong_arity_error_fixture" expect_fail expect_stderr="type 'bad_iter_arity' is not iterable: bad_iter_arity_iter_begin has wrong arity"
# wbuild: step="bin/wv2 tests/for_container_void_return_error_fixture.w -o bin/for_container_void_return_error_fixture" expect_fail expect_stderr="type 'bad_iter_return' is not iterable: bad_iter_return_iter_begin must return a word-sized value"
# wbuild: step="bin/wv2 tests/for_container_wrong_param_error_fixture.w -o bin/for_container_wrong_param_error_fixture" expect_fail expect_stderr="type 'bad_iter_param' is not iterable: bad_iter_param_iter_begin first parameter must match the iterable type"
# for x in <container> — cursor-protocol iteration over the standard
# containers and a user-defined one (docs/projects/iteration.md, design 3).
import lib.testing


# A minimal user-defined int container: for-in lowers to its
# int_list_iter_begin/done/next/value cursor functions.
struct int_list:
	int length
	int capacity
	int* items


int_list* int_list_new():
	int_list* l = new int_list
	l.length = 0
	l.capacity = 8
	l.items = cast(int*, malloc(8 * __word_size__))
	return l


void int_list_push(int_list* l, int value):
	if (l.length == l.capacity):
		l.items = cast(int*, realloc(l.items, l.capacity * __word_size__, 2 * l.capacity * __word_size__))
		l.capacity = 2 * l.capacity
	l.items[l.length] = value
	l.length = l.length + 1


void int_list_free(int_list* l):
	free(l.items)
	free(l)


int int_list_iter_begin(int_list* l):
	return 0


int int_list_iter_done(int_list* l, int cursor):
	return cursor >= l.length


int int_list_iter_next(int_list* l, int cursor):
	return cursor + 1


int int_list_iter_value(int_list* l, int cursor):
	return l.items[cursor]


void test_int_list_sum():
	int_list* a = int_list_new()
	int_list_push(a, 4)
	int_list_push(a, 5)
	int_list_push(a, 6)
	int sum = 0
	int count = 0
	for int x in a:
		sum = sum + x
		count = count + 1
	assert_equal(15, sum)
	assert_equal(3, count)
	int_list_free(a)


void test_int_list_empty():
	int_list* a = int_list_new()
	int count = 0
	for int x in a: count = count + 1
	assert_equal(0, count)
	int_list_free(a)


void test_int_list_break():
	int_list* a = int_list_new()
	for int i in range(10): int_list_push(a, i)
	int sum = 0
	for int x in a:
		if (x == 3): break
		sum = sum + x
	assert_equal(3, sum) /* 0 + 1 + 2 */
	int_list_free(a)


void test_int_list_continue():
	int_list* a = int_list_new()
	for int i in range(10): int_list_push(a, i)
	int sum = 0
	for int x in a:
		if (x % 2): continue
		sum = sum + x
	assert_equal(20, sum) /* 0 + 2 + 4 + 6 + 8 */
	int_list_free(a)


void test_nested_two_lists():
	int_list* outer = int_list_new()
	int_list_push(outer, 1)
	int_list_push(outer, 2)
	int_list* inner = int_list_new()
	int_list_push(inner, 10)
	int_list_push(inner, 20)
	int sum = 0
	for int x in outer:
		for int y in inner: sum = sum + x * y
	assert_equal(90, sum) /* (1+2) * (10+20) */
	int_list_free(outer)
	int_list_free(inner)


void test_nested_same_list():
	int_list* a = int_list_new()
	int_list_push(a, 1)
	int_list_push(a, 2)
	int_list_push(a, 3)
	int count = 0
	for int x in a:
		for int y in a: count = count + 1
	assert_equal(9, count)
	int_list_free(a)


void test_nested_break_inner_only():
	int_list* a = int_list_new()
	int_list_push(a, 1)
	int_list_push(a, 2)
	int_list_push(a, 3)
	int count = 0
	for int x in a:
		for int y in a:
			if (y == 2): break
			count = count + 1
	assert_equal(3, count) /* inner loop runs once per outer element */
	int_list_free(a)


void test_range_inside_container_loop():
	int_list* a = int_list_new()
	int_list_push(a, 2)
	int_list_push(a, 3)
	int sum = 0
	for int x in a:
		for int i in range(x): sum = sum + 1
	assert_equal(5, sum)
	int_list_free(a)


int_list* make_list(int n):
	int_list* a = int_list_new()
	for int i in range(n): int_list_push(a, i + 1)
	return a


void test_iterable_from_call_expression():
	int sum = 0
	for int x in make_list(4): sum = sum + x
	assert_equal(10, sum) /* 1 + 2 + 3 + 4 */


# A user-defined container proves the protocol needs no compiler support:
# any struct type with the four _iter_ functions is iterable.
struct countdown:
	int start

countdown* countdown_new(int start):
	countdown* c = malloc(4)
	c.start = start
	return c

int countdown_iter_begin(countdown* c):
	return c.start

int countdown_iter_done(countdown* c, int cursor):
	return cursor <= 0

int countdown_iter_next(countdown* c, int cursor):
	return cursor - 1

int countdown_iter_value(countdown* c, int cursor):
	return cursor


void test_user_defined_container():
	countdown* c = countdown_new(4)
	int digits = 0
	for int x in c: digits = digits * 10 + x
	assert_equal(4321, digits)
	free(c)
