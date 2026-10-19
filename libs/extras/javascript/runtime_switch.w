# CaseBlock evaluation: one lexical scope across clauses, strict case
# comparison, lazy case tests, fallthrough and UpdateEmpty for abrupt exits.
import libs.extras.javascript.runtime

js_value* js_runtime_switch(js_runtime* rt, js_node* node, js_value* env):
	js_value* input = js_runtime_eval_node(rt, node.children[0], env)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* scope = js_runtime_environment(rt, env)
	# Declaration instantiation borrows AST statements; no AST is copied or
	# retained beyond this operation and cancellation owns no native resources.
	js_node declarations
	declarations.children = new list[js_node*]
	for i in range(1, node.children.length):
		js_node* clause = node.children[i]
		for j in range(1, clause.children.length): declarations.children.push(clause.children[j])
	js_runtime_declare(rt, &declarations, scope)
	__w_list_free(cast(__w_list*, declarations.children))
	int selected = -1
	int fallback = -1
	for i in range(1, node.children.length):
		if (rt.completion.status != 0): break
		js_node* test = node.children[i].children[0]
		if (js_kind(test, c"empty")): fallback = i
		else:
			js_value* candidate = js_runtime_eval_node(rt, test, scope)
			if (rt.completion.status == 0 && js_runtime_equal(input, candidate)):
				selected = i
				break
	if (selected == -1): selected = fallback
	js_value* result = rt.undefined_value
	if (selected != -1):
		for i in range(selected, node.children.length):
			js_node* clause = node.children[i]
			for j in range(1, clause.children.length):
				if (rt.completion.status != 0): break
				js_value* value = js_runtime_eval_node(rt, clause.children[j], scope)
				if (rt.empty == 0): result = value
			if (rt.completion.status != 0): break
	if (rt.completion.status == 3 && rt.jump_target == 0): rt.completion.status = 0
	rt.empty = 0
	return result
