# wbuild: x64
import lib.testing
import lib.process
import repl.core


int detached_initialized


void detached_init():
	if (detached_initialized): return
	repl_init()
	detached_initialized = 1


# The returned ID is the only surviving parse result. Poison the borrowed
# arena before returning, then close the input: emission must use neither.
int detached_parse(char* source, int walk = -1):
	char* saved = generic_reparse_save()
	int serial = token_serial
	int reader
	int writer
	assert_equal(0, process_make_pipe(&reader, &writer))
	getchar_reset(reader)
	assert_equal(strlen(source), write(writer, source, strlen(source)))
	close(writer)
	file = reader
	filename = c"detached-expression.w"
	retained_source_begin(filename)
	byte_offset = 0
	line_number = 0
	column_number = 0
	tab_level = 0
	token_newline = 0
	nextc = 0
	nextc = get_character()
	get_token()
	int before = codepos
	expression_ast tree
	int root = ast_expression_prepare_at(&tree, token_start_offset, 1)
	assert1(root >= 0)
	int group = retained_node_count()
	if (walk >= 0): retained_walk_expression(walk, &tree, root)
	else: retained_expression_note(&tree, root)
	assert_equal(before, codepos)
	for i in range(tree.count):
		tree.op[i] = 0
		tree.value[i] = 999
		tree.result_type[i] = -99
	for i in range(tree.text_used): tree.text[i] = 'x'
	for i in range(tree.type_names_used): tree.type_names[i] = 'x'
	for i in range(tree.token_count * expression_ast_token_fields): tree.tokens[i] = -123
	close(reader)
	generic_reparse_restore(saved)
	token_serial = serial
	return group


type detached_callback = fn() -> int


int detached_run(int group):
	int start = codepos
	int serial = token_serial
	int offset = token_start_offset
	char* spelling = strclone(token)
	int emitted = ast_retained_emitted
	be_notes_reset()
	int result = retained_emit_expression(group)
	promote(result)
	ret()
	assert_equal(serial, token_serial)
	assert_equal(offset, token_start_offset)
	assert_strings_equal(spelling, token)
	assert_equal(emitted + 1, ast_retained_emitted)
	free(spelling)
	detached_callback* run = cast(detached_callback*, code + start)
	int value = run()
	codepos = start
	be_notes_reset()
	return value


