import lib.lib


int diag_json
char* diag_buffer
int diag_buffer_size
int diag_buffer_pos
int diag_token_line
int diag_token_column
int diag_word_size


void diag_clear():
	diag_buffer_pos = 0
	if (diag_buffer != 0):
		diag_buffer[0] = 0


void diag_ensure(int n):
	if (diag_buffer_size == 0):
		diag_buffer_size = 128
		diag_buffer = malloc(diag_buffer_size)
		diag_buffer[0] = 0
	while (diag_buffer_size <= diag_buffer_pos + n):
		int old_size = diag_buffer_size
		diag_buffer_size = diag_buffer_size << 1
		diag_buffer = realloc(diag_buffer, old_size, diag_buffer_size)


void diag_append(char* s):
	diag_ensure(strlen(s) + 1)
	int i = 0
	while (s[i] != 0):
		diag_buffer[diag_buffer_pos] = s[i]
		diag_buffer_pos = diag_buffer_pos + 1
		i = i + 1
	diag_buffer[diag_buffer_pos] = 0


void diag_part(char* s):
	if (diag_json):
		diag_append(s)
	else:
		print_error(str_from_cstr(s))


int diag_hex_digit(int value):
	if (value < 10):
		return value + '0'
	return value - 10 + 'a'


void diag_write_cstr(char* s):
	write(1, s, strlen(s))


void diag_write_json_string(char* s):
	putc(1, '"')
	int i = 0
	while (s[i] != 0):
		int ch = s[i] & 255
		if (ch == '"'):
			diag_write_cstr(c"\\\"")
		else if (ch == 92):
			diag_write_cstr(c"\\\\")
		else if (ch == 10):
			diag_write_cstr(c"\\n")
		else if (ch == 13):
			diag_write_cstr(c"\\r")
		else if (ch == 9):
			diag_write_cstr(c"\\t")
		else if (ch < 32):
			diag_write_cstr(c"\\u00")
			putc(1, diag_hex_digit(ch >> 4))
			putc(1, diag_hex_digit(ch & 15))
		else:
			putc(1, ch)
		i = i + 1
	putc(1, '"')


void diag_write_json_field(char* name, char* value):
	diag_write_json_string(name)
	diag_write_cstr(c": ")
	diag_write_json_string(value)


void diag_write_json_int_field(char* name, int value):
	diag_write_json_string(name)
	diag_write_cstr(c": ")
	char* digits = itoa(value)
	diag_write_cstr(digits)
	free(digits)


char* diag_strip_warning_prefix(char* message):
	if (starts_with(message, c"warning: ")):
		return message + 9
	return message


void diag_emit(char* severity, char* file, int line, int column, char* token):
	char* message = diag_buffer
	if (strcmp(severity, c"warning") == 0):
		message = diag_strip_warning_prefix(message)
	char* arch = c"x86"
	if (diag_word_size == 8):
		arch = c"x64"
	diag_write_cstr(c"{")
	diag_write_json_field(c"file", file)
	diag_write_cstr(c", ")
	diag_write_json_int_field(c"line", line)
	diag_write_cstr(c", ")
	diag_write_json_int_field(c"column", column)
	diag_write_cstr(c", ")
	diag_write_json_field(c"severity", severity)
	diag_write_cstr(c", ")
	diag_write_json_field(c"message", message)
	diag_write_cstr(c", ")
	diag_write_json_field(c"token", token)
	diag_write_cstr(c", ")
	diag_write_json_field(c"arch", arch)
	diag_write_cstr(c"}\x0a")
	diag_clear()
