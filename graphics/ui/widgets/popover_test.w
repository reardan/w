# Headless unit tests for the popover: placement against the viewport
# edges, the popup scope it opens, and the ways it closes
# (docs/projects/ui_widgets.md §9). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_popover_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets


void setup(ui_renderer* r, ui_theme* theme, ui_context* ctx):
	ui_render_init_headless(r)
	ui_theme_light(theme)
	ui_context_init(ctx, r, theme)


void feed_click(ui_context* ctx, int x, int y):
	gfx_event press
	press.kind = GFX_EVENT_MOUSE_DOWN
	press.code = 1
	press.x = x
	press.y = y
	press.mods = 0
	ui_feed_event(ctx, &press)
	gfx_event release
	release.kind = GFX_EVENT_MOUSE_UP
	release.code = 1
	release.x = x
	release.y = y
	release.mods = 0
	ui_feed_event(ctx, &release)


void feed_char(ui_context* ctx, int code):
	gfx_event e
	e.kind = GFX_EVENT_CHAR
	e.code = code
	e.x = 0
	e.y = 0
	e.mods = 0
	ui_feed_event(ctx, &e)


# One frame: a background button, then a popover anchored under it.
# `bg` counts clicks that reached the background button.
void popover_frame(ui_context* ctx, int32* open, int32* bg, ui_rect anchor):
	ui_begin(ctx, 320, 240)
	if (ui_button(ctx, c"behind")):
		bg[0] = bg[0] + 1
	if (ui_popover_begin(ctx, 900, anchor, 160.0, 80.0, open)):
		ui_label(ctx, c"inside")
		ui_popover_end(ctx)
	ui_end(ctx)


# Placement is pure arithmetic, so it is tested directly rather than
# inferred from geometry — and it runs on any target.
void test_placement_prefers_below_and_flips_when_it_must():
	# Room below: straight under the anchor, left edges aligned.
	ui_rect below = ui_popover_place(ui_rect_new(20.0, 40.0, 60.0, 24.0), 100.0, 50.0, 320.0, 240.0)
	asserts(c"below the anchor", below.y == 40.0 + 24.0 + ui_popover_gap())
	asserts(c"left edges aligned", below.x == 20.0)

	# No room below, plenty above: flips.
	ui_rect above = ui_popover_place(ui_rect_new(20.0, 200.0, 60.0, 24.0), 100.0, 50.0, 320.0, 240.0)
	asserts(c"flipped above the anchor", above.y == 200.0 - ui_popover_gap() - 50.0)

	# Too tall for either side, anchor near the top: stays below, which
	# is the friendlier overflow.
	ui_rect neither = ui_popover_place(ui_rect_new(20.0, 10.0, 60.0, 24.0), 100.0, 400.0, 320.0, 240.0)
	asserts(c"stays below when above is no better", neither.y > 10.0)

	# Off the right edge: shifted back inside rather than drawn off.
	ui_rect shifted = ui_popover_place(ui_rect_new(300.0, 40.0, 60.0, 24.0), 100.0, 50.0, 320.0, 240.0)
	asserts(c"shifted inside the viewport", shifted.x + 100.0 <= 320.0)
	asserts(c"and not past the left edge", shifted.x >= 0.0)


# A closed popover costs nothing: no popup registered, no geometry, and
# the widgets around it stay live.
void test_a_closed_popover_is_inert_and_draws_nothing():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	int32 open = 0
	int32 bg = 0

	feed_click(&ctx, 20, 20)
	popover_frame(&ctx, &open, &bg, ui_rect_new(8.0, 8.0, 80.0, 32.0))
	assert_equal(1, bg)
	assert_equal(0, r.layer_vert_count[UI_LAYER_POPUP])
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&r)


# An open popover draws on the popup layer and makes the page inert.
# The widget issued before it needs one registration frame first — the
# same immediate-mode ordering the modal documents.
void test_an_open_popover_takes_the_popup_layer_and_the_input():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	int32 open = 1
	int32 bg = 0
	# Anchor low enough that the surface does not cover the background
	# button, so an inert background is the only reason a click on it
	# could fail to register.
	ui_rect anchor = ui_rect_new(8.0, 120.0, 80.0, 32.0)

	popover_frame(&ctx, &open, &bg, anchor)
	assert_equal(1, ctx.popup_depth)
	asserts(c"the surface drew on the popup layer", r.layer_vert_count[UI_LAYER_POPUP] > 0)

	feed_click(&ctx, 20, 20)
	popover_frame(&ctx, &open, &bg, anchor)
	assert_equal(0, bg)
	ui_render_destroy(&r)


# A press outside closes it, and is consumed so nothing behind also
# acts on it.
void test_a_press_outside_closes_and_is_consumed():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	int32 open = 1
	int32 bg = 0
	ui_rect anchor = ui_rect_new(8.0, 120.0, 80.0, 32.0)

	popover_frame(&ctx, &open, &bg, anchor)
	feed_click(&ctx, 20, 20)
	popover_frame(&ctx, &open, &bg, anchor)

	assert_equal(0, open)
	assert_equal(0, ctx.popup_depth)
	asserts(c"the closing press did not also click the button", bg == 0)
	ui_render_destroy(&r)


void test_escape_closes_it():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	int32 open = 1
	int32 bg = 0
	ui_rect anchor = ui_rect_new(8.0, 120.0, 80.0, 32.0)

	popover_frame(&ctx, &open, &bg, anchor)
	feed_char(&ctx, 27)
	popover_frame(&ctx, &open, &bg, anchor)
	assert_equal(0, open)
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&r)


# Opening and closing must leave scope, layer and region depth exactly
# where they were: an unbalanced bracket is the failure mode that would
# corrupt every later frame rather than just this one.
void test_the_bracket_balances():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	int32 open = 0
	int32 bg = 0
	ui_rect anchor = ui_rect_new(8.0, 120.0, 80.0, 32.0)

	popover_frame(&ctx, &open, &bg, anchor)
	int depth_closed = ctx.layout_depth
	int scope_closed = ctx.scope

	open = 1
	popover_frame(&ctx, &open, &bg, anchor)
	assert_equal(depth_closed, ctx.layout_depth)
	assert_equal(scope_closed, ctx.scope)
	assert_equal(0, ctx.bracket_depth)
	assert_equal(UI_LAYER_BASE, r.layer)
	ui_render_destroy(&r)


# A popover closed from inside its own body must not stay registered:
# that is the bug ui_modal_begin was fixed for in round 1, and the same
# unconditional dismiss is what prevents it here.
void test_closing_from_inside_the_body_unregisters_it():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	int32 open = 1
	int32 bg = 0
	ui_rect anchor = ui_rect_new(8.0, 120.0, 80.0, 32.0)

	popover_frame(&ctx, &open, &bg, anchor)
	assert_equal(1, ctx.popup_depth)

	# The caller's body closed it, the way a Close button would.
	open = 0
	popover_frame(&ctx, &open, &bg, anchor)
	assert_equal(0, ctx.popup_depth)

	# And the page is live again rather than inert forever.
	feed_click(&ctx, 20, 20)
	popover_frame(&ctx, &open, &bg, anchor)
	assert_equal(1, bg)
	ui_render_destroy(&r)
