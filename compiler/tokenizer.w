import compiler.diagnostics
import lib.env
import lib.termios

# tokenizer
int nextc
char *token
int token_size
int token_newline
int tab_level
int line_number
int column_number
int bounds_mode

# Byte position in the current file: the number of characters read from
# the file descriptor so far, reset per file like line_number (see
# compile_attempt / compile_save). Because of the one-character lookahead
# in nextc, the offset of nextc itself is byte_offset - 1.
int byte_offset

# Byte offset of the first character of the current token, recorded by
# get_token() after skipping whitespace and comments. Generic
# definitions (grammar/generic.w) use it to re-parse a recorded source
# span later with type parameters bound.
int token_start_offset

# Number of get_token() calls so far. 'w check --lint' (compiler/lint.w)
# diffs it around a subexpression to tell whether that subexpression was
# a single token.
int token_serial

# --strict: count warnings during compilation; link_impl() fails the build
# when any fired. The count is advisory outside strict mode.
int strict_mode
int warning_count

# 'w defhash' recording: while defhash_mode is set, the grammar rules that
# recognize a top-level definition (struct/union/enum/type-alias in their
# own grammar/*.w files, function/global in grammar/program.w) call
# defhash_note() (compiler/compiler.w) with the definition's name, kind
# and byte span; defhash_note itself checks this flag and is a no-op
# when it is unset, so those call sites are unconditional. Declared here,
# next to strict_mode/warning_count, only because this is where that
# kind of whole-compile mode flag already lives -- everything else
# defhash-specific (defhash_note, the recorded-definition arrays,
# defhash_dump) lives in compiler/compiler.w next to the analogous
# deps_mode machinery.
int defhash_mode

# Re-tokenizing an already-compiled byte span (defhash_span_hash in
# compiler/compiler.w) replays bytes the real compile already lexed
# without error, so any lexer warning it would fire (e.g. the
# space-indentation hint) was already reported once. defhash_rehash_mode
# tells warning() below to stay silent while the replay is in progress.
int defhash_rehash_mode

# Recursive-descent nesting guards (docs/projects/ai_tooling_next_steps.md,
# "No recursion-depth guard in the recursive-descent parser"): thousands
# of nested parens, calls, subscripts, ternaries or statement blocks
# recurse the parser's own call stack until it SIGSEGVs with no
# diagnostic at all -- confirmed by direct measurement (a paren or call
# chain crashes native between ~40000 and ~60000 levels deep; the
# smaller-frame ternary/unary/assignment cycles by ~2 million).
# expr_nesting_depth is incremented/checked/decremented at three sites
# that together cover every expression-grammar cycle: the entry of
# grammar/unary_expression.w's unary_expression() (the one function
# every operand-position recursion -- '(' grouping, call arguments,
# index subscripts, stacked unary operators, cast/constructor/literal
# arguments -- descends through per nesting level while its enclosing
# frames are still live), the ternary branch of
# grammar/conditional_expr.w (ternary chains recurse above the operand
# level, after each level's condition operand has returned), and the
# assignment branches of grammar/expression.w ('a = b = ...' chains
# recurse expression() directly the same way). stmt_nesting_depth wraps
# the whole body of grammar/statement.w's statement() (the single
# function every nested block/if/while/for/switch body recurses back
# through, so guarding it once there covers every statement-level
# recursion path without touching each caller).
# stmt_nesting_depth's limit is far smaller than expr_nesting_depth's,
# but still has to clear the tree's longest legitimate 'else if' dispatch
# chain (lib/lib.w's errno-to-string table, 132 branches deep -- each
# 'else if' recurses statement() once, same as true block nesting) --
# see grammar/statement.w for the exact number and its relationship to
# code_generator/x86.w's separate fixed-size int[256] ctrl_kind_stack/
# ctrl_val_stack (a pre-existing, lower bound on *true* nested if/while/
# for/switch specifically, already logged in
# docs/projects/ai_tooling_next_steps.md rather than fixed here).
# Reset to 0 at the start of every compile (compiler/compiler.w's
# compile_attempt) and every REPL entry (repl/core.w's
# repl_compile_entry) so a REPL error longjmp -- which unwinds past every
# pending decrement below -- can never leave a stale count from a failed
# entry poisoning the next one.
int expr_nesting_depth
int stmt_nesting_depth

