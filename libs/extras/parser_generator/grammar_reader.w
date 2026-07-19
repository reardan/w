/*
ParserGenerator grammar reader.

This reader is deliberately separate from compiler.tokenizer. It accepts a
small grammar format suitable for generated recursive-descent parsers.
*/
import lib.lib
import structures.string
import libs.extras.parser_generator.token
import libs.extras.parser_generator.lexer
import libs.extras.parser_generator.diagnostics
import libs.extras.parser_generator.grammar_model


struct pg_grammar_reader:
	char* input
	char* filename
	int index
	int line
	int column
	int token_kind
	char* token
	int token_line
	int token_column
	pg_diagnostics* diagnostics


int pg_reader_token_eof():
	return 0


int pg_reader_token_name():
	return 1


int pg_reader_token_string():
	return 2


int pg_reader_token_symbol():
	return 3


int pg_reader_token_charset():
	return 4


pg_grammar_reader* pg_reader_new(char* input, char* filename, pg_diagnostics* diagnostics):
	pg_grammar_reader* reader = new pg_grammar_reader()
	reader.input = input
	reader.filename = filename
	reader.index = 0
	reader.line = 1
	reader.column = 1
	reader.token_kind = pg_reader_token_eof()
	reader.token = c""
	reader.token_line = 1
	reader.token_column = 1
	reader.diagnostics = diagnostics
	return reader


void pg_reader_step(pg_grammar_reader* reader):
	if (reader.input[reader.index] == 10):
		reader.line = reader.line + 1
		reader.column = 1
	else:
		reader.column = reader.column + 1
	reader.index = reader.index + 1


void pg_reader_skip_ws(pg_grammar_reader* reader):
	int running = 1
	while (running):
		running = 0
		while (pg_lexer_is_space(reader.input[reader.index])):
			pg_reader_step(reader)
			running = 1
		if (reader.input[reader.index] == '#'):
			while ((reader.input[reader.index] != 0) && (reader.input[reader.index] != 10)):
				pg_reader_step(reader)
			running = 1


void pg_reader_error(pg_grammar_reader* reader, char* message, char* expected):
	pg_diagnostics_add(reader.diagnostics, reader.filename, reader.token_line, reader.token_column, message, expected, reader.token)


char* pg_reader_string_token(pg_grammar_reader* reader):
	string_builder* out = string_new()
	pg_reader_step(reader)
	while ((reader.input[reader.index] != 0) && (reader.input[reader.index] != '"')):
		int c = reader.input[reader.index]
		if (c == 92):
			pg_reader_step(reader)
			c = reader.input[reader.index]
			if (c == 'n'):
				c = 10
			else if (c == 't'):
				c = 9
			else if (c == 'r'):
				c = 13
		string_append_char(out, c)
		pg_reader_step(reader)
	if (reader.input[reader.index] == '"'):
		pg_reader_step(reader)
	char* text = out.data
	free(out)
	return text


char* pg_reader_charset_token(pg_grammar_reader* reader):
	int start = reader.index
	pg_reader_step(reader)
	while ((reader.input[reader.index] != 0) && (reader.input[reader.index] != 10)):
		int c = reader.input[reader.index]
		pg_reader_step(reader)
		if (c == 92):
			if ((reader.input[reader.index] != 0) && (reader.input[reader.index] != 10)):
				pg_reader_step(reader)
		else if (c == ']'):
			break
	return pg_substr(reader.input, start, reader.index - start)


void pg_reader_next(pg_grammar_reader* reader):
	pg_reader_skip_ws(reader)
	reader.token_line = reader.line
	reader.token_column = reader.column
	int c = reader.input[reader.index]
	if (c == 0):
		reader.token_kind = pg_reader_token_eof()
		reader.token = c""
		return
	if (pg_lexer_is_ident_start(c)):
		int start = reader.index
		while (pg_lexer_is_ident_part(reader.input[reader.index])):
			pg_reader_step(reader)
		reader.token_kind = pg_reader_token_name()
		reader.token = pg_substr(reader.input, start, reader.index - start)
		return
	if (c == '"'):
		reader.token_kind = pg_reader_token_string()
		reader.token = pg_reader_string_token(reader)
		return
	if (c == '['):
		reader.token_kind = pg_reader_token_charset()
		reader.token = pg_reader_charset_token(reader)
		return
	reader.token_kind = pg_reader_token_symbol()
	reader.token = pg_substr(reader.input, reader.index, 1)
	pg_reader_step(reader)


