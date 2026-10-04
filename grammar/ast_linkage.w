void ast_enum_value(int binding, int value):
	linkage_ast node
	node.kind = ast_linkage_enum
	node.binding = binding
	node.value = value
	node.split = target_isa == 2
	node.source_file = file
	node.start_offset = token_start_offset
	node.end_offset = token_start_offset
	emit_linkage_ast(&node)


void ast_extern_object(int binding, int size, char* name):
	linkage_ast node
	node.kind = ast_linkage_object
	node.binding = binding
	node.size = size
	node.split = data_split
	node.name = strclone(name)
	node.source_file = file
	node.start_offset = token_start_offset
	node.end_offset = token_start_offset
	emit_linkage_ast(&node)
	free(node.name)


void ast_extern_function(int binding, int return_type, char* name, char* import_name, int count, char* classes, int return_class, int variadic):
	linkage_ast node
	node.kind = ast_linkage_native
	node.binding = binding
	node.source_file = file
	node.start_offset = token_start_offset
	node.end_offset = token_start_offset
	node.parameter_count = count
	node.variadic = variadic
	node.return_class = return_class
	node.module_name = 0
	if (target_isa == 2):
		node.kind = ast_linkage_wasm
		if (variadic): error(c"variadic extern functions are not supported on the wasm target")
		node.return_kind = 1
		if (return_class == 1): node.return_kind = 2
		if (type_get_pointer_level(return_type) == 0):
			if (strcmp(type_get_name(return_type), c"void") == 0): node.return_kind = 0
		char* module_name = c"env"
		if (dyn_lib_count > 0): module_name = dyn_lib_name(dyn_lib_count - 1)
		node.module_name = strclone(module_name)
	node.name = strclone(name)
	node.import_name = strclone(import_name)
	node.parameter_classes = malloc(count + 1)
	for i in range(count): node.parameter_classes[i] = classes[i]
	node.parameter_classes[count] = 0
	emit_linkage_ast(&node)
	free(node.name)
	free(node.import_name)
	if (node.module_name): free(node.module_name)
	free(node.parameter_classes)
