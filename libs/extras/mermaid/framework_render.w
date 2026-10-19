# Family-specific outlines, fishbones, Cynefin regions and Wardley axes.
import libs.extras.mermaid.scene

mm_scene* mm_framework_scene(mm_document* d):
	mm_scene* s = new mm_scene()
	s.items = new list[mm_primitive*]
	s.nodes = new list[mm_bounds*]
	for mm_node* n in d.nodes:
		mm_bounds* b = new mm_bounds()
		b.w = strlen(n.label) * 8 + 32
		b.h = 32
		s.nodes.push(b)
	return s

void mm_framework_arrow(mm_scene* s, int ax, int ay, int bx, int by, int dashed):
	mm_line(s, ax, ay, bx, by, dashed)
	float dx = cast(float, bx - ax)
	float dy = cast(float, by - ay)
	float length = fsqrt(dx * dx + dy * dy)
	if (length < 1.0): return
	int ux = cast(int, dx / length * 12.0)
	int uy = cast(int, dy / length * 12.0)
	int px = cast(int, 0.0 - dy / length * 6.0)
	int py = cast(int, dx / length * 6.0)
	mm_line(s, bx, by, bx - ux + px, by - uy + py, 0)
	mm_line(s, bx, by, bx - ux - px, by - uy - py, 0)

mm_scene* mm_treeview_render(mm_document* d):
	mm_scene* s = mm_framework_scene(d)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		b.x = 40
		b.y = 40 + i * 32
		if (n.parent >= 0):
			mm_bounds* a = s.nodes[n.parent]
			b.x = a.x + 36
			mm_line(s, a.x + 8, a.y + 24, a.x + 8, b.y + 8, 0)
			mm_line(s, a.x + 8, b.y + 8, b.x - 4, b.y + 8, 0)
		mm_text(s, b.x, b.y, n.label)
		if (n.annotation[0] != 0):
			mm_text(s, b.x + strlen(n.label) * 8 + 24, b.y, n.annotation)
			mm_primitive* description = s.items[s.items.length - 1]
			description.style.mask = description.style.mask | 4
			description.style.text = 0x64748b
	return s

mm_scene* mm_ishikawa_render(mm_document* d):
	mm_scene* s = mm_framework_scene(d)
	list[int] categories = new list[int]
	list[int] widths = new list[int]
	list[int] counts = new list[int]
	int max_count = 1
	for i in range(1, d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != 0): continue
		int width = strlen(n.label) * 8 + 80
		int count = 0
		for j in range(i + 1, d.nodes.length):
			mm_node* child = d.nodes[j]
			int ancestor = child.parent
			int depth = 0
			while (ancestor > 0 && ancestor != i):
				mm_node* a = d.nodes[ancestor]
				ancestor = a.parent
				depth = depth + 1
			if (ancestor == i):
				count = count + 1
				int size = strlen(child.label) * 8 + 100 + depth * 20
				if (size > width): width = size
		if (count > max_count): max_count = count
		categories.push(i)
		widths.push(width)
		counts.push(count)
	int spine_y = 100 + max_count * 32
	int x = 40
	for k in range(categories.length):
		int i = categories[k]
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		int sign = -1
		if (k % 2): sign = 1
		int span = (counts[k] + 1) * 32
		b.x = x
		b.y = spine_y + sign * (span + 24)
		int tip_x = x + widths[k]
		mm_line(s, x + widths[k] - 80, spine_y + sign * span, tip_x, spine_y, 0)
		mm_text(s, b.x, b.y, n.label)
		int row = 0
		for j in range(i + 1, d.nodes.length):
			mm_node* child = d.nodes[j]
			int ancestor = child.parent
			int depth = 0
			while (ancestor > 0 && ancestor != i):
				mm_node* a = d.nodes[ancestor]
				ancestor = a.parent
				depth = depth + 1
			if (ancestor != i): continue
			row = row + 1
			mm_bounds* leaf = s.nodes[j]
			leaf.x = x + depth * 20
			leaf.y = spine_y + sign * row * 32
			int end_x = tip_x - 80 * row / (counts[k] + 1)
			mm_text(s, leaf.x, leaf.y - 18, child.label)
			if (depth == 0): mm_line(s, leaf.x, leaf.y, end_x, leaf.y, 0)
			else:
				mm_bounds* parent = s.nodes[child.parent]
				mm_line(s, leaf.x, leaf.y, leaf.x + leaf.w, leaf.y, 0)
				mm_line(s, leaf.x + leaf.w, leaf.y, parent.x + parent.w, parent.y, 0)
		x = x + widths[k] + 40
	mm_bounds* head = s.nodes[0]
	mm_node* problem = d.nodes[0]
	head.x = x
	head.y = spine_y - 24
	head.h = 48
	mm_framework_arrow(s, 40, spine_y, x, spine_y, 0)
	mm_draw(s, MM_BOX, head.x, head.y, head.x + head.w, head.y + head.h, 0, c"")
	mm_text(s, head.x + 16, head.y + 16, problem.label)
	__w_list_free(cast(__w_list*, categories))
	__w_list_free(cast(__w_list*, widths))
	__w_list_free(cast(__w_list*, counts))
	return s

