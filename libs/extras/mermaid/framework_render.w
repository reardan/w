# Family-specific outlines, fishbones, Cynefin regions and Wardley axes.
import libs.extras.mermaid.scene
import libs.extras.mermaid.icons
import libs.extras.mermaid.style_render
import libs.extras.mermaid.shapes

mm_scene* mm_framework_scene(mm_document* d):
	mm_scene* s = new mm_scene()
	s.items = new list[mm_primitive*]
	s.nodes = new list[mm_bounds*]
	for mm_node* n in d.nodes:
		mm_bounds* b = new mm_bounds()
		b.w = mm_text_width(n.label, 0) + 32
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

# Colour of a treeView theme variable setting, or `fallback`.
int mm_tree_color(mm_document* d, char* key, int fallback):
	char* value = mm_config_value(d, key)
	if (value == 0): return fallback
	int color = mm_style_color(value)
	if (color < 0): return fallback
	return color

# Icon reference for a row: an explicit `icon(...)` always ("" hides it);
# with `showIcons`, filenameIcons / extensionIcons, then folder or file.
char* mm_tree_icon(mm_document* d, int index, int show):
	mm_node* n = d.nodes[index]
	for mm_property* property in n.metadata:
		if (strcmp(property.key, c"icon") == 0): return property.value
	if (show == 0): return c""
	string_builder* key = string_from(c"treeView.filenameIcons.")
	string_append(key, n.label)
	char* mapped = mm_config_value(d, key.data)
	string_free(key)
	if (mapped != 0): return mapped
	int dot = -1
	for i in range(strlen(n.label)):
		if (n.label[i] == '.'): dot = i
	if (dot > 0):
		key = string_from(c"treeView.extensionIcons.")
		string_append(key, n.label + dot + 1)
		mapped = mm_config_value(d, key.data)
		string_free(key)
		if (mapped != 0): return mapped
	int folder = n.label[strlen(n.label) - 1] == '/'
	for mm_node* other in d.nodes:
		if (other.parent == index): folder = 1
	if (folder): return c"folder"
	return c"file"

void mm_tree_stroke(mm_scene* s, int color, int width):
	mm_primitive* p = s.items[s.items.length - 1]
	p.style.mask = p.style.mask | 2 | 8
	p.style.stroke = color
	p.style.width = width
# The node names the `highlight` class and no classDef/themeCSS rule replaces it.
int mm_tree_highlighted(mm_node* n):
	int start = 0
	int length = strlen(n.style_classes)
	int found = 0
	for i in range(length + 1):
		if (i == length || n.style_classes[i] == ','):
			char* name = str_copy_range(n.style_classes, start, i)
			if (strcmp(name, c"highlight") == 0): found = 1
			free(name)
			start = i + 1
	return found

