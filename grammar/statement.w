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
 *     switch expression : case-clauses       (parentheses optional)
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

# 1 while compiling a generator body (grammar/generator_decl.w): yield
# is only legal then, and return must not carry a value.
int in_generator_body
void emit_generator_yield_call(); /* defined in generator_decl */
void emit_generator_finish_call(); /* defined in generator_decl */


void copy_struct_return_value(int declared_type):
	int words = (type_get_size(declared_type) + word_size - 1) >> word_size_log2
	mov_ebx_esp_plus((stack_pos + number_of_args) << word_size_log2)
	push_ebx()
	stack_pos = stack_pos + 1
	push_eax()
	stack_pos = stack_pos + 1
	int i = 0
	while (i < words):
		mov_eax_esp_plus(0)
		if (i > 0):
			add_eax_int32(i << word_size_log2)
		promote_eax()
		if (i > 0):
			add_ebx_int32(word_size)
		store_ebx_word()
		i = i + 1
	pop_eax()
	stack_pos = stack_pos - 1
	pop_ebx()
	stack_pos = stack_pos - 1
	if (type_has_array_field(declared_type)):
		mov_eax_ebx()
		init_array_field_descriptors(declared_type)

void statement():
	int p1
	int p2
	int if_tab_level

	# DWARF line info: the code emitted next belongs to this source line
	debug_line_note(stack_pos)

	# { statement-list-opt }
	if (accept(c"{")) {
		int n = table_pos
		int s = stack_pos
		while (accept(c"}") == 0):
			statement()
		table_pos = n
		be_pop(stack_pos - s)
		stack_pos = s
	}

	# : statement-list-tab-scoped
	else if (peek(c":")):
		int block_tab_level = enclosing_tab_level
		get_token()
		int n = table_pos
		int s = stack_pos
		int start_tab_level = tab_level
		print_int_v1(c"starting stack_pos: ", stack_pos)
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
		print_int_v1(c"ending stack_pos: ", stack_pos)
		be_pop(stack_pos - s)
		stack_pos = s

	# type-name identifier
	else if (variable_declaration() >= 0):
		expect_or_newline(c";")

	# if expression statement else statement (parentheses optional)
	else if (accept(c"if")):
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
		if (peek(c"else")):
			if (tab_level == if_tab_level):
				get_token()
				enclosing_tab_level = if_tab_level
				statement()
		save_int32(code + p2 - 4, codepos - p2)

	else if (while_statement()) {}
	else if (for_statement()) {}
	else if (switch_statement()) {}

	# 'break' targets the innermost breakable construct: a switch when
	# break_in_switch is set (grammar/while_statement.w), a loop otherwise
	else if (accept(c"break")):
		expect_or_newline(c";")
		if ((loop_depth == 0) & (switch_depth == 0)):
			error(c"'break' outside of a loop or switch")
		if (break_in_switch):
			# Unwind block locals pushed since the switch started
			if (stack_pos > switch_stack_pos):
				be_pop(stack_pos - switch_stack_pos)
			jmp_int32(switch_break_chain)
			switch_break_chain = codepos
		else:
			# Unwind block locals pushed since the loop started
			if (stack_pos > loop_stack_pos):
				be_pop(stack_pos - loop_stack_pos)
			jmp_int32(loop_break_chain)
			loop_break_chain = codepos

	else if (accept(c"continue")):
		expect_or_newline(c";")
		if (loop_depth == 0):
			error(c"'continue' outside of a loop")
		if (stack_pos > loop_stack_pos):
			be_pop(stack_pos - loop_stack_pos)
		jmp_int32(loop_continue_chain)
		loop_continue_chain = codepos

	else if (accept(c"return")):
		# A newline (or end of file) after 'return' means no return value.
		if ((peek(c";") == 0) & (token_newline == 0) & (token[0] != 0)):
			if (in_generator_body):
				error(c"generators cannot return a value; use yield")
			int return_type = expression()
			return_type = promote(return_type)
			int declared_type = load_int(table + current_function_symbol + 6)
			if ((type_num_args(declared_type) > 0) & (type_num_args(return_type) > 0)):
				if (types_compatible_with_expression(declared_type, return_type) == 0):
					warn_type_mismatch(c"return", declared_type, return_type)
				copy_struct_return_value(declared_type)
			else:
				coerce(declared_type, return_type)
				if (types_compatible_with_expression(declared_type, return_type) == 0):
					warn_type_mismatch(c"return", declared_type, return_type)
		expect_or_newline(c";")
		if (in_generator_body):
			# Finish the generator: __w_gen_return switches back to the
			# consumer permanently, so no ret / stack unwinding is needed
			emit_generator_finish_call()
		else:
			be_pop(stack_pos)
			ret()

	# yield expression: store the value into the generator object and
	# switch back to the consumer until the next gen_next
	else if (accept(c"yield")):
		if (in_generator_body == 0):
			error(c"'yield' outside of a generator body")
		int yield_type = expression()
		yield_type = promote(yield_type)
		int declared_yield_type = load_int(table + current_function_symbol + 6)
		coerce(declared_yield_type, yield_type)
		if (types_compatible_with_expression(declared_yield_type, yield_type) == 0):
			warn_type_mismatch(c"yield", declared_yield_type, yield_type)
		expect_or_newline(c";")
		emit_generator_yield_call()

	else if (accept(c"debugger")):
		int3()
		expect_or_newline(c";")

	# Explicit no-op, for spelling out an intentionally empty block
	else if (accept(c"pass")):
		expect_or_newline(c";")

	else if (raw_asm_literal()):
		expect_or_newline(c";")

	else:
		expression()
		expect_or_newline(c";")
