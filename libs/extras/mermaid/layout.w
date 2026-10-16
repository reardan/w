# Bounded deterministic graph layout helpers, independent of rendering backends.
import libs.extras.mermaid.scene

# Stable barycentric sweeps reorder each rank to reduce edge crossings while
# preserving node indices and using source order to resolve equal scores.
list[int] mm_layer_order(list[mm_bounds*] nodes, list[mm_edge*] edges, int max_rank):
	list[int] order = new list[int]
	list[int] positions = new list[int]
	list[int] scores = new list[int]
	for i in range(nodes.length):
		order.push(i)
		positions.push(i)
		scores.push(0)
	for sweep in range(4):
		for step in range(max_rank + 1):
			int rank = step
			if (sweep % 2): rank = max_rank - step
			list[int] slots = new list[int]
			for i in range(order.length):
				mm_bounds* b = nodes[order[i]]
				if (b.rank != rank): continue
				slots.push(i)
				int sum = 0
				int count = 0
				for mm_edge* e in edges:
					int neighbor = -1
					if (sweep % 2 == 0 && e.to_node == order[i]): neighbor = e.from_node
					if (sweep % 2 && e.from_node == order[i]): neighbor = e.to_node
					if (neighbor >= 0):
						mm_bounds* other = nodes[neighbor]
						if (other.rank != rank):
							sum = sum + positions[neighbor] * 1024
							count = count + 1
				scores[order[i]] = positions[order[i]] * 1024
				if (count): scores[order[i]] = sum / count
			for i in range(1, slots.length):
				int j = i
				while (j > 0 && scores[order[slots[j]]] < scores[order[slots[j - 1]]]):
					int item = order[slots[j]]
					order[slots[j]] = order[slots[j - 1]]
					order[slots[j - 1]] = item
					j = j - 1
			for i in range(slots.length): positions[order[slots[i]]] = i
			__w_list_free(cast(__w_list*, slots))
	__w_list_free(cast(__w_list*, positions))
	__w_list_free(cast(__w_list*, scores))
	return order

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
