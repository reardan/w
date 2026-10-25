# Graph layout and rendering; shared scene primitives live in scene.w.
import libs.extras.mermaid.scene
import libs.extras.mermaid.text
import libs.extras.mermaid.layout
import libs.extras.mermaid.positions
import libs.extras.mermaid.data_render
import libs.extras.mermaid.hierarchy_render
import libs.extras.mermaid.framework_render
import libs.extras.mermaid.gitgraph
import libs.extras.mermaid.blocks
import libs.extras.mermaid.systems
import libs.extras.mermaid.workflow_render
import libs.extras.mermaid.narrative_render
import libs.extras.mermaid.railroad_render
import libs.extras.mermaid.style_render
import libs.extras.mermaid.uml_render
import libs.extras.mermaid.c4_render
import libs.extras.mermaid.agentflow_render
import libs.extras.mermaid.flow_shapes
import libs.extras.mermaid.class_members
import libs.extras.mermaid.routing

# A comment holding a Markdown string or a <br> renders through the shared
# label layout; plain comments stay in the attribute's single text run.
# Requirement text is Markdown upstream: a member with emphasis markers or
# `<br>` gets the rich layout (an owned label), plain members return 0.
char* mm_member_markup(int markdown, mm_member* m):
	int emphasis = markdown && mm_text_is_markdown(m.text) == 0 && (index_of(m.text, c"*") >= 0 || index_of(m.text, c"_") >= 0)
	if (emphasis == 0):
		if (mm_text_rich(m.text)): return strclone(m.text)
		return 0
	string_builder* text = string_from(c"`")
	string_append(text, m.text)
	string_append_char(text, '`')
	char* result = text.data
	free(text)
	return result

# Extra row height and the width of a member's rich label (0 when plain).
int mm_member_extra(int markdown, mm_member* m, int* width):
	char* label = mm_member_markup(markdown, m)
	if (label == 0): return 0
	mm_text_block* t = mm_text_layout(label, 0)
	int extra = (mm_text_lines(t) - 1) * t.pitch
	width[0] = t.width
	mm_text_block_free(t)
	free(label)
	return extra

int mm_attribute_rich(mm_attribute* a):
	if (mm_text_is_markdown(a.comment)): return 1
	for i in range(strlen(a.comment)):
		if (mm_text_break_tag(a.comment, i, strlen(a.comment))): return 1
	return 0

char* mm_attribute_text(mm_attribute* a):
	string_builder* s = string_from(a.type_name)
	string_append(s, c"  ")
	string_append(s, a.name)
	if (a.keys[0] != 0):
		string_append(s, c"  ")
		string_append(s, a.keys)
	if (a.comment[0] != 0 && mm_attribute_rich(a) == 0):
		string_append(s, c"  ")
		string_append(s, a.comment)
	char* result = s.data
	free(s)
	return result

# Row height of an attribute: 26px, plus one pitch per extra comment line.
int mm_attribute_height(mm_attribute* a):
	if (mm_attribute_rich(a) == 0): return 26
	mm_text_block* t = mm_text_layout(a.comment, 0)
	int height = 26 + (mm_text_lines(t) - 1) * t.pitch
	mm_text_block_free(t)
	return height

int mm_attribute_width(mm_attribute* a):
	char* text = mm_attribute_text(a)
	int width = mm_text_width(text, 0)
	free(text)
	if (mm_attribute_rich(a)):
		mm_text_block* t = mm_text_layout(a.comment, 0)
		width = width + mm_text_width(c"  ", 0) + t.width
		mm_text_block_free(t)
	return width

void mm_attribute_draw(mm_scene* s, mm_attribute* a, int x, int y):
	char* text = mm_attribute_text(a)
	mm_text(s, x, y, text)
	if (mm_attribute_rich(a)):
		mm_text_block* t = mm_text_layout(a.comment, 0)
		mm_text_draw(s, t, x + mm_text_width(text, 0) + mm_text_width(c"  ", 0), y, 0)
		mm_text_block_free(t)
	free(text)

char* mm_scope_direction(mm_document* d, int scope):
	while (scope >= 0):
		mm_node* n = d.nodes[scope]
		if (n.direction[0] != 0): return n.direction
		scope = n.parent
	return d.direction

# Compartment titles (ER entities, classes, requirements, C4) and group
# titles are names: they break only where the label says so. Other node
# labels wrap at the upstream default wrapping width.
int mm_label_wrap(mm_document* d, mm_node* n):
	if (n.group || d.kind == MM_ER || d.kind == MM_CLASS || d.kind == MM_REQUIREMENT || d.kind == MM_C4): return 0
	return MM_TEXT_WRAP

# font-weight / font-style styles give the whole label a base text style.
mm_text_block* mm_node_text(mm_document* d, mm_node* n):
	mm_style style = mm_style_resolve(d, n)
	int base = 0
	if (style.mask & MM_STYLE_WEIGHT): base = base | (style.font & MM_TEXT_BOLD)
	if (style.mask & MM_STYLE_ITALIC): base = base | (style.font & MM_TEXT_ITALIC)
	return mm_text_layout_style(n.label, mm_label_wrap(d, n), base)

# Select a node's font-size style for its measurement and drawing; returns
# the previous size for mm_text_set_size.
int mm_node_font_push(mm_document* d, mm_node* n):
	mm_style style = mm_style_resolve(d, n)
	if (style.mask & MM_STYLE_SIZE): return mm_text_set_size(style.font_size)
	return mm_text_set_size(mm_text_size())

# Height a node's label adds beyond the single line every shape reserves.
int mm_node_text_extra(mm_document* d, mm_node* n):
	int previous = mm_node_font_push(d, n)
	mm_text_block* t = mm_node_text(d, n)
	int extra = t.height - MM_TEXT_LINE
	mm_text_block_free(t)
	mm_text_set_size(previous)
	return extra

# Requirement and element boxes stack measured lines as upstream's
# requirementBox does: the <<type>> line and the name centered, a 20px gap
# holding the divider, then one row per property at its measured height plus
# 6px, inside 10px of padding (the box stays at least 180px wide).
const int MM_REQUIREMENT_PAD = 10

char* mm_requirement_type(mm_node* n):
	if (n.annotation[0] == 0): return 0
	string_builder* text = string_from(c"<<")
	string_append(text, n.annotation)
	string_append(text, c">>")
	char* result = text.data
	free(text)
	return result

# Row height of one property; *width receives its measured width.
int mm_requirement_row(mm_member* m, int* width):
	char* rich = mm_member_markup(1, m)
	if (rich == 0):
		width[0] = mm_text_width(m.text, 0)
		return MM_TEXT_LINE + 6
	mm_text_block* t = mm_text_layout(rich, 0)
	width[0] = t.width
	int height = t.height + 6
	mm_text_block_free(t)
	free(rich)
	return height

void mm_requirement_measure(mm_node* n, mm_bounds* b, int title_width, int title_height):
	int widest = title_width
	int height = MM_REQUIREMENT_PAD * 2 + title_height
	char* type = mm_requirement_type(n)
	if (type != 0):
		if (mm_text_width(type, 0) > widest): widest = mm_text_width(type, 0)
		height = height + MM_TEXT_LINE + 6
		free(type)
	if (n.members.length > 0): height = height + 20
	for mm_member* m in n.members:
		int width = 0
		height = height + mm_requirement_row(m, &width)
		if (width > widest): widest = width
	b.w = widest + 24
	if (b.w < 180): b.w = 180
	b.h = height

void mm_render_requirement(mm_scene* s, mm_node* n, mm_bounds* b, int title_height):
	int y = b.y + MM_REQUIREMENT_PAD
	char* type = mm_requirement_type(n)
	if (type != 0):
		mm_text(s, b.x + (b.w - mm_text_width(type, 0)) / 2, y + 3, type)
		free(type)
		y = y + MM_TEXT_LINE + 6
	y = y + title_height
	if (n.members.length == 0): return
	mm_line(s, b.x, y + 10, b.x + b.w, y + 10, 0)
	y = y + 20
	for mm_member* m in n.members:
		int width = 0
		int height = mm_requirement_row(m, &width)
		char* rich = mm_member_markup(1, m)
		if (rich != 0):
			mm_label(s, b.x + 12, y + 3, rich, 0, 0)
			free(rich)
		else: mm_text(s, b.x + 12, y + 3, m.text)
		y = y + height

