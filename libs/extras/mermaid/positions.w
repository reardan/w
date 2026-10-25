# Portable graphical geometry is ordinary Mermaid comments in the selected
# diagram. Coordinates are layout coordinates (before the title's 40px gutter).
#   %% @w-position "id" x y   top-left corner; a group carries its members
#   %% @w-size "id" w h       manual node size (groups: a minimum size)
import libs.extras.mermaid.scene
import libs.extras.mermaid.flow_shapes
import libs.extras.mermaid.agentflow

const int MM_POSITION_LIMIT = 100000
const int MM_GEOMETRY_POSITION = 0
const int MM_GEOMETRY_SIZE = 1
const int MM_SIZE_MIN = 8
const int MM_SIZE_LIMIT = 20000
# Fitting margins around a moved group's members (title band on top).
const int MM_GROUP_MARGIN = 20
const int MM_GROUP_TITLE = 48

int mm_position_title_offset(mm_document* d):
	if (d.title[0] != 0): return 40
	return 0

# Families whose source grammar the graphical editor splices and whose
# scene uses the generic graph renderer (edges hit-test against it).
int mm_graph_edit_family(int kind):
	return kind == MM_FLOW || kind == MM_ER || kind == MM_CLASS || kind == MM_STATE || kind == MM_REQUIREMENT || kind == MM_USECASE || kind == MM_ARCHITECTURE || kind == MM_AGENT

# Families whose saved `@w-position` / `@w-size` records apply after the
# family's own layout: the generic graph families, C4 and swimlane.
int mm_geometry_family(int kind):
	return mm_graph_edit_family(kind) || kind == MM_C4 || kind == MM_SWIMLANE

# Families whose layout is their source order: a move reorders the source
# (block grid cells, outline siblings, kanban cards) instead of storing
# coordinates, and a block resize changes its column span.
int mm_slot_family(int kind):
	return kind == MM_BLOCK || kind == MM_MINDMAP || kind == MM_TREEVIEW || kind == MM_KANBAN

# Families with structural graphical edits (select, rename, delete, connect,
# add, outline operations) whose layout is not free geometry.
int mm_structural_edit_family(int kind):
	return mm_slot_family(kind)

int mm_canvas_edit_family(int kind):
	return mm_geometry_family(kind) || mm_structural_edit_family(kind)

# Synthetic identities (`@hierarchy:3`, `note@0`, `@region:...`) are
# positional, so geometry cannot follow them; state start/end pseudo-states
# are scoped by their composite and remain movable.
int mm_position_identity(char* id):
	if (id[0] == 0): return 0
	if (starts_with(id, c"@start:") || starts_with(id, c"@end:")): return 1
	for i in range(strlen(id)):
		# Quoted identifiers have no embedded quote/newline in the parser grammar.
		if (id[i] == '"' || id[i] == 10 || id[i] == 13 || id[i] == '@'): return 0
	return 1

int mm_position_supported(mm_document* d, int index):
	if (d.error != 0 || mm_geometry_family(d.kind) == 0): return 0
	if (index < 0 || index >= d.nodes.length): return 0
	mm_node* n = d.nodes[index]
	if (mm_position_identity(n.id) == 0): return 0
	# Collapsed agentflow containers render a projected view.
	if (mm_agent_has_collapsed(d)): return 0
	# Members of a collapsed subgraph are not drawn.
	if (mm_flow_visible_node(d, index) != index): return 0
	return 1

# A source-order item a canvas gesture may move: a named block item (not
# the root, a `space` or an anonymous composite) or any outline node except
# a mindmap's root.
int mm_slot_movable(mm_document* d, int index):
	if (d.error != 0 || mm_slot_family(d.kind) == 0): return 0
	if (index < 0 || index >= d.nodes.length): return 0
	mm_node* n = d.nodes[index]
	if (d.kind == MM_BLOCK): return n.parent >= 0 && n.shape != -1 && mm_position_identity(n.id)
	if (d.kind == MM_MINDMAP): return n.parent >= 0
	return 1

