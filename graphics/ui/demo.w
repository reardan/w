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
import graphics.ui.demo_shell


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
	# --theme light|dark|ocean preselects the theme the picker would set,
	# so all three docs/images/ui_demo_*.png are reproducible from the
	# CLI instead of by clicking the dropdown before capturing.
	# --dialog opens the modal on the first frame, so the one round-1
	# widget that is not on the default screen is capturable too.
	int dialog = args_has_flag(c"dialog")
	# --shell swaps the stage-1..3 form for the round-2 editor shell in a
	# wide window. The form's row coordinates are load-bearing for
	# graphics/ui/smoke_test.w and tools/web/run_ui_stub.mjs, so the
	# shell is a separate screen rather than more rows on the same one.
	int shell = args_has_flag(c"shell")
	# --menu opens the shell's context menu and raises a toast on the
	# first frame, so the two round-2 overlays that are not on the
	# default screen are capturable without clicking — the same reason
	# --dialog exists for the modal.
	int menu = args_has_flag(c"menu")
	int theme_choice = 0
	char* theme_value = args_value(c"theme")
	if (theme_value != 0):
		if (strcmp(theme_value, c"dark") == 0):
			theme_choice = 1
		else if (strcmp(theme_value, c"ocean") == 0):
			theme_choice = 2
		else if (strcmp(theme_value, c"light") != 0):
			print_error(c"demo: unknown --theme (want light, dark or ocean)\n")
			return 1

	int win_w = 320
	int win_h = 680
	if (shell):
		win_w = 900
		win_h = 600
	gfx_window* win = gfx_window_open(c"W ui demo", win_w, win_h)
	if (win == 0):
		return 1
	ui_renderer rndr
	if (ui_render_init(&rndr) == 0):
		return 1
	ui_shell_state shell_state
	ui_shell_init(&shell_state)
	if (shell):
		if (theme_choice == 0):
			ui_theme_light(&shell_state.theme)
		else if (theme_choice == 2):
			ui_theme_ocean(&shell_state.theme)
		# The shell opens with one document already up, so the editor
		# pane is not empty in a screenshot.
		ui_shell_open_doc(&shell_state, 0)
		if (menu):
			ui_shell_pin_menu(&shell_state, 60.0, 150.0)
			# Started from the same clock the loop feeds ui_shell_body,
			# or it would already have expired by the first frame.
			ui_toast_show(&shell_state.toast, c"Collapsed every folder", time_monotonic_ms(), 1000000)
	ui_demo_state state
	ui_demo_init(&state)
	# Same single source of truth the checkbox and dropdown drive.
	state.choice = theme_choice
	state.dark = 0
	if (theme_choice == 1):
		state.dark = 1
	state.dialog_open = dialog
	ui_context ctx
	ui_context_init(&ctx, &rndr, &state.light_theme)
	if (shell):
		ctx.theme = &shell_state.theme

	int frame = 0
	while (gfx_window_poll(win)):
		ui_begin_window(&ctx, win)
		if (shell):
			# The shell's toast is the one time-dependent thing on screen,
			# and the widget layer reads no clocks — so the driver
			# supplies the time (docs/projects/ui_widgets.md §9.3).
			ui_shell_body(&ctx, &shell_state, time_monotonic_ms())
		else:
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
