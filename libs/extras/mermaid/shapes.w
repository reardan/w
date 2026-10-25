# Native outlines for the canonical node-shape catalogue (shape_catalog.w),
# the one implementation every family draws them with: flowcharts (through
# flow_shapes.w, which adds label placement and icon / image nodes),
# swimlanes, agentflow and the architecture-style extras. Curves are sampled
# into polygons and segments, so every backend that draws scene primitives
# draws every shape.
import libs.extras.mermaid.scene
import libs.extras.mermaid.shape_catalog

void mm_shape_polygon(mm_scene* s, list[int] points):
	int x = points[0]
	int y = points[1]
	int x2 = x
	int y2 = y
	for i in range(points.length / 2):
		if (points[i * 2] < x): x = points[i * 2]
		if (points[i * 2] > x2): x2 = points[i * 2]
		if (points[i * 2 + 1] < y): y = points[i * 2 + 1]
		if (points[i * 2 + 1] > y2): y2 = points[i * 2 + 1]
	mm_draw(s, MM_POLYGON, x, y, x2, y2, 0, c"")
	mm_primitive* p = s.items[s.items.length - 1]
	p.points = points

# Sampled elliptical arc from angle a0 to a1 (degrees, y down) appended to points.
void mm_shape_arc(list[int] points, int cx, int cy, int rx, int ry, int a0, int a1, int steps):
	for i in range(steps + 1):
		float angle = cast(float, a0 + (a1 - a0) * i / steps) * 3.14159265 / 180.0
		points.push(cx + cast(int, fcos(angle) * cast(float, rx)))
		points.push(cy + cast(int, fsin(angle) * cast(float, ry)))

void mm_shape_ellipse(mm_scene* s, int cx, int cy, int rx, int ry):
	list[int] points = new list[int]
	mm_shape_arc(points, cx, cy, rx, ry, 0, 345, 23)
	mm_shape_polygon(s, points)

# An empty polygon primitive with bounds (x, y, w, h); points are appended.
mm_primitive* mm_shape_outline(mm_scene* s, int x, int y, int w, int h):
	mm_draw(s, MM_POLYGON, x, y, x + w, y + h, 0, c"")
	mm_primitive* p = s.items[s.items.length - 1]
	p.points = new list[int]
	return p

void mm_shape_point(mm_primitive* p, int x, int y):
	p.points.push(x)
	p.points.push(y)

# Ellipse arc from degree `from` to `to` (screen coordinates, y down), sampled
# every 15 degrees, appended to p.
void mm_shape_arc_to(mm_primitive* p, int cx, int cy, int rx, int ry, int from, int to):
	int steps = (to - from) / 15
	if (steps < 0): steps = 0 - steps
	if (steps == 0): steps = 1
	for i in range(steps + 1):
		float angle = cast(float, from + (to - from) * i / steps) * 3.14159265 / 180.0
		mm_shape_point(p, cx + cast(int, fcos(angle) * cast(float, rx)), cy + cast(int, fsin(angle) * cast(float, ry)))

# The same arc as connected strokes, for front edges inside a filled outline.
void mm_shape_arc_lines(mm_scene* s, int cx, int cy, int rx, int ry, int from, int to):
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
void mm_shape_wave_to(mm_primitive* p, int x0, int x1, int y, int a):
	for i in range(17):
		float t = cast(float, i) / 16.0
		int x = x0 + cast(int, cast(float, x1 - x0) * t)
		mm_shape_point(p, x, y + cast(int, fsin(t * 6.2831853) * cast(float, a)))

void mm_shape_document(mm_scene* s, int x, int y, int w, int h):
	mm_primitive* p = mm_shape_outline(s, x, y, w, h)
	mm_shape_point(p, x, y)
	mm_shape_point(p, x + w, y)
	mm_shape_wave_to(p, x + w, x, y + h - 8, 8)

void mm_shape_rect(mm_scene* s, int x, int y, int w, int h):
	mm_primitive* p = mm_shape_outline(s, x, y, w, h)
	mm_shape_point(p, x, y)
	mm_shape_point(p, x + w, y)
	mm_shape_point(p, x + w, y + h)
	mm_shape_point(p, x, y + h)

