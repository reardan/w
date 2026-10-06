# The module dependency graph on its own: modules, edges and the transitive
# invalidation walk, with no compiler state behind them. compiler/
# module_dependencies.w fills one from the retained forest; tools that keep
# their own snapshot of which files an answer read (tools/wbuildd.w) build
# one directly from paths and import it without the compiler.
#
# A module is a path plus its edges: targets[i] is a module it depends on
# for reasons[i] (a module_dependency_* bit set), and users lists every
# module with an edge to it. IDs are indexes into graph.modules and stay
# valid for the graph's lifetime; module_dependencies_forget empties a
# module's outgoing edges without renumbering anything.
import lib.lib
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


module_dependency_graph* module_graph_new():
	module_dependency_graph* graph = new module_dependency_graph
	graph.modules = new list[module_dependencies*]
	return graph


# Appends a module (the graph owns a copy of path) and returns its ID.
int module_graph_add_module(module_dependency_graph* graph, char* path):
	module_dependencies* module = new module_dependencies
	module.path = strclone(path)
	module.targets = new list[int]
	module.reasons = new list[int]
	module.users = new list[int]
	graph.modules.push(module)
	return graph.modules.length - 1


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


# Drops every edge out of source, and source from each target's users, so
# a caller can retire or re-point a module whose dependencies changed. The
# module keeps its ID and path, and edges into it are untouched.
void module_dependencies_forget(module_dependency_graph* graph, int source):
	assert1((source >= 0) && (source < graph.modules.length))
	module_dependencies* module = graph.modules[source]
	for i in range(module.targets.length):
		list[int] users = graph.modules[module.targets[i]].users
		# module_dependency_add records each (source, target) pair once.
		for j in range(users.length):
			if (users[j] == source):
				users[j] = users[users.length - 1]
				users.pop()
				break
	module.targets.clear()
	module.reasons.clear()


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
