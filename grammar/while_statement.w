void statement();

# Innermost loop context for break/continue: control-region handles
# (be_ctrl_block/be_ctrl_loop in code_generator/x86.w) that break and
# continue branch to with be_br. Each loop saves the outer values in locals
# and restores them, so nesting works through recursion.
int loop_break_chain
int loop_continue_chain
int loop_stack_pos
int loop_depth

# Innermost switch context (grammar/switch_statement.w), mirroring the
# loop globals: 'break' inside a switch exits the switch. break_in_switch
# says whether the innermost breakable construct is a switch (1) or a
# loop (0); loops reset it to 0, switches set it to 1, and both
# save/restore the outer value around their bodies. 'continue' is not
# affected: it always targets the enclosing loop.
int switch_break_chain
int switch_stack_pos
int switch_depth
int break_in_switch

# Indent level of the statement owning the next ':' block; used to detect
# empty blocks and terminate them correctly.
int enclosing_tab_level


# Enter a loop context for break/continue: saves the outer context
# (returned for loop_leave) and opens the exit region that the failed
# condition and 'break' land after. The caller opens the loop region and
# sets loop_continue_chain.
int* loop_enter():
	int* outer = cast(int*, malloc(4 * __word_size__))
	outer[0] = loop_break_chain
	outer[1] = loop_continue_chain
	outer[2] = loop_stack_pos
	outer[3] = break_in_switch
	loop_break_chain = be_ctrl_block()
	loop_stack_pos = stack_pos
	break_in_switch = 0
	loop_depth = loop_depth + 1
	return outer


void loop_leave(int* outer):
	loop_break_chain = outer[0]
	loop_continue_chain = outer[1]
	loop_stack_pos = outer[2]
	break_in_switch = outer[3]
	loop_depth = loop_depth - 1
	free(outer)


# while ( expression ) statement — parentheses are optional before ':'
int while_statement():
	if (accept(c"while") == 0):
		return 0

	int while_tab_level = tab_level
	int* outer = loop_enter()
	# Loop region: the back edge and 'continue' re-test the condition.
	loop_continue_chain = be_ctrl_loop()

	# if not expression: leave the loop
	int outer_condition = condition_context
	condition_context = 1
	lint_condition_begin()
	promote(expression())
	lint_condition_end()
	condition_context = outer_condition
	be_br_zero_discard(loop_break_chain)

	enclosing_tab_level = while_tab_level
	statement()

	# loop
	be_br(loop_continue_chain)
	be_ctrl_end(loop_continue_chain)
	be_ctrl_end(loop_break_chain)

	loop_leave(outer)

	return 1
