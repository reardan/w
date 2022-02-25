/*
Wesley Reardan based on work by Edmund GRIMLEY EVANS <edmundo@rano.org>
W Language
A self-compiling compiler for a small subset of C.

TODO
====
test:
	&, *, ! for char + int
operators:
	for
	in
	range
	yield
	and
	or
	not
	import

features:
	generators
	repl
	debugging
	symbols
	import

types:
	float

Data Structures:
	List
		String
		Map
			Set
			Object
		Stack
		Queue
		Heap
			PriorityQueue
		Node
		Edge
		Tree
			Trie
		Graph
		Collection
		SSTable

	List
		append
		appendleft
		clear
		copy
		count
		extend
		extendleft
		index
		insert
		pop
		popleft
		remove
		reverse
		rotate

		LinkedList
		DoublyLinkedList
		ArrayList
		RingBuffer
		FlatList

	File
	Stream
*/
import lib

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


void error(char *s):
	put_error(s)
	put_error(" in ")
	put_error(filename)
	put_error(":")
	put_error(itoa(line_number+1))
	puterror(10)
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

				nextc = get_character()
				w = 1

			else if (nextc != 0-1):
				takechar()

		token[token_i] = 0



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
		put_error("'")
		put_error(s)
		put_error("' expected, found '")
		put_error(token)
		put_error("'")
		error("")


void expect_or_newline(char *s):
	if((accept(s) == 0) & (token_newline == 0)):
		put_error("'")
		put_error(s)
		put_error("' expected, found '")
		put_error(token)
		put_error("'")
		error("")


char *code
int code_size
int codepos
int code_offset

void save_int(char *p, int n):
	p[0] = n
	p[1] = n >> 8
	p[2] = n >> 16
	p[3] = n >> 24


int load_int(char *p):
	return ((p[0] & 255) + ((p[1] & 255) << 8) +
					((p[2] & 255) << 16) + ((p[3] & 255) << 24))


void emit(int n, char *s):
	int i = 0
	if (code_size <= codepos + n):
		int x = (codepos + n) << 1
		code = realloc(code, code_size, x)
		code_size = x

	while (i <= n - 1):
		code[codepos] = s[i]
		codepos = codepos + 1
		i = i + 1



void be_push():
	emit(1, "\x50") /* push %eax */


void be_pop(int n):
	emit(6, "\x81\xc4....") /* add $(n * 4),%esp */
	save_int(code + codepos - 4, n << 2)



/*
table: stack of symbols
symbol format:
string: symbol\0 
char: [DULA]
int: address
int: type
*/
char *table
int table_size
int table_pos
int stack_pos
int table_struct_size

void print_symbol_table(int t):
	put_error("printing symbol table since ")
	put_error(itoa(t))
	put_error(":\x0a")
	while (t <= table_pos - 1):
		char* sym = table + t
		t = t + strlen(table + t)

		put_error(sym)

		put_error(": type(")
		puterror(table[t + 6] + '0')
		put_error(") symtype(")
		puterror(table[t + 1])
		put_error(") address(")
		int address = table + t + 2
		put_error(hex(*address))
		put_error(")\x0a")

		t = t + 10
	

int sym_lookup(char *s):
	int t = 0
	int current_symbol = 0
	while (t <= table_pos - 1):
		int i = 0
		while ((s[i] == table[t]) & (s[i] != 0)):
			i = i + 1
			t = t + 1

		if (s[i] == table[t]):
			current_symbol = t

		while (table[t] != 0):
			t = t + 1

		t = t + 10

	return current_symbol

void sym_declare(char *s, int type, int symtype, int value):
	int t = table_pos
	int i = 0
	while (s[i] != 0):
		if (table_size <= t + 10):
			int x = (t + 10) << 1
			table = realloc(table, table_size, x)
			table_size = x

		table[t] = s[i]
		i = i + 1
		t = t + 1

	table[t] = 0
	table[t + 1] = symtype
	save_int(table + t + 2, value)
	table[t + 6] = type
	table_pos = t + 10


char *last_global_declaration
int sym_declare_global(char *s, int type):
	strcpy(last_global_declaration, s)
	int current_symbol = sym_lookup(s)
	if (current_symbol == 0):
		sym_declare(s, type, 'U', code_offset)
		current_symbol = table_pos - 10

	return current_symbol

