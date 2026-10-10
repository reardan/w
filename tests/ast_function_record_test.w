# wbuild: x64
import lib.testing
import lib.process
import repl.core


int scalar_record_initialized


void scalar_record_init():
	if (scalar_record_initialized): return
	repl_init()
	ast_expressions_mode = 2
	ast_retain_mode = 1
	ast_emit_retained_mode = 1
	scalar_record_initialized = 1


# Only the owned main function AST survives this closed input and restored
# tokenizer. The snapshots prove parsing did not start lowering the body.
function_ast* scalar_record_parse(char* source, int reject = 0):
	char* saved = generic_reparse_save()
	int serial = token_serial
	int reader
	int writer
	assert_equal(0, process_make_pipe(&reader, &writer))
	getchar_reset(reader)
	assert_equal(strlen(source), write(writer, source, strlen(source)))
	close(writer)
	file = reader
	filename = c"detached-scalar-function.w"
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
	int before = codepos
	int body = ptx_body_pos
	int module = ptx_module_pos
	int depth = stack_pos
	int symbols = table_pos
	int isa = target_isa
	int loops = loop_depth
	int switches = switch_depth
	function_ast* function = ast_record_scalar_function()
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
	assert1(function.owned_body != 0)
	assert1(retained_record_at(function.owned_body.retained_id).function_payload == cast(char*, function))
	close(reader)
	generic_reparse_restore(saved)
	token_serial = serial
	return function


int scalar_record_emit(function_ast* function):
	int serial = token_serial
	int offset = token_start_offset
	char* spelling = strclone(token)
	int symbols = table_pos
	int depth = stack_pos
	int loops = loop_depth
	int switches = switch_depth
	int module = ptx_module_pos
	dwarf_notes_ensure()
	int dwarf_functions = dwarf_funcs.length
	int dwarf_event_count = dwarf_events.length
	int dwarf_leave_count = dwarf_leaves.length
	int dwarf_blocks_count = dwarf_blocks.length
	int dwarf_depth = dwarf_open_depth
	int dwarf_open = dwarf_open_func
	int pending_symbol = dwarf_params_symbol
	int pending = dwarf_pending_params.length
	# Pending parameters belong to a later registered function. A standalone
	# function must not consume them or relabel the preceding debug symbol.
	dwarf_pending_params.push(-123)
	int start = emit_recorded_scalar_function(function)
	assert_equal(serial, token_serial)
	assert_equal(offset, token_start_offset)
	assert_strings_equal(spelling, token)
	assert_equal(symbols, table_pos)
	assert_equal(depth, stack_pos)
	assert_equal(loops, loop_depth)
	assert_equal(switches, switch_depth)
	assert_equal(module, ptx_module_pos)
	assert_equal(dwarf_functions, dwarf_funcs.length)
	assert_equal(dwarf_event_count, dwarf_events.length)
	assert_equal(dwarf_leave_count, dwarf_leaves.length)
	assert_equal(dwarf_blocks_count, dwarf_blocks.length)
	assert_equal(dwarf_depth, dwarf_open_depth)
	assert_equal(dwarf_open, dwarf_open_func)
	assert_equal(pending_symbol, dwarf_params_symbol)
	assert_equal(pending + 1, dwarf_pending_params.length)
	assert_equal(-123, dwarf_pending_params.pop())
	free(spelling)
	return start


type scalar_record_pair = fn(int, int) -> int
type scalar_record_one = fn(int) -> int
type scalar_record_none = fn() -> int


int scalar_record_reject_lowering(function_ast* function):
	repl_checkpoint()
	repl_recovery = 1
	if (repl_setjmp(repl_jump_buffer)):
		repl_recovery = 0
		repl_rollback()
		return 1
	emit_recorded_scalar_function(function)
	repl_recovery = 0
	return 0


