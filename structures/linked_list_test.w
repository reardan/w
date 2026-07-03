import lib.testing
import structures.linked_list


void test_push_get():
	linked_list* list = linked_list_new()
	linked_list_push(list, 10)
	linked_list_push(list, 20)
	linked_list_push(list, 30)
	assert_equal(3, list.length)
	assert_equal(10, linked_list_get(list, 0))
	assert_equal(20, linked_list_get(list, 1))
	assert_equal(30, linked_list_get(list, 2))
	linked_list_free(list)


void test_pop():
	linked_list* list = linked_list_new()
	linked_list_push(list, 1)
	linked_list_push(list, 2)
	assert_equal(2, linked_list_pop(list))
	assert_equal(1, linked_list_pop(list))
	assert_equal(0, list.length)
	linked_list_free(list)


void test_push_after_pop():
	linked_list* list = linked_list_new()
	linked_list_push(list, 1)
	linked_list_pop(list)
	linked_list_push(list, 5)
	assert_equal(1, list.length)
	assert_equal(5, linked_list_get(list, 0))
	linked_list_free(list)


void test_many_elements():
	linked_list* list = linked_list_new()
	int i = 0
	while (i < 100):
		linked_list_push(list, i)
		i = i + 1
	assert_equal(100, list.length)
	assert_equal(0, linked_list_get(list, 0))
	assert_equal(99, linked_list_get(list, 99))
	linked_list_free(list)


void test_iter_empty():
	linked_list* list = linked_list_new()
	int cursor = linked_list_iter_begin(list)
	assert_equal(1, linked_list_iter_done(list, cursor))
	linked_list_free(list)


void test_iter_values_in_order():
	linked_list* list = linked_list_new()
	linked_list_push(list, 7)
	linked_list_push(list, 8)
	linked_list_push(list, 9)

	int cursor = linked_list_iter_begin(list)
	assert_equal(0, linked_list_iter_done(list, cursor))
	assert_equal(7, linked_list_iter_value(list, cursor))
	cursor = linked_list_iter_next(list, cursor)
	assert_equal(8, linked_list_iter_value(list, cursor))
	cursor = linked_list_iter_next(list, cursor)
	assert_equal(9, linked_list_iter_value(list, cursor))
	cursor = linked_list_iter_next(list, cursor)
	assert_equal(1, linked_list_iter_done(list, cursor))
	linked_list_free(list)