void sym_define_global(int current_symbol):
	int i
	int j
	int t = current_symbol
	int v = codepos + code_offset
	if (table[t + 1] != 'U'):
		put_error("symbol redefined: '")
		put_error(last_global_declaration)
		error("'")
	i = load_int(table + t + 2) - code_offset
	while (i):
		j = load_int(code + i) - code_offset
		save_int(code + i, v)
		i = j

	table[t + 1] = 'D'
	save_int(table + t + 2, v)


int number_of_args

void sym_get_value(char *s):
	int t
	if ((t = sym_lookup(s)) == 0):
		put_error("Cannot find symbol: '")
		put_error(token)
		error("'\x0a")
	emit(5, "\xb8....") /* mov $n,%eax */
	save_int(code + codepos - 4, load_int(table + t + 2))
	if (table[t + 1] == 'D') { /* defined global */
	}
	else if (table[t + 1] == 'U'): /* undefined global */
		save_int(table + t + 2, codepos + code_offset - 4)
	else if (table[t + 1] == 'L'): /* local variable */
		int k = (stack_pos - table[t + 2] - 1) << 2
		emit(7, "\x8d\x84\x24....") /* lea (n * 4)(%esp),%eax */
		save_int(code + codepos - 4, k)

	else if (table[t + 1] == 'A'): /* argument */
		int k = (stack_pos + number_of_args - table[t + 2] + 1) << 2
		emit(7, "\x8d\x84\x24....") /* lea (n * 4)(%esp),%eax */
		save_int(code + codepos - 4, k)

	else:
		put_error("Error getting symbol value for '")
		put_error(s)
		put_error("', table[t + 1]='")
		puterror(table[t + 1])
		error("'")

void sym_define_declare_global_function(char* name):
	sym_define_global(sym_declare_global(name, 4))

void be_start():
	emit(16, "\x7f\x45\x4c\x46\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00")
	emit(16, "\x02\x00\x03\x00\x01\x00\x00\x00\x54\x80\x04\x08\x34\x00\x00\x00")
	emit(16, "\x00\x00\x00\x00\x00\x00\x00\x00\x34\x00\x20\x00\x01\x00\x00\x00")
	emit(16, "\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x80\x04\x08")
	emit(16, "\x00\x80\x04\x08\x10\x4b\x00\x00\x10\x4b\x00\x00\x07\x00\x00\x00")
	emit(4, "\x00\x10\x00\x00")

	/* setup command line args */
	emit(5, "\x8d\x44\x24\x04\x50")
	/* lea eax, [esp+4]; push eax */

	emit(5, "\xe8....")
	/* call [first function ] - set with the save_int() at the end of this func */

	sym_define_declare_global_function("exit")
	/* pop %ebx ; pop %ebx ; xor %eax,%eax ; inc %eax ; int $0x80 */
	emit(7, "\x5b\x5b\x31\xc0\x40\xcd\x80")

	sym_define_declare_global_function("malloc")
	/* mov 4(%esp),%eax */
	emit(4, "\x8b\x44\x24\x04")
	/* push %eax ; xor %ebx,%ebx ; mov $45,%eax ; int $0x80 */
	emit(10, "\x50\x31\xdb\xb8\x2d\x00\x00\x00\xcd\x80")
	/* pop %ebx ; add %eax,%ebx ; push %eax ; push %ebx ; mov $45,%eax */
	emit(10, "\x5b\x01\xc3\x50\x53\xb8\x2d\x00\x00\x00")
	/* int $0x80 ; pop %ebx ; cmp %eax,%ebx ; pop %eax ; je . + 7 */
	emit(8, "\xcd\x80\x5b\x39\xc3\x58\x74\x05")
	/* mov $-1,%eax ; ret */
	emit(6, "\xb8\xff\xff\xff\xff\xc3")

	sym_define_declare_global_function("putchar")
	/* mov $4,%eax ; xor %ebx,%ebx ; inc %ebx */
	emit(8, "\xb8\x04\x00\x00\x00\x31\xdb\x43")
	/*  lea 4(%esp),%ecx ; mov %ebx,%edx ; int $0x80 ; ret */
	emit(9, "\x8d\x4c\x24\x04\x89\xda\xcd\x80\xc3")

	sym_define_declare_global_function("puterror")
	/* mov $4,%eax ; xor %ebx,%ebx ; inc %ebx */
	emit(8, "\xb8\x04\x00\x00\x00\x31\xdb\x43")
	/*  lea 4(%esp),%ecx ; mov %ebx,%edx ; inc %ebx ; int $0x80 ; ret */
	emit(10, "\x8d\x4c\x24\x04\x89\xda\x43\xcd\x80\xc3")

	sym_define_declare_global_function("syscall")
	/* mov eax,[esp+16] ; mov ebx,[esp+12] ; mov ecx,[esp+8] ; mov edx,[esp+4] ; int 0x80 ; ret */
	emit(19, "\x8b\x44\x24\x10\x8b\x5c\x24\x0c\x8b\x4c\x24\x08\x8b\x54\x24\x04\xcd\x80\xc3")

	# OG: 85, 89
	save_int(code + 90, codepos - 94) /* entry set to first thing in file */


