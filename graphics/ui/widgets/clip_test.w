# Headless unit tests for the renderer's clip stack: what a clip does to
# a quad's geometry, to its UVs, and to the glyph runs a text line
# expands into (docs/projects/ui_widgets.md §4). All through
# ui_render_init_headless, no GL context or display.
# x64-only: the renderer imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_clip_test arch_only=x64
import lib.testing
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text


# A frame with one clip in force, ready for the caller's draw calls.
void begin_clipped(ui_renderer* r, ui_rect clip):
	ui_render_begin(r, 320, 240)
	ui_clip_push(r, clip)


void test_quad_inside_clip_is_untouched():
	ui_renderer r
	ui_render_init_headless(&r)
	begin_clipped(&r, ui_rect_new(0.0, 0.0, 200.0, 200.0))
	ui_render_rect(&r, ui_rect_new(10.0, 20.0, 100.0, 50.0), ui_gray(0.5))
	assert_equal(6, r.vert_count)
	# Same geometry an unclipped push would produce.
	asserts(c"x", r.verts[0] == 10.0)
	asserts(c"y", r.verts[1] == 20.0)
	asserts(c"x2", r.verts[16] == 110.0)
	asserts(c"y2", r.verts[17] == 70.0)
	ui_render_destroy(&r)


void test_quad_outside_clip_emits_nothing():
	ui_renderer r
	ui_render_init_headless(&r)
	begin_clipped(&r, ui_rect_new(0.0, 0.0, 50.0, 50.0))
	ui_render_rect(&r, ui_rect_new(100.0, 100.0, 20.0, 20.0), ui_gray(0.5))
	assert_equal(0, r.vert_count)
	# Edge-adjacent counts as outside: the clip's right edge is
	# exclusive, like ui_rect_contains.
	ui_render_rect(&r, ui_rect_new(50.0, 0.0, 20.0, 20.0), ui_gray(0.5))
	assert_equal(0, r.vert_count)
	ui_render_destroy(&r)


void test_half_clipped_quad_halves_its_uvs():
	ui_renderer r
	ui_render_init_headless(&r)
	# A glyph-style quad with a known UV range, clipped so exactly its
	# left half survives.
	ui_render_begin(&r, 320, 240)
	ui_clip_push(&r, ui_rect_new(0.0, 0.0, 50.0, 200.0))
	ui_render_quad(&r, ui_rect_new(0.0, 0.0, 100.0, 40.0), 0.0, 0.0, 1.0, 1.0, ui_gray(0.5))
	assert_equal(6, r.vert_count)
	# Geometry trimmed at the clip edge...
	asserts(c"x0", r.verts[0] == 0.0)
	asserts(c"x1", r.verts[16] == 50.0)
	# ...and the u range trimmed by the same fraction, so the visible
	# half samples the texels it would have. v is untouched: the clip
	# did not cross it.
	asserts(c"u0", r.verts[2] == 0.0)
	asserts(c"u1", r.verts[18] == 0.5)
	asserts(c"v0", r.verts[3] == 0.0)
	asserts(c"v1", r.verts[19] == 1.0)
	ui_render_destroy(&r)


void test_clip_trims_leading_edge_and_uv():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	# Clip away the left quarter: u0 moves in, u1 stays.
	ui_clip_push(&r, ui_rect_new(25.0, 0.0, 200.0, 200.0))
	ui_render_quad(&r, ui_rect_new(0.0, 0.0, 100.0, 40.0), 0.0, 0.0, 1.0, 1.0, ui_gray(0.5))
	asserts(c"x0", r.verts[0] == 25.0)
	asserts(c"u0", r.verts[2] == 0.25)
	asserts(c"u1", r.verts[18] == 1.0)
	ui_render_destroy(&r)


