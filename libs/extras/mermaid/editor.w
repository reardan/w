# UI-independent editor state: bounded undo/redo, parse-on-change, safe save.
import libs.extras.mermaid.io
import libs.extras.mermaid.render
import libs.extras.mermaid.save_guard

struct mm_editor:
	mm_document* document
	mm_scene* scene
	char* path
	char* saved_source
	list[char*] history
	int position
	int selected
	int disk_present
	char* disk_source
	int moving
	int move_index
	int move_start_x
	int move_start_y
	# Disk polling (mm_editor_poll) and the last save's outcome.
	mm_disk_stamp disk_stamp
	int disk_state
	int polls
	int save_status
	char* recovery_path

void mm_editor_move_cancel(mm_editor* e);

# Treat unreadable paths as occupied; only ENOENT means absent.
int mm_editor_path_present(char* path):
	return mm_disk_present(path)

mm_editor* mm_editor_new(char* path, char* source):
	if (path == 0 || source == 0 || strlen(source) > MM_MAX_SOURCE): return 0
	mm_editor* e = new mm_editor()
	e.move_index = -1
	e.path = strclone(path)
	e.saved_source = strclone(source)
	e.disk_present = mm_editor_path_present(path)
	# The baseline is exactly the source presented to the user. Re-reading here
	# could accept a newer disk revision while leaving the old document visible.
	e.disk_source = strclone(source)
	e.document = mm_parse(source, strlen(source))
	e.scene = mm_render(e.document)
	e.history = new list[char*]
	e.history.push(strclone(source))
	mm_disk_stamp_read(path, &e.disk_stamp)
	e.disk_state = mm_disk_compare(path, e.disk_present, e.disk_source)
	return e

# Opening records that the snapshot came from an existing file, even if another
# process deletes that file before the editor state is allocated.
mm_editor* mm_editor_open(char* path):
	int length = 0
	char* source = mm_read_source(path, &length)
	if (source == 0): return 0
	if (strlen(source) != length):
		free(source)
		return 0
	mm_editor* e = mm_editor_new(path, source)
	e.disk_present = 1
	e.disk_state = mm_disk_compare(path, 1, e.disk_source)
	free(source)
	return e

int mm_editor_dirty(mm_editor* e):
	return strcmp(e.document.source, e.saved_source) != 0

void mm_editor_load(mm_editor* e, char* source):
	e.moving = 0
	e.move_index = -1
	mm_document* next = mm_parse_selected(source, strlen(source), e.selected)
	mm_scene_free(e.scene)
	mm_document_free(e.document)
	e.document = next
	e.scene = mm_render(next)

int mm_editor_change(mm_editor* e, char* source):
	mm_editor_move_cancel(e)
	if (source == 0): return 0
	if (strlen(source) > MM_MAX_SOURCE): return 0
	if (strcmp(e.document.source, source) == 0): return 1
	char* copy = strclone(source)
	while (e.history.length > e.position + 1):
		free(e.history[e.history.length - 1])
		e.history.pop()
	# At most 32 MiB source snapshots. A dropped oldest state is freed.
	if (e.history.length >= 32):
		free(e.history[0])
		for i in range(1, e.history.length): e.history[i - 1] = e.history[i]
		e.history.pop()
	e.history.push(copy)
	e.position = e.history.length - 1
	mm_editor_load(e, copy)
	return 1

# The UI owns the idle deadline and gesture boundaries. Coalescing may replace
# only the latest unsaved typing snapshot; a saved state remains an undo stop.
int mm_editor_change_typing(mm_editor* e, char* source, int continue_group):
	mm_editor_move_cancel(e)
	if (source == 0 || strlen(source) > MM_MAX_SOURCE): return 0
	if (strcmp(e.document.source, source) == 0): return 1
	if (continue_group == 0 || e.position == 0 || e.position + 1 != e.history.length || strcmp(e.document.source, e.saved_source) == 0): return mm_editor_change(e, source)
	char* copy = strclone(source)
	free(e.history[e.position])
	e.history[e.position] = copy
	mm_editor_load(e, copy)
	return 1

int mm_editor_undo(mm_editor* e, int redo):
	mm_editor_move_cancel(e)
	int next = e.position - 1
	if (redo): next = e.position + 1
	if (next < 0 || next >= e.history.length): return 0
	e.position = next
	mm_editor_load(e, e.history[next])
	return 1