# file reading
int file
char* filename

# used for keeping track of current position in token
# todo: rename this
int token_i


/*
Python-style source context under human-readable diagnostics (#377):
after the frozen '<message> in <file>:<line>' line, warning() below also
prints the offending source line and a caret aligned under the
diagnostic's column. The compiler never holds a whole source file in
memory -- the tokenizer streams bytes through lib/lib.w's buffered
per-fd getchar -- so the line is re-read from the current fd: seek to
the file start, count newlines up to diag_token_line, collect that line,
and seek back to the tokenizer's own position (byte_offset is the fd's
exact logical offset; every path that repositions the fd -- compile_
attempt, compile_save, the generic reparse -- re-derives both together).
The context block is skipped gracefully whenever the line cannot be
trusted or delivered: the diagnostic does not point at the tokenizer's
current line (diag_token_line was restored from a recorded span, or a
failed open's missing_file_reset zeroed it -- the named file's bytes
are not what the current fd would deliver), the fd cannot produce the
line (closed, read error, EOF before the line), or the line overflows
the collection buffer.
*/
const int diag_context_capacity = 512


char* diag_context_buffer


# Re-read line diag_token_line of the current file into
# diag_context_buffer (NUL-terminated, newline excluded). Returns its
# length in bytes, or -1 when the line cannot be delivered. Reads
# through getchar()/getchar_seek() directly, NOT getc(): a read failure
# here must skip the context, never recurse into error().
int diag_context_collect():
	if (file < 0):
		return (-1)
	int saved_position = byte_offset
	getchar_seek(file, 0)
	int scan_line = 1
	int c = getchar(file)
	while ((scan_line < diag_token_line) && (c >= 0)):
		if (c == 10):
			scan_line = scan_line + 1
		c = getchar(file)
	if (diag_context_buffer == 0):
		diag_context_buffer = malloc(diag_context_capacity + 1)
	int length = 0
	int failed = 0
	if (c < 0):
		# EOF (or a read error) before the line's first character
		failed = 1
	while ((failed == 0) && (c >= 0) && (c != 10)):
		if (length >= diag_context_capacity):
			failed = 1
		else:
			diag_context_buffer[length] = c
			length = length + 1
			c = getchar(file)
	getchar_seek(file, saved_position)
	if (failed):
		return (-1)
	diag_context_buffer[length] = 0
	return length


/*
Human-readable diagnostic layout (#377), modeled on rustc -- the
format gcc and clang converged on for the location line, plus rustc's
line-number gutter and whole-token underline, plus Python 3.10+'s
did-you-mean hints (compiler/diagnostics.w's suggester):

	error: Cannot find symbol: 'countr'
	  --> tests/foo.w:12:9
	   |
	12 |	return countr + 1
	   |	       ^^^^^^
	   = help: did you mean 'counter'?

The first line leads with the severity; the message text itself is
unchanged (fixtures pin it). The location line is 'file:line:col', a
form terminals and editors turn into a jump-to link; the line number is
the same one the old '<message> in <file>:<line>' header printed, and
the column is added only when the diagnostic points at the tokenizer's
current line (the same condition the source context below needs).
When stderr is a terminal the labels, gutter and underline are colored
the way rustc colors them; NO_COLOR disables that and FORCE_COLOR (or
CLICOLOR_FORCE) forces it for a pipe (see https://no-color.org).
*/
int diag_color_state


int diag_env_set(char* name):
	char* value = env_get(name)
	if (value == 0):
		return 0
	if (value[0] == 0):
		return 0
	if ((value[0] == '0') && (value[1] == 0)):
		return 0
	return 1


int diag_color():
	if (diag_color_state == 0):
		diag_color_state = 2
		if (diag_env_set(c"NO_COLOR")):
			diag_color_state = 2
		else if (diag_env_set(c"FORCE_COLOR") || diag_env_set(c"CLICOLOR_FORCE")):
			diag_color_state = 1
		else if (term_isatty(2)):
			diag_color_state = 1
	return diag_color_state == 1


