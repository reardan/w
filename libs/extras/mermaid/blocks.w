# Source-ordered block grids with spans and bounded nested composites.
import libs.extras.mermaid.frameworks
import libs.extras.mermaid.framework_render
import libs.extras.mermaid.style_render

# Block shapes reuse the flowchart codes where they exist (0 rectangle,
# 1 rounded, 2 circle, 3 rhombus, 21 stadium, 22 subroutine, 23 hexagon,
# 24..27 parallelograms/trapezoids) plus block-only codes below.
const int MM_BLOCK_CYLINDER = 40
const int MM_BLOCK_ASYMMETRIC = 41
const int MM_BLOCK_DOUBLE_CIRCLE = 42
const int MM_BLOCK_ARROW = 43

int mm_small_positive(mm_parser* p):
	mm_space(p)
	int value = 0
	int digits = 0
	while (isdigit(mm_peek(p))):
		if (value <= 64): value = value * 10 + mm_peek(p) - '0'
		p.pos = p.pos + 1
		digits = digits + 1
	if (digits == 0 || value < 1 || value > 64): mm_error(p.doc, p.pos, c"expected integer from 1 to 64")
	return value

# `[/label/]`, `[\label\]`, `[/label\]` and `[\label/]`; the opening `[` and
# slant were consumed by the caller.
void mm_block_slanted(mm_parser* p, mm_node* n):
	int opening = p.doc.source[p.pos - 1]
	mm_space(p)
	free(n.label)
	if (mm_peek(p) == '"'):
		n.label = mm_quoted(p)
		mm_space(p)
	else:
		int start = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10):
			if ((mm_peek(p) == '/' || mm_peek(p) == '\\') && p.pos + 1 < p.doc.length && p.doc.source[p.pos + 1] == ']'): break
			p.pos = p.pos + 1
		n.label = mm_style_trim(p.doc.source, start, p.pos)
	int ending = mm_peek(p)
	if (ending != '/' && ending != '\\'): mm_error(p.doc, p.pos, c"expected slanted shape closing delimiter")
	else: p.pos = p.pos + 1
	if (mm_match(p, c"]") == 0): mm_error(p.doc, p.pos, c"expected slanted shape closing bracket")
	n.shape = 24
	if (opening == '\\'): n.shape = 25
	if (opening == '/' && ending == '\\'): n.shape = 26
	if (opening == '\\' && ending == '/'): n.shape = 27

void mm_block_arrow_direction(mm_parser* p, mm_node* n):
	mm_space(p)
	if (mm_match(p, c"(") == 0):
		mm_error(p.doc, p.pos, c"expected block arrow direction right, left, up, down, x or y")
		return
	int at = p.pos
	char* direction = mm_identifier(p)
	mm_space(p)
	if (mm_in_words(direction, c"|right|left|up|down|x|y|") == 0 || mm_match(p, c")") == 0): mm_error(p.doc, at, c"expected block arrow direction right, left, up, down, x or y")
	free(n.direction)
	n.direction = direction

