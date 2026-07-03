/*
 * statement:
 *     { statement-list-opt }
 *     : statement-list-tab-scoped
 *     type-name identifier ;
 *     type-name identifier = expression;
 *     if expression statement                (parentheses optional)
 *     if expression statement else statement (parentheses optional)
 *     while expression statement             (parentheses optional)
 *     for type-name identifier in range args statement
 *     break ;
 *     continue ;
 *     return ;
 *     return expression ;
 *     debugger ;
 *     pass ;
 *     expression ;
 */
# Table offset of the function whose body is being parsed; return
# statements check their expression against its declared return type.
int current_function_symbol

void statement():
	int p1
	int p2
	int if_tab_level

	# DWARF line info: the code emitted next belongs to this source line
	debug_line_note()

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
	else if (peek(":")):
		int block_tab_level = enclosing_tab_level
		get_token()
		int n = table_pos
		int s = stack_pos
		int start_tab_level = tab_level
		print_int_v1("starting stack_pos: ", stack_pos)
		int same_line = 0
		if (token_newline == 0):
			# Same-line body: exactly one statement, e.g. "if (x): return"
			same_line = 1
			if (token[0] != 0):
				statement()
		if (same_line == 0):
			# An un-indented next line means the block is empty (like 'pass')
			if (start_tab_level > block_tab_level):
				while(start_tab_level <= tab_level):
					statement()
		table_pos = n
		print_int_v1("ending stack_pos: ", stack_pos)
		be_pop(stack_pos - s)
		stack_pos = s

	# type-name identifier
	else if (variable_declaration() >= 0):
		expect_or_newline(";")

	# if expression statement else statement (parentheses optional)
	else if (accept("if")):
		if_tab_level = tab_level
		promote(expression())
		jmp_zero_int32(1337)
		p1 = codepos
		enclosing_tab_level = if_tab_level
		statement()
		jmp_int32(1337007)
		p2 = codepos
		save_int32(code + p1 - 4, codepos - p1)
		# An 'else' only binds to an 'if' at the same indent level
		if (peek("else")):
			if (tab_level == if_tab_level):
				get_token()
				enclosing_tab_level = if_tab_level
				statement()
		save_int32(code + p2 - 4, codepos - p2)

	else if (while_statement()) {}
	else if (for_statement()) {}

	else if (accept("break")):
		expect_or_newline(";")
		if (loop_depth == 0):
			error("'break' outside of a loop")
		# Unwind block locals pushed since the loop started
		if (stack_pos > loop_stack_pos):
			be_pop(stack_pos - loop_stack_pos)
		jmp_int32(loop_break_chain)
		loop_break_chain = codepos

	else if (accept("continue")):
		expect_or_newline(";")
		if (loop_depth == 0):
			error("'continue' outside of a loop")
		if (stack_pos > loop_stack_pos):
			be_pop(stack_pos - loop_stack_pos)
		jmp_int32(loop_continue_chain)
		loop_continue_chain = codepos

	else if (accept("return")):
		# A newline (or end of file) after 'return' means no return value.
		if ((peek(";") == 0) & (token_newline == 0) & (token[0] != 0)):
			int return_type = expression()
			promote(return_type)
			int declared_type = load_int(table + current_function_symbol + 6)
			if (types_compatible(declared_type, return_type) == 0):
				warn_type_mismatch("return", declared_type, return_type)
		expect_or_newline(";")
		be_pop(stack_pos)
		ret()

	else if (accept("debugger")):
		int3()
		expect_or_newline(";")

	# Explicit no-op, for spelling out an intentionally empty block
	else if (accept("pass")):
		expect_or_newline(";")

	else if (raw_asm_literal()):
		expect_or_newline(";")

	else:
		expression()
		expect_or_newline(";")
