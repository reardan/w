/*
graphics.ui.widgets.textbox: the single-line text field and its
caller-owned buffer (docs/projects/ui_widgets.md §3). The fixed 128-byte
buffer is what the multi-line edit surface replaces with
graphics.ui.widgets.buffer.
*/
import lib.lib
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context


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
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	ui_click_behavior(ctx, id, r)

	float32 text_x = r.x + cast(float32, ctx.theme.pad)
	# Focus follows the press: inside claims it, any other press drops
	# it. Inert while another widget holds a popup open or inside a
	# disabled scope.
	if (ctx.input.mouse_pressed && (ui_scope_blocked(ctx) == 0) && (ctx.disabled == 0)):
		if (ui_rect_contains(r, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
			ctx.focus = id
			# Proportional caret: the nearest glyph boundary to the
			# click.
			st.caret = ui_text_caret_from_x(&st.text[0], scale, ctx.input.press_x - cast(int, text_x))
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

	# Material filled field: a rounded tonal fill with a 2px baseline
	# that turns into the focus color while focused.
	ui_color field_fill = ctx.theme.widget
	ui_color line = ctx.theme.border
	if (ctx.focus == id):
		line = ctx.theme.focus
	if (ctx.disabled):
		field_fill = ctx.theme.disabled_widget
		line = ctx.theme.disabled_widget
	ui_draw_rrect(ctx.rndr, r, cast(float32, ctx.theme.radius), field_fill)
	ui_render_rect(ctx.rndr, ui_rect_new(r.x + 4.0, r.y + r.h - 2.0, r.w - 8.0, 2.0), line)
	# Proportional draw: advance per glyph, stop at the field's width
	# (no horizontal scroll yet — glyphs past it are not drawn).
	int fit_w = cast(int, r.w) - ctx.theme.pad * 2
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	int strike = ui_font_strike_from_scale(scale)
	int pen = 0
	int col = 0
	while (col < st.length):
		ui_glyph g = ui_font_glyph(strike, st.text[col] & 255)
		if (pen + g.advance > fit_w):
			break
		ui_render_glyph(ctx.rndr, text_x + cast(float32, pen), ty, st.text[col] & 255, scale, ui_text_color(ctx))
		pen = pen + g.advance
		col = col + 1
	if (ctx.focus == id):
		int caret_w = ui_text_prefix_width(&st.text[0], st.caret, scale)
		if (caret_w > fit_w):
			caret_w = fit_w
		ui_render_rect(ctx.rndr, ui_rect_new(text_x + cast(float32, caret_w) - 1.0, r.y + 6.0, 2.0, r.h - 12.0), ctx.theme.text)
	return submitted
