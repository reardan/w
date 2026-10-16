# Family-specific geometry shared by SVG and the native desktop preview.
import libs.extras.mermaid.scene

char* mm_data_format(int value):
	string_builder* s = string_new()
	if (value < 0):
		string_append_char(s, '-')
		value = 0 - value
	string_append_int(s, value / 1000)
	int fraction = value % 1000
	if (fraction):
		string_append_char(s, '.')
		string_append_char(s, '0' + fraction / 100)
		if (fraction % 100): string_append_char(s, '0' + fraction / 10 % 10)
		if (fraction % 10): string_append_char(s, '0' + fraction % 10)
	char* result = s.data
	free(s)
	return result

void mm_data_value_text(mm_scene* s, int x, int y, int value):
	char* label = mm_data_format(value)
	mm_text(s, x, y, label)
	free(label)

int mm_data_scale(int value, int low, int high, int pixels):
	return cast(int, cast(float, value - low) / cast(float, high - low) * cast(float, pixels))

mm_primitive* mm_data_polygon(mm_scene* s):
	mm_draw(s, MM_POLYGON, 0, 0, 0, 0, 0, c"")
	mm_primitive* p = s.items[s.items.length - 1]
	p.points = new list[int]
	return p

void mm_data_vertex(mm_scene* s, mm_primitive* p, int x, int y):
	p.points.push(x)
	p.points.push(y)
	if (x + 40 > s.width): s.width = x + 40
	if (y + 40 > s.height): s.height = y + 40

void mm_data_pie_render(mm_document* d, mm_scene* s):
	float sum = 0.0
	for mm_data_item* item in d.data.items: sum = sum + cast(float, item.a)
	float angle = -1.5707963
	int row = 0
	for mm_data_item* item in d.data.items:
		float sweep = cast(float, item.a) / sum * 6.2831853
		int steps = cast(int, sweep * 180.0 / 3.14159265 / 4.0) + 1
		# Approximate each arc directly; no artificial radial seams.
		int last_x = 250 + cast(int, fcos(angle) * 180.0)
		int last_y = 260 + cast(int, fsin(angle) * 180.0)
		for j in range(1, steps + 1):
			float end = angle + sweep * cast(float, j) / cast(float, steps)
			int x = 250 + cast(int, fcos(end) * 180.0)
			int y = 260 + cast(int, fsin(end) * 180.0)
			# Fill-free geometry avoids artificial radial seams between fan parts.
			mm_line(s, last_x, last_y, x, y, 0)
			last_x = x
			last_y = y
		mm_line(s, 250, 260, last_x, last_y, 0)
		float middle = angle + sweep / 2.0
		int lx = 250 + cast(int, fcos(middle) * 125.0)
		int ly = 260 + cast(int, fsin(middle) * 125.0)
		mm_text(s, lx - strlen(item.label) * 4, ly - 20, item.label)
		mm_data_value_text(s, lx - 12, ly, cast(int, cast(float, item.a) / sum * 100000.0))
		mm_text(s, 500, 80 + row * 26, item.label)
		if (d.data.show_data): mm_data_value_text(s, 500 + strlen(item.label) * 8 + 20, 80 + row * 26, item.a)
		angle = angle + sweep
		row = row + 1
	mm_line(s, 250, 260, 250, 80, 0)
	mm_text(s, 170, 470, c"Slice labels: percent")

void mm_data_quadrant_render(mm_document* d, mm_scene* s):
	mm_data_chart* c = d.data
	mm_draw(s, MM_BOX, 120, 80, 720, 580, 0, c"")
	mm_line(s, 420, 80, 420, 580, 0)
	mm_line(s, 120, 330, 720, 330, 0)
	mm_text(s, 120, 610, c.x_label)
	mm_text(s, 720 - strlen(c.x_end) * 8, 610, c.x_end)
	mm_text(s, 10, 560, c.y_label)
	mm_text(s, 10, 80, c.y_end)
	for mm_data_item* item in c.items:
		if (item.kind == 8):
			int x = 140
			int y = 100
			if (item.a == 1 || item.a == 4): x = 440
			if (item.a == 3 || item.a == 4): y = 350
			mm_text(s, x, y, item.label)
		else:
			int x = 120 + item.values[0] * 600 / 1000
			int y = 580 - item.values[1] * 500 / 1000
			mm_draw(s, MM_CIRCLE, x - 4, y - 4, x + 4, y + 4, 1, c"")
			mm_text(s, x + 8, y - 18, item.label)

