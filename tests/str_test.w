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


void test_char_class_predicates():
	assert_equal(1, isdigit('0'))
	assert_equal(1, isdigit('9'))
	assert_equal(0, isdigit('a'))
	assert_equal(1, isupper('A'))
	assert_equal(0, isupper('a'))
	assert_equal(1, islower('z'))
	assert_equal(0, islower('Z'))
	assert_equal(1, isalpha('w'))
	assert_equal(1, isalpha('W'))
	assert_equal(0, isalpha('7'))
	assert_equal(0, isalpha('_'))
	assert_equal(1, isalnum('w'))
	assert_equal(1, isalnum('7'))
	assert_equal(0, isalnum(' '))
	assert_equal(1, isspace(' '))
	assert_equal(1, isspace(9))
	assert_equal(1, isspace(10))
	assert_equal(1, isspace(13))
	assert_equal(0, isspace('x'))
	assert_equal(0, isspace(0))


void test_char_class_scans_a_string():
	char* s = c"ab3 Z\x09"
	int digits = 0
	int letters = 0
	int spaces = 0
	int i = 0
	while (s[i] != 0):
		digits = digits + isdigit(s[i])
		letters = letters + isalpha(s[i])
		spaces = spaces + isspace(s[i])
		i = i + 1
	assert_equal(1, digits)
	assert_equal(3, letters)
	assert_equal(2, spaces)


void test_char_class_non_ascii_bytes():
	# UTF-8 continuation/lead bytes are never ASCII classes
	char* s = c"caf\xc3\xa9"
	assert_equal(0, isalpha(s[3]))
	assert_equal(0, isalnum(s[4]))
	assert_equal(0, isspace(s[3]))
	assert_equal(s[3], tolower(s[3]))
	assert_equal(s[4], toupper(s[4]))


void test_case_mapping():
	assert_equal('a', tolower('A'))
	assert_equal('z', tolower('Z'))
	assert_equal('a', tolower('a'))
	assert_equal('7', tolower('7'))
	assert_equal('A', toupper('a'))
	assert_equal('Z', toupper('z'))
	assert_equal('Z', toupper('Z'))
	assert_equal(' ', toupper(' '))
