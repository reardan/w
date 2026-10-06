import lib.lib


int diag_json
char* diag_buffer
int diag_buffer_size
int diag_buffer_pos
int diag_token_line
int diag_token_column
int diag_word_size


void diag_related_clear();


void diag_clear():
	diag_buffer_pos = 0
	if (diag_buffer != 0): diag_buffer[0] = 0
	diag_related_clear()


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
	if (diag_help_text != 0): free(diag_help_text)
	diag_help_text = strclone(s)


void diag_clear_help():
	if (diag_help_text != 0): free(diag_help_text)
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


const int diag_suggest_max_length = 64


void diag_suggest_begin(char* name):
	diag_suggest_name = name
	diag_suggest_best = 0
	diag_suggest_best_distance = 1000
	if (diag_suggest_rows == 0): diag_suggest_rows = malloc(3 * (diag_suggest_max_length + 1))


int diag_lower(int c):
	if ((c >= 'A') && (c <= 'Z')): return c + 32
	return c


int diag_min(int a, int b):
	if (a < b):
		return a
	return b


# Edit distance between a and b (lengths n and m, both at most
# diag_suggest_max_length); rows are one byte per cell, which the
# length cap keeps in range. Returns 0 for a case-only difference.
int diag_edit_distance(char* a, int n, char* b, int m):
	char* prev2 = diag_suggest_rows
	char* prev = diag_suggest_rows + (diag_suggest_max_length + 1)
	char* row = diag_suggest_rows + 2 * (diag_suggest_max_length + 1)
	int j = 0
	while (j <= m):
		prev[j] = j
		j = j + 1
	for i in range(1, n + 1):
		row[0] = i
		j = 1
		while (j <= m):
			int cost = 1
			if (diag_lower(a[i - 1] & 255) == diag_lower(b[j - 1] & 255)): cost = 0
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
	return prev[m] & 255


void diag_suggest_consider(char* candidate):
	if ((diag_suggest_name == 0) || (candidate == 0)): return
	char* name = diag_suggest_name
	# Compiler-internal names ('__w_...') are only offered for a name
	# that is itself spelled that way.
	if ((candidate[0] == '_') && (candidate[1] == '_') && (name[0] != '_')): return
	if (strcmp(candidate, name) == 0): return
	int n = strlen(name)
	int m = strlen(candidate)
	if ((n == 0) || (m == 0)): return
	if ((n > diag_suggest_max_length) || (m > diag_suggest_max_length)): return
	int limit = n
	if (limit < 3): limit = 3
	limit = limit / 3
	int gap = n - m
	if (gap < 0): gap = 0 - gap
	if (gap > limit): return
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
	if (value < 10): return value + '0'
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
	for i in range(len):
		diag_out_buffer[diag_out_buffer_pos] = s[i]
		diag_out_buffer_pos = diag_out_buffer_pos + 1


# The codepoint of the multi-byte UTF-8 sequence starting at s[i], with
# its byte length (2-4, lead byte included) in utf8_decode_length; or -1
# with utf8_decode_length 0 when the bytes there are not a well-formed
# sequence: an ASCII or invalid lead byte, a lone/missing continuation
# byte, or an overlong encoding. Surrogates and codepoints past U+10FFFF
# decode normally, for callers to reject with their own diagnostics.
# Mirrors lib/utf8.w's utf8_validate_bytes, reimplemented locally
# because this module stays dependency-free. Truncation at the
# terminating NUL fails the continuation-range check, so the scan never
# reads past it.
int utf8_decode_length


int utf8_decode_at(char* s, int i):
	utf8_decode_length = 0
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
	else: return -1
	for j in range(1, need + 1):
		int d = s[i + j] & 255
		if ((d < 128) || (d > 191)): return -1
		codepoint = (codepoint << 6) | (d & 63)
	if (((need == 2) && (codepoint < 2048)) || ((need == 3) && (codepoint < 65536))): return -1
	utf8_decode_length = need + 1
	return codepoint


# Length of the well-formed UTF-8 sequence at s[i] (utf8_decode_at), or
# 0 when it is malformed, a surrogate or past U+10FFFF.
int diag_utf8_sequence_length(char* s, int i):
	int codepoint = utf8_decode_at(s, i)
	if (((codepoint >= 55296) && (codepoint <= 57343)) || (codepoint > 1114111)): return 0
	return utf8_decode_length


void diag_write_json_string(char* s):
	diag_out_char('"')
	int i = 0
	while (s[i] != 0):
		int ch = s[i] & 255
		if (ch == '"'): diag_write_cstr(c"\\\"")
		else if (ch == 92): diag_write_cstr(c"\\\\")
		else if (ch == 10): diag_write_cstr(c"\\n")
		else if (ch == 13): diag_write_cstr(c"\\r")
		else if (ch == 9): diag_write_cstr(c"\\t")
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
		else: diag_out_char(ch)
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


/*
Stable diagnostic codes (AST completion plan unit C3.2). Every --json
record carries a "code": the row of the table below whose pattern
matches the record's message (after the 'warning: ' label is
stripped). A pattern is the frozen message text with '@' standing for
the variable parts (names, types, counts, nested clauses); it must
match the whole message. When several rows match, the one with the
most literal characters wins, and the earlier row breaks a tie, so a
specific message ("function '@' expects at least @ arguments, got @")
beats a general one ("function '@' expects @ arguments, got @") no
matter where either sits in the table. A message that matches no row
gets W0000, "unclassified".

The table is append-only: a code is never renumbered or reused. A new
diagnostic gets a new row with the next free number at the end of the
table; a diagnostic whose text is removed keeps its row (it just stops
matching), and a reworded message updates its pattern in place, keeping
its code. Codes are assigned at diagnostic time from the final message
text, so call sites need no change and the human-readable output never
sees them. docs/projects/lint.md "JSON output" documents the record.
*/
char** diag_code_ids
char** diag_code_patterns
int* diag_code_scores
int diag_code_count
int diag_code_capacity


