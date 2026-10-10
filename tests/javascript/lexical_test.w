# wbuild: name=javascript_lexical_test
# wbuild: x64
import lib.testing
import libs.extras.javascript.lexical


void test_js_identifier_unicode_and_escapes():
	assert_equal(4, pg_lexer_matcher_js_identifier(c"$foo!", 0))
	assert_equal(8, pg_lexer_matcher_js_identifier(c"\\u0061bc", 0))
	assert_equal(4, pg_lexer_matcher_js_identifier(c"\xf0\x90\x90\x80", 0))
	assert_equal(4, pg_lexer_matcher_js_identifier(c"a\xe2\x80\x8c", 0))
	assert_equal(0, pg_lexer_matcher_js_identifier(c"\xe2\x80\x8c", 0))
	assert_equal(0, pg_lexer_matcher_js_identifier(c"\\u0030", 0))
	assert_equal(0, pg_lexer_matcher_js_identifier(c"\\uD800", 0))
	assert_equal(0, pg_lexer_matcher_js_identifier(c"\xf0\x80", 0))
	assert_equal(0, pg_lexer_matcher_js_identifier(c"\\u{110000}", 0))


void test_js_numeric_boundaries():
	assert_equal(6, pg_lexer_matcher_js_number(c"1.2e-3", 0))
	assert_equal(2, pg_lexer_matcher_js_number(c".5", 0))
	assert_equal(2, pg_lexer_matcher_js_number(c"1..x", 0))
	assert_equal(5, pg_lexer_matcher_js_number(c"0xffn", 0))
	assert_equal(5, pg_lexer_matcher_js_number(c"0b101", 0))
	assert_equal(0, pg_lexer_matcher_js_number(c"0b102", 0))
	assert_equal(0, pg_lexer_matcher_js_number(c"42abc", 0))
	assert_equal(0, pg_lexer_matcher_js_number(c"1e+", 0))
	assert_equal(0, pg_lexer_matcher_js_number(c"1.0n", 0))
	assert_equal(0, pg_lexer_matcher_js_number(c"01n", 0))
	assert_equal(0, pg_lexer_matcher_js_number(c"0x", 0))
	assert_equal(0, pg_lexer_matcher_js_number(c".", 0))


void test_js_string_and_comment_boundaries():
	assert_equal(8, pg_lexer_matcher_js_string(c"'\\u0061'", 0))
	assert_equal(6, pg_lexer_matcher_js_string(c"'\\x61'", 0))
	assert_equal(6, pg_lexer_matcher_js_string(c"'a\\\nb'", 0))
	assert_equal(0, pg_lexer_matcher_js_string(c"'a\nb'", 0))
	assert_equal(0, pg_lexer_matcher_js_string(c"'\\xQ0'", 0))
	assert_equal(0, pg_lexer_matcher_js_string(c"'\\u{110000}'", 0))
	assert_equal(0, pg_lexer_matcher_js_string(c"'unterminated", 0))
	assert_equal(3, pg_lexer_matcher_js_line_comment(c"//x\xe2\x80\xa8tail", 0))
	assert_equal(5, pg_lexer_matcher_js_block_comment(c"/*x*/tail", 0))
	assert_equal(0, pg_lexer_matcher_js_block_comment(c"/*x", 0))


void test_js_regex_and_template_boundaries():
	assert_equal(8, pg_lexer_matcher_js_regex(c"/[a/]+/g.test(x)", 0))
	assert_equal(6, pg_lexer_matcher_js_regex(c"/a\\/b/", 0))
	assert_equal(0, pg_lexer_matcher_js_regex(c"/a/gg", 0))
	assert_equal(0, pg_lexer_matcher_js_regex(c"/a/z", 0))
	assert_equal(0, pg_lexer_matcher_js_regex(c"/a\n/", 0))
	assert_equal(0, pg_lexer_matcher_js_regex(c"/[a/", 0))
	assert_equal(0, pg_lexer_matcher_js_regex(c"//x", 0))
	assert_equal(3, pg_lexer_matcher_js_template_text(c"abc${x}", 0))
	assert_equal(4, pg_lexer_matcher_js_template_text(c"a\\`b`", 0))
	assert_equal(4, pg_lexer_matcher_js_space(c" \xe2\x80\xa8x", 0))
