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
	if (e.document.kind != MM_FLOW && e.document.kind != MM_ER): return -1
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

# Returns 1 only when a click mode committed a source change.
int mm_canvas_press(mm_canvas* c, mm_editor* e, float32 x, float32 y):
	int wx = cast(int, (x - c.pan_x) / c.zoom)
	int wy = cast(int, (y - c.pan_y) / c.zoom)
	if (c.move_here && mm_editor_can_move(e, c.node)):
		int ok = mm_editor_move_node(e, c.node, mm_canvas_bound_x(wx), mm_canvas_bound_y(e, wy))
		c.move_here = 0
		return ok
	int hit = mm_editor_hit(e, wx, wy)
	if (c.connect_from >= 0 && hit >= 0):
		int ok = 0
		if (e.document.kind == MM_ER): ok = mm_editor_add_relationship(e, e.document.nodes[c.connect_from].id, e.document.nodes[hit].id, c"relates", 1, 3, 0)
		else: ok = mm_editor_connect(e, e.document.nodes[c.connect_from].id, e.document.nodes[hit].id)
		c.connect_from = -1
		c.node = hit
		c.edge = -1
		return ok
	c.node = hit
	c.edge = -1
	if (hit < 0): c.edge = mm_canvas_hit_edge(c, e, x, y)
	c.press_x = x
	c.press_y = y
	c.start_pan_x = c.pan_x
	c.start_pan_y = c.pan_y
	c.dragged = 0
	c.gesture = 0
	if (hit >= 0):
		if (mm_editor_can_move(e, hit)):
			c.gesture = 2
			c.start_x = e.scene.nodes[hit].x
			c.start_y = e.scene.nodes[hit].y
	else if (c.edge < 0): c.gesture = 1
	return 0

void mm_canvas_motion(mm_canvas* c, mm_editor* e, float32 x, float32 y):
	if (c.gesture == 0): return
	float32 dx = x - c.press_x
	float32 dy = y - c.press_y
	if (c.dragged == 0):
		if (dx * dx + dy * dy < 25.0): return
		c.dragged = 1
		if (c.gesture == 2 && mm_editor_move_begin(e, c.node) == 0):
			c.gesture = 0
			return
	if (c.gesture == 1):
		c.pan_x = c.start_pan_x + dx
		c.pan_y = c.start_pan_y + dy
	else:
		mm_editor_move_preview(e, mm_canvas_bound_x(c.start_x + cast(int, dx / c.zoom)), mm_canvas_bound_y(e, c.start_y + cast(int, dy / c.zoom)))

int mm_canvas_release(mm_canvas* c, mm_editor* e):
	int changed = 0
	if (c.gesture == 2 && c.dragged): changed = mm_editor_move_commit(e)
	c.gesture = 0
	c.dragged = 0
	return changed

int mm_canvas_nudge(mm_canvas* c, mm_editor* e, int dx, int dy):
	if (mm_editor_can_move(e, c.node) == 0): return 0
	mm_bounds* b = e.scene.nodes[c.node]
	return mm_editor_move_node(e, c.node, mm_canvas_bound_x(b.x + dx), mm_canvas_bound_y(e, b.y + dy))

void mm_canvas_cycle(mm_canvas* c, mm_editor* e, int reverse):
	# Switching the visible selection always exits an armed click operation.
	mm_canvas_cancel(c, e)
	if (e.scene == 0 || e.document.nodes.length == 0): return
	if (e.document.kind != MM_FLOW && e.document.kind != MM_ER): return
	int count = e.document.nodes.length
	int next = c.node
	if (reverse && next < 0): next = 0
	for i in range(count):
		if (reverse): next = (next + count - 1) % count
		else: next = (next + 1) % count
		if (e.document.nodes[next].group == 0):
			c.node = next
			c.edge = -1
			return

int mm_canvas_delete(mm_canvas* c, mm_editor* e):
	int ok = 0
	if (c.node >= 0): ok = mm_editor_delete_node(e, c.node)
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
