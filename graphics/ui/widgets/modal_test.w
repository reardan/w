# Headless unit tests for the modal dialog: background widgets going
# inert, geometry landing in the popup layer, and the two ways it
# closes (docs/projects/ui_widgets.md §5). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_modal_test arch_only=x64
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


# One frame: a background button, then the modal with a body button.
# Returns the background button's click result through bg.
void modal_frame(ui_context* ctx, int32* open, int32* bg, int32* body):
	ui_begin(ctx, 320, 240)
	bg[0] = ui_button(ctx, c"behind")
	if (ui_modal_begin(ctx, c"Confirm", 200.0, 120.0, open)):
		body[0] = ui_button(ctx, c"ok")
		ui_modal_end(ctx)
	ui_end(ctx)


void test_closed_modal_draws_nothing_and_leaves_input_alone():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	int32 open = 0
	int32 bg = 0
	int32 body = 0

	feed_click(&ctx, 20, 20)
	modal_frame(&ctx, &open, &bg, &body)
	assert_equal(1, bg)
	assert_equal(0, r.layer_vert_count[UI_LAYER_POPUP])
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&r)


void test_open_modal_makes_the_page_inert():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	int32 open = 1
	int32 bg = 0
	int32 body = 0

	# One frame to register the popup. A widget issued BEFORE
	# ui_modal_begin only goes inert once the modal has been seen —
	# immediate mode's one-frame ordering, the same as the dropdown's,
	# and invisible in practice because the click that opens a modal is
	# consumed by whatever opened it.
	modal_frame(&ctx, &open, &bg, &body)
	assert_equal(1, ctx.popup_depth)

	# A click on the background button now: inert.
	feed_click(&ctx, 20, 20)
	modal_frame(&ctx, &open, &bg, &body)
	assert_equal(0, bg)
	# ...and the click that landed on the scrim closed the modal.
	assert_equal(0, open)
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&r)


void test_modal_geometry_lands_in_the_popup_layer():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	int32 open = 1
	int32 bg = 0
	int32 body = 0

	ui_begin(&ctx, 320, 240)
	ui_button(&ctx, c"behind")
	int base_before = r.layer_vert_count[UI_LAYER_BASE]
	assert_equal(1, ui_modal_begin(&ctx, c"Confirm", 200.0, 120.0, &open))
	ui_button(&ctx, c"ok")
	ui_modal_end(&ctx)
	# Scrim, shadow, surface, title and the body button all went to the
	# popup layer; the page behind did not grow.
	asserts(c"popup drew", r.layer_vert_count[UI_LAYER_POPUP] > 0)
	assert_equal(base_before, r.layer_vert_count[UI_LAYER_BASE])
	ui_end(&ctx)
	# And the bracket left nothing behind.
	assert_equal(0, ctx.scope)
	assert_equal(1, ctx.layout_depth)
	ui_render_destroy(&r)


void test_body_widgets_take_input():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	int32 open = 1
	int32 bg = 0
	int32 body = 0

	# One frame to register, then click the body button, which sits at
	# the dialog's top-left inside a 200x120 surface centered in a
	# 320x240 window.
	modal_frame(&ctx, &open, &bg, &body)
	feed_click(&ctx, 60 + 24, 60 + 44 + 8 + 16)
	modal_frame(&ctx, &open, &bg, &body)
	assert_equal(1, body)
	assert_equal(0, bg)
	# A click inside the surface does not close the dialog.
	assert_equal(1, open)
	ui_render_destroy(&r)


void test_escape_closes():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	int32 open = 1
	int32 bg = 0
	int32 body = 0

	modal_frame(&ctx, &open, &bg, &body)
	assert_equal(1, open)
	feed_char(&ctx, 27)
	modal_frame(&ctx, &open, &bg, &body)
	assert_equal(0, open)
	assert_equal(0, ctx.popup_depth)

	# Closed: the page takes input again.
	feed_click(&ctx, 20, 20)
	modal_frame(&ctx, &open, &bg, &body)
	assert_equal(1, bg)
	ui_render_destroy(&r)


void test_closing_from_inside_the_body_releases_the_page():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	int32 open = 1
	int32 bg = 0
	int32 body = 0

	# A body button that closes the dialog — the common case, and the
	# one that leaves the popup registered a frame longer than the
	# caller's `open` flag says.
	modal_frame(&ctx, &open, &bg, &body)
	assert_equal(1, ctx.popup_depth)
	open = 0
	modal_frame(&ctx, &open, &bg, &body)
	assert_equal(0, ctx.popup_depth)

	# The page takes input again; without the unregister it would stay
	# inert forever.
	feed_click(&ctx, 20, 20)
	modal_frame(&ctx, &open, &bg, &body)
	assert_equal(1, bg)
	ui_render_destroy(&r)


void test_scrim_click_is_consumed():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	int32 open = 1

	# The press that dismisses the modal must not also reach a widget
	# issued after it.
	feed_click(&ctx, 300, 230)
	ui_begin(&ctx, 320, 240)
	int shown = ui_modal_begin(&ctx, c"Confirm", 200.0, 120.0, &open)
	assert_equal(0, shown)
	assert_equal(0, open)
	assert_equal(0, ctx.input.mouse_pressed)
	ui_end(&ctx)
	ui_render_destroy(&r)
