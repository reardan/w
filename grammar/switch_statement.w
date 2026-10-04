/*
switch (expression):             # parentheses optional, like if/while
	case expression: statement-block
	case expression, expression: statement-block
	default: statement-block

The scrutinee is evaluated exactly once, into a hidden stack slot. Each
case compares it against its comma-separated values in source order
(word equality for int-likes; contents for a string scrutinee, like
== on strings, and for a char* scrutinee against char* and
string-literal values, a null-safe strcmp); the first match runs that
case's body and
control then leaves the switch (no fallthrough). 'default' runs when no
case matched and must be the last clause. A switch with no clauses is
legal and only evaluates the scrutinee. Scrutinees other than
int-likes, strings and char* are compile errors.

'break' inside a case body exits the switch (see the switch context
globals in grammar/while_statement.w); 'continue' still targets the
enclosing loop. 'case' and 'default' are contextual keywords: they are
only recognized at the start of a clause inside a switch body, so both
stay usable as ordinary identifiers everywhere else.
*/

void statement();


int ast_statement_switch_value();
int ast_statement_switch_case(int type, int slot, int body_target, int next_target);
void emit_switch_value(int scrutinee_type);
void emit_switch_case_compare(int scrutinee_type, int value_type);


int switch_value():
	if (ast_expressions_mode >= 2): return ast_statement_switch_value()
	int type = promote(expression())
	emit_switch_value(type)
	return type


int switch_case_value(int type, int slot, int body_target, int next_target):
	if (ast_expressions_mode >= 2): return ast_statement_switch_case(type, slot, body_target, next_target)
	push_slot_copy(slot)
	int value_type = promote(expression())
	emit_switch_case_compare(type, value_type)
	int more = accept(c",")
	if (more): be_br_nonzero_discard(body_target)
	else: be_br_zero_discard(next_target)
	return more


int switch_statement():
	if (accept(c"switch") == 0): return 0

	int switch_tab_level = tab_level

	# The scrutinee is evaluated exactly once, into a hidden stack slot
	int scrutinee_type = switch_value()
	int scrutinee_slot = stack_pos

	expect(c":")
	if ((token_newline == 0) && (token[0] != 0)): error(c"switch body must start on a new line")

	# Enter a new break context: 'break' in a case body exits the switch.
	# One region serves both exits — each body's implicit break and every
	# explicit 'break' branch to the switch end.
	int outer_chain = switch_break_chain
	int outer_stack = switch_stack_pos
	int outer_in_switch = break_in_switch
	switch_break_chain = be_ctrl_block()
	switch_stack_pos = stack_pos
	break_in_switch = 1
	switch_depth = switch_depth + 1

	int seen_default = 0

	while ((tab_level > switch_tab_level) && (token[0] != 0)):
		int label_tab_level = tab_level
		if (seen_default): error(c"'default' must be the last clause in a switch")

		# Region for jumps past this case while its values do not match
		int h_next_case = be_ctrl_block()
		if (accept(c"case")):
			# Multi-value case: any matching value jumps to the body
			int h_body = be_ctrl_block()
			int more = 1
			while (more):
				more = switch_case_value(scrutinee_type, scrutinee_slot, h_body, h_next_case)
			be_ctrl_end(h_body)
		else if (accept(c"default")): seen_default = 1
		else: error(c"'case' or 'default' expected in switch body")

		# The body is an ordinary ':' block scoped to the label's line
		enclosing_tab_level = label_tab_level
		statement()

		# Implicit break: leave the switch after the body (no fallthrough)
		be_br(switch_break_chain)
		be_ctrl_end(h_next_case)

	# No-match fallthrough, each body's exit jump, and 'break' all land
	# here, before the scrutinee slot is discarded
	be_ctrl_end(switch_break_chain)

	switch_break_chain = outer_chain
	switch_stack_pos = outer_stack
	break_in_switch = outer_in_switch
	switch_depth = switch_depth - 1

	# Discard the hidden scrutinee slot
	drop_slots(1)

	return 1
