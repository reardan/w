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

	/* booleanize: test %eax,%eax ; setne %al ; movzbl %al,%eax */
	emit(8, "\x85\xc0\x0f\x95\xc0\x0f\xb6\xc0")
	patch_jump_chain(chain, codepos - 8)
	return 3