mm_scene* mm_treeview_render(mm_document* d):
	mm_scene* s = mm_framework_scene(d)
	char* setting = mm_config_value(d, c"treeView.showIcons")
	int show = setting != 0 && strcmp(setting, c"true") == 0
	int indent = 36
	setting = mm_config_value(d, c"treeView.rowIndent")
	if (setting != 0):
		indent = atoi(setting)
		if (indent < 12): indent = 12
		if (indent > 200): indent = 200
	int thickness = 1
	setting = mm_config_value(d, c"treeView.lineThickness")
	if (setting != 0):
		thickness = atoi(setting)
		if (thickness < 1): thickness = 1
		if (thickness > 8): thickness = 8
	int line_color = mm_tree_color(d, c"themeVariables.treeView.lineColor", 0x111827)
	int label_color = mm_tree_color(d, c"themeVariables.treeView.labelColor", -1)
	int description_color = mm_tree_color(d, c"themeVariables.treeView.descriptionColor", 0x64748b)
	int icon_color = mm_tree_color(d, c"themeVariables.treeView.iconColor", 0x546e7a)
	int highlight_fill = mm_tree_color(d, c"themeVariables.treeView.highlightBg", 0xfff7dc)
	int highlight_stroke = mm_tree_color(d, c"themeVariables.treeView.highlightStroke", 0xffc107)
	int styled = thickness != 1 || mm_config_value(d, c"themeVariables.treeView.lineColor") != 0
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		b.x = 40
		b.y = 40 + i * 32
		if (n.parent >= 0):
			mm_bounds* a = s.nodes[n.parent]
			b.x = a.x + indent
			mm_line(s, a.x + 8, a.y + 24, a.x + 8, b.y + 8, 0)
			if (styled): mm_tree_stroke(s, line_color, thickness)
			mm_line(s, a.x + 8, b.y + 8, b.x - 4, b.y + 8, 0)
			if (styled): mm_tree_stroke(s, line_color, thickness)
		int x = b.x
		char* icon = mm_tree_icon(d, i, show)
		int has_icon = icon[0] != 0
		int width = mm_text_width(n.label, 0)
		if (n.annotation[0] != 0): width = width + 24 + mm_text_width(n.annotation, MM_TEXT_ITALIC)
		if (has_icon): width = width + 26
		# Classed rows get a box behind the row that classDef/themeCSS rules
		# style; `highlight` is upstream's built-in class (highlightBg over
		# white, highlightStroke).
		int start = s.items.length
		if (n.style_classes[0] != 0):
			mm_draw(s, MM_BOX, b.x - 6, b.y - 4, b.x + width + 6, b.y + 22, 0, c"")
			mm_primitive* row = s.items[start]
			if (mm_tree_highlighted(n)):
				row.style.mask = MM_STYLE_FILL | MM_STYLE_STROKE | MM_STYLE_WIDTH
				row.style.fill = highlight_fill
				row.style.stroke = highlight_stroke
				row.style.width = 1
		if (has_icon):
			mm_icon_draw(s, icon, x + 10, b.y + 8, icon_color)
			x = x + 26
		mm_text(s, x, b.y, n.label)
		if (label_color >= 0):
			mm_primitive* label = s.items[s.items.length - 1]
			label.style.mask = label.style.mask | 4
			label.style.text = label_color
		if (n.annotation[0] != 0):
			mm_text_styled(s, x + mm_text_width(n.label, 0) + 24, b.y, n.annotation, MM_TEXT_ITALIC)
			mm_primitive* description = s.items[s.items.length - 1]
			description.style.mask = description.style.mask | 4
			description.style.text = description_color
		if (n.style_classes[0] != 0): mm_style_node(d, s, n, start)
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

# Dense transition routing (issue #817). Upstream draws every transition
# from domain centre to domain centre bowed by 15%, so arrows land on the
# domain names and parallel transitions coincide. Here each domain's text
# (name, model, practices, item badges) is a keep-out block. A transition
# runs on a line parallel to the centre line, shifted 8px to the left of
# its direction (and 16px further for each earlier transition between the
# same domains in the same direction), from where that line leaves the
# source block (plus a margin) to where it enters the target's; it bows
# to the same side by 15% (+15% per nesting step) of its chord, so a
# reverse transition takes the other side and repeats nest outside each
# other. Where that curve would enter a third domain's block or run
# alongside an earlier transition, bows 30% and 60% larger, then a 60%
# smaller one are tried; with none clean the least bad wins.
# Labels sit beside the curve's midpoint, moving along and across it until
# they overlap no block and no earlier label.
const int MM_CYNEFIN_MARGIN = 10

struct mm_cynefin_router:
	# Keep-out text blocks per domain (x0, y0, x1, y1).
	list[int] bx0
	list[int] by0
	list[int] bx1
	list[int] by1
	# Sample points of curves drawn so far, and placed label boxes.
	list[int] sx
	list[int] sy
	list[int] lx0
	list[int] ly0
	list[int] lx1
	list[int] ly1

mm_cynefin_router* mm_cynefin_router_new():
	mm_cynefin_router* r = new mm_cynefin_router()
	r.bx0 = new list[int]
	r.by0 = new list[int]
	r.bx1 = new list[int]
	r.by1 = new list[int]
	r.sx = new list[int]
	r.sy = new list[int]
	r.lx0 = new list[int]
	r.ly0 = new list[int]
	r.lx1 = new list[int]
	r.ly1 = new list[int]
	return r

