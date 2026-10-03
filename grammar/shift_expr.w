# A shift's result has its left operand's type (C: the promoted left
# operand), so only that side decides signedness.
int shift_result_type(int left_type):
	if (type_is_unsigned_word(left_type)): return type_value(type_unqualified(left_type))
	return 3


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
			type = shift_result_type(left_type)

		else if (accept(c">>")):
			int left_type = binary1(type)
			int right_type = additive_expr()
			if (var_binary_operands(left_type, right_type)):
				error(c"var operands do not support >>")
			type = binary2_finish(right_type)
			# An unsigned word left operand shifts logically
			if (type_is_unsigned_word(left_type)): alu_shr()
			else: alu_sar()
			type = shift_result_type(left_type)

		else:
			return type
