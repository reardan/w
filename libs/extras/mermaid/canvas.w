# UI-independent canvas interaction. Pointer coordinates are viewport-local pixels.
import libs.extras.mermaid.editor
import libs.extras.mermaid.edit_commands

struct mm_canvas:
	float32 zoom
	float32 pan_x
	float32 pan_y
	int node
	int edge
	int gesture
	int dragged
	float32 press_x
	float32 press_y
	float32 start_pan_x
	float32 start_pan_y
	int start_x
	int start_y
	int move_here
	int connect_from
	# Multi-selection: every selected node, `node` among them when set.
	# Empty means only `node` (if any) is selected.
	list[int] selection
	# Sticky extend (keyboard Space): the next selection change adds.
	int extend
	# Rubber band (gesture 3) corners in viewport pixels.
	float32 band_x
	float32 band_y
	int band_additive

# Gestures: 1 pan, 2 move node or selection, 3 rubber band, 4 resize.
# Press modifier bits (callers map shift/ctrl to MM_CANVAS_EXTEND).
const int MM_CANVAS_EXTEND = 1
# Resize handle half-size in viewport pixels (bottom-right corner).
const int MM_CANVAS_HANDLE = 6

void mm_canvas_init(mm_canvas* c):
	c.zoom = 1.0
	c.pan_x = 0.0
	c.pan_y = 0.0
	c.node = -1
	c.edge = -1
	c.gesture = 0
	c.dragged = 0
	c.move_here = 0
	c.connect_from = -1
	c.selection = new list[int]
	c.extend = 0
	c.band_x = 0.0
	c.band_y = 0.0
	c.band_additive = 0

void mm_canvas_clear_selection(mm_canvas* c):
	if (c.selection == 0): c.selection = new list[int]
	while (c.selection.length > 0): c.selection.pop()

# With an empty `selection`, `node` alone is selected; otherwise exactly
# the listed nodes are, and `node` is the focused one (possibly unselected
# while Space-extending).
int mm_canvas_selected(mm_canvas* c, int index):
	if (index < 0): return 0
	if (c.selection == 0 || c.selection.length == 0): return index == c.node
	for int i in c.selection:
		if (i == index): return 1
	return 0

# The selected node indices, ascending, as a new list (caller frees).
list[int] mm_canvas_selected_nodes(mm_canvas* c, mm_editor* e):
	list[int] result = new list[int]
	for i in range(e.document.nodes.length):
		if (mm_canvas_selected(c, i)): result.push(i)
	return result

int mm_canvas_selection_count(mm_canvas* c, mm_editor* e):
	list[int] all = mm_canvas_selected_nodes(c, e)
	int count = all.length
	__w_list_free(cast(__w_list*, all))
	return count

# The one selected node, or -1 when none or several are selected.
int mm_canvas_single(mm_canvas* c, mm_editor* e):
	list[int] all = mm_canvas_selected_nodes(c, e)
	int one = -1
	if (all.length == 1): one = all[0]
	__w_list_free(cast(__w_list*, all))
	return one

# A node the canvas may select: real (not a synthetic '@' container) in a
# family the canvas edits.
int mm_canvas_selectable(mm_editor* e, int index):
	if (e.scene == 0 || index < 0 || index >= e.document.nodes.length): return 0
	if (mm_canvas_edit_family(e.document.kind) == 0): return 0
	if (e.scene.nodes.length != e.document.nodes.length): return 0
	if (e.document.nodes[index].group && e.document.nodes[index].id[0] == '@'): return 0
	return mm_flow_visible_node(e.document, index) == index

# Toggle membership (shift/ctrl-click); focus follows the toggled node.
void mm_canvas_toggle_node(mm_canvas* c, mm_editor* e, int index):
	if (mm_canvas_selectable(e, index) == 0): return
	if (c.selection == 0): c.selection = new list[int]
	if (c.selection.length == 0 && c.node >= 0 && c.node < e.document.nodes.length): c.selection.push(c.node)
	int found = -1
	for i in range(c.selection.length):
		if (c.selection[i] == index): found = i
	c.edge = -1
	c.node = index
	if (found < 0):
		c.selection.push(index)
		return
	for i in range(found, c.selection.length - 1): c.selection[i] = c.selection[i + 1]
	c.selection.pop()
	if (c.selection.length == 0): c.node = -1