mm_scene* mm_cynefin_render(mm_document* d):
	mm_scene* s = mm_framework_scene(d)
	int width = 280
	int height = 180
	for mm_node* n in d.nodes:
		if (n.members.length * 28 + 80 > height): height = n.members.length * 28 + 80
		for mm_member* m in n.members:
			if (strlen(m.text) * 8 + 40 > width): width = strlen(m.text) * 8 + 40
	for i in range(5):
		mm_bounds* b = s.nodes[i]
		b.w = width
		b.h = height
		b.x = 40 + (i % 2) * (width + 100)
		b.y = 80 + (i / 2) * (height * 2 + 100)
		if (i == 4):
			b.x = 40 + (width + 100) / 2
			b.y = 80 + height + 50
	for i in range(5):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, i == 4, c"")
		mm_text(s, b.x + 20, b.y + 16, n.label)
		mm_line(s, b.x, b.y + 44, b.x + b.w, b.y + 44, 0)
		for j in range(n.members.length):
			mm_member* m = n.members[j]
			mm_text(s, b.x + 20, b.y + 60 + j * 28, m.text + 6)
	s.has_title = d.title[0] != 0

	int legend_y = 80 + height * 3 + 140
	for i in range(d.edges.length):
		mm_edge* e = d.edges[i]
		mm_bounds* a = s.nodes[e.from_node]
		mm_bounds* b = s.nodes[e.to_node]
		int ax = a.x + a.w / 2
		int ay = a.y + a.h / 2
		int bx = b.x + b.w / 2
		int by = b.y + b.h / 2
		if (a.y == b.y):
			if (a.x < b.x):
				ax = a.x + a.w
				bx = b.x
			else:
				ax = a.x
				bx = b.x + b.w
		else:
			if (a.y < b.y):
				ay = a.y + a.h
				by = b.y
			else:
				ay = a.y
				by = b.y + b.h
		if (e.from_node == e.to_node):
			ax = a.x + a.w
			ay = a.y + 30
			bx = ax
			by = a.y + a.h - 30
			mm_line(s, ax, ay, ax + 30, ay, 1)
			mm_line(s, ax + 30, ay, ax + 30, by, 1)
			mm_framework_arrow(s, ax + 30, by, bx, by, 1)
		else: mm_framework_arrow(s, ax, ay, bx, by, 1)
		string_builder* number = string_new()
		string_append_int(number, i + 1)
		mm_text(s, (ax + bx) / 2 + 8, (ay + by) / 2 - 20, number.data)
		string_append(number, c": ")
		mm_node* from = d.nodes[e.from_node]
		mm_node* to = d.nodes[e.to_node]
		string_append(number, from.label)
		string_append(number, c" -> ")
		string_append(number, to.label)
		if (e.label[0] != 0):
			string_append(number, c": ")
			string_append(number, e.label)
		mm_text(s, 40, legend_y + i * 24, number.data)
		string_free(number)
	mm_text(s, 40, 30, d.title)
	return s

char* mm_wardley_value(mm_node* n, char* key):
	for mm_property* property in n.metadata:
		if (strcmp(property.key, key) == 0): return property.value
	return 0

