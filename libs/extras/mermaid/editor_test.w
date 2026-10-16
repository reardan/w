# wbuild: name=mermaid_editor_test arch_only=x64
import lib.testing
import libs.extras.mermaid.editor
import graphics.mermaid

void test_mermaid_editor_undo_redo_and_invalid_source():
	unlink(c"bin/mermaid_editor_state.mmd")
	mm_editor* e = mm_editor_new(c"bin/mermaid_editor_state.mmd", c"flowchart LR\nA --> B\n")
	assert_equal(0, mm_editor_dirty(e))
	assert_equal(1, mm_editor_change(e, c"flowchart LR\nA --> C\n"))
	assert_equal(1, mm_editor_dirty(e))
	assert_equal(1, mm_editor_change(e, c"flowchart LR\nA["))
	asserts(c"syntax error retained in editor", e.document.error != 0)
	assert_equal(0, cast(int, e.scene))
	assert_equal(1, mm_editor_undo(e, 0))
	asserts(c"undo restores preview", e.scene != 0)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_equal(0, mm_editor_dirty(e))
	assert_equal(0, mm_editor_undo(e, 0))
	assert_equal(1, mm_editor_undo(e, 1))
	assert_equal(1, mm_editor_change(e, c"erDiagram\nENTITY\n"))
	assert_equal(0, mm_editor_undo(e, 1))
	assert_equal(1, mm_editor_save(e))
	assert_equal(0, mm_editor_dirty(e))
	mm_document* saved = mm_read(e.path)
	assert_strings_equal(e.document.source, saved.source)
	mm_document_free(saved)
	mm_editor_free(e)

void test_mermaid_editor_save_failure_preserves_dirty_state():
	mm_editor* e = mm_editor_new(c"bin/nonexistent_mermaid_directory/test.mmd", c"erDiagram\nA\n")
	mm_editor_change(e, c"erDiagram\nB\n")
	assert_equal(0, mm_editor_save(e))
	assert_equal(1, mm_editor_dirty(e))
	assert_strings_equal(c"erDiagram\nB\n", e.document.source)
	mm_editor_free(e)

void test_mermaid_editor_history_limit():
	mm_editor* e = mm_editor_new(c"unused.mmd", c"erDiagram\nA\n")
	for i in range(48):
		string_builder* source = string_from(c"erDiagram\nA")
		string_append_int(source, i)
		mm_editor_change(e, source.data)
		string_free(source)
	assert_equal(32, e.history.length)
	for i in range(31): assert_equal(1, mm_editor_undo(e, 0))
	assert_equal(0, mm_editor_undo(e, 0))
	mm_editor_free(e)

void test_mermaid_native_display_list_is_clipped():
	char* source = c"erDiagram\nA ||..o{ B : relates\n"
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"parse", d.error == 0)
	mm_scene* scene = mm_render(d)
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 640, 480)
	ui_rect clip = ui_rect_new(100.0, 100.0, 300.0, 200.0)
	ui_clip_push(&r, clip)
	mm_ui_render(&r, scene, clip, 0.75, -15.0, -10.0)
	assert_equal(1, r.clip_depth[0])
	asserts(c"native geometry emitted", r.layer_vert_count[0] > 0)
	for i in range(r.layer_vert_count[0]):
		float32* v = &r.layer_verts[0][i * 8]
		asserts(c"clipped x", v[0] >= 99.99 && v[0] <= 400.01)
		asserts(c"clipped y", v[1] >= 99.99 && v[1] <= 300.01)
	ui_render_destroy(&r)
	mm_scene_free(scene)
	mm_document_free(d)

void test_mermaid_native_uml_markers_and_groups_are_clipped():
	list[char*] sources = list[char*]{c"classDiagram\nnamespace Domain {\nclass A {\n+field\n+run()\n}\nA *--|> B\n}\nB o..> C\n", c"stateDiagram-v2\n[*] --> Outer\nstate Outer {\n[*] --> A\nstate F <<fork>>\nA --> F\nF --> [*]\n}\nOuter --> [*]\n"}
	for char* source in sources:
		mm_document* d = mm_parse(source, strlen(source))
		asserts(c"UML parse", d.error == 0)
		mm_scene* scene = mm_render(d)
		ui_renderer r
		ui_render_init_headless(&r)
		ui_render_begin(&r, 640, 480)
		ui_rect clip = ui_rect_new(120.0, 80.0, 300.0, 250.0)
		ui_clip_push(&r, clip)
		mm_ui_render(&r, scene, ui_rect_new(0.0, 0.0, 640.0, 480.0), 1.5, -160.0, -200.0)
		assert_equal(1, r.clip_depth[0])
		asserts(c"UML geometry emitted", r.layer_vert_count[0] > 0)
		for i in range(r.layer_vert_count[0]):
			float32* v = &r.layer_verts[0][i * 8]
			asserts(c"UML clipped x", v[0] >= 119.99 && v[0] <= 420.01)
			asserts(c"UML clipped y", v[1] >= 79.99 && v[1] <= 330.01)
		ui_render_destroy(&r)
		mm_scene_free(scene)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))

