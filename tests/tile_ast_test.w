# wbuild: x64
import lib.testing
import lib.process
import lib.str
import repl.core


tile_program* tile_test_parse(char* source, int reject = 0):
	char* saved = generic_reparse_save()
	int serial = token_serial
	int reader
	int writer
	assert_equal(0, process_make_pipe(&reader, &writer))
	getchar_reset(reader)
	assert_equal(strlen(source), write(writer, source, strlen(source)))
	close(writer)
	file = reader
	filename = c"detached-tile.w"
	retained_source_begin(filename)
	byte_offset = 0
	line_number = 0
	column_number = 0
	tab_level = 0
	token_newline = 0
	nextc = 0
	nextc = get_character()
	get_token()
	if (reject):
		repl_checkpoint()
		repl_recovery = 1
		if (repl_setjmp(repl_jump_buffer)):
			repl_recovery = 0
			repl_rollback()
			close(reader)
			generic_reparse_restore(saved)
			token_serial = serial
			return 0
	int owner = retained_enter(retained_statement, filename, 0, 1, 1, c"tile")
	int before = codepos
	int body = ptx_body_pos
	int module = ptx_module_pos
	int depth = stack_pos
	int symbols = table_pos
	int isa = target_isa
	int loops = loop_depth
	int switches = switch_depth
	tile_program* program = tile_parse_program()
	repl_recovery = 0
	assert_equal(0, reject)
	assert_equal(before, codepos)
	assert_equal(body, ptx_body_pos)
	assert_equal(module, ptx_module_pos)
	assert_equal(depth, stack_pos)
	assert_equal(symbols, table_pos)
	assert_equal(isa, target_isa)
	assert_equal(loops, loop_depth)
	assert_equal(switches, switch_depth)
	assert_equal(cast(int, program), cast(int, retained_record_at(owner).tile_payload))
	retained_leave(owner, token_start_offset)
	close(reader)
	generic_reparse_restore(saved)
	token_serial = serial
	return program


void test_tile_body_is_owned_and_detached():
	repl_init()
	ast_expressions_mode = 2
	ast_retain_mode = 1
	ast_emit_retained_mode = 1
	int symbols = table_pos
	int integer = type_lookup(c"int")
	int pointer = type_get_next_pointer(float32_type)
	sym_declare(c"n", integer, 'L', 0, 1)
	sym_declare(c"a", pointer, 'L', 1, 1)
	sym_declare(c"b", pointer, 'L', 2, 1)
	sym_declare(c"c", pointer, 'L', 3, 1)
	retained_checkpoint entry
	retained_capture(&entry)
	tile_program* program = tile_test_parse(c"gpu[1024] for tile in range(n):\n\tvalue := a[tile] + b[tile]\n\tif n > 0:\n\t\tint count = 1\n\t\tfor int j in range(2):\n\t\t\tint count = j + 2\n\t\t\tc[tile] = value + count\n\tc[tile] = value\n")
	assert_equal(1024, program.width)
	assert_equal(5, program.capture_count)
	assert_equal(retained_tile_statement, retained_node_kind(program.body.retained_id))
	assert_equal(program.retained_owner, retained_record_at(program.body.retained_id).parent)
	assert_equal(retained_tile_expression, retained_node_kind(program.body.left.retained_id))
	assert_equal(program.body.retained_id, retained_record_at(program.body.left.retained_id).parent)
	tile_node* branch = program.body.next
	tile_node* outer = branch.body
	tile_node* loop = outer.next
	tile_node* inner = loop.body
	assert1(outer.binding != inner.binding)
	assert_strings_equal(c"count", outer.binding.name)
	assert_strings_equal(c"count", inner.binding.name)
	assert1(inner.next.right.right.binding == inner.binding)
	assert1(program.body.next.next.right.binding == program.body.binding)
	# A later parse recycles the tokenizer and its source buffer. Retracting
	# it must preserve the earlier body's complete owned tree and captures.
	retained_checkpoint checkpoint
	retained_capture(&checkpoint)
	tile_test_parse(c"gpu[16] for other in range(n):\n\tc[other] = a[other] * 0.5\n")
	assert1(retained_node_count() > checkpoint.nodes)
	retained_rollback(&checkpoint)
	assert_equal(checkpoint.nodes, retained_node_count())
	assert_equal(checkpoint.text, retained_arena_offset)
	assert_equal(checkpoint.arena_chunk, retained_arena_index)
	int failed_code = codepos
	int failed_ptx = ptx_module_pos
	int failed_stack = stack_pos
	assert1(tile_test_parse(c"gpu[16] for other in range(n):\n\tint local = 1\n\tc[other] = absent_tile_name\n", 1) == 0)
	assert_equal(failed_code, codepos)
	assert_equal(failed_ptx, ptx_module_pos)
	assert_equal(failed_stack, stack_pos)
	retained_rollback(&checkpoint)
	# A flat arithmetic chain must hit a diagnostic before recursive tree
	# consumers could overflow their call stack.
	char* deep = cast(char*, malloc(2048))
	strcpy(deep, c"gpu[16] for other in range(n):\n\tc[other] = 0")
	int offset = strlen(deep)
	for i in range(200):
		deep[offset] = '+'
		deep[offset + 1] = '1'
		offset += 2
	deep[offset] = 10
	deep[offset + 1] = 0
	assert1(tile_test_parse(deep, 1) == 0)
	free(deep)
	retained_rollback(&checkpoint)
	# A successful parse after the error must have fresh lexical bindings.
	tile_program* recovered = tile_test_parse(c"gpu[16] for other in range(n):\n\tlocal := a[other]\n\tc[other] = local\n")
	tile_analyze(recovered)
	assert_equal(1, recovered.analyzed)
	retained_rollback(&checkpoint)
	# Leave the host local environment too. Tile semantic analysis and PTX
	# lowering use the owned bindings, not reused symbol-table offsets.
	table_pos = symbols
	sym_index_sync()
	sym_declare(c"unrelated", integer, 'L', 99, 1)
	int before = codepos
	int body = ptx_body_pos
	int module = ptx_module_pos
	int depth = stack_pos
	tile_analyze(program)
	assert_equal(before, codepos)
	assert_equal(body, ptx_body_pos)
	assert_equal(module, ptx_module_pos)
	assert_equal(depth, stack_pos)
	assert_equal(1, program.analyzed)
	assert_equal(1, program.body.binding.rank)
	tile_ptx_emit(program)
	assert1(ptx_module_pos > module)
	assert_equal(before, codepos)
	assert_equal(depth, stack_pos)
	assert1(contains(ptx_module_buf, c"ld.f32"))
	assert1(contains(ptx_module_buf, c"st.f32"))
	retained_rollback(&entry)
	table_pos = symbols
	sym_index_sync()
