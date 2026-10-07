# Lower resolved GPU operands and host/device statement phases.
int emit_gpu_value_ast(statement_ast* node):
	int type = promote(node.expression_type)
	if (node.kind == ast_stmt_gpu_argument):
		if (type_num_args(type_real(type)) > 0): error(c"struct arguments are not supported in launch")
		if (node.expression_root >= 0): ast_expression_note_root(node.expression_tree, node.expression_root)
		check_call_argument(node.binding, -1, node.callee_name, node.argument_index, type)
		const_note_override = 0
		if (node.declared_type >= 0): coerce_call_argument(node.declared_type, type)
		push_slot()
	else: coerce(node.declared_type, type)
	ast_gpu_values_emitted = ast_gpu_values_emitted + 1
	return type


void emit_gpu_dimension_slot_ast(gpu_statement_ast* node):
	push_slot()
	node.header_slots = node.header_slots + 1


void emit_gpu_launch_ast(gpu_statement_ast* node):
	launch_emit_runtime_call(node.kernel_name, node.base_stack, node.argument_count)
	pop_to(node.base_stack)
	ast_gpu_launches_emitted = ast_gpu_launches_emitted + 1


void emit_gpu_for_device_begin_ast(gpu_statement_ast* node):
	device_mode_enter()
	gpu_capture_reset()
	if (node.has_start):
		gpu_capture_reserve() /* slot 0 = start, slot 1 = end */
	in_gpu_for_body = 1
	ptx_kernel_begin(node.kernel_name)

	# i = block_idx() * block_dim() + thread_idx() [+ start]
	ptx_special_reg(2)
	push_slot()
	ptx_special_reg(3)
	pop_ebx_slot()
	alu_imul()
	push_slot()
	ptx_special_reg(1)
	pop_ebx_slot()
	alu_add()
	if (node.has_start):
		push_slot()
		ptx_lea_ax_bp_minus(1 << word_size_log2) /* capture slot 0: start */
		promote_eax()
		pop_ebx_slot()
		alu_add()


void emit_gpu_loop_variable_ast(gpu_statement_ast* node):
	node.variable_slot = push_slot()


void emit_gpu_for_guard_ast(gpu_statement_ast* node):
	node.guard_target = be_ctrl_block()
	mov_eax_esp_plus(0) /* i */
	push_slot()
	ptx_lea_ax_bp_minus((1 + node.has_start) << word_size_log2) /* the bound */
	promote_eax()
	pop_ebx_slot()
	alu_cmp_set(0x9c) /* setl: i < bound */
	be_br_zero(node.guard_target)



void emit_gpu_for_device_end_ast(gpu_statement_ast* node):
	be_ctrl_end(node.guard_target)
	ret()
	ptx_kernel_end(gpu_capture_count, gpu_capture_limit << word_size_log2)
	in_gpu_for_body = 0
	device_mode_exit()
	node.capture_count = gpu_capture_count


void emit_gpu_capture_value_ast(statement_ast* node):
	promote(sym_emit_value(node.binding, node.callee_name))
	push_slot()
	ast_gpu_captures_emitted = ast_gpu_captures_emitted + 1


void emit_gpu_for_launch_ast(gpu_statement_ast* node):
	gpu_for_emit_runtime_call(node.launch_name, node.base_stack, node.capture_count, node.has_start)
	pop_to(node.base_stack)
	ast_gpu_fors_emitted = ast_gpu_fors_emitted + 1


# S2.2e: the walk of a launch or gpu for statement (grammar/ast_gpu.w).
# walk.statement is the statement's gpu_statement_ast; its value field is
# the header value whose phases are pending (at most one at a time), and
# the walk's expression child is that value's.
void emit_gpu_walk_ast(retained_statement_walk* walk, int phase):
	gpu_statement_ast* node = cast(gpu_statement_ast*, walk.statement)
	statement_ast* value = node.value
	int code = phase & 255
	if (code == ast_gpu_walk_expression):
		int root = retained_walk_lower_expression(walk)
		expression_lhs_readonly = walk.tree.readonly
		value.expression_type = walk.tree.result_type[root]
	else if (code == ast_gpu_walk_expression_end): emit_statement_ast_expression_end(value)
	else if (code == ast_gpu_walk_value): emit_gpu_value_ast(value)
	else if (code == ast_gpu_walk_slot): emit_gpu_dimension_slot_ast(node)
	else if (code == ast_gpu_walk_launch): emit_gpu_launch_ast(node)
	else if (code == ast_gpu_walk_device_begin): emit_gpu_for_device_begin_ast(node)
	else if (code == ast_gpu_walk_loop_variable): emit_gpu_loop_variable_ast(node)
	else if (code == ast_gpu_walk_guard): emit_gpu_for_guard_ast(node)
	else if (code == ast_gpu_walk_device_end): emit_gpu_for_device_end_ast(node)
	else if (code == ast_gpu_walk_capture):
		statement_ast capture
		capture.kind = ast_stmt_gpu_capture
		capture.callee_name = gpu_capture_name(phase >> 8)
		capture.binding = node.capture_bindings[phase >> 8]
		emit_gpu_capture_value_ast(&capture)
	else if (code == ast_gpu_walk_for_launch): emit_gpu_for_launch_ast(node)
	else: error(c"internal error: unknown gpu statement walk phase")
