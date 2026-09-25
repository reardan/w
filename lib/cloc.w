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

cloc_collect walks directories with lib/dir.w.
*/
import lib.lib
import lib.file
import lib.path
import lib.stat
import lib.dir


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


# Directory entries cloc_collect skips: hidden entries ('.git', ...)
# and bin/, the gitignored build-output directory.
int cloc_skip_entry(char* name):
	return (name[0] == '.') || (strcmp(name, c"bin") == 0)


# The sorted, non-skipped entry names of directory path, or an empty
# list when it cannot be opened.
list[char*] cloc_dir_entries(char* path):
	list[char*] names = new list[char*]
	list[char*] all = dir_names(path)
	if (all == 0):
		return names
	for char* name in all:
		if (cloc_skip_entry(name)):
			free(name)
		else:
			names.push(name)
	list_free[char*](all)
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


# --- per-argument rows (the grouping tools/wcloc.w reports) ---

struct cloc_row:
	char* path
	int is_file
	cloc_counts* counts


# The row a file under directory root is grouped into: root itself for
# a file directly inside it, else root/<first path component>. file
# always starts with root + '/' (cloc_collect builds it with
# path_join).
char* cloc_group_path(char* root, char* file):
	int start = strlen(root)
	if ((start > 0) && (root[start - 1] != '/')):
		start = start + 1
	int end = start
	while ((file[end] != 0) && (file[end] != '/')):
		end = end + 1
	if (file[end] == 0):
		return strclone(root)
	char* group = malloc(end + 1)
	int i = 0
	while (i < end):
		group[i] = file[i]
		i = i + 1
	group[end] = 0
	return group


cloc_row* cloc_new_row(char* path, int is_file):
	cloc_row* row = new cloc_row
	row.path = path
	row.is_file = is_file
	row.counts = new cloc_counts
	cloc_counts_clear(row.counts)
	return row


# The display form of a collected path: "wcloc" with no argument (or
# ".") walks "." and cloc_collect joins every result as "./x"; showing
# "x" reads the way the tree is usually named.
char* cloc_display_path(char* path):
	if ((path[0] == '.') && (path[1] == '/') && (path[2] != 0)):
		return strclone(path + 2)
	return strclone(path)


# The row in rows[first..] whose path is key, or 0.
cloc_row* cloc_find_row(list[cloc_row*] rows, int first, char* key):
	int i = first
	while (i < rows.length):
		if (strcmp(rows[i].path, key) == 0):
			return rows[i]
		i = i + 1
	return 0


# Count every file of one argument into rows, the way wcloc reports
# them: one row per file with by_file (or when path is a file), else one
# row per top-level entry of the directory path. Rows are matched only
# among those this call adds. Files that cannot be read are appended to
# unreadable (owned by the caller) and skipped. Returns 0, or -1 when
# path does not exist.
int cloc_count_path(char* path, int by_file, list[cloc_row*] rows, list[char*] unreadable):
	list[char*] files = new list[char*]
	if (cloc_collect(path, files) != 0):
		return -1
	int path_is_file = (files.length == 1) && (strcmp(files[0], path) == 0)
	int first = rows.length
	int i = 0
	while (i < files.length):
		char* file = files[i]
		char* raw = 0
		int is_file = 1
		if (by_file || path_is_file):
			raw = strclone(file)
		else:
			raw = cloc_group_path(path, file)
			is_file = 0
		char* key = cloc_display_path(raw)
		free(raw)
		cloc_row* row = cloc_find_row(rows, first, key)
		if (row == 0):
			row = cloc_new_row(key, is_file)
			rows.push(row)
		else:
			free(key)
		cloc_counts counts
		cloc_counts_clear(&counts)
		if (cloc_scan_file(file, &counts) == 0):
			cloc_counts_add(row.counts, &counts)
			free(file)
		else:
			unreadable.push(file)
		i = i + 1
	return 0
