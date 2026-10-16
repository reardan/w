# Native adapter for the same display list exported as SVG.
import libs.extras.mermaid.render
import graphics.ui.text

# Clipped short quads approximate diagonal strokes; horizontal/vertical strokes
# use one quad. Segment count depends on visible length, not source coordinates.
void mm_ui_line(ui_renderer* r, float32 x, float32 y, float32 x2, float32 y2, int dashed, ui_color ink):
	float32 dx = x2 - x
	float32 dy = y2 - y
	int steps = cast(int, fabs(dx) + fabs(dy)) + 1
	if (steps > 16384): steps = 16384
	if (dashed == 0 && (dx == 0.0 || dy == 0.0)):
		if (dx < 0.0): x = x2
		if (dy < 0.0): y = y2
		ui_render_rect(r, ui_rect_new(x - 0.75, y - 0.75, fabs(dx) + 1.5, fabs(dy) + 1.5), ink)
		return
	for i in range(steps + 1):
		if (dashed && i % 10 >= 6): continue
		float32 t = cast(float32, i) / cast(float32, steps)
		ui_render_rect(r, ui_rect_new(x + dx * t - 0.75, y + dy * t - 0.75, 1.5, 1.5), ink)

# Scan-convert small convex UML endpoint polygons. Clip before iterating so
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
	if (p.dashed): fill = ink
	int rows = cast(int, bottom - top) + 1
	if (rows > 16384): rows = 16384
	for row in range(rows):
		float32 y = top + cast(float32, row) + 0.5
		float32 left = clip.x + clip.w
		float32 right = clip.x
		int hits = 0
		for i in range(count):
			int j = (i + 1) % count
			float32 ax = ox + cast(float32, p.points[i * 2]) * zoom
			float32 ay = oy + cast(float32, p.points[i * 2 + 1]) * zoom
			float32 bx = ox + cast(float32, p.points[j * 2]) * zoom
			float32 by = oy + cast(float32, p.points[j * 2 + 1]) * zoom
			if ((ay <= y && by > y) || (by <= y && ay > y)):
				float32 x = ax + (bx - ax) * (y - ay) / (by - ay)
				if (x < left): left = x
				if (x > right): right = x
				hits = hits + 1
		if (hits >= 2): ui_render_rect(r, ui_rect_new(left, y - 0.5, right - left, 1.0), fill)
	for i in range(count):
		int j = (i + 1) % count
		mm_ui_line(r, ox + cast(float32, p.points[i * 2]) * zoom, oy + cast(float32, p.points[i * 2 + 1]) * zoom, ox + cast(float32, p.points[j * 2]) * zoom, oy + cast(float32, p.points[j * 2 + 1]) * zoom, 0, ink)

void mm_ui_render(ui_renderer* r, mm_scene* scene, ui_rect viewport, float32 zoom, float32 pan_x, float32 pan_y):
	if (scene == 0 || zoom <= 0.0): return
	if (r.clip_depth[r.layer] >= ui_render_clip_depth): return
	ui_clip_push(r, viewport)
	ui_rect visible = ui_clip_current(r)
	ui_color ink = ui_color_new(0.20, 0.25, 0.33, 1.0)
	ui_color paper = ui_color_new(0.97, 0.98, 0.99, 1.0)
	for mm_primitive* p in scene.items:
		float32 x = viewport.x + pan_x + cast(float32, p.x) * zoom
		float32 y = viewport.y + pan_y + cast(float32, p.y) * zoom
		float32 x2 = viewport.x + pan_x + cast(float32, p.x2) * zoom
		float32 y2 = viewport.y + pan_y + cast(float32, p.y2) * zoom
		if (p.kind == MM_LINE): mm_ui_line(r, x, y, x2, y2, p.dashed, ink)
		else if (p.kind == MM_BOX):
			ui_rect box = ui_rect_new(x, y, x2 - x, y2 - y)
			float32 radius = 0.0
			if (p.dashed == 1): radius = 12.0 * zoom
			ui_draw_rrect(r, box, radius, ink)
			if (p.dashed != 2): ui_draw_rrect(r, ui_rect_inset(box, 1.5), radius, paper)
		else if (p.kind == MM_CIRCLE):
			ui_rect box = ui_rect_new(x, y, x2 - x, y2 - y)
			ui_draw_rrect(r, box, box.w * 0.5, ink)
			if (p.dashed == 0): ui_draw_rrect(r, ui_rect_inset(box, 1.5), box.w * 0.5, paper)
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
			ui_draw_text(r, 0.0, 0.0, p.text, 2, ink)
			r.clip_stack[clip_slot] = visible
			for i in range(start, r.layer_vert_count[layer]):
				float32* v = &r.layer_verts[layer][i * 8]
				v[0] = x + v[0] * zoom
				v[1] = y + v[1] * zoom
	ui_clip_pop(r)
