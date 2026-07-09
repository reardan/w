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


struct pg_token_stream:
	list[pg_token*] tokens
	list[pg_token*] all_tokens
	int index
	int max_index


pg_token_stream* pg_token_stream_new():
	pg_token_stream* stream = new pg_token_stream()
	stream.tokens = new list[pg_token*]
	stream.all_tokens = new list[pg_token*]
	stream.index = 0
	stream.max_index = 0
	return stream


void pg_token_stream_add(pg_token_stream* stream, pg_token* token):
	stream.all_tokens.push(token)
	if (token.channel == pg_token_default_channel()):
		stream.tokens.push(token)


pg_token* pg_token_stream_get(pg_token_stream* stream, int index):
	if (index >= stream.tokens.length):
		return stream.tokens[stream.tokens.length - 1]
	return stream.tokens[index]


pg_token* pg_token_stream_la(pg_token_stream* stream, int offset):
	return pg_token_stream_get(stream, stream.index + offset - 1)


pg_token* pg_token_stream_peek(pg_token_stream* stream):
	return pg_token_stream_la(stream, 1)


pg_token* pg_token_stream_consume(pg_token_stream* stream):
	pg_token* token = pg_token_stream_peek(stream)
	if (stream.index < stream.tokens.length):
		stream.index = stream.index + 1
	if (stream.index > stream.max_index):
		stream.max_index = stream.index
	return token


int pg_token_stream_mark(pg_token_stream* stream):
	return stream.index


void pg_token_stream_rewind(pg_token_stream* stream, int mark):
	stream.index = mark


# The token at the deepest point any parse attempt reached. After a failed
# backtracking parse this is a far better error location than the (fully
# rewound) current position.
pg_token* pg_token_stream_furthest(pg_token_stream* stream):
	return pg_token_stream_get(stream, stream.max_index)


int pg_token_stream_done(pg_token_stream* stream):
	return pg_token_stream_peek(stream).kind == pg_token_eof_kind()


# Every token in source order, including hidden-channel trivia.
int pg_token_stream_all_count(pg_token_stream* stream):
	return stream.all_tokens.length


pg_token* pg_token_stream_all_get(pg_token_stream* stream, int index):
	return stream.all_tokens[index]


# Concatenate the text of every token (all channels). With a lossless lexer
# this reproduces the lexed input byte for byte. Caller frees the result.
char* pg_token_stream_source(pg_token_stream* stream):
	string_builder* out = string_new()
	int i = 0
	while (i < stream.all_tokens.length):
		pg_token* token = stream.all_tokens[i]
		string_append(out, token.text)
		i = i + 1
	char* text = out.data
	free(out)
	return text


void pg_token_stream_free(pg_token_stream* stream):
	if (stream == 0):
		return
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
	free(stream)
