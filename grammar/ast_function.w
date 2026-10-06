# Parameter declarations remain semantic input to the ordinary function
# rule. Its completed signature feeds these resolved body-boundary nodes.
void ast_function_body(int binding, int code_start, int kind, int written_return_type, int retained_line, int retained_column):
	function_ast node
	node.kind = kind
	node.binding = binding
	node.source_file = file
	node.start_offset = token_start_offset
	node.code_start = code_start
	node.argument_words = number_of_args
	node.name = strclone(last_global_declaration)
	int retained = retained_enter(retained_function, filename, node.start_offset, diag_token_line, diag_token_column, node.name)
	emit_function_begin_ast(&node)
	retained_function_parameters(binding)
	current_function_symbol = binding
	if (kind == ast_function_generator): in_generator_body = 1
	enclosing_tab_level = 0
	emit_function_debug_ast(&node)
	if (kind == ast_function_native):
		defer_reset()
		defer_function_body_pending = 1
	node.outer_label_base = goto_label_base
	node.outer_pending_base = goto_pending_base
	goto_scope_begin()
	int outer_saw_return = flow_saw_return
	flow_saw_return = 0
	statement()
	node.end_offset = token_start_offset
	# Mirrors function_definition (grammar/program.w)
	if (kind == ast_function_native):
		check_missing_return(written_return_type, node.name, retained_line, retained_column)
		flow_function_finished(node.name)
	flow_saw_return = outer_saw_return
	goto_scope_end(node.outer_label_base, node.outer_pending_base)
	if (kind == ast_function_native): defer_reset()
	emit_function_end_ast(&node)
	retained_leave(retained, node.end_offset)
	free(node.name)


void ast_script_main():
	int int_type = type_lookup(c"int")
	int binding = sym_declare_global(c"main", int_type, 2)
	int symbol_base = table_pos
	number_of_args = 0
	function_ast node
	node.kind = ast_function_script
	node.binding = binding
	node.source_file = file
	node.start_offset = token_start_offset
	node.code_start = codepos
	node.argument_words = 0
	node.name = c"main"
	save_int(table + binding + 22, 0)
	sym_set_w_variadic(binding, -1)
	int retained = retained_enter(retained_function, filename, node.start_offset, diag_token_line, diag_token_column, node.name)
	emit_function_begin_ast(&node)
	current_function_symbol = binding
	enclosing_tab_level = 0
	emit_function_debug_ast(&node)
	defer_reset()
	node.outer_label_base = goto_label_base
	node.outer_pending_base = goto_pending_base
	goto_scope_begin()
	while (token[0] != 0):
		if (script_declaration_keyword()):
			error(c"declarations must come before the first top-level statement")
		if (script_function_definition_ahead()):
			error(c"declarations must come before the first top-level statement")
		statement()
	node.end_offset = token_start_offset
	goto_scope_end(node.outer_label_base, node.outer_pending_base)
	defer_emit_all()
	defer_reset()
	emit_function_end_ast(&node)
	retained_leave(retained, node.end_offset)
	table_pos = symbol_base


void ast_kernel_function_definition(int binding, char* name):
	table[binding + 10] = 2
	sym_set_kernel(binding)
	sym_define_global_at(binding, 0)
	int symbol_base = table_pos
	function_ast node
	node.kind = ast_function_kernel
	node.binding = binding
	node.source_file = file
	node.start_offset = token_start_offset
	node.name = name
	node.parameter_count = 0
	int retained = retained_enter(retained_function, filename, node.start_offset, diag_token_line, diag_token_column, node.name)
	emit_function_begin_ast(&node)
	while (accept(c")") == 0):
		function_parameter_ast parameter
		parameter.index = node.parameter_count
		parameter.binding = -1
		node.parameter_count = node.parameter_count + 1
		int type = type_name()
		parameter.declared_type = type
		if (accept(c".")): error(c"variadic kernel parameters are not supported")
		if (type_stack_words(type) != 1): error(c"kernel parameters must be word-sized")
		if (type_num_args(type_real(type)) > 0): error(c"kernel parameters must be word-sized")
		if (node.parameter_count <= sym_max_param_slots):
			save_int(table + binding + 22 + (node.parameter_count << 2), type)
		emit_kernel_parameter_value_ast(&parameter)
		if (peek(c")") == 0):
			sym_declare(token, type, 'L', stack_pos, 1)
			parameter.binding = last_declared_symbol
			pointer_indirection = 0
			get_token()
		if (accept(c"=")): error(c"kernel parameters cannot have default values")
		emit_kernel_parameter_slot_ast(&parameter)
		accept(c",")
	save_int(table + binding + 22, node.parameter_count)
	sym_set_w_variadic(binding, -1)
	if (accept(c";")): error(c"a kernel declaration requires a body")
	current_function_symbol = binding
	enclosing_tab_level = 0
	statement()
	node.end_offset = token_start_offset
	emit_function_end_ast(&node)
	retained_leave(retained, node.end_offset)
	table_pos = symbol_base