void diag_out(char* s):
	print_error(str_from_cstr(s))


# ANSI SGR sequence 'ESC [ code m', only when color is on.
void diag_style(char* code):
	if (diag_color()):
		put_error(27)
		put_error('[')
		diag_out(code)
		put_error('m')


void diag_reset():
	diag_style(c"0")


# Bold red for errors, bold yellow for warnings; bold blue for the
# gutter and location arrow; bold cyan for help (rustc's palette).
void diag_severity_style(char* severity):
	if (severity[0] == 'e'):
		diag_style(c"1;31")
	else:
		diag_style(c"1;33")


int diag_digit_count(int n):
	int digits = 1
	while (n >= 10):
		n = n / 10
		digits = digits + 1
	return digits


void diag_spaces(int n):
	while (n > 0):
		put_error(' ')
		n = n - 1


# '<pad> |' -- an empty gutter row, or the start of the underline row
void diag_gutter(int width):
	diag_style(c"1;34")
	diag_spaces(width + 1)
	put_error('|')
	diag_reset()


# 1 when the diagnostic's column belongs to the tokenizer's current line,
# the only line the source context can be re-read for.
int diag_on_current_line():
	if (diag_token_line < 1):
		return 0
	if (diag_token_line != line_number + 1):
		return 0
	return diag_token_column >= 1


# Codepoints in s (UTF-8 continuation bytes do not count)
int diag_codepoints(char* s):
	int count = 0
	int i = 0
	while (s[i] != 0):
		if ((s[i] & 192) != 128):
			count = count + 1
		i = i + 1
	return count


# Source line and underline under the gutter. The underline pad
# advances one character per CODEPOINT (diag_token_column counts
# codepoints, not bytes -- #287), replaying the line's own tabs verbatim
# so terminal tab stops keep the underline under the token; every other
# codepoint pads as a single space (approximate for double-width glyphs,
# exact everywhere else). The underline spans the current token when the
# source at the column really spells it, and is a single caret
# otherwise (a repositioned diagnostic, a string token, end of file).
void diag_context_print(char* severity, int width):
	if (diag_on_current_line() == 0):
		return
	int length = diag_context_collect()
	if (length < 0):
		return
	diag_gutter(width)
	put_error(10)
	diag_style(c"1;34")
	diag_out(itoa(diag_token_line))
	diag_spaces(width - diag_digit_count(diag_token_line) + 1)
	put_error('|')
	diag_reset()
	put_error(' ')
	int i = 0
	while (i < length):
		put_error(diag_context_buffer[i] & 255)
		i = i + 1
	put_error(10)
	diag_gutter(width)
	put_error(' ')
	int column = 1
	i = 0
	while (column < diag_token_column):
		if (i < length):
			if (diag_context_buffer[i] == 9):
				put_error(9)
			else:
				put_error(' ')
			i = i + 1
			while ((i < length) && ((diag_context_buffer[i] & 192) == 128)):
				i = i + 1
		else:
			put_error(' ')
		column = column + 1
	int marks = 1
	if (token != 0):
		int j = 0
		while ((token[j] != 0) && (i + j < length) && (diag_context_buffer[i + j] == token[j])):
			j = j + 1
		if ((j > 0) && (token[j] == 0)):
			marks = diag_codepoints(token)
	diag_severity_style(severity)
	while (marks > 0):
		put_error('^')
		marks = marks - 1
	diag_reset()
	put_error(10)


