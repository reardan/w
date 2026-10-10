/*
Buffered token stream for generated recursive-descent parsers.

The parser-facing cursor (index/peek/consume) only ever sees default-channel
tokens. Hidden-channel trivia (whitespace, comments, invalid characters) is
kept in all_tokens, which holds every token in source order so tools like
formatters can reproduce the input losslessly.
*/
import lib.lib
import structures.string
import libs.extras.parser_generator.token
import libs.extras.parser_generator.ast_node
import libs.extras.parser_generator.lexer_state


struct pg_token_stream:
	list[pg_token*] tokens
	list[pg_token*] all_tokens
	int index
	int max_index
	list[pg_ast_node*] ast_nodes
	pg_lexer_state* provider
	pg_lexer_next* next_token
	pg_diagnostics* diagnostics
	list[pg_token*] retired_tokens
	list[pg_lexer_snapshot*] boundaries
	list[int] boundary_all
	list[int] boundary_diagnostics
	pg_token* furthest
	int scan_count
	int rollback_count
	int allocation_count
	int ast_allocation_count
	int ast_limit
	int resource_failed
	char* resource_message
	int checkpoint_count
	int checkpoint_limit
	int token_limit
	int exhausted


struct pg_stream_checkpoint:
	pg_token_stream* owner
	int index
	int all_count
	int token_count
	int diagnostic_count
	int exhausted
	pg_lexer_snapshot* state


void pg_token_stream_own_ast(pg_token_stream* stream);
void pg_token_stream_add(pg_token_stream* stream, pg_token* token);


pg_token_stream* pg_token_stream_new():
	pg_token_stream* stream = new pg_token_stream()
	stream.tokens = new list[pg_token*]
	stream.all_tokens = new list[pg_token*]
	stream.index = 0
	stream.max_index = 0
	stream.ast_nodes = 0
	stream.provider = 0
	stream.next_token = 0
	stream.diagnostics = 0
	stream.retired_tokens = new list[pg_token*]
	stream.boundaries = new list[pg_lexer_snapshot*]
	stream.boundary_all = new list[int]
	stream.boundary_diagnostics = new list[int]
	stream.furthest = 0
	stream.scan_count = 0
	stream.rollback_count = 0
	stream.allocation_count = 0
	stream.ast_allocation_count = 0
	stream.ast_limit = 0
	stream.resource_failed = 0
	stream.resource_message = c""
	stream.checkpoint_count = 0
	stream.checkpoint_limit = 4096
	stream.token_limit = 1000000
	stream.exhausted = 0
	return stream


# The stream owns state and tokens; diagnostics remain caller-owned.
pg_token_stream* pg_token_stream_from_provider(pg_lexer_state* state, pg_lexer_next* next_token, pg_diagnostics* diagnostics):
	pg_token_stream* stream = pg_token_stream_new()
	stream.provider = state
	stream.next_token = next_token
	stream.diagnostics = diagnostics
	stream.ast_limit = 1000000
	pg_token_stream_own_ast(stream)
	# A bounded input must never silently stop at an embedded NUL.
	pg_lexer_snapshot* initial = pg_lexer_save(state)
	while (state.offset < state.length):
		if (state.input[state.offset] == 0):
			pg_diagnostics_add(diagnostics, state.filename, state.line, state.column, c"embedded NUL in lexer input", c"source character", c"NUL")
		pg_lexer_advance(state, 1)
	pg_lexer_restore(state, initial)
	pg_lexer_snapshot_free(initial)
	return stream


# Resource failure is sticky across rollback. Branch diagnostics are still
# transactional; the entry point reports this persistent failure once more
# if the original message was discarded with the branch.
void pg_token_stream_report_resource(pg_token_stream* stream):
	if (stream.resource_failed == 0 || stream.diagnostics == 0): return
	for i in range(stream.diagnostics.items.length):
		if (strcmp(stream.diagnostics.items[i].message, stream.resource_message) == 0): return
	pg_diagnostics_add(stream.diagnostics, stream.provider.filename, stream.provider.line, stream.provider.column, stream.resource_message, c"", c"")


