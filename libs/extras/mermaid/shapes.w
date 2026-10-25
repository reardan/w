# Native outlines for the canonical node-shape catalogue (shape_catalog.w).
# Curves are sampled into polygons and segments, so every backend that draws
# scene primitives draws every shape.
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

# A sine-like lower edge from right to left, the document "wave".
void mm_shape_wave(list[int] points, int x, int y, int w, int amplitude):
	for i in range(17):
		int px = x + w - w * i / 16
		float angle = cast(float, i) * 6.2831853 / 16.0
		points.push(px)
		points.push(y + cast(int, fsin(angle) * cast(float, amplitude)))

void mm_shape_document(mm_scene* s, int x, int y, int w, int h):
	list[int] points = list[int]{x, y, x + w, y}
	mm_shape_wave(points, x, y + h - 8, w, 8)
	mm_shape_polygon(s, points)

void mm_shape_cylinder(mm_scene* s, int x, int y, int w, int h, int lined):
	int ry = h / 8
	if (ry < 6): ry = 6
	list[int] points = new list[int]
	mm_shape_arc(points, x + w / 2, y + ry, w / 2, ry, 180, 360, 12)
	mm_shape_arc(points, x + w / 2, y + h - ry, w / 2, ry, 0, 180, 12)
	mm_shape_polygon(s, points)
	list[int] rim = new list[int]
	mm_shape_arc(rim, x + w / 2, y + ry, w / 2, ry, 0, 180, 12)
	for i in range(rim.length / 2 - 1): mm_line(s, rim[i * 2], rim[i * 2 + 1], rim[i * 2 + 2], rim[i * 2 + 3], 0)
	if (lined):
		for i in range(rim.length / 2 - 1): mm_line(s, rim[i * 2], rim[i * 2 + 1] + ry, rim[i * 2 + 2], rim[i * 2 + 3] + ry, 0)
	__w_list_free(cast(__w_list*, rim))

void mm_shape_h_cylinder(mm_scene* s, int x, int y, int w, int h):
	int rx = w / 10
	if (rx < 6): rx = 6
	list[int] points = new list[int]
	mm_shape_arc(points, x + rx, y + h / 2, rx, h / 2, 90, 270, 12)
	mm_shape_arc(points, x + w - rx, y + h / 2, rx, h / 2, 270, 450, 12)
	mm_shape_polygon(s, points)
	list[int] rim = new list[int]
	mm_shape_arc(rim, x + w - rx, y + h / 2, rx, h / 2, 90, 270, 12)
	for i in range(rim.length / 2 - 1): mm_line(s, rim[i * 2], rim[i * 2 + 1], rim[i * 2 + 2], rim[i * 2 + 3], 0)
	__w_list_free(cast(__w_list*, rim))

void mm_shape_brace(mm_scene* s, int x, int y, int h, int side):
	int d = 8 * side
	mm_line(s, x + d, y, x, y + 6, 0)
	mm_line(s, x, y + 6, x, y + h / 2 - 6, 0)
	mm_line(s, x, y + h / 2 - 6, x - d, y + h / 2, 0)
	mm_line(s, x - d, y + h / 2, x, y + h / 2 + 6, 0)
	mm_line(s, x, y + h / 2 + 6, x, y + h - 6, 0)
	mm_line(s, x, y + h - 6, x + d, y + h, 0)

