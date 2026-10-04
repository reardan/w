# Session-owned production traversal trees with independent semantic records.
# Backend-specific operands retain their production interpretation; emission
# still runs through the immediate visitor, not by reloading this forest.
# IDs are append-only within a session. A checkpoint retracts its suffix;
# consumers must not keep IDs from a retracted entry.
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

int ast_retain_mode
# Borrowed resolver context, restored by both normal return and rollback.
char* retained_pending_import
list[retained_source*] retained_sources
list[retained_node*] retained_nodes
int retained_parent = -1
char* retained_last_path
int retained_last_source


void retained_init():
	if (retained_nodes == 0): retained_nodes = new list[retained_node*]
	if (retained_sources == 0): retained_sources = new list[retained_source*]


int retained_add(int kind, int parent, int source, int start, int line, int column, char* name):
	retained_init()
	retained_node* node = new retained_node
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
	node.name = strclone(name)
	node.left = -1
	node.right = -1
	node.next_arg = -1
	int id = retained_nodes.length
	retained_nodes.push(node)
	return id


# A fresh compile owns a fresh source version, even at a reused pathname.
int retained_source_begin(char* path):
	retained_init()
	retained_source* source = new retained_source
	retained_semantic_invalidate()
	source.lines = new list[int]
	source.lines.push(0)
	source.bytes = 0
	source.length = 0
	source.capacity = 0
	source.declaration_cursor = 0
	source.path = strclone(path)
	source.import_key = 0
	int id = retained_sources.length
	retained_sources.push(source)
	retained_last_path = path
	retained_last_source = id
	source.root = retained_add(retained_module, -1, id, 0, 1, 1, path)
	return id


int retained_source_id(char* path):
	retained_init()
	if ((retained_last_path == path) && (retained_sources.length > 0)):
		if (strcmp(retained_sources[retained_last_source].path, path) == 0): return retained_last_source
	retained_last_path = path
	int i = retained_sources.length
	while (i > 0):
		i = i - 1
		if (strcmp(retained_sources[i].path, path) == 0):
			retained_last_source = i
			return i
	return retained_source_begin(path)


# Record the bytes the tokenizer actually consumes, including speculative
# reads. Never reopen a pathname to manufacture a possibly different snapshot.
int retained_source_byte(char* path, int offset, int value):
	if (ast_retain_mode == 0): return 1
	if ((path == 0) || (offset < 0) || (value < 0)): return 1
	int id = retained_source_id(path)
	retained_source* source = retained_sources[id]
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
	if (retained_types != 0): checkpoint.types = retained_types.length
	if (retained_bindings != 0): checkpoint.bindings = retained_bindings.length
	checkpoint.parent = retained_parent
	if (retained_nodes != 0): checkpoint.nodes = retained_nodes.length
	if (retained_sources != 0): checkpoint.sources = retained_sources.length


void retained_rollback(retained_checkpoint* checkpoint):
	retained_pending_import = checkpoint.pending_import
	retained_last_path = 0
	retained_semantic_rollback(checkpoint.types, checkpoint.bindings)
	if (retained_nodes != 0):
		while (retained_nodes.length > checkpoint.nodes):
			retained_node* node = retained_nodes.pop()
			free(node.name)
			if (node.import_path != 0): free(node.import_path)
			if (node.import_alias != 0): free(node.import_alias)
			if (node.payload_text != 0): free(node.payload_text)
			if (node.arena_text != 0): free(node.arena_text)
			if (node.arena_type_names != 0): free(node.arena_type_names)
			if (node.literal_text != 0): free(node.literal_text)
			if (node.result_type != 0): free(node.result_type)
			if (node.binding_name != 0): free(node.binding_name)
			if (node.binding_file != 0): free(node.binding_file)
			free(node)
	if (retained_sources != 0):
		while (retained_sources.length > checkpoint.sources):
			retained_source* source = retained_sources.pop()
			source.lines.free()
			free(source.path)
			if (source.import_key != 0): free(source.import_key)
			if (source.bytes != 0): free(source.bytes)
			free(source)
	if (retained_sources != 0):
		for i in range(retained_sources.length):
			if (retained_sources[i].declaration_cursor > checkpoint.nodes): retained_sources[i].declaration_cursor = checkpoint.nodes
	retained_parent = checkpoint.parent


void retained_clear():
	retained_checkpoint checkpoint
	checkpoint.pending_import = 0
	checkpoint.nodes = 0
	checkpoint.sources = 0
	checkpoint.parent = -1
	checkpoint.types = 0
	checkpoint.bindings = 0
	retained_rollback(&checkpoint)
	if (retained_nodes != 0): retained_nodes.free()
	if (retained_sources != 0): retained_sources.free()
	retained_nodes = 0
	retained_sources = 0
	retained_semantic_clear()
