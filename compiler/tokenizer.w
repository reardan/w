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
# of nested parens, or thousands of nested statement blocks, recurse the
# parser's own call stack until it SIGSEGVs with no diagnostic at all --
# confirmed by direct measurement (a paren chain crashes native between
# ~40000 and ~60000 levels deep). Each counter is incremented/checked/
# decremented at its single recursive re-entry site: expr_nesting_depth
# in grammar/primary_expr.w's '(' branch (the only place '(' -grouping
# re-enters expression() -- the top of the expression grammar), and
# stmt_nesting_depth wrapping the whole body of grammar/statement.w's
# statement() (the single function every nested block/if/while/for/
# switch body recurses back through, so guarding it once there covers
# every statement-level recursion path without touching each caller).
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
	int c = getchar(file)
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
