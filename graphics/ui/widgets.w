/*
graphics.ui.widgets: the immediate-mode widget set over the batching
renderer (docs/projects/ui_framework.md §3-4; stage 1: label, button,
checkbox; stage 2: textbox, radio, toggle, progress, dropdown).
Widgets are function calls made every frame; persistent state (a
checkbox's value, a textbox's buffer) is caller-owned, exactly like
gfx_window.

Keyboard input is context-routed: ui_feed_event queues the frame's
CHAR/NAV events on the context, and the widget holding ctx.focus
(claimed by clicking a textbox) consumes them. An open dropdown claims
ctx.modal, which makes every other widget inert until it closes — its
list draws through the renderer's overlay batch so it paints above
widgets issued later in the frame.

Interaction is event-queue-based (graphics.event), not snapshot-based:
ui_feed_event turns MOUSE_DOWN/MOUSE_UP into per-frame pressed/
released edges, so a press+release landing inside one poll cycle still
registers — the §7 motivation for the queue. A widget becomes `active`
when the press event landed inside it and clicks when the release
arrives while the pointer is still over it (press-drag-away-release is
not a click, matching every native toolkit).

Widget ids are sequential per frame in call order — stable for the
static forms of stage 1; hash-based ids are the flagged stage-2
refinement for dynamic layouts.

Layout is a vertical stack cursor: each widget takes the next row
(theme.widget_height tall, theme.gap between rows) starting at
theme.pad; ui_same_line places the next widget to the right of the
previous one instead.
*/
import lib.lib
import graphics.gl
import graphics.window
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text


struct ui_input:
	int32 mouse_x
	int32 mouse_y
	int32 mouse_down       # button 1 currently held
	int32 mouse_pressed    # a button-1 MOUSE_DOWN arrived this frame
	int32 mouse_released   # a button-1 MOUSE_UP arrived this frame
	int32 press_x          # where this frame's press landed
	int32 press_y


struct ui_context:
	ui_renderer* rndr
	ui_theme* theme
	ui_input input
	int32 hot              # widget under the pointer this frame (0 = none)
	int32 active           # widget owning the current press (0 = none)
	int32 focus            # widget owning keyboard input (persistent)
	int32 modal            # open popup owning ALL input (a dropdown)
	int32 disabled         # ui_disable scope: widgets render but are inert
	int32 next_id          # per-frame sequential id counter
	# This frame's translated text input, drained by the focused
	# widget; cleared in ui_end like the mouse edges.
	int32[32] chars        # GFX_EVENT_CHAR codes in arrival order
	int32 char_count
	int32[8] navs          # GFX_EVENT_NAV codes in arrival order
	int32 nav_count
	float32 cursor_x
	float32 cursor_y
	float32 origin_x
	float32 last_right     # previous widget's right edge (for same_line)
	float32 last_top       # previous widget's top edge
	int32 pending_same_line


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


# Place the next widget on the same row as the previous one.
void ui_same_line(ui_context* ctx):
	ctx.pending_same_line = 1


# Claim the next layout rect: the stack cursor position, or to the
# right of the previous widget after ui_same_line.
ui_rect ui_layout_next(ui_context* ctx, float32 w, float32 h):
	float32 x = ctx.cursor_x
	float32 y = ctx.cursor_y
	if (ctx.pending_same_line):
		ctx.pending_same_line = 0
		x = ctx.last_right + cast(float32, ctx.theme.gap)
		y = ctx.last_top
	ui_rect r = ui_rect_new(x, y, w, h)
	ctx.last_right = r.x + r.w
	ctx.last_top = r.y
	ctx.cursor_x = ctx.origin_x
	ctx.cursor_y = r.y + r.h + cast(float32, ctx.theme.gap)
	return r


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


# Static text on the background; occupies one layout row.
void ui_label(ui_context* ctx, char* text):
	int scale = ctx.theme.text_scale
	ui_rect r = ui_layout_next(ctx, cast(float32, ui_text_width(text, scale)), cast(float32, ctx.theme.widget_height))
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, r.x, ty, text, scale, ui_text_color(ctx))