# The disk baseline is now what the editor shows as saved.
void mm_editor_adopt_baseline(mm_editor* e, char* source, int present):
	char* copy = 0
	if (source != 0): copy = strclone(source)
	else: copy = strclone(c"")
	free(e.disk_source)
	e.disk_source = copy
	e.disk_present = present
	e.disk_state = MM_DISK_SAME
	mm_disk_stamp_read(e.path, &e.disk_stamp)

# Detect content changes, replacement and deletion before overwriting the file.
int mm_editor_external_change(mm_editor* e):
	return mm_disk_compare(e.path, e.disk_present, e.disk_source) != MM_DISK_SAME

# Periodic check for the UI loop: MM_DISK_SAME, MM_DISK_CHANGED or
# MM_DISK_MISSING. The size/mtime/ctime/inode fingerprint is read every
# call; the bytes are compared when it moved or on every force call, which
# catches same-second, same-size in-place rewrites and stat-less platforms.
int mm_editor_poll(mm_editor* e, int force):
	mm_disk_stamp now
	mm_disk_stamp_read(e.path, &now)
	e.polls = e.polls + 1
	if (force == 0 && mm_disk_stamp_same(&now, &e.disk_stamp) && e.disk_state == MM_DISK_SAME): return MM_DISK_SAME
	e.disk_state = mm_disk_compare(e.path, e.disk_present, e.disk_source)
	if (e.disk_state == MM_DISK_SAME): e.disk_stamp = now
	return e.disk_state

# "Keep mine": acknowledge the current disk version (or its deletion) as
# the baseline, so the next save replaces exactly that version. Nothing is
# written here, and a later external change is detected again.
int mm_editor_keep_mine(mm_editor* e):
	if (mm_disk_present(e.path) == 0):
		mm_editor_adopt_baseline(e, 0, 0)
		return 1
	int length = 0
	char* disk = mm_read_source(e.path, &length)
	if (disk == 0): return 0
	if (strlen(disk) != length):
		free(disk)
		return 0
	mm_editor_adopt_baseline(e, disk, 1)
	free(disk)
	return 1

void mm_editor_clear_recovery(mm_editor* e):
	free(e.recovery_path)
	e.recovery_path = 0

# MM_SAVE_OK, MM_SAVE_CONFLICT (disk differs from the baseline, or another
# writer raced the save; nothing of theirs is overwritten and recovery_path
# names any bytes that had to be set aside) or MM_SAVE_FAILED.
int mm_editor_save_checked(mm_editor* e):
	char* recovery = 0
	int status = mm_save_cas(e.path, e.disk_present, e.disk_source, e.document.source, e.document.length, &recovery)
	if (recovery != 0):
		mm_editor_clear_recovery(e)
		e.recovery_path = recovery
	e.save_status = status
	if (status == MM_SAVE_CONFLICT): e.disk_state = MM_DISK_CHANGED
	if (status == MM_SAVE_CONFLICT && recovery != 0 && mm_disk_matches(e.path, e.document.source)):
		# Placed, but an in-place writer touched the claimed copy afterwards.
		free(e.saved_source)
		e.saved_source = strclone(e.document.source)
		mm_editor_adopt_baseline(e, e.document.source, 1)
		e.disk_state = MM_DISK_CHANGED
		return status
	if (status != MM_SAVE_OK): return status
	free(e.saved_source)
	e.saved_source = strclone(e.document.source)
	mm_editor_adopt_baseline(e, e.document.source, 1)
	return status

int mm_editor_save(mm_editor* e):
	return mm_editor_save_checked(e) == MM_SAVE_OK

# Save As refuses an existing destination; use Open to review it first.
int mm_editor_save_as(mm_editor* e, char* path):
	if (strcmp(e.path, path) == 0): return mm_editor_save(e)
	if (mm_save_write_new(path, e.document.source, e.document.length, FS_DEFAULT_MODE) != 0): return 0
	io_result result
	if (os_windows() == 0 && fs_sync_parent_dir(path, &result) != IO_OK): return 0
	char* saved_path = strclone(path)
	free(e.path)
	e.path = saved_path
	free(e.saved_source)
	e.saved_source = strclone(e.document.source)
	mm_editor_adopt_baseline(e, e.document.source, 1)
	return 1

