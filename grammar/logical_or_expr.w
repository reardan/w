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

	/* booleanize: test %eax,%eax ; setne %al ; movzbl %al,%eax */
	emit(8, "\x85\xc0\x0f\x95\xc0\x0f\xb6\xc0")
	patch_jump_chain(chain, codepos - 8)
	return 3
