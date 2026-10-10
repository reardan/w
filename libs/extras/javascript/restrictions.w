# Additional syntax-context and assignment-pattern checks.
import libs.extras.javascript.bindings


int js_pattern_target(pg_ast_node* node, int default_allowed, int strict, pg_diagnostics* diagnostics);


pg_ast_node* js_restriction_unwrap_target(pg_ast_node* node):
	node = js_cst_unwrap(node)
	while (js_cst_is(node, c"primary") && node.children.length == 3 && js_cst_is(node.children[0], c"LPAREN")):
		node = js_cst_unwrap(node.children[1])
	return node


int js_restricted_target(pg_ast_node* node, int strict):
	if (strict == 0): return 0
	node = js_restriction_unwrap_target(node)
	if (node.token == 0): return 0
	char* name = js_identifier_decode(node.text)
	int restricted = strcmp(name, c"eval") == 0 || strcmp(name, c"arguments") == 0
	free(name)
	return restricted


int js_array_pattern(pg_ast_node* node, int strict, pg_diagnostics* diagnostics):
	int valid = 1
	for i in range(1, node.children.length - 1):
		pg_ast_node* element = node.children[i]
		if (js_cst_is(element, c"array_tail")): element = element.children[1]
		if (element.children.length == 0): continue
		pg_ast_node* argument = element.children[0]
		int rest = js_cst_child(argument, c"ELLIPSIS") != 0
		pg_ast_node* target = argument.children[argument.children.length - 1]
		if (rest && i != node.children.length - 2): valid = 0
		if (js_pattern_target(target, rest == 0, strict, diagnostics) == 0): valid = 0
	return valid


int js_object_pattern(pg_ast_node* node, int strict, pg_diagnostics* diagnostics):
	pg_ast_node* properties = js_cst_child(node, c"object_properties")
	if (properties == 0): return 1
	int valid = 1
	for pg_ast_node* entry in properties.children:
		pg_ast_node* property = entry
		if (js_cst_is(entry, c"object_property_tail")): property = entry.children[1]
		if (js_cst_is(property, c"object_property") == 0): continue
		if (js_cst_child(property, c"method") != 0):
			valid = 0
			continue
		pg_ast_node* assignment = js_cst_child(property, c"assignment")
		if (js_cst_child(property, c"ELLIPSIS") != 0):
			if (property.last_token != properties.last_token): valid = 0
			if (assignment == 0 || js_simple_target(assignment) == 0 || js_restricted_target(assignment, strict)): valid = 0
		else if (assignment != 0):
			if (js_pattern_target(assignment, 1, strict, diagnostics) == 0): valid = 0
		else:
			pg_ast_node* identifier = js_cst_child(property, c"binding_identifier")
			if (identifier == 0 || js_restricted_target(identifier, strict)): valid = 0
	return valid


int js_pattern_target(pg_ast_node* node, int default_allowed, int strict, pg_diagnostics* diagnostics):
	if (node == 0): return 0
	if (js_simple_target(node)): return js_restricted_target(node, strict) == 0
	node = js_cst_unwrap(node)
	if (js_cst_is(node, c"assignment") && node.children.length == 2):
		pg_ast_node* tail = node.children[1]
		if (default_allowed == 0 || js_cst_is(tail, c"assignment_tail") == 0 || strcmp(tail.first_token.text, c"=") != 0): return 0
		return js_pattern_target(node.children[0], 0, strict, diagnostics)
	if (js_cst_is(node, c"array_literal")): return js_array_pattern(node, strict, diagnostics)
	if (js_cst_is(node, c"object_literal")): return js_object_pattern(node, strict, diagnostics)
	return 0


# Cover-initialized shorthand is valid only inside an assignment pattern,
# never in an ordinary object initializer or a computed property expression.
int js_in_assignment_pattern(pg_ast_node* node):
	pg_ast_node* parent = node.parent
	while (parent != 0):
		if (js_cst_is(parent, c"initializer") || js_cst_is(parent, c"property_name") || js_is_function(parent)): return 0
		if (js_cst_is(parent, c"assignment") && parent.children.length == 2):
			pg_ast_node* tail = parent.children[1]
			if (js_cst_is(tail, c"assignment_tail")):
				return parent.children[0] == node && strcmp(tail.first_token.text, c"=") == 0
		if (js_cst_is(parent, c"for_binding")): return js_cst_child(parent, c"variable_kind") == 0
		node = parent
		parent = parent.parent
	return 0


