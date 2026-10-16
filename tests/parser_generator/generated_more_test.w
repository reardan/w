# wbuild: name=parser_generator_more_test
# wbuild: target=parser_generator_more_test tag=tests dep=grammars_parser_generator
# wbuild: step="bin/parser_generator_grammars tests/parser_generator/stateful_more.pg -o bin/generated_more_parser.w"
# wbuild: step="bin/parser_generator_grammars tests/parser_generator/stateful_more_eof.pg -o bin/generated_more_eof_parser.w"
# wbuild: step="bin/wv2 tests/parser_generator/generated_more_test.w -o bin/parser_generator_more_test"
# wbuild: step="bin/parser_generator_more_test"
import lib.testing
import libs.extras.parser_generator.grammar_reader
import libs.extras.parser_generator.generator
import bin.generated_more_parser
import bin.generated_more_eof_parser


void test_more_remap_spans_and_replay():
	char* input = c"[a\r\nb]"
	pg_parse_result* result = stateful_more_parse_owned(input, strlen(input), c"more.txt")
	assert_equal(1, result.success)
	assert_equal(0, pg_diagnostics_count(result.diagnostics))
	assert1(result.stream.rollback_count > 0)
	pg_token* token = result.stream.tokens[0]
	assert_equal(stateful_more_token_TEXT, token.kind)
	assert_strings_equal(input, token.text)
	assert_equal(0, token.offset)
	assert_equal(strlen(input), token.length)
	assert_equal(1, token.line)
	assert_equal(1, token.column)
	assert_equal(0, result.stream.provider.mode)
	assert_equal(0, result.stream.provider.modes.length)
	assert_equal(2, result.stream.provider.line)
	assert_equal(3, result.stream.provider.column)
	char* reconstructed = pg_token_stream_source(result.stream)
	assert_strings_equal(input, reconstructed)
	free(reconstructed)
	pg_parse_result_free(result)


void test_more_hidden_and_skip_preserve_source():
	char* input = c"^123 [abc; 456"
	pg_parse_result* result = stateful_more_parse_owned(input, strlen(input), c"hidden.txt")
	assert_equal(1, result.success)
	assert_equal(stateful_more_token_NUMBER, result.stream.tokens[0].kind)
	assert_strings_equal(c"456", result.stream.tokens[0].text)
	assert_strings_equal(c"^123", result.stream.all_tokens[0].text)
	assert_equal(pg_token_hidden_channel, result.stream.all_tokens[0].channel)
	assert_strings_equal(c"[abc;", result.stream.all_tokens[2].text)
	assert_equal(pg_token_hidden_channel, result.stream.all_tokens[2].channel)
	char* reconstructed = pg_token_stream_source(result.stream)
	assert_strings_equal(input, reconstructed)
	free(reconstructed)
	pg_parse_result_free(result)


void test_more_eof_and_invalid_input_progress():
	list[char*] inputs = list[char*]{c"[abc", c"[ab?]", c"^", c"[]x"}
	for char* input in inputs:
		pg_diagnostics* diagnostics = pg_diagnostics_new()
		pg_token_stream* stream = stateful_more_lex(input, c"bad.txt", diagnostics)
		assert1(pg_diagnostics_count(diagnostics) > 0)
		assert_equal(strlen(input), stream.provider.offset)
		char* reconstructed = pg_token_stream_source(stream)
		assert_strings_equal(input, reconstructed)
		free(reconstructed)
		pg_token_stream_free(stream)
		pg_diagnostics_free(diagnostics)


void test_more_checkpoint_restores_the_whole_token():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_lexer_state* state = stateful_more_provider_new(c"[abc]", 5, c"checkpoint.txt")
	pg_lexer_snapshot* saved = pg_lexer_save(state)
	pg_token* first = stateful_more_next(state, diagnostics)
	assert_equal(5, state.offset)
	pg_lexer_restore(state, saved)
	assert_equal(0, state.offset)
	assert_equal(0, state.mode)
	pg_token* second = stateful_more_next(state, diagnostics)
	assert_equal(first.kind, second.kind)
	assert_equal(first.length, second.length)
	assert_strings_equal(first.text, second.text)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	pg_token_free(first)
	pg_token_free(second)
	pg_lexer_snapshot_free(saved)
	pg_lexer_state_free(state)
	pg_diagnostics_free(diagnostics)


void test_more_explicit_eof_mode_policy():
	pg_parse_result* result = stateful_more_eof_parse_owned(c"[abc", 4, c"eof.txt")
	assert_equal(1, result.success)
	assert_equal(0, pg_diagnostics_count(result.diagnostics))
	assert_equal(1, result.stream.provider.mode)
	assert_strings_equal(c"[abc", result.stream.tokens[0].text)
	pg_parse_result_free(result)
	# A completed token may leave its mode active; an unfinished more
	# sequence must still diagnose EOF and retain every consumed byte.
	result = stateful_more_eof_parse_owned(c"[", 1, c"eof.txt")
	assert_equal(0, result.success)
	assert1(pg_diagnostics_count(result.diagnostics) > 0)
	pg_parse_result_free(result)


int more_generation_rejected(char* source):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_grammar* grammar = pg_grammar_read(source, c"reject-more.pg", diagnostics)
	int rejected = grammar == 0
	if (grammar != 0):
		char* generated = pg_generate_parser(grammar)
		rejected = generated == 0
		if (generated != 0): free(generated)
		pg_grammar_free(grammar)
	pg_diagnostics_free(diagnostics)
	return rejected


void test_more_and_symbolic_token_validation():
	assert1(more_generation_rejected(c"parser duplicate\nlexer stateful\ntoken X\ntoken X digits\nrule root = X EOF\n"))
	assert1(more_generation_rejected(c"parser duplicate\nlexer stateful\ntoken X\nliteral X \"x\"\nrule root = X EOF\n"))
	assert1(more_generation_rejected(c"parser duplicate\nlexer stateful\ntoken X\nskip X spaces\nrule root = X EOF\n"))
	assert1(more_generation_rejected(c"parser bad\nlexer stateful\nlexer_eof unknown\nliteral X \"x\"\nrule root = X EOF\n"))
	assert1(more_generation_rejected(c"parser bad\nlexer_eof any_mode\nliteral X \"x\"\nrule root = X EOF\n"))
	assert1(more_generation_rejected(c"parser bad\nlexer stateful\nliteral X \"x\"\nlexer_command X more\nlexer_command X skip\nrule root = X EOF\n"))
	assert1(more_generation_rejected(c"parser bad\nlexer stateful\nliteral X \"x\"\nlexer_command X more\nlexer_command X type X\nrule root = X EOF\n"))
	assert1(more_generation_rejected(c"parser bad\nlexer stateful\nliteral X \"x\"\nlexer_command X more\nlexer_command X more\nrule root = X EOF\n"))
	assert1(more_generation_rejected(c"parser bad\ntoken X\nrule root = X EOF\n"))
	assert1(more_generation_rejected(c"parser bad\nlexer stateful\ntoken X\ntoken Y = X\nrule root = Y EOF\n"))
	assert1(more_generation_rejected(c"parser bad\nlexer stateful\ntoken X\nlexer_command X more\nrule root = X EOF\n"))
