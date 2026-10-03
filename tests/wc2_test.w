# wbuild: x64 tool=tools/wc2.w
import lib.testing
import tools.wc2.lower
import tools.wc2.dump


wc2_module* wc2_test_parse(char* source):
	wc2_module* m = wc2_parse(source, c"test.w")
	if (wc2_module_ok(m) == 0): pg_diagnostics_print(m.diagnostics)
	assert1(wc2_module_ok(m))
	# Every edge is module-local and contained in its parent's source span.
	for i in range(m.nodes.length):
		wc2_node* node = m.nodes[i]
		assert_equal(i, node.id)
		assert1((node.start >= 0) && (node.end <= strlen(source)))
		assert1(node.start <= node.end)
		assert1((node.scope >= 0) && (node.scope < m.scopes.length))
		assert_equal(-1, node.binding)
		for int id in node.children:
			assert1((id >= 0) && (id < m.nodes.length))
			assert1(m.nodes[id].start >= node.start)
			assert1(m.nodes[id].end <= node.end)
	for i in range(m.scopes.length):
		wc2_scope* scope = m.scopes[i]
		assert1((scope.parent >= -1) && (scope.parent < i))
		assert1((scope.owner >= 0) && (scope.owner < m.nodes.length))
		for int id in scope.declarations: assert_equal(i, m.nodes[id].scope)
	return m


wc2_node* wc2_test_body(wc2_module* m, int index):
	wc2_node* fn_node = wc2_child(m, m.nodes[m.root], index)
	assert_equal(wc2_function_kind, fn_node.kind)
	wc2_node* body = wc2_child(m, fn_node, fn_node.children.length - 1)
	assert_equal(wc2_block_kind, body.kind)
	return body


wc2_node* wc2_test_return_value(wc2_module* m):
	wc2_node* ret = wc2_child(m, wc2_test_body(m, 0), 0)
	assert_equal(wc2_return_kind, ret.kind)
	return wc2_child(m, ret, 0)


void wc2_test_reject(char* source, char* message):
	wc2_module* m = wc2_parse(source, c"reject.w")
	assert_equal(0, wc2_module_ok(m))
	assert1(pg_diagnostics_count(m.diagnostics) > 0)
	int found = 0
	for pg_diagnostic* diagnostic in m.diagnostics.items:
		if (assert_has(diagnostic.message, message)): found = 1
		assert_strings_equal(c"reject.w", diagnostic.filename)
		assert1((diagnostic.line > 0) && (diagnostic.column > 0))
	asserts(message, found)
	wc2_module_free(m)


void test_wc2_arithmetic_precedence_and_spans():
	wc2_module* m = wc2_test_parse(c"int main():\n\treturn 2 + 3 * 4\n")
	wc2_node* sum = wc2_test_return_value(m)
	assert_equal(wc2_binary_kind, sum.kind)
	assert_strings_equal(c"+", sum.text)
	assert_strings_equal(c"2", wc2_child(m, sum, 0).text)
	wc2_node* product = wc2_child(m, sum, 1)
	assert_strings_equal(c"*", product.text)
	assert_strings_equal(c"3", wc2_child(m, product, 0).text)
	assert_strings_equal(c"4", wc2_child(m, product, 1).text)
	assert_equal(20, sum.start)
	assert_equal(29, sum.end)
	assert_equal(2, sum.line)
	assert_equal(9, sum.column)
	assert_equal(wc2_integer_literal_type, wc2_child(m, sum, 0).type_id)
	assert_equal(wc2_unresolved_type, sum.type_id)
	wc2_module_free(m)


void test_wc2_every_precedence_level():
	wc2_module* m = wc2_test_parse(c"int f(): return a || b && c | d ^ e & f == g < h << i + j * k\n")
	wc2_node* node = wc2_test_return_value(m)
	char*[10] ops
	ops[0] = c"||"
	ops[1] = c"&&"
	ops[2] = c"|"
	ops[3] = c"^"
	ops[4] = c"&"
	ops[5] = c"=="
	ops[6] = c"<"
	ops[7] = c"<<"
	ops[8] = c"+"
	ops[9] = c"*"
	for i in range(10):
		assert_strings_equal(ops[i], node.text)
		if (i < 2): assert_equal(wc2_logical_kind, node.kind)
		else: assert_equal(wc2_binary_kind, node.kind)
		node = wc2_child(m, node, 1)
	assert_strings_equal(c"k", node.text)
	wc2_module_free(m)


