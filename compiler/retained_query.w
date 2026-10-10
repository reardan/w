import compiler.module_dependencies

# Public read-only serialization of the session-owned module forest. All IDs
# refer to this dump; rollback or a new compiler invocation starts a new session.
# Expression operands remain opcode-specific and local to their group.
# Records stream: the output buffer is flushed at record boundaries once it
# passes retained_query_flush_at, so a dump never materialises in memory.
# Filters (--file, --no-expressions) omit records but never renumber them:
# every ID, and the totals in the leading tree record, describe the whole
# session, so a reference may name a record the filter left out.

const int retained_query_flush_at = 65536
# 0 = every source; otherwise retained_query_sources[source] selects it.
int retained_query_filtered
list[int] retained_query_sources
int retained_query_no_expressions


void retained_query_end_record():
	diag_write_cstr(c"}\n")
	if (diag_out_buffer_pos >= retained_query_flush_at): diag_flush()


# Decimal digits straight into the output buffer: the same text as itoa
# without an allocation per field.
void retained_query_digits(int value):
	diag_out_ensure(24)
	if (value < 0):
		diag_out_buffer[diag_out_buffer_pos] = '-'
		diag_out_buffer_pos = diag_out_buffer_pos + 1
	int begin = diag_out_buffer_pos
	while (1):
		int digit = value % 10
		if (digit < 0): digit = 0 - digit
		diag_out_buffer[diag_out_buffer_pos] = '0' + digit
		diag_out_buffer_pos = diag_out_buffer_pos + 1
		value = value / 10
		if (value == 0): break
	int last = diag_out_buffer_pos - 1
	while (begin < last):
		int swap = diag_out_buffer[begin]
		diag_out_buffer[begin] = diag_out_buffer[last]
		diag_out_buffer[last] = swap
		begin = begin + 1
		last = last - 1


# Field names are short fixed ASCII identifiers that need no JSON escaping.
void retained_query_key(char* name):
	diag_out_ensure(96)
	char* out = diag_out_buffer
	int at = diag_out_buffer_pos
	out[at] = ','
	out[at + 1] = ' '
	out[at + 2] = '"'
	at = at + 3
	int i = 0
	while (name[i] != 0):
		out[at] = name[i]
		at = at + 1
		i = i + 1
	out[at] = '"'
	out[at + 1] = ':'
	out[at + 2] = ' '
	diag_out_buffer_pos = at + 3


void retained_query_int(char* name, int value):
	retained_query_key(name)
	retained_query_digits(value)


# A JSON string: printable ASCII without quotes or backslashes is copied
# as is; anything else takes diag_write_json_string's escaping path.
void retained_query_text(char* value):
	int length = 0
	while (value[length] != 0):
		int c = value[length] & 255
		if ((c < 32) || (c >= 127) || (c == '"') || (c == 92)):
			diag_write_json_string(value)
			return
		length = length + 1
	diag_out_ensure(length + 2)
	char* out = diag_out_buffer
	int at = diag_out_buffer_pos
	out[at] = '"'
	for i in range(length): out[at + 1 + i] = value[i]
	out[at + length + 1] = '"'
	diag_out_buffer_pos = at + length + 2


void retained_query_string(char* name, char* value):
	if (value == 0): return
	retained_query_key(name)
	retained_query_text(value)


# Hex encodes length-delimited literal bytes, including embedded NUL and
# non-UTF8 bytes, without truncating them through a C string serializer.
void retained_query_bytes(char* name, char* value, int length):
	if (value == 0): return
	retained_query_key(name)
	diag_out_ensure(length * 2 + 2)
	diag_out_buffer[diag_out_buffer_pos] = '"'
	int at = diag_out_buffer_pos + 1
	for i in range(length):
		diag_out_buffer[at] = diag_hex_digit((value[i] >> 4) & 15)
		diag_out_buffer[at + 1] = diag_hex_digit(value[i] & 15)
		at = at + 2
	diag_out_buffer[at] = '"'
	diag_out_buffer_pos = at + 1


