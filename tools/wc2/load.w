# Plain dotted imports, expanded once in source order. Search the invocation
# directory and its parents, matching W's ordinary import search. No runtime
# modules are implicitly loaded into the leaf compiler's executable subset.
import tools.wc2.lower
import tools.wc2.validate
import lib.file
import lib.path


int wc2_has_path(list[char*] paths, char* path):
	for char* item in paths:
		if (strcmp(item, path) == 0): return 1
	return 0


char* wc2_find_import(char* name):
	string_builder* relative = string_new()
	for i in range(strlen(name)):
		int ch = name[i]
		if (ch == '.'): ch = '/'
		string_append_char(relative, ch)
	string_append(relative, c".w")
	char* directory = malloc(4096)
	if (getcwd(directory, 4096) < 0):
		free(directory)
		string_free(relative)
		return 0
	while (1):
		char* candidate = path_join(directory, relative.data)
		if (path_exists(candidate)):
			free(directory)
			string_free(relative)
			return candidate
		free(candidate)
		if (strcmp(directory, c"/") == 0): break
		char* parent = path_dirname(directory)
		free(directory)
		directory = parent
	free(directory)
	string_free(relative)
	return 0


# Transfer semantic tables, retaining the imported module's token/source
# ownership in dependencies. IDs and scopes are rebased once, before analysis.
void wc2_merge_module(wc2_module* m, wc2_module* child):
	int node_base = m.nodes.length
	int scope_base = m.scopes.length - 1
	wc2_node* child_root = child.nodes[child.root]
	for wc2_node* node in child.nodes:
		node.id = node.id + node_base
		if (node.scope != 0): node.scope = node.scope + scope_base
		for i in range(node.children.length): node.children[i] = node.children[i] + node_base
		m.nodes.push(node)
	for int id in child.scopes[0].declarations: m.scopes[0].declarations.push(id + node_base)
	for i in range(1, child.scopes.length):
		wc2_scope* scope = child.scopes[i]
		if (scope.parent != 0): scope.parent = scope.parent + scope_base
		scope.owner = scope.owner + node_base
		for j in range(scope.declarations.length): scope.declarations[j] = scope.declarations[j] + node_base
		m.scopes.push(scope)
	for int id in child_root.children: m.nodes[m.root].children.push(id)
	# Lists are emptied only after all references have been rebased.
	while (child.nodes.length): child.nodes.pop()
	while (child.scopes.length > 1): child.scopes.pop()
	m.dependencies.push(child)


void wc2_expand_imports(wc2_module* m, list[char*] seen, list[char*] active, int depth):
	if (wc2_module_ok(m) == 0): return
	wc2_node* root = m.nodes[m.root]
	list[int] declarations = root.children
	root.children = new list[int]
	for int id in declarations:
		wc2_node* node = m.nodes[id]
		if (node.kind != wc2_import_kind):
			root.children.push(id)
			continue
		if (depth >= 64):
			wc2_node_error(m, node, c"wc2: import nesting limit exceeded")
			continue
		char* path = wc2_find_import(node.text)
		if (path == 0):
			wc2_node_error(m, node, c"wc2: cannot locate imported module")
			continue
		if (wc2_has_path(active, path)):
			wc2_node_error(m, node, c"wc2: cyclic import is not supported")
			free(path)
			continue
		if (wc2_has_path(seen, path)):
			free(path)
			continue
		seen.push(path)
		active.push(path)
		char* source = file_read_text(path)
		if (source == 0):
			wc2_node_error(m, node, c"wc2: cannot read imported module")
		else:
			wc2_module* child = wc2_parse(source, path)
			free(source)
			wc2_expand_imports(child, seen, active, depth + 1)
			if (wc2_module_ok(child)):
				wc2_merge_module(m, child)
			else:
				for pg_diagnostic* diagnostic in child.diagnostics.items:
					pg_diagnostics_add(m.diagnostics, diagnostic.filename, diagnostic.line, diagnostic.column, diagnostic.message, diagnostic.expected, diagnostic.found)
				m.dependencies.push(child)
		active.pop()
	__w_list_free(cast(__w_list*, declarations))


void wc2_load_imports(wc2_module* m):
	list[char*] seen = new list[char*]
	list[char*] active = new list[char*]
	wc2_expand_imports(m, seen, active, 0)
	for char* path in seen: free(path)
	__w_list_free(cast(__w_list*, seen))
	__w_list_free(cast(__w_list*, active))
