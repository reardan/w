# Canonical data chart source: pie, quadrant, XY, Sankey, radar, treemap,
# Venn and packet charts. Items are written in model order, one statement
# per line; resolved item styles come back from the chart's own `style`
# rules and classDefs, which are written verbatim after the items.
import libs.extras.mermaid.serialize_common

# Treemap and packet charts read classDef statements; the other data charts
# carry style classes as frontmatter themeCSS.
int mm_serialize_data_class_defs(int kind):
	return kind == MM_TREEMAP || kind == MM_PACKET

# Signed fixed-point thousandths as a decimal ("-1.5", "0.025", "12").
void mm_serialize_data_number(mm_serializer* out, int value):
	if (value < -1000000000 || value > 1000000000): out.failed = 1
	if (value < 0):
		mm_out_char(out, '-')
		value = 0 - value
	mm_out_int(out, value / 1000)
	int fraction = value % 1000
	if (fraction == 0): return
	mm_out_char(out, '.')
	mm_out_char(out, '0' + fraction / 100)
	if (fraction % 100):
		mm_out_char(out, '0' + fraction / 10 % 10)
		if (fraction % 10): mm_out_char(out, '0' + fraction % 10)

# Text read by mm_data_text, mm_until or mm_identifier: quoted unless it
# holds a double quote, then plain when no delimiter would cut it short.
void mm_serialize_data_text(mm_serializer* out, char* text, char* stops):
	if (text == 0 || text[0] == 0):
		out.failed = 1
		return
	if (index_of(text, c"\"") < 0 && text[0] != '`'):
		mm_serialize_quote(out, text)
		return
	int length = strlen(text)
	if (text[0] == '"' || text[0] <= 32 || text[length - 1] <= 32 || index_of(text, c"%%") >= 0): out.failed = 1
	mm_out_plain(out, text, stops)

# An item name read by mm_identifier, with an optional `[label]`.
void mm_serialize_data_named(mm_serializer* out, mm_data_item* item):
	mm_serialize_id(out, item.id)
	if (strcmp(item.label, item.id) == 0): return
	mm_out_char(out, '[')
	if (item.label[0] == 0): mm_out(out, c"\"\"")
	else: mm_serialize_data_text(out, item.label, c"]")
	mm_out_char(out, ']')

# A Sankey CSV field: plain, or quoted with doubled quotes.
void mm_serialize_data_csv(mm_serializer* out, char* text):
	int length = strlen(text)
	int plain = length > 0 && text[0] > 32 && text[0] != '"' && text[length - 1] > 32 && index_of(text, c"%%") < 0
	for i in range(length):
		int c = text[i] & 255
		if (c == ',' || c == ';' || c == 10 || c == 13): plain = 0
	if (plain):
		mm_out(out, text)
		return
	mm_out_char(out, '"')
	for i in range(length):
		if (text[i] == '"'): mm_out_char(out, '"')
		mm_out_char(out, text[i])
	mm_out_char(out, '"')

void mm_serialize_data_values(mm_serializer* out, mm_data_item* item, int labels):
	mm_out_char(out, '[')
	for i in range(item.values.length):
		if (i > 0): mm_out(out, c", ")
		mm_serialize_data_number(out, item.values[i])
		if (labels && i < item.point_labels.length && item.point_labels[i][0] != 0):
			mm_out_char(out, 32)
			mm_serialize_quote(out, item.point_labels[i])
	mm_out_char(out, ']')

# Quadrant point properties: color is the point fill.
void mm_serialize_data_point_style(mm_serializer* out, mm_data_item* item):
	int known = MM_STYLE_FILL | MM_STYLE_STROKE | MM_STYLE_WIDTH
	if ((item.style.mask & known) != item.style.mask): out.failed = 1
	int comma = 0
	if (item.radius != 0):
		mm_out(out, c" radius: ")
		mm_out_int(out, item.radius)
		comma = 1
	if (item.style.mask & MM_STYLE_FILL):
		if (comma): mm_out_char(out, ',')
		mm_out(out, c" color: ")
		mm_serialize_color(out, item.style.fill)
		comma = 1
	if (item.style.mask & MM_STYLE_STROKE):
		if (comma): mm_out_char(out, ',')
		mm_out(out, c" stroke-color: ")
		mm_serialize_color(out, item.style.stroke)
		comma = 1
	if (item.style.mask & MM_STYLE_WIDTH):
		if (comma): mm_out_char(out, ',')
		mm_out(out, c" stroke-width: ")
		mm_out_int(out, item.style.width)
		mm_out(out, c"px")

