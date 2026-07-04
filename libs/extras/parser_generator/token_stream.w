/*
Buffered token stream for generated recursive-descent parsers.
*/
import lib.lib
import structures.array_list
import libs.extras.parser_generator.token


struct pg_token_stream:
	array_list* tokens
	int index


pg_token_stream* pg_token_stream_new():
	pg_token_stream* stream = new pg_token_stream()
	stream.tokens = array_list_new()
	stream.index = 0
	return stream


void pg_token_stream_add(pg_token_stream* stream, pg_token* token):
	array_list_push(stream.tokens, token)


pg_token* pg_token_stream_get(pg_token_stream* stream, int index):
	if (index >= stream.tokens.length):
		return array_list_get(stream.tokens, stream.tokens.length - 1)
	return array_list_get(stream.tokens, index)


pg_token* pg_token_stream_la(pg_token_stream* stream, int offset):
	return pg_token_stream_get(stream, stream.index + offset - 1)


pg_token* pg_token_stream_peek(pg_token_stream* stream):
	return pg_token_stream_la(stream, 1)


pg_token* pg_token_stream_consume(pg_token_stream* stream):
	pg_token* token = pg_token_stream_peek(stream)
	if (stream.index < stream.tokens.length):
		stream.index = stream.index + 1
	return token


int pg_token_stream_mark(pg_token_stream* stream):
	return stream.index


void pg_token_stream_rewind(pg_token_stream* stream, int mark):
	stream.index = mark


int pg_token_stream_done(pg_token_stream* stream):
	return pg_token_stream_peek(stream).kind == pg_token_eof_kind()


void pg_token_stream_free(pg_token_stream* stream):
	if (stream == 0):
		return
	int i = 0
	while (i < stream.tokens.length):
		pg_token_free(array_list_get(stream.tokens, i))
		i = i + 1
	array_list_free(stream.tokens)
	free(stream)
