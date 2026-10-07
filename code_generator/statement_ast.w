# Backend lowering consumes resolved statement nodes. Terminator parsing,
# target selection and source spans live in grammar/ast_statement.w.
void emit_simple_statement_ast(statement_ast* node):
	ast_simple_statements_emitted = ast_simple_statements_emitted + 1
	if (node.kind == ast_stmt_pass): return
	if (node.kind == ast_stmt_debugger):
		ast_debugger_statements_emitted = ast_debugger_statements_emitted + 1
		saw_debugger_statement = 1
		int3()
		return
	if (node.valid_jump == 0):
		if (node.kind == ast_stmt_break): error(c"'break' outside of a loop or switch")
		else: error(c"'continue' outside of a loop")
	if (node.unwind_slots > 0): be_pop(node.unwind_slots)
	be_br(node.target)


int emit_prepared_expression_ast(expression_ast* tree, int root);
void ast_expression_note_root(expression_ast* tree, int root);


# Value-bearing statements own an expression child. Source terminators
# are checked between value lowering and the final control transfer,
# retaining the established coercion/diagnostic order.
void emit_statement_ast_expression(statement_ast* node):
	if (node.expression_root < 0): return
	node.expression_type = emit_prepared_expression_ast(node.expression_tree, node.expression_root)


void emit_statement_ast_value(statement_ast* node):
	if (node.expression_root < 0): return
	int type = promote(node.expression_type)
	if (node.kind != ast_stmt_yield): return_mismatch_note(node.declared_type, type)
	if (node.kind == ast_stmt_yield):
		ast_expression_note_root(node.expression_tree, node.expression_root)
		coerce_checked(node.declared_type, type, c"yield")
		const_note_override = 0
	else if ((type_num_args(node.declared_type) > 0) && (type_num_args(type) > 0)):
		if (types_compatible_with_expression(node.declared_type, type) == 0):
			warn_type_mismatch(c"return", node.declared_type, type)
		copy_struct_return_value(node.declared_type)
	else:
		check_void_return(node.declared_type, type, node.line - 1, node.line, node.column)
		ast_expression_note_root(node.expression_tree, node.expression_root)
		coerce_checked(node.declared_type, type, c"return")
		const_note_override = 0


void emit_statement_ast_exit(statement_ast* node):
	if (node.kind == ast_stmt_yield):
		ast_yield_statements_emitted = ast_yield_statements_emitted + 1
		emit_generator_yield_call()
		return
	ast_return_statements_emitted = ast_return_statements_emitted + 1
	if (node.generator):
		for_cleanup_emit_all()
		emit_generator_finish_call()
	else:
		for_cleanup_emit_returning()
		defer_emit_returning()
		be_return(stack_pos)


void ast_expression_replay_warning(expression_ast* tree, int id);


# The tail of ast_expression_finish_prepared that follows its terminator
# lex: warnings located on the token after the root, then the counters.
void emit_statement_ast_expression_end(statement_ast* node):
	expression_ast* tree = node.expression_tree
	for id in range(tree.count):
		if ((tree.op[id] == ast_warning) && (tree.offset[id] == tree.end_offset)):
			ast_expression_replay_warning(tree, id)
	ast_expressions_emitted = ast_expressions_emitted + 1
	ast_roots_emitted = ast_roots_emitted + 1


# S2.2a: the retained walk of a simple, expression or return/yield statement
# (code_generator/retained_emit.w). Each phase is one step the streaming
# hooks in grammar/ast_statement.w run during their parse, at its point.
void emit_statement_ast_walk(retained_statement_walk* walk, int phase):
	statement_ast* node = walk.statement
	if (phase == ast_walk_simple): emit_simple_statement_ast(node)
	else if (phase == ast_walk_expression):
		int root = retained_walk_lower_expression(walk)
		expression_lhs_readonly = walk.tree.readonly
		node.expression_type = walk.tree.result_type[root]
	else if (phase == ast_walk_expression_end): emit_statement_ast_expression_end(node)
	else if (phase == ast_walk_value): emit_statement_ast_value(node)
	else if (phase == ast_walk_exit): emit_statement_ast_exit(node)
	else: error(c"internal error: unknown statement walk phase")


