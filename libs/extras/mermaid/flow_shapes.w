# Flowchart rendering of the named shapes: the outlines, sizes and label
# offsets are the shared catalogue ones (shapes.w); this file adds the
# flowchart's wrapped labels, `w` / `h` / `pos` metadata and the icon and
# image nodes.
import libs.extras.mermaid.flowchart
import libs.extras.mermaid.text
import libs.extras.mermaid.shapes

int mm_flow_text_height(char* label):
	mm_text_block* t = mm_text_layout(label, MM_TEXT_WRAP)
	int height = t.height
	mm_text_block_free(t)
	return height

int mm_flow_metadata_number(mm_node* n, char* key, int fallback):
	char* value = mm_flow_property(n, key)
	if (value == 0): return fallback
	int number = mm_flow_dimension(value)
	if (number < 0): return fallback
	return number

int mm_flow_label_top(mm_node* n):
	char* pos = mm_flow_property(n, c"pos")
	return pos != 0 && strcmp(pos, c"t") == 0

# Sizes for named shapes; `text_w`/`text_h` measure the wrapped label.
void mm_flow_shape_measure(mm_node* n, mm_bounds* b, char* direction, int text_w, int text_h):
	int shape = n.shape
	if (shape == MM_SHAPE_ICON || shape == MM_SHAPE_IMAGE):
		int size = mm_flow_metadata_number(n, c"h", 48)
		if (size < 48 && shape == MM_SHAPE_ICON): size = 48
		if (shape == MM_SHAPE_IMAGE): size = mm_flow_metadata_number(n, c"h", 80)
		int width = size
		if (shape == MM_SHAPE_IMAGE):
			width = mm_flow_metadata_number(n, c"w", size)
			char* constraint = mm_flow_property(n, c"constraint")
			if (constraint != 0 && strcmp(constraint, c"on") == 0): width = size
		b.w = width + 16
		if (text_w + 16 > b.w): b.w = text_w + 16
		b.h = size + 8
		if (n.label[0] != 0): b.h = b.h + text_h + 8
	else: mm_shape_measure(shape, b, direction, text_w, text_h)

# An icon or image node: the placeholder glyph or frame and its label.
void mm_flow_media_draw(mm_scene* s, mm_node* n, mm_bounds* b):
	int shape = n.shape
	int y = b.y
	int cx = b.x + b.w / 2
	int size = b.h - 8
	if (n.label[0] != 0): size = size - mm_flow_text_height(n.label) - 8
	int width = size
	if (shape == MM_SHAPE_IMAGE):
		width = mm_flow_metadata_number(n, c"w", size)
		char* constraint = mm_flow_property(n, c"constraint")
		if (constraint != 0 && strcmp(constraint, c"on") == 0): width = size
	int top = mm_flow_label_top(n) && n.label[0] != 0
	int area_y = y + 4
	if (top): area_y = y + mm_flow_text_height(n.label) + 12
	int left = cx - width / 2
	if (shape == MM_SHAPE_ICON):
		char* form = mm_flow_property(n, c"form")
		if (form != 0 && strcmp(form, c"circle") == 0): mm_draw(s, MM_CIRCLE, left, area_y, left + size, area_y + size, 0, c"")
		else if (form != 0): mm_draw(s, MM_BOX, left, area_y, left + size, area_y + size, strcmp(form, c"rounded") == 0, c"")
		# Icon packs are not bundled: a framed glyph placeholder marks the icon.
		mm_line(s, cx - size / 4, area_y + size / 4, cx + size / 4, area_y + size / 4, 0)
		mm_line(s, cx + size / 4, area_y + size / 4, cx + size / 4, area_y + size * 3 / 4, 0)
		mm_line(s, cx + size / 4, area_y + size * 3 / 4, cx - size / 4, area_y + size * 3 / 4, 0)
		mm_line(s, cx - size / 4, area_y + size * 3 / 4, cx - size / 4, area_y + size / 4, 0)
	else:
		# Remote images are never fetched; the frame keeps their geometry.
		mm_draw(s, MM_BOX, left, area_y, left + width, area_y + size, 0, c"")
		mm_line(s, left, area_y, left + width, area_y + size, 0)
		mm_line(s, left, area_y + size, left + width, area_y, 0)
	if (n.label[0] != 0):
		int label_y = area_y + size + 8
		if (top): label_y = y + 4
		mm_label(s, cx, label_y, n.label, MM_TEXT_WRAP, 1)

