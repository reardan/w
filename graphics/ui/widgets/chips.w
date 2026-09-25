/*
graphics.ui.widgets.chips: compact pills that flow left to right and
wrap onto a new row at the area's edge — filter chips that toggle, and
input chips with a remove cross (docs/projects/ui_widgets.md §2, §6).

	ui_chips_begin(ctx, &st, area)
	int i = 0
	while (i < tag_count):
		if (ui_chip_removable(ctx, &st, tag_name(i), 0)): remove_after_walk = i
		i = i + 1
	ui_chip(ctx, &st, c"Open only", &open_only)
	ui_chips_end(ctx, &st)

A walk, like the tab strip's. Only area's x, y and w place the chips:
the rows grow downwards as far as they need, and ui_chips_end claims
the extent they covered on the enclosing region, so a scroll region
around the row sizes itself correctly. A caller stacking chips in the
layout flow can size the slot from last frame's measurement —
ui_layout_next(ctx, w, st.height) — the one-frame lag the tree and
scroll regions already document.

Chip width is text-derived and does not change with selection: a filter
chip always reserves its leading check-mark slot, so toggling a chip
never re-wraps the rows under the pointer. A chip wider than the whole
area is capped at it and its label clipped.

The remove cross is hit-tested as its own sub-rect with its own id and
consumes the press, so removing a chip never also toggles it — even
when the press and release arrive in different frames. Every chip takes
two ids whether or not it is removable, so turning a chip into an input
chip, or wrapping it onto another row, shifts no widget issued after it.
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context


# Side of the leading check mark and of the trailing remove cross.
float32 ui_chip_mark_size():
	return 12.0


struct ui_chips_state:
	ui_rect area
	float32 pen_x          # next chip's left edge, from area.x
	float32 pen_y          # current row's top, from area.y
	float32 content_w      # widest row so far, from area.x
	float32 height         # rows covered by the last complete walk
	int32 rows             # rows the last complete walk used
	int32 row              # the row being filled, from 0
	int32 walk_index


void ui_chips_init(ui_chips_state* st):
	st.area = ui_rect_new(0.0, 0.0, 0.0, 0.0)
	st.pen_x = 0.0
	st.pen_y = 0.0
	st.content_w = 0.0
	st.height = 0.0
	st.rows = 0
	st.row = 0
	st.walk_index = 0


# Start a walk of chips flowing across area.
void ui_chips_begin(ui_context* ctx, ui_chips_state* st, ui_rect area):
	st.area = area
	st.pen_x = 0.0
	st.pen_y = 0.0
	st.content_w = 0.0
	st.row = 0
	st.walk_index = 0


# Finish the walk: record how tall the rows came out and claim that
# extent on the enclosing region.
void ui_chips_end(ui_context* ctx, ui_chips_state* st):
	if (st.walk_index == 0):
		st.height = 0.0
		st.rows = 0
		return
	st.height = st.pen_y + cast(float32, ctx.theme.widget_height)
	st.rows = st.row + 1
	ui_region_claim(ctx, ui_rect_new(st.area.x, st.area.y, st.content_w, st.height))


# A chip's width: its label between two pads, plus the check slot a
# selectable chip reserves and the cross a removable one carries.
float32 ui_chip_width(ui_context* ctx, char* label, int selectable, int removable):
	float32 pad = cast(float32, ctx.theme.pad)
	float32 w = cast(float32, ui_text_width(label, ctx.theme.text_scale)) + pad * 2.0
	if (selectable): w = w + ui_chip_mark_size() + pad * 0.5
	if (removable): w = w + ui_chip_mark_size() + pad * 0.5
	return w


# Place the next chip, wrapping to a new row when it would overflow the
# area. The first chip of a row never wraps, so an over-wide chip takes
# a row of its own (capped to the area) instead of an endless run of
# empty rows.
ui_rect ui_chip_place(ui_context* ctx, ui_chips_state* st, float32 w):
	float32 gap = cast(float32, ctx.theme.gap)
	float32 h = cast(float32, ctx.theme.widget_height)
	if (w > st.area.w): w = st.area.w
	if ((st.pen_x > 0.0) && (st.pen_x + w > st.area.w)):
		st.pen_x = 0.0
		st.pen_y = st.pen_y + h + gap
		st.row = st.row + 1
	ui_rect r = ui_rect_new(st.area.x + st.pen_x, st.area.y + st.pen_y, w, h)
	st.pen_x = st.pen_x + w + gap
	if (st.pen_x - gap > st.content_w): st.content_w = st.pen_x - gap
	return r


# The shared chip. selected may be 0 for a chip that does not toggle.
# Returns 1 when the body toggled selected, 2 when the cross was
# clicked, 0 otherwise.
int ui_chip_walk(ui_context* ctx, ui_chips_state* st, char* label, int32* selected, int removable):
	st.walk_index = st.walk_index + 1
	# Two ids per chip, removable or not, so no later widget shifts.
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int remove_id = ctx.next_id
	ctx.next_id = ctx.next_id + 1

	int selectable = 0
	if (selected != 0): selectable = 1
	float32 pad = cast(float32, ctx.theme.pad)
	float32 mark = ui_chip_mark_size()
	ui_rect chip = ui_chip_place(ctx, st, ui_chip_width(ctx, label, selectable, removable))
	ui_rect cross = ui_rect_new(chip.x + chip.w - pad - mark, chip.y + (chip.h - mark) * 0.5, mark, mark)

	# The cross first: it consumes the click, so removing never toggles.
	int result = 0
	if (removable):
		if (ui_click_behavior(ctx, remove_id, cross)): result = 2
	if (result == 0):
		int clicked = ui_click_behavior(ctx, id, chip)
		if (removable):
			# The cross lies inside the chip, so the body just re-claimed
			# a press (and the hover) that belonged to the cross. Hand
			# them back, or a press on the cross released a frame later
			# would toggle the chip instead of removing it.
			if (ctx.input.mouse_pressed && (ctx.active == id) && ui_rect_contains(cross, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
				ctx.active = remove_id
				clicked = 0
			if ((ctx.hot == id) && ui_rect_contains(cross, cast(float32, ctx.input.mouse_x), cast(float32, ctx.input.mouse_y))):
				ctx.hot = remove_id
		if (clicked && selectable):
			if (selected[0]): selected[0] = 0
			else: selected[0] = 1
			result = 1

	int on = 0
	if (selectable): on = selected[0]
	ui_color fill = ui_widget_fill(ctx, id)
	ui_color ink = ui_text_color(ctx)
	ui_color cross_ink = ctx.theme.text_muted
	if (ctx.disabled): cross_ink = ctx.theme.disabled_text
	else if (on):
		fill = ctx.theme.accent
		if ((ctx.hot == id) || (ctx.active == id)): fill = ctx.theme.accent_hot
		ink = ctx.theme.on_accent
		cross_ink = ctx.theme.on_accent
	else if (ctx.hot == remove_id): cross_ink = ctx.theme.text
	ui_draw_rrect(ctx.rndr, chip, chip.h * 0.5, fill)

	# The label column: between the check slot and the cross. An
	# unselected filter chip centres its label in the column, a selected
	# one draws the check in the slot and the label after it.
	int scale = ctx.theme.text_scale
	float32 col_x = chip.x + pad
	float32 col_w = chip.w - pad * 2.0
	if (removable): col_w = col_w - mark - pad * 0.5
	float32 tw = cast(float32, ui_text_width(label, scale))
	float32 tx = col_x + (col_w - tw) * 0.5
	if (on):
		ui_draw_check(ctx.rndr, ui_rect_new(col_x, chip.y + (chip.h - mark) * 0.5, mark, mark), ink)
		tx = col_x + mark + pad * 0.5
	if (tx < col_x): tx = col_x
	float32 ty = chip.y + (chip.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_clip_push(ctx.rndr, ui_rect_new(col_x, chip.y, col_w, chip.h))
	ui_draw_text(ctx.rndr, tx, ty, label, scale, ink)
	ui_clip_pop(ctx.rndr)

	if (removable): ui_draw_cross(ctx.rndr, cross, cross_ink)
	return result


# A filter chip. Toggles selected[0] when clicked and returns 1 on that
# frame; selected chips fill with the accent and show a check.
int ui_chip(ui_context* ctx, ui_chips_state* st, char* label, int32* selected):
	if (ui_chip_walk(ctx, st, label, selected, 0) == 1): return 1
	return 0


# An input chip with a remove cross. Returns 1 on the frame the cross is
# clicked; the caller drops the item after the walk. selected may be 0
# for a plain tag, or point at a flag to make the chip toggle as well —
# a click on the cross never toggles it.
int ui_chip_removable(ui_context* ctx, ui_chips_state* st, char* label, int32* selected):
	if (ui_chip_walk(ctx, st, label, selected, 1) == 2): return 1
	return 0
