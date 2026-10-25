# Family-independent graphical edits as validated source splices.
#
# Every command builds candidate sources that change only a few byte ranges
# of the selected diagram (lossless: comments, fences, frontmatter and
# formatting elsewhere are untouched), reparses each candidate and accepts
# the first whose semantic delta is exactly the expected one (mm_expect).
# An accepted candidate is one undo step; nothing else enters history.
import libs.extras.mermaid.editor
import libs.extras.mermaid.serialize

# Reparses one command may spend before it gives up.
const int MM_EE_ATTEMPTS = 160
const int MM_EE_SAME = -2

list[int] mm_ee_operator_spans(mm_document* d, int start, int end);

# ---------------------------------------------------------------- scanning

int mm_ee_in_comment(mm_document* d, int offset):
	if (d.comment_ranges == 0): return 0
	int low = 0
	int high = d.comment_ranges.length / 2
	while (low < high):
		int mid = low + (high - low) / 2
		if (d.comment_ranges[mid * 2] <= offset): low = mid + 1
		else: high = mid
	if (low == 0): return 0
	return offset < d.comment_ranges[(low - 1) * 2 + 1]

int mm_ee_space(int c):
	return c == 32 || c == 9 || c == 13

int mm_ee_line_end(mm_document* d, int at):
	while (at < d.source_end && d.source[at] != 10): at = at + 1
	return at

# The end of a line's code: before a trailing comment and trailing spaces.
int mm_ee_code_end(mm_document* d, int start, int end):
	int at = start
	int quoted = 0
	while (at < end):
		int c = d.source[at]
		if (c == '"'): quoted = quoted == 0
		if (quoted == 0 && c == '%' && at + 1 < end && d.source[at + 1] == '%' && mm_ee_in_comment(d, at)): break
		at = at + 1
	while (at > start && mm_ee_space(d.source[at - 1])): at = at - 1
	return at

# One source statement: a code line, or a block from its opener line to the
# matching closer line (`{` ... `}` or `subgraph` ... `end`).
struct mm_ee_unit:
	int start
	int code
	int code_end
	int end
	int opener
	int closer
	int parent
	int header

struct mm_ee_scan:
	mm_document* d
	list[mm_ee_unit*] units

int mm_ee_word_is(mm_document* d, int at, int end, char* word):
	int length = strlen(word)
	if (end - at < length): return 0
	for i in range(length):
		if (d.source[at + i] != word[i]): return 0
	if (at + length < end && mm_id_char(d.source[at + length] & 255)): return 0
	return 1

# 1 brace opener, 2 keyword opener (closed by `end`), 0 otherwise.
int mm_ee_opener(mm_document* d, int code, int code_end):
	if (code_end <= code): return 0
	if (d.source[code_end - 1] == '{'): return 1
	if (mm_ee_word_is(d, code, code_end, c"subgraph") || mm_ee_word_is(d, code, code_end, c"systemBoundary")): return 2
	# Agentflow containers: `flow id[label] ... end`.
	if (d.kind == MM_AGENT && mm_ee_word_is(d, code, code_end, c"flow")): return 2
	if (d.kind == MM_BLOCK && (mm_ee_word_is(d, code, code_end, c"block") || (code_end - code > 6 && mm_ee_word_is(d, code, code + 5, c"block") && d.source[code + 5] == ':'))): return 2
	return 0

int mm_ee_closer(mm_document* d, int code, int code_end, int kind):
	if (code_end <= code): return 0
	if (kind == 1): return d.source[code] == '}'
	return code_end - code == 3 && mm_ee_word_is(d, code, code_end, c"end")

mm_ee_scan* mm_ee_scan_new(mm_document* d):
	mm_ee_scan* scan = new mm_ee_scan()
	scan.d = d
	scan.units = new list[mm_ee_unit*]
	list[int] stack = new list[int]
	int at = d.source_start
	int first = 1
	while (at < d.source_end):
		int end = mm_ee_line_end(d, at)
		int next = end
		if (next < d.source_end): next = next + 1
		int code = at
		while (code < end && mm_ee_space(d.source[code])): code = code + 1
		int code_end = mm_ee_code_end(d, code, end)
		if (code_end <= code || mm_ee_in_comment(d, code)):
			at = next
			continue
		if (stack.length > 0):
			mm_ee_unit* open = scan.units[stack[stack.length - 1]]
			if (mm_ee_closer(d, code, code_end, open.opener)):
				open.closer = at
				open.end = next
				stack.pop()
				at = next
				continue
		mm_ee_unit* unit = new mm_ee_unit()
		unit.start = at
		unit.code = code
		unit.code_end = code_end
		unit.end = next
		unit.closer = -1
		unit.header = first
		unit.parent = -1
		if (stack.length > 0): unit.parent = stack[stack.length - 1]
		first = 0
		if (unit.header == 0): unit.opener = mm_ee_opener(d, code, code_end)
		scan.units.push(unit)
		if (unit.opener): stack.push(scan.units.length - 1)
		at = next
	# Unclosed blocks keep their header line only.
	__w_list_free(cast(__w_list*, stack))
	return scan

void mm_ee_scan_free(mm_ee_scan* scan):
	for mm_ee_unit* unit in scan.units: free(unit)
	__w_list_free(cast(__w_list*, scan.units))
	free(scan)

# Whole-token occurrences of id in [start, end), outside quoted strings,
# `[...]` labels, `|...|` link labels and comments. Returns the first offset
# at or after `from`, or -1.
int mm_ee_token(mm_document* d, int start, int end, char* id, int from):
	int length = strlen(id)
	if (length == 0): return -1
	int at = start
	int quoted = 0
	int bracket = 0
	int bar = 0
	while (at < end):
		int c = d.source[at] & 255
		if (c == '"'):
			quoted = quoted == 0
			at = at + 1
			continue
		if (quoted):
			at = at + 1
			continue
		if (c == '%' && at + 1 < end && d.source[at + 1] == '%' && mm_ee_in_comment(d, at)): return -1
		# Architecture `(icon)` names are not references either.
		if (c == '[' || (c == '(' && d.kind == MM_ARCHITECTURE)): bracket = bracket + 1
		else if ((c == ']' || (c == ')' && d.kind == MM_ARCHITECTURE)) && bracket > 0): bracket = bracket - 1
		else if (c == '|' && (d.kind == MM_FLOW || d.kind == MM_AGENT) && bracket == 0): bar = bar == 0
		if (bracket == 0 && bar == 0 && at >= from && at + length <= end):
			int match = 1
			for i in range(length):
				if (d.source[at + i] != id[i]): match = 0
			if (match && at > start && mm_id_char(d.source[at - 1] & 255)): match = 0
			if (match && at + length < end && mm_id_char(d.source[at + length] & 255)): match = 0
			if (match): return at
		at = at + 1
	return -1

# The text span a unit owns for mentions: a block's header line, else the line.
int mm_ee_mentions(mm_document* d, mm_ee_unit* unit, char* id):
	return mm_ee_token(d, unit.code, unit.code_end, id, unit.code) >= 0

# Node ids mentioned by the unit other than `self` (-1 for none).
int mm_ee_other_mention(mm_document* d, mm_ee_unit* unit, int self):
	for i in range(d.nodes.length):
		if (i == self): continue
		mm_node* n = d.nodes[i]
		if (n.id[0] == '@' || index_of(n.id, c"@") >= 0): continue
		if (mm_ee_mentions(d, unit, n.id)): return i
	return -1

# The node a statement names first (its subject), or -1.
int mm_ee_unit_subject(mm_document* d, mm_ee_unit* unit):
	int best = -1
	int best_at = unit.code_end
	for i in range(d.nodes.length):
		char* id = d.nodes[i].id
		if (mm_position_identity(id) == 0): continue
		int at = mm_ee_token(d, unit.code, unit.code_end, id, unit.code)
		if (at >= 0 && at < best_at):
			best = i
			best_at = at
	return best

# The unit that opens group index's block (its header names the group).
int mm_ee_group_unit(mm_ee_scan* scan, int index):
	mm_document* d = scan.d
	char* id = d.nodes[index].id
	# Class namespaces are keyed by their dotted path; headers name the last part.
	char* name = id
	int dot = -1
	for i in range(strlen(id)):
		if (id[i] == '.'): dot = i
	if (dot >= 0 && d.kind == MM_CLASS): name = id + dot + 1
	for i in range(scan.units.length):
		mm_ee_unit* unit = scan.units[i]
		if (unit.opener && unit.closer >= 0 && mm_ee_mentions(d, unit, name)): return i
	return -1

# ---------------------------------------------------------------- splicing

struct mm_ee_splice:
	int start
	int end
	char* text

list[mm_ee_splice*] mm_ee_splices():
	return new list[mm_ee_splice*]

void mm_ee_add(list[mm_ee_splice*] edits, int start, int end, char* text):
	mm_ee_splice* s = new mm_ee_splice()
	s.start = start
	s.end = end
	s.text = strclone(text)
	edits.push(s)

