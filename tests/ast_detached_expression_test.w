# wbuild: x64
import lib.testing
import lib.process
import repl.core


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
	repl_init()
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
