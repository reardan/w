# wbuild: expect_stdout="stateful_runtime_test: OK"
# wbuild: x64
import lib.assert
import libs.extras.parser_generator.runtime


struct runtime_host:
	int calls


void* runtime_save(void* host):
	runtime_host* saved = new runtime_host()
	runtime_host* source = cast(runtime_host*, host)
	saved.calls = source.calls
	return cast(void*, saved)


void runtime_restore(void* host, void* saved):
	runtime_host* target = cast(runtime_host*, host)
	runtime_host* source = cast(runtime_host*, saved)
	target.calls = source.calls


void runtime_host_free(void* host):
	free(host)


# Deliberately tiny context-sensitive scanner: /ab/ is one token under
# goal 1, four byte tokens under goal 0. @ mutates every checkpointed
# state component and emits a branch-local diagnostic.
pg_token* runtime_next(pg_lexer_state* state, pg_diagnostics* diagnostics):
	if (state.offset == state.length): return pg_token_eof(state.offset, state.filename, state.line, state.column)
	if (state.host != 0):
		runtime_host* host = cast(runtime_host*, state.host)
		host.calls = host.calls + 1
	int length = 1
	int ch = pg_lexer_at(state, 0)
	int kind = ch
	if (ch == '/' && state.goal == 1 && state.length - state.offset >= 4):
		length = 4
		kind = 500
	pg_token* token = pg_token_make(kind, state.input, state.offset, length, state.filename, state.line, state.column)
	if (ch == ' ' || ch == 10 || ch == 13 || ch >= 128): pg_token_hide(token)
	if (ch == '@'):
		pg_lexer_push_mode(state, 7)
		state.context.push(42)
		pg_diagnostics_add(diagnostics, state.filename, state.line, state.column, c"speculative diagnostic", c"", c"")
	pg_lexer_advance(state, length)
	return token


pg_token_stream* runtime_stream(char* source, pg_diagnostics* diagnostics):
	return pg_token_stream_from_provider(pg_lexer_state_new(source, strlen(source), c"runtime.js"), runtime_next, diagnostics)


void runtime_context_test():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = runtime_stream(c" /ab/\r\n @ z", diagnostics)
	runtime_host* host = new runtime_host()
	host.calls = 0
	stream.provider.host = cast(void*, host)
	stream.provider.host_save = runtime_save
	stream.provider.host_restore = runtime_restore
	stream.provider.host_snapshot_free = runtime_host_free
	stream.provider.host_free = runtime_host_free
	assert_equal('/', pg_token_stream_peek(stream).kind)
	pg_token* old = pg_token_stream_peek(stream)
	pg_ast_node* abandoned = pg_token_stream_ast_new(stream, 1, old, c"abandoned")
	pg_token_stream_set_goal(stream, 1)
	assert_equal(500, pg_token_stream_peek(stream).kind)
	assert_strings_equal(c"/", abandoned.token.text)
	assert_equal(2, host.calls)
	assert_equal(2, stream.all_tokens.length)
	pg_token_stream_consume(stream)
	pg_stream_checkpoint* outer = pg_token_stream_checkpoint(stream)
	assert_equal('@', pg_token_stream_peek(stream).kind)
	assert_equal(1, pg_token_stream_line_break_before(stream))
	assert_equal(7, stream.provider.mode)
	assert_equal(42, stream.provider.context[0])
	assert_equal(1, pg_diagnostics_count(diagnostics))
	pg_token_stream_consume(stream)
	pg_stream_checkpoint* inner = pg_token_stream_checkpoint(stream)
	assert_equal('z', pg_token_stream_consume(stream).kind)
	assert1(pg_token_stream_done(stream))
	pg_token_stream_restore(stream, inner)
	assert_equal('z', pg_token_stream_peek(stream).kind)
	pg_token_stream_release(inner)
	pg_token_stream_restore(stream, outer)
	assert_equal(0, stream.provider.mode)
	assert_equal(0, stream.provider.modes.length)
	assert_equal(0, stream.provider.context.length)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(2, host.calls)
	assert_equal(2, stream.all_tokens.length)
	assert_equal(1, pg_token_stream_goal(stream))
	# Restore is reusable; a failed sibling cannot poison another sibling.
	pg_token_stream_peek(stream)
	pg_token_stream_restore(stream, outer)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	pg_token_stream_release(outer)
	while (pg_token_stream_done(stream) == 0): pg_token_stream_consume(stream)
	int scans = stream.scan_count
	pg_token* eof = pg_token_stream_peek(stream)
	assert1(pg_token_stream_la(stream, 100) == eof)
	pg_token_stream_consume(stream)
	assert1(pg_token_stream_peek(stream) == eof)
	assert_equal(scans, stream.scan_count)
	char* rebuilt = pg_token_stream_source(stream)
	assert_strings_equal(c" /ab/\r\n @ z", rebuilt)
	free(rebuilt)
	assert_equal(2, eof.line)
	assert1(stream.rollback_count >= 3)
	assert1(pg_token_stream_furthest(stream).offset >= 9)
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)


