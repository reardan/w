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
import lib.mem
import graphics.ui.grapheme
import graphics.ui.widgets.access_text


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
	# Selection anchor: the byte offset the selection extends from to
	# the caret, -1 when nothing is selected. Out-of-range values (a
	# state that skipped ui_textbox_init) read as no selection.
	int32 anchor
	# What a drag extends by: 1 characters, 2 words (after a
	# double-click), 3 the whole line (after a triple-click), with the
	# word or line the press selected in unit_start..unit_end.
	int32 unit
	int unit_start
	int unit_end


const int ui_textbox_capacity = 127


void ui_textbox_init(ui_textbox_state* st):
	st.text[0] = 0
	st.length = 0
	st.caret = 0
	st.edited = 0
	st.anchor = 0 - 1
	st.unit = 1
	st.unit_start = 0
	st.unit_end = 0


void ui_textbox_set(ui_textbox_state* st, char* s):
	int len = strlen(s)
	if (len > ui_textbox_capacity): len = ui_grapheme_floor(s, ui_textbox_capacity)
	mem_copy[char](st.text, s, len)
	st.text[len] = 0
	st.length = len
	st.caret = len
	st.anchor = 0 - 1


# 1 when a non-empty range is selected.
int ui_textbox_has_selection(ui_textbox_state* st):
	if ((st.anchor < 0) || (st.anchor > st.length)): return 0
	return st.anchor != st.caret


int ui_textbox_sel_start(ui_textbox_state* st):
	if (ui_textbox_has_selection(st) && (st.anchor < st.caret)): return st.anchor
	return st.caret


int ui_textbox_sel_end(ui_textbox_state* st):
	if (ui_textbox_has_selection(st) && (st.anchor > st.caret)): return st.anchor
	return st.caret


# Select the whole text, caret at the end (Ctrl+A).
void ui_textbox_select_all(ui_textbox_state* st):
	st.anchor = 0
	st.caret = st.length


# Remove the selected bytes, leaving the caret where they started.
# Returns 1 when there was a selection.
int ui_textbox_delete_selection(ui_textbox_state* st):
	if (ui_textbox_has_selection(st) == 0):
		st.anchor = 0 - 1
		return 0
	int start = ui_textbox_sel_start(st)
	int n = ui_textbox_sel_end(st) - start
	int i = start
	while (i + n <= st.length):
		st.text[i] = st.text[i + n]
		i = i + 1
	st.length = st.length - n
	st.caret = start
	st.anchor = 0 - 1
	return 1


# Start, extend or drop the selection before a caret motion: shift
# anchors at the pre-move caret (unless a selection already holds one),
# no shift drops it.
void ui_textbox_anchor(ui_textbox_state* st, int shift):
	if (shift):
		if (ui_textbox_has_selection(st) == 0): st.anchor = st.caret
	else: st.anchor = 0 - 1


# Insert codepoint ch at the caret as UTF-8, replacing the selection. A
# character that does not fit whole is dropped rather than split.
void ui_textbox_insert(ui_textbox_state* st, int ch):
	ui_textbox_delete_selection(st)
	char[4] bytes
	int n = ui_utf8_encode(&bytes[0], ch)
	if (st.length + n > ui_textbox_capacity): return
	int i = st.length - 1
	while (i >= st.caret):
		st.text[i + n] = st.text[i]
		i = i - 1
	for k in range(n): st.text[st.caret + k] = bytes[k]
	st.length = st.length + n
	st.caret = st.caret + n
	st.text[st.length] = 0
	st.caret = ui_grapheme_ceil(&st.text[0], st.caret)


# Insert pasted text at the caret, replacing the selection. A single
# line keeps no line breaks: newlines and tabs become spaces and other
# control characters are dropped. Text past the capacity is cut at the
# last whole character that fits.
void ui_textbox_insert_text(ui_textbox_state* st, char* s):
	ui_textbox_delete_selection(st)
	int at = 0
	int length = strlen(s)
	while (at < length):
		int cp = 0
		int n = utf8_scan(s + at, length - at, &cp)
		if (n == 0):
			cp = 65533
			n = 1
		if ((cp == 10) || (cp == 9)): cp = ' '
		if (ui_utf8_is_text(cp)):
			int before = st.length
			ui_textbox_insert(st, cp)
			if (st.length == before): return
		at = at + n


