/*
'w check --lint' and 'w check --fix' (docs/projects/lint.md).

--lint turns on opt-in lint rules for the files named on the command
line (never their imports: a library's findings are not the author's to
fix from here). Each finding is an ordinary warning -- counted by
--strict, emitted as NDJSON by --json -- whose message ends with the
rule name in brackets, e.g. '[unused-local]'. A line containing the
word 'nolint' suppresses every lint rule on that line.

Two families:

- Text rules, run over the raw bytes of each root before it compiles
  (lint_text_file below): trailing whitespace, CRLF line endings, runs
  of more than two blank lines, blank lines at the start or end of the
  file, lines wider than --line-length columns (120 by default), and
  the Unicode rules of issue #460: bidi controls anywhere in the file
  (Trojan Source), identifiers mixing Latin/Greek/Cyrillic letters, and
  identifiers that differ from another name in the file only by
  lookalike letters (lint_unicode_line).
- Semantic rules, hooked into the single-pass grammar: unused locals
  (lint_scope_exit), code after return/break/continue/goto
  (lint_unreachable_check), a local shadowing another local or a
  parameter (lint_check_shadow), '=' as the whole condition of an
  if/while (lint_check_condition_assign), 'x = x' (lint_self_assign_*),
  and a module imported twice by the same file (grammar/import_statement.w).
  Loop variables are exempt from unused-local and shadow: an unused
  'for int i in range(n)' counter is idiomatic, and a loop variable stays
  bound after its loop, so sibling loops reuse the name.

The existing --imports and --bool-ops checks compose with --lint but
stay separate: both audit the whole import closure, not just the roots.

--fix rewrites each root in place before compiling it, repairing every
text issue a rewrite can settle mechanically: the rules above except
line width, plus the two always-on style warnings (space indentation
and a missing final newline). Lines marked 'nolint' are left alone.
*/

# --lint: run the opt-in rules on the command-line roots
int lint_mode
# --fix: rewrite the roots' fixable text issues before compiling them
int lint_fix_mode
# --quiet: suppress the "fixed N issue(s)" note
int lint_quiet
# 0 while the tokens being parsed belong directly to a command-line root,
# >0 inside an import's nested compile (bracketed by compile_save, like
# defhash_depth)
int lint_depth
# Paths (as compile_attempt opened them) of the command-line roots
map[char*, int] lint_root_files
# Compiler-internal roots ('w check --lint compiler/lint.w' compiles w.w
# in their place): "/<path>" suffixes of files linted even though they
# compile as imports, and a flag keeping w.w itself out of the roots
char* lint_internal_roots
int lint_internal_count
int lint_skip_root_open
# "<file>:<line>:<column>:<rule>" keys already reported: generic bodies
# and defer statements are parsed more than once
map[char*, int] lint_reported
# Length in bytes of the buffer lint_read_file last returned
int lint_text_length

# 1 while for_statement parses its loop variable declarations
int lint_for_header

# Set by statement() on its way out: 1 when the statement it just parsed
# was a return/break/continue/goto, so the enclosing block loop knows the
# next statement cannot be reached
int lint_last_stmt_jumps

# If/while condition being parsed (assign-in-condition): byte offset of
# its first token plus one (0 when none), the expression nesting depth
# the condition started at, and the depth plus one of a '(' group that
# spans the whole condition (0 when none)
int lint_cond_start
int lint_cond_depth
int lint_cond_paren_depth

int lint_saved_line_number
int lint_saved_diag_line
int lint_saved_diag_column
char* lint_saved_token


int lint_tab_width():
	return 4


# line-too-long limit in columns; --line-length=N sets it, 0 disables
int lint_line_limit


# Called by compile_attempt once a file opens: a file opened at depth 0
# is a command-line root.
void lint_note_open(char* path):
	if ((lint_mode == 0) || (lint_depth != 0) || lint_skip_root_open):
		return
	if (lint_root_files == 0):
		lint_root_files = new map[char*, int]
	lint_root_files[strclone(path)] = 1


