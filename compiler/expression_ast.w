# Production AST island: parenthesized scalar expressions. Each
# attempt owns this bounded arena on its stack; unsupported syntax and
# REPL error recovery cannot leave allocated nodes or compiler state behind.
# Node IDs are arena indices, -1 is failure. Literal nodes carry their
# source byte offset until the committed diagnostic/decoding pass fills value.
# result_type retains the streaming type convention (lvalue, value or
# untyped constant); symbol records and their name offsets remain valid
# only for this parse/emit operation, never across declarations/REPL entries.
# Float literals store two 32-bit halves for host-independent decoding.
# Call nodes use left for the first argument and next_arg links on argument
# roots; those links do not change a nested call's own argument list.
# Logical chains use the same sibling links, with a separate node for
# each source-level chain (parenthesized subchains keep their boundary).
struct expression_ast:
	int count
	int end_offset
	int cast_depth
	int whole_expression
	int final_token_offset
	int text_used
	int types_base
	int types_count
	int type_names_used
	int pending_buffer_types
	int readonly
	type_rec[16] pointer_types
	int[16] pointer_offsets
	int[16] pointer_bases
	char[2048] type_names
	char[4096] text
	int[128] op
	int[128] left
	int[128] right
	int[128] offset
	int[128] value
	int[128] result_type
	int[128] high
	int[128] next_arg
	int[128] in_cast
	int[128] symbol
	int[128] generic_parameters
	int[128] generic_signature
	int[128] generic_offset
	int[128] generic_instance
	int[128] generic_arity


int ast_expressions_mode
int ast_expressions_emitted
int ast_roots_emitted
int ast_roots_fallback
int ast_audit_mode
int ast_required_mode


# Container methods share the streaming helper-call lowering. Bit 7
# chooses the aggregate-copy/address helper after types are known.
char* ast_expression_method_helper(int method):
	method = method & 255
	if (method == 11): return c"__w_map_remove"
	if (method == 12): return c"__w_set_add"
	if (method == 13): return c"__w_map_free"
	if (method == 14): return c"__w_map_get"
	if (method == 15): return c"__w_map_get_or"
	if (method == 142): return c"__w_map_get_addr"
	if (method == 143): return c"__w_map_get_or_addr"
	if (method == 129): return c"__w_list_push_bytes"
	if (method == 130): return c"__w_list_pop_addr"
	if (method == 131): return c"__w_list_insert_bytes"
	if (method == 1): return c"__w_list_push"
	if (method == 2): return c"__w_list_pop"
	if (method == 3): return c"__w_list_insert"
	if (method == 4): return c"__w_list_remove"
	if (method == 5): return c"__w_list_clear"
	if (method == 6): return c"__w_list_free"
	if (method == 20): return c"__w_list_sort"
	if (method == 21): return c"__w_list_sorted"
	if (method == 22): return c"__w_list_sum"
	if (method == 23): return c"__w_list_min"
	if (method == 24): return c"__w_list_max"
	if (method == 25): return c"__w_list_reverse"
	if (method == 26): return c"__w_list_reversed"
	if (method == 27): return c"__w_list_count"
	if (method == 28): return c"__w_list_index"
	return 0


char* ast_expression_contains_helper(int kind):
	if (kind == 1): return c"__w_map_contains"
	if (kind == 2): return c"__w_set_contains"
	if (kind == 3): return c"__w_list_contains_cstr"
	return c"__w_list_contains"


# Speculative pointer records borrow their names and live in the arena.
# They have no fields or parameter arrays, so their nested descriptors
# are never accessed. Remove every temporary table entry before any
# committed literal diagnostic can unwind this stack frame.
int ast_expression_pointer_type(expression_ast* tree, int base, int offset):
	int existing = type_lookup_next_pointer(base)
	if (existing >= 0): return existing
	# Array promotion can intern a slice-value type during emission.
	# Preserve type registration order until it too has a replay event.
	if (tree.pending_buffer_types || (tree.types_count == 16)): return -1
	int i = tree.types_count
	type_rec* rec = &tree.pointer_types[i]
	rec.name = type_get_name(type_canonical(base))
	rec.num_fields = 0
	rec.total_size = word_size
	rec.pointer_level = type_get_pointer_level(base) + 1
	rec.alias_target = -1
	rec.kind = 0
	rec.fn_return_type = -1
	rec.fn_param_count = -1
	rec.decl_file_index = -1
	rec.decl_line = 0
	rec.decl_column = 0
	tree.pointer_offsets[i] = offset
	tree.pointer_bases[i] = base
	tree.types_count = i + 1
	int result = type_count()
	type_records.push(cast(int, rec))
	return result


void ast_expression_restore_types(expression_ast* tree):
	if (tree.types_count == 0): return
	type_table_truncate(tree.types_base)
	# A nested type-name lookup may have indexed temporary records.
	# Discard the index immediately: committed records can otherwise
	# overtake a length-based rebuild marker before the next lookup.
	type_name_index = 0
	type_index_indexed = 0