void mm_ee_splices_free(list[mm_ee_splice*] edits):
	for mm_ee_splice* s in edits:
		free(s.text)
		free(s)
	__w_list_free(cast(__w_list*, edits))

# The whole envelope with edits applied (sorted by start; overlaps refused).
char* mm_ee_apply(mm_document* d, list[mm_ee_splice*] edits):
	for i in range(1, edits.length):
		int j = i
		while (j > 0 && (edits[j].start < edits[j - 1].start || (edits[j].start == edits[j - 1].start && edits[j].end < edits[j - 1].end))):
			mm_ee_splice* t = edits[j]
			edits[j] = edits[j - 1]
			edits[j - 1] = t
			j = j - 1
	string_builder* out = string_new()
	int copied = 0
	for mm_ee_splice* s in edits:
		if (s.start < copied || s.end < s.start || s.end > d.length):
			string_free(out)
			return 0
		string_append_bytes(out, d.source + copied, s.start - copied)
		string_append(out, s.text)
		copied = s.end
	string_append_bytes(out, d.source + copied, d.length - copied)
	char* result = out.data
	free(out)
	return result

# Text that ends the selected diagram's body with a newline, so appended
# statements land inside the diagram (and before a closing fence).
int mm_ee_append_at(mm_document* d):
	return d.source_end

char* mm_ee_line(mm_document* d, char* statement):
	string_builder* text = string_new()
	if (d.source_end > d.source_start && d.source[d.source_end - 1] != 10): string_append_char(text, 10)
	string_append(text, statement)
	string_append_char(text, 10)
	char* result = text.data
	free(text)
	return result

# The indentation of the line containing offset.
char* mm_ee_indent(mm_document* d, int offset):
	int start = offset
	while (start > d.source_start && d.source[start - 1] != 10): start = start - 1
	int end = start
	while (end < d.source_end && (d.source[end] == 32 || d.source[end] == 9)): end = end + 1
	return str_copy_range(d.source, start, end)

# ---------------------------------------------------------------- validation

struct mm_expect:
	list[int] removed
	list[int] removed_edges
	list[int] parents
	list[char*] labels
	list[mm_node*] nodes
	list[mm_edge*] edges
	list[int] relaxed
	list[char*] added
	list[char*] added_labels
	list[int] added_parents
	list[int] added_from
	list[int] added_to
	int attempts

mm_expect* mm_expect_new(mm_document* d):
	mm_expect* x = new mm_expect()
	x.removed = new list[int]
	x.parents = new list[int]
	x.labels = new list[char*]
	x.nodes = new list[mm_node*]
	x.relaxed = new list[int]
	for i in range(d.nodes.length):
		x.removed.push(0)
		x.parents.push(MM_EE_SAME)
		x.labels.push(0)
		x.nodes.push(0)
		x.relaxed.push(0)
	x.removed_edges = new list[int]
	x.edges = new list[mm_edge*]
	for i in range(d.edges.length):
		x.removed_edges.push(0)
		x.edges.push(0)
	x.added = new list[char*]
	x.added_labels = new list[char*]
	x.added_parents = new list[int]
	x.added_from = new list[int]
	x.added_to = new list[int]
	return x

void mm_expect_free(mm_expect* x):
	__w_list_free(cast(__w_list*, x.removed))
	__w_list_free(cast(__w_list*, x.removed_edges))
	__w_list_free(cast(__w_list*, x.parents))
	__w_list_free(cast(__w_list*, x.labels))
	__w_list_free(cast(__w_list*, x.nodes))
	__w_list_free(cast(__w_list*, x.edges))
	__w_list_free(cast(__w_list*, x.relaxed))
	__w_list_free(cast(__w_list*, x.added))
	__w_list_free(cast(__w_list*, x.added_labels))
	__w_list_free(cast(__w_list*, x.added_parents))
	__w_list_free(cast(__w_list*, x.added_from))
	__w_list_free(cast(__w_list*, x.added_to))
	free(x)

# State start/end pseudo-states exist only through transitions: one left
# without a surviving transition disappears with them.
void mm_expect_orphans(mm_document* d, mm_expect* x):
	if (d.kind != MM_STATE): return
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (x.removed[i] || (n.shape != 4 && n.shape != 5)): continue
		int kept = 0
		for k in range(d.edges.length):
			mm_edge* edge = d.edges[k]
			if (x.removed_edges[k] == 0 && (edge.from_node == i || edge.to_node == i)): kept = 1
		if (kept == 0): x.removed[i] = 1

# Remove a node, its members (for a group) and every incident edge.
void mm_expect_remove(mm_document* d, mm_expect* x, int index, int members):
	x.removed[index] = 1
	if (members):
		for i in range(d.nodes.length):
			if (mm_position_within(d, i, index)): x.removed[i] = 1
	for i in range(d.edges.length):
		mm_edge* edge = d.edges[i]
		if ((edge.from_node >= 0 && x.removed[edge.from_node]) || (edge.to_node >= 0 && x.removed[edge.to_node])): x.removed_edges[i] = 1
	mm_expect_orphans(d, x)

# Synthetic numbered identities (`@space:3`, `note@0`): their prefix length.
int mm_ee_numbered(char* id):
	int length = strlen(id)
	int at = length
	while (at > 0 && id[at - 1] >= '0' && id[at - 1] <= '9'): at = at - 1
	if (at == length || at == 0): return 0
	if (id[at - 1] != ':' && id[at - 1] != '@'): return 0
	if (index_of(id, c"@") < 0): return 0
	if (starts_with(id, c"@start:") || starts_with(id, c"@end:")): return 0
	return at

int mm_ee_same_prefix(char* a, char* b, int length):
	if (mm_ee_numbered(b) != length): return 0
	for i in range(length):
		if (a[i] != b[i]): return 0
	return 1

# The node of next with old.nodes[index]'s identity. Numbered synthetic
# identities match by rank among the surviving nodes with the same prefix.
int mm_ee_find(mm_document* old, int index, mm_document* next, mm_expect* x):
	if (index < 0 || index >= old.nodes.length): return -1
	char* id = old.nodes[index].id
	int prefix = mm_ee_numbered(id)
	if (prefix == 0): return mm_serialize_find_equal(old, index, next)
	int rank = 0
	for i in range(index):
		if ((x == 0 || x.removed[i] == 0) && mm_ee_same_prefix(id, old.nodes[i].id, prefix)): rank = rank + 1
	for j in range(next.nodes.length):
		if (mm_ee_same_prefix(id, next.nodes[j].id, prefix)):
			if (rank == 0): return j
			rank = rank - 1
	return -1

int mm_ee_ref(mm_document* old, int ai, mm_document* next, int bi, mm_expect* x):
	if (ai == -1 || bi == -1): return ai == bi
	if (mm_ee_numbered(old.nodes[ai].id) == 0): return mm_serialize_reference_equal(old, ai, next, bi)
	return mm_ee_find(old, ai, next, x) == bi

int mm_ee_node_equal(mm_node* a, mm_node* b):
	if (mm_serialize_node_equal(a, b) == 0): return 0
	for i in range(a.members.length):
		if (mm_serialize_text_equal(a.members[i].text, b.members[i].text) == 0 || a.members[i].method != b.members[i].method): return 0
	return 1

int mm_ee_edge_equal(mm_document* a, mm_edge* left, mm_document* b, mm_edge* right, mm_expect* x):
	if (mm_ee_ref(a, left.from_node, b, right.from_node, x) == 0 || mm_ee_ref(a, left.to_node, b, right.to_node, x) == 0): return 0
	if (mm_ee_ref(a, left.scope, b, right.scope, x) == 0): return 0
	if (mm_serialize_text_equal(left.label, right.label) == 0 || mm_serialize_text_equal(left.left_label, right.left_label) == 0 || mm_serialize_text_equal(left.right_label, right.right_label) == 0): return 0
	if (left.dashed != right.dashed || left.arrow != right.arrow || left.left_card != right.left_card || left.right_card != right.right_card): return 0
	if (left.from_port != right.from_port || left.to_port != right.to_port || left.left_marker != right.left_marker || left.right_marker != right.right_marker): return 0
	if (mm_serialize_text_equal(left.id, right.id) == 0 || left.stroke != right.stroke || left.extra_rank != right.extra_rank || left.animate != right.animate || left.curve != right.curve): return 0
	return mm_serialize_style_equal(&left.style, &right.style)

# Edge scopes follow their endpoints' common group, which a reparent may change.
int mm_ee_scope_free(mm_expect* x):
	for int p in x.parents:
		if (p != MM_EE_SAME): return 1
	return 0

