# Graph layout and rendering; shared scene primitives live in scene.w.
import libs.extras.mermaid.scene
import libs.extras.mermaid.text
import libs.extras.mermaid.layout
import libs.extras.mermaid.positions
import libs.extras.mermaid.data_render
import libs.extras.mermaid.hierarchy_render
import libs.extras.mermaid.framework_render
import libs.extras.mermaid.gitgraph
import libs.extras.mermaid.blocks
import libs.extras.mermaid.systems
import libs.extras.mermaid.workflow_render
import libs.extras.mermaid.narrative_render
import libs.extras.mermaid.railroad_render
import libs.extras.mermaid.style_render
import libs.extras.mermaid.uml_render

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

# Compartment titles (ER entities, classes, requirements, C4) and group
# titles are names: they break only where the label says so. Other node
# labels wrap at the upstream default wrapping width.
int mm_label_wrap(mm_document* d, mm_node* n):
	if (n.group || d.kind == MM_ER || d.kind == MM_CLASS || d.kind == MM_REQUIREMENT || d.kind == MM_C4): return 0
	return MM_TEXT_WRAP

mm_text_block* mm_node_text(mm_document* d, mm_node* n):
	return mm_text_layout(n.label, mm_label_wrap(d, n))

# Height a node's label adds beyond the single line every shape reserves.
int mm_node_text_extra(mm_document* d, mm_node* n):
	mm_text_block* t = mm_node_text(d, n)
	int extra = t.height - MM_TEXT_LINE
	mm_text_block_free(t)
	return extra