# A compiler-internal root: lint it where it compiles, inside w.w.
void lint_note_internal_root(char* path):
	if (lint_mode == 0):
		return
	while (starts_with(path, c"./")):
		path = path + 2
	if (lint_internal_roots == 0):
		lint_internal_roots = malloc(64 * __word_size__)
	if (lint_internal_count >= 64):
		return
	save_ptr(lint_internal_roots + lint_internal_count * __word_size__, cast(int, strjoin(c"/", path)))
	lint_internal_count = lint_internal_count + 1


# Whether the tokens being parsed right now belong to a linted root.
int lint_file_active():
	if ((lint_mode == 0) || (filename == 0)):
		return 0
	if ((lint_depth == 0) && (lint_root_files != 0)):
		if (filename in lint_root_files):
			return 1
	int i = 0
	while (i < lint_internal_count):
		if (ends_with(filename, cast(char*, load_ptr(lint_internal_roots + i * __word_size__)))):
			return 1
		i = i + 1
	return 0


int lint_contains(char* s, int length, char* word):
	int word_length = strlen(word)
	int i = 0
	while (i + word_length <= length):
		int j = 0
		while ((j < word_length) && (s[i + j] == word[j])):
			j = j + 1
		if (j == word_length):
			return 1
		i = i + 1
	return 0


# Point the next warning() at line/column of the current file. Returns 0
# (and changes nothing) when this finding was already reported or its
# source line says 'nolint'; otherwise the caller emits the warning and
# then calls lint_end().
int lint_begin(int line, int column, char* rule):
	char* key = strjoin(filename, c":")
	key = strjoin(key, itoa(line))
	key = strjoin(key, c":")
	key = strjoin(key, itoa(column))
	key = strjoin(key, c":")
	key = strjoin(key, rule)
	if (lint_reported == 0):
		lint_reported = new map[char*, int]
	if (key in lint_reported):
		return 0
	lint_reported[key] = 1
	lint_saved_line_number = line_number
	lint_saved_diag_line = diag_token_line
	lint_saved_diag_column = diag_token_column
	lint_saved_token = token
	line_number = line - 1
	diag_token_line = line
	diag_token_column = column
	int length = diag_context_collect()
	if (length >= 0):
		if (lint_contains(diag_context_buffer, length, c"nolint")):
			line_number = lint_saved_line_number
			diag_token_line = lint_saved_diag_line
			diag_token_column = lint_saved_diag_column
			return 0
	# --json's "token" field would otherwise name whatever token the
	# parser happens to be on; a lint finding has none of its own
	token = c""
	return 1


void lint_end():
	line_number = lint_saved_line_number
	diag_token_line = lint_saved_diag_line
	diag_token_column = lint_saved_diag_column
	token = lint_saved_token


# --- semantic rules --------------------------------------------------

# A typed or ':=' local was just declared (record t, the newest in the
# symbol index): start tracking whether anything references it.
# '_'-prefixed names opt out, the usual "intentionally unused" spelling.
void lint_track_local(int t):
	if (lint_file_active() == 0):
		return
	int p = sym_index_count - 1
	if (p < 0):
		return
	if (sym_index_offset(p) != t):
		return
	if (lint_for_header):
		sym_index_lint[p] = 3
		return
	if (table[t + 1] != 'L'):
		return
	if (table[sym_index_name_start(p)] == '_'):
		return
	sym_index_lint[p] = 1


# The newest record is a loop variable: never tracked, never shadowed
# (3 in sym_index_lint).
void lint_mark_loop_variable():
	if (lint_mode == 0):
		return
	int p = sym_index_count - 1
	if (p >= 0):
		sym_index_lint[p] = 3