struct js_restriction_context:
	int strict
	int async_function
	int super_property
	int super_call


int js_method_super_call(pg_ast_node* node, pg_diagnostics* diagnostics):
	pg_ast_node* element = node.parent
	if (js_cst_is(element, c"class_element") == 0 || js_cst_child(element, c"KW_STATIC") != 0): return 0
	pg_ast_node* tail = element.parent
	if (js_cst_is(tail, c"class_tail") == 0 || js_cst_child(tail, c"extends_clause") == 0): return 0
	char* name = js_binding_property_name(node, diagnostics)
	if (name == 0): return 0
	int constructor = strcmp(name, c"constructor") == 0
	free(name)
	return constructor


void js_validate_super(pg_ast_node* node, js_restriction_context* context, pg_diagnostics* diagnostics):
	pg_ast_node* primary = node.parent
	pg_ast_node* access = primary.parent
	int valid = 0
	if ((js_cst_is(access, c"postfix") || js_cst_is(access, c"new_callee")) && access.children.length > 1):
		pg_ast_node* tail = access.children[1]
		if (js_cst_child(tail, c"DOT") != 0 || js_cst_child(tail, c"LBRACKET") != 0): valid = context.super_property
		if (js_cst_is(access, c"postfix") && js_cst_child(tail, c"arguments") != 0): valid = context.super_call
	if (valid == 0): js_validation_error(diagnostics, node, c"invalid super access or call context")


void js_validate_for_header(pg_ast_node* node, js_restriction_context* context, pg_diagnostics* diagnostics):
	pg_ast_node* header = js_cst_child(node, c"for_header")
	pg_ast_node* operator = js_cst_child(header, c"for_in_of")
	int awaiting = js_cst_child(node, c"KW_AWAIT") != 0
	if (awaiting):
		if (context.async_function == 0 || operator == 0 || strcmp(operator.first_token.text, c"of") != 0):
			js_validation_error(diagnostics, node, c"for await requires async function and of clause")
	pg_ast_node* binding = js_cst_child(header, c"for_binding")
	if (binding != 0 && js_cst_child(binding, c"variable_kind") == 0):
		pg_ast_node* target = binding.children[0]
		if (js_pattern_target(target, 0, context.strict, diagnostics) == 0): js_validation_error(diagnostics, binding, c"invalid for-in/of assignment target")
		pg_ast_node* simple = js_cst_unwrap(target)
		if (operator != 0 && strcmp(operator.first_token.text, c"of") == 0 && simple.token != 0):
			if (strcmp(simple.text, c"let") == 0 || (awaiting == 0 && strcmp(simple.text, c"async") == 0)):
				js_validation_error(diagnostics, binding, c"ambiguous for-of binding")


void js_validate_label(pg_ast_node* node, pg_diagnostics* diagnostics):
	char* name = js_identifier_decode(node.first_token.text)
	pg_ast_node* parent = node.parent
	while (parent != 0 && js_is_function(parent) == 0):
		if (js_cst_is(parent, c"labelled_statement")):
			char* other = js_identifier_decode(parent.first_token.text)
			if (strcmp(name, other) == 0): js_validation_error(diagnostics, node, c"duplicate enclosing label")
			free(other)
		parent = parent.parent
	free(name)


void js_validate_declaration_position(pg_ast_node* node, int strict, pg_diagnostics* diagnostics):
	int declaration = js_cst_is(node, c"class_decl") || js_cst_is(node, c"function_decl")
	if (js_cst_is(node, c"variable_statement")):
		declaration = strcmp(node.first_token.text, c"var") != 0
	if (declaration == 0 || js_cst_is(node.parent, c"statement") == 0): return
	pg_ast_node* owner = node.parent.parent
	if (js_cst_is(owner, c"program") || js_cst_is(owner, c"block") || js_cst_is(owner, c"switch_clause")): return
	# Annex B's plain sloppy function declaration exceptions are narrow.
	if (strict == 0 && js_cst_is(node, c"function_decl") && js_cst_child(node, c"async_modifier") == 0 && js_cst_child(node, c"STAR") == 0):
		if (js_cst_is(owner, c"if_statement") || js_cst_is(owner, c"else_clause") || js_cst_is(owner, c"labelled_statement")): return
	js_validation_error(diagnostics, node, c"declaration requires a statement-list context")


