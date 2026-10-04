# Lower resolved range/cursor state around the grammar-owned body visit.
# No source tokens are read by these visitors.
int* emit_range_loop_ast_begin(loop_ast* node):
	# With 2+ arguments the first one is the start: copy it into the loop var
	node.end_slot = node.variable_slot + 1
	if (node.argument_count >= 2):
		node.end_slot = node.variable_slot + 2
		load_slot(node.variable_slot + 1)
		store_stack_var((stack_pos - node.variable_slot) << word_size_log2)

	# Enter a new loop context for break/continue
	int* outer = loop_enter()
	node.break_target = loop_break_chain
	# Loop region: the back edge re-tests the condition.
	node.top_target = be_ctrl_loop()

	# condition: loop var < end
	push_slot_copy(node.variable_slot)
	load_slot(node.end_slot)
	pop_ebx()
	alu_cmp_set(0x9c) /* setl: loop var < end */
	stack_pos = stack_pos - 1
	be_br_zero_discard(node.break_target)

	# Continue region: 'continue' in the body runs the increment first
	node.continue_target = be_ctrl_block()
	loop_continue_chain = node.continue_target

	return outer


void emit_range_loop_ast_end(loop_ast* node):
	/* increment: by 1, or by the step argument */
	be_ctrl_end(node.continue_target)
	if (node.argument_count == 3):
		load_slot(node.variable_slot + 3)
		add_dword_esp_plus_eax((stack_pos - node.variable_slot) << word_size_log2)
	else: inc_dword_esp_plus((stack_pos - node.variable_slot) << word_size_log2)

	/* jmp back to condition */
	be_br(node.top_target)
	be_ctrl_end(node.top_target)

	# break exits here; continue ran the increment first
	be_ctrl_end(node.break_target)

	ast_range_loops_emitted = ast_range_loops_emitted + 1


int* emit_cursor_loop_ast_begin(loop_ast* node):
	# hidden slot: the container pointer
	node.container_slot = push_slot()

	# hidden slot: the cursor
	if (node.begin_fn != 0): for_iter_call(node.begin_fn, node.container_slot, 0)
	else: mov_eax_int(0)
	node.cursor_slot = push_slot()

	# Enter a new loop context for break/continue
	# The exit region is where node.free_fn releases the container.
	int* outer = loop_enter()
	node.break_target = loop_break_chain
	# Loop region: the back edge re-tests.
	node.top_target = be_ctrl_loop()

	# condition: exit once node.done_fn(container, cursor) is true, or once
	# the index cursor reaches the length word
	if (node.done_fn != 0):
		for_iter_call(node.done_fn, node.container_slot, node.cursor_slot)
		be_br_nonzero_discard(node.break_target)
	else:
		push_slot_copy(node.cursor_slot)
		load_slot(node.container_slot)
		add_eax_int32(word_size)
		promote_eax()
		pop_ebx_slot()
		alu_cmp_set(0x9c) /* setl: cursor < length */
		be_br_zero_discard(node.break_target)

	# Continue region: 'continue' in the body advances the cursor first
	node.continue_target = be_ctrl_block()
	loop_continue_chain = node.continue_target

	# loop var = node.value_fn(container, cursor), or the slice element at
	# data + cursor * element_size
	int extracted_type = node.value_coerce_type
	if (node.value_fn != 0): for_iter_call(node.value_fn, node.container_slot, node.cursor_slot)
	else:
		load_slot(node.container_slot)
		promote_eax() /* the descriptor's data pointer */
		push_slot()
		load_slot(node.cursor_slot)
		int element_size = type_get_size(node.element_type)
		if (element_size > 1): imul_eax_int32(element_size)
		pop_ebx_slot()
		alu_add()
		extracted_type = promote(node.element_type)
	if (extracted_type != -1): coerce(node.variable_type, extracted_type)
	store_stack_var((stack_pos - node.variable_slot) << word_size_log2)

	if (node.value_var != 0):
		for_iter_call(node.value2_fn, node.container_slot, node.cursor_slot)
		coerce(node.value_var_type, node.value2_coerce_type)
		store_stack_var((stack_pos - node.value_var) << word_size_log2)

	return outer


void emit_cursor_loop_ast_end(loop_ast* node):
	# step (continue lands here): cursor = node.next_fn(container, cursor),
	# or an in-place index increment
	be_ctrl_end(node.continue_target)
	if (node.next_fn != 0):
		for_iter_call(node.next_fn, node.container_slot, node.cursor_slot)
		store_stack_var((stack_pos - node.cursor_slot) << word_size_log2)
	else: inc_dword_esp_plus((stack_pos - node.cursor_slot) << word_size_log2)

	/* jmp back to condition */
	be_br(node.top_target)
	be_ctrl_end(node.top_target)

	# Both exit edges (done and break) land here: release the container
	# before falling through
	be_ctrl_end(node.break_target)
	if (node.free_fn != 0): for_iter_call(node.free_fn, node.container_slot, 0)

	ast_cursor_loops_emitted = ast_cursor_loops_emitted + 1


void emit_loop_ast_cleanup(loop_ast* node):
	if (node.kind == ast_loop_range): drop_slots(node.argument_count)
	else if (node.kind == ast_loop_cursor): drop_slots(2)


int emit_iteration_value_ast(statement_ast* node):
	int type = promote(node.expression_type)
	if (node.kind == ast_stmt_range_argument): push_slot()
	ast_iteration_values_emitted = ast_iteration_values_emitted + 1
	return type


int* emit_while_loop_ast_begin(loop_ast* node):
	int* outer = loop_enter()
	node.break_target = loop_break_chain
	node.top_target = be_ctrl_loop()
	node.continue_target = node.top_target
	loop_continue_chain = node.continue_target
	return outer


void emit_while_loop_ast_end(loop_ast* node):
	be_br(node.top_target)
	be_ctrl_end(node.top_target)
	be_ctrl_end(node.break_target)
	ast_while_loops_emitted = ast_while_loops_emitted + 1
