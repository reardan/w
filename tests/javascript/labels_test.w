# wbuild: name=javascript_labels_test
# wbuild: target=javascript_labels_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/labels_test.w -o bin/javascript_labels_test"
# wbuild: step="bin/javascript_labels_test" expect_stdout="javascript_labels_test: OK"
# wbuild: step="bin/javascript_labels_test memory" expect_stdout="javascript_labels_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


void label_number(char* source, float64 expected):
	js_runtime* rt = js_runtime_new()
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	assert_equal(0, result.status)
	assert_equal(3, result.value.kind)
	assert1(result.value.number == expected)
	assert1(rt.label == 0)
	assert1(rt.jump_target == 0)
	js_runtime_free(rt)


void label_invalid(char* source):
	pg_parse_result* parsed = js_parse_script(source, c"invalid-label.js")
	assert_equal(0, parsed.success)
	assert1(pg_diagnostics_count(parsed.diagnostics) > 0)
	pg_parse_result_free(parsed)


void test_label_completions():
	label_number(c"outer: { 42; inner: { break outer; } }", 42.0)
	label_number(c"outer: for(let i=0;i<1;i++) { 42; inner: { break outer; } }", 42.0)
	label_number(c"42; empty: ;", 42.0)
	label_number(c"42; outer: { break outer; }", 42.0)
	label_number(c"outer: { 42; break outer; 0; }", 42.0)
	label_number(c"a: b: { 42; break a; }", 42.0)
	label_number(c"var n=0; a: b: { n=42; break b; n=0; } n;", 42.0)
	label_number(c"var n=0; outer: { while(true) { n=42; break outer; } n=0; } n;", 42.0)
	label_number(c"var n=0; outer: for (let i=0; i<3; i++) { for (let j=0; j<3; j++) { n++; continue outer; } n=0; } n;", 3.0)
	label_number(c"var n=0; a: b: while(n<3) { n++; continue a; } n;", 3.0)
	label_number(c"var n=0; a: b: do { n++; continue b; } while(n<3); n;", 3.0)
	label_number(c"var n=0; a: b: for (const v of [1,2,3]) { while(true) { n+=v; continue a; } } n;", 6.0)
	label_number(c"var n=0; outer: while(n<3) { for (const v of [1,2]) { n++; continue outer; } n=99; } n;", 3.0)
	label_number(c"var n=0; outer: { for (const v of [1,2]) { n+=v; break outer; } n=99; } n;", 1.0)
	label_number(c"var n=0; outer: for (;;) { for (;;) { n=42; break outer; } n=0; } n;", 42.0)
	label_number(c"var n=0; outer: while(n<2) { inner: while(true) { n++; break; } } n;", 2.0)
	label_number(c"var n=0; outer: while(n<3) { n++; inner: { if(n<3) continue; } } n;", 3.0)
	label_number(c"var n=0; out\\u0065r: while(true) { n=42; break outer; } n;", 42.0)
	label_number(c"var n=0; outer: while(n<3) { n++; continue out\\u0065r; } n;", 3.0)
	label_number(c"await: { 42; break await; }", 42.0)
	label_number(c"yield: { 42; break yield; }", 42.0)
	label_number(c"\"use strict\"; eval: { 42; break eval; }", 42.0)
	label_number(c"var n=typeof x; outer: { break outer; var x=1; } n===\"undefined\" ? 42 : 0;", 42.0)
	label_number(c"outer: { var value=42; break outer; } value;", 42.0)
	label_number(c"var n=0; outer: { try { n=1; break outer; } finally { n+=41; } n=0; } n;", 42.0)
	label_number(c"var n=0; outer: for(let i=0;i<3;i++) { try { continue outer; } finally { n++; } n=99; } n;", 3.0)
	label_number(c"var n=0; outer: while(true) { try { break outer; } finally { inner: { n=42; break inner; } } n=0; } n;", 42.0)
	label_number(c"var n=0; outer: while(n<3) { try { continue outer; } finally { local: { n++; break local; } } } n;", 3.0)
	label_number(c"var n=0; outer: while(n<3) { inner: while(true) { try { break outer; } finally { n++; continue outer; } } } n;", 3.0)
	label_number(c"var n=0; outer: { inner: while(true) { try { continue inner; } finally { n=42; break outer; } } n=0; } n;", 42.0)
	label_number(c"function f() { outer: { try { break outer; } finally { return 42; } } return 0; } f();", 42.0)
	label_number(c"var n=0; try { outer: { try { break outer; } finally { throw 42; } } } catch(e) { n=e; } n;", 42.0)
	label_number(c"function f(n) { outer: { if(n>0) { f(n-1); } break outer; } return n; } outer: { f(3); break outer; } f(3);", 3.0)
	label_number(c"var f=()=>{ same: { break same; } return 42; }; same: { f(); break same; } f();", 42.0)
	label_number(c"var a=[]; outer: for(let i=0;i<3;i++) { a[i]=()=>i; continue outer; } a[0]()+a[1]()+a[2]();", 3.0)
	label_number(c"var a=[]; outer: for(let i of [1,2,3]) { a[i-1]=()=>i; continue outer; } a[0]()+a[1]()+a[2]();", 6.0)


