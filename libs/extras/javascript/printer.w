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
omitted for clauses = empty; break/continue have optional target text and no children;
label = decoded label text with one statement child;
function_expression(optional name) = parameters, block;
arrow = parameters, expression-or-block; for_of(let/const) = identifier, iterable, body;
try = block, catch-or-empty, finally-block-or-empty; catch(name) = block;
string_utf16 owns explicit code units in string_units;
import(specifier) = [default-binding] [namespace|named]; call = callee, arguments...;
member/computed_member = receiver, property; property(key) = value;
template = template_text(raw spelling) and expression children.
property_shorthand(name) preserves shorthand (notably __proto__). The
string_non_directive("use strict") node retains an escaped spelling so
printing does not turn an ordinary string into a strict-mode directive.
Classes, async/generator functions, methods/accessors, computed keys,
patterns, switch/with/for-in, module declarations and the other lowered
kinds are tabulated in docs/projects/javascript.md ("Build and lower ASTs").
*/
import libs.extras.javascript.ast
import libs.extras.javascript.lexical
import libs.extras.javascript.validation
import structures.string


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
int js_print_block(string_builder* out, js_node* node, int depth, pg_diagnostics* diagnostics);
int js_print_target(string_builder* out, js_node* node, pg_diagnostics* diagnostics);
int js_print_chain(string_builder* out, js_node* node, pg_diagnostics* diagnostics);


# Function-family kinds: 1 = function, 2 = async, 4 = generator, 8 = expression.
int js_print_function_flags(js_node* node):
	char* kind = node.kind
	if (strcmp(kind, c"function") == 0): return 1
	if (strcmp(kind, c"function_expression") == 0): return 9
	if (strcmp(kind, c"async_function") == 0): return 3
	if (strcmp(kind, c"async_function_expression") == 0): return 11
	if (strcmp(kind, c"generator_function") == 0): return 5
	if (strcmp(kind, c"generator_function_expression") == 0): return 13
	if (strcmp(kind, c"async_generator_function") == 0): return 7
	if (strcmp(kind, c"async_generator_function_expression") == 0): return 15
	return 0


int js_print_expression_list(string_builder* out, js_node* node, int start, pg_diagnostics* diagnostics):
	for i in range(start, node.children.length):
		if (i > start): string_append(out, c", ")
		if (js_print_expression(out, node.children[i], diagnostics) == 0): return 0
	return 1