# A block is about to truncate the symbol table back to n: report every
# tracked local declared inside it that nothing referenced.
void lint_scope_exit(int n):
	if (lint_mode == 0):
		return
	int p = sym_index_count - 1
	while ((p >= 0) && (sym_index_offset(p) >= n)):
		if (sym_index_lint[p] == 1):
			sym_index_lint[p] = 0
			int t = sym_index_offset(p)
			if (lint_begin(sym_decl_line(t), sym_decl_column(t), c"unused-local")):
				warning3(c"warning: local variable '", &table[sym_index_name_start(p)], c"' is never used [unused-local]")
				lint_end()
		p = p - 1


# A typed local was just declared: warn when it hides a live local or
# parameter of the same name ('x := ...' already rejects this outright).
void lint_check_shadow():
	if (lint_for_header || (lint_file_active() == 0)):
		return
	int p = sym_index_count - 1
	if (p < 0):
		return
	int t = sym_index_offset(p)
	if (table[t + 1] != 'L'):
		return
	int previous = load_int(sym_index_prev + p * 4)
	if (previous < 0):
		return
	if (sym_index_lint[previous] == 3):
		return
	int previous_t = sym_index_offset(previous)
	int visibility = table[previous_t + 1]
	if ((visibility != 'L') && (visibility != 'A')):
		return
	if (lint_begin(sym_decl_line(t), sym_decl_column(t), c"shadow")):
		diag_part(c"warning: declaration of '")
		diag_part(&table[sym_index_name_start(p)])
		if (visibility == 'A'):
			diag_part(c"' shadows a parameter")
		else:
			diag_part(c"' shadows a local declared on line ")
			diag_part(itoa(sym_decl_line(previous_t)))
		warning(c" [shadow]")
		lint_end()


# Top of a block's statement loop: after_jump says the previous
# statement of this block was a return/break/continue/goto. A 'name:'
# label is a goto target, so code after it is reachable again.
void lint_unreachable_check(int after_jump):
	if (after_jump == 0):
		return
	if (lint_file_active() == 0):
		return
	if ((nextc == ':') && is_ident_start_byte(token[0])):
		return
	if (lint_begin(diag_token_line, diag_token_column, c"unreachable")):
		warning(c"warning: unreachable code after return/break/continue/goto [unreachable]")
		lint_end()


void lint_condition_begin():
	if (lint_mode == 0):
		return
	lint_cond_start = token_start_offset + 1
	lint_cond_depth = expr_nesting_depth
	lint_cond_paren_depth = 0


void lint_condition_end():
	lint_cond_start = 0
	lint_cond_paren_depth = 0


# primary_expr is opening a '(' group whose '(' starts at group_offset:
# when that is the condition's first token, the group is the condition.
void lint_condition_group(int group_offset):
	if (lint_cond_start == 0):
		return
	if (group_offset + 1 == lint_cond_start):
		lint_cond_paren_depth = expr_nesting_depth + 1


# expression() just parsed an '=': warn when it is the whole condition
# ('if x = 1', 'if (x = 1)'); '((x = 1))' and '(x = f()) != 0' stay quiet.
void lint_check_condition_assign(int line, int column):
	if (lint_cond_start == 0):
		return
	int depth = expr_nesting_depth
	if ((depth != lint_cond_depth) && (depth + 1 != lint_cond_paren_depth)):
		return
	if (lint_file_active() == 0):
		return
	if (lint_begin(line, column, c"assign-in-condition")):
		diag_part(c"warning: assignment used as a condition; use '==' to compare, ")
		warning(c"or wrap it in extra parentheses [assign-in-condition]")
		lint_end()


# expression() is about to parse the right side of 'lhs = ...'. When the
# left side was the single identifier lhs_name and the right side starts
# with that same name, returns a copy of it for lint_self_assign_end to
# confirm; otherwise 0.
char* lint_self_assign_begin(int lhs_tokens, char* lhs_name):
	if ((lint_mode == 0) || (lhs_tokens != 1)):
		return 0
	if (is_ident_start_byte(token[0]) == 0):
		return 0
	if (strcmp(token, lhs_name) != 0):
		return 0
	if (lint_file_active() == 0):
		return 0
	return strclone(token)


