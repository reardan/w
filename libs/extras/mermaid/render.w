# Deterministic native layout and a backend-independent display list.
# No DOM, JavaScript, external layout engine or graphics context required.
import libs.extras.mermaid.model
import lib.fmath

const int MM_LINE = 1
const int MM_BOX = 2
const int MM_TEXT = 3
const int MM_CIRCLE = 4
const int MM_POLYGON = 5

struct mm_primitive:
	int kind
	int x
	int y
	int x2
	int y2
	int dashed
	char* text
	list[int] points

struct mm_bounds:
	int x
	int y
	int w
	int h
	int rank

struct mm_scene:
	list[mm_primitive*] items
	list[mm_bounds*] nodes
	int width
	int height

void mm_draw(mm_scene* s, int kind, int x, int y, int x2, int y2, int dashed, char* text):
	mm_primitive* p = new mm_primitive(kind, x, y, x2, y2, dashed, strclone(text), 0)
	s.items.push(p)
	if (kind == MM_TEXT): x2 = x + strlen(text) * 8
	if (kind == MM_TEXT): y2 = y + 16
	if (x2 + 40 > s.width): s.width = x2 + 40
	if (y2 + 40 > s.height): s.height = y2 + 40
	if (x + 40 > s.width): s.width = x + 40
	if (y + 40 > s.height): s.height = y + 40

void mm_line(mm_scene* s, int x, int y, int x2, int y2, int dashed):
	mm_draw(s, MM_LINE, x, y, x2, y2, dashed, c"")

void mm_text(mm_scene* s, int x, int y, char* text):
	mm_draw(s, MM_TEXT, x, y, 0, 0, 0, text)

void mm_ellipse(mm_scene* s, int x, int y, int rx, int ry):
	int px = x + rx
	int py = y
	for i in range(1, 33):
		float angle = cast(float, i) * 6.2831853 / 32.0
		int nx = x + cast(int, fcos(angle) * cast(float, rx))
		int ny = y + cast(int, fsin(angle) * cast(float, ry))
		mm_line(s, px, py, nx, ny, 0)
		px = nx
		py = ny

# Endpoint marker oriented outward from the entity into the relationship.
void mm_marker(mm_scene* s, int x, int y, int dx, int dy, int card):
	int px = 0 - dy
	int py = dx
	if (card >= 2):
		mm_line(s, x + px * 7, y + py * 7, x + dx * 12, y + dy * 12, 0)
		mm_line(s, x - px * 7, y - py * 7, x + dx * 12, y + dy * 12, 0)
	else: mm_line(s, x + dx * 6 + px * 7, y + dy * 6 + py * 7, x + dx * 6 - px * 7, y + dy * 6 - py * 7, 0)
	int cx = x + dx * 20
	int cy = y + dy * 20
	if (card == 0 || card == 2): mm_draw(s, MM_CIRCLE, cx - 4, cy - 4, cx + 4, cy + 4, 0, c"")
	else: mm_line(s, cx + px * 7, cy + py * 7, cx - px * 7, cy - py * 7, 0)

char* mm_attribute_text(mm_attribute* a):
	string_builder* s = string_from(a.type_name)
	string_append(s, c"  ")
	string_append(s, a.name)
	if (a.keys[0] != 0):
		string_append(s, c"  ")
		string_append(s, a.keys)
	if (a.comment[0] != 0):
		string_append(s, c"  ")
		string_append(s, a.comment)
	char* result = s.data
	free(s)
	return result

char* mm_scope_direction(mm_document* d, int scope):
	while (scope >= 0):
		mm_node* n = d.nodes[scope]
		if (n.direction[0] != 0): return n.direction
		scope = n.parent
	return d.direction

void mm_measure(mm_document* d, mm_scene* s):
	for mm_node* n in d.nodes:
		mm_bounds* b = new mm_bounds()
		b.rank = -1
		b.w = strlen(n.label) * 8 + 40
		if (b.w < 180): b.w = 180
		b.h = 60
		if (n.shape == 2): b.h = b.w
		if (n.shape == 3):
			b.w = b.w * 2
			b.h = 100
		if (d.kind == MM_ER):
			b.h = 40 + n.attributes.length * 26
			for mm_attribute* a in n.attributes:
				char* text = mm_attribute_text(a)
				int width = strlen(text) * 8 + 32
				if (width > b.w): b.w = width
				free(text)
		if (d.kind == MM_CLASS && n.group == 0):
			b.h = 80 + n.members.length * 26
			if (n.annotation[0] != 0): b.h = b.h + 24
			int width = strlen(n.annotation) * 8 + 64
			if (width > b.w): b.w = width
			for mm_member* m in n.members:
				width = strlen(m.text) * 8 + 32
				if (width > b.w): b.w = width
		if (d.kind == MM_STATE && n.shape >= 3):
			b.w = 32
			b.h = 32
			if (n.shape == 3):
				b.w = 48
				b.h = 48
			if (n.shape == 6):
				b.w = 100
				b.h = 10
				char* dir = mm_scope_direction(d, n.parent)
				if (strcmp(dir, c"LR") == 0 || strcmp(dir, c"RL") == 0):
					b.w = 10
					b.h = 100
		s.nodes.push(b)

