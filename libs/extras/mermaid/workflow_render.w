# Swimlane placement aligns graph ranks across responsibility lanes; nested
# subgraphs are clusters drawn inside their lane. Event modeling places frames
# on a declaration-order timeline across typed lanes.
import libs.extras.mermaid.framework_render
import libs.extras.mermaid.shapes
import libs.extras.mermaid.style_render
import libs.extras.mermaid.workflows

# Nested clusters between a node and its lane, innermost first, into path.
void mm_workflow_path(mm_document* d, int index, list[int] path):
	while (path.length > 0): path.pop()
	mm_node* n = d.nodes[index]
	int at = n.parent
	int guard = 0
	while (at >= 0 && guard <= d.nodes.length):
		mm_node* group = d.nodes[at]
		if (group.parent < 0): break
		path.push(at)
		at = group.parent
		guard = guard + 1

# Outermost cluster below the lane (or the node itself): the stacking key
# that keeps a cluster's members contiguous.
int mm_workflow_key(mm_document* d, int index, list[int] path):
	mm_workflow_path(d, index, path)
	if (path.length == 0): return index
	return path[path.length - 1]

int mm_workflow_levels(list[int] a, list[int] b):
	int common = 0
	while (common < a.length && common < b.length && a[a.length - 1 - common] == b[b.length - 1 - common]): common = common + 1
	return a.length - common + b.length - common

# Event-model annotation lines for frame index: notes, then gwt specs.
int mm_workflow_annotations(mm_document* d, int index):
	int lines = 0
	for mm_note* note in d.notes:
		if (note.node != index || (note.side != MM_EM_NOTE && note.side != MM_EM_GWT)): continue
		lines = lines + 1
		for i in range(strlen(note.text)):
			if (note.text[i] == 10): lines = lines + 1
	return lines

void mm_workflow_lines(mm_scene* s, int x, int y, char* text, int* row):
	int start = 0
	int length = strlen(text)
	for i in range(length + 1):
		if (i == length || text[i] == 10):
			char* line = str_copy_range(text, start, i)
			int content = 0
			while (line[content] != 0 && (line[content] & 255) <= 32): content = content + 1
			if (line[content] != 0):
				mm_text(s, x, y + *row * 24, line)
				*row = *row + 1
			free(line)
			start = i + 1

# Last segment of a link with its target marker: arrow, cross (6) or circle (8).
void mm_workflow_end(mm_scene* s, mm_edge* e, int ax, int ay, int bx, int by):
	if (e.arrow): mm_framework_arrow(s, ax, ay, bx, by, e.dashed)
	else: mm_line(s, ax, ay, bx, by, e.dashed)
	if (e.right_marker == 0): return
	float dx = cast(float, bx - ax)
	float dy = cast(float, by - ay)
	float length = fsqrt(dx * dx + dy * dy)
	if (length < 1.0): return
	int ux = cast(int, dx / length * 8.0)
	int uy = cast(int, dy / length * 8.0)
	int cx = bx - ux
	int cy = by - uy
	if (e.right_marker == 6):
		mm_line(s, cx - 5, cy - 5, cx + 5, cy + 5, 0)
		mm_line(s, cx - 5, cy + 5, cx + 5, cy - 5, 0)
	else: mm_draw(s, MM_CIRCLE, cx - 5, cy - 5, cx + 5, cy + 5, 0, c"")

void mm_workflow_start(mm_scene* s, mm_edge* e, int ax, int ay, int nx, int ny):
	if (e.left_marker == 0): return
	float dx = cast(float, ax - nx)
	float dy = cast(float, ay - ny)
	float length = fsqrt(dx * dx + dy * dy)
	if (length < 1.0): return
	int ux = cast(int, dx / length * 12.0)
	int uy = cast(int, dy / length * 12.0)
	int px = cast(int, 0.0 - dy / length * 6.0)
	int py = cast(int, dx / length * 6.0)
	mm_line(s, ax, ay, ax - ux + px, ay - uy + py, 0)
	mm_line(s, ax, ay, ax - ux - px, ay - uy - py, 0)

