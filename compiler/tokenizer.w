import compiler.diagnostics

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
int diag_context_capacity():
	return 512


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
		diag_context_buffer = malloc(diag_context_capacity() + 1)
	int length = 0
	int failed = 0
	if (c < 0):
		# EOF (or a read error) before the line's first character
		failed = 1
	while ((failed == 0) && (c >= 0) && (c != 10)):
		if (length >= diag_context_capacity()):
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


# The caret pad advances one character per CODEPOINT (diag_token_column
# counts codepoints, not bytes -- #287), replaying the line's own tabs
# verbatim so terminal tab stops keep the caret under the token; every
# other codepoint pads as a single space (approximate for double-width
# glyphs, exact everywhere else).
void diag_context_print():
	# Only when the diagnostic points at the tokenizer's current line
	if (diag_token_line < 1):
		return
	if (diag_token_line != line_number + 1):
		return
	if (diag_token_column < 1):
		return
	int length = diag_context_collect()
	if (length < 0):
		return
	int i = 0
	while (i < length):
		put_error(diag_context_buffer[i] & 255)
		i = i + 1
	put_error(10)
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
	put_error('^')
	put_error(10)


void warning(char *s):
	if (defhash_rehash_mode):
		return
	warning_count = warning_count + 1
	if (diag_json):
		diag_append(s)
		diag_emit(c"warning", filename, diag_token_line, diag_token_column, token)
	else:
		print_error(str_from_cstr(s))
		print_error(str_from_cstr(c" in "))
		print_error(str_from_cstr(filename))
		print_error(str_from_cstr(c":"))
		print_error(str_from_cstr(itoa(line_number+1)))
		put_error(10)
		diag_context_print()


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
		warning(s)
	if (repl_recovery):
		diag_clear()
		repl_error_jump(repl_jump_buffer, 1)
	exit(1)


int getc():
	int c = getchar_checked(file)
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
		diag_part(c"read error while reading '")
		diag_part(filename)
		error(c"'")
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
		while ((('a' <= nextc) && (nextc <= 'z')) ||
					 (('A' <= nextc) && (nextc <= 'Z')) ||
					 (('0' <= nextc) && (nextc <= '9')) || (nextc == '_')):
			takechar()

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


int peek(char *s):
	int i = 0
	while ((s[i] == token[i]) && (s[i] != 0)):
		i = i + 1

	return s[i] == token[i]


int accept(char *s):
	if (peek(s)):
		get_token()
		return 1

	else:
		return 0


int accept_newline(char *s):
	if(peek(s) | token_newline):
		get_token()
		return 1

	else:
		return 0


void expect(char *s):
	if (accept(s) == 0):
		diag_part(c"'")
		diag_part(s)
		diag_part(c"' expected, found '")
		diag_part(token)
		diag_part(c"'")
		error(c"")


void expect_or_newline(char *s):
	# End of file also ends the statement, like a newline would
	if((accept(s) == 0) & (token_newline == 0) & (token[0] != 0)):
		diag_part(c"'")
		diag_part(s)
		diag_part(c"' expected, found '")
		diag_part(token)
		diag_part(c"'")
		error(c"")