void be_finish():
	save_int(code + 68, codepos)
	save_int(code + 72, codepos)
	int i = 0
	while (i <= codepos - 1):
		putchar(code[i])
		i = i + 1


void promote(int type):
	/* 1 = char lval, 2 = int lval, 3 = other */
	if (type == 1):
		emit(3, "\x0f\xbe\x00") /* movsbl (%eax),%eax */
	else if (type == 2):
		emit(2, "\x8b\x00") /* mov (%eax),%eax */


int expression();

/*
 * primary-expr:
 *     identifier
 *     constant
 *     ( expression )
 */
int primary_expr():
	int type
	# Integer constant
	if (('0' <= token[0]) & (token[0] <= '9')):
		int n = 0
		int i = 0
		while (token[i]):
			n = (n << 1) + (n << 3) + token[i] - '0'
			i = i + 1

		emit(5, "\xb8....") /* mov $x,%eax */
		save_int(code + codepos - 4, n)
		type = 3

	# Identifier
	else if (('a' <= token[0]) & (token[0] <= 'z')):
		sym_get_value(token)
		type = 2

	else if (accept("(")) {
		type = expression()
		if (peek(")") == 0):
			error("No closing parenthesis")
	}
	else if ((token[0] == 39) & (token[1] != 0) &
					 (token[2] == 39) & (token[3] == 0)):
		emit(5, "\xb8....") /* mov $x,%eax */
		save_int(code + codepos - 4, token[1])
		type = 3

	else if (token[0] == '"'):
		int i = 0
		int j = 1
		int k
		while (token[j] != '"'):
			if ((token[j] == 92) & (token[j + 1] == 'x')):
				if (token[j + 2] <= '9'):
					k = token[j + 2] - '0'
				else:
					k = token[j + 2] - 'a' + 10
				k = k << 4
				if (token[j + 3] <= '9'):
					k = k + token[j + 3] - '0'
				else:
					k = k + token[j + 3] - 'a' + 10
				token[i] = k
				j = j + 4

			else:
				token[i] = token[j]
				j = j + 1

			i = i + 1

		token[i] = 0
		/* call ... ; the string ; pop %eax */
		emit(5, "\xe8....")
		save_int(code + codepos - 4, i + 1)
		emit(i + 1, token)
		emit(1, "\x58")
		type = 3

	else:
		error("Could not find a valid primary expression")

	get_token()
	return type


void binary1(int type):
	promote(type)
	be_push()
	stack_pos = stack_pos + 1


int binary2(int type, int n, char *s):
	promote(type)
	emit(n, s)
	stack_pos = stack_pos - 1
	return 3


/*
 * postfix-expr:
 *         primary-expr
 *         postfix-expr [ expression ]
 *         postfix-expr ( expression-list-opt )
 */
int postfix_expr():
	int type = primary_expr()
	if (accept("[")):
		binary1(type) /* pop %ebx ; add %ebx,%eax */
		binary2(expression(), 3, "\x5b\x01\xd8")
		expect("]")
		type = 1
	
	else if (accept("(")):
		int s = stack_pos
		be_push()
		stack_pos = stack_pos + 1
		if (accept(")") == 0):
			promote(expression())
			be_push()
			stack_pos = stack_pos + 1
			while (accept(",")):
				promote(expression())
				be_push()
				stack_pos = stack_pos + 1

			expect(")")

		emit(7, "\x8b\x84\x24....") /* mov (n * 4)(%esp),%eax */
		save_int(code + codepos - 4, (stack_pos - s - 1) << 2)
		emit(2, "\xff\xd0") /* call *%eax */
		be_pop(stack_pos - s)
		stack_pos = s
		type = 3

	return type

