# Graph layout and rendering; shared scene primitives live in scene.w.
import libs.extras.mermaid.scene
import libs.extras.mermaid.data_render
import libs.extras.mermaid.hierarchy_render
import libs.extras.mermaid.framework_render
import libs.extras.mermaid.gitgraph
import libs.extras.mermaid.blocks
import libs.extras.mermaid.systems
import libs.extras.mermaid.workflow_render
import libs.extras.mermaid.narrative_render
import libs.extras.mermaid.railroad_render

char* mm_attribute_text(mm_attribute* a):
	string_builder* s = string_from(a.type_name)
	string_append(s, c"  ")
	string_append(s, a.name)
	if (a.keys[0] != 0):
		string_append(s, c"  ")
		string_append(s, a.keys)
	if (a.comment[0] != 0):
		string_append(s, c"  ")
		string_append(s, a.comment)
	char* result = s.data
	free(s)
	return result

char* mm_scope_direction(mm_document* d, int scope):
	while (scope >= 0):
		mm_node* n = d.nodes[scope]
		if (n.direction[0] != 0): return n.direction
		scope = n.parent
	return d.direction

void mm_measure(mm_document* d, mm_scene* s):
	for mm_node* n in d.nodes:
		mm_bounds* b = new mm_bounds()
		b.rank = -1
		b.w = strlen(n.label) * 8 + 40
		if (b.w < 180): b.w = 180
		b.h = 60
		if (d.kind == MM_ARCHITECTURE && n.group): b.w = b.w + strlen(n.annotation) * 8 + 24
		if (n.shape == 10 || n.shape == 12): b.h = 110
		if (n.shape == 11): b.h = 72
		if (n.shape == 13):
			b.w = 72
			b.h = 72
		if (n.shape == 2): b.h = b.w
		if (n.shape == 3):
			b.w = b.w * 2
			b.h = 100
		if (d.kind == MM_ER):
			b.h = 40 + n.attributes.length * 26
			for mm_attribute* a in n.attributes:
				char* text = mm_attribute_text(a)
				int width = strlen(text) * 8 + 32
				if (width > b.w): b.w = width
				free(text)
		if ((d.kind == MM_CLASS || d.kind == MM_REQUIREMENT || d.kind == MM_C4) && n.group == 0):
			b.h = 80 + n.members.length * 26
			if (n.annotation[0] != 0): b.h = b.h + 24
			int width = strlen(n.annotation) * 8 + 64
			if (width > b.w): b.w = width
			for mm_member* m in n.members:
				width = strlen(m.text) * 8 + 32
				if (width > b.w): b.w = width
		if (d.kind == MM_STATE && n.shape >= 3):
			b.w = 32
			b.h = 32
			if (n.shape == 3):
				b.w = 48
				b.h = 48
			if (n.shape == 6):
				b.w = 100
				b.h = 10
				char* dir = mm_scope_direction(d, n.parent)
				if (strcmp(dir, c"LR") == 0 || strcmp(dir, c"RL") == 0):
					b.w = 10
					b.h = 100
		s.nodes.push(b)

