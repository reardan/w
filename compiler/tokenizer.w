
# tokenizer
int nextc
char *token
int token_size
int token_newline
int tab_level
int line_number
int bounds_mode

# file reading
int file
char* filename

# used for keeping track of current position in token
# todo: rename this
int token_i


void warning(char *s):
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
	warning(s)
	if (repl_recovery):
		repl_error_jump(repl_jump_buffer, 1)
	exit(1)


int getc():
	return getchar(file)


int get_character():
	int c = getc()

	# Handle Newline
	if(nextc == 10):
		tab_level = 0
		line_number = line_number + 1

	# Handle Tab
	if(nextc == 9):
		tab_level = tab_level + 1

	# A last line without a newline is invisible to tab_level-based scoping
	# and can end an indented block with a confusing parse error, so flag it.
	# nextc is the final character of the file when getc() first reports EOF.
	if (c == -1):
		if ((nextc != 10) & (nextc != -1) & (nextc != 0)):
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
	while (nextc != 10 & nextc != 0):
		takechar()
	
	token[token_i] = 0
	token_i = token_i + 1


int spaces_warned_line

void get_token():
	if (token_size == 0):
		token_size = 20
		token = malloc(token_size)
	token_newline = 0
	int w = 1
	int prev_whitespace
	while (w):
		w = 0
		while ((nextc == ' ') | (nextc == 9) | (nextc == 10)):
			prev_whitespace = nextc
			if(nextc == 10):
				token_newline = 1

			nextc = get_character()

			# Space indentation is invisible to tab_level-based scoping
			if ((prev_whitespace == 10) & (nextc == ' ')):
				if (spaces_warned_line != line_number):
					spaces_warned_line = line_number
					warning(c"warning: line indented with spaces instead of tabs")

		token_i = 0
		while ((('a' <= nextc) & (nextc <= 'z')) |
					 (('A' <= nextc) & (nextc <= 'Z')) |
					 (('0' <= nextc) & (nextc <= '9')) | (nextc == '_')):
			takechar()

		# Prefixed string literals: s"..." is a UTF-8 string descriptor,
		# c"..." is the legacy char* literal spelling.
		if (token_i == 1):
			if (((token[0] == 's') | (token[0] == 'c')) & (nextc == '"')):
				takechar()
				while (nextc != '"'):
					if (nextc == 92):
						takechar()
					takechar()
				takechar()

		# Float literals: a digit-leading token absorbs a fraction ('3.25')
		# and a signed exponent ('1.5e-3', '2E+10') into one token.
		# Identifiers cannot start with a digit, so nothing else is affected.
		if (token_i > 0):
			if (('0' <= token[0]) & (token[0] <= '9')):
				if (nextc == '.'):
					takechar()
					while ((('a' <= nextc) & (nextc <= 'z')) |
								 (('A' <= nextc) & (nextc <= 'Z')) |
								 (('0' <= nextc) & (nextc <= '9')) | (nextc == '_')):
						takechar()
				# '0x1e - 2' must stay a hex literal minus 2, so hex tokens
				# never absorb an exponent sign
				if ((token[1] != 'x') &
						((token[token_i - 1] == 'e') | (token[token_i - 1] == 'E'))):
					if ((nextc == '+') | (nextc == '-')):
						takechar()
						while (('0' <= nextc) & (nextc <= '9')):
							takechar()

		if (token_i == 0):
			while ((nextc == '<') | (nextc == '=') | (nextc == '>') |
						 (nextc == '|') | (nextc == '&') | (nextc == '!')):
				takechar()

		if (token_i == 0):
			if (nextc == 39):
				takechar()
				while (nextc != 39):
					# A backslash escapes the next character (e.g. '\'')
					if (nextc == 92):
						takechar()
					takechar()
				takechar()

			else if (nextc == '"'):
				takechar()
				while (nextc != '"'):
					# A backslash escapes the next character (e.g. \")
					if (nextc == 92):
						takechar()
					takechar()
				takechar()

			/* Block Comments (bail out on EOF so truncated comments can't hang) */
			else if (nextc == '/') {
				takechar()
				if (nextc == '*'):
					nextc = get_character()
					while ((nextc != '/') & (nextc != -1)):
						while ((nextc != '*') & (nextc != -1)):
							nextc = get_character()
						nextc = get_character()

					nextc = get_character()
					w = 1
			}
			# Line Comments
			else if (nextc == '#'):
				takechar()
				nextc = get_character()
				while((nextc != 10) & (nextc != -1)):
					nextc = get_character()

				# nextc = get_character()
				w = 1

			else if (nextc != -1):
				takechar()

		token[token_i] = 0
	# print_string("token: ", token)


int peek(char *s):
	int i = 0
	while ((s[i] == token[i]) & (s[i] != 0)):
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
		print_error(str_from_cstr(c"'"))
		print_error(str_from_cstr(s))
		print_error(str_from_cstr(c"' expected, found '"))
		print_error(str_from_cstr(token))
		print_error(str_from_cstr(c"'"))
		error(c"")


void expect_or_newline(char *s):
	# End of file also ends the statement, like a newline would
	if((accept(s) == 0) & (token_newline == 0) & (token[0] != 0)):
		print_error(str_from_cstr(c"'"))
		print_error(str_from_cstr(s))
		print_error(str_from_cstr(c"' expected, found '"))
		print_error(str_from_cstr(token))
		print_error(str_from_cstr(c"'"))
		error(c"")
