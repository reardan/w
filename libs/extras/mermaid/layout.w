# Bounded deterministic graph layout helpers, independent of rendering backends.
import libs.extras.mermaid.scene
import libs.extras.mermaid.text

# Layered (Sugiyama-style) placement. Every edge spanning several ranks is
# split into a chain of dummy nodes, one per intermediate rank, so the
# crossing reduction sees each rank-to-rank segment and coordinate assignment
# reserves a free channel for the edge beside the real nodes of that rank.
# Ordering alternates barycenter sweeps with adjacent-transposition passes and
# keeps the order with the fewest counted crossings. Every pass is
# O((V + S) log V) for V real plus dummy nodes and S segments; transpositions
# share one fixed work budget, so dense graphs stay bounded and deterministic.

# Real plus dummy nodes one layout may hold; edges past it keep direct routes.
const int MM_LAYOUT_VIRTUAL_LIMIT = 32768
# Total neighbor comparisons the transposition passes may spend per layout.
const int MM_LAYOUT_TRANSPOSE_WORK = 2000000

# Rank-to-rank segment crossings of the last layered placement: in source
# order before reduction and in the final order (exposed for tests and docs).
int mm_layered_first_crossings
int mm_layered_last_crossings

struct mm_layered:
	int count
	int max_rank
	# Per virtual node: logical rank, index within its rank, cross-axis coordinate.
	list[int] rank
	list[int] position
	list[int] lane
	# Rank buckets in the current order, flattened: rank r is order[rank_start[r]..rank_start[r+1]).
	list[int] order
	list[int] rank_start
	# Neighbors in the rank above / below (CSR over virtual nodes).
	list[int] up_start
	list[int] up
	list[int] down_start
	list[int] down
	# Segments join adjacent ranks; seg_order groups them by their upper rank.
	list[int] seg_upper
	list[int] seg_lower
	list[int] seg_start
	list[int] seg_order
	# Scratch shared by sorting and crossing counts.
	list[int] keys
	list[int] items
	list[int] scratch
	list[int] tree
	int work

void mm_layered_free(mm_layered* g):
	__w_list_free(cast(__w_list*, g.rank))
	__w_list_free(cast(__w_list*, g.position))
	__w_list_free(cast(__w_list*, g.lane))
	__w_list_free(cast(__w_list*, g.order))
	__w_list_free(cast(__w_list*, g.rank_start))
	__w_list_free(cast(__w_list*, g.up_start))
	__w_list_free(cast(__w_list*, g.up))
	__w_list_free(cast(__w_list*, g.down_start))
	__w_list_free(cast(__w_list*, g.down))
	__w_list_free(cast(__w_list*, g.seg_upper))
	__w_list_free(cast(__w_list*, g.seg_lower))
	__w_list_free(cast(__w_list*, g.seg_start))
	__w_list_free(cast(__w_list*, g.seg_order))
	__w_list_free(cast(__w_list*, g.keys))
	__w_list_free(cast(__w_list*, g.items))
	__w_list_free(cast(__w_list*, g.scratch))
	__w_list_free(cast(__w_list*, g.tree))
	free(g)

# Stable bottom-up merge sort of items[start..end) by keys[item].
void mm_layout_sort(list[int] items, int start, int end, list[int] keys, list[int] scratch):
	int count = end - start
	int width = 1
	while (width < count):
		int left = 0
		while (left < count):
			int mid = left + width
			if (mid > count): mid = count
			int right = mid + width
			if (right > count): right = count
			int i = left
			int j = mid
			int k = left
			while (i < mid || j < right):
				if (j >= right || (i < mid && keys[items[start + i]] <= keys[items[start + j]])):
					scratch[k] = items[start + i]
					i = i + 1
				else:
					scratch[k] = items[start + j]
					j = j + 1
				k = k + 1
			left = right
		for t in range(count): items[start + t] = scratch[t]
		width = width * 2

