/*
graphics.ui.render_soft: a CPU rasterizer for a headless ui_renderer's
batch, so tests can check rendered pixels (golden images) with no GL
context (issue #827).

ui_render_software(r, width, height, background) paints every layer's
triangles in order, as ui_render_end would draw them: atlas commands
sample the R8 coverage atlas and tint it with the vertex color, image
commands (the color-glyph atlas, ui_image) multiply straight RGBA by
it, and each fragment blends source-alpha over an opaque background
(alpha composites source-over too, so the result stays opaque).
Sampling is nearest-texel, which matches GL's LINEAR filter exactly
where glyphs draw 1:1 at integer pens; a pixel belongs to a triangle
when its center is inside it (ties broken consistently, so the two
triangles of a quad never both paint a shared edge).
*/
import lib.lib
import lib.mem
import graphics.ui.font
import graphics.ui.render


struct ui_soft_source:
	char* pixels
	int w
	int h
	int rows            # the height v coordinates are normalized by
	int rgba


void ui_soft_sample(ui_soft_source* src, float32 u, float32 v, float32* out):
	int x = cast(int, u * cast(float32, src.w))
	int y = cast(int, v * cast(float32, src.rows))
	if (u < 0.0): x = 0
	if (v < 0.0): y = 0
	if (x >= src.w): x = src.w - 1
	if (y >= src.h): y = src.h - 1
	if ((src.pixels == 0) || (x < 0) || (y < 0)):
		for k in range(4): out[k] = 0.0
		return
	if (src.rgba):
		char* p = &src.pixels[(y * src.w + x) * 4]
		for k in range(4): out[k] = cast(float32, p[k] & 255) / 255.0
		return
	float32 c = cast(float32, src.pixels[y * src.w + x] & 255) / 255.0
	out[0] = c
	out[1] = c
	out[2] = c
	out[3] = c


float32 ui_soft_edge(float32 ax, float32 ay, float32 bx, float32 by, float32 px, float32 py):
	return (bx - ax) * (py - ay) - (by - ay) * (px - ax)


# Blend one triangle (vertices v at 8 floats each) into canvas
# (straight RGBA float, w x h).
void ui_soft_triangle(float32* canvas, int w, int h, float32* v0, float32* v1, float32* v2, ui_soft_source* src):
	float32 area = ui_soft_edge(v0[0], v0[1], v1[0], v1[1], v2[0], v2[1])
	if (area == 0.0): return
	if (area < 0.0):
		float32* t = v1
		v1 = v2
		v2 = t
		area = 0.0 - area
	float32 min_x = v0[0]
	float32 max_x = v0[0]
	float32 min_y = v0[1]
	float32 max_y = v0[1]
	if (v1[0] < min_x): min_x = v1[0]
	if (v2[0] < min_x): min_x = v2[0]
	if (v1[0] > max_x): max_x = v1[0]
	if (v2[0] > max_x): max_x = v2[0]
	if (v1[1] < min_y): min_y = v1[1]
	if (v2[1] < min_y): min_y = v2[1]
	if (v1[1] > max_y): max_y = v1[1]
	if (v2[1] > max_y): max_y = v2[1]
	int x0 = cast(int, min_x) - 1
	int y0 = cast(int, min_y) - 1
	int x1 = cast(int, max_x) + 1
	int y1 = cast(int, max_y) + 1
	if (x0 < 0): x0 = 0
	if (y0 < 0): y0 = 0
	if (x1 > w - 1): x1 = w - 1
	if (y1 > h - 1): y1 = h - 1
	float32[4] texel
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			# The center, nudged off any edge through exact pixel
			# coordinates so shared edges belong to one triangle.
			float32 px = cast(float32, x) + 0.5001
			float32 py = cast(float32, y) + 0.5002
			float32 w0 = ui_soft_edge(v1[0], v1[1], v2[0], v2[1], px, py)
			float32 w1 = ui_soft_edge(v2[0], v2[1], v0[0], v0[1], px, py)
			float32 w2 = ui_soft_edge(v0[0], v0[1], v1[0], v1[1], px, py)
			if ((w0 < 0.0) || (w1 < 0.0) || (w2 < 0.0)): continue
			w0 = w0 / area
			w1 = w1 / area
			w2 = w2 / area
			float32 u = v0[2] * w0 + v1[2] * w1 + v2[2] * w2
			float32 tv = v0[3] * w0 + v1[3] * w1 + v2[3] * w2
			float32[4] color
			for k in range(4): color[k] = v0[4 + k] * w0 + v1[4 + k] * w1 + v2[4 + k] * w2
			ui_soft_sample(src, u, tv, &texel[0])
			float32 a = color[3] * texel[3]
			float32 r = color[0]
			float32 g = color[1]
			float32 b = color[2]
			if (src.rgba):
				r = r * texel[0]
				g = g * texel[1]
				b = b * texel[2]
			float32* d = &canvas[(y * w + x) * 4]
			d[0] = r * a + d[0] * (1.0 - a)
			d[1] = g * a + d[1] * (1.0 - a)
			d[2] = b * a + d[2] * (1.0 - a)
			d[3] = a + d[3] * (1.0 - a)


# Rasterize r's batch (layers base, popup, top) into a new width x
# height straight-RGBA byte buffer over an opaque background. Call it
# after the frame's drawing (ui_render_end syncs the atlases first).
# Caller frees.
char* ui_render_software(ui_renderer* r, int width, int height, ui_color background):
	ui_render_sync_atlas(r)
	float32* canvas = cast(float32*, malloc(width * height * 16 + 16))
	for i in range(width * height):
		canvas[i * 4] = background.r
		canvas[i * 4 + 1] = background.g
		canvas[i * 4 + 2] = background.b
		canvas[i * 4 + 3] = 1.0
	ui_soft_source atlas
	atlas.pixels = ui_font_build_atlas()
	atlas.w = ui_font_atlas_w()
	atlas.h = ui_font_atlas_rows()
	atlas.rows = ui_font_uv_rows()
	atlas.rgba = 0
	ui_soft_source colors
	colors.pixels = ui_font_color_atlas_pixels()
	colors.w = ui_font_color_atlas_w()
	colors.h = ui_font_color_atlas_rows()
	colors.rows = ui_font_color_uv_rows()
	colors.rgba = 1
	for layer in range(ui_render_layer_count):
		float32* batch = r.layer_verts[layer]
		for c in range(r.commands.length):
			ui_image_command* command = r.commands[c]
			if (command.layer != layer): continue
			ui_soft_source* src = &atlas
			ui_soft_source image
			if (command.image == r.color_image): src = &colors
			else if (command.image != 0):
				image.pixels = command.image.pixels
				image.w = command.image.width
				image.h = command.image.height
				image.rows = command.image.height
				image.rgba = 1
				src = &image
			int t = command.first
			while (t + 2 < command.first + command.count):
				ui_soft_triangle(canvas, width, height, &batch[t * 8], &batch[(t + 1) * 8], &batch[(t + 2) * 8], src)
				t = t + 3
	free(atlas.pixels)
	char* out = cast(char*, malloc(width * height * 4 + 4))
	for i in range(width * height * 4):
		float32 v = canvas[i]
		if (v < 0.0): v = 0.0
		if (v > 1.0): v = 1.0
		out[i] = cast(int, v * 255.0 + 0.5)
	free(cast(char*, canvas))
	return out