int mm_ee_validate(mm_document* old, mm_document* next, mm_expect* x):
	if (next.error != 0 || next.kind != old.kind): return 0
	int expected = x.added.length
	for i in range(old.nodes.length):
		if (x.removed[i] == 0): expected = expected + 1
	if (next.nodes.length != expected): return 0
	for i in range(old.nodes.length):
		if (x.removed[i]): continue
		int j = mm_ee_find(old, i, next, x)
		if (j < 0): return 0
		mm_node expected_node = *old.nodes[i]
		if (x.nodes[i] != 0): expected_node = *x.nodes[i]
		if (x.labels[i] != 0): expected_node.label = x.labels[i]
		if (x.relaxed[i]): expected_node.declared = next.nodes[j].declared
		if (mm_ee_node_equal(&expected_node, next.nodes[j]) == 0): return 0
		int parent = old.nodes[i].parent
		if (x.parents[i] != MM_EE_SAME): parent = x.parents[i]
		# A removed parent's members move to its own parent (ungrouping).
		while (parent >= 0 && x.removed[parent]): parent = old.nodes[parent].parent
		if (mm_ee_ref(old, parent, next, next.nodes[j].parent, x) == 0): return 0
	for k in range(x.added.length):
		int j = mm_find_node(next, x.added[k])
		if (j < 0 || mm_find_node(old, x.added[k]) >= 0): return 0
		if (x.added_labels[k] != 0 && mm_serialize_text_equal(next.nodes[j].label, x.added_labels[k]) == 0): return 0
		int parent = x.added_parents[k]
		if (mm_ee_ref(old, parent, next, next.nodes[j].parent, x) == 0): return 0
	int scope_free = mm_ee_scope_free(x)
	int edge = 0
	for i in range(old.edges.length):
		if (x.removed_edges[i]): continue
		if (edge >= next.edges.length): return 0
		mm_edge* want = old.edges[i]
		if (x.edges[i] != 0): want = x.edges[i]
		mm_edge copy = *want
		while (copy.scope >= 0 && copy.scope < old.nodes.length && x.removed[copy.scope]): copy.scope = old.nodes[copy.scope].parent
		if (scope_free): copy.scope = -1
		mm_edge* have = next.edges[edge]
		mm_edge other = *have
		if (scope_free): other.scope = -1
		if (mm_ee_edge_equal(old, &copy, next, &other, x) == 0): return 0
		edge = edge + 1
	for k in range(x.added_from.length):
		if (edge >= next.edges.length): return 0
		mm_edge* have = next.edges[edge]
		int from = x.added_from[k]
		int to = x.added_to[k]
		if (from >= 0 && mm_ee_ref(old, from, next, have.from_node, x) == 0): return 0
		if (to >= 0 && mm_ee_ref(old, to, next, have.to_node, x) == 0): return 0
		edge = edge + 1
	if (edge != next.edges.length): return 0
	int note = 0
	for mm_note* a in old.notes:
		if (a.node >= 0 && x.removed[a.node]): continue
		if (note >= next.notes.length): return 0
		mm_note* b = next.notes[note]
		if (a.side != b.side || mm_serialize_text_equal(a.text, b.text) == 0 || mm_ee_ref(old, a.node, next, b.node, x) == 0): return 0
		note = note + 1
	if (note != next.notes.length): return 0
	if (old.style_definitions.length != next.style_definitions.length): return 0
	for i in range(old.style_definitions.length):
		mm_style_class* a = old.style_definitions[i]
		mm_style_class* b = next.style_definitions[i]
		if (strcmp(a.name, b.name) != 0 || mm_serialize_style_equal(&a.style, &b.style) == 0): return 0
	if (strcmp(old.direction, next.direction) != 0 || strcmp(old.title, next.title) != 0): return 0
	if (strcmp(old.accessibility_title, next.accessibility_title) != 0 || strcmp(old.accessibility_description, next.accessibility_description) != 0): return 0
	if (old.theme != next.theme || old.layout_algorithm != next.layout_algorithm || mm_serialize_style_equal(&old.edge_style, &next.edge_style) == 0): return 0
	return 1

# Try one candidate source; commit it as one undo step when it validates.
# Owns source. Returns 1 when committed.
int mm_ee_attempt(mm_editor* e, char* source, mm_expect* x):
	if (source == 0): return 0
	if (x.attempts >= MM_EE_ATTEMPTS || strlen(source) > MM_MAX_SOURCE):
		free(source)
		return 0
	x.attempts = x.attempts + 1
	mm_document* next = mm_parse_selected(source, strlen(source), e.selected)
	int ok = mm_ee_validate(e.document, next, x)
	mm_document_free(next)
	if (ok): ok = mm_editor_change(e, source)
	free(source)
	return ok

int mm_ee_attempt_edits(mm_editor* e, list[mm_ee_splice*] edits, mm_expect* x):
	char* source = mm_ee_apply(e.document, edits)
	return mm_ee_attempt(e, source, x)

int mm_ee_attempt_splice(mm_editor* e, int start, int end, char* text, mm_expect* x):
	list[mm_ee_splice*] edits = mm_ee_splices()
	mm_ee_add(edits, start, end, text)
	int ok = mm_ee_attempt_edits(e, edits, x)
	mm_ee_splices_free(edits)
	return ok

int mm_ee_attempt_append(mm_editor* e, char* statement, mm_expect* x):
	char* line = mm_ee_line(e.document, statement)
	int ok = mm_ee_attempt_splice(e, e.document.source_end, e.document.source_end, line, x)
	free(line)
	return ok

# ---------------------------------------------------------------- text rules

# Labels the generic commands write: printable, no quotes, no comment marker.
int mm_ee_text_safe(char* text):
	if (text == 0): return 0
	int length = strlen(text)
	for i in range(length):
		int c = text[i] & 255
		if (c < 32 || c == '"' || c == '`'): return 0
		if (c == '%' && i + 1 < length && text[i + 1] == '%'): return 0
	return utf8_validate_bytes(text, length)

int mm_ee_plain_id(char* id):
	if (id == 0 || id[0] == 0): return 0
	for i in range(strlen(id)):
		if (mm_id_char(id[i] & 255) == 0): return 0
	return 1

# ---------------------------------------------------------------- geometry records

# Remove valid geometry records naming removed nodes.
void mm_ee_drop_records(mm_document* d, mm_expect* x, list[mm_ee_splice*] edits):
	int at = d.source_start
	while (at < d.source_end):
		int end = mm_ee_line_end(d, at)
		int next = end
		if (next < d.source_end): next = next + 1
		int kind = 0
		int px = 0
		int py = 0
		int record = mm_geometry_record(d, at, end, &kind, &px, &py)
		if (record >= 0 && x.removed[record]): mm_ee_add(edits, at, next, c"")
		at = next

# ---------------------------------------------------------------- rename

# In place first: replace an occurrence of the current label (raw, then
# quoted) so only those bytes change. Then insert a label after the id.
# modes: 1 in place, 2 insert after the id token, 3 both.
int mm_ee_rename_mode(mm_editor* e, int index, char* label, int modes):
	mm_document* d = e.document
	if (index < 0 || index >= d.nodes.length || mm_ee_text_safe(label) == 0 || label[0] == 0): return 0
	mm_node* n = d.nodes[index]
	if (strcmp(n.label, label) == 0): return 1
	mm_expect* x = mm_expect_new(d)
	x.labels[index] = label
	int ok = 0
	char* old = n.label
	int length = strlen(old)
	string_builder* quoted = string_from(c"\"")
	string_append(quoted, label)
	string_append_char(quoted, '"')
	if ((modes & 1) && length > 0 && strcmp(old, n.id) != 0):
		int at = d.source_start
		while (ok == 0 && at + length <= d.source_end && x.attempts < MM_EE_ATTEMPTS):
			int found = index_of(d.source + at, old)
			if (found < 0 || at + found + length > d.source_end): break
			int start = at + found
			if (mm_ee_in_comment(d, start) == 0):
				ok = mm_ee_attempt_splice(e, start, start + length, label, x)
				if (ok == 0): ok = mm_ee_attempt_splice(e, start, start + length, quoted.data, x)
			at = start + 1
	if (ok == 0 && (modes & 2) && mm_position_identity(n.id)):
		# After an id token: `["L"]`, `[L]`, `("L")`, `(L)`.
		mm_ee_scan* scan = mm_ee_scan_new(d)
		for mm_ee_unit* unit in scan.units:
			if (ok || x.attempts >= MM_EE_ATTEMPTS): break
			if (unit.header): continue
			int at = mm_ee_token(d, unit.code, unit.code_end, n.id, unit.code)
			while (at >= 0 && ok == 0 && x.attempts < MM_EE_ATTEMPTS):
				int after = at + strlen(n.id)
				list[char*] forms = new list[char*]
				string_builder* a = string_from(c"[\"")
				string_append(a, label)
				string_append(a, c"\"]")
				string_builder* b = string_from(c"[")
				string_append(b, label)
				string_append(b, c"]")
				string_builder* c = string_from(c"(\"")
				string_append(c, label)
				string_append(c, c"\")")
				string_builder* f = string_from(c"(")
				string_append(f, label)
				string_append(f, c")")
				forms.push(a.data)
				forms.push(b.data)
				forms.push(c.data)
				forms.push(f.data)
				for char* form in forms:
					if (ok == 0): ok = mm_ee_attempt_splice(e, after, after, form, x)
				string_free(a)
				string_free(b)
				string_free(c)
				string_free(f)
				__w_list_free(cast(__w_list*, forms))
				if (ok == 0): at = mm_ee_token(d, unit.code, unit.code_end, n.id, at + 1)
		mm_ee_scan_free(scan)
	string_free(quoted)
	mm_expect_free(x)
	return ok

