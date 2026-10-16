# Swimlane placement aligns graph ranks across responsibility lanes. Event
# modeling places frames on a declaration-order timeline across typed lanes.
import libs.extras.mermaid.framework_render

mm_scene* mm_workflow_render(mm_document* d):
	mm_scene* s = mm_framework_scene(d)
	int horizontal = strcmp(d.direction, c"LR") == 0 || strcmp(d.direction, c"RL") == 0 || d.kind == MM_EVENT_MODEL
	int reverse = strcmp(d.direction, c"RL") == 0 || strcmp(d.direction, c"BT") == 0
	list[int] done = new list[int]
	list[int] incoming = new list[int]
	int max_rank = 0
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		b.h = 60
		if (b.w < 180): b.w = 180
		if (n.shape == 2): b.h = b.w
		if (n.shape == 3):
			b.w = b.w * 2
			b.h = 100
		if (d.kind == MM_EVENT_MODEL && n.group == 0):
			b.h = 90 + n.members.length * 24
			for mm_member* m in n.members:
				if (strlen(m.text) * 8 + 32 > b.w): b.w = strlen(m.text) * 8 + 32
			b.rank = n.value_x
			if (b.rank > max_rank): max_rank = b.rank
		int count = 0
		for mm_edge* e in d.edges:
			if (e.to_node == i && e.from_node != i): count = count + 1
		incoming.push(count)
		done.push(n.group)
	if (d.kind != MM_EVENT_MODEL):
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
			if (horizontal && strlen(n.label) * 8 + 40 > header): header = strlen(n.label) * 8 + 40
			continue
		int size = b.h
		if (horizontal): size = b.w
		if (size > sizes[b.rank]): sizes[b.rank] = size
	int major = 40
	for int size in sizes: major = major + size + 100
	int lane_offset = 40
	for lane in range(d.nodes.length):
		mm_node* group = d.nodes[lane]
		if (group.group == 0): continue
		int minor = 100
		if (horizontal == 0 && strlen(group.label) * 8 + 40 > minor): minor = strlen(group.label) * 8 + 40
		for rank in range(max_rank + 1):
			int stack = 40
			for i in range(d.nodes.length):
				mm_node* n = d.nodes[i]
				mm_bounds* b = s.nodes[i]
				if (n.parent != lane || b.rank != rank): continue
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
		mm_draw(s, MM_BOX, box.x, box.y, box.x + box.w, box.y + box.h, 0, c"")
		mm_text(s, box.x + 16, box.y + 16, group.label)
		if (horizontal): mm_line(s, box.x + header, box.y, box.x + header, box.y + box.h, 0)
		else: mm_line(s, box.x, box.y + header, box.x + box.w, box.y + header, 0)
	for mm_edge* e in d.edges:
		mm_bounds* a = s.nodes[e.from_node]
		mm_bounds* b = s.nodes[e.to_node]
		int ax = a.x + a.w / 2
		int ay = a.y + a.h
		int bx = b.x + b.w / 2
		int by = b.y
		if (horizontal):
			ax = a.x + a.w
			ay = a.y + a.h / 2
			bx = b.x
			by = b.y + b.h / 2
		if (reverse):
			if (horizontal):
				ax = a.x
				bx = b.x + b.w
			else:
				ay = a.y
				by = b.y + b.h
		if (e.from_node == e.to_node):
			if (horizontal):
				ax = a.x + a.w
				bx = ax
				ay = a.y + 16
				by = a.y + a.h - 16
			else:
				ay = a.y + a.h
				by = ay
				ax = a.x + 16
				bx = a.x + a.w - 16
		int mx = (ax + bx) / 2
		int my = (ay + by) / 2
		int backwards = 0
		if (horizontal): backwards = (reverse == 0 && bx < ax) || (reverse && bx > ax)
		else: backwards = (reverse == 0 && by < ay) || (reverse && by > ay)
		if (backwards && e.from_node != e.to_node):
			if (horizontal):
				ax = a.x + a.w / 2
				ay = a.y + a.h
				bx = b.x + b.w / 2
				by = b.y + b.h
				my = ay + 24
				if (by + 24 > my): my = by + 24
				mm_line(s, ax, ay, ax, my, e.dashed)
				mm_line(s, ax, my, bx, my, e.dashed)
				if (e.arrow): mm_framework_arrow(s, bx, my, bx, by, e.dashed)
				else: mm_line(s, bx, my, bx, by, e.dashed)
			else:
				ax = a.x + a.w
				ay = a.y + a.h / 2
				bx = b.x + b.w
				by = b.y + b.h / 2
				mx = ax + 24
				if (bx + 24 > mx): mx = bx + 24
				mm_line(s, ax, ay, mx, ay, e.dashed)
				mm_line(s, mx, ay, mx, by, e.dashed)
				if (e.arrow): mm_framework_arrow(s, mx, by, bx, by, e.dashed)
				else: mm_line(s, mx, by, bx, by, e.dashed)
		else if (horizontal):
			if (e.from_node == e.to_node): mx = a.x + a.w + 30
			mm_line(s, ax, ay, mx, ay, e.dashed)
			mm_line(s, mx, ay, mx, by, e.dashed)
			if (e.arrow): mm_framework_arrow(s, mx, by, bx, by, e.dashed)
			else: mm_line(s, mx, by, bx, by, e.dashed)
		else:
			if (e.from_node == e.to_node): my = a.y + a.h + 30
			mm_line(s, ax, ay, ax, my, e.dashed)
			mm_line(s, ax, my, bx, my, e.dashed)
			if (e.arrow): mm_framework_arrow(s, bx, my, bx, by, e.dashed)
			else: mm_line(s, bx, my, bx, by, e.dashed)
		mm_text(s, mx + 8, my - 20, e.label)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.group): continue
		mm_bounds* b = s.nodes[i]
		if (n.shape == 2): mm_ellipse(s, b.x + b.w / 2, b.y + b.h / 2, b.w / 2, b.h / 2)
		else if (n.shape == 3):
			mm_line(s, b.x, b.y + b.h / 2, b.x + b.w / 2, b.y, 0)
			mm_line(s, b.x + b.w / 2, b.y, b.x + b.w, b.y + b.h / 2, 0)
			mm_line(s, b.x + b.w, b.y + b.h / 2, b.x + b.w / 2, b.y + b.h, 0)
			mm_line(s, b.x + b.w / 2, b.y + b.h, b.x, b.y + b.h / 2, 0)
		else: mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, n.shape == 1, c"")
		if (d.kind == MM_EVENT_MODEL):
			mm_text(s, b.x + 12, b.y + 12, n.annotation)
			mm_text(s, b.x + 12, b.y + 38, n.label)
			for j in range(n.members.length):
				mm_member* m = n.members[j]
				mm_text(s, b.x + 12, b.y + 64 + j * 24, m.text)
		else: mm_text(s, b.x + (b.w - strlen(n.label) * 8) / 2, b.y + (b.h - 16) / 2, n.label)
	__w_list_free(cast(__w_list*, sizes))
	if (s.width < 240): s.width = 240
	if (s.height < 160): s.height = 160
	return s