void mm_canvas_select_all(mm_canvas* c, mm_editor* e):
	mm_canvas_clear_selection(c)
	c.edge = -1
	c.extend = 0
	for i in range(e.document.nodes.length):
		if (mm_canvas_selectable(e, i)):
			c.selection.push(i)
			c.node = i

void mm_canvas_cancel(mm_canvas* c, mm_editor* e):
	mm_editor_move_cancel(e)
	if (c.gesture == 1):
		c.pan_x = c.start_pan_x
		c.pan_y = c.start_pan_y
	c.gesture = 0
	c.dragged = 0
	c.move_here = 0
	c.connect_from = -1

# Call on source edits, undo, reload and diagram switches: indices cannot survive
# reparsing. Camera deliberately survives ordinary edits.
void mm_canvas_reset(mm_canvas* c, mm_editor* e):
	mm_canvas_cancel(c, e)
	c.node = -1
	c.edge = -1
	c.extend = 0
	mm_canvas_clear_selection(c)

void mm_canvas_zoom(mm_canvas* c, float32 factor, float32 x, float32 y):
	float32 next = c.zoom * factor
	if (next < 0.05): next = 0.05
	if (next > 4.0): next = 4.0
	c.pan_x = x - (x - c.pan_x) * next / c.zoom
	c.pan_y = y - (y - c.pan_y) * next / c.zoom
	c.zoom = next

void mm_canvas_fit(mm_canvas* c, mm_scene* s, float32 width, float32 height):
	if (s == 0 || width <= 24.0 || height <= 24.0): return
	float32 zoom = (width - 24.0) / cast(float32, s.width)
	float32 zy = (height - 24.0) / cast(float32, s.height)
	if (zy < zoom): zoom = zy
	if (zoom > 1.0): zoom = 1.0
	if (zoom < 0.05): zoom = 0.05
	c.zoom = zoom
	c.pan_x = (width - cast(float32, s.width) * zoom) / 2.0
	c.pan_y = (height - cast(float32, s.height) * zoom) / 2.0

# Reuse the renderer's actual edge geometry for hit testing and highlighting.
# Bounds are borrowed and detached before freeing the temporary scene.
mm_scene* mm_canvas_edge_scene(mm_editor* e, int edge):
	if (e.scene == 0 || edge < 0 || edge >= e.document.edges.length): return 0
	mm_scene* s = new mm_scene()
	s.items = new list[mm_primitive*]
	s.nodes = e.scene.nodes
	mm_render_edge(e.document, s, e.document.edges[edge])
	s.nodes = new list[mm_bounds*]
	return s

int mm_canvas_hit_edge(mm_canvas* c, mm_editor* e, float32 x, float32 y):
	if (e.scene == 0): return -1
	if (mm_graph_edit_family(e.document.kind) == 0): return -1
	float32 wx = (x - c.pan_x) / c.zoom
	float32 wy = (y - c.pan_y) / c.zoom
	float32 tolerance = 7.0 / c.zoom
	for i in range(e.document.edges.length):
		mm_scene* s = mm_canvas_edge_scene(e, i)
		int hit = 0
		for mm_primitive* p in s.items:
			if (p.kind != MM_LINE): continue
			float32 ax = cast(float32, p.x)
			float32 ay = cast(float32, p.y)
			float32 dx = cast(float32, p.x2 - p.x)
			float32 dy = cast(float32, p.y2 - p.y)
			float32 length = dx * dx + dy * dy
			float32 t = 0.0
			if (length > 0.0): t = ((wx - ax) * dx + (wy - ay) * dy) / length
			if (t < 0.0): t = 0.0
			if (t > 1.0): t = 1.0
			float32 ex = wx - ax - t * dx
			float32 ey = wy - ay - t * dy
			if (ex * ex + ey * ey <= tolerance * tolerance): hit = 1
		mm_scene_free(s)
		if (hit): return i
	return -1

