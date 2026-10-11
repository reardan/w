# S2.1: emit expressions from the retained forest (--ast-emit-retained; the
# default for every AST compile since S2.5). retained_expression_note copies
# each prepared expression arena into a retained group just before emission,
# and emit_prepared_expression_ast (code_generator/expression_ast.w) or a
# statement walk then has the adapter below reconstitute the arena from that
# group alone, overwriting every node column and the decoded text/type-name
# arenas, so the backend visitor in code_generator/expression_ast.w lowers
# retained data rather than the temporary parse. Node IDs stay
# group-local, so the root is the group's op.
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
#
# P1.2b: a group holds its columns in one session-arena block, and the
# semantic records above (types, bindings, interned operand spellings) are
# kept only in a semantic session (retained_semantic_mode: tree queries and
# --ast-retain). Both session modes lower an independent view of the group's
# columns and text (retained_emit_expression). The compatibility adapter
# still validates the parse arena against the group, with the full semantic
# comparison when those records are present, but emission never uses it.
import compiler.statement_ast

int ast_emit_retained_mode
# --stats: expression groups lowered from the retained forest.
int ast_retained_emitted


# Callers compare first (S2.5: one call per mismatch, not per column).
void retained_emit_check(int expected, int actual, char* column):
	if (expected == actual): return
	error3(c"internal error: --ast-emit-retained: retained ", column, c" differs from the parsed expression")


# The name of arena column c (compiler/retained_ast.w retained_group).
char* retained_emit_column_name(int c):
	if (c == 0): return c"op"
	if (c == 1): return c"left"
	if (c == 2): return c"right"
	if (c == 3): return c"offset"
	if (c == 4): return c"value"
	if (c == 5): return c"result_type"
	if (c == 6): return c"high"
	if (c == 7): return c"next_arg"
	if (c == 8): return c"in_cast"
	if (c == 9): return c"binding_name"
	if (c == 10): return c"binding_offset"
	if (c == 11): return c"symbol"
	if (c == 12): return c"qualified"
	if (c == 13): return c"it_slot"
	if (c == 14): return c"generic_parameters"
	if (c == 15): return c"generic_signature"
	if (c == 16): return c"generic_offset"
	if (c == 17): return c"generic_instance"
	if (c == 18): return c"generic_arity"
	if (c == 19): return c"infer_coercion"
	if (c == 20): return c"call_receiver_type"
	return c"infer_want"


# The arena's type convention: -1 untyped, a table index, or a value type.
int retained_emit_type(int semantic, int is_value):
	if (semantic < 0): return -1
	int origin = retained_types[semantic].origin
	if (is_value): return type_value(origin)
	return origin


# A symbol-table name operand: the spelling ends at the record itself.
int retained_emit_name(char* payload, int binding):
	if (binding < 0): return 0
	return retained_bindings[binding].origin - strlen(payload)


