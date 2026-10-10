# wbuild: name=javascript_ast_test
# wbuild: expect_stdout="javascript_ast_test: OK"
# wbuild: x64
import lib.assert
import libs.extras.javascript.printer
import libs.extras.javascript.edits


int js_test_visits


void js_test_visit(js_node* node):
	if (node != 0): js_test_visits = js_test_visits + 1


js_node* js_test_greeting():
	js_node* program = js_node_new(c"program", c"")
	js_node* exported = js_node_new(c"export", c"")
	js_node* function = js_node_new(c"function", c"greet")
	js_node* parameters = js_node_new(c"parameters", c"")
	js_node_add(parameters, js_identifier(c"name"))
	js_node* body = js_node_new(c"block", c"")
	js_node* returned = js_node_new(c"return", c"")
	js_node_add(returned, js_binary(c"+", js_string(c"Hello, "), js_identifier(c"name")))
	js_node_add(body, returned)
	js_node_add(function, parameters)
	js_node_add(function, body)
	js_node_add(exported, function)
	js_node_add(program, exported)
	return program


void js_test_build_print():
	js_node* program = js_test_greeting()
	js_node* same = js_test_greeting()
	same.offset = 20
	assert1(js_node_equal(program, same))
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	char* printed = js_print(program, diagnostics)
	assert_strings_equal(c"export function greet(name) {\n  return (\"Hello, \" + name);\n}\n", printed)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	free(printed)
	js_test_visits = 0
	js_node_walk(program, js_test_visit)
	assert_equal(10, js_test_visits)
	js_node* returned = program.children[0].children[0].children[1].children[0]
	js_node* old = js_node_replace(returned, 0, js_string(c"a\n\"b\\c\t\x01"))
	assert1(old != 0)
	js_node_free(old)
	assert1(js_node_equal(program, same) == 0)
	printed = js_print(program, diagnostics)
	assert_strings_equal(c"export function greet(name) {\n  return \"a\\n\\\"b\\\\c\\t\\x01\";\n}\n", printed)
	free(printed)
	js_node_free(program)
	js_node_free(same)
	pg_diagnostics_free(diagnostics)


void js_test_expressions():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	js_node* statement = js_node_new(c"expression_statement", c"")
	js_node_add(statement, js_binary(c"*", js_binary(c"+", js_number(c"2"), js_number(c"3")), js_number(c"4")))
	char* printed = js_print(statement, diagnostics)
	assert_strings_equal(c"((2 + 3) * 4);", printed)
	free(printed)
	js_node_free(statement)
	statement = js_node_new(c"expression_statement", c"")
	js_node* template = js_node_new(c"template", c"")
	js_node_add(template, js_node_new(c"template_text", c"hello "))
	js_node_add(template, js_identifier(c"name"))
	js_node_add(statement, template)
	printed = js_print(statement, diagnostics)
	assert_strings_equal(c"`hello ${name}`;", printed)
	free(printed)
	js_node_free(statement)
	statement = js_node_new(c"expression_statement", c"")
	js_node* member = js_node_new(c"member", c"")
	js_node_add(member, js_node_new(c"regex", c"/ab+c/i"))
	js_node_add(member, js_identifier(c"test"))
	js_node* call = js_call(member)
	js_node_add(call, js_identifier(c"s"))
	js_node_add(statement, call)
	printed = js_print(statement, diagnostics)
	assert_strings_equal(c"(/ab+c/i).test(s);", printed)
	free(printed)
	js_node_free(statement)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	pg_diagnostics_free(diagnostics)


void js_test_rejections():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	js_node* unknown = js_node_new(c"unsupported", c"arbitrary source")
	assert1(js_print(unknown, diagnostics) == 0)
	assert_equal(1, pg_diagnostics_count(diagnostics))
	js_node_free(unknown)
	js_node* malformed = js_node_new(c"expression_statement", c"")
	js_node_add(malformed, js_identifier(c"a; injected()"))
	assert1(js_print(malformed, diagnostics) == 0)
	assert_equal(2, pg_diagnostics_count(diagnostics))
	js_node_free(malformed)
	malformed = js_node_new(c"variable", c"const")
	js_node* binding = js_node_new(c"declarator", c"")
	js_node_add(binding, js_identifier(c"x"))
	js_node_add(malformed, binding)
	assert1(js_print(malformed, diagnostics) == 0)
	assert_equal(3, pg_diagnostics_count(diagnostics))
	js_node_free(malformed)
	pg_diagnostics_free(diagnostics)


