/*
Deterministic printer for the initial JS AST facade. Binary, assignment,
unary and conditional expressions are parenthesized, making grouping
independent of operator precedence. Unsupported kinds/operators/shapes
produce diagnostics and no output. Source comments are preserved through
edits.w; this printer constructs fresh source from semantic nodes.

Shapes: program/block = statements; function(name) = parameters, block;
variable(const/let/var) = declarators; declarator = binding[, initializer];
return = [expression]; throw/expression_statement = expression;
if = condition, then[, else]; export = declaration;
while/do_while = condition, body; for = init, condition, update, body;
omitted for clauses = empty; break/continue have no children;
function_expression(optional name) = parameters, block;
try = block, catch-or-empty, finally-block-or-empty; catch(name) = block;
string_utf16 owns explicit code units in string_units;
import(specifier) = [default-binding]; call = callee, arguments...;
member/computed_member = receiver, property; property(key) = value;
template = template_text(raw spelling) and expression children.
property_shorthand(name) preserves shorthand (notably __proto__). The
string_non_directive("use strict") node retains an escaped spelling so
printing does not turn an ordinary string into a strict-mode directive.
*/
import libs.extras.javascript.ast
import libs.extras.javascript.lexical
import libs.extras.javascript.validation
import structures.string


int js_kind(js_node* node, char* kind):
	return strcmp(node.kind, kind) == 0


int js_print_identifier_valid(char* text, int binding):
	if (strlen(text) == 0 || pg_lexer_matcher_js_identifier(text, 0) != strlen(text)): return 0
	char* decoded = js_identifier_decode(text)
	int invalid = js_reserved_identifier(decoded)
	if (binding): invalid = invalid || js_strict_reserved(decoded) || strcmp(decoded, c"await") == 0
	free(decoded)
	return invalid == 0


int js_print_assignable(js_node* node):
	return js_kind(node, c"identifier") || js_kind(node, c"member") || js_kind(node, c"computed_member")


int js_print_template_valid(char* text):
	if (pg_lexer_matcher_js_template_text(text, 0) != strlen(text)): return 0
	int i = 0
	while (text[i] != 0):
		if (text[i] == 92):
			if (text[i + 1] >= '1' && text[i + 1] <= '9'): return 0
			if (text[i + 1] == '0' && js_digit(text[i + 2])): return 0
			int width = js_string_escape(text, i)
			if (width == 0): return 0
			i = i + width
		else: i = i + 1
	return 1


void js_print_indent(string_builder* out, int depth):
	for i in range(depth): string_append(out, c"  ")


# JS strings use double quotes and deterministic escapes for control bytes.
void js_print_quoted(string_builder* out, char* text):
	char* digits = c"0123456789abcdef"
	string_append(out, c"\"")
	int i = 0
	while (text[i] != 0):
		int ch = cast(int, text[i]) & 255
		if (ch == 34): string_append(out, c"\\\"")
		else if (ch == 92): string_append(out, c"\\\\")
		else if (ch == 10): string_append(out, c"\\n")
		else if (ch == 13): string_append(out, c"\\r")
		else if (ch == 9): string_append(out, c"\\t")
		else if (ch < 32):
			string_append(out, c"\\x")
			string_append_bytes(out, digits + ch / 16, 1)
			string_append_bytes(out, digits + ch % 16, 1)
		else: string_append_bytes(out, text + i, 1)
		i = i + 1
	string_append(out, c"\"")


int js_print_error(pg_diagnostics* diagnostics, js_node* node):
	char* kind = c"null"
	if (node != 0): kind = node.kind
	pg_diagnostics_add(diagnostics, c"<JavaScript AST>", 1, 1, c"unsupported or invalid JavaScript AST node", c"supported node shape", kind)
	return 0


