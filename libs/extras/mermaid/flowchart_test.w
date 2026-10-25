# wbuild: x64
# Flowchart shape inventory, link grammar, edge IDs/metadata, `&` groups,
# collapsed subgraphs and click actions (Mermaid 12.2.0 flowchart syntax).
import lib.testing
import libs.extras.mermaid.io
import libs.extras.mermaid.render
import libs.extras.mermaid.serialize

mm_document* flow_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"flowchart parses", d.error == 0)
	return d

char* flow_svg(mm_document* d):
	mm_scene* s = mm_render(d)
	asserts(c"flowchart renders", s != 0 && s.items.length > 0)
	char* svg = mm_svg(s)
	mm_scene_free(s)
	return svg

void flow_reject(char* source, char* message):
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"flowchart rejected", d.error != 0)
	if (d.error != 0 && index_of(d.error, message) < 0): println2(d.error)
	asserts(c"diagnostic names the problem", d.error != 0 && index_of(d.error, message) >= 0)
	char* text = mm_write(d)
	assert_strings_equal(source, text)
	free(text)
	mm_document_free(d)

# Round trip through the canonical serializer keeps every semantic field.
void flow_serializes(mm_document* d):
	char* text = mm_serialize(d)
	if (text == 0): println2(c"serializer refused document")
	asserts(c"canonical serialization succeeds", text != 0)
	if (text != 0): free(text)

void test_flow_named_shapes_and_aliases():
	list[char*] names = list[char*]{c"rect", c"rounded", c"stadium", c"subproc", c"cyl", c"circle", c"odd", c"diamond", c"hex", c"lean-r", c"lean-l", c"trap-b", c"trap-t", c"dbl-circ", c"text", c"notch-rect", c"lin-rect", c"sm-circ", c"framed-circle", c"fork", c"hourglass", c"comment", c"brace-r", c"braces", c"bolt", c"doc", c"delay", c"das", c"lin-cyl", c"curv-trap", c"div-rect", c"tri", c"win-pane", c"f-circ", c"lin-doc", c"notch-pent", c"flip-tri", c"sl-rect", c"docs", c"procs", c"paper-tape", c"bow-rect", c"cross-circ", c"tag-doc", c"tag-rect", c"datastore", c"database", c"manual-input", c"stored-data", c"terminal", c"junction", c"collate"}
	for char* name in names:
		string_builder* source = string_from(c"flowchart TD\n  A@{ shape: ")
		string_append(source, name)
		string_append(source, c", label: \"Shape\" } --> B\n")
		mm_document* d = flow_parse(source.data)
		mm_node* a = d.nodes[0]
		asserts(c"named shape resolves", mm_flow_shape_code(name) >= 0 && a.shape == mm_flow_shape_code(name))
		assert_strings_equal(c"Shape", a.label)
		assert_strings_equal(name, mm_flow_property(a, c"shape"))
		char* svg = flow_svg(d)
		asserts(c"shape exported", index_of(svg, c"<svg") == 0)
		free(svg)
		flow_serializes(d)
		mm_document_free(d)
		string_free(source)
	__w_list_free(cast(__w_list*, names))
	assert_equal(MM_FLOW_STACKED_DOCUMENT, mm_flow_shape_code(c"documents"))
	assert_equal(-1, mm_flow_shape_code(c"not-a-shape"))
	flow_reject(c"flowchart TD\nA@{ shape: blob }\n", c"unknown flowchart shape name")
	flow_reject(c"flowchart TD\nA@{ shape: rect\n", c"unterminated metadata block")
	flow_reject(c"flowchart TD\nA@{ colour: red }\n", c"unsupported flowchart node metadata")

void test_flow_bracket_shapes_cylinder_odd_double_circle():
	mm_document* d = flow_parse(c"flowchart LR\nA[(Database)] --> B>Odd] --> C(((Stop)))\n")
	assert_equal(MM_FLOW_CYLINDER, d.nodes[0].shape)
	assert_equal(MM_FLOW_ODD, d.nodes[1].shape)
	assert_equal(MM_FLOW_DOUBLE_CIRCLE, d.nodes[2].shape)
	assert_strings_equal(c"Database", d.nodes[0].label)
	assert_strings_equal(c"Odd", d.nodes[1].label)
	assert_strings_equal(c"Stop", d.nodes[2].label)
	mm_scene* s = mm_render(d)
	int polygons = 0
	int circles = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_POLYGON): polygons = polygons + 1
		if (p.kind == MM_CIRCLE): circles = circles + 1
	asserts(c"cylinder and odd outlines are polygons", polygons >= 2)
	asserts(c"double circle draws two rings", circles >= 2)
	mm_scene_free(s)
	flow_serializes(d)
	mm_document_free(d)
	flow_reject(c"flowchart LR\nA(((Stop))\n", c"expected third closing shape delimiter")

