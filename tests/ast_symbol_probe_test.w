# wbuild: x64
import lib.testing
import compiler.compiler
import lib.process


void test_ast_buffer_read_ahead_preserves_short_reads():
	int reader
	int writer
	assert_equal(0, process_make_pipe(&reader, &writer))
	getchar_reset(reader)
	assert_equal(4, write(writer, c"abcd", 4))
	assert_equal('a', getchar(reader))
	assert_equal(4, getchar_limit[reader])
	assert_equal(4, write(writer, c"efgh", 4))
	close(writer)
	int saved_file = file
	file = reader
	assert_equal(1, ast_expression_refill(0))
	assert_equal(8, getchar_limit[reader])
	for i in range(1, 8): assert_equal('a' + i, getchar(reader))
	assert_equal(0, ast_expression_refill(3))
	assert_equal(5, getchar_pos[reader])
	assert_equal(5, getchar_limit[reader])
	assert_equal(8, getchar_kernel_pos[reader])
	getchar_seek(reader, 3)
	for i in range(3, 8): assert_equal('a' + i, getchar(reader))
	assert_equal(-1, getchar(reader))
	close(reader)
	file = saved_file


void test_ast_buffer_recovers_token_prefix_without_seeking():
	int reader
	int writer
	assert_equal(0, process_make_pipe(&reader, &writer))
	getchar_reset(reader)
	assert_equal(4, write(writer, c"abcd", 4))
	for i in range(4): assert_equal('a' + i, getchar(reader))
	assert_equal(6, write(writer, c"efghij", 6))
	close(writer)
	for i in range(3): assert_equal('e' + i, getchar(reader))
	int saved_file = file
	char* saved_token = token
	int saved_i = token_i
	int saved_start = token_start_offset
	int saved_offset = byte_offset
	int saved_next = nextc
	file = reader
	token = c"cdef"
	token_i = 4
	token_start_offset = 2
	byte_offset = 7
	nextc = 'g'
	ast_expression_retain_token()
	assert_equal(10, getchar_kernel_pos[reader])
	assert_equal(8, getchar_limit[reader])
	assert_equal(5, getchar_pos[reader])
	# The logical next byte is unchanged, and the recovered prefix can
	# be replayed entirely inside the retained window on a nonseekable fd.
	assert_equal('h', getchar(reader))
	getchar_seek(reader, 2)
	for i in range(8): assert_equal('c' + i, getchar(reader))
	assert_equal(-1, getchar(reader))
	close(reader)
	file = saved_file
	token = saved_token
	token_i = saved_i
	token_start_offset = saved_start
	byte_offset = saved_offset
	nextc = saved_next


void test_ast_buffer_recovers_token_and_lookahead_without_seeking():
	int reader
	int writer
	assert_equal(0, process_make_pipe(&reader, &writer))
	getchar_reset(reader)
	assert_equal(4, write(writer, c"abcd", 4))
	for i in range(4): assert_equal('a' + i, getchar(reader))
	assert_equal(6, write(writer, c"efghij", 6))
	close(writer)
	assert_equal('e', getchar(reader))
	getchar_seek(reader, 4)
	int saved_file = file
	char* saved_token = token
	int saved_i = token_i
	int saved_start = token_start_offset
	int saved_offset = byte_offset
	int saved_next = nextc
	file = reader
	token = c"abc"
	token_i = 3
	token_start_offset = 0
	byte_offset = 4
	nextc = 'd'
	ast_expression_retain_token()
	assert_equal(10, getchar_kernel_pos[reader])
	assert_equal(10, getchar_limit[reader])
	assert_equal(4, getchar_pos[reader])
	assert_equal('e', getchar(reader))
	getchar_seek(reader, 0)
	for i in range(10): assert_equal('a' + i, getchar(reader))
	assert_equal(-1, getchar(reader))
	close(reader)
	file = saved_file
	token = saved_token
	token_i = saved_i
	token_start_offset = saved_start
	byte_offset = saved_offset
	nextc = saved_next


