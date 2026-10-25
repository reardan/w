# wbuild: x64
# Family renderers size and wrap text from the shared per-glyph metrics
# (text_metrics.w) instead of fixed per-character estimates (issue #817):
# timeline, kanban and mindmap wrapping, gantt compact bar labels,
# xychart axis labels, pie legend columns, block and gitGraph boxes.
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* family_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"family source parses", d.error == 0)
	return d

mm_primitive* family_text(mm_scene* s, char* text):
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && strcmp(p.text, text) == 0): return p
	return 0

int family_right(mm_primitive* p):
	return p.x + mm_text_width(p.text, p.text_style)

void test_timeline_events_wrap_inside_their_column():
	mm_document* d = family_parse(c"timeline\n2024 : A deliberately long event description that upstream wraps inside the section width\n2025 : Short\n")
	mm_scene* s = mm_render(d)
	mm_bounds* period = s.nodes[0]
	# The column keeps the 170px default instead of growing to the line.
	assert_equal(170, period.w)
	int lines = 0
	for mm_primitive* p in s.items:
		if (p.kind != MM_TEXT || p.x != period.x + 15 || p.y < 200): continue
		asserts(c"wrapped line fits the column", family_right(p) <= period.x + period.w - 15)
		lines = lines + 1
	asserts(c"event wraps onto several lines", lines >= 4)
	# The event box grows by 18px per extra line.
	int tall = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_BOX && p.x == period.x && p.y2 - p.y == 45 + (lines - 1) * 18): tall = tall + 1
	assert_equal(1, tall)
	mm_scene_free(s)
	mm_document_free(d)
	# A word wider than the column widens it instead of overflowing.
	d = family_parse(c"timeline\n2024 : Supercalifragilisticexpialidociousnessology\n")
	s = mm_render(d)
	period = s.nodes[0]
	assert_equal(mm_text_width(c"Supercalifragilisticexpialidociousnessology", 0) + 40, period.w)
	mm_scene_free(s)
	mm_document_free(d)

void test_kanban_and_mindmap_labels_wrap_at_node_width():
	mm_document* d = family_parse(c"kanban\nTodo\n  card[A long card title that needs to wrap across several lines here]\n")
	mm_scene* s = mm_render(d)
	mm_bounds* card = s.nodes[1]
	asserts(c"card stays near the section width", card.w <= 240)
	int lines = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && p.x == card.x + 20 && p.y >= card.y && p.y < card.y + card.h):
			asserts(c"card line inside card", family_right(p) <= card.x + card.w)
			lines = lines + 1
	asserts(c"card title wraps", lines >= 2)
	assert_equal(60 + (lines - 1) * MM_TEXT_PITCH, card.h)
	mm_scene_free(s)
	mm_document_free(d)
	d = family_parse(c"mindmap\n  root((A central topic name that is much too long for one line))\n")
	s = mm_render(d)
	mm_bounds* root = s.nodes[0]
	lines = 0
	for mm_primitive* p in s.items:
		if (p.kind != MM_TEXT): continue
		asserts(c"mindmap line centred in node", p.x >= root.x && family_right(p) <= root.x + root.w)
		lines = lines + 1
	asserts(c"mindmap label wraps", lines >= 2)
	mm_scene_free(s)
	mm_document_free(d)

void test_gantt_compact_labels_inside_or_beside_bars():
	mm_document* d = family_parse(c"---\ndisplayMode: compact\n---\ngantt\ndateFormat YYYY-MM-DD\nsection S\nLong running task : 2024-01-01, 20d\nTiny label that will not fit : 2024-01-25, 1d\n")
	mm_scene* s = mm_render(d)
	mm_bounds* first = s.nodes[0]
	mm_bounds* second = s.nodes[1]
	mm_primitive* inside = family_text(s, c"Long running task")
	mm_primitive* outside = family_text(s, c"Tiny label that will not fit")
	asserts(c"labels drawn", inside != 0 && outside != 0)
	asserts(c"fitting label centred inside its bar", inside.x > first.x && family_right(inside) < first.x + first.w)
	assert_equal(first.x + (first.w - mm_text_width(inside.text, 0)) / 2, inside.x)
	assert_equal(second.x + second.w + 6, outside.x)
	mm_scene_free(s)
	mm_document_free(d)

