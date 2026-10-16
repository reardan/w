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
int* safe_contains_seen
int safe_contains_generation
list[int] safe_contains_pending

struct safe_flow:
	int node
	int expression
	int binding
	int action
	int next
	int alternate
	int returning
	int return_roots
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
list[char*] safe_sets
int safe_validate
int safe_origins_changed
int safe_replacing
int safe_event
int safe_position
list[int] safe_call_roots
list[int] safe_call_kinds


int safe_check_requested():
	return safe_mode || type_safe_used


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
	if (safe_contains_seen != 0): free(cast(char*, safe_contains_seen))
	safe_contains_seen = 0
	safe_contains_generation = 0
	if (safe_contains_pending != 0): safe_contains_pending.free()
	safe_contains_pending = 0


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


int safe_same_nominal(int a, int b):
	a = safe_unqualified(a)
	b = safe_unqualified(b)
	if ((a < 0) || (b < 0)): return 0
	retained_type* left = retained_types[a]
	retained_type* right = retained_types[b]
	return (strcmp(left.name, right.name) == 0) && (left.file_index == right.file_index) && (left.line == right.line) && (left.column == right.column)


int safe_kind(int type):
	type = safe_unqualified(type)
	if (type < 0): return 0
	int kind = retained_types[type].kind
	if ((kind == type_kind_safe_slice) || (kind == type_kind_safe_record)): return 2
	if (kind == type_kind_safe_recordmut): return 3
	if ((kind >= type_kind_own) && (kind <= type_kind_refmut)): return kind - 20
	if ((kind == type_kind_optref) || (kind == type_kind_optrefmut)): return kind - 24
	return 0


int safe_optional(int type):
	type = safe_unqualified(type)
	if (type < 0): return 0
	int kind = retained_types[type].kind
	return (kind == type_kind_optref) || (kind == type_kind_optrefmut)


void safe_contains_enqueue(int type):
	if (type < 0): return
	if (safe_contains_seen[type] == safe_contains_generation): return
	safe_contains_seen[type] = safe_contains_generation
	safe_contains_pending.push(type)


int safe_contains_checked(int type):
	if (type < 0): return 0
	if (safe_kind(type)): return 1
	if (safe_contains_seen == 0):
		safe_contains_seen = cast(int*, safe_zero(retained_types.length, __word_size__))
		safe_contains_pending = new list[int]
	if (safe_contains_generation == 2147483647):
		for i in range(retained_types.length): safe_contains_seen[i] = 0
		safe_contains_generation = 0
	safe_contains_generation = safe_contains_generation + 1
	# Each retained type enters the queue once, including cycles and shared
	# branches. Large raw graphs remain raw without a depth or size cutoff.
	safe_contains_pending.clear()
	safe_contains_enqueue(type)
	int position = 0
	int checked = 0
	while (position < safe_contains_pending.length):
		int current = safe_contains_pending[position]
		position = position + 1
		if (safe_kind(current)):
			checked = 1
			break
		retained_type* t = retained_types[current]
		safe_contains_enqueue(t.target)
		safe_contains_enqueue(t.return_type)
		for i in range(t.parameters.length): safe_contains_enqueue(t.parameters[i])
		for i in range(t.fields.length): safe_contains_enqueue(t.fields[i].type)
	safe_contains_pending.clear()
	return checked


int safe_slice(int type):
	type = safe_unqualified(type)
	if (type < 0): return 0
	return (retained_types[type].kind == type_kind_slice) || (retained_types[type].kind == type_kind_safe_slice)


int safe_inline_slice(int type):
	type = safe_unqualified(type)
	if (type < 0): return 0
	return retained_types[type].kind == type_kind_safe_slice


int safe_record(int type):
	type = safe_unqualified(type)
	if (type < 0): return 0
	int kind = retained_types[type].kind
	return (kind == type_kind_safe_record) || (kind == type_kind_safe_recordmut)


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


int safe_buffer_source(int source):
	if ((source < 0) || (safe_trusted(source) == 0)): return 0
	return ends_with(retained_sources[source].path, c"/lib/safe_buffer.w")


int safe_opaque(int type):
	type = safe_unqualified(type)
	if (type < 0): return 0
	retained_type* record = retained_types[type]
	if ((record.kind != 0) || record.pointer_level || (safe_buffer_source(record.source) == 0)): return 0
	return (strcmp(record.name, c"WIntBuffer") == 0) || (strcmp(record.name, c"WByteString") == 0) || (strcmp(record.name, c"WOwnedIntBuffer") == 0) || (strcmp(record.name, c"WByteArena") == 0)


int safe_runtime_call(retained_binding* binding):
	char* name = binding.name
	if (safe_buffer_source(binding.source)):
		if ((strcmp(name, c"byte_arena_new") == 0) || (strcmp(name, c"byte_arena_length") == 0) || (strcmp(name, c"byte_arena_copy") == 0) || (strcmp(name, c"byte_arena_reset") == 0) || (strcmp(name, c"byte_arena_release") == 0)): return 1
		if ((strcmp(name, c"owned_int_buffer_new") == 0) || (strcmp(name, c"owned_int_buffer_length") == 0) || (strcmp(name, c"owned_int_buffer_push") == 0) || (strcmp(name, c"owned_int_buffer_get") == 0) || (strcmp(name, c"owned_int_buffer_set") == 0) || (strcmp(name, c"owned_int_buffer_pop") == 0) || (strcmp(name, c"owned_int_buffer_clear") == 0)): return 1
		return (strcmp(name, c"int_buffer_new") == 0) || (strcmp(name, c"int_buffer_length") == 0) || (strcmp(name, c"int_buffer_push") == 0) || (strcmp(name, c"int_buffer_get") == 0) || (strcmp(name, c"int_buffer_set") == 0) || (strcmp(name, c"int_buffer_pop") == 0) || (strcmp(name, c"int_buffer_clear") == 0) || (strcmp(name, c"int_buffer_view") == 0) || (strcmp(name, c"byte_string_new") == 0) || (strcmp(name, c"byte_string_length") == 0) || (strcmp(name, c"byte_string_push") == 0) || (strcmp(name, c"byte_string_get") == 0) || (strcmp(name, c"byte_string_set") == 0) || (strcmp(name, c"byte_string_pop") == 0) || (strcmp(name, c"byte_string_clear") == 0) || (strcmp(name, c"byte_string_view") == 0) || (strcmp(name, c"byte_string_append") == 0) || (strcmp(name, c"byte_string_from") == 0)
	return (strcmp(name, c"put_char") == 0) || (strcmp(name, c"put_error") == 0) || (strcmp(name, c"exit") == 0)


void safe_pointer_match(int id, int want, int got):
	int w = safe_unqualified(safe_pointee(want))
	int g = safe_unqualified(safe_pointee(got))
	if ((w < 0) || (g < 0)): safe_error(id, c"safe: incompatible checked pointer types", -1)
	if ((safe_opaque(w) || safe_opaque(g)) && (safe_same_nominal(w, g) == 0)):
		safe_error(id, c"safe: incompatible opaque collection types", -1)
	if (strcmp(retained_types[w].name, retained_types[g].name) != 0):
		safe_error(id, c"safe: incompatible checked pointer types", -1)