void mm_place(list[mm_bounds*] nodes, list[mm_edge*] edges, char* direction):
	# Longest-path ranks over a topological traversal. Break cycles at the
	# first remaining node, deterministically, without repeatedly growing ranks.
	list[int] incoming = new list[int]
	list[int] done = new list[int]
	for i in range(nodes.length):
		int count = 0
		for mm_edge* e in edges:
			if (e.to_node == i && e.from_node != i): count = count + 1
		incoming.push(count)
		done.push(0)
	int max_rank = 0
	for step in range(nodes.length):
		int index = -1
		for i in range(nodes.length):
			if (done[i] == 0 && incoming[i] == 0 && index < 0): index = i
		if (index < 0):
			for i in range(nodes.length):
				if (done[i] == 0 && index < 0): index = i
		done[index] = 1
		mm_bounds* from = nodes[index]
		if (from.rank < 0): from.rank = 0
		if (from.rank > max_rank): max_rank = from.rank
		for mm_edge* e in edges:
			if (e.from_node == index && done[e.to_node] == 0):
				mm_bounds* to = nodes[e.to_node]
				if (to.rank <= from.rank): to.rank = from.rank + 1
				incoming[e.to_node] = incoming[e.to_node] - 1
	__w_list_free(cast(__w_list*, incoming))
	__w_list_free(cast(__w_list*, done))
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
	for i in range(nodes.length):
		mm_bounds* b = nodes[i]
		int lane = 60
		for j in range(i):
			mm_bounds* other = nodes[j]
			if (other.rank == b.rank):
				if (horizontal): lane = lane + other.h + 100
				else: lane = lane + other.w + 100
		int rank = b.rank
		if (reverse): rank = max_rank - rank
		int offset = 60
		for j in range(rank): offset = offset + sizes[j] + 140
		if (horizontal):
			b.x = offset
			b.y = lane
		else:
			b.x = lane
			b.y = offset
	__w_list_free(cast(__w_list*, sizes))

# Return the direct child of scope containing index, or -1 outside this scope.
int mm_scope_child(mm_document* d, int index, int scope):
	while (index >= 0):
		mm_node* n = d.nodes[index]
		if (n.parent == scope): return index
		index = n.parent
	return -1

void mm_layout_scope(mm_document* d, mm_scene* s, int scope):
	list[int] indices = new list[int]
	list[mm_bounds*] nodes = new list[mm_bounds*]
	list[mm_edge*] edges = new list[mm_edge*]
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent == scope):
			if (n.group): mm_layout_scope(d, s, i)
			indices.push(i)
			nodes.push(s.nodes[i])
	for mm_edge* e in d.edges:
		int a = mm_scope_child(d, e.from_node, scope)
		int b = mm_scope_child(d, e.to_node, scope)
		if (a < 0 || b < 0 || a == b): continue
		mm_edge* mapped = new mm_edge()
		for i in range(indices.length):
			if (indices[i] == a): mapped.from_node = i
			if (indices[i] == b): mapped.to_node = i
		edges.push(mapped)
	mm_place(nodes, edges, mm_scope_direction(d, scope))
	if (scope >= 0):
		mm_bounds* box = s.nodes[scope]
		box.h = 100
		for mm_bounds* b in nodes:
			b.y = b.y + 24
			if (b.x + b.w + 60 > box.w): box.w = b.x + b.w + 60
			if (b.y + b.h + 60 > box.h): box.h = b.y + b.h + 60
	for mm_edge* e in edges: free(e)
	__w_list_free(cast(__w_list*, indices))
	__w_list_free(cast(__w_list*, nodes))
	__w_list_free(cast(__w_list*, edges))

