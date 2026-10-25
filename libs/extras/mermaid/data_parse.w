# Native data diagrams. Numeric input is bounded fixed-point, never host atof.
import libs.extras.mermaid.parse_common
import libs.extras.mermaid.style

# Item kinds: value/point/packet/leaf = 0; axis = 1; line = 2; bar = 3;
# radar curve = 4; treemap group = 5; Venn set = 6; Venn intersection = 7.
# quadrant label = 8; quadrant class = 9; Venn text = 10.
mm_data_chart* mm_data_new(mm_document* d):
	mm_data_chart* c = new mm_data_chart()
	c.title = strclone(c"")
	c.x_label = strclone(c"")
	c.x_end = strclone(c"")
	c.y_label = strclone(c"")
	c.y_end = strclone(c"")
	c.items = new list[mm_data_item*]
	c.rules = new list[mm_data_item*]
	c.ticks = 5
	c.legend = 1
	d.data = c
	return c

mm_data_item* mm_data_add(mm_parser* p, int kind):
	if (p.doc.data.items.length >= 256):
		mm_error(p.doc, p.pos, c"data chart item limit exceeded (256)")
		return 0
	mm_data_item* item = new mm_data_item()
	item.id = strclone(c"")
	item.label = strclone(c"")
	item.target = strclone(c"")
	item.values = new list[int]
	item.point_labels = new list[char*]
	item.kind = kind
	item.parent = -1
	p.doc.data.items.push(item)
	return item

void mm_data_expect(mm_parser* p, char* token):
	mm_space(p)
	if (mm_match(p, token) == 0): mm_error(p.doc, p.pos, c"expected data diagram delimiter")

# Decimal values in [-1000000,1000000], with up to three fractional digits.
int mm_data_number(mm_parser* p):
	mm_space(p)
	int sign = 1
	if (mm_match(p, c"-")): sign = -1
	else: mm_match(p, c"+")
	int n = 0
	int digits = 0
	while (isdigit(mm_peek(p))):
		if (n > 100000):
			mm_error(p.doc, p.pos, c"numeric value exceeds 1000000")
			return 0
		n = n * 10 + mm_peek(p) - '0'
		p.pos = p.pos + 1
		digits = digits + 1
	if (digits == 0 && mm_peek(p) != '.'): mm_error(p.doc, p.pos, c"expected decimal number")
	int fraction = 0
	int scale = 100
	if (mm_match(p, c".")):
		int count = 0
		while (isdigit(mm_peek(p))):
			if (count >= 3):
				mm_error(p.doc, p.pos, c"at most three fractional digits supported")
				return 0
			fraction = fraction + (mm_peek(p) - '0') * scale
			scale = scale / 10
			count = count + 1
			p.pos = p.pos + 1
		if (count == 0): mm_error(p.doc, p.pos, c"expected fractional digit")
	if (n > 1000000 || (n == 1000000 && fraction != 0)):
		mm_error(p.doc, p.pos, c"numeric value exceeds 1000000")
		return 0
	return sign * (n * 1000 + fraction)

int mm_data_integer(mm_parser* p):
	int start = p.pos
	int value = mm_data_number(p)
	for i in range(start, p.pos):
		if (p.doc.source[i] == '.'): mm_error(p.doc, start, c"expected integer")
	return value / 1000

char* mm_data_text(mm_parser* p, int delimiter):
	mm_space(p)
	if (mm_peek(p) == '"'): return mm_quoted(p)
	int start = p.pos
	while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13 && mm_peek(p) != delimiter && mm_peek(p) != ';'):
		if (mm_peek(p) == '%' && p.pos + 1 < p.doc.length && p.doc.source[p.pos + 1] == '%'): break
		p.pos = p.pos + 1
	int end = p.pos
	while (end > start && (p.doc.source[end - 1] == ' ' || p.doc.source[end - 1] == 9)): end = end - 1
	if (start == end): mm_error(p.doc, start, c"expected data label")
	return str_copy_range(p.doc.source, start, end)

