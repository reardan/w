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
import graphics.__arch__.text_input
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import lib.utf8
import graphics.ui.text


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
	ctx.input.mouse_right_pressed = 0
	ctx.input.right_x = 0
	ctx.input.right_y = 0
	ctx.input.scroll_x = 0
	ctx.input.scroll_y = 0
	ctx.input.scroll_pixels_y = 0
	ctx.input.scroll_at_x = 0
	ctx.input.scroll_at_y = 0
	ctx.input.mods = 0
	ctx.hot = 0
	ctx.active = 0
	ctx.focus = 0
	ctx.disabled = 0
	ctx.next_id = 1
	ctx.char_count = 0
	ctx.nav_count = 0
	ctx.preedit[0] = 0
	ctx.preedit_length = 0
	ctx.preedit_focus = 0
	ctx.preedit_active = 0
	ctx.preedit_selection = 0
	ctx.popup_depth = 0
	ctx.scope = 0
	ctx.bracket_depth = 0
	ctx.text_input_id = 0
	ctx.text_input_scope = 0
	ctx.text_input_multiline = 0
	ctx.text_input_rect = ui_rect_new(0.0, 0.0, 0.0, 0.0)
	ctx.text_input_clip = ctx.text_input_rect
	ctx.pointer_mode = 0
	ui_layout_reset(&ctx.layout_stack[0], ui_rect_new(0.0, 0.0, 0.0, 0.0))
	ctx.layout_depth = 1


# Fold one queued event into the per-frame input edges. Only button 1
# drives pointer interaction — button 3 is a bare edge for context
# menus; CHAR/NAV queue up for the focused widget.
void ui_feed_event(ui_context* ctx, gfx_event* e):
	if ((e.kind == GFX_EVENT_MOUSE_DOWN) && (e.code == 1)):
		ctx.input.mouse_down = 1
		ctx.input.mouse_pressed = 1
		ctx.input.press_x = e.x
		ctx.input.press_y = e.y
		ctx.input.mouse_x = e.x
		ctx.input.mouse_y = e.y
	else if ((e.kind == GFX_EVENT_MOUSE_DOWN) && (e.code == 3)):
		ctx.input.mouse_right_pressed = 1
		ctx.input.right_x = e.x
		ctx.input.right_y = e.y
		ctx.input.mouse_x = e.x
		ctx.input.mouse_y = e.y
	else if ((e.kind == GFX_EVENT_MOUSE_UP) && (e.code == 1)):
		ctx.input.mouse_down = 0
		ctx.input.mouse_released = 1
		ctx.input.mouse_x = e.x
		ctx.input.mouse_y = e.y
	else if (e.kind == GFX_EVENT_SCROLL):
		# Wheel notches accumulate over the frame; the scroll region
		# under the pointer claims and zeroes them.
		ctx.input.scroll_y = ctx.input.scroll_y + e.code
		ctx.input.scroll_at_x = e.x
		ctx.input.scroll_at_y = e.y
	else if (e.kind == GFX_EVENT_SCROLL_PIXELS):
		ctx.input.scroll_pixels_y = ctx.input.scroll_pixels_y + e.code
		ctx.input.scroll_at_x = e.x
		ctx.input.scroll_at_y = e.y
	else if (e.kind == GFX_EVENT_POINTER_CANCEL):
		ctx.input.mouse_down = 0
		ctx.input.mouse_pressed = 0
		ctx.input.mouse_released = 0
		ctx.input.mouse_right_pressed = 0
		ctx.active = 0
	else if (e.kind == GFX_EVENT_PREEDIT_BEGIN):
		ctx.preedit_length = 0
		ctx.preedit[0] = 0
		ctx.preedit_focus = e.x
		if (ctx.preedit_focus == 0): ctx.preedit_focus = ctx.focus
		ctx.preedit_active = 1
		ctx.preedit_selection = e.y
	else if (e.kind == GFX_EVENT_PREEDIT_TEXT):
		if (ctx.preedit_active && ((e.x == 0) || (e.x == ctx.preedit_focus))):
			int cp = e.code
			if ((cp >= 32) && (cp <= 1114111) && ((cp < 55296) || (cp > 57343))):
				char[4] bytes
				int n = utf8_encode(&bytes[0], cp)
				if (ctx.preedit_length + n < 1024):
					for i in range(n): ctx.preedit[ctx.preedit_length + i] = bytes[i]
					ctx.preedit_length = ctx.preedit_length + n
					ctx.preedit[ctx.preedit_length] = 0
	else if (e.kind == GFX_EVENT_PREEDIT_END):
		if ((e.x == 0) || (e.x == ctx.preedit_focus)):
			ctx.preedit_active = 0
			ctx.preedit_length = 0
			ctx.preedit[0] = 0
	else if (e.kind == GFX_EVENT_CHAR):
		if (ctx.char_count < 32):
			ctx.chars[ctx.char_count] = e.code
			ctx.char_mods[ctx.char_count] = e.mods
			ctx.char_count = ctx.char_count + 1
	else if (e.kind == GFX_EVENT_NAV):
		if (ctx.nav_count < 8):
			ctx.navs[ctx.nav_count] = e.code
			ctx.nav_mods[ctx.nav_count] = e.mods
			ctx.nav_count = ctx.nav_count + 1
	ctx.input.mods = e.mods