void test_recorded_function_outlives_parser_and_symbols():
	scalar_record_init()
	retained_checkpoint entry
	retained_capture(&entry)
	int symbols = table_pos
	int before = codepos
	function_ast* fold = scalar_record_parse(c"int fold(int n, int bias):\n\tint acc = bias\n\tint bound = n\n\tfor int i in range(1, bound):\n\t\tbound = 0\n\t\tif i == 2:\n\t\t\tint acc = 100\n\t\t\tacc += 1\n\t\telse:\n\t\t\tacc += i * 2\n\twhile n > 0:\n\t\tn -= 1\n\t\tif n == 2:\n\t\t\treturn acc + 7\n\treturn acc\n")
	function_ast* arithmetic = scalar_record_parse(c"int arithmetic(int x, int y):\n\tint z = +x * 3\n\tz -= y\n\tz *= 2\n\tif (x > y && x >= y) || (x == y && !(x != y)):\n\t\tz += x / y + x % y\n\telse:\n\t\tz = -z\n\tif false && (1 / 0):\n\t\treturn 99\n\tif true || (1 / 0):\n\t\tif x <= y:\n\t\t\treturn z + 1\n\treturn z\n")
	assert_equal(before, codepos)
	assert_equal(ast_function_native, fold.kind)
	assert_equal(2, fold.parameter_count)
	assert_strings_equal(c"fold", fold.name)
	assert_strings_equal(c"detached-scalar-function.w", fold.owned_body.source_file)
	function_node_ast* outer = fold.owned_body.statements
	function_node_ast* loop = outer.next.next
	function_node_ast* branch = loop.body.next
	function_node_ast* inner = branch.body
	assert1(inner.binding != outer.binding)
	assert_strings_equal(c"acc", inner.binding.name)
	assert1(inner.next.binding == inner.binding)
	assert1(branch.otherwise.binding == outer.binding)
	assert_equal(retained_function, retained_node_kind(fold.owned_body.retained_id))
	assert_equal(fold.owned_body.retained_id, retained_record_at(outer.retained_id).parent)
	# Replacing symbol and token state must not affect either owned function.
	table_pos = symbols
	sym_index_sync()
	sym_declare(c"unrelated", type_lookup(c"int"), 'L', 99, 1)
	tokenizer_set_token_text(c"discarded_parser_state", 22)
	int fold_start = scalar_record_emit(fold)
	int arithmetic_start = scalar_record_emit(arithmetic)
	scalar_record_pair* run_fold = cast(scalar_record_pair*, code + fold_start)
	scalar_record_pair* run_arithmetic = cast(scalar_record_pair*, code + arithmetic_start)
	assert_equal(26, run_fold(5, 3))
	assert_equal(13, run_fold(3, 4))
	assert_equal(8, run_fold(0, 8))
	assert_equal(49, run_arithmetic(9, 4))
	assert_equal(-5, run_arithmetic(4, 9))
	assert_equal(18, run_arithmetic(4, 4))
	# A second lowering uses the same tree after unrelated backend activity.
	int repeat = scalar_record_emit(fold)
	run_fold = cast(scalar_record_pair*, code + repeat)
	assert_equal(26, run_fold(5, 3))
	codepos = before
	be_notes_reset()
	table_pos = symbols
	sym_index_sync()
	retained_rollback(&entry)


