# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* uc_parse(char* text):
	mm_document* d = mm_parse(text, strlen(text))
	if (d.error != 0):
		print(d.error)
		print(c"\n")
	asserts(c"use case sample parses", d.error == 0)
	return d

mm_node* uc_node(mm_document* d, char* id):
	int index = mm_find_node(d, id)
	asserts(c"node exists", index >= 0)
	return d.nodes[index]

char* uc_svg(mm_document* d):
	mm_scene* s = mm_render(d)
	asserts(c"use case renders", s != 0)
	char* svg = mm_svg(s)
	mm_scene_free(s)
	return svg

void test_usecase_actor_metadata_and_stereotypes():
	mm_document* d = uc_parse(c"usecase-beta\nactor Hollow(\"Hollow actor\")@{ type: hollow }\nactor Awesome@{ type: awesome }\nactor Icon(\"Icon\")@{ icon: \"fa:user\" }\nactor Agent(\"Sales agent\")@{ business: true } <<Employee>>\nQuote(\"Prepare quote\")@{ business: true } <<Core>>:::hot\nArchive[Archive quote] <<Record>>\nAgent --> Quote\nHollow --> Quote\nQuote --> Archive\nclassDef hot stroke:#c33\n")
	mm_node* hollow = uc_node(d, c"Hollow")
	assert_equal(MM_UC_ACTOR, hollow.shape)
	assert_strings_equal(c"hollow", mm_uc_get(hollow, c"type"))
	assert_strings_equal(c"Hollow actor", hollow.label)
	mm_node* icon = uc_node(d, c"Icon")
	assert_strings_equal(c"fa:user", mm_uc_get(icon, c"icon"))
	mm_node* agent = uc_node(d, c"Agent")
	assert_strings_equal(c"Employee", mm_uc_get(agent, c"stereotype"))
	asserts(c"business actor", mm_uc_true(agent, c"business"))
	mm_node* quote = uc_node(d, c"Quote")
	assert_equal(MM_UC_ELLIPSE, quote.shape)
	assert_strings_equal(c"Core", mm_uc_get(quote, c"stereotype"))
	assert_strings_equal(c"hot", quote.style_classes)
	mm_node* archive = uc_node(d, c"Archive")
	assert_equal(0, archive.shape)
	char* svg = uc_svg(d)
	asserts(c"stereotype text", index_of(svg, c"\xc2\xabEmployee\xc2\xbb") >= 0)
	asserts(c"class stroke", index_of(svg, c"#cc3333") >= 0)
	asserts(c"unknown icon fallback", index_of(svg, c">?</text>") >= 0)
	free(svg)
	mm_document_free(d)

void test_usecase_labels_entities_and_quoted_ids():
	mm_document* d = uc_parse(c"usecase-beta\nactor Reviewer(\"`*Reviewer*`\")\n\"Reset password\"\nQuoted(\"Show #quot;quoted#quot; text\")\nRefund(\"Refund #40;partial#41;\")\nFormatted(\"`**Formatted label**\nwith a physical line break`\")\nPriced[Costs 19.95 EUR!]\nReviewer -- \"`opens **form**`\" --> Formatted\nReviewer -- files R&D report --> Priced\n1mg --> Reset_password\n")
	mm_node* reset = uc_node(d, c"Reset_password")
	assert_strings_equal(c"Reset password", reset.label)
	assert_strings_equal(c"Show \"quoted\" text", uc_node(d, c"Quoted").label)
	assert_strings_equal(c"Refund (partial)", uc_node(d, c"Refund").label)
	assert_strings_equal(c"`**Formatted label**\nwith a physical line break`", uc_node(d, c"Formatted").label)
	mm_edge* markdown = d.edges[0]
	assert_strings_equal(c"`opens **form**`", markdown.label)
	assert_equal(MM_ARROW, markdown.right_marker)
	mm_edge* plain = d.edges[1]
	assert_strings_equal(c"files R&D report", plain.label)
	mm_node* digit = uc_node(d, c"1mg")
	assert_equal(MM_UC_ELLIPSE, digit.shape)
	char* svg = uc_svg(d)
	asserts(c"markdown bold run", index_of(svg, c"font-weight=\"bold\"") >= 0)
	asserts(c"entity decoded", index_of(svg, c"Refund (partial)") >= 0)
	free(svg)
	mm_document_free(d)

