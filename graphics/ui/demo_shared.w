/*
graphics.ui.demo_shared: the stage-1 demo form, written once and
driven by both graphics/ui/demo.w (native while-loop) and
graphics/ui/demo_web.w (wasm frame callback) — the "same widget
source on every backend" claim, held literally
(docs/projects/ui_framework.md §3, §8 stage 1).

The layout below is fixed by the default theme metrics (pad 8, gap 8,
widget_height 32, text_scale 2) in a 320x240 window, and the gates
rely on it (graphics/ui/smoke_test.w probes pixels,
tools/web/run_ui_stub.mjs scripts clicks):

	label    "W UI demo"  rect (8,   8, 144, 32)
	button   "Click me"   rect (8,  48, 144, 32)  — click point (20, 60)
	checkbox "dark mode"  rect (8,  88, 168, 32)

Clicking the button prints "ui demo clicks: N" (asserted by
wasm_ui_test's expect_stdout); the checkbox swaps the active theme
pointer — the dark/light toggle of §5, live.
*/
import lib.lib
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets


struct ui_demo_state:
	int32 clicks
	int32 dark
	ui_theme light_theme
	ui_theme dark_theme


void ui_demo_init(ui_demo_state* st):
	st.clicks = 0
	st.dark = 0
	ui_theme_light(&st.light_theme)
	ui_theme_dark(&st.dark_theme)


# One frame of the demo form. Call between ui_begin_window and ui_end.
void ui_demo_body(ui_context* ctx, ui_demo_state* st):
	ui_label(ctx, c"W UI demo")
	if (ui_button(ctx, c"Click me")):
		st.clicks = st.clicks + 1
		print(c"ui demo clicks: ")
		println(itoa(st.clicks))
	ui_checkbox(ctx, c"dark mode", &st.dark)
	# Theme swap takes effect from the next widget on; the background
	# clear picks it up next frame.
	if (st.dark):
		ctx.theme = &st.dark_theme
	else:
		ctx.theme = &st.light_theme
