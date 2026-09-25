/*
graphics.ui.widgets.dropdown_multi: a dropdown that picks any number of
items (docs/projects/ui_widgets.md §6, §9).

	int32[4] checked
	int32 open = 0
	if (ui_dropdown_multi(ctx, 200.0, items, 4, &checked[0], &open)):
		apply_filter(&checked[0])

Built on ui_popover_begin rather than on ui_dropdown's hand-rolled list:
the popover already owns the popup registration, placement, elevation
and the ways it closes (a press outside, escape), which is exactly what
a multi-select needs — the list has to stay open while items are
toggled, which is the one thing ui_dropdown's pick-and-close list
cannot do.

checked is a caller-owned 0/1 array, one entry per item, like a
checkbox's value times item_count. Pressing a row toggles its entry and
leaves the list open; the press is consumed so nothing else acts on it.
The header summarises the selection: the first checked item, then
"+N" for the rest, or a muted placeholder when nothing is checked.
Returns 1 on each frame the checked set changes.
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


# The header text when nothing is checked.
char* ui_dropdown_multi_placeholder():
	return c"Select..."


# Append s to out at *len, keeping out NUL-terminated and never writing
# past cap bytes (including the NUL). Truncation is at a byte, which a
# fitted draw then trims to whole glyphs.
void ui_dropdown_append(char* out, int cap, int32* len, char* s):
	int i = 0
	while ((s[i] != 0) && (len[0] + 1 < cap)):
		out[len[0]] = s[i]
		len[0] = len[0] + 1
		i = i + 1
	out[len[0]] = 0


# Write the header summary into out (cap bytes): the first checked
# item's label, then " +N" when N more are checked; the empty string
# when none are. Returns how many items are checked.
int ui_dropdown_multi_summary(char* out, int cap, char** items, int item_count, int32* checked):
	int32 len = 0
	out[0] = 0
	int count = 0
	int i = 0
	while (i < item_count):
		if (checked[i]):
			if (count == 0):
				ui_dropdown_append(out, cap, &len, items[i])
			count = count + 1
		i = i + 1
	if (count > 1):
		char[16] digits
		int n = count - 1
		int d = 15
		digits[d] = 0
		while (n > 0):
			d = d - 1
			digits[d] = '0' + n % 10
			n = n / 10
		ui_dropdown_append(out, cap, &len, c" +")
		ui_dropdown_append(out, cap, &len, &digits[d])
	return count


# A dropdown header: the tonal field, text fitted to the space left of
# the chevron, the chevron. Shared by the dropdown variants.
void ui_dropdown_draw_header(ui_context* ctx, int id, ui_rect r, char* text, ui_color color):
	int scale = ctx.theme.text_scale
	float32 pad = cast(float32, ctx.theme.pad)
	float32 chev = 12.0
	ui_draw_rrect(ctx.rndr, r, cast(float32, ctx.theme.radius), ui_widget_fill(ctx, id))
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	int fit_w = cast(int, r.w - pad * 3.0 - chev)
	int shown = ui_text_fit_strike(text, ui_font_strike_from_scale(scale), fit_w)
	ui_draw_text_n(ctx.rndr, r.x + pad, ty, text, shown, scale, color)
	ui_draw_chevron(ctx.rndr, ui_rect_new(r.x + r.w - pad - chev, r.y + (r.h - chev) * 0.5, chev, chev), ctx.theme.text_muted)


# One checkbox-marked row of a multi-select list.
void ui_dropdown_multi_row(ui_context* ctx, ui_rect row, char* label, int on):
	int scale = ctx.theme.text_scale
	if (ui_rect_contains(row, cast(float32, ctx.input.mouse_x), cast(float32, ctx.input.mouse_y))):
		ui_draw_rrect(ctx.rndr, row, cast(float32, ctx.theme.radius_small), ctx.theme.widget_hot)
	float32 box = cast(float32, ctx.theme.unit * 2)
	float32 bx = row.x + 4.0
	ui_rect box_rect = ui_rect_new(bx, row.y + (row.h - box) * 0.5, box, box)
	float32 rad = cast(float32, ctx.theme.radius_small)
	if (on):
		ui_draw_rrect(ctx.rndr, box_rect, rad, ctx.theme.accent)
		ui_draw_check(ctx.rndr, ui_rect_inset(box_rect, 1.0), ctx.theme.on_accent)
	else:
		ui_draw_rrect(ctx.rndr, box_rect, rad, ctx.theme.border)
		ui_draw_rrect(ctx.rndr, ui_rect_inset(box_rect, 2.0), rad - 2.0, ctx.theme.surface)
	float32 tx = bx + box + cast(float32, ctx.theme.gap)
	ui_draw_text(ctx.rndr, tx, row.y + (row.h - cast(float32, ui_text_height(scale))) * 0.5, label, scale, ctx.theme.text)


# Height of the open list's surface for item_count rows: the rows plus
# the popover's pad above and below.
float32 ui_dropdown_multi_list_height(ui_context* ctx, int item_count):
	return cast(float32, ctx.theme.widget_height * item_count + ctx.theme.pad * 2)


# A multi-select dropdown over caller-owned checked (item_count 0/1
# entries) and open. Returns 1 on each frame the checked set changes.
int ui_dropdown_multi(ui_context* ctx, float32 w, char** items, int item_count, int32* checked, int32* open):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	float32 row_h = cast(float32, ctx.theme.widget_height)
	ui_rect r = ui_layout_next(ctx, w, row_h)
	int changed = 0

	if (open[0] == 0):
		if (ui_click_behavior(ctx, id, r)):
			open[0] = 1
			# The opening click's press lies outside the surface; left in
			# place, the popover would read it as a press-away and close
			# on the frame it opened.
			ctx.input.mouse_pressed = 0
	else:
		ctx.hot = id

	if (ui_popover_begin(ctx, id, r, r.w, ui_dropdown_multi_list_height(ctx, item_count), open)):
		ui_rect body = ui_layout_top(ctx).bounds
		int i = 0
		while (i < item_count):
			ui_rect row = ui_rect_new(body.x, body.y + row_h * cast(float32, i), body.w, row_h)
			if (ctx.input.mouse_pressed && ui_rect_contains(row, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
				checked[i] = 1 - checked[i]
				changed = 1
				ctx.input.mouse_pressed = 0
			ui_dropdown_multi_row(ctx, row, items[i], checked[i])
			ui_region_claim(ctx, row)
			i = i + 1
		ui_popover_end(ctx)

	# The header draws after the list so it summarises this frame's
	# toggles, not last frame's; it is on the base layer either way.
	char[128] summary
	int count = ui_dropdown_multi_summary(&summary[0], 128, items, item_count, checked)
	if (count == 0):
		ui_dropdown_draw_header(ctx, id, r, ui_dropdown_multi_placeholder(), ctx.theme.text_muted)
	else:
		ui_dropdown_draw_header(ctx, id, r, &summary[0], ui_text_color(ctx))
	return changed
