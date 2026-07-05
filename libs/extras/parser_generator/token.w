/*
Parser generator token runtime.

Generated lexers use integer token kind tags and keep token text as owned
null-terminated strings. Source locations are one-based for human diagnostics;
offset/length are zero-based byte positions in the lexed input so tools can
compute precise edit ranges.

Channels: parsers only see default-channel tokens. Trivia (whitespace,
comments, invalid characters) is emitted on the hidden channel so the full
token stream reproduces the input byte for byte.
*/
import lib.lib


struct pg_token:
	int kind
	char* text
	char* filename
	int line
	int column
	int channel
	int offset
	int length


int pg_token_eof_kind():
	return 0


int pg_token_invalid_kind():
	return -1


# Kind tag for hidden inline-whitespace runs. Skip rules from the grammar get
# their own negative kinds starting at -3 (see pg_grammar_add_skip).
int pg_token_whitespace_kind():
	return -2


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
	token.offset = 0
	token.length = strlen(text)
	return token


pg_token* pg_token_make(int kind, char* input, int start, int length, char* filename, int line, int column):
	pg_token* token = pg_token_new(kind, pg_substr(input, start, length), filename, line, column)
	token.offset = start
	token.length = length
	return token


# Move the token to the hidden channel; returns the token for call chaining.
pg_token* pg_token_hide(pg_token* token):
	token.channel = pg_token_hidden_channel()
	return token


pg_token* pg_token_eof(int offset, char* filename, int line, int column):
	pg_token* token = pg_token_new(pg_token_eof_kind(), c"", filename, line, column)
	token.offset = offset
	return token


void pg_token_free(pg_token* token):
	if (token == 0):
		return
	if ((token.text != 0) & (strlen(token.text) > 0)):
		free(token.text)
	free(token)
