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
generic_signature_ast* ast_test_capture_signature(char* source):
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
	generic_signature_ast* signature = generic_signature_ast_capture(c"T", 2)
	assert_equal(before, type_count())
	close(reader)
	generic_reparse_restore(saved)
	token_serial = serial
	return signature


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