# Compressed adjacency: for each node v, targets[start[v]..start[v+1]).
void mm_layered_csr(int count, list[int] from, list[int] to, list[int] start, list[int] targets):
	for i in range(count + 1): start.push(0)
	for int v in from: start[v + 1] = start[v + 1] + 1
	for i in range(count): start[i + 1] = start[i + 1] + start[i]
	list[int] fill = new list[int]
	for i in range(count): fill.push(start[i])
	for i in range(from.length): targets.push(0)
	for i in range(from.length):
		targets[fill[from[i]]] = to[i]
		fill[from[i]] = fill[from[i]] + 1
	__w_list_free(cast(__w_list*, fill))

# Crossings between ranks r and r + 1: sort segments by (upper, lower)
# position, then count earlier segments whose lower end lies further right.
int mm_layered_rank_crossings(mm_layered* g, int r):
	int first = g.seg_start[r]
	int last = g.seg_start[r + 1]
	if (last - first < 2): return 0
	int below = g.rank_start[r + 2] - g.rank_start[r + 1]
	for i in range(first, last):
		int segment = g.seg_order[i]
		g.items[i - first] = segment
		g.keys[segment] = g.position[g.seg_upper[segment]] * (below + 1) + g.position[g.seg_lower[segment]]
	mm_layout_sort(g.items, 0, last - first, g.keys, g.scratch)
	for i in range(below + 1): g.tree[i] = 0
	int crossings = 0
	for i in range(last - first):
		int lower = g.position[g.seg_lower[g.items[i]]] + 1
		int at_most = 0
		int at = lower
		while (at > 0):
			at_most = at_most + g.tree[at]
			at = at - (at & (0 - at))
		crossings = crossings + i - at_most
		at = lower
		while (at <= below):
			g.tree[at] = g.tree[at] + 1
			at = at + (at & (0 - at))
	return crossings

int mm_layered_crossings(mm_layered* g):
	int total = 0
	for r in range(g.max_rank): total = total + mm_layered_rank_crossings(g, r)
	return total

# One barycenter pass: down sweeps order each rank by its upper neighbors,
# up sweeps by its lower neighbors; nodes without any keep their slot.
void mm_layered_sweep(mm_layered* g, int downward):
	for step in range(g.max_rank + 1):
		int r = step
		if (downward == 0): r = g.max_rank - step
		int first = g.rank_start[r]
		int last = g.rank_start[r + 1]
		for i in range(first, last):
			int v = g.order[i]
			int sum = 0
			int count = 0
			if (downward):
				for k in range(g.up_start[v], g.up_start[v + 1]):
					sum = sum + g.position[g.up[k]]
					count = count + 1
			else:
				for k in range(g.down_start[v], g.down_start[v + 1]):
					sum = sum + g.position[g.down[k]]
					count = count + 1
			g.keys[v] = g.position[v] * 1024
			if (count): g.keys[v] = sum / count * 1024 + sum % count * 1024 / count
		mm_layout_sort(g.order, first, last, g.keys, g.scratch)
		for i in range(first, last): g.position[g.order[i]] = i - first

# Crossings among the segments of x and y (x placed left of y) on one side.
int mm_layered_pair_side(mm_layered* g, list[int] start, list[int] targets, int x, int y):
	int crossings = 0
	for i in range(start[x], start[x + 1]):
		int px = g.position[targets[i]]
		for j in range(start[y], start[y + 1]):
			if (px > g.position[targets[j]]): crossings = crossings + 1
	g.work = g.work + (start[x + 1] - start[x]) * (start[y + 1] - start[y]) + 1
	return crossings

int mm_layered_pair(mm_layered* g, int x, int y):
	return mm_layered_pair_side(g, g.up_start, g.up, x, y) + mm_layered_pair_side(g, g.down_start, g.down, x, y)

# Swap adjacent nodes while that strictly removes crossings.
void mm_layered_transpose(mm_layered* g):
	for r in range(g.max_rank + 1):
		int first = g.rank_start[r]
		int last = g.rank_start[r + 1]
		for round in range(4):
			int improved = 0
			for i in range(first, last - 1):
				if (g.work > MM_LAYOUT_TRANSPOSE_WORK): return
				int x = g.order[i]
				int y = g.order[i + 1]
				if (mm_layered_pair(g, y, x) < mm_layered_pair(g, x, y)):
					g.order[i] = y
					g.order[i + 1] = x
					g.position[y] = i - first
					g.position[x] = i + 1 - first
					improved = 1
			if (improved == 0): break