# Borrowed aggregates have one lifetime group. Every reference field names
# that group; scalar fields have no lifetime. Mutable wrappers also admit
# exclusive fields and reserve the complete group when reborrowed.
int safe_record_shape(int type, int kind):
	type = safe_unqualified(type)
	if (type < 0): return 0
	retained_type* record = retained_types[type]
	if ((record.kind != 0) || record.pointer_level || (record.fields.length == 0)): return 0
	char* lifetime = 0
	for i in range(record.fields.length):
		int field = safe_unqualified(record.fields[i].type)
		if (field < 0): return 0
		retained_type* member = retained_types[field]
		if ((member.kind == type_kind_ref) || (member.kind == type_kind_safe_slice) || ((kind == 3) && (member.kind == type_kind_refmut))):
			if (safe_plain(safe_pointee(field), 0) == 0): return 0
			if (member.lifetime == 0): return 0
			if (lifetime == 0): lifetime = member.lifetime
			else if (strcmp(lifetime, member.lifetime) != 0): return 0
		else:
			if (safe_plain(field, 0) == 0): return 0
			if ((member.fields.length > 0) || (member.kind == type_kind_array)): return 0
	return lifetime != 0


int safe_owned_shape_walk(int type, int depth, int* path, int* remaining):
	type = safe_unqualified(type)
	if ((type < 0) || (depth > 32) || (*remaining <= 0)): return 0
	*remaining = *remaining - 1
	if (safe_plain(type, 0) || safe_opaque(type)): return 1
	for i in range(depth):
		if (path[i] == type): return 0
	path[depth] = type
	retained_type* record = retained_types[type]
	if ((record.kind != 0) || record.pointer_level || (record.fields.length == 0)): return 0
	for i in range(record.fields.length):
		int field = record.fields[i].type
		if (safe_kind(field) == 1):
			if (safe_owned_shape_walk(safe_pointee(field), depth + 1, path, remaining) == 0): return 0
		else if (safe_plain(field, 0) == 0): return 0
	return 1


int safe_owned_shape(int type):
	int[33] path
	# Bound repeated expansion of acyclic owner-field graphs as well as depth.
	int remaining = 256
	return safe_owned_shape_walk(type, 0, &path[0], &remaining)


void safe_type_check(int id, int type):
	if (safe_record(type)):
		if (safe_record_shape(retained_types[safe_unqualified(type)].target, safe_kind(type))): return
		if (safe_kind(type) == 3): safe_error(id, c"safe: mutable borrowed aggregate requires scalar fields and one named reference group", -1)
		safe_error(id, c"safe: borrowed aggregate requires scalar fields and one named shared-reference group", -1)
	if (safe_kind(type) || safe_slice(type)):
		if (safe_plain(safe_pointee(type), 0)): return
		if ((safe_slice(type) == 0) && safe_owned_shape(safe_pointee(type))): return
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
	f.returning = -1
	f.return_roots = -1
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


# Queued generic calls have no raw symbol at their emission site. Their
# retained mangled identity must resolve to the concrete checked body.
int safe_call_binding(retained_node* node):
	if (node.binding >= 0): return node.binding
	if ((node.op != 'G') && (node.op != 'W')): return -1
	if (node.payload_text == 0): return -1
	for i in range(retained_bindings.length):
		if ((safe_function_for_binding[i] >= 0) && (strcmp(retained_bindings[i].name, node.payload_text) == 0)): return i
	return -1


void safe_unsafe_check(int id):
	retained_record* n = retained_record_at(id)
	if (n.kind == retained_statement):
		if ((strcmp(n.name, c"return") == 0) || (strcmp(n.name, c"break") == 0) || (strcmp(n.name, c"continue") == 0) || (strcmp(n.name, c"defer") == 0) || (strcmp(n.name, c"goto") == 0) || (strcmp(n.name, c"yield") == 0)):
			safe_error(id, c"safe: unsafe blocks cannot transfer control or defer work", -1)
	if (safe_contains_checked(n.semantic_type)): safe_error(id, c"safe: unsafe blocks cannot manipulate checked pointers", -1)
	if (n.kind == retained_expression_group):
		for i in range(n.group.count):
			retained_node expr
			retained_node_load(id + 1 + i, &expr)
			if (safe_contains_checked(expr.semantic_type)): safe_error(id, c"safe: unsafe blocks cannot manipulate checked pointers", -1)
			if ((expr.op == 'C') || (expr.op == 'G') || (expr.op == 'W')):
				int binding = safe_call_binding(&expr)
				if ((binding < 0) && (expr.op != 'C')): safe_error(id, c"safe: generic calls require a concrete ownership contract", -1)
				if (binding < 0): continue
				retained_binding* callee = retained_bindings[binding]
				for j in range(callee.parameters.length):
					if (safe_contains_checked(callee.parameters[j])): safe_error(id, c"safe: checked calls must remain outside unsafe blocks", -1)
	int child = safe_first[id]
	while (child >= 0):
		safe_unsafe_check(child)
		child = safe_next[child]


int safe_build(int id, int next, int break_to, int continue_to);


# Emitted jumps destroy locals in every exited lexical block. Mirror that
# invalidation before the control-flow edge, including a continue crossing
# a switch. Range indices belong to their surrounding block and stay live.
int safe_jump_cleanup(int id, int target, int continuing):
	int scope = retained_record_at(id).parent
	if (scope < 0): return target
	retained_record* node = retained_record_at(scope)
	char* name = node.name
	if ((strcmp(name, c"while") == 0) || (strcmp(name, c"for range") == 0) || (strcmp(name, c"for") == 0)): return target
	if ((continuing == 0) && (strcmp(name, c"switch") == 0)): return target
	int rest = safe_jump_cleanup(scope, target, continuing)
	if ((strcmp(name, c":") == 0) || (strcmp(name, c"{") == 0)):
		return safe_add(scope, -1, -1, 3, rest, -1)
	return rest


int safe_sequence(int first, int next, int break_to, int continue_to):
	if (first < 0): return next
	int rest = safe_sequence(safe_next[first], next, break_to, continue_to)
	return safe_build(first, rest, break_to, continue_to)


int safe_scalar_type(int type);


void safe_control_scalar(int group):
	retained_node value
	retained_node_load(safe_expr_root(group), &value)
	if (safe_scalar_type(value.semantic_type) == 0):
		safe_error(group, c"safe: range and switch expressions require scalar values", -1)


# Range slots capture the arguments once. The implicit index accesses are
# real accesses: a borrow used after an increment must block that write.
int safe_range(int id, int next):
	int local = -1
	int body = -1
	list[int] arguments = new list[int]
	int child = safe_first[id]
	while (child >= 0):
		retained_record* n = retained_record_at(child)
		if (n.kind == retained_local): local = safe_index(n.binding)
		else if (n.kind == retained_expression_group):
			safe_control_scalar(child)
			arguments.push(child)
		else if (n.kind == retained_statement): body = child
		else: safe_error(child, c"safe: unsupported range representation", -1)
		child = safe_next[child]
	if ((local < 0) || (body < 0) || (arguments.length < 1) || (arguments.length > 3)):
		safe_error(id, c"safe: unsupported range representation", -1)
	int type = safe_unqualified(retained_bindings[safe_locals[local]].type)
	if (strcmp(retained_types[type].name, c"int") != 0):
		safe_error(id, c"safe: range variable must have type int", -1)
	int guard = safe_add(id, -1, local, 5, -1, next)
	int step = safe_add(id, -1, local, 6, guard, -1)
	safe_graph[guard].next = safe_build(body, step, next, step)
	int start = safe_add(id, -1, local, 6, guard, -1)
	int i = arguments.length
	while (i > 0):
		i = i - 1
		start = safe_add(arguments[i], safe_expr_root(arguments[i]), -1, 0, start, -1)
	arguments.free()
	return safe_add(id, -1, local, 4, start, -1)


