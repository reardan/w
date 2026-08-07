/*
graphics.ui.demo_shared: the stage-1 demo form, written once and
driven by both graphics/ui/demo.w (native while-loop) and
graphics/ui/demo_web.w (wasm frame callback) — the "same widget
source on every backend" claim, held literally
(docs/projects/ui_framework.md §3, §8 stage 1).

The layout below is fixed by the default theme metrics (pad 8, gap 8,
widget_height 32) in a 320x400 window, and the gates rely on the ROW
positions (proportional text makes widths font-derived; rows stay
put): graphics/ui/smoke_test.w probes pixels in its own 320x240
window — everything it samples sits above y=240,
tools/web/run_ui_stub.mjs scripts clicks:

	title    "W UI demo"     row (8,   8, .., 32) — bold title strike
	button   "Click me"      row (8,  48, .., 32) — click point (20, 60)
	  + same_line disabled button "Locked" (stage-3 disabled tokens)
	checkbox "dark mode"     row (8,  88, .., 32)
	textbox                  rect (8, 128, 200, 32)
	radio    "small"/"large" row  (8, 168, ..) — same_line pair
	toggle   "sound"         rect (8, 208, ..)
	dropdown light/dark/ocean rect (8, 248, 160, 32) — the THEME picker
	progress clicks x 10%    rect (8, 288, 200, 32)

Clicking the button prints "ui demo clicks: N" (asserted by
wasm_ui_test's expect_stdout) and advances the progress bar. Theme
switching is live two ways, one source of truth (st.choice): the
checkbox toggles light<->dark, the dropdown picks any of the three
presets including the non-grayscale ocean theme — §5's dark/light
swap and "fully customizable" claim, both on screen.
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
	ui_textbox_state textbox
	int32 size_choice
	int32 sound_on
	int32 choice
	int32 choice_open
	char** choice_items
	ui_theme light_theme
	ui_theme dark_theme
	ui_theme ocean_theme


void ui_demo_init(ui_demo_state* st):
	st.clicks = 0
	st.dark = 0
	ui_textbox_init(&st.textbox)
	st.size_choice = 0
	st.sound_on = 0
	st.choice = 0
	st.choice_open = 0
	# Built by hand (not lib.process's strv_new — that module is not
	# wasm-compatible and this file compiles for every backend).
	st.choice_items = cast(char**, malloc(3 * __word_size__))
	st.choice_items[0] = c"light"
	st.choice_items[1] = c"dark"
	st.choice_items[2] = c"ocean"
	ui_theme_light(&st.light_theme)
	ui_theme_dark(&st.dark_theme)
	ui_theme_ocean(&st.ocean_theme)


# One frame of the demo form. Call between ui_begin_window and ui_end.
void ui_demo_body(ui_context* ctx, ui_demo_state* st):
	ui_title(ctx, c"W UI demo")
	if (ui_button(ctx, c"Click me")):
		st.clicks = st.clicks + 1
		print(c"ui demo clicks: ")
		println(itoa(st.clicks))
	# The disabled scope on display: renders, never reacts.
	ui_same_line(ctx)
	ui_disable(ctx, 1)
	ui_button(ctx, c"Locked")
	ui_disable(ctx, 0)
	# Two live paths into the one theme choice: the checkbox flips
	# light<->dark, the dropdown picks any preset (ocean included).
	if (ui_checkbox(ctx, c"dark mode", &st.dark)):
		st.choice = st.dark
	ui_textbox(ctx, 200.0, &st.textbox)
	ui_radio(ctx, c"small", 0, &st.size_choice)
	ui_same_line(ctx)
	ui_radio(ctx, c"large", 1, &st.size_choice)
	ui_toggle(ctx, c"sound", &st.sound_on)
	if (ui_dropdown(ctx, 160.0, st.choice_items, 3, &st.choice, &st.choice_open)):
		st.dark = 0
		if (st.choice == 1):
			st.dark = 1
	ui_progress(ctx, 200.0, cast(float32, st.clicks) * 0.1)
	# Theme swap takes effect from the next widget on; the background
	# clear picks it up next frame.
	if (st.choice == 2):
		ctx.theme = &st.ocean_theme
	else if (st.choice == 1):
		ctx.theme = &st.dark_theme
	else:
		ctx.theme = &st.light_theme