void mm_place(list[mm_bounds*] nodes, list[mm_edge*] edges, char* direction):
	# Longest-path ranks over a topological traversal. Break cycles at the
	# first remaining node, deterministically, without repeatedly growing ranks.
	list[int] incoming = new list[int]
	list[int] done = new list[int]
	for i in range(nodes.length):
		int count = 0
		for mm_edge* e in edges:
			if (e.to_node == i && e.from_node != i): count = count + 1
		incoming.push(count)
		done.push(0)
	int max_rank = 0
	for step in range(nodes.length):
		int index = -1
		for i in range(nodes.length):
			if (done[i] == 0 && incoming[i] == 0 && index < 0): index = i
		if (index < 0):
			for i in range(nodes.length):
				if (done[i] == 0 && index < 0): index = i
		done[index] = 1
		mm_bounds* from = nodes[index]
		if (from.rank < 0): from.rank = 0
		if (from.rank > max_rank): max_rank = from.rank
		for mm_edge* e in edges:
			if (e.from_node == index && done[e.to_node] == 0):
				mm_bounds* to = nodes[e.to_node]
				if (to.rank <= from.rank): to.rank = from.rank + 1
				incoming[e.to_node] = incoming[e.to_node] - 1
	__w_list_free(cast(__w_list*, incoming))
	__w_list_free(cast(__w_list*, done))
	int horizontal = strcmp(direction, c"LR") == 0 || strcmp(direction, c"RL") == 0
	int reverse = strcmp(direction, c"RL") == 0 || strcmp(direction, c"BT") == 0
	# Sum actual rank/lane sizes instead of multiplying the largest label by
	# the whole graph. Dimensions stay bounded by total source + item padding,
	# including on x86, and a single large circle no longer expands every row.
	list[int] sizes = new list[int]
	for rank in range(max_rank + 1): sizes.push(0)
	for mm_bounds* b in nodes:
		int rank = b.rank
		if (reverse): rank = max_rank - rank
		int size = b.h
		if (horizontal): size = b.w
		if (size > sizes[rank]): sizes[rank] = size
	for i in range(nodes.length):
		mm_bounds* b = nodes[i]
		int lane = 60
		for j in range(i):
			mm_bounds* other = nodes[j]
			if (other.rank == b.rank):
				if (horizontal): lane = lane + other.h + 100
				else: lane = lane + other.w + 100
		int rank = b.rank
		if (reverse): rank = max_rank - rank
		int offset = 60
		for j in range(rank): offset = offset + sizes[j] + 140
		if (horizontal):
			b.x = offset
			b.y = lane
		else:
			b.x = lane
			b.y = offset
	__w_list_free(cast(__w_list*, sizes))

# Return the direct child of scope containing index, or -1 outside this scope.
int mm_scope_child(mm_document* d, int index, int scope):
	while (index >= 0):
		mm_node* n = d.nodes[index]
		if (n.parent == scope): return index
		index = n.parent
	return -1

void mm_layout_scope(mm_document* d, mm_scene* s, int scope):
	list[int] indices = new list[int]
	list[mm_bounds*] nodes = new list[mm_bounds*]
	list[mm_edge*] edges = new list[mm_edge*]
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent == scope):
			if (n.group): mm_layout_scope(d, s, i)
			indices.push(i)
			nodes.push(s.nodes[i])
	for mm_edge* e in d.edges:
		int a = mm_scope_child(d, e.from_node, scope)
		int b = mm_scope_child(d, e.to_node, scope)
		if (a < 0 || b < 0 || a == b): continue
		mm_edge* mapped = new mm_edge()
		for i in range(indices.length):
			if (indices[i] == a): mapped.from_node = i
			if (indices[i] == b): mapped.to_node = i
		edges.push(mapped)
	mm_place(nodes, edges, mm_scope_direction(d, scope))
	if (scope >= 0):
		mm_bounds* box = s.nodes[scope]
		box.h = 100
		for mm_bounds* b in nodes:
			b.y = b.y + 24
			if (b.x + b.w + 60 > box.w): box.w = b.x + b.w + 60
			if (b.y + b.h + 60 > box.h): box.h = b.y + b.h + 60
	for mm_edge* e in edges: free(e)
	__w_list_free(cast(__w_list*, indices))
	__w_list_free(cast(__w_list*, nodes))
	__w_list_free(cast(__w_list*, edges))

void mm_layout_absolute(mm_document* d, mm_scene* s, int scope, int x, int y):
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != scope): continue
		mm_bounds* b = s.nodes[i]
		b.x = b.x + x
		b.y = b.y + y
		if (n.group): mm_layout_absolute(d, s, i, b.x, b.y)

void mm_layout(mm_document* d, mm_scene* s):
	mm_measure(d, s)
	mm_layout_scope(d, s, -1)
	mm_layout_absolute(d, s, -1, 0, 0)

