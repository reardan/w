# Typed locals bind before their initializer; inferred locals bind after it.
# The node owns its prepared initializer through both backend visits. Symbol
# and lint bookkeeping retain their original positions between those visits.
#
# S2.2d: under --ast-emit-retained a local declaration, goto, label, raw_asm
# or defer statement is parsed completely before any of its code is emitted.
# The parse records the facts (the local's type and name, the label index
# and stack depth, the raw bytes, the deferred statement's span); the walk
# (emit_declaration_ast_walk, code_generator/statement_ast.w) reproduces the
# side effects in the streaming order: lowering the initializer, its
# coercion, the local's slot assignment and storage, the jump or label,
# the bytes, the defer registration. A statement that cannot start a walk
# is emitted during its parse as before.


# A declaration starts a walk only when it is the dispatcher's statement:
# one in a 'for' header belongs to the loop statement's node.
int ast_declaration_walk_begin(statement_ast* node):
	if ((ast_emit_retained_mode == 0) || (retained_parent < 0)): return -1
	if (retained_record_at(retained_parent).start != node.start_offset): return -1
	return retained_walk_begin(cast(int, emit_declaration_ast_walk), node)


# Bind a local at an analysis-supplied slot without emitting storage or
# advancing the backend stack. Typed declarations already carry the binding
# created by their type-name parse; inferred declarations enter scope only
# after their initializer. The current dispatcher supplies stack_pos, while
# a body analysis pass can supply its own independently computed depth.
void ast_declaration_bind(statement_ast* node, int depth):
	if (node.inferred):
		node.declared_type = inferred_storage_type(node.literal_bytes, node.expression_type)
		sym_declare(node.literal_bytes, node.declared_type, 'L', depth, 1)
		node.binding = table_pos - symbol_data_size
		sym_note_inferred_location(node.binding, node.line, node.column)
		lint_track_local(node.binding)
	else:
		sym_set_value_at(node.binding, depth)
	pointer_indirection = 0
	node.stack_depth = depth


# A typed local is in scope in its own initializer (as in C), but its slot
# does not exist until the initializer's value is stored: reading it there
# would load a stack word below the stack pointer. Taking its address
# ('void* p = &p') stays legal; any read is rejected. A statement that
# starts with '(' on the next line is absorbed as a call of the initializer
# ('int n = 2' then '(n)'); that already reports W0084 and a call error,
# so a read inside it adds nothing and is not reported again.
void ast_declaration_self_read_check(expression_ast* tree, int binding):
	for event in range(tree.count):
		if ((tree.op[event] == ast_warning) && (tree.high[event] == 7)):
			if (strcmp(cast(char*, tree.value[event]), c"warning: call arguments continue from the previous line") == 0): return
	for id in range(tree.count):
		if ((tree.op[id] == 'v') && (tree.symbol[id] == binding)):
			int taken = 0
			for parent in range(tree.count):
				if ((tree.op[parent] == 'r') && (tree.left[parent] == id)): taken = 1
			if (taken == 0):
				int k = expression_ast_token_at(tree, tree.offset[id])
				if (k >= 0):
					int* row = expression_ast_token_row(tree, k)
					line_number = row[3]
					diag_token_line = row[1]
					diag_token_column = row[2]
				error3(c"local '", table + tree.value[id], c"' is read in its own initializer")


int ast_local_declaration(statement_ast* node, char* name):
	if (node.inferred == 0): node.binding = last_declared_symbol
	node.expression_tree = 0
	node.expression_root = -1
	node.expression_type = -1
	node.literal_bytes = retained_parse_name(name)
	node.has_initializer = node.inferred
	if (node.inferred == 0): node.has_initializer = accept(c"=")
	node.end_offset = token_start_offset
	int walk = -1
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
			node.expression_type = promote(expression())
			if (node.inferred == 0): coerce_checked(node.declared_type, node.expression_type, c"initialization")
			emit_declaration_ast_trace(node)
		else:
			if (node.inferred == 0): ast_declaration_self_read_check(&tree, node.binding)
			node.expression_tree = &tree
			node.expression_root = root
			node.end_offset = tree.end_offset
			walk = ast_declaration_walk_begin(node)
			if (walk >= 0):
				ast_statement_walk_expression(walk, node)
				retained_walk_phase(walk, ast_walk_declaration_initializer)
			else:
				emit_statement_ast_expression(node)
				ast_statement_finish_expression(node)
				node.expression_type = emit_declaration_ast_initializer(node)
				emit_declaration_ast_trace(node)
	else: walk = ast_declaration_walk_begin(node)
	# Finish initializer diagnostics before the new binding enters scope.
	ast_walk_settle(walk)
	ast_declaration_bind(node, ast_body_depth())
	ast_body_reserve(type_stack_words(node.declared_type))
	if (walk >= 0):
		retained_walk_phase(walk, ast_walk_declaration_storage)
		retained_emit_statement(retained_walks[walk].node)
	else:
		emit_declaration_ast_storage(node)
	return node.declared_type


# goto and labels: the statement is parsed, its terminator included, before
# the jump or label is emitted from its record. Returns 0 when it must be
# emitted directly.
int ast_goto_walk(statement_ast* node):
	int walk = retained_walk_begin(cast(int, emit_declaration_ast_walk), node)
	if (walk < 0): return 0
	retained_walk_phase(walk, ast_walk_goto)
	retained_emit_statement(retained_walks[walk].node)
	return 1


# raw_asm: the decoded bytes live in the token buffer, which the rest of the
# parse overwrites, so the record owns a copy until the walk emits it.
# Returns -1 when the bytes must be emitted directly.
int ast_raw_walk_open(statement_ast* node):
	int walk = retained_walk_begin(cast(int, emit_declaration_ast_walk), node)
	if (walk < 0): return -1
	node.literal_bytes = retained_text_copy(node.literal_bytes, node.literal_length)
	retained_walk_phase(walk, ast_walk_raw)
	return walk


void ast_raw_walk_close(int walk, statement_ast* node):
	assert1(retained_walks[walk].statement == node)
	retained_emit_statement(retained_walks[walk].node)


# defer: the parse checks the form and records the span; the walk registers
# it (defer_record_span, grammar/defer.w) once the rest of the line is
# skipped. Returns 0 when the caller must register it directly. The 'defer'
# keyword is consumed; the deferred statement's first token is current.
int ast_defer_registration():
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	node.kind = ast_stmt_deferred_expression
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	int walk = retained_walk_begin(cast(int, emit_declaration_ast_walk), node)
	if (walk < 0): return 0
	node.literal_bytes = retained_parse_name(filename)
	retained_walk_phase(walk, ast_walk_defer_register)
	int tree = defer_tree_capture()
	node.end_offset = token_start_offset
	retained_emit_statement(retained_walks[walk].node)
	defer_spans[defer_count() - 1].tree = tree
	return 1


int ast_scoped_defer_enabled():
	return ast_emit_retained_mode
