# Railroad geometry following the upstream Mermaid 12.2 railroad renderer:
# arcRadius 10 quarter-circle branches, an optional bypass above, repetition
# loops below (with a bypass above for zero-or-more), padding 10, horizontal
# separation 10, vertical separation 8, and `name =` rows with 5px start/end
# markers. Arcs are sampled into short segments so SVG and the native preview
# share one display list. Native-only constructs (EBNF exceptions, PEG
# predicates, ABNF bounded repetition) use labeled frames on the same rails.
import libs.extras.mermaid.scene
import libs.extras.mermaid.railroad_parse
import libs.extras.mermaid.style_render

const int MM_RAIL_ARC = 10
const int MM_RAIL_PAD = 10
const int MM_RAIL_HSEP = 10
const int MM_RAIL_VSEP = 8
const int MM_RAIL_MARKER = 5
# Extra lane width that holds PEG ordered-choice numbers.
const int MM_RAIL_ORDER = 20

# Display form of a decoded literal: control characters are shown as escapes.
char* mm_rail_display(mm_rail_expr* e):
	string_builder* s = string_new()
	char* text = e.text
	for i in range(strlen(text)):
		int c = text[i]
		if (c == 10): string_append(s, c"\\n")
		else if (c == 13): string_append(s, c"\\r")
		else if (c == 9): string_append(s, c"\\t")
		else: string_append_char(s, c)
	char* result = strclone(s.data)
	string_free(s)
	return result

char* mm_rail_frame_label(mm_rail_expr* e):
	if (e.kind == MM_RAIL_AND): return c"lookahead (no consumption)"
	if (e.kind == MM_RAIL_NOT): return c"not (no consumption)"
	return c"match"

char* mm_rail_repeat_label(mm_rail_expr* e):
	string_builder* text = string_new()
	string_append_int(text, e.minimum)
	if (e.maximum != e.minimum):
		string_append(text, c"..")
		if (e.maximum < 0): string_append(text, c"unbounded")
		else: string_append_int(text, e.maximum)
	string_append(text, c" repetitions")
	if (e.maximum == 0): string_append(text, c" (empty)")
	char* result = strclone(text.data)
	string_free(text)
	return result

int mm_rail_loops(mm_rail_expr* e):
	if (e.kind == MM_RAIL_ZERO || e.kind == MM_RAIL_ONE): return 1
	return e.kind == MM_RAIL_REPEAT && e.maximum != 1 && e.maximum != 0

int mm_rail_bypass(mm_rail_expr* e):
	if (e.kind == MM_RAIL_OPTIONAL || e.kind == MM_RAIL_ZERO): return 1
	return e.kind == MM_RAIL_REPEAT && e.minimum == 0 && e.maximum != 0

void mm_rail_measure(mm_document* d, int index):
	mm_rail_grammar* g = d.railroad
	mm_rail_expr* e = g.expressions[index]
	if (e.width != 0): return
	int r = MM_RAIL_ARC
	if (e.children.length == 0):
		char* text = mm_rail_display(e)
		e.width = mm_text_width(text, 0) + MM_RAIL_PAD * 2
		free(text)
		e.height = MM_TEXT_LINE + MM_RAIL_PAD * 2
		e.up = e.height / 2
		e.down = e.height - e.up
		return
	int max_width = 0
	int sum_width = 0
	int sum_height = 0
	int max_up = 0
	int max_down = 0
	for int child in e.children:
		mm_rail_measure(d, child)
		mm_rail_expr* c = g.expressions[child]
		if (c.width > max_width): max_width = c.width
		if (c.up > max_up): max_up = c.up
		if (c.down > max_down): max_down = c.down
		sum_width = sum_width + c.width
		sum_height = sum_height + c.height
	int count = e.children.length
	mm_rail_expr* first = g.expressions[e.children[0]]
	if (e.kind == MM_RAIL_SEQUENCE):
		e.width = sum_width + (count - 1) * MM_RAIL_HSEP
		e.up = max_up
		e.down = max_down
		e.height = max_up + max_down
	else if (e.kind == MM_RAIL_CHOICE):
		e.width = max_width + r * 4
		if (d.kind == MM_RAIL_PEG): e.width = e.width + MM_RAIL_ORDER
		e.height = sum_height + (count - 1) * MM_RAIL_VSEP
		e.up = e.height / 2
		e.down = e.height - e.up
	else if (e.kind == MM_RAIL_EXCEPT || e.kind == MM_RAIL_AND || e.kind == MM_RAIL_NOT):
		int label = mm_text_width(mm_rail_frame_label(e), 0)
		if (e.kind == MM_RAIL_EXCEPT && mm_text_width(c"except", 0) > label): label = mm_text_width(c"except", 0)
		if (label > max_width): max_width = label
		e.width = max_width + r * 2 + 20
		int top = MM_TEXT_LINE + 8
		e.up = top + first.up
		e.height = top + first.height + 6
		if (e.kind == MM_RAIL_EXCEPT):
			mm_rail_expr* second = g.expressions[e.children[1]]
			e.height = e.height + MM_TEXT_LINE + 4 + second.height
		e.down = e.height - e.up
	else if (e.kind == MM_RAIL_REPEAT && e.maximum == 0):
		char* label = mm_rail_repeat_label(e)
		e.width = mm_text_width(label, 0) + r * 4
		free(label)
		e.up = 2
		e.height = MM_TEXT_LINE + 8
		e.down = e.height - e.up
	else:
		int top = 0
		if (mm_rail_bypass(e)): top = r * 2
		e.width = first.width + r * 4
		e.up = top + first.up
		e.height = top + first.height
		if (mm_rail_loops(e)): e.height = e.height + r * 2
		if (e.kind == MM_RAIL_REPEAT):
			char* label = mm_rail_repeat_label(e)
			int label_width = mm_text_width(label, 0) + r * 4
			free(label)
			if (label_width > e.width): e.width = label_width
			e.height = e.height + MM_TEXT_LINE + 4
		e.down = e.height - e.up

