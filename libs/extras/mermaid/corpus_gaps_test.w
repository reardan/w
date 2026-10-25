# wbuild: x64
# Syntax gaps closed from the pinned upstream conformance corpus
# (tests/mermaid_corpus): requirement direction/classes/case-insensitive keys,
# ER markers on either side, GitGraph messages and repeated commit ids, block
# composite spans, multi-headed arrows and quoted link labels, edge classes
# with CSS motion properties, multi-line quoted YAML scalars, dotted YAML map
# keys and Font Awesome label glyphs.
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* gaps_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"corpus gap source parses", d.error == 0)
	return d

# Renders d, checks the lossless write path, and returns the SVG export.
char* gaps_svg(mm_document* d, mm_scene* scene):
	asserts(c"corpus gap scene renders", scene != 0 && scene.items.length > 0)
	char* svg = mm_svg(scene)
	asserts(c"corpus gap exports SVG", index_of(svg, c"<svg") >= 0)
	char* written = mm_write(d)
	assert_strings_equal(d.source, written)
	free(written)
	return svg

void gaps_error(char* source, char* message):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error == 0): println2(source)
	asserts(c"corpus gap diagnostic reported", d.error != 0)
	if (d.error != 0 && strcmp(d.error, message) != 0): assert_strings_equal(message, d.error)
	asserts(c"diagnosed source suppresses preview", mm_render(d) == 0)
	mm_document_free(d)

# Every prefix must parse or diagnose without crashing.
void gaps_prefixes(char* source):
	for length in range(strlen(source) + 1):
		mm_document* d = mm_parse(source, length)
		mm_scene* scene = mm_render(d)
		if (d.error != 0): asserts(c"prefix error suppresses scene", scene == 0)
		if (scene != 0):
			char* svg = mm_svg(scene)
			free(svg)
		mm_scene_free(scene)
		mm_document_free(d)

int gaps_node(mm_document* d, char* id):
	int index = mm_find_node(d, id)
	if (index < 0): println2(id)
	asserts(c"expected node exists", index >= 0)
	return index

int gaps_has_member(mm_node* n, char* text):
	for mm_member* m in n.members:
		if (strcmp(m.text, text) == 0): return 1
	return 0

void test_requirement_direction_classes_and_case_insensitive_keywords():
	char* source = c"requirementDiagram\ndirection LR\nrequirement R:::important {\nid: 1\nText: \"t\"\nRisk: High\nverifyMethod: Test\n}\nelement E {\nType: sim\ndocRef: reqs/x\n}\nclassDef important font-weight:bold\nclassDef soft fill:#ffeeee\nE:::soft\nE - Satisfies -> R\n"
	mm_document* d = gaps_parse(source)
	assert_strings_equal(c"LR", d.direction)
	mm_node* r = d.nodes[gaps_node(d, c"R")]
	mm_node* e = d.nodes[gaps_node(d, c"E")]
	assert_strings_equal(c"important", r.style_classes)
	assert_strings_equal(c"soft", e.style_classes)
	asserts(c"docRef member kept as written", gaps_has_member(e, c"docRef: reqs/x"))
	asserts(c"verifyMethod member kept", gaps_has_member(r, c"verifyMethod: Test"))
	assert_equal(1, d.edges.length)
	mm_edge* link = d.edges[0]
	assert_strings_equal(c"satisfies", link.label)
	mm_scene* scene = mm_render(d)
	mm_bounds* rb = scene.nodes[gaps_node(d, c"R")]
	mm_bounds* eb = scene.nodes[gaps_node(d, c"E")]
	int dx = rb.x - eb.x
	int dy = rb.y - eb.y
	if (dx < 0): dx = 0 - dx
	if (dy < 0): dy = 0 - dy
	asserts(c"direction LR lays the relationship out horizontally", dx > dy)
	char* svg = gaps_svg(d, scene)
	asserts(c"classDef fill reaches the element", index_of(svg, c"#ffeeee") >= 0)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(d)
	gaps_error(c"requirementDiagram\nrequirement R {\nID: 1\nid: 2\n}\n", c"duplicate requirement property")
	gaps_error(c"requirementDiagram\nrequirement R:::x {\nid: 1\n}\n", c"assigned style class has no classDef")
	gaps_prefixes(source)