void mm_cynefin_router_free(mm_cynefin_router* r):
	__w_list_free(cast(__w_list*, r.bx0))
	__w_list_free(cast(__w_list*, r.by0))
	__w_list_free(cast(__w_list*, r.bx1))
	__w_list_free(cast(__w_list*, r.by1))
	__w_list_free(cast(__w_list*, r.sx))
	__w_list_free(cast(__w_list*, r.sy))
	__w_list_free(cast(__w_list*, r.lx0))
	__w_list_free(cast(__w_list*, r.ly0))
	__w_list_free(cast(__w_list*, r.lx1))
	__w_list_free(cast(__w_list*, r.ly1))
	free(r)

# Widen domain's keep-out block to cover a text box.
void mm_cynefin_block(mm_cynefin_router* r, int domain, int x0, int y0, int x1, int y1):
	while (r.bx0.length <= domain):
		r.bx0.push(100000)
		r.by0.push(100000)
		r.bx1.push(-100000)
		r.by1.push(-100000)
	if (x0 < r.bx0[domain]): r.bx0[domain] = x0
	if (y0 < r.by0[domain]): r.by0[domain] = y0
	if (x1 > r.bx1[domain]): r.bx1[domain] = x1
	if (y1 > r.by1[domain]): r.by1[domain] = y1

# Point where the ray from (ox, oy) inside domain's block (grown by the
# margin) along (ux, uy) leaves it.
void mm_cynefin_exit(mm_cynefin_router* r, int domain, float ox, float oy, float ux, float uy, int* x, int* y):
	float x0 = cast(float, r.bx0[domain] - MM_CYNEFIN_MARGIN)
	float x1 = cast(float, r.bx1[domain] + MM_CYNEFIN_MARGIN)
	float y0 = cast(float, r.by0[domain] - MM_CYNEFIN_MARGIN)
	float y1 = cast(float, r.by1[domain] + MM_CYNEFIN_MARGIN)
	float t = 100000.0
	if (ux > 0.0001): t = (x1 - ox) / ux
	if (ux < -0.0001): t = (x0 - ox) / ux
	if (uy > 0.0001 && (y1 - oy) / uy < t): t = (y1 - oy) / uy
	if (uy < -0.0001 && (y0 - oy) / uy < t): t = (y0 - oy) / uy
	if (t < 0.0): t = 0.0
	*x = cast(int, ox + ux * t)
	*y = cast(int, oy + uy * t)

int mm_cynefin_inside(mm_cynefin_router* r, int domain, int x, int y, int grow):
	return x > r.bx0[domain] - grow && x < r.bx1[domain] + grow && y > r.by0[domain] - grow && y < r.by1[domain] + grow

# Quadratic Bezier sample at t/12.
int mm_cynefin_qx(int x1, int cx, int x2, int t):
	float u = cast(float, t) / 12.0
	return cast(int, (1.0 - u) * (1.0 - u) * cast(float, x1) + 2.0 * (1.0 - u) * u * cast(float, cx) + u * u * cast(float, x2))

# Penalty of a candidate curve: samples inside other domains' blocks
# (heavy) and samples running within 8px of earlier curves.
int mm_cynefin_penalty(mm_cynefin_router* r, int from, int to, int x1, int y1, int cx, int cy, int x2, int y2):
	int penalty = 0
	for t in range(1, 12):
		int x = mm_cynefin_qx(x1, cx, x2, t)
		int y = mm_cynefin_qx(y1, cy, y2, t)
		for k in range(r.bx0.length):
			if (k != from && k != to && mm_cynefin_inside(r, k, x, y, 4)): penalty = penalty + 10
		if (t < 2 || t > 10): continue
		for j in range(r.sx.length):
			int dx = r.sx[j] - x
			int dy = r.sy[j] - y
			if (dx * dx + dy * dy < 64):
				penalty = penalty + 1
				break
	return penalty

