import compiler.safe_runtime

# Ownership analysis over resolved retained syntax. The graph is independent
# of backend emission and optimizations. No artifact is published before this
# pass succeeds. Unknown syntax and unknown call contracts fail closed.
int safe_mode
int safe_bounds_disabled
list[int] safe_trusted_sources
int* safe_first
int* safe_next
int* safe_function_for_binding
int* safe_checked_functions

struct safe_flow:
	int node
	int expression
	int binding
	int action
	int next
	int alternate
	int reached
	char* state
	char* live
	char* uses

list[safe_flow*] safe_graph
list[int] safe_locals
map[int, int] safe_local_index
int* safe_origin
int* safe_parent_ref
int* safe_birth
int* safe_moved_at
int safe_function
int safe_return_type
int safe_return_root
int safe_validate
int safe_event
int safe_position
list[int] safe_call_roots
list[int] safe_call_kinds


char* safe_zero(int count, int width):
	int size = count * width
	char* result = cast(char*, malloc(size + 1))
	for i in range(size + 1): result[i] = 0
	return result




void safe_reset():
	safe_mode = 0
	safe_bounds_disabled = 0
	if (safe_trusted_sources != 0): safe_trusted_sources.free()
	safe_trusted_sources = 0


void safe_trust_sources(int first):
	if (retained_sources == 0): return
	if (safe_trusted_sources == 0): safe_trusted_sources = new list[int]
	while (safe_trusted_sources.length < retained_sources.length): safe_trusted_sources.push(0)
	for i in range(first, retained_sources.length): safe_trusted_sources[i] = 1


int safe_trusted(int source):
	if ((source < 0) || (safe_trusted_sources == 0)): return 0
	if (source >= safe_trusted_sources.length): return 0
	return safe_trusted_sources[source]


void safe_error(int id, char* message, int related):
	retained_node node
	retained_node_load(id, &node)
	filename = retained_sources[node.source].path
	diag_token_line = node.line
	diag_token_column = node.column
	line_number = node.line - 1
	token = node.name
	if (related >= 0):
		retained_node other
		retained_node_load(related, &other)
		diag_related_add(retained_sources[other.source].path, other.line, other.column, c"ownership or borrow originates here")
	error(message)


int safe_unqualified(int type):
	while (type >= 0):
		retained_type* t = retained_types[type]
		if ((t.kind != type_kind_alias) && (t.kind != type_kind_const)): return type
		type = t.target
	return type


int safe_kind(int type):
	type = safe_unqualified(type)
	if (type < 0): return 0
	int kind = retained_types[type].kind
	if ((kind >= type_kind_own) && (kind <= type_kind_refmut)): return kind - 20
	return 0


int safe_contains_checked(int type, int depth):
	if ((type < 0) || (depth > 32)): return 0
	if (safe_kind(type)): return 1
	retained_type* t = retained_types[type]
	if (safe_contains_checked(t.target, depth + 1)): return 1
	if (safe_contains_checked(t.return_type, depth + 1)): return 1
	for i in range(t.parameters.length):
		if (safe_contains_checked(t.parameters[i], depth + 1)): return 1
	return 0


int safe_slice(int type):
	type = safe_unqualified(type)
	if (type < 0): return 0
	return retained_types[type].kind == type_kind_slice


int safe_borrow_kind(int type):
	if (safe_slice(type)): return 2
	return safe_kind(type)


int safe_plain(int type, int depth):
	type = safe_unqualified(type)
	if ((type < 0) || (depth > 32)): return 0
	retained_type* t = retained_types[type]
	if (t.pointer_level || safe_kind(type)): return 0
	if (((t.kind == 0) && (t.fields.length > 0)) || (t.kind == type_kind_array)):
		if (t.kind == type_kind_array): return safe_plain(t.target, depth + 1)
		for i in range(t.fields.length):
			if (safe_plain(t.fields[i].type, depth + 1) == 0): return 0
		return 1
	# Scalars only; in particular strings, unions, containers, functions and
	# slices cannot be mistaken for pointer-free values.
	int raw = t.origin
	return (((strcmp(t.name, c"int") == 0) || (strcmp(t.name, c"uint") == 0) || (strcmp(t.name, c"char") == 0) || (strcmp(t.name, c"byte") == 0) || (strcmp(t.name, c"bool") == 0) || (t.kind == type_kind_enum) || ((t.kind == 0) && type_var_boxable(raw))) || (type_float_kind(raw) != 0) || (strcmp(t.name, c"void") == 0) || (strcmp(t.name, c"constant") == 0))


int safe_has_array(int type, int depth):
	type = safe_unqualified(type)
	if ((type < 0) || (depth > 32)): return 0
	retained_type* t = retained_types[type]
	if (t.pointer_level || safe_kind(type)): return 0
	if (t.kind == type_kind_array): return 1
	for i in range(t.fields.length):
		if (safe_has_array(t.fields[i].type, depth + 1)): return 1
	return 0


