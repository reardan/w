import lib.assert
import bin.antlr_safety_matchers


int main():
	assert_equal(1, pg_lexer_matcher_g_safety_A(c"a", 0))
	assert_equal(2, pg_lexer_matcher_g_safety_A(c"ab", 0))
	assert_equal(0, pg_lexer_matcher_g_safety_A(c"b", 0))
	assert_equal(0, pg_lexer_matcher_g_safety_A(c"", 0))
	assert_equal(1, pg_lexer_matcher_g_safety_B(c"q", 0))
	assert_equal(4, pg_lexer_matcher_g_safety_B(c"qqqq!", 0))
	assert_equal(0, pg_lexer_matcher_g_safety_B(c"", 0))
	assert_equal(1, pg_lexer_matcher_g_safety_C(c"a", 0))
	assert_equal(3, pg_lexer_matcher_g_safety_C(c"aba", 0))
	assert_equal(5, pg_lexer_matcher_g_safety_C(c"ababa", 0))
	assert_equal(7, pg_lexer_matcher_g_safety_C(c"abababa!", 0))
	assert_equal(1, pg_lexer_matcher_g_safety_C(c"ab", 0))
	assert_equal(7, pg_lexer_matcher_g_safety_D(c"abababa!", 0))
	assert_equal(1, pg_lexer_matcher_g_safety_E(c"z", 0))
	assert_equal(4, pg_lexer_matcher_g_safety_E(c"xxxz!", 0))
	assert_equal(0, pg_lexer_matcher_g_safety_E(c"xxx", 0))
	assert_equal(4, pg_lexer_matcher_g_safety_F(c"zxxx!", 0))
	assert_equal(0, pg_lexer_matcher_g_safety_F(c"xxx", 0))
	# Fusion Tables' numeric recursion: disjoint sign alternatives and a
	# referenced digit range must retain every complete match length.
	assert_equal(1, pg_lexer_matcher_g_safety_G(c"0", 0))
	assert_equal(6, pg_lexer_matcher_g_safety_G(c"123.45!", 0))
	assert_equal(4, pg_lexer_matcher_g_safety_G(c"-1.5", 0))
	assert_equal(6, pg_lexer_matcher_g_safety_G(c"+-+-12!", 0))
	assert_equal(2, pg_lexer_matcher_g_safety_G(c"1.", 0))
	assert_equal(0, pg_lexer_matcher_g_safety_G(c"+-", 0))
	assert_equal(0, pg_lexer_matcher_g_safety_G(c".5", 0))
	assert_equal(2, pg_lexer_matcher_g_safety_G(c"12-3", 0))
	println(c"antlr generated nullable and recursive matcher execution passed")
	return 0
