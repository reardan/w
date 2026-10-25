# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* framework_parse(char* text):
	mm_document* d = mm_parse(text, strlen(text))
	if (d.error != 0): println2(d.error)
	asserts(c"framework parses", d.error == 0)
	return d

void test_framework_treeview_and_fishbone_ancestry():
	mm_document* d = framework_parse(c"treeView-beta\nproject/\n  src/\n    main.w\n  README.md\n")
	mm_node* leaf = d.nodes[2]
	assert_equal(1, leaf.parent)
	mm_scene* s = mm_render(d)
	mm_bounds* root = s.nodes[0]
	mm_bounds* b = s.nodes[2]
	asserts(c"tree rows retain source order", b.y > root.y && b.x > root.x)
	mm_scene_free(s)
	mm_document_free(d)
	d = framework_parse(c"ishikawa-beta\nFailure\nEquipment\n  Lens\n    Scratched\nPeople\n  Training\n")
	leaf = d.nodes[4]
	assert_equal(0, leaf.parent)
	leaf = d.nodes[3]
	assert_equal(2, leaf.parent)
	s = mm_render(d)
	mm_bounds* head = s.nodes[0]
	mm_bounds* top = s.nodes[1]
	mm_bounds* bottom = s.nodes[4]
	asserts(c"causes alternate around spine", top.y < head.y && bottom.y > head.y)
	asserts(c"problem at head of spine", head.x > bottom.x)
	mm_scene_free(s)
	mm_document_free(d)

void test_framework_cynefin_domains_and_transitions():
	mm_document* d = framework_parse(c"cynefin-beta\ntitle Decisions\ncomplex\n\"Experiment\"\nclear\n\"Procedure\"\ncomplex --> complicated : \"Learned\"\n")
	assert_equal(5, d.nodes.length)
	assert_equal(1, d.edges.length)
	mm_node* n = d.nodes[0]
	assert_equal(1, n.members.length)
	mm_scene* s = mm_render(d)
	mm_bounds* a = s.nodes[0]
	mm_bounds* b = s.nodes[1]
	mm_bounds* c = s.nodes[4]
	# Upstream geometry: 800x600 field in 40px padding, adjacent quadrants,
	# Confusion centred on the cross.
	assert_equal(880, s.width)
	assert_equal(680, s.height)
	assert_equal(400, a.w)
	assert_equal(300, a.h)
	assert_equal(a.x + a.w, b.x)
	assert_equal(a.x + a.w, c.x + c.w / 2)
	assert_equal(a.y + a.h, c.y + c.h / 2)
	char* svg = mm_svg(s)
	asserts(c"items exported", index_of(svg, c"Experiment") >= 0)
	asserts(c"domain model exported", index_of(svg, c"Probe → Sense → Respond") >= 0)
	asserts(c"transition label exported", index_of(svg, c">Learned<") >= 0)
	int last_box = -1
	int legend = -1
	for i in range(s.items.length):
		mm_primitive* p = s.items[i]
		if (p.kind == MM_BOX): last_box = i
		if (index_of(p.text, c"Learned") >= 0): legend = i
	asserts(c"transition text not hidden by region fills", legend > last_box)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_framework_cynefin_confusion_overflow_and_self_loops():
	mm_document* d = framework_parse(c"cynefin-beta\nconfusion\n\"One\"\n\"Two\"\n\"Three\"\n\"Four\"\n\"Five\"\ncomplex --> complex\n")
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"confusion caps badges", index_of(svg, c">Three<") >= 0 && index_of(svg, c">Four<") < 0)
	asserts(c"confusion overflow badge", index_of(svg, c">+2 more<") >= 0)
	free(svg)
	for mm_primitive* p in s.items: asserts(c"self-loop transition skipped", p.role != 3)
	mm_scene_free(s)
	mm_document_free(d)

