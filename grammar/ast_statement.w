# Statement grammar builds resolved nodes and visits child statements
# in source order. Backend phases consume their payloads and control
# targets; body traversal remains incremental, without retained child lists.
int ast_statement_simple(int* jumps):
	if (ast_expressions_mode < 2): return 0
	int kind = 0
	if (peek(c"pass")): kind = ast_stmt_pass
	else if (peek(c"debugger")): kind = ast_stmt_debugger
	else if (peek(c"break")): kind = ast_stmt_break
	else if (peek(c"continue")): kind = ast_stmt_continue
	if (kind == 0): return 0
	statement_ast node
	node.kind = kind
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.end_offset = token_start_offset + token_i
	node.target = 0
	node.unwind_slots = 0
	node.valid_jump = 1
	if (kind == ast_stmt_break):
		*jumps = 1
		node.valid_jump = (loop_depth != 0) || (switch_depth != 0)
		if (break_in_switch):
			node.target = switch_break_chain
			node.unwind_slots = stack_pos - switch_stack_pos
		else:
			node.target = loop_break_chain
			node.unwind_slots = stack_pos - loop_stack_pos
	else if (kind == ast_stmt_continue):
		*jumps = 1
		node.valid_jump = loop_depth != 0
		node.target = loop_continue_chain
		node.unwind_slots = stack_pos - loop_stack_pos
	get_token()
	# The debugger marker historically precedes terminator diagnostics;
	# branch validation historically follows them. Preserve both orders.
	if (kind == ast_stmt_debugger): emit_simple_statement_ast(&node)
	expect_or_newline(c";")
	if (kind != ast_stmt_debugger): emit_simple_statement_ast(&node)
	return 1


int ast_expression_prepare_at(expression_ast* tree, int group_offset, int whole);
void ast_expression_finish_prepared(expression_ast* tree);


void ast_statement_finish_expression(statement_ast* node):
	if (node.expression_root < 0): return
	ast_expression_finish_prepared(node.expression_tree)
	ast_roots_emitted = ast_roots_emitted + 1



int ast_statement_value(int* jumps):
	if (ast_expressions_mode < 2): return 0
	int kind = 0
	if (peek(c"return")): kind = ast_stmt_return
	else if (peek(c"yield")): kind = ast_stmt_yield
	if (kind == 0): return 0
	statement_ast node
	node.kind = kind
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.end_offset = token_start_offset + token_i
	node.generator = in_generator_body
	node.expression_tree = 0
	node.expression_root = -1
	get_token()
	int has_value = 1
	if (kind == ast_stmt_return):
		*jumps = 1
		if (in_gpu_for_body): error(c"'return' is not supported in 'gpu for'")
		has_value = (peek(c";") == 0) && (token_newline == 0) && (token[0] != 0)
		if (has_value && in_generator_body): error(c"generators cannot return a value; use yield")
	else if (in_generator_body == 0): error(c"'yield' outside of a generator body")
	expression_ast tree
	if (has_value):
		increment_statement_context = 0
		expression_lhs_readonly = 0
		int root = ast_expression_prepare_at(&tree, token_start_offset, 1)
		if (root < 0):
			# The expression probe restored its entry state. Existing
			# tails retain diagnostic fallback and required-mode errors.
			if (kind == ast_stmt_return): return_statement_tail()
			else: yield_statement_tail()
			return 1
		node.expression_tree = &tree
		node.expression_root = root
		node.end_offset = tree.end_offset
	node.declared_type = 0
	if (has_value): node.declared_type = load_int(table + current_function_symbol + 6)
	emit_statement_ast_expression(&node)
	ast_statement_finish_expression(&node)
	emit_statement_ast_value(&node)
	expect_or_newline(c";")
	emit_statement_ast_exit(&node)
	return 1


