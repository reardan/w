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
	# The touched state validated fields key their errors on: 0 while
	# pristine, 1 once typing has changed the text, 2 once the field
	# has then lost focus. Set only by ui_textbox's own editing, so a
	# ui_textbox_set prefill does not count as the user's edit.
	int32 edited


int ui_textbox_capacity():
	return 127


void ui_textbox_init(ui_textbox_state* st):
	st.text[0] = 0
	st.length = 0
	st.caret = 0
	st.edited = 0


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


# Insert codepoint ch at the caret as UTF-8. A character that does not
# fit whole is dropped rather than split.
void ui_textbox_insert(ui_textbox_state* st, int ch):
	char[4] bytes
	int n = ui_utf8_encode(&bytes[0], ch)
	if (st.length + n > ui_textbox_capacity()):
		return
	int i = st.length - 1
	while (i >= st.caret):
		st.text[i + n] = st.text[i]
		i = i - 1
	int k = 0
	while (k < n):
		st.text[st.caret + k] = bytes[k]
		k = k + 1
	st.length = st.length + n
	st.caret = st.caret + n
	st.text[st.length] = 0


# Delete the whole character before the caret.
void ui_textbox_backspace(ui_textbox_state* st):
	if (st.caret == 0):
		return
	int from = ui_utf8_prev(&st.text[0], st.caret)
	int n = st.caret - from
	int i = from
	while (i + n < st.length):
		st.text[i] = st.text[i + n]
		i = i + 1
	st.length = st.length - n
	st.caret = from
	st.text[st.length] = 0


void ui_textbox_mark_edited(ui_textbox_state* st):
	if (st.edited == 0):
		st.edited = 1


# Single-line text input over caller-owned state. Clicking focuses it
# (the caret lands at the nearest glyph boundary to the click); the
# focused textbox consumes the frame's CHAR/NAV queues — printable
# characters insert at the caret as UTF-8, backspace deletes and
# left/right step over whole characters, home/end move, escape drops
# focus. Returns 1 on the frame return is typed
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
			if (ui_utf8_is_text(ch)):
				ui_textbox_insert(st, ch)
				ui_textbox_mark_edited(st)
			else if (ch == 8):
				ui_textbox_backspace(st)
				ui_textbox_mark_edited(st)
			else if (ch == 13):
				submitted = 1
			else if (ch == 27):
				ctx.focus = 0
			i = i + 1
		i = 0
		while (i < ctx.nav_count):
			int nav = ctx.navs[i]
			if ((nav == GFX_NAV_LEFT) && (st.caret > 0)):
				st.caret = ui_utf8_prev(&st.text[0], st.caret)
			else if ((nav == GFX_NAV_RIGHT) && (st.caret < st.length)):
				int cp = 0
				st.caret = ui_utf8_next(&st.text[0], st.caret, &cp)
			else if (nav == GFX_NAV_HOME):
				st.caret = 0
			else if (nav == GFX_NAV_END):
				st.caret = st.length
			i = i + 1
	# Edited and no longer focused, however focus left (a press
	# elsewhere, escape, another widget claiming it): the field is
	# touched from here on.
	if ((st.edited == 1) && (ctx.focus != id)):
		st.edited = 2

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
	# Proportional draw of the characters that fit the field's width
	# (no horizontal scroll yet — glyphs past it are not drawn).
	int fit_w = cast(int, r.w) - ctx.theme.pad * 2
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	int shown = ui_text_fit_strike(&st.text[0], ui_font_strike_from_scale(scale), fit_w)
	ui_draw_text_n(ctx.rndr, text_x, ty, &st.text[0], shown, scale, ui_text_color(ctx))
	if (ctx.focus == id):
		int caret_w = ui_text_prefix_width(&st.text[0], st.caret, scale)
		if (caret_w > fit_w):
			caret_w = fit_w
		ui_render_rect(ctx.rndr, ui_rect_new(text_x + cast(float32, caret_w) - 1.0, r.y + 6.0, 2.0, r.h - 12.0), ctx.theme.text)
	return submitted
