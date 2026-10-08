# Production expression AST. Each parse/emit attempt owns this bounded
# arena: a small header on its stack bound to a reusable node slab (see
# expression_ast_bind); unsupported syntax and
# REPL error recovery cannot leave allocated nodes or compiler state behind.
# Node IDs are arena indices, -1 is failure. Literal nodes carry their
# source byte offset until the committed diagnostic/decoding pass fills value.
# result_type retains the streaming type convention (lvalue, value or
# untyped constant). Native stack operands snapshot their names and frame
# offsets. Other symbol records (calls, globals and device captures) remain
# borrowed for this parse/emit operation, not across declarations/REPL entries.
# Float literals store two 32-bit halves for host-independent decoding.
# Call nodes use left for the first argument and next_arg links on argument
# roots; those links do not change a nested call's own argument list.
# Logical chains use the same sibling links, with a separate node for
# each source-level chain (parenthesized subchains keep their boundary).
# The source window admits embedded asset chunks as well as ordinary
# expressions. Decoded text has extra room for per-chunk terminators.
# 4096 nodes cover the existing 900-level ternary fixture (3601 nodes);
# parsing retains the streaming expression nesting guard of 1000.
const int ast_expression_source_limit = 16384


# Comma-index pseudo-lvalues retain their operands until the parent
# chooses a read or store. Grouping finalizes a read, as with map nodes.
const int ast_nd_index = 128
const int ast_nd_store = 129
const int ast_nd_read = 130
const int ast_template_format = 131
const int ast_device_builtin = 132
const int ast_list_it = 133
const int ast_list_it_value = 134
const int ast_forward_generic = 135
const int ast_propagate = 136
const int ast_warning = 137


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
	int it_binding
	int lint_group_depth
	int lint_depth_bias
	int slab
	int capacity
	int recording
	int token_count
	int token_capacity
	int token_text_used
	int token_text_capacity
	int* tokens
	char* token_text
	type_rec[16] pointer_types
	int[16] pointer_offsets
	int[16] pointer_bases
	char[4096] type_names
	# P1.1: the node columns and decoded text live in a reusable heap slab
	# bound by expression_ast_bind, so declaring a tree does not zero-fill
	# half a megabyte of stack per expression root.
	char* text
	int* op
	int* left
	int* right
	int* offset
	int* value
	int* result_type
	int* high
	int* next_arg
	int* in_cast
	int* binding_name
	int* binding_offset
	int* symbol
	int* qualified
	int* it_slot
	int* generic_parameters
	int* generic_signature
	int* generic_offset
	int* generic_instance
	int* generic_arity
	int* infer_coercion
	int* call_receiver_type
	int* infer_want


int ast_expressions_mode
int ast_expressions_emitted
int ast_roots_emitted
int ast_roots_fallback
int ast_audit_mode
int ast_required_mode


# P1.1 node slabs. A tree is bound to a slab when its parse starts and
# keeps it while its stack frame lives. Trees are compiler stack locals
# (one per grammar frame), so the bound slabs form a stack ordered by
# owner address: an owner at or below the tree being bound belongs to a
# frame that has already returned (or to this very tree) and its slab is
# released. Owners above it may still be live enclosing roots (a generic
# body compiled while emitting an outer root) and keep their slabs. REPL
# error recovery only unwinds frames, so a stale owner is released by the
# next bind at or above its address. Node columns and token records start
# small and grow (nodes up to the 4096-node arena limit); decoded text
# keeps its fixed allowance.
struct expression_ast_slab:
	int owner
	char* text
	char* columns
	int capacity
	int* tokens
	int token_capacity
	char* token_text
	int token_text_capacity


const int expression_ast_columns = 22
const int expression_ast_initial_capacity = 64
const int expression_ast_token_fields = 12
int expression_ast_slab_depth
int expression_ast_slab_total
int expression_ast_slab_room
int* expression_ast_slabs


