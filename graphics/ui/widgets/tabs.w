/*
graphics.ui.widgets.tabs: the strip of open documents across the top of
an editor pane (docs/projects/ui_widgets.md §9).

	ui_tabs_begin(ctx, strip, &st, &active)
	int i = 0
	while (i < doc_count):
		ui_tab(ctx, &st, doc_name(i), 1)
		i = i + 1
	int closed = ui_tabs_end(ctx, &st)
	if (closed >= 0):
		close_document(closed)

A walk, like the tree's: ui_tab returns 1 on the frame its tab is
selected and writes active[0] itself, so the caller usually ignores the
return and just reads its own variable. ui_tabs_end reports a close
instead of ui_tab doing it, because closing changes the caller's list
and that is better done after the walk than during it.

Closing never also selects: the close affordance is hit-tested as its
own sub-rect and consumes the click. Tab widths are text-derived with a
cap, and each tab is clipped to its own rect, so a long filename
truncates instead of spilling into its neighbour.
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
import graphics.ui.widgets.scroll


# Widest a tab may grow before its label starts truncating.
float32 ui_tab_max_width():
	return 160.0


float32 ui_tab_min_width():
	return 56.0


# Side of the square close affordance.
float32 ui_tab_close_size():
	return 12.0


struct ui_tab_state:
	# Horizontal scroll, in pixels, when the strip is wider than its area.
	float32 offset_x
	int32 closed           # index closed this frame, -1 = none
	int32 walk_index
	float32 pen_x          # next tab's left edge, in strip space
	float32 content_w      # total width of the walk, for clamping
	ui_rect strip
	int32* active          # the caller's selected-tab index, held for the walk


void ui_tab_init(ui_tab_state* st):
	st.offset_x = 0.0
	st.closed = 0 - 1
	st.walk_index = 0
	st.pen_x = 0.0
	st.content_w = 0.0
	st.active = 0


# Open the strip: draw its base and start the walk.
void ui_tabs_begin(ui_context* ctx, ui_rect area, ui_tab_state* st, int32* active):
	st.strip = area
	st.active = active
	st.closed = 0 - 1
	st.walk_index = 0
	st.pen_x = 0.0

	ui_render_rect(ctx.rndr, area, ctx.theme.widget)
	# A hairline under the strip, the separator the table header uses.
	ui_render_rect(ctx.rndr, ui_rect_new(area.x, area.y + area.h - 1.0, area.w, 1.0), ctx.theme.border)

	# The wheel scrolls the strip when it overflows. Claimed, so one
	# notch never also scrolls whatever is underneath.
	if (ctx.input.scroll_y != 0):
		if (ui_rect_contains(area, cast(float32, ctx.input.scroll_at_x), cast(float32, ctx.input.scroll_at_y))):
			if (st.content_w > area.w):
				st.offset_x = st.offset_x - cast(float32, ctx.input.scroll_y * ui_scroll_notch())
				ctx.input.scroll_y = 0
	ui_clip_push(ctx.rndr, area)


float32 ui_tab_width(ui_context* ctx, char* label, int closable):
	float32 w = cast(float32, ui_text_width(label, ctx.theme.text_scale))
	w = w + cast(float32, ctx.theme.pad) * 2.0
	if (closable):
		w = w + ui_tab_close_size() + cast(float32, ctx.theme.pad)
	if (w < ui_tab_min_width()):
		w = ui_tab_min_width()
	if (w > ui_tab_max_width()):
		w = ui_tab_max_width()
	return w


# One tab. Returns 1 on the frame it becomes the active tab.
int ui_tab(ui_context* ctx, ui_tab_state* st, char* label, int closable):
	int index = st.walk_index
	st.walk_index = st.walk_index + 1
	float32 w = ui_tab_width(ctx, label, closable)
	ui_rect tab = ui_rect_new(st.strip.x + st.pen_x - st.offset_x, st.strip.y, w, st.strip.h)
	st.pen_x = st.pen_x + w

	# Ids are taken for every tab, on screen or not, so a widget issued
	# after the strip does not shift as the strip scrolls — the same
	# bargain the tree's rows make.
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int close_id = ctx.next_id
	ctx.next_id = ctx.next_id + 1

	if (tab.x + tab.w <= st.strip.x):
		return 0
	if (tab.x >= st.strip.x + st.strip.w):
		return 0

	# The close affordance is hit-tested first and consumes the press, so
	# closing a tab can never also select it.
	ui_rect close = ui_rect_new(tab.x + tab.w - ui_tab_close_size() - cast(float32, ctx.theme.pad) * 0.5, tab.y + (tab.h - ui_tab_close_size()) * 0.5, ui_tab_close_size(), ui_tab_close_size())
	int close_hit = 0
	if (closable):
		if (ui_click_behavior(ctx, close_id, close)):
			st.closed = index
			close_hit = 1

	int became_active = 0
	if (close_hit == 0):
		if (ui_click_behavior(ctx, id, tab)):
			if (st.active != 0):
				if (st.active[0] != index):
					st.active[0] = index
					became_active = 1

	int selected = 0
	if (st.active != 0):
		if (st.active[0] == index):
			selected = 1

	ui_clip_push(ctx.rndr, tab)
	if (selected):
		# The active tab reads as part of the pane below it: the surface
		# colour, with an accent underline tying it to the content.
		ui_render_rect(ctx.rndr, tab, ctx.theme.surface)
		ui_render_rect(ctx.rndr, ui_rect_new(tab.x, tab.y + tab.h - 2.0, tab.w, 2.0), ctx.theme.accent)
	else if (ctx.hot == id):
		ui_render_rect(ctx.rndr, tab, ctx.theme.widget_hot)
	# A hairline between tabs, so adjacent inactive tabs are separable.
	ui_render_rect(ctx.rndr, ui_rect_new(tab.x + tab.w - 1.0, tab.y + 4.0, 1.0, tab.h - 8.0), ctx.theme.border)

	int scale = ctx.theme.text_scale
	ui_color ink = ctx.theme.text_muted
	if (selected):
		ink = ui_text_color(ctx)
	float32 ty = tab.y + (tab.h - cast(float32, ui_text_height(scale))) * 0.5
	# Clipped to the label's own column so a long name cannot run under
	# the close affordance.
	float32 label_w = tab.w - cast(float32, ctx.theme.pad) * 2.0
	if (closable):
		label_w = label_w - ui_tab_close_size()
	ui_clip_push(ctx.rndr, ui_rect_new(tab.x + cast(float32, ctx.theme.pad), tab.y, label_w, tab.h))
	ui_draw_text(ctx.rndr, tab.x + cast(float32, ctx.theme.pad), ty, label, scale, ink)
	ui_clip_pop(ctx.rndr)

	if (closable):
		# Brightens on its own hover, not the tab's, so it is obvious
		# which of the two a click is about to hit.
		ui_color mark = ctx.theme.text_muted
		if (ctx.hot == close_id):
			mark = ui_text_color(ctx)
		ui_draw_cross(ctx.rndr, close, mark)
	ui_clip_pop(ctx.rndr)
	return became_active


# Close the strip. Returns the index whose close affordance was clicked
# this frame, or -1.
int ui_tabs_end(ui_context* ctx, ui_tab_state* st):
	st.content_w = st.pen_x
	# Clamp after the walk, when the total width is finally known.
	float32 max = st.content_w - st.strip.w
	if (max < 0.0):
		max = 0.0
	if (st.offset_x > max):
		st.offset_x = max
	if (st.offset_x < 0.0):
		st.offset_x = 0.0
	ui_clip_pop(ctx.rndr)
	ui_region_claim(ctx, st.strip)
	return st.closed
