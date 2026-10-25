# Family-specific outlines, fishbones, Cynefin regions and Wardley axes.
import libs.extras.mermaid.scene
import libs.extras.mermaid.style_render
import libs.extras.mermaid.shapes

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

# Greedy word wrap at max characters (upstream ishikawaRenderer wrapText).
char* mm_ishikawa_wrap(char* text, int max):
	if (strlen(text) <= max): return strclone(text)
	string_builder* out = string_new()
	int line = 0
	int i = 0
	int length = strlen(text)
	while (i < length):
		while (i < length && (text[i] == 32 || text[i] == 9)): i = i + 1
		int start = i
		while (i < length && text[i] != 32 && text[i] != 9): i = i + 1
		if (i == start): break
		if (out.length > 0 && line + 1 + i - start <= max):
			string_append_char(out, 32)
			line = line + 1
		else if (out.length > 0):
			string_append_char(out, 10)
			line = 0
		string_append_bytes(out, text + start, i - start)
		line = line + i - start
	char* result = strclone(out.data)
	string_free(out)
	return result

int mm_ishikawa_lines(char* text):
	int lines = 1
	for i in range(strlen(text)):
		if (text[i] == 10): lines = lines + 1
	return lines

int mm_ishikawa_width(char* text):
	int widest = 0
	int start = 0
	int length = strlen(text)
	for i in range(length + 1):
		if (i == length || text[i] == 10):
			int w = mm_text_width_range(text, start, i, 0)
			if (w > widest): widest = w
			start = i + 1
	return widest

# Multi-line text anchored like SVG text: anchor 0 start, 1 middle, 2 end;
# baseline 0 middle, 1 alphabetic (text above y), 2 hanging (text below y).
# Records the text block's extent in box.
void mm_ishikawa_text(mm_scene* s, char* text, int x, int y, int anchor, int baseline, mm_bounds* box):
	int lines = mm_ishikawa_lines(text)
	int pitch = 17
	int first = y - (lines - 1) * pitch / 2
	int top = first - MM_TEXT_LINE / 2
	if (baseline == 1): top = first - MM_TEXT_ASCENT
	if (baseline == 2): top = first
	int width = mm_ishikawa_width(text)
	box.x = x
	if (anchor == 1): box.x = x - width / 2
	if (anchor == 2): box.x = x - width
	box.y = top
	box.w = width
	box.h = (lines - 1) * pitch + MM_TEXT_LINE
	int start = 0
	int row = 0
	int length = strlen(text)
	for i in range(length + 1):
		if (i == length || text[i] == 10):
			char* line = str_copy_range(text, start, i)
			int w = mm_text_width(line, 0)
			int lx = x
			if (anchor == 1): lx = x - w / 2
			if (anchor == 2): lx = x - w
			mm_text(s, lx, top + row * pitch, line)
			free(line)
			row = row + 1
			start = i + 1

# Arrowhead with its tip at (x, y), pointing along (dx, dy).
void mm_ishikawa_arrow(mm_scene* s, int x, int y, float dx, float dy):
	float length = fsqrt(dx * dx + dy * dy)
	if (length < 0.5): return
	float ux = dx / length
	float uy = dy / length
	int bx = x - cast(int, ux * 6.0)
	int by = y - cast(int, uy * 6.0)
	int px = cast(int, 0.0 - uy * 3.6)
	int py = cast(int, ux * 3.6)
	mm_draw(s, MM_POLYGON, x - 6, y - 6, x + 6, y + 6, 1, c"")
	mm_primitive* head = s.items[s.items.length - 1]
	head.points = list[int]{x, y, bx + px, by + py, bx - px, by - py}

int mm_ishikawa_descendants(mm_document* d, int index):
	int count = 0
	for i in range(index + 1, d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent == index): count = count + 1 + mm_ishikawa_descendants(d, i)
	return count

int mm_ishikawa_children(mm_document* d, int index):
	int count = 0
	for mm_node* n in d.nodes:
		if (n.parent == index): count = count + 1
	return count