int pg_reader_is_name(pg_grammar_reader* reader, char* name):
	if (reader.token_kind != pg_reader_token_name()):
		return 0
	return strcmp(reader.token, name) == 0


int pg_reader_is_top_level(pg_grammar_reader* reader):
	if (reader.token_kind != pg_reader_token_name()):
		return 0
	if (strcmp(reader.token, c"parser") == 0):
		return 1
	if (strcmp(reader.token, c"mode") == 0):
		return 1
	if (strcmp(reader.token, c"import") == 0):
		return 1
	if (strcmp(reader.token, c"token") == 0):
		return 1
	if (strcmp(reader.token, c"skip") == 0):
		return 1
	if (strcmp(reader.token, c"fragment") == 0):
		return 1
	if (strcmp(reader.token, c"literal") == 0):
		return 1
	if (strcmp(reader.token, c"start") == 0):
		return 1
	if (strcmp(reader.token, c"rule") == 0):
		return 1
	if (strcmp(reader.token, c"recover") == 0):
		return 1
	return 0


int pg_reader_accept_symbol(pg_grammar_reader* reader, char* symbol):
	if (reader.token_kind != pg_reader_token_symbol()):
		return 0
	if (strcmp(reader.token, symbol) != 0):
		return 0
	pg_reader_next(reader)
	return 1


int pg_reader_expect_symbol(pg_grammar_reader* reader, char* symbol):
	if (pg_reader_accept_symbol(reader, symbol)):
		return 1
	pg_reader_error(reader, c"grammar parse error", symbol)
	return 0


char* pg_reader_take_name(pg_grammar_reader* reader):
	if (reader.token_kind != pg_reader_token_name()):
		pg_reader_error(reader, c"grammar parse error", c"name")
		return 0
	char* name = strclone(reader.token)
	pg_reader_next(reader)
	return name


char* pg_reader_take_string(pg_grammar_reader* reader):
	if (reader.token_kind != pg_reader_token_string()):
		pg_reader_error(reader, c"grammar parse error", c"string")
		return 0
	char* text = strclone(reader.token)
	pg_reader_next(reader)
	return text


# "a.b.c" for the "import <dotted.path>" directive (issue #329 milestone 4).
char* pg_reader_take_dotted_name(pg_grammar_reader* reader):
	string_builder* out = string_new()
	char* first = pg_reader_take_name(reader)
	if (first == 0):
		free(out.data)
		free(out)
		return 0
	string_append(out, first)
	free(first)
	while ((reader.token_kind == pg_reader_token_symbol()) && (strcmp(reader.token, c".") == 0)):
		pg_reader_next(reader)
		char* part = pg_reader_take_name(reader)
		if (part == 0):
			free(out.data)
			free(out)
			return 0
		string_append_char(out, '.')
		string_append(out, part)
		free(part)
	char* text = out.data
	free(out)
	return text


char* pg_trim(char* text):
	int start = 0
	while (pg_lexer_is_space(text[start])):
		start = start + 1
	int end = strlen(text)
	while ((end > start) && pg_lexer_is_space(text[end - 1])):
		end = end - 1
	return pg_substr(text, start, end - start)


# Raw byte-level scan of an action ({ code }) or predicate (&{ expr }) block.
# Called right after the opening '{' has been consumed as a token (so
# reader.index already sits on the first byte inside the braces); this
# bypasses the grammar tokenizer entirely so the verbatim W code inside is
# preserved exactly, including punctuation the grammar's own tokenizer
# would otherwise choke on. Braces are counted so a nested block (an
# action calling something with a "{...}" argument, however unlikely)
# doesn't end the scan early, and '"'/'\'' delimited literals are skipped
# whole so a brace or backslash inside a string/char literal in the action
# code can't desync the count. Returns 0 (after recording a diagnostic) on
# an unterminated block.
char* pg_reader_read_brace_block(pg_grammar_reader* reader):
	int start = reader.index
	int depth = 1
	while (reader.input[reader.index] != 0):
		int c = reader.input[reader.index]
		if ((c == '"') || (c == 39)):
			int quote = c
			pg_reader_step(reader)
			while ((reader.input[reader.index] != 0) && (reader.input[reader.index] != quote)):
				if (reader.input[reader.index] == 92):
					pg_reader_step(reader)
					if (reader.input[reader.index] != 0):
						pg_reader_step(reader)
				else:
					pg_reader_step(reader)
			if (reader.input[reader.index] == quote):
				pg_reader_step(reader)
		else if (c == '#'):
			# A '#' comment runs to end of line and is opaque W text: an
			# apostrophe ("don't") or brace inside it must not start a
			# literal skip or move the depth count, or the scan desyncs
			# and swallows following grammar text.
			while ((reader.input[reader.index] != 0) && (reader.input[reader.index] != 10)):
				pg_reader_step(reader)
		else if (c == '{'):
			depth = depth + 1
			pg_reader_step(reader)
		else if (c == '}'):
			depth = depth - 1
			if (depth == 0):
				break
			pg_reader_step(reader)
		else:
			pg_reader_step(reader)
	if (reader.input[reader.index] != '}'):
		pg_reader_error(reader, c"unterminated action block", c"}")
		return 0
	char* raw = pg_substr(reader.input, start, reader.index - start)
	pg_reader_step(reader)
	char* text = pg_trim(raw)
	free(raw)
	return text


