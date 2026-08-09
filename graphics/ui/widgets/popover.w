/*
graphics.ui.widgets.popover: an elevated surface anchored to something
else on screen (docs/projects/ui_widgets.md §9).

	if (ui_popover_begin(ctx, id, field, 200.0, 120.0, &open)):
		ui_label(ctx, c"anything at all")
		ui_popover_end(ctx)

The generic form of what ui_dropdown hand-rolls: register the popup so
everything outside it goes inert, place the surface, draw the elevation,
and hand the caller a layout region to fill. Unlike the dropdown it does
not own its contents, so a popover can hold a search field, a calendar
grid or a menu without any of them knowing about each other.

Placement flips above the anchor when there is not room below, and
shifts horizontally to stay inside the viewport, so a popover attached
to something near an edge does not draw off-screen.

Like ui_modal_begin: returns 0 having pushed nothing, and then
ui_popover_end must not be called. And like it, a closed popover
dismisses unconditionally — a caller that closes the popover from
inside its own body would otherwise leave it registered and the whole
page inert.
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context
import graphics.ui.widgets.overlay


# Gap between the anchor and the surface it opens next to.
float32 ui_popover_gap():
	return 4.0


# Where a w-by-h surface should sit relative to `anchor` inside a
# vw-by-vh viewport. Below the anchor by default; above it when that
# would run off the bottom and there is more room above.
ui_rect ui_popover_place(ui_rect anchor, float32 w, float32 h, float32 vw, float32 vh):
	float32 gap = ui_popover_gap()
	float32 y = anchor.y + anchor.h + gap
	if (y + h > vh):
		float32 above = anchor.y - gap - h
		# Flip only if above is genuinely better: near the top of a short
		# viewport both overflow, and below is the friendlier of the two.
		if (above >= 0.0):
			y = above
		else if (anchor.y > vh - (anchor.y + anchor.h)):
			y = above
	float32 x = anchor.x
	if (x + w > vw):
		x = vw - w
	if (x < 0.0):
		x = 0.0
	return ui_rect_new(x, y, w, h)


# Open an anchored surface. Returns 1 while open, with the layout region
# set to the surface's inside — issue body widgets and then call
# ui_popover_end.
int ui_popover_begin(ui_context* ctx, int id, ui_rect anchor, float32 w, float32 h, int32* open):
	if (open[0] == 0):
		ui_popup_dismiss(ctx, id)
		return 0
	ui_popup_open(ctx, id)

	float32 vw = cast(float32, ctx.rndr.vp_w)
	float32 vh = cast(float32, ctx.rndr.vp_h)
	ui_rect surface = ui_popover_place(anchor, w, h, vw, vh)

	# Escape closes, wherever focus is, and so does a press outside the
	# surface — consumed, so nothing behind it also sees the press.
	int i = 0
	while (i < ctx.char_count):
		if (ctx.chars[i] == 27):
			open[0] = 0
		i = i + 1
	if (ctx.input.mouse_pressed):
		float32 px = cast(float32, ctx.input.press_x)
		float32 py = cast(float32, ctx.input.press_y)
		if (ui_rect_contains(surface, px, py) == 0):
			open[0] = 0
			ctx.input.mouse_pressed = 0
	if (open[0] == 0):
		ui_popup_dismiss(ctx, id)
		return 0

	ui_popup_begin(ctx, id, surface, UI_LAYER_POPUP)
	ui_draw_shadow(ctx.rndr, surface, ctx.theme.shadow)
	ui_draw_rrect(ctx.rndr, surface, cast(float32, ctx.theme.radius), ctx.theme.surface)
	# The body lays out inside the surface, inset by a pad, exactly as a
	# modal's does.
	float32 pad = cast(float32, ctx.theme.pad)
	ui_region_push(ctx, ui_rect_new(surface.x + pad, surface.y + pad, surface.w - pad * 2.0, surface.h - pad * 2.0))
	return 1


void ui_popover_end(ui_context* ctx):
	ui_region_pop(ctx)
	ui_popup_end(ctx)
