/*
graphics.ui.widgets.textarea: a multi-line edit surface over
ui_text_buffer (docs/projects/ui_widgets.md §5). The widget the whole
foundation round was for: it needs the clip, the layout region, the
scroll viewport, the buffer and stage 1's modifier flags, and could not
have been written without any one of them.

	ui_textarea_init(&st)
	ui_textarea_set(&st, c"hello\nworld")
	...
	if (ui_textarea(ctx, area, &st)):
		# the buffer changed this frame

Focus works like ui_textbox's: clicking inside claims ctx.focus, and
the focused textarea drains the frame's CHAR and NAV queues. Printable
ASCII inserts, backspace and delete remove, return inserts a newline.
Arrows, page up/down, home/end move the caret; with shift held they
extend the selection from its anchor, and with ctrl held home/end go to
the ends of the buffer.

Only the visible line range is drawn, so a long document costs the
vertices of the lines on screen.
*/
import lib.lib
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets.state
import graphics.ui.widgets.buffer
import graphics.ui.widgets.layout
import graphics.ui.widgets.context
import graphics.ui.widgets.scroll


struct ui_textarea_state:
	ui_text_buffer buf
	int32 caret_line
	int32 caret_col
	# The column vertical motion aims for, so walking down through a
	# short line and back out returns to where the caret started.
	int32 caret_goal_col
	int32 sel_anchor       # byte offset the selection extends from, -1 = none
	ui_scroll_state scroll


void ui_textarea_init(ui_textarea_state* st):
	ui_text_buffer_init(&st.buf)
	st.caret_line = 0
	st.caret_col = 0
	st.caret_goal_col = 0
	st.sel_anchor = 0 - 1
	ui_scroll_init(&st.scroll)


void ui_textarea_free(ui_textarea_state* st):
	ui_text_buffer_free(&st.buf)


void ui_textarea_set(ui_textarea_state* st, char* s):
	ui_text_buffer_set(&st.buf, s)
	st.caret_line = 0
	st.caret_col = 0
	st.caret_goal_col = 0
	st.sel_anchor = 0 - 1


# The caret's byte offset in the buffer.
int ui_textarea_caret_offset(ui_textarea_state* st):
	return ui_text_buffer_line_col_to_offset(&st.buf, st.caret_line, st.caret_col)


# Move the caret to a byte offset, keeping line/col in step.
void ui_textarea_set_caret(ui_textarea_state* st, int offset):
	if (offset < 0):
		offset = 0
	if (offset > st.buf.length):
		offset = st.buf.length
	st.caret_line = ui_text_buffer_offset_to_line(&st.buf, offset)
	st.caret_col = offset - ui_text_buffer_line_start(&st.buf, st.caret_line)


int ui_textarea_line_height(ui_context* ctx):
	return ui_text_height(ctx.theme.text_scale) + 2


# 1 when a selection exists and is not empty.
int ui_textarea_has_selection(ui_textarea_state* st):
	if (st.sel_anchor < 0):
		return 0
	if (st.sel_anchor == ui_textarea_caret_offset(st)):
		return 0
	return 1


int ui_textarea_sel_start(ui_textarea_state* st):
	int caret = ui_textarea_caret_offset(st)
	if (st.sel_anchor < caret):
		return st.sel_anchor
	return caret


int ui_textarea_sel_end(ui_textarea_state* st):
	int caret = ui_textarea_caret_offset(st)
	if (st.sel_anchor > caret):
		return st.sel_anchor
	return caret


# Delete the selection if there is one; returns 1 when it deleted.
int ui_textarea_delete_selection(ui_textarea_state* st):
	if (ui_textarea_has_selection(st) == 0):
		st.sel_anchor = 0 - 1
		return 0
	int start = ui_textarea_sel_start(st)
	int end = ui_textarea_sel_end(st)
	ui_text_buffer_delete(&st.buf, start, end - start)
	ui_textarea_set_caret(st, start)
	st.sel_anchor = 0 - 1
	return 1


# Start, extend or drop the selection for a motion key: shift held
# anchors at the pre-move caret and keeps it, shift released drops it.
void ui_textarea_anchor(ui_textarea_state* st, int shift):
	if (shift):
		if (st.sel_anchor < 0):
			st.sel_anchor = ui_textarea_caret_offset(st)
	else:
		st.sel_anchor = 0 - 1