int pg_reader_matcher_primary_starts(pg_grammar_reader* reader, int line):
	if (reader.token_line != line):
		return 0
	if (reader.token_kind == pg_reader_token_name()):
		return 1
	if (reader.token_kind == pg_reader_token_string()):
		return 1
	if (reader.token_kind == pg_reader_token_charset()):
		return 1
	if (reader.token_kind == pg_reader_token_symbol()):
		return strcmp(reader.token, c"(") == 0
	return 0


int pg_reader_matcher_ascii(pg_grammar_reader* reader, char* text):
	int i = 0
	while (text[i] != 0):
		if ((text[i] & 255) >= 128):
			pg_reader_error(reader, c"matcher expressions are ASCII only", c"ASCII byte")
			return 0
		i = i + 1
	return 1


int pg_reader_charset_char(pg_grammar_reader* reader, char* text, int* indexp, int limit):
	int index = indexp[0]
	if (index >= limit):
		pg_reader_error(reader, c"invalid character class", c"character")
		return -1
	int c = text[index] & 255
	index = index + 1
	if (c == 92):
		if (index >= limit):
			pg_reader_error(reader, c"invalid character class escape", c"escaped character")
			return -1
		c = text[index] & 255
		index = index + 1
		if (c == 'n'):
			c = 10
		else if (c == 'r'):
			c = 13
		else if (c == 't'):
			c = 9
	if ((c <= 0) || (c >= 128)):
		pg_reader_error(reader, c"matcher expressions are ASCII only", c"ASCII byte")
		return -1
	indexp[0] = index
	return c


pg_match_expr* pg_reader_parse_matcher_alternation(pg_grammar_reader* reader, int line);


pg_match_expr* pg_reader_parse_matcher_primary(pg_grammar_reader* reader, int line):
	if (pg_reader_matcher_primary_starts(reader, line) == 0):
		pg_reader_error(reader, c"matcher expression parse error", c"string, character class, reference or group")
		return 0
	int token_line = reader.token_line
	int token_column = reader.token_column
	if (reader.token_kind == pg_reader_token_name()):
		char* name = pg_reader_take_name(reader)
		return pg_match_expr_text_new(pg_match_expr_reference_kind(), name, token_line, token_column)
	if (reader.token_kind == pg_reader_token_string()):
		if (pg_reader_matcher_ascii(reader, reader.token) == 0):
			return 0
		char* text = pg_reader_take_string(reader)
		return pg_match_expr_text_new(pg_match_expr_string_kind(), text, token_line, token_column)
	if (reader.token_kind == pg_reader_token_charset()):
		char* text = reader.token
		int length = strlen(text)
		if ((length < 2) || (text[length - 1] != ']')):
			pg_reader_error(reader, c"unterminated character class", c"]")
			return 0
		char* charset = malloc(128)
		int i = 0
		while (i < 128):
			charset[i] = 0
			i = i + 1
		int index = 1
		int negate = 0
		if ((index < length - 1) && (text[index] == '^')):
			negate = 1
			index = index + 1
		while (index < length - 1):
			int first = pg_reader_charset_char(reader, text, &index, length - 1)
			if (first < 0):
				free(charset)
				return 0
			if ((index < length - 2) && (text[index] == '-')):
				index = index + 1
				int last = pg_reader_charset_char(reader, text, &index, length - 1)
				if (last < first):
					pg_reader_error(reader, c"invalid character class range", c"ascending range")
					free(charset)
					return 0
				int c = first
				while (c <= last):
					charset[c] = 1
					c = c + 1
			else:
				charset[first] = 1
		if (negate):
			i = 1
			while (i < 128):
				charset[i] = charset[i] == 0
				i = i + 1
		pg_match_expr* expression = pg_match_expr_charset_new(charset, token_line, token_column)
		free(charset)
		pg_reader_next(reader)
		return expression
	pg_reader_next(reader)
	pg_match_expr* expression = pg_reader_parse_matcher_alternation(reader, line)
	if (expression == 0):
		return 0
	if (reader.token_line != line):
		pg_reader_error(reader, c"matcher expression parse error", c")")
		return 0
	if (pg_reader_accept_symbol(reader, c")") == 0):
		pg_reader_error(reader, c"matcher expression parse error", c")")
		return 0
	return expression