# P1.1 --stats counters: bytes in preflighted roots and groups, tokenizer
# snapshots taken by the probe, tokens whose lexer state was
# re-established for a committed literal/diagnostic event (from a
# recorded token or, on the relex path, by lexing it again), roots that
# replayed by lexing their tokens again, and node slabs allocated.
int ast_preflight_bytes
int ast_tokenizer_snapshots
int ast_tokens_replayed
int ast_relex_replays
int ast_slabs_allocated


expression_ast_slab* expression_ast_slab_at(int index):
	return cast(expression_ast_slab*, expression_ast_slabs[index])


# Unsigned address order: flip the sign bit so 32-bit stack addresses
# above 2 GiB compare in memory order.
int expression_ast_address_below_or_at(int a, int b):
	int bias = 1 << (__word_size__ * 8 - 1)
	return (a ^ bias) <= (b ^ bias)


void expression_ast_point_columns(expression_ast* tree):
	expression_ast_slab* slab = expression_ast_slab_at(tree.slab)
	char* memory = slab.columns
	int column = slab.capacity * __word_size__
	tree.capacity = slab.capacity
	tree.text = slab.text
	tree.op = cast(int*, memory)
	tree.left = cast(int*, memory + column)
	tree.right = cast(int*, memory + 2 * column)
	tree.offset = cast(int*, memory + 3 * column)
	tree.value = cast(int*, memory + 4 * column)
	tree.result_type = cast(int*, memory + 5 * column)
	tree.high = cast(int*, memory + 6 * column)
	tree.next_arg = cast(int*, memory + 7 * column)
	tree.in_cast = cast(int*, memory + 8 * column)
	tree.binding_name = cast(int*, memory + 9 * column)
	tree.binding_offset = cast(int*, memory + 10 * column)
	tree.symbol = cast(int*, memory + 11 * column)
	tree.qualified = cast(int*, memory + 12 * column)
	tree.it_slot = cast(int*, memory + 13 * column)
	tree.generic_parameters = cast(int*, memory + 14 * column)
	tree.generic_signature = cast(int*, memory + 15 * column)
	tree.generic_offset = cast(int*, memory + 16 * column)
	tree.generic_instance = cast(int*, memory + 17 * column)
	tree.generic_arity = cast(int*, memory + 18 * column)
	tree.infer_coercion = cast(int*, memory + 19 * column)
	tree.call_receiver_type = cast(int*, memory + 20 * column)
	tree.infer_want = cast(int*, memory + 21 * column)
	tree.tokens = slab.tokens
	tree.token_capacity = slab.token_capacity
	tree.token_text = slab.token_text
	tree.token_text_capacity = slab.token_text_capacity


# A copy of the first used words of old in a new room-word array.
int* expression_ast_grow_array(int* old, int used, int room):
	int* grown = cast(int*, malloc(room * __word_size__))
	for i in range(used): grown[i] = old[i]
	if (old): free(old)
	return grown


expression_ast_slab* expression_ast_new_slab():
	expression_ast_slab* slab = cast(expression_ast_slab*, malloc(sizeof(expression_ast_slab)))
	slab.owner = 0
	slab.text = cast(char*, malloc(32768))
	slab.capacity = expression_ast_initial_capacity
	slab.columns = cast(char*, malloc(expression_ast_columns * slab.capacity * __word_size__))
	slab.token_capacity = expression_ast_initial_capacity
	slab.tokens = cast(int*, malloc(expression_ast_token_fields * slab.token_capacity * __word_size__))
	slab.token_text_capacity = 1024
	slab.token_text = cast(char*, malloc(slab.token_text_capacity))
	ast_slabs_allocated = ast_slabs_allocated + 1
	return slab


