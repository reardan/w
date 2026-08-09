/*
graphics.ui.widgets.layout: the layout cursor — a vertical stack where
each widget claims the next row, with ui_same_line placing the next one
to the right instead (docs/projects/ui_widgets.md §3).

The cursor lives on a stack of regions rather than loose on the
context. ui_begin seeds the root region with the whole window, so the
plain stack is the depth-1 case; ui_region_push nests a sub-area, and
every widget between it and ui_region_pop places itself inside that
area, measuring its extent on the way out. Modal bodies, tab content,
table cells and a scrolled viewport are all that one mechanism.
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.widgets.state


# The region widgets are currently placing themselves in.
ui_layout* ui_layout_top(ui_context* ctx):
	return &ctx.layout_stack[ctx.layout_depth - 1]


# Reset one region to place its first widget at the area's top-left.
void ui_layout_reset(ui_layout* lo, ui_rect area):
	lo.bounds = area
	lo.cursor_x = area.x
	lo.cursor_y = area.y
	lo.origin_x = area.x
	lo.last_right = area.x
	lo.last_top = area.y
	lo.content_w = 0.0
	lo.content_h = 0.0
	lo.pending_same_line = 0


# Place subsequent widgets inside area, in its own coordinate space.
# A push past ui_layout_max_depth is dropped; ui_region_pop refuses to
# pop the root, so a dropped push and its matching pop still balance.
void ui_region_push(ui_context* ctx, ui_rect area):
	if (ctx.layout_depth >= ui_layout_max_depth()):
		return
	ui_layout_reset(&ctx.layout_stack[ctx.layout_depth], area)
	ctx.layout_depth = ctx.layout_depth + 1


void ui_region_pop(ui_context* ctx):
	if (ctx.layout_depth <= 1):
		return
	ctx.layout_depth = ctx.layout_depth - 1


# How much of the current region the widgets placed in it actually
# covered, as a rect at the region's origin. Scroll reads this to know
# whether its content overflows the viewport.
ui_rect ui_region_content(ui_context* ctx):
	ui_layout* lo = ui_layout_top(ctx)
	return ui_rect_new(lo.bounds.x, lo.bounds.y, lo.content_w, lo.content_h)


# Place the next widget on the same row as the previous one.
void ui_same_line(ui_context* ctx):
	ui_layout* lo = ui_layout_top(ctx)
	lo.pending_same_line = 1


# Claim the next layout rect: the stack cursor position, or to the
# right of the previous widget after ui_same_line.
ui_rect ui_layout_next(ui_context* ctx, float32 w, float32 h):
	ui_layout* lo = ui_layout_top(ctx)
	float32 x = lo.cursor_x
	float32 y = lo.cursor_y
	if (lo.pending_same_line):
		lo.pending_same_line = 0
		x = lo.last_right + cast(float32, ctx.theme.gap)
		y = lo.last_top
	ui_rect r = ui_rect_new(x, y, w, h)
	lo.last_right = r.x + r.w
	lo.last_top = r.y
	lo.cursor_x = lo.origin_x
	lo.cursor_y = r.y + r.h + cast(float32, ctx.theme.gap)
	# Measured from the region's origin, so a caller can size a
	# scrollable viewport from what was placed in it.
	float32 right = r.x + r.w - lo.bounds.x
	if (right > lo.content_w):
		lo.content_w = right
	float32 bottom = r.y + r.h - lo.bounds.y
	if (bottom > lo.content_h):
		lo.content_h = bottom
	return r
