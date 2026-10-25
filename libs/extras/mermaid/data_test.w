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
		assert_equal(68, p.points.length)
		if (ribbons == 1): first_height = p.points[67] - p.points[1]
		last_height = p.points[67] - p.points[1]
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
	data_bad(c"venn-beta\nset A\nset B\nset C\nset D\nset E\nset F\nset G\nset H\nset I\n")

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

void test_data_numeric_xy_and_keyed_radar():
	mm_document* d = data_parse(c"xychart-beta\nx-axis \"Year\" 2020 --> 2022\ny-axis 0 --> 10\nline [2 \"Start\",5,8 \"End\"]\n")
	assert_equal(1, d.data.x_numeric)
	assert_equal(2020000, d.data.x_low)
	assert_equal(2022000, d.data.x_high)
	mm_scene* s = mm_render(d)
	int left = 0
	int right = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_CIRCLE && p.x == 137): left = 1
		if (p.kind == MM_CIRCLE && p.x == 737): right = 1
	asserts(c"numeric x range spans endpoints", left && right)
	char* svg = mm_svg(s)
	asserts(c"numeric x tick labels", index_of(svg, c">2021</text>") >= 0)
	asserts(c"XY point annotations", index_of(svg, c">Start</text>") >= 0 && index_of(svg, c">End</text>") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
	d = data_parse(c"radar-beta\naxis a,b,c\ncurve sample{c:3, a:1, b:2}\n")
	mm_data_item* curve = d.data.items[3]
	assert_equal(1000, curve.values[0])
	assert_equal(2000, curve.values[1])
	assert_equal(3000, curve.values[2])
	mm_document_free(d)
	d = data_parse(c"quadrantChart\nA: [.5, .25]\n")
	mm_document_free(d)
	data_bad(c"xychart-beta\nx-axis 3 --> 1\nline [1,2]\n")
	data_bad(c"xychart-beta\nx-axis [A,B]\nx-axis 1 --> 2\nline [1,2]\n")
	data_bad(c"radar-beta\naxis a,b,c\ncurve x{a:1,b:2}\n")
	data_bad(c"radar-beta\naxis a,b,c\ncurve x{a:1,b:2,c:3,a:1}\n")
	data_bad(c"radar-beta\naxis a,b,c\ncurve x{a:1,b:2,d:3}\n")

void test_data_entry_and_series_limits():
	string_builder* text = string_from(c"pie\n")
	for i in range(257):
		string_append_char(text, '"')
		string_append_int(text, i)
		string_append(text, c"\":1\n")
	data_bad(text.data)
	string_free(text)
	text = string_from(c"xychart-beta\nline [")
	for i in range(257):
		if (i != 0): string_append_char(text, ',')
		string_append_char(text, '1')
	string_append(text, c"]\n")
	data_bad(text.data)
	string_free(text)

void test_data_forward_radar_and_hyphenated_axes():
	mm_document* d = data_parse(c"radar-beta\ncurve first{c:3,a:1,b:2}\naxis a,b,c\ncurve second{2,3,4}\n")
	mm_data_item* curve = d.data.items[0]
	assert_equal(1000, curve.values[0])
	assert_equal(2000, curve.values[1])
	assert_equal(3000, curve.values[2])
	mm_scene* scene = mm_render(d)
	mm_scene_free(scene)
	mm_document_free(d)
	data_bad(c"radar-beta\ncurve first{a:1,b:2,d:3}\naxis a,b,c\n")
	data_bad(c"radar-beta\ncurve first{a:1,b:2,a:3}\naxis a,b,c\n")
	d = data_parse(c"quadrantChart\nx-axis Low-effort --> High-effort\ny-axis Short-term --> Long-term\nA: [0.5,0.5]\n")
	assert_strings_equal(c"Low-effort", d.data.x_label)
	assert_strings_equal(c"High-effort", d.data.x_end)
	assert_strings_equal(c"Short-term", d.data.y_label)
	assert_strings_equal(c"Long-term", d.data.y_end)
	mm_document_free(d)
	d = data_parse(c"quadrantChart\nx-axis Single-ended\ny-axis Bottom-label\n")
	assert_strings_equal(c"Single-ended", d.data.x_label)
	assert_strings_equal(c"", d.data.x_end)
	assert_strings_equal(c"Bottom-label", d.data.y_label)
	mm_document_free(d)
	data_bad(c"quadrantChart\nx-axis --> High\nA: [0,0]\n")

void test_data_multiline_sankey_csv_source_and_prefixes():
	char* source = c"sankey-beta\r\n\"First\r\nsecond, \"\"quoted\"\"\",Middle,2\r\nMiddle,\"Final\nline\",2\r\n"
	mm_document* d = data_parse(source)
	mm_data_item* item = d.data.items[0]
	assert_strings_equal(c"First\r\nsecond, \"quoted\"", item.id)
	item = d.data.items[1]
	assert_strings_equal(c"Final\nline", item.target)
	char* copy = mm_write(d)
	assert_strings_equal(source, copy)
	free(copy)
	mm_scene* scene = mm_render(d)
	mm_scene_free(scene)
	mm_document_free(d)
	for length in range(strlen(source) + 1):
		d = mm_parse(source, length)
		scene = mm_render(d)
		if (d.error != 0): asserts(c"invalid CSV prefix suppresses scene", scene == 0)
		mm_scene_free(scene)
		mm_document_free(d)
	data_bad(c"sankey-beta\n\"unterminated\nfield,B,2\n")
	data_bad(c"sankey-beta\n\"A\nB\",C,1\nC,\"A\nB\",1\n")

void test_data_squarified_treemap_geometry():
	mm_document* d = data_parse(c"treemap-beta\n\"A\":1\n\"B\":1\n\"C\":1\n\"D\":1\n\"E\":1\n\"F\":1\n")
	mm_scene* scene = mm_render(d)
	list[mm_primitive*] boxes = new list[mm_primitive*]
	int area = 0
	for mm_primitive* p in scene.items:
		if (p.kind != MM_BOX): continue
		boxes.push(p)
		int width = p.x2 - p.x
		int height = p.y2 - p.y
		asserts(c"equal treemap weights form near-square tiles", width >= 299 && width <= 301 && height >= 299 && height <= 301)
		asserts(c"treemap tile stays in plot", p.x >= 40 && p.y >= 80 && p.x2 <= 940 && p.y2 <= 680)
		area = area + width * height
	assert_equal(6, boxes.length)
	assert_equal(540000, area)
	for i in range(boxes.length):
		for j in range(i + 1, boxes.length):
			mm_primitive* a = boxes[i]
			mm_primitive* b = boxes[j]
			asserts(c"treemap tiles do not overlap", a.x2 <= b.x || b.x2 <= a.x || a.y2 <= b.y || b.y2 <= a.y)
	__w_list_free(cast(__w_list*, boxes))
	mm_scene_free(scene)
	mm_document_free(d)
	d = data_parse(c"treemap-beta\n\"Small\":1\n\"Large\":3\n")
	scene = mm_render(d)
	int first_area = 0
	int second_area = 0
	for mm_primitive* p in scene.items:
		if (p.kind != MM_BOX): continue
		if (first_area == 0): first_area = (p.x2 - p.x) * (p.y2 - p.y)
		else: second_area = (p.x2 - p.x) * (p.y2 - p.y)
	assert_equal(second_area * 3, first_area)
	mm_scene_free(scene)
	mm_document_free(d)

void test_data_dense_pie_legend_labels():
	string_builder* source = string_from(c"pie showData\n")
	for i in range(40):
		string_append(source, c"\"Category ")
		string_append_int(source, i)
		string_append(source, c"\": 1\n")
	mm_document* d = data_parse(source.data)
	mm_scene* scene = mm_render(d)
	int labels = 0
	int percentages = 0
	for mm_primitive* p in scene.items:
		if (p.kind != MM_TEXT): continue
		if (index_of(p.text, c"Category ") == 0):
			assert_equal(500, p.x)
			assert_equal(80 + labels * 26, p.y)
			labels = labels + 1
		if (strcmp(p.text, c"2.5% (value: 1)") == 0): percentages = percentages + 1
	assert_equal(40, labels)
	assert_equal(40, percentages)
	mm_scene_free(scene)
	mm_document_free(d)
	string_free(source)

void test_data_packet_configured_word_order():
	mm_document* d = data_parse(c"---\nconfig:\n  packet:\n    bitsPerRow: 16\n    bitOrder: descending\n---\npacket\n0-7: \"Data\"\n8-19: \"Rest\"\n")
	assert_equal(16, d.packet_bits)
	assert_equal(1, d.packet_msb)
	mm_scene* scene = mm_render(d)
	int boxes = 0
	for mm_primitive* p in scene.items:
		if (p.kind != MM_BOX): continue
		if (boxes == 0):
			assert_equal(252, p.x)
			assert_equal(444, p.x2)
			assert_equal(80, p.y)
		if (boxes == 1):
			assert_equal(60, p.x)
			assert_equal(252, p.x2)
		if (boxes == 2):
			assert_equal(348, p.x)
			assert_equal(444, p.x2)
			assert_equal(170, p.y)
		boxes = boxes + 1
	assert_equal(3, boxes)
	mm_scene_free(scene)
	mm_document_free(d)
	data_bad(c"---\nconfig:\n  packet:\n    bitsPerRow: 0\n---\npacket\n+1: \"A\"\n")
	data_bad(c"---\nconfig:\n  packet:\n    bitOrder: reverse\n---\npacket\n+1: \"A\"\n")

void test_data_series_colors_match_legend_keys():
	mm_document* d = data_parse(c"xychart-beta\nx-axis [A,B]\nbar \"First\" [2,3]\nline \"Second\" [1,4]\n")
	mm_scene* scene = mm_render(d)
	int blue_bars = 0
	int blue_key = 0
	int red_line = 0
	int red_key = 0
	for mm_primitive* p in scene.items:
		if (p.kind == MM_BOX && p.style.fill == 0x2563eb):
			if (p.y >= 560): blue_key = blue_key + 1
			else: blue_bars = blue_bars + 1
		if (p.kind == MM_LINE && p.style.stroke == 0xdc2626):
			if (p.y >= 560): red_key = red_key + 1
			else: red_line = red_line + 1
	assert_equal(2, blue_bars)
	assert_equal(1, blue_key)
	assert_equal(1, red_line)
	assert_equal(1, red_key)
	mm_scene_free(scene)
	mm_document_free(d)
	d = data_parse(c"pie\n\"First\": 1\n\"Second\": 3\n")
	scene = mm_render(d)
	int sectors = 0
	for mm_primitive* p in scene.items:
		if (p.kind != MM_POLYGON): continue
		assert_equal(mm_data_series_color(sectors), p.style.fill)
		assert_equal(250, p.points[0])
		assert_equal(260, p.points[1])
		sectors = sectors + 1
	assert_equal(2, sectors)
	mm_scene_free(scene)
	mm_document_free(d)

void test_data_sankey_curves_order_and_multiline_labels():
	mm_document* d = data_parse(c"sankey-beta\nA,D,1\nB,C,1\nA,C,100\nB,D,100\n")
	mm_scene* scene = mm_render(d)
	int cy = 0
	int dy = 0
	int bent = 0
	for mm_primitive* p in scene.items:
		if (p.kind == MM_TEXT && strcmp(p.text, c"C") == 0): cy = p.y
		if (p.kind == MM_TEXT && strcmp(p.text, c"D") == 0): dy = p.y
		if (p.kind != MM_POLYGON): continue
		assert_equal(68, p.points.length)
		# At a quarter of the x span a smoothstep boundary differs from a chord.
		int chord = p.points[1] + (p.points[33] - p.points[1]) / 4
		if (p.points[9] != chord): bent = 1
	asserts(c"weighted node order favors dominant uncrossed flows", cy < dy)
	asserts(c"Sankey boundaries bend between endpoints", bent)
	mm_scene_free(scene)
	mm_document_free(d)
	d = data_parse(c"sankey-beta\n\"First\r\nSecond\",End,1\n")
	scene = mm_render(d)
	int first_y = 0
	int second_y = 0
	for mm_primitive* p in scene.items:
		if (p.kind != MM_TEXT): continue
		if (strcmp(p.text, c"First") == 0): first_y = p.y
		if (strcmp(p.text, c"Second") == 0): second_y = p.y
		asserts(c"multiline CSV is split into display lines", index_of(p.text, c"\n") < 0 && index_of(p.text, c"\r") < 0)
	asserts(c"multiline endpoint label present", first_y > 0)
	assert_equal(first_y + 18, second_y)
	mm_scene_free(scene)
	mm_document_free(d)

void test_data_quadrant_styles_classes_and_precedence():
	mm_document* d = data_parse(c"quadrantChart\nDirect: [0.25,0.75] radius: 12, color: #ff3300, stroke-color: #00ff00, stroke-width: 5px\nInherited:::large: [0.5,0.5]\nOverride:::large: [0.75,0.25] radius: 6, color: #0000ff\nclassDef large color: #109060, radius: 10, stroke-color: #310085, stroke-width: 3px\n")
	mm_scene* scene = mm_render(d)
	int points = 0
	for mm_primitive* p in scene.items:
		if (p.kind != MM_CIRCLE): continue
		if (points == 0):
			assert_equal(24, p.x2 - p.x)
			assert_equal(0xff3300, p.style.fill)
			assert_equal(0x00ff00, p.style.stroke)
			assert_equal(5, p.style.width)
		if (points == 1):
			assert_equal(20, p.x2 - p.x)
			assert_equal(0x109060, p.style.fill)
			assert_equal(0x310085, p.style.stroke)
			assert_equal(3, p.style.width)
		if (points == 2):
			assert_equal(12, p.x2 - p.x)
			assert_equal(0x0000ff, p.style.fill)
			assert_equal(0x310085, p.style.stroke)
			assert_equal(3, p.style.width)
		points = points + 1
	assert_equal(3, points)
	char* svg = mm_svg(scene)
	asserts(c"point style exported", index_of(svg, c"fill=\"#ff3300\" stroke=\"#00ff00\" stroke-width=\"5\"") >= 0)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(d)
	data_bad(c"quadrantChart\nA:::missing: [0.5,0.5]\n")
	data_bad(c"quadrantChart\nA: [0.5,0.5] radius: 0\n")
	data_bad(c"quadrantChart\nA: [0.5,0.5] radius: 65\n")
	data_bad(c"quadrantChart\nA: [0.5,0.5] radius: 1.5\n")
	data_bad(c"quadrantChart\nA: [0.5,0.5] color: invalid\n")
	data_bad(c"quadrantChart\nA: [0.5,0.5] radius: 5,\n")
	data_bad(c"quadrantChart\nA: [0.5,0.5] font-size: 12\n")
	data_bad(c"quadrantChart\nclassDef empty\n")
	data_bad(c"quadrantChart\nclassDef c color: red\nclassDef c color: blue\n")

void test_data_venn_sizes_and_text_nodes():
	mm_document* d = data_parse(c"venn-beta\nset A[\"Alpha\"]:20\n  text A1[\"First note\"]\nset B[\"Beta\"]:5\n  text B1[\"Second note\"]\nunion A,B[\"Shared\"]:2\n  text AB1[\"Shared note\"]\n")
	mm_scene* scene = mm_render(d)
	int lines = 0
	int first_left = 100000
	int first_right = 0
	int second_left = 100000
	int second_right = 0
	int text_count = 0
	for mm_primitive* p in scene.items:
		if (p.kind == MM_TEXT && index_of(p.text, c"note") >= 0): text_count = text_count + 1
		# Sets are filled disc polygons sampled from their circles.
		if (p.kind != MM_POLYGON): continue
		for k in range(0, p.points.length, 2):
			int x = p.points[k]
			if (lines == 0):
				if (x < first_left): first_left = x
				if (x > first_right): first_right = x
			else:
				if (x < second_left): second_left = x
				if (x > second_right): second_right = x
		lines = lines + 1
	assert_equal(2, lines)
	assert_equal(3, text_count)
	assert_equal(340, first_right - first_left)
	assert_equal(170, second_right - second_left)
	int first_center = (first_left + first_right) / 2
	int second_center = (second_left + second_right) / 2
	float area = mm_data_venn_overlap(170.0, 85.0, cast(float, second_center - first_center))
	float expected = 3.14159265 * 170.0 * 170.0 / 10.0
	asserts(c"Venn intersection area follows explicit size within pixel rounding", area > expected * 0.97 && area < expected * 1.03)
	char* svg = mm_svg(scene)
	asserts(c"Venn text nodes exported", index_of(svg, c">Shared note</text>") >= 0)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(d)
	data_bad(c"venn-beta\ntext A[\"No parent\"]\n")
	data_bad(c"venn-beta\nset A:0\n")
	data_bad(c"venn-beta\nset A:2\nset B:1\nunion A,B[\"Too large\"]:3\n")
	data_bad(c"venn-beta\nset A\n  text A[\"Duplicate\"]\n")

void test_data_new_syntax_prefixes():
	list[char*] sources = list[char*]{c"quadrantChart\nA:::c: [0.5,0.5] color:red, radius:12\nclassDef c stroke-width:3px\n", c"venn-beta\nset A:20\n  text note[\"Details\"]\nset B:12\nunion A,B[\"Overlap\"]:3\n", c"radar-beta\ncurve first{c:3,a:1,b:2}\naxis a,b,c\n"}
	for char* source in sources:
		for length in range(strlen(source) + 1):
			mm_document* d = mm_parse(source, length)
			mm_scene* scene = mm_render(d)
			if (d.error != 0): asserts(c"invalid new data prefix suppresses rendering", scene == 0)
			mm_scene_free(scene)
			mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))

