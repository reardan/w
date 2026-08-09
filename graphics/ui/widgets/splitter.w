/*
graphics.ui.widgets.splitter: a draggable divider that cuts a rect into
two panes (docs/projects/ui_widgets.md §9). The thing a sidebar needs
to stop being a fixed-width sidebar, and what every pane layout in the
editor shell is built out of.

	ui_split(ctx, area, 1, &st, &sidebar, &editor)
	ui_tree_begin(ctx, sidebar, &tree)
	...

Not a begin/end bracket: it hands back two rects and the caller fills
them however it likes, which composes with regions, scroll viewports
and popups without any of them knowing about it. Nesting is just
calling it again on one of the rects it returned.

`vertical` names the divider, not the split: a vertical divider puts
pane a left of pane b, a horizontal one puts a above b.
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context


# Grab width of the divider. Wider than the hairline it draws, because
# a 1px drag target is a 1px drag target.
float32 ui_split_handle():
	return 6.0


struct ui_split_state:
	# Divider offset from the area's left (vertical) or top edge.
	float32 pos
	# Smallest either pane may become. 0 takes a theme-derived default,
	# so the common case needs no setup.
	float32 min_a
	float32 min_b
	int32 drag_id
	float32 drag_grab


void ui_split_init(ui_split_state* st, float32 pos):
	st.pos = pos
	st.min_a = 0.0
	st.min_b = 0.0
	st.drag_id = 0
	st.drag_grab = 0.0


float32 ui_split_min(ui_context* ctx, float32 configured):
	if (configured > 0.0):
		return configured
	return cast(float32, ctx.theme.widget_height) * 2.0


# Cut area in two, draw and drive the divider, and write the pane rects
# through a and b. pos is clamped every frame rather than only on drag,
# so shrinking the window can never strand the divider outside it.
void ui_split(ui_context* ctx, ui_rect area, int vertical, ui_split_state* st, ui_rect* a, ui_rect* b):
	float32 handle = ui_split_handle()
	float32 extent = area.h
	if (vertical):
		extent = area.w

	float32 min_a = ui_split_min(ctx, st.min_a)
	float32 min_b = ui_split_min(ctx, st.min_b)
	# The divider can never leave the area, whatever the minimums ask
	# for: this is the only bound that is always satisfiable, so every
	# other one is taken against it.
	float32 limit = extent - handle
	if (limit < 0.0):
		limit = 0.0
	float32 max_pos = extent - min_b - handle
	if (max_pos > limit):
		max_pos = limit
	float32 min_pos = min_a
	if (min_pos > limit):
		min_pos = limit
	# An area too small to honour both minimums leaves max_pos below
	# min_pos — an inverted range, which a naive clamp turns into a
	# negative pane width. Resolve it towards pane a: it ends up cramped
	# and b collapses to nothing, but neither is nonsensical.
	if (max_pos < min_pos):
		max_pos = min_pos
	if (st.pos < min_pos):
		st.pos = min_pos
	if (st.pos > max_pos):
		st.pos = max_pos

	ui_rect divider = ui_rect_new(area.x + st.pos, area.y, handle, area.h)
	if (vertical == 0):
		divider = ui_rect_new(area.x, area.y + st.pos, area.w, handle)

	# One id per splitter, taken unconditionally — the whole point of
	# the round-2 scroll fix is that a widget's id cost must not depend
	# on its state.
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	if (ctx.disabled == 0):
		if (ui_scope_blocked(ctx) == 0):
			if (ctx.input.mouse_pressed):
				if (ui_rect_contains(divider, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
					st.drag_id = id
					# Remember where inside the handle the press landed, so
					# the divider does not jump to centre itself under the
					# pointer on the first frame of a drag.
					if (vertical):
						st.drag_grab = cast(float32, ctx.input.press_x) - divider.x
					else:
						st.drag_grab = cast(float32, ctx.input.press_y) - divider.y
			if (st.drag_id == id):
				if (ctx.input.mouse_down):
					float32 want = cast(float32, ctx.input.mouse_y) - area.y - st.drag_grab
					if (vertical):
						want = cast(float32, ctx.input.mouse_x) - area.x - st.drag_grab
					if (want < min_pos):
						want = min_pos
					if (want > max_pos):
						want = max_pos
					st.pos = want
					divider = ui_rect_new(area.x + st.pos, area.y, handle, area.h)
					if (vertical == 0):
						divider = ui_rect_new(area.x, area.y + st.pos, area.w, handle)
				else:
					st.drag_id = 0

	# A hairline down the middle of the grab area: the divider reads as
	# a seam, not as a widget, until you are dragging it.
	ui_color line = ctx.theme.border
	if (st.drag_id == id):
		line = ctx.theme.text_muted
	else if (ctx.disabled):
		line = ctx.theme.disabled_widget
	if (vertical):
		ui_render_rect(ctx.rndr, ui_rect_new(divider.x + handle * 0.5 - 0.5, divider.y, 1.0, divider.h), line)
	else:
		ui_render_rect(ctx.rndr, ui_rect_new(divider.x, divider.y + handle * 0.5 - 0.5, divider.w, 1.0), line)

	# The panes exclude the whole handle, so nothing a caller draws can
	# sit under the divider and become undraggable.
	if (vertical):
		a[0] = ui_rect_new(area.x, area.y, st.pos, area.h)
		b[0] = ui_rect_new(area.x + st.pos + handle, area.y, area.w - st.pos - handle, area.h)
	else:
		a[0] = ui_rect_new(area.x, area.y, area.w, st.pos)
		b[0] = ui_rect_new(area.x, area.y + st.pos + handle, area.w, area.h - st.pos - handle)
	# Placed geometry, so an enclosing scroll region still measures it.
	ui_region_claim(ctx, area)
