/*
Small owned JavaScript AST facade, independent of generated grammar rule
names. Nodes own text, kind, and their children. Each child has one owner;
callers must not create cycles or share a child between parents.

Source offsets/lengths are byte spans, or offset -1 for constructed nodes.
The supported printer node shapes are documented in printer.w.
*/
import lib.lib
import libs.extras.javascript.text


struct js_node:
	char* kind
	char* text
	js_text* string_units
	list[js_node*] children
	int offset
	int length


type js_node_visitor = fn(js_node*) -> void


js_node* js_node_new(char* kind, char* text):
	js_node* node = new js_node()
	node.kind = strclone(kind)
	node.text = strclone(text)
	node.children = new list[js_node*]
	node.string_units = 0
	node.offset = -1
	node.length = 0
	return node


void js_node_add(js_node* parent, js_node* child):
	if (child != 0): parent.children.push(child)


js_node* js_identifier(char* name):
	return js_node_new(c"identifier", name)


js_node* js_string(char* value):
	return js_node_new(c"string", value)


js_node* js_number(char* spelling):
	return js_node_new(c"number", spelling)


js_node* js_binary(char* op, js_node* left, js_node* right):
	js_node* node = js_node_new(c"binary", op)
	js_node_add(node, left)
	js_node_add(node, right)
	return node


js_node* js_call(js_node* callee):
	js_node* node = js_node_new(c"call", c"")
	js_node_add(node, callee)
	return node


# Returns the detached previous child, which the caller now owns. A bad
# index returns 0 and does not take ownership of replacement.
js_node* js_node_replace(js_node* parent, int index, js_node* replacement):
	if (index < 0 || index >= parent.children.length || replacement == 0): return 0
	js_node* previous = parent.children[index]
	parent.children[index] = replacement
	return previous


void js_node_walk(js_node* node, js_node_visitor* visitor):
	if (node == 0): return
	visitor(node)
	for i in range(node.children.length): js_node_walk(node.children[i], visitor)


void js_node_free(js_node* node):
	if (node == 0): return
	for i in range(node.children.length): js_node_free(node.children[i])
	__w_list_free(cast(__w_list*, node.children))
	free(node.kind)
	js_text_free(node.string_units)
	free(node.text)
	free(node)


# Compare syntax structure, excluding source spans. Used for round trips.
int js_node_equal(js_node* left, js_node* right):
	if (left == 0 || right == 0): return left == right
	if (strcmp(left.kind, right.kind) != 0 || strcmp(left.text, right.text) != 0): return 0
	if (js_text_equal(left.string_units, right.string_units) == 0): return 0
	if (left.children.length != right.children.length): return 0
	for i in range(left.children.length):
		if (js_node_equal(left.children[i], right.children[i]) == 0): return 0
	return 1


# Copies UTF-16 code units; caller retains the input.
js_node* js_string_utf16(js_text* value):
	int length = 0
	char* scalar = js_text_to_utf8(value, &length)
	if (scalar != 0 && strlen(scalar) == length):
		js_node* simple = js_string(scalar)
		free(scalar)
		return simple
	free(scalar)
	js_node* node = js_node_new(c"string_utf16", c"")
	node.string_units = js_text_clone(value)
	return node
