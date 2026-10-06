# Session-owned production traversal trees with independent semantic records.
# Backend-specific operands retain their production interpretation; emission
# still runs through the immediate visitor, not by reloading this forest.
# IDs are append-only within a session. A checkpoint retracts its suffix;
# consumers must not keep IDs from a retracted entry.
# Storage: nodes live in fixed-size chunks owned by the session, and their
# strings are either interned (retained_intern) or slices of the session's
# chunked text arena. Rollback is therefore a high-water mark: it truncates
# the node list and the text arena without freeing per-node allocations.
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

struct retained_checkpoint:
	char* pending_import
	int nodes
	int sources
	int parent
	int types
	int bindings
	int text

int ast_retain_mode
# Borrowed resolver context, restored by both normal return and rollback.
char* retained_pending_import
list[retained_source*] retained_sources
list[retained_node*] retained_nodes
int retained_parent = -1
char* retained_last_path
int retained_last_source
retained_source* retained_last_record
# Newest source version per path; older versions chain via previous_version.
map[char*, int] retained_source_index
# Newest source version per debug file index (-2 = not looked up yet). A
# debug file index names one path for the whole process, so this is the path
# index keyed by integer; it is emptied whenever the path index changes.
list[int] retained_file_sources

# Node chunks: node i lives in slot i % chunk of chunk i / chunk, and
# retained_nodes[i] points at it. Chunks above the high-water mark survive
# rollback and are reused; retained_clear frees them.
const int retained_node_chunk_shift = 10
const int retained_node_chunk = 1024
list[char*] retained_node_chunks

# Text arena for copied expression arenas. A record never spans a chunk;
# expression text and type-name arenas are bounded far below one chunk
# (grammar/ast_expression.w asserts 32 KiB and 4 KiB respectively).
const int retained_text_chunk_shift = 17
const int retained_text_chunk = 131072
list[char*] retained_text_chunks
int retained_text_mark


void retained_init():
	if (retained_nodes == 0): retained_nodes = new list[retained_node*]
	if (retained_sources == 0): retained_sources = new list[retained_source*]
	if (retained_node_chunks == 0): retained_node_chunks = new list[char*]
	if (retained_text_chunks == 0): retained_text_chunks = new list[char*]
	if (retained_source_index == 0): retained_source_index = new map[char*, int]
	if (retained_file_sources == 0): retained_file_sources = new list[int]


# Copy length bytes plus a terminator into the session text arena.
char* retained_text_copy(char* text, int length):
	retained_init()
	int size = length + 1
	if (size > retained_text_chunk): __w_trap(c"retained text record exceeds an arena chunk")
	int offset = retained_text_mark & (retained_text_chunk - 1)
	if (offset + size > retained_text_chunk):
		retained_text_mark = retained_text_mark - offset + retained_text_chunk
		offset = 0
	int index = retained_text_mark >> retained_text_chunk_shift
	while (retained_text_chunks.length <= index): retained_text_chunks.push(malloc(retained_text_chunk))
	char* copy = retained_text_chunks[index] + offset
	for i in range(length): copy[i] = text[i]
	copy[length] = 0
	retained_text_mark = retained_text_mark + size
	return copy


int retained_add(int kind, int parent, int source, int start, int line, int column, char* name):
	retained_init()
	int id = retained_nodes.length
	int chunk = id >> retained_node_chunk_shift
	if (chunk >= retained_node_chunks.length): retained_node_chunks.push(malloc(retained_node_chunk * sizeof(retained_node)))
	retained_node* node = cast(retained_node*, retained_node_chunks[chunk] + (id & (retained_node_chunk - 1)) * sizeof(retained_node))
	node.import_source = -1
	node.import_path = 0
	node.import_alias = 0
	node.payload_text = 0
	node.arena_text = 0
	node.arena_type_names = 0
	node.arena_text_length = 0
	node.arena_type_names_length = 0
	node.semantic_type = -1
	node.value = 0
	node.high = 0
	node.symbol = 0
	node.in_cast = 0
	node.binding_offset = 0
	node.binding_text_offset = -1
	node.it_slot = 0
	node.readonly = 0
	node.whole_expression = 0
	node.final_token_offset = 0
	node.qualified = 0
	node.generic_parameters = 0
	node.generic_offset = 0
	node.generic_instance = 0
	node.generic_arity = 0
	node.infer_coercion = 0
	node.result_is_value = 0
	node.binding = -1
	node.generic_signature = -1
	node.call_receiver_type = -1
	node.infer_want = -1
	node.op = 0
	node.literal_value = 0
	node.literal_high = 0
	node.literal_text = 0
	node.literal_length = 0
	node.type_size = 0
	node.type_pointer_level = 0
	node.result_type = 0
	node.binding_name = 0
	node.binding_file = 0
	node.binding_line = 0
	node.binding_column = 0
	node.binding_scope = 0
	node.binding_slot = 0
	node.kind = kind
	node.parent = parent
	node.source = source
	node.start = start
	node.end = start
	node.line = line
	node.column = column
	if ((line == 0) && (source >= 0)):
		retained_source* location = retained_sources[source]
		int low = 0
		int high = location.lines.length
		while (low < high):
			int mid = (low + high) / 2
			if (location.lines[mid] <= start): low = mid + 1
			else: high = mid
		if (low > 0):
			node.line = low
			node.column = start - location.lines[low - 1] + 1
	node.name = retained_intern(name)
	node.left = -1
	node.right = -1
	node.next_arg = -1
	retained_nodes.push(node)
	if ((source >= 0) && (parent >= 0)):
		retained_source* owner = retained_sources[source]
		if (owner.root == parent): owner.top_level.push(id)
	return id


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
	return id


