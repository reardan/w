/*
Phase 1-3-ish preprocessing lexer.
*/
import lib.lib
import libs.extras.c_preprocessor.pp_token


char* cpp_substr(char* input, int start, int end):
	char* text = malloc(end - start + 1)
	int i = 0
	while (start + i < end):
		text[i] = input[start + i]
		i = i + 1
	text[i] = 0
	return text


int cpp_is_ident_start(int c):
	return ((c >= 'a') & (c <= 'z')) | ((c >= 'A') & (c <= 'Z')) | (c == '_')


int cpp_is_digit(int c):
	return (c >= '0') & (c <= '9')


int cpp_is_ident_part(int c):
	return cpp_is_ident_start(c) | cpp_is_digit(c)


int cpp_is_inline_space(int c):
	return (c == ' ') | (c == 9) | (c == 13)


int cpp_is_punct_char(int c):
	if ((c == '[') | (c == ']') | (c == '(') | (c == ')') | (c == '{') | (c == '}')):
		return 1
	if ((c == '.') | (c == '-') | (c == '+') | (c == '&') | (c == '*') | (c == '~')):
		return 1
	if ((c == '!') | (c == '/') | (c == '%') | (c == '<') | (c == '>') | (c == '^')):
		return 1
	if ((c == '|') | (c == '?') | (c == ':') | (c == ';') | (c == '=') | (c == ',')):
		return 1
	if (c == '#'):
		return 1
	return 0


int cpp_match_literal(char* input, int index, char* text):
	int i = 0
	while (text[i] != 0):
		if (input[index + i] != text[i]):
			return 0
		i = i + 1
	return 1


int cpp_punct_length(char* input, int index):
	if (cpp_match_literal(input, index, c"...")):
		return 3
	if (cpp_match_literal(input, index, c"<<=")):
		return 3
	if (cpp_match_literal(input, index, c">>=")):
		return 3
	if (cpp_match_literal(input, index, c"##")):
		return 2
	if (cpp_match_literal(input, index, c"++")):
		return 2
	if (cpp_match_literal(input, index, c"--")):
		return 2
	if (cpp_match_literal(input, index, c"->")):
		return 2
	if (cpp_match_literal(input, index, c"<<")):
		return 2
	if (cpp_match_literal(input, index, c">>")):
		return 2
	if (cpp_match_literal(input, index, c"<=")):
		return 2
	if (cpp_match_literal(input, index, c">=")):
		return 2
	if (cpp_match_literal(input, index, c"==")):
		return 2
	if (cpp_match_literal(input, index, c"!=")):
		return 2
	if (cpp_match_literal(input, index, c"&&")):
		return 2
	if (cpp_match_literal(input, index, c"||")):
		return 2
	if (cpp_match_literal(input, index, c"+=")):
		return 2
	if (cpp_match_literal(input, index, c"-=")):
		return 2
	if (cpp_match_literal(input, index, c"*=")):
		return 2
	if (cpp_match_literal(input, index, c"/=")):
		return 2
	if (cpp_match_literal(input, index, c"%=")):
		return 2
	if (cpp_match_literal(input, index, c"&=")):
		return 2
	if (cpp_match_literal(input, index, c"^=")):
		return 2
	if (cpp_match_literal(input, index, c"|=")):
		return 2
	if (cpp_is_punct_char(input[index])):
		return 1
	return 0


int cpp_string_prefix_length(char* input, int index):
	if ((input[index] == 'u') & (input[index + 1] == '8') & (input[index + 2] == '"')):
		return 2
	if (((input[index] == 'u') | (input[index] == 'U') | (input[index] == 'L')) & (input[index + 1] == '"')):
		return 1
	if (input[index] == '"'):
		return 0
	return -1


int cpp_char_prefix_length(char* input, int index):
	if (((input[index] == 'u') | (input[index] == 'U') | (input[index] == 'L')) & (input[index + 1] == 39)):
		return 1
	if (input[index] == 39):
		return 0
	return -1


