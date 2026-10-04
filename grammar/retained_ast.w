# Copy the semantic type graph before temporary compiler tables are reused.
# Cache entries are invalidated at source-version boundaries and rollback.
# Exact record comparison also detects forward records completed in the same source.
int retained_type_matches(retained_type* type, type_rec* original):
	if (type.building): return 1
	if (strcmp(type.name, original.name) != 0): return 0
	if (strcmp(type.file, debug_file_name(original.decl_file_index)) != 0): return 0
	if ((type.line != original.decl_line) || (type.column != original.decl_column)): return 0
	if ((type.kind != original.kind) || (type.size != original.total_size) || (type.pointer_level != original.pointer_level)): return 0
	if ((type.origin_target != original.alias_target) || (type.origin_return != original.fn_return_type) || (type.origin_parameters != original.fn_param_count)): return 0
	if (type.fields.length != original.num_fields): return 0
	for i in range(original.num_fields):
		retained_field* field = type.fields[i]
		if (strcmp(field.name, original.field_names[i]) != 0): return 0
		if (retained_types[field.type].origin != type_real(original.field_types[i])): return 0
	if (original.kind == type_kind_function):
		for i in range(original.fn_param_count):
			if (retained_types[type.parameters[i]].origin != type_real(original.fn_param_types[i])): return 0
	int constants = 0
	if ((original.kind == type_kind_enum) && (enum_constants != 0)):
		for i in range(enum_constants.length):
			if (enum_constants[i].type == type.origin):
				if (constants >= type.constants.length): return 0
				retained_constant* member = type.constants[constants]
				if (strcmp(member.name, enum_constants[i].name) != 0): return 0
				if (member.value != enum_constants[i].value): return 0
				constants = constants + 1
	if (constants != type.constants.length): return 0
	return 1


int retained_type_note(int index):
	index = type_real(index)
	if ((index < 0) || (index >= type_count())): return -1
	type_rec* original = type_record(index)
	if (retained_type_cache == 0): retained_type_cache = new map[int, int]
	if (index in retained_type_cache):
		int existing = retained_type_cache[index]
		if (retained_type_matches(retained_types[existing], original)): return existing
	if (retained_types == 0): retained_types = new list[retained_type*]
	retained_type* type = new retained_type
	type.name = strclone(original.name)
	type.file = strclone(debug_file_name(original.decl_file_index))
	type.source = -1
	for i in range(retained_sources.length):
		if (strcmp(retained_sources[i].path, type.file) == 0): type.source = i
	type.line = original.decl_line
	type.column = original.decl_column
	type.kind = original.kind
	type.size = original.total_size
	type.pointer_level = original.pointer_level
	type.target = -1
	type.return_type = -1
	type.array_length = -1
	type.origin = index
	type.origin_target = original.alias_target
	type.origin_return = original.fn_return_type
	type.origin_parameters = original.fn_param_count
	type.building = 1
	type.fields = new list[retained_field*]
	type.parameters = new list[int]
	type.constants = new list[retained_constant*]
	int id = retained_types.length
	retained_types.push(type)
	# Publish before recursion: pointers and fields may form cycles.
	retained_type_cache[index] = id
	if (original.alias_target >= 0): type.target = retained_type_note(original.alias_target)
	if (original.pointer_level > 0):
		int base = type_lookup_previous_pointer(index)
		if (base >= 0): type.target = retained_type_note(base)
	if (original.kind == type_kind_array): type.array_length = original.fn_return_type
	if ((original.kind == type_kind_function) || (original.kind == type_kind_map)):
		type.return_type = retained_type_note(original.fn_return_type)
	if (original.kind == type_kind_function):
		for i in range(original.fn_param_count): type.parameters.push(retained_type_note(original.fn_param_types[i]))
	for i in range(original.num_fields):
		retained_field* field = new retained_field
		field.name = strclone(original.field_names[i])
		field.type = retained_type_note(original.field_types[i])
		field.offset = type_get_field_offset_at(index, i)
		type.fields.push(field)
	if ((original.kind == type_kind_enum) && (enum_constants != 0)):
		for i in range(enum_constants.length):
			if (enum_constants[i].type == index):
				retained_constant* member = new retained_constant
				member.name = strclone(enum_constants[i].name)
				member.value = enum_constants[i].value
				type.constants.push(member)
	type.building = 0
	return id