# Outlines of the named flowchart shapes (cylinder ... data store).
void mm_shape_catalogue_draw(mm_scene* s, int shape, int x, int y, int w, int h):
	int cx = x + w / 2
	int cy = y + h / 2
	if (shape == MM_SHAPE_CYLINDER || shape == MM_SHAPE_LINED_CYLINDER):
		int ry = 10
		mm_primitive* p = mm_shape_outline(s, x, y, w, h)
		mm_shape_point(p, x, y + ry)
		mm_shape_arc_to(p, cx, y + h - ry, w / 2, ry, 180, 0)
		mm_shape_arc_to(p, cx, y + ry, w / 2, ry, 0, -180)
		mm_shape_arc_lines(s, cx, y + ry, w / 2, ry, 180, 0)
		if (shape == MM_SHAPE_LINED_CYLINDER): mm_shape_arc_lines(s, cx, y + ry * 3, w / 2, ry, 180, 0)
	else if (shape == MM_SHAPE_H_CYLINDER):
		int rx = 12
		mm_primitive* p = mm_shape_outline(s, x, y, w, h)
		mm_shape_point(p, x + rx, y)
		mm_shape_arc_to(p, x + w - rx, cy, rx, h / 2, -90, 90)
		mm_shape_arc_to(p, x + rx, cy, rx, h / 2, 90, 270)
		mm_shape_arc_lines(s, x + w - rx, cy, rx, h / 2, 90, 270)
	else if (shape == MM_SHAPE_ODD):
		mm_primitive* p = mm_shape_outline(s, x, y, w, h)
		mm_shape_point(p, x, y)
		mm_shape_point(p, x + w, y)
		mm_shape_point(p, x + w, y + h)
		mm_shape_point(p, x, y + h)
		mm_shape_point(p, x + 20, cy)
	else if (shape == MM_SHAPE_DOUBLE_CIRCLE):
		mm_draw(s, MM_CIRCLE, x, y, x + w, y + w, 0, c"")
		mm_draw(s, MM_CIRCLE, x + 6, y + 6, x + w - 6, y + w - 6, 0, c"")
	else if (shape == MM_SHAPE_SMALL_CIRCLE): mm_draw(s, MM_CIRCLE, x, y, x + w, y + w, 0, c"")
	else if (shape == MM_SHAPE_FRAMED_CIRCLE):
		mm_draw(s, MM_CIRCLE, x, y, x + w, y + w, 0, c"")
		mm_draw(s, MM_CIRCLE, x + 6, y + 6, x + w - 6, y + w - 6, 1, c"")
	else if (shape == MM_SHAPE_FILLED_CIRCLE): mm_draw(s, MM_CIRCLE, x, y, x + w, y + w, 1, c"")
	else if (shape == MM_SHAPE_CROSSED_CIRCLE):
		mm_draw(s, MM_CIRCLE, x, y, x + w, y + w, 0, c"")
		int d = w * 707 / 2000
		mm_line(s, cx - d, cy - d, cx + d, cy + d, 0)
		mm_line(s, cx - d, cy + d, cx + d, cy - d, 0)
	else if (shape == MM_SHAPE_DOCUMENT || shape == MM_SHAPE_LINED_DOCUMENT || shape == MM_SHAPE_TAGGED_DOCUMENT):
		mm_shape_document(s, x, y, w, h)
		if (shape == MM_SHAPE_LINED_DOCUMENT): mm_line(s, x + 10, y, x + 10, y + h - 8, 0)
		if (shape == MM_SHAPE_TAGGED_DOCUMENT):
			mm_primitive* p = mm_shape_outline(s, x + w - 18, y + h - 30, 18, 22)
			p.dashed = 1
			mm_shape_point(p, x + w, y + h - 30)
			mm_shape_point(p, x + w, y + h - 10)
			mm_shape_point(p, x + w - 18, y + h - 12)
	else if (shape == MM_SHAPE_DOCUMENTS):
		mm_shape_document(s, x + 12, y, w - 12, h - 24)
		mm_shape_document(s, x + 6, y + 12, w - 12, h - 24)
		mm_shape_document(s, x, y + 24, w - 12, h - 24)
	else if (shape == MM_SHAPE_PROCESSES):
		mm_shape_rect(s, x + 12, y, w - 12, h - 24)
		mm_shape_rect(s, x + 6, y + 12, w - 12, h - 24)
		mm_shape_rect(s, x, y + 24, w - 12, h - 24)
	else if (shape == MM_SHAPE_LINED_RECT):
		mm_shape_rect(s, x, y, w, h)
		mm_line(s, x + 10, y, x + 10, y + h, 0)
	else if (shape == MM_SHAPE_DIVIDED_RECT):
		mm_shape_rect(s, x, y, w, h)
		mm_line(s, x, y + 14, x + w, y + 14, 0)
	else if (shape == MM_SHAPE_WINDOW_PANE):
		mm_shape_rect(s, x, y, w, h)
		mm_line(s, x, y + 12, x + w, y + 12, 0)
		mm_line(s, x + 12, y, x + 12, y + h, 0)
	else if (shape == MM_SHAPE_TAGGED_RECT):
		mm_shape_rect(s, x, y, w, h)
		mm_primitive* p = mm_shape_outline(s, x + w - 18, y + h - 18, 18, 18)
		p.dashed = 1
		mm_shape_point(p, x + w, y + h - 18)
		mm_shape_point(p, x + w, y + h)
		mm_shape_point(p, x + w - 18, y + h)
	else if (shape == MM_SHAPE_CARD):
		mm_primitive* p = mm_shape_outline(s, x, y, w, h)
		mm_shape_point(p, x + 16, y)
		mm_shape_point(p, x + w, y)
		mm_shape_point(p, x + w, y + h)
		mm_shape_point(p, x, y + h)
		mm_shape_point(p, x, y + 16)
	else if (shape == MM_SHAPE_SLOPED_RECT):
		mm_primitive* p = mm_shape_outline(s, x, y, w, h)
		mm_shape_point(p, x, y + 16)
		mm_shape_point(p, x + w, y)
		mm_shape_point(p, x + w, y + h)
		mm_shape_point(p, x, y + h)
	else if (shape == MM_SHAPE_BOW_RECT):
		int rx = 12
		mm_primitive* p = mm_shape_outline(s, x, y, w, h)
		mm_shape_point(p, x + rx, y)
		mm_shape_arc_to(p, x + w, cy, rx, h / 2, 270, 90)
		mm_shape_arc_to(p, x + rx, cy, rx, h / 2, 90, 270)
	else if (shape == MM_SHAPE_CURVED_TRAP):
		int rx = 16
		mm_primitive* p = mm_shape_outline(s, x, y, w, h)
		mm_shape_point(p, x + 20, y)
		mm_shape_arc_to(p, x + w - rx, cy, rx, h / 2, -90, 90)
		mm_shape_point(p, x + 20, y + h)
		mm_shape_point(p, x, cy)
	else if (shape == MM_SHAPE_DELAY):
		mm_primitive* p = mm_shape_outline(s, x, y, w, h)
		mm_shape_point(p, x, y)
		mm_shape_arc_to(p, x + w - h / 2, cy, h / 2, h / 2, -90, 90)
		mm_shape_point(p, x, y + h)
	else if (shape == MM_SHAPE_TRIANGLE):
		mm_primitive* p = mm_shape_outline(s, x, y, w, h)
		mm_shape_point(p, cx, y)
		mm_shape_point(p, x + w, y + h)
		mm_shape_point(p, x, y + h)
	else if (shape == MM_SHAPE_FLIPPED_TRIANGLE):
		mm_primitive* p = mm_shape_outline(s, x, y, w, h)
		mm_shape_point(p, x, y)
		mm_shape_point(p, x + w, y)
		mm_shape_point(p, cx, y + h)
	else if (shape == MM_SHAPE_HOURGLASS):
		int left = cx - 40
		mm_primitive* p = mm_shape_outline(s, x, y, w, h)
		mm_shape_point(p, left, y)
		mm_shape_point(p, left + 80, y)
		mm_shape_point(p, left, y + 80)
		mm_shape_point(p, left + 80, y + 80)
	else if (shape == MM_SHAPE_BOLT):
		mm_primitive* p = mm_shape_outline(s, x, y, w, h)
		p.dashed = 1
		mm_shape_point(p, x + w * 6 / 10, y)
		mm_shape_point(p, x + w * 2 / 10, y + h * 55 / 100)
		mm_shape_point(p, x + w / 2, y + h * 55 / 100)
		mm_shape_point(p, x + w * 4 / 10, y + h)
		mm_shape_point(p, x + w * 8 / 10, y + h * 45 / 100)
		mm_shape_point(p, x + w / 2, y + h * 45 / 100)
	else if (shape == MM_SHAPE_BRACE_LEFT || shape == MM_SHAPE_BRACE_RIGHT || shape == MM_SHAPE_BRACES):
		for side in range(2):
			if (side == 0 && shape == MM_SHAPE_BRACE_RIGHT): continue
			if (side == 1 && shape == MM_SHAPE_BRACE_LEFT): continue
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
	else if (shape == MM_SHAPE_FLAG):
		mm_primitive* p = mm_shape_outline(s, x, y, w, h)
		mm_shape_wave_to(p, x, x + w, y + 8, 8)
		mm_shape_wave_to(p, x + w, x, y + h - 8, 8)
	else if (shape == MM_SHAPE_FORK): mm_draw(s, MM_BOX, x, y, x + w, y + h, 2, c"")
	else if (shape == MM_SHAPE_NOTCH_PENTAGON):
		mm_primitive* p = mm_shape_outline(s, x, y, w, h)
		mm_shape_point(p, x + 16, y)
		mm_shape_point(p, x + w - 16, y)
		mm_shape_point(p, x + w, y + 16)
		mm_shape_point(p, x + w, y + h)
		mm_shape_point(p, x, y + h)
		mm_shape_point(p, x, y + 16)
	else if (shape == MM_SHAPE_DATA_STORE):
		# Data-flow store: open on the right, with an identifier compartment on the left.
		mm_draw(s, MM_BOX, x, y, x + w, y + h, 0, c"")
		mm_primitive* p = s.items[s.items.length - 1]
		p.style.mask = 2
		p.style.stroke = -1
		mm_line(s, x, y, x + w, y, 0)
		mm_line(s, x, y + h, x + w, y + h, 0)
		mm_line(s, x, y, x, y + h, 0)
		mm_line(s, x + 16, y, x + 16, y + h, 0)
	else if (shape != MM_SHAPE_TEXT): mm_shape_rect(s, x, y, w, h)

