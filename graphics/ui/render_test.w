# Headless unit tests for the batching renderer: vertex layout, quad
# expansion, solid-fill and glyph UVs against the baked records, the
# mask primitives' quad counts, and the batch cap — all through
# ui_render_init_headless, no GL context or display.
# x64-only: the renderer imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_render_test arch_only=x64
import lib.testing
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render


void test_rect_pushes_two_triangles():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_render_rect(&r, ui_rect_new(10.0, 20.0, 100.0, 50.0), ui_gray(0.5))
	assert_equal(6, r.layer_vert_count[UI_LAYER_BASE])

	# First vertex: position 10,20, the white mask's center UV, color
	# 0.5 — computed through the same float32 helpers the renderer
	# uses, so equality is exact.
	asserts(c"x", r.layer_verts[UI_LAYER_BASE][0] == 10.0)
	asserts(c"y", r.layer_verts[UI_LAYER_BASE][1] == 20.0)
	ui_glyph white = ui_font_mask(ui_mask_white)
	float32 want_u = ui_render_u(white.x * 2 + white.w) * 0.5
	float32 want_v = ui_render_v(white.y * 2 + white.h) * 0.5
	asserts(c"u", r.layer_verts[UI_LAYER_BASE][2] == want_u)
	asserts(c"v", r.layer_verts[UI_LAYER_BASE][3] == want_v)
	asserts(c"r", r.layer_verts[UI_LAYER_BASE][4] == 0.5)
	asserts(c"a", r.layer_verts[UI_LAYER_BASE][7] == 1.0)

	# Third vertex: the opposite corner 110,70.
	asserts(c"x2", r.layer_verts[UI_LAYER_BASE][16] == 110.0)
	asserts(c"y2", r.layer_verts[UI_LAYER_BASE][17] == 70.0)
	ui_render_destroy(&r)


void test_glyph_quad_matches_record():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	int advance = ui_render_glyph(&r, 50.0, 60.0, 'A', 2, ui_gray(0.0))
	assert_equal(6, r.layer_vert_count[UI_LAYER_BASE])

	ui_glyph g = ui_font_glyph(0, 'A')
	assert_equal(g.advance, advance)
	# Quad position: pen + bearing_x, line top + ascent - bearing_top.
	float32 want_x = 50.0 + cast(float32, g.bearing_x)
	float32 want_y = 60.0 + cast(float32, ui_font_ascent(0) - g.bearing_top)
	asserts(c"gx", r.layer_verts[UI_LAYER_BASE][0] == want_x)
	asserts(c"gy", r.layer_verts[UI_LAYER_BASE][1] == want_y)
	asserts(c"u0", r.layer_verts[UI_LAYER_BASE][2] == ui_render_u(g.x))
	asserts(c"v0", r.layer_verts[UI_LAYER_BASE][3] == ui_render_v(g.y))
	# Vertex 2 carries the opposite corner and u1,v1.
	asserts(c"x1", r.layer_verts[UI_LAYER_BASE][16] == want_x + cast(float32, g.w))
	asserts(c"y1", r.layer_verts[UI_LAYER_BASE][17] == want_y + cast(float32, g.h))
	asserts(c"u1", r.layer_verts[UI_LAYER_BASE][18] == ui_render_u(g.x + g.w))
	asserts(c"v1", r.layer_verts[UI_LAYER_BASE][19] == ui_render_v(g.y + g.h))
	ui_render_destroy(&r)


void test_space_advances_without_quads():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	int advance = ui_render_glyph(&r, 50.0, 60.0, ' ', 2, ui_gray(0.0))
	assert_equal(0, r.layer_vert_count[UI_LAYER_BASE])
	asserts(c"space advance", advance > 0)
	ui_render_destroy(&r)


void test_rrect_quad_counts():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	# Four corner masks + three fills = 7 quads = 42 vertices.
	ui_draw_rrect(&r, ui_rect_new(10.0, 10.0, 100.0, 32.0), 8.0, ui_gray(0.5))
	assert_equal(42, r.layer_vert_count[UI_LAYER_BASE])
	# Radius below 1 falls back to a plain 6-vertex rect.
	ui_render_begin(&r, 320, 240)
	ui_draw_rrect(&r, ui_rect_new(10.0, 10.0, 100.0, 32.0), 0.0, ui_gray(0.5))
	assert_equal(6, r.layer_vert_count[UI_LAYER_BASE])
	ui_render_destroy(&r)


# A stretched mask samples only its own texels: the quad's edges map to
# the edge texels' centers, so LINEAR filtering never blends in the
# atlas gap (the seam a 24px pill showed on a 1.75x phone).
void test_mask_uvs_stay_inside_their_texels():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_draw_rrect(&r, ui_rect_new(0.0, 0.0, 84.0, 84.0), 42.0, ui_gray(0.5))
	ui_glyph m = ui_font_mask(ui_mask_corner)
	float32 half_u = ui_render_u(1) * 0.5
	float32 half_v = ui_render_v(1) * 0.5
	float32* v = r.layer_verts[UI_LAYER_BASE]
	asserts(c"u0 is the first texel center", v[2] == ui_render_u(m.x) + half_u)
	asserts(c"v0 is the first texel center", v[3] == ui_render_v(m.y) + half_v)
	asserts(c"u1 is the last texel center", v[18] == ui_render_u(m.x + m.w) - half_u)
	asserts(c"v1 is the last texel center", v[19] == ui_render_v(m.y + m.h) - half_v)
	ui_render_destroy(&r)