void mm_data_values(mm_parser* p, mm_data_item* item, char* open, char* close):
	mm_data_expect(p, open)
	while (p.doc.error == 0):
		if (item.values.length >= 256):
			mm_error(p.doc, p.pos, c"series point limit exceeded (256)")
			return
		item.values.push(mm_data_number(p))
		mm_space(p)
		if (item.kind == 2 || item.kind == 3):
			if (mm_peek(p) == '"'): item.point_labels.push(mm_quoted(p))
			else: item.point_labels.push(strclone(c""))
		mm_space(p)
		if (mm_match(p, close)): return
		mm_data_expect(p, c",")

void mm_data_named(mm_parser* p, mm_data_item* item):
	free(item.id)
	item.id = mm_identifier(p)
	free(item.label)
	item.label = strclone(item.id)
	mm_space(p)
	if (mm_match(p, c"[")):
		free(item.label)
		item.label = mm_until(p, ']')

void mm_data_pie(mm_parser* p):
	mm_data_item* item = mm_data_add(p, 0)
	if (item == 0): return
	mm_space(p)
	if (mm_peek(p) != '"'): mm_error(p.doc, p.pos, c"pie labels must be quoted")
	free(item.label)
	item.label = mm_data_text(p, ':')
	mm_data_expect(p, c":")
	item.a = mm_data_number(p)
	if (item.a <= 0): mm_error(p.doc, p.pos, c"pie values must be positive")
	for mm_data_item* other in p.doc.data.items:
		if (other != item && strcmp(other.label, item.label) == 0): mm_error(p.doc, p.pos, c"duplicate pie label")

void mm_data_packet(mm_parser* p):
	mm_data_chart* c = p.doc.data
	int next = 0
	if (c.items.length != 0):
		mm_data_item* previous = c.items[c.items.length - 1]
		next = previous.b + 1
	mm_data_item* item = mm_data_add(p, 0)
	if (item == 0): return
	if (mm_match(p, c"+")):
		item.a = next
		int count = mm_data_integer(p)
		if (count <= 0): mm_error(p.doc, p.pos, c"packet bit count must be positive")
		item.b = next + count - 1
	else:
		item.a = mm_data_integer(p)
		item.b = item.a
		mm_space(p)
		if (mm_match(p, c"-")): item.b = mm_data_integer(p)
	if (item.a < next || item.b < item.a || item.b > 4095): mm_error(p.doc, p.pos, c"packet fields must be ordered, disjoint and within bits 0..4095")
	mm_data_expect(p, c":")
	mm_space(p)
	if (mm_peek(p) != '"'): mm_error(p.doc, p.pos, c"packet label must be quoted")
	free(item.label)
	item.label = mm_data_text(p, 10)
	mm_space(p)
	# `:::class` names a classDef; it is resolved into item.style on validation.
	if (mm_match(p, c":::")):
		free(item.target)
		item.target = mm_identifier(p)

# Families whose items take `style` rules.
int mm_data_styled_family(int kind):
	return kind == MM_TREEMAP || kind == MM_VENN || kind == MM_RADAR || kind == MM_PACKET

# `style <targets> <properties>`: a quoted label, or comma-separated names.
int mm_data_style_rule(mm_parser* p):
	if (mm_style_keyword(p, c"style") == 0): return 0
	mm_data_chart* c = p.doc.data
	if (c.rules.length >= 256):
		mm_error(p.doc, p.pos, c"data chart style rule limit exceeded (256)")
		return 1
	mm_data_item* rule = new mm_data_item()
	rule.id = strclone(c"")
	rule.label = strclone(c"")
	rule.values = new list[int]
	rule.point_labels = new list[char*]
	rule.parent = -1
	c.rules.push(rule)
	rule.b = p.pos
	if (mm_peek(p) == '"'):
		rule.target = mm_quoted(p)
		rule.a = 1
	else:
		int start = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13 && mm_peek(p) != 32 && mm_peek(p) != 9 && mm_peek(p) != ';'): p.pos = p.pos + 1
		rule.target = str_copy_range(p.doc.source, start, p.pos)
	if (rule.target[0] == 0): mm_error(p.doc, p.pos, c"invalid style target")
	mm_space(p)
	rule.style = mm_style_parse(p)
	return 1

