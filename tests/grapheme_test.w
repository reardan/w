import lib.testing
import lib.grapheme


void test_combining_mark_cluster():
	string s = "e\u0301x"
	assert_equal(2, grapheme_count(s))
	assert_equal(3, grapheme_next(s, 0))
	assert1(grapheme_is_boundary(s, 3))
	assert_equal(0, grapheme_is_boundary(s, 1))


void test_hebrew_combining_mark_cluster():
	string s = "\u05d0\u05b0x"
	assert_equal(2, grapheme_count(s))
	assert_equal(4, grapheme_next(s, 0))
	assert_equal(0, grapheme_is_boundary(s, 2))


void test_devanagari_spacing_mark_cluster():
	string s = "\u0915\u093ex"
	assert_equal(2, grapheme_count(s))
	assert_equal(6, grapheme_next(s, 0))
	assert_equal(0, grapheme_is_boundary(s, 3))


void test_hangul_jamo_cluster():
	string s = "\u1100\u1161\u11a8!"
	assert_equal(2, grapheme_count(s))
	assert_equal(9, grapheme_next(s, 0))


void test_emoji_zwj_cluster():
	string s = "\U0001f469\u200d\U0001f4bb!"
	assert_equal(2, grapheme_count(s))
	assert_equal(11, grapheme_next(s, 0))


void test_regional_indicator_pairs():
	string s = "\U0001f1fa\U0001f1f8\U0001f1e8"
	assert_equal(2, grapheme_count(s))
	assert_equal(8, grapheme_next(s, 0))
	assert_equal(12, grapheme_next(s, 8))


void test_crlf_cluster():
	string s = "\r\nx"
	assert_equal(2, grapheme_count(s))
	assert_equal(2, grapheme_next(s, 0))
