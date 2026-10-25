# Native C4 layout and cards, following the upstream renderer's model: the
# shapes of each boundary fill rows of c4ShapeInRow (default 4) in statement
# order, nested boundaries follow in rows of c4BoundaryInRow (default 2), and
# relations are straight border-to-border lines labelled at their midpoint.
# Cards use the fixed upstream C4 palette; UpdateElementStyle/UpdateRelStyle
# override it per element or relation.
import libs.extras.mermaid.text
import libs.extras.mermaid.style_render
import libs.extras.mermaid.framework_render
import libs.extras.mermaid.c4

const int MM_C4_WIDTH = 240
const int MM_C4_WRAP = 216
const int MM_C4_MARGIN = 50
const int MM_C4_PAD = 20
const int MM_C4_INK = 0x444444

# 0 person, 1 system, 2 container, 3 component; external adds 4.
int mm_c4_family(char* annotation):
	int family = 1
	if (index_of(annotation, c"Person") == 0): family = 0
	else if (index_of(annotation, c"Container") == 0): family = 2
	else if (index_of(annotation, c"Component") == 0): family = 3
	if (index_of(annotation, c"_Ext") >= 0): family = family + 4
	return family

int mm_c4_fill(int family):
	list[int] fills = list[int]{0x08427b, 0x1168bd, 0x438dd5, 0x85bbf0, 0x686868, 0x999999, 0xb3b3b3, 0xcccccc}
	int value = fills[family]
	__w_list_free(cast(__w_list*, fills))
	return value

int mm_c4_border(int family):
	list[int] borders = list[int]{0x073b6f, 0x3c7fc0, 0x3c7fc0, 0x78a8d8, 0x8a8a8a, 0x8a8a8a, 0xa6a6a6, 0xbfbfbf}
	int value = borders[family]
	__w_list_free(cast(__w_list*, borders))
	return value

int mm_c4_font(int family):
	if (family == 3 || family == 7): return 0
	return 0xffffff

# Upstream type stereotype, e.g. ContainerDb_Ext -> <<external_container_db>>.
char* mm_c4_type_text(char* annotation):
	string_builder* out = string_from(c"<<")
	if (index_of(annotation, c"_Ext") >= 0): string_append(out, c"external_")
	int i = 0
	while (annotation[i] != 0 && annotation[i] != '_'):
		int c = annotation[i]
		if (c >= 'A' && c <= 'Z'):
			if (i > 0): string_append_char(out, '_')
			c = c + 32
		string_append_char(out, c)
		i = i + 1
	string_append(out, c">>")
	char* result = strclone(out.data)
	string_free(out)
	return result

# Bold label as a Markdown string when that cannot change its meaning.
mm_text_block* mm_c4_title(char* label, int wrap):
	if (mm_text_is_markdown(label) || index_of(label, c"*") >= 0 || index_of(label, c"_") >= 0 || index_of(label, c"`") >= 0): return mm_text_layout(label, wrap)
	string_builder* text = string_from(c"`**")
	string_append(text, label)
	string_append(text, c"**`")
	mm_text_block* block = mm_text_layout(text.data, wrap)
	string_free(text)
	return block

char* mm_c4_bracketed(char* value):
	string_builder* text = string_from(c"[")
	string_append(text, value)
	string_append_char(text, ']')
	char* result = strclone(text.data)
	string_free(text)
	return result

# Card height for its stacked type, icon, name, technology and description.
int mm_c4_card_height(mm_node* n):
	int h = 10 + MM_TEXT_PITCH
	if (index_of(n.annotation, c"Person") == 0): h = h + 52
	if (index_of(n.annotation, c"Db") >= 0): h = h + 10
	mm_text_block* title = mm_c4_title(n.label, MM_C4_WRAP)
	h = h + title.height + 6
	mm_text_block_free(title)
	char* technology = mm_c4_get(n, c"techn")
	if (technology != 0 && technology[0] != 0): h = h + MM_TEXT_PITCH
	char* description = mm_c4_get(n, c"descr")
	if (description != 0 && description[0] != 0):
		mm_text_block* block = mm_text_layout(description, MM_C4_WRAP)
		h = h + block.height + 4
		mm_text_block_free(block)
	h = h + 10
	if (h < 70): h = 70
	return h

