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


# JSON output (--json diagnostics, `symbols --json`) used to write(2)/putc(2)
# a syscall per literal chunk or per character, which dominated wall time on
# files with many diagnostics or symbols (#113). diag_write_cstr and
# diag_write_json_string now append to diag_out_buffer instead; callers
# flush the complete record with a single write(2) via diag_flush() (see
# diag_emit below and compiler/compiler.w's symbols_emit_json/human).
char* diag_out_buffer
int diag_out_buffer_size
int diag_out_buffer_pos


void diag_out_ensure(int n):
	if (diag_out_buffer_size == 0):
		diag_out_buffer_size = 256
		diag_out_buffer = malloc(diag_out_buffer_size)
	while (diag_out_buffer_size <= diag_out_buffer_pos + n):
		int old_size = diag_out_buffer_size
		diag_out_buffer_size = diag_out_buffer_size << 1
		diag_out_buffer = realloc(diag_out_buffer, old_size, diag_out_buffer_size)


void diag_out_char(int c):
	diag_out_ensure(1)
	diag_out_buffer[diag_out_buffer_pos] = c
	diag_out_buffer_pos = diag_out_buffer_pos + 1


void diag_flush():
	if (diag_out_buffer_pos > 0):
		write(1, diag_out_buffer, diag_out_buffer_pos)
		diag_out_buffer_pos = 0


void diag_write_cstr(char* s):
	int len = strlen(s)
	diag_out_ensure(len)
	int i = 0
	while (i < len):
		diag_out_buffer[diag_out_buffer_pos] = s[i]
		diag_out_buffer_pos = diag_out_buffer_pos + 1
		i = i + 1


# Length (2-4, lead byte included) of the well-formed UTF-8 sequence
# starting at s[i], or 0 when the bytes there are not well-formed UTF-8
# (an invalid lead byte, a lone/missing continuation byte, an overlong
# encoding, a surrogate, or a codepoint past U+10FFFF). Mirrors
# lib/utf8.w's utf8_validate_bytes, reimplemented locally because this
# module stays dependency-free. Truncation at the terminating NUL fails
# the continuation-range check, so the scan never reads past it.
int diag_utf8_sequence_length(char* s, int i):
	int c = s[i] & 255
	int need = 0
	int codepoint = 0
	if ((c >= 194) & (c <= 223)):
		need = 1
		codepoint = c & 31
	else if ((c >= 224) & (c <= 239)):
		need = 2
		codepoint = c & 15
	else if ((c >= 240) & (c <= 244)):
		need = 3
		codepoint = c & 7
	else:
		return 0
	int j = 1
	while (j <= need):
		int d = s[i + j] & 255
		if ((d < 128) | (d > 191)):
			return 0
		codepoint = (codepoint << 6) | (d & 63)
		j = j + 1
	if ((need == 2) & (codepoint < 2048)):
		return 0
	if ((need == 3) & (codepoint < 65536)):
		return 0
	if ((codepoint >= 55296) & (codepoint <= 57343)):
		return 0
	if (codepoint > 1114111):
		return 0
	return need + 1


void diag_write_json_string(char* s):
	diag_out_char('"')
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
			diag_out_char(diag_hex_digit(ch >> 4))
			diag_out_char(diag_hex_digit(ch & 15))
		else if (ch >= 128):
			# Bytes >= 128 pass through raw only as part of a
			# well-formed UTF-8 sequence (JSON strings may contain raw
			# UTF-8). Any other byte -- a stray byte reflected into a
			# message or token from invalid source input -- is escaped
			# as \u00XX (its byte value) so the emitted NDJSON is
			# always valid UTF-8, and therefore valid JSON (#287).
			int n = diag_utf8_sequence_length(s, i)
			if (n == 0):
				diag_write_cstr(c"\\u00")
				diag_out_char(diag_hex_digit(ch >> 4))
				diag_out_char(diag_hex_digit(ch & 15))
			else:
				while (n > 1):
					diag_out_char(s[i] & 255)
					i = i + 1
					n = n - 1
				diag_out_char(s[i] & 255)
		else:
			diag_out_char(ch)
		i = i + 1
	diag_out_char('"')


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
	diag_flush()
	diag_clear()