# Whether a code is one of the named flowchart shapes (cylinder ... data store).
int mm_shape_flowchart(int shape):
	return shape >= MM_SHAPE_CYLINDER && shape <= MM_SHAPE_DATA_STORE

# Draws one node outline in the box (x, y, w, h). Unknown codes draw a rectangle.
void mm_shape_draw(mm_scene* s, int shape, int x, int y, int w, int h):
	int r = x + w
	int b = y + h
	int cx = x + w / 2
	int cy = y + h / 2
	if (mm_shape_flowchart(shape)): mm_shape_catalogue_draw(s, shape, x, y, w, h)
	else if (shape == MM_SHAPE_ROUNDED): mm_draw(s, MM_BOX, x, y, r, b, 1, c"")
	else if (shape == MM_SHAPE_CIRCLE): mm_draw(s, MM_CIRCLE, x, y, r, b, 0, c"")
	else if (shape == MM_SHAPE_DIAMOND): mm_shape_polygon(s, list[int]{cx, y, r, cy, cx, b, x, cy})
	else if (shape == MM_SHAPE_STADIUM):
		mm_draw(s, MM_BOX, x, y, r, b, 0, c"")
		mm_primitive* box = s.items[s.items.length - 1]
		box.dashed = 3
	else if (shape == MM_SHAPE_FRAMED || shape == 17):
		mm_draw(s, MM_BOX, x, y, r, b, 0, c"")
		mm_line(s, x + 10, y, x + 10, b, 0)
		mm_line(s, r - 10, y, r - 10, b, 0)
	else if (shape == MM_SHAPE_HEXAGON || shape == 20): mm_shape_polygon(s, list[int]{x + 20, y, r - 20, y, r, cy, r - 20, b, x + 20, b, x, cy})
	else if (shape == MM_SHAPE_LEAN_RIGHT || shape == 18): mm_shape_polygon(s, list[int]{x + 20, y, r, y, r - 20, b, x, b})
	else if (shape == MM_SHAPE_LEAN_LEFT): mm_shape_polygon(s, list[int]{x, y, r - 20, y, r, b, x + 20, b})
	else if (shape == MM_SHAPE_TRAP_BOTTOM): mm_shape_polygon(s, list[int]{x + 20, y, r - 20, y, r, b, x, b})
	else if (shape == MM_SHAPE_TRAP_TOP): mm_shape_polygon(s, list[int]{x, y, r, y, r - 20, b, x + 20, b})
	else if (shape == 19): mm_shape_catalogue_draw(s, MM_SHAPE_LINED_DOCUMENT, x, y, w, h)
	else if (shape == MM_SHAPE_FOLDER): mm_shape_polygon(s, list[int]{x, y, x + w / 3, y, x + w / 3 + 8, y + 8, r, y + 8, r, b, x, b})
	else if (shape == MM_SHAPE_BUCKET): mm_shape_polygon(s, list[int]{x, y, r, y, r - 10, b, x + 10, b})
	else if (shape == MM_SHAPE_CONSOLE || shape == MM_SHAPE_BROWSER):
		mm_draw(s, MM_BOX, x, y, r, b, 1, c"")
		mm_line(s, x, y + 14, r, y + 14, 0)
		if (shape == MM_SHAPE_BROWSER):
			for i in range(3): mm_draw(s, MM_CIRCLE, x + 6 + i * 8, y + 4, x + 12 + i * 8, y + 10, 0, c"")
		else: mm_text(s, x + 6, y + 18, c">_")
	else if (shape == MM_SHAPE_PERSON):
		mm_draw(s, MM_CIRCLE, cx - 10, y, cx + 10, y + 20, 0, c"")
		mm_shape_polygon(s, list[int]{x, b, x + 10, y + 24, r - 10, y + 24, r, b})
	else if (shape == MM_SHAPE_BANG):
		list[int] points = new list[int]
		for i in range(16):
			int radius = w / 2
			int vertical = h / 2
			if (i % 2):
				radius = w / 3
				vertical = h / 3
			float angle = cast(float, i) * 6.2831853 / 16.0
			points.push(cx + cast(int, fcos(angle) * cast(float, radius)))
			points.push(cy + cast(int, fsin(angle) * cast(float, vertical)))
		mm_shape_polygon(s, points)
	else if (shape == MM_SHAPE_CLOUD):
		list[int] points = new list[int]
		mm_shape_arc(points, x + w / 4, cy, w / 4, h / 3, 90, 270, 8)
		mm_shape_arc(points, cx, y + h / 3, w / 4, h / 3, 180, 360, 8)
		mm_shape_arc(points, r - w / 4, cy, w / 4, h / 3, 270, 450, 8)
		mm_shape_arc(points, cx, b - h / 3, w / 4, h / 3, 0, 180, 8)
		mm_shape_polygon(s, points)
	else if (shape == MM_SHAPE_COLLAPSED):
		mm_draw(s, MM_BOX, x, y, r, b, 1, c"")
		mm_line(s, x + 8, y + h - 28, r - 8, y + h - 28, 1)
		mm_text(s, cx - 16, y + h - 24, c"• • •")
	else: mm_draw(s, MM_BOX, x, y, r, b, 0, c"")

