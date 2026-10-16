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
	for mm_edge* e in d.edges:
		mm_bounds* a = s.nodes[e.from_node]
		mm_bounds* b = s.nodes[e.to_node]
		mm_framework_arrow(s, a.x + a.w / 2, a.y + a.h, b.x + b.w / 2, b.y, 1)
		mm_text(s, (a.x + b.x) / 2, (a.y + a.h + b.y) / 2, e.label)
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
	mm_text(s, 40, 30, d.title)
	return s

mm_scene* mm_wardley_render(mm_document* d):
	mm_scene* s = mm_framework_scene(d)
	s.has_title = d.title[0] != 0
	mm_text(s, 80, 24, d.title)
	mm_text(s, 80, 52, c"Visibility")
	mm_framework_arrow(s, 80, 650, 80, 90, 0)
	mm_framework_arrow(s, 80, 650, 1080, 650, 0)
	mm_text(s, 980, 688, c"Evolution")
	list[char*] stages = list[char*]{c"Genesis", c"Custom", c"Product", c"Commodity"}
	for i in range(4):
		mm_text(s, 100 + i * 250, 662, stages[i])
		if (i > 0): mm_line(s, 80 + i * 250, 90, 80 + i * 250, 650, 1)
	__w_list_free(cast(__w_list*, stages))
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		b.x = 80 + n.value_x
		b.y = 650 - n.value_y * 560 / 1000
	for mm_edge* e in d.edges:
		mm_bounds* a = s.nodes[e.from_node]
		mm_bounds* b = s.nodes[e.to_node]
		mm_line(s, a.x, a.y, b.x, b.y, 0)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		mm_draw(s, MM_CIRCLE, b.x - 6, b.y - 6, b.x + 6, b.y + 6, n.shape, c"")
		mm_text(s, b.x + 12, b.y - 16, n.label)
	return s