void runtime_interleaved_test():
	pg_diagnostics* left_diag = pg_diagnostics_new()
	pg_diagnostics* right_diag = pg_diagnostics_new()
	pg_token_stream* left = runtime_stream(c"/ab/", left_diag)
	pg_token_stream* right = runtime_stream(c"/ab/", right_diag)
	pg_token_stream_set_goal(left, 1)
	assert_equal(500, pg_token_stream_consume(left).kind)
	assert_equal('/', pg_token_stream_consume(right).kind)
	pg_parse_result* result = pg_parse_result_new(left, left_diag)
	result.root = pg_token_stream_ast_new(left, 1, left.tokens[0], c"expression")
	result.success = pg_token_stream_done(left) && pg_diagnostics_count(left_diag) == 0
	assert1(result.success)
	assert_strings_equal(c"/ab/", result.source)
	pg_parse_result_free(result)
	assert_equal('a', pg_token_stream_consume(right).kind)
	pg_token_stream_free(right)
	pg_diagnostics_free(right_diag)


pg_token* runtime_broken(pg_lexer_state* state, pg_diagnostics* diagnostics):
	# Both inputs are read to keep this provider warning-clean.
	if (diagnostics == 0): return 0
	return pg_token_make(1, state.input, state.offset, 0, state.filename, 1, 1)


pg_token* runtime_skips_input(pg_lexer_state* state, pg_diagnostics* diagnostics):
	if (diagnostics == 0): return 0
	pg_lexer_advance(state, state.length - state.offset)
	return pg_token_eof(state.offset, state.filename, state.line, state.column)


pg_token* runtime_wrong_span(pg_lexer_state* state, pg_diagnostics* diagnostics):
	if (diagnostics == 0): return 0
	pg_token* token = pg_token_make(1, state.input, state.offset, 1, state.filename, state.line, state.column)
	pg_lexer_advance(state, 2)
	return token


void runtime_provider_span_test():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = pg_token_stream_from_provider(pg_lexer_state_new(c"lost", 4, c"skipped"), runtime_skips_input, diagnostics)
	assert1(pg_token_stream_done(stream))
	assert_equal(1, pg_diagnostics_count(diagnostics))
	assert_substring(pg_diagnostics_get(diagnostics, 0).message, c"before input was tokenized", 1)
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)
	diagnostics = pg_diagnostics_new()
	stream = pg_token_stream_from_provider(pg_lexer_state_new(c"ab", 2, c"span"), runtime_wrong_span, diagnostics)
	assert1(pg_token_stream_done(stream))
	assert_equal(1, pg_diagnostics_count(diagnostics))
	assert_substring(pg_diagnostics_get(diagnostics, 0).message, c"inconsistent token span", 1)
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)


void runtime_error_test():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = pg_token_stream_from_provider(pg_lexer_state_new(c"x", 1, c"broken"), runtime_broken, diagnostics)
	assert1(pg_token_stream_done(stream))
	assert_equal(1, pg_diagnostics_count(diagnostics))
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)
	diagnostics = pg_diagnostics_new()
	char* input = pg_substr(c"axb", 0, 3)
	input[1] = 0
	stream = pg_token_stream_from_provider(pg_lexer_state_new(input, 3, c"nul"), runtime_next, diagnostics)
	free(input)
	assert_equal('a', pg_token_stream_consume(stream).kind)
	assert_equal('b', pg_token_stream_consume(stream).kind)
	assert1(pg_token_stream_done(stream))
	assert_equal(1, pg_diagnostics_count(diagnostics))
	assert_equal(4, stream.all_tokens.length)
	char* rebuilt = pg_token_stream_source(stream)
	assert_equal('a', rebuilt[0])
	assert_equal(0, rebuilt[1])
	assert_equal('b', rebuilt[2])
	free(rebuilt)
	pg_parse_result* result = pg_parse_result_new(stream, diagnostics)
	assert_equal(3, result.length)
	assert_equal('b', result.source[2])
	pg_parse_result_free(result)
	diagnostics = pg_diagnostics_new()
	stream = runtime_stream(c"abc", diagnostics)
	stream.token_limit = 1
	pg_token_stream_consume(stream)
	assert1(pg_token_stream_done(stream))
	assert_equal(1, pg_diagnostics_count(diagnostics))
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)


