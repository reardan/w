# Edge routing through layered-layout channels and collision-avoiding edge
# label placement for the generic graph renderer.
import libs.extras.mermaid.scene
import libs.extras.mermaid.style_render

# A usable route of r between bounds a and b drawn on the given axis: both
# endpoints moved by the same (*tx, *ty) since layout (title gutter, group
# offsets). Moving one endpoint alone (dragging, persisted positions) falls
# back to the direct route.
int mm_route_usable(mm_edge_route* r, mm_bounds* a, mm_bounds* b, int horizontal, int* tx, int* ty):
	if (r == 0 || r.gaps == 0 || r.horizontal != horizontal): return 0
	int dx = a.x - r.from_x
	int dy = a.y - r.from_y
	if (b.x - r.to_x != dx || b.y - r.to_y != dy): return 0
	tx[0] = dx
	ty[0] = dy
	return 1

# Draw a routed edge from port (ax, ay) to (bx, by): in each free gap the
# family's curve (step, linear or basis) bends to the next dummy channel or
# the target port, and each channel is crossed straight along the rank axis.
# Returns the final bend; *leg_x, *leg_y receive the final gap's start point.
int mm_route_draw(mm_document* d, mm_scene* s, mm_edge_route* r, int tx, int ty, int ax, int ay, int bx, int by, int horizontal, int dashed, int* leg_x, int* leg_y):
	int axis_shift = ty
	int cross_shift = tx
	if (horizontal):
		axis_shift = tx
		cross_shift = ty
	int x = ax
	int y = ay
	int k = r.lanes.length
	int bend = 0
	for i in range(k + 1):
		int start = r.gaps[i * 2] + axis_shift
		int end = r.gaps[i * 2 + 1] + axis_shift
		bend = (start + end) / 2
		int nx = bx
		int ny = by
		if (i < k):
			int lane = r.lanes[i] + cross_shift
			int enter = r.spans[i * 2] + axis_shift
			nx = lane
			ny = enter
			if (horizontal):
				nx = enter
				ny = lane
		else:
			leg_x[0] = x
			leg_y[0] = y
			# The final bend keeps the direct route's 45px approach leg when it fits the gap.
			int sign = 1
			if (end < start): sign = -1
			int near = by - sign * 45
			if (horizontal): near = bx - sign * 45
			int low = start
			int high = end
			if (high < low):
				low = end
				high = start
			if (near >= low && near <= high): bend = near
		if (r.bends != 0 && r.bends[i] >= 0): bend = r.bends[i] + axis_shift
		if (horizontal): mm_style_edge_path(d, s, x, y, bend, 0, nx, ny, 1, dashed, 0)
		else: mm_style_edge_path(d, s, x, y, 0, bend, nx, ny, 0, dashed, 0)
		if (i < k):
			int exit = r.spans[i * 2 + 1] + axis_shift
			x = nx
			y = ny
			if (horizontal): x = exit
			else: y = exit
			if (x != nx || y != ny): mm_line(s, nx, ny, x, y, dashed)
	return bend

const int MM_LABEL_PAD = 4

mm_label_grid* mm_label_grid_new(int width, int height):
	mm_label_grid* g = new mm_label_grid()
	int extent = width
	if (height > extent): extent = height
	g.cell = 256
	if ((extent + 255) / 256 > g.cell): g.cell = (extent + 255) / 256
	g.columns = width / g.cell + 1
	g.rows = height / g.cell + 1
	g.head = new list[int]
	for i in range(g.columns * g.rows): g.head.push(-1)
	g.next = new list[int]
	g.entry_rect = new list[int]
	g.rects = new list[int]
	return g

void mm_label_grid_free(mm_label_grid* g):
	if (g == 0): return
	__w_list_free(cast(__w_list*, g.head))
	__w_list_free(cast(__w_list*, g.next))
	__w_list_free(cast(__w_list*, g.entry_rect))
	__w_list_free(cast(__w_list*, g.rects))
	free(g)

int mm_label_grid_column(mm_label_grid* g, int x):
	int c = x / g.cell
	if (x < 0): c = 0
	if (c >= g.columns): c = g.columns - 1
	return c