void retained_key_int(char* key, int value):
	char* text = itoa(value)
	strappend(key, text)
	strappend(key, c":")
	free(text)


int retained_binding_note(int sym, int owner):
	if (sym < 0): return -1
	sym_index_sync()
	int low = 0
	int high = sym_index_count
	while (low < high):
		int mid = (low + high) / 2
		if (sym_index_offset(mid) < sym): low = mid + 1
		else: high = mid
	if (low >= sym_index_count): return -1
	if (sym_index_offset(low) != sym): return -1
	char* name = table + sym_index_name_start(low)
	int scope = table[sym + 1]
	char* path = debug_file_name(load_int(table + sym + 66))
	int line = load_int(table + sym + 70)
	int column = load_int(table + sym + 74)
	int source = -1
	for i in range(retained_sources.length):
		if (strcmp(retained_sources[i].path, path) == 0): source = i
	int declaration = owner
	if ((scope == 'L') || (scope == 'A')):
		while ((owner >= 0) && (retained_nodes[owner].kind != retained_function)): owner = retained_nodes[owner].parent
	else: owner = -1
	char* key = malloc(strlen(path) + strlen(name) + 160)
	key[0] = 0
	retained_key_int(key, source)
	retained_key_int(key, owner)
	retained_key_int(key, scope)
	retained_key_int(key, line)
	retained_key_int(key, column)
	retained_key_int(key, strlen(path))
	strappend(key, path)
	strappend(key, name)
	if (retained_binding_cache == 0): retained_binding_cache = new map[char*, int]
	if (key in retained_binding_cache):
		int existing = retained_binding_cache[key]
		free(key)
		return existing
	if (retained_bindings == 0): retained_bindings = new list[retained_binding*]
	retained_binding* binding = new retained_binding
	binding.key = key
	binding.name = strclone(name)
	binding.file = strclone(path)
	binding.line = line
	binding.column = column
	# Inferred declarations bind after parsing the initializer. Their raw
	# symbol location can therefore point at the next token. Keep that
	# location in the lookup key so later uses find this same record, but
	# give the owned declaration its original name location. Do not change
	# production diagnostics as a side effect of retaining a tree.
	if ((scope == 'L') && (declaration >= 0)):
		retained_node* node = retained_nodes[declaration]
		if ((node.kind == retained_statement) && (strcmp(node.name, name) == 0)):
			binding.line = node.line
			binding.column = node.column
	binding.scope = scope
	binding.slot = load_int(table + sym + 2)
	binding.source = source
	binding.owner = owner
	binding.type = retained_type_note(load_int(table + sym + 6))
	binding.origin = sym
	binding.linkage = retained_bindings.length
	# Forward declarations and their eventual definition share a linkage
	# identity. A later REPL definition starts a new identity; no surviving
	# record is mutated, so suffix rollback needs no semantic undo log.
	if ((scope == 'U') || (scope == 'D')):
		int previous = retained_bindings.length
		while (previous > 0):
			previous = previous - 1
			retained_binding* candidate = retained_bindings[previous]
			if ((candidate.origin == sym) && (strcmp(candidate.name, name) == 0)):
				if (candidate.scope == 'U'): binding.linkage = candidate.linkage
				break
	binding.return_type = -1
	binding.parameters = new list[int]
	if (load_int(table + sym + 10) == 2):
		binding.return_type = binding.type
		int count = load_int(table + sym + 22)
		for i in range(count): binding.parameters.push(retained_type_note(sym_param_type(sym, i)))
	int id = retained_bindings.length
	retained_bindings.push(binding)
	retained_binding_cache[key] = id
	return id