void test_flow_icon_and_image_nodes():
	mm_document* d = flow_parse(c"flowchart TD\nA@{ icon: \"fa:user\", form: \"square\", label: \"User Icon\", pos: \"t\", h: 60 }\nB@{ img: \"https://example.com/a.png\", label: \"Pic\", pos: \"b\", w: 60, h: 40, constraint: \"on\" }\nA --> B\n")
	mm_node* a = d.nodes[0]
	mm_node* b = d.nodes[1]
	assert_equal(MM_FLOW_ICON, a.shape)
	assert_equal(MM_FLOW_IMAGE, b.shape)
	assert_strings_equal(c"fa:user", mm_flow_property(a, c"icon"))
	assert_strings_equal(c"60", mm_flow_property(a, c"h"))
	assert_strings_equal(c"https://example.com/a.png", mm_flow_property(b, c"img"))
	mm_scene* s = mm_render(d)
	mm_bounds* ab = s.nodes[0]
	mm_bounds* bb = s.nodes[1]
	asserts(c"icon height follows h", ab.h >= 68)
	asserts(c"constrained image keeps a square frame", bb.w >= 56)
	mm_scene_free(s)
	flow_serializes(d)
	mm_document_free(d)
	flow_reject(c"flowchart TD\nA@{ icon: \"fa:user\", form: \"star\" }\n", c"expected icon form")
	flow_reject(c"flowchart TD\nA@{ img: \"x.png\", h: 99999 }\n", c"at most 4096")
	flow_reject(c"flowchart TD\nA@{ img: \"x.png\", pos: \"left\" }\n", c"expected label position")

void test_flow_link_grammar():
	mm_document* d = flow_parse(c"flowchart LR\nA ==> B\nB === C\nC -.- D\nD ~~~ E\nE <--> F\nF o--o G\nG x--x H\nH --o I\nI --x J\nJ ----> K\nK -..-> L\nL ====> M\nM -- text --- N\nN == thick ==> O\nO -. dotted .-> P\nP -->|piped| Q\nQ --- R\n")
	assert_equal(17, d.edges.length)
	mm_edge* e = d.edges[0]
	assert_equal(1, e.stroke)
	assert_equal(1, e.arrow)
	e = d.edges[1]
	assert_equal(1, e.stroke)
	assert_equal(0, e.arrow)
	e = d.edges[2]
	assert_equal(1, e.dashed)
	assert_equal(0, e.arrow)
	e = d.edges[3]
	assert_equal(2, e.stroke)
	e = d.edges[4]
	assert_equal(MM_ARROW, e.left_marker)
	assert_equal(1, e.arrow)
	e = d.edges[5]
	assert_equal(MM_FLOW_CIRCLE, e.left_marker)
	assert_equal(MM_FLOW_CIRCLE, e.right_marker)
	e = d.edges[6]
	assert_equal(MM_FLOW_CROSS, e.left_marker)
	assert_equal(MM_FLOW_CROSS, e.right_marker)
	e = d.edges[7]
	assert_equal(MM_FLOW_CIRCLE, e.right_marker)
	assert_equal(0, e.arrow)
	e = d.edges[8]
	assert_equal(MM_FLOW_CROSS, e.right_marker)
	e = d.edges[9]
	assert_equal(2, e.extra_rank)
	e = d.edges[10]
	assert_equal(1, e.extra_rank)
	assert_equal(1, e.dashed)
	e = d.edges[11]
	assert_equal(2, e.extra_rank)
	assert_equal(1, e.stroke)
	e = d.edges[12]
	assert_strings_equal(c"text", e.label)
	assert_equal(0, e.arrow)
	e = d.edges[13]
	assert_strings_equal(c"thick", e.label)
	assert_equal(1, e.stroke)
	e = d.edges[14]
	assert_strings_equal(c"dotted", e.label)
	assert_equal(1, e.dashed)
	assert_equal(1, e.arrow)
	e = d.edges[15]
	assert_strings_equal(c"piped", e.label)
	flow_serializes(d)
	mm_scene* s = mm_render(d)
	int thick = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_LINE && p.style.width == 4): thick = thick + 1
	asserts(c"thick links draw wider strokes", thick > 0)
	# The longer link places K two extra ranks beyond J.
	mm_bounds* j = s.nodes[9]
	mm_bounds* k = s.nodes[10]
	mm_bounds* i = s.nodes[8]
	assert_equal(3, k.rank - j.rank)
	asserts(c"ranks map to positions", k.x > j.x && j.x > i.x)
	mm_scene_free(s)
	mm_document_free(d)
	# An o/x continuing an identifier is part of the target ID.
	d = flow_parse(c"flowchart LR\nA---oak\nB --x xray\n")
	assert_strings_equal(c"oak", d.nodes[1].id)
	assert_equal(0, d.edges[0].right_marker)
	assert_equal(MM_FLOW_CROSS, d.edges[1].right_marker)
	mm_document_free(d)
	flow_reject(c"flowchart LR\nA -- unterminated\n", c"expected closing link after edge text")
	flow_reject(c"flowchart LR\nA ~~ B\n", c"unsupported flowchart edge")
	flow_reject(c"flowchart LR\nA -------------------------> B\n", c"link length limit exceeded")