int multiplicative_expr();
/*
unary-operator
& * + - ~ !

unary-expression
	postfix-expression
	unary-operator multiplicative-expression
*/
int unary_expression():
	int type
	# untested:
	if (accept("&")):
		type = multiplicative_expr()
		return type
	else if (accept("*")):
		type = multiplicative_expr()
/*		put_error("unary * type: ")
		put_error(itoa(type))
		put_error("\x0alast symbol: ")
		put_error(last_global_declaration)
		put_error("\x0a")*/
		promote(type)
		return type
	# untested:
	else if (accept("!")):
		type = multiplicative_expr()
		promote(type)
		emit(2, "\xf7\xd0") /* not eax */
		return type
	else:
		return postfix_expr()

	
/*
TODO: push/pop edx: is it necessary?
*/
int multiplicative_expr():
	int type = unary_expression()
	while (1):
		if (accept("*")):
			binary1(type) /* pop ebx ; imul eax,ebx */
			type = binary2(unary_expression(), 4, "\x5b\x0f\xaf\xc3")

		else if (accept("/")):
			binary1(type)  /* mov ebx, eax ; pop eax ; xor edx,edx ; idiv ebx */
			type = binary2(unary_expression(), 7, "\x89\xc3\x58\x31\xd2\xf7\xfb")

		else if (accept("%")):
			binary1(type) /* mov ebx, eax ; pop eax ; idiv ebx ; mov eax,edx */
			type = binary2(unary_expression(), 9, "\x89\xc3\x58\x31\xd2\xf7\xfb\x89\xd0")

		else:
			return type


/*
 * additive-expr:
 *         multiplicative-expr
 *         additive-expr + multiplicative-expr
 *         additive-expr - multiplicative-expr
 */
int additive_expr():
	int type = multiplicative_expr()
	while (1):
		if (accept("+")):
			binary1(type) /* pop %ebx ; add %ebx,%eax */
			type = binary2(multiplicative_expr(), 3, "\x5b\x01\xd8")

		else if (accept("-")):
			binary1(type) /* pop %ebx ; sub %eax,%ebx ; mov %ebx,%eax */
			type = binary2(multiplicative_expr(), 5, "\x5b\x29\xc3\x89\xd8")

		else:
			return type


/*
 * shift-expr:
 *         additive-expr
 *         shift-expr << additive-expr
 *         shift-expr >> additive-expr
 */
int shift_expr():
	int type = additive_expr()
	while (1):
		if (accept("<<")):
			binary1(type) /* mov %eax,%ecx ; pop %eax ; shl %cl,%eax */
			type = binary2(additive_expr(), 5, "\x89\xc1\x58\xd3\xe0")

		else if (accept(">>")):
			binary1(type) /* mov %eax,%ecx ; pop %eax ; sar %cl,%eax */
			type = binary2(additive_expr(), 5, "\x89\xc1\x58\xd3\xf8")

		else:
			return type


/*
 * relational-expr:
 *         shift-expr
 *         relational-expr <= shift-expr
 */
int relational_expr():
	int type = shift_expr()
	while (1):
		if(accept("<=")):
			binary1(type)
			/* pop %ebx ; cmp %eax,%ebx ; setle %al ; movzbl %al,%eax */
			type = binary2(shift_expr(), 9, "\x5b\x39\xc3\x0f\x9e\xc0\x0f\xb6\xc0")

		else if(accept("<")):
			binary1(type)
			/* pop %ebx ; cmp %eax,%ebx ; setl %al ; movzbl %al,%eax */
			type = binary2(shift_expr(), 9, "\x5b\x39\xc3\x0f\x9c\xc0\x0f\xb6\xc0")

		else if(accept(">=")):
			binary1(type)
			/* pop %ebx ; cmp %eax,%ebx ; setge %al ; movzbl %al,%eax */
			type = binary2(shift_expr(), 9, "\x5b\x39\xc3\x0f\x9d\xc0\x0f\xb6\xc0")

		else if(accept(">")):
			binary1(type)
			/* pop %ebx ; cmp %eax,%ebx ; setge %al ; movzbl %al,%eax */
			type = binary2(shift_expr(), 9, "\x5b\x39\xc3\x0f\x9f\xc0\x0f\xb6\xc0")
	
		else:
			return type