void test_er_markers_on_either_side_and_word_aliases():
	char* source = c"erDiagram\nPERSON:::foo o{--|| HOUSE:::bar : has\nA many--one B : x\nC |{--}| D : y\nclassDef foo stroke:#f00\nclassDef bar stroke:#0f0\n"
	mm_document* d = gaps_parse(source)
	assert_equal(3, d.edges.length)
	mm_edge* has = d.edges[0]
	assert_equal(2, has.left_card)
	assert_equal(1, has.right_card)
	mm_edge* words = d.edges[1]
	assert_equal(2, words.left_card)
	assert_equal(1, words.right_card)
	mm_edge* mirrored = d.edges[2]
	assert_equal(3, mirrored.left_card)
	assert_equal(3, mirrored.right_card)
	mm_node* house = d.nodes[gaps_node(d, c"HOUSE")]
	assert_strings_equal(c"bar", house.style_classes)
	mm_scene* scene = mm_render(d)
	char* svg = gaps_svg(d, scene)
	asserts(c"class stroke reaches HOUSE", index_of(svg, c"#00ff00") >= 0)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(d)
	gaps_error(c"erDiagram\nA o--|| B : x\n", c"expected ER cardinality marker")
	gaps_prefixes(source)

mm_property* gaps_property(mm_node* n, char* key):
	for mm_property* property in n.metadata:
		if (strcmp(property.key, key) == 0): return property
	return 0

void test_gitgraph_messages_and_repeated_commit_ids():
	char* source = c"gitGraph:\ncommit \"Ashish\"\ncommit msg: \"second\" id: \"two\"\nbranch dev\ncommit id: \"x\"\ncheckout main\ncommit id: \"x\" tag: \"again\"\ncheckout dev\ncherry-pick id: \"x\"\n"
	mm_document* d = gaps_parse(source)
	mm_node* first = d.nodes[gaps_node(d, c"commit-0")]
	mm_property* message = gaps_property(first, c"msg")
	asserts(c"bare string is the commit message", message != 0)
	assert_strings_equal(c"Ashish", message.value)
	mm_node* two = d.nodes[gaps_node(d, c"two")]
	assert_strings_equal(c"second", gaps_property(two, c"msg").value)
	# The repeated id rebinds to the newer commit; the older one stays drawn.
	int older = gaps_node(d, c"x~1")
	int newer = gaps_node(d, c"x")
	mm_node* old_commit = d.nodes[older]
	mm_node* new_commit = d.nodes[newer]
	assert_strings_equal(c"x", old_commit.label)
	assert_strings_equal(c"again", new_commit.annotation)
	mm_node* dev = d.nodes[gaps_node(d, c"@branch:dev")]
	mm_node* main = d.nodes[gaps_node(d, c"@branch:main")]
	asserts(c"older x stays on dev", d.nodes[old_commit.parent] == dev)
	asserts(c"newer x is on main", d.nodes[new_commit.parent] == main)
	mm_node* pick = d.nodes[gaps_node(d, c"cherry-pick-4")]
	assert_strings_equal(c"x", gaps_property(pick, c"cherry-pick").value)
	mm_scene* scene = mm_render(d)
	mm_bounds* a = scene.nodes[older]
	mm_bounds* b = scene.nodes[newer]
	asserts(c"both commits are placed apart", a.x != b.x || a.y != b.y)
	char* svg = gaps_svg(d, scene)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(d)
	gaps_error(c"gitGraph\ncommit id: \"same\"\nbranch b\ncommit\ncheckout main\ncommit\nmerge b id: \"same\"\n", c"empty or duplicate commit id")
	gaps_error(c"gitGraph\ncommit id: \"@branch:main\"\n", c"empty or duplicate commit id")
	gaps_error(c"gitGraph\ncommit \"a\" \"b\"\n", c"duplicate commit property")
	gaps_prefixes(source)

int gaps_polygon_points(mm_scene* scene, int most):
	int found = 0
	for mm_primitive* p in scene.items:
		if (p.kind == MM_POLYGON && p.points != 0 && p.points.length > found && p.points.length <= most): found = p.points.length
	return found

