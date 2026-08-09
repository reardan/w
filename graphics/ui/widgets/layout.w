/*
graphics.ui.widgets.layout: the layout cursor — a vertical stack where
each widget claims the next row, with ui_same_line placing the next one
to the right instead (docs/projects/ui_widgets.md §3).
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.widgets.state


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
