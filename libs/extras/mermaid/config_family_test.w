# wbuild: x64
# Per-family configuration: each supported option is parsed, stored and
# changes the rendered scene (and SVG); deliberately unsupported options
# are ignored and leave the output unchanged.
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_scene* fam_scene(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0):
		println2(source)
		println2(d.error)
	asserts(c"configured diagram parses", d.error == 0)
	mm_scene* s = mm_render(d)
	asserts(c"configured diagram renders", s != 0)
	mm_document_free(d)
	return s

void fam_reject(char* source, char* message):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error == 0): println2(source)
	asserts(c"configuration diagnosed", d.error != 0)
	if (d.error != 0): assert_strings_equal(message, d.error)
	mm_document_free(d)

# Source with a %%{init: CONFIG}%% directive before BODY.
char* fam_with(char* config, char* body):
	string_builder* s = string_from(c"%%{init: ")
	string_append(s, config)
	string_append(s, c"}%%\n")
	string_append(s, body)
	char* result = s.data
	free(s)
	return result

mm_scene* fam_configured(char* config, char* body):
	char* source = fam_with(config, body)
	mm_scene* s = fam_scene(source)
	free(source)
	return s

int fam_texts(mm_scene* s, char* text):
	int count = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && strcmp(p.text, text) == 0): count = count + 1
	return count

mm_primitive* fam_text(mm_scene* s, char* text):
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && strcmp(p.text, text) == 0): return p
	asserts(c"text primitive present", 0)
	return s.items[0]

int fam_kind(mm_scene* s, int kind, int dashed):
	int count = 0
	for mm_primitive* p in s.items:
		if (p.kind == kind && (dashed < 0 || p.dashed == dashed)): count = count + 1
	return count

int fam_svg_count(mm_scene* s, char* needle):
	char* svg = mm_svg(s)
	int found = count(svg, needle)
	free(svg)
	return found

void test_sequence_configuration():
	char* body = c"sequenceDiagram\nA->>B: hi\nactivate B\nB->>A: ok\ndeactivate B\n"
	mm_scene* plain = fam_scene(body)
	mm_bounds* a = plain.nodes[0]
	mm_bounds* b = plain.nodes[1]
	assert_equal(40, b.x - (a.x + a.w))
	assert_equal(80, a.x)
	assert_equal(160, a.w)
	assert_equal(55, a.h)
	assert_equal(1, fam_texts(plain, c"A"))
	mm_scene* s = fam_configured(c"{'sequence': {'actorMargin': 90, 'width': 300, 'height': 70, 'diagramMarginX': 120}}", body)
	a = s.nodes[0]
	b = s.nodes[1]
	assert_equal(90, b.x - (a.x + a.w))
	assert_equal(120, a.x)
	assert_equal(300, a.w)
	assert_equal(70, a.h)
	mm_scene_free(s)
	# mirrorActors repeats each participant below the lifelines (also in SVG).
	s = fam_configured(c"{'sequence': {'mirrorActors': true}}", body)
	assert_equal(2, fam_texts(s, c"A"))
	assert_equal(2, fam_texts(s, c"B"))
	assert_equal(2 * fam_svg_count(plain, c">A</text>"), fam_svg_count(s, c">A</text>"))
	mm_scene_free(s)
	# showSequenceNumbers numbers messages like autonumber.
	s = fam_configured(c"{'sequence': {'showSequenceNumbers': true}}", body)
	assert_equal(1, fam_texts(s, c"1. hi"))
	assert_equal(1, fam_texts(s, c"2. ok"))
	mm_scene_free(s)
	# messageAlign places the label at the left, center or right of the arrow.
	mm_primitive* center = fam_text(plain, c"hi")
	s = fam_configured(c"{'sequence': {'messageAlign': 'left'}}", body)
	mm_primitive* left = fam_text(s, c"hi")
	asserts(c"left aligned label", left.x < center.x)
	mm_bounds* first_lane = plain.nodes[0]
	assert_equal(first_lane.x + first_lane.w / 2 + 10, left.x)
	mm_scene_free(s)
	s = fam_configured(c"{'sequence': {'messageAlign': 'right'}}", body)
	mm_primitive* right = fam_text(s, c"hi")
	asserts(c"right aligned label", right.x > center.x)
	mm_scene_free(s)
	# activationWidth sets the activation bar width.
	int bars = 0
	for mm_primitive* p in plain.items:
		if (p.kind == MM_BOX && p.x2 - p.x == 12): bars = bars + 1
	assert_equal(1, bars)
	s = fam_configured(c"{'sequence': {'activationWidth': 20}}", body)
	bars = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_BOX && p.x2 - p.x == 20): bars = bars + 1
	assert_equal(1, bars)
	mm_scene_free(s)
	mm_scene_free(plain)
	# wrap (sequence.wrap, the global wrap key or %%{wrap}%%) breaks long labels.
	char* long_body = c"sequenceDiagram\nA->>B: one two three four five six seven eight nine ten eleven twelve thirteen\n"
	plain = fam_scene(long_body)
	assert_equal(1, fam_texts(plain, c"one two three four five six seven eight nine ten eleven twelve thirteen"))
	list[char*] wrapped = list[char*]{c"%%{init: {'sequence': {'wrap': true}}}%%\n", c"%%{init: {'wrap': true}}%%\n", c"%%{wrap}%%\n", c"---\nconfig:\n  wrap: true\n---\n"}
	for char* prefix in wrapped:
		string_builder* source = string_from(prefix)
		string_append(source, long_body)
		s = fam_scene(source.data)
		assert_equal(0, fam_texts(s, c"one two three four five six seven eight nine ten eleven twelve thirteen"))
		asserts(c"wrapped label lines", fam_kind(s, MM_TEXT, -1) > fam_kind(plain, MM_TEXT, -1))
		mm_bounds* lane = s.nodes[0]
		mm_bounds* wide = plain.nodes[0]
		asserts(c"wrapped lane is narrower", lane.w < wide.w)
		mm_scene_free(s)
		string_free(source)
	__w_list_free(cast(__w_list*, wrapped))
	mm_scene_free(plain)
	fam_reject(c"%%{init: {'sequence': {'height': 200}}}%%\nsequenceDiagram\nA->>B: x\n", c"sequence.height must be an integer from 20 to 75")

