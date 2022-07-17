
# tokenizer
int nextc
char *token
int token_size
int token_newline
int tab_level
int line_number

# file reading
int file
char* filename

# used for keeping track of current position in token
# todo: rename this
int token_i


void warning(char *s):
	print_error(s)
	print_error(" in ")
	print_error(filename)
	print_error(":")
	print_error(itoa(line_number+1))
	put_error(10)


void error(char *s):
	warning(s)
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


void get_token():
	token_newline = 0
	int w = 1
	while (w):
		w = 0
		while ((nextc == ' ') | (nextc == 9) | (nextc == 10)):
			if(nextc == 10):
				token_newline = 1

			nextc = get_character()

		token_i = 0
		while ((('a' <= nextc) & (nextc <= 'z')) |
					 (('0' <= nextc) & (nextc <= '9')) | (nextc == '_')):
			takechar()
		
		if (token_i == 0):
			while ((nextc == '<') | (nextc == '=') | (nextc == '>') |
						 (nextc == '|') | (nextc == '&') | (nextc == '!')):
				takechar()

		if (token_i == 0):
			if (nextc == 39):
				takechar()
				while (nextc != 39):
					takechar()
				takechar()

			else if (nextc == '"'):
				takechar()
				while (nextc != '"'):
					takechar()
				takechar()

			/* Block Comments */
			else if (nextc == '/') {
				takechar()
				if (nextc == '*'):
					nextc = get_character()
					while (nextc != '/'):
						while (nextc != '*'):
							nextc = get_character()
						nextc = get_character()

					nextc = get_character()
					w = 1
			}
			# Line Comments
			else if (nextc == '#'):
				takechar()
				nextc = get_character()
				while(nextc != 10):
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
		print_error("'")
		print_error(s)
		print_error("' expected, found '")
		print_error(token)
		print_error("'")
		error("")


void expect_or_newline(char *s):
	if((accept(s) == 0) & (token_newline == 0)):
		print_error("'")
		print_error(s)
		print_error("' expected, found '")
		print_error(token)
		print_error("'")
		error("")
