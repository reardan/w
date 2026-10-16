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
	assert_equal(3, result.stream.tokens.length)
	assert_equal(guarded_progress_token_END, result.stream.tokens[1].kind)
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
	pg_lexer_state* state = guarded_progress_provider_new(c"a", 1, c"replay")
	pg_token* token = guarded_progress_next(state, diagnostics)
	pg_token_free(token)
	token = guarded_progress_next(state, diagnostics)
	pg_token_free(token)
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