void test_gantt_configuration():
	char* body = c"gantt\ndateFormat YYYY-MM-DD\nsection S\nA : a1, 2024-01-01, 10d\nB : b1, 2024-01-15, 10d\nsection T\nC : 2024-02-10, 20d\n"
	mm_scene* plain = fam_scene(body)
	mm_bounds* first = plain.nodes[0]
	mm_bounds* second = plain.nodes[1]
	assert_equal(30, first.h)
	assert_equal(85, second.y - first.y)
	assert_equal(180, first.x)
	mm_scene* s = fam_configured(c"{'gantt': {'barHeight': 24, 'barGap': 10, 'leftPadding': 300}}", body)
	first = s.nodes[0]
	second = s.nodes[1]
	assert_equal(24, first.h)
	assert_equal(34, second.y - first.y)
	assert_equal(300, first.x)
	mm_scene_free(s)
	# Compact display packs non-overlapping tasks of a section into one row.
	char* compact = c"---\ndisplayMode: compact\n---\ngantt\ndateFormat YYYY-MM-DD\nsection S\nA : a1, 2024-01-01, 10d\nB : b1, 2024-01-15, 10d\nsection T\nC : 2024-02-10, 20d\n"
	s = fam_scene(compact)
	first = s.nodes[0]
	second = s.nodes[1]
	mm_bounds* third = s.nodes[2]
	assert_equal(first.y, second.y)
	asserts(c"next section on a new row", third.y > second.y)
	mm_primitive* label = fam_text(s, c"A")
	assert_equal(first.x + 4, label.x)
	mm_scene_free(s)
	s = fam_configured(c"{'gantt': {'displayMode': 'compact'}}", body)
	first = s.nodes[0]
	second = s.nodes[1]
	assert_equal(first.y, second.y)
	mm_scene_free(s)
	# tickInterval with weekday alignment, calendar months and axis formats.
	s = fam_configured(c"{'gantt': {'tickInterval': '1week'}}", body)
	assert_equal(1, fam_texts(s, c"2024-01-07"))
	assert_equal(1, fam_texts(s, c"2024-01-14"))
	assert_equal(1, fam_texts(s, c"2024-02-25"))
	assert_equal(0, fam_texts(s, c"2024-01-08"))
	mm_scene_free(s)
	s = fam_configured(c"{'gantt': {'tickInterval': '1week', 'weekday': 'monday'}}", body)
	assert_equal(1, fam_texts(s, c"2024-01-08"))
	assert_equal(0, fam_texts(s, c"2024-01-07"))
	mm_scene_free(s)
	s = fam_configured(c"{'gantt': {'tickInterval': '1month'}}", body)
	assert_equal(1, fam_texts(s, c"2024-02-01"))
	assert_equal(1, fam_texts(s, c"2024-03-01"))
	assert_equal(3, fam_kind(s, MM_LINE, 1))
	mm_scene_free(s)
	s = fam_configured(c"{'gantt': {'tickInterval': '3day', 'axisFormat': '%d/%m'}}", body)
	assert_equal(1, fam_texts(s, c"01/01"))
	assert_equal(1, fam_texts(s, c"04/01"))
	mm_scene_free(s)
	# The axisFormat statement wins over the configuration.
	s = fam_configured(c"{'gantt': {'axisFormat': '%d/%m'}}", c"gantt\ndateFormat YYYY-MM-DD\naxisFormat %m-%d\nA : 2024-01-01, 10d\n")
	assert_equal(1, fam_texts(s, c"01-01"))
	mm_scene_free(s)
	# topAxis: true adds the bottom axis; false keeps only the bottom one.
	mm_primitive* top = fam_text(plain, c"2024-01-01")
	assert_equal(70, top.y)
	s = fam_configured(c"{'gantt': {'topAxis': true}}", body)
	assert_equal(2, fam_texts(s, c"2024-01-01"))
	mm_scene_free(s)
	s = fam_configured(c"{'gantt': {'topAxis': false}}", body)
	assert_equal(1, fam_texts(s, c"2024-01-01"))
	mm_primitive* bottom = fam_text(s, c"2024-01-01")
	asserts(c"bottom axis label", bottom.y > 300)
	mm_scene_free(s)
	mm_scene_free(plain)
	fam_reject(c"%%{init: {'gantt': {'axisFormat': '%Q'}}}%%\ngantt\nA : 2024-01-01, 1d\n", c"unsupported Gantt axisFormat")
	fam_reject(c"%%{init: {'gantt': {'displayMode': 'wide'}}}%%\ngantt\nA : 2024-01-01, 1d\n", c"gantt.displayMode must be one of: compact, ")

