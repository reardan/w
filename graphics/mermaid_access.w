# Screen-reader semantics for the Mermaid canvas (#822 on the #465 snapshots).
# The canvas is a list whose items are the diagram's nodes, groups and edges,
# each with a role, a name (its label), a description ("edge from A to B,
# label x"), window-space bounds and selected/focused states. Platform
# bridges (AT-SPI, UI Automation, NSAccessibility, the web ARIA mirror)
# publish the snapshot; their focus/select requests come back through
# mm_access_apply. Display independent: no GL or window is needed.
import graphics.mermaid_canvas
import graphics.ui.accessibility

# Items beyond this budget are summarized in the canvas description.
const int MM_ACCESS_MAX_ITEMS = 2048
const int MM_ACCESS_NONE = 0
const int MM_ACCESS_NODE = 1
const int MM_ACCESS_EDGE = 2

# Stable per-index ids above the canvas id; nodes and edges interleave so
# either list can grow without renumbering the other.
int mm_access_node_id(int canvas_id, int index):
	return canvas_id + 1 + index * 2

int mm_access_edge_id(int canvas_id, int index):
	return canvas_id + 2 + index * 2

# MM_ACCESS_NODE / MM_ACCESS_EDGE with *index set, or MM_ACCESS_NONE.
int mm_access_item(int canvas_id, int id, int* index):
	int offset = id - canvas_id - 1
	if (offset < 0 || offset >= MM_ACCESS_MAX_ITEMS * 2): return MM_ACCESS_NONE
	*index = offset / 2
	if (offset % 2 == 0): return MM_ACCESS_NODE
	return MM_ACCESS_EDGE

char* mm_access_family(int kind):
	if (kind == MM_FLOW): return c"flowchart"
	if (kind == MM_ER): return c"entity relationship diagram"
	if (kind == MM_CLASS): return c"class diagram"
	if (kind == MM_STATE): return c"state diagram"
	if (kind == MM_SEQUENCE): return c"sequence diagram"
	if (kind == MM_MINDMAP): return c"mind map"
	if (kind == MM_REQUIREMENT): return c"requirement diagram"
	if (kind == MM_GANTT): return c"Gantt chart"
	if (kind == MM_PIE): return c"pie chart"
	if (kind == MM_TIMELINE): return c"timeline"
	if (kind == MM_JOURNEY): return c"user journey"
	return c"diagram"

# Node and edge semantics exist where the scene's node boxes line up with
# the document's nodes (the graph-shaped families); other families expose
# the canvas alone, with the diagram's accessible title and description.
int mm_access_has_items(mm_editor* e):
	if (e == 0 || e.scene == 0 || e.document.error != 0): return 0
	return e.scene.nodes.length == e.document.nodes.length

char* mm_access_label(mm_node* n):
	if (n.label != 0 && n.label[0] != 0): return n.label
	return n.id

ui_rect mm_access_screen(mm_canvas* c, ui_rect viewport, int x, int y, int w, int h):
	return ui_rect_new(viewport.x + c.pan_x + cast(float32, x) * c.zoom, viewport.y + c.pan_y + cast(float32, y) * c.zoom, cast(float32, w) * c.zoom, cast(float32, h) * c.zoom)

void mm_access_text(ui_access_tree* tree, int id, int field, string_builder* text):
	ui_access_set_text(tree, id, field, text.data, text.length)
	string_free(text)

int mm_access_count_items(mm_editor* e):
	if (mm_access_has_items(e) == 0): return 0
	return e.document.nodes.length + e.document.edges.length

# The canvas summary: family, counts, title and the keyboard model.
string_builder* mm_access_summary(mm_editor* e, int exposed):
	string_builder* s = string_new()
	if (e.document.error != 0):
		string_append(s, c"Syntax error; the preview is empty. Fix the source to see the diagram.")
		return s
	string_append(s, mm_access_family(e.document.kind))
	if (mm_access_has_items(e)):
		int groups = 0
		for mm_node* n in e.document.nodes:
			if (n.group): groups = groups + 1
		string_append(s, c", ")
		string_append_int(s, e.document.nodes.length - groups)
		string_append(s, c" nodes, ")
		if (groups > 0):
			string_append_int(s, groups)
			string_append(s, c" groups, ")
		string_append_int(s, e.document.edges.length)
		string_append(s, c" edges")
		if (exposed < mm_access_count_items(e)):
			string_append(s, c"; first ")
			string_append_int(s, exposed)
			string_append(s, c" listed")
	if (e.document.accessibility_description != 0 && e.document.accessibility_description[0] != 0):
		string_append(s, c". ")
		string_append(s, e.document.accessibility_description)
	if (mm_canvas_edit_family(e.document.kind)): string_append(s, c". Tab and Shift+Tab select, Space adds to the selection, Ctrl+A selects all, arrows move, Alt+arrows resize, Delete removes, Ctrl+R edits the label.")
	return s

