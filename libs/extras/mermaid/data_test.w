# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* data_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"data diagram parses", d.error == 0)
	return d

void data_bad(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"invalid data diagram has diagnostic", d.error != 0)
	asserts(c"invalid data suppresses scene", mm_render(d) == 0)
	asserts(c"diagnostic offset valid", d.error_offset >= 0 && d.error_offset <= d.length)
	mm_document_free(d)

void test_data_pie_proportions_and_source():
	char* source = c"pie showData title Budget\r\n\"Food\": 1.25\r\n\"Rent\": 3.75\r\n"
	mm_document* d = data_parse(source)
	assert_equal(MM_PIE, d.kind)
	assert_equal(1, d.data.show_data)
	mm_data_item* item = d.data.items[0]
	assert_equal(1250, item.a)
	char* copy = mm_write(d)
	assert_strings_equal(source, copy)
	free(copy)
	mm_scene* scene = mm_render(d)
	mm_document_free(d)
	char* svg = mm_svg(scene)
	asserts(c"quarter fraction label", index_of(svg, c">25</text>") >= 0)
	asserts(c"three quarter fraction label", index_of(svg, c">75</text>") >= 0)
	asserts(c"owned source title", index_of(svg, c">Budget</text>") >= 0)
	free(svg)
	mm_scene_free(scene)
	data_bad(c"pie\n\"a\": 0\n")
	data_bad(c"pie\n\"a\": -2\n")
	data_bad(c"pie\n\"a\": 1\n\"a\": 2\n")

void test_data_quadrant_coordinates():
	mm_document* d = data_parse(c"quadrantChart\nx-axis Low --> High\ny-axis Small --> Large\nquadrant-1 Do first\nA: [0.25, 0.75]\nB: [1, 0]\n")
	mm_scene* s = mm_render(d)
	int found = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_CIRCLE && p.x == 266 && p.y == 201): found = 1
	asserts(c"quadrant numeric position", found)
	mm_scene_free(s)
	mm_document_free(d)
	data_bad(c"quadrantChart\nA: [1.1,0]\n")
	data_bad(c"quadrantChart\nA: [1]\n")

void test_data_xy_series_and_negative_baseline():
	mm_document* d = data_parse(c"xychart-beta\ntitle Sales\nx-axis [Jan, Feb, Mar]\ny-axis \"Sales\" -10 --> 20\nbar [-10,0,20]\nline [5,10,15]\n")
	assert_equal(-10000, d.data.low)
	assert_equal(20000, d.data.high)
	mm_scene* s = mm_render(d)
	int boxes = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_BOX):
			boxes = boxes + 1
			asserts(c"bars nonnegative geometry", p.x2 >= p.x && p.y2 >= p.y)
	assert_equal(3, boxes)
	mm_scene_free(s)
	mm_document_free(d)
	d = data_parse(c"xychart-beta horizontal\nx-axis [A,B]\nbar [2,4]\n")
	assert_equal(1, d.data.horizontal)
	s = mm_render(d)
	mm_scene_free(s)
	mm_document_free(d)
	data_bad(c"xychart-beta\nx-axis [A,B]\nbar [2]\n")
	data_bad(c"xychart-beta\ny-axis 0 --> 1\nline [2]\n")
	data_bad(c"xychart-beta\nline [2,3]\nbar [1]\n")