void runtime_ast_limit_test():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = runtime_stream(c"", diagnostics)
	stream.ast_limit = 1
	assert1(pg_token_stream_ast_new(stream, 1, 0, c"first") != 0)
	pg_stream_checkpoint* checkpoint = pg_token_stream_checkpoint(stream)
	assert1(pg_token_stream_ast_new(stream, 1, 0, c"over budget") == 0)
	assert_equal(1, pg_diagnostics_count(diagnostics))
	assert_equal(1, stream.ast_allocation_count)
	pg_token_stream_restore(stream, checkpoint)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(1, stream.resource_failed)
	pg_token_stream_report_resource(stream)
	assert_equal(1, pg_diagnostics_count(diagnostics))
	pg_token_stream_report_resource(stream)
	assert_equal(1, pg_diagnostics_count(diagnostics))
	pg_token_stream_release(checkpoint)
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)


void runtime_checkpoint_limit_test():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = runtime_stream(c"", diagnostics)
	stream.checkpoint_limit = 1
	pg_stream_checkpoint* outer = pg_token_stream_checkpoint(stream)
	pg_stream_checkpoint* inner = pg_token_stream_checkpoint(stream)
	assert_equal(1, stream.resource_failed)
	assert1(pg_token_stream_ast_new(stream, 1, 0, c"over depth") == 0)
	pg_token_stream_restore(stream, inner)
	pg_token_stream_release(inner)
	pg_token_stream_restore(stream, outer)
	pg_token_stream_release(outer)
	assert_equal(0, stream.checkpoint_count)
	assert_equal(1, stream.resource_failed)
	pg_token_stream_report_resource(stream)
	assert_equal(1, pg_diagnostics_count(diagnostics))
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)


void runtime_locations_test():
	char* input = c"a\r\nb\rc\nd\xe2\x80\xa8e\xe2\x80\xa9f"
	pg_lexer_state* state = pg_lexer_state_new(input, strlen(input), c"lines")
	for i in range(state.length): pg_lexer_advance(state, 1)
	assert_equal(6, state.line)
	assert_equal(2, state.column)
	assert_equal(-1, pg_lexer_at(state, 0))
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	assert_equal(0, pg_lexer_pop_mode(state, diagnostics))
	assert_equal(1, pg_diagnostics_count(diagnostics))
	pg_lexer_state_free(state)
	pg_diagnostics_free(diagnostics)


void runtime_parity_test():
	char* source = c" a\r\n b "
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* lazy = runtime_stream(source, diagnostics)
	pg_token_stream* eager = pg_token_stream_new()
	pg_lexer_state* state = pg_lexer_state_new(source, strlen(source), c"eager")
	while (1):
		pg_token* token = runtime_next(state, diagnostics)
		pg_token_stream_add(eager, token)
		if (token.kind == pg_token_eof_kind): break
	while (1):
		pg_token* left = pg_token_stream_consume(lazy)
		pg_token* right = pg_token_stream_consume(eager)
		assert_equal(left.kind, right.kind)
		assert_equal(left.offset, right.offset)
		assert_equal(left.length, right.length)
		assert_equal(left.line, right.line)
		assert_equal(left.column, right.column)
		assert_strings_equal(left.text, right.text)
		if (left.kind == pg_token_eof_kind): break
	assert_equal(eager.all_tokens.length, lazy.all_tokens.length)
	for i in range(eager.all_tokens.length):
		assert_equal(eager.all_tokens[i].kind, lazy.all_tokens[i].kind)
		assert_equal(eager.all_tokens[i].channel, lazy.all_tokens[i].channel)
	char* rebuilt = pg_token_stream_source(lazy)
	assert_strings_equal(source, rebuilt)
	free(rebuilt)
	pg_token_stream_free(eager)
	pg_lexer_state_free(state)
	pg_token_stream_free(lazy)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	pg_diagnostics_free(diagnostics)
	diagnostics = pg_diagnostics_new()
	lazy = runtime_stream(c"a\xe2\x80\xa8b", diagnostics)
	pg_token_stream_consume(lazy)
	assert_equal(1, pg_token_stream_line_break_before(lazy))
	assert_equal(2, pg_token_stream_peek(lazy).line)
	pg_token_stream_free(lazy)
	pg_diagnostics_free(diagnostics)


int main():
	malloc_force_debug_mode()
	for i in range(3):
		runtime_context_test()
		runtime_interleaved_test()
		runtime_error_test()
		runtime_provider_span_test()
		runtime_locations_test()
		runtime_parity_test()
		runtime_ast_limit_test()
		runtime_checkpoint_limit_test()
	assert_equal(0, debug_alloc_report_leaks())
	println(c"stateful_runtime_test: OK")
	return 0
