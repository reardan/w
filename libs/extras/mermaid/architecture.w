# Architecture (`architecture-beta`): services, groups, junctions, ports,
# `{group}` edge endpoints, `align row|column` directives and icon packs.
#
# Placement follows the upstream spatial model: every edge's port pair
# places its endpoints on a grid relative to each other (`a:R -- L:b` puts
# b to the right of a, `a:T -- L:b` above and to the right), alignment
# directives pin members to one row or column in their declared order, and
# each group is laid out as a grid of its own children. Icon packs
# (`pack:name`) are never fetched: they render as the closest built-in glyph
# when the icon name says what it is, otherwise as the unknown-icon tile.
import libs.extras.mermaid.frameworks
import libs.extras.mermaid.framework_render
import libs.extras.mermaid.style
import libs.extras.mermaid.text

# Port values 1 L, 2 R, 3 T, 4 B; MM_ARCH_GROUP marks a `{group}` endpoint.
const int MM_ARCH_GROUP = 8
const int MM_ARCH_GAP = 80

int mm_system_node(mm_parser* p):
	char* id = mm_identifier(p)
	int index = mm_add_node(p.doc, id, p.pos)
	free(id)
	return index

void mm_system_parent(mm_parser* p, mm_node* n):
	mm_space(p)
	if (mm_keyword(p, c"in")):
		int parent = mm_system_node(p)
		if (parent >= 0): n.parent = parent

int mm_arch_port(mm_parser* p):
	char* port = mm_identifier(p)
	int value = 0
	if (strcmp(port, c"L") == 0): value = 1
	else if (strcmp(port, c"R") == 0): value = 2
	else if (strcmp(port, c"T") == 0): value = 3
	else if (strcmp(port, c"B") == 0): value = 4
	else: mm_error(p.doc, p.pos, c"expected architecture port L, R, T or B")
	free(port)
	return value

int mm_arch_group_modifier(mm_parser* p):
	return mm_match(p, c"{group}")

int mm_arch_icon_char(int c):
	return isalnum(c) || c == '-' || c == '_' || c == '.'

# Built-in names, or an iconify-style `pack:name` reference.
int mm_arch_icon_valid(char* icon):
	if (mm_in_words(icon, c"|cloud|database|disk|server|internet|")): return 1
	int colon = index_of(icon, c":")
	if (colon <= 0 || icon[colon + 1] == 0): return 0
	for i in range(strlen(icon)):
		if (i != colon && mm_arch_icon_char(icon[i] & 255) == 0): return 0
	return 1

# Glyph drawn for an icon: a built-in name, or "" for the unknown-icon tile.
char* mm_arch_glyph(char* icon):
	if (mm_in_words(icon, c"|cloud|database|disk|server|internet|")): return icon
	if (icon[0] == 0): return c""
	char* name = icon + index_of(icon, c":") + 1
	list[char*] words = list[char*]{c"database", c"db", c"sql", c"aurora", c"rds", c"dynamo", c"mongo", c"redis", c"disk", c"storage", c"s3", c"glacier", c"bucket", c"volume", c"server", c"ec2", c"lambda", c"compute", c"container", c"docker", c"kubernetes", c"internet", c"gateway", c"globe", c"network", c"cdn", c"cloud"}
	list[char*] glyphs = list[char*]{c"database", c"database", c"database", c"database", c"database", c"database", c"database", c"database", c"disk", c"disk", c"disk", c"disk", c"disk", c"disk", c"server", c"server", c"server", c"server", c"server", c"server", c"server", c"internet", c"internet", c"internet", c"internet", c"internet", c"cloud"}
	char* result = c""
	for i in range(words.length):
		if (result[0] == 0 && index_of(name, words[i]) >= 0): result = glyphs[i]
	__w_list_free(cast(__w_list*, words))
	__w_list_free(cast(__w_list*, glyphs))
	return result

