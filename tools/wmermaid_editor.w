# wbuild: binary=wmermaid_editor arch=x64 tag=tests
# wbuild: target=mermaid_editor_platforms tag=tests dep=wv2
# wbuild: step="bin/wv2 win64 tools/wmermaid_editor.w -o bin/wmermaid_editor_win.exe"
# wbuild: step="bin/wv2 arm64_darwin tools/wmermaid_editor.w -o bin/wmermaid_editor_darwin"
# wbuild: step="bin/wv2 arm64_darwin --import-root tools/mac/access_cocoa tools/wmermaid_editor.w -o bin/wmermaid_editor_darwin_voiceover"
# wbuild: target=mermaid_editor_ui_test dep=wmermaid_editor dep=wmermaid dep=mermaid_editor_ui_driver
# wbuild: step="xvfb-run -a bin/mermaid_editor_ui_driver"
# wbuild: target=mermaid_editor_wine_test dep=mermaid_editor_platforms dep=wmermaid dep=mermaid_editor_ui_driver
# wbuild: step="sh tools/mermaid_editor_wine_test.sh"
# wbuild: target=mermaid_editor_atspi_test dep=wmermaid_editor
# wbuild: step="sh tools/mermaid_editor_atspi_test.sh"
# wbuild: target=mermaid_editor_orca_test dep=wmermaid_editor
# wbuild: step="sh tools/mermaid_editor_atspi_test.sh --orca"
# Native desktop editor. Optional --frames N / --screenshot FILE for QA.
import lib.args
import lib.time
import libs.extras.mermaid.editor
import libs.extras.mermaid.edit_outline
import graphics.mermaid_canvas
import graphics.mermaid_access
import graphics.__arch__.access_platform
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
# Semantic ids past every canvas item id (graphics/mermaid_access.w).
const int WM_STATUS_ACCESS = 990001

char* wm_message

# The status line for a save attempt; never claims success on a conflict.
char* wm_save_message(mm_editor* e, int result):
	if (result == MM_SAVE_OK): return c"Saved."
	if (result == MM_SAVE_FAILED): return c"Save failed. Changes remain in the editor; try Save as."
	if (e.recovery_path == 0): return c"Not saved: the file changed on disk. Choose Reload from disk, or Keep mine and save again."
	free(wm_message)
	string_builder* text = string_from(c"Conflict: another program wrote the file during the save; its bytes were kept in ")
	string_append(text, e.recovery_path)
	wm_message = text.data
	free(text)
	return wm_message

char* wm_disk_message(int state):
	if (state == MM_DISK_MISSING): return c"The file was deleted on disk. Keep mine recreates it on save; nothing is written until then."
	return c"The file changed on disk. Reload from disk discards your edits; Keep mine overwrites it on the next save."

# Mirror a selection into fields only on selection changes, preserving typing.
void wm_selection_fields(mm_canvas* canvas, mm_editor* e, ui_textbox_state* id, ui_textarea_state* label):
	if (canvas.node < 0 && canvas.edge >= 0 && canvas.edge < e.document.edges.length):
		# A connection: the label field edits the connection label.
		ui_textbox_set(id, c"")
		char* text = e.document.edges[canvas.edge].label
		if (text == 0): text = c""
		ui_textarea_set(label, text)
		return
	if (canvas.node < 0 || canvas.node >= e.document.nodes.length): return
	ui_textbox_set(id, e.document.nodes[canvas.node].id)
	ui_textarea_set(label, e.document.nodes[canvas.node].label)

# Shift, Ctrl or Cmd on a canvas press extends the selection.
int wm_press_mods(int mods):
	if (mods & (GFX_MOD_SHIFT | GFX_MOD_CTRL | GFX_MOD_SUPER)): return MM_CANVAS_EXTEND
	return 0

# The group a structural command targets: the group id field, else -1.
int wm_group_target(mm_editor* e, ui_textbox_state* group):
	if (group.length == 0): return -1
	int index = mm_find_node(e.document, &group.text[0])
	if (index < 0 || e.document.nodes[index].group == 0): return -2
	return index

