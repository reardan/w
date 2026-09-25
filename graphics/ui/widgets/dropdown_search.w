/*
graphics.ui.widgets.dropdown_search: a dropdown with a filter field
(docs/projects/ui_widgets.md §6, §9).

	ui_textbox_state query
	if (ui_dropdown_search(ctx, 200.0, items, n, &selected, &open, &query)):
		load(items[selected])

Opening shows a popover holding a ui_textbox at the top and, under it,
the items whose label contains the query — a case-insensitive ASCII
substring match, so "an" finds "Banana" and "ANT". Pressing a match
picks it and closes; return in the filter picks the first match. The
filter is a plain ui_textbox issued inside the popover's scope, which
is what makes the widget possible at all: the textbox is live because
its scope is the innermost open popup, while everything outside it
stays inert.

The filter takes focus on the frame the list opens and is cleared
then, so each opening starts from the full list. Its id is reserved
whether or not the list is open (the dropdown always takes two ids),
so opening and closing never shift the ids of widgets issued after it;
and when the list closes, focus the filter held is released rather
than left on an id the next widget would inherit.

The surface is sized for every item, not for the current matches, so
it does not jump as the user types; unused rows are empty space, and
an empty result shows a muted "No matches" row. The query is
caller-owned state, like the open flag.
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context
import graphics.ui.widgets.overlay
import graphics.ui.widgets.popover
import graphics.ui.widgets.textbox
import graphics.ui.widgets.dropdown_multi


int ui_ascii_lower(int c):
	if ((c >= 'A') && (c <= 'Z')):
		return c + 32
	return c


# 1 when query occurs in label, ignoring ASCII case. The empty query
# matches everything.
int ui_dropdown_matches(char* label, char* query):
	if (query[0] == 0):
		return 1
	int i = 0
	while (label[i] != 0):
		int k = 0
		while ((query[k] != 0) && (label[i + k] != 0) && (ui_ascii_lower(label[i + k]) == ui_ascii_lower(query[k]))):
			k = k + 1
		if (query[k] == 0):
			return 1
		i = i + 1
	return 0


# Index of the first item matching query, or -1.
int ui_dropdown_first_match(char** items, int item_count, char* query):
	int i = 0
	while (i < item_count):
		if (ui_dropdown_matches(items[i], query)):
			return i
		i = i + 1
	return 0 - 1


# Height of the open surface: the filter row, a gap, a row per item,
# and the popover's pad above and below.
float32 ui_dropdown_search_list_height(ui_context* ctx, int item_count):
	int rows = item_count
	if (rows < 1):
		rows = 1
	return cast(float32, ctx.theme.widget_height * (rows + 1) + ctx.theme.gap + ctx.theme.pad * 2)


# A searchable single-select dropdown over caller-owned selected, open
# and query. Returns 1 on the frame the selection changes.
int ui_dropdown_search(ui_context* ctx, float32 w, char** items, int item_count, int32* selected, int32* open, ui_textbox_state* query):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	float32 row_h = cast(float32, ctx.theme.widget_height)
	ui_rect r = ui_layout_next(ctx, w, row_h)
	int changed = 0
	int opened = 0

	if (open[0] == 0):
		if (ui_click_behavior(ctx, id, r)):
			open[0] = 1
			opened = 1
			ui_textbox_init(query)
			# As in ui_dropdown_multi: the opening press lies outside the
			# surface and must not close it on the frame it opened.
			ctx.input.mouse_pressed = 0
	else:
		ctx.hot = id

	# The filter's id, reserved open or closed.
	int filter_id = ctx.next_id
	int pick = 0 - 1
	if (ui_popover_begin(ctx, id, r, r.w, ui_dropdown_search_list_height(ctx, item_count), open)):
		if (opened):
			ctx.focus = filter_id
		ui_layout* lo = ui_layout_top(ctx)
		float32 inner_w = lo.bounds.w
		int submitted = ui_textbox(ctx, inner_w, query)
		# Rows sit flush under the filter, one row pitch apart.
		float32 y = lo.cursor_y
		int shown = 0
		int i = 0
		while (i < item_count):
			if (ui_dropdown_matches(items[i], &query.text[0])):
				ui_rect row = ui_rect_new(lo.bounds.x, y, inner_w, row_h)
				if (ctx.input.mouse_pressed && ui_rect_contains(row, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
					pick = i
				if (ui_rect_contains(row, cast(float32, ctx.input.mouse_x), cast(float32, ctx.input.mouse_y))):
					ui_draw_rrect(ctx.rndr, row, cast(float32, ctx.theme.radius_small), ctx.theme.widget_hot)
				if (i == selected[0]):
					ui_draw_rrect(ctx.rndr, ui_rect_new(row.x + 3.0, row.y + 7.0, 4.0, row.h - 14.0), 2.0, ctx.theme.accent)
				ui_draw_text(ctx.rndr, row.x + cast(float32, ctx.theme.pad + 4), row.y + (row.h - cast(float32, ui_text_height(scale))) * 0.5, items[i], scale, ctx.theme.text)
				ui_region_claim(ctx, row)
				y = y + row_h
				shown = shown + 1
			i = i + 1
		if (shown == 0):
			ui_rect none = ui_rect_new(lo.bounds.x, y, inner_w, row_h)
			ui_draw_text(ctx.rndr, none.x + cast(float32, ctx.theme.pad + 4), none.y + (none.h - cast(float32, ui_text_height(scale))) * 0.5, c"No matches", scale, ctx.theme.text_muted)
		if (submitted && (pick < 0)):
			pick = ui_dropdown_first_match(items, item_count, &query.text[0])
		ui_popover_end(ctx)
		if (pick >= 0):
			if (selected[0] != pick):
				selected[0] = pick
				changed = 1
			open[0] = 0
			ui_popup_dismiss(ctx, id)
			# The picking press is spent: widgets after this call are
			# live again this frame and must not also act on it.
			ctx.input.mouse_pressed = 0
	else:
		ctx.next_id = ctx.next_id + 1
	if ((open[0] == 0) && (ctx.focus == filter_id)):
		ctx.focus = 0

	char* text = c""
	if ((selected[0] >= 0) && (selected[0] < item_count)):
		text = items[selected[0]]
	ui_dropdown_draw_header(ctx, id, r, text, ui_text_color(ctx))
	return changed
