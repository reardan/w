# A linking snapshot copies semantic nodes/scopes, never parser/token trees.
# It can be rebased by load.w without mutating a resident parsed module.
import tools.wc2.load


wc2_module* wc2_snapshot(wc2_module* source):
	wc2_module* copy = wc2_module_new(c"", source.filename)
	copy.root = source.root
	for wc2_node* original in source.nodes:
		wc2_node* node = new wc2_node()
		node.id = original.id
		node.kind = original.kind
		node.start = original.start
		node.end = original.end
		node.line = original.line
		node.column = original.column
		node.scope = original.scope
		node.type_id = original.type_id
		node.binding = original.binding
		node.text = strclone(original.text)
		node.type_name = strclone(original.type_name)
		node.filename = strclone(original.filename)
		node.children = new list[int]
		for int id in original.children: node.children.push(id)
		copy.nodes.push(node)
	for wc2_scope* original in source.scopes:
		wc2_scope* scope = new wc2_scope()
		scope.parent = original.parent
		scope.owner = original.owner
		scope.declarations = new list[int]
		for int id in original.declarations: scope.declarations.push(id)
		copy.scopes.push(scope)
	for pg_diagnostic* diagnostic in source.diagnostics.items:
		pg_diagnostics_add(copy.diagnostics, copy.filename, diagnostic.line, diagnostic.column, diagnostic.message, diagnostic.expected, diagnostic.found)
	return copy