# Delete the selection, or else the whole grapheme before the caret.
void ui_textbox_backspace(ui_textbox_state* st):
	if (ui_textbox_delete_selection(st)): return
	if (st.caret == 0): return
	int from = ui_grapheme_prev(&st.text[0], st.caret)
	int n = st.caret - from
	int i = from
	while (i + n < st.length):
		st.text[i] = st.text[i + n]
		i = i + 1
	st.length = st.length - n
	st.text[st.length] = 0
	st.caret = ui_grapheme_floor(&st.text[0], from)


# Delete the selection, or else the whole grapheme after the caret.
void ui_textbox_delete_forward(ui_textbox_state* st):
	if (ui_textbox_delete_selection(st)): return
	if (st.caret >= st.length): return
	int to = ui_grapheme_next(&st.text[0], st.caret)
	int n = to - st.caret
	int i = st.caret
	while (i + n <= st.length):
		st.text[i] = st.text[i + n]
		i = i + 1
	st.length = st.length - n


# The range a press of the given click count selects around byte offset
# hit: the word there (ui_word_bounds) for a double-click, the whole line
# for a triple-click.
void ui_textbox_unit_range(ui_textbox_state* st, int unit, int hit, int* start, int* end):
	if (unit >= 3):
		start[0] = 0
		end[0] = st.length
	else: ui_word_bounds(&st.text[0], st.length, hit, start, end)


# Select by words or lines from the press's unit_start..unit_end to the
# unit under hit, the anchor at whichever end the pointer moved away
# from (a drag after a double- or triple-click).
void ui_textbox_select_units(ui_textbox_state* st, int hit):
	int start = 0
	int end = 0
	ui_textbox_unit_range(st, st.unit, hit, &start, &end)
	if (start < st.unit_start):
		st.anchor = st.unit_end
		st.caret = start
	else:
		st.anchor = st.unit_start
		st.caret = end
		if (st.caret < st.unit_end): st.caret = st.unit_end


void ui_textbox_mark_edited(ui_textbox_state* st):
	if (st.edited == 0): st.edited = 1


# The field's glyph boxes and text attributes for the accessibility
# snapshot (#863), from the layout ui_textbox draws: characters from the
# padded left edge, vertically centred, clipped to the drawn width.
void ui_textbox_access_layout(ui_context* ctx, ui_access_node* node, ui_textbox_state* st, ui_rect r):
	if ((node == 0) || (ctx.access == 0)): return
	int scale = ctx.theme.text_scale
	float32 pad = cast(float32, ctx.theme.pad)
	float32 h = cast(float32, ui_text_height(scale))
	ui_rect* boxes = cast(ui_rect*, malloc((st.length + 1) * sizeof(ui_rect)))
	int count = ui_access_line_boxes(&st.text[0], st.length, scale, r.x + pad, r.y + (r.h - h) * 0.5, h, r.x + r.w - pad, boxes)
	ui_access_publish_boxes(ctx, node, boxes, count)
	ui_color fill = ctx.theme.widget
	if (ctx.disabled): fill = ctx.theme.disabled_widget
	ui_access_field_attrs(ctx, node, scale, ui_text_color(ctx), fill)


