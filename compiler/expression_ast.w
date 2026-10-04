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
	int pending_buffer_types
	int readonly
	type_rec[16] pointer_types
	int[16] pointer_offsets
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


int ast_expressions_mode
int ast_expressions_emitted
int ast_roots_emitted
int ast_roots_fallback
int ast_audit_mode
int ast_required_mode


# Basic list methods share the streaming cm_call lowering. Bit 7 chooses
# the aggregate-copy helper after the argument's type is known.
char* ast_expression_list_helper(int method):
	if (method == 129): return c"__w_list_push_bytes"
	if (method == 131): return c"__w_list_insert_bytes"
	if (method == 1): return c"__w_list_push"
	if (method == 2): return c"__w_list_pop"
	if (method == 3): return c"__w_list_insert"
	if (method == 4): return c"__w_list_remove"
	if (method == 5): return c"__w_list_clear"
	if (method == 6): return c"__w_list_free"
	return 0


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
	tree.types_count = i + 1
	int result = type_count()
	type_records.push(cast(int, rec))
	return result


void ast_expression_restore_types(expression_ast* tree):
	if (tree.types_count == 0): return
	type_table_truncate(tree.types_base)
	# A nested type-name lookup may have indexed temporary records.
	# Force the normal lazy index rebuild before the next lookup.
	type_index_indexed = tree.types_base + 1


void ast_expression_commit_pointer(expression_ast* tree, int i):
	type_rec* rec = &tree.pointer_types[i]
	int actual = type_push_pointer(rec.name, rec.total_size, rec.pointer_level)
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
