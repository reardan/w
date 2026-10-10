/*
Convert generated JavaScript CST nodes to the supported owned AST facade.
Unsupported syntax is diagnosed explicitly; parsing supports more syntax
than the initial builder/printer facade. Returned nodes own all children.
*/
import libs.extras.javascript.ast
import libs.extras.javascript.validation
import libs.extras.javascript.strings


js_node* js_lower_node(pg_ast_node* node, pg_diagnostics* diagnostics);


js_node* js_lower_error(pg_ast_node* node, pg_diagnostics* diagnostics):
	pg_token* token = node.first_token
	char* filename = c"<JavaScript AST>"
	int line = 1
	int column = 1
	if (token != 0):
		filename = token.filename
		line = token.line
		column = token.column
	pg_diagnostics_add(diagnostics, filename, line, column, c"JavaScript syntax is not supported by the AST facade", c"supported semantic node", node.name)
	return 0


int js_lower_add(js_node* parent, pg_ast_node* child, pg_diagnostics* diagnostics):
	js_node* lowered = js_lower_node(child, diagnostics)
	if (lowered == 0): return 0
	js_node_add(parent, lowered)
	return 1


js_node* js_lower_identifier(pg_ast_node* node):
	char* name = js_identifier_decode(node.first_token.text)
	js_node* result = js_identifier(name)
	result.offset = node.first_token.offset
	result.length = node.last_token.offset + node.last_token.length - result.offset
	free(name)
	return result


# Every binary tail has operator then RHS, regardless of operator tier.
js_node* js_lower_binary(pg_ast_node* node, pg_diagnostics* diagnostics):
	js_node* left = js_lower_node(node.children[0], diagnostics)
	if (left == 0): return 0
	for i in range(1, node.children.length):
		pg_ast_node* tail = node.children[i]
		if (tail.children.length != 2):
			js_node_free(left)
			return js_lower_error(tail, diagnostics)
		js_node* right = js_lower_node(tail.children[1], diagnostics)
		if (right == 0):
			js_node_free(left)
			return 0
		js_node* binary = js_binary(tail.children[0].first_token.text, left, right)
		binary.offset = left.offset
		binary.length = right.offset + right.length - left.offset
		if (js_cst_is(tail, c"assignment_tail")):
			free(binary.kind)
			binary.kind = strclone(c"assignment")
		left = binary
	return left


int js_lower_arguments(js_node* call, pg_ast_node* arguments, pg_diagnostics* diagnostics):
	pg_ast_node* list = js_cst_child(arguments, c"argument_list")
	if (list == 0): return 1
	for i in range(list.children.length):
		pg_ast_node* argument = list.children[i]
		if (argument.token != 0): continue
		if (js_cst_is(argument, c"argument_tail")): argument = argument.children[1]
		if (js_lower_add(call, argument, diagnostics) == 0): return 0
	return 1


js_node* js_lower_postfix(pg_ast_node* node, pg_diagnostics* diagnostics):
	js_node* value = js_lower_node(node.children[0], diagnostics)
	if (value == 0): return 0
	for i in range(1, node.children.length):
		pg_ast_node* tail = node.children[i]
		pg_ast_node* first = tail.children[0]
		js_node* next = 0
		if (js_cst_is(first, c"arguments")):
			next = js_call(value)
			if (js_lower_arguments(next, first, diagnostics) == 0):
				js_node_free(next)
				return 0
		else if (js_cst_is(first, c"DOT") || js_cst_is(first, c"LBRACKET")):
			char* kind = c"member"
			if (js_cst_is(first, c"LBRACKET")): kind = c"computed_member"
			next = js_node_new(kind, c"")
			js_node_add(next, value)
			if (js_lower_add(next, tail.children[1], diagnostics) == 0):
				js_node_free(next)
				return 0
		else:
			js_node_free(value)
			return js_lower_error(tail, diagnostics)
		next.offset = value.offset
		next.length = tail.last_token.offset + tail.last_token.length - next.offset
		value = next
	return value