string_builder* mm_access_node_description(mm_editor* e, int index):
	mm_document* d = e.document
	mm_node* n = d.nodes[index]
	string_builder* s = string_new()
	if (n.group):
		int members = 0
		for mm_node* other in d.nodes:
			if (other.parent == index): members = members + 1
		string_append(s, c"group ")
		string_append(s, n.id)
		string_append(s, c" containing ")
		string_append_int(s, members)
		string_append(s, c" items")
		return s
	int outgoing = 0
	int incoming = 0
	for mm_edge* edge in d.edges:
		if (edge.from_node == index): outgoing = outgoing + 1
		if (edge.to_node == index): incoming = incoming + 1
	string_append(s, c"node ")
	string_append(s, n.id)
	if (n.parent >= 0 && n.parent < d.nodes.length && d.nodes[n.parent].group):
		string_append(s, c" in ")
		string_append(s, mm_access_label(d.nodes[n.parent]))
	string_append(s, c", ")
	string_append_int(s, outgoing)
	string_append(s, c" outgoing, ")
	string_append_int(s, incoming)
	string_append(s, c" incoming")
	if (mm_editor_can_move(e, index)): string_append(s, c", movable")
	return s

char* mm_access_endpoint(mm_document* d, int index):
	if (index < 0 || index >= d.nodes.length): return c"?"
	return mm_access_label(d.nodes[index])

# Accessible name of edge index: "Alpha to Beta" plus ": label" when set.
string_builder* mm_access_edge_name(mm_document* d, int index):
	mm_edge* edge = d.edges[index]
	string_builder* s = string_from(mm_access_endpoint(d, edge.from_node))
	string_append(s, c" to ")
	string_append(s, mm_access_endpoint(d, edge.to_node))
	if (edge.label != 0 && edge.label[0] != 0):
		string_append(s, c": ")
		string_append(s, edge.label)
	return s

string_builder* mm_access_edge_description(mm_document* d, int index):
	mm_edge* edge = d.edges[index]
	string_builder* s = string_from(c"edge from ")
	string_append(s, mm_access_endpoint(d, edge.from_node))
	string_append(s, c" to ")
	string_append(s, mm_access_endpoint(d, edge.to_node))
	if (edge.label != 0 && edge.label[0] != 0):
		string_append(s, c", label ")
		string_append(s, edge.label)
	if (edge.dashed): string_append(s, c", dashed")
	return s

ui_rect mm_access_edge_bounds(mm_canvas* c, mm_editor* e, ui_rect viewport, int index):
	mm_edge* edge = e.document.edges[index]
	int count = e.scene.nodes.length
	if (edge.from_node < 0 || edge.from_node >= count || edge.to_node < 0 || edge.to_node >= count): return ui_rect_new(viewport.x, viewport.y, 0.0, 0.0)
	mm_bounds* a = e.scene.nodes[edge.from_node]
	mm_bounds* b = e.scene.nodes[edge.to_node]
	# The span between the two endpoint centers: cheap and stable per frame.
	int ax = a.x + a.w / 2
	int ay = a.y + a.h / 2
	int bx = b.x + b.w / 2
	int by = b.y + b.h / 2
	int x = ax
	int y = ay
	if (bx < x): x = bx
	if (by < y): y = by
	int w = ax - bx
	int h = ay - by
	if (w < 0): w = 0 - w
	if (h < 0): h = 0 - h
	return mm_access_screen(c, viewport, x, y, w + 1, h + 1)