char* retained_query_kind(int kind):
	if (kind == retained_module): return c"module"
	if (kind == retained_function): return c"function"
	if (kind == retained_statement): return c"statement"
	if (kind == retained_expression): return c"expression"
	if (kind == retained_declaration): return c"declaration"
	if (kind == retained_expression_group): return c"expression_group"
	if (kind == retained_import): return c"import"
	if (kind == retained_local): return c"local"
	if (kind == retained_tile_expression): return c"tile_expression"
	if (kind == retained_tile_statement): return c"tile_statement"
	if (kind == retained_function_expression): return c"function_expression"
	return c"unknown"


void retained_query_parameters(list[int] parameters):
	diag_write_cstr(c", \"parameters\": [")
	for i in range(parameters.length):
		if (i): diag_write_cstr(c", ")
		retained_query_digits(parameters[i])
	diag_write_cstr(c"]")


int retained_query_selected(int source):
	if (retained_query_filtered == 0): return 1
	if ((source < 0) || (source >= retained_query_sources.length)): return 0
	return retained_query_sources[source]


void retained_query_type(int id):
	retained_type* type = retained_types[id]
	diag_write_cstr(c"{\"record\": \"type\"")
	retained_query_int(c"id", id)
	retained_query_string(c"name", type.name)
	retained_query_string(c"file", type.file)
	retained_query_int(c"source", type.source)
	retained_query_int(c"line", type.line)
	retained_query_int(c"column", type.column)
	retained_query_int(c"kind", type.kind)
	retained_query_int(c"size", type.size)
	retained_query_int(c"pointer_level", type.pointer_level)
	retained_query_int(c"target", type.target)
	retained_query_int(c"return_type", type.return_type)
	retained_query_int(c"array_length", type.array_length)
	retained_query_parameters(type.parameters)
	diag_write_cstr(c", \"fields\": [")
	for j in range(type.fields.length):
		if (j): diag_write_cstr(c", ")
		retained_field* field = type.fields[j]
		diag_write_cstr(c"{")
		diag_write_json_field(c"name", field.name)
		retained_query_int(c"type", field.type)
		retained_query_int(c"offset", field.offset)
		diag_write_cstr(c"}")
	diag_write_cstr(c"], \"constants\": [")
	for j in range(type.constants.length):
		if (j): diag_write_cstr(c", ")
		retained_constant* member = type.constants[j]
		diag_write_cstr(c"{")
		diag_write_json_field(c"name", member.name)
		retained_query_int(c"value", member.value)
		diag_write_cstr(c"}")
	diag_write_cstr(c"]")
	retained_query_end_record()


void retained_query_binding(int id):
	retained_binding* binding = retained_bindings[id]
	diag_write_cstr(c"{\"record\": \"binding\"")
	retained_query_int(c"id", id)
	retained_query_string(c"name", binding.name)
	retained_query_string(c"file", binding.file)
	retained_query_int(c"line", binding.line)
	retained_query_int(c"column", binding.column)
	retained_query_int(c"scope", binding.scope)
	retained_query_int(c"source", binding.source)
	retained_query_int(c"owner", binding.owner)
	retained_query_int(c"linkage", binding.linkage)
	retained_query_int(c"type", binding.type)
	retained_query_int(c"return_type", binding.return_type)
	retained_query_parameters(binding.parameters)
	retained_query_end_record()


void retained_query_semantics():
	if (retained_types != 0):
		for i in range(retained_types.length):
			if (retained_query_selected(retained_types[i].source)): retained_query_type(i)
	if (retained_bindings != 0):
		for i in range(retained_bindings.length):
			if (retained_query_selected(retained_bindings[i].source)): retained_query_binding(i)