void test_recorded_function_rollback_preserves_earlier_tree():
	scalar_record_init()
	retained_checkpoint entry
	retained_capture(&entry)
	int before = codepos
	function_ast* kept = scalar_record_parse(c"int sum(int n):\n\tint total = 0\n\tfor int i in range(n):\n\t\ttotal += i\n\tif total < 1:\n\t\treturn 7\n\telse:\n\t\treturn total\n")
	retained_checkpoint checkpoint
	retained_capture(&checkpoint)
	scalar_record_parse(c"int discarded(int other):\n\treturn other * 99\n")
	assert1(retained_node_count() > checkpoint.nodes)
	retained_rollback(&checkpoint)
	assert_equal(checkpoint.nodes, retained_node_count())
	assert_equal(checkpoint.text, retained_arena_offset)
	assert_equal(checkpoint.arena_chunk, retained_arena_index)
	assert1(scalar_record_parse(c"int broken(int n):\n\tint value = absent_binding\n\treturn n\n", 1) == 0)
	assert_equal(before, codepos)
	retained_rollback(&checkpoint)
	# A failed parse and arena suffix reuse cannot rewrite the kept bindings.
	scalar_record_parse(c"int recovered(int n):\n\tint total = n + 1\n\treturn total\n")
	retained_rollback(&checkpoint)
	assert_strings_equal(c"sum", kept.name)
	int start = scalar_record_emit(kept)
	scalar_record_one* run = cast(scalar_record_one*, code + start)
	assert_equal(7, run(0))
	assert_equal(10, run(5))
	codepos = before
	be_notes_reset()
	retained_rollback(&entry)


void test_recorded_function_requires_return_before_emission():
	scalar_record_init()
	retained_checkpoint entry
	retained_capture(&entry)
	int before = codepos
	function_ast* incomplete = scalar_record_parse(c"int incomplete(int n):\n\tif n > 0:\n\t\treturn n\n")
	assert_equal(1, scalar_record_reject_lowering(incomplete))
	assert_equal(before, codepos)
	assert_equal(0, incomplete.owned_body.analyzed)
	function_ast* constant = scalar_record_parse(c"int constant() { return 42 }\n")
	assert_equal(0, constant.parameter_count)
	int frame = be_frame_active
	be_frame_active = 1
	assert_equal(1, scalar_record_reject_lowering(constant))
	assert_equal(before, codepos)
	assert_equal(0, constant.owned_body.analyzed)
	be_frame_active = frame
	int start = scalar_record_emit(constant)
	scalar_record_none* run = cast(scalar_record_none*, code + start)
	assert_equal(42, run())
	codepos = before
	be_notes_reset()
	retained_rollback(&entry)


void test_recorded_function_rejects_unsupported_syntax_without_emission():
	scalar_record_init()
	retained_checkpoint entry
	retained_capture(&entry)
	int before = codepos
	assert1(scalar_record_parse(c"int duplicate(int n, int n): return n\n", 1) == 0)
	retained_rollback(&entry)
	assert1(scalar_record_parse(c"int duplicate():\n\tint n = 1\n\tint n = 2\n\treturn n\n", 1) == 0)
	retained_rollback(&entry)
	assert1(scalar_record_parse(c"int fractional(): return 1.5\n", 1) == 0)
	retained_rollback(&entry)
	assert1(scalar_record_parse(c"int too_large(): return 2147483648\n", 1) == 0)
	retained_rollback(&entry)
	assert1(scalar_record_parse(c"int unsupported(int n):\n\tn++\n\treturn n\n", 1) == 0)
	retained_rollback(&entry)
	assert1(scalar_record_parse(c"int empty():\nreturn 1\n", 1) == 0)
	retained_rollback(&entry)
	assert1(scalar_record_parse(c"int missing_brace() { return 1\n", 1) == 0)
	retained_rollback(&entry)
	# A flat expression chain parses iteratively but must still be bounded
	# before recursive retained walkers or lowering can consume it.
	char* deep = cast(char*, malloc(1024))
	strcpy(deep, c"int deep(): return 0")
	int offset = strlen(deep)
	for i in range(120):
		deep[offset] = '+'
		deep[offset + 1] = '1'
		offset += 2
	deep[offset] = 10
	deep[offset + 1] = 0
	assert1(scalar_record_parse(deep, 1) == 0)
	free(deep)
	retained_rollback(&entry)
	assert_equal(before, codepos)
	function_ast* valid = scalar_record_parse(c"int after_errors(int n): return n + 3\n")
	int start = scalar_record_emit(valid)
	scalar_record_one* run = cast(scalar_record_one*, code + start)
	assert_equal(42, run(39))
	codepos = before
	be_notes_reset()
	retained_rollback(&entry)