void mm_layout_absolute(mm_document* d, mm_scene* s, int scope, int x, int y):
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != scope): continue
		mm_bounds* b = s.nodes[i]
		b.x = b.x + x
		b.y = b.y + y
		if (n.group): mm_layout_absolute(d, s, i, b.x, b.y)

void mm_layout(mm_document* d, mm_scene* s):
	mm_measure(d, s)
	mm_layout_scope(d, s, -1)
	mm_layout_absolute(d, s, -1, 0, 0)

# Convex, axis-aligned endpoint polygons, oriented away from their node.
void mm_uml_marker(mm_scene* s, int x, int y, int dx, int dy, int kind):
	if (kind == 0): return
	int px = 0 - dy
	int py = dx
	if (kind == MM_ARROW):
		mm_line(s, x, y, x + dx * 12 + px * 6, y + dy * 12 + py * 6, 0)
		mm_line(s, x, y, x + dx * 12 - px * 6, y + dy * 12 - py * 6, 0)
		return
	mm_draw(s, MM_POLYGON, x, y, x + dx * 24, y + dy * 24, kind == MM_COMPOSITION, c"")
	mm_primitive* p = s.items[s.items.length - 1]
	p.points = new list[int]
	p.points.push(x)
	p.points.push(y)
	int length = 12
	if (kind == MM_TRIANGLE): length = 18
	p.points.push(x + dx * length + px * 9)
	p.points.push(y + dy * length + py * 9)
	if (kind != MM_TRIANGLE):
		p.points.push(x + dx * 24)
		p.points.push(y + dy * 24)
	p.points.push(x + dx * length - px * 9)
	p.points.push(y + dy * length - py * 9)


void mm_render_edge(mm_document* d, mm_scene* s, mm_edge* e):
	mm_bounds* a = s.nodes[e.from_node]
	mm_bounds* b = s.nodes[e.to_node]
	char* direction = d.direction
	if (d.kind == MM_CLASS || d.kind == MM_STATE): direction = mm_scope_direction(d, e.scope)
	int horizontal = strcmp(direction, c"LR") == 0 || strcmp(direction, c"RL") == 0
	int dx = 0
	int dy = 1
	int ax = a.x + a.w / 2
	int ay = a.y + a.h
	int bx = b.x + b.w / 2
	int by = b.y
	if (horizontal):
		dx = 1
		dy = 0
		ax = a.x + a.w
		ay = a.y + a.h / 2
		bx = b.x
		by = b.y + b.h / 2
		if (b.x < a.x):
			dx = -1
			ax = a.x
			bx = b.x + b.w
	else if (b.y < a.y):
		dy = -1
		ay = a.y
		by = b.y + b.h
	# Separate attachment points for several relationships to one entity.
	# Small flow shapes retain their center ports.
	if (d.kind == MM_ER && e.from_node != e.to_node):
		int out_count = 0
		int in_count = 0
		int out_index = 0
		int in_index = 0
		int seen = 0
		for mm_edge* other in d.edges:
			if (other == e): seen = 1
			if (other.from_node == e.from_node):
				out_count = out_count + 1
				if (seen == 0): out_index = out_index + 1
			if (other.to_node == e.to_node):
				in_count = in_count + 1
				if (seen == 0): in_index = in_index + 1
		if (horizontal):
			ay = a.y + a.h * (out_index + 1) / (out_count + 1)
			by = b.y + b.h * (in_index + 1) / (in_count + 1)
		else:
			ax = a.x + a.w * (out_index + 1) / (out_count + 1)
			bx = b.x + b.w * (in_index + 1) / (in_count + 1)
	int mx = (ax + bx) / 2
	int my = (ay + by) / 2
	if (horizontal): mx = bx - dx * 45
	else: my = by - dy * 45
	if (e.from_node == e.to_node):
		ax = a.x + a.w
		ay = a.y + a.h / 3
		bx = ax
		by = a.y + a.h * 2 / 3
		dx = 1
		dy = 0
		mx = ax + 55
		my = ay
		horizontal = 1
	if (horizontal):
		mm_line(s, ax, ay, mx, ay, e.dashed)
		mm_line(s, mx, ay, mx, by, e.dashed)
		mm_line(s, mx, by, bx, by, e.dashed)
	else:
		mm_line(s, ax, ay, ax, my, e.dashed)
		mm_line(s, ax, my, bx, my, e.dashed)
		mm_line(s, bx, my, bx, by, e.dashed)
	if (d.kind == MM_ER):
		mm_marker(s, ax, ay, dx, dy, e.left_card)
		if (e.from_node == e.to_node): mm_marker(s, bx, by, dx, dy, e.right_card)
		else: mm_marker(s, bx, by, 0 - dx, 0 - dy, e.right_card)
	else if (d.kind == MM_CLASS):
		mm_uml_marker(s, ax, ay, dx, dy, e.left_marker)
		int end_dx = 0 - dx
		int end_dy = 0 - dy
		if (e.from_node == e.to_node): end_dx = dx
		mm_uml_marker(s, bx, by, end_dx, end_dy, e.right_marker)
		if (e.left_label[0] != 0): mm_text(s, ax + dx * 30 + 8, ay + dy * 30 + 8, e.left_label)
		if (e.right_label[0] != 0): mm_text(s, bx + end_dx * 30 + 8, by + end_dy * 30 + 8, e.right_label)
	else if (e.arrow):
		int end_dx = 0 - dx
		int end_dy = 0 - dy
		if (e.from_node == e.to_node): end_dx = dx
		mm_line(s, bx, by, bx + end_dx * 10 - end_dy * 5, by + end_dy * 10 + end_dx * 5, 0)
		mm_line(s, bx, by, bx + end_dx * 10 + end_dy * 5, by + end_dy * 10 - end_dx * 5, 0)
	if (e.label[0] != 0):
		if (e.from_node == e.to_node): mm_text(s, mx + 8, my - 22, e.label)
		else if (horizontal): mm_text(s, (ax + mx) / 2 - strlen(e.label) * 4, ay - 22, e.label)
		else: mm_text(s, bx + 8, (my + by) / 2 - 8, e.label)