# Each clause owns its label expressions and body. Unmatched labels
# continue to the next clause; matching one skips the remaining labels.
int safe_switch_clause(int clause, int next, int continue_to):
	if (clause < 0): return next
	int unmatched = safe_switch_clause(safe_next[clause], next, continue_to)
	retained_record* n = retained_record_at(clause)
	if ((n.kind != retained_statement) || ((strcmp(n.name, c"case") != 0) && (strcmp(n.name, c"default") != 0))):
		safe_error(clause, c"safe: unsupported switch representation", -1)
	list[int] labels = new list[int]
	int body = -1
	int child = safe_first[clause]
	while (child >= 0):
		retained_record* part = retained_record_at(child)
		if (part.kind == retained_expression_group):
			safe_control_scalar(child)
			labels.push(child)
		else if (part.kind == retained_statement): body = child
		else: safe_error(child, c"safe: unsupported switch representation", -1)
		child = safe_next[child]
	if (body < 0): safe_error(clause, c"safe: unsupported switch representation", -1)
	int matched = safe_build(body, next, next, continue_to)
	int start = unmatched
	if (strcmp(n.name, c"default") == 0): start = matched
	int i = labels.length
	while (i > 0):
		i = i - 1
		start = safe_add(labels[i], safe_expr_root(labels[i]), -1, 0, matched, start)
	labels.free()
	return start


int safe_switch(int id, int next, int continue_to):
	int selector = safe_first[id]
	if ((selector < 0) || (retained_record_at(selector).kind != retained_expression_group)):
		safe_error(id, c"safe: unsupported switch representation", -1)
	safe_control_scalar(selector)
	int clauses = safe_switch_clause(safe_next[selector], next, continue_to)
	return safe_add(selector, safe_expr_root(selector), -1, 0, clauses, -1)


int safe_deferred(int id, int next, int returning):
	int group = safe_first[id]
	if ((group < 0) || (retained_record_at(group).kind != retained_expression_group) || (safe_next[group] >= 0)):
		safe_error(id, c"safe: unsupported deferred expression representation", -1)
	if (retained_record_at(id).expression_fallback): safe_error(id, c"safe: unsupported expression fallback", -1)
	int event = safe_add(id, safe_expr_root(group), -1, 7, next, -1)
	safe_graph[event].returning = returning
	return event


# Return capture precedes deferred evaluation. Keeping these events on the
# same graph makes deferred reads extend liveness and deferred moves visible
# to later LIFO calls, while a captured borrowed result stays protected.
int safe_return(int id):
	int expression = -1
	list[int] deferred = new list[int]
	int child = safe_first[id]
	while (child >= 0):
		retained_record* n = retained_record_at(child)
		if (n.kind == retained_expression_group):
			if (expression >= 0): safe_error(id, c"safe: unsupported multiple-expression statement", -1)
			expression = safe_expr_root(child)
		else if ((n.kind == retained_statement) && (strcmp(n.name, c"deferred exit") == 0)): deferred.push(child)
		else: safe_error(child, c"safe: unsupported return representation", -1)
		child = safe_next[child]
	int capture = safe_add(id, expression, -1, 2, -1, -1)
	int next = -1
	int i = deferred.length
	while (i > 0):
		i = i - 1
		next = safe_deferred(deferred[i], next, capture)
	deferred.free()
	safe_graph[capture].next = next
	return capture


int safe_build(int id, int next, int break_to, int continue_to):
	retained_record* n = retained_record_at(id)
	if (n.kind == retained_local): return next
	if (n.kind == retained_expression_group): return safe_add(id, safe_expr_root(id), -1, 0, next, -1)
	if (n.kind != retained_statement): safe_error(id, c"safe: unsupported statement representation", -1)
	char* name = n.name
	if (strcmp(name, c"unsafe block") == 0):
		safe_unsafe_check(id)
		return next
	if (n.expression_fallback): safe_error(id, c"safe: unsupported expression fallback", -1)
	if ((strcmp(name, c"yield") == 0) || (strcmp(name, c"goto") == 0) || (strcmp(name, c"asm") == 0) || (strcmp(name, c"for") == 0)):
		safe_error(id, c"safe: unsupported control flow or deferred operation", -1)
	if (strcmp(name, c"defer") == 0): return next
	if (strcmp(name, c"deferred exit") == 0): return safe_deferred(id, next, -1)
	if (strcmp(name, c"return") == 0): return safe_return(id)
	if (strcmp(name, c"for range") == 0): return safe_range(id, next)
	if (strcmp(name, c"switch") == 0): return safe_switch(id, next, continue_to)
	if ((strcmp(name, c":") == 0) || (strcmp(name, c"{") == 0)):
		int cleanup = safe_add(id, -1, -1, 3, next, -1)
		return safe_sequence(safe_first[id], cleanup, break_to, continue_to)
	if ((strcmp(name, c"pass") == 0) || (strcmp(name, c"debugger") == 0)): return next
	if (strcmp(name, c"break") == 0): return safe_add(id, -1, -1, 0, safe_jump_cleanup(id, break_to, 0), -1)
	if (strcmp(name, c"continue") == 0): return safe_add(id, -1, -1, 0, safe_jump_cleanup(id, continue_to, 1), -1)
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
	if (local >= 0):
		char* scope = retained_record_at(n.parent).name
		if ((strcmp(scope, c":") != 0) && (strcmp(scope, c"{") != 0)):
			safe_error(id, c"safe: declarations require a lexical block", -1)
		return safe_add(id, safe_expr_root(group), safe_index(local), 1, next, -1)
	if ((first_body >= 0) || (group < 0)):
		safe_error(id, c"safe: unsupported statement (including defer, goto, assembly, generators and container iteration)", -1)
	return safe_add(id, safe_expr_root(group), -1, 0, next, -1)


void safe_read(int index, int id, char* state):
	if ((index >= 0) && safe_validate && ((state[index] & 7) != 2)):
		int cause = safe_birth[index]
		if ((state[index] & 4) && (safe_moved_at[index] >= 0)): cause = safe_moved_at[index]
		safe_error(id, c"safe: use of uninitialized or moved value", cause)


# Provenance and reborrow ancestry are sets of local identities. The first
# set for each local is its singleton; union sets are interned per function.
# This keeps all possible backing values alive when a call may return either
# of several borrowed inputs, without assigning one arbitrary representative.
int safe_set_has(int set, int member):
	if ((set < 0) || (member < 0)): return 0
	return safe_sets[set][member] != 0


int safe_set_union(int left, int right):
	if (left < 0): return right
	if ((right < 0) || (left == right)): return left
	for set in range(safe_sets.length):
		int equal = 1
		for i in range(safe_locals.length):
			if (safe_sets[set][i] != (safe_sets[left][i] | safe_sets[right][i])): equal = 0
		if (equal): return set
	char* merged = safe_zero(safe_locals.length, 1)
	for i in range(safe_locals.length): merged[i] = safe_sets[left][i] | safe_sets[right][i]
	int result = safe_sets.length
	safe_sets.push(merged)
	return result