# Reload explicitly discards pending changes and resets undo to the disk version.
int mm_editor_reload(mm_editor* e):
	mm_document* disk = mm_read_selected(e.path, e.selected)
	if (disk == 0): return 0
	if (strlen(disk.source) != disk.length):
		mm_document_free(disk)
		return 0
	mm_editor_load(e, disk.source)
	for char* text in e.history: free(text)
	while (e.history.length > 0): e.history.pop()
	e.history.push(strclone(disk.source))
	e.position = 0
	free(e.saved_source)
	e.saved_source = strclone(disk.source)
	mm_editor_adopt_baseline(e, disk.source, 1)
	mm_document_free(disk)
	return 1

int mm_editor_select(mm_editor* e, int selected):
	int count = mm_source_diagram_count(e.document.source, e.document.length)
	if (selected < 0 || selected >= count): return 0
	e.selected = selected
	mm_editor_load(e, e.document.source)
	return 1

# A validated structured insertion is one undoable edit. Its position is inside
# the selected fence and after its frontmatter, leaving surrounding bytes intact.
int mm_editor_append(mm_editor* e, char* statement):
	if (e.document.error != 0 || statement == 0): return 0
	string_builder* source = string_new()
	string_append_bytes(source, e.document.source, e.document.source_end)
	if (source.length > 0 && source.data[source.length - 1] != 10): string_append_char(source, 10)
	string_append(source, statement)
	string_append_char(source, 10)
	string_append_bytes(source, e.document.source + e.document.source_end, e.document.length - e.document.source_end)
	mm_document* next = mm_parse_selected(source.data, source.length, e.selected)
	int ok = next.error == 0
	if (ok): ok = mm_editor_change(e, source.data)
	mm_document_free(next)
	string_free(source)
	return ok

int mm_editor_identifier(char* id):
	if (id == 0 || id[0] == 0): return 0
	for i in range(strlen(id)):
		int c = id[i]
		if ((c < 'a' || c > 'z') && (c < 'A' || c > 'Z') && (c < '0' || c > '9') && c != '_'): return 0
	return 1

# Structured flowchart additions preserve source comments and original styling.
int mm_editor_add_node(mm_editor* e, char* id, char* label):
	if (e.document.kind != MM_FLOW || mm_editor_identifier(id) == 0 || label == 0): return 0
	if (mm_find_node(e.document, id) >= 0): return 0
	string_builder* statement = string_from(id)
	string_append(statement, c"[\"")
	for i in range(strlen(label)):
		int c = label[i] & 255
		if (c < 32 || c == '"' || c == '\\'):
			string_free(statement)
			return 0
		string_append_char(statement, c)
	string_append(statement, c"\"]")
	int ok = mm_editor_append(e, statement.data)
	string_free(statement)
	return ok

int mm_editor_add_edge(mm_editor* e, char* from_id, char* to_id):
	if (e.document.kind != MM_FLOW || mm_editor_identifier(from_id) == 0 || mm_editor_identifier(to_id) == 0): return 0
	if (mm_find_node(e.document, from_id) < 0 || mm_find_node(e.document, to_id) < 0): return 0
	string_builder* statement = string_from(from_id)
	string_append(statement, c" --> ")
	string_append(statement, to_id)
	int ok = mm_editor_append(e, statement.data)
	string_free(statement)
	return ok

# Hit testing uses scene coordinates; callers reverse preview zoom and pan.
int mm_editor_hit(mm_editor* e, int x, int y):
	if (e.scene == 0 || mm_graph_edit_family(e.document.kind) == 0): return -1
	int hit = -1
	for i in range(e.scene.nodes.length):
		mm_bounds* b = e.scene.nodes[i]
		if (e.document.nodes[i].group == 0 && x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h): hit = i
	return hit

# Canvas gestures retain the parsed document and measured layout. A pointer
# update only rebuilds primitives, so edges follow their current node bounds.
int mm_editor_can_move(mm_editor* e, int index):
	if (e.scene == 0 || index < 0 || index >= e.scene.nodes.length): return 0
	return mm_position_supported(e.document, index)

int mm_editor_move_begin(mm_editor* e, int index):
	if (mm_editor_can_move(e, index) == 0): return 0
	mm_editor_move_cancel(e)
	e.moving = 1
	e.move_index = index
	e.move_start_x = e.scene.nodes[index].x
	e.move_start_y = e.scene.nodes[index].y
	return 1

