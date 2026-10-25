# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

void test_c4_variants_semantic_cards_and_relationships():
	list[char*] kinds = list[char*]{c"C4Context", c"C4Container", c"C4Component", c"C4Dynamic", c"C4Deployment"}
	for i in range(kinds.length):
		string_builder* text = string_from(kinds[i])
		string_append(text, c"\ntitle Native system\nPerson(user, \"User\", \"Customer\")\nSystem_Boundary(system, \"Store\") {\nContainer(api, \"API\", \"W\", \"Order processing\")\nContainerDb(db, \"Database\", \"SQL\")\n}\nRel(user, api, \"Uses\", \"HTTPS\")\nBiRel(api, db, \"Stores\")\n")
		mm_document* d = mm_parse(text.data, text.length)
		asserts(c"C4 variant parses", d.error == 0)
		assert_equal(i, d.graph_variant)
		mm_node* api = d.nodes[2]
		assert_equal(1, api.parent)
		assert_strings_equal(c"W", mm_c4_get(api, c"techn"))
		assert_strings_equal(c"Order processing", mm_c4_get(api, c"descr"))
		assert_strings_equal(c"Container", api.annotation)
		mm_edge* relation = d.edges[0]
		if (i == 3): asserts(c"dynamic interaction numbered", index_of(relation.label, c"1: ") == 0)
		mm_scene* s = mm_render(d)
		char* svg = mm_svg(s)
		asserts(c"technology visible", index_of(svg, c"HTTPS") >= 0)
		asserts(c"description visible", index_of(svg, c"Order processing") >= 0)
		free(svg)
		mm_scene_free(s)
		mm_document_free(d)
		string_free(text)
	__w_list_free(cast(__w_list*, kinds))

void test_c4_deployment_nesting_and_forward_references():
	char* text = c"C4Deployment\nRel(app, db, \"Uses\")\nDeployment_Node(host, \"Host\", \"Linux\") {\nDeployment_Node(runtime, \"Runtime\", \"W\") {\nContainer(app, \"Application\", \"W\")\n}\nContainerDb(db, \"Store\", \"SQL\")\n}\n"
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"nested deployment parses", d.error == 0)
	mm_node* app = d.nodes[0]
	assert_equal(3, app.parent)
	mm_scene* s = mm_render(d)
	mm_bounds* host = s.nodes[2]
	mm_bounds* runtime = s.nodes[3]
	asserts(c"nested deployment boxes contained", runtime.x > host.x && runtime.x + runtime.w < host.x + host.w)
	mm_scene_free(s)
	mm_document_free(d)