void mm_measure(mm_document* d, mm_scene* s):
	for mm_node* n in d.nodes:
		mm_bounds* b = new mm_bounds()
		b.rank = -1
		int previous = mm_node_font_push(d, n)
		mm_text_block* text = mm_node_text(d, n)
		int extra = text.height - MM_TEXT_LINE
		b.w = text.width + 40
		int text_w = text.width
		int text_h = text.height
		mm_text_block_free(text)
		if (b.w < 180): b.w = 180
		b.h = 60 + extra
		if (d.kind == MM_ARCHITECTURE && n.group): b.w = b.w + mm_text_width(n.annotation, 0) + 24
		if (n.shape == 10 || n.shape == 12): b.h = 110 + extra
		if (n.shape == 11): b.h = 72 + extra
		if (n.shape == 28):
			b.h = 72 + extra
		if (n.shape == 13):
			b.w = 72
			b.h = 72
		if (n.shape == 2): b.h = b.w
		if (n.shape == 3):
			b.w = b.w * 2
			b.h = 100 + extra * 2
		if (d.kind != MM_FLOW && mm_shape_catalogued(n.shape)): mm_shape_size(n.shape, &b.w, &b.h)
		if (d.kind == MM_ER):
			b.h = 40 + extra
			for mm_attribute* a in n.attributes:
				b.h = b.h + mm_attribute_height(a)
				int width = mm_attribute_width(a) + 32
				if (width > b.w): b.w = width
		if (d.kind == MM_REQUIREMENT && n.group == 0): mm_requirement_measure(n, b, text_w, text_h)
		else if ((d.kind == MM_CLASS || d.kind == MM_C4) && n.group == 0):
			b.h = 80 + extra + n.members.length * 26
			if (n.annotation[0] != 0): b.h = b.h + 24
			int width = mm_text_width(n.annotation, 0) + 68
			if (width > b.w): b.w = width
			for mm_member* m in n.members:
				if (d.kind == MM_CLASS):
					int classifier = 0
					char* shown = mm_class_member_display(m.text, &classifier)
					int style = 0
					if (classifier == MM_MEMBER_ABSTRACT): style = MM_TEXT_ITALIC
					width = mm_text_width(shown, style) + 32
					free(shown)
				else:
					width = mm_text_width(m.text, 0) + 32
					int rich_width = 0
					b.h = b.h + mm_member_extra(d.kind == MM_REQUIREMENT, m, &rich_width)
					if (rich_width != 0): width = rich_width + 32
				if (width > b.w): b.w = width
		if (d.kind == MM_USECASE): mm_uc_measure(d, n, b)
		# requirement.rect_min_width / rect_min_height enlarge requirement and element boxes.
		if (d.kind == MM_REQUIREMENT && n.group == 0):
			int min_width = mm_config_number(d, c"requirement.rect_min_width", 0)
			int min_height = mm_config_number(d, c"requirement.rect_min_height", 0)
			if (b.w < min_width): b.w = min_width
			if (b.h < min_height): b.h = min_height
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
		if (d.kind == MM_FLOW && n.group == 0 && n.shape >= MM_SHAPE_CYLINDER): mm_flow_shape_measure(n, b, mm_scope_direction(d, n.parent), text_w, text_h)
		mm_text_set_size(previous)
		s.nodes.push(b)

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
			if (n.group && mm_flow_collapsed(d, i) == 0): mm_layout_scope(d, s, i)
			indices.push(i)
			nodes.push(s.nodes[i])
	# Scope-local index of each direct child; edges between nested nodes map to
	# their scope children, and only edges joining two direct children get routes.
	list[int] local = new list[int]
	for i in range(d.nodes.length): local.push(-1)
	for i in range(indices.length): local[indices[i]] = i
	list[mm_edge_route*] routes = new list[mm_edge_route*]
	for mm_edge* e in d.edges:
		int a = mm_scope_child(d, e.from_node, scope)
		int b = mm_scope_child(d, e.to_node, scope)
		if (a < 0 || b < 0 || a == b): continue
		mm_edge* mapped = new mm_edge()
		# Borrowed for label-aware rank gaps; only the struct is freed below.
		mapped.label = e.label
		mapped.min_length = e.min_length
		mapped.extra_rank = e.extra_rank
		mapped.stroke = e.stroke
		mapped.from_node = local[a]
		mapped.to_node = local[b]
		edges.push(mapped)
		mm_edge_route* route = 0
		if (a == e.from_node && b == e.to_node && d.layout_algorithm != 1): route = mm_edge_route_of(s.nodes[a], e, 1)
		routes.push(route)
	mm_place(nodes, edges, mm_scope_direction(d, scope), mm_style_lane_gap(d), mm_style_rank_gap(d), routes, d.kind == MM_ER)
	__w_list_free(cast(__w_list*, local))
	__w_list_free(cast(__w_list*, routes))
	if (d.layout_algorithm == 1): mm_force_place(nodes, edges)
	if (scope >= 0):
		mm_bounds* box = s.nodes[scope]
		int extra = mm_node_text_extra(d, d.nodes[scope])
		box.h = 100 + extra
		for mm_bounds* b in nodes:
			b.y = b.y + 24 + extra
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
	# Contents of collapsed subgraphs keep empty bounds at their group's origin.
	for i in range(d.nodes.length):
		int visible = mm_flow_visible_node(d, i)
		if (visible == i): continue
		mm_bounds* b = s.nodes[i]
		mm_bounds* group = s.nodes[visible]
		b.x = group.x
		b.y = group.y
		b.w = 0
		b.h = 0

# Convex, axis-aligned endpoint polygons, oriented away from their node.
void mm_uml_marker(mm_scene* s, int x, int y, int dx, int dy, int kind):
	if (kind == 0): return
	int px = 0 - dy
	int py = dx
	if (kind == 5):
		int cx = x + dx * 8
		int cy = y + dy * 8
		mm_draw(s, MM_CIRCLE, cx - 7, cy - 7, cx + 7, cy + 7, 0, c"")
		mm_line(s, cx - 5, cy, cx + 5, cy, 0)
		mm_line(s, cx, cy - 5, cx, cy + 5, 0)
		return
	if (kind == 8):
		# Use-case circle association end.
		int ox = x + dx * 7
		int oy = y + dy * 7
		mm_draw(s, MM_CIRCLE, ox - 6, oy - 6, ox + 6, oy + 6, 0, c"")
		return
	if (kind == 9):
		int qx = x + dx * 8
		int qy = y + dy * 8
		mm_line(s, qx - 6, qy - 6, qx + 6, qy + 6, 0)
		mm_line(s, qx - 6, qy + 6, qx + 6, qy - 6, 0)
		return
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


# 1 when the generic renderer draws e between left/right node sides.
int mm_edge_horizontal(mm_document* d, mm_edge* e):
	char* direction = d.direction
	if (d.kind == MM_CLASS || d.kind == MM_STATE || d.kind == MM_FLOW || d.kind == MM_ER || d.kind == MM_REQUIREMENT || d.kind == MM_C4 || d.kind == MM_AGENT): direction = mm_scope_direction(d, e.scope)
	return strcmp(direction, c"LR") == 0 || strcmp(direction, c"RL") == 0

