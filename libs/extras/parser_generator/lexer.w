/*
Small lexer helpers shared by the ParserGenerator and generated lexers.
*/
import lib.lib


int pg_lexer_is_space(int c):
	return (c == ' ') | (c == '\n') | (c == '\r') | (c == '\t')


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


int pg_lexer_matcher_identifier(char* input, int index):
	if (pg_lexer_is_ident_start(input[index]) == 0):
		return 0
	int start = index
	while (pg_lexer_is_ident_part(input[index])):
		index = index + 1
	return index - start


int pg_lexer_matcher_any(char* input, int index):
	if (input[index] == 0):
		return 0
	return 1
