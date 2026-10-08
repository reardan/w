# S2.2c: under --ast-emit-retained a for loop's header is walked from its
# record (emit_loop_ast_walk), like a switch's (grammar/ast_statement.w).
# The walk is drained before the body, whose parse reads the loop slots and
# the break and continue context the header's phases set up; the steps
# after the body are its last phases.
void ast_loop_step(int walk, loop_ast_walk* record, int phase):
	if (walk >= 0): retained_walk_phase(walk, phase)
	else: emit_loop_ast_phase(record, 0, phase)


void ast_iteration_value_into(int walk, loop_ast_walk* record, expression_ast* tree, int store_slot):
	ast_walk_settle(walk)
	statement_ast* value = record.value
	value.kind = ast_stmt_iterable
	if (store_slot): value.kind = ast_stmt_range_argument
	ast_walk_header_value(walk, value, tree, loop_walk_value, loop_walk_value_end)
	ast_loop_step(walk, record, loop_walk_value_store)


# The walk an iterable started for the cursor loop that follows it, plus
# one (0: none).
int ast_loop_iterable_walk


# A for-in iterable starts its loop's walk. The for rule checks the
# iterable's type before the cursor loop is reached, and those checks may
# print, so the iterable is walked before returning; ast_for_cursor_loop
# continues the same walk.
int ast_iteration_value(int store_slot):
	statement_ast local_value
	statement_ast* value = cast(statement_ast*, retained_parse_record(&local_value, sizeof(statement_ast)))
	expression_ast tree
	loop_ast_walk local_record
	loop_ast_walk* record = cast(loop_ast_walk*, retained_parse_record(&local_record, sizeof(loop_ast_walk)))
	record.loop = 0
	record.value = value
	record.outer = 0
	int walk = -1
	if (store_slot == 0):
		walk = retained_walk_begin(cast(int, emit_loop_ast_walk), cast(statement_ast*, record))
		ast_loop_iterable_walk = walk + 1
	ast_iteration_value_into(walk, record, &tree, store_slot)
	ast_walk_settle(walk)
	return record.value_type


void ast_for_range_loop(int for_var, int for_tab_level):
	loop_ast local_node
	loop_ast* node = cast(loop_ast*, retained_parse_record(&local_node, sizeof(loop_ast)))
	node.kind = ast_loop_range
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.variable_slot = for_var
	statement_ast local_value
	statement_ast* value = cast(statement_ast*, retained_parse_record(&local_value, sizeof(statement_ast)))
	expression_ast tree
	loop_ast_walk local_record
	loop_ast_walk* record = cast(loop_ast_walk*, retained_parse_record(&local_record, sizeof(loop_ast_walk)))
	record.loop = node
	record.value = value
	record.outer = 0
	int walk = retained_walk_begin(cast(int, emit_loop_ast_walk), cast(statement_ast*, record))
	int has_parens = ast_walk_accept(walk, c"(")
	node.argument_count = 1
	ast_iteration_value_into(walk, record, &tree, 1)
	while (ast_walk_accept(walk, c",")):
		ast_iteration_value_into(walk, record, &tree, 1)
		node.argument_count = node.argument_count + 1
	if (has_parens): ast_walk_expect(walk, c")")
	if (node.argument_count > 3):
		ast_walk_settle(walk)
		error(c"range() takes 1-3 arguments")
	ast_loop_step(walk, record, loop_walk_range_begin)
	ast_walk_settle(walk)
	enclosing_tab_level = for_tab_level
	statement()
	node.end_offset = token_start_offset
	ast_loop_step(walk, record, loop_walk_range_end)
	ast_loop_step(walk, record, loop_walk_leave)
	ast_loop_step(walk, record, loop_walk_cleanup)
	if (walk >= 0): retained_emit_statement(retained_walks[walk].node)