int mm_ee_rename(mm_editor* e, int index, char* label):
	return mm_ee_rename_mode(e, index, label, 3)

int mm_ee_rename_in_place(mm_editor* e, int index, char* label):
	return mm_ee_rename_mode(e, index, label, 1)

int mm_ee_rename_insert(mm_editor* e, int index, char* label):
	return mm_ee_rename_mode(e, index, label, 2)

# ---------------------------------------------------------------- delete

int mm_ee_unit_removed(mm_ee_scan* scan, list[int] taken, int index):
	int at = scan.units[index].parent
	while (at >= 0):
		if (taken[at]): return 1
		at = scan.units[at].parent
	return 0

# The span of a declaration item starting at the id token: id, a bracketed
# label (with quotes), `:N` spans and trailing blanks. Used for block rows.
int mm_ee_item_end(mm_document* d, int at, int end, char* id):
	int pos = at + strlen(id)
	int depth = 0
	int quoted = 0
	while (pos < end):
		int c = d.source[pos]
		if (c == '"'): quoted = quoted == 0
		else if (quoted == 0):
			if (c == '[' || c == '(' || c == '{' || c == '<'): depth = depth + 1
			else if (c == ']' || c == ')' || c == '}' || c == '>'):
				if (depth == 0): break
				depth = depth - 1
			else if (depth == 0 && (c == 32 || c == 9 || c == ':')): break
		pos = pos + 1
	if (pos < end && d.source[pos] == ':'):
		pos = pos + 1
		while (pos < end && d.source[pos] >= '0' && d.source[pos] <= '9'): pos = pos + 1
	while (pos < end && (d.source[pos] == 32 || d.source[pos] == 9)): pos = pos + 1
	return pos

# A relation row that also declares survivors keeps their items, one per
# line at the row's indentation (pass 2: labeled items only; pass 3: every
# surviving mention, for nodes this row alone declares).
# 1 when a statement other than unit `skip` that names no removed node
# mentions id (so a bare re-declaration would be redundant).
int mm_ee_mentioned_elsewhere(mm_ee_scan* scan, int skip, mm_expect* x, char* id):
	mm_document* d = scan.d
	for u in range(scan.units.length):
		mm_ee_unit* unit = scan.units[u]
		if (u == skip || unit.header || mm_ee_mentions(d, unit, id) == 0): continue
		int doomed = 0
		for i in range(d.nodes.length):
			if (x.removed[i] && mm_position_identity(d.nodes[i].id) && mm_ee_mentions(d, unit, d.nodes[i].id)): doomed = 1
		if (doomed == 0): return 1
	return 0

char* mm_ee_survivors(mm_ee_scan* scan, int u, mm_expect* x, int bare):
	mm_document* d = scan.d
	mm_ee_unit* unit = scan.units[u]
	string_builder* out = string_new()
	for i in range(d.nodes.length):
		if (x.removed[i] || mm_position_identity(d.nodes[i].id) == 0): continue
		if (d.nodes[i].group): continue
		int at = mm_ee_token(d, unit.code, unit.code_end, d.nodes[i].id, unit.code)
		if (at < 0): continue
		int end = mm_ee_item_end(d, at, unit.code_end, d.nodes[i].id)
		while (end > at && (d.source[end - 1] == 32 || d.source[end - 1] == 9)): end = end - 1
		if (end <= at + strlen(d.nodes[i].id) && (bare == 0 || mm_ee_mentioned_elsewhere(scan, u, x, d.nodes[i].id))): continue
		if (out.length > 0):
			string_append_char(out, 10)
			string_append_bytes(out, d.source + unit.start, unit.code - unit.start)
		string_append_bytes(out, d.source + at, end - at)
	char* result = out.data
	free(out)
	return result

# Remove every statement naming a removed node (a removed group's block
# whole), plus their geometry records, as one candidate; then, for rows that
# also declare surviving items, only the removed items' spans; then relation
# rows reduced to their surviving declarations.
int mm_ee_delete_expect(mm_editor* e, mm_expect* x):
	mm_document* d = e.document
	mm_ee_scan* scan = mm_ee_scan_new(d)
	int ok = 0
	for pass in range(4):
		if (ok): break
		list[mm_ee_splice*] edits = mm_ee_splices()
		list[int] taken = new list[int]
		for i in range(scan.units.length): taken.push(0)
		for u in range(scan.units.length):
			mm_ee_unit* unit = scan.units[u]
			if (unit.header || mm_ee_unit_removed(scan, taken, u)): continue
			int hit = 0
			int survivor = 0
			for i in range(d.nodes.length):
				if (mm_position_identity(d.nodes[i].id) == 0 && mm_ee_numbered(d.nodes[i].id) == 0): continue
				if (mm_ee_mentions(d, unit, d.nodes[i].id) == 0): continue
				if (x.removed[i]): hit = 1
				else: survivor = 1
			# An edge statement between survivors is kept unless its edge goes.
			if (hit == 0): continue
			int opener_of_removed = 0
			if (unit.opener):
				for i in range(d.nodes.length):
					if (x.removed[i] && d.nodes[i].group && mm_ee_group_unit(scan, i) == u): opener_of_removed = 1
				# A removed node's own body block (entity, class, requirement).
				int subject = mm_ee_unit_subject(d, unit)
				if (subject >= 0 && x.removed[subject] && d.nodes[subject].group == 0): opener_of_removed = 1
			if (unit.opener && opener_of_removed == 0):
				# A surviving block naming a removed node (e.g. a relation inside a
				# composite) is handled by its inner statements.
				continue
			# Pass 1: rows that only declare items lose just the removed items.
			int relation = 0
			if (pass >= 2 && unit.opener == 0 && survivor):
				list[int] spans = mm_ee_operator_spans(d, unit.code, unit.code_end)
				int row = spans.length > 0
				__w_list_free(cast(__w_list*, spans))
				if (row):
					char* kept = mm_ee_survivors(scan, u, x, pass == 3)
					taken[u] = 1
					if (kept[0] != 0): mm_ee_add(edits, unit.code, unit.code_end, kept)
					else: mm_ee_add(edits, unit.start, unit.end, c"")
					free(kept)
					continue
			if (pass >= 1 && unit.opener == 0):
				list[int] spans = mm_ee_operator_spans(d, unit.code, unit.code_end)
				relation = spans.length > 0
				__w_list_free(cast(__w_list*, spans))
			if (pass >= 1 && relation == 0 && unit.opener == 0 && (survivor || unit.code_end > unit.code)):
				# Items only: when they are the whole row, the row goes instead.
				int covered = 0
				int first = edits.length
				for i in range(d.nodes.length):
					if (x.removed[i] == 0 || mm_position_identity(d.nodes[i].id) == 0): continue
					int at = mm_ee_token(d, unit.code, unit.code_end, d.nodes[i].id, unit.code)
					if (at < 0): continue
					int item_end = mm_ee_item_end(d, at, unit.code_end, d.nodes[i].id)
					covered = covered + item_end - at
					mm_ee_add(edits, at, item_end, c"")
				if (survivor || covered < unit.code_end - unit.code): continue
				while (edits.length > first):
					mm_ee_splice* dropped = edits.pop()
					free(dropped.text)
					free(dropped)
			taken[u] = 1
			mm_ee_add(edits, unit.start, unit.end, c"")
		mm_ee_drop_records(d, x, edits)
		if (edits.length > 0): ok = mm_ee_attempt_edits(e, edits, x)
		mm_ee_splices_free(edits)
		__w_list_free(cast(__w_list*, taken))
	mm_ee_scan_free(scan)
	return ok

int mm_ee_delete_node(mm_editor* e, int index):
	mm_document* d = e.document
	if (index < 0 || index >= d.nodes.length): return 0
	mm_expect* x = mm_expect_new(d)
	mm_expect_remove(d, x, index, 1)
	int ok = mm_ee_delete_expect(e, x)
	mm_expect_free(x)
	return ok