void retained_query_dependencies():
	module_dependency_graph* graph = module_dependencies_build()
	for i in range(graph.modules.length):
		if (retained_query_selected(i) == 0): continue
		module_dependencies* module = graph.modules[i]
		for j in range(module.targets.length):
			diag_write_cstr(c"{\"record\": \"dependency\"")
			retained_query_int(c"source", i)
			retained_query_int(c"target", module.targets[j])
			retained_query_int(c"reasons", module.reasons[j])
			retained_query_end_record()
	module_dependencies_free(graph)


void retained_query_node(int id, retained_node* node):
	diag_write_cstr(c"{\"record\": \"node\"")
	retained_query_int(c"id", id)
	retained_query_string(c"kind", retained_query_kind(node.kind))
	retained_query_string(c"name", node.name)
	retained_query_string(c"import_path", node.import_path)
	retained_query_string(c"import_alias", node.import_alias)
	if (node.kind == retained_import): retained_query_int(c"import_source", node.import_source)
	retained_query_int(c"parent", node.parent)
	retained_query_int(c"source", node.source)
	retained_query_int(c"start", node.start)
	retained_query_int(c"end", node.end)
	retained_query_int(c"line", node.line)
	retained_query_int(c"column", node.column)
	retained_query_int(c"type", node.semantic_type)
	retained_query_int(c"binding", node.binding)
	if ((node.kind == retained_expression) || (node.kind == retained_expression_group)):
		retained_query_int(c"op", node.op)
		retained_query_int(c"left", node.left)
		retained_query_int(c"right", node.right)
		retained_query_int(c"next_arg", node.next_arg)
		retained_query_int(c"literal_value", node.literal_value)
		retained_query_int(c"literal_high", node.literal_high)
		retained_query_bytes(c"literal_hex", node.literal_text, node.literal_length)
		retained_query_int(c"value", node.value)
		retained_query_int(c"high", node.high)
		retained_query_int(c"raw_symbol", node.symbol)
		retained_query_int(c"in_cast", node.in_cast)
		retained_query_int(c"binding_offset", node.binding_offset)
		retained_query_int(c"binding_text_offset", node.binding_text_offset)
		retained_query_int(c"it_slot", node.it_slot)
		retained_query_int(c"readonly", node.readonly)
		retained_query_int(c"whole_expression", node.whole_expression)
		retained_query_int(c"final_token_offset", node.final_token_offset)
		retained_query_int(c"qualified", node.qualified)
		retained_query_int(c"generic_parameters", node.generic_parameters)
		retained_query_int(c"generic_signature", node.generic_signature)
		retained_query_int(c"generic_offset", node.generic_offset)
		retained_query_int(c"generic_instance", node.generic_instance)
		retained_query_int(c"generic_arity", node.generic_arity)
		retained_query_int(c"infer_coercion", node.infer_coercion)
		retained_query_int(c"call_receiver_type", node.call_receiver_type)
		retained_query_int(c"infer_want", node.infer_want)
		retained_query_int(c"result_is_value", node.result_is_value)
		retained_query_string(c"payload_text", node.payload_text)
		retained_query_bytes(c"arena_text_hex", node.arena_text, node.arena_text_length)
		retained_query_bytes(c"arena_type_names_hex", node.arena_type_names, node.arena_type_names_length)
	retained_query_string(c"result_type", node.result_type)
	retained_query_string(c"binding_name", node.binding_name)
	retained_query_string(c"binding_file", node.binding_file)
	retained_query_end_record()


void retained_query_dump():
	diag_write_cstr(c"{\"record\": \"tree\", \"version\": 2")
	retained_query_int(c"sources", retained_sources.length)
	retained_query_int(c"nodes", retained_node_count())
	if (retained_types != 0): retained_query_int(c"types", retained_types.length)
	if (retained_bindings != 0): retained_query_int(c"bindings", retained_bindings.length)
	retained_query_end_record()
	for i in range(retained_sources.length):
		if (retained_query_selected(i) == 0): continue
		retained_source* source = retained_sources[i]
		diag_write_cstr(c"{\"record\": \"source\"")
		retained_query_int(c"id", i)
		retained_query_string(c"file", source.path)
		retained_query_int(c"length", source.length)
		retained_query_int(c"root", source.root)
		retained_query_end_record()
	retained_node view
	int total = retained_node_count()
	for i in range(total):
		int kind = retained_node_kind(i)
		if (retained_query_no_expressions && ((kind == retained_expression) || (kind == retained_expression_group))): continue
		retained_node_load(i, &view)
		if (retained_query_selected(view.source) == 0): continue
		retained_query_node(i, &view)
	retained_query_semantics()
	retained_query_dependencies()
	diag_flush()


