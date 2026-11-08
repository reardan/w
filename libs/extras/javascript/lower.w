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


js_node* js_lower_postfix_tails(pg_ast_node* node, js_node* value, int start, pg_diagnostics* diagnostics):
	int optional = 0
	for i in range(start, node.children.length):
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
		else if (js_cst_is(first, c"OPTIONAL")):
			optional = 1
			pg_ast_node* part = tail.children[1]
			if (js_cst_is(part, c"arguments")):
				next = js_node_new(c"optional_call", c"")
				js_node_add(next, value)
				if (js_lower_arguments(next, part, diagnostics) == 0):
					js_node_free(next)
					return 0
			else:
				char* kind = c"optional_member"
				int index = 1
				if (js_cst_is(part, c"LBRACKET")):
					kind = c"optional_computed_member"
					index = 2
				next = js_node_new(kind, c"")
				js_node_add(next, value)
				if (js_lower_add(next, tail.children[index], diagnostics) == 0):
					js_node_free(next)
					return 0
		else if (js_cst_is(first, c"template")):
			next = js_node_new(c"tagged_template", c"")
			js_node_add(next, value)
			if (js_lower_add(next, first, diagnostics) == 0):
				js_node_free(next)
				return 0
		else:
			js_node_free(value)
			return js_lower_error(tail, diagnostics)
		next.offset = value.offset
		next.length = tail.last_token.offset + tail.last_token.length - next.offset
		value = next
	if (optional):
		js_node* chain = js_node_new(c"optional_chain", c"")
		js_node_add(chain, value)
		return chain
	return value


js_node* js_lower_postfix(pg_ast_node* node, pg_diagnostics* diagnostics):
	js_node* value = js_lower_node(node.children[0], diagnostics)
	if (value == 0): return 0
	return js_lower_postfix_tails(node, value, 1, diagnostics)


js_node* js_lower_parameters(pg_ast_node* node, pg_diagnostics* diagnostics):
	js_node* result = js_node_new(c"parameters", c"")
	pg_ast_node* list = js_cst_child(node, c"parameter_list")
	if (list == 0): return result
	for i in range(list.children.length):
		pg_ast_node* parameter = list.children[i]
		if (parameter.token != 0): continue
		if (js_cst_is(parameter, c"parameter_tail")): parameter = parameter.children[1]
		if (js_cst_is(parameter, c"parameter") == 0 && js_cst_is(parameter, c"rest_parameter") == 0):
			js_node_free(result)
			return js_lower_error(parameter, diagnostics)
		if (js_lower_add(result, parameter, diagnostics) == 0):
			js_node_free(result)
			return 0
	return result


# Function kinds encode async/generator and declaration/expression forms.
char* js_lower_function_kind(int is_async, int generator, int expression):
	if (is_async && generator):
		if (expression): return c"async_generator_function_expression"
		return c"async_generator_function"
	if (is_async):
		if (expression): return c"async_function_expression"
		return c"async_function"
	if (generator):
		if (expression): return c"generator_function_expression"
		return c"generator_function"
	if (expression): return c"function_expression"
	return c"function"


void js_lower_rename(js_node* node, char* kind):
	free(node.kind)
	node.kind = strclone(kind)


# Decodes a literal property name to char* text, or returns 0 without a
# diagnostic when the value needs UTF-16 storage (embedded NUL, lone surrogate).
char* js_lower_key_text(pg_ast_node* name):
	if (js_cst_is(name, c"identifier_name") || js_cst_is(name, c"binding_identifier")): return js_identifier_decode(name.first_token.text)
	if (js_cst_is(name, c"STRING") == 0): return 0
	js_text* units = js_text_decode(name.text, strlen(name.text))
	if (units == 0): return 0
	int length = 0
	char* text = js_text_to_utf8(units, &length)
	js_text_free(units)
	if (text != 0 && strlen(text) == length): return text
	free(text)
	return 0