void mm_measure(mm_document* d, mm_scene* s):
	for mm_node* n in d.nodes:
		mm_bounds* b = new mm_bounds()
		b.rank = -1
		mm_text_block* text = mm_node_text(d, n)
		int extra = text.height - MM_TEXT_LINE
		b.w = text.width + 40
		mm_text_block_free(text)
		if (b.w < 180): b.w = 180
		b.h = 60 + extra
		if (d.kind == MM_ARCHITECTURE && n.group): b.w = b.w + mm_text_width(n.annotation, 0) + 24
		if (n.shape == 10 || n.shape == 12): b.h = 110 + extra
		if (n.shape == 11): b.h = 72 + extra
		if (n.shape == 28):
			b.h = 72 + extra
		if (n.shape == 13):
			b.w = 72
			b.h = 72
		if (n.shape == 2): b.h = b.w
		if (n.shape == 3):
			b.w = b.w * 2
			b.h = 100 + extra * 2
		if (d.kind == MM_ER):
			b.h = 40 + extra + n.attributes.length * 26
			for mm_attribute* a in n.attributes:
				char* text = mm_attribute_text(a)
				int width = mm_text_width(text, 0) + 32
				if (width > b.w): b.w = width
				free(text)
		if ((d.kind == MM_CLASS || d.kind == MM_REQUIREMENT || d.kind == MM_C4) && n.group == 0):
			b.h = 80 + extra + n.members.length * 26
			if (n.annotation[0] != 0): b.h = b.h + 24
			int width = mm_text_width(n.annotation, 0) + 68
			if (width > b.w): b.w = width
			for mm_member* m in n.members:
				width = mm_text_width(m.text, 0) + 32
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
	# Rank gaps grow to hold the edge labels drawn in them (beside the
	# target's incoming segment in vertical layouts, above it horizontally).
	list[int] gaps = new list[int]
	for rank in range(max_rank + 1): gaps.push(140)
	for mm_edge* e in edges:
		if (e.label == 0 || e.label[0] == 0 || e.from_node == e.to_node): continue
		int from_rank = nodes[e.from_node].rank
		int to_rank = nodes[e.to_node].rank
		if (reverse):
			from_rank = max_rank - from_rank
			to_rank = max_rank - to_rank
		if (from_rank == to_rank): continue
		int gap = to_rank
		if (to_rank > from_rank): gap = to_rank - 1
		mm_text_block* t = mm_text_layout(e.label, MM_TEXT_WRAP)
		int need = t.height + 64
		if (horizontal): need = t.width + 70
		mm_text_block_free(t)
		if (need > gaps[gap]): gaps[gap] = need
	list[int] order = mm_layer_order(nodes, edges, max_rank)
	for i in range(nodes.length):
		mm_bounds* b = nodes[order[i]]
		int lane = 60
		for j in range(i):
			mm_bounds* other = nodes[order[j]]
			if (other.rank == b.rank):
				if (horizontal): lane = lane + other.h + 100
				else: lane = lane + other.w + 100
		int rank = b.rank
		if (reverse): rank = max_rank - rank
		int offset = 60
		for j in range(rank): offset = offset + sizes[j] + gaps[j]
		if (horizontal):
			b.x = offset
			b.y = lane
		else:
			b.x = lane
			b.y = offset
	__w_list_free(cast(__w_list*, sizes))
	__w_list_free(cast(__w_list*, gaps))
	__w_list_free(cast(__w_list*, order))

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
		# Borrowed for label-aware rank gaps; only the struct is freed below.
		mapped.label = e.label
		for i in range(indices.length):
			if (indices[i] == a): mapped.from_node = i
			if (indices[i] == b): mapped.to_node = i
		edges.push(mapped)
	mm_place(nodes, edges, mm_scope_direction(d, scope))
	if (d.layout_algorithm == 1): mm_force_place(nodes, edges)
	if (scope >= 0):
		mm_bounds* box = s.nodes[scope]
		int extra = mm_node_text_extra(d, d.nodes[scope])
		box.h = 100 + extra
		for mm_bounds* b in nodes:
			b.y = b.y + 24 + extra
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
	if (d.kind == MM_CLASS || d.kind == MM_STATE || d.kind == MM_FLOW || d.kind == MM_ER || d.kind == MM_REQUIREMENT || d.kind == MM_C4 || d.kind == MM_AGENT): direction = mm_scope_direction(d, e.scope)
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
	mm_node* from_node = d.nodes[e.from_node]
	mm_node* to_node = d.nodes[e.to_node]
	if (from_node.shape == 28):
		ax = a.x + a.w / 2 + dx * 12
		ay = a.y + 16 + dy * 12
	if (to_node.shape == 28):
		bx = b.x + b.w / 2 - dx * 12
		by = b.y + 16 - dy * 12
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
		if (from_node.shape != 28): mm_uml_marker(s, ax, ay, dx, dy, e.left_marker)
		int end_dx = 0 - dx
		int end_dy = 0 - dy
		if (e.from_node == e.to_node): end_dx = dx
		if (to_node.shape != 28): mm_uml_marker(s, bx, by, end_dx, end_dy, e.right_marker)
		if (e.left_label[0] != 0): mm_text(s, ax + dx * 30 + 8, ay + dy * 30 + 8, e.left_label)
		if (e.right_label[0] != 0): mm_text(s, bx + end_dx * 30 + 8, by + end_dy * 30 + 8, e.right_label)
	else if (d.kind == MM_AGENT && e.right_marker == 6):
		int mark_x = bx - dx * 10
		int mark_y = by - dy * 10
		if (e.from_node == e.to_node): mark_x = bx + 10
		mm_line(s, mark_x - 6, mark_y - 6, mark_x + 6, mark_y + 6, 0)
		mm_line(s, mark_x - 6, mark_y + 6, mark_x + 6, mark_y - 6, 0)
	else if (e.arrow):
		int end_dx = 0 - dx
		int end_dy = 0 - dy
		if (e.from_node == e.to_node): end_dx = dx
		mm_line(s, bx, by, bx + end_dx * 10 - end_dy * 5, by + end_dy * 10 + end_dx * 5, 0)
		mm_line(s, bx, by, bx + end_dx * 10 + end_dy * 5, by + end_dy * 10 - end_dx * 5, 0)
	if (e.label[0] != 0):
		mm_text_block* t = mm_text_layout(e.label, MM_TEXT_WRAP)
		if (e.from_node == e.to_node): mm_text_draw(s, t, mx + 8, my - 6 - t.height, 0)
		else if (horizontal): mm_text_draw(s, t, (ax + mx) / 2, ay - 6 - t.height, 1)
		else: mm_text_draw(s, t, bx + 8, (my + by) / 2 - t.height / 2, 0)
		mm_text_block_free(t)

