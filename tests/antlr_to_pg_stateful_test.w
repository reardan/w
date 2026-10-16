# wbuild: target=antlr_to_pg_stateful_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/antlr_to_pg --strict libs/extras/grammars/antlr_to_pg/testdata/stateful/ModesLexer.g4 libs/extras/grammars/antlr_to_pg/testdata/stateful/ModesParser.g4 --parser-name at_modes -o bin/at_modes.pg --matchers bin/at_modes_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/at_modes.pg -o bin/at_modes_parser.w"
# wbuild: step="bin/antlr_to_pg --strict --stateful libs/extras/grammars/antlr_to_pg/testdata/stateful/Priority.g4 --parser-name at_priority -o bin/at_priority.pg --matchers bin/at_priority_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/at_priority.pg -o bin/at_priority_parser.w"
# wbuild: step="bin/antlr_to_pg --strict libs/extras/grammars/antlr_to_pg/testdata/stateful/SwiftFinLexer.g4 libs/extras/grammars/antlr_to_pg/testdata/stateful/SwiftFinParser.g4 --parser-name at_swift -o bin/at_swift.pg --matchers bin/at_swift_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/at_swift.pg -o bin/at_swift_parser.w"
# wbuild: step="bin/antlr_to_pg --strict libs/extras/grammars/antlr_to_pg/testdata/stateful/PropertiesLexer.g4 libs/extras/grammars/antlr_to_pg/testdata/stateful/PropertiesParser.g4 --parser-name at_properties -o bin/at_properties.pg --matchers bin/at_properties_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/at_properties.pg -o bin/at_properties_parser.w"
# wbuild: step="bin/antlr_to_pg --strict --stateful libs/extras/grammars/antlr_to_pg/testdata/stateful/Collisions.g4 --parser-name at_collisions -o bin/at_collisions.pg --matchers bin/at_collisions_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/at_collisions.pg -o bin/at_collisions_parser.w"
# wbuild: step="bin/wv2 tests/antlr_to_pg_stateful_test.w -o bin/antlr_to_pg_stateful_test"
# wbuild: step="bin/antlr_to_pg_stateful_test"
# wbuild: step="sh libs/extras/grammars/antlr_to_pg/testdata/stateful/check.sh"
import lib.testing
import bin.at_modes_matchers
import bin.at_modes_parser
import bin.at_priority_matchers
import bin.at_priority_parser
import bin.at_swift_matchers
import bin.at_swift_parser
import bin.at_properties_matchers
import bin.at_properties_parser
import bin.at_collisions_matchers
import bin.at_collisions_parser


void stateful_translation_source(pg_parse_result* result, char* input):
	assert_equal(1, result.success)
	assert_equal(0, pg_diagnostics_count(result.diagnostics))
	assert_equal(0, result.stream.provider.mode)
	assert_equal(0, result.stream.provider.modes.length)
	char* actual = pg_token_stream_source(result.stream)
	assert_strings_equal(input, actual)
	free(actual)


void test_translated_modes_commands_priority_and_whitespace():
	char* input = c"if #hidden\n` a\nb ` <xyz>"
	pg_parse_result* result = at_modes_parse_owned(input, strlen(input), c"modes.txt")
	stateful_translation_source(result, input)
	assert_equal(at_modes_token_IDENT, result.stream.tokens[0].kind)
	assert_equal(at_modes_token_OPEN, result.stream.tokens[1].kind)
	assert_strings_equal(c" a", result.stream.tokens[2].text)
	assert_equal(at_modes_token_LINE, result.stream.tokens[3].kind)
	assert_strings_equal(c"b ", result.stream.tokens[4].text)
	assert_equal(at_modes_token_OPEN, result.stream.tokens[5].kind)
	assert_equal(at_modes_token_IDENT, result.stream.tokens[7].kind)
	int comments = 0
	for pg_token* token in result.stream.all_tokens:
		if (token.kind == at_modes_token_COMMENT):
			assert_equal(pg_token_hidden_channel, token.channel)
			comments++
	assert_equal(1, comments)
	pg_parse_result_free(result)