# Draw the outline of a named shape. Returns 1 when the shape placed its own
# label (or has none), 0 when the caller centers the label in the bounds.
int mm_flow_shape_draw(mm_scene* s, mm_node* n, mm_bounds* b):
	int shape = n.shape
	if (shape == MM_SHAPE_ICON || shape == MM_SHAPE_IMAGE):
		mm_flow_media_draw(s, n, b)
		return 1
	mm_shape_draw(s, shape, b.x, b.y, b.w, b.h)
	if (mm_shape_label_placed(shape)):
		int x = b.x + b.w / 2
		if (shape == MM_SHAPE_DOCUMENTS || shape == MM_SHAPE_PROCESSES): x = b.x + (b.w - 12) / 2
		mm_label(s, x, b.y + mm_shape_label_y(shape, b.h, mm_flow_text_height(n.label)), n.label, MM_TEXT_WRAP, 1)
		return 1
	return mm_shape_unlabeled(shape)

# A subgraph with `@{ view: collapsed }` is drawn as one node; its contents are hidden.
int mm_flow_collapsed(mm_document* d, int index):
	if (d.kind != MM_FLOW || index < 0): return 0
	mm_node* n = d.nodes[index]
	if (n.group == 0): return 0
	char* view = mm_flow_property(n, c"view")
	return view != 0 && strcmp(view, c"collapsed") == 0

# The node drawn for `index`: itself, or its outermost collapsed ancestor.
int mm_flow_visible_node(mm_document* d, int index):
	if (d.kind != MM_FLOW): return index
	int visible = index
	mm_node* start = d.nodes[index]
	int at = start.parent
	int depth = 0
	while (at >= 0 && depth < 64):
		if (mm_flow_collapsed(d, at)): visible = at
		mm_node* parent = d.nodes[at]
		at = parent.parent
		depth = depth + 1
	return visible

# Link endpoint marker at (x, y); (dx, dy) points from the tip along the link.
void mm_flow_marker(mm_scene* s, int x, int y, int dx, int dy, int kind):
	if (kind == MM_ARROW):
		mm_line(s, x, y, x + dx * 10 - dy * 5, y + dy * 10 + dx * 5, 0)
		mm_line(s, x, y, x + dx * 10 + dy * 5, y + dy * 10 - dx * 5, 0)
	else if (kind == MM_FLOW_CIRCLE):
		int cx = x + dx * 5
		int cy = y + dy * 5
		mm_draw(s, MM_CIRCLE, cx - 5, cy - 5, cx + 5, cy + 5, 1, c"")
	else if (kind == MM_FLOW_CROSS):
		int cx = x + dx * 7
		int cy = y + dy * 7
		mm_line(s, cx - 5, cy - 5, cx + 5, cy + 5, 0)
		mm_line(s, cx - 5, cy + 5, cx + 5, cy - 5, 0)

# Thick, animated and per-edge-curve link strokes, applied to the primitives drawn since `start`.
void mm_flow_link_stroke(mm_scene* s, mm_edge* e, int start):
	for i in range(start, s.items.length):
		mm_primitive* p = s.items[i]
		if (e.stroke == 1 && (p.style.mask & 8) == 0):
			p.style.mask = p.style.mask | 8
			p.style.width = 4
		if (e.animate != 0 && p.kind == MM_LINE): p.dashed = 3 + e.animate

# Interaction links on a node's text runs. Unsafe URL schemes stay in the
# model only; callbacks are never exported or run.
void mm_flow_link_scene(mm_scene* s, mm_node* n, int start):
	if (n.link == 0 && n.tooltip == 0): return
	int safe = n.link != 0 && mm_link_safe(n.link)
	for i in range(start, s.items.length):
		mm_primitive* p = s.items[i]
		if (p.kind != MM_TEXT || p.text[0] == 0): continue
		if (safe && p.href == 0):
			p.href = strclone(n.link)
			if (n.link_target != 0): p.href_target = strclone(n.link_target)
		if (n.tooltip != 0 && p.tooltip == 0): p.tooltip = strclone(n.tooltip)