js_node* js_lower_parameters(pg_ast_node* node, pg_diagnostics* diagnostics):
	js_node* result = js_node_new(c"parameters", c"")
	pg_ast_node* list = js_cst_child(node, c"parameter_list")
	if (list == 0): return result
	for i in range(list.children.length):
		pg_ast_node* parameter = list.children[i]
		if (parameter.token != 0): continue
		if (js_cst_is(parameter, c"parameter_tail")): parameter = parameter.children[1]
		if (js_cst_is(parameter, c"parameter") == 0 || parameter.children.length != 1):
			js_node_free(result)
			return js_lower_error(parameter, diagnostics)
		if (js_lower_add(result, parameter.children[0], diagnostics) == 0):
			js_node_free(result)
			return 0
	return result


js_node* js_lower_object_property(pg_ast_node* node, pg_diagnostics* diagnostics):
	pg_ast_node* first = node.children[0]
	char* key = 0
	if (js_cst_is(first, c"binding_identifier")): key = js_identifier_decode(first.first_token.text)
	else if (js_cst_is(first, c"property_name") && first.children.length == 1):
		pg_ast_node* name = first.children[0]
		if (js_cst_is(name, c"STRING")): key = js_string_decode(name.token.text, diagnostics)
		else if (js_cst_is(name, c"identifier_name")): key = js_identifier_decode(name.first_token.text)
	if (key == 0): return js_lower_error(node, diagnostics)
	js_node* result = js_node_new(c"property", key)
	free(key)
	if (node.children.length == 1):
		free(result.kind)
		result.kind = strclone(c"property_shorthand")
	else:
		if (js_lower_add(result, node.children[2], diagnostics) == 0):
			js_node_free(result)
			return 0
	return result