void test_data_radar_axes_and_graticule():
	mm_document* d = data_parse(c"radar-beta\naxis a[\"Math\"], b, c\ncurve one[\"Alice\"]{1,2,3}, two{3,2,1}\nmin 0\nmax 5\nticks 4\ngraticule polygon\nshowLegend true\n")
	assert_equal(5, d.data.items.length)
	assert_equal(5000, d.data.high)
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"axis labels render", index_of(svg, c">Math</text>") >= 0)
	asserts(c"curve legend renders", index_of(svg, c">Alice</text>") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
	data_bad(c"radar-beta\naxis a,b\ncurve c{1,2}\n")
	data_bad(c"radar-beta\naxis a,b,c\ncurve d{1,2}\n")
	data_bad(c"radar-beta\naxis a,a,c\ncurve d{1,2,3}\n")

void test_data_sankey_csv_and_flow_width():
	mm_document* d = data_parse(c"sankey-beta\n\"Source, one\",\"Mid \"\"quoted\"\"\",2\n\"Mid \"\"quoted\"\"\",End,2\nOther,End,1\n")
	assert_equal(4, d.nodes.length)
	mm_data_item* item = d.data.items[0]
	assert_strings_equal(c"Mid \"quoted\"", item.target)
	mm_scene* s = mm_render(d)
	int ribbons = 0
	int first_height = 0
	int last_height = 0
	for mm_primitive* p in s.items:
		if (p.kind != MM_POLYGON): continue
		ribbons = ribbons + 1
		assert_equal(8, p.points.length)
		if (ribbons == 1): first_height = p.points[7] - p.points[1]
		last_height = p.points[7] - p.points[1]
	assert_equal(3, ribbons)
	asserts(c"ribbons proportional to flow", first_height >= last_height * 2 - 1 && first_height <= last_height * 2 + 1)
	mm_scene_free(s)
	mm_document_free(d)
	data_bad(c"sankey-beta\nA,B,1\nB,A,1\n")
	data_bad(c"sankey-beta\nA,A,1\n")
	data_bad(c"sankey-beta\nA,B,-1\n")

void test_data_treemap_hierarchy_and_area():
	mm_document* d = data_parse(c"treemap-beta\n\"Group\"\n  \"A\": 1\n  \"B\": 3\n\"Other\": 2\n")
	mm_data_item* leaf = d.data.items[1]
	assert_equal(0, leaf.parent)
	assert_equal(1000, leaf.a)
	asserts(c"group aggregate weight", mm_data_tree_weight(d.data, 0) == 4000.0)
	mm_scene* s = mm_render(d)
	int boxes = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_BOX): boxes = boxes + 1
	assert_equal(4, boxes)
	mm_scene_free(s)
	mm_document_free(d)
	data_bad(c"treemap-beta\n\"Empty\"\n")
	data_bad(c"treemap-beta\n\"Leaf\": 1\n  \"Child\": 2\n")

void test_data_venn_regions_and_aliases():
	mm_document* d = data_parse(c"venn-beta\nset A[\"Alpha\"]\nset B\nset C\nunion A,B[\"AB\"]\nunion A,B,C[\"All\"]\n")
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"set label", index_of(svg, c">Alpha</text>") >= 0)
	asserts(c"triple intersection label", index_of(svg, c">All</text>") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
	data_bad(c"venn-beta\nset A\nunion A,B[\"x\"]\n")
	data_bad(c"venn-beta\nset A\nunion A,A[\"x\"]\n")
	data_bad(c"venn-beta\nset A\nset B\nset C\nset D\n")

void test_data_packet_ranges_and_wrapping():
	mm_document* d = data_parse(c"packet-beta\n+16: \"Source\"\n+16: \"Destination\"\n32-79: \"Payload\"\n")
	mm_data_item* item = d.data.items[1]
	assert_equal(16, item.a)
	assert_equal(31, item.b)
	mm_scene* s = mm_render(d)
	int boxes = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_BOX):
			boxes = boxes + 1
			asserts(c"field clipped to word", p.x >= 60 && p.x2 <= 828)
	assert_equal(4, boxes)
	mm_scene_free(s)
	mm_document_free(d)
	data_bad(c"packet\n0-7: \"A\"\n7-9: \"B\"\n")
	data_bad(c"packet\n+0: \"A\"\n")
	data_bad(c"packet\n0-4096: \"A\"\n")