# Sizes of the named flowchart shapes; b holds the label box, `text_w` /
# `text_h` measure the wrapped label, and direction orients forks.
void mm_shape_measure(int shape, mm_bounds* b, char* direction, int text_w, int text_h):
	int extra = text_h - MM_TEXT_LINE
	if (shape == MM_SHAPE_CYLINDER): b.h = 84 + extra
	else if (shape == MM_SHAPE_LINED_CYLINDER): b.h = 100 + extra
	else if (shape == MM_SHAPE_DOUBLE_CIRCLE): b.h = b.w
	else if (shape == MM_SHAPE_SMALL_CIRCLE || shape == MM_SHAPE_FRAMED_CIRCLE):
		b.w = 28
		b.h = 28
	else if (shape == MM_SHAPE_FILLED_CIRCLE):
		b.w = 20
		b.h = 20
	else if (shape == MM_SHAPE_CROSSED_CIRCLE):
		b.w = 40
		b.h = 40
	else if (shape == MM_SHAPE_BOLT):
		b.w = 40
		b.h = 64
	else if (shape == MM_SHAPE_FORK):
		b.w = 100
		b.h = 14
		if (strcmp(direction, c"LR") == 0 || strcmp(direction, c"RL") == 0):
			b.w = 14
			b.h = 100
	else if (shape == MM_SHAPE_DOCUMENT || shape == MM_SHAPE_LINED_DOCUMENT || shape == MM_SHAPE_TAGGED_DOCUMENT || shape == MM_SHAPE_FLAG): b.h = 76 + extra
	else if (shape == MM_SHAPE_DOCUMENTS || shape == MM_SHAPE_PROCESSES):
		b.w = b.w + 12
		b.h = b.h + 24
	else if (shape == MM_SHAPE_DIVIDED_RECT || shape == MM_SHAPE_WINDOW_PANE): b.h = b.h + 12
	else if (shape == MM_SHAPE_TRIANGLE || shape == MM_SHAPE_FLIPPED_TRIANGLE):
		b.w = b.w + b.w / 2
		b.h = 100 + extra
	else if (shape == MM_SHAPE_HOURGLASS):
		b.w = 80
		if (text_w + 20 > b.w): b.w = text_w + 20
		b.h = 80 + text_h + 8