void test_ast_pointer_probe_records_are_transactional():
	word_size = __word_size__
	push_basic_types()
	int base = type_push_size(c"ast_pointer_probe_base", word_size)
	expression_ast tree
	tree.types_base = type_count()
	tree.types_count = 0
	tree.pending_buffer_types = 0
	int first = ast_expression_pointer_type(&tree, base, 10)
	int second = ast_expression_pointer_type(&tree, first, 11)
	assert_equal(tree.types_base, first)
	assert_equal(first + 1, second)
	assert_equal(first, ast_expression_pointer_type(&tree, base, 12))
	assert_equal(2, tree.types_count)
	assert_equal(2, type_get_pointer_level(second))
	assert_equal(base, type_lookup(c"ast_pointer_probe_base"))
	ast_expression_restore_types(&tree)
	assert_equal(tree.types_base, type_count())
	assert_equal(-1, type_lookup_next_pointer(base))
	assert_equal(base, type_lookup(c"ast_pointer_probe_base"))
	ast_expression_commit_pointer(&tree, 0)
	ast_expression_commit_pointer(&tree, 1)
	assert_equal(first, type_lookup_next_pointer(base))
	assert_equal(second, type_lookup_next_pointer(first))
	assert1(type_record(first) != &tree.pointer_types[0])
	assert1(type_record(second) != &tree.pointer_types[1])
	# A pending array promotion must not reorder new type records.
	tree.types_base = type_count()
	tree.types_count = 0
	tree.pending_buffer_types = 1
	assert_equal(-1, ast_expression_pointer_type(&tree, second, 13))
	assert_equal(tree.types_base, type_count())
	# Capacity failure leaves only arena-owned records to roll back.
	tree.pending_buffer_types = 0
	int current = second
	for i in range(16):
		current = ast_expression_pointer_type(&tree, current, 20 + i)
		assert1(current >= 0)
	assert_equal(-1, ast_expression_pointer_type(&tree, current, 40))
	ast_expression_restore_types(&tree)
	assert_equal(tree.types_base, type_count())
	assert_equal(-1, type_lookup_next_pointer(second))


void test_ast_composite_probe_records_are_transactional():
	word_size = __word_size__
	push_basic_types()
	int base = type_push_size(c"ast_composite_probe_base", word_size)
	expression_ast tree
	tree.types_base = type_count()
	tree.types_count = 0
	tree.type_names_used = 0
	tree.pending_buffer_types = 0
	int list = ast_expression_composite_type(&tree, type_kind_list, base, -1, 10)
	int ptr = ast_expression_pointer_type(&tree, list, 11)
	int map = ast_expression_composite_type(&tree, type_kind_map, base, list, 12)
	int slice = ast_expression_composite_type(&tree, type_kind_slice, base, -1, 13)
	assert_equal(tree.types_base, list)
	assert_equal(list + 1, ptr)
	assert_equal(list + 2, map)
	assert_equal(list + 3, slice)
	assert_equal(list, ast_expression_composite_type(&tree, type_kind_list, base, -1, 14))
	assert_equal(list, type_lookup(c"list[ast_composite_probe_base]"))
	assert_equal(list, type_lookup_previous_pointer(ptr))
	ast_expression_restore_types(&tree)
	assert_equal(tree.types_base, type_count())
	assert_equal(-1, type_lookup_list(base))
	assert_equal(-1, type_lookup(c"list[ast_composite_probe_base]"))
	for i in range(tree.types_count): ast_expression_commit_pointer(&tree, i)
	# Committed names must survive arena reuse, including pointer names.
	for i in range(tree.type_names_used): tree.type_names[i] = 'x'
	assert_equal(list, type_lookup_list(base))
	assert_equal(map, type_lookup_map(base, list))
	assert_equal(slice, type_lookup_slice(base))
	assert_equal(ptr, type_lookup_next_pointer(list))
	assert_strings_equal(c"list[ast_composite_probe_base]", type_get_name(ptr))
	assert_equal(list, type_lookup(c"list[ast_composite_probe_base]"))


