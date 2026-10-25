# Railroad geometry: branches, bypasses, backwards loops, and grammar boxes.
import libs.extras.mermaid.scene
import libs.extras.mermaid.railroad_parse
import libs.extras.mermaid.style

# railroad.horizontalSeparation / verticalSeparation (native 30 and 20).
void mm_rail_measure(mm_rail_grammar* g, int index, int hsep, int vsep):
	mm_rail_expr* e = g.expressions[index]
	if (e.width != 0): return
	e.width = strlen(e.text) * 8 + 32
	if (e.width < 60): e.width = 60
	e.height = 40
	if (e.children.length == 0): return
	int max_width = 0
	int max_height = 0
	int sum_width = 0
	int sum_height = 0
	for int child in e.children:
		mm_rail_measure(g, child, hsep, vsep)
		mm_rail_expr* c = g.expressions[child]
		if (c.width > max_width): max_width = c.width
		if (c.height > max_height): max_height = c.height
		sum_width = sum_width + c.width + hsep
		sum_height = sum_height + c.height + vsep
	if (e.kind == MM_RAIL_SEQUENCE):
		e.width = sum_width - hsep
		e.height = max_height
	else if (e.kind == MM_RAIL_EXCEPT):
		e.width = max_width + 80
		e.height = sum_height + 60
	else if (e.kind == MM_RAIL_CHOICE):
		e.width = max_width + 100
		e.height = sum_height - vsep
	else:
		e.width = max_width + 80
		e.height = max_height + 60
		if (e.kind == MM_RAIL_ZERO || (e.kind == MM_RAIL_REPEAT && e.minimum == 0)): e.height = max_height + 100
		if (e.kind == MM_RAIL_REPEAT && e.width < 280): e.width = 280
		if (e.kind == MM_RAIL_AND || e.kind == MM_RAIL_NOT):
			e.height = max_height + 60
			if (e.width < 270): e.width = 270

void mm_rail_arrow(mm_scene* s, int x, int y, int reverse):
	int direction = 1
	if (reverse): direction = -1
	mm_line(s, x - direction * 6, y - 4, x, y, 0)
	mm_line(s, x - direction * 6, y + 4, x, y, 0)

void mm_rail_path(mm_scene* s, int x, int y, int x2):
	mm_line(s, x, y, x2, y, 0)
	if (x2 - x > 12): mm_rail_arrow(s, (x + x2) / 2, y, 0)

char* mm_rail_repeat_label(mm_rail_expr* e):
	string_builder* text = string_new()
	string_append_int(text, e.minimum)
	if (e.maximum != e.minimum):
		string_append(text, c"..")
		if (e.maximum < 0): string_append(text, c"unbounded")
		else: string_append_int(text, e.maximum)
	string_append(text, c" repetitions")
	char* result = strclone(text.data)
	string_free(text)
	return result

