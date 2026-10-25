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
	list[char*] bad = list[char*]{c"gitGraph\ncheckout unknown", c"gitGraph\nbranch \"\"", c"gitGraph\nbranch main", c"gitGraph\ncommit\nmerge main", c"gitGraph\nbranch a\nmerge main", c"gitGraph\ncommit id: \"same\"\nbranch b\ncommit\ncheckout main\ncommit\nmerge b id: \"same\"",c"gitGraph\ncommit type: INVALID", c"gitGraph\ncommit id: \"a\" id: \"b\"", c"gitGraph\ncherry-pick id: \"a\""}
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

void test_gitgraph_cherry_pick_preserves_branch_ancestry():
	char* text = c"gitGraph\ncommit id: \"base\"\nbranch feature\ncommit id: \"patch\"\ncheckout main\ncherry-pick id: \"patch\" tag: \"backport\"\n"
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"cherry pick parses", d.error == 0)
	assert_equal(5, d.nodes.length)
	assert_equal(2, d.edges.length)
	mm_node* picked = d.nodes[4]
	mm_edge* edge = d.edges[1]
	assert_equal(0, picked.parent)
	assert_equal(1, edge.from_node)
	assert_equal(4, edge.to_node)
	assert_strings_equal(c"patch", picked.label)
	mm_property* origin = picked.metadata[0]
	assert_strings_equal(c"patch", origin.value)
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"pick tag renders", index_of(svg, c"backport") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_gitgraph_cherry_pick_merge_parent_validation():
	char* text = c"gitGraph\ncommit id: \"base\"\nbranch feature\ncommit id: \"patch\"\ncheckout main\ncommit id: \"fix\"\nmerge feature id: \"merge\"\ncheckout feature\ncherry-pick id: \"merge\" parent: \"fix\"\n"
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"pick merge immediate parent", d.error == 0)
	mm_document_free(d)
	list[char*] bad = list[char*]{c"gitGraph\ncommit id: \"a\"\ncherry-pick id: \"a\"", c"gitGraph\ncommit id: \"a\"\nbranch b\ncommit id: \"b\"\ncheckout main\ncherry-pick id: \"b\" parent: \"missing\"", c"gitGraph\ncommit id: \"a\"\nbranch b\ncommit id: \"b\"\ncheckout main\ncommit id: \"c\"\nmerge b id: \"m\"\ncheckout b\ncherry-pick id: \"m\""}
	for char* source in bad:
		d = mm_parse(source, strlen(source))
		asserts(c"invalid cherry pick rejected", d.error != 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))

void test_gitgraph_order_and_vertical_orientations():
	for direction in list[char*]{c"TB", c"BT"}:
		string_builder* text = string_from(c"gitGraph ")
		string_append(text, direction)
		string_append(text, c":\ncommit id: \"base\"\nbranch z order: 9\ncommit id: \"z\"\ncheckout main\nbranch a order: 1\ncommit id: \"a\"\n")
		mm_document* d = mm_parse(text.data, text.length)
		asserts(c"vertical graph parses", d.error == 0)
		mm_scene* s = mm_render(d)
		mm_bounds* base = s.nodes[1]
		mm_bounds* z = s.nodes[3]
		mm_bounds* a = s.nodes[5]
		asserts(c"explicit order changes lanes", a.x < z.x)
		if (strcmp(direction, c"TB") == 0): asserts(c"TB time increases", base.y < z.y && z.y < a.y)
		else: asserts(c"BT time decreases", base.y > z.y && z.y > a.y)
		mm_scene_free(s)
		mm_document_free(d)
		string_free(text)

void test_gitgraph_vertical_lane_bounds_and_long_labels():
	char* text = c"gitGraph BT:\ncommit id: \"root\"\nbranch a_very_long_branch_name_that_needs_space\ncommit id: \"long_label_commit\"\ncheckout main\nbranch another\ncommit id: \"tip\"\n"
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"long vertical labels parse", d.error == 0)
	mm_scene* s = mm_render(d)
	mm_bounds* long_branch = s.nodes[2]
	mm_bounds* next_branch = s.nodes[4]
	mm_node* branch = d.nodes[2]
	asserts(c"vertical branch labels reserve width", next_branch.x > long_branch.x + strlen(branch.label) * 8)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.group): continue
		mm_bounds* b = s.nodes[i]
		int on_lane = 0
		for mm_primitive* p in s.items:
			if (p.kind == MM_LINE && p.dashed && p.x == b.x && p.x2 == b.x && p.y <= b.y && p.y2 >= b.y): on_lane = 1
		asserts(c"BT commits sit on branch line", on_lane)
	mm_scene_free(s)
	mm_document_free(d)
	text = c"gitGraph\ncommit\nbranch x order: \"\"\ncommit\n"
	d = mm_parse(text, strlen(text))
	asserts(c"empty order rejected", d.error != 0)
	mm_document_free(d)
