# wbuild: x64
import lib.testing

/*
Array-to-pointer decay: passing a fixed array (or slice) where a T*
is expected passes the descriptor's DATA POINTER, exactly like C decay.
Before this landed the compiler warned and passed the descriptor's own
address, so the callee overwrote the {data, length} header and the next
index through the array jumped to a garbage address (the #113 corruption).
*/


struct cell_holder:
	int[3] cells
	int marker


int[4] global_cells


void fill_bytes(char* dst, int n):
	int i = 0
	while (i < n):
		dst[i] = 'a' + i
		i = i + 1


int sum_words(int* values, int n):
	int total = 0
	int i = 0
	while (i < n):
		total = total + values[i]
		i = i + 1
	return total


void stamp_first_byte(void* target):
	char* bytes = cast(char*, target)
	bytes[0] = 'Z'


int* global_cells_pointer():
	# Return-value decay: int[4] -> int*
	return global_cells


void test_char_array_argument_decay():
	char[8] buf
	buf[0] = 0
	fill_bytes(buf, 7)
	# The descriptor must survive the callee's writes
	assert_equal(8, buf.length)
	assert_equal('a', buf[0])
	assert_equal('g', buf[6])


void test_int_array_argument_decay():
	int[4] values
	values[0] = 10
	values[1] = 20
	values[2] = 12
	values[3] = 0
	assert_equal(42, sum_words(values, 4))
	assert_equal(4, values.length)


void test_void_pointer_argument_decay():
	char[4] buf
	buf[0] = 'x'
	stamp_first_byte(buf)
	assert_equal('Z', buf[0])
	assert_equal(4, buf.length)


void test_slice_argument_decay():
	int[4] values
	values[0] = 40
	values[1] = 2
	values[2] = 0
	values[3] = 0
	int[] view = values
	assert_equal(42, sum_words(view, 2))


void test_initialization_decay():
	char[8] buf
	buf[0] = 'x'
	char* p = buf
	p[0] = 'y'
	assert_equal('y', buf[0])


void test_assignment_decay():
	char[8] buf
	buf[0] = 'x'
	char* p = 0
	p = buf
	p[0] = 'q'
	assert_equal('q', buf[0])


void test_return_decay():
	global_cells[2] = 0
	int* cells = global_cells_pointer()
	cells[2] = 42
	assert_equal(42, global_cells[2])


void test_struct_field_array_decay():
	cell_holder h
	h.cells[0] = 41
	h.marker = 7
	int* q = h.cells
	q[0] = q[0] + 1
	assert_equal(42, h.cells[0])
	assert_equal(7, h.marker)


void test_decay_matches_data_accessor():
	char[8] buf
	char* p = buf
	assert_equal(cast(int, buf.data), cast(int, p))


void test_map_key_decay():
	char[4] key
	key[0] = 'h'
	key[1] = 'i'
	key[2] = 0
	map[char*, int] m = new map[char*, int]
	m[c"hi"] = 42
	# cstr keys compare by contents, so the decayed data pointer finds it
	assert_equal(42, m[key])


void test_membership_decay():
	char[4] key
	key[0] = 'h'
	key[1] = 'i'
	key[2] = 0
	set[char*] names = set[char*]{c"hi", c"bye"}
	assert1(key in names)
	list[char*] words = list[char*]{c"one", c"hi"}
	assert1(key in words)


void test_list_push_decay():
	char[8] buf
	buf[0] = 0
	list[char*] pointers = new list[char*]
	pointers.push(buf)
	assert_equal(cast(int, buf.data), cast(int, pointers[0]))


void test_switch_case_decay():
	char[4] buf
	buf[0] = 'x'
	char* p = buf
	int matched = 0
	switch (p):
		case buf:
			matched = 1
		default:
			matched = 2
	assert_equal(1, matched)
