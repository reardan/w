# Graphical moves for families whose layout is their source order.
#
# A block diagram is a grid filled in statement order (upstream's
# `columns N` rows), so moving a block means moving it to another cell of
# its composite: adjacent siblings swap their source items, one validated
# splice per step. Resizing a block changes its column span (`id:N`, or
# `block:id:N` for a composite).
# Outlines (mindmap, treeView, kanban) move a subtree among its siblings
# (mm_outline_reorder) or under another parent (mm_outline_reparent); a
# kanban card moves into another column. No coordinates are stored, so
# the source stays meaningful to every Mermaid renderer. A multi-selection
# moves as one transaction of such steps (mm_editor_slot_move_set).
import libs.extras.mermaid.edit_outline

# The moved item's index after the last successful slot command, so a
# selection can follow it (indices shift as the source is reordered).
int mm_slot_moved

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
	if (text.length > 0 && text.data[text.length - 1] != 10 && into_end == 0): mm_append_newline(text, d)
	if (into_end && text.length > 0 && text.data[text.length - 1] == 10 && d.source[d.source_end - 1] != 10): mm_strip_newline(text)
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
	mm_append_newline(text, d)
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
			string_builder* text = string_new()
			mm_append_newline(text, d)
			string_builder* bare = string_from(line)
			mm_strip_newline(bare)
			string_append(text, bare.data)
			string_free(bare)
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
		if (ok): mm_slot_moved = mm_find_node(e.document, id)
		free(id)
	else:
		int at = index
		for k in range(count):
			if (ok):
				at = mm_os_step(e, at, delta < 0)
				ok = at >= 0
		if (ok): mm_slot_moved = at
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
	int size = mm_oe_subtree_end(d, index) - index
	int moved_parent = parent
	if (index < parent): moved_parent = parent - size
	int ok = mm_outline_reparent(e, index, parent)
	int at = -1
	if (ok): at = mm_oe_subtree_end(e.document, moved_parent) - size
	if (ok && before >= 0):
		# Reparented as the column's last card; step up to the target's slot.
		while (ok && at > before):
			at = mm_os_step(e, at, 1)
			ok = at >= 0
	if (ok): mm_slot_moved = at
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
		int column = columns[at]
		ok = mm_outline_reparent(e, index, column)
		if (index < column): column = column - 1
		if (ok): mm_slot_moved = mm_oe_subtree_end(e.document, column) - 1
	__w_list_free(cast(__w_list*, columns))
	return ok

# A block's column span: a leaf's `id:N`, a composite's `block:id:N`.
int mm_block_span_of(mm_document* d, int index):
	int span = d.nodes[index].value_x
	if (d.nodes[index].group): span = d.nodes[index].value_y
	if (span < 1): span = 1
	return span

# The `:N` suffix range after a composite's `block:id` header ([id end,
# suffix end), empty when it has none). 0 when the header is not that shape.
int mm_bs_composite_suffix(mm_document* d, int index, int* start, int* end):
	mm_ee_scan* scan = mm_ee_scan_new(d)
	int u = mm_ee_group_unit(scan, index)
	int found = 0
	if (u >= 0):
		mm_ee_unit* unit = scan.units[u]
		char* id = d.nodes[index].id
		int at = unit.code + 5
		if (mm_ee_word_is(d, unit.code, unit.code + 5, c"block") && at < unit.code_end && d.source[at] == ':' && mm_ee_word_is(d, at + 1, unit.code_end, id)):
			int stop = at + 1 + strlen(id)
			*start = stop
			*end = stop
			int p = stop
			while (p < unit.code_end && (d.source[p] == 32 || d.source[p] == 9)): p = p + 1
			if (p < unit.code_end && d.source[p] == ':'):
				p = p + 1
				while (p < unit.code_end && (d.source[p] == 32 || d.source[p] == 9)): p = p + 1
				int digits = p
				while (p < unit.code_end && d.source[p] >= '0' && d.source[p] <= '9'): p = p + 1
				if (p > digits): *end = p
			found = 1
	mm_ee_scan_free(scan)
	return found