int fam_fill(mm_scene* s, int index):
	int boxes = 0
	for mm_primitive* p in s.items:
		if (p.kind != MM_BOX): continue
		if (boxes == index):
			if ((p.style.mask & MM_STYLE_FILL) == 0): return -1
			return p.style.fill
		boxes = boxes + 1
	return -2

void test_timeline_configuration():
	char* body = c"timeline\nsection One\n2020 : a\nsection Two\n2021 : b\n"
	mm_scene* plain = fam_scene(body)
	assert_equal(-1, fam_fill(plain, 0))
	mm_bounds* period = plain.nodes[0]
	assert_equal(170, period.w)
	mm_scene* s = fam_configured(c"{'timeline': {'disableMulticolor': false}}", body)
	assert_equal(mm_style_series_color(0), fam_fill(s, 0))
	assert_equal(mm_style_series_color(0), fam_fill(s, 1))
	assert_equal(mm_style_series_color(1), fam_fill(s, 2))
	mm_scene_free(s)
	s = fam_configured(c"{'timeline': {'disableMulticolor': true}}", body)
	assert_equal(-1, fam_fill(s, 0))
	mm_scene_free(s)
	s = fam_scene(c"---\nconfig:\n  timeline:\n    sectionFills:\n      - '#ff0000'\n      - '#00ff00'\n    width: 250\n---\ntimeline\nsection One\n2020 : a\nsection Two\n2021 : b\n")
	assert_equal(0xff0000, fam_fill(s, 0))
	assert_equal(0x00ff00, fam_fill(s, 2))
	period = s.nodes[0]
	assert_equal(250, period.w)
	asserts(c"svg carries section fills", fam_svg_count(s, c"#ff0000") >= 2)
	mm_scene_free(s)
	mm_scene_free(plain)

