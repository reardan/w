# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

void test_systems_architecture_ports_groups_and_icons():
	list[char*] ports = list[char*]{c"L", c"R", c"T", c"B"}
	for i in range(4):
		for j in range(4):
			string_builder* text = string_from(c"architecture-beta\ngroup api(cloud)[API]\nservice a(database)[Store] in api\nservice b(server)[Compute] in api\na:")
			string_append(text, ports[i])
			string_append(text, c" <--> ")
			string_append(text, ports[j])
			string_append(text, c":b\n")
			mm_document* d = mm_parse(text.data, text.length)
			asserts(c"architecture parses", d.error == 0)
			mm_edge* e = d.edges[0]
			assert_equal(i + 1, e.from_port)
			assert_equal(j + 1, e.to_port)
			assert_equal(1, e.left_marker)
			assert_equal(1, e.right_marker)
			mm_node* n = d.nodes[1]
			assert_equal(0, n.parent)
			mm_scene* s = mm_render(d)
			mm_bounds* group = s.nodes[0]
			mm_bounds* child = s.nodes[1]
			asserts(c"service within group", child.x > group.x && child.x + child.w < group.x + group.w)
			mm_scene_free(s)
			mm_document_free(d)
			string_free(text)
	__w_list_free(cast(__w_list*, ports))

void test_systems_usecase_actors_boundaries_and_relationships():
	char* text = c"usecase-beta\ndirection LR\nactor Customer(\"Customer\")\nactor Admin\nsystemBoundary Store[Order system]\nCheckout(Place order)\nPayment(Pay)\nend\nCustomer --> Checkout\nCheckout ..> : include Payment\nAdmin --|> Customer\n"
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"use case parses", d.error == 0)
	assert_equal(5, d.nodes.length)
	mm_node* actor = d.nodes[0]
	assert_equal(10, actor.shape)
	mm_node* usecase = d.nodes[3]
	assert_equal(11, usecase.shape)
	assert_equal(2, usecase.parent)
	mm_edge* include = d.edges[1]
	assert_strings_equal(c"include", include.label)
	assert_equal(1, include.dashed)
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"UML include rendered", index_of(svg, c"include") >= 0)
	asserts(c"actor head rendered", index_of(svg, c"<circle") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_systems_invalid_references_cycles_and_semantics():
	list[char*] bad = list[char*]{c"architecture-beta\nservice a in missing", c"architecture-beta\ngroup a in b\ngroup b in a", c"architecture-beta\nservice a\na:Q -- L:a", c"architecture-beta\nservice a(custom)[A]", c"architecture-beta\ngroup a\na:L -- R:a", c"usecase-beta\nactor A\nB\nA ..> : include B", c"usecase-beta\nactor A\nB\nA --|> B", c"usecase-beta\nsystemBoundary G\nsystemBoundary H\nend\nend", c"usecase-beta\nsystemBoundary G\nA --> B\nend"}
	for char* text in bad:
		mm_document* d = mm_parse(text, strlen(text))
		asserts(c"invalid systems diagram rejected", d.error != 0)
		asserts(c"invalid systems diagram has no preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))

void test_systems_every_prefix_is_safe():
	list[char*] samples = list[char*]{c"architecture-beta\ngroup api(cloud)[API]\nservice a(database)[Store] in api\njunction j in api\na:R --> L:j\n", c"usecase-beta\nactor A(Name)\nsystemBoundary G[System]\nB(Work)\nend\nA --> B\n"}
	for char* text in samples:
		for length in range(strlen(text) + 1):
			mm_document* d = mm_parse(text, length)
			mm_scene* s = mm_render(d)
			asserts(c"prefix parse/render consistent", (d.error == 0 && s != 0) || (d.error != 0 && s == 0))
			mm_scene_free(s)
			mm_document_free(d)
	__w_list_free(cast(__w_list*, samples))
