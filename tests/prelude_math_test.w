# wbuild: x64
# Prelude math (issue #360): max/min/abs/len reachable without an
# import when no user symbol shadows the name
# (grammar/print_builtin.w, structures/prelude.w). lib.testing pulls
# in lib.lib but not lib.math, so these call sites exercise the
# prelude helpers.
import lib.testing


void test_prelude_max_min_abs():
	assert_equal(9, max(3, 9))
	assert_equal(-3, max(-3, -9))
	assert_equal(-9, min(3, -9))
	assert_equal(3, min(3, 9))
	assert_equal(7, abs(-7))
	assert_equal(7, abs(7))
	assert_equal(0, abs(0))


void test_prelude_math_expressions_and_nesting():
	int a = 4
	assert_equal(8, max(a * 2, a + 1))
	assert_equal(6, max(abs(-4), min(9, 6)))
	assert_equal(1, min(abs(-1), abs(2)))


void test_prelude_math_char_args():
	assert_equal('b', max('a', 'b'))
	assert_equal('a', min('a', 'b'))


# Single-pass shadowing: a call site before the user definition binds
# the prelude helper, one after it binds the user function -- the same
# rule input()/read_all()/ints() follow (golf_ergonomics.md).
void test_prelude_min_before_user_definition():
	assert_equal(2, min(2, 5))


int min(int a, int b):
	return 1000


void test_user_min_shadows_prelude():
	assert_equal(1000, min(2, 5))


void test_len_list_map_set():
	l := list[int]{1, 2, 3}
	assert_equal(3, len(l))
	l.push(4)
	assert_equal(4, len(l))
	m := map[int, int]{1: 10, 2: 20}
	assert_equal(2, len(m))
	s := set[int]{5, 6, 7}
	assert_equal(3, len(s))


void test_len_cstr_and_string():
	assert_equal(5, len(c"hello"))
	assert_equal(0, len(c""))
	t := s"héllo"
	# string length is the byte count, matching '.length'
	assert_equal(6, len(t))


void test_len_array_and_slice():
	int[3] a
	a[0] = 1
	a[1] = 2
	a[2] = 3
	assert_equal(3, len(a))
	int[] tail = a[1:3]
	assert_equal(2, len(tail))


void test_len_in_expressions():
	l := list[int]{1, 2}
	assert_equal(7, len(l) + len(c"hello"))
	assert_equal(5, max(len(l), len(c"hello")))
