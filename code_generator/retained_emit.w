# S2.1: emit expressions from the retained forest (--ast-emit-retained).
# retained_expression_note copies each prepared expression arena into a
# retained group just before emission. In this mode the adapter below then
# reconstitutes the arena from that group alone, overwriting every node
# column and the decoded text/type-name arenas, so the backend visitor in
# code_generator/expression_ast.w lowers retained data rather than the
# temporary parse. Node IDs stay group-local, so the root is the group's op.
#
# The retained copy closes the arena's borrowed and overloaded slots as
# follows (each was a gap found by compiling with this mode):
# - result, signature, receiver and inference types are retained semantic
#   types; the arena's value-type encoding is a separate flag for each.
# - symbol-table operands ('v', 'C', 'X', 'z', 'l', 'G', 'W') resolve
#   through their retained binding; the name operand is the binding's
#   spelling suffix of the symbol record, so it is rebuilt as an offset
#   from that binding.
# - argument-count and self-assignment warnings name a symbol by spelling
#   only, and the argument warning also borrows its record; the retained
#   node keeps a binding for that symbol (name_binding).
# - message-bearing warnings carry their interned message text.
# - generic calls ('G', 'W') name their definition, not its table index.
# Every other column is a group-local index, a decoded literal, an offset
# into the retained text arena, a source offset, a type-table index (the
# identity retained_types records as origin) or a lowering payload whose
# value the retained node holds verbatim (see retained_node).
#
# The adapter also compares each reconstituted field with the temporary
# arena it replaces. A difference means the retained copy lost information,
# so it is a compiler bug and stops the compilation, rather than letting
# the image silently differ from the default emitter's.

int ast_emit_retained_mode
# --stats: expression groups lowered from the retained forest.
int ast_retained_emitted


void retained_emit_check(int expected, int actual, char* column):
	if (expected == actual): return
	error3(c"internal error: --ast-emit-retained: retained ", column, c" differs from the parsed expression")


# The arena's type convention: -1 untyped, a table index, or a value type.
int retained_emit_type(int semantic, int is_value):
	if (semantic < 0): return -1
	int origin = retained_types[semantic].origin
	if (is_value): return type_value(origin)
	return origin


# A symbol-table name operand: the spelling ends at the record itself.
int retained_emit_name(retained_node* node, int binding):
	if (binding < 0): return 0
	return retained_bindings[binding].origin - strlen(node.payload_text)


# Warnings whose operand is a message or context string, not an offset.
int retained_emit_message(retained_node* node):
	if (node.op != ast_warning): return 0
	return (node.high == 0) || (node.high == 6) || (node.high == 7) || (node.high == 8)


int retained_emit_value(retained_node* node):
	int op = node.op
	if ((op == 'v') || (op == 'C') || (op == 'X') || (op == 'z') || (op == 'l')):
		return retained_emit_name(node, node.binding)
	if (retained_emit_message(node)): return cast(int, node.payload_text)
	if ((op == ast_warning) && ((node.high == 1) || (node.high == 2) || (node.high == 5))):
		return retained_emit_name(node, node.name_binding)
	if ((op == 'G') || (op == 'W')): return generic_def_lookup(node.payload_text, 0)
	return node.value


int retained_emit_symbol(retained_node* node):
	int op = node.op
	if ((op == 'v') || (op == 'C') || (op == 'X') || (op == 'z') || (op == 'l') || (op == 'G') || (op == 'W')):
		if (node.binding >= 0): return retained_bindings[node.binding].origin
	if ((op == ast_warning) && (node.high == 1) && (node.name_binding >= 0)): return retained_bindings[node.name_binding].origin
	return node.symbol


