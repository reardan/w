import tools.wc2.expressions
import bin.wc2_parser


struct wc2_event:
	pg_ast_node* syntax
	pg_ast_node* body
	pg_ast_node* condition
	pg_token* first
	int indent
	int clause
	int top_level


struct wc2_lowering:
	wc2_module* module
	list[wc2_event*] events
	int next


int wc2_indentation(wc2_module* m, pg_token* token):
	int start = token.offset
	while ((start > 0) && (m.source[start - 1] != '\n')): start = start - 1
	int indent = 0
	while (m.source[start] == '\t'):
		indent = indent + 1
		start = start + 1
	if (m.source[start] == ' '):
		wc2_error(m, token, c"wc2: indentation must use tabs")
	return indent


# Flatten statement headers in source order. The PG's block_body accepts
# any positive indentation and can absorb a sibling into an inner block.
# Its expression trees remain useful; its statement parentage is rebuilt.
void wc2_collect(wc2_lowering* c):
	list[pg_ast_node*] pending = new list[pg_ast_node*]
	pending.push(c.module.syntax)
	while (pending.length > 0):
		pg_ast_node* raw = pending.pop()
		int top = wc2_rule(raw, c"declaration")
		int statement = wc2_rule(raw, c"statement")
		if (top || statement):
			pg_ast_node* syntax = raw.children[0]
			if (statement): syntax = syntax.children[0]
			wc2_event* event = new wc2_event()
			event.syntax = syntax
			event.first = syntax.first_token
			event.indent = wc2_indentation(c.module, event.first)
			event.top_level = top
			event.clause = 0
			if (wc2_rule(syntax, c"elif_stmt")): event.clause = 1
			if (wc2_rule(syntax, c"else_stmt")):
				event.clause = 2
				pg_ast_node* nested_if = wc2_part(syntax, c"if_stmt")
				if (nested_if != 0):
					syntax = nested_if
					event.clause = 1
			event.body = wc2_part(syntax, c"block")
			event.condition = wc2_part(syntax, c"paren_expression_opt")
			if (wc2_rule(syntax, c"function_decl")):
				event.body = wc2_part(wc2_part(syntax, c"function_body"), c"block")
			else if ((wc2_rule(syntax, c"if_stmt") || wc2_rule(syntax, c"elif_stmt") || wc2_rule(syntax, c"while_stmt") || wc2_rule(syntax, c"else_stmt")) == 0):
				# An unsupported declaration/statement is one diagnostic;
				# do not reinterpret its body as surrounding-scope siblings.
				event.body = 0
			c.events.push(event)
			if (event.body != 0):
				if (strcmp(event.body.first_token.text, c":") != 0):
					wc2_error(c.module, event.body.first_token, c"wc2: brace blocks are not supported yet")
				else: pending.push(event.body)
		else:
			int i = raw.children.length - 1
			while (i >= 0):
				pending.push(raw.children[i])
				i = i - 1
	__w_list_free(cast(__w_list*, pending))


int wc2_declared_type(wc2_module* m, pg_ast_node* syntax):
	pg_token* token = syntax.first_token
	if (token == syntax.last_token):
		if (strcmp(token.text, c"int") == 0): return wc2_int_type
		if (strcmp(token.text, c"bool") == 0): return wc2_bool_type
		if (strcmp(token.text, c"void") == 0): return wc2_void_type
	wc2_error(m, token, c"wc2: only int, bool and void types are supported yet")
	return wc2_unresolved_type


wc2_node* wc2_lower_declaration(wc2_module* m, pg_ast_node* syntax, int scope, int kind):
	pg_ast_node* name = wc2_part(syntax, c"name_token")
	if (name == 0):
		wc2_error(m, syntax.first_token, c"wc2: a declaration must have a name")
		return 0
	pg_ast_node* suffix = wc2_part(syntax, c"decl_suffix")
	if ((suffix != 0) && (suffix.children.length != 0)):
		wc2_error(m, suffix.first_token, c"wc2: array declarations are not supported yet")
		return 0
	wc2_node* node = wc2_node_new(m, kind, scope, syntax.first_token, syntax.last_token, name.first_token.text)
	pg_ast_node* type = wc2_part(syntax, c"type_ref")
	if (type != 0): node.type_id = wc2_declared_type(m, type)
	m.scopes[scope].declarations.push(node.id)
	pg_ast_node* initializer = wc2_part(syntax, c"expression")
	pg_ast_node* local_suffix = wc2_part(syntax, c"local_suffix")
	if (local_suffix == 0): local_suffix = wc2_part(syntax, c"global_suffix")
	if (local_suffix != 0):
		initializer = wc2_part(local_suffix, c"expression")
		if (wc2_part(local_suffix, c"expr_stmt_tail") != 0):
			wc2_error(m, local_suffix.first_token, c"wc2: parallel assignment is not supported yet")
	pg_ast_node* default_value = wc2_part(syntax, c"param_default")
	if ((default_value != 0) && (default_value.children.length != 0)):
		wc2_error(m, default_value.first_token, c"wc2: default parameters are not supported yet")
	if (wc2_part(syntax, c"ELLIPSIS") != 0):
		wc2_error(m, syntax.first_token, c"wc2: variadic parameters are not supported yet")
	if (initializer != 0): wc2_add(node, wc2_lower_expression(m, initializer, scope, 0))
	return node


