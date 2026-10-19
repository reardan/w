# Transactional graphical edits splice source rather than canonicalizing it.
# Unrelated comments, Markdown fences, configuration and directives stay intact.
import libs.extras.mermaid.editor
import libs.extras.mermaid.serialize

const int MM_EDIT_LABEL = 1
const int MM_EDIT_NODE_DELETE = 2
const int MM_EDIT_EDGE_DELETE = 3

int mm_edit_uml(mm_document* d):
	return d.kind == MM_CLASS || d.kind == MM_STATE

# Lollipop interfaces get positional synthetic identities, so a structural
# deletion could silently rename an unrelated interface.
int mm_edit_has_interfaces(mm_document* d):
	if (d.kind != MM_CLASS): return 0
	for mm_node* n in d.nodes:
		if (n.shape == 28): return 1
	return 0

char* mm_edit_nested_reason(mm_document* d):
	if (d.kind == MM_CLASS): return c"Edit classes inside namespaces in the source pane."
	return c"Edit states inside composite states in the source pane."

# Borrowed static text: an empty string means the selected operation is available.
char* mm_editor_edit_reason(mm_editor* e, int operation, int index):
	if (e == 0 || e.document.error != 0): return c"Fix source errors before editing the diagram."
	mm_document* d = e.document
	if (mm_graph_edit_family(d.kind) == 0): return c"Graphical editing is available for flowcharts, ER, class and state diagrams."
	if (operation == MM_EDIT_EDGE_DELETE):
		if (index < 0 || index >= d.edges.length): return c"Select a connection first."
		if (mm_edit_uml(d)):
			mm_edge* edge = d.edges[index]
			if (d.nodes[edge.from_node].parent >= 0 || d.nodes[edge.to_node].parent >= 0): return mm_edit_nested_reason(d)
			if (mm_edit_has_interfaces(d)): return c"Edit lollipop interfaces in the source pane."
	else:
		if (operation != MM_EDIT_LABEL && operation != MM_EDIT_NODE_DELETE): return c"Unknown edit command."
		if (index < 0 || index >= d.nodes.length): return c"Select a node first."
		mm_node* n = d.nodes[index]
		if (n.group):
			if (d.kind == MM_CLASS): return c"Edit namespaces in the source pane."
			if (d.kind == MM_STATE): return c"Edit composite states in the source pane."
			return c"Edit groups in the source pane."
		if (mm_edit_uml(d) && n.parent >= 0): return mm_edit_nested_reason(d)
		if (n.shape == 28 && d.kind == MM_CLASS): return c"Edit lollipop interfaces in the source pane."
		if (operation == MM_EDIT_NODE_DELETE && mm_edit_has_interfaces(d)): return c"Edit lollipop interfaces in the source pane."
		if (operation == MM_EDIT_LABEL && d.kind == MM_STATE && n.shape != 1): return c"Start, end, choice, fork and join states have no editable label."
	return c""

int mm_edit_text_safe(char* text):
	if (text == 0): return 0
	for i in range(strlen(text)):
		int c = text[i] & 255
		if (c < 32 || c == '"'): return 0
	return utf8_validate_bytes(text, strlen(text))

int mm_edit_removed_edge(mm_document* d, int edge, int node, int selected_edge):
	if (edge == selected_edge): return 1
	if (node < 0): return 0
	return d.edges[edge].from_node == node || d.edges[edge].to_node == node

list[int] mm_edit_mask(int length, int value):
	list[int] mask = new list[int]
	for i in range(length): mask.push(value)
	return mask

