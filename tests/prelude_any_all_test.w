# Prelude any(l)/all(l) (issue #360): truthiness scans over a list[T]
# of int-like elements, reachable without an import. any([]) is false
# and all([]) is true (the Python contract). Like the other prelude
# names the binding is single-pass: a call site textually before a
# same-file user definition binds the prelude, later sites bind the
# user function.
# wbuild: x64
import lib.assert


# Parsed before the user 'all' below exists, so these bind the prelude
int prelude_all_checks():
	list[int] empty = new list[int]
	assert_equal(1, all(empty))
	ones := list[int]{1, 2, 3}
	assert_equal(1, all(ones))
	with_zero := list[int]{1, 0, 3}
	assert_equal(0, all(with_zero))
	flags := list[bool]{true, false}
	assert_equal(0, all(flags))
	true_flags := list[bool]{true, true}
	assert_equal(1, all(true_flags))
	return 1


# A user function named 'all' shadows the prelude helper at every call
# site after this definition
int all(int x):
	return x + 40


int main():
	list[int] empty = new list[int]
	assert_equal(0, any(empty))
	assert_equal(1, prelude_all_checks())

	zeros := list[int]{0, 0, 0}
	assert_equal(0, any(zeros))

	mixed := list[int]{0, 2, 0}
	assert_equal(1, any(mixed))

	# Negative values are truthy
	negative := list[int]{-1}
	assert_equal(1, any(negative))

	# any/all results are plain ints, usable directly as conditions
	hits := 0
	if any(mixed):
		hits = hits + 1
	assert_equal(1, hits)

	# Sub-word elements: chars and bools load at their own width
	chars := list[char]{0, 'a'}
	assert_equal(1, any(chars))
	char_zeros := list[char]{0, 0}
	assert_equal(0, any(char_zeros))

	flags := list[bool]{true, false}
	assert_equal(1, any(flags))

	# The user 'all' wins from here on
	assert_equal(42, all(2))

	println(c"prelude_any_all_test passed")
	return 0
