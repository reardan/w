# wbuild: name=mermaid_style_native_test arch_only=x64
import lib.testing
import libs.extras.mermaid.parser
import graphics.mermaid

void test_mermaid_native_palette_and_nested_clip():
	char* source = c"---\nconfig:\n  theme: dark\n---\nflowchart LR\nA[Box] --> B{Diamond} --> C((Circle))\nstyle A,B,C fill:red,stroke:blue,color:white,stroke-width:4\n"
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"parse native style", d.error == 0)
	mm_scene* scene = mm_render(d)
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 640, 480)
	ui_rect clip = ui_rect_new(80.0, 80.0, 420.0, 300.0)
	ui_clip_push(&r, clip)
	mm_ui_render(&r, scene, ui_rect_new(0.0, 0.0, 640.0, 480.0), 0.5, 30.0, 50.0)
	assert_equal(1, r.clip_depth[0])
	int red = 0
	int blue = 0
	for i in range(r.layer_vert_count[0]):
		float32* v = &r.layer_verts[0][i * 8]
		asserts(c"styled geometry clipped x", v[0] >= 79.99 && v[0] <= 500.01)
		asserts(c"styled geometry clipped y", v[1] >= 79.99 && v[1] <= 380.01)
		if (v[4] > 0.99 && v[5] < 0.01 && v[6] < 0.01): red = red + 1
		if (v[4] < 0.01 && v[5] < 0.01 && v[6] > 0.99): blue = blue + 1
	asserts(c"native red fill matches SVG", red > 0)
	asserts(c"native blue stroke matches SVG", blue > 0)
	ui_render_destroy(&r)
	mm_scene_free(scene)
	mm_document_free(d)

void test_mermaid_native_transparent_interior():
	mm_scene* scene = new mm_scene()
	scene.items = new list[mm_primitive*]
	scene.nodes = new list[mm_bounds*]
	mm_draw(scene, MM_BOX, 20, 20, 120, 120, 0, c"")
	mm_primitive* p = scene.items[0]
	p.style.mask = 3
	p.style.fill = -1
	p.style.stroke = 0
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 200, 200)
	mm_ui_render(&r, scene, ui_rect_new(0.0, 0.0, 200.0, 200.0), 1.0, 0.0, 0.0)
	asserts(c"outline is visible", r.layer_vert_count[0] > 0)
	for i in range(r.layer_vert_count[0]):
		float32* v = &r.layer_verts[0][i * 8]
		asserts(c"transparent interior not painted", v[0] < 25.0 || v[0] > 115.0 || v[1] < 25.0 || v[1] > 115.0)
	ui_render_destroy(&r)
	mm_scene_free(scene)