# Flattens a branch: even depths in pre-order (near the spine), odd depths
# in post-order (inside the parent's wedge), upper branches reversed.
void mm_ishikawa_walk(mm_document* d, int parent, int pid, int depth, int dir, list[int] nodes, list[int] depths, list[int] parents, list[int] order):
	list[int] kids = new list[int]
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent == parent): kids.push(i)
	for k in range(kids.length):
		int child = kids[k]
		if (dir < 0): child = kids[kids.length - 1 - k]
		int index = nodes.length
		nodes.push(child)
		depths.push(depth)
		parents.push(pid)
		if (depth % 2 == 0):
			order.push(index)
			mm_ishikawa_walk(d, child, index, depth + 1, dir, nodes, depths, parents, order)
		else:
			mm_ishikawa_walk(d, child, index, depth + 1, dir, nodes, depths, parents, order)
			order.push(index)
	__w_list_free(cast(__w_list*, kids))

# One cause branch (upstream drawBranch): an 82-degree bone from the spine,
# a boxed cause label at its end and alternating horizontal / diagonal bones.
void mm_ishikawa_branch(mm_document* d, mm_scene* s, int cause, float sx, float sy, int dir, float length):
	float cos_a = 0.139173
	float sin_a = 0.990268
	int children = mm_ishikawa_children(d, cause)
	float line = length * 0.2
	if (children > 0): line = length
	float dx = 0.0 - cos_a * line
	float dy = sin_a * line * cast(float, dir)
	float ex = sx + dx
	float ey = sy + dy
	mm_line(s, cast(int, sx), cast(int, sy), cast(int, ex), cast(int, ey), 0)
	mm_ishikawa_arrow(s, cast(int, sx), cast(int, sy), 0.0 - dx, 0.0 - dy)
	mm_node* n = d.nodes[cause]
	mm_bounds* label = s.nodes[cause]
	int box_start = s.items.length
	mm_draw(s, MM_BOX, 0, 0, 0, 0, 0, c"")
	mm_ishikawa_text(s, n.label, cast(int, ex), cast(int, ey) + 11 * dir, 1, 0, label)
	mm_primitive* box = s.items[box_start]
	box.x = label.x - 20
	box.y = label.y - 2
	box.x2 = label.x + label.w + 20
	box.y2 = label.y + label.h + 2
	box.role = 6
	if (children == 0): return
	list[int] nodes = new list[int]
	list[int] depths = new list[int]
	list[int] parents = new list[int]
	list[int] order = new list[int]
	mm_ishikawa_walk(d, cause, -1, 2, dir, nodes, depths, parents, order)
	int count = nodes.length
	list[int] ys = new list[int]
	for i in range(count): ys.push(0)
	for slot in range(order.length): ys[order[slot]] = cast(int, sy + dy * cast(float, slot + 1) / cast(float, count + 1))
	# Bone of each entry (x0, y0, x1, y1) and how many children it has drawn.
	list[int] bones = new list[int]
	list[int] drawn = new list[int]
	for i in range(count + 1):
		for k in range(4): bones.push(0)
		drawn.push(0)
	bones[0] = cast(int, sx)
	bones[1] = cast(int, sy)
	bones[2] = cast(int, ex)
	bones[3] = cast(int, ey)
	for i in range(count):
		int y = ys[i]
		int parent = parents[i] + 1
		int px0 = bones[parent * 4]
		int py0 = bones[parent * 4 + 1]
		int px1 = bones[parent * 4 + 2]
		int py1 = bones[parent * 4 + 3]
		int parent_children = children
		if (parent > 0): parent_children = mm_ishikawa_children(d, nodes[parent - 1])
		int own = mm_ishikawa_children(d, nodes[i])
		mm_node* entry = d.nodes[nodes[i]]
		char* text = mm_ishikawa_wrap(entry.label, 15)
		int bx0 = 0
		int by0 = 0
		int bx1 = 0
		if (depths[i] % 2 == 0):
			float t = 0.5
			if (py1 != py0): t = cast(float, y - py0) / cast(float, py1 - py0)
			bx0 = px0 + cast(int, cast(float, px1 - px0) * t)
			by0 = y
			int run = 30
			if (own > 0): run = 60 + own * 5
			bx1 = bx0 - run
			mm_line(s, bx0, y, bx1, y, 0)
			mm_ishikawa_arrow(s, bx0, y, 1.0, 0.0)
			mm_ishikawa_text(s, text, bx1, y, 2, 0, s.nodes[nodes[i]])
		else:
			int k = drawn[parent]
			drawn[parent] = k + 1
			bx0 = px0 + (px1 - px0) * (parent_children - k) / (parent_children + 1)
			by0 = py0
			bx1 = bx0 + cast(int, (0.0 - cos_a) * cast(float, y - by0) / (sin_a * cast(float, dir)))
			mm_line(s, bx0, by0, bx1, y, 0)
			mm_ishikawa_arrow(s, bx0, by0, cast(float, bx0 - bx1), cast(float, by0 - y))
			int baseline = 2
			if (dir < 0): baseline = 1
			mm_ishikawa_text(s, text, bx1, y, 2, baseline, s.nodes[nodes[i]])
		free(text)
		bones[(i + 1) * 4] = bx0
		bones[(i + 1) * 4 + 1] = by0
		bones[(i + 1) * 4 + 2] = bx1
		bones[(i + 1) * 4 + 3] = y
	__w_list_free(cast(__w_list*, nodes))
	__w_list_free(cast(__w_list*, depths))
	__w_list_free(cast(__w_list*, parents))
	__w_list_free(cast(__w_list*, order))
	__w_list_free(cast(__w_list*, ys))
	__w_list_free(cast(__w_list*, bones))
	__w_list_free(cast(__w_list*, drawn))