# Block leaves resize by column span.
int mm_slot_resizable(mm_document* d, int index):
	return d.kind == MM_BLOCK && mm_slot_movable(d, index) && d.nodes[index].group == 0

int mm_position_space(int c):
	return c == 32 || c == 9 || c == 13

# Only ranges actually consumed by mm_separators are comments. In particular,
# accDescr blocks may contain metadata-looking lines that must stay plain text.
int mm_position_comment(mm_document* d, int start, int end):
	if (d.comment_ranges == 0): return 0
	int low = 0
	int high = d.comment_ranges.length / 2
	while (low < high):
		int mid = low + (high - low) / 2
		int offset = d.comment_ranges[mid * 2]
		if (offset < start): low = mid + 1
		else: high = mid
	if (low * 2 >= d.comment_ranges.length): return 0
	return d.comment_ranges[low * 2] == start && d.comment_ranges[low * 2 + 1] == end

int mm_geometry_prefix(mm_document* d, int at, int end, char* prefix):
	int length = strlen(prefix)
	if (end - at < length): return 0
	for i in range(length):
		if (d.source[at + i] != prefix[i]): return 0
	return length

# A malformed comment remains ordinary text; it must never move a node or
# overflow an integer. Return the matched node index only for complete records;
# *kind is MM_GEOMETRY_POSITION or MM_GEOMETRY_SIZE.
int mm_geometry_record(mm_document* d, int start, int end, int* kind, int* x, int* y):
	int at = start
	while (at < end && mm_position_space(d.source[at])): at = at + 1
	int length = mm_geometry_prefix(d, at, end, c"%% @w-position ")
	*kind = MM_GEOMETRY_POSITION
	if (length == 0):
		length = mm_geometry_prefix(d, at, end, c"%% @w-size ")
		*kind = MM_GEOMETRY_SIZE
	if (length == 0): return -1
	if (mm_position_comment(d, at, end) == 0): return -1
	at = at + length
	while (at < end && mm_position_space(d.source[at])): at = at + 1
	int quoted = at < end && d.source[at] == '"'
	if (quoted): at = at + 1
	int id_start = at
	while (at < end):
		if (quoted && d.source[at] == '"'): break
		if (quoted == 0 && mm_position_space(d.source[at])): break
		at = at + 1
	if (at == id_start || at == end): return -1
	char* id = str_copy_range(d.source, id_start, at)
	int index = mm_find_node(d, id)
	free(id)
	if (mm_position_supported(d, index) == 0): return -1
	if (quoted): at = at + 1
	int limit = MM_POSITION_LIMIT
	if (*kind == MM_GEOMETRY_SIZE): limit = MM_SIZE_LIMIT
	for axis in range(2):
		if (at == end || mm_position_space(d.source[at]) == 0): return -1
		while (at < end && mm_position_space(d.source[at])): at = at + 1
		int digit_start = at
		int value = 0
		while (at < end && d.source[at] >= '0' && d.source[at] <= '9'):
			int digit = d.source[at] - '0'
			if (value > (limit - digit) / 10): return -1
			value = value * 10 + digit
			at = at + 1
		if (at == digit_start): return -1
		if (*kind == MM_GEOMETRY_SIZE && value < MM_SIZE_MIN): return -1
		if (axis == 0): *x = value
		else: *y = value
	while (at < end && mm_position_space(d.source[at])): at = at + 1
	if (at != end): return -1
	return index

# Position records only (sizes return -1), as before sizes existed.
int mm_position_record(mm_document* d, int start, int end, int* x, int* y):
	int kind = 0
	int index = mm_geometry_record(d, start, end, &kind, x, y)
	if (kind != MM_GEOMETRY_POSITION): return -1
	return index

int mm_position_line_end(mm_document* d, int start):
	int end = start
	while (end < d.source_end && d.source[end] != 10): end = end + 1
	return end