pg_match_expr* pg_reader_parse_matcher_postfix(pg_grammar_reader* reader, int line):
	pg_match_expr* expression = pg_reader_parse_matcher_primary(reader, line)
	if (expression == 0):
		return 0
	if ((reader.token_line == line) & (reader.token_kind == pg_reader_token_symbol())):
		int kind = 0
		if (strcmp(reader.token, c"?") == 0):
			kind = pg_match_expr_optional_kind()
		else if (strcmp(reader.token, c"*") == 0):
			kind = pg_match_expr_zero_or_more_kind()
		else if (strcmp(reader.token, c"+") == 0):
			kind = pg_match_expr_one_or_more_kind()
		if (kind != 0):
			int token_line = reader.token_line
			int token_column = reader.token_column
			pg_reader_next(reader)
			expression = pg_match_expr_unary_new(kind, expression, token_line, token_column)
	return expression


pg_match_expr* pg_reader_parse_matcher_sequence(pg_grammar_reader* reader, int line):
	if (pg_reader_matcher_primary_starts(reader, line) == 0):
		pg_reader_error(reader, c"matcher expression parse error", c"matcher term")
		return 0
	pg_match_expr* sequence = pg_match_expr_new(pg_match_expr_sequence_kind(), reader.token_line, reader.token_column)
	while (pg_reader_matcher_primary_starts(reader, line)):
		pg_match_expr* child = pg_reader_parse_matcher_postfix(reader, line)
		if (child == 0):
			return 0
		pg_match_expr_add(sequence, child)
	if (sequence.children.length == 1):
		pg_match_expr* child = sequence.children[0]
		list_free[pg_match_expr*](sequence.children)
		free(sequence)
		return child
	return sequence


pg_match_expr* pg_reader_parse_matcher_alternation(pg_grammar_reader* reader, int line):
	pg_match_expr* first = pg_reader_parse_matcher_sequence(reader, line)
	if (first == 0):
		return 0
	if ((reader.token_line != line) | (reader.token_kind != pg_reader_token_symbol()) | (strcmp(reader.token, c"|") != 0)):
		return first
	pg_match_expr* alternation = pg_match_expr_new(pg_match_expr_alternation_kind(), first.line, first.column)
	pg_match_expr_add(alternation, first)
	while ((reader.token_line == line) & (reader.token_kind == pg_reader_token_symbol()) & (strcmp(reader.token, c"|") == 0)):
		pg_reader_next(reader)
		pg_match_expr* child = pg_reader_parse_matcher_sequence(reader, line)
		if (child == 0):
			return 0
		pg_match_expr_add(alternation, child)
	return alternation


pg_match_expr* pg_reader_parse_matcher(pg_grammar_reader* reader, int line):
	if ((reader.token_kind == pg_reader_token_eof()) | (reader.token_line != line)):
		pg_reader_error(reader, c"matcher expression parse error", c"matcher expression")
		return 0
	pg_match_expr* expression = pg_reader_parse_matcher_alternation(reader, line)
	if (expression == 0):
		return 0
	if (reader.token_line == line):
		pg_reader_error(reader, c"matcher expression parse error", c"end of directive")
		return 0
	return expression


int pg_reader_matcher_path_contains(list[char*] path, char* name):
	int i = 0
	while (i < path.length):
		if (strcmp(path[i], name) == 0):
			return 1
		i = i + 1
	return 0


