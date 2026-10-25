# Semantic model equality for every Mermaid family: the round-trip
# contract of the canonical serializer (parse -> serialize -> parse yields
# the same model). Source bytes, offsets, comment ranges and ignored
# configuration paths are not semantic and are never compared; everything
# else the parsers store is. mm_document_diff names the first difference.
import libs.extras.mermaid.model
import libs.extras.mermaid.style

struct mm_diff:
	# Null until the first difference is found.
	string_builder* text

void mm_diff_fail(mm_diff* df, char* what, char* detail):
	if (df.text != 0): return
	df.text = string_from(what)
	if (detail != 0):
		string_append(df.text, c": ")
		string_append(df.text, detail)

void mm_diff_int(mm_diff* df, char* what, int a, int b):
	if (df.text != 0 || a == b): return
	string_builder* detail = string_new()
	string_append_int(detail, a)
	string_append(detail, c" != ")
	string_append_int(detail, b)
	mm_diff_fail(df, what, detail.data)
	string_free(detail)

# Null and empty text are equal: parsers use either for "absent".
void mm_diff_text(mm_diff* df, char* what, char* a, char* b):
	if (df.text != 0): return
	char* left = a
	char* right = b
	if (left == 0): left = c""
	if (right == 0): right = c""
	if (strcmp(left, right) == 0): return
	string_builder* detail = string_from(c"\"")
	string_append(detail, left)
	string_append(detail, c"\" != \"")
	string_append(detail, right)
	string_append(detail, c"\"")
	mm_diff_fail(df, what, detail.data)
	string_free(detail)

# Presence matters where null means "not configured" (links, URLs).
void mm_diff_optional(mm_diff* df, char* what, char* a, char* b):
	if (df.text != 0): return
	if ((a == 0) != (b == 0)):
		mm_diff_fail(df, what, c"presence differs")
		return
	mm_diff_text(df, what, a, b)

void mm_diff_ints(mm_diff* df, char* what, list[int] a, list[int] b):
	if (df.text != 0): return
	if ((a == 0) != (b == 0)):
		mm_diff_fail(df, what, c"presence differs")
		return
	if (a == 0): return
	mm_diff_int(df, what, a.length, b.length)
	if (df.text != 0): return
	for i in range(a.length): mm_diff_int(df, what, a[i], b[i])

void mm_diff_texts(mm_diff* df, char* what, list[char*] a, list[char*] b):
	if (df.text != 0): return
	int al = 0
	int bl = 0
	if (a != 0): al = a.length
	if (b != 0): bl = b.length
	mm_diff_int(df, what, al, bl)
	if (df.text != 0): return
	for i in range(al): mm_diff_text(df, what, a[i], b[i])

char* mm_diff_font(mm_document* d, int family):
	if (family < 1 || family > d.style_fonts.length): return c""
	return d.style_fonts[family - 1]

# Only the properties a mask bit selects are meaningful.
void mm_diff_style(mm_diff* df, char* what, mm_document* da, mm_style* a, mm_document* db, mm_style* b):
	if (df.text != 0): return
	mm_diff_int(df, what, a.mask, b.mask)
	int m = a.mask
	if (m & MM_STYLE_FILL): mm_diff_int(df, what, a.fill, b.fill)
	if (m & MM_STYLE_STROKE): mm_diff_int(df, what, a.stroke, b.stroke)
	if (m & MM_STYLE_TEXT): mm_diff_int(df, what, a.text, b.text)
	if (m & MM_STYLE_WIDTH): mm_diff_int(df, what, a.width, b.width)
	if (m & MM_STYLE_DASH):
		mm_diff_int(df, what, a.dash, b.dash)
		mm_diff_int(df, what, a.gap, b.gap)
	if (m & MM_STYLE_OPACITY): mm_diff_int(df, what, a.opacity, b.opacity)
	if (m & MM_STYLE_FILL_OPACITY): mm_diff_int(df, what, a.fill_opacity, b.fill_opacity)
	if (m & MM_STYLE_WEIGHT): mm_diff_int(df, what, a.font & MM_TEXT_BOLD, b.font & MM_TEXT_BOLD)
	if (m & MM_STYLE_ITALIC): mm_diff_int(df, what, a.font & MM_TEXT_ITALIC, b.font & MM_TEXT_ITALIC)
	if (m & MM_STYLE_SIZE): mm_diff_int(df, what, a.font_size, b.font_size)
	if (m & MM_STYLE_FAMILY): mm_diff_text(df, what, mm_diff_font(da, a.family), mm_diff_font(db, b.family))
	if (m & MM_STYLE_RADIUS): mm_diff_int(df, what, a.radius, b.radius)

