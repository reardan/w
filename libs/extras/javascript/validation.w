# Syntax-context validation for the generated JavaScript grammar.
# This is deliberately separate from lexer predicates, which must stay pure.
import lib.utf8
import structures.string
import libs.extras.javascript.lexical
import libs.extras.javascript.regexp_syntax
import libs.extras.parser_generator.runtime


int js_cst_is(pg_ast_node* node, char* name):
	return node != 0 && strcmp(node.name, name) == 0


pg_ast_node* js_cst_child(pg_ast_node* node, char* name):
	for i in range(node.children.length):
		if (js_cst_is(node.children[i], name)): return node.children[i]
	return 0


pg_ast_node* js_cst_unwrap(pg_ast_node* node):
	while (node != 0 && node.children.length == 1): node = node.children[0]
	return node


char* js_identifier_decode(char* raw):
	string_builder* out = string_new()
	int i = 0
	while (raw[i] != 0):
		if (raw[i] == 92):
			int cp = 0
			int n = js_unicode_escape(raw, i, &cp)
			if (n == 0): break
			char[4] encoded
			int count = utf8_encode(encoded, cp)
			string_append_bytes(out, encoded, count)
			i = i + n
		else:
			string_append_char(out, raw[i])
			i = i + 1
	char* text = out.data
	free(out)
	return text


int js_reserved_identifier(char* text):
	return strcmp(text, c"break") == 0 || strcmp(text, c"case") == 0 || strcmp(text, c"catch") == 0 || strcmp(text, c"class") == 0 || strcmp(text, c"const") == 0 || strcmp(text, c"continue") == 0 || strcmp(text, c"debugger") == 0 || strcmp(text, c"default") == 0 || strcmp(text, c"delete") == 0 || strcmp(text, c"do") == 0 || strcmp(text, c"else") == 0 || strcmp(text, c"enum") == 0 || strcmp(text, c"export") == 0 || strcmp(text, c"extends") == 0 || strcmp(text, c"false") == 0 || strcmp(text, c"finally") == 0 || strcmp(text, c"for") == 0 || strcmp(text, c"function") == 0 || strcmp(text, c"if") == 0 || strcmp(text, c"import") == 0 || strcmp(text, c"in") == 0 || strcmp(text, c"instanceof") == 0 || strcmp(text, c"new") == 0 || strcmp(text, c"null") == 0 || strcmp(text, c"return") == 0 || strcmp(text, c"super") == 0 || strcmp(text, c"switch") == 0 || strcmp(text, c"this") == 0 || strcmp(text, c"throw") == 0 || strcmp(text, c"true") == 0 || strcmp(text, c"try") == 0 || strcmp(text, c"typeof") == 0 || strcmp(text, c"var") == 0 || strcmp(text, c"void") == 0 || strcmp(text, c"while") == 0 || strcmp(text, c"with") == 0


int js_strict_reserved(char* text):
	return strcmp(text, c"implements") == 0 || strcmp(text, c"interface") == 0 || strcmp(text, c"package") == 0 || strcmp(text, c"private") == 0 || strcmp(text, c"protected") == 0 || strcmp(text, c"public") == 0 || strcmp(text, c"static") == 0 || strcmp(text, c"let") == 0 || strcmp(text, c"yield") == 0


int js_directive_strict(pg_ast_node* body):
	if (body == 0): return 0
	for i in range(body.children.length):
		pg_ast_node* stmt = body.children[i]
		if (stmt.token != 0): continue
		while (stmt.children.length == 1): stmt = stmt.children[0]
		if (js_cst_is(stmt, c"expression_statement") == 0): return 0
		pg_ast_node* value = js_cst_unwrap(stmt.children[0])
		if (value.token == 0 || js_cst_is(value, c"STRING") == 0): return 0
		if (strcmp(value.text, c"'use strict'") == 0 || strcmp(value.text, c"\"use strict\"") == 0): return 1
	return 0


void js_validation_error(pg_diagnostics* diagnostics, pg_ast_node* node, char* message):
	pg_token* token = node.first_token
	if (token == 0): return
	pg_diagnostics_add(diagnostics, token.filename, token.line, token.column, message, c"valid JavaScript syntax context", token.text)