void mm_serialize_data_quadrant(mm_serializer* out, mm_document* d, mm_data_chart* c):
	if (c.x_label[0] != 0):
		mm_out(out, c"  x-axis ")
		mm_serialize_quote(out, c.x_label)
		if (c.x_end[0] != 0):
			mm_out(out, c" --> ")
			mm_serialize_data_text(out, c.x_end, 0)
		mm_out_line(out)
	else if (c.x_end[0] != 0): out.failed = 1
	if (c.y_label[0] != 0):
		mm_out(out, c"  y-axis ")
		mm_serialize_quote(out, c.y_label)
		if (c.y_end[0] != 0):
			mm_out(out, c" --> ")
			mm_serialize_data_text(out, c.y_end, 0)
		mm_out_line(out)
	else if (c.y_end[0] != 0): out.failed = 1
	for mm_data_item* item in c.items:
		mm_out(out, c"  ")
		if (item.kind == 9):
			mm_out(out, c"classDef ")
			mm_serialize_id(out, item.id)
			if (item.style.mask == 0 && item.radius == 0): out.failed = 1
			mm_serialize_data_point_style(out, item)
		else if (item.kind == 8):
			mm_out(out, c"quadrant-")
			mm_out_int(out, item.a)
			mm_out_char(out, 32)
			mm_serialize_data_text(out, item.label, 0)
		else if (item.kind == 0):
			mm_serialize_data_text(out, item.label, c":")
			if (item.target[0] != 0):
				mm_out(out, c":::")
				mm_serialize_id(out, item.target)
			mm_out(out, c": ")
			mm_serialize_data_values(out, item, 0)
			mm_serialize_data_point_style(out, item)
		else: out.failed = 1
		mm_out_line(out)

void mm_serialize_data_xy(mm_serializer* out, mm_document* d, mm_data_chart* c):
	if (c.x_numeric):
		mm_out(out, c"  x-axis ")
		if (c.x_label[0] != 0):
			mm_serialize_quote(out, c.x_label)
			mm_out_char(out, 32)
		mm_serialize_data_number(out, c.x_low)
		mm_out(out, c" --> ")
		mm_serialize_data_number(out, c.x_high)
		mm_out_line(out)
	if (c.explicit_low != c.explicit_high): out.failed = 1
	if (c.explicit_low):
		mm_out(out, c"  y-axis ")
		if (c.y_label[0] != 0):
			mm_serialize_quote(out, c.y_label)
			mm_out_char(out, 32)
		mm_serialize_data_number(out, c.low)
		mm_out(out, c" --> ")
		mm_serialize_data_number(out, c.high)
		mm_out_line(out)
	else if (c.y_label[0] != 0): out.failed = 1
	int axes = 0
	int i = 0
	while (i < c.items.length):
		mm_data_item* item = c.items[i]
		if (item.kind == 1):
			mm_out(out, c"  x-axis ")
			if (c.x_label[0] != 0):
				mm_serialize_quote(out, c.x_label)
				mm_out_char(out, 32)
			mm_out_char(out, '[')
			int first = 1
			while (i < c.items.length && c.items[i].kind == 1):
				if (first == 0): mm_out(out, c", ")
				first = 0
				mm_serialize_data_text(out, c.items[i].label, c",]")
				i = i + 1
			mm_out(out, c"]\n")
			axes = 1
			continue
		if (item.kind == 2): mm_out(out, c"  line ")
		else if (item.kind == 3): mm_out(out, c"  bar ")
		else: out.failed = 1
		if (item.label[0] != 0):
			mm_serialize_quote(out, item.label)
			mm_out_char(out, 32)
		mm_serialize_data_values(out, item, 1)
		mm_out_line(out)
		i = i + 1
	if (axes == 0 && c.x_numeric == 0 && c.x_label[0] != 0): out.failed = 1

