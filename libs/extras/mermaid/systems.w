# Architecture ports/groups and UML use-case actors/boundaries.
import libs.extras.mermaid.frameworks
import libs.extras.mermaid.framework_render

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

void mm_arch_body(mm_parser* p):
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_metadata(p)):
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
			if (mm_match(p, c"(")):
				free(n.annotation)
				n.annotation = mm_until(p, ')')
				if (mm_in_words(n.annotation, c"|cloud|database|disk|server|internet|") == 0): mm_error(p.doc, p.pos, c"unsupported architecture icon")
			mm_space(p)
			if (mm_match(p, c"[")):
				free(n.label)
				n.label = mm_until(p, ']')
			mm_system_parent(p, n)
		else:
			int from = mm_add_node(p.doc, word, p.pos)
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
			if (p.doc.edges.length >= MM_MAX_ITEMS): mm_error(p.doc, p.pos, c"architecture edge limit exceeded")
			if (p.doc.error == 0):
				mm_edge* e = new mm_edge()
				e.from_node = from
				e.to_node = to
				e.from_port = from_port
				e.to_port = to_port
				e.left_marker = left
				e.right_marker = right
				e.label = strclone(c"")
				p.doc.edges.push(e)
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

int mm_usecase_node(mm_parser* p, int parent, int declare):
	int index = mm_system_node(p)
	if (index < 0): return -1
	mm_node* n = p.doc.nodes[index]
	if (n.declared == 0):
		n.shape = 11
		n.parent = parent
	if (declare):
		if (n.declared && n.parent != parent): mm_error(p.doc, p.pos, c"use case already belongs to another boundary")
		n.parent = parent
		n.declared = 1
	mm_space(p)
	int close = 0
	if (mm_match(p, c"(")): close = ')'
	else if (mm_match(p, c"[")):
		close = ']'
		n.shape = 0
	if (close):
		free(n.label)
		n.label = mm_until(p, close)
	return index

void mm_usecase_body(mm_parser* p, int scope):
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_metadata(p)):
			mm_separators(p)
			continue
		if (mm_keyword(p, c"end")):
			if (scope < 0): mm_error(p.doc, p.pos, c"unexpected boundary end")
			return
		if (mm_keyword(p, c"direction")):
			if (scope >= 0): mm_error(p.doc, p.pos, c"direction belongs outside boundaries")
			mm_direction(p)
		else if (mm_keyword(p, c"systemBoundary")):
			if (scope >= 0): mm_error(p.doc, p.pos, c"nested use-case boundaries are unsupported")
			int index = mm_usecase_node(p, -1, 1)
			if (index < 0): return
			mm_node* n = p.doc.nodes[index]
			if (n.group): mm_error(p.doc, p.pos, c"duplicate system boundary")
			n.group = 1
			mm_separators(p)
			if (p.doc.error == 0): mm_usecase_body(p, index)
		else if (mm_keyword(p, c"actor")):
			int index = mm_usecase_node(p, scope, 1)
			if (index < 0): return
			mm_node* n = p.doc.nodes[index]
			n.shape = 10
		else:
			int from = mm_usecase_node(p, scope, 0)
			if (from < 0): return
			mm_space(p)
			int right = 0
			int left = 0
			int dashed = 0
			int edge = 1
			char* label = strclone(c"")
			if (mm_match(p, c"--|>")): right = MM_TRIANGLE
			else if (mm_match(p, c"-->")): right = MM_ARROW
			else if (mm_match(p, c"<--")): left = MM_ARROW
			else if (mm_match(p, c"..>")):
				dashed = 1
				right = MM_ARROW
				mm_space(p)
				if (mm_match(p, c":") == 0): mm_error(p.doc, p.pos, c"expected include or extend relationship colon")
				free(label)
				label = mm_identifier(p)
				if (mm_in_words(label, c"|include|extend|") == 0): mm_error(p.doc, p.pos, c"expected include or extend")
			else if (mm_match(p, c"--") == 0): edge = 0
			if (edge):
				if (scope >= 0): mm_error(p.doc, p.pos, c"relationships belong outside system boundaries")
				int to = mm_usecase_node(p, -1, 0)
				if (p.doc.edges.length >= MM_MAX_ITEMS): mm_error(p.doc, p.pos, c"use-case edge limit exceeded")
				if (p.doc.error == 0):
					mm_edge* e = new mm_edge()
					e.from_node = from
					e.to_node = to
					e.left_marker = left
					e.right_marker = right
					e.dashed = dashed
					e.label = strclone(label)
					e.left_label = strclone(c"")
					e.right_label = strclone(c"")
					e.scope = -1
					p.doc.edges.push(e)
			else:
				mm_node* n = p.doc.nodes[from]
				n.declared = 1
			free(label)
		if (mm_end(p) == 0 || mm_peek(p) == ';'): mm_error(p.doc, p.pos, c"unsupported use-case syntax")
		mm_separators(p)
	if (scope >= 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"unterminated system boundary")
	if (scope < 0):
		for mm_edge* e in p.doc.edges:
			mm_node* a = p.doc.nodes[e.from_node]
			mm_node* b = p.doc.nodes[e.to_node]
			if (a.group || b.group): mm_error(p.doc, p.pos, c"relationships cannot target boundaries")
			if (e.dashed && (a.shape == 10 || b.shape == 10)): mm_error(p.doc, p.pos, c"include and extend require use-case endpoints")
			if (e.right_marker == MM_TRIANGLE && (a.shape == 10) != (b.shape == 10)): mm_error(p.doc, p.pos, c"generalization needs endpoints of the same kind")

