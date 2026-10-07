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
import compiler.statement_ast

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


# ---------------------------------------------------------------------------
# S2.2: parse a statement completely, then emit it by walking its record.
#
# A statement family that supports the walk records, while it parses, the
# facts its emitter needs (its statement_ast node and the retained group of
# its expression child) and an ordered list of phases. A phase is one of the
# family's emission steps, tagged with an emission point: the lexer state the
# streaming emitter ran that step in. Diagnostics, DWARF notes and constant
# checks read the current token and line, so the walk switches the lexer to
# each phase's point around the step, and back to the parse's position after.
# The family's parse ends with retained_emit_statement(node), the entry point
# of the walk: it emits every remaining phase in recorded order.
#
# Families plug in without a shared switch: retained_walk_begin stores the
# family's own emitter in the record, void emitter(retained_statement_walk*
# walk, int phase), and phase codes are private to that emitter (family (a)'s
# are in compiler/statement_ast.w).
#
# Order-sensitive parse steps. Moving emission after the rest of the parse
# keeps images identical but would move the emitter's diagnostics after any
# diagnostic printed by a parse step in between (a lexer warning on the next
# line, a missing terminator). A family therefore drains the phases recorded
# so far (retained_walk_drain) before any such step that may print, which
# emits them at their original place in the output; the rest of the walk
# still runs after the parse.
#
# Lifetime: a record borrows its statement_ast node and expression arena from
# the parsing frame. That is sound while a family walks before its hook
# returns; a walk that outlives the frame must own copies. Records, phases
# and points are pooled and released, last in first out, once walked.

void retained_expression_note(expression_ast* tree, int root);
void emit_expression_ast(expression_ast* tree, int id);

struct retained_statement_walk:
	int node
	int emitter
	statement_ast* statement
	expression_ast* tree
	int group
	int root
	int phase_base
	int phase_count
	int point_base
	int point_count
	int done
	int walked

list[retained_statement_walk*] retained_walks
int retained_walks_used
list[int] retained_walk_phase_codes
list[int] retained_walk_phase_points
int retained_walk_phases_used
list[tokenizer_snapshot*] retained_emit_points
list[char*] retained_emit_point_texts
list[int] retained_emit_point_sizes
int retained_emit_points_used
# --stats: statements emitted by the walk rather than during their parse.
int ast_retained_statements_emitted


# A record that was walked, or whose statement node was retracted (an error
# rolled a REPL entry back mid-statement), no longer holds pool entries.
int retained_walk_stale(int id):
	retained_statement_walk* walk = retained_walks[id]
	if (walk.walked): return 1
	if (walk.node >= retained_nodes.length): return 1
	return retained_nodes[walk.node].statement_walk != id


void retained_walk_release():
	while ((retained_walks_used > 0) && retained_walk_stale(retained_walks_used - 1)):
		retained_statement_walk* top = retained_walks[retained_walks_used - 1]
		retained_walk_phases_used = top.phase_base
		retained_emit_points_used = top.point_base
		retained_walks_used = retained_walks_used - 1


# Start a walk record for the statement being parsed, attached to its
# retained statement node. Returns -1 when the statement must be emitted
# during its parse: the mode is off, or there is no retained statement node
# (a hook called outside the statement dispatcher) or it already has one.
int retained_walk_begin(int emitter, statement_ast* statement):
	if ((ast_emit_retained_mode == 0) || (retained_parent < 0)): return -1
	retained_node* node = retained_nodes[retained_parent]
	if ((node.kind != retained_statement) || (node.statement_walk >= 0)): return -1
	if (retained_walks == 0):
		retained_walks = new list[retained_statement_walk*]
		retained_walk_phase_codes = new list[int]
		retained_walk_phase_points = new list[int]
		retained_emit_points = new list[tokenizer_snapshot*]
		retained_emit_point_texts = new list[char*]
		retained_emit_point_sizes = new list[int]
	retained_walk_release()
	int id = retained_walks_used
	if (id == retained_walks.length): retained_walks.push(new retained_statement_walk)
	retained_walks_used = id + 1
	retained_statement_walk* walk = retained_walks[id]
	walk.node = retained_parent
	walk.emitter = emitter
	walk.statement = statement
	walk.tree = 0
	walk.group = -1
	walk.root = -1
	walk.phase_base = retained_walk_phases_used
	walk.phase_count = 0
	walk.point_base = retained_emit_points_used
	walk.point_count = 0
	walk.done = 0
	walk.walked = 0
	node.statement_walk = id
	return id


# 1 when the lexer is exactly at the recorded point.
int retained_emit_point_current(int point):
	tokenizer_snapshot* s = retained_emit_points[point]
	if ((s.token_serial != token_serial) || (s.byte_offset != byte_offset)): return 0
	if ((s.token_start_offset != token_start_offset) || (s.token_i != token_i)): return 0
	if ((s.file != file) || (s.filename != filename) || (s.nextc != nextc)): return 0
	if ((s.line_number != line_number) || (s.column_number != column_number)): return 0
	if ((s.diag_token_line != diag_token_line) || (s.diag_token_column != diag_token_column)): return 0
	if ((s.tab_level != tab_level) || (s.token_newline != token_newline)): return 0
	return strcmp(retained_emit_point_texts[point], token) == 0


