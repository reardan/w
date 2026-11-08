# Direct and indirect eval (reardan/w#907; ECMA-262 2020 sec-eval-x,
# sec-performeval, sec-evaldeclarationinstantiation and Annex B.3.5).
# Eval code goes through the same js_parse, js_lower and preflight as a
# script. A parse or early error throws a catchable SyntaxError; code outside
# the lowering or runtime subset stops evaluation with status 6. Imported by
# runtime.w after its core.
#
# Indirect eval runs in the global environment with the global object as
# this. Direct eval (a call `eval(...)` whose callee is the intrinsic) runs
# in a new declarative environment inside the caller's. Sloppy eval code
# declares its var and function names in the caller's variable environment,
# where they are deletable, and fails with a SyntaxError when a name is
# lexically declared between the two (simple catch parameters excepted).
# Strict eval code, or eval code called from strict code, keeps all its
# declarations in the new environment. Every evaluated tree is retained in
# rt.scripts, like a script, since its functions borrow its nodes.
import libs.extras.javascript.runtime


# The environment of a catch clause with a simple parameter (Annex B.3.5).
const int JS_CATCH_ENVIRONMENT = 9


void js_runtime_eval_syntax_error(js_runtime* rt):
	js_runtime_fail(rt, 2, c"invalid eval code")
	if (rt.completion.value == rt.undefined_value): return
	rt.completion.value.intrinsic_error_name = c"SyntaxError"
	rt.completion.value.prototype = js_runtime_error_prototype(rt, c"SyntaxError")
	js_text* key = js_runtime_key(c"name")
	js_text* name = js_runtime_key(c"SyntaxError")
	js_runtime_put(rt, rt.completion.value, key, js_runtime_string(rt, name))
	js_text_free(name)
	js_text_free(key)


# Parses and lowers eval code; 0 after a SyntaxError, limit or unsupported.
js_node* js_runtime_eval_tree(js_runtime* rt, js_text* text, int strict):
	int length = 0
	char* bytes = js_text_to_utf8(text, &length)
	if (bytes == 0):
		js_runtime_fail(rt, 6, c"eval source with unpaired surrogates is outside the runtime subset")
		return 0
	if (length > rt.max_source_bytes || rt.scripts.length >= rt.max_scripts):
		free(bytes)
		js_runtime_fail(rt, 5, c"JavaScript input or execution limit")
		return 0
	char* source = bytes
	# Eval code called from strict code is strict: a directive prefix gives
	# the parser the strict early errors and is skipped at evaluation.
	if (strict):
		source = strjoin(c"\"use strict\";", bytes)
		length = strlen(source)
		free(bytes)
	pg_parse_result* parsed = js_parse_with_limits(source, length, c"<eval>", 0, rt.parse_limits)
	int parsed_ok = parsed.success
	js_node* tree = js_lower(parsed)
	if (tree == 0):
		if (parsed.stream.resource_failed): js_runtime_fail(rt, 5, c"JavaScript parser resource limit")
		else if (parsed_ok == 0): js_runtime_eval_syntax_error(rt)
		else: js_runtime_fail(rt, 6, c"JavaScript parse or AST lowering failed")
	pg_parse_result_free(parsed)
	free(source)
	if (tree == 0): return 0
	if (js_runtime_supported(tree) == 0):
		js_node_free(tree)
		js_runtime_fail(rt, 6, c"syntax outside the JavaScript runtime subset")
		return 0
	rt.scripts.push(tree)
	return tree


# Var-declared names below node: var declarations and for-in/of var heads,
# never inside nested functions or classes.
void js_runtime_eval_var_names(js_node* node, list[js_node*] names):
	if (js_kind(node, c"function") || js_kind(node, c"function_expression") || js_kind(node, c"arrow") || js_kind(node, c"class") || js_kind(node, c"class_expression")): return
	if (js_kind(node, c"variable")):
		if (strcmp(node.text, c"var") == 0):
			for js_node* declarator in node.children: js_runtime_pattern_names(declarator.children[0], names)
		return
	if ((js_kind(node, c"for_in") || js_kind(node, c"for_of")) && strcmp(node.text, c"var") == 0): js_runtime_pattern_names(node.children[0], names)
	for js_node* child in node.children: js_runtime_eval_var_names(child, names)


# Sloppy eval var names may not be lexically declared between the eval's
# environment and the variable environment, nor globally.
int js_runtime_eval_conflict(js_runtime* rt, js_node* tree, js_value* caller, js_value* variables):
	list[js_node*] names = new list[js_node*]
	js_runtime_eval_var_names(tree, names)
	for js_node* statement in tree.children:
		js_node* declared = js_runtime_declared(statement)
		if (js_kind(declared, c"function")): names.push(declared)
	int conflict = 0
	for js_node* name in names:
		js_text* key = js_runtime_key(name.text)
		js_value* scope = caller
		while (scope != 0 && scope != variables && conflict == 0):
			if (scope.builtin_state != JS_CATCH_ENVIRONMENT && js_runtime_property(scope, key) != 0): conflict = 1
			scope = scope.parent
		if (variables == rt.global && js_runtime_global_lexical_conflict(rt, key)): conflict = 1
		if (variables != rt.global):
			js_value* binding = js_runtime_property(variables, key)
			if (binding != 0 && binding.lexical_binding): conflict = 1
		js_text_free(key)
	__w_list_free(cast(__w_list*, names))
	return conflict