int safe_pointee(int type):
	type = safe_unqualified(type)
	if (safe_slice(type)): return retained_types[type].target
	if (safe_kind(type)): type = retained_types[type].target
	if (type < 0): return -1
	return retained_types[type].target


void safe_pointer_match(int id, int want, int got):
	int w = safe_unqualified(safe_pointee(want))
	int g = safe_unqualified(safe_pointee(got))
	if ((w < 0) || (g < 0)): safe_error(id, c"safe: incompatible checked pointer types", -1)
	if (strcmp(retained_types[w].name, retained_types[g].name) != 0):
		safe_error(id, c"safe: incompatible checked pointer types", -1)


void safe_type_check(int id, int type):
	if (safe_kind(type) || safe_slice(type)):
		if (safe_plain(safe_pointee(type), 0)): return
	else if (safe_plain(type, 0)): return
	safe_error(id, c"safe: unsupported type or reference-bearing aggregate", -1)


int safe_index(int binding):
	return safe_local_index.get(binding, -1)


int safe_local_kind(int index):
	return safe_borrow_kind(retained_bindings[safe_locals[index]].type)


int safe_add(int node, int expression, int binding, int action, int next, int alternate):
	safe_flow* f = new safe_flow
	f.node = node
	f.expression = expression
	f.binding = binding
	f.action = action
	f.next = next
	f.alternate = alternate
	f.reached = 0
	f.state = cast(char*, safe_zero(safe_locals.length, 1))
	f.live = cast(char*, safe_zero(safe_locals.length, 1))
	f.uses = cast(char*, safe_zero(safe_locals.length, 1))
	int result = safe_graph.length
	safe_graph.push(f)
	return result


int safe_expr_root(int group):
	if (group < 0): return -1
	return group + 1 + retained_record_at(group).group.root


# Children of an expression are group-local indices in the production AST.
int safe_child(retained_node* node, int child):
	if (child < 0): return -1
	return node.parent + 1 + child


void safe_unsafe_check(int id):
	retained_record* n = retained_record_at(id)
	if (n.kind == retained_statement):
		if ((strcmp(n.name, c"return") == 0) || (strcmp(n.name, c"break") == 0) || (strcmp(n.name, c"continue") == 0) || (strcmp(n.name, c"defer") == 0) || (strcmp(n.name, c"goto") == 0) || (strcmp(n.name, c"yield") == 0)):
			safe_error(id, c"safe: unsafe blocks cannot transfer control or defer work", -1)
	if (safe_contains_checked(n.semantic_type, 0)): safe_error(id, c"safe: unsafe blocks cannot manipulate checked pointers", -1)
	if (n.kind == retained_expression_group):
		for i in range(n.group.count):
			retained_node expr
			retained_node_load(id + 1 + i, &expr)
			if (safe_contains_checked(expr.semantic_type, 0)): safe_error(id, c"safe: unsafe blocks cannot manipulate checked pointers", -1)
			if ((expr.op == 'C') && (expr.binding >= 0)):
				retained_binding* callee = retained_bindings[expr.binding]
				for j in range(callee.parameters.length):
					if (safe_contains_checked(callee.parameters[j], 0)): safe_error(id, c"safe: checked calls must remain outside unsafe blocks", -1)
	int child = safe_first[id]
	while (child >= 0):
		safe_unsafe_check(child)
		child = safe_next[child]


int safe_build(int id, int next, int break_to, int continue_to);


int safe_sequence(int first, int next, int break_to, int continue_to):
	if (first < 0): return next
	int rest = safe_sequence(safe_next[first], next, break_to, continue_to)
	return safe_build(first, rest, break_to, continue_to)