# A block's column span (`id:N`, or `block:id:N` for a composite; 1 drops
# the suffix). Spans wider than the parent's columns fail validation and
# change nothing.
int mm_editor_block_span(mm_editor* e, int index, int span):
	mm_editor_move_cancel(e)
	mm_document* d = e.document
	if (mm_slot_resizable(d, index) == 0 || span < 1 || span > 64): return 0
	if (mm_block_span_of(d, index) == span): return 1
	int suffix = 0
	int end = 0
	if (d.nodes[index].group):
		if (mm_bs_composite_suffix(d, index, &suffix, &end) == 0): return 0
	else:
		mm_ee_scan* scan = mm_ee_scan_new(d)
		int start = 0
		int ws = 0
		int we = 0
		int found = mm_bs_locate(scan, index, &start, &end, &ws, &we)
		mm_ee_scan_free(scan)
		if (found == 0 || start < 0): return 0
		# An existing `:N` suffix: digits, then a single colon.
		int digits = end
		while (digits > start && d.source[digits - 1] >= '0' && d.source[digits - 1] <= '9'): digits = digits - 1
		suffix = end
		if (digits < end && digits - 1 > start && d.source[digits - 1] == ':' && d.source[digits - 2] != ':'): suffix = digits - 1
	string_builder* text = string_new()
	if (span > 1):
		string_append_char(text, ':')
		string_append_int(text, span)
	list[mm_ee_splice*] edits = mm_ee_splices()
	mm_ee_add(edits, suffix, end, text.data)
	mm_node* want = new mm_node()
	*want = *d.nodes[index]
	if (want.group): want.value_y = span
	else: want.value_x = span
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
	int span = mm_block_span_of(e.document, index)
	int unit = (old_width + 40) / span
	if (unit < 1): unit = 1
	int next = (width + 40 + unit / 2) / unit
	if (next < 1): next = 1
	return next

# ---------------------------------------------------------------- multi-selection
#
# A multi-selection moves as one transaction (one undo step, rolled back
# whole on any refusal) of the single-item steps above, so every
# intermediate source is validated like a single move. Items inside another
# selected item (a card of a selected column, a branch under a selected
# branch, a member of a selected composite) ride along with it. The moved
# items keep their relative (source) order:
# - siblings dropped on a sibling move as one contiguous run that takes the
#   target's place: after it when the target follows the dragged item,
#   before it otherwise (block cells, outline siblings, kanban cards of one
#   column, kanban columns);
# - outline items dropped on a node of another branch become that node's
#   last children; kanban cards dropped on another column become its last
#   cards, and dropped on a card of another column land before that card.

# Adjacent sibling swaps one multi-selection command may spend.
const int MM_SLOT_SWAPS = 512

# Every moved item's index after the last successful set command, in order.
list[int] mm_slot_moved_set

void mm_slot_moved_reset():
	if (mm_slot_moved_set == 0): mm_slot_moved_set = new list[int]
	while (mm_slot_moved_set.length > 0): mm_slot_moved_set.pop()

# The children of parent (-1: the top level), in node order; caller frees.
list[int] mm_slot_children(mm_document* d, int parent):
	list[int] result = new list[int]
	for i in range(d.nodes.length):
		if (d.nodes[i].parent == parent): result.push(i)
	return result

# Index maps of the outline primitives. A swap of the adjacent subtrees
# [first, second) and [second, second_end):
int mm_slot_map_swap(int i, int first, int second, int second_end):
	if (i >= first && i < second): return i + second_end - second
	if (i >= second && i < second_end): return i - (second - first)
	return i

# Moving the subtree [index, last) before old node target (outside it):
int mm_slot_map_move(int i, int index, int last, int target):
	int size = last - index
	int t = target
	if (t >= last): t = t - size
	if (i >= index && i < last): return t + i - index
	int r = i
	if (r >= last): r = r - size
	if (r >= t): r = r + size
	return r

