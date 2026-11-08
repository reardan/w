import libs.extras.javascript.runtime

void js_runtime_pattern_names(js_node* pattern, list[js_node*] names);

# Annex B.3.3 / B.3.4 web-compat function declarations in blocks and in
# if-statement clauses, for non-strict function and script bodies only.
# Imported by runtime.w after its core.
#
# A block-level `function f` also gets a var binding `f` (initially undefined)
# in the enclosing function or script when a `var f` there would not be an
# early error: no let/const/class or enclosing block function named `f` lies
# between the block and the body, and `f` is not a parameter name. Evaluating
# the declaration statement copies the block's current `f` into that binding.
# An `if (x) function f() {}` clause behaves as `if (x) { function f() {} }`.


int js_annexb_listed(list[js_node*] nodes, js_node* node):
	if (nodes == 0): return 0
	for js_node* item in nodes:
		if (item == node): return 1
	return 0


int js_annexb_named(list[char*] names, char* name):
	for char* item in names:
		if (strcmp(item, name) == 0): return 1
	return 0


# Names a statement list declares lexically: let/const and class bindings,
# plus block-level functions when functions is set.
void js_annexb_lexical_names(js_node* block, list[char*] names, int functions):
	for js_node* statement in block.children:
		if (js_kind(statement, c"variable") && strcmp(statement.text, c"var") != 0):
			for js_node* declarator in statement.children:
				list[js_node*] bound = new list[js_node*]
				js_runtime_pattern_names(declarator.children[0], bound)
				for js_node* name in bound: names.push(name.text)
				__w_list_free(cast(__w_list*, bound))
		if (js_kind(statement, c"class") && strlen(statement.text) > 0): names.push(statement.text)
		if (functions && js_kind(statement, c"function")): names.push(statement.text)


struct js_annexb_scan:
	js_runtime* rt
	js_value* env
	list[char*] parameters


void js_annexb_qualify(js_annexb_scan* scan, js_node* function, list[char*] outer, int clause):
	char* name = function.text
	if (js_annexb_named(outer, name) || js_annexb_named(scan.parameters, name)): return
	js_runtime* rt = scan.rt
	js_text* key = js_runtime_key(name)
	js_value* binding = js_runtime_property(scan.env, key)
	# A global lexical declaration from an earlier script also blocks it.
	if (binding != 0 && binding.lexical_binding):
		js_text_free(key)
		return
	if (binding == 0 && scan.env == rt.global): js_runtime_global_declare(rt, key, 0, 0)
	else if (binding == 0):
		js_runtime_put(rt, scan.env, key, rt.undefined_value)
		binding = js_runtime_property(scan.env, key)
		if (binding != 0):
			binding.initialized = 1
			binding.lexical_binding = 0
	js_text_free(key)
	if (clause):
		if (rt.annexb_clause_functions == 0): rt.annexb_clause_functions = new list[js_node*]
		if (js_annexb_listed(rt.annexb_clause_functions, function) == 0): rt.annexb_clause_functions.push(function)
	else:
		if (rt.annexb_functions == 0): rt.annexb_functions = new list[js_node*]
		if (js_annexb_listed(rt.annexb_functions, function) == 0): rt.annexb_functions.push(function)


