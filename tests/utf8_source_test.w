# wbuild: x64
# Raw (non-escaped) multi-byte UTF-8 bytes in source: comments, "..."
# string literals, s"..." literals and f-string chunks are byte-
# transparent or UTF-8-validated paths that were working but untested
# before #287 stage 1. Escape-sequence coverage lives in
# tests/string_utf8_test.w and tests/template_string_test.w; this file
# is the raw-bytes twin. Line-comment probe: héllo wörld 日本語 🎉
import lib.testing
import lib.utf8


/*
Block-comment probe: the scanner only looks for the ASCII bytes '*' and
'/', so raw UTF-8 must pass straight through — café, naïve, 日本語, 🎉.
*/


void check(char* want, string got):
	assert_equal(strlen(want), got.length)
	assert_strings_equal(want, got.data)


void test_raw_utf8_default_string_literal():
	string s = "héllo wörld 日本語 🎉"
	# .length is the byte length (28), not the codepoint count (17)
	assert_equal(28, s.length)
	assert1(utf8_validate(s))
	assert_equal(17, utf8_codepoint_count(s))
	# 'é' is U+00E9, encoded C3 A9 starting at byte offset 1
	assert_equal(233, utf8_decode(s, 1))
	assert_equal(0xc3, s[1] & 255)
	assert_equal(0xa9, s[2] & 255)
	# '日' is U+65E5 at byte offset 14 (after "héllo wörld ")
	assert_equal(26085, utf8_decode(s, 14))
	# '🎉' is U+1F389, the trailing 4-byte sequence
	assert_equal(127881, utf8_decode(s, 24))


void test_raw_utf8_matches_escaped_spelling():
	# The raw bytes and the \u/\U escapes decode to the same string
	assert1(utf8_equals("é", "\u00e9"))
	assert1(utf8_equals("日本語", "\u65e5\u672c\u8a9e"))
	assert1(utf8_equals("🎉", "\U0001f389"))


void test_raw_utf8_prefixed_string_literal():
	string s = s"grüße 語"
	assert_equal(11, s.length)
	assert_equal(7, utf8_codepoint_count(s))
	assert1(utf8_equals(s, "grüße 語"))


void test_raw_utf8_in_template_string():
	int n = 42
	check(c"caf\xc3\xa9: 42 \xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", f"café: {n} 日本語")


void test_raw_utf8_iterates_codepoints():
	string s = "aé語🎉"
	int count = 0
	int sum = 0
	for int cp in s:
		count = count + 1
		sum = sum + cp
	assert_equal(4, count)
	assert_equal('a' + 233 + 35486 + 127881, sum)
