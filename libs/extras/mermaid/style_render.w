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
# Family roles painted from the matching theme variables; renderers keep
# their own colors without a configured theme.
const int MM_ROLE_NOTE = 7
const int MM_ROLE_ACTOR = 8
const int MM_ROLE_SIGNAL = 9
const int MM_ROLE_ACTOR_LINE = 10
const int MM_ROLE_TASK = 11
const int MM_ROLE_TASK_ACTIVE = 12
const int MM_ROLE_TASK_DONE = 13
const int MM_ROLE_TASK_CRIT = 14
const int MM_ROLE_GRID = 15
const int MM_ROLE_TODAY = 16
const int MM_ROLE_SECTION = 17
const int MM_ROLE_EXCLUDE = 18
# ER attribute rows: series parity selects the odd/even background.
const int MM_ROLE_ROW = 19
# Categorical roles: series index selects git0..git7 / venn1..venn8.
const int MM_ROLE_GIT = 20
const int MM_ROLE_VENN = 21
# A series fill lightened by the primitive's tint (treemap depth palettes).
const int MM_ROLE_TINT = 22

# Tag primitives drawn from start onward with a theme role.
void mm_style_role(mm_scene* scene, int start, int role, int series):
	for i in range(start, scene.items.length):
		mm_primitive* primitive = scene.items[i]
		primitive.role = role
		primitive.series = series

void mm_style_node(mm_document* d, mm_scene* scene, mm_node* node, int start):
	mm_style resolved = mm_style_resolve(d, node)
	int role = MM_ROLE_NODE
	if (node.group): role = MM_ROLE_CLUSTER
	for i in range(start, scene.items.length):
		mm_primitive* primitive = scene.items[i]
		primitive.node_style = 1
		primitive.user_mask = primitive.user_mask | resolved.mask
		if (primitive.role == MM_ROLE_NONE): primitive.role = role
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
# Per-edge curve forced by the renderer (agentflow `curve`; -1: none), in
# flowchart.curve values.
int mm_style_curve_override = -1

void mm_style_edge_path(mm_document* d, mm_scene* s, int ax, int ay, int mx, int my, int bx, int by, int horizontal, int dashed, int loop):
	int curve = 0
	if (d.kind == MM_FLOW && loop == 0): curve = d.edge_curve
	if (mm_style_curve_override >= 0 && loop == 0): curve = mm_style_curve_override
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

# Fill, stroke and text for a family role under the resolved theme.
void mm_style_role_paint(list[int] values, mm_primitive* p, mm_style* resolved):
	int role = p.role
	int fill = -3
	int stroke = -3
	int text = -3
	if (role == MM_ROLE_NOTE):
		fill = values[MM_THEME_NOTE_BKG]
		stroke = values[MM_THEME_NOTE_BORDER]
		text = values[MM_THEME_NOTE_TEXT]
	else if (role == MM_ROLE_ACTOR):
		fill = values[MM_THEME_ACTOR_BKG]
		stroke = values[MM_THEME_ACTOR_BORDER]
		text = values[MM_THEME_ACTOR_TEXT]
	else if (role == MM_ROLE_SIGNAL):
		stroke = values[MM_THEME_SIGNAL]
		fill = stroke
		text = values[MM_THEME_SIGNAL_TEXT]
	else if (role == MM_ROLE_ACTOR_LINE): stroke = values[MM_THEME_ACTOR_LINE]
	else if (role >= MM_ROLE_TASK && role <= MM_ROLE_TASK_CRIT):
		fill = values[MM_THEME_TASK_BKG]
		if (role == MM_ROLE_TASK_ACTIVE): fill = values[MM_THEME_ACTIVE_TASK_BKG]
		if (role == MM_ROLE_TASK_DONE): fill = values[MM_THEME_DONE_TASK_BKG]
		if (role == MM_ROLE_TASK_CRIT): fill = values[MM_THEME_CRIT_BKG]
		stroke = values[MM_THEME_TASK_BORDER]
		text = values[MM_THEME_TASK_TEXT]
	else if (role == MM_ROLE_GRID): stroke = values[MM_THEME_GRID]
	else if (role == MM_ROLE_TODAY): stroke = values[MM_THEME_TODAY]
	else if (role == MM_ROLE_SECTION):
		fill = values[MM_THEME_SECTION_BKG]
		if (p.series % 2): fill = values[MM_THEME_ALT_SECTION_BKG]
		stroke = -1
	else if (role == MM_ROLE_EXCLUDE):
		fill = values[MM_THEME_EXCLUDE_BKG]
		stroke = fill
	else if (role == MM_ROLE_ROW):
		fill = values[MM_THEME_ROW_ODD]
		if (p.series % 2): fill = values[MM_THEME_ROW_EVEN]
	else if (role == MM_ROLE_GIT):
		stroke = values[MM_THEME_GIT + p.series % 8]
		fill = stroke
	else if (role == MM_ROLE_VENN):
		stroke = values[MM_THEME_VENN + p.series % 8]
		fill = stroke
	else if (role == MM_ROLE_TINT):
		stroke = values[MM_THEME_SCALE + p.series % 12]
		fill = mm_theme_adjust(stroke, 0, 0, p.tint)
	if (fill != -3 && p.kind != MM_TEXT && (p.user_mask & MM_STYLE_FILL) == 0): resolved.fill = fill
	if (stroke != -3 && (p.user_mask & MM_STYLE_STROKE) == 0): resolved.stroke = stroke
	if (text != -3 && p.kind == MM_TEXT && (p.user_mask & MM_STYLE_TEXT) == 0): resolved.text = text