# Returns 1 on the frame the button is clicked.
int ui_button(ui_context* ctx, char* label):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	float32 w = cast(float32, ui_text_width(label, scale) + ctx.theme.pad * 2)
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	int clicked = ui_click_behavior(ctx, id, r)
	ui_render_rect(ctx.rndr, r, ui_widget_fill(ctx, id))
	ui_draw_text_centered(ctx.rndr, r, label, scale, ui_text_color(ctx))
	return clicked


# Caller-owned single-line text buffer for ui_textbox. text stays
# NUL-terminated; caret is a byte index 0..length.
struct ui_textbox_state:
	char[128] text
	int32 length
	int32 caret


int ui_textbox_capacity():
	return 127


void ui_textbox_init(ui_textbox_state* st):
	st.text[0] = 0
	st.length = 0
	st.caret = 0


void ui_textbox_set(ui_textbox_state* st, char* s):
	int len = strlen(s)
	if (len > ui_textbox_capacity()):
		len = ui_textbox_capacity()
	int i = 0
	while (i < len):
		st.text[i] = s[i]
		i = i + 1
	st.text[len] = 0
	st.length = len
	st.caret = len


void ui_textbox_insert(ui_textbox_state* st, int ch):
	if (st.length >= ui_textbox_capacity()):
		return
	int i = st.length
	while (i > st.caret):
		st.text[i] = st.text[i - 1]
		i = i - 1
	st.text[st.caret] = ch
	st.length = st.length + 1
	st.caret = st.caret + 1
	st.text[st.length] = 0


void ui_textbox_backspace(ui_textbox_state* st):
	if (st.caret == 0):
		return
	int i = st.caret - 1
	while (i < st.length - 1):
		st.text[i] = st.text[i + 1]
		i = i + 1
	st.length = st.length - 1
	st.caret = st.caret - 1
	st.text[st.length] = 0


