import compiler.module_dependencies

# Public read-only serialization of the session-owned module forest. All IDs
# refer to this dump; rollback or a new compiler invocation starts a new session.
# Expression operands remain opcode-specific and local to their group.

void retained_query_int(char* name, int value):
	diag_write_cstr(c", ")
	diag_write_json_int_field(name, value)


void retained_query_string(char* name, char* value):
	if (value == 0): return
	diag_write_cstr(c", ")
	diag_write_json_field(name, value)


# Hex encodes length-delimited literal bytes, including embedded NUL and
# non-UTF8 bytes, without truncating them through a C string serializer.
void retained_query_bytes(char* name, char* value, int length):
	if (value == 0): return
	diag_write_cstr(c", ")
	diag_write_json_string(name)
	diag_write_cstr(c": \"")
	for i in range(length):
		diag_out_char(diag_hex_digit((value[i] >> 4) & 15))
		diag_out_char(diag_hex_digit(value[i] & 15))
	diag_write_cstr(c"\"")


char* retained_query_kind(int kind):
	if (kind == retained_module): return c"module"
	if (kind == retained_function): return c"function"
	if (kind == retained_statement): return c"statement"
	if (kind == retained_expression): return c"expression"
	if (kind == retained_declaration): return c"declaration"
	if (kind == retained_expression_group): return c"expression_group"
	if (kind == retained_import): return c"import"
	if (kind == retained_local): return c"local"
	return c"unknown"


void retained_query_parameters(list[int] parameters):
	diag_write_cstr(c", \"parameters\": [")
	for i in range(parameters.length):
		if (i): diag_write_cstr(c", ")
		char* digits = itoa(parameters[i])
		diag_write_cstr(digits)
		free(digits)
	diag_write_cstr(c"]")


void retained_query_semantics():
	if (retained_types != 0):
		for i in range(retained_types.length):
			retained_type* type = retained_types[i]
			diag_write_cstr(c"{\"record\": \"type\"")
			retained_query_int(c"id", i)
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
			diag_write_cstr(c"]}\n")
	if (retained_bindings != 0):
		for i in range(retained_bindings.length):
			retained_binding* binding = retained_bindings[i]
			diag_write_cstr(c"{\"record\": \"binding\"")
			retained_query_int(c"id", i)
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
			diag_write_cstr(c"}\n")


void retained_query_dependencies():
	module_dependency_graph* graph = module_dependencies_build()
	for i in range(graph.modules.length):
		module_dependencies* module = graph.modules[i]
		for j in range(module.targets.length):
			diag_write_cstr(c"{\"record\": \"dependency\"")
			retained_query_int(c"source", i)
			retained_query_int(c"target", module.targets[j])
			retained_query_int(c"reasons", module.reasons[j])
			diag_write_cstr(c"}\n")
	module_dependencies_free(graph)


void retained_query_dump():
	diag_write_cstr(c"{\"record\": \"tree\", \"version\": 2")
	retained_query_int(c"sources", retained_sources.length)
	retained_query_int(c"nodes", retained_nodes.length)
	if (retained_types != 0): retained_query_int(c"types", retained_types.length)
	if (retained_bindings != 0): retained_query_int(c"bindings", retained_bindings.length)
	diag_write_cstr(c"}\n")
	for i in range(retained_sources.length):
		retained_source* source = retained_sources[i]
		diag_write_cstr(c"{\"record\": \"source\"")
		retained_query_int(c"id", i)
		retained_query_string(c"file", source.path)
		retained_query_int(c"length", source.length)
		retained_query_int(c"root", source.root)
		diag_write_cstr(c"}\n")
	for i in range(retained_nodes.length):
		retained_node* node = retained_nodes[i]
		diag_write_cstr(c"{\"record\": \"node\"")
		retained_query_int(c"id", i)
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
		diag_write_cstr(c"}\n")
	retained_query_semantics()
	retained_query_dependencies()
	diag_flush()


int retained_query_main(int argc, int argv):
	int i = 2
	diag_json = 1
	int scanning = 1
	while (scanning && (i < argc)):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--json") == 0): i = i + 1
		else if (strcmp(*arg, c"--quiet") == 0):
			quiet_mode = 1
			i = i + 1
		else if (import_root_arg_width(*arg) > 0): i = i + import_root_arg_width(*arg)
		else if (arg_is_help(*arg)):
			println(c"usage: w tree [--json] [--quiet] [target] <file.w>... [compiler options]")
			println(c"Emit owned source, module, declaration and expression records as NDJSON.")
			println(c"IDs are local to this query. Expressions use group-local operand indices.")
			return 0
		else: scanning = 0
	if (argc <= i):
		println2(c"usage: w tree [--json] [--quiet] [target] <file.w>... [compiler options]")
		return 1
	retained_query_mode = 1
	int status = link_impl(argc, argv, i, 1)
	retained_query_mode = 0
	if (status == 0): retained_query_dump()
	retained_clear()
	return status
