/*
for type-name identifier in range args :
	{ statement }

range forms (parentheses optional):
	range end
	range(end)
	range(start, end)
	range(start, end, step)

All range arguments are evaluated once, up front, into hidden stack slots.
*/
int for_statement():
	int p1
	int p2
	if (accept("for") == 0):
		return 0

	int for_tab_level = tab_level

	mov_eax_int(0) /* default start value for the loop variable */
	int type = variable_declaration()
	asserts("type not found in for_statement loop variable", type >= 0)
	int for_var = stack_pos

	expect("in")
	expect("range")

	int has_parens = accept("(")
	int num_range_args = 1
	promote(expression())
	push_eax()
	stack_pos = stack_pos + 1
	while (accept(",")):
		promote(expression())
		push_eax()
		stack_pos = stack_pos + 1
		num_range_args = num_range_args + 1
	if (has_parens):
		expect(")")
	asserts("range() takes 1-3 arguments", num_range_args <= 3)

	# With 2+ arguments the first one is the start: copy it into the loop var
	int end_slot = for_var + 1
	if (num_range_args >= 2):
		end_slot = for_var + 2
		mov_eax_esp_plus((stack_pos - (for_var + 1)) << word_size_log2)
		store_stack_var((stack_pos - for_var) << word_size_log2)

	# Enter a new loop context for break/continue
	int outer_break = loop_break_chain
	int outer_continue = loop_continue_chain
	int outer_stack = loop_stack_pos
	loop_break_chain = 0
	loop_continue_chain = 0
	loop_stack_pos = stack_pos
	loop_depth = loop_depth + 1

	# condition: loop var < end
	p1 = codepos
	mov_eax_esp_plus((stack_pos - for_var) << word_size_log2)
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus((stack_pos - end_slot) << word_size_log2)
	/* pop %ebx ; cmp %eax,%ebx ; setl %al ; movzbl %al,%eax */
	emit(9, compare_opcode("\x9c"))
	stack_pos = stack_pos - 1
	jmp_zero_int32(1337010)
	p2 = codepos

	/* ':' scoping + child scope statements */
	enclosing_tab_level = for_tab_level
	statement()

	/* increment: by 1, or by the step argument */
	int increment_target = codepos
	if (num_range_args == 3):
		mov_eax_esp_plus((stack_pos - (for_var + 3)) << word_size_log2)
		add_dword_esp_plus_eax((stack_pos - for_var) << word_size_log2)
	else:
		inc_dword_esp_plus((stack_pos - for_var) << word_size_log2)

	/* jmp back to condition */
	jmp_int32(1337011)
	save_int32(code + codepos - 4, p1 - codepos)

	/* save jmp to here if condition failed */
	save_int32(code + p2 - 4, codepos - p2)

	# break exits here; continue runs the increment first
	patch_jump_chain(loop_break_chain, codepos)
	patch_jump_chain(loop_continue_chain, increment_target)

	loop_break_chain = outer_break
	loop_continue_chain = outer_continue
	loop_stack_pos = outer_stack
	loop_depth = loop_depth - 1

	# Discard the hidden range slots (the loop variable itself stays)
	be_pop(num_range_args)
	stack_pos = stack_pos - num_range_args

	return 1
