# Session-owned production traversal trees with independent semantic records.
# Backend-specific operands retain their production interpretation. Every AST
# compile retains this forest, and expressions are lowered from it (S2.5;
# code_generator/retained_emit.w) through the backend's existing visitor.
# IDs are append-only within a session. A checkpoint retracts its suffix;
# consumers must not keep IDs from a retracted entry.
#
# Storage (P1.2b). Every node that is not an expression operand is a
# retained_record. An expression group's operands are not records: the group
# keeps its arena's node columns in one column-major block, and each operand
# ID maps to its group (retained_expression_columns words per operand, the
# arena's own encoding). Records, column blocks and copied text live in one
# chunked session arena, so rollback is a high-water mark. A node ID maps to
# its record through retained_node_table; an operand's entry is its group's
# record with the low bit set. Consumers read any node through the full view
# struct retained_node (retained_node_load), which derives the operand fields
# the columns do not hold (literals, value-type flags, locations).
#
# Semantic snapshot records (compiler/retained_semantic.w) are kept only in
# a semantic session (retained_semantic_mode): a tree query, an explicit
# --ast-retain, or an in-process compiler API. A plain compile's forest keeps
# the raw type and symbol identities its emission lowers, and every semantic
# field of its nodes reads -1 (or 0 for text).
import lib.lib
import compiler.retained_semantic

const int retained_module = 1
const int retained_function = 2
const int retained_statement = 3
const int retained_expression = 4
const int retained_declaration = 5
const int retained_expression_group = 6
const int retained_import = 7
const int retained_local = 8
const int retained_tile_expression = 9
const int retained_tile_statement = 10

struct retained_source:
	char* path
	char* import_key
	char* bytes
	int length
	int capacity
	int root
	int declaration_cursor
	list[int] lines
	# Node IDs whose parent was this module's root, in creation order, and
	# the next entry a declaration may adopt. Replaces a scan of every node
	# created since the previous declaration, imports included.
	list[int] top_level
	int top_cursor
	# Older source version with the same path, restored to the path index
	# when this version is rolled back.
	int previous_version

# The view of one node (retained_node_load): every field any kind carries.
struct retained_node:
	int kind
	int parent
	int source
	int start
	int end
	int line
	int column
	char* name
	int op
	int left
	int right
	int next_arg
	int literal_value
	int literal_high
	char* literal_text
	int literal_length
	int type_size
	int type_pointer_level
	char* result_type
	char* binding_name
	char* binding_file
	int binding_line
	int binding_column
	int binding_scope
	int binding_slot
	int semantic_type
	int binding
	int value
	int high
	int symbol
	int in_cast
	int binding_offset
	int binding_text_offset
	int it_slot
	int readonly
	int whole_expression
	int final_token_offset
	int qualified
	int generic_parameters
	int generic_signature
	int generic_offset
	int generic_instance
	int generic_arity
	int infer_coercion
	int call_receiver_type
	int infer_want
	int result_is_value
	int import_source
	char* import_path
	char* import_alias
	char* payload_text
	char* arena_text
	int arena_text_length
	char* arena_type_names
	int arena_type_names_length
	# S2.1: the symbol a name-bearing warning spells (argument-count and
	# self-assignment diagnostics), and the arena's value-type encoding of
	# generic_signature (1), call_receiver_type (2) and infer_want (4).
	int name_binding
	int type_value_flags
	# S2.2a: a retained statement node's pending walk record
	# (code_generator/retained_emit.w), or -1 once walked or never deferred.
	int statement_walk

