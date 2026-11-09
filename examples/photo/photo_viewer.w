/*
photo_viewer: an interactive graphics.effects demo -- the image on the
right, graphics.ui controls on the left, every change re-run through the
GPU effect chain (ping-pong framebuffer objects at the image's own
resolution) and shown on the next frame.

	./wbuild photo_viewer        # or: bin/wv2 x64 examples/photo/photo_viewer.w -o bin/photo_viewer
	bin/photo_viewer photo.jpg [--out graded.png] [any photo_fx effect flag]
	bin/photo_viewer pattern:640x400 --frames 3 --screenshot bin/viewer.png

Drag a slider to change its value; "Save" writes the graded image to
--out (default photo_viewer_out.png). --frames N exits after N frames
and --screenshot writes the last one (window pixels) as a PNG, for
tests and docs.

graphics.ui has no slider widget yet, so photo_slider below is a small
one built from the same pieces the stock widgets use (ui_layout_next,
ui_click_behavior, the theme colors, an accessible UI_ACCESS_SLIDER node
with its range). Design notes: docs/projects/effects.md
*/
# wbuild: binary=photo_viewer arch=x64
# A real three-frame run (SKIP without a display, a failure under
# W_CI_NO_SKIP): the chain must run on the GPU and the screenshot land.
# wbuild: target=photo_viewer_test tag=tests_x64 dep=photo_viewer
# wbuild: step="bin/photo_viewer pattern:240x160 --frames 3 --screenshot bin/photo_viewer_test.png --vignette 0.6 --lut sepia --blur 2" expect_stdout="photo_viewer"
import lib.lib
import lib.args
import lib.time
import lib.format
import lib.ci_skip
import graphics.gl
import graphics.window
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets
import graphics.ui.accessibility
import graphics.effects_core
import graphics.effects_cpu
import graphics.effects
import graphics.image.image
import examples.photo.photo_lib


const int photo_panel_width = 300


# A horizontal slider over lo..hi: the label and value on the left, a
# track with a knob on the right. Pressing anywhere on the row grabs it;
# the value follows the pointer while the button is held. Returns 1 on
# frames where the value changed.
int photo_slider(ui_context* ctx, char* label, float32* value, float32 lo, float32 hi):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int scale = ctx.theme.text_scale
	ui_rect r = ui_layout_next(ctx, cast(float32, photo_panel_width - 20), cast(float32, ctx.theme.widget_height))
	ui_access_node* n = ui_access_widget(ctx, id, UI_ACCESS_SLIDER, r, label)
	if (n != 0): ui_access_set_range(ctx.access, n.id, *value, lo, hi, 0.0)
	ui_click_behavior(ctx, id, r)
	float32 label_w = 120.0
	float32 knob = 14.0
	ui_rect track = ui_rect_new(r.x + label_w + knob * 0.5, r.y + r.h * 0.5 - 3.0, r.w - label_w - knob, 6.0)
	int changed = 0
	if ((ctx.active == id) && ctx.input.mouse_down && (ctx.disabled == 0)):
		float32 t = (cast(float32, ctx.input.mouse_x) - track.x) / track.w
		if (t < 0.0): t = 0.0
		if (t > 1.0): t = 1.0
		float32 v = lo + t * (hi - lo)
		if (v != *value):
			*value = v
			changed = 1
	float32 fraction = (*value - lo) / (hi - lo)
	if (fraction < 0.0): fraction = 0.0
	if (fraction > 1.0): fraction = 1.0
	# Label and value.
	char* shown = ftoa_fixed(*value, 2)
	char* text = strjoin(label, c" ")
	char* line = strjoin(text, shown)
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, r.x, ty, line, scale, ui_text_color(ctx))
	free(shown)
	free(text)
	free(line)
	# Track, fill and knob.
	ui_draw_rrect(ctx.rndr, track, 3.0, ctx.theme.widget)
	ui_draw_rrect(ctx.rndr, ui_rect_new(track.x, track.y, track.w * fraction, track.h), 3.0, ctx.theme.accent)
	ui_color knob_color = ctx.theme.accent
	if ((ctx.active == id) || (ctx.hot == id)): knob_color = ctx.theme.accent_hot
	ui_draw_disc(ctx.rndr, ui_rect_new(track.x + track.w * fraction - knob * 0.5, r.y + r.h * 0.5 - knob * 0.5, knob, knob), knob_color)
	return changed


# The left-hand controls; returns 1 when any setting changed.
int photo_controls(ui_context* ctx, photo_settings* s, int32* lut_choice, int* save):
	int changed = 0
	ui_title(ctx, c"photo_viewer")
	changed = changed | photo_slider(ctx, c"Brightness", &s.brightness, 0.0 - 0.5, 0.5)
	changed = changed | photo_slider(ctx, c"Contrast", &s.contrast, 0.0, 2.0)
	changed = changed | photo_slider(ctx, c"Saturation", &s.saturation, 0.0, 2.0)
	changed = changed | photo_slider(ctx, c"Gamma", &s.gamma, 0.3, 3.0)
	changed = changed | photo_slider(ctx, c"Blur", &s.blur, 0.0, 16.0)
	changed = changed | photo_slider(ctx, c"Sharpen", &s.sharpen, 0.0, 2.0)
	changed = changed | photo_slider(ctx, c"Vignette", &s.vignette, 0.0, 1.0)
	changed = changed | photo_slider(ctx, c"LUT amount", &s.lut_amount, 0.0, 1.0)
	int32 before = *lut_choice
	ui_radio(ctx, c"no grade", 0, lut_choice)
	ui_radio(ctx, c"warm", 1, lut_choice)
	ui_radio(ctx, c"cool", 2, lut_choice)
	ui_radio(ctx, c"sepia", 3, lut_choice)
	ui_radio(ctx, c"mono", 4, lut_choice)
	if (*lut_choice != before):
		# Choice index i > 0 is preset i (FX_LUT_WARM .. FX_LUT_MONO).
		if (*lut_choice == 0): s.lut_preset = 0 - 1
		else: s.lut_preset = *lut_choice
		changed = 1
	if (ui_checkbox(ctx, c"edge detect", &s.edges)): changed = 1
	if (ui_checkbox(ctx, c"emboss", &s.emboss)): changed = 1
	if (ui_button(ctx, c"Save")): *save = 1
	return changed