int mm_label_grid_row(mm_label_grid* g, int y):
	int r = y / g.cell
	if (y < 0): r = 0
	if (r >= g.rows): r = g.rows - 1
	return r

void mm_label_grid_add(mm_label_grid* g, int x1, int y1, int x2, int y2):
	int rect = g.rects.length / 4
	g.rects.push(x1)
	g.rects.push(y1)
	g.rects.push(x2)
	g.rects.push(y2)
	for row in range(mm_label_grid_row(g, y1), mm_label_grid_row(g, y2) + 1):
		for column in range(mm_label_grid_column(g, x1), mm_label_grid_column(g, x2) + 1):
			int cell = row * g.columns + column
			g.next.push(g.head[cell])
			g.entry_rect.push(rect)
			g.head[cell] = g.next.length - 1

int mm_label_grid_hits(mm_label_grid* g, int x1, int y1, int x2, int y2):
	for row in range(mm_label_grid_row(g, y1), mm_label_grid_row(g, y2) + 1):
		for column in range(mm_label_grid_column(g, x1), mm_label_grid_column(g, x2) + 1):
			int entry = g.head[row * g.columns + column]
			while (entry >= 0):
				int at = g.entry_rect[entry] * 4
				if (x1 < g.rects[at + 2] && g.rects[at] < x2 && y1 < g.rects[at + 3] && g.rects[at + 1] < y2): return 1
				entry = g.next[entry]
	return 0

# Move a label of w x h (origin *x, *y; centered: *x is its middle) to the
# first candidate clear of nodes and earlier labels: the default spot, the
# other side of its leg, then steps along the leg. Without a clear spot the
# default stays. The chosen box joins the occupied set.
void mm_label_place(mm_label_grid* g, int w, int h, int centered, int horizontal, int* x, int* y):
	int left = x[0]
	if (centered): left = left - w / 2
	int top = y[0]
	int pad = MM_LABEL_PAD
	int best_x = left
	int best_y = top
	int found = 0
	for attempt in range(18):
		int cx = left
		int cy = top
		int side = attempt % 2
		int shift = (attempt / 2 + 1) / 2
		int sign = 1
		if ((attempt / 2) % 2 == 0): sign = -1
		if (attempt < 2): shift = 0
		if (horizontal):
			if (side): cy = top + h + 12
			cx = left + sign * shift * (w / 2 + 12)
		else:
			if (side): cx = left - 16 - w
			cy = top + sign * shift * (h + 6)
		if (mm_label_grid_hits(g, cx - pad, cy - pad, cx + w + pad, cy + h + pad) == 0):
			best_x = cx
			best_y = cy
			found = 1
			break
	if (found == 0):
		best_x = left
		best_y = top
	mm_label_grid_add(g, best_x, best_y, best_x + w, best_y + h)
	x[0] = best_x
	if (centered): x[0] = best_x + w / 2
	y[0] = best_y

# Obstacle-aware orthogonal routing for the edges the layered channels do not
# cover: same-rank edges, self loops, edges between nodes nested in different
# subgraphs and edges whose endpoint was moved after layout. A route runs on
# the grid of obstacle edges (padded boxes), the stub points and the midlines
# between them, inside a region grown from the stubs until it holds every
# obstacle it touches; Dijkstra over (grid point, travel axis) states charges
# length, bends, collinear overlap with unrelated edges and crossings of
# drawn segments.

# Clearance kept around obstacle boxes, and the straight leg leaving a port.
const int MM_OBSTACLE_MARGIN = 12
const int MM_OBSTACLE_STUB = 24
# Grid lines per axis one route may use; busier neighborhoods keep the direct route.
const int MM_OBSTACLE_AXIS_LIMIT = 256
const int MM_OBSTACLE_BEND = 48
const int MM_OBSTACLE_OVERLAP = 4000
const int MM_OBSTACLE_CROSS = 120
# Obstacle routes computed per render; further blocked edges keep their direct routes.
const int MM_OBSTACLE_EDGE_LIMIT = 512
const int MM_OBSTACLE_INFINITY = 1073741824

int mm_sign(int v):
	if (v > 0): return 1
	if (v < 0): return -1
	return 0

int mm_abs(int v):
	if (v < 0): return 0 - v
	return v