void test_xychart_axis_labels_measured():
	mm_document* d = family_parse(c"xychart-beta\nx-axis [\"Quarter one results\", \"Quarter two results\", \"Quarter three results\", \"Quarter four results\", \"Quarter five results\", \"Quarter six results\", \"Quarter seven results\", \"Quarter eight results\", \"Quarter nine results\", \"Quarter ten results\"]\ny-axis \"Revenue\" 0 --> 1000\nbar [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]\n")
	mm_scene* s = mm_render(d)
	# Value labels right-align ten pixels left of the axis at x = 140.
	mm_primitive* top = family_text(s, c"1000")
	asserts(c"top value label", top != 0)
	assert_equal(130, family_right(top))
	# Ten 60px bands: long category labels wrap to the band width, so no
	# two neighbouring labels overlap.
	int words = 0
	for i in range(s.items.length):
		mm_primitive* a = s.items[i]
		if (a.kind != MM_TEXT || (strcmp(a.text, c"Quarter") != 0 && strcmp(a.text, c"results") != 0)): continue
		words = words + 1
		for j in range(i + 1, s.items.length):
			mm_primitive* b = s.items[j]
			if (b.kind != MM_TEXT || b.y != a.y || (strcmp(b.text, c"Quarter") != 0 && strcmp(b.text, c"results") != 0)): continue
			asserts(c"category labels apart", family_right(a) <= b.x || family_right(b) <= a.x)
	assert_equal(20, words)
	mm_scene_free(s)
	mm_document_free(d)

void test_pie_legend_and_boxes_use_measured_widths():
	# The percentage column starts after each name's measured width, so a
	# wide name pushes it further than a narrow name of the same length.
	mm_document* d = family_parse(c"pie\n\"WWWW\": 1\n\"iiii\": 1\n")
	mm_scene* s = mm_render(d)
	mm_primitive* wide = family_text(s, c"WWWW")
	mm_primitive* narrow = family_text(s, c"iiii")
	mm_primitive* wide_percent = 0
	mm_primitive* narrow_percent = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && strcmp(p.text, c"50%") == 0):
			if (p.y == wide.y): wide_percent = p
			if (p.y == narrow.y): narrow_percent = p
	assert_equal(family_right(wide) + 12, wide_percent.x)
	assert_equal(family_right(narrow) + 12, narrow_percent.x)
	asserts(c"wide name widens its row", wide_percent.x > narrow_percent.x)
	mm_scene_free(s)
	mm_document_free(d)
	d = family_parse(c"block\ncolumns 2\na[\"WWWWWWWW\"] b[\"iiiiiiii\"]\n")
	s = mm_render(d)
	# Block labels centre from their measured widths.
	mm_bounds* a = s.nodes[mm_find_node(d, c"a")]
	mm_bounds* b = s.nodes[mm_find_node(d, c"b")]
	mm_primitive* wide_label = family_text(s, c"WWWWWWWW")
	mm_primitive* narrow_label = family_text(s, c"iiiiiiii")
	assert_equal(a.x + (a.w - mm_text_width(c"WWWWWWWW", 0)) / 2, wide_label.x)
	assert_equal(b.x + (b.w - mm_text_width(c"iiiiiiii", 0)) / 2, narrow_label.x)
	mm_scene_free(s)
	mm_document_free(d)
	d = family_parse(c"gitGraph\ncommit id: \"WWWWWWWWWWWW\"\ncommit id: \"iiiiiiiiiiii\"\ncommit id: \"end\"\n")
	s = mm_render(d)
	mm_bounds* first = 0
	mm_bounds* second = 0
	mm_bounds* third = 0
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (strcmp(n.label, c"WWWWWWWWWWWW") == 0): first = s.nodes[i]
		if (strcmp(n.label, c"iiiiiiiiiiii") == 0): second = s.nodes[i]
		if (strcmp(n.label, c"end") == 0): third = s.nodes[i]
	asserts(c"commits found", first != 0 && second != 0 && third != 0)
	assert_equal(mm_text_width(c"WWWWWWWWWWWW", 0) + 60, second.x - first.x)
	assert_equal(mm_text_width(c"iiiiiiiiiiii", 0) + 60, third.x - second.x)
	asserts(c"narrow commit id narrower than a per-character estimate", third.x - second.x < 12 * 8 + 60)
	mm_scene_free(s)
	mm_document_free(d)

