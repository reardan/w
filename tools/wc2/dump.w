import tools.wc2.ast
import structures.json


void wc2_dump_ids(string_builder* out, list[int] ids):
	string_append_char(out, '[')
	for i in range(ids.length):
		if (i > 0): string_append_char(out, ',')
		string_append_int(out, ids[i])
	string_append_char(out, ']')


# Flat tables keep the dump bounded in stack usage even for long binary
# chains. Schema 1 has no addresses or host-width-dependent values.
char* wc2_dump(wc2_module* m):
	string_builder* out = string_new()
	string_append(out, c"{\"schema\":1,\"file\":")
	json_append_escaped_string(out, m.filename)
	string_append(out, c",\"root\":")
	string_append_int(out, m.root)
	string_append(out, c",\"nodes\":[")
	for i in range(m.nodes.length):
		wc2_node* node = m.nodes[i]
		if (i > 0): string_append_char(out, ',')
		string_append(out, c"\n{\"id\":")
		string_append_int(out, node.id)
		string_append(out, c",\"kind\":")
		json_append_escaped_string(out, wc2_kind_name(node.kind))
		string_append(out, c",\"text\":")
		json_append_escaped_string(out, node.text)
		string_append(out, c",\"start\":")
		string_append_int(out, node.start)
		string_append(out, c",\"end\":")
		string_append_int(out, node.end)
		string_append(out, c",\"line\":")
		string_append_int(out, node.line)
		string_append(out, c",\"column\":")
		string_append_int(out, node.column)
		string_append(out, c",\"scope\":")
		string_append_int(out, node.scope)
		string_append(out, c",\"type\":")
		string_append_int(out, node.type_id)
		string_append(out, c",\"binding\":")
		string_append_int(out, node.binding)
		string_append(out, c",\"children\":")
		wc2_dump_ids(out, node.children)
		string_append_char(out, '}')
	string_append(out, c"\n],\"scopes\":[")
	for i in range(m.scopes.length):
		wc2_scope* scope = m.scopes[i]
		if (i > 0): string_append_char(out, ',')
		string_append(out, c"{\"parent\":")
		string_append_int(out, scope.parent)
		string_append(out, c",\"owner\":")
		string_append_int(out, scope.owner)
		string_append(out, c",\"declarations\":")
		wc2_dump_ids(out, scope.declarations)
		string_append_char(out, '}')
	string_append(out, c"]}\n")
	char* result = out.data
	free(out)
	return result