# Draws one node outline in the box (x, y, w, h). Unknown codes draw a rectangle.
void mm_shape_draw(mm_scene* s, int shape, int x, int y, int w, int h):
	int r = x + w
	int b = y + h
	int cx = x + w / 2
	int cy = y + h / 2
	if (shape == MM_SHAPE_ROUNDED): mm_draw(s, MM_BOX, x, y, r, b, 1, c"")
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
	else if (shape == MM_SHAPE_CYLINDER): mm_shape_cylinder(s, x, y, w, h, 0)
	else if (shape == MM_SHAPE_LINED_CYLINDER): mm_shape_cylinder(s, x, y, w, h, 1)
	else if (shape == MM_SHAPE_H_CYLINDER): mm_shape_h_cylinder(s, x, y, w, h)
	else if (shape == MM_SHAPE_DOUBLE_CIRCLE):
		mm_draw(s, MM_CIRCLE, x, y, r, b, 0, c"")
		mm_draw(s, MM_CIRCLE, x + 5, y + 5, r - 5, b - 5, 0, c"")
	else if (shape == MM_SHAPE_SMALL_CIRCLE || shape == MM_SHAPE_FILLED_CIRCLE): mm_draw(s, MM_CIRCLE, cx - 7, cy - 7, cx + 7, cy + 7, shape == MM_SHAPE_FILLED_CIRCLE, c"")
	else if (shape == MM_SHAPE_FRAMED_CIRCLE):
		mm_draw(s, MM_CIRCLE, cx - 10, cy - 10, cx + 10, cy + 10, 0, c"")
		mm_draw(s, MM_CIRCLE, cx - 6, cy - 6, cx + 6, cy + 6, 1, c"")
	else if (shape == MM_SHAPE_CROSSED_CIRCLE):
		mm_draw(s, MM_CIRCLE, cx - 15, cy - 15, cx + 15, cy + 15, 0, c"")
		mm_line(s, cx - 10, cy - 10, cx + 10, cy + 10, 0)
		mm_line(s, cx - 10, cy + 10, cx + 10, cy - 10, 0)
	else if (shape == MM_SHAPE_ODD): mm_shape_polygon(s, list[int]{x, y, r, y, r, b, x, b, x + 16, cy})
	else if (shape == MM_SHAPE_DOCUMENT || shape == MM_SHAPE_LINED_DOCUMENT || shape == 19):
		mm_shape_document(s, x, y, w, h)
		if (shape != MM_SHAPE_DOCUMENT): mm_line(s, x + 10, y, x + 10, b - 8, 0)
	else if (shape == MM_SHAPE_TAGGED_DOCUMENT):
		mm_shape_document(s, x, y, w, h)
		mm_shape_polygon(s, list[int]{r - 16, b - 12, r, b - 28, r, b - 12})
	else if (shape == MM_SHAPE_DOCUMENTS):
		mm_shape_polygon(s, list[int]{x + 10, y, r, y, r, b - 18, r - 4, b - 18, r - 4, y + 6, x + 10, y + 6})
		mm_line(s, x + 5, y + 5, r - 5, y + 5, 0)
		mm_shape_document(s, x, y + 10, w - 10, h - 10)
	else if (shape == MM_SHAPE_PROCESSES):
		mm_shape_polygon(s, list[int]{x + 8, y, r, y, r, b - 8, r - 8, b - 8, r - 8, y + 8, x + 8, y + 8})
		mm_draw(s, MM_BOX, x, y + 8, r - 8, b, 0, c"")
	else if (shape == MM_SHAPE_CARD): mm_shape_polygon(s, list[int]{x + 12, y, r, y, r, b, x, b, x, y + 12})
	else if (shape == MM_SHAPE_LINED_RECT):
		mm_draw(s, MM_BOX, x, y, r, b, 0, c"")
		mm_line(s, x + 8, y, x + 8, b, 0)
	else if (shape == MM_SHAPE_DIVIDED_RECT):
		mm_draw(s, MM_BOX, x, y, r, b, 0, c"")
		mm_line(s, x, y + 12, r, y + 12, 0)
	else if (shape == MM_SHAPE_WINDOW_PANE):
		mm_draw(s, MM_BOX, x, y, r, b, 0, c"")
		mm_line(s, x + 10, y, x + 10, b, 0)
		mm_line(s, x, y + 10, r, y + 10, 0)
	else if (shape == MM_SHAPE_TAGGED_RECT):
		mm_draw(s, MM_BOX, x, y, r, b, 0, c"")
		mm_shape_polygon(s, list[int]{r - 14, b, r, b - 14, r, b})
	else if (shape == MM_SHAPE_FORK): mm_draw(s, MM_BOX, x, cy - 5, r, cy + 5, 2, c"")
	else if (shape == MM_SHAPE_HOURGLASS): mm_shape_polygon(s, list[int]{x, y, r, y, x, b, r, b})
	else if (shape == MM_SHAPE_BRACE_LEFT): mm_shape_brace(s, x + 8, y, h, 1)
	else if (shape == MM_SHAPE_BRACE_RIGHT): mm_shape_brace(s, r - 8, y, h, -1)
	else if (shape == MM_SHAPE_BRACES):
		mm_shape_brace(s, x + 8, y, h, 1)
		mm_shape_brace(s, r - 8, y, h, -1)
	else if (shape == MM_SHAPE_BOLT): mm_shape_polygon(s, list[int]{r, y, x + w / 3, cy + 2, cx + 4, cy - 2, x, b, r - w / 3, cy - 2, cx - 4, cy + 2})
	else if (shape == MM_SHAPE_DELAY):
		list[int] points = list[int]{x, y, r - h / 2, y}
		mm_shape_arc(points, r - h / 2, cy, h / 2, h / 2, 270, 450, 12)
		points.push(x)
		points.push(b)
		mm_shape_polygon(s, points)
	else if (shape == MM_SHAPE_CURVED_TRAP):
		list[int] points = list[int]{x + w / 5, y, r - h / 2, y}
		mm_shape_arc(points, r - h / 2, cy, h / 2, h / 2, 270, 450, 12)
		points.push(x + w / 5)
		points.push(b)
		points.push(x)
		points.push(cy)
		mm_shape_polygon(s, points)
	else if (shape == MM_SHAPE_TRIANGLE): mm_shape_polygon(s, list[int]{cx, y, r, b, x, b})
	else if (shape == MM_SHAPE_FLIPPED_TRIANGLE): mm_shape_polygon(s, list[int]{x, y, r, y, cx, b})
	else if (shape == MM_SHAPE_NOTCH_PENTAGON): mm_shape_polygon(s, list[int]{x + 16, y, r - 16, y, r, y + 16, r, b, x, b, x, y + 16})
	else if (shape == MM_SHAPE_SLOPED_RECT): mm_shape_polygon(s, list[int]{x, y + 14, r, y, r, b, x, b})
	else if (shape == MM_SHAPE_BOW_RECT):
		list[int] points = list[int]{x + 8, y, r - 8, y}
		mm_shape_arc(points, r - 8, cy, 8, h / 2, 270, 90, 10)
		points.push(x + 8)
		points.push(b)
		mm_shape_arc(points, x + 8, cy, 8, h / 2, 90, 270, 10)
		mm_shape_polygon(s, points)
	else if (shape == MM_SHAPE_FLAG):
		list[int] points = new list[int]
		for i in range(17):
			points.push(x + w * i / 16)
			points.push(y + cast(int, fsin(cast(float, i) * 6.2831853 / 16.0) * 6.0))
		mm_shape_wave(points, x, b, w, 6)
		mm_shape_polygon(s, points)
	else if (shape == MM_SHAPE_TEXT): return
	else if (shape == MM_SHAPE_DATA_STORE):
		mm_line(s, x, y, r, y, 0)
		mm_line(s, x, b, r, b, 0)
		mm_line(s, x, y, x, b, 0)
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

