# Target-aware validation for the first executable slice. Later tasks will
# replace the shape restriction with general name/type/control-flow passes.
import tools.wc2.expressions


void wc2_node_error(wc2_module* m, wc2_node* node, char* message):
	pg_diagnostics_add(m.diagnostics, m.filename, node.line, node.column, message, c"", node.text)


# Accumulate two 16-bit limbs so overflow checking and sign extension are
# identical in 32-bit and 64-bit hosts. W accepts 32 significant literal bits.
int wc2_integer32(char* text, int* value):
	if (strcmp(text, c"true") == 0):
		*value = 1
		return 1
	if (strcmp(text, c"false") == 0):
		*value = 0
		return 1
	if (wc2_integer_spelling(text) == 0): return 0
	int base = 10
	int i = 0
	if ((text[0] == '0') && (text[1] == 'x')):
		base = 16
		i = 2
	if ((text[0] == '0') && (text[1] == 'b')):
		base = 2
		i = 2
	int low = 0
	int high = 0
	while (text[i]):
		int digit = text[i] - '0'
		if ((text[i] >= 'a') && (text[i] <= 'f')): digit = text[i] - 'a' + 10
		if ((text[i] >= 'A') && (text[i] <= 'F')): digit = text[i] - 'A' + 10
		low = low * base + digit
		high = high * base + (low >> 16)
		if (high > 65535): return 0
		low = low & 65535
		i = i + 1
	if (high >= 32768): high = high - 65536
	*value = (high << 16) | low
	return 1


void wc2_validate_expression(wc2_module* m, wc2_node* node, int depth):
	if (depth > 200):
		wc2_node_error(m, node, c"wc2: executable expression nesting limit exceeded")
		return
	if (node.kind == wc2_integer_kind):
		int value = 0
		if (wc2_integer32(node.text, &value) == 0):
			wc2_node_error(m, node, c"wc2: integer literal exceeds 32 significant bits")
		return
	if ((node.kind == wc2_unary_kind) || (node.kind == wc2_binary_kind) || (node.kind == wc2_logical_kind)):
		for int child in node.children: wc2_validate_expression(m, m.nodes[child], depth + 1)
		return
	wc2_node_error(m, node, c"wc2: executable expressions currently support only integer literals and operators")


# Return the expression to emit, or 0 with diagnostics. Check the whole
# function shape: unsupported statements after a return must not disappear.
wc2_node* wc2_validate_executable(wc2_module* m):
	if (wc2_module_ok(m) == 0): return 0
	wc2_node* root = m.nodes[m.root]
	if (root.children.length != 1):
		wc2_node_error(m, root, c"wc2: executable requires exactly one int main() function")
		return 0
	wc2_node* fn_node = wc2_child(m, root, 0)
	if ((fn_node.kind != wc2_function_kind) || (strcmp(fn_node.text, c"main") != 0) || (fn_node.type_id != wc2_int_type) || (fn_node.children.length != 1)):
		wc2_node_error(m, fn_node, c"wc2: executable requires int main() with no parameters")
		return 0
	wc2_node* body = wc2_child(m, fn_node, 0)
	if (body.children.length != 1):
		wc2_node_error(m, body, c"wc2: executable function body must contain exactly one return expression")
		return 0
	wc2_node* statement = wc2_child(m, body, 0)
	if ((statement.kind != wc2_return_kind) || (statement.children.length != 1)):
		wc2_node_error(m, statement, c"wc2: executable function body must contain exactly one return expression")
		return 0
	wc2_node* expression = wc2_child(m, statement, 0)
	wc2_validate_expression(m, expression, 0)
	if (wc2_module_ok(m) == 0): return 0
	return expression