int mm_cynefin_label_clear(mm_cynefin_router* r, int x, int y, int w, int h, int field_x0, int field_y0, int field_x1, int field_y1):
	if (x < field_x0 || y < field_y0 || x + w > field_x1 || y + h > field_y1): return 0
	for k in range(r.bx0.length):
		if (x < r.bx1[k] + 2 && x + w > r.bx0[k] - 2 && y < r.by1[k] + 2 && y + h > r.by0[k] - 2): return 0
	for k in range(r.lx0.length):
		if (x < r.lx1[k] + 3 && x + w > r.lx0[k] - 3 && y < r.ly1[k] + 3 && y + h > r.ly0[k] - 3): return 0
	return 1

void mm_cynefin_label(mm_scene* s, mm_cynefin_router* r, char* text, int x1, int y1, int cx, int cy, int x2, int y2, int field_x0, int field_y0, int field_x1, int field_y1):
	int w = mm_text_width(text, 0)
	int h = MM_TEXT_LINE
	list[int] ts = list[int]{6, 5, 7, 4, 8, 3, 9}
	# Unit normal on the bow side.
	float nx = cast(float, cx - (x1 + x2) / 2)
	float ny = cast(float, cy - (y1 + y2) / 2)
	float length = fsqrt(nx * nx + ny * ny)
	if (length < 1.0):
		nx = 0.0
		ny = -1.0
	else:
		nx = nx / length
		ny = ny / length
	int best_x = mm_cynefin_qx(x1, cx, x2, 6) - w / 2
	int best_y = mm_cynefin_qx(y1, cy, y2, 6) - h - 4
	int found = 0
	for int t in ts:
		if (found): break
		int px = mm_cynefin_qx(x1, cx, x2, t)
		int py = mm_cynefin_qx(y1, cy, y2, t)
		for side in range(2):
			float sign = 1.0
			if (side == 1): sign = -1.0
			# Offset the box centre so its nearest edge clears the curve.
			float reach = 6.0 + fabs(nx) * cast(float, w) / 2.0 + fabs(ny) * cast(float, h) / 2.0
			int x = px + cast(int, sign * nx * reach) - w / 2
			int y = py + cast(int, sign * ny * reach) - h / 2
			if (mm_cynefin_label_clear(r, x, y, w, h, field_x0, field_y0, field_x1, field_y1)):
				best_x = x
				best_y = y
				found = 1
				break
	__w_list_free(cast(__w_list*, ts))
	mm_text(s, best_x, best_y, text)
	r.lx0.push(best_x)
	r.ly0.push(best_y)
	r.lx1.push(best_x + w)
	r.ly1.push(best_y + h)