void test_wc2_associativity_grouping_and_unary():
	wc2_module* m = wc2_test_parse(c"int f(): return 20 - 5 - 3\n")
	wc2_node* node = wc2_test_return_value(m)
	assert_strings_equal(c"-", node.text)
	assert_strings_equal(c"-", wc2_child(m, node, 0).text)
	assert_strings_equal(c"3", wc2_child(m, node, 1).text)
	wc2_module_free(m)
	m = wc2_test_parse(c"int f(): return -(2 + 3) * ~4\n")
	node = wc2_test_return_value(m)
	assert_strings_equal(c"*", node.text)
	wc2_node* unary = wc2_child(m, node, 0)
	assert_equal(wc2_unary_kind, unary.kind)
	assert_strings_equal(c"-", unary.text)
	assert_strings_equal(c"+", wc2_child(m, unary, 0).text)
	assert_strings_equal(c"~", wc2_child(m, node, 1).text)
	wc2_module_free(m)
	m = wc2_test_parse(c"int f(): return a = b = 3\n")
	node = wc2_test_return_value(m)
	assert_equal(wc2_assignment_kind, node.kind)
	assert_strings_equal(c"a", wc2_child(m, node, 0).text)
	assert_equal(wc2_assignment_kind, wc2_child(m, node, 1).kind)
	wc2_module_free(m)


void test_wc2_parameters_calls_and_declarations():
	wc2_module* m = wc2_test_parse(c"int global = 7\nint add(int a, int b):\n\tint total = a + b\n\ttotal += 1\n\treturn total\nint main():\n\tanswer := add(2, 3 * 4)\n\treturn answer\n")
	assert_equal(3, m.nodes[m.root].children.length)
	wc2_node* fn_node = wc2_child(m, m.nodes[m.root], 1)
	assert_strings_equal(c"add", fn_node.text)
	assert_equal(3, fn_node.children.length)
	wc2_node* parameter = wc2_child(m, fn_node, 0)
	assert_equal(wc2_parameter_kind, parameter.kind)
	assert_strings_equal(c"a", parameter.text)
	assert_equal(wc2_int_type, parameter.type_id)
	assert_equal(2, m.scopes[parameter.scope].declarations.length)
	wc2_node* body = wc2_test_body(m, 1)
	assert_equal(3, body.children.length)
	assert_equal(parameter.scope, m.scopes[body.scope].parent)
	assert_equal(1, m.scopes[body.scope].declarations.length)
	assert_strings_equal(c"+=", wc2_child(m, wc2_child(m, body, 1), 0).text)
	body = wc2_test_body(m, 2)
	wc2_node* local = wc2_child(m, body, 0)
	assert_strings_equal(c"answer", local.text)
	assert_equal(wc2_unresolved_type, local.type_id)
	wc2_node* call = wc2_child(m, local, 0)
	assert_equal(wc2_call_kind, call.kind)
	assert_equal(3, call.children.length)
	assert_strings_equal(c"add", wc2_child(m, call, 0).text)
	assert_strings_equal(c"*", wc2_child(m, call, 2).text)
	wc2_module_free(m)


void test_wc2_dedents_and_else_binding():
	wc2_module* m = wc2_test_parse(c"int f(int x):\n\twhile x:\n\t\tif x > 1:\n\t\t\tx -= 1\n\t\telse:\n\t\t\tbreak\n\t\tx -= 2\n\treturn x\nint g(): return 5\n")
	assert_equal(2, m.nodes[m.root].children.length)
	wc2_node* body = wc2_test_body(m, 0)
	assert_equal(2, body.children.length)
	assert_equal(wc2_return_kind, wc2_child(m, body, 1).kind)
	wc2_node* loop = wc2_child(m, body, 0)
	assert_equal(wc2_while_kind, loop.kind)
	wc2_node* loop_body = wc2_child(m, loop, 1)
	assert_equal(2, loop_body.children.length)
	wc2_node* branch = wc2_child(m, loop_body, 0)
	assert_equal(wc2_if_kind, branch.kind)
	assert_equal(3, branch.children.length)
	wc2_node* yes = wc2_child(m, branch, 1)
	wc2_node* no = wc2_child(m, branch, 2)
	assert_equal(1, yes.children.length)
	assert_equal(1, no.children.length)
	assert1(yes.scope != no.scope)
	assert_equal(loop_body.scope, m.scopes[yes.scope].parent)
	assert_equal(loop_body.scope, m.scopes[no.scope].parent)
	assert_equal(wc2_break_kind, wc2_child(m, no, 0).kind)
	assert_equal(7, wc2_child(m, loop_body, 1).line)
	assert1(loop.end <= wc2_child(m, body, 1).start)
	wc2_module_free(m)