void expression_ast_bind(expression_ast* tree):
	int self = cast(int, tree)
	while (expression_ast_slab_depth > 0):
		expression_ast_slab* top = expression_ast_slab_at(expression_ast_slab_depth - 1)
		if (expression_ast_address_below_or_at(top.owner, self) == 0): break
		expression_ast_slab_depth = expression_ast_slab_depth - 1
	int index = expression_ast_slab_depth
	if (index == expression_ast_slab_total):
		if (index == expression_ast_slab_room):
			expression_ast_slab_room = expression_ast_slab_room * 2 + 8
			expression_ast_slabs = expression_ast_grow_array(expression_ast_slabs, index, expression_ast_slab_room)
		expression_ast_slabs[index] = cast(int, expression_ast_new_slab())
		expression_ast_slab_total = index + 1
	expression_ast_slab* bound = expression_ast_slab_at(index)
	bound.owner = self
	expression_ast_slab_depth = index + 1
	tree.slab = index
	tree.recording = 0
	tree.token_count = 0
	tree.token_text_used = 0
	expression_ast_point_columns(tree)


# Double the bound slab's node columns, keeping the first count nodes.
void expression_ast_grow(expression_ast* tree):
	expression_ast_slab* slab = expression_ast_slab_at(tree.slab)
	int old_capacity = slab.capacity
	int capacity = old_capacity * 2
	if (capacity > 4096): capacity = 4096
	char* old = slab.columns
	char* memory = cast(char*, malloc(expression_ast_columns * capacity * __word_size__))
	int used = tree.count * __word_size__
	for c in range(expression_ast_columns):
		char* from = old + c * old_capacity * __word_size__
		char* to = memory + c * capacity * __word_size__
		for i in range(used): to[i] = from[i]
	free(old)
	slab.columns = memory
	slab.capacity = capacity
	expression_ast_point_columns(tree)


# Keep length more bytes of token text (plus a terminator) in the slab.
int expression_ast_token_text_reserve(expression_ast* tree, int length):
	int need = tree.token_text_used + length + 1
	if (need > tree.token_text_capacity):
		expression_ast_slab* slab = expression_ast_slab_at(tree.slab)
		int room = slab.token_text_capacity * 2
		while (room < need): room = room * 2
		char* grown = cast(char*, malloc(room))
		for i in range(tree.token_text_used): grown[i] = slab.token_text[i]
		free(slab.token_text)
		slab.token_text = grown
		slab.token_text_capacity = room
		tree.token_text = grown
		tree.token_text_capacity = room
	int start = tree.token_text_used
	tree.token_text_used = need
	return start


# Copy the current token's bytes (embedded NULs included) and terminator.
int expression_ast_save_token_text(expression_ast* tree):
	int start = expression_ast_token_text_reserve(tree, token_i)
	char* to = tree.token_text + start
	for i in range(token_i): to[i] = token[i]
	to[token_i] = 0
	return start


# Record the lexer state get_token left for the current token. The
# probe lexes every token of an accepted root exactly as the committed
# replay would, so these records replace lexing the root a second time.
void expression_ast_record_token(expression_ast* tree):
	if (tree.token_count == tree.token_capacity):
		expression_ast_slab* slab = expression_ast_slab_at(tree.slab)
		int words = tree.token_count * expression_ast_token_fields
		slab.token_capacity = slab.token_capacity * 2
		slab.tokens = expression_ast_grow_array(slab.tokens, words, slab.token_capacity * expression_ast_token_fields)
		tree.tokens = slab.tokens
		tree.token_capacity = slab.token_capacity
	int* row = &tree.tokens[tree.token_count * expression_ast_token_fields]
	row[0] = token_start_offset
	row[1] = diag_token_line
	row[2] = diag_token_column
	row[3] = line_number
	row[4] = column_number
	row[5] = tab_level
	row[6] = nextc
	row[7] = byte_offset
	row[8] = token_newline
	row[9] = token_i
	row[10] = expression_ast_save_token_text(tree)
	row[11] = token_serial
	tree.token_count = tree.token_count + 1


# Re-establish recorded token k as the current token.
void expression_ast_enter_token(expression_ast* tree, int k):
	int* row = &tree.tokens[k * expression_ast_token_fields]
	token_start_offset = row[0]
	diag_token_line = row[1]
	diag_token_column = row[2]
	line_number = row[3]
	column_number = row[4]
	tab_level = row[5]
	nextc = row[6]
	byte_offset = row[7]
	token_newline = row[8]
	tokenizer_set_token_text(tree.token_text + row[10], row[9])
	token_i = row[9]
	token_serial = row[11]


