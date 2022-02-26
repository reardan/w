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
/*		print_error("unary * type: ")
		print_error(itoa(type))
		print_error("\x0alast symbol: ")
		print_error(last_global_declaration)
		print_error("\x0a")*/
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
		print_error("unknown type name: '")
		print_error(token)
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

	else if (accept("debugger")):
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
		while (accept("import")):
			char* with_path = strjoin(token, ".w")
			if (verbosity > 0):
				print_error("importing '")
				print_error(with_path)
				print_error("'\x0a")
			compile_save(with_path)
			free(with_path)

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
