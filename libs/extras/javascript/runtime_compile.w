# Compile a parenthesized ordinary function expression during an active host
# callback. Uses the current execution budget and realm; never executes source.
import libs.extras.javascript.runtime


js_value* js_runtime_compile_function(js_runtime* rt, char* source, int length):
	if (rt.completion.status != 0): return rt.undefined_value
	if (rt.running == 0 || length < 0 || length > rt.max_source_bytes || rt.scripts.length >= rt.max_scripts):
		js_runtime_fail(rt, 5, c"JavaScript function compilation input or execution limit")
		return rt.undefined_value
	if (js_runtime_compat_step(rt) == 0): return rt.undefined_value
	pg_parse_result* parsed = js_parse_with_limits(source, length, c"<host function>", 0, rt.parse_limits)
	js_node* tree = js_lower(parsed)
	if (tree == 0):
		if (parsed.stream.resource_failed): js_runtime_fail(rt, 5, c"JavaScript parser resource limit")
		else: js_runtime_fail(rt, 6, c"JavaScript parse or AST lowering failed")
		pg_parse_result_free(parsed)
		return rt.undefined_value
	pg_parse_result_free(parsed)
	int shape = tree.children.length == 1
	js_node* expression = 0
	if (shape):
		js_node* statement = tree.children[0]
		shape = js_kind(statement, c"expression_statement") && statement.children.length == 1
		if (shape):
			expression = statement.children[0]
			shape = js_kind(expression, c"function_expression") && expression.async_function == 0
	if (shape == 0 || js_runtime_supported(tree) == 0):
		js_node_free(tree)
		js_runtime_fail(rt, 6, c"host function compilation requires a supported function expression")
		return rt.undefined_value
	rt.scripts.push(tree)
	return js_runtime_function(rt, expression, rt.global)