# P1.2b: in a semantic session, the operands rebuilt from their semantic
# records alone (retained types and bindings, interned spellings) must equal
# the arena columns, as S2.1's adapter required of every retained node.
void retained_emit_semantic_check(expression_ast* tree, retained_group* group):
	int count = group.count
	int* s = group.semantic
	for i in range(count):
		int op = tree.op[i]
		int high = tree.high[i]
		int binding = s[4 * count + i]
		int name_binding = s[5 * count + i]
		char* payload = cast(char*, s[6 * count + i])
		int value = tree.value[i]
		int expected = value
		if ((op == 'v') || (op == 'C') || (op == 'X') || (op == 'z') || (op == 'l')): expected = retained_emit_name(payload, binding)
		else if ((op == ast_warning) && ((high == 0) || (high == 6) || (high == 7) || (high == 8))):
			# A message is compared by text: the retained copy is interned.
			expected = cast(int, payload)
			if (value && (strcmp(cast(char*, value), payload) == 0)): expected = value
		else if ((op == ast_warning) && ((high == 1) || (high == 2) || (high == 5))): expected = retained_emit_name(payload, name_binding)
		else if ((op == 'G') || (op == 'W')): expected = generic_def_lookup(payload, 0)
		if (value != expected): retained_emit_check(value, expected, c"value")
		int symbol = tree.symbol[i]
		expected = symbol
		if ((op == 'v') || (op == 'C') || (op == 'X') || (op == 'z') || (op == 'l') || (op == 'G') || (op == 'W')):
			if (binding >= 0): expected = retained_bindings[binding].origin
		if ((op == ast_warning) && (high == 1) && (name_binding >= 0)): expected = retained_bindings[name_binding].origin
		if (symbol != expected): retained_emit_check(symbol, expected, c"symbol")
		int result = retained_emit_type(s[i], tree.result_type[i] < -1)
		if (tree.result_type[i] != result): retained_emit_check(tree.result_type[i], result, c"result_type")
		int signature = retained_emit_type(s[count + i], tree.generic_signature[i] < -1)
		if (tree.generic_signature[i] != signature): retained_emit_check(tree.generic_signature[i], signature, c"generic_signature")
		int receiver = retained_emit_type(s[2 * count + i], tree.call_receiver_type[i] < -1)
		if (tree.call_receiver_type[i] != receiver): retained_emit_check(tree.call_receiver_type[i], receiver, c"call_receiver_type")
		int want = retained_emit_type(s[3 * count + i], tree.infer_want[i] < -1)
		if (tree.infer_want[i] != want): retained_emit_check(tree.infer_want[i], want, c"infer_want")


# Check the arena bound to tree against the contents of retained group.
# Returns the root node ID recorded for the group.
int retained_emit_expression_group(expression_ast* tree, int id):
	retained_record* owner = retained_record_at(id)
	retained_group* group = owner.group
	int count = group.count
	if (tree.count != count): retained_emit_check(tree.count, count, c"count")
	assert1(count <= tree.capacity)
	if (tree.text_used != group.arena_text_length): retained_emit_check(tree.text_used, group.arena_text_length, c"text")
	if (tree.type_names_used != group.arena_type_names_length): retained_emit_check(tree.type_names_used, group.arena_type_names_length, c"type_names")
	# The adapter's arena already holds the parse: a difference means the
	# retained copy lost information (S2.1), and stops the compilation.
	int at = retained_bytes_differ(tree.type_names, group.arena_type_names, group.arena_type_names_length)
	if (at >= 0): retained_emit_check(tree.type_names[at], group.arena_type_names[at], c"type_names")
	tree.count = count
	tree.text_used = group.arena_text_length
	tree.type_names_used = group.arena_type_names_length
	if (tree.end_offset != owner.end): retained_emit_check(tree.end_offset, owner.end, c"end_offset")
	if (tree.readonly != group.readonly): retained_emit_check(tree.readonly, group.readonly, c"readonly")
	if (tree.whole_expression != group.whole_expression): retained_emit_check(tree.whole_expression, group.whole_expression, c"whole_expression")
	if (tree.final_token_offset != group.final_token_offset): retained_emit_check(tree.final_token_offset, group.final_token_offset, c"final_token_offset")
	tree.end_offset = owner.end
	tree.readonly = group.readonly
	tree.whole_expression = group.whole_expression
	tree.final_token_offset = group.final_token_offset
	# P1.2b: a plain session's visitor reads the group's columns in place
	# (retained_emit_lower), so only a semantic session compares them.
	if (group.semantic != 0):
		at = retained_bytes_differ(tree.text, group.arena_text, group.arena_text_length)
		if (at >= 0): retained_emit_check(tree.text[at], group.arena_text[at], c"text")
		# The arena's columns are contiguous, tree.capacity words apart, in
		# the order the group keeps them.
		int* from = group.columns
		int* to = tree.op
		int stride = tree.capacity
		for c in range(retained_expression_columns):
			at = retained_words_differ(to, from, count)
			if (at >= 0): retained_emit_check(to[at], from[at], retained_emit_column_name(c))
			from = &from[count]
			to = &to[stride]
		retained_emit_semantic_check(tree, group)
	return group.root