int mm_slot_contains(list[int] items, int value):
	return mm_slot_position(items, value) >= 0

# The selected items no other selected item contains, ascending; 0 when one
# cannot move.
list[int] mm_slot_roots(mm_document* d, list[int] indices):
	list[int] roots = new list[int]
	for i in range(d.nodes.length):
		if (mm_slot_contains(indices, i) == 0): continue
		int carried = 0
		for int k in indices:
			if (k != i && mm_position_within(d, i, k)): carried = 1
		if (carried): continue
		if (mm_slot_movable(d, i) == 0):
			__w_list_free(cast(__w_list*, roots))
			return 0
		roots.push(i)
	return roots

# Reorder parent's children into `desired` (their current sibling
# positions, in the wanted order) by adjacent validated swaps. Outline
# indices in track follow the swaps; a block parent is named by id, since
# block node order follows first mentions rather than subtrees.
int mm_slot_permute(mm_editor* e, int parent, char* parent_id, list[int] desired, list[int] track, int* budget):
	int n = desired.length
	list[int] cur = new list[int]
	for i in range(n): cur.push(i)
	int ok = 1
	for i in range(n):
		if (ok == 0): break
		int j = i
		while (j < n && cur[j] != desired[i]): j = j + 1
		if (j >= n): ok = 0
		while (ok && j > i):
			if (*budget <= 0):
				ok = 0
				break
			*budget = *budget - 1
			mm_document* d = e.document
			int at = parent
			if (parent_id != 0): at = mm_find_node(d, parent_id)
			list[int] kids = mm_slot_children(d, at)
			if (kids.length != n || (parent_id != 0 && at < 0)): ok = 0
			else:
				int a = kids[j - 1]
				int b = kids[j]
				int b_end = mm_oe_subtree_end(d, b)
				if (d.kind == MM_BLOCK): ok = mm_bs_swap(e, a, b)
				else: ok = mm_outline_reorder(e, a, 0)
				if (ok && track != 0):
					for k in range(track.length): track[k] = mm_slot_map_swap(track[k], a, b, b_end)
			__w_list_free(cast(__w_list*, kids))
			int t = cur[j - 1]
			cur[j - 1] = cur[j]
			cur[j] = t
			j = j - 1
	__w_list_free(cast(__w_list*, cur))
	return ok

# Sibling positions of kids with the chosen ones as a run before position
# `before` (kids.length: at the end), others in order; caller frees.
list[int] mm_slot_insert_order(list[int] kids, list[int] chosen, int before):
	list[int] order = new list[int]
	for p in range(kids.length + 1):
		if (p == before):
			for q in range(kids.length):
				if (mm_slot_contains(chosen, kids[q])): order.push(q)
		if (p < kids.length && mm_slot_contains(chosen, kids[p]) == 0): order.push(p)
	return order

# The run order of a sibling drop: the chosen run takes target's place,
# after it when it follows primary, before it otherwise. 0 when target is
# chosen or not a sibling.
list[int] mm_slot_run_order(list[int] kids, list[int] chosen, int primary, int target):
	int t = mm_slot_position(kids, target)
	int p = mm_slot_position(kids, primary)
	if (t < 0 || p < 0 || mm_slot_contains(chosen, target)): return 0
	int before = t
	if (t > p): before = t + 1
	return mm_slot_insert_order(kids, chosen, before)

# Every chosen sibling `steps` slots later (negative: earlier), keeping the
# gaps between them; 0 when one would leave the row.
list[int] mm_slot_shift_order(list[int] kids, list[int] chosen, int steps):
	list[int] order = new list[int]
	for p in range(kids.length): order.push(p)
	int count = steps
	if (count < 0): count = 0 - count
	int n = kids.length
	for s in range(count):
		for k in range(n):
			int p = n - 1 - k
			if (steps < 0): p = k
			if (mm_slot_contains(chosen, kids[order[p]]) == 0): continue
			int q = p + 1
			if (steps < 0): q = p - 1
			if (q < 0 || q >= n || mm_slot_contains(chosen, kids[order[q]])):
				__w_list_free(cast(__w_list*, order))
				return 0
			int t = order[p]
			order[p] = order[q]
			order[q] = t
	return order