# 1 when item is the target name: an ID for Venn and radar, a label (or a
# packet field's first bit) for treemap and packet charts.
int mm_data_style_match(mm_document* d, mm_data_item* item, char* name, int quoted):
	if (d.kind == MM_VENN): return quoted == 0 && (item.kind == 6 || item.kind == 10) && strcmp(item.id, name) == 0
	if (d.kind == MM_RADAR): return quoted == 0 && item.kind == 4 && strcmp(item.id, name) == 0
	if (strcmp(item.label, name) == 0): return 1
	if (d.kind == MM_PACKET && quoted == 0 && name[0] >= '0' && name[0] <= '9'):
		char* bit = itoa(item.a)
		int same = strcmp(bit, name) == 0
		free(bit)
		return same
	return 0

# Direct style rules apply after classes, so they win.
void mm_data_style_resolve(mm_parser* p):
	mm_data_chart* c = p.doc.data
	for mm_data_item* rule in c.rules:
		list[char*] names = new list[char*]
		if (rule.a): names.push(strclone(rule.target))
		else:
			int start = 0
			for i in range(strlen(rule.target) + 1):
				if (rule.target[i] == 0 || rule.target[i] == ','):
					names.push(mm_style_trim(rule.target, start, i))
					start = i + 1
		int matched = 0
		if (p.doc.kind == MM_VENN && names.length > 1):
			# `style A,B` styles the union of exactly those sets.
			for mm_data_item* item in c.items:
				if (item.kind != 7 || item.values.length != names.length): continue
				int same = 1
				for int index in item.values:
					mm_data_item* member = c.items[index]
					int found = 0
					for char* name in names:
						if (strcmp(member.id, name) == 0): found = 1
					if (found == 0): same = 0
				if (same):
					mm_style_merge(&item.style, &rule.style)
					matched = 1
		else:
			for char* name in names:
				int one = 0
				for mm_data_item* item in c.items:
					if (mm_data_style_match(p.doc, item, name, rule.a)):
						mm_style_merge(&item.style, &rule.style)
						one = 1
				if (one == 0): matched = -1
				else if (matched == 0): matched = 1
		for char* name in names: free(name)
		__w_list_free(cast(__w_list*, names))
		if (matched != 1): mm_error(p.doc, rule.b, c"style target matches no item")

# An axis delimiter is the complete arrow; ordinary hyphens belong to labels.
char* mm_data_axis_start(mm_parser* p):
	mm_space(p)
	if (mm_peek(p) == '"'): return mm_quoted(p)
	int start = p.pos
	while (mm_end(p) == 0):
		if (p.pos + 2 < p.doc.length && p.doc.source[p.pos] == '-' && p.doc.source[p.pos + 1] == '-' && p.doc.source[p.pos + 2] == '>'): break
		p.pos = p.pos + 1
	int end = p.pos
	while (end > start && (p.doc.source[end - 1] == ' ' || p.doc.source[end - 1] == 9)): end = end - 1
	if (end == start): mm_error(p.doc, start, c"expected data label")
	return str_copy_range(p.doc.source, start, end)

# Quadrant point CSS differs from node CSS: color is the point fill.
void mm_data_quadrant_style(mm_parser* p, mm_data_item* item):
	int count = 0
	while (mm_end(p) == 0 && p.doc.error == 0):
		int start = p.pos
		while (mm_end(p) == 0 && mm_peek(p) != ':' && mm_peek(p) != ','): p.pos = p.pos + 1
		char* key = mm_style_trim(p.doc.source, start, p.pos)
		mm_data_expect(p, c":")
		start = p.pos
		while (mm_end(p) == 0 && mm_peek(p) != ','): p.pos = p.pos + 1
		char* value = mm_style_trim(p.doc.source, start, p.pos)
		if (strcmp(key, c"radius") == 0):
			int radius = 0
			int length = strlen(value)
			if (length == 0 || length > 2): radius = -1
			for i in range(length):
				if (isdigit(value[i]) == 0): radius = -1
				if (radius >= 0): radius = radius * 10 + value[i] - '0'
			if (radius < 1 || radius > 64): mm_error(p.doc, start, c"quadrant radius must be an integer in 1..64")
			else: item.radius = radius
		else if (strcmp(key, c"color") == 0): mm_style_property(p.doc, &item.style, c"fill", value, start)
		else if (strcmp(key, c"stroke-color") == 0): mm_style_property(p.doc, &item.style, c"stroke", value, start)
		else if (strcmp(key, c"stroke-width") == 0): mm_style_property(p.doc, &item.style, c"stroke-width", value, start)
		else: mm_error(p.doc, start, c"quadrant point style supports color, radius, stroke-color and stroke-width")
		free(key)
		free(value)
		count = count + 1
		if (count > 16): mm_error(p.doc, p.pos, c"style property limit exceeded")
		if (mm_match(p, c",") && mm_end(p)): mm_error(p.doc, p.pos, c"trailing style comma")