void mm_layered_order(mm_layered* g):
	list[int] best = new list[int]
	for int v in g.order: best.push(v)
	int least = mm_layered_crossings(g)
	mm_layered_first_crossings = least
	int rounds = 12
	if (g.count > 2048): rounds = 6
	int step = 0
	while (step < rounds && least > 0):
		mm_layered_sweep(g, step % 2 == 0)
		mm_layered_transpose(g)
		int crossings = mm_layered_crossings(g)
		if (crossings < least):
			least = crossings
			for i in range(g.order.length): best[i] = g.order[i]
		step = step + 1
	for i in range(best.length):
		g.order[i] = best[i]
	for r in range(g.max_rank + 1):
		for i in range(g.rank_start[r], g.rank_start[r + 1]): g.position[g.order[i]] = i - g.rank_start[r]
	__w_list_free(cast(__w_list*, best))

# Coordinate assignment after ordering: alternating passes pull every node
# toward the mean center of its neighbors in the rank just placed, solved per
# rank as a weighted isotonic regression (pool adjacent violators) under the
# order and the minimum spacing, so each pass is linear in the rank size.
# Dummy nodes weigh more, which straightens long edges into vertical channels
# instead of jogging across the drawing. Finally the drawing shifts so its
# leftmost (topmost) box starts at the 60px margin again.
void mm_layered_coordinates(mm_layered* g, list[int] size, int lane_gap, int real_count):
	list[float] center = new list[float]
	for v in range(g.count): center.push(cast(float, g.lane[v]) + cast(float, size[v]) / 2.0)
	list[float] target = new list[float]
	list[float] weight = new list[float]
	list[float] offset = new list[float]
	list[float] block_sum = new list[float]
	list[float] block_weight = new list[float]
	list[int] block_count = new list[int]
	for round in range(8):
		int downward = round % 2 == 0
		for step in range(g.max_rank + 1):
			int r = step
			if (downward == 0): r = g.max_rank - step
			int first = g.rank_start[r]
			int last = g.rank_start[r + 1]
			if (last == first): continue
			while (target.length > 0): target.pop()
			while (weight.length > 0): weight.pop()
			while (offset.length > 0): offset.pop()
			for i in range(first, last):
				int v = g.order[i]
				float sum = 0.0
				int count = 0
				if (downward):
					for k in range(g.up_start[v], g.up_start[v + 1]):
						sum = sum + center[g.up[k]]
						count = count + 1
				else:
					for k in range(g.down_start[v], g.down_start[v + 1]):
						sum = sum + center[g.down[k]]
						count = count + 1
				if (count > 0):
					target.push(sum / cast(float, count))
					if (v >= real_count): weight.push(8.0)
					else: weight.push(1.0)
				else:
					target.push(center[v])
					weight.push(0.25)
				if (i == first): offset.push(0.0)
				else:
					int previous = g.order[i - 1]
					int gap = lane_gap / 2
					if (v < real_count && previous < real_count): gap = lane_gap
					offset.push(offset[offset.length - 1] + cast(float, size[previous] + size[v]) / 2.0 + cast(float, gap))
			while (block_sum.length > 0): block_sum.pop()
			while (block_weight.length > 0): block_weight.pop()
			while (block_count.length > 0): block_count.pop()
			for t in range(last - first):
				block_sum.push((target[t] - offset[t]) * weight[t])
				block_weight.push(weight[t])
				block_count.push(1)
				while (block_sum.length > 1):
					int top = block_sum.length - 1
					if (block_sum[top - 1] / block_weight[top - 1] <= block_sum[top] / block_weight[top]): break
					block_sum[top - 1] = block_sum[top - 1] + block_sum[top]
					block_weight[top - 1] = block_weight[top - 1] + block_weight[top]
					block_count[top - 1] = block_count[top - 1] + block_count[top]
					block_sum.pop()
					block_weight.pop()
					block_count.pop()
			int t = 0
			for b in range(block_sum.length):
				float value = block_sum[b] / block_weight[b]
				for k in range(block_count[b]):
					center[g.order[first + t]] = value + offset[t]
					t = t + 1
	float least = 0.0
	int any = 0
	for v in range(g.count):
		float edge = center[v] - cast(float, size[v]) / 2.0
		if (any == 0 || edge < least): least = edge
		any = 1
	for v in range(g.count):
		float lane = center[v] - cast(float, size[v]) / 2.0 - least + 60.0
		g.lane[v] = cast(int, lane + 0.5)
	__w_list_free(cast(__w_list*, center))
	__w_list_free(cast(__w_list*, target))
	__w_list_free(cast(__w_list*, weight))
	__w_list_free(cast(__w_list*, offset))
	__w_list_free(cast(__w_list*, block_sum))
	__w_list_free(cast(__w_list*, block_weight))
	__w_list_free(cast(__w_list*, block_count))

