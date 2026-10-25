/*
graphics.ui.widgets.progress: the read-only progress bar
(docs/projects/ui_widgets.md §3).
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context


# Read-only progress bar; fraction clamps to 0..1.
void ui_progress(ui_context* ctx, float32 w, float32 fraction):
	if (fraction < 0.0): fraction = 0.0
	if (fraction > 1.0): fraction = 1.0
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	ui_access_node* n = ui_access_widget(ctx, ui_access_aux_id(ctx), UI_ACCESS_PROGRESS, r, 0)
	if (n != 0):
		# The value is the percentage text, "0%".."100%".
		char[8] pct
		int v = cast(int, fraction * 100.0 + 0.5)
		int k = 0
		if (v >= 100):
			pct[k] = '1'
			k = k + 1
		if (v >= 10):
			pct[k] = '0' + (v / 10) % 10
			k = k + 1
		pct[k] = '0' + v % 10
		pct[k + 1] = '%'
		ui_access_set_value(ctx, n, &pct[0], k + 2)
	# A thin fully-rounded track with a matching accent fill.
	float32 bar_h = 6.0
	ui_rect track = ui_rect_new(r.x, r.y + (r.h - bar_h) * 0.5, r.w, bar_h)
	ui_draw_rrect(ctx.rndr, track, bar_h * 0.5, ctx.theme.widget)
	if (fraction > 0.0):
		ui_draw_rrect(ctx.rndr, ui_rect_new(track.x, track.y, track.w * fraction, track.h), bar_h * 0.5, ctx.theme.accent)
