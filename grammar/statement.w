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
		print_int_v1("starting stack_pos: ", stack_pos)
		while(start_tab_level <= tab_level):
			statement()
		table_pos = n
		print_int_v1("ending stack_pos: ", stack_pos)
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
		jmp_zero_int32(1337)
		p1 = codepos
		expect(")")
		statement()
		jmp_int32(1337007)
		p2 = codepos
		save_int32(code + p1 - 4, codepos - p1)
		if (peek("else")):
			get_token()
			statement()
		save_int32(code + p2 - 4, codepos - p2)

	else if (while_statement()) {}
	else if (for_statement()) {}

	else if (accept("return")):
		if (peek(";") == 0):
			promote(expression())
		expect_or_newline(";")
		be_pop(stack_pos)
		ret()

	else if (accept("debugger")):
		int3()
		expect_or_newline(";")

	else if (raw_asm_literal()):
		expect_or_newline(";")

	else:
		expression()
		expect_or_newline(";")