# EvalDeclarationInstantiation followed by the statement list.
js_value* js_runtime_eval_body(js_runtime* rt, js_node* tree, js_value* scope, js_value* variables, int first):
	if (variables != scope && js_runtime_eval_conflict(rt, tree, scope.parent, variables)):
		js_runtime_fail(rt, 2, c"duplicate lexical binding")
		return rt.undefined_value
	int saved_eval = rt.eval_code
	rt.eval_code = 1
	js_runtime_var_declare(rt, tree, variables, 0)
	# Lexical declarations stay in the eval environment; functions are
	# var-scoped and close over the eval environment.
	js_node* lexical = js_node_new(c"block", c"")
	for i in range(first, tree.children.length):
		js_node* statement = js_runtime_declared(tree.children[i])
		if (js_kind(statement, c"function") == 0): js_node_add(lexical, tree.children[i])
	if (rt.completion.status == 0): js_runtime_declare(rt, lexical, scope)
	while (lexical.children.length > 0): lexical.children.pop()
	js_node_free(lexical)
	for i in range(first, tree.children.length):
		if (rt.completion.status != 0): break
		js_node* statement = js_runtime_declared(tree.children[i])
		if (js_kind(statement, c"function") == 0): continue
		js_text* key = js_runtime_key(statement.text)
		js_value* callable = js_runtime_function(rt, statement, scope)
		if (variables == rt.global && js_runtime_global_lexical_conflict(rt, key)): js_runtime_fail(rt, 2, c"duplicate lexical binding")
		else if (variables == rt.global): js_runtime_global_declare(rt, key, callable, 1)
		else:
			js_runtime_put(rt, variables, key, callable)
			js_value* binding = js_runtime_property(variables, key)
			if (binding != 0 && variables != scope):
				binding.variable_scope = 2
				binding.initialized = 1
		js_text_free(key)
	if (rt.completion.status == 0): js_runtime_var_declare(rt, tree, variables, 1)
	if (rt.completion.status == 0 && scope.strict == 0): js_annexb_declare(rt, tree, variables)
	rt.eval_code = saved_eval
	js_value* result = rt.undefined_value
	for i in range(first, tree.children.length):
		if (rt.completion.status != 0): break
		js_value* value = js_runtime_eval_node(rt, tree.children[i], scope)
		if (rt.empty == 0): result = value
	rt.empty = 0
	return result


# PerformEval. caller is the calling environment of a direct eval, or 0.
js_value* js_runtime_perform_eval(js_runtime* rt, js_value* source, js_value* caller):
	if (source.kind != 4): return source
	int inherited = caller != 0 && caller.strict
	js_node* tree = js_runtime_eval_tree(rt, source.text, inherited)
	if (tree == 0): return rt.undefined_value
	int first = 0
	if (inherited): first = 1
	js_value* outer = rt.global
	if (caller != 0): outer = caller
	js_value* scope = js_runtime_environment(rt, outer)
	if (scope == rt.undefined_value): return scope
	scope.strict = inherited || js_runtime_strict_body(tree)
	js_value* variables = scope
	if (scope.strict): scope.variable_scope = 1
	else if (caller == 0): variables = rt.global
	else: variables = js_annexb_variable_environment(caller)
	if (variables == 0): variables = rt.global
	return js_runtime_eval_body(rt, tree, scope, variables, first)


# Reached only through a call whose callee is the eval intrinsic.
js_value* js_runtime_direct_eval(js_runtime* rt, js_node* node, js_value* env, list[js_value*] arguments):
	if (arguments.length == 0): return rt.undefined_value
	return js_runtime_perform_eval(rt, arguments[0], env)


js_value* js_runtime_eval_function(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (args.length == 0): return rt.undefined_value
	return js_runtime_perform_eval(rt, args[0], 0)


void js_runtime_install_eval(js_runtime* rt):
	js_value* eval = js_runtime_host_callable(rt, 0, js_runtime_eval_function)
	if (eval == rt.undefined_value): return
	js_text* key = js_runtime_key(c"name")
	js_runtime_define_data(rt, eval, key, js_runtime_string_value(rt, c"eval"), 0, 0, 1)
	js_text_free(key)
	key = js_runtime_key(c"length")
	js_runtime_define_data(rt, eval, key, js_runtime_number(rt, 1.0), 0, 0, 1)
	js_text_free(key)
	rt.eval_function = eval
	js_runtime_set(rt, rt.global, c"eval", eval)