# Record the moved items (tracked outline indices, or block ids).
void mm_slot_note(mm_editor* e, list[int] track, list[char*] ids, int primary_slot):
	mm_slot_moved_reset()
	for k in range(track.length):
		int at = track[k]
		if (ids != 0): at = mm_find_node(e.document, ids[k])
		mm_slot_moved_set.push(at)
		if (k == primary_slot): mm_slot_moved = at

# Reorder chosen siblings (all children of one parent) into the order
# built by `mode`: 0 a run at target's place, 1 shifted by steps.
int mm_slot_sibling_set(mm_editor* e, list[int] roots, int primary, int target, int steps, int mode):
	mm_document* d = e.document
	int parent = d.nodes[roots[0]].parent
	for int r in roots:
		if (d.nodes[r].parent != parent): return 0
	if (mode == 0 && (target < 0 || d.nodes[target].parent != parent)): return 0
	list[int] kids = mm_slot_children(d, parent)
	list[int] order = 0
	if (mode == 0): order = mm_slot_run_order(kids, roots, primary, target)
	else: order = mm_slot_shift_order(kids, roots, steps)
	__w_list_free(cast(__w_list*, kids))
	if (order == 0): return 0
	char* parent_id = 0
	list[char*] ids = 0
	if (d.kind == MM_BLOCK):
		parent_id = strclone(d.nodes[parent].id)
		ids = new list[char*]
		for int r in roots: ids.push(strclone(d.nodes[r].id))
	list[int] track = new list[int]
	int primary_slot = 0
	for k in range(roots.length):
		track.push(roots[k])
		if (roots[k] == primary): primary_slot = k
	int budget = MM_SLOT_SWAPS
	mm_editor_begin(e)
	int ok = mm_slot_permute(e, parent, parent_id, order, track, &budget)
	if (ok):
		mm_editor_commit(e)
		mm_slot_note(e, track, ids, primary_slot)
	else: mm_editor_rollback(e)
	if (ids != 0):
		for char* id in ids: free(id)
		__w_list_free(cast(__w_list*, ids))
	if (parent_id != 0): free(parent_id)
	__w_list_free(cast(__w_list*, track))
	__w_list_free(cast(__w_list*, order))
	return ok

# Outline roots gathered under parent as a run before anchor (-1: as its
# last children), in their source order.
int mm_slot_gather(mm_editor* e, list[int] roots, int primary, int parent, int anchor):
	list[int] track = new list[int]
	int primary_slot = 0
	for k in range(roots.length):
		track.push(roots[k])
		if (roots[k] == primary): primary_slot = k
	int n = roots.length
	# Tracked after the roots: the parent, then the anchor.
	track.push(parent)
	track.push(anchor)
	mm_editor_begin(e)
	int ok = 1
	for k in range(n):
		if (ok == 0): break
		mm_document* d = e.document
		int at = track[k]
		int into = track[n]
		if (d.nodes[at].parent == into): continue
		int last = mm_oe_subtree_end(d, at)
		int target = mm_oe_subtree_end(d, into)
		ok = mm_outline_reparent(e, at, into)
		if (ok):
			for j in range(track.length):
				if (track[j] >= 0): track[j] = mm_slot_map_move(track[j], at, last, target)
	if (ok):
		mm_document* d = e.document
		list[int] kids = mm_slot_children(d, track[n])
		list[int] chosen = new list[int]
		for k in range(n): chosen.push(track[k])
		int before = kids.length
		if (track[n + 1] >= 0): before = mm_slot_position(kids, track[n + 1])
		if (before < 0): ok = 0
		if (ok):
			list[int] order = mm_slot_insert_order(kids, chosen, before)
			int budget = MM_SLOT_SWAPS
			ok = mm_slot_permute(e, track[n], 0, order, track, &budget)
			__w_list_free(cast(__w_list*, order))
		__w_list_free(cast(__w_list*, chosen))
		__w_list_free(cast(__w_list*, kids))
	if (ok):
		mm_editor_commit(e)
		while (track.length > n): track.pop()
		mm_slot_note(e, track, 0, primary_slot)
	else: mm_editor_rollback(e)
	__w_list_free(cast(__w_list*, track))
	return ok