# ER inspector attribute text "type name [PK|FK|UK...]": split on blanks.
int wm_attribute_add(mm_editor* e, int index, char* text):
	list[char*] words = split(text)
	int ok = 0
	if (words.length >= 2):
		string_builder* keys = string_new()
		for i in range(2, words.length):
			if (keys.length > 0): string_append(keys, c",")
			string_append(keys, words[i])
		ok = mm_editor_attribute_add(e, index, words[0], words[1], keys.data, c"")
		string_free(keys)
	for char* word in words: free(word)
	__w_list_free(cast(__w_list*, words))
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
	mm_canvas_source_sync(&area, e.document.source)
	ui_textarea_state filename
	ui_textarea_init(&filename)
	ui_textarea_set(&filename, path)
	ui_textbox_state node_id
	ui_textarea_state node_label
	ui_textbox_init(&node_id)
	ui_textarea_init(&node_label)
	# Inspector fields: target group id and a member/attribute line.
	ui_textbox_state group_id
	ui_textbox_state member_text
	ui_textbox_init(&group_id)
	ui_textbox_init(&member_text)
	# The selected compartment line, edited in place (Ctrl+P focuses it and
	# then steps through the lines). A typing run is one undo step.
	ui_textbox_state line_text
	ui_textbox_init(&line_text)
	int line_index = 0
	int line_node = -1
	int line_resync = 1
	int line_focus_id = -1
	int focus_line = 0
	int line_position = -1
	int line_group = -1
	int line_time = 0
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
	# Screen-reader bridge (AT-SPI / UI Automation / opt-in NSAccessibility);
	# 0 when no assistive technology is reachable, and then nothing is built.
	int access_bridge = ui_access_platform_open(win, c"W Mermaid")
	ui_access_tree* access_published = 0
	ui_access_tree* access_fresh = 0
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
		if (access_bridge != 0):
			access_fresh = ui_access_tree_new(8192, 4194304)
			ui_access_capture(&ctx, access_fresh)
		ui_begin_window(&ctx, win)
		# Poll the fingerprint four times a second and the bytes every two.
		if (frame % 15 == 0 && closing == 0):
			int disk = mm_editor_poll(e, frame % 120 == 0)
			if (disk != MM_DISK_SAME && external == 0): status = wm_disk_message(disk)
			external = disk
		float32 width = cast(float32, win.width)
		float32 height = cast(float32, win.height)
		float32 preview_width = width - splitter.pos - 30.0
		float32 preview_height = height - 204.0
		if (ctx.input.mouse_pressed && (canvas.move_here || canvas.connect_from >= 0)):
			ui_rect canvas_area = ui_rect_new(18.0 + splitter.pos, 134.0, preview_width, preview_height)
			if (ui_rect_contains(canvas_area, ctx.input.press_x, ctx.input.press_y) == 0): mm_canvas_cancel(&canvas, e)
		int now = time_monotonic_ms()
		if (ctx.input.mouse_pressed || ctx.nav_count > 0): last_source_time = 0
		if (ctx.input.mouse_pressed): line_time = 0
		int old_selection = canvas.node
		int old_edge = canvas.edge
		int disk_reload = 0
		int disk_keep = 0
		if (mm_access_apply(&ctx, WM_CANVAS_FOCUS, &canvas, e)): status = c"Selected from the accessibility tree."
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
					int saved = mm_editor_save_checked(e)
					status = wm_save_message(e, saved)
					external = e.disk_state
				else if (key == 'r' && (ctx.char_mods[i] & GFX_MOD_SHIFT) != 0 && external == MM_DISK_CHANGED): disk_reload = 1
				else if (key == 'k' && external != MM_DISK_SAME): disk_keep = 1
				else if (key == 'z' || key == 'y'):
					int redo = key == 'y' || (ctx.char_mods[i] & GFX_MOD_SHIFT) != 0
					changed = mm_canvas_undo(&canvas, e, redo)
					wm_selection_fields(&canvas, e, &node_id, &node_label)
					line_resync = 1
				else if (key == 'p'):
					# Focus the compartment line field; again: the next line.
					mm_canvas_cancel(&canvas, e)
					if (line_focus_id > 0 && ctx.focus == line_focus_id): line_index = line_index + 1
					line_resync = 1
					focus_line = 1
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
				else if (key == 'a' && ctx.focus == WM_CANVAS_FOCUS):
					mm_canvas_select_all(&canvas, e)
					string_builder* count = string_new()
					string_append_int(count, mm_canvas_selection_count(&canvas, e))
					string_append(count, c" selected. Arrows move them; Delete removes them.")
					free(wm_message)
					wm_message = count.data
					free(count)
					status = wm_message
				else if (key == 'g' && ctx.focus == WM_CANVAS_FOCUS && canvas.node >= 0):
					if (mm_editor_ungroup(e, canvas.node)):
						mm_canvas_reset(&canvas, e)
						changed = 1
						status = c"Group removed; its members stay. Ctrl+Z to undo."
					else: status = c"Select a group to ungroup."
				else if (key == 'q'): closing = 1
				else if (key == '0'): fit = 1
				else if (key == '+' || key == '='): mm_canvas_zoom(&canvas, 1.25, preview_width / 2.0, preview_height / 2.0)
				else if (key == '-'): mm_canvas_zoom(&canvas, 0.8, preview_width / 2.0, preview_height / 2.0)
				else: continue
				ctx.chars[i] = 0
			else if (ctx.focus == WM_CANVAS_FOCUS):
				if (key == 9): mm_canvas_cycle(&canvas, e, ctx.char_mods[i] & GFX_MOD_SHIFT)
				else if (key == 32):
					mm_canvas_toggle_focused(&canvas, e)
					status = c"Space toggles the focused item; Tab moves on keeping the selection."
				ctx.chars[i] = 0
		if (ctx.focus == WM_CANVAS_FOCUS && closing == 0 && canvas.gesture == 0):
			for i in range(ctx.nav_count):
				int key = ctx.navs[i]
				int step = 1
				if (ctx.nav_mods[i] & GFX_MOD_SHIFT): step = 10
				if (key == GFX_NAV_DELETE): changed = mm_canvas_delete(&canvas, e) || changed
				else if (ctx.nav_mods[i] & GFX_MOD_ALT):
					# Alt+arrows resize the selected node (stored as @w-size).
					if (key == GFX_NAV_LEFT): changed = mm_canvas_grow(&canvas, e, 0 - step, 0) || changed
					else if (key == GFX_NAV_RIGHT): changed = mm_canvas_grow(&canvas, e, step, 0) || changed
					else if (key == GFX_NAV_UP): changed = mm_canvas_grow(&canvas, e, 0, 0 - step) || changed
					else if (key == GFX_NAV_DOWN): changed = mm_canvas_grow(&canvas, e, 0, step) || changed
				else if (key == GFX_NAV_LEFT): changed = mm_canvas_nudge(&canvas, e, 0 - step, 0) || changed
				else if (key == GFX_NAV_RIGHT): changed = mm_canvas_nudge(&canvas, e, step, 0) || changed
				else if (key == GFX_NAV_UP): changed = mm_canvas_nudge(&canvas, e, 0, 0 - step) || changed
				else if (key == GFX_NAV_DOWN): changed = mm_canvas_nudge(&canvas, e, 0, step) || changed
				ctx.navs[i] = 0
		if (changed): mm_canvas_source_sync(&area, e.document.source)
		if (old_selection != canvas.node || old_edge != canvas.edge): wm_selection_fields(&canvas, e, &node_id, &node_label)
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
			int saved = mm_editor_save_checked(e)
			status = wm_save_message(e, saved)
			external = e.disk_state
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
			line_resync = 1
		ui_same_line(&ctx)
		ui_disable(&ctx, closing || e.position + 1 >= e.history.length)
		if (ui_button(&ctx, c"Redo")):
			if (mm_canvas_undo(&canvas, e, 1)): mm_canvas_source_sync(&area, e.document.source)
			wm_selection_fields(&canvas, e, &node_id, &node_label)
			line_resync = 1
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
		if (external != MM_DISK_SAME):
			# The explicit choice an external change needs; saving stays refused.
			ui_same_line(&ctx)
			if (external == MM_DISK_MISSING): ui_label(&ctx, c"Deleted on disk:")
			else: ui_label(&ctx, c"Changed on disk:")
			ui_same_line(&ctx)
			ui_disable(&ctx, closing || external == MM_DISK_MISSING)
			if (ui_button(&ctx, c"Reload from disk")): disk_reload = 1
			ui_same_line(&ctx)
			ui_disable(&ctx, closing)
			if (ui_button(&ctx, c"Keep mine")): disk_keep = 1
			if (disk_reload && closing == 0):
				mm_canvas_reset(&canvas, e)
				if (mm_editor_reload(e)):
					mm_canvas_source_sync(&area, e.document.source)
					external = MM_DISK_SAME
					reloading = 0
					fit = 1
					status = c"Reloaded the disk version; Ctrl+Z cannot restore the discarded edits."
				else: status = c"Reload failed."
			else if (disk_keep && closing == 0):
				if (mm_editor_keep_mine(e)):
					external = MM_DISK_SAME
					status = c"Keeping your version. Save replaces the disk file."
				else: status = c"The disk file is unreadable; Save as a new path instead."
		ui_region_pop(&ctx)
		ui_rect left
		ui_rect preview
		ui_split(&ctx, ui_rect_new(12.0, 134.0, width - 24.0, height - 204.0), 1, &splitter, &left, &preview)
		ui_clip_push(&renderer, left)
		ui_region_push(&ctx, ui_rect_new(left.x, left.y, left.w - 8.0, 212.0))
		char* selection_text = c"New node / selection"
		int selected_count = mm_canvas_selection_count(&canvas, e)
		if (selected_count > 1): selection_text = c"Several selected"
		else if (canvas.node >= 0 && e.document.nodes[canvas.node].group): selection_text = c"Selected group"
		else if (canvas.node >= 0): selection_text = c"Selected node"
		else if (canvas.edge >= 0): selection_text = c"Selected connection"
		ui_label(&ctx, selection_text)
		ui_same_line(&ctx)
		int outline = mm_outline_family(e.document.kind)
		ui_disable(&ctx, closing || mm_canvas_edit_family(e.document.kind) == 0 || outline)
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
		int can_add = e.document.error == 0 && mm_canvas_edit_family(e.document.kind) && outline == 0 && mm_editor_identifier(&node_id.text[0]) && mm_find_node(e.document, &node_id.text[0]) < 0
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
		int edge_label = canvas.node < 0 && canvas.edge >= 0 && mm_editor_edge_editable(e, canvas.edge) && e.document.kind != MM_REQUIREMENT
		ui_disable(&ctx, closing || (label_reason[0] != 0 && edge_label == 0))
		if (ui_button(&ctx, c"Apply")):
			if (edge_label):
				if (mm_editor_edge_label(e, canvas.edge, node_label.buf.data)):
					mm_canvas_source_sync(&area, e.document.source)
					status = c"Connection label updated. Ctrl+Z to undo."
				else: status = c"Connection label cannot be represented here; use source editing."
			else if (mm_editor_set_label(e, canvas.node, node_label.buf.data)):
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
		if (selected_count > 1): delete_reason = c""
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
		ui_disable(&ctx, closing || canvas.node < 0 || mm_canvas_edit_family(e.document.kind) == 0 || outline)
		if (ui_button(&ctx, c"Link to")):
			canvas.connect_from = canvas.node
			canvas.move_here = 0
			ctx.focus = WM_CANVAS_FOCUS
			status = c"Click the destination node. Escape cancels."
			if (e.document.kind == MM_ER): status = c"Click target: one-to-many relates. Select the connection to change its cardinality."
			if (e.document.kind == MM_CLASS): status = c"Click target: adds an association. Select the connection to change its kind."
		ui_disable(&ctx, closing)
		ui_region_pop(&ctx)
		# Structure and inspector rows: groups, outline order, connection
		# kinds and compartments. Every button is one undoable edit.
		ui_region_push(&ctx, ui_rect_new(left.x, left.y + 214.0, left.w - 8.0, 120.0))
		if (outline):
			int at = canvas.node
			ui_disable(&ctx, closing || at < 0 || e.document.error != 0)
			if (ui_button(&ctx, c"Add child")):
				if (mm_outline_add(e, at, node_label.buf.data, 0)):
					mm_canvas_reset(&canvas, e)
					mm_canvas_source_sync(&area, e.document.source)
					status = c"Child added with the label field's text."
				else: status = c"Type a plain label first; it cannot hold line breaks."
			ui_same_line(&ctx)
			if (ui_button(&ctx, c"Add sibling")):
				if (mm_outline_add(e, at, node_label.buf.data, 1)):
					mm_canvas_reset(&canvas, e)
					mm_canvas_source_sync(&area, e.document.source)
					status = c"Sibling added with the label field's text."
				else: status = c"A sibling needs a parent and a plain label."
			ui_same_line(&ctx)
			if (ui_button(&ctx, c"Up")):
				if (mm_outline_reorder(e, at, 1)):
					mm_canvas_reset(&canvas, e)
					mm_canvas_source_sync(&area, e.document.source)
					status = c"Moved before its previous sibling."
			ui_same_line(&ctx)
			if (ui_button(&ctx, c"Down")):
				if (mm_outline_reorder(e, at, 0)):
					mm_canvas_reset(&canvas, e)
					mm_canvas_source_sync(&area, e.document.source)
					status = c"Moved after its next sibling."
			if (e.document.kind == MM_KANBAN):
				# Cards move between columns (also Left/Right on the canvas).
				ui_disable(&ctx, closing || at < 0 || e.document.error != 0 || e.document.nodes[at].parent < 0)
				ui_label(&ctx, c"Column")
				ui_same_line(&ctx)
				for k in range(2):
					char* name = c"Previous"
					int delta = -1
					if (k == 1):
						name = c"Next"
						delta = 1
					if (k == 1): ui_same_line(&ctx)
					if (ui_button(&ctx, name)):
						if (mm_editor_slot_column(e, at, delta)):
							mm_canvas_reset(&canvas, e)
							mm_canvas_source_sync(&area, e.document.source)
							status = c"Card moved to another column. Ctrl+Z to undo."
						else: status = c"No column there, or the card spans several lines."
			ui_disable(&ctx, closing)
		else:
			ui_label(&ctx, c"Group")
			ui_same_line(&ctx)
			ui_disable(&ctx, closing || mm_canvas_edit_family(e.document.kind) == 0)
			ui_textbox(&ctx, 90.0, &group_id)
			ui_same_line(&ctx)
			int target = wm_group_target(e, &group_id)
			ui_disable(&ctx, closing || canvas.node < 0 || target < 0 || selected_count > 1)
			if (ui_button(&ctx, c"Into")):
				if (mm_editor_reparent(e, canvas.node, target)):
					char* id = strclone(e.document.nodes[canvas.node].id)
					mm_canvas_reset(&canvas, e)
					canvas.node = mm_find_node(e.document, id)
					free(id)
					mm_canvas_source_sync(&area, e.document.source)
					status = c"Moved into the group. Ctrl+Z to undo."
				else: status = c"This family cannot move that item into the group without rewriting other statements."
			ui_same_line(&ctx)
			ui_disable(&ctx, closing || canvas.node < 0 || selected_count > 1)
			if (ui_button(&ctx, c"Out")):
				if (mm_editor_reparent(e, canvas.node, -1)):
					char* id = strclone(e.document.nodes[canvas.node].id)
					mm_canvas_reset(&canvas, e)
					canvas.node = mm_find_node(e.document, id)
					free(id)
					mm_canvas_source_sync(&area, e.document.source)
					status = c"Moved to the top level. Ctrl+Z to undo."
				else: status = c"It cannot leave its group here (an edge inside the group declares it)."
			ui_same_line(&ctx)
			ui_disable(&ctx, closing || canvas.node < 0 || selected_count > 1 || e.document.nodes[canvas.node].group == 0)
			if (ui_button(&ctx, c"Ungroup")):
				if (mm_editor_ungroup(e, canvas.node)):
					mm_canvas_reset(&canvas, e)
					mm_canvas_source_sync(&area, e.document.source)
					status = c"Group removed; its members stay. Ctrl+Z to undo."
				else: status = c"This group cannot be removed without rewriting its members."
			ui_same_line(&ctx)
			ui_disable(&ctx, closing || can_add == 0 || target < 0)
			if (ui_button(&ctx, c"Add in")):
				if (mm_editor_add_node_in(e, &node_id.text[0], node_label.buf.data, target)):
					canvas.node = mm_find_node(e.document, &node_id.text[0])
					canvas.edge = -1
					mm_canvas_source_sync(&area, e.document.source)
					status = c"Node added inside the group."
				else: status = c"The node cannot be added inside that group here."
			ui_disable(&ctx, closing)
		if (canvas.node < 0 && canvas.edge >= 0 && canvas.edge < e.document.edges.length && mm_editor_edge_editable(e, canvas.edge)):
			# Connection kind: one button per connector this family offers.
			ui_label(&ctx, c"Kind")
			if (e.document.kind == MM_ER):
				list[char*] names = list[char*]{c"1 to 1", c"1 to 1+", c"1 to 0+", c"1+ to 1+"}
				list[int] lefts = list[int]{1, 1, 1, 3}
				list[int] rights = list[int]{1, 3, 2, 3}
				for k in range(names.length):
					ui_same_line(&ctx)
					if (ui_button(&ctx, names[k])):
						if (mm_editor_er_cardinality(e, canvas.edge, lefts[k], rights[k], e.document.edges[canvas.edge].dashed)):
							mm_canvas_source_sync(&area, e.document.source)
							status = c"Cardinality changed. Ctrl+Z to undo."
						else: status = c"Cardinality cannot be changed here; use source editing."
				__w_list_free(cast(__w_list*, names))
				__w_list_free(cast(__w_list*, lefts))
				__w_list_free(cast(__w_list*, rights))
			else:
				list[char*] kinds = split(mm_editor_edge_kinds(e.document.kind))
				for char* kind in kinds:
					if (kind[0] == 0): continue
					ui_same_line(&ctx)
					if (ui_button(&ctx, kind)):
						if (mm_editor_edge_kind(e, canvas.edge, kind)):
							mm_canvas_source_sync(&area, e.document.source)
							status = c"Connection kind changed. Ctrl+Z to undo."
						else: status = c"That kind cannot be written here; use source editing."
				for char* kind in kinds: free(kind)
				__w_list_free(cast(__w_list*, kinds))
		else if (canvas.node >= 0 && selected_count <= 1 && (e.document.kind == MM_CLASS || e.document.kind == MM_ER || e.document.kind == MM_REQUIREMENT)):
			# Compartments: class members, ER attributes, requirement properties.
			char* member_name = c"Member"
			if (e.document.kind == MM_ER): member_name = c"Attribute"
			if (e.document.kind == MM_REQUIREMENT): member_name = c"Property"
			ui_label(&ctx, member_name)
			ui_same_line(&ctx)
			ui_textbox(&ctx, left.w - 250.0, &member_text)
			ui_same_line(&ctx)
			ui_disable(&ctx, closing || member_text.length == 0)
			if (ui_button(&ctx, c"Add")):
				int ok = 0
				if (e.document.kind == MM_ER): ok = wm_attribute_add(e, canvas.node, &member_text.text[0])
				else: ok = mm_editor_member_add(e, canvas.node, &member_text.text[0])
				if (ok):
					mm_canvas_source_sync(&area, e.document.source)
					ui_textbox_set(&member_text, c"")
					status = c"Added to the compartment. Ctrl+Z to undo."
				else: status = c"Use one plain line (ER: type name [keys])."
			ui_same_line(&ctx)
			int last = -1
			mm_node* n = e.document.nodes[canvas.node]
			if (e.document.kind == MM_ER && n.attributes != 0): last = n.attributes.length - 1
			else if (e.document.kind != MM_ER && n.members != 0): last = n.members.length - 1
			ui_disable(&ctx, closing || last < 0)
			if (ui_button(&ctx, c"Remove last")):
				int ok = 0
				if (e.document.kind == MM_ER): ok = mm_editor_attribute_remove(e, canvas.node, last)
				else: ok = mm_editor_member_remove(e, canvas.node, last)
				if (ok):
					mm_canvas_source_sync(&area, e.document.source)
					status = c"Removed. Ctrl+Z to undo."
				else: status = c"That line cannot be removed here; use source editing."
			ui_disable(&ctx, closing)
			# Line row: choose a compartment line and edit it in place.
			int count = mm_editor_line_count(e, canvas.node)
			if (line_node != canvas.node):
				line_node = canvas.node
				line_index = 0
				line_resync = 1
			if (count > 0 && line_index >= count):
				line_index = 0
				line_resync = 1
			ui_label(&ctx, c"Line")
			ui_same_line(&ctx)
			ui_disable(&ctx, closing || count < 2)
			if (ui_button(&ctx, c"<")):
				line_index = (line_index + count - 1) % count
				line_resync = 1
			ui_same_line(&ctx)
			if (ui_button(&ctx, c">")):
				line_index = (line_index + 1) % count
				line_resync = 1
			ui_same_line(&ctx)
			ui_disable(&ctx, closing || count == 0)
			if (focus_line):
				ctx.focus = ctx.next_id
				focus_line = 0
			line_focus_id = ctx.next_id
			if (ctx.focus != line_focus_id || line_resync):
				char* current = mm_editor_line_text(e, canvas.node, line_index)
				if (current == 0): ui_textbox_set(&line_text, c"")
				else:
					ui_textbox_set(&line_text, current)
					free(current)
				line_text.caret = line_text.length
				line_resync = 0
			char* typed_before = strclone(&line_text.text[0])
			ui_textbox(&ctx, left.w - 200.0, &line_text)
			if (count > 0 && strcmp(typed_before, &line_text.text[0]) != 0):
				int keep = line_position == e.position && line_group == line_index && now - line_time < 500
				int position_before = e.position
				if (mm_editor_line_set(e, canvas.node, line_index, &line_text.text[0])):
					if (keep && e.position != position_before): mm_editor_coalesce(e)
					line_position = e.position
					line_group = line_index
					line_time = now
					mm_canvas_source_sync(&area, e.document.source)
					status = c"Line updated in place; one typing run is one undo step."
				else: status = c"Not applied yet: keep the line valid (ER: type name [keys] [\"comment\"])."
			free(typed_before)
			ui_same_line(&ctx)
			string_builder* which = string_new()
			if (count > 0):
				string_append_int(which, line_index + 1)
				string_append(which, c"/")
				string_append_int(which, count)
			ui_label(&ctx, which.data)
			string_free(which)
			ui_disable(&ctx, closing)
		ui_region_pop(&ctx)
		float32 source_y = left.y + 338.0
		ui_draw_text(&renderer, left.x, source_y, c"Source  (Ctrl+E)", 2, theme.text_muted)
		source_y = source_y + 24.0
		ui_rect source_rect = ui_rect_new(left.x, source_y, left.w - 8.0, left.h - 362.0)
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
				if (mm_canvas_press_mods(&canvas, e, cast(float32, ctx.input.press_x) - preview.x, cast(float32, ctx.input.press_y) - preview.y, wm_press_mods(ctx.input.mods))):
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
						status = c"Changed. Ctrl+Z to undo the whole drag."
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
		char* help = c"Ctrl+D canvas: Tab selects, Space/Shift+click add, Ctrl+A all, arrows move (Shift: 10), Alt+arrows resize, Delete removes, Ctrl+G ungroups, Ctrl+P edits a member line."
		if (external != MM_DISK_SAME): help = c"Changed on disk: Ctrl+Shift+R reloads it (discarding edits), Ctrl+K keeps your version."
		if (mm_canvas_edit_family(e.document.kind) == 0): help = c"Preview and source editing for this family. Graphical editing: flowchart, ER, class, state, requirement, use case, architecture, block, C4, swimlane, mindmap, treeView, kanban, agentflow."
		else if (e.document.kind == MM_KANBAN): help = c"Ctrl+D canvas: Tab selects, Up/Down reorder a card, Left/Right move it to another column, drag onto a column or card; Delete removes."
		else if (mm_outline_family(e.document.kind)): help = c"Ctrl+D canvas: Tab selects, arrows or a drag reorder among siblings (drag onto another node to move under it); Delete removes the subtree."
		else if (e.document.kind == MM_BLOCK): help = c"Ctrl+D canvas: Tab selects, arrows or a drag move a block to another cell, Alt+Left/Right change its column span, Delete removes."
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
					int saved = mm_editor_save_checked(e)
					if (saved == MM_SAVE_OK): finished = 1
					else:
						closing = 0
						status = wm_save_message(e, saved)
						external = e.disk_state
				ui_same_line(&ctx)
				if (ui_button(&ctx, c"Discard")): finished = 1
				ui_same_line(&ctx)
				if (ui_button(&ctx, c"Cancel")): closing = 0
				ui_region_pop(&ctx)
		ui_end(&ctx)
		if (access_bridge != 0):
			ui_access_node* root = ui_access_find(access_fresh, ui_access_root_id)
			if (root != 0):
				string_builder* title = string_from(c"W Mermaid: ")
				string_append(title, e.path)
				ui_access_set_text(access_fresh, ui_access_root_id, UI_ACCESS_NAME, title.data, title.length)
				string_free(title)
				mm_access_canvas(access_fresh, ui_access_root_id, WM_CANVAS_FOCUS, &canvas, e, preview, ctx.focus == WM_CANVAS_FOCUS)
				char* spoken = status
				if (e.document.error != 0): spoken = c"Syntax error in the source."
				if (ui_access_add(access_fresh, WM_STATUS_ACCESS, ui_access_root_id, UI_ACCESS_TEXT, ui_rect_new(12.0, height - 64.0, width - 24.0, 24.0)) != 0): ui_access_set_text(access_fresh, WM_STATUS_ACCESS, UI_ACCESS_NAME, spoken, strlen(spoken))
			ui_access_capture(&ctx, 0)
			if (ui_access_tree_same(access_fresh, access_published)): ui_access_tree_free(access_fresh)
			else:
				ui_access_platform_publish(access_bridge, access_fresh)
				ui_access_tree_free(access_published)
				access_published = access_fresh
			access_fresh = 0
			ui_access_platform_origin(access_bridge, win)
			if (ui_access_platform_dispatch(access_bridge, access_published) < 0):
				ui_access_platform_close(access_bridge)
				access_bridge = 0
		frame = frame + 1
		if (max_frames > 0 && frame >= max_frames):
			char* shot = args_value(c"screenshot")
			if (shot != 0):
				glFinish()
				# The framebuffer is in device pixels (HiDPI windows).
				float32 ratio = gfx_window_pixel_ratio(win)
				int shot_w = cast(int, cast(float32, win.width) * ratio)
				int shot_h = cast(int, cast(float32, win.height) * ratio)
				if (wm_editor_ppm(shot, shot_w, shot_h) == 0): exit_status = 1
			finished = 1
		gfx_window_swap(win)
		sleep_ms(16)
	mm_canvas_cancel(&canvas, e)
	ui_access_platform_close(access_bridge)
	ui_access_tree_free(access_published)
	ui_render_destroy(&renderer)
	gfx_window_destroy(win)
	ui_textarea_free(&area)
	ui_textarea_free(&filename)
	ui_textarea_free(&node_label)
	mm_editor_free(e)
	return exit_status