js_node* js_lower_impl(pg_ast_node* node, pg_diagnostics* diagnostics):
	int count = node.children.length
	if (node.token != 0):
		if (js_cst_is(node, c"NUMBER")): return js_number(node.text)
		if (js_cst_is(node, c"REGEX")): return js_node_new(c"regex", node.text)
		if (js_cst_is(node, c"TEMPLATE_TEXT")): return js_node_new(c"template_text", node.text)
		if (js_cst_is(node, c"STRING")):
			js_text* units = js_text_decode(node.text, strlen(node.text))
			if (units == 0): return js_lower_error(node, diagnostics)
			int byte_length = 0
			char* text = js_text_to_utf8(units, &byte_length)
			if (text == 0 || strlen(text) != byte_length):
				js_node* special = js_string_utf16(units)
				js_text_free(units)
				free(text)
				return special
			js_text_free(units)
			js_node* result = js_string(text)
			# An escaped spelling of use strict must not become a directive.
			if (strcmp(text, c"use strict") == 0):
				for i in range(strlen(node.text)):
					if (node.text[i] == 92):
						free(result.kind)
						result.kind = strclone(c"string_non_directive")
						break
			free(text)
			return result
		if (js_cst_is(node, c"KW_TRUE") || js_cst_is(node, c"KW_FALSE") || js_cst_is(node, c"KW_NULL") || js_cst_is(node, c"KW_THIS")): return js_node_new(c"literal", node.text)
		return js_lower_error(node, diagnostics)
	if (js_cst_is(node, c"identifier_reference") || js_cst_is(node, c"identifier_name") || js_cst_is(node, c"binding_identifier")): return js_lower_identifier(node)
	if (js_cst_is(node, c"statement") || js_cst_is(node, c"binding_pattern") || js_cst_is(node, c"return_value")):
		if (count == 1): return js_lower_node(node.children[0], diagnostics)
	if (js_cst_is(node, c"primary")):
		if (count == 1): return js_lower_node(node.children[0], diagnostics)
		if (count == 3 && js_cst_is(node.children[0], c"LPAREN")): return js_lower_node(node.children[1], diagnostics)
	if (js_cst_is(node, c"short_circuit") || js_cst_is(node, c"expression") || js_cst_is(node, c"assignment") || js_cst_is(node, c"coalesce") || js_cst_is(node, c"logical_or") || js_cst_is(node, c"logical_and") || js_cst_is(node, c"bitor") || js_cst_is(node, c"bitxor") || js_cst_is(node, c"bitand") || js_cst_is(node, c"equality") || js_cst_is(node, c"relational") || js_cst_is(node, c"shift") || js_cst_is(node, c"additive") || js_cst_is(node, c"multiplicative") || js_cst_is(node, c"power")): return js_lower_binary(node, diagnostics)
	if (js_cst_is(node, c"conditional")):
		if (count == 1): return js_lower_node(node.children[0], diagnostics)
		js_node* result = js_node_new(c"conditional", c"")
		pg_ast_node* tail = node.children[1]
		if (js_lower_add(result, node.children[0], diagnostics) == 0 || js_lower_add(result, tail.children[1], diagnostics) == 0 || js_lower_add(result, tail.children[3], diagnostics) == 0):
			js_node_free(result)
			return 0
		return result
	if (js_cst_is(node, c"unary")):
		if (count == 1): return js_lower_node(node.children[0], diagnostics)
		pg_ast_node* op = node.children[0]
		if (js_cst_is(op, c"KW_AWAIT")): return js_lower_error(node, diagnostics)
		char* kind = c"unary"
		if (strcmp(op.first_token.text, c"++") == 0 || strcmp(op.first_token.text, c"--") == 0): kind = c"update_prefix"
		js_node* result = js_node_new(kind, op.first_token.text)
		if (js_lower_add(result, node.children[1], diagnostics) == 0):
			js_node_free(result)
			return 0
		return result
	if (js_cst_is(node, c"update")):
		if (count == 1): return js_lower_node(node.children[0], diagnostics)
		js_node* result = js_node_new(c"update_postfix", node.children[1].first_token.text)
		if (js_lower_add(result, node.children[0], diagnostics) == 0):
			js_node_free(result)
			return 0
		return result
	if (js_cst_is(node, c"postfix")): return js_lower_postfix(node, diagnostics)
	if (js_cst_is(node, c"argument")):
		if (count == 1): return js_lower_node(node.children[0], diagnostics)
		return js_lower_error(node, diagnostics)
	if (js_cst_is(node, c"program") || js_cst_is(node, c"block")):
		js_node* result = js_node_new(node.name, c"")
		for i in range(count):
			if (node.children[i].token != 0): continue
			if (js_lower_add(result, node.children[i], diagnostics) == 0):
				js_node_free(result)
				return 0
		return result
	if (js_cst_is(node, c"empty_statement")): return js_node_new(c"empty", c"")
	if (js_cst_is(node, c"expression_statement") || js_cst_is(node, c"return_statement") || js_cst_is(node, c"throw_statement")):
		char* kind = c"expression_statement"
		if (js_cst_is(node, c"return_statement")): kind = c"return"
		if (js_cst_is(node, c"throw_statement")): kind = c"throw"
		js_node* result = js_node_new(kind, c"")
		for i in range(count):
			pg_ast_node* child = node.children[i]
			if (child.token != 0 || js_cst_is(child, c"eos")): continue
			if (js_lower_add(result, child, diagnostics) == 0):
				js_node_free(result)
				return 0
		return result
	if (js_cst_is(node, c"variable_statement")): return js_lower_node(node.children[0], diagnostics)
	if (js_cst_is(node, c"variable_declarations")):
		js_node* result = js_node_new(c"variable", node.children[0].first_token.text)
		for i in range(1, count):
			pg_ast_node* declarator = node.children[i]
			if (js_cst_is(declarator, c"variable_declarator_tail")): declarator = declarator.children[1]
			if (js_lower_add(result, declarator, diagnostics) == 0):
				js_node_free(result)
				return 0
		return result
	if (js_cst_is(node, c"variable_declarator")):
		js_node* result = js_node_new(c"declarator", c"")
		if (js_lower_add(result, node.children[0], diagnostics) == 0):
			js_node_free(result)
			return 0
		if (count == 2):
			if (js_lower_add(result, node.children[1].children[1], diagnostics) == 0):
				js_node_free(result)
				return 0
		return result
	if (js_cst_is(node, c"parameters")): return js_lower_parameters(node, diagnostics)
	if (js_cst_is(node, c"function_decl") || js_cst_is(node, c"function_expr")):
		if (js_cst_child(node, c"async_modifier") != 0 || js_cst_child(node, c"STAR") != 0): return js_lower_error(node, diagnostics)
		pg_ast_node* binding = js_cst_child(node, c"binding_identifier")
		char* name = strclone(c"")
		if (binding != 0):
			free(name)
			name = js_identifier_decode(binding.first_token.text)
		char* kind = c"function"
		if (js_cst_is(node, c"function_expr")): kind = c"function_expression"
		js_node* result = js_node_new(kind, name)
		free(name)
		if (js_lower_add(result, js_cst_child(node, c"parameters"), diagnostics) == 0 || js_lower_add(result, js_cst_child(node, c"block"), diagnostics) == 0):
			js_node_free(result)
			return 0
		return result
	if (js_cst_is(node, c"try_statement")):
		js_node* result = js_node_new(c"try", c"")
		if (js_lower_add(result, node.children[1], diagnostics) == 0):
			js_node_free(result)
			return 0
		pg_ast_node* handler = js_cst_child(node, c"catch_clause")
		pg_ast_node* finalizer = js_cst_child(node, c"finally_clause")
		if (handler == 0): js_node_add(result, js_node_new(c"empty", c""))
		else if (js_lower_add(result, handler, diagnostics) == 0):
			js_node_free(result)
			return 0
		if (finalizer == 0): js_node_add(result, js_node_new(c"empty", c""))
		else if (js_lower_add(result, finalizer.children[1], diagnostics) == 0):
			js_node_free(result)
			return 0
		return result
	if (js_cst_is(node, c"catch_clause")):
		char* name = strclone(c"")
		pg_ast_node* binding = js_cst_child(node, c"catch_binding")
		if (binding != 0):
			pg_ast_node* pattern = binding.children[1]
			if (pattern.children.length != 1 || js_cst_is(pattern.children[0], c"binding_identifier") == 0):
				free(name)
				return js_lower_error(node, diagnostics)
			free(name)
			name = js_identifier_decode(pattern.first_token.text)
		js_node* result = js_node_new(c"catch", name)
		free(name)
		if (js_lower_add(result, js_cst_child(node, c"block"), diagnostics) == 0):
			js_node_free(result)
			return 0
		return result
	if (js_cst_is(node, c"break_statement") || js_cst_is(node, c"continue_statement")):
		if (js_cst_child(node, c"jump_label") != 0): return js_lower_error(node, diagnostics)
		char* kind = c"break"
		if (js_cst_is(node, c"continue_statement")): kind = c"continue"
		return js_node_new(kind, c"")
	if (js_cst_is(node, c"while_statement") || js_cst_is(node, c"do_statement")):
		char* kind = c"while"
		int condition = 2
		int body = 4
		if (js_cst_is(node, c"do_statement")):
			kind = c"do_while"
			condition = 4
			body = 1
		js_node* result = js_node_new(kind, c"")
		if (js_lower_add(result, node.children[condition], diagnostics) == 0 || js_lower_add(result, node.children[body], diagnostics) == 0):
			js_node_free(result)
			return 0
		return result
	if (js_cst_is(node, c"for_statement")):
		pg_ast_node* header = js_cst_child(node, c"for_header")
		if (js_cst_child(node, c"KW_AWAIT") != 0 || js_cst_child(header, c"for_binding") != 0): return js_lower_error(node, diagnostics)
		js_node* result = js_node_new(c"for", c"")
		for i in range(3): js_node_add(result, js_node_new(c"empty", c""))
		int slot = 0
		for i in range(header.children.length):
			pg_ast_node* part = header.children[i]
			if (js_cst_is(part, c"SEMI")):
				slot = slot + 1
				continue
			if (js_cst_is(part, c"for_init")): part = part.children[0]
			js_node* lowered = js_lower_node(part, diagnostics)
			if (lowered == 0):
				js_node_free(result)
				return 0
			js_node_free(js_node_replace(result, slot, lowered))
		if (js_lower_add(result, node.children[count - 1], diagnostics) == 0):
			js_node_free(result)
			return 0
		return result
	if (js_cst_is(node, c"if_statement")):
		js_node* result = js_node_new(c"if", c"")
		if (js_lower_add(result, node.children[2], diagnostics) == 0 || js_lower_add(result, node.children[4], diagnostics) == 0):
			js_node_free(result)
			return 0
		if (count == 6):
			if (js_lower_add(result, node.children[5].children[1], diagnostics) == 0):
				js_node_free(result)
				return 0
		return result
	if (js_cst_is(node, c"export_statement")):
		if (count != 2 || (js_cst_is(node.children[1], c"variable_statement") == 0 && js_cst_is(node.children[1], c"function_decl") == 0)): return js_lower_error(node, diagnostics)
		js_node* result = js_node_new(c"export", c"")
		if (js_lower_add(result, node.children[1], diagnostics) == 0):
			js_node_free(result)
			return 0
		return result
	if (js_cst_is(node, c"import_statement")):
		pg_ast_node* specifier = js_cst_child(node, c"STRING")
		char* text = js_string_decode(specifier.text, diagnostics)
		if (text == 0): return 0
		js_node* result = js_node_new(c"import", text)
		free(text)
		pg_ast_node* clause = js_cst_child(node, c"import_clause")
		if (clause != 0):
			if (clause.children.length != 1 || js_cst_is(clause.children[0], c"binding_identifier") == 0):
				js_node_free(result)
				return js_lower_error(node, diagnostics)
			js_node_add(result, js_lower_identifier(clause.children[0]))
		return result
	if (js_cst_is(node, c"template")):
		js_node* result = js_node_new(c"template", c"")
		for i in range(count):
			pg_ast_node* part = node.children[i]
			if (part.token != 0): continue
			if (js_cst_is(part.children[0], c"TEMPLATE_TEXT")):
				if (js_lower_add(result, part.children[0], diagnostics) == 0):
					js_node_free(result)
					return 0
			else:
				if (js_lower_add(result, part.children[1], diagnostics) == 0):
					js_node_free(result)
					return 0
		return result
	if (js_cst_is(node, c"object_property")): return js_lower_object_property(node, diagnostics)
	if (js_cst_is(node, c"object_literal")):
		js_node* result = js_node_new(c"object", c"")
		pg_ast_node* properties = js_cst_child(node, c"object_properties")
		if (properties == 0): return result
		for i in range(properties.children.length):
			pg_ast_node* property = properties.children[i]
			if (property.token != 0): continue
			if (js_cst_is(property, c"object_property_tail")): property = property.children[1]
			if (js_lower_add(result, property, diagnostics) == 0):
				js_node_free(result)
				return 0
		return result
	if (js_cst_is(node, c"array_literal")):
		js_node* result = js_node_new(c"array", c"")
		for i in range(1, count - 1):
			pg_ast_node* element = node.children[i]
			if (js_cst_is(element, c"array_tail")): element = element.children[1]
			if (element.children.length == 0):
				if (i == count - 2): continue
				js_node_free(result)
				return js_lower_error(node, diagnostics)
			if (js_lower_add(result, element.children[0], diagnostics) == 0):
				js_node_free(result)
				return 0
		return result
	return js_lower_error(node, diagnostics)


js_node* js_lower_node(pg_ast_node* node, pg_diagnostics* diagnostics):
	js_node* result = js_lower_impl(node, diagnostics)
	if (result != 0 && node.first_token != 0):
		result.offset = node.first_token.offset
		result.length = node.last_token.offset + node.last_token.length - result.offset
	return result


# Lowering failure adds a diagnostic to the owned result. The result still
# owns the CST; caller separately owns and frees the returned semantic AST.
js_node* js_lower(pg_parse_result* result):
	if (result.success == 0 || result.root == 0): return 0
	js_node* node = js_lower_node(result.root, result.diagnostics)
	if (node == 0): result.success = 0
	return node