# Move the selected items (indices) to target's cell or slot as one undo
# step, primary being the dragged one; see the semantics above.
int mm_editor_slot_move_set(mm_editor* e, list[int] indices, int primary, int target):
	mm_editor_move_cancel(e)
	mm_document* d = e.document
	if (indices == 0 || indices.length == 0 || target < 0 || target >= d.nodes.length): return 0
	if (indices.length == 1):
		int moved = mm_editor_slot_move(e, indices[0], target)
		if (moved):
			mm_slot_moved_reset()
			mm_slot_moved_set.push(mm_slot_moved)
		return moved
	list[int] roots = mm_slot_roots(d, indices)
	if (roots == 0): return 0
	int ok = roots.length > 0
	# The dragged item, or the selected item carrying it.
	int lead = -1
	for int r in roots:
		if (r == primary || mm_position_within(d, primary, r)): lead = r
		if (r == target || mm_position_within(d, target, r)): ok = 0
	if (lead < 0 && roots.length > 0): lead = roots[0]
	int siblings = 1
	for int r in roots:
		if (d.nodes[r].parent != d.nodes[target].parent): siblings = 0
	if (ok && siblings): ok = mm_slot_sibling_set(e, roots, lead, target, 0, 0)
	else if (ok && d.kind == MM_BLOCK): ok = 0
	else if (ok):
		int parent = target
		int anchor = -1
		if (d.kind == MM_KANBAN):
			for int r in roots:
				if (d.nodes[r].parent < 0): ok = 0
			if (d.nodes[target].parent >= 0):
				parent = d.nodes[target].parent
				anchor = target
		if (ok): ok = mm_slot_gather(e, roots, lead, parent, anchor)
	__w_list_free(cast(__w_list*, roots))
	return ok

# Arrow keys on a multi-selection of siblings: every item moves delta slots
# (block rows: delta is a multiple of the columns), keeping their gaps.
int mm_editor_slot_step_set(mm_editor* e, list[int] indices, int delta):
	mm_editor_move_cancel(e)
	if (indices == 0 || indices.length == 0 || delta == 0): return 0
	list[int] roots = mm_slot_roots(e.document, indices)
	if (roots == 0): return 0
	int ok = 0
	if (roots.length > 0): ok = mm_slot_sibling_set(e, roots, roots[0], -1, delta, 1)
	__w_list_free(cast(__w_list*, roots))
	return ok

# Kanban: selected cards of one column move to the previous/next column as
# its last cards, in order; selected columns move among the columns.
int mm_editor_slot_column_set(mm_editor* e, list[int] indices, int delta):
	mm_document* d = e.document
	if (d.kind != MM_KANBAN || indices == 0 || indices.length == 0): return 0
	list[int] roots = mm_slot_roots(d, indices)
	if (roots == 0): return 0
	int ok = roots.length > 0
	int column = -1
	if (ok): column = d.nodes[roots[0]].parent
	for int r in roots:
		if (d.nodes[r].parent != column): ok = 0
	if (ok && column < 0):
		__w_list_free(cast(__w_list*, roots))
		return mm_editor_slot_step_set(e, indices, delta)
	if (ok):
		mm_editor_move_cancel(e)
		list[int] columns = mm_slot_children(d, -1)
		int at = mm_slot_position(columns, column) + delta
		ok = at >= 0 && at < columns.length
		if (ok): ok = mm_slot_gather(e, roots, roots[0], columns[at], -1)
		__w_list_free(cast(__w_list*, columns))
	__w_list_free(cast(__w_list*, roots))
	return ok