void test_vertical_timeline_wraps_like_horizontal():
	mm_document* d = family_parse(c"timeline TD\n2024 : A deliberately long event description that wraps inside its box\nA period title long enough to wrap in the column : Short\n")
	mm_scene* s = mm_render(d)
	mm_bounds* period = s.nodes[0]
	# Columns keep the 170px default instead of growing to the line.
	assert_equal(170, period.w)
	mm_bounds* second = s.nodes[1]
	assert_equal(170, second.w)
	int event_lines = 0
	int event_x = -1
	for mm_primitive* p in s.items:
		if (p.kind == MM_BOX && p.y == period.y && p.x > period.x + period.w):
			event_x = p.x
			assert_equal(170, p.x2 - p.x)
	asserts(c"event box found", event_x > 0)
	for mm_primitive* p in s.items:
		if (p.kind != MM_TEXT || p.x != event_x + 15): continue
		asserts(c"wrapped event line fits its box", family_right(p) <= event_x + 170 - 15)
		if (p.y < second.y): event_lines = event_lines + 1
	asserts(c"event wraps onto several lines", event_lines >= 3)
	# The row grows with the wrapped event: 45px plus 18px per extra line.
	assert_equal(45 + (event_lines - 1) * 18, period.h)
	# The long period title wraps inside its column too.
	int title_lines = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && p.x == 75 && p.y >= second.y && p.y < second.y + second.h): title_lines = title_lines + 1
	asserts(c"period title wraps", title_lines >= 2)
	mm_scene_free(s)
	mm_document_free(d)

void test_journey_task_labels_wrap():
	mm_document* d = family_parse(c"journey\nsection Day\nA task label long enough to wrap inside the fixed width task box: 3: Me\nShort: 4: Me\n")
	mm_scene* s = mm_render(d)
	mm_bounds* task = s.nodes[0]
	mm_bounds* other = s.nodes[1]
	assert_equal(160, task.w)
	int lines = 0
	for mm_primitive* p in s.items:
		if (p.kind != MM_TEXT || p.x != task.x + 10 || p.y < task.y || p.y > task.y + task.h): continue
		asserts(c"wrapped task line fits its box", family_right(p) <= task.x + task.w - 10)
		lines = lines + 1
	asserts(c"task label wraps", lines >= 3)
	# Every task box shares the taller height.
	assert_equal(task.h, other.h)
	asserts(c"task box grows", task.h > 50)
	mm_scene_free(s)
	mm_document_free(d)

void test_requirement_boxes_use_measured_rows():
	mm_document* d = family_parse(c"requirementDiagram\nrequirement r {\n  id: 1\n  text: A requirement text that is measured\n}\nelement e {\n  type: db\n}\nr - satisfies -> e\n")
	mm_scene* s = mm_render(d)
	mm_bounds* r = s.nodes[0]
	# 10px padding, the type line (line height + 6) and the name, the 20px
	# divider gap and two property rows (line height + 6); the width follows
	# the widest measured line.
	int row = MM_TEXT_LINE + 6
	assert_equal(10 + row + MM_TEXT_LINE + 20 + row * 2 + 10, r.h)
	assert_equal(mm_text_width(c"text: A requirement text that is measured", 0) + 24, r.w)
	mm_primitive* type = family_text(s, c"<<requirement>>")
	asserts(c"type line centered above the name", type != 0 && type.y < r.y + 20 && type.x == r.x + (r.w - mm_text_width(c"<<requirement>>", 0)) / 2)
	mm_primitive* text = family_text(s, c"text: A requirement text that is measured")
	asserts(c"row inside the box", text != 0 && family_right(text) <= r.x + r.w - 12)
	mm_scene_free(s)
	mm_document_free(d)
