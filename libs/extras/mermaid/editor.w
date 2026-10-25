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
	# Set moves and resizes: the moved roots and every node's bounds at the
	# gesture start (x, y, w, h per scene node); moving 2 means resizing.
	list[int] move_set
	list[int] move_snapshot
	# History index of an open transaction (mm_editor_begin), else -1.
	int transaction

void mm_editor_move_cancel(mm_editor* e);

# Treat unreadable paths as occupied; only ENOENT means absent.
int mm_editor_path_present(char* path):
	return mm_disk_present(path)

mm_editor* mm_editor_new(char* path, char* source):
	if (path == 0 || source == 0 || strlen(source) > MM_MAX_SOURCE): return 0
	mm_editor* e = new mm_editor()
	e.move_index = -1
	e.transaction = -1
	e.move_set = new list[int]
	e.move_snapshot = new list[int]
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
		if (e.transaction > 0): e.transaction = e.transaction - 1
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
# A node wins over the groups drawn around it; among groups the innermost.
int mm_editor_hit(mm_editor* e, int x, int y):
	if (e.scene == 0 || e.document.error != 0 || mm_canvas_edit_family(e.document.kind) == 0): return -1
	if (e.scene.nodes.length != e.document.nodes.length): return -1
	int hit = -1
	int group = -1
	int group_depth = -1
	for i in range(e.scene.nodes.length):
		mm_bounds* b = e.scene.nodes[i]
		if (b.w <= 0 || b.h <= 0 || mm_flow_visible_node(e.document, i) != i): continue
		if (x < b.x || x > b.x + b.w || y < b.y || y > b.y + b.h): continue
		# Synthetic containers (a block root, concurrent state regions) are not targets.
		if (e.document.nodes[i].group && e.document.nodes[i].id[0] == '@'): continue
		if (e.document.nodes[i].group == 0 || mm_flow_collapsed(e.document, i)): hit = i
		else:
			int depth = mm_position_depth(e.document, i)
			if (depth >= group_depth):
				group = i
				group_depth = depth
	if (hit >= 0): return hit
	return group

# Canvas gestures retain the parsed document and measured layout. A pointer
# update only rebuilds primitives, so edges follow their current node bounds.
int mm_editor_can_move(mm_editor* e, int index):
	if (e.scene == 0 || index < 0 || index >= e.scene.nodes.length): return 0
	if (e.scene.nodes.length != e.document.nodes.length): return 0
	return mm_position_supported(e.document, index) || mm_slot_movable(e.document, index)

int mm_editor_can_resize(mm_editor* e, int index):
	if (e.scene == 0 || index < 0 || index >= e.scene.nodes.length): return 0
	if (e.scene.nodes.length != e.document.nodes.length): return 0
	return mm_position_supported(e.document, index) || mm_slot_resizable(e.document, index)

# Source-order families preview a gesture as a ghost (the selection outline
# follows the pointer) and commit it as a reorder; geometry families redraw.
void mm_editor_preview_refresh(mm_editor* e):
	if (mm_slot_family(e.document.kind)): return
	mm_positions_fit_groups(e.document, e.scene)
	mm_render_graph_refresh(e.document, e.scene)

void mm_editor_snapshot(mm_editor* e):
	while (e.move_snapshot.length > 0): e.move_snapshot.pop()
	for mm_bounds* b in e.scene.nodes:
		e.move_snapshot.push(b.x)
		e.move_snapshot.push(b.y)
		e.move_snapshot.push(b.w)
		e.move_snapshot.push(b.h)

void mm_editor_restore(mm_editor* e):
	if (e.move_snapshot.length != e.scene.nodes.length * 4): return
	for i in range(e.scene.nodes.length):
		mm_bounds* b = e.scene.nodes[i]
		b.x = e.move_snapshot[i * 4]
		b.y = e.move_snapshot[i * 4 + 1]
		b.w = e.move_snapshot[i * 4 + 2]
		b.h = e.move_snapshot[i * 4 + 3]

