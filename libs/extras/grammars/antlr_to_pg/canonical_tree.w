# Canonical ANTLR parse-tree projection of a prediction-mode W AST.
# The translator tags every alternative with `antlr_tree:*` metadata (see
# source_metadata.w): `context` opens an original rule context, `fold` is a
# lowered left-recursive tail that wraps the preceding value in a new context
# (ANTLR's left-nested tree), `list` opens the base context of an inlined list
# base, and untagged nodes (groups, precedence helpers) are spliced into their
# parent. The JSON shape matches tests/grammars/antlr_left_recursion/TreeOracle.java:
# {"rule":R,"context":C,"children":[...]} and {"token":TEXT}; only default-channel
# tokens appear and a named EOF token is spelled `<EOF>`.
import structures.string
import libs.extras.parser_generator.runtime


struct at_tree_item:
	int is_token
	char* text
	char* rule
	char* context
	list[at_tree_item*] children


void at_tree_quote(string_builder* out, char* text):
	string_append_char(out, 34)
	for i in range(strlen(text)):
		int c = cast(int, text[i]) & 255
		if ((c == 34) || (c == 92)):
			string_append_char(out, 92)
			string_append_char(out, c)
		else if (c < 32):
			char* digits = c"0123456789abcdef"
			string_append(out, c"\\u00")
			string_append_char(out, digits[c >> 4])
			string_append_char(out, digits[c & 15])
		else: string_append_char(out, c)
	string_append_char(out, 34)


# The metadata key with this prefix names the original rule; its value is the
# original alternative. Returns the suffix, or 0 when absent.
char* at_tree_meta_suffix(pg_ast_node* node, char* prefix):
	if (node.metadata == 0): return 0
	int n = strlen(prefix)
	for char* key in node.metadata.keys():
		if (starts_with(key, prefix)): return key + n
	return 0


char* at_tree_capitalized(char* text):
	string_builder* out = string_new()
	string_append(out, text)
	if ((out.length > 0) && (out.data[0] >= 'a') && (out.data[0] <= 'z')): out.data[0] = out.data[0] - 32
	string_append(out, c"Context")
	return out.data


at_tree_item* at_tree_context(pg_ast_node* node):
	at_tree_item* item = new at_tree_item()
	item.children = new list[at_tree_item*]
	item.rule = at_tree_meta_suffix(node, c"antlr_rule:")
	if (item.rule == 0): item.rule = node.name
	char* label = at_tree_meta_suffix(node, c"antlr_alt:")
	if (label != 0): item.context = at_tree_capitalized(label)
	else: item.context = at_tree_capitalized(item.rule)
	return item


void at_tree_project_into(pg_ast_node* node, list[at_tree_item*] out);


# Project children in order; a fold child takes the preceding value as its
# first child, mirroring ANTLR's precedence loop re-parenting.
void at_tree_project_children(pg_ast_node* node, list[at_tree_item*] out):
	for pg_ast_node* child in node.children:
		if ((child.token == 0) && (pg_ast_get_metadata(child, c"antlr_tree:fold", 0) == 1)):
			at_tree_item* folded = at_tree_context(child)
			if (out.length > 0): folded.children.push(out.pop())
			at_tree_project_children(child, folded.children)
			out.push(folded)
		else: at_tree_project_into(child, out)


void at_tree_project_into(pg_ast_node* node, list[at_tree_item*] out):
	if (node.token != 0):
		if (node.token.channel != 0): return
		at_tree_item* token = new at_tree_item()
		token.is_token = 1
		token.text = node.token.text
		if (strcmp(node.name, c"EOF") == 0): token.text = c"<EOF>"
		out.push(token)
		return
	if (pg_ast_get_metadata(node, c"antlr_tree:context", 0) == 1):
		at_tree_item* item = at_tree_context(node)
		at_tree_project_children(node, item.children)
		out.push(item)
		return
	if (pg_ast_get_metadata(node, c"antlr_tree:list", 0) == 1):
		# Leading non-fold children form the base context; folds wrap it.
		at_tree_item* value = at_tree_context(node)
		for pg_ast_node* child in node.children:
			if ((child.token == 0) && (pg_ast_get_metadata(child, c"antlr_tree:fold", 0) == 1)):
				at_tree_item* folded = at_tree_context(child)
				folded.children.push(value)
				at_tree_project_children(child, folded.children)
				value = folded
			else: at_tree_project_into(child, value.children)
		out.push(value)
		return
	at_tree_project_children(node, out)


void at_tree_write(string_builder* out, at_tree_item* item):
	if (item.is_token):
		string_append(out, c"{\"token\":")
		at_tree_quote(out, item.text)
		string_append_char(out, '}')
		return
	string_append(out, c"{\"rule\":")
	at_tree_quote(out, item.rule)
	string_append(out, c",\"context\":")
	at_tree_quote(out, item.context)
	string_append(out, c",\"children\":[")
	for i, child in item.children:
		if (i > 0): string_append_char(out, ',')
		at_tree_write(out, child)
	string_append(out, c"]}")


# Canonical JSON for the root, or 0 when the projection is not a single tree.
char* at_tree_json(pg_ast_node* root):
	list[at_tree_item*] items = new list[at_tree_item*]
	at_tree_project_into(root, items)
	if (items.length != 1): return 0
	string_builder* out = string_new()
	at_tree_write(out, items[0])
	return out.data
