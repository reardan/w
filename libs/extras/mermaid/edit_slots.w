# Graphical moves for families whose layout is their source order.
#
# A block diagram is a grid filled in statement order (upstream's
# `columns N` rows), so moving a block means moving it to another cell of
# its composite: adjacent siblings swap their source items, one validated
# splice per step. Resizing a block changes its column span (`id:N`).
# Outlines (mindmap, treeView, kanban) move a subtree among its siblings
# (mm_outline_reorder) or under another parent (mm_outline_reparent); a
# kanban card moves into another column. No coordinates are stored, so
# the source stays meaningful to every Mermaid renderer.
import libs.extras.mermaid.edit_outline

# Siblings of index (same parent), in node order; caller frees.
list[int] mm_slot_siblings(mm_document* d, int index):
	list[int] result = new list[int]
	int parent = d.nodes[index].parent
	for i in range(d.nodes.length):
		if (d.nodes[i].parent == parent): result.push(i)
	return result

int mm_slot_position(list[int] items, int index):
	for i in range(items.length):
		if (items[i] == index): return i
	return -1

# ---------------------------------------------------------------- block cells

int mm_bs_link_char(int c):
	return c == '-' || c == '=' || c == '>' || c == '<' || c == '|' || c == '.' || c == ':' || c == '&'

# The source of one block cell: an inline span (a leaf or `space` item,
# without trailing blanks) and, when it is alone on its line or is a
# composite `block:id ... end`, the whole-line range. 0 when the item is
# only named by a link or cannot be located.
int mm_bs_locate(mm_ee_scan* scan, int index, int* start, int* end, int* whole_start, int* whole_end):
	mm_document* d = scan.d
	mm_node* n = d.nodes[index]
	*start = -1
	*end = -1
	*whole_start = -1
	*whole_end = -1
	if (n.group):
		if (mm_position_identity(n.id) == 0): return 0
		int u = mm_ee_group_unit(scan, index)
		if (u < 0): return 0
		*whole_start = scan.units[u].start
		*whole_end = scan.units[u].end
		return 1
	char* word = n.id
	int rank = 0
	if (n.shape == -1):
		# `space` items are numbered by rank among the spaces.
		word = c"space"
		for i in range(index):
			if (d.nodes[i].shape == -1 && d.nodes[i].group == 0): rank = rank + 1
	else if (mm_position_identity(n.id) == 0): return 0
	for mm_ee_unit* unit in scan.units:
		if (unit.header): continue
		int at = mm_ee_token(d, unit.code, unit.code_end, word, unit.code)
		while (at >= 0 && rank > 0):
			rank = rank - 1
			at = mm_ee_token(d, unit.code, unit.code_end, word, at + 1)
		if (at < 0): continue
		int stop = mm_ee_item_end(d, at, unit.code_end, word)
		while (stop > at && (d.source[stop - 1] == 32 || d.source[stop - 1] == 9)): stop = stop - 1
		# A first mention inside a link (`a --> b`) is not a cell of its own.
		int before = at
		while (before > unit.code && (d.source[before - 1] == 32 || d.source[before - 1] == 9)): before = before - 1
		if (before > unit.code && mm_bs_link_char(d.source[before - 1])): return 0
		int after = stop
		while (after < unit.code_end && (d.source[after] == 32 || d.source[after] == 9)): after = after + 1
		if (after < unit.code_end && mm_bs_link_char(d.source[after])): return 0
		*start = at
		*end = stop
		if (unit.opener == 0 && at == unit.code && stop == unit.code_end):
			*whole_start = unit.start
			*whole_end = unit.end
		return 1
	return 0

# Commit candidate edits when the reparse keeps every node, edge and style
# (by identity) and, for a swap, puts b before a. Owns nothing.
int mm_bs_attempt(mm_editor* e, list[mm_ee_splice*] edits, mm_expect* x, int a, int b):
	char* source = mm_ee_apply(e.document, edits)
	if (source == 0): return 0
	int ok = 0
	if (strlen(source) <= MM_MAX_SOURCE):
		mm_document* next = mm_parse_selected(source, strlen(source), e.selected)
		ok = mm_ee_validate(e.document, next, x)
		if (ok && a >= 0 && b >= 0):
			int ja = mm_ee_find(e.document, a, next, x)
			int jb = mm_ee_find(e.document, b, next, x)
			ok = ja >= 0 && jb >= 0 && jb < ja
		mm_document_free(next)
		if (ok): ok = mm_editor_change(e, source)
	free(source)
	return ok

# Whole-line text placed where a range without a final newline was, or
# the reverse: every moved line keeps exactly one line ending.
char* mm_bs_line_text(mm_document* d, int start, int end, int into_end):
	string_builder* text = string_new()
	string_append_bytes(text, d.source + start, end - start)
	if (text.length > 0 && text.data[text.length - 1] != 10 && into_end == 0): string_append_char(text, 10)
	if (into_end && text.length > 0 && text.data[text.length - 1] == 10 && d.source[d.source_end - 1] != 10):
		text.length = text.length - 1
		text.data[text.length] = 0
	char* result = text.data
	free(text)
	return result

