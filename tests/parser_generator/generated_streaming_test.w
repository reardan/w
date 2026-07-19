/*
Streaming mode (issue #329 milestone 3): the generated parser fires
listener callbacks -- enter/exit per rule, one token event -- instead of
building a pg_ast_node tree. tests/parser_generator/streaming_sample.pg
is fully LL(1)-committed (pg_streaming_check finds no violations), so it
generates; a grammar that is not committed must be rejected instead (see
test_streaming_mode_rejects_rule_referenced_repeat below).
*/
import lib.testing
import libs.extras.parser_generator.runtime
import libs.extras.parser_generator.grammar_reader
import libs.extras.parser_generator.generator
import bin.generated_streaming_parser


int enter_document
int exit_document
int enter_statement_list
int exit_statement_list
int enter_statement
int exit_statement
int enter_assignment
int exit_assignment
int enter_value
int exit_value
int enter_block
int exit_block
int enter_numbers
int exit_numbers

int token_total_count
int token_ident_count
int token_number_count
int token_equals_count
int token_semi_count
int token_minus_count
int token_lbrace_count
int token_rbrace_count


void reset_counts():
	enter_document = 0
	exit_document = 0
	enter_statement_list = 0
	exit_statement_list = 0
	enter_statement = 0
	exit_statement = 0
	enter_assignment = 0
	exit_assignment = 0
	enter_value = 0
	exit_value = 0
	enter_block = 0
	exit_block = 0
	enter_numbers = 0
	exit_numbers = 0
	token_total_count = 0
	token_ident_count = 0
	token_number_count = 0
	token_equals_count = 0
	token_semi_count = 0
	token_minus_count = 0
	token_lbrace_count = 0
	token_rbrace_count = 0


void on_enter_document(pg_token_stream* stream, void* context):
	enter_document = enter_document + 1


void on_exit_document(pg_token_stream* stream, void* context):
	exit_document = exit_document + 1


void on_enter_statement_list(pg_token_stream* stream, void* context):
	enter_statement_list = enter_statement_list + 1


void on_exit_statement_list(pg_token_stream* stream, void* context):
	exit_statement_list = exit_statement_list + 1


void on_enter_statement(pg_token_stream* stream, void* context):
	enter_statement = enter_statement + 1


void on_exit_statement(pg_token_stream* stream, void* context):
	exit_statement = exit_statement + 1


void on_enter_assignment(pg_token_stream* stream, void* context):
	enter_assignment = enter_assignment + 1


void on_exit_assignment(pg_token_stream* stream, void* context):
	exit_assignment = exit_assignment + 1


void on_enter_value(pg_token_stream* stream, void* context):
	enter_value = enter_value + 1


void on_exit_value(pg_token_stream* stream, void* context):
	exit_value = exit_value + 1


void on_enter_block(pg_token_stream* stream, void* context):
	enter_block = enter_block + 1


void on_exit_block(pg_token_stream* stream, void* context):
	exit_block = exit_block + 1


void on_enter_numbers(pg_token_stream* stream, void* context):
	enter_numbers = enter_numbers + 1


void on_exit_numbers(pg_token_stream* stream, void* context):
	exit_numbers = exit_numbers + 1


void on_token_event(pg_token* token, void* context):
	token_total_count = token_total_count + 1
	if (token.kind == streaming_sample_token_IDENT()):
		token_ident_count = token_ident_count + 1
	else if (token.kind == streaming_sample_token_NUMBER()):
		token_number_count = token_number_count + 1
	else if (token.kind == streaming_sample_token_EQUALS()):
		token_equals_count = token_equals_count + 1
	else if (token.kind == streaming_sample_token_SEMI()):
		token_semi_count = token_semi_count + 1
	else if (token.kind == streaming_sample_token_MINUS()):
		token_minus_count = token_minus_count + 1
	else if (token.kind == streaming_sample_token_LBRACE()):
		token_lbrace_count = token_lbrace_count + 1
	else if (token.kind == streaming_sample_token_RBRACE()):
		token_rbrace_count = token_rbrace_count + 1