void pg_token_stream_resource_error(pg_token_stream* stream, char* message):
	if (stream.resource_failed == 0): stream.resource_message = message
	stream.resource_failed = 1
	pg_token_stream_report_resource(stream)


void pg_token_stream_scan(pg_token_stream* stream):
	pg_lexer_state* state = stream.provider
	pg_lexer_snapshot* boundary = pg_lexer_save(state)
	int all_start = stream.all_tokens.length
	int diagnostic_start = pg_diagnostics_count(stream.diagnostics)
	while (1):
		pg_token* token = 0
		int start = state.offset
		if (stream.allocation_count >= stream.token_limit):
			pg_token_stream_resource_error(stream, c"lexer token resource limit exceeded")
			token = pg_token_eof(start, state.filename, state.line, state.column)
			stream.exhausted = 1
		else:
			stream.scan_count = stream.scan_count + 1
			if (state.offset < state.length && state.input[state.offset] == 0):
				token = pg_token_hide(pg_token_make(pg_token_invalid_kind(), state.input, start, 1, state.filename, state.line, state.column))
				pg_lexer_advance(state, 1)
			else: token = stream.next_token(state, stream.diagnostics)
		if (token == 0):
			pg_diagnostics_add(stream.diagnostics, state.filename, state.line, state.column, c"lexer provider failed", c"token", c"")
			token = pg_token_eof(start, state.filename, state.line, state.column)
			stream.exhausted = 1
		if (token.kind == pg_token_eof_kind):
			if (stream.exhausted == 0 && (start != state.length || state.offset != start || token.offset != state.length || token.length != 0)):
				pg_diagnostics_add(stream.diagnostics, state.filename, state.line, state.column, c"lexer emitted EOF before input was tokenized", c"complete input tokenization", c"")
			stream.exhausted = 1
			token.channel = pg_token_default_channel
		else:
			if (state.offset <= start || state.offset > state.length || token.offset != start || token.length != state.offset - start):
				pg_diagnostics_add(stream.diagnostics, state.filename, state.line, state.column, c"lexer provider emitted an inconsistent token span", c"nonempty contiguous input span", token.text)
				pg_token_free(token)
				token = pg_token_eof(start, state.filename, state.line, state.column)
				stream.exhausted = 1
		stream.allocation_count = stream.allocation_count + 1
		pg_token_stream_add(stream, token)
		if (token.channel == pg_token_default_channel):
			stream.boundaries.push(boundary)
			stream.boundary_all.push(all_start)
			stream.boundary_diagnostics.push(diagnostic_start)
			return


# Retired tokens stay alive because abandoned nodes may still borrow them.
void pg_token_stream_truncate(pg_token_stream* stream, int count, int all_count):
	while (stream.all_tokens.length > all_count): stream.retired_tokens.push(stream.all_tokens.pop())
	while (stream.tokens.length > count):
		stream.tokens.pop()
		pg_lexer_snapshot_free(stream.boundaries.pop())
		stream.boundary_all.pop()
		stream.boundary_diagnostics.pop()


# Restore the state before the current visible token, including its trivia.
void pg_token_stream_discard_lookahead(pg_token_stream* stream):
	if (stream.provider == 0 || stream.index >= stream.tokens.length): return
	pg_lexer_restore(stream.provider, stream.boundaries[stream.index])
	pg_diagnostics_truncate(stream.diagnostics, stream.boundary_diagnostics[stream.index])
	int all_count = stream.boundary_all[stream.index]
	pg_token_stream_truncate(stream, stream.index, all_count)
	stream.exhausted = 0


void pg_token_stream_set_goal(pg_token_stream* stream, int goal):
	if (stream.provider == 0): return
	if (stream.provider.goal == goal): return
	pg_token_stream_discard_lookahead(stream)
	stream.provider.goal = goal


