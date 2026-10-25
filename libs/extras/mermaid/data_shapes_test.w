# wbuild: x64
# Radar smooth curves (curveTension) and general-N Venn layout.
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* shape_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"diagram parses", d.error == 0)
	return d

void shape_bad(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"invalid diagram has diagnostic", d.error != 0)
	asserts(c"invalid diagram suppresses scene", mm_render(d) == 0)
	mm_document_free(d)

int series_lines(mm_scene* s, int series):
	int count = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_LINE && p.role == MM_ROLE_SERIES && p.series == series): count = count + 1
	return count

# The first sampled segment of series 0 ends this far from the straight chord.
int first_segment_end_y(mm_scene* s):
	for mm_primitive* p in s.items:
		if (p.kind == MM_LINE && p.role == MM_ROLE_SERIES && p.series == 0): return p.y2
	return -1

void test_radar_circle_graticule_draws_closed_spline():
	mm_document* d = shape_parse(c"radar-beta\naxis a, b, c, d\ncurve one{4, 2, 4, 2}\nmax 4\n")
	mm_scene* s = mm_render(d)
	# Four cubic segments sampled into twelve straight steps each, plus the legend key.
	assert_equal(48 + 1, series_lines(s, 0))
	char* svg = mm_svg(s)
	asserts(c"smooth curve exported to SVG", index_of(svg, c"<line") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
	d = shape_parse(c"radar-beta\naxis a, b, c, d\ncurve one{4, 2, 4, 2}\nmax 4\ngraticule polygon\n")
	s = mm_render(d)
	assert_equal(4 + 1, series_lines(s, 0))
	mm_scene_free(s)
	mm_document_free(d)

void test_radar_curve_tension_configuration():
	char* base = c"radar-beta\naxis a, b, c, d\ncurve one{4, 2, 4, 2}\nmax 4\n"
	mm_document* d = shape_parse(base)
	mm_scene* s = mm_render(d)
	int default_y = first_segment_end_y(s)
	mm_scene_free(s)
	mm_document_free(d)
	d = shape_parse(c"---\nconfig:\n  radar:\n    curveTension: 0\n---\nradar-beta\naxis a, b, c, d\ncurve one{4, 2, 4, 2}\nmax 4\n")
	assert_equal(0, d.radar_tension)
	s = mm_render(d)
	int straight_y = first_segment_end_y(s)
	mm_scene_free(s)
	mm_document_free(d)
	d = shape_parse(c"%%{init: {\"radar\": {\"curveTension\": 0.5}}}%%\nradar-beta\naxis a, b, c, d\ncurve one{4, 2, 4, 2}\nmax 4\n")
	assert_equal(500, d.radar_tension)
	s = mm_render(d)
	int loose_y = first_segment_end_y(s)
	char* copy = mm_write(d)
	asserts(c"configured radar source is lossless", index_of(copy, c"curveTension") >= 0)
	free(copy)
	mm_scene_free(s)
	mm_document_free(d)
	# Tension 0 degenerates to the chord; larger tension bulges further out.
	asserts(c"tension changes the curve", straight_y != default_y && default_y != loose_y)
	asserts(c"tension bulges monotonically", (default_y - straight_y) * (loose_y - default_y) > 0)
	shape_bad(c"---\nconfig:\n  radar:\n    curveTension: -1\n---\nradar-beta\naxis a, b, c\ncurve x{1,2,3}\n")
	shape_bad(c"---\nconfig:\n  radar:\n    curveTension: lots\n---\nradar-beta\naxis a, b, c\ncurve x{1,2,3}\n")

# Circles are emitted as runs of 32 sampled segments; recover center and radius.
list[int] venn_circles(mm_scene* s):
	list[int] circles = new list[int]
	int run = 0
	int min_x = 0
	int max_x = 0
	int min_y = 0
	int max_y = 0
	for mm_primitive* p in s.items:
		if (p.kind != MM_LINE):
			run = 0
			continue
		if (run == 0):
			min_x = p.x
			max_x = p.x
			min_y = p.y
			max_y = p.y
		if (p.x < min_x): min_x = p.x
		if (p.x > max_x): max_x = p.x
		if (p.y < min_y): min_y = p.y
		if (p.y > max_y): max_y = p.y
		run = run + 1
		if (run == 32):
			circles.push((min_x + max_x) / 2)
			circles.push((min_y + max_y) / 2)
			circles.push((max_x - min_x) / 2)
			run = 0
	return circles

int venn_distance(list[int] c, int a, int b):
	int dx = c[a * 3] - c[b * 3]
	int dy = c[a * 3 + 1] - c[b * 3 + 1]
	return cast(int, fsqrt(cast(float, dx * dx + dy * dy)))

# 1 when (x,y) lies inside circle i.
int venn_inside(list[int] c, int i, int x, int y):
	int dx = x - c[i * 3]
	int dy = y - c[i * 3 + 1]
	return dx * dx + dy * dy < c[i * 3 + 2] * c[i * 3 + 2]

mm_primitive* venn_label(mm_scene* s, char* text):
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && strcmp(p.text, text) == 0): return p
	return 0