void emit_goto_target(int label, int source_stack):
	if (goto_label_pos[label] >= 0):
		# Backward: the label's depth is known
		goto_adjust_stack(source_stack, goto_label_stack[label])
		jmp_int32(0)
		be_branch_patch(codepos, goto_label_pos[label])
		return
	jmp_int32(0)
	goto_reserve()
	goto_pending_label[goto_pending_count] = label
	goto_pending_site[goto_pending_count] = codepos
	goto_pending_stack[goto_pending_count] = source_stack
	goto_pending_count = goto_pending_count + 1


void emit_label_target(int label, int target_stack):
	# A jump lands here: no constant/compare fold may reach back across it
	be_cmp_note_reset()
	be_imm_note_reset()
	# Forward gotos at another depth get an adjust-and-jump stub, placed
	# before the label behind a jump that skips them on fall-through
	int skip = 0
	int i = goto_pending_base
	while (i < goto_pending_count):
		if ((goto_pending_label[i] == label) && (goto_pending_stack[i] != target_stack)):
			if (skip == 0):
				jmp_int32(0)
				skip = codepos
			be_branch_patch(goto_pending_site[i], codepos)
			goto_adjust_stack(goto_pending_stack[i], target_stack)
			jmp_int32(0)
			# The stub's own jump is resolved to the label below
			goto_pending_site[i] = codepos
		i = i + 1
	if (skip): be_branch_patch(skip, codepos)
	# ...nor across the label itself, past any stub emitted above
	be_notes_reset()
	goto_label_pos[label] = codepos
	goto_label_stack[label] = target_stack
	i = goto_pending_base
	while (i < goto_pending_count):
		if (goto_pending_label[i] == label):
			be_branch_patch(goto_pending_site[i], codepos)
			goto_pending_label[i] = -1
		i = i + 1


void emit_goto_statement_ast(statement_ast* node):
	if (node.kind == ast_stmt_goto): emit_goto_target(node.target, node.stack_depth)
	else: emit_label_target(node.target, node.stack_depth)
	ast_goto_statements_emitted = ast_goto_statements_emitted + 1


void emit_raw_statement_ast(statement_ast* node):
	emit(node.literal_length, node.literal_bytes)
	ast_raw_statements_emitted = ast_raw_statements_emitted + 1


void emit_inferred_local_storage(int type):
	int size = type_stack_words(type)
	if ((type_num_args(type) > 0) & (type_is_array(type) == 0)):
		# Struct value: eax holds its address; copy the words
		int j = size - 1
		while (j >= 0):
			push_eax_plus(j << word_size_log2)
			j = j - 1
		stack_pos = stack_pos + size
		if (type_has_array_field(type)):
			lea_eax_esp_plus(0)
			init_array_field_descriptors(type)
		return
	for i in range(size): push_eax()
	stack_pos = stack_pos + size
	return


void emit_typed_local_storage(int type, int has_initializer):
	# Reserve enough words for aggregate storage, else 1 word.
	int size = type_stack_words(type)
	int num_args = type_num_args(type)
	if ((num_args > 0) & (type_is_array(type) == 0)):
		if (has_initializer):
			int j = size - 1
			while (j >= 0):
				push_eax_plus(j << word_size_log2)
				j = j - 1
			stack_pos = stack_pos + size
			if (type_has_array_field(type)):
				lea_eax_esp_plus(0)
				init_array_field_descriptors(type)
			return
	if (type_is_array(type) | type_has_array_field(type)): mov_eax_int(0)
	for i in range(size): push_eax()
	stack_pos = stack_pos + size
	if (type_is_array(type)):
		lea_eax_esp_plus(2 * word_size)
		store_stack_var(0)
		mov_eax_int(type_get_array_length(type))
		store_stack_var(word_size)
	else if (type_has_array_field(type)):
		lea_eax_esp_plus(0)
		init_array_field_descriptors(type)
	return