# Location prefix of a parse token or a retained diagnostic token.
int* expression_ast_token_row(expression_ast* tree, int index):
	int stride = expression_ast_token_fields
	# A retained emission view carries compact diagnostic locations only.
	if (tree.slab < 0): stride = 4
	return &tree.tokens[index * stride]


# Index of the recorded token starting at offset, or -1.
int expression_ast_token_at(expression_ast* tree, int offset):
	int low = 0
	int high = tree.token_count - 1
	while (low <= high):
		int middle = (low + high) >> 1
		int start = expression_ast_token_row(tree, middle)[0]
		if (start == offset): return middle
		if (start < offset): low = middle + 1
		else: high = middle - 1
	return -1


# Container methods share the streaming helper-call lowering. Bit 7
# chooses the aggregate-copy/address helper after types are known.
# Bit 8 records the method-token lookup of an outer it variable.
char* ast_expression_method_helper(int method):
	method = method & 255
	if (method == 11): return c"__w_map_remove"
	if (method == 12): return c"__w_set_add"
	if (method == 13): return c"__w_map_free"
	if (method == 14): return c"__w_map_get"
	if (method == 15): return c"__w_map_get_or"
	if (method == 16): return c"__w_map_keys"
	if (method == 17): return c"__w_map_values"
	if (method == 18): return c"__w_map_add"
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
	if (method == 30): return c"__w_list_sort_by"
	if (method == 31): return c"__w_list_sorted_by"
	if (method == 32): return c"__w_list_map"
	if (method == 33): return c"__w_list_filter"
	if (method == 34): return c"__w_list_reduce"
	if (method == 158): return c"__w_list_sort_by_addr"
	if (method == 159): return c"__w_list_sorted_by_addr"
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
	if (type_is_gpu_object(base)): existing = type_lookup_pointer(type_get_name(base), 1)
	if (existing >= 0): return existing
	# Array promotion can intern a slice-value type during emission.
	# Preserve type registration order until it too has a replay event.
	if (tree.pending_buffer_types || (tree.types_count == 16)): return -1
	int i = tree.types_count
	type_rec* rec = &tree.pointer_types[i]
	rec.name = type_get_name(type_canonical(base))
	if (type_is_gpu_object(base)): rec.name = type_get_name(base)
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


# Device captures make scalar lvalues const. Stage the wrapper at the
# symbol token, just as the streaming device-symbol resolver does.
int ast_expression_const_type(expression_ast* tree, int base, int offset):
	int existing = type_lookup_const(base)
	if (existing >= 0): return existing
	base = type_canonical(base)
	if ((type_num_args(base) > 0) || tree.pending_buffer_types || (tree.types_count == 16)): return -1
	int length = strlen(type_get_name(base)) + 7
	if (tree.type_names_used + length > 4096): return -1
	int i = tree.types_count
	type_rec* rec = &tree.pointer_types[i]
	rec.name = &tree.type_names[tree.type_names_used]
	strcpy(rec.name, c"const ")
	strcpy(rec.name + 6, type_get_name(base))
	tree.type_names_used = tree.type_names_used + length
	rec.num_fields = 0
	rec.total_size = type_get_size(base)
	rec.pointer_level = type_get_pointer_level(base)
	rec.alias_target = base
	rec.kind = type_kind_const
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


# GPU-object wrappers preserve the raw memory-domain type while the
# ordinary type queries follow the canonical element, including its
# fields. The arena record needs no field-array descriptors.
int ast_expression_gpu_type(expression_ast* tree, int base, int offset):
	base = type_canonical(base)
	for index in range(type_count()):
		type_rec* existing = type_record(index)
		if ((existing.kind == type_kind_gpu) && (existing.alias_target == base)): return index
	if (tree.pending_buffer_types || (tree.types_count == 16)): return -1
	int length = strlen(type_get_name(base)) + 5
	if (tree.type_names_used + length > 4096): return -1
	int i = tree.types_count
	type_rec* rec = &tree.pointer_types[i]
	type_rec* source = type_record(base)
	rec.name = &tree.type_names[tree.type_names_used]
	strcpy(rec.name, c"gpu ")
	strcpy(rec.name + 4, type_get_name(base))
	tree.type_names_used = tree.type_names_used + length
	rec.num_fields = source.num_fields
	rec.total_size = source.total_size
	rec.pointer_level = source.pointer_level
	rec.alias_target = base
	rec.kind = type_kind_gpu
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
	# type_table_truncate invalidates the name index even if later inserts
	# overtake its previous length before the next lookup.


