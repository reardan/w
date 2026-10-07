import code_generator.retained_emit


# A debug file index names one path for the whole process; every index
# outside the table names the empty path and shares the key -1.
int retained_file_key(int index):
	if ((index < 0) || (index >= debug_file_count)): return -1
	return index


# Newest source version recorded for a debug file index, or -1.
int retained_file_source(int index):
	retained_init()
	if ((index < 0) || (index >= debug_file_count)): return retained_source_find(debug_file_name(index))
	while (retained_file_sources.length <= index): retained_file_sources.push(-2)
	int source = retained_file_sources[index]
	if (source == -2):
		source = retained_source_find(debug_file_name(index))
		retained_file_sources[index] = source
	return source


# Copy the semantic type graph before temporary compiler tables are reused.
# Cache entries are invalidated at source-version boundaries and rollback.
# Exact record comparison also detects forward records completed in the same source.
int retained_type_matches(retained_type* type, type_rec* original):
	if (type.building): return 1
	if (strcmp(type.name, original.name) != 0): return 0
	if (type.file_index != retained_file_key(original.decl_file_index)): return 0
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
	int existing = retained_type_cached(index)
	if (existing >= 0):
		if (retained_type_matches(retained_types[existing], original)): return existing
	if (retained_types == 0): retained_types = new list[retained_type*]
	retained_type* type = new retained_type
	type.name = retained_intern(original.name)
	type.file = retained_intern(debug_file_name(original.decl_file_index))
	type.file_index = retained_file_key(original.decl_file_index)
	type.source = retained_file_source(original.decl_file_index)
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
	retained_type_cache_set(index, id)
	if (original.alias_target >= 0): type.target = retained_type_note(original.alias_target)
	if (original.pointer_level > 0):
		int base = type_lookup_previous_pointer(index)
		if (base >= 0): type.target = retained_type_note(base)
	if (original.kind == type_kind_array): type.array_length = original.fn_return_type
	if ((original.kind == type_kind_function) || (original.kind == type_kind_map)):
		type.return_type = retained_type_note(original.fn_return_type)
	if (original.kind == type_kind_function):
		for i in range(original.fn_param_count): type.parameters.push(retained_type_note(original.fn_param_types[i]))
	# S2.5: type_get_field_offset_at(index, i), summed as the fields go
	# instead of from the first field each time.
	int layout_index = type_canonical(index)
	type_rec* layout = type_record(layout_index)
	int layout_union = type_get_kind(layout_index) == type_kind_union
	int layout_offset = 0
	for i in range(original.num_fields):
		retained_field* field = new retained_field
		field.name = retained_intern(original.field_names[i])
		field.type = retained_type_note(original.field_types[i])
		field.offset = layout_offset
		if (layout_union): field.offset = 0
		if (i + 1 < original.num_fields): layout_offset = layout_offset + type_get_size(layout.field_types[i])
		type.fields.push(field)
	if ((original.kind == type_kind_enum) && (enum_constants != 0)):
		for i in range(enum_constants.length):
			if (enum_constants[i].type == index):
				retained_constant* member = new retained_constant
				member.name = retained_intern(enum_constants[i].name)
				member.value = enum_constants[i].value
				type.constants.push(member)
	type.building = 0
	return id


# Append value and a ':' separator at key[at]; returns the new length.
int retained_key_int(char* key, int at, int value):
	if (value < 0):
		key[at] = '-'
		at = at + 1
		value = 0 - value
	int begin = at
	while (1):
		key[at] = '0' + value % 10
		at = at + 1
		value = value / 10
		if (value == 0): break
	int last = at - 1
	while (begin < last):
		int swap = key[begin]
		key[begin] = key[last]
		key[last] = swap
		begin = begin + 1
		last = last - 1
	key[at] = ':'
	return at + 1


int retained_key_text(char* key, int at, char* text, int length):
	for i in range(length): key[at + i] = text[i]
	return at + length


