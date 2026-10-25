# Native adapter for the same display list exported as SVG.
import libs.extras.mermaid.render
import graphics.ui.text

# Clipped short quads approximate diagonal strokes; horizontal/vertical strokes
# use one quad. Segment count depends on visible length, not source coordinates.
# dash/gap are the on/off run lengths in steps; dash 0 draws a solid stroke.
void mm_ui_line_dash(ui_renderer* r, float32 x, float32 y, float32 x2, float32 y2, int dash, int gap, ui_color ink, float32 width):
	if (ink.a == 0.0): return
	float32 half = width / 2.0
	float32 dx = x2 - x
	float32 dy = y2 - y
	int steps = cast(int, fabs(dx) + fabs(dy)) + 1
	if (steps > 16384): steps = 16384
	if (dash == 0 && (dx == 0.0 || dy == 0.0)):
		if (dx < 0.0): x = x2
		if (dy < 0.0): y = y2
		ui_render_rect(r, ui_rect_new(x - half, y - half, fabs(dx) + width, fabs(dy) + width), ink)
		return
	for i in range(steps + 1):
		if (dash > 0 && i % (dash + gap) >= dash): continue
		float32 t = cast(float32, i) / cast(float32, steps)
		ui_render_rect(r, ui_rect_new(x + dx * t - half, y + dy * t - half, width, width), ink)

void mm_ui_line(ui_renderer* r, float32 x, float32 y, float32 x2, float32 y2, int dashed, ui_color ink, float32 width):
	if (dashed): mm_ui_line_dash(r, x, y, x2, y2, 6, 4, ink, width)
	else: mm_ui_line_dash(r, x, y, x2, y2, 0, 0, ink, width)

# The primitive's stroke-dasharray style, else its own dashed flag (6 on, 4 off).
void mm_ui_dash(mm_primitive* p, int* dash, int* gap):
	*dash = 0
	*gap = 0
	if (p.style.mask & 16):
		*dash = p.style.dash
		*gap = p.style.gap
	else if (p.kind == MM_LINE && p.dashed):
		*dash = 6
		*gap = 4

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
void mm_ui_outline_dash(ui_renderer* r, ui_rect box, float32 radius, ui_color ink, float32 stroke, int dash, int gap):
	if (ink.a == 0.0): return
	if (radius > box.w / 2.0): radius = box.w / 2.0
	if (radius > box.h / 2.0): radius = box.h / 2.0
	mm_ui_line_dash(r, box.x + radius, box.y, box.x + box.w - radius, box.y, dash, gap, ink, stroke)
	mm_ui_line_dash(r, box.x + box.w, box.y + radius, box.x + box.w, box.y + box.h - radius, dash, gap, ink, stroke)
	mm_ui_line_dash(r, box.x + radius, box.y + box.h, box.x + box.w - radius, box.y + box.h, dash, gap, ink, stroke)
	mm_ui_line_dash(r, box.x, box.y + radius, box.x, box.y + box.h - radius, dash, gap, ink, stroke)
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

void mm_ui_outline(ui_renderer* r, ui_rect box, float32 radius, ui_color ink, float32 stroke):
	mm_ui_outline_dash(r, box, radius, ink, stroke, 0, 0)

# opacity / fill-opacity styles become the native color's alpha.
ui_color mm_ui_alpha(ui_color color, int hundredths):
	color.a = color.a * cast(float32, hundredths) / 100.0
	return color

# `look: handDrawn` natively: the same seeded double strokes as the SVG
# (rough.w). The shape is filled solid underneath: upstream's 1.5px hachure
# gap at 1.5px weight covers it, so the native preview skips the hatch lines.
void mm_ui_rough(ui_renderer* r, mm_scene* scene, mm_primitive* p, int index, float32 ox, float32 oy, float32 zoom, ui_color ink, ui_color paper, float32 stroke, int dash, int gap):
	int solid = 0
	mm_rough* rough = mm_rough_primitive(scene, p, index, &solid)
	if (p.kind != MM_LINE && paper.a != 0.0):
		if (p.kind == MM_POLYGON): mm_ui_polygon(r, p, ox, oy, zoom, mm_ui_color(-1), paper)
		else:
			ui_rect box = ui_rect_new(ox + cast(float32, p.x) * zoom, oy + cast(float32, p.y) * zoom, cast(float32, p.x2 - p.x) * zoom, cast(float32, p.y2 - p.y) * zoom)
			float32 radius = cast(float32, mm_paint_radius(p)) * zoom
			if (p.kind == MM_CIRCLE): radius = box.w * 0.5
			ui_draw_rrect(r, box, radius, paper)
	float32 scale = zoom / 10.0
	list[int] runs = rough.strokes
	int at = 0
	while (at < runs.length):
		int count = runs[at]
		for i in range(1, count):
			float32 ax = ox + cast(float32, runs[at + 1 + (i - 1) * 2]) * scale
			float32 ay = oy + cast(float32, runs[at + 2 + (i - 1) * 2]) * scale
			float32 bx = ox + cast(float32, runs[at + 1 + i * 2]) * scale
			float32 by = oy + cast(float32, runs[at + 2 + i * 2]) * scale
			mm_ui_line_dash(r, ax, ay, bx, by, dash, gap, ink, stroke)
		at = at + 1 + count * 2
	mm_rough_free(rough)

