# Structural graphical edits for indentation outlines (mindmap, treeView,
# kanban): rename, delete a subtree, add a child or sibling, reorder
# siblings and move a subtree under another parent (a kanban card into
# another column).
# Each edit splices whole lines (or a label inside one line) and is checked
# against the expected tree before it becomes one undo step. Outline node
# identities are positional, so the check compares the tree by position.
import libs.extras.mermaid.edit_engine

int mm_outline_family(int kind):
	return kind == MM_MINDMAP || kind == MM_TREEVIEW || kind == MM_KANBAN

int mm_oe_glyph(mm_document* d, int at, int end):
	if (at + 2 >= end || (d.source[at] & 255) != 0xE2 || (d.source[at + 1] & 255) != 0x94): return 0
	int last = d.source[at + 2] & 255
	return last == 0x82 || last == 0x9C || last == 0x94 || last == 0x80

# The offset where a line's label begins: after indentation and, in a
# treeView, `tree` command glyphs and no-break spaces.
int mm_oe_label_start(mm_document* d, int at, int end):
	while (at < end):
		int c = d.source[at] & 255
		if (c == 32 || c == 9): at = at + 1
		else if (d.kind == MM_TREEVIEW && mm_oe_glyph(d, at, end)): at = at + 3
		else if (d.kind == MM_TREEVIEW && c == 0xC2 && at + 1 < end && (d.source[at + 1] & 255) == 0xA0): at = at + 2
		else: return at
	return at

int mm_oe_starts(mm_document* d, int at, int end, char* word):
	int length = strlen(word)
	if (end - at < length): return 0
	for i in range(length):
		if (d.source[at + i] != word[i]): return 0
	return 1

# Start offsets of the lines that declare nodes, in node order, followed by
# the body end. Null when the lines cannot be matched to the parsed nodes.
list[int] mm_oe_lines(mm_document* d):
	if (d.error != 0 || mm_outline_family(d.kind) == 0): return 0
	list[int] lines = new list[int]
	int at = d.source_start
	int header = 1
	int description = 0
	while (at < d.source_end):
		int end = mm_ee_line_end(d, at)
		int next = end
		if (next < d.source_end): next = next + 1
		int code = at
		while (code < end && (d.source[code] == 32 || d.source[code] == 9 || d.source[code] == 13)): code = code + 1
		int label = mm_oe_label_start(d, at, end)
		if (description):
			for i in range(at, end):
				if (d.source[i] == '}'): description = 0
		else if (code >= end): description = 0
		else if (mm_oe_starts(d, code, end, c"%%")): description = 0
		else if (header): header = 0
		else if (d.kind == MM_MINDMAP && d.source[code] == ':'): description = 0
		else if (mm_oe_starts(d, code, end, c"accTitle") || mm_oe_starts(d, code, end, c"accDescr")):
			int braces = 0
			for i in range(code, end):
				if (d.source[i] == '{'): braces = braces + 1
				if (d.source[i] == '}'): braces = braces - 1
			if (braces > 0): description = 1
		else if (label < end && d.source[label] != 13): lines.push(at)
		at = next
	if (lines.length != d.nodes.length):
		__w_list_free(cast(__w_list*, lines))
		return 0
	lines.push(d.source_end)
	return lines

# One past the last node of index's subtree.
int mm_oe_subtree_end(mm_document* d, int index):
	int k = index + 1
	while (k < d.nodes.length && mm_position_within(d, k, index)): k = k + 1
	return k

# Expected outline: old node index per new position (-1 = the new node).
struct mm_oe_expect:
	list[int] order
	int changed
	char* label
	int new_parent
	# A reparented subtree root (old index) and its new parent (old index).
	int moved
	int moved_parent

int mm_oe_validate(mm_document* old, mm_document* next, mm_oe_expect* x):
	if (next.error != 0 || next.kind != old.kind || next.nodes.length != x.order.length): return 0
	for k in range(x.order.length):
		mm_node* have = next.nodes[k]
		int was = x.order[k]
		int parent = -1
		if (have.parent >= 0):
			if (have.parent >= x.order.length): return 0
			parent = x.order[have.parent]
			if (parent < 0): return 0
		if (was < 0):
			if (strcmp(have.label, x.label) != 0 || have.shape != 0 || parent != x.new_parent): return 0
			continue
		mm_node want = *old.nodes[was]
		if (was == x.changed): want.label = x.label
		if (mm_ee_node_equal(&want, have) == 0): return 0
		int want_parent = old.nodes[was].parent
		if (was == x.moved): want_parent = x.moved_parent
		if (parent != want_parent): return 0
		if (have.parent < 0 && want_parent >= 0): return 0
	if (strcmp(old.title, next.title) != 0 || strcmp(old.accessibility_title, next.accessibility_title) != 0 || strcmp(old.accessibility_description, next.accessibility_description) != 0): return 0
	return 1

