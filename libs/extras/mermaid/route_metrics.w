# Route-quality measurements of a rendered graph scene, used by the routing
# stress fixtures and the layout measurements in docs/projects/mermaid_layout.md.
# Each edge is redrawn alone into a scene borrowing the laid-out bounds, so
# segments and labels are attributed to their edge. Quadratic in the number of
# segments: meant for fixtures, not for production rendering.
import libs.extras.mermaid.render

struct mm_route_quality:
	# Proper crossings between path segments of two different edges.
	int crossings
	# (edge, node) pairs where the edge's path enters an unrelated leaf node box.
	int node_hits
	# Pairs of labels of different edges whose boxes overlap.
	int label_overlaps
	# (label, node) pairs where an edge label overlaps a leaf node box.
	int label_node_overlaps
	# Pairs of edges whose ports coincide on a shared node (both ends checked).
	int shared_ports
	# Collinear overlaps (> 4px) between path segments of two edges that share
	# no endpoint: drawn on top of each other, they cannot be told apart.
	int overlaps

int mm_route_orientation(float ax, float ay, float bx, float by, float cx, float cy):
	float value = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
	if (value > 0.0): return 1
	if (value < 0.0): return -1
	return 0

# Strict interior intersection of segments p and q (touching does not count).
int mm_route_segments_cross(list[int] p, int i, list[int] q, int j):
	float ax = cast(float, p[i])
	float ay = cast(float, p[i + 1])
	float bx = cast(float, p[i + 2])
	float by = cast(float, p[i + 3])
	float cx = cast(float, q[j])
	float cy = cast(float, q[j + 1])
	float dx = cast(float, q[j + 2])
	float dy = cast(float, q[j + 3])
	int o1 = mm_route_orientation(ax, ay, bx, by, cx, cy)
	int o2 = mm_route_orientation(ax, ay, bx, by, dx, dy)
	int o3 = mm_route_orientation(cx, cy, dx, dy, ax, ay)
	int o4 = mm_route_orientation(cx, cy, dx, dy, bx, by)
	return o1 * o2 < 0 && o3 * o4 < 0

# Overlap length of two collinear axis-aligned segments (0 otherwise).
int mm_route_collinear_overlap(list[int] p, int i, list[int] q, int j):
	int vertical = p[i] == p[i + 2] && q[j] == q[j + 2] && p[i] == q[j]
	int horizontal = p[i + 1] == p[i + 3] && q[j + 1] == q[j + 3] && p[i + 1] == q[j + 1]
	int axis = 0
	if (vertical): axis = 1
	else if (horizontal == 0): return 0
	int a1 = p[i + axis]
	int a2 = p[i + 2 + axis]
	int b1 = q[j + axis]
	int b2 = q[j + 2 + axis]
	if (a2 < a1):
		int t = a1
		a1 = a2
		a2 = t
	if (b2 < b1):
		int t = b1
		b1 = b2
		b2 = t
	int lo = a1
	if (b1 > lo): lo = b1
	int hi = a2
	if (b2 < hi): hi = b2
	if (hi - lo > 4): return hi - lo
	return 0

# Whether the segment enters the box shrunk by 2px (border contact is fine).
int mm_route_segment_hits_box(list[int] p, int i, mm_bounds* b):
	int x1 = b.x + 2
	int y1 = b.y + 2
	int x2 = b.x + b.w - 2
	int y2 = b.y + b.h - 2
	if (x2 <= x1 || y2 <= y1): return 0
	# Sample the segment; fixture segments are short, axis-aligned or sampled curves.
	int ax = p[i]
	int ay = p[i + 1]
	int bx = p[i + 2]
	int by = p[i + 3]
	int lo_x = ax
	int hi_x = bx
	if (hi_x < lo_x):
		lo_x = bx
		hi_x = ax
	int lo_y = ay
	int hi_y = by
	if (hi_y < lo_y):
		lo_y = by
		hi_y = ay
	if (hi_x <= x1 || lo_x >= x2 || hi_y <= y1 || lo_y >= y2): return 0
	int steps = (hi_x - lo_x) + (hi_y - lo_y)
	if (steps < 1): steps = 1
	for k in range(steps + 1):
		int x = ax + (bx - ax) * k / steps
		int y = ay + (by - ay) * k / steps
		if (x > x1 && x < x2 && y > y1 && y < y2): return 1
	return 0

# Leaf nodes count as obstacles: groups are containers edges legitimately cross.
int mm_route_obstacle(mm_document* d, mm_scene* s, int index):
	mm_node* n = d.nodes[index]
	mm_bounds* b = s.nodes[index]
	return n.group == 0 && b.w > 0 && mm_flow_visible_node(d, index) == index