int safe_build(int id, int next, int break_to, int continue_to):
	retained_record* n = retained_record_at(id)
	if (n.kind == retained_local): return next
	if (n.kind == retained_expression_group): return safe_add(id, safe_expr_root(id), -1, 0, next, -1)
	if (n.kind != retained_statement): safe_error(id, c"safe: unsupported statement representation", -1)
	char* name = n.name
	if (strcmp(name, c"unsafe block") == 0):
		safe_unsafe_check(id)
		return next
	if ((strcmp(name, c"defer") == 0) || (strcmp(name, c"yield") == 0) || (strcmp(name, c"goto") == 0) || (strcmp(name, c"asm") == 0) || (strcmp(name, c"switch") == 0) || (strcmp(name, c"for") == 0)):
		safe_error(id, c"safe: unsupported control flow or deferred operation", -1)
	if ((strcmp(name, c":") == 0) || (strcmp(name, c"{") == 0)):
		int cleanup = safe_add(id, -1, -1, 3, next, -1)
		return safe_sequence(safe_first[id], cleanup, break_to, continue_to)
	if ((strcmp(name, c"pass") == 0) || (strcmp(name, c"debugger") == 0)): return next
	if (strcmp(name, c"break") == 0): return safe_add(id, -1, -1, 0, break_to, -1)
	if (strcmp(name, c"continue") == 0): return safe_add(id, -1, -1, 0, continue_to, -1)
	int group = -1
	int local = -1
	int first_body = -1
	int second_body = -1
	int child = safe_first[id]
	while (child >= 0):
		retained_record* c = retained_record_at(child)
		if (c.kind == retained_expression_group):
			if (group >= 0): safe_error(id, c"safe: unsupported multiple-expression statement", -1)
			group = child
		else if (c.kind == retained_local): local = c.binding
		else if (c.kind == retained_statement):
			if (first_body < 0): first_body = child
			else if (second_body < 0): second_body = child
			else: safe_error(id, c"safe: unsupported control flow", -1)
		else: safe_error(child, c"safe: unsupported statement child", -1)
		child = safe_next[child]
	if (strcmp(name, c"if") == 0):
		int yes = safe_build(first_body, next, break_to, continue_to)
		int no = next
		if (second_body >= 0): no = safe_build(second_body, next, break_to, continue_to)
		return safe_add(id, safe_expr_root(group), -1, 0, yes, no)
	if (strcmp(name, c"while") == 0):
		int guard = safe_add(id, safe_expr_root(group), -1, 0, -1, next)
		safe_graph[guard].next = safe_build(first_body, guard, next, guard)
		return guard
	if (strcmp(name, c"return") == 0): return safe_add(id, safe_expr_root(group), -1, 2, -1, -1)
	if (local >= 0):
		char* scope = retained_record_at(n.parent).name
		if ((strcmp(scope, c":") != 0) && (strcmp(scope, c"{") != 0)):
			safe_error(id, c"safe: declarations require a lexical block", -1)
		return safe_add(id, safe_expr_root(group), safe_index(local), 1, next, -1)
	if ((first_body >= 0) || (group < 0)):
		safe_error(id, c"safe: unsupported statement (including defer, goto, assembly, generators and container iteration)", -1)
	return safe_add(id, safe_expr_root(group), -1, 0, next, -1)


void safe_read(int index, int id, char* state):
	if ((index >= 0) && safe_validate && (state[index] != 2)):
		int cause = safe_birth[index]
		if ((state[index] & 4) && (safe_moved_at[index] >= 0)): cause = safe_moved_at[index]
		safe_error(id, c"safe: use of uninitialized or moved value", cause)


int safe_ancestor(int ancestor, int child):
	while (child >= 0):
		if (child == ancestor): return 1
		child = safe_parent_ref[child]
	return 0


void safe_access(int root, int via, int write, int id, char* state):
	if ((root < 0) || (safe_validate == 0)): return
	safe_read(root, id, state)
	if ((via >= 0) && write && (safe_local_kind(via) == 2)):
		safe_error(id, c"safe: write through a shared reference", safe_birth[via])
	for i in range(safe_call_roots.length):
		if ((safe_call_roots[i] == root) && (write || (safe_call_kinds[i] != 2))):
			safe_error(id, c"safe: conflicting access during call argument evaluation", -1)
	safe_flow* event = safe_graph[safe_event]
	for i in range(safe_locals.length):
		if ((safe_local_kind(i) < 2) || (state[i] != 2)): continue
		if (safe_origin[i] != root): continue
		if (safe_ancestor(i, via)): continue
		if ((event.live[i] == 0) && (event.uses[i] == 0)): continue
		if (write || (safe_local_kind(i) == 3)):
			safe_error(id, c"safe: conflicting access while a borrow is live", safe_birth[i])


# Locate the backing binding, keeping the reference used to access it.
# Projections conservatively share their whole root, including array indices.
int safe_place(int id, char* state, int* via);
int safe_eval(int id, char* state, int want);
int safe_call(int id, retained_node* n, char* state, int* parent);


int safe_place(int id, char* state, int* via):
	retained_node n
	retained_node_load(id, &n)
	int left = safe_child(&n, n.left)
	if (n.op == 'v'):
		int index = safe_index(n.binding)
		if (index < 0): safe_error(id, c"safe: access to global or untracked storage", -1)
		return index
	if ((n.op == 'd') || (n.op == '.') || (n.op == 'i') || (n.op == 'I') || (n.op == 'B')):
		retained_node base
		retained_node_load(left, &base)
		int root = -1
		int index = safe_index(base.binding)
		if (safe_borrow_kind(base.semantic_type)):
			if (index < 0): safe_error(id, c"safe: dereference requires a named checked pointer", -1)
			safe_read(index, id, state)
			root = index
			if (safe_local_kind(index) >= 2):
				root = safe_origin[index]
				*via = index
		else:
			if ((n.op == 'd') || (retained_types[base.semantic_type].pointer_level > 0)):
				safe_error(id, c"safe: raw pointer access requires an unsafe interface", -1)
			root = safe_place(left, state, via)
		if ((n.op == 'i') || (n.op == 'I')):
			if (safe_kind(base.semantic_type)): safe_error(id, c"safe: checked pointer indexing is not supported; use a bounds-checked array", -1)
			safe_eval(safe_child(&n, n.right), state, -1)
		return root
	safe_error(id, c"safe: unsupported storage projection", -1)
	return -1


