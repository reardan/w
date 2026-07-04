/*
Small lexer helpers shared by the ParserGenerator and generated lexers.
*/
import lib.lib


int pg_lexer_is_space(int c):
	return (c == ' ') | (c == '\n') | (c == '\r') | (c == '\t')


int pg_lexer_is_inline_space(int c):
	return (c == ' ') | (c == '\r')


int pg_lexer_is_alpha(int c):
	return ((c >= 'a') & (c <= 'z')) | ((c >= 'A') & (c <= 'Z')) | (c == '_')


int pg_lexer_is_digit(int c):
	return (c >= '0') & (c <= '9')


int pg_lexer_is_alnum(int c):
	return pg_lexer_is_alpha(c) | pg_lexer_is_digit(c)


int pg_lexer_is_ident_start(int c):
	return pg_lexer_is_alpha(c)


int pg_lexer_is_ident_part(int c):
	return pg_lexer_is_alnum(c)


int pg_lexer_matcher_letters(char* input, int index):
	if (pg_lexer_is_alpha(input[index]) == 0):
		return 0
	int start = index
	while (pg_lexer_is_alpha(input[index])):
		index = index + 1
	return index - start


int pg_lexer_matcher_digits(char* input, int index):
	if (pg_lexer_is_digit(input[index]) == 0):
		return 0
	int start = index
	while (pg_lexer_is_digit(input[index])):
		index = index + 1
	return index - start


int pg_lexer_matcher_number(char* input, int index):
	if (pg_lexer_is_digit(input[index]) == 0):
		return 0
	int start = index
	while (pg_lexer_is_alnum(input[index])):
		index = index + 1
	if (input[index] == '.'):
		index = index + 1
		while (pg_lexer_is_alnum(input[index])):
			index = index + 1
	if ((input[index] == 'e') | (input[index] == 'E')):
		index = index + 1
		if ((input[index] == '+') | (input[index] == '-')):
			index = index + 1
		while (pg_lexer_is_digit(input[index])):
			index = index + 1
	return index - start


int pg_lexer_matcher_identifier(char* input, int index):
	if (pg_lexer_is_ident_start(input[index]) == 0):
		return 0
	int start = index
	while (pg_lexer_is_ident_part(input[index])):
		index = index + 1
	return index - start


int pg_lexer_matcher_newline(char* input, int index):
	if (input[index] == 10):
		return 1
	return 0


int pg_lexer_matcher_tabs(char* input, int index):
	if (input[index] != 9):
		return 0
	int start = index
	while (input[index] == 9):
		index = index + 1
	return index - start


int pg_lexer_matcher_line_comment(char* input, int index):
	if (input[index] != '#'):
		return 0
	int start = index
	while ((input[index] != 0) & (input[index] != 10)):
		index = index + 1
	return index - start


int pg_lexer_matcher_block_comment(char* input, int index):
	if ((input[index] != '/') | (input[index + 1] != '*')):
		return 0
	int start = index
	index = index + 2
	while (input[index] != 0):
		if ((input[index] == '*') & (input[index + 1] == '/')):
			index = index + 2
			return index - start
		index = index + 1
	return index - start


int pg_lexer_matcher_c_line_comment(char* input, int index):
	if ((input[index] != '/') | (input[index + 1] != '/')):
		return 0
	int start = index
	while ((input[index] != 0) & (input[index] != 10)):
		index = index + 1
	return index - start


int pg_lexer_matcher_c_preprocessor(char* input, int index):
	if (input[index] != '#'):
		return 0
	int start = index
	while (input[index] != 0):
		if (input[index] == 10):
			return index - start
		if ((input[index] == 92) & (input[index + 1] == 10)):
			index = index + 2
		else:
			index = index + 1
	return index - start


int pg_lexer_c_string_prefix(char* input, int index):
	if ((input[index] == 'u') & (input[index + 1] == '8') & (input[index + 2] == '"')):
		return 2
	if (((input[index] == 'u') | (input[index] == 'U') | (input[index] == 'L')) & (input[index + 1] == '"')):
		return 1
	if (input[index] == '"'):
		return 0
	return -1


int pg_lexer_matcher_c_string(char* input, int index):
	int prefix = pg_lexer_c_string_prefix(input, index)
	if (prefix < 0):
		return 0
	int start = index
	index = index + prefix + 1
	while ((input[index] != 0) & (input[index] != '"') & (input[index] != 10)):
		if (input[index] == 92):
			index = index + 1
			if (input[index] == 0):
				return index - start
		index = index + 1
	if (input[index] == '"'):
		index = index + 1
	return index - start


int pg_lexer_c_char_prefix(char* input, int index):
	if (((input[index] == 'u') | (input[index] == 'U') | (input[index] == 'L')) & (input[index + 1] == 39)):
		return 1
	if (input[index] == 39):
		return 0
	return -1


int pg_lexer_matcher_c_char_literal(char* input, int index):
	int prefix = pg_lexer_c_char_prefix(input, index)
	if (prefix < 0):
		return 0
	int start = index
	index = index + prefix + 1
	while ((input[index] != 0) & (input[index] != 39) & (input[index] != 10)):
		if (input[index] == 92):
			index = index + 1
			if (input[index] == 0):
				return index - start
		index = index + 1
	if (input[index] == 39):
		index = index + 1
	return index - start


int pg_lexer_matcher_c_number(char* input, int index):
	if ((pg_lexer_is_digit(input[index]) == 0) &
			((input[index] != '.') | (pg_lexer_is_digit(input[index + 1]) == 0))):
		return 0
	int start = index
	if (input[index] == '.'):
		index = index + 1
	while (pg_lexer_is_alnum(input[index]) | (input[index] == '.')):
		index = index + 1
	if ((input[index] == '+') | (input[index] == '-')):
		if ((input[index - 1] == 'e') | (input[index - 1] == 'E') | (input[index - 1] == 'p') | (input[index - 1] == 'P')):
			index = index + 1
			while (pg_lexer_is_alnum(input[index]) | (input[index] == '.')):
				index = index + 1
	return index - start


int pg_lexer_matcher_string(char* input, int index):
	int prefix = 0
	if (((input[index] == 's') | (input[index] == 'c')) & (input[index + 1] == '"')):
		prefix = 1
	else if (input[index] != '"'):
		return 0
	int start = index
	index = index + prefix + 1
	while ((input[index] != 0) & (input[index] != '"')):
		if (input[index] == 92):
			index = index + 1
			if (input[index] == 0):
				return index - start
		index = index + 1
	if (input[index] == '"'):
		index = index + 1
	return index - start


int pg_lexer_matcher_char_literal(char* input, int index):
	if (input[index] != 39):
		return 0
	int start = index
	index = index + 1
	while ((input[index] != 0) & (input[index] != 39)):
		if (input[index] == 92):
			index = index + 1
			if (input[index] == 0):
				return index - start
		index = index + 1
	if (input[index] == 39):
		index = index + 1
	return index - start


int pg_lexer_matcher_operator(char* input, int index):
	int c = input[index]
	if ((c == '<') | (c == '=') | (c == '>') | (c == '|') | (c == '&') | (c == '!')):
		int start = index
		while ((input[index] == '<') | (input[index] == '=') | (input[index] == '>') |
				(input[index] == '|') | (input[index] == '&') | (input[index] == '!')):
			index = index + 1
		return index - start
	return 0


int pg_lexer_matcher_any(char* input, int index):
	if (input[index] == 0):
		return 0
	return 1
