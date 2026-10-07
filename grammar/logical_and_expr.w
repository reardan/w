/*
 * logical-and-expr:
 *         bitwise-or-expr
 *         logical-and-expr && bitwise-or-expr
 */
# Condition context (grammar/cond_branch.w): every operand branches on
# its own flags to the chain's false region, nothing is booleanized,
# and the chain is left pending for the if/while/?:/! that consumes it.
# The region is opened before the first operand so a parenthesized
# sub-chain's regions nest above it.
int logical_and_cond():
	int base = ctrl_stack_pos
	int h = be_ctrl_block_tagged(1)
	int type = bitwise_or_expr()
	int result = type
	while (accept(c"&&")):
		cond_operand_branch(type, h, 0)
		cond_discard_arm()
		type = bitwise_or_expr()
		result = type_value(bool_type)
	cond_chain_finish(base, type)
	return result


int logical_and_expr():
	if (cond_discard_match()): return logical_and_cond()
	int type = bitwise_or_expr()
	if (peek(c"&&") == 0):
		return type

	# Short-circuit: a zero operand jumps to the booleanize step with eax=0.
	# Must stay be_br_zero, not the _discard twin: the taken edge carries
	# the operand value in eax to the alu_test_set below.
	promote(type)
	int h = be_ctrl_block()
	while (accept(c"&&")):
		be_br_zero(h)
		promote(bitwise_or_expr())

	be_ctrl_end(h)
	alu_test_set(0x95) /* setne */
	return type_value(bool_type)