# Validate the intended semantic delta before recording a single history entry.
# In particular, deleting a declaration must never recreate its node through a
# style target, lose a surviving inline declaration, or retarget linkStyle indices.
# removed[i] marks nodes the edit deletes (the selection plus, in state diagrams,
# start/end pseudo-states left without transitions). relaxed[i] marks class nodes
# whose only change may be becoming explicitly declared by a `class` statement.
int mm_edit_commit_masks(mm_editor* e, char* source, list[int] removed, int deleted_node, int deleted_edge, list[int] relaxed, int label_node, char* label):
	mm_document* old = e.document
	mm_document* next = mm_parse_selected(source, strlen(source), e.selected)
	int ok = next.error == 0 && next.kind == old.kind
	int expected_nodes = old.nodes.length
	for i in range(old.nodes.length):
		if (removed[i]): expected_nodes = expected_nodes - 1
	if (next.nodes.length != expected_nodes): ok = 0
	if (ok):
		for i in range(old.nodes.length):
			if (removed[i]): continue
			mm_node* n = old.nodes[i]
			int found = mm_serialize_find_equal(old, i, next)
			if (found < 0):
				ok = 0
				break
			mm_node expected = *n
			if (i == label_node): expected.label = label
			if (relaxed[i] && n.declared == 0): expected.declared = next.nodes[found].declared
			if (mm_serialize_node_equal(&expected, next.nodes[found]) == 0): ok = 0
			if (mm_serialize_reference_equal(old, n.parent, next, next.nodes[found].parent) == 0): ok = 0
	int edge = 0
	if (ok):
		for i in range(old.edges.length):
			if (mm_edit_removed_edge(old, i, deleted_node, deleted_edge)): continue
			if (edge >= next.edges.length):
				ok = 0
				break
			if (mm_serialize_edge_equal(old, old.edges[i], next, next.edges[edge]) == 0): ok = 0
			edge = edge + 1
	if (edge != next.edges.length): ok = 0
	# Notes follow their node; detached notes and notes on survivors are unchanged.
	int note = 0
	if (ok):
		for mm_note* a in old.notes:
			if (a.node >= 0 && removed[a.node]): continue
			if (note >= next.notes.length):
				ok = 0
				break
			mm_note* b = next.notes[note]
			if (a.side != b.side || mm_serialize_text_equal(a.text, b.text) == 0 || mm_serialize_reference_equal(old, a.node, next, b.node) == 0): ok = 0
			note = note + 1
	if (note != next.notes.length): ok = 0
	if (old.style_definitions.length != next.style_definitions.length): ok = 0
	if (ok):
		for i in range(old.style_definitions.length):
			mm_style_class* a = old.style_definitions[i]
			mm_style_class* b = next.style_definitions[i]
			if (strcmp(a.name, b.name) != 0 || mm_serialize_style_equal(&a.style, &b.style) == 0): ok = 0
	if (strcmp(old.direction, next.direction) != 0 || strcmp(old.title, next.title) != 0): ok = 0
	if (strcmp(old.accessibility_title, next.accessibility_title) != 0 || strcmp(old.accessibility_description, next.accessibility_description) != 0): ok = 0
	if (old.theme != next.theme || old.layout_algorithm != next.layout_algorithm || mm_serialize_style_equal(&old.edge_style, &next.edge_style) == 0): ok = 0
	mm_document_free(next)
	if (ok): return mm_editor_change(e, source)
	return 0

int mm_edit_commit(mm_editor* e, char* source, int deleted_node, int deleted_edge, int label_node, char* label):
	list[int] removed = mm_edit_mask(e.document.nodes.length, 0)
	if (deleted_node >= 0): removed[deleted_node] = 1
	list[int] relaxed = mm_edit_mask(e.document.nodes.length, 0)
	# A class rename is a `class Id["Label"]` declaration.
	if (label_node >= 0 && e.document.kind == MM_CLASS): relaxed[label_node] = 1
	int ok = mm_edit_commit_masks(e, source, removed, deleted_node, deleted_edge, relaxed, label_node, label)
	__w_list_free(cast(__w_list*, removed))
	__w_list_free(cast(__w_list*, relaxed))
	return ok

# Class and state identifiers are written plainly when the statement grammar
# reads them back unchanged, otherwise as backtick identifiers. Owned or null.
char* mm_edit_uml_id(char* id):
	if (id == 0 || id[0] == 0): return 0
	int plain = mm_in_words(id, c"|style|classDef|cssClass|click|note|link|callback|accTitle|accDescr|end|class|state|namespace|direction|as|linkStyle|") == 0
	for i in range(strlen(id)):
		int c = id[i] & 255
		if (c < 32 || c == '`'): return 0
		if (mm_id_char(c) == 0): plain = 0
	if (plain): return strclone(id)
	string_builder* text = string_from(c"`")
	string_append(text, id)
	string_append_char(text, '`')
	char* result = strclone(text.data)
	string_free(text)
	return result

# A state description is read to the end of its statement and trimmed.
int mm_edit_state_text_safe(char* text):
	int length = strlen(text)
	if (length == 0 || text[0] == 32 || text[0] == 9 || text[length - 1] == 32 || text[length - 1] == 9): return 0
	for i in range(length):
		if (text[i] == ';' || text[i] == '{' || text[i] == '}'): return 0
		if (text[i] == '%' && text[i + 1] == '%'): return 0
	return 1

# The statement that sets a node's label without touching its other state:
# flowchart/ER `"id"[label]`, class `class id["label"]`, state `id : label`.
char* mm_edit_label_statement(mm_document* d, mm_node* n, char* label):
	mm_serializer out
	out.text = string_new()
	out.failed = 0
	if (d.kind == MM_CLASS || d.kind == MM_STATE):
		char* id = mm_edit_uml_id(n.id)
		if (id == 0 || label[0] == 0): out.failed = 1
		else if (d.kind == MM_CLASS):
			string_append(out.text, c"class ")
			string_append(out.text, id)
			string_append_char(out.text, '[')
			mm_serialize_quote(&out, label)
			string_append_char(out.text, ']')
		else:
			if (mm_edit_state_text_safe(label) == 0): out.failed = 1
			string_append(out.text, id)
			string_append(out.text, c" : ")
			string_append(out.text, label)
		free(id)
	else:
		mm_node node = *n
		node.label = label
		mm_serialize_quote(&out, node.id)
		mm_serialize_shape(&out, &node)
	if (out.failed):
		string_free(out.text)
		return 0
	char* result = strclone(out.text.data)
	string_free(out.text)
	return result