char* mm_c4_boundary_type(mm_node* n):
	char* type = mm_c4_get(n, c"type")
	if (type != 0 && type[0] != 0): return strclone(type)
	if (strcmp(n.annotation, c"Enterprise_Boundary") == 0): return strclone(c"enterprise")
	if (strcmp(n.annotation, c"System_Boundary") == 0): return strclone(c"system")
	if (strcmp(n.annotation, c"Container_Boundary") == 0): return strclone(c"container")
	if (strcmp(n.annotation, c"Boundary") == 0): return strclone(c"boundary")
	return strclone(c"")

# Boundary header: bold title, then the bracketed type (upstream `[system]`).
mm_text_block* mm_c4_type_block(mm_node* n):
	char* type = mm_c4_boundary_type(n)
	char* text = strclone(c"")
	if (type[0] != 0):
		free(text)
		text = mm_c4_bracketed(type)
	mm_text_block* block = mm_text_layout(text, 0)
	free(text)
	free(type)
	return block

int mm_c4_header(mm_node* n, int* width):
	mm_text_block* title = mm_c4_title(n.label, 0)
	mm_text_block* type = mm_c4_type_block(n)
	int h = 10 + title.height + 4 + type.height + 10
	*width = title.width
	if (type.width > *width): *width = type.width
	mm_text_block_free(title)
	mm_text_block_free(type)
	return h

# Places the shapes, then the nested boundaries, of scope from (x, y).
# Returns the content height; *width receives the content width.
int mm_c4_place(mm_document* d, mm_scene* s, int scope, int x, int y, int* width):
	int shapes = 4
	if (d.c4_shape_in_row > 0): shapes = d.c4_shape_in_row
	int boundaries = 2
	if (d.c4_boundary_in_row > 0): boundaries = d.c4_boundary_in_row
	int max_w = 0
	int top = y
	int bottom = y
	for phase in range(2):
		int cx = x
		int cy = bottom
		if (bottom > top): cy = bottom + MM_C4_MARGIN
		int row_h = 0
		int column = 0
		int limit = shapes
		if (phase == 1): limit = boundaries
		for i in range(d.nodes.length):
			mm_node* n = d.nodes[i]
			if (n.parent != scope || n.group != phase): continue
			mm_bounds* b = s.nodes[i]
			if (column == limit):
				cy = cy + row_h + MM_C4_MARGIN
				cx = x
				row_h = 0
				column = 0
			b.x = cx
			b.y = cy
			if (phase == 1):
				int header_w = 0
				int header = mm_c4_header(n, &header_w)
				int inner_w = 0
				int inner_h = mm_c4_place(d, s, i, cx + MM_C4_PAD, cy + header, &inner_w)
				b.w = inner_w + MM_C4_PAD * 2
				if (header_w + 24 > b.w): b.w = header_w + 24
				if (b.w < 200): b.w = 200
				b.h = header + inner_h + MM_C4_PAD
			cx = cx + b.w + MM_C4_MARGIN
			if (b.h > row_h): row_h = b.h
			if (cx - MM_C4_MARGIN - x > max_w): max_w = cx - MM_C4_MARGIN - x
			column = column + 1
			if (cy + row_h > bottom): bottom = cy + row_h
	*width = max_w
	return bottom - top

void mm_c4_arc(list[int] points, int cx, int cy, int rx, int ry, int from, int to):
	for i in range(from, to + 1):
		float angle = cast(float, i) * 3.14159265 / 12.0
		points.push(cx + cast(int, fcos(angle) * cast(float, rx)))
		points.push(cy + cast(int, fsin(angle) * cast(float, ry)))

void mm_c4_paint(mm_scene* s, int start, int fill, int stroke, int text):
	for i in range(start, s.items.length):
		mm_primitive* p = s.items[i]
		if (p.kind == MM_TEXT):
			p.style.text = text
			p.style.mask = p.style.mask | MM_STYLE_TEXT
		else:
			p.style.fill = fill
			p.style.stroke = stroke
			p.style.mask = p.style.mask | MM_STYLE_FILL | MM_STYLE_STROKE

