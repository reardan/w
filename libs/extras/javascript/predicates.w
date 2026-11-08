import lib.container
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


# Defined by the generated parser that imports this file.
char* javascript_token_name(int kind);


# Scan classes for backward context scans: 1 opener (one-byte bracket or the
# template `${`), 2 closer, 3 separator (`;` or `,`), 4 `=>`, 0 anything else.
# Template text spelled like a punctuator (`)` in `\`)\``) is not one.
int js_predicate_kind(pg_token* token):
	char* text = token.text
	int ch = text[0]
	if (text[1] == 0):
		if (ch == ';' || ch == ','): return 3
		int kind = 0
		if (ch == '(' || ch == '[' || ch == '{'): kind = 1
		else if (ch == ')' || ch == ']' || ch == '}'): kind = 2
		if (kind != 0 && strcmp(javascript_token_name(token.kind), c"TEMPLATE_TEXT") == 0): return 0
		return kind
	if (text[2] != 0): return 0
	if (ch == '$' && text[1] == '{'): return 1
	if (ch == '=' && text[1] == '>'): return 4
	return 0


# Backward scans are memoized per token in the stream (one word each, see
# pg_token_stream_memo_get): bits 0-2 hold js_function_flags_from with
# closed = 0 and bit 3 marks it known, bits 4-7 the same for closed = 1, and
# bits 8 and up a closer's matching opener + 2 (0 unknown, 1 unmatched).
# Every value depends only on the token and those before it, so entries stay
# valid until rollback rescans the token and the stream drops them.
int js_predicate_memo(pg_token_stream* stream, int index):
	int value = pg_token_stream_memo_get(stream, index)
	if (value < 0): return 0
	return value


# Index of the opener matching the closer at index, or -1.
int js_predicate_open(pg_token_stream* stream, int index):
	if (index < 0 || index >= stream.index): return -1
	int memo = js_predicate_memo(stream, index)
	if ((memo >> 8) != 0): return (memo >> 8) - 2
	int result = -1
	int scan = index - 1
	while (scan >= 0):
		int kind = js_predicate_kind(stream.tokens[scan])
		if (kind == 1):
			result = scan
			break
		if (kind == 2):
			scan = js_predicate_open(stream, scan)
			if (scan < 0): break
		scan = scan - 1
	pg_token_stream_memo_set(stream, index, (js_predicate_memo(stream, index) & 255) | ((result + 2) << 8))
	return result


int js_predicate_control(pg_token_stream* stream, int index):
	return js_predicate_is(stream, index, c"if") || js_predicate_is(stream, index, c"while") || js_predicate_is(stream, index, c"for") || js_predicate_is(stream, index, c"switch") || js_predicate_is(stream, index, c"catch") || js_predicate_is(stream, index, c"with") || (js_predicate_is(stream, index, c"await") && js_predicate_is(stream, index - 1, c"for"))


int js_predicate_operator_word(pg_token_stream* stream, int index):
	char* text = stream.tokens[index].text
	return strcmp(text, c"return") == 0 || strcmp(text, c"typeof") == 0 || strcmp(text, c"void") == 0 || strcmp(text, c"delete") == 0 || strcmp(text, c"new") == 0 || strcmp(text, c"in") == 0 || strcmp(text, c"instanceof") == 0 || strcmp(text, c"case") == 0 || strcmp(text, c"throw") == 0 || strcmp(text, c"do") == 0 || strcmp(text, c"else") == 0 || strcmp(text, c"yield") == 0 || strcmp(text, c"of") == 0