# Ungroup: remove the group's opener and closer lines; members join the
# group's parent. Architecture-style `in group` suffixes are removed too.
int mm_ee_ungroup(mm_editor* e, int index):
	mm_document* d = e.document
	if (index < 0 || index >= d.nodes.length || d.nodes[index].group == 0): return 0
	mm_expect* x = mm_expect_new(d)
	x.removed[index] = 1
	mm_ee_scan* scan = mm_ee_scan_new(d)
	list[mm_ee_splice*] edits = mm_ee_splices()
	int unit = mm_ee_group_unit(scan, index)
	char* id = d.nodes[index].id
	if (unit >= 0):
		mm_ee_unit* u = scan.units[unit]
		int header_end = mm_ee_line_end(d, u.start)
		if (header_end < d.source_end): header_end = header_end + 1
		mm_ee_add(edits, u.start, header_end, c"")
		mm_ee_add(edits, u.closer, u.end, c"")
	else:
		for mm_ee_unit* u in scan.units:
			if (u.header || mm_ee_mentions(d, u, id) == 0): continue
			# The group's own declaration line, and ` in id` member suffixes.
			int at = mm_ee_token(d, u.code, u.code_end, id, u.code)
			int keyword = at - 3
			while (keyword > u.code && mm_ee_space(d.source[keyword - 1])): keyword = keyword - 1
			if (at >= u.code + 3 && mm_ee_word_is(d, at - 3, at, c"in")):
				int start = at - 3
				while (start > u.code && mm_ee_space(d.source[start - 1])): start = start - 1
				mm_ee_add(edits, start, at + strlen(id), c"")
			else if (mm_ee_word_is(d, u.code, u.code_end, c"group")): mm_ee_add(edits, u.start, u.end, c"")
	mm_ee_drop_records(d, x, edits)
	int ok = 0
	if (edits.length > 0): ok = mm_ee_attempt_edits(e, edits, x)
	mm_ee_splices_free(edits)
	mm_ee_scan_free(scan)
	mm_expect_free(x)
	return ok

# Edge removal: the statement naming both endpoints that alone states it.
int mm_ee_delete_edge(mm_editor* e, int index):
	mm_document* d = e.document
	if (index < 0 || index >= d.edges.length): return 0
	mm_edge* edge = d.edges[index]
	if (edge.from_node < 0 || edge.to_node < 0): return 0
	mm_expect* x = mm_expect_new(d)
	x.removed_edges[index] = 1
	mm_expect_orphans(d, x)
	mm_ee_scan* scan = mm_ee_scan_new(d)
	int ok = 0
	char* from = d.nodes[edge.from_node].id
	char* to = d.nodes[edge.to_node].id
	for mm_ee_unit* unit in scan.units:
		if (ok || unit.header || unit.opener || x.attempts >= MM_EE_ATTEMPTS): continue
		if (mm_ee_mentions(d, unit, from) == 0 || mm_ee_mentions(d, unit, to) == 0): continue
		ok = mm_ee_attempt_splice(e, unit.start, unit.end, c"", x)
	mm_ee_scan_free(scan)
	mm_expect_free(x)
	return ok

# ---------------------------------------------------------------- insertions

# A statement inside group's body: before its closer line, indented like the
# block's last statement. Returns 1 when committed.
int mm_ee_insert_in_group(mm_editor* e, int group, char* statement, mm_expect* x):
	mm_document* d = e.document
	if (group < 0): return mm_ee_attempt_append(e, statement, x)
	mm_ee_scan* scan = mm_ee_scan_new(d)
	int unit = mm_ee_group_unit(scan, group)
	int ok = 0
	if (unit >= 0):
		mm_ee_unit* u = scan.units[unit]
		char* indent = mm_ee_indent(d, u.closer)
		string_builder* line = string_from(indent)
		string_append(line, c"  ")
		# Prefer the indentation of a statement already inside the block.
		for mm_ee_unit* inner in scan.units:
			if (inner.parent == unit):
				char* inner_indent = mm_ee_indent(d, inner.code)
				string_free(line)
				line = string_from(inner_indent)
				free(inner_indent)
		string_append(line, statement)
		string_append_char(line, 10)
		ok = mm_ee_attempt_splice(e, u.closer, u.closer, line.data, x)
		string_free(line)
		free(indent)
	mm_ee_scan_free(scan)
	return ok

# Templates for a new node and a new connection, per family.
char* mm_ee_node_statement(mm_document* d, char* id, char* label):
	string_builder* s = string_new()
	int k = d.kind
	if (k == MM_REQUIREMENT):
		string_append(s, c"requirement ")
		string_append(s, id)
		string_append(s, c" {\n}")
	else if (k == MM_USECASE):
		string_append(s, id)
		string_append(s, c"(")
		string_append(s, label)
		string_append(s, c")")
	else if (k == MM_ARCHITECTURE):
		string_append(s, c"service ")
		string_append(s, id)
		string_append(s, c"(server)[")
		string_append(s, label)
		string_append(s, c"]")
	else if (k == MM_C4):
		string_append(s, c"System(")
		string_append(s, id)
		string_append(s, c", \"")
		string_append(s, label)
		string_append(s, c"\")")
	else:
		string_append(s, id)
		string_append(s, c"[\"")
		string_append(s, label)
		string_append(s, c"\"]")
	char* result = s.data
	free(s)
	return result

char* mm_ee_edge_statement(mm_document* d, char* from, char* to):
	string_builder* s = string_new()
	int k = d.kind
	if (k == MM_REQUIREMENT):
		string_append(s, from)
		string_append(s, c" - traces -> ")
		string_append(s, to)
	else if (k == MM_ARCHITECTURE):
		string_append(s, from)
		string_append(s, c":R --> L:")
		string_append(s, to)
	else if (k == MM_C4):
		string_append(s, c"Rel(")
		string_append(s, from)
		string_append(s, c", ")
		string_append(s, to)
		string_append(s, c", \"Uses\")")
	else:
		string_append(s, from)
		string_append(s, c" --> ")
		string_append(s, to)
	char* result = s.data
	free(s)
	return result

int mm_ee_add_node(mm_editor* e, char* id, char* label, int group):
	mm_document* d = e.document
	if (d.error != 0 || mm_ee_plain_id(id) == 0 || mm_ee_text_safe(label) == 0 || mm_find_node(d, id) >= 0): return 0
	if (group >= d.nodes.length || (group >= 0 && d.nodes[group].group == 0)): return 0
	if (label[0] == 0): label = id
	for i in range(strlen(label)):
		if (label[i] == ']' || label[i] == ')' || label[i] == '['): return 0
	char* statement = mm_ee_node_statement(d, id, label)
	mm_expect* x = mm_expect_new(d)
	x.added.push(id)
	if (d.kind != MM_REQUIREMENT): x.added_labels.push(label)
	else: x.added_labels.push(0)
	# A block diagram's top-level items belong to its synthetic root.
	if (group < 0 && d.kind == MM_BLOCK): x.added_parents.push(mm_find_node(d, c"@block:root"))
	else: x.added_parents.push(group)
	int ok = 0
	if (group >= 0 && d.kind == MM_ARCHITECTURE):
		string_builder* in_group = string_from(statement)
		string_append(in_group, c" in ")
		string_append(in_group, d.nodes[group].id)
		ok = mm_ee_attempt_append(e, in_group.data, x)
		string_free(in_group)
	else: ok = mm_ee_insert_in_group(e, group, statement, x)
	free(statement)
	mm_expect_free(x)
	return ok

int mm_ee_connect(mm_editor* e, int from, int to):
	mm_document* d = e.document
	if (d.error != 0 || from < 0 || to < 0 || from >= d.nodes.length || to >= d.nodes.length): return 0
	if (mm_ee_plain_id(d.nodes[from].id) == 0 || mm_ee_plain_id(d.nodes[to].id) == 0): return 0
	if (d.nodes[from].group || d.nodes[to].group): return 0
	char* statement = mm_ee_edge_statement(d, d.nodes[from].id, d.nodes[to].id)
	mm_expect* x = mm_expect_new(d)
	x.added_from.push(from)
	x.added_to.push(to)
	int ok = mm_ee_attempt_append(e, statement, x)
	free(statement)
	mm_expect_free(x)
	return ok

# ---------------------------------------------------------------- reparent

# A statement that only declares index (no other node, no relationship).
int mm_ee_declaration_unit(mm_document* d, mm_ee_unit* unit, int index):
	if (unit.header || unit.opener || mm_ee_mentions(d, unit, d.nodes[index].id) == 0): return 0
	if (mm_ee_other_mention(d, unit, index) >= 0): return 0
	for at in range(unit.code, unit.code_end):
		if (d.source[at] == '-' && at + 1 < unit.code_end && (d.source[at + 1] == '-' || d.source[at + 1] == '.' || d.source[at + 1] == '>')): return 0
	return 1

int mm_ee_unit_within(mm_ee_scan* scan, int unit, int block):
	int at = scan.units[unit].parent
	while (at >= 0):
		if (at == block): return 1
		at = scan.units[at].parent
	return 0

# The declaration that moves a node into a block, per family.
char* mm_ee_mention_statement(mm_document* d, int index):
	string_builder* s = string_new()
	if (d.kind == MM_CLASS): string_append(s, c"class ")
	else if (d.kind == MM_STATE): string_append(s, c"state ")
	string_append(s, d.nodes[index].id)
	char* result = s.data
	free(s)
	return result