void mm_render_groups(mm_document* d, mm_scene* s, int scope):
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.group == 0 || n.parent != scope): continue
		mm_bounds* b = s.nodes[i]
		int style_start = s.items.length
		mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, d.kind == MM_STATE, c"")
		int title_x = b.x + 16
		if (d.kind == MM_ARCHITECTURE && n.annotation[0] != 0):
			string_builder* prefix = string_from(c"[")
			string_append(prefix, n.annotation)
			string_append(prefix, c"] ")
			mm_text(s, title_x, b.y + 12, prefix.data)
			title_x = title_x + mm_text_width(prefix.data, 0)
			string_free(prefix)
		int extra = mm_label(s, title_x, b.y + 12, n.label, 0, 0) - MM_TEXT_LINE
		mm_line(s, b.x, b.y + 40 + extra, b.x + b.w, b.y + 40 + extra, 0)
		mm_style_node(d, s, n, style_start)
		mm_render_groups(d, s, i)

void mm_render_class(mm_scene* s, mm_node* n, mm_bounds* b, int extra):
	int y = b.y + 40 + extra
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

# Rebuild primitives from existing bounds; pointer-motion previews skip parsing and layout.
void mm_render_graph(mm_document* d, mm_scene* s):
	mm_render_groups(d, s, -1)
	for mm_edge* e in d.edges:
		int start = s.items.length
		mm_render_edge(d, s, e)
		for i in range(start, s.items.length):
			mm_primitive* primitive = s.items[i]
			mm_style_merge(&primitive.style, &d.edge_style)
			mm_style_merge(&primitive.style, &e.style)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		if (n.group): continue
		int style_start = s.items.length
		if (d.kind == MM_STATE && n.shape >= 4):
			if (n.shape == 6): mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, 2, c"")
			else:
				mm_draw(s, MM_CIRCLE, b.x, b.y, b.x + b.w, b.y + b.h, n.shape == 4, c"")
				if (n.shape == 5): mm_draw(s, MM_CIRCLE, b.x + 7, b.y + 7, b.x + b.w - 7, b.y + b.h - 7, 1, c"")
			mm_style_node(d, s, n, style_start)
			continue
		if (n.shape == 28):
			int cx = b.x + b.w / 2
			mm_draw(s, MM_CIRCLE, cx - 12, b.y + 4, cx + 12, b.y + 28, 0, c"")
			mm_label(s, b.x + b.w / 2, b.y + 44, n.label, mm_label_wrap(d, n), 1)
			mm_style_node(d, s, n, style_start)
			continue
		if (n.shape == 10):
			mm_actor_draw(s, b)
			mm_label(s, b.x + 12, b.y + 90, n.label, mm_label_wrap(d, n), 0)
			mm_style_node(d, s, n, style_start)
			continue
		if (n.shape == 12 || n.shape == 13):
			mm_arch_icon(s, n, b)
			if (n.shape == 12): mm_label(s, b.x + 12, b.y + 86, n.label, mm_label_wrap(d, n), 0)
			mm_style_node(d, s, n, style_start)
			continue
		if (n.shape == 21 || n.shape == 22):
			mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
			mm_primitive* box = s.items[s.items.length - 1]
			if (n.shape == 21): box.dashed = 3
			else:
				mm_line(s, b.x + 10, b.y, b.x + 10, b.y + b.h, 0)
				mm_line(s, b.x + b.w - 10, b.y, b.x + b.w - 10, b.y + b.h, 0)
		else if (n.shape >= 23 && n.shape <= 27):
			mm_draw(s, MM_POLYGON, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
			mm_primitive* polygon = s.items[s.items.length - 1]
			if (n.shape == 23): polygon.points = list[int]{b.x + 20, b.y, b.x + b.w - 20, b.y, b.x + b.w, b.y + b.h / 2, b.x + b.w - 20, b.y + b.h, b.x + 20, b.y + b.h, b.x, b.y + b.h / 2}
			else:
				int tl = 0
				int tr = 0
				int bl = 0
				int br = 0
				if (n.shape == 24 || n.shape == 26): tl = 20
				if (n.shape == 25 || n.shape == 26): tr = 20
				if (n.shape == 25 || n.shape == 27): bl = 20
				if (n.shape == 24 || n.shape == 27): br = 20
				polygon.points = list[int]{b.x + tl, b.y, b.x + b.w - tr, b.y, b.x + b.w - br, b.y + b.h, b.x + bl, b.y + b.h}
		else if (n.shape == 3):
			mm_draw(s, MM_POLYGON, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
			mm_primitive* diamond = s.items[s.items.length - 1]
			diamond.points = list[int]{b.x + b.w / 2, b.y, b.x + b.w, b.y + b.h / 2, b.x + b.w / 2, b.y + b.h, b.x, b.y + b.h / 2}
		else if (d.kind == MM_AGENT && n.shape >= 17):
			if (n.shape == 17 || n.shape == 19):
				mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
				if (n.shape == 17):
					mm_line(s, b.x + 10, b.y, b.x + 10, b.y + b.h, 0)
					mm_line(s, b.x + b.w - 10, b.y, b.x + b.w - 10, b.y + b.h, 0)
				else:
					mm_line(s, b.x + 8, b.y + b.h - 8, b.x + b.w - 8, b.y + b.h - 8, 0)
			else:
				mm_draw(s, MM_POLYGON, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
				mm_primitive* polygon = s.items[s.items.length - 1]
				if (n.shape == 18): polygon.points = list[int]{b.x + 16, b.y, b.x + b.w, b.y, b.x + b.w - 16, b.y + b.h, b.x, b.y + b.h}
				else: polygon.points = list[int]{b.x + 16, b.y, b.x + b.w - 16, b.y, b.x + b.w, b.y + b.h / 2, b.x + b.w - 16, b.y + b.h, b.x + 16, b.y + b.h, b.x, b.y + b.h / 2}
		else if (n.shape == 2): mm_draw(s, MM_CIRCLE, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
		else if (n.shape == 11):
			mm_draw(s, MM_POLYGON, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
			mm_primitive* oval = s.items[s.items.length - 1]
			oval.points = new list[int]
			for i in range(48):
				float angle = cast(float, i) * 6.2831853 / 48.0
				oval.points.push(b.x + b.w / 2 + cast(int, fcos(angle) * cast(float, b.w) / 2.0))
				oval.points.push(b.y + b.h / 2 + cast(int, fsin(angle) * cast(float, b.h) / 2.0))
		else: mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, n.shape == 1, c"")
		mm_text_block* title = mm_node_text(d, n)
		int extra = title.height - MM_TEXT_LINE
		int title_y = b.y + (b.h - title.height) / 2
		if (d.kind == MM_ER || (d.kind == MM_CLASS || d.kind == MM_REQUIREMENT || d.kind == MM_C4)): title_y = b.y + 12
		if (d.kind != MM_STATE || n.shape != 3): mm_text_draw(s, title, b.x + b.w / 2, title_y, 1)
		mm_text_block_free(title)
		if ((d.kind == MM_CLASS || d.kind == MM_REQUIREMENT || d.kind == MM_C4)): mm_render_class(s, n, b, extra)
		if (d.kind == MM_ER):
			for j in range(n.attributes.length):
				int y = b.y + 40 + extra + j * 26
				mm_line(s, b.x, y, b.x + b.w, y, 0)
				char* text = mm_attribute_text(n.attributes[j])
				mm_text(s, b.x + 12, y + 5, text)
				free(text)
		mm_style_node(d, s, n, style_start)
	if (d.kind == MM_CLASS || d.kind == MM_STATE): mm_uml_notes(d, s)

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
	mm_positions_apply(d, s)
	mm_render_graph(d, s)
	return s

# Apply document metadata once, after the family's own layout has completed.
void mm_render_metadata(mm_document* d, mm_scene* s):
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
	mm_style_scene(d, s)

mm_scene* mm_render(mm_document* d):
	mm_scene* s = mm_render_diagram(d)
	if (s != 0): mm_render_metadata(d, s)
	return s

# Scene bounds use final coordinates, including the optional title gutter.
void mm_render_graph_refresh(mm_document* d, mm_scene* s):
	for mm_primitive* p in s.items:
		if (p.points != 0): __w_list_free(cast(__w_list*, p.points))
		free(p.text)
		free(p)
	while (s.items.length > 0): s.items.pop()
	free(s.accessibility_title)
	free(s.accessibility_description)
	s.accessibility_title = 0
	s.accessibility_description = 0
	int offset = mm_position_title_offset(d)
	for mm_bounds* b in s.nodes: b.y = b.y - offset
	s.width = 240
	s.height = 160
	s.has_title = 0
	s.has_background = 0
	s.background = 0
	mm_render_graph(d, s)
	mm_render_metadata(d, s)