int retained_emit_point_save():
	int id = retained_emit_points_used
	if (id == retained_emit_points.length):
		retained_emit_points.push(new tokenizer_snapshot)
		retained_emit_point_texts.push(0)
		retained_emit_point_sizes.push(0)
	retained_emit_points_used = id + 1
	tokenizer_snapshot_save(retained_emit_points[id])
	int length = strlen(token)
	if (retained_emit_point_sizes[id] <= length):
		int size = (length + 16) << 1
		if (retained_emit_point_texts[id] != 0): free(retained_emit_point_texts[id])
		retained_emit_point_texts[id] = cast(char*, malloc(size))
		retained_emit_point_sizes[id] = size
	char* text = retained_emit_point_texts[id]
	for i in range(length): text[i] = token[i]
	text[length] = 0
	return id


# Record the next emission step of a walk at the current lexer state.
void retained_walk_phase(int id, int code):
	retained_statement_walk* walk = retained_walks[id]
	# A nested walk runs to completion inside a drain, so a record's
	# phases and points stay contiguous.
	assert1(retained_walk_phases_used == walk.phase_base + walk.phase_count)
	int point = walk.point_base + walk.point_count - 1
	if ((walk.point_count == 0) || (retained_emit_point_current(point) == 0)):
		assert1(retained_emit_points_used == walk.point_base + walk.point_count)
		point = retained_emit_point_save()
		walk.point_count = walk.point_count + 1
	int k = retained_walk_phases_used
	if (k == retained_walk_phase_codes.length):
		retained_walk_phase_codes.push(code)
		retained_walk_phase_points.push(point)
	else:
		retained_walk_phase_codes[k] = code
		retained_walk_phase_points[k] = point
	retained_walk_phases_used = k + 1
	walk.phase_count = walk.phase_count + 1


# The expression child: record its retained group now, without lowering it
# (that is the walk's job, retained_walk_lower_expression). The note runs
# exactly where the streaming emitter's would, right after preparation.
void retained_walk_expression(int id, expression_ast* tree, int root):
	retained_statement_walk* walk = retained_walks[id]
	retained_init()
	int group = retained_nodes.length
	int lowering = ast_emit_retained_mode
	ast_emit_retained_mode = 0
	retained_expression_note(tree, root)
	ast_emit_retained_mode = lowering
	assert1(retained_nodes[group].kind == retained_expression_group)
	walk.tree = tree
	walk.group = group
	walk.root = root


# Lower the walk's expression child from its retained group (S2.1's
# adapter rebuilds the arena and checks it against the parse); returns
# the root node ID.
int retained_walk_lower_expression(retained_statement_walk* walk):
	int root = retained_emit_expression_group(walk.tree, walk.group)
	assert1(root == walk.root)
	emit_expression_ast(walk.tree, root)
	return root


# The source descriptor's logical read position (getchar's buffered view).
int retained_emit_source_position():
	if ((file < 0) || (file >= GETCHAR_MAX_FD)): return -1
	return getchar_kernel_pos[file] - getchar_limit[file] + getchar_pos[file]


# Emit the recorded phases not yet emitted, each at its emission point,
# then return the lexer to where the parse stands. The source descriptor
# is not moved to a point: a phase that reads source (a diagnostic's
# context line, a deferred-statement reparse) seeks absolutely, and the
# parse's read position is restored afterwards if a phase moved it.
void retained_walk_drain(int id):
	retained_statement_walk* walk = retained_walks[id]
	if (walk.done >= walk.phase_count): return
	tokenizer_snapshot resume
	tokenizer_snapshot_save(&resume)
	char* resume_text = 0
	int resume_file = file
	int resume_position = retained_emit_source_position()
	while (walk.done < walk.phase_count):
		int k = walk.phase_base + walk.done
		int point = retained_walk_phase_points[k]
		if (retained_emit_point_current(point) == 0):
			if (resume_text == 0): resume_text = strclone(token)
			tokenizer_snapshot_restore(retained_emit_points[point], retained_emit_point_texts[point])
		walk.done = walk.done + 1
		# The family's emitter, held as an address like analysis_run's
		# operation (compiler/analysis.w).
		int emitter = walk.emitter
		emitter(walk, retained_walk_phase_codes[k])
	if (resume_text != 0):
		tokenizer_snapshot_restore(&resume, resume_text)
		free(resume_text)
	if ((resume_position >= 0) && (file == resume_file) && (retained_emit_source_position() != resume_position)):
		getchar_seek(file, resume_position)


# The walk's entry point: emit the retained statement node's remaining
# phases and release its record (and any walked records above it).
void retained_emit_statement(int node):
	int id = retained_nodes[node].statement_walk
	assert1(id >= 0)
	retained_walk_drain(id)
	retained_walks[id].walked = 1
	retained_nodes[node].statement_walk = -1
	ast_retained_statements_emitted = ast_retained_statements_emitted + 1
	retained_walk_release()


# --stats: statements the dispatcher entered, from the retained forest.
int retained_statement_count():
	if (retained_nodes == 0): return 0
	int count = 0
	for i in range(retained_nodes.length):
		if (retained_nodes[i].kind == retained_statement): count = count + 1
	return count
