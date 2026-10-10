import libs.extras.parser_generator.runtime


int stateful_word_allowed(pg_token_stream* stream):
	return strcmp(pg_token_stream_la(stream, 0).text, c"bad") != 0
