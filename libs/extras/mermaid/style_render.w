import libs.extras.mermaid.style
import libs.extras.mermaid.scene

# Primitive roles select which resolved theme variables paint them.
const int MM_ROLE_NONE = 0
const int MM_ROLE_NODE = 1
const int MM_ROLE_CLUSTER = 2
const int MM_ROLE_EDGE = 3
const int MM_ROLE_TITLE = 4
const int MM_ROLE_SERIES = 5
const int MM_ROLE_LABEL_BOX = 6

void mm_style_node(mm_document* d, mm_scene* scene, mm_node* node, int start):
	mm_style resolved
	resolved.mask = 0
	resolved.fill = 0
	resolved.stroke = 0
	resolved.text = 0
	resolved.width = 0
	mm_style_class* definition = mm_style_find(d, c"default")
	if (definition != 0): mm_style_merge(&resolved, &definition.style)
	int begin = 0
	int length = strlen(node.style_classes)
	if (length != 0):
		for i in range(length + 1):
			if (i == length || node.style_classes[i] == ','):
				char* name = mm_style_trim(node.style_classes, begin, i)
				definition = mm_style_find(d, name)
				if (definition != 0): mm_style_merge(&resolved, &definition.style)
				free(name)
				begin = i + 1
	mm_style_merge(&resolved, &node.style)
	int role = MM_ROLE_NODE
	if (node.group): role = MM_ROLE_CLUSTER
	for i in range(start, scene.items.length):
		mm_primitive* primitive = scene.items[i]
		primitive.node_style = 1
		primitive.role = role
		mm_style_merge(&primitive.style, &resolved)

# Relationship primitives: linkStyle default, then the edge's own style.
void mm_style_edge(mm_document* d, mm_scene* scene, mm_edge* e, int start):
	for i in range(start, scene.items.length):
		mm_primitive* primitive = scene.items[i]
		primitive.role = MM_ROLE_EDGE
		mm_style_merge(&primitive.style, &d.edge_style)
		mm_style_merge(&primitive.style, &e.style)

# Cubic Bezier from (x0,y0) to (x3,y3), sampled into fixed straight segments.
void mm_style_bezier(mm_scene* s, int x0, int y0, int x1, int y1, int x2, int y2, int x3, int y3, int dashed):
	int px = x0
	int py = y0
	for i in range(1, 13):
		float t = cast(float, i) / 12.0
		float u = 1.0 - t
		float a = u * u * u
		float b = 3.0 * u * u * t
		float c = 3.0 * u * t * t
		float e = t * t * t
		int nx = cast(int, a * cast(float, x0) + b * cast(float, x1) + c * cast(float, x2) + e * cast(float, x3))
		int ny = cast(int, a * cast(float, y0) + b * cast(float, y1) + c * cast(float, y2) + e * cast(float, y3))
		if (i == 12):
			nx = x3
			ny = y3
		mm_line(s, px, py, nx, ny, dashed)
		px = nx
		py = ny

# Relationship route from port (ax,ay) to port (bx,by) through the bend at
# mx (horizontal) or my (vertical). flowchart.curve selects step (orthogonal,
# the default), linear or basis; every route ends with an axis-aligned leg so
# arrowheads and endpoint markers keep their orientation. Loops stay orthogonal.
void mm_style_edge_path(mm_document* d, mm_scene* s, int ax, int ay, int mx, int my, int bx, int by, int horizontal, int dashed, int loop):
	int curve = 0
	if (d.kind == MM_FLOW && loop == 0): curve = d.edge_curve
	if (horizontal):
		if (curve == 1): mm_line(s, ax, ay, mx, by, dashed)
		else if (curve == 2): mm_style_bezier(s, ax, ay, (ax + mx) / 2, ay, (ax + mx) / 2, by, mx, by, dashed)
		else:
			mm_line(s, ax, ay, mx, ay, dashed)
			mm_line(s, mx, ay, mx, by, dashed)
		mm_line(s, mx, by, bx, by, dashed)
	else:
		if (curve == 1): mm_line(s, ax, ay, bx, my, dashed)
		else if (curve == 2): mm_style_bezier(s, ax, ay, ax, (ay + my) / 2, bx, (ay + my) / 2, bx, my, dashed)
		else:
			mm_line(s, ax, ay, ax, my, dashed)
			mm_line(s, ax, my, bx, my, dashed)
		mm_line(s, bx, my, bx, by, dashed)

void mm_style_scene(mm_document* d, mm_scene* scene):
	if (d.theme == 0 || d.theme_values == 0): return
	list[int] values = d.theme_values
	scene.has_background = 1
	scene.background = d.background
	for mm_primitive* primitive in scene.items:
		mm_style resolved = d.palette
		if (primitive.role == MM_ROLE_CLUSTER):
			resolved.fill = values[MM_THEME_CLUSTER_BKG]
			resolved.stroke = values[MM_THEME_CLUSTER_BORDER]
			resolved.text = values[MM_THEME_TITLE]
		else if (primitive.node_style == 0):
			resolved.stroke = d.palette_line
			resolved.text = d.palette_label
			if (primitive.role == MM_ROLE_TITLE): resolved.text = values[MM_THEME_TITLE]
		mm_style_merge(&resolved, &primitive.style)
		if (primitive.role == MM_ROLE_SERIES):
			int base = MM_THEME_SCALE
			if (d.kind == MM_PIE): base = MM_THEME_PIE
			resolved.fill = values[base + primitive.series % 12]
			resolved.stroke = resolved.fill
		primitive.style = resolved
	int background = values[MM_THEME_EDGE_LABEL_BKG]
	if (background < 0): return
	# Edge labels sit on an edgeLabelBackground box drawn just beneath them.
	list[mm_primitive*] items = new list[mm_primitive*]
	for mm_primitive* primitive in scene.items:
		if (primitive.role == MM_ROLE_EDGE && primitive.kind == MM_TEXT && primitive.text[0] != 0):
			mm_primitive* box = new mm_primitive()
			box.kind = MM_BOX
			box.x = primitive.x - 3
			box.y = primitive.y - 1
			box.x2 = primitive.x + strlen(primitive.text) * 8 + 3
			box.y2 = primitive.y + 17
			box.text = strclone(c"")
			box.role = MM_ROLE_LABEL_BOX
			box.style.mask = 15
			box.style.fill = background
			box.style.stroke = -1
			box.style.width = 1
			items.push(box)
		items.push(primitive)
	__w_list_free(cast(__w_list*, scene.items))
	scene.items = items