void js_restriction_walk(pg_ast_node* node, js_restriction_context* context, pg_diagnostics* diagnostics):
	if (node == 0): return
	js_restriction_context here = *context
	js_validate_declaration_position(node, here.strict, diagnostics)
	if (js_is_function(node)):
		here.async_function = js_cst_child(node, c"async_modifier") != 0
		if (js_cst_is(node, c"arrow_function") == 0):
			here.super_property = js_cst_is(node, c"method")
			here.super_call = 0
			if (here.super_property): here.super_call = js_method_super_call(node, diagnostics)
		if (js_directive_strict(js_binding_function_body(node))): here.strict = 1
	if (js_cst_is(node, c"class_decl") || js_cst_is(node, c"class_expr")): here.strict = 1
	if (js_cst_is(node, c"program") && js_directive_strict(node)): here.strict = 1
	if (js_cst_is(node, c"KW_SUPER") && js_cst_is(node.parent, c"primary")): js_validate_super(node, &here, diagnostics)
	if (js_cst_is(node, c"for_statement")): js_validate_for_header(node, &here, diagnostics)
	if (js_cst_is(node, c"labelled_statement")): js_validate_label(node, diagnostics)
	if (js_cst_is(node, c"switch_statement")):
		int defaults = 0
		for pg_ast_node* child in node.children:
			if (js_cst_is(child, c"switch_clause") && strcmp(child.first_token.text, c"default") == 0): defaults = defaults + 1
		if (defaults > 1): js_validation_error(diagnostics, node, c"duplicate switch default clause")
	if (js_cst_is(node, c"assignment") && node.children.length == 2):
		pg_ast_node* tail = node.children[1]
		if (js_cst_is(tail, c"assignment_tail")):
			int plain = strcmp(tail.first_token.text, c"=") == 0
			int valid = js_simple_target(node.children[0]) && js_restricted_target(node.children[0], here.strict) == 0
			if (plain): valid = js_pattern_target(node.children[0], 0, here.strict, diagnostics)
			if (valid == 0): js_validation_error(diagnostics, node, c"invalid assignment pattern")
	if (js_cst_is(node, c"object_property") && js_cst_child(node, c"initializer") != 0 && js_in_assignment_pattern(node) == 0):
		js_validation_error(diagnostics, node, c"initialized shorthand outside assignment pattern")
	if (js_cst_is(node, c"update") && node.children.length == 2 && js_restricted_target(node.children[0], here.strict)):
		js_validation_error(diagnostics, node, c"restricted strict-mode update target")
	if (js_cst_is(node, c"unary") && node.children.length == 2):
		pg_ast_node* op = js_cst_unwrap(node.children[0])
		if ((js_cst_is(op, c"INC") || js_cst_is(op, c"DEC")) && js_restricted_target(node.children[1], here.strict)):
			js_validation_error(diagnostics, node, c"restricted strict-mode update target")
		if (js_cst_is(op, c"KW_DELETE") && here.strict):
			pg_ast_node* target = js_restriction_unwrap_target(node.children[1])
			if (target.token != 0 && js_simple_target(target)): js_validation_error(diagnostics, node, c"delete of unqualified identifier in strict code")
	for pg_ast_node* child in node.children: js_restriction_walk(child, &here, diagnostics)


void js_validate_restrictions(pg_parse_result* result, int module):
	if (result.success == 0): return
	js_restriction_context context
	context.strict = module
	context.async_function = 0
	context.super_property = 0
	context.super_call = 0
	js_restriction_walk(result.root, &context, result.diagnostics)
	if (pg_diagnostics_count(result.diagnostics) != 0): result.success = 0