# Add the canvas (id canvas_id, under parent_id) and its items to a snapshot
# being captured. focused: the canvas holds keyboard focus; the selected item
# (or the canvas) then becomes tree.focused_id. Call after ui_end, which
# otherwise recomputes the focused id from widgets alone. Returns the canvas.
ui_access_node* mm_access_canvas(ui_access_tree* tree, int parent_id, int canvas_id, mm_canvas* c, mm_editor* e, ui_rect viewport, int focused):
	if (tree == 0 || e == 0): return 0
	ui_access_node* canvas = ui_access_add(tree, canvas_id, parent_id, UI_ACCESS_LIST, viewport)
	if (canvas == 0): return 0
	canvas.states = UI_ACCESS_FOCUSABLE
	canvas.actions = UI_ACCESS_FOCUS
	string_builder* name = string_from(c"Diagram canvas")
	char* title = e.document.accessibility_title
	if (title == 0 || title[0] == 0): title = e.document.title
	if (title != 0 && title[0] != 0):
		string_append(name, c": ")
		string_append(name, title)
	mm_access_text(tree, canvas_id, UI_ACCESS_NAME, name)
	int exposed = mm_access_count_items(e)
	if (exposed > MM_ACCESS_MAX_ITEMS): exposed = MM_ACCESS_MAX_ITEMS
	mm_access_text(tree, canvas_id, UI_ACCESS_DESCRIPTION, mm_access_summary(e, exposed))
	int selectable = mm_canvas_edit_family(e.document.kind) && e.document.error == 0
	int focus_id = canvas_id
	int added = 0
	if (mm_access_has_items(e)):
		mm_document* d = e.document
		for i in range(d.nodes.length):
			if (added >= exposed): break
			mm_bounds* b = e.scene.nodes[i]
			int id = mm_access_node_id(canvas_id, i)
			int role = UI_ACCESS_LIST_ITEM
			if (d.nodes[i].group): role = UI_ACCESS_GROUP
			ui_access_node* item = ui_access_add(tree, id, canvas_id, role, mm_access_screen(c, viewport, b.x, b.y, b.w, b.h))
			if (item == 0): break
			added = added + 1
			item.states = UI_ACCESS_FOCUSABLE
			item.actions = UI_ACCESS_FOCUS
			if (selectable && mm_canvas_selectable(e, i)):
				item.actions = item.actions | UI_ACCESS_ACTIVATE
			# Every member of a multi-selection is SELECTED; the focused one
			# carries focus.
			if (mm_canvas_selected(c, i)): item.states = item.states | UI_ACCESS_SELECTED
			if (c.node == i): focus_id = id
			char* label = mm_access_label(d.nodes[i])
			ui_access_set_text(tree, id, UI_ACCESS_NAME, label, strlen(label))
			mm_access_text(tree, id, UI_ACCESS_DESCRIPTION, mm_access_node_description(e, i))
		for i in range(d.edges.length):
			if (added >= exposed): break
			int id = mm_access_edge_id(canvas_id, i)
			ui_access_node* item = ui_access_add(tree, id, canvas_id, UI_ACCESS_LIST_ITEM, mm_access_edge_bounds(c, e, viewport, i))
			if (item == 0): break
			added = added + 1
			item.states = UI_ACCESS_FOCUSABLE
			item.actions = UI_ACCESS_FOCUS
			if (selectable): item.actions = item.actions | UI_ACCESS_ACTIVATE
			if (c.edge == i):
				item.states = item.states | UI_ACCESS_SELECTED
				focus_id = id
			mm_access_text(tree, id, UI_ACCESS_NAME, mm_access_edge_name(d, i))
			mm_access_text(tree, id, UI_ACCESS_DESCRIPTION, mm_access_edge_description(d, i))
	if (focused): tree.focused_id = focus_id
	return canvas

# Select item id (an assistive focus or select request); 1 on success.
int mm_access_select(int canvas_id, int id, mm_canvas* c, mm_editor* e):
	int index = -1
	int kind = mm_access_item(canvas_id, id, &index)
	if (kind == MM_ACCESS_NONE || mm_access_has_items(e) == 0): return 0
	if (kind == MM_ACCESS_NODE && index >= e.document.nodes.length): return 0
	if (kind == MM_ACCESS_EDGE && index >= e.document.edges.length): return 0
	# Like Tab selection, a new selection exits armed click operations.
	mm_canvas_cancel(c, e)
	c.node = -1
	c.edge = -1
	if (kind == MM_ACCESS_NODE):
		# Groups select like nodes (as with Tab); synthetic containers do not.
		if (mm_canvas_selectable(e, index) == 0): return 0
		mm_canvas_clear_selection(c)
		c.node = index
	else: c.edge = index
	return 1

# Apply this frame's assistive requests aimed at canvas items: a focus
# request (the widget callback already moved ctx.focus to the item) or a
# queued activate/select. Focus returns to the canvas id, which owns the
# keyboard. Call between ui_begin and ui_end; 1 when the selection changed.
int mm_access_apply(ui_context* ctx, int canvas_id, mm_canvas* c, mm_editor* e):
	int changed = 0
	if (ctx.focus != canvas_id):
		int index = -1
		if (mm_access_item(canvas_id, ctx.focus, &index) != MM_ACCESS_NONE):
			changed = mm_access_select(canvas_id, ctx.focus, c, e)
			ctx.focus = canvas_id
	int i = 0
	while (i < ctx.access_activation_count):
		int id = ctx.access_activations[i]
		int index = -1
		if (mm_access_item(canvas_id, id, &index) != MM_ACCESS_NONE && ui_access_take_activation(ctx, id)):
			if (mm_access_select(canvas_id, id, c, e)): changed = 1
			ctx.focus = canvas_id
			ctx.focus_visible = 1
		else: i = i + 1
	return changed