# Box sizes for a one-line label box (w, h), updated in place: the named
# flowchart shapes take their flowchart sizes, the other shapes the
# proportions their outlines need.
void mm_shape_size(int shape, int* w, int* h):
	if (mm_shape_flowchart(shape)):
		mm_bounds box
		box.x = 0
		box.y = 0
		box.w = *w
		box.h = *h
		mm_shape_measure(shape, &box, c"TB", *w - 40, MM_TEXT_LINE)
		*w = box.w
		*h = box.h
	else if (shape == MM_SHAPE_CIRCLE): *h = *w
	else if (shape == MM_SHAPE_DIAMOND):
		*w = *w * 2
		*h = 100
	else if (shape == MM_SHAPE_PERSON || shape == MM_SHAPE_COLLAPSED): *h = *h + 20
	else if (shape == MM_SHAPE_CLOUD || shape == MM_SHAPE_BANG):
		*w = *w + 40
		*h = *h + 30

# Shapes drawn without an inner label (markers and pictograms); a label goes
# below them.
int mm_shape_unlabeled(int shape):
	return shape == MM_SHAPE_SMALL_CIRCLE || shape == MM_SHAPE_FRAMED_CIRCLE || shape == MM_SHAPE_FILLED_CIRCLE || shape == MM_SHAPE_CROSSED_CIRCLE || shape == MM_SHAPE_FORK || shape == MM_SHAPE_BOLT

