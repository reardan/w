# A deliberately bounded CSS subset, shared by SVG and the native renderer.
import libs.extras.mermaid.parse_common

const int MM_STYLE_FILL = 1
const int MM_STYLE_STROKE = 2
const int MM_STYLE_TEXT = 4
const int MM_STYLE_WIDTH = 8

char* mm_style_trim(char* text, int start, int end):
	while (start < end && (text[start] == 32 || text[start] == 9 || text[start] == 13)): start = start + 1
	while (end > start && (text[end - 1] == 32 || text[end - 1] == 9 || text[end - 1] == 13)): end = end - 1
	return str_copy_range(text, start, end)

int mm_style_hex(int c):
	if (c >= '0' && c <= '9'): return c - '0'
	if (c >= 'a' && c <= 'f'): return c - 'a' + 10
	if (c >= 'A' && c <= 'F'): return c - 'A' + 10
	return -1

# -1 means transparent/none; -2 means invalid.
int mm_style_color(char* value):
	int length = strlen(value)
	if (value[0] == '#' && (length == 4 || length == 7)):
		int result = 0
		for i in range(1, length):
			int digit = mm_style_hex(value[i])
			if (digit < 0): return -2
			if (length == 4): result = result * 256 + digit * 17
			else: result = result * 16 + digit
		return result
	if (strcmp(value, c"none") == 0 || strcmp(value, c"transparent") == 0): return -1
	list[char*] names = list[char*]{c"black", c"white", c"red", c"green", c"blue", c"yellow", c"cyan", c"magenta", c"gray", c"grey", c"orange", c"purple", c"pink", c"navy", c"teal", c"lime"}
	list[int] values = list[int]{0, 0xffffff, 0xff0000, 0x008000, 0x0000ff, 0xffff00, 0x00ffff, 0xff00ff, 0x808080, 0x808080, 0xffa500, 0x800080, 0xffc0cb, 0x000080, 0x008080, 0x00ff00}
	int result = -2
	for i in range(names.length):
		if (strcmp(value, names[i]) == 0): result = values[i]
	__w_list_free(cast(__w_list*, names))
	__w_list_free(cast(__w_list*, values))
	return result

void mm_style_merge(mm_style* result, mm_style* next):
	if (next.mask & MM_STYLE_FILL): result.fill = next.fill
	if (next.mask & MM_STYLE_STROKE): result.stroke = next.stroke
	if (next.mask & MM_STYLE_TEXT): result.text = next.text
	if (next.mask & MM_STYLE_WIDTH): result.width = next.width
	result.mask = result.mask | next.mask

void mm_style_property(mm_document* d, mm_style* style, char* key, char* value, int offset):
	int mask = 0
	if (strcmp(key, c"fill") == 0): mask = MM_STYLE_FILL
	else if (strcmp(key, c"stroke") == 0): mask = MM_STYLE_STROKE
	else if (strcmp(key, c"color") == 0): mask = MM_STYLE_TEXT
	else if (strcmp(key, c"stroke-width") == 0): mask = MM_STYLE_WIDTH
	else:
		mm_error(d, offset, c"unsupported style property; supported: fill, stroke, color, stroke-width")
		return
	int parsed = -2
	if (mask == MM_STYLE_WIDTH):
		int length = strlen(value)
		if (length >= 2 && strcmp(value + length - 2, c"px") == 0): length = length - 2
		parsed = 0
		if (length == 0 || length > 2): parsed = -2
		for i in range(length):
			if (value[i] < '0' || value[i] > '9'): parsed = -2
			if (parsed >= 0): parsed = parsed * 10 + value[i] - '0'
		if (parsed < 1 || parsed > 16): parsed = -2
	else: parsed = mm_style_color(value)
	if (parsed == -2):
		mm_error(d, offset, c"invalid style value; use #RGB/#RRGGBB, a supported color name, none, or a 1-16px stroke width")
		return
	style.mask = style.mask | mask
	if (mask == MM_STYLE_FILL): style.fill = parsed
	if (mask == MM_STYLE_STROKE): style.stroke = parsed
	if (mask == MM_STYLE_TEXT): style.text = parsed
	if (mask == MM_STYLE_WIDTH): style.width = parsed

mm_style mm_style_parse(mm_parser* p):
	mm_style style
	style.mask = 0
	style.fill = 0
	style.stroke = 0
	style.text = 0
	style.width = 0
	int count = 0
	while (mm_end(p) == 0 && p.doc.error == 0):
		int start = p.pos
		while (mm_end(p) == 0 && mm_peek(p) != ':' && mm_peek(p) != ','): p.pos = p.pos + 1
		char* key = mm_style_trim(p.doc.source, start, p.pos)
		if (mm_match(p, c":") == 0): mm_error(p.doc, p.pos, c"style property requires colon")
		start = p.pos
		while (mm_end(p) == 0 && mm_peek(p) != ','): p.pos = p.pos + 1
		char* value = mm_style_trim(p.doc.source, start, p.pos)
		mm_style_property(p.doc, &style, key, value, start)
		free(key)
		free(value)
		count = count + 1
		if (count > 16): mm_error(p.doc, p.pos, c"style property limit exceeded")
		if (mm_match(p, c",") && mm_end(p)): mm_error(p.doc, p.pos, c"trailing style comma")
	if (count == 0): mm_error(p.doc, p.pos, c"expected style properties")
	return style

mm_style_class* mm_style_find(mm_document* d, char* name):
	for mm_style_class* definition in d.style_definitions:
		if (strcmp(name, definition.name) == 0): return definition
	return 0

