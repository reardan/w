/*
Native driver for the stage-1 UI demo: the graphics/demo.w shape — a
main-owned while-loop over poll/draw/swap with sleep_ms pacing — around
the shared form in graphics/ui/demo_shared.w. Run it on a desktop:

	./bin/wv2 x64 graphics/ui/demo.w -o bin/graphics_ui_demo
	./bin/graphics_ui_demo            # --frames N to exit after N frames

The wasm twin is graphics/ui/demo_web.w; only the loop driver differs.
*/
import lib.lib
import lib.args
import lib.time
import graphics.gl
import graphics.window
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets
import graphics.ui.demo_shared


int main(int argc, int argv):
	args_init(argc, argv)
	int max_frames = 0
	char* frames_value = args_value(c"frames")
	if (frames_value != 0):
		max_frames = atoi(frames_value)

	gfx_window* win = gfx_window_open(c"W ui demo", 320, 240)
	if (win == 0):
		return 1
	ui_renderer rndr
	if (ui_render_init(&rndr) == 0):
		return 1
	ui_demo_state state
	ui_demo_init(&state)
	ui_context ctx
	ui_context_init(&ctx, &rndr, &state.light_theme)

	int frame = 0
	while (gfx_window_poll(win)):
		ui_begin_window(&ctx, win)
		ui_demo_body(&ctx, &state)
		ui_end(&ctx)
		gfx_window_swap(win)
		sleep_ms(16)
		frame = frame + 1
		if ((max_frames > 0) && (frame >= max_frames)):
			break
	ui_render_destroy(&rndr)
	gfx_window_destroy(win)
	return 0
