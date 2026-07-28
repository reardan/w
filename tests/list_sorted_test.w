# l.sorted() / l.sorted_by(f) (issue #360): non-mutating counterparts
# of sort/sort_by returning a NEW list, with the same element and
# comparator rules (int-like as signed words, char* by contents,
# aggregate elements pass addresses to the comparator).
# wbuild: x64
import lib.testing


struct ls_point:
	int x
	int y


int ls_desc(int a, int b):
	return b - a


int ls_by_y(ls_point* a, ls_point* b):
	return a.y - b.y


type ls_binop = fn(int, int) -> int


void test_sorted_ints_and_source_untouched():
	list[int] l = list[int]{3, 1, 4, 1}
	list[int] s = l.sorted()
	assert_equal(4, s.length)
	assert_equal(1, s[0])
	assert_equal(1, s[1])
	assert_equal(3, s[2])
	assert_equal(4, s[3])
	# The source list keeps its order
	assert_equal(3, l[0])
	assert_equal(1, l[1])
	assert_equal(4, l[2])
	assert_equal(1, l[3])


void test_sorted_negative_and_empty():
	list[int] l = list[int]{-5, 10, -20, 0}
	list[int] s = l.sorted()
	assert_equal(-20, s[0])
	assert_equal(-5, s[1])
	assert_equal(0, s[2])
	assert_equal(10, s[3])
	list[int] empty = new list[int]
	assert_equal(0, empty.sorted().length)


void test_sorted_cstr_contents():
	list[char*] words = list[char*]{c"pear", c"apple", c"fig"}
	list[char*] s = words.sorted()
	assert_strings_equal(c"apple", s[0])
	assert_strings_equal(c"fig", s[1])
	assert_strings_equal(c"pear", s[2])
	assert_strings_equal(c"pear", words[0])


void test_sorted_char_elements():
	list[char] letters = list[char]{'c', 'a', 'b'}
	list[char] s = letters.sorted()
	assert_equal('a', s[0])
	assert_equal('b', s[1])
	assert_equal('c', s[2])
	assert_equal('c', letters[0])


void test_sorted_by_comparator():
	list[int] l = list[int]{3, 1, 4, 1}
	list[int] s = l.sorted_by(ls_desc)
	assert_equal(4, s[0])
	assert_equal(3, s[1])
	assert_equal(1, s[2])
	assert_equal(1, s[3])
	assert_equal(3, l[0])


void test_sorted_by_fn_pointer():
	ls_binop* comparator = ls_desc
	list[int] l = list[int]{2, 9, 5, 7}
	list[int] s = l.sorted_by(comparator)
	assert_equal(9, s[0])
	assert_equal(2, s[3])


void test_sorted_by_struct_elements():
	list[ls_point] points = new list[ls_point]
	ls_point p
	p.x = 1
	p.y = 30
	points.push(p)
	p.x = 2
	p.y = 10
	points.push(p)
	p.x = 3
	p.y = 20
	points.push(p)
	list[ls_point] s = points.sorted_by(ls_by_y)
	assert_equal(2, s[0].x)
	assert_equal(3, s[1].x)
	assert_equal(1, s[2].x)
	# The source keeps its order
	assert_equal(1, points[0].x)


void test_sorted_chains():
	list[int] l = list[int]{5, 1, 4}
	# The result is an ordinary list: methods chain off it
	assert_equal(1, l.sorted()[0])
	assert_equal(2, l.sorted().index(5))
	assert_equal(10, l.sorted().sum())
