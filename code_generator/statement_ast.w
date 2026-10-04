# Backend lowering consumes resolved statement nodes. Terminator parsing,
# target selection and source spans live in grammar/ast_statement.w.
void emit_simple_statement_ast(statement_ast* node):
	ast_simple_statements_emitted = ast_simple_statements_emitted + 1
	if (node.kind == ast_stmt_pass): return
	if (node.kind == ast_stmt_debugger):
		ast_debugger_statements_emitted = ast_debugger_statements_emitted + 1
		saw_debugger_statement = 1
		int3()
		return
	if (node.valid_jump == 0):
		if (node.kind == ast_stmt_break): error(c"'break' outside of a loop or switch")
		else: error(c"'continue' outside of a loop")
	if (node.unwind_slots > 0): be_pop(node.unwind_slots)
	be_br(node.target)


int ast_expression_emit_prepared(expression_ast* tree, int root);


# Value-bearing statements own an expression child. Source terminators
# are checked between value lowering and the final control transfer,
# retaining the established coercion/diagnostic order.
void emit_statement_ast_value(statement_ast* node):
	if (node.expression_root < 0): return
	int type = ast_expression_emit_prepared(node.expression_tree, node.expression_root)
	ast_roots_emitted = ast_roots_emitted + 1
	type = promote(type)
	if (node.kind == ast_stmt_yield):
		coerce_checked(node.declared_type, type, c"yield")
	else if ((type_num_args(node.declared_type) > 0) && (type_num_args(type) > 0)):
		if (types_compatible_with_expression(node.declared_type, type) == 0):
			warn_type_mismatch(c"return", node.declared_type, type)
		copy_struct_return_value(node.declared_type)
	else: coerce_checked(node.declared_type, type, c"return")


void emit_statement_ast_exit(statement_ast* node):
	if (node.kind == ast_stmt_yield):
		ast_yield_statements_emitted = ast_yield_statements_emitted + 1
		emit_generator_yield_call()
		return
	ast_return_statements_emitted = ast_return_statements_emitted + 1
	if (node.generator):
		for_cleanup_emit_all()
		emit_generator_finish_call()
	else:
		for_cleanup_emit_returning()
		defer_emit_returning()
		be_return(stack_pos)