# Moves every primitive and bound by (dx, dy) and recomputes the extent.
void mm_framework_shift(mm_scene* s, int dx, int dy, int pad):
	int x1 = 0
	int y1 = 0
	for mm_primitive* p in s.items:
		p.x = p.x + dx
		p.y = p.y + dy
		if (p.kind != MM_TEXT):
			p.x2 = p.x2 + dx
			p.y2 = p.y2 + dy
		if (p.points != 0):
			for i in range(p.points.length):
				if (i % 2): p.points[i] = p.points[i] + dy
				else: p.points[i] = p.points[i] + dx
		int right = p.x2
		int bottom = p.y2
		if (p.kind == MM_TEXT):
			right = p.x + mm_text_width(p.text, 0)
			bottom = p.y + MM_TEXT_LINE
		if (right > x1): x1 = right
		if (bottom > y1): y1 = bottom
		if (p.x > x1): x1 = p.x
		if (p.y > y1): y1 = p.y
	for mm_bounds* b in s.nodes:
		b.x = b.x + dx
		b.y = b.y + dy
	s.width = x1 + pad
	s.height = y1 + pad

# Upstream ishikawaRenderer geometry: the problem head sits at the right end
# of the spine; causes alternate above and below, sharing a 500px pool of
# bone length in proportion to their descendants; each pair of branches
# starts left of the previous pair's labels.
mm_scene* mm_ishikawa_render(mm_document* d):
	mm_scene* s = mm_framework_scene(d)
	int font = 16
	int spine_y = 250
	mm_node* problem = d.nodes[0]
	mm_bounds* head = s.nodes[0]
	char* title = mm_ishikawa_wrap(problem.label, 13)
	int text_w = mm_ishikawa_width(title)
	int text_h = (mm_ishikawa_lines(title) - 1) * 17 + MM_TEXT_LINE
	int w = text_w + 6
	if (w < 60): w = 60
	int h = text_h * 2 + 40
	if (h < 40): h = 40
	list[int] causes = new list[int]
	int upper_total = 0
	int lower_total = 0
	int upper_max = 0
	int lower_max = 0
	for i in range(1, d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != 0): continue
		int count = mm_ishikawa_descendants(d, i)
		if (causes.length % 2 == 0):
			upper_total = upper_total + count
			if (count > upper_max): upper_max = count
		else:
			lower_total = lower_total + count
			if (count > lower_max): lower_max = count
		causes.push(i)
	float upper = 250.0
	float lower = 250.0
	if (upper_total + lower_total > 0):
		upper = 500.0 * cast(float, upper_total) / cast(float, upper_total + lower_total)
		lower = 500.0 * cast(float, lower_total) / cast(float, upper_total + lower_total)
		if (upper < 75.0): upper = 75.0
		if (lower < 75.0): lower = 75.0
	if (upper < cast(float, upper_max * font * 2)): upper = cast(float, upper_max * font * 2)
	if (lower < cast(float, lower_max * font * 2)): lower = cast(float, lower_max * font * 2)
	if (causes.length > 0 && cast(int, upper) > spine_y): spine_y = cast(int, upper)
	# The head: a quadratic fish head closing on the spine's right end.
	mm_draw(s, MM_POLYGON, 0, spine_y - h / 2, w * 2, spine_y + h / 2, 0, c"")
	mm_primitive* outline = s.items[s.items.length - 1]
	outline.points = new list[int]
	for i in range(25):
		float t = cast(float, i) / 24.0
		float u = 1.0 - t
		outline.points.push(cast(int, 2.0 * u * t * cast(float, w) * 2.4))
		outline.points.push(spine_y + cast(int, (u * u - t * t) * cast(float, h) / 2.0))
	mm_ishikawa_text(s, title, (w - text_w) / 2 + 3, spine_y, 0, 0, head)
	head.x = 0
	head.y = spine_y - h / 2
	head.w = w * 2
	head.h = h
	free(title)
	int spine_x = -20
	int pairs = (causes.length + 1) / 2
	for pair in range(pairs):
		int start = s.items.length
		mm_ishikawa_branch(d, s, causes[pair * 2], cast(float, spine_x), cast(float, spine_y), -1, upper)
		if (pair * 2 + 1 < causes.length): mm_ishikawa_branch(d, s, causes[pair * 2 + 1], cast(float, spine_x), cast(float, spine_y), 1, lower)
		for k in range(start, s.items.length):
			mm_primitive* p = s.items[k]
			if (p.kind == MM_TEXT && p.x < spine_x): spine_x = p.x
	if (causes.length == 0): spine_x = 0
	mm_line(s, spine_x, spine_y, 0, spine_y, 0)
	mm_primitive* spine = s.items[s.items.length - 1]
	spine.style.mask = spine.style.mask | 8
	spine.style.width = 2
	__w_list_free(cast(__w_list*, causes))
	int min_x = 0
	int min_y = 0
	for mm_primitive* p in s.items:
		if (p.x < min_x): min_x = p.x
		if (p.y < min_y): min_y = p.y
		if (p.kind != MM_TEXT && p.x2 < min_x): min_x = p.x2
		if (p.kind != MM_TEXT && p.y2 < min_y): min_y = p.y2
		if (p.points != 0):
			for i in range(p.points.length):
				if (i % 2 == 0 && p.points[i] < min_x): min_x = p.points[i]
				if (i % 2 && p.points[i] < min_y): min_y = p.points[i]
	mm_framework_shift(s, 20 - min_x, 20 - min_y, 20)
	return s