pg_stream_checkpoint* pg_token_stream_checkpoint(pg_token_stream* stream):
	# Checkpoints start before unconsumed lookahead. No cached token may
	# cross a context boundary: the selected branch rescans it.
	pg_token_stream_discard_lookahead(stream)
	pg_stream_checkpoint* checkpoint = new pg_stream_checkpoint()
	checkpoint.owner = stream
	stream.checkpoint_count = stream.checkpoint_count + 1
	if (stream.provider != 0 && stream.checkpoint_limit > 0 && stream.checkpoint_count > stream.checkpoint_limit):
		pg_token_stream_resource_error(stream, c"parser checkpoint depth limit exceeded")
	checkpoint.index = stream.index
	checkpoint.all_count = stream.all_tokens.length
	checkpoint.token_count = stream.tokens.length
	checkpoint.diagnostic_count = pg_diagnostics_count(stream.diagnostics)
	checkpoint.exhausted = stream.exhausted
	checkpoint.state = 0
	if (stream.provider != 0): checkpoint.state = pg_lexer_save(stream.provider)
	return checkpoint


void pg_token_stream_restore(pg_token_stream* stream, pg_stream_checkpoint* checkpoint):
	stream.index = checkpoint.index
	pg_diagnostics_truncate(stream.diagnostics, checkpoint.diagnostic_count)
	if (checkpoint.state != 0):
		pg_lexer_restore(stream.provider, checkpoint.state)
		pg_token_stream_truncate(stream, checkpoint.token_count, checkpoint.all_count)
		stream.exhausted = checkpoint.exhausted
	stream.rollback_count = stream.rollback_count + 1


void pg_token_stream_release(pg_stream_checkpoint* checkpoint):
	if (checkpoint == 0): return
	pg_lexer_snapshot_free(checkpoint.state)
	checkpoint.owner.checkpoint_count = checkpoint.owner.checkpoint_count - 1
	free(checkpoint)


# Opt in BEFORE parsing with a newly generated parser. The stream then
# owns all parse nodes, including abandoned alternatives and recovery
# nodes. Free only the stream, never pg_ast_free(root), in this mode.
# Default callers retain the original independently owned tree API.
void pg_token_stream_own_ast(pg_token_stream* stream):
	if (stream.ast_nodes == 0): stream.ast_nodes = new list[pg_ast_node*]


pg_ast_node* pg_token_stream_ast_new(pg_token_stream* stream, int kind, pg_token* token, char* name):
	# Eager callers remain unlimited: their generated code predates nullable
	# allocation results. Stateful generated rules check this return value.
	if (stream.provider != 0):
		if (stream.resource_failed || (stream.ast_limit > 0 && stream.ast_allocation_count >= stream.ast_limit)):
			pg_token_stream_resource_error(stream, c"parser AST resource limit exceeded")
			return 0
	stream.ast_allocation_count = stream.ast_allocation_count + 1
	pg_ast_node* node = pg_ast_new(kind, token, name)
	if (stream.ast_nodes != 0): stream.ast_nodes.push(node)
	return node


void pg_token_stream_add(pg_token_stream* stream, pg_token* token):
	stream.all_tokens.push(token)
	if (token.channel == pg_token_default_channel): stream.tokens.push(token)


pg_token* pg_token_stream_get(pg_token_stream* stream, int index):
	if (index < 0): index = 0
	if (stream.provider != 0):
		while (index >= stream.tokens.length && stream.exhausted == 0): pg_token_stream_scan(stream)
	if (stream.tokens.length == 0): return 0
	if (index >= stream.tokens.length): index = stream.tokens.length - 1
	pg_token* token = stream.tokens[index]
	if (stream.provider != 0):
		if (stream.furthest == 0 || token.offset >= stream.furthest.offset): stream.furthest = token
	return token


pg_token* pg_token_stream_la(pg_token_stream* stream, int offset):
	return pg_token_stream_get(stream, stream.index + offset - 1)


pg_token* pg_token_stream_peek(pg_token_stream* stream):
	return pg_token_stream_la(stream, 1)


pg_token* pg_token_stream_consume(pg_token_stream* stream):
	pg_token* token = pg_token_stream_peek(stream)
	if (stream.provider == 0 || token.kind != pg_token_eof_kind):
		if (stream.index < stream.tokens.length): stream.index = stream.index + 1
	if (stream.index > stream.max_index): stream.max_index = stream.index
	if (stream.furthest == 0 || token.offset >= stream.furthest.offset): stream.furthest = token
	return token


