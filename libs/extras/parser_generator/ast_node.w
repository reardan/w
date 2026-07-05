/*
AST node runtime for generated parsers.
*/
import lib.lib
import structures.array_list
import structures.hash_map
import libs.extras.parser_generator.token


struct pg_ast_node:
	int kind
	char* name
	char* text
	pg_token* token
	array_list* children
	pg_ast_node* parent
	hash_map* metadata
	pg_token* first_token
	pg_token* last_token


# Kind tag for error-recovery nodes holding the tokens skipped while the
# parser resynchronized. Rule kinds are positive, so -1 never collides.
int pg_ast_error_kind():
	return -1


pg_ast_node* pg_ast_new(int kind, pg_token* token, char* name):
	pg_ast_node* node = new pg_ast_node()
	node.kind = kind
	node.name = strclone(name)
	node.text = 0
	node.token = token
	node.children = array_list_new()
	node.parent = 0
	node.metadata = 0
	node.first_token = token
	node.last_token = token
	if (token != 0):
		node.text = strclone(token.text)
	return node


pg_ast_node* pg_ast_token(int kind, pg_token* token, char* name):
	return pg_ast_new(kind, token, name)


# Spans grow as children are added: trees are built bottom-up, so a child's
# span is final by the time it is attached to its parent.
void pg_ast_add(pg_ast_node* parent, pg_ast_node* child):
	if (child == 0):
		return
	child.parent = parent
	array_list_push(parent.children, cast(int, child))
	if (child.first_token != 0):
		if (parent.first_token == 0):
			parent.first_token = child.first_token
		parent.last_token = child.last_token


# First/last token covered by this node, or 0 for an empty node (e.g. a rule
# that matched only optional terms).
pg_token* pg_ast_first_token(pg_ast_node* node):
	return node.first_token


pg_token* pg_ast_last_token(pg_ast_node* node):
	return node.last_token


int pg_ast_child_count(pg_ast_node* node):
	return node.children.length


pg_ast_node* pg_ast_child(pg_ast_node* node, int index):
	return cast(pg_ast_node*, array_list_get(node.children, index))


void pg_ast_set_metadata(pg_ast_node* node, char* key, int value):
	if (node.metadata == 0):
		node.metadata = hash_map_new()
	hash_map_set(node.metadata, key, value)


int pg_ast_get_metadata(pg_ast_node* node, char* key, int missing):
	if (node.metadata == 0):
		return missing
	return hash_map_get_default(node.metadata, key, missing)


type pg_ast_visitor = fn(pg_ast_node*) -> void


void pg_ast_walk_preorder(pg_ast_node* node, pg_ast_visitor* visitor):
	if (node == 0):
		return
	visitor(node)
	int i = 0
	while (i < node.children.length):
		pg_ast_walk_preorder(cast(pg_ast_node*, array_list_get(node.children, i)), visitor)
		i = i + 1


void pg_ast_walk_listener(pg_ast_node* node, pg_ast_visitor* enter, pg_ast_visitor* leave):
	if (node == 0):
		return
	enter(node)
	int i = 0
	while (i < node.children.length):
		pg_ast_walk_listener(cast(pg_ast_node*, array_list_get(node.children, i)), enter, leave)
		i = i + 1
	leave(node)


void pg_ast_free(pg_ast_node* node):
	if (node == 0):
		return
	int i = 0
	while (i < node.children.length):
		pg_ast_free(cast(pg_ast_node*, array_list_get(node.children, i)))
		i = i + 1
	if (node.text != 0):
		free(node.text)
	free(node.name)
	array_list_free(node.children)
	if (node.metadata != 0):
		hash_map_free(node.metadata)
	free(node)
