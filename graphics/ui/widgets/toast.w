/*
graphics.ui.widgets.toast: a transient notification, bottom-centered
above everything (docs/projects/ui_widgets.md §9.3).

	ui_toast_show(&st, c"Saved", now_ms, 2500)
	...
	ui_toast(ctx, &st, now_ms)

The widget takes the time from its caller and holds no clock of its
own. That is deliberate, and it is the answer to round 1's open
question 3.

The obvious clock, time_monotonic_ms(), is documented as wrap-safe for
exactly this kind of relative measurement — and is wrong on wasm, where
clock_gettime stores WASI's u64 nanosecond count straight into a
{seconds, nanoseconds} timespec without converting. Rather than block a
widget on a 64-by-32 division helper, the time comes in as an argument.
The native demo passes time_monotonic_ms(); a web caller passes a
frame-derived count; a test passes increasing integers, which is what
keeps this headless-testable at all.

The general rule the wasm bug only made obvious: UI code should not read
clocks. Anything time-dependent takes the time as an argument.

A toast draws on UI_LAYER_TOP, above even a modal, and takes no input:
it is not a popup scope and makes nothing inert. Notifications that
steal clicks are notifications that lose work.

Elapsed time is computed as a difference, so a monotonic source that
wraps a 32-bit int — which time_monotonic_ms() does, after about 24.8
days — still measures short intervals correctly.
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


# Longest message a toast holds. Fixed, like ui_textbox_state's buffer:
# a notification that needs more than this wants a dialog.
int ui_toast_capacity():
	return 128


float32 ui_toast_height():
	return 36.0


# Gap between the toast and the bottom of the window.
float32 ui_toast_margin():
	return 24.0


struct ui_toast_state:
	char[128] text
	int32 shown_at_ms
	int32 duration_ms
	int32 visible


void ui_toast_init(ui_toast_state* st):
	st.text[0] = 0
	st.shown_at_ms = 0
	st.duration_ms = 0
	st.visible = 0


# Show a message for duration_ms from now. Showing again restarts the
# timer, so a burst of notifications does not expire on the first one's
# clock.
void ui_toast_show(ui_toast_state* st, char* text, int now_ms, int duration_ms):
	int i = 0
	while ((i < ui_toast_capacity() - 1) && (text[i] != 0)):
		st.text[i] = text[i]
		i = i + 1
	st.text[i] = 0
	st.shown_at_ms = now_ms
	st.duration_ms = duration_ms
	st.visible = 1


void ui_toast_dismiss(ui_toast_state* st):
	st.visible = 0


# 1 while the toast should still be on screen. A difference, so a clock
# that wraps a 32-bit int still measures short intervals correctly.
int ui_toast_alive(ui_toast_state* st, int now_ms):
	if (st.visible == 0):
		return 0
	int elapsed = now_ms - st.shown_at_ms
	if (elapsed < 0):
		return 1
	if (elapsed >= st.duration_ms):
		return 0
	return 1


# Draw the toast if it is still alive, and return 1 while it is. Takes
# no input and opens no scope: the widgets underneath stay live.
int ui_toast(ui_context* ctx, ui_toast_state* st, int now_ms):
	if (ui_toast_alive(st, now_ms) == 0):
		st.visible = 0
		return 0

	int scale = ctx.theme.text_scale
	float32 vw = cast(float32, ctx.rndr.vp_w)
	float32 vh = cast(float32, ctx.rndr.vp_h)
	float32 pad = cast(float32, ctx.theme.pad)
	float32 w = cast(float32, ui_text_width(&st.text[0], scale)) + pad * 4.0
	float32 h = ui_toast_height()
	ui_rect surface = ui_rect_new((vw - w) * 0.5, vh - h - ui_toast_margin(), w, h)

	# UI_LAYER_TOP, so a toast is visible over an open modal — which is
	# the case that motivates a third layer at all. Saved and restored
	# rather than bracketed through ui_popup_begin, because a toast must
	# not become the input scope.
	int layer = ctx.rndr.layer
	ui_render_layer(ctx.rndr, UI_LAYER_TOP)
	ui_draw_shadow(ctx.rndr, surface, ctx.theme.shadow)
	ui_draw_rrect(ctx.rndr, surface, cast(float32, ctx.theme.radius), ctx.theme.accent)
	float32 ty = surface.y + (h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, surface.x + pad * 2.0, ty, &st.text[0], scale, ctx.theme.on_accent)
	ui_render_layer(ctx.rndr, layer)
	return 1
