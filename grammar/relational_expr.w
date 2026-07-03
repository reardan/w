

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
	
		else:
			return type