# Quarter circle from (x0,y0) to (x1,y1). `horizontal` means the rail leaves
# (x0,y0) horizontally (the center is then below/above the start point).
void mm_rail_corner(mm_scene* s, int x0, int y0, int x1, int y1, int horizontal):
	int cx = x0
	int cy = y1
	if (horizontal == 0):
		cx = x1
		cy = y0
	float ax = cast(float, x0 - cx)
	float ay = cast(float, y0 - cy)
	float bx = cast(float, x1 - cx)
	float by = cast(float, y1 - cy)
	int px = x0
	int py = y0
	for i in range(1, 7):
		float t = cast(float, i) * 1.5707963 / 6.0
		float c = fcos(t)
		float sn = fsin(t)
		int nx = cx + cast(int, ffloor(ax * c + bx * sn + 0.5))
		int ny = cy + cast(int, ffloor(ay * c + by * sn + 0.5))
		if (i == 6):
			nx = x1
			ny = y1
		mm_line(s, px, py, nx, ny, 0)
		px = nx
		py = ny

# Rail from the branch point (x,from_y) down/up a vertical lane at x+r onto
# the horizontal track at to_y, ending at (x+2r,to_y): the upstream choice
# entry shape. Tracks closer than two radii use one smooth cubic instead.
void mm_rail_switch(mm_scene* s, int x, int from_y, int to_y):
	int r = MM_RAIL_ARC
	if (from_y == to_y):
		mm_line(s, x, from_y, x + r * 2, to_y, 0)
		return
	int dir = 1
	if (to_y < from_y): dir = -1
	if ((to_y - from_y) * dir < r * 2):
		mm_style_bezier(s, x, from_y, x + r, from_y, x + r, to_y, x + r * 2, to_y, 0)
		return
	mm_rail_corner(s, x, from_y, x + r, from_y + dir * r, 1)
	mm_line(s, x + r, from_y + dir * r, x + r, to_y - dir * r, 0)
	mm_rail_corner(s, x + r, to_y - dir * r, x + r * 2, to_y, 0)

void mm_rail_draw_expr(mm_document* d, mm_scene* s, int index, int x, int y);

void mm_rail_draw_leaf(mm_document* d, mm_scene* s, mm_rail_expr* e, int x, int y):
	int round = e.kind == MM_RAIL_TERMINAL || e.kind == MM_RAIL_NUMERIC || e.kind == MM_RAIL_CLASS
	mm_draw(s, MM_BOX, x, y, x + e.width, y + e.height, round, c"")
	char* text = mm_rail_display(e)
	mm_text(s, x + MM_RAIL_PAD, y + MM_RAIL_PAD, text)
	free(text)
	if (e.kind == MM_RAIL_REFERENCE && e.target > 0):
		mm_primitive* label = s.items[s.items.length - 1]
		string_builder* href = string_from(c"#railroad-rule-")
		string_append(href, e.text)
		label.href = strclone(href.data)
		string_free(href)