# P1.2b: an expression group's own fields and its operands' columns.
# columns holds retained_expression_columns blocks of count words, in the
# arena's column order (compiler/expression_ast.w expression_ast_point_columns):
# op, left, right, offset, value, result_type, high, next_arg, in_cast,
# binding_name, binding_offset, symbol, qualified, it_slot,
# generic_parameters, generic_signature, generic_offset, generic_instance,
# generic_arity, infer_coercion, call_receiver_type, infer_want.
# semantic (semantic sessions only, else 0) holds retained_semantic_columns
# blocks: the semantic result, signature, receiver and inference types, the
# binding and name binding, the payload text, and the result type's interned
# spelling, size and pointer level.
struct retained_group:
	int id
	int root
	int count
	# 1 when the target word is 64 bits wide (a float literal's high half
	# is then part of its retained literal).
	int wide
	int readonly
	int whole_expression
	int final_token_offset
	char* arena_text
	int arena_text_length
	char* arena_type_names
	int arena_type_names_length
	int* columns
	int* semantic
	# Only groups with literal conversion notes need token locations after
	# parsing. Four words per token: offset, diagnostic line/column, lexer
	# line. Token spellings and the rest of the speculative lexer stay out.
	int location_count
	int* locations

const int retained_expression_columns = 22
const int retained_semantic_columns = 10
# compiler/expression_ast.w's ast_warning opcode; this module is also
# compiled without the expression arena (compiler/module_dependencies.w).
const int retained_op_warning = 137

# P1.2b: storage of every node but an expression operand.
struct retained_record:
	int kind
	int parent
	int source
	int start
	int end
	int line
	int column
	char* name
	int semantic_type
	int binding
	int statement_walk
	# Declarations: the declared kind's spelling.
	char* result_type
	int import_source
	char* import_path
	char* import_alias
	retained_group* group
	# Statement-local semantic layout cursor. A successful child publishes
	# its final depth to its parent; a failed child's rollback removes its
	# cursor before publication. Function boundaries start a fresh cursor.
	int layout_active
	int layout_depth
	# A complete tile region, owned by the same checkpointed arena. Kept
	# opaque here so non-compiler tree consumers need not import its grammar.
	char* tile_payload

struct retained_checkpoint:
	char* pending_import
	int nodes
	int sources
	int parent
	int types
	int bindings
	# P1.2b: the session arena's high-water mark (chunk and offset).
	int text
	int arena_chunk

int ast_retain_mode
# Borrowed resolver context, restored by both normal return and rollback.
char* retained_pending_import
list[retained_source*] retained_sources
int retained_parent = -1
char* retained_last_path
int retained_last_source
retained_source* retained_last_record
# P1.2b: getc's recording state (compiler/tokenizer.w): the path and
# recorded length of retained_last_record while it is the version being
# read, so a byte inside an already recorded window costs one comparison
# of its offset. retained_append_sync keeps them current;
# retained_append_none marks them unusable.
char* retained_append_path
int retained_append_next
# S2.5: the line lookup of the previous retained_add: source and the index
# of the first line start after its offset. Expression nodes of one group
# share lines, so most lookups need no search.
int retained_line_source = -1
int retained_line_index
# The start offset of the line retained_line_at found (when it is > 0).
int retained_line_start
# Newest source version per path; older versions chain via previous_version.
map[char*, int] retained_source_index
# Newest source version per debug file index (-2 = not looked up yet). A
# debug file index names one path for the whole process, so this is the path
# index keyed by integer; it is emptied whenever the path index changes.
list[int] retained_file_sources

# P1.2b: node ID -> record address (an operand's group record | 1).
int* retained_node_table
int retained_node_total
int retained_node_room

# P1.2b: the session arena. Allocations never span a chunk; a request larger
# than a chunk gets a chunk of its own size. Chunks above the high-water mark
# survive rollback and are reused when large enough; retained_clear frees them.
const int retained_arena_chunk_size = 1048576
int* retained_arena_chunks
int* retained_arena_sizes
int retained_arena_count
int retained_arena_room
int retained_arena_index
int retained_arena_offset
# Cached payloads on surviving owners must not reuse an arena suffix after
# rollback. This generation is monotonic and is never checkpoint-restored.
int retained_arena_generation
# Interned spellings every group and operand share.
char* retained_name_expression
char* retained_name_empty
# --stats (P1.2b): operands and copied text bytes retained this session.
int retained_operand_total
int retained_text_total
# retained_node_at's ring of loaded views.
const int retained_view_ring = 8
retained_node* retained_views
int retained_view_next