int js_simple_target(pg_ast_node* node):
	node = js_cst_unwrap(node)
	if (node.token != 0):
		return js_cst_is(node, c"IDENT") || js_cst_is(node, c"KW_ASYNC") || js_cst_is(node, c"KW_OF") || js_cst_is(node, c"KW_GET") || js_cst_is(node, c"KW_SET") || js_cst_is(node, c"KW_STATIC") || js_cst_is(node, c"KW_FROM") || js_cst_is(node, c"KW_AS") || js_cst_is(node, c"KW_TARGET") || js_cst_is(node, c"KW_LET")
	if (js_cst_is(node, c"primary") && node.children.length == 3):
		if (js_cst_is(node.children[0], c"LPAREN")): return js_simple_target(node.children[1])
	if (js_cst_is(node, c"postfix") || js_cst_is(node, c"new_expression")):
		pg_ast_node* last = node.children[node.children.length - 1]
		if (js_cst_is(last, c"postfix_tail") == 0): return 0
		for i in range(node.children.length):
			pg_ast_node* tail = node.children[i]
			if (js_cst_child(tail, c"OPTIONAL") != 0): return 0
		return js_cst_is(last.children[0], c"DOT") || js_cst_is(last.children[0], c"LBRACKET")
	return 0


int js_assignment_target(pg_ast_node* node, int destructuring):
	if (js_simple_target(node)): return 1
	node = js_cst_unwrap(node)
	if (destructuring && (js_cst_is(node, c"array_literal") || js_cst_is(node, c"object_literal"))): return 1
	return 0


pg_ast_node* js_target_identifier(pg_ast_node* node):
	node = js_cst_unwrap(node)
	if (node.token != 0 && js_simple_target(node)): return node
	if (js_cst_is(node, c"primary") && node.children.length == 3 && js_cst_is(node.children[0], c"LPAREN")): return js_target_identifier(node.children[1])
	return 0


struct js_validation_context:
	int module
	int strict
	int function_depth
	int async_function
	int generator
	int loops
	int switches
	int top_level
	int new_target_allowed
	int in_parameters


int js_is_function(pg_ast_node* node):
	return js_cst_is(node, c"function_decl") || js_cst_is(node, c"function_expr") || js_cst_is(node, c"arrow_function") || js_cst_is(node, c"method")


int js_jump_label_exists(pg_ast_node* node, int continuing):
	pg_ast_node* label = js_cst_child(node, c"jump_label")
	if (label == 0): return 0
	char* name = js_identifier_decode(label.first_token.text)
	pg_ast_node* parent = node.parent
	int found = 0
	while (parent != 0 && js_is_function(parent) == 0):
		if (js_cst_is(parent, c"labelled_statement")):
			char* candidate = js_identifier_decode(parent.first_token.text)
			int matches = strcmp(candidate, name) == 0
			free(candidate)
			if (matches):
				found = 1
				if (continuing):
					pg_ast_node* target = parent.children[2]
					while (js_cst_is(target, c"statement") || js_cst_is(target, c"labelled_statement")):
						if (js_cst_is(target, c"statement")): target = target.children[0]
						else: target = target.children[2]
					found = js_cst_is(target, c"for_statement") || js_cst_is(target, c"while_statement") || js_cst_is(target, c"do_statement")
				break
		parent = parent.parent
	free(name)
	return found


