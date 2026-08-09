# Headless unit tests for the layout region stack: where widgets land
# inside a nested region, how same_line composes with one, the measured
# content extent, and what a depth overflow does
# (docs/projects/ui_widgets.md §4). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_layout_test arch_only=x64
import lib.testing
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets


# A headless context on the light theme, one per test.
void setup(ui_renderer* r, ui_theme* theme, ui_context* ctx):
	ui_render_init_headless(r)
	ui_theme_light(theme)
	ui_context_init(ctx, r, theme)


void test_root_region_is_the_padded_window():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)

	ui_begin(&ctx, 320, 240)
	assert_equal(1, ctx.layout_depth)
	ui_layout* lo = ui_layout_top(&ctx)
	# The root region is the window inset by the theme pad, so the
	# plain vertical stack is just its depth-1 case.
	asserts(c"x", lo.bounds.x == cast(float32, theme.pad))
	asserts(c"y", lo.bounds.y == cast(float32, theme.pad))
	asserts(c"w", lo.bounds.w == 320.0 - cast(float32, theme.pad * 2))
	# The first widget lands at the region origin, exactly where it did
	# before regions existed.
	ui_rect first = ui_layout_next(&ctx, 100.0, 20.0)
	asserts(c"first x", first.x == cast(float32, theme.pad))
	asserts(c"first y", first.y == cast(float32, theme.pad))
	ui_end(&ctx)
	ui_render_destroy(&r)


void test_region_places_widgets_inside_it():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)

	ui_begin(&ctx, 320, 240)
	ui_rect outer = ui_layout_next(&ctx, 100.0, 20.0)
	ui_region_push(&ctx, ui_rect_new(100.0, 50.0, 120.0, 90.0))
	assert_equal(2, ctx.layout_depth)
	ui_rect a = ui_layout_next(&ctx, 40.0, 20.0)
	ui_rect b = ui_layout_next(&ctx, 40.0, 20.0)
	# Placement is in the region's space, not the window's.
	asserts(c"a x", a.x == 100.0)
	asserts(c"a y", a.y == 50.0)
	asserts(c"b x", b.x == 100.0)
	asserts(c"b stacked", b.y == a.y + a.h + cast(float32, theme.gap))
	ui_region_pop(&ctx)
	assert_equal(1, ctx.layout_depth)

	# The outer cursor is untouched by the region: the next widget
	# continues below the one issued before the push.
	ui_rect after = ui_layout_next(&ctx, 100.0, 20.0)
	asserts(c"outer resumed", after.y == outer.y + outer.h + cast(float32, theme.gap))
	asserts(c"outer x", after.x == outer.x)
	ui_end(&ctx)
	ui_render_destroy(&r)


void test_same_line_inside_a_region():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)

	ui_begin(&ctx, 320, 240)
	ui_region_push(&ctx, ui_rect_new(40.0, 40.0, 200.0, 100.0))
	ui_rect a = ui_layout_next(&ctx, 30.0, 20.0)
	ui_same_line(&ctx)
	ui_rect b = ui_layout_next(&ctx, 30.0, 20.0)
	asserts(c"same row", b.y == a.y)
	asserts(c"to the right", b.x == a.x + a.w + cast(float32, theme.gap))
	# The pending flag belongs to the region, so the next row is back at
	# the region's own origin.
	ui_rect c = ui_layout_next(&ctx, 30.0, 20.0)
	asserts(c"back to origin", c.x == 40.0)
	asserts(c"next row", c.y > b.y)
	ui_region_pop(&ctx)
	ui_end(&ctx)
	ui_render_destroy(&r)


void test_same_line_does_not_leak_across_regions():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)

	ui_begin(&ctx, 320, 240)
	# A same_line requested in the outer region must not place the
	# region's first widget to the right of an outer widget.
	ui_layout_next(&ctx, 30.0, 20.0)
	ui_same_line(&ctx)
	ui_region_push(&ctx, ui_rect_new(150.0, 60.0, 100.0, 60.0))
	ui_rect inner = ui_layout_next(&ctx, 30.0, 20.0)
	asserts(c"region origin", inner.x == 150.0)
	asserts(c"region origin y", inner.y == 60.0)
	ui_region_pop(&ctx)
	# ...and the outer region's pending same_line is still pending.
	ui_rect outer = ui_layout_next(&ctx, 30.0, 20.0)
	asserts(c"outer same_line honored", outer.y == cast(float32, theme.pad))
	ui_end(&ctx)
	ui_render_destroy(&r)


