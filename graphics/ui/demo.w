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
import lib.stream
import graphics.gl
import graphics.window
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets
import graphics.ui.demo_shared


# Write the just-drawn frame as a binary PPM (P6): glReadPixels is
# bottom-origin, PPM rows run top-down, so rows flip on the way out.
# Convert with any image tool (e.g. tools/ppm_to_png.py).
int ui_demo_write_ppm(char* path, int w, int h):
	char* pixels = malloc(w * h * 4)
	glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, pixels)
	wstream* out = stream_open_write(path)
	if (out == 0):
		free(pixels)
		return 0
	stream_write_cstr(out, c"P6\n")
	stream_write_int(out, w)
	stream_write_cstr(out, c" ")
	stream_write_int(out, h)
	stream_write_cstr(out, c"\n255\n")
	char* row = malloc(w * 3)
	int y = h - 1
	while (y >= 0):
		char* src = &pixels[y * w * 4]
		int x = 0
		while (x < w):
			row[x * 3] = src[x * 4]
			row[x * 3 + 1] = src[x * 4 + 1]
			row[x * 3 + 2] = src[x * 4 + 2]
			x = x + 1
		stream_write(out, row, w * 3)
		y = y - 1
	stream_close(out)
	stream_free(out)
	free(row)
	free(pixels)
	return 1


int main(int argc, int argv):
	args_init(argc, argv)
	int max_frames = 0
	char* frames_value = args_value(c"frames")
	if (frames_value != 0):
		max_frames = atoi(frames_value)
	# --screenshot out.ppm captures the final frame (needs --frames).
	char* shot_path = args_value(c"screenshot")

	gfx_window* win = gfx_window_open(c"W ui demo", 320, 400)
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
		frame = frame + 1
		int last = (max_frames > 0) && (frame >= max_frames)
		if (last && (shot_path != 0)):
			glFinish()
			if (ui_demo_write_ppm(shot_path, win.width, win.height) == 0):
				print_error(c"screenshot write failed\n")
		gfx_window_swap(win)
		sleep_ms(16)
		if (last):
			break
	ui_render_destroy(&rndr)
	gfx_window_destroy(win)
	return 0