void mm_arch_align(mm_parser* p):
	mm_space(p)
	int axis = -1
	if (mm_keyword(p, c"row")): axis = 0
	else if (mm_keyword(p, c"column")): axis = 1
	else:
		mm_error(p.doc, p.pos, c"expected align row or align column")
		return
	if (p.doc.arch_align == 0): p.doc.arch_align = new list[int]
	list[int] align = p.doc.arch_align
	int header = align.length
	align.push(axis)
	align.push(0)
	while (mm_end(p) == 0 && p.doc.error == 0):
		if (align.length >= MM_MAX_ITEMS * 4):
			mm_error(p.doc, p.pos, c"architecture alignment limit exceeded")
			return
		int start = p.pos
		char* id = mm_identifier(p)
		int index = mm_find_node(p.doc, id)
		free(id)
		if (index < 0):
			mm_error(p.doc, start, c"align members must be declared services or junctions")
			return
		mm_node* n = p.doc.nodes[index]
		if (n.group): mm_error(p.doc, start, c"align members must be declared services or junctions")
		for i in range(header + 2, align.length):
			if (align[i] == index): mm_error(p.doc, start, c"duplicate align member")
		align.push(index)
		align[header + 1] = align[header + 1] + 1
	if (align[header + 1] < 2): mm_error(p.doc, p.pos, c"align needs at least two members")

void mm_arch_edge_parse(mm_parser* p, char* word):
	int from = mm_add_node(p.doc, word, p.pos)
	int from_group = mm_arch_group_modifier(p)
	mm_space(p)
	if (mm_match(p, c":") == 0): mm_error(p.doc, p.pos, c"expected architecture source port")
	int from_port = mm_arch_port(p)
	mm_space(p)
	int left = mm_match(p, c"<")
	if (mm_match(p, c"--") == 0): mm_error(p.doc, p.pos, c"expected architecture edge --")
	int right = mm_match(p, c">")
	mm_space(p)
	int to_port = mm_arch_port(p)
	if (mm_match(p, c":") == 0): mm_error(p.doc, p.pos, c"expected target port colon")
	int to = mm_system_node(p)
	int to_group = mm_arch_group_modifier(p)
	if (p.doc.edges.length >= MM_MAX_ITEMS): mm_error(p.doc, p.pos, c"architecture edge limit exceeded")
	if (p.doc.error == 0):
		mm_edge* e = new mm_edge()
		e.from_node = from
		e.to_node = to
		e.from_port = from_port
		e.to_port = to_port
		if (from_group): e.from_port = from_port | MM_ARCH_GROUP
		if (to_group): e.to_port = to_port | MM_ARCH_GROUP
		e.left_marker = left
		e.right_marker = right
		e.label = strclone(c"")
		e.left_label = strclone(c"")
		e.right_label = strclone(c"")
		e.scope = -1
		p.doc.edges.push(e)

void mm_arch_body(mm_parser* p):
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_metadata(p)):
			mm_separators(p)
			continue
		if (mm_keyword(p, c"align")):
			mm_arch_align(p)
			if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported architecture syntax")
			mm_separators(p)
			continue
		char* word = mm_identifier(p)
		if (mm_in_words(word, c"|service|group|junction|")):
			int index = mm_system_node(p)
			if (index < 0):
				free(word)
				return
			mm_node* n = p.doc.nodes[index]
			if (n.declared): mm_error(p.doc, p.pos, c"duplicate architecture identifier")
			n.declared = 1
			n.group = strcmp(word, c"group") == 0
			n.shape = 12
			if (strcmp(word, c"junction") == 0): n.shape = 13
			mm_space(p)
			if (n.shape == 12 && mm_match(p, c"(")):
				free(n.annotation)
				n.annotation = mm_until(p, ')')
				if (mm_arch_icon_valid(n.annotation) == 0): mm_error(p.doc, p.pos, c"unsupported architecture icon; use cloud, database, disk, server, internet or pack:name")
			mm_space(p)
			if (n.shape == 12 && mm_match(p, c"[")):
				free(n.label)
				n.label = mm_until(p, ']')
			mm_system_parent(p, n)
		else: mm_arch_edge_parse(p, word)
		free(word)
		if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported architecture syntax")
		mm_separators(p)
	for i in range(p.doc.nodes.length):
		mm_node* n = p.doc.nodes[i]
		if (n.declared == 0): mm_error(p.doc, p.pos, c"undeclared architecture service or group")
		int ancestor = n.parent
		int depth = 0
		while (ancestor >= 0 && p.doc.error == 0):
			mm_node* parent = p.doc.nodes[ancestor]
			if (parent.group == 0): mm_error(p.doc, p.pos, c"architecture parent must be a group")
			if (ancestor == i || depth >= 32): mm_error(p.doc, p.pos, c"cyclic or excessively nested architecture group")
			ancestor = parent.parent
			depth = depth + 1
	for mm_edge* e in p.doc.edges:
		mm_node* from = p.doc.nodes[e.from_node]
		mm_node* to = p.doc.nodes[e.to_node]
		if (from.group || to.group): mm_error(p.doc, p.pos, c"architecture edges need service or junction endpoints")
		if ((e.from_port & MM_ARCH_GROUP) && (from.parent < 0 || from.shape != 12)): mm_error(p.doc, p.pos, c"{group} applies only to services inside a group")
		if ((e.to_port & MM_ARCH_GROUP) && (to.parent < 0 || to.shape != 12)): mm_error(p.doc, p.pos, c"{group} applies only to services inside a group")