void emit_expression_ast_root(expression_ast* tree, int root);


# Bind a lowering view to an owned expression group. Unlike the comparison
# adapter, this does not read the parse arena or require its stack frame to
# remain alive. The group's column and text storage belongs to the retained
# session; the view borrows it only for the duration of the walk.
void retained_expression_view(expression_ast* tree, int id):
	retained_record* owner = retained_record_at(id)
	assert1(owner.kind == retained_expression_group)
	retained_group* group = owner.group
	int count = group.count
	int* c = group.columns
	tree.slab = -1
	tree.capacity = count
	tree.count = count
	tree.end_offset = owner.end
	tree.readonly = group.readonly
	tree.whole_expression = group.whole_expression
	tree.final_token_offset = group.final_token_offset
	tree.text_used = group.arena_text_length
	tree.type_names_used = group.arena_type_names_length
	tree.token_count = group.location_count
	tree.tokens = group.locations
	tree.type_names = group.arena_type_names
	tree.text = group.arena_text
	tree.op = c
	tree.left = &c[count]
	tree.right = &c[2 * count]
	tree.offset = &c[3 * count]
	tree.value = &c[4 * count]
	tree.result_type = &c[5 * count]
	tree.high = &c[6 * count]
	tree.next_arg = &c[7 * count]
	tree.in_cast = &c[8 * count]
	tree.binding_name = &c[9 * count]
	tree.binding_offset = &c[10 * count]
	tree.symbol = &c[11 * count]
	tree.qualified = &c[12 * count]
	tree.it_slot = &c[13 * count]
	tree.generic_parameters = &c[14 * count]
	tree.generic_signature = &c[15 * count]
	tree.generic_offset = &c[16 * count]
	tree.generic_instance = &c[17 * count]
	tree.generic_arity = &c[18 * count]
	tree.infer_coercion = &c[19 * count]
	tree.call_receiver_type = &c[20 * count]
	tree.infer_want = &c[21 * count]


# Lower a retained expression after its parser has returned. Symbol/type
# identities are still session-local: this is not a relocatable module IR.
# In particular, callers must preserve the environment for global calls
# and register allocation, and establish the intended emission location.
void retained_emit_view(expression_ast* tree, int id):
	retained_group* group = retained_record_at(id).group
	int* slots = tree.it_slot
	int scratch = 0
	# A semantic forest exposes it_slot in tree queries. Historically its
	# copy stayed unchanged while lowering wrote the temporary arena; keep
	# that property when a list callback allocates its hidden iterator slot.
	if (group.semantic != 0):
		for i in range(tree.count):
			if (tree.op[i] == ast_list_it): scratch = 1
	if (scratch):
		# Session ownership also covers a diagnostic's non-local recovery.
		tree.it_slot = cast(int*, retained_arena_alloc(tree.count * __word_size__))
		retained_copy_words(tree.it_slot, slots, tree.count)
	emit_expression_ast_root(tree, group.root)
	if (scratch): tree.it_slot = slots
	ast_retained_emitted = ast_retained_emitted + 1


int retained_emit_expression(int id):
	expression_ast tree
	retained_expression_view(&tree, id)
	int root = retained_record_at(id).group.root
	retained_emit_view(&tree, id)
	return tree.result_type[root]


