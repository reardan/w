/*
 * logical-or-expr:
 *         logical-and-expr
 *         logical-or-expr || logical-and-expr
 */
# Condition context (grammar/cond_branch.w): each &&-chain operand is
# consumed with a branch to the true region when it holds; the last
# one stays pending, and the chain's own region joins its pending set.
int logical_or_cond():
	int base = ctrl_stack_pos
	int h = be_ctrl_block_tagged(2)
	int type = logical_and_expr()
	int result = type
	while (accept(c"||")):
		cond_branch_consume(h, 1)
		cond_discard_arm()
		type = logical_and_expr()
		result = type_value(bool_type)
	if (cond_pending == 0): error(c"internal error: condition chain operand left nothing pending")
	cond_pending_base = base
	return result


int logical_or_expr():
	if (cond_discard_match()): return logical_or_cond()
	int type = logical_and_expr()
	if (peek(c"||") == 0):
		return type

	# Short-circuit: a nonzero operand jumps to the booleanize step.
	# Must stay be_br_nonzero, not the _discard twin: the taken edge
	# carries the operand value in eax to the alu_test_set below.
	promote(type)
	int h = be_ctrl_block()
	while (accept(c"||")):
		be_br_nonzero(h)
		promote(logical_and_expr())

	be_ctrl_end(h)
	alu_test_set(0x95) /* setne */
	return type_value(bool_type)