# Prefix increment has its earlier dispatch position. All other expression
# statements arrive here only after declarations, labels and special forms
# have had their normal precedence in the statement dispatcher.
int ast_statement_expression(int prefix_only):
	if (ast_expressions_mode < 2): return 0
	if (prefix_only && (increment_op() == 0)): return 0
	statement_ast node
	node.kind = ast_stmt_expression
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	increment_statement_context = 0
	expression_lhs_readonly = 0
	expression_ast tree
	int root = ast_expression_prepare_at(&tree, token_start_offset, 2)
	if (root < 0): return 0
	node.expression_tree = &tree
	node.expression_root = root
	node.end_offset = tree.end_offset
	emit_statement_ast_expression(&node)
	ast_statement_finish_expression(&node)
	ast_expression_statements_emitted = ast_expression_statements_emitted + 1
	expect_or_newline(c";")
	return 1


# A conditional branch owns its expression and resolved failure target.
# Enclosing if/while bodies still use their streaming scope dispatcher.
void ast_statement_guard(int target, int outer_condition):
	statement_ast node
	node.kind = ast_stmt_guard
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.target = target
	node.expression_tree = 0
	node.expression_root = -1
	lint_condition_begin()
	increment_statement_context = 0
	expression_lhs_readonly = 0
	expression_ast tree
	int root = ast_expression_prepare_at(&tree, token_start_offset, 1)
	if (root < 0):
		promote(expression())
		node.end_offset = token_start_offset
	else:
		node.expression_tree = &tree
		node.expression_root = root
		node.end_offset = tree.end_offset
		emit_statement_ast_expression(&node)
		ast_statement_finish_expression(&node)
		emit_guard_ast_value(&node)
	lint_condition_end()
	condition_context = outer_condition
	emit_guard_ast_branch(&node)


# Expression children remain live until their switch value has been lowered.
# Case bodies and enclosing break-region lifetimes stay in the dispatcher.
int ast_statement_switch_value():
	statement_ast node
	node.kind = ast_stmt_switch_value
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
	return emit_switch_value_ast(&node)


int ast_statement_switch_case(int type, int slot, int body_target, int next_target):
	statement_ast node
	node.kind = ast_stmt_switch_case
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.declared_type = type
	node.stack_depth = slot
	node.expression_tree = 0
	node.expression_root = -1
	emit_switch_case_ast_begin(&node)
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
	emit_switch_case_ast_compare(&node)
	node.branch_nonzero = accept(c",")
	node.target = next_target
	if (node.branch_nonzero): node.target = body_target
	emit_switch_case_ast_branch(&node)
	return node.branch_nonzero


void ast_if_statement_tail():
	statement_ast node
	node.kind = ast_stmt_if
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	int if_tab_level = tab_level
	int outer_condition = condition_context
	condition_context = 1
	emit_if_ast_begin(&node)
	statement_guard(node.alternate_target, outer_condition)
	enclosing_tab_level = if_tab_level
	statement()
	emit_if_ast_then_end(&node)
	if (peek(c"elif") && (tab_level == if_tab_level)):
		get_token()
		stmt_nesting_depth = stmt_nesting_depth + 1
		if (stmt_nesting_depth > 200): error(c"statement nesting too deep")
		ast_if_statement_tail()
		stmt_nesting_depth = stmt_nesting_depth - 1
	else if (peek(c"else")):
		if (tab_level == if_tab_level):
			get_token()
			enclosing_tab_level = if_tab_level
			statement()
	node.end_offset = token_start_offset
	emit_if_ast_end(&node)