# Last declaration wins in Mermaid. Append only the changed label/shape, keeping
# the node identity, scope, original declarations and every comment untouched.
int mm_editor_set_label(mm_editor* e, int index, char* label):
	if (mm_editor_edit_reason(e, MM_EDIT_LABEL, index)[0] != 0 || mm_edit_text_safe(label) == 0): return 0
	if (strcmp(e.document.nodes[index].label, label) == 0): return 1
	char* statement = mm_edit_label_statement(e.document, e.document.nodes[index], label)
	if (statement == 0): return 0
	string_builder* source = string_new()
	string_append_bytes(source, e.document.source, e.document.source_end)
	if (source.length > 0 && source.data[source.length - 1] != 10): string_append_char(source, 10)
	string_append(source, statement)
	string_append_char(source, 10)
	string_append_bytes(source, e.document.source + e.document.source_end, e.document.length - e.document.source_end)
	int ok = mm_edit_commit(e, source.data, -1, -1, index, label)
	free(statement)
	string_free(source)
	return ok

struct mm_edit_token:
	int start
	int end
	int node

struct mm_edit_piece:
	int start
	int end
	int line_start
	int line_end
	char* text
	list[int] refs
	int statement

struct mm_edit_scan:
	mm_parser parser
	mm_document* original
	string_builder* output
	int copied
	int node
	int edge
	int edge_index
	# Class/state scans record splices instead of writing output, so a second
	# pass can redeclare endpoints whose only statement was removed.
	list[mm_edit_piece*] pieces
	list[int] removed
	list[int] redeclare
	int failed

void mm_edit_splice(mm_edit_scan* scan, int start, int end, char* replacement):
	if (scan.pieces != 0):
		mm_edit_piece* piece = new mm_edit_piece()
		piece.start = start
		piece.end = end
		piece.line_start = start
		piece.line_end = end
		# A removal takes its whole line when nothing else shares that line.
		mm_document* d = scan.original
		int line_start = start
		while (line_start > d.source_start && (d.source[line_start - 1] == 32 || d.source[line_start - 1] == 9)): line_start = line_start - 1
		int line_end = end
		while (line_end < d.source_end && (d.source[line_end] == 32 || d.source[line_end] == 9 || d.source[line_end] == 13)): line_end = line_end + 1
		if ((line_start == d.source_start || d.source[line_start - 1] == 10) && line_end < d.source_end && d.source[line_end] == 10):
			piece.line_start = line_start
			piece.line_end = line_end + 1
		piece.text = strclone(replacement)
		piece.refs = new list[int]
		piece.statement = 0
		scan.pieces.push(piece)
		return
	string_append_bytes(scan.output, scan.original.source + scan.copied, start - scan.copied)
	string_append(scan.output, replacement)
	scan.copied = end

# Position comments belong to their node; remove valid generated records with
# that node while leaving ordinary comments and malformed metadata untouched.
void mm_edit_separators(mm_edit_scan* scan):
	mm_parser* p = &scan.parser
	while (1):
		mm_space(p)
		int start = p.pos
		if (mm_match(p, c"%%")):
			while (mm_peek(p) != 0 && mm_peek(p) != 10): p.pos = p.pos + 1
			int x = 0
			int y = 0
			int record = mm_position_record(scan.original, start, p.pos, &x, &y)
			int removed = record >= 0 && record == scan.node
			if (record >= 0 && scan.removed != 0 && scan.removed[record]): removed = 1
			if (removed): mm_edit_splice(scan, start, p.pos, c"")
		else if (mm_peek(p) == 10 || mm_peek(p) == ';'): p.pos = p.pos + 1
		else: return

int mm_edit_trim_end(mm_parser* p):
	int end = p.pos
	while (end > 0 && (p.doc.source[end - 1] == 32 || p.doc.source[end - 1] == 9 || p.doc.source[end - 1] == 13)): end = end - 1
	return end

mm_edit_token* mm_edit_node_token(mm_edit_scan* scan):
	mm_parser* p = &scan.parser
	mm_space(p)
	mm_edit_token* token = new mm_edit_token()
	token.start = p.pos
	int index = mm_node_parse(p)
	token.end = mm_edit_trim_end(p)
	token.node = -1
	if (index >= 0): token.node = mm_find_node(scan.original, p.doc.nodes[index].id)
	return token

# The accepted edge grammar is the parser's bounded flowchart / ER grammar.
void mm_edit_skip_connector(mm_parser* p):
	mm_space(p)
	if (p.doc.kind == MM_ER):
		mm_card(p, 1)
		mm_space(p)
		if (mm_match(p, c"..") == 0 && mm_keyword(p, c"optionally to") == 0 && mm_match(p, c"--") == 0): mm_keyword(p, c"to")
		mm_card(p, 0)
		return
	if (mm_match(p, c"-->") == 0 && mm_match(p, c"-.->") == 0 && mm_match(p, c"---") == 0):
		if (mm_match(p, c"--")):
			while (mm_end(p) == 0):
				if (mm_match(p, c"-->")): break
				p.pos = p.pos + 1
		else: mm_error(p.doc, p.pos, c"unsupported graphical connection")
	mm_space(p)
	if (mm_match(p, c"|")):
		char* label = mm_until(p, '|')
		free(label)