void mm_diff_properties(mm_diff* df, char* what, list[mm_property*] a, list[mm_property*] b):
	if (df.text != 0): return
	int al = 0
	int bl = 0
	if (a != 0): al = a.length
	if (b != 0): bl = b.length
	mm_diff_int(df, what, al, bl)
	if (df.text != 0): return
	for i in range(al):
		mm_diff_text(df, what, a[i].key, b[i].key)
		mm_diff_text(df, what, a[i].value, b[i].value)
		mm_diff_int(df, what, a[i].type, b[i].type)

void mm_diff_node(mm_diff* df, mm_document* da, mm_node* a, mm_document* db, mm_node* b):
	mm_diff_text(df, c"node id", a.id, b.id)
	mm_diff_text(df, c"node label", a.label, b.label)
	mm_diff_int(df, c"node shape", a.shape, b.shape)
	mm_diff_int(df, c"node attribute count", a.attributes.length, b.attributes.length)
	if (df.text != 0): return
	for i in range(a.attributes.length):
		mm_attribute* x = a.attributes[i]
		mm_attribute* y = b.attributes[i]
		mm_diff_text(df, c"attribute type", x.type_name, y.type_name)
		mm_diff_text(df, c"attribute name", x.name, y.name)
		mm_diff_text(df, c"attribute keys", x.keys, y.keys)
		mm_diff_text(df, c"attribute comment", x.comment, y.comment)
	mm_diff_int(df, c"node member count", a.members.length, b.members.length)
	if (df.text != 0): return
	for i in range(a.members.length):
		mm_diff_text(df, c"member", a.members[i].text, b.members[i].text)
		mm_diff_int(df, c"member method", a.members[i].method, b.members[i].method)
	mm_diff_text(df, c"node annotation", a.annotation, b.annotation)
	mm_diff_int(df, c"node value_x", a.value_x, b.value_x)
	mm_diff_int(df, c"node value_y", a.value_y, b.value_y)
	mm_diff_int(df, c"node parent", a.parent, b.parent)
	mm_diff_int(df, c"node group", a.group, b.group)
	mm_diff_int(df, c"node declared", a.declared, b.declared)
	mm_diff_text(df, c"node direction", a.direction, b.direction)
	mm_diff_style(df, c"node style", da, &a.style, db, &b.style)
	mm_diff_text(df, c"node classes", a.style_classes, b.style_classes)
	mm_diff_text(df, c"node role", a.role, b.role)
	mm_diff_int(df, c"node global", a.global_node, b.global_node)
	mm_diff_properties(df, c"node metadata", a.metadata, b.metadata)
	mm_diff_optional(df, c"node link", a.link, b.link)
	mm_diff_optional(df, c"node link target", a.link_target, b.link_target)
	mm_diff_optional(df, c"node tooltip", a.tooltip, b.tooltip)
	mm_diff_optional(df, c"node callback", a.callback, b.callback)

void mm_diff_edge(mm_diff* df, mm_document* da, mm_edge* a, mm_document* db, mm_edge* b):
	mm_diff_int(df, c"edge from", a.from_node, b.from_node)
	mm_diff_int(df, c"edge to", a.to_node, b.to_node)
	mm_diff_int(df, c"edge from port", a.from_port, b.from_port)
	mm_diff_int(df, c"edge to port", a.to_port, b.to_port)
	mm_diff_text(df, c"edge label", a.label, b.label)
	mm_diff_int(df, c"edge dashed", a.dashed, b.dashed)
	mm_diff_int(df, c"edge arrow", a.arrow, b.arrow)
	mm_diff_int(df, c"edge left card", a.left_card, b.left_card)
	mm_diff_int(df, c"edge right card", a.right_card, b.right_card)
	mm_diff_int(df, c"edge left marker", a.left_marker, b.left_marker)
	mm_diff_int(df, c"edge right marker", a.right_marker, b.right_marker)
	mm_diff_text(df, c"edge left label", a.left_label, b.left_label)
	mm_diff_text(df, c"edge right label", a.right_label, b.right_label)
	mm_diff_int(df, c"edge scope", a.scope, b.scope)
	mm_diff_style(df, c"edge style", da, &a.style, db, &b.style)
	mm_diff_optional(df, c"edge id", a.id, b.id)
	mm_diff_int(df, c"edge label dx", a.label_dx, b.label_dx)
	mm_diff_int(df, c"edge label dy", a.label_dy, b.label_dy)
	mm_diff_int(df, c"edge min length", a.min_length, b.min_length)
	mm_diff_properties(df, c"edge metadata", a.metadata, b.metadata)
	mm_diff_int(df, c"edge stroke", a.stroke, b.stroke)
	mm_diff_int(df, c"edge extra rank", a.extra_rank, b.extra_rank)
	mm_diff_int(df, c"edge animate", a.animate, b.animate)
	mm_diff_int(df, c"edge curve", a.curve, b.curve)