streaming_sample_listener* make_listener():
	streaming_sample_listener* listener = streaming_sample_listener_new()
	listener.on_enter_document = on_enter_document
	listener.on_exit_document = on_exit_document
	listener.on_enter_statement_list = on_enter_statement_list
	listener.on_exit_statement_list = on_exit_statement_list
	listener.on_enter_statement = on_enter_statement
	listener.on_exit_statement = on_exit_statement
	listener.on_enter_assignment = on_enter_assignment
	listener.on_exit_assignment = on_exit_assignment
	listener.on_enter_value = on_enter_value
	listener.on_exit_value = on_exit_value
	listener.on_enter_block = on_enter_block
	listener.on_exit_block = on_exit_block
	listener.on_enter_numbers = on_enter_numbers
	listener.on_exit_numbers = on_exit_numbers
	listener.on_token = on_token_event
	return listener


# Four statements -- three assignments (one with a doubled unary minus,
# one a block of two bare numbers, one an identifier value) -- drive the
# recursive statement_list/statement dispatch, the MINUS* and NUMBER+
# repeats, and the value rule's two-alternative committed dispatch, all
# over real (if small) input.
void test_streaming_parser_fires_listener_callbacks():
	reset_counts()
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	streaming_sample_listener* listener = make_listener()
	char* input = c"x = 1;\ny = --2;\n{\n\t3\n\t4\n}\nz = foo;\n"
	int ok = streaming_sample_parse_streaming(input, c"streaming_sample.txt", diagnostics, listener)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert1(ok != 0)

	assert_equal(1, enter_document)
	assert_equal(1, exit_document)
	# One statement_list activation per statement (4), plus the trailing
	# empty-alternative activation that ends the recursion.
	assert_equal(5, enter_statement_list)
	assert_equal(5, exit_statement_list)
	assert_equal(4, enter_statement)
	assert_equal(4, exit_statement)
	assert_equal(3, enter_assignment)
	assert_equal(3, exit_assignment)
	assert_equal(3, enter_value)
	assert_equal(3, exit_value)
	assert_equal(1, enter_block)
	assert_equal(1, exit_block)
	assert_equal(1, enter_numbers)
	assert_equal(1, exit_numbers)

	assert_equal(4, token_ident_count)
	assert_equal(4, token_number_count)
	assert_equal(3, token_equals_count)
	assert_equal(3, token_semi_count)
	assert_equal(2, token_minus_count)
	assert_equal(1, token_lbrace_count)
	assert_equal(1, token_rbrace_count)
	# 18 counted tokens above plus the EOF term document = statement_list
	# EOF matches via the same <name>_match_token/on_token path.
	assert_equal(19, token_total_count)


# A committed-dispatch parse never backtracks, so a mandatory term that
# fails is an immediate, precise syntax error: entered but never exited.
void test_streaming_parser_reports_syntax_error():
	reset_counts()
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	streaming_sample_listener* listener = make_listener()
	char* input = c"x = 1\n"
	int ok = streaming_sample_parse_streaming(input, c"streaming_sample.txt", diagnostics, listener)
	assert_equal(0, ok)
	assert1(pg_diagnostics_count(diagnostics) > 0)
	assert_equal(1, enter_assignment)
	assert_equal(0, exit_assignment)
	assert_equal(0, exit_document)


# A grammar with a repeated *rule reference* (`item*`) is exactly the
# backtracking shape streaming mode excludes -- see pg_streaming_check in
# analysis.w -- so generation must fail (return 0) instead of silently
# emitting an unsound parser.
void test_streaming_mode_rejects_rule_referenced_repeat():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	char* source = c"parser bad_stream\nmode streaming\ntoken IDENT letters\nstart value\nrule item = IDENT\nrule value = item*\n"
	pg_grammar* grammar = pg_grammar_read(source, c"bad_stream.pg", diagnostics)
	assert1(grammar != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	char* generated = pg_generate_parser(grammar)
	assert1(generated == 0)
