# wbuild: target=antlr_eof_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/antlr_to_pg --strict --exact-lexer --prediction tests/grammars/antlr_eof/End.g4 -o bin/antlr_end.pg --parser-name antlr_end --matchers bin/antlr_end_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_end.pg -o bin/antlr_end_parser.w"
# wbuild: step="bin/wv2 --strict tests/antlr_eof_test.w -o bin/antlr_eof_test"
# wbuild: step="bin/antlr_eof_test"
import lib.testing
import bin.antlr_end_matchers
import bin.antlr_end_parser

void test_consuming_token_at_eof_does_not_invent_a_named_eof_token():
	# ANTLR marks EOF after A consumes the last input character. A later
	# nextToken call emits built-in EOF without running the CR: EOF rule.
	pg_parse_result* result = antlr_end_parse_owned(c"a", 1, c"end")
	assert_equal(0, result.success)
	assert_equal(2, result.stream.tokens.length)
	assert_equal(pg_token_eof_kind, result.stream.tokens[1].kind)
	pg_parse_result_free(result)
	result = antlr_end_parse_owned(c"a\n", 2, c"newline")
	assert_equal(1, result.success)
	assert_equal(0, pg_diagnostics_count(result.diagnostics))
	assert_equal(3, result.stream.tokens.length)
	assert_equal(antlr_end_token_CR, result.stream.tokens[1].kind)
	assert_equal(1, result.stream.tokens[1].length)
	pg_parse_result_free(result)


void test_named_eof_not_repeated():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_lexer_state* state = antlr_end_provider_new(c"", 0, c"empty")
	pg_token* token = antlr_end_next(state, diagnostics)
	assert_equal(antlr_end_token_CR, token.kind)
	pg_token_free(token)
	for i in range(3):
		token = antlr_end_next(state, diagnostics)
		assert_equal(pg_token_eof_kind, token.kind)
		pg_token_free(token)
	pg_lexer_state_free(state)
	pg_diagnostics_free(diagnostics)