void retained_init():
	# Set last below and cleared with the rest by retained_clear.
	if (retained_name_expression != 0): return
	if (retained_sources == 0): retained_sources = new list[retained_source*]
	if (retained_source_index == 0): retained_source_index = new map[char*, int]
	if (retained_file_sources == 0): retained_file_sources = new list[int]
	if (retained_node_table == 0):
		retained_node_room = 4096
		retained_node_table = cast(int*, malloc(retained_node_room * __word_size__))
		retained_node_total = 0
	if (retained_name_expression == 0):
		retained_name_expression = retained_intern(c"expression")
		retained_name_empty = retained_intern(c"")


int retained_node_count():
	return retained_node_total


# Reserve one more node ID mapped to entry.
int retained_node_push(int entry):
	int id = retained_node_total
	if (id == retained_node_room):
		int room = retained_node_room * 2
		int* grown = cast(int*, malloc(room * __word_size__))
		int* old = retained_node_table
		for i in range(id): grown[i] = old[i]
		free(cast(char*, old))
		retained_node_table = grown
		retained_node_room = room
	retained_node_table[id] = entry
	retained_node_total = id + 1
	return id


# The record of a node that is not an expression operand.
retained_record* retained_record_at(int id):
	int entry = retained_node_table[id]
	if (entry & 1): __w_trap(c"retained_record_at: an expression operand has no record")
	return cast(retained_record*, entry)


int retained_node_kind(int id):
	int entry = retained_node_table[id]
	if (entry & 1): return retained_expression
	retained_record* record = cast(retained_record*, entry)
	return record.kind


# Word-aligned bytes from the session arena.
char* retained_arena_alloc(int size):
	size = (size + __word_size__ - 1) & (0 - __word_size__)
	int index = retained_arena_index
	int offset = retained_arena_offset
	if ((index < retained_arena_count) && (offset + size <= retained_arena_sizes[index])):
		retained_arena_offset = offset + size
		return cast(char*, retained_arena_chunks[index]) + offset
	# The next chunk: the current one is full (or there is none yet).
	int next = retained_arena_index + 1
	if (retained_arena_count == 0): next = 0
	if (next == retained_arena_room):
		int room = retained_arena_room * 2 + 8
		int* chunks = cast(int*, malloc(room * __word_size__))
		int* sizes = cast(int*, malloc(room * __word_size__))
		for i in range(retained_arena_count):
			chunks[i] = retained_arena_chunks[i]
			sizes[i] = retained_arena_sizes[i]
		if (retained_arena_chunks != 0):
			free(cast(char*, retained_arena_chunks))
			free(cast(char*, retained_arena_sizes))
		retained_arena_chunks = chunks
		retained_arena_sizes = sizes
		retained_arena_room = room
	int chunk_size = retained_arena_chunk_size
	if (size > chunk_size): chunk_size = size
	if (next == retained_arena_count):
		retained_arena_chunks[next] = cast(int, malloc(chunk_size))
		retained_arena_sizes[next] = chunk_size
		retained_arena_count = next + 1
	else if (retained_arena_sizes[next] < size):
		free(cast(char*, retained_arena_chunks[next]))
		retained_arena_chunks[next] = cast(int, malloc(chunk_size))
		retained_arena_sizes[next] = chunk_size
	retained_arena_index = next
	retained_arena_offset = size
	return cast(char*, retained_arena_chunks[next])


# P1.2b: count words from from to to. The pointers step by raw byte
# offsets (T* + int is unscaled), which the backend lowers without the
# multiply an indexed access costs; this loop moves every retained column.
void retained_copy_words(int* to, int* from, int count):
	int* p = from
	int* q = to
	int blocks = count >> 2
	while (blocks > 0):
		q[0] = p[0]
		q[1] = p[1]
		q[2] = p[2]
		q[3] = p[3]
		p = &p[4]
		q = &q[4]
		blocks = blocks - 1
	int rest = count & 3
	while (rest > 0):
		q[0] = p[0]
		p = &p[1]
		q = &q[1]
		rest = rest - 1


