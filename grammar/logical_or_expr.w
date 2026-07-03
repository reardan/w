/*
 * logical-or-expr:
 *         logical-and-expr
 *         logical-or-expr || logical-and-expr
 */
int logical_or_expr():
	int type = logical_and_expr()
	if (peek("||") == 0):
		return type

	# Short-circuit: a nonzero operand jumps to the booleanize step
	promote(type)
	int chain = 0
	while (accept("||")):
		jmp_nonzero_int32(chain)
		chain = codepos
		promote(logical_and_expr())

	int booleanize_target = codepos
	alu_test_set(0x95) /* setne */
	patch_jump_chain(chain, booleanize_target)
	return type_value(bool_type)
