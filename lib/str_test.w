# wbuild: x64
# wbuild: step="bin/str_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import lib.str


# Assert got equals want, then free got (every lib/str.w result is
# malloc'd and owned by the caller).
void str_test_expect(char* want, char* got):
	assert_strings_equal(want, got)
	free(got)


void str_test_free_all(list[char*] pieces):
	for piece in pieces:
		free(piece)
	pieces.free()


# Assert pieces holds exactly the three strings, then free it.
void str_test_expect3(char* a, char* b, char* c, list[char*] pieces):
	assert_equal(3, pieces.length)
	assert_strings_equal(a, pieces[0])
	assert_strings_equal(b, pieces[1])
	assert_strings_equal(c, pieces[2])
	str_test_free_all(pieces)


void test_substring_basic():
	char* s = c"hello world"
	str_test_expect(c"hello", substring(s, 0, 5))
	str_test_expect(c"world", substring(s, 6, 11))


void test_substring_clamps():
	char* s = c"abc"
	str_test_expect(c"abc", substring(s, 0, 99))
	str_test_expect(c"bc", substring(s, 1, 99))
	str_test_expect(c"", substring(s, 2, 1))
	str_test_expect(c"abc", substring(s, -4, 3))


void test_index_of():
	assert_equal(0, index_of(c"hello", c"he"))
	assert_equal(2, index_of(c"hello", c"llo"))
	assert_equal(-1, index_of(c"hello", c"world"))
	assert_equal(0, index_of(c"hello", c""))
	assert_equal(2, index_of(c"aaab", c"ab"))


void test_split_basic():
	list[char*] pieces = split(c"a,b,c", ',')
	str_test_expect3(c"a", c"b", c"c", pieces)


void test_split_does_not_mutate():
	char* s = c"x y"
	list[char*] pieces = split(s, ' ')
	assert_equal(2, pieces.length)
	assert_strings_equal(c"x y", s)
	str_test_free_all(pieces)


void test_split_empty_pieces():
	list[char*] pieces = split(c",a,,b,", ',')
	assert_equal(5, pieces.length)
	assert_strings_equal(c"", pieces[0])
	assert_strings_equal(c"a", pieces[1])
	assert_strings_equal(c"", pieces[2])
	assert_strings_equal(c"b", pieces[3])
	assert_strings_equal(c"", pieces[4])
	str_test_free_all(pieces)


void test_split_whitespace_default():
	# With the delimiter omitted, runs of whitespace separate the pieces
	# and empty pieces are dropped (Python's s.split())
	str_test_expect3(c"a", c"bb", c"c", split(c"  a\tbb \n c  "))
	list[char*] none = split(c" \t ")
	assert_equal(0, none.length)
	none.free()


void test_replace_multi_char():
	str_test_expect(c"one-two-three", replace(c"one two three", c" ", c"-"))
	str_test_expect(c"aXXcaXXc", replace(c"abcabc", c"b", c"XX"))
	str_test_expect(c"ac ac", replace(c"abbc abbc", c"bb", c""))
	str_test_expect(c"same", replace(c"same", c"zz", c"yy"))
	str_test_expect(c"copy", replace(c"copy", c"", c"zz"))


void test_join():
	list[char*] pieces = list[char*]{c"a", c"b", c"c"}
	str_test_expect(c"a, b, c", join(pieces, c", "))
	str_test_expect(c"abc", join(pieces, c""))
	pieces.free()
	list[char*] one = list[char*]{c"solo"}
	str_test_expect(c"solo", join(one, c"-"))
	one.free()
	list[char*] none = new list[char*]
	str_test_expect(c"", join(none, c"-"))
	none.free()


void test_split_join_round_trip():
	char* original = c"2026-07-07"
	list[char*] pieces = split(original, '-')
	assert_equal(3, pieces.length)
	str_test_expect(original, join(pieces, c"-"))
	str_test_free_all(pieces)


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


