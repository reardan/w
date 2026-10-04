# The streaming statement dispatcher still owns scopes and compound
# statements. This first statement slice builds explicit leaf nodes and
# resolves their control targets before passing them to the AST emitter.
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
