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


void emit_expression_ast(expression_ast* tree, int id);


# Emit fixed/default arguments and W variadic tails for a saved callee.
# Method calls have already pushed their receiver and start at argument 1.
int emit_ast_direct_arguments(expression_ast* tree, int id, int s, int passed):
	int sym = tree.symbol[id]
	int variadic = sym_w_variadic_fixed_args(sym)
	int element = -1
	if (variadic >= 0): element = type_get_element_type(type_unqualified(sym_param_type(sym, variadic)))
	int variadic_values = 0
	int fixed_words_end = -1
	int arg = tree.left[id]
	int count = passed
	while (arg >= 0):
		int is_tail = (variadic >= 0) && (count >= variadic)
		if (is_tail && (variadic_values == 0)): fixed_words_end = stack_pos
		int arg_stack = stack_pos
		emit_expression_ast(tree, arg)
		int got = promote(tree.result_type[arg])
		int param_type = sym_param_type(sym, count)
		if (is_tail): param_type = element
		if (param_type >= 0): coerce_call_argument(param_type, got)
		if (is_tail):
			push_slot()
			variadic_values = variadic_values + 1
		else: push_call_argument_compact(got, stack_pos - arg_stack)
		count = count + 1
		arg = tree.next_arg[arg]
	if (variadic >= 0): finish_w_variadic_arguments(s, fixed_words_end, variadic_values)
	return count