void mm_data_quadrant_resolve(mm_parser* p):
	for mm_data_item* item in p.doc.data.items:
		if (item.kind != 0 || item.target[0] == 0): continue
		mm_data_item* definition = 0
		for mm_data_item* candidate in p.doc.data.items:
			if (candidate.kind == 9 && strcmp(candidate.id, item.target) == 0): definition = candidate
		if (definition == 0): mm_error(p.doc, p.pos, c"unknown quadrant point class")
		else:
			mm_style resolved = definition.style
			mm_style_merge(&resolved, &item.style)
			item.style = resolved
			if (item.radius == 0): item.radius = definition.radius

void mm_data_quadrant(mm_parser* p):
	mm_data_chart* c = p.doc.data
	if (mm_match(p, c"classDef ")):
		mm_data_item* definition = mm_data_add(p, 9)
		if (definition == 0): return
		free(definition.id)
		definition.id = mm_identifier(p)
		for mm_data_item* previous in c.items:
			if (previous != definition && previous.kind == 9 && strcmp(previous.id, definition.id) == 0): mm_error(p.doc, p.pos, c"duplicate quadrant class")
		if (mm_end(p)): mm_error(p.doc, p.pos, c"expected quadrant class properties")
		mm_data_quadrant_style(p, definition)
		return
	int axis = 0
	if (mm_match(p, c"x-axis ")): axis = 1
	else if (mm_match(p, c"y-axis ")): axis = 2
	if (axis):
		char* first = mm_data_axis_start(p)
		mm_space(p)
		char* last = strclone(c"")
		if (mm_match(p, c"-->")):
			free(last)
			last = mm_data_text(p, 10)
		if (axis == 1):
			free(c.x_label)
			free(c.x_end)
			c.x_label = first
			c.x_end = last
		else:
			free(c.y_label)
			free(c.y_end)
			c.y_label = first
			c.y_end = last
		return
	mm_data_item* item = mm_data_add(p, 0)
	if (item == 0): return
	if (mm_match(p, c"quadrant-")):
		item.kind = 8
		item.a = mm_data_integer(p)
		if (item.a < 1 || item.a > 4): mm_error(p.doc, p.pos, c"quadrant index must be 1..4")
		free(item.label)
		item.label = mm_data_text(p, 10)
	else:
		free(item.label)
		item.label = mm_data_text(p, ':')
		if (mm_match(p, c":::")):
			free(item.target)
			item.target = mm_identifier(p)
		mm_data_expect(p, c":")
		mm_data_values(p, item, c"[", c"]")
		mm_data_quadrant_style(p, item)
		if (item.values.length != 2): mm_error(p.doc, p.pos, c"quadrant point requires exactly two coordinates")
		for int v in item.values:
			if (v < 0 || v > 1000): mm_error(p.doc, p.pos, c"quadrant coordinates must be between 0 and 1")