void mm_data_xy_render(mm_document* d, mm_scene* s):
	mm_data_chart* c = d.data
	int count = 0
	int bars = 0
	for mm_data_item* item in c.items:
		if (item.kind != 1): count = item.values.length
		if (item.kind == 3): bars = bars + 1
	int width = count * 64
	if (width < 600): width = 600
	int horizontal = c.horizontal
	int left = 140
	int top = 80
	int extent = 400
	int zero = mm_data_scale(0, c.low, c.high, extent)
	if (zero < 0): zero = 0
	if (zero > extent): zero = extent
	if (horizontal):
		mm_line(s, left, top, left, top + width, 0)
		mm_line(s, left, top + width, left + extent, top + width, 0)
	else:
		mm_line(s, left, top, left, top + extent, 0)
		mm_line(s, left, top + extent, left + width, top + extent, 0)
	for tick in range(6):
		int value = c.low + cast(int, cast(float, c.high - c.low) * cast(float, tick) / 5.0)
		if (horizontal):
			mm_data_value_text(s, left + tick * extent / 5 - 16, top + width + 24, value)
			mm_line(s, left + tick * extent / 5, top, left + tick * extent / 5, top + width, 1)
		else:
			mm_data_value_text(s, 20, top + extent - tick * extent / 5 - 8, value)
			mm_line(s, left, top + extent - tick * extent / 5, left + width, top + extent - tick * extent / 5, 1)
	int category = 0
	for mm_data_item* item in c.items:
		if (item.kind != 1): continue
		int position = (category * 2 + 1) * width / (count * 2)
		if (horizontal): mm_text(s, 10, top + position - 8, item.label)
		else: mm_text(s, left + position - strlen(item.label) * 4, top + extent + 20, item.label)
		category = category + 1
	if (category == 0):
		for i in range(count):
			int position = (i * 2 + 1) * width / (count * 2)
			if (horizontal): mm_data_value_text(s, 50, top + position - 8, (i + 1) * 1000)
			else: mm_data_value_text(s, left + position - 4, top + extent + 20, (i + 1) * 1000)
	int bar_index = 0
	int series_index = 0
	for mm_data_item* item in c.items:
		if (item.kind == 1): continue
		int last_x = 0
		int last_y = 0
		for i in range(count):
			int position = (i * 2 + 1) * width / (count * 2)
			int value = mm_data_scale(item.values[i], c.low, c.high, extent)
			int x = left + position
			int y = top + extent - value
			if (horizontal):
				x = left + value
				y = top + position
			if (item.kind == 2):
				if (i != 0): mm_line(s, last_x, last_y, x, y, series_index % 2)
				mm_draw(s, MM_CIRCLE, x - 3, y - 3, x + 3, y + 3, 1, c"")
			else:
				int band = width / count * 3 / 4
				int start = position - band / 2 + band * bar_index / bars
				int end = position - band / 2 + band * (bar_index + 1) / bars - 2
				int low = value
				int high = zero
				if (low > high):
					low = zero
					high = value
				if (horizontal): mm_draw(s, MM_BOX, left + low, top + start, left + high, top + end, 0, c"")
				else: mm_draw(s, MM_BOX, left + start, top + extent - high, left + end, top + extent - low, 0, c"")
			last_x = x
			last_y = y
		if (item.kind == 3): bar_index = bar_index + 1
		if (item.label[0] != 0):
			int legend_y = top + extent + 80
			if (horizontal): legend_y = top + width + 80
			mm_text(s, left, legend_y + series_index * 24, item.label)
		series_index = series_index + 1
	if (horizontal):
		mm_text(s, left, top + width + 52, c.y_label)
		mm_text(s, 10, 44, c.x_label)
	else:
		mm_text(s, left, top + extent + 52, c.x_label)
		mm_text(s, 20, 44, c.y_label)

