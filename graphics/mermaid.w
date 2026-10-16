# Native adapter for the same display list exported as SVG.
import libs.extras.mermaid.render
import graphics.ui.text

# Clipped short quads approximate diagonal strokes; horizontal/vertical strokes
# use one quad. Segment count depends on visible length, not source coordinates.
void mm_ui_line(ui_renderer* r, float32 x, float32 y, float32 x2, float32 y2, int dashed, ui_color ink, float32 width):
	if (ink.a == 0.0): return
	float32 half = width / 2.0
	float32 dx = x2 - x
	float32 dy = y2 - y
	int steps = cast(int, fabs(dx) + fabs(dy)) + 1
	if (steps > 16384): steps = 16384
	if (dashed == 0 && (dx == 0.0 || dy == 0.0)):
		if (dx < 0.0): x = x2
		if (dy < 0.0): y = y2
		ui_render_rect(r, ui_rect_new(x - half, y - half, fabs(dx) + width, fabs(dy) + width), ink)
		return
	for i in range(steps + 1):
		if (dashed && i % 10 >= 6): continue
		float32 t = cast(float32, i) / cast(float32, steps)
		ui_render_rect(r, ui_rect_new(x + dx * t - half, y + dy * t - half, width, width), ink)

# Scan-convert polygons with even-odd spans, including concave chart sectors. Clip before iterating so
# zoomed or offscreen diagrams cannot turn coordinate size into unbounded work.
void mm_ui_polygon(ui_renderer* r, mm_primitive* p, float32 ox, float32 oy, float32 zoom, ui_color ink, ui_color paper):
	ui_rect clip = ui_clip_current(r)
	float32 top = clip.y + clip.h
	float32 bottom = clip.y
	int count = p.points.length / 2
	for i in range(count):
		float32 y = oy + cast(float32, p.points[i * 2 + 1]) * zoom
		if (y < top): top = y
		if (y > bottom): bottom = y
	if (top < clip.y): top = clip.y
	if (bottom > clip.y + clip.h): bottom = clip.y + clip.h
	ui_color fill = paper
	list[float32] crossings = new list[float32]
	for i in range(count): crossings.push(0.0)

	int rows = cast(int, bottom - top) + 1
	if (rows > 16384): rows = 16384
	for row in range(rows):
		float32 y = top + cast(float32, row) + 0.5
		int hits = 0
		for i in range(count):
			int j = (i + 1) % count
			float32 ax = ox + cast(float32, p.points[i * 2]) * zoom
			float32 ay = oy + cast(float32, p.points[i * 2 + 1]) * zoom
			float32 bx = ox + cast(float32, p.points[j * 2]) * zoom
			float32 by = oy + cast(float32, p.points[j * 2 + 1]) * zoom
			if ((ay <= y && by > y) || (by <= y && ay > y)):
				float32 x = ax + (bx - ax) * (y - ay) / (by - ay)
				crossings[hits] = x
				hits = hits + 1
		if (fill.a != 0.0):
			for i in range(1, hits):
				int j = i
				while (j > 0 && crossings[j] < crossings[j - 1]):
					float32 value = crossings[j]
					crossings[j] = crossings[j - 1]
					crossings[j - 1] = value
					j = j - 1
			for i in range(0, hits - 1, 2):
				float32 left = crossings[i]
				float32 right = crossings[i + 1]
				ui_render_rect(r, ui_rect_new(left, y - 0.5, right - left, 1.0), fill)
	__w_list_free(cast(__w_list*, crossings))
	for i in range(count):
		int j = (i + 1) % count
		mm_ui_line(r, ox + cast(float32, p.points[i * 2]) * zoom, oy + cast(float32, p.points[i * 2 + 1]) * zoom, ox + cast(float32, p.points[j * 2]) * zoom, oy + cast(float32, p.points[j * 2 + 1]) * zoom, 0, ink, cast(float32, mm_paint_width(p)) * zoom)

ui_color mm_ui_color(int rgb):
	if (rgb < 0): return ui_color_new(0.0, 0.0, 0.0, 0.0)
	return ui_color_new(cast(float32, (rgb >> 16) & 255) / 255.0, cast(float32, (rgb >> 8) & 255) / 255.0, cast(float32, rgb & 255) / 255.0, 1.0)

