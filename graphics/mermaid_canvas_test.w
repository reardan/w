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

# Issue #910: copying the diagram offers its source as text, the SVG as
# HTML and a PNG of the scene, which decodes to the scene's size with
# both the white paper and the diagram's ink in it.
void test_canvas_copy_offers_source_svg_and_png():
	char* source = c"flowchart LR\nA[One] --> B[Two]\n"
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)
	assert_equal(1, mm_canvas_copy(&ctx, e))
	assert_strings_equal(source, ui_clipboard_copied(&ctx))
	asserts(c"html flavor is the SVG", starts_with(ctx.clip_out_html, c"<svg"))
	wresult[rgba_image*]* decoded = png_decode_n(ctx.clip_out_png, ctx.clip_out_png_length, 0)
	assert_equal(1, decoded.ok)
	rgba_image* image = decoded.value
	assert_equal(e.scene.width, image.width)
	assert_equal(e.scene.height, image.height)
	int white = 0
	int ink = 0
	for i in range(image.width * image.height):
		int sum = (image.pixels[i * 4] & 255) + (image.pixels[i * 4 + 1] & 255) + (image.pixels[i * 4 + 2] & 255)
		if (sum == 765): white = white + 1
		else if (sum < 600): ink = ink + 1
	asserts(c"paper", white > image.width * image.height / 2)
	asserts(c"ink", ink > 50)
	result_free[rgba_image*](decoded)
	# A source with a syntax error has no scene and copies nothing.
	mm_editor* broken = mm_editor_new(c"unused.mmd", c"flowchart LR\nA[One --> \n")
	if (broken.scene == 0): assert_equal(0, mm_canvas_copy(&ctx, broken))
	mm_editor_free(broken)
	ui_render_destroy(&r)
	mm_editor_free(e)