void diag_human(char* severity, char* s):
	diag_append(s)
	char* message = diag_buffer
	int label_length = strlen(severity)
	if (starts_with(message, severity) && (message[label_length] == ':') && (message[label_length + 1] == ' ')):
		message = message + label_length + 2
	int line = line_number + 1
	int width = diag_digit_count(line)
	diag_severity_style(severity)
	diag_out(severity)
	diag_reset()
	diag_style(c"1")
	diag_out(c": ")
	diag_out(message)
	diag_reset()
	put_error(10)
	diag_spaces(width)
	diag_style(c"1;34")
	diag_out(c"--> ")
	diag_reset()
	diag_out(filename)
	put_error(':')
	diag_out(itoa(line))
	if (diag_on_current_line()):
		put_error(':')
		diag_out(itoa(diag_token_column))
	put_error(10)
	diag_context_print(severity, width)
	if (diag_help_text != 0):
		diag_style(c"1;34")
		diag_spaces(width + 1)
		put_error('=')
		diag_reset()
		diag_style(c"1")
		diag_out(c" help")
		diag_reset()
		diag_out(c": ")
		diag_out(diag_help_text)
		put_error(10)
	diag_clear()
	diag_clear_help()


void warning(char *s):
	if (defhash_rehash_mode):
		diag_clear()
		diag_clear_help()
		return
	warning_count = warning_count + 1
	if (diag_json):
		diag_append(s)
		diag_emit(c"warning", filename, diag_token_line, diag_token_column, token)
	else:
		diag_human(c"warning", s)


# REPL error recovery: when repl_recovery is nonzero, error() reports the
# problem and jumps back to the checkpoint in repl_jump_buffer instead of
# exiting the process. repl_error_jump holds the repl_longjmp stub as a
# function pointer: the seed compiler that bootstraps this file predates
# the stub, so its name cannot be referenced here directly.
int repl_recovery
int repl_jump_buffer
int repl_error_jump

void error(char *s):
	if (diag_json):
		diag_append(s)
		diag_emit(c"error", filename, diag_token_line, diag_token_column, token)
	else:
		diag_human(c"error", s)
	if (repl_recovery):
		diag_clear()
		repl_error_jump(repl_jump_buffer, 1)
	exit(1)


# error()/warning() with the message's leading parts (diag_part) given
# as arguments.
void error2(char* a, char* b):
	diag_part(a)
	error(b)


void error3(char* a, char* b, char* c):
	diag_part(a)
	diag_part(b)
	error(c)


void warning3(char* a, char* b, char* c):
	diag_part(a)
	diag_part(b)
	warning(c)


int getc():
	# Inline fast path of lib/lib.w's getchar_checked(): take the next
	# byte straight from the per-fd buffer while it is non-empty, and
	# fall back to the full function (refill, EOF, read error, unbuffered
	# high fds) otherwise. The lexer calls this once per source byte.
	int c
	if ((file >= 0) && (file < 256) && (getchar_pos[file] < getchar_limit[file])):
		char* getc_buffer = cast(char*, getchar_buf_addr[file])
		c = getc_buffer[getchar_pos[file]] & 255
		getchar_pos[file] = getchar_pos[file] + 1
		byte_offset = byte_offset + 1
		return c
	c = getchar_checked(file)
	# A failed read() is not end of file: stopping here with a diagnostic
	# beats silently truncating the source and reporting a misleadingly
	# positioned parse error later (docs/projects/ai_tooling_next_steps.md).
	# Every caller of get_character()/get_token() -- compile_attempt for
	# the root and each import, the generic/defer reparses, the defhash
	# rehash, the REPL entry loader -- points filename at the file it is
	# reading before the first read, so the message names the right file.
	# GETCHAR_EOF() keeps the legacy -1 value, so every nextc == -1 check
	# downstream is unaffected.
	if (c == GETCHAR_READ_ERROR()):
		diag_token_line = line_number + 1
		diag_token_column = column_number + 1
		# The priming read of the very first file can fail before
		# get_token() has ever allocated the token buffer; error() prints
		# and emits token, so point it at something live (mirrors
		# compiler/compiler.w's missing_file_reset, #190)
		if (token == 0):
			token = filename
		error3(c"read error while reading '", filename, c"'")
	# EOF consumes nothing, so the offset only advances for real bytes
	if (c != -1):
		byte_offset = byte_offset + 1
	return c