void test_usecase_operators_lengths_and_markers():
	mm_document* d = uc_parse(c"usecase-beta\nactor User\nactor Support\nStart\nFinish\nUser --> Start\nStart <-- Support\nStart -- Finish\nUser --o Start\nStart o-- Support\nUser --x Finish\nFinish x-- Support\nUser ----> Finish\nUser -- \"longer\" ---> Start\nStart --- Finish\n")
	list[int] left = list[int]{0, MM_ARROW, 0, 0, MM_UC_CIRCLE, 0, MM_UC_CROSS, 0, 0, 0}
	list[int] right = list[int]{MM_ARROW, 0, 0, MM_UC_CIRCLE, 0, MM_UC_CROSS, 0, MM_ARROW, MM_ARROW, 0}
	list[int] lengths = list[int]{1, 1, 1, 0, 0, 0, 0, 3, 2, 2}
	assert_equal(10, d.edges.length)
	for i in range(d.edges.length):
		mm_edge* e = d.edges[i]
		assert_equal(left[i], e.left_marker)
		assert_equal(right[i], e.right_marker)
		assert_equal(lengths[i], e.min_length)
	mm_scene* s = mm_render(d)
	mm_bounds* user = s.nodes[0]
	mm_bounds* start = s.nodes[2]
	mm_bounds* finish = s.nodes[3]
	asserts(c"longer edge pushes its target further", finish.y > start.y && start.y > user.y)
	mm_scene_free(s)
	__w_list_free(cast(__w_list*, left))
	__w_list_free(cast(__w_list*, right))
	__w_list_free(cast(__w_list*, lengths))
	mm_document_free(d)

void test_usecase_edge_ids_styles_and_animation():
	mm_document* d = uc_parse(c"usecase-beta\nactor Customer\nCheckout\nPayment\nCustomer opens@-- \"starts checkout\" ---> Checkout\nCheckout payment@..> : include Payment\nclassDef emphasized stroke:#d33,stroke-width:3px\nclass opens,payment emphasized\nstyle opens stroke:#06c,stroke-width:4px\nopens@{ animation: fast }\npayment@{ animate: false }\n")
	assert_equal(3, d.nodes.length)
	mm_edge* opens = d.edges[0]
	assert_strings_equal(c"opens", opens.id)
	assert_strings_equal(c"starts checkout", opens.label)
	assert_equal(3, opens.arrow)
	asserts(c"direct style wins over class", opens.style.stroke == 0x0066cc && opens.style.width == 4)
	mm_edge* payment = d.edges[1]
	assert_strings_equal(c"payment", payment.id)
	assert_strings_equal(c"include", payment.label)
	assert_equal(0, payment.arrow)
	asserts(c"class style on edge", payment.style.stroke == 0xdd3333 && payment.style.width == 3)
	char* svg = uc_svg(d)
	asserts(c"animated edge dashed", index_of(svg, c"stroke=\"#0066cc\" stroke-width=\"4\" x1") >= 0 && index_of(svg, c"stroke-dasharray") >= 0)
	free(svg)
	mm_document_free(d)

