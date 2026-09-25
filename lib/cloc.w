/*
Line and token counts for W source (issue #437) -- the counting core
behind tools/wcloc.w, kept as a library so other tools (and tests) can
call it directly.

Every physical line of a file lands in exactly one bucket, following
cloc's conventions:

	code     the line holds at least one token, including a line that
	         also carries a trailing '#' comment, and every line of a
	         string literal that spans lines
	comment  no code, but part of a '#' line comment or a slash-star
	         block comment -- whitespace-only lines inside a block
	         comment count here too, so a module header stays one block
	blank    whitespace only

tokens counts the lexical tokens the compiler's tokenizer
(compiler/tokenizer.w get_token) would produce: identifiers, keywords
and numbers (a float literal like 1.5e-3 is one token), string and char
literals, and operators with the tokenizer's own merges ('<=', '&&',
'+=', '++', ':=', '/='). An f"..." template string counts one token per
literal chunk plus the tokens of each embedded {expression}, as the
tokenizer splits it. Indentation and newlines are not counted.

This is a self-contained scanner rather than a call into
compiler/tokenizer.w: that tokenizer reads through the compiler's
global file state and turns malformed input into a fatal compile
error, while a counter has to keep going over any file. Malformed
input (an unterminated literal or comment) is counted up to EOF.

cloc_collect walks directories with getdents, so it is Linux-only like
the rest of the stdlib's directory walkers (lib/shell_commands.w's du).
*/
import lib.lib
import lib.file
import lib.path
import lib.stat


struct cloc_counts:
	int files
	int blank
	int comment
	int code
	int tokens


# Scanner frame kinds. The frame stack only grows past one entry for
# f-string interpolation: an f"..." pushes a template frame, each
# embedded '{' pushes a code frame, and its closing '}' pops back.
int CLOC_CODE():
	return 0


int CLOC_TEMPLATE():
	return 1


int CLOC_STACK_MAX():
	return 64


void cloc_counts_clear(cloc_counts* c):
	c.files = 0
	c.blank = 0
	c.comment = 0
	c.code = 0
	c.tokens = 0


void cloc_counts_add(cloc_counts* into, cloc_counts* from):
	into.files = into.files + from.files
	into.blank = into.blank + from.blank
	into.comment = into.comment + from.comment
	into.code = into.code + from.code
	into.tokens = into.tokens + from.tokens


int cloc_lines(cloc_counts* c):
	return c.blank + c.comment + c.code


int cloc_is_word_char(int ch):
	return (('a' <= ch) && (ch <= 'z')) || (('A' <= ch) && (ch <= 'Z')) ||
		(('0' <= ch) && (ch <= '9')) || (ch == '_')


int cloc_is_space(int ch):
	return (ch == ' ') || (ch == 9) || (ch == 13) || (ch == 12) || (ch == 11)


# The characters the tokenizer merges into one run ('<=', '==', '&&',
# '!=', '>>=', ...).
int cloc_is_relational_char(int ch):
	return (ch == '<') || (ch == '=') || (ch == '>') || (ch == '|') ||
		(ch == '&') || (ch == '!')


# Skip a quoted literal body starting just after its opening quote at
# text[i]; returns the index just past the closing quote (or length on
# EOF). Newlines crossed on the way are reported through *newlines so
# the caller can count the spanned lines as code -- except the file's
# final newline, which an unterminated literal runs into but which
# does not start another line.
int cloc_skip_quoted(char* text, int length, int i, int quote, int* newlines):
	while (i < length):
		int ch = text[i]
		if (ch == quote):
			return i + 1
		if ((ch == 92) && (i + 1 < length)):
			i = i + 1
			ch = text[i]
		if ((ch == 10) && (i + 1 < length)):
			newlines[0] = newlines[0] + 1
		i = i + 1
	return length


# Classify the line that just ended and reset the per-line flags.
void cloc_end_line(cloc_counts* out, int has_code, int has_comment):
	if (has_code):
		out.code = out.code + 1
	else if (has_comment):
		out.comment = out.comment + 1
	else:
		out.blank = out.blank + 1


