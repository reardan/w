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

# Postfix '?' error propagation (docs/error_results.txt). The operand
# must be a wresult[T]* — a pointer to an instantiated generic struct
# whose type-table name starts with 'wresult$' (grammar/generic.w's
# mangling; '$' cannot appear in a source identifier, so user structs
# can never alias the prefix).

# Struct type index behind a wresult[T]* expression type, or -1 when
# the type is not a pointer to a wresult instantiation.
int result_propagate_struct(int type):
	int operand = type_unqualified(type)
	if (operand < 0):
		return -1
	if (type_get_pointer_level(operand) != 1):
		return -1
	int base = type_lookup_previous_pointer(operand)
	if (base < 0):
		return -1
	if (type_num_args(base) <= 0):
		return -1
	if (starts_with(type_get_name(base), c"wresult$") == 0):
		return -1
	return base


# 'expr?' with the operand's lvalue/value in eax. Ok results evaluate
# to the address of the payload field ('value'), typed as the payload
# (the usual lvalue convention, so later postfix ops chain). Error
# results make the enclosing function return the operand pointer as its
# own wresult[U]* result: 'ok'/'code' sit at the same offsets in every
# instantiation and an error's payload is never read, so the
# reinterpretation is layout-safe.
int result_propagate_suffix(int type):
	if (in_generator_body):
		error(c"'?' is not supported in generator bodies")
	if (current_function_symbol < 0):
		error(c"'?' outside of a function")
	type = promote(type)
	int base = result_propagate_struct(type)
	if (base < 0):
		diag_part(c"'?' requires a wresult[...]* operand, got '")
		print_error_type(type)
		error(c"'")
	int declared_type = load_int(table + current_function_symbol + 6)
	if (result_propagate_struct(declared_type) < 0):
		diag_part(c"'?' requires the enclosing function to return a wresult[...]*, got '")
		print_error_type(declared_type)
		error(c"'")
	int payload_type = type_get_field_type(base, c"value")
	if (payload_type < 0):
		error(c"'?' operand struct has no 'value' field")
	# eax holds the wresult pointer; keep it while testing the ok flag
	push_eax()
	stack_pos = stack_pos + 1
	promote_eax() /* load r.ok: an int at field offset 0 */
	jmp_nonzero_int32(1337022)
	int p = codepos
	# Error path: return the operand pointer, unwinding block locals and
	# expression temporaries exactly like the 'return' statement does
	# (stack_pos already counts the slot pushed above). Deferred
	# statements run first, with the result pointer saved around them,
	# because '?' is a function exit like any 'return'.
	mov_eax_esp_plus(0)
	defer_emit_returning()
	be_pop(stack_pos)
	ret()
	save_int32(code + p - 4, codepos - p)
	# Ok path: eax = address of the payload field
	pop_eax()
	stack_pos = stack_pos - 1
	int value_offset = type_get_field_offset(base, c"value")
	if (value_offset > 0):
		add_eax_int32(value_offset)
	return payload_type


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
		int is_function_body = defer_function_body_pending
		defer_function_body_pending = 0
		while (accept(c"}") == 0):
			statement()
		# The function body block closing is the fall-through exit: run
		# the deferred statements (LIFO) while the body's locals are
		# still in scope
		if (is_function_body):
			defer_emit_all()
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
		int is_function_body = defer_function_body_pending
		defer_function_body_pending = 0
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
		# The function body block closing is the fall-through exit: run
		# the deferred statements (LIFO) while the body's locals are
		# still in scope
		if (is_function_body):
			defer_emit_all()
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
			# Deferred statements run before the frame unwinds, with the
			# already-evaluated return value saved around them
			defer_emit_returning()
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

	# defer <simple-statement>: record the span; it re-parses and runs
	# at every function exit, LIFO (grammar/defer.w)
	else if (accept(c"defer")):
		if (in_generator_body):
			error(c"'defer' is not supported in generator bodies")
		defer_register()

	else if (raw_asm_literal()):
		expect_or_newline(c";")

	else:
		expression()
		expect_or_newline(c";")