mm_oe_expect* mm_oe_expect_new(mm_document* d):
	mm_oe_expect* x = new mm_oe_expect()
	x.order = new list[int]
	for i in range(d.nodes.length): x.order.push(i)
	x.changed = -1
	x.label = c""
	x.new_parent = -1
	x.moved = -1
	x.moved_parent = -1
	return x

void mm_oe_expect_free(mm_oe_expect* x):
	__w_list_free(cast(__w_list*, x.order))
	free(x)

int mm_oe_attempt(mm_editor* e, list[mm_ee_splice*] edits, mm_oe_expect* x):
	char* source = mm_ee_apply(e.document, edits)
	if (source == 0): return 0
	int ok = 0
	if (strlen(source) <= MM_MAX_SOURCE):
		mm_document* next = mm_parse_selected(source, strlen(source), e.selected)
		ok = mm_oe_validate(e.document, next, x)
		mm_document_free(next)
		if (ok): ok = mm_editor_change(e, source)
	free(source)
	return ok

int mm_oe_label_safe(mm_document* d, char* label):
	if (mm_ee_text_safe(label) == 0 || label[0] == 0 || label[0] == 32 || label[strlen(label) - 1] == 32): return 0
	for i in range(strlen(label)):
		int c = label[i]
		if (c == '[' || c == ']' || c == '(' || c == ')' || c == '{' || c == '}' || c == ':' || c == '#' || c == '@'): return 0
	return 1

# Replace the label bytes inside the node's own line.
int mm_outline_rename(mm_editor* e, int index, char* label):
	mm_document* d = e.document
	if (index < 0 || index >= d.nodes.length || mm_oe_label_safe(d, label) == 0): return 0
	if (strcmp(d.nodes[index].label, label) == 0): return 1
	list[int] lines = mm_oe_lines(d)
	if (lines == 0): return 0
	mm_oe_expect* x = mm_oe_expect_new(d)
	x.changed = index
	x.label = label
	int start = mm_oe_label_start(d, lines[index], mm_ee_line_end(d, lines[index]))
	int end = mm_ee_line_end(d, lines[index])
	char* old = d.nodes[index].label
	int length = strlen(old)
	int ok = 0
	int at = start
	int tries = 0
	while (ok == 0 && length > 0 && at + length <= end && tries < 32):
		int found = index_of(d.source + at, old)
		if (found < 0 || at + found + length > end): break
		list[mm_ee_splice*] edits = mm_ee_splices()
		mm_ee_add(edits, at + found, at + found + length, label)
		ok = mm_oe_attempt(e, edits, x)
		mm_ee_splices_free(edits)
		at = at + found + 1
		tries = tries + 1
	mm_oe_expect_free(x)
	__w_list_free(cast(__w_list*, lines))
	return ok

int mm_outline_delete(mm_editor* e, int index):
	mm_document* d = e.document
	if (index < 0 || index >= d.nodes.length): return 0
	# A mindmap has exactly one root.
	if (d.kind == MM_MINDMAP && index == 0): return 0
	list[int] lines = mm_oe_lines(d)
	if (lines == 0): return 0
	int last = mm_oe_subtree_end(d, index)
	mm_oe_expect* x = mm_oe_expect_new(d)
	while (x.order.length > 0): x.order.pop()
	for i in range(d.nodes.length):
		if (i < index || i >= last): x.order.push(i)
	list[mm_ee_splice*] edits = mm_ee_splices()
	mm_ee_add(edits, lines[index], lines[last], c"")
	int ok = mm_oe_attempt(e, edits, x)
	mm_ee_splices_free(edits)
	mm_oe_expect_free(x)
	__w_list_free(cast(__w_list*, lines))
	return ok