int mm_canvas_bound_x(int x):
	if (x < 0): return 0
	if (x > 100000): return 100000
	return x

int mm_canvas_bound_y(mm_editor* e, int y):
	int top = mm_position_title_offset(e.document)
	if (y < top): return top
	if (y > 100000 + top): return 100000 + top
	return y

# The bottom-right resize handle of the primary node, in viewport pixels.
int mm_canvas_on_handle(mm_canvas* c, mm_editor* e, float32 x, float32 y):
	if (c.node < 0 || mm_canvas_single(c, e) != c.node || mm_editor_can_resize(e, c.node) == 0): return 0
	mm_bounds* b = e.scene.nodes[c.node]
	float32 hx = c.pan_x + cast(float32, b.x + b.w) * c.zoom
	float32 hy = c.pan_y + cast(float32, b.y + b.h) * c.zoom
	float32 size = cast(float32, MM_CANVAS_HANDLE)
	return x >= hx - size && x <= hx + size && y >= hy - size && y <= hy + size

# Returns 1 only when a click mode committed a source change. `mods`
# carries MM_CANVAS_EXTEND for shift/ctrl-click (toggle, rubber band).
# The cell or outline slot under scene point (x, y) for a source-order
# move of index: the smallest drawn box containing it, outside index's own
# subtree. Blocks resolve to index's sibling enclosing that box.
int mm_canvas_slot_at(mm_editor* e, int index, int x, int y):
	mm_document* d = e.document
	int best = -1
	int best_area = 0
	for i in range(d.nodes.length):
		if (i == index || mm_position_within(d, i, index)): continue
		if (d.nodes[i].group && d.nodes[i].id[0] == '@'): continue
		mm_bounds* b = e.scene.nodes[i]
		if (b.w <= 0 || b.h <= 0 || x < b.x || x > b.x + b.w || y < b.y || y > b.y + b.h): continue
		int area = b.w * b.h
		if (best < 0 || area < best_area):
			best = i
			best_area = area
	if (best >= 0 && d.kind == MM_BLOCK):
		int at = best
		int guard = 0
		while (at >= 0 && d.nodes[at].parent != d.nodes[index].parent && guard < 64):
			at = d.nodes[at].parent
			guard = guard + 1
		if (at < 0 || d.nodes[at].parent != d.nodes[index].parent): return -1
		best = at
	return best

# The selection follows the item a slot command moved.
void mm_canvas_follow_slot(mm_canvas* c):
	mm_canvas_clear_selection(c)
	c.node = mm_slot_moved
	c.edge = -1

# A multi-selection follows every item a set command moved.
void mm_canvas_follow_slots(mm_canvas* c):
	mm_canvas_clear_selection(c)
	if (mm_slot_moved_set != 0):
		for int i in mm_slot_moved_set: c.selection.push(i)
	c.node = mm_slot_moved
	c.edge = -1

# Release of a source-order drag: the slot under the dragged box's centre.
int mm_canvas_slot_drop(mm_canvas* c, mm_editor* e):
	int index = e.move_index
	if (index < 0 || index >= e.scene.nodes.length):
		mm_editor_move_cancel(e)
		return 0
	mm_bounds* b = e.scene.nodes[index]
	int cx = b.x + b.w / 2
	int cy = b.y + b.h / 2
	mm_editor_move_cancel(e)
	int target = mm_canvas_slot_at(e, index, cx, cy)
	if (target < 0): return 0
	if (mm_canvas_selection_count(c, e) > 1):
		# The whole selection moves to the slot under the dragged item.
		if (mm_canvas_selected(c, target)): return 0
		list[int] all = mm_canvas_selected_nodes(c, e)
		int moved = mm_editor_slot_move_set(e, all, index, target)
		__w_list_free(cast(__w_list*, all))
		if (moved): mm_canvas_follow_slots(c)
		return moved
	int ok = mm_editor_slot_move(e, index, target)
	if (ok): mm_canvas_follow_slot(c)
	return ok