int emit_declaration_ast_initializer(statement_ast* node):
	int got = promote(node.expression_type)
	if (node.inferred == 0):
		ast_expression_note_root(node.expression_tree, node.expression_root)
		coerce_checked(node.declared_type, got, c"initialization")
		const_note_override = 0
	return got


void emit_declaration_ast_storage(statement_ast* node):
	ast_declarations_emitted = ast_declarations_emitted + 1
	if (node.inferred): emit_inferred_local_storage(node.declared_type)
	else: emit_typed_local_storage(node.declared_type, node.has_initializer)


# The -v trace of a typed initializer's promoted type (expression_type
# once emit_declaration_ast_initializer has run).
void emit_declaration_ast_trace(statement_ast* node):
	if ((node.inferred == 0) && (verbosity >= 1)):
		print2(c"variable declaration = expression() right side type: ")
		type_print(node.expression_type)


# Local slot assignment. The parse records the local (its name in
# literal_bytes for ':=', its type, the initializer's promoted type in
# expression_type); the slot is the stack depth when its storage is
# pushed, which only emission knows. A typed local was declared by its
# type-name parse and gets its slot here; an inferred one is declared here,
# after its initializer, which therefore cannot name it.
void emit_declaration_ast_bind(statement_ast* node):
	if (node.inferred):
		node.declared_type = inferred_storage_type(node.literal_bytes, node.expression_type)
		sym_declare(node.literal_bytes, node.declared_type, 'L', stack_pos, 1)
		node.binding = table_pos - symbol_data_size
		sym_note_inferred_location(node.binding, node.line, node.column)
		lint_track_local(node.binding)
	else:
		node.binding = last_declared_symbol
		save_int(table + node.binding + 2, stack_pos)
	pointer_indirection = 0
	node.stack_depth = stack_pos


void defer_record_span(char* path, int offset, int line, int column);


# defer registration: the node records the deferred statement's span
# (literal_bytes is its file path, owned by the registry from here on).
void emit_defer_ast_register(statement_ast* node):
	defer_record_span(node.literal_bytes, node.start_offset, node.line - 1, node.column - 1)


# S2.2d: phases of a local declaration, goto/label, raw-asm or defer
# statement's walk (code_generator/retained_emit.w), private to this family.
# A declaration's initializer also runs family (a)'s ast_walk_expression and
# ast_walk_expression_end phases.
const int ast_walk_declaration_initializer = 41
const int ast_walk_declaration_bind = 42
const int ast_walk_declaration_storage = 43
const int ast_walk_goto = 44
const int ast_walk_raw = 45
const int ast_walk_defer_register = 46


# S2.2d: the walk of a local declaration, goto/label, raw-asm or defer
# statement. Each phase is one step its streaming parse ran, at its point.
void emit_declaration_ast_walk(retained_statement_walk* walk, int phase):
	statement_ast* node = walk.statement
	if ((phase == ast_walk_expression) || (phase == ast_walk_expression_end)): emit_statement_ast_walk(walk, phase)
	else if (phase == ast_walk_declaration_initializer):
		node.expression_type = emit_declaration_ast_initializer(node)
		emit_declaration_ast_trace(node)
	else if (phase == ast_walk_declaration_bind): emit_declaration_ast_bind(node)
	else if (phase == ast_walk_declaration_storage): emit_declaration_ast_storage(node)
	else if (phase == ast_walk_goto): emit_goto_statement_ast(node)
	else if (phase == ast_walk_raw): emit_raw_statement_ast(node)
	else if (phase == ast_walk_defer_register): emit_defer_ast_register(node)
	else: error(c"internal error: unknown statement walk phase")


void emit_guard_ast_value(statement_ast* node):
	promote(node.expression_type)


void emit_guard_ast_branch(statement_ast* node):
	be_br_zero_discard(node.target)
	ast_guards_emitted = ast_guards_emitted + 1