# Single-line text input over caller-owned state. Clicking focuses it
# (the caret lands at the nearest glyph boundary to the click), dragging
# selects, Shift+click extends, a double-click selects the word under the
# pointer (UAX #29 word boundaries) and a triple-click the whole line,
# a drag after either extending by words or lines; every new selection
# becomes the PRIMARY selection and a middle-click pastes it; the focused textbox consumes the
# frame's CHAR/NAV queues — printable characters replace the selection
# or insert at the caret as UTF-8, backspace/delete remove the selection
# or a whole character, left/right step over whole characters, home/end
# move, Shift with any of them extends the selection, Ctrl/Cmd+A selects
# all, Ctrl/Cmd+C/X/V copy, cut and paste (ui_clipboard_*), escape drops
# focus. Tab reaches it in focus order, and an accessibility bridge can
# replace its text and move its caret. Returns 1 on the frame return is typed
# (the submit edge). No horizontal scroll in stage 2: glyphs past the
# field's width are not drawn.
int ui_textbox(ui_context* ctx, float32 w, ui_textbox_state* st):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	ui_click_behavior(ctx, id, r)
	ui_access_node* node = ui_access_widget(ctx, id, UI_ACCESS_TEXTBOX, r, 0)
	if (node != 0): node.actions = UI_ACCESS_SET_VALUE | UI_ACCESS_SET_SELECTION
	ui_focus_stop(ctx, id, r, 0)
	char* requested = ui_access_value_request(ctx, id)
	if (requested != 0):
		ui_textbox_set(st, requested)
		ui_textbox_mark_edited(st)
	# An assistive selection request selects anchor..active (character
	# offsets), or just places the caret when they are equal.
	int sel_anchor = 0
	int sel_active = 0
	if (ui_access_selection_request(ctx, id, &sel_anchor, &sel_active)):
		st.caret = ui_grapheme_floor(&st.text[0], ui_access_char_byte(&st.text[0], st.length, sel_active))
		st.anchor = ui_grapheme_floor(&st.text[0], ui_access_char_byte(&st.text[0], st.length, sel_anchor))

	float32 text_x = r.x + cast(float32, ctx.theme.pad)
	# The selection before this frame's input, to publish PRIMARY when it
	# changes.
	int was_anchor = st.anchor
	int was_caret = st.caret
	int was_length = st.length
	# Focus follows the press: inside claims it, any other press drops
	# it. Inert while another widget holds a popup open or inside a
	# disabled scope.
	if (ctx.input.mouse_pressed && (ui_scope_blocked(ctx) == 0) && (ctx.disabled == 0)):
		if (ui_pointer_inside(ctx, r, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
			# Shift+click in the focused field extends the selection;
			# any other press anchors a new one at the caret, which a
			# drag then stretches.
			int extend = (ctx.focus == id) && ((ctx.input.mods & GFX_MOD_SHIFT) != 0)
			ctx.focus = id
			if (extend): ui_textbox_anchor(st, 1)
			# Proportional caret: the nearest glyph boundary to the
			# click.
			int press_rel = ctx.input.press_x - cast(int, text_x)
			st.caret = ui_text_caret_from_x(&st.text[0], scale, press_rel)
			st.unit = 1
			if ((extend == 0) && (ctx.input.clicks >= 2)):
				# Double-click selects the word under the pointer,
				# triple-click the line; a drag then extends by them.
				st.unit = 2
				if (ctx.input.clicks >= 3): st.unit = 3
				ui_textbox_unit_range(st, st.unit, ui_text_hit_from_x(&st.text[0], scale, press_rel), &st.unit_start, &st.unit_end)
				st.anchor = st.unit_start
				st.caret = st.unit_end
			else if (extend == 0): st.anchor = st.caret
		else if (ctx.focus == id): ctx.focus = 0
	else if (ctx.input.mouse_down && (ctx.active == id) && (ctx.focus == id) && (ctx.disabled == 0)):
		# Drag selection: the caret follows the pointer, the anchor stays.
		ctx.pointer_mode = 1
		int drag_rel = ctx.input.mouse_x - cast(int, text_x)
		if (st.unit >= 2): ui_textbox_select_units(st, ui_text_hit_from_x(&st.text[0], scale, drag_rel))
		else:
			int dragged = ui_text_caret_from_x(&st.text[0], scale, drag_rel)
			if (dragged < 0): dragged = 0
			st.caret = dragged
	# Middle-click pastes the PRIMARY selection at the pointer (X11's
	# convention; elsewhere the program's own last selection).
	if (ctx.input.mouse_middle_pressed && (ui_scope_blocked(ctx) == 0) && (ctx.disabled == 0)):
		if (ui_pointer_inside(ctx, r, cast(float32, ctx.input.middle_x), cast(float32, ctx.input.middle_y))):
			ctx.input.mouse_middle_pressed = 0
			ctx.focus = id
			st.caret = ui_text_caret_from_x(&st.text[0], scale, ctx.input.middle_x - cast(int, text_x))
			st.anchor = 0 - 1
			ui_primary_paste_request(ctx, id)
	# A click that selected nothing leaves no anchor behind once released.
	if ((ctx.input.mouse_down == 0) && (ui_textbox_has_selection(st) == 0)): st.anchor = 0 - 1

	int submitted = 0
	# A focused field behind an open popup keeps its focus but not the
	# keyboard: the popup (a menu, a dropdown) is what the keys are for.
	if ((ctx.focus == id) && (ctx.disabled == 0) && (ui_scope_blocked(ctx) == 0)):
		int i = 0
		while (i < ctx.char_count):
			int ch = ctx.chars[i]
			int command = ui_clipboard_command(ch, ctx.char_mods[i])
			if (command == 'a'): ui_textbox_select_all(st)
			else if (command == 'c'):
				if (ui_textbox_has_selection(st)):
					int from = ui_textbox_sel_start(st)
					ui_clipboard_copy(ctx, &st.text[from], ui_textbox_sel_end(st) - from)
			else if (command == 'x'):
				if (ui_textbox_has_selection(st)):
					int from = ui_textbox_sel_start(st)
					ui_clipboard_copy(ctx, &st.text[from], ui_textbox_sel_end(st) - from)
					ui_textbox_delete_selection(st)
					ui_textbox_mark_edited(st)
			else if (command == 'v'): ui_clipboard_paste_request(ctx, id)
			else if (ui_utf8_is_text(ch) && ui_char_is_typing(ctx.char_mods[i])):
				ui_textbox_insert(st, ch)
				ui_textbox_mark_edited(st)
			else if (ch == 8):
				ui_textbox_backspace(st)
				ui_textbox_mark_edited(st)
			else if (ch == 13): submitted = 1
			else if (ch == 27): ctx.focus = 0
			i = i + 1
		i = 0
		while (i < ctx.nav_count):
			int nav = ctx.navs[i]
			if (nav == GFX_NAV_DELETE):
				int before = st.length
				ui_textbox_delete_forward(st)
				if (st.length != before): ui_textbox_mark_edited(st)
				i = i + 1
				continue
			if ((nav == GFX_NAV_LEFT) || (nav == GFX_NAV_RIGHT) || (nav == GFX_NAV_HOME) || (nav == GFX_NAV_END)):
				ui_textbox_anchor(st, ctx.nav_mods[i] & GFX_MOD_SHIFT)
			if ((nav == GFX_NAV_LEFT) && (st.caret > 0)):
				st.caret = ui_grapheme_prev(&st.text[0], st.caret)
			else if ((nav == GFX_NAV_RIGHT) && (st.caret < st.length)):
				st.caret = ui_grapheme_next(&st.text[0], st.caret)
			else if (nav == GFX_NAV_HOME): st.caret = 0
			else if (nav == GFX_NAV_END): st.caret = st.length
			i = i + 1
		char* pasted = ui_clipboard_paste_take(ctx, id)
		if (pasted != 0):
			ui_textbox_insert_text(st, pasted)
			ui_textbox_mark_edited(st)
			free(pasted)
	# A new or changed selection becomes the PRIMARY selection.
	if ((ctx.focus == id) && ui_textbox_has_selection(st) && ((st.anchor != was_anchor) || (st.caret != was_caret) || (st.length != was_length))):
		int from = ui_textbox_sel_start(st)
		ui_primary_publish(ctx, &st.text[from], ui_textbox_sel_end(st) - from)
	# Edited and no longer focused, however focus left (a press
	# elsewhere, escape, another widget claiming it): the field is
	# touched from here on.
	if ((st.edited == 1) && (ctx.focus != id)): st.edited = 2

	# Material filled field: a rounded tonal fill with a 2px baseline
	# that turns into the focus color while focused.
	ui_color field_fill = ctx.theme.widget
	ui_color line = ctx.theme.border
	if (ctx.focus == id): line = ctx.theme.focus
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
	# Selection highlight behind the glyphs, clipped to the drawn width.
	if ((ctx.focus == id) && ui_textbox_has_selection(st)):
		int x0 = ui_text_prefix_width(&st.text[0], ui_textbox_sel_start(st), scale)
		int x1 = ui_text_prefix_width(&st.text[0], ui_textbox_sel_end(st), scale)
		if (x1 > fit_w): x1 = fit_w
		if (x1 > x0): ui_render_rect(ctx.rndr, ui_rect_new(text_x + cast(float32, x0), r.y + 6.0, cast(float32, x1 - x0), r.h - 12.0), ctx.theme.accent_hot)
	ui_draw_text_n(ctx.rndr, text_x, ty, &st.text[0], shown, scale, ui_text_color(ctx))
	if ((ctx.focus == id) && (ui_text_preedit_showing(ctx, id) == 0)):
		int caret_w = ui_text_prefix_width(&st.text[0], st.caret, scale)
		if (caret_w > fit_w): caret_w = fit_w
		ui_render_rect(ctx.rndr, ui_rect_new(text_x + cast(float32, caret_w) - 1.0, r.y + 6.0, 2.0, r.h - 12.0), ctx.theme.text)
	ui_text_preedit(ctx, id, r, text_x + cast(float32, ui_text_prefix_width(&st.text[0], st.caret, scale)), ty)
	ui_text_input_declare(ctx, id, r, 0)
	ui_access_set_value(ctx, node, &st.text[0], st.length)
	int access_anchor = st.caret
	if (ui_textbox_has_selection(st)): access_anchor = st.anchor
	ui_access_set_caret(ctx, node, access_anchor, st.caret)
	ui_textbox_access_layout(ctx, node, st, r)
	return submitted