int mm_block_node(mm_parser* p, int parent):
	char* id = mm_identifier(p)
	int index = mm_add_node(p.doc, id, p.pos)
	free(id)
	if (index < 0): return -1
	mm_node* n = p.doc.nodes[index]
	if (n.declared == 0):
		n.parent = parent
		n.value_x = 1
		n.declared = 1
	mm_space(p)
	int close = 0
	int extra = 0
	int third = 0
	if (mm_match(p, c"(((")):
		close = ')'
		extra = ')'
		third = ')'
		n.shape = MM_BLOCK_DOUBLE_CIRCLE
	else if (mm_match(p, c"((")):
		close = ')'
		extra = ')'
		n.shape = 2
	else if (mm_match(p, c"([")):
		close = ']'
		extra = ')'
		n.shape = 21
	else if (mm_match(p, c"(")):
		close = ')'
		n.shape = 1
	else if (mm_match(p, c"[[")):
		close = ']'
		extra = ']'
		n.shape = 22
	else if (mm_match(p, c"[(")):
		close = ')'
		extra = ']'
		n.shape = MM_BLOCK_CYLINDER
	else if (mm_match(p, c"[/") || mm_match(p, c"[\\")): mm_block_slanted(p, n)
	else if (mm_match(p, c"[")):
		close = ']'
		n.shape = 0
	else if (mm_match(p, c"{{")):
		close = '}'
		extra = '}'
		n.shape = 23
	else if (mm_match(p, c"{")):
		close = '}'
		n.shape = 3
	else if (mm_match(p, c"<[")):
		close = ']'
		extra = '>'
		n.shape = MM_BLOCK_ARROW
	else if (mm_peek(p) == '>' && (p.pos + 1 >= p.doc.length || p.doc.source[p.pos + 1] != '>')):
		p.pos = p.pos + 1
		close = ']'
		n.shape = MM_BLOCK_ASYMMETRIC
	if (close):
		free(n.label)
		n.label = mm_until(p, close)
		if (extra):
			if (mm_peek(p) != extra): mm_error(p.doc, p.pos, c"expected second closing shape delimiter")
			else: p.pos = p.pos + 1
		if (third && mm_match(p, c")") == 0): mm_error(p.doc, p.pos, c"expected closing circle parenthesis")
		if (n.shape == MM_BLOCK_ARROW): mm_block_arrow_direction(p, n)
	mm_space(p)
	if (mm_match(p, c":::")): mm_style_inline(p, n)
	mm_space(p)
	if (mm_match(p, c":")): n.value_x = mm_small_positive(p)
	return index

void mm_block_body(mm_parser* p, int parent, int depth):
	if (depth >= 32):
		mm_error(p.doc, p.pos, c"block nesting limit exceeded")
		return
	mm_node* group = p.doc.nodes[parent]
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_metadata(p) || mm_style_statement(p)):
			mm_separators(p)
			continue
		if (mm_keyword(p, c"end")):
			if (depth == 0): mm_error(p.doc, p.pos, c"unexpected block end")
			return
		if (mm_keyword(p, c"columns")):
			if (group.value_x != 0): mm_error(p.doc, p.pos, c"duplicate column declaration")
			group.value_x = mm_small_positive(p)
		else if (mm_keyword(p, c"block")):
			mm_space(p)
			char* id
			if (mm_match(p, c":")): id = mm_identifier(p)
			else:
				string_builder* text = string_from(c"@block:")
				string_append_int(text, p.doc.nodes.length)
				id = strclone(text.data)
				string_free(text)
			int previous = mm_find_node(p.doc, id)
			int index = mm_add_node(p.doc, id, p.pos)
			free(id)
			if (index < 0): return
			mm_node* n = p.doc.nodes[index]
			if (previous >= 0 && n.declared): mm_error(p.doc, p.pos, c"duplicate composite block")
			n.group = 1
			n.declared = 1
			n.parent = parent
			free(n.label)
			n.label = strclone(c"")
			mm_separators(p)
			mm_block_body(p, index, depth + 1)
		else if (mm_keyword(p, c"space")):
			string_builder* id = string_from(c"@space:")
			string_append_int(id, p.doc.nodes.length)
			int index = mm_add_node(p.doc, id.data, p.pos)
			string_free(id)
			if (index < 0): return
			mm_node* n = p.doc.nodes[index]
			n.shape = -1
			n.parent = parent
			n.value_x = 1
			free(n.label)
			n.label = strclone(c"")
			mm_space(p)
			if (mm_match(p, c":")): n.value_x = mm_small_positive(p)
		else:
			int from = mm_block_node(p, parent)
			mm_space(p)
			int arrow = mm_match(p, c"-->")
			int line = arrow || mm_match(p, c"---")
			if (line && p.doc.error == 0):
				char* label = strclone(c"")
				mm_space(p)
				if (mm_match(p, c"|")):
					free(label)
					label = mm_until(p, '|')
				int to = mm_block_node(p, parent)
				if (p.doc.edges.length >= MM_MAX_ITEMS): mm_error(p.doc, p.pos, c"block edge limit exceeded")
				if (p.doc.error == 0):
					mm_edge* e = new mm_edge()
					e.from_node = from
					e.to_node = to
					e.label = strclone(label)
					e.arrow = arrow
					p.doc.edges.push(e)
				free(label)
		mm_separators(p)
	if (depth > 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"unterminated composite block")