void emit_switch_value(int scrutinee_type):
	if (type_float_kind(scrutinee_type)): error(c"switch on a float value is not supported")
	if (type_is_var(scrutinee_type)): error(c"switch on a var value is not supported")
	if (type_stack_words(scrutinee_type) != 1):
		error(c"switch expression must be a word-sized value")
	# int-likes compare as words; string and char* scrutinees compare
	# case values by contents. Anything else (pointers, structs,
	# containers, functions) could only ever match by identity.
	int scrutinee_class = value_class(scrutinee_type)
	if ((value_class_is_int_like(scrutinee_class) == 0) && (scrutinee_class != VC_STRING) && (scrutinee_class != VC_CSTR)):
		value_type_error(c"switch expression must be an int-like value, a string or a char*, got", scrutinee_type)
	push_slot()


void emit_switch_case_compare(int scrutinee_type, int value_type):
	int scrutinee_class = value_class(scrutinee_type)
	if (types_compatible_with_expression(scrutinee_type, value_type) == 0):
		warn_type_mismatch(c"case", scrutinee_type, value_type)
	if (type_decays_to_pointer(scrutinee_type, value_type)): promote_eax()
	pop_ebx_slot()
	# text scrutinees compare contents against text values;
	# a constant case (a null check) stays a word compare
	int value_class_got = value_class(value_type)
	if ((scrutinee_class == VC_STRING) && (value_class_got == VC_STRING)):
		emit_runtime_call_ebx_eax(c"__w_string_equal")
	else if ((scrutinee_class == VC_CSTR) && ((value_class_got == VC_CSTR) || (value_type == string_literal_type))):
		emit_runtime_call_ebx_eax(c"__w_cstr_equal")
	else:
		alu_cmp_set(0x94) /* sete: scrutinee == value */


int emit_switch_value_ast(statement_ast* node):
	int type = promote(node.expression_type)
	emit_switch_value(type)
	ast_switch_values_emitted = ast_switch_values_emitted + 1
	return type


void emit_switch_case_ast_begin(statement_ast* node):
	push_slot_copy(node.stack_depth)


void emit_switch_case_ast_compare(statement_ast* node):
	int type = promote(node.expression_type)
	emit_switch_case_compare(node.declared_type, type)


void emit_switch_case_ast_branch(statement_ast* node):
	if (node.branch_nonzero): be_br_nonzero_discard(node.target)
	else: be_br_zero_discard(node.target)
	ast_switch_cases_emitted = ast_switch_cases_emitted + 1


void emit_if_ast_begin(statement_ast* node):
	node.target = be_ctrl_block()
	node.alternate_target = be_ctrl_block()


void emit_if_ast_then_end(statement_ast* node):
	be_br(node.target)
	be_ctrl_end(node.alternate_target)


void emit_if_ast_end(statement_ast* node):
	be_ctrl_end(node.target)
	ast_if_regions_emitted = ast_if_regions_emitted + 1


void emit_block_ast_deferred(statement_ast* node):
	if (node.function_body): defer_emit_all()


void emit_block_ast_end(statement_ast* node):
	pop_to(node.stack_depth)
	ast_blocks_emitted = ast_blocks_emitted + 1


# S2.2b: the retained walk of a block, an if/elif/else chain or a while
# loop (code_generator/retained_emit.w). The header of each, the opening
# token or the keyword and its condition, is parsed completely before its
# phases are emitted; body statements are walked by their own families as
# they are reached, and the steps after a body (the jump past the else
# arms, the back edge, the region ends, the block's deferred statements
# and stack unwind) are phases emitted once the body has been parsed.
#
# Phase codes are private to these emitters. A condition records family
# (a)'s ast_walk_expression and ast_walk_expression_end too (through
# ast_statement_walk_expression); those run on the condition's
# statement_ast, which is the walk's statement while it is drained.
const int ast_walk_if_begin = 101
const int ast_walk_guard_value = 102
const int ast_walk_guard_branch = 103
const int ast_walk_if_then_end = 104
const int ast_walk_if_end = 105
const int ast_walk_while_begin = 106
const int ast_walk_while_end = 107
const int ast_walk_block_begin = 108
const int ast_walk_block_deferred = 109
const int ast_walk_block_end = 110


