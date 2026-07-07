import lib.testing


struct lm_point:
	int x
	int y


int lm_desc(int a, int b):
	return b - a


int lm_double(int x):
	return x * 2


int lm_is_odd(int x):
	return x % 2


int lm_add(int a, int b):
	return a + b


int lm_by_y(lm_point* a, lm_point* b):
	return a.y - b.y


int lm_len_cstr(char* s):
	return strlen(s)


type lm_binop = fn(int, int) -> int


void lm_assert_ints(list[int] got, int a, int b, int c, int d):
	assert_equal(4, got.length)
	assert_equal(a, got[0])
	assert_equal(b, got[1])
	assert_equal(c, got[2])
	assert_equal(d, got[3])


void test_list_sort_ints():
	list[int] l = list[int]{3, 1, 4, 1}
	l.sort()
	lm_assert_ints(l, 1, 1, 3, 4)


void test_list_sort_negative_and_sorted_input():
	list[int] l = list[int]{-5, 10, -20, 0}
	l.sort()
	lm_assert_ints(l, -20, -5, 0, 10)
	l.sort()
	lm_assert_ints(l, -20, -5, 0, 10)


void test_list_sort_cstr_contents():
	list[char*] words = list[char*]{c"pear", c"apple", c"fig"}
	words.sort()
	assert_strings_equal(c"apple", words[0])
	assert_strings_equal(c"fig", words[1])
	assert_strings_equal(c"pear", words[2])


void test_list_sort_by_comparator():
	list[int] l = list[int]{3, 1, 4, 1}
	l.sort_by(lm_desc)
	lm_assert_ints(l, 4, 3, 1, 1)


void test_list_sort_by_fn_pointer():
	lm_binop* comparator = lm_desc
	list[int] l = list[int]{2, 9, 5, 7}
	l.sort_by(comparator)
	lm_assert_ints(l, 9, 7, 5, 2)


void test_list_sort_by_struct_elements():
	list[lm_point] points = new list[lm_point]
	lm_point p
	p.x = 1
	p.y = 30
	points.push(p)
	p.x = 2
	p.y = 10
	points.push(p)
	p.x = 3
	p.y = 20
	points.push(p)
	points.sort_by(lm_by_y)
	assert_equal(2, points[0].x)
	assert_equal(3, points[1].x)
	assert_equal(1, points[2].x)


void test_list_map():
	list[int] l = list[int]{1, 2, 3, 4}
	list[int] doubled = l.map(lm_double)
	lm_assert_ints(doubled, 2, 4, 6, 8)
	# The source list is untouched
	lm_assert_ints(l, 1, 2, 3, 4)


void test_list_map_changes_element_type():
	list[char*] words = list[char*]{c"a", c"bb", c"ccc"}
	list[int] lengths = words.map(lm_len_cstr)
	assert_equal(3, lengths.length)
	assert_equal(1, lengths[0])
	assert_equal(2, lengths[1])
	assert_equal(3, lengths[2])


void test_list_filter():
	list[int] l = list[int]{1, 2, 3, 4, 5}
	list[int] odd = l.filter(lm_is_odd)
	assert_equal(3, odd.length)
	assert_equal(1, odd[0])
	assert_equal(3, odd[1])
	assert_equal(5, odd[2])
	assert_equal(5, l.length)


void test_list_reduce():
	list[int] l = list[int]{1, 2, 3, 4}
	assert_equal(110, l.reduce(lm_add, 100))
	list[int] empty = new list[int]
	assert_equal(7, empty.reduce(lm_add, 7))


void test_list_sum_min_max():
	list[int] l = list[int]{4, -2, 9, 1}
	assert_equal(12, l.sum())
	assert_equal(-2, l.min())
	assert_equal(9, l.max())
	list[int] empty = new list[int]
	assert_equal(0, empty.sum())


void test_list_reverse():
	list[int] l = list[int]{1, 2, 3, 4}
	l.reverse()
	lm_assert_ints(l, 4, 3, 2, 1)
	list[int] odd_length = list[int]{1, 2, 3}
	odd_length.reverse()
	assert_equal(3, odd_length[0])
	assert_equal(2, odd_length[1])
	assert_equal(1, odd_length[2])


void test_list_reverse_struct_elements():
	list[lm_point] points = new list[lm_point]
	lm_point p
	p.x = 1
	p.y = 11
	points.push(p)
	p.x = 2
	p.y = 22
	points.push(p)
	points.reverse()
	assert_equal(2, points[0].x)
	assert_equal(22, points[0].y)
	assert_equal(1, points[1].x)


void test_list_count_and_index():
	list[int] l = list[int]{5, 3, 5, 5, 1}
	assert_equal(3, l.count(5))
	assert_equal(0, l.count(42))
	assert_equal(1, l.index(3))
	assert_equal(0, l.index(5))
	assert_equal(-1, l.index(42))


void test_list_count_index_cstr_contents():
	list[char*] words = list[char*]{c"aa", c"bb", c"aa"}
	assert_equal(2, words.count(c"aa"))
	assert_equal(1, words.index(c"bb"))
	assert_equal(-1, words.index(c"zz"))


void test_list_methods_chain():
	list[int] l = list[int]{5, 1, 4, 2, 3}
	assert_equal(18, l.filter(lm_is_odd).map(lm_double).sum())
	# sum of squares of even numbers, reduce-style
	assert_equal(6, l.filter(lm_is_odd).reduce(lm_add, -3))


void test_list_methods_char_elements():
	list[char] letters = list[char]{'c', 'a', 'b'}
	letters.sort()
	assert_equal('a', letters[0])
	assert_equal('b', letters[1])
	assert_equal('c', letters[2])
	assert_equal('a', letters.min())
	assert_equal('c', letters.max())