int mm_canvas_press_mods(mm_canvas* c, mm_editor* e, float32 x, float32 y, int mods):
	int wx = cast(int, (x - c.pan_x) / c.zoom)
	int wy = cast(int, (y - c.pan_y) / c.zoom)
	int extend = (mods & MM_CANVAS_EXTEND) != 0 || c.extend
	if (c.move_here && mm_slot_family(e.document.kind) && mm_editor_can_move(e, c.node)):
		int target = mm_canvas_slot_at(e, c.node, wx, wy)
		c.move_here = 0
		if (target < 0): return 0
		int moved = mm_editor_slot_move(e, c.node, target)
		if (moved): mm_canvas_follow_slot(c)
		return moved
	if (c.move_here && mm_editor_can_move(e, c.node)):
		int ok = mm_editor_move_node(e, c.node, mm_canvas_bound_x(wx), mm_canvas_bound_y(e, wy))
		c.move_here = 0
		return ok
	c.press_x = x
	c.press_y = y
	c.start_pan_x = c.pan_x
	c.start_pan_y = c.pan_y
	c.dragged = 0
	c.gesture = 0
	if (extend == 0 && c.connect_from < 0 && mm_canvas_on_handle(c, e, x, y)):
		c.gesture = 4
		c.start_x = e.scene.nodes[c.node].w
		c.start_y = e.scene.nodes[c.node].h
		return 0
	int hit = mm_editor_hit(e, wx, wy)
	if (c.connect_from >= 0 && hit >= 0):
		int ok = 0
		if (e.document.kind == MM_ER): ok = mm_editor_add_relationship(e, e.document.nodes[c.connect_from].id, e.document.nodes[hit].id, c"relates", 1, 3, 0)
		else: ok = mm_editor_connect(e, e.document.nodes[c.connect_from].id, e.document.nodes[hit].id)
		c.connect_from = -1
		mm_canvas_clear_selection(c)
		c.node = hit
		c.edge = -1
		return ok
	if (extend):
		c.extend = 0
		if (hit >= 0):
			mm_canvas_toggle_node(c, e, hit)
			return 0
		# Shift/ctrl on the background: rubber band adding to the selection.
		c.gesture = 3
		c.band_x = x
		c.band_y = y
		c.band_additive = 1
		return 0
	# Pressing a member of a multi-selection drags the whole set.
	if (hit >= 0 && mm_canvas_selection_count(c, e) > 1 && mm_canvas_selected(c, hit)):
		c.node = hit
		c.edge = -1
		c.gesture = 2
		c.start_x = e.scene.nodes[hit].x
		c.start_y = e.scene.nodes[hit].y
		return 0
	mm_canvas_clear_selection(c)
	c.node = hit
	c.edge = -1
	if (hit < 0): c.edge = mm_canvas_hit_edge(c, e, x, y)
	if (hit >= 0):
		if (mm_editor_can_move(e, hit)):
			c.gesture = 2
			c.start_x = e.scene.nodes[hit].x
			c.start_y = e.scene.nodes[hit].y
	else if (c.edge < 0): c.gesture = 1
	return 0

int mm_canvas_press(mm_canvas* c, mm_editor* e, float32 x, float32 y):
	return mm_canvas_press_mods(c, e, x, y, 0)