int safe_borrow(int id, int want, char* state, int* parent):
	int kind = safe_borrow_kind(want)
	retained_node n
	retained_node_load(id, &n)
	# Slice expressions retain their base array type in the semantic AST.
	# Match their actual representation before comparing element types.
	int slice_value = safe_slice(n.semantic_type) || (n.op == 'Z')
	if (safe_slice(want) != slice_value):
		safe_error(id, c"safe: checked pointer/slice representation mismatch", -1)
	if (n.op == 'r'):
		retained_node place
		retained_node_load(safe_child(&n, n.left), &place)
		# A view's descriptor may be local even when its elements outlive
		# the function. Metadata also must not become writable via refmut.
		if (place.op == 'B'): safe_error(id, c"safe: buffer metadata cannot be borrowed", -1)
		int wanted = safe_unqualified(safe_pointee(want))
		int actual = safe_unqualified(place.semantic_type)
		if ((wanted < 0) || (actual < 0) || (strcmp(retained_types[wanted].name, retained_types[actual].name) != 0)):
			safe_error(id, c"safe: incompatible checked pointer types", -1)
	else: safe_pointer_match(id, want, n.semantic_type)
	int root = -1
	int via = -1
	if (n.op == 'C'):
		if ((safe_kind(n.semantic_type) < 2) || safe_slice(want)):
			safe_error(id, c"safe: reference requires a borrowed return contract", -1)
		if ((kind == 3) && (safe_kind(n.semantic_type) == 2)):
			safe_error(id, c"safe: cannot make a mutable borrow from a shared reference", -1)
		root = safe_call(id, &n, state, &via)
	else if (n.op == 'Z'):
		root = safe_place(safe_child(&n, n.left), state, &via)
		retained_node base
		retained_node_load(safe_child(&n, n.left), &base)
		if (safe_slice(base.semantic_type)):
			safe_read(root, id, state)
			via = root
			root = safe_origin[root]
		safe_eval(safe_child(&n, n.right), state, -1)
		safe_eval(safe_child(&n, n.high), state, -1)
	else if (n.op == 'r'): root = safe_place(safe_child(&n, n.left), state, &via)
	else if (n.op == 'v'):
		int index = safe_index(n.binding)
		if ((index < 0) || (safe_borrow_kind(n.semantic_type) == 0)):
			safe_error(id, c"safe: reference requires an address or checked pointer", -1)
		safe_read(index, id, state)
		root = index
		if (safe_local_kind(index) >= 2):
			via = index
			root = safe_origin[index]
	else: safe_error(id, c"safe: reference requires a stable place", -1)
	if ((via >= 0) && (kind == 3) && (safe_local_kind(via) == 2)):
		safe_error(id, c"safe: cannot make a mutable borrow from a shared reference", safe_birth[via])
	safe_access(root, via, kind == 3, id, state)
	*parent = via
	return root


int safe_scalar_type(int type):
	if (type < 0): return 0
	return safe_plain(type, 0) && (retained_types[type].fields.length == 0) && (retained_types[type].kind != type_kind_array)


int safe_same_contract_type(int a, int b):
	a = safe_unqualified(a)
	b = safe_unqualified(b)
	if ((a < 0) || (b < 0)): return a == b
	return strcmp(retained_types[a].name, retained_types[b].name) == 0


int safe_has_body(int function):
	int child = safe_first[function]
	while (child >= 0):
		if (retained_record_at(child).kind == retained_statement): return 1
		child = safe_next[child]
	return 0


# A returned reference inherits the sole borrowed parameter's lifetime.
# This signature-only rule is identical for callers, definitions, imports
# and recursion. Ambiguous signatures need future named lifetime syntax.
int safe_return_parameter(int id, retained_binding* binding):
	if (safe_borrow_kind(binding.return_type) < 2): return -1
	if (safe_slice(binding.return_type)):
		safe_error(id, c"safe: returning slices requires an explicit lifetime contract", -1)
	int result = -1
	for p in range(binding.parameters.length):
		if (safe_borrow_kind(binding.parameters[p]) >= 2):
			if (result >= 0): safe_error(id, c"safe: returning references requires exactly one borrowed parameter", -1)
			result = p
	if (result < 0): safe_error(id, c"safe: returning references requires exactly one borrowed parameter", -1)
	if ((safe_kind(binding.return_type) == 3) && (safe_kind(binding.parameters[result]) != 3)):
		safe_error(id, c"safe: mutable reference return requires a mutable borrowed parameter", -1)
	return result


