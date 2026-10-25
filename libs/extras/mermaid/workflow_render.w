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
	for mm_edge* e in d.edges:
		int edge_start = s.items.length
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
				mm_workflow_start(s, e, ax, ay, ax, my)
				mm_line(s, ax, my, bx, my, e.dashed)
				mm_workflow_end(s, e, bx, my, bx, by)
			else:
				ax = a.x + a.w
				ay = a.y + a.h / 2
				bx = b.x + b.w
				by = b.y + b.h / 2
				mx = ax + 24
				if (bx + 24 > mx): mx = bx + 24
				mm_line(s, ax, ay, mx, ay, e.dashed)
				mm_workflow_start(s, e, ax, ay, mx, ay)
				mm_line(s, mx, ay, mx, by, e.dashed)
				mm_workflow_end(s, e, mx, by, bx, by)
		else if (horizontal):
			if (e.from_node == e.to_node): mx = a.x + a.w + 30
			mm_line(s, ax, ay, mx, ay, e.dashed)
			mm_workflow_start(s, e, ax, ay, mx, ay)
			mm_line(s, mx, ay, mx, by, e.dashed)
			mm_workflow_end(s, e, mx, by, bx, by)
		else:
			if (e.from_node == e.to_node): my = a.y + a.h + 30
			mm_line(s, ax, ay, ax, my, e.dashed)
			mm_workflow_start(s, e, ax, ay, ax, my)
			mm_line(s, ax, my, bx, my, e.dashed)
			mm_workflow_end(s, e, bx, my, bx, by)
		mm_style_edge(d, s, e, edge_start)
		mm_text(s, mx + 8, my - 20, e.label)
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