void ast_expression_commit_pointer(expression_ast* tree, int i):
	type_rec* rec = &tree.pointer_types[i]
	if (rec.kind == type_kind_function): return
	int actual
	if (rec.kind == type_kind_slice_value): actual = type_push_slice_value(rec.alias_target)
	else if (rec.kind == type_kind_slice): actual = type_push_slice(rec.alias_target)
	else if (rec.kind == type_kind_map): actual = type_push_map(rec.alias_target, rec.fn_return_type)
	else if (rec.kind == type_kind_set): actual = type_push_set(rec.alias_target)
	else if (rec.kind == type_kind_list): actual = type_push_list(rec.alias_target)
	else:
		# A newly staged composite's name belongs to this arena. Reuse the
		# committed base record's persistent name for its pointer record.
		char* name = type_get_name(type_canonical(tree.pointer_bases[i]))
		actual = type_push_pointer(name, rec.total_size, rec.pointer_level)
	assert1(actual == tree.types_base + i)


int expression_ast_add(expression_ast* tree, int op, int left, int right):
	if (tree.count == 128): return -1
	int id = tree.count
	tree.count = id + 1
	tree.op[id] = op
	tree.left[id] = left
	tree.right[id] = right
	tree.offset[id] = token_start_offset
	tree.in_cast[id] = tree.cast_depth
	tree.result_type[id] = 3
	tree.symbol[id] = -1
	tree.next_arg[id] = -1
	return id


# Signature slots participate in the same rollback as pointer records.
# Parameter types live in AST nodes, so no nested array descriptor of
# these borrowed records is read during the probe.
int ast_expression_reserve_signature(expression_ast* tree, int id, int result, int arity):
	if (tree.pending_buffer_types || (tree.types_count == 16)): return -1
	int i = tree.types_count
	type_rec* rec = &tree.pointer_types[i]
	rec.name = c""
	rec.num_fields = 0
	rec.total_size = word_size
	rec.pointer_level = 0
	rec.alias_target = -1
	rec.kind = type_kind_function
	rec.fn_return_type = result
	rec.fn_param_count = arity
	rec.decl_file_index = -1
	rec.decl_line = 0
	rec.decl_column = 0
	tree.pointer_offsets[i] = tree.generic_offset[id]
	tree.types_count = i + 1
	int signature = type_count()
	type_records.push(cast(int, rec))
	return signature


# Composite probes use arena-owned names as well as records: nested type
# lookups and pointer names must see the same spelling as committed types.
int ast_expression_composite_type(expression_ast* tree, int kind, int element, int extra, int offset):
	element = type_canonical(element)
	if (kind == type_kind_map): extra = type_canonical(extra)
	if ((kind == type_kind_list) || (kind == type_kind_map)):
		int checked = element
		if (kind == type_kind_map): checked = extra
		if (type_is_array(checked) || type_has_array_field(checked)): return -1
		if ((kind == type_kind_list) && (type_get_size(checked) <= 0)): return -1
		if ((type_num_args(checked) == 0) && (type_stack_words(checked) != 1)): return -1
	int existing = type_lookup_composite(kind, element, extra)
	if (existing >= 0): return existing
	if (tree.types_count == 16): return -1
	char* name = 0
	if (kind == type_kind_map): name = type_make_map_name(element, extra)
	else if (kind == type_kind_set): name = type_make_set_name(element)
	else if (kind == type_kind_list): name = type_make_list_name(element)
	else:
		name = type_make_slice_name(element)
		if (kind == type_kind_slice_value):
			char* storage = name
			name = strjoin(storage, c" value")
			free(storage)
	int length = strlen(name) + 1
	if (tree.type_names_used + length > 2048):
		free(name)
		return -1
	int i = tree.types_count
	type_rec* rec = &tree.pointer_types[i]
	rec.name = &tree.type_names[tree.type_names_used]
	strcpy(rec.name, name)
	free(name)
	tree.type_names_used = tree.type_names_used + length
	rec.num_fields = 0
	rec.total_size = word_size
	if (kind == type_kind_slice_value): rec.total_size = 0
	rec.pointer_level = 0
	rec.alias_target = element
	rec.kind = kind
	rec.fn_return_type = extra
	rec.fn_param_count = -1
	rec.decl_file_index = -1
	rec.decl_line = 0
	rec.decl_column = 0
	tree.pointer_offsets[i] = offset
	tree.types_count = i + 1
	int result = type_count()
	type_records.push(cast(int, rec))
	return result


int ast_expression_slice_value_type(expression_ast* tree, int element, int offset):
	return ast_expression_composite_type(tree, type_kind_slice_value, element, -1, offset)


int ast_expression_prepare_value(expression_ast* tree, int type, int offset):
	if (type_is_value(type)): return 1
	if ((type_is_array(type) == 0) && (type_get_kind(type) != type_kind_slice)): return 1
	return ast_expression_slice_value_type(tree, type_get_element_type(type), offset) >= 0