void test_c4_invalid_and_truncated_calls():
	list[char*] bad = list[char*]{c"C4Context\nPerson(a)", c"C4Context\nPerson(a, A)\nPerson(a, B)", c"C4Context\nRel(a,b,Uses)", c"C4Context\nSystem_Boundary(a,A) {\nPerson(a, A)\n}", c"C4Context\nPerson(a, A, $bogus=\"v1\")", c"C4Context\nUpdateLayoutConfig(0,3)", c"C4Context\nPerson(a, A, $descr=\"x\", $descr=\"y\")", c"C4Context\nPerson(a, A, B, C, D, E, F)", c"C4Context\nPerson(a, A, x=1)", c"C4Context\nPerson(a, A)\nPerson(b, B)\nRel(a, b)", c"C4Context\nPerson(a, A)\nUpdateElementStyle(a, $bgColor=\"nocolor\")", c"C4Context\nPerson(a, A)\nPerson(b, B)\nRel(a, b, x)\nUpdateRelStyle(a, b, $offsetX=\"x\")", c"C4Context\nPerson(a, A)\nPerson(b, B)\nUpdateRelStyle(a, b, red)", c"C4Context\nLay_U(a, b)"}
	for char* text in bad:
		mm_document* d = mm_parse(text, strlen(text))
		asserts(c"invalid C4 rejected", d.error != 0)
		asserts(c"invalid C4 no preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))
	char* text = c"C4Context\nSystem_Boundary(g,\"Group\") {\nPerson(a,\"A\")\nSystem(b,\"B\")\n}\nRel(a,b,\"Uses\")\n"
	for length in range(strlen(text) + 1):
		mm_document* d = mm_parse(text, length)
		mm_scene* s = mm_render(d)
		asserts(c"prefix parse/render consistent", (d.error == 0 && s != 0) || (d.error != 0 && s == 0))
		mm_scene_free(s)
		mm_document_free(d)

void test_c4_named_arguments_macros_styles_and_layout():
	char* text = c"C4Context\nPerson(a, \"A\", $descr=\"Named\", $tags=\"v1.0\", $link=\"https://example.com\")\nSystem(b, B)\nSystem_Ext(c, \"C\")\nSystemDb(e, \"E\")\nPerson_Ext(f, F)\nRel_U(a, b, \"Up\")\nRel_Right(b, c, \"Right\", \"HTTPS\")\nBiRel_D(c, e, \"Down\")\nRel_Back(e, f, \"Back\")\nRelIndex(1, a, e, \"Indexed\")\nUpdateElementStyle(a, $fontColor=\"red\", $bgColor=\"grey\", $borderColor=\"red\")\nUpdateRelStyle(a, b, $textColor=\"blue\", $lineColor=\"blue\", $offsetX=\"5\", $offsetY=\"-10\")\nUpdateRelStyle(b, c, \"red\", \"green\", \"-40\", \"60\")\nUpdateLayoutConfig($c4ShapeInRow=\"2\", $c4BoundaryInRow=\"1\")\n"
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"named C4 call parses", d.error == 0)
	mm_node* a = d.nodes[0]
	assert_strings_equal(c"Named", mm_c4_get(a, c"descr"))
	assert_strings_equal(c"v1.0", mm_c4_get(a, c"tags"))
	assert_strings_equal(c"https://example.com", mm_c4_get(a, c"link"))
	asserts(c"element style", (a.style.mask & 7) == 7 && a.style.fill == 0x808080 && a.style.text == 0xff0000)
	assert_equal(2, d.c4_shape_in_row)
	assert_equal(1, d.c4_boundary_in_row)
	mm_edge* up = d.edges[0]
	assert_equal(3, up.from_port)
	assert_equal(4, up.to_port)
	assert_equal(5, up.label_dx)
	assert_equal(-10, up.label_dy)
	assert_equal(0x0000ff, up.style.stroke)
	mm_edge* right = d.edges[1]
	assert_equal(2, right.from_port)
	assert_equal(0x008000, right.style.stroke)
	assert_equal(0xff0000, right.style.text)
	assert_equal(60, right.label_dy)
	mm_edge* down = d.edges[2]
	assert_equal(4, down.from_port)
	assert_equal(MM_ARROW, down.left_marker)
	mm_edge* back = d.edges[3]
	assert_equal(4, back.from_node)
	assert_equal(3, back.to_node)
	mm_edge* indexed = d.edges[4]
	assert_equal(0, indexed.from_node)
	assert_equal(3, indexed.to_node)
	mm_scene* s = mm_render(d)
	# Two shapes per row in statement order.
	mm_bounds* first = s.nodes[0]
	mm_bounds* second = s.nodes[1]
	mm_bounds* third = s.nodes[2]
	asserts(c"shape row", first.y == second.y && second.x > first.x)
	asserts(c"next row", third.y > first.y + first.h && third.x == first.x)
	char* svg = mm_svg(s)
	asserts(c"default C4 system fill", index_of(svg, c"#1168bd") >= 0)
	asserts(c"custom element fill", index_of(svg, c"#808080") >= 0)
	asserts(c"custom relation colour", index_of(svg, c"stroke=\"#0000ff\"") >= 0)
	asserts(c"type stereotype", index_of(svg, c"&lt;&lt;external_system&gt;&gt;") >= 0)
	asserts(c"database cylinder", index_of(svg, c"&lt;&lt;system_db&gt;&gt;") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_c4_boundary_rows_and_types():
	char* text = c"C4Container\nPerson(u, U)\nContainer_Boundary(b1, \"One\") {\nContainer(x, X, \"W\")\n}\nBoundary(b2, \"Two\", \"cluster\") {\nComponent(y, Y)\n}\nBoundary(b3, \"Three\") {\nComponentQueue_Ext(z, Z)\n}\nRel(u, x, \"Uses\")\nRel(x, x, \"Self\")\n"
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"boundaries parse", d.error == 0)
	mm_scene* s = mm_render(d)
	mm_bounds* person = s.nodes[0]
	mm_bounds* one = s.nodes[1]
	mm_bounds* two = s.nodes[3]
	mm_bounds* three = s.nodes[5]
	asserts(c"boundaries below root shapes", one.y > person.y + person.h)
	asserts(c"two boundaries per row", one.y == two.y && two.x > one.x + one.w)
	asserts(c"third boundary wraps", three.y > one.y + one.h)
	char* svg = mm_svg(s)
	asserts(c"container type", index_of(svg, c"[container]") >= 0)
	asserts(c"explicit boundary type", index_of(svg, c"[cluster]") >= 0)
	asserts(c"default boundary type", index_of(svg, c"[boundary]") >= 0)
	asserts(c"external component queue", index_of(svg, c"external_component_queue") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