void mm_data_xy(mm_parser* p):
	mm_data_chart* c = p.doc.data
	int kind = 0
	if (mm_match(p, c"line")): kind = 2
	else if (mm_match(p, c"bar")): kind = 3
	if (kind):
		mm_data_item* item = mm_data_add(p, kind)
		if (item == 0): return
		mm_space(p)
		if (mm_peek(p) == '"'):
			free(item.label)
			item.label = mm_quoted(p)
		mm_data_values(p, item, c"[", c"]")
		return
	if (mm_match(p, c"x-axis")):
		mm_space(p)
		if (mm_peek(p) == '"'):
			free(c.x_label)
			c.x_label = mm_quoted(p)
		mm_space(p)
		if (mm_peek(p) != '['):
			c.x_numeric = 1
			c.x_low = mm_data_number(p)
			mm_data_expect(p, c"-->")
			c.x_high = mm_data_number(p)
			if (c.x_high <= c.x_low): mm_error(p.doc, p.pos, c"numeric x-axis maximum must exceed minimum")
			return
		mm_data_expect(p, c"[")
		while (p.doc.error == 0):
			mm_data_item* item = mm_data_add(p, 1)
			if (item == 0): return
			mm_space(p)
			free(item.label)
			if (mm_peek(p) == '"'): item.label = mm_quoted(p)
			else:
				int start = p.pos
				while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != ',' && mm_peek(p) != ']'): p.pos = p.pos + 1
				int end = p.pos
				while (end > start && p.doc.source[end - 1] == ' '): end = end - 1
				item.label = str_copy_range(p.doc.source, start, end)
			if (item.label[0] == 0): mm_error(p.doc, p.pos, c"empty XY category")
			mm_space(p)
			if (mm_match(p, c"]")): return
			mm_data_expect(p, c",")
		return
	if (mm_match(p, c"y-axis")):
		mm_space(p)
		if (mm_peek(p) == '"'):
			free(c.y_label)
			c.y_label = mm_quoted(p)
		c.low = mm_data_number(p)
		mm_data_expect(p, c"-->")
		c.high = mm_data_number(p)
		c.explicit_low = 1
		c.explicit_high = 1
		return
	mm_error(p.doc, p.pos, c"expected XY x-axis categories, y-axis range, bar or line")

void mm_data_radar_values(mm_parser* p, mm_data_item* item):
	mm_data_expect(p, c"{")
	mm_space(p)
	int keyed = isalpha(mm_peek(p)) || mm_peek(p) == '_' || mm_peek(p) == '"' || mm_peek(p) >= 128
	while (p.doc.error == 0):
		if (item.values.length >= 256):
			mm_error(p.doc, p.pos, c"series point limit exceeded (256)")
			return
		if (keyed):
			char* name = mm_identifier(p)
			for char* previous in item.point_labels:
				if (strcmp(previous, name) == 0): mm_error(p.doc, p.pos, c"duplicate radar axis value")
			item.point_labels.push(name)
			mm_data_expect(p, c":")
		item.values.push(mm_data_number(p))
		mm_space(p)
		if (mm_match(p, c"}")): break
		mm_data_expect(p, c",")

# Resolve keyed curves after the complete body, allowing axes in either order.
void mm_data_radar_resolve(mm_parser* p):
	for mm_data_item* curve in p.doc.data.items:
		if (curve.kind != 4 || curve.point_labels.length == 0): continue
		list[int] ordered = new list[int]
		for mm_data_item* axis in p.doc.data.items:
			if (axis.kind != 1): continue
			int index = -1
			for i in range(curve.point_labels.length):
				if (strcmp(curve.point_labels[i], axis.id) == 0): index = i
			if (index < 0): mm_error(p.doc, p.pos, c"keyed radar curve must specify every axis")
			else: ordered.push(curve.values[index])
		if (ordered.length != curve.values.length): mm_error(p.doc, p.pos, c"radar curve references an undeclared axis")
		__w_list_free(cast(__w_list*, curve.values))
		curve.values = ordered

void mm_data_radar(mm_parser* p):
	mm_data_chart* c = p.doc.data
	int kind = 0
	if (mm_match(p, c"axis ")): kind = 1
	else if (mm_match(p, c"curve ")): kind = 4
	if (kind):
		while (p.doc.error == 0):
			mm_data_item* item = mm_data_add(p, kind)
			if (item == 0): return
			mm_data_named(p, item)
			for mm_data_item* other in c.items:
				if (other != item && other.kind == kind && strcmp(other.id, item.id) == 0): mm_error(p.doc, p.pos, c"duplicate radar axis or curve ID")
			if (kind == 4): mm_data_radar_values(p, item)
			mm_space(p)
			if (mm_match(p, c",") == 0): return
		return
	if (mm_match(p, c"min ")):
		c.low = mm_data_number(p)
		c.explicit_low = 1
	else if (mm_match(p, c"max ")):
		c.high = mm_data_number(p)
		c.explicit_high = 1
	else if (mm_match(p, c"ticks ")):
		c.ticks = mm_data_integer(p)
		if (c.ticks < 1 || c.ticks > 20): mm_error(p.doc, p.pos, c"radar ticks must be 1..20")
	else if (mm_match(p, c"graticule ")):
		if (mm_match(p, c"polygon")): c.polygon = 1
		else if (mm_match(p, c"circle") == 0): mm_error(p.doc, p.pos, c"expected circle or polygon graticule")
	else if (mm_match(p, c"showLegend ")):
		if (mm_match(p, c"false")): c.legend = 0
		else if (mm_match(p, c"true")): c.legend = 1
		else: mm_error(p.doc, p.pos, c"expected true or false")
	else: mm_error(p.doc, p.pos, c"unsupported radar statement")