# On a 1.75x phone canvas the glyph comes from the device-size strike,
# sized back to logical units and placed on the device-pixel grid; the
# pen still advances by the logical strike's metrics.
void test_pixel_scale_draws_device_glyphs():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_set_pixel_scale(&r, 1.75)
	ui_render_begin(&r, 320, 240)
	int advance = ui_render_glyph(&r, 10.3, 20.0, 'A', 2, ui_gray(0.0))
	ui_glyph g = ui_font_glyph(0, 'A')
	assert_equal(g.advance, advance)
	int device = ui_font_strike(ui_font_strike_face(0), 28)
	ui_glyph d = ui_font_glyph_id(device, g.gid)
	asserts(c"device glyph is larger", d.w > g.w)
	float32* v = r.layer_verts[UI_LAYER_BASE]
	float32 x0 = v[0] * 1.75
	float32 y0 = v[1] * 1.75
	asserts(c"device-pixel width", (v[16] - v[0]) * 1.75 > cast(float32, d.w) - 0.01)
	asserts(c"device-pixel width", (v[16] - v[0]) * 1.75 < cast(float32, d.w) + 0.01)
	asserts(c"x on the device grid", x0 - gfx_floor(x0 + 0.5) < 0.01)
	asserts(c"x on the device grid", gfx_floor(x0 + 0.5) - x0 < 0.01)
	asserts(c"y on the device grid", y0 - gfx_floor(y0 + 0.5) < 0.01)
	asserts(c"y on the device grid", gfx_floor(y0 + 0.5) - y0 < 0.01)
	asserts(c"device UVs", v[2] == ui_render_u(d.x))
	# Scale 1 (and nonsense) keeps the logical strike.
	ui_render_set_pixel_scale(&r, 0.0)
	ui_render_begin(&r, 320, 240)
	ui_render_glyph(&r, 10.0, 20.0, 'A', 2, ui_gray(0.0))
	asserts(c"logical UVs", r.layer_verts[UI_LAYER_BASE][2] == ui_render_u(g.x))
	ui_render_destroy(&r)


void test_corner_mask_mirrors():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_draw_rrect(&r, ui_rect_new(0.0, 0.0, 64.0, 64.0), 8.0, ui_gray(0.5))
	# Quad 0 is the top-left corner (u ascending), quad 1 the top-right
	# (u mirrored: descending).
	asserts(c"top-left ascending u", r.layer_verts[UI_LAYER_BASE][2] < r.layer_verts[UI_LAYER_BASE][18])
	asserts(c"top-right mirrored u", r.layer_verts[UI_LAYER_BASE][48 + 2] > r.layer_verts[UI_LAYER_BASE][48 + 18])
	ui_render_destroy(&r)


void test_disc_and_shadow_counts():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_draw_disc(&r, ui_rect_new(0.0, 0.0, 20.0, 20.0), ui_gray(0.5))
	assert_equal(6, r.layer_vert_count[UI_LAYER_BASE])
	ui_render_begin(&r, 320, 240)
	# 9-patch: 4 corners + 4 edges + 1 center = 54 vertices.
	ui_draw_shadow(&r, ui_rect_new(50.0, 50.0, 160.0, 96.0), ui_gray(0.0))
	assert_equal(54, r.layer_vert_count[UI_LAYER_BASE])
	ui_render_destroy(&r)


void test_begin_resets_and_batch_grows():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	for i in range(1600): ui_render_rect(&r, ui_rect_new(0.0, 0.0, 1.0, 1.0), ui_gray(1.0))
	# 1600 rects want 9600 vertices, past the 8192 the batch starts
	# with: it doubles instead of dropping the tail, so every vertex
	# pushed is a vertex kept.
	assert_equal(9600, r.layer_vert_count[UI_LAYER_BASE])
	asserts(c"grew", r.layer_vert_cap[UI_LAYER_BASE] > ui_render_max_verts)
	# Growth preserves what was already written: the last rect's first
	# vertex is intact past the old cap.
	asserts(c"last vertex kept", r.layer_verts[UI_LAYER_BASE][9594 * 8 + 7] == 1.0)
	ui_render_begin(&r, 320, 240)
	assert_equal(0, r.layer_vert_count[UI_LAYER_BASE])
	# The grown capacity survives the frame reset — it is the batch,
	# not the frame, that grew.
	asserts(c"cap kept", r.layer_vert_cap[UI_LAYER_BASE] > ui_render_max_verts)
	ui_render_destroy(&r)