# Move node index into group (or to the top level, -1). Declarations that
# alone name it inside its current group move with their label and shape;
# otherwise a bare declaration is inserted into the target block.
int mm_ee_reparent(mm_editor* e, int index, int group):
	mm_document* d = e.document
	if (d.error != 0 || index < 0 || index >= d.nodes.length): return 0
	if (group >= d.nodes.length || group == index): return 0
	if (group >= 0 && (d.nodes[group].group == 0 || mm_position_within(d, group, index))): return 0
	if (d.nodes[index].parent == group): return 1
	if (mm_ee_plain_id(d.nodes[index].id) == 0): return 0
	mm_expect* x = mm_expect_new(d)
	x.parents[index] = group
	int ok = 0
	mm_ee_scan* scan = mm_ee_scan_new(d)
	char* id = d.nodes[index].id
	if (d.kind == MM_ARCHITECTURE):
		# `service id(...)[...] in group`: replace, add or drop the suffix.
		for mm_ee_unit* unit in scan.units:
			if (ok || unit.header || mm_ee_token(d, unit.code, unit.code_end, id, unit.code) < 0): continue
			if (mm_ee_word_is(d, unit.code, unit.code_end, c"service") == 0 && mm_ee_word_is(d, unit.code, unit.code_end, c"junction") == 0): continue
			int parent = d.nodes[index].parent
			string_builder* suffix = string_new()
			if (group >= 0):
				string_append(suffix, c" in ")
				string_append(suffix, d.nodes[group].id)
			if (parent >= 0):
				int at = mm_ee_token(d, unit.code, unit.code_end, d.nodes[parent].id, unit.code)
				if (at >= 0):
					int start = at - 1
					while (start > unit.code && mm_ee_space(d.source[start])): start = start - 1
					start = start - 1
					while (start > unit.code && mm_ee_space(d.source[start - 1])): start = start - 1
					ok = mm_ee_attempt_splice(e, start, at + strlen(d.nodes[parent].id), suffix.data, x)
			else: ok = mm_ee_attempt_splice(e, unit.code_end, unit.code_end, suffix.data, x)
			string_free(suffix)
	else:
		int target = -1
		if (group >= 0): target = mm_ee_group_unit(scan, group)
		int source_block = -1
		if (d.nodes[index].parent >= 0): source_block = mm_ee_group_unit(scan, d.nodes[index].parent)
		# Candidate 0 carries the declarations that alone name the node in its
		# current scope; candidate 1 adds a bare declaration to the target.
		for candidate in range(2):
			if (ok || (group >= 0 && target < 0)): break
			list[mm_ee_splice*] edits = mm_ee_splices()
			string_builder* moved = string_new()
			if (candidate == 0):
				for u in range(scan.units.length):
					mm_ee_unit* unit = scan.units[u]
					if (mm_ee_declaration_unit(d, unit, index) == 0): continue
					if (source_block >= 0 && mm_ee_unit_within(scan, u, source_block) == 0): continue
					if (source_block < 0 && unit.parent >= 0): continue
					string_append_bytes(moved, d.source + unit.code, unit.code_end - unit.code)
					string_append_char(moved, 10)
					mm_ee_add(edits, unit.start, unit.end, c"")
			else:
				char* mention = mm_ee_mention_statement(d, index)
				string_append(moved, mention)
				string_append_char(moved, 10)
				free(mention)
			if (moved.length > 0):
				string_builder* text = string_new()
				int at = d.source_end
				char* indent = strclone(c"")
				if (target >= 0):
					mm_ee_unit* block = scan.units[target]
					at = block.closer
					free(indent)
					indent = mm_ee_indent(d, block.closer)
					string_builder* deeper = string_from(indent)
					string_append(deeper, c"  ")
					free(indent)
					indent = strclone(deeper.data)
					string_free(deeper)
				else if (d.source_end > d.source_start && d.source[d.source_end - 1] != 10): string_append_char(text, 10)
				int line = 0
				for i in range(moved.length):
					if (line == 0): string_append(text, indent)
					line = 1
					string_append_char(text, moved.data[i])
					if (moved.data[i] == 10): line = 0
				mm_ee_add(edits, at, at, text.data)
				ok = mm_ee_attempt_edits(e, edits, x)
				free(indent)
				string_free(text)
			string_free(moved)
			mm_ee_splices_free(edits)
	mm_ee_scan_free(scan)
	mm_expect_free(x)
	return ok

# ---------------------------------------------------------------- edge label / kind

# Units naming both endpoints of edge index (candidates for its statement).
int mm_ee_edge_unit(mm_document* d, mm_ee_unit* unit, mm_edge* edge):
	if (unit.header || unit.opener): return 0
	return mm_ee_mentions(d, unit, d.nodes[edge.from_node].id) && mm_ee_mentions(d, unit, d.nodes[edge.to_node].id)

int mm_ee_operator_char(int c):
	return c == '-' || c == '.' || c == '=' || c == '<' || c == '>' || c == '|' || c == '*' || c == '{' || c == '}' || c == 'o' || c == 'x' || c == '+'

int mm_ee_operator_core(mm_document* d, int start, int end):
	int dashes = 0
	for at in range(start, end):
		int c = d.source[at]
		if (c == '-' || c == '.' || c == '='): dashes = dashes + 1
	return dashes >= 2

# Each maximal operator run in [start, end) as a candidate span, plus the
# spans without a leading/trailing o/x letter (which may belong to an id).
list[int] mm_ee_operator_spans(mm_document* d, int start, int end):
	list[int] spans = new list[int]
	int at = start
	int quoted = 0
	while (at < end):
		int c = d.source[at]
		if (c == '"'):
			quoted = quoted == 0
			at = at + 1
			continue
		if (quoted || mm_ee_operator_char(c) == 0):
			at = at + 1
			continue
		int run = at
		while (at < end && mm_ee_operator_char(d.source[at])): at = at + 1
		for trim_left in range(2):
			for trim_right in range(2):
				int a = run
				int b = at
				if (trim_left):
					while (a < b && (d.source[a] == 'o' || d.source[a] == 'x')): a = a + 1
				if (trim_right):
					while (b > a && (d.source[b - 1] == 'o' || d.source[b - 1] == 'x')): b = b - 1
				if (b > a && mm_ee_operator_core(d, a, b)):
					int duplicate = 0
					for k in range(spans.length / 2):
						if (spans[k * 2] == a && spans[k * 2 + 1] == b): duplicate = 1
					if (duplicate == 0):
						spans.push(a)
						spans.push(b)
	return spans

int mm_ee_edge_label(mm_editor* e, int index, char* label):
	mm_document* d = e.document
	if (d.error != 0 || index < 0 || index >= d.edges.length || label == 0): return 0
	if (mm_ee_text_safe(label) == 0): return 0
	for i in range(strlen(label)):
		if (label[i] == '|' || label[i] == ';' || label[i] == ':'): return 0
	mm_edge* edge = d.edges[index]
	if (edge.from_node < 0 || edge.to_node < 0): return 0
	if (strcmp(edge.label, label) == 0): return 1
	mm_edge want = *edge
	want.label = label
	mm_expect* x = mm_expect_new(d)
	x.edges[index] = &want
	mm_ee_scan* scan = mm_ee_scan_new(d)
	int ok = 0
	char* old = edge.label
	int length = strlen(old)
	for mm_ee_unit* unit in scan.units:
		if (ok || mm_ee_edge_unit(d, unit, edge) == 0 || x.attempts >= MM_EE_ATTEMPTS): continue
		if (length > 0):
			int at = unit.code
			while (ok == 0 && at < unit.code_end && x.attempts < MM_EE_ATTEMPTS):
				int found = index_of(d.source + at, old)
				if (found < 0 || at + found + length > unit.code_end): break
				int start = at + found
				if (label[0] != 0): ok = mm_ee_attempt_splice(e, start, start + length, label, x)
				else:
					# Removing: the label with its delimiters.
					int a = start
					int b = start + length
					if (a > unit.code && b < unit.code_end && (d.source[a - 1] == '|' || d.source[a - 1] == '"') && d.source[b] == d.source[a - 1]):
						a = a - 1
						b = b + 1
					int colon = a
					while (colon > unit.code && mm_ee_space(d.source[colon - 1])): colon = colon - 1
					if (colon > unit.code && d.source[colon - 1] == ':'):
						colon = colon - 1
						while (colon > unit.code && mm_ee_space(d.source[colon - 1])): colon = colon - 1
						a = colon
					ok = mm_ee_attempt_splice(e, a, b, c"", x)
				at = start + 1
		else:
			string_builder* bar = string_from(c"|")
			string_append(bar, label)
			string_append_char(bar, '|')
			string_builder* colon = string_from(c" : ")
			string_append(colon, label)
			list[int] spans = mm_ee_operator_spans(d, unit.code, unit.code_end)
			for k in range(spans.length / 2):
				if (ok == 0): ok = mm_ee_attempt_splice(e, spans[k * 2 + 1], spans[k * 2 + 1], bar.data, x)
			if (ok == 0): ok = mm_ee_attempt_splice(e, unit.code_end, unit.code_end, colon.data, x)
			# `A -- "label" --> B` (use case, flowchart inline text).
			for k in range(spans.length / 2):
				if (ok == 0 && d.source[spans[k * 2]] == '-'):
					string_builder* inline = string_from(c"-- \"")
					string_append(inline, label)
					string_append(inline, c"\" ")
					ok = mm_ee_attempt_splice(e, spans[k * 2], spans[k * 2], inline.data, x)
					string_free(inline)
			__w_list_free(cast(__w_list*, spans))
			string_free(bar)
			string_free(colon)
	mm_ee_scan_free(scan)
	mm_expect_free(x)
	return ok