# property_name = identifier_name | STRING | NUMBER | [ assignment ].
# Literal names give property_key(name); computed names, numeric names and
# names that need UTF-16 storage give computed_key(expression).
js_node* js_lower_property_key(pg_ast_node* name, pg_diagnostics* diagnostics):
	if (name.children.length == 3):
		js_node* computed = js_node_new(c"computed_key", c"")
		if (js_lower_add(computed, name.children[1], diagnostics)): return computed
		js_node_free(computed)
		return 0
	pg_ast_node* literal = name.children[0]
	char* key = js_lower_key_text(literal)
	if (key != 0):
		js_node* result = js_node_new(c"property_key", key)
		free(key)
		return result
	js_node* computed = js_node_new(c"computed_key", c"")
	if (js_lower_add(computed, literal, diagnostics)): return computed
	js_node_free(computed)
	return 0


# Builds an unnamed function expression from a method's parameters and block.
js_node* js_lower_method_function(pg_ast_node* method, pg_diagnostics* diagnostics):
	int is_async = js_cst_child(method, c"async_modifier") != 0
	int generator = js_cst_child(method, c"STAR") != 0
	js_node* routine = js_node_new(js_lower_function_kind(is_async, generator, 1), c"")
	pg_ast_node* parameters = js_cst_child(method, c"parameters")
	if (parameters != 0):
		if (js_lower_add(routine, parameters, diagnostics) == 0):
			js_node_free(routine)
			return 0
	else:
		js_node* list = js_node_new(c"parameters", c"")
		js_node_add(routine, list)
		pg_ast_node* parameter = js_cst_child(method, c"parameter")
		if (parameter != 0 && js_lower_add(list, parameter, diagnostics) == 0):
			js_node_free(routine)
			return 0
	if (js_lower_add(routine, js_cst_child(method, c"block"), diagnostics) == 0):
		js_node_free(routine)
		return 0
	routine.offset = method.first_token.offset
	routine.length = method.last_token.offset + method.last_token.length - routine.offset
	return routine


# method(get|set|method) = key, function; static class methods use
# static_method. The key is property_key or computed_key.
js_node* js_lower_method(pg_ast_node* method, char* kind, pg_diagnostics* diagnostics):
	char* text = c"method"
	if (js_cst_is(method.children[0], c"KW_GET")): text = c"get"
	if (js_cst_is(method.children[0], c"KW_SET")): text = c"set"
	js_node* result = js_node_new(kind, text)
	js_node* key = js_lower_property_key(js_cst_child(method, c"property_name"), diagnostics)
	if (key == 0):
		js_node_free(result)
		return 0
	js_node_add(result, key)
	js_node* routine = js_lower_method_function(method, diagnostics)
	if (routine == 0):
		js_node_free(result)
		return 0
	js_node_add(result, routine)
	return result


js_node* js_lower_object_property(pg_ast_node* node, pg_diagnostics* diagnostics):
	pg_ast_node* first = node.children[0]
	if (js_cst_is(first, c"ELLIPSIS")):
		js_node* spread = js_node_new(c"spread", c"")
		if (js_lower_add(spread, node.children[1], diagnostics)): return spread
		js_node_free(spread)
		return 0
	if (js_cst_is(first, c"method")):
		js_node* method = js_lower_method(first, c"method", diagnostics)
		if (method == 0): return 0
		# Ordinary methods keep the original property + function_expression
		# shape, which the runtime executes; accessors and async/generator
		# methods use method nodes.
		if (strcmp(method.text, c"method") != 0 || js_kind(method.children[1], c"function_expression") == 0): return method
		js_node* key = method.children[0]
		js_node* routine = method.children[1]
		js_node* property = 0
		if (js_kind(key, c"property_key")):
			property = js_node_new(c"property", key.text)
			js_node_free(key)
		else:
			property = js_node_new(c"computed_property", c"")
			js_node_add(property, key.children[0])
			key.children.clear()
			js_node_free(key)
		js_node_add(property, routine)
		method.children.clear()
		js_node_free(method)
		return property
	if (js_cst_is(first, c"binding_identifier")):
		char* name = js_identifier_decode(first.first_token.text)
		js_node* shorthand = js_node_new(c"property_shorthand", name)
		free(name)
		# A CoverInitializedName ({x = 1}) is only valid in assignment patterns.
		if (node.children.length == 2 && js_lower_add(shorthand, node.children[1].children[1], diagnostics) == 0):
			js_node_free(shorthand)
			return 0
		return shorthand
	js_node* key = js_lower_property_key(first, diagnostics)
	if (key == 0): return 0
	js_node* result = 0
	if (js_kind(key, c"property_key")):
		result = js_node_new(c"property", key.text)
		js_node_free(key)
	else:
		result = js_node_new(c"computed_property", c"")
		js_node_add(result, key.children[0])
		key.children.clear()
		js_node_free(key)
	if (js_lower_add(result, node.children[2], diagnostics) == 0):
		js_node_free(result)
		return 0
	return result


