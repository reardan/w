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
				return index - start
		index = index + 1
	if (input[index] == ']'):
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


# Consumes a balanced {...} block (options{}/tokens{}/channels{}/@header{}
# bodies, and rule-body actions `{...}` / predicates `{...}?`), skipping
# quoted runs inside it so an embedded '{'/'}'/quote can't unbalance the
# scan. A trailing '?' right after the closing brace (a semantic predicate)
# is swallowed too, so the grammar never sees a stray '?' token for it.
int pg_lexer_matcher_brace_block(char* input, int index):
	if (input[index] != '{'):
		return 0
	int start = index
	int depth = 1
	index = index + 1
	while ((input[index] != 0) && (depth > 0)):
		int c = input[index]
		if (c == '{'):
			depth = depth + 1
			index = index + 1
		else if (c == '}'):
			depth = depth - 1
			index = index + 1
		else if (c == 39):
			index = pg_skip_quoted_run(input, index, 39)
		else if (c == '"'):
			index = pg_skip_quoted_run(input, index, '"')
		else:
			index = index + 1
	if (input[index] == '?'):
		index = index + 1
	return index - start