int safe_set_overlap(int left, int right):
	if ((left < 0) || (right < 0)): return 0
	for i in range(safe_locals.length):
		if (safe_sets[left][i] && safe_sets[right][i]): return 1
	return 0


int safe_ancestor(int ancestor, int children):
	# Invalid initializers can introduce a self edge before definite-init
	# validation. Set closure terminates even for those malformed cycles.
	int ancestors = children
	int changed = 1
	while (changed):
		if (safe_set_has(ancestors, ancestor)): return 1
		int previous = ancestors
		for child in range(safe_locals.length):
			if (safe_set_has(ancestors, child)):
				ancestors = safe_set_union(ancestors, safe_parent_ref[child])
		changed = ancestors != previous
	return 0


int safe_shared_parent(int parents):
	for i in range(safe_locals.length):
		if (safe_set_has(parents, i) && (safe_local_kind(i) == 2)): return i
	return -1


void safe_access(int roots, int via, int write, int id, char* state):
	if ((roots < 0) || (safe_validate == 0)): return
	for root in range(safe_locals.length):
		if (safe_set_has(roots, root)): safe_read(root, id, state)
	int shared = safe_shared_parent(via)
	if ((shared >= 0) && write):
		safe_error(id, c"safe: write through a shared reference", safe_birth[shared])
	for i in range(safe_call_roots.length):
		if (safe_set_overlap(safe_call_roots[i], roots) && (write || (safe_call_kinds[i] != 2))):
			safe_error(id, c"safe: conflicting access during call argument evaluation", -1)
	safe_flow* event = safe_graph[safe_event]
	for i in range(safe_locals.length):
		if ((safe_local_kind(i) < 2) || ((state[i] & 7) != 2)): continue
		if (i == safe_replacing): continue
		if (safe_optional(retained_bindings[safe_locals[i]].type) && ((state[i] & 48) == 16)): continue
		if (safe_set_overlap(safe_origin[i], roots) == 0): continue
		if (safe_ancestor(i, via)): continue
		if ((event.live[i] == 0) && (event.uses[i] == 0)): continue
		if (write || (safe_local_kind(i) == 3)):
			safe_error(id, c"safe: conflicting access while a borrow is live", safe_birth[i])


# Presence is a separate lattice in the initialized-state byte: 16 absent,
# 32 present, 48 either. Joins union possibilities, assignments replace them.
int safe_null(int id):
	if (id < 0): return 0
	retained_node n
	retained_node_load(id, &n)
	return (n.op == 0) && (n.value == 0)


int safe_presence(int id, char* state):
	if (safe_null(id)): return 16
	retained_node n
	retained_node_load(id, &n)
	if (safe_optional(n.semantic_type) == 0): return 32
	if (n.op == 'v'):
		int index = safe_index(n.binding)
		if (index >= 0): return state[index] & 48
	return 48


void safe_require_present(int id, char* state):
	if (safe_validate && (safe_presence(id, state) != 32)):
		safe_error(id, c"safe: optional reference requires a presence check", -1)


# Detect only identity-preserving tests, never integer casts or arithmetic.
int safe_presence_test(int id, int* present):
	if (id < 0): return -1
	retained_node n
	retained_node_load(id, &n)
	int left = safe_child(&n, n.left)
	int right = safe_child(&n, n.right)
	if ((n.op == 'v') && safe_optional(n.semantic_type)): return safe_index(n.binding)
	if (n.op == '!'):
		*present = 1 - *present
		return safe_presence_test(left, present)
	if ((n.op == 0x94) || (n.op == 0x95)):
		int value = -1
		if (safe_null(left)): value = right
		if (safe_null(right)): value = left
		if (value < 0): return -1
		retained_node operand
		retained_node_load(value, &operand)
		if ((operand.op != 'v') || (safe_optional(operand.semantic_type) == 0)): return -1
		if (n.op == 0x94): *present = 1 - *present
		return safe_index(operand.binding)
	return -1


void safe_refine(int id, char* state, int truth):
	if (id < 0): return
	int present = truth
	int index = safe_presence_test(id, &present)
	if (index >= 0):
		int presence = 16
		if (present): presence = 32
		state[index] = (state[index] & 7) | presence
		return
	retained_node n
	retained_node_load(id, &n)
	if (n.op == '!'):
		safe_refine(safe_child(&n, n.left), state, 1 - truth)
	else if (((n.op == 'a') && truth) || ((n.op == 'o') && (truth == 0))):
		retained_group* group = retained_record_at(n.parent).group
		for i in range(group.count):
			retained_node child
			retained_node_load(n.parent + 1 + i, &child)
			if ((child.op == '=') && safe_optional(child.semantic_type)): return
		int at = safe_child(&n, n.left)
		while (at >= 0):
			safe_refine(at, state, truth)
			retained_node child
			retained_node_load(at, &child)
			at = safe_child(&child, child.next_arg)


void safe_origin_join(int index, int root, int parent):
	int origins = safe_set_union(safe_origin[index], root)
	int parents = safe_set_union(safe_parent_ref[index], parent)
	if ((origins != safe_origin[index]) || (parents != safe_parent_ref[index])): safe_origins_changed = 1
	safe_origin[index] = origins
	safe_parent_ref[index] = parents


# Locate the backing binding, keeping the reference used to access it.
# Projections conservatively share their whole root, including array indices.
int safe_place(int id, char* state, int* via);
int safe_eval(int id, char* state, int want);
int safe_call(int id, retained_node* n, char* state, int* parent);
int safe_borrow(int id, int want, char* state, int* parent);
void safe_condition(int id, char* state);


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
			if (safe_opaque(safe_pointee(base.semantic_type))):
				safe_error(id, c"safe: opaque collection metadata is not accessible", -1)
			if (index < 0): safe_error(id, c"safe: dereference requires a named checked pointer", -1)
			safe_read(index, id, state)
			if (safe_optional(base.semantic_type)): safe_require_present(left, state)
			root = index
			if (safe_local_kind(index) >= 2):
				root = safe_origin[index]
				*via = index
		else:
			if ((n.op == 'd') || (retained_types[base.semantic_type].pointer_level > 0)):
				safe_error(id, c"safe: raw pointer access requires an unsafe interface", -1)
			root = safe_place(left, state, via)
		if ((n.op == 'i') || (n.op == 'I')):
			if (safe_kind(base.semantic_type) && (safe_inline_slice(base.semantic_type) == 0)): safe_error(id, c"safe: checked pointer indexing is not supported; use a bounds-checked array", -1)
			# The receiver address is already evaluated before the index.
			# Keep its storage alive even if an index expression replaces
			# or consumes an owner and later restores that binding.
			int saved = safe_call_roots.length
			safe_call_roots.push(root)
			safe_call_kinds.push(2)
			safe_eval(safe_child(&n, n.right), state, -1)
			while (safe_call_roots.length > saved):
				safe_call_roots.pop()
				safe_call_kinds.pop()
		return root
	safe_error(id, c"safe: unsupported storage projection", -1)
	return -1