# Start a frame: reset ids/hot/layout, start the render batch, clear
# to the theme background (skipped headless).
void ui_begin(ui_context* ctx, int width, int height):
	ctx.hot = 0
	ctx.next_id = 1
	# The root region is the window inset by the theme pad, so the
	# plain vertical stack is just the depth-1 case of a region.
	float32 pad = cast(float32, ctx.theme.pad)
	ui_layout_reset(&ctx.layout_stack[0], ui_rect_new(pad, pad, cast(float32, width) - pad * 2.0, cast(float32, height) - pad * 2.0))
	ctx.layout_depth = 1
	# Scope is per-frame; the open-popup stack is not (it has to outlive
	# the frame that opened it to make earlier widgets inert).
	ctx.scope = 0
	ctx.bracket_depth = 0
	ctx.text_input_id = 0
	ctx.text_input_scope = 0
	ctx.text_input_multiline = 0
	ctx.text_input_rect = ui_rect_new(0.0, 0.0, 0.0, 0.0)
	ctx.text_input_clip = ctx.text_input_rect
	ctx.pointer_mode = 0
	ui_render_begin(ctx.rndr, width, height)
	if (ctx.rndr.gl_ready):
		glClearColor(ctx.theme.background.r, ctx.theme.background.g, ctx.theme.background.b, 1.0)
		glClear(GL_COLOR_BUFFER_BIT)


# Drain the window's event queue and refresh the pointer snapshot,
# then start the frame at the window's current size. The one function
# in this module that touches gfx_window.
void ui_begin_window(ui_context* ctx, gfx_window* win):
	gfx_event e
	while (gfx_window_next_event(win, &e)): ui_feed_event(ctx, &e)
	ctx.input.mouse_x = win.mouse_x
	ctx.input.mouse_y = win.mouse_y
	ui_begin(ctx, win.width, win.height)


# Revalidate after the whole frame: a later widget may open a popup over
# an editor that already declared itself. Popup editors retain their scope
# even after ui_popup_end restores the outer scope.
int ui_text_input_active(ui_context* ctx):
	if ((ctx.text_input_id == 0) || (ctx.text_input_id != ctx.focus)): return 0
	if (ctx.popup_depth > 0):
		if (ctx.text_input_scope != ctx.popup_stack[ctx.popup_depth - 1]): return 0
	else if (ctx.text_input_scope != 0): return 0
	return ui_rect_is_empty(ui_rect_intersect(ctx.text_input_rect, ctx.text_input_clip)) == 0


# Finish a frame: draw the batch, clear the per-frame edges, release
# the press owner once the release has been seen by every widget.
void ui_end(ui_context* ctx):
	ui_render_end(ctx.rndr)
	if (ctx.preedit_focus != ctx.focus):
		ctx.preedit_active = 0
		ctx.preedit_length = 0
		ctx.preedit[0] = 0
	# Sync only after every widget has declared itself; no transient blur
	# between ui_begin and the focused field. Headless tests have no host.
	if (ctx.rndr.gl_ready):
		ui_rect r = ui_rect_intersect(ctx.text_input_rect, ctx.text_input_clip)
		int editing = ui_text_input_active(ctx)
		gfx_text_input(editing, ctx.text_input_multiline, cast(int, r.x), cast(int, r.y), cast(int, r.w), cast(int, r.h), ctx.text_input_id)
		gfx_pointer_mode(ctx.pointer_mode)
	if (ctx.input.mouse_released): ctx.active = 0
	ctx.input.mouse_pressed = 0
	ctx.input.mouse_released = 0
	ctx.input.mouse_right_pressed = 0
	ctx.input.scroll_x = 0
	ctx.input.scroll_y = 0
	ctx.input.scroll_pixels_y = 0
	ctx.char_count = 0
	ctx.nav_count = 0


