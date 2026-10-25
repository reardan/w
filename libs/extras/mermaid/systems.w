# UML use-case actors/boundaries; architecture lives in architecture.w.
import libs.extras.mermaid.architecture

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
		if (mm_metadata(p) || mm_style_statement(p)):
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