# First index of the sorted axis holding a value >= value.
int mm_obstacle_lower(list[int] axis, int value):
	int lo = 0
	int hi = axis.length
	while (lo < hi):
		int mid = (lo + hi) / 2
		if (axis[mid] < value): lo = mid + 1
		else: hi = mid
	return lo

# Sort raw in place and append its distinct values, with the midline of
# every gap wider than two margins, to out.
void mm_obstacle_axis(list[int] raw, list[int] out):
	for i in range(1, raw.length):
		int v = raw[i]
		int k = i - 1
		while (k >= 0 && raw[k] > v):
			raw[k + 1] = raw[k]
			k = k - 1
		raw[k + 1] = v
	int previous = 0
	for i in range(raw.length):
		int v = raw[i]
		if (out.length > 0 && v == previous): continue
		if (out.length > 0 && v - previous > 2 * MM_OBSTACLE_MARGIN): out.push((previous + v) / 2)
		out.push(v)
		previous = v

void mm_obstacle_heap_push(list[int] cost, list[int] state, int c, int v):
	cost.push(c)
	state.push(v)
	int i = cost.length - 1
	while (i > 0):
		int parent = (i - 1) / 2
		if (cost[parent] <= c): break
		cost[i] = cost[parent]
		state[i] = state[parent]
		i = parent
	cost[i] = c
	state[i] = v

int mm_obstacle_heap_pop(list[int] cost, list[int] state, int* top_cost):
	int top = state[0]
	top_cost[0] = cost[0]
	int n = cost.length - 1
	int last_cost = cost[n]
	int last_state = state[n]
	cost.pop()
	state.pop()
	if (n > 0):
		int i = 0
		while (i * 2 + 1 < n):
			int child = i * 2 + 1
			if (child + 1 < n && cost[child + 1] < cost[child]): child = child + 1
			if (cost[child] >= last_cost): break
			cost[i] = cost[child]
			state[i] = state[child]
			i = child
		cost[i] = last_cost
		state[i] = last_state
	return top

# Whether the axis-aligned segment passes strictly inside rect r of rects.
int mm_obstacle_segment_blocked(list[int] rects, int r, int x1, int y1, int x2, int y2):
	int lo_x = x1
	int hi_x = x2
	if (hi_x < lo_x):
		lo_x = x2
		hi_x = x1
	int lo_y = y1
	int hi_y = y2
	if (hi_y < lo_y):
		lo_y = y2
		hi_y = y1
	int a = r * 4
	if (lo_y == hi_y): return lo_y > rects[a + 1] && lo_y < rects[a + 3] && lo_x < rects[a + 2] && hi_x > rects[a]
	return lo_x > rects[a] && lo_x < rects[a + 2] && lo_y < rects[a + 3] && hi_y > rects[a + 1]

# Charge the grid edges an occupied axis-aligned segment on line `at` from a
# to b overlaps (kind 2) or crosses (kinds 1 and 2). along holds the grid
# edges parallel to the segment, across the perpendicular ones.
void mm_obstacle_charge(list[int] xs, list[int] ys, list[int] along, list[int] across, int w, int h, int vertical, int at, int a, int b, int kind):
	if (b < a):
		int t = a
		a = b
		b = t
	list[int] line_axis = ys
	list[int] extent_axis = xs
	int line_count = h
	int extent_count = w
	if (vertical):
		line_axis = xs
		extent_axis = ys
		line_count = w
		extent_count = h
	if (kind == 2):
		int line = mm_obstacle_lower(line_axis, at)
		if (line < line_count && line_axis[line] == at):
			int k = mm_obstacle_lower(extent_axis, a) - 1
			if (k < 0): k = 0
			while (k < extent_count - 1 && extent_axis[k] < b):
				int lo = extent_axis[k]
				if (a > lo): lo = a
				int hi = extent_axis[k + 1]
				if (b < hi): hi = b
				int index = line * w + k
				if (vertical): index = k * w + line
				if (hi - lo > 4 && along[index] >= 0): along[index] = along[index] + MM_OBSTACLE_OVERLAP
				k = k + 1
	# Perpendicular grid edges spanning the line: (line, line + 1) with
	# coordinate[line] < at <= coordinate[line + 1].
	int line = mm_obstacle_lower(line_axis, at) - 1
	if (line < 0 || line >= line_count - 1): return
	int k = mm_obstacle_lower(extent_axis, a + 1)
	while (k < extent_count && extent_axis[k] < b):
		int index = line * w + k
		if (vertical): index = k * w + line
		if (across[index] >= 0): across[index] = across[index] + MM_OBSTACLE_CROSS
		k = k + 1