# The cell [start, end) as a line of its own, indented like its line.
char* mm_bs_own_line(mm_document* d, int start, int end):
	int line = start
	while (line > d.source_start && d.source[line - 1] != 10): line = line - 1
	int code = line
	while (code < start && (d.source[code] == 32 || d.source[code] == 9)): code = code + 1
	string_builder* text = string_new()
	string_append_bytes(text, d.source + line, code - line)
	string_append_bytes(text, d.source + start, end - start)
	string_append_char(text, 10)
	char* result = text.data
	free(text)
	return result

# Swap adjacent sibling cells a (earlier) and b.
int mm_bs_swap(mm_editor* e, int a, int b):
	mm_document* d = e.document
	mm_ee_scan* scan = mm_ee_scan_new(d)
	int as = 0
	int ae = 0
	int aws = 0
	int awe = 0
	int bs = 0
	int be = 0
	int bws = 0
	int bwe = 0
	int found = mm_bs_locate(scan, a, &as, &ae, &aws, &awe) && mm_bs_locate(scan, b, &bs, &be, &bws, &bwe)
	mm_ee_scan_free(scan)
	if (found == 0): return 0
	list[mm_ee_splice*] edits = mm_ee_splices()
	int ok = 0
	if (as >= 0 && bs >= 0 && ae <= bs):
		char* ta = str_copy_range(d.source, as, ae)
		char* tb = str_copy_range(d.source, bs, be)
		mm_ee_add(edits, as, ae, tb)
		mm_ee_add(edits, bs, be, ta)
		free(ta)
		free(tb)
		ok = 1
	else if (aws >= 0 && bws >= 0 && awe <= bws):
		char* ta = mm_bs_line_text(d, aws, awe, bwe == d.source_end)
		char* tb = mm_bs_line_text(d, bws, bwe, 0)
		mm_ee_add(edits, aws, awe, tb)
		mm_ee_add(edits, bws, bwe, ta)
		free(ta)
		free(tb)
		ok = 1
	else if (as >= 0 && bws >= 0 && aws < 0 && ae <= bws):
		# A cell sharing its line, then a composite: the cell leaves the end
		# of its line and follows the composite on a line of its own.
		int cut = as
		while (cut > d.source_start && (d.source[cut - 1] == 32 || d.source[cut - 1] == 9)): cut = cut - 1
		char* line = mm_bs_own_line(d, as, ae)
		mm_ee_add(edits, cut, ae, c"")
		if (bwe == d.source_end && d.source[bwe - 1] != 10):
			string_builder* text = string_from(c"\n")
			string_append_bytes(text, line, strlen(line) - 1)
			mm_ee_add(edits, bwe, bwe, text.data)
			string_free(text)
		else: mm_ee_add(edits, bwe, bwe, line)
		free(line)
		ok = 1
	else if (aws >= 0 && bs >= 0 && bws < 0 && awe <= bs):
		# A composite, then a cell starting its line: the cell moves to a
		# line of its own before the composite.
		int cut = be
		while (cut < d.source_end && (d.source[cut] == 32 || d.source[cut] == 9)): cut = cut + 1
		char* line = mm_bs_own_line(d, bs, be)
		mm_ee_add(edits, aws, aws, line)
		mm_ee_add(edits, bs, cut, c"")
		free(line)
		ok = 1
	if (ok):
		mm_expect* x = mm_expect_new(d)
		ok = mm_bs_attempt(e, edits, x, a, b)
		mm_expect_free(x)
	mm_ee_splices_free(edits)
	return ok

# The block with id at its current index (indices shift with each swap).
int mm_bs_step(mm_editor* e, char* id, int forward):
	int index = mm_find_node(e.document, id)
	if (index < 0): return 0
	list[int] siblings = mm_slot_siblings(e.document, index)
	int at = mm_slot_position(siblings, index)
	int ok = 0
	if (forward && at + 1 < siblings.length): ok = mm_bs_swap(e, index, siblings[at + 1])
	else if (forward == 0 && at > 0): ok = mm_bs_swap(e, siblings[at - 1], index)
	__w_list_free(cast(__w_list*, siblings))
	return ok

# ---------------------------------------------------------------- outlines

# Move an outline subtree one sibling earlier (up) or later; returns its new
# index, or -1.
int mm_os_step(mm_editor* e, int index, int up):
	mm_document* d = e.document
	int parent = d.nodes[index].parent
	int moved = -1
	if (up):
		for i in range(index):
			if (d.nodes[i].parent == parent): moved = i
	else:
		int next = mm_oe_subtree_end(d, index)
		if (next < d.nodes.length && d.nodes[next].parent == parent): moved = index + mm_oe_subtree_end(d, next) - next
	if (moved < 0 || mm_outline_reorder(e, index, up) == 0): return -1
	return moved

# ---------------------------------------------------------------- commands