void js_test_reject_node(js_node* node):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	assert1(js_print(node, diagnostics) == 0)
	assert_equal(1, pg_diagnostics_count(diagnostics))
	js_node_free(node)
	pg_diagnostics_free(diagnostics)


void js_test_printer_safety():
	js_node* variable = js_node_new(c"variable", c"let")
	js_node* binding = js_node_new(c"declarator", c"")
	js_node_add(binding, js_identifier(c"return"))
	js_node_add(variable, binding)
	js_test_reject_node(variable)
	variable = js_node_new(c"variable", c"let")
	binding = js_node_new(c"declarator", c"")
	js_node_add(binding, js_identifier(c"\\u0072eturn"))
	js_node_add(variable, binding)
	js_test_reject_node(variable)
	js_node* statement = js_node_new(c"expression_statement", c"")
	js_node* assignment = js_node_new(c"assignment", c"=")
	js_node_add(assignment, js_number(c"1"))
	js_node_add(assignment, js_number(c"2"))
	js_node_add(statement, assignment)
	js_test_reject_node(statement)
	statement = js_node_new(c"expression_statement", c"")
	js_node* update = js_node_new(c"update_postfix", c"++")
	js_node_add(update, js_binary(c"+", js_identifier(c"a"), js_identifier(c"b")))
	js_node_add(statement, update)
	js_test_reject_node(statement)
	statement = js_node_new(c"expression_statement", c"")
	js_node* template = js_node_new(c"template", c"")
	js_node_add(template, js_node_new(c"template_text", c"\\uZZZZ"))
	js_node_add(statement, template)
	js_test_reject_node(statement)
	statement = js_node_new(c"expression_statement", c"")
	template = js_node_new(c"template", c"")
	js_node_add(template, js_node_new(c"template_text", c"$"))
	js_node_add(template, js_node_new(c"template_text", c"{injected}"))
	js_node_add(statement, template)
	js_test_reject_node(statement)
	statement = js_node_new(c"expression_statement", c"")
	js_node_add(statement, js_string(c"\xc0"))
	js_test_reject_node(statement)


void js_test_edits():
	char* source = c"// keep\nimport x from './old.js';\nconst s = './old.js';\n"
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	list[js_source_edit*] edits = new list[js_source_edit*]
	edits.push(js_source_edit_new(23, 8, c"./new.js", 8))
	int length = 0
	char* changed = js_source_edits_apply(source, strlen(source), edits, diagnostics, &length)
	# Only the selected module span changes; unrelated strings stay intact.
	assert_strings_equal(c"// keep\nimport x from './new.js';\nconst s = './old.js';\n", changed)
	assert_equal(strlen(source), length)
	free(changed)
	# Unsorted disjoint edits are accepted.
	edits.push(js_source_edit_new(0, 7, c"// kept", 7))
	changed = js_source_edits_apply(source, strlen(source), edits, diagnostics, &length)
	assert1(changed != 0)
	assert_substring(changed, c"// kept\n", 1)
	free(changed)
	edits.push(js_source_edit_new(24, 1, c"x", 1))
	assert1(js_source_edits_apply(source, strlen(source), edits, diagnostics, &length) == 0)
	assert_equal(1, pg_diagnostics_count(diagnostics))
	while (edits.length > 0): js_source_edit_free(edits.pop())
	edits.push(js_source_edit_new(strlen(source), 1, c"x", 1))
	assert1(js_source_edits_apply(source, strlen(source), edits, diagnostics, &length) == 0)
	assert_equal(2, pg_diagnostics_count(diagnostics))
	js_source_edit_free(edits.pop())
	# Duplicate zero-length insertions have no implicit ordering.
	edits.push(js_source_edit_new(0, 0, c"a", 1))
	edits.push(js_source_edit_new(0, 0, c"b", 1))
	assert1(js_source_edits_apply(source, strlen(source), edits, diagnostics, &length) == 0)
	assert_equal(3, pg_diagnostics_count(diagnostics))
	while (edits.length > 0): js_source_edit_free(edits.pop())
	__w_list_free(cast(__w_list*, edits))
	pg_diagnostics_free(diagnostics)


int main():
	malloc_force_debug_mode()
	js_test_build_print()
	js_test_expressions()
	js_test_rejections()
	js_test_printer_safety()
	js_test_edits()
	assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_ast_test: OK")
	return 0