int pg_reader_matcher_nullable(pg_grammar_reader* reader, pg_grammar* grammar, pg_match_expr* expression, list[char*] path):
	if (expression.kind == pg_match_expr_string_kind()):
		return strlen(expression.text) == 0
	if (expression.kind == pg_match_expr_charset_kind()):
		return 0
	if (expression.kind == pg_match_expr_reference_kind()):
		if (pg_reader_matcher_path_contains(path, expression.text)):
			pg_diagnostics_add(reader.diagnostics, reader.filename, expression.line, expression.column, c"cyclic matcher reference", c"acyclic token or fragment", expression.text)
			return -1
		pg_token_def* token = pg_grammar_find_token(grammar, expression.text)
		if (token != 0):
			if (token.expression == 0):
				return 0
			path.push(token.name)
			int nullable = pg_reader_matcher_nullable(reader, grammar, token.expression, path)
			path.pop()
			return nullable
		pg_fragment_def* fragment = pg_grammar_find_fragment(grammar, expression.text)
		if (fragment == 0):
			pg_diagnostics_add(reader.diagnostics, reader.filename, expression.line, expression.column, c"unknown matcher reference", c"token or fragment", expression.text)
			return -1
		path.push(fragment.name)
		int nullable = pg_reader_matcher_nullable(reader, grammar, fragment.expression, path)
		path.pop()
		return nullable
	if (expression.kind == pg_match_expr_sequence_kind()):
		int i = 0
		while (i < expression.children.length):
			int nullable = pg_reader_matcher_nullable(reader, grammar, expression.children[i], path)
			if (nullable <= 0):
				return nullable
			i = i + 1
		return 1
	if (expression.kind == pg_match_expr_alternation_kind()):
		int i = 0
		while (i < expression.children.length):
			int nullable = pg_reader_matcher_nullable(reader, grammar, expression.children[i], path)
			if (nullable < 0):
				return -1
			if (nullable):
				return 1
			i = i + 1
		return 0
	if ((expression.kind == pg_match_expr_optional_kind()) | (expression.kind == pg_match_expr_zero_or_more_kind())):
		return 1
	return pg_reader_matcher_nullable(reader, grammar, expression.children[0], path)


int pg_reader_validate_matcher_expression(pg_grammar_reader* reader, pg_grammar* grammar, pg_match_expr* expression, list[char*] path):
	if (expression.kind == pg_match_expr_reference_kind()):
		return pg_reader_matcher_nullable(reader, grammar, expression, path) >= 0
	if ((expression.kind == pg_match_expr_zero_or_more_kind()) | (expression.kind == pg_match_expr_one_or_more_kind())):
		int nullable = pg_reader_matcher_nullable(reader, grammar, expression.children[0], path)
		if (nullable < 0):
			return 0
		if (nullable):
			pg_diagnostics_add(reader.diagnostics, reader.filename, expression.line, expression.column, c"repeated matcher can match empty", c"non-empty matcher", c"")
			return 0
	int i = 0
	while (i < expression.children.length):
		if (pg_reader_validate_matcher_expression(reader, grammar, expression.children[i], path) == 0):
			return 0
		i = i + 1
	return 1


int pg_reader_validate_matcher_definition(pg_grammar_reader* reader, pg_grammar* grammar, char* name, pg_match_expr* expression):
	list[char*] path = new list[char*]
	path.push(name)
	int valid = pg_reader_validate_matcher_expression(reader, grammar, expression, path)
	list_free[char*](path)
	return valid


int pg_reader_validate_matchers(pg_grammar_reader* reader, pg_grammar* grammar):
	int i = 0
	while (i < grammar.tokens.length):
		pg_token_def* token = grammar.tokens[i]
		if (token.expression != 0):
			if (pg_reader_validate_matcher_definition(reader, grammar, token.name, token.expression) == 0):
				return 0
		i = i + 1
	i = 0
	while (i < grammar.skips.length):
		pg_token_def* skip = grammar.skips[i]
		if (skip.expression != 0):
			if (pg_reader_validate_matcher_definition(reader, grammar, skip.name, skip.expression) == 0):
				return 0
		i = i + 1
	i = 0
	while (i < grammar.fragments.length):
		pg_fragment_def* fragment = grammar.fragments[i]
		if (pg_reader_validate_matcher_definition(reader, grammar, fragment.name, fragment.expression) == 0):
			return 0
		i = i + 1
	return 1