void test_strip_whitespace():
	str_test_expect(c"a b", strip(c" \t\na b \r\x0b\x0c"))
	str_test_expect(c"a b \n", lstrip(c"  a b \n"))
	str_test_expect(c"  a b", rstrip(c"  a b \n"))
	str_test_expect(c"x", strip(c"x"))
	# Empty and all-whitespace inputs give ""
	str_test_expect(c"", strip(c""))
	str_test_expect(c"", lstrip(c""))
	str_test_expect(c"", rstrip(c""))
	str_test_expect(c"", strip(c" \t\n "))
	str_test_expect(c"", lstrip(c" \t\n "))
	str_test_expect(c"", rstrip(c" \t\n "))


void test_strip_does_not_mutate():
	char* s = c"  keep  "
	str_test_expect(c"keep", strip(s))
	assert_strings_equal(c"  keep  ", s)


void test_strip_char_set():
	# chars is a set, not a prefix: any mix of its members is removed
	str_test_expect(c"example", strip(c"www.example.com", c"cmowz."))
	str_test_expect(c"example.com", lstrip(c"www.example.com", c"w."))
	str_test_expect(c"www.example", rstrip(c"www.example.com", c".moc"))
	str_test_expect(c"", strip(c"xyxy", c"yx"))
	str_test_expect(c" a ", strip(c"- a -", c"-"))
	# An empty set strips nothing
	str_test_expect(c" a ", strip(c" a ", c""))


void test_strip_utf8():
	# Multi-byte characters stay intact under the default whitespace set
	str_test_expect(c"\xc3\xa9t\xc3\xa9", strip(c"  \xc3\xa9t\xc3\xa9\t"))
	# A multi-byte character in chars strips only that whole character
	str_test_expect(c"t", strip(c"\xc3\xa9t\xc3\xa9", c"\xc3\xa9"))
	str_test_expect(c"t\xc3\xa9", lstrip(c"\xc3\xa9t\xc3\xa9", c"\xc3\xa9"))
	str_test_expect(c"\xc3\xa9t", rstrip(c"\xc3\xa9t\xc3\xa9", c"\xc3\xa9"))
	# ... and never a lone byte of a different character that shares it
	str_test_expect(c"\xc3\xa8x\xc3\xa8", strip(c"\xc3\xa8x\xc3\xa8", c"\xc3\xa9"))
	# Mixed ASCII and multi-byte set
	str_test_expect(c"mid", strip(c"\xe2\x80\x94 mid \xe2\x80\x94", c" \xe2\x80\x94"))


void test_rindex_of():
	assert_equal(4, rindex_of(c"abcabc", c"bc"))
	assert_equal(3, rindex_of(c"abcabc", c"a"))
	assert_equal(-1, rindex_of(c"abc", c"z"))
	assert_equal(-1, rindex_of(c"ab", c"abc"))
	assert_equal(3, rindex_of(c"abc", c""))
	assert_equal(0, rindex_of(c"", c""))
	assert_equal(-1, rindex_of(c"", c"a"))
	assert_equal(2, rindex_of(c"aaaa", c"aa"))


void test_starts_with_at():
	assert_equal(1, starts_with_at(c"hello", c"ll", 2))
	assert_equal(0, starts_with_at(c"hello", c"ll", 1))
	assert_equal(1, starts_with_at(c"hello", c"he", 0))
	assert_equal(1, starts_with_at(c"hello", c"", 5))
	assert_equal(0, starts_with_at(c"hello", c"", 6))
	assert_equal(0, starts_with_at(c"hello", c"lo!", 3))
	# Negative start counts from the end, clamped to 0
	assert_equal(1, starts_with_at(c"hello", c"lo", -2))
	assert_equal(1, starts_with_at(c"hello", c"he", -99))
	assert_equal(1, starts_with_at(c"", c"", 0))
	assert_equal(0, starts_with_at(c"", c"a", 0))


