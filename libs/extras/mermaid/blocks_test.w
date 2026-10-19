# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

void test_blocks_grid_spans_space_and_composites():
	char* source = c"block-beta\ncolumns 3\na[First] b[Wide]:2\nspace c\nblock:group\ncolumns 1\nx y\nend\na --> c\n"
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"block grid parses", d.error == 0)
	assert_equal(8, d.nodes.length)
	mm_scene* s = mm_render(d)
	mm_bounds* a = s.nodes[1]
	mm_bounds* b = s.nodes[2]
	mm_bounds* c = s.nodes[4]
	mm_bounds* group = s.nodes[5]
	mm_bounds* x = s.nodes[6]
	mm_bounds* y = s.nodes[7]
	asserts(c"span consumes two columns", b.w > a.w * 2 && b.y == a.y)
	asserts(c"space advances grid column", c.y > a.y && c.x > a.x)
	asserts(c"nested layout contained", x.x > group.x && y.y + y.h < group.y + group.h)
	asserts(c"nested columns respected", y.y > x.y)
	char* saved = mm_write(d)
	assert_strings_equal(source, saved)
	free(saved)
	mm_scene_free(s)
	mm_document_free(d)

void test_blocks_invalid_and_truncated_grids():
	list[char*] bad = list[char*]{c"block\ncolumns 0", c"block\ncolumns 65", c"block\ncolumns 2\na:3", c"block\nblock:g\na", c"block\nend", c"block\na{diamond", c"block\ncolumns 1\ncolumns 2", c"block\na<[\"Go\"]>(sideways)", c"block\na<[\"Go\"]>", c"block\na<[\"Go\"]", c"block\na(((Twice))", c"block\na[(Disk]", c"block\na[/Lean]", c"block\na[[Sub]", c"block\nstyle missing fill:#f00", c"block\na:::undefined", c"block\na\nstyle a colour:red", c"block\nblock:g\nend\nblock:g\nend"}
	for char* text in bad:
		mm_document* d = mm_parse(text, strlen(text))
		asserts(c"invalid grid rejected", d.error != 0)
		asserts(c"invalid grid no preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))
	char* text = c"block\ncolumns 2\na[\"First\"] b:1\nblock:g\nx\nend\na --> g\n"
	for length in range(strlen(text) + 1):
		mm_document* d = mm_parse(text, length)
		mm_scene* s = mm_render(d)
		asserts(c"prefix parse/render consistent", (d.error == 0 && s != 0) || (d.error != 0 && s == 0))
		mm_scene_free(s)
		mm_document_free(d)

void test_blocks_shapes_arrows_and_styles():
	char* source = c"block-beta\ncolumns 4\nr[\"Rect\"] o(\"Round\") st([\"Stadium\"]) sub[[\"Subroutine\"]]\ndb[(\"Database\")] c((\"Circle\")) dc(((\"Double\"))) asym>\"Flag\"]\nrh{\"Decide\"} hex{{\"Prepare\"}} pl[/\"Lean\"/] tr[/\"Trap\"\\]\nright<[\"Go\"]>(right) left<[\"Back\"]>(left) up<[\"Rise\"]>(up) both<[\"Swap\"]>(x)\ndown<[\"Fall\"]>(down) vert<[\"Sync\"]>(y):2 block:grp\nn\nend\nclassDef hot fill:#ff0000,stroke:#990000,color:#ffffff\nclass r,grp hot\nstyle db fill:#00ff00,stroke-width:4px\nhex:::hot\nr --> db\nlinkStyle 0 stroke:#0000ff\n"
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"block shapes parse", d.error == 0)
	list[char*] ids = list[char*]{c"r", c"o", c"st", c"sub", c"db", c"c", c"dc", c"asym", c"rh", c"hex", c"pl", c"tr", c"right", c"left", c"up", c"both", c"down", c"vert"}
	list[int] shapes = list[int]{0, 1, 21, 22, MM_BLOCK_CYLINDER, 2, MM_BLOCK_DOUBLE_CIRCLE, MM_BLOCK_ASYMMETRIC, 3, 23, 24, 26, MM_BLOCK_ARROW, MM_BLOCK_ARROW, MM_BLOCK_ARROW, MM_BLOCK_ARROW, MM_BLOCK_ARROW, MM_BLOCK_ARROW}
	for i in range(ids.length):
		int index = mm_find_node(d, ids[i])
		asserts(c"shape node exists", index > 0)
		mm_node* n = d.nodes[index]
		assert_equal(shapes[i], n.shape)
	mm_node* db = d.nodes[mm_find_node(d, c"db")]
	assert_strings_equal(c"Database", db.label)
	mm_node* up = d.nodes[mm_find_node(d, c"up")]
	assert_strings_equal(c"up", up.direction)
	assert_strings_equal(c"Rise", up.label)
	mm_node* vert = d.nodes[mm_find_node(d, c"vert")]
	assert_strings_equal(c"y", vert.direction)
	assert_equal(2, vert.value_x)
	mm_node* hex = d.nodes[mm_find_node(d, c"hex")]
	assert_strings_equal(c"hot", hex.style_classes)
	mm_scene* s = mm_render(d)
	mm_bounds* right = s.nodes[mm_find_node(d, c"right")]
	mm_bounds* down = s.nodes[mm_find_node(d, c"down")]
	asserts(c"vertical arrows are taller", down.h > right.h)
	int polygons = 0
	int red = 0
	int green = 0
	int stadium = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_POLYGON):
			polygons = polygons + 1
			asserts(c"polygon has points", p.points.length >= 8)
		if (p.kind == MM_BOX && p.dashed == 3): stadium = stadium + 1
		if ((p.style.mask & 1) && p.style.fill == 0xff0000): red = red + 1
		if ((p.style.mask & 9) == 9 && p.style.fill == 0x00ff00 && p.style.width == 4): green = green + 1
	# rhombus, hexagon, 2 slanted, asymmetric, 6 arrows and the cylinder outline.
	assert_equal(12, polygons)
	assert_equal(1, stadium)
	asserts(c"class styles applied to block, composite and inline class", red >= 3)
	asserts(c"style statement applied to cylinder", green >= 1)
	int blue = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_LINE && (p.style.mask & 2) && p.style.stroke == 0x0000ff): blue = blue + 1
	assert_equal(3, blue)
	char* svg = mm_svg(s)
	asserts(c"styled fill exported", index_of(svg, c"fill=\"#ff0000\"") >= 0)
	asserts(c"arrow label exported", index_of(svg, c">Swap<") >= 0)
	free(svg)
	char* saved = mm_write(d)
	assert_strings_equal(source, saved)
	free(saved)
	mm_scene_free(s)
	mm_document_free(d)
	__w_list_free(cast(__w_list*, ids))
	__w_list_free(cast(__w_list*, shapes))
	for length in range(strlen(source) + 1):
		mm_document* prefix = mm_parse(source, length)
		mm_scene* scene = mm_render(prefix)
		asserts(c"shape prefix parse/render consistent", (prefix.error == 0 && scene != 0) || (prefix.error != 0 && scene == 0))
		mm_scene_free(scene)
		mm_document_free(prefix)
	char* text = c"block\na<[\"Go\"]>(sideways)\n"
	mm_document* bad = mm_parse(text, strlen(text))
	assert_strings_equal(c"expected block arrow direction right, left, up, down, x or y", bad.error)
	mm_document_free(bad)
	text = c"block\nstyle missing fill:#f00\n"
	bad = mm_parse(text, strlen(text))
	assert_strings_equal(c"style references undeclared block", bad.error)
	mm_document_free(bad)

void test_blocks_large_label_dimensions_stay_bounded():
	string_builder* source = string_from(c"block\ncolumns 64\na[\"")
	for i in range(100000): string_append_char(source, 'X')
	string_append(source, c"\"]\n")
	for i in range(100):
		string_append(source, c"n")
		string_append_int(source, i)
		string_append_char(source, ' ')
	mm_document* d = mm_parse(source.data, source.length)
	asserts(c"large bounded grid parses", d.error == 0)
	mm_scene* s = mm_render(d)
	asserts(c"one long label does not multiply across columns", s.width > 800000 && s.width < 1000000)
	asserts(c"grid height bounded", s.height > 0 && s.height < 1000)
	mm_scene_free(s)
	mm_document_free(d)
	string_free(source)
