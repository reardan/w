/*
Small owned JavaScript AST facade, independent of generated grammar rule
names. Nodes own text, kind, and their children. Each child has one owner;
callers must not create cycles or share a child between parents.

Source offsets/lengths are byte spans, or offset -1 for constructed nodes.
The supported printer node shapes are documented in printer.w.
*/
import lib.lib


struct js_node:
	char* kind
	char* text
	list[js_node*] children
	int offset
	int length


type js_node_visitor = fn(js_node*) -> void


js_node* js_node_new(char* kind, char* text):
	js_node* node = new js_node()
	node.kind = strclone(kind)
	node.text = strclone(text)
	node.children = new list[js_node*]
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
	free(node.text)
	free(node)


# Compare syntax structure, excluding source spans. Used for round trips.
int js_node_equal(js_node* left, js_node* right):
	if (left == 0 || right == 0): return left == right
	if (strcmp(left.kind, right.kind) != 0 || strcmp(left.text, right.text) != 0): return 0
	if (left.children.length != right.children.length): return 0
	for i in range(left.children.length):
		if (js_node_equal(left.children[i], right.children[i]) == 0): return 0
	return 1