# A set move: indices whose ancestor group is also moved ride along with it.
int mm_editor_move_begin_set(mm_editor* e, list[int] indices):
	mm_editor_move_cancel(e)
	if (indices == 0 || indices.length == 0): return 0
	for int index in indices:
		if (mm_editor_can_move(e, index) == 0): return 0
	while (e.move_set.length > 0): e.move_set.pop()
	for int index in indices:
		int carried = 0
		for int other in indices:
			if (other != index && mm_position_within(e.document, index, other)): carried = 1
		for int other in e.move_set:
			if (other == index): carried = 1
		if (carried == 0): e.move_set.push(index)
	mm_editor_snapshot(e)
	e.moving = 1
	e.move_index = e.move_set[0]
	e.move_start_x = e.scene.nodes[e.move_index].x
	e.move_start_y = e.scene.nodes[e.move_index].y
	return 1

int mm_editor_move_begin(mm_editor* e, int index):
	if (mm_editor_can_move(e, index) == 0): return 0
	list[int] one = list[int]{index}
	int ok = mm_editor_move_begin_set(e, one)
	__w_list_free(cast(__w_list*, one))
	return ok

# Offset every moved root (and its members) from its gesture-start bounds.
int mm_editor_move_preview_delta(mm_editor* e, int dx, int dy):
	if (e.moving != 1): return 0
	int offset = mm_position_title_offset(e.document)
	for int index in e.move_set:
		if (mm_editor_can_move(e, index) == 0): return 0
		int x = e.move_snapshot[index * 4] + dx
		int y = e.move_snapshot[index * 4 + 1] + dy
		if (x < 0 || x > MM_POSITION_LIMIT || y < offset || y > MM_POSITION_LIMIT + offset): return 0
	mm_bounds* primary = e.scene.nodes[e.move_index]
	if (primary.x == e.move_start_x + dx && primary.y == e.move_start_y + dy): return 1
	mm_editor_restore(e)
	for int index in e.move_set: mm_position_translate(e.document, e.scene, index, dx, dy)
	mm_editor_preview_refresh(e)
	return 1

int mm_editor_move_preview(mm_editor* e, int x, int y):
	if (e.moving != 1 || mm_editor_can_move(e, e.move_index) == 0): return 0
	return mm_editor_move_preview_delta(e, x - e.move_start_x, y - e.move_start_y)

void mm_editor_move_cancel(mm_editor* e):
	if (e.moving == 0): return
	e.moving = 0
	e.move_index = -1
	if (e.scene == 0 || e.move_snapshot.length != e.scene.nodes.length * 4): return
	int same = 1
	for i in range(e.scene.nodes.length):
		mm_bounds* b = e.scene.nodes[i]
		if (b.x != e.move_snapshot[i * 4] || b.y != e.move_snapshot[i * 4 + 1] || b.w != e.move_snapshot[i * 4 + 2] || b.h != e.move_snapshot[i * 4 + 3]): same = 0
	if (same): return
	mm_editor_restore(e)
	if (mm_slot_family(e.document.kind) == 0): mm_render_graph_refresh(e.document, e.scene)

# Per node: 1 when it currently carries a valid record of the given kind.
list[int] mm_editor_recorded(mm_editor* e, int kind):
	list[int] marks = new list[int]
	for i in range(e.document.nodes.length): marks.push(0)
	mm_document* d = e.document
	int at = d.source_start
	while (at < d.source_end):
		int end = mm_position_line_end(d, at)
		int record_kind = 0
		int x = 0
		int y = 0
		int index = mm_geometry_record(d, at, end, &record_kind, &x, &y)
		if (index >= 0 && record_kind == kind): marks[index] = 1
		at = end + 1
	return marks