# Record the bytes the tokenizer actually consumes, including speculative
# reads. Never reopen a pathname to manufacture a possibly different snapshot.
int retained_source_byte(char* path, int offset, int value):
	if (ast_retain_mode == 0): return 1
	if ((path == 0) || (offset < 0) || (value < 0)): return 1
	if (retained_last_path != path): retained_source_id(path)
	retained_source* source = retained_last_record
	if (offset < source.length): return (source.bytes[offset] & 255) == value
	if (offset >= source.capacity):
		int capacity = source.capacity
		if (capacity == 0): capacity = 1024
		while (capacity <= offset): capacity = capacity * 2
		source.bytes = realloc(source.bytes, source.capacity, capacity)
		for i in range(source.capacity, capacity): source.bytes[i] = 0
		source.capacity = capacity
	source.bytes[offset] = value
	if (value == 10): source.lines.push(offset + 1)
	if (source.length <= offset): source.length = offset + 1
	retained_nodes[source.root].end = source.length
	return 1


int retained_enter(int kind, char* path, int start, int line, int column, char* name):
	if (ast_retain_mode == 0): return -1
	int source = retained_source_id(path)
	int parent = retained_parent
	if (parent < 0): parent = retained_sources[source].root
	int id = retained_add(kind, parent, source, start, line, column, name)
	retained_parent = id
	return id


void retained_leave(int id, int end):
	if (id < 0): return
	retained_nodes[id].end = end
	retained_parent = retained_nodes[id].parent
	if (retained_nodes[retained_parent].kind == retained_module): retained_parent = -1


void retained_capture(retained_checkpoint* checkpoint):
	checkpoint.pending_import = retained_pending_import
	checkpoint.nodes = 0
	checkpoint.sources = 0
	checkpoint.types = 0
	checkpoint.bindings = 0
	checkpoint.text = retained_text_mark
	if (retained_types != 0): checkpoint.types = retained_types.length
	if (retained_bindings != 0): checkpoint.bindings = retained_bindings.length
	checkpoint.parent = retained_parent
	if (retained_nodes != 0): checkpoint.nodes = retained_nodes.length
	if (retained_sources != 0): checkpoint.sources = retained_sources.length


void retained_rollback(retained_checkpoint* checkpoint):
	retained_pending_import = checkpoint.pending_import
	retained_last_path = 0
	retained_semantic_rollback(checkpoint.types, checkpoint.bindings)
	# Node strings are interned or arena slices, so retracting the suffix
	# is a high-water mark; the chunks stay allocated for reuse.
	if (retained_nodes != 0):
		while (retained_nodes.length > checkpoint.nodes): retained_nodes.pop()
	if (retained_text_mark > checkpoint.text): retained_text_mark = checkpoint.text
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
	retained_rollback(&checkpoint)
	if (retained_nodes != 0): retained_nodes.free()
	if (retained_sources != 0): retained_sources.free()
	if (retained_source_index != 0): retained_source_index.free()
	if (retained_file_sources != 0): retained_file_sources.free()
	if (retained_node_chunks != 0):
		for i in range(retained_node_chunks.length): free(retained_node_chunks[i])
		retained_node_chunks.free()
	if (retained_text_chunks != 0):
		for i in range(retained_text_chunks.length): free(retained_text_chunks[i])
		retained_text_chunks.free()
	retained_nodes = 0
	retained_sources = 0
	retained_source_index = 0
	retained_file_sources = 0
	retained_node_chunks = 0
	retained_text_chunks = 0
	retained_text_mark = 0
	retained_last_path = 0
	retained_semantic_clear()