void test_retained_expression_outlives_parse_frame():
	detached_init()
	ast_expressions_mode = 2
	ast_retain_mode = 1
	ast_emit_retained_mode = 1
	# Exercise both the ordinary compile and semantic/tree-query records.
	for semantic in range(2):
		retained_semantic_mode = semantic
		int before = codepos
		int arithmetic = detached_parse(c"6 * 7\n")
		int short_circuit = detached_parse(c"0 && (1 / 0)\n")
		int conditional = detached_parse(c"1 ? 42 : (1 / 0)\n")
		int string = detached_parse(c"s\"ab\\x00cd\".length\n")
		int literal = detached_parse(c"-300\n")
		assert_equal(before, codepos)
		# Several intervening parses recycled the slabs and stack frames.
		assert_equal(42, detached_run(arithmetic))
		expression_ast view
		retained_expression_view(&view, literal)
		ast_expression_note_root(&view, retained_record_at(literal).group.root)
		assert_equal(1, const_note_override)
		assert_equal(-300, const_note_value)
		assert_equal(1, const_note_diag_line)
		assert_equal(2, const_note_diag_column)
		const_note_override = 0
		assert_equal(0, detached_run(short_circuit))
		assert_equal(42, detached_run(conditional))
		assert_equal(5, detached_run(string))
		assert_equal(42, detached_run(arithmetic))
		# Local names and slots must also outlive the parser's symbol scope.
		int symbols = table_pos
		int saved_stack = stack_pos
		int type = type_lookup(c"int")
		stack_pos = 3
		sym_declare(c"owned_local", type, 'L', 2, 1)
		int local = detached_parse(c"owned_local\n")
		table_pos = symbols
		sym_index_sync()
		sym_declare(c"other_local", type, 'L', 99, 1)
		stack_pos = 5
		int start = codepos
		be_notes_reset()
		assert_equal(type, retained_emit_expression(local))
		assert_strings_equal(c"owned_local", last_identifier)
		int length = codepos - start
		char* actual = cast(char*, malloc(length))
		for i in range(length): actual[i] = code[start + i]
		codepos = start
		be_notes_reset()
		be_lea_acc_wstack(2 * word_size)
		assert_equal(length, codepos - start)
		assert_bytes_equal(actual, code + start, length)
		free(actual)
		codepos = start
		be_notes_reset()
		stack_pos = saved_stack
		table_pos = symbols
		sym_index_sync()
	retained_semantic_mode = 0
	# Statement walks must own the same independent expression view. Keep
	# only the statement alive, overwrite the parse arena, and walk later.
	int statement = retained_enter(retained_statement, c"detached-walk.w", 0, 1, 1, c"expression")
	statement_ast node
	node.kind = ast_stmt_expression
	node.expression_tree = 0
	int walk = retained_walk_begin(cast(int, emit_statement_ast_walk), &node)
	assert1(walk >= 0)
	int group = detached_parse(c"6 * 7\n", walk)
	node.expression_root = retained_record_at(group).group.root
	detached_parse(c"123 + 456\n")
	retained_walk_phase(walk, ast_walk_expression)
	int start = codepos
	be_notes_reset()
	retained_emit_statement(statement)
	assert_equal(3, node.expression_type)
	assert1(node.expression_tree != 0)
	ret()
	detached_callback* run = cast(detached_callback*, code + start)
	assert_equal(42, run())
	codepos = start
	be_notes_reset()
	retained_leave(statement, 6)


void detached_poison(void* record, int size):
	char* bytes = cast(char*, record)
	for i in range(size): bytes[i] = 165


# Both the guard and its enclosing control record leave this frame alive.
# Nothing has been emitted when the function returns; the caller can reuse
# the stack and parse arenas before opening the control regions.
int detached_guard_prepare(char* condition, int is_loop):
	int id = retained_enter(retained_statement, c"detached-control.w", 0, 1, 1, c"guard")
	statement_ast local_guard
	statement_ast* guard = cast(statement_ast*, retained_parse_record(&local_guard, sizeof(statement_ast)))
	guard.kind = ast_stmt_guard
	control_ast_walk local_control
	control_ast_walk* control = cast(control_ast_walk*, retained_parse_record(&local_control, sizeof(control_ast_walk)))
	statement_ast local_arm
	loop_ast local_loop
	int walk = retained_walk_begin(cast(int, emit_guard_ast_walk), guard)
	assert1(walk >= 0)
	if (is_loop):
		control.loop = cast(loop_ast*, retained_parse_record(&local_loop, sizeof(loop_ast)))
		control.loop.kind = ast_loop_while
		ast_loop_layout(control.loop, stack_pos)
	else:
		control.statement = cast(statement_ast*, retained_parse_record(&local_arm, sizeof(statement_ast)))
		control.statement.kind = ast_stmt_if
	control_ast_walk_attach(walk, control)
	if (is_loop): retained_walk_phase(walk, ast_walk_while_begin)
	else: retained_walk_phase(walk, ast_walk_if_begin)
	int group = detached_parse(condition, walk)
	guard.expression_root = retained_record_at(group).group.root
	retained_walk_phase(walk, ast_walk_expression)
	retained_walk_phase(walk, ast_walk_guard_value)
	retained_walk_phase(walk, ast_walk_guard_branch)
	detached_poison(&local_guard, sizeof(statement_ast))
	detached_poison(&local_arm, sizeof(statement_ast))
	detached_poison(&local_loop, sizeof(loop_ast))
	detached_poison(&local_control, sizeof(control_ast_walk))
	retained_leave(id, 1)
	return id