# Grid step from an edge's port pair: the source side gives the primary axis,
# an orthogonal target side the secondary one.
void mm_arch_delta(int from_port, int to_port, int* dx, int* dy):
	int a = from_port & 7
	int b = to_port & 7
	*dx = 0
	*dy = 0
	if (a == 1): *dx = -1
	if (a == 2): *dx = 1
	if (a == 3): *dy = -1
	if (a == 4): *dy = 1
	if (a <= 2 && b == 3): *dy = 1
	if (a <= 2 && b == 4): *dy = -1
	if (a >= 3 && b == 1): *dx = 1
	if (a >= 3 && b == 2): *dx = -1

# Direct child of scope containing index, or -1 outside this scope.
int mm_arch_child(mm_document* d, int index, int scope):
	while (index >= 0):
		mm_node* n = d.nodes[index]
		if (n.parent == scope): return index
		index = n.parent
	return -1

int mm_arch_occupied(list[int] placed, list[int] cols, list[int] rows, int col, int row):
	for i in range(placed.length):
		if (placed[i] && cols[i] == col && rows[i] == row): return 1
	return 0

void mm_arch_put(list[int] placed, list[int] cols, list[int] rows, int k, int col, int row, int dx, int dy):
	if (dx == 0 && dy == 0): dx = 1
	int guard = 0
	while (mm_arch_occupied(placed, cols, rows, col, row) && guard <= placed.length):
		col = col + dx
		row = row + dy
		guard = guard + 1
	placed[k] = 1
	cols[k] = col
	rows[k] = row

# Sorted distinct values.
list[int] mm_arch_distinct(list[int] values):
	list[int] out = new list[int]
	for int v in values:
		int at = 0
		int seen = 0
		while (at < out.length && out[at] <= v):
			if (out[at] == v): seen = 1
			at = at + 1
		if (seen == 0):
			out.push(0)
			int j = out.length - 1
			while (j > at):
				out[j] = out[j - 1]
				j = j - 1
			out[at] = v
	return out

int mm_arch_rank(list[int] distinct, int value):
	for i in range(distinct.length):
		if (distinct[i] == value): return i
	return 0

# Offset of node inside the scope's child that contains it (positions are
# still relative to each parent at this point).
int mm_arch_within(mm_document* d, mm_scene* s, int index, int scope, int vertical):
	int total = 0
	while (index >= 0):
		mm_node* n = d.nodes[index]
		if (n.parent == scope): return total
		mm_bounds* b = s.nodes[index]
		if (vertical): total = total + b.y
		else: total = total + b.x
		index = n.parent
	return total

