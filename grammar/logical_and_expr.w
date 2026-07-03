void patch_jump_chain(int chain, int target);

/*
 * logical-and-expr:
 *         bitwise-or-expr
 *         logical-and-expr && bitwise-or-expr
 */
int logical_and_expr():
	int type = bitwise_or_expr()
	if (peek("&&") == 0):
		return type

	# Short-circuit: a zero operand jumps to the booleanize step with eax=0
	promote(type)
	int chain = 0
	while (accept("&&")):
		jmp_zero_int32(chain)
		chain = codepos
		promote(bitwise_or_expr())

	int booleanize_target = codepos
	alu_test_set(0x95) /* setne */
	patch_jump_chain(chain, booleanize_target)
	return 3
