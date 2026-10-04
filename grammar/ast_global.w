# Bind storage before parsing the constant initializer, preserving recursive
# name lookup and diagnostic order. The node stays live through both phases.
void ast_global_declaration(int binding, int type, char* init_name):
	global_declaration_ast node
	node.binding = binding
	node.declared_type = type
	node.source_file = file
	node.start_offset = token_start_offset
	node.size = global_storage_size(type)
	node.scalar_width = word_size
	int declared_size = type_get_size(type)
	if ((type_get_pointer_level(type) == 0) & (declared_size > 0) & (declared_size < word_size)):
		node.scalar_width = declared_size
	node.split = data_split
	node.storage = global_storage_ast_build(type, 0)
	emit_global_declaration_ast(&node)
	global_storage_ast_free(node.storage)
	node.storage = 0
	if (init_name):
		global_initializer_check_type(init_name, type)
		node.value = parse_constant_literal(c"initializer for global", init_name)
		node.end_offset = token_start_offset
		emit_global_initializer_ast(&node)
	else: node.end_offset = token_start_offset


void ast_thread_local_declaration(int binding, int type):
	global_declaration_ast node
	node.binding = binding
	node.declared_type = type
	node.size = global_storage_size(type)
	node.source_file = file
	node.start_offset = token_start_offset
	node.end_offset = token_start_offset
	emit_thread_local_ast(&node)
