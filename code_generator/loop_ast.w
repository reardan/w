# Lower resolved range/cursor state around the grammar-owned body visit.
# No source tokens are read by these visitors.
int* emit_range_loop_ast_begin(loop_ast* node):
	# With 2+ arguments the first one is the start: copy it into the loop var
	node.end_slot = node.variable_slot + 1
	int for_reg = regalloc_slot_register(node.variable_slot - 1)
	if (node.argument_count >= 2):
		node.end_slot = node.variable_slot + 2
		load_slot(node.variable_slot + 1)
		for_store_loop_var(node.variable_slot)
	elif (for_reg != 0):
		mov_eax_int(0)
		mov_reg_eax(for_reg)

	# Enter a new loop context for break/continue
	int* outer = loop_enter()
	node.break_target = loop_break_chain
	# Loop region: the back edge re-tests the condition.
	node.top_target = be_ctrl_loop()

	# condition: loop var < end
	if (for_reg != 0):
		mov_eax_reg(for_reg)
		push_slot()
	else: push_slot_copy(node.variable_slot)
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
	int for_reg = regalloc_slot_register(node.variable_slot - 1)
	if (node.argument_count == 3):
		load_slot(node.variable_slot + 3)
		if (for_reg != 0): add_reg_eax(for_reg)
		else:
			regalloc_slot_assert(node.variable_slot - 1)
			add_dword_esp_plus_eax((stack_pos - node.variable_slot) << word_size_log2)
	elif (for_reg != 0): add_reg_int8(for_reg, 1)
	else:
		regalloc_slot_assert(node.variable_slot - 1)
		inc_dword_esp_plus((stack_pos - node.variable_slot) << word_size_log2)

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
	for_store_loop_var(node.variable_slot)

	if (node.value_var != 0):
		for_iter_call(node.value2_fn, node.container_slot, node.cursor_slot)
		coerce(node.value_var_type, node.value2_coerce_type)
		for_store_loop_var(node.value_var)

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


# S2.2c: a for loop's header walked from its record (code_generator/
# retained_emit.w). The grammar (grammar/ast_loop.w) records these phases
# in the order the streaming hooks ran the steps, and runs them itself, in
# place, when no walk is open. Header values (range arguments, the
# iterable) are walked one at a time, like a switch's (switch_ast_walk).
const int loop_walk_value = 1
const int loop_walk_value_end = 2
const int loop_walk_value_store = 3
const int loop_walk_range_begin = 4
const int loop_walk_range_end = 5
const int loop_walk_cursor_begin = 6
const int loop_walk_cursor_end = 7
const int loop_walk_leave = 8
const int loop_walk_cleanup = 9


struct loop_ast_walk:
	loop_ast* loop
	statement_ast* value
	int value_type
	int* outer


# One loop step; walk is 0 when the grammar runs it during the parse.
void emit_loop_ast_phase(loop_ast_walk* record, retained_statement_walk* walk, int phase):
	if (phase == loop_walk_value): emit_walk_header_value(walk, record.value)
	else if (phase == loop_walk_value_end): emit_statement_ast_expression_end(record.value)
	else if (phase == loop_walk_value_store): record.value_type = emit_iteration_value_ast(record.value)
	else if (phase == loop_walk_range_begin): record.outer = emit_range_loop_ast_begin(record.loop)
	else if (phase == loop_walk_range_end): emit_range_loop_ast_end(record.loop)
	else if (phase == loop_walk_cursor_begin): record.outer = emit_cursor_loop_ast_begin(record.loop)
	else if (phase == loop_walk_cursor_end): emit_cursor_loop_ast_end(record.loop)
	else if (phase == loop_walk_leave): loop_leave(record.outer)
	else if (phase == loop_walk_cleanup): emit_loop_ast_cleanup(record.loop)
	else: error(c"internal error: unknown loop walk phase")


void emit_loop_ast_walk(retained_statement_walk* walk, int phase):
	emit_loop_ast_phase(cast(loop_ast_walk*, walk.statement), walk, phase)


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