int mm_style_name(char* name):
	if (name[0] == 0): return 0
	for i in range(strlen(name)):
		if (mm_id_char(name[i] & 255) == 0 && name[i] != '-'): return 0
	return 1

void mm_style_assign(mm_parser* p, mm_node* node, char* classes):
	if (strlen(node.style_classes) + strlen(classes) > 4096):
		mm_error(p.doc, p.pos, c"node class assignment limit exceeded")
		return
	int start = 0
	for i in range(strlen(classes) + 1):
		if (classes[i] == 0 || classes[i] == ','):
			char* name = mm_style_trim(classes, start, i)
			if (mm_style_name(name) == 0): mm_error(p.doc, p.pos, c"invalid style class name")
			free(name)
			start = i + 1
	string_builder* joined = string_from(node.style_classes)
	if (joined.length != 0): string_append_char(joined, ',')
	string_append(joined, classes)
	free(node.style_classes)
	node.style_classes = joined.data
	free(joined)

void mm_style_inline(mm_parser* p, mm_node* node):
	int start = p.pos
	while (mm_id_char(mm_peek(p)) || mm_peek(p) == '-'):
		if (mm_peek(p) == '-' && p.pos + 1 < p.doc.length && p.doc.source[p.pos + 1] == '-'): break
		p.pos = p.pos + 1
	char* name = str_copy_range(p.doc.source, start, p.pos)
	mm_style_assign(p, node, name)
	free(name)

int mm_style_keyword(mm_parser* p, char* word):
	int start = p.pos
	if (mm_match(p, word) == 0): return 0
	if (mm_peek(p) != 32 && mm_peek(p) != 9):
		p.pos = start
		return 0
	mm_space(p)
	return 1

int mm_style_statement(mm_parser* p):
	int kind = 0
	if (mm_style_keyword(p, c"style")): kind = 1
	else if (mm_style_keyword(p, c"classDef")): kind = 2
	else if (mm_style_keyword(p, c"cssClass")): kind = 3
	else if (p.doc.kind != MM_CLASS && mm_style_keyword(p, c"class")): kind = 3
	if (kind == 0): return 0
	char* targets
	if (mm_peek(p) == '"'): targets = mm_quoted(p)
	else:
		int start = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 32 && mm_peek(p) != 9 && mm_peek(p) != ';'): p.pos = p.pos + 1
		targets = str_copy_range(p.doc.source, start, p.pos)
	mm_space(p)
	mm_style style
	style.mask = 0
	style.fill = 0
	style.stroke = 0
	style.text = 0
	style.width = 0
	char* classes = strclone(c"")
	if (kind == 3):
		int start = p.pos
		while (mm_end(p) == 0): p.pos = p.pos + 1
		free(classes)
		classes = mm_style_trim(p.doc.source, start, p.pos)
	else: style = mm_style_parse(p)
	int start = 0
	for i in range(strlen(targets) + 1):
		if (targets[i] == 0 || targets[i] == ','):
			char* name = mm_style_trim(targets, start, i)
			if (mm_style_name(name) == 0): mm_error(p.doc, p.pos, c"invalid style target")
			else if (kind == 2):
				mm_style_class* definition = mm_style_find(p.doc, name)
				if (definition == 0):
					if (p.doc.style_definitions.length >= 128): mm_error(p.doc, p.pos, c"style class limit exceeded")
					else:
						definition = new mm_style_class()
						definition.name = strclone(name)
						p.doc.style_definitions.push(definition)
				if (definition != 0): mm_style_merge(&definition.style, &style)
			else:
				int index = mm_add_node(p.doc, name, p.pos)
				if (index >= 0):
					mm_node* node = p.doc.nodes[index]
					if (p.doc.kind == MM_STATE && node.shape == 0): node.shape = 1
					if (kind == 1): mm_style_merge(&node.style, &style)
					else: mm_style_assign(p, node, classes)
			free(name)
			start = i + 1
			if (p.doc.error != 0): break
	free(targets)
	free(classes)
	return 1

void mm_style_validate(mm_document* d):
	for mm_node* node in d.nodes:
		int start = 0
		int length = strlen(node.style_classes)
		if (length == 0): continue
		for i in range(length + 1):
			if (i == length || node.style_classes[i] == ','):
				char* name = mm_style_trim(node.style_classes, start, i)
				if (mm_style_find(d, name) == 0): mm_error(d, 0, c"assigned style class has no classDef")
				free(name)
				start = i + 1

int mm_style_theme(mm_document* d, char* name):
	d.palette.mask = 15
	d.palette.fill = 0xf8fafc
	d.palette.stroke = 0x334155
	d.palette.text = 0x0f172a
	d.palette.width = 2
	d.background = 0xffffff
	if (strcmp(name, c"default") == 0): d.theme = 1
	else if (strcmp(name, c"base") == 0):
		d.theme = 2
		d.palette.fill = 0xfff4dd
		d.palette.stroke = 0x937044
		d.palette.text = 0x333333
	else if (strcmp(name, c"dark") == 0):
		d.theme = 3
		d.palette.fill = 0x1f2937
		d.palette.stroke = 0x94a3b8
		d.palette.text = 0xf8fafc
		d.background = 0x0f172a
	else if (strcmp(name, c"forest") == 0):
		d.theme = 4
		d.palette.fill = 0xdcfce7
		d.palette.stroke = 0x166534
		d.palette.text = 0x14532d
	else if (strcmp(name, c"neutral") == 0):
		d.theme = 5
		d.palette.fill = 0xf5f5f5
		d.palette.stroke = 0x525252
		d.palette.text = 0x171717
	else: return 0
	d.palette_line = d.palette.stroke
	d.palette_label = d.palette.text
	return 1