# Compatibility adapter for callers that still keep their parse frame.
# Validate its copy, then lower through the independent retained view in
# both ordinary and semantic sessions. The one column the visitor writes
# (it_slot, a list iteration's hidden slot) is copied back for those callers.
int retained_emit_lower(expression_ast* tree, int id):
	int root = retained_emit_expression_group(tree, id)
	retained_group* group = retained_record_at(id).group
	retained_emit_expression(id)
	int count = group.count
	retained_copy_words(tree.it_slot, &group.columns[13 * count], count)
	return root


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
# Lifetime: the expression view is owned by the pooled walk and points into
# the retained group, never the parse arena. Grammar-created statement and
# control records live in the retained session arena, including their child
# records and copied names/bytes. Records, phases and points are pooled and
# released, last in first out, once walked. Parsing still drains phases that
# establish scope/stack/control state: owned storage alone does not make the
# analysis independent of emission.

void retained_expression_note(expression_ast* tree, int root);
void emit_expression_ast(expression_ast* tree, int id);
void emit_expression_ast_root(expression_ast* tree, int root);

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
	expression_ast* expression_view

# P1.2b: the pools are raw arrays (room entries each, grown by doubling):
# records by pointer, phase codes and points as words, and emission points
# inline, a tokenizer_snapshot each, with their token texts beside them.
retained_statement_walk** retained_walks
int retained_walks_used
int retained_walks_room
int* retained_walk_phase_codes
int* retained_walk_phase_points
int retained_walk_phases_used
int retained_walk_phases_room
tokenizer_snapshot* retained_emit_points
char** retained_emit_point_texts
int* retained_emit_point_sizes
int retained_emit_points_used
int retained_emit_points_room
# --stats: statements emitted by the walk rather than during their parse.
int ast_retained_statements_emitted


# A record that was walked, or whose statement node was retracted (an error
# rolled a REPL entry back mid-statement), no longer holds pool entries.
int retained_walk_stale(int id):
	retained_statement_walk* walk = retained_walks[id]
	if (walk.walked): return 1
	if (walk.node >= retained_node_count()): return 1
	return retained_record_at(walk.node).statement_walk != id


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
	retained_record* node = retained_record_at(retained_parent)
	if ((node.kind != retained_statement) || (node.statement_walk >= 0)): return -1
	retained_walk_release()
	int id = retained_walks_used
	if (id == retained_walks_room):
		int room = retained_walks_room * 2 + 16
		retained_walks = cast(retained_statement_walk**, realloc(cast(char*, retained_walks), retained_walks_room * __word_size__, room * __word_size__))
		for i in range(retained_walks_room, room):
			retained_statement_walk* fresh = new retained_statement_walk
			# The pinned seed predates zero-initialized `new`.
			fresh.expression_view = 0
			retained_walks[i] = fresh
		retained_walks_room = room
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


tokenizer_snapshot* retained_emit_point(int point):
	return cast(tokenizer_snapshot*, cast(char*, retained_emit_points) + point * sizeof(tokenizer_snapshot))


# 1 when the lexer is exactly at the recorded point.
int retained_emit_point_current(int point):
	tokenizer_snapshot* s = retained_emit_point(point)
	if ((s.token_serial != token_serial) || (s.byte_offset != byte_offset)): return 0
	if ((s.token_start_offset != token_start_offset) || (s.token_i != token_i)): return 0
	if ((s.file != file) || (s.filename != filename) || (s.nextc != nextc)): return 0
	if ((s.line_number != line_number) || (s.column_number != column_number)): return 0
	if ((s.diag_token_line != diag_token_line) || (s.diag_token_column != diag_token_column)): return 0
	if ((s.tab_level != tab_level) || (s.token_newline != token_newline)): return 0
	return strcmp(retained_emit_point_texts[point], token) == 0