# Most horizontal jogs one inter-rank gap gets tracks for; busier gaps keep
# the shared middle bend so the pass stays bounded.
const int MM_LAYOUT_TRACK_LIMIT = 512

# Channel routing between ranks. Every routed edge jogs across the cross axis
# once per gap; jogs whose spans overlap would draw on top of each other at
# the shared bend, so each gap's jogs get distinct tracks (bends) spread over
# the gap. Jogs leaving the same upper point or reaching the same lower point
# share a trunk and may share a track. Rightward jogs take tracks from the
# rightmost start, leftward ones from the leftmost, which keeps two jogs
# going the same way from crossing. Gaps with one track keep their defaults.
void mm_place_tracks(list[mm_edge_route*] routes, list[int] jog_gap, list[int] jog_route, list[int] jog_index, list[int] jog_up, list[int] jog_down, list[int] key_up, list[int] key_down, list[int] gap_low, list[int] gap_high):
	int gap_count = gap_low.length
	list[int] start = new list[int]
	list[int] members = new list[int]
	list[int] ids = new list[int]
	for i in range(jog_gap.length): ids.push(i)
	mm_layered_csr(gap_count, jog_gap, ids, start, members)
	list[int] keys = new list[int]
	list[int] scratch = new list[int]
	list[int] track = new list[int]
	for i in range(jog_gap.length):
		keys.push(0)
		scratch.push(0)
		track.push(-1)
	for gap in range(gap_count):
		int first = start[gap]
		int last = start[gap + 1]
		if (last - first < 2 || last - first > MM_LAYOUT_TRACK_LIMIT): continue
		# Rightward jogs (larger start first), then leftward (smaller start first).
		for i in range(first, last):
			int j = members[i]
			if (jog_down[j] >= jog_up[j]): keys[j] = 0 - jog_up[j]
			else: keys[j] = 1073741824 / 2 + jog_up[j]
		mm_layout_sort(members, first, last, keys, scratch)
		int tracks = 0
		for i in range(first, last):
			int j = members[i]
			if (jog_up[j] == jog_down[j]): continue
			int lo = jog_up[j]
			int hi = jog_down[j]
			if (hi < lo):
				lo = jog_down[j]
				hi = jog_up[j]
			int t = 0
			int placed = 0
			while (placed == 0):
				int clash = 0
				for k in range(first, i):
					int other = members[k]
					if (track[other] != t): continue
					int olo = jog_up[other]
					int ohi = jog_down[other]
					if (ohi < olo):
						olo = jog_down[other]
						ohi = jog_up[other]
					if (lo < ohi + 4 && olo < hi + 4 && key_up[other] != key_up[j] && key_down[other] != key_down[j]): clash = 1
				if (clash == 0): placed = 1
				else: t = t + 1
			track[j] = t
			if (t + 1 > tracks): tracks = t + 1
		if (tracks < 2): continue
		for i in range(first, last):
			int j = members[i]
			if (track[j] < 0): continue
			mm_edge_route* r = routes[jog_route[j]]
			r.bends[jog_index[j]] = gap_low[gap] + (track[j] + 1) * (gap_high[gap] - gap_low[gap]) / (tracks + 1)
	__w_list_free(cast(__w_list*, start))
	__w_list_free(cast(__w_list*, members))
	__w_list_free(cast(__w_list*, ids))
	__w_list_free(cast(__w_list*, keys))
	__w_list_free(cast(__w_list*, scratch))
	__w_list_free(cast(__w_list*, track))

