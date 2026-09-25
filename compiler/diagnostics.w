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


# Message fragments are buffered in both output modes: warning()/error()
# (compiler/tokenizer.w) print the whole message at once, after a
# severity label, so human-readable diagnostics can lead with
# 'error:'/'warning:' the way gcc, clang and rustc do (#377).
void diag_part(char* s):
	diag_append(s)


# Optional '= help: ...' line attached to the next diagnostic (#377):
# set by the did-you-mean suggester below or directly by a call site,
# printed under the source context in human output, emitted as an
# optional "help" field in --json output, and cleared by either.
char* diag_help_text


void diag_set_help(char* s):
	if (diag_help_text != 0):
		free(diag_help_text)
	diag_help_text = strclone(s)


void diag_clear_help():
	if (diag_help_text != 0):
		free(diag_help_text)
	diag_help_text = 0


/*
Did-you-mean suggestions (#377), after Python 3.10+'s NameError hints
and rustc's similar-name help: a lookup failure hands every name that
was in scope to diag_suggest_consider(); the closest one within
max(len, 3) / 3 edits (rustc's threshold) becomes the diagnostic's
help line. Distance is optimal-string-alignment edit distance, so an
adjacent transposition ('lenght') costs one edit like a typo does, and
a case-only difference counts as the closest match of all. The first
candidate wins ties, so callers offer the innermost scope first.
*/
char* diag_suggest_name
char* diag_suggest_best
int diag_suggest_best_distance
char* diag_suggest_rows


int diag_suggest_max_length():
	return 64


void diag_suggest_begin(char* name):
	diag_suggest_name = name
	diag_suggest_best = 0
	diag_suggest_best_distance = 1000
	if (diag_suggest_rows == 0):
		diag_suggest_rows = malloc(3 * (diag_suggest_max_length() + 1))


int diag_lower(int c):
	if ((c >= 'A') && (c <= 'Z')):
		return c + 32
	return c


int diag_min(int a, int b):
	if (a < b):
		return a
	return b


# Edit distance between a and b (lengths n and m, both at most
# diag_suggest_max_length()); rows are one byte per cell, which the
# length cap keeps in range. Returns 0 for a case-only difference.
int diag_edit_distance(char* a, int n, char* b, int m):
	char* prev2 = diag_suggest_rows
	char* prev = diag_suggest_rows + (diag_suggest_max_length() + 1)
	char* row = diag_suggest_rows + 2 * (diag_suggest_max_length() + 1)
	int j = 0
	while (j <= m):
		prev[j] = j
		j = j + 1
	int i = 1
	while (i <= n):
		row[0] = i
		j = 1
		while (j <= m):
			int cost = 1
			if (diag_lower(a[i - 1] & 255) == diag_lower(b[j - 1] & 255)):
				cost = 0
			int best = diag_min((prev[j] & 255) + 1, (row[j - 1] & 255) + 1)
			best = diag_min(best, (prev[j - 1] & 255) + cost)
			if ((i > 1) && (j > 1)):
				if ((a[i - 1] == b[j - 2]) && (a[i - 2] == b[j - 1])):
					best = diag_min(best, (prev2[j - 2] & 255) + 1)
			row[j] = best
			j = j + 1
		char* t = prev2
		prev2 = prev
		prev = row
		row = t
		i = i + 1
	return prev[m] & 255


void diag_suggest_consider(char* candidate):
	if ((diag_suggest_name == 0) || (candidate == 0)):
		return
	char* name = diag_suggest_name
	# Compiler-internal names ('__w_...') are only offered for a name
	# that is itself spelled that way.
	if ((candidate[0] == '_') && (candidate[1] == '_') && (name[0] != '_')):
		return
	if (strcmp(candidate, name) == 0):
		return
	int n = strlen(name)
	int m = strlen(candidate)
	if ((n == 0) || (m == 0)):
		return
	if ((n > diag_suggest_max_length()) || (m > diag_suggest_max_length())):
		return
	int limit = n
	if (limit < 3):
		limit = 3
	limit = limit / 3
	int gap = n - m
	if (gap < 0):
		gap = 0 - gap
	if (gap > limit):
		return
	int distance = diag_edit_distance(name, n, candidate, m)
	if ((distance <= limit) && (distance < diag_suggest_best_distance)):
		diag_suggest_best = candidate
		diag_suggest_best_distance = distance


# Attach "did you mean '<best>'?" as the pending help line when a
# candidate was close enough; returns 1 when it did.
int diag_suggest_finish():
	int found = 0
	if (diag_suggest_best != 0):
		char* prefix = strjoin(c"did you mean '", diag_suggest_best)
		char* text = strjoin(prefix, c"'?")
		diag_set_help(text)
		free(prefix)
		free(text)
		found = 1
	diag_suggest_name = 0
	diag_suggest_best = 0
	return found


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
	if ((c >= 194) && (c <= 223)):
		need = 1
		codepoint = c & 31
	else if ((c >= 224) && (c <= 239)):
		need = 2
		codepoint = c & 15
	else if ((c >= 240) && (c <= 244)):
		need = 3
		codepoint = c & 7
	else:
		return 0
	int j = 1
	while (j <= need):
		int d = s[i + j] & 255
		if ((d < 128) || (d > 191)):
			return 0
		codepoint = (codepoint << 6) | (d & 63)
		j = j + 1
	if ((need == 2) && (codepoint < 2048)):
		return 0
	if ((need == 3) && (codepoint < 65536)):
		return 0
	if ((codepoint >= 55296) && (codepoint <= 57343)):
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
	if (diag_help_text != 0):
		diag_write_cstr(c", ")
		diag_write_json_field(c"help", diag_help_text)
	diag_write_cstr(c"}\x0a")
	diag_flush()
	diag_clear()
	diag_clear_help()
