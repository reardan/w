# wbuild: x64
import lib.testing
import lib.utf8


struct array_holder:
	int[3] values
	int marker


int[3] global_values
array_holder global_holder


void test_global_array_index_length_and_slice():
	assert_equal(3, global_values.length)
	assert_equal(0, global_values[0])
	global_values[0] = 12
	global_values[1] = 30
	global_values[2] = global_values[0] + global_values[1]
	assert_equal(42, global_values[2])
	int[] view = global_values
	assert_equal(3, view.length)
	view[1] = 99
	assert_equal(99, global_values[1])


void test_global_struct_array_field():
	assert_equal(3, global_holder.values.length)
	assert_equal(0, global_holder.values[0])
	global_holder.values[0] = 6
	global_holder.values[1] = 7
	global_holder.values[2] = global_holder.values[0] * global_holder.values[1]
	assert_equal(42, global_holder.values[2])
	int[] view = global_holder.values
	assert_equal(3, view.length)
	view[2] = 84
	assert_equal(84, global_holder.values[2])


void test_local_struct_array_field():
	array_holder h
	assert_equal(3, h.values.length)
	assert_equal(0, h.values[0])
	h.values[0] = 10
	h.values[1] = 20
	h.marker = 5
	assert_equal(30, h.values[0] + h.values[1])
	assert_equal(5, h.marker)


void test_heap_struct_array_field():
	array_holder* h = new array_holder
	assert_equal(3, h.values.length)
	assert_equal(0, h.values[0])
	h.values[0] = 14
	h.values[1] = 3
	assert_equal(42, h.values[0] * h.values[1])


array_holder make_array_holder():
	array_holder h
	h.values[0] = 4
	h.values[1] = 5
	h.values[2] = 6
	h.marker = 70
	return h


void take_array_holder(array_holder h):
	assert_equal(3, h.values.length)
	assert_equal(5, h.values[1])
	h.values[1] = 55
	assert_equal(55, h.values[1])


void test_struct_array_copy_argument_and_return():
	array_holder a = make_array_holder()
	assert_equal(3, a.values.length)
	assert_equal(4, a.values[0])
	assert_equal(70, a.marker)
	array_holder b = a
	assert1(a.values.data != b.values.data)
	b.values[0] = 40
	assert_equal(4, a.values[0])
	assert_equal(40, b.values[0])
	take_array_holder(a)
	assert_equal(5, a.values[1])


void test_stack_array_index_and_length():
	int[4] values
	assert_equal(4, values.length)
	values[0] = 11
	values[1] = 22
	values[2] = values[0] + values[1]
	assert_equal(33, values[2])


void test_stack_array_decays_to_slice():
	int[3] values
	values[0] = 4
	values[1] = 5
	values[2] = 6
	int[] view = values
	assert_equal(3, view.length)
	view[1] = 50
	assert_equal(50, values[1])


void test_subslice_aliases_source():
	int[5] values
	values[0] = 1
	values[1] = 2
	values[2] = 3
	values[3] = 4
	values[4] = 5
	int[] mid = values[1:4]
	assert_equal(3, mid.length)
	assert_equal(2, mid[0])
	mid[1] = 30
	assert_equal(30, values[2])


void test_omitted_slice_bounds():
	int[4] values
	values[0] = 10
	values[1] = 20
	values[2] = 30
	values[3] = 40
	int[] prefix = values[:2]
	assert_equal(2, prefix.length)
	assert_equal(20, prefix[1])
	int[] suffix = values[2:]
	assert_equal(2, suffix.length)
	assert_equal(30, suffix[0])
	int[] all = values[:]
	assert_equal(4, all.length)
	assert_equal(40, all[3])


void test_heap_array():
	int[] values = new int[3]
	assert_equal(3, values.length)
	assert_equal(0, values[0])
	assert_equal(0, values[1])
	assert_equal(0, values[2])
	values[0] = 7
	values[1] = 8
	values[2] = values[0] + values[1]
	assert_equal(15, values[2])


void test_utf8_string_literal():
	string s = s"hi \u00e9"
	assert_equal(5, s.length)
	assert1(utf8_validate(s))
	assert_equal(4, utf8_codepoint_count(s))
	assert_equal('h', s[0])
	assert_equal(0, strcmp(cstr(s), c"hi \xc3\xa9"))