void diag_code_row(char* code, char* pattern):
	if (diag_code_count == diag_code_capacity):
		int old_capacity = diag_code_capacity
		diag_code_capacity = diag_code_capacity * 2
		if (diag_code_capacity == 0): diag_code_capacity = 512
		diag_code_ids = cast(char**, realloc(cast(char*, diag_code_ids), old_capacity * __word_size__, diag_code_capacity * __word_size__))
		diag_code_patterns = cast(char**, realloc(cast(char*, diag_code_patterns), old_capacity * __word_size__, diag_code_capacity * __word_size__))
		diag_code_scores = cast(int*, realloc(cast(char*, diag_code_scores), old_capacity * __word_size__, diag_code_capacity * __word_size__))
	int score = 0
	int i = 0
	while (pattern[i] != 0):
		if (pattern[i] != '@'): score = score + 1
		i = i + 1
	diag_code_ids[diag_code_count] = code
	diag_code_patterns[diag_code_count] = pattern
	diag_code_scores[diag_code_count] = score
	diag_code_count = diag_code_count + 1


# Whole-string match of pattern p against s, '@' matching any run of
# bytes (including none). The classic single-backtrack-point glob walk:
# a later '@' supersedes the earlier one's retry point, which is enough
# for a wildcard that matches arbitrary text.
int diag_pattern_match(char* p, char* s):
	int pi = 0
	int si = 0
	int star = -1
	int mark = 0
	while (s[si] != 0):
		if (p[pi] == '@'):
			star = pi
			pi = pi + 1
			mark = si
		else if ((p[pi] != 0) && (p[pi] == s[si])):
			pi = pi + 1
			si = si + 1
		else if (star >= 0):
			pi = star + 1
			mark = mark + 1
			si = mark
		else: return 0
	while (p[pi] == '@'): pi = pi + 1
	return p[pi] == 0


void diag_code_table();


# The stable code for a (warning-label-stripped) message; W0000 when no
# row matches.
char* diag_code_for(char* message):
	if (diag_code_count == 0): diag_code_table()
	int best = -1
	int best_score = -1
	for i in range(diag_code_count):
		if (diag_code_scores[i] > best_score):
			if (diag_pattern_match(diag_code_patterns[i], message)):
				best = i
				best_score = diag_code_scores[i]
	if (best < 0): return c"W0000"
	return diag_code_ids[best]


/*
Related notes (C3.2): a call site that knows which declaration a
diagnostic is about -- the definition a redefinition collides with, the
similar name a "Cannot find symbol" suggests, the function whose
parameter or return type a mismatch was checked against -- attaches it
with diag_related_add() right before warning()/error(). The note rides
only in the --json record's "related" array: human output is unchanged
and the note is only recorded under --json at all. diag_clear() drops
pending notes, so a warning suppressed in an --all-errors probe or a
defhash replay cannot leak its note onto the next diagnostic.
*/
const int diag_related_max = 4
char** diag_related_files
char** diag_related_messages
int* diag_related_lines
int* diag_related_columns
int diag_related_count


void diag_related_add(char* file, int line, int column, char* message):
	if ((diag_json == 0) || (file == 0) || (message == 0)): return
	if (diag_related_count >= diag_related_max): return
	if (diag_related_files == 0):
		diag_related_files = cast(char**, malloc(diag_related_max * __word_size__))
		diag_related_messages = cast(char**, malloc(diag_related_max * __word_size__))
		diag_related_lines = cast(int*, malloc(diag_related_max * __word_size__))
		diag_related_columns = cast(int*, malloc(diag_related_max * __word_size__))
	diag_related_files[diag_related_count] = strclone(file)
	diag_related_messages[diag_related_count] = strclone(message)
	diag_related_lines[diag_related_count] = line
	diag_related_columns[diag_related_count] = column
	diag_related_count = diag_related_count + 1


void diag_related_clear():
	while (diag_related_count > 0):
		diag_related_count = diag_related_count - 1
		free(diag_related_files[diag_related_count])
		free(diag_related_messages[diag_related_count])


/*
End positions (C3.2): "end_line"/"end_column" close the span that
starts at "line"/"column", exclusive (the position just past the last
character), counted in codepoints like "column". The span is the
reported token's: the token text is the raw source bytes the
tokenizer consumed, so walking it from the start position gives the
end. Where the source can be read back -- a regular file, the same
condition under which the human-readable diagnostic prints its source
line -- the token is first checked against the bytes at the start
position, and a token that is not there (a diagnostic re-pointed at a
recorded position, a lint finding, end of file, '<command-line>')
gets a zero-width span: end == start. Where it cannot (no statx on
this host), the token text is trusted. The source is read once per
file through a fresh descriptor, never the tokenizer's, and cached
with a line index, so a file with many findings is scanned once.
*/
int diag_end_line
int diag_end_column
char* diag_source_path
char* diag_source_bytes
int diag_source_length
int* diag_source_lines
int diag_source_line_count
int diag_source_state


# 1: the cached bytes are diag_source_path's; 0: the file cannot be
# read back as a regular file; -1: this host cannot tell (no statx).
int diag_source_load(char* path):
	if ((diag_source_path != 0) && (strcmp(diag_source_path, path) == 0)): return diag_source_state
	if (diag_source_path != 0):
		free(diag_source_path)
		if (diag_source_bytes != 0): free(diag_source_bytes)
		if (diag_source_lines != 0): free(diag_source_lines)
	diag_source_path = strclone(path)
	diag_source_bytes = 0
	diag_source_lines = 0
	diag_source_length = 0
	diag_source_line_count = 0
	diag_source_state = 0
	# Only a regular file is reopened: a FIFO or device would block on
	# open or hand back different bytes. statx's mode is a u16 at
	# offset 28 of its 256-byte buffer; S_IFMT 0170000, S_IFREG 0100000.
	char* info = malloc(256)
	int status = statx(path, 0, 2047, info)
	int mode = load_int(info + 28) & 61440
	free(info)
	# The darwin/win64/wasm stubs return -1; a Linux kernel or sandbox
	# without statx returns -ENOSYS (or -EPERM, also -1). Any other
	# failure (the file is gone) means the bytes cannot be checked.
	if ((status == -1) || (status == -38)):
		diag_source_state = -1
		return -1
	if (status != 0): return 0
	if (mode != 32768): return 0
	int fd = open(path, 0, 0)
	if (fd < 0): return 0
	int size = seek(fd, 0, 2)
	if ((size < 0) || (seek(fd, 0, 0) != 0)):
		close(fd)
		return 0
	diag_source_bytes = malloc(size + 1)
	int got = 0
	while (got < size):
		int n = read(fd, diag_source_bytes + got, size - got)
		if (n > 0): got = got + n
		else if (n != -4): size = got
	close(fd)
	diag_source_bytes[size] = 0
	diag_source_length = size
	int lines = 1
	for i in range(size):
		if (diag_source_bytes[i] == 10): lines = lines + 1
	diag_source_lines = cast(int*, malloc(lines * __word_size__))
	diag_source_lines[0] = 0
	diag_source_line_count = 1
	for i in range(size):
		if (diag_source_bytes[i] == 10):
			diag_source_lines[diag_source_line_count] = i + 1
			diag_source_line_count = diag_source_line_count + 1
	diag_source_state = 1
	return 1


