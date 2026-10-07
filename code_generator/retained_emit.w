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
	emit_expression_ast_root(walk.tree, root)
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
# /dev/null, which never has to supply anything, only when no preflight of
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
	if (follow != -1): fd = open(c"/dev/null", 0, 511)
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
	retained_window_fds.push(fd)
	retained_window_buffers.push(getchar_buf_addr[fd])
	# Room for one more read, as ast_expression_refill expects of a window.
	char* copy = malloc(length + GETCHAR_BUF_CAPACITY)
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


# Close the descriptor a re-parse read from: a retained window gives its
# buffer slot back, a reopened source file is closed.
void retained_source_reparse_close(int fd):
	int top = 0
	if (retained_window_fds != 0): top = retained_window_fds.length
	if ((top > 0) && (retained_window_fds[top - 1] == fd)): retained_window_release(top - 1)
	close(fd)


# A compile starts with no window open. One can be left over only when an
# error unwound a REPL entry in the middle of a re-parse; give its buffer
# slot back so a later open() of that descriptor reads into its own buffer.
void retained_source_reparse_reset():
	if (retained_window_fds == 0): return
	while (retained_window_fds.length > 0): retained_window_release(retained_window_fds.length - 1)