# A --file argument names a source by its recorded path, or by a path
# suffix that starts at a directory boundary ("lib/lib.w", "./lib/lib.w").
int retained_query_path_matches(char* path, char* wanted):
	while (starts_with(wanted, c"./")): wanted = wanted + 2
	if (strcmp(path, wanted) == 0): return 1
	int path_length = strlen(path)
	int wanted_length = strlen(wanted)
	if ((wanted_length == 0) || (wanted_length >= path_length)): return 0
	if (path[path_length - wanted_length - 1] != '/'): return 0
	return strcmp(path + path_length - wanted_length, wanted) == 0


# Select the sources the --file arguments name; returns 0 and reports the
# first argument that matches no source.
int retained_query_select(list[char*] files):
	retained_query_filtered = 0
	if (files.length == 0): return 1
	retained_query_filtered = 1
	retained_query_sources = new list[int]
	for i in range(retained_sources.length): retained_query_sources.push(0)
	for j in range(files.length):
		int found = 0
		for i in range(retained_sources.length):
			if (retained_query_path_matches(retained_sources[i].path, files[j])):
				retained_query_sources[i] = 1
				found = 1
		if (found == 0):
			print_error(c"w tree: no compiled source matches --file '")
			print_error(files[j])
			print_error(c"'\x0a")
			return 0
	return 1


void retained_query_usage():
	println(c"usage: w tree [--json] [--quiet] [--file <path>]... [--no-expressions] [target] <file.w>... [compiler options]")
	println(c"Emit owned source, module, declaration and expression records as NDJSON.")
	println(c"IDs are local to this query. Expressions use group-local operand indices.")
	println(c"--file keeps the records of the named source(s) (a path or a path suffix);")
	println(c"--no-expressions drops expression and expression_group nodes. Filters keep")
	println(c"IDs and the tree record's totals unchanged; references may name omitted records.")


int retained_query_main(int argc, int argv):
	int i = 2
	diag_json = 1
	int scanning = 1
	list[char*] files = new list[char*]
	retained_query_no_expressions = 0
	while (scanning && (i < argc)):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--json") == 0): i = i + 1
		else if (strcmp(*arg, c"--quiet") == 0):
			quiet_mode = 1
			i = i + 1
		else if (strcmp(*arg, c"--no-expressions") == 0):
			retained_query_no_expressions = 1
			i = i + 1
		else if ((strcmp(*arg, c"--file") == 0) && (i + 1 < argc)):
			char** value = argv + (i + 1) * __word_size__
			files.push(*value)
			i = i + 2
		else if (import_root_arg_width(*arg) > 0): i = i + import_root_arg_width(*arg)
		else if (arg_is_help(*arg)):
			retained_query_usage()
			files.free()
			return 0
		else: scanning = 0
	if (argc <= i):
		println2(c"usage: w tree [--json] [--quiet] [--file <path>]... [--no-expressions] [target] <file.w>... [compiler options]")
		files.free()
		return 1
	retained_query_mode = 1
	int status = link_impl(argc, argv, i, 1)
	retained_query_mode = 0
	if (status == 0):
		if (retained_query_select(files)): retained_query_dump()
		else: status = 1
	if (retained_query_sources != 0): retained_query_sources.free()
	retained_query_sources = 0
	retained_query_filtered = 0
	files.free()
	retained_clear()
	return status
