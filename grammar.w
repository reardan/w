
char *last_identifier


void warn_bad_promotion(int want, int got):
	if (want != got):
		print2("wanted '")
		print2(itoa(want))
		print2("' got ")
		print2(itoa(got))
		warning("'")
	

int promote(int type):
	int type_size = type_get_size(type)
	if (verbosity >= 1):
		print2("promote(")
		print2(itoa(type))
		print2("=")
		print2(type_get_name(type))
		print2(", size=")
		print2(itoa(type_size))
		print2(", '")
		print2(last_identifier)
		println2("')")
	/* 1 = char lval, 2 = int lval, 3 = no promotion, pointer? */
	if (type_size == 2):
		println2("int16")
		emit(3, "\x0f\xbf\x00") /* movsx eax, word[eax] */
	else if (type_size == 1):
		emit(3, "\x0f\xb6\x00") /* movsbl (%eax),%eax */
	else if (type == 1):
		# warn_bad_promotion(1, type_size)  # TODO: FIX
		emit(3, "\x0f\xbe\x00") /* movsbl (%eax),%eax */
	else if (type == 3) {}
	else:
		# warn_bad_promotion(4, type_size)   # TODO: FIX
		emit(2, "\x8b\x00") /* mov (%eax),%eax */

	return type


int identifier():
	if (('a' <= token[0]) & (token[0] <= 'z')):
		sym_get_value(token)
		strcpy(last_identifier, token)
		return 1
	return 0


int int_literal():
	if ((token[0]) < '0' |  & (token[0] > '9')):
		return 0
	int n = 0
	int i = 0
	while (token[i]):
		n = (n << 1) + (n << 3) + token[i] - '0'
		i = i + 1

	emit(5, "\xb8....") /* mov $x,%eax */
	save_int(code + codepos - 4, n)
	return 1






# like a char_pointer_literal()
# except it emits the code directly to be executed
int raw_char_pointer_literal():
	if (accept("raw\x22") == 0):
		return 0


int process_string_literal():
	int i = 0
	int j = 1
	int k
	while (token[j] != '"'):
		# \x0a formatting
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
	return i



int char_pointer_literal():
	if (token[0] != '"'):
		return 0
	int i = process_string_literal()
	token[i] = 0
	/* call ... ; the string ; pop %eax */
	emit(5, "\xe8....")
	save_int(code + codepos - 4, i + 1)
	emit(i + 1, token)
	emit(1, "\x58")

	return 1



int expression();

/*
 * primary-expr:
 *     identifier
 *     constant
 *     ( expression )
 */
int primary_expr():
	int type
	int new_type
	# Integer literal
	if (int_literal()):
		type = 3

	# Identifier
	else if (identifier()) {
		type = 2
		new_type = sym_type(token)
		# TODO: fix int type (1)
		if (new_type != 1):
			type = new_type
	}
	# ( expression )
	else if (accept("(")) {
		type = expression()
		if (peek(")") == 0):
			error("No closing parenthesis")
	}
	# char literal
	else if ((token[0] == 39) & (token[1] != 0) &
					 (token[2] == 39) & (token[3] == 0)):
		emit(5, "\xb8....") /* mov $x,%eax */
		save_int(code + codepos - 4, token[1])
		type = 3

	else if (char_pointer_literal()):
		type = 3

	else:
		print2("Could not find a valid primary expression, token: ")
		error(token)

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
postfix-expr:
	primary-expr
	postfix-expr [ expression ]
	postfix-expr ( expression-list-opt )
	postfix-expr . identifier

 */