# columns blocks of count words from from, stride words apart, packed
# end to end at to: the arena's node columns into a group's block.
void retained_copy_columns(int* to, int* from, int count, int stride, int columns):
	int* q = to
	int* p = from
	int left = columns
	# Most groups are an operand or three: copy those a column per step.
	int step = stride * __word_size__
	if (count == 1):
		while (left > 0):
			q[0] = p[0]
			p = p + step
			q = &q[1]
			left = left - 1
		return
	if (count == 2):
		while (left > 0):
			q[0] = p[0]
			q[1] = p[1]
			p = p + step
			q = &q[2]
			left = left - 1
		return
	if (count == 3):
		while (left > 0):
			q[0] = p[0]
			q[1] = p[1]
			q[2] = p[2]
			p = p + step
			q = &q[3]
			left = left - 1
		return
	int skip = (stride - count) * __word_size__
	while (left > 0):
		int n = count
		while (n >= 4):
			q[0] = p[0]
			q[1] = p[1]
			q[2] = p[2]
			q[3] = p[3]
			p = &p[4]
			q = &q[4]
			n = n - 4
		while (n > 0):
			q[0] = p[0]
			p = &p[1]
			q = &q[1]
			n = n - 1
		p = p + skip
		left = left - 1


# Index of the first word where a and b differ, or -1.
int retained_words_differ(int* a, int* b, int count):
	int* p = a
	int* q = b
	int left = count
	while (left > 0):
		if (*p != *q): return count - left
		p = p + __word_size__
		q = q + __word_size__
		left = left - 1
	return -1


# Index of the first byte where a and b differ, or -1.
int retained_bytes_differ(char* a, char* b, int count):
	char* start = a
	char* end = a + count
	while (a != end):
		if (*a != *b): return cast(int, a) - cast(int, start)
		a = a + 1
		b = b + 1
	return -1


# Bytes of the session arena below its high-water mark.
int retained_arena_used():
	int used = retained_arena_offset
	for i in range(retained_arena_index): used = used + retained_arena_sizes[i]
	return used


# Copy length bytes plus a terminator into the session arena.
char* retained_text_copy(char* text, int length):
	retained_text_total = retained_text_total + length
	char* copy = retained_arena_alloc(length + 1)
	int words = length / __word_size__
	retained_copy_words(cast(int*, copy), cast(int*, text), words)
	for i in range(words * __word_size__, length): copy[i] = text[i]
	copy[length] = 0
	return copy


# Line and column of offset in source, as a node created there records them
# (line 0 when no line start precedes it). Sets retained_line_index and
# retained_line_start.
int retained_line_at(int source, int start):
	retained_source* location = retained_sources[source]
	list[int] lines = location.lines
	int high = lines.length
	# The starts are contiguous words (lines always holds offset 0).
	int* starts = cast(int*, &lines[0])
	int low = retained_line_index
	if ((source != retained_line_source) || (low <= 0) || (low > high) || (starts[low - 1] > start) || ((low < high) && (starts[low] <= start))):
		low = 0
		while (low < high):
			int mid = (low + high) >> 1
			if (starts[mid] <= start): low = mid + 1
			else: high = mid
	retained_line_source = source
	retained_line_index = low
	if (low > 0): retained_line_start = starts[low - 1]
	return low


retained_record* retained_record_new(int kind, int parent, int source, int start, int line, int column, char* name):
	retained_record* node = cast(retained_record*, retained_arena_alloc(sizeof(retained_record)))
	node.kind = kind
	node.parent = parent
	node.source = source
	node.start = start
	node.end = start
	node.line = line
	node.column = column
	if ((line == 0) && (source >= 0)):
		int low = retained_line_at(source, start)
		if (low > 0):
			node.line = low
			node.column = start - retained_line_start + 1
	node.name = name
	node.semantic_type = -1
	node.binding = -1
	node.statement_walk = -1
	node.result_type = 0
	node.import_source = -1
	node.import_path = 0
	node.import_alias = 0
	node.group = 0
	node.layout_active = 0
	node.layout_depth = 0
	node.tile_payload = 0
	return node


# A record whose name is already interned (or one of the shared spellings).
int retained_add_interned(int kind, int parent, int source, int start, int line, int column, char* name):
	retained_init()
	retained_record* node = retained_record_new(kind, parent, source, start, line, column, name)
	int id = retained_node_push(cast(int, node))
	if ((source >= 0) && (parent >= 0)):
		retained_source* owner = retained_sources[source]
		if (owner.root == parent): owner.top_level.push(id)
	return id


