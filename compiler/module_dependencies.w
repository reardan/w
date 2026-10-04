# Independent analysis of owned production records. Building this graph reads
# no source files, compiler tables or machine code. Its result survives release
# of the retained forest. This is dependency planning, not reusable code or a
# claim that the production traversal is already a complete executable IR.
import compiler.retained_ast
import lib.assert

const int module_dependency_import = 1
const int module_dependency_binding = 2
const int module_dependency_type = 4

struct module_dependencies:
	char* path
	list[int] targets
	list[int] reasons
	list[int] users

struct module_dependency_graph:
	list[module_dependencies*] modules


void module_dependency_add(module_dependency_graph* graph, int source, int target, int reason):
	if ((source < 0) || (target < 0) || (source == target)): return
	module_dependencies* module = graph.modules[source]
	for i in range(module.targets.length):
		if (module.targets[i] == target):
			module.reasons[i] = module.reasons[i] | reason
			return
	module.targets.push(target)
	module.reasons.push(reason)
	graph.modules[target].users.push(source)


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
	module_dependency_graph* graph = new module_dependency_graph
	graph.modules = new list[module_dependencies*]
	if (retained_sources == 0): return graph
	for i in range(retained_sources.length):
		module_dependencies* module = new module_dependencies
		module.path = strclone(retained_sources[i].path)
		module.targets = new list[int]
		module.reasons = new list[int]
		module.users = new list[int]
		graph.modules.push(module)
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
	if (retained_nodes != 0):
		for i in range(retained_nodes.length):
			retained_node* node = retained_nodes[i]
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


# Return the changed modules and every transitive user in source-ID order.
# The worklist is iterative, cycle-safe and insensitive to seed ordering.
# A caller changing import resolution must rebuild the graph; IDs belong to
# this snapshot and are not persistent cache keys.
list[int] module_dependencies_invalidate(module_dependency_graph* graph, list[int] changed):
	list[int] marked = new list[int]
	list[int] pending = new list[int]
	list[int] result = new list[int]
	for i in range(graph.modules.length): marked.push(0)
	for i in range(changed.length):
		int source = changed[i]
		assert1((source >= 0) && (source < graph.modules.length))
		if (marked[source] == 0):
			marked[source] = 1
			pending.push(source)
	while (pending.length):
		module_dependencies* module = graph.modules[pending.pop()]
		for i in range(module.users.length):
			int user = module.users[i]
			if (marked[user] == 0):
				marked[user] = 1
				pending.push(user)
	for i in range(marked.length):
		if (marked[i]): result.push(i)
	marked.free()
	pending.free()
	return result


void module_dependencies_free(module_dependency_graph* graph):
	for i in range(graph.modules.length):
		module_dependencies* module = graph.modules[i]
		free(module.path)
		module.targets.free()
		module.reasons.free()
		module.users.free()
		free(module)
	graph.modules.free()
	free(graph)