void mm_diff_event(mm_diff* df, char* what, mm_narrative_event* a, mm_narrative_event* b):
	mm_diff_int(df, what, a.kind, b.kind)
	mm_diff_int(df, what, a.from_node, b.from_node)
	mm_diff_int(df, what, a.to_node, b.to_node)
	mm_diff_text(df, what, a.label, b.label)
	mm_diff_text(df, what, a.detail, b.detail)
	mm_diff_text(df, what, a.section, b.section)
	mm_diff_int(df, what, a.value, b.value)
	mm_diff_int(df, what, a.start, b.start)
	mm_diff_int(df, what, a.end, b.end)
	mm_diff_int(df, what, a.dashed, b.dashed)
	mm_diff_int(df, what, a.arrow, b.arrow)
	mm_diff_int(df, what, a.central, b.central)

void mm_diff_data_item(mm_diff* df, char* what, mm_document* da, mm_data_item* a, mm_document* db, mm_data_item* b, int rule):
	mm_diff_text(df, what, a.id, b.id)
	mm_diff_text(df, what, a.label, b.label)
	mm_diff_text(df, what, a.target, b.target)
	mm_diff_int(df, what, a.kind, b.kind)
	mm_diff_int(df, what, a.a, b.a)
	# A style rule's b is its source offset.
	if (rule == 0): mm_diff_int(df, what, a.b, b.b)
	mm_diff_int(df, what, a.parent, b.parent)
	mm_diff_int(df, what, a.depth, b.depth)
	mm_diff_ints(df, what, a.values, b.values)
	mm_diff_texts(df, what, a.point_labels, b.point_labels)
	mm_diff_style(df, what, da, &a.style, db, &b.style)
	mm_diff_int(df, what, a.radius, b.radius)

void mm_diff_data(mm_diff* df, mm_document* da, mm_data_chart* a, mm_document* db, mm_data_chart* b):
	if (df.text != 0): return
	if ((a == 0) != (b == 0)):
		mm_diff_fail(df, c"data chart", c"presence differs")
		return
	if (a == 0): return
	mm_diff_text(df, c"chart title", a.title, b.title)
	mm_diff_text(df, c"chart x label", a.x_label, b.x_label)
	mm_diff_text(df, c"chart x end", a.x_end, b.x_end)
	mm_diff_text(df, c"chart y label", a.y_label, b.y_label)
	mm_diff_text(df, c"chart y end", a.y_end, b.y_end)
	mm_diff_int(df, c"chart low", a.low, b.low)
	mm_diff_int(df, c"chart high", a.high, b.high)
	mm_diff_int(df, c"chart explicit low", a.explicit_low, b.explicit_low)
	mm_diff_int(df, c"chart explicit high", a.explicit_high, b.explicit_high)
	mm_diff_int(df, c"chart horizontal", a.horizontal, b.horizontal)
	mm_diff_int(df, c"chart x numeric", a.x_numeric, b.x_numeric)
	mm_diff_int(df, c"chart x low", a.x_low, b.x_low)
	mm_diff_int(df, c"chart x high", a.x_high, b.x_high)
	mm_diff_int(df, c"chart show data", a.show_data, b.show_data)
	mm_diff_int(df, c"chart ticks", a.ticks, b.ticks)
	mm_diff_int(df, c"chart polygon", a.polygon, b.polygon)
	mm_diff_int(df, c"chart legend", a.legend, b.legend)
	mm_diff_int(df, c"chart item count", a.items.length, b.items.length)
	if (df.text != 0): return
	for i in range(a.items.length): mm_diff_data_item(df, c"chart item", da, a.items[i], db, b.items[i], 0)
	int ar = 0
	int br = 0
	if (a.rules != 0): ar = a.rules.length
	if (b.rules != 0): br = b.rules.length
	mm_diff_int(df, c"chart rule count", ar, br)
	if (df.text != 0): return
	for i in range(ar): mm_diff_data_item(df, c"chart rule", da, a.rules[i], db, b.rules[i], 1)

