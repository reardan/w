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
	if (kind == ast_stmt_debugger): emit_statement_ast(&node)
	expect_or_newline(c";")
	if (kind != ast_stmt_debugger): emit_statement_ast(&node)
	return 1