# Move index by delta sibling slots (negative: earlier) as one undo step.
int mm_editor_slot_step(mm_editor* e, int index, int delta):
	mm_editor_move_cancel(e)
	if (mm_slot_movable(e.document, index) == 0 || delta == 0): return 0
	mm_editor_begin(e)
	int ok = 1
	int count = delta
	if (count < 0): count = 0 - count
	if (e.document.kind == MM_BLOCK):
		char* id = strclone(e.document.nodes[index].id)
		for k in range(count):
			if (ok): ok = mm_bs_step(e, id, delta > 0)
		free(id)
	else:
		int at = index
		for k in range(count):
			if (ok):
				at = mm_os_step(e, at, delta < 0)
				ok = at >= 0
	if (ok): mm_editor_commit(e)
	else: mm_editor_rollback(e)
	return ok

# Move index to target's cell or slot: a sibling target takes index's
# place in the order; an outline target in another branch becomes the new
# parent (kanban: the target's column, before the target card).
int mm_editor_slot_move(mm_editor* e, int index, int target):
	mm_editor_move_cancel(e)
	mm_document* d = e.document
	if (mm_slot_movable(d, index) == 0 || target < 0 || target >= d.nodes.length || target == index): return 0
	if (mm_position_within(d, target, index)): return 0
	if (d.nodes[target].parent == d.nodes[index].parent):
		list[int] siblings = mm_slot_siblings(d, index)
		int delta = mm_slot_position(siblings, target) - mm_slot_position(siblings, index)
		__w_list_free(cast(__w_list*, siblings))
		return mm_editor_slot_step(e, index, delta)
	if (d.kind == MM_BLOCK): return 0
	int parent = target
	int before = -1
	if (d.kind == MM_KANBAN && d.nodes[target].parent >= 0):
		parent = d.nodes[target].parent
		# Cards have no subtrees: the target shifts up when index left from before it.
		before = target
		if (index < target): before = target - 1
	mm_editor_begin(e)
	int moved_parent = parent
	if (index < parent): moved_parent = parent - 1
	int ok = mm_outline_reparent(e, index, parent)
	if (ok && before >= 0):
		# Reparented as the column's last card; step up to the target's slot.
		int at = mm_oe_subtree_end(e.document, moved_parent) - 1
		while (ok && at > before):
			at = mm_os_step(e, at, 1)
			ok = at >= 0
	if (ok): mm_editor_commit(e)
	else: mm_editor_rollback(e)
	return ok

# Kanban: a card moves to the previous/next column (as its last card); a
# column moves among the columns.
int mm_editor_slot_column(mm_editor* e, int index, int delta):
	mm_document* d = e.document
	if (d.kind != MM_KANBAN || mm_slot_movable(d, index) == 0): return 0
	if (d.nodes[index].parent < 0): return mm_editor_slot_step(e, index, delta)
	list[int] columns = new list[int]
	for i in range(d.nodes.length):
		if (d.nodes[i].parent < 0): columns.push(i)
	int at = mm_slot_position(columns, d.nodes[index].parent) + delta
	int ok = 0
	if (at >= 0 && at < columns.length):
		mm_editor_move_cancel(e)
		ok = mm_outline_reparent(e, index, columns[at])
	__w_list_free(cast(__w_list*, columns))
	return ok

# A block leaf's column span (`id:N`; 1 drops the suffix). Spans wider than
# the composite's columns fail validation and change nothing.
int mm_editor_block_span(mm_editor* e, int index, int span):
	mm_editor_move_cancel(e)
	mm_document* d = e.document
	if (mm_slot_resizable(d, index) == 0 || span < 1 || span > 64): return 0
	if (d.nodes[index].value_x == span): return 1
	mm_ee_scan* scan = mm_ee_scan_new(d)
	int start = 0
	int end = 0
	int ws = 0
	int we = 0
	int found = mm_bs_locate(scan, index, &start, &end, &ws, &we)
	mm_ee_scan_free(scan)
	if (found == 0 || start < 0): return 0
	# An existing `:N` suffix: digits, then a single colon.
	int digits = end
	while (digits > start && d.source[digits - 1] >= '0' && d.source[digits - 1] <= '9'): digits = digits - 1
	int suffix = end
	if (digits < end && digits - 1 > start && d.source[digits - 1] == ':' && d.source[digits - 2] != ':'): suffix = digits - 1
	string_builder* text = string_new()
	if (span > 1):
		string_append_char(text, ':')
		string_append_int(text, span)
	list[mm_ee_splice*] edits = mm_ee_splices()
	mm_ee_add(edits, suffix, end, text.data)
	mm_node* want = new mm_node()
	*want = *d.nodes[index]
	want.value_x = span
	mm_expect* x = mm_expect_new(d)
	x.nodes[index] = want
	int ok = mm_bs_attempt(e, edits, x, -1, -1)
	mm_expect_free(x)
	free(want)
	mm_ee_splices_free(edits)
	string_free(text)
	return ok

# The span a resize gesture's width asks for: the cell's width per column
# (columns are at least 180 wide with 40 gaps) scaled to the new width.
int mm_editor_block_span_for(mm_editor* e, int index, int old_width, int width):
	int span = e.document.nodes[index].value_x
	if (span < 1): span = 1
	int unit = (old_width + 40) / span
	if (unit < 1): unit = 1
	int next = (width + 40 + unit / 2) / unit
	if (next < 1): next = 1
	return next
