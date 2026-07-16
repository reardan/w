import lib.testing
import libs.extras.parser_generator.diagnostics
import libs.extras.parser_generator.grammar_reader
import libs.extras.parser_generator.runtime
import bin.generated_matcher_expressions_parser


void assert_matcher_token(pg_token_stream* stream, int index, int kind, char* text):
	pg_token* token = pg_token_stream_la(stream, index)
	assert_equal(kind, token.kind)
	assert_strings_equal(text, token.text)


void test_matcher_expressions_lex_end_to_end():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	char* input = c"@ abc zoom #x1Af 'q' thing-name_2 +42 pre12\r\n -- hidden\n"
	pg_token_stream* stream = matcher_expr_lex(input, c"matcher.txt", diagnostics)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_matcher_token(stream, 1, matcher_expr_token_TIE_FIRST(), c"@")
	assert_matcher_token(stream, 2, matcher_expr_token_LONG(), c"abc")
	assert_matcher_token(stream, 3, matcher_expr_token_ALT(), c"zoom")
	assert_matcher_token(stream, 4, matcher_expr_token_NUMCONST(), c"#x1Af")
	assert_matcher_token(stream, 5, matcher_expr_token_NUMCONST(), c"'q'")
	assert_matcher_token(stream, 6, matcher_expr_token_IDENT(), c"thing-name_2")
	assert_matcher_token(stream, 7, matcher_expr_token_SIGNED(), c"+42")
	assert_matcher_token(stream, 8, matcher_expr_token_PREFIXED(), c"pre12")
	assert_matcher_token(stream, 9, matcher_expr_token_NEWLINE_TOK(), c"\r\n")
	assert_matcher_token(stream, 10, matcher_expr_token_NEWLINE_TOK(), c"\n")
	assert_equal(pg_token_eof_kind(), pg_token_stream_la(stream, 11).kind)
	int found_comment = 0
	int i = 0
	while (i < pg_token_stream_all_count(stream)):
		pg_token* token = pg_token_stream_all_get(stream, i)
		if (token.kind == matcher_expr_token_DASH_COMMENT()):
			found_comment = 1
			assert_equal(pg_token_hidden_channel(), token.channel)
			assert_strings_equal(c"-- hidden", token.text)
		i = i + 1
	assert_equal(1, found_comment)


# Literal selection through the first-byte dispatch: trie fallback from
# "<<=" to "<", literal-over-token priority on equal length ("zoo" beats
# IDENT), longest token over shorter literal ("zoom" via ALT), and
# declaration-order tie-breaks ("z", "ab") staying with the first token.
void test_matcher_dispatch_literals():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	char* input = c"<<x zoo zoom <<= < z ab"
	pg_token_stream* stream = matcher_expr_lex(input, c"literals.txt", diagnostics)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_matcher_token(stream, 1, matcher_expr_token_LT(), c"<")
	assert_matcher_token(stream, 2, matcher_expr_token_LT(), c"<")
	assert_matcher_token(stream, 3, matcher_expr_token_IDENT(), c"x")
	assert_matcher_token(stream, 4, matcher_expr_token_KW_ZOO(), c"zoo")
	assert_matcher_token(stream, 5, matcher_expr_token_ALT(), c"zoom")
	assert_matcher_token(stream, 6, matcher_expr_token_SHL_ASSIGN(), c"<<=")
	assert_matcher_token(stream, 7, matcher_expr_token_LT(), c"<")
	assert_matcher_token(stream, 8, matcher_expr_token_ALT(), c"z")
	assert_matcher_token(stream, 9, matcher_expr_token_SHORT(), c"ab")
	assert_equal(pg_token_eof_kind(), pg_token_stream_la(stream, 10).kind)


# Bytes outside every matcher's first set (e.g. 0xff) must still lex as
# hidden invalid tokens with a diagnostic, exactly like the linear sweep.
void test_matcher_dispatch_invalid_byte():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = matcher_expr_lex(c"ab\xffab", c"invalid.txt", diagnostics)
	assert_equal(1, pg_diagnostics_count(diagnostics))
	assert_matcher_token(stream, 1, matcher_expr_token_SHORT(), c"ab")
	assert_matcher_token(stream, 2, matcher_expr_token_SHORT(), c"ab")
	assert_equal(pg_token_eof_kind(), pg_token_stream_la(stream, 3).kind)


void test_matcher_expression_rejects_nullable_repetition():
	char* grammar_text = c"parser bad\ntoken BAD = (\"x\"?)*\nstart root\nrule root = EOF\n"
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_grammar* grammar = pg_grammar_read(grammar_text, c"nullable.pg", diagnostics)
	assert_equal(0, cast(int, grammar))
	assert_equal(1, pg_diagnostics_count(diagnostics))
	assert_strings_equal(c"repeated matcher can match empty", pg_diagnostics_get(diagnostics, 0).message)


void test_matcher_expression_rejects_unknown_reference():
	char* grammar_text = c"parser bad\ntoken BAD = MISSING\nstart root\nrule root = EOF\n"
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_grammar* grammar = pg_grammar_read(grammar_text, c"unknown.pg", diagnostics)
	assert_equal(0, cast(int, grammar))
	assert_equal(1, pg_diagnostics_count(diagnostics))
	assert_strings_equal(c"unknown matcher reference", pg_diagnostics_get(diagnostics, 0).message)


void test_matcher_expression_rejects_reference_cycle():
	char* grammar_text = c"parser bad\nfragment A = B\nfragment B = A\ntoken BAD = A\nstart root\nrule root = EOF\n"
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_grammar* grammar = pg_grammar_read(grammar_text, c"cycle.pg", diagnostics)
	assert_equal(0, cast(int, grammar))
	assert_equal(1, pg_diagnostics_count(diagnostics))
	assert_strings_equal(c"cyclic matcher reference", pg_diagnostics_get(diagnostics, 0).message)