# Count one file's text (length bytes) into out: files goes up by one
# and every line and token is added to the running totals. A trailing
# newline does not start an extra empty line; a final line without one
# still counts.
void cloc_scan_text(char* text, int length, cloc_counts* out):
	out.files = out.files + 1
	int* kinds = malloc(CLOC_STACK_MAX() * __word_size__)
	int* depths = malloc(CLOC_STACK_MAX() * __word_size__)
	int top = 0
	kinds[0] = CLOC_CODE()
	depths[0] = 0
	int has_code = 0
	int has_comment = 0
	int line_started = 0
	int in_block = 0
	int newlines = 0
	int i = 0
	while (i < length):
		int ch = text[i]
		if (ch == 10):
			cloc_end_line(out, has_code, has_comment)
			has_code = 0
			has_comment = in_block
			line_started = 0
			i = i + 1
		else if (in_block):
			line_started = 1
			has_comment = 1
			if ((ch == '*') && (i + 1 < length) && (text[i + 1] == '/')):
				in_block = 0
				i = i + 2
			else:
				i = i + 1
		else if (kinds[top] == CLOC_TEMPLATE()):
			# Inside an f-string's literal text: '{{' and '}}' are
			# escaped braces, a lone '{' opens an embedded expression.
			line_started = 1
			has_code = 1
			if (ch == '"'):
				top = top - 1
				i = i + 1
			else if ((ch == '{') || (ch == '}')):
				if ((i + 1 < length) && (text[i + 1] == ch)):
					i = i + 2
				else if ((ch == '{') && (top + 1 < CLOC_STACK_MAX())):
					top = top + 1
					kinds[top] = CLOC_CODE()
					depths[top] = 0
					i = i + 1
				else:
					i = i + 1
			else if ((ch == 92) && (i + 1 < length)):
				if (text[i + 1] == 10):
					cloc_end_line(out, 1, 0)
				i = i + 2
			else:
				i = i + 1
		else if (cloc_is_space(ch)):
			line_started = 1
			i = i + 1
		else if (ch == '#'):
			line_started = 1
			has_comment = 1
			while ((i < length) && (text[i] != 10)):
				i = i + 1
		else if ((ch == '/') && (i + 1 < length) && (text[i + 1] == '*')):
			line_started = 1
			has_comment = 1
			in_block = 1
			i = i + 2
		else:
			line_started = 1
			has_code = 1
			out.tokens = out.tokens + 1
			if (cloc_is_word_char(ch)):
				int start = i
				while ((i < length) && cloc_is_word_char(text[i])):
					i = i + 1
				int run = i - start
				int prefix = text[start]
				if ((run == 1) && (i < length) && (text[i] == '"') &&
						((prefix == 's') || (prefix == 'c'))):
					newlines = 0
					i = cloc_skip_quoted(text, length, i + 1, '"', &newlines)
					while (newlines > 0):
						cloc_end_line(out, 1, 0)
						newlines = newlines - 1
				else if ((run == 1) && (i < length) && (text[i] == '"') && (prefix == 'f')):
					if (top + 1 < CLOC_STACK_MAX()):
						top = top + 1
						kinds[top] = CLOC_TEMPLATE()
						depths[top] = 0
					i = i + 1
				else if (('0' <= prefix) && (prefix <= '9')):
					# Float literal: fraction then an optional signed
					# exponent; hex tokens never take an exponent sign.
					if ((i < length) && (text[i] == '.')):
						i = i + 1
						while ((i < length) && cloc_is_word_char(text[i])):
							i = i + 1
					int last = text[i - 1]
					int is_hex = (run > 1) && ((text[start + 1] == 'x') || (text[start + 1] == 'X'))
					if ((is_hex == 0) && ((last == 'e') || (last == 'E')) && (i < length) &&
							((text[i] == '+') || (text[i] == '-'))):
						i = i + 1
						while ((i < length) && ('0' <= text[i]) && (text[i] <= '9')):
							i = i + 1
			else if ((ch == '"') || (ch == 39)):
				newlines = 0
				i = cloc_skip_quoted(text, length, i + 1, ch, &newlines)
				while (newlines > 0):
					cloc_end_line(out, 1, 0)
					newlines = newlines - 1
			else if (cloc_is_relational_char(ch)):
				while ((i < length) && cloc_is_relational_char(text[i])):
					i = i + 1
			else if ((ch == '+') || (ch == '-') || (ch == '*') || (ch == '%') ||
					(ch == '^') || (ch == '/')):
				i = i + 1
				if ((i < length) && (text[i] == '=')):
					i = i + 1
				else if ((i < length) && ((ch == '+') || (ch == '-')) && (text[i] == ch)):
					i = i + 1
			else if ((ch == ':') && (i + 1 < length) && (text[i + 1] == '=')):
				i = i + 2
			else if ((ch == '{') && (top > 0)):
				depths[top] = depths[top] + 1
				i = i + 1
			else if ((ch == '}') && (top > 0)):
				if (depths[top] == 0):
					# Closes an f-string's embedded expression: the
					# tokenizer folds this '}' into the next literal
					# chunk's token, which this token already counts.
					top = top - 1
				else:
					depths[top] = depths[top] - 1
				i = i + 1
			else:
				i = i + 1
	if (line_started):
		cloc_end_line(out, has_code, has_comment)
	free(kinds)
	free(depths)