int retained_add(int kind, int parent, int source, int start, int line, int column, char* name):
	return retained_add_interned(kind, parent, source, start, line, column, retained_intern(name))


# Fill view with node id's fields.
void retained_node_load(int id, retained_node* view):
	int entry = retained_node_table[id]
	retained_record* record = cast(retained_record*, entry & (0 - 2))
	view.kind = record.kind
	view.parent = record.parent
	view.source = record.source
	view.start = record.start
	view.end = record.end
	# P1.2b: a module ends with every byte its version recorded.
	if (record.kind == retained_module): view.end = retained_sources[record.source].length
	view.line = record.line
	view.column = record.column
	view.name = record.name
	view.op = 0
	view.left = -1
	view.right = -1
	view.next_arg = -1
	view.literal_value = 0
	view.literal_high = 0
	view.literal_text = 0
	view.literal_length = 0
	view.type_size = 0
	view.type_pointer_level = 0
	view.result_type = record.result_type
	view.binding_name = 0
	view.binding_file = 0
	view.binding_line = 0
	view.binding_column = 0
	view.binding_scope = 0
	view.binding_slot = 0
	view.semantic_type = record.semantic_type
	view.binding = record.binding
	view.value = 0
	view.high = 0
	view.symbol = 0
	view.in_cast = 0
	view.binding_offset = 0
	view.binding_text_offset = -1
	view.it_slot = 0
	view.readonly = 0
	view.whole_expression = 0
	view.final_token_offset = 0
	view.qualified = 0
	view.generic_parameters = 0
	view.generic_signature = -1
	view.generic_offset = 0
	view.generic_instance = 0
	view.generic_arity = 0
	view.infer_coercion = 0
	view.call_receiver_type = -1
	view.infer_want = -1
	view.result_is_value = 0
	view.import_source = record.import_source
	view.import_path = record.import_path
	view.import_alias = record.import_alias
	view.payload_text = 0
	view.arena_text = 0
	view.arena_text_length = 0
	view.arena_type_names = 0
	view.arena_type_names_length = 0
	view.name_binding = -1
	view.type_value_flags = 0
	view.statement_walk = record.statement_walk
	retained_group* group = record.group
	if (group == 0): return
	if ((entry & 1) == 0):
		view.op = group.root
		view.readonly = group.readonly
		view.whole_expression = group.whole_expression
		view.final_token_offset = group.final_token_offset
		view.arena_text = group.arena_text
		view.arena_text_length = group.arena_text_length
		view.arena_type_names = group.arena_type_names
		view.arena_type_names_length = group.arena_type_names_length
		return
	# An operand: its group's column entry k.
	int k = id - group.id - 1
	int count = group.count
	int* c = group.columns
	view.kind = retained_expression
	view.parent = group.id
	view.statement_walk = -1
	view.import_source = -1
	view.import_path = 0
	view.import_alias = 0
	view.result_type = 0
	view.semantic_type = -1
	view.binding = -1
	view.name = retained_name_empty
	int op = c[k]
	view.op = op
	view.left = c[count + k]
	view.right = c[2 * count + k]
	int start = c[3 * count + k]
	view.start = start
	view.line = 0
	view.column = 0
	int low = retained_line_at(record.source, start)
	if (low > 0):
		view.line = low
		view.column = start - retained_line_start + 1
	int value = c[4 * count + k]
	int result = c[5 * count + k]
	int high = c[6 * count + k]
	view.high = high
	view.next_arg = c[7 * count + k]
	view.in_cast = c[8 * count + k]
	view.binding_text_offset = c[9 * count + k]
	view.binding_offset = c[10 * count + k]
	view.symbol = c[11 * count + k]
	view.qualified = c[12 * count + k]
	view.it_slot = c[13 * count + k]
	view.generic_parameters = c[14 * count + k]
	int signature = c[15 * count + k]
	view.generic_offset = c[16 * count + k]
	view.generic_instance = c[17 * count + k]
	view.generic_arity = c[18 * count + k]
	view.infer_coercion = c[19 * count + k]
	int receiver = c[20 * count + k]
	int want = c[21 * count + k]
	view.result_is_value = result < -1
	if (signature < -1): view.type_value_flags = view.type_value_flags | 1
	if (receiver < -1): view.type_value_flags = view.type_value_flags | 2
	if (want < -1): view.type_value_flags = view.type_value_flags | 4
	# Symbol-table names and message operands are text (payload_text), not
	# offsets or addresses, once retained.
	if ((op == 'v') || (op == 'C') || (op == 'X') || (op == 'z') || (op == 'l')): value = 0
	if ((op == retained_op_warning) && ((high == 0) || (high == 6) || (high == 7) || (high == 8) || (high == 1) || (high == 2) || (high == 5))): value = 0
	view.value = value
	if ((op == 0) || (op == 'c') || (op == 'h') || (op == 'f')):
		view.literal_value = value
		if ((op == 'f') && group.wide): view.literal_high = high
	if ((op == 's') || (op == 'S') || (op == 't')):
		view.literal_length = high
		view.literal_text = &group.arena_text[value]
	int* s = group.semantic
	if (s == 0): return
	view.semantic_type = s[k]
	view.generic_signature = s[count + k]
	view.call_receiver_type = s[2 * count + k]
	view.infer_want = s[3 * count + k]
	int binding = s[4 * count + k]
	view.binding = binding
	view.name_binding = s[5 * count + k]
	view.payload_text = cast(char*, s[6 * count + k])
	view.result_type = cast(char*, s[7 * count + k])
	view.type_size = s[8 * count + k]
	view.type_pointer_level = s[9 * count + k]
	if (binding >= 0):
		retained_binding* bound = retained_bindings[binding]
		view.binding_name = bound.name
		view.binding_file = bound.file
		view.binding_line = bound.line
		view.binding_column = bound.column
		view.binding_scope = bound.scope
		view.binding_slot = bound.slot