int fam_max_x(mm_scene* s):
	int result = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_LINE && p.x2 > result): result = p.x2
	return result

void test_xychart_configuration():
	char* body = c"xychart-beta\ntitle T\nx-axis \"Month\" [a, b]\ny-axis \"Value\" 0 --> 26\nbar \"Sales\" [13, 26]\n"
	mm_scene* plain = fam_scene(body)
	assert_equal(740, fam_max_x(plain))
	assert_equal(0, fam_texts(plain, c"13"))
	assert_equal(1, fam_texts(plain, c"T"))
	assert_equal(1, fam_texts(plain, c"Sales"))
	mm_primitive* category = fam_text(plain, c"a")
	asserts(c"vertical categories run along x", category.x > 140)
	mm_scene* s = fam_configured(c"{'xyChart': {'width': 1000, 'height': 700}}", body)
	assert_equal(940, fam_max_x(s))
	mm_scene_free(s)
	s = fam_configured(c"{'xyChart': {'chartOrientation': 'horizontal'}}", body)
	category = fam_text(s, c"a")
	assert_equal(10, category.x)
	mm_scene_free(s)
	s = fam_configured(c"{'xyChart': {'showDataLabel': true, 'showTitle': false, 'showLegend': false}}", body)
	assert_equal(1, fam_texts(s, c"13"))
	assert_equal(0, fam_texts(s, c"T"))
	assert_equal(0, fam_texts(s, c"Sales"))
	mm_scene_free(s)
	s = fam_configured(c"{'xyChart': {'xAxis': {'showLabel': false, 'showTitle': false}, 'yAxis': {'showLabel': false, 'showTitle': false}}}", body)
	assert_equal(0, fam_texts(s, c"a"))
	assert_equal(0, fam_texts(s, c"Month"))
	assert_equal(0, fam_texts(s, c"Value"))
	assert_equal(0, fam_texts(s, c"0"))
	mm_scene_free(s)
	int grid = fam_kind(plain, MM_LINE, 1)
	int axes = fam_kind(plain, MM_LINE, 0)
	asserts(c"grid lines drawn", grid == 6)
	s = fam_configured(c"{'xyChart': {'yAxis': {'showTick': false}}}", body)
	assert_equal(0, fam_kind(s, MM_LINE, 1))
	mm_scene_free(s)
	s = fam_configured(c"{'xyChart': {'xAxis': {'showAxisLine': false}, 'yAxis': {'showAxisLine': false}}}", body)
	assert_equal(axes - 2, fam_kind(s, MM_LINE, 0))
	mm_scene_free(s)
	mm_scene_free(plain)

mm_primitive* fam_box(mm_scene* s, int index):
	int boxes = 0
	for mm_primitive* p in s.items:
		if (p.kind != MM_BOX): continue
		if (boxes == index): return p
		boxes = boxes + 1
	asserts(c"box present", 0)
	return s.items[0]

mm_primitive* fam_polygon(mm_scene* s, int index):
	int found = 0
	for mm_primitive* p in s.items:
		if (p.kind != MM_POLYGON): continue
		if (found == index): return p
		found = found + 1
	asserts(c"polygon present", 0)
	return s.items[0]