void test_region_content_measures_the_extent():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)

	ui_begin(&ctx, 320, 240)
	ui_region_push(&ctx, ui_rect_new(0.0, 0.0, 100.0, 100.0))
	ui_rect empty = ui_region_content(&ctx)
	asserts(c"empty w", empty.w == 0.0)
	asserts(c"empty h", empty.h == 0.0)

	ui_layout_next(&ctx, 60.0, 20.0)
	ui_layout_next(&ctx, 140.0, 20.0)
	ui_rect content = ui_region_content(&ctx)
	# Widest widget, and the bottom of the last row — measured from the
	# region origin, which is what a scroll viewport needs.
	asserts(c"content w", content.w == 140.0)
	asserts(c"content h", content.h == 20.0 + cast(float32, theme.gap) + 20.0)
	# Content can exceed the region: that is the overflow scroll exists
	# to handle, not something layout clamps.
	asserts(c"overflow allowed", content.w > 100.0)
	ui_region_pop(&ctx)
	ui_end(&ctx)
	ui_render_destroy(&r)


void test_nested_regions_compose():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)

	ui_begin(&ctx, 320, 240)
	ui_region_push(&ctx, ui_rect_new(20.0, 20.0, 200.0, 200.0))
	ui_layout_next(&ctx, 50.0, 20.0)
	ui_region_push(&ctx, ui_rect_new(60.0, 90.0, 80.0, 80.0))
	assert_equal(3, ctx.layout_depth)
	ui_rect inner = ui_layout_next(&ctx, 20.0, 10.0)
	asserts(c"inner x", inner.x == 60.0)
	asserts(c"inner y", inner.y == 90.0)
	ui_region_pop(&ctx)
	# The middle region's own extent is unaffected by the nested one.
	ui_rect content = ui_region_content(&ctx)
	asserts(c"middle content w", content.w == 50.0)
	ui_region_pop(&ctx)
	assert_equal(1, ctx.layout_depth)
	ui_end(&ctx)
	ui_render_destroy(&r)


void test_region_depth_overflow_is_dropped_cleanly():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)

	ui_begin(&ctx, 320, 240)
	int i = 0
	while (i < 20):
		ui_region_push(&ctx, ui_rect_new(cast(float32, i), 0.0, 50.0, 50.0))
		i = i + 1
	assert_equal(ui_layout_max_depth(), ctx.layout_depth)
	# Widgets still land somewhere sane — the innermost region that fit.
	# The root holds slot 0, so the last push to land is number
	# max_depth - 1, pushed with i == max_depth - 2.
	ui_rect r0 = ui_layout_next(&ctx, 10.0, 10.0)
	asserts(c"placed in deepest region", r0.x == cast(float32, ui_layout_max_depth() - 2))

	# Every push is matched by a pop, and the dropped pushes' pops are
	# dropped too, so the stack lands back on the root.
	i = 0
	while (i < 20):
		ui_region_pop(&ctx)
		i = i + 1
	assert_equal(1, ctx.layout_depth)
	# Over-popping never goes below the root.
	ui_region_pop(&ctx)
	assert_equal(1, ctx.layout_depth)
	ui_end(&ctx)
	ui_render_destroy(&r)


void test_begin_reseeds_the_root_each_frame():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)

	# A frame that pushed a region and never popped it must not leak
	# into the next frame's layout.
	ui_begin(&ctx, 320, 240)
	ui_region_push(&ctx, ui_rect_new(200.0, 200.0, 40.0, 40.0))
	ui_end(&ctx)

	ui_begin(&ctx, 320, 240)
	assert_equal(1, ctx.layout_depth)
	ui_rect first = ui_layout_next(&ctx, 10.0, 10.0)
	asserts(c"fresh root", first.x == cast(float32, theme.pad))
	asserts(c"fresh root y", first.y == cast(float32, theme.pad))
	ui_end(&ctx)
	ui_render_destroy(&r)
