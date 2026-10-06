# Typed locals bind before their initializer; inferred locals bind after it.
# The node owns its prepared initializer through both backend visits. Symbol
# and lint bookkeeping retain their original positions between those visits.
int ast_local_declaration(statement_ast* node, char* name):
	node.expression_tree = 0
	node.expression_root = -1
	node.has_initializer = node.inferred
	if (node.inferred == 0): node.has_initializer = accept(c"=")
	node.end_offset = token_start_offset
	int got = -1
	expression_ast tree
	if (node.has_initializer):
		if ((node.inferred == 0) && type_is_array(node.declared_type)):
			error(c"fixed array initializer is not implemented")
		increment_statement_context = 0
		expression_lhs_readonly = 0
		int root = ast_expression_prepare_at(&tree, token_start_offset, 1)
		if (root < 0):
			# A rejected probe restores the expression entry. The normal
			# path reports its existing diagnostic or required-mode error.
			got = promote(expression())
			if (node.inferred == 0): coerce_checked(node.declared_type, got, c"initialization")
		else:
			node.expression_tree = &tree
			node.expression_root = root
			node.end_offset = tree.end_offset
			emit_statement_ast_expression(node)
			ast_statement_finish_expression(node)
			got = emit_declaration_ast_initializer(node)
		if ((node.inferred == 0) && (verbosity >= 1)):
			print2(c"variable declaration = expression() right side type: ")
			type_print(got)
	if (node.inferred):
		node.declared_type = inferred_storage_type(name, got)
		sym_declare(name, node.declared_type, 'L', stack_pos, 1)
		node.binding = table_pos - symbol_data_size
		sym_note_inferred_location(node.binding, node.line, node.column)
		lint_track_local(node.binding)
	else:
		node.binding = last_declared_symbol
		save_int(table + node.binding + 2, stack_pos)
	pointer_indirection = 0
	node.stack_depth = stack_pos
	emit_declaration_ast_storage(node)
	return node.declared_type