void ast_expression_commit_pointer(expression_ast* tree, int i):
	type_rec* rec = &tree.pointer_types[i]
	if (rec.kind == type_kind_function): return
	int actual
	if (rec.kind == type_kind_gpu): actual = type_get_gpu(rec.alias_target)
	else if (rec.kind == type_kind_const): actual = type_push_const(rec.alias_target)
	else if (rec.kind == type_kind_slice_value): actual = type_push_slice_value(rec.alias_target)
	else if (rec.kind == type_kind_slice): actual = type_push_slice(rec.alias_target)
	else if (rec.kind == type_kind_map): actual = type_push_map(rec.alias_target, rec.fn_return_type)
	else if (rec.kind == type_kind_set): actual = type_push_set(rec.alias_target)
	else if (rec.kind == type_kind_list): actual = type_push_list(rec.alias_target)
	else:
		# A newly staged composite's name belongs to this arena. Reuse the
		# committed base record's persistent name for its pointer record.
		int base = tree.pointer_bases[i]
		char* name = type_get_name(type_canonical(base))
		if (type_is_gpu_object(base)): name = type_get_name(base)
		actual = type_push_pointer(name, rec.total_size, rec.pointer_level)
	assert1(actual == tree.types_base + i)


int expression_ast_add(expression_ast* tree, int op, int left, int right):
	if (tree.count == 4096): return -1
	if (tree.count == tree.capacity): expression_ast_grow(tree)
	int id = tree.count
	tree.count = id + 1
	tree.op[id] = op
	tree.left[id] = left
	tree.right[id] = right
	tree.offset[id] = token_start_offset
	tree.in_cast[id] = tree.cast_depth
	tree.result_type[id] = 3
	tree.symbol[id] = -1
	tree.binding_name[id] = -1
	tree.qualified[id] = 0
	tree.next_arg[id] = -1
	tree.value[id] = 0
	tree.high[id] = 0
	tree.binding_offset[id] = 0
	tree.it_slot[id] = 0
	tree.generic_offset[id] = 0
	tree.generic_arity[id] = 0
	tree.infer_coercion[id] = 0
	tree.generic_parameters[id] = -1
	tree.generic_signature[id] = -1
	tree.generic_instance[id] = -1
	tree.call_receiver_type[id] = -1
	tree.infer_want[id] = -1
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
	if (tree.type_names_used + length > 4096):
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


# Explicit container type syntax checks storage rules. Implicit snapshot
# results follow cm_result_type, which interns the list without those checks.
int ast_expression_checked_composite_type(expression_ast* tree, int kind, int element, int extra, int offset):
	if ((kind == type_kind_list) || (kind == type_kind_map)):
		int checked = element
		if (kind == type_kind_map): checked = extra
		if (type_is_array(checked) || type_has_array_field(checked)): return -1
		if ((kind == type_kind_list) && (type_get_size(checked) <= 0)): return -1
		if ((type_num_args(checked) == 0) && (type_stack_words(checked) != 1)): return -1
	return ast_expression_composite_type(tree, kind, element, extra, offset)


int ast_expression_slice_value_type(expression_ast* tree, int element, int offset):
	return ast_expression_composite_type(tree, type_kind_slice_value, element, -1, offset)


int ast_expression_prepare_value(expression_ast* tree, int type, int offset):
	if (type_is_value(type)): return 1
	if ((type_is_array(type) == 0) && (type_get_kind(type) != type_kind_slice)): return 1
	return ast_expression_slice_value_type(tree, type_get_element_type(type), offset) >= 0