# Shapes whose label sits off-center (in the cylinder body, the front sheet,
# the triangle's wide end, below the hourglass glyph).
int mm_shape_label_placed(int shape):
	return shape == MM_SHAPE_CYLINDER || shape == MM_SHAPE_LINED_CYLINDER || shape == MM_SHAPE_DOCUMENTS || shape == MM_SHAPE_PROCESSES || shape == MM_SHAPE_TRIANGLE || shape == MM_SHAPE_FLIPPED_TRIANGLE || shape == MM_SHAPE_HOURGLASS

# Where the label sits inside a shape box: the y offset of the label's top.
int mm_shape_label_y(int shape, int h, int text_height):
	if (shape == MM_SHAPE_COLLAPSED): return 10
	if (shape == MM_SHAPE_CYLINDER): return 20 + (h - 30 - text_height) / 2
	if (shape == MM_SHAPE_LINED_CYLINDER): return 40 + (h - 50 - text_height) / 2
	if (shape == MM_SHAPE_DOCUMENTS): return 24 + (h - 32 - text_height) / 2
	if (shape == MM_SHAPE_PROCESSES): return 24 + (h - 24 - text_height) / 2
	if (shape == MM_SHAPE_TRIANGLE): return h - 12 - text_height
	if (shape == MM_SHAPE_FLIPPED_TRIANGLE): return 12
	if (shape == MM_SHAPE_HOURGLASS): return 88
	if (shape == MM_SHAPE_PERSON): return (h - text_height) / 2 + 10
	if (mm_shape_unlabeled(shape)): return h + 4
	return (h - text_height) / 2