void mm_ui_render(ui_renderer* r, mm_scene* scene, ui_rect viewport, float32 zoom, float32 pan_x, float32 pan_y):
	if (scene == 0 || zoom <= 0.0): return
	if (r.clip_depth[r.layer] >= ui_render_clip_depth): return
	ui_clip_push(r, viewport)
	ui_rect visible = ui_clip_current(r)
	if (scene.has_background): ui_render_rect(r, viewport, mm_ui_color(scene.background))
	for index in range(scene.items.length):
		mm_primitive* p = scene.items[index]
		int stroke_rgb = mm_paint_stroke(p)
		# Native strokes approximate a gradient stroke with its first stop.
		if ((p.effects & 2) && stroke_rgb >= 0): stroke_rgb = scene.gradient_start
		ui_color ink = mm_ui_color(stroke_rgb)
		ui_color paper = mm_ui_color(mm_paint_fill(p))
		if (p.style.mask & 2048): paper = mm_ui_alpha(paper, p.style.fill_opacity)
		if (p.style.mask & 32):
			ink = mm_ui_alpha(ink, p.style.opacity)
			paper = mm_ui_alpha(paper, p.style.opacity)
		float32 stroke = cast(float32, mm_paint_width(p)) * zoom
		float32 x = viewport.x + pan_x + cast(float32, p.x) * zoom
		float32 y = viewport.y + pan_y + cast(float32, p.y) * zoom
		float32 x2 = viewport.x + pan_x + cast(float32, p.x2) * zoom
		float32 y2 = viewport.y + pan_y + cast(float32, p.y2) * zoom
		int dash = 0
		int gap = 0
		mm_ui_dash(p, &dash, &gap)
		if (mm_rough_drawn(scene, p)): mm_ui_rough(r, scene, p, index, viewport.x + pan_x, viewport.y + pan_y, zoom, ink, paper, stroke, dash, gap)
		else if (p.kind == MM_LINE): mm_ui_line_dash(r, x, y, x2, y2, dash, gap, ink, stroke)
		else if (p.kind == MM_BOX || p.kind == MM_CIRCLE):
			ui_rect box = ui_rect_new(x, y, x2 - x, y2 - y)
			float32 radius = cast(float32, mm_paint_radius(p)) * zoom
			if (p.kind == MM_BOX && p.dashed == 3 && (p.style.mask & 1024) == 0): radius = box.h * 0.5
			if (p.kind == MM_CIRCLE): radius = box.w * 0.5
			# The neo look's drop shadow: an offset, translucent copy behind the shape.
			if (p.effects & 1):
				ui_color shadow = mm_ui_alpha(mm_ui_color(scene.shadow_color), scene.shadow_alpha)
				ui_rect offset = ui_rect_new(x + cast(float32, scene.shadow_dx) * zoom, y + cast(float32, scene.shadow_dy) * zoom, x2 - x, y2 - y)
				ui_draw_rrect(r, offset, radius, shadow)
			if (paper.a != 0.0): ui_draw_rrect(r, box, radius, paper)
			mm_ui_outline_dash(r, box, radius, ink, stroke, dash, gap)

		else if (p.kind == MM_POLYGON): mm_ui_polygon(r, p, viewport.x + pan_x, viewport.y + pan_y, zoom, ink, paper)
		else:
			# Text and glyph positions scale together, using a temporary batch
			# transform so the UI's font API need not quantize preview zoom.
			int layer = r.layer
			int start = r.layer_vert_count[layer]
			int clip_slot = layer * 8 + r.clip_depth[layer] - 1
			# Transform the effective clip with the text, then restore it. A
			# nested push would intersect world and local coordinate systems.
			# Body strike (Regular 16) or the bold face at the same size, so
			# runs keep the advances libs/extras/mermaid/text_metrics.w laid out.
			# Other font sizes scale the 16px strike with the glyph positions.
			int flags = mm_text_flags(p)
			float32 scale = zoom * cast(float32, mm_paint_font_size(p)) / cast(float32, MM_TEXT_SIZE)
			r.clip_stack[clip_slot] = ui_rect_new((visible.x - x) / scale, (visible.y - y) / scale, visible.w / scale, visible.h / scale)
			int strike = ui_font_strike_from_scale(2)
			if (flags & MM_TEXT_BOLD): strike = ui_font_strike(UI_FACE_BOLD, MM_TEXT_SIZE)
			int style = UI_TEXT_PLAIN
			if (flags & MM_TEXT_ITALIC): style = UI_TEXT_ITALIC
			ui_draw_text_strike(r, 0.0, 0.0, p.text, strike, style, paper)
			r.clip_stack[clip_slot] = visible
			for i in range(start, r.layer_vert_count[layer]):
				float32* v = &r.layer_verts[layer][i * 8]
				v[0] = x + v[0] * scale
				v[1] = y + v[1] * scale
	ui_clip_pop(r)