void mm_rail_draw_expr(mm_document* d, mm_scene* s, int index, int x, int y):
	mm_rail_grammar* g = d.railroad
	mm_rail_expr* e = g.expressions[index]
	int baseline = y + 20
	if (e.children.length == 0):
		int round = e.kind == MM_RAIL_TERMINAL || e.kind == MM_RAIL_NUMERIC || e.kind == MM_RAIL_CLASS
		mm_draw(s, MM_BOX, x, y + 2, x + e.width, y + 38, round, c"")
		# railroad.terminalFill/Stroke and nonTerminalFill/Stroke.
		char* fill = mm_config_value(d, c"railroad.nonTerminalFill")
		char* stroke = mm_config_value(d, c"railroad.nonTerminalStroke")
		if (round):
			fill = mm_config_value(d, c"railroad.terminalFill")
			stroke = mm_config_value(d, c"railroad.terminalStroke")
		mm_primitive* box = s.items[s.items.length - 1]
		if (fill != 0):
			box.style.mask = box.style.mask | MM_STYLE_FILL
			box.style.fill = mm_style_color(fill)
		if (stroke != 0):
			box.style.mask = box.style.mask | MM_STYLE_STROKE
			box.style.stroke = mm_style_color(stroke)
		mm_text(s, x + 16, y + 12, e.text)
		return
	if (e.kind == MM_RAIL_SEQUENCE):
		int hsep = mm_config_number(d, c"railroad.horizontalSeparation", 30)
		int xx = x
		for int child in e.children:
			mm_rail_expr* c = g.expressions[child]
			mm_rail_draw_expr(d, s, child, xx, y)
			xx = xx + c.width
			if (xx < x + e.width): mm_rail_path(s, xx, baseline, xx + hsep)
			xx = xx + hsep
		return
	if (e.kind == MM_RAIL_CHOICE):
		int yy = y
		int order = 1
		for int child in e.children:
			mm_rail_expr* c = g.expressions[child]
			int xx = x + (e.width - c.width) / 2
			mm_line(s, x, baseline, x + 20, baseline, 0)
			mm_line(s, x + 20, baseline, x + 20, yy + 20, 0)
			mm_rail_path(s, x + 20, yy + 20, xx)
			mm_rail_draw_expr(d, s, child, xx, yy)
			mm_rail_path(s, xx + c.width, yy + 20, x + e.width - 20)
			mm_line(s, x + e.width - 20, yy + 20, x + e.width - 20, baseline, 0)
			mm_line(s, x + e.width - 20, baseline, x + e.width, baseline, 0)
			if (d.kind == MM_RAIL_PEG):
				string_builder* label = string_new()
				string_append_int(label, order)
				mm_text(s, x + 24, yy + 1, label.data)
				string_free(label)
			yy = yy + c.height + mm_config_number(d, c"railroad.verticalSeparation", 20)
			order = order + 1
		return
	if (e.kind == MM_RAIL_EXCEPT):
		mm_draw(s, MM_BOX, x + 10, y, x + e.width - 10, y + e.height, 0, c"")
		mm_line(s, x, baseline, x + 10, baseline, 0)
		mm_line(s, x + e.width - 10, baseline, x + e.width, baseline, 0)
		mm_text(s, x + 20, y + 5, c"match")
		mm_rail_expr* included = g.expressions[e.children[0]]
		mm_rail_draw_expr(d, s, e.children[0], x + 40, y + 30)
		mm_text(s, x + 20, y + included.height + 40, c"except")
		mm_rail_draw_expr(d, s, e.children[1], x + 40, y + included.height + 65)
		return
	mm_rail_expr* c = g.expressions[e.children[0]]
	int xx = x + (e.width - c.width) / 2
	if (e.kind == MM_RAIL_AND || e.kind == MM_RAIL_NOT):
		# A labeled non-consuming predicate box contains its tested grammar.
		mm_draw(s, MM_BOX, x + 10, y, x + e.width - 10, y + e.height, 0, c"")
		mm_line(s, x, baseline, x + 10, baseline, 0)
		mm_line(s, x + e.width - 10, baseline, x + e.width, baseline, 0)
		if (e.kind == MM_RAIL_AND): mm_text(s, x + 20, y + 5, c"lookahead (no consumption)")
		else: mm_text(s, x + 20, y + 5, c"not (no consumption)")
		mm_rail_draw_expr(d, s, e.children[0], xx, y + 40)
		return
	int optional = e.kind == MM_RAIL_OPTIONAL || e.kind == MM_RAIL_ZERO || (e.kind == MM_RAIL_REPEAT && e.minimum == 0)
	int loop = e.kind == MM_RAIL_ZERO || e.kind == MM_RAIL_ONE || (e.kind == MM_RAIL_REPEAT && e.maximum != 1 && e.maximum != 0)
	if (e.kind == MM_RAIL_REPEAT && e.maximum == 0):
		mm_rail_path(s, x, baseline, x + e.width)
		mm_text(s, x + 20, baseline + 14, c"0 repetitions (empty)")
		return
	int yy = y
	if (optional):
		mm_rail_path(s, x, baseline, x + e.width)
		yy = y + 40
		mm_line(s, x + 20, baseline, x + 20, yy + 20, 0)
		mm_line(s, x + e.width - 20, baseline, x + e.width - 20, yy + 20, 0)
	else:
		mm_line(s, x, baseline, x + 20, baseline, 0)
		mm_line(s, x + e.width - 20, baseline, x + e.width, baseline, 0)
	mm_rail_path(s, x + 20, yy + 20, xx)
	mm_rail_draw_expr(d, s, e.children[0], xx, yy)
	mm_rail_path(s, xx + c.width, yy + 20, x + e.width - 20)
	if (loop):
		int bottom = yy + c.height + 20
		mm_line(s, x + 20, yy + 20, x + 20, bottom, 0)
		mm_line(s, x + e.width - 20, yy + 20, x + e.width - 20, bottom, 0)
		mm_line(s, x + 20, bottom, x + e.width - 20, bottom, 0)
		mm_rail_arrow(s, x + e.width / 2, bottom, 1)
	if (e.kind == MM_RAIL_REPEAT):
		char* label = mm_rail_repeat_label(e)
		mm_text(s, x + 20, y + e.height - 18, label)
		free(label)

mm_scene* mm_rail_render(mm_document* d):
	mm_scene* s = new mm_scene()
	s.items = new list[mm_primitive*]
	s.nodes = new list[mm_bounds*]
	s.width = 300
	s.height = 200
	char* title = d.title
	if (title[0] == 0): title = d.railroad.title
	mm_text(s, 40, 20, title)
	s.has_title = title[0] != 0
	int y = 80
	int hsep = mm_config_number(d, c"railroad.horizontalSeparation", 30)
	int vsep = mm_config_number(d, c"railroad.verticalSeparation", 20)
	int markers = mm_config_flag(d, c"railroad.showMarkers", 1)
	for mm_rail_rule* rule in d.railroad.rules:
		mm_rail_measure(d.railroad, rule.expression, hsep, vsep)
		mm_rail_expr* e = d.railroad.expressions[rule.expression]
		mm_text(s, 40, y, rule.name)
		y = y + 30
		if (markers): mm_draw(s, MM_CIRCLE, 40, y + 16, 48, y + 24, 1, c"")
		mm_rail_path(s, 48, y + 20, 80)
		mm_rail_draw_expr(d, s, rule.expression, 80, y)
		mm_rail_path(s, 80 + e.width, y + 20, 112 + e.width)
		if (markers): mm_draw(s, MM_CIRCLE, 112 + e.width, y + 16, 120 + e.width, y + 24, 1, c"")
		y = y + e.height + 40
	# railroad.lineColor and strokeWidth apply to every connection and outline.
	char* line = mm_config_value(d, c"railroad.lineColor")
	int stroke_width = mm_config_number(d, c"railroad.strokeWidth", 0)
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT): continue
		if (line != 0 && p.kind == MM_LINE):
			p.style.mask = p.style.mask | MM_STYLE_STROKE
			p.style.stroke = mm_style_color(line)
		if (stroke_width > 0):
			p.style.mask = p.style.mask | MM_STYLE_WIDTH
			p.style.width = stroke_width
	return s
