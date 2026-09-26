# Headless unit tests for the popup scope: what an open popup does to
# widgets outside it, where its geometry lands, and that entering and
# leaving one restores scope, layer, clip and region together
# (docs/projects/ui_widgets.md §4). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_overlay_test arch_only=x64
import lib.testing
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets
import graphics.ui.testing


void test_open_popup_makes_outside_widgets_inert():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)

	# No popup: a clicked button clicks.
	ui_test_click(ctx, 20, 20)
	ui_begin(ctx, 320, 240)
	assert_equal(1, ui_button(ctx, c"go"))
	ui_end(ctx)

	# With a popup open, the same click is inert — including for a
	# widget issued BEFORE the popup is entered this frame, which is
	# why the open-popup stack outlives the frame.
	ui_popup_open(ctx, 4242)
	ui_test_click(ctx, 20, 20)
	ui_begin(ctx, 320, 240)
	assert_equal(0, ui_button(ctx, c"go"))
	ui_end(ctx)

	# Dismissed: live again.
	ui_popup_dismiss(ctx, 4242)
	assert_equal(0, ctx.popup_depth)
	ui_test_click(ctx, 20, 20)
	ui_begin(ctx, 320, 240)
	assert_equal(1, ui_button(ctx, c"go"))
	ui_end(ctx)
	ui_render_destroy(&fx.r)


void test_widgets_inside_the_popup_scope_take_input():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)

	ui_popup_open(ctx, 77)
	ui_test_click(ctx, 60, 60)
	ui_begin(ctx, 320, 240)
	# Outside the scope: inert.
	assert_equal(0, ui_button(ctx, c"outside"))
	ui_popup_begin(ctx, 77, ui_rect_new(50.0, 50.0, 200.0, 100.0), UI_LAYER_POPUP)
	# Inside it: live, and laid out in the popup's own area.
	assert_equal(1, ui_button(ctx, c"inside"))
	ui_popup_end(ctx)
	ui_end(ctx)
	ui_popup_dismiss(ctx, 77)
	ui_render_destroy(&fx.r)


void test_popup_geometry_lands_in_its_layer():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)

	ui_begin(ctx, 320, 240)
	ui_button(ctx, c"base")
	int base_only = fx.r.layer_vert_count[UI_LAYER_BASE]
	asserts(c"base drew", base_only > 0)
	assert_equal(0, fx.r.layer_vert_count[UI_LAYER_POPUP])

	ui_popup_begin(ctx, 9, ui_rect_new(40.0, 40.0, 200.0, 120.0), UI_LAYER_POPUP)
	ui_button(ctx, c"floating")
	# The popup's geometry went to its own batch, and the base batch
	# did not grow.
	asserts(c"popup drew", fx.r.layer_vert_count[UI_LAYER_POPUP] > 0)
	assert_equal(base_only, fx.r.layer_vert_count[UI_LAYER_BASE])
	ui_popup_end(ctx)

	# After the bracket, drawing goes back to the base layer.
	int popup_after = fx.r.layer_vert_count[UI_LAYER_POPUP]
	ui_button(ctx, c"base again")
	asserts(c"base resumed", fx.r.layer_vert_count[UI_LAYER_BASE] > base_only)
	assert_equal(popup_after, fx.r.layer_vert_count[UI_LAYER_POPUP])
	ui_end(ctx)
	ui_render_destroy(&fx.r)