void mm_render_edge(mm_document* d, mm_scene* s, mm_edge* e):
	if (d.kind == MM_ARCHITECTURE):
		mm_arch_edge(d, s, e)
		return
	mm_bounds* a = s.nodes[e.from_node]
	mm_bounds* b = s.nodes[e.to_node]
	int horizontal = mm_edge_horizontal(d, e)
	mm_edge_route* record = mm_edge_route_of(a, e, 0)
	int route_dx = 0
	int route_dy = 0
	int routed = e.from_node != e.to_node && mm_route_usable(record, a, b, horizontal, &route_dx, &route_dy)
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
	# Port distribution from mm_render_ports: ER relationships spread along the
	# entity side in the order of their far ends; spread sides elsewhere use a
	# 16px pitch around the center.
	if (record != 0 && d.kind == MM_ER):
		if (horizontal):
			if (record.from_count > 0): ay = a.y + a.h * (record.from_slot + 1) / (record.from_count + 1)
			if (record.to_count > 0): by = b.y + b.h * (record.to_slot + 1) / (record.to_count + 1)
		else:
			if (record.from_count > 0): ax = a.x + a.w * (record.from_slot + 1) / (record.from_count + 1)
			if (record.to_count > 0): bx = b.x + b.w * (record.to_slot + 1) / (record.to_count + 1)
	else if (record != 0):
		int from_shift = 0
		int to_shift = 0
		if (record.from_count > 0): from_shift = (record.from_slot * 2 - (record.from_count - 1)) * 8
		if (record.to_count > 0): to_shift = (record.to_slot * 2 - (record.to_count - 1)) * 8
		if (horizontal):
			ay = ay + from_shift
			by = by + to_shift
		else:
			ax = ax + from_shift
			bx = bx + to_shift
	mm_node* from_node = d.nodes[e.from_node]
	mm_node* to_node = d.nodes[e.to_node]
	if (from_node.shape == 28):
		ax = a.x + a.w / 2 + dx * 12
		ay = a.y + 16 + dy * 12
	if (to_node.shape == 28):
		bx = b.x + b.w / 2 - dx * 12
		by = b.y + 16 - dy * 12
	int mx = (ax + bx) / 2
	int my = (ay + by) / 2
	if (horizontal): mx = bx - dx * 45
	else: my = by - dy * 45
	# Outward direction of the line at the target port (markers point along it).
	int end_dx = 0 - dx
	int end_dy = 0 - dy
	if (e.from_node == e.to_node):
		ax = a.x + a.w
		ay = a.y + a.h / 3
		bx = ax
		by = a.y + a.h * 2 / 3
		dx = 1
		dy = 0
		end_dx = 1
		end_dy = 0
		mx = ax + 55
		my = ay
		horizontal = 1
	# An obstacle route (mm_render_obstacle_routes) replaces the direct one
	# while both endpoints keep the offset they had when it was computed.
	list[int] points = 0
	int points_dx = 0
	int points_dy = 0
	if (record != 0 && record.points != 0 && a.x - record.points_from_x == b.x - record.points_to_x && a.y - record.points_from_y == b.y - record.points_to_y):
		points = record.points
		points_dx = a.x - record.points_from_x
		points_dy = a.y - record.points_from_y
		ax = points[0] + points_dx
		ay = points[1] + points_dy
		bx = points[points.length - 2] + points_dx
		by = points[points.length - 1] + points_dy
		dx = record.from_dx
		dy = record.from_dy
		end_dx = record.to_dx
		end_dy = record.to_dy
		horizontal = record.points_horizontal
	int path_start = s.items.length
	if (d.kind == MM_FLOW && e.stroke == 2): return
	int dashed = e.dashed
	# Animated use-case edges (e.arrow) draw as dashes in static output.
	if (d.kind == MM_USECASE && e.arrow): dashed = 1
	int curve = d.edge_curve
	if (d.kind == MM_FLOW && e.curve != 0): d.edge_curve = e.curve - 1
	# An agentflow `curve` shapes the edge along its route like flowchart.curve.
	int override = mm_style_curve_override
	if (d.kind == MM_AGENT && e.curve != 0): mm_style_curve_override = e.curve - 1
	int leg_x = ax
	int leg_y = ay
	if (points != 0):
		int smooth = 0
		if (e.from_node != e.to_node):
			if (mm_style_curve_override >= 0): smooth = mm_style_curve_override == 2
			else if (d.kind == MM_FLOW): smooth = d.edge_curve == 2
		mm_route_points_draw(s, points, points_dx, points_dy, smooth, dashed)
		# Labels follow the final leg: from its corner to the target port.
		int corner_x = points[0] + points_dx
		int corner_y = points[1] + points_dy
		if (points.length >= 4):
			corner_x = points[points.length - 4] + points_dx
			corner_y = points[points.length - 3] + points_dy
		if (e.from_node == e.to_node):
			mx = ax
			for k in range(points.length / 2):
				if (points[k * 2] + points_dx > mx): mx = points[k * 2] + points_dx
			my = ay
		else if (horizontal):
			leg_x = corner_x
			leg_y = by
			mx = bx
		else: my = corner_y
	else if (routed):
		int bend = mm_route_draw(d, s, record, route_dx, route_dy, ax, ay, bx, by, horizontal, dashed, &leg_x, &leg_y)
		if (horizontal): mx = bend
		else: my = bend
	else: mm_style_edge_path(d, s, ax, ay, mx, my, bx, by, horizontal, dashed, e.from_node == e.to_node)
	d.edge_curve = curve
	mm_style_curve_override = override
	if (s.path_only): return
	if (d.kind == MM_FLOW):
		mm_flow_link_stroke(s, e, path_start)
		mm_flow_marker(s, ax, ay, dx, dy, e.left_marker)
		mm_flow_marker(s, bx, by, end_dx, end_dy, e.right_marker)
	# Animated agentflow edges march their dashes like flowchart links.
	if (d.kind == MM_AGENT && e.animate != 0):
		for i in range(path_start, s.items.length):
			mm_primitive* segment = s.items[i]
			if (segment.kind == MM_LINE): segment.dashed = 3 + e.animate
	if (d.kind == MM_ER):
		mm_marker(s, ax, ay, dx, dy, e.left_card)
		mm_marker(s, bx, by, end_dx, end_dy, e.right_card)
	else if (d.kind == MM_CLASS || d.kind == MM_REQUIREMENT || d.kind == MM_C4 || d.kind == MM_USECASE):
		if (from_node.shape != 28): mm_uml_marker(s, ax, ay, dx, dy, e.left_marker)
		if (to_node.shape != 28): mm_uml_marker(s, bx, by, end_dx, end_dy, e.right_marker)
		if (e.left_label[0] != 0): mm_text(s, ax + dx * 30 + 8, ay + dy * 30 + 8, e.left_label)
		if (e.right_label[0] != 0): mm_text(s, bx + end_dx * 30 + 8, by + end_dy * 30 + 8, e.right_label)
	else if (d.kind == MM_AGENT && e.right_marker == 6):
		int mark_x = bx + end_dx * 10
		int mark_y = by + end_dy * 10
		mm_line(s, mark_x - 6, mark_y - 6, mark_x + 6, mark_y + 6, 0)
		mm_line(s, mark_x - 6, mark_y + 6, mark_x + 6, mark_y - 6, 0)
	else if (e.arrow):
		mm_line(s, bx, by, bx + end_dx * 10 - end_dy * 5, by + end_dy * 10 + end_dx * 5, 0)
		mm_line(s, bx, by, bx + end_dx * 10 + end_dy * 5, by + end_dy * 10 - end_dx * 5, 0)
	if (e.label[0] != 0):
		mm_text_block* t = mm_text_layout(e.label, MM_TEXT_WRAP)
		if (e.from_node == e.to_node): mm_text_draw(s, t, mx + 8, my - 6 - t.height, 0)
		else:
			int lx = bx + 8
			int ly = (my + by) / 2 - t.height / 2
			if (horizontal):
				lx = (leg_x + mx) / 2
				ly = leg_y - 6 - t.height
			# Labels move off nodes and earlier labels; edge-only redraws (canvas
			# hit tests and highlights) reuse the spot chosen by the full render.
			if (s.labels != 0):
				mm_label_place(s.labels, t.width, t.height, horizontal, horizontal, &lx, &ly)
				if (record != 0):
					record.placed = 1
					record.label_x = lx - a.x
					record.label_y = ly - a.y
			else if (record != 0 && record.placed):
				lx = a.x + record.label_x
				ly = a.y + record.label_y
			mm_text_draw(s, t, lx, ly, horizontal)
		mm_text_block_free(t)