# class(name) / class_expression(optional name) = heritage-or-empty, methods.
js_node* js_lower_class(pg_ast_node* node, pg_diagnostics* diagnostics):
	char* kind = c"class"
	if (js_cst_is(node, c"class_expr")): kind = c"class_expression"
	pg_ast_node* binding = js_cst_child(node, c"binding_identifier")
	js_node* result = js_node_new(kind, c"")
	if (binding != 0):
		free(result.text)
		result.text = js_identifier_decode(binding.first_token.text)
	pg_ast_node* tail = js_cst_child(node, c"class_tail")
	pg_ast_node* heritage = js_cst_child(tail, c"extends_clause")
	if (heritage == 0): js_node_add(result, js_node_new(c"empty", c""))
	else if (js_lower_add(result, heritage.children[1], diagnostics) == 0):
		js_node_free(result)
		return 0
	for i in range(tail.children.length):
		pg_ast_node* element = tail.children[i]
		if (js_cst_is(element, c"class_element") == 0 || js_cst_is(element.children[0], c"SEMI")): continue
		char* method_kind = c"method"
		pg_ast_node* method = element.children[0]
		if (js_cst_is(method, c"KW_STATIC")):
			method_kind = c"static_method"
			method = element.children[1]
		js_node* lowered = js_lower_method(method, method_kind, diagnostics)
		if (lowered == 0):
			js_node_free(result)
			return 0
		lowered.offset = element.first_token.offset
		lowered.length = element.last_token.offset + element.last_token.length - lowered.offset
		js_node_add(result, lowered)
	return result


# import(specifier) = [identifier default] [import_namespace | import_named].
js_node* js_lower_import(pg_ast_node* node, pg_diagnostics* diagnostics):
	pg_ast_node* specifier = js_cst_child(node, c"STRING")
	char* text = js_string_decode(specifier.text, diagnostics)
	if (text == 0): return 0
	js_node* result = js_node_new(c"import", text)
	free(text)
	pg_ast_node* clause = js_cst_child(node, c"import_clause")
	if (clause == 0): return result
	for i in range(clause.children.length):
		pg_ast_node* part = clause.children[i]
		if (js_cst_is(part, c"binding_identifier")): js_node_add(result, js_lower_identifier(part))
		else if (js_cst_is(part, c"import_namespace")):
			js_node* namespace = js_node_new(c"import_namespace", c"")
			js_node_add(namespace, js_lower_identifier(js_cst_child(part, c"binding_identifier")))
			js_node_add(result, namespace)
		else if (js_cst_is(part, c"import_named")):
			js_node* named = js_node_new(c"import_named", c"")
			js_node_add(result, named)
			pg_ast_node* list = js_cst_child(part, c"import_specifiers")
			if (list == 0): continue
			for j in range(list.children.length):
				pg_ast_node* item = list.children[j]
				if (item.token != 0): continue
				if (js_cst_is(item, c"import_specifier_tail")): item = item.children[1]
				char* imported = js_identifier_decode(item.first_token.text)
				js_node* entry = js_node_new(c"import_specifier", imported)
				free(imported)
				js_node_add(entry, js_lower_identifier(item.children[item.children.length - 1]))
				js_node_add(named, entry)
	return result