void lint_self_assign_end(char* name, int rhs_tokens, int line, int column):
	if (name == 0):
		return
	if (rhs_tokens == 1):
		if (lint_begin(line, column, c"self-assign")):
			warning3(c"warning: '", name, c"' is assigned to itself [self-assign]")
			lint_end()
	free(name)


# --- text rules and --fix ----------------------------------------------

# The whole file as a malloc'd NUL-terminated buffer (length in
# lint_text_length), or 0 when it cannot be read.
char* lint_read_file(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0):
		return 0
	int size = file_size(fd)
	if (size < 0):
		close(fd)
		return 0
	char* buffer = malloc(size + 1)
	int got = 0
	while (got < size):
		int n = read(fd, buffer + got, size - got)
		if (n <= 0):
			size = got
		else:
			got = got + n
	close(fd)
	buffer[got] = 0
	lint_text_length = got
	return buffer


# Lexical state at the end of src[start, end) given the state at its
# start: 0 code, 1 inside a /* */ comment, 2 inside a string literal. A
# '#' comment or an unterminated char literal ends the line in state 0.
int lint_scan_line(char* src, int start, int end, int state):
	int j = start
	while (j < end):
		int c = src[j]
		if (state == 1):
			if ((c == '*') && (j + 1 < end) && (src[j + 1] == '/')):
				state = 0
				j = j + 1
		else if (state == 2):
			if (c == 92):
				j = j + 1
			else if (c == '"'):
				state = 0
		else if (c == '#'):
			return 0
		else if (c == '"'):
			state = 2
		else if (c == 39):
			j = j + 1
			while ((j < end) && (src[j] != 39)):
				if (src[j] == 92):
					j = j + 1
				j = j + 1
		else if ((c == '/') && (j + 1 < end) && (src[j + 1] == '*')):
			state = 1
			j = j + 1
		j = j + 1
	return state


# Display width of src[start, end): tabs advance to the next multiple of
# lint_tab_width(), UTF-8 continuation bytes take no column.
int lint_line_width(char* src, int start, int end):
	int width = 0
	int j = start
	while (j < end):
		int c = src[j] & 255
		if (c == 9):
			width = width + lint_tab_width() - width % lint_tab_width()
		else if ((c & 192) != 128):
			width = width + 1
		j = j + 1
	return width


int lint_is_blank(char* src, int start, int end):
	int j = start
	while (j < end):
		if ((src[j] != ' ') && (src[j] != 9)):
			return 0
		j = j + 1
	return 1


# --- Unicode rules (issue #460) -----------------------------------------

# Codepoint at src[j] (NUL-free UTF-8, end-exclusive); its byte length
# lands in lint_decode_length. A malformed sequence decodes as its lead
# byte, one byte long.
int lint_decode_length


int lint_decode(char* src, int j, int end):
	int c = src[j] & 255
	lint_decode_length = 1
	int extra = 0
	if ((c & 224) == 192):
		extra = 1
		c = c & 31
	else if ((c & 240) == 224):
		extra = 2
		c = c & 15
	else if ((c & 248) == 240):
		extra = 3
		c = c & 7
	if (j + extra >= end + 1):
		return src[j] & 255
	int k = 1
	while (k <= extra):
		int b = src[j + k] & 255
		if ((b & 192) != 128):
			return src[j] & 255
		c = (c << 6) | (b & 63)
		k = k + 1
	lint_decode_length = extra + 1
	return c


# Bidi embedding/override/isolate controls and the Arabic letter mark:
# the characters CVE-2021-42574 ("Trojan Source") reorders a line with
int lint_is_bidi_control(int cp):
	if ((cp >= 8234) && (cp <= 8238)):
		return 1
	if ((cp >= 8294) && (cp <= 8297)):
		return 1
	return cp == 1564