void test_mirrored_quad_clips_correctly():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_clip_push(&r, ui_rect_new(0.0, 0.0, 50.0, 200.0))
	# u0 > u1: the mirrored sample the corner masks rely on. Trimming
	# the right half of the geometry must trim the same fraction off the
	# range as given, which moves u1 UP toward u0.
	ui_render_quad(&r, ui_rect_new(0.0, 0.0, 100.0, 40.0), 1.0, 0.0, 0.0, 1.0, ui_gray(0.5))
	assert_equal(6, r.vert_count)
	asserts(c"u0 kept", r.verts[2] == 1.0)
	asserts(c"u1 lerped", r.verts[18] == 0.5)
	ui_render_destroy(&r)


void test_nested_pushes_intersect():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_clip_push(&r, ui_rect_new(0.0, 0.0, 100.0, 100.0))
	ui_clip_push(&r, ui_rect_new(50.0, 50.0, 100.0, 100.0))
	ui_rect inner = ui_clip_current(&r)
	# The inner push cannot widen the outer one.
	asserts(c"x", inner.x == 50.0)
	asserts(c"y", inner.y == 50.0)
	asserts(c"w", inner.w == 50.0)
	asserts(c"h", inner.h == 50.0)
	# A quad inside the outer clip but outside the inner one is gone.
	ui_render_rect(&r, ui_rect_new(10.0, 10.0, 20.0, 20.0), ui_gray(0.5))
	assert_equal(0, r.vert_count)
	ui_clip_pop(&r)
	# Popping restores the outer clip, and the same quad now draws.
	ui_render_rect(&r, ui_rect_new(10.0, 10.0, 20.0, 20.0), ui_gray(0.5))
	assert_equal(6, r.vert_count)
	ui_clip_pop(&r)
	assert_equal(0, r.clip_depth)
	ui_render_destroy(&r)


void test_clip_depth_overflow_is_dropped_cleanly():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_clip_push(&r, ui_rect_new(0.0, 0.0, 40.0, 40.0))
	int i = 0
	while (i < 20):
		ui_clip_push(&r, ui_rect_new(0.0, 0.0, 200.0, 200.0))
		i = i + 1
	assert_equal(ui_render_clip_depth(), r.clip_depth)
	# The dropped pushes did not widen the clip: the first one still
	# rules, so a quad outside it is still gone.
	ui_render_rect(&r, ui_rect_new(100.0, 100.0, 10.0, 10.0), ui_gray(0.5))
	assert_equal(0, r.vert_count)
	ui_render_destroy(&r)


void test_begin_resets_clip_depth():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_clip_push(&r, ui_rect_new(0.0, 0.0, 10.0, 10.0))
	assert_equal(1, r.clip_depth)
	# A frame that returned early must not leak its clip into the next.
	ui_render_begin(&r, 320, 240)
	assert_equal(0, r.clip_depth)
	ui_render_rect(&r, ui_rect_new(100.0, 100.0, 10.0, 10.0), ui_gray(0.5))
	assert_equal(6, r.vert_count)
	ui_render_destroy(&r)


void test_glyphs_clipped_mid_line_drop_only_the_outside_ones():
	ui_renderer r
	ui_render_init_headless(&r)
	# Unclipped reference: how many vertices the whole line costs.
	ui_render_begin(&r, 320, 240)
	ui_draw_text(&r, 0.0, 0.0, c"iiiiiiii", 2, ui_gray(0.0))
	int full = r.vert_count
	asserts(c"line drew", full > 0)

	# Clipped to the first few glyphs' worth of pen: fewer vertices,
	# but not none — the run is trimmed glyph by glyph, and the glyph
	# straddling the edge survives as a partial quad.
	int half_w = ui_text_width(c"iiii", 2)
	ui_render_begin(&r, 320, 240)
	ui_clip_push(&r, ui_rect_new(0.0, 0.0, cast(float32, half_w), 100.0))
	ui_draw_text(&r, 0.0, 0.0, c"iiiiiiii", 2, ui_gray(0.0))
	asserts(c"clipped fewer", r.vert_count < full)
	asserts(c"clipped some kept", r.vert_count > 0)

	# Every surviving vertex is inside the clip.
	int i = 0
	while (i < r.vert_count):
		asserts(c"vertex inside clip", r.verts[i * 8] <= cast(float32, half_w))
		i = i + 1
	ui_render_destroy(&r)
