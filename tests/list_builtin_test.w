import lib.testing


void test_list_new_push_index_and_length():
	list[int] l = new list[int]
	assert_equal(0, l.length)
	l.push(10)
	l.push(20)
	l.push(30)
	assert_equal(3, l.length)
	assert_equal(10, l[0])
	assert_equal(20, l[1])
	assert_equal(30, l[2])


void test_list_index_assignment():
	list[int] l = list[int]{1, 2, 3}
	l[1] = 99
	assert_equal(1, l[0])
	assert_equal(99, l[1])
	assert_equal(3, l[2])
	l[1] = l[1] + 1
	assert_equal(100, l[1])


void test_list_pop():
	list[int] l = list[int]{7, 8, 9}
	assert_equal(9, l.pop())
	assert_equal(8, l.pop())
	assert_equal(1, l.length)
	l.push(11)
	assert_equal(11, l[1])


void test_list_literal():
	list[int] l = list[int]{4, 5, 6}
	assert_equal(3, l.length)
	assert_equal(4, l[0])
	assert_equal(6, l[2])
	list[int] empty = list[int]{}
	assert_equal(0, empty.length)


void test_list_growth():
	list[int] l = new list[int]
	for int i in range(1000):
		l.push(i)
	assert_equal(1000, l.length)
	assert_equal(0, l[0])
	assert_equal(999, l[999])
	int sum = 0
	for int v in l:
		sum = sum + v
	assert_equal(499500, sum)


void test_list_iteration():
	list[int] l = list[int]{1, 2, 3, 4, 5}
	int sum = 0
	for int x in l:
		sum = sum + x
	assert_equal(15, sum)


void test_list_iteration_break_continue():
	int acc = 0
	for int v in list[int]{1, 2, 3, 4, 5}:
		if (v == 2):
			continue
		if (v == 5):
			break
		acc = acc + v
	assert_equal(8, acc)


void test_list_char_pointer_elements():
	list[char*] names = list[char*]{c"alpha", c"beta"}
	assert_equal(2, names.length)
	assert_strings_equal(c"alpha", names[0])
	assert_strings_equal(c"beta", names[1])
	names.push(c"gamma")
	assert_strings_equal(c"gamma", names[2])


void test_list_char_elements_are_byte_sized():
	list[char] chars = list[char]{'a', 'b', 'c'}
	assert_equal(3, chars.length)
	assert_equal('a', chars[0])
	assert_equal('c', chars[2])
	chars[1] = 'z'
	assert_equal('z', chars[1])
	assert_equal('c', chars.pop())


void test_list_int16_elements():
	list[int16] shorts = list[int16]{1000, 2000}
	assert_equal(2000, shorts[1])
	shorts[0] = 4000
	assert_equal(4000, shorts[0])
	assert_equal(2000, shorts.pop())


void test_list_bool_elements():
	list[bool] flags = list[bool]{true, false, true}
	int on = 0
	for bool b in flags:
		if (b):
			on = on + 1
	assert_equal(2, on)


void test_list_float32_elements():
	list[float32] floats = new list[float32]
	floats.push(1.5)
	floats.push(2.25)
	float32 f = floats[0] + floats[1]
	int quadrupled = f * 4.0
	assert_equal(15, quadrupled)


void test_nested_lists():
	list[list[int]] grid = new list[list[int]]
	grid.push(list[int]{1, 2})
	grid.push(list[int]{3, 4, 5})
	assert_equal(2, grid.length)
	assert_equal(5, grid[1][2])
	int total = 0
	for list[int] row in grid:
		for int x in row:
			total = total + x
	assert_equal(15, total)


list[int] list_test_make_evens(int n):
	list[int] result = new list[int]
	for int i in range(n):
		result.push(i * 2)
	return result


int list_test_sum(list[int] l):
	int total = 0
	for int x in l:
		total = total + x
	return total


void test_list_function_parameter_and_return():
	list[int] evens = list_test_make_evens(5)
	assert_equal(5, evens.length)
	assert_equal(20, list_test_sum(evens))


struct list_test_holder:
	list[int] items
	int tag


void test_list_struct_field():
	list_test_holder h
	h.items = list[int]{7, 8}
	h.tag = 42
	assert_equal(8, h.items[1])
	assert_equal(2, h.items.length)
	h.items.push(9)
	assert_equal(3, h.items.length)
	assert_equal(9, h.items[2])


void test_list_reference_semantics():
	list[int] a = list[int]{1, 2}
	list[int] b = a
	b.push(3)
	assert_equal(3, a.length)
	assert_equal(3, a[2])


void test_list_in_map_values():
	map[char*, list[int]] table = new map[char*, list[int]]
	table[c"low"] = list[int]{1, 2}
	table[c"high"] = list[int]{9}
	assert_equal(2, table[c"low"].length)
	assert_equal(9, table[c"high"][0])