void test_data_numeric_bounds_and_escape():
	data_bad(c"pie\n\"x\": 1000000.001\n")
	data_bad(c"pie\n\"x\": 1234567890123456789\n")
	data_bad(c"pie\n\"x\": 1.0001\n")
	data_bad(c"pie\n\"x\": NaN\n")
	data_bad(c"pie\n\"x\": 1e2\n")
	mm_document* d = data_parse(c"pie\n\"<script>&\": 1000000\n")
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"labels XML escaped", index_of(svg, c"&lt;script&gt;&amp;") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_data_truncation_and_edit_ownership():
	list[char*] sources = list[char*]{c"pie showData title T\n\"a\": 1.25\n", c"quadrantChart\nA: [0.2, 0.4]\n", c"xychart-beta\nx-axis [A,B]\nbar [1,2]\n", c"radar-beta\naxis a,b,c\ncurve x{1,2,3}\n", c"sankey-beta\nA,B,2\n", c"treemap-beta\n\"G\"\n  \"L\": 2\n", c"venn-beta\nset A\nset B\nunion A,B[\"AB\"]\n", c"packet\n+16: \"A\"\n"}
	for char* source in sources:
		for length in range(strlen(source) + 1):
			mm_document* d = mm_parse(source, length)
			mm_scene* s = mm_render(d)
			if (d.error != 0): asserts(c"invalid prefix has no scene", s == 0)
			else: asserts(c"valid prefix renders", s != 0)
			mm_scene_free(s)
			mm_document_free(d)
		mm_document* original = data_parse(source)
		mm_document* edited = mm_edit(original, 0, original.length, c"pie\n\"Edit\": 2\n", 14)
		asserts(c"source edit reparses", edited != 0 && edited.error == 0)
		assert_strings_equal(source, original.source)
		mm_document_free(edited)
		mm_document_free(original)
	__w_list_free(cast(__w_list*, sources))

void test_mermaid_data_envelope_metadata_and_title_precedence():
	char* source = c"# Report\n```mermaid\n---\ntitle: Overview\n---\npie title Old title\naccTitle: Pie & chart\naccDescr: Two categories\n\"A\": 1\n\"B\": 2\n```\n"
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"data envelope parses", d.error == 0)
	assert_strings_equal(c"Overview", d.title)
	mm_scene* s = mm_render(d)
	int count = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && strcmp(p.text, c"Overview") == 0): count = count + 1
		asserts(c"frontmatter overrides chart title", strcmp(p.text, c"Old title") != 0)
	assert_equal(1, count)
	char* svg = mm_svg(s)
	asserts(c"accessible title escaped", index_of(svg, c"Pie &amp; chart") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_data_venn_only_declared_overlaps():
	mm_document* d = data_parse(c"venn-beta\nset A\nset B\n")
	mm_scene* s = mm_render(d)
	int gap_left = 0
	int gap_right = 0
	for mm_primitive* p in s.items:
		if (p.kind != MM_LINE): continue
		if (p.x > 420 && p.x < 480): gap_left = gap_left + 1
		if (p.x2 > 420 && p.x2 < 480): gap_right = gap_right + 1
	assert_equal(0, gap_left)
	assert_equal(0, gap_right)
	mm_scene_free(s)
	mm_document_free(d)
	d = data_parse(c"venn-beta\nset A\nset B\nset C\nunion A,B[\"AB\"]\nunion B,C[\"BC\"]\n")
	s = mm_render(d)
	int ab_x = 0
	int bc_x = 0
	for mm_primitive* p in s.items:
		if (strcmp(p.text, c"AB") == 0): ab_x = p.x
		if (strcmp(p.text, c"BC") == 0): bc_x = p.x
	asserts(c"chain intersections occupy distinct pairwise lenses", ab_x != bc_x)
	mm_scene_free(s)
	mm_document_free(d)
	d = data_parse(c"sankey-beta\ntitle source,Destination,2\n")
	mm_data_item* item = d.data.items[0]
	assert_strings_equal(c"title source", item.id)
	mm_document_free(d)