# Single-line text input over caller-owned state. Clicking focuses it
# (the caret lands at the nearest glyph boundary to the click); the
# focused textbox consumes the frame's CHAR/NAV queues — printable
# ASCII inserts at the caret, backspace deletes, left/right/home/end
# move, escape drops focus. Returns 1 on the frame return is typed
# (the submit edge). No horizontal scroll in stage 2: glyphs past the
# field's width are not drawn.
int ui_textbox(ui_context* ctx, float32 w, ui_textbox_state* st):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	int advance = 8 * scale
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	ui_click_behavior(ctx, id, r)

	float32 text_x = r.x + cast(float32, ctx.theme.pad)
	# Focus follows the press: inside claims it, any other press drops
	# it. Inert while another widget holds a popup open or inside a
	# disabled scope.
	if (ctx.input.mouse_pressed && (ctx.modal == 0) && (ctx.disabled == 0)):
		if (ui_rect_contains(r, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
			ctx.focus = id
			int pos = (ctx.input.press_x - cast(int, text_x) + advance / 2) / advance
			if (pos < 0):
				pos = 0
			if (pos > st.length):
				pos = st.length
			st.caret = pos
		else if (ctx.focus == id):
			ctx.focus = 0

	int submitted = 0
	if (ctx.focus == id):
		int i = 0
		while (i < ctx.char_count):
			int ch = ctx.chars[i]
			if ((ch >= 32) && (ch <= 126)):
				ui_textbox_insert(st, ch)
			else if (ch == 8):
				ui_textbox_backspace(st)
			else if (ch == 13):
				submitted = 1
			else if (ch == 27):
				ctx.focus = 0
			i = i + 1
		i = 0
		while (i < ctx.nav_count):
			int nav = ctx.navs[i]
			if ((nav == GFX_NAV_LEFT) && (st.caret > 0)):
				st.caret = st.caret - 1
			else if ((nav == GFX_NAV_RIGHT) && (st.caret < st.length)):
				st.caret = st.caret + 1
			else if (nav == GFX_NAV_HOME):
				st.caret = 0
			else if (nav == GFX_NAV_END):
				st.caret = st.length
			i = i + 1

	ui_color border_color = ctx.theme.border
	if (ctx.focus == id):
		border_color = ctx.theme.focus
	if (ctx.disabled):
		border_color = ctx.theme.disabled_widget
	ui_render_rect(ctx.rndr, r, border_color)
	ui_render_rect(ctx.rndr, ui_rect_inset(r, 2.0), ctx.theme.surface)
	int fit = (cast(int, r.w) - ctx.theme.pad * 2) / advance
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	int col = 0
	while ((col < st.length) && (col < fit)):
		ui_render_glyph(ctx.rndr, text_x + cast(float32, col * advance), ty, st.text[col] & 255, scale, ui_text_color(ctx))
		col = col + 1
	if (ctx.focus == id):
		int caret_col = st.caret
		if (caret_col > fit):
			caret_col = fit
		ui_render_rect(ctx.rndr, ui_rect_new(text_x + cast(float32, caret_col * advance) - 1.0, r.y + 6.0, 2.0, r.h - 12.0), ctx.theme.text)
	return submitted


# One radio option; clicking selects its index into the caller's group
# variable. Returns 1 on the frame this option becomes selected.
int ui_radio(ui_context* ctx, char* label, int index, int32* selected):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	int box = ctx.theme.unit * 2
	float32 w = cast(float32, box + ctx.theme.gap + ui_text_width(label, scale))
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	int clicked = ui_click_behavior(ctx, id, r)
	int changed = 0
	if (clicked && (selected[0] != index)):
		selected[0] = index
		changed = 1

	ui_rect box_rect = ui_rect_new(r.x, r.y + (r.h - cast(float32, box)) * 0.5, cast(float32, box), cast(float32, box))
	ui_render_rect(ctx.rndr, box_rect, ui_widget_fill(ctx, id))
	ui_render_rect(ctx.rndr, ui_rect_inset(box_rect, 2.0), ctx.theme.surface)
	if (selected[0] == index):
		ui_render_rect(ctx.rndr, ui_rect_inset(box_rect, 5.0), ctx.theme.accent)
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, r.x + cast(float32, box + ctx.theme.gap), ty, label, scale, ui_text_color(ctx))
	return changed


# A switch: an accent track with the knob on the off (left) or on
# (right) side. The whole row is clickable; returns 1 on the frame it
# flips.
int ui_toggle(ui_context* ctx, char* label, int32* on):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	int track_w = ctx.theme.unit * 4
	int track_h = ctx.theme.unit * 2
	float32 w = cast(float32, track_w + ctx.theme.gap + ui_text_width(label, scale))
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	int flipped = ui_click_behavior(ctx, id, r)
	if (flipped):
		on[0] = 1 - on[0]

	ui_rect track = ui_rect_new(r.x, r.y + (r.h - cast(float32, track_h)) * 0.5, cast(float32, track_w), cast(float32, track_h))
	ui_color track_color = ctx.theme.widget
	ui_color knob_color = ctx.theme.surface
	if (on[0]):
		track_color = ctx.theme.accent
		if (ctx.hot == id):
			track_color = ctx.theme.accent_hot
		knob_color = ctx.theme.on_accent
	else if (ctx.hot == id):
		track_color = ctx.theme.widget_hot
	if (ctx.disabled):
		track_color = ctx.theme.disabled_widget
		knob_color = ctx.theme.disabled_text
	ui_render_rect(ctx.rndr, track, track_color)
	float32 knob = cast(float32, track_h - 4)
	float32 kx = track.x + 2.0
	if (on[0]):
		kx = track.x + track.w - knob - 2.0
	ui_render_rect(ctx.rndr, ui_rect_new(kx, track.y + 2.0, knob, knob), knob_color)
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, r.x + cast(float32, track_w + ctx.theme.gap), ty, label, scale, ui_text_color(ctx))
	return flipped


# Read-only progress bar; fraction clamps to 0..1.
void ui_progress(ui_context* ctx, float32 w, float32 fraction):
	if (fraction < 0.0):
		fraction = 0.0
	if (fraction > 1.0):
		fraction = 1.0
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	float32 bar_h = cast(float32, ctx.theme.unit)
	ui_rect track = ui_rect_new(r.x, r.y + (r.h - bar_h) * 0.5, r.w, bar_h)
	ui_render_rect(ctx.rndr, track, ctx.theme.widget)
	if (fraction > 0.0):
		ui_render_rect(ctx.rndr, ui_rect_new(track.x, track.y, track.w * fraction, track.h), ctx.theme.accent)


