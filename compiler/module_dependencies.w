# Independent analysis of owned production records. Building this graph reads
# no source files, compiler tables or machine code. Its result survives release
# of the retained forest. This is dependency planning, not reusable code or a
# claim that the production traversal is already a complete executable IR.
# The graph type, module_dependencies_invalidate and module_dependencies_free
# live in compiler/module_graph.w, which tools import without the compiler.
import compiler.retained_ast
import compiler.module_graph


# A per-source visited generation handles recursive types and avoids walking
# the same shape for every operand. Each retained type records its source
# version; path lookup here would silently merge different REPL versions.
void module_dependency_type_note(module_dependency_graph* graph, int source, int type, list[int] visited):
	if ((source < 0) || (type < 0)): return
	list[int] pending = new list[int]
	pending.push(type)
	while (pending.length):
		int id = pending.pop()
		if (id < 0): continue
		if (visited[id] == source + 1): continue
		visited[id] = source + 1
		retained_type* record = retained_types[id]
		module_dependency_add(graph, source, record.source, module_dependency_type)
		pending.push(record.target)
		pending.push(record.return_type)
		for i in range(record.parameters.length): pending.push(record.parameters[i])
		for i in range(record.fields.length): pending.push(record.fields[i].type)
	pending.free()


module_dependency_graph* module_dependencies_build():
	module_dependency_graph* graph = module_graph_new()
	if (retained_sources == 0): return graph
	for i in range(retained_sources.length): module_graph_add_module(graph, retained_sources[i].path)
	list[int] visited = new list[int]
	if (retained_types != 0):
		for i in range(retained_types.length): visited.push(0)
	# A call through a prototype depends on the defining module too. Keep
	# the prototype dependency: changing its signature can affect the call.
	list[int] definitions = new list[int]
	if (retained_bindings != 0):
		for i in range(retained_bindings.length): definitions.push(-1)
		for i in range(retained_bindings.length):
			retained_binding* binding = retained_bindings[i]
			if (binding.scope == 'D'): definitions[binding.linkage] = binding.source
	retained_node view
	retained_node* node = &view
	if (retained_node_table != 0):
		for i in range(retained_node_count()):
			retained_node_load(i, node)
			if (node.kind == retained_import):
				module_dependency_add(graph, node.source, node.import_source, module_dependency_import)
			module_dependency_type_note(graph, node.source, node.semantic_type, visited)
			module_dependency_type_note(graph, node.source, node.generic_signature, visited)
			module_dependency_type_note(graph, node.source, node.call_receiver_type, visited)
			module_dependency_type_note(graph, node.source, node.infer_want, visited)
			if (node.binding >= 0):
				retained_binding* binding = retained_bindings[node.binding]
				module_dependency_add(graph, node.source, binding.source, module_dependency_binding)
				module_dependency_add(graph, node.source, definitions[binding.linkage], module_dependency_binding)
				module_dependency_type_note(graph, node.source, binding.type, visited)
				module_dependency_type_note(graph, node.source, binding.return_type, visited)
				for j in range(binding.parameters.length): module_dependency_type_note(graph, node.source, binding.parameters[j], visited)
	visited.free()
	definitions.free()
	return graph
