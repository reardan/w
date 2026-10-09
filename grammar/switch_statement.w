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


void emit_switch_value(int scrutinee_type);
void emit_switch_case_compare(int scrutinee_type, int value_type);


int switch_value():
	int type = promote(expression())
	emit_switch_value(type)
	return type


# Constant case values of the switches being parsed, innermost last:
# switch_seen_base is where the innermost switch's values start.
int* switch_seen_values
int switch_seen_count
int switch_seen_capacity
int switch_seen_base


# Classify the first token of a case value (the current token) for
# switch_case_constant: the start serial, plus whether it is a '-' (1)
# or a '(' (2). Token-based, so the streaming and AST case paths agree.
int switch_case_start():
	int shape = 0
	if ((token[0] == '-') && (token[1] == 0)): shape = 1
	if ((token[0] == '(') && (token[1] == 0)): shape = 2
	return (token_serial << 2) | shape


# The value of the case expression that began with start_state and just
# finished parsing, when it is a literal ('3', '-1', 'c', '(3)') or a
# single enum constant; found_out[0] says whether one was recognized.
int switch_case_constant(int start_state, int value_type, int* found_out):
	found_out[0] = 0
	int shape = start_state & 3
	int start_serial = start_state >> 2
	if ((shape == 0) && (lit_note_serial == start_serial) && (token_serial == start_serial + 1)):
		found_out[0] = 1
		return lit_note_value
	if ((shape == 1) && (lit_note_serial == start_serial + 1) && (token_serial == start_serial + 2)):
		found_out[0] = 1
		if (lit_note_negative): return lit_note_value
		return 0 - lit_note_value
	if ((shape == 2) && (lit_note_serial == start_serial + 1) && (token_serial == start_serial + 3)):
		found_out[0] = 1
		return lit_note_value
	if ((shape != 0) || (token_serial != start_serial + 1)): return 0
	int t = type_unqualified(value_type)
	if ((t < 0) || (type_get_kind(t) != type_kind_enum)): return 0
	if (cast(int, enum_constants) == 0): return 0
	for i in range(enum_constants.length):
		if ((enum_constants[i].type == t) && (strcmp(enum_constants[i].name, last_identifier) == 0)):
			found_out[0] = 1
			return enum_constants[i].value
	return 0


# Warn when a case value repeats an earlier constant of the same switch:
# the first match wins, so the later body is dead (#532).
void switch_note_case_value(int start_state, int value_type, int line, int diag_line, int diag_column):
	int found = 0
	int value = switch_case_constant(start_state, value_type, &found)
	if (found == 0): return
	for i in range(switch_seen_base, switch_seen_count):
		if (switch_seen_values[i] == value):
			diag_part(c"duplicate case value ")
			diag_part(itoa(value))
			type_error_at(c" in switch; only the first matching case runs", line, diag_line, diag_column, c"case")
			return
	if (switch_seen_count >= switch_seen_capacity):
		switch_seen_capacity = switch_seen_capacity * 2 + 16
		switch_seen_values = cast(int*, realloc(switch_seen_values, switch_seen_count * __word_size__, switch_seen_capacity * __word_size__))
	switch_seen_values[switch_seen_count] = value
	switch_seen_count = switch_seen_count + 1


int switch_case_value(int type, int slot, int body_target, int next_target):
	push_slot_copy(slot)
	int start_state = switch_case_start()
	int value_line = line_number
	int value_diag_line = diag_token_line
	int value_diag_column = diag_token_column
	int value_type = promote(expression())
	switch_note_case_value(start_state, value_type, value_line, value_diag_line, value_diag_column)
	emit_switch_case_compare(type, value_type)
	int more = accept(c",")
	if (more): be_br_nonzero_discard(body_target)
	else: be_br_zero_discard(next_target)
	return more


int ast_switch_statement();


int switch_statement():
	if (ast_expressions_mode >= 2): return ast_switch_statement()
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
	int outer_seen_base = switch_seen_base
	switch_seen_base = switch_seen_count
	# The switch cannot complete normally when a default exists and no
	# body falls out of it or breaks (grammar/type_check.w)
	int outer_switch_break = flow_switch_break
	flow_switch_break = 0
	int every_case_terminates = 1

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
		if (flow_terminates == 0): every_case_terminates = 0

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
	switch_seen_count = switch_seen_base
	switch_seen_base = outer_seen_base
	int switch_terminates = seen_default && every_case_terminates && (flow_switch_break == 0)
	flow_switch_break = outer_switch_break

	# Discard the hidden scrutinee slot
	drop_slots(1)
	flow_terminates = switch_terminates

	return 1