void test_sankey_configuration():
	char* body = c"sankey\na,b,5\na,c,3\nc,d,3\nx,d,2\n"
	mm_scene* plain = fam_scene(body)
	assert_equal(1, fam_texts(plain, c"5"))
	# Nodes a b c d x: boxes follow node order.
	mm_primitive* b = fam_box(plain, 1)
	mm_primitive* x = fam_box(plain, 4)
	assert_equal(360, b.x)
	assert_equal(80, x.x)
	assert_equal(20, b.x2 - b.x)
	mm_primitive* ribbon = fam_polygon(plain, 0)
	assert_equal(0, ribbon.style.mask & MM_STYLE_FILL)
	mm_scene* s = fam_configured(c"{'sankey': {'nodeAlignment': 'justify'}}", body)
	b = fam_box(s, 1)
	assert_equal(640, b.x)
	mm_scene_free(s)
	s = fam_configured(c"{'sankey': {'nodeAlignment': 'right'}}", body)
	x = fam_box(s, 4)
	b = fam_box(s, 1)
	assert_equal(360, x.x)
	assert_equal(640, b.x)
	mm_scene_free(s)
	s = fam_configured(c"{'sankey': {'nodeAlignment': 'center'}}", body)
	x = fam_box(s, 4)
	assert_equal(360, x.x)
	mm_scene_free(s)
	s = fam_configured(c"{'sankey': {'showValues': false}}", body)
	assert_equal(0, fam_texts(s, c"5"))
	mm_scene_free(s)
	s = fam_configured(c"{'sankey': {'prefix': '$', 'suffix': 'k'}}", body)
	assert_equal(1, fam_texts(s, c"$5k"))
	mm_scene_free(s)
	s = fam_configured(c"{'sankey': {'nodeWidth': 30, 'nodePadding': 10, 'width': 760}}", body)
	b = fam_box(s, 1)
	mm_primitive* c = fam_box(s, 2)
	assert_equal(30, b.x2 - b.x)
	assert_equal(80 + 285, b.x)
	assert_equal(10, c.y - b.y2)
	mm_scene_free(s)
	s = fam_configured(c"{'sankey': {'height': 300}}", body)
	mm_primitive* a = fam_box(s, 0)
	assert_equal(80, a.y2 - a.y)
	mm_scene_free(s)
	s = fam_configured(c"{'sankey': {'linkColor': 'source', 'nodeColors': {'a': '#ff0000'}}}", body)
	ribbon = fam_polygon(s, 0)
	assert_equal(0xff0000, ribbon.style.fill)
	a = fam_box(s, 0)
	assert_equal(0xff0000, a.style.fill)
	ribbon = fam_polygon(s, 2)
	assert_equal(mm_style_series_color(2), ribbon.style.fill)
	asserts(c"svg carries link and node colors", fam_svg_count(s, c"#ff0000") >= 2)
	mm_scene_free(s)
	s = fam_configured(c"{'sankey': {'linkColor': 'target'}}", body)
	ribbon = fam_polygon(s, 0)
	assert_equal(mm_style_series_color(1), ribbon.style.fill)
	mm_scene_free(s)
	s = fam_configured(c"{'sankey': {'linkColor': 'gradient', 'nodeColors': {'a': '#ff0000', 'b': '#0000ff'}}}", body)
	ribbon = fam_polygon(s, 0)
	assert_equal(0x7f007f, ribbon.style.fill)
	mm_scene_free(s)
	s = fam_configured(c"{'sankey': {'linkColor': '#00ff00'}}", body)
	ribbon = fam_polygon(s, 1)
	assert_equal(0x00ff00, ribbon.style.fill)
	a = fam_box(s, 0)
	assert_equal(0, a.style.mask & MM_STYLE_FILL)
	mm_scene_free(s)
	mm_scene_free(plain)

# The index-th line; solid only counts undashed lines.
mm_primitive* fam_line(mm_scene* s, int index, int solid):
	int found = 0
	for mm_primitive* p in s.items:
		if (p.kind != MM_LINE || (solid && p.dashed != 0)): continue
		if (found == index): return p
		found = found + 1
	asserts(c"line present", 0)
	return s.items[0]

void fam_near(int expected, int actual):
	if (actual < expected - 1 || actual > expected + 1): assert_equal(expected, actual)