# Convex, axis-aligned endpoint polygons, oriented away from their node.
void mm_uml_marker(mm_scene* s, int x, int y, int dx, int dy, int kind):
	if (kind == 0): return
	int px = 0 - dy
	int py = dx
	if (kind == 5):
		int cx = x + dx * 8
		int cy = y + dy * 8
		mm_draw(s, MM_CIRCLE, cx - 7, cy - 7, cx + 7, cy + 7, 0, c"")
		mm_line(s, cx - 5, cy, cx + 5, cy, 0)
		mm_line(s, cx, cy - 5, cx, cy + 5, 0)
		return
	if (kind == MM_ARROW):
		mm_line(s, x, y, x + dx * 12 + px * 6, y + dy * 12 + py * 6, 0)
		mm_line(s, x, y, x + dx * 12 - px * 6, y + dy * 12 - py * 6, 0)
		return
	mm_draw(s, MM_POLYGON, x, y, x + dx * 24, y + dy * 24, kind == MM_COMPOSITION, c"")
	mm_primitive* p = s.items[s.items.length - 1]
	p.points = new list[int]
	p.points.push(x)
	p.points.push(y)
	int length = 12
	if (kind == MM_TRIANGLE): length = 18
	p.points.push(x + dx * length + px * 9)
	p.points.push(y + dy * length + py * 9)
	if (kind != MM_TRIANGLE):
		p.points.push(x + dx * 24)
		p.points.push(y + dy * 24)
	p.points.push(x + dx * length - px * 9)
	p.points.push(y + dy * length - py * 9)


void mm_render_edge(mm_document* d, mm_scene* s, mm_edge* e):
	if (d.kind == MM_ARCHITECTURE):
		mm_arch_edge(s, e)
		return
	mm_bounds* a = s.nodes[e.from_node]
	mm_bounds* b = s.nodes[e.to_node]
	char* direction = d.direction
	if (d.kind == MM_CLASS || d.kind == MM_STATE || d.kind == MM_FLOW || d.kind == MM_ER || d.kind == MM_REQUIREMENT || d.kind == MM_C4): direction = mm_scope_direction(d, e.scope)
	int horizontal = strcmp(direction, c"LR") == 0 || strcmp(direction, c"RL") == 0
	int dx = 0
	int dy = 1
	int ax = a.x + a.w / 2
	int ay = a.y + a.h
	int bx = b.x + b.w / 2
	int by = b.y
	if (horizontal):
		dx = 1
		dy = 0
		ax = a.x + a.w
		ay = a.y + a.h / 2
		bx = b.x
		by = b.y + b.h / 2
		if (b.x < a.x):
			dx = -1
			ax = a.x
			bx = b.x + b.w
	else if (b.y < a.y):
		dy = -1
		ay = a.y
		by = b.y + b.h
	# Separate attachment points for several relationships to one entity.
	# Small flow shapes retain their center ports.
	if (d.kind == MM_ER && e.from_node != e.to_node):
		int out_count = 0
		int in_count = 0
		int out_index = 0
		int in_index = 0
		int seen = 0
		for mm_edge* other in d.edges:
			if (other == e): seen = 1
			if (other.from_node == e.from_node):
				out_count = out_count + 1
				if (seen == 0): out_index = out_index + 1
			if (other.to_node == e.to_node):
				in_count = in_count + 1
				if (seen == 0): in_index = in_index + 1
		if (horizontal):
			ay = a.y + a.h * (out_index + 1) / (out_count + 1)
			by = b.y + b.h * (in_index + 1) / (in_count + 1)
		else:
			ax = a.x + a.w * (out_index + 1) / (out_count + 1)
			bx = b.x + b.w * (in_index + 1) / (in_count + 1)
	int mx = (ax + bx) / 2
	int my = (ay + by) / 2
	if (horizontal): mx = bx - dx * 45
	else: my = by - dy * 45
	if (e.from_node == e.to_node):
		ax = a.x + a.w
		ay = a.y + a.h / 3
		bx = ax
		by = a.y + a.h * 2 / 3
		dx = 1
		dy = 0
		mx = ax + 55
		my = ay
		horizontal = 1
	if (horizontal):
		mm_line(s, ax, ay, mx, ay, e.dashed)
		mm_line(s, mx, ay, mx, by, e.dashed)
		mm_line(s, mx, by, bx, by, e.dashed)
	else:
		mm_line(s, ax, ay, ax, my, e.dashed)
		mm_line(s, ax, my, bx, my, e.dashed)
		mm_line(s, bx, my, bx, by, e.dashed)
	if (d.kind == MM_ER):
		mm_marker(s, ax, ay, dx, dy, e.left_card)
		if (e.from_node == e.to_node): mm_marker(s, bx, by, dx, dy, e.right_card)
		else: mm_marker(s, bx, by, 0 - dx, 0 - dy, e.right_card)
	else if (d.kind == MM_CLASS || d.kind == MM_REQUIREMENT || d.kind == MM_C4 || d.kind == MM_USECASE):
		mm_uml_marker(s, ax, ay, dx, dy, e.left_marker)
		int end_dx = 0 - dx
		int end_dy = 0 - dy
		if (e.from_node == e.to_node): end_dx = dx
		mm_uml_marker(s, bx, by, end_dx, end_dy, e.right_marker)
		if (e.left_label[0] != 0): mm_text(s, ax + dx * 30 + 8, ay + dy * 30 + 8, e.left_label)
		if (e.right_label[0] != 0): mm_text(s, bx + end_dx * 30 + 8, by + end_dy * 30 + 8, e.right_label)
	else if (e.arrow):
		int end_dx = 0 - dx
		int end_dy = 0 - dy
		if (e.from_node == e.to_node): end_dx = dx
		mm_line(s, bx, by, bx + end_dx * 10 - end_dy * 5, by + end_dy * 10 + end_dx * 5, 0)
		mm_line(s, bx, by, bx + end_dx * 10 + end_dy * 5, by + end_dy * 10 - end_dx * 5, 0)
	if (e.label[0] != 0):
		if (e.from_node == e.to_node): mm_text(s, mx + 8, my - 22, e.label)
		else if (horizontal): mm_text(s, (ax + mx) / 2 - strlen(e.label) * 4, ay - 22, e.label)
		else: mm_text(s, bx + 8, (my + by) / 2 - 8, e.label)

