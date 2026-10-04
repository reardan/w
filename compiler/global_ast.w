# Resolved global layouts own their field tree. Lowering reads byte sizes,
# offsets and array lengths, not the original type-table records.
struct global_storage_ast:
	int kind
	int size
	int offset
	int length
	global_storage_ast* children
	global_storage_ast* next


struct global_declaration_ast:
	int binding
	int declared_type
	int source_file
	int start_offset
	int end_offset
	int size
	int scalar_width
	int split
	int address
	int value
	global_storage_ast* storage


int ast_globals_emitted
int ast_global_initializers_emitted
int ast_thread_locals_emitted


global_storage_ast* global_storage_ast_build(int type, int offset):
	global_storage_ast* node = cast(global_storage_ast*, malloc(sizeof(global_storage_ast)))
	node.kind = 0
	node.size = type_get_size(type)
	node.offset = offset
	node.length = 0
	node.children = 0
	node.next = 0
	if (type_is_array(type)):
		node.kind = 1
		node.length = type_get_array_length(type)
	else if (type_num_args(type) > 0):
		node.kind = 2
		global_storage_ast* last = 0
		int i = 0
		while (i < type_num_args(type)):
			global_storage_ast* child = global_storage_ast_build(type_get_field_type_at(type, i), type_get_field_offset_at(type, i))
			if (last): last.next = child
			else: node.children = child
			last = child
			i = i + 1
	return node


void global_storage_ast_free(global_storage_ast* node):
	global_storage_ast* child = node.children
	while (child):
		global_storage_ast* next = child.next
		global_storage_ast_free(child)
		child = next
	free(cast(char*, node))
