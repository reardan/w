/* Foundational text helpers for libs.standard.text. */
import lib.lib
import structures.string

struct text_span:
	int start
	int length

struct text_error:
	int code
	char* message

text_error* text_current_error

int TEXT_OK():
	return 0

int TEXT_ERR_INVALID_ARGUMENT():
	return 1

int TEXT_ERR_UNSUPPORTED():
	return 2

text_span* text_span_new(int start, int length):
	text_span* span = new text_span
	span.start = start
	span.length = length
	return span

void text_clear_error():
	text_current_error = 0

void text_set_error(int code, char* message):
	text_error* err = new text_error
	err.code = code
	err.message = strclone(message)
	text_current_error = err

text_error* text_last_error():
	return text_current_error

char* text_error_message():
	if (text_current_error == 0):
		return c""
	return text_current_error.message

char* text_copy_range(char* text, int start, int length):
	if ((text == 0) | (start < 0) | (length < 0)):
		text_set_error(TEXT_ERR_INVALID_ARGUMENT(), c"text range must be non-negative")
		return strclone(c"")
	char* out = malloc(length + 1)
	int i = 0
	while (i < length):
		out[i] = text[start + i]
		i = i + 1
	out[length] = 0
	return out

list[char*] text_split_lines(char* text):
	text_clear_error()
	list[char*] lines = new list[char*]
	if (text == 0):
		text_set_error(TEXT_ERR_INVALID_ARGUMENT(), c"text must not be null")
		return lines
	int start = 0
	int i = 0
	while (text[i] != 0):
		if (text[i] == 10):
			lines.push(text_copy_range(text, start, i - start))
			start = i + 1
		i = i + 1
	if (i > start):
		lines.push(text_copy_range(text, start, i - start))
	else if ((i > 0) & (text[i - 1] == 10)):
		lines.push(strclone(c""))
	return lines

char* text_join_lines(list[char*] lines):
	text_clear_error()
	string_builder* out = string_new()
	int i = 0
	while (i < lines.length):
		if (i > 0):
			string_append_char(out, 10)
		string_append(out, lines[i])
		i = i + 1
	char* joined = strclone(out.data)
	string_free(out)
	return joined

int text_is_utf8_continuation(int ch):
	ch = ch & 255
	return (ch >= 128) & (ch <= 191)

int text_is_ascii_space(int ch):
	return (ch == ' ') | ((ch >= 9) & (ch <= 13))

int text_supports_option(char* option):
	if (strcmp(option, c"utf8-byte-boundaries") == 0):
		return 1
	text_set_error(TEXT_ERR_UNSUPPORTED(), c"unsupported text option")
	return 0
