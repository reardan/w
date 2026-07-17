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


void test_cast_int_decay():
	# cast(int, arr) decays to the data pointer, agreeing with
	# cast(char*, arr) and arr.data (#229); the descriptor's own address
	# is no longer reachable through cast()
	char[8] buf
	buf[0] = 'x'
	assert_equal(cast(int, buf.data), cast(int, buf))
	assert_equal(cast(int, cast(char*, buf)), cast(int, buf))
	int[4] words
	words[0] = 1
	int[] view = words
	assert_equal(cast(int, words.data), cast(int, words))
	assert_equal(cast(int, view.data), cast(int, view))


# The conditional-arm helpers take the selector as a parameter so both
# paths of each ternary really execute (#229: the then arm decays
# through a stub after the else arm; the else arm decays via coerce).
# The array lives at module scope so returning the chosen pointer is
# sound on either path.
char[8] cond_cells


char* pick_then_array(int flag, char* p):
	return flag ? cond_cells : p


char* pick_else_array(int flag, char* p):
	return flag ? p : cond_cells


char* pick_array_or_null(int flag):
	# A bare constant arm joins at the element pointer: the array arm
	# decays, the constant passes through (this used to leave a
	# slice-value result whose outer decay load dereferenced the 0)
	return flag ? cond_cells : 0


char* pick_null_or_array(int flag):
	return flag ? 0 : cond_cells


void test_conditional_then_arm_decay():
	cond_cells[0] = 'a'
	char[4] other
	other[0] = 'o'
	char* p = other
	char* r = pick_then_array(1, p)
	assert_equal(cast(int, cond_cells.data), cast(int, r))
	assert_equal('a', r[0])
	r = pick_then_array(0, p)
	assert_equal(cast(int, p), cast(int, r))
	assert_equal('o', r[0])


void test_conditional_else_arm_decay():
	cond_cells[0] = 'b'
	char[4] other
	other[0] = 'o'
	char* p = other
	char* r = pick_else_array(0, p)
	assert_equal(cast(int, cond_cells.data), cast(int, r))
	assert_equal('b', r[0])
	r = pick_else_array(1, p)
	assert_equal(cast(int, p), cast(int, r))
	assert_equal('o', r[0])


void test_conditional_constant_arm_decay():
	cond_cells[0] = 'n'
	char* r = pick_array_or_null(1)
	assert_equal(cast(int, cond_cells.data), cast(int, r))
	assert_equal('n', r[0])
	assert_equal(0, cast(int, pick_array_or_null(0)))
	r = pick_null_or_array(0)
	assert_equal(cast(int, cond_cells.data), cast(int, r))
	assert_equal('n', r[0])
	assert_equal(0, cast(int, pick_null_or_array(1)))


void test_conditional_slice_arms_keep_descriptor():
	# Two array/slice arms still join as a slice value with a live
	# length, on both paths
	char[8] a
	a[0] = 'x'
	char[4] b
	b[0] = 'y'
	int flag = 1
	char[] chosen = flag ? a : b
	assert_equal(8, chosen.length)
	assert_equal('x', chosen[0])
	flag = 0
	char[] other = flag ? a : b
	assert_equal(4, other.length)
	assert_equal('y', other[0])