void mm_actor_draw(mm_scene* s, mm_bounds* b):
	int x = b.x + b.w / 2
	int y = b.y + 14
	mm_draw(s, MM_CIRCLE, x - 10, y - 10, x + 10, y + 10, 0, c"")
	mm_line(s, x, y + 10, x, y + 44, 0)
	mm_line(s, x - 20, y + 22, x + 20, y + 22, 0)
	mm_line(s, x, y + 44, x - 18, y + 64, 0)
	mm_line(s, x, y + 44, x + 18, y + 64, 0)

void mm_arch_icon(mm_scene* s, mm_node* n, mm_bounds* b):
	int x = b.x + b.w / 2
	int y = b.y + 36
	if (n.shape == 13):
		mm_draw(s, MM_CIRCLE, x - 5, y - 5, x + 5, y + 5, 1, c"")
		return
	if (strcmp(n.annotation, c"database") == 0):
		mm_ellipse(s, x, y - 18, 28, 9)
		mm_ellipse(s, x, y + 18, 28, 9)
		mm_line(s, x - 28, y - 18, x - 28, y + 18, 0)
		mm_line(s, x + 28, y - 18, x + 28, y + 18, 0)
	else if (strcmp(n.annotation, c"internet") == 0):
		mm_ellipse(s, x, y, 26, 26)
		mm_ellipse(s, x, y, 12, 26)
		mm_line(s, x - 26, y, x + 26, y, 0)
	else if (strcmp(n.annotation, c"cloud") == 0):
		mm_ellipse(s, x - 18, y + 5, 17, 17)
		mm_ellipse(s, x, y - 5, 22, 22)
		mm_ellipse(s, x + 20, y + 6, 15, 15)
	else:
		mm_draw(s, MM_BOX, x - 28, y - 24, x + 28, y + 24, 1, c"")
		if (strcmp(n.annotation, c"server") == 0):
			for i in range(3): mm_line(s, x - 18, y - 14 + i * 14, x + 18, y - 14 + i * 14, 0)
		else: mm_line(s, x - 18, y + 12, x + 18, y + 12, 0)

void mm_arch_edge(mm_scene* s, mm_edge* e):
	mm_bounds* a = s.nodes[e.from_node]
	mm_bounds* b = s.nodes[e.to_node]
	int ax = a.x + a.w / 2
	int ay = a.y + a.h / 2
	int bx = b.x + b.w / 2
	int by = b.y + b.h / 2
	int dx = 0
	int dy = 0
	int ex = 0
	int ey = 0
	if (e.from_port == 1):
		ax = a.x
		dx = -1
	if (e.from_port == 2):
		ax = a.x + a.w
		dx = 1
	if (e.from_port == 3):
		ay = a.y
		dy = -1
	if (e.from_port == 4):
		ay = a.y + a.h
		dy = 1
	if (e.to_port == 1):
		bx = b.x
		ex = -1
	if (e.to_port == 2):
		bx = b.x + b.w
		ex = 1
	if (e.to_port == 3):
		by = b.y
		ey = -1
	if (e.to_port == 4):
		by = b.y + b.h
		ey = 1
	int sx = ax + dx * 30
	int sy = ay + dy * 30
	int tx = bx + ex * 30
	int ty = by + ey * 30
	mm_line(s, ax, ay, sx, sy, 0)
	mm_line(s, sx, sy, tx, sy, 0)
	mm_line(s, tx, sy, tx, ty, 0)
	mm_line(s, tx, ty, bx, by, 0)
	if (e.left_marker): mm_framework_arrow(s, sx, sy, ax, ay, 0)
	if (e.right_marker): mm_framework_arrow(s, tx, ty, bx, by, 0)