int postfix_expr():
	# print_string("postfix_expr: ", token)
	int type = primary_expr()
	if (accept("[")):
		binary1(type)
		/* pop %ebx ; add %ebx,%eax */
		binary2(expression(), 3, "\x5b\x01\xd8")
		expect("]")
		type = 1
	
	else if (accept("(")):
		int s = stack_pos
		be_push()
		stack_pos = stack_pos + 1
		if (accept(")") == 0):
			int arg_type = expression()
			if (pointer_indirection == 0):
				promote(arg_type)
			be_push()
			stack_pos = stack_pos + 1
			while (accept(",")):
				int arg_type = expression()
				if (pointer_indirection == 0):
					promote(arg_type)
				be_push()
				stack_pos = stack_pos + 1

			expect(")")

		emit(7, "\x8b\x84\x24....") /* mov (n * 4)(%esp),%eax */
		save_int(code + codepos - 4, (stack_pos - s - 1) << 2)
		emit(2, "\xff\xd0") /* call *%eax */
		be_pop(stack_pos - s)
		stack_pos = s
		type = 3

	else if (accept(".")):
		# For structures, find offset of field name
		int num_args = type_num_args(type)
		if (num_args > 0):
			int arg = type_get_arg(type, token)
			if(arg < 0):
				print2("struct field '")
				print2(token)
				error("' not found")
			# Return right side field type instead of struct
			emit(5, "\x05....") /* \x2d add eax,... */
			/* \x2d: sub eax, ... WRONG use sub instead? */
			int stack_offset = type_get_field_offset(type, token)
			save_int(code + codepos - 4, stack_offset)

			# use child type:
			type = type_get_field_type(type, token)

		get_token()
		/*while (accept(".")):
			println2("accepted '.'")
			print_string("token: ", token)
			get_token()*/

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
		int type2 = expression()
		if (verbosity >= 1):
			print2("expression() type: ")
			type_print(type)
			print_int("expression() type: ", type)
			print_int("expression() type2: ", type2)
		
		promote(type2)
		int type_size = type_get_size(type2)
		if (type == 1):
			emit(3, "\x5b\x88\x03") /* pop %ebx ; mov %al,(%ebx) */
		else if(type_size == 2):
			emit(4, "\x5b\x66\x89\x03") /* pop %ebx ; mov %ax,(%ebx) */
		else:
			emit(3, "\x5b\x89\x03") /* pop %ebx ; mov %eax,(%ebx) */
		stack_pos = stack_pos - 1
		# type = 3
		type = type2

	return type


/*
typename:
	void
	int
	char
*/
int type_name():
	int type = 0
	pointer_indirection = 0
	type = type_lookup(token)
	if (type < 0):
		print_error("unknown type name: '")
		print_error(token)
		error("'")
	get_token()
	while (accept("*")) {
		if (type == 1):
			if (verbosity > 0):
				warning("'*' accepted")
			pointer_indirection = pointer_indirection + 1
	}
	return type

void statement();
# while ( expression ) statement
# no ':' required ??
int while_statement():
	int p1
	int p2
	if (accept("while") == 0):
		return 0

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

	return 1



/*
for type-name indentifier in range (int-literal):
	{ statement }

for int i in range(0, 10):
*/
int for_statement():
	int p1
	int p2
	int for_type
	int max_stack_pos
	char* for_var = 0
	# for
	if (accept("for")):
		if (type_lookup(token) < 0):
			error("no variable type found in for loop")

		# int i
		for_type = type_name()
		for_var = strclone(token)
		sym_declare(token, for_type, 'L', stack_pos, 1)
		pointer_indirection = 0
		get_token()

		# in range(stop-expression)
		expect("in")
		expect("range")

		p1 = codepos
		promote(expression())  ### mov eax, 10

		# mov ebx,eax
		emit(2, "\x89\xc3")
		promote(for_type)

		# cmp eax, ebx; jge 0x200
		emit(8, "\x39\xd8\x0f\x8d\xf8\x01\x00\x00")
		p2 = codepos

		# get statements including the ':' new scope starter
		statement()

		emit(5, "\xe9....") /* jmp ... */
		save_int(code + codepos - 4, p1 - codepos)
		save_int(code + p2 - 4, codepos - p2)


		return 1
	return 0


/*
import_statement:
	'import' dotted_as_names
dotted_as_names:
	| ','.dotted_as_name+
dotted_as_name
	| dotted_name ['as' NAME]
dotted_name:
	| dotted_name '.' NAME
	| NAME

examples:
	import file.*
	import file
	import directory.file
	import directory.file.[func1, func2, var2]

*/


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
 *     debugger ;
 *     expression ;
 */