# Append (x, y) to a polyline, dropping repeats and merging collinear legs.
void mm_route_point_push(list[int] points, int x, int y):
	int n = points.length
	if (n >= 2 && points[n - 2] == x && points[n - 1] == y): return
	if (n >= 4 && ((points[n - 4] == points[n - 2] && points[n - 2] == x) || (points[n - 3] == points[n - 1] && points[n - 1] == y))):
		points[n - 2] = x
		points[n - 1] = y
		return
	points.push(x)
	points.push(y)

# Orthogonal route from one of the start stubs to one of the target stubs
# (x, y, travel axis 0 horizontal / 1 vertical, extra cost quadruples) with no
# point strictly inside a padded obstacle rect (x1, y1, x2, y2 quadruples).
# Occupied segments (quadruples; seg_kind 0 ignores one, 1 charges crossings,
# 2 also collinear overlaps) steer it off the drawn edges. Appends the corner
# points from the chosen start stub to the chosen target stub to an empty
# out and stores the chosen indices in chosen[0], chosen[1]; 0 when no route fits.
int mm_obstacle_route(list[int] rects, list[int] segs, list[int] seg_kind, list[int] starts, list[int] targets, list[int] out, list[int] chosen):
	int rect_count = rects.length / 4
	int lo_x = starts[0]
	int hi_x = lo_x
	int lo_y = starts[1]
	int hi_y = lo_y
	for pass in range(2):
		list[int] ends = starts
		if (pass): ends = targets
		for k in range(ends.length / 4):
			int x = ends[k * 4]
			int y = ends[k * 4 + 1]
			if (x < lo_x): lo_x = x
			if (x > hi_x): hi_x = x
			if (y < lo_y): lo_y = y
			if (y > hi_y): hi_y = y
	lo_x = lo_x - 80
	lo_y = lo_y - 80
	hi_x = hi_x + 80
	hi_y = hi_y + 80
	# Grow the region until it contains every rect it touches, so its border
	# lines are free.
	list[int] inside = new list[int]
	for round in range(10):
		while (inside.length > 0): inside.pop()
		int changed = 0
		for r in range(rect_count):
			int at = r * 4
			if (rects[at] > hi_x || rects[at + 2] < lo_x || rects[at + 1] > hi_y || rects[at + 3] < lo_y): continue
			inside.push(r)
			if (rects[at] - 24 < lo_x):
				lo_x = rects[at] - 24
				changed = 1
			if (rects[at + 1] - 24 < lo_y):
				lo_y = rects[at + 1] - 24
				changed = 1
			if (rects[at + 2] + 24 > hi_x):
				hi_x = rects[at + 2] + 24
				changed = 1
			if (rects[at + 3] + 24 > hi_y):
				hi_y = rects[at + 3] + 24
				changed = 1
		if (changed == 0 || inside.length * 4 > MM_OBSTACLE_AXIS_LIMIT): break
	if (inside.length * 4 > MM_OBSTACLE_AXIS_LIMIT):
		__w_list_free(cast(__w_list*, inside))
		return 0
	list[int] raw_x = new list[int]
	list[int] raw_y = new list[int]
	for pass in range(2):
		list[int] ends = starts
		if (pass): ends = targets
		for k in range(ends.length / 4):
			raw_x.push(ends[k * 4])
			raw_y.push(ends[k * 4 + 1])
	raw_x.push(lo_x)
	raw_x.push(hi_x)
	raw_y.push(lo_y)
	raw_y.push(hi_y)
	for int r in inside:
		for k in range(2):
			int x = rects[r * 4 + k * 2]
			int y = rects[r * 4 + k * 2 + 1]
			if (x > lo_x && x < hi_x): raw_x.push(x)
			if (y > lo_y && y < hi_y): raw_y.push(y)
	list[int] xs = new list[int]
	list[int] ys = new list[int]
	mm_obstacle_axis(raw_x, xs)
	mm_obstacle_axis(raw_y, ys)
	__w_list_free(cast(__w_list*, raw_x))
	__w_list_free(cast(__w_list*, raw_y))
	int w = xs.length
	int h = ys.length
	int found = 0
	if (w <= MM_OBSTACLE_AXIS_LIMIT && h <= MM_OBSTACLE_AXIS_LIMIT):
		# Grid edge costs (-1: blocked): horizontal edge (i, j)-(i + 1, j) and
		# vertical edge (i, j)-(i, j + 1) both at index j * w + i.
		list[int] hcost = new list[int]
		list[int] vcost = new list[int]
		for i in range(w * h):
			hcost.push(0)
			vcost.push(0)
		for int r in inside:
			int at = r * 4
			int x1 = rects[at]
			int y1 = rects[at + 1]
			int x2 = rects[at + 2]
			int y2 = rects[at + 3]
			int i0 = mm_obstacle_lower(xs, x1)
			int i1 = mm_obstacle_lower(xs, x2 + 1) - 1
			for j in range(mm_obstacle_lower(ys, y1 + 1), mm_obstacle_lower(ys, y2)):
				for i in range(i0, i1): hcost[j * w + i] = -1
			int j0 = mm_obstacle_lower(ys, y1)
			int j1 = mm_obstacle_lower(ys, y2 + 1) - 1
			for i in range(mm_obstacle_lower(xs, x1 + 1), mm_obstacle_lower(xs, x2)):
				for j in range(j0, j1): vcost[j * w + i] = -1
		for k in range(seg_kind.length):
			int kind = seg_kind[k]
			if (kind == 0): continue
			int at = k * 4
			int x1 = segs[at]
			int y1 = segs[at + 1]
			int x2 = segs[at + 2]
			int y2 = segs[at + 3]
			if ((x1 < lo_x && x2 < lo_x) || (x1 > hi_x && x2 > hi_x) || (y1 < lo_y && y2 < lo_y) || (y1 > hi_y && y2 > hi_y)): continue
			if (y1 == y2 && x1 != x2): mm_obstacle_charge(xs, ys, hcost, vcost, w, h, 0, y1, x1, x2, kind)
			else if (x1 == x2 && y1 != y2): mm_obstacle_charge(xs, ys, vcost, hcost, w, h, 1, x1, y1, y2, kind)
		list[int] dist = new list[int]
		list[int] previous = new list[int]
		for i in range(w * h * 2):
			dist.push(MM_OBSTACLE_INFINITY)
			previous.push(-1)
		list[int] heap_cost = new list[int]
		list[int] heap_state = new list[int]
		# Grid node of every start / target stub.
		list[int] start_node = new list[int]
		for k in range(starts.length / 4):
			int node = mm_obstacle_lower(ys, starts[k * 4 + 1]) * w + mm_obstacle_lower(xs, starts[k * 4])
			start_node.push(node)
			int state = node * 2 + starts[k * 4 + 2]
			if (starts[k * 4 + 3] < dist[state]):
				dist[state] = starts[k * 4 + 3]
				mm_obstacle_heap_push(heap_cost, heap_state, starts[k * 4 + 3], state)
		list[int] target_node = new list[int]
		list[int] is_target = new list[int]
		for i in range(w * h): is_target.push(0)
		for k in range(targets.length / 4):
			int node = mm_obstacle_lower(ys, targets[k * 4 + 1]) * w + mm_obstacle_lower(xs, targets[k * 4])
			target_node.push(node)
			is_target[node] = 1
		int best = MM_OBSTACLE_INFINITY
		int best_state = -1
		int best_target = -1
		while (heap_cost.length > 0):
			int c = 0
			int v = mm_obstacle_heap_pop(heap_cost, heap_state, &c)
			if (c > dist[v]): continue
			if (c >= best): break
			int node = v / 2
			int axis = v % 2
			if (is_target[node]):
				for k in range(target_node.length):
					if (target_node[k] != node): continue
					int total = c + targets[k * 4 + 3]
					if (axis != targets[k * 4 + 2]): total = total + MM_OBSTACLE_BEND
					if (total < best):
						best = total
						best_state = v
						best_target = k
			int i = node % w
			int j = node / w
			for direction in range(4):
				int ni = i
				int nj = j
				int edge_cost = -1
				int length = 0
				int next_axis = 0
				if (direction == 0 && i + 1 < w):
					ni = i + 1
					edge_cost = hcost[j * w + i]
					length = xs[ni] - xs[i]
				else if (direction == 1 && i > 0):
					ni = i - 1
					edge_cost = hcost[j * w + ni]
					length = xs[i] - xs[ni]
				else if (direction == 2 && j + 1 < h):
					nj = j + 1
					edge_cost = vcost[j * w + i]
					length = ys[nj] - ys[j]
					next_axis = 1
				else if (direction == 3 && j > 0):
					nj = j - 1
					edge_cost = vcost[nj * w + i]
					length = ys[j] - ys[nj]
					next_axis = 1
				if (edge_cost < 0): continue
				int next_cost = c + length + edge_cost
				if (next_axis != axis): next_cost = next_cost + MM_OBSTACLE_BEND
				int next_state = (nj * w + ni) * 2 + next_axis
				if (next_cost < dist[next_state]):
					dist[next_state] = next_cost
					previous[next_state] = v
					mm_obstacle_heap_push(heap_cost, heap_state, next_cost, next_state)
		if (best_state >= 0):
			# Walk back to the start, then keep only the corners.
			list[int] trail = new list[int]
			int v = best_state
			while (v >= 0):
				trail.push(v / 2)
				v = previous[v]
			chosen[1] = best_target
			chosen[0] = 0
			for k in range(start_node.length):
				if (start_node[k] == trail[trail.length - 1]):
					chosen[0] = k
					break
			for k in range(trail.length):
				int node = trail[trail.length - 1 - k]
				mm_route_point_push(out, xs[node % w], ys[node / w])
			__w_list_free(cast(__w_list*, trail))
			found = 1
		__w_list_free(cast(__w_list*, hcost))
		__w_list_free(cast(__w_list*, vcost))
		__w_list_free(cast(__w_list*, dist))
		__w_list_free(cast(__w_list*, previous))
		__w_list_free(cast(__w_list*, heap_cost))
		__w_list_free(cast(__w_list*, heap_state))
		__w_list_free(cast(__w_list*, start_node))
		__w_list_free(cast(__w_list*, target_node))
		__w_list_free(cast(__w_list*, is_target))
	__w_list_free(cast(__w_list*, xs))
	__w_list_free(cast(__w_list*, ys))
	__w_list_free(cast(__w_list*, inside))
	if (found):
		# Every rect, not only the region's, stays clear.
		for k in range(out.length / 2 - 1):
			for r in range(rect_count):
				if (mm_obstacle_segment_blocked(rects, r, out[k * 2], out[k * 2 + 1], out[k * 2 + 2], out[k * 2 + 3])): found = 0
	return found