void test_flow_invisible_link_draws_nothing():
	mm_document* visible = flow_parse(c"flowchart LR\nA --- B\n")
	mm_document* hidden = flow_parse(c"flowchart LR\nA ~~~ B\n")
	mm_scene* a = mm_render(visible)
	mm_scene* b = mm_render(hidden)
	int lines_a = 0
	int lines_b = 0
	for mm_primitive* p in a.items:
		if (p.kind == MM_LINE): lines_a = lines_a + 1
	for mm_primitive* p in b.items:
		if (p.kind == MM_LINE): lines_b = lines_b + 1
	asserts(c"visible link draws", lines_a > 0)
	assert_equal(0, lines_b)
	mm_bounds* left = b.nodes[0]
	mm_bounds* right = b.nodes[1]
	asserts(c"invisible link still ranks its target", right.x > left.x)
	mm_scene_free(a)
	mm_scene_free(b)
	mm_document_free(visible)
	mm_document_free(hidden)

void test_flow_ampersand_groups():
	mm_document* d = flow_parse(c"flowchart TB\nA & B--> C & D\na --> b & c--> d\nX:::foo & Y:::bar --> Z\nclassDef foo stroke:#f00\nclassDef bar stroke:#0f0\n")
	assert_equal(4 + 4 + 2, d.edges.length)
	list[char*] pairs = list[char*]{c"A", c"C", c"A", c"D", c"B", c"C", c"B", c"D", c"a", c"b", c"a", c"c", c"b", c"d", c"c", c"d", c"X", c"Z", c"Y", c"Z"}
	for i in range(d.edges.length):
		mm_edge* e = d.edges[i]
		assert_strings_equal(pairs[i * 2], d.nodes[e.from_node].id)
		assert_strings_equal(pairs[i * 2 + 1], d.nodes[e.to_node].id)
	__w_list_free(cast(__w_list*, pairs))
	assert_strings_equal(c"foo", d.nodes[mm_find_node(d, c"X")].style_classes)
	flow_serializes(d)
	mm_document_free(d)

void test_flow_edge_ids_animation_and_curves():
	mm_document* d = flow_parse(c"flowchart LR\nA e1@==> B\nA e2@--> C\ne1@{ animate: true }\ne2@{ curve: natural, animation: slow }\n")
	mm_edge* e1 = d.edges[0]
	mm_edge* e2 = d.edges[1]
	assert_strings_equal(c"e1", e1.id)
	assert_equal(1, e1.animate)
	assert_equal(1, e1.stroke)
	assert_equal(3, e2.animate)
	assert_equal(3, e2.curve)
	assert_equal(3, d.nodes.length)
	char* svg = flow_svg(d)
	asserts(c"animated links march with SMIL", index_of(svg, c"<animate attributeName=\"stroke-dashoffset\"") > 0)
	asserts(c"slow animation duration", index_of(svg, c"dur=\"2s\"") > 0)
	free(svg)
	flow_serializes(d)
	mm_document_free(d)
	d = flow_parse(c"flowchart LR\nA --> B\nA e1@--> C\ne1@{ curve: linear }\n")
	assert_equal(2, d.edges[1].curve)
	mm_scene* s = mm_render(d)
	int diagonal = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_LINE && (p.x2 - p.x) * (p.x2 - p.x) > 400 && (p.y2 - p.y) * (p.y2 - p.y) > 400): diagonal = diagonal + 1
	asserts(c"linear curve draws a diagonal segment", diagonal > 0)
	mm_scene_free(s)
	mm_document_free(d)
	flow_reject(c"flowchart LR\nA e1@--> B\nB e1@--> C\n", c"duplicate edge ID")
	flow_reject(c"flowchart LR\nA & B e1@--> C\n", c"an edge ID names exactly one link")
	flow_reject(c"flowchart LR\nA e1@--> B\ne1@{ curve: wiggly }\n", c"unsupported edge curve")
	flow_reject(c"flowchart LR\nA e1@--> B\ne1@{ animate: maybe }\n", c"expected animate true or false")
	flow_reject(c"flowchart LR\nA e1@--> B\ne1@{ color: red }\n", c"unsupported flowchart edge metadata")

