# Function code generation consumes resolved boundaries and parameters.
void emit_function_begin_ast(function_ast* node):
	if (node.kind == ast_function_kernel):
		device_mode_enter()
		ptx_kernel_begin(node.name)
		return
	if (node.kind == ast_function_generator):
		sym_define_global(node.binding)
		profile_generator_enter(node.binding, node.name)   # P1: --profile-generate
		return
	be_function_define(node.binding, node.name)
	be_function_prologue()
	profile_function_enter(node.binding, node.name)   # P1: --profile-generate
	node.frame_words = be_frame_words()
	stack_pos = stack_pos + node.frame_words


void emit_function_debug_ast(function_ast* node):
	debug_func_note(node.code_start, node.argument_words)


void emit_function_end_ast(function_ast* node):
	if (node.kind == ast_function_kernel):
		ret()
		ptx_kernel_end(node.parameter_count, 0)
		device_mode_exit()
		ast_kernels_emitted = ast_kernels_emitted + 1
		return
	if (node.kind == ast_function_generator):
		emit_generator_finish_call()
		in_generator_body = 0
		ast_generators_emitted = ast_generators_emitted + 1
	else if (node.kind == ast_function_script):
		if (node.frame_words):
			mov_eax_int(0)
			be_return(stack_pos)
		else:
			be_pop(stack_pos)
			mov_eax_int(0)
			ret()
		stack_pos = 0
		be_function_epilogue()
		ast_scripts_emitted = ast_scripts_emitted + 1
	else:
		be_return_bare()
		be_function_epilogue()
		stack_pos = stack_pos - node.frame_words
		ast_functions_emitted = ast_functions_emitted + 1
	save_int(table + node.binding + 14, codepos - node.code_start)


void emit_kernel_parameter_value_ast(function_parameter_ast* node):
	ptx_param_load(node.index)


void emit_kernel_parameter_slot_ast(function_parameter_ast* node):
	node.slot = push_slot()
	ast_kernel_parameters_emitted = ast_kernel_parameters_emitted + 1
