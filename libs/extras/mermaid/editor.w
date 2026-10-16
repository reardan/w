# UI-independent editor state: bounded undo/redo, parse-on-change, safe save.
import libs.extras.mermaid.io
import libs.extras.mermaid.render

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

# Treat unreadable paths as occupied; only ENOENT means absent.
int mm_editor_path_present(char* path):
	io_result result
	int fd = fs_open(path, FS_O_RDONLY, 0, &result)
	if (fd < 0): return result.native_error != 2
	io_close(fd, &result)
	return 1

mm_editor* mm_editor_new(char* path, char* source):
	if (path == 0 || source == 0 || strlen(source) > MM_MAX_SOURCE): return 0
	mm_editor* e = new mm_editor()
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
	free(source)
	return e

int mm_editor_dirty(mm_editor* e):
	return strcmp(e.document.source, e.saved_source) != 0

void mm_editor_load(mm_editor* e, char* source):
	mm_document* next = mm_parse_selected(source, strlen(source), e.selected)
	mm_scene_free(e.scene)
	mm_document_free(e.document)
	e.document = next
	e.scene = mm_render(next)

int mm_editor_change(mm_editor* e, char* source):
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

int mm_editor_undo(mm_editor* e, int redo):
	int next = e.position - 1
	if (redo): next = e.position + 1
	if (next < 0 || next >= e.history.length): return 0
	e.position = next
	mm_editor_load(e, e.history[next])
	return 1

# Detect content changes, replacement and deletion before overwriting the file.
# This is an optimistic guard, not a lock against another writer during replace.
int mm_editor_external_change(mm_editor* e):
	int length = 0
	char* disk = mm_read_source(e.path, &length)
	int changed = 0
	if (disk == 0): changed = e.disk_present || mm_editor_path_present(e.path)
	else:
		changed = e.disk_present == 0 || length != strlen(e.disk_source)
		if (changed == 0):
			for i in range(length):
				if (disk[i] != e.disk_source[i]): changed = 1
	free(disk)
	return changed

int mm_editor_save(mm_editor* e):
	if (mm_editor_external_change(e)): return 0
	io_result result
	if (mm_save(e.document, e.path, &result) != IO_OK): return 0
	free(e.saved_source)
	e.saved_source = strclone(e.document.source)
	free(e.disk_source)
	e.disk_source = strclone(e.document.source)
	e.disk_present = 1
	return 1

# Save As refuses an existing destination; use Open to review it first.
int mm_editor_save_as(mm_editor* e, char* path):
	if (strcmp(e.path, path) == 0): return mm_editor_save(e)
	io_result result
	int fd = fs_create_exclusive(path, FS_DEFAULT_MODE, &result)
	if (fd < 0): return 0
	int ok = io_write_all(fd, e.document.source, e.document.length, &result) == IO_OK
	if (fs_fsync(fd, &result) != IO_OK): ok = 0
	if (io_close(fd, &result) != IO_OK): ok = 0
	if (fs_sync_parent_dir(path, &result) != IO_OK): ok = 0
	if (ok == 0): return 0
	char* saved_path = strclone(path)
	free(e.path)
	e.path = saved_path
	free(e.saved_source)
	e.saved_source = strclone(e.document.source)
	free(e.disk_source)
	e.disk_source = strclone(e.document.source)
	e.disk_present = 1
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
	free(e.disk_source)
	e.disk_source = strclone(disk.source)
	e.disk_present = 1
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
	if (e.scene == 0 || e.document.kind != MM_FLOW): return -1
	int hit = -1
	for i in range(e.scene.nodes.length):
		mm_bounds* b = e.scene.nodes[i]
		if (e.document.nodes[i].group == 0 && x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h): hit = i
	return hit

void mm_editor_free(mm_editor* e):
	mm_scene_free(e.scene)
	mm_document_free(e.document)
	free(e.path)
	free(e.saved_source)
	free(e.disk_source)
	for char* text in e.history: free(text)
	__w_list_free(cast(__w_list*, e.history))
	free(e)