void mm_blocks_parse(mm_parser* p):
	int root = mm_add_node(p.doc, c"@block:root", p.pos)
	mm_node* group = p.doc.nodes[root]
	group.group = 1
	group.declared = 1
	group.shape = -1
	free(group.label)
	group.label = strclone(c"")
	mm_block_body(p, root, 0)
	for mm_node* n in p.doc.nodes:
		if (n.declared == 0 && n.shape != -1): mm_error(p.doc, p.pos, c"style references undeclared block")
		if (n.parent >= 0 && n.group == 0):
			mm_node* parent = p.doc.nodes[n.parent]
			if (parent.value_x > 0 && n.value_x > parent.value_x): mm_error(p.doc, p.pos, c"block span exceeds parent columns")

void mm_blocks_measure(mm_document* d, mm_scene* s, int parent):
	mm_node* group = d.nodes[parent]
	mm_bounds* box = s.nodes[parent]
	int columns = group.value_x
	if (columns == 0):
		for mm_node* n in d.nodes:
			if (n.parent == parent): columns = columns + 1
		if (columns > 64): columns = 64
		if (columns == 0): columns = 1
	list[int] widths = new list[int]
	for i in range(columns): widths.push(180)
	int col = 0
	int row = 0
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != parent): continue
		mm_bounds* b = s.nodes[i]
		if (n.group): mm_blocks_measure(d, s, i)
		else:
			b.w = strlen(n.label) * 8 + 40
			b.h = 60
			if (n.shape == 2 || n.shape == MM_BLOCK_DOUBLE_CIRCLE): b.h = b.w
			if (n.shape == 3 || n.shape == 23): b.w = b.w + 40
			if (n.shape == 3): b.h = 80
			if (n.shape == MM_BLOCK_ARROW):
				b.w = b.w + 60
				if (strcmp(n.direction, c"up") == 0 || strcmp(n.direction, c"down") == 0 || strcmp(n.direction, c"y") == 0): b.h = 100
		int span = n.value_x
		if (n.group || span == 0): span = 1
		if (span > columns): span = columns
		if (col + span > columns):
			col = 0
			row = row + 1
		b.x = col
		b.y = span
		b.rank = row
		int available = (span - 1) * 40
		for j in range(col, col + span): available = available + widths[j]
		if (b.w > available): widths[col] = widths[col] + b.w - available
		col = col + span
	list[int] heights = new list[int]
	for i in range(row + 1): heights.push(60)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != parent): continue
		mm_bounds* b = s.nodes[i]
		if (b.h > heights[b.rank]): heights[b.rank] = b.h
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != parent): continue
		mm_bounds* b = s.nodes[i]
		int offset = 24
		for j in range(b.x): offset = offset + widths[j] + 40
		int width = 0
		for j in range(b.x, b.x + b.y): width = width + widths[j] + 40
		b.x = offset
		b.w = width - 40
		b.y = 24
		for j in range(b.rank): b.y = b.y + heights[j] + 40
		b.h = heights[b.rank]
	box.w = 8
	for int width in widths: box.w = box.w + width + 40
	box.h = 8
	for int height in heights: box.h = box.h + height + 40
	__w_list_free(cast(__w_list*, widths))
	__w_list_free(cast(__w_list*, heights))

void mm_blocks_absolute(mm_document* d, mm_scene* s, int parent, int x, int y):
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != parent): continue
		mm_bounds* b = s.nodes[i]
		b.x = b.x + x
		b.y = b.y + y
		if (n.group): mm_blocks_absolute(d, s, i, b.x, b.y)