# Node id loaded into the next view of a ring of retained_view_ring: a
# convenience for code that holds a few nodes at once (tests, checks). The
# view is overwritten by a later call; retained_node_load fills one's own.
retained_node* retained_node_at(int id):
	if (retained_views == 0): retained_views = cast(retained_node*, malloc(retained_view_ring * sizeof(retained_node)))
	retained_node* view = cast(retained_node*, cast(char*, retained_views) + retained_view_next * sizeof(retained_node))
	retained_view_next = (retained_view_next + 1) % retained_view_ring
	retained_node_load(id, view)
	return view


# Room for bytes up to end (inclusive) in source; bytes at and past
# source.length are unspecified, so a write past the end zeroes the gap.
void retained_source_reserve(retained_source* source, int end):
	if (end < source.capacity): return
	int capacity = source.capacity
	if (capacity == 0): capacity = 1024
	while (capacity <= end): capacity = capacity * 2
	source.bytes = realloc(source.bytes, source.capacity, capacity)
	source.capacity = capacity


# Zero source bytes [from, to): a gap a later read skipped over.
void retained_source_zero(retained_source* source, int from, int to):
	char* bytes = source.bytes
	for i in range(from, to): bytes[i] = 0


# Point getc's recording state at retained_last_record (retained_last_path).
void retained_append_sync():
	retained_source* source = retained_last_record
	retained_append_path = retained_last_path
	retained_append_next = source.length


void retained_append_none():
	retained_append_path = cast(char*, -1)
	retained_append_next = -1


# A fresh compile owns a fresh source version, even at a reused pathname.
int retained_source_begin(char* path):
	retained_init()
	retained_source* source = new retained_source
	retained_semantic_invalidate()
	source.lines = new list[int]
	source.lines.push(0)
	source.top_level = new list[int]
	source.top_cursor = 0
	source.bytes = 0
	source.length = 0
	source.capacity = 0
	source.declaration_cursor = 0
	source.path = strclone(path)
	source.import_key = 0
	int id = retained_sources.length
	source.previous_version = retained_source_index.get(path, -1)
	retained_source_index[path] = id
	retained_file_sources.clear()
	retained_sources.push(source)
	retained_last_path = path
	retained_last_source = id
	retained_last_record = source
	source.root = retained_add(retained_module, -1, id, 0, 1, 1, path)
	retained_append_sync()
	return id


