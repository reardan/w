/*
Wasm driver for the stage-1 UI demo: the graphics/demo_web.w shape —
setup in main, then a frame callback registered through gfx_window_run
and driven by the host's requestAnimationFrame (the return value
travels in the exported $ax global) — around the same shared form as
the native driver. Run in a browser:

	./bin/wv2 wasm graphics/ui/demo_web.w -o bin/graphics_ui_demo.wasm
	python3 -m http.server 8000
	# -> http://localhost:8000/tools/web/?module=/bin/graphics_ui_demo.wasm

Headless gate: wasm_ui_test drives it through
tools/web/run_ui_stub.mjs with scripted click events.
*/
import lib.lib
import lib.args
import graphics.gl
import graphics.window
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets
import graphics.ui.demo_shared


gfx_window* ui_demo_win
ui_renderer* ui_demo_rndr
ui_context* ui_demo_ctx
ui_demo_state* ui_demo_st
int ui_demo_frame_count
int ui_demo_max_frames


int ui_demo_frame():
	if (gfx_window_poll(ui_demo_win) == 0):
		return 0
	ui_begin_window(ui_demo_ctx, ui_demo_win)
	ui_demo_body(ui_demo_ctx, ui_demo_st)
	ui_end(ui_demo_ctx)
	gfx_window_swap(ui_demo_win)
	ui_demo_frame_count = ui_demo_frame_count + 1
	if ((ui_demo_max_frames > 0) && (ui_demo_frame_count >= ui_demo_max_frames)):
		return 0
	return 1


int main(int argc, int argv):
	args_init(argc, argv)
	ui_demo_max_frames = 0
	char* frames_value = args_value(c"frames")
	if (frames_value != 0):
		ui_demo_max_frames = atoi(frames_value)

	ui_demo_win = gfx_window_open(c"W ui demo", 320, 400)
	if (ui_demo_win == 0):
		return 1
	ui_demo_rndr = new ui_renderer()
	if (ui_render_init(ui_demo_rndr) == 0):
		return 1
	ui_demo_st = new ui_demo_state()
	ui_demo_init(ui_demo_st)
	ui_demo_ctx = new ui_context()
	ui_context_init(ui_demo_ctx, ui_demo_rndr, &ui_demo_st.light_theme)
	ui_demo_frame_count = 0

	gfx_window_run(ui_demo_win, ui_demo_frame)
	return 0