# 1 Latin, 2 Greek, 3 Cyrillic, 0 anything else (digits, '_', other
# scripts): the lookalike-prone scripts the mixed-script rule separates
int lint_script(int cp):
	if ((('a' <= cp) && (cp <= 'z')) || (('A' <= cp) && (cp <= 'Z'))):
		return 1
	if ((cp >= 192) && (cp <= 591) && (cp != 215) && (cp != 247)):
		return 1
	if ((cp >= 880) && (cp <= 1023)):
		return 2
	if ((cp >= 1024) && (cp <= 1279)):
		return 3
	return 0


char* lint_script_name(int script):
	if (script == 1):
		return c"Latin"
	if (script == 2):
		return c"Greek"
	return c"Cyrillic"


# Greek and Cyrillic letters that render like a Latin letter, as
# "<4 hex digits><latin letter>" entries; not the full Unicode
# confusables data, just the practical lookalikes
char* lint_confusable_cache


char* lint_confusable_table():
	if (lint_confusable_cache == 0):
		char* cyrillic = c"0430a0435e043Eo0440p0441c0443y0445x0456i0458j0455s04BBh"
		cyrillic = strjoin(cyrillic, c"0410A0412B0415E041AK041CM041DH041EO0420P0421C0422T0425X0406I0408J0405S")
		char* greek = c"0391A0392B0395E0396Z0397H0399I039AK039CM039DN039FO03A1P03A4T03A5Y03A7X"
		greek = strjoin(greek, c"03BFo03BDv03B9i03C1p")
		lint_confusable_cache = strjoin(cyrillic, greek)
	return lint_confusable_cache


int lint_hex_digit(int c):
	if (('0' <= c) && (c <= '9')):
		return c - '0'
	return c - 'A' + 10


# The Latin letter cp is confusable with, or 0
int lint_confusable_ascii(int cp):
	char* table = lint_confusable_table()
	int i = 0
	while (table[i] != 0):
		int v = 0
		int d = 0
		while (d < 4):
			v = (v << 4) | lint_hex_digit(table[i + d])
			d = d + 1
		if (v == cp):
			return table[i + 4]
		i = i + 5
	return 0


# Per-file state of the confusable rule: skeleton -> first spelling (a
# char* stored as an int) and its line, plus the spellings already reported
map[char*, int] lint_skeleton_spelling
map[char*, int] lint_skeleton_line
map[char*, int] lint_unicode_warned


void lint_unicode_reset():
	lint_skeleton_spelling = new map[char*, int]
	lint_skeleton_line = new map[char*, int]
	lint_unicode_warned = new map[char*, int]


# 1-based codepoint column of src[pos] on the line starting at start,
# matching the compiler's own diagnostic columns
int lint_codepoint_column(char* src, int start, int pos):
	int column = 1
	int j = start
	while (j < pos):
		if ((src[j] & 192) != 128):
			column = column + 1
		j = j + 1
	return column


char* lint_substring(char* src, int start, int end):
	char* out = malloc(end - start + 1)
	int j = 0
	while (start + j < end):
		out[j] = src[start + j]
		j = j + 1
	out[j] = 0
	return out


