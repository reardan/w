# Native data diagrams. Numeric input is bounded fixed-point, never host atof.
import libs.extras.mermaid.parse_common

# Item kinds: value/point/packet/leaf = 0; axis = 1; line = 2; bar = 3;
# radar curve = 4; treemap group = 5; Venn set = 6; Venn intersection = 7.
mm_data_chart* mm_data_new(mm_document* d):
	mm_data_chart* c = new mm_data_chart()
	c.title = strclone(c"")
	c.x_label = strclone(c"")
	c.x_end = strclone(c"")
	c.y_label = strclone(c"")
	c.y_end = strclone(c"")
	c.items = new list[mm_data_item*]
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
	if (digits == 0): mm_error(p.doc, p.pos, c"expected decimal number")
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

void mm_data_quadrant(mm_parser* p):
	mm_data_chart* c = p.doc.data
	int axis = 0
	if (mm_match(p, c"x-axis ")): axis = 1
	else if (mm_match(p, c"y-axis ")): axis = 2
	if (axis):
		char* first = mm_data_text(p, '-')
		mm_data_expect(p, c"-->")
		char* last = mm_data_text(p, 10)
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
		mm_data_expect(p, c":")
		mm_data_values(p, item, c"[", c"]")
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
			if (kind == 4): mm_data_values(p, item, c"{", c"}")
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

# CSV fields implement doubled quote escaping; records cannot span lines.
char* mm_data_csv(mm_parser* p):
	mm_space(p)
	if (mm_peek(p) != '"'): return mm_data_text(p, ',')
	p.pos = p.pos + 1
	string_builder* s = string_new()
	while (mm_peek(p) != 0 && mm_peek(p) != 10):
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
	if (mm_match(p, c":")):
		item.kind = 0
		item.a = mm_data_number(p)
		if (item.a <= 0): mm_error(p.doc, p.pos, c"treemap leaf values must be positive")
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
	int kind = 0
	if (mm_match(p, c"set ")): kind = 6
	else if (mm_match(p, c"union ")): kind = 7
	else:
		mm_error(p.doc, p.pos, c"expected Venn set or union")
		return
	mm_data_item* item = mm_data_add(p, kind)
	if (item == 0): return
	if (kind == 6):
		mm_data_named(p, item)
		int count = 0
		for mm_data_item* other in p.doc.data.items:
			if (other.kind == 6): count = count + 1
			if (other != item && other.kind == 6 && strcmp(other.id, item.id) == 0): mm_error(p.doc, p.pos, c"duplicate Venn set")
		if (count > 3): mm_error(p.doc, p.pos, c"native Venn diagrams support up to three sets")
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

void mm_data_validate(mm_parser* p):
	mm_data_chart* c = p.doc.data
	if (c.items.length == 0):
		mm_error(p.doc, p.pos, c"data diagram needs at least one item")
		return
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
		if (series == 0 || (axes != 0 && axes != count)): mm_error(p.doc, p.pos, c"chart requires series matching the axis count")
		if (p.doc.kind == MM_RADAR && (axes < 3 || axes > 32)): mm_error(p.doc, p.pos, c"radar requires 3..32 axes")
		if (c.explicit_high == 0 && c.high == c.low): c.high = c.low + 1000
		if (c.high <= c.low): mm_error(p.doc, p.pos, c"chart maximum must exceed minimum")
		for mm_data_item* item in c.items:
			for int value in item.values:
				if (value < c.low || value > c.high): mm_error(p.doc, p.pos, c"series value outside axis range")
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
		else if (mm_match(p, c"title ")):
			free(p.doc.data.title)
			p.doc.data.title = mm_data_text(p, 10)
		else if (p.doc.kind == MM_PIE): mm_data_pie(p)
		else if (p.doc.kind == MM_QUADRANT): mm_data_quadrant(p)
		else if (p.doc.kind == MM_XY): mm_data_xy(p)
		else if (p.doc.kind == MM_SANKEY): mm_data_sankey(p)
		else if (p.doc.kind == MM_RADAR): mm_data_radar(p)
		else if (p.doc.kind == MM_TREEMAP): mm_data_tree(p)
		else if (p.doc.kind == MM_VENN): mm_data_venn(p)
		else: mm_data_packet(p)
		if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported data diagram syntax")
		mm_separators(p)
		if (start == p.pos): mm_error(p.doc, start, c"expected data diagram statement")
	if (p.doc.error == 0): mm_data_validate(p)