# 1 when binding's lookup key is the one retained_binding_note spells for
# these fields.
int retained_binding_is(retained_binding* binding, int source, int owner, int scope, int line, int column, int file_index, char* name):
	if ((binding.source != source) || (binding.owner != owner) || (binding.scope != scope)): return 0
	if ((binding.key_line != line) || (binding.key_column != column) || (binding.key_file_index != file_index)): return 0
	return strcmp(binding.name, name) == 0


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
	int file_index = load_int(table + sym + 66)
	char* path = debug_file_name(file_index)
	int line = load_int(table + sym + 70)
	int column = load_int(table + sym + 74)
	int source = retained_file_source(file_index)
	int declaration = owner
	if ((scope == 'L') || (scope == 'A')):
		while ((owner >= 0) && (retained_record_at(owner).kind != retained_function)): owner = retained_record_at(owner).parent
	else: owner = -1
	# S2.5: a binding whose key fields all match is the one the key map
	# would return (keys are unique), so try the front cache and then the
	# raw symbol's own chain before spelling the key.
	if (retained_binding_front == 0):
		retained_binding_front = cast(int*, malloc(retained_binding_slots * __word_size__))
		for i in range(retained_binding_slots): retained_binding_front[i] = -1
	int front = (sym >> 2) & (retained_binding_slots - 1)
	int candidate = retained_binding_front[front]
	if ((candidate >= 0) && (candidate < retained_bindings.length)):
		if (retained_binding_is(retained_bindings[candidate], source, owner, scope, line, column, file_index, name)): return candidate
	if (retained_binding_origins != 0):
		candidate = retained_binding_origins.get(sym, -1)
		while (candidate >= 0):
			retained_binding* record = retained_bindings[candidate]
			if (retained_binding_is(record, source, owner, scope, line, column, file_index, name)):
				retained_binding_front[front] = candidate
				return candidate
			candidate = record.origin_previous
	# A debug file index names exactly one path for the whole process, so
	# it identifies the declaring file as the path itself would.
	int name_length = strlen(name)
	if (retained_key_capacity < name_length + 160):
		if (retained_key_buffer != 0): free(retained_key_buffer)
		retained_key_capacity = name_length + 256
		retained_key_buffer = cast(char*, malloc(retained_key_capacity))
	char* key = retained_key_buffer
	int at = retained_key_int(key, 0, source)
	at = retained_key_int(key, at, owner)
	at = retained_key_int(key, at, scope)
	at = retained_key_int(key, at, line)
	at = retained_key_int(key, at, column)
	at = retained_key_int(key, at, file_index)
	at = retained_key_text(key, at, name, name_length)
	key[at] = 0
	if (retained_binding_cache == 0):
		retained_binding_cache = new map[char*, int]
		retained_binding_origins = new map[int, int]
	int existing = retained_binding_cache.get(key, -1)
	if (existing >= 0):
		retained_binding_front[front] = existing
		return existing
	key = strclone(key)
	if (retained_bindings == 0): retained_bindings = new list[retained_binding*]
	retained_binding* binding = new retained_binding
	binding.key = key
	binding.name = retained_intern(name)
	binding.file = retained_intern(path)
	binding.line = line
	binding.column = column
	binding.key_line = line
	binding.key_column = column
	binding.key_file_index = file_index
	# Inferred declarations bind after parsing the initializer. Their raw
	# symbol location can therefore point at the next token. Keep that
	# location in the lookup key so later uses find this same record, but
	# give the owned declaration its original name location. Do not change
	# production diagnostics as a side effect of retaining a tree.
	if ((scope == 'L') && (declaration >= 0)):
		retained_record* node = retained_record_at(declaration)
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
	# The origin chain visits exactly the earlier bindings with this raw
	# symbol offset, newest first, as a backwards scan of all bindings would.
	binding.origin_previous = retained_binding_origins.get(sym, -1)
	if ((scope == 'U') || (scope == 'D')):
		int previous = binding.origin_previous
		while (previous >= 0):
			retained_binding* candidate = retained_bindings[previous]
			if (strcmp(candidate.name, name) == 0):
				if (candidate.scope == 'U'): binding.linkage = candidate.linkage
				break
			previous = candidate.origin_previous
	binding.return_type = -1
	binding.parameters = new list[int]
	if (load_int(table + sym + 10) == 2):
		binding.return_type = binding.type
		int count = load_int(table + sym + 22)
		for i in range(count): binding.parameters.push(retained_type_note(sym_param_type(sym, i)))
	int id = retained_bindings.length
	retained_bindings.push(binding)
	retained_binding_cache[key] = id
	retained_binding_origins[sym] = id
	retained_binding_front[front] = id
	return id


# Retain the production traversal without keeping pointers into temporary
# expression arenas or the symbol/type tables. Operand indices are local to
# each expression group and retain the production op-specific interpretation.
# P1.2b: the operands are the arena's node columns, copied into one block of
# the group (compiler/retained_ast.w); a semantic session adds their semantic
# types, bindings and spellings in a second block.
void retained_expression_semantics(expression_ast* tree, retained_group* group);