# Deterministic value in [0, 1) for a seed (Park-Miller steps; the same on
# every word size). Upstream seeds waviness from the SVG id; the native
# renderer uses a fixed seed so output is reproducible.
float mm_cynefin_random(int seed):
	int x = seed % 2147483646
	if (x < 0): x = 0 - x
	x = x + 1
	for i in range(3):
		x = 16807 * (x % 127773) - 2836 * (x / 127773)
		if (x <= 0): x = x + 2147483647
	return cast(float, x) / 2147483647.0

# A wavy boundary through the field (upstream generateFoldPath /
# generateHorizontalBoundary): seven cubic segments with seeded jitter.
void mm_cynefin_wave(mm_scene* s, int ox, int oy, int width, int height, int seed, int vertical):
	float amplitude = 8.0
	int length = width
	if (vertical): length = height
	int step_mul = 23
	int offset_mul = 37
	int offset_add = 11
	if (vertical):
		step_mul = 17
		offset_mul = 31
		offset_add = 7
	list[int] points = new list[int]
	for i in range(8):
		int jitter = cast(int, mm_cynefin_random(seed + i * step_mul) * amplitude * 2.0 - amplitude)
		points.push(length * i / 7)
		points.push(jitter)
	for i in range(7):
		int a = points[i * 2]
		int ja = points[i * 2 + 1]
		int b = points[i * 2 + 2]
		int jb = points[i * 2 + 3]
		int mid = (a + b) / 2
		int dir = 1
		if (i % 2): dir = -1
		int bend = cast(int, amplitude * 1.5 * cast(float, dir) * mm_cynefin_random(seed + i * offset_mul + offset_add))
		if (vertical): mm_style_bezier(s, ox + width / 2 + ja, oy + a, ox + width / 2 + ja + bend, oy + mid, ox + width / 2 + jb - bend, oy + mid, ox + width / 2 + jb, oy + b, 0)
		else: mm_style_bezier(s, ox + a, oy + height / 2 + ja, ox + mid, oy + height / 2 + ja + bend, ox + mid, oy + height / 2 + jb - bend, ox + b, oy + height / 2 + jb, 0)
	__w_list_free(cast(__w_list*, points))

