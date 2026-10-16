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

mm_editor* mm_editor_new(char* path, char* source):
	if (path == 0 || source == 0 || strlen(source) > MM_MAX_SOURCE): return 0
	mm_editor* e = new mm_editor()
	e.path = strclone(path)
	e.saved_source = strclone(source)
	e.document = mm_parse(source, strlen(source))
	e.scene = mm_render(e.document)
	e.history = new list[char*]
	e.history.push(strclone(source))
	return e

int mm_editor_dirty(mm_editor* e):
	return strcmp(e.document.source, e.saved_source) != 0

void mm_editor_load(mm_editor* e, char* source):
	mm_document* next = mm_parse(source, strlen(source))
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

int mm_editor_save(mm_editor* e):
	io_result result
	if (mm_save(e.document, e.path, &result) != IO_OK): return 0
	free(e.saved_source)
	e.saved_source = strclone(e.document.source)
	return 1

void mm_editor_free(mm_editor* e):
	mm_scene_free(e.scene)
	mm_document_free(e.document)
	free(e.path)
	free(e.saved_source)
	for char* text in e.history: free(text)
	__w_list_free(cast(__w_list*, e.history))
	free(e)
