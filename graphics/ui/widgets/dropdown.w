/*
graphics.ui.widgets.dropdown: the collapsed-list selector, the widget
set's one popup (docs/projects/ui_widgets.md §3).
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context


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

	# Header: a rounded tonal field with the selection and a chevron.
	ui_draw_rrect(ctx.rndr, r, cast(float32, ctx.theme.radius), ui_widget_fill(ctx, id))
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	if ((selected[0] >= 0) && (selected[0] < item_count)):
		ui_draw_text(ctx.rndr, r.x + cast(float32, ctx.theme.pad), ty, items[selected[0]], scale, ui_text_color(ctx))
	float32 chev = 12.0
	ui_draw_chevron(ctx.rndr, ui_rect_new(r.x + r.w - cast(float32, ctx.theme.pad) - chev, r.y + (r.h - chev) * 0.5, chev, chev), ctx.theme.text_muted)

	if (open[0]):
		# The open menu: an elevated rounded surface (shadow first, all
		# through the overlay batch so it paints above later widgets).
		ui_rect list_rect = ui_rect_new(r.x, r.y + r.h, r.w, row_h * cast(float32, item_count))
		ctx.rndr.to_overlay = 1
		ui_draw_shadow(ctx.rndr, list_rect, ctx.theme.shadow)
		ui_draw_rrect(ctx.rndr, list_rect, cast(float32, ctx.theme.radius), ctx.theme.surface)
		int i = 0
		while (i < item_count):
			ui_rect row = ui_rect_new(list_rect.x, list_rect.y + row_h * cast(float32, i), list_rect.w, row_h)
			if (ui_rect_contains(row, cast(float32, ctx.input.mouse_x), cast(float32, ctx.input.mouse_y))):
				ui_draw_rrect(ctx.rndr, ui_rect_inset(row, 2.0), cast(float32, ctx.theme.radius_small), ctx.theme.widget_hot)
			if (i == selected[0]):
				ui_draw_rrect(ctx.rndr, ui_rect_new(row.x + 3.0, row.y + 7.0, 4.0, row.h - 14.0), 2.0, ctx.theme.accent)
			ui_draw_text(ctx.rndr, row.x + cast(float32, ctx.theme.pad + 4), row.y + (row.h - cast(float32, ui_text_height(scale))) * 0.5, items[i], scale, ctx.theme.text)
			i = i + 1
		ctx.rndr.to_overlay = 0
	return changed
