# wbuild: name=mermaid_editor_test arch_only=x64
import lib.testing
import libs.extras.mermaid.editor
import graphics.mermaid

void test_mermaid_editor_undo_redo_and_invalid_source():
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