void mm_render_groups(mm_document* d, mm_scene* s, int scope):
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.group == 0 || n.parent != scope): continue
		mm_bounds* b = s.nodes[i]
		if (d.kind == MM_USECASE && mm_uc_boundary_draw(d, s, n, b)):
			mm_render_groups(d, s, i)
			continue
		int style_start = s.items.length
		if (mm_flow_collapsed(d, i)):
			mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
			mm_text_block* collapsed = mm_node_text(d, n)
			mm_text_draw(s, collapsed, b.x + b.w / 2, b.y + (b.h - collapsed.height) / 2, 1)
			mm_text_block_free(collapsed)
			mm_flow_link_scene(s, n, style_start)
			mm_style_node(d, s, n, style_start)
			continue
		mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, d.kind == MM_STATE, c"")
		# Concurrent state regions are unlabeled dashed partitions of their composite.
		if (d.kind == MM_STATE && index_of(n.id, c"@region:") == 0):
			mm_render_groups(d, s, i)
			continue
		int title_x = b.x + 16
		if (d.kind == MM_ARCHITECTURE && n.annotation[0] != 0):
			string_builder* prefix = string_from(c"[")
			string_append(prefix, n.annotation)
			string_append(prefix, c"] ")
			mm_text(s, title_x, b.y + 12, prefix.data)
			title_x = title_x + mm_text_width(prefix.data, 0)
			string_free(prefix)
		int previous = mm_node_font_push(d, n)
		mm_text_block* title = mm_node_text(d, n)
		mm_text_draw(s, title, title_x, b.y + 12, 0)
		int extra = title.height - MM_TEXT_LINE
		mm_text_block_free(title)
		mm_text_set_size(previous)
		mm_line(s, b.x, b.y + 40 + extra, b.x + b.w, b.y + 40 + extra, 0)
		mm_style_node(d, s, n, style_start)
		mm_render_groups(d, s, i)

void mm_render_class(mm_document* d, mm_scene* s, mm_node* n, mm_bounds* b, int extra):
	int y = b.y + 40 + extra
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
				if (d.kind == MM_CLASS):
					# Static members are underlined, abstract members italic, as upstream.
					int classifier = 0
					char* shown = mm_class_member_display(m.text, &classifier)
					int style = 0
					if (classifier == MM_MEMBER_ABSTRACT): style = MM_TEXT_ITALIC
					mm_text_styled(s, b.x + 12, y + 5, shown, style)
					if (classifier == MM_MEMBER_STATIC): mm_line(s, b.x + 12, y + 5 + MM_TEXT_LINE - 1, b.x + 12 + mm_text_width(shown, 0), y + 5 + MM_TEXT_LINE - 1, 0)
					free(shown)
				else:
					char* rich = mm_member_markup(d.kind == MM_REQUIREMENT, m)
					if (rich != 0):
						mm_label(s, b.x + 12, y + 5, rich, 0, 0)
						free(rich)
						int rich_width = 0
						y = y + mm_member_extra(d.kind == MM_REQUIREMENT, m, &rich_width)
					else: mm_text(s, b.x + 12, y + 5, m.text)
				y = y + 26
				count = count + 1
		if (count == 0): y = y + 18
		if (method == 0): mm_line(s, b.x, y, b.x + b.w, y, 0)

