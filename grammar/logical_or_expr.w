/*
 * logical-or-expr:
 *         logical-and-expr
 *         logical-or-expr || logical-and-expr
 */
int logical_or_expr():
	int type = logical_and_expr()
	if (peek(c"||") == 0):
		return type

	# Short-circuit: a nonzero operand jumps to the booleanize step
	promote(type)
	int h = be_ctrl_block()
	while (accept(c"||")):
		be_br_nonzero(h)
		promote(logical_and_expr())

	be_ctrl_end(h)
	alu_test_set(0x95) /* setne */
	return type_value(bool_type)
