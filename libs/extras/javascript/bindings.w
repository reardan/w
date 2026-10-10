# Binding and parameter early errors for the supported JavaScript syntax.
# Every scope owns decoded names; the CST and diagnostics remain result-owned.
import lib.container
import libs.extras.javascript.validation
import libs.extras.javascript.strings


struct js_binding_name:
	char* name
	pg_ast_node* node


struct js_binding_scope:
	js_binding_scope* parent
	int function_scope
	int program_scope
	char* catch_parameter
	list[js_binding_name*] lexical
	list[js_binding_name*] variables


js_binding_scope* js_binding_scope_new(js_binding_scope* parent, int function_scope, int program_scope):
	js_binding_scope* scope = new js_binding_scope()
	scope.parent = parent
	scope.function_scope = function_scope
	scope.program_scope = program_scope
	scope.catch_parameter = 0
	scope.lexical = new list[js_binding_name*]
	scope.variables = new list[js_binding_name*]
	return scope


void js_binding_names_free(list[js_binding_name*] names):
	for js_binding_name* binding in names:
		free(binding.name)
		free(binding)
	list_free[js_binding_name*](names)


void js_binding_scope_free(js_binding_scope* scope):
	js_binding_names_free(scope.lexical)
	js_binding_names_free(scope.variables)
	free(scope)


int js_binding_name_exists(list[js_binding_name*] names, char* name):
	for js_binding_name* binding in names:
		if (strcmp(binding.name, name) == 0): return 1
	return 0


void js_binding_name_add(list[js_binding_name*] names, char* name, pg_ast_node* node):
	js_binding_name* binding = new js_binding_name()
	binding.name = strclone(name)
	binding.node = node
	names.push(binding)


# Initializers are expressions, not bindings. Property-name nodes likewise
# cannot contribute a binding; their computed expressions may contain one.
void js_binding_collect(pg_ast_node* node, list[js_binding_name*] names):
	if (node == 0): return
	if (js_cst_is(node, c"initializer") || js_cst_is(node, c"property_name")): return
	if (js_cst_is(node, c"binding_identifier")):
		char* name = js_identifier_decode(node.first_token.text)
		js_binding_name_add(names, name, node)
		free(name)
		return
	for pg_ast_node* child in node.children: js_binding_collect(child, names)


void js_binding_declare(js_binding_scope* scope, js_binding_name* binding, int lexical, pg_diagnostics* diagnostics):
	if (lexical):
		if (js_binding_name_exists(scope.lexical, binding.name) || js_binding_name_exists(scope.variables, binding.name)):
			js_validation_error(diagnostics, binding.node, c"duplicate lexical binding")
		js_binding_name_add(scope.lexical, binding.name, binding.node)
		return
	# A var is visible in every enclosing statement block through its
	# containing function/program. Retain its name in those blocks so a
	# later lexical declaration detects the conflict independent of order.
	js_binding_scope* owner = scope
	while (owner != 0):
		int catch_exception = owner.catch_parameter != 0 && strcmp(owner.catch_parameter, binding.name) == 0
		if (catch_exception == 0 && js_binding_name_exists(owner.lexical, binding.name)):
			js_validation_error(diagnostics, binding.node, c"var conflicts with lexical binding")
		if (js_binding_name_exists(owner.variables, binding.name) == 0): js_binding_name_add(owner.variables, binding.name, binding.node)
		if (owner.function_scope || owner.program_scope): break
		owner = owner.parent


void js_binding_declare_tree(js_binding_scope* scope, pg_ast_node* node, int lexical, pg_diagnostics* diagnostics):
	list[js_binding_name*] names = new list[js_binding_name*]
	js_binding_collect(node, names)
	for js_binding_name* binding in names: js_binding_declare(scope, binding, lexical, diagnostics)
	js_binding_names_free(names)


pg_ast_node* js_binding_function_body(pg_ast_node* node):
	pg_ast_node* body = js_cst_child(node, c"block")
	if (body != 0): return body
	pg_ast_node* arrow = js_cst_child(node, c"arrow_body")
	if (arrow != 0): return js_cst_child(arrow, c"block")
	return 0


