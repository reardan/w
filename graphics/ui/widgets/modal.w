/*
graphics.ui.widgets.modal: a centered dialog over a scrim
(docs/projects/ui_widgets.md §5). The first widget that could not have
been written before the popup scope existed, and the reason it exists:
a modal is a popup that happens to cover the window.

	if (ui_modal_begin(ctx, c"Confirm", 280.0, 160.0, &open)):
		ui_label(ctx, c"Delete the file?")
		if (ui_button(ctx, c"Delete")):
			...
		ui_modal_end(ctx)

ui_modal_begin returns 1 while the dialog is open, so the caller issues
its body between the calls — and issues nothing, and calls no
ui_modal_end, while it is closed. Escape (which arrives as CHAR 27) and
a click on the scrim both close it.

Ordering, as for every immediate-mode popup: a widget issued BEFORE
ui_modal_begin goes inert on the frame AFTER the modal opens, since
that is when the open-popup registration is first seen. In practice
this is invisible — the click that opens a modal is consumed by
whatever opened it — but a caller that flips `open` from outside the
frame should expect the page to stay live for that one frame.
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


# Scrim alpha over the page behind an open modal.
float32 ui_modal_scrim_alpha():
	return 0.32


# Height of the dialog's title row.
float32 ui_modal_title_height():
	return 44.0


# Open a modal dialog: a scrim over the whole window, a centered
# elevated surface, and a title row. Returns 1 while open, with the
# layout region set to the dialog's body — issue body widgets and then
# call ui_modal_end. Returns 0 when closed, and then nothing was
# pushed, so ui_modal_end must not be called.
int ui_modal_begin(ui_context* ctx, char* title, float32 w, float32 h, int32* open):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	if (open[0] == 0):
		# Unregister unconditionally: the caller may have closed the
		# dialog from inside its own body (a Close button), which
		# leaves the popup registered until the next frame gets here.
		# Without this the whole page stays inert forever.
		ui_popup_dismiss(ctx, id)
		return 0
	ui_popup_open(ctx, id)

	float32 vw = cast(float32, ctx.rndr.vp_w)
	float32 vh = cast(float32, ctx.rndr.vp_h)
	ui_rect window = ui_rect_new(0.0, 0.0, vw, vh)
	ui_rect surface = ui_rect_new((vw - w) * 0.5, (vh - h) * 0.5, w, h)

	# Escape closes, wherever focus is: the modal owns input while open.
	int i = 0
	while (i < ctx.char_count):
		if (ctx.chars[i] == 27):
			open[0] = 0
		i = i + 1
	# So does a press on the scrim — outside the surface, inside the
	# window — and that press is consumed so nothing behind sees it.
	if (ctx.input.mouse_pressed):
		float32 px = cast(float32, ctx.input.press_x)
		float32 py = cast(float32, ctx.input.press_y)
		if (ui_rect_contains(surface, px, py) == 0):
			open[0] = 0
			ctx.input.mouse_pressed = 0
	if (open[0] == 0):
		ui_popup_dismiss(ctx, id)
		return 0

	# The whole window is the popup's area: the scrim covers it, and a
	# clip at the dialog's edge would cut the scrim away.
	ui_popup_begin(ctx, id, window, UI_LAYER_POPUP)
	ui_color scrim = ctx.theme.shadow
	scrim.a = ui_modal_scrim_alpha()
	ui_render_rect(ctx.rndr, window, scrim)
	ui_draw_shadow(ctx.rndr, surface, ctx.theme.shadow)
	ui_draw_rrect(ctx.rndr, surface, cast(float32, ctx.theme.radius), ctx.theme.surface)

	float32 pad = cast(float32, ctx.theme.pad)
	float32 title_h = ui_modal_title_height()
	float32 ty = surface.y + (title_h - cast(float32, ui_text_height(3))) * 0.5
	ui_draw_text(ctx.rndr, surface.x + pad * 2.0, ty, title, 3, ctx.theme.text)
	# A hairline under the title row, the same separator the table
	# header uses.
	ui_render_rect(ctx.rndr, ui_rect_new(surface.x + pad, surface.y + title_h, surface.w - pad * 2.0, 1.0), ctx.theme.border)

	# Body widgets lay out inside the surface, below the title.
	ui_region_push(ctx, ui_rect_new(surface.x + pad * 2.0, surface.y + title_h + pad, surface.w - pad * 4.0, surface.h - title_h - pad * 2.0))
	return 1


void ui_modal_end(ui_context* ctx):
	ui_region_pop(ctx)
	ui_popup_end(ctx)