int mm_arch_overlaps(mm_scene* s, list[int] kids, int moved):
	mm_bounds* a = s.nodes[moved]
	for int k in kids:
		if (k == moved): continue
		mm_bounds* b = s.nodes[k]
		if (a.x < b.x + b.w + 20 && a.x + a.w + 20 > b.x && a.y < b.y + b.h + 20 && a.y + a.h + 20 > b.y): return 1
	return 0

# Alignment across groups: when consecutive align members sit in different
# children of this scope, shift the later child along the free axis so the
# members line up, unless that would make it overlap a sibling.
void mm_arch_cross_align(mm_document* d, mm_scene* s, int scope, list[int] kids, list[int] local):
	if (d.arch_align == 0): return
	list[int] moved = new list[int]
	list[int] align = d.arch_align
	int at = 0
	while (at + 1 < align.length):
		int axis = align[at]
		int count = align[at + 1]
		for j in range(1, count):
			int first = align[at + 1 + j]
			int second = align[at + 2 + j]
			int ca = mm_arch_child(d, first, scope)
			int cb = mm_arch_child(d, second, scope)
			if (ca < 0 || cb < 0 || ca == cb || local[cb] < 0): continue
			if (d.nodes[cb].group == 0): continue
			int seen = 0
			for int m in moved:
				if (m == cb): seen = 1
			if (seen): continue
			mm_bounds* a = s.nodes[first]
			mm_bounds* b = s.nodes[second]
			mm_bounds* box = s.nodes[cb]
			int vertical = axis == 0
			int delta = 0
			if (vertical): delta = s.nodes[ca].y + mm_arch_within(d, s, first, scope, 1) - box.y - mm_arch_within(d, s, second, scope, 1)
			else: delta = s.nodes[ca].x + mm_arch_within(d, s, first, scope, 0) + a.w / 2 - box.x - mm_arch_within(d, s, second, scope, 0) - b.w / 2
			if (delta == 0): continue
			if (vertical): box.y = box.y + delta
			else: box.x = box.x + delta
			if (mm_arch_overlaps(s, kids, cb)):
				if (vertical): box.y = box.y - delta
				else: box.x = box.x - delta
			else: moved.push(cb)
		at = at + 2 + count
	__w_list_free(cast(__w_list*, moved))

int mm_arch_gap(mm_document* d):
	if (d.config_mask & 1): return d.node_spacing
	return MM_ARCH_GAP