# The family's diagram header line (`flowchart LR`, `classDiagram`, ...).
char* mm_ee_header(mm_document* d):
	mm_ee_scan* scan = mm_ee_scan_new(d)
	char* header = 0
	if (scan.units.length > 0):
		mm_ee_unit* unit = scan.units[0]
		header = str_copy_range(d.source, unit.code, unit.code_end)
	mm_ee_scan_free(scan)
	return header

# The edge a family's grammar reads for `operator` between two fresh nodes.
# Owned probe document (with *edge set), or null when the operator is invalid.
mm_document* mm_ee_probe(mm_document* d, char* operator, mm_edge** edge, int* swapped):
	char* header = mm_ee_header(d)
	if (header == 0): return 0
	string_builder* s = string_from(header)
	free(header)
	string_append_char(s, 10)
	if (d.kind == MM_REQUIREMENT):
		string_append(s, c"requirement PA {\n}\nrequirement PB {\n}\nPA - ")
		string_append(s, operator)
		string_append(s, c" -> PB\n")
	else:
		string_append(s, c"PA ")
		string_append(s, operator)
		string_append(s, c" PB")
		if (d.kind == MM_ER): string_append(s, c" : x")
		string_append_char(s, 10)
	mm_document* probe = mm_parse(s.data, s.length)
	string_free(s)
	if (probe.error != 0 || probe.edges.length != 1):
		mm_document_free(probe)
		return 0
	*edge = probe.edges[0]
	*swapped = strcmp(probe.nodes[probe.edges[0].from_node].id, c"PB") == 0
	return probe

# Change an edge's operator (arrowheads, line kind, ER cardinalities, class
# relationship kind, requirement relation): replace the operator bytes.
int mm_ee_edge_kind(mm_editor* e, int index, char* operator):
	mm_document* d = e.document
	if (d.error != 0 || index < 0 || index >= d.edges.length || operator == 0 || operator[0] == 0): return 0
	for i in range(strlen(operator)):
		int c = operator[i]
		if (c == 10 || c == 13 || c == '"' || c == ';' || c == '%'): return 0
		if (d.kind != MM_REQUIREMENT && (c == 32 || mm_ee_operator_char(c) == 0)): return 0
	mm_edge* edge = d.edges[index]
	if (edge.from_node < 0 || edge.to_node < 0): return 0
	mm_edge* model = 0
	int swapped = 0
	mm_document* probe = mm_ee_probe(d, operator, &model, &swapped)
	if (probe == 0): return 0
	mm_edge want = *edge
	want.dashed = model.dashed
	want.arrow = model.arrow
	want.left_card = model.left_card
	want.right_card = model.right_card
	want.left_marker = model.left_marker
	want.right_marker = model.right_marker
	want.stroke = model.stroke
	want.extra_rank = model.extra_rank
	want.min_length = model.min_length
	if (d.kind == MM_REQUIREMENT): want.label = model.label
	if (swapped):
		want.from_node = edge.to_node
		want.to_node = edge.from_node
	mm_expect* x = mm_expect_new(d)
	x.edges[index] = &want
	mm_ee_scan* scan = mm_ee_scan_new(d)
	int ok = 0
	for mm_ee_unit* unit in scan.units:
		if (ok || mm_ee_edge_unit(d, unit, edge) == 0 || x.attempts >= MM_EE_ATTEMPTS): continue
		if (d.kind == MM_REQUIREMENT):
			int at = mm_ee_token(d, unit.code, unit.code_end, edge.label, unit.code)
			while (at >= 0 && ok == 0):
				ok = mm_ee_attempt_splice(e, at, at + strlen(edge.label), operator, x)
				if (ok == 0): at = mm_ee_token(d, unit.code, unit.code_end, edge.label, at + 1)
			continue
		list[int] spans = mm_ee_operator_spans(d, unit.code, unit.code_end)
		for k in range(spans.length / 2):
			if (ok == 0 && x.attempts < MM_EE_ATTEMPTS): ok = mm_ee_attempt_splice(e, spans[k * 2], spans[k * 2 + 1], operator, x)
		__w_list_free(cast(__w_list*, spans))
	mm_ee_scan_free(scan)
	mm_expect_free(x)
	mm_document_free(probe)
	return ok

# ER `||--o{` from cardinalities (0 zero/one, 1 one, 2 zero/many, 3 one/many).
char* mm_ee_er_operator(int left, int right, int dashed):
	if (left < 0 || left > 3 || right < 0 || right > 3): return 0
	list[char*] lefts = list[char*]{c"|o", c"||", c"}o", c"}|"}
	list[char*] rights = list[char*]{c"o|", c"||", c"o{", c"|{"}
	string_builder* s = string_from(lefts[left])
	if (dashed): string_append(s, c"..")
	else: string_append(s, c"--")
	string_append(s, rights[right])
	__w_list_free(cast(__w_list*, lefts))
	__w_list_free(cast(__w_list*, rights))
	char* result = s.data
	free(s)
	return result

int mm_ee_er_cardinality(mm_editor* e, int index, int left, int right, int dashed):
	char* operator = mm_ee_er_operator(left, right, dashed)
	if (operator == 0 || e.document.kind != MM_ER): return 0
	int ok = mm_ee_edge_kind(e, index, operator)
	free(operator)
	return ok

# ---------------------------------------------------------------- compartments

# The node's own `{ ... }` blocks (ER entity, class body, requirement).
list[int] mm_ee_body_units(mm_ee_scan* scan, int index):
	list[int] result = new list[int]
	mm_document* d = scan.d
	char* id = d.nodes[index].id
	for i in range(scan.units.length):
		mm_ee_unit* unit = scan.units[i]
		if (unit.opener != 1 || unit.closer < 0): continue
		int at = mm_ee_token(d, unit.code, unit.code_end, id, unit.code)
		if (at < 0): continue
		# The block belongs to id when id is its first name (after a keyword).
		int other = mm_ee_other_mention(d, unit, index)
		if (other >= 0 && mm_ee_token(d, unit.code, unit.code_end, d.nodes[other].id, unit.code) < at): continue
		result.push(i)
	return result

# A compartment line inside the node's blocks: insert before the last
# block's closer, else append a statement (`fallback`).
int mm_ee_compartment_insert(mm_editor* e, int index, char* line, char* fallback, mm_expect* x):
	mm_document* d = e.document
	mm_ee_scan* scan = mm_ee_scan_new(d)
	list[int] bodies = mm_ee_body_units(scan, index)
	int ok = 0
	if (bodies.length > 0):
		mm_ee_unit* unit = scan.units[bodies[bodies.length - 1]]
		char* indent = mm_ee_indent(d, unit.closer)
		string_builder* text = string_from(indent)
		string_append(text, c"    ")
		for mm_ee_unit* inner in scan.units:
			if (inner.parent == bodies[bodies.length - 1]):
				char* inner_indent = mm_ee_indent(d, inner.code)
				string_free(text)
				text = string_from(inner_indent)
				free(inner_indent)
		string_append(text, line)
		string_append_char(text, 10)
		ok = mm_ee_attempt_splice(e, unit.closer, unit.closer, text.data, x)
		string_free(text)
		free(indent)
	if (ok == 0 && fallback != 0): ok = mm_ee_attempt_append(e, fallback, x)
	__w_list_free(cast(__w_list*, bodies))
	mm_ee_scan_free(scan)
	return ok

# Remove or replace the compartment line whose text is `text` (trimmed) in
# the node's blocks, or a `Id : text` statement. replacement 0 removes.
int mm_ee_compartment_change(mm_editor* e, int index, char* text, char* replacement, mm_expect* x):
	mm_document* d = e.document
	mm_ee_scan* scan = mm_ee_scan_new(d)
	int ok = 0
	int length = strlen(text)
	for mm_ee_unit* unit in scan.units:
		if (ok || unit.header || unit.opener || x.attempts >= MM_EE_ATTEMPTS): continue
		int at = unit.code
		while (ok == 0 && at < unit.code_end):
			int found = index_of(d.source + at, text)
			if (found < 0 || at + found + length > unit.code_end): break
			int start = at + found
			if (replacement != 0): ok = mm_ee_attempt_splice(e, start, start + length, replacement, x)
			else: ok = mm_ee_attempt_splice(e, unit.start, unit.end, c"", x)
			at = start + 1
	mm_ee_scan_free(scan)
	return ok

char* mm_ee_attribute_text(char* type_name, char* name, char* keys, char* comment):
	string_builder* s = string_from(type_name)
	string_append_char(s, 32)
	string_append(s, name)
	if (keys != 0 && keys[0] != 0):
		string_append_char(s, 32)
		string_append(s, keys)
	if (comment != 0 && comment[0] != 0):
		string_append(s, c" \"")
		string_append(s, comment)
		string_append_char(s, '"')
	char* result = s.data
	free(s)
	return result

int mm_ee_attribute_word(char* text):
	if (text == 0 || text[0] == 0): return 0
	for i in range(strlen(text)):
		int c = text[i] & 255
		if (mm_id_char(c) == 0 && c != '-' && c != '(' && c != ')' && c != '[' && c != ']' && c != ',' && c != '*'): return 0
	return 1