void mm_c4_card(mm_document* d, mm_scene* s, mm_node* n, mm_bounds* b):
	int start = s.items.length
	int family = mm_c4_family(n.annotation)
	int fill = mm_c4_fill(family)
	int border = mm_c4_border(family)
	int db = index_of(n.annotation, c"Db") >= 0
	int queue = index_of(n.annotation, c"Queue") >= 0
	if (db || queue):
		mm_draw(s, MM_POLYGON, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
		mm_primitive* body = s.items[s.items.length - 1]
		body.points = new list[int]
		list[int] rim = new list[int]
		if (db):
			mm_c4_arc(body.points, b.x + b.w / 2, b.y + 10, b.w / 2, 10, 12, 24)
			mm_c4_arc(body.points, b.x + b.w / 2, b.y + b.h - 10, b.w / 2, 10, 0, 12)
			mm_c4_arc(rim, b.x + b.w / 2, b.y + 10, b.w / 2, 10, 0, 12)
		else:
			mm_c4_arc(body.points, b.x + b.w - 10, b.y + b.h / 2, 10, b.h / 2, -6, 6)
			mm_c4_arc(body.points, b.x + 10, b.y + b.h / 2, 10, b.h / 2, 6, 18)
			mm_c4_arc(rim, b.x + b.w - 10, b.y + b.h / 2, 10, b.h / 2, 6, 18)
		for i in range(1, rim.length / 2): mm_line(s, rim[i * 2 - 2], rim[i * 2 - 1], rim[i * 2], rim[i * 2 + 1], 0)
		__w_list_free(cast(__w_list*, rim))
	else: mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
	mm_c4_paint(s, start, fill, border, border)
	int cx = b.x + b.w / 2
	int y = b.y + 10
	if (db): y = y + 10
	int text_start = s.items.length
	char* type = mm_c4_type_text(n.annotation)
	mm_label(s, cx, y, type, 0, 1)
	free(type)
	y = y + MM_TEXT_PITCH
	if (family % 4 == 0):
		int icon_start = s.items.length
		mm_draw(s, MM_CIRCLE, cx - 13, y + 2, cx + 13, y + 28, 0, c"")
		mm_draw(s, MM_POLYGON, cx - 24, y + 28, cx + 24, y + 50, 0, c"")
		mm_primitive* shoulders = s.items[s.items.length - 1]
		shoulders.points = new list[int]
		mm_c4_arc(shoulders.points, cx, y + 50, 24, 20, 12, 24)
		mm_c4_paint(s, icon_start, 0xffffff, border, border)
		y = y + 52
	mm_text_block* title = mm_c4_title(n.label, MM_C4_WRAP)
	mm_text_draw(s, title, cx, y, 1)
	y = y + title.height + 6
	mm_text_block_free(title)
	char* technology = mm_c4_get(n, c"techn")
	if (technology != 0 && technology[0] != 0):
		char* text = mm_c4_bracketed(technology)
		mm_label(s, cx, y, text, 0, 1)
		free(text)
		y = y + MM_TEXT_PITCH
	char* description = mm_c4_get(n, c"descr")
	if (description != 0 && description[0] != 0): mm_label(s, cx, y, description, MM_C4_WRAP, 1)
	int font = mm_c4_font(family)
	for i in range(text_start, s.items.length):
		mm_primitive* p = s.items[i]
		if (p.kind == MM_TEXT):
			p.style.text = font
			p.style.mask = p.style.mask | MM_STYLE_TEXT
	mm_style_node(d, s, n, start)

void mm_c4_boundary(mm_document* d, mm_scene* s, mm_node* n, mm_bounds* b):
	int start = s.items.length
	int deployment = mm_in_words(n.annotation, c"|Deployment_Node|Node|Node_L|Node_R|")
	mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, deployment, c"")
	mm_primitive* box = s.items[s.items.length - 1]
	box.style.fill = -1
	box.style.stroke = MM_C4_INK
	box.style.mask = MM_STYLE_FILL | MM_STYLE_STROKE
	if (deployment == 0):
		box.style.stroke = -1
		mm_line(s, b.x, b.y, b.x + b.w, b.y, 1)
		mm_line(s, b.x + b.w, b.y, b.x + b.w, b.y + b.h, 1)
		mm_line(s, b.x + b.w, b.y + b.h, b.x, b.y + b.h, 1)
		mm_line(s, b.x, b.y + b.h, b.x, b.y, 1)
		for i in range(start + 1, s.items.length):
			mm_primitive* line = s.items[i]
			line.style.stroke = MM_C4_INK
			line.style.mask = MM_STYLE_STROKE
	int right = strcmp(n.annotation, c"Node_R") == 0
	mm_text_block* title = mm_c4_title(n.label, 0)
	int left = b.x + 12
	if (right): left = b.x + b.w - 12 - title.width
	mm_text_draw(s, title, left, b.y + 10, 0)
	int y = b.y + 10 + title.height + 4
	mm_text_block_free(title)
	mm_text_block* type = mm_c4_type_block(n)
	left = b.x + 12
	if (right): left = b.x + b.w - 12 - type.width
	mm_text_draw(s, type, left, y, 0)
	mm_text_block_free(type)
	for i in range(start, s.items.length):
		mm_primitive* p = s.items[i]
		if (p.kind == MM_TEXT):
			p.style.text = MM_C4_INK
			p.style.mask = p.style.mask | MM_STYLE_TEXT
	mm_style_node(d, s, n, start)