void wc2_lower_parameters(wc2_module* m, pg_ast_node* syntax, wc2_node* fn_node, int scope):
	for pg_ast_node* child in syntax.children:
		if (wc2_rule(child, c"param")):
			wc2_add(fn_node, wc2_lower_declaration(m, child, scope, wc2_parameter_kind))
		else if (wc2_rule(child, c"param_tail")):
			wc2_lower_parameters(m, child, fn_node, scope)


wc2_node* wc2_lower_statement(wc2_lowering* c, int scope, int depth, int loops);


wc2_node* wc2_lower_block(wc2_lowering* c, wc2_event* header, int parent, int depth, int loops):
	wc2_module* m = c.module
	if (header.body == 0):
		wc2_error(m, header.first, c"wc2: function prototypes are not supported yet")
		return 0
	pg_token* colon = header.body.first_token
	wc2_node* block = wc2_node_new(m, wc2_block_kind, parent, colon, colon, c"")
	block.scope = wc2_scope_new(m, parent, block.id)
	if (depth > 100):
		wc2_error(m, colon, c"wc2: block nesting limit exceeded")
		return block
	if (c.next >= c.events.length): return block
	wc2_event* next = c.events[c.next]
	# The production compiler permits empty blocks and an arbitrary first
	# indentation increment. An inline body contains exactly one statement.
	if (next.first.line == colon.line):
		wc2_add(block, wc2_lower_statement(c, block.scope, depth + 1, loops))
		return block
	if (next.indent <= header.indent): return block
	int body_indent = next.indent
	while (c.next < c.events.length):
		next = c.events[c.next]
		if (next.indent < body_indent): break
		wc2_add(block, wc2_lower_statement(c, block.scope, depth + 1, loops))
	return block


wc2_node* wc2_lower_if(wc2_lowering* c, wc2_event* event, int scope, int depth, int loops):
	wc2_module* m = c.module
	if (depth > 100):
		wc2_error(m, event.first, c"wc2: block nesting limit exceeded")
		return 0
	wc2_node* node = wc2_node_new(m, wc2_if_kind, scope, event.first, event.condition.last_token, c"")
	wc2_add(node, wc2_lower_expression(m, event.condition, scope, 0))
	wc2_add(node, wc2_lower_block(c, event, scope, depth + 1, loops))
	if (c.next < c.events.length):
		wc2_event* next = c.events[c.next]
		if ((next.clause != 0) && (next.indent == event.indent)):
			c.next = c.next + 1
			if (next.clause == 1): wc2_add(node, wc2_lower_if(c, next, scope, depth + 1, loops))
			else: wc2_add(node, wc2_lower_block(c, next, scope, depth + 1, loops))
	return node


