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
int relational_expr():
	int type = shift_expr()
	while (1):
		if(accept(c"<=")):
			int left_type = binary1(type)
			int right_type = binary2_promote_pop(shift_expr())
			int result_type = var_binary_compare_order(left_type, right_type, 0x9e)
			if (result_type == 0):
				result_type = float_binary_compare(left_type, right_type, 0x93, 1)
			if (result_type):
				type = result_type
			else:
				alu_cmp_set(0x9e)
				type = type_value(bool_type)

		else if(accept(c"<")):
			int left_type = binary1(type)
			int right_type = binary2_promote_pop(shift_expr())
			int result_type = var_binary_compare_order(left_type, right_type, 0x9c)
			if (result_type == 0):
				result_type = float_binary_compare(left_type, right_type, 0x97, 1)
			if (result_type):
				type = result_type
			else:
				alu_cmp_set(0x9c)
				type = type_value(bool_type)

		else if(accept(c">=")):
			int left_type = binary1(type)
			int right_type = binary2_promote_pop(shift_expr())
			int result_type = var_binary_compare_order(left_type, right_type, 0x9d)
			if (result_type == 0):
				result_type = float_binary_compare(left_type, right_type, 0x93, 0)
			if (result_type):
				type = result_type
			else:
				alu_cmp_set(0x9d)
				type = type_value(bool_type)

		else if(accept(c">")):
			int left_type = binary1(type)
			int right_type = binary2_promote_pop(shift_expr())
			int result_type = var_binary_compare_order(left_type, right_type, 0x9f)
			if (result_type == 0):
				result_type = float_binary_compare(left_type, right_type, 0x97, 0)
			if (result_type):
				type = result_type
			else:
				alu_cmp_set(0x9f)
				type = type_value(bool_type)

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