void test_flow_collapsed_subgraph():
	mm_document* d = flow_parse(c"flowchart TD\nStart --> one\nsubgraph one [My Group]\nA --> B\nB --> C\nend\none --> End\nX --> A\none@{ view: collapsed }\n")
	int one = mm_find_node(d, c"one")
	assert_equal(1, mm_flow_collapsed(d, one))
	assert_equal(one, mm_flow_visible_node(d, mm_find_node(d, c"B")))
	mm_scene* s = mm_render(d)
	mm_bounds* hidden = s.nodes[mm_find_node(d, c"B")]
	assert_equal(0, hidden.w)
	int labels = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && strcmp(p.text, c"B") == 0): labels = labels + 1
		if (p.kind == MM_TEXT && strcmp(p.text, c"My Group") == 0): labels = labels + 10
	assert_equal(10, labels)
	mm_scene_free(s)
	flow_serializes(d)
	mm_document_free(d)
	flow_reject(c"flowchart TD\nsubgraph one\nA\nend\none@{ view: folded }\n", c"expected subgraph view")

void test_flow_click_actions_and_svg_links():
	mm_document* d = flow_parse(c"flowchart LR\nA-->B\nB-->C\nC-->D\nD-->E\nclick A callback \"Tooltip for a callback\"\nclick B \"https://www.github.com\" \"This is a tooltip for a link\"\nclick C call callback(\"x\", 2) \"Tip\"\nclick D href \"https://www.github.com\" \"Open\" _blank\nclick E \"javascript:alert(1)\"\n")
	mm_node* a = d.nodes[0]
	mm_node* b = d.nodes[1]
	mm_node* c = d.nodes[2]
	mm_node* dn = d.nodes[3]
	mm_node* e = d.nodes[4]
	assert_strings_equal(c"callback", a.callback)
	assert_strings_equal(c"Tooltip for a callback", a.tooltip)
	assert_strings_equal(c"https://www.github.com", b.link)
	assert_strings_equal(c"callback(\"x\", 2)", c.callback)
	assert_strings_equal(c"_blank", dn.link_target)
	assert_strings_equal(c"javascript:alert(1)", e.link)
	asserts(c"script links are unsafe", mm_link_safe(e.link) == 0)
	asserts(c"relative links are safe", mm_link_safe(c"docs/page.html#x"))
	asserts(c"data links are unsafe", mm_link_safe(c"data:text/html,x") == 0)
	char* svg = flow_svg(d)
	asserts(c"link exported", index_of(svg, c"<a href=\"https://www.github.com\"><title>This is a tooltip for a link</title>") > 0)
	asserts(c"target exported with noopener", index_of(svg, c"rel=\"noopener noreferrer\" target=\"_blank\"") > 0)
	asserts(c"callback tooltip exported without a link", index_of(svg, c"<g><title>Tooltip for a callback</title>") > 0)
	asserts(c"script URL never exported", index_of(svg, c"javascript:") < 0)
	asserts(c"callbacks are never exported", index_of(svg, c"callback(") < 0)
	free(svg)
	flow_serializes(d)
	mm_document_free(d)
	flow_reject(c"flowchart LR\nA-->B\nclick Z \"https://x.org\"\n", c"interaction requires a declared node")
	flow_reject(c"flowchart LR\nA-->B\nclick A \"https://x.org\" _new\n", c"expected link target")
	flow_reject(c"flowchart LR\nA-->B\nclick A call cb(\"x\"\n", c"unbalanced callback arguments")
	flow_reject(c"flowchart LR\nA-->B\nclick A href nope\n", c"expected quoted link URL")

void test_flow_lossless_write_with_new_syntax():
	char* source = c"flowchart LR\n  %% kept\n  A@{ shape: docs, label: \"Docs\" } e1@<==> B[(DB)]\n  click A href \"https://example.com\"\n"
	mm_document* d = flow_parse(source)
	char* text = mm_write(d)
	assert_strings_equal(source, text)
	free(text)
	mm_document_free(d)