int retained_emit_point_save():
	int id = retained_emit_points_used
	if (id == retained_emit_points_room):
		int room = retained_emit_points_room * 2 + 16
		int old = retained_emit_points_room
		retained_emit_points = cast(tokenizer_snapshot*, realloc(cast(char*, retained_emit_points), old * sizeof(tokenizer_snapshot), room * sizeof(tokenizer_snapshot)))
		retained_emit_point_texts = cast(char**, realloc(cast(char*, retained_emit_point_texts), old * __word_size__, room * __word_size__))
		retained_emit_point_sizes = cast(int*, realloc(cast(char*, retained_emit_point_sizes), old * __word_size__, room * __word_size__))
		for i in range(old, room):
			retained_emit_point_texts[i] = 0
			retained_emit_point_sizes[i] = 0
		retained_emit_points_room = room
	retained_emit_points_used = id + 1
	tokenizer_snapshot_save(retained_emit_point(id))
	char* from = token
	int length = strlen(from)
	char* text = retained_emit_point_texts[id]
	if (retained_emit_point_sizes[id] <= length):
		int size = (length + 16) << 1
		if (text != 0): free(text)
		text = cast(char*, malloc(size))
		retained_emit_point_texts[id] = text
		retained_emit_point_sizes[id] = size
	for i in range(length + 1): text[i] = from[i]
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
	if (k == retained_walk_phases_room):
		int room = retained_walk_phases_room * 2 + 64
		retained_walk_phase_codes = cast(int*, realloc(cast(char*, retained_walk_phase_codes), retained_walk_phases_room * __word_size__, room * __word_size__))
		retained_walk_phase_points = cast(int*, realloc(cast(char*, retained_walk_phase_points), retained_walk_phases_room * __word_size__, room * __word_size__))
		retained_walk_phases_room = room
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
	int group = retained_node_count()
	retained_expression_note(tree, root)
	assert1(retained_node_kind(group) == retained_expression_group)
	# Compare while the parser's temporary storage is still available, then
	# retain only the group's own view. Statement/header emitters install
	# this view on their value node before coercion and end diagnostics.
	retained_emit_expression_group(tree, group)
	if (walk.expression_view == 0): walk.expression_view = new expression_ast
	retained_expression_view(walk.expression_view, group)
	walk.tree = walk.expression_view
	walk.group = group
	walk.root = root


# Lower the walk's expression child without reading its former parse arena.
int retained_walk_lower_expression(retained_statement_walk* walk):
	# A guard's condition is in discard position (grammar/cond_branch.w);
	# the flag is read by the emission inside retained_emit_view (P1.2b).
	if (walk.statement != 0):
		if ((walk.statement.kind == ast_stmt_guard) && cond_branch_on()): ast_cond_discard = 1
	int root = retained_record_at(walk.group).group.root
	assert1(root == walk.root)
	retained_emit_view(walk.tree, walk.group)
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
type __emitter_callback = fn(retained_statement_walk*, int) -> void


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
			tokenizer_snapshot_restore(retained_emit_point(point), retained_emit_point_texts[point])
		walk.done = walk.done + 1
		# The family's emitter, held as an address like analysis_run's
		# operation (compiler/analysis.w).
		__emitter_callback* emitter = cast(__emitter_callback*, walk.emitter)
		emitter(walk, retained_walk_phase_codes[k])
	if (resume_text != 0):
		tokenizer_snapshot_restore(&resume, resume_text)
		free(resume_text)
	if ((resume_position >= 0) && (file == resume_file) && (retained_emit_source_position() != resume_position)):
		getchar_seek(file, resume_position)


# The walk's entry point: emit the retained statement node's remaining
# phases and release its record (and any walked records above it).
void retained_emit_statement(int node):
	int id = retained_record_at(node).statement_walk
	assert1(id >= 0)
	retained_walk_drain(id)
	retained_walks[id].walked = 1
	retained_record_at(node).statement_walk = -1
	ast_retained_statements_emitted = ast_retained_statements_emitted + 1
	retained_walk_release()


# --stats: statements the dispatcher entered, from the retained forest.
int retained_statement_count():
	int total = retained_node_count()
	int count = 0
	for i in range(total):
		if (retained_node_kind(i) == retained_statement): count = count + 1
	return count