void mm_rail_draw_choice(mm_document* d, mm_scene* s, mm_rail_expr* e, int x, int y):
	mm_rail_grammar* g = d.railroad
	int r = MM_RAIL_ARC
	int center = y + e.up
	int lane_width = e.width - r * 4
	int inner_x = x + r * 2
	if (d.kind == MM_RAIL_PEG):
		lane_width = lane_width - MM_RAIL_ORDER
		inner_x = inner_x + MM_RAIL_ORDER
	int yy = y
	int order = 1
	for int child in e.children:
		mm_rail_expr* c = g.expressions[child]
		int lane = yy + c.up
		int xx = inner_x + (lane_width - c.width) / 2
		# Left: branch from the center line onto this alternative's track.
		mm_rail_switch(s, x, center, lane)
		mm_line(s, x + r * 2, lane, xx, lane, 0)
		mm_rail_draw_expr(d, s, child, xx, yy)
		# Right: track back into the center line.
		int right = x + e.width
		mm_line(s, xx + c.width, lane, right - r * 2, lane, 0)
		if (lane == center): mm_line(s, right - r * 2, lane, right, center, 0)
		else:
			int dir = 1
			if (center < lane): dir = -1
			if ((center - lane) * dir < r * 2): mm_style_bezier(s, right - r * 2, lane, right - r, lane, right - r, center, right, center, 0)
			else:
				mm_rail_corner(s, right - r * 2, lane, right - r, lane + dir * r, 1)
				mm_line(s, right - r, lane + dir * r, right - r, center - dir * r, 0)
				mm_rail_corner(s, right - r, center - dir * r, right, center, 0)
		if (d.kind == MM_RAIL_PEG):
			string_builder* label = string_new()
			string_append_int(label, order)
			mm_text(s, x + r * 2 + 3, lane - MM_TEXT_LINE, label.data)
			string_free(label)
		yy = yy + c.height + MM_RAIL_VSEP
		order = order + 1

# Upstream bypass above a track: leaves the main line at (x,center), runs
# along `top`, and rejoins at (x2,center).
void mm_rail_bypass_path(mm_scene* s, int x, int x2, int center, int top):
	int r = MM_RAIL_ARC
	mm_rail_corner(s, x, center, x + r, center - r, 1)
	mm_line(s, x + r, center - r, x + r, top + r, 0)
	mm_rail_corner(s, x + r, top + r, x + r * 2, top, 0)
	mm_line(s, x + r * 2, top, x2 - r * 2, top, 0)
	mm_rail_corner(s, x2 - r * 2, top, x2 - r, top + r, 1)
	mm_line(s, x2 - r, top + r, x2 - r, center - r, 0)
	mm_rail_corner(s, x2 - r, center - r, x2, center, 0)

void mm_rail_draw_frame(mm_document* d, mm_scene* s, mm_rail_expr* e, int x, int y):
	mm_rail_grammar* g = d.railroad
	int r = MM_RAIL_ARC
	int center = y + e.up
	mm_draw(s, MM_BOX, x + r, y, x + e.width - r, y + e.height, 0, c"")
	mm_text(s, x + r + 6, y + 4, mm_rail_frame_label(e))
	mm_rail_expr* first = g.expressions[e.children[0]]
	int inner_x = x + r + 10
	int inner_y = y + MM_TEXT_LINE + 8
	mm_line(s, x, center, inner_x, center, 0)
	mm_rail_draw_expr(d, s, e.children[0], inner_x, inner_y)
	mm_line(s, inner_x + first.width, center, x + e.width, center, 0)
	if (e.kind == MM_RAIL_EXCEPT):
		int label_y = inner_y + first.height + 2
		mm_text(s, x + r + 6, label_y, c"except")
		mm_rail_draw_expr(d, s, e.children[1], inner_x, label_y + MM_TEXT_LINE + 2)