# Lays the children of scope out on a grid, relative to the scope origin;
# groups are laid out first so their sizes are known.
void mm_arch_scope(mm_document* d, mm_scene* s, int scope):
	list[int] kids = new list[int]
	list[int] local = new list[int]
	for i in range(d.nodes.length):
		local.push(-1)
		mm_node* n = d.nodes[i]
		if (n.parent == scope):
			if (n.group): mm_arch_scope(d, s, i)
			local[i] = kids.length
			kids.push(i)
	list[int] ca = new list[int]
	list[int] cb = new list[int]
	list[int] cdx = new list[int]
	list[int] cdy = new list[int]
	list[int] strong = new list[int]
	if (d.arch_align != 0):
		list[int] align = d.arch_align
		int at = 0
		while (at + 1 < align.length):
			int axis = align[at]
			int count = align[at + 1]
			int previous = -1
			for j in range(count):
				int child = mm_arch_child(d, align[at + 2 + j], scope)
				if (child < 0): continue
				int k = local[child]
				if (previous >= 0 && previous != k):
					ca.push(previous)
					cb.push(k)
					cdx.push(1 - axis)
					cdy.push(axis)
					strong.push(1)
				previous = k
			at = at + 2 + count
	for mm_edge* e in d.edges:
		int a = mm_arch_child(d, e.from_node, scope)
		int b = mm_arch_child(d, e.to_node, scope)
		if (a < 0 || b < 0 || a == b): continue
		int dx = 0
		int dy = 0
		mm_arch_delta(e.from_port, e.to_port, &dx, &dy)
		ca.push(local[a])
		cb.push(local[b])
		cdx.push(dx)
		cdy.push(dy)
		strong.push(0)
	list[int] placed = new list[int]
	list[int] cols = new list[int]
	list[int] rows = new list[int]
	for i in range(kids.length):
		placed.push(0)
		cols.push(0)
		rows.push(0)
	list[int] qa = new list[int]
	list[int] qe = new list[int]
	int ha = 0
	int he = 0
	int placed_count = 0
	while (placed_count < kids.length):
		int u = -1
		int pass_strong = 1
		if (ha < qa.length):
			u = qa[ha]
			ha = ha + 1
		else if (he < qe.length):
			u = qe[he]
			he = he + 1
			pass_strong = 0
		if (u < 0):
			int seed = -1
			for k in range(kids.length):
				if (seed < 0 && placed[k] == 0): seed = k
			int col = 0
			for k in range(kids.length):
				if (placed[k] && cols[k] + 1 > col): col = cols[k] + 1
			mm_arch_put(placed, cols, rows, seed, col, 0, 1, 0)
			placed_count = placed_count + 1
			qa.push(seed)
			qe.push(seed)
			continue
		for c in range(ca.length):
			if (strong[c] != pass_strong): continue
			int other = -1
			int sign = 1
			if (ca[c] == u && placed[cb[c]] == 0): other = cb[c]
			else if (cb[c] == u && placed[ca[c]] == 0):
				other = ca[c]
				sign = -1
			if (other < 0): continue
			mm_arch_put(placed, cols, rows, other, cols[u] + cdx[c] * sign, rows[u] + cdy[c] * sign, cdx[c] * sign, cdy[c] * sign)
			placed_count = placed_count + 1
			qa.push(other)
			qe.push(other)
	list[int] distinct_cols = mm_arch_distinct(cols)
	list[int] distinct_rows = mm_arch_distinct(rows)
	list[int] widths = new list[int]
	list[int] heights = new list[int]
	for i in range(distinct_cols.length): widths.push(0)
	for i in range(distinct_rows.length): heights.push(0)
	for k in range(kids.length):
		mm_bounds* b = s.nodes[kids[k]]
		int c = mm_arch_rank(distinct_cols, cols[k])
		int r = mm_arch_rank(distinct_rows, rows[k])
		if (b.w > widths[c]): widths[c] = b.w
		if (b.h > heights[r]): heights[r] = b.h
	int gap = mm_arch_gap(d)
	list[int] xs = new list[int]
	list[int] ys = new list[int]
	int x = 0
	for int w in widths:
		xs.push(x)
		x = x + w + gap
	int y = 0
	for int h in heights:
		ys.push(y)
		y = y + h + gap
	int content_w = x - gap
	int content_h = y - gap
	int pad_x = 0
	int pad_y = 0
	if (scope >= 0):
		mm_text_block* title = mm_text_layout(d.nodes[scope].label, 0)
		pad_x = 30
		pad_y = 60 + title.height - MM_TEXT_LINE
		mm_text_block_free(title)
	for k in range(kids.length):
		mm_bounds* b = s.nodes[kids[k]]
		int c = mm_arch_rank(distinct_cols, cols[k])
		int r = mm_arch_rank(distinct_rows, rows[k])
		b.x = pad_x + xs[c] + (widths[c] - b.w) / 2
		b.y = pad_y + ys[r]
	mm_arch_cross_align(d, s, scope, kids, local)
	int min_x = 1000000000
	int max_x = 0
	int min_y = 1000000000
	int max_y = 0
	for int k in kids:
		mm_bounds* b = s.nodes[k]
		if (b.x < min_x): min_x = b.x
		if (b.y < min_y): min_y = b.y
		if (b.x + b.w > max_x): max_x = b.x + b.w
		if (b.y + b.h > max_y): max_y = b.y + b.h
	if (kids.length != 0):
		for int k in kids:
			mm_bounds* b = s.nodes[k]
			b.x = b.x - min_x + pad_x
			b.y = b.y - min_y + pad_y
		content_w = max_x - min_x
		content_h = max_y - min_y
	if (scope >= 0):
		mm_bounds* box = s.nodes[scope]
		if (kids.length == 0):
			content_w = 0
			content_h = 0
		if (content_w + pad_x * 2 > box.w): box.w = content_w + pad_x * 2
		box.h = pad_y + content_h + 30
	__w_list_free(cast(__w_list*, kids))
	__w_list_free(cast(__w_list*, local))
	__w_list_free(cast(__w_list*, ca))
	__w_list_free(cast(__w_list*, cb))
	__w_list_free(cast(__w_list*, cdx))
	__w_list_free(cast(__w_list*, cdy))
	__w_list_free(cast(__w_list*, strong))
	__w_list_free(cast(__w_list*, placed))
	__w_list_free(cast(__w_list*, cols))
	__w_list_free(cast(__w_list*, rows))
	__w_list_free(cast(__w_list*, qa))
	__w_list_free(cast(__w_list*, qe))
	__w_list_free(cast(__w_list*, distinct_cols))
	__w_list_free(cast(__w_list*, distinct_rows))
	__w_list_free(cast(__w_list*, widths))
	__w_list_free(cast(__w_list*, heights))
	__w_list_free(cast(__w_list*, xs))
	__w_list_free(cast(__w_list*, ys))

