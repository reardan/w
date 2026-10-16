# wbuild: name=parser_generator_guarded_progress_test
# wbuild: target=parser_generator_guarded_progress_test tag=tests dep=parser_generator_test
# wbuild: step="bin/parser_generator tests/parser_generator/guarded_progress.pg -o bin/generated_guarded_progress.w"
# wbuild: step="bin/wv2 --strict tests/parser_generator/guarded_progress_test.w -o bin/parser_generator_guarded_progress_test"
# wbuild: step="bin/parser_generator_guarded_progress_test"
import lib.testing
import bin.generated_guarded_progress

void test_guarded_mode_and_named_eof():
	pg_parse_result* result = guarded_progress_parse_owned(c"a", 1, c"test")
	pg_diagnostics_print(result.diagnostics)
	assert_equal(1, result.success)
	assert_equal(0, pg_diagnostics_count(result.diagnostics))
	assert_equal(2, result.stream.tokens.length)
	assert_equal(pg_token_eof_kind, result.stream.tokens[1].kind)
	assert_equal(0, result.stream.tokens[1].length)
	assert_equal(1, result.stream.tokens[1].offset)
	pg_parse_result_free(result)

void test_guarded_matcher_failures_are_errors():
	pg_parse_result* result = guarded_progress_parse_owned(c"x", 1, c"limit")
	assert_equal(0, result.success)
	assert1(pg_diagnostics_count(result.diagnostics) > 0)
	pg_parse_result_free(result)
	result = guarded_progress_parse_owned(c"y", 1, c"utf8")
	assert_equal(0, result.success)
	assert1(pg_diagnostics_count(result.diagnostics) > 0)
	pg_parse_result_free(result)

void test_guarded_eof_snapshot_replays():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_lexer_state* state = guarded_progress_provider_new(c"", 0, c"replay")
	state.mode = guarded_progress_mode_NEXT
	pg_token* token = 0
	pg_lexer_snapshot* saved = pg_lexer_save(state)
	token = guarded_progress_next(state, diagnostics)
	assert_equal(guarded_progress_token_END, token.kind)
	pg_token_free(token)
	pg_lexer_restore(state, saved)
	token = guarded_progress_next(state, diagnostics)
	assert_equal(guarded_progress_token_END, token.kind)
	pg_token_free(token)
	token = guarded_progress_next(state, diagnostics)
	assert_equal(pg_token_eof_kind, token.kind)
	pg_token_free(token)
	pg_lexer_snapshot_free(saved)
	pg_lexer_state_free(state)
	pg_diagnostics_free(diagnostics)

void test_guarded_zero_width_cycle_is_bounded():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = guarded_progress_lex(c"z", c"cycle", diagnostics)
	assert1(pg_diagnostics_count(diagnostics) > 0)
	assert1(stream.allocation_count < 260)
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)

void test_guarded_literal_failed_prefix_and_scalar_boundaries():
	assert_equal(2, pg_lexer_literal_probe(c"ab!", 0, 3, c"ab"))
	assert_equal(-6, pg_lexer_literal_probe(c"ac!", 0, 3, c"ab"))
	assert_equal(-5, pg_lexer_literal_probe(c"a", 0, 1, c"ab"))
	assert_equal(-7, pg_lexer_literal_probe(c"a\xc3\xa9!", 0, 4, c"ab"))
	assert_equal(-3, pg_lexer_literal_probe(c"a\xc3!", 0, 3, c"ab"))

void test_guarded_failure_survives_rollback():
	for index in range(3):
		char* input = c"x"
		if (index == 1): input = c"y"
		if (index == 2): input = c"z"
		pg_diagnostics* diagnostics = pg_diagnostics_new()
		pg_lexer_state* state = guarded_progress_provider_new(input, 1, c"rollback")
		pg_token_stream* stream = pg_token_stream_from_provider(state, guarded_progress_next, diagnostics)
		pg_stream_checkpoint* checkpoint = pg_token_stream_checkpoint(stream)
		pg_token_stream_peek(stream)
		assert_equal(1, stream.resource_failed)
		int scans = stream.scan_count
		pg_token_stream_restore(stream, checkpoint)
		pg_token_stream_peek(stream)
		assert_equal(scans, stream.scan_count)
		assert_equal(1, pg_diagnostics_count(diagnostics))
		pg_token_stream_release(checkpoint)
		pg_token_stream_free(stream)
		pg_diagnostics_free(diagnostics)

void test_guarded_embedded_nul_is_an_explicit_failure():
	char* input = cast(char*, malloc(3))
	input[0] = 'a'
	input[1] = 0
	input[2] = 0
	pg_parse_result* result = guarded_progress_parse_owned(input, 2, c"nul")
	assert_equal(0, result.success)
	assert_equal(1, result.stream.resource_failed)
	assert1(pg_diagnostics_count(result.diagnostics) > 0)
	pg_parse_result_free(result)
	free(input)