int js_operator_valid(char* op, int assignment):
	if (assignment):
		return strcmp(op, c"=") == 0 || strcmp(op, c"+=") == 0 || strcmp(op, c"-=") == 0 || strcmp(op, c"*=") == 0 || strcmp(op, c"/=") == 0 || strcmp(op, c"%=") == 0 || strcmp(op, c"**=") == 0 || strcmp(op, c"<<=") == 0 || strcmp(op, c">>=") == 0 || strcmp(op, c">>>=") == 0 || strcmp(op, c"&=") == 0 || strcmp(op, c"|=") == 0 || strcmp(op, c"^=") == 0
	return strcmp(op, c",") == 0 || strcmp(op, c"+") == 0 || strcmp(op, c"-") == 0 || strcmp(op, c"*") == 0 || strcmp(op, c"/") == 0 || strcmp(op, c"%") == 0 || strcmp(op, c"**") == 0 || strcmp(op, c"==") == 0 || strcmp(op, c"!=") == 0 || strcmp(op, c"===") == 0 || strcmp(op, c"!==") == 0 || strcmp(op, c"<") == 0 || strcmp(op, c">") == 0 || strcmp(op, c"<=") == 0 || strcmp(op, c">=") == 0 || strcmp(op, c"&&") == 0 || strcmp(op, c"||") == 0 || strcmp(op, c"??") == 0 || strcmp(op, c"&") == 0 || strcmp(op, c"|") == 0 || strcmp(op, c"^") == 0 || strcmp(op, c"<<") == 0 || strcmp(op, c">>") == 0 || strcmp(op, c">>>") == 0 || strcmp(op, c"in") == 0 || strcmp(op, c"instanceof") == 0


int js_print_expression(string_builder* out, js_node* node, pg_diagnostics* diagnostics);
int js_print_statement(string_builder* out, js_node* node, int depth, pg_diagnostics* diagnostics);


int js_print_expression_list(string_builder* out, js_node* node, int start, pg_diagnostics* diagnostics):
	for i in range(start, node.children.length):
		if (i > start): string_append(out, c", ")
		if (js_print_expression(out, node.children[i], diagnostics) == 0): return 0
	return 1