# Collapsed: a button-look header showing items[selected[0]] and a 'v'
# marker; clicking opens the list. Open: the list draws through the
# renderer's overlay batch (above everything else this frame) while
# ctx.modal keeps every other widget inert; pressing an item selects
# it and closes, pressing anywhere else just closes, and either press
# is consumed so widgets after this call never see it. open is caller
# state, like a checkbox's value. Returns 1 on the frame the selection
# changes.
int ui_dropdown(ui_context* ctx, float32 w, char** items, int item_count, int32* selected, int32* open):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	float32 row_h = cast(float32, ctx.theme.widget_height)
	ui_rect r = ui_layout_next(ctx, w, row_h)
	int changed = 0

	if (open[0] == 0):
		if (ui_click_behavior(ctx, id, r)):
			open[0] = 1
			ctx.modal = id
	else:
		ctx.modal = id
		ctx.hot = id
		ui_rect list = ui_rect_new(r.x, r.y + r.h, r.w, row_h * cast(float32, item_count))
		if (ctx.input.mouse_pressed):
			if (ui_rect_contains(list, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
				int pick = (ctx.input.press_y - cast(int, list.y)) / ctx.theme.widget_height
				if (pick >= item_count):
					pick = item_count - 1
				if (selected[0] != pick):
					selected[0] = pick
					changed = 1
			open[0] = 0
			ctx.modal = 0
			ctx.input.mouse_pressed = 0

	ui_render_rect(ctx.rndr, r, ui_widget_fill(ctx, id))
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	if ((selected[0] >= 0) && (selected[0] < item_count)):
		ui_draw_text(ctx.rndr, r.x + cast(float32, ctx.theme.pad), ty, items[selected[0]], scale, ui_text_color(ctx))
	ui_render_glyph(ctx.rndr, r.x + r.w - cast(float32, ctx.theme.pad + 8 * scale), ty, 'v', scale, ctx.theme.text_muted)

	if (open[0]):
		ui_rect list_rect = ui_rect_new(r.x, r.y + r.h, r.w, row_h * cast(float32, item_count))
		ctx.rndr.to_overlay = 1
		ui_render_rect(ctx.rndr, list_rect, ctx.theme.border)
		ui_render_rect(ctx.rndr, ui_rect_inset(list_rect, 1.0), ctx.theme.surface)
		int i = 0
		while (i < item_count):
			ui_rect row = ui_rect_new(list_rect.x, list_rect.y + row_h * cast(float32, i), list_rect.w, row_h)
			if (ui_rect_contains(row, cast(float32, ctx.input.mouse_x), cast(float32, ctx.input.mouse_y))):
				ui_render_rect(ctx.rndr, ui_rect_inset(row, 1.0), ctx.theme.widget_hot)
			if (i == selected[0]):
				ui_render_rect(ctx.rndr, ui_rect_new(row.x + 1.0, row.y + 1.0, 4.0, row.h - 2.0), ctx.theme.accent)
			ui_draw_text(ctx.rndr, row.x + cast(float32, ctx.theme.pad), row.y + (row.h - cast(float32, ui_text_height(scale))) * 0.5, items[i], scale, ctx.theme.text)
			i = i + 1
		ctx.rndr.to_overlay = 0
	return changed


# Toggles *checked and returns 1 on the frame it flips. The whole
# box-plus-label row is clickable.
int ui_checkbox(ui_context* ctx, char* label, int32* checked):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	int box = ctx.theme.unit * 2
	float32 w = cast(float32, box + ctx.theme.gap + ui_text_width(label, scale))
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	int toggled = ui_click_behavior(ctx, id, r)
	if (toggled):
		checked[0] = 1 - checked[0]

	ui_rect box_rect = ui_rect_new(r.x, r.y + (r.h - cast(float32, box)) * 0.5, cast(float32, box), cast(float32, box))
	ui_render_rect(ctx.rndr, box_rect, ui_widget_fill(ctx, id))
	if (checked[0]):
		ui_render_rect(ctx.rndr, ui_rect_inset(box_rect, 3.0), ctx.theme.accent)
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, r.x + cast(float32, box + ctx.theme.gap), ty, label, scale, ui_text_color(ctx))
	return toggled