void test_venn_three_explicit_sizes_area_proportional():
	char* source = c"venn-beta\nset A[\"Alpha\"]:20\nset B[\"Beta\"]:10\nset C[\"Gamma\"]:5\nunion A,B[\"AB\"]:4\nunion B,C[\"BC\"]:1\n"
	mm_document* d = shape_parse(source)
	char* copy = mm_write(d)
	assert_strings_equal(source, copy)
	free(copy)
	mm_scene* s = mm_render(d)
	list[int] c = venn_circles(s)
	assert_equal(9, c.length)
	# Radii follow sqrt(size): A/B = sqrt(2), B/C = sqrt(2).
	float ab = cast(float, c[2]) / cast(float, c[5])
	float bc = cast(float, c[5]) / cast(float, c[8])
	asserts(c"set radii are area proportional", ab > 1.37 && ab < 1.46 && bc > 1.37 && bc < 1.46)
	# The A/B lens holds 4/20 of A's area (within rounding).
	float lens = mm_data_venn_overlap(cast(float, c[2]), cast(float, c[5]), cast(float, venn_distance(c, 0, 1)))
	float ratio = lens / (3.14159265 * cast(float, c[2] * c[2]))
	asserts(c"explicit three-set intersection size honoured", ratio > 0.18 && ratio < 0.22)
	# A and C share no declared region, so they do not overlap.
	asserts(c"undeclared pair stays disjoint", venn_distance(c, 0, 2) >= c[2] + c[8] - 3)
	mm_primitive* label = venn_label(s, c"AB")
	int x = label.x + mm_text_width(c"AB", 0) / 2
	int y = label.y + 8
	asserts(c"intersection label inside its region", venn_inside(c, 0, x, y) && venn_inside(c, 1, x, y) && venn_inside(c, 2, x, y) == 0)
	char* svg = mm_svg(s)
	asserts(c"three-set sized Venn exported", index_of(svg, c">Gamma</text>") >= 0 && index_of(svg, c">BC</text>") >= 0)
	free(svg)
	__w_list_free(cast(__w_list*, c))
	mm_scene_free(s)
	mm_document_free(d)

void test_venn_more_than_three_sets():
	char* source = c"venn-beta\ntitle Skills\nset A\nset B\nset C\nset D\nset E\nunion A,B[\"AB\"]\nunion B,C[\"BC\"]\nunion C,D[\"CD\"]\nunion D,E[\"DE\"]\nunion A,B,C[\"ABC\"]\n  text core[\"Core\"]\n"
	mm_document* d = shape_parse(source)
	mm_scene* s = mm_render(d)
	list[int] c = venn_circles(s)
	assert_equal(15, c.length)
	for i in range(5):
		asserts(c"default sizes give equal radii", c[i * 3 + 2] >= c[2] - 1 && c[i * 3 + 2] <= c[2] + 1)
		asserts(c"circles fit the positive viewport", c[i * 3] - c[i * 3 + 2] >= 0 && c[i * 3 + 1] - c[i * 3 + 2] >= 0)
	asserts(c"declared pair overlaps", venn_distance(c, 2, 3) < c[8] + c[11])
	# A,B,C implies the A/C overlap even though it is not declared.
	asserts(c"higher-arity union implies pairwise overlap", venn_distance(c, 0, 2) < c[2] + c[8])
	asserts(c"undeclared pair disjoint", venn_distance(c, 0, 4) >= c[2] + c[14] - 3)
	mm_primitive* label = venn_label(s, c"CD")
	int x = label.x + mm_text_width(c"CD", 0) / 2
	int y = label.y + 8
	asserts(c"pair label inside its region", venn_inside(c, 2, x, y) && venn_inside(c, 3, x, y))
	char* svg = mm_svg(s)
	asserts(c"text nodes exported for N sets", index_of(svg, c">Core</text>") >= 0)
	free(svg)
	__w_list_free(cast(__w_list*, c))
	mm_scene_free(s)
	mm_document_free(d)
	d = shape_parse(c"venn-beta\nset A:8\nset B:7\nset C:6\nset D:5\nset E:4\nset F:3\nset G:2\nset H:1\nunion A,H[\"AH\"]:0.5\n")
	s = mm_render(d)
	c = venn_circles(s)
	assert_equal(24, c.length)
	__w_list_free(cast(__w_list*, c))
	mm_scene_free(s)
	mm_document_free(d)
	shape_bad(c"venn-beta\nset A\nset B\nset C\nset D\nset E\nset F\nset G\nset H\nset I\n")