void mm_render_groups(mm_document* d, mm_scene* s, int scope):
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.group == 0 || n.parent != scope): continue
		mm_bounds* b = s.nodes[i]
		mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, d.kind == MM_STATE, c"")
		mm_text(s, b.x + 16, b.y + 12, n.label)
		mm_line(s, b.x, b.y + 40, b.x + b.w, b.y + 40, 0)
		mm_render_groups(d, s, i)

void mm_render_class(mm_scene* s, mm_node* n, mm_bounds* b):
	int y = b.y + 40
	if (n.annotation[0] != 0):
		string_builder* text = string_from(c"<<")
		string_append(text, n.annotation)
		string_append(text, c">>")
		mm_text(s, b.x + 16, y, text.data)
		string_free(text)
		y = y + 24
	mm_line(s, b.x, y, b.x + b.w, y, 0)
	for method in range(2):
		int count = 0
		for mm_member* m in n.members:
			if (m.method == method):
				mm_text(s, b.x + 12, y + 5, m.text)
				y = y + 26
				count = count + 1
		if (count == 0): y = y + 18
		if (method == 0): mm_line(s, b.x, y, b.x + b.w, y, 0)

# Failed parses cannot produce a misleading partial preview.
mm_scene* mm_render(mm_document* d):
	if (d.error != 0): return 0
	mm_scene* s = new mm_scene()
	s.items = new list[mm_primitive*]
	s.nodes = new list[mm_bounds*]
	s.width = 240
	s.height = 160
	mm_layout(d, s)
	mm_render_groups(d, s, -1)
	for mm_edge* e in d.edges: mm_render_edge(d, s, e)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		if (n.group): continue
		if (d.kind == MM_STATE && n.shape >= 4):
			if (n.shape == 6): mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, 2, c"")
			else:
				mm_draw(s, MM_CIRCLE, b.x, b.y, b.x + b.w, b.y + b.h, n.shape == 4, c"")
				if (n.shape == 5): mm_draw(s, MM_CIRCLE, b.x + 7, b.y + 7, b.x + b.w - 7, b.y + b.h - 7, 1, c"")
			continue
		if (n.shape == 3):
			mm_line(s, b.x + b.w / 2, b.y, b.x + b.w, b.y + b.h / 2, 0)
			mm_line(s, b.x + b.w, b.y + b.h / 2, b.x + b.w / 2, b.y + b.h, 0)
			mm_line(s, b.x + b.w / 2, b.y + b.h, b.x, b.y + b.h / 2, 0)
			mm_line(s, b.x, b.y + b.h / 2, b.x + b.w / 2, b.y, 0)
		else if (n.shape == 2): mm_ellipse(s, b.x + b.w / 2, b.y + b.h / 2, b.w / 2, b.h / 2)
		else: mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, n.shape == 1, c"")
		int title_y = b.y + (b.h - 16) / 2
		if (d.kind == MM_ER || d.kind == MM_CLASS): title_y = b.y + 12
		if (d.kind != MM_STATE || n.shape != 3): mm_text(s, b.x + (b.w - strlen(n.label) * 8) / 2, title_y, n.label)
		if (d.kind == MM_CLASS): mm_render_class(s, n, b)
		if (d.kind == MM_ER):
			for j in range(n.attributes.length):
				int y = b.y + 40 + j * 26
				mm_line(s, b.x, y, b.x + b.w, y, 0)
				char* text = mm_attribute_text(n.attributes[j])
				mm_text(s, b.x + 12, y + 5, text)
				free(text)
	return s