void js_annexb_visit(js_annexb_scan* scan, js_node* node, list[char*] outer):
	if (js_kind(node, c"function") || js_kind(node, c"function_expression") || js_kind(node, c"arrow")): return
	int count = outer.length
	if (js_kind(node, c"block")):
		# Siblings may repeat a sloppy block function name (B.3.3.4); only
		# let/const/class in the same block conflict with the var binding.
		js_annexb_lexical_names(node, outer, 0)
		for js_node* child in node.children:
			if (js_kind(child, c"function")): js_annexb_qualify(scan, child, outer, 0)
		while (outer.length > count): outer.pop()
		js_annexb_lexical_names(node, outer, 1)
	if (js_kind(node, c"switch")):
		# The CaseBlock is one lexical scope spanning every clause.
		for i in range(1, node.children.length): js_annexb_lexical_names(node.children[i], outer, 0)
		for i in range(1, node.children.length):
			for js_node* child in node.children[i].children:
				if (js_kind(child, c"function")): js_annexb_qualify(scan, child, outer, 0)
		while (outer.length > count): outer.pop()
		for i in range(1, node.children.length): js_annexb_lexical_names(node.children[i], outer, 1)
	if (js_kind(node, c"if")):
		for i in range(1, node.children.length):
			if (js_kind(node.children[i], c"function")): js_annexb_qualify(scan, node.children[i], outer, 1)
	# A destructured catch parameter's names conflict (B.3.5 exempts only a
	# simple one).
	if (js_kind(node, c"catch") && node.children.length == 2):
		list[js_node*] caught = new list[js_node*]
		js_runtime_pattern_names(node.children[0], caught)
		for js_node* name in caught: outer.push(name.text)
		__w_list_free(cast(__w_list*, caught))
	if ((js_kind(node, c"for") && js_kind(node.children[0], c"variable")) || js_kind(node, c"for_of") || js_kind(node, c"for_in")):
		js_node* head = node
		if (js_kind(node, c"for")): head = node.children[0]
		if (strcmp(head.text, c"let") == 0 || strcmp(head.text, c"const") == 0):
			list[js_node*] bound = new list[js_node*]
			if (js_kind(node, c"for_of") || js_kind(node, c"for_in")): js_runtime_pattern_names(node.children[0], bound)
			else:
				for js_node* declarator in head.children: js_runtime_pattern_names(declarator.children[0], bound)
			for js_node* name in bound: outer.push(name.text)
			__w_list_free(cast(__w_list*, bound))
	for js_node* child in node.children: js_annexb_visit(scan, child, outer)
	while (outer.length > count): outer.pop()


# Called after the var pass of a non-strict function or script body.
void js_annexb_declare(js_runtime* rt, js_node* body, js_value* env):
	if (rt.completion.status != 0 || env.strict): return
	js_annexb_scan scan
	scan.rt = rt
	scan.env = env
	scan.parameters = new list[char*]
	# Eval code (B.3.3.3) does not skip parameter names.
	if (rt.eval_code == 0 && env.code != 0 && env.code.children.length > 0 && js_kind(env.code.children[0], c"parameters")):
		list[js_node*] bound = new list[js_node*]
		js_runtime_pattern_names(env.code.children[0], bound)
		for js_node* name in bound: scan.parameters.push(name.text)
		__w_list_free(cast(__w_list*, bound))
	list[char*] outer = new list[char*]
	# Body-level functions are var-scoped already; only let/const/class conflict.
	js_annexb_lexical_names(body, outer, 0)
	for js_node* child in body.children: js_annexb_visit(&scan, child, outer)
	__w_list_free(cast(__w_list*, outer))
	__w_list_free(cast(__w_list*, scan.parameters))


js_value* js_annexb_variable_environment(js_value* env):
	while (env != 0 && env.variable_scope == 0): env = env.parent
	return env


# Evaluates a FunctionDeclaration statement. Returns 1 when Annex B handled it.
int js_annexb_evaluate(js_runtime* rt, js_node* node, js_value* env):
	int clause = js_annexb_listed(rt.annexb_clause_functions, node)
	if (clause == 0 && js_annexb_listed(rt.annexb_functions, node) == 0): return 0
	js_text* key = js_runtime_key(node.text)
	js_value* value = 0
	if (clause):
		js_value* block = js_runtime_environment(rt, env)
		value = js_runtime_function(rt, node, block)
		js_runtime_put(rt, block, key, value)
	else:
		js_value* binding = js_runtime_binding(env, node.text)
		if (binding != 0): value = js_runtime_binding_value(rt, binding)
	js_value* target = js_annexb_variable_environment(env)
	if (value != 0 && target == rt.global && rt.completion.status == 0): js_runtime_member_write(rt, rt.global_object, key, value)
	else if (value != 0 && target != 0 && rt.completion.status == 0): js_runtime_put(rt, target, key, value)
	js_text_free(key)
	return 1