pg_ast_node* js_binding_parameters(pg_ast_node* node):
	pg_ast_node* params = js_cst_child(node, c"parameters")
	if (params != 0): return params
	params = js_cst_child(node, c"arrow_parameters")
	if (params != 0): return params
	# Accessor grammar spells setter parameters without a parameters node.
	return js_cst_child(node, c"parameter")


int js_binding_non_simple(pg_ast_node* node):
	if (node == 0): return 0
	if (js_cst_is(node, c"initializer") || js_cst_is(node, c"array_binding") || js_cst_is(node, c"object_binding") || js_cst_is(node, c"rest_parameter")): return 1
	for pg_ast_node* child in node.children:
		if (js_binding_non_simple(child)): return 1
	return 0


void js_binding_rest_last(pg_ast_node* node, pg_ast_node* list_node, char* rest_kind, pg_diagnostics* diagnostics):
	if (node == 0): return
	if (js_cst_is(node, rest_kind)):
		if (node.last_token != list_node.last_token): js_validation_error(diagnostics, node, c"rest binding must be last without trailing comma")
		return
	for pg_ast_node* child in node.children: js_binding_rest_last(child, list_node, rest_kind, diagnostics)


void js_binding_validate_parameters(pg_ast_node* node, js_binding_scope* scope, int strict, pg_diagnostics* diagnostics):
	pg_ast_node* params = js_binding_parameters(node)
	if (params == 0): return
	int non_simple = js_binding_non_simple(params)
	pg_ast_node* body = js_binding_function_body(node)
	if (non_simple && js_directive_strict(body)):
		js_validation_error(diagnostics, params, c"use strict directive with non-simple parameters")
	int unique = strict || non_simple || js_cst_is(node, c"arrow_function") || js_cst_is(node, c"method")
	list[js_binding_name*] names = new list[js_binding_name*]
	js_binding_collect(params, names)
	for js_binding_name* binding in names:
		if (unique && js_binding_name_exists(scope.variables, binding.name)):
			js_validation_error(diagnostics, binding.node, c"duplicate parameter binding")
		js_binding_name_add(scope.variables, binding.name, binding.node)
	js_binding_names_free(names)


char* js_binding_property_name(pg_ast_node* node, pg_diagnostics* diagnostics):
	pg_ast_node* property = js_cst_child(node, c"property_name")
	if (property == 0 || property.children.length != 1): return 0
	pg_ast_node* value = js_cst_unwrap(property)
	if (value.token == 0): return 0
	if (js_cst_is(value, c"STRING")): return js_string_decode(value.text, diagnostics)
	return js_identifier_decode(value.text)


void js_binding_validate_class(pg_ast_node* node, pg_diagnostics* diagnostics):
	pg_ast_node* tail = js_cst_child(node, c"class_tail")
	if (tail == 0): return
	int constructors = 0
	for pg_ast_node* element in tail.children:
		if (js_cst_is(element, c"class_element") == 0): continue
		pg_ast_node* method = js_cst_child(element, c"method")
		if (method == 0): continue
		int is_static = js_cst_child(element, c"KW_STATIC") != 0
		char* name = js_binding_property_name(method, diagnostics)
		if (name == 0): continue
		if (is_static && strcmp(name, c"prototype") == 0): js_validation_error(diagnostics, method, c"static class method named prototype")
		if (is_static == 0 && strcmp(name, c"constructor") == 0):
			constructors = constructors + 1
			if (constructors > 1): js_validation_error(diagnostics, method, c"duplicate class constructor")
			if (js_cst_child(method, c"async_modifier") != 0 || js_cst_child(method, c"STAR") != 0 || js_cst_child(method, c"KW_GET") != 0 || js_cst_child(method, c"KW_SET") != 0):
				js_validation_error(diagnostics, method, c"constructor cannot be async, generator or accessor")
		free(name)