# Quoted CSV fields retain embedded line breaks and doubled quote escaping.
char* mm_data_csv(mm_parser* p):
	mm_space(p)
	if (mm_peek(p) != '"'): return mm_data_text(p, ',')
	p.pos = p.pos + 1
	string_builder* s = string_new()
	while (mm_peek(p) != 0):
		if (mm_match(p, c"\"")):
			if (mm_match(p, c"\"")): string_append_char(s, '"')
			else:
				char* result = strclone(s.data)
				string_free(s)
				return result
		else:
			string_append_char(s, mm_peek(p))
			p.pos = p.pos + 1
	mm_error(p.doc, p.pos, c"unterminated CSV field")
	char* result = strclone(s.data)
	string_free(s)
	return result

void mm_data_sankey(mm_parser* p):
	mm_data_item* item = mm_data_add(p, 0)
	if (item == 0): return
	free(item.id)
	item.id = mm_data_csv(p)
	mm_data_expect(p, c",")
	free(item.target)
	item.target = mm_data_csv(p)
	mm_data_expect(p, c",")
	item.a = mm_data_number(p)
	if (item.a <= 0): mm_error(p.doc, p.pos, c"Sankey flows must be positive")
	if (item.id[0] == 0 || item.target[0] == 0 || strcmp(item.id, item.target) == 0): mm_error(p.doc, p.pos, c"Sankey requires distinct nonempty endpoints")
	int from = mm_add_node(p.doc, item.id, p.pos)
	int to = mm_add_node(p.doc, item.target, p.pos)
	item.parent = from
	item.b = to

void mm_data_tree(mm_parser* p):
	int line = p.pos
	while (line > 0 && p.doc.source[line - 1] != 10): line = line - 1
	int indent = 0
	while (line < p.pos):
		if (p.doc.source[line] == ' '): indent = indent + 1
		else if (p.doc.source[line] == 9): indent = indent + 4
		else: mm_error(p.doc, line, c"treemap entries must begin on their own line")
		line = line + 1
	mm_data_item* item = mm_data_add(p, 5)
	if (item == 0): return
	item.depth = indent
	mm_space(p)
	if (mm_peek(p) != '"'): mm_error(p.doc, p.pos, c"treemap labels must be quoted")
	free(item.label)
	item.label = mm_data_text(p, ':')
	mm_space(p)
	int styled = mm_match(p, c":::")
	if (styled == 0 && mm_match(p, c":")):
		item.kind = 0
		item.a = mm_data_number(p)
		if (item.a <= 0): mm_error(p.doc, p.pos, c"treemap leaf values must be positive")
		mm_space(p)
		styled = mm_match(p, c":::")
	# `:::class` names a classDef; it is resolved into item.style on validation.
	if (styled):
		free(item.target)
		item.target = mm_identifier(p)
	int i = p.doc.data.items.length - 2
	while (i >= 0):
		mm_data_item* previous = p.doc.data.items[i]
		if (previous.depth < indent):
			item.parent = i
			if (previous.kind != 5): mm_error(p.doc, p.pos, c"treemap leaf cannot contain children")
			break
		i = i - 1
	if (item.parent >= 0):
		mm_data_item* parent = p.doc.data.items[item.parent]
		int level = 1
		while (parent.parent >= 0):
			parent = p.doc.data.items[parent.parent]
			level = level + 1
		if (level > 16): mm_error(p.doc, p.pos, c"treemap nesting limit exceeded (16)")