int js_print_expression(string_builder* out, js_node* node, pg_diagnostics* diagnostics):
	if (node == 0): return js_print_error(diagnostics, node)
	int count = node.children.length
	if (js_kind(node, c"string_utf16")):
		if (count != 0 || node.string_units == 0): return js_print_error(diagnostics, node)
		char* digits = c"0123456789abcdef"
		string_append_char(out, 34)
		for i in range(node.string_units.units.length):
			int unit = node.string_units.units[i]
			if (unit < 0 || unit > 65535): return js_print_error(diagnostics, node)
			string_append(out, c"\\u")
			for shift in range(4): string_append_char(out, digits[(unit >> ((3 - shift) * 4)) & 15])
		string_append_char(out, 34)
		return 1
	if (js_kind(node, c"function_expression")):
		string_append(out, c"(")
		if (js_print_statement(out, node, 0, diagnostics) == 0): return 0
		string_append(out, c")")
		return 1
	if (js_kind(node, c"identifier")):
		if (count != 0 || js_print_identifier_valid(node.text, 0) == 0): return js_print_error(diagnostics, node)
		string_append(out, node.text)
		return 1
	if (js_kind(node, c"number") || js_kind(node, c"regex") || js_kind(node, c"literal")):
		if (count != 0 || strlen(node.text) == 0): return js_print_error(diagnostics, node)
		if (js_kind(node, c"number") && pg_lexer_matcher_js_number(node.text, 0) != strlen(node.text)): return js_print_error(diagnostics, node)
		if (js_kind(node, c"regex") && pg_lexer_matcher_js_regex(node.text, 0) != strlen(node.text)): return js_print_error(diagnostics, node)
		if (js_kind(node, c"literal") && strcmp(node.text, c"true") != 0 && strcmp(node.text, c"false") != 0 && strcmp(node.text, c"null") != 0 && strcmp(node.text, c"this") != 0): return js_print_error(diagnostics, node)
		string_append(out, node.text)
		return 1
	if (js_kind(node, c"string_non_directive")):
		if (count != 0 || strcmp(node.text, c"use strict") != 0): return js_print_error(diagnostics, node)
		string_append(out, c"\"use\\x20strict\"")
		return 1
	if (js_kind(node, c"string")):
		if (count != 0 || utf8_validate_bytes(node.text, strlen(node.text)) == 0): return js_print_error(diagnostics, node)
		js_print_quoted(out, node.text)
		return 1
	if (js_kind(node, c"binary") || js_kind(node, c"assignment")):
		if (count != 2 || js_operator_valid(node.text, js_kind(node, c"assignment")) == 0): return js_print_error(diagnostics, node)
		if (js_kind(node, c"assignment") && js_print_assignable(node.children[0]) == 0): return js_print_error(diagnostics, node)
		string_append(out, c"(")
		if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c" ")
		string_append(out, node.text)
		string_append(out, c" ")
		if (js_print_expression(out, node.children[1], diagnostics) == 0): return 0
		string_append(out, c")")
		return 1
	if (js_kind(node, c"unary") || js_kind(node, c"update_prefix") || js_kind(node, c"update_postfix")):
		if (count != 1): return js_print_error(diagnostics, node)
		if (js_kind(node, c"unary")):
			if (strcmp(node.text, c"!") != 0 && strcmp(node.text, c"~") != 0 && strcmp(node.text, c"+") != 0 && strcmp(node.text, c"-") != 0 && strcmp(node.text, c"typeof") != 0 && strcmp(node.text, c"void") != 0 && strcmp(node.text, c"delete") != 0): return js_print_error(diagnostics, node)
		else:
			if (js_print_assignable(node.children[0]) == 0): return js_print_error(diagnostics, node)
			if (strcmp(node.text, c"++") != 0 && strcmp(node.text, c"--") != 0): return js_print_error(diagnostics, node)
		string_append(out, c"(")
		if (js_kind(node, c"update_postfix") == 0):
			string_append(out, node.text)
			string_append(out, c" ")
		if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
		if (js_kind(node, c"update_postfix")): string_append(out, node.text)
		string_append(out, c")")
		return 1
	if (js_kind(node, c"conditional")):
		if (count != 3): return js_print_error(diagnostics, node)
		string_append(out, c"(")
		for i in range(3):
			if (i == 1): string_append(out, c" ? ")
			if (i == 2): string_append(out, c" : ")
			if (js_print_expression(out, node.children[i], diagnostics) == 0): return 0
		string_append(out, c")")
		return 1
	if (js_kind(node, c"call")):
		if (count < 1): return js_print_error(diagnostics, node)
		if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c"(")
		if (js_print_expression_list(out, node, 1, diagnostics) == 0): return 0
		string_append(out, c")")
		return 1
	if (js_kind(node, c"member") || js_kind(node, c"computed_member")):
		if (count != 2): return js_print_error(diagnostics, node)
		# Parentheses also make numeric literal receivers unambiguous.
		string_append(out, c"(")
		if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c")")
		if (js_kind(node, c"member")):
			if (js_kind(node.children[1], c"identifier") == 0): return js_print_error(diagnostics, node)
			string_append(out, c".")
		else: string_append(out, c"[")
		if (js_kind(node, c"member")):
			char* name = node.children[1].text
			if (node.children[1].children.length != 0 || strlen(name) == 0 || pg_lexer_matcher_js_identifier(name, 0) != strlen(name)): return js_print_error(diagnostics, node)
			string_append(out, name)
		else:
			if (js_print_expression(out, node.children[1], diagnostics) == 0): return 0
			string_append(out, c"]")
		return 1
	if (js_kind(node, c"array")):
		string_append(out, c"[")
		if (js_print_expression_list(out, node, 0, diagnostics) == 0): return 0
		string_append(out, c"]")
		return 1
	if (js_kind(node, c"object")):
		string_append(out, c"({")
		for i in range(count):
			js_node* property = node.children[i]
			if (i > 0): string_append(out, c", ")
			if (js_kind(property, c"property_shorthand")):
				if (property.children.length != 0 || js_print_identifier_valid(property.text, 0) == 0): return js_print_error(diagnostics, property)
				string_append(out, property.text)
				continue
			if (js_kind(property, c"property") == 0 || property.children.length != 1): return js_print_error(diagnostics, property)
			if (utf8_validate_bytes(property.text, strlen(property.text)) == 0): return js_print_error(diagnostics, property)
			js_print_quoted(out, property.text)
			string_append(out, c": ")
			if (js_print_expression(out, property.children[0], diagnostics) == 0): return 0
		string_append(out, c"})")
		return 1
	if (js_kind(node, c"template")):
		string_append(out, c"`")
		for i in range(count):
			js_node* part = node.children[i]
			if (js_kind(part, c"template_text")):
				if (part.children.length != 0 || js_print_template_valid(part.text) == 0): return js_print_error(diagnostics, part)
				if (i > 0 && js_kind(node.children[i - 1], c"template_text")): return js_print_error(diagnostics, part)
				string_append(out, part.text)
			else:
				string_append(out, c"${")
				if (js_print_expression(out, part, diagnostics) == 0): return 0
				string_append(out, c"}")
		string_append(out, c"`")
		return 1
	return js_print_error(diagnostics, node)