void test_retained_control_records_outlive_parse_frame():
	detached_init()
	ast_expressions_mode = 2
	ast_retain_mode = 1
	ast_emit_retained_mode = 1
	for semantic in range(2):
		retained_semantic_mode = semantic
		for condition in range(2):
			int start = codepos
			char* source = c"0\n"
			if (condition): source = c"1\n"
			int id = detached_guard_prepare(source, 0)
			detached_parse(c"999 + 123\n")
			assert_equal(start, codepos)
			int walk = retained_record_at(id).statement_walk
			be_notes_reset()
			retained_walk_drain(walk)
			mov_eax_int(42)
			retained_walk_phase(walk, ast_walk_if_then_end)
			retained_walk_drain(walk)
			mov_eax_int(17)
			retained_walk_phase(walk, ast_walk_if_end)
			retained_emit_statement(id)
			ret()
			detached_callback* run = cast(detached_callback*, code + start)
			int expected = 17
			if (condition): expected = 42
			assert_equal(expected, run())
			codepos = start
			be_notes_reset()
		int start = codepos
		int depth = loop_depth
		int id = detached_guard_prepare(c"0\n", 1)
		detached_parse(c"321 * 7\n")
		assert_equal(start, codepos)
		int walk = retained_record_at(id).statement_walk
		retained_walk_drain(walk)
		control_ast_walk* control = control_ast_walk_of(retained_walks[walk])
		assert_equal(depth + 1, loop_depth)
		mov_eax_int(999)
		retained_walk_phase(walk, ast_walk_while_end)
		retained_emit_statement(id)
		loop_leave(control.outer)
		assert_equal(depth, loop_depth)
		mov_eax_int(42)
		ret()
		detached_callback* run = cast(detached_callback*, code + start)
		assert_equal(42, run())
		codepos = start
		be_notes_reset()
	retained_semantic_mode = 0


# The bytes include NULs; copying them as a C string loses the immediate.
int detached_raw_prepare():
	int id = retained_enter(retained_statement, c"detached-raw.w", 0, 1, 1, c"raw_asm")
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	char[6] bytes
	bytes[0] = 184
	bytes[1] = 42
	bytes[2] = 0
	bytes[3] = 0
	bytes[4] = 0
	bytes[5] = 195
	node.kind = ast_stmt_raw_asm
	node.literal_bytes = bytes
	node.literal_length = 6
	assert1(ast_raw_walk_open(node) >= 0)
	detached_poison(bytes, 6)
	detached_poison(&local_node, sizeof(statement_ast))
	retained_leave(id, 6)
	return id


void test_retained_statement_payload_and_rollback():
	detached_init()
	ast_expressions_mode = 2
	ast_retain_mode = 1
	ast_emit_retained_mode = 1
	int start = codepos
	int id = detached_raw_prepare()
	int walk = retained_record_at(id).statement_walk
	statement_ast* node = retained_walks[walk].statement
	detached_parse(c"123 + 456\n")
	assert_equal(start, codepos)
	assert_equal(6, node.literal_length)
	be_notes_reset()
	retained_emit_statement(id)
	detached_callback* run = cast(detached_callback*, code + start)
	assert_equal(42, run())
	codepos = start
	be_notes_reset()
	# An error can abandon an unwalked record. Session rollback owns its
	# storage and the next walk must not consume its stale payload/phases.
	retained_checkpoint checkpoint
	retained_capture(&checkpoint)
	int arena = retained_arena_used()
	int used = retained_walks_used
	detached_raw_prepare()
	retained_rollback(&checkpoint)
	retained_walk_release()
	assert_equal(arena, retained_arena_used())
	assert_equal(used, retained_walks_used)
	id = detached_raw_prepare()
	retained_emit_statement(id)
	run = cast(detached_callback*, code + start)
	assert_equal(42, run())
	codepos = start
	be_notes_reset()


statement_ast* detached_local_prepare(int depth):
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	char* name = strclone(c"detached_owned_local")
	node.kind = ast_stmt_declaration
	node.inferred = 1
	node.expression_type = 3
	node.literal_bytes = retained_parse_name(name)
	node.line = 1
	node.column = 1
	ast_declaration_bind(node, depth)
	detached_poison(name, strlen(name))
	free(name)
	detached_poison(&local_node, sizeof(statement_ast))
	return node