# The prefix of a new child line of index: the existing first child's, or
# the parent's indentation one level deeper (a `tree` branch for glyphs).
char* mm_oe_child_prefix(mm_document* d, list[int] lines, int index):
	if (index + 1 < d.nodes.length && d.nodes[index + 1].parent == index):
		int start = lines[index + 1]
		return str_copy_range(d.source, start, mm_oe_label_start(d, start, mm_ee_line_end(d, start)))
	# Kanban indentation levels are shared: an empty column's first card is
	# indented like the cards of the other columns.
	if (d.kind == MM_KANBAN):
		for i in range(d.nodes.length):
			if (d.nodes[i].parent >= 0):
				int start = lines[i]
				return str_copy_range(d.source, start, mm_oe_label_start(d, start, mm_ee_line_end(d, start)))
	int start = lines[index]
	int label = mm_oe_label_start(d, start, mm_ee_line_end(d, start))
	string_builder* s = string_new()
	int glyphs = 0
	int at = start
	while (at < label):
		if (mm_oe_glyph(d, at, label)):
			glyphs = 1
			int kind = d.source[at + 2] & 255
			# `├`/`└` become a continuation for the deeper level; `─` padding goes.
			if (kind == 0x9C): string_append(s, c"│")
			else if (kind == 0x94): string_append(s, c" ")
			else if (kind == 0x82): string_append(s, c"│")
			else: string_append_char(s, 32)
			at = at + 3
		else:
			string_append_char(s, d.source[at])
			at = at + 1
	if (glyphs): string_append(s, c"└── ")
	else: string_append(s, c"    ")
	char* result = s.data
	free(s)
	return result

# kind 0: last child of index; kind 1: the sibling right after index.
int mm_outline_add(mm_editor* e, int index, char* label, int kind):
	mm_document* d = e.document
	if (index < 0 || index >= d.nodes.length || mm_oe_label_safe(d, label) == 0): return 0
	if (kind == 1 && d.kind == MM_MINDMAP && d.nodes[index].parent < 0): return 0
	list[int] lines = mm_oe_lines(d)
	if (lines == 0): return 0
	int last = mm_oe_subtree_end(d, index)
	char* prefix = 0
	if (kind == 0): prefix = mm_oe_child_prefix(d, lines, index)
	else: prefix = str_copy_range(d.source, lines[index], mm_oe_label_start(d, lines[index], mm_ee_line_end(d, lines[index])))
	string_builder* text = string_new()
	int at = lines[last]
	# Appending after the final line: make sure the previous line ends.
	if (at == d.source_end && at > d.source_start && d.source[at - 1] != 10): mm_append_newline(text, d)
	string_append(text, prefix)
	string_append(text, label)
	mm_append_newline(text, d)
	mm_oe_expect* x = mm_oe_expect_new(d)
	while (x.order.length > 0): x.order.pop()
	for i in range(d.nodes.length):
		if (i == last): x.order.push(-1)
		x.order.push(i)
	if (last == d.nodes.length): x.order.push(-1)
	x.label = label
	x.new_parent = index
	if (kind == 1): x.new_parent = d.nodes[index].parent
	list[mm_ee_splice*] edits = mm_ee_splices()
	mm_ee_add(edits, at, at, text.data)
	int ok = mm_oe_attempt(e, edits, x)
	mm_ee_splices_free(edits)
	mm_oe_expect_free(x)
	string_free(text)
	free(prefix)
	__w_list_free(cast(__w_list*, lines))
	return ok

# Swap index's subtree with its previous (up) or next sibling's subtree.
int mm_outline_reorder(mm_editor* e, int index, int up):
	mm_document* d = e.document
	if (index < 0 || index >= d.nodes.length): return 0
	int parent = d.nodes[index].parent
	int other = -1
	if (up):
		for i in range(index):
			if (d.nodes[i].parent == parent): other = i
	else:
		int k = mm_oe_subtree_end(d, index)
		if (k < d.nodes.length && d.nodes[k].parent == parent): other = k
	if (other < 0): return 0
	int first = index
	int second = other
	if (up):
		first = other
		second = index
	list[int] lines = mm_oe_lines(d)
	if (lines == 0): return 0
	int first_end = mm_oe_subtree_end(d, first)
	int second_end = mm_oe_subtree_end(d, second)
	if (first_end != second):
		__w_list_free(cast(__w_list*, lines))
		return 0
	char* a = str_copy_range(d.source, lines[first], lines[second])
	char* b = str_copy_range(d.source, lines[second], lines[second_end])
	# A final line without a newline moves into the middle: give it one.
	string_builder* moved = string_from(b)
	if (moved.length > 0 && moved.data[moved.length - 1] != 10): mm_append_newline(moved, d)
	string_append(moved, a)
	if (lines[second_end] == d.source_end && b[0] != 0 && b[strlen(b) - 1] != 10 && moved.length > 0 && moved.data[moved.length - 1] == 10): mm_strip_newline(moved)
	mm_oe_expect* x = mm_oe_expect_new(d)
	while (x.order.length > 0): x.order.pop()
	for i in range(first): x.order.push(i)
	for i in range(second, second_end): x.order.push(i)
	for i in range(first, second): x.order.push(i)
	for i in range(second_end, d.nodes.length): x.order.push(i)
	list[mm_ee_splice*] edits = mm_ee_splices()
	mm_ee_add(edits, lines[first], lines[second_end], moved.data)
	int ok = mm_oe_attempt(e, edits, x)
	mm_ee_splices_free(edits)
	mm_oe_expect_free(x)
	string_free(moved)
	free(a)
	free(b)
	__w_list_free(cast(__w_list*, lines))
	return ok