/*
 * equality-expr:
 *         relational-expr
 *         equality-expr == relational-expr
 *         equality-expr != relational-expr
 */
int equality_expr():
	int type = relational_expr()
	while (1):
		if (accept("==")):
			binary1(type)
			/* pop %ebx ; cmp %eax,%ebx ; sete %al ; movzbl %al,%eax */
			type = binary2(relational_expr(), 9, "\x5b\x39\xc3\x0f\x94\xc0\x0f\xb6\xc0")

		else if (accept("!=")):
			binary1(type)
			/* pop %ebx ; cmp %eax,%ebx ; setne %al ; movzbl %al,%eax */
			type = binary2(relational_expr(), 9, "\x5b\x39\xc3\x0f\x95\xc0\x0f\xb6\xc0")

		else:
			return type


/*
 * bitwise-and-expr:
 *         equality-expr
 *         bitwise-and-expr & equality-expr
 */
int bitwise_and_expr():
	int type = equality_expr()
	while (accept("&")):
		binary1(type) /* pop %ebx ; and %ebx,%eax */
		type = binary2(equality_expr(), 3, "\x5b\x21\xd8")

	return type


/*
 * bitwise-or-expr:
 *         bitwise-and-expr
 *         bitwise-and-expr | bitwise-or-expr
 */
int bitwise_or_expr():
	int type = bitwise_and_expr()
	while (accept("|")):
		binary1(type) /* pop %ebx ; or %ebx,%eax */
		type = binary2(bitwise_and_expr(), 3, "\x5b\x09\xd8")

	return type


/*
 * expression:
 *         bitwise-or-expr
 *         bitwise-or-expr = expression
 */
int expression():
	int type = bitwise_or_expr()
	if (accept("=")):
		be_push()
		stack_pos = stack_pos + 1
		promote(expression())
		if (type == 2):
			emit(3, "\x5b\x89\x03") /* pop %ebx ; mov %eax,(%ebx) */
		else:
			emit(3, "\x5b\x88\x03") /* pop %ebx ; mov %al,(%ebx) */
		stack_pos = stack_pos - 1
		type = 3

	return type


/*
 * type-name:
 *     char *
 *     int
 *     void
 */
int type_name():
	int type = 0
	if (peek("char")):
		type = 3
	else if (peek("int")):
		type = 2
	else if (peek("void")):
		type = 1
	else:
		put_error("unknown type name: '")
		put_error(token)
		error("'")
	get_token()
	while (accept("*")) {
	}
	return type



/*
 * statement:
 *     { statement-list-opt }
 *     : statement-list-tab-scoped
 *     type-name identifier ;
 *     type-name identifier = expression;
 *     if ( expression ) statement
 *     if ( expression ) statement else statement
 *     while ( expression ) statement
 *     return ;
 *     return expression ;
 *     yield expression ;
 *     "debug;"
 *     expr ;
 TODO:
 *     import Root.Subpath.File [as Identifier] ;
 *     import Root.File.[Ident1, Ident2, Ident3] ;
 *     new File( arg-list )
 */