# Flags (1 generator, 2 async, 4 function) for the function whose parameter
# list opens at index. Without a following body, `name(` may be a call and
# only heads that cannot be calls qualify.
# Inside the still open `name(` at open, look past its balanced parameter
# list: a `{` right after the `)` makes it a method head, so a parameter
# default such as `m(a = yield) {}` follows the method's context. A line break
# before the `{` reads as a call followed by a block (ASI) unless the name
# follows a `,` of an object literal. The answer is memoized on the opener
# (bits 8 and up: 1 call, 2 method), so each list is looked through once.
# Tokens past the cursor are lexed ahead in the current goal and discarded
# at the next checkpoint; the parameter list's tokens never depend on it.
int js_predicate_method_parameters(pg_token_stream* stream, int open, int before):
	int memo = js_predicate_memo(stream, open)
	if ((memo >> 8) != 0): return (memo >> 8) == 2
	int depth = 0
	int index = open
	int method = 0
	while (1):
		pg_token* token = pg_token_stream_get(stream, index)
		if (token == 0 || token.kind == pg_token_eof_kind || index >= stream.tokens.length): break
		int kind = js_predicate_kind(token)
		if (kind == 1): depth = depth + 1
		else if (kind == 2):
			depth = depth - 1
			if (depth == 0):
				pg_token* next = pg_token_stream_get(stream, index + 1)
				if (next != 0 && index + 1 < stream.tokens.length && strcmp(next.text, c"{") == 0):
					int saved = stream.index
					stream.index = index + 1
					int line_break = pg_token_stream_line_break_before(stream)
					stream.index = saved
					method = line_break == 0 || js_predicate_is(stream, before, c",")
				break
		index = index + 1
	pg_token_stream_memo_set(stream, open, (js_predicate_memo(stream, open) & 255) | ((1 + method) << 8))
	return method


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
	if (js_predicate_is(stream, before, c"extends")): return 0
	if (body || (js_predicate_is(stream, name, c"extends") == 0 && js_predicate_method_parameters(stream, open, before))): return 4
	return 0


# Arrow whose `=>` is at index: 4 | 2 when async.
int js_predicate_arrow(pg_token_stream* stream, int index):
	int head = index - 1
	if (js_predicate_is(stream, head, c")")): head = js_predicate_open(stream, head)
	return 4 | 2 * js_predicate_is(stream, head - 1, c"async")


# Flags of the opener at index when the scan reaches it unmatched.
int js_predicate_opener_flags(pg_token_stream* stream, int index):
	char* text = stream.tokens[index].text
	if (text[0] == '('): return js_predicate_function_head(stream, index, 0)
	if (text[0] != '{'): return 0
	if (js_predicate_is(stream, index - 1, c"=>")): return js_predicate_arrow(stream, index - 1)
	if (js_predicate_is(stream, index - 1, c")")):
		int open = js_predicate_open(stream, index - 1)
		if (open >= 0): return js_predicate_function_head(stream, open, 1)
	return 0


# Scan back from token index (inclusive) for the innermost enclosing function.
# A depth-0 `;` or `,` sets closed: an earlier `=>` then ends an arrow body
# that cannot contain this token. Closed groups are skipped through the
# matching-opener memo. Each (token, closed) state on the walk shares the
# walk's result, so all of them are memoized and later scans stop at the
# first known state: n contextual keywords cost O(n) overall, not O(n^2).
int js_function_flags_from(pg_token_stream* stream, int index, int closed):
	list[int] walk = 0
	int result = 0
	while (index >= 0):
		int kind = js_predicate_kind(stream.tokens[index])
		# A separator's result never depends on the incoming state, nor an
		# opener's: key both by one state so every scan shares the entry.
		if (kind == 3): closed = 1
		else if (kind == 1): closed = 0
		int memo = js_predicate_memo(stream, index)
		int shift = 4 * closed
		if (((memo >> shift) & 8) != 0):
			result = (memo >> shift) & 7
			break
		if (walk == 0): walk = new list[int]
		walk.push(2 * index + closed)
		if (kind == 2):
			index = js_predicate_open(stream, index)
			if (index < 0): break
		else if (kind == 1):
			result = js_predicate_opener_flags(stream, index)
			if (result != 0): break
		else if (kind == 4 && closed == 0):
			result = js_predicate_arrow(stream, index)
			break
		index = index - 1
	if (walk != 0):
		for int state in walk:
			int at = state >> 1
			int shift = 4 * (state & 1)
			int memo = js_predicate_memo(stream, at)
			pg_token_stream_memo_set(stream, at, (memo & ~(15 << shift)) | ((8 | result) << shift))
		list_free[int](walk)
	return result


int js_function_flags(pg_token_stream* stream):
	return js_function_flags_from(stream, stream.index - 1, 0)


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


# The `(` at index opens a for-statement head (`for (` or `for await (`).
int js_predicate_for_head(pg_token_stream* stream, int index):
	if (js_predicate_is(stream, index - 1, c"for")): return 1
	return js_predicate_is(stream, index - 1, c"await") && js_predicate_is(stream, index - 2, c"for")


# An `in` operator, not the property name in `a.in`.
int js_predicate_in_operator(pg_token_stream* stream, int index):
	return js_predicate_is(stream, index, c"in") && js_predicate_is(stream, index - 1, c".") == 0 && js_predicate_is(stream, index - 1, c"?.") == 0