void test_count():
	assert_equal(2, count(c"abcabc", c"bc"))
	assert_equal(0, count(c"abc", c"z"))
	# Non-overlapping, left to right
	assert_equal(2, count(c"aaaa", c"aa"))
	assert_equal(1, count(c"aaa", c"aa"))
	assert_equal(0, count(c"", c"a"))
	# Empty needle: code points + 1
	assert_equal(4, count(c"abc", c""))
	assert_equal(1, count(c"", c""))
	assert_equal(3, count(c"\xc3\xa9\xc3\xa9", c""))
	assert_equal(2, count(c"\xc3\xa9x\xc3\xa9", c"\xc3\xa9"))


void test_partition():
	str_test_expect3(c"key", c"=", c"value=x", partition(c"key=value=x", c"="))
	str_test_expect3(c"a", c"::", c"b", partition(c"a::b", c"::"))
	str_test_expect3(c"none", c"", c"", partition(c"none", c"="))
	str_test_expect3(c"", c"", c"", partition(c"", c"="))
	str_test_expect3(c"", c"=", c"", partition(c"=", c"="))
	str_test_expect3(c"", c"", c"abc", partition(c"abc", c""))


void test_rpartition():
	str_test_expect3(c"key=value", c"=", c"x", rpartition(c"key=value=x", c"="))
	str_test_expect3(c"", c"", c"none", rpartition(c"none", c"="))
	str_test_expect3(c"", c"", c"", rpartition(c"", c"="))
	str_test_expect3(c"abc", c"", c"", rpartition(c"abc", c""))
	str_test_expect3(c"\xc3\xa9", c"/", c"\xc3\xa8", rpartition(c"\xc3\xa9/\xc3\xa8", c"/"))


void test_justify():
	str_test_expect(c"ab   ", ljust(c"ab", 5))
	str_test_expect(c"   ab", rjust(c"ab", 5))
	str_test_expect(c"ab***", ljust(c"ab", 5, '*'))
	str_test_expect(c"***ab", rjust(c"ab", 5, '*'))
	# Already wide enough (or a negative width): a plain copy
	str_test_expect(c"abcdef", ljust(c"abcdef", 3))
	str_test_expect(c"abcdef", rjust(c"abcdef", -1))
	str_test_expect(c"abc", center(c"abc", 2))
	str_test_expect(c"    ", ljust(c"", 4))
	str_test_expect(c"", rjust(c"", 0))


void test_center_rounding():
	# CPython: the odd pad goes left only when pad and width are both odd
	str_test_expect(c" a  ", center(c"a", 4))
	str_test_expect(c"  ab ", center(c"ab", 5))
	str_test_expect(c" abc ", center(c"abc", 5))
	str_test_expect(c"  a  ", center(c"a", 5))
	str_test_expect(c"--abc---", center(c"abc", 8, '-'))
	str_test_expect(c"   ", center(c"", 3))


void test_justify_counts_code_points():
	# Widths count code points, not bytes
	str_test_expect(c"\xc3\xa9t\xc3\xa9  ", ljust(c"\xc3\xa9t\xc3\xa9", 5))
	str_test_expect(c"  \xc3\xa9t\xc3\xa9", rjust(c"\xc3\xa9t\xc3\xa9", 5))
	str_test_expect(c" \xc3\xa9 ", center(c"\xc3\xa9", 3))
	str_test_expect(c"\xe2\x82\xac", rjust(c"\xe2\x82\xac", 1))


void test_zfill():
	str_test_expect(c"00042", zfill(c"42", 5))
	str_test_expect(c"-0042", zfill(c"-42", 5))
	str_test_expect(c"+0042", zfill(c"+42", 5))
	str_test_expect(c"+00", zfill(c"+", 3))
	str_test_expect(c"000", zfill(c"", 3))
	str_test_expect(c"12345", zfill(c"12345", 3))
	str_test_expect(c"-42", zfill(c"-42", 3))
	str_test_expect(c"0x1", zfill(c"x1", 3))


void test_capitalize():
	str_test_expect(c"Hello world", capitalize(c"hELLO WORLD"))
	str_test_expect(c"", capitalize(c""))
	str_test_expect(c"1abc", capitalize(c"1ABC"))
	str_test_expect(c"  a", capitalize(c"  A"))
	str_test_expect(c"\xc3\xa9cole", capitalize(c"\xc3\xa9COLE"))