# Outline without painting the interior, preserving transparent node fills.
void mm_ui_outline(ui_renderer* r, ui_rect box, float32 radius, ui_color ink, float32 stroke):
	if (ink.a == 0.0): return
	if (radius > box.w / 2.0): radius = box.w / 2.0
	if (radius > box.h / 2.0): radius = box.h / 2.0
	mm_ui_line(r, box.x + radius, box.y, box.x + box.w - radius, box.y, 0, ink, stroke)
	mm_ui_line(r, box.x + box.w, box.y + radius, box.x + box.w, box.y + box.h - radius, 0, ink, stroke)
	mm_ui_line(r, box.x + radius, box.y + box.h, box.x + box.w - radius, box.y + box.h, 0, ink, stroke)
	mm_ui_line(r, box.x, box.y + radius, box.x, box.y + box.h - radius, 0, ink, stroke)
	if (radius <= 0.0): return
	for corner in range(4):
		float32 cx = box.x + radius
		float32 cy = box.y + radius
		if (corner == 0 || corner == 1): cx = box.x + box.w - radius
		if (corner == 1 || corner == 2): cy = box.y + box.h - radius
		float32 start = cast(float32, corner) * 1.5707963 - 1.5707963
		float32 px = cx + fcos(start) * radius
		float32 py = cy + fsin(start) * radius
		for i in range(1, 13):
			float32 angle = start + cast(float32, i) * 1.5707963 / 12.0
			float32 nx = cx + fcos(angle) * radius
			float32 ny = cy + fsin(angle) * radius
			mm_ui_line(r, px, py, nx, ny, 0, ink, stroke)
			px = nx
			py = ny

void mm_ui_render(ui_renderer* r, mm_scene* scene, ui_rect viewport, float32 zoom, float32 pan_x, float32 pan_y):
	if (scene == 0 || zoom <= 0.0): return
	if (r.clip_depth[r.layer] >= ui_render_clip_depth): return
	ui_clip_push(r, viewport)
	ui_rect visible = ui_clip_current(r)
	if (scene.has_background): ui_render_rect(r, viewport, mm_ui_color(scene.background))
	for mm_primitive* p in scene.items:
		ui_color ink = mm_ui_color(mm_paint_stroke(p))
		ui_color paper = mm_ui_color(mm_paint_fill(p))
		float32 stroke = cast(float32, mm_paint_width(p)) * zoom
		float32 x = viewport.x + pan_x + cast(float32, p.x) * zoom
		float32 y = viewport.y + pan_y + cast(float32, p.y) * zoom
		float32 x2 = viewport.x + pan_x + cast(float32, p.x2) * zoom
		float32 y2 = viewport.y + pan_y + cast(float32, p.y2) * zoom
		if (p.kind == MM_LINE): mm_ui_line(r, x, y, x2, y2, p.dashed, ink, stroke)
		else if (p.kind == MM_BOX || p.kind == MM_CIRCLE):
			ui_rect box = ui_rect_new(x, y, x2 - x, y2 - y)
			float32 radius = 0.0
			if (p.kind == MM_BOX && p.dashed == 1): radius = 12.0 * zoom
			if (p.kind == MM_BOX && p.dashed == 3): radius = box.h * 0.5
			if (p.kind == MM_CIRCLE): radius = box.w * 0.5
			if (paper.a != 0.0): ui_draw_rrect(r, box, radius, paper)
			mm_ui_outline(r, box, radius, ink, stroke)

		else if (p.kind == MM_POLYGON): mm_ui_polygon(r, p, viewport.x + pan_x, viewport.y + pan_y, zoom, ink, paper)
		else:
			# Text and glyph positions scale together, using a temporary batch
			# transform so the UI's font API need not quantize preview zoom.
			int layer = r.layer
			int start = r.layer_vert_count[layer]
			int clip_slot = layer * 8 + r.clip_depth[layer] - 1
			# Transform the effective clip with the text, then restore it. A
			# nested push would intersect world and local coordinate systems.
			r.clip_stack[clip_slot] = ui_rect_new((visible.x - x) / zoom, (visible.y - y) / zoom, visible.w / zoom, visible.h / zoom)
			ui_draw_text(r, 0.0, 0.0, p.text, 2, paper)
			r.clip_stack[clip_slot] = visible
			for i in range(start, r.layer_vert_count[layer]):
				float32* v = &r.layer_verts[layer][i * 8]
				v[0] = x + v[0] * zoom
				v[1] = y + v[1] * zoom
	ui_clip_pop(r)