int pg_reader_is_symbol(pg_grammar_reader* reader, char* symbol):
	if (reader.token_kind != pg_reader_token_symbol()):
		return 0
	return strcmp(reader.token, symbol) == 0


int pg_text_contains_newline(char* text):
	int i = 0
	while (text[i] != 0):
		if (text[i] == 10):
			return 1
		i = i + 1
	return 0


void pg_reader_parse_rule_body(pg_grammar_reader* reader, pg_rule* rule):
	pg_alternative* alternative = pg_alternative_new()
	while (reader.token_kind != pg_reader_token_eof()):
		if (pg_reader_is_top_level(reader)):
			break
		if (pg_reader_accept_symbol(reader, c"|")):
			pg_rule_add_alternative(rule, alternative)
			alternative = pg_alternative_new()
		else if (pg_reader_is_symbol(reader, c"{")):
			# reader.index already sits on the first byte after '{' --
			# read_brace_block scans raw bytes, so do NOT tokenize past
			# it with pg_reader_next() first (issue #329 milestone 4).
			char* code = pg_reader_read_brace_block(reader)
			if (code == 0):
				return
			pg_alternative_add_term(alternative, pg_term_new_action(code))
			free(code)
			pg_reader_next(reader)
		else if (pg_reader_is_symbol(reader, c"&")):
			if (alternative.terms.length != 0):
				pg_reader_error(reader, c"semantic predicate must be the first term of an alternative", c"&{ expr } at the start of the alternative")
				return
			pg_reader_next(reader)
			if (pg_reader_is_symbol(reader, c"{") == 0):
				pg_reader_error(reader, c"grammar parse error", c"&{ expr }")
				return
			char* code = pg_reader_read_brace_block(reader)
			if (code == 0):
				return
			if (pg_text_contains_newline(code)):
				pg_reader_error(reader, c"semantic predicate must be a single line", c"&{ expr } without a newline")
				free(code)
				return
			pg_alternative_add_term(alternative, pg_term_new_predicate(code))
			free(code)
			pg_reader_next(reader)
		else:
			char* name = pg_reader_take_name(reader)
			if (name == 0):
				return
			int modifier = 0
			if (reader.token_kind == pg_reader_token_symbol()):
				if ((strcmp(reader.token, c"?") == 0) | (strcmp(reader.token, c"*") == 0) | (strcmp(reader.token, c"+") == 0)):
					modifier = reader.token[0]
					pg_reader_next(reader)
			pg_alternative_add_term(alternative, pg_term_new(name, modifier))
	pg_rule_add_alternative(rule, alternative)


