# Source-ordered block grids with spans and bounded nested composites.
import libs.extras.mermaid.frameworks
import libs.extras.mermaid.framework_render

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
	int doubled = 0
	if (mm_match(p, c"[")): close = ']'
	else if (mm_match(p, c"((")):
		close = ')'
		doubled = 1
		n.shape = 2
	else if (mm_match(p, c"(")):
		close = ')'
		n.shape = 1
	if (close):
		free(n.label)
		n.label = mm_until(p, close)
		if (doubled && mm_match(p, c")") == 0): mm_error(p.doc, p.pos, c"expected closing circle parenthesis")
	mm_space(p)
	if (mm_match(p, c":")): n.value_x = mm_small_positive(p)
	return index

void mm_block_body(mm_parser* p, int parent, int depth):
	if (depth >= 32):
		mm_error(p.doc, p.pos, c"block nesting limit exceeded")
		return
	mm_node* group = p.doc.nodes[parent]
	while (mm_peek(p) != 0 && p.doc.error == 0):
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
			if (mm_find_node(p.doc, id) >= 0): mm_error(p.doc, p.pos, c"duplicate composite block")
			int index = mm_add_node(p.doc, id, p.pos)
			free(id)
			if (index < 0): return
			mm_node* n = p.doc.nodes[index]
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
			if (n.shape == 2): b.h = b.w
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
		if (n.shape == 2): mm_ellipse(s, b.x + b.w / 2, b.y + b.h / 2, b.w / 2, b.h / 2)
		else: mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, n.shape == 1, c"")
		if (n.group == 0): mm_text(s, b.x + 20, b.y + (b.h - 16) / 2, n.label)
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
		if (e.arrow): mm_framework_arrow(s, ax, ay, bx, by, 0)
		else: mm_line(s, ax, ay, bx, by, 0)
		mm_text(s, (ax + bx) / 2, (ay + by) / 2 - 20, e.label)
	return s
