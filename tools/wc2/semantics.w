# Per-compilation semantic tables. The parsed module stays immutable so
# inspection and repeated compilation can share it without stale bindings.
import tools.wc2.validate


struct wc2_semantics:
	wc2_module* module
	list[int] types
	list[int] bindings
	list[int] slots
	list[int] frames
	list[int] visible
	list[int] initialized
	list[int] masks
	int entry
	int current_function
	int frame_size


list[int] wc2_copy_ints(list[int] source):
	list[int] result = new list[int]
	for int value in source: result.push(value)
	return result


void wc2_free_ints(list[int] values):
	__w_list_free(cast(__w_list*, values))


wc2_semantics* wc2_semantics_new(wc2_module* m):
	wc2_semantics* s = new wc2_semantics()
	s.module = m
	s.types = new list[int]
	s.bindings = new list[int]
	s.slots = new list[int]
	s.frames = new list[int]
	s.visible = new list[int]
	s.initialized = new list[int]
	s.masks = new list[int]
	s.entry = -1
	s.current_function = -1
	s.frame_size = 0
	for wc2_node* node in m.nodes:
		s.types.push(node.type_id)
		s.bindings.push(-1)
		s.slots.push(0)
		s.frames.push(0)
		s.visible.push(0)
		s.initialized.push(0)
		s.masks.push(1)
	return s


void wc2_semantics_free(wc2_semantics* s):
	wc2_free_ints(s.types)
	wc2_free_ints(s.bindings)
	wc2_free_ints(s.slots)
	wc2_free_ints(s.frames)
	wc2_free_ints(s.visible)
	wc2_free_ints(s.initialized)
	wc2_free_ints(s.masks)
	free(s)


int wc2_lookup(wc2_semantics* s, wc2_node* node):
	int scope = node.scope
	while (scope >= 0):
		list[int] declarations = s.module.scopes[scope].declarations
		int i = declarations.length - 1
		while (i >= 0):
			int id = declarations[i]
			if (s.visible[id] && (strcmp(s.module.nodes[id].text, node.text) == 0)): return id
			i = i - 1
		scope = s.module.scopes[scope].parent
	return -1


void wc2_require_scalar(wc2_semantics* s, wc2_node* node, int type_id):
	if ((type_id != wc2_unresolved_type) && (type_id != wc2_int_type) && (type_id != wc2_bool_type) && (type_id != wc2_integer_literal_type)):
		wc2_node_error(s.module, node, c"wc2: expected an integer or boolean value")


int wc2_semantic_expression(wc2_semantics* s, wc2_node* node, int depth);


list[int] wc2_fields(wc2_semantics* s, int type_id):
	wc2_node* structure = s.module.nodes[type_id - wc2_struct_type_base]
	return wc2_child(s.module, structure, 0).children


int wc2_type_size(wc2_semantics* s, int type_id):
	if (type_id >= wc2_struct_type_base): return wc2_fields(s, type_id).length * 4
	return 4


int wc2_full_mask(wc2_semantics* s, int type_id):
	if (type_id >= wc2_struct_type_base): return (1 << wc2_fields(s, type_id).length) - 1
	return 1


void wc2_resolve_type(wc2_semantics* s, wc2_node* node):
	if (node.type_id != wc2_named_type): return
	for int id in s.module.scopes[0].declarations:
		wc2_node* structure = s.module.nodes[id]
		if (s.visible[id] && (structure.kind == wc2_struct_kind) && (strcmp(structure.text, node.type_name) == 0)):
			s.types[node.id] = wc2_struct_type_base + id
			return
	s.types[node.id] = wc2_unresolved_type
	wc2_node_error(s.module, node, c"wc2: unknown struct type or use before declaration")


void wc2_require_value(wc2_semantics* s, wc2_node* node, int want, int got):
	if ((want == wc2_unresolved_type) || (got == wc2_unresolved_type)): return
	if ((want >= wc2_struct_type_base) || (got >= wc2_struct_type_base)):
		if (want != got): wc2_node_error(s.module, node, c"wc2: incompatible struct value types")
	else: wc2_require_scalar(s, node, got)


