/*
graphics.ui.widgets.context: frame lifecycle and shared interaction —
context init, event folding, ui_begin/ui_end, the disabled scope, and
the press/release logic plus token pickers every widget calls
(docs/projects/ui_widgets.md §3).
*/
import lib.lib
import graphics.gl
import graphics.window
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets.state


void ui_context_init(ui_context* ctx, ui_renderer* rndr, ui_theme* theme):
	ctx.rndr = rndr
	ctx.theme = theme
	ctx.input.mouse_x = 0
	ctx.input.mouse_y = 0
	ctx.input.mouse_down = 0
	ctx.input.mouse_pressed = 0
	ctx.input.mouse_released = 0
	ctx.input.press_x = 0
	ctx.input.press_y = 0
	ctx.hot = 0
	ctx.active = 0
	ctx.focus = 0
	ctx.modal = 0
	ctx.disabled = 0
	ctx.next_id = 1
	ctx.char_count = 0
	ctx.nav_count = 0
	ctx.cursor_x = 0.0
	ctx.cursor_y = 0.0
	ctx.origin_x = 0.0
	ctx.last_right = 0.0
	ctx.last_top = 0.0
	ctx.pending_same_line = 0


# Fold one queued event into the per-frame input edges. Only button 1
# drives pointer interaction; CHAR/NAV queue up for the focused widget.
void ui_feed_event(ui_context* ctx, gfx_event* e):
	if ((e.kind == GFX_EVENT_MOUSE_DOWN) && (e.code == 1)):
		ctx.input.mouse_down = 1
		ctx.input.mouse_pressed = 1
		ctx.input.press_x = e.x
		ctx.input.press_y = e.y
		ctx.input.mouse_x = e.x
		ctx.input.mouse_y = e.y
	else if ((e.kind == GFX_EVENT_MOUSE_UP) && (e.code == 1)):
		ctx.input.mouse_down = 0
		ctx.input.mouse_released = 1
		ctx.input.mouse_x = e.x
		ctx.input.mouse_y = e.y
	else if (e.kind == GFX_EVENT_CHAR):
		if (ctx.char_count < 32):
			ctx.chars[ctx.char_count] = e.code
			ctx.char_count = ctx.char_count + 1
	else if (e.kind == GFX_EVENT_NAV):
		if (ctx.nav_count < 8):
			ctx.navs[ctx.nav_count] = e.code
			ctx.nav_count = ctx.nav_count + 1


# Start a frame: reset ids/hot/layout, start the render batch, clear
# to the theme background (skipped headless).
void ui_begin(ui_context* ctx, int width, int height):
	ctx.hot = 0
	ctx.next_id = 1
	ctx.cursor_x = cast(float32, ctx.theme.pad)
	ctx.cursor_y = cast(float32, ctx.theme.pad)
	ctx.origin_x = ctx.cursor_x
	ctx.last_right = ctx.cursor_x
	ctx.last_top = ctx.cursor_y
	ctx.pending_same_line = 0
	ui_render_begin(ctx.rndr, width, height)
	if (ctx.rndr.gl_ready):
		glClearColor(ctx.theme.background.r, ctx.theme.background.g, ctx.theme.background.b, 1.0)
		glClear(GL_COLOR_BUFFER_BIT)


# Drain the window's event queue and refresh the pointer snapshot,
# then start the frame at the window's current size. The one function
# in this module that touches gfx_window.
void ui_begin_window(ui_context* ctx, gfx_window* win):
	gfx_event e
	while (gfx_window_next_event(win, &e)):
		ui_feed_event(ctx, &e)
	ctx.input.mouse_x = win.mouse_x
	ctx.input.mouse_y = win.mouse_y
	ui_begin(ctx, win.width, win.height)


# Finish a frame: draw the batch, clear the per-frame edges, release
# the press owner once the release has been seen by every widget.
void ui_end(ui_context* ctx):
	ui_render_end(ctx.rndr)
	if (ctx.input.mouse_released):
		ctx.active = 0
	ctx.input.mouse_pressed = 0
	ctx.input.mouse_released = 0
	ctx.char_count = 0
	ctx.nav_count = 0


# Open/close a disabled scope: widgets inside render with the
# disabled tokens and ignore all input.
void ui_disable(ui_context* ctx, int on):
	ctx.disabled = on


# Shared press/release logic: claims hot when the pointer is over the
# rect, active when this frame's press landed inside it; returns 1 on
# the frame the release lands while still over it. While a popup is
# open (ctx.modal) every other widget is inert — the popup handles all
# input itself — and so is everything inside a ui_disable scope.
int ui_click_behavior(ui_context* ctx, int id, ui_rect r):
	if (ctx.disabled):
		return 0
	if ((ctx.modal != 0) && (ctx.modal != id)):
		return 0
	int over = ui_rect_contains(r, cast(float32, ctx.input.mouse_x), cast(float32, ctx.input.mouse_y))
	if (over):
		ctx.hot = id
	if (ctx.input.mouse_pressed):
		if (ui_rect_contains(r, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
			ctx.active = id
	if (ctx.input.mouse_released && (ctx.active == id) && over):
		return 1
	return 0


ui_color ui_widget_fill(ui_context* ctx, int id):
	if (ctx.disabled):
		return ctx.theme.disabled_widget
	if (ctx.active == id):
		return ctx.theme.widget_active
	if (ctx.hot == id):
		return ctx.theme.widget_hot
	return ctx.theme.widget


ui_color ui_text_color(ui_context* ctx):
	if (ctx.disabled):
		return ctx.theme.disabled_text
	return ctx.theme.text