int safe_record_construct(int id, retained_node* n, int want, char* state, int* parent):
	if (n.high): safe_error(id, c"safe: borrowed aggregates require a value constructor", -1)
	retained_type* record = retained_types[retained_types[safe_unqualified(want)].target]
	char* initialized = safe_zero(record.fields.length, 1)
	int roots = -1
	int saved = safe_call_roots.length
	int entry = safe_child(n, n.left)
	while (entry >= 0):
		retained_node field
		retained_node_load(entry, &field)
		int position = field.value
		if ((position < 0) || (position >= record.fields.length)):
			safe_error(entry, c"safe: invalid borrowed aggregate initializer", -1)
		if (initialized[position]): safe_error(entry, c"safe: borrowed aggregate field initialized twice", -1)
		initialized[position] = 1
		int type = record.fields[position].type
		int value = safe_child(&field, field.left)
		if (safe_kind(type) >= 2):
			int via = -1
			int root = safe_borrow(value, type, state, &via)
			roots = safe_set_union(roots, root)
			*parent = safe_set_union(*parent, via)
			# Later scalar arguments may call functions. Keep every earlier
			# reference reserved until the complete value has been constructed.
			safe_call_roots.push(root)
			safe_call_kinds.push(safe_kind(type))
		else: safe_eval(value, state, type)
		entry = safe_child(&field, field.next_arg)
	for i in range(record.fields.length):
		if (initialized[i] == 0): safe_error(id, c"safe: borrowed aggregate requires every field to be initialized", -1)
	free(initialized)
	while (safe_call_roots.length > saved):
		safe_call_roots.pop()
		safe_call_kinds.pop()
	return roots


void safe_owner_construct(int id, retained_node* n, int want, char* state):
	if (n.high == 0): safe_error(id, c"safe: owned aggregate requires a heap constructor", -1)
	retained_type* record = retained_types[safe_unqualified(safe_pointee(want))]
	char* initialized = safe_zero(record.fields.length, 1)
	int entry = safe_child(n, n.left)
	while (entry >= 0):
		retained_node field
		retained_node_load(entry, &field)
		int position = field.value
		if ((position < 0) || (position >= record.fields.length)):
			safe_error(entry, c"safe: invalid owned aggregate initializer", -1)
		if (initialized[position]): safe_error(entry, c"safe: owned aggregate field initialized twice", -1)
		initialized[position] = 1
		safe_eval(safe_child(&field, field.left), state, record.fields[position].type)
		entry = safe_child(&field, field.next_arg)
	for i in range(record.fields.length):
		if (initialized[i] == 0): safe_error(id, c"safe: owned aggregate requires every field to be initialized", -1)
	free(initialized)


int safe_borrow(int id, int want, char* state, int* parent):
	if (safe_optional(want) && safe_null(id)): return -1
	int kind = safe_borrow_kind(want)
	retained_node n
	retained_node_load(id, &n)
	if (safe_optional(n.semantic_type) && (safe_optional(want) == 0)): safe_require_present(id, state)
	# Slice expressions retain their base array type in the semantic AST.
	# Match their actual representation before comparing element types.
	int slice_value = safe_slice(n.semantic_type) || (n.op == 'Z')
	int inline_view = safe_inline_slice(want)
	int array_value = 0
	int actual_type = safe_unqualified(n.semantic_type)
	if (actual_type >= 0): array_value = retained_types[actual_type].kind == type_kind_array
	if (safe_record(want)):
		int got = actual_type
		if (safe_record(got)):
			if ((kind == 3) && (safe_kind(got) == 2)):
				safe_error(id, c"safe: cannot make a mutable borrow from a shared reference", -1)
			got = retained_types[got].target
		else if (n.op != 'D'): safe_error(id, c"safe: borrowed aggregate requires a checked value or complete constructor", -1)
		int target = retained_types[safe_unqualified(want)].target
		if (safe_same_nominal(target, got) == 0):
			safe_error(id, c"safe: incompatible borrowed aggregate types", -1)
	else if (safe_record(n.semantic_type)):
		safe_error(id, c"safe: borrowed aggregate representation mismatch", -1)
	else if (inline_view):
		if (n.op == 'Z'):
			retained_node base
			retained_node_load(safe_child(&n, n.left), &base)
			if (safe_inline_slice(base.semantic_type) == 0):
				safe_error(id, c"safe: checked slice ranges require inline descriptor lowering", -1)
		if ((safe_inline_slice(n.semantic_type) == 0) && (array_value == 0)):
			safe_error(id, c"safe: checked pointer/slice representation mismatch", -1)
	else if (safe_inline_slice(n.semantic_type) || (safe_slice(want) != slice_value)):
		safe_error(id, c"safe: checked pointer/slice representation mismatch", -1)
	if (n.op == 'r'):
		retained_node place
		retained_node_load(safe_child(&n, n.left), &place)
		# A view's descriptor may be local even when its elements outlive
		# the function. Metadata also must not become writable via refmut.
		if (place.op == 'B'): safe_error(id, c"safe: buffer metadata cannot be borrowed", -1)
		if (place.op == '.'):
			retained_node base
			retained_node_load(safe_child(&place, place.left), &base)
			if (safe_record(base.semantic_type)):
				safe_error(id, c"safe: borrowed aggregate descriptor fields cannot be borrowed", -1)
		int wanted = safe_unqualified(safe_pointee(want))
		int actual = safe_unqualified(place.semantic_type)
		if ((wanted < 0) || (actual < 0) || (strcmp(retained_types[wanted].name, retained_types[actual].name) != 0)):
			safe_error(id, c"safe: incompatible checked pointer types", -1)
	else if (safe_record(want) == 0): safe_pointer_match(id, want, n.semantic_type)
	int root = -1
	int via = -1
	if ((n.op == 'D') && safe_record(want)):
		root = safe_record_construct(id, &n, want, state, &via)
	else if ((n.op == '.') && safe_kind(n.semantic_type)):
		retained_node base
		retained_node_load(safe_child(&n, n.left), &base)
		if (safe_record(base.semantic_type)):
			if ((kind == 3) && ((safe_kind(base.semantic_type) == 2) || (safe_kind(n.semantic_type) == 2))): safe_error(id, c"safe: cannot make a mutable borrow from a shared reference", -1)
			root = safe_borrow(safe_child(&n, n.left), base.semantic_type, state, &via)
		else if (safe_kind(base.semantic_type) && (safe_kind(n.semantic_type) == 1) && safe_owned_shape(safe_pointee(base.semantic_type))):
			root = safe_place(id, state, &via)
		else: safe_error(id, c"safe: unsupported reference-bearing projection", -1)
	else if ((n.op == 'C') || (n.op == 'G') || (n.op == 'W')):
		if ((safe_kind(n.semantic_type) < 2) || (safe_slice(want) && (inline_view == 0))):
			safe_error(id, c"safe: reference requires a borrowed return contract", -1)
		if ((kind == 3) && (safe_kind(n.semantic_type) == 2)):
			safe_error(id, c"safe: cannot make a mutable borrow from a shared reference", -1)
		root = safe_call(id, &n, state, &via)
	else if (n.op == 'Z'):
		retained_node base
		retained_node_load(safe_child(&n, n.left), &base)
		if (safe_inline_slice(base.semantic_type)):
			root = safe_borrow(safe_child(&n, n.left), base.semantic_type, state, &via)
		else:
			root = safe_place(safe_child(&n, n.left), state, &via)
			if (safe_slice(base.semantic_type)):
				safe_read(root, id, state)
				via = root
				root = safe_origin[root]
		# The descriptor receiver is evaluated before its bounds. A
		# temporary returned view must reserve its data through both bounds.
		int saved = safe_call_roots.length
		safe_call_roots.push(root)
		safe_call_kinds.push(2)
		safe_eval(safe_child(&n, n.right), state, -1)
		safe_eval(safe_child(&n, n.high), state, -1)
		while (safe_call_roots.length > saved):
			safe_call_roots.pop()
			safe_call_kinds.pop()
	else if (n.op == 'r'): root = safe_place(safe_child(&n, n.left), state, &via)
	else if (n.op == 'v'):
		int index = safe_index(n.binding)
		if ((index < 0) || ((safe_borrow_kind(n.semantic_type) == 0) && ((inline_view == 0) || (array_value == 0)))):
			safe_error(id, c"safe: reference requires an address or checked pointer", -1)
		safe_read(index, id, state)
		root = index
		if (safe_local_kind(index) >= 2):
			via = index
			root = safe_origin[index]
	else: safe_error(id, c"safe: reference requires a stable place", -1)
	int shared = safe_shared_parent(via)
	if ((shared >= 0) && (kind == 3)):
		safe_error(id, c"safe: cannot make a mutable borrow from a shared reference", safe_birth[shared])
	# A proven-absent value has no backing-storage obligation. Do not
	# resurrect its conservative former origins when it is copied/passed.
	if (safe_optional(n.semantic_type) && (safe_presence(id, state) == 16)):
		root = -1
		via = -1
	safe_access(root, via, kind == 3, id, state)
	*parent = via
	return root


