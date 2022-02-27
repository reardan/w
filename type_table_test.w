import testing
import type_table


void test_type_size():
	assert_equal(32, type_size())


# same as list.test_push_pop()
void test_list_functions():
	create()
	int want = 1234
	push(want)
	assert_equal(want, pop())
	assert_equal(length, 0)


void push_advanced_types():
	type_push("void*")
	type_push("char**")
	type_push("int(int,int)")


void test_type_push():
	push_basic_types()
	assert_equal(3, length)


void test_type_lookup():
	push_basic_types()
	assert_equal(0, type_lookup("void"))
	assert_equal(1, type_lookup("int"))
	assert_equal(2, type_lookup("char"))


void test_extra_types():
	push_basic_types()
	push_advanced_types()
	assert_equal(6, length)
	assert_equal(5, type_lookup("int(int,int)"))