void test_label_validation():
	label_invalid(c"break absent;")
	label_invalid(c"continue absent;")
	label_invalid(c"a: { continue a; }")
	label_invalid(c"a: { while(true) { continue a; } }")
	label_invalid(c"a: a: while(true) { break a; }")
	label_invalid(c"a: \\u0061: while(true) { break a; }")
	label_invalid(c"a: while(true) { function f() { break a; } }")
	label_invalid(c"a: while(true) { (()=>{ continue a; }); }")
	label_invalid(c"a: { break; }")
	label_invalid(c"a: let value=1;")
	label_invalid(c"a: const value=1;")


void test_label_limits():
	js_runtime* rt = js_runtime_new()
	char* empty_source = c"outer: { 42; while(true) { break outer; } }"
	js_completion* empty_result = js_runtime_eval(rt, empty_source, strlen(empty_source), 100)
	assert_equal(0, empty_result.status)
	assert_equal(0, empty_result.value.kind)
	char* source = c"var final=0; outer: while(true) { try { continue outer; } finally { final++; } }"
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 40)
	assert_equal(5, result.status)
	assert1(rt.label == 0)
	assert1(result.steps <= 40)
	source = c"outer: { 42; break outer; }"
	result = js_runtime_eval(rt, source, strlen(source), 100)
	assert_equal(0, result.status)
	assert1(result.value.number == 42.0)
	assert1(rt.jump_target == 0)
	# Annex B labelled functions fail before any effects, as documented.
	source = c"final=99; label: function f() {}"
	result = js_runtime_eval(rt, source, strlen(source), 100)
	assert_equal(6, result.status)
	source = c"final;"
	result = js_runtime_eval(rt, source, strlen(source), 100)
	assert_equal(0, result.status)
	assert1(result.value.number != 99.0)
	source = c"final=0; outer: try { for(;;) { continue; } } finally { final=99; }"
	result = js_runtime_eval(rt, source, strlen(source), 30)
	assert_equal(5, result.status)
	assert1(rt.label == 0)
	source = c"final;"
	result = js_runtime_eval(rt, source, strlen(source), 100)
	assert_equal(0, result.status)
	assert1(result.value.number == 0.0)
	rt.max_depth = 2
	source = c"a: b: c: ;"
	result = js_runtime_eval(rt, source, strlen(source), 100)
	assert_equal(5, result.status)
	assert1(rt.label == 0)
	js_runtime_free(rt)


void test_label_ast():
	char* source = c"out\\u0065r: inner: while(true) { break outer; continue inner; }"
	pg_parse_result* parsed = js_parse_script(source, c"labels.js")
	assert1(parsed.success)
	js_node* tree = js_lower(parsed)
	assert1(tree != 0)
	js_node* label = tree.children[0]
	assert_strings_equal(c"label", label.kind)
	assert_strings_equal(c"outer", label.text)
	assert_equal(0, label.offset)
	assert_equal(strlen(source), label.length)
	js_node* jump = label.children[0].children[0].children[1].children[0]
	assert_strings_equal(c"break", jump.kind)
	assert_strings_equal(c"outer", jump.text)
	assert_equal(0, jump.children.length)
	char* printed = js_print(tree, parsed.diagnostics)
	assert1(printed != 0)
	pg_parse_result* reparsed = js_parse_script(printed, c"printed-labels.js")
	assert1(reparsed.success)
	js_node* other = js_lower(reparsed)
	assert1(js_node_equal(tree, other))
	free(printed)
	js_node_free(tree)
	js_node_free(other)
	pg_parse_result_free(parsed)
	pg_parse_result_free(reparsed)
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	label = js_node_new(c"label", c"bad name")
	js_node_add(label, js_node_new(c"empty", c""))
	assert1(js_print(label, diagnostics) == 0)
	js_node_free(label)
	jump = js_node_new(c"break", c"bad name")
	assert1(js_print(jump, diagnostics) == 0)
	js_node_free(jump)
	# The printer must see an unmatched if through the label wrapper.
	label = js_node_new(c"label", c"outer")
	js_node* conditional = js_node_new(c"if", c"")
	js_node_add(conditional, js_identifier(c"condition"))
	js_node_add(conditional, js_node_new(c"empty", c""))
	js_node_add(label, conditional)
	assert1(js_print_dangling_else(label))
	js_node* outer = js_node_new(c"if", c"")
	js_node_add(outer, js_identifier(c"outerCondition"))
	js_node_add(outer, label)
	js_node_add(outer, js_node_new(c"empty", c""))
	printed = js_print(outer, diagnostics)
	assert_strings_equal(c"if (outerCondition) { outer: if (condition) ; } else ;", printed)
	free(printed)
	js_node_free(outer)
	pg_diagnostics_free(diagnostics)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1):
		# A representative ownership sweep stays below the host's VMA cap.
		malloc_force_debug_mode()
		label_number(c"var n=0; outer: for(let i=0;i<3;i++) { try { continue outer; } finally { n++; } } n;", 3.0)
		test_label_ast()
		assert_equal(0, debug_alloc_report_leaks())
	else:
		test_label_completions()
		test_label_validation()
		test_label_limits()
		test_label_ast()
	println(c"javascript_labels_test: OK")
	return 0