void test_ast_symbol_probe_preserves_usage_and_scope_state():
	verbosity = -1
	filename = 0
	sym_declare(c"ast_probe_local", 1, 'L', 0, 1)
	int outer = sym_index_offset(sym_index_count - 1)
	int outer_index = sym_index_count - 1
	int outer_end = table_pos
	sym_index_lint[outer_index] = 1
	int calls = sym_lookup_calls
	int steps = sym_lookup_steps
	assert_equal(outer, sym_probe(c"ast_probe_local"))
	assert_equal(-1, sym_probe(c"ast_probe_absent"))
	assert_equal(1, cast(int, sym_index_lint[outer_index]))
	assert_equal(calls, sym_lookup_calls)
	assert_equal(steps, sym_lookup_steps)

	sym_declare(c"ast_probe_local", 2, 'L', 1, 1)
	int inner = sym_index_offset(sym_index_count - 1)
	int count = sym_index_count
	assert_equal(inner, sym_probe(c"ast_probe_local"))
	table_pos = outer_end
	assert_equal(outer, sym_probe(c"ast_probe_local"))
	assert_equal(count, sym_index_count)
	assert_equal(count - 1, sym_name_index[c"ast_probe_local"])
	assert_equal(1, cast(int, sym_index_lint[outer_index]))
	assert_equal(calls, sym_lookup_calls)
	assert_equal(outer, sym_lookup(c"ast_probe_local"))
	assert_equal(count - 1, sym_index_count)
	assert_equal(2, cast(int, sym_index_lint[outer_index]))

	# Debugger eval retires scratch bindings without truncating the table.
	int start = table_pos
	sym_declare(c"ast_probe_local", 2, 'L', 1, 1)
	assert_equal(1, sym_index_unbind(start))
	table[start] = '_'
	assert_equal(outer, sym_probe(c"ast_probe_local"))


# Isolated lexer input keeps signature capture tests independent of
# instantiation and proves that parsing unbound names creates no types.
generic_signature_ast* ast_test_capture_signature_kind(char* source, int return_shape):
	if (token == 0):
		token_size = 20
		token = malloc(token_size)
		token[0] = 0
	char* saved = generic_reparse_save()
	int serial = token_serial
	int reader
	int writer
	assert_equal(0, process_make_pipe(&reader, &writer))
	getchar_reset(reader)
	assert_equal(strlen(source), write(writer, source, strlen(source)))
	close(writer)
	file = reader
	filename = c"signature capture test"
	byte_offset = 0
	line_number = 0
	column_number = 0
	tab_level = 0
	token_newline = 0
	nextc = 0
	nextc = get_character()
	get_token()
	int before = type_count()
	generic_signature_ast* signature = 0
	if (return_shape):
		generic_type_ast* result = generic_type_ast_capture_return()
		assert_equal(0, strcmp(c"next", token))
		if (result != 0):
			signature = new generic_signature_ast
			signature.result = result
			signature.parameters = 0
			signature.count = 0
	else: signature = generic_signature_ast_capture(c"T", 2)
	assert_equal(before, type_count())
	close(reader)
	generic_reparse_restore(saved)
	token_serial = serial
	return signature


generic_signature_ast* ast_test_capture_signature(char* source):
	return ast_test_capture_signature_kind(source, 0)


void test_ast_generic_return_capture_and_recovery():
	generic_signature_ast* signature = ast_test_capture_signature_kind(c"Box[list[T*], U]** next\n", 1)
	assert1(signature != 0)
	generic_type_ast* result = signature.result
	assert_equal(1, result.application)
	assert_equal(2, result.stars)
	assert_equal(0, strcmp(c"Box", result.name))
	assert_equal(0, strcmp(c"list", result.first.name))
	assert_equal(1, result.first.first.stars)
	assert_equal(0, strcmp(c"U", result.first.next.name))
	generic_signature_ast_free(signature)
	assert1(ast_test_capture_signature_kind(c"Box[const T]* next\n", 1) == 0)
	assert1(ast_test_capture_signature_kind(c"Box[Pair[T[2]]]* next\n", 1) == 0)
	assert1(ast_test_capture_signature_kind(c"Box[T, U, V, A, B, C, D, E, F]* next\n", 1) == 0)


