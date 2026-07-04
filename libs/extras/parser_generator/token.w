/*
Parser generator token runtime.

Generated lexers use integer token kind tags and keep token text as owned
null-terminated strings. Source locations are one-based for human diagnostics.
*/
import lib.lib


struct pg_token:
	int kind
	char* text
	char* filename
	int line
	int column
	int channel


int pg_token_eof_kind():
	return 0


int pg_token_invalid_kind():
	return -1


int pg_token_default_channel():
	return 0


int pg_token_hidden_channel():
	return 1


char* pg_substr(char* input, int start, int length):
	char* text = malloc(length + 1)
	int i = 0
	while (i < length):
		text[i] = input[start + i]
		i = i + 1
	text[length] = 0
	return text


pg_token* pg_token_new(int kind, char* text, char* filename, int line, int column):
	pg_token* token = new pg_token()
	token.kind = kind
	token.text = text
	token.filename = filename
	token.line = line
	token.column = column
	token.channel = pg_token_default_channel()
	return token


pg_token* pg_token_make(int kind, char* input, int start, int length, char* filename, int line, int column):
	return pg_token_new(kind, pg_substr(input, start, length), filename, line, column)


pg_token* pg_token_eof(char* filename, int line, int column):
	return pg_token_new(pg_token_eof_kind(), "", filename, line, column)


void pg_token_free(pg_token* token):
	if (token == 0):
		return
	if ((token.text != 0) & (strlen(token.text) > 0)):
		free(token.text)
	free(token)
