# wbuild: name=parser_generator_stateful_lexer_test
# wbuild: target=parser_generator_stateful_lexer_test tag=tests dep=parser_generator_test
# wbuild: step="bin/parser_generator tests/parser_generator/stateful_sample.pg -o bin/generated_stateful_parser.w"
# wbuild: step="bin/parser_generator tests/parser_generator/stateful_legacy.pg -o bin/generated_stateful_legacy.w"
# wbuild: step="bin/parser_generator tests/parser_generator/ast_predicate.pg -o bin/generated_ast_predicate.w"
# wbuild: step="bin/wv2 tests/parser_generator/generated_stateful_test.w -o bin/parser_generator_stateful_lexer_test"
# wbuild: step="bin/parser_generator_stateful_lexer_test"
import lib.testing
import libs.extras.parser_generator.grammar_reader
import libs.extras.parser_generator.generator
import bin.generated_stateful_parser
import bin.generated_stateful_legacy
import bin.generated_ast_predicate


void test_generated_stateful_goal_rollback():
	char* input = c" /x/  "
	pg_parse_result* result = stateful_sample_parse_owned(input, strlen(input), c"goal.js")
	assert_equal(1, result.success)
	assert_equal(0, pg_diagnostics_count(result.diagnostics))
	assert_equal(stateful_sample_token_SLASH, result.stream.tokens[0].kind)
	assert_equal(0, result.stream.provider.goal)
	assert1(result.stream.rollback_count > 0)
	char* reconstructed = pg_token_stream_source(result.stream)
	assert_strings_equal(input, reconstructed)
	free(reconstructed)
	pg_parse_result_free(result)


void test_generated_nested_template_modes():
	char* input = c"`a${`b${x}`}c`"
	pg_parse_result* result = stateful_sample_parse_owned(input, strlen(input), c"template.js")
	assert_equal(1, result.success)
	assert_equal(0, result.stream.provider.mode)
	assert_equal(0, result.stream.provider.modes.length)
	assert_equal(stateful_sample_token_OPEN, result.stream.tokens[result.stream.tokens.length - 2].kind)
	char* reconstructed = pg_token_stream_source(result.stream)
	assert_strings_equal(input, reconstructed)
	free(reconstructed)
	pg_parse_result_free(result)


void test_generated_priority_and_selected_actions():
	pg_parse_result* ordered = stateful_sample_parse_owned(c"if", 2, c"priority.js")
	assert_equal(1, ordered.success)
	assert_equal(stateful_sample_token_IDENT, ordered.stream.tokens[0].kind)
	assert_equal(0, ordered.stream.provider.context.length)
	pg_parse_result_free(ordered)
	pg_parse_result* legacy = stateful_legacy_parse_owned(c"if", 2, c"priority.js")
	assert_equal(1, legacy.success)
	assert_equal(stateful_legacy_token_KEYWORD, legacy.stream.tokens[0].kind)
	pg_parse_result_free(legacy)


void test_generated_rejections():
	char* unterminated = c"`a${x"
	pg_parse_result* result = stateful_sample_parse_owned(unterminated, strlen(unterminated), c"broken.js")
	assert_equal(0, result.success)
	assert1(pg_diagnostics_count(result.diagnostics) > 0)
	pg_parse_result_free(result)
	result = stateful_sample_parse_owned(c"bad", 3, c"predicate.js")
	assert_equal(0, result.success)
	pg_parse_result_free(result)
	result = stateful_sample_parse_owned(c"}", 1, c"underflow.js")
	assert_equal(0, result.success)
	pg_parse_result_free(result)
	result = stateful_sample_parse_owned(c"ok more", 7, c"trailing.js")
	assert_equal(0, result.success)
	pg_parse_result_free(result)
	char* nul = cast(char*, malloc(3))
	nul[0] = 'x'
	nul[1] = 0
	nul[2] = 'x'
	result = stateful_sample_parse_owned(nul, 3, c"nul.js")
	assert_equal(0, result.success)
	assert_equal(3, result.length)
	pg_parse_result_free(result)
	free(nul)


void test_ast_mid_predicates_optional_repeat_shared_prefix():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = ast_predicate_lex(c"good yes yes", c"ast.txt", diagnostics)
	pg_token_stream_own_ast(stream)
	pg_ast_node* root = ast_predicate_parse_program(stream, diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(3, root.children.length)
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)
	diagnostics = pg_diagnostics_new()
	stream = ast_predicate_lex(c"bad yes", c"ast.txt", diagnostics)
	pg_token_stream_own_ast(stream)
	assert1(ast_predicate_parse_program(stream, diagnostics) == 0)
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)