void mm_cynefin_transitions(mm_document* d, mm_scene* s, mm_cynefin_router* r, int field_x0, int field_y0, int field_x1, int field_y1):
	int count = d.edges.length
	list[int] bows = list[int]{0, 30, 60, -60}
	for i in range(count):
		mm_edge* e = d.edges[i]
		int from = e.from_node
		int to = e.to_node
		# Self-loops carry no movement; upstream skips them too.
		if (from == to || from > 4 || to > 4): continue
		# Rank among earlier transitions between the same domains in the
		# same direction: each further one nests outside the previous.
		int nest = 0
		for j in range(i):
			mm_edge* other = d.edges[j]
			if (other.from_node == from && other.to_node == to): nest = nest + 1
		float ax = cast(float, r.bx0[from] + r.bx1[from]) / 2.0
		float ay = cast(float, r.by0[from] + r.by1[from]) / 2.0
		float bx = cast(float, r.bx0[to] + r.bx1[to]) / 2.0
		float by = cast(float, r.by0[to] + r.by1[to]) / 2.0
		float dx = bx - ax
		float dy = by - ay
		float length = fsqrt(dx * dx + dy * dy)
		if (length < 1.0): continue
		float ux = dx / length
		float uy = dy / length
		# Left normal of the direction: the side this transition bows to, so
		# the reverse transition takes the other side.
		float nx = 0.0 - uy
		float ny = ux
		float offset = cast(float, 8 + nest * 16)
		int x1 = 0
		int y1 = 0
		int x2 = 0
		int y2 = 0
		mm_cynefin_exit(r, from, ax + nx * offset, ay + ny * offset, ux, uy, &x1, &y1)
		mm_cynefin_exit(r, to, bx + nx * offset, by + ny * offset, 0.0 - ux, 0.0 - uy, &x2, &y2)
		float cdx = cast(float, x2 - x1)
		float cdy = cast(float, y2 - y1)
		float chord = fsqrt(cdx * cdx + cdy * cdy)
		if (chord < 1.0): continue
		int best_cx = 0
		int best_cy = 0
		int best_penalty = -1
		for int extra in bows:
			float f = cast(float, 15 + nest * 15 + extra) / 100.0
			int cx = (x1 + x2) / 2 + cast(int, (0.0 - cdy / chord) * chord * f)
			int cy = (y1 + y2) / 2 + cast(int, cdx / chord * chord * f)
			# Control points stay on the field so curves never leave it.
			if (cx < field_x0): cx = field_x0
			if (cx > field_x1): cx = field_x1
			if (cy < field_y0): cy = field_y0
			if (cy > field_y1): cy = field_y1
			int penalty = mm_cynefin_penalty(r, from, to, x1, y1, cx, cy, x2, y2)
			if (best_penalty < 0 || penalty < best_penalty):
				best_penalty = penalty
				best_cx = cx
				best_cy = cy
			if (penalty == 0): break
		int cx = best_cx
		int cy = best_cy
		for t in range(13):
			r.sx.push(mm_cynefin_qx(x1, cx, x2, t))
			r.sy.push(mm_cynefin_qx(y1, cy, y2, t))
		int start = s.items.length
		mm_style_bezier(s, x1, y1, x1 + (cx - x1) * 2 / 3, y1 + (cy - y1) * 2 / 3, x2 + (cx - x2) * 2 / 3, y2 + (cy - y2) * 2 / 3, x2, y2, 0)
		mm_ishikawa_arrow(s, x2, y2, cast(float, x2 - cx), cast(float, y2 - cy))
		for k in range(start, s.items.length):
			mm_primitive* p = s.items[k]
			p.role = 3
		if (e.label[0] != 0): mm_cynefin_label(s, r, e.label, x1, y1, cx, cy, x2, y2, field_x0, field_y0, field_x1, field_y1)
	__w_list_free(cast(__w_list*, bows))

# Upstream cynefinRenderer geometry on its default 800x600 field with 40px
# padding: four quadrants, the seeded wavy fold and horizontal boundary, the
# Clear/Chaotic cliff, the central Confusion ellipse (at most three item
# badges plus "+N more"), domain models and practices, and transitions as
# bowed quadratic curves (routed by mm_cynefin_transitions above).
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
	mm_cynefin_router* router = mm_cynefin_router_new()
	for i in range(5):
		mm_bounds* b = s.nodes[i]
		int centre_x = b.x + b.w / 2
		int centre_y = b.y + b.h / 2
		int label_y = centre_y - 30
		if (i == 4): label_y = pad + hh - 10
		int text_start = s.items.length
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
		# The domain's keep-out block covers every text and badge just drawn.
		for k in range(text_start, s.items.length):
			mm_primitive* p = s.items[k]
			int x1 = p.x2
			int y1 = p.y2
			if (p.kind == MM_TEXT):
				x1 = p.x + mm_text_width(p.text, p.text_style)
				y1 = p.y + MM_TEXT_LINE
			mm_cynefin_block(router, i, p.x, p.y, x1, y1)
	__w_list_free(cast(__w_list*, names))
	__w_list_free(cast(__w_list*, models))
	__w_list_free(cast(__w_list*, practices))
	mm_cynefin_transitions(d, s, router, pad, pad, pad + width, pad + height)
	mm_cynefin_router_free(router)
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