void test_local_analysis_does_not_emit_storage():
	detached_init()
	ast_retain_mode = 1
	int start = codepos
	int symbols = table_pos
	int backend_depth = stack_pos
	statement_ast* node = detached_local_prepare(7)
	assert_equal(start, codepos)
	assert_equal(backend_depth, stack_pos)
	assert_equal(7, node.stack_depth)
	assert_equal(7, load_int(table + node.binding + 2))
	assert_strings_equal(c"detached_owned_local", node.literal_bytes)
	assert_equal(type_lookup(c"int"), node.declared_type)
	# A later declaration must not redirect a typed local's slot update
	# through the global last_declared_symbol.
	statement_ast local_typed
	statement_ast* typed = cast(statement_ast*, retained_parse_record(&local_typed, sizeof(statement_ast)))
	typed.binding = node.binding
	typed.declared_type = node.declared_type
	sym_declare(c"detached_other_local", node.declared_type, 'L', 99, 1)
	int other = table_pos - symbol_data_size
	last_declared_symbol = other
	ast_declaration_bind(typed, 11)
	assert_equal(11, load_int(table + node.binding + 2))
	assert_equal(99, load_int(table + other + 2))
	assert_equal(start, codepos)
	assert_equal(backend_depth, stack_pos)
	table_pos = symbols
	sym_index_sync()


int detached_range_prepare(int slot):
	int id = retained_enter(retained_statement, c"detached-range.w", 0, 1, 1, c"for")
	loop_ast local_loop
	loop_ast* loop = cast(loop_ast*, retained_parse_record(&local_loop, sizeof(loop_ast)))
	loop.kind = ast_loop_range
	loop.variable_slot = slot
	loop.argument_count = 1
	ast_loop_layout(loop, slot)
	statement_ast local_value
	statement_ast* value = cast(statement_ast*, retained_parse_record(&local_value, sizeof(statement_ast)))
	value.kind = ast_stmt_range_argument
	loop_ast_walk local_record
	loop_ast_walk* record = cast(loop_ast_walk*, retained_parse_record(&local_record, sizeof(loop_ast_walk)))
	record.loop = loop
	record.value = value
	int walk = retained_walk_begin(cast(int, emit_loop_ast_walk), cast(statement_ast*, record))
	int group = detached_parse(c"3\n", walk)
	value.expression_root = retained_record_at(group).group.root
	retained_walk_phase(walk, loop_walk_value)
	retained_walk_phase(walk, loop_walk_value_store)
	retained_walk_phase(walk, loop_walk_range_begin)
	detached_poison(&local_loop, sizeof(loop_ast))
	detached_poison(&local_value, sizeof(statement_ast))
	detached_poison(&local_record, sizeof(loop_ast_walk))
	retained_leave(id, 1)
	return id


int detached_switch_prepare():
	int id = retained_enter(retained_statement, c"detached-switch.w", 0, 1, 1, c"switch")
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	node.kind = ast_stmt_switch
	node.unwind_slots = 1
	node.stack_depth = stack_pos + 1
	statement_ast local_value
	statement_ast* value = cast(statement_ast*, retained_parse_record(&local_value, sizeof(statement_ast)))
	value.kind = ast_stmt_switch_value
	switch_ast_walk local_record
	switch_ast_walk* record = cast(switch_ast_walk*, retained_parse_record(&local_record, sizeof(switch_ast_walk)))
	record.node = node
	record.value = value
	record.outer_chain = switch_break_chain
	record.outer_stack = switch_stack_pos
	record.outer_in_switch = break_in_switch
	int walk = retained_walk_begin(cast(int, emit_switch_ast_walk), cast(statement_ast*, record))
	int group = detached_parse(c"42\n", walk)
	value.expression_root = retained_record_at(group).group.root
	retained_walk_phase(walk, switch_walk_value)
	retained_walk_phase(walk, switch_walk_selector)
	retained_walk_phase(walk, switch_walk_region)
	retained_walk_phase(walk, switch_walk_enter)
	retained_walk_phase(walk, switch_walk_case_region)
	retained_walk_phase(walk, switch_walk_match_region)
	detached_poison(&local_node, sizeof(statement_ast))
	detached_poison(&local_value, sizeof(statement_ast))
	detached_poison(&local_record, sizeof(switch_ast_walk))
	retained_leave(id, 1)
	return id


