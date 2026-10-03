# Semantic AST for the leaf compiler experiment (#488).
# IDs are stable only within one module. Spans are half-open byte ranges;
# line/column are one-based. No node borrows a compiler-global table slot.
import libs.extras.parser_generator.runtime


const int wc2_module_kind = 1
const int wc2_function_kind = 2
const int wc2_block_kind = 3
const int wc2_parameter_kind = 4
const int wc2_declaration_kind = 5
const int wc2_return_kind = 6
const int wc2_if_kind = 7
const int wc2_while_kind = 8
const int wc2_expression_statement_kind = 9
const int wc2_integer_kind = 10
const int wc2_name_kind = 11
const int wc2_unary_kind = 12
const int wc2_binary_kind = 13
const int wc2_logical_kind = 14
const int wc2_assignment_kind = 15
const int wc2_call_kind = 16
const int wc2_pass_kind = 17
const int wc2_break_kind = 18
const int wc2_continue_kind = 19
const int wc2_struct_kind = 20
const int wc2_member_kind = 21
const int wc2_import_kind = 22
const int wc2_named_type = 4
const int wc2_struct_type_base = 1000

# Intrinsic/declared types only. Expression inference and name binding are
# a later pass; -1 must never be mistaken for the production type table.
const int wc2_unresolved_type = -1
const int wc2_int_type = 0
const int wc2_bool_type = 1
const int wc2_void_type = 2
const int wc2_integer_literal_type = 3


struct wc2_node:
	int id
	int kind
	int start
	int end
	int line
	int column
	int scope
	int type_id
	int binding
	char* text
	char* type_name
	char* filename
	list[int] children


struct wc2_scope:
	int parent
	int owner
	list[int] declarations


struct wc2_module:
	char* filename
	char* source
	pg_token_stream* tokens
	pg_ast_node* syntax
	pg_diagnostics* diagnostics
	list[wc2_node*] nodes
	list[wc2_scope*] scopes
	int root
	list[wc2_module*] dependencies


wc2_module* wc2_module_new(char* source, char* filename):
	wc2_module* m = new wc2_module()
	m.filename = strclone(filename)
	m.source = strclone(source)
	m.tokens = 0
	m.syntax = 0
	m.diagnostics = pg_diagnostics_new()
	m.nodes = new list[wc2_node*]
	m.scopes = new list[wc2_scope*]
	m.root = -1
	m.dependencies = new list[wc2_module*]
	return m


int wc2_scope_new(wc2_module* m, int parent, int owner):
	wc2_scope* scope = new wc2_scope()
	scope.parent = parent
	scope.owner = owner
	scope.declarations = new list[int]
	int id = m.scopes.length
	m.scopes.push(scope)
	return id


wc2_node* wc2_node_new(wc2_module* m, int kind, int scope, pg_token* first, pg_token* last, char* text):
	wc2_node* node = new wc2_node()
	node.id = m.nodes.length
	node.kind = kind
	node.start = first.offset
	node.end = last.offset + last.length
	node.line = first.line
	node.column = first.column
	node.scope = scope
	node.type_id = wc2_unresolved_type
	node.binding = -1
	node.text = strclone(text)
	node.type_name = strclone(c"")
	node.filename = strclone(m.filename)
	node.children = new list[int]
	m.nodes.push(node)
	return node


void wc2_add(wc2_node* parent, wc2_node* child):
	if (child == 0): return
	parent.children.push(child.id)
	if (child.end > parent.end): parent.end = child.end


wc2_node* wc2_child(wc2_module* m, wc2_node* node, int index):
	return m.nodes[node.children[index]]


void wc2_error(wc2_module* m, pg_token* at, char* message):
	pg_diagnostics_add(m.diagnostics, m.filename, at.line, at.column, message, c"", at.text)


int wc2_module_ok(wc2_module* m):
	return (m.root >= 0) && (pg_diagnostics_count(m.diagnostics) == 0)


char* wc2_kind_name(int kind):
	if (kind == wc2_module_kind): return c"module"
	if (kind == wc2_function_kind): return c"function"
	if (kind == wc2_block_kind): return c"block"
	if (kind == wc2_parameter_kind): return c"parameter"
	if (kind == wc2_declaration_kind): return c"declaration"
	if (kind == wc2_return_kind): return c"return"
	if (kind == wc2_if_kind): return c"if"
	if (kind == wc2_while_kind): return c"while"
	if (kind == wc2_expression_statement_kind): return c"expression_statement"
	if (kind == wc2_integer_kind): return c"integer"
	if (kind == wc2_name_kind): return c"name"
	if (kind == wc2_unary_kind): return c"unary"
	if (kind == wc2_binary_kind): return c"binary"
	if (kind == wc2_logical_kind): return c"logical"
	if (kind == wc2_assignment_kind): return c"assignment"
	if (kind == wc2_call_kind): return c"call"
	if (kind == wc2_pass_kind): return c"pass"
	if (kind == wc2_break_kind): return c"break"
	if (kind == wc2_continue_kind): return c"continue"
	if (kind == wc2_struct_kind): return c"struct"
	if (kind == wc2_member_kind): return c"member"
	if (kind == wc2_import_kind): return c"import"
	return c"unknown"


void wc2_module_free(wc2_module* m):
	if (m == 0): return
	for wc2_node* node in m.nodes:
		free(node.text)
		free(node.type_name)
		free(node.filename)
		__w_list_free(cast(__w_list*, node.children))
		free(node)
	for wc2_scope* scope in m.scopes:
		__w_list_free(cast(__w_list*, scope.declarations))
		free(scope)
	__w_list_free(cast(__w_list*, m.nodes))
	__w_list_free(cast(__w_list*, m.scopes))
	for wc2_module* dependency in m.dependencies: wc2_module_free(dependency)
	__w_list_free(cast(__w_list*, m.dependencies))
	# Tree leaves borrow token pointers; diagnostics borrow the filename.
	# The stream owns reachable AND abandoned PG nodes (opt-in at parse).
	pg_token_stream_free(m.tokens)
	pg_diagnostics_free(m.diagnostics)
	free(m.source)
	free(m.filename)
	free(m)
