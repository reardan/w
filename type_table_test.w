import testing
import type_table


void test_type_size():
	assert_equal(816, type_size())


# same as list.test_push_pop()
void test_list_functions():
	create()
	int want = 1234
	push(want)
	assert_equal(want, pop())
	assert_equal(length, 0)


void push_advanced_types():
	# these pointer types are deprecated, use * instead
	type_push("void*")
	type_push("char**")
	type_push("int(int,int)")


void test_type_push():
	push_basic_types()


void test_type_lookup():
	push_basic_types()
	assert_equal(0, type_lookup("void"))
	assert_equal(1, type_lookup("int"))
	assert_equal(2, type_lookup("char"))


void test_extra_types():
	push_basic_types()
	push_advanced_types()
	assert_equal(length - 1, type_lookup("int(int,int)"))


void test_add_get_print_2_fields():
	push_basic_types()
	int type_index = type_push("point")
	char* field = "x"
	int int_type = type_lookup("int")
	print_int("type_index: ", type_index)
	type_add_arg(type_index, field, int_type)

	int arg_index = type_get_arg(type_index, field)
	assert_equal(0, arg_index)

	char* field2 = "y"
	type_add_arg(type_index, field2, int_type)

	type_print(type_index)

	int arg_index2 = type_get_arg(type_index, field2)
	assert_equal(1, arg_index2)


void test_add_get_50_fields():
	push_basic_types()
	int type_index = type_push("massive_struct")
	char* field = "field\x00\x00\x00\x00\x00\x00\x00\x00"
	int i = 0
	int count = 50
	while (i < count):
		strcpy(field + 5, itoa(i))
		int int_type = type_lookup("int")
		type_add_arg(type_index, strclone(field), int_type)
		i = i + 1

	int t = get(type_index)
	assert_equal(count, load_int(t + 4))


void test_type_push_size():
	push_basic_types()


# simulating:
#
# struct mixed:
#	int32 a   # [0] offset
#	int16 b   # [4]
#	int32 c   # [6]
# type_get_field_offset("c") == 6
void test_type_get_field_offset():
	push_basic_types()
	int type_index = type_push("mixed")
	int int_type = type_lookup("int")
	int int16_type = type_push_size("int16", 2)
	type_add_arg(type_index, "a", int_type)
	type_get_field_offset(type_index, "a")
	type_add_arg(type_index, "b", int16_type)
	type_add_arg(type_index, "c", int_type)
	type_print(type_index)
	assert_equal(0, type_get_field_offset(type_index, "a"))
	assert_equal(4, type_get_field_offset(type_index, "b"))
	assert_equal(6, type_get_field_offset(type_index, "c"))


void test_type_with_fields_total_size():
	push_basic_types()
	int type_index = type_push_size("mixed", 0)
	int int_type = type_lookup("int")
	int int16_type = type_push_size("int16", 2)
	type_add_arg(type_index, "a", int16_type)
	type_add_arg(type_index, "b", int_type)
	type_add_arg(type_index, "c", int16_type)
	type_add_arg(type_index, "d", int_type)
	assert_equal(12, type_get_size(type_index))



# Test pointer level
void test_pointer_level():
	push_basic_types()
	int first_pointer = type_lookup_pointer("int", 1)
	assert1(first_pointer > 0)
	assert_equal(first_pointer+1, type_lookup_pointer("int", 2))
	assert_equal(first_pointer+2, type_lookup_pointer("char", 1))
	assert_equal(first_pointer+3, type_lookup_pointer("char", 2))