void mm_wardley_paint(mm_scene* s, int fill, int stroke):
	mm_primitive* p = s.items[s.items.length - 1]
	if (fill >= 0):
		p.style.mask = p.style.mask | 1
		p.style.fill = fill
	if (stroke >= 0):
		p.style.mask = p.style.mask | 2
		p.style.stroke = stroke

# Visibility runs upward and evolution rightward over a fixed 1000-unit plot.
# Pipeline sub-components sit inside their pipeline band under the parent.
mm_scene* mm_wardley_render(mm_document* d):
	mm_scene* s = mm_framework_scene(d)
	s.has_title = d.title[0] != 0
	mm_text(s, 80, 24, d.title)
	mm_text(s, 80, 52, c"Visibility")
	mm_framework_arrow(s, 80, 650, 80, 90, 0)
	mm_framework_arrow(s, 80, 650, 1080, 650, 0)
	mm_text(s, 980, 688, c"Evolution")
	list[char*] stages = list[char*]{c"Genesis", c"Custom", c"Product", c"Commodity"}
	for mm_note* note in d.notes:
		if (note.node == -1 && note.side >= 0 && note.side < 4): stages[note.side] = note.text
	for i in range(4):
		mm_text(s, 100 + i * 250, 662, stages[i])
		if (i > 0): mm_line(s, 80 + i * 250, 90, 80 + i * 250, 650, 1)
	__w_list_free(cast(__w_list*, stages))
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		b.x = 80 + n.value_x
		b.y = 650 - n.value_y * 560 / 1000
		if (n.shape == 2): b.y = b.y + 28
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		char* range = mm_wardley_value(n, c"pipeline")
		if (range == 0): continue
		mm_bounds* b = s.nodes[i]
		int split = index_of(range, c" ")
		int low = 80 + atoi(range)
		int high = 80 + atoi(range + split + 1)
		mm_draw(s, MM_BOX, low - 12, b.y + 12, high + 12, b.y + 44, 0, c"")
	for mm_edge* e in d.edges:
		mm_bounds* a = s.nodes[e.from_node]
		mm_bounds* b = s.nodes[e.to_node]
		mm_line(s, a.x, a.y, b.x, b.y, 0)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		char* evolve = mm_wardley_value(n, c"evolve")
		if (evolve == 0): continue
		int target = 80 + atoi(evolve)
		int direction = 1
		if (target < b.x): direction = -1
		int start = s.items.length
		if (target - b.x > 24 || b.x - target > 24): mm_framework_arrow(s, b.x + direction * 8, b.y, target - direction * 8, b.y, 1)
		mm_draw(s, MM_CIRCLE, target - 6, b.y - 6, target + 6, b.y + 6, 0, c"")
		for k in range(start, s.items.length):
			mm_primitive* item = s.items[k]
			item.style.mask = item.style.mask | 2
			item.style.stroke = 0xdc2626
		mm_text(s, target + 12, b.y - 16, n.label)
		mm_primitive* label = s.items[s.items.length - 1]
		label.style.mask = label.style.mask | 4
		label.style.text = 0xdc2626
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		if (n.shape == 3):
			mm_text(s, b.x, b.y - 8, n.label)
			continue
		char* strategy = mm_wardley_value(n, c"strategy")
		if (strategy != 0):
			int fill = 0xe5e7eb
			if (strcmp(strategy, c"buy") == 0): fill = 0x9ca3af
			if (strcmp(strategy, c"outsource") == 0): fill = 0x4b5563
			mm_draw(s, MM_CIRCLE, b.x - 18, b.y - 18, b.x + 18, b.y + 18, 0, c"")
			mm_wardley_paint(s, fill, fill)
		mm_draw(s, MM_CIRCLE, b.x - 6, b.y - 6, b.x + 6, b.y + 6, n.shape == 1, c"")
		if (mm_wardley_value(n, c"inertia") != 0): mm_draw(s, MM_BOX, b.x + 22, b.y - 16, b.x + 28, b.y + 16, 2, c"")
		int dx = 12
		int dy = -16
		char* offset = mm_wardley_value(n, c"label")
		if (offset != 0):
			dx = atoi(offset)
			dy = atoi(offset + index_of(offset, c" ") + 1)
		int x = b.x + dx
		int y = b.y + dy
		if (x < 0): x = 0
		if (y < 0): y = 0
		mm_text(s, x, y, n.label)
	return s