int get_character():
	int c = getc()

	# Handle Newline
	if(nextc == 10):
		tab_level = 0
		line_number = line_number + 1
		column_number = 0
	else if ((nextc != 0) && (nextc != -1)):
		# Columns count codepoints, not bytes: a UTF-8 continuation
		# byte (10xxxxxx) extends the previous character, so it does
		# not advance the column. Identical to byte counting for
		# all-ASCII lines; byte_offset stays byte-exact regardless
		# (grammar/generic.w re-seeks by it). (#287)
		if ((nextc & 192) != 128):
			column_number = column_number + 1

	# Handle Tab
	if(nextc == 9):
		tab_level = tab_level + 1

	# A last line without a newline is invisible to tab_level-based scoping
	# and can end an indented block with a confusing parse error, so flag it.
	# nextc is the final character of the file when getc() first reports EOF.
	if (c == -1):
		if ((nextc != 10) && (nextc != -1) && (nextc != 0)):
			diag_token_line = line_number + 1
			diag_token_column = column_number + 1
			warning(c"warning: file does not end with a newline")

	return c


void takechar():
	if (token_size <= token_i + 1):
		int x = (token_i + 10) << 1
		token = realloc(token, token_size, x)
		token_size = x

	token[token_i] = nextc
	token_i = token_i + 1
	nextc = get_character()


# Identifier character classes (#287 stage 2). ASCII letters, digits and
# '_' as before, plus raw UTF-8: a lead byte (0xC2-0xF4) can start or
# continue an identifier and take_utf8_ident_char() consumes the whole
# sequence, so a continuation byte (0x80-0xBF) never reaches the loop
# on its own. Byte values are masked because char is sign-extended.
# grammar/*.w's "is this token an identifier" gates share these so a
# UTF-8 name is recognised everywhere the tokenizer accepts it.
int is_utf8_lead_byte(int c):
	c = c & 255
	return (c >= 194) & (c <= 244)


int is_ident_start_byte(int c):
	c = c & 255
	return (('a' <= c) & (c <= 'z')) | (('A' <= c) & (c <= 'Z')) | (c == '_') | is_utf8_lead_byte(c)


int is_ident_part_byte(int c):
	c = c & 255
	return is_ident_start_byte(c) | (('0' <= c) & (c <= '9'))


# The identifier security floor: codepoints that are well-formed UTF-8
# but must not appear in a name because they are invisible, control the
# display order of the surrounding text (Trojan Source, CVE-2021-42574),
# look like whitespace, or are plain punctuation. Everything else above
# U+007F is accepted; there are no Unicode category tables in the seed-
# compiled tokenizer (docs/projects/utf8_source.md). Returns a message
# fragment naming the reason, or 0 when the codepoint is allowed.
char* ident_codepoint_rejection(int cp):
	# C1 controls, NBSP, soft hyphen, Latin-1 punctuation and symbols
	# (keeping the letters U+00AA, U+00B5, U+00BA)
	if ((cp >= 128) && (cp <= 159)):
		return c"a control character"
	if (cp == 160):
		return c"a whitespace character"
	if (cp == 173):
		return c"an invisible character"
	if ((cp >= 161) && (cp <= 191) && (cp != 170) && (cp != 181) && (cp != 186)):
		return c"a punctuation character"
	if ((cp == 215) || (cp == 247)):
		return c"a punctuation character"
	# Generic combining diacritics: a decomposed spelling (e + U+0301)
	# would otherwise be a silently different symbol from the
	# precomposed one, so it is rejected instead of normalised
	if (((cp >= 768) && (cp <= 879)) || ((cp >= 6832) && (cp <= 6911)) ||
			((cp >= 7616) && (cp <= 7679)) || ((cp >= 8400) && (cp <= 8447)) ||
			((cp >= 65056) && (cp <= 65071))):
		return c"a combining mark (use the precomposed spelling)"
	# Arabic letter mark, Mongolian vowel separator, Ogham space
	if ((cp == 1564) || (cp == 6158) || (cp == 5760)):
		return c"an invisible character"
	# General Punctuation block U+2000-U+206F: spaces, dashes, quotes,
	# zero-width characters, bidi embeddings/overrides/isolates and the
	# invisible operators all live here
	if ((cp >= 8192) && (cp <= 8303)):
		if ((cp <= 8202) || (cp == 8232) || (cp == 8233) || (cp == 8239) || (cp == 8287)):
			return c"a whitespace character"
		if (((cp >= 8203) && (cp <= 8207)) || ((cp >= 8234) && (cp <= 8238)) ||
				((cp >= 8288) && (cp <= 8303))):
			return c"an invisible or bidirectional control character"
		return c"a punctuation character"
	# Ideographic space and CJK punctuation
	if ((cp >= 12288) && (cp <= 12291)):
		if (cp == 12288):
			return c"a whitespace character"
		return c"a punctuation character"
	if (((cp >= 12296) && (cp <= 12305)) || ((cp >= 12308) && (cp <= 12319))):
		return c"a punctuation character"
	# Variation selectors, BOM/ZWNBSP, interlinear annotations,
	# noncharacters, tag characters
	if (((cp >= 65024) && (cp <= 65039)) || (cp == 65279) ||
			((cp >= 65529) && (cp <= 65531)) || (cp >= 917504) && (cp <= 917631)):
		return c"an invisible character"
	if ((cp == 65534) || (cp == 65535)):
		return c"a noncharacter"
	return 0