# Newest source version recorded at a pathname, or -1.
int retained_source_find(char* path):
	if (retained_source_index == 0): return -1
	return retained_source_index.get(path, -1)


# The tokenizer passes the same filename pointer for every byte of a file.
# Every new source version enters through retained_source_begin and every
# retraction through retained_rollback; both reset this one-entry cache, so
# a pointer match needs no string comparison on the per-byte path.
int retained_source_id(char* path):
	retained_init()
	if ((retained_last_path == path) && (path != 0)): return retained_last_source
	int id = retained_source_find(path)
	if (id < 0): return retained_source_begin(path)
	retained_last_path = path
	retained_last_source = id
	retained_last_record = retained_sources[id]
	retained_append_sync()
	return id


# Record the bytes the tokenizer actually consumes, including speculative
# reads. Never reopen a pathname to manufacture a possibly different snapshot.
int retained_source_byte(char* path, int offset, int value):
	if (ast_retain_mode == 0): return 1
	if ((path == 0) || (offset < 0) || (value < 0)): return 1
	if (retained_last_path != path): retained_source_id(path)
	retained_source* source = retained_last_record
	if (offset < source.length): return (source.bytes[offset] & 255) == value
	retained_source_reserve(source, offset)
	retained_source_zero(source, source.length, offset)
	source.bytes[offset] = value
	if (value == 10): source.lines.push(offset + 1)
	if (source.length <= offset): source.length = offset + 1
	retained_append_sync()
	return 1



# P1.2b: record, or check against the recorded copy, count bytes the
# tokenizer's getchar window holds for path from file offset offset on. getc
# calls this when the lexer reaches a byte the version has not recorded yet
# (its window's remaining bytes) and whenever a read() refills the window
# (the whole new window: a byte read again from the file must not differ),
# so the per-byte path is one comparison. Bytes are therefore recorded up
# to the end of the window being read, a little ahead of the lexer; a
# compile that reads its file to the end records exactly the file either
# way. Returns 0 when a byte differs from its recorded copy.
int retained_source_window(char* path, int offset, char* bytes, int count):
	if (ast_retain_mode == 0): return 1
	if ((path == 0) || (offset < 0) || (count <= 0)): return 1
	if (retained_last_path != path): retained_source_id(path)
	retained_source* source = retained_last_record
	int end = offset + count
	int length = source.length
	int same = length - offset
	if (same > count): same = count
	if ((same > 0) && (retained_bytes_differ(source.bytes + offset, bytes, same) >= 0)): return 0
	if (end > length):
		retained_source_reserve(source, end)
		int from = length
		if (from < offset):
			retained_source_zero(source, length, offset)
			from = offset
		char* base = source.bytes
		int words = (end - from) / __word_size__
		retained_copy_words(cast(int*, base + from), cast(int*, bytes + (from - offset)), words)
		for i in range(from + words * __word_size__, end): base[i] = bytes[i - offset]
		# Line starts: a second pass over the copy, one compare per byte.
		char* scan = base + from
		char* stop = base + end
		while (scan != stop):
			if (*scan == 10): source.lines.push(cast(int, scan) - cast(int, base) + 1)
			scan = scan + 1
		source.length = end
	retained_append_sync()
	return 1


int retained_enter_interned(int kind, char* path, int start, int line, int column, char* name):
	if (ast_retain_mode == 0): return -1
	int source = retained_source_id(path)
	int parent = retained_parent
	if (parent < 0): parent = retained_sources[source].root
	int id = retained_add_interned(kind, parent, source, start, line, column, name)
	retained_parent = id
	return id


int retained_enter(int kind, char* path, int start, int line, int column, char* name):
	if (ast_retain_mode == 0): return -1
	return retained_enter_interned(kind, path, start, line, column, retained_intern(name))


