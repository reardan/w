# Geometry of the named flowchart shapes (flowchart.w codes 40-75) as scene
# primitives. Curved outlines are sampled into polygons, so the SVG export and
# the native preview draw the same outline.
import libs.extras.mermaid.flowchart
import libs.extras.mermaid.text

int mm_flow_text_height(char* label):
	mm_text_block* t = mm_text_layout(label, MM_TEXT_WRAP)
	int height = t.height
	mm_text_block_free(t)
	return height

mm_primitive* mm_flow_polygon(mm_scene* s, mm_bounds* b):
	mm_draw(s, MM_POLYGON, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
	mm_primitive* p = s.items[s.items.length - 1]
	p.points = new list[int]
	return p

void mm_flow_point(mm_primitive* p, int x, int y):
	p.points.push(x)
	p.points.push(y)

# Ellipse arc from degree `from` to `to` (screen coordinates, y down), sampled every 15 degrees.
void mm_flow_arc(mm_primitive* p, int cx, int cy, int rx, int ry, int from, int to):
	int steps = (to - from) / 15
	if (steps < 0): steps = 0 - steps
	if (steps == 0): steps = 1
	for i in range(steps + 1):
		float angle = cast(float, from + (to - from) * i / steps) * 3.14159265 / 180.0
		mm_flow_point(p, cx + cast(int, fcos(angle) * cast(float, rx)), cy + cast(int, fsin(angle) * cast(float, ry)))

# The same arc as connected strokes, for front edges inside a filled outline.
void mm_flow_arc_lines(mm_scene* s, int cx, int cy, int rx, int ry, int from, int to):
	int steps = (to - from) / 15
	if (steps < 0): steps = 0 - steps
	if (steps == 0): steps = 1
	int px = 0
	int py = 0
	for i in range(steps + 1):
		float angle = cast(float, from + (to - from) * i / steps) * 3.14159265 / 180.0
		int x = cx + cast(int, fcos(angle) * cast(float, rx))
		int y = cy + cast(int, fsin(angle) * cast(float, ry))
		if (i > 0): mm_line(s, px, py, x, y, 0)
		px = x
		py = y

# A sine wave from (x0, y) to (x1, y); amplitude `a`.
void mm_flow_wave(mm_primitive* p, int x0, int x1, int y, int a):
	for i in range(17):
		float t = cast(float, i) / 16.0
		int x = x0 + cast(int, cast(float, x1 - x0) * t)
		mm_flow_point(p, x, y + cast(int, fsin(t * 6.2831853) * cast(float, a)))

void mm_flow_document(mm_scene* s, int x, int y, int w, int h):
	mm_bounds box
	box.x = x
	box.y = y
	box.w = w
	box.h = h
	mm_primitive* p = mm_flow_polygon(s, &box)
	mm_flow_point(p, x, y)
	mm_flow_point(p, x + w, y)
	mm_flow_wave(p, x + w, x, y + h - 8, 8)

void mm_flow_rect_points(mm_scene* s, int x, int y, int w, int h):
	mm_bounds box
	box.x = x
	box.y = y
	box.w = w
	box.h = h
	mm_primitive* p = mm_flow_polygon(s, &box)
	mm_flow_point(p, x, y)
	mm_flow_point(p, x + w, y)
	mm_flow_point(p, x + w, y + h)
	mm_flow_point(p, x, y + h)

int mm_flow_metadata_number(mm_node* n, char* key, int fallback):
	char* value = mm_flow_property(n, key)
	if (value == 0): return fallback
	int number = mm_flow_dimension(value)
	if (number < 0): return fallback
	return number

int mm_flow_label_top(mm_node* n):
	char* pos = mm_flow_property(n, c"pos")
	return pos != 0 && strcmp(pos, c"t") == 0

# Shapes drawn without an inner label (markers and pictograms).
int mm_flow_shape_unlabeled(int shape):
	return shape == MM_FLOW_SMALL_CIRCLE || shape == MM_FLOW_FRAMED_CIRCLE || shape == MM_FLOW_FILLED_CIRCLE || shape == MM_FLOW_CROSSED_CIRCLE || shape == MM_FLOW_FORK || shape == MM_FLOW_BOLT

# Sizes for named shapes; `text_w`/`text_h` measure the wrapped label.
void mm_flow_shape_measure(mm_node* n, mm_bounds* b, char* direction, int text_w, int text_h):
	int shape = n.shape
	int extra = text_h - MM_TEXT_LINE
	if (shape == MM_FLOW_CYLINDER): b.h = 84 + extra
	else if (shape == MM_FLOW_LINED_CYLINDER): b.h = 100 + extra
	else if (shape == MM_FLOW_DOUBLE_CIRCLE): b.h = b.w
	else if (shape == MM_FLOW_SMALL_CIRCLE || shape == MM_FLOW_FRAMED_CIRCLE):
		b.w = 28
		b.h = 28
	else if (shape == MM_FLOW_FILLED_CIRCLE):
		b.w = 20
		b.h = 20
	else if (shape == MM_FLOW_CROSSED_CIRCLE):
		b.w = 40
		b.h = 40
	else if (shape == MM_FLOW_BOLT):
		b.w = 40
		b.h = 64
	else if (shape == MM_FLOW_FORK):
		b.w = 100
		b.h = 14
		if (strcmp(direction, c"LR") == 0 || strcmp(direction, c"RL") == 0):
			b.w = 14
			b.h = 100
	else if (shape == MM_FLOW_DOCUMENT || shape == MM_FLOW_LINED_DOCUMENT || shape == MM_FLOW_TAGGED_DOCUMENT || shape == MM_FLOW_FLAG): b.h = 76 + extra
	else if (shape == MM_FLOW_STACKED_DOCUMENT || shape == MM_FLOW_STACKED_RECT):
		b.w = b.w + 12
		b.h = b.h + 24
	else if (shape == MM_FLOW_DIVIDED_RECT || shape == MM_FLOW_WINDOW_PANE): b.h = b.h + 12
	else if (shape == MM_FLOW_TRIANGLE || shape == MM_FLOW_FLIPPED_TRIANGLE):
		b.w = b.w + b.w / 2
		b.h = 100 + extra
	else if (shape == MM_FLOW_HOURGLASS):
		b.w = 80
		if (text_w + 20 > b.w): b.w = text_w + 20
		b.h = 80 + text_h + 8
	else if (shape == MM_FLOW_ICON || shape == MM_FLOW_IMAGE):
		int size = mm_flow_metadata_number(n, c"h", 48)
		if (size < 48 && shape == MM_FLOW_ICON): size = 48
		if (shape == MM_FLOW_IMAGE): size = mm_flow_metadata_number(n, c"h", 80)
		int width = size
		if (shape == MM_FLOW_IMAGE):
			width = mm_flow_metadata_number(n, c"w", size)
			char* constraint = mm_flow_property(n, c"constraint")
			if (constraint != 0 && strcmp(constraint, c"on") == 0): width = size
		b.w = width + 16
		if (text_w + 16 > b.w): b.w = text_w + 16
		b.h = size + 8
		if (n.label[0] != 0): b.h = b.h + text_h + 8

# Draw the outline of a named shape. Returns 1 when the shape placed its own
# label (or has none), 0 when the caller centers the label in the bounds.
int mm_flow_shape_draw(mm_scene* s, mm_node* n, mm_bounds* b):
	int shape = n.shape
	int x = b.x
	int y = b.y
	int w = b.w
	int h = b.h
	int cx = x + w / 2
	int cy = y + h / 2
	if (shape == MM_FLOW_CYLINDER || shape == MM_FLOW_LINED_CYLINDER):
		int ry = 10
		mm_primitive* p = mm_flow_polygon(s, b)
		mm_flow_point(p, x, y + ry)
		mm_flow_arc(p, cx, y + h - ry, w / 2, ry, 180, 0)
		mm_flow_arc(p, cx, y + ry, w / 2, ry, 0, -180)
		mm_flow_arc_lines(s, cx, y + ry, w / 2, ry, 180, 0)
		int body = y + ry * 2
		if (shape == MM_FLOW_LINED_CYLINDER):
			mm_flow_arc_lines(s, cx, y + ry * 3, w / 2, ry, 180, 0)
			body = y + ry * 4
		mm_label(s, cx, body + (y + h - ry - body - mm_flow_text_height(n.label)) / 2, n.label, MM_TEXT_WRAP, 1)
		return 1
	else if (shape == MM_FLOW_H_CYLINDER):
		int rx = 12
		mm_primitive* p = mm_flow_polygon(s, b)
		mm_flow_point(p, x + rx, y)
		mm_flow_arc(p, x + w - rx, cy, rx, h / 2, -90, 90)
		mm_flow_arc(p, x + rx, cy, rx, h / 2, 90, 270)
		mm_flow_arc_lines(s, x + w - rx, cy, rx, h / 2, 90, 270)
	else if (shape == MM_FLOW_ODD):
		mm_primitive* p = mm_flow_polygon(s, b)
		mm_flow_point(p, x, y)
		mm_flow_point(p, x + w, y)
		mm_flow_point(p, x + w, y + h)
		mm_flow_point(p, x, y + h)
		mm_flow_point(p, x + 20, cy)
	else if (shape == MM_FLOW_DOUBLE_CIRCLE):
		mm_draw(s, MM_CIRCLE, x, y, x + w, y + w, 0, c"")
		mm_draw(s, MM_CIRCLE, x + 6, y + 6, x + w - 6, y + w - 6, 0, c"")
	else if (shape == MM_FLOW_SMALL_CIRCLE): mm_draw(s, MM_CIRCLE, x, y, x + w, y + w, 0, c"")
	else if (shape == MM_FLOW_FRAMED_CIRCLE):
		mm_draw(s, MM_CIRCLE, x, y, x + w, y + w, 0, c"")
		mm_draw(s, MM_CIRCLE, x + 6, y + 6, x + w - 6, y + w - 6, 1, c"")
	else if (shape == MM_FLOW_FILLED_CIRCLE): mm_draw(s, MM_CIRCLE, x, y, x + w, y + w, 1, c"")
	else if (shape == MM_FLOW_CROSSED_CIRCLE):
		mm_draw(s, MM_CIRCLE, x, y, x + w, y + w, 0, c"")
		int d = w * 707 / 2000
		mm_line(s, cx - d, cy - d, cx + d, cy + d, 0)
		mm_line(s, cx - d, cy + d, cx + d, cy - d, 0)
	else if (shape == MM_FLOW_DOCUMENT || shape == MM_FLOW_LINED_DOCUMENT || shape == MM_FLOW_TAGGED_DOCUMENT):
		mm_flow_document(s, x, y, w, h)
		if (shape == MM_FLOW_LINED_DOCUMENT): mm_line(s, x + 10, y, x + 10, y + h - 8, 0)
		if (shape == MM_FLOW_TAGGED_DOCUMENT):
			mm_bounds tag
			tag.x = x + w - 18
			tag.y = y + h - 30
			tag.w = 18
			tag.h = 22
			mm_primitive* p = mm_flow_polygon(s, &tag)
			p.dashed = 1
			mm_flow_point(p, x + w, y + h - 30)
			mm_flow_point(p, x + w, y + h - 10)
			mm_flow_point(p, x + w - 18, y + h - 12)
	else if (shape == MM_FLOW_STACKED_DOCUMENT):
		mm_flow_document(s, x + 12, y, w - 12, h - 24)
		mm_flow_document(s, x + 6, y + 12, w - 12, h - 24)
		mm_flow_document(s, x, y + 24, w - 12, h - 24)
		mm_label(s, x + (w - 12) / 2, y + 24 + (h - 24 - 8 - mm_flow_text_height(n.label)) / 2, n.label, MM_TEXT_WRAP, 1)
		return 1
	else if (shape == MM_FLOW_STACKED_RECT):
		mm_flow_rect_points(s, x + 12, y, w - 12, h - 24)
		mm_flow_rect_points(s, x + 6, y + 12, w - 12, h - 24)
		mm_flow_rect_points(s, x, y + 24, w - 12, h - 24)
		mm_label(s, x + (w - 12) / 2, y + 24 + (h - 24 - mm_flow_text_height(n.label)) / 2, n.label, MM_TEXT_WRAP, 1)
		return 1
	else if (shape == MM_FLOW_LINED_RECT):
		mm_flow_rect_points(s, x, y, w, h)
		mm_line(s, x + 10, y, x + 10, y + h, 0)
	else if (shape == MM_FLOW_DIVIDED_RECT):
		mm_flow_rect_points(s, x, y, w, h)
		mm_line(s, x, y + 14, x + w, y + 14, 0)
	else if (shape == MM_FLOW_WINDOW_PANE):
		mm_flow_rect_points(s, x, y, w, h)
		mm_line(s, x, y + 12, x + w, y + 12, 0)
		mm_line(s, x + 12, y, x + 12, y + h, 0)
	else if (shape == MM_FLOW_TAGGED_RECT):
		mm_flow_rect_points(s, x, y, w, h)
		mm_bounds tag
		tag.x = x + w - 18
		tag.y = y + h - 18
		tag.w = 18
		tag.h = 18
		mm_primitive* p = mm_flow_polygon(s, &tag)
		p.dashed = 1
		mm_flow_point(p, x + w, y + h - 18)
		mm_flow_point(p, x + w, y + h)
		mm_flow_point(p, x + w - 18, y + h)
	else if (shape == MM_FLOW_NOTCHED_RECT):
		mm_primitive* p = mm_flow_polygon(s, b)
		mm_flow_point(p, x + 16, y)
		mm_flow_point(p, x + w, y)
		mm_flow_point(p, x + w, y + h)
		mm_flow_point(p, x, y + h)
		mm_flow_point(p, x, y + 16)
	else if (shape == MM_FLOW_SLOPED_RECT):
		mm_primitive* p = mm_flow_polygon(s, b)
		mm_flow_point(p, x, y + 16)
		mm_flow_point(p, x + w, y)
		mm_flow_point(p, x + w, y + h)
		mm_flow_point(p, x, y + h)
	else if (shape == MM_FLOW_BOW_TIE):
		int rx = 12
		mm_primitive* p = mm_flow_polygon(s, b)
		mm_flow_point(p, x + rx, y)
		mm_flow_arc(p, x + w, cy, rx, h / 2, 270, 90)
		mm_flow_arc(p, x + rx, cy, rx, h / 2, 90, 270)
	else if (shape == MM_FLOW_CURVED_TRAPEZOID):
		int rx = 16
		mm_primitive* p = mm_flow_polygon(s, b)
		mm_flow_point(p, x + 20, y)
		mm_flow_arc(p, x + w - rx, cy, rx, h / 2, -90, 90)
		mm_flow_point(p, x + 20, y + h)
		mm_flow_point(p, x, cy)
	else if (shape == MM_FLOW_DELAY):
		mm_primitive* p = mm_flow_polygon(s, b)
		mm_flow_point(p, x, y)
		mm_flow_arc(p, x + w - h / 2, cy, h / 2, h / 2, -90, 90)
		mm_flow_point(p, x, y + h)
	else if (shape == MM_FLOW_TRIANGLE):
		mm_primitive* p = mm_flow_polygon(s, b)
		mm_flow_point(p, cx, y)
		mm_flow_point(p, x + w, y + h)
		mm_flow_point(p, x, y + h)
		mm_label(s, cx, y + h - 12 - mm_flow_text_height(n.label), n.label, MM_TEXT_WRAP, 1)
		return 1
	else if (shape == MM_FLOW_FLIPPED_TRIANGLE):
		mm_primitive* p = mm_flow_polygon(s, b)
		mm_flow_point(p, x, y)
		mm_flow_point(p, x + w, y)
		mm_flow_point(p, cx, y + h)
		mm_label(s, cx, y + 12, n.label, MM_TEXT_WRAP, 1)
		return 1
	else if (shape == MM_FLOW_HOURGLASS):
		int left = cx - 40
		mm_primitive* p = mm_flow_polygon(s, b)
		mm_flow_point(p, left, y)
		mm_flow_point(p, left + 80, y)
		mm_flow_point(p, left, y + 80)
		mm_flow_point(p, left + 80, y + 80)
		mm_label(s, cx, y + 88, n.label, MM_TEXT_WRAP, 1)
		return 1
	else if (shape == MM_FLOW_BOLT):
		mm_primitive* p = mm_flow_polygon(s, b)
		p.dashed = 1
		mm_flow_point(p, x + w * 6 / 10, y)
		mm_flow_point(p, x + w * 2 / 10, y + h * 55 / 100)
		mm_flow_point(p, x + w / 2, y + h * 55 / 100)
		mm_flow_point(p, x + w * 4 / 10, y + h)
		mm_flow_point(p, x + w * 8 / 10, y + h * 45 / 100)
		mm_flow_point(p, x + w / 2, y + h * 45 / 100)
	else if (shape == MM_FLOW_BRACE_LEFT || shape == MM_FLOW_BRACE_RIGHT || shape == MM_FLOW_BRACES):
		for side in range(2):
			if (side == 0 && shape == MM_FLOW_BRACE_RIGHT): continue
			if (side == 1 && shape == MM_FLOW_BRACE_LEFT): continue
			int edge = x
			int sign = 1
			if (side == 1):
				edge = x + w
				sign = -1
			mm_line(s, edge + sign * 12, y, edge + sign * 6, y + 6, 0)
			mm_line(s, edge + sign * 6, y + 6, edge + sign * 6, cy - 6, 0)
			mm_line(s, edge + sign * 6, cy - 6, edge, cy, 0)
			mm_line(s, edge, cy, edge + sign * 6, cy + 6, 0)
			mm_line(s, edge + sign * 6, cy + 6, edge + sign * 6, y + h - 6, 0)
			mm_line(s, edge + sign * 6, y + h - 6, edge + sign * 12, y + h, 0)
	else if (shape == MM_FLOW_FLAG):
		mm_primitive* p = mm_flow_polygon(s, b)
		mm_flow_wave(p, x, x + w, y + 8, 8)
		mm_flow_wave(p, x + w, x, y + h - 8, 8)
	else if (shape == MM_FLOW_FORK): mm_draw(s, MM_BOX, x, y, x + w, y + h, 2, c"")
	else if (shape == MM_FLOW_LOOP_LIMIT):
		mm_primitive* p = mm_flow_polygon(s, b)
		mm_flow_point(p, x + 16, y)
		mm_flow_point(p, x + w - 16, y)
		mm_flow_point(p, x + w, y + 16)
		mm_flow_point(p, x + w, y + h)
		mm_flow_point(p, x, y + h)
		mm_flow_point(p, x, y + 16)
	else if (shape == MM_FLOW_ICON || shape == MM_FLOW_IMAGE):
		int size = b.h - 8
		if (n.label[0] != 0): size = size - mm_flow_text_height(n.label) - 8
		int width = size
		if (shape == MM_FLOW_IMAGE):
			width = mm_flow_metadata_number(n, c"w", size)
			char* constraint = mm_flow_property(n, c"constraint")
			if (constraint != 0 && strcmp(constraint, c"on") == 0): width = size
		int top = mm_flow_label_top(n) && n.label[0] != 0
		int area_y = y + 4
		if (top): area_y = y + mm_flow_text_height(n.label) + 12
		int left = cx - width / 2
		if (shape == MM_FLOW_ICON):
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
		return 1
	else if (shape == MM_FLOW_DATASTORE):
		# Data-flow store: open on the right, with an identifier compartment on the left.
		mm_draw(s, MM_BOX, x, y, x + w, y + h, 0, c"")
		mm_primitive* p = s.items[s.items.length - 1]
		p.style.mask = 2
		p.style.stroke = -1
		mm_line(s, x, y, x + w, y, 0)
		mm_line(s, x, y + h, x + w, y + h, 0)
		mm_line(s, x, y, x, y + h, 0)
		mm_line(s, x + 16, y, x + 16, y + h, 0)
	else if (shape == MM_FLOW_TEXT): return 0
	else: mm_flow_rect_points(s, x, y, w, h)
	if (mm_flow_shape_unlabeled(shape)): return 1
	return 0

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