# Uppercase hex spelling of a codepoint, at least four digits (U+00E9)
char* ident_codepoint_hex(int cp):
	char* out = malloc(8)
	int n = 0
	int v = cp
	while ((v > 0) || (n < 4)):
		int d = v & 15
		if (d < 10):
			out[n] = d + '0'
		else:
			out[n] = d - 10 + 'A'
		v = v >> 4
		n = n + 1
	char* text = malloc(n + 1)
	for i in range(n):
		text[i] = out[n - 1 - i]
	text[n] = 0
	return text


# Consume one raw UTF-8 sequence inside an identifier: nextc holds the
# lead byte. Validates the encoding (the same rules as
# grammar/string_literal.w's validate_utf8_literal) and the security
# floor above, then appends every byte to the token.
void take_utf8_ident_char():
	int c = nextc & 255
	int need = 1
	int cp = c & 31
	if (c >= 240):
		need = 3
		cp = c & 7
	else if (c >= 224):
		need = 2
		cp = c & 15
	takechar()
	for j in range(need):
		int d = nextc & 255
		if ((nextc == -1) || (d < 128) || (d > 191)):
			error(c"invalid UTF-8 sequence in identifier")
		cp = (cp << 6) | (d & 63)
		takechar()
	if (((need == 2) && (cp < 2048)) || ((need == 3) && (cp < 65536))):
		error(c"invalid UTF-8 sequence in identifier")
	if (((cp >= 55296) && (cp <= 57343)) || (cp > 1114111)):
		error(c"invalid UTF-8 sequence in identifier")
	char* why = ident_codepoint_rejection(cp)
	if (why != 0):
		token[token_i] = 0
		diag_part(c"identifier '")
		diag_part(token)
		diag_part(c"' contains ")
		error3(why, c": U+", ident_codepoint_hex(cp))


# Byte class table for take_ident_run(), filled once from the
# is_ident_part_byte()/is_utf8_lead_byte() predicates above (so it cannot
# drift from them): 0 = not an identifier byte, 1 = ASCII identifier
# byte, 2 = UTF-8 lead byte. Replaces three nested predicate calls per
# identifier byte with one load.
int[256] ident_byte_class
int ident_byte_class_ready


void ident_byte_class_init():
	for c in range(256):
		if (is_utf8_lead_byte(c)):
			ident_byte_class[c] = 2
		else if (is_ident_part_byte(c)):
			ident_byte_class[c] = 1
		else:
			ident_byte_class[c] = 0
	ident_byte_class_ready = 1


# Scan an identifier (or keyword / integer-literal prefix) run
void take_ident_run():
	if (ident_byte_class_ready == 0):
		ident_byte_class_init()
	while (nextc != -1):
		int k = ident_byte_class[nextc & 255]
		if (k == 0):
			return;
		if (k == 2):
			take_utf8_ident_char()
		else:
			takechar()


# Read UNTIL end of line or end of file
# (but NOT the newline itself) 
# Also append a 0 so the string is zero terminated
void read_until_end():
	while (nextc != 10 && nextc != 0):
		takechar()
	
	token[token_i] = 0
	token_i = token_i + 1