# Count one file into out. Returns 0, or -1 when the file cannot be
# read (out is left untouched).
int cloc_scan_file(char* path, cloc_counts* out):
	char* text = file_read_text(path)
	if (text == 0):
		return -1
	cloc_scan_text(text, strlen(text), out)
	free(text)
	return 0


# d_reclen is a little-endian 16-bit field two words into each getdents
# record (the same layout lib/shell_commands.w reads).
int cloc_load_uint16(char* p):
	return (p[0] & 255) + ((p[1] & 255) << 8)


# Insertion sort, so the walk order (and so the output) does not depend
# on getdents' filesystem-dependent order.
void cloc_sort_strings(list[char*] items):
	int i = 1
	while (i < items.length):
		char* value = items[i]
		int j = i - 1
		while ((j >= 0) && (strcmp(items[j], value) > 0)):
			items[j + 1] = items[j]
			j = j - 1
		items[j + 1] = value
		i = i + 1


# Directory entries cloc_collect skips: hidden entries ('.git', ...)
# and bin/, the gitignored build-output directory.
int cloc_skip_entry(char* name):
	return (name[0] == '.') || (strcmp(name, c"bin") == 0)


# The sorted, non-skipped entry names of directory path, or an empty
# list when it cannot be opened.
list[char*] cloc_dir_entries(char* path):
	list[char*] names = new list[char*]
	int fd = open(path, 65536, 0) /* 65536 = O_DIRECTORY */
	if (fd < 0):
		return names
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int off = 0
		while (off < n):
			char* entry = buffer + off
			int reclen = cloc_load_uint16(entry + 2 * __word_size__)
			char* entry_name = entry + 2 * __word_size__ + 2
			off = off + reclen
			if (cloc_skip_entry(entry_name) == 0):
				names.push(strclone(entry_name))
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)
	cloc_sort_strings(names)
	return names


# Append every .w file under path to out, in sorted depth-first order.
# A path naming a file is appended as-is whatever its extension, so an
# explicit argument is always counted. Symlinks are not followed into
# directories. Returns -1 when path does not exist, else 0.
int cloc_collect(char* path, list[char*] out):
	file_stat st
	if (file_lstat_path(path, &st) != 0):
		return -1
	if (file_is_dir(&st) == 0):
		out.push(strclone(path))
		return 0
	list[char*] names = cloc_dir_entries(path)
	int i = 0
	while (i < names.length):
		char* child = path_join(path, names[i])
		file_stat child_st
		if (file_lstat_path(child, &child_st) == 0):
			if (file_is_dir(&child_st)):
				cloc_collect(child, out)
			else if (file_is_reg(&child_st) && ends_with(child, c".w")):
				out.push(strclone(child))
		free(child)
		free(names[i])
		i = i + 1
	return 0