void mm_data_radar_render(mm_document* d, mm_scene* s):
	mm_data_chart* c = d.data
	list[mm_data_item*] axes = new list[mm_data_item*]
	for mm_data_item* item in c.items:
		if (item.kind == 1): axes.push(item)
	int count = axes.length
	for tick in range(1, c.ticks + 1):
		int radius = 200 * tick / c.ticks
		if (c.polygon == 0): mm_ellipse(s, 300, 300, radius, radius)
		else:
			for i in range(count):
				float a = cast(float, i) * 6.2831853 / cast(float, count) - 1.5707963
				float b = cast(float, i + 1) * 6.2831853 / cast(float, count) - 1.5707963
				mm_line(s, 300 + cast(int, fcos(a) * cast(float, radius)), 300 + cast(int, fsin(a) * cast(float, radius)), 300 + cast(int, fcos(b) * cast(float, radius)), 300 + cast(int, fsin(b) * cast(float, radius)), 1)
	for i in range(count):
		float angle = cast(float, i) * 6.2831853 / cast(float, count) - 1.5707963
		mm_data_item* axis = axes[i]
		mm_line(s, 300, 300, 300 + cast(int, fcos(angle) * 200.0), 300 + cast(int, fsin(angle) * 200.0), 0)
		mm_text(s, 300 + cast(int, fcos(angle) * 225.0) - strlen(axis.label) * 4, 300 + cast(int, fsin(angle) * 225.0) - 8, axis.label)
	int series = 0
	for mm_data_item* item in c.items:
		if (item.kind != 4): continue
		for i in range(count):
			int j = (i + 1) % count
			float a = cast(float, i) * 6.2831853 / cast(float, count) - 1.5707963
			float b = cast(float, j) * 6.2831853 / cast(float, count) - 1.5707963
			int r1 = mm_data_scale(item.values[i], c.low, c.high, 200)
			int r2 = mm_data_scale(item.values[j], c.low, c.high, 200)
			int x = 300 + cast(int, fcos(a) * cast(float, r1))
			int y = 300 + cast(int, fsin(a) * cast(float, r1))
			mm_line(s, x, y, 300 + cast(int, fcos(b) * cast(float, r2)), 300 + cast(int, fsin(b) * cast(float, r2)), series % 2)
			mm_draw(s, MM_CIRCLE, x - 3, y - 3, x + 3, y + 3, series % 2, c"")
		if (c.legend):
			mm_line(s, 580, 100 + series * 28, 620, 100 + series * 28, series % 2)
			mm_text(s, 630, 92 + series * 28, item.label)
		series = series + 1
	mm_data_value_text(s, 310, 300, c.low)
	mm_data_value_text(s, 310, 100, c.high)
	__w_list_free(cast(__w_list*, axes))

float mm_data_tree_weight(mm_data_chart* c, int index):
	mm_data_item* item = c.items[index]
	if (item.kind != 5): return cast(float, item.a)
	float sum = 0.0
	for i in range(c.items.length):
		mm_data_item* child = c.items[i]
		if (child.parent == index): sum = sum + mm_data_tree_weight(c, i)
	return sum

void mm_data_tree_render_level(mm_data_chart* c, mm_scene* s, int parent, int x, int y, int width, int height, int depth):
	float total = 0.0
	for i in range(c.items.length):
		mm_data_item* item = c.items[i]
		if (item.parent == parent): total = total + mm_data_tree_weight(c, i)
	float used = 0.0
	for i in range(c.items.length):
		mm_data_item* item = c.items[i]
		if (item.parent != parent): continue
		float weight = mm_data_tree_weight(c, i)
		int xx = x
		int yy = y
		int ww = width
		int hh = height
		if (depth % 2 == 0):
			xx = x + cast(int, used / total * cast(float, width))
			ww = x + cast(int, (used + weight) / total * cast(float, width)) - xx
		else:
			yy = y + cast(int, used / total * cast(float, height))
			hh = y + cast(int, (used + weight) / total * cast(float, height)) - yy
		mm_draw(s, MM_BOX, xx, yy, xx + ww, yy + hh, 0, c"")
		# Labels in tiny cells go to a legend rather than crossing cell boundaries.
		if (ww > strlen(item.label) * 8 + 12 && hh > 26): mm_text(s, xx + 6, yy + 6, item.label)
		if (item.kind == 5):
			if (ww > 20 && hh > 40): mm_data_tree_render_level(c, s, i, xx + 4, yy + 26, ww - 8, hh - 30, depth + 1)
		used = used + weight

void mm_data_tree_render(mm_document* d, mm_scene* s):
	mm_data_tree_render_level(d.data, s, -1, 40, 80, 900, 600, 0)
	int row = 0
	for mm_data_item* item in d.data.items:
		mm_text(s, 980 + item.depth * 3, 80 + row * 24, item.label)
		if (item.kind != 5): mm_data_value_text(s, 1000 + item.depth * 3 + strlen(item.label) * 8, 80 + row * 24, item.a)
		row = row + 1