int spaces_warned_line


/*
Scan one f"..." template string chunk into the token buffer, starting at
the current token_i. The chunk is the raw literal text up to and
including its terminator: the closing '"' or a single '{' that opens an
embedded expression. Doubled braces ('{{' and '}}') stay doubled in the
token; grammar/template_string.w collapses them while decoding escapes.
A backslash escapes the next character, exactly like the other string
forms, so escaped quotes and braces never terminate the chunk.
*/
void take_template_chunk():
	int done = 0
	while (done == 0):
		if (nextc == -1):
			error(c"unterminated template string literal")
		else if (nextc == '"'):
			takechar()
			done = 1
		else if (nextc == '{'):
			takechar()
			if (nextc == '{'):
				takechar()
			else:
				done = 1
		else if (nextc == '}'):
			takechar()
			if (nextc == '}'):
				takechar()
			else:
				error(c"single '}' in template string; use '}}'")
		else:
			if (nextc == 92):
				takechar()
				if (nextc == -1):
					error(c"unterminated template string literal")
			takechar()


# Resume an f-string after an embedded expression: replace the current
# token (the '}' that closed the expression) with the next literal chunk,
# which starts at the character right after that '}'. Called only by the
# template string grammar; ordinary tokens keep flowing through
# get_token() while the expression itself is parsed.
void get_token_template_chunk():
	token_i = 0
	token_newline = 0
	diag_token_line = line_number + 1
	diag_token_column = column_number + 1
	take_template_chunk()
	token[token_i] = 0


