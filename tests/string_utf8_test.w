import lib.testing
import lib.utf8


void test_utf8_decode_encode_and_boundaries():
	string s = "A\u00e9\U0001f600"
	assert_equal(7, s.length)
	assert_equal(65, utf8_decode(s, 0))
	assert_equal(233, utf8_decode(s, 1))
	assert_equal(128512, utf8_decode(s, 3))
	assert1(utf8_is_boundary(s, 0))
	assert1(utf8_is_boundary(s, 1))
	assert1(utf8_is_boundary(s, 3))
	assert1(utf8_is_boundary(s, 7))
	assert_equal(0, utf8_is_boundary(s, 2))
	char[4] out
	assert_equal(4, utf8_encode(out.data, 128512))
	assert_equal(s[3], out[0])
	assert_equal(s[4], out[1])
	assert_equal(s[5], out[2])
	assert_equal(s[6], out[3])


void test_string_from_bytes_and_prefix_suffix():
	char* raw = c"hello \xc3\xa9"
	string s = string_from_bytes(raw, 8)
	assert1(utf8_validate(s))
	assert_equal(7, utf8_codepoint_count(s))
	assert1(string_starts_with(s, "hell"))
	assert1(string_ends_with(s, "\u00e9"))
	assert_equal(0, string_starts_with(s, "ello"))
	assert_equal(0, string_ends_with(s, "e"))


void test_for_in_string_iterates_codepoints():
	string s = "A\u00e9\U0001f600"
	int count = 0
	int sum = 0
	for int cp in s:
		count = count + 1
		sum = sum + cp
	assert_equal(3, count)
	assert_equal(128810, sum)