mm_scene* mm_route_edge_scene(mm_document* d, mm_scene* s, mm_edge* e, int path_only):
	mm_scene* view = new mm_scene()
	view.items = new list[mm_primitive*]
	view.nodes = s.nodes
	view.path_only = path_only
	int from = mm_flow_visible_node(d, e.from_node)
	int to = mm_flow_visible_node(d, e.to_node)
	if (from == to && e.from_node != e.to_node): return view
	int original_from = e.from_node
	int original_to = e.to_node
	e.from_node = from
	e.to_node = to
	int previous = mm_text_set_size(d.font_size)
	mm_render_edge(d, view, e)
	mm_text_set_size(previous)
	e.from_node = original_from
	e.to_node = original_to
	return view

void mm_route_edge_scene_free(mm_scene* view):
	view.nodes = new list[mm_bounds*]
	mm_scene_free(view)

mm_route_quality* mm_route_measure(mm_document* d, mm_scene* s):
	mm_route_quality* q = new mm_route_quality()
	list[int] segments = new list[int]
	list[int] segment_edge = new list[int]
	list[int] labels = new list[int]
	list[int] label_edge = new list[int]
	list[int] ports = new list[int]
	for i in range(d.edges.length):
		mm_edge* e = d.edges[i]
		if (d.kind == MM_FLOW && e.stroke == 2): continue
		mm_scene* view = mm_route_edge_scene(d, s, e, 1)
		int first = segments.length
		for mm_primitive* p in view.items:
			if (p.kind != MM_LINE || (p.x == p.x2 && p.y == p.y2)): continue
			segments.push(p.x)
			segments.push(p.y)
			segments.push(p.x2)
			segments.push(p.y2)
			segment_edge.push(i)
		if (segments.length > first && e.from_node != e.to_node):
			ports.push(segments[first])
			ports.push(segments[first + 1])
			ports.push(segments[segments.length - 2])
			ports.push(segments[segments.length - 1])
		else:
			for k in range(4): ports.push(-1)
		# Path-entering-node checks against every unrelated leaf node.
		int from = mm_flow_visible_node(d, e.from_node)
		int to = mm_flow_visible_node(d, e.to_node)
		for n in range(d.nodes.length):
			if (n == from || n == to || mm_route_obstacle(d, s, n) == 0): continue
			int hit = 0
			int at = first
			while (at < segments.length && hit == 0):
				if (mm_route_segment_hits_box(segments, at, s.nodes[n])): hit = 1
				at = at + 4
			q.node_hits = q.node_hits + hit
		mm_route_edge_scene_free(view)
		mm_scene* full = mm_route_edge_scene(d, s, e, 0)
		for mm_primitive* p in full.items:
			if (p.kind != MM_TEXT || p.text[0] == 0): continue
			int previous = mm_text_set_size(mm_paint_font_size(p))
			labels.push(p.x)
			labels.push(p.y)
			labels.push(p.x + mm_text_width(p.text, mm_text_flags(p)))
			labels.push(p.y + mm_text_line_height())
			mm_text_set_size(previous)
			label_edge.push(i)
		mm_route_edge_scene_free(full)
	for i in range(segment_edge.length):
		for j in range(i + 1, segment_edge.length):
			if (segment_edge[i] == segment_edge[j]): continue
			if (mm_route_segments_cross(segments, i * 4, segments, j * 4)): q.crossings = q.crossings + 1
			mm_edge* a = d.edges[segment_edge[i]]
			mm_edge* b = d.edges[segment_edge[j]]
			int shared = a.from_node == b.from_node || a.from_node == b.to_node || a.to_node == b.from_node || a.to_node == b.to_node
			if (shared == 0 && mm_route_collinear_overlap(segments, i * 4, segments, j * 4) > 0): q.overlaps = q.overlaps + 1
	for i in range(label_edge.length):
		for j in range(i + 1, label_edge.length):
			if (label_edge[i] == label_edge[j]): continue
			int a = i * 4
			int b = j * 4
			if (labels[a] < labels[b + 2] && labels[b] < labels[a + 2] && labels[a + 1] < labels[b + 3] && labels[b + 1] < labels[a + 3]): q.label_overlaps = q.label_overlaps + 1
		for n in range(d.nodes.length):
			if (mm_route_obstacle(d, s, n) == 0): continue
			mm_bounds* b = s.nodes[n]
			int a = i * 4
			if (labels[a] < b.x + b.w && b.x < labels[a + 2] && labels[a + 1] < b.y + b.h && b.y < labels[a + 3]): q.label_node_overlaps = q.label_node_overlaps + 1
	int edges = ports.length / 4
	for i in range(edges):
		for j in range(i + 1, edges):
			for end_i in range(2):
				for end_j in range(2):
					int a = i * 4 + end_i * 2
					int b = j * 4 + end_j * 2
					if (ports[a] >= 0 && ports[a] == ports[b] && ports[a + 1] == ports[b + 1]): q.shared_ports = q.shared_ports + 1
	__w_list_free(cast(__w_list*, segments))
	__w_list_free(cast(__w_list*, segment_edge))
	__w_list_free(cast(__w_list*, labels))
	__w_list_free(cast(__w_list*, label_edge))
	__w_list_free(cast(__w_list*, ports))
	return q
