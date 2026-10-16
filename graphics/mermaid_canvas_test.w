# wbuild: name=mermaid_canvas_render_test arch_only=x64
import lib.testing
import graphics.mermaid_canvas

void test_canvas_selection_is_clipped_and_never_changes_export_geometry():
	mm_editor* e = mm_editor_new(c"unused.mmd", c"flowchart LR\nA[One] --> B[Two]\n")
	mm_canvas c
	mm_canvas_init(&c)
	c.node = 0
	c.edge = 0
	c.zoom = 2.0
	c.pan_x = -40.0
	c.pan_y = -30.0
	char* before = mm_svg(e.scene)
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 640, 480)
	ui_rect viewport = ui_rect_new(100.0, 80.0, 320.0, 240.0)
	mm_canvas_render(&r, &c, e, viewport, 1)
	asserts(c"selection renders", r.layer_vert_count[0] > 0)
	for i in range(r.layer_vert_count[0]):
		float32* v = &r.layer_verts[0][i * 8]
		asserts(c"selection x clipped", v[0] >= 99.99 && v[0] <= 420.01)
		asserts(c"selection y clipped", v[1] >= 79.99 && v[1] <= 320.01)
	char* after = mm_svg(e.scene)
	assert_strings_equal(before, after)
	assert_equal(0, mm_editor_dirty(e))
	free(before)
	free(after)
	ui_render_destroy(&r)
	mm_editor_free(e)

void test_source_sync_preserves_caret_scroll_and_clamps_to_new_text():
	ui_textarea_state area
	ui_textarea_init(&area)
	ui_textarea_set(&area, c"one\ntwo\nthree")
	ui_textarea_set_caret(&area, 10)
	area.scroll.offset_y = 18.0
	mm_canvas_source_sync(&area, c"one\ntwo\nthree changed")
	assert_equal(10, ui_textarea_caret_offset(&area))
	assert_equal(18, cast(int, area.scroll.offset_y))
	assert_equal(2, area.caret_line)
	mm_canvas_source_sync(&area, c"one")
	assert_equal(3, ui_textarea_caret_offset(&area))
	assert_equal(0, area.caret_line)
	assert_equal(3, area.caret_goal_col)
	area.sel_anchor = 0
	mm_canvas_source_sync(&area, c"one")
	assert_equal(0, area.sel_anchor)
	ui_textarea_free(&area)