# Move index's subtree to the end of parent's children (a kanban card into
# another column, a mindmap branch under another node). The subtree's lines
# keep their relative indentation under the new parent's child prefix;
# treeView glyph prefixes move only a single line.
int mm_outline_reparent(mm_editor* e, int index, int parent):
	mm_document* d = e.document
	if (index < 0 || index >= d.nodes.length || parent < 0 || parent >= d.nodes.length): return 0
	if (parent == index || mm_position_within(d, parent, index) || d.nodes[index].parent == parent): return 0
	if (d.kind == MM_MINDMAP && d.nodes[index].parent < 0): return 0
	# Kanban columns hold cards; a column does not nest.
	if (d.kind == MM_KANBAN && (d.nodes[parent].parent >= 0 || d.nodes[index].parent < 0)): return 0
	list[int] lines = mm_oe_lines(d)
	if (lines == 0): return 0
	int last = mm_oe_subtree_end(d, index)
	int root_start = lines[index]
	int root_label = mm_oe_label_start(d, root_start, mm_ee_line_end(d, root_start))
	char* old_prefix = str_copy_range(d.source, root_start, root_label)
	char* new_prefix = mm_oe_child_prefix(d, lines, parent)
	int ok = 1
	for i in range(root_label - root_start):
		if (old_prefix[i] != 32 && old_prefix[i] != 9): ok = 0
	if (d.kind == MM_TREEVIEW && last != index + 1): ok = 0
	string_builder* text = string_new()
	for k in range(index, last):
		if (ok == 0): break
		int start = lines[k]
		int end = lines[k + 1]
		int length = strlen(old_prefix)
		if (end - start < length):
			ok = 0
			break
		for j in range(length):
			if (d.source[start + j] != old_prefix[j]): ok = 0
		if (ok == 0): break
		string_append(text, new_prefix)
		string_append_bytes(text, d.source + start + strlen(old_prefix), end - start - strlen(old_prefix))
	if (ok && text.length > 0 && text.data[text.length - 1] != 10): mm_append_newline(text, d)
	int target = mm_oe_subtree_end(d, parent)
	if (ok && target > index && target < last): ok = 0
	int at = lines[target]
	string_builder* inserted = string_new()
	if (ok && at == d.source_end && at != lines[last] && at > d.source_start && d.source[at - 1] != 10): mm_append_newline(inserted, d)
	string_append_bytes(inserted, text.data, text.length)
	mm_oe_expect* x = mm_oe_expect_new(d)
	while (x.order.length > 0): x.order.pop()
	for i in range(d.nodes.length + 1):
		if (i == target):
			for k in range(index, last): x.order.push(k)
		if (i < d.nodes.length && (i < index || i >= last)): x.order.push(i)
	x.moved = index
	x.moved_parent = parent
	if (ok):
		list[mm_ee_splice*] edits = mm_ee_splices()
		# Removing the final line of the body takes its preceding newline
		# when it has none of its own.
		mm_ee_add(edits, lines[index], lines[last], c"")
		mm_ee_add(edits, at, at, inserted.data)
		ok = mm_oe_attempt(e, edits, x)
		mm_ee_splices_free(edits)
	mm_oe_expect_free(x)
	string_free(text)
	string_free(inserted)
	free(old_prefix)
	free(new_prefix)
	__w_list_free(cast(__w_list*, lines))
	return ok
