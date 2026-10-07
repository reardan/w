# The parse state an analysis boundary (compiler/analysis.w) records
# before each declaration and statement under check --all-errors, and
# puts back after error() jumped out of a failed one. It reads globals of
# the grammar and code generator, so it is imported after them.


void analysis_capture(analysis_state* state):
	state.filename = filename
	state.file = file
	state.nextc = nextc
	state.line_number = line_number
	state.column_number = column_number
	state.tab_level = tab_level
	state.token_newline = token_newline
	state.byte_offset = byte_offset
	state.diag_token_line = diag_token_line
	state.diag_token_column = diag_token_column
	state.token_start_offset = token_start_offset
	state.token = strclone(token)
	state.token_i = token_i
	state.pointer_indirection = pointer_indirection
	retained_capture(&state.retained)
	state.stack_pos = stack_pos
	state.loop_depth = loop_depth
	state.loop_break_chain = loop_break_chain
	state.loop_continue_chain = loop_continue_chain
	state.loop_stack_pos = loop_stack_pos
	state.switch_depth = switch_depth
	state.switch_break_chain = switch_break_chain
	state.switch_stack_pos = switch_stack_pos
	state.break_in_switch = break_in_switch
	state.defer_count = defer_count()
	state.for_cleanup_count = for_cleanup_count()
	state.number_of_args = number_of_args
	state.function_symbol = current_function_symbol
	state.ctrl_stack_pos = ctrl_stack_pos
	state.dwarf_blocks = 0
	if (dwarf_block_stack != 0): state.dwarf_blocks = dwarf_block_stack.length
	state.dwarf_open_func = dwarf_open_func
	state.dwarf_open_depth = dwarf_open_depth
	state.stmt_nesting_depth = stmt_nesting_depth
	state.expr_nesting_depth = expr_nesting_depth
	state.enclosing_tab_level = enclosing_tab_level
	state.defer_function_body_pending = defer_function_body_pending
	state.target_isa = target_isa
	state.bounds_mode = bounds_mode
	state.in_generator_body = in_generator_body
	state.in_gpu_for_body = in_gpu_for_body
	state.device_symbol_base = device_symbol_base
	state.generic_subst = generic_subst_block
	state.control_guard_pending = cast(int, control_ast_guard_pending)
	state.loop_iterable_walk = ast_loop_iterable_walk


# Put back what a failed item may have left half-updated, and return the
# lexer to the item's first token (the source is re-read through the
# same buffered fd, so only a position outside the read window seeks).
void analysis_restore(analysis_state* state):
	# A failure inside a generic instantiation's reparse leaves that
	# definition's file open and current.
	if ((file != state.file) && (file >= 0)): close(file)
	filename = state.filename
	file = state.file
	getchar_seek(file, state.byte_offset)
	nextc = state.nextc
	line_number = state.line_number
	column_number = state.column_number
	tab_level = state.tab_level
	token_newline = state.token_newline
	byte_offset = state.byte_offset
	diag_token_line = state.diag_token_line
	diag_token_column = state.diag_token_column
	token_start_offset = state.token_start_offset
	# error() may have been reached with the token buffer swapped for a
	# shorter diagnostic copy (grammar/postfix_expr.w's field error):
	# start from a fresh buffer of the recorded size.
	int length = strlen(state.token)
	if (token_size <= length + 1): token_size = (length + 10) << 1
	token = malloc(token_size)
	strcpy(token, state.token)
	token_i = state.token_i
	pointer_indirection = state.pointer_indirection
	retained_rollback(&state.retained)
	# The failed statement's walk record (--ast-emit-retained) lost its
	# node with the rollback; hand its phases back before the enclosing
	# walk records more.
	retained_walk_release()
	be_cmp_note_reset()
	be_imm_note_reset()
	stack_pos = state.stack_pos
	loop_depth = state.loop_depth
	loop_break_chain = state.loop_break_chain
	loop_continue_chain = state.loop_continue_chain
	loop_stack_pos = state.loop_stack_pos
	switch_depth = state.switch_depth
	switch_break_chain = state.switch_break_chain
	switch_stack_pos = state.switch_stack_pos
	break_in_switch = state.break_in_switch
	defer_truncate(state.defer_count)
	for_cleanup_truncate(state.for_cleanup_count)
	number_of_args = state.number_of_args
	current_function_symbol = state.function_symbol
	if (ctrl_stack_pos > state.ctrl_stack_pos): ctrl_stack_pos = state.ctrl_stack_pos
	if (dwarf_block_stack != 0):
		while (dwarf_block_stack.length > state.dwarf_blocks): dwarf_block_stack.pop()
	dwarf_open_func = state.dwarf_open_func
	dwarf_open_depth = state.dwarf_open_depth
	stmt_nesting_depth = state.stmt_nesting_depth
	expr_nesting_depth = state.expr_nesting_depth
	enclosing_tab_level = state.enclosing_tab_level
	defer_function_body_pending = state.defer_function_body_pending
	target_isa = state.target_isa
	bounds_mode = state.bounds_mode
	in_generator_body = state.in_generator_body
	in_gpu_for_body = state.in_gpu_for_body
	device_symbol_base = state.device_symbol_base
	generic_subst_block = state.generic_subst
	control_ast_guard_pending = cast(control_ast_walk*, state.control_guard_pending)
	ast_loop_iterable_walk = state.loop_iterable_walk
	# The parse-context flags error() can leave set mid-expression.
	condition_context = 0
	cast_context = 0
	cond_pending = 0
	cond_discard_mark = 0
	ast_cond_discard = 0
	increment_statement_context = 0
	diag_clear()
	diag_clear_help()


# A failed statement publishes no control-flow facts of its own. Report
# it as one that may not complete, so the enclosing function's
# missing-return check does not add a follow-on warning for a body whose
# final statement failed; and as one that does not jump, so the next
# statement is not reported unreachable.
void analysis_statement_failed():
	flow_terminates = 1
	lint_last_stmt_jumps = 0
