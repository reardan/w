import libs.extras.parser_generator.runtime


int js_no_linebreak(pg_token_stream* stream):
	return pg_token_stream_line_break_before(stream) == 0


int js_statement_end(pg_token_stream* stream):
	pg_token* next = pg_token_stream_peek(stream)
	return next.kind == pg_token_eof_kind || strcmp(next.text, c"}") == 0 || pg_token_stream_line_break_before(stream)


int js_expression_statement_start(pg_token_stream* stream):
	pg_token* next = pg_token_stream_peek(stream)
	return strcmp(next.text, c"{") != 0 && strcmp(next.text, c"function") != 0 && strcmp(next.text, c"class") != 0