# Walk the completed, decoded scalar tree in source evaluation order.
# Reuse the production backend dispatch and stack accounting; the same
# peepholes, target word size and runtime division behavior still apply.
void emit_expression_ast(expression_ast* tree, int id):
	int op = tree.op[id]
	if (op == ast_propagate):
		int child = tree.left[id]
		emit_expression_ast(tree, child)
		result_propagate_suffix(tree.result_type[child])
		return
	if (op == ast_forward_generic):
		if (cast(int, generic_forwards) == 0): generic_forwards = new list[generic_forward_record]
		generic_forward_record rec
		rec.name = strclone(&tree.type_names[tree.value[id]])
		rec.args = cast(int, malloc(generic_max_params * __word_size__))
		rec.arg_count = tree.high[id]
		int argument = tree.left[id]
		for i in range(rec.arg_count):
			save_ptr(rec.args + i * __word_size__, tree.value[argument])
			argument = tree.next_arg[argument]
		rec.chain = addr_chain_link(0)
		rec.call_file = strclone(filename)
		rec.call_line = tree.symbol[id]
		generic_forwards.push(rec)
		strcpy(last_identifier, c"$forward generic call$")
		return
	if (op == ast_list_it_value):
		strcpy(last_identifier, c"it")
		be_lea_acc_wstack((stack_pos - tree.it_slot[tree.symbol[id]]) << word_size_log2)
		return
	if (op == ast_list_it):
		int receiver = tree.left[id]
		emit_expression_ast(tree, receiver)
		int element = type_list_element_type(type_unqualified(tree.result_type[receiver]))
		char* value_fn = c"__w_list_iter_value"
		if (type_num_args(type_unqualified(element)) > 0): value_fn = c"__w_list_addr"
		promote(tree.result_type[receiver])
		int base_stack = stack_pos
		int list_slot = push_slot()
		mov_eax_int(0)
		int cursor_slot = push_slot()
		int keys_slot = push_slot()
		int it_slot = push_slot()
		tree.it_slot[id] = it_slot
		# Reproduce the hidden local's instruction boundary and debugger
		# metadata; its references have already been bound to this node.
		pointer_indirection = 0
		be_notes_reset()
		debug_local_note(c"it", it_slot - 1, 'L', tree.high[id])
		int exit = be_ctrl_block()
		int top = be_ctrl_loop()
		push_slot_copy(cursor_slot)
		load_slot(list_slot)
		add_eax_int32(word_size)
		promote_eax()
		pop_ebx_slot()
		alu_cmp_set(0x9c)
		be_br_zero_discard(exit)
		for_iter_call(value_fn, list_slot, cursor_slot)
		store_stack_var((stack_pos - it_slot) << word_size_log2)
		int body = tree.right[id]
		emit_expression_ast(tree, body)
		promote(tree.result_type[body])
		int key_type = tree.symbol[id]
		int key_size = list_element_slot_size(key_type)
		push_slot()
		list_it_call(c"__w_list_push_lazy", keys_slot, stack_pos, key_size)
		store_stack_var((stack_pos - keys_slot) << word_size_log2)
		drop_slots(1)
		inc_dword_esp_plus((stack_pos - cursor_slot) << word_size_log2)
		be_br(top)
		be_ctrl_end(top)
		be_ctrl_end(exit)
		list_it_call(c"__w_list_or_new", keys_slot, 0, key_size)
		store_stack_var((stack_pos - keys_slot) << word_size_log2)
		int mode = tree.value[id]
		int kind = tree.generic_arity[id]
		if (mode == 1): list_it_call(c"__w_list_filter_keys", list_slot, keys_slot, -1)
		else if ((mode >= 2) && (mode <= 5)): list_it_call(c"__w_list_truth", keys_slot, 0, mode - 2)
		else if ((mode >= 6) && (mode <= 8)):
			char* helper = c"__w_list_sum"
			if (mode == 7): helper = c"__w_list_min"
			if (mode == 8): helper = c"__w_list_max"
			list_it_call(helper, keys_slot, 0, -1)
		else if (mode == 9): list_it_call(c"__w_list_sort_keys", list_slot, keys_slot, kind)
		else if (mode == 10): list_it_call(c"__w_list_sorted_keys", list_slot, keys_slot, kind)
		else if (mode >= 11):
			list_it_call(c"__w_list_best_key", keys_slot, 0, kind | ((mode - 11) << 2))
			push_slot()
			list_it_call(c"__w_list_addr", list_slot, stack_pos, -1)
		pop_to(base_stack)
		return
	if (op == 'E'):
		int base_stack = stack_pos
		template_emit_helper_address(0)
		int s = stack_pos
		push_slot()
		rt_call_end(s)
		int builder_slot = push_slot()
		int part = tree.left[id]
		int spec = -1
		while (part >= 0):
			if (tree.op[part] == 't'):
				spec = tree.right[part]
				if (tree.high[part] > 0):
					char* saved_token = token
					token = &tree.text[0]
					token = token + tree.value[part]
					template_emit_chunk_append(tree.high[part], builder_slot)
					token = saved_token
			else:
				emit_expression_ast(tree, part)
				int got = promote(tree.result_type[part])
				template_spec_present = 0
				if (spec >= 0):
					template_spec_present = tree.result_type[spec]
					if (template_spec_present):
						template_spec_width = tree.left[spec]
						template_spec_precision = tree.right[spec]
						template_spec_fill = tree.value[spec]
						template_spec_align = tree.high[spec]
						template_spec_type = tree.symbol[spec]
				template_emit_value_append(got, builder_slot)
			part = tree.next_arg[part]
		template_emit_helper_address(5)
		s = stack_pos
		push_slot()
		push_slot_copy(builder_slot)
		rt_call_end(s)
		pop_to(base_stack)
		return
	if (op == ast_device_builtin):
		int kind = tree.value[id]
		if (kind <= 4): ptx_special_reg(kind)
		else if (kind <= 6):
			int child = tree.left[id]
			emit_expression_ast(tree, child)
			coerce(float32_type, promote(tree.result_type[child]))
			if (kind == 5): ptx_gpu_exp()
			else: ptx_gpu_log()
		else if (kind == 7): ptx_shared_f32(tree.high[id])
		else:
			ptx_barrier()
			mov_eax_int(0)
		return
	if (op == 'k'):
		int argument = tree.left[id]
		emit_expression_ast(tree, argument)
		int pointer = promote(tree.result_type[argument])
		if (target_isa != 3): coerce(tree.symbol[id], pointer)
		push_slot()
		argument = tree.next_arg[argument]
		emit_expression_ast(tree, argument)
		coerce(tree.high[id], promote(tree.result_type[argument]))
		if (tree.value[id] == 4):
			push_slot()
			argument = tree.next_arg[argument]
			emit_expression_ast(tree, argument)
			coerce(tree.high[id], promote(tree.result_type[argument]))
			mov_ecx_eax()
			pop_eax()
			pop_ebx()
			stack_pos = stack_pos - 2
			alu_atomic_cas()
		else:
			pop_ebx_slot()
			if (target_isa == 3):
				if (tree.high[id] == float32_type): ptx_atomic_add_f32()
				else: ptx_atomic_int(tree.value[id])
			else: alu_atomic_add()
		return
	if (op == 'Q'):
		int kind = tree.value[id]
		int argument = tree.left[id]
		emit_expression_ast(tree, argument)
		coerce(tree.high[id], promote(tree.result_type[argument]))
		if (kind >= 7):
			if (kind == 7): alu_popcount32()
			else if (kind == 8): alu_clz32()
			else: alu_ctz32()
			return
		push_slot()
		argument = tree.next_arg[argument]
		emit_expression_ast(tree, argument)
		coerce(tree.high[id], promote(tree.result_type[argument]))
		if ((kind == 2) || (kind == 3)):
			push_slot()
			argument = tree.next_arg[argument]
			emit_expression_ast(tree, argument)
			coerce(tree.symbol[id], promote(tree.result_type[argument]))
			mov_ecx_eax()
			pop_eax()
			pop_ebx()
			stack_pos = stack_pos - 2
			if (kind == 2): alu_mul_wide()
			else: alu_add_carry()
		else:
			pop_ebx_slot()
			if (kind == 1): alu_mul_hi()
			else if (kind == 4): alu_shr32()
			else if (kind == 5): alu_rotl32()
			else: alu_rotr32()
		return
	if (op == 'W'):
		int s = stack_pos
		int argument = tree.left[id]
		while (argument >= 0):
			emit_expression_ast(tree, argument)
			int got = promote(tree.result_type[argument])
			if (tree.infer_coercion[argument] == 1): coerce(tree.infer_want[argument], got)
			if (tree.infer_coercion[argument] == 2): coerce_call_argument(tree.infer_want[argument], got)
			push_call_argument(got)
			argument = tree.next_arg[argument]
		int sym = tree.symbol[id]
		if (sym >= 0):
			int[8] types
			int count = generic_def_param_count(tree.value[id])
			argument = tree.right[id]
			for i in range(count):
				types[i] = tree.value[argument]
				argument = tree.next_arg[argument]
			char* name = generic_mangle(generic_def_name(tree.value[id]), cast(int, &types[0]), count)
			sym_emit_value(sym, name)
			free(name)
		else: generic_inst_emit_callee(tree.generic_instance[id])
		call_eax()
		pop_to(s)
		last_call_return_type = tree.high[id]
		last_call_end = codepos
		return
	if (op == 'G'):
		int sym = tree.symbol[id]
		int signature = tree.generic_signature[id]
		if (sym >= 0):
			# The symbol table has a stable name immediately before its
			# record, but queued instances already retain their mangling.
			int count = generic_def_param_count(tree.value[id])
			int[8] types
			int argument = tree.right[id]
			for i in range(count):
				types[i] = tree.value[argument]
				argument = tree.next_arg[argument]
			char* name = generic_mangle(generic_def_name(tree.value[id]), cast(int, &types[0]), count)
			strcpy(last_identifier, name)
			sym_emit_value(sym, name)
			free(name)
		else: generic_inst_emit_callee(tree.generic_instance[id])
		int result = tree.high[id]
		int has_return_buffer = emit_ast_return_buffer(result)
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
			int want = -1
			if (sym >= 0): want = sym_param_type(sym, count)
			else: want = type_function_param_type(signature, count)
			if (want >= 0): coerce_call_argument(want, got)
			push_call_argument_compact(got, stack_pos - arg_stack)
			count = count + 1
			arg = tree.next_arg[arg]
		finish_call(4, s, count, sym, 0, result, count, has_return_buffer, -1)
		return
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
	if ((op == ast_nd_index) || (op == ast_nd_store) || (op == ast_nd_read)):
		int index = id
		if (op == ast_nd_store): index = tree.left[id]
		int receiver = tree.left[index]
		emit_expression_ast(tree, receiver)
		binary1(tree.result_type[receiver])
		int* park = park_new(stack_pos - 1, tree.high[index] + 1)
		park[2] = stack_pos
		int arg = tree.right[index]
		int i = 3
		while (arg >= 0):
			emit_expression_ast(tree, arg)
			int got = promote(tree.result_type[arg])
			coerce(type_lookup(c"int"), got)
			park[i] = push_slot()
			i = i + 1
			arg = tree.next_arg[arg]
		char* get_name = ndarray_accessor_name_for(tree.value[index], tree.high[index], c"_at")
		sym_lookup(get_name)
		if (op == ast_nd_store):
			expression_is_assignment = 1
			char* set_name = ndarray_accessor_name_for(tree.value[index], tree.high[index], c"_set")
			sym_lookup(set_name)
			int subop = tree.value[id]
			if (subop):
				park_call(park, get_name, 0)
				push_slot()
			int right = tree.right[id]
			emit_expression_ast(tree, right)
			int got = promote(tree.result_type[right])
			if (subop): got = compound_assign_apply(subop, tree.result_type[index], got)
			coerce(tree.high[id], got)
			int value_slot = push_slot()
			park_store(park, set_name, value_slot, tree.high[id])
			free(set_name)
		else: park_load(park, get_name)
		free(get_name)
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
	if (op == 'O'):
		int type = tree.value[id]
		int list = type_is_list(type)
		int map = type_is_map(type)
		if (list): list_emit_new_container(type)
		else: hash_emit_new_container(type)
		int container_slot = push_slot()
		int entry = tree.left[id]
		while (entry >= 0):
			int base_stack = stack_pos
			int first = tree.left[entry]
			emit_expression_ast(tree, first)
			int got = promote(tree.result_type[first])
			int want = type_set_key_type(type)
			if (list): want = type_list_element_type(type)
			if (map): want = type_map_key_type(type)
			coerce(want, got)
			int first_slot = push_slot()
			if (map):
				int second = tree.right[entry]
				emit_expression_ast(tree, second)
				got = promote(tree.result_type[second])
				coerce(type_map_value_type(type), got)
				int second_slot = push_slot()
				hash_literal_call_map_set(container_slot, first_slot, second_slot, tree.value[entry])
			else if (list):
				char* helper = c"__w_list_push"
				if (tree.value[entry]): helper = c"__w_list_push_bytes"
				int s = rt_call_begin(helper)
				push_slot_copy(container_slot)
				push_slot_copy(first_slot)
				rt_call_end(s)
			else: hash_literal_call_set_add(container_slot, first_slot)
			pop_to(base_stack)
			entry = tree.next_arg[entry]
		pop_eax_slot()
		return
	if (op == 'V'):
		int type = tree.value[id]
		if (type_is_list(type)): list_emit_new_container(type)
		else: hash_emit_new_container(type)
		if (tree.high[id]):
			int base_stack = stack_pos
			int map_slot = push_slot()
			if (tree.high[id] == 3): mov_eax_int(tree.symbol[id])
			else:
				int argument = tree.left[id]
				emit_expression_ast(tree, argument)
				int got = promote(tree.result_type[argument])
				if (tree.high[id] == 1): coerce(type_map_value_type(type), got)
			int value_slot = push_slot()
			int s = rt_call_begin(c"__w_map_set_default")
			push_slot_copy(map_slot)
			push_slot_int(tree.high[id])
			push_slot_copy(value_slot)
			rt_call_end(s)
			load_slot(map_slot)
			pop_to(base_stack)
		return
	if (op == 'Y'):
		int length = tree.left[id]
		emit_expression_ast(tree, length)
		promote(tree.result_type[length])
		int element_size = type_get_size(tree.value[id])
		if (bounds_mode != 0):
			int alloc_limit = 1073741823 / element_size
			int h_in_bounds = be_ctrl_block()
			int h_trap = be_ctrl_block()
			be_bounds_branch(BOUNDS_EAX_NEG, 0, h_trap)
			be_bounds_branch(BOUNDS_EAX_LE_LIMIT, alloc_limit, h_in_bounds)
			be_ctrl_end(h_trap)
			push_eax()
			mov_eax_int(alloc_limit)
			pop_ebx()
			bounds_trap_call(c"__w_alloc_trap")
			be_ctrl_end(h_in_bounds)
		push_slot()
		sym_get_value(c"malloc")
		push_slot()
		mov_eax_esp_plus(word_size)
		if (element_size > 1): imul_eax_int32(element_size)
		add_eax_int32(2 * word_size)
		push_slot()
		mov_eax_esp_plus(word_size)
		call_eax()
		drop_slots(2)
		push_slot()
		add_eax_int32(2 * word_size)
		mov_ebx_esp()
		store_ebx_word()
		mov_eax_esp_plus(word_size)
		mov_ebx_esp()
		add_ebx_int32(word_size)
		store_ebx_word()
		mov_eax_esp_plus(word_size)
		if (element_size > 1): imul_eax_int32(element_size)
		push_slot()
		mov_eax_esp_plus(word_size)
		add_eax_int32(2 * word_size)
		push_slot()
		zero_stack_count_bytes()
		drop_slots(2)
		pop_eax_slot()
		drop_slots(1)
		return
	if (op == 'D'):
		int base = tree.value[id]
		int heap = tree.high[id]
		if (heap):
			sym_get_value(c"malloc")
			push_slot()
			push_slot_int(type_get_size(base))
			mov_eax_esp_plus(word_size)
			call_eax()
			drop_slots(2)
		else:
			int words = (type_get_size(base) + word_size - 1) >> word_size_log2
			for j in range(words): push_eax()
			stack_pos = stack_pos + words
			lea_eax_esp_plus(0)
		if (type_has_array_field(base)):
			zero_runtime_object(type_get_size(base))
			init_array_field_descriptors(base)
		if ((heap == 0) || (tree.left[id] >= 0)):
			push_slot()
			int entry_stack = stack_pos
			if (tree.symbol[id]): zero_runtime_object(type_get_size(base))
			int entry = tree.left[id]
			while (entry >= 0):
				int argument = tree.left[entry]
				emit_expression_ast(tree, argument)
				int got = promote(tree.result_type[argument])
				new_store_field(base, tree.value[entry], got, stack_pos - entry_stack)
				if (stack_pos > entry_stack): pop_to(entry_stack)
				entry = tree.next_arg[entry]
			pop_eax_slot()
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
	if ((op == 'x') && (tree.value[id] >= 2)):
		int kind = tree.value[id]
		int descriptor = 0
		if (kind != 2): descriptor = protobuf_descriptor(tree.high[id])
		if (kind == 5):
			mov_eax_int(descriptor)
			return
		int base_stack = stack_pos
		int arg = tree.left[id]
		emit_expression_ast(tree, arg)
		promote(tree.result_type[arg])
		if (kind == 2): base_stack = stack_pos
		int arg_slot = push_slot()
		char* helper = c"pb_from_bytes"
		int count = 1
		if (kind == 2):
			descriptor = protobuf_descriptor(tree.high[id])
			helper = c"pb_to_bytes"
		if (kind == 4):
			int length = tree.right[id]
			emit_expression_ast(tree, length)
			promote(tree.result_type[length])
			push_slot()
			helper = c"pb_from_data"
			count = 2
		protobuf_emit_call(helper, descriptor, arg_slot, count)
		pop_to(base_stack)
		return
	if (op == 'x'):
		int descriptor = 0
		if (tree.value[id]): descriptor = json_codec_descriptor(tree.high[id])
		int arg = tree.left[id]
		emit_expression_ast(tree, arg)
		promote(tree.result_type[arg])
		int base_stack = stack_pos
		int arg_slot = push_slot()
		if (tree.value[id] == 0): descriptor = json_codec_descriptor(tree.high[id])
		json_codec_emit_call(tree.value[id], descriptor, arg_slot)
		pop_to(base_stack)
		return
	if (op == 'y'):
		int base_stack = stack_pos
		int helper = tree.value[id]
		int arg = tree.left[id]
		if ((helper == 20) || (helper == 21)):
			emit_expression_ast(tree, arg)
			promote(tree.result_type[arg])
			if (helper == 20): prelude_emit_enum_name(tree.high[id], base_stack)
			else if (tree.high[id]):
				push_slot()
				print_emit_call1(12, stack_pos)
				pop_to(base_stack)
			else:
				add_eax_int32(word_size)
				promote_eax()
			return
		print_emit_helper_address(helper)
		push_slot()
		while (arg >= 0):
			emit_expression_ast(tree, arg)
			promote(tree.result_type[arg])
			push_slot()
			if ((helper == 18) && (arg == tree.left[id])):
				push_slot_int(tree.high[id])
				if (tree.next_arg[arg] < 0): push_slot_int(0)
			arg = tree.next_arg[arg]
		if (helper == 19): push_slot_int(tree.high[id])
		rt_call_end(base_stack)
		return
	if (op == 'P'):
		int base_stack = stack_pos
		int arg = tree.left[id]
		if (arg >= 0):
			emit_expression_ast(tree, arg)
			int got = promote(tree.result_type[arg])
			if (type_is_var(type_unqualified(got))): var_emit_to_cstr()
			int value_slot = push_slot()
			if (tree.high[id] == 4): print_emit_call_list(value_slot, tree.symbol[id])
			else: print_emit_call1(tree.high[id], value_slot)
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
	if (op == 'z'):
		int receiver = tree.right[id]
		emit_expression_ast(tree, receiver)
		if (type_num_args(type_real(tree.result_type[receiver])) == 0): promote(tree.result_type[receiver])
		int result = tree.high[id]
		int has_return_buffer = emit_ast_return_buffer(result)
		push_slot()
		int sym = tree.symbol[id]
		int s = rt_call_begin(table + tree.value[id])
		if (has_return_buffer):
			lea_eax_esp_plus(2 << word_size_log2)
			push_slot()
			mov_eax_esp_plus(2 << word_size_log2)
		else: mov_eax_esp_plus(1 << word_size_log2)
		int got = tree.call_receiver_type[id]
		coerce(sym_param_type(sym, 0), got)
		push_call_argument(got)
		int count = emit_ast_direct_arguments(tree, id, s, 1)
		finish_call(4, s, count, sym, 0, result, count, has_return_buffer, sym_w_variadic_fixed_args(sym))
		drop_slots(1)
		if (has_return_buffer): lea_eax_esp_plus(0)
		return
	if ((op == 'v') || (op == 'C') || (op == 'X')):
		char* name = table + tree.value[id]
		strcpy(last_identifier, name)
		int sym = tree.symbol[id]
		if (target_isa == 3): gpu_sym_get_value(name)
		else: sym_emit_value(sym, name)
		if (op == 'X'):
			int s = stack_pos
			push_slot()
			int arg = tree.left[id]
			int count = 0
			while (arg >= 0):
				emit_expression_ast(tree, arg)
				int got = promote(tree.result_type[arg])
				int want = sym_param_type(sym, count)
				if (want >= 0): coerce_call_argument(want, got)
				push_slot()
				count = count + 1
				arg = tree.next_arg[arg]
			sym_get_value(c"__w_gen_create")
			push_slot()
			mov_eax_esp_plus((count + 1) << word_size_log2)
			push_slot()
			lea_eax_esp_plus(2 << word_size_log2)
			push_slot()
			mov_eax_int(count)
			push_slot()
			mov_eax_esp_plus(3 << word_size_log2)
			call_eax()
			pop_to(s)
			last_call_return_type = tree.high[id]
			last_call_end = codepos
			return
		if (op == 'C'):
			int declared_return = load_int(table + sym + 6)
			if (declared_return == 4): declared_return = -1
			int c_variadic = sym_variadic_fixed_args(sym)
			if (c_variadic >= 0):
				int s = stack_pos
				char* classes = malloc(extern_max_params)
				int arg = tree.left[id]
				int count = 0
				while (arg >= 0):
					emit_expression_ast(tree, arg)
					int got = promote(tree.result_type[arg])
					classes[count] = push_c_variadic_argument(sym, table + tree.value[id], count, c_variadic, got)
					count = count + 1
					arg = tree.next_arg[arg]
				emit_ffi_call_inline(count, classes, ffi_type_class(declared_return), sym_got_vaddr(sym))
				free(classes)
				pop_to(s)
				last_call_return_type = declared_return
				last_call_end = codepos
				return
			int has_return_buffer = emit_ast_return_buffer(declared_return)
			int s = stack_pos
			push_slot()
			if (has_return_buffer):
				lea_eax_esp_plus(word_size)
				push_slot()
			int count = emit_ast_direct_arguments(tree, id, s, 0)
			finish_call(4, s, count, sym, 0, declared_return, count, has_return_buffer, sym_w_variadic_fixed_args(sym))
		return
	emit_expression_ast(tree, tree.left[id])
	int left_type = tree.result_type[tree.left[id]]
	if (op == 'U'):
		expression_is_assignment = 1
		compound_assign_scalar(tree.value[id], left_type, 1)
		return
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
			if ((((method >= 11) && (method <= 18)) || (method == 27) || (method == 28)) && (count == 0)): coerce(tree.high[id], got)
			if (((method == 15) || (method == 18)) && (count == 1)): coerce(tree.symbol[id], got)
			int slot = push_slot()
			if (count == 0): first_slot = slot
			else: second_slot = slot
			count = count + 1
			arg = tree.next_arg[arg]
		if ((method == 18) && (second_slot == 0)):
			mov_eax_int(1)
			if (type_float_kind(tree.symbol[id])): coerce(tree.symbol[id], 3)
			second_slot = push_slot()
		if ((method == 18) && type_float_kind(tree.symbol[id])):
			int s = rt_call_begin(c"__w_map_get_or")
			push_slot_copy(receiver_slot)
			push_slot_copy(first_slot)
			push_slot_int(0)
			rt_call_end(s)
			push_slot()
			load_slot(second_slot)
			pop_ebx_slot()
			int value_type = type_value(tree.symbol[id])
			float_binary_arithmetic(value_type, value_type, '+')
			int sum_slot = push_slot()
			emit_ast_map_call(c"__w_map_set", receiver_slot, first_slot, sum_slot)
			load_slot(sum_slot)
			pop_to(base_stack)
			return
		int s = rt_call_begin(ast_expression_method_helper(tree.value[id]))
		push_slot_copy(receiver_slot)
		if (first_slot): push_slot_copy(first_slot)
		if (second_slot): push_slot_copy(second_slot)
		if ((method == 16) || (method == 17)): push_slot_int(tree.high[id])
		if ((method == 20) || (method == 21) || (method == 27) || (method == 28) || (method == 32)): push_slot_int(tree.symbol[id])
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
		int decay = tree.value[id]
		if (decay == 1): promote_eax()
		else if (decay == 2): be_br(h_join)
		else if (yt != 3): coerce(yt, nt)
		be_ctrl_end(h_stub)
		if (decay == 2): promote_eax()
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
	if (op == 'J'):
		promote(left_type)
		int base_stack = stack_pos
		int list_slot = push_slot()
		int start = tree.right[id]
		if (start < 0): mov_eax_int(0)
		else:
			emit_expression_ast(tree, start)
			promote(tree.result_type[start])
		int start_slot = push_slot()
		int end = tree.high[id]
		if (end < 0): mov_eax_int(0)
		else:
			emit_expression_ast(tree, end)
			promote(tree.result_type[end])
		int end_slot = push_slot()
		int s = rt_call_begin(c"__w_list_slice")
		push_slot_copy(list_slot)
		push_slot_copy(start_slot)
		push_slot_copy(end_slot)
		push_slot_int(end >= 0)
		rt_call_end(s)
		pop_to(base_stack)
		return
	if (op == 'Z'):
		promote(left_type)
		push_slot()
		int start = tree.right[id]
		if (start < 0): mov_eax_int(0)
		else:
			emit_expression_ast(tree, start)
			promote(tree.result_type[start])
		push_slot()
		int end = tree.high[id]
		if (end < 0):
			mov_eax_esp_plus(word_size)
			add_eax_int32(word_size)
			promote_eax()
		else:
			emit_expression_ast(tree, end)
			promote(tree.result_type[end])
		push_slot()
		buffer_range_bounds_check()
		buffer_push_range_descriptor(left_type, start < 0)
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
	int left_slot = stack_pos
	emit_expression_ast(tree, tree.right[id])
	int right_type = promote(tree.result_type[tree.right[id]])
	if (op == 'l'):
		operator_emit_binary(left_type, right_type, left_slot, tree.symbol[id], strclone(table + tree.value[id]))
		return
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
		if ((op == 0x94) || (op == 0x95)): result = var_binary_compare_eq(left_type, right_type, op == 0x95)
		else: result = var_binary_compare_order(left_type, right_type, op)
		if ((result == 0) && ((op == 0x94) || (op == 0x95))): result = string_binary_compare_eq(left_type, right_type, op == 0x95)
		if (result == 0): result = float_binary_compare(left_type, right_type, cc, swap)
		if (result == 0): alu_cmp_set(op)
		return
	if (var_binary_operands(left_type, right_type)):
		pop_ebx_slot()
		var_binary_arithmetic(left_type, right_type, op)
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