void test_mermaid_multiple_diagrams_and_structured_edits():
	char* original = c"# Document\r\n```text\n```mermaid\n```\n~~~mermaid\r\nflowchart LR\r\nA[First]\r\n~~~\r\nBetween\r\n```mermaid\nflowchart TD\nB[Second]\n```\nAfter\n"
	mm_editor* e = mm_editor_new(c"bin/mermaid_multiple.mmd", original)
	assert_equal(2, mm_source_diagram_count(original, strlen(original)))
	asserts(c"first diagram parses", e.document.error == 0)
	assert_strings_equal(c"A", e.document.nodes[0].id)
	assert_equal(1, mm_editor_select(e, 1))
	assert_strings_equal(c"B", e.document.nodes[0].id)
	assert_equal(0, mm_editor_dirty(e))
	assert_equal(0, mm_editor_select(e, 2))
	assert_equal(0, mm_editor_select(e, -1))
	assert_equal(1, mm_editor_add_node(e, c"C", c"Café"))
	assert_equal(0, mm_editor_add_node(e, c"C", c"duplicate"))
	assert_equal(0, mm_editor_add_node(e, c"bad id", c"bad"))
	assert_equal(0, mm_editor_add_node(e, c"D", c"bad\"quote"))
	assert_equal(1, mm_editor_add_edge(e, c"B", c"C"))
	assert_equal(1, e.document.edges.length)
	assert_equal(0, mm_editor_add_edge(e, c"missing", c"C"))
	asserts(c"unselected diagram bytes preserved", index_of(e.document.source, c"flowchart LR\r\nA[First]\r\n~~~\r\nBetween\r\n") >= 0)
	asserts(c"trailing Markdown preserved", index_of(e.document.source, c"C[\"Café\"]\nB --> C\n```\nAfter\n") >= 0)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_equal(0, e.document.edges.length)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(original, e.document.source)
	assert_equal(1, e.selected)
	assert_equal(0, mm_editor_dirty(e))
	assert_equal(1, mm_editor_undo(e, 1))
	assert_equal(2, e.document.nodes.length)
	mm_editor_free(e)

void test_mermaid_external_changes_and_reload():
	char* path = c"bin/mermaid_conflict_test.mmd"
	io_result result
	char* initial = c"flowchart LR\nA\n"
	char* changed = c"flowchart LR\nB\n"
	assert_equal(IO_OK, file_write_durable(path, initial, strlen(initial), &result))
	mm_editor* e = mm_editor_open(path)
	asserts(c"open existing snapshot", e != 0)
	assert_equal(0, mm_editor_external_change(e))
	mm_editor_change(e, c"flowchart LR\nC\n")
	assert_equal(IO_OK, file_write_durable(path, changed, strlen(changed), &result))
	assert_equal(1, mm_editor_external_change(e))
	assert_equal(0, mm_editor_save(e))
	assert_equal(1, mm_editor_dirty(e))
	mm_document* disk = mm_read(path)
	assert_strings_equal(changed, disk.source)
	mm_document_free(disk)
	assert_equal(1, mm_editor_reload(e))
	assert_equal(0, mm_editor_dirty(e))
	assert_equal(0, mm_editor_external_change(e))
	assert_strings_equal(changed, e.document.source)
	assert_equal(0, mm_editor_undo(e, 0))
	mm_editor_change(e, initial)
	assert_equal(1, mm_editor_save(e))
	mm_editor_free(e)

void test_mermaid_selection_error_uses_document_lines():
	char* source = c"Text\n```mermaid\nflowchart LR\nA\n```\n```mermaid\nflowchart LR\nB[\n```\n"
	mm_document* d = mm_parse_selected(source, strlen(source), 1)
	asserts(c"second diagram error", d.error != 0)
	asserts(c"error uses original document offset", d.error_line >= 8)
	assert_strings_equal(source, d.source)
	mm_document_free(d)
	d = mm_parse_selected(source, strlen(source), 2)
	asserts(c"invalid index diagnosed", d.error != 0)
	mm_document_free(d)