void retained_expression_note(expression_ast* tree, int root):
	if (ast_retain_mode == 0): return
	int count = tree.count
	int* offsets = tree.offset
	int start_offset = offsets[root]
	for i in range(count):
		if (offsets[i] < start_offset): start_offset = offsets[i]
	retained_init()
	int id = retained_enter_interned(retained_expression_group, filename, start_offset, 0, 0, retained_name_expression)
	retained_record* owner = retained_record_at(id)
	retained_group* group = cast(retained_group*, retained_arena_alloc(sizeof(retained_group)))
	owner.group = group
	group.id = id
	group.root = root
	group.count = count
	group.wide = word_size == 8
	group.readonly = tree.readonly
	group.whole_expression = tree.whole_expression
	group.final_token_offset = tree.final_token_offset
	# One copy of each temporary arena into the session arena; string
	# literal operands are slices of this copy, not separate copies.
	group.arena_text_length = tree.text_used
	group.arena_text = retained_text_copy(tree.text, tree.text_used)
	group.arena_type_names_length = tree.type_names_used
	group.arena_type_names = retained_text_copy(tree.type_names, tree.type_names_used)
	group.semantic = 0
	# The arena's columns are contiguous, tree.capacity words apart.
	int* columns = cast(int*, retained_arena_alloc(retained_expression_columns * count * __word_size__))
	group.columns = columns
	int* from = tree.op
	int stride = tree.capacity
	int to = 0
	for c in range(retained_expression_columns):
		for i in range(count): columns[to + i] = from[i]
		from = &from[stride]
		to = to + count
	int operand = cast(int, owner) | 1
	for i in range(count): retained_node_push(operand)
	if (retained_semantic_mode): retained_expression_semantics(tree, group)
	retained_leave(id, tree.end_offset)


# A semantic session's second block for a group just noted: per operand the
# semantic result, signature, receiver and inference types, the binding and
# name binding, the payload text, and the result type's spelling, size and
# pointer level (the columns retained_node_load reads).
void retained_expression_semantics(expression_ast* tree, retained_group* group):
	int count = group.count
	int* s = cast(int*, retained_arena_alloc(retained_semantic_columns * count * __word_size__))
	group.semantic = s
	int id = group.id
	for i in range(count):
		s[i] = retained_type_note(tree.result_type[i])
		s[count + i] = retained_type_note(tree.generic_signature[i])
		s[2 * count + i] = retained_type_note(tree.call_receiver_type[i])
		s[3 * count + i] = retained_type_note(tree.infer_want[i])
		int binding = -1
		int name_binding = -1
		char* payload = 0
		char* result_name = 0
		int size = 0
		int pointer_level = 0
		int type = type_real(tree.result_type[i])
		if ((type >= 0) && (type < type_count())):
			result_name = retained_intern(type_get_name(type))
			size = type_get_size(type)
			pointer_level = type_get_pointer_level(type)
		# These opcodes always carry a symbol-table binding. Other opcodes
		# overload the same slot with type/format/diagnostic information.
		int op = tree.op[i]
		int high = tree.high[i]
		if ((op == 'G') || (op == 'W')): payload = retained_intern(generic_def_name(tree.value[i]))
		if (op == ast_warning):
			if ((high == 0) || (high == 6) || (high == 7) || (high == 8)): payload = retained_intern(cast(char*, tree.value[i]))
			if ((high == 1) || (high == 2) || (high == 5)):
				char* message = table + tree.value[i]
				if ((high == 5) && tree.symbol[i]): message = c"it"
				payload = retained_intern(message)
		# Name-bearing warnings spell a symbol whose record ends their name.
		if ((op == ast_warning) && ((high == 1) || (high == 2) || ((high == 5) && (tree.symbol[i] == 0)))):
			name_binding = retained_binding_note(tree.value[i] + strlen(table + tree.value[i]), id)
		if ((op == 'v') || (op == 'C') || (op == 'X') || (op == 'z') || (op == 'l')):
			char* name = table + tree.value[i]
			if (tree.binding_name[i] >= 0): name = &tree.text[tree.binding_name[i]]
			payload = retained_intern(name)
		if ((op == 'v') || (op == 'C') || (op == 'X') || (op == 'z') || (op == 'l') || (op == 'G') || (op == 'W')):
			binding = retained_binding_note(tree.symbol[i], id)
		s[4 * count + i] = binding
		s[5 * count + i] = name_binding
		s[6 * count + i] = cast(int, payload)
		s[7 * count + i] = cast(int, result_name)
		s[8 * count + i] = size
		s[9 * count + i] = pointer_level