int safe_scalar_type(int type):
	if (type < 0): return 0
	return safe_plain(type, 0) && (retained_types[type].fields.length == 0) && (retained_types[type].kind != type_kind_array)


char* safe_lifetime(int type):
	type = safe_unqualified(type)
	if (type < 0): return 0
	return retained_types[type].lifetime


int safe_same_contract_type(int a, int b):
	a = safe_unqualified(a)
	b = safe_unqualified(b)
	if ((a < 0) || (b < 0)): return a == b
	if (safe_kind(a) != safe_kind(b)): return 0
	if (safe_optional(a) != safe_optional(b)): return 0
	if (safe_inline_slice(a) != safe_inline_slice(b)): return 0
	if (safe_record(a) != safe_record(b)): return 0
	if (safe_record(a)):
		return safe_same_nominal(retained_types[a].target, retained_types[b].target)
	if (safe_kind(a)):
		a = safe_unqualified(retained_types[a].target)
		b = safe_unqualified(retained_types[b].target)
	return strcmp(retained_types[a].name, retained_types[b].name) == 0


int safe_contract_slot(retained_binding* binding, int slot):
	if (slot == binding.parameters.length): return binding.return_type
	return binding.parameters[slot]


# Lifetime spelling is local to a signature. Compare the equality relation
# between annotated positions, so alpha-renaming cannot change a contract.
int safe_contract_matches(retained_binding* left, retained_binding* right):
	if (left.parameters.length != right.parameters.length): return 0
	for i in range(left.parameters.length + 1):
		int a = safe_contract_slot(left, i)
		int b = safe_contract_slot(right, i)
		if (safe_same_contract_type(a, b) == 0): return 0
		char* al = safe_lifetime(a)
		char* bl = safe_lifetime(b)
		if ((al == 0) != (bl == 0)): return 0
		if (al == 0): continue
		for j in range(i):
			char* earlier_a = safe_lifetime(safe_contract_slot(left, j))
			char* earlier_b = safe_lifetime(safe_contract_slot(right, j))
			if ((earlier_a == 0) || (earlier_b == 0)): continue
			if ((strcmp(al, earlier_a) == 0) != (strcmp(bl, earlier_b) == 0)): return 0
	return 1


int safe_has_body(int function):
	int child = safe_first[function]
	while (child >= 0):
		if (retained_record_at(child).kind == retained_statement): return 1
		child = safe_next[child]
	return 0


# Unannotated results retain sole-input inference. An explicit result label
# denotes the intersection of every input carrying that label: callers retain
# all those origins, and the body may return a view derived from any of them.
int safe_return_parameter(int id, retained_binding* binding):
	if (safe_borrow_kind(binding.return_type) < 2): return -1
	if (safe_slice(binding.return_type) && (safe_inline_slice(binding.return_type) == 0)):
		safe_error(id, c"safe: returning slices requires an explicit lifetime contract", -1)
	char* lifetime = safe_lifetime(binding.return_type)
	int result = -1
	for p in range(binding.parameters.length):
		if (safe_borrow_kind(binding.parameters[p]) < 2): continue
		if (lifetime != 0):
			char* input = safe_lifetime(binding.parameters[p])
			if (input == 0): continue
			if (strcmp(input, lifetime) != 0): continue
		else if (result >= 0): safe_error(id, c"safe: returning references requires exactly one borrowed parameter", -1)
		result = p
		if ((safe_kind(binding.return_type) == 3) && (safe_kind(binding.parameters[p]) != 3)):
			safe_error(id, c"safe: mutable reference return requires a mutable borrowed parameter", -1)
	if (result < 0):
		if (lifetime != 0): safe_error(id, c"safe: returned lifetime must name a borrowed parameter", -1)
		# With no borrowed inputs an optional result has no legal origins;
		# body validation therefore permits absence, never local storage.
		if (safe_optional(binding.return_type)): return -1
		safe_error(id, c"safe: returning references requires exactly one borrowed parameter", -1)
	return result


int safe_return_from(retained_binding* binding, int inferred, int position):
	char* lifetime = safe_lifetime(binding.return_type)
	if (lifetime == 0): return inferred == position
	char* input = safe_lifetime(binding.parameters[position])
	if (input == 0): return 0
	return strcmp(input, lifetime) == 0