# Binding patterns: identifier, object/array patterns, defaults and rest.
int js_print_binding(string_builder* out, js_node* node, pg_diagnostics* diagnostics):
	if (node == 0): return js_print_error(diagnostics, node)
	int count = node.children.length
	if (js_kind(node, c"identifier")):
		if (count != 0 || js_print_identifier_valid(node.text, 1) == 0): return js_print_error(diagnostics, node)
		string_append(out, node.text)
		return 1
	if (js_kind(node, c"default_pattern")):
		if (count != 2 || js_kind(node.children[0], c"default_pattern") || js_kind(node.children[0], c"rest")): return js_print_error(diagnostics, node)
		if (js_print_binding(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c" = ")
		return js_print_expression(out, node.children[1], diagnostics)
	if (js_kind(node, c"rest")):
		if (count != 1 || js_kind(node.children[0], c"default_pattern") || js_kind(node.children[0], c"rest")): return js_print_error(diagnostics, node)
		string_append(out, c"...")
		return js_print_binding(out, node.children[0], diagnostics)
	if (js_kind(node, c"object_pattern")):
		string_append(out, c"{")
		for i in range(count):
			js_node* item = node.children[i]
			if (i > 0): string_append(out, c", ")
			if (js_kind(item, c"rest")):
				if (i != count - 1 || js_kind(item.children[0], c"identifier") == 0): return js_print_error(diagnostics, item)
				if (js_print_binding(out, item, diagnostics) == 0): return 0
				continue
			if (js_kind(item, c"pattern_property")):
				if (item.children.length != 1 || utf8_validate_bytes(item.text, strlen(item.text)) == 0): return js_print_error(diagnostics, item)
				js_print_quoted(out, item.text)
			else if (js_kind(item, c"computed_pattern_property")):
				if (item.children.length != 2): return js_print_error(diagnostics, item)
				string_append(out, c"[")
				if (js_print_expression(out, item.children[0], diagnostics) == 0): return 0
				string_append(out, c"]")
			else: return js_print_error(diagnostics, item)
			string_append(out, c": ")
			if (js_print_binding(out, item.children[item.children.length - 1], diagnostics) == 0): return 0
		string_append(out, c"}")
		return 1
	if (js_kind(node, c"array_pattern")):
		string_append(out, c"[")
		for i in range(count):
			js_node* item = node.children[i]
			if (i > 0): string_append(out, c", ")
			if (js_kind(item, c"empty")):
				if (item.children.length != 0): return js_print_error(diagnostics, item)
				# A final hole needs its own comma to survive reparsing.
				if (i == count - 1): string_append(out, c",")
				continue
			if (js_kind(item, c"rest") && i != count - 1): return js_print_error(diagnostics, item)
			if (js_print_binding(out, item, diagnostics) == 0): return 0
		string_append(out, c"]")
		return 1
	return js_print_error(diagnostics, node)


int js_print_parameters(string_builder* out, js_node* node, pg_diagnostics* diagnostics):
	if (js_kind(node, c"parameters") == 0): return js_print_error(diagnostics, node)
	string_append(out, c"(")
	for i in range(node.children.length):
		if (i > 0): string_append(out, c", ")
		if (js_kind(node.children[i], c"rest") && i != node.children.length - 1): return js_print_error(diagnostics, node)
		if (js_print_binding(out, node.children[i], diagnostics) == 0): return 0
	string_append(out, c")")
	return 1


# Prints any function-family node. Names are required for declarations
# unless allow_anonymous is set (export default).
int js_print_function(string_builder* out, js_node* node, int depth, int allow_anonymous, pg_diagnostics* diagnostics):
	int flags = js_print_function_flags(node)
	if (flags == 0 || node.children.length != 2): return js_print_error(diagnostics, node)
	if (strlen(node.text) == 0):
		if ((flags & 8) == 0 && allow_anonymous == 0): return js_print_error(diagnostics, node)
	else if (js_print_identifier_valid(node.text, 1) == 0): return js_print_error(diagnostics, node)
	if (flags & 2): string_append(out, c"async ")
	string_append(out, c"function")
	if (flags & 4): string_append(out, c"*")
	string_append(out, c" ")
	string_append(out, node.text)
	if (js_print_parameters(out, node.children[0], diagnostics) == 0): return 0
	string_append(out, c" ")
	return js_print_block(out, node.children[1], depth, diagnostics)


int js_print_key(string_builder* out, js_node* key, pg_diagnostics* diagnostics):
	if (js_kind(key, c"property_key")):
		if (key.children.length != 0 || utf8_validate_bytes(key.text, strlen(key.text)) == 0): return js_print_error(diagnostics, key)
		js_print_quoted(out, key.text)
		return 1
	if (js_kind(key, c"computed_key") == 0 || key.children.length != 1): return js_print_error(diagnostics, key)
	string_append(out, c"[")
	if (js_print_expression(out, key.children[0], diagnostics) == 0): return 0
	string_append(out, c"]")
	return 1


# method/static_method(get|set|method) = key, unnamed function expression.
int js_print_method(string_builder* out, js_node* node, int depth, int in_class, pg_diagnostics* diagnostics):
	int is_static = js_kind(node, c"static_method")
	if ((js_kind(node, c"method") == 0 && is_static == 0) || (is_static && in_class == 0) || node.children.length != 2): return js_print_error(diagnostics, node)
	js_node* routine = node.children[1]
	int flags = js_print_function_flags(routine)
	if ((flags & 8) == 0 || strlen(routine.text) != 0 || routine.children.length != 2): return js_print_error(diagnostics, node)
	js_node* parameters = routine.children[0]
	if (js_kind(parameters, c"parameters") == 0): return js_print_error(diagnostics, node)
	int accessor = strcmp(node.text, c"get") == 0 || strcmp(node.text, c"set") == 0
	if (accessor == 0 && strcmp(node.text, c"method") != 0): return js_print_error(diagnostics, node)
	if (accessor && flags != 9): return js_print_error(diagnostics, node)
	if (strcmp(node.text, c"get") == 0 && parameters.children.length != 0): return js_print_error(diagnostics, node)
	if (strcmp(node.text, c"set") == 0 && (parameters.children.length != 1 || js_kind(parameters.children[0], c"rest"))): return js_print_error(diagnostics, node)
	if (is_static): string_append(out, c"static ")
	if (accessor):
		string_append(out, node.text)
		string_append(out, c" ")
	if (flags & 2): string_append(out, c"async ")
	if (flags & 4): string_append(out, c"*")
	if (js_print_key(out, node.children[0], diagnostics) == 0): return 0
	if (js_print_parameters(out, parameters, diagnostics) == 0): return 0
	string_append(out, c" ")
	return js_print_block(out, routine.children[1], depth, diagnostics)


# class/class_expression(name) = heritage-or-empty, method/static_method...
int js_print_class(string_builder* out, js_node* node, int depth, int allow_anonymous, pg_diagnostics* diagnostics):
	int count = node.children.length
	if (count < 1): return js_print_error(diagnostics, node)
	if (strlen(node.text) == 0):
		if (js_kind(node, c"class") && allow_anonymous == 0): return js_print_error(diagnostics, node)
	else if (js_print_identifier_valid(node.text, 1) == 0): return js_print_error(diagnostics, node)
	string_append(out, c"class ")
	if (strlen(node.text) != 0):
		string_append(out, node.text)
		string_append(out, c" ")
	js_node* heritage = node.children[0]
	if (js_kind(heritage, c"empty") == 0):
		string_append(out, c"extends (")
		if (js_print_expression(out, heritage, diagnostics) == 0): return 0
		string_append(out, c") ")
	else if (heritage.children.length != 0): return js_print_error(diagnostics, heritage)
	string_append(out, c"{\n")
	for i in range(1, count):
		js_print_indent(out, depth + 1)
		if (js_print_method(out, node.children[i], depth + 1, 1, diagnostics) == 0): return 0
		string_append(out, c"\n")
	js_print_indent(out, depth)
	string_append(out, c"}")
	return 1


int js_print_chain_part_kind(js_node* node):
	return js_kind(node, c"member") || js_kind(node, c"computed_member") || js_kind(node, c"call") || js_kind(node, c"optional_member") || js_kind(node, c"optional_computed_member") || js_kind(node, c"optional_call")


# Receivers are parenthesized except super, which is only valid bare.
int js_print_receiver(string_builder* out, js_node* node, int chain, pg_diagnostics* diagnostics):
	if (js_kind(node, c"super")):
		if (node.children.length != 0): return js_print_error(diagnostics, node)
		string_append(out, c"super")
		return 1
	if (chain && js_print_chain_part_kind(node)): return js_print_chain(out, node, diagnostics)
	string_append(out, c"(")
	if (js_print_expression(out, node, diagnostics) == 0): return 0
	string_append(out, c")")
	return 1


int js_print_member_name(string_builder* out, js_node* node, pg_diagnostics* diagnostics):
	if (js_kind(node, c"identifier") == 0): return js_print_error(diagnostics, node)
	char* name = node.text
	if (node.children.length != 0 || strlen(name) == 0 || pg_lexer_matcher_js_identifier(name, 0) != strlen(name)): return js_print_error(diagnostics, node)
	string_append(out, name)
	return 1


# Within an optional chain the operations to the left of ?. stay unparenthesized:
# (a?.b).c and a?.b.c differ when a is nullish.
int js_print_chain(string_builder* out, js_node* node, pg_diagnostics* diagnostics):
	int count = node.children.length
	if (js_print_chain_part_kind(node) == 0 || count < 1): return js_print_error(diagnostics, node)
	int optional = js_kind(node, c"optional_member") || js_kind(node, c"optional_computed_member") || js_kind(node, c"optional_call")
	if (js_kind(node.children[0], c"super") && optional): return js_print_error(diagnostics, node)
	if (js_print_receiver(out, node.children[0], 1, diagnostics) == 0): return 0
	if (optional): string_append(out, c"?.")
	if (js_kind(node, c"call") || js_kind(node, c"optional_call")):
		string_append(out, c"(")
		if (js_print_expression_list(out, node, 1, diagnostics) == 0): return 0
		string_append(out, c")")
		return 1
	if (count != 2): return js_print_error(diagnostics, node)
	if (js_kind(node, c"member")):
		string_append(out, c".")
		return js_print_member_name(out, node.children[1], diagnostics)
	if (js_kind(node, c"optional_member")): return js_print_member_name(out, node.children[1], diagnostics)
	string_append(out, c"[")
	if (js_print_expression(out, node.children[1], diagnostics) == 0): return 0
	string_append(out, c"]")
	return 1


# Destructuring assignment targets (= and for-in/of heads) are array/object
# literals printed without the protective parentheses of ordinary objects.
int js_print_target(string_builder* out, js_node* node, pg_diagnostics* diagnostics):
	if (node == 0): return js_print_error(diagnostics, node)
	int count = node.children.length
	if (js_kind(node, c"array")):
		string_append(out, c"[")
		for i in range(count):
			js_node* item = node.children[i]
			if (i > 0): string_append(out, c", ")
			if (js_kind(item, c"empty")):
				if (item.children.length != 0): return js_print_error(diagnostics, item)
				if (i == count - 1): string_append(out, c",")
				continue
			if (js_kind(item, c"spread")):
				if (i != count - 1 || item.children.length != 1): return js_print_error(diagnostics, item)
				string_append(out, c"...")
				if (js_print_target(out, item.children[0], diagnostics) == 0): return 0
				continue
			if (js_print_target(out, item, diagnostics) == 0): return 0
		string_append(out, c"]")
		return 1
	if (js_kind(node, c"object")):
		string_append(out, c"{")
		for i in range(count):
			js_node* item = node.children[i]
			if (i > 0): string_append(out, c", ")
			if (js_kind(item, c"property_shorthand")):
				if (item.children.length > 1 || js_print_identifier_valid(item.text, 1) == 0): return js_print_error(diagnostics, item)
				string_append(out, item.text)
				if (item.children.length == 1):
					string_append(out, c" = ")
					if (js_print_expression(out, item.children[0], diagnostics) == 0): return 0
				continue
			if (js_kind(item, c"spread")):
				if (i != count - 1 || item.children.length != 1): return js_print_error(diagnostics, item)
				string_append(out, c"...")
				if (js_print_target(out, item.children[0], diagnostics) == 0): return 0
				continue
			if (js_kind(item, c"property")):
				if (item.children.length != 1 || utf8_validate_bytes(item.text, strlen(item.text)) == 0): return js_print_error(diagnostics, item)
				js_print_quoted(out, item.text)
			else if (js_kind(item, c"computed_property")):
				if (item.children.length != 2): return js_print_error(diagnostics, item)
				string_append(out, c"[")
				if (js_print_expression(out, item.children[0], diagnostics) == 0): return 0
				string_append(out, c"]")
			else: return js_print_error(diagnostics, item)
			string_append(out, c": ")
			if (js_print_target(out, item.children[item.children.length - 1], diagnostics) == 0): return 0
		string_append(out, c"}")
		return 1
	if (js_kind(node, c"assignment")):
		# Element defaults inside patterns: target = initializer.
		if (count != 2 || strcmp(node.text, c"=") != 0): return js_print_error(diagnostics, node)
		if (js_print_target(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c" = ")
		return js_print_expression(out, node.children[1], diagnostics)
	if (js_kind(node, c"identifier")):
		# Parentheses keep contextual names (async, let) out of statement heads.
		string_append(out, c"(")
		if (js_print_expression(out, node, diagnostics) == 0): return 0
		string_append(out, c")")
		return 1
	if (js_kind(node, c"member") || js_kind(node, c"computed_member")): return js_print_expression(out, node, diagnostics)
	return js_print_error(diagnostics, node)


int js_print_object_entry(string_builder* out, js_node* property, pg_diagnostics* diagnostics):
	if (js_kind(property, c"property_shorthand")):
		if (property.children.length != 0 || js_print_identifier_valid(property.text, 0) == 0): return js_print_error(diagnostics, property)
		string_append(out, property.text)
		return 1
	if (js_kind(property, c"spread")):
		if (property.children.length != 1): return js_print_error(diagnostics, property)
		string_append(out, c"...")
		return js_print_expression(out, property.children[0], diagnostics)
	if (js_kind(property, c"method")): return js_print_method(out, property, 0, 0, diagnostics)
	if (js_kind(property, c"computed_property")):
		if (property.children.length != 2): return js_print_error(diagnostics, property)
		string_append(out, c"[")
		if (js_print_expression(out, property.children[0], diagnostics) == 0): return 0
		string_append(out, c"]: ")
		return js_print_expression(out, property.children[1], diagnostics)
	if (js_kind(property, c"property") == 0 || property.children.length != 1): return js_print_error(diagnostics, property)
	if (utf8_validate_bytes(property.text, strlen(property.text)) == 0): return js_print_error(diagnostics, property)
	js_print_quoted(out, property.text)
	string_append(out, c": ")
	return js_print_expression(out, property.children[0], diagnostics)


int js_print_template(string_builder* out, js_node* node, int tagged, pg_diagnostics* diagnostics):
	if (js_kind(node, c"template") == 0): return js_print_error(diagnostics, node)
	string_append(out, c"`")
	for i in range(node.children.length):
		js_node* part = node.children[i]
		if (js_kind(part, c"template_text")):
			if (part.children.length != 0): return js_print_error(diagnostics, part)
			# Tagged templates may carry escapes whose cooked value is undefined.
			if (tagged):
				if (pg_lexer_matcher_js_template_text(part.text, 0) != strlen(part.text)): return js_print_error(diagnostics, part)
			else if (js_print_template_valid(part.text) == 0): return js_print_error(diagnostics, part)
			if (i > 0 && js_kind(node.children[i - 1], c"template_text")): return js_print_error(diagnostics, part)
			string_append(out, part.text)
		else:
			string_append(out, c"${")
			if (js_print_expression(out, part, diagnostics) == 0): return 0
			string_append(out, c"}")
	string_append(out, c"`")
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
	if (js_kind(node, c"arrow") || js_kind(node, c"async_arrow")):
		if (count != 2 || strlen(node.text) != 0): return js_print_error(diagnostics, node)
		string_append(out, c"(")
		if (js_kind(node, c"async_arrow")): string_append(out, c"async ")
		if (js_print_parameters(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c" => ")
		if (js_kind(node.children[1], c"block")):
			if (js_print_statement(out, node.children[1], 0, diagnostics) == 0): return 0
		else:
			string_append(out, c"(")
			if (js_print_expression(out, node.children[1], diagnostics) == 0): return 0
			string_append(out, c")")
		string_append(out, c")")
		return 1
	if (js_print_function_flags(node) & 8):
		string_append(out, c"(")
		if (js_print_function(out, node, 0, 0, diagnostics) == 0): return 0
		string_append(out, c")")
		return 1
	if (js_kind(node, c"class_expression")):
		string_append(out, c"(")
		if (js_print_class(out, node, 0, 1, diagnostics) == 0): return 0
		string_append(out, c")")
		return 1
	if (js_kind(node, c"identifier")):
		if (count != 0 || js_print_identifier_valid(node.text, 0) == 0): return js_print_error(diagnostics, node)
		string_append(out, node.text)
		return 1
	if (js_kind(node, c"number") || js_kind(node, c"regex") || js_kind(node, c"literal") || js_kind(node, c"bigint")):
		if (count != 0 || strlen(node.text) == 0): return js_print_error(diagnostics, node)
		if (js_kind(node, c"number") && pg_lexer_matcher_js_number(node.text, 0) != strlen(node.text)): return js_print_error(diagnostics, node)
		if (js_kind(node, c"regex") && pg_lexer_matcher_js_regex(node.text, 0) != strlen(node.text)): return js_print_error(diagnostics, node)
		if (js_kind(node, c"literal") && strcmp(node.text, c"true") != 0 && strcmp(node.text, c"false") != 0 && strcmp(node.text, c"null") != 0 && strcmp(node.text, c"this") != 0): return js_print_error(diagnostics, node)
		if (js_kind(node, c"bigint")):
			char* spelling = strjoin(node.text, c"n")
			int valid = pg_lexer_matcher_js_number(spelling, 0) == strlen(spelling)
			free(spelling)
			if (valid == 0): return js_print_error(diagnostics, node)
		string_append(out, node.text)
		if (js_kind(node, c"bigint")): string_append(out, c"n")
		return 1
	if (js_kind(node, c"new_target") || js_kind(node, c"import_meta")):
		if (count != 0): return js_print_error(diagnostics, node)
		if (js_kind(node, c"new_target")): string_append(out, c"new.target")
		else: string_append(out, c"import.meta")
		return 1
	if (js_kind(node, c"import_call")):
		if (count != 1): return js_print_error(diagnostics, node)
		string_append(out, c"import(")
		if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c")")
		return 1
	if (js_kind(node, c"string_non_directive")):
		if (count != 0 || strcmp(node.text, c"use strict") != 0): return js_print_error(diagnostics, node)
		string_append(out, c"\"use\\x20strict\"")
		return 1
	if (js_kind(node, c"string")):
		if (count != 0 || utf8_validate_bytes(node.text, strlen(node.text)) == 0): return js_print_error(diagnostics, node)
		js_print_quoted(out, node.text)
		return 1
	if (js_kind(node, c"assignment") && count == 2 && strcmp(node.text, c"=") == 0 && (js_kind(node.children[0], c"array") || js_kind(node.children[0], c"object"))):
		string_append(out, c"(")
		if (js_print_target(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c" = ")
		if (js_print_expression(out, node.children[1], diagnostics) == 0): return 0
		string_append(out, c")")
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
	if (js_kind(node, c"unary") || js_kind(node, c"update_prefix") || js_kind(node, c"update_postfix") || js_kind(node, c"await")):
		if (count != 1): return js_print_error(diagnostics, node)
		if (js_kind(node, c"await")):
			if (strlen(node.text) != 0): return js_print_error(diagnostics, node)
			string_append(out, c"(await ")
			if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
			string_append(out, c")")
			return 1
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
	if (js_kind(node, c"yield")):
		if (count > 1 || (strcmp(node.text, c"") != 0 && strcmp(node.text, c"*") != 0) || (count == 0 && strlen(node.text) != 0)): return js_print_error(diagnostics, node)
		string_append(out, c"(yield")
		string_append(out, node.text)
		if (count == 1):
			string_append(out, c" ")
			if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
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
	if (js_kind(node, c"spread")):
		if (count != 1): return js_print_error(diagnostics, node)
		string_append(out, c"...")
		return js_print_expression(out, node.children[0], diagnostics)
	if (js_kind(node, c"construct")):
		if (count < 1 || js_kind(node.children[0], c"super")): return js_print_error(diagnostics, node)
		# The parenthesized callee keeps calls inside it from becoming arguments.
		string_append(out, c"(new (")
		if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c")(")
		if (js_print_expression_list(out, node, 1, diagnostics) == 0): return 0
		string_append(out, c"))")
		return 1
	if (js_kind(node, c"call")):
		if (count < 1): return js_print_error(diagnostics, node)
		js_node* callee = node.children[0]
		if (js_kind(callee, c"super")):
			if (callee.children.length != 0): return js_print_error(diagnostics, callee)
			string_append(out, c"super")
		else if (js_kind(callee, c"optional_chain")):
			string_append(out, c"(")
			if (js_print_expression(out, callee, diagnostics) == 0): return 0
			string_append(out, c")")
		else if (js_print_expression(out, callee, diagnostics) == 0): return 0
		string_append(out, c"(")
		if (js_print_expression_list(out, node, 1, diagnostics) == 0): return 0
		string_append(out, c")")
		return 1
	if (js_kind(node, c"member") || js_kind(node, c"computed_member")):
		if (count != 2): return js_print_error(diagnostics, node)
		# Parentheses also make numeric literal receivers unambiguous.
		if (js_print_receiver(out, node.children[0], 0, diagnostics) == 0): return 0
		if (js_kind(node, c"member")):
			string_append(out, c".")
			return js_print_member_name(out, node.children[1], diagnostics)
		string_append(out, c"[")
		if (js_print_expression(out, node.children[1], diagnostics) == 0): return 0
		string_append(out, c"]")
		return 1
	if (js_kind(node, c"optional_chain")):
		if (count != 1): return js_print_error(diagnostics, node)
		return js_print_chain(out, node.children[0], diagnostics)
	if (js_kind(node, c"tagged_template")):
		if (count != 2 || js_kind(node.children[0], c"optional_chain")): return js_print_error(diagnostics, node)
		if (js_print_receiver(out, node.children[0], 0, diagnostics) == 0): return 0
		return js_print_template(out, node.children[1], 1, diagnostics)
	if (js_kind(node, c"array")):
		string_append(out, c"[")
		for i in range(count):
			if (i > 0): string_append(out, c", ")
			js_node* item = node.children[i]
			if (js_kind(item, c"empty")):
				if (item.children.length != 0): return js_print_error(diagnostics, item)
				if (i == count - 1): string_append(out, c",")
				continue
			if (js_print_expression(out, item, diagnostics) == 0): return 0
		string_append(out, c"]")
		return 1
	if (js_kind(node, c"object")):
		string_append(out, c"({")
		for i in range(count):
			if (i > 0): string_append(out, c", ")
			if (js_print_object_entry(out, node.children[i], diagnostics) == 0): return 0
		string_append(out, c"})")
		return 1
	if (js_kind(node, c"template")): return js_print_template(out, node, 0, diagnostics)
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
	if ((js_kind(node, c"label") || js_kind(node, c"while") || js_kind(node, c"for") || js_kind(node, c"for_of") || js_kind(node, c"for_in") || js_kind(node, c"for_await_of") || js_kind(node, c"with")) && node.children.length > 0): return js_print_dangling_else(node.children[node.children.length - 1])
	if (js_kind(node, c"if") == 0): return 0
	if (node.children.length == 2): return 1
	if (node.children.length == 3): return js_print_dangling_else(node.children[2])
	return 0


int js_print_variable(string_builder* out, js_node* node, int depth, pg_diagnostics* diagnostics):
	int count = node.children.length
	if (count == 0 || (strcmp(node.text, c"const") != 0 && strcmp(node.text, c"let") != 0 && strcmp(node.text, c"var") != 0)): return js_print_error(diagnostics, node)
	string_append(out, node.text)
	string_append(out, c" ")
	for i in range(count):
		js_node* binding = node.children[i]
		if (js_kind(binding, c"declarator") == 0 || binding.children.length < 1 || binding.children.length > 2): return js_print_error(diagnostics, binding)
		js_node* target = binding.children[0]
		if (js_kind(target, c"identifier") == 0 && js_kind(target, c"object_pattern") == 0 && js_kind(target, c"array_pattern") == 0): return js_print_error(diagnostics, binding)
		if (strcmp(node.text, c"const") == 0 && binding.children.length != 2): return js_print_error(diagnostics, binding)
		if (i > 0): string_append(out, c", ")
		if (js_print_binding(out, target, diagnostics) == 0): return 0
		if (binding.children.length == 2):
			string_append(out, c" = ")
			if (js_print_expression(out, binding.children[1], diagnostics) == 0): return 0
	string_append(out, c";")
	return 1


int js_print_import(string_builder* out, js_node* node, pg_diagnostics* diagnostics):
	int count = node.children.length
	if (count > 2 || utf8_validate_bytes(node.text, strlen(node.text)) == 0): return js_print_error(diagnostics, node)
	string_append(out, c"import ")
	for i in range(count):
		js_node* part = node.children[i]
		if (i > 0): string_append(out, c", ")
		if (js_kind(part, c"identifier")):
			if (i != 0 || js_print_binding(out, part, diagnostics) == 0): return js_print_error(diagnostics, node)
		else if (js_kind(part, c"import_namespace")):
			if (part.children.length != 1 || i != count - 1): return js_print_error(diagnostics, part)
			string_append(out, c"* as ")
			if (js_print_binding(out, part.children[0], diagnostics) == 0): return 0
		else if (js_kind(part, c"import_named")):
			if (i != count - 1): return js_print_error(diagnostics, part)
			string_append(out, c"{")
			for j in range(part.children.length):
				js_node* entry = part.children[j]
				if (j > 0): string_append(out, c", ")
				if (js_kind(entry, c"import_specifier") == 0 || entry.children.length != 1 || pg_lexer_matcher_js_identifier(entry.text, 0) != strlen(entry.text) || strlen(entry.text) == 0): return js_print_error(diagnostics, entry)
				string_append(out, entry.text)
				string_append(out, c" as ")
				if (js_print_binding(out, entry.children[0], diagnostics) == 0): return 0
			string_append(out, c"}")
		else: return js_print_error(diagnostics, part)
	if (count > 0): string_append(out, c" from ")
	js_print_quoted(out, node.text)
	string_append(out, c";")
	return 1


int js_print_export_name(string_builder* out, js_node* node, pg_diagnostics* diagnostics):
	if (js_kind(node, c"property_key") == 0 || node.children.length != 0 || strlen(node.text) == 0 || pg_lexer_matcher_js_identifier(node.text, 0) != strlen(node.text)): return js_print_error(diagnostics, node)
	string_append(out, node.text)
	return 1


int js_print_export(string_builder* out, js_node* node, int depth, pg_diagnostics* diagnostics):
	int count = node.children.length
	if (js_kind(node, c"export")):
		if (count != 1): return js_print_error(diagnostics, node)
		js_node* declaration = node.children[0]
		if (js_kind(declaration, c"variable") == 0 && js_kind(declaration, c"class") == 0 && (js_print_function_flags(declaration) == 0 || (js_print_function_flags(declaration) & 8))): return js_print_error(diagnostics, node)
		string_append(out, c"export ")
		return js_print_statement(out, declaration, depth, diagnostics)
	if (js_kind(node, c"export_default")):
		if (count != 1): return js_print_error(diagnostics, node)
		js_node* value = node.children[0]
		string_append(out, c"export default ")
		if (js_kind(value, c"class")): return js_print_class(out, value, depth, 1, diagnostics)
		int flags = js_print_function_flags(value)
		if (flags != 0 && (flags & 8) == 0): return js_print_function(out, value, depth, 1, diagnostics)
		if (js_print_expression(out, value, diagnostics) == 0): return 0
		string_append(out, c";")
		return 1
	if (js_kind(node, c"export_all")):
		if (count > 1 || utf8_validate_bytes(node.text, strlen(node.text)) == 0): return js_print_error(diagnostics, node)
		string_append(out, c"export *")
		if (count == 1):
			string_append(out, c" as ")
			if (js_print_export_name(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c" from ")
		js_print_quoted(out, node.text)
		string_append(out, c";")
		return 1
	if (js_kind(node, c"export_named") == 0 && js_kind(node, c"export_from") == 0): return js_print_error(diagnostics, node)
	if (js_kind(node, c"export_named") && strlen(node.text) != 0): return js_print_error(diagnostics, node)
	if (utf8_validate_bytes(node.text, strlen(node.text)) == 0): return js_print_error(diagnostics, node)
	string_append(out, c"export {")
	for i in range(count):
		js_node* entry = node.children[i]
		if (i > 0): string_append(out, c", ")
		if (js_kind(entry, c"export_specifier") == 0 || entry.children.length != 1 || strlen(entry.text) == 0 || pg_lexer_matcher_js_identifier(entry.text, 0) != strlen(entry.text)): return js_print_error(diagnostics, entry)
		string_append(out, entry.text)
		string_append(out, c" as ")
		if (js_print_export_name(out, entry.children[0], diagnostics) == 0): return 0
	string_append(out, c"}")
	if (js_kind(node, c"export_from")):
		string_append(out, c" from ")
		js_print_quoted(out, node.text)
	string_append(out, c";")
	return 1


int js_print_switch(string_builder* out, js_node* node, int depth, pg_diagnostics* diagnostics):
	int count = node.children.length
	if (count < 1): return js_print_error(diagnostics, node)
	string_append(out, c"switch (")
	if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
	string_append(out, c") {\n")
	int defaults = 0
	for i in range(1, count):
		js_node* clause = node.children[i]
		int start = 0
		js_print_indent(out, depth + 1)
		if (js_kind(clause, c"case")):
			if (clause.children.length < 1): return js_print_error(diagnostics, clause)
			string_append(out, c"case ")
			if (js_print_expression(out, clause.children[0], diagnostics) == 0): return 0
			start = 1
		else if (js_kind(clause, c"default")):
			defaults = defaults + 1
			if (defaults > 1): return js_print_error(diagnostics, clause)
			string_append(out, c"default")
		else: return js_print_error(diagnostics, clause)
		string_append(out, c":\n")
		for j in range(start, clause.children.length):
			js_print_indent(out, depth + 2)
			if (js_print_statement(out, clause.children[j], depth + 2, diagnostics) == 0): return 0
			string_append(out, c"\n")
	js_print_indent(out, depth)
	string_append(out, c"}")
	return 1


# for_in/for_of/for_await_of heads: declaration + binding, or an assignment target.
int js_print_for_each(string_builder* out, js_node* node, int depth, pg_diagnostics* diagnostics):
	if (node.children.length != 3): return js_print_error(diagnostics, node)
	char* declaration = node.text
	if (strcmp(declaration, c"let") != 0 && strcmp(declaration, c"const") != 0 && strcmp(declaration, c"var") != 0 && strlen(declaration) != 0): return js_print_error(diagnostics, node)
	string_append(out, c"for ")
	if (js_kind(node, c"for_await_of")): string_append(out, c"await ")
	string_append(out, c"(")
	if (strlen(declaration) != 0):
		js_node* binding = node.children[0]
		if (js_kind(binding, c"identifier") == 0 && js_kind(binding, c"object_pattern") == 0 && js_kind(binding, c"array_pattern") == 0): return js_print_error(diagnostics, node)
		string_append(out, declaration)
		string_append(out, c" ")
		if (js_print_binding(out, binding, diagnostics) == 0): return 0
	else if (js_print_target(out, node.children[0], diagnostics) == 0): return 0
	if (js_kind(node, c"for_in")): string_append(out, c" in (")
	else: string_append(out, c" of (")
	if (js_print_expression(out, node.children[1], diagnostics) == 0): return 0
	string_append(out, c")) ")
	return js_print_statement(out, node.children[2], depth, diagnostics)


int js_print_statement(string_builder* out, js_node* node, int depth, pg_diagnostics* diagnostics):
	if (node == 0): return js_print_error(diagnostics, node)
	int count = node.children.length
	if (js_kind(node, c"block")): return js_print_block(out, node, depth, diagnostics)
	if (js_kind(node, c"empty") || js_kind(node, c"debugger")):
		if (count != 0): return js_print_error(diagnostics, node)
		if (js_kind(node, c"debugger")): string_append(out, c"debugger")
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
	if (js_kind(node, c"variable")): return js_print_variable(out, node, depth, diagnostics)
	int flags = js_print_function_flags(node)
	if (flags != 0):
		# Function expressions in statement position remain expressions only
		# when wrapped by an expression_statement.
		if (flags & 8): return js_print_error(diagnostics, node)
		return js_print_function(out, node, depth, 0, diagnostics)
	if (js_kind(node, c"class")): return js_print_class(out, node, depth, 0, diagnostics)
	if (js_kind(node, c"try")):
		if (count != 3 || js_kind(node.children[0], c"block") == 0): return js_print_error(diagnostics, node)
		js_node* handler = node.children[1]
		js_node* finalizer = node.children[2]
		if (js_kind(handler, c"empty") && js_kind(finalizer, c"empty")): return js_print_error(diagnostics, node)
		string_append(out, c"try ")
		if (js_print_block(out, node.children[0], depth, diagnostics) == 0): return 0
		if (js_kind(handler, c"empty") == 0):
			if (js_kind(handler, c"catch") == 0 || handler.children.length < 1 || handler.children.length > 2): return js_print_error(diagnostics, handler)
			string_append(out, c" catch")
			if (handler.children.length == 2):
				if (strlen(handler.text) != 0 || (js_kind(handler.children[0], c"object_pattern") == 0 && js_kind(handler.children[0], c"array_pattern") == 0)): return js_print_error(diagnostics, handler)
				string_append(out, c" (")
				if (js_print_binding(out, handler.children[0], diagnostics) == 0): return 0
				string_append(out, c")")
			else if (strlen(handler.text) != 0):
				if (js_print_identifier_valid(handler.text, 1) == 0): return js_print_error(diagnostics, handler)
				string_append(out, c" (")
				string_append(out, handler.text)
				string_append(out, c")")
			string_append(out, c" ")
			if (js_print_block(out, handler.children[handler.children.length - 1], depth, diagnostics) == 0): return 0
		else if (handler.children.length != 0): return js_print_error(diagnostics, handler)
		if (js_kind(finalizer, c"empty") == 0):
			string_append(out, c" finally ")
			if (js_print_block(out, finalizer, depth, diagnostics) == 0): return 0
		else if (finalizer.children.length != 0): return js_print_error(diagnostics, finalizer)
		return 1
	if (js_kind(node, c"label")):
		if (count != 1 || js_print_identifier_valid(node.text, 0) == 0): return js_print_error(diagnostics, node)
		string_append(out, node.text)
		string_append(out, c": ")
		return js_print_statement(out, node.children[0], depth, diagnostics)
	if (js_kind(node, c"break") || js_kind(node, c"continue")):
		if (count != 0): return js_print_error(diagnostics, node)
		if (strlen(node.text) != 0 && js_print_identifier_valid(node.text, 0) == 0): return js_print_error(diagnostics, node)
		string_append(out, node.kind)
		if (strlen(node.text) != 0):
			string_append(out, c" ")
			string_append(out, node.text)
		string_append(out, c";")
		return 1
	if (js_kind(node, c"while") || js_kind(node, c"do_while") || js_kind(node, c"with")):
		if (count != 2): return js_print_error(diagnostics, node)
		if (js_kind(node, c"do_while")):
			string_append(out, c"do ")
			if (js_print_statement(out, node.children[1], depth, diagnostics) == 0): return 0
			string_append(out, c" while (")
		else if (js_kind(node, c"with")): string_append(out, c"with (")
		else: string_append(out, c"while (")
		if (js_print_expression(out, node.children[0], diagnostics) == 0): return 0
		string_append(out, c")")
		if (js_kind(node, c"do_while")):
			string_append(out, c";")
			return 1
		string_append(out, c" ")
		return js_print_statement(out, node.children[1], depth, diagnostics)
	if (js_kind(node, c"for_of") || js_kind(node, c"for_in") || js_kind(node, c"for_await_of")): return js_print_for_each(out, node, depth, diagnostics)
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
	if (js_kind(node, c"switch")): return js_print_switch(out, node, depth, diagnostics)
	if (js_kind(node, c"export") || js_kind(node, c"export_default") || js_kind(node, c"export_named") || js_kind(node, c"export_from") || js_kind(node, c"export_all")): return js_print_export(out, node, depth, diagnostics)
	if (js_kind(node, c"import")): return js_print_import(out, node, diagnostics)
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