void mm_diff_railroad(mm_diff* df, mm_rail_grammar* a, mm_rail_grammar* b):
	if (df.text != 0): return
	if ((a == 0) != (b == 0)):
		mm_diff_fail(df, c"railroad", c"presence differs")
		return
	if (a == 0): return
	mm_diff_text(df, c"railroad title", a.title, b.title)
	mm_diff_int(df, c"railroad expression count", a.expressions.length, b.expressions.length)
	mm_diff_int(df, c"railroad rule count", a.rules.length, b.rules.length)
	if (df.text != 0): return
	for i in range(a.expressions.length):
		mm_rail_expr* x = a.expressions[i]
		mm_rail_expr* y = b.expressions[i]
		mm_diff_int(df, c"railroad kind", x.kind, y.kind)
		mm_diff_text(df, c"railroad text", x.text, y.text)
		mm_diff_ints(df, c"railroad children", x.children, y.children)
		mm_diff_int(df, c"railroad minimum", x.minimum, y.minimum)
		mm_diff_int(df, c"railroad maximum", x.maximum, y.maximum)
		mm_diff_int(df, c"railroad target", x.target, y.target)
	for i in range(a.rules.length):
		mm_diff_text(df, c"railroad rule name", a.rules[i].name, b.rules[i].name)
		mm_diff_int(df, c"railroad rule expression", a.rules[i].expression, b.rules[i].expression)

void mm_diff_gantt(mm_diff* df, mm_gantt_settings* a, mm_gantt_settings* b):
	if (df.text != 0): return
	if ((a == 0) != (b == 0)):
		mm_diff_fail(df, c"gantt settings", c"presence differs")
		return
	if (a == 0): return
	mm_diff_text(df, c"gantt date format", a.date_format, b.date_format)
	mm_diff_text(df, c"gantt axis format", a.axis_format, b.axis_format)
	mm_diff_int(df, c"gantt minutes", a.minutes, b.minutes)
	mm_diff_int(df, c"gantt weekends", a.weekends, b.weekends)
	mm_diff_int(df, c"gantt weekend start", a.weekend_start, b.weekend_start)
	mm_diff_int(df, c"gantt weekday mask", a.weekday_mask, b.weekday_mask)
	mm_diff_ints(df, c"gantt excluded", a.excluded, b.excluded)
	mm_diff_ints(df, c"gantt included", a.included, b.included)
	mm_diff_int(df, c"gantt today", a.today, b.today)
	mm_diff_int(df, c"gantt promoted", a.promoted, b.promoted)
	mm_diff_int(df, c"gantt week start", a.week_start, b.week_start)
	mm_diff_int(df, c"gantt tick count", a.tick_count, b.tick_count)
	mm_diff_int(df, c"gantt tick unit", a.tick_unit, b.tick_unit)
	mm_diff_int(df, c"gantt compact", a.compact, b.compact)
	mm_diff_int(df, c"gantt inclusive", a.inclusive, b.inclusive)
	mm_diff_int(df, c"gantt top axis", a.top_axis, b.top_axis)

# Resolved configuration compares as a set of key/value pairs.
void mm_diff_config(mm_diff* df, mm_document* a, mm_document* b):
	if (df.text != 0): return
	int al = 0
	int bl = 0
	if (a.config != 0): al = a.config.length
	if (b.config != 0): bl = b.config.length
	for i in range(al):
		mm_property* property = a.config[i]
		char* other = mm_config_value(b, property.key)
		if (other == 0):
			mm_diff_fail(df, c"config key missing", property.key)
			return
		mm_diff_text(df, property.key, property.value, other)
	mm_diff_int(df, c"config count", al, bl)

# Theme state is compared only when a theme is configured.
void mm_diff_theme(mm_diff* df, mm_document* a, mm_document* b):
	mm_diff_int(df, c"theme", a.theme, b.theme)
	mm_diff_ints(df, c"theme values", a.theme_values, b.theme_values)
	mm_diff_style(df, c"palette", a, &a.palette, b, &b.palette)
	mm_diff_int(df, c"background", a.background, b.background)
	mm_diff_int(df, c"palette line", a.palette_line, b.palette_line)
	mm_diff_int(df, c"palette label", a.palette_label, b.palette_label)