js_node* js_lower_export_specifier(pg_ast_node* item):
	char* local = js_identifier_decode(item.first_token.text)
	js_node* entry = js_node_new(c"export_specifier", local)
	free(local)
	char* exported = js_identifier_decode(item.children[item.children.length - 1].first_token.text)
	js_node_add(entry, js_node_new(c"property_key", exported))
	free(exported)
	return entry


# export = declaration; export_default = declaration (optional name) or
# expression; export_named = specifiers; export_from(specifier) = specifiers;
# export_all(specifier) = [property_key alias].
js_node* js_lower_export(pg_ast_node* node, pg_diagnostics* diagnostics):
	int count = node.children.length
	if (js_cst_is(node.children[1], c"KW_DEFAULT")):
		js_node* result = js_node_new(c"export_default", c"")
		pg_ast_node* value = node.children[2].children[0]
		js_node* lowered = js_lower_node(value, diagnostics)
		if (lowered == 0):
			js_node_free(result)
			return 0
		js_node_add(result, lowered)
		if (js_cst_is(value, c"class_expr")): js_lower_rename(lowered, c"class")
		else if (js_cst_is(value, c"function_expr")):
			int is_async = js_cst_child(value, c"async_modifier") != 0
			int generator = js_cst_child(value, c"STAR") != 0
			js_lower_rename(lowered, js_lower_function_kind(is_async, generator, 0))
		return result
	pg_ast_node* named = js_cst_child(node, c"export_named")
	pg_ast_node* all = js_cst_child(node, c"export_all")
	if (named != 0 || all != 0):
		js_node* result = 0
		pg_ast_node* from = js_cst_child(node, c"export_from")
		if (all != 0): from = all
		if (from == 0): result = js_node_new(c"export_named", c"")
		else:
			char* text = js_string_decode(js_cst_child(from, c"STRING").text, diagnostics)
			if (text == 0): return 0
			char* kind = c"export_from"
			if (all != 0): kind = c"export_all"
			result = js_node_new(kind, text)
			free(text)
		if (all != 0):
			pg_ast_node* alias = js_cst_child(all, c"export_alias")
			if (alias != 0):
				char* name = js_identifier_decode(alias.children[1].first_token.text)
				js_node_add(result, js_node_new(c"property_key", name))
				free(name)
			return result
		pg_ast_node* list = js_cst_child(named, c"export_specifiers")
		if (list == 0): return result
		for i in range(list.children.length):
			pg_ast_node* item = list.children[i]
			if (item.token != 0): continue
			if (js_cst_is(item, c"export_specifier_tail")): item = item.children[1]
			js_node_add(result, js_lower_export_specifier(item))
		return result
	if (count != 2): return js_lower_error(node, diagnostics)
	js_node* result = js_node_new(c"export", c"")
	if (js_lower_add(result, node.children[1], diagnostics) == 0):
		js_node_free(result)
		return 0
	return result


# for_in/for_of/for_await_of(var|let|const or empty) = binding pattern or
# assignment target, iterated expression, body.
js_node* js_lower_for_each(pg_ast_node* node, pg_ast_node* header, pg_ast_node* binding, pg_diagnostics* diagnostics):
	char* kind = c"for_of"
	if (strcmp(header.children[1].first_token.text, c"in") == 0): kind = c"for_in"
	if (js_cst_child(node, c"KW_AWAIT") != 0): kind = c"for_await_of"
	char* declaration = c""
	pg_ast_node* target = binding.children[0]
	if (binding.children.length >= 2):
		declaration = binding.children[0].first_token.text
		target = binding.children[1]
	js_node* result = js_node_new(kind, declaration)
	# Annex B.3.6 `for (var x = init in o)`: default_pattern(x, init).
	if (binding.children.length == 3):
		js_node* initialized = js_node_new(c"default_pattern", c"")
		js_node_add(result, initialized)
		if (js_lower_add(initialized, target, diagnostics) == 0 || js_lower_add(initialized, binding.children[2].children[1], diagnostics) == 0):
			js_node_free(result)
			return 0
	else if (js_lower_add(result, target, diagnostics) == 0):
		js_node_free(result)
		return 0
	if (js_lower_add(result, header.children[2], diagnostics) == 0 || js_lower_add(result, node.children[node.children.length - 1], diagnostics) == 0):
		js_node_free(result)
		return 0
	return result