# Run the chain over the source image; returns new RGBA pixels (GPU,
# falling back to the CPU reference) and frees the previous chain.
char* photo_process(fx_gl* g, photo_settings* s, rgba_image* image, int* passes):
	list[fx_effect*] chain = photo_build_chain(s)
	*passes = chain.length
	char* pixels = fx_gl_run_pixels(g, chain, image.pixels, image.width, image.height)
	if (pixels == 0): pixels = fx_cpu_run(chain, image.pixels, image.width, image.height)
	for i in range(chain.length): fx_gl_release_effect(chain[i])
	photo_free_chain(chain)
	return pixels


# The window's pixels as a top-down PNG.
int photo_screenshot(char* path, int width, int height):
	char* pixels = cast(char*, malloc(width * height * 4))
	glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels)
	char* flipped = cast(char*, malloc(width * height * 4))
	for y in range(height):
		char* src = &pixels[(height - 1 - y) * width * 4]
		char* dst = &flipped[y * width * 4]
		for i in range(width * 4): dst[i] = src[i]
	int ok = photo_write_png(path, width, height, flipped)
	free(pixels)
	free(flipped)
	return ok


int main(int argc, int argv):
	args_init(argc, argv)
	photo_settings settings
	if (photo_settings_from_args(&settings) == 0): return 2
	int max_frames = 0
	char* frames_value = args_value(c"frames")
	if (frames_value != 0): max_frames = atoi(frames_value)
	char* shot_path = args_value(c"screenshot")
	char* out_path = args_value(c"out")
	if (out_path == 0): out_path = c"photo_viewer_out.png"
	if (args_positional_count() != 1):
		println2(c"usage: photo_viewer IN [--out OUT.png] [--frames N --screenshot SHOT.png] [photo_fx effect flags]")
		return 2
	rgba_image* image = photo_load(args_positional(0))
	if (image == 0): return 1

	gfx_window* win = gfx_window_open(c"W photo viewer", 1000, 680)
	if (win == 0):
		if (max_frames > 0):
			test_skip(c"photo_viewer SKIP (no display)")
			return 0
		return 1
	ui_renderer rndr
	if (ui_render_init(&rndr) == 0): return 1
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &rndr, &theme)
	fx_gl g
	fx_gl_init(&g)

	int32 lut_choice = 0
	if (settings.lut_preset > 0): lut_choice = settings.lut_preset
	int passes = 0
	char* processed = photo_process(&g, &settings, image, &passes)
	ui_image* shown = ui_image_create(&rndr, image.width, image.height, processed, image.width * image.height * 4)
	int dirty = 0
	char* status = c""
	int frame = 0
	while (gfx_window_poll(win)):
		if (dirty):
			free(processed)
			processed = photo_process(&g, &settings, image, &passes)
			ui_image_update(shown, processed, image.width * image.height * 4)
			dirty = 0
		ui_begin_window(&ctx, win)
		int save = 0
		if (photo_controls(&ctx, &settings, &lut_choice, &save)): dirty = 1
		if (save):
			if (photo_write_png(out_path, image.width, image.height, processed)): status = c"saved"
			else: status = c"save failed"
		ui_status(&ctx, status)
		# The image, fitted into the area right of the panel.
		float32 area_x = cast(float32, photo_panel_width)
		float32 area_w = cast(float32, win.width) - area_x - 16.0
		float32 area_h = cast(float32, win.height) - 32.0
		float32 fit = area_w / cast(float32, image.width)
		if (area_h / cast(float32, image.height) < fit): fit = area_h / cast(float32, image.height)
		float32 draw_w = cast(float32, image.width) * fit
		float32 draw_h = cast(float32, image.height) * fit
		ui_draw_image(&rndr, shown, ui_rect_new(area_x + (area_w - draw_w) * 0.5, 16.0 + (area_h - draw_h) * 0.5, draw_w, draw_h), 1.0)
		ui_end(&ctx)
		frame = frame + 1
		int last = (max_frames > 0) && (frame >= max_frames)
		if (last && (shot_path != 0)):
			glFinish()
			if (photo_screenshot(shot_path, win.width, win.height) == 0):
				print_error(c"photo_viewer: screenshot write failed\n")
				return 1
		gfx_window_swap(win)
		sleep_ms(16)
		if (last): break
	if (max_frames > 0):
		print(c"photo_viewer: ")
		print(itoa(frame))
		print(c" frames, ")
		print(itoa(passes))
		println(c" passes")
	ui_image_release(shown)
	free(processed)
	fx_gl_destroy(&g)
	ui_render_destroy(&rndr)
	rgba_image_free(image)
	gfx_window_destroy(win)
	return 0