# Retain the production traversal without keeping pointers into temporary
# expression arenas or the symbol/type tables. Operand indices are local to
# each expression group and retain the production op-specific interpretation.
void retained_expression_note(expression_ast* tree, int root):
	if (ast_retain_mode == 0): return
	int start_offset = tree.offset[root]
	for i in range(tree.count):
		if (tree.offset[i] < start_offset): start_offset = tree.offset[i]
	int group = retained_enter(retained_expression_group, filename, start_offset, 0, 0, c"expression")
	retained_node* owner = retained_nodes[group]
	owner.op = root
	owner.readonly = tree.readonly
	owner.whole_expression = tree.whole_expression
	owner.final_token_offset = tree.final_token_offset
	owner.arena_text_length = tree.text_used
	owner.arena_text = malloc(tree.text_used + 1)
	for i in range(tree.text_used): owner.arena_text[i] = tree.text[i]
	owner.arena_text[tree.text_used] = 0
	owner.arena_type_names_length = tree.type_names_used
	owner.arena_type_names = malloc(tree.type_names_used + 1)
	for i in range(tree.type_names_used): owner.arena_type_names[i] = tree.type_names[i]
	owner.arena_type_names[tree.type_names_used] = 0
	for i in range(tree.count):
		int id = retained_add(retained_expression, group, owner.source, tree.offset[i], 0, 0, c"")
		retained_node* node = retained_nodes[id]
		node.op = tree.op[i]
		node.value = tree.value[i]
		node.high = tree.high[i]
		node.symbol = tree.symbol[i]
		node.in_cast = tree.in_cast[i]
		node.binding_offset = tree.binding_offset[i]
		node.binding_text_offset = tree.binding_name[i]
		node.it_slot = tree.it_slot[i]
		node.qualified = tree.qualified[i]
		node.generic_parameters = tree.generic_parameters[i]
		node.generic_offset = tree.generic_offset[i]
		node.generic_instance = tree.generic_instance[i]
		node.generic_arity = tree.generic_arity[i]
		node.infer_coercion = tree.infer_coercion[i]
		node.left = tree.left[i]
		node.right = tree.right[i]
		node.next_arg = tree.next_arg[i]
		node.end = tree.end_offset
		node.semantic_type = retained_type_note(tree.result_type[i])
		node.result_is_value = type_is_value(tree.result_type[i])
		node.generic_signature = retained_type_note(tree.generic_signature[i])
		node.call_receiver_type = retained_type_note(tree.call_receiver_type[i])
		node.infer_want = retained_type_note(tree.infer_want[i])
		int type = type_real(tree.result_type[i])
		if ((type >= 0) && (type < type_count())):
			node.result_type = strclone(type_get_name(type))
			node.type_size = type_get_size(type)
			node.type_pointer_level = type_get_pointer_level(type)
		# These opcodes always carry a symbol-table binding. Other opcodes
		# overload the same slot with type/format/diagnostic information.
		int op = tree.op[i]
		if ((op == 'G') || (op == 'W')): node.payload_text = strclone(generic_def_name(tree.value[i]))
		if (op == ast_warning):
			if ((node.high == 0) || (node.high == 6) || (node.high == 7)):
				node.payload_text = strclone(cast(char*, tree.value[i]))
				node.value = 0
			if ((node.high == 1) || (node.high == 2) || (node.high == 5)):
				char* message = table + tree.value[i]
				if ((node.high == 5) && tree.symbol[i]): message = c"it"
				node.payload_text = strclone(message)
				node.value = 0
		if ((op == 'v') || (op == 'C') || (op == 'X') || (op == 'z') || (op == 'l')):
			char* name = table + tree.value[i]
			if (tree.binding_name[i] >= 0): name = &tree.text[tree.binding_name[i]]
			node.payload_text = strclone(name)
			node.value = 0
		if ((op == 0) || (op == 'c') || (op == 'h') || (op == 'f')):
			node.literal_value = tree.value[i]
			if ((op == 'f') && (word_size == 8)): node.literal_high = tree.high[i]
		if ((op == 's') || (op == 'S') || (op == 't')):
			node.literal_length = tree.high[i]
			node.literal_text = malloc(node.literal_length + 1)
			for j in range(node.literal_length): node.literal_text[j] = tree.text[tree.value[i] + j]
			node.literal_text[node.literal_length] = 0
		if ((op == 'v') || (op == 'C') || (op == 'X') || (op == 'z') || (op == 'l') || (op == 'G') || (op == 'W')):
			node.binding = retained_binding_note(tree.symbol[i], group)
			if (node.binding >= 0):
				retained_binding* binding = retained_bindings[node.binding]
				node.binding_name = strclone(binding.name)
				node.binding_file = strclone(binding.file)
				node.binding_line = binding.line
				node.binding_column = binding.column
				node.binding_scope = binding.scope
				node.binding_slot = binding.slot

	retained_leave(group, tree.end_offset)