# switch = discriminant, clauses; case = test, statements; default = statements.
js_node* js_lower_switch(pg_ast_node* node, pg_diagnostics* diagnostics):
	js_node* result = js_node_new(c"switch", c"")
	if (js_lower_add(result, node.children[2], diagnostics) == 0):
		js_node_free(result)
		return 0
	for i in range(node.children.length):
		pg_ast_node* clause = node.children[i]
		if (js_cst_is(clause, c"switch_clause") == 0): continue
		int start = 2
		js_node* lowered = js_node_new(c"default", c"")
		if (js_cst_is(clause.children[0], c"KW_CASE")):
			js_lower_rename(lowered, c"case")
			start = 3
			if (js_lower_add(lowered, clause.children[1], diagnostics) == 0):
				js_node_free(lowered)
				js_node_free(result)
				return 0
		js_node_add(result, lowered)
		for j in range(start, clause.children.length):
			if (js_lower_add(lowered, clause.children[j], diagnostics) == 0):
				js_node_free(result)
				return 0
		lowered.offset = clause.first_token.offset
		lowered.length = clause.last_token.offset + clause.last_token.length - lowered.offset
	return result


js_node* js_lower_impl(pg_ast_node* node, pg_diagnostics* diagnostics):
	int count = node.children.length
	if (node.token != 0):
		if (js_cst_is(node, c"NUMBER")):
			int length = strlen(node.text)
			if (length > 1 && node.text[length - 1] == 'n'):
				js_node* result = js_node_new(c"bigint", node.text)
				result.text[length - 1] = 0
				return result
			return js_number(node.text)
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
		if (js_cst_is(node, c"KW_SUPER")): return js_node_new(c"super", c"")
		return js_lower_error(node, diagnostics)
	if (js_cst_is(node, c"identifier_reference") || js_cst_is(node, c"identifier_name") || js_cst_is(node, c"binding_identifier")): return js_lower_identifier(node)
	if (js_cst_is(node, c"statement") || js_cst_is(node, c"binding_pattern") || js_cst_is(node, c"return_value")):
		if (count == 1): return js_lower_node(node.children[0], diagnostics)
	if (js_cst_is(node, c"parameter") || js_cst_is(node, c"binding_element")):
		if (count == 1): return js_lower_node(node.children[0], diagnostics)
		js_node* result = js_node_new(c"default_pattern", c"")
		if (js_lower_add(result, node.children[0], diagnostics) && js_lower_add(result, node.children[1].children[1], diagnostics)): return result
		js_node_free(result)
		return 0
	if (js_cst_is(node, c"binding_rest") || js_cst_is(node, c"rest_parameter")):
		js_node* result = js_node_new(c"rest", c"")
		if (js_lower_add(result, node.children[1], diagnostics)): return result
		js_node_free(result)
		return 0
	if (js_cst_is(node, c"object_binding")):
		js_node* result = js_node_new(c"object_pattern", c"")
		pg_ast_node* items = js_cst_child(node, c"object_binding_items")
		if (items == 0): return result
		for i in range(items.children.length):
			pg_ast_node* item = items.children[i]
			if (item.token != 0): continue
			if (js_cst_is(item, c"object_binding_tail")): item = item.children[1]
			if (js_lower_add(result, item, diagnostics) == 0):
				js_node_free(result)
				return 0
		return result
	if (js_cst_is(node, c"object_binding_property")):
		pg_ast_node* name = node.children[0]
		js_node* result = 0
		if (js_cst_is(name, c"property_name")):
			js_node* key = js_lower_property_key(name, diagnostics)
			if (key == 0): return 0
			if (js_kind(key, c"property_key")):
				result = js_node_new(c"pattern_property", key.text)
				js_node_free(key)
			else:
				result = js_node_new(c"computed_pattern_property", c"")
				js_node_add(result, key.children[0])
				key.children.clear()
				js_node_free(key)
		else:
			char* text = js_identifier_decode(name.first_token.text)
			result = js_node_new(c"pattern_property", text)
			free(text)
		if (count == 3):
			if (js_lower_add(result, node.children[2], diagnostics)): return result
		else:
			js_node* binding = js_lower_identifier(name)
			if (count == 2):
				js_node* fallback = js_node_new(c"default_pattern", c"")
				js_node_add(fallback, binding)
				js_node_add(result, fallback)
				if (js_lower_add(fallback, node.children[1].children[1], diagnostics)): return result
			else:
				js_node_add(result, binding)
				return result
		js_node_free(result)
		return 0
	if (js_cst_is(node, c"array_binding")):
		js_node* result = js_node_new(c"array_pattern", c"")
		for i in range(1, count - 1):
			pg_ast_node* item = node.children[i]
			if (js_cst_is(item, c"binding_array_tail")): item = item.children[1]
			if (js_cst_is(item, c"binding_element_opt")):
				if (item.children.length == 0):
					if (i < count - 2 && js_cst_is(node.children[i + 1], c"binding_rest") == 0): js_node_add(result, js_node_new(c"empty", c""))
					continue
				item = item.children[0]
			if (js_lower_add(result, item, diagnostics) == 0):
				js_node_free(result)
				return 0
		return result
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
		char* kind = c"unary"
		if (js_cst_is(op, c"KW_AWAIT")): kind = c"await"
		if (strcmp(op.first_token.text, c"++") == 0 || strcmp(op.first_token.text, c"--") == 0): kind = c"update_prefix"
		js_node* result = js_node_new(kind, op.first_token.text)
		if (js_cst_is(op, c"KW_AWAIT")):
			free(result.text)
			result.text = strclone(c"")
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
	if (js_cst_is(node, c"new_expression") || js_cst_is(node, c"new_callee")):
		if (js_cst_is(node.children[0], c"KW_NEW") == 0): return js_lower_postfix(node, diagnostics)
		if (count < 2): return js_lower_error(node, diagnostics)
		if (js_cst_is(node.children[1], c"DOT")):
			js_node* target = js_node_new(c"new_target", c"")
			target.offset = node.first_token.offset
			target.length = node.children[2].token.offset + node.children[2].token.length - target.offset
			return js_lower_postfix_tails(node, target, 3, diagnostics)
		js_node* constructed = js_node_new(c"construct", c"")
		if (js_lower_add(constructed, node.children[1], diagnostics) == 0):
			js_node_free(constructed)
			return 0
		int tail = 2
		if (count > 2 && js_cst_is(node.children[2], c"arguments")):
			if (js_lower_arguments(constructed, node.children[2], diagnostics) == 0):
				js_node_free(constructed)
				return 0
			tail = 3
		constructed.offset = node.first_token.offset
		constructed.length = node.last_token.offset + node.last_token.length - constructed.offset
		return js_lower_postfix_tails(node, constructed, tail, diagnostics)
	if (js_cst_is(node, c"postfix")): return js_lower_postfix(node, diagnostics)
	if (js_cst_is(node, c"argument")):
		if (count == 1): return js_lower_node(node.children[0], diagnostics)
		js_node* result = js_node_new(c"spread", c"")
		if (js_lower_add(result, node.children[1], diagnostics)): return result
		js_node_free(result)
		return 0
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
	if (js_cst_is(node, c"arrow_function")):
		pg_ast_node* parameter = js_cst_child(node, c"arrow_parameters").children[0]
		js_node* result = js_node_new(c"arrow", c"")
		if (js_cst_child(node, c"async_modifier") != 0): js_lower_rename(result, c"async_arrow")
		if (js_cst_is(parameter, c"binding_identifier")):
			js_node* parameters = js_node_new(c"parameters", c"")
			js_node_add(parameters, js_lower_identifier(parameter))
			js_node_add(result, parameters)
		else if (js_lower_add(result, parameter, diagnostics) == 0):
			js_node_free(result)
			return 0
		if (js_lower_add(result, js_cst_child(node, c"arrow_body").children[0], diagnostics) == 0):
			js_node_free(result)
			return 0
		return result
	if (js_cst_is(node, c"function_decl") || js_cst_is(node, c"function_expr")):
		pg_ast_node* binding = js_cst_child(node, c"binding_identifier")
		char* name = strclone(c"")
		if (binding != 0):
			free(name)
			name = js_identifier_decode(binding.first_token.text)
		char* kind = js_lower_function_kind(js_cst_child(node, c"async_modifier") != 0, js_cst_child(node, c"STAR") != 0, js_cst_is(node, c"function_expr"))
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
				# catch(pattern) = binding pattern, block.
				js_node* destructured = js_node_new(c"catch", c"")
				free(name)
				if (js_lower_add(destructured, pattern, diagnostics) && js_lower_add(destructured, js_cst_child(node, c"block"), diagnostics)): return destructured
				js_node_free(destructured)
				return 0
			free(name)
			name = js_identifier_decode(pattern.first_token.text)
		js_node* result = js_node_new(c"catch", name)
		free(name)
		if (js_lower_add(result, js_cst_child(node, c"block"), diagnostics) == 0):
			js_node_free(result)
			return 0
		return result
	if (js_cst_is(node, c"labelled_statement")):
		char* name = js_identifier_decode(node.first_token.text)
		js_node* result = js_node_new(c"label", name)
		free(name)
		if (js_lower_add(result, node.children[2], diagnostics) == 0):
			js_node_free(result)
			return 0
		return result
	if (js_cst_is(node, c"break_statement") || js_cst_is(node, c"continue_statement")):
		char* kind = c"break"
		if (js_cst_is(node, c"continue_statement")): kind = c"continue"
		js_node* result = js_node_new(kind, c"")
		pg_ast_node* label = js_cst_child(node, c"jump_label")
		if (label != 0):
			free(result.text)
			result.text = js_identifier_decode(label.first_token.text)
		return result
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
		pg_ast_node* binding = js_cst_child(header, c"for_binding")
		if (binding != 0): return js_lower_for_each(node, header, binding, diagnostics)
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
	if (js_cst_is(node, c"export_statement")): return js_lower_export(node, diagnostics)
	if (js_cst_is(node, c"import_statement")): return js_lower_import(node, diagnostics)
	if (js_cst_is(node, c"class_decl") || js_cst_is(node, c"class_expr")): return js_lower_class(node, diagnostics)
	if (js_cst_is(node, c"switch_statement")): return js_lower_switch(node, diagnostics)
	if (js_cst_is(node, c"with_statement")):
		js_node* result = js_node_new(c"with", c"")
		if (js_lower_add(result, node.children[2], diagnostics) && js_lower_add(result, node.children[4], diagnostics)): return result
		js_node_free(result)
		return 0
	if (js_cst_is(node, c"debugger_statement")): return js_node_new(c"debugger", c"")
	if (js_cst_is(node, c"yield_expression")):
		js_node* result = js_node_new(c"yield", c"")
		pg_ast_node* value = js_cst_child(node, c"yield_value")
		if (value == 0): return result
		if (js_cst_child(value, c"STAR") != 0):
			free(result.text)
			result.text = strclone(c"*")
		if (js_lower_add(result, value.children[value.children.length - 1], diagnostics)): return result
		js_node_free(result)
		return 0
	if (js_cst_is(node, c"dynamic_import")):
		if (js_cst_is(node.children[1], c"DOT")): return js_node_new(c"import_meta", c"")
		js_node* result = js_node_new(c"import_call", c"")
		if (js_lower_add(result, node.children[2], diagnostics)): return result
		js_node_free(result)
		return 0
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
				# Elisions are holes; the final empty slot is a trailing comma.
				if (i == count - 2): continue
				js_node_add(result, js_node_new(c"empty", c""))
				continue
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