# Plot geometry: evolution x from left over width, visibility y upward from
# bottom over height. The default plot is 1000 x 560 pixels; `size [w, h]`
# scales it to the requested canvas.
struct mm_wardley_plot:
	int left
	int top
	int width
	int height

int mm_wardley_x(mm_wardley_plot* plot, int evolution):
	return plot.left + evolution * plot.width / 1000

int mm_wardley_y(mm_wardley_plot* plot, int visibility):
	return plot.top + plot.height - visibility * plot.height / 1000

# Link with optional flow arrowheads (1 at the target, 2 at the source),
# shortened to stop at the component circles, and an optional label.
void mm_wardley_link_draw(mm_scene* s, mm_bounds* a, mm_bounds* b, mm_edge* e):
	float dx = cast(float, b.x - a.x)
	float dy = cast(float, b.y - a.y)
	float length = fsqrt(dx * dx + dy * dy)
	int ax = a.x
	int ay = a.y
	int bx = b.x
	int by = b.y
	if (length > 20.0):
		ax = a.x + cast(int, dx / length * 8.0)
		ay = a.y + cast(int, dy / length * 8.0)
		bx = b.x - cast(int, dx / length * 8.0)
		by = b.y - cast(int, dy / length * 8.0)
	if ((e.arrow & 1) != 0): mm_framework_arrow(s, ax, ay, bx, by, e.dashed)
	if ((e.arrow & 2) != 0): mm_framework_arrow(s, bx, by, ax, ay, e.dashed)
	if (e.arrow == 0): mm_line(s, a.x, a.y, b.x, b.y, e.dashed)
	if (e.label[0] != 0): mm_text(s, (a.x + b.x) / 2 + 6, (a.y + b.y) / 2 - 18, e.label)

# Market decorator: white disc with three linked dots on a triangle.
void mm_wardley_market(mm_scene* s, int x, int y):
	mm_draw(s, MM_CIRCLE, x - 12, y - 12, x + 12, y + 12, 0, c"")
	mm_wardley_paint(s, 0xffffff, 0x111827)
	list[int] points = list[int]{x, y - 7, x + 6, y + 4, x - 6, y + 4}
	for k in range(3):
		int next = (k + 1) % 3
		mm_line(s, points[k * 2], points[k * 2 + 1], points[next * 2], points[next * 2 + 1], 0)
	for k in range(3):
		int px = points[k * 2]
		int py = points[k * 2 + 1]
		mm_draw(s, MM_CIRCLE, px - 4, py - 4, px + 4, py + 4, 0, c"")
		mm_wardley_paint(s, 0xffffff, 0x111827)
	__w_list_free(cast(__w_list*, points))

# Accelerator (direction 1) or deaccelerator (-1): a 60 x 30 block arrow
# whose head flares 8 pixels, as upstream.
void mm_wardley_force_draw(mm_scene* s, int x, int y, int direction, char* label):
	mm_draw(s, MM_POLYGON, x - 30, y - 23, x + 30, y + 23, 0, c"")
	mm_primitive* shape = s.items[s.items.length - 1]
	int tail = x - direction * 30
	int neck = x + direction * 10
	int tip = x + direction * 30
	shape.points = list[int]{tail, y - 15, neck, y - 15, neck, y - 23, tip, y, neck, y + 23, neck, y + 15, tail, y + 15}
	mm_wardley_paint(s, 0xffffff, 0x111827)
	mm_text_styled(s, x - mm_text_width(label, MM_TEXT_BOLD) / 2, y + 28, label, MM_TEXT_BOLD)