void mm_data_venn(mm_parser* p):
	if (mm_match(p, c"text ")):
		int parent = -1
		for i in range(p.doc.data.items.length):
			mm_data_item* region = p.doc.data.items[i]
			if (region.kind == 6 || region.kind == 7): parent = i
		if (parent < 0):
			mm_error(p.doc, p.pos, c"Venn text requires a preceding set or union")
			return
		mm_data_item* item = mm_data_add(p, 10)
		if (item == 0): return
		item.parent = parent
		mm_data_named(p, item)
		for mm_data_item* other in p.doc.data.items:
			if (other != item && (other.kind == 6 || other.kind == 10) && strcmp(other.id, item.id) == 0): mm_error(p.doc, p.pos, c"duplicate Venn set or text identifier")
		return
	int kind = 0
	if (mm_match(p, c"set ")): kind = 6
	else if (mm_match(p, c"union ")): kind = 7
	else:
		mm_error(p.doc, p.pos, c"expected Venn set, union or text")
		return
	mm_data_item* item = mm_data_add(p, kind)
	if (item == 0): return
	if (kind == 6):
		item.a = 10000
		mm_data_named(p, item)
		int count = 0
		for mm_data_item* other in p.doc.data.items:
			if (other.kind == 6): count = count + 1
			if (other != item && (other.kind == 6 || other.kind == 10) && strcmp(other.id, item.id) == 0): mm_error(p.doc, p.pos, c"duplicate Venn set or text identifier")
		# Upstream draws any number of sets with an eight-colour venn1..venn8 palette.
		if (count > 8): mm_error(p.doc, p.pos, c"native Venn diagrams support up to eight sets")
	else:
		while (p.doc.error == 0):
			char* name = mm_identifier(p)
			int index = -1
			for i in range(p.doc.data.items.length):
				mm_data_item* other = p.doc.data.items[i]
				if (other.kind == 6 && strcmp(other.id, name) == 0): index = i
			free(name)
			if (index < 0): mm_error(p.doc, p.pos, c"Venn union references an undeclared set")
			for int old in item.values:
				if (old == index): mm_error(p.doc, p.pos, c"duplicate set in Venn union")
			item.values.push(index)
			mm_space(p)
			if (mm_match(p, c",") == 0): break
		if (item.values.length < 2): mm_error(p.doc, p.pos, c"Venn union requires at least two sets")
		mm_data_expect(p, c"[")
		free(item.label)
		item.label = mm_until(p, ']')
		item.a = 10000 / (item.values.length * item.values.length)
	mm_space(p)
	if (mm_match(p, c":")):
		item.a = mm_data_number(p)
		item.b = 1
		if (item.a <= 0): mm_error(p.doc, p.pos, c"Venn sizes must be positive")

void mm_data_venn_validate(mm_parser* p):
	for mm_data_item* item in p.doc.data.items:
		if (item.kind != 7): continue
		for mm_data_item* other in p.doc.data.items:
			if (other == item || other.kind != 7 || other.values.length != item.values.length): continue
			int same = 1
			for int index in item.values:
				if (other.values.index(index) < 0): same = 0
			if (same): mm_error(p.doc, p.pos, c"duplicate Venn intersection")
		for int index in item.values:
			mm_data_item* set_item = p.doc.data.items[index]
			if (item.a > set_item.a): mm_error(p.doc, p.pos, c"Venn intersection size cannot exceed a member set")