void mm_data_packet_render(mm_document* d, mm_scene* s):
	for mm_data_item* item in d.data.items:
		int first = item.a
		while (first <= item.b):
			int last = (first / 32 + 1) * 32 - 1
			if (last > item.b): last = item.b
			int x = 60 + first % 32 * 24
			int y = 80 + first / 32 * 90
			int right = 60 + (last % 32 + 1) * 24
			mm_draw(s, MM_BOX, x, y, right, y + 60, 0, c"")
			mm_data_value_text(s, x + 2, y - 20, first * 1000)
			if (last != first): mm_data_value_text(s, right - 24, y - 20, last * 1000)
			if (strlen(item.label) * 8 < right - x - 4): mm_text(s, x + (right - x - strlen(item.label) * 8) / 2, y + 22, item.label)
			else:
				# Bit-width geometry remains proportional; narrow field labels use a key.
				mm_data_value_text(s, x + 2, y + 22, (item.a + 1) * 1000)
				string_builder* text = string_new()
				string_append_int(text, item.a + 1)
				string_append(text, c": ")
				string_append(text, item.label)
				mm_text(s, 880, 80 + cast(int, d.data.items.index(item)) * 24, text.data)
				string_free(text)
			first = last + 1

void mm_data_venn_render(mm_document* d, mm_scene* s):
	list[int] ids = new list[int]
	list[int] xs = new list[int]
	list[int] ys = new list[int]
	for i in range(d.data.items.length):
		mm_data_item* item = d.data.items[i]
		if (item.kind == 6): ids.push(i)
		xs.push(0)
		ys.push(260)
	int count = ids.length
	list[int] connected = new list[int]
	for i in range(9): connected.push(0)
	int triple = 0
	for mm_data_item* item in d.data.items:
		if (item.kind != 7): continue
		if (item.values.length == 3): triple = 1
		for int a in item.values:
			for int b in item.values:
				int ai = ids.index(a)
				int bi = ids.index(b)
				if (ai != bi): connected[ai * 3 + bi] = 1
	int pairs = 0
	for i in range(count):
		for j in range(i + 1, count):
			if (connected[i * 3 + j]): pairs = pairs + 1
	for i in range(count): xs[ids[i]] = 250 + i * 400
	if (count == 2 && pairs == 1):
		xs[ids[0]] = 270
		xs[ids[1]] = 440
	if (count == 3 && pairs == 1):
		for i in range(count):
			for j in range(i + 1, count):
				if (connected[i * 3 + j] == 0): continue
				xs[ids[i]] = 270
				xs[ids[j]] = 440
				xs[ids[3 - i - j]] = 850
	if (count == 3 && pairs == 2):
		for i in range(count):
			int degree = 0
			for j in range(count): degree = degree + connected[i * 3 + j]
			if (degree != 2): continue
			xs[ids[i]] = 550
			xs[ids[(i + 1) % 3]] = 280
			xs[ids[(i + 2) % 3]] = 820
	if (count == 3 && pairs == 3):
		if (triple):
			xs[ids[0]] = 270
			xs[ids[1]] = 440
			xs[ids[2]] = 355
			ys[ids[2]] = 400
		else:
			# Pairwise intersections without a specified triple intersection.
			xs[ids[0]] = 240
			xs[ids[1]] = 550
			xs[ids[2]] = 395
			ys[ids[2]] = 528
	for i in range(count):
		mm_data_item* item = d.data.items[ids[i]]
		int x = xs[ids[i]]
		int y = ys[ids[i]]
		mm_ellipse(s, x, y, 170, 170)
		int ty = y - 115
		if (count == 3 && pairs == 3 && i == 2): ty = y + 110
		mm_text(s, x - strlen(item.label) * 4, ty, item.label)
	for mm_data_item* item in d.data.items:
		if (item.kind != 7): continue
		int x = 0
		int y = 0
		for int i in item.values:
			x = x + xs[i]
			y = y + ys[i]
		x = x / item.values.length
		y = y / item.values.length
		if (triple && item.values.length == 2):
			x = 355 + (x - 355) * 2
			y = 306 + (y - 306) * 2
		mm_text(s, x - strlen(item.label) * 4, y - 8, item.label)
	__w_list_free(cast(__w_list*, ids))
	__w_list_free(cast(__w_list*, connected))
	__w_list_free(cast(__w_list*, xs))
	__w_list_free(cast(__w_list*, ys))

struct mm_data_flow_node:
	float incoming
	float outgoing
	float total
	float in_used
	float out_used
	int rank
	int x
	int y
	int height

