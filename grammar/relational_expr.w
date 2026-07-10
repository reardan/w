/*
 * relational-expr:
 *         shift-expr
 *         relational-expr <= shift-expr
 *         relational-expr < shift-expr
 *         relational-expr >= shift-expr
 *         relational-expr > shift-expr
 *
 * Chains left-associatively, so a < b < c means (a < b) < c.
 */

# Shared lowering for one ordered comparison: cc doubles as the setcc byte
# for the var layer's __w_var_cmp result and for the integer ALU fallback;
# the float layer takes its own setcc plus an operand swap (< and <= are
# emitted as the swapped > and >= so unordered compares stay false).
int relational_op(int type, int cc, int float_cc, int float_swap):
	int left_type = binary1(type)
	int right_type = binary2_promote_pop(shift_expr())
	int result_type = var_binary_compare_order(left_type, right_type, cc)
	if (result_type == 0):
		result_type = float_binary_compare(left_type, right_type, float_cc, float_swap)
	if (result_type):
		return result_type
	alu_cmp_set(cc)
	return type_value(bool_type)


int relational_expr():
	int type = shift_expr()
	while (1):
		if(accept(c"<=")):
			type = relational_op(type, 0x9e, 0x93, 1)

		else if(accept(c"<")):
			type = relational_op(type, 0x9c, 0x97, 1)

		else if(accept(c">=")):
			type = relational_op(type, 0x9d, 0x93, 0)

		else if(accept(c">")):
			type = relational_op(type, 0x9f, 0x97, 0)

		else if(accept(c"in")):
			int key_type = binary1(type)
			int key_slot = stack_pos
			int base_stack = key_slot - 1
			int container_type = shift_expr()
			container_type = promote(container_type)
			container_type = type_unqualified(container_type)
			int want_key_type = -1
			char* contains_name = c"__w_set_contains"
			if (type_is_map(container_type)):
				want_key_type = type_map_key_type(container_type)
				contains_name = c"__w_map_contains"
			else if (type_is_set(container_type)):
				want_key_type = type_set_key_type(container_type)
			else if (type_is_list(container_type)):
				want_key_type = type_list_element_type(container_type)
				if ((type_num_args(want_key_type) > 0) | type_is_string(want_key_type)):
					error(c"'in' on a list requires scalar or char* elements")
				# char* elements compare by contents, like map/set keys
				if (hash_key_kind_for_type(want_key_type) == 2):
					contains_name = c"__w_list_contains_cstr"
				else:
					contains_name = c"__w_list_contains"
			else:
				error(c"right operand of 'in' must be a map, set, or list")
			if (types_compatible_with_expression(want_key_type, key_type) == 0):
				warn_type_mismatch(c"membership key", want_key_type, key_type)
			if (type_decays_to_pointer(want_key_type, key_type)):
				# The key was pushed before the container's key type was
				# known: decay the descriptor address in its slot to the
				# data pointer. eax (the container) is saved around it.
				push_eax()
				stack_pos = stack_pos + 1
				mov_eax_esp_plus((stack_pos - key_slot) << word_size_log2)
				promote_eax()
				store_stack_var((stack_pos - key_slot) << word_size_log2)
				pop_eax()
				stack_pos = stack_pos - 1
			push_eax()
			stack_pos = stack_pos + 1
			int container_slot = stack_pos
			sym_get_value(contains_name)
			int s = stack_pos
			push_eax()
			stack_pos = stack_pos + 1
			hash_push_stack_slot(container_slot)
			hash_push_stack_slot(key_slot)
			hash_call_finish(s)
			be_pop(stack_pos - base_stack)
			stack_pos = base_stack
			type = type_value(bool_type)

		else:
			return type