# Definition hooks run after the declaration. Adopt its already retained
# function/initializer children instead of creating a second parser.
void retained_declaration_note(char* name, char* kind, int start, int end, int line, int column):
	if (ast_retain_mode == 0): return
	int source = retained_source_id(filename)
	int module = retained_sources[source].root
	int id = retained_add(retained_declaration, module, source, start, line, column, name)
	retained_nodes[id].end = end
	retained_nodes[id].result_type = strclone(kind)
	retained_semantic_invalidate()
	if ((strcmp(kind, c"function") == 0) || (strcmp(kind, c"global") == 0) || (strcmp(kind, c"const") == 0)):
		retained_nodes[id].binding = retained_binding_note(sym_probe(name), id)
		if (retained_nodes[id].binding >= 0): retained_nodes[id].semantic_type = retained_bindings[retained_nodes[id].binding].type
	else: retained_nodes[id].semantic_type = retained_type_note(type_lookup(name))
	int cursor = retained_sources[source].declaration_cursor
	retained_sources[source].declaration_cursor = id + 1
	for i in range(cursor, id):
		retained_node* child = retained_nodes[i]
		if ((child.parent == module) && (child.source == source) && (child.start >= start) && (child.end <= end)):
			child.parent = id


# Imports remain explicit module children even when their target has already
# been compiled. Record the resolver's normalized module spelling, not a
# guessed absolute pathname or an ambiguous source-version identity.
void retained_import_note(char* spelling, char* path, char* alias, int start, int end, int line, int column):
	if (ast_retain_mode == 0): return
	int source = retained_source_id(filename)
	int id = retained_add(retained_import, retained_sources[source].root, source, start, line, column, spelling)
	retained_node* node = retained_nodes[id]
	node.end = end
	node.import_path = strclone(path)
	if (alias != 0): node.import_alias = strclone(alias)


# Inventory declarations even when no expression refers to them. The parent
# preserves lexical block membership; binding.owner identifies the function.
void retained_local_note(int sym):
	if ((ast_retain_mode == 0) || (retained_parent < 0)): return
	int owner = retained_parent
	while ((owner >= 0) && (retained_nodes[owner].kind != retained_function)): owner = retained_nodes[owner].parent
	if (owner < 0): return
	int binding = retained_binding_note(sym, retained_parent)
	if (binding < 0): return
	retained_binding* record = retained_bindings[binding]
	int source = record.source
	if (source < 0): return
	int offset = 0
	retained_source* input = retained_sources[source]
	if ((record.line > 0) && (record.line <= input.lines.length)):
		offset = input.lines[record.line - 1] + record.column - 1
	int id = retained_add(retained_local, retained_parent, source, offset, record.line, record.column, record.name)
	retained_nodes[id].binding = binding
	retained_nodes[id].semantic_type = record.type
	retained_nodes[id].end = offset + strlen(record.name)
	# Native parameters are inventoried after their header was parsed. The
	# function originally entered at its body delimiter; include parameters
	# in that retained span without moving the production tokenizer.
	retained_node* parent = retained_nodes[retained_parent]
	if ((record.scope == 'A') && (parent.kind == retained_function) && (parent.source == source) && (offset < parent.start)):
		parent.start = offset
		parent.line = record.line
		parent.column = record.column


void retained_function_parameters(int binding):
	if (ast_retain_mode == 0): return
	if (retained_parent >= 0):
		retained_nodes[retained_parent].binding = retained_binding_note(binding, retained_parent)
	sym_index_sync()
	for i in range(sym_index_count):
		int sym = sym_index_offset(i)
		if ((sym > binding) && (table[sym + 1] == 'A')): retained_local_note(sym)