void statement():
	int p1
	int p2
	int if_tab_level

	# Original scope starting with '{' Character
	if (accept("{")) {
		int n = table_pos
		int s = stack_pos
		while (accept("}") == 0):
			statement()
		table_pos = n
		be_pop(stack_pos - s)
		stack_pos = s
	}
	# New scoping based on tabs and ':'
	else if (accept(":")):
		int n = table_pos
		int s = stack_pos
		int start_tab_level = tab_level
		while(start_tab_level <= tab_level):
			statement()
		table_pos = n
		be_pop(stack_pos - s)
		stack_pos = s

	else if (peek("char") | peek("int")):
		sym_declare(token, type_name(), 'L', stack_pos)
		get_token()
		if (accept("=")):
			promote(expression())
		expect_or_newline(";")
		be_push()
		stack_pos = stack_pos + 1

	else if (accept("if")):
		if_tab_level = tab_level
		expect("(")
		promote(expression())
		emit(8, "\x85\xc0\x0f\x84....") /* test %eax,%eax ; je ... */
		p1 = codepos
		expect(")")
		statement()
		emit(5, "\xe9....") /* jmp ... */
		p2 = codepos
		save_int(code + p1 - 4, codepos - p1)
		if (peek("else")):
			get_token()
			statement()
		save_int(code + p2 - 4, codepos - p2)

	else if (accept("while")):
		expect("(")
		p1 = codepos
		promote(expression())
		emit(8, "\x85\xc0\x0f\x84....") /* test %eax,%eax ; je ... */
		p2 = codepos
		expect(")")
		statement()
		emit(5, "\xe9....") /* jmp ... */
		save_int(code + codepos - 4, p1 - codepos)
		save_int(code + p2 - 4, codepos - p2)

	else if (accept("for")):
		if (peek("char") | peek("int")):
			sym_declare(token, type_name(), 'L', stack_pos)
			get_token()
			be_push()
			stack_pos = stack_pos + 1
		else:
			error("no variable found in for loop")

		accept("in")
		promote(expression())
		statement()

	else if(accept("pass")):
		emit(2, "\x89\xff")  /* mov edi,edi ; does not work :( */

	else if (accept("return")):
		if (peek(";") == 0):
			promote(expression())
		expect_or_newline(";")
		be_pop(stack_pos)
		emit(1, "\xc3") /* ret */

	else if (accept("yield")):
		if (peek(";") == 0):
			promote(expression())
		expect_or_newline(";")
		be_pop(stack_pos)
		emit(1, "\xc3") /* ret */

	else if (accept(";debug;")):
		expect_or_newline(";")
		emit(1, "\xcc") /* int 3 */

	else:
		expression()
		expect_or_newline(";")


void compile_save(char* fn);
/*
 * program:
 *     declaration
 *     declaration program
 *
 * declaration:
 *     type-name identifier ;
 *     type-name identifier ( parameter-list ) ;
 *     type-name identifier ( parameter-list ) statement
 *
 * parameter-list:
 *     parameter-declaration
 *     parameter-list, parameter-declaration
 *
 * parameter-declaration:
 *     type-name identifier-opt
 */
void program():
	int current_symbol
	while (token[0]):
		# First handle imports
		if (accept("import")):
			put_error("importing '")
			char* with_path = strjoin(token, ".w")
			put_error(with_path)
			put_error("'\x0a")
			compile_save(with_path)
			free(with_path)
			expect_or_newline(";")

		# Now variables + functions
		current_symbol = sym_declare_global(token, type_name())
		get_token()
		if (accept(";")):
			sym_define_global(current_symbol)
			emit(4, "\x00\x00\x00\x00")

		else if (accept("(")):
			int n = table_pos
			number_of_args = 0
			while (accept(")") == 0):
				number_of_args = number_of_args + 1
				int type = type_name()
				if (peek(")") == 0):
					sym_declare(token, type, 'A', number_of_args)
					get_token()

				accept(",") /* ignore trailing comma */

			if (accept(";") == 0):
				sym_define_global(current_symbol)
				statement()
				emit(1, "\xc3") /* ret */

			table_pos = n

		else:
			/*error(8)*/
			sym_define_global(current_symbol)
			emit(4, "\x00\x00\x00\x00")


void compile(char* fn):
	filename = fn
	file = open(filename, 0, 511)
	line_number = 0
	tab_level = 0
	nextc = get_character()
	get_token()
	program()


void compile_save(char* fn):
	char* old_filename = filename
	int old_file = file
	int old_line_number = line_number
	int old_tab_level = old_tab_level

	compile(fn)
	close(file)

	filename = old_filename
	put_error("switching back to '")
	put_error(filename)
	put_error("'\x0a")
	file = old_file
	line_number = old_line_number
	tab_level = old_tab_level
	nextc = get_character()
	get_token()


int link(int argc, int argv):
	last_global_declaration = malloc(8000)
	code_offset = 134512640 /* 0x08048000 */
	be_start()

	int i = 1
	while (i < argc):
		int arg = argv + i * 4
		put_error("compiling '")
		put_error(*arg)
		put_error("'\x0a")
		compile(*arg)
		i = i + 1

	be_finish()


int main(int argc, int argv):
	link(argc, argv)
	return 0

