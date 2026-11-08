import libs.extras.parser_generator.runtime


int js_no_linebreak(pg_token_stream* stream):
	return pg_token_stream_line_break_before(stream) == 0


int js_statement_end(pg_token_stream* stream):
	pg_token* next = pg_token_stream_peek(stream)
	return next.kind == pg_token_eof_kind || strcmp(next.text, c"}") == 0 || pg_token_stream_line_break_before(stream)


int js_expression_statement_start(pg_token_stream* stream):
	pg_token* next = pg_token_stream_peek(stream)
	return strcmp(next.text, c"{") != 0 && strcmp(next.text, c"function") != 0 && strcmp(next.text, c"class") != 0


# Contextual `yield`/`await` (sec-identifiers-static-semantics-early-errors).
# The grammar is parsed without [Yield]/[Await] parameters, so these pure
# predicates recover them from the consumed tokens: the innermost enclosing
# function (arrows included) decides whether `yield` starts a YieldExpression
# and `await` an AwaitExpression. Everything else is an identifier, which the
# validator then checks against strict mode, module goal and the context.
int js_predicate_is(pg_token_stream* stream, int index, char* text):
	return index >= 0 && index < stream.index && strcmp(stream.tokens[index].text, text) == 0


int js_predicate_word(pg_token_stream* stream, int index):
	if (index < 0 || index >= stream.index): return 0
	int ch = stream.tokens[index].text[0] & 255
	return ch == '_' || ch == '$' || ch == 92 || ch >= 128 || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')


# Index of the opener matching the closer at index, or -1.
int js_predicate_open(pg_token_stream* stream, int index):
	int depth = 0
	while (index >= 0):
		char* text = stream.tokens[index].text
		if (strcmp(text, c")") == 0 || strcmp(text, c"]") == 0 || strcmp(text, c"}") == 0): depth = depth + 1
		else if (strcmp(text, c"(") == 0 || strcmp(text, c"[") == 0 || strcmp(text, c"{") == 0):
			depth = depth - 1
			if (depth == 0): return index
		index = index - 1
	return -1


int js_predicate_control(pg_token_stream* stream, int index):
	return js_predicate_is(stream, index, c"if") || js_predicate_is(stream, index, c"while") || js_predicate_is(stream, index, c"for") || js_predicate_is(stream, index, c"switch") || js_predicate_is(stream, index, c"catch") || js_predicate_is(stream, index, c"with") || (js_predicate_is(stream, index, c"await") && js_predicate_is(stream, index - 1, c"for"))


int js_predicate_operator_word(pg_token_stream* stream, int index):
	char* text = stream.tokens[index].text
	return strcmp(text, c"return") == 0 || strcmp(text, c"typeof") == 0 || strcmp(text, c"void") == 0 || strcmp(text, c"delete") == 0 || strcmp(text, c"new") == 0 || strcmp(text, c"in") == 0 || strcmp(text, c"instanceof") == 0 || strcmp(text, c"case") == 0 || strcmp(text, c"throw") == 0 || strcmp(text, c"do") == 0 || strcmp(text, c"else") == 0 || strcmp(text, c"yield") == 0 || strcmp(text, c"of") == 0


# Flags (1 generator, 2 async, 4 function) for the function whose parameter
# list opens at index. Without a following body, `name(` may be a call and
# only heads that cannot be calls qualify.
int js_predicate_function_head(pg_token_stream* stream, int open, int body):
	int name = open - 1
	if (js_predicate_is(stream, name, c"function")): return 4 | 2 * js_predicate_is(stream, name - 1, c"async")
	if (js_predicate_is(stream, name, c"*") && js_predicate_is(stream, name - 1, c"function")): return 5 | 2 * js_predicate_is(stream, name - 2, c"async")
	if (js_predicate_is(stream, name, c"]")):
		name = js_predicate_open(stream, name)
		if (name < 0): return 0
	else if (js_predicate_word(stream, name) == 0 || js_predicate_control(stream, name) || (body == 0 && js_predicate_operator_word(stream, name))): return 0
	int before = name - 1
	if (js_predicate_is(stream, before, c"function")): return 4 | 2 * js_predicate_is(stream, before - 1, c"async")
	if (js_predicate_is(stream, before, c"*")):
		if (js_predicate_is(stream, before - 1, c"function")): return 5 | 2 * js_predicate_is(stream, before - 2, c"async")
		return 5 | 2 * js_predicate_is(stream, before - 1, c"async")
	if (js_predicate_is(stream, before, c"async")): return 6
	if (js_predicate_is(stream, before, c"get") || js_predicate_is(stream, before, c"set") || js_predicate_is(stream, before, c"static")): return 4
	# A plain `name(...) {` is a method body; `name(` alone may be a call.
	if (body && js_predicate_is(stream, before, c"extends") == 0): return 4
	return 0


# Arrow whose `=>` is at index: 4 | 2 when async.
int js_predicate_arrow(pg_token_stream* stream, int index):
	int head = index - 1
	if (js_predicate_is(stream, head, c")")): head = js_predicate_open(stream, head)
	return 4 | 2 * js_predicate_is(stream, head - 1, c"async")


int js_function_flags(pg_token_stream* stream):
	int index = stream.index - 1
	int depth = 0
	int closed = 0
	while (index >= 0):
		char* text = stream.tokens[index].text
		int ch = text[0]
		# Only one-byte punctuators and `=>` steer the scan.
		if (text[1] == 0 || (ch == '=' && text[1] == '>' && text[2] == 0)):
			if (ch == ')' || ch == ']' || ch == '}'): depth = depth + 1
			else if (ch == '(' || ch == '[' || ch == '{'):
				if (depth > 0): depth = depth - 1
				else:
					closed = 0
					int flags = 0
					if (ch == '('): flags = js_predicate_function_head(stream, index, 0)
					else if (ch == '{' && js_predicate_is(stream, index - 1, c"=>")): flags = js_predicate_arrow(stream, index - 1)
					else if (ch == '{' && js_predicate_is(stream, index - 1, c")")):
						int open = js_predicate_open(stream, index - 1)
						if (open >= 0): flags = js_predicate_function_head(stream, open, 1)
					if (flags != 0): return flags
			else if (depth == 0):
				if (ch == ';' || ch == ','): closed = 1
				else if (closed == 0 && ch == '=' && text[1] == '>'): return js_predicate_arrow(stream, index)
		index = index - 1
	return 0


# A name directly after `function` or `function*` is never an expression.
int js_predicate_function_name(pg_token_stream* stream):
	int index = stream.index - 1
	if (js_predicate_is(stream, index, c"*")): index = index - 1
	return js_predicate_is(stream, index, c"function")


int js_predicate_next(pg_token_stream* stream, char* text):
	return strcmp(pg_token_stream_peek(stream).text, text) == 0


int js_yield_keyword(pg_token_stream* stream):
	return js_predicate_next(stream, c"yield") && js_predicate_function_name(stream) == 0 && (js_function_flags(stream) & 1) != 0


int js_await_keyword(pg_token_stream* stream):
	return js_predicate_next(stream, c"await") && js_predicate_function_name(stream) == 0 && (js_function_flags(stream) & 2) != 0


int js_yield_identifier(pg_token_stream* stream):
	return js_predicate_next(stream, c"yield") && js_yield_keyword(stream) == 0


int js_await_identifier(pg_token_stream* stream):
	return js_predicate_next(stream, c"await") && js_await_keyword(stream) == 0