void mm_scene_free(mm_scene* s):
	if (s == 0): return
	for mm_primitive* p in s.items:
		if (p.points != 0): __w_list_free(cast(__w_list*, p.points))
		free(p.text)
		free(p)
	for mm_bounds* b in s.nodes: free(b)
	__w_list_free(cast(__w_list*, s.items))
	__w_list_free(cast(__w_list*, s.nodes))
	free(s)

void mm_xml(string_builder* out, char* text):
	int i = 0
	while (text[i] != 0):
		int c = text[i]
		if (c == '&'): string_append(out, c"&amp;")
		else if (c == '<'): string_append(out, c"&lt;")
		else if (c == '>'): string_append(out, c"&gt;")
		else if (c == '"'): string_append(out, c"&quot;")
		else: string_append_char(out, c)
		i = i + 1

void mm_svg_number(string_builder* out, char* name, int value):
	string_append_char(out, ' ')
	string_append(out, name)
	string_append(out, c"=\"")
	string_append_int(out, value)
	string_append_char(out, '"')

char* mm_svg(mm_scene* scene):
	if (scene == 0): return 0
	string_builder* out = string_from(c"<svg xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" viewBox=\"0 0 ")
	string_append_int(out, scene.width)
	string_append_char(out, ' ')
	string_append_int(out, scene.height)
	string_append(out, c"\"><title>Mermaid diagram</title>\n<g stroke=\"#334155\" stroke-width=\"2\" fill=\"none\">\n")
	for mm_primitive* p in scene.items:
		if (p.kind == MM_LINE):
			string_append(out, c"<line")
			mm_svg_number(out, c"x1", p.x)
			mm_svg_number(out, c"y1", p.y)
			mm_svg_number(out, c"x2", p.x2)
			mm_svg_number(out, c"y2", p.y2)
			if (p.dashed): string_append(out, c" stroke-dasharray=\"6 4\"")
			string_append(out, c"/>\n")
		else if (p.kind == MM_BOX):
			if (p.dashed == 2): string_append(out, c"<rect fill=\"#334155\"")
			else: string_append(out, c"<rect fill=\"#f8fafc\"")
			mm_svg_number(out, c"x", p.x)
			mm_svg_number(out, c"y", p.y)
			mm_svg_number(out, c"width", p.x2 - p.x)
			mm_svg_number(out, c"height", p.y2 - p.y)
			if (p.dashed == 1): mm_svg_number(out, c"rx", 12)
			string_append(out, c"/>\n")
		else if (p.kind == MM_CIRCLE):
			if (p.dashed): string_append(out, c"<circle fill=\"#334155\"")
			else: string_append(out, c"<circle fill=\"white\"")
			mm_svg_number(out, c"cx", (p.x + p.x2) / 2)
			mm_svg_number(out, c"cy", (p.y + p.y2) / 2)
			mm_svg_number(out, c"r", (p.x2 - p.x) / 2)
			string_append(out, c"/>\n")
		else if (p.kind == MM_POLYGON):
			if (p.dashed): string_append(out, c"<polygon fill=\"#334155\" points=\"")
			else: string_append(out, c"<polygon fill=\"white\" points=\"")
			for i in range(p.points.length):
				string_append_int(out, p.points[i])
				if (i % 2 == 0): string_append_char(out, ',')
				else: string_append_char(out, ' ')
			string_append(out, c"\"/>\n")
		else:
			string_append(out, c"<text stroke=\"none\" fill=\"#0f172a\" font-family=\"monospace\" font-size=\"13\"")
			mm_svg_number(out, c"x", p.x)
			mm_svg_number(out, c"y", p.y + 13)
			string_append_char(out, '>')
			mm_xml(out, p.text)
			string_append(out, c"</text>\n")
	string_append(out, c"</g></svg>\n")
	char* result = out.data
	free(out)
	return result