void test_wc2_inline_elif_and_empty_blocks():
	wc2_module* m = wc2_test_parse(c"int f(int x):\n\tif x: return 1\n\telif x + 1: return 2\n\telse if x + 2: return 3\n\telse: return 4\n\treturn 5\nvoid empty():\nint g(): return 6\n")
	wc2_node* body = wc2_test_body(m, 0)
	assert_equal(2, body.children.length)
	wc2_node* branch = wc2_child(m, body, 0)
	for i in range(2):
		assert_equal(3, branch.children.length)
		branch = wc2_child(m, branch, 2)
		assert_equal(wc2_if_kind, branch.kind)
	assert_equal(wc2_block_kind, wc2_child(m, branch, 2).kind)
	assert_equal(0, wc2_test_body(m, 1).children.length)
	assert_equal(1, wc2_test_body(m, 2).children.length)
	wc2_module_free(m)


void test_wc2_owned_modules_and_deterministic_dump():
	char* source = strclone(c"# UTF-8: \xc3\xa9\nint main(): return 0xffffffff\n")
	char* filename = strclone(c"quoted\"name.w")
	wc2_module* first = wc2_parse(source, filename)
	assert1(wc2_module_ok(first))
	free(source)
	free(filename)
	char* before = wc2_dump(first)
	for i in range(20):
		wc2_module* other = wc2_test_parse(c"bool flag = true\nint second(): return 0b101\n")
		wc2_module_free(other)
	char* after = wc2_dump(first)
	assert_strings_equal(before, after)
	assert_contains(after, c"quoted\\\"name.w")
	assert_strings_equal(c"0xffffffff", wc2_test_return_value(first).text)
	assert_equal(2, wc2_test_return_value(first).line)
	json_value* parsed = json_parse(after)
	assert1(parsed != 0)
	json_free(parsed)
	free(before)
	free(after)
	wc2_module_free(first)


void test_wc2_errors_are_explicit_and_releasable():
	wc2_test_reject(c"int f(): return 1.5\n", c"integer literal")
	wc2_test_reject(c"int f(): return 0x\n", c"integer literal")
	wc2_test_reject(c"int f(): return 1 ? 2 : 3\n", c"postfix")
	wc2_test_reject(c"int f(): return x[0]\n", c"postfix")
	wc2_test_reject(c"int f(): return *x\n", c"unary")
	wc2_test_reject(c"int f(): return 1 = 2\n", c"name target")
	wc2_test_reject(c"int f(): return x in y\n", c"binary operator")
	wc2_test_reject(c"int f():\n\tbreak\n", c"outside a loop")
	wc2_test_reject(c"int f():\n\telse: return 1\n", c"unmatched")
	wc2_test_reject(c"int f():\n return 1\n", c"indentation")
	wc2_test_reject(c"int f(): return 1 +\n\t2\n", c"multiline")
	wc2_test_reject(c"int f() { return 1 }\n", c"brace blocks")
	wc2_test_reject(c"int f();\n", c"prototypes")
	wc2_test_reject(c"int f(int x = 1): return x\n", c"default parameters")
	wc2_test_reject(c"int* f(): return 0\n", c"types")
	wc2_test_reject(c"int f(): return @\n", c"invalid")
	wc2_test_reject(c"int f(\n", c"syntax error")
	wc2_module* m = wc2_parse(c"import lib.lib\nstruct point:\n\tint x\n", c"unsupported.w")
	assert_equal(0, wc2_module_ok(m))
	assert_equal(2, pg_diagnostics_count(m.diagnostics))
	wc2_module_free(m)
	m = wc2_parse(c"int f():\n\tswitch 1:\n\t\tcase 1: return 2\n", c"unsupported.w")
	assert_equal(0, wc2_module_ok(m))
	assert_equal(1, pg_diagnostics_count(m.diagnostics))
	wc2_module_free(m)
	m = wc2_test_parse(c"# empty module\n")
	assert_equal(0, m.nodes[m.root].children.length)
	wc2_module_free(m)