void detached_switch_case_prepare(int id, char* source):
	int walk = retained_record_at(id).statement_walk
	switch_ast_walk* record = cast(switch_ast_walk*, retained_walks[walk].statement)
	statement_ast local_value
	statement_ast* value = cast(statement_ast*, retained_parse_record(&local_value, sizeof(statement_ast)))
	value.kind = ast_stmt_switch_case
	record.value = value
	retained_walk_phase(walk, switch_walk_case_begin)
	int group = detached_parse(source, walk)
	value.expression_root = retained_record_at(group).group.root
	retained_walk_phase(walk, switch_walk_value)
	retained_walk_phase(walk, switch_walk_case_compare)
	retained_walk_phase(walk, switch_walk_case_branch)
	retained_walk_phase(walk, switch_walk_match_end)
	detached_poison(&local_value, sizeof(statement_ast))


int detached_switch_result


void test_retained_for_and_switch_records_outlive_parse_frame():
	detached_init()
	ast_expressions_mode = 2
	ast_retain_mode = 1
	ast_emit_retained_mode = 1
	for semantic in range(2):
		retained_semantic_mode = semantic
		int start = codepos
		int depth = stack_pos
		be_notes_reset()
		mov_eax_int(0)
		int slot = push_slot()
		int header_start = codepos
		int id = detached_range_prepare(slot)
		detached_parse(c"987 * 123\n")
		assert_equal(header_start, codepos)
		int walk = retained_record_at(id).statement_walk
		retained_walk_drain(walk)
		retained_walk_phase(walk, loop_walk_range_end)
		retained_walk_phase(walk, loop_walk_leave)
		retained_walk_phase(walk, loop_walk_cleanup)
		retained_emit_statement(id)
		load_slot(slot)
		drop_slots(1)
		ret()
		assert_equal(depth, stack_pos)
		detached_callback* run = cast(detached_callback*, code + start)
		assert_equal(3, run())
		codepos = start
		be_notes_reset()
		for matches in range(2):
			int switch_nesting = switch_depth
			id = detached_switch_prepare()
			assert_equal(start, codepos)
			walk = retained_record_at(id).statement_walk
			retained_walk_drain(walk)
			int case_start = codepos
			char* source = c"0\n"
			if (matches): source = c"42\n"
			detached_switch_case_prepare(id, source)
			detached_parse(c"123 * 987\n")
			assert_equal(case_start, codepos)
			retained_walk_drain(walk)
			push_slot_int(cast(int, &detached_switch_result))
			mov_eax_int(123)
			pop_ebx_slot()
			store_ebx_word()
			retained_walk_phase(walk, switch_walk_case_end)
			retained_walk_phase(walk, switch_walk_region_end)
			retained_walk_phase(walk, switch_walk_leave)
			retained_walk_phase(walk, switch_walk_cleanup)
			retained_emit_statement(id)
			ret()
			assert_equal(depth, stack_pos)
			assert_equal(switch_nesting, switch_depth)
			run = cast(detached_callback*, code + start)
			int expected = 0
			if (matches): expected = 123
			detached_switch_result = 0
			run()
			assert_equal(expected, detached_switch_result)
			codepos = start
			be_notes_reset()
	retained_semantic_mode = 0