void mm_render_groups(mm_document* d, mm_scene* s, int scope):
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.group == 0 || n.parent != scope): continue
		mm_bounds* b = s.nodes[i]
		mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, d.kind == MM_STATE, c"")
		if (d.kind == MM_ARCHITECTURE && n.annotation[0] != 0):
			string_builder* label = string_from(c"[")
			string_append(label, n.annotation)
			string_append(label, c"] ")
			string_append(label, n.label)
			mm_text(s, b.x + 16, b.y + 12, label.data)
			string_free(label)
		else: mm_text(s, b.x + 16, b.y + 12, n.label)
		mm_line(s, b.x, b.y + 40, b.x + b.w, b.y + 40, 0)
		mm_render_groups(d, s, i)

void mm_render_class(mm_scene* s, mm_node* n, mm_bounds* b):
	int y = b.y + 40
	if (n.annotation[0] != 0):
		string_builder* text = string_from(c"<<")
		string_append(text, n.annotation)
		string_append(text, c">>")
		mm_text(s, b.x + 16, y, text.data)
		string_free(text)
		y = y + 24
	mm_line(s, b.x, y, b.x + b.w, y, 0)
	for method in range(2):
		int count = 0
		for mm_member* m in n.members:
			if (m.method == method):
				mm_text(s, b.x + 12, y + 5, m.text)
				y = y + 26
				count = count + 1
		if (count == 0): y = y + 18
		if (method == 0): mm_line(s, b.x, y, b.x + b.w, y, 0)