int safe_call(int id, retained_node* n, char* state, int* parent):
	int binding = n.binding
	if ((binding < 0) || (retained_bindings[binding].return_type < 0)):
		safe_error(id, c"safe: indirect calls require an ownership contract", -1)
	retained_binding* callee = retained_bindings[binding]
	int function = safe_function_for_binding[binding]
	if (safe_trusted(callee.source)):
		# Only scalar output and termination cross the runtime boundary.
		if ((strcmp(callee.name, c"put_char") != 0) && (strcmp(callee.name, c"put_error") != 0) && (strcmp(callee.name, c"exit") != 0)):
			safe_error(id, c"safe: runtime call has no audited ownership contract", -1)
	else:
		if (function < 0): safe_error(id, c"safe: call has no checked implementation", -1)
		retained_binding* definition = retained_bindings[retained_record_at(function).binding]
		int matches = safe_same_contract_type(callee.return_type, definition.return_type)
		if (callee.parameters.length != definition.parameters.length): matches = 0
		else:
			for p in range(callee.parameters.length):
				if (safe_same_contract_type(callee.parameters[p], definition.parameters[p]) == 0): matches = 0
		if (matches == 0): safe_error(id, c"safe: forward declaration disagrees with its definition", function)
		if (safe_checked_functions[function] == 0): safe_checked_functions[function] = 1
	int return_parameter = safe_return_parameter(id, callee)
	int return_root = -1
	int arg = safe_child(n, n.left)
	int position = 0
	int saved = safe_call_roots.length
	while (arg >= 0):
		if (position >= callee.parameters.length): safe_error(id, c"safe: call arity must match its contract", -1)
		int want = callee.parameters[position]
		safe_type_check(id, want)
		int kind = safe_borrow_kind(want)
		int root = -1
		if (kind >= 2):
			int via = -1
			root = safe_borrow(arg, want, state, &via)
			if (position == return_parameter):
				return_root = root
				*parent = via
		else: root = safe_eval(arg, state, want)
		# Scalar arguments copy their value; only pointer contracts keep
		# storage reserved while later arguments are evaluated.
		if ((root >= 0) && kind):
			for i in range(saved, safe_call_roots.length):
				if ((safe_call_roots[i] == root) && ((kind != 2) || (safe_call_kinds[i] != 2))):
					safe_error(arg, c"safe: conflicting call arguments", -1)
			safe_call_roots.push(root)
			safe_call_kinds.push(kind)
		retained_node a
		retained_node_load(arg, &a)
		arg = safe_child(&a, a.next_arg)
		position = position + 1
	while (safe_call_roots.length > saved):
		safe_call_roots.pop()
		safe_call_kinds.pop()
	if (position != callee.parameters.length): safe_error(id, c"safe: call arity must match its contract", -1)
	safe_type_check(id, callee.return_type)
	return return_root


int safe_eval(int id, char* state, int want):
	if (id < 0): return -1
	retained_node n
	retained_node_load(id, &n)
	int op = n.op
	int left = safe_child(&n, n.left)
	int right = safe_child(&n, n.right)
	int kind = safe_borrow_kind(n.semantic_type)
	int wanted = safe_borrow_kind(want)
	if (wanted >= 2): safe_error(id, c"safe: reference assignment is not supported", -1)
	if (wanted == 1):
		safe_pointer_match(id, want, n.semantic_type)
		if ((op != 'N') && (kind != 1)): safe_error(id, c"safe: owner requires new storage or an ownership transfer", -1)
		if ((op != 'N') && (op != 'v') && (op != 'C')): safe_error(id, c"safe: unsupported owner transfer", -1)
	else if (kind && (op != '=')): safe_error(id, c"safe: checked pointers cannot escape into raw or scalar values", -1)
	if (op == 'v'):
		if (safe_has_array(n.semantic_type, 0)): safe_error(id, c"safe: array storage cannot be copied; pass a shared slice", -1)
		int index = safe_index(n.binding)
		if (index < 0): safe_error(id, c"safe: global and function values are not supported", -1)
		safe_read(index, id, state)
		safe_access(index, -1, wanted == 1, id, state)
		if (wanted == 1):
			state[index] = 4
			safe_moved_at[index] = id
		return index
	if (op == 'N'):
		if (wanted != 1): safe_error(id, c"safe: new storage must initialize an owner", -1)
		if (safe_plain(safe_pointee(n.semantic_type), 0) == 0): safe_error(id, c"safe: allocation requires a pointer-free sized value", -1)
		return -1
	if (op == 'C'):
		int parent = -1
		safe_call(id, &n, state, &parent)
		return -1
	if (op == '='):
		retained_node lhs
		retained_node_load(left, &lhs)
		int lk = safe_borrow_kind(lhs.semantic_type)
		int via = -1
		int root = safe_place(left, state, &via)
		if (lk >= 2): safe_error(id, c"safe: references cannot be reassigned", safe_birth[root])
		if ((lk == 1) && ((lhs.op != 'v') || n.value)): safe_error(id, c"safe: owner assignment requires a plain binding", -1)
		if (n.value): safe_read(root, id, state)
		safe_eval(right, state, lhs.semantic_type)
		# Replacement of a moved/uninitialized scalar is valid. A write
		# still conflicts with live borrows of its storage.
		int old = state[root]
		state[root] = 2
		safe_access(root, via, 1, id, state)
		if (lhs.op != 'v'): state[root] = old
		return -1
	if ((op == 'd') || (op == '.') || (op == 'i') || (op == 'I') || (op == 'B')):
		int via = -1
		int root = safe_place(id, state, &via)
		safe_access(root, via, 0, id, state)
		safe_type_check(id, n.semantic_type)
		return -1
	if ((op == 0) || (op == 'c') || (op == 'h') || (op == 'f')): return -1
	if ((op == 'a') || (op == 'o')):
		safe_eval(left, state, -1)
		retained_node child
		retained_node_load(left, &child)
		int at = safe_child(&child, child.next_arg)
		char* branch = cast(char*, malloc(safe_locals.length + 1))
		while (at >= 0):
			for i in range(safe_locals.length): branch[i] = state[i]
			safe_eval(at, branch, -1)
			for i in range(safe_locals.length): state[i] = state[i] | branch[i]
			retained_node_load(at, &child)
			at = safe_child(&child, child.next_arg)
		free(branch)
		return -1
	if (op == '?'):
		safe_eval(left, state, -1)
		char* other = cast(char*, malloc(safe_locals.length + 1))
		for i in range(safe_locals.length): other[i] = state[i]
		safe_eval(right, state, want)
		safe_eval(safe_child(&n, n.high), other, want)
		for i in range(safe_locals.length): state[i] = state[i] | other[i]
		free(other)
		return -1
	if (op == 'K'):
		retained_node operand
		retained_node_load(left, &operand)
		if ((safe_scalar_type(n.semantic_type) == 0) || (safe_scalar_type(operand.semantic_type) == 0)):
			safe_error(id, c"safe: casts require scalar operands", -1)
		safe_eval(left, state, -1)
		return -1
	if (op == 'U'):
		if (safe_scalar_type(n.semantic_type) == 0): safe_error(id, c"safe: increment requires a scalar place", -1)
		int via = -1
		int root = safe_place(left, state, &via)
		safe_access(root, via, 1, id, state)
		return -1
	if (op == 'r'): safe_error(id, c"safe: an address must initialize a checked reference", -1)
	int scalar_op = (op == '+') || (op == '-') || (op == '*') || (op == '/') || (op == '%') || (op == '&') || (op == '|') || (op == '^') || (op == 'L') || (op == 'R') || (op == 'n') || (op == 'p') || (op == '~') || (op == '!') || (op == 'b') || ((op >= 0x94) && (op <= 0x9f))
	if (scalar_op == 0): safe_error(id, c"safe: unsupported expression operation", -1)
	safe_eval(left, state, -1)
	safe_eval(right, state, -1)
	if (safe_scalar_type(n.semantic_type) == 0): safe_error(id, c"safe: arithmetic requires scalar operands", -1)
	return -1


