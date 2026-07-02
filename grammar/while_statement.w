void statement();

# Innermost loop context for break/continue backpatching.
# Each loop saves the outer values in locals and restores them, so nesting
# works through recursion.
int loop_break_chain
int loop_continue_chain
int loop_stack_pos
int loop_depth

# Indent level of the statement owning the next ':' block; used to detect
# empty blocks and terminate them correctly.
int enclosing_tab_level


# Walk a chain of jmp sites (each displacement slot holds the previous
# site's codepos, 0 ends the chain) and point them all at target.
void patch_jump_chain(int chain, int target):
	while (chain):
		int next_site = load_int32(code + chain - 4)
		save_int32(code + chain - 4, target - chain)
		chain = next_site


# while ( expression ) statement — parentheses are optional before ':'
int while_statement():
	int p1
	int p2
	if (accept("while") == 0):
		return 0

	int while_tab_level = tab_level
	int outer_break = loop_break_chain
	int outer_continue = loop_continue_chain
	int outer_stack = loop_stack_pos
	loop_break_chain = 0
	loop_continue_chain = 0
	loop_stack_pos = stack_pos
	loop_depth = loop_depth + 1

	# if not expression: jmp after statement block
	p1 = codepos
	promote(expression())
	jmp_zero_int32(1337008)
	p2 = codepos

	enclosing_tab_level = while_tab_level
	statement()

	# loop
	jmp_int32(1337009)

	# backtrace: save jmp out, loop jmp addresses
	save_int32(code + codepos - 4, p1 - codepos)
	save_int32(code + p2 - 4, codepos - p2)

	# break exits here; continue re-tests the condition
	patch_jump_chain(loop_break_chain, codepos)
	patch_jump_chain(loop_continue_chain, p1)

	loop_break_chain = outer_break
	loop_continue_chain = outer_continue
	loop_stack_pos = outer_stack
	loop_depth = loop_depth - 1

	return 1