# Orthogonal link routing across lanes (issue #817). Coordinates are
# normalized so ranks advance along u (x for LR/RL and event models, y for
# TB/BT; negated for RL/BT) and lanes stack along v. Rank columns never
# overlap, so the gap after each column is a channel free of steps. A link
# leaves its source's far side into the channel after the source column,
# runs along v to a track, follows the track to the channel before the
# target column and enters the target's near side. The track is the
# target's (or source's) own center line when that is clear of every step
# between the two channels, else the nearest clear line just above or
# below a blocking step, so no segment crosses a step box. Channel and
# track segments of unrelated links are offset (8px steps) when they would
# overlap, so parallel links stay distinguishable.
const int MM_WF_CLEAR = 10
const int MM_WF_SLOT = 8

struct mm_wf_router:
	int horizontal
	int reverse
	# Normalized step boxes (u0, u1, v0, v1) per node, -1 rank for clusters.
	list[int] u0
	list[int] u1
	list[int] v0
	list[int] v1
	list[int] ranks
	# Occupied routes: kind 0 channel (u fixed), 1 track (v fixed).
	list[int] seg_kind
	list[int] seg_at
	list[int] seg_lo
	list[int] seg_hi
	list[int] seg_from
	list[int] seg_to
	# Nested cluster frames (u0, u1, v0) whose title band tracks avoid in
	# horizontal layouts, and placed label boxes in screen coordinates.
	list[int] band_u0
	list[int] band_u1
	list[int] band_v
	list[int] label_x0
	list[int] label_y0
	list[int] label_x1
	list[int] label_y1

int mm_wf_u(mm_wf_router* r, int x, int y):
	int u = y
	if (r.horizontal): u = x
	if (r.reverse): u = 0 - u
	return u

int mm_wf_v(mm_wf_router* r, int x, int y):
	if (r.horizontal): return y
	return x

int mm_wf_x(mm_wf_router* r, int u, int v):
	if (r.reverse): u = 0 - u
	if (r.horizontal): return u
	return v

int mm_wf_y(mm_wf_router* r, int u, int v):
	if (r.reverse): u = 0 - u
	if (r.horizontal): return v
	return u

mm_wf_router* mm_wf_router_new(mm_document* d, mm_scene* s, int horizontal, int reverse):
	mm_wf_router* r = new mm_wf_router()
	r.horizontal = horizontal
	r.reverse = reverse
	r.u0 = new list[int]
	r.u1 = new list[int]
	r.v0 = new list[int]
	r.v1 = new list[int]
	r.ranks = new list[int]
	r.seg_kind = new list[int]
	r.seg_at = new list[int]
	r.seg_lo = new list[int]
	r.seg_hi = new list[int]
	r.seg_from = new list[int]
	r.seg_to = new list[int]
	r.band_u0 = new list[int]
	r.band_u1 = new list[int]
	r.band_v = new list[int]
	r.label_x0 = new list[int]
	r.label_y0 = new list[int]
	r.label_x1 = new list[int]
	r.label_y1 = new list[int]
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		int a = mm_wf_u(r, b.x, b.y)
		int c = mm_wf_u(r, b.x + b.w, b.y + b.h)
		if (c < a):
			int swap = a
			a = c
			c = swap
		r.u0.push(a)
		r.u1.push(c)
		r.v0.push(mm_wf_v(r, b.x, b.y))
		r.v1.push(mm_wf_v(r, b.x + b.w, b.y + b.h))
		if (n.group): r.ranks.push(-1)
		else: r.ranks.push(b.rank)
		if (n.group && n.parent >= 0 && b.w > 0 && horizontal):
			r.band_u0.push(a)
			r.band_u1.push(c)
			r.band_v.push(b.y)
	return r

void mm_wf_router_free(mm_wf_router* r):
	__w_list_free(cast(__w_list*, r.u0))
	__w_list_free(cast(__w_list*, r.u1))
	__w_list_free(cast(__w_list*, r.v0))
	__w_list_free(cast(__w_list*, r.v1))
	__w_list_free(cast(__w_list*, r.ranks))
	__w_list_free(cast(__w_list*, r.seg_kind))
	__w_list_free(cast(__w_list*, r.seg_at))
	__w_list_free(cast(__w_list*, r.seg_lo))
	__w_list_free(cast(__w_list*, r.seg_hi))
	__w_list_free(cast(__w_list*, r.seg_from))
	__w_list_free(cast(__w_list*, r.seg_to))
	__w_list_free(cast(__w_list*, r.band_u0))
	__w_list_free(cast(__w_list*, r.band_u1))
	__w_list_free(cast(__w_list*, r.band_v))
	__w_list_free(cast(__w_list*, r.label_x0))
	__w_list_free(cast(__w_list*, r.label_y0))
	__w_list_free(cast(__w_list*, r.label_x1))
	__w_list_free(cast(__w_list*, r.label_y1))
	free(r)

