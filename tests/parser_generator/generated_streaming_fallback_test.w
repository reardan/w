/*
Streaming-mode nullable fallback (docs/projects/ai_tooling_next_steps.md,
ParserGenerator streaming codegen): a nullable, non-empty factored suffix
whose later siblings are all strict epsilons is compiled as the choice's
final fallback branch instead of being rejected -- the epsilons are dead
under ordered choice, since the nullable suffix always matches first
(pg_choice_unit_is_nullable_fallback in analysis.w, live-unit trim in
generator.w's pg_emit_streaming_choice). streaming_fallback_sample.pg
holds the two accepted shapes: `value = IDENT WS? | IDENT` (the minimal
form -- the WS? suffix becomes the whole choice body) and
`pair = IDENT NUMBER | IDENT WS? | IDENT` (mid-alternatives -- a guarded
sibling before, a dead epsilon after). The tests below drive both rules
over real input through every path: optional token present, optional
token absent (the behavior the dead epsilon would have duplicated), and
the guarded sibling still winning on its own first set.
*/
import lib.testing
import libs.extras.parser_generator.runtime
import libs.extras.parser_generator.grammar_reader
import libs.extras.parser_generator.generator
import bin.generated_streaming_fallback_parser


int enter_document
int exit_document
int enter_statement_list
int exit_statement_list
int enter_statement
int exit_statement
int enter_value
int exit_value
int enter_pair
int exit_pair

int token_total_count
int token_ident_count
int token_number_count
int token_ws_count
int token_semi_count
int token_comma_count


void reset_counts():
	enter_document = 0
	exit_document = 0
	enter_statement_list = 0
	exit_statement_list = 0
	enter_statement = 0
	exit_statement = 0
	enter_value = 0
	exit_value = 0
	enter_pair = 0
	exit_pair = 0
	token_total_count = 0
	token_ident_count = 0
	token_number_count = 0
	token_ws_count = 0
	token_semi_count = 0
	token_comma_count = 0


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


void on_enter_value(pg_token_stream* stream, void* context):
	enter_value = enter_value + 1


void on_exit_value(pg_token_stream* stream, void* context):
	exit_value = exit_value + 1


void on_enter_pair(pg_token_stream* stream, void* context):
	enter_pair = enter_pair + 1


void on_exit_pair(pg_token_stream* stream, void* context):
	exit_pair = exit_pair + 1


void on_token_event(pg_token* token, void* context):
	token_total_count = token_total_count + 1
	if (token.kind == streaming_fallback_token_IDENT()):
		token_ident_count = token_ident_count + 1
	else if (token.kind == streaming_fallback_token_NUMBER()):
		token_number_count = token_number_count + 1
	else if (token.kind == streaming_fallback_token_WS()):
		token_ws_count = token_ws_count + 1
	else if (token.kind == streaming_fallback_token_SEMI()):
		token_semi_count = token_semi_count + 1
	else if (token.kind == streaming_fallback_token_COMMA()):
		token_comma_count = token_comma_count + 1


streaming_fallback_listener* make_listener():
	streaming_fallback_listener* listener = streaming_fallback_listener_new()
	listener.on_enter_document = on_enter_document
	listener.on_exit_document = on_exit_document
	listener.on_enter_statement_list = on_enter_statement_list
	listener.on_exit_statement_list = on_exit_statement_list
	listener.on_enter_statement = on_enter_statement
	listener.on_exit_statement = on_exit_statement
	listener.on_enter_value = on_enter_value
	listener.on_exit_value = on_exit_value
	listener.on_enter_pair = on_enter_pair
	listener.on_exit_pair = on_exit_pair
	listener.on_token = on_token_event
	return listener


# Five statements, one per dispatch path (there is no skip rule, so every
# space is a real WS token):
#   ;foo_   value's WS? fallback consumes the trailing WS
#   ;bar    value's WS? fallback matches empty (next token is COMMA) --
#           the observable the dead trailing epsilon would have duplicated
#   ,baz7   pair's guarded NUMBER suffix wins on its own first set
#   ,qux_   pair's WS? fallback consumes the WS
#   ,mix    pair's WS? fallback matches empty at EOF; the dead third
#           alternative (bare IDENT) is dropped, not dispatched
void test_streaming_nullable_fallback_paths():
	reset_counts()
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	streaming_fallback_listener* listener = make_listener()
	char* input = c";foo ;bar,baz7,qux ,mix"
	int ok = streaming_fallback_parse_streaming(input, c"streaming_fallback.txt", diagnostics, listener)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert1(ok != 0)

	assert_equal(1, enter_document)
	assert_equal(1, exit_document)
	# One statement_list activation per statement (5), plus the trailing
	# empty-alternative activation that ends the recursion.
	assert_equal(6, enter_statement_list)
	assert_equal(6, exit_statement_list)
	assert_equal(5, enter_statement)
	assert_equal(5, exit_statement)
	assert_equal(2, enter_value)
	assert_equal(2, exit_value)
	assert_equal(3, enter_pair)
	assert_equal(3, exit_pair)

	assert_equal(5, token_ident_count)
	assert_equal(1, token_number_count)
	assert_equal(2, token_ws_count)
	assert_equal(2, token_semi_count)
	assert_equal(3, token_comma_count)
	# 13 counted tokens above plus the EOF term document = statement_list
	# EOF matches via the same <name>_match_token/on_token path.
	assert_equal(14, token_total_count)


# The doc entry's literal minimal example generates now: the WS? suffix
# unit is trailing-fallback-equivalent (its only later sibling is the
# dead strict epsilon), so pg_streaming_check accepts the grammar and
# pg_generate_parser emits it. The sibling shape that must stay rejected
# is pinned by generated_streaming_test.w's
# test_streaming_mode_rejects_nullable_suffix_with_live_sibling and by
# streaming_guard_reject.pg.
void test_streaming_mode_accepts_nullable_nonempty_factored_suffix():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	char* source = c"parser edge_probe\nmode streaming\ntoken IDENT letters\ntoken WS = [ \t]+\nstart value\nrule value = IDENT WS? | IDENT\n"
	pg_grammar* grammar = pg_grammar_read(source, c"edge_probe.pg", diagnostics)
	assert1(grammar != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	char* generated = pg_generate_parser(grammar)
	assert1(generated != 0)
