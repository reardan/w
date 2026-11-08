# wbuild: binary=wdrive_fixture arch=x64
# The small graphics.ui program tests/wdrive_xvfb_test.w drives through
# bin/wdrive (docs/projects/wdrive.md). It knows nothing about the
# control channel: a "Paint" button flips the theme between light and
# dark (so a pixel near the corner changes colour), a label counts the
# clicks, and a textbox takes typed text. Each click is also printed
# on stdout, which wdrive forwards to its stderr.
import lib.lib
import lib.time
import graphics.gl
import graphics.window
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets


int main(int argc, int argv):
	gfx_window* win = gfx_window_open(c"wdrive fixture", 320, 240)
	if (win == 0): return 1
	ui_renderer rndr
	if (ui_render_init(&rndr) == 0): return 1
	ui_theme light
	ui_theme dark
	ui_theme_light(&light)
	ui_theme_dark(&dark)
	ui_context ctx
	ui_context_init(&ctx, &rndr, &light)
	ui_textbox_state name
	ui_textbox_init(&name)
	int clicks = 0
	while (gfx_window_poll(win)):
		ui_begin_window(&ctx, win)
		ui_title(&ctx, c"Fixture")
		if (ui_button(&ctx, c"Paint")):
			clicks = clicks + 1
			print(c"fixture clicks ")
			println(itoa(clicks))
		char* digits = itoa(clicks)
		char* count = strjoin(c"clicks: ", digits)
		ui_label(&ctx, count)
		free(count)
		free(digits)
		ui_textbox(&ctx, 200.0, &name)
		ui_end(&ctx)
		# The theme the next frame clears with.
		if (clicks % 2 == 1): ctx.theme = &dark
		else: ctx.theme = &light
		gfx_window_swap(win)
		sleep_ms(5)
	ui_render_destroy(&rndr)
	gfx_window_destroy(win)
	return 0