# Numbered annotation texts, sorted by number, in a white box at the
# `annotations` position (default: the plot's top-right corner).
void mm_wardley_legend(mm_document* d, mm_scene* s, mm_wardley_plot* plot):
	list[int] order = new list[int]
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.shape != 4): continue
		int duplicate = 0
		for int k in order:
			mm_node* other = d.nodes[k]
			if (strcmp(other.annotation, n.annotation) == 0): duplicate = 1
		if (duplicate): continue
		int at = order.length
		order.push(i)
		while (at > 0):
			mm_node* before = d.nodes[order[at - 1]]
			if (atoi(before.annotation) <= atoi(n.annotation)): break
			order[at] = order[at - 1]
			order[at - 1] = i
			at = at - 1
	char* position = mm_config_value(d, c"wardley.annotations")
	if (order.length == 0 && position == 0):
		__w_list_free(cast(__w_list*, order))
		return
	list[char*] lines = new list[char*]
	int widest = 0
	for int k in order:
		mm_node* n = d.nodes[k]
		string_builder* line = string_from(n.annotation)
		string_append(line, c". ")
		string_append(line, n.label)
		int width = mm_text_width(line.data, 0)
		if (width > widest): widest = width
		lines.push(line.data)
		free(line)
	int box_width = widest + 20
	int box_height = lines.length * 20 + 20
	int x = plot.left + plot.width - box_width
	int y = plot.top
	if (position != 0):
		int visibility = atoi(position)
		int evolution = atoi(position + index_of(position, c" ") + 1)
		x = mm_wardley_x(plot, evolution)
		y = mm_wardley_y(plot, visibility)
		if (x + box_width > plot.left + plot.width): x = plot.left + plot.width - box_width
		if (y + box_height > plot.top + plot.height): y = plot.top + plot.height - box_height
		if (x < plot.left): x = plot.left
		if (y < plot.top): y = plot.top
	mm_draw(s, MM_BOX, x, y, x + box_width, y + box_height, 0, c"")
	mm_wardley_paint(s, 0xffffff, 0x6b7280)
	for i in range(lines.length): mm_text(s, x + 10, y + 10 + i * 20, lines[i])
	for char* line in lines: free(line)
	__w_list_free(cast(__w_list*, lines))
	__w_list_free(cast(__w_list*, order))

