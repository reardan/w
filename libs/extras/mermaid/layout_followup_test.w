# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

void test_mermaid_layered_order_reduces_simple_crossing():
	char* text = c"flowchart TB\nA\nB\nC\nD\nA-->D\nB-->C\n"
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"crossing graph parses", d.error == 0)
	mm_scene* s = mm_render(d)
	mm_bounds* a = s.nodes[0]
	mm_bounds* b = s.nodes[1]
	mm_bounds* c = s.nodes[2]
	mm_bounds* end = s.nodes[3]
	asserts(c"rank order follows predecessors", (a.x < b.x) == (end.x < c.x))
	mm_scene_free(s)
	mm_document_free(d)

void test_mermaid_force_layout_is_deterministic_and_nonoverlapping():
	char* text = c"---\nconfig:\n  layout: force\n---\nerDiagram\nA ||--o{ B : owns\nB ||--o{ C : has\nC ||--o{ A : links\nD\n"
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"force configuration parses", d.error == 0)
	assert_equal(1, d.layout_algorithm)
	mm_scene* s = mm_render(d)
	mm_scene* again = mm_render(d)
	char* svg = mm_svg(s)
	char* svg2 = mm_svg(again)
	assert_strings_equal(svg, svg2)
	for i in range(s.nodes.length):
		mm_bounds* a = s.nodes[i]
		asserts(c"positive bounds", a.x >= 0 && a.y >= 0)
		for j in range(i + 1, s.nodes.length):
			mm_bounds* b = s.nodes[j]
			asserts(c"force boxes do not overlap", a.x + a.w <= b.x || b.x + b.w <= a.x || a.y + a.h <= b.y || b.y + b.h <= a.y)
	free(svg)
	free(svg2)
	mm_scene_free(s)
	mm_scene_free(again)
	mm_document_free(d)

void test_mermaid_force_nested_scope_and_invalid_configuration():
	char* text = c"---\nconfig:\n  layout: force\n---\nflowchart LR\nsubgraph Outer\nA-->B\nend\nB-->C\n"
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"nested force parses", d.error == 0)
	mm_scene* s = mm_render(d)
	mm_bounds* outer = s.nodes[0]
	for i in range(1, 3):
		mm_bounds* b = s.nodes[i]
		asserts(c"child within force group", b.x >= outer.x && b.y >= outer.y && b.x + b.w <= outer.x + outer.w && b.y + b.h <= outer.y + outer.h)
	mm_scene_free(s)
	mm_document_free(d)
	list[char*] bad = list[char*]{c"---\nconfig:\n  layout: cose-bilkent\n---\nflowchart LR\nA", c"---\nconfig:\n  layout: force\n  layout: dagre\n---\nflowchart LR\nA", c"---\nconfig:\n  layout: force\n---\npie\n\"A\": 2", c"---\nconfig:\n  layout: elk\n---\npie\n\"A\": 2"}
	for char* source in bad:
		d = mm_parse(source, strlen(source))
		asserts(c"unsupported layout diagnosed", d.error != 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))

# `layout: elk` is accepted and recorded, and drawn with the native layered
# layout (the same scene as dagre) for flowcharts and agentflows alike.
void test_mermaid_elk_layout_uses_layered_approximation():
	list[char*] bodies = list[char*]{c"flowchart LR\nA-->B\nA-->C\nB-->D\n", c"agentflow-beta TB\nflow tools[\"Tools\"]\na[\"a\"]@{ shape: tool }\nb[\"b\"]@{ shape: tool }\nend\ntools@{ algorithm: \"elk.rectpacking\" }\n"}
	for char* body in bodies:
		string_builder* elk = string_from(c"---\nconfig:\n  layout: elk\n---\n")
		string_append(elk, body)
		string_builder* dagre = string_from(c"---\nconfig:\n  layout: dagre\n---\n")
		string_append(dagre, body)
		mm_document* d = mm_parse(elk.data, elk.length)
		if (d.error != 0): println2(d.error)
		asserts(c"elk layout parses", d.error == 0)
		assert_equal(2, d.layout_algorithm)
		mm_document* reference = mm_parse(dagre.data, dagre.length)
		asserts(c"dagre layout parses", reference.error == 0)
		mm_scene* s = mm_render(d)
		mm_scene* r = mm_render(reference)
		asserts(c"elk scene renders", s != 0 && s.items.length > 0)
		assert_equal(r.nodes.length, s.nodes.length)
		for i in range(s.nodes.length):
			mm_bounds* a = s.nodes[i]
			mm_bounds* b = r.nodes[i]
			asserts(c"elk places nodes as the layered layout", a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h)
		char* svg = mm_svg(s)
		asserts(c"elk exports SVG", index_of(svg, c"<svg") >= 0)
		free(svg)
		char* written = mm_write(d)
		assert_strings_equal(d.source, written)
		free(written)
		mm_scene_free(s)
		mm_scene_free(r)
		mm_document_free(d)
		mm_document_free(reference)
		string_free(elk)
		string_free(dagre)
	__w_list_free(cast(__w_list*, bodies))

