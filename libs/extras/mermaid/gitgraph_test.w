# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

void test_gitgraph_heads_parentage_and_merge_geometry():
	char* text = c"gitGraph LR:\ncommit id: \"root\"\nbranch develop\ncommit id: \"feature\" type: HIGHLIGHT\ncheckout main\ncommit id: \"fix\" type: REVERSE\nmerge develop id: \"release\" tag: \"v1\"\n"
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"GitGraph parses", d.error == 0)
	assert_equal(6, d.nodes.length)
	assert_equal(4, d.edges.length)
	mm_node* main = d.nodes[0]
	mm_node* develop = d.nodes[2]
	assert_equal(5, main.value_x)
	assert_equal(3, develop.value_x)
	mm_edge* a = d.edges[2]
	mm_edge* b = d.edges[3]
	assert_equal(4, a.from_node)
	assert_equal(3, b.from_node)
	assert_equal(5, a.to_node)
	assert_equal(5, b.to_node)
	mm_scene* s = mm_render(d)
	mm_bounds* feature = s.nodes[3]
	mm_bounds* release = s.nodes[5]
	asserts(c"branches have distinct lanes", feature.y != release.y)
	asserts(c"commits ordered along timeline", feature.x < release.x)
	mm_document_free(d)
	char* svg = mm_svg(s)
	asserts(c"tag survives document lifetime", index_of(svg, c"v1") >= 0)
	free(svg)
	mm_scene_free(s)

void test_gitgraph_invalid_operations_and_prefixes():
	list[char*] bad = list[char*]{c"gitGraph\ncheckout unknown", c"gitGraph\nbranch main", c"gitGraph\ncommit\nmerge main", c"gitGraph\nbranch a\nmerge main", c"gitGraph\ncommit id: \"same\"\ncommit id: \"same\"", c"gitGraph\ncommit type: INVALID", c"gitGraph\ncommit id: \"a\" id: \"b\"", c"gitGraph\ncherry-pick id: \"a\""}
	for char* text in bad:
		mm_document* d = mm_parse(text, strlen(text))
		asserts(c"invalid GitGraph operation fails", d.error != 0)
		asserts(c"invalid history cannot render", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))
	char* text = c"gitGraph\ncommit id: \"root\"\nbranch feature\ncommit id: \"feature\"\nswitch main\nmerge feature tag: \"release\"\n"
	for size in range(strlen(text) + 1):
		mm_document* d = mm_parse(text, size)
		mm_scene* s = mm_render(d)
		asserts(c"prefix parse/render agree", (d.error == 0 && s != 0) || (d.error != 0 && s == 0))
		mm_scene_free(s)
		mm_document_free(d)

void test_gitgraph_history_bounds():
	string_builder* source = string_from(c"gitGraph\n")
	for i in range(MM_MAX_ITEMS): string_append(source, c"commit\n")
	mm_document* d = mm_parse(source.data, source.length)
	asserts(c"bounded history nodes", d.error != 0)
	mm_document_free(d)
	string_free(source)