int stateful_generation_rejected(char* source):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_grammar* grammar = pg_grammar_read(source, c"reject.pg", diagnostics)
	int rejected = grammar == 0
	if (grammar != 0):
		char* generated = pg_generate_parser(grammar)
		rejected = generated == 0
		if (generated != 0): free(generated)
		pg_grammar_free(grammar)
	pg_diagnostics_free(diagnostics)
	return rejected


void test_grammar_safety_diagnostics():
	assert1(stateful_generation_rejected(c"parser bad\ntoken ID letters\nrule root = empty? root ID | ID\nrule empty =\n"))
	assert1(stateful_generation_rejected(c"parser bad\ntoken ID letters\nrule root = second ID | ID\nrule second = root |\n"))
	assert1(stateful_generation_rejected(c"parser bad\ntoken ID letters\nrule root = empty* EOF\nrule empty = ID?\n"))
	assert1(stateful_generation_rejected(c"parser bad\nlexer stateful\nliteral X \"x\"\nlexer_command X more\nrule root = X EOF\n"))
	assert1(stateful_generation_rejected(c"parser bad\nlexer stateful\nliteral X \"x\"\nlexer_rule X UNDECLARED\nrule root = X EOF\n"))
	assert1(stateful_generation_rejected(c"parser bad\nlexer stateful\nliteral X \"x\"\nlexer_command X type UNKNOWN\nrule root = X EOF\n"))
	assert1(stateful_generation_rejected(c"parser bad\nliteral X \"x\"\ngoal root 1\nrule root = X EOF\n"))
	assert1(stateful_generation_rejected(c"parser bad\nliteral X \"x\"\nrule root = X { state_change() } EOF\n"))


void test_lexer_command_validation_and_progress():
	assert1(stateful_generation_rejected(c"parser bad\nlexer stateful\nliteral X \"x\"\ngoal root 1\ngoal root 2\nrule root = X EOF\n"))
	assert1(stateful_generation_rejected(c"parser bad\nliteral X \"x\"\nrule root = end*\nrule end = EOF\n"))
	assert1(stateful_generation_rejected(c"parser bad\nliteral X \"x\"\nrule root = EOF root | X\n"))
	assert1(stateful_generation_rejected(c"parser bad\nlexer stateful\nliteral X \"x\"\nlexer_command X channel missing\nrule root = X EOF\n"))
	assert1(stateful_generation_rejected(c"parser bad\nlexer stateful\nliteral X \"x\"\nlexer_command X pushMode missing\nrule root = X EOF\n"))
	assert1(stateful_generation_rejected(c"parser bad\nlexer stateful\nliteral X \"x\"\nlexer_command X channel hidden\nlexer_command X skip\nrule root = X EOF\n"))
	assert1(stateful_generation_rejected(c"parser bad\nlexer stateful\nliteral X \"x\"\nlexer_command X type X\nlexer_command X type X\nrule root = X EOF\n"))
	assert1(stateful_generation_rejected(c"parser bad\nlexer stateful\ntoken X = [x]*\nrule root = X EOF\n"))
	assert1(stateful_generation_rejected(c"parser bad\nlexer stateful\nliteral X \"\"\nrule root = X EOF\n"))
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = stateful_sample_lex(c"}", c"underflow.js", diagnostics)
	assert1(pg_diagnostics_count(diagnostics) > 0)
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)


void test_generated_ast_budget_unwinds_checkpoints():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_lexer_state* state = stateful_sample_provider_new(c"/x/", 3, c"budget.js")
	pg_token_stream* stream = pg_token_stream_from_provider(state, stateful_sample_next, diagnostics)
	pg_parse_result* result = pg_parse_result_new(stream, diagnostics)
	stream.ast_limit = 1
	result.root = stateful_sample_parse_program(stream, diagnostics)
	assert1(result.root == 0)
	assert_equal(1, stream.resource_failed)
	assert_equal(0, stream.checkpoint_count)
	assert_equal(0, stream.provider.goal)
	pg_token_stream_report_resource(stream)
	assert1(pg_diagnostics_count(diagnostics) > 0)
	pg_parse_result_free(result)