# Longest-path ranks, layered ordering with dummy chains, lane packing, and the
# dummy channels as routes for the edges whose routes[i] record is non-null.
void mm_place(list[mm_bounds*] nodes, list[mm_edge*] edges, char* direction, int lane_gap, int rank_gap, list[mm_edge_route*] routes):
	int n = nodes.length
	# Kahn's traversal; a cycle is broken at the lowest-index remaining node.
	list[int] incoming = new list[int]
	list[int] done = new list[int]
	for i in range(n):
		incoming.push(0)
		done.push(0)
	list[int] edge_from = new list[int]
	list[int] edge_index = new list[int]
	for i in range(edges.length):
		mm_edge* e = edges[i]
		if (e.from_node != e.to_node): incoming[e.to_node] = incoming[e.to_node] + 1
		edge_from.push(e.from_node)
		edge_index.push(i)
	list[int] out_start = new list[int]
	list[int] out = new list[int]
	mm_layered_csr(n, edge_from, edge_index, out_start, out)
	list[int] ready = new list[int]
	for i in range(n):
		if (incoming[i] == 0): ready.push(i)
	int head = 0
	int scan = 0
	int max_rank = 0
	for step in range(n):
		int index = -1
		while (head < ready.length && index < 0):
			if (done[ready[head]] == 0): index = ready[head]
			head = head + 1
		if (index < 0):
			while (done[scan]): scan = scan + 1
			index = scan
		done[index] = 1
		mm_bounds* from = nodes[index]
		if (from.rank < 0): from.rank = 0
		if (from.rank > max_rank): max_rank = from.rank
		for k in range(out_start[index], out_start[index + 1]):
			mm_edge* e = edges[out[k]]
			if (done[e.to_node] == 0):
				mm_bounds* to = nodes[e.to_node]
				# Longer links (flowchart `--->`, use case extra dashes) span extra ranks.
				int length = 1 + e.extra_rank
				if (e.min_length > length): length = e.min_length
				if (to.rank < from.rank + length): to.rank = from.rank + length
				incoming[e.to_node] = incoming[e.to_node] - 1
				if (incoming[e.to_node] == 0): ready.push(e.to_node)
	for mm_bounds* b in nodes:
		if (b.rank > max_rank): max_rank = b.rank
	__w_list_free(cast(__w_list*, incoming))
	__w_list_free(cast(__w_list*, done))
	__w_list_free(cast(__w_list*, edge_from))
	__w_list_free(cast(__w_list*, edge_index))
	__w_list_free(cast(__w_list*, out_start))
	__w_list_free(cast(__w_list*, out))
	__w_list_free(cast(__w_list*, ready))
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
	# Rank gaps start at the configured rank gap and grow to hold the edge labels drawn in them (beside the
	# target's incoming segment in vertical layouts, above it horizontally).
	list[int] gaps = new list[int]
	for rank in range(max_rank + 1): gaps.push(rank_gap)
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
	list[int] offsets = new list[int]
	offsets.push(60)
	for rank in range(max_rank): offsets.push(offsets[rank] + sizes[rank] + gaps[rank])
	# Layered graph: real nodes first, then each long edge's dummy chain.
	mm_layered* g = new mm_layered()
	g.max_rank = max_rank
	g.rank = new list[int]
	for mm_bounds* b in nodes: g.rank.push(b.rank)
	list[int] chain_start = new list[int]
	list[int] chain_length = new list[int]
	g.seg_upper = new list[int]
	g.seg_lower = new list[int]
	for mm_edge* e in edges:
		int from_rank = nodes[e.from_node].rank
		int to_rank = nodes[e.to_node].rank
		int span = to_rank - from_rank
		int step = 1
		if (span < 0):
			span = 0 - span
			step = -1
		chain_start.push(g.rank.length)
		int chain = -1
		if (e.from_node != e.to_node && span != 0 && (span == 1 || g.rank.length + span - 1 <= MM_LAYOUT_VIRTUAL_LIMIT)): chain = span - 1
		chain_length.push(chain)
		if (chain < 0): continue
		int previous = e.from_node
		for k in range(span):
			int next = e.to_node
			if (k < span - 1):
				next = g.rank.length
				g.rank.push(from_rank + (k + 1) * step)
			if (g.rank[previous] < g.rank[next]):
				g.seg_upper.push(previous)
				g.seg_lower.push(next)
			else:
				g.seg_upper.push(next)
				g.seg_lower.push(previous)
			previous = next
	g.count = g.rank.length
	# Rank buckets, initially by index: real nodes in source order, then dummies.
	g.rank_start = new list[int]
	for r in range(max_rank + 2): g.rank_start.push(0)
	for int r in g.rank: g.rank_start[r + 1] = g.rank_start[r + 1] + 1
	for r in range(max_rank): g.rank_start[r + 1] = g.rank_start[r + 1] + g.rank_start[r]
	g.rank_start[max_rank + 1] = g.count
	g.order = new list[int]
	g.position = new list[int]
	g.lane = new list[int]
	list[int] fill = new list[int]
	for r in range(max_rank + 1): fill.push(g.rank_start[r])
	for v in range(g.count):
		g.order.push(0)
		g.position.push(0)
		g.lane.push(0)
	for v in range(g.count):
		int r = g.rank[v]
		g.order[fill[r]] = v
		g.position[v] = fill[r] - g.rank_start[r]
		fill[r] = fill[r] + 1
	__w_list_free(cast(__w_list*, fill))
	g.up_start = new list[int]
	g.up = new list[int]
	g.down_start = new list[int]
	g.down = new list[int]
	mm_layered_csr(g.count, g.seg_lower, g.seg_upper, g.up_start, g.up)
	mm_layered_csr(g.count, g.seg_upper, g.seg_lower, g.down_start, g.down)
	list[int] segment_rank = new list[int]
	list[int] segment_ids = new list[int]
	for i in range(g.seg_upper.length):
		segment_rank.push(g.rank[g.seg_upper[i]])
		segment_ids.push(i)
	g.seg_start = new list[int]
	g.seg_order = new list[int]
	mm_layered_csr(max_rank + 1, segment_rank, segment_ids, g.seg_start, g.seg_order)
	__w_list_free(cast(__w_list*, segment_rank))
	__w_list_free(cast(__w_list*, segment_ids))
	g.keys = new list[int]
	g.items = new list[int]
	g.scratch = new list[int]
	int widest = 0
	for r in range(max_rank + 1):
		if (g.rank_start[r + 1] - g.rank_start[r] > widest): widest = g.rank_start[r + 1] - g.rank_start[r]
	g.tree = new list[int]
	for i in range(widest + 2): g.tree.push(0)
	int scratch = g.count
	if (g.seg_upper.length > scratch): scratch = g.seg_upper.length
	for i in range(scratch + 1):
		g.keys.push(0)
		g.items.push(0)
		g.scratch.push(0)
	mm_layered_order(g)
	mm_layered_last_crossings = mm_layered_crossings(g)
	# Pack each rank along the cross axis; a dummy channel is a zero-width lane
	# with half the node gap on each side.
	for r in range(max_rank + 1):
		int lane = 60
		int previous_size = 0
		int previous_real = 0
		for i in range(g.rank_start[r], g.rank_start[r + 1]):
			int v = g.order[i]
			int real = v < n
			if (i > g.rank_start[r]):
				int gap = lane_gap / 2
				if (real && previous_real): gap = lane_gap
				lane = lane + previous_size + gap
			g.lane[v] = lane
			previous_size = 0
			if (real):
				previous_size = nodes[v].w
				if (horizontal): previous_size = nodes[v].h
			previous_real = real
	list[int] cross_size = new list[int]
	for v in range(g.count):
		int size = 0
		if (v < n):
			size = nodes[v].w
			if (horizontal): size = nodes[v].h
		cross_size.push(size)
	mm_layered_coordinates(g, cross_size, lane_gap, n)
	__w_list_free(cast(__w_list*, cross_size))
	for i in range(n):
		mm_bounds* b = nodes[i]
		int rank = b.rank
		if (reverse): rank = max_rank - rank
		if (horizontal):
			b.x = offsets[rank]
			b.y = g.lane[i]
		else:
			b.x = g.lane[i]
			b.y = offsets[rank]
	# Routes: the channel coordinate and rank band at each dummy, and the free
	# gap crossed before each dummy and before the target, in travel order.
	list[int] jog_gap = new list[int]
	list[int] jog_route = new list[int]
	list[int] jog_index = new list[int]
	list[int] jog_up = new list[int]
	list[int] jog_down = new list[int]
	list[int] key_up = new list[int]
	list[int] key_down = new list[int]
	if (routes != 0):
		for i in range(edges.length):
			mm_edge_route* route = routes[i]
			if (route == 0 || chain_length[i] < 0): continue
			mm_edge* e = edges[i]
			mm_edge_route_clear(route)
			int from_rank = nodes[e.from_node].rank
			int to_rank = nodes[e.to_node].rank
			if (reverse):
				from_rank = max_rank - from_rank
				to_rank = max_rank - to_rank
			int step = 1
			if (to_rank < from_rank): step = -1
			route.lanes = new list[int]
			route.spans = new list[int]
			route.gaps = new list[int]
			route.bends = new list[int]
			route.horizontal = horizontal
			int p = from_rank
			int point = e.from_node
			for k in range(chain_length[i] + 1):
				int next = p + step
				int next_point = e.to_node
				if (k < chain_length[i]): next_point = chain_start[i] + k
				route.bends.push(-1)
				# The jog across this gap, oriented from the upper rank to the lower one.
				int here = g.lane[point]
				int there = g.lane[next_point]
				if (point < n):
					if (horizontal): here = here + nodes[point].h / 2
					else: here = here + nodes[point].w / 2
				if (next_point < n):
					if (horizontal): there = there + nodes[next_point].h / 2
					else: there = there + nodes[next_point].w / 2
				jog_route.push(i)
				jog_index.push(k)
				if (step > 0):
					jog_gap.push(p)
					jog_up.push(here)
					jog_down.push(there)
					key_up.push(point)
					key_down.push(next_point)
				else:
					jog_gap.push(next)
					jog_up.push(there)
					jog_down.push(here)
					key_up.push(next_point)
					key_down.push(point)
				point = next_point
				if (step > 0):
					route.gaps.push(offsets[p] + sizes[p])
					route.gaps.push(offsets[next])
				else:
					route.gaps.push(offsets[p])
					route.gaps.push(offsets[next] + sizes[next])
				if (k < chain_length[i]):
					route.lanes.push(g.lane[chain_start[i] + k])
					if (step > 0):
						route.spans.push(offsets[next])
						route.spans.push(offsets[next] + sizes[next])
					else:
						route.spans.push(offsets[next] + sizes[next])
						route.spans.push(offsets[next])
				p = next
			mm_bounds* a = nodes[e.from_node]
			mm_bounds* b = nodes[e.to_node]
			route.from_x = a.x
			route.from_y = a.y
			route.to_x = b.x
			route.to_y = b.y
		list[int] gap_low = new list[int]
		list[int] gap_high = new list[int]
		for rank in range(max_rank):
			gap_low.push(offsets[rank] + sizes[rank])
			gap_high.push(offsets[rank + 1])
		mm_place_tracks(routes, jog_gap, jog_route, jog_index, jog_up, jog_down, key_up, key_down, gap_low, gap_high)
		__w_list_free(cast(__w_list*, gap_low))
		__w_list_free(cast(__w_list*, gap_high))
	__w_list_free(cast(__w_list*, jog_gap))
	__w_list_free(cast(__w_list*, jog_route))
	__w_list_free(cast(__w_list*, jog_index))
	__w_list_free(cast(__w_list*, jog_up))
	__w_list_free(cast(__w_list*, jog_down))
	__w_list_free(cast(__w_list*, key_up))
	__w_list_free(cast(__w_list*, key_down))
	mm_layered_free(g)
	__w_list_free(cast(__w_list*, chain_start))
	__w_list_free(cast(__w_list*, chain_length))
	__w_list_free(cast(__w_list*, offsets))
	__w_list_free(cast(__w_list*, sizes))
	__w_list_free(cast(__w_list*, gaps))

