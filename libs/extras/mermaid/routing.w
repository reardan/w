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