void test_ast_generic_signature_capture():
	generic_signature_ast* signature = ast_test_capture_signature(c"(map[char*, list[T*]] values, T** other, FutureType):\n")
	assert1(signature != 0)
	assert_equal(3, signature.count)
	assert_equal(0, strcmp(c"T", signature.result.name))
	assert_equal(2, signature.result.stars)
	generic_type_ast* parameter = signature.parameters
	assert_equal(0, strcmp(c"map", parameter.name))
	assert_equal(0, strcmp(c"char", parameter.first.name))
	assert_equal(1, parameter.first.stars)
	assert_equal(0, strcmp(c"list", parameter.second.name))
	assert_equal(0, strcmp(c"T", parameter.second.first.name))
	assert_equal(1, parameter.second.first.stars)
	parameter = parameter.next
	assert_equal(2, parameter.stars)
	assert_equal(0, strcmp(c"FutureType", parameter.next.name))
	assert1(parameter.next.next == 0)
	generic_signature_ast_free(signature)
	signature = ast_test_capture_signature(c"():\n")
	assert1(signature != 0)
	assert_equal(0, signature.count)
	assert1(signature.parameters == 0)
	generic_signature_ast_free(signature)
	signature = ast_test_capture_signature(c"(T,):\n")
	assert1(signature != 0)
	assert_equal(1, signature.count)
	generic_signature_ast_free(signature)
	assert1(ast_test_capture_signature(c"(T value = 3):\n") == 0)
	assert1(ast_test_capture_signature(c"(T[2] values):\n") == 0)
	signature = ast_test_capture_signature(c"(pair[T, U*]* value, T*[] values, box[T][] boxes):\n")
	assert1(signature != 0)
	parameter = signature.parameters
	assert_equal(1, parameter.application)
	assert_equal(1, parameter.stars)
	assert_equal(0, strcmp(c"T", parameter.first.name))
	assert_equal(0, strcmp(c"U", parameter.first.next.name))
	assert_equal(1, parameter.first.next.stars)
	parameter = parameter.next
	assert_equal(2, parameter.application)
	assert_equal(1, parameter.first.stars)
	parameter = parameter.next
	assert_equal(2, parameter.application)
	assert_equal(1, parameter.first.application)
	assert_equal(0, strcmp(c"box", parameter.first.name))
	generic_signature_ast_free(signature)
	assert1(ast_test_capture_signature(c"(const T* value):\n") == 0)
	assert1(ast_test_capture_signature(c"(T... values):\n") == 0)
	assert1(ast_test_capture_signature(c"(map[T, ] values):\n") == 0)


void test_ast_generic_inference_shapes_without_placeholders():
	word_size = __word_size__
	push_basic_types()
	int record = type_push_size(c"ast_inference_record", word_size)
	int ptr = type_get_next_pointer(record)
	char* names = malloc(__word_size__)
	save_ptr(names, cast(int, c"T"))
	int def = generic_def_add(c"ast_inference_shapes", 0, c"no source file needed", 0, 1, 1, 1, cast(int, names))
	generic_signature_ast* signature = ast_test_capture_signature(c"(T a, T** b, int c, ast_inference_record* d):\n")
	assert1(signature != 0)
	generic_defs[def].signature_ast = signature
	int before = type_count()
	char* placeholders = generic_infer_placeholders
	char* block = generic_infer_shapes(def)
	assert_equal(4, load_ptr(block))
	assert_equal(0, load_ptr(block + __word_size__))
	assert_equal(0, load_ptr(block + 2 * __word_size__))
	assert_equal(0, load_ptr(block + 3 * __word_size__))
	assert_equal(2, load_ptr(block + 4 * __word_size__))
	assert_equal(-1, load_ptr(block + 5 * __word_size__))
	assert_equal(type_lookup(c"int"), load_ptr(block + 6 * __word_size__))
	assert_equal(-1, load_ptr(block + 7 * __word_size__))
	assert_equal(ptr, load_ptr(block + 8 * __word_size__))
	assert1(block == generic_infer_shapes(def))
	assert_equal(before, type_count())
	assert1(placeholders == generic_infer_placeholders)
	# Composite parameter references are opaque and need no placeholders.
	generic_defs[def].signature_ast = ast_test_capture_signature(c"(list[T] a, map[int, list[T*]] b, T[] c, set[T]* d):\n")
	char* opaque = generic_infer_ast_shapes(def)
	assert1(opaque != 0)
	assert_equal(4, load_ptr(opaque))
	for i in range(4):
		assert_equal(-2, load_ptr(opaque + __word_size__ + i * 2 * __word_size__))
		assert_equal(0, load_ptr(opaque + 2 * __word_size__ + i * 2 * __word_size__))
	free(opaque)
	assert_equal(before, type_count())
	assert1(placeholders == generic_infer_placeholders)
	generic_signature_ast_free(generic_defs[def].signature_ast)
	generic_defs[def].signature_ast = ast_test_capture_signature(c"(AstMissingType value):\n")
	assert1(generic_infer_ast_shapes(def) == 0)
	assert_equal(before, type_count())
	generic_signature_ast_free(generic_defs[def].signature_ast)
	generic_defs[def].signature_ast = signature