void get_token():
	token_serial = token_serial + 1
	if (token_size == 0):
		token_size = 20
		token = malloc(token_size)
	token_newline = 0
	int w = 1
	int prev_whitespace
	while (w):
		w = 0
		while ((nextc == ' ') || (nextc == 9) || (nextc == 10)):
			prev_whitespace = nextc
			if(nextc == 10):
				token_newline = 1

			nextc = get_character()

			# Space indentation is invisible to tab_level-based scoping
			if ((prev_whitespace == 10) && (nextc == ' ')):
				if (spaces_warned_line != line_number):
					spaces_warned_line = line_number
					diag_token_line = line_number + 1
					diag_token_column = column_number + 1
					warning(c"warning: line indented with spaces instead of tabs")

		token_i = 0
		diag_token_line = line_number + 1
		diag_token_column = column_number + 1
		token_start_offset = byte_offset - 1
		take_ident_run()

		# Prefixed string literals: s"..." is a UTF-8 string descriptor,
		# c"..." is the legacy char* literal spelling.
		if (token_i == 1):
			if (((token[0] == 's') || (token[0] == 'c')) && (nextc == '"')):
				takechar()
				while (nextc != '"'):
					# EOF inside a prefixed literal used to spin the
					# tokenizer forever (nextc pinned at -1 never
					# matches '"'), consuming memory instead of
					# reporting the truncation.
					if (nextc == -1):
						error(c"unterminated string literal")
					if (nextc == 92):
						takechar()
						if (nextc == -1):
							error(c"unterminated string literal")
					takechar()
				takechar()

			# f"..." template string: the token carries the opening chunk,
			# up to the first embedded '{' expression or the closing quote.
			else if ((token[0] == 'f') && (nextc == '"')):
				takechar()
				take_template_chunk()

		# Float literals: a digit-leading token absorbs a fraction ('3.25')
		# and a signed exponent ('1.5e-3', '2E+10') into one token.
		# Identifiers cannot start with a digit, so nothing else is affected.
		if (token_i > 0):
			if (('0' <= token[0]) && (token[0] <= '9')):
				if (nextc == '.'):
					takechar()
					while ((('a' <= nextc) && (nextc <= 'z')) ||
								 (('A' <= nextc) && (nextc <= 'Z')) ||
								 (('0' <= nextc) && (nextc <= '9')) || (nextc == '_')):
						takechar()
				# '0x1e - 2' must stay a hex literal minus 2, so hex tokens
				# never absorb an exponent sign
				if ((token[1] != 'x') &&
						((token[token_i - 1] == 'e') || (token[token_i - 1] == 'E'))):
					if ((nextc == '+') || (nextc == '-')):
						takechar()
						while (('0' <= nextc) && (nextc <= '9')):
							takechar()

		if (token_i == 0):
			while ((nextc == '<') || (nextc == '=') || (nextc == '>') ||
						 (nextc == '|') || (nextc == '&') || (nextc == '!')):
				takechar()

		# Compound assignment operators: '+' '-' '*' '%' '^' merge with a
		# directly following '=' into one token ('+=', '-=', ...). '/=' is
		# merged in the comment branch below; '&=', '|=', '<<=' and '>>='
		# already merge in the loop above. A directly following '+' after
		# '+' (or '-' after '-') merges the same way into the '++'/'--'
		# increment/decrement statement tokens (grammar/increment.w);
		# spaced spellings ('+ +', '- -') keep lexing as two tokens.
		if (token_i == 0):
			if ((nextc == '+') || (nextc == '-') || (nextc == '*') ||
					(nextc == '%') || (nextc == '^')):
				takechar()
				if (nextc == '='):
					takechar()
				else if ((token[0] == '+') && (nextc == '+')):
					takechar()
				else if ((token[0] == '-') && (nextc == '-')):
					takechar()

		# ':=' inferred declaration: ':' merges with a directly following
		# '='. A bare ':' (blocks, slices, map literals, ternary) never has
		# '=' directly after it, so those keep lexing as single-char tokens.
		if (token_i == 0):
			if (nextc == ':'):
				takechar()
				if (nextc == '='):
					takechar()

		if (token_i == 0):
			if (nextc == 39):
				takechar()
				while (nextc != 39):
					if (nextc == -1):
						error(c"unterminated char literal")
					# A backslash escapes the next character (e.g. '\'')
					if (nextc == 92):
						takechar()
						if (nextc == -1):
							error(c"unterminated char literal")
					takechar()
				takechar()

			else if (nextc == '"'):
				takechar()
				while (nextc != '"'):
					if (nextc == -1):
						error(c"unterminated string literal")
					# A backslash escapes the next character (e.g. \")
					if (nextc == 92):
						takechar()
						if (nextc == -1):
							error(c"unterminated string literal")
					takechar()
				takechar()

			/* Block Comments (bail out on EOF so truncated comments can't hang) */
			else if (nextc == '/') {
				takechar()
				if (nextc == '*'):
					nextc = get_character()
					while ((nextc != '/') && (nextc != -1)):
						while ((nextc != '*') && (nextc != -1)):
							nextc = get_character()
						nextc = get_character()

					nextc = get_character()
					w = 1

				# '/=' compound assignment
				else if (nextc == '='):
					takechar()
			}
			# Line Comments
			else if (nextc == '#'):
				takechar()
				nextc = get_character()
				while((nextc != 10) && (nextc != -1)):
					nextc = get_character()

				# nextc = get_character()
				w = 1

			else if (nextc != -1):
				takechar()

		token[token_i] = 0
	# print_string("token: ", token)


# The grammar tries alternatives in sequence (accept("&"), accept("*"),
# ...), so almost every call mismatches on the first byte: reject that
# case before entering the compare loop.
int peek(char *s):
	int c = s[0]
	if (c != token[0]):
		return 0
	if (c == 0):
		return 1
	int i = 1
	while ((s[i] == token[i]) && (s[i] != 0)):
		i = i + 1

	return s[i] == token[i]


int accept(char *s):
	# Same first-byte rejection as peek(), without the extra call
	if (s[0] != token[0]):
		return 0
	if (peek(s)):
		get_token()
		return 1

	else:
		return 0


void expect(char *s):
	if (accept(s) == 0):
		diag_part(c"'")
		diag_part(s)
		diag_part(c"' expected, found '")
		error3(token, c"'", c"")


void expect_or_newline(char *s):
	# End of file also ends the statement, like a newline would
	if((accept(s) == 0) & (token_newline == 0) & (token[0] != 0)):
		diag_part(c"'")
		diag_part(s)
		diag_part(c"' expected, found '")
		error3(token, c"'", c"")