mm_scene* mm_wardley_render(mm_document* d):
	mm_scene* s = mm_framework_scene(d)
	mm_wardley_plot plot
	plot.left = 80
	plot.top = 90
	plot.width = 1000
	plot.height = 560
	char* size = mm_config_value(d, c"wardley.size")
	if (size != 0):
		plot.width = atoi(size) - 100
		plot.height = atoi(size + index_of(size, c" ") + 1) - 130
		if (plot.width < 200): plot.width = 200
		if (plot.height < 200): plot.height = 200
	int right = plot.left + plot.width
	int bottom = plot.top + plot.height
	s.has_title = d.title[0] != 0
	mm_text(s, 80, 24, d.title)
	mm_text(s, 80, 52, c"Visibility")
	mm_framework_arrow(s, 80, bottom, 80, plot.top, 0)
	mm_framework_arrow(s, 80, bottom, right, bottom, 0)
	mm_text(s, right - 100, bottom + 38, c"Evolution")
	int count = 0
	for mm_note* note in d.notes:
		if (note.node == -1 && note.side + 1 > count): count = note.side + 1
	list[char*] stages = list[char*]{c"Genesis", c"Custom", c"Product", c"Commodity"}
	if (count == 0): count = 4
	while (stages.length < count): stages.push(c"")
	list[char*] seconds = new list[char*]
	for i in range(count): seconds.push(0)
	for mm_note* note in d.notes:
		if (note.node == -1 && note.side >= 0 && note.side < count): stages[note.side] = note.text
		if (note.node == -2 && note.side >= 0 && note.side < count): seconds[note.side] = note.text
	# Stage i spans edges[i]..edges[i + 1]: even splits or `Stage@boundary` ends.
	list[int] edges = new list[int]
	edges.push(0)
	char* boundaries = mm_config_value(d, c"wardley.boundaries")
	int at = 0
	for i in range(count):
		int edge = (i + 1) * 1000 / count
		if (boundaries != 0 && boundaries[at] != 0):
			edge = atoi(boundaries + at)
			while (boundaries[at] != 0 && boundaries[at] != ' '): at = at + 1
			if (boundaries[at] == ' '): at = at + 1
		edges.push(edge)
	for i in range(count):
		int x = mm_wardley_x(&plot, edges[i])
		mm_text(s, x + 20, bottom + 12, stages[i])
		if (seconds[i] != 0): mm_text(s, x + 20, bottom + 26, seconds[i])
		if (i > 0): mm_line(s, x, plot.top, x, bottom, 1)
	__w_list_free(cast(__w_list*, stages))
	__w_list_free(cast(__w_list*, seconds))
	__w_list_free(cast(__w_list*, edges))
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		b.x = mm_wardley_x(&plot, n.value_x)
		b.y = mm_wardley_y(&plot, n.value_y)
		if (n.shape == 2): b.y = b.y + 28
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		char* range = mm_wardley_value(n, c"pipeline")
		if (range == 0): continue
		mm_bounds* b = s.nodes[i]
		int split = index_of(range, c" ")
		int low = mm_wardley_x(&plot, atoi(range))
		int high = mm_wardley_x(&plot, atoi(range + split + 1))
		mm_draw(s, MM_BOX, low - 12, b.y + 12, high + 12, b.y + 44, 0, c"")
	for mm_edge* e in d.edges: mm_wardley_link_draw(s, s.nodes[e.from_node], s.nodes[e.to_node], e)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		char* evolve = mm_wardley_value(n, c"evolve")
		if (evolve == 0): continue
		int target = mm_wardley_x(&plot, atoi(evolve))
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
	# Same-numbered annotation markers are joined by dashed connectors.
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.shape != 4): continue
		for j in range(i + 1, d.nodes.length):
			mm_node* other = d.nodes[j]
			if (other.shape == 4 && strcmp(other.annotation, n.annotation) == 0):
				mm_bounds* a = s.nodes[i]
				mm_bounds* b = s.nodes[j]
				mm_line(s, a.x, a.y, b.x, b.y, 1)
				break
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		if (n.shape == 3):
			mm_text(s, b.x, b.y - 8, n.label)
			continue
		if (n.shape == 4):
			mm_draw(s, MM_CIRCLE, b.x - 10, b.y - 10, b.x + 10, b.y + 10, 0, c"")
			mm_wardley_paint(s, 0xffffff, 0x111827)
			mm_text_styled(s, b.x - mm_text_width(n.annotation, MM_TEXT_BOLD) / 2, b.y - 8, n.annotation, MM_TEXT_BOLD)
			continue
		if (n.shape == 5 || n.shape == 6):
			int direction = 1
			if (n.shape == 6): direction = -1
			mm_wardley_force_draw(s, b.x, b.y, direction, n.label)
			continue
		char* strategy = mm_wardley_value(n, c"strategy")
		int market = strategy != 0 && strcmp(strategy, c"market") == 0
		if (strategy != 0 && market == 0):
			int fill = 0xe5e7eb
			if (strcmp(strategy, c"buy") == 0): fill = 0x9ca3af
			if (strcmp(strategy, c"outsource") == 0): fill = 0x4b5563
			mm_draw(s, MM_CIRCLE, b.x - 18, b.y - 18, b.x + 18, b.y + 18, 0, c"")
			mm_wardley_paint(s, fill, fill)
		if (market): mm_wardley_market(s, b.x, b.y)
		else: mm_draw(s, MM_CIRCLE, b.x - 6, b.y - 6, b.x + 6, b.y + 6, n.shape == 1, c"")
		if (mm_wardley_value(n, c"inertia") != 0): mm_draw(s, MM_BOX, b.x + 22, b.y - 16, b.x + 28, b.y + 16, 2, c"")
		int dx = 12
		int dy = -16
		if (market): dx = 18
		char* offset = mm_wardley_value(n, c"label")
		if (offset != 0):
			dx = atoi(offset)
			dy = atoi(offset + index_of(offset, c" ") + 1)
		int x = b.x + dx
		int y = b.y + dy
		if (x < 0): x = 0
		if (y < 0): y = 0
		mm_text(s, x, y, n.label)
	mm_wardley_legend(d, s, &plot)
	return s