# Vertical motion aims at goal_col, which a short line clamps for
# display but does not overwrite — so passing through one and out the
# other side lands back at the original column.
void ui_textarea_move_line(ui_textarea_state* st, int delta):
	int line = st.caret_line + delta
	if (line < 0):
		line = 0
	if (line >= st.buf.line_count):
		line = st.buf.line_count - 1
	st.caret_line = line
	int len = ui_text_buffer_line_length(&st.buf, line)
	if (st.caret_goal_col < len):
		st.caret_col = st.caret_goal_col
	else:
		st.caret_col = len


# Apply one NAV code. goal_col survives vertical motion and is reset by
# everything else.
void ui_textarea_nav(ui_textarea_state* st, int nav, int mods, int page_lines):
	int shift = mods & GFX_MOD_SHIFT
	int ctrl = mods & GFX_MOD_CTRL
	# Delete is an edit, not a motion: it consumes the selection rather
	# than dropping it, so it has to run before the motion keys' anchor
	# handling clears it.
	if (nav == GFX_NAV_DELETE):
		if (ui_textarea_delete_selection(st) == 0):
			int at = ui_textarea_caret_offset(st)
			if (at < st.buf.length):
				ui_text_buffer_delete(&st.buf, at, 1)
				ui_textarea_set_caret(st, at)
		st.caret_goal_col = st.caret_col
		return
	ui_textarea_anchor(st, shift)
	int offset = ui_textarea_caret_offset(st)
	if (nav == GFX_NAV_LEFT):
		if (offset > 0):
			ui_textarea_set_caret(st, offset - 1)
		st.caret_goal_col = st.caret_col
	else if (nav == GFX_NAV_RIGHT):
		if (offset < st.buf.length):
			ui_textarea_set_caret(st, offset + 1)
		st.caret_goal_col = st.caret_col
	else if (nav == GFX_NAV_HOME):
		if (ctrl):
			ui_textarea_set_caret(st, 0)
		else:
			st.caret_col = 0
		st.caret_goal_col = st.caret_col
	else if (nav == GFX_NAV_END):
		if (ctrl):
			ui_textarea_set_caret(st, st.buf.length)
		else:
			st.caret_col = ui_text_buffer_line_length(&st.buf, st.caret_line)
		st.caret_goal_col = st.caret_col
	else if (nav == GFX_NAV_UP):
		ui_textarea_move_line(st, 0 - 1)
	else if (nav == GFX_NAV_DOWN):
		ui_textarea_move_line(st, 1)
	else if (nav == GFX_NAV_PAGE_UP):
		ui_textarea_move_line(st, 0 - page_lines)
	else if (nav == GFX_NAV_PAGE_DOWN):
		ui_textarea_move_line(st, page_lines)


# Insert one typed character, replacing any selection first.
void ui_textarea_type(ui_textarea_state* st, int ch):
	ui_textarea_delete_selection(st)
	int offset = ui_textarea_caret_offset(st)
	ui_text_buffer_insert(&st.buf, offset, ch)
	ui_textarea_set_caret(st, offset + 1)
	st.caret_goal_col = st.caret_col


void ui_textarea_backspace(ui_textarea_state* st):
	if (ui_textarea_delete_selection(st)):
		st.caret_goal_col = st.caret_col
		return
	int offset = ui_textarea_caret_offset(st)
	if (offset == 0):
		return
	ui_text_buffer_delete(&st.buf, offset - 1, 1)
	ui_textarea_set_caret(st, offset - 1)
	st.caret_goal_col = st.caret_col


