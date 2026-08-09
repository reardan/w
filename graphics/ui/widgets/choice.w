/*
graphics.ui.widgets.choice: the boolean and one-of-N widgets —
checkbox, radio, toggle (docs/projects/ui_widgets.md §3).
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context


# Toggles *checked and returns 1 on the frame it flips. The whole
# box-plus-label row is clickable.
int ui_checkbox(ui_context* ctx, char* label, int32* checked):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	int box = ctx.theme.unit * 2
	float32 w = cast(float32, box + ctx.theme.gap + ui_text_width(label, scale))
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	int toggled = ui_click_behavior(ctx, id, r)
	if (toggled):
		checked[0] = 1 - checked[0]

	# Rounded box: an accent fill with a checkmark when checked, an
	# outlined box otherwise.
	ui_rect box_rect = ui_rect_new(r.x, r.y + (r.h - cast(float32, box)) * 0.5, cast(float32, box), cast(float32, box))
	float32 rad = cast(float32, ctx.theme.radius_small)
	if (checked[0]):
		ui_color fill = ctx.theme.accent
		if (ctx.disabled):
			fill = ctx.theme.disabled_widget
		else if (ctx.hot == id):
			fill = ctx.theme.accent_hot
		ui_draw_rrect(ctx.rndr, box_rect, rad, fill)
		ui_draw_check(ctx.rndr, ui_rect_inset(box_rect, 1.0), ctx.theme.on_accent)
	else:
		ui_color edge = ctx.theme.border
		if (ctx.disabled):
			edge = ctx.theme.disabled_widget
		else if (ctx.hot == id):
			edge = ctx.theme.text_muted
		ui_draw_rrect(ctx.rndr, box_rect, rad, edge)
		ui_draw_rrect(ctx.rndr, ui_rect_inset(box_rect, 2.0), rad - 2.0, ctx.theme.surface)
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, r.x + cast(float32, box + ctx.theme.gap), ty, label, scale, ui_text_color(ctx))
	return toggled


# One radio option; clicking selects its index into the caller's group
# variable. Returns 1 on the frame this option becomes selected.
int ui_radio(ui_context* ctx, char* label, int index, int32* selected):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	int box = ctx.theme.unit * 2
	float32 w = cast(float32, box + ctx.theme.gap + ui_text_width(label, scale))
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	int clicked = ui_click_behavior(ctx, id, r)
	int changed = 0
	if (clicked && (selected[0] != index)):
		selected[0] = index
		changed = 1

	# A circle: ring in the accent when selected (with a center dot),
	# border gray otherwise.
	ui_rect box_rect = ui_rect_new(r.x, r.y + (r.h - cast(float32, box)) * 0.5, cast(float32, box), cast(float32, box))
	if (selected[0] == index):
		ui_color mark = ctx.theme.accent
		if (ctx.disabled):
			mark = ctx.theme.disabled_text
		else if (ctx.hot == id):
			mark = ctx.theme.accent_hot
		ui_draw_ring(ctx.rndr, box_rect, mark)
		ui_draw_disc(ctx.rndr, ui_rect_inset(box_rect, 4.0), mark)
	else:
		ui_color edge = ctx.theme.border
		if (ctx.disabled):
			edge = ctx.theme.disabled_widget
		else if (ctx.hot == id):
			edge = ctx.theme.text_muted
		ui_draw_ring(ctx.rndr, box_rect, edge)
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, r.x + cast(float32, box + ctx.theme.gap), ty, label, scale, ui_text_color(ctx))
	return changed


# A switch: an accent track with the knob on the off (left) or on
# (right) side. The whole row is clickable; returns 1 on the frame it
# flips.
int ui_toggle(ui_context* ctx, char* label, int32* on):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	int track_w = ctx.theme.unit * 4
	int track_h = ctx.theme.unit * 2
	float32 w = cast(float32, track_w + ctx.theme.gap + ui_text_width(label, scale))
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	int flipped = ui_click_behavior(ctx, id, r)
	if (flipped):
		on[0] = 1 - on[0]

	ui_rect track = ui_rect_new(r.x, r.y + (r.h - cast(float32, track_h)) * 0.5, cast(float32, track_w), cast(float32, track_h))
	ui_color track_color = ctx.theme.widget
	ui_color knob_color = ctx.theme.surface
	if (on[0]):
		track_color = ctx.theme.accent
		if (ctx.hot == id):
			track_color = ctx.theme.accent_hot
		knob_color = ctx.theme.on_accent
	else if (ctx.hot == id):
		track_color = ctx.theme.widget_hot
	if (ctx.disabled):
		track_color = ctx.theme.disabled_widget
		knob_color = ctx.theme.disabled_text
	# A pill track with a round sliding knob.
	ui_draw_rrect(ctx.rndr, track, track.h * 0.5, track_color)
	float32 knob = cast(float32, track_h - 4)
	float32 kx = track.x + 2.0
	if (on[0]):
		kx = track.x + track.w - knob - 2.0
	ui_draw_disc(ctx.rndr, ui_rect_new(kx, track.y + 2.0, knob, knob), knob_color)
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, r.x + cast(float32, track_w + ctx.theme.gap), ty, label, scale, ui_text_color(ctx))
	return flipped