void test_popup_end_restores_scope_layer_clip_and_region():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)

	ui_begin(ctx, 320, 240)
	ui_region_push(ctx, ui_rect_new(10.0, 10.0, 100.0, 100.0))
	ui_clip_push(&fx.r, ui_rect_new(10.0, 10.0, 100.0, 100.0))
	int depth_before = ctx.layout_depth
	int clip_before = fx.r.clip_depth[UI_LAYER_BASE]

	ui_popup_begin(ctx, 5, ui_rect_new(0.0, 0.0, 320.0, 240.0), UI_LAYER_POPUP)
	assert_equal(5, ctx.scope)
	assert_equal(UI_LAYER_POPUP, fx.r.layer)
	# The popup layer has its own clip stack: the base layer's clip is
	# not in force here, which is what keeps a dropdown opened inside a
	# scrolled region from being trimmed by it.
	assert_equal(1, fx.r.clip_depth[UI_LAYER_POPUP])
	assert_equal(clip_before, fx.r.clip_depth[UI_LAYER_BASE])
	assert_equal(depth_before + 1, ctx.layout_depth)

	ui_popup_end(ctx)
	assert_equal(0, ctx.scope)
	assert_equal(UI_LAYER_BASE, fx.r.layer)
	assert_equal(0, fx.r.clip_depth[UI_LAYER_POPUP])
	assert_equal(clip_before, fx.r.clip_depth[UI_LAYER_BASE])
	assert_equal(depth_before, ctx.layout_depth)
	ui_region_pop(ctx)
	ui_end(ctx)
	ui_render_destroy(&fx.r)


void test_nested_popups_only_the_innermost_takes_input():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)

	ui_popup_open(ctx, 1)
	ui_popup_open(ctx, 2)
	assert_equal(2, ctx.popup_depth)

	ui_test_click(ctx, 60, 60)
	ui_begin(ctx, 320, 240)
	ui_popup_begin(ctx, 1, ui_rect_new(50.0, 50.0, 200.0, 100.0), UI_LAYER_POPUP)
	# The outer popup is open but no longer innermost: inert.
	assert_equal(0, ui_button(ctx, c"outer"))
	ui_popup_begin(ctx, 2, ui_rect_new(50.0, 50.0, 200.0, 100.0), UI_LAYER_TOP)
	assert_equal(1, ui_button(ctx, c"inner"))
	assert_equal(UI_LAYER_TOP, fx.r.layer)
	ui_popup_end(ctx)
	# Leaving the inner one restores the outer's scope and layer, not
	# the base's.
	assert_equal(1, ctx.scope)
	assert_equal(UI_LAYER_POPUP, fx.r.layer)
	ui_popup_end(ctx)
	assert_equal(0, ctx.scope)
	ui_end(ctx)
	ui_render_destroy(&fx.r)


void test_dismiss_closes_popups_stacked_on_top():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)

	ui_popup_open(ctx, 1)
	ui_popup_open(ctx, 2)
	ui_popup_open(ctx, 3)
	assert_equal(3, ctx.popup_depth)
	# Dismissing the outermost takes the ones opened on top of it with
	# it — otherwise they would keep input that nothing can reach.
	ui_popup_dismiss(ctx, 1)
	assert_equal(0, ctx.popup_depth)

	# Dismissing an id that is not open is a no-op.
	ui_popup_open(ctx, 8)
	ui_popup_dismiss(ctx, 99)
	assert_equal(1, ctx.popup_depth)
	# Opening the same id twice does not stack it.
	ui_popup_open(ctx, 8)
	assert_equal(1, ctx.popup_depth)
	ui_render_destroy(&fx.r)


void test_popup_stack_overflow_does_not_corrupt():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)

	int i = 0
	while (i < 20):
		ui_popup_open(ctx, i + 1)
		i = i + 1
	assert_equal(ui_popup_max_depth, ctx.popup_depth)
	# The innermost that fit still owns input, and ids past the cap were
	# never registered.
	assert_equal(1, ui_popup_is_top(ctx, ui_popup_max_depth))
	assert_equal(0, ui_popup_is_top(ctx, 20))

	# Nested brackets past the save array still land back on the base
	# rather than leaving a stale scope or layer in force.
	ui_begin(ctx, 320, 240)
	i = 0
	while (i < 12):
		ui_popup_begin(ctx, i + 1, ui_rect_new(0.0, 0.0, 100.0, 100.0), UI_LAYER_POPUP)
		i = i + 1
	i = 0
	while (i < 12):
		ui_popup_end(ctx)
		i = i + 1
	assert_equal(0, ctx.bracket_depth)
	assert_equal(0, ctx.scope)
	assert_equal(UI_LAYER_BASE, fx.r.layer)
	assert_equal(1, ctx.layout_depth)
	ui_end(ctx)
	ui_render_destroy(&fx.r)
