# Transactional graphical edits splice source rather than canonicalizing it.
# Unrelated comments, Markdown fences, configuration and directives stay intact.
import libs.extras.mermaid.editor
import libs.extras.mermaid.serialize

const int MM_EDIT_LABEL = 1
const int MM_EDIT_NODE_DELETE = 2
const int MM_EDIT_EDGE_DELETE = 3

# Borrowed static text: an empty string means the selected operation is available.
char* mm_editor_edit_reason(mm_editor* e, int operation, int index):
	if (e == 0 || e.document.error != 0): return c"Fix source errors before editing the diagram."
	if (e.document.kind != MM_FLOW && e.document.kind != MM_ER): return c"Graphical editing is available for flowcharts and ER diagrams."
	if (operation == MM_EDIT_EDGE_DELETE):
		if (index < 0 || index >= e.document.edges.length): return c"Select a connection first."
	else:
		if (operation != MM_EDIT_LABEL && operation != MM_EDIT_NODE_DELETE): return c"Unknown edit command."
		if (index < 0 || index >= e.document.nodes.length): return c"Select a node first."
		if (e.document.nodes[index].group): return c"Edit groups in the source pane."
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

# Validate the intended semantic delta before recording a single history entry.
# In particular, deleting a declaration must never recreate its node through a
# style target, lose a surviving inline declaration, or retarget linkStyle indices.
int mm_edit_commit(mm_editor* e, char* source, int deleted_node, int deleted_edge, int label_node, char* label):
	mm_document* old = e.document
	mm_document* next = mm_parse_selected(source, strlen(source), e.selected)
	int ok = next.error == 0 && next.kind == old.kind
	int expected_nodes = old.nodes.length
	if (deleted_node >= 0): expected_nodes = expected_nodes - 1
	if (next.nodes.length != expected_nodes): ok = 0
	if (ok):
		for i in range(old.nodes.length):
			if (i == deleted_node): continue
			mm_node* n = old.nodes[i]
			int found = mm_find_node(next, n.id)
			if (found < 0):
				ok = 0
				break
			mm_node expected = *n
			if (i == label_node): expected.label = label
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

# Last declaration wins in Mermaid. Append only the changed label/shape, keeping
# the node identity, scope, original declarations and every comment untouched.
int mm_editor_set_label(mm_editor* e, int index, char* label):
	if (mm_editor_edit_reason(e, MM_EDIT_LABEL, index)[0] != 0 || mm_edit_text_safe(label) == 0): return 0
	if (strcmp(e.document.nodes[index].label, label) == 0): return 1
	mm_serializer out
	out.text = string_new()
	out.failed = 0
	mm_node node = *e.document.nodes[index]
	node.label = label
	mm_serialize_quote(&out, node.id)
	mm_serialize_shape(&out, &node)
	string_builder* source = string_new()
	string_append_bytes(source, e.document.source, e.document.source_end)
	if (source.length > 0 && source.data[source.length - 1] != 10): string_append_char(source, 10)
	string_append(source, out.text.data)
	string_append_char(source, 10)
	string_append_bytes(source, e.document.source + e.document.source_end, e.document.length - e.document.source_end)
	int ok = 0
	if (out.failed == 0): ok = mm_edit_commit(e, source.data, -1, -1, index, label)
	string_free(out.text)
	string_free(source)
	return ok

struct mm_edit_token:
	int start
	int end
	int node

struct mm_edit_scan:
	mm_parser parser
	mm_document* original
	string_builder* output
	int copied
	int node
	int edge
	int edge_index

void mm_edit_splice(mm_edit_scan* scan, int start, int end, char* replacement):
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
			if (scan.node >= 0 && mm_position_record(scan.original, start, p.pos, &x, &y) == scan.node): mm_edit_splice(scan, start, p.pos, c"")
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

int mm_editor_delete(mm_editor* e, int node, int edge):
	mm_edit_scan scan
	scan.original = e.document
	scan.output = string_new()
	scan.copied = 0
	scan.node = node
	scan.edge = edge
	scan.edge_index = 0
	mm_document* scratch = mm_document_new()
	free(scratch.source)
	scratch.source = strclone(e.document.source)
	scratch.length = e.document.source_end
	scratch.kind = e.document.kind
	mm_parser* p = &scan.parser
	p.doc = scratch
	p.pos = e.document.source_start
	p.scope = -1
	p.global_nodes = 0
	if (p.pos == 0 && scratch.length >= 3 && (scratch.source[0] & 255) == 239 && (scratch.source[1] & 255) == 187 && (scratch.source[2] & 255) == 191): p.pos = 3
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

int mm_editor_delete_node(mm_editor* e, int index):
	if (mm_editor_edit_reason(e, MM_EDIT_NODE_DELETE, index)[0] != 0): return 0
	return mm_editor_delete(e, index, -1)

int mm_editor_delete_edge(mm_editor* e, int index):
	if (mm_editor_edit_reason(e, MM_EDIT_EDGE_DELETE, index)[0] != 0): return 0
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

# Existing node identifiers may be quoted, Unicode or contain spaces. Serialize
# those identities instead of restricting connection creation to UI-generated IDs.
int mm_editor_connect(mm_editor* e, char* from_id, char* to_id):
	if (e.document.error != 0 || e.document.kind != MM_FLOW || from_id == 0 || to_id == 0): return 0
	int from_node = mm_find_node(e.document, from_id)
	int to_node = mm_find_node(e.document, to_id)
	if (from_node < 0 || to_node < 0): return 0
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