int mm_editor_move_commit(mm_editor* e):
	if (e.moving != 1 || mm_editor_can_move(e, e.move_index) == 0): return 0
	# Source-order families commit through mm_editor_slot_* (edit_slots.w).
	if (mm_position_supported(e.document, e.move_index) == 0):
		mm_editor_move_cancel(e)
		return 0
	mm_bounds* primary = e.scene.nodes[e.move_index]
	int dx = primary.x - e.move_start_x
	int dy = primary.y - e.move_start_y
	if (dx == 0 && dy == 0):
		mm_editor_move_cancel(e)
		return 1
	int offset = mm_position_title_offset(e.document)
	# Roots get records; positioned members of moved groups keep their place
	# inside the group by shifting their own records by the same offset.
	list[int] recorded = mm_editor_recorded(e, MM_GEOMETRY_POSITION)
	list[int] indices = new list[int]
	list[int] xs = new list[int]
	list[int] ys = new list[int]
	for i in range(e.document.nodes.length):
		int root = 0
		int member = 0
		for int index in e.move_set:
			if (index == i): root = 1
			else if (recorded[i] && mm_position_within(e.document, i, index)): member = 1
		if (root == 0 && member == 0): continue
		indices.push(i)
		xs.push(e.move_snapshot[i * 4] + dx)
		ys.push(e.move_snapshot[i * 4 + 1] + dy - offset)
	char* source = mm_geometry_source(e.document, MM_GEOMETRY_POSITION, indices, xs, ys)
	__w_list_free(cast(__w_list*, recorded))
	__w_list_free(cast(__w_list*, indices))
	__w_list_free(cast(__w_list*, xs))
	__w_list_free(cast(__w_list*, ys))
	if (source == 0 || strlen(source) > MM_MAX_SOURCE):
		if (source != 0): free(source)
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

int mm_editor_move_nodes(mm_editor* e, list[int] indices, int dx, int dy):
	if (mm_editor_move_begin_set(e, indices) == 0): return 0
	if (mm_editor_move_preview_delta(e, dx, dy) == 0):
		mm_editor_move_cancel(e)
		return 0
	return mm_editor_move_commit(e)

# Resizing previews like a move; the commit writes one @w-size record.
int mm_editor_resize_begin(mm_editor* e, int index):
	mm_editor_move_cancel(e)
	if (mm_editor_can_resize(e, index) == 0): return 0
	mm_editor_snapshot(e)
	e.moving = 2
	e.move_index = index
	e.move_start_x = e.scene.nodes[index].w
	e.move_start_y = e.scene.nodes[index].h
	return 1

int mm_editor_resize_preview(mm_editor* e, int w, int h):
	if (e.moving != 2 || mm_editor_can_resize(e, e.move_index) == 0): return 0
	if (w < MM_SIZE_MIN || h < MM_SIZE_MIN || w > MM_SIZE_LIMIT || h > MM_SIZE_LIMIT): return 0
	mm_bounds* b = e.scene.nodes[e.move_index]
	if (b.w == w && b.h == h): return 1
	mm_editor_restore(e)
	b.w = w
	b.h = h
	mm_editor_preview_refresh(e)
	return 1

int mm_editor_resize_commit(mm_editor* e):
	if (e.moving != 2 || mm_editor_can_resize(e, e.move_index) == 0): return 0
	if (mm_position_supported(e.document, e.move_index) == 0):
		mm_editor_move_cancel(e)
		return 0
	mm_bounds* b = e.scene.nodes[e.move_index]
	if (b.w == e.move_start_x && b.h == e.move_start_y):
		mm_editor_move_cancel(e)
		return 1
	list[int] indices = list[int]{e.move_index}
	list[int] ws = list[int]{b.w}
	list[int] hs = list[int]{b.h}
	char* source = mm_geometry_source(e.document, MM_GEOMETRY_SIZE, indices, ws, hs)
	__w_list_free(cast(__w_list*, indices))
	__w_list_free(cast(__w_list*, ws))
	__w_list_free(cast(__w_list*, hs))
	if (source == 0 || strlen(source) > MM_MAX_SOURCE):
		if (source != 0): free(source)
		mm_editor_move_cancel(e)
		return 0
	e.moving = 0
	e.move_index = -1
	int ok = mm_editor_change(e, source)
	free(source)
	return ok