void test_radar_configuration():
	char* body = c"radar-beta\naxis a, b, c, d\ncurve one{1, 2, 3, 4}\nticks 2\ngraticule polygon\n"
	mm_scene* plain = fam_scene(body)
	# The dashed graticule comes first, then the solid axes from the center.
	mm_primitive* axis = fam_line(plain, 0, 1)
	assert_equal(300, axis.x)
	assert_equal(300, axis.y)
	fam_near(100, axis.y2)
	mm_primitive* label = fam_text(plain, c"a")
	fam_near(300 - 225 - 8, label.y)
	int curve_lines = fam_kind(plain, MM_LINE, -1)
	mm_scene* s = fam_configured(c"{'radar': {'width': 400, 'height': 400}}", body)
	axis = fam_line(s, 0, 1)
	assert_equal(200, axis.x)
	assert_equal(200, axis.y)
	fam_near(50, axis.y2)
	mm_scene_free(s)
	s = fam_configured(c"{'radar': {'marginLeft': 100, 'marginTop': 0}}", body)
	axis = fam_line(s, 0, 1)
	assert_equal(100 + 225, axis.x)
	mm_scene_free(s)
	s = fam_configured(c"{'radar': {'axisScaleFactor': 0.5, 'axisLabelFactor': 1.2}}", body)
	axis = fam_line(s, 0, 1)
	fam_near(200, axis.y2)
	label = fam_text(s, c"a")
	fam_near(300 - 240 - 8, label.y)
	mm_scene_free(s)
	s = fam_configured(c"{'radar': {'curveTension': 0.17}}", body)
	asserts(c"tension samples curves", fam_kind(s, MM_LINE, -1) > curve_lines + 30)
	mm_scene_free(s)
	mm_scene_free(plain)

void test_gitgraph_configuration():
	char* body = c"gitGraph\ncommit id: \"one\"\nbranch dev\ncommit id: \"two\"\ncheckout main\ncommit id: \"three\"\n"
	mm_scene* plain = fam_scene(body)
	assert_equal(1, fam_texts(plain, c"main"))
	assert_equal(1, fam_texts(plain, c"one"))
	# Nodes: main, one, dev, two, three.
	mm_bounds* two = plain.nodes[3]
	mm_bounds* three = plain.nodes[4]
	asserts(c"serial commits", three.x > two.x)
	mm_scene* s = fam_configured(c"{'gitGraph': {'showBranches': false, 'showCommitLabel': false}}", body)
	assert_equal(0, fam_texts(s, c"main"))
	assert_equal(0, fam_texts(s, c"dev"))
	assert_equal(0, fam_texts(s, c"one"))
	asserts(c"branch lines hidden", fam_kind(s, MM_LINE, 1) == 0 && fam_kind(plain, MM_LINE, 1) == 2)
	mm_scene_free(s)
	s = fam_configured(c"{'gitGraph': {'parallelCommits': true}}", body)
	two = s.nodes[3]
	three = s.nodes[4]
	assert_equal(two.x, three.x)
	mm_scene_free(s)
	s = fam_configured(c"{'gitGraph': {'mainBranchName': 'trunk'}}", c"gitGraph\ncommit\nbranch dev\ncommit\ncheckout trunk\ncommit\n")
	assert_equal(1, fam_texts(s, c"trunk"))
	assert_equal(0, fam_texts(s, c"main"))
	mm_scene_free(s)
	fam_reject(c"%%{init: {'gitGraph': {'mainBranchName': 'trunk'}}}%%\ngitGraph\ncommit\ncheckout main\n", c"unknown branch")
	# mainBranchOrder moves main after branches without an order.
	mm_bounds* main_lane = plain.nodes[0]
	mm_bounds* dev_lane = plain.nodes[2]
	asserts(c"main above dev natively", main_lane.y < dev_lane.y)
	s = fam_configured(c"{'gitGraph': {'mainBranchOrder': 2}}", body)
	mm_bounds* moved_main = s.nodes[0]
	mm_bounds* moved_dev = s.nodes[2]
	asserts(c"main below dev", moved_main.y > moved_dev.y)
	mm_scene_free(s)
	mm_scene_free(plain)

