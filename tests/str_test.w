import lib.testing
import lib.str


void test_substring_basic():
	char* s = c"hello world"
	char* hello = substring(s, 0, 5)
	assert_strings_equal(c"hello", hello)
	char* world = substring(s, 6, 11)
	assert_strings_equal(c"world", world)
	free(hello)
	free(world)


void test_substring_clamps():
	char* s = c"abc"
	assert_strings_equal(c"abc", substring(s, 0, 99))
	assert_strings_equal(c"bc", substring(s, 1, 99))
	assert_strings_equal(c"", substring(s, 2, 1))
	assert_strings_equal(c"abc", substring(s, -4, 3))


void test_index_of():
	assert_equal(0, index_of(c"hello", c"he"))
	assert_equal(2, index_of(c"hello", c"llo"))
	assert_equal(-1, index_of(c"hello", c"world"))
	assert_equal(0, index_of(c"hello", c""))
	assert_equal(2, index_of(c"aaab", c"ab"))


void test_split_basic():
	list[char*] pieces = split(c"a,b,c", ',')
	assert_equal(3, pieces.length)
	assert_strings_equal(c"a", pieces[0])
	assert_strings_equal(c"b", pieces[1])
	assert_strings_equal(c"c", pieces[2])


void test_split_does_not_mutate():
	char* s = c"x y"
	list[char*] pieces = split(s, ' ')
	assert_equal(2, pieces.length)
	assert_strings_equal(c"x y", s)


void test_split_empty_pieces():
	list[char*] pieces = split(c",a,,b,", ',')
	assert_equal(5, pieces.length)
	assert_strings_equal(c"", pieces[0])
	assert_strings_equal(c"a", pieces[1])
	assert_strings_equal(c"", pieces[2])
	assert_strings_equal(c"b", pieces[3])
	assert_strings_equal(c"", pieces[4])


void test_replace_multi_char():
	assert_strings_equal(c"one-two-three", replace(c"one two three", c" ", c"-"))
	assert_strings_equal(c"aXXcaXXc", replace(c"abcabc", c"b", c"XX"))
	assert_strings_equal(c"ac ac", replace(c"abbc abbc", c"bb", c""))
	assert_strings_equal(c"same", replace(c"same", c"zz", c"yy"))
	assert_strings_equal(c"copy", replace(c"copy", c"", c"zz"))


void test_join():
	list[char*] pieces = list[char*]{c"a", c"b", c"c"}
	assert_strings_equal(c"a, b, c", join(pieces, c", "))
	assert_strings_equal(c"abc", join(pieces, c""))
	list[char*] one = list[char*]{c"solo"}
	assert_strings_equal(c"solo", join(one, c"-"))
	list[char*] none = new list[char*]
	assert_strings_equal(c"", join(none, c"-"))


void test_split_join_round_trip():
	char* original = c"2026-07-07"
	list[char*] pieces = split(original, '-')
	assert_equal(3, pieces.length)
	char* rebuilt = join(pieces, c"-")
	assert_strings_equal(original, rebuilt)