# Overwrite the arena bound to tree with the contents of retained group.
# Returns the root node ID recorded for the group.
int retained_emit_expression_group(expression_ast* tree, int group):
	retained_node* owner = retained_nodes[group]
	int count = 0
	int limit = retained_nodes.length
	while ((group + 1 + count < limit) && (retained_nodes[group + 1 + count].parent == group)): count = count + 1
	retained_emit_check(tree.count, count, c"count")
	assert1(count <= tree.capacity)
	retained_emit_check(tree.text_used, owner.arena_text_length, c"text")
	retained_emit_check(tree.type_names_used, owner.arena_type_names_length, c"type_names")
	for i in range(owner.arena_text_length):
		retained_emit_check(tree.text[i], owner.arena_text[i], c"text")
		tree.text[i] = owner.arena_text[i]
	for i in range(owner.arena_type_names_length):
		retained_emit_check(tree.type_names[i], owner.arena_type_names[i], c"type_names")
		tree.type_names[i] = owner.arena_type_names[i]
	tree.count = count
	tree.text_used = owner.arena_text_length
	tree.type_names_used = owner.arena_type_names_length
	retained_emit_check(tree.end_offset, owner.end, c"end_offset")
	retained_emit_check(tree.readonly, owner.readonly, c"readonly")
	retained_emit_check(tree.whole_expression, owner.whole_expression, c"whole_expression")
	retained_emit_check(tree.final_token_offset, owner.final_token_offset, c"final_token_offset")
	tree.end_offset = owner.end
	tree.readonly = owner.readonly
	tree.whole_expression = owner.whole_expression
	tree.final_token_offset = owner.final_token_offset
	for i in range(count):
		retained_node* node = retained_nodes[group + 1 + i]
		int at = node.start
		int value = retained_emit_value(node)
		int symbol = retained_emit_symbol(node)
		int result = retained_emit_type(node.semantic_type, node.result_is_value)
		int signature = retained_emit_type(node.generic_signature, node.type_value_flags & 1)
		int receiver = retained_emit_type(node.call_receiver_type, node.type_value_flags & 2)
		int want = retained_emit_type(node.infer_want, node.type_value_flags & 4)
		retained_emit_check(tree.op[i], node.op, c"op")
		retained_emit_check(tree.left[i], node.left, c"left")
		retained_emit_check(tree.right[i], node.right, c"right")
		retained_emit_check(tree.offset[i], at, c"offset")
		# A message is compared by text: the retained copy is interned.
		int original = tree.value[i]
		if (retained_emit_message(node) && original && (strcmp(cast(char*, original), node.payload_text) == 0)): original = value
		retained_emit_check(original, value, c"value")
		retained_emit_check(tree.result_type[i], result, c"result_type")
		retained_emit_check(tree.high[i], node.high, c"high")
		retained_emit_check(tree.next_arg[i], node.next_arg, c"next_arg")
		retained_emit_check(tree.in_cast[i], node.in_cast, c"in_cast")
		retained_emit_check(tree.binding_name[i], node.binding_text_offset, c"binding_name")
		retained_emit_check(tree.binding_offset[i], node.binding_offset, c"binding_offset")
		retained_emit_check(tree.symbol[i], symbol, c"symbol")
		retained_emit_check(tree.qualified[i], node.qualified, c"qualified")
		retained_emit_check(tree.it_slot[i], node.it_slot, c"it_slot")
		retained_emit_check(tree.generic_parameters[i], node.generic_parameters, c"generic_parameters")
		retained_emit_check(tree.generic_signature[i], signature, c"generic_signature")
		retained_emit_check(tree.generic_offset[i], node.generic_offset, c"generic_offset")
		retained_emit_check(tree.generic_instance[i], node.generic_instance, c"generic_instance")
		retained_emit_check(tree.generic_arity[i], node.generic_arity, c"generic_arity")
		retained_emit_check(tree.infer_coercion[i], node.infer_coercion, c"infer_coercion")
		retained_emit_check(tree.call_receiver_type[i], receiver, c"call_receiver_type")
		retained_emit_check(tree.infer_want[i], want, c"infer_want")
		tree.op[i] = node.op
		tree.left[i] = node.left
		tree.right[i] = node.right
		tree.offset[i] = at
		tree.value[i] = value
		tree.result_type[i] = result
		tree.high[i] = node.high
		tree.next_arg[i] = node.next_arg
		tree.in_cast[i] = node.in_cast
		tree.binding_name[i] = node.binding_text_offset
		tree.binding_offset[i] = node.binding_offset
		tree.symbol[i] = symbol
		tree.qualified[i] = node.qualified
		tree.it_slot[i] = node.it_slot
		tree.generic_parameters[i] = node.generic_parameters
		tree.generic_signature[i] = signature
		tree.generic_offset[i] = node.generic_offset
		tree.generic_instance[i] = node.generic_instance
		tree.generic_arity[i] = node.generic_arity
		tree.infer_coercion[i] = node.infer_coercion
		tree.call_receiver_type[i] = receiver
		tree.infer_want[i] = want
	ast_retained_emitted = ast_retained_emitted + 1
	return owner.op
