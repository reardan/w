/*
switch (expression):             # parentheses optional, like if/while
	case expression:
		statement-block
	case expression, expression:
		statement-block
	default:
		statement-block

The scrutinee is evaluated exactly once, into a hidden stack slot. Each
case compares it against its comma-separated values in source order
(word equality, like ==); the first match runs that case's body and
control then leaves the switch (no fallthrough). 'default' runs when no
case matched and must be the last clause. A switch with no clauses is
legal and only evaluates the scrutinee.

'break' inside a case body exits the switch (see the switch context
globals in grammar/while_statement.w); 'continue' still targets the
enclosing loop. 'case' and 'default' are contextual keywords: they are
only recognized at the start of a clause inside a switch body, so both
stay usable as ordinary identifiers everywhere else.
*/

void statement();


int switch_statement():
	if (accept(c"switch") == 0):
		return 0

	int switch_tab_level = tab_level

	# The scrutinee is evaluated exactly once, into a hidden stack slot
	int scrutinee_type = promote(expression())
	if (type_float_kind(scrutinee_type)):
		error(c"switch on a float value is not supported")
	if (type_is_var(scrutinee_type)):
		error(c"switch on a var value is not supported")
	if (type_stack_words(scrutinee_type) != 1):
		error(c"switch expression must be a word-sized value")
	push_eax()
	stack_pos = stack_pos + 1
	int scrutinee_slot = stack_pos

	expect(c":")
	if ((token_newline == 0) & (token[0] != 0)):
		error(c"switch body must start on a new line")

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

	while ((tab_level > switch_tab_level) & (token[0] != 0)):
		int label_tab_level = tab_level
		if (seen_default):
			error(c"'default' must be the last clause in a switch")

		# Region for jumps past this case while its values do not match
		int h_next_case = be_ctrl_block()
		if (accept(c"case")):
			# Multi-value case: any matching value jumps to the body
			int h_body = be_ctrl_block()
			int more = 1
			while (more):
				mov_eax_esp_plus((stack_pos - scrutinee_slot) << word_size_log2)
				push_eax()
				stack_pos = stack_pos + 1
				int value_type = promote(expression())
				if (types_compatible_with_expression(scrutinee_type, value_type) == 0):
					warn_type_mismatch(c"case", scrutinee_type, value_type)
				if (type_decays_to_pointer(scrutinee_type, value_type)):
					promote_eax()
				pop_ebx()
				stack_pos = stack_pos - 1
				alu_cmp_set(0x94) /* sete: scrutinee == value */
				more = accept(c",")
				if (more):
					be_br_nonzero(h_body)
				else:
					be_br_zero(h_next_case)
			be_ctrl_end(h_body)
		else if (accept(c"default")):
			seen_default = 1
		else:
			error(c"'case' or 'default' expected in switch body")

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
	be_pop(1)
	stack_pos = stack_pos - 1

	return 1