void test_mermaid_extra_flow_shapes_and_edge_styles():
	char* text = c"flowchart LR\nA([Stadium])-->B[[Subroutine]]-->C{{Hexagon}}-->D[/Slant/]-->E[\\Reverse\\]-->F[/Trap\\]-->G[\\Inverse/]\nlinkStyle default stroke:blue\nlinkStyle 0,2 stroke:red,stroke-width:4,color:green\n"
	mm_document* d = mm_parse(text, strlen(text))
	if (d.error != 0): println2(d.error)
	asserts(c"expanded shapes parse", d.error == 0)
	assert_equal(7, d.nodes.length)
	assert_equal(6, d.edges.length)
	for i in range(7):
		mm_node* n = d.nodes[i]
		assert_equal(21 + i, n.shape)
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"stadium radius exported", index_of(svg, c"rx=\"30\"") >= 0)
	asserts(c"specific link stroke", index_of(svg, c"stroke=\"#ff0000\"") >= 0)
	asserts(c"default link stroke", index_of(svg, c"stroke=\"#0000ff\"") >= 0)
	int styled = 0
	for mm_primitive* p in s.items:
		if (mm_paint_stroke(p) == 0xff0000):
			assert_equal(4, mm_paint_width(p))
			styled = styled + 1
	asserts(c"specific edge primitives styled", styled > 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_mermaid_extra_shapes_truncation_and_link_indices():
	char* text = c"flowchart LR\nA([a])-->B{{b}}-->C[/c\\]\nlinkStyle 0 stroke:red\n"
	for length in range(strlen(text) + 1):
		mm_document* d = mm_parse(text, length)
		mm_scene* s = mm_render(d)
		asserts(c"truncated shape render agrees", (d.error == 0) == (s != 0))
		mm_scene_free(s)
		mm_document_free(d)
	list[char*] bad = list[char*]{c"flowchart LR\nA-->B\nlinkStyle 1 stroke:red", c"flowchart LR\nA-->B\nlinkStyle -1 stroke:red", c"flowchart LR\nA-->B\nlinkStyle 0, stroke:red", c"flowchart LR\nA-->B\nlinkStyle 99999999999999999 stroke:red"}
	for char* source in bad:
		mm_document* d = mm_parse(source, strlen(source))
		asserts(c"invalid edge reference fails", d.error != 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))

void test_mermaid_requirement_and_usecase_styles():
	list[char*] sources = list[char*]{c"requirementDiagram\nrequirement r {\nid: R1\ntext: test\nrisk: low\nverifymethod: test\n}\nclassDef red fill:red\nclass r red\n", c"usecase-beta\nactor a[User]\nu(Login)\na --> u\nstyle u fill:red\nlinkStyle 0 stroke:blue\n"}
	for char* text in sources:
		mm_document* d = mm_parse(text, strlen(text))
		asserts(c"family styles parse", d.error == 0)
		mm_scene* s = mm_render(d)
		int styled = 0
		for mm_primitive* p in s.items:
			if (p.node_style && (p.kind == MM_BOX || p.kind == MM_POLYGON) && mm_paint_fill(p) == 0xff0000): styled = styled + 1
		asserts(c"family style reaches native scene", styled > 0)
		mm_scene_free(s)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))