void mm_blocks_polygon(mm_scene* s, mm_bounds* b, list[int] points):
	mm_draw(s, MM_POLYGON, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
	mm_primitive* polygon = s.items[s.items.length - 1]
	polygon.points = points

list[int] mm_blocks_arrow_points(char* direction, int x, int y, int w, int h):
	if (strcmp(direction, c"left") == 0):
		int head = h / 2
		return list[int]{x + w, y + h / 4, x + head, y + h / 4, x + head, y, x, y + h / 2, x + head, y + h, x + head, y + h * 3 / 4, x + w, y + h * 3 / 4}
	if (strcmp(direction, c"x") == 0):
		int head = h / 2
		return list[int]{x, y + h / 2, x + head, y, x + head, y + h / 4, x + w - head, y + h / 4, x + w - head, y, x + w, y + h / 2, x + w - head, y + h, x + w - head, y + h * 3 / 4, x + head, y + h * 3 / 4, x + head, y + h}
	if (strcmp(direction, c"up") == 0):
		int head = w / 3
		if (head > h / 2): head = h / 2
		return list[int]{x + w / 4, y + h, x + w / 4, y + head, x, y + head, x + w / 2, y, x + w, y + head, x + w * 3 / 4, y + head, x + w * 3 / 4, y + h}
	if (strcmp(direction, c"down") == 0):
		int head = w / 3
		if (head > h / 2): head = h / 2
		return list[int]{x + w / 4, y, x + w * 3 / 4, y, x + w * 3 / 4, y + h - head, x + w, y + h - head, x + w / 2, y + h, x, y + h - head, x + w / 4, y + h - head}
	if (strcmp(direction, c"y") == 0):
		int head = w / 3
		if (head > h / 3): head = h / 3
		return list[int]{x + w / 2, y, x + w, y + head, x + w * 3 / 4, y + head, x + w * 3 / 4, y + h - head, x + w, y + h - head, x + w / 2, y + h, x, y + h - head, x + w / 4, y + h - head, x + w / 4, y + head, x, y + head}
	int head = h / 2
	return list[int]{x, y + h / 4, x + w - head, y + h / 4, x + w - head, y, x + w, y + h / 2, x + w - head, y + h, x + w - head, y + h * 3 / 4, x, y + h * 3 / 4}

void mm_blocks_shape(mm_scene* s, mm_node* n, mm_bounds* b):
	int x = b.x
	int y = b.y
	int w = b.w
	int h = b.h
	if (n.shape == 2 || n.shape == MM_BLOCK_DOUBLE_CIRCLE):
		mm_ellipse(s, x + w / 2, y + h / 2, w / 2, h / 2)
		if (n.shape == MM_BLOCK_DOUBLE_CIRCLE && w > 16 && h > 16): mm_ellipse(s, x + w / 2, y + h / 2, w / 2 - 6, h / 2 - 6)
	else if (n.shape == 21):
		mm_draw(s, MM_BOX, x, y, x + w, y + h, 0, c"")
		mm_primitive* box = s.items[s.items.length - 1]
		box.dashed = 3
	else if (n.shape == 22):
		mm_draw(s, MM_BOX, x, y, x + w, y + h, 0, c"")
		mm_line(s, x + 10, y, x + 10, y + h, 0)
		mm_line(s, x + w - 10, y, x + w - 10, y + h, 0)
	else if (n.shape == 3): mm_blocks_polygon(s, b, list[int]{x + w / 2, y, x + w, y + h / 2, x + w / 2, y + h, x, y + h / 2})
	else if (n.shape == 23): mm_blocks_polygon(s, b, list[int]{x + 20, y, x + w - 20, y, x + w, y + h / 2, x + w - 20, y + h, x + 20, y + h, x, y + h / 2})
	else if (n.shape >= 24 && n.shape <= 27):
		int tl = 0
		int tr = 0
		int bl = 0
		int br = 0
		if (n.shape == 24 || n.shape == 26): tl = 20
		if (n.shape == 25 || n.shape == 26): tr = 20
		if (n.shape == 25 || n.shape == 27): bl = 20
		if (n.shape == 24 || n.shape == 27): br = 20
		mm_blocks_polygon(s, b, list[int]{x + tl, y, x + w - tr, y, x + w - br, y + h, x + bl, y + h})
	else if (n.shape == MM_BLOCK_ASYMMETRIC): mm_blocks_polygon(s, b, list[int]{x, y, x + w, y, x + w, y + h, x, y + h, x + 20, y + h / 2})
	else if (n.shape == MM_BLOCK_ARROW): mm_blocks_polygon(s, b, mm_blocks_arrow_points(n.direction, x, y, w, h))
	else if (n.shape == MM_BLOCK_CYLINDER):
		# Filled outline (upper rim, sides, lower rim), then the visible front lip.
		int rx = w / 2
		int ry = 8
		int cx = x + rx
		list[int] points = new list[int]
		for i in range(17):
			float angle = 3.14159265 + cast(float, i) * 3.14159265 / 16.0
			points.push(cx + cast(int, fcos(angle) * cast(float, rx)))
			points.push(y + ry + cast(int, fsin(angle) * cast(float, ry)))
		for i in range(17):
			float angle = cast(float, i) * 3.14159265 / 16.0
			points.push(cx + cast(int, fcos(angle) * cast(float, rx)))
			points.push(y + h - ry + cast(int, fsin(angle) * cast(float, ry)))
		mm_blocks_polygon(s, b, points)
		int px = x
		int py = y + ry
		for i in range(1, 17):
			float angle = cast(float, i) * 3.14159265 / 16.0
			int nx = cx - cast(int, fcos(angle) * cast(float, rx))
			int ny = y + ry + cast(int, fsin(angle) * cast(float, ry))
			mm_line(s, px, py, nx, ny, 0)
			px = nx
			py = ny
	else: mm_draw(s, MM_BOX, x, y, x + w, y + h, n.shape == 1, c"")

mm_scene* mm_blocks_render(mm_document* d):
	mm_scene* s = mm_framework_scene(d)
	mm_blocks_measure(d, s, 0)
	mm_blocks_absolute(d, s, 0, 40, 40)
	mm_bounds* root = s.nodes[0]
	s.width = root.w + 80
	s.height = root.h + 80
	for i in range(1, d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		if (n.shape == -1): continue
		int style_start = s.items.length
		mm_blocks_shape(s, n, b)
		if (n.group == 0): mm_text(s, b.x + (b.w - strlen(n.label) * 8) / 2, b.y + (b.h - 16) / 2, n.label)
		mm_style_node(d, s, n, style_start)
	for mm_edge* e in d.edges:
		mm_bounds* a = s.nodes[e.from_node]
		mm_bounds* b = s.nodes[e.to_node]
		int ax = a.x + a.w / 2
		int ay = a.y + a.h / 2
		int bx = b.x + b.w / 2
		int by = b.y + b.h / 2
		if (b.x >= a.x + a.w):
			ax = a.x + a.w
			bx = b.x
		else if (a.x >= b.x + b.w):
			ax = a.x
			bx = b.x + b.w
		else if (b.y >= a.y + a.h):
			ay = a.y + a.h
			by = b.y
		else:
			ay = a.y
			by = b.y + b.h
		int style_start = s.items.length
		if (e.arrow): mm_framework_arrow(s, ax, ay, bx, by, 0)
		else: mm_line(s, ax, ay, bx, by, 0)
		mm_text(s, (ax + bx) / 2, (ay + by) / 2 - 20, e.label)
		for i in range(style_start, s.items.length):
			mm_primitive* primitive = s.items[i]
			mm_style_merge(&primitive.style, &d.edge_style)
			mm_style_merge(&primitive.style, &e.style)
	return s