# Box sizes for shapes whose drawing needs proportions other than the default
# label box; w and h are the label box, updated in place.
void mm_shape_size(int shape, int* w, int* h):
	if (shape == MM_SHAPE_SMALL_CIRCLE || shape == MM_SHAPE_FILLED_CIRCLE || shape == MM_SHAPE_FRAMED_CIRCLE || shape == MM_SHAPE_CROSSED_CIRCLE):
		*w = 40
		*h = 40
	else if (shape == MM_SHAPE_FORK):
		*w = 100
		*h = 20
	else if (shape == MM_SHAPE_CIRCLE || shape == MM_SHAPE_DOUBLE_CIRCLE): *h = *w
	else if (shape == MM_SHAPE_DIAMOND):
		*w = *w * 2
		*h = 100
	else if (shape == MM_SHAPE_CYLINDER || shape == MM_SHAPE_LINED_CYLINDER || shape == MM_SHAPE_DOCUMENTS || shape == MM_SHAPE_PROCESSES || shape == MM_SHAPE_PERSON || shape == MM_SHAPE_COLLAPSED || shape == MM_SHAPE_TRIANGLE || shape == MM_SHAPE_FLIPPED_TRIANGLE): *h = *h + 20
	else if (shape == MM_SHAPE_CLOUD || shape == MM_SHAPE_BANG):
		*w = *w + 40
		*h = *h + 30

# Where the label sits inside a shape box: the y offset of the label's top.
int mm_shape_label_y(int shape, int h, int text_height):
	if (shape == MM_SHAPE_COLLAPSED): return 10
	if (shape == MM_SHAPE_CYLINDER || shape == MM_SHAPE_LINED_CYLINDER || shape == MM_SHAPE_PERSON || shape == MM_SHAPE_TRIANGLE): return (h - text_height) / 2 + 10
	if (shape == MM_SHAPE_DOCUMENTS || shape == MM_SHAPE_PROCESSES || shape == MM_SHAPE_FLIPPED_TRIANGLE): return (h - text_height) / 2 - 4
	if (shape == MM_SHAPE_SMALL_CIRCLE || shape == MM_SHAPE_FILLED_CIRCLE || shape == MM_SHAPE_FRAMED_CIRCLE || shape == MM_SHAPE_CROSSED_CIRCLE || shape == MM_SHAPE_FORK || shape == MM_SHAPE_HOURGLASS || shape == MM_SHAPE_BOLT): return h + 4
	return (h - text_height) / 2
