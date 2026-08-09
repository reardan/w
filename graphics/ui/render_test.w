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
	assert_equal(6, r.vert_count)

	# First vertex: position 10,20, the white mask's center UV, color
	# 0.5 — computed through the same float32 helpers the renderer
	# uses, so equality is exact.
	asserts(c"x", r.verts[0] == 10.0)
	asserts(c"y", r.verts[1] == 20.0)
	ui_glyph white = ui_font_mask(ui_mask_white())
	float32 want_u = ui_render_u(white.x * 2 + white.w) * 0.5
	float32 want_v = ui_render_v(white.y * 2 + white.h) * 0.5
	asserts(c"u", r.verts[2] == want_u)
	asserts(c"v", r.verts[3] == want_v)
	asserts(c"r", r.verts[4] == 0.5)
	asserts(c"a", r.verts[7] == 1.0)

	# Third vertex: the opposite corner 110,70.
	asserts(c"x2", r.verts[16] == 110.0)
	asserts(c"y2", r.verts[17] == 70.0)
	ui_render_destroy(&r)


void test_glyph_quad_matches_record():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	int advance = ui_render_glyph(&r, 50.0, 60.0, 'A', 2, ui_gray(0.0))
	assert_equal(6, r.vert_count)

	ui_glyph g = ui_font_glyph(0, 'A')
	assert_equal(g.advance, advance)
	# Quad position: pen + bearing_x, line top + ascent - bearing_top.
	float32 want_x = 50.0 + cast(float32, g.bearing_x)
	float32 want_y = 60.0 + cast(float32, ui_font_ascent(0) - g.bearing_top)
	asserts(c"gx", r.verts[0] == want_x)
	asserts(c"gy", r.verts[1] == want_y)
	asserts(c"u0", r.verts[2] == ui_render_u(g.x))
	asserts(c"v0", r.verts[3] == ui_render_v(g.y))
	# Vertex 2 carries the opposite corner and u1,v1.
	asserts(c"x1", r.verts[16] == want_x + cast(float32, g.w))
	asserts(c"y1", r.verts[17] == want_y + cast(float32, g.h))
	asserts(c"u1", r.verts[18] == ui_render_u(g.x + g.w))
	asserts(c"v1", r.verts[19] == ui_render_v(g.y + g.h))
	ui_render_destroy(&r)


void test_space_advances_without_quads():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	int advance = ui_render_glyph(&r, 50.0, 60.0, ' ', 2, ui_gray(0.0))
	assert_equal(0, r.vert_count)
	asserts(c"space advance", advance > 0)
	ui_render_destroy(&r)


void test_rrect_quad_counts():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	# Four corner masks + three fills = 7 quads = 42 vertices.
	ui_draw_rrect(&r, ui_rect_new(10.0, 10.0, 100.0, 32.0), 8.0, ui_gray(0.5))
	assert_equal(42, r.vert_count)
	# Radius below 1 falls back to a plain 6-vertex rect.
	ui_render_begin(&r, 320, 240)
	ui_draw_rrect(&r, ui_rect_new(10.0, 10.0, 100.0, 32.0), 0.0, ui_gray(0.5))
	assert_equal(6, r.vert_count)
	ui_render_destroy(&r)


void test_corner_mask_mirrors():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_draw_rrect(&r, ui_rect_new(0.0, 0.0, 64.0, 64.0), 8.0, ui_gray(0.5))
	# Quad 0 is the top-left corner (u ascending), quad 1 the top-right
	# (u mirrored: descending).
	asserts(c"top-left ascending u", r.verts[2] < r.verts[18])
	asserts(c"top-right mirrored u", r.verts[48 + 2] > r.verts[48 + 18])
	ui_render_destroy(&r)


void test_disc_and_shadow_counts():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_draw_disc(&r, ui_rect_new(0.0, 0.0, 20.0, 20.0), ui_gray(0.5))
	assert_equal(6, r.vert_count)
	ui_render_begin(&r, 320, 240)
	# 9-patch: 4 corners + 4 edges + 1 center = 54 vertices.
	ui_draw_shadow(&r, ui_rect_new(50.0, 50.0, 160.0, 96.0), ui_gray(0.0))
	assert_equal(54, r.vert_count)
	ui_render_destroy(&r)


void test_begin_resets_and_batch_grows():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	int i = 0
	while (i < 1600):
		ui_render_rect(&r, ui_rect_new(0.0, 0.0, 1.0, 1.0), ui_gray(1.0))
		i = i + 1
	# 1600 rects want 9600 vertices, past the 8192 the batch starts
	# with: it doubles instead of dropping the tail, so every vertex
	# pushed is a vertex kept.
	assert_equal(9600, r.vert_count)
	asserts(c"grew", r.vert_cap > ui_render_max_verts())
	# Growth preserves what was already written: the last rect's first
	# vertex is intact past the old cap.
	asserts(c"last vertex kept", r.verts[9594 * 8 + 7] == 1.0)
	ui_render_begin(&r, 320, 240)
	assert_equal(0, r.vert_count)
	# The grown capacity survives the frame reset — it is the batch,
	# not the frame, that grew.
	asserts(c"cap kept", r.vert_cap > ui_render_max_verts())
	ui_render_destroy(&r)