void test_title():
	str_test_expect(c"Hello World", title(c"hello world"))
	str_test_expect(c"Hello World", title(c"HELLO WORLD"))
	str_test_expect(c"They'Re Bill'S", title(c"they're bill's"))
	str_test_expect(c"A1B2 C", title(c"a1b2 c"))
	str_test_expect(c"", title(c""))
	str_test_expect(c"   ", title(c"   "))
	# Non-ASCII bytes are copied and act as letters
	str_test_expect(c"Caf\xc3\xa9 Bar", title(c"caf\xc3\xa9 bar"))
	str_test_expect(c"\xc3\xa9mile Zola", title(c"\xc3\xa9MILE zola"))


void test_splitlines():
	str_test_expect3(c"a", c"b", c"c", splitlines(c"a\nb\r\nc"))
	str_test_expect3(c"a", c"", c"c", splitlines(c"a\r\rc\n"))
	list[char*] none = splitlines(c"")
	assert_equal(0, none.length)
	none.free()
	list[char*] one = splitlines(c"\n")
	assert_equal(1, one.length)
	assert_strings_equal(c"", one[0])
	str_test_free_all(one)
	one = splitlines(c"no break")
	assert_equal(1, one.length)
	assert_strings_equal(c"no break", one[0])
	str_test_free_all(one)
	# Whitespace-only lines are kept
	str_test_expect3(c"  ", c"\t", c" ", splitlines(c"  \n\t\n "))


void test_splitlines_other_breaks():
	str_test_expect3(c"a", c"b", c"c", splitlines(c"a\x0bb\x0cc"))
	str_test_expect3(c"a", c"b", c"c", splitlines(c"a\x1cb\x1ec"))
	# U+0085, U+2028, U+2029 encoded in UTF-8
	str_test_expect3(c"a", c"b", c"c", splitlines(c"a\xc2\x85b\xe2\x80\xa8c\xe2\x80\xa9"))
	# Other multi-byte characters are left intact
	str_test_expect3(c"\xc3\xa9", c"\xe2\x80\x94", c"\xc2\xa0", splitlines(c"\xc3\xa9\n\xe2\x80\x94\n\xc2\xa0"))


void test_splitlines_keepends():
	str_test_expect3(c"a\n", c"b\r\n", c"c", splitlines(c"a\nb\r\nc", 1))
	str_test_expect3(c"\r", c"\r\n", c"x\xe2\x80\xa8", splitlines(c"\r\r\nx\xe2\x80\xa8", 1))


void test_is_ascii():
	assert_equal(1, is_ascii(c""))
	assert_equal(1, is_ascii(c"plain text \t\n~"))
	assert_equal(1, is_ascii(c"\x7f"))
	assert_equal(0, is_ascii(c"caf\xc3\xa9"))
	assert_equal(0, is_ascii(c"\x80"))


void test_expandtabs():
	str_test_expect(c"01      012     0123    01234", expandtabs(c"01\t012\t0123\t01234"))
	str_test_expect(c"01  012 0123    01234", expandtabs(c"01\t012\t0123\t01234", 4))
	str_test_expect(c"a b", expandtabs(c"a\tb", 2))
	str_test_expect(c"ab", expandtabs(c"a\tb", 0))
	str_test_expect(c"ab", expandtabs(c"a\tb", -3))
	str_test_expect(c"", expandtabs(c""))
	str_test_expect(c"        ", expandtabs(c"\t"))
	str_test_expect(c"no tabs", expandtabs(c"no tabs"))


void test_expandtabs_columns():
	# The column restarts after \n and \r
	str_test_expect(c"ab  x\n    y\r    z", expandtabs(c"ab\tx\n\ty\r\tz", 4))
	# Multi-byte characters advance one column
	str_test_expect(c"\xc3\xa9t\xc3\xa9 x", expandtabs(c"\xc3\xa9t\xc3\xa9\tx", 4))
	str_test_expect(c"\xe2\x82\xac   x", expandtabs(c"\xe2\x82\xac\tx", 4))