# The multi-line edit surface. Returns 1 on frames the buffer changed.
int ui_textarea(ui_context* ctx, ui_rect area, ui_textarea_state* st):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	float32 pad = cast(float32, ctx.theme.pad)
	float32 line_h = cast(float32, ui_textarea_line_height(ctx))
	int page_lines = cast(int, (area.h - pad * 2.0) / line_h)
	if (page_lines < 1):
		page_lines = 1

	# Field surface, focus underline like ui_textbox's.
	ui_color line_color = ctx.theme.border
	if (ctx.focus == id):
		line_color = ctx.theme.focus
	ui_color fill = ctx.theme.widget
	if (ctx.disabled):
		fill = ctx.theme.disabled_widget
		line_color = ctx.theme.disabled_widget
	ui_draw_rrect(ctx.rndr, area, cast(float32, ctx.theme.radius), fill)
	ui_render_rect(ctx.rndr, ui_rect_new(area.x + 4.0, area.y + area.h - 2.0, area.w - 8.0, 2.0), line_color)

	# Focus follows the press, and the caret lands where it landed.
	ui_rect view = ui_rect_new(area.x + pad, area.y + pad, area.w - pad * 2.0, area.h - pad * 2.0)
	if (ctx.input.mouse_pressed && (ui_scope_blocked(ctx) == 0) && (ctx.disabled == 0)):
		float32 px = cast(float32, ctx.input.press_x)
		float32 py = cast(float32, ctx.input.press_y)
		if (ui_rect_contains(area, px, py)):
			ctx.focus = id
			int line = cast(int, (py - view.y + st.scroll.offset_y) / line_h)
			if (line < 0):
				line = 0
			if (line >= st.buf.line_count):
				line = st.buf.line_count - 1
			st.caret_line = line
			int start = ui_text_buffer_line_start(&st.buf, line)
			st.caret_col = ui_text_caret_from_x(&st.buf.data[start], scale, cast(int, px - view.x + st.scroll.offset_x))
			int len = ui_text_buffer_line_length(&st.buf, line)
			if (st.caret_col > len):
				st.caret_col = len
			st.caret_goal_col = st.caret_col
			st.sel_anchor = 0 - 1
		else if (ctx.focus == id):
			ctx.focus = 0

	int changed = 0
	if ((ctx.focus == id) && (ctx.disabled == 0)):
		int i = 0
		while (i < ctx.char_count):
			int ch = ctx.chars[i]
			if ((ch >= 32) && (ch <= 126)):
				ui_textarea_type(st, ch)
				changed = 1
			else if (ch == 9):
				ui_textarea_type(st, ' ')
				changed = 1
			else if (ch == 8):
				ui_textarea_backspace(st)
				changed = 1
			else if (ch == 13):
				# Return inserts a newline here: a multi-line field has
				# no submit edge to steal it for.
				ui_textarea_type(st, '\n')
				changed = 1
			else if (ch == 27):
				ctx.focus = 0
			i = i + 1
		i = 0
		while (i < ctx.nav_count):
			int before = st.buf.length
			ui_textarea_nav(st, ctx.navs[i], ctx.nav_mods[i], page_lines)
			if (st.buf.length != before):
				changed = 1
			i = i + 1

	# Keep the caret in view after typing or motion.
	ui_scroll_reveal(&st.scroll, cast(float32, st.caret_line) * line_h, line_h)

	ui_scroll_begin(ctx, view, &st.scroll)
	ui_layout* lo = ui_layout_top(ctx)
	float32 origin_x = lo.bounds.x
	float32 origin_y = lo.bounds.y
	# The whole document's extent, so scroll knows what it is scrolling
	# even though only the visible lines are issued.
	ui_region_claim(ctx, ui_rect_new(origin_x, origin_y, view.w, cast(float32, st.buf.line_count) * line_h))

	int first = cast(int, st.scroll.offset_y / line_h)
	if (first < 0):
		first = 0
	int last = first + page_lines + 1
	if (last > st.buf.line_count):
		last = st.buf.line_count

	int sel_start = ui_textarea_sel_start(st)
	int sel_end = ui_textarea_sel_end(st)
	int has_sel = ui_textarea_has_selection(st)

	int line = first
	while (line < last):
		float32 ly = origin_y + cast(float32, line) * line_h
		int start = ui_text_buffer_line_start(&st.buf, line)
		int len = ui_text_buffer_line_length(&st.buf, line)
		char* text = &st.buf.data[start]
		# Selection highlight behind the glyph run, clipped to this
		# line's share of the selected range.
		if (has_sel):
			int from = sel_start - start
			int to = sel_end - start
			if (from < 0):
				from = 0
			if (to > len):
				to = len
			if (to > from):
				float32 hx = origin_x + cast(float32, ui_text_prefix_width(text, from, scale))
				float32 hw = cast(float32, ui_text_prefix_width(text, to, scale) - ui_text_prefix_width(text, from, scale))
				ui_render_rect(ctx.rndr, ui_rect_new(hx, ly, hw, line_h), ctx.theme.accent_hot)
		int col = 0
		float32 pen = origin_x
		while (col < len):
			pen = pen + cast(float32, ui_render_glyph(ctx.rndr, pen, ly, text[col] & 255, scale, ui_text_color(ctx)))
			col = col + 1
		line = line + 1

	if ((ctx.focus == id) && (ctx.disabled == 0)):
		int cstart = ui_text_buffer_line_start(&st.buf, st.caret_line)
		float32 cx = origin_x + cast(float32, ui_text_prefix_width(&st.buf.data[cstart], st.caret_col, scale))
		float32 cy = origin_y + cast(float32, st.caret_line) * line_h
		ui_render_rect(ctx.rndr, ui_rect_new(cx, cy, 2.0, line_h), ctx.theme.text)

	ui_scroll_end(ctx, &st.scroll)
	return changed