void js_binding_walk(pg_ast_node* node, js_binding_scope* scope, int strict, int module, pg_ast_node* function_body, pg_diagnostics* diagnostics):
	if (node == 0): return
	if (js_is_function(node)):
		if (js_cst_is(node, c"function_decl") || (js_cst_is(node, c"function_expr") && js_cst_is(node.parent, c"export_default"))):
			int lexical = (scope.function_scope == 0 && scope.program_scope == 0) || (scope.program_scope && module)
			js_binding_declare_tree(scope, js_cst_child(node, c"binding_identifier"), lexical, diagnostics)
		pg_ast_node* body = js_binding_function_body(node)
		if (js_directive_strict(body)): strict = 1
		js_binding_scope* inner = js_binding_scope_new(scope, 1, 0)
		js_binding_validate_parameters(node, inner, strict, diagnostics)
		for pg_ast_node* child in node.children: js_binding_walk(child, inner, strict, module, body, diagnostics)
		js_binding_scope_free(inner)
		return
	int own_scope = 0
	if ((js_cst_is(node, c"block") && node != function_body) || js_cst_is(node, c"for_statement") || js_cst_is(node, c"switch_statement") || js_cst_is(node, c"catch_clause")):
		scope = js_binding_scope_new(scope, 0, 0)
		own_scope = 1
	if (js_cst_is(node, c"program") && js_directive_strict(node)): strict = 1
	if (js_cst_is(node, c"class_decl") || js_cst_is(node, c"class_expr")):
		if (js_cst_is(node, c"class_decl") || js_cst_is(node.parent, c"export_default")): js_binding_declare_tree(scope, js_cst_child(node, c"binding_identifier"), 1, diagnostics)
		js_binding_validate_class(node, diagnostics)
		strict = 1
	if (js_cst_is(node, c"variable_declarations")):
		int lexical = strcmp(node.first_token.text, c"var") != 0
		js_binding_declare_tree(scope, node, lexical, diagnostics)
	if (js_cst_is(node, c"for_binding")):
		pg_ast_node* kind = js_cst_child(node, c"variable_kind")
		if (kind != 0): js_binding_declare_tree(scope, js_cst_child(node, c"binding_pattern"), strcmp(kind.first_token.text, c"var") != 0, diagnostics)
	if (js_cst_is(node, c"import_statement")): js_binding_declare_tree(scope, node, 1, diagnostics)
	if (js_cst_is(node, c"catch_clause")):
		pg_ast_node* catch_binding = js_cst_child(node, c"catch_binding")
		js_binding_declare_tree(scope, catch_binding, 1, diagnostics)
		if (catch_binding != 0):
			pg_ast_node* pattern = js_cst_child(catch_binding, c"binding_pattern")
			if (pattern != 0 && js_cst_unwrap(pattern).token != 0): scope.catch_parameter = scope.lexical[0].name
		# Catch parameters share the body's lexical declaration checks.
		function_body = js_cst_child(node, c"block")
	if (js_cst_is(node, c"parameter_list")): js_binding_rest_last(node, node, c"rest_parameter", diagnostics)
	if (js_cst_is(node, c"object_binding_items")):
		js_binding_rest_last(node, node, c"binding_rest", diagnostics)
	if (js_cst_is(node, c"binding_rest") && node.parent != 0):
		pg_ast_node* parent = node.parent
		if (js_cst_is(parent, c"object_binding_items") || js_cst_is(parent, c"object_binding_tail")):
			pg_ast_node* value = js_cst_unwrap(node.children[node.children.length - 1])
			if (value.token == 0): js_validation_error(diagnostics, node, c"object rest binding must be an identifier")
	for pg_ast_node* child in node.children: js_binding_walk(child, scope, strict, module, function_body, diagnostics)
	if (own_scope): js_binding_scope_free(scope)


void js_validate_bindings(pg_parse_result* result, int module):
	if (result.success == 0): return
	js_binding_scope* scope = js_binding_scope_new(0, 0, 1)
	js_binding_walk(result.root, scope, module, module, 0, result.diagnostics)
	js_binding_scope_free(scope)
	if (pg_diagnostics_count(result.diagnostics) != 0): result.success = 0