int safe_call(int id, retained_node* n, char* state, int* parent):
	int binding = safe_call_binding(n)
	if ((binding < 0) || (retained_bindings[binding].return_type < 0)):
		safe_error(id, c"safe: indirect calls require an ownership contract", -1)
	retained_binding* callee = retained_bindings[binding]
	if (((n.op == 'G') || (n.op == 'W')) && (n.generic_signature >= 0)):
		retained_type* signature = retained_types[n.generic_signature]
		retained_binding expected
		expected.return_type = signature.return_type
		expected.parameters = signature.parameters
		if (safe_contract_matches(&expected, callee) == 0):
			safe_error(id, c"safe: generic specialization disagrees with its concrete contract", -1)
	int function = safe_function_for_binding[binding]
	retained_binding* implementation = callee
	if (function >= 0):
		implementation = retained_bindings[retained_record_at(function).binding]
		if (safe_contract_matches(callee, implementation) == 0):
			safe_error(id, c"safe: forward declaration disagrees with its definition", function)
	if (safe_trusted(implementation.source)):
		if (safe_runtime_call(implementation) == 0):
			safe_error(id, c"safe: runtime call has no audited ownership contract", -1)
	else:
		if (function < 0): safe_error(id, c"safe: call has no checked implementation", -1)
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
			if (safe_return_from(callee, return_parameter, position)):
				return_root = safe_set_union(return_root, root)
				*parent = safe_set_union(*parent, via)
		else: root = safe_eval(arg, state, want)
		# Scalar arguments copy their value; only pointer contracts keep
		# storage reserved while later arguments are evaluated.
		if ((root >= 0) && kind):
			for i in range(saved, safe_call_roots.length):
				if (safe_set_overlap(safe_call_roots[i], root) && ((kind != 2) || (safe_call_kinds[i] != 2))):
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
	if (kind && (op == '=') && (want >= 0) && (wanted == 0)):
		safe_error(id, c"safe: checked pointers cannot escape into raw or scalar values", -1)
	int constructed = (op == 'D') && n.high && safe_owned_shape(safe_pointee(want))
	if (wanted >= 2): safe_error(id, c"safe: reference assignment is not supported", -1)
	if (wanted == 1):
		safe_pointer_match(id, want, n.semantic_type)
		if (((op == 'N') || (op == 'D')) && safe_opaque(safe_pointee(want))):
			safe_error(id, c"safe: opaque collections require an audited constructor", -1)
		if ((op != 'N') && (kind != 1) && (constructed == 0)): safe_error(id, c"safe: owner requires new storage or an ownership transfer", -1)
		if ((op != 'N') && (op != 'v') && (op != 'C') && (op != 'G') && (op != 'W') && (constructed == 0)): safe_error(id, c"safe: unsupported owner transfer", -1)
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
	if ((op == 'D') && (wanted == 1)):
		safe_owner_construct(id, &n, want, state)
		return -1
	if (op == 'N'):
		if (wanted != 1): safe_error(id, c"safe: new storage must initialize an owner", -1)
		if (safe_plain(safe_pointee(n.semantic_type), 0) == 0): safe_error(id, c"safe: allocation requires a pointer-free sized value", -1)
		return -1
	if ((op == 'C') || (op == 'G') || (op == 'W')):
		int parent = -1
		safe_call(id, &n, state, &parent)
		return -1
	if (op == '='):
		retained_node lhs
		retained_node_load(left, &lhs)
		int lk = safe_borrow_kind(lhs.semantic_type)
		int via = -1
		int root = safe_place(left, state, &via)
		if (safe_optional(lhs.semantic_type) && (lhs.op == 'v') && (n.value == 0)):
			int index = safe_index(lhs.binding)
			int parent = -1
			int previous = safe_replacing
			# The overwritten loan can end before RHS evaluation only if
			# no later operand reads its old value. Otherwise a call could
			# invalidate it, then pass the stale pointer as a later argument.
			int reads_previous = 0
			retained_group* group = retained_record_at(n.parent).group
			for i in range(group.count):
				int child_id = n.parent + 1 + i
				retained_node child
				retained_node_load(child_id, &child)
				if ((child_id != left) && (child.op == 'v') && (child.binding == lhs.binding)): reads_previous = 1
			if (reads_previous == 0): safe_replacing = index
			int source = safe_borrow(right, lhs.semantic_type, state, &parent)
			safe_replacing = previous
			if (safe_validate && safe_ancestor(index, parent)):
				safe_error(id, c"safe: optional replacement cannot create a reborrow cycle", safe_birth[index])
			int presence = safe_presence(right, state)
			safe_origin_join(index, source, parent)
			state[index] = 2 | presence
			return -1
		if (lk >= 2):
			int related = -1
			int named = safe_index(lhs.binding)
			if (named >= 0): related = safe_birth[named]
			safe_error(id, c"safe: references cannot be reassigned", related)
		if ((lk == 1) && ((lhs.op != 'v') || n.value)): safe_error(id, c"safe: owner assignment requires a plain binding", -1)
		if (n.value):
			for i in range(safe_locals.length):
				if (safe_set_has(root, i)): safe_read(i, id, state)
		# A projected destination holds an address through RHS evaluation.
		# A plain binding's slot stays valid when its owned payload moves.
		int saved = safe_call_roots.length
		if (lhs.op != 'v'):
			safe_call_roots.push(root)
			safe_call_kinds.push(2)
		safe_eval(right, state, lhs.semantic_type)
		while (safe_call_roots.length > saved):
			safe_call_roots.pop()
			safe_call_kinds.pop()
		# Replacement of a moved/uninitialized scalar is valid. A write
		# still conflicts with live borrows of its storage.
		if (lhs.op == 'v'): state[root] = 2
		safe_access(root, via, 1, id, state)
		return -1
	if ((op == 'd') || (op == '.') || (op == 'i') || (op == 'I') || (op == 'B')):
		int via = -1
		int root = safe_place(id, state, &via)
		safe_access(root, via, 0, id, state)
		safe_type_check(id, n.semantic_type)
		return -1
	if ((op == 0) || (op == 'c') || (op == 'h') || (op == 'f')): return -1
	int tested_presence = 1
	int tested = safe_presence_test(id, &tested_presence)
	if ((tested >= 0) && (op != 'v')):
		safe_read(tested, id, state)
		return -1
	if ((op == 'a') || (op == 'o')):
		char* continuing = safe_zero(safe_locals.length, 1)
		char* finished = safe_zero(safe_locals.length, 1)
		for i in range(safe_locals.length): continuing[i] = state[i]
		int at = left
		int continue_truth = op == 'a'
		while (at >= 0):
			safe_condition(at, continuing)
			for i in range(safe_locals.length): state[i] = continuing[i]
			safe_refine(at, state, 1 - continue_truth)
			for i in range(safe_locals.length): finished[i] = finished[i] | state[i]
			safe_refine(at, continuing, continue_truth)
			retained_node child
			retained_node_load(at, &child)
			at = safe_child(&child, child.next_arg)
		for i in range(safe_locals.length): state[i] = finished[i] | continuing[i]
		free(continuing)
		free(finished)
		return -1
	if (op == '?'):
		safe_condition(left, state)
		char* other = cast(char*, malloc(safe_locals.length + 1))
		for i in range(safe_locals.length): other[i] = state[i]
		safe_refine(left, state, 1)
		safe_refine(left, other, 0)
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


void safe_condition(int id, char* state):
	int present = 1
	int index = safe_presence_test(id, &present)
	if (index >= 0):
		safe_read(index, id, state)
		return
	safe_eval(id, state, -1)


int safe_within(int node, int scope):
	while (node >= 0):
		if (node == scope): return 1
		node = retained_record_at(node).parent
	return 0