void mm_rail_draw_expr(mm_document* d, mm_scene* s, int index, int x, int y):
	mm_rail_grammar* g = d.railroad
	mm_rail_expr* e = g.expressions[index]
	int r = MM_RAIL_ARC
	int center = y + e.up
	if (e.children.length == 0):
		mm_rail_draw_leaf(d, s, e, x, y)
		return
	if (e.kind == MM_RAIL_SEQUENCE):
		int xx = x
		for i in range(e.children.length):
			mm_rail_expr* c = g.expressions[e.children[i]]
			mm_rail_draw_expr(d, s, e.children[i], xx, center - c.up)
			xx = xx + c.width
			if (i + 1 < e.children.length): mm_line(s, xx, center, xx + MM_RAIL_HSEP, center, 0)
			xx = xx + MM_RAIL_HSEP
		return
	if (e.kind == MM_RAIL_CHOICE):
		mm_rail_draw_choice(d, s, e, x, y)
		return
	if (e.kind == MM_RAIL_EXCEPT || e.kind == MM_RAIL_AND || e.kind == MM_RAIL_NOT):
		mm_rail_draw_frame(d, s, e, x, y)
		return
	if (e.kind == MM_RAIL_REPEAT && e.maximum == 0):
		mm_line(s, x, center, x + e.width, center, 0)
		char* empty = mm_rail_repeat_label(e)
		mm_text(s, x + r * 2, center + 4, empty)
		free(empty)
		return
	mm_rail_expr* c = g.expressions[e.children[0]]
	int top = y
	int inner_y = y
	if (mm_rail_bypass(e)): inner_y = y + r * 2
	int inner_x = x + r * 2
	int inner_right = inner_x + c.width
	int right = x + e.width
	mm_line(s, x, center, inner_x, center, 0)
	mm_rail_draw_expr(d, s, e.children[0], inner_x, inner_y)
	mm_line(s, inner_right, center, right, center, 0)
	if (mm_rail_bypass(e)): mm_rail_bypass_path(s, x, right, center, top)
	if (mm_rail_loops(e)):
		# Backwards loop below the body: right side down, leftwards, back up.
		int loop = inner_y + c.height + r
		int lane = inner_right + r
		if (lane > right - r): lane = right - r
		mm_rail_corner(s, inner_right, center, lane, center + r, 1)
		mm_line(s, lane, center + r, lane, loop, 0)
		mm_rail_corner(s, lane, loop, lane - r, loop + r, 0)
		mm_line(s, lane - r, loop + r, x + r * 2, loop + r, 0)
		mm_rail_corner(s, x + r * 2, loop + r, x + r, loop, 1)
		mm_line(s, x + r, loop, x + r, center + r, 0)
		mm_rail_corner(s, x + r, center + r, x + r * 2, center, 0)
	if (e.kind == MM_RAIL_REPEAT):
		char* label = mm_rail_repeat_label(e)
		mm_text(s, x + r * 2, y + e.height - MM_TEXT_LINE - 2, label)
		free(label)

mm_scene* mm_rail_render(mm_document* d):
	mm_scene* s = new mm_scene()
	s.items = new list[mm_primitive*]
	s.nodes = new list[mm_bounds*]
	s.width = 300
	s.height = 200
	char* title = d.title
	if (title[0] == 0): title = d.railroad.title
	s.has_title = title[0] != 0
	int left = MM_RAIL_PAD * 2
	int y = MM_RAIL_PAD
	if (s.has_title):
		mm_text(s, left, y, title)
		y = y + MM_TEXT_LINE + 24
	for mm_rail_rule* rule in d.railroad.rules:
		mm_rail_measure(d, rule.expression)
		mm_rail_expr* e = d.railroad.expressions[rule.expression]
		string_builder* name = string_from(rule.name)
		string_append(name, c" =")
		int name_width = mm_text_width(name.data, 0) + 20
		int definition_x = left + name_width + 20
		int baseline = e.up
		if (baseline < 20): baseline = 20
		int definition_y = y + baseline - e.up
		baseline = y + baseline
		mm_text(s, left, baseline - MM_TEXT_LINE / 2, name.data)
		string_free(name)
		mm_primitive* label = s.items[s.items.length - 1]
		string_builder* anchor = string_from(c"railroad-rule-")
		string_append(anchor, rule.name)
		label.anchor = strclone(anchor.data)
		string_free(anchor)
		int marker = left + name_width
		mm_draw(s, MM_CIRCLE, marker - MM_RAIL_MARKER, baseline - MM_RAIL_MARKER, marker + MM_RAIL_MARKER, baseline + MM_RAIL_MARKER, 1, c"")
		mm_line(s, marker + MM_RAIL_MARKER, baseline, definition_x, baseline, 0)
		mm_rail_draw_expr(d, s, rule.expression, definition_x, definition_y)
		int end = definition_x + e.width + 10
		mm_line(s, definition_x + e.width, baseline, end - MM_RAIL_MARKER, baseline, 0)
		mm_draw(s, MM_CIRCLE, end - MM_RAIL_MARKER, baseline - MM_RAIL_MARKER, end + MM_RAIL_MARKER, baseline + MM_RAIL_MARKER, 1, c"")
		int row = definition_y - y + e.height + MM_RAIL_PAD * 2
		if (row < 40): row = 40
		y = y + row + MM_RAIL_VSEP
	return s