void test_framework_ishikawa_upstream_geometry():
	mm_document* d = framework_parse(c"ishikawa-beta\nBlurry Photo\nProcess\n  Out of focus\n  Shutter speed too slow\nUser\n  Shaky hands\nEquipment\n  Lens\n    Dirty lens\n    Damaged lens\nEnvironment\n  Too dark\n")
	mm_scene* s = mm_render(d)
	mm_bounds* head = s.nodes[0]
	int spine_y = head.y + head.h / 2
	int spine = 0
	int min_x = 100000
	for mm_primitive* p in s.items:
		if (p.kind == MM_LINE && p.y == spine_y && p.y2 == spine_y && p.style.width == 2): spine = spine + 1
		if (p.x < min_x): min_x = p.x
	assert_equal(1, spine)
	asserts(c"content shifted to the margin", min_x >= 20 && min_x <= 22)
	mm_bounds* process = s.nodes[1]
	mm_bounds* user = s.nodes[4]
	asserts(c"first cause above, second below", process.y + process.h < spine_y && user.y > spine_y)
	mm_bounds* equipment = s.nodes[6]
	asserts(c"later pairs sit left of earlier pairs", equipment.x < process.x)
	asserts(c"head at the right end", head.x > process.x + process.w)
	# Labels wrap at 15 characters.
	char* svg = mm_svg(s)
	asserts(c"cause wrapped", index_of(svg, c">Shutter speed<") >= 0 && index_of(svg, c">too slow<") >= 0)
	free(svg)
	int polygons = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_POLYGON): polygons = polygons + 1
	# One head plus an arrowhead per bone (4 causes, 7 sub-causes).
	assert_equal(1 + 11, polygons)
	mm_scene_free(s)
	mm_document_free(d)

