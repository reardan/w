# GPU headers own prepared expression children. Dimensions leave their
# value in the accumulator so syntax checks can precede the slot push.
int ast_gpu_value(int type, int kernel_sym, char* name, int index):
	statement_ast node
	node.kind = ast_stmt_gpu_dimension
	if (kernel_sym >= 0): node.kind = ast_stmt_gpu_argument
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.declared_type = type
	node.binding = kernel_sym
	node.callee_name = name
	node.argument_index = index
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
	return emit_gpu_value_ast(&node)


void ast_gpu_capture_value(char* name):
	statement_ast node
	node.kind = ast_stmt_gpu_capture
	node.callee_name = name
	node.binding = sym_lookup(name)
	if (node.binding < 0): sym_not_found_error(name)
	emit_gpu_capture_value_ast(&node)


int ast_launch_statement():
	if (peek(c"launch") == 0): return 0
	gpu_statement_ast node
	node.kind = ast_gpu_launch
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.header_slots = 0
	char* save = generic_reparse_save()
	get_token()
	int c0 = token[0]
	int is_ident = is_ident_start_byte(c0)
	if (is_ident == 0):
		getchar_seek(file, load_ptr(save + 7 * __word_size__))
		generic_reparse_restore(save)
		return 0
	free(cast(char*, load_ptr(save + 11 * __word_size__)))
	free(save)

	if (target_isa == 3): error(c"'launch' is not supported in gpu code")
	gpu_target_check()
	if (sym_lookup(c"__w_gpu_launch_raw") < 0): error(c"gpu code requires 'import lib.cuda'")
	node.kernel_symbol = sym_lookup(token)
	int is_kernel = 0
	if (node.kernel_symbol >= 0): is_kernel = sym_is_kernel(node.kernel_symbol)
	if (is_kernel == 0): error3(c"'", token, c"' is not a kernel")
	node.kernel_name = strclone(token)
	get_token()

	node.base_stack = stack_pos
	expect(c"[")
	node.integer_type = type_lookup(c"int")
	ast_gpu_value(node.integer_type, -1, 0, 0)
	emit_gpu_dimension_slot_ast(&node) /* grid */
	expect(c",")
	ast_gpu_value(node.integer_type, -1, 0, 0)
	emit_gpu_dimension_slot_ast(&node) /* block */
	expect(c"]")

	expect(c"(")
	node.argument_count = 0
	if (accept(c")") == 0):
		ast_gpu_value(sym_param_type(node.kernel_symbol, node.argument_count), node.kernel_symbol, node.kernel_name, node.argument_count)
		node.argument_count = node.argument_count + 1
		while (accept(c",")):
			ast_gpu_value(sym_param_type(node.kernel_symbol, node.argument_count), node.kernel_symbol, node.kernel_name, node.argument_count)
			node.argument_count = node.argument_count + 1
		expect(c")")

	# The launch path passes exactly one 8-byte cell per declared
	# parameter: a count mismatch would feed the kernel garbage cells.
	int expected_args = sym_num_args(node.kernel_symbol)
	if (node.argument_count != expected_args):
		diag_part(c"kernel '")
		diag_part(node.kernel_name)
		diag_part(c"' expects ")
		error3(itoa(expected_args), c" arguments, got ", itoa(node.argument_count))

	node.end_offset = token_start_offset
	emit_gpu_launch_ast(&node)
	free(node.kernel_name)
	return 1


int ast_gpu_for_statement():
	if (peek(c"gpu") == 0): return 0
	gpu_statement_ast node
	node.kind = ast_gpu_for
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.header_slots = 0
	char* save = generic_reparse_save()
	get_token()
	if (peek(c"for") == 0):
		getchar_seek(file, load_ptr(save + 7 * __word_size__))
		generic_reparse_restore(save)
		return 0
	free(cast(char*, load_ptr(save + 11 * __word_size__)))
	free(save)

	if (target_isa == 3): error(c"'gpu for' cannot nest inside gpu code")
	gpu_target_check()
	if (sym_lookup(c"__w_gpu_launch") < 0): error(c"gpu code requires 'import lib.cuda'")

	int gpu_for_tab_level = tab_level
	get_token() /* consume 'for' */

	# Loop variable: 'int name' (one thread index per iteration)
	node.integer_type = type_lookup(c"int")
	int type = type_name()
	if (type_unqualified(type) != node.integer_type): error(c"'gpu for' loop variable must be an int")
	node.variable_name = strclone(token)
	get_token()
	expect(c"in")
	if (accept(c"range") == 0): error(c"'gpu for' supports only range iteration")

	# The range operands, evaluated in host mode into hidden slots that
	# double as the leading capture cells: range(end) pushes just the
	# bound (capture slot 0); range(start, end) pushes start then end
	# (slots 0 and 1, parse order). The device guard reloads the bound
	# from its slot; a step argument is not supported.
	node.base_stack = stack_pos
	int has_parens = accept(c"(")
	node.has_start = 0
	ast_gpu_value(node.integer_type, -1, 0, 0)
	emit_gpu_dimension_slot_ast(&node)
	if (accept(c",")):
		node.has_start = 1
		ast_gpu_value(node.integer_type, -1, 0, 0)
		if (accept(c",")): error(c"'gpu for' supports only range(end) and range(start, end)")
		emit_gpu_dimension_slot_ast(&node)
	if (has_parens): expect(c")")

	# Device side: outline the body into a fresh kernel
	node.symbol_base = table_pos
	node.kernel_name = gpu_for_kernel_name()
	node.launch_name = strclone(node.kernel_name)
	emit_gpu_for_device_begin_ast(&node)
	sym_declare(node.variable_name, node.integer_type, 'L', stack_pos, 1)
	pointer_indirection = 0
	emit_gpu_loop_variable_ast(&node)
	free(node.variable_name)
	node.variable_name = 0

	# Compiler-inserted guard: threads past the bound do nothing
	emit_gpu_for_guard_ast(&node)

	enclosing_tab_level = gpu_for_tab_level
	statement()

	emit_gpu_for_device_end_ast(&node)
	table_pos = node.symbol_base

	# Host side: push the remaining captures' current values (slot
	# order; the range operands already sit at node.base_stack+1..), then launch.
	int k = 1 + node.has_start
	while (k < node.capture_count):
		ast_gpu_capture_value(gpu_capture_name(k))
		k = k + 1
	node.end_offset = token_start_offset
	emit_gpu_for_launch_ast(&node)
	free(node.launch_name)
	return 1