# Definition hooks run after the declaration. Adopt its already retained
# function/initializer children instead of creating a second parser.
void retained_declaration_note(char* name, char* kind, int start, int end, int line, int column):
	if (ast_retain_mode == 0): return
	int source = retained_source_id(filename)
	int module = retained_sources[source].root
	int id = retained_add(retained_declaration, module, source, start, line, column, name)
	retained_record* node = retained_record_at(id)
	node.end = end
	node.result_type = retained_intern(kind)
	if (retained_semantic_mode):
		retained_semantic_invalidate()
		if ((strcmp(kind, c"function") == 0) || (strcmp(kind, c"global") == 0) || (strcmp(kind, c"const") == 0)):
			int binding = retained_binding_note(sym_probe(name), id)
			node.binding = binding
			if (binding >= 0): node.semantic_type = retained_bindings[binding].type
		else: node.semantic_type = retained_type_note(type_lookup(name))
	retained_source* input = retained_sources[source]
	input.declaration_cursor = id + 1
	# Only this module's own top-level children since the previous
	# declaration can be adopted; the declaration itself is the last entry.
	list[int] top = input.top_level
	for k in range(input.top_cursor, top.length):
		int i = top[k]
		if (i >= id): continue
		retained_record* child = retained_record_at(i)
		if ((child.parent == module) && (child.start >= start) && (child.end <= end)): child.parent = id
	input.top_cursor = top.length


# Imports remain explicit module children even when their target has already
# been compiled. Record the resolver's normalized module spelling, not a
# guessed absolute pathname or an ambiguous source-version identity.
void retained_import_note(char* spelling, char* path, char* alias, int start, int end, int line, int column):
	if (ast_retain_mode == 0): return
	int source = retained_source_id(filename)
	int id = retained_add(retained_import, retained_sources[source].root, source, start, line, column, spelling)
	retained_record* node = retained_record_at(id)
	node.end = end
	node.import_path = retained_intern(path)
	if (alias != 0): node.import_alias = retained_intern(alias)


# Inventory declarations even when no expression refers to them. The parent
# preserves lexical block membership; binding.owner identifies the function.
# P1.2b: outside a semantic session there is no binding record; the node's
# name and location are the ones its binding would record.
void retained_local_note(int sym):
	if ((ast_retain_mode == 0) || (retained_parent < 0)): return
	int owner = retained_parent
	while ((owner >= 0) && (retained_record_at(owner).kind != retained_function)): owner = retained_record_at(owner).parent
	if (owner < 0): return
	int binding = -1
	int type = -1
	int scope = 0
	int source = -1
	int line = 0
	int column = 0
	char* name = 0
	if (retained_semantic_mode):
		binding = retained_binding_note(sym, retained_parent)
		if (binding < 0): return
		retained_binding* record = retained_bindings[binding]
		type = record.type
		scope = record.scope
		source = record.source
		line = record.line
		column = record.column
		name = record.name
	else:
		sym_index_sync()
		int low = 0
		int high = sym_index_count
		while (low < high):
			int mid = (low + high) / 2
			if (sym_index_offset(mid) < sym): low = mid + 1
			else: high = mid
		if ((low >= sym_index_count) || (sym_index_offset(low) != sym)): return
		char* spelled = table + sym_index_name_start(low)
		scope = table[sym + 1]
		source = retained_file_source(load_int(table + sym + 66))
		line = load_int(table + sym + 70)
		column = load_int(table + sym + 74)
		# As retained_binding_note places an inferred declaration.
		if (scope == 'L'):
			retained_record* declaration = retained_record_at(retained_parent)
			if ((declaration.kind == retained_statement) && (strcmp(declaration.name, spelled) == 0)):
				line = declaration.line
				column = declaration.column
		name = retained_intern(spelled)
	if (source < 0): return
	int offset = 0
	retained_source* input = retained_sources[source]
	if ((line > 0) && (line <= input.lines.length)):
		offset = input.lines[line - 1] + column - 1
	int id = retained_add_interned(retained_local, retained_parent, source, offset, line, column, name)
	retained_record* node = retained_record_at(id)
	node.binding = binding
	node.semantic_type = type
	node.end = offset + strlen(name)
	# Native parameters are inventoried after their header was parsed. The
	# function originally entered at its body delimiter; include parameters
	# in that retained span without moving the production tokenizer.
	retained_record* parent = retained_record_at(retained_parent)
	if ((scope == 'A') && (parent.kind == retained_function) && (parent.source == source) && (offset < parent.start)):
		parent.start = offset
		parent.line = line
		parent.column = column


void retained_function_parameters(int binding):
	if (ast_retain_mode == 0): return
	if ((retained_parent >= 0) && retained_semantic_mode):
		retained_record_at(retained_parent).binding = retained_binding_note(binding, retained_parent)
	sym_index_sync()
	# The index is sorted by offset: start at the first symbol after binding.
	int low = 0
	int high = sym_index_count
	while (low < high):
		int mid = (low + high) / 2
		if (sym_index_offset(mid) <= binding): low = mid + 1
		else: high = mid
	for i in range(low, sym_index_count):
		int sym = sym_index_offset(i)
		if (table[sym + 1] == 'A'): retained_local_note(sym)