int mm_position_depth(mm_document* d, int index):
	int depth = 0
	int at = d.nodes[index].parent
	while (at >= 0 && depth < 128):
		depth = depth + 1
		at = d.nodes[at].parent
	return depth

# 1 when index lies strictly inside ancestor's subtree.
int mm_position_within(mm_document* d, int index, int ancestor):
	int at = d.nodes[index].parent
	int depth = 0
	while (at >= 0 && depth < 128):
		if (at == ancestor): return 1
		at = d.nodes[at].parent
		depth = depth + 1
	return 0

# Translate a node and, for a group, every member drawn inside it.
void mm_position_translate(mm_document* d, mm_scene* s, int index, int dx, int dy):
	if (dx == 0 && dy == 0): return
	s.nodes[index].x = s.nodes[index].x + dx
	s.nodes[index].y = s.nodes[index].y + dy
	if (d.nodes[index].group == 0): return
	for i in range(d.nodes.length):
		if (i < s.nodes.length && mm_position_within(d, i, index)):
			s.nodes[i].x = s.nodes[i].x + dx
			s.nodes[i].y = s.nodes[i].y + dy

# Grow groups (innermost first) so they keep enclosing moved or resized
# members. Groups only grow: automatic layout already encloses its members.
void mm_positions_fit_groups(mm_document* d, mm_scene* s):
	# Swimlane frames are tighter than the graph renderer's (14px sides, a
	# 36px title band), so an untouched layout never grows.
	int side = MM_GROUP_MARGIN
	int title = MM_GROUP_TITLE
	if (d.kind == MM_SWIMLANE):
		side = 14
		title = 36
	int deepest = 0
	for i in range(d.nodes.length):
		int depth = mm_position_depth(d, i)
		if (depth > deepest): deepest = depth
	int depth = deepest
	while (depth >= 0):
		for g in range(d.nodes.length):
			mm_node* group = d.nodes[g]
			if (group.group == 0 || g >= s.nodes.length || mm_position_depth(d, g) != depth): continue
			if (mm_flow_collapsed(d, g) || mm_flow_visible_node(d, g) != g): continue
			mm_bounds* box = s.nodes[g]
			int any = 0
			int left = 0
			int top = 0
			int right = 0
			int bottom = 0
			for i in range(d.nodes.length):
				if (i >= s.nodes.length || d.nodes[i].parent != g): continue
				mm_bounds* b = s.nodes[i]
				if (any == 0 || b.x < left): left = b.x
				if (any == 0 || b.y < top): top = b.y
				if (any == 0 || b.x + b.w > right): right = b.x + b.w
				if (any == 0 || b.y + b.h > bottom): bottom = b.y + b.h
				any = 1
			if (any == 0): continue
			left = left - side
			top = top - title
			right = right + side
			bottom = bottom + side
			if (left < box.x):
				box.w = box.w + box.x - left
				box.x = left
			if (top < box.y):
				box.h = box.h + box.y - top
				box.y = top
			if (right > box.x + box.w): box.w = right - box.x
			if (bottom > box.y + box.h): box.h = bottom - box.y
		depth = depth - 1