int safe_within(int node, int scope):
	while (node >= 0):
		if (node == scope): return 1
		node = retained_record_at(node).parent
	return 0


void safe_transfer(int event, char* state):
	safe_event = event
	safe_flow* f = safe_graph[event]
	int index = f.binding
	if (f.action == 1):
		int type = retained_bindings[safe_locals[index]].type
		safe_type_check(f.node, type)
		if (safe_borrow_kind(type) >= 2):
			if (f.expression < 0): safe_error(f.node, c"safe: references require initialization", -1)
			int parent = -1
			safe_origin[index] = safe_borrow(f.expression, type, state, &parent)
			safe_parent_ref[index] = parent
		else: safe_eval(f.expression, state, type)
		state[index] = 1
		if ((f.expression >= 0) || (retained_types[type].kind == type_kind_array)): state[index] = 2
		if ((f.expression < 0) && safe_kind(type)): safe_error(f.node, c"safe: checked pointers require initialization", -1)
	else if (f.action == 2):
		if (safe_borrow_kind(safe_return_type) >= 2):
			if (f.expression < 0): safe_error(f.node, c"safe: reference return requires a value", -1)
			int parent = -1
			int root = safe_borrow(f.expression, safe_return_type, state, &parent)
			if (safe_validate && (root != safe_return_root)):
				safe_error(f.node, c"safe: returned reference must borrow from the function's borrowed parameter", safe_birth[root])
		else: safe_eval(f.expression, state, safe_return_type)
	else if (f.action == 3):
		for i in range(safe_locals.length):
			if (safe_within(safe_birth[i], f.node)): state[i] = 1
	else: safe_eval(f.expression, state, -1)