# Nodes whose bounds intersect the band (scene coordinates).
void mm_canvas_band_select(mm_canvas* c, mm_editor* e, float32 x, float32 y):
	float32 x0 = (c.band_x - c.pan_x) / c.zoom
	float32 y0 = (c.band_y - c.pan_y) / c.zoom
	float32 x1 = (x - c.pan_x) / c.zoom
	float32 y1 = (y - c.pan_y) / c.zoom
	if (x1 < x0):
		float32 t = x0
		x0 = x1
		x1 = t
	if (y1 < y0):
		float32 t = y0
		y0 = y1
		y1 = t
	if (c.band_additive == 0):
		mm_canvas_clear_selection(c)
		c.node = -1
	for i in range(e.document.nodes.length):
		if (mm_canvas_selectable(e, i) == 0 || mm_canvas_selected(c, i)): continue
		mm_bounds* b = e.scene.nodes[i]
		if (b.w <= 0 || b.h <= 0): continue
		if (cast(float32, b.x + b.w) < x0 || cast(float32, b.x) > x1 || cast(float32, b.y + b.h) < y0 || cast(float32, b.y) > y1): continue
		mm_canvas_toggle_node(c, e, i)

# The selection to move with the primary node; 0 when any member is fixed.
list[int] mm_canvas_move_set(mm_canvas* c, mm_editor* e):
	list[int] all = mm_canvas_selected_nodes(c, e)
	for int i in all:
		if (mm_editor_can_move(e, i) == 0):
			__w_list_free(cast(__w_list*, all))
			return 0
	if (all.length == 0):
		__w_list_free(cast(__w_list*, all))
		return 0
	return all

void mm_canvas_motion(mm_canvas* c, mm_editor* e, float32 x, float32 y):
	if (c.gesture == 0): return
	float32 dx = x - c.press_x
	float32 dy = y - c.press_y
	if (c.dragged == 0):
		if (dx * dx + dy * dy < 25.0): return
		c.dragged = 1
		if (c.gesture == 2):
			int began = 0
			if (mm_canvas_selection_count(c, e) > 1):
				list[int] set = mm_canvas_move_set(c, e)
				if (set != 0):
					# The primary node leads so previews and commits track it.
					list[int] ordered = list[int]{c.node}
					for int i in set:
						if (i != c.node): ordered.push(i)
					began = mm_editor_move_begin_set(e, ordered)
					if (began && e.move_index != c.node):
						e.move_index = c.node
						e.move_start_x = e.scene.nodes[c.node].x
						e.move_start_y = e.scene.nodes[c.node].y
					__w_list_free(cast(__w_list*, ordered))
					__w_list_free(cast(__w_list*, set))
			else: began = mm_editor_move_begin(e, c.node)
			if (began == 0):
				c.gesture = 0
				return
		if (c.gesture == 4 && mm_editor_resize_begin(e, c.node) == 0):
			c.gesture = 0
			return
	if (c.gesture == 1):
		c.pan_x = c.start_pan_x + dx
		c.pan_y = c.start_pan_y + dy
	else if (c.gesture == 3):
		c.start_x = cast(int, x)
		c.start_y = cast(int, y)
	else if (c.gesture == 4):
		int w = c.start_x + cast(int, dx / c.zoom)
		int h = c.start_y + cast(int, dy / c.zoom)
		if (w < MM_SIZE_MIN): w = MM_SIZE_MIN
		if (h < MM_SIZE_MIN): h = MM_SIZE_MIN
		mm_editor_resize_preview(e, w, h)
	else if (e.move_set.length > 1 || mm_canvas_selection_count(c, e) > 1):
		mm_editor_move_preview_delta(e, cast(int, dx / c.zoom), cast(int, dy / c.zoom))
	else:
		mm_editor_move_preview(e, mm_canvas_bound_x(c.start_x + cast(int, dx / c.zoom)), mm_canvas_bound_y(e, c.start_y + cast(int, dy / c.zoom)))