wc2_node* wc2_lower_statement(wc2_lowering* c, int scope, int depth, int loops):
	wc2_module* m = c.module
	wc2_event* event = c.events[c.next]
	c.next = c.next + 1
	pg_ast_node* syntax = event.syntax
	if (event.top_level || (event.clause != 0)):
		wc2_error(m, event.first, c"wc2: unexpected declaration or unmatched else/elif")
		return 0
	if (wc2_rule(syntax, c"if_stmt")): return wc2_lower_if(c, event, scope, depth, loops)
	if (wc2_rule(syntax, c"while_stmt")):
		wc2_node* loop = wc2_node_new(m, wc2_while_kind, scope, event.first, event.condition.last_token, c"")
		wc2_add(loop, wc2_lower_expression(m, event.condition, scope, 0))
		wc2_add(loop, wc2_lower_block(c, event, scope, depth + 1, loops + 1))
		return loop
	if (wc2_rule(syntax, c"local_decl") || wc2_rule(syntax, c"infer_decl")):
		return wc2_lower_declaration(m, syntax, scope, wc2_declaration_kind)
	int kind = 0
	pg_ast_node* expression = 0
	if (wc2_rule(syntax, c"return_stmt")):
		kind = wc2_return_kind
		expression = wc2_part(wc2_part(syntax, c"expression_opt"), c"expression")
	else if (wc2_rule(syntax, c"expression_stmt")):
		kind = wc2_expression_statement_kind
		expression = wc2_part(syntax, c"expression")
		if (syntax.children.length != 1):
			wc2_error(m, event.first, c"wc2: parallel assignment is not supported yet")
	else if (wc2_rule(syntax, c"pass_stmt")): kind = wc2_pass_kind
	else if (wc2_rule(syntax, c"break_stmt")): kind = wc2_break_kind
	else if (wc2_rule(syntax, c"continue_stmt")): kind = wc2_continue_kind
	if (kind == 0):
		wc2_error(m, event.first, c"wc2: unsupported statement")
		return 0
	if (((kind == wc2_break_kind) || (kind == wc2_continue_kind)) && (loops == 0)):
		wc2_error(m, event.first, c"wc2: break/continue outside a loop")
	wc2_node* node = wc2_node_new(m, kind, scope, event.first, syntax.last_token, c"")
	if (expression != 0): wc2_add(node, wc2_lower_expression(m, expression, scope, 0))
	return node


wc2_node* wc2_lower_function(wc2_lowering* c, wc2_event* event):
	wc2_module* m = c.module
	pg_ast_node* syntax = event.syntax
	pg_ast_node* name = wc2_part(syntax, c"name_token")
	wc2_node* fn_node = wc2_node_new(m, wc2_function_kind, 0, event.first, name.last_token, name.first_token.text)
	fn_node.type_id = wc2_declared_type(m, wc2_part(syntax, c"type_ref"))
	m.scopes[0].declarations.push(fn_node.id)
	pg_ast_node* generic = wc2_part(syntax, c"generic_opt")
	if (generic.children.length != 0):
		wc2_error(m, generic.first_token, c"wc2: generic functions are not supported yet")
	int scope = wc2_scope_new(m, 0, fn_node.id)
	wc2_lower_parameters(m, wc2_part(syntax, c"param_list"), fn_node, scope)
	wc2_add(fn_node, wc2_lower_block(c, event, scope, 0, 0))
	return fn_node


wc2_module* wc2_parse(char* source, char* filename):
	wc2_module* m = wc2_module_new(source, filename)
	# Own the stream explicitly: wlang_parse's convenience entry point
	# hides it, preventing its caller from releasing tokens with the tree.
	m.tokens = wlang_lex(m.source, m.filename, m.diagnostics)
	if (pg_diagnostics_count(m.diagnostics) != 0): return m
	pg_token_stream_own_ast(m.tokens)
	m.syntax = wlang_parse_program(m.tokens, m.diagnostics)
	if (m.syntax == 0):
		pg_syntax_error(m.diagnostics, pg_token_stream_furthest(m.tokens), c"program")
	if (pg_diagnostics_count(m.diagnostics) != 0): return m
	pg_token* first = pg_token_stream_get(m.tokens, 0)
	pg_token* last = pg_token_stream_get(m.tokens, m.tokens.tokens.length - 1)
	wc2_node* root = wc2_node_new(m, wc2_module_kind, 0, first, last, c"")
	root.start = 0
	root.line = 1
	root.column = 1
	m.root = root.id
	wc2_scope_new(m, -1, root.id)
	wc2_lowering* c = new wc2_lowering()
	c.module = m
	c.events = new list[wc2_event*]
	c.next = 0
	wc2_collect(c)
	# Rejected syntax must never appear to be a successful partial AST.
	if (pg_diagnostics_count(m.diagnostics) == 0):
		while (c.next < c.events.length):
			wc2_event* event = c.events[c.next]
			c.next = c.next + 1
			if ((event.top_level == 0) || (event.indent != 0)):
				wc2_error(m, event.first, c"wc2: expected a top-level function or global declaration")
			else if (wc2_rule(event.syntax, c"function_decl")):
				wc2_add(root, wc2_lower_function(c, event))
			else if (wc2_rule(event.syntax, c"global_decl")):
				wc2_add(root, wc2_lower_declaration(m, event.syntax, 0, wc2_declaration_kind))
			else: wc2_error(m, event.first, c"wc2: unsupported top-level declaration")
	for wc2_event* event in c.events: free(event)
	__w_list_free(cast(__w_list*, c.events))
	free(c)
	return m
