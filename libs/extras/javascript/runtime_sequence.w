# Logical/comma/conditional expression trees evaluate iteratively. Their AST nesting
# does not represent nested JavaScript calls; fuel and work-list size remain bounded.
import libs.extras.javascript.runtime

int js_sequence_operator(char* operation):
	return strcmp(operation, c"&&") == 0 || strcmp(operation, c"||") == 0 || strcmp(operation, c"??") == 0 || strcmp(operation, c",") == 0

js_value* js_runtime_sequence(js_runtime* rt, js_node* root, js_value* env):
	list[js_node*] pending = new list[js_node*]
	js_node* node = root
	js_value* result = rt.undefined_value
	while ((node != 0 || pending.length > 0) && rt.completion.status == 0):
		if (node != 0):
			if (js_kind(node, c"conditional") || (js_kind(node, c"binary") && js_sequence_operator(node.text))):
				# Entry already charged root. Every other visited branching/comma
				# node consumes its original step, even when its right is skipped.
				if (node != root && js_runtime_compat_step(rt) == 0): break
				if (pending.length >= rt.max_properties):
					js_runtime_fail(rt, 5, c"JavaScript expression work-list limit")
					break
				pending.push(node)
				node = node.children[0]
			else:
				result = js_runtime_eval_node(rt, node, env)
				node = 0
		else:
			js_node* parent = pending.pop()
			int right = strcmp(parent.text, c",") == 0
			if (strcmp(parent.text, c"&&") == 0): right = js_runtime_truth(result)
			if (strcmp(parent.text, c"||") == 0): right = js_runtime_truth(result) == 0
			if (strcmp(parent.text, c"??") == 0): right = result.kind == 0 || result.kind == 1
			if (js_kind(parent, c"conditional")):
				if (js_runtime_truth(result)): node = parent.children[1]
				else: node = parent.children[2]
			else if (right): node = parent.children[1]
	__w_list_free(cast(__w_list*, pending))
	return result
