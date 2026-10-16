# wbuild: target=antlr_exact_unicode_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/antlr_to_pg --strict --exact-lexer tests/grammars/antlr_exact_lexer/Unicode.g4 -o bin/at_unicode.pg --parser-name at_unicode --matchers bin/at_unicode_matchers.w"
# wbuild: step="bin/wv2 --strict tests/antlr_exact_unicode_test.w -o bin/antlr_exact_unicode_test"
# wbuild: step="bin/antlr_exact_unicode_test"
# wbuild: step="sh tests/grammars/antlr_exact_lexer/check.sh"
import lib.testing
import bin.at_unicode_matchers
import libs.extras.grammars.antlr_to_pg.lexer_unicode


void test_exact_unicode_literals_ranges_and_properties():
	assert_equal(4, pg_lexer_matcher_g_at_unicode_ACCENT(c"éÉ", 0))
	assert_equal(4, pg_lexer_matcher_g_at_unicode_SCALAR(c"😀!", 0))
	assert_equal(7, pg_lexer_matcher_g_at_unicode_LETTER(c"éΩ字1", 0))
	assert_equal(4, pg_lexer_matcher_g_at_unicode_RAW(c"ωΩ!", 0))
	assert_equal(2, pg_lexer_matcher_g_at_unicode_RANGE(c"ā!", 0))
	assert_equal(-5, pg_lexer_matcher_g_at_unicode_RANGE(c"a", 0))


void test_exact_unicode_complements_and_literal_caret():
	assert_equal(2, pg_lexer_matcher_g_at_unicode_CARET(c"^^a", 0))
	assert_equal(-5, pg_lexer_matcher_g_at_unicode_CARET(c"a", 0))
	assert_equal(2, pg_lexer_matcher_g_at_unicode_NEGATED(c"~xΩ", 0))
	assert_equal(-7, pg_lexer_matcher_g_at_unicode_NOT_LITERAL(c"~ω", 0))
	assert_equal(3, pg_lexer_matcher_g_at_unicode_NOT_LITERAL(c"~α", 0))
	assert_equal(-7, pg_lexer_matcher_g_at_unicode_NOT_GROUP(c"/Ω", 0))
	assert_equal(-7, pg_lexer_matcher_g_at_unicode_NOT_GROUP(c"/Α", 0))
	assert_equal(3, pg_lexer_matcher_g_at_unicode_NOT_GROUP(c"/β", 0))
	assert_equal(-6, pg_lexer_matcher_g_at_unicode_NOT_GROUP(c"/^", 0))
	assert_equal(-6, pg_lexer_matcher_g_at_unicode_NOT_GROUP(c"/[", 0))


void test_exact_rule_case_override_and_mixed_range():
	assert_equal(3, pg_lexer_matcher_g_at_unicode_LOWER(c"abc", 0))
	assert_equal(-5, pg_lexer_matcher_g_at_unicode_LOWER(c"ABC", 0))
	assert_equal(4, pg_lexer_matcher_g_at_unicode_MIXED_RANGE(c"!a_Z", 0))


void test_exact_property_aliases_and_malformed_input():
	list[int] ranges = at_unicode_charset(c"[\\p{General_Category=Uppercase_Letter}]", 0, 0)
	assert1(ranges != 0)
	ranges.free()
	ranges = at_unicode_charset(c"[\\P{White_Space}]", 0, 0)
	assert1(ranges != 0)
	ranges.free()
	assert_equal(0, cast(int, at_unicode_charset(c"[\\p{Definitely_Not_A_Property}]", 0, 0)))
	assert_equal(0, cast(int, at_unicode_charset(c"[z-a]", 0, 0)))
	assert_equal(0, cast(int, at_unicode_literal(c"'\\u{110000}'")))
	assert_equal(0, cast(int, at_unicode_literal(c"'\\uD800'")))
	char* surrogate_pair = at_unicode_literal(c"'\\uD83D\\uDE00'")
	assert_strings_equal(c"😀", surrogate_pair)
	free(surrogate_pair)


void test_exact_large_property_repetition():
	string_builder* input = string_new()
	for i in range(2000): string_append(input, c"α")
	assert_equal(4000, pg_lexer_matcher_g_at_unicode_LETTER(input.data, 0))
	string_free(input)


void test_exact_zero_endpoint_ranges_and_complements():
	assert_equal(1, pg_lexer_matcher_g_at_unicode_BYTE_RANGE(c"a", 0))
	assert_equal(2, pg_lexer_matcher_g_at_unicode_BYTE_RANGE(c"ÿ", 0))
	assert_equal(-6, pg_lexer_matcher_g_at_unicode_BYTE_RANGE(c"Ā", 0))
	assert_equal(0, pg_lexer_matcher_g_at_unicode_BYTE_RANGE(c"", 0))
	assert_equal(5, pg_lexer_matcher_g_at_unicode_IRI_RANGE(c"<a/b>", 0))
	assert_equal(6, pg_lexer_matcher_g_at_unicode_IRI_RANGE(c"<😀>", 0))
	assert_equal(-7, pg_lexer_matcher_g_at_unicode_IRI_RANGE(c"<a b>", 0))
	assert_equal(0, at_unicode_scalar_literal(c"'\\u0000'"))
	assert_equal(-1, at_unicode_scalar_literal(c"'ab'"))
	assert_equal(-1, at_unicode_scalar_literal(c"'\\uD800'"))
	assert_equal(128512, at_unicode_scalar_literal(c"'\\uD83D\\uDE00'"))