# Failed parses cannot produce a misleading partial preview.
mm_scene* mm_render_diagram(mm_document* d):
	if (d.error == 0 && d.kind >= MM_SEQUENCE && d.kind <= MM_ZENUML): return mm_narrative_render(d)
	if (d.error != 0): return 0
	if (d.kind == MM_SWIMLANE || d.kind == MM_EVENT_MODEL): return mm_workflow_render(d)
	if (d.kind == MM_BLOCK): return mm_blocks_render(d)
	if (d.kind == MM_GITGRAPH): return mm_git_render(d)
	if (d.kind == MM_TREEVIEW): return mm_treeview_render(d)
	if (d.kind == MM_ISHIKAWA): return mm_ishikawa_render(d)
	if (d.kind == MM_CYNEFIN): return mm_cynefin_render(d)
	if (d.kind == MM_WARDLEY): return mm_wardley_render(d)
	if (d.error == 0 && (d.kind == MM_MINDMAP || d.kind == MM_KANBAN)): return mm_hierarchy_render(d)
	if (d.error != 0): return 0
	if (d.kind >= MM_PIE && d.kind <= MM_PACKET): return mm_data_render(d)
	if (d.kind >= MM_RAIL_IR && d.kind <= MM_RAIL_PEG): return mm_rail_render(d)
	mm_scene* s = new mm_scene()
	s.items = new list[mm_primitive*]
	s.nodes = new list[mm_bounds*]
	s.width = 240
	s.height = 160
	mm_layout(d, s)
	mm_render_groups(d, s, -1)
	for mm_edge* e in d.edges: mm_render_edge(d, s, e)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		if (n.group): continue
		if (d.kind == MM_STATE && n.shape >= 4):
			if (n.shape == 6): mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, 2, c"")
			else:
				mm_draw(s, MM_CIRCLE, b.x, b.y, b.x + b.w, b.y + b.h, n.shape == 4, c"")
				if (n.shape == 5): mm_draw(s, MM_CIRCLE, b.x + 7, b.y + 7, b.x + b.w - 7, b.y + b.h - 7, 1, c"")
			continue
		if (n.shape == 10):
			mm_actor_draw(s, b)
			mm_text(s, b.x + 12, b.y + 90, n.label)
			continue
		if (n.shape == 12 || n.shape == 13):
			mm_arch_icon(s, n, b)
			if (n.shape == 12): mm_text(s, b.x + 12, b.y + 86, n.label)
			continue
		if (n.shape == 3):
			mm_line(s, b.x + b.w / 2, b.y, b.x + b.w, b.y + b.h / 2, 0)
			mm_line(s, b.x + b.w, b.y + b.h / 2, b.x + b.w / 2, b.y + b.h, 0)
			mm_line(s, b.x + b.w / 2, b.y + b.h, b.x, b.y + b.h / 2, 0)
			mm_line(s, b.x, b.y + b.h / 2, b.x + b.w / 2, b.y, 0)
		else if (n.shape == 2 || n.shape == 11): mm_ellipse(s, b.x + b.w / 2, b.y + b.h / 2, b.w / 2, b.h / 2)
		else: mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, n.shape == 1, c"")
		int title_y = b.y + (b.h - 16) / 2
		if (d.kind == MM_ER || (d.kind == MM_CLASS || d.kind == MM_REQUIREMENT || d.kind == MM_C4)): title_y = b.y + 12
		if (d.kind != MM_STATE || n.shape != 3): mm_text(s, b.x + (b.w - strlen(n.label) * 8) / 2, title_y, n.label)
		if ((d.kind == MM_CLASS || d.kind == MM_REQUIREMENT || d.kind == MM_C4)): mm_render_class(s, n, b)
		if (d.kind == MM_ER):
			for j in range(n.attributes.length):
				int y = b.y + 40 + j * 26
				mm_line(s, b.x, y, b.x + b.w, y, 0)
				char* text = mm_attribute_text(n.attributes[j])
				mm_text(s, b.x + 12, y + 5, text)
				free(text)
	return s

# Apply document metadata once, after the family's own layout has completed.
mm_scene* mm_render(mm_document* d):
	mm_scene* s = mm_render_diagram(d)
	if (s == 0): return 0
	if (d.title[0] != 0 && s.has_title == 0):
		for mm_primitive* p in s.items:
			p.y = p.y + 40
			p.y2 = p.y2 + 40
			if (p.points != 0):
				for i in range(p.points.length):
					if (i % 2): p.points[i] = p.points[i] + 40
		for mm_bounds* b in s.nodes: b.y = b.y + 40
		s.height = s.height + 40
		mm_text(s, 40, 12, d.title)
		s.has_title = 1
	s.accessibility_title = strclone(d.accessibility_title)
	if (s.accessibility_title[0] == 0):
		free(s.accessibility_title)
		s.accessibility_title = strclone(d.title)
	s.accessibility_description = strclone(d.accessibility_description)
	return s
