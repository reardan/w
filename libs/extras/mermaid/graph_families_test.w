# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* graph_family_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"graph family parses", d.error == 0)
	return d

void test_graph_requirement_properties_and_relationships():
	char* source = c"requirementDiagram\nrequirement R {\nid: 1\ntext: Correct results\nrisk: high\nverifymethod: test\n}\nelement E {\ntype: simulation\ndocref: report\n}\nE - satisfies -> R\nR <- verifies - E\nR - contains -> E\n"
	mm_document* d = graph_family_parse(source)
	assert_equal(MM_REQUIREMENT, d.kind)
	assert_equal(2, d.nodes.length)
	assert_equal(3, d.edges.length)
	mm_node* n = d.nodes[0]
	assert_equal(4, n.members.length)
	mm_edge* reverse = d.edges[1]
	assert_equal(1, reverse.from_node)
	assert_equal(0, reverse.to_node)
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"requirement text rendered", index_of(svg, c"Correct results") >= 0)
	asserts(c"relationship rendered", index_of(svg, c"satisfies") >= 0)
	char* saved = mm_write(d)
	assert_strings_equal(source, saved)
	free(saved)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_graph_mindmap_ancestry_and_tree_layout():
	mm_document* d = graph_family_parse(c"mindmap\n  root((Ideas))\n    A[First]\n      detail\n    B(Second)\n      detail\n")
	assert_equal(5, d.nodes.length)
	mm_node* n = d.nodes[4]
	assert_equal(3, n.parent)
	mm_scene* s = mm_render(d)
	mm_bounds* root = s.nodes[0]
	mm_bounds* a = s.nodes[1]
	mm_bounds* b = s.nodes[3]
	mm_bounds* leaf = s.nodes[4]
	asserts(c"children advance depth", a.x > root.x + root.w && leaf.x > b.x + b.w)
	asserts(c"sibling subtrees do not overlap", b.y >= a.y + a.h)
	mm_document_free(d)
	char* svg = mm_svg(s)
	asserts(c"scene owns labels", index_of(svg, c"Ideas") >= 0)
	free(svg)
	mm_scene_free(s)

void test_graph_kanban_columns_cards_and_metadata():
	mm_document* d = graph_family_parse(c"kanban\nTodo\n  c[Implement]@{ assigned: 'W team', ticket: W-42, priority: 'High' }\nDone\n  [Test]\n")
	assert_equal(4, d.nodes.length)
	mm_node* card = d.nodes[1]
	assert_equal(0, card.parent)
	assert_equal(3, card.members.length)
	mm_scene* s = mm_render(d)
	mm_bounds* a = s.nodes[0]
	mm_bounds* b = s.nodes[2]
	mm_bounds* c = s.nodes[1]
	asserts(c"columns side by side", b.x > a.x + a.w)
	asserts(c"card inside column", c.x > a.x && c.x + c.w < a.x + a.w && c.y > a.y + 60 && c.y + c.h < a.y + a.h)
	char* svg = mm_svg(s)
	asserts(c"metadata rendered", index_of(svg, c"W-42") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_graph_family_rejections_and_truncations():
	list[char*] bad = list[char*]{c"mindmap\nA\nB", c"mindmap\nA\n  B\n C", c"mindmap\nA\n  ::icon(fa)", c"kanban\nA\n  B\n    C", c"kanban\nA\n  b[B]@{priority:'urgent'}", c"requirementDiagram\nrequirement R {\nrisk: unknown\n}", c"requirementDiagram\nA - verifies -> B", c"requirementDiagram\nelement E {\nid: 1\n}", c"requirementDiagram\nrequirement R {\nid: 1\nid: 2\n}"}
	for char* text in bad:
		mm_document* d = mm_parse(text, strlen(text))
		asserts(c"invalid syntax rejected", d.error != 0)
		asserts(c"no misleading partial preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))
	list[char*] sources = list[char*]{c"mindmap\nroot((Root))\n  child[Text]\n", c"kanban\nTodo\n  task[Text]@{priority: 'High'}\n", c"requirementDiagram\nrequirement R {\nid: 1\nrisk: low\n}\nR - traces -> R\n"}
	for char* text in sources:
		for size in range(strlen(text) + 1):
			mm_document* d = mm_parse(text, size)
			mm_scene* s = mm_render(d)
			asserts(c"error or render", (d.error != 0 && s == 0) || (d.error == 0 && s != 0))
			mm_scene_free(s)
			mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))

void test_graph_accessible_metadata_and_title_once():
	char* text = c"---\ntitle: Components\n---\narchitecture-beta\naccTitle: Accessible architecture\nservice A(server)[Worker]\n"
	mm_document* d = graph_family_parse(text)
	mm_scene* s = mm_render(d)
	int titles = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && strcmp(p.text, c"Components") == 0): titles = titles + 1
	assert_equal(1, titles)
	char* svg = mm_svg(s)
	asserts(c"accessible title exported", index_of(svg, c"Accessible architecture") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
