# Header expression children are emitted before their temporary arenas
# unwind. Loop state then spans the existing body/scoping dispatcher.
int ast_iteration_value(int store_slot):
	statement_ast node
	node.kind = ast_stmt_iterable
	if (store_slot): node.kind = ast_stmt_range_argument
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.expression_tree = 0
	node.expression_root = -1
	increment_statement_context = 0
	expression_lhs_readonly = 0
	expression_ast tree
	int root = ast_expression_prepare_at(&tree, token_start_offset, 1)
	if (root < 0):
		node.expression_type = expression()
		node.end_offset = token_start_offset
	else:
		node.expression_tree = &tree
		node.expression_root = root
		node.end_offset = tree.end_offset
		emit_statement_ast_expression(&node)
		ast_statement_finish_expression(&node)
	return emit_iteration_value_ast(&node)


void ast_for_range_loop(int for_var, int for_tab_level):
	loop_ast node
	node.kind = ast_loop_range
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.variable_slot = for_var
	int has_parens = accept(c"(")
	node.argument_count = 1
	ast_iteration_value(1)
	while (accept(c",")):
		ast_iteration_value(1)
		node.argument_count = node.argument_count + 1
	if (has_parens): expect(c")")
	if (node.argument_count > 3): error(c"range() takes 1-3 arguments")
	int* outer = emit_range_loop_ast_begin(&node)
	enclosing_tab_level = for_tab_level
	statement()
	node.end_offset = token_start_offset
	emit_range_loop_ast_end(&node)
	loop_leave(outer)
	emit_loop_ast_cleanup(&node)


void ast_for_cursor_loop(int for_var, int for_tab_level, int loop_var_type,
		char* begin_fn, char* done_fn, char* value_fn, char* next_fn, char* free_fn,
		int element_type, int value_coerce_type,
		int value_var, int value_var_type, char* value2_fn, int value2_coerce_type):
	loop_ast node
	node.kind = ast_loop_cursor
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.variable_slot = for_var
	node.variable_type = loop_var_type
	node.begin_fn = begin_fn
	node.done_fn = done_fn
	node.value_fn = value_fn
	node.next_fn = next_fn
	node.free_fn = free_fn
	node.value2_fn = value2_fn
	node.element_type = element_type
	node.value_coerce_type = value_coerce_type
	node.value_var = value_var
	node.value_var_type = value_var_type
	node.value2_coerce_type = value2_coerce_type
	int* outer = emit_cursor_loop_ast_begin(&node)
	if (free_fn != 0): for_cleanup_push(free_fn, node.container_slot)
	enclosing_tab_level = for_tab_level
	statement()
	node.end_offset = token_start_offset
	if (free_fn != 0): for_cleanup_truncate(for_cleanup_count() - 1)
	emit_cursor_loop_ast_end(&node)
	loop_leave(outer)
	emit_loop_ast_cleanup(&node)


# S2.2b: under --ast-emit-retained a while loop is a statement walk
# (emit_guard_ast_walk): the keyword and its condition are parsed before
# the loop's regions are opened, and the back edge and region ends are
# emitted once the body has been parsed.
int ast_while_statement():
	if (peek(c"while") == 0): return 0
	loop_ast node
	node.kind = ast_loop_while
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	get_token()
	int while_tab_level = tab_level
	int* outer = 0
	control_ast_walk control
	int walk = retained_walk_begin(cast(int, emit_guard_ast_walk), 0)
	if (walk >= 0):
		control.statement = 0
		control.loop = &node
		control.outer = 0
		control_ast_walk_attach(walk, &control)
		retained_walk_phase(walk, ast_walk_while_begin)
		control_ast_guard_pending = &control
	else: outer = emit_while_loop_ast_begin(&node)
	int outer_condition = condition_context
	condition_context = 1
	statement_guard(node.break_target, outer_condition)
	# Fall-through bookkeeping mirrors while_statement
	# (grammar/while_statement.w, grammar/type_check.w)
	int forever = flow_guard_true
	enclosing_tab_level = while_tab_level
	if (walk >= 0):
		retained_walk_drain(walk)
		outer = control.outer
	statement()
	forever = forever && (flow_loop_break == 0)
	node.end_offset = token_start_offset
	if (walk >= 0):
		retained_walk_phase(walk, ast_walk_while_end)
		retained_emit_statement(retained_walks[walk].node)
	else: emit_while_loop_ast_end(&node)
	loop_leave(outer)
	flow_terminates = forever
	return 1
