# wbuild: x64
# Issue #820: Wardley flows, market, size, annotations, forces and stage
# boundaries; mindmap icon pictograms, indentation and colorBy; treeView
# icons and classes; kanban column metadata and repeated IDs.
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* fgaps_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0):
		println2(source)
		println2(d.error)
	asserts(c"gap source parses", d.error == 0)
	return d

char* fgaps_svg(mm_document* d):
	mm_scene* scene = mm_render(d)
	asserts(c"gap scene exists", scene != 0)
	char* svg = mm_svg(scene)
	mm_scene_free(scene)
	char* written = mm_write(d)
	assert_strings_equal(d.source, written)
	free(written)
	return svg

void fgaps_error(char* source, char* message):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error == 0): println2(source)
	asserts(c"gap diagnostic reported", d.error != 0)
	if (d.error != 0 && strcmp(d.error, message) != 0): assert_strings_equal(message, d.error)
	asserts(c"diagnosed source suppresses preview", mm_render(d) == 0)
	mm_document_free(d)

void fgaps_prefixes(char* source):
	for length in range(strlen(source) + 1):
		mm_document* d = mm_parse(source, length)
		mm_scene* scene = mm_render(d)
		if (d.error != 0): asserts(c"prefix error suppresses scene", scene == 0)
		if (scene != 0):
			char* svg = mm_svg(scene)
			free(svg)
		mm_scene_free(scene)
		mm_document_free(d)

int fgaps_count(mm_scene* scene, int kind):
	int count = 0
	for mm_primitive* item in scene.items:
		if (item.kind == kind): count = count + 1
	return count

mm_edge* fgaps_edge(mm_document* d, int index):
	return d.edges[index]

void test_wardley_flows_and_link_labels():
	char* source = c"wardley-beta\ncomponent User [0.90, 0.95]\ncomponent App [0.75, 0.75]\ncomponent API [0.60, 0.60]\ncomponent Cache [0.65, 0.45]\ncomponent Database [0.15, 0.80]\nUser -> App\nApp +> API\nAPI +<> Cache\nCache +'backup'> Database\nDatabase +< API\nApp -.-> Cache\nUser --> Database; customer data\nAPI > Database\n"
	mm_document* d = fgaps_parse(source)
	assert_equal(8, d.edges.length)
	assert_equal(0, fgaps_edge(d, 0).arrow)
	assert_equal(0, fgaps_edge(d, 0).scope)
	assert_equal(1, fgaps_edge(d, 1).arrow)
	assert_equal(1, fgaps_edge(d, 1).scope)
	assert_equal(3, fgaps_edge(d, 2).arrow)
	assert_equal(1, fgaps_edge(d, 3).arrow)
	assert_strings_equal(c"backup", fgaps_edge(d, 3).label)
	assert_equal(2, fgaps_edge(d, 4).arrow)
	assert_equal(1, fgaps_edge(d, 5).dashed)
	assert_strings_equal(c"customer data", fgaps_edge(d, 6).label)
	assert_equal(0, fgaps_edge(d, 7).arrow)
	mm_scene* scene = mm_render(d)
	# Each arrowhead adds two short lines; flows carry 1 + 2 + 1 + 1 heads.
	int heads = 0
	for mm_primitive* item in scene.items:
		if (item.kind == MM_LINE):
			int dx = item.x2 - item.x
			int dy = item.y2 - item.y
			if (dx * dx + dy * dy <= 200 && dx * dx + dy * dy > 100): heads = heads + 1
	asserts(c"flow arrowheads drawn", heads >= 10)
	mm_scene_free(scene)
	char* svg = fgaps_svg(d)
	asserts(c"flow label exported", index_of(svg, c">backup<") >= 0 && index_of(svg, c">customer data<") >= 0)
	asserts(c"dashed link exported", index_of(svg, c"stroke-dasharray") >= 0)
	free(svg)
	mm_document_free(d)
	fgaps_error(c"wardley-beta\ncomponent A [0.5, 0.5]\ncomponent B [0.4, 0.4]\nA +'open B", c"unterminated Wardley flow label")
	fgaps_error(c"wardley-beta\ncomponent A [0.5, 0.5]\ncomponent B [0.4, 0.4]\nA +'x' B", c"expected Wardley flow direction after label")
	fgaps_error(c"wardley-beta\ncomponent A [0.5, 0.5]\ncomponent B [0.4, 0.4]\nA -> B;", c"empty Wardley link label")
	fgaps_prefixes(source)

