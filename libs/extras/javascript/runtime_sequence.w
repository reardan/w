# Binary and conditional expression trees evaluate iteratively. Their AST nesting
# does not represent nested JavaScript calls; fuel and work-list size remain bounded.
import libs.extras.javascript.runtime

# Records live on the evaluator stack, including suspended async stacks. Removal
# is by identity because another task can suspend/resume between this task's turns.
struct js_sequence_roots:
	list[js_value*] values
	js_value* current
	js_sequence_roots* next

void js_sequence_mark(js_runtime* rt, list[js_value*] pending):
	js_sequence_roots* roots = cast(js_sequence_roots*, rt.expression_roots)
	while (roots != 0):
		js_runtime_mark(pending, roots.current)
		for i in range(roots.values.length): js_runtime_mark(pending, roots.values[i])
		roots = roots.next

void js_sequence_release(js_runtime* rt, js_sequence_roots* roots):
	js_sequence_roots* previous = 0
	js_sequence_roots* current = cast(js_sequence_roots*, rt.expression_roots)
	while (current != roots && current != 0):
		previous = current
		current = current.next
	if (current != 0):
		if (previous == 0): rt.expression_roots = roots.next
		else: previous.next = roots.next

int js_sequence_operator(char* operation):
	return strcmp(operation, c"&&") == 0 || strcmp(operation, c"||") == 0 || strcmp(operation, c"??") == 0 || strcmp(operation, c",") == 0

js_value* js_runtime_sequence(js_runtime* rt, js_node* root, js_value* env):
	list[js_node*] pending = new list[js_node*]
	list[js_value*] lefts = new list[js_value*]
	js_sequence_roots roots
	roots.values = lefts
	roots.current = 0
	roots.next = cast(js_sequence_roots*, rt.expression_roots)
	rt.expression_roots = &roots
	js_node* node = root
	js_value* result = rt.undefined_value
	while ((node != 0 || pending.length > 0) && rt.completion.status == 0):
		if (node != 0):
			if (js_kind(node, c"conditional") || js_kind(node, c"binary")):
				# Entry already charged root. Every other visited expression
				# node consumes its original step, even when its right is skipped.
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
		else:
			js_node* parent = pending.pop()
			js_value* left = lefts[lefts.length - 1]
			if (js_kind(parent, c"binary") && js_sequence_operator(parent.text) == 0):
				if (left == 0):
					pending.push(parent)
					lefts.pop()
					lefts.push(result)
					node = parent.children[1]
				else:
					roots.current = result
					result = js_runtime_binary(rt, parent.text, left, result)
					roots.current = 0
					lefts.pop()
				continue
			lefts.pop()
			int right = strcmp(parent.text, c",") == 0
			if (strcmp(parent.text, c"&&") == 0): right = js_runtime_truth(result)
			if (strcmp(parent.text, c"||") == 0): right = js_runtime_truth(result) == 0
			if (strcmp(parent.text, c"??") == 0): right = result.kind == 0 || result.kind == 1
			if (js_kind(parent, c"conditional")):
				if (js_runtime_truth(result)): node = parent.children[1]
				else: node = parent.children[2]
			else if (right): node = parent.children[1]
	js_sequence_release(rt, &roots)
	__w_list_free(cast(__w_list*, pending))
	__w_list_free(cast(__w_list*, lefts))
	return result