# Extent of rank's column along u; 0 when the rank holds no step.
int mm_wf_column(mm_wf_router* r, int rank, int* lo, int* hi):
	int any = 0
	for i in range(r.ranks.length):
		if (r.ranks[i] != rank): continue
		if (any == 0 || r.u0[i] < *lo): *lo = r.u0[i]
		if (any == 0 || r.u1[i] > *hi): *hi = r.u1[i]
		any = 1
	return any

# Channel center just past (after = 1) or before a rank's column.
int mm_wf_channel(mm_wf_router* r, int rank, int after):
	int lo = 0
	int hi = 0
	mm_wf_column(r, rank, &lo, &hi)
	int max_rank = 0
	for int k in r.ranks:
		if (k > max_rank): max_rank = k
	int other = rank - 1
	if (after): other = rank + 1
	while (other >= 0 && other <= max_rank):
		int olo = 0
		int ohi = 0
		if (mm_wf_column(r, other, &olo, &ohi)):
			if (after): return (hi + olo) / 2
			return (ohi + lo) / 2
		if (after): other = other + 1
		else: other = other - 1
	if (after): return hi + 50
	return lo - 20

# 1 when the v line at `at` between u lo..hi touches no step box.
int mm_wf_track_clear(mm_wf_router* r, int at, int lo, int hi):
	for i in range(r.ranks.length):
		if (r.ranks[i] < 0): continue
		if (r.u1[i] < lo || r.u0[i] > hi): continue
		if (at > r.v0[i] - MM_WF_CLEAR && at < r.v1[i] + MM_WF_CLEAR): return 0
	for i in range(r.band_v.length):
		if (r.band_u1[i] < lo || r.band_u0[i] > hi): continue
		if (at > r.band_v[i] - 4 && at < r.band_v[i] + 30): return 0
	return 1

# 1 when a new segment would overlap an unrelated link's segment.
int mm_wf_busy(mm_wf_router* r, int kind, int at, int lo, int hi, int from, int to):
	for i in range(r.seg_kind.length):
		if (r.seg_kind[i] != kind || r.seg_from[i] == from || r.seg_to[i] == to): continue
		if (at > r.seg_at[i] - MM_WF_SLOT / 2 - 1 && at < r.seg_at[i] + MM_WF_SLOT / 2 + 1 && lo < r.seg_hi[i] + 4 && hi > r.seg_lo[i] - 4): return 1
	return 0

void mm_wf_occupy(mm_wf_router* r, int kind, int at, int a, int b, int from, int to):
	int lo = a
	int hi = b
	if (hi < lo):
		lo = b
		hi = a
	r.seg_kind.push(kind)
	r.seg_at.push(at)
	r.seg_lo.push(lo)
	r.seg_hi.push(hi)
	r.seg_from.push(from)
	r.seg_to.push(to)

# A free channel offset near center for a segment spanning v lo..hi.
int mm_wf_channel_slot(mm_wf_router* r, int center, int a, int b, int from, int to):
	int lo = a
	int hi = b
	if (hi < lo):
		lo = b
		hi = a
	for k in range(9):
		int offset = (k + 1) / 2 * MM_WF_SLOT
		if (k % 2 == 0): offset = 0 - offset
		if (mm_wf_busy(r, 0, center + offset, lo, hi, from, to) == 0): return center + offset
	return center

# Clear track between channels c1 and c2 nearest the endpoints' centers.
int mm_wf_track(mm_wf_router* r, int av, int bv, int c1, int c2, int from, int to):
	int lo = c1
	int hi = c2
	if (hi < lo):
		lo = c2
		hi = c1
	list[int] candidates = new list[int]
	candidates.push(bv)
	candidates.push(av)
	for i in range(r.ranks.length):
		if (r.ranks[i] < 0 || r.u1[i] < lo || r.u0[i] > hi): continue
		candidates.push(r.v0[i] - 2 * MM_WF_CLEAR)
		candidates.push(r.v1[i] + 2 * MM_WF_CLEAR)
	int best = 0
	int best_cost = -1
	for int base in candidates:
		for k in range(5):
			int offset = (k + 1) / 2 * MM_WF_SLOT
			if (k % 2 == 0): offset = 0 - offset
			int at = base + offset
			if (mm_wf_track_clear(r, at, lo, hi) == 0 || mm_wf_busy(r, 1, at, lo, hi, from, to)): continue
			int cost = at - av
			if (cost < 0): cost = 0 - cost
			int other = at - bv
			if (other < 0): other = 0 - other
			cost = cost + other
			if (best_cost < 0 || cost < best_cost):
				best = at
				best_cost = cost
			break
	__w_list_free(cast(__w_list*, candidates))
	if (best_cost >= 0): return best
	# Nothing clear between the channels: run past every step.
	int outside = 0
	for i in range(r.ranks.length):
		if (r.ranks[i] >= 0 && r.v1[i] > outside): outside = r.v1[i]
	return outside + 3 * MM_WF_CLEAR