# A for-of `of` follows the end of its binding or target.
int js_predicate_of_operator(pg_token_stream* stream, int index):
	if (index < 1 || js_predicate_is(stream, index, c"of") == 0): return 0
	return js_predicate_word(stream, index - 1) || js_predicate_kind(stream.tokens[index - 1]) == 2


# [~In] (sec-for-statement, B.3.6): a relational `in` cannot appear at the top
# level of a for head's first clause, so `for (var x = a in b)` ends the
# initializer at `in`. Brackets, templates and function bodies restore [+In],
# as do the middle operand of `?:`, the clauses after the first `;` and the
# expression after the head's own `in`/`of`.
int js_relational_in(pg_token_stream* stream):
	# Alternatives evaluate the predicate before matching KW_IN.
	if (js_predicate_next(stream, c"in") == 0): return 1
	int index = stream.index - 1
	int colons = 0
	while (index >= 0):
		char* text = stream.tokens[index].text
		int kind = js_predicate_kind(stream.tokens[index])
		if (kind == 2):
			index = js_predicate_open(stream, index)
			if (index < 0): return 1
		else if (kind == 1): return text[0] != '(' || js_predicate_for_head(stream, index) == 0
		else if (strcmp(text, c";") == 0): return 1
		else if (strcmp(text, c":") == 0): colons = colons + 1
		else if (strcmp(text, c"?") == 0):
			if (colons == 0): return 1
			colons = colons - 1
		else if (colons == 0 && (js_predicate_in_operator(stream, index) || js_predicate_of_operator(stream, index))): return 1
		index = index - 1
	return 1


# The statement ending at index is the body of a `do` (a block or a simple
# statement directly after `do`).
int js_predicate_do_while(pg_token_stream* stream, int index):
	if (index < 0): return 0
	if (js_predicate_is(stream, index, c"}")):
		int open = js_predicate_open(stream, index)
		return open >= 0 && js_predicate_is(stream, open - 1, c"do")
	if (js_predicate_is(stream, index, c";") == 0): return 0
	index = index - 1
	while (index >= 0):
		char* text = stream.tokens[index].text
		int kind = js_predicate_kind(stream.tokens[index])
		if (kind == 2):
			index = js_predicate_open(stream, index)
			if (index < 0): return 0
		else if (kind == 1 || strcmp(text, c";") == 0 || strcmp(text, c":") == 0): return 0
		else if (strcmp(text, c"do") == 0): return 1
		index = index - 1
	return 0


# The statement about to start follows a single-statement head (if, else,
# while, for, with, do or a label) rather than a statement list.
int js_predicate_substatement(pg_token_stream* stream):
	int index = stream.index - 1
	if (index < 0): return 0
	char* text = stream.tokens[index].text
	if (strcmp(text, c"else") == 0 || strcmp(text, c"do") == 0): return 1
	if (strcmp(text, c")") == 0):
		int open = js_predicate_open(stream, index)
		if (open < 0): return 0
		if (js_predicate_for_head(stream, open)): return 1
		if (js_predicate_is(stream, open - 1, c"if") || js_predicate_is(stream, open - 1, c"with")): return 1
		# `do S while (x)` ends a statement; `while (x)` heads one.
		return js_predicate_is(stream, open - 1, c"while") && js_predicate_do_while(stream, open - 2) == 0
	if (strcmp(text, c":") != 0): return 0
	# A label, unless the colon ends a `case` or `default` clause head.
	if (js_predicate_is(stream, index - 1, c"default")): return 0
	index = index - 1
	while (index >= 0):
		text = stream.tokens[index].text
		int kind = js_predicate_kind(stream.tokens[index])
		if (kind == 2):
			index = js_predicate_open(stream, index)
			if (index < 0): return 0
		else if (kind == 1 || strcmp(text, c";") == 0 || strcmp(text, c":") == 0): return 1
		else if (strcmp(text, c"case") == 0): return 0
		else if (strcmp(text, c"else") == 0 || strcmp(text, c"do") == 0): return 1
		index = index - 1
	return 1


# `let` starts a LexicalDeclaration unless it sits in a single-statement
# position with a line break before the next token (other than `[`): there
# it is an identifier and ASI ends the expression statement, as in
# `if (x) let\ny` (sec-expression-statement; Node agrees).
int js_let_declaration(pg_token_stream* stream):
	if (js_predicate_next(stream, c"let") == 0): return 1
	if (strcmp(pg_token_stream_la(stream, 2).text, c"[") == 0): return 1
	stream.index = stream.index + 1
	int line_break = pg_token_stream_line_break_before(stream)
	stream.index = stream.index - 1
	return line_break == 0 || js_predicate_substatement(stream) == 0