# ---------------------------------------------------------------------------
# S2.3: generic instantiation and deferred statements from the retained
# forest instead of the source file.
#
# A generic definition and a deferred statement used to be re-read from the
# file: open the recorded path again, seek to the span's offset, re-lex.
# Under --ast-emit-retained, grammar/generic.w builds generic struct types,
# instantiation signatures and inference shapes by walking retained type
# trees under the instantiation's substitution, so no source is read at all.
# What still has to be re-parsed (a function body, whose meaning depends on
# the type arguments; a deferred statement, whose names bind at each exit;
# a header or field list the trees cannot express) is re-lexed from the
# retained source version: the bytes the tokenizer recorded while it first
# read the file (compiler/retained_ast.w, retained_source_byte). Every span
# has been read through, and so recorded, before it is instantiated.
#
# The lexer reads through getchar's per-descriptor window, so a re-parse
# gets a descriptor whose window is a private copy of the version's bytes,
# covering file offsets [0, length). Every absolute getchar_seek inside it
# (a diagnostic's context line, an expression preflight's rewind, a walk
# drain) stays in memory. A copy, because the expression preflight may
# compact or replace the window when it runs into the window's end
# (ast_expression_refill); after that, an earlier offset is no longer in
# memory and getchar re-reads it from the descriptor. So the descriptor is
# an empty stream (compiler/tokenizer.w's empty_stream_open: a closed
# pipe, /dev/null only as a fallback), which never has to supply
# anything, only when no preflight of
# the span can reach the window's end: a token the first read consumed
# follows the span (follow), or the span holds no expression. A body or
# deferred statement that ends its file gets the file itself, positioned at
# the end of the retained bytes so its offset agrees with the window: no
# byte of the span is read from it, but getchar can re-read the prefix after
# a compaction. A version that was replaced or rolled back falls back to the
# file re-parse.

# --stats: re-parses served from retained source bytes, and those whose
# descriptor is the source file positioned at the retained end.
int retained_source_reparses
int retained_source_end_positions
list[int] retained_window_fds
list[int] retained_window_buffers
# S2.5: 1 for a window on /dev/null, which already holds every byte its
# re-parse may read (see retained_window_complete).
list[int] retained_window_null


# 1 when grammar/generic.w may build types from retained trees: the mode is
# on and no -v trace (which prints every pointer-type lookup a re-parse
# makes) has to match the streaming compile's.
int retained_emit_generic_enabled():
	return ast_emit_retained_mode && (verbosity < 1)


# Offset of the first token after the line holding offset in the retained
# version source (comments and blank lines skipped), or -1 when none was
# read, or when a block comment opens on that line.
int retained_source_next_line_token(int source, int offset):
	if ((source < 0) || (source >= retained_sources.length)): return -1
	retained_source* record = retained_sources[source]
	char* bytes = record.bytes
	int length = record.length
	if ((bytes == 0) || (offset < 0)): return -1
	int i = offset
	while ((i < length) && (bytes[i] != 10)):
		if ((bytes[i] == '/') && (i + 1 < length) && (bytes[i + 1] == '*')): return -1
		i = i + 1
	while (i < length):
		int c = bytes[i] & 255
		if ((c == 10) || (c == 13) || (c == ' ') || (c == 9)):
			i = i + 1
		else if (c == '#'):
			while ((i < length) && (bytes[i] != 10)): i = i + 1
		else if ((c == '/') && (i + 1 < length) && (bytes[i + 1] == '*')):
			i = i + 2
			while ((i + 1 < length) && ((bytes[i] != '*') || (bytes[i + 1] != '/'))): i = i + 1
			if (i + 1 >= length): return -1
			i = i + 2
		else:
			return i
	return -1