void mm_data_validate(mm_parser* p):
	mm_data_chart* c = p.doc.data
	if (c.items.length == 0 && p.doc.kind != MM_QUADRANT):
		mm_error(p.doc, p.pos, c"data diagram needs at least one item")
		return
	if (p.doc.kind == MM_VENN): mm_data_venn_validate(p)
	if (p.doc.kind == MM_QUADRANT): mm_data_quadrant_resolve(p)
	if (p.doc.kind == MM_RADAR): mm_data_radar_resolve(p)
	if (p.doc.error != 0): return
	if (p.doc.kind == MM_XY || p.doc.kind == MM_RADAR):
		int axes = 0
		int series = 0
		int count = 0
		for mm_data_item* item in c.items:
			if (item.kind == 1): axes = axes + 1
			else:
				series = series + 1
				if (count == 0): count = item.values.length
				if (count != item.values.length): mm_error(p.doc, p.pos, c"chart series must have equal lengths")
				for int value in item.values:
					if (c.explicit_low == 0 && value < c.low): c.low = value
					if (c.explicit_high == 0 && value > c.high): c.high = value
		if (c.x_numeric && axes != 0): mm_error(p.doc, p.pos, c"x-axis cannot mix numeric range and categories")
		if (series == 0 || (axes != 0 && axes != count)): mm_error(p.doc, p.pos, c"chart requires series matching the axis count")
		if (p.doc.kind == MM_RADAR && (axes < 3 || axes > 32)): mm_error(p.doc, p.pos, c"radar requires 3..32 axes")
		if (c.explicit_high == 0 && c.high == c.low): c.high = c.low + 1000
		if (c.high <= c.low): mm_error(p.doc, p.pos, c"chart maximum must exceed minimum")
		for mm_data_item* item in c.items:
			for int value in item.values:
				if (value < c.low || value > c.high): mm_error(p.doc, p.pos, c"series value outside axis range")
	if (p.doc.kind == MM_PACKET):
		for mm_data_item* item in c.items:
			if (item.target[0] == 0): continue
			mm_style_class* definition = mm_style_find(p.doc, item.target)
			if (definition == 0): mm_error(p.doc, p.pos, c"assigned style class has no classDef")
			else: mm_style_merge(&item.style, &definition.style)
	if (p.doc.kind == MM_TREEMAP):
		for i in range(c.items.length):
			mm_data_item* item = c.items[i]
			if (item.target[0] != 0):
				mm_style_class* definition = mm_style_find(p.doc, item.target)
				if (definition == 0): mm_error(p.doc, p.pos, c"assigned style class has no classDef")
				else: mm_style_merge(&item.style, &definition.style)
	if (mm_data_styled_family(p.doc.kind) && p.doc.error == 0): mm_data_style_resolve(p)
	if (p.doc.kind == MM_TREEMAP):
		for i in range(c.items.length):
			mm_data_item* item = c.items[i]
			if (item.kind != 5): continue
			int children = 0
			for mm_data_item* child in c.items:
				if (child.parent == i): children = children + 1
			if (children == 0): mm_error(p.doc, p.pos, c"treemap section requires children")
	if (p.doc.kind == MM_SANKEY):
		# Kahn traversal: reject cycles rather than render misleading flows.
		list[int] ranks = new list[int]
		for i in range(p.doc.nodes.length): ranks.push(-1)
		for pass in range(p.doc.nodes.length):
			for i in range(p.doc.nodes.length):
				if (ranks[i] >= 0): continue
				int rank = 0
				int ready = 1
				for mm_data_item* item in c.items:
					if (item.b != i): continue
					if (ranks[item.parent] < 0): ready = 0
					else if (ranks[item.parent] + 1 > rank): rank = ranks[item.parent] + 1
				if (ready): ranks[i] = rank
		for int rank in ranks:
			if (rank < 0): mm_error(p.doc, p.pos, c"Sankey graph must be acyclic")
		__w_list_free(cast(__w_list*, ranks))

void mm_data_body(mm_parser* p):
	while (mm_peek(p) != 0 && p.doc.error == 0):
		int start = p.pos
		if (mm_metadata(p)): mm_space(p)
		else if (p.doc.kind != MM_SANKEY && mm_match(p, c"title ")):
			free(p.doc.data.title)
			p.doc.data.title = mm_data_text(p, 10)
		else if (mm_data_styled_family(p.doc.kind) && mm_data_style_rule(p)): mm_space(p)
		else if (p.doc.kind == MM_PIE): mm_data_pie(p)
		else if (p.doc.kind == MM_QUADRANT): mm_data_quadrant(p)
		else if (p.doc.kind == MM_XY): mm_data_xy(p)
		else if (p.doc.kind == MM_SANKEY): mm_data_sankey(p)
		else if (p.doc.kind == MM_RADAR): mm_data_radar(p)
		else if ((p.doc.kind == MM_TREEMAP || p.doc.kind == MM_PACKET) && mm_match(p, c"classDef ")):
			p.pos = p.pos - 9
			mm_style_statement(p)
		else if (p.doc.kind == MM_TREEMAP): mm_data_tree(p)
		else if (p.doc.kind == MM_VENN): mm_data_venn(p)
		else: mm_data_packet(p)
		if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported data diagram syntax")
		mm_separators(p)
		if (start == p.pos): mm_error(p.doc, start, c"expected data diagram statement")
	if (p.doc.error == 0): mm_data_validate(p)
