import lib.testing
import lib.utf8


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