# What the phases of an if/while walk act on, owned by the parsing frame
# (which walks before it returns): statement is the if node of the arm
# being parsed (an elif arm swaps its own in), loop the while node. A
# block's walk needs none: its statement_ast is the walk's statement.
struct control_ast_walk:
	int walk
	statement_ast* statement
	loop_ast* loop
	int* outer

# Indexed by walk record id; an entry is valid while its walk is open.
list[control_ast_walk*] control_ast_walks
# The if/while walk whose condition the next ast_statement_guard parses.
control_ast_walk* control_ast_guard_pending


void control_ast_walk_attach(int walk, control_ast_walk* control):
	if (control_ast_walks == 0): control_ast_walks = new list[control_ast_walk*]
	while (control_ast_walks.length <= walk): control_ast_walks.push(0)
	control_ast_walks[walk] = control
	control.walk = walk


# A record's id is on its statement node until retained_emit_statement
# finishes the walk.
control_ast_walk* control_ast_walk_of(retained_statement_walk* walk):
	return control_ast_walks[retained_nodes[walk.node].statement_walk]


int* emit_while_loop_ast_begin(loop_ast* node);
void emit_while_loop_ast_end(loop_ast* node);


# The guard's target region is opened by its statement's begin phase, so
# it is read when the branch is emitted.
void emit_guard_ast_walk_branch(control_ast_walk* control, statement_ast* guard):
	if (control.loop != 0): guard.target = control.loop.break_target
	else: guard.target = control.statement.alternate_target
	emit_guard_ast_branch(guard)


# if/elif/else and while, with their conditions.
void emit_guard_ast_walk(retained_statement_walk* walk, int phase):
	if ((phase == ast_walk_expression) || (phase == ast_walk_expression_end)):
		emit_statement_ast_walk(walk, phase)
		return
	control_ast_walk* control = control_ast_walk_of(walk)
	if (phase == ast_walk_if_begin): emit_if_ast_begin(control.statement)
	else if (phase == ast_walk_guard_value): emit_guard_ast_value(walk.statement)
	else if (phase == ast_walk_guard_branch): emit_guard_ast_walk_branch(control, walk.statement)
	else if (phase == ast_walk_if_then_end): emit_if_ast_then_end(control.statement)
	else if (phase == ast_walk_if_end): emit_if_ast_end(control.statement)
	else if (phase == ast_walk_while_begin): control.outer = emit_while_loop_ast_begin(control.loop)
	else if (phase == ast_walk_while_end): emit_while_loop_ast_end(control.loop)
	else: error(c"internal error: unknown statement walk phase")


# '{' and ':' blocks: open the DWARF scope, then (after the body) run a
# function body's deferred statements, close the scope and unwind.
void emit_block_ast_walk(retained_statement_walk* walk, int phase):
	statement_ast* node = walk.statement
	if (phase == ast_walk_block_begin):
		node.stack_depth = stack_pos
		dwarf_block_begin()
		if (node.kind == ast_stmt_indent_block): print_int_v1(c"starting stack_pos: ", stack_pos)
	else if (phase == ast_walk_block_deferred): emit_block_ast_deferred(node)
	else if (phase == ast_walk_block_end):
		dwarf_block_end()
		if (node.kind == ast_stmt_indent_block): print_int_v1(c"ending stack_pos: ", stack_pos)
		emit_block_ast_end(node)
	else: error(c"internal error: unknown statement walk phase")


void emit_switch_region_ast_begin(statement_ast* node):
	node.target = be_ctrl_block()


void emit_switch_case_region_ast_begin(statement_ast* node):
	node.alternate_target = be_ctrl_block()


void emit_switch_match_region_ast_begin(statement_ast* node):
	node.body_target = be_ctrl_block()


void emit_switch_match_region_ast_end(statement_ast* node):
	be_ctrl_end(node.body_target)


void emit_switch_case_region_ast_end(statement_ast* node):
	be_br(node.target)
	be_ctrl_end(node.alternate_target)


void emit_switch_region_ast_end(statement_ast* node):
	be_ctrl_end(node.target)
	ast_switch_regions_emitted = ast_switch_regions_emitted + 1


