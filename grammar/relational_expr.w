

int generate_relational_code(int type, int setcc_opcode):
	int left_type = binary1(type)
	int right_type = binary2_promote_pop(shift_expr())
	int result_type = float_binary_compare(left_type, right_type, setcc_opcode, 0)
	if (result_type):
		return result_type
	alu_cmp_set(setcc_opcode)
	return type_value(bool_type)


int generate_float_swapped_relational_code(int type, int setcc_opcode):
	int left_type = binary1(type)
	int right_type = binary2_promote_pop(shift_expr())
	int result_type = float_binary_compare(left_type, right_type, setcc_opcode, 1)
	if (result_type):
		return result_type
	# Integer fallback uses the original signed condition on left/right.
	alu_cmp_set(0x9c)
	return type_value(bool_type)


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
		if(accept("<=")):
			int left_type = binary1(type)
			int right_type = binary2_promote_pop(shift_expr())
			int result_type = float_binary_compare(left_type, right_type, 0x93, 1)
			if (result_type):
				type = result_type
			else:
				alu_cmp_set(0x9e)
				type = type_value(bool_type)

		else if(accept("<")):
			int left_type = binary1(type)
			int right_type = binary2_promote_pop(shift_expr())
			int result_type = float_binary_compare(left_type, right_type, 0x97, 1)
			if (result_type):
				type = result_type
			else:
				alu_cmp_set(0x9c)
				type = type_value(bool_type)

		else if(accept(">=")):
			int left_type = binary1(type)
			int right_type = binary2_promote_pop(shift_expr())
			int result_type = float_binary_compare(left_type, right_type, 0x93, 0)
			if (result_type):
				type = result_type
			else:
				alu_cmp_set(0x9d)
				type = type_value(bool_type)

		else if(accept(">")):
			int left_type = binary1(type)
			int right_type = binary2_promote_pop(shift_expr())
			int result_type = float_binary_compare(left_type, right_type, 0x97, 0)
			if (result_type):
				type = result_type
			else:
				alu_cmp_set(0x9f)
				type = type_value(bool_type)

		else if(accept("in")):
			int key_type = binary1(type)
			int key_slot = stack_pos
			int base_stack = key_slot - 1
			int container_type = shift_expr()
			container_type = promote(container_type)
			container_type = type_unqualified(container_type)
			int want_key_type = -1
			char* contains_name = "__w_set_contains"
			if (type_is_map(container_type)):
				want_key_type = type_map_key_type(container_type)
				contains_name = "__w_map_contains"
			else if (type_is_set(container_type)):
				want_key_type = type_set_key_type(container_type)
			else:
				error("right operand of 'in' must be a map or set")
			if (types_compatible_with_expression(want_key_type, key_type) == 0):
				warn_type_mismatch("membership key", want_key_type, key_type)
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
