# wbuild: target=antlr_token_sets_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/antlr_to_pg --strict --prediction --exact-lexer tests/grammars/antlr_token_sets/TokenSets.g4 -o bin/antlr_token_sets.pg --parser-name token_sets --matchers bin/antlr_token_sets_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_token_sets.pg -o bin/antlr_token_sets_parser.w"
# wbuild: step="bin/wv2 --strict tests/antlr_token_sets_test.w -o bin/antlr_token_sets_test"
# wbuild: step="bin/antlr_token_sets_test"
import lib.testing
import bin.antlr_token_sets_matchers
import bin.antlr_token_sets_parser

void token_set_accepts(char* input, int expected):
	pg_parse_result* result = token_sets_parse_owned(input, strlen(input), c"sets")
	assert_equal(expected, result.success)
	pg_parse_result_free(result)

void test_parser_sets_match_whole_tokens():
	token_set_accepts(c"n123", 1)
	token_set_accepts(c"nkeyword", 1)
	token_set_accepts(c"nword", 0)
	token_set_accepts(c"n,", 0)
	token_set_accepts(c"wword", 1)
	token_set_accepts(c"w123", 1)
	token_set_accepts(c"w", 0)
	token_set_accepts(c"lword", 1)
	token_set_accepts(c"lkeyword", 0)