int mm_ee_keys_safe(char* keys):
	if (keys == 0): return 1
	for i in range(strlen(keys)):
		int c = keys[i]
		if (c != 'P' && c != 'F' && c != 'U' && c != 'K' && c != ',' && c != 32): return 0
	return 1

# The expected node: a copy of n whose attribute list is `attributes`.
int mm_ee_attribute_commit(mm_editor* e, int index, list[mm_attribute*] attributes, int mode, int which, char* line):
	mm_document* d = e.document
	mm_node want = *d.nodes[index]
	want.attributes = attributes
	mm_expect* x = mm_expect_new(d)
	x.nodes[index] = &want
	int ok = 0
	if (mode == 0):
		string_builder* fallback = string_from(d.nodes[index].id)
		string_append(fallback, c" {\n    ")
		string_append(fallback, line)
		string_append(fallback, c"\n}")
		ok = mm_ee_compartment_insert(e, index, line, fallback.data, x)
		string_free(fallback)
	else:
		mm_attribute* a = d.nodes[index].attributes[which]
		char* old = mm_ee_attribute_text(a.type_name, a.name, a.keys, a.comment)
		char* bare = mm_ee_attribute_text(a.type_name, a.name, 0, 0)
		if (mode == 1):
			ok = mm_ee_compartment_change(e, index, old, 0, x)
			if (ok == 0): ok = mm_ee_compartment_change(e, index, bare, 0, x)
		else:
			ok = mm_ee_compartment_change(e, index, old, line, x)
			if (ok == 0 && (a.keys[0] == 0 && a.comment[0] == 0)): ok = mm_ee_compartment_change(e, index, bare, line, x)
		free(old)
		free(bare)
	mm_expect_free(x)
	return ok

# ER attributes: add at the end of the entity's block (or a new block).
int mm_ee_attribute_add(mm_editor* e, int index, char* type_name, char* name, char* keys, char* comment):
	mm_document* d = e.document
	if (d.error != 0 || d.kind != MM_ER || index < 0 || index >= d.nodes.length): return 0
	if (mm_ee_attribute_word(type_name) == 0 || mm_ee_attribute_word(name) == 0 || mm_ee_keys_safe(keys) == 0): return 0
	if (comment != 0 && mm_ee_text_safe(comment) == 0): return 0
	char* line = mm_ee_attribute_text(type_name, name, keys, comment)
	list[mm_attribute*] attributes = new list[mm_attribute*]
	for mm_attribute* a in d.nodes[index].attributes: attributes.push(a)
	mm_attribute added
	added.type_name = type_name
	added.name = name
	added.keys = keys
	if (keys == 0): added.keys = c""
	added.comment = comment
	if (comment == 0): added.comment = c""
	attributes.push(&added)
	int ok = mm_ee_attribute_commit(e, index, attributes, 0, -1, line)
	__w_list_free(cast(__w_list*, attributes))
	free(line)
	return ok

int mm_ee_attribute_remove(mm_editor* e, int index, int which):
	mm_document* d = e.document
	if (d.error != 0 || d.kind != MM_ER || index < 0 || index >= d.nodes.length): return 0
	if (which < 0 || which >= d.nodes[index].attributes.length): return 0
	list[mm_attribute*] attributes = new list[mm_attribute*]
	for i in range(d.nodes[index].attributes.length):
		if (i != which): attributes.push(d.nodes[index].attributes[i])
	int ok = mm_ee_attribute_commit(e, index, attributes, 1, which, 0)
	__w_list_free(cast(__w_list*, attributes))
	return ok

int mm_ee_attribute_set(mm_editor* e, int index, int which, char* type_name, char* name, char* keys, char* comment):
	mm_document* d = e.document
	if (d.error != 0 || d.kind != MM_ER || index < 0 || index >= d.nodes.length): return 0
	if (which < 0 || which >= d.nodes[index].attributes.length): return 0
	if (mm_ee_attribute_word(type_name) == 0 || mm_ee_attribute_word(name) == 0 || mm_ee_keys_safe(keys) == 0): return 0
	if (comment != 0 && mm_ee_text_safe(comment) == 0): return 0
	char* line = mm_ee_attribute_text(type_name, name, keys, comment)
	mm_attribute changed
	changed.type_name = type_name
	changed.name = name
	changed.keys = keys
	if (keys == 0): changed.keys = c""
	changed.comment = comment
	if (comment == 0): changed.comment = c""
	list[mm_attribute*] attributes = new list[mm_attribute*]
	for i in range(d.nodes[index].attributes.length):
		if (i == which): attributes.push(&changed)
		else: attributes.push(d.nodes[index].attributes[i])
	int ok = mm_ee_attribute_commit(e, index, attributes, 2, which, line)
	__w_list_free(cast(__w_list*, attributes))
	free(line)
	return ok

# Class members (and requirement `key: value` properties, which the model
# keeps as members). The member's kind (method or field) comes from a probe.
int mm_ee_member_probe(mm_document* d, char* text, int* method):
	string_builder* s = string_from(c"classDiagram\nclass P {\n")
	string_append(s, text)
	string_append(s, c"\n}\n")
	mm_document* probe = mm_parse(s.data, s.length)
	string_free(s)
	int ok = probe.error == 0 && probe.nodes.length == 1 && probe.nodes[0].members.length == 1 && strcmp(probe.nodes[0].members[0].text, text) == 0
	if (ok): *method = probe.nodes[0].members[0].method
	mm_document_free(probe)
	return ok

int mm_ee_member_commit(mm_editor* e, int index, list[mm_member*] members, int mode, char* old, char* text):
	mm_document* d = e.document
	mm_node want = *d.nodes[index]
	want.members = members
	mm_expect* x = mm_expect_new(d)
	x.nodes[index] = &want
	int ok = 0
	if (mode == 0):
		char* fallback = 0
		string_builder* statement = 0
		if (d.kind == MM_CLASS):
			statement = string_from(d.nodes[index].id)
			string_append(statement, c" : ")
			string_append(statement, text)
			fallback = statement.data
		ok = mm_ee_compartment_insert(e, index, text, fallback, x)
		if (statement != 0): string_free(statement)
	else if (mode == 1): ok = mm_ee_compartment_change(e, index, old, 0, x)
	else: ok = mm_ee_compartment_change(e, index, old, text, x)
	mm_expect_free(x)
	return ok

int mm_ee_member_allowed(mm_document* d, int index):
	if (d.error != 0 || index < 0 || index >= d.nodes.length): return 0
	if (d.kind == MM_CLASS): return d.nodes[index].group == 0 && d.nodes[index].shape != 28
	return d.kind == MM_REQUIREMENT

int mm_ee_member_add(mm_editor* e, int index, char* text):
	mm_document* d = e.document
	if (mm_ee_member_allowed(d, index) == 0 || mm_ee_text_safe(text) == 0 || text[0] == 0): return 0
	for i in range(strlen(text)):
		if (text[i] == '{' || text[i] == '}' || text[i] == ';'): return 0
	mm_member added
	added.text = text
	added.method = 0
	if (d.kind == MM_CLASS && mm_ee_member_probe(d, text, &added.method) == 0): return 0
	list[mm_member*] members = new list[mm_member*]
	for mm_member* m in d.nodes[index].members: members.push(m)
	members.push(&added)
	int ok = mm_ee_member_commit(e, index, members, 0, 0, text)
	__w_list_free(cast(__w_list*, members))
	return ok

int mm_ee_member_remove(mm_editor* e, int index, int which):
	mm_document* d = e.document
	if (mm_ee_member_allowed(d, index) == 0 || which < 0 || which >= d.nodes[index].members.length): return 0
	list[mm_member*] members = new list[mm_member*]
	for i in range(d.nodes[index].members.length):
		if (i != which): members.push(d.nodes[index].members[i])
	int ok = mm_ee_member_commit(e, index, members, 1, d.nodes[index].members[which].text, 0)
	__w_list_free(cast(__w_list*, members))
	return ok

int mm_ee_member_set(mm_editor* e, int index, int which, char* text):
	mm_document* d = e.document
	if (mm_ee_member_allowed(d, index) == 0 || which < 0 || which >= d.nodes[index].members.length): return 0
	if (mm_ee_text_safe(text) == 0 || text[0] == 0): return 0
	for i in range(strlen(text)):
		if (text[i] == '{' || text[i] == '}' || text[i] == ';'): return 0
	mm_member changed
	changed.text = text
	changed.method = 0
	if (d.kind == MM_CLASS && mm_ee_member_probe(d, text, &changed.method) == 0): return 0
	list[mm_member*] members = new list[mm_member*]
	for i in range(d.nodes[index].members.length):
		if (i == which): members.push(&changed)
		else: members.push(d.nodes[index].members[i])
	int ok = mm_ee_member_commit(e, index, members, 2, d.nodes[index].members[which].text, text)
	__w_list_free(cast(__w_list*, members))
	return ok