# Native force-directed option. Fixed initialization/iteration budgets make
# repeated exports reproducible. Rectangle sizes influence repulsion and a
# final collision pass guarantees disjoint boxes even when cooling stops early.
void mm_force_place(list[mm_bounds*] nodes, list[mm_edge*] edges):
	if (nodes.length == 0): return
	list[float] xs = new list[float]
	list[float] ys = new list[float]
	list[float] fx = new list[float]
	list[float] fy = new list[float]
	for mm_bounds* b in nodes:
		xs.push(cast(float, b.x + b.w / 2))
		ys.push(cast(float, b.y + b.h / 2))
		fx.push(0.0)
		fy.push(0.0)
	int rounds = 64
	if (nodes.length > 128): rounds = 24
	for step in range(rounds):
		for i in range(nodes.length):
			fx[i] = 0.0
			fy[i] = 0.0
		for i in range(nodes.length):
			mm_bounds* a = nodes[i]
			for j in range(i + 1, nodes.length):
				mm_bounds* b = nodes[j]
				float dx = xs[j] - xs[i]
				float dy = ys[j] - ys[i]
				if (dx == 0.0 && dy == 0.0): dx = 1.0
				float distance = fsqrt(dx * dx + dy * dy)
				float desired = cast(float, a.w + b.w + a.h + b.h) / 4.0 + 80.0
				float force = desired * desired / (distance + 1.0) * 0.08
				if (force > 40.0): force = 40.0
				float x = dx / distance * force
				float y = dy / distance * force
				fx[i] = fx[i] - x
				fy[i] = fy[i] - y
				fx[j] = fx[j] + x
				fy[j] = fy[j] + y
		for mm_edge* e in edges:
			int a = e.from_node
			int b = e.to_node
			if (a == b): continue
			float dx = xs[b] - xs[a]
			float dy = ys[b] - ys[a]
			float distance = fsqrt(dx * dx + dy * dy) + 1.0
			mm_bounds* na = nodes[a]
			mm_bounds* nb = nodes[b]
			float desired = cast(float, na.w + nb.w + na.h + nb.h) / 4.0 + 80.0
			float force = (distance - desired) * 0.04
			float x = dx / distance * force
			float y = dy / distance * force
			fx[a] = fx[a] + x
			fy[a] = fy[a] + y
			fx[b] = fx[b] - x
			fy[b] = fy[b] - y
		float temperature = cast(float, rounds - step) / cast(float, rounds) * 16.0 + 1.0
		for i in range(nodes.length):
			float x = fx[i]
			float y = fy[i]
			if (x > temperature): x = temperature
			if (x < 0.0 - temperature): x = 0.0 - temperature
			if (y > temperature): y = temperature
			if (y < 0.0 - temperature): y = 0.0 - temperature
			xs[i] = xs[i] + x
			ys[i] = ys[i] + y
	int min_x = 0
	int min_y = 0
	for i in range(nodes.length):
		mm_bounds* b = nodes[i]
		b.x = cast(int, xs[i]) - b.w / 2
		b.y = cast(int, ys[i]) - b.h / 2
		if (b.x < min_x): min_x = b.x
		if (b.y < min_y): min_y = b.y
	for i in range(nodes.length):
		mm_bounds* b = nodes[i]
		b.x = b.x - min_x + 60
		b.y = b.y - min_y + 60
		int j = 0
		while (j < i):
			mm_bounds* a = nodes[j]
			if (b.x < a.x + a.w + 40 && b.x + b.w + 40 > a.x && b.y < a.y + a.h + 40 && b.y + b.h + 40 > a.y):
				b.x = a.x + a.w + 40
				j = 0
			else: j = j + 1
	__w_list_free(cast(__w_list*, xs))
	__w_list_free(cast(__w_list*, ys))
	__w_list_free(cast(__w_list*, fx))
	__w_list_free(cast(__w_list*, fy))