void test_mermaid_graph_hit_and_long_path_save_as():
	string_builder* path = string_from(c"bin/mermaid_long_")
	for i in range(140): string_append_char(path, 'x')
	string_append(path, c".mmd")
	unlink(path.data)
	mm_editor* e = mm_editor_new(c"bin/unused_mermaid_source.mmd", c"flowchart LR\nA[Alpha] --> B[Beta]\n")
	mm_bounds* box = e.scene.nodes[1]
	assert_equal(1, mm_editor_hit(e, box.x + box.w / 2, box.y + box.h / 2))
	assert_equal(-1, mm_editor_hit(e, -100, -100))
	assert_equal(1, mm_editor_save_as(e, path.data))
	asserts(c"long path retained", strlen(e.path) > 127)
	assert_equal(0, mm_editor_external_change(e))
	mm_editor* other = mm_editor_new(c"bin/unused_mermaid_other.mmd", c"flowchart LR\nOther\n")
	assert_equal(0, mm_editor_save_as(other, path.data))
	mm_document* disk = mm_read(path.data)
	assert_strings_equal(e.document.source, disk.source)
	mm_document_free(disk)
	mm_editor_free(other)
	unlink(path.data)
	assert_equal(1, mm_editor_external_change(e))
	mm_editor_change(e, c"flowchart LR\nChanged\n")
	assert_equal(0, mm_editor_save(e))
	assert_equal(1, mm_editor_dirty(e))
	mm_editor_free(e)
	string_free(path)

void test_mermaid_selection_survives_invalid_first_frontmatter():
	char* source = c"```mermaid\n---\ntitle: |\n---\nflowchart LR\nA\n```\n```mermaid\nflowchart LR\nB\n```\n"
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	asserts(c"invalid first diagram", e.document.error != 0)
	assert_equal(2, mm_source_diagram_count(source, strlen(source)))
	assert_equal(1, mm_editor_select(e, 1))
	asserts(c"second diagram still usable", e.document.error == 0)
	assert_strings_equal(c"B", e.document.nodes[0].id)
	mm_editor_free(e)
	string_builder* bom = string_new()
	string_append_char(bom, 239)
	string_append_char(bom, 187)
	string_append_char(bom, 191)
	string_append(bom, source)
	assert_equal(2, mm_source_diagram_count(bom.data, bom.length))
	mm_document* d = mm_parse_selected(bom.data, bom.length, 1)
	asserts(c"BOM-selected second diagram", d.error == 0)
	mm_document_free(d)
	string_free(bom)

void test_mermaid_editor_stale_constructor_source_is_not_disk_baseline():
	char* path = c"bin/mermaid_stale_constructor.mmd"
	char* original = c"flowchart LR\nOriginal\n"
	char* current = c"flowchart LR\nExternal\n"
	io_result result
	assert_equal(IO_OK, file_write_durable(path, current, strlen(current), &result))
	mm_editor* e = mm_editor_new(path, original)
	assert_equal(1, mm_editor_external_change(e))
	assert_equal(0, mm_editor_save(e))
	mm_document* disk = mm_read(path)
	assert_strings_equal(current, disk.source)
	mm_document_free(disk)
	mm_editor_free(e)

void test_mermaid_immutable_edit_keeps_selected_diagram():
	char* source = c"```mermaid\nflowchart LR\nA\n```\n```mermaid\nflowchart LR\nB\n```\n"
	mm_document* d = mm_parse_selected(source, strlen(source), 1)
	int offset = index_of(source, c"B\n")
	mm_document* next = mm_edit(d, offset, offset + 1, c"Changed", 7)
	asserts(c"selected edit parses", next != 0 && next.error == 0)
	assert_equal(1, next.diagram_index)
	assert_strings_equal(c"Changed", next.nodes[0].id)
	assert_strings_equal(source, d.source)
	mm_document_free(next)
	mm_document_free(d)

void test_mermaid_unselected_unclosed_fence_reports_its_opening():
	char* source = c"```mermaid\nflowchart LR\nA\n```\n```mermaid\nflowchart LR\nB\n"
	mm_document* d = mm_parse_selected(source, strlen(source), 0)
	asserts(c"whole envelope must have closed fences", d.error != 0)
	assert_strings_equal(c"unterminated Mermaid fence", d.error)
	assert_equal(5, d.error_line)
	assert_equal(1, d.error_column)
	assert_equal(index_of(source, c"```mermaid\nflowchart LR\nB"), d.error_offset)
	assert_strings_equal(source, d.source)
	mm_document_free(d)
