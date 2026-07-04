import lib.testing
import libs.extras.parser_generator.runtime
import bin.generated_sample_parser


void test_generated_parser_ast_shape():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = sample_parse("alpha 123 beta", "sample.txt", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(sample_ast_list(), root.kind)
	assert_equal(4, pg_ast_child_count(root))
	assert_equal(sample_ast_value(), pg_ast_child(root, 0).kind)
	assert_equal(sample_ast_value(), pg_ast_child(root, 1).kind)
	assert_equal(sample_ast_value(), pg_ast_child(root, 2).kind)
	assert_equal(sample_token_EOF(), pg_ast_child(root, 3).kind)
	assert_strings_equal("alpha", pg_ast_child(pg_ast_child(root, 0), 0).text)
	assert_strings_equal("123", pg_ast_child(pg_ast_child(root, 1), 0).text)


void test_generated_parser_alternative():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = sample_parse("42", "sample.txt", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(sample_token_NUMBER(), pg_ast_child(pg_ast_child(root, 0), 0).kind)


void test_generated_lexer_literals():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = sample_lex("a,b", "sample.txt", diagnostics)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(sample_token_WORD(), pg_token_stream_la(stream, 1).kind)
	assert_equal(sample_token_COMMA(), pg_token_stream_la(stream, 2).kind)
	assert_equal(sample_token_WORD(), pg_token_stream_la(stream, 3).kind)
	assert_strings_equal(",", pg_token_stream_la(stream, 2).text)


void test_generated_parser_syntax_error():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = sample_parse("", "sample.txt", diagnostics)
	assert_equal(0, root)
	assert_equal(1, pg_diagnostics_count(diagnostics))
	pg_diagnostic* diagnostic = pg_diagnostics_get(diagnostics, 0)
	assert_strings_equal("syntax error", diagnostic.message)
	assert_strings_equal("list", diagnostic.expected)


void test_generated_parser_lexer_error():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = sample_parse("alpha !", "sample.txt", diagnostics)
	assert1(root != 0)
	assert_equal(1, pg_diagnostics_count(diagnostics))
	pg_diagnostic* diagnostic = pg_diagnostics_get(diagnostics, 0)
	assert_strings_equal("invalid character", diagnostic.message)
