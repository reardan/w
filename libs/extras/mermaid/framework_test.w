# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* framework_parse(char* text):
	mm_document* d = mm_parse(text, strlen(text))
	if (d.error != 0): println2(d.error)
	asserts(c"framework parses", d.error == 0)
	return d

void test_framework_treeview_and_fishbone_ancestry():
	mm_document* d = framework_parse(c"treeView-beta\nproject/\n  src/\n    main.w\n  README.md\n")
	mm_node* leaf = d.nodes[2]
	assert_equal(1, leaf.parent)
	mm_scene* s = mm_render(d)
	mm_bounds* root = s.nodes[0]
	mm_bounds* b = s.nodes[2]
	asserts(c"tree rows retain source order", b.y > root.y && b.x > root.x)
	mm_scene_free(s)
	mm_document_free(d)
	d = framework_parse(c"ishikawa-beta\nFailure\nEquipment\n  Lens\n    Scratched\nPeople\n  Training\n")
	leaf = d.nodes[4]
	assert_equal(0, leaf.parent)
	leaf = d.nodes[3]
	assert_equal(2, leaf.parent)
	s = mm_render(d)
	mm_bounds* head = s.nodes[0]
	mm_bounds* top = s.nodes[1]
	mm_bounds* bottom = s.nodes[4]
	asserts(c"causes alternate around spine", top.y < head.y && bottom.y > head.y)
	asserts(c"problem at head of spine", head.x > bottom.x)
	mm_scene_free(s)
	mm_document_free(d)

void test_framework_cynefin_domains_and_transitions():
	mm_document* d = framework_parse(c"cynefin-beta\ntitle Decisions\ncomplex\n\"Experiment\"\nclear\n\"Procedure\"\ncomplex --> complicated : \"Learned\"\n")
	assert_equal(5, d.nodes.length)
	assert_equal(1, d.edges.length)
	mm_node* n = d.nodes[0]
	assert_equal(1, n.members.length)
	mm_scene* s = mm_render(d)
	mm_bounds* a = s.nodes[0]
	mm_bounds* b = s.nodes[1]
	mm_bounds* c = s.nodes[4]
	asserts(c"domains occupy separate regions", b.x > a.x + a.w)
	asserts(c"confusion centered between rows", c.y > a.y + a.h)
	char* svg = mm_svg(s)
	asserts(c"items exported", index_of(svg, c"Experiment") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_framework_wardley_normalized_axes_and_dependencies():
	mm_document* d = framework_parse(c"wardley-beta\ntitle Value chain\nanchor User [0.9, 0.1]\ncomponent Service [0.6, 0.5]\ncomponent Database [0.2, 1.0]\nUser -> Service\nService --> Database\n")
	mm_node* a = d.nodes[0]
	assert_equal(900, a.value_y)
	assert_equal(100, a.value_x)
	assert_equal(2, d.edges.length)
	mm_scene* s = mm_render(d)
	mm_bounds* first = s.nodes[0]
	mm_bounds* last = s.nodes[2]
	asserts(c"visibility increases upward, evolution rightward", first.y < last.y && first.x < last.x)
	char* svg = mm_svg(s)
	asserts(c"axis labels rendered", index_of(svg, c"Commodity") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_framework_invalid_input_and_prefixes():
	list[char*] bad = list[char*]{c"wardley-beta\ncomponent A [1.1, 0.5]", c"wardley-beta\ncomponent A [0.5, -1]", c"wardley-beta\nA -> Missing", c"cynefin-beta\nunknown", c"cynefin-beta\n\"No domain\"", c"treeView-beta\nA\n  B\n C", c"treeView-beta\nA icon(custom)", c"ishikawa-beta\n"}
	for char* text in bad:
		mm_document* d = mm_parse(text, strlen(text))
		asserts(c"invalid framework fails explicitly", d.error != 0)
		asserts(c"invalid framework has no preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))
	list[char*] samples = list[char*]{c"wardley-beta\ncomponent A [0.5, 0.6]\nA -> A\n", c"cynefin-beta\ncomplex\n\"Text\"\ncomplex --> clear : \"Resolved\"\n", c"treeView-beta\nA/\n  B\n", c"ishikawa-beta\nProblem\nCause\n  Detail\n"}
	for char* text in samples:
		for size in range(strlen(text) + 1):
			mm_document* d = mm_parse(text, size)
			mm_scene* s = mm_render(d)
			asserts(c"parse and render agree", (d.error == 0 && s != 0) || (d.error != 0 && s == 0))
			mm_scene_free(s)
			mm_document_free(d)
	__w_list_free(cast(__w_list*, samples))