void test_wardley_market_size_annotations_and_forces():
	char* source = c"wardley-beta\ntitle Forces\nsize [800, 1000]\nevolution Genesis / Concept@0.2 -> Custom@0.5 -> Product@0.8 -> Commodity@1.0\ncomponent Cloud [0.30, 0.95] (market)\ncomponent API [0.60, 0.70] (buy) inertia\nCloud -> API\nannotations [0.10, 0.90]\nannotation 2,[0.50, 0.50] \"Second\"\nannotation 1,[0.60, 0.65] \"Critical\"\nannotation 1,[0.62, 0.40] \"Critical\"\naccelerator \"AI Adoption\" [0.55, 0.25]\ndeaccelerator \"Legacy\" [0.15, 0.75]\n"
	mm_document* d = fgaps_parse(source)
	assert_strings_equal(c"800 1000", mm_setting(d, c"wardley.size"))
	assert_strings_equal(c"200 500 800 1000", mm_setting(d, c"wardley.boundaries"))
	assert_strings_equal(c"100 900", mm_setting(d, c"wardley.annotations"))
	mm_node* cloud = d.nodes[0]
	assert_strings_equal(c"market", mm_wardley_get(cloud, c"strategy"))
	mm_node* second = d.nodes[2]
	assert_equal(4, second.shape)
	assert_strings_equal(c"2", second.annotation)
	assert_strings_equal(c"Second", second.label)
	assert_equal(500, second.value_y)
	mm_node* force = d.nodes[5]
	assert_equal(5, force.shape)
	assert_strings_equal(c"AI Adoption", force.label)
	force = d.nodes[6]
	assert_equal(6, force.shape)
	int stages = 0
	int seconds = 0
	for mm_note* note in d.notes:
		if (note.node == -1): stages = stages + 1
		if (note.node == -2):
			seconds = seconds + 1
			assert_strings_equal(c"Concept", note.text)
	assert_equal(4, stages)
	assert_equal(1, seconds)
	mm_scene* scene = mm_render(d)
	asserts(c"size scales the map", scene.width <= 900 && scene.height >= 950)
	# Market: a white disc and three white dots instead of the plain circle.
	int white = 0
	for mm_primitive* item in scene.items:
		if (item.kind == MM_CIRCLE && (item.style.mask & 1) != 0 && item.style.fill == 0xffffff): white = white + 1
	# 1 market disc + 3 market dots + 3 annotation markers.
	assert_equal(7, white)
	assert_equal(2, fgaps_count(scene, MM_POLYGON))
	mm_scene_free(scene)
	char* svg = fgaps_svg(d)
	asserts(c"legend sorted by number", index_of(svg, c"1. Critical") >= 0 && index_of(svg, c"1. Critical") < index_of(svg, c"2. Second"))
	asserts(c"legend lists repeated numbers once", index_of(svg + index_of(svg, c"1. Critical") + 4, c"1. Critical") < 0)
	asserts(c"forces exported", index_of(svg, c">AI Adoption<") >= 0 && index_of(svg, c">Legacy<") >= 0)
	asserts(c"dual stage label exported", index_of(svg, c">Genesis<") >= 0 && index_of(svg, c">Concept<") >= 0)
	free(svg)
	mm_document_free(d)
	# Three stages are fine upstream; boundaries apply only when all are given.
	d = fgaps_parse(c"wardley-beta\nevolution A@0.3 -> B -> C\ncomponent X [0.5, 0.5]\n")
	asserts(c"partial boundaries ignored", mm_setting(d, c"wardley.boundaries") == 0)
	char* text = fgaps_svg(d)
	free(text)
	mm_document_free(d)
	fgaps_error(c"wardley-beta\nsize [50, 600]", c"Wardley size must be integers from 100 to 4000")
	fgaps_error(c"wardley-beta\nsize [800, 600]\nsize [800, 600]", c"duplicate Wardley size")
	fgaps_error(c"wardley-beta\nannotation 0,[0.5, 0.5] \"x\"", c"Wardley annotation number must be 1 to 999")
	fgaps_error(c"wardley-beta\nannotation 1,[0.5, 0.5] text", c"Wardley annotation text must be quoted")
	fgaps_error(c"wardley-beta\nevolution A@0.5 -> B@0.4", c"Wardley stage boundaries must increase")
	fgaps_error(c"wardley-beta\nevolution A@2 -> B@0.4", c"expected Wardley stage boundary between zero and one")
	fgaps_error(c"wardley-beta\nevolution A", c"Wardley evolution axis requires two to eight stages")
	fgaps_error(c"wardley-beta\ncomponent A [0.5, 0.5] (ecosystem)", c"unsupported Wardley decorator; supported: build, buy, outsource, market, inertia")
	fgaps_prefixes(source)