void mm_diff_document(mm_diff* df, mm_document* a, mm_document* b):
	if (a == 0 || b == 0):
		mm_diff_fail(df, c"document", c"missing")
		return
	mm_diff_optional(df, c"error", a.error, b.error)
	mm_diff_int(df, c"kind", a.kind, b.kind)
	mm_diff_int(df, c"graph variant", a.graph_variant, b.graph_variant)
	mm_diff_text(df, c"direction", a.direction, b.direction)
	mm_diff_text(df, c"title", a.title, b.title)
	mm_diff_text(df, c"accessibility title", a.accessibility_title, b.accessibility_title)
	mm_diff_text(df, c"accessibility description", a.accessibility_description, b.accessibility_description)
	mm_diff_int(df, c"node count", a.nodes.length, b.nodes.length)
	if (df.text != 0): return
	for i in range(a.nodes.length):
		mm_diff_node(df, a, a.nodes[i], b, b.nodes[i])
		if (df.text != 0):
			string_append(df.text, c" (node ")
			string_append(df.text, a.nodes[i].id)
			string_append(df.text, c")")
			return
	mm_diff_int(df, c"edge count", a.edges.length, b.edges.length)
	if (df.text != 0): return
	for i in range(a.edges.length):
		mm_diff_edge(df, a, a.edges[i], b, b.edges[i])
		if (df.text != 0):
			string_append(df.text, c" (edge ")
			string_append_int(df.text, i)
			string_append(df.text, c")")
			return
	mm_diff_int(df, c"note count", a.notes.length, b.notes.length)
	if (df.text != 0): return
	for i in range(a.notes.length):
		mm_diff_int(df, c"note node", a.notes[i].node, b.notes[i].node)
		mm_diff_int(df, c"note side", a.notes[i].side, b.notes[i].side)
		mm_diff_text(df, c"note text", a.notes[i].text, b.notes[i].text)
	mm_diff_int(df, c"event count", a.narrative.length, b.narrative.length)
	if (df.text != 0): return
	for i in range(a.narrative.length):
		mm_diff_event(df, c"event", a.narrative[i], b.narrative[i])
		if (df.text != 0):
			string_append(df.text, c" (event ")
			string_append_int(df.text, i)
			string_append(df.text, c")")
			return
	mm_diff_int(df, c"box count", a.boxes.length, b.boxes.length)
	if (df.text != 0): return
	for i in range(a.boxes.length): mm_diff_event(df, c"box", a.boxes[i], b.boxes[i])
	mm_diff_int(df, c"numbered", a.narrative_numbered, b.narrative_numbered)
	mm_diff_data(df, a, a.data, b, b.data)
	mm_diff_railroad(df, a.railroad, b.railroad)
	mm_diff_gantt(df, a.gantt, b.gantt)
	mm_diff_int(df, c"style class count", a.style_definitions.length, b.style_definitions.length)
	if (df.text != 0): return
	for i in range(a.style_definitions.length):
		mm_diff_text(df, c"style class name", a.style_definitions[i].name, b.style_definitions[i].name)
		mm_diff_style(df, c"style class", a, &a.style_definitions[i].style, b, &b.style_definitions[i].style)
	mm_diff_style(df, c"edge default style", a, &a.edge_style, b, &b.edge_style)
	mm_diff_theme(df, a, b)
	mm_diff_int(df, c"layout", a.layout_algorithm, b.layout_algorithm)
	mm_diff_int(df, c"packet bits", a.packet_bits, b.packet_bits)
	mm_diff_int(df, c"packet msb", a.packet_msb, b.packet_msb)
	mm_diff_optional(df, c"ticket base url", a.ticket_base_url, b.ticket_base_url)
	mm_diff_int(df, c"config mask", a.config_mask, b.config_mask)
	if (a.config_mask & 1): mm_diff_int(df, c"node spacing", a.node_spacing, b.node_spacing)
	if (a.config_mask & 2): mm_diff_int(df, c"rank spacing", a.rank_spacing, b.rank_spacing)
	mm_diff_int(df, c"edge curve", a.edge_curve, b.edge_curve)
	mm_diff_int(df, c"look", a.look, b.look)
	mm_diff_optional(df, c"font family", a.font_family, b.font_family)
	mm_diff_int(df, c"font size", a.font_size, b.font_size)
	mm_diff_int(df, c"c4 shapes in row", a.c4_shape_in_row, b.c4_shape_in_row)
	mm_diff_int(df, c"c4 boundaries in row", a.c4_boundary_in_row, b.c4_boundary_in_row)
	mm_diff_ints(df, c"architecture align", a.arch_align, b.arch_align)
	mm_diff_int(df, c"use case rotate", a.usecase_rotate, b.usecase_rotate)
	mm_diff_config(df, a, b)

# Owned description of the first semantic difference, or null when equal.
char* mm_document_diff(mm_document* a, mm_document* b):
	mm_diff df
	df.text = 0
	mm_diff_document(&df, a, b)
	if (df.text == 0): return 0
	char* result = df.text.data
	free(df.text)
	return result

int mm_document_equal(mm_document* a, mm_document* b):
	char* diff = mm_document_diff(a, b)
	if (diff == 0): return 1
	free(diff)
	return 0
