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


void emit_expression_statement_ast(statement_ast* node):
	ast_expression_emit_prepared(node.expression_tree, node.expression_root)
	ast_roots_emitted = ast_roots_emitted + 1
	ast_expression_statements_emitted = ast_expression_statements_emitted + 1


void emit_goto_target(int label, int source_stack):
	if (goto_label_pos[label] >= 0):
		# Backward: the label's depth is known
		goto_adjust_stack(source_stack, goto_label_stack[label])
		jmp_int32(0)
		be_branch_patch(codepos, goto_label_pos[label])
		return
	jmp_int32(0)
	goto_reserve()
	goto_pending_label[goto_pending_count] = label
	goto_pending_site[goto_pending_count] = codepos
	goto_pending_stack[goto_pending_count] = source_stack
	goto_pending_count = goto_pending_count + 1


void emit_label_target(int label, int target_stack):
	# A jump lands here: no constant/compare fold may reach back across it
	be_cmp_note_reset()
	be_imm_note_reset()
	# Forward gotos at another depth get an adjust-and-jump stub, placed
	# before the label behind a jump that skips them on fall-through
	int skip = 0
	int i = goto_pending_base
	while (i < goto_pending_count):
		if ((goto_pending_label[i] == label) && (goto_pending_stack[i] != target_stack)):
			if (skip == 0):
				jmp_int32(0)
				skip = codepos
			be_branch_patch(goto_pending_site[i], codepos)
			goto_adjust_stack(goto_pending_stack[i], target_stack)
			jmp_int32(0)
			# The stub's own jump is resolved to the label below
			goto_pending_site[i] = codepos
		i = i + 1
	if (skip): be_branch_patch(skip, codepos)
	# ...nor across the label itself, past any stub emitted above
	be_notes_reset()
	goto_label_pos[label] = codepos
	goto_label_stack[label] = target_stack
	i = goto_pending_base
	while (i < goto_pending_count):
		if (goto_pending_label[i] == label):
			be_branch_patch(goto_pending_site[i], codepos)
			goto_pending_label[i] = -1
		i = i + 1


void emit_goto_statement_ast(statement_ast* node):
	if (node.kind == ast_stmt_goto): emit_goto_target(node.target, node.stack_depth)
	else: emit_label_target(node.target, node.stack_depth)
	ast_goto_statements_emitted = ast_goto_statements_emitted + 1


void emit_raw_statement_ast(statement_ast* node):
	emit(node.literal_length, node.literal_bytes)
	ast_raw_statements_emitted = ast_raw_statements_emitted + 1


void emit_inferred_local_storage(int type):
	int size = type_stack_words(type)
	if ((type_num_args(type) > 0) & (type_is_array(type) == 0)):
		# Struct value: eax holds its address; copy the words
		int j = size - 1
		while (j >= 0):
			push_eax_plus(j << word_size_log2)
			j = j - 1
		stack_pos = stack_pos + size
		if (type_has_array_field(type)):
			lea_eax_esp_plus(0)
			init_array_field_descriptors(type)
		return
	for i in range(size): push_eax()
	stack_pos = stack_pos + size
	return


void emit_typed_local_storage(int type, int has_initializer):
	# Reserve enough words for aggregate storage, else 1 word.
	int size = type_stack_words(type)
	int num_args = type_num_args(type)
	if ((num_args > 0) & (type_is_array(type) == 0)):
		if (has_initializer):
			int j = size - 1
			while (j >= 0):
				push_eax_plus(j << word_size_log2)
				j = j - 1
			stack_pos = stack_pos + size
			if (type_has_array_field(type)):
				lea_eax_esp_plus(0)
				init_array_field_descriptors(type)
			return
	if (type_is_array(type) | type_has_array_field(type)): mov_eax_int(0)
	for i in range(size): push_eax()
	stack_pos = stack_pos + size
	if (type_is_array(type)):
		lea_eax_esp_plus(2 * word_size)
		store_stack_var(0)
		mov_eax_int(type_get_array_length(type))
		store_stack_var(word_size)
	else if (type_has_array_field(type)):
		lea_eax_esp_plus(0)
		init_array_field_descriptors(type)
	return


int emit_declaration_ast_initializer(statement_ast* node):
	int got = ast_expression_emit_prepared(node.expression_tree, node.expression_root)
	ast_roots_emitted = ast_roots_emitted + 1
	got = promote(got)
	if (node.inferred == 0): coerce_checked(node.declared_type, got, c"initialization")
	return got


void emit_declaration_ast_storage(statement_ast* node):
	ast_declarations_emitted = ast_declarations_emitted + 1
	if (node.inferred): emit_inferred_local_storage(node.declared_type)
	else: emit_typed_local_storage(node.declared_type, node.has_initializer)
