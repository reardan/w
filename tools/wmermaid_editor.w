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
	mm_editor* e = mm_editor_open(path)
	if (e == 0):
		println2(c"cannot open source (I/O, size limit or embedded NUL)")
		return 1
	ui_textarea_state area
	ui_textarea_init(&area)
	ui_textarea_set(&area, e.document.source)
	ui_textarea_state filename
	ui_textarea_init(&filename)
	ui_textarea_set(&filename, path)
	ui_textbox_state node_id
	ui_textbox_state node_label
	ui_textbox_state edge_from
	ui_textbox_state edge_to
	ui_textbox_init(&node_id)
	ui_textbox_init(&node_label)
	ui_textbox_init(&edge_from)
	ui_textbox_init(&edge_to)
	gfx_window* win = gfx_window_open(c"W Mermaid", 1280, 800)
	if (win == 0):
		mm_editor_free(e)
		ui_textarea_free(&area)
		ui_textarea_free(&filename)
		return 1
	ui_renderer renderer
	if (ui_render_init(&renderer) == 0):
		gfx_window_destroy(win)
		mm_editor_free(e)
		ui_textarea_free(&area)
		ui_textarea_free(&filename)
		return 1
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &renderer, &theme)
	char* status = c"Ctrl+S save; Ctrl+Z undo; Ctrl+Y redo; Ctrl+L path; Ctrl+E source."
	int focus_source = 1
	int external = 0
	int reloading = 0
	int focus_inspector = 0
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
		if (frame % 60 == 0): external = mm_editor_external_change(e)
		for i in range(ctx.char_count):
			int key = ctx.chars[i]
			if (ctx.char_mods[i] & (GFX_MOD_CTRL | GFX_MOD_SUPER)):
				if (key >= 'A' && key <= 'Z'): key = key + 32
				if (key > 0 && key < 27): key = key + 96
				if (key == 's'):
					if (mm_editor_save(e)):
						status = c"Saved."
						external = 0
					else: status = c"Save failed or file changed externally. Reload or Save as a new path."
				else if (key == 'z' || key == 'y'):
					int redo = key == 'y' || (ctx.char_mods[i] & GFX_MOD_SHIFT) != 0
					if (mm_editor_undo(e, redo)): ui_textarea_set(&area, e.document.source)
				else if (key == 'l'): ctx.focus = ctx.next_id
				else if (key == 'e'): focus_source = 1
				else if (key >= '1' && key <= '4'): focus_inspector = key - '0'
				else if (key == 'n'):
					if (mm_editor_add_node(e, &node_id.text[0], &node_label.text[0])):
						ui_textarea_set(&area, e.document.source)
						fit = 1
					else: status = c"Add node failed: requires a flowchart, unused ID and plain label."
				else if (key == 'k'):
					if (mm_editor_add_edge(e, &edge_from.text[0], &edge_to.text[0])):
						ui_textarea_set(&area, e.document.source)
						fit = 1
					else: status = c"Connect requires two existing flowchart node IDs."
				else if (key == '0'): fit = 1
				else if (key == '+' || key == '='): zoom = zoom * 1.25
				else if (key == '-'): zoom = zoom / 1.25
				else: continue
				ctx.chars[i] = 0
		float32 width = cast(float32, win.width)
		float32 height = cast(float32, win.height)
		ui_region_push(&ctx, ui_rect_new(12.0, 10.0, width - 24.0, 34.0))
		ui_textarea(&ctx, ui_layout_next(&ctx, 400.0, 34.0), &filename)
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Open")):
			if (mm_editor_dirty(e)): status = c"Save changes before opening another file."
			else:
				mm_editor* loaded = mm_editor_open(filename.buf.data)
				if (loaded == 0): status = c"Open failed: unreadable file, embedded NUL or source limit."
				else:
					mm_editor_free(e)
					e = loaded
					ui_textarea_set(&area, e.document.source)
					status = c"Opened."
					external = 0
					reloading = 0
					fit = 1
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Save")):
			if (mm_editor_save(e)): status = c"Saved."
			else: status = c"Save failed or file changed externally. Reload or Save as a new path."
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Save as")):
			if (mm_editor_save_as(e, filename.buf.data)): status = c"Saved to the path field."
			else: status = c"Save as failed: destination must be a new file."
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
		if (ui_button(&ctx, c"Previous diagram")):
			if (mm_editor_select(e, e.selected - 1)): fit = 1
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Next diagram")):
			if (mm_editor_select(e, e.selected + 1)): fit = 1
		ui_same_line(&ctx)
		char* reload_label = c"Reload"
		if (reloading): reload_label = c"Discard edits + reload"
		if (ui_button(&ctx, reload_label)):
			if (mm_editor_dirty(e) && reloading == 0):
				reloading = 1
				status = c"Click Discard edits + reload to replace unsaved edits with the file on disk."
			else if (mm_editor_reload(e)):
				ui_textarea_set(&area, e.document.source)
				external = 0
				reloading = 0
				fit = 1
				status = c"Reloaded from disk."
			else: status = c"Reload failed."
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Fit")): fit = 1
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Zoom +")): zoom = zoom * 1.25
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Zoom -")): zoom = zoom / 1.25
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Close")): closing = 1
		ui_same_line(&ctx)
		if (external): ui_label(&ctx, c"File changed externally")
		else if (mm_editor_dirty(e)): ui_label(&ctx, c"Unsaved changes")
		else: ui_label(&ctx, c"Saved")
		ui_region_pop(&ctx)
		ui_region_push(&ctx, ui_rect_new(12.0, 94.0, width - 24.0, 34.0))
		ui_label(&ctx, c"Node ID")
		ui_same_line(&ctx)
		if (focus_inspector == 1):
			ctx.focus = ctx.next_id
			focus_inspector = 0
		ui_textbox(&ctx, 100.0, &node_id)
		ui_same_line(&ctx)
		ui_label(&ctx, c"Label")
		ui_same_line(&ctx)
		if (focus_inspector == 2):
			ctx.focus = ctx.next_id
			focus_inspector = 0
		ui_textbox(&ctx, 160.0, &node_label)
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Add node")):
			if (mm_editor_add_node(e, &node_id.text[0], &node_label.text[0])):
				ui_textarea_set(&area, e.document.source)
				fit = 1
				status = c"Node added; Ctrl+Z to undo."
			else: status = c"Requires a valid flowchart, unused ID and label without quotes or controls."
		ui_same_line(&ctx)
		ui_label(&ctx, c"From")
		ui_same_line(&ctx)
		if (focus_inspector == 3):
			ctx.focus = ctx.next_id
			focus_inspector = 0
		ui_textbox(&ctx, 100.0, &edge_from)
		ui_same_line(&ctx)
		ui_label(&ctx, c"To")
		ui_same_line(&ctx)
		if (focus_inspector == 4):
			ctx.focus = ctx.next_id
			focus_inspector = 0
		ui_textbox(&ctx, 100.0, &edge_to)
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Connect")):
			if (mm_editor_add_edge(e, &edge_from.text[0], &edge_to.text[0])):
				ui_textarea_set(&area, e.document.source)
				fit = 1
				status = c"Connection added; Ctrl+Z to undo."
			else: status = c"Connect requires two existing flowchart node IDs."
		ui_region_pop(&ctx)
		if (zoom < 0.05): zoom = 0.05
		if (zoom > 4.0): zoom = 4.0
		float32 split = width * 0.38
		ui_rect source_rect = ui_rect_new(12.0, 142.0, split - 24.0, height - 220.0)
		if (focus_source):
			ctx.focus = ctx.next_id
			focus_source = 0
		if (ui_textarea(&ctx, source_rect, &area)):
			if (mm_editor_change(e, area.buf.data) == 0):
				ui_textarea_set(&area, e.document.source)
				status = c"Edit exceeds the 1 MiB source limit."
		ui_rect preview = ui_rect_new(split, 142.0, width - split - 12.0, height - 220.0)
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
			int hit = mm_editor_hit(e, cast(int, (ctx.input.mouse_x - preview.x - pan_x) / zoom), cast(int, (ctx.input.mouse_y - preview.y - pan_y) / zoom))
			if (hit >= 0):
				mm_node* node = e.document.nodes[hit]
				ui_textbox_set(&node_id, node.id)
				ui_textbox_set(&node_label, node.label)
				if (edge_from.length == 0 || edge_to.length > 0):
					ui_textbox_set(&edge_from, node.id)
					ui_textbox_set(&edge_to, c"")
				else: ui_textbox_set(&edge_to, node.id)
				status = c"Click another node, then Connect (Ctrl+K). Ctrl+1..4 focus structured fields; Ctrl+N adds a node."
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
	ui_textarea_free(&filename)
	mm_editor_free(e)
	return exit_status