void test_block_composite_span_arrow_lists_and_quoted_link_labels():
	char* source = c"block\ncolumns 3\nblock:g:2\ncolumns 2\nh i\nend\nB\nM<[\"Many\"]>(x, down)\nU<[\"Up\"]>(up, up)\nA space:1 C\nA-- \"X\" -->C\n"
	mm_document* d = gaps_parse(source)
	int group = gaps_node(d, c"g")
	mm_node* g = d.nodes[group]
	assert_equal(2, g.value_y)
	assert_equal(2, g.value_x)
	assert_strings_equal(c"right,left,down", d.nodes[gaps_node(d, c"M")].direction)
	assert_strings_equal(c"up", d.nodes[gaps_node(d, c"U")].direction)
	assert_equal(1, d.edges.length)
	mm_edge* link = d.edges[0]
	assert_strings_equal(c"X", link.label)
	assert_equal(1, link.arrow)
	mm_scene* scene = mm_render(d)
	mm_bounds* gb = scene.nodes[group]
	mm_bounds* bb = scene.nodes[gaps_node(d, c"B")]
	asserts(c"span-2 composite is wider than a single cell", gb.w > bb.w + 40)
	assert_equal(gb.y, bb.y)
	asserts(c"composite and B share the first row", bb.x > gb.x + gb.w)
	# Three heads: central square corners plus five points per arm.
	assert_equal(38, gaps_polygon_points(scene, 38))
	char* svg = gaps_svg(d, scene)
	asserts(c"link label exported", index_of(svg, c">X</text>") >= 0)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(d)
	gaps_error(c"block\ncolumns 2\nblock:g:3\nA\nend\n", c"block span exceeds parent columns")
	gaps_error(c"block\nA<[\"L\"]>(x, sideways)\n", c"expected block arrow direction right, left, up, down, x or y")
	gaps_error(c"block\nA B\nA-- \"X\" B\n", c"expected link after link label")
	gaps_prefixes(source)

void test_flow_edge_classes_with_motion_properties():
	char* source = c"flowchart LR\n  A e1@--> B\n  A e2@--> C\n  classDef animate stroke-dasharray: 9,5,stroke-dashoffset: 900,animation: dash 25s linear infinite;\n  classDef escaped stroke-dasharray: 4\\,2,stroke:#ff0000\n  class e1 animate\n  class e2 escaped\n"
	mm_document* d = gaps_parse(source)
	assert_equal(3, d.nodes.length)
	asserts(c"edge class does not create a node", mm_find_node(d, c"e1") < 0)
	mm_edge* first = d.edges[0]
	mm_edge* second = d.edges[1]
	asserts(c"dash from class", (first.style.mask & MM_STYLE_DASH) != 0)
	assert_equal(9, first.style.dash)
	assert_equal(5, first.style.gap)
	assert_equal(4, second.style.dash)
	assert_equal(2, second.style.gap)
	assert_equal(0xff0000, second.style.stroke)
	mm_scene* scene = mm_render(d)
	char* svg = gaps_svg(d, scene)
	asserts(c"edge dash exported", index_of(svg, c"stroke-dasharray=\"9 5\"") >= 0)
	asserts(c"motion properties are not exported", index_of(svg, c"25s") < 0)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(d)
	gaps_error(c"flowchart LR\nA e1@--> B\nclass e1 missing\n", c"assigned style class has no classDef")
	gaps_error(c"flowchart LR\nA\nstyle A animation: url(x)\n", c"stroke-dashoffset takes a length; animation properties take CSS keywords, names and times")
	gaps_error(c"flowchart LR\nA\nstyle A stroke-dashoffset: 9q\n", c"stroke-dashoffset takes a length; animation properties take CSS keywords, names and times")
	gaps_error(c"flowchart LR\nA\nstyle A stroke-dasharray: 9,5,x\n", c"style property requires colon")
	gaps_prefixes(source)