int js_print_block(string_builder* out, js_node* node, int depth, pg_diagnostics* diagnostics):
	if (js_kind(node, c"block") == 0): return js_print_error(diagnostics, node)
	string_append(out, c"{\n")
	for i in range(node.children.length):
		js_print_indent(out, depth + 1)
		if (js_print_statement(out, node.children[i], depth + 1, diagnostics) == 0): return 0
		string_append(out, c"\n")
	js_print_indent(out, depth)
	string_append(out, c"}")
	return 1


int js_print_dangling_else(js_node* node):
	if ((js_kind(node, c"while") || js_kind(node, c"for")) && node.children.length > 0): return js_print_dangling_else(node.children[node.children.length - 1])
	if (js_kind(node, c"if") == 0): return 0
	if (node.children.length == 2): return 1
	if (node.children.length == 3): return js_print_dangling_else(node.children[2])
	return 0


int js_print_statement(string_builder* out, js_node* node, int depth, pg_diagnostics* diagnostics):
	if (node == 0): return js_print_error(diagnostics, node)
	int count = node.children.length
	if (js_kind(node, c"block")): return js_print_block(out, node, depth, diagnostics)
	if (js_kind(node, c"empty")):
		if (count != 0): return js_print_error(diagnostics, node)
		string_append(out, c";")
		return 1
	if (js_kind(node, c"expression_statement")):
		if (count != 1): return js_print_error(diagnostics, node)
		if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c";")
		return 1
	if (js_kind(node, c"return") || js_kind(node, c"throw")):
		if (count > 1 || (js_kind(node, c"throw") && count != 1)): return js_print_error(diagnostics, node)
		string_append(out, node.kind)
		if (count == 1):
			string_append(out, c" ")
			if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c";")
		return 1
	if (js_kind(node, c"variable")):
		if (count == 0 || (strcmp(node.text, c"const") != 0 && strcmp(node.text, c"let") != 0 && strcmp(node.text, c"var") != 0)): return js_print_error(diagnostics, node)
		string_append(out, node.text)
		string_append(out, c" ")
		for i in range(count):
			js_node* binding = node.children[i]
			if (js_kind(binding, c"declarator") == 0 || binding.children.length < 1 || binding.children.length > 2): return js_print_error(diagnostics, binding)
			if (js_kind(binding.children[0], c"identifier") == 0 || js_print_identifier_valid(binding.children[0].text, 1) == 0): return js_print_error(diagnostics, binding)
			if (strcmp(node.text, c"const") == 0 && binding.children.length != 2): return js_print_error(diagnostics, binding)
			if (i > 0): string_append(out, c", ")
			if (js_print_expression(out, binding.children[0], diagnostics) == 0): return 0
			if (binding.children.length == 2):
				string_append(out, c" = ")
				if (js_print_expression(out, binding.children[1], diagnostics) == 0): return 0
		string_append(out, c";")
		return 1
	if (js_kind(node, c"function") || js_kind(node, c"function_expression")):
		if (count != 2): return js_print_error(diagnostics, node)
		if (strlen(node.text) == 0):
			if (js_kind(node, c"function_expression") == 0): return js_print_error(diagnostics, node)
		else if (js_print_identifier_valid(node.text, 1) == 0): return js_print_error(diagnostics, node)
		if (js_kind(node.children[0], c"parameters") == 0 || js_kind(node.children[1], c"block") == 0): return js_print_error(diagnostics, node)
		string_append(out, c"function ")
		string_append(out, node.text)
		string_append(out, c"(")
		js_node* parameters = node.children[0]
		for i in range(parameters.children.length):
			if (js_kind(parameters.children[i], c"identifier") == 0 || js_print_identifier_valid(parameters.children[i].text, 1) == 0): return js_print_error(diagnostics, parameters)
		if (js_print_expression_list(out, parameters, 0, diagnostics) == 0): return 0
		string_append(out, c") ")
		return js_print_block(out, node.children[1], depth, diagnostics)
	if (js_kind(node, c"try")):
		if (count != 3 || js_kind(node.children[0], c"block") == 0): return js_print_error(diagnostics, node)
		js_node* handler = node.children[1]
		js_node* finalizer = node.children[2]
		if (js_kind(handler, c"empty") && js_kind(finalizer, c"empty")): return js_print_error(diagnostics, node)
		string_append(out, c"try ")
		if (js_print_block(out, node.children[0], depth, diagnostics) == 0): return 0
		if (js_kind(handler, c"empty") == 0):
			if (js_kind(handler, c"catch") == 0 || handler.children.length != 1): return js_print_error(diagnostics, handler)
			string_append(out, c" catch")
			if (strlen(handler.text) != 0):
				if (js_print_identifier_valid(handler.text, 1) == 0): return js_print_error(diagnostics, handler)
				string_append(out, c" (")
				string_append(out, handler.text)
				string_append(out, c")")
			string_append(out, c" ")
			if (js_print_block(out, handler.children[0], depth, diagnostics) == 0): return 0
		else if (handler.children.length != 0): return js_print_error(diagnostics, handler)
		if (js_kind(finalizer, c"empty") == 0):
			string_append(out, c" finally ")
			if (js_print_block(out, finalizer, depth, diagnostics) == 0): return 0
		else if (finalizer.children.length != 0): return js_print_error(diagnostics, finalizer)
		return 1
	if (js_kind(node, c"break") || js_kind(node, c"continue")):
		if (count != 0 || strlen(node.text) != 0): return js_print_error(diagnostics, node)
		string_append(out, node.kind)
		string_append(out, c";")
		return 1
	if (js_kind(node, c"while") || js_kind(node, c"do_while")):
		if (count != 2): return js_print_error(diagnostics, node)
		if (js_kind(node, c"do_while")):
			string_append(out, c"do ")
			if (js_print_statement(out, node.children[1], depth, diagnostics) == 0): return 0
			string_append(out, c" while (")
		else: string_append(out, c"while (")
		if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c")")
		if (js_kind(node, c"do_while")):
			string_append(out, c";")
			return 1
		string_append(out, c" ")
		return js_print_statement(out, node.children[1], depth, diagnostics)
	if (js_kind(node, c"for")):
		if (count != 4): return js_print_error(diagnostics, node)
		string_append(out, c"for (")
		for i in range(3):
			js_node* part = node.children[i]
			if (js_kind(part, c"variable") && i == 0):
				if (js_print_statement(out, part, depth, diagnostics) == 0): return 0
				# The declaration printer owns its trailing semicolon.
			else:
				if (js_kind(part, c"empty")):
					if (part.children.length != 0): return js_print_error(diagnostics, part)
				else if (js_print_expression(out, part, diagnostics) == 0): return 0
				if (i < 2): string_append(out, c";")
			if (i < 2): string_append(out, c" ")
		string_append(out, c") ")
		return js_print_statement(out, node.children[3], depth, diagnostics)
	if (js_kind(node, c"if")):
		if (count < 2 || count > 3): return js_print_error(diagnostics, node)
		string_append(out, c"if (")
		if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c") ")
		int wrap = count == 3 && js_print_dangling_else(node.children[1])
		if (wrap): string_append(out, c"{ ")
		if (js_print_statement(out, node.children[1], depth, diagnostics) == 0): return 0
		if (wrap): string_append(out, c" }")
		if (count == 3):
			string_append(out, c" else ")
			if (js_print_statement(out, node.children[2], depth, diagnostics) == 0): return 0
		return 1
	if (js_kind(node, c"export")):
		if (count != 1 || (js_kind(node.children[0], c"function") == 0 && js_kind(node.children[0], c"variable") == 0)): return js_print_error(diagnostics, node)
		string_append(out, c"export ")
		return js_print_statement(out, node.children[0], depth, diagnostics)
	if (js_kind(node, c"import")):
		if (count > 1 || utf8_validate_bytes(node.text, strlen(node.text)) == 0): return js_print_error(diagnostics, node)
		string_append(out, c"import ")
		if (count == 1):
			if (js_kind(node.children[0], c"identifier") == 0 || js_print_identifier_valid(node.children[0].text, 1) == 0): return js_print_error(diagnostics, node)
			if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
			string_append(out, c" from ")
		js_print_quoted(out, node.text)
		string_append(out, c";")
		return 1
	return js_print_error(diagnostics, node)


char* js_print(js_node* root, pg_diagnostics* diagnostics):
	string_builder* out = string_new()
	int valid = 1
	if (root != 0 && js_kind(root, c"program")):
		for i in range(root.children.length):
			if (js_print_statement(out, root.children[i], 0, diagnostics) == 0):
				valid = 0
				break
			string_append(out, c"\n")
	else: valid = js_print_statement(out, root, 0, diagnostics)
	if (valid == 0):
		free(out.data)
		free(out)
		return 0
	char* text = out.data
	free(out)
	return text
