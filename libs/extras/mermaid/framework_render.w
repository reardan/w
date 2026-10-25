# Family-specific outlines, fishbones, Cynefin regions and Wardley axes.
import libs.extras.mermaid.scene
import libs.extras.mermaid.icons
import libs.extras.mermaid.style

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

# Colour of a treeView theme variable setting, or `fallback`.
int mm_tree_color(mm_document* d, char* key, int fallback):
	char* value = mm_setting(d, key)
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
	char* mapped = mm_setting(d, key.data)
	string_free(key)
	if (mapped != 0): return mapped
	int dot = -1
	for i in range(strlen(n.label)):
		if (n.label[i] == '.'): dot = i
	if (dot > 0):
		key = string_from(c"treeView.extensionIcons.")
		string_append(key, n.label + dot + 1)
		mapped = mm_setting(d, key.data)
		string_free(key)
		if (mapped != 0): return mapped
	int folder = n.label[strlen(n.label) - 1] == '/'
	for mm_node* other in d.nodes:
		if (other.parent == index): folder = 1
	if (folder): return c"folder"
	return c"file"

int mm_tree_class(mm_node* n, char* name):
	for mm_property* property in n.metadata:
		if (strcmp(property.key, c"classes") != 0): continue
		string_builder* joined = string_from(c",")
		string_append(joined, property.value)
		string_append_char(joined, ',')
		string_builder* needle = string_from(c",")
		string_append(needle, name)
		string_append_char(needle, ',')
		int found = index_of(joined.data, needle.data) >= 0
		string_free(joined)
		string_free(needle)
		return found
	return 0

void mm_tree_stroke(mm_scene* s, int color, int width):
	mm_primitive* p = s.items[s.items.length - 1]
	p.style.mask = p.style.mask | 2 | 8
	p.style.stroke = color
	p.style.width = width

mm_scene* mm_treeview_render(mm_document* d):
	mm_scene* s = mm_framework_scene(d)
	char* setting = mm_setting(d, c"treeView.showIcons")
	int show = setting != 0 && strcmp(setting, c"true") == 0
	int indent = 36
	setting = mm_setting(d, c"treeView.rowIndent")
	if (setting != 0):
		indent = atoi(setting)
		if (indent < 12): indent = 12
		if (indent > 200): indent = 200
	int thickness = 1
	setting = mm_setting(d, c"treeView.lineThickness")
	if (setting != 0):
		thickness = atoi(setting)
		if (thickness < 1): thickness = 1
		if (thickness > 8): thickness = 8
	int line_color = mm_tree_color(d, c"themeVariables.treeView.lineColor", 0x111827)
	int label_color = mm_tree_color(d, c"themeVariables.treeView.labelColor", -1)
	int description_color = mm_tree_color(d, c"themeVariables.treeView.descriptionColor", 0x64748b)
	int icon_color = mm_tree_color(d, c"themeVariables.treeView.iconColor", 0x546e7a)
	int highlight_fill = mm_tree_color(d, c"themeVariables.treeView.highlightBg", 0xfff6d9)
	int highlight_stroke = mm_tree_color(d, c"themeVariables.treeView.highlightStroke", 0xffc107)
	int styled = thickness != 1 || mm_setting(d, c"themeVariables.treeView.lineColor") != 0
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
		# The built-in `highlight` class tints the row as upstream.
		if (mm_tree_class(n, c"highlight")):
			mm_draw(s, MM_BOX, b.x - 6, b.y - 4, b.x + width + 6, b.y + 22, 0, c"")
			mm_primitive* row = s.items[s.items.length - 1]
			row.style.mask = row.style.mask | 3
			row.style.fill = highlight_fill
			row.style.stroke = highlight_stroke
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
	char* position = mm_setting(d, c"wardley.annotations")
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
	char* size = mm_setting(d, c"wardley.size")
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
	char* boundaries = mm_setting(d, c"wardley.boundaries")
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