void mm_serialize_data_radar(mm_serializer* out, mm_data_chart* c):
	list[mm_data_item*] axes = new list[mm_data_item*]
	for mm_data_item* item in c.items:
		if (item.kind == 1): axes.push(item)
	for mm_data_item* item in c.items:
		if (item.kind == 1): mm_out(out, c"  axis ")
		else if (item.kind == 4): mm_out(out, c"  curve ")
		else: out.failed = 1
		mm_serialize_data_named(out, item)
		if (item.kind == 4):
			mm_out(out, c"{")
			int keyed = item.point_labels.length != 0
			if (keyed && item.point_labels.length != item.values.length): out.failed = 1
			for i in range(item.values.length):
				if (i > 0): mm_out(out, c", ")
				if (keyed == 0):
					mm_serialize_data_number(out, item.values[i])
					continue
				char* name = item.point_labels[i]
				int at = -1
				for k in range(axes.length):
					if (strcmp(axes[k].id, name) == 0): at = k
				if (at < 0 || at >= item.values.length):
					out.failed = 1
					continue
				mm_serialize_id(out, name)
				mm_out(out, c": ")
				mm_serialize_data_number(out, item.values[at])
			mm_out(out, c"}")
		mm_out_line(out)
	__w_list_free(cast(__w_list*, axes))
	if (c.explicit_low):
		mm_out(out, c"  min ")
		mm_serialize_data_number(out, c.low)
		mm_out_line(out)
	if (c.explicit_high):
		mm_out(out, c"  max ")
		mm_serialize_data_number(out, c.high)
		mm_out_line(out)
	if (c.ticks != 5):
		mm_out(out, c"  ticks ")
		mm_out_int(out, c.ticks)
		mm_out_line(out)
	if (c.polygon): mm_out(out, c"  graticule polygon\n")
	if (c.legend == 0): mm_out(out, c"  showLegend false\n")

void mm_serialize_data_venn(mm_serializer* out, mm_data_chart* c):
	int region = -1
	for i in range(c.items.length):
		mm_data_item* item = c.items[i]
		mm_out(out, c"  ")
		if (item.kind == 6):
			mm_out(out, c"set ")
			mm_serialize_data_named(out, item)
			if (item.b == 0 && item.a != 10000): out.failed = 1
		else if (item.kind == 7):
			mm_out(out, c"union ")
			for k in range(item.values.length):
				if (k > 0): mm_out(out, c", ")
				int member = item.values[k]
				if (member < 0 || member >= i || c.items[member].kind != 6):
					out.failed = 1
					continue
				mm_serialize_id(out, c.items[member].id)
			mm_out_char(out, '[')
			if (item.label[0] == 0): mm_out(out, c"\"\"")
			else: mm_serialize_data_text(out, item.label, c"]")
			mm_out_char(out, ']')
			int count = item.values.length
			if (count < 2 || (item.b == 0 && item.a != 10000 / (count * count))): out.failed = 1
		else if (item.kind == 10):
			if (item.parent != region): out.failed = 1
			mm_out(out, c"text ")
			mm_serialize_data_named(out, item)
		else: out.failed = 1
		if ((item.kind == 6 || item.kind == 7) && item.b == 1):
			mm_out(out, c": ")
			mm_serialize_data_number(out, item.a)
		if (item.kind == 6 || item.kind == 7): region = i
		mm_out_line(out)

