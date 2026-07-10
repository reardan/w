# wbuild: x64
import lib.testing
import structures.array_list


void test_push_get():
	array_list* a = array_list_new()
	array_list_push(a, 10)
	array_list_push(a, 20)
	array_list_push(a, 30)
	assert_equal(3, a.length)
	assert_equal(10, array_list_get(a, 0))
	assert_equal(20, array_list_get(a, 1))
	assert_equal(30, array_list_get(a, 2))
	array_list_free(a)


void test_pop():
	array_list* a = array_list_new()
	array_list_push(a, 1)
	array_list_push(a, 2)
	assert_equal(2, array_list_pop(a))
	assert_equal(1, array_list_pop(a))
	assert_equal(0, a.length)
	array_list_free(a)


void test_set():
	array_list* a = array_list_new()
	array_list_push(a, 1)
	array_list_set(a, 0, 99)
	assert_equal(99, array_list_get(a, 0))
	array_list_free(a)


void test_insert():
	array_list* a = array_list_new()
	array_list_push(a, 1)
	array_list_push(a, 3)
	array_list_insert(a, 1, 2)
	assert_equal(3, a.length)
	assert_equal(1, array_list_get(a, 0))
	assert_equal(2, array_list_get(a, 1))
	assert_equal(3, array_list_get(a, 2))
	array_list_free(a)


void test_growth():
	array_list* a = array_list_new()
	int i = 0
	while (i < 1000):
		array_list_push(a, i * 2)
		i = i + 1
	assert_equal(1000, a.length)
	assert_equal(0, array_list_get(a, 0))
	assert_equal(998, array_list_get(a, 499))
	assert_equal(1998, array_list_get(a, 999))
	array_list_free(a)


void test_iter_empty():
	array_list* a = array_list_new()
	int cursor = array_list_iter_begin(a)
	assert_equal(1, array_list_iter_done(a, cursor))
	array_list_free(a)


void test_iter_values_in_order():
	array_list* a = array_list_new()
	array_list_push(a, 4)
	array_list_push(a, 5)
	array_list_push(a, 6)

	int cursor = array_list_iter_begin(a)
	assert_equal(0, array_list_iter_done(a, cursor))
	assert_equal(4, array_list_iter_value(a, cursor))
	cursor = array_list_iter_next(a, cursor)
	assert_equal(5, array_list_iter_value(a, cursor))
	cursor = array_list_iter_next(a, cursor)
	assert_equal(6, array_list_iter_value(a, cursor))
	cursor = array_list_iter_next(a, cursor)
	assert_equal(1, array_list_iter_done(a, cursor))
	array_list_free(a)