void ast_test_prepared_expression(char* source, int accepted):
	word_size = __word_size__
	push_basic_types()
	if (token == 0):
		token_size = 20
		token = malloc(token_size)
		token[0] = 0
	char* saved = generic_reparse_save()
	int serial = token_serial
	int mode = ast_expressions_mode
	int reader
	int writer
	assert_equal(0, process_make_pipe(&reader, &writer))
	getchar_reset(reader)
	assert_equal(strlen(source), write(writer, source, strlen(source)))
	close(writer)
	file = reader
	filename = c"AST preparation test"
	byte_offset = 0
	line_number = 0
	column_number = 0
	tab_level = 0
	token_newline = 0
	nextc = 0
	nextc = get_character()
	get_token()
	ast_expressions_mode = 2
	int before_code = codepos
	int before_types = type_count()
	int before_emitted = ast_expressions_emitted
	expression_ast tree
	int root = ast_expression_prepare_at(&tree, token_start_offset, 1)
	assert_equal(before_code, codepos)
	assert_equal(before_emitted, ast_expressions_emitted)
	assert_equal(before_types, type_count())
	if (accepted):
		assert1(root >= 0)
		assert_equal('*', tree.op[root])
		assert_equal(6, tree.value[tree.left[root]])
		assert_equal(7, tree.value[tree.right[root]])
		assert_equal(tree.end_offset, token_start_offset)
		# Backend lowering must leave the virtual source boundary alone.
		int end_serial = token_serial
		char* end_token = strclone(token)
		be_notes_reset()
		assert_equal(3, emit_prepared_expression_ast(&tree, root))
		assert1(codepos > before_code)
		assert_equal(end_serial, token_serial)
		assert_equal(tree.end_offset, token_start_offset)
		assert_strings_equal(end_token, token)
		assert_equal(before_emitted, ast_expressions_emitted)
		free(end_token)
		ast_expression_finish_prepared(&tree)
		assert_strings_equal(c"next", token)
		assert_equal(before_emitted + 1, ast_expressions_emitted)
		codepos = before_code
		ast_expressions_emitted = before_emitted
		be_notes_reset()
	else:
		assert_equal(-1, root)
		assert_equal(0, token_start_offset)
		assert_strings_equal(c"6", token)
	close(reader)
	generic_reparse_restore(saved)
	token_serial = serial
	ast_expressions_mode = mode


void test_ast_preparation_emission_and_source_completion():
	ast_test_prepared_expression(c"6 * 7\nnext\n", 1)
	ast_test_prepared_expression(c"6 + ast_preparation_missing_name\n", 0)