# One node's shape, label and compartments, at the node's own font size.
void mm_render_node(mm_document* d, mm_scene* s, int i):
	mm_node* n = d.nodes[i]
	mm_bounds* b = s.nodes[i]
	int style_start = s.items.length
	if (d.kind == MM_FLOW && n.shape >= MM_SHAPE_CYLINDER):
		if (mm_flow_shape_draw(s, n, b) == 0):
			mm_text_block* inner = mm_node_text(d, n)
			mm_text_draw(s, inner, b.x + b.w / 2, b.y + (b.h - inner.height) / 2, 1)
			mm_text_block_free(inner)
		mm_flow_link_scene(s, n, style_start)
		mm_style_node(d, s, n, style_start)
		return
	if (d.kind == MM_STATE && n.shape >= 4):
		if (n.shape == 6): mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, 2, c"")
		else:
			mm_draw(s, MM_CIRCLE, b.x, b.y, b.x + b.w, b.y + b.h, n.shape == 4, c"")
			if (n.shape == 5): mm_draw(s, MM_CIRCLE, b.x + 7, b.y + 7, b.x + b.w - 7, b.y + b.h - 7, 1, c"")
		mm_style_node(d, s, n, style_start)
		return
	if (n.shape == 28):
		int cx = b.x + b.w / 2
		mm_draw(s, MM_CIRCLE, cx - 12, b.y + 4, cx + 12, b.y + 28, 0, c"")
		mm_label(s, b.x + b.w / 2, b.y + 44, n.label, mm_label_wrap(d, n), 1)
		mm_style_node(d, s, n, style_start)
		return
	if (d.kind == MM_USECASE && mm_uc_node_draw(d, s, n, b)): return
	if (n.shape == 12 || n.shape == 13):
		mm_arch_icon(s, n, b)
		if (n.shape == 12): mm_label(s, b.x + b.w / 2, b.y + 86, n.label, mm_label_wrap(d, n), 1)
		mm_style_node(d, s, n, style_start)
		return
	if (n.shape >= 100 && n.shape <= MM_SHAPE_LAST): mm_shape_draw(s, n.shape, b.x, b.y, b.w, b.h)
	else if (n.shape == 21 || n.shape == 22):
		mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
		mm_primitive* box = s.items[s.items.length - 1]
		if (n.shape == 21): box.dashed = 3
		else:
			mm_line(s, b.x + 10, b.y, b.x + 10, b.y + b.h, 0)
			mm_line(s, b.x + b.w - 10, b.y, b.x + b.w - 10, b.y + b.h, 0)
	else if (n.shape >= 23 && n.shape <= 27):
		mm_draw(s, MM_POLYGON, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
		mm_primitive* polygon = s.items[s.items.length - 1]
		if (n.shape == 23): polygon.points = list[int]{b.x + 20, b.y, b.x + b.w - 20, b.y, b.x + b.w, b.y + b.h / 2, b.x + b.w - 20, b.y + b.h, b.x + 20, b.y + b.h, b.x, b.y + b.h / 2}
		else:
			int tl = 0
			int tr = 0
			int bl = 0
			int br = 0
			if (n.shape == 24 || n.shape == 26): tl = 20
			if (n.shape == 25 || n.shape == 26): tr = 20
			if (n.shape == 25 || n.shape == 27): bl = 20
			if (n.shape == 24 || n.shape == 27): br = 20
			polygon.points = list[int]{b.x + tl, b.y, b.x + b.w - tr, b.y, b.x + b.w - br, b.y + b.h, b.x + bl, b.y + b.h}
	else if (n.shape == 3):
		mm_draw(s, MM_POLYGON, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
		mm_primitive* diamond = s.items[s.items.length - 1]
		diamond.points = list[int]{b.x + b.w / 2, b.y, b.x + b.w, b.y + b.h / 2, b.x + b.w / 2, b.y + b.h, b.x, b.y + b.h / 2}
	else if (d.kind == MM_AGENT && n.shape >= 17):
		if (n.shape == 17 || n.shape == 19):
			mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
			if (n.shape == 17):
				mm_line(s, b.x + 10, b.y, b.x + 10, b.y + b.h, 0)
				mm_line(s, b.x + b.w - 10, b.y, b.x + b.w - 10, b.y + b.h, 0)
			else:
				mm_line(s, b.x + 8, b.y + b.h - 8, b.x + b.w - 8, b.y + b.h - 8, 0)
		else:
			mm_draw(s, MM_POLYGON, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
			mm_primitive* polygon = s.items[s.items.length - 1]
			if (n.shape == 18): polygon.points = list[int]{b.x + 16, b.y, b.x + b.w, b.y, b.x + b.w - 16, b.y + b.h, b.x, b.y + b.h}
			else: polygon.points = list[int]{b.x + 16, b.y, b.x + b.w - 16, b.y, b.x + b.w, b.y + b.h / 2, b.x + b.w - 16, b.y + b.h, b.x + 16, b.y + b.h, b.x, b.y + b.h / 2}
	else if (n.shape == 2): mm_draw(s, MM_CIRCLE, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
	else if (n.shape == 11):
		mm_draw(s, MM_POLYGON, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
		mm_primitive* oval = s.items[s.items.length - 1]
		oval.points = new list[int]
		for i in range(48):
			float angle = cast(float, i) * 6.2831853 / 48.0
			oval.points.push(b.x + b.w / 2 + cast(int, fcos(angle) * cast(float, b.w) / 2.0))
			oval.points.push(b.y + b.h / 2 + cast(int, fsin(angle) * cast(float, b.h) / 2.0))
	else: mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, n.shape == 1, c"")
	mm_text_block* title = mm_node_text(d, n)
	int extra = title.height - MM_TEXT_LINE
	int title_y = b.y + (b.h - title.height) / 2
	if (n.shape >= 100 && n.shape <= MM_SHAPE_LAST): title_y = b.y + mm_shape_label_y(n.shape, b.h, title.height)
	if (d.kind == MM_ER || (d.kind == MM_CLASS || d.kind == MM_REQUIREMENT || d.kind == MM_C4)): title_y = b.y + 12
	if (d.kind == MM_REQUIREMENT && n.group == 0):
		title_y = b.y + MM_REQUIREMENT_PAD
		if (n.annotation[0] != 0): title_y = title_y + MM_TEXT_LINE + 6
	if (d.kind != MM_STATE || n.shape != 3): mm_text_draw(s, title, b.x + b.w / 2, title_y, 1)
	int title_height = title.height
	mm_text_block_free(title)
	if (d.kind == MM_REQUIREMENT && n.group == 0): mm_render_requirement(s, n, b, title_height)
	else if ((d.kind == MM_CLASS || d.kind == MM_REQUIREMENT || d.kind == MM_C4)): mm_render_class(d, s, n, b, extra)
	if (d.kind == MM_ER):
		int y = b.y + 40 + extra
		for j in range(n.attributes.length):
			mm_attribute* a = n.attributes[j]
			int height = mm_attribute_height(a)
			# Themed rows alternate attributeBackgroundColorOdd / Even.
			if (d.theme_values != 0):
				int row = s.items.length
				mm_draw(s, MM_BOX, b.x + 1, y + 1, b.x + b.w - 1, y + height - 1, 0, c"")
				mm_style_role(s, row, MM_ROLE_ROW, j)
				mm_primitive* fill = s.items[row]
				fill.style.mask = MM_STYLE_STROKE
				fill.style.stroke = -1
			mm_line(s, b.x, y, b.x + b.w, y, 0)
			mm_attribute_draw(s, a, b.x + 12, y + 5)
			y = y + height
	mm_flow_link_scene(s, n, style_start)
	mm_style_node(d, s, n, style_start)

# Rebuild primitives from existing bounds; pointer-motion previews skip parsing and layout.
# Port slots for every drawn edge, stored on its geometry record. ER ends on
# one entity side are ordered by the cross-axis position of their far end (the
# first or last route channel when routed), so neighboring relationships do
# not cross at the entity, and parallel relationships take adjacent slots.
# Other families keep side-center ports unless a side holds parallel or
# opposite-direction edges; those spread 16px apart around the center.
void mm_render_ports(mm_document* d, mm_scene* s):
	list[mm_edge_route*] records = new list[mm_edge_route*]
	list[int] group = new list[int]
	list[int] key = new list[int]
	list[int] end = new list[int]
	list[int] pair = new list[int]
	int count = d.nodes.length
	for mm_edge* e in d.edges:
		int from = mm_flow_visible_node(d, e.from_node)
		int to = mm_flow_visible_node(d, e.to_node)
		if (from == to || (d.kind == MM_FLOW && e.stroke == 2)): continue
		mm_bounds* a = s.nodes[from]
		mm_bounds* b = s.nodes[to]
		mm_edge_route* r = mm_edge_route_of(a, e, 1)
		r.from_slot = 0
		r.from_count = 0
		r.to_slot = 0
		r.to_count = 0
		r.offset = 0
		int horizontal = mm_edge_horizontal(d, e)
		int side = 1
		int far_from = b.x + b.w / 2
		int far_to = a.x + a.w / 2
		if (horizontal):
			side = 3
			far_from = b.y + b.h / 2
			far_to = a.y + a.h / 2
			if (b.x < a.x): side = 2
		else if (b.y < a.y): side = 0
		int tx = 0
		int ty = 0
		if (from == e.from_node && to == e.to_node && mm_route_usable(r, a, b, horizontal, &tx, &ty) && r.lanes.length > 0):
			int shift = tx
			if (horizontal): shift = ty
			far_from = r.lanes[0] + shift
			far_to = r.lanes[r.lanes.length - 1] + shift
		int low = from
		int high = to
		if (high < low):
			low = to
			high = from
		for which in range(2):
			records.push(r)
			end.push(which)
			if (which == 0):
				group.push(from * 4 + side)
				key.push(far_from)
			else:
				group.push(to * 4 + (side ^ 1))
				key.push(far_to)
			pair.push(low * count + high)
	list[int] order = new list[int]
	list[int] scratch = new list[int]
	for i in range(records.length):
		order.push(i)
		scratch.push(0)
	mm_layout_sort(order, 0, order.length, key, scratch)
	mm_layout_sort(order, 0, order.length, group, scratch)
	int at = 0
	while (at < order.length):
		int stop = at
		int spread = 0
		while (stop < order.length && group[order[stop]] == group[order[at]]):
			for k in range(at, stop):
				if (end[order[k]] != end[order[stop]] || pair[order[k]] == pair[order[stop]]): spread = 1
			stop = stop + 1
		# Elsewhere a side is spread only when it holds parallel edges or edges
		# that both leave and arrive (mirrored by mm_place for track order), so
		# no two edges run on top of each other into the same port.
		if (d.kind == MM_ER || spread):
			for i in range(at, stop):
				mm_edge_route* r = records[order[i]]
				if (end[order[i]] == 0):
					r.from_slot = i - at
					r.from_count = stop - at
				else:
					r.to_slot = i - at
					r.to_count = stop - at
		at = stop
	__w_list_free(cast(__w_list*, records))
	__w_list_free(cast(__w_list*, group))
	__w_list_free(cast(__w_list*, key))
	__w_list_free(cast(__w_list*, end))
	__w_list_free(cast(__w_list*, pair))
	__w_list_free(cast(__w_list*, order))
	__w_list_free(cast(__w_list*, scratch))

# Occupied areas for label placement: every drawn leaf node box.
mm_label_grid* mm_render_label_grid(mm_document* d, mm_scene* s):
	int width = 0
	int height = 0
	for mm_bounds* b in s.nodes:
		if (b.x + b.w > width): width = b.x + b.w
		if (b.y + b.h > height): height = b.y + b.h
	mm_label_grid* g = mm_label_grid_new(width + 400, height + 400)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		if (n.group || b.w <= 0 || mm_flow_visible_node(d, i) != i): continue
		mm_label_grid_add(g, b.x, b.y, b.x + b.w, b.y + b.h)
	return g

# Free a scratch scene that borrows another scene's bounds.
void mm_route_edge_scene_release(mm_scene* view):
	view.nodes = new list[mm_bounds*]
	mm_scene_free(view)

# Title area of a drawn, expanded group (mm_render_groups): from its top-left
# corner past the title text to the divider. 0 for unlabeled regions.
int mm_group_title_box(mm_document* d, mm_scene* s, int index, list[int] out):
	mm_node* n = d.nodes[index]
	if (n.group == 0 || d.kind == MM_ARCHITECTURE || mm_flow_collapsed(d, index) || mm_flow_visible_node(d, index) != index): return 0
	if (d.kind == MM_STATE && index_of(n.id, c"@region:") == 0): return 0
	mm_bounds* b = s.nodes[index]
	if (b.w <= 0): return 0
	int previous = mm_node_font_push(d, n)
	mm_text_block* title = mm_node_text(d, n)
	int width = title.width
	int extra = title.height - MM_TEXT_LINE
	mm_text_block_free(title)
	mm_text_set_size(previous)
	if (width <= 0): return 0
	int right = b.x + 16 + width + 12
	if (right > b.x + b.w): right = b.x + b.w
	out.push(b.x)
	out.push(b.y)
	out.push(right)
	out.push(b.y + 40 + extra)
	return 1

# Leaf boxes edges must not enter: drawn leaf nodes and collapsed groups.
int mm_render_obstacle_leaf(mm_document* d, mm_scene* s, int index):
	mm_node* n = d.nodes[index]
	mm_bounds* b = s.nodes[index]
	if (b.w <= 0 || mm_flow_visible_node(d, index) != index): return 0
	return n.group == 0 || mm_flow_collapsed(d, index)

# Whether segment (x1, y1)-(x2, y2) enters box (bx1, by1)-(bx2, by2) shrunk by
# 2px (border contact is fine); curves are sampled.
int mm_render_segment_enters(int x1, int y1, int x2, int y2, int bx1, int by1, int bx2, int by2):
	bx1 = bx1 + 2
	by1 = by1 + 2
	bx2 = bx2 - 2
	by2 = by2 - 2
	if (bx2 <= bx1 || by2 <= by1): return 0
	int lo_x = x1
	int hi_x = x2
	if (hi_x < lo_x):
		lo_x = x2
		hi_x = x1
	int lo_y = y1
	int hi_y = y2
	if (hi_y < lo_y):
		lo_y = y2
		hi_y = y1
	if (hi_x <= bx1 || lo_x >= bx2 || hi_y <= by1 || lo_y >= by2): return 0
	if (x1 == x2 || y1 == y2): return 1
	int steps = (hi_x - lo_x) + (hi_y - lo_y)
	for k in range(steps + 1):
		int x = x1 + (x2 - x1) * k / steps
		int y = y1 + (y2 - y1) * k / steps
		if (x > bx1 && x < bx2 && y > by1 && y < by2): return 1
	return 0

# Collinear overlap of more than 4px between two axis-aligned segments.
int mm_render_segments_overlap(list[int] p, int i, list[int] q, int j):
	int axis = 0
	if (p[i] == p[i + 2] && q[j] == q[j + 2] && p[i] == q[j]): axis = 1
	else if (p[i + 1] != p[i + 3] || q[j + 1] != q[j + 3] || p[i + 1] != q[j + 1]): return 0
	int a1 = p[i + axis]
	int a2 = p[i + 2 + axis]
	if (a2 < a1):
		a1 = p[i + 2 + axis]
		a2 = p[i + axis]
	int b1 = q[j + axis]
	int b2 = q[j + 2 + axis]
	if (b2 < b1):
		b1 = q[j + 2 + axis]
		b2 = q[j + axis]
	int lo = a1
	if (b1 > lo): lo = b1
	int hi = a2
	if (b2 < hi): hi = b2
	return hi - lo > 4

# Draw e (remapped to its visible endpoints) path-only into view and append
# its straight segments to segs, owned by edge index `owner`.
void mm_render_edge_segments(mm_document* d, mm_scene* view, mm_edge* e, int from, int to, int owner, list[int] segs, list[int] seg_edge):
	int original_from = e.from_node
	int original_to = e.to_node
	e.from_node = from
	e.to_node = to
	mm_render_edge(d, view, e)
	e.from_node = original_from
	e.to_node = original_to
	for mm_primitive* p in view.items:
		if (p.kind == MM_LINE && (p.x != p.x2 || p.y != p.y2)):
			segs.push(p.x)
			segs.push(p.y)
			segs.push(p.x2)
			segs.push(p.y2)
			seg_edge.push(owner)
		if (p.points != 0): __w_list_free(cast(__w_list*, p.points))
		free(p.text)
		free(p)
	while (view.items.length > 0): view.items.pop()

# Candidate ports of box b (x, y, dx, dy, cost, side sextuples): the
# preferred port (x, y) leaving along (dx, dy) at no cost, then unless only
# that one is allowed the centers of the other sides (0 top, 1 bottom, 2 left,
# 3 right), spread 16px per earlier use, at half a bend's cost (two bends
# opposite).
void mm_render_port_candidates(mm_bounds* b, int x, int y, int dx, int dy, list[int] used, int node, int only, list[int] ports):
	ports.push(x)
	ports.push(y)
	ports.push(dx)
	ports.push(dy)
	ports.push(0)
	ports.push(-1)
	if (only): return
	for side in range(4):
		int sdx = 0
		int sdy = -1
		if (side == 1): sdy = 1
		if (side >= 2):
			sdy = 0
			sdx = -1
			if (side == 3): sdx = 1
		if (sdx == dx && sdy == dy): continue
		int cost = MM_OBSTACLE_BEND / 2
		if (sdx == 0 - dx && sdy == 0 - dy): cost = MM_OBSTACLE_BEND * 2
		int count = used[node * 4 + side]
		int shift = (count + 1) / 2 * 16
		if (count % 2 == 0): shift = 0 - shift
		int px = b.x + b.w / 2 + shift
		int py = b.y
		if (side == 1): py = b.y + b.h
		if (side >= 2):
			px = b.x
			if (side == 3): px = b.x + b.w
			py = b.y + b.h / 2 + shift
		ports.push(px)
		ports.push(py)
		ports.push(sdx)
		ports.push(sdy)
		ports.push(cost)
		ports.push(side)

# Obstacle routes for every edge the layered channels do not carry
# (same-rank edges, self loops, edges between nodes in different subgraphs,
# edges whose endpoint moved after layout): an edge whose direct route
# enters a node box (its own ends included), a group title area or runs on
# top of an unrelated edge is routed around them on the free grid
# (mm_obstacle_route). Same-rank edges switch to the facing sides. Clear
# direct routes are kept as drawn before.
# Cleared by the routing fixtures to measure the direct routes it replaces.
int mm_render_obstacle_enabled = 1

void mm_render_obstacle_routes(mm_document* d, mm_scene* s):
	if (mm_render_obstacle_enabled == 0 || d.kind == MM_ARCHITECTURE || d.layout_algorithm == 1 || d.edges.length == 0): return
	int count = d.edges.length
	list[int] from_of = new list[int]
	list[int] to_of = new list[int]
	list[int] special = new list[int]
	list[int] segs = new list[int]
	list[int] seg_edge = new list[int]
	mm_scene* view = new mm_scene()
	view.items = new list[mm_primitive*]
	view.nodes = s.nodes
	view.path_only = 1
	int any = 0
	for i in range(count):
		mm_edge* e = d.edges[i]
		int from = mm_flow_visible_node(d, e.from_node)
		int to = mm_flow_visible_node(d, e.to_node)
		if ((d.kind == MM_FLOW && e.stroke == 2) || (from == to && e.from_node != e.to_node)):
			from_of.push(-1)
			to_of.push(-1)
			special.push(0)
			continue
		from_of.push(from)
		to_of.push(to)
		mm_bounds* a = s.nodes[from]
		mm_bounds* b = s.nodes[to]
		mm_edge_route* r = mm_edge_route_of(a, e, 1)
		mm_edge_route_clear_points(r)
		int tx = 0
		int ty = 0
		int channel = from != to && from == e.from_node && to == e.to_node && mm_route_usable(r, a, b, mm_edge_horizontal(d, e), &tx, &ty)
		# Class lollipop interfaces (shape 28) attach inside their own box.
		int lollipop = d.nodes[from].shape == 28 || d.nodes[to].shape == 28
		special.push(channel == 0 && lollipop == 0)
		if (channel == 0 && lollipop == 0): any = 1
		mm_render_edge_segments(d, view, e, from, to, i, segs, seg_edge)
	if (any == 0):
		mm_route_edge_scene_release(view)
		__w_list_free(cast(__w_list*, from_of))
		__w_list_free(cast(__w_list*, to_of))
		__w_list_free(cast(__w_list*, special))
		__w_list_free(cast(__w_list*, segs))
		__w_list_free(cast(__w_list*, seg_edge))
		return
	# Obstacles: leaf boxes (owner = node) and group title areas (owner = group).
	list[int] boxes = new list[int]
	list[int] box_owner = new list[int]
	for i in range(d.nodes.length):
		if (mm_render_obstacle_leaf(d, s, i)):
			mm_bounds* b = s.nodes[i]
			boxes.push(b.x)
			boxes.push(b.y)
			boxes.push(b.x + b.w)
			boxes.push(b.y + b.h)
			box_owner.push(i)
		else if (mm_group_title_box(d, s, i, boxes)): box_owner.push(i)
	# Same-rank edges leave and enter by the facing sides, spread per side.
	list[int] side_count = new list[int]
	list[int] side_used = new list[int]
	for i in range(d.nodes.length * 4):
		side_count.push(0)
		side_used.push(0)
	list[int] side_of = new list[int]
	for i in range(count):
		side_of.push(-1)
		if (special[i] == 0 || from_of[i] == to_of[i]): continue
		mm_bounds* a = s.nodes[from_of[i]]
		mm_bounds* b = s.nodes[to_of[i]]
		int horizontal = mm_edge_horizontal(d, d.edges[i])
		int side = -1
		# Sides: 0 top, 1 bottom, 2 left, 3 right.
		if (horizontal == 0 && a.y < b.y + b.h && b.y < a.y + a.h):
			side = 3
			if (b.x + b.w / 2 < a.x + a.w / 2): side = 2
		else if (horizontal && a.x < b.x + b.w && b.x < a.x + a.w):
			side = 1
			if (b.y + b.h / 2 < a.y + a.h / 2): side = 0
		if (side < 0): continue
		side_of[i] = side
		side_count[from_of[i] * 4 + side] = side_count[from_of[i] * 4 + side] + 1
		side_count[to_of[i] * 4 + (side ^ 1)] = side_count[to_of[i] * 4 + (side ^ 1)] + 1
	list[int] rects = new list[int]
	list[int] seg_kind = new list[int]
	list[int] path = new list[int]
	list[int] from_ports = new list[int]
	list[int] to_ports = new list[int]
	list[int] starts = new list[int]
	list[int] targets = new list[int]
	list[int] alt_used = new list[int]
	for i in range(d.nodes.length * 4): alt_used.push(0)
	int routed = 0
	for i in range(count):
		if (special[i] == 0): continue
		mm_edge* e = d.edges[i]
		int from = from_of[i]
		int to = to_of[i]
		# Is the direct route clear?
		int blocked = side_of[i] >= 0
		for k in range(seg_edge.length):
			if (blocked || seg_edge[k] != i): continue
			int at = k * 4
			for o in range(box_owner.length):
				int owner = box_owner[o]
				if (d.nodes[owner].group && (owner == from || owner == to) && mm_render_obstacle_leaf(d, s, owner) == 0): continue
				# The ports sit on the endpoint borders; only entering them counts.
				if (mm_render_segment_enters(segs[at], segs[at + 1], segs[at + 2], segs[at + 3], boxes[o * 4], boxes[o * 4 + 1], boxes[o * 4 + 2], boxes[o * 4 + 3])):
					blocked = 1
					break
			if (blocked): break
			for m in range(seg_edge.length):
				int other = seg_edge[m]
				if (other < 0 || other == i): continue
				if (from_of[other] == from || from_of[other] == to || to_of[other] == from || to_of[other] == to): continue
				if (mm_render_segments_overlap(segs, at, segs, m * 4)):
					blocked = 1
					break
		if (blocked == 0 || routed >= MM_OBSTACLE_EDGE_LIMIT): continue
		mm_bounds* a = s.nodes[from]
		mm_bounds* b = s.nodes[to]
		int horizontal = mm_edge_horizontal(d, e)
		# Ports and their outward directions.
		int ax = 0
		int ay = 0
		int bx = 0
		int by = 0
		int adx = 0
		int ady = 0
		int bdx = 0
		int bdy = 0
		int side = side_of[i]
		if (from == to):
			ax = a.x + a.w
			ay = a.y + a.h / 3
			bx = ax
			by = a.y + a.h * 2 / 3
			adx = 1
			bdx = 1
		else if (side >= 0):
			int from_key = from * 4 + side
			int to_key = to * 4 + (side ^ 1)
			int from_shift = (side_used[from_key] * 2 - (side_count[from_key] - 1)) * 8
			int to_shift = (side_used[to_key] * 2 - (side_count[to_key] - 1)) * 8
			side_used[from_key] = side_used[from_key] + 1
			side_used[to_key] = side_used[to_key] + 1
			if (side >= 2):
				adx = 1
				if (side == 2): adx = -1
				bdx = 0 - adx
				ax = a.x + a.w
				if (side == 2): ax = a.x
				bx = b.x
				if (side == 2): bx = b.x + b.w
				ay = a.y + a.h / 2 + from_shift
				by = b.y + b.h / 2 + to_shift
			else:
				ady = 1
				if (side == 0): ady = -1
				bdy = 0 - ady
				ay = a.y + a.h
				if (side == 0): ay = a.y
				by = b.y
				if (side == 0): by = b.y + b.h
				ax = a.x + a.w / 2 + from_shift
				bx = b.x + b.w / 2 + to_shift
		else:
			# The direct route's ports, leaving along the rank axis.
			int first = -1
			int last = -1
			for k in range(seg_edge.length):
				if (seg_edge[k] != i): continue
				if (first < 0): first = k
				last = k
			if (first < 0): continue
			ax = segs[first * 4]
			ay = segs[first * 4 + 1]
			bx = segs[last * 4 + 2]
			by = segs[last * 4 + 3]
			if (horizontal):
				adx = 1
				if (b.x < a.x): adx = -1
				bdx = 0 - adx
			else:
				ady = 1
				if (b.y < a.y): ady = -1
				bdy = 0 - ady
		while (from_ports.length > 0): from_ports.pop()
		while (to_ports.length > 0): to_ports.pop()
		mm_render_port_candidates(a, ax, ay, adx, ady, alt_used, from, from == to, from_ports)
		mm_render_port_candidates(b, bx, by, bdx, bdy, alt_used, to, from == to, to_ports)
		while (starts.length > 0): starts.pop()
		while (targets.length > 0): targets.pop()
		for pass in range(2):
			list[int] ports = from_ports
			list[int] ends = starts
			if (pass):
				ports = to_ports
				ends = targets
			for k in range(ports.length / 6):
				int at = k * 6
				ends.push(ports[at] + ports[at + 2] * MM_OBSTACLE_STUB)
				ends.push(ports[at + 1] + ports[at + 3] * MM_OBSTACLE_STUB)
				ends.push(ports[at + 3] != 0)
				ends.push(ports[at + 4])
		while (rects.length > 0): rects.pop()
		for o in range(box_owner.length):
			int owner = box_owner[o]
			if (d.nodes[owner].group && (owner == from || owner == to) && mm_render_obstacle_leaf(d, s, owner) == 0): continue
			rects.push(boxes[o * 4] - MM_OBSTACLE_MARGIN)
			rects.push(boxes[o * 4 + 1] - MM_OBSTACLE_MARGIN)
			rects.push(boxes[o * 4 + 2] + MM_OBSTACLE_MARGIN)
			rects.push(boxes[o * 4 + 3] + MM_OBSTACLE_MARGIN)
		while (seg_kind.length > 0): seg_kind.pop()
		for k in range(seg_edge.length):
			int other = seg_edge[k]
			int kind = 2
			if (other < 0 || other == i): kind = 0
			else if (from_of[other] == from || from_of[other] == to || to_of[other] == from || to_of[other] == to): kind = 1
			seg_kind.push(kind)
		while (path.length > 0): path.pop()
		int chosen_from = 0
		int chosen_to = 0
		list[int] chosen = list[int]{0, 0}
		int found = mm_obstacle_route(rects, segs, seg_kind, starts, targets, path, chosen)
		chosen_from = chosen[0] * 6
		chosen_to = chosen[1] * 6
		__w_list_free(cast(__w_list*, chosen))
		if (found == 0): continue
		routed = routed + 1
		ax = from_ports[chosen_from]
		ay = from_ports[chosen_from + 1]
		adx = from_ports[chosen_from + 2]
		ady = from_ports[chosen_from + 3]
		bx = to_ports[chosen_to]
		by = to_ports[chosen_to + 1]
		bdx = to_ports[chosen_to + 2]
		bdy = to_ports[chosen_to + 3]
		if (from_ports[chosen_from + 5] >= 0): alt_used[from * 4 + from_ports[chosen_from + 5]] = alt_used[from * 4 + from_ports[chosen_from + 5]] + 1
		if (to_ports[chosen_to + 5] >= 0): alt_used[to * 4 + to_ports[chosen_to + 5]] = alt_used[to * 4 + to_ports[chosen_to + 5]] + 1
		mm_edge_route* r = mm_edge_route_of(a, e, 1)
		r.points = new list[int]
		mm_route_point_push(r.points, ax, ay)
		for k in range(path.length / 2): mm_route_point_push(r.points, path[k * 2], path[k * 2 + 1])
		mm_route_point_push(r.points, bx, by)
		r.points_from_x = a.x
		r.points_from_y = a.y
		r.points_to_x = b.x
		r.points_to_y = b.y
		r.from_dx = adx
		r.from_dy = ady
		r.to_dx = bdx
		r.to_dy = bdy
		r.points_horizontal = bdy == 0
		# The new route replaces the direct one among the occupied segments.
		for k in range(seg_edge.length):
			if (seg_edge[k] == i): seg_edge[k] = -1
		mm_render_edge_segments(d, view, e, from, to, i, segs, seg_edge)
	mm_route_edge_scene_release(view)
	__w_list_free(cast(__w_list*, from_of))
	__w_list_free(cast(__w_list*, to_of))
	__w_list_free(cast(__w_list*, special))
	__w_list_free(cast(__w_list*, segs))
	__w_list_free(cast(__w_list*, seg_edge))
	__w_list_free(cast(__w_list*, boxes))
	__w_list_free(cast(__w_list*, box_owner))
	__w_list_free(cast(__w_list*, side_count))
	__w_list_free(cast(__w_list*, side_used))
	__w_list_free(cast(__w_list*, side_of))
	__w_list_free(cast(__w_list*, rects))
	__w_list_free(cast(__w_list*, seg_kind))
	__w_list_free(cast(__w_list*, path))
	__w_list_free(cast(__w_list*, from_ports))
	__w_list_free(cast(__w_list*, to_ports))
	__w_list_free(cast(__w_list*, starts))
	__w_list_free(cast(__w_list*, targets))
	__w_list_free(cast(__w_list*, alt_used))

void mm_render_graph(mm_document* d, mm_scene* s):
	mm_render_groups(d, s, -1)
	if (d.kind != MM_ARCHITECTURE):
		mm_render_ports(d, s)
		mm_render_obstacle_routes(d, s)
		s.labels = mm_render_label_grid(d, s)
	for mm_edge* e in d.edges:
		int start = s.items.length
		int from = mm_flow_visible_node(d, e.from_node)
		int to = mm_flow_visible_node(d, e.to_node)
		if (from == e.from_node && to == e.to_node): mm_render_edge(d, s, e)
		else if (from != to):
			int original_from = e.from_node
			int original_to = e.to_node
			e.from_node = from
			e.to_node = to
			mm_render_edge(d, s, e)
			e.from_node = original_from
			e.to_node = original_to
		mm_style_edge(d, s, e, start)
	mm_label_grid_free(s.labels)
	s.labels = 0
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.group || mm_flow_visible_node(d, i) != i): continue
		int previous = mm_node_font_push(d, n)
		mm_render_node(d, s, i)
		mm_text_set_size(previous)
	if (d.kind == MM_CLASS || d.kind == MM_STATE): mm_uml_notes(d, s)

# Primitives from the scene's current bounds, for every geometry family.
void mm_render_draw(mm_document* d, mm_scene* s):
	if (d.kind == MM_C4): mm_c4_draw(d, s)
	else if (d.kind == MM_SWIMLANE): mm_workflow_draw(d, s)
	else: mm_render_graph(d, s)

# Failed parses cannot produce a misleading partial preview.
mm_scene* mm_render_diagram(mm_document* d):
	if (d.error == 0 && d.kind >= MM_SEQUENCE && d.kind <= MM_ZENUML): return mm_narrative_render(d)
	if (d.error != 0): return 0
	if (mm_agent_has_collapsed(d)):
		list[int] slots = new list[int]
		mm_document* view = mm_agent_project(d, slots)
		mm_scene* folded = mm_render_diagram(view)
		if (folded != 0): mm_agent_unproject(folded, slots)
		mm_document_free(view)
		__w_list_free(cast(__w_list*, slots))
		return folded
	if (d.kind == MM_SWIMLANE || d.kind == MM_C4):
		# Saved geometry applies between the family's layout and drawing.
		mm_scene* placed = 0
		if (d.kind == MM_C4): placed = mm_c4_layout(d)
		else: placed = mm_workflow_layout(d)
		mm_positions_apply(d, placed)
		mm_render_draw(d, placed)
		return placed
	if (d.kind == MM_EVENT_MODEL): return mm_workflow_render(d)
	if (d.kind == MM_BLOCK): return mm_blocks_render(d)
	if (d.kind == MM_GITGRAPH): return mm_git_render(d)
	if (d.kind == MM_TREEVIEW): return mm_treeview_render(d)
	if (d.kind == MM_ISHIKAWA): return mm_ishikawa_render(d)
	if (d.kind == MM_CYNEFIN): return mm_cynefin_render(d)
	if (d.kind == MM_WARDLEY): return mm_wardley_render(d)
	if (d.error == 0 && (d.kind == MM_MINDMAP || d.kind == MM_KANBAN)): return mm_hierarchy_render(d)
	if (d.error != 0): return 0
	if (d.kind >= MM_PIE && d.kind <= MM_PACKET): return mm_data_render(d)
	if (d.kind >= MM_RAIL_IR && d.kind <= MM_RAIL_PEG): return mm_rail_render(d)
	mm_scene* s = new mm_scene()
	s.items = new list[mm_primitive*]
	s.nodes = new list[mm_bounds*]
	s.width = 240
	s.height = 160
	if (d.kind == MM_ARCHITECTURE):
		mm_measure(d, s)
		mm_arch_layout(d, s)
	else: mm_layout(d, s)
	mm_positions_apply(d, s)
	mm_render_graph(d, s)
	return s

# Apply document metadata once, after the family's own layout has completed.
void mm_render_metadata(mm_document* d, mm_scene* s):
	# `fa:fa-name` label prefixes become native pictograms (icons.w).
	if (d.kind == MM_FLOW): mm_fa_glyphs(s)
	if (d.title[0] != 0 && s.has_title == 0):
		for mm_primitive* p in s.items:
			p.y = p.y + 40
			p.y2 = p.y2 + 40
			if (p.points != 0):
				for i in range(p.points.length):
					if (i % 2): p.points[i] = p.points[i] + 40
		for mm_bounds* b in s.nodes: b.y = b.y + 40
		s.height = s.height + 40
		mm_text(s, 40, 12, d.title)
		mm_primitive* title = s.items[s.items.length - 1]
		title.role = MM_ROLE_TITLE
		s.has_title = 1
	s.accessibility_title = strclone(d.accessibility_title)
	if (s.accessibility_title[0] == 0):
		free(s.accessibility_title)
		s.accessibility_title = strclone(d.title)
	s.accessibility_description = strclone(d.accessibility_description)
	mm_style_scene(d, s)

# fontSize configuration scales every label measured and drawn for d.
mm_scene* mm_render(mm_document* d):
	int previous = mm_text_set_size(d.font_size)
	mm_scene* s = mm_render_diagram(d)
	if (s != 0): mm_render_metadata(d, s)
	mm_text_set_size(previous)
	return s

# Scene bounds use final coordinates, including the optional title gutter.
void mm_render_graph_refresh(mm_document* d, mm_scene* s):
	for mm_primitive* p in s.items:
		if (p.points != 0): __w_list_free(cast(__w_list*, p.points))
		free(p.text)
		if (p.href != 0): free(p.href)
		if (p.href_target != 0): free(p.href_target)
		if (p.tooltip != 0): free(p.tooltip)
		free(p)
	while (s.items.length > 0): s.items.pop()
	free(s.accessibility_title)
	free(s.accessibility_description)
	s.accessibility_title = 0
	s.accessibility_description = 0
	int offset = mm_position_title_offset(d)
	for mm_bounds* b in s.nodes: b.y = b.y - offset
	s.width = 240
	s.height = 160
	s.has_title = 0
	s.has_background = 0
	s.background = 0
	if (s.font_family != 0): free(s.font_family)
	s.font_family = 0
	s.has_effects = 0
	int previous = mm_text_set_size(d.font_size)
	mm_render_draw(d, s)
	mm_render_metadata(d, s)
	mm_text_set_size(previous)
