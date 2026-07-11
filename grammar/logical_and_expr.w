/*
 * logical-and-expr:
 *         bitwise-or-expr
 *         logical-and-expr && bitwise-or-expr
 */
int logical_and_expr():
	int type = bitwise_or_expr()
	if (peek(c"&&") == 0):
		return type

	# Short-circuit: a zero operand jumps to the booleanize step with eax=0
	promote(type)
	int h = be_ctrl_block()
	while (accept(c"&&")):
		be_br_zero(h)
		promote(bitwise_or_expr())

	be_ctrl_end(h)
	alu_test_set(0x95) /* setne */
	return type_value(bool_type)