# Normalized route of a link from step a to step b into us/vs; returns the
# index of the segment that carries the label.
int mm_wf_route(mm_wf_router* r, int a, int b, list[int] us, list[int] vs):
	int av = (r.v0[a] + r.v1[a]) / 2
	int bv = (r.v0[b] + r.v1[b]) / 2
	int c1 = mm_wf_channel(r, r.ranks[a], 1)
	int c2 = mm_wf_channel(r, r.ranks[b], 0)
	us.push(r.u1[a])
	vs.push(av)
	int label = 0
	if (c1 == c2 && r.ranks[b] > r.ranks[a]):
		if (av != bv):
			int c = mm_wf_channel_slot(r, c1, av, bv, a, b)
			mm_wf_occupy(r, 0, c, av, bv, a, b)
			us.push(c)
			vs.push(av)
			us.push(c)
			vs.push(bv)
			label = 1
	else:
		int t = mm_wf_track(r, av, bv, c1, c2, a, b)
		int first = c1
		if (t != av):
			first = mm_wf_channel_slot(r, c1, av, t, a, b)
			mm_wf_occupy(r, 0, first, av, t, a, b)
		int second = c2
		if (t != bv):
			second = mm_wf_channel_slot(r, c2, t, bv, a, b)
			mm_wf_occupy(r, 0, second, t, bv, a, b)
		mm_wf_occupy(r, 1, t, first, second, a, b)
		if (t != av):
			us.push(first)
			vs.push(av)
		us.push(first)
		vs.push(t)
		label = us.length - 1
		us.push(second)
		vs.push(t)
		if (t != bv):
			us.push(second)
			vs.push(bv)
	us.push(r.u0[b])
	vs.push(bv)
	return label

# 1 when a label box at (x, y) of size w x h touches a step box or a label
# placed before it.
int mm_wf_label_clear(mm_document* d, mm_scene* s, mm_wf_router* r, int x, int y, int w, int h):
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		if (n.group): continue
		if (x < b.x + b.w + 2 && x + w > b.x - 2 && y < b.y + b.h + 2 && y + h > b.y - 2): return 0
	for i in range(r.label_x0.length):
		if (x < r.label_x1[i] + 2 && x + w > r.label_x0[i] - 2 && y < r.label_y1[i] + 2 && y + h > r.label_y0[i] - 2): return 0
	return 1

# Link labels sit beside their segment at the first of several positions
# along it (middle first, either side) that overlaps no step and no other
# label; with none clear they keep the middle position.
void mm_wf_label(mm_document* d, mm_scene* s, mm_wf_router* r, char* text, int x0, int y0, int x1, int y1):
	int w = mm_text_width(text, 0)
	int h = MM_TEXT_LINE
	list[int] fractions = list[int]{50, 30, 70, 15, 85}
	int vertical = x0 == x1
	int best_x = (x0 + x1) / 2 + 6
	int best_y = (y0 + y1) / 2 - 8
	if (vertical == 0):
		best_x = (x0 + x1) / 2 - w / 2
		best_y = y0 - 20
	int found = 0
	for int f in fractions:
		if (found): break
		int px = x0 + (x1 - x0) * f / 100
		int py = y0 + (y1 - y0) * f / 100
		for side in range(2):
			int x = px + 6
			int y = py - h / 2
			if (vertical && side == 1): x = px - 6 - w
			if (vertical == 0):
				x = px - w / 2
				y = py - 20
				if (side == 1): y = py + 4
			if (mm_wf_label_clear(d, s, r, x, y, w, h)):
				best_x = x
				best_y = y
				found = 1
				break
	__w_list_free(cast(__w_list*, fractions))
	mm_text(s, best_x, best_y, text)
	r.label_x0.push(best_x)
	r.label_y0.push(best_y)
	r.label_x1.push(best_x + w)
	r.label_y1.push(best_y + h)