void mm_edit_graph_statement(mm_edit_scan* scan):
	mm_parser* p = &scan.parser
	int start = p.pos
	int first_edge = scan.edge_index
	list[mm_edit_token*] tokens = new list[mm_edit_token*]
	tokens.push(mm_edit_node_token(scan))
	mm_space(p)
	if (p.doc.kind == MM_ER && mm_match(p, c"{")):
		# Attributes have no graph references. The existing parser consumes quoted
		# comments and semicolon-separated fields without a second ad-hoc grammar.
		int scratch_index = mm_find_node(p.doc, scan.original.nodes[tokens[0].node].id)
		mm_attributes(p, scratch_index)
		tokens[0].end = p.pos
	else:
		while (mm_end(p) == 0 && p.doc.error == 0):
			mm_edit_skip_connector(p)
			tokens.push(mm_edit_node_token(scan))
			scan.edge_index = scan.edge_index + 1
			if (p.doc.kind == MM_ER):
				mm_space(p)
				mm_match(p, c":")
				mm_space(p)
				if (mm_peek(p) == '"'):
					char* label = mm_quoted(p)
					free(label)
				else:
					while (mm_end(p) == 0): p.pos = p.pos + 1
				break
	int end = mm_edit_trim_end(p)
	int changed = 0
	for mm_edit_token* token in tokens:
		if (token.node == scan.node): changed = 1
	for i in range(tokens.length - 1):
		if (first_edge + i == scan.edge): changed = 1
	if (changed && p.doc.error == 0):
		string_builder* replacement = string_new()
		int previous = -1
		for i in range(tokens.length):
			mm_edit_token* token = tokens[i]
			if (token.node == scan.node): continue
			if (previous >= 0):
				if (previous == i - 1 && first_edge + previous != scan.edge):
					mm_edit_token* before = tokens[previous]
					string_append_bytes(replacement, p.doc.source + before.end, token.start - before.end)
				else: string_append(replacement, c"; ")
			string_append_bytes(replacement, p.doc.source + token.start, token.end - token.start)
			previous = i
		# A retained ER relationship also retains its colon and label. All ER
		# statements touched by a deletion lose that relationship, leaving nodes.
		mm_edit_splice(scan, start, end, replacement.data)
		string_free(replacement)
	for mm_edit_token* token in tokens: free(token)
	__w_list_free(cast(__w_list*, tokens))

# Remove one target from comma-separated style/class directives, retaining every
# other target and the original style text. Edge indices follow surviving edges.
void mm_edit_directive(mm_edit_scan* scan, int kind, int start):
	mm_parser* p = &scan.parser
	mm_space(p)
	int targets_start = p.pos
	char* targets
	if (mm_peek(p) == '"'): targets = mm_quoted(p)
	else:
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 32 && mm_peek(p) != 9 && mm_peek(p) != ';'): p.pos = p.pos + 1
		targets = str_copy_range(p.doc.source, targets_start, p.pos)
	int targets_end = p.pos
	while (mm_end(p) == 0): p.pos = p.pos + 1
	int end = mm_edit_trim_end(p)
	string_builder* replacement = string_new()
	int changed = 0
	int at = 0
	for i in range(strlen(targets) + 1):
		if (targets[i] != ',' && targets[i] != 0): continue
		char* target = mm_style_trim(targets, at, i)
		int keep = 1
		int index = 0
		if (kind == 1):
			if (scan.node >= 0 && strcmp(target, scan.original.nodes[scan.node].id) == 0): keep = 0
		else if (strcmp(target, c"default") != 0):
			for j in range(strlen(target)): index = index * 10 + target[j] - '0'
			if (index < 0 || index >= scan.original.edges.length):
				mm_error(p.doc, targets_start, c"invalid graphical edge style index")
				keep = 0
			else:
				keep = mm_edit_removed_edge(scan.original, index, scan.node, scan.edge) == 0
				int shifted = index
				for j in range(index):
					if (mm_edit_removed_edge(scan.original, j, scan.node, scan.edge)): shifted = shifted - 1
				if (shifted != index): changed = 1
				index = shifted
		if (keep):
			if (replacement.length > 0): string_append_char(replacement, ',')
			if (kind == 2 && strcmp(target, c"default") != 0): string_append_int(replacement, index)
			else: string_append(replacement, target)
		else: changed = 1
		free(target)
		at = i + 1
	if (changed):
		if (replacement.length == 0): mm_edit_splice(scan, start, end, c"")
		else: mm_edit_splice(scan, targets_start, targets_end, replacement.data)
	string_free(replacement)
	free(targets)

# A private reparse of the selected diagram in whole-envelope coordinates.
# Statements parse into it exactly as they did into the original document.
mm_document* mm_edit_scratch(mm_edit_scan* scan, mm_document* d):
	mm_document* scratch = mm_document_new()
	free(scratch.source)
	scratch.source = strclone(d.source)
	scratch.length = d.source_end
	scratch.kind = d.kind
	mm_parser* p = &scan.parser
	p.doc = scratch
	p.pos = d.source_start
	p.scope = -1
	p.global_nodes = 0
	if (p.pos == 0 && scratch.length >= 3 && (scratch.source[0] & 255) == 239 && (scratch.source[1] & 255) == 187 && (scratch.source[2] & 255) == 191): p.pos = 3
	return scratch

