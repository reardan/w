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
		assert_equal(2, api.members.length)
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
	list[char*] bad = list[char*]{c"C4Context\nPerson(a)", c"C4Context\nPerson(a, A)\nPerson(a, B)", c"C4Context\nRel(a,b,Uses)", c"C4Context\nSystem_Boundary(a,A) {\nPerson(a, A)\n}", c"C4Context\nPerson(a, A, $tags=\"v1\")", c"C4Context\nUpdateLayoutConfig(2,3)"}
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