void safe_function_check(int function):
	safe_function = function
	retained_record* fn = retained_record_at(function)
	if (retained_bindings[fn.binding].assembly_body): safe_error(function, c"safe: assembly function bodies are not supported", -1)
	safe_return_type = retained_bindings[fn.binding].return_type
	safe_type_check(function, safe_return_type)
	int return_parameter = safe_return_parameter(function, retained_bindings[fn.binding])
	safe_return_root = -1
	if (safe_has_array(safe_return_type, 0)): safe_error(function, c"safe: array storage cannot escape by value", -1)
	safe_graph = new list[safe_flow*]
	safe_locals = new list[int]
	safe_local_index = new map[int, int]
	for id in range(retained_node_count()):
		if ((retained_node_table[id] & 1)): continue
		retained_record* n = retained_record_at(id)
		if ((n.kind == retained_local) && (n.binding >= 0) && (retained_bindings[n.binding].owner == function)):
			safe_local_index[n.binding] = safe_locals.length
			safe_locals.push(n.binding)
	for id in range(retained_node_count()):
		if (retained_node_table[id] & 1): continue
		retained_record* n = retained_record_at(id)
		if ((n.kind == retained_statement) && (strcmp(n.name, c"defer") == 0) && safe_within(id, function)):
			safe_error(id, c"safe: unsupported control flow or deferred operation", -1)
	int count = safe_locals.length
	safe_origin = cast(int*, malloc((count + 1) * __word_size__))
	safe_parent_ref = cast(int*, malloc((count + 1) * __word_size__))
	safe_birth = cast(int*, malloc((count + 1) * __word_size__))
	safe_moved_at = cast(int*, malloc((count + 1) * __word_size__))
	for i in range(count):
		safe_origin[i] = i
		safe_moved_at[i] = -1
		safe_parent_ref[i] = -1
	for id in range(retained_node_count()):
		if ((retained_node_table[id] & 1)): continue
		retained_record* n = retained_record_at(id)
		if (n.kind == retained_local):
			int index = safe_index(n.binding)
			if (index >= 0): safe_birth[index] = id
	int end = safe_add(function, -1, -1, 0, -1, -1)
	int start = safe_sequence(safe_first[function], end, -1, -1)
	# Reference liveness: direct uses plus reborrow ancestry. The fixed
	# point handles loop backedges; no source-offset lifetime shortcuts.
	for i in range(safe_graph.length):
		safe_flow* f = safe_graph[i]
		if (f.expression < 0): continue
		retained_node root
		retained_node_load(f.expression, &root)
		retained_group* group = retained_record_at(root.parent).group
		for j in range(group.count):
			retained_node n
			retained_node_load(root.parent + 1 + j, &n)
			if (n.op == 'v'):
				int index = safe_index(n.binding)
				if (index >= 0): f.uses[index] = 1
	int changed = 1
	while (changed):
		changed = 0
		for i in range(safe_graph.length):
			safe_flow* f = safe_graph[i]
			for j in range(count):
				int live = f.uses[j]
				if ((f.action != 1) || (f.binding != j)):
					if (f.next >= 0): live = live | safe_graph[f.next].live[j]
					if (f.alternate >= 0): live = live | safe_graph[f.alternate].live[j]
				if (live != f.live[j]):
					f.live[j] = live
					changed = 1
	char* initial = safe_graph[start].state
	int parameter = 0
	for i in range(count):
		initial[i] = 1
		if (retained_bindings[safe_locals[i]].scope == 'A'):
			if (parameter == return_parameter): safe_return_root = i
			parameter = parameter + 1
			safe_type_check(safe_birth[i], retained_bindings[safe_locals[i]].type)
			initial[i] = 2
	safe_graph[start].reached = 1
	char* state = cast(char*, malloc(count + 1))
	safe_validate = 0
	changed = 1
	while (changed):
		changed = 0
		for i in range(safe_graph.length):
			safe_flow* f = safe_graph[i]
			if (f.reached == 0): continue
			for j in range(count): state[j] = f.state[j]
			safe_transfer(i, state)
			for edge in range(2):
				int target = f.next
				if (edge): target = f.alternate
				if (target < 0): continue
				safe_flow* to = safe_graph[target]
				if (to.reached == 0):
					to.reached = 1
					changed = 1
				for j in range(count):
					int joined = to.state[j] | state[j]
					if (joined != to.state[j]):
						to.state[j] = joined
						changed = 1
	if (safe_graph[end].reached && (safe_kind(safe_return_type) == 1)): safe_error(function, c"safe: owner-returning function must return an owner on every path", -1)
	if (safe_graph[end].reached && (safe_borrow_kind(safe_return_type) >= 2)): safe_error(function, c"safe: reference-returning function must return a reference on every path", -1)
	safe_validate = 1
	for i in range(safe_graph.length):
		if (safe_graph[i].reached):
			for j in range(count): state[j] = safe_graph[i].state[j]
			safe_transfer(i, state)
	free(state)
	for i in range(safe_graph.length):
		free(safe_graph[i].state)
		free(safe_graph[i].live)
		free(safe_graph[i].uses)
		free(safe_graph[i])
	safe_graph.free()
	safe_locals.free()
	safe_local_index.free()
	free(cast(char*, safe_origin))
	free(cast(char*, safe_parent_ref))
	free(cast(char*, safe_birth))
	free(cast(char*, safe_moved_at))


void safe_audit_runtime():
	while (safe_trusted_sources.length < retained_sources.length): safe_trusted_sources.push(0)
	for i in range(retained_sources.length):
		retained_source* source = retained_sources[i]
		char* expected = safe_runtime_digest(source.path)
		if (expected == 0):
			if (safe_trusted(i)): safe_error(source.root, c"safe: injected runtime has no audited implementation", -1)
			continue
		char[32] digest
		sha256(source.bytes, source.length, &digest[0])
		char* digits = c"0123456789abcdef"
		int matches = 1
		for j in range(32):
			int value = digest[j] & 255
			if ((expected[j * 2] != digits[value >> 4]) || (expected[j * 2 + 1] != digits[value & 15])): matches = 0
		if (matches == 0): safe_error(source.root, c"safe: runtime implementation differs from its audited contract", -1)
		safe_trusted_sources[i] = 1


