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

# File offset of the first token of the statement being parsed
# (grammar/statement.w sets it on entry): for a loop statement, its
# keyword, which is how loop_enter finds the loop's pre-scan record
# (compiler/regalloc_scan.w, R3). Both the streaming loops and the
# retained-AST walk reach loop_enter before the body's first statement
# moves it.
int loop_stmt_offset


# Enter a loop context for break/continue: saves the outer context
# (returned for loop_leave) and opens the exit region that the failed
# condition and 'break' land after. The caller opens the loop region and
# sets loop_continue_chain. Loop-scoped registers (R3) are loaded here,
# ahead of the loop region, and written back in loop_leave, after the
# exit region every exit edge lands on.
int* loop_enter():
	int* outer = cast(int*, malloc(5 * __word_size__))
	outer[0] = loop_break_chain
	outer[1] = loop_continue_chain
	outer[2] = loop_stack_pos
	outer[3] = break_in_switch
	outer[4] = flow_loop_break
	flow_loop_break = 0
	regalloc_loop_enter(loop_stmt_offset)
	loop_break_chain = be_ctrl_block()
	loop_stack_pos = stack_pos
	break_in_switch = 0
	loop_depth = loop_depth + 1
	return outer


void loop_leave(int* outer):
	regalloc_loop_leave()
	loop_break_chain = outer[0]
	loop_continue_chain = outer[1]
	loop_stack_pos = outer[2]
	break_in_switch = outer[3]
	flow_loop_break = outer[4]
	loop_depth = loop_depth - 1
	free(outer)


void ast_statement_guard(int target, int outer_condition, int on_true);


# The caller opens control regions and installs the condition context.
# Source/lint completion precedes the branch in both compilation modes.
# The branch to target is taken when the condition is false (on_true
# 0: an if, a top-tested while) or true (1: the bottom test of a
# rotated while, grammar/loop_rotate.w).
void statement_guard(int target, int outer_condition, int on_true):
	int flow_state = flow_condition_begin()
	if (ast_expressions_mode >= 2):
		ast_statement_guard(target, outer_condition, on_true)
		flow_condition_end(flow_state)
		return
	lint_condition_begin()
	# The condition is in discard position (grammar/cond_branch.w): a
	# chain branches per operand and is consumed below
	cond_discard_arm()
	int type = expression()
	cond_discard_clear()
	if (cond_pending == 0): promote(type)
	flow_condition_end(flow_state)
	lint_condition_end()
	condition_context = outer_condition
	cond_branch_consume(target, on_true)


# while ( expression ) statement — parentheses are optional before ':'
int ast_while_statement();


# The rotated while loop's shape is documented in grammar/loop_rotate.w;
# the top-tested shape below it is what --no-loop-rotate, the
# structured-control ISAs and a declined condition skip emit.
int while_statement():
	if (ast_expressions_mode >= 2): return ast_while_statement()
	if (accept(c"while") == 0): return 0

	int while_tab_level = tab_level
	int outer_condition = condition_context
	int* outer = loop_enter()

	# Rotation: skip the condition to the body, remembering where it
	# starts; a declined skip returns to it and takes the top-tested path
	tokenizer_snapshot cond_mark
	char* cond_text = 0
	int rotate = 0
	if (loop_rotate_on()):
		cond_text = loop_rotate_mark(&cond_mark)
		rotate = loop_rotate_skip_condition()
		if (rotate == 0):
			loop_rotate_return(&cond_mark, cond_text)
			cond_text = 0
	int entry = -1
	if (rotate): entry = be_loop_entry()

	# Loop region: the back edge lands here -- on the condition when it
	# is top-tested, on the body when it is at the bottom. P1 names the
	# loop by the current token's line: the condition's first token,
	# where the retained walk's begin phase stands, not the block opener
	# the skip stopped at.
	int opener_line = diag_token_line
	if (rotate): diag_token_line = cond_mark.diag_token_line
	profile_use_loop_align()   # P2: --profile-use pads a hot head to 16 bytes
	int h_top = be_ctrl_loop()
	profile_loop_head()   # P1: --profile-generate
	diag_token_line = opener_line

	# 'while (1)' with no break never completes (grammar/type_check.w)
	int forever = 0
	if (rotate):
		# 'continue' re-tests at the bottom
		loop_continue_chain = be_ctrl_block()
	else:
		# if not expression: leave the loop
		loop_continue_chain = h_top
		condition_context = 1
		statement_guard(loop_break_chain, outer_condition, 0)
		forever = flow_guard_true

	enclosing_tab_level = while_tab_level
	statement()

	if (rotate):
		be_ctrl_end(loop_continue_chain)
		# Back to the condition: it is parsed here, as the bottom test
		# that branches to the body while it holds, then the lexer
		# returns to the end of the body. Its code belongs to the while
		# line (DWARF, wdbg), like the condition it replaces.
		tokenizer_snapshot body_mark
		char* body_text = loop_rotate_mark(&body_mark)
		loop_rotate_return(&cond_mark, cond_text)
		be_loop_entry_land(entry)
		debug_line_note(stack_pos)
		condition_context = 1
		statement_guard(h_top, outer_condition, 1)
		forever = flow_guard_true
		# Token serials only ever grow (grammar/type_check.w's
		# constant-condition check compares them): the re-parse's
		# count stands
		int serial = token_serial
		loop_rotate_return(&body_mark, body_text)
		if (token_serial < serial): token_serial = serial
	else:
		# loop
		be_br(h_top)
	forever = forever && (flow_loop_break == 0)
	be_ctrl_end(h_top)
	be_ctrl_end(loop_break_chain)

	loop_leave(outer)
	flow_terminates = forever

	return 1