int mm_canvas_release(mm_canvas* c, mm_editor* e):
	int changed = 0
	int slot = mm_slot_family(e.document.kind)
	if (c.gesture == 2 && c.dragged && slot): changed = mm_canvas_slot_drop(c, e)
	else if (c.gesture == 2 && c.dragged): changed = mm_editor_move_commit(e)
	# A click (no drag) on a member of a multi-selection selects just it.
	if (c.gesture == 2 && c.dragged == 0 && c.selection != 0 && c.selection.length > 0): mm_canvas_clear_selection(c)
	if (c.gesture == 4 && c.dragged && slot && e.moving == 2):
		# A block's resize handle sets its column span.
		int index = e.move_index
		int span = mm_editor_block_span_for(e, index, e.move_start_x, e.scene.nodes[index].w)
		mm_editor_move_cancel(e)
		changed = mm_editor_block_span(e, index, span)
	else if (c.gesture == 4 && c.dragged): changed = mm_editor_resize_commit(e)
	if (c.gesture == 3):
		if (c.dragged): mm_canvas_band_select(c, e, cast(float32, c.start_x), cast(float32, c.start_y))
	c.gesture = 0
	c.dragged = 0
	return changed

# Arrow keys in source-order families move one slot: block cells left and
# right (up and down by a row of the composite's columns), outline siblings
# up and down, kanban cards across columns with left and right.
int mm_canvas_slot_nudge(mm_canvas* c, mm_editor* e, int dx, int dy):
	int one = mm_canvas_single(c, e)
	if (one < 0 || mm_editor_can_move(e, one) == 0): return 0
	mm_document* d = e.document
	int across = 0
	if (dx > 0): across = 1
	if (dx < 0): across = -1
	int along = 0
	if (dy > 0): along = 1
	if (dy < 0): along = -1
	int columns = 0
	if (d.kind == MM_BLOCK):
		int parent = d.nodes[one].parent
		if (parent >= 0): columns = d.nodes[parent].value_x
		if (columns <= 0):
			list[int] siblings = mm_slot_siblings(d, one)
			columns = siblings.length
			__w_list_free(cast(__w_list*, siblings))
	int ok = 0
	if (d.kind == MM_BLOCK): ok = mm_editor_slot_step(e, one, across + along * columns)
	else if (d.kind == MM_KANBAN && across != 0): ok = mm_editor_slot_column(e, one, across)
	else:
		if (along == 0): along = across
		ok = mm_editor_slot_step(e, one, along)
	if (ok): mm_canvas_follow_slot(c)
	return ok

# Arrow keys on a source-order multi-selection: every selected item moves
# one slot (block cells up and down by a row), keeping their gaps; kanban
# cards of one column move across columns together.
int mm_canvas_slot_nudge_set(mm_canvas* c, mm_editor* e, int dx, int dy):
	mm_document* d = e.document
	list[int] all = mm_canvas_selected_nodes(c, e)
	int across = 0
	if (dx > 0): across = 1
	if (dx < 0): across = -1
	int along = 0
	if (dy > 0): along = 1
	if (dy < 0): along = -1
	int ok = 0
	if (d.kind == MM_BLOCK && all.length > 0):
		int parent = d.nodes[all[0]].parent
		int columns = 0
		if (parent >= 0): columns = d.nodes[parent].value_x
		if (columns <= 0):
			list[int] siblings = mm_slot_siblings(d, all[0])
			columns = siblings.length
			__w_list_free(cast(__w_list*, siblings))
		ok = mm_editor_slot_step_set(e, all, across + along * columns)
	else if (d.kind == MM_KANBAN && across != 0): ok = mm_editor_slot_column_set(e, all, across)
	else:
		if (along == 0): along = across
		ok = mm_editor_slot_step_set(e, all, along)
	__w_list_free(cast(__w_list*, all))
	if (ok): mm_canvas_follow_slots(c)
	return ok

int mm_canvas_nudge(mm_canvas* c, mm_editor* e, int dx, int dy):
	if (mm_slot_family(e.document.kind)):
		if (mm_canvas_selection_count(c, e) > 1): return mm_canvas_slot_nudge_set(c, e, dx, dy)
		return mm_canvas_slot_nudge(c, e, dx, dy)
	if (mm_canvas_selection_count(c, e) > 1):
		list[int] set = mm_canvas_move_set(c, e)
		if (set == 0): return 0
		int ok = mm_editor_move_nodes(e, set, dx, dy)
		__w_list_free(cast(__w_list*, set))
		return ok
	int one = mm_canvas_single(c, e)
	if (mm_editor_can_move(e, one) == 0): return 0
	mm_bounds* b = e.scene.nodes[one]
	return mm_editor_move_node(e, one, mm_canvas_bound_x(b.x + dx), mm_canvas_bound_y(e, b.y + dy))