int wc2_resolve_variable(wc2_semantics* s, wc2_node* node, int reading):
	wc2_node* base = node
	if (node.kind == wc2_member_kind): base = wc2_child(s.module, node, 0)
	if (base.kind != wc2_name_kind):
		wc2_node_error(s.module, node, c"wc2: field access currently requires a named struct variable")
		return -1
	int id = wc2_lookup(s, base)
	if (id < 0):
		wc2_node_error(s.module, node, c"wc2: unknown name or use before declaration")
		return -1
	wc2_node* declaration = s.module.nodes[id]
	if ((declaration.kind != wc2_declaration_kind) && (declaration.kind != wc2_parameter_kind)):
		wc2_node_error(s.module, node, c"wc2: expected a variable, not a function value")
		return -1
	s.bindings[node.id] = id
	s.types[node.id] = s.types[id]
	s.slots[node.id] = s.slots[id]
	s.masks[node.id] = wc2_full_mask(s, s.types[id])
	if (node.kind == wc2_member_kind):
		if (s.types[id] < wc2_struct_type_base):
			wc2_node_error(s.module, node, c"wc2: field access requires a struct variable")
			return -1
		list[int] fields = wc2_fields(s, s.types[id])
		int found = 0
		for i in range(fields.length):
			wc2_node* field = s.module.nodes[fields[i]]
			if (strcmp(field.text, node.text) == 0):
				s.types[node.id] = s.types[field.id]
				s.slots[node.id] = s.slots[id] + 4 * i
				s.masks[node.id] = 1 << i
				found = 1
		if (found == 0):
			wc2_node_error(s.module, node, c"wc2: unknown struct field")
			return -1
	if (reading && ((s.initialized[id] & s.masks[node.id]) != s.masks[node.id])):
		wc2_node_error(s.module, node, c"wc2: variable or field may be uninitialized")
	return id


int wc2_semantic_expression(wc2_semantics* s, wc2_node* node, int depth):
	wc2_module* m = s.module
	int type_id = wc2_unresolved_type
	if (depth > 200):
		wc2_node_error(m, node, c"wc2: executable expression nesting limit exceeded")
		return type_id
	if (node.kind == wc2_integer_kind):
		int value = 0
		if (wc2_integer32(node.text, &value) == 0): wc2_node_error(m, node, c"wc2: integer literal exceeds 32 significant bits")
		return s.types[node.id]
	if ((node.kind == wc2_name_kind) || (node.kind == wc2_member_kind)):
		wc2_resolve_variable(s, node, 1)
		return s.types[node.id]
	if (node.kind == wc2_call_kind):
		wc2_node* callee = wc2_child(m, node, 0)
		int id = -1
		if (callee.kind == wc2_name_kind): id = wc2_lookup(s, callee)
		if ((id < 0) || (m.nodes[id].kind != wc2_function_kind)):
			wc2_node_error(m, callee, c"wc2: call requires a previously declared function")
		else:
			s.bindings[node.id] = id
			s.bindings[callee.id] = id
			type_id = s.types[id]
			if (node.children.length != m.nodes[id].children.length): wc2_node_error(m, node, c"wc2: wrong number of function arguments")
		for i in range(1, node.children.length):
			wc2_node* arg = wc2_child(m, node, i)
			int got = wc2_semantic_expression(s, arg, depth + 1)
			if ((id >= 0) && (m.nodes[id].kind == wc2_function_kind) && (i < m.nodes[id].children.length)):
				wc2_require_value(s, arg, s.types[m.nodes[id].children[i - 1]], got)
	elif (node.kind == wc2_assignment_kind):
		wc2_node* left = wc2_child(m, node, 0)
		int id = wc2_resolve_variable(s, left, strcmp(node.text, c"=") != 0)
		wc2_node* right = wc2_child(m, node, 1)
		int got = wc2_semantic_expression(s, right, depth + 1)
		wc2_require_value(s, right, s.types[left.id], got)
		if (strcmp(node.text, c"=") != 0):
			wc2_require_scalar(s, left, s.types[left.id])
			wc2_require_scalar(s, right, got)
		if (id >= 0):
			s.initialized[id] = s.initialized[id] | s.masks[left.id]
			type_id = s.types[left.id]
	elif ((node.kind == wc2_unary_kind) || (node.kind == wc2_binary_kind) || (node.kind == wc2_logical_kind)):
		wc2_node* left = wc2_child(m, node, 0)
		wc2_require_scalar(s, left, wc2_semantic_expression(s, left, depth + 1))
		if (node.children.length == 2):
			list[int] before = wc2_copy_ints(s.initialized)
			wc2_node* right = wc2_child(m, node, 1)
			wc2_require_scalar(s, right, wc2_semantic_expression(s, right, depth + 1))
			if (node.kind == wc2_logical_kind):
				for i in range(before.length): s.initialized[i] = before[i] & s.initialized[i]
			wc2_free_ints(before)
		type_id = wc2_int_type
		int precedence = wc2_precedence(node.text)
		if ((node.kind == wc2_logical_kind) || (strcmp(node.text, c"!") == 0) || ((precedence >= 6) && (precedence <= 7))): type_id = wc2_bool_type
	else: wc2_node_error(m, node, c"wc2: unsupported executable expression")
	s.types[node.id] = type_id
	return type_id