void test_control_layout_ignores_backend_stack():
	detached_init()
	int before = codepos
	int depth = stack_pos
	stack_pos = 999
	loop_ast loop
	loop.kind = ast_loop_range
	loop.variable_slot = 7
	for arguments in range(1, 4):
		loop.argument_count = arguments
		ast_loop_layout(&loop, 7)
		assert_equal(7, loop.entry_depth)
		assert_equal(7 + arguments, loop.body_depth)
		assert_equal(arguments, loop.cleanup_slots)
		int end = 8
		if (arguments >= 2): end = 9
		assert_equal(end, loop.end_slot)
	loop.kind = ast_loop_cursor
	ast_loop_layout(&loop, 11)
	assert_equal(12, loop.container_slot)
	assert_equal(13, loop.cursor_slot)
	assert_equal(13, loop.body_depth)
	assert_equal(2, loop.cleanup_slots)
	loop.kind = ast_loop_while
	ast_loop_layout(&loop, 17)
	assert_equal(17, loop.body_depth)
	assert_equal(0, loop.cleanup_slots)
	statement_ast block
	ast_block_layout(&block, 5)
	assert_equal(5, block.stack_depth)
	statement_ast jump
	ast_jump_layout(&jump, 17, 5, 123, 1)
	assert_equal(12, jump.unwind_slots)
	assert_equal(123, jump.target)
	assert_equal(999, stack_pos)
	assert_equal(before, codepos)
	stack_pos = depth


void test_goto_scope_validation_precedes_branch_emission():
	detached_init()
	int before = codepos
	int depth = stack_pos
	int labels = goto_label_base
	int pending = goto_pending_base
	goto_scope_begin()
	# Interning order need not be goto order, and an abandoned parse may
	# intern a name without registering a successful goto to it.
	int late = goto_label_intern(c"later-reference")
	int first = goto_label_intern(c"first-reference")
	goto_label_intern(c"abandoned-reference")
	goto_label_note_reference(first)
	goto_label_note_reference(late)
	assert_equal(first, goto_scope_unresolved())
	goto_label_defined[first] = 1
	assert_equal(late, goto_scope_unresolved())
	int nested_labels = goto_label_base
	int nested_pending = goto_pending_base
	goto_scope_begin()
	int nested = goto_label_intern(c"later-reference")
	goto_label_note_reference(nested)
	assert_equal(nested, goto_scope_unresolved())
	goto_label_defined[nested] = 1
	goto_scope_end(nested_labels, nested_pending)
	assert_equal(late, goto_scope_unresolved())
	goto_label_defined[late] = 1
	assert_equal(-1, goto_scope_unresolved())
	# No machine branch exists: all semantic labels are known while their
	# code offsets are still unbound and the pending patch list is empty.
	assert_equal(-1, goto_label_pos[first])
	assert_equal(-1, goto_label_pos[late])
	assert_equal(goto_pending_base, goto_pending_count)
	goto_scope_validate()
	goto_scope_end(labels, pending)
	assert_equal(before, codepos)
	assert_equal(depth, stack_pos)