pg_grammar* pg_grammar_read(char* input, char* filename, pg_diagnostics* diagnostics):
	pg_grammar_reader* reader = pg_reader_new(input, filename, diagnostics)
	pg_reader_next(reader)
	if (pg_reader_is_name(reader, c"parser") == 0):
		pg_reader_error(reader, c"grammar must start with parser directive", c"parser")
		return 0
	pg_reader_next(reader)
	char* parser_name = pg_reader_take_name(reader)
	if (parser_name == 0):
		return 0
	pg_grammar* grammar = pg_grammar_new(parser_name)
	while (reader.token_kind != pg_reader_token_eof()):
		if (pg_reader_is_name(reader, c"mode")):
			pg_reader_next(reader)
			char* name = pg_reader_take_name(reader)
			if (name == 0):
				return 0
			if (strcmp(name, c"streaming") == 0):
				grammar.mode = pg_grammar_mode_streaming()
			else if (strcmp(name, c"ast") == 0):
				grammar.mode = pg_grammar_mode_ast()
			else:
				pg_reader_error(reader, c"unknown parser mode", c"streaming or ast")
				free(name)
				return 0
			free(name)
		else if (pg_reader_is_name(reader, c"import")):
			pg_reader_next(reader)
			char* path = pg_reader_take_dotted_name(reader)
			if (path == 0):
				return 0
			pg_grammar_add_import(grammar, path)
			free(path)
		else if (pg_reader_is_name(reader, c"token")):
			pg_reader_next(reader)
			char* name = pg_reader_take_name(reader)
			if (name == 0):
				return 0
			if ((reader.token_kind == pg_reader_token_symbol()) & (strcmp(reader.token, c"=") == 0)):
				int line = reader.token_line
				pg_reader_next(reader)
				pg_match_expr* expression = pg_reader_parse_matcher(reader, line)
				if (expression == 0):
					return 0
				pg_grammar_add_token_expression(grammar, name, expression)
			else:
				char* matcher = pg_reader_take_name(reader)
				if (matcher == 0):
					return 0
				pg_grammar_add_token(grammar, name, matcher)
		else if (pg_reader_is_name(reader, c"skip")):
			pg_reader_next(reader)
			char* name = pg_reader_take_name(reader)
			if (name == 0):
				return 0
			if ((reader.token_kind == pg_reader_token_symbol()) & (strcmp(reader.token, c"=") == 0)):
				int line = reader.token_line
				pg_reader_next(reader)
				pg_match_expr* expression = pg_reader_parse_matcher(reader, line)
				if (expression == 0):
					return 0
				pg_grammar_add_skip_expression(grammar, name, expression)
			else:
				char* matcher = pg_reader_take_name(reader)
				if (matcher == 0):
					return 0
				pg_grammar_add_skip(grammar, name, matcher)
		else if (pg_reader_is_name(reader, c"fragment")):
			pg_reader_next(reader)
			char* name = pg_reader_take_name(reader)
			if (name == 0):
				return 0
			if ((reader.token_kind != pg_reader_token_symbol()) | (strcmp(reader.token, c"=") != 0)):
				pg_reader_error(reader, c"grammar parse error", c"=")
				return 0
			int line = reader.token_line
			pg_reader_next(reader)
			pg_match_expr* expression = pg_reader_parse_matcher(reader, line)
			if (expression == 0):
				return 0
			pg_grammar_add_fragment(grammar, name, expression)
		else if (pg_reader_is_name(reader, c"literal")):
			pg_reader_next(reader)
			char* name = pg_reader_take_name(reader)
			char* text = pg_reader_take_string(reader)
			if ((name == 0) || (text == 0)):
				return 0
			pg_grammar_add_literal(grammar, name, text)
		else if (pg_reader_is_name(reader, c"start")):
			pg_reader_next(reader)
			char* name = pg_reader_take_name(reader)
			if (name == 0):
				return 0
			if (grammar.start_rule != 0):
				free(grammar.start_rule)
			grammar.start_rule = strclone(name)
		else if (pg_reader_is_name(reader, c"rule")):
			pg_reader_next(reader)
			char* name = pg_reader_take_name(reader)
			if (name == 0):
				return 0
			if (pg_reader_expect_symbol(reader, c"=") == 0):
				return 0
			pg_rule* rule = pg_grammar_add_rule(grammar, name)
			pg_reader_parse_rule_body(reader, rule)
		else if (pg_reader_is_name(reader, c"recover")):
			pg_reader_next(reader)
			char* name = pg_reader_take_name(reader)
			char* sync = pg_reader_take_name(reader)
			if ((name == 0) || (sync == 0)):
				return 0
			pg_recover_def* recover = pg_grammar_add_recover(grammar, name, sync)
			while ((reader.token_kind == pg_reader_token_name()) & (pg_reader_is_top_level(reader) == 0)):
				pg_recover_add_skip(recover, reader.token)
				pg_reader_next(reader)
		else:
			pg_reader_error(reader, c"unknown grammar directive", c"mode, token, skip, fragment, literal, start or rule")
			return 0
	if (grammar.rules.length == 0):
		pg_reader_error(reader, c"grammar has no rules", c"rule")
		return 0
	if (pg_grammar_find_rule(grammar, grammar.start_rule) == 0):
		pg_reader_error(reader, c"start rule is not defined", grammar.start_rule)
		return 0
	int r = 0
	while (r < grammar.recovers.length):
		pg_recover_def* recover = grammar.recovers[r]
		if (pg_grammar_find_rule(grammar, recover.rule_name) == 0):
			pg_reader_error(reader, c"recover rule is not defined", recover.rule_name)
			return 0
		if (pg_grammar_token_kind(grammar, recover.sync_token) <= 0):
			pg_reader_error(reader, c"recover sync must be a token or literal", recover.sync_token)
			return 0
		int s = 0
		while (s < recover.skip_tokens.length):
			char* skip_name = recover.skip_tokens[s]
			if (pg_grammar_token_kind(grammar, skip_name) <= 0):
				pg_reader_error(reader, c"recover skip must be a token or literal", skip_name)
				return 0
			s = s + 1
		r = r + 1
	if (pg_reader_validate_matchers(reader, grammar) == 0):
		return 0
	return grammar