void mm_cynefin_badge(mm_scene* s, int cx, int y, char* text, int overflow):
	int width = mm_text_width(text, 0) + 20
	mm_draw(s, MM_BOX, cx - width / 2, y, cx - width / 2 + width, y + 26, 1, c"")
	mm_primitive* badge = s.items[s.items.length - 1]
	badge.role = 6
	if (overflow): badge.dashed = 0
	mm_text(s, cx - width / 2 + 10, y + 5, text)

# Upstream cynefinRenderer geometry on its default 800x600 field with 40px
# padding: four quadrants, the seeded wavy fold and horizontal boundary, the
# Clear/Chaotic cliff, the central Confusion ellipse (at most three item
# badges plus "+N more"), domain models and practices, and transitions as
# quadratic curves between domain centres bowed by 15% of their length.
mm_scene* mm_cynefin_render(mm_document* d):
	mm_scene* s = mm_framework_scene(d)
	int pad = 40
	int width = 800
	int height = 600
	int hw = width / 2
	int hh = height / 2
	list[char*] names = list[char*]{c"Complex", c"Complicated", c"Chaotic", c"Clear", c"Confusion"}
	list[char*] models = list[char*]{c"Probe → Sense → Respond", c"Sense → Analyse → Respond", c"Act → Sense → Respond", c"Sense → Categorise → Respond", c""}
	list[char*] practices = list[char*]{c"Emergent Practices", c"Good Practices", c"Novel Practices", c"Best Practices", c"Disorder"}
	# Node order is complex, complicated, chaotic, clear, confusion.
	for i in range(5):
		mm_bounds* b = s.nodes[i]
		b.x = pad + (i % 2) * hw
		b.y = pad + (i / 2) * hh
		b.w = hw
		b.h = hh
		if (i == 4):
			b.x = pad + hw * 7 / 10
			b.y = pad + hh * 7 / 10
			b.w = hw * 6 / 10
			b.h = hh * 6 / 10
	for i in range(4):
		mm_bounds* b = s.nodes[i]
		int start = s.items.length
		mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
		# Upstream domain backgrounds are unstroked; the boundaries divide them.
		mm_primitive* quadrant = s.items[start]
		quadrant.style.mask = quadrant.style.mask | 2
		quadrant.style.stroke = -1
		mm_style_node(d, s, d.nodes[i], start)
	int seed = 7919
	mm_cynefin_wave(s, pad, pad, width, height, seed, 1)
	mm_cynefin_wave(s, pad, pad, width, height, seed + 100, 0)
	int cliff_start = s.items.length
	int cx = pad + hw
	int amp = width * 3 / 100
	int top = pad + hh
	mm_style_bezier(s, cx, top, cx + amp, top + hh / 5, cx - amp * 3 / 2, top + hh * 55 / 100, cx + amp / 2, top + hh * 75 / 100, 0)
	mm_style_bezier(s, cx + amp / 2, top + hh * 75 / 100, cx - amp, top + hh * 85 / 100, cx + amp * 3 / 10, top + hh * 95 / 100, cx, pad + height, 0)
	for k in range(cliff_start, s.items.length):
		mm_primitive* p = s.items[k]
		p.style.mask = p.style.mask | 8
		p.style.width = 4
	int confusion_start = s.items.length
	mm_shape_ellipse(s, cx, pad + hh, width * 15 / 100, height * 15 / 100)
	mm_style_node(d, s, d.nodes[4], confusion_start)
	for i in range(5):
		mm_bounds* b = s.nodes[i]
		int centre_x = b.x + b.w / 2
		int centre_y = b.y + b.h / 2
		int label_y = centre_y - 30
		if (i == 4): label_y = pad + hh - 10
		mm_text_styled(s, centre_x - mm_text_width(names[i], MM_TEXT_BOLD) / 2, label_y - MM_TEXT_LINE / 2, names[i], MM_TEXT_BOLD)
		if (i < 4):
			mm_text(s, centre_x - mm_text_width(models[i], 0) / 2, centre_y - 10 - MM_TEXT_LINE / 2, models[i])
			mm_text(s, centre_x - mm_text_width(practices[i], 0) / 2, centre_y + 5 - MM_TEXT_LINE / 2, practices[i])
		else: mm_text(s, centre_x - mm_text_width(practices[i], 0) / 2, pad + hh + 8 - MM_TEXT_LINE / 2, practices[i])
		mm_node* n = d.nodes[i]
		int first = centre_y + 25
		if (i == 4): first = pad + hh + 22
		int shown = n.members.length
		if (i == 4 && shown > 3): shown = 3
		for j in range(shown):
			mm_member* m = n.members[j]
			mm_cynefin_badge(s, centre_x, first + j * 30, m.text + 6, 0)
		if (shown < n.members.length):
			string_builder* more = string_from(c"+")
			string_append_int(more, n.members.length - shown)
			string_append(more, c" more")
			mm_cynefin_badge(s, centre_x, first + shown * 30, more.data, 1)
			string_free(more)
	__w_list_free(cast(__w_list*, names))
	__w_list_free(cast(__w_list*, models))
	__w_list_free(cast(__w_list*, practices))
	for mm_edge* e in d.edges:
		# Self-loops carry no movement; upstream skips them too.
		if (e.from_node == e.to_node): continue
		mm_bounds* a = s.nodes[e.from_node]
		mm_bounds* b = s.nodes[e.to_node]
		int x1 = a.x + a.w / 2
		int y1 = a.y + a.h / 2
		int x2 = b.x + b.w / 2
		int y2 = b.y + b.h / 2
		float dx = cast(float, x2 - x1)
		float dy = cast(float, y2 - y1)
		float length = fsqrt(dx * dx + dy * dy)
		if (length < 1.0): continue
		int cpx = (x1 + x2) / 2 + cast(int, (0.0 - dy / length) * length * 0.15)
		int cpy = (y1 + y2) / 2 + cast(int, dx / length * length * 0.15)
		int start = s.items.length
		mm_style_bezier(s, x1, y1, x1 + (cpx - x1) * 2 / 3, y1 + (cpy - y1) * 2 / 3, x2 + (cpx - x2) * 2 / 3, y2 + (cpy - y2) * 2 / 3, x2, y2, 0)
		mm_ishikawa_arrow(s, x2, y2, cast(float, x2 - cpx), cast(float, y2 - cpy))
		for k in range(start, s.items.length):
			mm_primitive* p = s.items[k]
			p.role = 3
		if (e.label[0] != 0): mm_text(s, cpx - mm_text_width(e.label, 0) / 2, cpy - 6 - MM_TEXT_ASCENT, e.label)
	if (d.title[0] != 0):
		s.has_title = 1
		mm_text(s, pad + hw - mm_text_width(d.title, 0) / 2, pad / 2 - MM_TEXT_LINE / 2, d.title)
		mm_primitive* heading = s.items[s.items.length - 1]
		heading.role = 4
	s.width = width + pad * 2
	s.height = height + pad * 2
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
