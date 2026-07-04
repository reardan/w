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
			binary1(type)
			type = binary2_finish(additive_expr())
			alu_shl()

		else if (accept(c">>")):
			binary1(type)
			type = binary2_finish(additive_expr())
			alu_sar()

		else:
			return type
