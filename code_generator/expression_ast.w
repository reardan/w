# A record-returning call owns a caller-provided buffer above its saved
# callee slot. Keep the same allocation order as postfix_expr().
int emit_ast_return_buffer(int type):
	if ((type < 0) || (type_num_args(type) == 0)): return 0
	int words = (type_get_size(type) + word_size - 1) >> word_size_log2
	for j in range(words): push_eax()
	stack_pos = stack_pos + words
	return 1


void emit_ast_map_call(char* helper, int map_slot, int key_slot, int value_slot):
	int s = rt_call_begin(helper)
	push_slot_copy(map_slot)
	push_slot_copy(key_slot)
	if (value_slot): push_slot_copy(value_slot)
	rt_call_end(s)


# Walk the completed, decoded scalar tree in source evaluation order.
# Reuse the production backend dispatch and stack accounting; the same
# peepholes, target word size and runtime division behavior still apply.
void emit_expression_ast(expression_ast* tree, int id):
	int op = tree.op[id]
	if (op == 'A'):
		expression_is_assignment = 1
		int[128] lhs_slots
		int[128] rhs_slots
		int entry_stack = stack_pos
		int pair = tree.left[id]
		while (pair >= 0):
			emit_expression_ast(tree, tree.left[pair])
			if (pair == tree.left[id]): entry_stack = stack_pos
			lhs_slots[pair] = push_slot()
			pair = tree.next_arg[pair]
		pair = tree.left[id]
		while (pair >= 0):
			int rhs = tree.right[pair]
			emit_expression_ast(tree, rhs)
			int got = promote(tree.result_type[rhs])
			coerce(tree.result_type[tree.left[pair]], got)
			rhs_slots[pair] = push_slot()
			pair = tree.next_arg[pair]
		pair = tree.left[id]
		while (pair >= 0):
			mov_eax_esp_plus((stack_pos - rhs_slots[pair]) << word_size_log2)
			mov_ebx_esp_plus((stack_pos - lhs_slots[pair]) << word_size_log2)
			assign_store(tree.result_type[tree.left[pair]])
			pair = tree.next_arg[pair]
		pop_to(entry_stack)
		return
	if ((op == 'm') || (op == 'q') || (op == 'w')):
		int index = id
		if (op == 'w'): index = tree.left[id]
		int receiver = tree.left[index]
		emit_expression_ast(tree, receiver)
		promote(tree.result_type[receiver])
		int base_stack = stack_pos
		int map_slot = push_slot()
		int key = tree.right[index]
		emit_expression_ast(tree, key)
		int key_type = promote(tree.result_type[key])
		int map_type = tree.value[index]
		coerce(type_map_key_type(map_type), key_type)
		int key_slot = push_slot()
		int element = type_map_value_type(map_type)
		if (op == 'w'):
			expression_is_assignment = 1
			int subop = tree.value[id]
			if (subop):
				emit_ast_map_call(c"__w_map_get", map_slot, key_slot, 0)
				push_slot()
			int right = tree.right[id]
			emit_expression_ast(tree, right)
			int got = promote(tree.result_type[right])
			if (subop): got = compound_assign_apply(subop, type_value(element), got)
			coerce(element, got)
			int value_slot = push_slot()
			char* helper = c"__w_map_set"
			if ((type_num_args(element) > 0) && (type_num_args(got) > 0)): helper = c"__w_map_set_bytes"
			emit_ast_map_call(helper, map_slot, key_slot, value_slot)
			load_slot(value_slot)
		else:
			char* helper = c"__w_map_get"
			if (type_num_args(element) > 0): helper = c"__w_map_get_addr"
			emit_ast_map_call(helper, map_slot, key_slot, 0)
		pop_to(base_stack)
		return
	if (op == 'V'):
		int type = tree.value[id]
		if (type_is_list(type)): list_emit_new_container(type)
		else: hash_emit_new_container(type)
		return
	if (op == 'N'):
		int base = tree.value[id]
		sym_get_value(c"malloc")
		push_slot()
		push_slot_int(type_get_size(base))
		mov_eax_esp_plus(word_size)
		call_eax()
		drop_slots(2)
		if (type_has_array_field(base)):
			zero_runtime_object(type_get_size(base))
			init_array_field_descriptors(base)
		return
	if (op == 'P'):
		int base_stack = stack_pos
		int arg = tree.left[id]
		if (arg >= 0):
			emit_expression_ast(tree, arg)
			promote(tree.result_type[arg])
			int value_slot = push_slot()
			print_emit_call1(tree.high[id], value_slot)
		if (tree.value[id]): print_emit_nl()
		if (arg >= 0): pop_to(base_stack)
		return
	if ((op == 0) || (op == 'c') || (op == 'h')):
		mov_eax_int(tree.value[id])
		return
	if ((op == 's') || (op == 'S')):
		char* bytes = &tree.text[0]
		bytes = bytes + tree.value[id]
		if (op == 's'): be_emit_inline_cstr(tree.high[id], bytes)
		else:
			# The shared descriptor encoder still takes its bytes via
			# token. Decoding/validation already ran at the source token.
			char* saved_token = token
			token = bytes
			emit_utf8_string_descriptor(tree.high[id])
			token = saved_token
		return
	if (op == 'f'):
		if (word_size == 8): mov_rax_int64_halves(tree.value[id], tree.high[id])
		else: mov_eax_int32(tree.value[id])
		return
	if ((op == 'v') || (op == 'C')):
		char* name = table + tree.value[id]
		strcpy(last_identifier, name)
		int sym = tree.symbol[id]
		sym_emit_value(sym, name)
		if (op == 'C'):
			int declared_return = load_int(table + sym + 6)
			if (declared_return == 4): declared_return = -1
			int has_return_buffer = emit_ast_return_buffer(declared_return)
			int s = stack_pos
			push_slot()
			if (has_return_buffer):
				lea_eax_esp_plus(word_size)
				push_slot()
			int arg = tree.left[id]
			int count = 0
			while (arg >= 0):
				int arg_stack = stack_pos
				emit_expression_ast(tree, arg)
				int got = promote(tree.result_type[arg])
				int param_type = sym_param_type(sym, count)
				if (param_type >= 0): coerce_call_argument(param_type, got)
				push_call_argument_compact(got, stack_pos - arg_stack)
				count = count + 1
				arg = tree.next_arg[arg]
			finish_call(4, s, count, sym, 0, declared_return, count, has_return_buffer, -1)
		return
	emit_expression_ast(tree, tree.left[id])
	int left_type = tree.result_type[tree.left[id]]
	if (op == 'H'):
		int key_type = binary1(left_type)
		int key_slot = stack_pos
		int base_stack = key_slot - 1
		int right = tree.right[id]
		emit_expression_ast(tree, right)
		int container = type_unqualified(promote(tree.result_type[right]))
		int want = type_list_element_type(container)
		if (type_is_map(container)): want = type_map_key_type(container)
		else if (type_is_set(container)): want = type_set_key_type(container)
		if (type_decays_to_pointer(want, key_type)):
			push_slot()
			load_slot(key_slot)
			promote_eax()
			store_stack_var((stack_pos - key_slot) << word_size_log2)
			pop_eax_slot()
		int container_slot = push_slot()
		emit_ast_map_call(ast_expression_contains_helper(tree.value[id]), container_slot, key_slot, 0)
		pop_to(base_stack)
		return
	if (op == 'M'):
		promote(left_type)
		int base_stack = stack_pos
		int receiver_slot = push_slot()
		int first_slot = 0
		int second_slot = 0
		int arg = tree.right[id]
		int method = tree.value[id] & 127
		int count = 0
		while (arg >= 0):
			emit_expression_ast(tree, arg)
			int got = promote(tree.result_type[arg])
			if ((method == 1) || ((method == 3) && (count == 1))): coerce(tree.high[id], got)
			int slot = push_slot()
			if (count == 0): first_slot = slot
			else: second_slot = slot
			count = count + 1
			arg = tree.next_arg[arg]
		int s = rt_call_begin(ast_expression_list_helper(tree.value[id]))
		push_slot_copy(receiver_slot)
		if (first_slot): push_slot_copy(first_slot)
		if (second_slot): push_slot_copy(second_slot)
		rt_call_end(s)
		pop_to(base_stack)
		return
	if (op == 'F'):
		int has_return_buffer = emit_ast_return_buffer(tree.high[id])
		int s = stack_pos
		push_slot()
		if (has_return_buffer):
			lea_eax_esp_plus(word_size)
			push_slot()
		int signature = tree.value[id]
		int arg = tree.right[id]
		int count = 0
		while (arg >= 0):
			int arg_stack = stack_pos
			emit_expression_ast(tree, arg)
			int got = promote(tree.result_type[arg])
			if (signature >= 0): coerce_call_argument(type_function_param_type(signature, count), got)
			push_call_argument_compact(got, stack_pos - arg_stack)
			count = count + 1
			arg = tree.next_arg[arg]
		int arity = -1
		if (signature >= 0): arity = type_function_param_count(signature)
		finish_call(left_type, s, arity, -1, 0, tree.high[id], count, has_return_buffer, -1)
		return
	if (op == '='):
		expression_is_assignment = 1
		int lhs_slot = push_slot()
		int subop = tree.value[id]
		int loaded = left_type
		if (subop):
			loaded = promote(left_type)
			push_slot()
		emit_expression_ast(tree, tree.right[id])
		int rt = promote(tree.result_type[tree.right[id]])
		if (subop): rt = compound_assign_apply(subop, loaded, rt)
		coerce(left_type, rt)
		int lhs_buried = stack_pos - lhs_slot
		if (subop): pop_ebx_slot()
		else if (lhs_buried > 0): mov_ebx_esp_plus(lhs_buried << word_size_log2)
		else: pop_ebx()
		if (type_num_args(left_type) > 0): assign_store_struct(left_type)
		else: assign_store(left_type)
		if ((subop == 0) && (lhs_buried == 0)): stack_pos = stack_pos - 1
		return
	if ((op == 'a') || (op == 'o')):
		promote(left_type)
		int h = be_ctrl_block()
		int child = tree.next_arg[tree.left[id]]
		while (child >= 0):
			if (op == 'a'): be_br_zero(h)
			else: be_br_nonzero(h)
			emit_expression_ast(tree, child)
			promote(tree.result_type[child])
			child = tree.next_arg[child]
		be_ctrl_end(h)
		alu_test_set(0x95)
		return
	if (op == 'K'):
		int got = promote(left_type)
		coerce_explicit(tree.value[id], got)
		return
	if (op == '?'):
		promote(left_type)
		int h_join = be_ctrl_block()
		int h_stub = be_ctrl_block()
		int h_else = be_ctrl_block()
		be_br_zero_discard(h_else)
		emit_expression_ast(tree, tree.right[id])
		int yt = promote(tree.result_type[tree.right[id]])
		be_br(h_stub)
		be_ctrl_end(h_else)
		emit_expression_ast(tree, tree.high[id])
		int nt = promote(tree.result_type[tree.high[id]])
		if (yt != 3): coerce(yt, nt)
		be_ctrl_end(h_stub)
		be_ctrl_end(h_join)
		return
	if (op == 'r'): return
	if (op == 'd'):
		promote(left_type)
		return
	if (op == '.'):
		if (tree.high[id] > 0): promote(left_type)
		add_eax_int32(tree.value[id])
		if (tree.high[id] < 0):
			promote(tree.symbol[id])
			drop_slots(0 - tree.high[id])
		return
	if (op == 'B'):
		promote(left_type)
		if (tree.value[id]): add_eax_int32(tree.value[id])
		return
	if (op == 'j'):
		promote(left_type)
		int base_stack = stack_pos
		int list_slot = push_slot()
		emit_expression_ast(tree, tree.right[id])
		promote(tree.result_type[tree.right[id]])
		int index_slot = push_slot()
		int s = rt_call_begin(c"__w_list_addr")
		push_slot_copy(list_slot)
		push_slot_copy(index_slot)
		rt_call_end(s)
		pop_to(base_stack)
		expression_lhs_readonly = 0
		return
	if (op == 'I'):
		promote(left_type)
		push_slot()
		emit_expression_ast(tree, tree.right[id])
		promote(tree.result_type[tree.right[id]])
		buffer_bounds_check()
		if (tree.value[id] > 1): imul_eax_int32(tree.value[id])
		pop_ebx()
		promote_ebx()
		alu_add()
		stack_pos = stack_pos - 1
		expression_lhs_readonly = 0
		return
	if ((op == 'n') || (op == 'p') || (op == '~') || (op == '!') || (op == 'b')):
		int kind = type_float_kind(promote(left_type))
		if (op == 'n'):
			if (kind == 1): xor_eax_int32(1 << 31)
			else if (kind == 2): btc_rax_63()
			else: neg_eax()
		if (op == '~'): not_eax()
		if (op == '!'): alu_test_set(0x94)
		if (op == 'b'): alu_test_set(0x95)
		return
	left_type = binary1(left_type)
	emit_expression_ast(tree, tree.right[id])
	int right_type = promote(tree.result_type[tree.right[id]])
	if ((op == 'L') || (op == 'R')):
		stack_pos = stack_pos - 1
		if (op == 'L'): alu_shl()
		else: alu_sar()
		return
	if ((op == '&') || (op == '|') || (op == '^')):
		pop_ebx_slot()
		if (op == '&'): alu_and()
		else if (op == '|'): alu_or()
		else: alu_xor()
		return
	if (op == 'i'):
		if (tree.value[id] > 1): imul_eax_int32(tree.value[id])
		pop_ebx()
		alu_add()
		stack_pos = stack_pos - 1
		return
	if (op >= 0x90):
		pop_ebx_slot()
		int cc = op
		int swap = 0
		if ((op == 0x9c) || (op == 0x9e)): swap = 1
		if ((op == 0x9c) || (op == 0x9f)): cc = 0x97
		if ((op == 0x9e) || (op == 0x9d)): cc = 0x93
		int result = 0
		if ((op == 0x94) || (op == 0x95)): result = string_binary_compare_eq(left_type, right_type, op == 0x95)
		if (result == 0): result = float_binary_compare(left_type, right_type, cc, swap)
		if (result == 0): alu_cmp_set(op)
		return
	if (binary_float_kind(left_type, right_type)):
		pop_ebx_slot()
		float_binary_arithmetic(left_type, right_type, op)
		return
	if ((op == '+') || (op == '-') || (op == '*')):
		pop_ebx_slot()
		if (op == '+'): alu_add()
		else if (op == '-'): alu_sub()
		else: alu_imul()
	else:
		if (op == '/'): alu_idiv()
		else: alu_imod()
		stack_pos = stack_pos - 1