# The neo look: themed node outlines take the theme's drop shadow and, where
# the theme enables it, the primaryBorderColor -> secondaryBorderColor gradient.
void mm_style_look(mm_document* d, mm_scene* scene):
	if (d.look != 1 || d.theme_values == 0): return
	list[int] values = d.theme_values
	int gradient = mm_theme_scalar(d.theme, 6)
	scene.has_effects = 1
	scene.shadow_dx = mm_theme_scalar(d.theme, 2)
	scene.shadow_dy = mm_theme_scalar(d.theme, 3)
	scene.shadow_blur = 2
	scene.shadow_color = mm_theme_scalar(d.theme, 4)
	scene.shadow_alpha = mm_theme_scalar(d.theme, 5)
	scene.gradient_start = values[MM_THEME_GRADIENT_START]
	scene.gradient_stop = values[MM_THEME_GRADIENT_STOP]
	for mm_primitive* primitive in scene.items:
		if (primitive.kind == MM_TEXT || primitive.kind == MM_LINE): continue
		if (primitive.role != MM_ROLE_NODE && primitive.role != MM_ROLE_CLUSTER && primitive.role != MM_ROLE_ACTOR): continue
		if (primitive.role != MM_ROLE_CLUSTER): primitive.effects = primitive.effects | 1
		if (gradient && (primitive.style.mask & MM_STYLE_STROKE) == 0): primitive.effects = primitive.effects | 2

# Fonts apply with or without a theme: the configured fontFamily becomes the
# SVG default and font-family styles give primitives their own family.
void mm_style_fonts(mm_document* d, mm_scene* scene):
	if (d.font_family != 0 && scene.font_family == 0): scene.font_family = strclone(d.font_family)
	for mm_primitive* primitive in scene.items:
		if ((primitive.style.mask & MM_STYLE_FAMILY) == 0 || primitive.font != 0): continue
		int family = primitive.style.family
		if (family >= 1 && family <= d.style_fonts.length): primitive.font = strclone(d.style_fonts[family - 1])

void mm_style_scene(mm_document* d, mm_scene* scene):
	mm_style_fonts(d, scene)
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
		if (primitive.role >= MM_ROLE_NOTE): mm_style_role_paint(values, primitive, &resolved)
		if (primitive.role == MM_ROLE_SERIES):
			int base = MM_THEME_SCALE
			if (d.kind == MM_PIE): base = MM_THEME_PIE
			resolved.fill = values[base + primitive.series % 12]
			resolved.stroke = resolved.fill
		primitive.style = resolved
	mm_style_look(d, scene)
	int background = values[MM_THEME_EDGE_LABEL_BKG]
	if (background < 0): return
	# Edge labels sit on an edgeLabelBackground box drawn just beneath them.
	list[mm_primitive*] items = new list[mm_primitive*]
	for mm_primitive* primitive in scene.items:
		if (primitive.role == MM_ROLE_EDGE && primitive.kind == MM_TEXT && primitive.text[0] != 0):
			int previous = mm_text_set_size(mm_paint_font_size(primitive))
			mm_primitive* box = new mm_primitive()
			box.kind = MM_BOX
			box.x = primitive.x - 3
			box.y = primitive.y - 1
			box.x2 = primitive.x + mm_text_width(primitive.text, mm_text_flags(primitive)) + 3
			box.y2 = primitive.y + mm_text_line_height() + 1
			mm_text_set_size(previous)
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
