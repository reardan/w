/*
 * shift-expr:
 *         additive-expr
 *         shift-expr << additive-expr
 *         shift-expr >> additive-expr
 */
int shift_expr():
	int type = additive_expr()
	while (1):
		if (accept(c"<<")):
			int left_type = binary1(type)
			int right_type = additive_expr()
			if (var_binary_operands(left_type, right_type)):
				error(c"var operands do not support <<")
			type = binary2_finish(right_type)
			alu_shl()

		else if (accept(c">>")):
			int left_type = binary1(type)
			int right_type = additive_expr()
			if (var_binary_operands(left_type, right_type)):
				error(c"var operands do not support >>")
			type = binary2_finish(right_type)
			alu_sar()

		else:
			return type