void mm_arch_absolute(mm_document* d, mm_scene* s, int scope, int x, int y):
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != scope): continue
		mm_bounds* b = s.nodes[i]
		b.x = b.x + x
		b.y = b.y + y
		if (n.group): mm_arch_absolute(d, s, i, b.x, b.y)

# Called with measured bounds; replaces the layered placement.
void mm_arch_layout(mm_document* d, mm_scene* s):
	mm_arch_scope(d, s, -1)
	mm_arch_absolute(d, s, -1, 40, 40)

void mm_arch_glyph_draw(mm_scene* s, char* glyph, int x, int y):
	if (strcmp(glyph, c"database") == 0):
		mm_ellipse(s, x, y - 18, 28, 9)
		mm_ellipse(s, x, y + 18, 28, 9)
		mm_line(s, x - 28, y - 18, x - 28, y + 18, 0)
		mm_line(s, x + 28, y - 18, x + 28, y + 18, 0)
	else if (strcmp(glyph, c"internet") == 0):
		mm_ellipse(s, x, y, 26, 26)
		mm_ellipse(s, x, y, 12, 26)
		mm_line(s, x - 26, y, x + 26, y, 0)
	else if (strcmp(glyph, c"cloud") == 0):
		mm_ellipse(s, x - 18, y + 5, 17, 17)
		mm_ellipse(s, x, y - 5, 22, 22)
		mm_ellipse(s, x + 20, y + 6, 15, 15)
	else if (glyph[0] == 0):
		# Unknown-icon tile: the icon pack is not bundled.
		mm_draw(s, MM_BOX, x - 28, y - 24, x + 28, y + 24, 1, c"")
		mm_primitive* tile = s.items[s.items.length - 1]
		mm_text(s, x - mm_text_width(c"?", 0) / 2, y - MM_TEXT_LINE / 2, c"?")
	else:
		mm_draw(s, MM_BOX, x - 28, y - 24, x + 28, y + 24, 1, c"")
		if (strcmp(glyph, c"server") == 0):
			for i in range(3): mm_line(s, x - 18, y - 14 + i * 14, x + 18, y - 14 + i * 14, 0)
		else: mm_line(s, x - 18, y + 12, x + 18, y + 12, 0)

void mm_arch_icon(mm_scene* s, mm_node* n, mm_bounds* b):
	int x = b.x + b.w / 2
	int y = b.y + 36
	if (n.shape == 13):
		mm_draw(s, MM_CIRCLE, x - 5, y - 5, x + 5, y + 5, 1, c"")
		return
	char* glyph = mm_arch_glyph(n.annotation)
	if (n.annotation[0] == 0): glyph = c"server-default"
	mm_arch_glyph_draw(s, glyph, x, y)