# Draw an obstacle route translated by (tx, ty): straight legs, or with
# corners rounded within the clearance when smooth (basis curves).
void mm_route_points_draw(mm_scene* s, list[int] points, int tx, int ty, int smooth, int dashed):
	int n = points.length / 2
	int x = points[0] + tx
	int y = points[1] + ty
	for k in range(1, n):
		int cx = points[k * 2] + tx
		int cy = points[k * 2 + 1] + ty
		if (smooth == 0 || k == n - 1):
			mm_line(s, x, y, cx, cy, dashed)
			x = cx
			y = cy
			continue
		int nx = points[k * 2 + 2] + tx
		int ny = points[k * 2 + 3] + ty
		int before = mm_abs(cx - x) + mm_abs(cy - y)
		int after = mm_abs(nx - cx) + mm_abs(ny - cy)
		int radius = MM_OBSTACLE_MARGIN
		if (before / 2 < radius): radius = before / 2
		if (after / 2 < radius): radius = after / 2
		int in_x = cx - mm_sign(cx - x) * radius
		int in_y = cy - mm_sign(cy - y) * radius
		int out_x = cx + mm_sign(nx - cx) * radius
		int out_y = cy + mm_sign(ny - cy) * radius
		mm_line(s, x, y, in_x, in_y, dashed)
		mm_style_bezier(s, in_x, in_y, cx, cy, cx, cy, out_x, out_y, dashed)
		x = out_x
		y = out_y
