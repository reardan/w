/*
 * equality-expr:
 *         relational-expr
 *         equality-expr == relational-expr
 *         equality-expr != relational-expr
 */
int equality_expr():
	int type = relational_expr()
	while (1):
		if (accept(c"==")):
			int left_type = binary1(type)
			int right_type = binary2_promote_pop(relational_expr())
			int result_type = float_binary_compare(left_type, right_type, 0x94, 0)
			if (result_type):
				type = result_type
			else:
				alu_cmp_set(0x94) /* sete */
				type = type_value(bool_type)

		else if (accept(c"!=")):
			int left_type = binary1(type)
			int right_type = binary2_promote_pop(relational_expr())
			int result_type = float_binary_compare(left_type, right_type, 0x95, 0)
			if (result_type):
				type = result_type
			else:
				alu_cmp_set(0x95) /* setne */
				type = type_value(bool_type)

		else:
			return type