int mm_editor_resize_node(mm_editor* e, int index, int w, int h):
	if (mm_editor_resize_begin(e, index) == 0): return 0
	if (mm_editor_resize_preview(e, w, h) == 0):
		mm_editor_move_cancel(e)
		return 0
	return mm_editor_resize_commit(e)

# Several commands as one undo step. A begin inside an open transaction
# joins it; a rollback restores the source at the begin and drops the
# partial steps, leaving no history entry.
void mm_editor_begin(mm_editor* e):
	mm_editor_move_cancel(e)
	if (e.transaction < 0): e.transaction = e.position

void mm_editor_commit(mm_editor* e):
	int mark = e.transaction
	e.transaction = -1
	if (mark < 0 || e.position <= mark + 1): return
	char* last = e.history[e.position]
	for i in range(mark + 1, e.position): free(e.history[i])
	e.history[mark + 1] = last
	while (e.history.length > mark + 2): e.history.pop()
	e.position = mark + 1

void mm_editor_rollback(mm_editor* e):
	int mark = e.transaction
	e.transaction = -1
	if (mark < 0 || mark >= e.history.length || e.position == mark): return
	while (e.history.length > mark + 1):
		free(e.history[e.history.length - 1])
		e.history.pop()
	e.position = mark
	mm_editor_load(e, e.history[mark])

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
		int kind = 0
		int x = 0
		int y = 0
		if (mm_geometry_record(d, start, end, &kind, &x, &y) >= 0): return 1
	return 0

# Restore automatic layout in one undoable edit. Malformed hints, inaccessible
# metadata-looking text and other diagrams remain byte-for-byte intact.
int mm_editor_reset_positions(mm_editor* e):
	mm_editor_move_cancel(e)
	if (e.document.error != 0 || mm_geometry_family(e.document.kind) == 0): return 0
	if (mm_editor_has_positions(e) == 0): return 1
	mm_document* d = e.document
	string_builder* source = string_new()
	string_append_bytes(source, d.source, d.source_start)
	int at = d.source_start
	while (at < d.source_end):
		int end = mm_position_line_end(d, at)
		int after = end
		if (after < d.source_end): after = after + 1
		int kind = 0
		int x = 0
		int y = 0
		if (mm_geometry_record(d, at, end, &kind, &x, &y) < 0): string_append_bytes(source, d.source + at, after - at)
		at = after
	string_append_bytes(source, d.source + d.source_end, d.length - d.source_end)
	int ok = mm_editor_change(e, source.data)
	string_free(source)
	return ok

# Merge the latest history step into the one before it, so a run of
# inspector field edits (typing) is one undo step. A saved state, the
# history's first entry and an open transaction stay undo stops.
int mm_editor_coalesce(mm_editor* e):
	if (e.position < 2 || e.position + 1 != e.history.length || e.transaction >= 0): return 0
	if (strcmp(e.history[e.position - 1], e.saved_source) == 0): return 0
	free(e.history[e.position - 1])
	e.history[e.position - 1] = e.history[e.position]
	e.history.pop()
	e.position = e.position - 1
	return 1

void mm_editor_free(mm_editor* e):
	mm_scene_free(e.scene)
	mm_document_free(e.document)
	free(e.path)
	free(e.saved_source)
	free(e.disk_source)
	free(e.recovery_path)
	for char* text in e.history: free(text)
	__w_list_free(cast(__w_list*, e.history))
	__w_list_free(cast(__w_list*, e.move_set))
	__w_list_free(cast(__w_list*, e.move_snapshot))
	free(e)