void js_validate_node(pg_ast_node* node, js_validation_context* context, pg_diagnostics* diagnostics):
	if (node == 0): return
	js_validation_context here = *context
	if (js_is_function(node)):
		here.in_parameters = 0
		here.function_depth = here.function_depth + 1
		here.async_function = js_cst_child(node, c"async_modifier") != 0
		here.generator = js_cst_child(node, c"STAR") != 0
		here.loops = 0
		here.switches = 0
		here.top_level = 0
		pg_ast_node* body = js_cst_child(node, c"block")
		pg_ast_node* arrow_body = js_cst_child(node, c"arrow_body")
		if (arrow_body != 0): body = js_cst_child(arrow_body, c"block")
		if (js_cst_is(node, c"arrow_function") == 0): here.new_target_allowed = 1
		if (js_directive_strict(body)): here.strict = 1
	if (js_cst_is(node, c"class_decl") || js_cst_is(node, c"class_expr")): here.strict = 1
	if (js_cst_is(node, c"program") && js_directive_strict(node)): here.strict = 1
	if (js_cst_is(node, c"parameters") || js_cst_is(node, c"arrow_parameters") || js_cst_is(node, c"parameter")): here.in_parameters = 1
	if (here.in_parameters && js_cst_is(node, c"yield_expression")): js_validation_error(diagnostics, node, c"yield expression in formal parameters")
	if (here.in_parameters && js_cst_is(node, c"unary") && js_cst_child(node, c"KW_AWAIT") != 0): js_validation_error(diagnostics, node, c"await expression in formal parameters")
	if (js_cst_is(node, c"return_statement") && here.function_depth == 0): js_validation_error(diagnostics, node, c"return outside function")
	if (js_cst_is(node, c"yield_expression") && here.generator == 0): js_validation_error(diagnostics, node, c"yield outside generator")
	if (js_cst_is(node, c"unary") && js_cst_child(node, c"KW_AWAIT") != 0 && here.async_function == 0): js_validation_error(diagnostics, node, c"await outside async function (ES2020)")
	if (js_cst_is(node, c"with_statement") && here.strict): js_validation_error(diagnostics, node, c"with statement in strict code")
	if (js_cst_is(node, c"new_expression") && js_cst_child(node, c"KW_TARGET") != 0 && here.new_target_allowed == 0): js_validation_error(diagnostics, node, c"new.target outside function")
	if (js_cst_is(node, c"dynamic_import") && js_cst_child(node, c"DOT") != 0):
		pg_ast_node* name = js_cst_child(node, c"identifier_name")
		if (here.module == 0 || name == 0 || strcmp(name.first_token.text, c"meta") != 0): js_validation_error(diagnostics, node, c"import.meta requires module context")
	if (js_cst_is(node, c"template") && js_cst_is(node.parent, c"postfix_tail") == 0):
		for part in range(node.children.length):
			pg_ast_node* text = js_cst_unwrap(node.children[part])
			if (js_cst_is(text, c"TEMPLATE_TEXT")):
				int i = 0
				while (text.text[i] != 0):
					if (text.text[i] == 92):
						int width = js_string_escape(text.text, i)
						int ch = text.text[i + 1]
						if (width == 0 || (ch >= '1' && ch <= '9') || (ch == '0' && js_digit(text.text[i + 2]))):
							js_validation_error(diagnostics, text, c"invalid escape in untagged template")
							break
						i = i + width
					else: i = i + 1
	if (js_cst_is(node, c"import_statement") || js_cst_is(node, c"export_statement")):
		if (here.module == 0 || here.top_level == 0): js_validation_error(diagnostics, node, c"import/export requires module top level")
	if (js_cst_is(node, c"break_statement")):
		int labelled = js_cst_child(node, c"jump_label") != 0
		if ((labelled && js_jump_label_exists(node, 0) == 0) || (labelled == 0 && here.loops == 0 && here.switches == 0)): js_validation_error(diagnostics, node, c"invalid break target")
	if (js_cst_is(node, c"continue_statement")):
		int labelled = js_cst_child(node, c"jump_label") != 0
		if ((labelled && js_jump_label_exists(node, 1) == 0) || (labelled == 0 && here.loops == 0)): js_validation_error(diagnostics, node, c"invalid continue target")
	if (js_cst_is(node, c"assignment") && node.children.length == 2):
		pg_ast_node* tail = node.children[1]
		if (js_cst_is(tail, c"assignment_tail")):
			int destructuring = strcmp(tail.first_token.text, c"=") == 0
			if (js_assignment_target(node.children[0], destructuring) == 0): js_validation_error(diagnostics, node, c"invalid assignment target")
			pg_ast_node* id = js_target_identifier(node.children[0])
			if (here.strict && id != 0):
				char* name = js_identifier_decode(id.text)
				if (strcmp(name, c"eval") == 0 || strcmp(name, c"arguments") == 0): js_validation_error(diagnostics, node, c"assignment to eval/arguments in strict code")
				free(name)
	if (js_cst_is(node, c"short_circuit") && node.children.length > 1):
		pg_ast_node* head = js_cst_unwrap(node.children[0])
		if (js_cst_is(head, c"logical_or") || js_cst_is(head, c"logical_and")): js_validation_error(diagnostics, node, c"nullish coalescing cannot mix with unparenthesized logical operators")
	if (js_cst_is(node, c"update") && node.children.length == 2):
		if (js_simple_target(node.children[0]) == 0): js_validation_error(diagnostics, node, c"invalid update target")
	if (js_cst_is(node, c"unary") && node.children.length == 2):
		pg_ast_node* op = js_cst_unwrap(node.children[0])
		if (js_cst_is(op, c"INC") || js_cst_is(op, c"DEC")):
			if (js_simple_target(node.children[1]) == 0): js_validation_error(diagnostics, node, c"invalid update target")
	if (js_cst_is(node, c"power") && node.children.length == 2):
		pg_ast_node* base = js_cst_unwrap(node.children[0])
		if (js_cst_is(base, c"unary") && base.children.length == 2):
			pg_ast_node* op = js_cst_unwrap(base.children[0])
			if (js_cst_is(op, c"INC") == 0 && js_cst_is(op, c"DEC") == 0): js_validation_error(diagnostics, node, c"unparenthesized unary expression before exponentiation")
	if (js_cst_is(node, c"variable_declarator") && js_cst_child(node, c"initializer") == 0):
		pg_ast_node* parent = node.parent
		while (parent != 0 && js_cst_is(parent, c"variable_declarations") == 0): parent = parent.parent
		if (parent != 0 && strcmp(parent.first_token.text, c"const") == 0): js_validation_error(diagnostics, node, c"const declaration requires initializer")
		pg_ast_node* binding = js_cst_unwrap(node.children[0])
		if (binding.token == 0): js_validation_error(diagnostics, node, c"destructuring declaration requires initializer")
	if (js_cst_is(node, c"identifier_reference") || js_cst_is(node, c"binding_identifier")):
		char* name = js_identifier_decode(node.first_token.text)
		int bad = js_reserved_identifier(name) || (here.strict && js_strict_reserved(name))
		if (strcmp(name, c"await") == 0 && (here.module || here.async_function)): bad = 1
		if (strcmp(name, c"yield") == 0 && (here.strict || here.generator)): bad = 1
		if (js_cst_is(node, c"binding_identifier") && here.strict):
			if (strcmp(name, c"eval") == 0 || strcmp(name, c"arguments") == 0): bad = 1
		if (bad): js_validation_error(diagnostics, node, c"reserved identifier in this context")
		free(name)
	if (js_cst_is(node, c"REGEX") && js_regexp_syntax(node.text) == 0): js_validation_error(diagnostics, node, c"invalid regular expression structure")
	if (node.token != 0 && here.strict):
		if (js_cst_is(node, c"NUMBER") && node.text[0] == '0' && js_digit(node.text[1])): js_validation_error(diagnostics, node, c"legacy leading-zero number in strict code")
		if (js_cst_is(node, c"STRING")):
			int i = 1
			while (node.text[i] != 0):
				if (node.text[i] == 92):
					i = i + 1
					if ((node.text[i] >= '1' && node.text[i] <= '9') || (node.text[i] == '0' && js_digit(node.text[i + 1]))): js_validation_error(diagnostics, node, c"legacy numeric escape in strict code")
					if (node.text[i] == 0): break
				i = i + 1
	if (js_cst_is(node, c"for_statement") || js_cst_is(node, c"while_statement") || js_cst_is(node, c"do_statement")): here.loops = here.loops + 1
	if (js_cst_is(node, c"switch_statement")): here.switches = here.switches + 1
	if (js_cst_is(node, c"block") || js_cst_is(node, c"if_statement") || js_cst_is(node, c"while_statement") || js_cst_is(node, c"for_statement") || js_cst_is(node, c"do_statement") || js_cst_is(node, c"switch_statement") || js_cst_is(node, c"labelled_statement") || js_cst_is(node, c"with_statement")): here.top_level = 0
	for i in range(node.children.length): js_validate_node(node.children[i], &here, diagnostics)


void js_validate(pg_parse_result* result, int module):
	if (result.success == 0): return
	js_validation_context context
	context.module = module
	context.strict = module
	context.function_depth = 0
	context.async_function = 0
	context.generator = 0
	context.loops = 0
	context.switches = 0
	context.top_level = 1
	context.new_target_allowed = 0
	context.in_parameters = 0
	js_validate_node(result.root, &context, result.diagnostics)
	if (pg_diagnostics_count(result.diagnostics) != 0): result.success = 0