int mm_editor_move_preview(mm_editor* e, int x, int y):
	if (e.moving == 0 || mm_editor_can_move(e, e.move_index) == 0): return 0
	int offset = mm_position_title_offset(e.document)
	if (x < 0 || x > MM_POSITION_LIMIT || y < offset || y > MM_POSITION_LIMIT + offset): return 0
	mm_bounds* b = e.scene.nodes[e.move_index]
	if (b.x == x && b.y == y): return 1
	b.x = x
	b.y = y
	mm_render_graph_refresh(e.document, e.scene)
	return 1

void mm_editor_move_cancel(mm_editor* e):
	if (e.moving == 0): return
	int index = e.move_index
	e.moving = 0
	e.move_index = -1
	if (mm_editor_can_move(e, index) == 0): return
	mm_bounds* b = e.scene.nodes[index]
	if (b.x == e.move_start_x && b.y == e.move_start_y): return
	b.x = e.move_start_x
	b.y = e.move_start_y
	mm_render_graph_refresh(e.document, e.scene)

int mm_editor_move_commit(mm_editor* e):
	if (e.moving == 0 || mm_editor_can_move(e, e.move_index) == 0): return 0
	mm_bounds* b = e.scene.nodes[e.move_index]
	if (b.x == e.move_start_x && b.y == e.move_start_y):
		mm_editor_move_cancel(e)
		return 1
	char* source = mm_position_source(e.document, e.move_index, b.x, b.y - mm_position_title_offset(e.document))
	if (source == 0):
		mm_editor_move_cancel(e)
		return 0
	if (strlen(source) > MM_MAX_SOURCE):
		free(source)
		mm_editor_move_cancel(e)
		return 0
	# Only now create one undo snapshot; preview frames never enter history.
	e.moving = 0
	e.move_index = -1
	int ok = mm_editor_change(e, source)
	free(source)
	return ok

# Keyboard nudges and pointer drags share the same transactional command.
int mm_editor_move_node(mm_editor* e, int index, int x, int y):
	if (mm_editor_move_begin(e, index) == 0): return 0
	if (mm_editor_move_preview(e, x, y) == 0):
		mm_editor_move_cancel(e)
		return 0
	return mm_editor_move_commit(e)

# Only standalone comments that currently affect layout enable Auto layout.
int mm_editor_has_positions(mm_editor* e):
	mm_document* d = e.document
	if (d.error != 0 || d.comment_ranges == 0): return 0
	for i in range(d.comment_ranges.length / 2):
		int start = d.comment_ranges[i * 2]
		int end = d.comment_ranges[i * 2 + 1]
		int before = start - 1
		while (before >= d.source_start && mm_position_space(d.source[before])): before = before - 1
		if (before >= d.source_start && d.source[before] != 10): continue
		int x = 0
		int y = 0
		if (mm_position_record(d, start, end, &x, &y) >= 0): return 1
	return 0

# Restore automatic layout in one undoable edit. Malformed hints, inaccessible
# metadata-looking text and other diagrams remain byte-for-byte intact.
int mm_editor_reset_positions(mm_editor* e):
	mm_editor_move_cancel(e)
	if (e.document.error != 0 || mm_graph_edit_family(e.document.kind) == 0): return 0
	if (mm_editor_has_positions(e) == 0): return 1
	mm_document* d = e.document
	string_builder* source = string_new()
	string_append_bytes(source, d.source, d.source_start)
	int at = d.source_start
	while (at < d.source_end):
		int end = mm_position_line_end(d, at)
		int after = end
		if (after < d.source_end): after = after + 1
		int x = 0
		int y = 0
		if (mm_position_record(d, at, end, &x, &y) < 0): string_append_bytes(source, d.source + at, after - at)
		at = after
	string_append_bytes(source, d.source + d.source_end, d.length - d.source_end)
	int ok = mm_editor_change(e, source.data)
	string_free(source)
	return ok

void mm_editor_free(mm_editor* e):
	mm_scene_free(e.scene)
	mm_document_free(e.document)
	free(e.path)
	free(e.saved_source)
	free(e.disk_source)
	free(e.recovery_path)
	for char* text in e.history: free(text)
	__w_list_free(cast(__w_list*, e.history))
	free(e)