# Prime the lexer at offset of the retained version source of path, as
# generic_reparse_start does with the file. follow is the offset of a token
# the first read consumed after the span, -1 when there is none, or -2 when
# the re-parse lexes no expression (a header or field list), so needs none.
# Returns 0, leaving the lexer untouched, when the version cannot serve the
# span.
int retained_source_reparse_begin(char* path, int source, int offset, int line, int column, int follow):
	if ((ast_emit_retained_mode == 0) || (source < 0)): return 0
	if (retained_source_find(path) != source): return 0
	retained_source* record = retained_sources[source]
	int length = record.length
	if ((record.bytes == 0) || (offset < 0) || (offset >= length)): return 0
	if (follow >= length): follow = -1
	int fd = -1
	if (follow != -1): fd = empty_stream_open()
	int null_window = fd >= 0
	if (fd < 0):
		# The span may end the file (or the host has no /dev/null): a
		# descriptor that can re-read the prefix, at the window's end.
		fd = open(path, 0, 511)
		if (fd < 0): return 0
		if (fd < GETCHAR_MAX_FD):
			getchar_reset(fd)
			getchar_seek(fd, length)
			retained_source_end_positions = retained_source_end_positions + 1
	if (fd >= GETCHAR_MAX_FD):
		close(fd)
		return 0
	if (retained_window_fds == 0):
		retained_window_fds = new list[int]
		retained_window_buffers = new list[int]
		retained_window_null = new list[int]
	retained_window_fds.push(fd)
	retained_window_buffers.push(getchar_buf_addr[fd])
	retained_window_null.push(null_window)
	# Room for one more read, as ast_expression_refill expects of a window.
	char* copy = cast(char*, malloc(length + GETCHAR_BUF_CAPACITY))
	char* bytes = record.bytes
	for i in range(length): copy[i] = bytes[i]
	getchar_buf_addr[fd] = cast(int, copy)
	getchar_limit[fd] = length
	getchar_kernel_pos[fd] = length
	getchar_pos[fd] = offset
	# A new stream on this fd (the register pre-scan's file image of a
	# previous use of the number must not serve it; lib/lib.w)
	getchar_generation[fd] = getchar_generation[fd] + 1
	file = fd
	filename = path
	byte_offset = offset
	line_number = line
	column_number = column
	tab_level = 0
	token_newline = 0
	nextc = 0
	nextc = get_character()
	get_token()
	retained_source_reparses = retained_source_reparses + 1
	return 1


# Give a window's descriptor back: free its buffer (the copy, or whatever
# replaced it) and restore the slot's own.
void retained_window_release(int top):
	int fd = retained_window_fds[top]
	free(cast(char*, getchar_buf_addr[fd]))
	getchar_buf_addr[fd] = retained_window_buffers[top]
	getchar_reset(fd)
	retained_window_fds.pop()
	retained_window_buffers.pop()
	retained_window_null.pop()


# S2.5: 1 when fd is the innermost retained window and reads /dev/null.
# Its window is the whole recorded version and a read adds nothing, so
# ast_expression_refill leaves it as it is instead of compacting it: a
# compacted window would lose the prefix that a diagnostic's context line
# (diag_context_collect) seeks back to, and /dev/null cannot re-read it.
int retained_window_complete(int fd):
	if (retained_window_fds == 0): return 0
	int top = retained_window_fds.length
	if ((top == 0) || (retained_window_fds[top - 1] != fd)): return 0
	return retained_window_null[top - 1]


# Close the descriptor a re-parse read from: a retained window gives its
# buffer slot back, a reopened source file is closed.
void retained_source_reparse_close(int fd):
	int top = 0
	if (retained_window_fds != 0): top = retained_window_fds.length
	if ((top > 0) && (retained_window_fds[top - 1] == fd)): retained_window_release(top - 1)
	empty_stream_forget(fd)
	close(fd)


# A compile starts with no window open. One can be left over only when an
# error unwound a REPL entry in the middle of a re-parse; give its buffer
# slot back so a later open() of that descriptor reads into its own buffer.
void retained_source_reparse_reset():
	if (retained_window_fds == 0): return
	while (retained_window_fds.length > 0): retained_window_release(retained_window_fds.length - 1)