# mixed-script and confusable checks for the identifier src[s, e)
void lint_identifier(char* src, int s, int e, int line, int column):
	int ascii = 1
	int j = s
	while (j < e):
		if ((src[j] & 128) != 0):
			ascii = 0
		j = j + 1
	char* name = lint_substring(src, s, e)
	# Skeleton: every lookalike letter replaced by its Latin twin
	char* skeleton = malloc(e - s + 1)
	int k = 0
	int first_script = 0
	int second_script = 0
	j = s
	while (j < e):
		int cp = lint_decode(src, j, e)
		int length = lint_decode_length
		int script = lint_script(cp)
		if (script != 0):
			if (first_script == 0):
				first_script = script
			else if ((script != first_script) && (second_script == 0)):
				second_script = script
		int twin = 0
		if (ascii == 0):
			twin = lint_confusable_ascii(cp)
		if (twin != 0):
			skeleton[k] = twin
			k = k + 1
		else:
			int b = 0
			while (b < length):
				skeleton[k] = src[j + b]
				k = k + 1
				b = b + 1
		j = j + length
	skeleton[k] = 0
	char* mixed_key = strjoin(c"mixed:", name)
	if ((second_script != 0) && ((mixed_key in lint_unicode_warned) == 0)):
		lint_unicode_warned[mixed_key] = 1
		if (lint_begin(line, column, c"mixed-script")):
			diag_part(c"warning: identifier '")
			diag_part(name)
			diag_part(c"' mixes ")
			diag_part(lint_script_name(first_script))
			warning3(c" and ", lint_script_name(second_script), c" letters [mixed-script]")
			lint_end()
	if (skeleton in lint_skeleton_spelling):
		char* other = cast(char*, lint_skeleton_spelling[skeleton])
		char* confusable_key = strjoin(c"confusable:", name)
		if ((strcmp(other, name) != 0) && ((confusable_key in lint_unicode_warned) == 0)):
			lint_unicode_warned[confusable_key] = 1
			if (lint_begin(line, column, c"confusable")):
				diag_part(c"warning: identifier '")
				diag_part(name)
				diag_part(c"' looks like '")
				diag_part(other)
				warning3(c"' from line ", itoa(lint_skeleton_line[skeleton]), c" but is a different name [confusable]")
				lint_end()
		free(skeleton)
	else:
		lint_skeleton_spelling[skeleton] = cast(int, strclone(name))
		lint_skeleton_line[skeleton] = line
	free(name)


void lint_bidi_report(char* src, int start, int pos, int cp, int line, int state):
	if (lint_begin(line, lint_codepoint_column(src, start, pos), c"bidi-control")):
		diag_part(c"warning: bidirectional control character U+")
		diag_part(ident_codepoint_hex(cp))
		if (state == 1):
			diag_part(c" in a comment")
		else if (state == 2):
			diag_part(c" in a string literal")
		diag_part(c" can make this line display differently from how it compiles")
		warning(c" (Trojan Source) [bidi-control]")
		lint_end()


# Walk one line with lint_scan_line's lexical states: report bidi
# controls anywhere on it, and hand every identifier in code to
# lint_identifier. Only lines holding a byte >= 0x80 can trip a rule,
# but every line's identifiers are recorded as confusable references.
void lint_unicode_line(char* src, int start, int end, int state, int line):
	int j = start
	while (j < end):
		int c = src[j] & 255
		if (c >= 128):
			int cp = lint_decode(src, j, end)
			if (lint_is_bidi_control(cp)):
				lint_bidi_report(src, start, j, cp, line, state)
		if (state == 1):
			if ((c == '*') && (j + 1 < end) && (src[j + 1] == '/')):
				state = 0
				j = j + 1
		else if (state == 2):
			if (c == 92):
				j = j + 1
			else if (c == '"'):
				state = 0
		else if (c == '#'):
			# The rest of the line is a comment
			state = 1
			j = j + 1
			while (j < end):
				if ((src[j] & 128) != 0):
					int comment_cp = lint_decode(src, j, end)
					if (lint_is_bidi_control(comment_cp)):
						lint_bidi_report(src, start, j, comment_cp, line, 1)
				j = j + 1
		else if (c == '"'):
			state = 2
		else if (c == 39):
			j = j + 1
			while ((j < end) && (src[j] != 39)):
				if ((src[j] & 128) != 0):
					int char_cp = lint_decode(src, j, end)
					if (lint_is_bidi_control(char_cp)):
						lint_bidi_report(src, start, j, char_cp, line, 2)
				if (src[j] == 92):
					j = j + 1
				j = j + 1
		else if ((c == '/') && (j + 1 < end) && (src[j + 1] == '*')):
			state = 1
			j = j + 1
		else if (is_ident_start_byte(c)):
			int s = j
			int in_name = 1
			while ((j < end) && in_name):
				if (is_utf8_lead_byte(src[j])):
					lint_decode(src, j, end)
					j = j + lint_decode_length
				else if (is_ident_part_byte(src[j])):
					j = j + 1
				else:
					in_name = 0
			# 'c"..."' / 's"..."' / 'f"..."' prefixes open a string instead
			if ((j < end) && (src[j] == '"') && (j - s == 1)):
				j = j - 1
			else:
				lint_identifier(src, s, j, line, lint_codepoint_column(src, start, s))
				j = j - 1
		else if (('0' <= c) && (c <= '9')):
			while ((j + 1 < end) && is_ident_part_byte(src[j + 1])):
				j = j + 1
		j = j + 1