int pg_token_stream_mark(pg_token_stream* stream):
	return stream.index


void pg_token_stream_rewind(pg_token_stream* stream, int mark):
	stream.index = mark
	pg_token_stream_discard_lookahead(stream)


# The token at the deepest point any parse attempt reached. After a failed
# backtracking parse this is a far better error location than the (fully
# rewound) current position.
pg_token* pg_token_stream_furthest(pg_token_stream* stream):
	if (stream.provider != 0):
		pg_token* current = pg_token_stream_peek(stream)
		if (stream.furthest == 0 || current.offset >= stream.furthest.offset): stream.furthest = current
		return stream.furthest
	return pg_token_stream_get(stream, stream.max_index)


int pg_token_stream_done(pg_token_stream* stream):
	return pg_token_stream_peek(stream).kind == pg_token_eof_kind


# Every token in source order, including hidden-channel trivia.
int pg_token_stream_all_count(pg_token_stream* stream):
	return stream.all_tokens.length


pg_token* pg_token_stream_all_get(pg_token_stream* stream, int index):
	return stream.all_tokens[index]


# Concatenate the text of every token (all channels). With a lossless lexer
# this reproduces the lexed input byte for byte. Caller frees the result.
char* pg_token_stream_source(pg_token_stream* stream):
	string_builder* out = string_new()
	for i in range(stream.all_tokens.length):
		pg_token* token = stream.all_tokens[i]
		string_append_bytes(out, token.text, token.length)
	char* text = out.data
	free(out)
	return text


void pg_token_stream_free(pg_token_stream* stream):
	if (stream == 0): return
	if (stream.ast_nodes != 0):
		int n = 0
		while (n < stream.ast_nodes.length):
			# Shared factored prefixes can occur under several abandoned
			# parents. Each allocation is registered once; do not recurse.
			pg_ast_free_shallow(stream.ast_nodes[n])
			n = n + 1
		__w_list_free(cast(__w_list*, stream.ast_nodes))
	int i = 0
	while (i < stream.all_tokens.length):
		pg_token_free(stream.all_tokens[i])
		i = i + 1
	# This file is transitively imported by the compiler itself (via
	# grammar/c_import_statement.w), so it must stick to syntax the seed
	# already supports (no generic functions) — reach into the
	# auto-imported __w_list runtime directly, the same pattern
	# compiler/type_table.w uses for type_table_truncate().
	__w_list_free(cast(__w_list*, stream.all_tokens))
	__w_list_free(cast(__w_list*, stream.tokens))
	for j in range(stream.retired_tokens.length): pg_token_free(stream.retired_tokens[j])
	for j in range(stream.boundaries.length): pg_lexer_snapshot_free(stream.boundaries[j])
	__w_list_free(cast(__w_list*, stream.retired_tokens))
	__w_list_free(cast(__w_list*, stream.boundaries))
	__w_list_free(cast(__w_list*, stream.boundary_all))
	__w_list_free(cast(__w_list*, stream.boundary_diagnostics))
	pg_lexer_state_free(stream.provider)
	free(stream)


# Includes newlines inside comments and Unicode JS line separators. Inspect
# only intervening trivia, not line breaks inside the current token itself.
int pg_token_stream_line_break_before(pg_token_stream* stream):
	pg_token* current = pg_token_stream_peek(stream)
	int previous_end = 0
	if (stream.index > 0):
		pg_token* previous = stream.tokens[stream.index - 1]
		previous_end = previous.offset + previous.length
	int older = 0
	int previous = 0
	int start = 0
	if (stream.provider != 0 && stream.index < stream.boundary_all.length): start = stream.boundary_all[stream.index]
	for i in range(start, stream.all_tokens.length):
		pg_token* trivia = stream.all_tokens[i]
		if (trivia.offset < previous_end): continue
		if (trivia.offset >= current.offset): break
		if (trivia.channel == pg_token_default_channel): continue
		for j in range(trivia.length):
			int ch = cast(int, trivia.text[j]) & 255
			if (ch == 10 || ch == 13): return 1
			if (older == 226 && previous == 128 && (ch == 168 || ch == 169)): return 1
			older = previous
			previous = ch
	return 0
