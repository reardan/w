# wbuild: binary=wmermaid_editor arch=x64 tag=tests
# Native Linux desktop editor. Optional --frames N / --screenshot FILE for QA.
import lib.args
import lib.time
import libs.extras.mermaid.editor
import graphics.mermaid
import graphics.ui.widgets

int wm_editor_ppm(char* path, int width, int height):
	char* pixels = cast(char*, malloc(width * height * 4))
	glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels)
	wstream* out = stream_open_write(path)
	if (out == 0):
		free(pixels)
		return 0
	stream_write_cstr(out, c"P6\n")
	stream_write_int(out, width)
	stream_write_cstr(out, c" ")
	stream_write_int(out, height)
	stream_write_cstr(out, c"\n255\n")
	char* row = cast(char*, malloc(width * 3))
	for y in range(height):
		for x in range(width):
			int offset = ((height - y - 1) * width + x) * 4
			for c in range(3): row[x * 3 + c] = pixels[offset + c]
		stream_write(out, row, width * 3)
	io_result result
	int ok = stream_close_checked(out, &result) == IO_OK
	free(row)
	free(pixels)
	return ok

int main(int argc, int argv):
	args_init(argc, argv)
	char* path = args_positional(0)
	if (path == 0):
		println2(c"usage: wmermaid_editor FILE.mmd [--frames N] [--screenshot FILE.ppm]")
		return 2
	if (strlen(path) > 127):
		println2(c"editor path field supports up to 127 UTF-8 bytes")
		return 2
	mm_document* input = mm_read(path)
	if (input == 0 || strlen(input.source) != input.length):
		println2(c"cannot open source (I/O, size limit or embedded NUL)")
		mm_document_free(input)
		return 1
	mm_editor* e = mm_editor_new(path, input.source)
	mm_document_free(input)
	ui_textarea_state area
	ui_textarea_init(&area)
	ui_textarea_set(&area, e.document.source)
	ui_textbox_state filename
	ui_textbox_init(&filename)
	ui_textbox_set(&filename, path)
	gfx_window* win = gfx_window_open(c"W Mermaid", 1280, 800)
	if (win == 0):
		mm_editor_free(e)
		ui_textarea_free(&area)
		return 1
	ui_renderer renderer
	if (ui_render_init(&renderer) == 0):
		gfx_window_destroy(win)
		mm_editor_free(e)
		ui_textarea_free(&area)
		return 1
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &renderer, &theme)
	char* status = c"Edit source on the left. Drag the preview to pan."
	float32 zoom = 1.0
	float32 pan_x = 0.0
	float32 pan_y = 0.0
	float32 last_x = 0.0
	float32 last_y = 0.0
	int dragging = 0
	int fit = 1
	int closing = 0
	int finished = 0
	int frame = 0
	int max_frames = 0
	char* frames = args_value(c"frames")
	if (frames != 0): max_frames = atoi(frames)
	int exit_status = 0
	while (finished == 0):
		if (gfx_window_poll(win) == 0):
			if (mm_editor_dirty(e) == 0): break
			win.should_close = 0
			closing = 1
		ui_begin_window(&ctx, win)
		float32 width = cast(float32, win.width)
		float32 height = cast(float32, win.height)
		ui_region_push(&ctx, ui_rect_new(12.0, 10.0, width - 24.0, 34.0))
		ui_textbox(&ctx, 400.0, &filename)
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Open")):
			if (mm_editor_dirty(e)): status = c"Save changes before opening another file."
			else:
				mm_document* loaded = mm_read(&filename.text[0])
				if (loaded == 0): status = c"Open failed: unreadable file or source limit."
				else if (strlen(loaded.source) != loaded.length): status = c"Open failed: embedded NUL."
				else:
					mm_editor_free(e)
					e = mm_editor_new(&filename.text[0], loaded.source)
					ui_textarea_set(&area, e.document.source)
					status = c"Opened."
					fit = 1
				mm_document_free(loaded)
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Save")):
			if (mm_editor_save(e)): status = c"Saved."
			else: status = c"Save failed. Changes remain in the editor."
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Save as")):
			char* old_path = e.path
			e.path = strclone(&filename.text[0])
			if (mm_editor_save(e)):
				free(old_path)
				status = c"Saved to the path field."
			else:
				free(e.path)
				e.path = old_path
				status = c"Save as failed."
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Undo")):
			if (mm_editor_undo(e, 0)): ui_textarea_set(&area, e.document.source)
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Redo")):
			if (mm_editor_undo(e, 1)): ui_textarea_set(&area, e.document.source)
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Export SVG")):
			char* svg = mm_svg(e.scene)
			if (svg == 0): status = c"Fix the syntax error before exporting."
			else:
				string_builder* output = string_from(e.path)
				string_append(output, c".svg")
				io_result result
				if (file_write_durable(output.data, svg, strlen(svg), &result) == IO_OK): status = c"Exported beside source as FILE.mmd.svg."
				else: status = c"SVG export failed."
				free(svg)
				string_free(output)
		ui_region_pop(&ctx)
		ui_region_push(&ctx, ui_rect_new(12.0, 52.0, width - 24.0, 34.0))
		if (ui_button(&ctx, c"Fit")): fit = 1
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Zoom +")): zoom = zoom * 1.25
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Zoom -")): zoom = zoom / 1.25
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Close")): closing = 1
		ui_same_line(&ctx)
		if (mm_editor_dirty(e)): ui_label(&ctx, c"Unsaved changes")
		else: ui_label(&ctx, c"Saved")
		ui_region_pop(&ctx)
		if (zoom < 0.05): zoom = 0.05
		if (zoom > 4.0): zoom = 4.0
		float32 split = width * 0.38
		ui_rect source_rect = ui_rect_new(12.0, 100.0, split - 24.0, height - 178.0)
		if (ui_textarea(&ctx, source_rect, &area)):
			if (mm_editor_change(e, area.buf.data) == 0):
				ui_textarea_set(&area, e.document.source)
				status = c"Edit exceeds the 1 MiB source limit."
		ui_rect preview = ui_rect_new(split, 100.0, width - split - 12.0, height - 178.0)
		ui_render_rect(&renderer, preview, theme.surface)
		if (fit && e.scene != 0):
			zoom = preview.w / cast(float32, e.scene.width)
			float32 zy = preview.h / cast(float32, e.scene.height)
			if (zy < zoom): zoom = zy
			if (zoom > 1.0): zoom = 1.0
			pan_x = 0.0
			pan_y = 0.0
			fit = 0
		if (ctx.input.mouse_pressed && ui_rect_contains(preview, ctx.input.mouse_x, ctx.input.mouse_y)):
			dragging = 1
			last_x = ctx.input.mouse_x
			last_y = ctx.input.mouse_y
		if (ctx.input.mouse_down == 0): dragging = 0
		if (dragging):
			pan_x = pan_x + ctx.input.mouse_x - last_x
			pan_y = pan_y + ctx.input.mouse_y - last_y
			last_x = ctx.input.mouse_x
			last_y = ctx.input.mouse_y
		mm_ui_render(&renderer, e.scene, preview, zoom, pan_x, pan_y)
		ui_clip_push(&renderer, ui_rect_new(12.0, height - 72.0, width - 24.0, 65.0))
		if (e.document.error != 0):
			char* diagnostic = mm_diagnostic(e.document)
			ui_draw_text(&renderer, 12.0, height - 68.0, diagnostic, 2, theme.error)
			free(diagnostic)
		else: ui_draw_text(&renderer, 12.0, height - 68.0, status, 2, theme.text_muted)
		ui_draw_text(&renderer, 12.0, height - 44.0, e.path, 2, theme.text_muted)
		ui_clip_pop(&renderer)
		if (closing):
			if (mm_editor_dirty(e) == 0): finished = 1
			else:
				ui_render_rect(&renderer, ui_rect_new(12.0, height - 78.0, width - 24.0, 72.0), theme.surface)
				ui_region_push(&ctx, ui_rect_new(20.0, height - 62.0, width - 40.0, 40.0))
				ui_label(&ctx, c"Unsaved changes:")
				ui_same_line(&ctx)
				if (ui_button(&ctx, c"Save and close")):
					if (mm_editor_save(e)): finished = 1
					else:
						closing = 0
						status = c"Save failed. Changes remain in the editor."
				ui_same_line(&ctx)
				if (ui_button(&ctx, c"Discard")): finished = 1
				ui_same_line(&ctx)
				if (ui_button(&ctx, c"Cancel")): closing = 0
				ui_region_pop(&ctx)
		ui_end(&ctx)
		frame = frame + 1
		if (max_frames > 0 && frame >= max_frames):
			char* shot = args_value(c"screenshot")
			if (shot != 0):
				glFinish()
				if (wm_editor_ppm(shot, win.width, win.height) == 0): exit_status = 1
			finished = 1
		gfx_window_swap(win)
		sleep_ms(16)
	ui_render_destroy(&renderer)
	gfx_window_destroy(win)
	ui_textarea_free(&area)
	mm_editor_free(e)
	return exit_status
