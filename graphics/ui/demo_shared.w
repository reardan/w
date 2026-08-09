/*
graphics.ui.demo_shared: the stage-1 demo form, written once and
driven by both graphics/ui/demo.w (native while-loop) and
graphics/ui/demo_web.w (wasm frame callback) — the "same widget
source on every backend" claim, held literally
(docs/projects/ui_framework.md §3, §8 stage 1).

The layout below is fixed by the default theme metrics (pad 8, gap 8,
widget_height 32) in a 320x680 window, and the gates rely on the ROW
positions (proportional text makes widths font-derived; rows stay
put): graphics/ui/smoke_test.w probes pixels in its own 320x240
window — everything it samples sits above y=240,
tools/web/run_ui_stub.mjs scripts clicks. The stage-1..3 rows keep the
coordinates those gates were written against; the round-1 widgets are
appended below them:

	title    "W UI demo"     row (8,   8, .., 32) — bold title strike
	button   "Click me"      row (8,  48, .., 32) — click point (20, 60)
	  + same_line disabled button "Locked" (stage-3 disabled tokens)
	checkbox "dark mode"     row (8,  88, .., 32)
	textbox                  rect (8, 128, 200, 32)
	radio    "small"/"large" row  (8, 168, ..) — same_line pair
	toggle   "sound"         rect (8, 208, ..)
	dropdown light/dark/ocean rect (8, 248, 160, 32) — the THEME picker
	progress clicks x 10%    rect (8, 288, 200, 32)
	button   "Open dialog"   row (8, 328, .., 32) — opens the MODAL
	table    name/size       rect (8, 368, 304, 129) — sticky header,
	                         scrollable body, click to select a row
	textarea                 rect (8, 505, 304, 160) — multi-line edit

The modal, when open, centers a 240x160 dialog over the window on the
popup layer and makes everything above inert until Escape, the scrim
or its Close button dismisses it.

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
	# Round-1 widgets (docs/projects/ui_widgets.md).
	int32 dialog_open
	ui_table_state table
	char** table_headers
	int32* table_widths
	ui_textarea_state notes


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
	st.dialog_open = 0
	ui_table_init(&st.table)
	st.table_headers = cast(char**, malloc(2 * __word_size__))
	st.table_headers[0] = c"widget"
	st.table_headers[1] = c"round"
	st.table_widths = cast(int32*, malloc(2 * 4))
	st.table_widths[0] = 200
	st.table_widths[1] = 90
	ui_textarea_init(&st.notes)
	ui_textarea_set(&st.notes, c"Multi-line edit.\nArrows, page keys,\nshift-selection.")


# The table's rows: one per widget the round shipped.
char* ui_demo_row_name(int row):
	if (row == 0):
		return c"button"
	if (row == 1):
		return c"checkbox"
	if (row == 2):
		return c"textbox"
	if (row == 3):
		return c"dropdown"
	if (row == 4):
		return c"modal"
	if (row == 5):
		return c"table"
	return c"textarea"


char* ui_demo_row_round(int row):
	if (row < 4):
		return c"shipped"
	return c"round 1"


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

	# Round 1: the modal's trigger, then the table and the edit surface.
	if (ui_button(ctx, c"Open dialog")):
		st.dialog_open = 1
	# A table one header plus four rows tall, holding seven rows — so
	# the scroll thumb and row virtualization are both on screen.
	ui_table_begin(ctx, ui_rect_new(8.0, 368.0, 304.0, 129.0), st.table_headers, st.table_widths, 2, &st.table)
	int row = 0
	while (row < 7):
		if (ui_table_row(ctx, &st.table, row)):
			ui_table_cell(ctx, &st.table, ui_demo_row_name(row))
			ui_table_cell(ctx, &st.table, ui_demo_row_round(row))
		row = row + 1
	ui_table_end(ctx, &st.table)
	ui_textarea(ctx, ui_rect_new(8.0, 505.0, 304.0, 160.0), &st.notes)

	# The modal last, so it is issued above everything — though the
	# popup layer, not call order, is what actually puts it on top.
	if (ui_modal_begin(ctx, c"Dialog", 240.0, 160.0, &st.dialog_open)):
		ui_label(ctx, c"The page behind is inert.")
		ui_label(ctx, c"Escape or the scrim closes.")
		if (ui_button(ctx, c"Close")):
			st.dialog_open = 0
		ui_modal_end(ctx)

	# Theme swap takes effect from the next widget on; the background
	# clear picks it up next frame.
	if (st.choice == 2):
		ctx.theme = &st.ocean_theme
	else if (st.choice == 1):
		ctx.theme = &st.dark_theme
	else:
		ctx.theme = &st.light_theme