void mm_positions_apply(mm_document* d, mm_scene* s):
	if (mm_geometry_family(d.kind) == 0): return
	int count = d.nodes.length
	if (s.nodes.length < count): count = s.nodes.length
	list[int] xs = new list[int]
	list[int] ys = new list[int]
	list[int] ws = new list[int]
	list[int] hs = new list[int]
	for i in range(count):
		xs.push(-1)
		ys.push(-1)
		ws.push(-1)
		hs.push(-1)
	int found = 0
	int at = d.source_start
	while (at < d.source_end):
		int end = mm_position_line_end(d, at)
		int kind = 0
		int x = 0
		int y = 0
		int index = mm_geometry_record(d, at, end, &kind, &x, &y)
		if (index >= 0 && index < count):
			found = 1
			if (kind == MM_GEOMETRY_POSITION):
				xs[index] = x
				ys[index] = y
			else:
				ws[index] = x
				hs[index] = y
		at = end + 1
	if (found):
		# Sizes first, then positions outermost first: a group's record moves
		# its members, and a member's own record then places it absolutely.
		for i in range(count):
			if (ws[i] < 0): continue
			mm_bounds* b = s.nodes[i]
			if (d.nodes[i].group):
				if (ws[i] > b.w): b.w = ws[i]
				if (hs[i] > b.h): b.h = hs[i]
			else:
				b.w = ws[i]
				b.h = hs[i]
		int deepest = 0
		for i in range(count):
			int depth = mm_position_depth(d, i)
			if (depth > deepest): deepest = depth
		for depth in range(deepest + 1):
			for i in range(count):
				if (xs[i] < 0 || mm_position_depth(d, i) != depth): continue
				mm_position_translate(d, s, i, xs[i] - s.nodes[i].x, ys[i] - s.nodes[i].y)
		mm_positions_fit_groups(d, s)
	__w_list_free(cast(__w_list*, xs))
	__w_list_free(cast(__w_list*, ys))
	__w_list_free(cast(__w_list*, ws))
	__w_list_free(cast(__w_list*, hs))

# Replace the kind records of the listed nodes with new values; keep every
# other source byte, including malformed comments, other records and other
# Markdown fences. Last record wins on read; writing coalesces duplicates.
# Owned result, or null when an entry is unsupported or out of range.
char* mm_geometry_source(mm_document* d, int kind, list[int] indices, list[int] xs, list[int] ys):
	if (indices.length == 0 || indices.length != xs.length || indices.length != ys.length): return 0
	for k in range(indices.length):
		if (mm_position_supported(d, indices[k]) == 0): return 0
		int low = 0
		int high = MM_POSITION_LIMIT
		if (kind == MM_GEOMETRY_SIZE):
			low = MM_SIZE_MIN
			high = MM_SIZE_LIMIT
		if (xs[k] < low || ys[k] < low || xs[k] > high || ys[k] > high): return 0
	string_builder* out = string_new()
	string_append_bytes(out, d.source, d.source_start)
	int at = d.source_start
	int crlf = 0
	while (at < d.source_end):
		int end = mm_position_line_end(d, at)
		if (end > at && d.source[end - 1] == 13): crlf = 1
		int line_end = end
		if (line_end < d.source_end): line_end = line_end + 1
		int old_kind = 0
		int old_x = 0
		int old_y = 0
		int record = mm_geometry_record(d, at, end, &old_kind, &old_x, &old_y)
		int replaced = 0
		if (record >= 0 && old_kind == kind):
			for int index in indices:
				if (index == record): replaced = 1
		if (replaced == 0): string_append_bytes(out, d.source + at, line_end - at)
		at = line_end
	if (out.length > 0 && out.data[out.length - 1] != 10):
		if (crlf): string_append_char(out, 13)
		string_append_char(out, 10)
	for k in range(indices.length):
		if (kind == MM_GEOMETRY_SIZE): string_append(out, c"%% @w-size \"")
		else: string_append(out, c"%% @w-position \"")
		string_append(out, d.nodes[indices[k]].id)
		string_append(out, c"\" ")
		string_append_int(out, xs[k])
		string_append_char(out, 32)
		string_append_int(out, ys[k])
		if (crlf): string_append_char(out, 13)
		string_append_char(out, 10)
	string_append_bytes(out, d.source + d.source_end, d.length - d.source_end)
	char* result = out.data
	free(out)
	return result

char* mm_position_source(mm_document* d, int index, int x, int y):
	list[int] indices = list[int]{index}
	list[int] xs = list[int]{x}
	list[int] ys = list[int]{y}
	char* result = mm_geometry_source(d, MM_GEOMETRY_POSITION, indices, xs, ys)
	__w_list_free(cast(__w_list*, indices))
	__w_list_free(cast(__w_list*, xs))
	__w_list_free(cast(__w_list*, ys))
	return result