void test_translated_implicit_and_explicit_literal_priority():
	char* input = c"if ifx else 1221"
	pg_parse_result* result = at_priority_parse_owned(input, strlen(input), c"priority.txt")
	stateful_translation_source(result, input)
	pg_token_stream* stream = result.stream
	assert_equal(at_priority_token_KW_IF, stream.tokens[0].kind)
	assert_equal(at_priority_token_IDENT, stream.tokens[1].kind)
	# Explicit KW follows IDENT and loses an equal-length match. The
	# implicit 'if' precedes IDENT but cannot beat its longer 'ifx' match.
	assert_equal(at_priority_token_IDENT, stream.tokens[2].kind)
	assert_equal(at_priority_token_PREFIX_FREE, stream.tokens[3].kind)
	assert_strings_equal(c"1221", stream.tokens[3].text)
	pg_parse_result_free(result)


void test_translated_swift_fin_corpus():
	char* input = c"{1:ABC}{2:DEF}{3:{A:B}{C:D}}{4:{E:F}}{5:{G:H}}"
	pg_parse_result* result = at_swift_parse_owned(input, strlen(input), c"swift.fin")
	stateful_translation_source(result, input)
	pg_parse_result_free(result)
	input = c"{1:A}{4:\n:20:abc\n-}"
	result = at_swift_parse_owned(input, strlen(input), c"swift.fin")
	stateful_translation_source(result, input)
	pg_parse_result_free(result)
	input = c"{1:abc"
	result = at_swift_parse_owned(input, strlen(input), c"bad.fin")
	assert_equal(0, result.success)
	assert1(pg_diagnostics_count(result.diagnostics) > 0)
	pg_parse_result_free(result)
	input = c" {1:A}"
	result = at_swift_parse_owned(input, strlen(input), c"space.fin")
	assert_equal(0, result.success)
	assert1(pg_diagnostics_count(result.diagnostics) > 0)
	pg_parse_result_free(result)


void test_translated_properties_more_spans_and_lines():
	char* input = c"a\\=b=c\\\nd\n"
	pg_parse_result* result = at_properties_parse_owned(input, strlen(input), c"sample.properties")
	stateful_translation_source(result, input)
	pg_token* escaped = result.stream.tokens[1]
	assert_equal(at_properties_token_CHARACTER, escaped.kind)
	assert_strings_equal(c"\\=", escaped.text)
	assert_equal(1, escaped.offset)
	assert_equal(2, escaped.length)
	pg_token* continuation = result.stream.tokens[5]
	assert_equal(at_properties_token_CHARACTER, continuation.kind)
	assert_strings_equal(c"\\\n", continuation.text)
	assert_equal(6, continuation.offset)
	assert_equal(2, continuation.length)
	assert_equal(1, continuation.line)
	assert_equal(7, continuation.column)
	assert_equal(2, result.stream.tokens[6].line)
	assert_equal(1, result.stream.tokens[6].column)
	pg_parse_result_free(result)


void test_translated_properties_eof_in_value_mode():
	char* input = c"a=b"
	pg_parse_result* result = at_properties_parse_owned(input, strlen(input), c"eof.properties")
	assert_equal(1, result.success)
	assert_equal(0, pg_diagnostics_count(result.diagnostics))
	assert1(result.stream.provider.mode != 0)
	char* source = pg_token_stream_source(result.stream)
	assert_strings_equal(input, source)
	free(source)
	pg_parse_result_free(result)
	input = c"a=b\\"
	result = at_properties_parse_owned(input, strlen(input), c"broken.properties")
	assert_equal(0, result.success)
	assert1(pg_diagnostics_count(result.diagnostics) > 0)
	pg_parse_result_free(result)


void test_translated_expression_helper_name_collisions():
	char* input = c"1+2+3"
	pg_parse_result* result = at_collisions_parse_owned(input, strlen(input), c"expression.txt")
	stateful_translation_source(result, input)
	assert_equal(at_collisions_ast_expr, result.root.children[0].kind)
	pg_parse_result_free(result)
	result = at_collisions_parse_owned(c"x", 1, c"source-rule.txt")
	stateful_translation_source(result, c"x")
	assert_equal(at_collisions_ast_expr_prec0_g1, result.root.children[0].kind)
	pg_parse_result_free(result)
	result = at_collisions_parse_owned(c"p", 1, c"primary-rule.txt")
	stateful_translation_source(result, c"p")
	assert_equal(at_collisions_ast_expr_primary, result.root.children[0].kind)
	pg_parse_result_free(result)