int mm_editor_delete(mm_editor* e, int node, int edge):
	mm_edit_scan scan
	scan.original = e.document
	scan.output = string_new()
	scan.copied = 0
	scan.node = node
	scan.edge = edge
	scan.edge_index = 0
	scan.pieces = 0
	scan.removed = 0
	scan.redeclare = 0
	scan.failed = 0
	mm_document* scratch = mm_edit_scratch(&scan, e.document)
	mm_parser* p = &scan.parser
	mm_edit_separators(&scan)
	char* header = mm_identifier(p)
	free(header)
	if (scratch.kind == MM_FLOW): mm_direction(p)
	mm_edit_separators(&scan)
	while (mm_peek(p) != 0 && scratch.error == 0):
		int start = p.pos
		if (mm_metadata(p)): mm_space(p)
		else if (mm_style_keyword(p, c"style") || mm_style_keyword(p, c"class") || mm_style_keyword(p, c"cssClass")): mm_edit_directive(&scan, 1, start)
		else if (mm_style_keyword(p, c"linkStyle")): mm_edit_directive(&scan, 2, start)
		else if (mm_keyword(p, c"subgraph")):
			char* id = mm_identifier(p)
			free(id)
			mm_space(p)
			if (mm_match(p, c"[")):
				char* label = mm_until(p, ']')
				free(label)
			else:
				while (mm_end(p) == 0): p.pos = p.pos + 1
		else if (mm_keyword(p, c"classDef") || mm_keyword(p, c"end") || mm_keyword(p, c"direction")):
			# A valid original document already checked nesting. Group declarations
			# are preserved; graph tokens use original identity rather than indices.
			while (mm_end(p) == 0): p.pos = p.pos + 1
		else: mm_edit_graph_statement(&scan)
		if (p.pos <= start): mm_error(scratch, start, c"cannot locate graphical statement")
		mm_edit_separators(&scan)
	string_append_bytes(scan.output, e.document.source + scan.copied, e.document.length - scan.copied)
	int ok = 0
	if (scratch.error == 0 && scan.edge_index == e.document.edges.length): ok = mm_edit_commit(e, scan.output.data, node, edge, -1, c"")
	mm_document_free(scratch)
	string_free(scan.output)
	return ok

# The statement's subject: the declared or first-named class/state, -2 for a
# namespace. Lookahead only creates a node the statement itself would create.
int mm_edit_uml_subject(mm_parser* p):
	int save = p.pos
	if (p.doc.kind == MM_CLASS):
		if (mm_keyword(p, c"namespace")):
			p.pos = save
			return -2
		if (mm_match(p, c"<<")):
			char* annotation = mm_annotation(p)
			free(annotation)
		else: mm_keyword(p, c"class")
	else if (mm_keyword(p, c"state")):
		mm_space(p)
		if (mm_peek(p) == '"'):
			char* label = mm_quoted(p)
			free(label)
			mm_space(p)
			mm_keyword(p, c"as")
	int index = mm_uml_node(p, -1, 0)
	p.pos = save
	return index

void mm_edit_uml_ref(mm_edit_scan* scan, list[int] refs, int scratch_index):
	if (scratch_index < 0):
		scan.failed = 1
		return
	int index = mm_find_node(scan.original, scan.parser.doc.nodes[scratch_index].id)
	if (index < 0): scan.failed = 1
	refs.push(index)

# Each top-level class/state statement names at most one relationship, so a
# deletion removes whole statements. Composite states and namespaces are opaque:
# touching their bodies fails rather than rewriting nested scopes.
void mm_edit_uml_statement(mm_edit_scan* scan, int start):
	mm_parser* p = &scan.parser
	mm_document* scratch = p.doc
	mm_document* d = scan.original
	list[int] refs = new list[int]
	int edges = scratch.edges.length
	int notes = scratch.notes.length
	int group = 0
	if (mm_keyword(p, c"note")): mm_uml_note(p, -1)
	else:
		int subject = mm_edit_uml_subject(p)
		int was_group = 0
		if (subject >= 0): was_group = scratch.nodes[subject].group
		if (scratch.kind == MM_CLASS): mm_class_statement(p, -1, 0)
		else: mm_state_statement(p, -1, 0)
		if (scratch.error != 0):
			__w_list_free(cast(__w_list*, refs))
			return
		if (subject == -2): group = 1
		else:
			if (subject >= 0 && was_group == 0 && scratch.nodes[subject].group): group = 1
			mm_edit_uml_ref(scan, refs, subject)
	int hit = 0
	for i in range(edges, scratch.edges.length):
		if (i >= d.edges.length):
			scan.failed = 1
			break
		mm_edge* edge = scratch.edges[i]
		mm_edit_uml_ref(scan, refs, edge.from_node)
		mm_edit_uml_ref(scan, refs, edge.to_node)
		if (mm_edit_removed_edge(d, i, scan.node, scan.edge)): hit = 1
	for i in range(notes, scratch.notes.length):
		mm_note* note = scratch.notes[i]
		if (note.node >= 0): mm_edit_uml_ref(scan, refs, note.node)
	for int r in refs:
		if (r >= 0 && r == scan.node): hit = 1
	if (hit && scan.failed == 0):
		if (group): scan.failed = 1
		else:
			int end = mm_edit_trim_end(p)
			mm_edit_splice(scan, start, end, c"")
			mm_edit_piece* piece = scan.pieces[scan.pieces.length - 1]
			__w_list_free(cast(__w_list*, piece.refs))
			piece.refs = refs
			refs = 0
			piece.statement = 1
	if (refs != 0): __w_list_free(cast(__w_list*, refs))

