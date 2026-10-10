/*
Custom pg lexer matchers antlr4.pg needs that libs/extras/parser_generator/
lexer.w doesn't provide: a `[...]` character class and a balanced `{...}`
block. Kept here rather than in lexer.w since only this grammar uses them;
antlr4.pg's `import` line pulls this module into the generated parser.
*/


int pg_lexer_matcher_bracket_charset(char* input, int index):
	if (input[index] != '['):
		return 0
	int start = index
	index = index + 1
	while ((input[index] != 0) && (input[index] != ']')):
		if (input[index] == 92):
			index = index + 1
			if (input[index] == 0):
				return 0
		index = index + 1
	if (input[index] != ']'): return 0
	index = index + 1
	return index - start


# Returns the index right after the closing delimiter of a quoted run
# starting at `index` (which must point at the opening delimiter).
int pg_skip_quoted_run(char* input, int index, int delimiter):
	index = index + 1
	while ((input[index] != 0) && (input[index] != delimiter)):
		if (input[index] == 92):
			index = index + 1
			if (input[index] == 0):
				return index
		index = index + 1
	if (input[index] == delimiter):
		index = index + 1
	return index


# Return zero on unterminated blocks so normal lexical diagnostics identify
# the opening brace. Comments and quoted braces cannot alter nesting depth.
int pg_lexer_matcher_brace_block(char* input, int index):
	if (input[index] != '{'): return 0
	int start = index
	int depth = 1
	index = index + 1
	while (input[index] != 0):
		int c = input[index]
		if (c == '{'):
			depth = depth + 1
			index = index + 1
		else if (c == '}'):
			depth = depth - 1
			index = index + 1
			if (depth == 0):
				if (input[index] == '?'): index = index + 1
				return index - start
		else if ((c == 39) || (c == '"') || (c == 96)):
			index = pg_skip_quoted_run(input, index, c)
		else if ((c == '/') && (input[index + 1] == '/')):
			index = index + 2
			while ((input[index] != 0) && (input[index] != 10) && (input[index] != 13)):
				index = index + 1
		else if ((c == '/') && (input[index + 1] == '*')):
			index = index + 2
			while (input[index] != 0):
				if ((input[index] == '*') && (input[index + 1] == '/')): break
				index = index + 1
			if (input[index] == 0): return 0
			index = index + 2
		else:
			index = index + 1
	return 0