void mm_serialize_data_items(mm_serializer* out, mm_document* d, mm_data_chart* c):
	int kind = d.kind
	if (kind == MM_QUADRANT):
		mm_serialize_data_quadrant(out, d, c)
		return
	if (kind == MM_XY):
		mm_serialize_data_xy(out, d, c)
		return
	if (kind == MM_RADAR):
		mm_serialize_data_radar(out, c)
		return
	if (kind == MM_VENN):
		mm_serialize_data_venn(out, c)
		return
	for i in range(c.items.length):
		mm_data_item* item = c.items[i]
		if (kind == MM_PIE):
			if (item.kind != 0): out.failed = 1
			mm_out(out, c"  ")
			mm_serialize_quote(out, item.label)
			mm_out(out, c": ")
			mm_serialize_data_number(out, item.a)
		else if (kind == MM_SANKEY):
			if (item.kind != 0 || item.parent < 0 || item.b < 0 || item.parent >= d.nodes.length || item.b >= d.nodes.length): out.failed = 1
			mm_serialize_data_csv(out, item.id)
			mm_out_char(out, ',')
			mm_serialize_data_csv(out, item.target)
			mm_out_char(out, ',')
			mm_serialize_data_number(out, item.a)
		else if (kind == MM_TREEMAP):
			if (item.kind != 0 && item.kind != 5): out.failed = 1
			if (item.depth < 0 || item.depth > 256): out.failed = 1
			for k in range(item.depth): mm_out_char(out, 32)
			mm_serialize_quote(out, item.label)
			if (item.kind == 0):
				mm_out(out, c": ")
				mm_serialize_data_number(out, item.a)
			if (item.target[0] != 0):
				mm_out(out, c":::")
				mm_serialize_id(out, item.target)
		else if (kind == MM_PACKET):
			if (item.kind != 0): out.failed = 1
			mm_out(out, c"  ")
			mm_out_int(out, item.a)
			if (item.b != item.a):
				mm_out_char(out, '-')
				mm_out_int(out, item.b)
			mm_out(out, c": ")
			mm_serialize_quote(out, item.label)
			if (item.target[0] != 0):
				mm_out(out, c":::")
				mm_serialize_id(out, item.target)
		mm_out_line(out)

void mm_serialize_data_rules(mm_serializer* out, mm_document* d, mm_data_chart* c):
	if (c.rules == 0): return
	if (c.rules.length != 0 && mm_data_styled_family(d.kind) == 0): out.failed = 1
	for mm_data_item* rule in c.rules:
		mm_out(out, c"  style ")
		if (rule.a): mm_serialize_quote(out, rule.target)
		else:
			if (rule.target[0] == 0 || rule.target[0] == '"'): out.failed = 1
			mm_out_plain(out, rule.target, c" \t;")
		mm_out_char(out, 32)
		mm_serialize_style(out, d, &rule.style)

void mm_serialize_data_body(mm_serializer* out, mm_document* d, int variant):
	mm_data_chart* c = d.data
	if (c == 0 || d.edges.length != 0 || d.notes.length != 0 || d.narrative.length != 0 || d.railroad != 0):
		out.failed = 1
		return
	int kind = d.kind
	if (kind == MM_PIE): mm_out(out, c"pie")
	else if (kind == MM_QUADRANT): mm_out(out, c"quadrantChart")
	else if (kind == MM_XY): mm_out(out, c"xychart-beta")
	else if (kind == MM_SANKEY): mm_out(out, c"sankey-beta")
	else if (kind == MM_RADAR): mm_out(out, c"radar-beta")
	else if (kind == MM_TREEMAP): mm_out(out, c"treemap-beta")
	else if (kind == MM_VENN): mm_out(out, c"venn-beta")
	else: mm_out(out, c"packet-beta")
	if (c.show_data): mm_out(out, c" showData")
	if (c.horizontal): mm_out(out, c" horizontal")
	if (kind == MM_SANKEY && c.title[0] != 0):
		mm_out(out, c" title ")
		mm_serialize_data_text(out, c.title, 0)
	mm_out_line(out)
	out.depth = 1
	if (kind != MM_SANKEY && c.title[0] != 0):
		mm_out(out, c"  title ")
		mm_serialize_data_text(out, c.title, 0)
		mm_out_line(out)
	mm_serialize_accessibility(out, d)
	if (mm_serialize_data_class_defs(kind)): mm_serialize_class_defs(out, d)
	mm_serialize_data_items(out, d, c)
	mm_serialize_data_rules(out, d, c)
	out.depth = 0