void ast_for_cursor_loop(int for_var, int for_tab_level, int loop_var_type,
		char* begin_fn, char* done_fn, char* value_fn, char* next_fn, char* free_fn,
		int element_type, int value_coerce_type,
		int value_var, int value_var_type, char* value2_fn, int value2_coerce_type):
	loop_ast local_node
	loop_ast* node = cast(loop_ast*, retained_parse_record(&local_node, sizeof(loop_ast)))
	node.kind = ast_loop_cursor
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.variable_slot = for_var
	node.variable_type = loop_var_type
	node.begin_fn = retained_parse_name(begin_fn)
	node.done_fn = retained_parse_name(done_fn)
	node.value_fn = retained_parse_name(value_fn)
	node.next_fn = retained_parse_name(next_fn)
	node.free_fn = retained_parse_name(free_fn)
	node.value2_fn = retained_parse_name(value2_fn)
	node.element_type = element_type
	node.value_coerce_type = value_coerce_type
	node.value_var = value_var
	node.value_var_type = value_var_type
	node.value2_coerce_type = value2_coerce_type
	loop_ast_walk local_record
	loop_ast_walk* record = cast(loop_ast_walk*, retained_parse_record(&local_record, sizeof(loop_ast_walk)))
	record.loop = node
	record.value = 0
	record.outer = 0
	# Continue the walk the iterable started on this statement, if any.
	int walk = ast_loop_iterable_walk - 1
	ast_loop_iterable_walk = 0
	if (walk >= 0):
		if ((retained_parent < 0) || (retained_walk_stale(walk)) || (retained_walks[walk].node != retained_parent)): walk = -1
	if (walk >= 0): retained_walks[walk].statement = cast(statement_ast*, record)
	ast_loop_step(walk, record, loop_walk_cursor_begin)
	ast_walk_settle(walk)
	if (free_fn != 0): for_cleanup_push(free_fn, node.container_slot)
	enclosing_tab_level = for_tab_level
	statement()
	node.end_offset = token_start_offset
	if (free_fn != 0): for_cleanup_truncate(for_cleanup_count() - 1)
	ast_loop_step(walk, record, loop_walk_cursor_end)
	ast_loop_step(walk, record, loop_walk_leave)
	ast_loop_step(walk, record, loop_walk_cleanup)
	if (walk >= 0): retained_emit_statement(retained_walks[walk].node)


# S2.2b: under --ast-emit-retained a while loop is a statement walk
# (emit_guard_ast_walk): the keyword and its condition are parsed before
# the loop's regions are opened, and the back edge and region ends are
# emitted once the body has been parsed.
# A rotated loop (grammar/loop_rotate.w, the twin of while_statement in
# grammar/while_statement.w) skips the condition, parses the body with
# the header's phases drained, and parses the condition as the bottom
# test afterwards: its guard phases are recorded and drained with the
# lexer at the condition, the end phase with it back at the body's end.
void emit_while_loop_ast_bottom(loop_ast* node);


int ast_while_statement():
	if (peek(c"while") == 0): return 0
	loop_ast local_node
	loop_ast* node = cast(loop_ast*, retained_parse_record(&local_node, sizeof(loop_ast)))
	node.kind = ast_loop_while
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.rotated = 0
	node.entry_site = -1
	get_token()
	int while_tab_level = tab_level
	int outer_condition = condition_context
	int* outer = 0
	control_ast_walk local_control
	control_ast_walk* control = cast(control_ast_walk*, retained_parse_record(&local_control, sizeof(control_ast_walk)))
	int walk = retained_walk_begin(cast(int, emit_guard_ast_walk), 0)
	if (walk >= 0):
		control.statement = 0
		control.loop = node
		control.outer = 0
		control_ast_walk_attach(walk, control)
		retained_walk_phase(walk, ast_walk_while_begin)
	tokenizer_snapshot cond_mark
	char* cond_text = 0
	if (loop_rotate_on()):
		cond_text = loop_rotate_mark(&cond_mark)
		node.rotated = loop_rotate_skip_condition()
		if (node.rotated == 0):
			loop_rotate_return(&cond_mark, cond_text)
			cond_text = 0
	if (walk < 0): outer = emit_while_loop_ast_begin(node)
	# Fall-through bookkeeping mirrors while_statement
	# (grammar/while_statement.w, grammar/type_check.w)
	int forever = 0
	if (node.rotated == 0):
		if (walk >= 0): control_ast_guard_pending = control
		condition_context = 1
		statement_guard(node.break_target, outer_condition, 0)
		forever = flow_guard_true
	enclosing_tab_level = while_tab_level
	if (walk >= 0):
		retained_walk_drain(walk)
		outer = control.outer
	statement()
	if (node.rotated):
		tokenizer_snapshot body_mark
		char* body_text = loop_rotate_mark(&body_mark)
		loop_rotate_return(&cond_mark, cond_text)
		emit_while_loop_ast_bottom(node)
		if (walk >= 0): control_ast_guard_pending = control
		condition_context = 1
		statement_guard(node.top_target, outer_condition, 1)
		forever = flow_guard_true
		int serial = token_serial
		loop_rotate_return(&body_mark, body_text)
		if (token_serial < serial): token_serial = serial
	forever = forever && (flow_loop_break == 0)
	node.end_offset = token_start_offset
	if (walk >= 0):
		retained_walk_phase(walk, ast_walk_while_end)
		retained_emit_statement(retained_walks[walk].node)
	else: emit_while_loop_ast_end(node)
	loop_leave(outer)
	flow_terminates = forever
	return 1