# Keyboard resize of the single selected node (Alt+arrows).
int mm_canvas_grow(mm_canvas* c, mm_editor* e, int dw, int dh):
	int one = mm_canvas_single(c, e)
	if (mm_editor_can_resize(e, one) == 0): return 0
	if (mm_slot_family(e.document.kind)):
		# Blocks: Alt+Right/Left widen/narrow the column span by one.
		if (dw == 0): return 0
		int span = mm_block_span_of(e.document, one)
		if (dw > 0): span = span + 1
		else: span = span - 1
		return mm_editor_block_span(e, one, span)
	mm_bounds* b = e.scene.nodes[one]
	int w = b.w + dw
	int h = b.h + dh
	if (w < MM_SIZE_MIN): w = MM_SIZE_MIN
	if (h < MM_SIZE_MIN): h = MM_SIZE_MIN
	return mm_editor_resize_node(e, one, w, h)

# Tab order covers nodes and groups (not synthetic containers). With
# sticky extend (Space), the selection is kept and the focus moves.
void mm_canvas_cycle(mm_canvas* c, mm_editor* e, int reverse):
	# Switching the visible selection always exits an armed click operation.
	mm_canvas_cancel(c, e)
	if (e.scene == 0 || e.document.nodes.length == 0): return
	if (mm_canvas_edit_family(e.document.kind) == 0): return
	int count = e.document.nodes.length
	int next = c.node
	if (reverse && next < 0): next = 0
	for i in range(count):
		if (reverse): next = (next + count - 1) % count
		else: next = (next + 1) % count
		if (mm_canvas_selectable(e, next)):
			# A listed selection survives focus moves; a single one follows focus.
			if (c.selection == 0 || c.selection.length == 0 || c.extend == 0): mm_canvas_clear_selection(c)
			c.node = next
			c.edge = -1
			return

# Space: toggle the focused node into the multi-selection and keep
# extending; the next Tab moves focus without dropping the set.
void mm_canvas_toggle_focused(mm_canvas* c, mm_editor* e):
	if (c.node < 0 || mm_canvas_selectable(e, c.node) == 0): return
	if (c.selection == 0): c.selection = new list[int]
	c.extend = 1
	if (c.selection.length == 0):
		c.selection.push(c.node)
		return
	int focus = c.node
	mm_canvas_toggle_node(c, e, focus)
	# Focus stays put while the node leaves the set.
	c.node = focus

int mm_canvas_delete(mm_canvas* c, mm_editor* e):
	int ok = 0
	if (mm_canvas_selection_count(c, e) > 1):
		list[int] all = mm_canvas_selected_nodes(c, e)
		ok = mm_editor_delete_nodes(e, all)
		__w_list_free(cast(__w_list*, all))
	else if (mm_canvas_single(c, e) >= 0): ok = mm_editor_delete_node(e, mm_canvas_single(c, e))
	else if (c.edge >= 0): ok = mm_editor_delete_edge(e, c.edge)
	if (ok): mm_canvas_reset(c, e)
	return ok

# Preserve an existing node selection by identity across history navigation.
# Removed/reordered nodes can never leave an index pointing at another entity.
int mm_canvas_undo(mm_canvas* c, mm_editor* e, int redo):
	char* id = 0
	if (c.node >= 0 && c.node < e.document.nodes.length): id = strclone(e.document.nodes[c.node].id)
	mm_canvas_reset(c, e)
	int ok = mm_editor_undo(e, redo)
	if (id != 0):
		c.node = mm_find_node(e.document, id)
		free(id)
	return ok