void retained_leave(int id, int end):
	if (id < 0): return
	retained_record* record = retained_record_at(id)
	record.end = end
	retained_parent = record.parent
	if (retained_record_at(retained_parent).kind == retained_module): retained_parent = -1


void retained_capture(retained_checkpoint* checkpoint):
	checkpoint.pending_import = retained_pending_import
	checkpoint.nodes = retained_node_total
	checkpoint.sources = 0
	checkpoint.types = 0
	checkpoint.bindings = 0
	checkpoint.text = retained_arena_offset
	checkpoint.arena_chunk = retained_arena_index
	if (retained_types != 0): checkpoint.types = retained_types.length
	if (retained_bindings != 0): checkpoint.bindings = retained_bindings.length
	checkpoint.parent = retained_parent
	if (retained_sources != 0): checkpoint.sources = retained_sources.length


void retained_rollback(retained_checkpoint* checkpoint):
	retained_arena_generation = retained_arena_generation + 1
	retained_pending_import = checkpoint.pending_import
	retained_last_path = 0
	retained_append_none()
	retained_line_source = -1
	retained_semantic_rollback(checkpoint.types, checkpoint.bindings)
	# Node strings are interned or arena slices, so retracting the suffix
	# is a high-water mark; the chunks stay allocated for reuse.
	if (retained_node_total > checkpoint.nodes): retained_node_total = checkpoint.nodes
	if ((retained_arena_index > checkpoint.arena_chunk) || ((retained_arena_index == checkpoint.arena_chunk) && (retained_arena_offset > checkpoint.text))):
		retained_arena_index = checkpoint.arena_chunk
		retained_arena_offset = checkpoint.text
	if ((retained_sources != 0) && (retained_sources.length > checkpoint.sources)): retained_file_sources.clear()
	if (retained_sources != 0):
		while (retained_sources.length > checkpoint.sources):
			retained_source* source = retained_sources.pop()
			if (source.previous_version >= 0): retained_source_index[source.path] = source.previous_version
			else: retained_source_index.remove(source.path)
			source.lines.free()
			source.top_level.free()
			free(source.path)
			if (source.import_key != 0): free(source.import_key)
			if (source.bytes != 0): free(source.bytes)
			free(source)
		for i in range(retained_sources.length):
			retained_source* survivor = retained_sources[i]
			if (survivor.declaration_cursor > checkpoint.nodes): survivor.declaration_cursor = checkpoint.nodes
			list[int] top = survivor.top_level
			while ((top.length > 0) && (top[top.length - 1] >= checkpoint.nodes)): top.pop()
			if (survivor.top_cursor > top.length): survivor.top_cursor = top.length
	retained_parent = checkpoint.parent


void retained_clear():
	retained_checkpoint checkpoint
	checkpoint.pending_import = 0
	checkpoint.nodes = 0
	checkpoint.sources = 0
	checkpoint.parent = -1
	checkpoint.types = 0
	checkpoint.bindings = 0
	checkpoint.text = 0
	checkpoint.arena_chunk = 0
	retained_rollback(&checkpoint)
	if (retained_sources != 0): retained_sources.free()
	if (retained_source_index != 0): retained_source_index.free()
	if (retained_file_sources != 0): retained_file_sources.free()
	if (retained_node_table != 0): free(cast(char*, retained_node_table))
	if (retained_arena_chunks != 0):
		for i in range(retained_arena_count): free(cast(char*, retained_arena_chunks[i]))
		free(cast(char*, retained_arena_chunks))
		free(cast(char*, retained_arena_sizes))
	retained_node_table = 0
	retained_node_total = 0
	retained_node_room = 0
	retained_arena_chunks = 0
	retained_arena_sizes = 0
	retained_arena_count = 0
	retained_arena_room = 0
	retained_arena_index = 0
	retained_arena_offset = 0
	retained_sources = 0
	retained_source_index = 0
	retained_file_sources = 0
	retained_last_path = 0
	retained_append_none()
	retained_name_expression = 0
	retained_name_empty = 0
	if (retained_views != 0): free(cast(char*, retained_views))
	retained_views = 0
	retained_view_next = 0
	retained_operand_total = 0
	retained_text_total = 0
	retained_semantic_clear()