void test_data_venn_long_text_and_duplicate_regions():
	string_builder* source = string_from(c"venn-beta\nset A\n  text note[\"")
	for i in range(200): string_append_char(source, 'x')
	string_append(source, c"\"]\n")
	mm_document* d = data_parse(source.data)
	mm_scene* scene = mm_render(d)
	int found = 0
	for mm_primitive* p in scene.items:
		asserts(c"Venn content remains inside positive viewport", p.x >= 0 && p.y >= 0)
		if (p.kind == MM_TEXT):
			asserts(c"complete text fits viewport", p.x + strlen(p.text) * 8 <= scene.width)
			if (strlen(p.text) == 200):
				found = 1
				assert_equal(40, p.x)
	asserts(c"long Venn text retained", found)
	mm_scene_free(scene)
	mm_document_free(d)
	string_free(source)
	data_bad(c"venn-beta\nset A:10\nset B:10\nunion A,B[\"First\"]:1\nunion A,B[\"Second\"]:9\n")
	data_bad(c"venn-beta\nset A\nset B\nunion A,B[\"First\"]\nunion B,A[\"Second\"]\n")

void test_data_treemap_subpixel_leaves_keep_complete_key():
	mm_document* d = data_parse(c"treemap-beta\n\"Huge\":1000000\n\"Small\":0.001\n\"Small2\":0.001\n")
	mm_scene* scene = mm_render(d)
	int area = 0
	int keys = 0
	int small_values = 0
	for mm_primitive* p in scene.items:
		if (p.kind == MM_BOX):
			asserts(c"subpixel weights never create inverted cells", p.x2 >= p.x && p.y2 >= p.y)
			area = area + (p.x2 - p.x) * (p.y2 - p.y)
		if (p.kind == MM_TEXT && p.x >= 980):
			if (strcmp(p.text, c"Huge") == 0 || strcmp(p.text, c"Small") == 0 || strcmp(p.text, c"Small2") == 0): keys = keys + 1
			if (strcmp(p.text, c"0.001") == 0): small_values = small_values + 1
	assert_equal(540000, area)
	assert_equal(3, keys)
	assert_equal(2, small_values)
	mm_scene_free(scene)
	mm_document_free(d)