void mm_edit_scan_free(mm_edit_scan* scan):
	for mm_edit_piece* piece in scan.pieces:
		free(piece.text)
		__w_list_free(cast(__w_list*, piece.refs))
		free(piece)
	__w_list_free(cast(__w_list*, scan.pieces))
	free(scan)

mm_edit_scan* mm_edit_uml_pass(mm_editor* e, int node, int edge, list[int] removed, list[int] redeclare):
	mm_edit_scan* scan = new mm_edit_scan()
	scan.original = e.document
	scan.output = 0
	scan.copied = 0
	scan.node = node
	scan.edge = edge
	scan.edge_index = 0
	scan.pieces = new list[mm_edit_piece*]
	scan.removed = removed
	scan.redeclare = redeclare
	scan.failed = 0
	mm_document* scratch = mm_edit_scratch(scan, e.document)
	mm_parser* p = &scan.parser
	mm_edit_separators(scan)
	char* header = mm_identifier(p)
	free(header)
	if (scratch.kind == MM_STATE): mm_match(p, c"-v2")
	mm_edit_separators(scan)
	while (mm_peek(p) != 0 && scratch.error == 0 && scan.failed == 0):
		int start = p.pos
		if (mm_metadata(p)): mm_space(p)
		else if (mm_style_keyword(p, c"linkStyle")): mm_edit_directive(scan, 2, start)
		else if (mm_style_keyword(p, c"style") || mm_style_keyword(p, c"cssClass") || (scratch.kind == MM_STATE && mm_style_keyword(p, c"class"))): mm_edit_directive(scan, 1, start)
		else if (mm_style_keyword(p, c"classDef")):
			while (mm_end(p) == 0): p.pos = p.pos + 1
		else if (mm_keyword(p, c"direction")): mm_direction(p)
		else: mm_edit_uml_statement(scan, start)
		if (p.pos <= start): mm_error(scratch, start, c"cannot locate graphical statement")
		mm_edit_separators(scan)
	if (scratch.error != 0 || scratch.edges.length != e.document.edges.length): scan.failed = 1
	mm_document_free(scratch)
	return scan

# A node kept only by a removed relationship is redeclared where it was named.
# Generic parameters are the only label such a reference can have set.
char* mm_edit_uml_declaration(mm_document* d, int index):
	mm_node* n = d.nodes[index]
	char* id = mm_edit_uml_id(n.id)
	if (id == 0): return 0
	string_builder* text = string_new()
	int ok = 1
	if (d.kind == MM_CLASS):
		string_append(text, c"class ")
		string_append(text, id)
		int length = strlen(n.id)
		int label_length = strlen(n.label)
		if (strcmp(n.label, n.id) != 0):
			if (label_length <= length + 1 || n.label[length] != '<' || n.label[label_length - 1] != '>'): ok = 0
			for i in range(length):
				if (ok && n.label[i] != n.id[i]): ok = 0
			if (ok):
				for i in range(length, label_length):
					int c = n.label[i]
					if (c == '<' || c == '>'): c = '~'
					string_append_char(text, c)
	else:
		if (n.shape != 1 || strcmp(n.label, n.id) != 0): ok = 0
		string_append(text, id)
	free(id)
	char* result = 0
	if (ok): result = strclone(text.data)
	string_free(text)
	return result

string_builder* mm_edit_assemble(mm_edit_scan* scan):
	mm_document* d = scan.original
	string_builder* out = string_new()
	int copied = 0
	for mm_edit_piece* piece in scan.pieces:
		int start = piece.start
		int end = piece.end
		string_builder* text = string_from(piece.text)
		if (piece.statement):
			for i in range(d.nodes.length):
				if (scan.redeclare[i] != piece.start): continue
				char* declaration = mm_edit_uml_declaration(d, i)
				if (declaration == 0): scan.failed = 1
				else:
					if (text.length > 0): string_append(text, c"; ")
					string_append(text, declaration)
					free(declaration)
		if (text.length == 0):
			start = piece.line_start
			end = piece.line_end
		if (start < copied): scan.failed = 1
		else:
			string_append_bytes(out, d.source + copied, start - copied)
			string_append(out, text.data)
			copied = end
		string_free(text)
	string_append_bytes(out, d.source + copied, d.length - copied)
	return out