# Byte offset of 1-based line/column in the cached source, or -1 when
# that position is not on the line. Columns advance per codepoint (a
# UTF-8 continuation byte does not count), as the tokenizer's do; the
# column just past a line's last character is still on that line. A
# leading UTF-8 BOM is skipped like the compiler skips it.
int diag_source_offset(int line, int column):
	if ((line < 1) || (line > diag_source_line_count) || (column < 1)): return -1
	int i = diag_source_lines[line - 1]
	if ((line == 1) && (diag_source_length >= 3)):
		if (((diag_source_bytes[0] & 255) == 239) && ((diag_source_bytes[1] & 255) == 187) && ((diag_source_bytes[2] & 255) == 191)): i = 3
	int at = 1
	while (at < column):
		if ((i >= diag_source_length) || (diag_source_bytes[i] == 10)): return -1
		i = i + 1
		while ((i < diag_source_length) && ((diag_source_bytes[i] & 192) == 128)): i = i + 1
		at = at + 1
	return i


# Set diag_end_line/diag_end_column for a diagnostic at line/column
# about token (see "End positions" above).
void diag_span(char* file, int line, int column, char* token):
	diag_end_line = line
	diag_end_column = column
	if ((line < 1) || (column < 1) || (token == 0) || (file == 0)): return
	if (token[0] == 0): return
	int state = diag_source_load(file)
	if (state == 0): return
	if (state == 1):
		int offset = diag_source_offset(line, column)
		if (offset < 0): return
		int j = 0
		while (token[j] != 0):
			if (offset + j >= diag_source_length): return
			if (diag_source_bytes[offset + j] != token[j]): return
			j = j + 1
	int end_line = line
	int end_column = column
	int k = 0
	while (token[k] != 0):
		if (token[k] == 10):
			end_line = end_line + 1
			end_column = 1
		else if ((token[k] & 192) != 128): end_column = end_column + 1
		k = k + 1
	diag_end_line = end_line
	diag_end_column = end_column


void diag_write_related():
	diag_write_json_string(c"related")
	diag_write_cstr(c": [")
	for i in range(diag_related_count):
		if (i > 0): diag_write_cstr(c", ")
		diag_write_cstr(c"{")
		diag_write_json_field(c"file", diag_related_files[i])
		diag_write_cstr(c", ")
		diag_write_json_int_field(c"line", diag_related_lines[i])
		diag_write_cstr(c", ")
		diag_write_json_int_field(c"column", diag_related_columns[i])
		diag_write_cstr(c", ")
		diag_write_json_field(c"message", diag_related_messages[i])
		diag_write_cstr(c"}")
	diag_write_cstr(c"]")


char* diag_strip_warning_prefix(char* message):
	if (starts_with(message, c"warning: ")): return message + 9
	return message


void diag_emit(char* severity, char* file, int line, int column, char* token):
	char* message = diag_buffer
	if (strcmp(severity, c"warning") == 0): message = diag_strip_warning_prefix(message)
	char* arch = c"x86"
	if (diag_word_size == 8): arch = c"x64"
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
	diag_write_cstr(c", ")
	diag_write_json_field(c"code", diag_code_for(message))
	diag_span(file, line, column, token)
	diag_write_cstr(c", ")
	diag_write_json_int_field(c"end_line", diag_end_line)
	diag_write_cstr(c", ")
	diag_write_json_int_field(c"end_column", diag_end_column)
	if (diag_help_text != 0):
		diag_write_cstr(c", ")
		diag_write_json_field(c"help", diag_help_text)
	diag_write_cstr(c", ")
	diag_write_related()
	diag_write_cstr(c"}\x0a")
	diag_flush()
	diag_clear()
	diag_clear_help()