void test_usecase_boundaries_titles_and_package_type():
	mm_document* d = uc_parse(c"usecase-beta\nsystemBoundary sb1[\"Payment service\"]@{ type: package }:::system\n  actor Clerk(\"Payment clerk\")\n  Authorize(\"Authorize payment\")\nend\nsystemBoundary \"Order system\"\n  Checkout(Place order)\nend\nsystemBoundary Fulfil(Fulfilment)\n  Track\nend\nOrder_system@{ type: package }\nClerk --> Authorize\nclassDef system stroke:#4b4b7a\n")
	mm_node* sb1 = uc_node(d, c"sb1")
	asserts(c"boundary group", sb1.group == 1)
	assert_strings_equal(c"Payment service", sb1.label)
	assert_strings_equal(c"package", mm_uc_get(sb1, c"type"))
	mm_node* order = uc_node(d, c"Order_system")
	assert_strings_equal(c"Order system", order.label)
	assert_strings_equal(c"package", mm_uc_get(order, c"type"))
	assert_strings_equal(c"Fulfilment", uc_node(d, c"Fulfil").label)
	mm_node* clerk = uc_node(d, c"Clerk")
	assert_equal(mm_find_node(d, c"sb1"), clerk.parent)
	mm_scene* s = mm_render(d)
	mm_bounds* box = s.nodes[mm_find_node(d, c"sb1")]
	mm_bounds* inner = s.nodes[mm_find_node(d, c"Authorize")]
	asserts(c"contained", inner.x > box.x && inner.y > box.y && inner.x + inner.w < box.x + box.w)
	char* svg = mm_svg(s)
	asserts(c"package tab title", index_of(svg, c"Payment service") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_usecase_notes_and_json_tables():
	mm_document* d = uc_parse(c"usecase-beta\nnote for Login \"`Requires an **active session**`\"\nnote for User Starts the workflow\nactor User\nLogin(\"Sign in\")\nInspect(\"Inspect payload\")\njson Payload@{\n  \"2\": \"second\",\n  \"1\": \"first\",\n  \"enabled\": true,\n  \"count\": -3.5e2,\n  \"missing\": null,\n  \"colors\": [\"Red\", \"Gr\\u00e9en\"],\n  \"address\": { \"city\": \"Oslo\" },\n  \"items\": [{ \"name\": \"Book\" }],\n  \"emptyObject\": {},\n  \"emptyArray\": [],\n  \"2\": \"last wins\"\n}:::data\nUser --> Login\nInspect --> Payload\nPayload <-- Login\nInspect -- Payload\nstyle Payload stroke-width:2px\n")
	mm_node* note = uc_node(d, c"note@0")
	assert_equal(MM_UC_NOTE, note.shape)
	assert_strings_equal(c"`Requires an **active session**`", note.label)
	assert_strings_equal(c"Starts the workflow", uc_node(d, c"note@1").label)
	mm_edge* link = d.edges[0]
	assert_equal(1, link.dashed)
	assert_equal(mm_find_node(d, c"Login"), link.to_node)
	mm_node* json = uc_node(d, c"Payload")
	assert_equal(MM_UC_JSON, json.shape)
	assert_strings_equal(c"data", json.style_classes)
	list[char*] paths = list[char*]{c"2", c"1", c"enabled", c"count", c"missing", c"colors[0]", c"colors[1]", c"address.city", c"items[0].name", c"emptyObject", c"emptyArray"}
	list[char*] values = list[char*]{c"last wins", c"first", c"true", c"-3.5e2", c"null", c"Red", c"Gr\xc3\xa9en", c"Oslo", c"Book", c"{}", c"[]"}
	assert_equal(paths.length, json.attributes.length)
	for i in range(paths.length):
		mm_attribute* row = json.attributes[i]
		assert_strings_equal(paths[i], row.type_name)
		assert_strings_equal(values[i], row.name)
	__w_list_free(cast(__w_list*, paths))
	__w_list_free(cast(__w_list*, values))
	mm_scene* s = mm_render(d)
	mm_bounds* table = s.nodes[mm_find_node(d, c"Payload")]
	assert_equal(36 + 11 * 26, table.h)
	char* svg = mm_svg(s)
	asserts(c"note fill", index_of(svg, c"#fff5ad") >= 0)
	asserts(c"json row", index_of(svg, c"items[0].name") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_usecase_configuration_keys():
	mm_document* d = uc_parse(c"---\nconfig:\n  theme: redux-color\n  usecase:\n    colorScheme: rotate\n    actorFontSize: 16\n    actorFontFamily: Arial\n    nodeSpacing: 60\n    rankSpacing: 70\n    useMaxWidth: false\n---\nusecase-beta\nactor Customer\nactor Auditor\nBrowse(\"Browse catalogue\")\nCustomer --> Browse\nAuditor --> Browse\n")
	assert_equal(1, d.usecase_rotate)
	assert_equal(60, d.node_spacing)
	assert_equal(70, d.rank_spacing)
	mm_node* browse = uc_node(d, c"Browse")
	assert_equal(2, mm_uc_series(d, browse))
	assert_equal(1, mm_uc_series(d, uc_node(d, c"Auditor")))
	mm_scene* s = mm_render(d)
	int series = 0
	for mm_primitive* p in s.items:
		if (p.role == MM_ROLE_SERIES): series = series + 1
	asserts(c"rotated colours applied", series > 0)
	mm_scene_free(s)
	mm_document_free(d)
	d = uc_parse(c"---\nconfig:\n  architecture:\n    randomize: true\n    nodeSeparation: 90\n    idealEdgeLengthMultiplier: 3\n  c4:\n    wrap: false\n    c4ShapeInRow: 2\n---\nusecase-beta\nA\n")
	assert_equal(90, d.node_spacing)
	assert_equal(2, d.c4_shape_in_row)
	mm_document_free(d)
	# Unknown family keys are ignored deterministically and recorded.
	d = uc_parse(c"---\nconfig:\n  usecase:\n    bogus: 1\n---\nusecase-beta\nA\n")
	asserts(c"unknown family key accepted", d.error == 0)
	assert_equal(1, d.config_ignored.length)
	mm_document_free(d)
	list[char*] bad = list[char*]{c"---\nconfig:\n  usecase:\n    colorScheme: random\n---\nusecase-beta\nA\n", c"---\nconfig:\n  architecture:\n    seed: x\n---\nusecase-beta\nA\n", c"---\nconfig:\n  c4:\n    c4BoundaryInRow: 0\n---\nusecase-beta\nA\n"}
	for char* text in bad:
		mm_document* invalid = mm_parse(text, strlen(text))
		asserts(c"invalid family configuration rejected", invalid.error != 0)
		mm_document_free(invalid)
	__w_list_free(cast(__w_list*, bad))

void test_usecase_invalid_constructs():
	list[char*] bad = list[char*]{c"usecase-beta\nactor A@{ fillColor: red }", c"usecase-beta\nactor A@{ type: robot }", c"usecase-beta\nactor A@{ icon: \"fa:user\", type: hollow }", c"usecase-beta\nactor A@{ icon: \"fa:user\", business: true }", c"usecase-beta\nactor A@{ type: awesome, business: true }", c"usecase-beta\nR[Rect]@{ business: true }", c"usecase-beta\nsystemBoundary G@{ type: circle }\nend", c"usecase-beta\njson J@{ \"a\": 1 }\nactor A\nA --o J", c"usecase-beta\njson J@{ \"a\": 1 }\nU\nU ..> : include J", c"usecase-beta\njson J@[1]", c"usecase-beta\njson J@{ \"a\": 1, }", c"usecase-beta\njson J@{ \"a\": tru }", c"usecase-beta\njson J@{ a: 1 }", c"usecase-beta\njson J@{ \"a\": \"x\\q\" }", c"usecase-beta\nsystemBoundary G\njson J@{ }\nend", c"usecase-beta\nnote for G \"x\"\nsystemBoundary G\nend", c"usecase-beta\njson J@{ }\nnote for J \"x\"", c"usecase-beta\nA ---o B", c"usecase-beta\nA ---|> B", c"usecase-beta\nA --- \"x\" --> B", c"usecase-beta\nA e@-- B\nB e@--> C", c"usecase-beta\nA e@-- B\ne\nf --> e", c"usecase-beta\nA e@--> B\ne@{ animation: warp }", c"usecase-beta\nA e@--> B\ne@{ colour: red }", c"usecase-beta\nA <<>>", c"usecase-beta\nsystemBoundary G <<X>>\nend", c"usecase-beta\nA --> B C", c"usecase-beta\nA e@ B"}
	for char* text in bad:
		mm_document* d = mm_parse(text, strlen(text))
		if (d.error == 0):
			print(text)
			print(c"\n")
		asserts(c"invalid use case rejected", d.error != 0)
		asserts(c"invalid use case has no preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))

void test_usecase_extension_prefixes_are_safe():
	char* text = c"usecase-beta\nactor S(\"Staff\")@{ type: hollow, business: true } <<Employee>>\nsystemBoundary o[\"Ordering\"]@{ type: package }:::sys\n  C(\"Checkout\") <<Core>>:::crit\nend\njson D@{ \"s\": [{ \"n\": 1 }] }\nnote for C \"`a **b**`\"\nS starts@-- \"places\" ---> C\nC pays@..> : include P\nC --> D\nstarts@{ animation: fast }\n"
	for length in range(strlen(text) + 1):
		mm_document* d = mm_parse(text, length)
		mm_scene* s = mm_render(d)
		asserts(c"prefix parse/render consistent", (d.error == 0 && s != 0) || (d.error != 0 && s == 0))
		mm_scene_free(s)
		mm_document_free(d)