# Port point of a service icon, a junction centre, or the parent group's
# side for a `{group}` endpoint; *dx/*dy receive the outward direction.
void mm_arch_port_point(mm_document* d, mm_scene* s, int index, int port, int* x, int* y, int* dx, int* dy):
	mm_node* n = d.nodes[index]
	mm_bounds* b = s.nodes[index]
	int cx = b.x + b.w / 2
	int cy = b.y + 36
	int side = port & 7
	int half = 28
	int top = b.y + 12
	int bottom = b.y + b.h
	if (n.shape == 13):
		half = 5
		top = cy - 5
		bottom = cy + 5
	*x = cx
	*y = cy
	*dx = 0
	*dy = 0
	if (side == 1):
		*x = cx - half
		*dx = -1
	if (side == 2):
		*x = cx + half
		*dx = 1
	if (side == 3):
		*y = top
		*dy = -1
	if (side == 4):
		*y = bottom
		*dy = 1
	if ((port & MM_ARCH_GROUP) && n.parent >= 0):
		mm_bounds* g = s.nodes[n.parent]
		if (side == 1): *x = g.x
		if (side == 2): *x = g.x + g.w
		if (side == 3): *y = g.y
		if (side == 4): *y = g.y + g.h

void mm_arch_head(mm_scene* s, int x, int y, int dx, int dy):
	# Arrowhead at (x, y) pointing against the outward direction (dx, dy).
	int px = 0 - dy
	int py = dx
	mm_line(s, x, y, x + dx * 12 + px * 6, y + dy * 12 + py * 6, 0)
	mm_line(s, x, y, x + dx * 12 - px * 6, y + dy * 12 - py * 6, 0)

void mm_arch_edge(mm_document* d, mm_scene* s, mm_edge* e):
	int ax = 0
	int ay = 0
	int adx = 0
	int ady = 0
	int bx = 0
	int by = 0
	int bdx = 0
	int bdy = 0
	mm_arch_port_point(d, s, e.from_node, e.from_port, &ax, &ay, &adx, &ady)
	mm_arch_port_point(d, s, e.to_node, e.to_port, &bx, &by, &bdx, &bdy)
	int routed = 0
	if (adx != 0 && bdx == 0 - adx && (bx - ax) * adx > 0):
		# Facing horizontal ports: straight, or one vertical jog midway.
		int mx = (ax + bx) / 2
		mm_line(s, ax, ay, mx, ay, 0)
		mm_line(s, mx, ay, mx, by, 0)
		mm_line(s, mx, by, bx, by, 0)
		routed = 1
	else if (ady != 0 && bdy == 0 - ady && (by - ay) * ady > 0):
		int my = (ay + by) / 2
		mm_line(s, ax, ay, ax, my, 0)
		mm_line(s, ax, my, bx, my, 0)
		mm_line(s, bx, my, bx, by, 0)
		routed = 1
	else if (adx != 0 && bdy != 0 && (bx - ax) * adx > 0 && (ay - by) * bdy > 0):
		# Horizontal exit into a vertical entry: one 90 degree elbow.
		mm_line(s, ax, ay, bx, ay, 0)
		mm_line(s, bx, ay, bx, by, 0)
		routed = 1
	else if (ady != 0 && bdx != 0 && (by - ay) * ady > 0 && (ax - bx) * bdx > 0):
		mm_line(s, ax, ay, ax, by, 0)
		mm_line(s, ax, by, bx, by, 0)
		routed = 1
	if (routed == 0):
		int sx = ax + adx * 30
		int sy = ay + ady * 30
		int tx = bx + bdx * 30
		int ty = by + bdy * 30
		mm_line(s, ax, ay, sx, sy, 0)
		if (adx != 0):
			mm_line(s, sx, sy, sx, ty, 0)
			mm_line(s, sx, ty, tx, ty, 0)
		else:
			mm_line(s, sx, sy, tx, sy, 0)
			mm_line(s, tx, sy, tx, ty, 0)
		mm_line(s, tx, ty, bx, by, 0)
	if (e.left_marker): mm_arch_head(s, ax, ay, adx, ady)
	if (e.right_marker): mm_arch_head(s, bx, by, bdx, bdy)