# Open/close a disabled scope: widgets inside render with the
# disabled tokens and ignore all input.
void ui_disable(ui_context* ctx, int on):
	ctx.disabled = on


# 1 when the code being issued is outside the innermost open popup.
# Everything else on screen is inert while a popup is open — the popup
# handles all input itself — and that has to hold for widgets issued
# BEFORE the popup in the frame as well, which is why the open-popup
# stack persists across frames instead of being a frame-scoped bracket.
int ui_scope_blocked(ui_context* ctx):
	if (ctx.popup_depth == 0): return 0
	if (ctx.scope == ctx.popup_stack[ctx.popup_depth - 1]): return 0
	return 1


# 1 when a CHAR arriving with these gfx_mod bits is typing rather than
# a command chord. Ctrl or Super held makes it a shortcut (Ctrl+S is
# not an 's'), unless Alt is held too: AltGr arrives as Ctrl+Alt on
# Windows and types real characters.
int ui_char_is_typing(int mods):
	if (mods & GFX_MOD_ALT): return 1
	return (mods & (GFX_MOD_CTRL | GFX_MOD_SUPER)) == 0


# A clipped-away widget must not receive a touch through its viewport.
int ui_pointer_inside(ui_context* ctx, ui_rect r, float32 x, float32 y):
	return ui_rect_contains(ui_rect_intersect(r, ui_clip_current(ctx.rndr)), x, y)


# Register only the focused, enabled editor; ui_end sends the final one.
void ui_text_input_declare(ui_context* ctx, int id, ui_rect area, int multiline):
	if ((ctx.focus != id) || ctx.disabled || ui_scope_blocked(ctx)): return
	ctx.text_input_id = id
	ctx.text_input_scope = ctx.scope
	ctx.text_input_multiline = multiline
	ctx.text_input_rect = area
	ctx.text_input_clip = ui_clip_current(ctx.rndr)


# Shared press/release logic: claims hot when the pointer is over the
# rect, active when this frame's press landed inside it; returns 1 on
# the frame the release lands while still over it. Inert inside a
# ui_disable scope, or outside the innermost open popup.
int ui_click_behavior(ui_context* ctx, int id, ui_rect r):
	if (ctx.disabled): return 0
	if (ui_scope_blocked(ctx)): return 0
	int over = ui_pointer_inside(ctx, r, cast(float32, ctx.input.mouse_x), cast(float32, ctx.input.mouse_y))
	if (over): ctx.hot = id
	if (ctx.input.mouse_pressed):
		if (ui_pointer_inside(ctx, r, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
			ctx.active = id
	if (ctx.input.mouse_released && (ctx.active == id) && over): return 1
	return 0


ui_color ui_widget_fill(ui_context* ctx, int id):
	if (ctx.disabled): return ctx.theme.disabled_widget
	if (ctx.active == id): return ctx.theme.widget_active
	if (ctx.hot == id): return ctx.theme.widget_hot
	return ctx.theme.widget


ui_color ui_text_color(ui_context* ctx):
	if (ctx.disabled): return ctx.theme.disabled_text
	return ctx.theme.text


# Draw a clipped, underlined IME preview at the insertion point. The
# caller's buffer/selection remains untouched until committed CHARs arrive.
void ui_text_preedit(ui_context* ctx, int id, ui_rect clip, float32 x, float32 y):
	if ((ctx.focus != id) || (ctx.preedit_focus != id) || (ctx.preedit_active == 0)): return
	if (ctx.disabled || ui_scope_blocked(ctx)): return
	ui_clip_push(ctx.rndr, clip)
	int scale = ctx.theme.text_scale
	int width = ui_text_width(&ctx.preedit[0], scale)
	int height = ui_text_height(scale)
	ui_render_rect(ctx.rndr, ui_rect_new(x, y, cast(float32, width), cast(float32, height)), ctx.theme.widget)
	ui_draw_text(ctx.rndr, x, y, &ctx.preedit[0], scale, ctx.theme.text)
	ui_render_rect(ctx.rndr, ui_rect_new(x, y + cast(float32, height - 1), cast(float32, width), 1.0), ctx.theme.focus)
	ui_clip_pop(ctx.rndr)