void test_railroad_configuration():
	char* body = c"railroad-ebnf-beta\nrule = \"a\" , \"b\" | x ;\n"
	mm_scene* plain = fam_scene(body)
	assert_equal(2, fam_kind(plain, MM_CIRCLE, -1))
	mm_scene* s = fam_configured(c"{'railroad': {'showMarkers': false}}", body)
	assert_equal(0, fam_kind(s, MM_CIRCLE, -1))
	mm_scene_free(s)
	mm_primitive* a = fam_box(plain, 0)
	mm_primitive* b = fam_box(plain, 1)
	mm_primitive* x = fam_box(plain, 2)
	assert_equal(30, b.x - a.x2)
	assert_equal(20, x.y - a.y2 - 4)
	s = fam_configured(c"{'railroad': {'horizontalSeparation': 50, 'verticalSeparation': 40}}", body)
	a = fam_box(s, 0)
	b = fam_box(s, 1)
	x = fam_box(s, 2)
	assert_equal(50, b.x - a.x2)
	assert_equal(40, x.y - a.y2 - 4)
	mm_scene_free(s)
	s = fam_configured(c"{'railroad': {'terminalFill': '#ffffc0', 'terminalStroke': 'red', 'nonTerminalFill': 'white', 'nonTerminalStroke': 'blue', 'lineColor': '#123456', 'strokeWidth': 3}}", body)
	a = fam_box(s, 0)
	x = fam_box(s, 2)
	assert_equal(0xffffc0, a.style.fill)
	assert_equal(0xff0000, a.style.stroke)
	assert_equal(0xffffff, x.style.fill)
	assert_equal(0x0000ff, x.style.stroke)
	assert_equal(3, a.style.width)
	mm_primitive* line = fam_line(s, 0, 0)
	assert_equal(0x123456, line.style.stroke)
	assert_equal(3, line.style.width)
	asserts(c"svg carries the fills", fam_svg_count(s, c"#ffffc0") == 2)
	mm_scene_free(s)
	mm_scene_free(plain)

void test_requirement_and_c4_configuration():
	char* body = c"requirementDiagram\nrequirement R {\nid: 1\ntext: t\n}\n"
	mm_scene* plain = fam_scene(body)
	mm_bounds* r = plain.nodes[0]
	asserts(c"native requirement box", r.w < 400 && r.h < 300)
	mm_scene* s = fam_configured(c"{'requirement': {'rect_min_width': 400, 'rect_min_height': 300}}", body)
	r = s.nodes[0]
	assert_equal(400, r.w)
	assert_equal(300, r.h)
	mm_scene_free(s)
	mm_scene_free(plain)
	# C4 row limits are validated and stored for the C4 layout.
	char* source = c"%%{init: {'c4': {'c4ShapeInRow': 2, 'c4BoundaryInRow': 3}}}%%\nC4Context\nPerson(a, A)\n"
	mm_document* d = mm_parse(source, strlen(source))
	assert_equal(0, cast(int, d.error))
	assert_equal(2, mm_config_number(d, c"c4.c4ShapeInRow", 4))
	assert_equal(3, mm_config_number(d, c"c4.c4BoundaryInRow", 2))
	mm_document_free(d)
	fam_reject(c"%%{init: {'c4': {'c4ShapeInRow': 0}}}%%\nC4Context\nPerson(a, A)\n", c"c4.c4ShapeInRow must be an integer from 1 to 100")

# Options left unsupported are ignored: the output is byte-identical.
void test_unsupported_options_are_ignored():
	list[char*] bodies = list[char*]{c"gitGraph\ncommit\nbranch dev\ncommit\n", c"sequenceDiagram\nA->>B: hi\n", c"xychart-beta\nx-axis [a, b]\nbar [1, 2]\n", c"sankey\na,b,1\n", c"timeline\n2020 : a\n"}
	list[char*] configs = list[char*]{c"{'gitGraph': {'rotateCommitLabel': false, 'nodeLabel': {'width': 10}}}", c"{'sequence': {'hideUnusedParticipants': true, 'messageMargin': 80, 'noteAlign': 'left'}}", c"{'xyChart': {'xAxis': {'showTick': false, 'labelRotation': 45}, 'plotReservedSpacePercent': 30}}", c"{'sankey': {'labelStyle': 'outlined'}}", c"{'timeline': {'leftMargin': 10, 'actorColours': ['#fff']}}"}
	for i in range(bodies.length):
		mm_scene* plain = fam_scene(bodies[i])
		mm_scene* configured = fam_configured(configs[i], bodies[i])
		char* a = mm_svg(plain)
		char* b = mm_svg(configured)
		assert_strings_equal(a, b)
		free(a)
		free(b)
		mm_scene_free(plain)
		mm_scene_free(configured)
	__w_list_free(cast(__w_list*, bodies))
	__w_list_free(cast(__w_list*, configs))