# Draw a routed link: start marker on the first segment, target marker on
# the last, label beside the segment the router chose.
void mm_wf_draw(mm_document* d, mm_scene* s, mm_wf_router* r, mm_edge* e, list[int] us, list[int] vs, int label):
	int count = us.length
	list[int] xs = new list[int]
	list[int] ys = new list[int]
	for k in range(count):
		xs.push(mm_wf_x(r, us[k], vs[k]))
		ys.push(mm_wf_y(r, us[k], vs[k]))
	for k in range(count - 2): mm_line(s, xs[k], ys[k], xs[k + 1], ys[k + 1], e.dashed)
	mm_workflow_end(s, e, xs[count - 2], ys[count - 2], xs[count - 1], ys[count - 1])
	mm_workflow_start(s, e, xs[0], ys[0], xs[1], ys[1])
	if (e.label[0] != 0): mm_wf_label(d, s, r, e.label, xs[label], ys[label], xs[label + 1], ys[label + 1])
	__w_list_free(cast(__w_list*, xs))
	__w_list_free(cast(__w_list*, ys))

mm_scene* mm_workflow_render(mm_document* d):
	mm_scene* s = mm_framework_scene(d)
	int event = d.kind == MM_EVENT_MODEL
	int horizontal = strcmp(d.direction, c"LR") == 0 || strcmp(d.direction, c"RL") == 0 || event
	int reverse = strcmp(d.direction, c"RL") == 0 || strcmp(d.direction, c"BT") == 0
	list[int] done = new list[int]
	list[int] incoming = new list[int]
	list[int] path = new list[int]
	list[int] other = new list[int]
	int max_rank = 0
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		b.w = mm_text_width(n.label, 0) + 40
		b.h = 60
		if (b.w < 180): b.w = 180
		if (event == 0 && n.group == 0): mm_shape_size(n.shape, &b.w, &b.h)
		if (event && n.group == 0):
			int lines = n.members.length + mm_workflow_annotations(d, i)
			b.h = 90 + lines * 24
			if (mm_workflow_annotations(d, i) > 0): b.h = b.h + 12
			for mm_member* m in n.members:
				if (mm_text_width(m.text, 0) + 32 > b.w): b.w = mm_text_width(m.text, 0) + 32
			for mm_note* note in d.notes:
				if (note.node == i && mm_text_width(note.text, 0) + 32 > b.w): b.w = mm_text_width(note.text, 0) + 32
			b.rank = n.value_x
			if (b.rank > max_rank): max_rank = b.rank
		int count = 0
		for mm_edge* e in d.edges:
			if (e.to_node == i && e.from_node != i): count = count + 1
		incoming.push(count)
		done.push(n.group)
	if (event == 0):
		for step in range(d.nodes.length):
			int index = -1
			for i in range(d.nodes.length):
				if (done[i] == 0 && incoming[i] == 0 && index < 0): index = i
			if (index < 0):
				int best_rank = -1
				for i in range(d.nodes.length):
					mm_bounds* candidate = s.nodes[i]
					if (done[i] == 0 && candidate.rank > best_rank):
						index = i
						best_rank = candidate.rank
			if (index < 0): break
			done[index] = 1
			mm_bounds* from = s.nodes[index]
			if (from.rank > max_rank): max_rank = from.rank
			for mm_edge* e in d.edges:
				if (e.from_node == index && done[e.to_node] == 0):
					mm_bounds* to = s.nodes[e.to_node]
					if (to.rank <= from.rank): to.rank = from.rank + 1
					incoming[e.to_node] = incoming[e.to_node] - 1
	__w_list_free(cast(__w_list*, done))
	__w_list_free(cast(__w_list*, incoming))
	list[int] sizes = new list[int]
	for i in range(max_rank + 1): sizes.push(0)
	int header = 80
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		if (n.group):
			if (horizontal && n.parent < 0 && mm_text_width(n.label, 0) + 40 > header): header = mm_text_width(n.label, 0) + 40
			continue
		int size = b.h
		if (horizontal): size = b.w
		if (size > sizes[b.rank]): sizes[b.rank] = size
	int major = 40
	for int size in sizes: major = major + size + 100
	# Lanes are top-level groups; event lanes group automation, command / read
	# model and event lanes in that order, each in order of first appearance.
	list[int] lanes = new list[int]
	for kind in range(3):
		for i in range(d.nodes.length):
			mm_node* n = d.nodes[i]
			if (n.group == 0 || n.parent >= 0): continue
			if ((event && n.value_y == kind) || (event == 0 && kind == 0)): lanes.push(i)
	int lane_offset = 40
	list[int] stacked = new list[int]
	for int lane in lanes:
		mm_node* group = d.nodes[lane]
		int minor = 100
		if (horizontal == 0 && mm_text_width(group.label, 0) + 40 > minor): minor = mm_text_width(group.label, 0) + 40
		for rank in range(max_rank + 1):
			while (stacked.length > 0): stacked.pop()
			for i in range(d.nodes.length):
				mm_node* n = d.nodes[i]
				mm_bounds* b = s.nodes[i]
				if (n.group || b.rank != rank || mm_swim_lane(d, i) != lane): continue
				# Insert by cluster key so cluster members stay contiguous.
				int key = mm_workflow_key(d, i, path)
				int at = stacked.length
				for j in range(stacked.length):
					if (at == stacked.length && mm_workflow_key(d, stacked[j], other) > key): at = j
				stacked.push(i)
				int k = stacked.length - 1
				while (k > at):
					stacked[k] = stacked[k - 1]
					k = k - 1
				stacked[at] = i
			int stack = 40
			while (other.length > 0): other.pop()
			for int i in stacked:
				mm_node* n = d.nodes[i]
				mm_bounds* b = s.nodes[i]
				mm_workflow_path(d, i, path)
				# Room for the cluster frames (14px padding, 22px title) that open or close here.
				stack = stack + mm_workflow_levels(path, other) * 24
				while (other.length > 0): other.pop()
				for int cluster in path: other.push(cluster)
				int position = header + 40
				if (reverse):
					for j in range(rank + 1, sizes.length): position = position + sizes[j] + 100
				else:
					for j in range(rank): position = position + sizes[j] + 100
				if (horizontal):
					b.x = position + 40
					b.y = lane_offset + stack
					stack = stack + b.h + 40
				else:
					b.x = lane_offset + stack
					b.y = position + 40
					stack = stack + b.w + 40
			stack = stack + other.length * 24
			if (stack > minor): minor = stack
		mm_bounds* box = s.nodes[lane]
		if (horizontal):
			box.x = 40
			box.y = lane_offset
			box.w = major + header
			box.h = minor
		else:
			box.x = lane_offset
			box.y = 40
			box.w = minor
			box.h = major + header
		lane_offset = lane_offset + minor + 20
		int style_start = s.items.length
		mm_draw(s, MM_BOX, box.x, box.y, box.x + box.w, box.y + box.h, 0, c"")
		mm_text(s, box.x + 16, box.y + 16, group.label)
		if (horizontal): mm_line(s, box.x + header, box.y, box.x + header, box.y + box.h, 0)
		else: mm_line(s, box.x, box.y + header, box.x + box.w, box.y + header, 0)
		mm_style_node(d, s, group, style_start)
	__w_list_free(cast(__w_list*, stacked))
	__w_list_free(cast(__w_list*, lanes))
	__w_list_free(cast(__w_list*, path))
	__w_list_free(cast(__w_list*, other))
	# Nested clusters wrap their members; children are declared after their
	# parent, so a reverse pass sizes inner clusters first.
	int cluster = d.nodes.length - 1
	while (cluster >= 0):
		mm_node* group = d.nodes[cluster]
		if (group.group && group.parent >= 0):
			int x0 = 0
			int y0 = 0
			int x1 = 0
			int y1 = 0
			int any = 0
			for i in range(d.nodes.length):
				mm_node* child = d.nodes[i]
				mm_bounds* b = s.nodes[i]
				if (child.parent != cluster || (child.group && b.w == 0)): continue
				if (any == 0 || b.x < x0): x0 = b.x
				if (any == 0 || b.y < y0): y0 = b.y
				if (any == 0 || b.x + b.w > x1): x1 = b.x + b.w
				if (any == 0 || b.y + b.h > y1): y1 = b.y + b.h
				any = 1
			mm_bounds* box = s.nodes[cluster]
			if (any):
				box.x = x0 - 14
				box.y = y0 - 36
				box.w = x1 - x0 + 28
				box.h = y1 - y0 + 50
				if (mm_text_width(group.label, 0) + 28 > box.w): box.w = mm_text_width(group.label, 0) + 28
			else:
				mm_bounds* lane = s.nodes[mm_swim_lane(d, cluster)]
				box.x = lane.x
				box.y = lane.y
				box.w = 0
				box.h = 0
		cluster = cluster - 1
	for i in range(d.nodes.length):
		mm_node* group = d.nodes[i]
		mm_bounds* box = s.nodes[i]
		if (group.group == 0 || group.parent < 0 || box.w == 0): continue
		int style_start = s.items.length
		mm_draw(s, MM_BOX, box.x, box.y, box.x + box.w, box.y + box.h, 1, c"")
		mm_text(s, box.x + 12, box.y + 8, group.label)
		mm_style_node(d, s, group, style_start)
	mm_wf_router* router = mm_wf_router_new(d, s, horizontal, reverse)
	list[int] us = new list[int]
	list[int] vs = new list[int]
	for mm_edge* e in d.edges:
		int edge_start = s.items.length
		mm_bounds* a = s.nodes[e.from_node]
		if (e.from_node != e.to_node):
			us.clear()
			vs.clear()
			int label = mm_wf_route(router, e.from_node, e.to_node, us, vs)
			mm_wf_draw(d, s, router, e, us, vs, label)
			mm_style_edge(d, s, e, edge_start)
			continue
		# Self loops: a short bracket beside the step's far side.
		int ax = a.x + a.w
		int bx = ax
		int ay = a.y + 16
		int by = a.y + a.h - 16
		if (horizontal == 0):
			ay = a.y + a.h
			by = ay
			ax = a.x + 16
			bx = a.x + a.w - 16
		int mx = (ax + bx) / 2
		int my = (ay + by) / 2
		if (horizontal):
			mx = a.x + a.w + 30
			mm_line(s, ax, ay, mx, ay, e.dashed)
			mm_workflow_start(s, e, ax, ay, mx, ay)
			mm_line(s, mx, ay, mx, by, e.dashed)
			mm_workflow_end(s, e, mx, by, bx, by)
		else:
			my = a.y + a.h + 30
			mm_line(s, ax, ay, ax, my, e.dashed)
			mm_workflow_start(s, e, ax, ay, ax, my)
			mm_line(s, ax, my, bx, my, e.dashed)
			mm_workflow_end(s, e, bx, my, bx, by)
		mm_style_edge(d, s, e, edge_start)
		mm_text(s, mx + 8, my - 20, e.label)
	__w_list_free(cast(__w_list*, us))
	__w_list_free(cast(__w_list*, vs))
	mm_wf_router_free(router)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.group): continue
		mm_bounds* b = s.nodes[i]
		int style_start = s.items.length
		if (event): mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, n.shape == 1, c"")
		else: mm_shape_draw(s, n.shape, b.x, b.y, b.w, b.h)
		if (event):
			string_builder* heading = string_from(n.annotation)
			mm_property* data_type = mm_agent_get(n.metadata, c"dataType")
			if (data_type != 0):
				string_append(heading, c" [")
				string_append(heading, data_type.value)
				string_append_char(heading, ']')
			mm_text(s, b.x + 12, b.y + 12, heading.data)
			string_free(heading)
			mm_text(s, b.x + 12, b.y + 38, n.label)
			for j in range(n.members.length):
				mm_member* m = n.members[j]
				mm_text(s, b.x + 12, b.y + 64 + j * 24, m.text)
			int row = 0
			int top = b.y + 76 + n.members.length * 24
			if (mm_workflow_annotations(d, i) > 0): mm_line(s, b.x + 8, top - 6, b.x + b.w - 8, top - 6, 1)
			for mm_note* note in d.notes:
				if (note.node == i && note.side == MM_EM_NOTE): mm_workflow_lines(s, b.x + 12, top, note.text, &row)
			for mm_note* note in d.notes:
				if (note.node == i && note.side == MM_EM_GWT): mm_workflow_lines(s, b.x + 12, top, note.text, &row)
		else:
			int label_y = b.y + mm_shape_label_y(n.shape, b.h, 16)
			mm_text(s, b.x + (b.w - mm_text_width(n.label, 0)) / 2, label_y, n.label)
		mm_style_node(d, s, n, style_start)
	__w_list_free(cast(__w_list*, sizes))
	if (s.width < 240): s.width = 240
	if (s.height < 160): s.height = 160
	return s