void emit_switch_region_ast_cleanup(statement_ast* node):
	drop_slots(node.unwind_slots)


# S2.2c: a switch statement walked from its record (code_generator/
# retained_emit.w). The grammar (grammar/ast_statement.w) records these
# phases in the order the streaming hooks ran the steps, and runs them
# itself, in place, when no walk is open. A header value (the selector or
# a case value) is walked before the next one is parsed, so the record
# holds one value at a time; the switch node keeps the facts the later
# phases need (selector type and slot, regions, the enclosing break
# context).
const int switch_walk_value = 1
const int switch_walk_value_end = 2
const int switch_walk_selector = 3
const int switch_walk_region = 4
const int switch_walk_enter = 5
const int switch_walk_case_region = 6
const int switch_walk_match_region = 7
const int switch_walk_case_begin = 8
const int switch_walk_case_note = 9
const int switch_walk_case_compare = 10
const int switch_walk_case_branch = 11
const int switch_walk_match_end = 12
const int switch_walk_case_end = 13
const int switch_walk_region_end = 14
const int switch_walk_leave = 15
const int switch_walk_cleanup = 16


struct switch_ast_walk:
	statement_ast* node
	statement_ast* value
	int case_start
	int case_line
	int outer_chain
	int outer_stack
	int outer_in_switch


# A header value's lowering from its retained group (S2.2c; family (a)'s
# ast_walk_expression step, for a value the walk record does not own).
void emit_walk_header_value(retained_statement_walk* walk, statement_ast* value):
	int root = retained_walk_lower_expression(walk)
	expression_lhs_readonly = walk.tree.readonly
	value.expression_type = walk.tree.result_type[root]


# One switch step; walk is 0 when the grammar runs it during the parse.
void emit_switch_ast_phase(switch_ast_walk* record, retained_statement_walk* walk, int phase):
	statement_ast* node = record.node
	statement_ast* value = record.value
	if (phase == switch_walk_value): emit_walk_header_value(walk, value)
	else if (phase == switch_walk_value_end): emit_statement_ast_expression_end(value)
	else if (phase == switch_walk_selector):
		node.declared_type = emit_switch_value_ast(value)
		node.stack_depth = stack_pos
	else if (phase == switch_walk_region): emit_switch_region_ast_begin(node)
	else if (phase == switch_walk_enter):
		# 'break' in a case body exits the switch
		switch_break_chain = node.target
		switch_stack_pos = stack_pos
		break_in_switch = 1
		switch_depth = switch_depth + 1
	else if (phase == switch_walk_case_region): emit_switch_case_region_ast_begin(node)
	else if (phase == switch_walk_match_region): emit_switch_match_region_ast_begin(node)
	else if (phase == switch_walk_case_begin):
		value.declared_type = node.declared_type
		value.stack_depth = node.stack_depth
		emit_switch_case_ast_begin(value)
	else if (phase == switch_walk_case_note):
		switch_note_case_value(record.case_start, value.expression_type, record.case_line, value.line, value.column)
	else if (phase == switch_walk_case_compare): emit_switch_case_ast_compare(value)
	else if (phase == switch_walk_case_branch):
		value.target = node.alternate_target
		if (value.branch_nonzero): value.target = node.body_target
		emit_switch_case_ast_branch(value)
	else if (phase == switch_walk_match_end): emit_switch_match_region_ast_end(node)
	else if (phase == switch_walk_case_end): emit_switch_case_region_ast_end(node)
	else if (phase == switch_walk_region_end): emit_switch_region_ast_end(node)
	else if (phase == switch_walk_leave):
		switch_break_chain = record.outer_chain
		switch_stack_pos = record.outer_stack
		break_in_switch = record.outer_in_switch
		switch_depth = switch_depth - 1
	else if (phase == switch_walk_cleanup): emit_switch_region_ast_cleanup(node)
	else: error(c"internal error: unknown switch walk phase")


void emit_switch_ast_walk(retained_statement_walk* walk, int phase):
	emit_switch_ast_phase(cast(switch_ast_walk*, walk.statement), walk, phase)