void safe_check_finish():
	if ((safe_mode == 0) && (type_safe_used == 0)): return
	if (safe_bounds_disabled): error(c"safe: checked pointers require bounds checks")
	if ((target_isa != 0) || (target_os != 0)): error(c"safe: only Linux x86 and x64 targets are supported")
	safe_audit_runtime()
	int count = retained_node_count()
	safe_first = cast(int*, malloc(count * __word_size__))
	safe_next = cast(int*, malloc(count * __word_size__))
	safe_checked_functions = cast(int*, safe_zero(count, __word_size__))
	safe_function_for_binding = cast(int*, malloc(retained_bindings.length * __word_size__))
	for i in range(retained_bindings.length): safe_function_for_binding[i] = -1
	for i in range(count):
		safe_first[i] = -1
		safe_next[i] = -1
	int i = count
	while (i > 0):
		i = i - 1
		if ((retained_node_table[i] & 1)): continue
		retained_record* n = retained_record_at(i)
		if (n.parent >= 0):
			safe_next[i] = safe_first[n.parent]
			safe_first[n.parent] = i
		if ((n.kind == retained_function) && (n.binding >= 0) && safe_has_body(i)):
			safe_function_for_binding[n.binding] = i
			if ((safe_mode && (safe_trusted(n.source) == 0)) || safe_kind(retained_bindings[n.binding].return_type)): safe_checked_functions[i] = 1
		if ((n.kind == retained_local) && safe_kind(n.semantic_type)):
			safe_checked_functions[retained_bindings[n.binding].owner] = 1
	for id in range(count):
		retained_node n
		retained_node_load(id, &n)
		int checked = safe_contains_checked(n.semantic_type, 0)
		if ((n.kind == retained_expression) && (n.binding >= 0)):
			retained_binding* callee = retained_bindings[n.binding]
			for p in range(callee.parameters.length):
				if (safe_kind(callee.parameters[p])): checked = 1
		if (n.kind == retained_declaration):
			if ((n.binding >= 0) && (safe_trusted(n.source) == 0)):
				retained_binding* binding = retained_bindings[n.binding]
				int contract = checked
				for arg in range(binding.parameters.length):
					if (safe_kind(binding.parameters[arg])): contract = 1
				if ((safe_mode || contract) && binding.assembly_body): safe_error(id, c"safe: assembly function bodies are not supported", -1)
			if (n.semantic_type >= 0):
				retained_type* t = retained_types[n.semantic_type]
				for field in range(t.fields.length):
					if (safe_contains_checked(t.fields[field].type, 0)): safe_error(id, c"safe: checked pointers in aggregates are not supported", -1)
			if ((n.binding < 0) || (retained_bindings[n.binding].return_type >= 0)): checked = 0
		if (checked):
			int owner = n.parent
			while ((owner >= 0) && (retained_record_at(owner).kind != retained_function)): owner = retained_record_at(owner).parent
			if (owner < 0): safe_error(id, c"safe: checked pointers require local storage or a function contract", -1)
			safe_checked_functions[owner] = 1
		if (safe_mode && (safe_trusted(n.source) == 0)):
			if ((n.kind == retained_declaration) && (n.binding >= 0) && (retained_bindings[n.binding].return_type < 0)):
				safe_error(id, c"safe: global storage is not supported", -1)
	# Resolve forward declarations to their completed implementation.
	for b in range(retained_bindings.length):
		if (safe_function_for_binding[b] >= 0): continue
		retained_binding* binding = retained_bindings[b]
		if (binding.return_type < 0): continue
		for j in range(retained_bindings.length):
			if ((safe_function_for_binding[j] >= 0) && (strcmp(binding.name, retained_bindings[j].name) == 0)):
				safe_function_for_binding[b] = safe_function_for_binding[j]
	if (safe_mode):
		for b in range(retained_bindings.length):
			retained_binding* binding = retained_bindings[b]
			if ((binding.source >= 0) && (strcmp(binding.name, c"main") == 0) && (safe_function_for_binding[b] < 0)):
				safe_error(retained_sources[binding.source].root, c"safe: main requires a checked implementation", -1)
	safe_call_roots = new list[int]
	safe_call_kinds = new list[int]
	int pending = 1
	while (pending):
		pending = 0
		for id in range(count):
			if (safe_checked_functions[id] == 1):
				safe_checked_functions[id] = 2
				if (safe_has_body(id)): safe_function_check(id)
				pending = 1
	safe_call_roots.free()
	safe_call_kinds.free()
	free(cast(char*, safe_first))
	free(cast(char*, safe_next))
	free(cast(char*, safe_checked_functions))
	free(cast(char*, safe_function_for_binding))
