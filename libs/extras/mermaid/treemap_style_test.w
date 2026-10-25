# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

int treemap_styled(mm_scene* s, int fill):
	int count = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_BOX && (p.style.mask & 1) && p.style.fill == fill): count = count + 1
	return count

void test_treemap_class_definitions_style_cells():
	char* source = c"---\nconfig:\n  theme: dark\n---\ntreemap-beta\n\"Section 1\"\n    \"Leaf 1.1\": 12\n    \"Section 1.2\":::class1\n      \"Leaf 1.2.1\": 12\n\"Section 2\"\n    \"Leaf 2.1\": 20:::class1\n    \"Leaf 2.2\": 5 :::other\nclassDef class1 fill:red,color:blue,stroke:#FFD600;\nclassDef other fill:#00ff00\n"
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"styled treemap parses", d.error == 0)
	mm_data_item* group = d.data.items[2]
	assert_strings_equal(c"class1", group.target)
	assert_equal(5, group.kind)
	mm_data_item* leaf = d.data.items[5]
	assert_strings_equal(c"class1", leaf.target)
	assert_equal(20000, leaf.a)
	assert_equal(7, leaf.style.mask)
	assert_equal(0xff0000, leaf.style.fill)
	assert_equal(0xffd600, leaf.style.stroke)
	mm_data_item* plain = d.data.items[1]
	assert_equal(0, plain.style.mask)
	mm_scene* s = mm_render(d)
	assert_equal(2, treemap_styled(s, 0xff0000))
	assert_equal(1, treemap_styled(s, 0x00ff00))
	char* svg = mm_svg(s)
	asserts(c"class fill survives the dark theme", index_of(svg, c"fill=\"#ff0000\" stroke=\"#ffd600\"") >= 0)
	asserts(c"class text colour applied", index_of(svg, c"fill=\"#0000ff\" stroke=\"none\"") >= 0)
	free(svg)
	char* saved = mm_write(d)
	assert_strings_equal(source, saved)
	free(saved)
	mm_scene_free(s)
	mm_document_free(d)
	for size in range(strlen(source) + 1):
		mm_document* prefix = mm_parse(source, size)
		mm_scene* scene = mm_render(prefix)
		asserts(c"styled treemap prefix parse and render agree", (prefix.error == 0 && scene != 0) || (prefix.error != 0 && scene == 0))
		mm_scene_free(scene)
		mm_document_free(prefix)

void test_treemap_class_diagnostics():
	list[char*] bad = list[char*]{c"treemap-beta\n\"A\": 1:::missing\n", c"treemap-beta\n\"A\": 1:::\n", c"treemap-beta\n\"A\": 1\nclassDef x colour:red\n", c"treemap-beta\n\"A\": 1\nstyle B fill:red\n"}
	list[char*] messages = list[char*]{c"assigned style class has no classDef", c"expected entity or node identifier", c"unsupported style property; supported: fill, stroke, color, stroke-width, stroke-dasharray, opacity, fill-opacity, font-weight, font-style, font-size, font-family, rx, ry", c"style target matches no item"}
	for i in range(bad.length):
		mm_document* d = mm_parse(bad[i], strlen(bad[i]))
		assert_strings_equal(messages[i], d.error)
		asserts(c"invalid treemap style has no preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))
	__w_list_free(cast(__w_list*, messages))
