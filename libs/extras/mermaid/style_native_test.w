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

void test_mermaid_native_concave_polygon_preserves_gap():
	mm_scene* scene = new mm_scene()
	scene.items = new list[mm_primitive*]
	scene.nodes = new list[mm_bounds*]
	mm_draw(scene, MM_POLYGON, 20, 20, 80, 80, 0, c"")
	mm_primitive* p = scene.items[0]
	p.points = list[int]{20, 20, 40, 20, 40, 60, 60, 60, 60, 20, 80, 20, 80, 80, 20, 80}
	p.style.mask = MM_STYLE_FILL | MM_STYLE_STROKE
	p.style.fill = 0xff0000
	p.style.stroke = -1
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 100, 100)
	mm_ui_render(&r, scene, ui_rect_new(0.0, 0.0, 100.0, 100.0), 1.0, 0.0, 0.0)
	int left = 0
	int right = 0
	for i in range(0, r.layer_vert_count[0], 3):
		float32* a = &r.layer_verts[0][i * 8]
		float32* b = &r.layer_verts[0][(i + 1) * 8]
		float32* c = &r.layer_verts[0][(i + 2) * 8]
		if (a[1] >= 25.0 && a[1] < 50.0):
			int on_left = a[0] <= 40.0 && b[0] <= 40.0 && c[0] <= 40.0
			int on_right = a[0] >= 60.0 && b[0] >= 60.0 && c[0] >= 60.0
			asserts(c"concave gap is not bridged", on_left || on_right)
			left = left + on_left
			right = right + on_right
	asserts(c"both filled spans visible", left > 0 && right > 0)
	ui_render_destroy(&r)
	mm_scene_free(scene)

# Vertex count of a native render and a checksum of its vertex positions.
int native_hand_drawn_verts(char* source, int* checksum):
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"parse hand-drawn", d.error == 0)
	mm_scene* scene = mm_render(d)
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 800, 400)
	mm_ui_render(&r, scene, ui_rect_new(0.0, 0.0, 800.0, 400.0), 1.0, 0.0, 0.0)
	int count = r.layer_vert_count[0]
	int sum = 0
	for i in range(count):
		float32* v = &r.layer_verts[0][i * 8]
		sum = (sum * 31 + cast(int, v[0] * 4.0) * 7 + cast(int, v[1] * 4.0)) % 1000003
	*checksum = sum
	ui_render_destroy(&r)
	mm_scene_free(scene)
	mm_document_free(d)
	return count

# `look: handDrawn` natively: the same seeded double strokes as the SVG,
# deterministic, and different from the crisp classic outline.
void test_mermaid_native_hand_drawn_look():
	char* source = c"---\nconfig:\n  look: handDrawn\n  handDrawnSeed: 11\n---\nflowchart LR\nA[Hand drawn box] --> B[Second]\n"
	int sum = 0
	int first = native_hand_drawn_verts(source, &sum)
	int again = 0
	assert_equal(first, native_hand_drawn_verts(source, &again))
	assert_equal(sum, again)
	int other = 0
	native_hand_drawn_verts(c"---\nconfig:\n  look: handDrawn\n  handDrawnSeed: 12\n---\nflowchart LR\nA[Hand drawn box] --> B[Second]\n", &other)
	asserts(c"another seed draws other strokes", other != sum)
	int crisp = 0
	int classic = native_hand_drawn_verts(c"---\nconfig:\n  theme: default\n---\nflowchart LR\nA[Hand drawn box] --> B[Second]\n", &crisp)
	asserts(c"rough strokes draw more segments", first > classic)