void mm_data_sankey_render(mm_document* d, mm_scene* s):
	list[mm_data_flow_node*] nodes = new list[mm_data_flow_node*]
	for i in range(d.nodes.length):
		mm_data_flow_node* node = new mm_data_flow_node()
		node.rank = -1
		nodes.push(node)
	for mm_data_item* item in d.data.items:
		mm_data_flow_node* from = nodes[item.parent]
		mm_data_flow_node* to = nodes[item.b]
		from.outgoing = from.outgoing + cast(float, item.a)
		to.incoming = to.incoming + cast(float, item.a)
	for mm_data_flow_node* node in nodes:
		node.total = node.incoming
		if (node.outgoing > node.total): node.total = node.outgoing
	int ranks = 0
	for pass in range(nodes.length):
		for i in range(nodes.length):
			mm_data_flow_node* node = nodes[i]
			if (node.rank >= 0): continue
			int rank = 0
			int ready = 1
			for mm_data_item* item in d.data.items:
				if (item.b != i): continue
				mm_data_flow_node* from = nodes[item.parent]
				if (from.rank < 0): ready = 0
				else if (from.rank + 1 > rank): rank = from.rank + 1
			if (ready):
				node.rank = rank
				if (rank + 1 > ranks): ranks = rank + 1
	float maximum = 0.0
	int max_count = 0
	for rank in range(ranks):
		float sum = 0.0
		int count = 0
		for mm_data_flow_node* node in nodes:
			if (node.rank == rank):
				sum = sum + node.total
				count = count + 1
		if (sum > maximum): maximum = sum
		if (count > max_count): max_count = count
	float scale = 500.0 / maximum
	for rank in range(ranks):
		int y = 100
		for mm_data_flow_node* node in nodes:
			if (node.rank != rank): continue
			node.x = 80 + rank * 280
			node.y = y
			node.height = cast(int, node.total * scale)
			if (node.height < 1): node.height = 1
			y = y + node.height + 50
	for mm_data_item* item in d.data.items:
		mm_data_flow_node* from = nodes[item.parent]
		mm_data_flow_node* to = nodes[item.b]
		int ay = from.y + cast(int, from.out_used * scale)
		int by = to.y + cast(int, to.in_used * scale)
		int ah = from.y + cast(int, (from.out_used + cast(float, item.a)) * scale)
		int bh = to.y + cast(int, (to.in_used + cast(float, item.a)) * scale)
		mm_primitive* ribbon = mm_data_polygon(s)
		mm_data_vertex(s, ribbon, from.x + 20, ay)
		mm_data_vertex(s, ribbon, to.x, by)
		mm_data_vertex(s, ribbon, to.x, bh)
		mm_data_vertex(s, ribbon, from.x + 20, ah)
		mm_data_value_text(s, (from.x + to.x) / 2, (ay + by + ah + bh) / 4, item.a)
		from.out_used = from.out_used + cast(float, item.a)
		to.in_used = to.in_used + cast(float, item.a)
	for i in range(nodes.length):
		mm_data_flow_node* node = nodes[i]
		mm_node* named = d.nodes[i]
		mm_draw(s, MM_BOX, node.x, node.y, node.x + 20, node.y + node.height, 2, c"")
		mm_text(s, node.x, node.y - 24, named.label)
	for mm_data_flow_node* node in nodes: free(node)
	__w_list_free(cast(__w_list*, nodes))

mm_scene* mm_data_render(mm_document* d):
	mm_scene* s = new mm_scene()
	s.items = new list[mm_primitive*]
	s.nodes = new list[mm_bounds*]
	s.width = 400
	s.height = 300
	char* title = d.title
	if (title[0] == 0): title = d.data.title
	if (title[0] != 0):
		mm_text(s, 40, 20, title)
		s.has_title = 1
	if (d.kind == MM_PIE): mm_data_pie_render(d, s)
	else if (d.kind == MM_QUADRANT): mm_data_quadrant_render(d, s)
	else if (d.kind == MM_XY): mm_data_xy_render(d, s)
	else if (d.kind == MM_SANKEY): mm_data_sankey_render(d, s)
	else if (d.kind == MM_RADAR): mm_data_radar_render(d, s)
	else if (d.kind == MM_TREEMAP): mm_data_tree_render(d, s)
	else if (d.kind == MM_VENN): mm_data_venn_render(d, s)
	else: mm_data_packet_render(d, s)
	return s
