# Headless unit tests for the batching renderer: vertex layout, quad
# expansion, the solid-fill white-cell UVs, glyph UVs and the batch
# cap — all through ui_render_init_headless, no GL context or display.
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

	# First vertex: position 10,20, white-cell center UV, color 0.5.
	asserts(c"x", r.verts[0] == 10.0)
	asserts(c"y", r.verts[1] == 20.0)
	# white cell 95 -> cell (15, 5): u = (120 + 4) / 128, v = (40 + 4) / 48.
	# Compare through float32 locals — the renderer computes UVs in
	# float32, and 44/48 is not exactly representable.
	float32 want_u = 124.0
	want_u = want_u / 128.0
	float32 want_v = 44.0
	want_v = want_v / 48.0
	asserts(c"u", r.verts[2] == want_u)
	asserts(c"v", r.verts[3] == want_v)
	asserts(c"r", r.verts[4] == 0.5)
	asserts(c"a", r.verts[7] == 1.0)

	# Third vertex: the opposite corner 110,70.
	asserts(c"x2", r.verts[16] == 110.0)
	asserts(c"y2", r.verts[17] == 70.0)
	ui_render_destroy(&r)


void test_glyph_quad_uvs():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	# 'A' = cell 33 -> atlas cell (1, 2): x 8..16, y 16..24. float32
	# locals for the non-power-of-two v0 (16/48).
	ui_render_glyph(&r, 50.0, 60.0, 65, 2, ui_gray(0.0))
	assert_equal(6, r.vert_count)
	float32 want_v0 = 16.0
	want_v0 = want_v0 / 48.0
	asserts(c"u0", r.verts[2] == 8.0 / 128.0)
	asserts(c"v0", r.verts[3] == want_v0)
	# vertex 2 carries u1,v1; scale 2 makes the quad 16x16
	asserts(c"u1", r.verts[18] == 16.0 / 128.0)
	asserts(c"v1", r.verts[19] == 24.0 / 48.0)
	asserts(c"x1", r.verts[16] == 66.0)
	asserts(c"y1", r.verts[17] == 76.0)
	ui_render_destroy(&r)


void test_begin_resets_and_cap_holds():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	int i = 0
	while (i < 800):
		ui_render_rect(&r, ui_rect_new(0.0, 0.0, 1.0, 1.0), ui_gray(1.0))
		i = i + 1
	# 800 rects want 4800 vertices; the cap drops whole pushes past
	# ui_render_max_verts.
	asserts(c"cap", r.vert_count <= ui_render_max_verts())
	ui_render_begin(&r, 320, 240)
	assert_equal(0, r.vert_count)
	ui_render_destroy(&r)