void test_mindmap_icon_pictograms_and_mapping():
	assert_equal(1, mm_icon_kind(c"fa fa-book"))
	assert_equal(0, mm_icon_kind(c"mdi mdi-folder-open"))
	assert_equal(3, mm_icon_kind(c"fa-solid fa-user"))
	assert_equal(5, mm_icon_kind(c"fa fa-cloud"))
	assert_equal(MM_ICON_COUNT, mm_icon_kind(c"logos:react"))
	assert_equal(-1, mm_icon_kind(c"none"))
	char* name = mm_icon_name(c"fa fa-book")
	assert_strings_equal(c"book", name)
	free(name)
	char* source = c"mindmap\n  root((mindmap))\n    Origins\n      ::icon(fa fa-book)\n    Tools\n      ::icon(logos:react)\n"
	mm_document* d = fgaps_parse(source)
	mm_scene* scene = mm_render(d)
	char* svg = mm_svg(scene)
	asserts(c"icon names are not printed", index_of(svg, c"fa fa-book") < 0)
	asserts(c"unknown icon shows its initial", index_of(svg, c">R</text>") >= 0)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(d)

void test_mindmap_indentation_heuristic_and_color_by():
	# Upstream: a node's parent is the nearest earlier node indented less.
	mm_document* d = fgaps_parse(c"mindmap\nRoot\n    A\n        B\n      C\n   D\n")
	mm_node* c = d.nodes[3]
	mm_node* dd = d.nodes[4]
	assert_equal(1, c.parent)
	assert_equal(0, dd.parent)
	mm_scene* scene = mm_render(d)
	# Branch colours: A, B, C share branch 0; D is branch 1; the root is plain.
	int branch_zero = 0
	int branch_one = 0
	for mm_primitive* item in scene.items:
		if (item.role == 5 && item.series == 0): branch_zero = branch_zero + 1
		if (item.role == 5 && item.series == 1): branch_one = branch_one + 1
	assert_equal(3, branch_zero)
	assert_equal(1, branch_one)
	mm_scene_free(scene)
	mm_document_free(d)
	d = fgaps_parse(c"---\nconfig:\n  mindmap:\n    colorBy: depth\n---\nmindmap\n  root((mindmap))\n    a{{A}}\n      b[B]\n    c{{C}}\n")
	scene = mm_render(d)
	int depth_one = 0
	int depth_two = 0
	for mm_primitive* item in scene.items:
		if (item.role == 5 && item.series == 0): depth_one = depth_one + 1
		if (item.role == 5 && item.series == 1): depth_two = depth_two + 1
	assert_equal(2, depth_one)
	assert_equal(1, depth_two)
	mm_scene_free(scene)
	char* svg = fgaps_svg(d)
	free(svg)
	mm_document_free(d)
	fgaps_error(c"mindmap\n  A\nB", c"mindmap requires one root")
	fgaps_error(c"---\nconfig:\n  mindmap:\n    colorBy: rainbow\n---\nmindmap\nA\n", c"mindmap colorBy must be depth or branch")

char* fgaps_icon(mm_node* n):
	for mm_property* property in n.metadata:
		if (strcmp(property.key, c"icon") == 0): return property.value
	return 0

