# wbuild: binary=wmermaid_editor arch=x64 tag=tests
# wbuild: target=mermaid_editor_platforms tag=tests dep=wv2
# wbuild: step="bin/wv2 win64 tools/wmermaid_editor.w -o bin/wmermaid_editor_win.exe"
# wbuild: step="bin/wv2 arm64_darwin tools/wmermaid_editor.w -o bin/wmermaid_editor_darwin"
# wbuild: target=mermaid_editor_ui_test dep=wmermaid_editor dep=wmermaid dep=mermaid_editor_ui_driver
# wbuild: step="xvfb-run -a bin/mermaid_editor_ui_driver"
# Native desktop editor. Optional --frames N / --screenshot FILE for QA.
import lib.args
import lib.time
import libs.extras.mermaid.editor
import graphics.mermaid_canvas
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

const int WM_CANVAS_FOCUS = 900001

# Mirror a selection into fields only on selection changes, preserving typing.
void wm_selection_fields(mm_canvas* canvas, mm_editor* e, ui_textbox_state* id, ui_textarea_state* label):
	if (canvas.node < 0 || canvas.node >= e.document.nodes.length): return
	ui_textbox_set(id, e.document.nodes[canvas.node].id)
	ui_textarea_set(label, e.document.nodes[canvas.node].label)

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
	mm_canvas_source_sync(&area, e.document.source)
	ui_textarea_state filename
	ui_textarea_init(&filename)
	ui_textarea_set(&filename, path)
	ui_textbox_state node_id
	ui_textarea_state node_label
	ui_textbox_init(&node_id)
	ui_textarea_init(&node_label)
	gfx_window* win = gfx_window_open(c"W Mermaid", 1280, 800)
	if (win == 0):
		mm_editor_free(e)
		ui_textarea_free(&area)
		ui_textarea_free(&filename)
		ui_textarea_free(&node_label)
		return 1
	ui_renderer renderer
	if (ui_render_init(&renderer) == 0):
		gfx_window_destroy(win)
		mm_editor_free(e)
		ui_textarea_free(&area)
		ui_textarea_free(&filename)
		ui_textarea_free(&node_label)
		return 1
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &renderer, &theme)
	mm_canvas canvas
	mm_canvas_init(&canvas)
	ui_split_state splitter
	ui_split_init(&splitter, 435.0)
	splitter.min_a = 300.0
	splitter.min_b = 260.0
	char* status = c"Click a node to edit. Drag nodes to move; drag background to pan."
	int focus_source = 1
	int focus_label = 0
	int label_focus_id = 0
	int focus_id = 0
	int external = 0
	int reloading = 0
	int fit = 1
	int closing = 0
	int finished = 0
	int frame = 0
	int max_frames = 0
	char* frames = args_value(c"frames")
	if (frames != 0): max_frames = atoi(frames)
	int exit_status = 0
	int last_source_time = 0
	while (finished == 0):
		if (gfx_window_poll(win) == 0):
			if (mm_editor_dirty(e) == 0): break
			win.should_close = 0
			closing = 1
		ui_begin_window(&ctx, win)
		if (frame % 60 == 0): external = mm_editor_external_change(e)
		float32 width = cast(float32, win.width)
		float32 height = cast(float32, win.height)
		float32 preview_width = width - splitter.pos - 30.0
		float32 preview_height = height - 204.0
		if (ctx.input.mouse_pressed && (canvas.move_here || canvas.connect_from >= 0)):
			ui_rect canvas_area = ui_rect_new(18.0 + splitter.pos, 134.0, preview_width, preview_height)
			if (ui_rect_contains(canvas_area, ctx.input.press_x, ctx.input.press_y) == 0): mm_canvas_cancel(&canvas, e)
		int now = time_monotonic_ms()
		if (ctx.input.mouse_pressed || ctx.nav_count > 0): last_source_time = 0
		int old_selection = canvas.node
		int changed = 0
		for i in range(ctx.char_count):
			int key = ctx.chars[i]
			if (key == 27):
				mm_canvas_cancel(&canvas, e)
				closing = 0
				status = c"Canceled."
				ctx.chars[i] = 0
				continue
			if (closing): continue
			if (ctx.char_mods[i] & (GFX_MOD_CTRL | GFX_MOD_SUPER)):
				last_source_time = 0
				if ((key == 13 || key == 10) && canvas.node >= 0 && ctx.focus == label_focus_id):
					if (mm_editor_set_label(e, canvas.node, node_label.buf.data)):
						changed = 1
						status = c"Label updated. Ctrl+Z to undo."
					else: status = c"Label unavailable for this source; edit the source field."
					ctx.chars[i] = 0
					continue
				if (key >= 'A' && key <= 'Z'): key = key + 32
				if (key > 0 && key < 27): key = key + 96
				if (key == 's'):
					mm_canvas_cancel(&canvas, e)
					if (mm_editor_save(e)):
						status = c"Saved."
						external = 0
					else: status = c"File changed or save failed. Reload or Save as a new path."
				else if (key == 'z' || key == 'y'):
					int redo = key == 'y' || (ctx.char_mods[i] & GFX_MOD_SHIFT) != 0
					changed = mm_canvas_undo(&canvas, e, redo)
					wm_selection_fields(&canvas, e, &node_id, &node_label)
				else if (key == 'l'):
					mm_canvas_cancel(&canvas, e)
					ctx.focus = ctx.next_id
				else if (key == 'e'):
					mm_canvas_cancel(&canvas, e)
					ctx.focus = 0
					focus_source = 1
				else if (key == 'd'): ctx.focus = WM_CANVAS_FOCUS
				else if (key == '2' || key == 'r'):
					mm_canvas_cancel(&canvas, e)
					ctx.focus = 0
					focus_label = 1
				else if (key == 'n'):
					mm_canvas_reset(&canvas, e)
					ui_textbox_set(&node_id, c"")
					ui_textarea_set(&node_label, c"")
					focus_id = 1
				else if (key == 'q'): closing = 1
				else if (key == '0'): fit = 1
				else if (key == '+' || key == '='): mm_canvas_zoom(&canvas, 1.25, preview_width / 2.0, preview_height / 2.0)
				else if (key == '-'): mm_canvas_zoom(&canvas, 0.8, preview_width / 2.0, preview_height / 2.0)
				else: continue
				ctx.chars[i] = 0
			else if (ctx.focus == WM_CANVAS_FOCUS):
				if (key == 9): mm_canvas_cycle(&canvas, e, ctx.char_mods[i] & GFX_MOD_SHIFT)
				ctx.chars[i] = 0
		if (ctx.focus == WM_CANVAS_FOCUS && closing == 0 && canvas.gesture == 0):
			for i in range(ctx.nav_count):
				int key = ctx.navs[i]
				int step = 1
				if (ctx.nav_mods[i] & GFX_MOD_SHIFT): step = 10
				if (key == GFX_NAV_DELETE): changed = mm_canvas_delete(&canvas, e) || changed
				else if (key == GFX_NAV_LEFT): changed = mm_canvas_nudge(&canvas, e, 0 - step, 0) || changed
				else if (key == GFX_NAV_RIGHT): changed = mm_canvas_nudge(&canvas, e, step, 0) || changed
				else if (key == GFX_NAV_UP): changed = mm_canvas_nudge(&canvas, e, 0, 0 - step) || changed
				else if (key == GFX_NAV_DOWN): changed = mm_canvas_nudge(&canvas, e, 0, step) || changed
				ctx.navs[i] = 0
		if (changed): mm_canvas_source_sync(&area, e.document.source)
		if (old_selection != canvas.node): wm_selection_fields(&canvas, e, &node_id, &node_label)
		ui_disable(&ctx, closing)
		ui_region_push(&ctx, ui_rect_new(12.0, 10.0, width - 24.0, 34.0))
		float32 path_width = width - 320.0
		if (path_width < 100.0): path_width = 100.0
		ui_textarea(&ctx, ui_layout_next(&ctx, path_width, 34.0), &filename)
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Open")):
			if (mm_editor_dirty(e)): status = c"Save changes before opening another file."
			else:
				mm_editor* loaded = mm_editor_open(filename.buf.data)
				if (loaded == 0): status = c"Open failed: unreadable file or source limit."
				else:
					mm_canvas_reset(&canvas, e)
					mm_editor_free(e)
					e = loaded
					mm_canvas_source_sync(&area, e.document.source)
					status = c"Opened."
					external = 0
					reloading = 0
					fit = 1
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Save")):
			if (mm_editor_save(e)): status = c"Saved."
			else: status = c"File changed or save failed. Reload or Save as a new path."
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Save as")):
			if (mm_editor_save_as(e, filename.buf.data)): status = c"Saved to the path field."
			else: status = c"Save as needs a new destination path."
		ui_region_pop(&ctx)
		ui_region_push(&ctx, ui_rect_new(12.0, 52.0, width - 24.0, 34.0))
		ui_disable(&ctx, closing || e.position == 0)
		if (ui_button(&ctx, c"Undo")):
			if (mm_canvas_undo(&canvas, e, 0)): mm_canvas_source_sync(&area, e.document.source)
			wm_selection_fields(&canvas, e, &node_id, &node_label)
		ui_same_line(&ctx)
		ui_disable(&ctx, closing || e.position + 1 >= e.history.length)
		if (ui_button(&ctx, c"Redo")):
			if (mm_canvas_undo(&canvas, e, 1)): mm_canvas_source_sync(&area, e.document.source)
			wm_selection_fields(&canvas, e, &node_id, &node_label)
		ui_disable(&ctx, closing)
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Fit")): fit = 1
		ui_same_line(&ctx)
		ui_disable(&ctx, closing || mm_editor_has_positions(e) == 0)
		if (ui_button(&ctx, c"Auto layout")):
			mm_canvas_cancel(&canvas, e)
			if (mm_editor_reset_positions(e)):
				mm_canvas_source_sync(&area, e.document.source)
				fit = 1
				status = c"Automatic layout restored. Ctrl+Z restores manual positions."
		ui_disable(&ctx, closing)
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"+")): mm_canvas_zoom(&canvas, 1.25, preview_width / 2.0, preview_height / 2.0)
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"-")): mm_canvas_zoom(&canvas, 0.8, preview_width / 2.0, preview_height / 2.0)
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"SVG")):
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
		ui_same_line(&ctx)
		if (ui_button(&ctx, c"Close")): closing = 1
		ui_same_line(&ctx)
		if (external): ui_label(&ctx, c"Changed on disk")
		else if (mm_editor_dirty(e)): ui_label(&ctx, c"Unsaved")
		else: ui_label(&ctx, c"Saved")
		ui_region_pop(&ctx)
		ui_region_push(&ctx, ui_rect_new(12.0, 92.0, width - 24.0, 34.0))
		int diagrams = mm_source_diagram_count(e.document.source, e.document.length)
		ui_disable(&ctx, closing || e.selected <= 0)
		if (ui_button(&ctx, c"Previous")):
			mm_canvas_reset(&canvas, e)
			if (mm_editor_select(e, e.selected - 1)): fit = 1
		ui_same_line(&ctx)
		ui_disable(&ctx, closing || e.selected + 1 >= diagrams)
		if (ui_button(&ctx, c"Next")):
			mm_canvas_reset(&canvas, e)
			if (mm_editor_select(e, e.selected + 1)): fit = 1
		ui_same_line(&ctx)
		ui_disable(&ctx, closing)
		char* reload_label = c"Reload"
		if (reloading): reload_label = c"Discard + reload"
		if (ui_button(&ctx, reload_label)):
			if (mm_editor_dirty(e) && reloading == 0):
				reloading = 1
				status = c"Click Discard + reload to replace unsaved changes."
			else:
				mm_canvas_reset(&canvas, e)
				if (mm_editor_reload(e)):
					mm_canvas_source_sync(&area, e.document.source)
					external = 0
					reloading = 0
					fit = 1
					status = c"Reloaded."
				else: status = c"Reload failed."
		ui_same_line(&ctx)
		string_builder* counter = string_from(c"Diagram ")
		string_append_int(counter, e.selected + 1)
		string_append(counter, c" / ")
		string_append_int(counter, diagrams)
		ui_label(&ctx, counter.data)
		string_free(counter)
		ui_region_pop(&ctx)
		ui_rect left
		ui_rect preview
		ui_split(&ctx, ui_rect_new(12.0, 134.0, width - 24.0, height - 204.0), 1, &splitter, &left, &preview)
		ui_clip_push(&renderer, left)
		ui_region_push(&ctx, ui_rect_new(left.x, left.y, left.w - 8.0, 212.0))
		char* selection_text = c"New node / selection"
		if (canvas.node >= 0): selection_text = c"Selected node"
		else if (canvas.edge >= 0): selection_text = c"Selected connection"
		ui_label(&ctx, selection_text)
		ui_same_line(&ctx)
		ui_disable(&ctx, closing || mm_graph_edit_family(e.document.kind) == 0)
		if (ui_button(&ctx, c"New")):
			mm_canvas_reset(&canvas, e)
			ui_textbox_set(&node_id, c"")
			ui_textarea_set(&node_label, c"")
			focus_id = 1
		ui_disable(&ctx, closing)
		ui_label(&ctx, c"ID")
		ui_same_line(&ctx)
		ui_disable(&ctx, closing || canvas.node >= 0)
		if (focus_id):
			ctx.focus = ctx.next_id
			focus_id = 0
		ui_textbox(&ctx, left.w - 64.0, &node_id)
		ui_disable(&ctx, closing)
		ui_label(&ctx, c"Label")
		ui_same_line(&ctx)
		if (focus_label):
			ctx.focus = ctx.next_id
			focus_label = 0
		label_focus_id = ctx.next_id
		ui_textarea(&ctx, ui_layout_next(&ctx, left.w - 112.0, 34.0), &node_label)
		int can_add = e.document.error == 0 && mm_graph_edit_family(e.document.kind) && mm_editor_identifier(&node_id.text[0]) && mm_find_node(e.document, &node_id.text[0]) < 0
		ui_disable(&ctx, closing || can_add == 0)
		if (ui_button(&ctx, c"Add")):
			if (mm_editor_add_graph_node(e, &node_id.text[0], node_label.buf.data)):
				canvas.node = mm_find_node(e.document, &node_id.text[0])
				canvas.edge = -1
				mm_canvas_source_sync(&area, e.document.source)
				status = c"Node added. Fit to see the whole diagram."
			else: status = c"Use a plain label without quotes or controls."
		ui_same_line(&ctx)
		char* label_reason = mm_editor_edit_reason(e, MM_EDIT_LABEL, canvas.node)
		ui_disable(&ctx, closing || label_reason[0] != 0)
		if (ui_button(&ctx, c"Apply")):
			if (mm_editor_set_label(e, canvas.node, node_label.buf.data)):
				mm_canvas_source_sync(&area, e.document.source)
				status = c"Label updated. Ctrl+Z to undo."
			else: status = c"Label cannot be represented here; use source editing."
		ui_same_line(&ctx)
		int operation = MM_EDIT_NODE_DELETE
		int selected_index = canvas.node
		if (canvas.edge >= 0):
			operation = MM_EDIT_EDGE_DELETE
			selected_index = canvas.edge
		char* delete_reason = mm_editor_edit_reason(e, operation, selected_index)
		ui_disable(&ctx, closing || delete_reason[0] != 0)
		if (ui_button(&ctx, c"Delete")):
			if (mm_canvas_delete(&canvas, e)):
				mm_canvas_source_sync(&area, e.document.source)
				status = c"Deleted with incident connections. Ctrl+Z to undo."
			else: status = c"This deletion cannot be represented safely here (e.g. it reaches inside a composite or namespace); use source editing."
		ui_disable(&ctx, closing || mm_editor_can_move(e, canvas.node) == 0)
		if (ui_button(&ctx, c"Move here")):
			canvas.move_here = 1
			canvas.connect_from = -1
			ctx.focus = WM_CANVAS_FOCUS
			status = c"Click the new top-left position. Escape cancels."
		ui_same_line(&ctx)
		ui_disable(&ctx, closing || canvas.node < 0 || mm_graph_edit_family(e.document.kind) == 0)
		if (ui_button(&ctx, c"Link to")):
			canvas.connect_from = canvas.node
			canvas.move_here = 0
			ctx.focus = WM_CANVAS_FOCUS
			status = c"Click the destination node. Escape cancels."
			if (e.document.kind == MM_ER): status = c"Click target: one-to-many relates. Edit cardinality and label in source."
			if (e.document.kind == MM_CLASS): status = c"Click target: adds an association. Edit relationship kind in source."
		ui_disable(&ctx, closing)
		ui_region_pop(&ctx)
		float32 source_y = left.y + 218.0
		ui_draw_text(&renderer, left.x, source_y, c"Source  (Ctrl+E)", 2, theme.text_muted)
		source_y = source_y + 24.0
		ui_rect source_rect = ui_rect_new(left.x, source_y, left.w - 8.0, left.h - 242.0)
		if (source_rect.h < 40.0): source_rect.h = 40.0
		if (focus_source):
			ctx.focus = ctx.next_id
			focus_source = 0
		if (ui_textarea(&ctx, source_rect, &area)):
			mm_canvas_reset(&canvas, e)
			int keep_group = last_source_time > 0 && now - last_source_time < 500
			last_source_time = now
			if (mm_editor_change_typing(e, area.buf.data, keep_group) == 0):
				mm_canvas_source_sync(&area, e.document.source)
				status = c"Edit exceeds the 1 MiB source limit."
		ui_clip_pop(&renderer)
		ui_render_rect(&renderer, preview, theme.surface)
		if (fit && e.scene != 0):
			mm_canvas_fit(&canvas, e.scene, preview.w, preview.h)
			fit = 0
		if (closing == 0):
			if (ctx.input.mouse_pressed && ui_rect_contains(preview, ctx.input.press_x, ctx.input.press_y)):
				ctx.focus = WM_CANVAS_FOCUS
				if (mm_canvas_press(&canvas, e, cast(float32, ctx.input.press_x) - preview.x, cast(float32, ctx.input.press_y) - preview.y)):
					mm_canvas_source_sync(&area, e.document.source)
					status = c"Updated. Ctrl+Z to undo."
				wm_selection_fields(&canvas, e, &node_id, &node_label)
				if (canvas.node >= 0 && mm_editor_can_move(e, canvas.node) == 0): status = c"This node can be edited in source; graphical movement is unavailable."
				else if (canvas.node >= 0): status = c"Ctrl+R edits the label; Apply or Ctrl+Enter saves it. New adds another node."
			if (canvas.gesture):
				mm_canvas_motion(&canvas, e, cast(float32, ctx.input.mouse_x) - preview.x, cast(float32, ctx.input.mouse_y) - preview.y)
				if (ctx.input.mouse_released):
					if (mm_canvas_release(&canvas, e)):
						mm_canvas_source_sync(&area, e.document.source)
						status = c"Moved. Ctrl+Z to undo the whole drag."
				else if (ctx.input.mouse_down == 0): mm_canvas_cancel(&canvas, e)
			if ((ctx.input.scroll_y != 0 || ctx.input.scroll_pixels_y != 0) && canvas.gesture == 0 && ui_rect_contains(preview, ctx.input.scroll_at_x, ctx.input.scroll_at_y)):
				float32 factor = 1.15
				if (ctx.input.scroll_y < 0): factor = 1.0 / factor
				if (ctx.input.scroll_pixels_y != 0):
					factor = 1.0 + fabs(cast(float32, ctx.input.scroll_pixels_y)) * 0.002
					if (ctx.input.scroll_pixels_y > 0): factor = 1.0 / factor
				mm_canvas_zoom(&canvas, factor, cast(float32, ctx.input.scroll_at_x) - preview.x, cast(float32, ctx.input.scroll_at_y) - preview.y)
				ctx.input.scroll_y = 0
				ctx.input.scroll_pixels_y = 0
		mm_canvas_render(&renderer, &canvas, e, preview, ctx.focus == WM_CANVAS_FOCUS)
		ui_clip_push(&renderer, ui_rect_new(12.0, height - 64.0, width - 24.0, 60.0))
		if (e.document.error != 0):
			char* diagnostic = mm_diagnostic(e.document)
			ui_draw_text(&renderer, 12.0, height - 62.0, diagnostic, 2, theme.error)
			free(diagnostic)
		else: ui_draw_text(&renderer, 12.0, height - 62.0, status, 2, theme.text_muted)
		char* help = c"Ctrl+D canvas: Tab selects, arrows move (Shift: 10), Delete removes. Wheel zooms."
		if (mm_graph_edit_family(e.document.kind) == 0): help = c"Preview and source editing for this family. Graphical editing: flowchart, ER, class and state."
		ui_draw_text(&renderer, 12.0, height - 38.0, help, 2, theme.text_muted)
		ui_clip_pop(&renderer)
		ui_disable(&ctx, 0)
		if (closing):
			mm_canvas_cancel(&canvas, e)
			if (mm_editor_dirty(e) == 0): finished = 1
			else:
				ui_render_rect(&renderer, ui_rect_new(12.0, height - 78.0, width - 24.0, 72.0), theme.surface)
				ui_region_push(&ctx, ui_rect_new(20.0, height - 62.0, width - 40.0, 40.0))
				ui_label(&ctx, c"Unsaved:")
				ui_same_line(&ctx)
				if (ui_button(&ctx, c"Save + close")):
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
	mm_canvas_cancel(&canvas, e)
	ui_render_destroy(&renderer)
	gfx_window_destroy(win)
	ui_textarea_free(&area)
	ui_textarea_free(&filename)
	ui_textarea_free(&node_label)
	mm_editor_free(e)
	return exit_status