int ast_statement_block():
	if (ast_expressions_mode < 2): return 0
	int kind = 0
	if (peek(c"{")): kind = ast_stmt_brace_block
	else if (peek(c":")): kind = ast_stmt_indent_block
	if (kind == 0): return 0
	statement_ast node
	node.kind = kind
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	int block_tab_level = enclosing_tab_level
	get_token()
	node.binding = table_pos
	node.stack_depth = stack_pos
	int start_tab_level = tab_level
	if (kind == ast_stmt_indent_block): print_int_v1(c"starting stack_pos: ", stack_pos)
	node.function_body = defer_function_body_pending
	defer_function_body_pending = 0
	if (kind == ast_stmt_brace_block):
		int after_jump = 0
		while (accept(c"}") == 0):
			lint_unreachable_check(after_jump)
			statement()
			after_jump = lint_last_stmt_jumps
	else:
		int same_line = 0
		if (token_newline == 0):
			same_line = 1
			if (token[0] != 0): statement()
		if ((same_line == 0) && (start_tab_level > block_tab_level)):
			int after_jump = 0
			while (start_tab_level <= tab_level):
				lint_unreachable_check(after_jump)
				statement()
				after_jump = lint_last_stmt_jumps
	node.end_offset = token_start_offset
	emit_block_ast_deferred(&node)
	lint_scope_exit(node.binding)
	table_pos = node.binding
	if (kind == ast_stmt_indent_block): print_int_v1(c"ending stack_pos: ", stack_pos)
	emit_block_ast_end(&node)
	return 1


int ast_switch_statement():
	if (peek(c"switch") == 0): return 0
	statement_ast node
	node.kind = ast_stmt_switch
	node.unwind_slots = 1
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	get_token()

	int switch_tab_level = tab_level

	# The scrutinee is evaluated exactly once, into a hidden stack slot
	node.declared_type = switch_value()
	node.stack_depth = stack_pos

	expect(c":")
	if ((token_newline == 0) && (token[0] != 0)): error(c"switch body must start on a new line")

	# Enter a new break context: 'break' in a case body exits the switch.
	# One region serves both exits — each body's implicit break and every
	# explicit 'break' branch to the switch end.
	int outer_chain = switch_break_chain
	int outer_stack = switch_stack_pos
	int outer_in_switch = break_in_switch
	emit_switch_region_ast_begin(&node)
	switch_break_chain = node.target
	switch_stack_pos = stack_pos
	break_in_switch = 1
	switch_depth = switch_depth + 1

	int seen_default = 0

	while ((tab_level > switch_tab_level) && (token[0] != 0)):
		int label_tab_level = tab_level
		if (seen_default): error(c"'default' must be the last clause in a switch")

		# Region for jumps past this case while its values do not match
		emit_switch_case_region_ast_begin(&node)
		if (accept(c"case")):
			# Multi-value case: any matching value jumps to the body
			emit_switch_match_region_ast_begin(&node)
			int more = 1
			while (more):
				more = switch_case_value(node.declared_type, node.stack_depth, node.body_target, node.alternate_target)
			emit_switch_match_region_ast_end(&node)
		else if (accept(c"default")): seen_default = 1
		else: error(c"'case' or 'default' expected in switch body")

		# The body is an ordinary ':' block scoped to the label's line
		enclosing_tab_level = label_tab_level
		statement()

		# Implicit break: leave the switch after the body (no fallthrough)
		emit_switch_case_region_ast_end(&node)

	# No-match fallthrough, each body's exit jump, and 'break' all land
	# here, before the scrutinee slot is discarded
	node.end_offset = token_start_offset
	emit_switch_region_ast_end(&node)

	switch_break_chain = outer_chain
	switch_stack_pos = outer_stack
	break_in_switch = outer_in_switch
	switch_depth = switch_depth - 1

	# Discard the hidden scrutinee slot
	emit_switch_region_ast_cleanup(&node)

	return 1


# Build at the exit site: bindings and temporary stack depth intentionally
# differ from registration. Deferred expressions retain value-expression
# syntax; statement-only increments and parallel stores stay disallowed.
int ast_deferred_expression():
	if (ast_expressions_mode < 2): return 0
	statement_ast node
	node.kind = ast_stmt_deferred_expression
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	increment_statement_context = 0
	expression_lhs_readonly = 0
	expression_ast tree
	int root = ast_expression_prepare_at(&tree, token_start_offset, 1)
	if (root < 0): return 0
	node.expression_tree = &tree
	node.expression_root = root
	node.end_offset = tree.end_offset
	emit_statement_ast_expression(&node)
	ast_statement_finish_expression(&node)
	ast_deferred_expressions_emitted = ast_deferred_expressions_emitted + 1
	return 1