void test_symbolic_jump_binds_regions_only_during_emission():
	detached_init()
	ast_expressions_mode = 2
	ast_retain_mode = 1
	ast_emit_retained_mode = 1
	retained_checkpoint checkpoint
	retained_capture(&checkpoint)
	int before = codepos
	int function = retained_enter(retained_function, c"symbolic-control.w", 0, 1, 1, c"function")
	int parent = retained_enter(retained_statement, c"symbolic-control.w", 0, 1, 1, c"while")
	loop_ast local_loop
	loop_ast* loop = cast(loop_ast*, retained_parse_record(&local_loop, sizeof(loop_ast)))
	loop.kind = ast_loop_while
	loop.break_target = -123
	loop.continue_target = -456
	ast_loop_layout(loop, 0)
	control_ast_walk local_control
	control_ast_walk* control = cast(control_ast_walk*, retained_parse_record(&local_control, sizeof(control_ast_walk)))
	control.loop = loop
	int walk = retained_walk_begin(cast(int, emit_guard_ast_walk), 0)
	control_ast_walk_attach(walk, control)
	int child = retained_enter(retained_statement, c"symbolic-control.w", 1, 1, 2, c"break")
	statement_ast local_jump
	statement_ast* jump = cast(statement_ast*, retained_parse_record(&local_jump, sizeof(statement_ast)))
	jump.kind = ast_stmt_break
	jump.stack_depth = 0
	jump.target = -999
	ast_jump_resolve_retained(jump)
	assert_equal(1, jump.valid_jump)
	assert_equal(1, jump.control_kind)
	assert_equal(cast(int, loop), cast(int, jump.control_record))
	assert_equal(0, jump.unwind_slots)
	assert_equal(before, codepos)
	retained_leave(child, 2)
	retained_leave(parent, 2)
	retained_leave(function, 2)
	# Analyze first, then assign the native region. The jump's stale
	# numeric target must never be used by the emitter.
	be_notes_reset()
	loop.break_target = be_ctrl_block()
	mov_eax_int(41)
	emit_simple_statement_ast(jump)
	mov_eax_int(-1)
	be_ctrl_end(loop.break_target)
	ret()
	detached_callback* run = cast(detached_callback*, code + before)
	assert_equal(41, run())
	codepos = before
	be_notes_reset()
	retained_rollback(&checkpoint)
	retained_walk_release()


void test_layout_cursor_rollback_and_nested_functions():
	detached_init()
	ast_expressions_mode = 2
	ast_retain_mode = 1
	ast_emit_retained_mode = 1
	retained_checkpoint entry
	retained_capture(&entry)
	int before = codepos
	int depth = stack_pos
	stack_pos = 999
	int function = retained_enter(retained_function, c"layout-cursor.w", 0, 1, 1, c"outer")
	ast_body_layout_begin(function, 4)
	retained_checkpoint checkpoint
	retained_capture(&checkpoint)
	int statement = retained_enter(retained_statement, c"layout-cursor.w", 1, 1, 2, c"local")
	ast_body_statement_begin(statement)
	ast_body_reserve(3)
	assert_equal(7, ast_body_depth())
	assert_equal(999, stack_pos)
	assert_equal(4, retained_record_at(function).layout_depth)
	# A failed statement never publishes its partially advanced cursor.
	retained_rollback(&checkpoint)
	assert_equal(4, ast_body_depth())
	statement = retained_enter(retained_statement, c"layout-cursor.w", 1, 1, 2, c"local")
	ast_body_statement_begin(statement)
	ast_body_reserve(3)
	stack_pos = 7
	ast_body_statement_end(statement)
	retained_leave(statement, 2)
	assert_equal(7, ast_body_depth())
	int nested = retained_enter(retained_function, c"layout-cursor.w", 2, 1, 3, c"nested")
	ast_body_layout_begin(nested, 2)
	statement = retained_enter(retained_statement, c"layout-cursor.w", 3, 1, 4, c"nested-local")
	ast_body_statement_begin(statement)
	ast_body_reserve(6)
	assert_equal(8, ast_body_depth())
	stack_pos = 8
	ast_body_statement_end(statement)
	retained_leave(statement, 4)
	retained_leave(nested, 4)
	assert_equal(7, ast_body_depth())
	# An unsupported expression suspends only the current statement until
	# success. Recovery must not poison an otherwise analyzable parent.
	retained_capture(&checkpoint)
	statement = retained_enter(retained_statement, c"layout-cursor.w", 4, 1, 5, c"aggregate")
	ast_body_statement_begin(statement)
	ast_body_layout_suspend()
	retained_rollback(&checkpoint)
	assert_equal(1, retained_record_at(function).layout_active)
	assert_equal(7, ast_body_depth())
	statement = retained_enter(retained_statement, c"layout-cursor.w", 4, 1, 5, c"aggregate")
	ast_body_statement_begin(statement)
	ast_body_layout_suspend()
	ast_body_statement_end(statement)
	retained_leave(statement, 5)
	assert_equal(-1, retained_record_at(function).layout_active)
	retained_leave(function, 5)
	retained_rollback(&entry)
	assert_equal(before, codepos)
	stack_pos = depth