int safe_condition_flow(safe_flow* f):
	if (f.alternate < 0): return 0
	char* name = retained_record_at(f.node).name
	return (strcmp(name, c"if") == 0) || (strcmp(name, c"while") == 0)


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
			int root = safe_borrow(f.expression, type, state, &parent)
			safe_origin_join(index, root, parent)
		else: safe_eval(f.expression, state, type)
		int presence = 0
		if (safe_optional(type) && (f.expression >= 0)): presence = safe_presence(f.expression, state)
		state[index] = 1
		if ((f.expression >= 0) || (retained_types[type].kind == type_kind_array)): state[index] = 2 | presence
		if ((f.expression < 0) && safe_kind(type)): safe_error(f.node, c"safe: checked pointers require initialization", -1)
	else if (f.action == 2):
		if (safe_borrow_kind(safe_return_type) >= 2):
			if (f.expression < 0): safe_error(f.node, c"safe: reference return requires a value", -1)
			int parent = -1
			int root = safe_borrow(f.expression, safe_return_type, state, &parent)
			f.return_roots = root
			if (safe_validate):
				for i in range(safe_locals.length):
					if (safe_set_has(root, i) && (safe_set_has(safe_return_root, i) == 0)):
						safe_error(f.node, c"safe: returned reference must borrow from the function's borrowed parameter", safe_birth[i])
		else: safe_eval(f.expression, state, safe_return_type)
	else if (f.action == 3):
		# A loop reuses a binding for each allocation/stack lifetime. Kill
		# surviving loans as well as the ended roots so the next iteration
		# cannot revive a pointer into an earlier incarnation of that root.
		for root in range(safe_locals.length):
			if (safe_within(safe_birth[root], f.node) == 0): continue
			for borrower in range(safe_locals.length):
				if (safe_local_kind(borrower) < 2): continue
				if (safe_set_has(safe_origin[borrower], root) == 0): continue
				if (safe_optional(retained_bindings[safe_locals[borrower]].type) && ((state[borrower] & 48) == 16)): continue
				state[borrower] = (state[borrower] & 48) | 4
				safe_moved_at[borrower] = f.node
		for i in range(safe_locals.length):
			if (safe_within(safe_birth[i], f.node)): state[i] = 1
	else if (f.action == 4): state[index] = 2
	else if ((f.action == 5) || (f.action == 6)):
		safe_access(index, -1, f.action == 6, f.node, state)
	else if (f.action == 7):
		int roots = -1
		if (f.returning >= 0): roots = safe_graph[f.returning].return_roots
		if (roots >= 0):
			safe_call_roots.push(roots)
			safe_call_kinds.push(safe_borrow_kind(safe_return_type))
		safe_eval(f.expression, state, -1)
		if (roots >= 0):
			safe_call_roots.pop()
			safe_call_kinds.pop()
	else if (safe_condition_flow(f)): safe_condition(f.expression, state)
	else: safe_eval(f.expression, state, -1)


void safe_function_check(int function):
	safe_function = function
	safe_replacing = -1
	retained_record* fn = retained_record_at(function)
	if (fn.expression_fallback): safe_error(function, c"safe: unsupported expression fallback", -1)
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
			int block = n.parent
			if ((block < 0) || (retained_record_at(block).parent != function)):
				safe_error(id, c"safe: defer requires the function's outer lexical block", -1)
	int count = safe_locals.length
	safe_sets = new list[char*]
	for i in range(count):
		char* singleton = safe_zero(count, 1)
		singleton[i] = 1
		safe_sets.push(singleton)
	safe_origin = cast(int*, malloc((count + 1) * __word_size__))
	safe_parent_ref = cast(int*, malloc((count + 1) * __word_size__))
	safe_birth = cast(int*, malloc((count + 1) * __word_size__))
	safe_moved_at = cast(int*, malloc((count + 1) * __word_size__))
	for i in range(count):
		safe_origin[i] = -1
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
		if ((f.action == 5) || (f.action == 6)): f.uses[f.binding] = 1
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
				if (((f.action != 1) && (f.action != 4)) || (f.binding != j)):
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
			if (safe_return_from(retained_bindings[fn.binding], return_parameter, parameter)):
				safe_return_root = safe_set_union(safe_return_root, i)
			parameter = parameter + 1
			safe_type_check(safe_birth[i], retained_bindings[safe_locals[i]].type)
			initial[i] = 2
			safe_origin[i] = i
			if (safe_optional(retained_bindings[safe_locals[i]].type)): initial[i] = 50
	safe_graph[start].reached = 1
	char* state = cast(char*, malloc(count + 1))
	char* refined = cast(char*, malloc(count + 1))
	safe_validate = 0
	changed = 1
	while (changed):
		changed = 0
		for i in range(safe_graph.length):
			safe_flow* f = safe_graph[i]
			if (f.reached == 0): continue
			for j in range(count): state[j] = f.state[j]
			safe_origins_changed = 0
			safe_transfer(i, state)
			if (safe_origins_changed): changed = 1
			for edge in range(2):
				int target = f.next
				if (edge): target = f.alternate
				if (target < 0): continue
				safe_flow* to = safe_graph[target]
				if (to.reached == 0):
					to.reached = 1
					changed = 1
				for j in range(count): refined[j] = state[j]
				if (safe_condition_flow(f)): safe_refine(f.expression, refined, edge == 0)
				for j in range(count):
					int joined = to.state[j] | refined[j]
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
	free(refined)
	for i in range(safe_graph.length):
		free(safe_graph[i].state)
		free(safe_graph[i].live)
		free(safe_graph[i].uses)
		free(safe_graph[i])
	safe_graph.free()
	for i in range(safe_sets.length): free(safe_sets[i])
	safe_sets.free()
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
	if ((target_isa != 0) || ((target_os != 0) && (target_os != 2))): error(c"safe: only Linux x86 and x64, and win64 targets are supported")
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
			if ((safe_trusted(n.source) == 0) && (safe_mode || safe_kind(retained_bindings[n.binding].return_type))): safe_checked_functions[i] = 1
		if ((n.kind == retained_local) && (safe_trusted(n.source) == 0) && safe_kind(n.semantic_type)):
			safe_checked_functions[retained_bindings[n.binding].owner] = 1
	for id in range(count):
		retained_node n
		retained_node_load(id, &n)
		if (safe_trusted(n.source)): continue
		int checked = safe_contains_checked(n.semantic_type)
		int call_binding = n.binding
		if ((n.kind == retained_expression) && ((n.op == 'G') || (n.op == 'W'))): call_binding = safe_call_binding(&n)
		if ((n.kind == retained_expression) && (call_binding >= 0)):
			retained_binding* callee = retained_bindings[call_binding]
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
					if (safe_contains_checked(t.fields[field].type) && (safe_record_shape(n.semantic_type, 3) == 0) && (safe_record(n.semantic_type) == 0) && (safe_owned_shape(n.semantic_type) == 0)):
						safe_error(id, c"safe: checked pointers in aggregates require one named shared-reference group", -1)
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
	# A declaration carries a contract even when no call reaches it. Validate
	# its result relationship and compare every completed forward signature.
	for b in range(retained_bindings.length):
		retained_binding* binding = retained_bindings[b]
		if ((binding.return_type < 0) || safe_trusted(binding.source)): continue
		int checked = safe_mode || safe_contains_checked(binding.return_type)
		for p in range(binding.parameters.length):
			if (safe_contains_checked(binding.parameters[p])): checked = 1
		int function = safe_function_for_binding[b]
		if (function >= 0):
			retained_binding* implementation = retained_bindings[retained_record_at(function).binding]
			# Erasing every qualifier in an unused prototype must not erase
			# the completed implementation's checked or audited contract.
			if (safe_buffer_source(implementation.source) || safe_contains_checked(implementation.return_type)): checked = 1
			for p in range(implementation.parameters.length):
				if (safe_contains_checked(implementation.parameters[p])): checked = 1
		if (checked == 0): continue
		int at = function
		if (at < 0): at = retained_sources[binding.source].root
		safe_return_parameter(at, binding)
		if (function >= 0):
			retained_binding* definition = retained_bindings[retained_record_at(function).binding]
			if (safe_contract_matches(binding, definition) == 0):
				safe_error(at, c"safe: forward declaration disagrees with its definition", function)
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
	if (safe_contains_seen != 0): free(cast(char*, safe_contains_seen))
	safe_contains_seen = 0
	safe_contains_generation = 0
	if (safe_contains_pending != 0): safe_contains_pending.free()
	safe_contains_pending = 0