# Flow bits: fallthrough=1, return=2, break=4, continue=8. Definite
# initialization merges only branches that reach the following statement.
int wc2_semantic_statement(wc2_semantics* s, wc2_node* node, int loops):
	wc2_module* m = s.module
	if (node.kind == wc2_block_kind):
		int flow = 1
		for int id in node.children:
			int next = wc2_semantic_statement(s, m.nodes[id], loops)
			if (flow & 1): flow = (flow & 14) | next
		return flow
	if (node.kind == wc2_declaration_kind):
		wc2_resolve_type(s, node)
		int inferred = node.type_id == wc2_unresolved_type
		if (inferred):
			int existing = wc2_lookup(s, node)
			if ((existing >= 0) && (m.nodes[existing].scope != 0)): wc2_node_error(m, node, c"wc2: := redeclares a visible variable")
		else:
			s.visible[node.id] = 1
			s.frame_size = s.frame_size + wc2_type_size(s, s.types[node.id])
			s.slots[node.id] = 0 - s.frame_size
		if (node.type_id == wc2_void_type): wc2_node_error(m, node, c"wc2: variable cannot have void type")
		if (node.children.length):
			wc2_node* value = wc2_child(m, node, 0)
			int got = wc2_semantic_expression(s, value, 0)
			if (inferred):
				if (got < wc2_struct_type_base): wc2_require_scalar(s, value, got)
				if (got == wc2_integer_literal_type): got = wc2_int_type
				s.types[node.id] = got
			else: wc2_require_value(s, value, s.types[node.id], got)
			s.initialized[node.id] = wc2_full_mask(s, s.types[node.id])
		s.visible[node.id] = 1
		if (inferred):
			s.frame_size = s.frame_size + wc2_type_size(s, s.types[node.id])
			s.slots[node.id] = 0 - s.frame_size
		return 1
	if (node.kind == wc2_return_kind):
		int want = s.types[s.current_function]
		if (node.children.length):
			wc2_node* value = wc2_child(m, node, 0)
			wc2_require_scalar(s, value, wc2_semantic_expression(s, value, 0))
			if (want == wc2_void_type): wc2_node_error(m, node, c"wc2: void function cannot return a value")
		elif (want != wc2_void_type): wc2_node_error(m, node, c"wc2: non-void function must return a value")
		return 2
	if (node.kind == wc2_expression_statement_kind):
		wc2_semantic_expression(s, wc2_child(m, node, 0), 0)
		return 1
	if ((node.kind == wc2_if_kind) || (node.kind == wc2_while_kind)):
		wc2_node* condition = wc2_child(m, node, 0)
		wc2_require_scalar(s, condition, wc2_semantic_expression(s, condition, 0))
		list[int] before = wc2_copy_ints(s.initialized)
		int nested_loops = loops
		if (node.kind == wc2_while_kind): nested_loops = loops + 1
		int then_flow = wc2_semantic_statement(s, wc2_child(m, node, 1), nested_loops)
		list[int] then_state = s.initialized
		s.initialized = wc2_copy_ints(before)
		int else_flow = 1
		if ((node.kind == wc2_if_kind) && (node.children.length == 3)):
			else_flow = wc2_semantic_statement(s, wc2_child(m, node, 2), loops)
		if (node.kind == wc2_if_kind):
			for i in range(before.length):
				if ((then_flow & 1) && (else_flow & 1)): s.initialized[i] = then_state[i] & s.initialized[i]
				elif (then_flow & 1): s.initialized[i] = then_state[i]
		wc2_free_ints(then_state)
		wc2_free_ints(before)
		if (node.kind == wc2_while_kind): return 1 | (then_flow & 2)
		return then_flow | else_flow
	if ((node.kind == wc2_break_kind) || (node.kind == wc2_continue_kind)):
		if (loops == 0): wc2_node_error(m, node, c"wc2: break/continue outside a loop")
		if (node.kind == wc2_break_kind): return 4
		return 8
	if (node.kind != wc2_pass_kind): wc2_node_error(m, node, c"wc2: unsupported executable statement")
	return 1