# Border point of b on the segment from its centre towards (tx, ty).
void mm_c4_clip(mm_bounds* b, int tx, int ty, int* x, int* y):
	int cx = b.x + b.w / 2
	int cy = b.y + b.h / 2
	float dx = cast(float, tx - cx)
	float dy = cast(float, ty - cy)
	if (dx == 0.0 && dy == 0.0):
		*x = cx
		*y = cy
		return
	float sx = 1000000.0
	float sy = 1000000.0
	if (dx != 0.0): sx = cast(float, b.w / 2) / fabs(dx)
	if (dy != 0.0): sy = cast(float, b.h / 2) / fabs(dy)
	float scale = sx
	if (sy < scale): scale = sy
	*x = cx + cast(int, dx * scale)
	*y = cy + cast(int, dy * scale)

void mm_c4_port(mm_bounds* b, int port, int* x, int* y):
	*x = b.x + b.w / 2
	*y = b.y + b.h / 2
	if (port == 1): *x = b.x
	if (port == 2): *x = b.x + b.w
	if (port == 3): *y = b.y
	if (port == 4): *y = b.y + b.h

void mm_c4_head(mm_scene* s, int ax, int ay, int bx, int by):
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

void mm_c4_relation_draw(mm_document* d, mm_scene* s, mm_edge* e):
	int start = s.items.length
	mm_bounds* a = s.nodes[e.from_node]
	mm_bounds* b = s.nodes[e.to_node]
	int ax = 0
	int ay = 0
	int bx = 0
	int by = 0
	int mx = 0
	int my = 0
	if (e.from_node == e.to_node):
		ax = a.x + a.w
		ay = a.y + a.h / 3
		bx = ax
		by = a.y + a.h * 2 / 3
		mm_line(s, ax, ay, ax + 40, ay, 0)
		mm_line(s, ax + 40, ay, ax + 40, by, 0)
		mm_line(s, ax + 40, by, bx, by, 0)
		mm_c4_head(s, ax + 40, by, bx, by)
		mx = ax + 48
		my = (ay + by) / 2
	else:
		if (e.from_port != 0):
			mm_c4_port(a, e.from_port, &ax, &ay)
			mm_c4_port(b, e.to_port, &bx, &by)
		else:
			mm_c4_clip(a, b.x + b.w / 2, b.y + b.h / 2, &ax, &ay)
			mm_c4_clip(b, a.x + a.w / 2, a.y + a.h / 2, &bx, &by)
		mm_line(s, ax, ay, bx, by, 0)
		mm_c4_head(s, ax, ay, bx, by)
		if (e.left_marker): mm_c4_head(s, bx, by, ax, ay)
		mx = (ax + bx) / 2
		my = (ay + by) / 2
	mm_text_block* t = mm_text_layout(e.label, MM_TEXT_WRAP)
	mm_text_draw(s, t, mx + e.label_dx, my + e.label_dy - t.height / 2, 1)
	mm_text_block_free(t)
	for i in range(start, s.items.length):
		mm_primitive* p = s.items[i]
		p.style.stroke = MM_C4_INK
		p.style.text = MM_C4_INK
		p.style.mask = p.style.mask | MM_STYLE_STROKE | MM_STYLE_TEXT
	mm_style_edge(d, s, e, start)

mm_scene* mm_c4_render(mm_document* d):
	mm_scene* s = new mm_scene()
	s.items = new list[mm_primitive*]
	s.nodes = new list[mm_bounds*]
	s.width = 240
	s.height = 160
	for mm_node* n in d.nodes:
		mm_bounds* b = new mm_bounds()
		b.rank = -1
		if (n.group == 0):
			b.w = MM_C4_WIDTH
			mm_text_block* title = mm_c4_title(n.label, MM_C4_WRAP)
			if (title.width + 24 > b.w): b.w = title.width + 24
			mm_text_block_free(title)
			b.h = mm_c4_card_height(n)
		s.nodes.push(b)
	int width = 0
	mm_c4_place(d, s, -1, 40, 40, &width)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.group): mm_c4_boundary(d, s, n, s.nodes[i])
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.group == 0): mm_c4_card(d, s, n, s.nodes[i])
	for mm_edge* e in d.edges: mm_c4_relation_draw(d, s, e)
	return s