void test_treeview_icons_classes_and_config():
	char* source = c"treeView-beta\n├── src/\n│   ├── App.tsx :::highlight icon(logos:react) ## main component\n│   └── index.ts ## entry point\n├── notes.txt icon(none)\n└── package.json\n"
	mm_document* d = fgaps_parse(source)
	mm_node* app = d.nodes[1]
	assert_strings_equal(c"App.tsx", app.label)
	assert_strings_equal(c"main component", app.annotation)
	assert_strings_equal(c"logos:react", fgaps_icon(app))
	mm_node* notes = d.nodes[3]
	assert_strings_equal(c"", fgaps_icon(notes))
	mm_scene* scene = mm_render(d)
	int highlight = 0
	for mm_primitive* item in scene.items:
		if (item.kind == MM_BOX && (item.style.mask & 2) != 0 && item.style.stroke == 0xffc107): highlight = highlight + 1
	assert_equal(1, highlight)
	mm_scene_free(scene)
	char* svg = fgaps_svg(d)
	asserts(c"explicit icon drawn without showIcons", index_of(svg, c">R</text>") >= 0)
	asserts(c"description is italic", index_of(svg, c"font-style=\"italic\"") >= 0)
	free(svg)
	mm_document_free(d)
	# showIcons draws folder/file pictograms; filenameIcons maps by name.
	d = fgaps_parse(c"---\nconfig:\n  treeView:\n    showIcons: true\n    rowIndent: 40\n    lineThickness: 3\n    filenameIcons:\n      Dockerfile: docker\n  themeVariables:\n    treeView:\n      lineColor: '#00FF00'\n---\ntreeView-beta\n    src/\n        index.js\n        none.js icon(none)\n    Dockerfile\n")
	scene = mm_render(d)
	mm_bounds* root = scene.nodes[0]
	mm_bounds* child = scene.nodes[1]
	assert_equal(root.x + 40, child.x)
	int green = 0
	for mm_primitive* item in scene.items:
		if (item.kind == MM_LINE && (item.style.mask & 2) != 0 && item.style.stroke == 0x00ff00 && item.style.width == 3): green = green + 1
	assert_equal(4, green)
	mm_scene_free(scene)
	svg = fgaps_svg(d)
	asserts(c"mapped filename icon", index_of(svg, c">D</text>") >= 0)
	asserts(c"default folder and file pictograms", index_of(svg, c"<polygon") >= 0)
	free(svg)
	mm_document_free(d)
	fgaps_error(c"treeView-beta\nA icon(x) icon(y)", c"duplicate TreeView icon")
	fgaps_error(c"treeView-beta\nA :::bad!", c"invalid TreeView class name")
	fgaps_error(c"---\nconfig:\n  treeView:\n    showIcons: sometimes\n---\ntreeView-beta\nA\n", c"configuration value must be true or false")
	fgaps_prefixes(source)

void test_kanban_column_metadata_and_repeated_ids():
	char* source = c"kanban\n  todo[Todo]@{ assigned: 'team', label: 'To do' }\n    id3[Update DB]@{ ticket: MC-1 }\n  done[Done]\n    id3[Weird flickering]\n"
	mm_document* d = fgaps_parse(source)
	assert_equal(4, d.nodes.length)
	mm_node* todo = d.nodes[0]
	assert_strings_equal(c"To do", todo.label)
	assert_equal(1, todo.members.length)
	mm_node* repeat = d.nodes[3]
	assert_strings_equal(c"Weird flickering", repeat.label)
	assert_equal(2, repeat.parent)
	mm_property* written = repeat.metadata[0]
	assert_strings_equal(c"id3", written.value)
	mm_scene* scene = mm_render(d)
	mm_bounds* column = scene.nodes[0]
	mm_bounds* card = scene.nodes[1]
	asserts(c"cards start below column metadata", card.y >= column.y + 104)
	mm_scene_free(scene)
	char* svg = fgaps_svg(d)
	asserts(c"column metadata rendered", index_of(svg, c"assigned: team") >= 0 && index_of(svg, c">To do<") >= 0)
	free(svg)
	mm_document_free(d)
	fgaps_error(c"kanban\n  todo[Todo]@{ shape: circle }\n", c"unsupported Kanban metadata key")
	fgaps_prefixes(source)
