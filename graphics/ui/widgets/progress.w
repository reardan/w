/*
graphics.ui.widgets.progress: the read-only progress bar
(docs/projects/ui_widgets.md §3).
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets.state
import graphics.ui.widgets.layout


# Read-only progress bar; fraction clamps to 0..1.
void ui_progress(ui_context* ctx, float32 w, float32 fraction):
	if (fraction < 0.0):
		fraction = 0.0
	if (fraction > 1.0):
		fraction = 1.0
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	# A thin fully-rounded track with a matching accent fill.
	float32 bar_h = 6.0
	ui_rect track = ui_rect_new(r.x, r.y + (r.h - bar_h) * 0.5, r.w, bar_h)
	ui_draw_rrect(ctx.rndr, track, bar_h * 0.5, ctx.theme.widget)
	if (fraction > 0.0):
		ui_draw_rrect(ctx.rndr, ui_rect_new(track.x, track.y, track.w * fraction, track.h), bar_h * 0.5, ctx.theme.accent)
