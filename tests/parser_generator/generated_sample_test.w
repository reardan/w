import lib.testing
import libs.extras.parser_generator.runtime
import bin.generated_sample_parser


char* traversal_values
int traversal_count


void traversal_reset():
	traversal_values = malloc(128)
	traversal_count = 0


void traversal_record(int value):
	save_int(traversal_values + traversal_count * 4, value)
	traversal_count = traversal_count + 1


int traversal_get(int index):
	return load_int(traversal_values + index * 4)


void traversal_visit(pg_ast_node* node):
	traversal_record(node.kind)


void traversal_enter(pg_ast_node* node):
	traversal_record(node.kind)


void traversal_leave(pg_ast_node* node):
	traversal_record(0 - node.kind)


void test_generated_parser_ast_shape():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = sample_parse(c"alpha 123 beta", c"sample.txt", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(sample_ast_list(), root.kind)
	assert_equal(4, pg_ast_child_count(root))
	assert_equal(sample_ast_value(), pg_ast_child(root, 0).kind)
	assert_equal(sample_ast_value(), pg_ast_child(root, 1).kind)
	assert_equal(sample_ast_value(), pg_ast_child(root, 2).kind)
	assert_equal(sample_token_EOF(), pg_ast_child(root, 3).kind)
	assert_strings_equal(c"alpha", pg_ast_child(pg_ast_child(root, 0), 0).text)
	assert_strings_equal(c"123", pg_ast_child(pg_ast_child(root, 1), 0).text)


void test_generated_parser_alternative():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = sample_parse(c"42", c"sample.txt", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(sample_token_NUMBER(), pg_ast_child(pg_ast_child(root, 0), 0).kind)


void test_generated_lexer_literals():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = sample_lex(c"a,b", c"sample.txt", diagnostics)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(sample_token_WORD(), pg_token_stream_la(stream, 1).kind)
	assert_equal(sample_token_COMMA(), pg_token_stream_la(stream, 2).kind)
	assert_equal(sample_token_WORD(), pg_token_stream_la(stream, 3).kind)
	assert_strings_equal(c",", pg_token_stream_la(stream, 2).text)


void test_generated_lexer_doubled_strings_and_sql_comment():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = sample_lex(c"'can''t' \"a\"\"b\" -- hidden", c"sample.txt", diagnostics)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	pg_token* single_quoted = pg_token_stream_la(stream, 1)
	assert_equal(sample_token_SINGLE_QUOTED(), single_quoted.kind)
	assert_equal(0, single_quoted.offset)
	assert_equal(8, single_quoted.length)
	assert_strings_equal(c"'can''t'", single_quoted.text)
	pg_token* double_quoted = pg_token_stream_la(stream, 2)
	assert_equal(sample_token_DOUBLE_QUOTED(), double_quoted.kind)
	assert_equal(9, double_quoted.offset)
	assert_equal(6, double_quoted.length)
	assert_strings_equal(c"\"a\"\"b\"", double_quoted.text)
	assert_equal(pg_token_eof_kind(), pg_token_stream_la(stream, 3).kind)
	assert_equal(6, pg_token_stream_all_count(stream))
	pg_token* sql_comment = pg_token_stream_all_get(stream, 4)
	assert_equal(sample_token_SQL_LINE_COMMENT(), sql_comment.kind)
	assert_equal(pg_token_hidden_channel(), sql_comment.channel)
	assert_equal(16, sql_comment.offset)
	assert_equal(9, sql_comment.length)
	assert_strings_equal(c"-- hidden", sql_comment.text)


void test_generated_parser_syntax_error():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = sample_parse(c"", c"sample.txt", diagnostics)
	assert_equal(0, cast(int, root))
	assert_equal(1, pg_diagnostics_count(diagnostics))
	pg_diagnostic* diagnostic = pg_diagnostics_get(diagnostics, 0)
	assert_strings_equal(c"syntax error", diagnostic.message)
	assert_strings_equal(c"list", diagnostic.expected)


void test_generated_parser_lexer_error():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = sample_parse(c"alpha !", c"sample.txt", diagnostics)
	assert1(root != 0)
	assert_equal(1, pg_diagnostics_count(diagnostics))
	pg_diagnostic* diagnostic = pg_diagnostics_get(diagnostics, 0)
	assert_strings_equal(c"invalid character", diagnostic.message)


void test_token_offsets_and_channels():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = sample_lex(c"alpha  123", c"sample.txt", diagnostics)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	# Parser-facing stream: WORD NUMBER EOF
	pg_token* word = pg_token_stream_la(stream, 1)
	assert_equal(0, word.offset)
	assert_equal(5, word.length)
	assert_equal(pg_token_default_channel(), word.channel)
	pg_token* number = pg_token_stream_la(stream, 2)
	assert_equal(7, number.offset)
	assert_equal(3, number.length)
	pg_token* eof = pg_token_stream_la(stream, 3)
	assert_equal(pg_token_eof_kind(), eof.kind)
	assert_equal(10, eof.offset)
	# All-channel stream keeps the whitespace run between the two tokens
	assert_equal(4, pg_token_stream_all_count(stream))
	pg_token* space = pg_token_stream_all_get(stream, 1)
	assert_equal(pg_token_whitespace_kind(), space.kind)
	assert_equal(pg_token_hidden_channel(), space.channel)
	assert_equal(5, space.offset)
	assert_equal(2, space.length)
	assert_strings_equal(c"  ", space.text)


void test_lossless_token_stream_round_trip():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = sample_lex(c"alpha  123 , ! beta", c"sample.txt", diagnostics)
	char* rebuilt = pg_token_stream_source(stream)
	assert_strings_equal(c"alpha  123 , ! beta", rebuilt)


void test_ast_node_spans():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = sample_parse(c"alpha 123", c"sample.txt", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	# Root spans the whole input including the EOF terminal
	assert_equal(0, pg_ast_first_token(root).offset)
	assert_equal(pg_token_eof_kind(), pg_ast_last_token(root).kind)
	# First value spans just "alpha"
	pg_ast_node* first_value = pg_ast_child(root, 0)
	assert_equal(0, pg_ast_first_token(first_value).offset)
	assert_equal(5, pg_ast_first_token(first_value).length)
	# Second value spans just "123"
	pg_ast_node* second_value = pg_ast_child(root, 1)
	assert_equal(6, pg_ast_first_token(second_value).offset)
	assert_equal(3, pg_ast_last_token(second_value).length)


void test_error_recovery_multi_parse():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = sample_parse(c"alpha , beta", c"sample.txt", diagnostics)
	assert1(root != 0)
	assert_equal(1, pg_diagnostics_count(diagnostics))
	pg_diagnostic* diagnostic = pg_diagnostics_get(diagnostics, 0)
	assert_strings_equal(c"syntax error", diagnostic.message)
	assert_strings_equal(c"value", diagnostic.expected)
	assert_strings_equal(c",", diagnostic.found)
	# value(alpha), error(,), value(beta), EOF
	assert_equal(4, pg_ast_child_count(root))
	assert_equal(sample_ast_value(), pg_ast_child(root, 0).kind)
	pg_ast_node* error_node = pg_ast_child(root, 1)
	assert_equal(pg_ast_error_kind(), error_node.kind)
	assert_equal(1, pg_ast_child_count(error_node))
	assert_strings_equal(c",", pg_ast_child(error_node, 0).text)
	assert_equal(sample_ast_value(), pg_ast_child(root, 2).kind)
	assert_strings_equal(c"beta", pg_ast_child(pg_ast_child(root, 2), 0).text)


void test_visitor_preorder_on_generated_ast():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = sample_parse(c"alpha 123", c"sample.txt", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	traversal_reset()
	pg_ast_walk_preorder(root, traversal_visit)
	assert_equal(6, traversal_count)
	assert_equal(sample_ast_list(), traversal_get(0))
	assert_equal(sample_ast_value(), traversal_get(1))
	assert_equal(sample_token_WORD(), traversal_get(2))
	assert_equal(sample_ast_value(), traversal_get(3))
	assert_equal(sample_token_NUMBER(), traversal_get(4))
	assert_equal(sample_token_EOF(), traversal_get(5))


void test_listener_enter_leave_order_on_generated_ast():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = sample_parse(c"alpha", c"sample.txt", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	traversal_reset()
	pg_ast_walk_listener(root, traversal_enter, traversal_leave)
	assert_equal(8, traversal_count)
	assert_equal(sample_ast_list(), traversal_get(0))
	assert_equal(sample_ast_value(), traversal_get(1))
	assert_equal(sample_token_WORD(), traversal_get(2))
	assert_equal(0 - sample_token_WORD(), traversal_get(3))
	assert_equal(0 - sample_ast_value(), traversal_get(4))
	assert_equal(sample_token_EOF(), traversal_get(5))
	assert_equal(0 - sample_token_EOF(), traversal_get(6))
	assert_equal(0 - sample_ast_list(), traversal_get(7))


void test_listener_sets_parent_links_for_children():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = sample_parse(c"alpha 123", c"sample.txt", diagnostics)
	assert1(root != 0)
	pg_ast_node* first_value = pg_ast_child(root, 0)
	pg_ast_node* first_token = pg_ast_child(first_value, 0)
	assert_equal(cast(int, root), cast(int, first_value.parent))
	assert_equal(cast(int, first_value), cast(int, first_token.parent))


void test_manual_ast_traversal_and_null_noop():
	pg_ast_node* root = pg_ast_new(10, 0, c"root")
	pg_ast_node* left = pg_ast_new(20, 0, c"left")
	pg_ast_node* right = pg_ast_new(30, 0, c"right")
	pg_ast_node* leaf = pg_ast_new(40, 0, c"leaf")
	pg_ast_add(root, left)
	pg_ast_add(root, right)
	pg_ast_add(right, leaf)
	traversal_reset()
	pg_ast_walk_preorder(0, traversal_visit)
	pg_ast_walk_listener(0, traversal_enter, traversal_leave)
	assert_equal(0, traversal_count)
	pg_ast_walk_preorder(root, traversal_visit)
	assert_equal(4, traversal_count)
	assert_equal(10, traversal_get(0))
	assert_equal(20, traversal_get(1))
	assert_equal(30, traversal_get(2))
	assert_equal(40, traversal_get(3))
	traversal_reset()
	pg_ast_walk_listener(root, traversal_enter, traversal_leave)
	assert_equal(8, traversal_count)
	assert_equal(10, traversal_get(0))
	assert_equal(20, traversal_get(1))
	assert_equal(-20, traversal_get(2))
	assert_equal(30, traversal_get(3))
	assert_equal(40, traversal_get(4))
	assert_equal(-40, traversal_get(5))
	assert_equal(-30, traversal_get(6))
	assert_equal(-10, traversal_get(7))
