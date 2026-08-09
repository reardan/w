/*
graphics.ui.widgets.scroll: a scrollable viewport — a clip, a shifted
layout region, a wheel claim and a thumb (docs/projects/ui_widgets.md
§4). Everything that shows more content than fits is built on this:
Table's rows, Textarea's lines, Tree, Accordion and List alike.

	ui_scroll_begin(ctx, area, &st)
	# ... widgets, drawn in content space ...
	ui_scroll_end(ctx, &st)

Content is placed at the region's origin offset by -offset_*, so a
widget scrolled out of view is clipped away and costs no vertices —
which is what keeps a long list inside the vertex budget without every
caller writing its own culling. Callers that KNOW their content is
long (a table's rows, an editor's lines) should still skip issuing
what is out of view; the clip is a correctness backstop, not a
substitute for virtualization.

State is caller-owned, like every other widget's.
*/
import lib.lib
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context


# Pixels one wheel notch scrolls.
int ui_scroll_notch():
	return 48


# Thickness of the scrollbar drawn inside the viewport's right edge.
float32 ui_scroll_bar_width():
	return 6.0


struct ui_scroll_state:
	float32 offset_x
	float32 offset_y
	# The viewport ui_scroll_begin was given, so ui_scroll_end needs no
	# second copy of it, and the extent the content covered in it.
	float32 view_x
	float32 view_y
	float32 view_w
	float32 view_h
	float32 content_w
	float32 content_h
	# The widget id owning a thumb drag, 0 when none.
	int32 drag_id
	float32 drag_grab_y


void ui_scroll_init(ui_scroll_state* st):
	st.offset_x = 0.0
	st.offset_y = 0.0
	st.view_x = 0.0
	st.view_y = 0.0
	st.view_w = 0.0
	st.view_h = 0.0
	st.content_w = 0.0
	st.content_h = 0.0
	st.drag_id = 0
	st.drag_grab_y = 0.0


# How far the content can scroll before its bottom reaches the
# viewport's, never negative: content shorter than the view does not
# scroll at all.
float32 ui_scroll_max(ui_scroll_state* st):
	float32 max = st.content_h - st.view_h
	if (max < 0.0):
		return 0.0
	return max


# 1 when the last measured content did not fit the viewport.
int ui_scroll_overflows(ui_scroll_state* st):
	if (ui_scroll_max(st) > 0.0):
		return 1
	return 0


void ui_scroll_clamp(ui_scroll_state* st):
	float32 max = ui_scroll_max(st)
	if (st.offset_y > max):
		st.offset_y = max
	if (st.offset_y < 0.0):
		st.offset_y = 0.0


# Scroll to a given offset, clamped to the measured content.
void ui_scroll_to(ui_scroll_state* st, float32 offset_y):
	st.offset_y = offset_y
	ui_scroll_clamp(st)


# Bring a band of content space into view with the smallest move that
# does it — what a caret or a selected row needs after keyboard motion.
void ui_scroll_reveal(ui_scroll_state* st, float32 top, float32 height):
	if (top < st.offset_y):
		st.offset_y = top
	else if (top + height > st.offset_y + st.view_h):
		st.offset_y = top + height - st.view_h
	ui_scroll_clamp(st)


# Enter a scrollable viewport: clip to area, then place widgets in a
# region shifted up by the current offset, so content coordinates run
# from the region's origin regardless of scroll position.
void ui_scroll_begin(ui_context* ctx, ui_rect area, ui_scroll_state* st):
	st.view_x = area.x
	st.view_y = area.y
	st.view_w = area.w
	st.view_h = area.h
	ui_clip_push(ctx.rndr, area)
	ui_region_push(ctx, ui_rect_new(area.x - st.offset_x, area.y - st.offset_y, area.w, area.h))


# Leave the viewport: record what the content covered, claim the
# frame's wheel notches when the pointer is inside, clamp, and draw a
# thumb when the content overflows.
void ui_scroll_end(ui_context* ctx, ui_scroll_state* st):
	ui_rect area = ui_rect_new(st.view_x, st.view_y, st.view_w, st.view_h)
	ui_rect content = ui_region_content(ctx)
	st.content_w = content.w
	st.content_h = content.h
	ui_region_pop(ctx)
	ui_clip_pop(ctx.rndr)

	# The wheel belongs to the region under the pointer, and is claimed
	# so one notch never scrolls two nested regions.
	if (ctx.input.scroll_y != 0):
		if (ui_rect_contains(area, cast(float32, ctx.input.scroll_at_x), cast(float32, ctx.input.scroll_at_y))):
			if (ui_scroll_overflows(st)):
				st.offset_y = st.offset_y - cast(float32, ctx.input.scroll_y * ui_scroll_notch())
				ctx.input.scroll_y = 0
	ui_scroll_clamp(st)

	# The thumb's id is taken whether or not there is a thumb. Widget ids
	# are sequential in call order, so allocating it only on the overflow
	# path would shift every later widget's id the moment content grows
	# past the viewport — and ctx.focus persists across frames, so a
	# focused field after a growing region would silently lose focus.
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1

	if (ui_scroll_overflows(st) == 0):
		st.drag_id = 0
		return

	# The thumb: proportional length, positioned by scroll fraction.
	float32 bar_w = ui_scroll_bar_width()
	float32 track_x = area.x + area.w - bar_w - 2.0
	float32 frac = st.view_h / st.content_h
	float32 thumb_h = area.h * frac
	if (thumb_h < 24.0):
		thumb_h = 24.0
	if (thumb_h > area.h):
		thumb_h = area.h
	float32 travel = area.h - thumb_h
	float32 max = ui_scroll_max(st)
	float32 thumb_y = area.y
	if (max > 0.0):
		thumb_y = area.y + travel * (st.offset_y / max)
	ui_rect thumb = ui_rect_new(track_x, thumb_y, bar_w, thumb_h)

	# Dragging the thumb, on the same press/active model as every other
	# widget — but tracked on the scroll state, since a viewport is not
	# issued through ui_layout_next and has no widget id of its own.
	if (ctx.disabled == 0):
		if (ui_scope_blocked(ctx) == 0):
			if (ctx.input.mouse_pressed):
				if (ui_rect_contains(thumb, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
					st.drag_id = id
					st.drag_grab_y = cast(float32, ctx.input.press_y) - thumb_y
			if (st.drag_id == id):
				if (ctx.input.mouse_down):
					if (travel > 0.0):
						float32 want = cast(float32, ctx.input.mouse_y) - st.drag_grab_y - area.y
						st.offset_y = max * (want / travel)
						ui_scroll_clamp(st)
				else:
					st.drag_id = 0

	ui_color bar = ctx.theme.border
	if (st.drag_id == id):
		bar = ctx.theme.text_muted
	ui_draw_rrect(ctx.rndr, thumb, bar_w * 0.5, bar)
