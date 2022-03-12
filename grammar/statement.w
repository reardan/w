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
	else if (variable_declaration() >= 0):
		expect_or_newline(";")

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

	else if(raw_asm_literal()) {}

	else:
		expression()
		expect_or_newline(";")