void test_ast_constant_folder_walks_children():
	constant_ast six = constant_ast_literal(6, 0, 1)
	constant_ast seven = constant_ast_literal(7, 4, 5)
	constant_ast product = constant_ast_literal(0, 0, 5)
	product.op = '*'
	product.left = &six
	product.right = &seven
	constant_ast two = constant_ast_literal(2, 8, 9)
	constant_ast sum = constant_ast_literal(0, 0, 9)
	sum.op = '+'
	sum.left = &product
	sum.right = &two
	int before_code = codepos
	assert_equal(44, constant_ast_fold(&sum))
	constant_ast folded = constant_ast_operator('+', 0, &product, &two)
	assert_equal(44, folded.value)
	assert_equal(0, folded.op)
	assert1(folded.left == 0 && folded.right == 0)
	assert_equal(0, folded.start_offset)
	assert_equal(9, folded.end_offset)
	assert_equal(before_code, codepos)


void ast_test_stack_binding_snapshot(int scope, int expected_words):
	word_size = __word_size__
	word_size_log2 = 2
	if (word_size == 8): word_size_log2 = 3
	push_basic_types()
	int type = type_lookup(c"int")
	int saved_table = table_pos
	int saved_stack = stack_pos
	int saved_args = number_of_args
	int saved_mode = ast_expressions_mode
	int saved_emitted = ast_expressions_emitted
	int saved_verbosity = verbosity
	char* saved_identifier = last_identifier
	char[128] identifier
	identifier[0] = 0
	last_identifier = &identifier[0]
	verbosity = -1
	stack_pos = 7
	number_of_args = 5
	sym_declare(c"ast_bound_operand", type, scope, 2, 1)
	int sym = table_pos - symbol_data_size
	if (token == 0):
		token_size = 20
		token = malloc(token_size)
		token[0] = 0
	char* saved = generic_reparse_save()
	int serial = token_serial
	int reader
	int writer
	assert_equal(0, process_make_pipe(&reader, &writer))
	getchar_reset(reader)
	char* source = c"ast_bound_operand\nnext\n"
	assert_equal(strlen(source), write(writer, source, strlen(source)))
	close(writer)
	file = reader
	filename = c"AST stack binding test"
	byte_offset = 0
	line_number = 0
	column_number = 0
	tab_level = 0
	token_newline = 0
	nextc = 0
	nextc = get_character()
	get_token()
	ast_expressions_mode = 2
	expression_ast tree
	int root = ast_expression_prepare_at(&tree, token_start_offset, 1)
	assert1(root >= 0)
	assert1(tree.binding_name[root] >= 0)
	assert_strings_equal(c"ast_bound_operand", &tree.text[tree.binding_name[root]])
	# Simulate reuse of the symbol's storage and a different frame context.
	# The operand keeps its original binding, but follows the current
	# temporary stack depth when computing the runtime address.
	char* original_name = strclone(table + tree.value[root])
	for i in range(strlen(original_name)): table[tree.value[root] + i] = 'x'
	table[sym + 1] = 'D'
	save_int(table + sym + 2, 1000)
	save_int(table + sym + 6, 0)
	number_of_args = 99
	stack_pos = 9
	int before = codepos
	be_notes_reset()
	assert_equal(type, emit_prepared_expression_ast(&tree, root))
	assert_strings_equal(c"ast_bound_operand", last_identifier)
	int length = codepos - before
	assert1(length > 0)
	char* actual = malloc(length)
	for i in range(length): actual[i] = code[before + i]
	codepos = before
	be_notes_reset()
	be_lea_acc_wstack(expected_words * __word_size__)
	assert_equal(length, codepos - before)
	assert_bytes_equal(actual, code + before, length)
	free(actual)
	ast_expression_finish_prepared(&tree)
	assert_strings_equal(c"next", token)
	strcpy(table + tree.value[root], original_name)
	free(original_name)
	table[sym + 1] = scope
	save_int(table + sym + 2, 2)
	save_int(table + sym + 6, type)
	table_pos = saved_table
	sym_index_sync()
	codepos = before
	be_notes_reset()
	stack_pos = saved_stack
	number_of_args = saved_args
	ast_expressions_mode = saved_mode
	ast_expressions_emitted = saved_emitted
	verbosity = saved_verbosity
	close(reader)
	generic_reparse_restore(saved)
	token_serial = serial
	last_identifier = saved_identifier


void test_ast_stack_operands_own_their_bindings():
	ast_test_stack_binding_snapshot('L', 6)
	ast_test_stack_binding_snapshot('A', 13)