int cpp_quoted_length(char* input, int index, int quote):
	int start = index
	index = index + 1
	while ((input[index] != 0) & (input[index] != quote) & (input[index] != 10)):
		if (input[index] == 92):
			index = index + 1
			if (input[index] == 0):
				return index - start
		index = index + 1
	if (input[index] == quote):
		index = index + 1
	return index - start


int cpp_number_length(char* input, int index):
	if ((cpp_is_digit(input[index]) == 0) & ((input[index] != '.') | (cpp_is_digit(input[index + 1]) == 0))):
		return 0
	int start = index
	if (input[index] == '.'):
		index = index + 1
	while (1):
		if (cpp_is_ident_part(input[index]) | (input[index] == '.')):
			index = index + 1
		else if (((input[index] == '+') | (input[index] == '-')) &
				((input[index - 1] == 'e') | (input[index - 1] == 'E') |
					(input[index - 1] == 'p') | (input[index - 1] == 'P'))):
			index = index + 1
		else:
			return index - start


int cpp_identifier_length(char* input, int index):
	if (cpp_is_ident_start(input[index]) == 0):
		return 0
	int start = index
	while (cpp_is_ident_part(input[index])):
		index = index + 1
	return index - start


cpp_token* cpp_lex_make_token(int kind, char* input, int start, int end, char* filename, int line, int has_space, int at_bol):
	char* text = cpp_substr(input, start, end)
	cpp_token* token = cpp_token_new(kind, text, filename, line, has_space, at_bol)
	free(text)
	return token


cpp_token* cpp_tokenize_text(char* input, char* filename):
	cpp_token head
	head.next = 0
	cpp_token* tail = &head
	int index = 0
	int line = 1
	int has_space = 0
	int at_bol = 1
	while (input[index] != 0):
		if (cpp_is_inline_space(input[index])):
			has_space = 1
			index = index + 1
		else if (input[index] == 10):
			line = line + 1
			has_space = 0
			at_bol = 1
			index = index + 1
		else if ((input[index] == 92) & (input[index + 1] == 10)):
			line = line + 1
			index = index + 2
		else if ((input[index] == '/') & (input[index + 1] == '/')):
			has_space = 1
			index = index + 2
			while ((input[index] != 0) & (input[index] != 10)):
				index = index + 1
		else if ((input[index] == '/') & (input[index + 1] == '*')):
			has_space = 1
			index = index + 2
			while (input[index] != 0):
				if ((input[index] == '*') & (input[index + 1] == '/')):
					index = index + 2
					break
				if (input[index] == 10):
					line = line + 1
					at_bol = 1
				index = index + 1
		else:
			int start = index
			int token_line = line
			int token_space = has_space
			int token_bol = at_bol
			int kind = cpp_token_other()
			int length = cpp_identifier_length(input, index)
			if (length > 0):
				kind = cpp_token_ident()
			else:
				length = cpp_number_length(input, index)
				if (length > 0):
					kind = cpp_token_number()
				else:
					int prefix = cpp_string_prefix_length(input, index)
					if (prefix >= 0):
						index = index + prefix
						length = prefix + cpp_quoted_length(input, index, '"')
						kind = cpp_token_string()
					else:
						prefix = cpp_char_prefix_length(input, index)
						if (prefix >= 0):
							index = index + prefix
							length = prefix + cpp_quoted_length(input, index, 39)
							kind = cpp_token_char()
						else:
							length = cpp_punct_length(input, index)
							if (length > 0):
								kind = cpp_token_punct()
							else:
								length = 1
			tail.next = cpp_lex_make_token(kind, input, start, start + length, filename, token_line, token_space, token_bol)
			tail = tail.next
			index = start + length
			has_space = 0
			at_bol = 0
	cpp_token* eof = cpp_token_new(cpp_token_eof(), c"", filename, line, 0, at_bol)
	tail.next = eof
	return head.next


cpp_token* cpp_lex_one_token(char* text):
	cpp_token* token = cpp_tokenize_text(text, c"<paste>")
	if (token.kind == cpp_token_eof()):
		return 0
	if (token.next == 0):
		return 0
	if (token.next.kind != cpp_token_eof()):
		return 0
	token.next = 0
	return token