void statement():
	int p1
	int p2
	int if_tab_level

	# { statement-list-opt }
	if (accept("{")) {
		int n = table_pos
		int s = stack_pos
		while (accept("}") == 0):
			statement()
		table_pos = n
		be_pop(stack_pos - s)
		stack_pos = s
	}

	# : statement-list-tab-scoped
	else if (accept(":")):
		int n = table_pos
		int s = stack_pos
		int start_tab_level = tab_level
		if (verbosity >= 1):
			print_int("starting stack_pos: ", stack_pos)
		while(start_tab_level <= tab_level):
			statement()
		table_pos = n
		if (verbosity >= 1):
			print_int("ending stack_pos: ", stack_pos)
		be_pop(stack_pos - s)
		stack_pos = s

	# type-name identifier
	else if (type_lookup(token) >= 0):
		# println2("statement(): type identifier")
		int type = type_name()
		sym_declare(token, type, 'L', stack_pos, 1)
		get_token()
		# = expression
		if (accept("=")):
			int type = expression()
			# TODO: Fix to use & instead?  e.g. int*f = &func
			if (pointer_indirection == 0)
				promote(type)
		pointer_indirection = 0
		expect_or_newline(";")

		# Compute size of struct else use 1 word
		int size = 1
		int num_args = type_num_args(type)
		if (num_args > 0):
			# print_string("num_args > 0 for ", token)
			size = num_args
		int i = 0
		while (i < size):
			be_push()
			i = i + 1
		stack_pos = stack_pos + size

	# if ( expression ) statement else statement
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

	else if (while_statement()) {}
	else if(for_statement()) {}
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

	else if (accept("tracer")):
		expect_or_newline(";")
		emit(1, "\xcc") /* int 3 */

	else if (accept("nop")):
		expect_or_newline(";")
		emit(2, "\x9090") /* nop; nop */

	else:
		expression()
		expect_or_newline(";")


/*
import
*/



/*

struct_declaration identifier :
	type_name identifier
	...

*/
int struct_declaration():
	int current_symbol
	int num_fields = 0
	int type_index = 0
	# parent_expression()
	if (accept("struct")):
		int start_tab_level = tab_level
		if (verbosity >= 0):
			print_int("start_tab_level: ", start_tab_level)
			print_string("struct accepted name: ", token)
			println2("")
		current_symbol = sym_declare_global(token, 5, 1)

		# emit struct type with token name
		type_index = type_push(strclone(token))
		type_print_all()

		get_token()
		# print_string("token_colon: ", token)
		expect(":")
		while(tab_level > start_tab_level):
			if (verbosity >= 0):
				print2("type_token: ")
				print2(token)
			int field_type = type_name()
			if (verbosity >= 0):
				print_int0("[", field_type)
				println2("]")

			current_symbol = sym_declare_global(token, field_type, 1)
			type_add_arg(type_index, strclone(token), field_type)
			if (verbosity >= 0):
				print_int("num_fields: ", num_fields)
				print_string("field: ", token)
				print_error("\x0a")

			get_token()
			num_fields = num_fields + 1
			pointer_indirection = 0

		return 1

	return 0


void compile_save(char* fn);


int import_statement():
	if(accept("import")):
		# Ignore if we have already imported this type
		if (type_lookup(token) >= 0):
			if (verbosity >= 1):
				print2("Warning: ignoring duplicate imported type: '")
				print2(token)
				println2("'")
			get_token()
		else:
			type_push(strclone(token))
			char* with_path = strjoin(token, ".w")
			if (verbosity >= 1):
				print_string("importing ", with_path)
			compile_save(with_path)
			free(with_path)
		return 1
	return 0


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
	int function_start
	while (token[0]):
		# First handle imports
		while (import_statement() ) {}

		# Next handle struct declarations
		while(struct_declaration()):
			print_int("struct_declaration=1, current_symbol=", current_symbol)

		# Now global variables + functions
		# TODO: variables THEN functions, not both
		current_symbol = sym_declare_global(token, type_name(), 1)
		get_token()
		if (accept(";")):
			sym_define_global(current_symbol)
			emit(4, "\x00\x00\x00\x00")

		else if (accept("(")):
			table[current_symbol + 10] = 2 /* store function type */
			int n = table_pos
			number_of_args = 0
			function_start = codepos /* keep track of start for length comp */
			while (accept(")") == 0):
				number_of_args = number_of_args + 1
				int type = type_name()
				if (peek(")") == 0):
					sym_declare(token, type, 'A', number_of_args, 1)
					pointer_indirection = 0
					get_token()

				accept(",") /* ignore trailing comma */

			if (accept(";") == 0):
				sym_define_global(current_symbol)
				statement()
				emit(1, "\xc3") /* ret */
				# Store length to symbol table:
				save_int(table + current_symbol + 14, codepos - function_start)

			table_pos = n

		else:
			/*error(8)*/
			sym_define_global(current_symbol)
			emit(4, "\x00\x00\x00\x00")