# Class/state deletion: remove the statements naming the selection, then
# redeclare survivors that only those statements introduced. Start/end
# pseudo-states left without a transition are removed with them.
int mm_editor_delete_uml(mm_editor* e, int node, int edge):
	mm_document* d = e.document
	list[int] removed = mm_edit_mask(d.nodes.length, 0)
	if (node >= 0): removed[node] = 1
	list[int] redeclare = mm_edit_mask(d.nodes.length, -1)
	mm_edit_scan* scan = mm_edit_uml_pass(e, node, edge, removed, redeclare)
	string_builder* source = 0
	if (scan.failed == 0): source = mm_edit_assemble(scan)
	int ok = scan.failed == 0
	int again = 0
	if (ok):
		mm_document* next = mm_parse_selected(source.data, source.length, e.selected)
		if (next.error != 0): ok = 0
		for i in range(d.nodes.length):
			if (ok == 0 || removed[i]): continue
			# A survivor first named by a removed statement could otherwise be
			# recreated later inside a composite or namespace body.
			int found = mm_serialize_find_equal(d, i, next)
			if (found >= 0 && mm_serialize_reference_equal(d, d.nodes[i].parent, next, next.nodes[found].parent)): continue
			again = 1
			mm_node* n = d.nodes[i]
			if (d.kind == MM_STATE && (n.shape == 4 || n.shape == 5)): removed[i] = 1
			else:
				for mm_edit_piece* piece in scan.pieces:
					if (piece.statement == 0 || redeclare[i] >= 0): continue
					for int r in piece.refs:
						if (r == i): redeclare[i] = piece.start
				if (redeclare[i] < 0): ok = 0
		mm_document_free(next)
	if (ok && again):
		mm_edit_scan_free(scan)
		string_free(source)
		source = 0
		scan = mm_edit_uml_pass(e, node, edge, removed, redeclare)
		if (scan.failed == 0): source = mm_edit_assemble(scan)
		if (scan.failed): ok = 0
	list[int] relaxed = mm_edit_mask(d.nodes.length, 0)
	if (d.kind == MM_CLASS):
		for i in range(d.nodes.length): relaxed[i] = redeclare[i] >= 0
	mm_edit_scan_free(scan)
	if (ok): ok = mm_edit_commit_masks(e, source.data, removed, node, edge, relaxed, -1, c"")
	if (source != 0): string_free(source)
	__w_list_free(cast(__w_list*, removed))
	__w_list_free(cast(__w_list*, redeclare))
	__w_list_free(cast(__w_list*, relaxed))
	return ok

int mm_editor_delete_node(mm_editor* e, int index):
	if (mm_editor_edit_reason(e, MM_EDIT_NODE_DELETE, index)[0] != 0): return 0
	if (mm_edit_uml(e.document)): return mm_editor_delete_uml(e, index, -1)
	return mm_editor_delete(e, index, -1)

int mm_editor_delete_edge(mm_editor* e, int index):
	if (mm_editor_edit_reason(e, MM_EDIT_EDGE_DELETE, index)[0] != 0): return 0
	if (mm_edit_uml(e.document)): return mm_editor_delete_uml(e, -1, index)
	return mm_editor_delete(e, -1, index)

int mm_editor_add_entity(mm_editor* e, char* id, char* label):
	if (e.document.kind != MM_ER || mm_editor_identifier(id) == 0 || mm_edit_text_safe(label) == 0): return 0
	if (mm_find_node(e.document, id) >= 0): return 0
	mm_serializer out
	out.text = string_from(id)
	out.failed = 0
	string_append_char(out.text, '[')
	mm_serialize_quote(&out, label)
	string_append_char(out.text, ']')
	int ok = mm_editor_append(e, out.text.data)
	string_free(out.text)
	return ok

int mm_editor_add_relationship(mm_editor* e, char* from_id, char* to_id, char* label, int left_card, int right_card, int dashed):
	if (e.document.kind != MM_ER || mm_edit_text_safe(label) == 0 || label[0] == 0): return 0
	int from_node = mm_find_node(e.document, from_id)
	int to_node = mm_find_node(e.document, to_id)
	if (from_node < 0 || to_node < 0 || left_card < 0 || left_card > 3 || right_card < 0 || right_card > 3): return 0
	mm_edge* edge = new mm_edge()
	edge.from_node = from_node
	edge.to_node = to_node
	edge.label = label
	edge.left_card = left_card
	edge.right_card = right_card
	edge.dashed = dashed != 0
	edge.from_port = 0
	edge.to_port = 0
	edge.left_marker = 0
	edge.right_marker = 0
	mm_serializer out
	out.text = string_new()
	out.failed = 0
	out.edges = e.document.edges.length
	mm_serialize_edge(&out, e.document, edge)
	int ok = 0
	if (out.failed == 0): ok = mm_editor_append(e, out.text.data)
	free(edge)
	string_free(out.text)
	return ok

int mm_editor_connect_uml(mm_editor* e, int from_node, int to_node);

