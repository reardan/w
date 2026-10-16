# wbuild: target=antlr_exact_lexer_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/antlr_to_pg --strict --exact-lexer tests/grammars/antlr_exact_lexer/Exact.g4 -o bin/at_exact.pg --parser-name at_exact --matchers bin/at_exact_matchers.w"
# wbuild: step="bin/wv2 --strict tests/antlr_exact_lexer_test.w -o bin/antlr_exact_lexer_test"
# wbuild: step="bin/antlr_exact_lexer_test"
import lib.testing
import structures.string
import bin.at_exact_matchers


void test_exact_greedy_continuations():
	assert_equal(4, pg_lexer_matcher_g_at_exact_WORD(c"abxx!", 0))
	assert_equal(-8, pg_lexer_matcher_g_at_exact_WORD(c"abc!", 0))
	assert_equal(5, pg_lexer_matcher_g_at_exact_REPEAT(c"aaaaa!", 0))
	assert_equal(7, pg_lexer_matcher_g_at_exact_REPEAT(c"aaaaaaa!", 0))
	assert_equal(2, pg_lexer_matcher_g_at_exact_OPTIONAL(c"ox!", 0))
	assert_equal(3, pg_lexer_matcher_g_at_exact_OPTIONAL(c"oxx!", 0))
	assert_equal(4, pg_lexer_matcher_g_at_exact_FRAGMENT(c"fabx!", 0))
	assert_equal(3, pg_lexer_matcher_g_at_exact_FRAGMENT(c"fax!", 0))
	assert_equal(-8, pg_lexer_matcher_g_at_exact_FRAGMENT(c"fab!", 0))


void test_exact_priority_and_nongreedy():
	assert_equal(3, pg_lexer_matcher_g_at_exact_NON_GREEDY(c"<a><b>", 0))
	assert_equal(6, pg_lexer_matcher_g_at_exact_GREEDY(c"{a}{b}", 0))
	assert_equal(-6, pg_lexer_matcher_g_at_exact_NON_GREEDY(c"<a", 0))
	assert_equal(3, pg_lexer_matcher_g_at_exact_NON_GREEDY(c"!<a>", 1))


void test_exact_productive_recursive_fragments():
	assert_equal(9, pg_lexer_matcher_g_at_exact_NESTED(c"[a[b]c[]]", 0))
	assert_equal(-11, pg_lexer_matcher_g_at_exact_NESTED(c"[a[b]c[", 0))
	assert_equal(2, pg_lexer_matcher_g_at_exact_NESTED(c"[][]", 0))


void test_exact_scalar_wildcards():
	assert_equal(4, pg_lexer_matcher_g_at_exact_WIDE(c"w\xc3\xa9x", 0))
	assert_equal(6, pg_lexer_matcher_g_at_exact_WIDE(c"w\xf0\x9f\x98\x80x", 0))
	assert_equal(-3, pg_lexer_matcher_g_at_exact_WIDE(c"w\xc3x", 0))


void test_exact_nongreedy_order_and_continuation():
	assert_equal(2, pg_lexer_matcher_g_at_exact_ORDERED(c"nab", 0))
	assert_equal(5, pg_lexer_matcher_g_at_exact_NG_SUFFIX(c"saaab", 0))
	assert_equal(2, pg_lexer_matcher_g_at_exact_NG_OPTIONAL(c"uaa", 0))
	assert_equal(3, pg_lexer_matcher_g_at_exact_NG_PLUS(c"paaaa", 0))
	assert_equal(5, pg_lexer_matcher_g_at_exact_MIXED(c"maaaa", 0))


void exact_test_word(string_builder* out, int value):
	for shift in range(0, 32, 8): string_append_char(out, (value >> shift) & 255)


void exact_test_state(string_builder* out, int op, int next, int other, int low, int high):
	exact_test_word(out, op)
	exact_test_word(out, next)
	exact_test_word(out, other)
	exact_test_word(out, low)
	exact_test_word(out, high)
	exact_test_word(out, 0)


void test_exact_resource_limits_and_metrics():
	string_builder* code = string_new()
	exact_test_state(code, 2, 1, 2, 0, 0)
	exact_test_state(code, 1, 0, 0, 97, 97)
	exact_test_state(code, 5, 0, 0, 0, 0)
	string_builder* input = string_new()
	for i in range(2000): string_append_char(input, 97)
	at_lex_result* result = at_lex_execute(code.data, 3, 0, input.data, 0, 20000)
	assert_equal(1, result.status)
	assert_equal(2000, result.length)
	assert1(result.steps < 10000)
	assert_equal(1, result.peak_configs)
	assert_equal(1, result.stack_count)
	free(result)
	result = at_lex_execute(code.data, 3, 0, input.data, 0, 10)
	assert_equal(-2, result.status)
	free(result)
	assert_equal(-4, at_lex_match(code.data, 3, 0, c"", 0))
	string_free(input)
	string_free(code)