void wc2_semantic_struct(wc2_semantics* s, wc2_node* node):
	wc2_module* m = s.module
	if (wc2_lookup(s, node) >= 0): wc2_node_error(m, node, c"wc2: duplicate top-level name")
	s.visible[node.id] = 1
	s.types[node.id] = wc2_struct_type_base + node.id
	list[int] fields = wc2_fields(s, s.types[node.id])
	if ((fields.length == 0) || (fields.length > 30)): wc2_node_error(m, node, c"wc2: structs currently require 1 to 30 scalar fields")
	for i in range(fields.length):
		wc2_node* field = m.nodes[fields[i]]
		if ((field.kind != wc2_declaration_kind) || ((field.type_id != wc2_int_type) && (field.type_id != wc2_bool_type)) || (field.children.length != 0)):
			wc2_node_error(m, field, c"wc2: struct fields must be uninitialized int or bool declarations")
		for j in range(i):
			if (strcmp(m.nodes[fields[j]].text, field.text) == 0): wc2_node_error(m, field, c"wc2: duplicate struct field")


wc2_semantics* wc2_analyze(wc2_module* m):
	wc2_semantics* s = wc2_semantics_new(m)
	if (wc2_module_ok(m) == 0): return s
	wc2_node* root = m.nodes[m.root]
	for int id in root.children:
		wc2_node* fn_node = m.nodes[id]
		if (fn_node.kind == wc2_struct_kind):
			wc2_semantic_struct(s, fn_node)
			continue
		if (fn_node.kind != wc2_function_kind):
			wc2_node_error(m, fn_node, c"wc2: executable top level currently supports functions only")
			continue
		if (wc2_lookup(s, fn_node) >= 0): wc2_node_error(m, fn_node, c"wc2: duplicate function name")
		s.visible[id] = 1
		s.current_function = id
		s.frame_size = 0
		wc2_resolve_type(s, fn_node)
		if (s.types[id] >= wc2_struct_type_base): wc2_node_error(m, fn_node, c"wc2: struct return values are not supported yet")
		int count = fn_node.children.length - 1
		if (strcmp(fn_node.text, c"main") == 0):
			s.entry = id
			if ((count != 0) || (fn_node.type_id != wc2_int_type)): wc2_node_error(m, fn_node, c"wc2: executable requires int main() with no parameters")
		int argument_size = 0
		for i in range(count):
			wc2_node* param = wc2_child(m, fn_node, i)
			wc2_resolve_type(s, param)
			argument_size = argument_size + wc2_type_size(s, s.types[param.id])
		for i in range(count):
			wc2_node* param = wc2_child(m, fn_node, i)
			int existing = wc2_lookup(s, param)
			if ((existing >= 0) && (m.nodes[existing].scope == param.scope)): wc2_node_error(m, param, c"wc2: duplicate parameter name")
			if (param.type_id == wc2_void_type): wc2_node_error(m, param, c"wc2: parameter cannot have void type")
			s.visible[param.id] = 1
			s.initialized[param.id] = wc2_full_mask(s, s.types[param.id])
			argument_size = argument_size - wc2_type_size(s, s.types[param.id])
			s.slots[param.id] = 8 + argument_size
		int flow = wc2_semantic_statement(s, wc2_child(m, fn_node, count), 0)
		if ((fn_node.type_id != wc2_void_type) && (flow & 1)): wc2_node_error(m, fn_node, c"wc2: non-void function may reach its end without returning")
		s.frames[id] = s.frame_size
	if (s.entry < 0): wc2_node_error(m, root, c"wc2: executable requires int main()")
	return s
