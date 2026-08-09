/*
graphics.ui.widgets.menu: a context menu — a popover pinned at a point
rather than under a rect (docs/projects/ui_widgets.md §9).

	ui_menu_open_on_right_click(ctx, sidebar, &menu)
	if (ui_menu_begin(ctx, &menu)):
		if (ui_menu_item(ctx, &menu, c"New File", 1)):
			new_file()
		if (ui_menu_item(ctx, &menu, c"Rename", has_selection)):
			rename()
		ui_menu_separator(ctx, &menu)
		if (ui_menu_item(ctx, &menu, c"Delete", has_selection)):
			delete()
		ui_menu_end(ctx, &menu)

Items are a walk, so the menu's height is whatever the caller issues —
but the popover underneath needs that height when it places the
surface, one call earlier. So ui_menu_begin sizes from the PREVIOUS
frame's item count and the first frame of a newly-opened menu measures
before it settles. That is invisible in practice, because a menu opens
under the pointer, at the top-left corner it was pinned to, and only
the bottom edge moves.

Right-click reaches here through ui_input.mouse_right_pressed, a bare
per-frame edge with no held or released state: nothing drags with the
right button.
*/
import lib.lib
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


float32 ui_menu_item_height():
	return 26.0


float32 ui_menu_separator_height():
	return 9.0


struct ui_menu_state:
	int32 open
	float32 at_x           # where the menu was pinned, viewport space
	float32 at_y
	float32 w
	int32 walk_index
	int32 chosen           # item index chosen this frame, -1 = none
	# The previous frame's measured height, which is what ui_menu_begin
	# has to place the surface with.
	float32 height
	float32 pen_y
	int32 id


void ui_menu_init(ui_menu_state* st, float32 w):
	st.open = 0
	st.at_x = 0.0
	st.at_y = 0.0
	st.w = w
	st.walk_index = 0
	st.chosen = 0 - 1
	st.height = ui_menu_item_height()
	st.pen_y = 0.0
	st.id = 0


# Pin the menu at the pointer when a right-click lands inside `area`.
# The edge is consumed, so two overlapping areas cannot both open one.
# Returns 1 on the frame the menu opens.
int ui_menu_open_on_right_click(ui_context* ctx, ui_rect area, ui_menu_state* st):
	if (ctx.input.mouse_right_pressed == 0):
		return 0
	if (ctx.disabled):
		return 0
	if (ui_scope_blocked(ctx)):
		return 0
	float32 px = cast(float32, ctx.input.right_x)
	float32 py = cast(float32, ctx.input.right_y)
	if (ui_rect_contains(area, px, py) == 0):
		return 0
	ctx.input.mouse_right_pressed = 0
	st.open = 1
	st.at_x = px
	st.at_y = py
	st.walk_index = 0
	st.chosen = 0 - 1
	return 1


# Enter the menu. Returns 1 while open — issue items and call
# ui_menu_end. Returns 0 having pushed nothing, in which case
# ui_menu_end must not be called.
int ui_menu_begin(ui_context* ctx, ui_menu_state* st):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	st.id = id
	st.walk_index = 0
	st.chosen = 0 - 1
	st.pen_y = 0.0

	# A zero-height anchor at the pointer: the popover's own placement
	# then puts the surface just below it, flipping and shifting to stay
	# inside the viewport, which is exactly what a context menu wants.
	ui_rect anchor = ui_rect_new(st.at_x, st.at_y, 0.0, 0.0)
	if (ui_popover_begin(ctx, id, anchor, st.w, st.height, &st.open) == 0):
		return 0
	# Items place themselves against the surface, not the pad-inset body
	# region a popover hands out, so the highlight spans the full width.
	return 1


# One item. Returns 1 on the frame it is chosen, which also closes the
# menu — a context menu never survives its own action.
int ui_menu_item(ui_context* ctx, ui_menu_state* st, char* label, int enabled):
	int index = st.walk_index
	st.walk_index = st.walk_index + 1
	ui_layout* lo = ui_layout_top(ctx)
	float32 pad = cast(float32, ctx.theme.pad)
	ui_rect row = ui_rect_new(lo.bounds.x - pad * 0.5, lo.bounds.y + st.pen_y, st.w - pad, ui_menu_item_height())
	st.pen_y = st.pen_y + ui_menu_item_height()
	ui_region_claim(ctx, row)

	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int chosen = 0
	if (enabled):
		if (ui_click_behavior(ctx, id, row)):
			chosen = 1
			st.chosen = index
			# Closing here rather than in ui_menu_end keeps the bracket
			# balanced: the popover was entered this frame and still has
			# to be left through ui_menu_end.
			st.open = 0

	if (enabled && (ctx.hot == id)):
		ui_draw_rrect(ctx.rndr, row, cast(float32, ctx.theme.radius_small), ctx.theme.widget_hot)

	int scale = ctx.theme.text_scale
	ui_color ink = ctx.theme.text
	if (enabled == 0):
		ink = ctx.theme.disabled_text
	float32 ty = row.y + (row.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_clip_push(ctx.rndr, row)
	ui_draw_text(ctx.rndr, row.x + pad, ty, label, scale, ink)
	ui_clip_pop(ctx.rndr)
	return chosen


# A hairline between groups of items. Costs no widget id: it cannot be
# interacted with.
void ui_menu_separator(ui_context* ctx, ui_menu_state* st):
	ui_layout* lo = ui_layout_top(ctx)
	float32 pad = cast(float32, ctx.theme.pad)
	float32 y = lo.bounds.y + st.pen_y + ui_menu_separator_height() * 0.5
	st.pen_y = st.pen_y + ui_menu_separator_height()
	ui_rect line = ui_rect_new(lo.bounds.x, y, st.w - pad * 2.0, 1.0)
	ui_render_rect(ctx.rndr, line, ctx.theme.border)
	ui_region_claim(ctx, ui_rect_new(line.x, lo.bounds.y + st.pen_y - ui_menu_separator_height(), line.w, ui_menu_separator_height()))


# Leave the menu, recording the height the next frame will place with.
void ui_menu_end(ui_context* ctx, ui_menu_state* st):
	float32 measured = st.pen_y + cast(float32, ctx.theme.pad) * 2.0
	if (measured > 0.0):
		st.height = measured
	ui_popover_end(ctx)