# Existing node identifiers may be quoted, Unicode or contain spaces. Serialize
# those identities instead of restricting connection creation to UI-generated IDs.
int mm_editor_connect(mm_editor* e, char* from_id, char* to_id):
	if (e.document.error != 0 || from_id == 0 || to_id == 0): return 0
	if (e.document.kind != MM_FLOW && mm_edit_uml(e.document) == 0): return 0
	int from_node = mm_find_node(e.document, from_id)
	int to_node = mm_find_node(e.document, to_id)
	if (from_node < 0 || to_node < 0): return 0
	if (mm_edit_uml(e.document)): return mm_editor_connect_uml(e, from_node, to_node)
	mm_edge* edge = new mm_edge()
	edge.from_node = from_node
	edge.to_node = to_node
	edge.arrow = 1
	edge.label = c""
	mm_serializer out
	out.text = string_new()
	out.failed = 0
	out.edges = e.document.edges.length
	mm_serialize_edge(&out, e.document, edge)
	int ok = 0
	if (out.failed == 0): ok = mm_editor_append(e, out.text.data)
	free(edge)
	string_free(out.text)
	return ok

# Class/state insertions are validated like deletions: every existing node,
# edge and note survives unchanged and exactly the requested items are added.
int mm_edit_append_checked(mm_editor* e, char* statement, int added_nodes, int from_node, int to_node):
	mm_document* old = e.document
	if (old.error != 0 || statement == 0): return 0
	string_builder* source = string_new()
	string_append_bytes(source, old.source, old.source_end)
	if (source.length > 0 && source.data[source.length - 1] != 10): string_append_char(source, 10)
	string_append(source, statement)
	string_append_char(source, 10)
	string_append_bytes(source, old.source + old.source_end, old.length - old.source_end)
	mm_document* next = mm_parse_selected(source.data, source.length, e.selected)
	int added_edges = from_node >= 0
	int ok = next.error == 0 && next.kind == old.kind && next.nodes.length == old.nodes.length + added_nodes && next.edges.length == old.edges.length + added_edges && next.notes.length == old.notes.length
	if (ok):
		for i in range(old.nodes.length):
			mm_node* n = old.nodes[i]
			int found = mm_serialize_find_equal(old, i, next)
			if (found < 0 || mm_serialize_node_equal(n, next.nodes[found]) == 0 || mm_serialize_reference_equal(old, n.parent, next, next.nodes[found].parent) == 0): ok = 0
	if (ok):
		for i in range(old.edges.length):
			if (mm_serialize_edge_equal(old, old.edges[i], next, next.edges[i]) == 0): ok = 0
	if (ok && added_edges):
		mm_edge* edge = next.edges[old.edges.length]
		if (mm_serialize_reference_equal(old, from_node, next, edge.from_node) == 0 || mm_serialize_reference_equal(old, to_node, next, edge.to_node) == 0): ok = 0
	mm_document_free(next)
	if (ok): ok = mm_editor_change(e, source.data)
	string_free(source)
	return ok

# `class Id["Label"]` or a state `Id : Label`; the label may be left empty.
int mm_editor_add_uml_node(mm_editor* e, char* id, char* label):
	if (e.document.error != 0 || mm_edit_uml(e.document) == 0 || mm_editor_identifier(id) == 0 || mm_edit_text_safe(label) == 0): return 0
	if (mm_find_node(e.document, id) >= 0): return 0
	char* name = mm_edit_uml_id(id)
	if (name == 0): return 0
	string_builder* statement = string_new()
	if (e.document.kind == MM_CLASS): string_append(statement, c"class ")
	string_append(statement, name)
	free(name)
	int ok = 1
	if (label[0] != 0 && strcmp(label, id) != 0):
		if (e.document.kind == MM_CLASS):
			string_append(statement, c"[\"")
			string_append(statement, label)
			string_append(statement, c"\"]")
		else:
			ok = mm_edit_state_text_safe(label)
			string_append(statement, c" : ")
			string_append(statement, label)
	if (ok): ok = mm_edit_append_checked(e, statement.data, 1, -1, -1)
	string_free(statement)
	return ok

# Start states only begin and end states only finish a top-level transition.
# Namespaces and lollipop interfaces are not class endpoints.
char* mm_edit_uml_endpoint(mm_document* d, int index, int target):
	mm_node* n = d.nodes[index]
	if (d.kind == MM_STATE && (n.shape == 4 || n.shape == 5)):
		if (n.parent >= 0 || (n.shape == 5) != (target != 0)): return 0
		return strclone(c"[*]")
	if (d.kind == MM_CLASS && (n.group || n.shape == 28)): return 0
	return mm_edit_uml_id(n.id)

# Class association `A --> B` or state transition `A --> B`.
int mm_editor_connect_uml(mm_editor* e, int from_node, int to_node):
	char* from = mm_edit_uml_endpoint(e.document, from_node, 0)
	char* to = mm_edit_uml_endpoint(e.document, to_node, 1)
	int ok = 0
	if (from != 0 && to != 0):
		string_builder* statement = string_from(from)
		string_append(statement, c" --> ")
		string_append(statement, to)
		ok = mm_edit_append_checked(e, statement.data, 0, from_node, to_node)
		string_free(statement)
	free(from)
	free(to)
	return ok

# The canvas Add command for every graphically editable family.
int mm_editor_add_graph_node(mm_editor* e, char* id, char* label):
	if (e.document.kind == MM_ER): return mm_editor_add_entity(e, id, label)
	if (e.document.kind == MM_FLOW): return mm_editor_add_node(e, id, label)
	return mm_editor_add_uml_node(e, id, label)