# Count of fixes lint_text_file applied to the current buffer, and
# whether the text pass may report (lint_mode) at all
int lint_text_fixes


# One text-rule finding at line/column of the file being scanned.
# fixable findings are repaired instead of reported under --fix.
void lint_text_report(int line, int column, char* message, int fixable):
	if (fixable && lint_fix_mode):
		lint_text_fixes = lint_text_fixes + 1
		return
	if (lint_mode == 0):
		return
	if (lint_begin(line, column, message)):
		warning(message)
		lint_end()


int lint_write_file(char* path, char* text, int length):
	/* O_WRONLY|O_CREAT|O_TRUNC; an existing file keeps its mode */
	int fd = open(path, 577, 420)
	if (fd < 0):
		return 0
	int done = 0
	while (done < length):
		int n = write(fd, text + done, length - done)
		if (n <= 0):
			close(fd)
			return 0
		done = done + n
	close(fd)
	return 1


# Run the text rules over the root at path and, under --fix, rewrite it.
# Runs before the root compiles, so a fixed file is what gets checked.
void lint_text_file(char* path):
	char* src = lint_read_file(path)
	if (src == 0):
		return
	int n = lint_text_length
	char* out = malloc(n + 2)
	int o = 0
	lint_text_fixes = 0
	lint_unicode_reset()

	# Findings print against this file with no source-context block (the
	# compile has not opened it yet)
	char* saved_filename = filename
	int saved_file = file
	filename = path
	file = -1

	int state = 0
	int line = 1
	int blank_run = 0
	int seen_code = 0
	int crlf_reported = 0
	int leading_reported = 0
	int last_code_line = 0
	int last_code_end = 0
	int i = 0
	while (i < n):
		int start = i
		int end = i
		while ((end < n) && (src[end] != 10)):
			end = end + 1
		int has_newline = end < n
		int content_end = end
		int cr = 0
		if ((content_end > start) && (src[content_end - 1] == 13)):
			content_end = content_end - 1
			cr = 1
		int start_state = state
		if (lint_mode && (lint_contains(src + start, content_end - start, c"nolint") == 0)):
			lint_unicode_line(src, start, content_end, start_state, line)
		state = lint_scan_line(src, start, content_end, state)
		# Inside a multi-line string literal, or opted out: copied verbatim
		int verbatim = (start_state == 2) || lint_contains(src + start, content_end - start, c"nolint")
		int blank = (verbatim == 0) && (start_state == 0) && lint_is_blank(src, start, content_end)
		int keep = 1
		int body = start
		int text_end = content_end
		int keep_cr = cr
		int indent_width = -1
		if (blank):
			if (seen_code == 0):
				if (leading_reported == 0):
					leading_reported = 1
					lint_text_report(line, 1, c"warning: blank line at start of file [leading-blank-lines]", 1)
				keep = lint_fix_mode == 0
			else:
				blank_run = blank_run + 1
				if (blank_run == 3):
					lint_text_report(line, 1, c"warning: more than two consecutive blank lines [blank-lines]", 1)
				if (blank_run >= 3):
					keep = lint_fix_mode == 0
		else:
			seen_code = 1
			blank_run = 0
			last_code_line = line
		if (verbatim == 0):
			# Trailing whitespace, unless the line ends inside a string
			if (state != 2):
				while ((text_end > start) && ((src[text_end - 1] == ' ') || (src[text_end - 1] == 9))):
					text_end = text_end - 1
				if (text_end < content_end):
					int column = lint_line_width(src, start, text_end) + 1
					lint_text_report(line, column, c"warning: trailing whitespace [trailing-whitespace]", 1)
					if (lint_fix_mode == 0):
						text_end = content_end
			if (cr):
				if (crlf_reported == 0):
					crlf_reported = 1
					lint_text_report(line, 1, c"warning: file uses CRLF line endings [crlf]", 1)
				if (lint_fix_mode && (state != 2)):
					keep_cr = 0
			# Space indentation (the compiler itself warns about it):
			# re-indent with a tab per lint_tab_width() columns
			if (lint_fix_mode && (start_state == 0) && (blank == 0) && (src[start] == ' ')):
				int indent_end = start
				while ((indent_end < text_end) && ((src[indent_end] == ' ') || (src[indent_end] == 9))):
					indent_end = indent_end + 1
				int width = lint_line_width(src, start, indent_end)
				if (width >= lint_tab_width()):
					lint_text_fixes = lint_text_fixes + 1
					indent_width = width
					body = indent_end
			int line_width = lint_line_width(src, start, text_end)
			if ((lint_mode != 0) && (lint_line_limit > 0) && (line_width > lint_line_limit)):
				if (lint_begin(line, lint_line_limit + 1, c"line-too-long")):
					diag_part(c"warning: line is ")
					diag_part(itoa(line_width))
					warning3(c" columns wide (limit ", itoa(lint_line_limit), c") [line-too-long]")
					lint_end()
		if (keep):
			if (indent_width >= 0):
				int k = 0
				while (k < indent_width / lint_tab_width()):
					out[o] = 9
					o = o + 1
					k = k + 1
				k = 0
				while (k < indent_width % lint_tab_width()):
					out[o] = ' '
					o = o + 1
					k = k + 1
			int j = body
			while (j < text_end):
				out[o] = src[j]
				o = o + 1
				j = j + 1
			if (keep_cr):
				out[o] = 13
				o = o + 1
			if (has_newline):
				out[o] = 10
				o = o + 1
			else if (lint_fix_mode && (blank == 0)):
				# Last line without a newline (the compiler warns): add one
				lint_text_fixes = lint_text_fixes + 1
				out[o] = 10
				o = o + 1
		if (blank == 0):
			last_code_end = o
		i = end
		if (has_newline):
			i = i + 1
		line = line + 1

	# Blank lines at the end of the file
	if (seen_code && (line - 1 > last_code_line)):
		lint_text_report(last_code_line + 1, 1, c"warning: blank lines at end of file [trailing-blank-lines]", 1)
		if (lint_fix_mode):
			o = last_code_end

	filename = saved_filename
	file = saved_file

	if (lint_fix_mode && (lint_text_fixes > 0)):
		int changed = o != n
		int k = 0
		while ((changed == 0) && (k < o)):
			if (out[k] != src[k]):
				changed = 1
			k = k + 1
		if (changed):
			if (lint_write_file(path, out, o) == 0):
				print_error(str_from_cstr(c"error: could not write '"))
				print_error(str_from_cstr(path))
				print_error(str_from_cstr(c"'\x0a"))
				exit(1)
			if (lint_quiet == 0):
				print_error(str_from_cstr(c"fixed "))
				print_error(str_from_cstr(itoa(lint_text_fixes)))
				print_error(str_from_cstr(c" issue(s) in '"))
				print_error(str_from_cstr(path))
				print_error(str_from_cstr(c"'\x0a"))
	free(out)
	free(src)