# The code table (see "Stable diagnostic codes" above). Append-only:
# never renumber, reorder-insensitive (the most specific match wins),
# one row per distinct message shape; W0000 is reserved for "no row".
void diag_code_table():
	# name resolution and redefinition
	diag_code_row(c"W0001", c"Cannot find symbol: '@")
	diag_code_row(c"W0002", c"symbol redefined: '@'")
	# type checking
	diag_code_row(c"W0003", c"@ type mismatch: expected '@', got '@'")
	diag_code_row(c"W0004", c"function '@' argument @ type mismatch: expected '@', got '@'")
	diag_code_row(c"W0005", c"function '@' expects @ arguments, got @")
	diag_code_row(c"W0006", c"function '@' expects at least @ arguments, got @")
	diag_code_row(c"W0007", c"@ mixes gpu and host pointers: expected '@', got '@'; use cast() to cross the host/device boundary")
	diag_code_row(c"W0008", c"':=' redeclares '@'; use '=' to assign, or a typed declaration to shadow")
	diag_code_row(c"W0009", c"generic '@' redefined")
	diag_code_row(c"W0010", c"duplicate label '@'")
	diag_code_row(c"W0011", c"duplicate import alias: '@'")
	diag_code_row(c"W0012", c"duplicate protobuf field number in message '@'")
	diag_code_row(c"W0013", c"function '@' is already exported")
	diag_code_row(c"W0014", c"unknown type name: '@'")
	diag_code_row(c"W0015", c"unknown type after new: '@'")
	diag_code_row(c"W0016", c"struct field '@' not found")
	diag_code_row(c"W0017", c"struct field '@' is an imported C bit-field that spans more than a word on this target; member access is not supported")
	diag_code_row(c"W0018", c"struct method '@.@' not found; expected function '@'")
	diag_code_row(c"W0019", c"member '@' on non-struct type '@'")
	diag_code_row(c"W0020", c"buffer field '@' not found")
	diag_code_row(c"W0021", c"hash container field '@' not found")
	diag_code_row(c"W0022", c"list field '@' not found")
	diag_code_row(c"W0023", c"child field not found: '@")
	diag_code_row(c"W0024", c"goto to undefined label '@'")
	diag_code_row(c"W0025", c"symbol '@' is not defined in module imported as '@'")
	diag_code_row(c"W0026", c"type '@' is not defined in module imported as '@'")
	diag_code_row(c"W0027", c"'@' is a value, not a type, in module imported as '@'")
	diag_code_row(c"W0028", c"'@' is not a kernel")
	diag_code_row(c"W0029", c"'@' is not a protobuf message")
	diag_code_row(c"W0030", c"@ is not defined")
	# syntax
	diag_code_row(c"W0031", c"'@' expected, found '@'")
	diag_code_row(c"W0032", c"Could not find a valid primary expression, token: @")
	diag_code_row(c"W0033", c"No closing parenthesis")
	diag_code_row(c"W0034", c"')' expected in @")
	diag_code_row(c"W0035", c"'}' expected in hash literal")
	diag_code_row(c"W0036", c"'}' expected in list literal")
	diag_code_row(c"W0037", c"'}' expected in template string expression")
	diag_code_row(c"W0038", c"']' expected in type argument list, found '@'")
	diag_code_row(c"W0039", c"'(' expected after the type parameter list of generic '@'")
	diag_code_row(c"W0040", c"type parameter name expected, found '@'")
	diag_code_row(c"W0041", c"label name expected after 'goto'")
	diag_code_row(c"W0042", c"identifier expected after import alias '@'")
	diag_code_row(c"W0043", c"invalid import alias: '@'")
	diag_code_row(c"W0044", c"import wildcard '.*' is not supported (an import already makes the whole module visible); use 'import @'")
	diag_code_row(c"W0045", c"'@' is a statement and cannot be used inside an expression")
	diag_code_row(c"W0046", c"unmatched '}' at module scope")
	diag_code_row(c"W0047", c"switch body must start on a new line")
	diag_code_row(c"W0048", c"'default' must be the last clause in a switch")
	diag_code_row(c"W0049", c"'case' or 'default' expected in switch body")
	diag_code_row(c"W0050", c"a statement must follow 'defer' on the same line")
	diag_code_row(c"W0051", c"expression nesting too deep")
	diag_code_row(c"W0052", c"statement nesting too deep")
	diag_code_row(c"W0053", c"declarations must come before the first top-level statement")
	# lexical
	diag_code_row(c"W0054", c"unterminated string literal")
	diag_code_row(c"W0055", c"unterminated char literal")
	diag_code_row(c"W0056", c"unterminated template string literal")
	diag_code_row(c"W0057", c"single '}' in template string; use '}}'")
	diag_code_row(c"W0058", c"invalid UTF-8 sequence in identifier")
	diag_code_row(c"W0059", c"identifier '@' contains @: U+@")
	diag_code_row(c"W0060", c"empty char literal")
	diag_code_row(c"W0061", c"unknown escape in char literal: @")
	diag_code_row(c"W0062", c"invalid UTF-8 char literal: @")
	diag_code_row(c"W0063", c"multi-character char literal: @")
	diag_code_row(c"W0064", c"invalid hex digit in string literal")
	diag_code_row(c"W0065", c"invalid unicode codepoint")
	diag_code_row(c"W0066", c"invalid unicode surrogate")
	diag_code_row(c"W0067", c"unicode codepoint out of range")
	diag_code_row(c"W0068", c"invalid UTF-8 string literal")
	diag_code_row(c"W0069", c"truncated UTF-8 string literal")
	diag_code_row(c"W0070", c"invalid UTF-8 continuation byte")
	diag_code_row(c"W0071", c"overlong UTF-8 string literal")
	diag_code_row(c"W0072", c"invalid UTF-8 surrogate")
	diag_code_row(c"W0073", c"UTF-8 codepoint out of range")
	diag_code_row(c"W0074", c"invalid float exponent")
	diag_code_row(c"W0075", c"invalid float literal")
	diag_code_row(c"W0076", c"integer literal has more than 32 significant bits; assemble wide constants at runtime from 32-bit pieces")
	diag_code_row(c"W0077", c"double quote expected inside raw_asm( ... ) literal")
	diag_code_row(c"W0078", c"invalid template string format spec '@': @")
	diag_code_row(c"W0079", c"read error while reading '@'")
	diag_code_row(c"W0080", c"source changed during retained AST traversal")
	# always-on warnings
	diag_code_row(c"W0081", c"file does not end with a newline")
	diag_code_row(c"W0082", c"line indented with spaces instead of tabs")
	diag_code_row(c"W0083", c"bitwise '@' on bool operands in a condition does not short-circuit; did you mean '@'?")
	diag_code_row(c"W0084", c"call arguments continue from the previous line")
	diag_code_row(c"W0085", c"cast of array to pointer addresses the array header, not its data; index or let it decay instead")
	diag_code_row(c"W0086", c"integer literal has bit 31 set and sign-extends to a negative int on every target; use cast(int, ...) if the bit pattern is intended")
	diag_code_row(c"W0087", c"unqualified use of '@' from module imported as '@'")
	diag_code_row(c"W0088", c"symbol '@' resolves through a transitive import (defined in '@'); import it directly")
	diag_code_row(c"W0089", c"@ constructor expects @ arguments, got @")
	diag_code_row(c"W0090", c"new @ expects @ arguments, got @")
	# lint rules (w check --lint)
	diag_code_row(c"W0091", c"local variable '@' is never used [unused-local]")
	diag_code_row(c"W0092", c"unreachable code after return/break/continue/goto [unreachable]")
	diag_code_row(c"W0093", c"declaration of '@' shadows @ [shadow]")
	diag_code_row(c"W0094", c"assignment used as a condition; use '==' to compare, or wrap it in extra parentheses [assign-in-condition]")
	diag_code_row(c"W0095", c"'@' is assigned to itself [self-assign]")
	diag_code_row(c"W0096", c"module '@' is already imported [duplicate-import]")
	diag_code_row(c"W0097", c"trailing whitespace [trailing-whitespace]")
	diag_code_row(c"W0098", c"file uses CRLF line endings [crlf]")
	diag_code_row(c"W0099", c"more than two consecutive blank lines [blank-lines]")
	diag_code_row(c"W0100", c"blank line at start of file [leading-blank-lines]")
	diag_code_row(c"W0101", c"blank lines at end of file [trailing-blank-lines]")
	diag_code_row(c"W0102", c"line is @ columns wide (limit @) [line-too-long]")
	diag_code_row(c"W0103", c"bidirectional control character U+@ can make this line display differently from how it compiles (Trojan Source) [bidi-control]")
	diag_code_row(c"W0104", c"identifier '@' mixes @ and @ letters [mixed-script]")
	diag_code_row(c"W0105", c"identifier '@' looks like '@' from line @ but is a different name [confusable]")
	# assignment, operators and values
	diag_code_row(c"W0106", c"assignment to const")
	diag_code_row(c"W0107", c"assignment target is not assignable")
	diag_code_row(c"W0108", c"cannot assign to read-only buffer field")
	diag_code_row(c"W0109", c"compound assignment does not support var operands")
	diag_code_row(c"W0110", c"compound assignment is not supported on struct values")
	diag_code_row(c"W0111", c"compound assignment is not supported on string, array or slice values")
	diag_code_row(c"W0112", c"float operands only support += -= *= /=")
	diag_code_row(c"W0113", c"float operands do not support %")
	diag_code_row(c"W0114", c"float operands do not support ~")
	diag_code_row(c"W0115", c"var operands do not support @")
	diag_code_row(c"W0116", c"'++' and '--' are not supported on map or set elements")
	diag_code_row(c"W0117", c"'++' and '--' are not supported on ndarray elements")
	diag_code_row(c"W0118", c"multi-assignment arity mismatch: @ targets but @ values")
	diag_code_row(c"W0119", c"multi-assignment does not support map or set elements")
	diag_code_row(c"W0120", c"multi-assignment does not support ndarray elements")
	diag_code_row(c"W0121", c"multi-assignment does not support struct values")
	diag_code_row(c"W0122", c"no operator '@' for operands '@', '@'")
	diag_code_row(c"W0123", c"operator '@' cannot be overloaded")
	diag_code_row(c"W0124", c"operator definitions do not support variadic parameters")
	diag_code_row(c"W0125", c"operator definition takes 2 parameters")
	diag_code_row(c"W0126", c"operator parameters require a struct type")
	diag_code_row(c"W0127", c"'in' on a list requires scalar or char* elements")
	diag_code_row(c"W0128", c"right operand of 'in' must be a map, set, or list")
	diag_code_row(c"W0129", c"cannot cast to a struct value")
	diag_code_row(c"W0130", c"cannot cast an address to a sub-word integer")
	diag_code_row(c"W0131", c"cannot convert '@' to var")
	diag_code_row(c"W0132", c"cannot convert var to '@'")
	diag_code_row(c"W0133", c"cannot infer a type for '@' from a bare function name")
	diag_code_row(c"W0134", c"cannot infer a type for '@' from a void expression")
	diag_code_row(c"W0135", c"cannot initialize fixed-array field in constructor")
	diag_code_row(c"W0136", c"cannot mix positional and named constructor arguments")
	diag_code_row(c"W0137", c"cannot allocate array of zero-sized type")
	diag_code_row(c"W0138", c"cannot initialize global '@' of type '@' at its declaration; assign it inside a function")
	diag_code_row(c"W0139", c"fixed array initializer is not implemented")
	diag_code_row(c"W0140", c"fixed array fields are not implemented in unions")
	diag_code_row(c"W0141", c"fixed array parameter is not implemented; use T[] instead")
	diag_code_row(c"W0142", c"array length must be positive")
	diag_code_row(c"W0143", c"kernels cannot be called; use 'launch'")
	# constants
	diag_code_row(c"W0144", c"@: division by zero in constant expression")
	diag_code_row(c"W0145", c"@: shift count must be 0..31 in a constant expression")
	diag_code_row(c"W0146", c"@: constant expression overflows 32 bits")
	diag_code_row(c"W0147", c"@: ')' expected in constant expression")
	diag_code_row(c"W0148", c"@: ')' expected after sizeof type")
	diag_code_row(c"W0149", c"@ must be a compile-time constant, got '@'")
	diag_code_row(c"W0150", c"default value for parameter must be a single compile-time constant")
	diag_code_row(c"W0151", c"bignum overflow")
	diag_code_row(c"W0152", c"bignum quotient overflow")
	# functions and parameters
	diag_code_row(c"W0153", c"default values are only supported on the first 10 parameters")
	diag_code_row(c"W0154", c"variadic parameter must be the last parameter")
	diag_code_row(c"W0155", c"a variadic parameter cannot follow parameters with default values")
	diag_code_row(c"W0156", c"variadic functions support at most 10 parameters")
	diag_code_row(c"W0157", c"variadic parameter element type must be word-sized")
	diag_code_row(c"W0158", c"variadic parameter element type cannot be var")
	diag_code_row(c"W0159", c"a variadic parameter cannot have a default value")
	diag_code_row(c"W0160", c"default values are not supported on var parameters")
	diag_code_row(c"W0161", c"parameter without a default follows a parameter with a default")
	diag_code_row(c"W0162", c"too many arguments in variadic call")
	diag_code_row(c"W0163", c"struct arguments are not supported in variadic C calls")
	diag_code_row(c"W0164", c"'export' must be followed by a function definition")
	diag_code_row(c"W0165", c"'export' is not supported on generic functions")
	diag_code_row(c"W0166", c"'export' is not supported on operator overloads")
	diag_code_row(c"W0167", c"only functions can be exported")
	diag_code_row(c"W0168", c"cannot export a variadic function")
	diag_code_row(c"W0169", c"exported functions support at most 10 parameters")
	diag_code_row(c"W0170", c"cannot export a function returning a struct by value")
	diag_code_row(c"W0171", c"exported function parameters must be single words")
	diag_code_row(c"W0172", c"export name '@' collides with a reserved module export")
	diag_code_row(c"W0173", c"exported function '@' is never defined")
	diag_code_row(c"W0174", c"too many exported functions")
	diag_code_row(c"W0175", c"Failed to find a _main() function. Did you import lib/testing?")
	# control flow
	diag_code_row(c"W0176", c"'break' outside of a loop or switch")
	diag_code_row(c"W0177", c"'continue' outside of a loop")
	diag_code_row(c"W0178", c"'return' is not supported in 'gpu for'")
	diag_code_row(c"W0179", c"generators cannot return a value; use yield")
	diag_code_row(c"W0180", c"'yield' outside of a generator body")
	diag_code_row(c"W0181", c"'?' is not supported in gpu code")
	diag_code_row(c"W0182", c"'?' is not supported in generator bodies")
	diag_code_row(c"W0183", c"'?' outside of a function")
	diag_code_row(c"W0184", c"'?' operand struct has no 'value' field")
	diag_code_row(c"W0185", c"'?' requires a wresult[...]* operand, got '@'")
	diag_code_row(c"W0186", c"'?' requires the enclosing function to return a wresult[...]*, got '@'")
	diag_code_row(c"W0187", c"'defer' outside of a function")
	diag_code_row(c"W0188", c"'defer' is not supported in gpu code")
	diag_code_row(c"W0189", c"'defer' is not supported in generator bodies")
	diag_code_row(c"W0190", c"'return' is not allowed in a deferred statement")
	diag_code_row(c"W0191", c"'defer' cannot be nested in a deferred statement")
	diag_code_row(c"W0192", c"deferred statement must be a simple expression statement")
	diag_code_row(c"W0193", c"deferred statement cannot declare a variable")
	diag_code_row(c"W0194", c"cannot reopen deferred statement file '@'")
	diag_code_row(c"W0195", c"'goto' and labels are only supported on native targets (not wasm or gpu code)")
	diag_code_row(c"W0196", c"switch on a float value is not supported")
	diag_code_row(c"W0197", c"switch on a var value is not supported")
	diag_code_row(c"W0198", c"switch expression must be a word-sized value")
	diag_code_row(c"W0199", c"switch expression must be an int-like value, a string or a char*, got '@'")
	# loops and iteration
	diag_code_row(c"W0200", c"range() takes 1-3 arguments")
	diag_code_row(c"W0201", c"range iteration takes one loop variable")
	diag_code_row(c"W0202", c"type '@' is not iterable: expected a pointer to a container struct")
	diag_code_row(c"W0203", c"type '@' is not iterable: @ not found")
	diag_code_row(c"W0204", c"type '@' is not iterable: @ is not a function")
	diag_code_row(c"W0205", c"type '@' is not iterable: @ has wrong arity")
	diag_code_row(c"W0206", c"type '@' is not iterable: @ must return a word-sized value")
	diag_code_row(c"W0207", c"type '@' is not iterable: @ first parameter must match the iterable type")
	diag_code_row(c"W0208", c"type '@' is not iterable: @ second parameter must be int")
	diag_code_row(c"W0209", c"type '@' is not iterable: @ must take exactly one type parameter")
	diag_code_row(c"W0210", c"type '@' is not iterable: @ has an unknown type argument")
	diag_code_row(c"W0211", c"sets have no values: use one loop variable")
	diag_code_row(c"W0212", c"slice iteration requires scalar or pointer elements")
	diag_code_row(c"W0213", c"string iteration requires import lib.utf8")
	diag_code_row(c"W0214", c"type not found in for_statement loop variable")
	diag_code_row(c"W0215", c"type not found in for_statement value variable")
	diag_code_row(c"W0216", c"enumerate requires a list, got '@'")
	diag_code_row(c"W0217", c"enumerate requires two loop variables: for i, x in enumerate(l)")
	diag_code_row(c"W0218", c"only maps and lists support two loop variables")
	diag_code_row(c"W0219", c"for loop variable must be a word-sized type")
	diag_code_row(c"W0220", c"for loop value variable must be a word-sized type")
	# generics
	diag_code_row(c"W0221", c"cannot reopen generic definition file '@'")
	diag_code_row(c"W0222", c"too many type parameters")
	diag_code_row(c"W0223", c"too many type arguments")
	diag_code_row(c"W0224", c"wrong number of type arguments for generic '@': expected @, got @")
	diag_code_row(c"W0225", c"variadic parameters are not supported in generic functions")
	diag_code_row(c"W0226", c"default parameter values are not supported in generic functions")
	diag_code_row(c"W0227", c"generic function '@': cannot infer type parameter '@' from argument @: expected a pointer, got '@'")
	diag_code_row(c"W0228", c"generic function '@': cannot infer type parameter '@' from argument @: a bare function name has no value type; use explicit type arguments")
	diag_code_row(c"W0229", c"generic function '@': conflicting types inferred for type parameter '@': '@' vs '@'")
	diag_code_row(c"W0230", c"generic function '@': cannot infer type argument '@'; use explicit type arguments, e.g. '@[int](...)'")
	diag_code_row(c"W0231", c"generic function '@': inferred call returns a struct by value; use explicit type arguments, e.g. '@[int](...)'")
	diag_code_row(c"W0232", c"generic function '@' requires explicit type arguments, e.g. '@[int](...)'")
	diag_code_row(c"W0233", c"generic function '@' has no body")
	diag_code_row(c"W0234", c"generic function '@' is not defined (called at @:@)")
	diag_code_row(c"W0235", c"generic function '@' called with the wrong number of type arguments (called at @:@)")
	diag_code_row(c"W0236", c"generic function '@' returns a struct by value, so it must be defined before the call (called at @:@)")
	diag_code_row(c"W0237", c"')' expected in call to generic '@'")
	# generators
	diag_code_row(c"W0238", c"generator functions require 'import lib.generator'")
	diag_code_row(c"W0239", c"variadic generator parameters are not supported")
	diag_code_row(c"W0240", c"generator parameters must be word-sized")
	diag_code_row(c"W0241", c"generator yield type must be a word-sized value")
	diag_code_row(c"W0242", c"struct arguments are not supported in generator calls")
	# containers and builtins
	diag_code_row(c"W0243", c"list element type cannot be a fixed-size array")
	diag_code_row(c"W0244", c"list element type must have a size")
	diag_code_row(c"W0245", c"list element type cannot contain fixed-size array fields")
	diag_code_row(c"W0246", c"list element type must be word-sized")
	diag_code_row(c"W0247", c"map value type cannot be a fixed-size array")
	diag_code_row(c"W0248", c"map value type cannot contain fixed-size array fields")
	diag_code_row(c"W0249", c"map value type must be word-sized")
	diag_code_row(c"W0250", c"map default does not support struct value types")
	diag_code_row(c"W0251", c"map default with no argument requires a container value type")
	diag_code_row(c"W0252", c"map default for a container or pointer value type must be a factory function")
	diag_code_row(c"W0253", c"map add requires an integer or float value type")
	diag_code_row(c"W0254", c"map add does not support float16 values")
	diag_code_row(c"W0255", c"list map callback must return a value")
	diag_code_row(c"W0256", c"list reduce init must be a scalar value")
	diag_code_row(c"W0257", c"list @ requires int-like elements")
	diag_code_row(c"W0258", c"list @ requires int-like or char* elements, got '@'")
	diag_code_row(c"W0259", c"list @ requires scalar elements, got '@'")
	diag_code_row(c"W0260", c"list @ expects a function, got '@'")
	diag_code_row(c"W0261", c"list @ expression must be a scalar value, got '@'")
	diag_code_row(c"W0262", c"list @ condition must be an int-like or pointer value, got '@'")
	diag_code_row(c"W0263", c"ndarray index requires accessor '@' in scope")
	diag_code_row(c"W0264", c"ndarray index supports at most 4 indices")
	diag_code_row(c"W0265", c"comma-separated indexing requires an ndarray or matrix (ndf, ndi, ndf64 or matrix), got '@'")
	diag_code_row(c"W0266", c"print does not support float64 yet")
	diag_code_row(c"W0267", c"print supports lists of scalar elements only")
	diag_code_row(c"W0268", c"print does not support float list elements yet")
	diag_code_row(c"W0269", c"print requires an argument")
	diag_code_row(c"W0270", c"unsupported print argument type: '@'")
	diag_code_row(c"W0271", c"unsupported len argument type: '@'")
	diag_code_row(c"W0272", c"unsupported template string expression type: '@'")
	diag_code_row(c"W0273", c"enum_name argument must be an enum value, got '@'")
	diag_code_row(c"W0274", c"the prelude input helpers take no arguments")
	diag_code_row(c"W0275", c"prelude '@' argument must be an int-like value: '@'")
	diag_code_row(c"W0276", c"prelude '@' argument must be a list of int-like elements: '@'")
	diag_code_row(c"W0277", c"prelude '@' argument must be a char* or string: '@'")
	diag_code_row(c"W0278", c"prelude '@' argument must be a list of char* or string: '@'")
	diag_code_row(c"W0279", c"prelude '@' separator must be a char* or string: '@'")
	diag_code_row(c"W0280", c"@ requires 'import structures.json'")
	diag_code_row(c"W0281", c"to_json argument must be a struct value or struct pointer")
	diag_code_row(c"W0282", c"to_json does not support unions")
	diag_code_row(c"W0283", c"from_json target must be a struct type")
	diag_code_row(c"W0284", c"from_json does not support unions")
	diag_code_row(c"W0285", c"to_json/from_json map fields need char* or string keys: '@'")
	diag_code_row(c"W0286", c"unsupported to_json/from_json field type: '@'")
	diag_code_row(c"W0287", c"@ requires 'import libs.extras.protobuf.message'")
	diag_code_row(c"W0288", c"protobuf field type '@' needs a 64-bit target (x64 or arm64)")
	diag_code_row(c"W0289", c"unknown protobuf field type '@'")
	diag_code_row(c"W0290", c"unsupported protobuf field type '@'")
	diag_code_row(c"W0291", c"protobuf field '@' needs a field number: '= N'")
	diag_code_row(c"W0292", c"protobuf field number must be an integer literal")
	diag_code_row(c"W0293", c"protobuf field number must be between 1 and 536870911")
	diag_code_row(c"W0294", c"protobuf field numbers 19000-19999 are reserved")
	diag_code_row(c"W0295", c"too many fields in protobuf message")
	diag_code_row(c"W0296", c"protobuf message '@' is declared but never defined")
	diag_code_row(c"W0297", c"protobuf runtime function '@' is not defined; import libs.extras.protobuf.message")
	diag_code_row(c"W0298", c"to_proto argument must be a protobuf message value or message pointer")
	diag_code_row(c"W0299", c"from_proto target must be a protobuf message type")
	diag_code_row(c"W0300", c"proto_descriptor argument must be a protobuf message type")
	# targets, FFI and linking
	diag_code_row(c"W0301", c"float64 requires the x64 target")
	diag_code_row(c"W0302", c"int64 requires the x64 target")
	diag_code_row(c"W0303", c"gpu: float16 is not implemented")
	diag_code_row(c"W0304", c"wasm: float16 is not implemented")
	diag_code_row(c"W0305", c"arm64: float16 is not implemented")
	diag_code_row(c"W0306", c"c_import is not supported on the wasm target")
	diag_code_row(c"W0307", c"c_import expects a \"soname\" string literal")
	diag_code_row(c"W0308", c"c_import expects a header path string literal")
	diag_code_row(c"W0309", c"c_lib expects a \"soname\" string literal")
	diag_code_row(c"W0310", c"extern alias expects a \"symbol\" string literal")
	diag_code_row(c"W0311", c"extern data objects are not supported on arm64 targets yet")
	diag_code_row(c"W0312", c"extern data objects are not supported on the wasm target")
	diag_code_row(c"W0313", c"extern data object needs a sized type")
	diag_code_row(c"W0314", c"too many extern parameters")
	diag_code_row(c"W0315", c"variadic extern functions are not supported on the wasm target")
	diag_code_row(c"W0316", c"variadic extern calls are not supported on arm64_darwin yet")
	diag_code_row(c"W0317", c"arm64_darwin extern calls support at most 8 integer and 8 float arguments")
	diag_code_row(c"W0318", c"too many c_lib entries")
	diag_code_row(c"W0319", c"too many extern imports")
	diag_code_row(c"W0320", c"imported data objects are not supported on the win64 target")
	diag_code_row(c"W0321", c"extern used without any c_lib to import from")
	diag_code_row(c"W0322", c"extern import declared before any c_lib")
	diag_code_row(c"W0323", c"thread_local is only supported on the x86 and x64 Linux targets")
	diag_code_row(c"W0324", c"thread_local is not supported in the REPL or debugger")
	diag_code_row(c"W0325", c"thread_local fixed arrays are not supported; use a pointer")
	diag_code_row(c"W0326", c"thread_local applies to variables, not functions")
	diag_code_row(c"W0327", c"thread_local variables cannot have an initializer; they start zeroed")
	diag_code_row(c"W0328", c"thread_local storage exceeds 1MB")
	diag_code_row(c"W0329", c"thread_local: no __w_tls_size stub on this target")
	diag_code_row(c"W0330", c"Mach-O headerpad has no room for LC_CODE_SIGNATURE")
	diag_code_row(c"W0331", c"Mach-O load commands overflow the headerpad")
	diag_code_row(c"W0332", c"could not write output file")
	diag_code_row(c"W0333", c"could not open the --ptx output file")
	diag_code_row(c"W0334", c"arm64: unsupported setcc opcode")
	diag_code_row(c"W0335", c"c_import: unsupported C type '@'")
	diag_code_row(c"W0336", c"c_import: header parse failed")
	diag_code_row(c"W0337", c"c preprocessor: include not found: @")
	diag_code_row(c"W0338", c"c preprocessor: #error in @")
	diag_code_row(c"W0339", c"c preprocessor: could not read @")
	diag_code_row(c"W0340", c"c preprocessor: invalid token paste: @ at @:@ / @:@")
	# gpu
	diag_code_row(c"W0341", c"gpu kernels require the x64 target")
	diag_code_row(c"W0342", c"gpu builtins take no arguments")
	diag_code_row(c"W0343", c"gpu code requires 'import lib.cuda'")
	diag_code_row(c"W0344", c"gpu code cannot call functions")
	diag_code_row(c"W0345", c"global variables are not accessible in gpu code")
	diag_code_row(c"W0346", c"enclosing-scope variables are not accessible in gpu code")
	diag_code_row(c"W0347", c"too many variables captured in 'gpu for'")
	diag_code_row(c"W0348", c"'gpu for' captures must be word-sized")
	diag_code_row(c"W0349", c"containers and strings cannot be captured in 'gpu for'")
	diag_code_row(c"W0350", c"'gpu for' cannot nest inside gpu code")
	diag_code_row(c"W0351", c"'gpu for' loop variable must be an int")
	diag_code_row(c"W0352", c"'gpu for' supports only range iteration")
	diag_code_row(c"W0353", c"'gpu for' supports only range(end) and range(start, end)")
	diag_code_row(c"W0354", c"'launch' is not supported in gpu code")
	diag_code_row(c"W0355", c"struct arguments are not supported in launch")
	diag_code_row(c"W0356", c"variadic kernel parameters are not supported")
	diag_code_row(c"W0357", c"kernel parameters must be word-sized")
	diag_code_row(c"W0358", c"kernel parameters cannot have default values")
	diag_code_row(c"W0359", c"a kernel declaration requires a body")
	diag_code_row(c"W0360", c"kernel '@' expects @ arguments, got @")
	diag_code_row(c"W0361", c"cannot dereference a gpu pointer in host code; copy the data with gpu_memcpy_from, or cast() to a host pointer for managed memory")
	diag_code_row(c"W0362", c"the gpu qualifier applies to the pointee type: write 'gpu T*' with a non-pointer T")
	diag_code_row(c"W0363", c"the gpu qualifier requires a pointer type: 'gpu T*'")
	diag_code_row(c"W0364", c"atomic_cas is not available in gpu code yet")
	diag_code_row(c"W0365", c"atomic_min/atomic_max are only available in gpu code")
	diag_code_row(c"W0366", c"host atomics are not available on this target yet")
	diag_code_row(c"W0367", c"gpu atomics require an int* or float32* first argument")
	diag_code_row(c"W0368", c"atomic_min/atomic_max require an int* first argument")
	diag_code_row(c"W0369", c"gpu_exp/gpu_log are only available in gpu code")
	diag_code_row(c"W0370", c"gpu_shared_f32/gpu_barrier are only available in gpu code")
	diag_code_row(c"W0371", c"gpu_shared_f32 requires a positive integer literal element count")
	diag_code_row(c"W0372", c"gpu_shared_f32: element count exceeds the 48KB shared-memory block limit")
	diag_code_row(c"W0373", c"raw_asm is not supported in gpu code")
	diag_code_row(c"W0374", c"strings are not supported in gpu code")
	diag_code_row(c"W0375", c"gpu: unsupported comparison")
	diag_code_row(c"W0376", c"--cubin-file='@': stale cubin: it has no kernel '@' (rebuild it with ptxas from a fresh --ptx dump)")
	diag_code_row(c"W0377", c"--cubin-file='@': cannot open file")
	diag_code_row(c"W0378", c"--cubin-file='@': not an ELF cubin (expected ptxas output)")
	diag_code_row(c"W0379", c"--cubin-file='@': not a CUDA cubin (ELF e_machine is not EM_CUDA)")
	# driver, imports and analysis
	diag_code_row(c"W0380", c"cannot locate '@' (searched the import roots, the current directory and every parent)")
	diag_code_row(c"W0381", c"cannot locate '@' (searched the current directory and every parent)")
	diag_code_row(c"W0382", c"cannot locate '@': import paths are dotted module names, not file paths; try 'import @'")
	diag_code_row(c"W0383", c"no such file: '@'")
	diag_code_row(c"W0384", c"unrecognized option: '@'")
	diag_code_row(c"W0385", c"missing directory after '@'")
	diag_code_row(c"W0386", c"import root is not a directory: '@'")
	diag_code_row(c"W0387", c"too many import roots at '@'")
	diag_code_row(c"W0388", c"--all-errors requires seekable source files")
	diag_code_row(c"W0389", c"could not create semantic analysis boundary pipe")
	diag_code_row(c"W0390", c"could not fork semantic analysis probe")
	diag_code_row(c"W0391", c"could not wait for semantic analysis probe")
	diag_code_row(c"W0392", c"could not restore analysis source position")
	diag_code_row(c"W0393", c"semantic analysis probe terminated unexpectedly")
	diag_code_row(c"W0394", c"stopping after 100 semantic errors")
	diag_code_row(c"W0395", c"AST-required compilation encountered an unsupported expression")
	# compiler-internal consistency checks
	diag_code_row(c"W0396", c"symbol index desync: empty index, non-empty table")
	diag_code_row(c"W0397", c"symbol index desync: top record does not end at table_pos")
	diag_code_row(c"W0398", c"symbol index: name index and scan disagree")
	diag_code_row(c"W0399", c"Error getting symbol value for '@', table[t + 1]='@'")
