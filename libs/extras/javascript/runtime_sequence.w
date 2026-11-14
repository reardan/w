# Deep binary, logical, comma and conditional expression trees evaluate with an
# explicit work list, so a long `a && b && ...` or `a + b + ...` chain does not
# consume one JavaScript depth level per AST level. Only trees that cannot
# suspend (no await or yield inside) qualify: they never need frames, and no
# collection can run while they evaluate. Every visited node still consumes its
# step, and the work list is bounded by max_properties.
import libs.extras.javascript.runtime

# Chains shallower than this keep the recursive evaluator.
const int JS_SEQUENCE_THRESHOLD = 8

int js_sequence_node(js_node* node):
	return (js_kind(node, c"binary") && node.children.length == 2) || (js_kind(node, c"conditional") && node.children.length == 3)

# Nesting of binary/conditional nodes, capped at limit.
int js_sequence_depth(js_node* node, int limit):
	if (js_sequence_node(node) == 0): return 0
	int deepest = 0
	for i in range(node.children.length):
		if (deepest >= limit): break
		int depth = js_sequence_depth(node.children[i], limit)
		if (depth > deepest): deepest = depth
	return deepest + 1

int js_sequence_suspends(js_node* node):
	if (js_runtime_function_node(node)): return 0
	if (js_kind(node, c"yield") || js_kind(node, c"await") || js_kind(node, c"for_await_of")): return 1
	for i in range(node.children.length):
		if (js_sequence_suspends(node.children[i])): return 1
	return 0

# Whether root is evaluated by js_runtime_sequence; decided once per node.
int js_sequence_applies(js_node* root):
	if (root.sequence_use == 0):
		root.sequence_use = 1
		if (js_sequence_depth(root, JS_SEQUENCE_THRESHOLD) >= JS_SEQUENCE_THRESHOLD && js_sequence_suspends(root) == 0): root.sequence_use = 2
	return root.sequence_use == 2

int js_sequence_operator(char* operation):
	return strcmp(operation, c"&&") == 0 || strcmp(operation, c"||") == 0 || strcmp(operation, c"??") == 0 || strcmp(operation, c",") == 0

js_value* js_runtime_sequence(js_runtime* rt, js_node* root, js_value* env):
	list[js_node*] pending = new list[js_node*]
	list[js_value*] lefts = new list[js_value*]
	js_node* node = root
	js_value* result = rt.undefined_value
	while ((node != 0 || pending.length > 0) && rt.completion.status == 0):
		if (node != 0):
			if (js_sequence_node(node)):
				# The caller charged root; every other visited node consumes its step.
				if (node != root && js_runtime_compat_step(rt) == 0): break
				if (pending.length >= rt.max_properties):
					js_runtime_fail(rt, 5, c"JavaScript expression work-list limit")
					break
				pending.push(node)
				lefts.push(0)
				node = node.children[0]
			else:
				result = js_runtime_eval_node(rt, node, env)
				node = 0
			continue
		js_node* parent = pending.pop()
		js_value* left = lefts[lefts.length - 1]
		if (js_kind(parent, c"binary") && js_sequence_operator(parent.text) == 0):
			if (left == 0):
				# The left operand is done; evaluate the right one.
				pending.push(parent)
				lefts.pop()
				lefts.push(result)
				node = parent.children[1]
			else:
				lefts.pop()
				if (strcmp(parent.text, c"instanceof") == 0): result = js_runtime_instanceof(rt, left, result)
				else if (strcmp(parent.text, c"in") == 0): result = js_runtime_in_operator(rt, left, result)
				else: result = js_runtime_binary(rt, parent.text, left, result)
			continue
		lefts.pop()
		if (js_kind(parent, c"conditional")):
			if (js_runtime_truth(result)): node = parent.children[1]
			else: node = parent.children[2]
			continue
		int right = strcmp(parent.text, c",") == 0
		if (strcmp(parent.text, c"&&") == 0): right = js_runtime_truth(result)
		if (strcmp(parent.text, c"||") == 0): right = js_runtime_truth(result) == 0
		if (strcmp(parent.text, c"??") == 0): right = result.kind == 0 || result.kind == 1
		if (right): node = parent.children[1]
	__w_list_free(cast(__w_list*, pending))
	__w_list_free(cast(__w_list*, lefts))
	if (rt.completion.status != 0): return rt.undefined_value
	rt.empty = 0
	return result