void test_framework_wardley_normalized_axes_and_dependencies():
	mm_document* d = framework_parse(c"wardley-beta\ntitle Value chain\nanchor User [0.9, 0.1]\ncomponent Service [0.6, 0.5]\ncomponent Database [0.2, 1.0]\nUser -> Service\nService --> Database\n")
	mm_node* a = d.nodes[0]
	assert_equal(900, a.value_y)
	assert_equal(100, a.value_x)
	assert_equal(2, d.edges.length)
	mm_scene* s = mm_render(d)
	mm_bounds* first = s.nodes[0]
	mm_bounds* last = s.nodes[2]
	asserts(c"visibility increases upward, evolution rightward", first.y < last.y && first.x < last.x)
	char* svg = mm_svg(s)
	asserts(c"axis labels rendered", index_of(svg, c"Commodity") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_framework_invalid_input_and_prefixes():
	list[char*] bad = list[char*]{c"wardley-beta\ncomponent A [1.1, 0.5]", c"wardley-beta\ncomponent A [0.5, -1]", c"wardley-beta\nA -> Missing", c"cynefin-beta\nunknown", c"cynefin-beta\n\"No domain\"", c"treeView-beta\nA\n  B\n C", c"treeView-beta\nA icon(custom)", c"treeView-beta\nA:::", c"treeView-beta\nA ::: x.y", c"treeView-beta\nA ##", c"treeView-beta\nA\n│   B", c"treeView-beta\nA\n── B",c"ishikawa-beta\n"}
	for char* text in bad:
		mm_document* d = mm_parse(text, strlen(text))
		asserts(c"invalid framework fails explicitly", d.error != 0)
		asserts(c"invalid framework has no preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))
	list[char*] samples = list[char*]{c"wardley-beta\ncomponent A [0.5, 0.6]\nA -> A\n", c"cynefin-beta\ncomplex\n\"Text\"\ncomplex --> clear : \"Resolved\"\n", c"treeView-beta\nA/\n  B\n", c"ishikawa-beta\nProblem\nCause\n  Detail\n"}
	for char* text in samples:
		for size in range(strlen(text) + 1):
			mm_document* d = mm_parse(text, size)
			mm_scene* s = mm_render(d)
			asserts(c"parse and render agree", (d.error == 0 && s != 0) || (d.error != 0 && s == 0))
			mm_scene_free(s)
			mm_document_free(d)
	__w_list_free(cast(__w_list*, samples))

void test_framework_outline_accessibility_is_not_a_node():
	list[char*] headers = list[char*]{c"treeView-beta", c"ishikawa-beta"}
	for char* header in headers:
		string_builder* source = string_from(header)
		string_append(source, c"\naccTitle: Accessible outline\naccDescr: Outline description\nRoot\n  Category\n  accDescr {\n    Detailed description\n  }\n    Leaf\n")
		mm_document* d = framework_parse(source.data)
		assert_equal(3, d.nodes.length)
		mm_node* leaf = d.nodes[2]
		assert_equal(1, leaf.parent)
		assert_strings_equal(c"Accessible outline", d.accessibility_title)
		assert_strings_equal(c"\n    Detailed description", d.accessibility_description)
		mm_scene* scene = mm_render(d)
		char* svg = mm_svg(scene)
		asserts(c"outline accessibility exported", index_of(svg, c"<title id=\"mermaid-title\">Accessible outline</title>") >= 0)
		for mm_primitive* item in scene.items:
			asserts(c"metadata excluded from visible labels", index_of(item.text, c"accTitle:") < 0 && index_of(item.text, c"accDescr:") < 0)
		free(svg)
		mm_scene_free(scene)
		mm_document_free(d)
		string_free(source)
	__w_list_free(cast(__w_list*, headers))

void test_framework_treeview_tree_command_prefixes_and_descriptions():
	# Plain-space and NBSP-padded (GNU tree) prefixes, plus indented and
	# prefixed lines mixed in one forest, all yield the same ancestry.
	list[char*] sources = list[char*]{c"treeView-beta\n.\n├── src\n│   ├── main.w ## Entry point\n│   └── \"lib dir\"\n│       └── util.w\n└── README.md\n", c"treeView-beta\n.\n├──\xc2\xa0src\n│\xc2\xa0\xc2\xa0 ├──\xc2\xa0main.w ## Entry point\n│\xc2\xa0\xc2\xa0 └──\xc2\xa0\"lib dir\"\n│\xc2\xa0\xc2\xa0     └──\xc2\xa0util.w\n│\n└──\xc2\xa0README.md\n", c"treeView-beta\n.\n    src\n        main.w ## Entry point\n│   └── \"lib dir\"\n            util.w\n    README.md\n"}
	for char* source in sources:
		mm_document* d = framework_parse(source)
		assert_equal(6, d.nodes.length)
		list[int] parents = list[int]{-1, 0, 1, 1, 3, 0}
		for i in range(6):
			mm_node* n = d.nodes[i]
			assert_equal(parents[i], n.parent)
		__w_list_free(cast(__w_list*, parents))
		mm_node* main = d.nodes[2]
		assert_strings_equal(c"main.w", main.label)
		assert_strings_equal(c"Entry point", main.annotation)
		mm_node* folder = d.nodes[3]
		assert_strings_equal(c"lib dir", folder.label)
		assert_strings_equal(c"", folder.annotation)
		mm_scene* s = mm_render(d)
		char* svg = mm_svg(s)
		asserts(c"description exported", index_of(svg, c"fill=\"#64748b\" stroke=\"none\" stroke-width=\"2\" x=\"") >= 0 && index_of(svg, c">Entry point<") >= 0)
		asserts(c"prefix glyphs are not label text", index_of(svg, c"├") < 0 && index_of(svg, c"│") < 0)
		free(svg)
		char* saved = mm_write(d)
		assert_strings_equal(source, saved)
		free(saved)
		mm_scene_free(s)
		mm_document_free(d)
		for size in range(strlen(source) + 1):
			mm_document* prefix = mm_parse(source, size)
			mm_scene* scene = mm_render(prefix)
			asserts(c"tree prefix parse and render agree", (prefix.error == 0 && scene != 0) || (prefix.error != 0 && scene == 0))
			mm_scene_free(scene)
			mm_document_free(prefix)
	__w_list_free(cast(__w_list*, sources))
	char* bad = c"ishikawa-beta\nProblem\n├── Cause\n"
	mm_document* d = mm_parse(bad, strlen(bad))
	assert_strings_equal(c"outline annotations and tree command prefixes are not yet supported", d.error)
	mm_document_free(d)
	bad = c"treeView-beta\nA\n│   B\n"
	d = mm_parse(bad, strlen(bad))
	assert_strings_equal(c"tree command prefix requires a branch marker", d.error)
	mm_document_free(d)

int framework_count(mm_scene* s, int kind, int dashed, int stroke):
	int count = 0
	for mm_primitive* p in s.items:
		if (p.kind == kind && p.dashed == dashed && (stroke < 0 || ((p.style.mask & 2) && p.style.stroke == stroke))): count = count + 1
	return count

void test_framework_wardley_evolution_notes_pipelines_and_decorators():
	char* source = c"wardley-beta\ntitle Tea Shop\nevolution Uncharted -> Emerging -> Good -> Best\nanchor Business [0.95, 0.63]\ncomponent Cup of Tea [0.79, 0.61] label [19, -4]\ncomponent Kettle [0.43, 0.35] (build) inertia\ncomponent Power [0.1, 0.7] (outsource)\ncomponent Water [0.38, 0.82] (buy) (inertia)\nBusiness -> Cup of Tea\nCup of Tea -> Kettle\nKettle -> Power\nevolve Kettle 0.62\nnote \"Standardising power\" [0.30, 0.49]\nnote Unquoted note [0.2, 0.2]\npipeline Kettle\n{\n  component Campfire Kettle [0.30]\n  component Electric Kettle [0.55] (buy)\n}\npipeline Power [0.6, 0.9] { component Grid [0.75] }\nElectric Kettle -> Power\n"
	mm_document* d = framework_parse(source)
	assert_equal(10, d.nodes.length)
	assert_equal(4, d.edges.length)
	mm_node* kettle = d.nodes[2]
	assert_strings_equal(c"build", mm_wardley_get(kettle, c"strategy"))
	assert_strings_equal(c"1", mm_wardley_get(kettle, c"inertia"))
	assert_strings_equal(c"620", mm_wardley_get(kettle, c"evolve"))
	assert_strings_equal(c"300 550", mm_wardley_get(kettle, c"pipeline"))
	mm_node* power = d.nodes[3]
	assert_strings_equal(c"600 900", mm_wardley_get(power, c"pipeline"))
	mm_node* water = d.nodes[4]
	assert_strings_equal(c"buy", mm_wardley_get(water, c"strategy"))
	assert_strings_equal(c"1", mm_wardley_get(water, c"inertia"))
	mm_node* note = d.nodes[5]
	assert_equal(3, note.shape)
	assert_strings_equal(c"Standardising power", note.label)
	assert_equal(300, note.value_y)
	assert_equal(490, note.value_x)
	note = d.nodes[6]
	assert_strings_equal(c"Unquoted note", note.label)
	mm_node* campfire = d.nodes[7]
	assert_equal(2, campfire.parent)
	assert_equal(2, campfire.shape)
	assert_equal(430, campfire.value_y)
	assert_equal(300, campfire.value_x)
	mm_node* grid = d.nodes[9]
	assert_equal(3, grid.parent)
	mm_scene* s = mm_render(d)
	mm_bounds* k = s.nodes[2]
	mm_bounds* child = s.nodes[7]
	asserts(c"pipeline component sits under its parent", child.y > k.y && child.x < k.x)
	assert_equal(1, framework_count(s, MM_LINE, 1, 0xdc2626))
	assert_equal(1, framework_count(s, MM_CIRCLE, 0, 0xdc2626))
	assert_equal(2, framework_count(s, MM_BOX, 2, -1))
	assert_equal(2, framework_count(s, MM_BOX, 0, -1))
	int halos = 0
	int cup_label = 0
	mm_bounds* cup = s.nodes[1]
	for mm_primitive* p in s.items:
		if (p.kind == MM_CIRCLE && p.x2 - p.x == 36): halos = halos + 1
		if (p.kind == MM_TEXT && strcmp(p.text, c"Cup of Tea") == 0 && p.x == cup.x + 19 && p.y == cup.y - 4): cup_label = 1
	assert_equal(4, halos)
	asserts(c"custom label offset applied", cup_label)
	char* svg = mm_svg(s)
	asserts(c"custom stages rendered", index_of(svg, c"Uncharted") >= 0 && index_of(svg, c">Best<") >= 0 && index_of(svg, c"Genesis") < 0)
	asserts(c"note rendered", index_of(svg, c"Standardising power") >= 0)
	asserts(c"evolution colour exported", index_of(svg, c"#dc2626") >= 0)
	free(svg)
	char* saved = mm_write(d)
	assert_strings_equal(source, saved)
	free(saved)
	mm_scene_free(s)
	mm_document_free(d)
	list[char*] samples = list[char*]{source, c"wardley-beta\nevolve \"A\" 0.4\ncomponent A [0.5, 0.6] label [-5, 7] (outsource)\n"}
	for char* text in samples:
		for size in range(strlen(text) + 1):
			mm_document* prefix = mm_parse(text, size)
			mm_scene* scene = mm_render(prefix)
			asserts(c"wardley prefix parse and render agree", (prefix.error == 0 && scene != 0) || (prefix.error != 0 && scene == 0))
			mm_scene_free(scene)
			mm_document_free(prefix)
	__w_list_free(cast(__w_list*, samples))

void test_framework_wardley_modifier_diagnostics():
	list[char*] bad = list[char*]{c"wardley-beta\ncomponent A [0.5, 0.5] (rent)", c"wardley-beta\ncomponent A [0.5, 0.5] (build) (buy)", c"wardley-beta\ncomponent A [0.5, 0.5] label [1000, 0]", c"wardley-beta\nevolution A -> B -> C", c"wardley-beta\nevolution A -> -> C -> D", c"wardley-beta\nevolution A -> B -> C -> D\nevolution A -> B -> C -> D", c"wardley-beta\nevolve Missing 0.5", c"wardley-beta\ncomponent A [0.5, 0.5]\nevolve A->B 0.6", c"wardley-beta\ncomponent A [0.5, 0.5]\nevolve A 0.5\nevolve A 0.6", c"wardley-beta\ncomponent A [0.5, 0.5]\npipeline A", c"wardley-beta\ncomponent A [0.5, 0.5]\npipeline A [0.6, 0.4]", c"wardley-beta\ncomponent A [0.5, 0.5]\npipeline A [0.4, 0.5] {\ncomponent B [0.9]\n}", c"wardley-beta\ncomponent A [0.5, 0.5]\npipeline A {\n}", c"wardley-beta\ncomponent A [0.5, 0.5]\npipeline A {\ncomponent B [0.6]\n", c"wardley-beta\ncomponent A [0.5, 0.5]\npipeline A {\nB [0.6]\n}", c"wardley-beta\nnote \"\" [0.1, 0.1]", c"wardley-beta\nnote Text", c"wardley-beta\ncomponent A [0.5, 0.5]\npipeline A [0.1, 0.2]\npipeline A [0.3, 0.4]", c"wardley-beta\ncomponent A [0.5, 0.5]\npipeline A {\ncomponent B [0.6]\n}\npipeline B [0.1, 0.2]", c"wardley-beta\nA +> B"}
	for char* text in bad:
		mm_document* d = mm_parse(text, strlen(text))
		if (d.error == 0): println2(text)
		asserts(c"invalid Wardley modifier fails explicitly", d.error != 0)
		asserts(c"invalid Wardley modifier has no preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))
	char* text = c"wardley-beta\ncomponent A [0.5, 0.5] (rent)\n"
	mm_document* d = mm_parse(text, strlen(text))
	assert_strings_equal(c"unsupported Wardley decorator; supported: build, buy, outsource, inertia", d.error)
	mm_document_free(d)
	text = c"wardley-beta\ncomponent A [0.5, 0.5]\npipeline A [0.4, 0.5] {\ncomponent B [0.9]\n}\n"
	d = mm_parse(text, strlen(text))
	assert_strings_equal(c"Wardley pipeline component outside pipeline range", d.error)
	mm_document_free(d)