void test_yaml_multiline_quoted_scalars():
	char* source = c"---\ntitle: \"first line\n  second \\\n  third\n\n  para\"\nconfig:\n  gitGraph:\n    mainBranchName: 'trunk\n      line'\n---\ngitGraph\ncommit\n"
	mm_document* d = gaps_parse(source)
	assert_strings_equal(c"first line second third\npara", d.title)
	assert_strings_equal(c"trunk line", mm_config_value(d, c"gitGraph.mainBranchName"))
	mm_scene* scene = mm_render(d)
	char* svg = gaps_svg(d, scene)
	asserts(c"folded branch name drawn", index_of(svg, c"trunk line") >= 0)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(d)
	gaps_error(c"---\ntitle: \"never\n  closed\n---\nflowchart LR\nA\n", c"unterminated quoted configuration value")
	gaps_error(c"---\ntitle: \"a\n  b\" tail\n---\nflowchart LR\nA\n", c"unexpected text after quoted configuration value")
	gaps_prefixes(source)

void test_yaml_dotted_member_keys_drive_tree_icons():
	char* source = c"---\nconfig:\n  treeView:\n    showIcons: true\n    filenameIcons:\n      README.md: book\n    extensionIcons:\n      .ts: code\n      tsx: user\n      .d.ts: star\n      .txt: none\n---\ntreeView-beta\n    a.ts\n    b.tsx\n    c.d.ts\n    README.md\n    x.txt\n    y.md\n"
	mm_document* d = gaps_parse(source)
	list[char*] expected = list[char*]{c"code", c"user", c"star", c"book", c"none", c"file"}
	list[char*] labels = list[char*]{c"a.ts", c"b.tsx", c"c.d.ts", c"README.md", c"x.txt", c"y.md"}
	for k in range(labels.length):
		int index = -1
		for i in range(d.nodes.length):
			mm_node* n = d.nodes[i]
			if (strcmp(n.label, labels[k]) == 0): index = i
		asserts(c"tree row exists", index >= 0)
		assert_strings_equal(expected[k], mm_tree_icon(d, index, 1))
	__w_list_free(cast(__w_list*, expected))
	__w_list_free(cast(__w_list*, labels))
	mm_scene* scene = mm_render(d)
	char* svg = gaps_svg(d, scene)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(d)
	gaps_error(c"---\nconfig:\n  treeView:\n    row.Indent: 4\n---\ntreeView-beta\n    a\n", c"invalid frontmatter key")
	gaps_prefixes(source)

void test_font_awesome_label_prefixes_draw_pictograms():
	char* source = c"flowchart TD\n    B[\"fa:fa-twitter for peace\"]\n    B-->C[fa:fa-ban forbidden]\n    B-->D(fa:fa-spinner)\n    B-->E[\"fab:fa-truck-bold a custom icon\"]\n"
	mm_document* d = gaps_parse(source)
	assert_strings_equal(c"fa:fa-ban forbidden", d.nodes[gaps_node(d, c"C")].label)
	assert_equal(28, mm_icon_kind(c"fa-twitter"))
	assert_equal(24, mm_icon_kind(c"fa-ban"))
	assert_equal(27, mm_icon_kind(c"fa-truck-bold"))
	mm_scene* scene = mm_render(d)
	int circles = 0
	int peace = 0
	for mm_primitive* p in scene.items:
		if (p.kind == MM_TEXT): asserts(c"no literal Font Awesome reference", index_of(p.text, c"fa-") < 0)
		if (p.kind == MM_TEXT && strcmp(p.text, c"for peace") == 0): peace = 1
		if (p.kind == MM_CIRCLE): circles = circles + 1
	asserts(c"text after the glyph is its own run", peace)
	# ban: 1 ring; spinner: 8 dots; truck: 2 wheels.
	asserts(c"pictograms drawn", circles >= 11)
	char* svg = gaps_svg(d, scene)
	asserts(c"reference text not exported", index_of(svg, c"fa:fa-") < 0)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(d)
	# Without a `fa-` name the prefix is ordinary text.
	d = gaps_parse(c"flowchart TD\nA[fa:x and fa:fa-]\n")
	scene = mm_render(d)
	int literal = 0
	for mm_primitive* p in scene.items:
		if (p.kind == MM_TEXT && index_of(p.text, c"fa:x") >= 0): literal = 1
	asserts(c"non-reference text kept", literal)
	mm_scene_free(scene)
	mm_document_free(d)
	gaps_prefixes(source)
