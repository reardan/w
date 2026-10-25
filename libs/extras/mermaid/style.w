# A deliberately bounded CSS subset, shared by SVG and the native renderer.
import libs.extras.mermaid.parse_common
import libs.extras.mermaid.text_metrics

const int MM_STYLE_FILL = 1
const int MM_STYLE_STROKE = 2
const int MM_STYLE_TEXT = 4
const int MM_STYLE_WIDTH = 8
const int MM_STYLE_DASH = 16
const int MM_STYLE_OPACITY = 32
const int MM_STYLE_WEIGHT = 64
const int MM_STYLE_ITALIC = 128
const int MM_STYLE_SIZE = 256
const int MM_STYLE_FAMILY = 512
const int MM_STYLE_RADIUS = 1024
const int MM_STYLE_FILL_OPACITY = 2048
const int MM_STYLE_MAX_FONTS = 32

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
	list[char*] names = list[char*]{c"black", c"white", c"red", c"green", c"blue", c"yellow", c"cyan", c"magenta", c"gray", c"grey", c"orange", c"purple", c"pink", c"navy", c"teal", c"lime", c"aqua", c"fuchsia", c"silver", c"maroon", c"olive", c"lightblue", c"lightgreen", c"lightgray", c"lightgrey", c"lightyellow", c"lavender", c"beige"}
	list[int] values = list[int]{0, 0xffffff, 0xff0000, 0x008000, 0x0000ff, 0xffff00, 0x00ffff, 0xff00ff, 0x808080, 0x808080, 0xffa500, 0x800080, 0xffc0cb, 0x000080, 0x008080, 0x00ff00, 0x00ffff, 0xff00ff, 0xc0c0c0, 0x800000, 0x808000, 0xadd8e6, 0x90ee90, 0xd3d3d3, 0xd3d3d3, 0xffffe0, 0xe6e6fa, 0xf5f5dc}
	int result = -2
	for i in range(names.length):
		if (strcmp(value, names[i]) == 0): result = values[i]
	__w_list_free(cast(__w_list*, names))
	__w_list_free(cast(__w_list*, values))
	return result

# Parses an integer 0..255, or (fraction set) an alpha 0..1 as hundredths.
# Returns -1 for malformed text; *at advances past the number.
int mm_style_channel(char* value, int* at, int fraction):
	int i = *at
	while (value[i] == 32): i = i + 1
	int number = 0
	int digits = 0
	while (value[i] >= '0' && value[i] <= '9' && digits < 4):
		number = number * 10 + value[i] - '0'
		digits = digits + 1
		i = i + 1
	if (fraction):
		number = number * 100
		if (value[i] == '.'):
			i = i + 1
			int scale = 10
			while (value[i] >= '0' && value[i] <= '9'):
				number = number + (value[i] - '0') * scale
				scale = scale / 10
				digits = digits + 1
				i = i + 1
		if (number > 100): return -1
	else if (number > 255): return -1
	while (value[i] == 32): i = i + 1
	*at = i
	if (digits == 0): return -1
	return number

# CSS rgb()/rgba() and case-insensitive names. Alpha is composited over the
# white diagram background because native primitives carry opaque colors.
int mm_style_css_color(char* value):
	int length = strlen(value)
	int alpha = index_of(value, c"rgba(") == 0
	if (alpha || index_of(value, c"rgb(") == 0):
		if (value[length - 1] != ')'): return -2
		int at = 4
		if (alpha): at = 5
		int result = 0
		int opacity = 100
		int parsed = 0
		list[int] channels = new list[int]
		for i in range(3 + alpha):
			int channel = mm_style_channel(value, &at, i == 3)
			if (channel < 0): break
			parsed = parsed + 1
			if (i == 3): opacity = channel
			else: channels.push(channel)
			if (i < 2 + alpha):
				if (value[at] != ','): break
				at = at + 1
		int valid = parsed == 3 + alpha && at == length - 1
		for int channel in channels: result = result * 256 + 255 - (255 - channel) * opacity / 100
		__w_list_free(cast(__w_list*, channels))
		if (valid == 0): return -2
		return result
	char* lower = strclone(value)
	for i in range(length):
		if (lower[i] >= 'A' && lower[i] <= 'Z'): lower[i] = lower[i] + 32
	int result = mm_style_color(lower)
	free(lower)
	return result

void mm_style_merge(mm_style* result, mm_style* next):
	int mask = next.mask
	if (mask & MM_STYLE_FILL): result.fill = next.fill
	if (mask & MM_STYLE_STROKE): result.stroke = next.stroke
	if (mask & MM_STYLE_TEXT): result.text = next.text
	if (mask & MM_STYLE_WIDTH): result.width = next.width
	if (mask & MM_STYLE_DASH):
		result.dash = next.dash
		result.gap = next.gap
	if (mask & MM_STYLE_OPACITY): result.opacity = next.opacity
	if (mask & MM_STYLE_FILL_OPACITY): result.fill_opacity = next.fill_opacity
	if (mask & MM_STYLE_WEIGHT): result.font = result.font - (result.font & MM_TEXT_BOLD) + (next.font & MM_TEXT_BOLD)
	if (mask & MM_STYLE_ITALIC): result.font = result.font - (result.font & MM_TEXT_ITALIC) + (next.font & MM_TEXT_ITALIC)
	if (mask & MM_STYLE_SIZE): result.font_size = next.font_size
	if (mask & MM_STYLE_FAMILY): result.family = next.family
	if (mask & MM_STYLE_RADIUS): result.radius = next.radius
	result.mask = result.mask | mask

void mm_style_clear(mm_style* style):
	style.mask = 0
	style.fill = 0
	style.stroke = 0
	style.text = 0
	style.width = 0
	style.dash = 0
	style.gap = 0
	style.opacity = 0
	style.fill_opacity = 0
	style.font = 0
	style.font_size = 0
	style.family = 0
	style.radius = 0

# Unsigned decimal of at most digits characters, optionally followed by px; -1 when malformed.
int mm_style_pixels(char* value, int start, int end, int digits):
	if (end - start >= 2 && value[end - 2] == 'p' && value[end - 1] == 'x'): end = end - 2
	if (end <= start || end - start > digits): return -1
	int result = 0
	for i in range(start, end):
		if (value[i] < '0' || value[i] > '9'): return -1
		result = result * 10 + value[i] - '0'
	return result

# CSS <alpha-value>: 0..1 with up to two decimals, or 0%..100%; hundredths or -1.
int mm_style_alpha(char* value):
	int length = strlen(value)
	if (length > 1 && value[length - 1] == '%'):
		int percent = mm_style_pixels(value, 0, length - 1, 3)
		if (percent > 100): return -1
		return percent
	int i = 0
	int whole = 0
	while (value[i] >= '0' && value[i] <= '9' && i < 2):
		whole = whole * 10 + value[i] - '0'
		i = i + 1
	int result = whole * 100
	int scale = 10
	if (value[i] == '.'):
		i = i + 1
		if (value[i] == 0): return -1
		while (value[i] >= '0' && value[i] <= '9' && scale > 0):
			result = result + (value[i] - '0') * scale
			scale = scale / 10
			i = i + 1
	if (i == 0 || value[i] != 0 || result > 100): return -1
	return result

# One family name, quoted or bare (letters, digits, spaces, - and _), up to 64 bytes.
char* mm_style_family_name(char* value):
	int length = strlen(value)
	int start = 0
	int end = length
	if (length >= 2 && (value[0] == '"' || value[0] == '\'') && value[length - 1] == value[0]):
		start = 1
		end = length - 1
	if (end <= start || end - start > 64): return 0
	for i in range(start, end):
		int c = value[i] & 255
		if (isalnum(c) == 0 && c != ' ' && c != '-' && c != '_'): return 0
	return str_copy_range(value, start, end)

# Index (1-based) of an interned family name in the document's font table, or 0.
int mm_style_font(mm_document* d, char* name, int offset):
	for i in range(d.style_fonts.length):
		if (strcmp(d.style_fonts[i], name) == 0): return i + 1
	if (d.style_fonts.length >= MM_STYLE_MAX_FONTS):
		mm_error(d, offset, c"font-family limit exceeded")
		return 0
	d.style_fonts.push(strclone(name))
	return d.style_fonts.length

void mm_style_property(mm_document* d, mm_style* style, char* key, char* value, int offset):
	list[char*] keys = list[char*]{c"fill", c"stroke", c"color", c"stroke-width", c"stroke-dasharray", c"opacity", c"font-weight", c"font-style", c"font-size", c"font-family", c"rx", c"fill-opacity", c"ry"}
	int mask = 0
	for i in range(keys.length):
		if (strcmp(key, keys[i]) == 0):
			mask = 1 << i
			if (i == 12): mask = MM_STYLE_RADIUS
	__w_list_free(cast(__w_list*, keys))
	if (mask == 0):
		mm_error(d, offset, c"unsupported style property; supported: fill, stroke, color, stroke-width, stroke-dasharray, opacity, fill-opacity, font-weight, font-style, font-size, font-family, rx, ry")
		return
	int length = strlen(value)
	int parsed = -2
	int extra = 0
	char* message = c"invalid style value; use #RGB/#RRGGBB, a supported color name, none, or a 1-16px stroke width"
	if (mask == MM_STYLE_WIDTH):
		parsed = mm_style_pixels(value, 0, length, 2)
		if (parsed < 1 || parsed > 16): parsed = -2
	else if (mask == MM_STYLE_DASH):
		message = c"stroke-dasharray takes none, 0, or one or two 1-64px lengths separated by a space"
		if (strcmp(value, c"none") == 0 || strcmp(value, c"0") == 0): parsed = 0
		else:
			int split = index_of(value, c" ")
			if (split < 0): split = length
			parsed = mm_style_pixels(value, 0, split, 2)
			extra = parsed
			if (split < length):
				int at = split
				while (value[at] == ' '): at = at + 1
				extra = mm_style_pixels(value, at, length, 2)
			if (parsed < 1 || parsed > 64 || extra < 1 || extra > 64): parsed = -2
	else if (mask == MM_STYLE_OPACITY || mask == MM_STYLE_FILL_OPACITY):
		message = c"opacity takes a number from 0 to 1 or a percentage"
		parsed = mm_style_alpha(value)
		if (parsed < 0): parsed = -2
	else if (mask == MM_STYLE_WEIGHT):
		message = c"font-weight takes normal, bold, bolder, lighter or 100-900"
		if (strcmp(value, c"bold") == 0 || strcmp(value, c"bolder") == 0): parsed = MM_TEXT_BOLD
		else if (strcmp(value, c"normal") == 0 || strcmp(value, c"lighter") == 0): parsed = 0
		else:
			int weight = mm_style_pixels(value, 0, length, 3)
			if (weight >= 100 && weight <= 900 && weight % 100 == 0):
				parsed = 0
				if (weight >= 600): parsed = MM_TEXT_BOLD
	else if (mask == MM_STYLE_ITALIC):
		message = c"font-style takes normal, italic or oblique"
		if (strcmp(value, c"italic") == 0 || strcmp(value, c"oblique") == 0): parsed = MM_TEXT_ITALIC
		else if (strcmp(value, c"normal") == 0): parsed = 0
	else if (mask == MM_STYLE_SIZE):
		message = c"font-size takes 8-72px"
		parsed = mm_style_pixels(value, 0, length, 2)
		if (parsed < 8 || parsed > 72): parsed = -2
	else if (mask == MM_STYLE_FAMILY):
		message = c"font-family takes one quoted or plain family name"
		char* name = mm_style_family_name(value)
		if (name != 0):
			parsed = mm_style_font(d, name, offset)
			free(name)
			if (parsed == 0): return
	else if (mask == MM_STYLE_RADIUS):
		message = c"rx and ry take 0-64px"
		parsed = mm_style_pixels(value, 0, length, 2)
		if (parsed > 64): parsed = -2
		if (parsed < 0): parsed = -2
	else: parsed = mm_style_color(value)
	if (parsed == -2):
		mm_error(d, offset, message)
		return
	style.mask = style.mask | mask
	if (mask == MM_STYLE_FILL): style.fill = parsed
	if (mask == MM_STYLE_STROKE): style.stroke = parsed
	if (mask == MM_STYLE_TEXT): style.text = parsed
	if (mask == MM_STYLE_WIDTH): style.width = parsed
	if (mask == MM_STYLE_DASH):
		style.dash = parsed
		style.gap = extra
	if (mask == MM_STYLE_OPACITY): style.opacity = parsed
	if (mask == MM_STYLE_FILL_OPACITY): style.fill_opacity = parsed
	if (mask == MM_STYLE_WEIGHT): style.font = style.font - (style.font & MM_TEXT_BOLD) + parsed
	if (mask == MM_STYLE_ITALIC): style.font = style.font - (style.font & MM_TEXT_ITALIC) + parsed
	if (mask == MM_STYLE_SIZE): style.font_size = parsed
	if (mask == MM_STYLE_FAMILY): style.family = parsed
	if (mask == MM_STYLE_RADIUS): style.radius = parsed

# C4 UpdateElementStyle / UpdateRelStyle arguments ($bgColor="red" ...) as
# the shared CSS subset: returns 1 when name is a styling argument (its value
# is then checked like the matching CSS property), 0 for other arguments.
int mm_style_c4_property(mm_document* d, mm_style* style, char* name, char* value, int offset):
	list[char*] names = list[char*]{c"$bgColor", c"$fontColor", c"$borderColor", c"$lineColor", c"$textColor", c"$borderThickness", c"$borderStyle"}
	list[char*] keys = list[char*]{c"fill", c"color", c"stroke", c"stroke", c"color", c"stroke-width", c"stroke-dasharray"}
	int found = -1
	for i in range(names.length):
		if (strcmp(name, names[i]) == 0): found = i
	if (found == 6):
		# Upstream's c4 border styles: dashed and dotted map to dash arrays.
		if (strcmp(value, c"dashed") == 0): mm_style_property(d, style, keys[found], c"6 4", offset)
		else if (strcmp(value, c"dotted") == 0): mm_style_property(d, style, keys[found], c"2 2", offset)
		else if (strcmp(value, c"solid") != 0): mm_error(d, offset, c"C4 $borderStyle must be solid, dashed or dotted")
	else if (found >= 0): mm_style_property(d, style, keys[found], value, offset)
	__w_list_free(cast(__w_list*, names))
	__w_list_free(cast(__w_list*, keys))
	return found >= 0

mm_style mm_style_parse(mm_parser* p):
	mm_style style
	mm_style_clear(&style)
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

# classDef default, then assigned classes in order, then the node's own style.
mm_style mm_style_resolve(mm_document* d, mm_node* node):
	mm_style resolved
	mm_style_clear(&resolved)
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
	return resolved

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

# Link indices refer to already declared edges, matching their source order.
int mm_style_links(mm_parser* p):
	if (mm_style_keyword(p, c"linkStyle") == 0): return 0
	int start = p.pos
	while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 32 && mm_peek(p) != 9 && mm_peek(p) != ';'): p.pos = p.pos + 1
	char* targets = str_copy_range(p.doc.source, start, p.pos)
	mm_space(p)
	mm_style style = mm_style_parse(p)
	if (style.mask & MM_STYLE_FILL): mm_error(p.doc, start, c"linkStyle supports stroke, color and stroke-width")
	if (strcmp(targets, c"default") == 0): mm_style_merge(&p.doc.edge_style, &style)
	else:
		int index = 0
		int digits = 0
		for i in range(strlen(targets) + 1):
			int c = targets[i]
			if (c == ',' || c == 0):
				if (digits == 0 || index >= p.doc.edges.length): mm_error(p.doc, start, c"linkStyle requires an existing edge index")
				else:
					mm_edge* edge = p.doc.edges[index]
					mm_style_merge(&edge.style, &style)
				index = 0
				digits = 0
			else if (c < '0' || c > '9' || index >= MM_MAX_ITEMS):
				mm_error(p.doc, start, c"invalid linkStyle index")
				break
			else:
				index = index * 10 + c - '0'
				digits = digits + 1
	free(targets)
	return 1

int mm_style_statement(mm_parser* p):
	if (mm_style_links(p)): return 1
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
	mm_style_clear(&style)
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
	# Mindmap and TreeView classes name stylesheet (themeCSS) classes; unknown names are ignored.
	if (d.kind == MM_MINDMAP || d.kind == MM_TREEVIEW): return
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

# Theme variables. Indices are in dependency order: every derived variable
# names an earlier source, so one forward pass resolves the whole palette.
const int MM_THEME_BACKGROUND = 0
const int MM_THEME_PRIMARY = 1
const int MM_THEME_PRIMARY_BORDER = 2
const int MM_THEME_PRIMARY_TEXT = 3
const int MM_THEME_SECONDARY = 4
const int MM_THEME_TERTIARY = 7
const int MM_THEME_LINE = 10
const int MM_THEME_TEXT = 11
const int MM_THEME_MAIN_BKG = 12
const int MM_THEME_NODE_BORDER = 13
const int MM_THEME_CLUSTER_BKG = 14
const int MM_THEME_CLUSTER_BORDER = 15
const int MM_THEME_TITLE = 16
const int MM_THEME_EDGE_LABEL_BKG = 17
const int MM_THEME_PIE = 18
const int MM_THEME_SCALE = 30
const int MM_THEME_NOTE_BKG = 42
const int MM_THEME_NOTE_BORDER = 43
const int MM_THEME_NOTE_TEXT = 44
const int MM_THEME_ACTOR_BKG = 45
const int MM_THEME_ACTOR_BORDER = 46
const int MM_THEME_ACTOR_TEXT = 47
const int MM_THEME_ACTOR_LINE = 48
const int MM_THEME_SIGNAL = 49
const int MM_THEME_SIGNAL_TEXT = 50
const int MM_THEME_GIT = 51
const int MM_THEME_VENN = 59
const int MM_THEME_TASK_BKG = 67
const int MM_THEME_TASK_BORDER = 68
const int MM_THEME_TASK_TEXT = 69
const int MM_THEME_ACTIVE_TASK_BKG = 70
const int MM_THEME_DONE_TASK_BKG = 71
const int MM_THEME_CRIT_BKG = 72
const int MM_THEME_GRID = 73
const int MM_THEME_TODAY = 74
const int MM_THEME_SECTION_BKG = 75
const int MM_THEME_ALT_SECTION_BKG = 76
const int MM_THEME_EXCLUDE_BKG = 77
const int MM_THEME_ROW_ODD = 78
const int MM_THEME_ROW_EVEN = 79
const int MM_THEME_GRADIENT_START = 80
const int MM_THEME_GRADIENT_STOP = 81
const int MM_THEME_COUNT = 82
const int MM_THEME_UNSET = -2

const int MM_THEME_ROOT = 0
const int MM_THEME_COPY = 1
const int MM_THEME_ADJUST = 2
const int MM_THEME_BORDER = 3
const int MM_THEME_CONTRAST = 4
const int MM_THEME_INVERT = 5
const int MM_THEME_EDGE = 6
const int MM_THEME_GIT_SHADE = 7

# Fixed categorical colors: the native series palette without a configured theme.
int mm_style_series_color(int index):
	list[int] colors = list[int]{0x2563eb, 0xdc2626, 0x16a34a, 0x9333ea, 0xea580c, 0x0891b2, 0xdb2777, 0x65a30d, 0x4f46e5, 0x0d9488, 0xca8a04, 0x7c3aed}
	int color = colors[index % colors.length]
	__w_list_free(cast(__w_list*, colors))
	return color

# Small decimal suffix of pie1..pie12 / cScale0..cScale11; -1 when malformed.
int mm_theme_digits(char* text):
	int length = strlen(text)
	if (length == 0 || length > 2 || (length == 2 && text[0] == '0')): return -1
	int value = 0
	for i in range(length):
		if (text[i] < '0' || text[i] > '9'): return -1
		value = value * 10 + text[i] - '0'
	return value

# Variable index for a themeVariables key, or -1 when unsupported.
int mm_theme_variable(char* name):
	list[char*] names = list[char*]{c"background", c"primaryColor", c"primaryBorderColor", c"primaryTextColor", c"secondaryColor", c"secondaryBorderColor", c"secondaryTextColor", c"tertiaryColor", c"tertiaryBorderColor", c"tertiaryTextColor", c"lineColor", c"textColor", c"mainBkg", c"nodeBorder", c"clusterBkg", c"clusterBorder", c"titleColor", c"edgeLabelBackground"}
	list[char*] extras = list[char*]{c"noteBkgColor", c"noteBorderColor", c"noteTextColor", c"actorBkg", c"actorBorder", c"actorTextColor", c"actorLineColor", c"signalColor", c"signalTextColor", c"git0", c"git1", c"git2", c"git3", c"git4", c"git5", c"git6", c"git7", c"venn1", c"venn2", c"venn3", c"venn4", c"venn5", c"venn6", c"venn7", c"venn8", c"taskBkgColor", c"taskBorderColor", c"taskTextColor", c"activeTaskBkgColor", c"doneTaskBkgColor", c"critBkgColor", c"gridColor", c"todayLineColor", c"sectionBkgColor", c"altSectionBkgColor", c"excludeBkgColor", c"attributeBackgroundColorOdd", c"attributeBackgroundColorEven", c"gradientStart", c"gradientStop"}
	int result = -1
	for i in range(names.length):
		if (strcmp(name, names[i]) == 0): result = i
	for i in range(extras.length):
		if (strcmp(name, extras[i]) == 0): result = MM_THEME_NOTE_BKG + i
	__w_list_free(cast(__w_list*, names))
	__w_list_free(cast(__w_list*, extras))
	if (result >= 0): return result
	if (index_of(name, c"pie") == 0):
		int number = mm_theme_digits(name + 3)
		if (number >= 1 && number <= 12): return MM_THEME_PIE + number - 1
	if (index_of(name, c"cScale") == 0):
		int number = mm_theme_digits(name + 6)
		if (number >= 0 && number <= 11): return MM_THEME_SCALE + number
	return -1

int mm_theme_abs(int value):
	if (value < 0): return 0 - value
	return value

int mm_theme_clamp(int value, int low, int high):
	if (value < low): return low
	if (value > high): return high
	return value

int mm_theme_channel(int value):
	return mm_theme_clamp((value * 255 + 500) / 1000, 0, 255)

# Integer HSL adjustment in the style of khroma's adjust(): hue in degrees,
# saturation and lightness in percentage points, clamped; hue wraps.
int mm_theme_adjust(int rgb, int dh, int ds, int dl):
	int r = (rgb >> 16) & 255
	int g = (rgb >> 8) & 255
	int b = rgb & 255
	int high = r
	if (g > high): high = g
	if (b > high): high = b
	int low = r
	if (g < low): low = g
	if (b < low): low = b
	int light = (high + low) * 1000 / 510
	int sat = 0
	int hue = 0
	int delta = high - low
	if (delta != 0):
		if (high + low > 255): sat = delta * 1000 / (510 - high - low)
		else: sat = delta * 1000 / (high + low)
		if (high == r): hue = (g - b) * 600 / delta
		else if (high == g): hue = (b - r) * 600 / delta + 1200
		else: hue = (r - g) * 600 / delta + 2400
	hue = ((hue + dh * 10) % 3600 + 3600) % 3600
	sat = mm_theme_clamp(sat + ds * 10, 0, 1000)
	light = mm_theme_clamp(light + dl * 10, 0, 1000)
	int chroma = (1000 - mm_theme_abs(2 * light - 1000)) * sat / 1000
	int x = chroma * (600 - mm_theme_abs(hue % 1200 - 600)) / 600
	int m = light - chroma / 2
	int sector = hue / 600
	int rr = chroma
	int gg = x
	int bb = 0
	if (sector == 1):
		rr = x
		gg = chroma
	else if (sector == 2):
		rr = 0
		gg = chroma
		bb = x
	else if (sector == 3):
		rr = 0
		gg = x
		bb = chroma
	else if (sector == 4):
		rr = x
		gg = 0
		bb = chroma
	else if (sector == 5):
		gg = 0
		bb = x
	return (mm_theme_channel(rr + m) << 16) | (mm_theme_channel(gg + m) << 8) | mm_theme_channel(bb + m)

int mm_theme_derive(int op, int source, int dh, int dl, int dark):
	if (op == MM_THEME_COPY): return source
	if (op == MM_THEME_ADJUST): return mm_theme_adjust(source, dh, 0, dl)
	if (op == MM_THEME_GIT_SHADE):
		if (dark): return mm_theme_adjust(source, dh, 0, 0 - dl)
		return mm_theme_adjust(source, dh, 0, dl)
	if (op == MM_THEME_BORDER):
		if (dark): return mm_theme_adjust(source, 0, -40, 10)
		return mm_theme_adjust(source, 0, -40, -10)
	if (op == MM_THEME_CONTRAST):
		int luminance = (((source >> 16) & 255) * 299 + ((source >> 8) & 255) * 587 + (source & 255) * 114) / 1000
		if (luminance >= 128): return 0x333333
		return 0xeeeeee
	if (op == MM_THEME_INVERT): return 0xffffff - source
	if (dark): return mm_theme_adjust(source, 0, 0, -30)
	return source

# Theme identifier for a theme name, or 0.
int mm_style_theme_id(char* name):
	list[char*] names = list[char*]{c"default", c"base", c"dark", c"forest", c"neutral", c"neo", c"neo-dark", c"redux", c"redux-dark", c"redux-color", c"redux-dark-color"}
	int result = 0
	for i in range(names.length):
		if (strcmp(name, names[i]) == 0): result = i + 1
	__w_list_free(cast(__w_list*, names))
	return result

# Upstream mermaid@12.2.0 resolved values (packages/mermaid/src/themes/theme-*.js),
# one row per variable and one 6-digit column per theme in mm_style_theme_id
# order. Translucent values are composited over the theme background and
# "------" marks a variable the theme leaves to derivation.
int mm_theme_upstream(list[char*] rows, int variable, int theme):
	char* row = rows[variable]
	int at = (theme - 1) * 7
	if (row[at] == '-'): return MM_THEME_UNSET
	int value = 0
	for i in range(6): value = value * 16 + mm_style_hex(row[at + i])
	return value

list[char*] mm_theme_rows():
	return list[char*]{c"ffffff f4f4f4 333333 ffffff ffffff ffffff 333333 ffffff 333333 ffffff 333333", c"ececff fff4dd 1f2020 cde498 eeeeee cccccc 1f2020 cccccc 1f2020 cccccc 1f2020", c"c7c7f1 eeddbb cccccc abb594 d4d4d4 b3b3b3 cccccc 181818 cccccc 181818 cccccc", c"131300 333333 e0dfdf 321b67 111111 333333 e0dfdf 28253d e0dfdf 28253d e0dfdf", c"ffffde f4ddff 474949 cdffb2 fcfcfc cccccc 474949 cccccc 474949 cccccc 474949", c"eeeebc ddbbee 2f2f2f b4e599 e3e3e3 b3b3b3 2f2f2f b3b3b3 2f2f2f b3b3b3 2f2f2f", c"000021 0b2200 b8b6b6 32004d 030303 333333 b8b6b6 333333 b8b6b6 333333 b8b6b6", c"f9ffec f6f9ff 201f1f e1efc0 eeeeee ffffff 201f1f ffffff 201f1f ffffff 201f1f", c"e3f1c7 cfdbf3 060606 c3cab2 d4d4d4 e6e6e6 060606 e6e6e6 060606 e6e6e6 060606", c"060013 090600 dfe0e0 321b67 111111 000000 dfe0e0 000000 dfe0e0 000000 dfe0e0", c"333333 0b0b0b d3d3d3 000000 666666 000000 cccccc 000000 cccccc 000000 cccccc", c"333333 333333 cccccc 000000 000000 333333 cccccc 28253d cccccc 28253d cccccc", c"ececff fff4dd 1f2020 cde498 eeeeee ffffff 2a2020 ffffff 111113 ffffff 111113", c"9370db eeddbb cccccc 13540c 999999 000000 cccccc 28253d ffffff 28253d ffffff", c"ffffde f6f9ff 474949 cdffb2 fcfcfc ffffff 201f1f f9f9fb 1e1a2e f9f9fb 1e1a2e", c"aaaa33 cfdbf3 666666 6eaa49 707070 e6e6e6 060606 bdbccc bdbccc bdbccc bdbccc", c"333333 090600 f9fffe 333333 333333 000000 dfe0e0 000000 dfe0e0 000000 dfe0e0", c"ededed f4ddff 585858 e8e8e8 ffffff cccccc 474949 cccccc 474949 cccccc 474949", c"ececff fff4dd 0b0000 cde498 f4f4f4 ececfe 1f2020 ececfe 1f2020 f4a8ff f4a8ff", c"ffffde f4ddff 4d1037 cdffb2 555555 e9e9f1 474949 e9e9f1 474949 46ecd5 46ecd5", c"b5ff20 f6f9ff 3f5258 e1efc0 bbbbbb ffffff 201f1f ffffff 201f1f ffb86a ffb86a", c"b9b9ff ffe3aa 4f2f1b 8cb42f 777777 bcbcfb 060606 bcbcfb 060606 dab2ff dab2ff", c"ffff45 e3aaff 6e0a0a 6aff19 999999 cacadd 2e3030 cacadd 2e3030 7bf1a8 7bf1a8", c"d7ff86 c3d7ff 3b0048 33b42f dddddd fcfccf 060606 fcfccf 060606 c4b4ff c4b4ff", c"ff86ff c5ffaa 995a01 70d990 ffffff fbbcfb 060606 fbbcfb 060606 ffa2a2 ffa2a2", c"20ffff ffaac5 154706 d99070 dddddd bcfbfb 060606 bcfbfb 060606 ffdf20 ffdf20", c"ff2020 ddfff4 161722 98cde4 bbbbbb feecec 201f20 feecec 201f20 a3b3ff a3b3ff", c"ff20ff a3ff77 00296f 1a6330 999999 f98bf9 000000 f98bf9 000000 bbf451 bbf451", c"20ff8f ff77a3 01629c 63301a 777777 8bf9f9 000000 8bf9f9 000000 74d4ff 74d4ff", c"ff5353 aaffe3 ------ 1a4d63 555555 fbbcbc 060606 fbbcbc 060606 ffa1ad ffa1ad", c"8686ff ffcb5d 1f2020 b9d970 555555 7373f8 000000 bfbfbf 000000 f4a8ff f4a8ff", c"ffff78 cb5dff 0b0000 acff7f f4f4f4 9b9bbf 080909 bfbfbf 080909 46ecd5 46ecd5", c"d7ff86 77a3ff 4d1037 cde498 555555 f9f986 000000 bfbfbf 000000 ffb86a ffb86a", c"c286ff e3ff5d 3f5258 84d970 bbbbbb b573f8 000000 bfbfbf 000000 dab2ff dab2ff", c"ff86ff 92ff5d 4f2f1b 70d990 777777 f873f8 000000 bfbfbf 000000 7bf1a8 7bf1a8", c"ff86c2 5dff7a 6e0a0a 70d9c5 999999 f873b5 000000 bfbfbf 000000 c4b4ff c4b4ff", c"ff8686 5dffcb 3b0048 70b9d9 dddddd f87373 000000 bfbfbf 000000 ffa2a2 ffa2a2", c"ffc286 5de3ff 995a01 7084d9 ffffff f8b573 000000 bfbfbf 000000 ffdf20 ffdf20", c"c2ff86 9680ff 154706 c570d9 dddddd bff986 c0bfbe bfbfbf c0bfbe a3b3ff a3b3ff", c"86ffc2 ff5de3 161722 d97084 bbbbbb 73f8b5 000000 bfbfbf 000000 bbf451 bbf451", c"86ffff ff5d92 00296f d99070 999999 73f8f8 000000 bfbfbf 000000 74d4ff 74d4ff", c"86c2ff ff7a5d 01629c d9c570 777777 73b5f8 000000 bfbfbf 000000 ffa1ad ffa1ad", c"fff5ad fff5ad 474949 fff5ad 666666 fff5ad fff5ad fff5ad fef9c3 fff5ad fef9c3", c"aaaa33 e4db95 2f2f2f 6eaa49 999999 e4db95 e4db95 facc15 facc15 facc15 facc15", c"000000 333333 b8b6b6 000000 ffffff 333333 333333 28253d 28253d 28253d 28253d", c"ececff fff4dd 1f2020 cde498 eeeeee ffffff 2a2020 ffffff 111113 ffffff 111113", c"9370db eeddbb cccccc a6cf47 d4d4d4 b3b3b3 cccccc 28253d ffffff 28253d ffffff", c"000000 333333 d3d3d3 000000 333333 333333 e0dfdf 28253d e0dfdf 28253d e0dfdf", c"9370db eeddbb cccccc a6cf47 d4d4d4 b3b3b3 cccccc 28253d ffffff 28253d ffffff", c"333333 333333 d3d3d3 333333 333333 333333 cccccc 28253d ffffff 28253d ffffff", c"333333 333333 d3d3d3 333333 333333 333333 cccccc 28253d cccccc 28253d cccccc", c"0000ec ffcb5d 797d7d 9bc834 b4b4b4 7373f8 8b0000 7373f8 000000 7373f8 000000", c"dede00 cb5dff a12273 7aff32 555555 9b9bbf b72682 9b9bbf 080909 9b9bbf 080909", c"9dec00 77a3ff 6a8993 b0d45b bbbbbb f9f986 78959e f9f986 000000 f9f986 000000", c"0076ec ff7a5d 9b5c35 c8ab34 777777 73b5f8 ae683b 73b5f8 000000 73b5f8 000000", c"00ecec ff5d92 cb1313 c86134 999999 73f8f8 e31515 73f8f8 000000 73f8f8 000000", c"00ec76 ff5de3 65007b c83452 dddddd 73f8b5 a300c7 73f8b5 000000 73f8b5 000000", c"ec00ec 92ff5d cc7801 34c861 ffffff f873f8 fea01c f873f8 000000 f873f8 000000", c"ec0000 5dffcb 31a50e 349bc8 dddddd f87373 38bd10 f87373 000000 f87373 000000", c"5353ff ffc244 6a6e6e 8cb42f 555555 ------ ------ ------ ------ e879f9 e879f9", c"ffff45 c244ff a40000 6aff19 f4f4f4 ------ ------ ------ ------ 2dd4bf 2dd4bf", c"b5ff20 5d92ff cc2a91 a6cf47 555555 ------ ------ ------ ------ fb923c fb923c", c"ff53ff 80ff44 87a1a9 2fb457 bbbbbb ------ ------ ------ ------ 22d3ee 22d3ee", c"53ffff ff4480 bf7344 b4572f 777777 ------ ------ ------ ------ 4ade80 4ade80", c"45ff45 ff4480 eb2626 19ffae 999999 ------ ------ ------ ------ a78bfa a78bfa", c"ff5353 44ffc2 b800e1 2f8cb4 dddddd ------ ------ ------ ------ f87171 f87171", c"45ffff ffc244 feab35 196aff ffffff ------ ------ ------ ------ facc15 facc15", c"8a90dd fff4dd 595c5c 487e3a 707070 ececfe 1f2020 ececfe 1f2020 ececfe 1f2020", c"534fbc eeddbb ffffff 13540c 575757 b3b3b3 cccccc 181818 cccccc 181818 cccccc", c"ffffff 333333 e2dcd6 ffffff ffffff 333333 cccccc 28253d cccccc 28253d cccccc", c"bfc7ff ffffff 81b1db cde498 eeeeee ffffff 595c5c ffffff 595c5c ffffff 595c5c", c"d3d3d3 d3d3d3 d3d3d3 d3d3d3 bbbbbb d3d3d3 584343 d3d3d3 38383e d3d3d3 38383e", c"ff0000 ff0000 e83737 ff0000 dd4422 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000", c"d3d3d3 d3d3d3 d3d3d3 d3d3d3 e6e6e6 d3d3d3 d3d3d3 d3d3d3 d3d3d3 d3d3d3 d3d3d3", c"ff0000 ff0000 db5757 ff0000 dd4422 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000", c"b4b4ff f6f9ff b4ac76 6eaa49 bdbdbd ffffff 201f1f ffffff 201f1f f4a8ff f4a8ff", c"ffffff ffffff 333333 ffffff ffffff ffffff ffffff ffffff ffffff ffffff 333333", c"eeeeee eeeeee 9f9758 eeeeee eeeeee eeeeee eeeeee eeeeee eeeeee eeeeee eeeeee", c"ffffff ffffff 525252 ffffff ffffff ffffff ffffff ffffff ffffff ffffff ffffff", c"f2f2f2 f2f2f2 383838 f2f2f2 f2f2f2 f2f2f2 f2f2f2 f2f2f2 f2f2f2 f2f2f2 f2f2f2", c"c7c7f1 eeddbb cccccc abb594 d4d4d4 0042eb 0042eb 0042eb 0042eb 0042eb 0042eb", c"eeeebc ddbbee 2f2f2f b4e599 e3e3e3 eb0042 eb0042 eb0042 eb0042 eb0042 eb0042"}

# Per-theme scalars (which): 0 stroke width, 1 label font size, 2/3 drop
# shadow dx/dy, 4 shadow color, 5 shadow alpha in hundredths, 6 whether neo
# node strokes use the gradient. The redux themes name an SVG filter
# (url(#drop-shadow)) instead of a drop-shadow(); natively they use neo's.
int mm_theme_scalar(int theme, int which):
	list[int] widths = list[int]{1, 1, 1, 1, 1, 2, 1, 2, 2, 2, 2}
	list[int] sizes = list[int]{16, 16, 16, 16, 16, 14, 14, 14, 14, 14, 14}
	list[int] dxs = list[int]{1, 1, 1, 1, 1, 0, 1, 0, 0, 0, 0}
	list[int] dys = list[int]{2, 2, 2, 2, 2, 1, 2, 1, 1, 1, 1}
	list[int] colors = list[int]{0xb9b9b9, 0xb9b9b9, 0xb9b9b9, 0xb9b9b9, 0xb9b9b9, 0, 0xb9b9b9, 0, 0, 0, 0}
	list[int] alphas = list[int]{100, 100, 100, 50, 100, 25, 20, 25, 25, 25, 25}
	list[int] gradients = list[int]{0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0}
	int result = 0
	if (which == 0): result = widths[theme - 1]
	else if (which == 1): result = sizes[theme - 1]
	else if (which == 2): result = dxs[theme - 1]
	else if (which == 3): result = dys[theme - 1]
	else if (which == 4): result = colors[theme - 1]
	else if (which == 5): result = alphas[theme - 1]
	else if (which == 6): result = gradients[theme - 1]
	__w_list_free(cast(__w_list*, widths))
	__w_list_free(cast(__w_list*, sizes))
	__w_list_free(cast(__w_list*, dxs))
	__w_list_free(cast(__w_list*, dys))
	__w_list_free(cast(__w_list*, colors))
	__w_list_free(cast(__w_list*, alphas))
	__w_list_free(cast(__w_list*, gradients))
	return result

# Resolve every theme variable. user holds MM_THEME_COUNT explicit values
# (MM_THEME_UNSET when absent); dark is -1 for the theme's own mode. A variable
# keeps the selected theme's upstream value unless it, or a variable it derives
# from, was set explicitly; then it is derived the way Mermaid's theme-base
# derives it.
void mm_style_theme_resolve(mm_document* d, int theme, list[int] user, int dark):
	if (theme == 0): theme = 1
	d.theme = theme
	list[int] modes = list[int]{0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 1}
	list[int] sources = list[int]{-1, -1, 1, 1, 1, 4, 4, 1, 7, 7, 0, 3, 1, 2, 7, 8, 11, 4, 1, 4, 7, 1, 4, 7, 1, 1, 1, 1, 1, 1, 1, 4, 7, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, 42, -1, 12, 2, 3, 46, 11, 11, 1, 4, 7, 1, 1, 1, 1, 1, 1, 4, 7, 1, 1, 4, 1, 4, 1, 2, 11, 1, -1, -1, -1, -1, 7, -1, -1, -1, -1, 2, 5}
	list[int] ops = list[int]{0, 0, 3, 4, 2, 3, 5, 2, 3, 5, 5, 1, 1, 1, 1, 1, 1, 6, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 3, 0, 1, 1, 1, 1, 1, 1, 7, 7, 7, 7, 7, 7, 7, 7, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1}
	list[int] hues = list[int]{0, 0, 0, 0, -120, 0, 0, 180, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 60, -60, 120, 60, -60, 120, 0, 0, 0, 30, 60, 90, 120, 150, 210, 270, 300, 330, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -30, -60, -90, 60, 120, 0, 0, 0, 60, -60, 60, 120, 120, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	list[int] lights = list[int]{0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -10, -10, -10, -10, -10, 0, -20, -20, -10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -25, -25, -25, -25, -25, -25, -25, -25, -30, -30, -30, -30, -30, -30, -30, -30, 0, 0, 0, 23, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	list[char*] rows = mm_theme_rows()
	if (dark < 0): dark = modes[theme - 1]
	list[int] values = new list[int]
	list[int] touched = new list[int]
	for v in range(MM_THEME_COUNT):
		int value = MM_THEME_UNSET
		if (user != 0): value = user[v]
		int changed = value != MM_THEME_UNSET
		if (changed == 0):
			int source = sources[v]
			int native = mm_theme_upstream(rows, v, theme)
			if (source >= 0 && touched[source]): changed = 1
			if (changed == 0 && native != MM_THEME_UNSET): value = native
			else if (source >= 0): value = mm_theme_derive(ops[v], values[source], hues[v], lights[v], dark)
			else: value = 0
		values.push(value)
		touched.push(changed)
	d.palette.mask = 15
	d.palette.fill = values[MM_THEME_MAIN_BKG]
	d.palette.stroke = values[MM_THEME_NODE_BORDER]
	d.palette.text = values[MM_THEME_PRIMARY_TEXT]
	d.palette.width = mm_theme_scalar(theme, 0)
	d.palette_line = values[MM_THEME_LINE]
	d.palette_label = values[MM_THEME_TEXT]
	d.background = values[MM_THEME_BACKGROUND]
	# The neo and redux themes set a 14px label font unless fontSize is configured.
	if (d.font_size == 0 && mm_theme_scalar(theme, 1) != MM_TEXT_SIZE): d.font_size = mm_theme_scalar(theme, 1)
	if (d.theme_values != 0): __w_list_free(cast(__w_list*, d.theme_values))
	d.theme_values = values
	__w_list_free(cast(__w_list*, rows))
	__w_list_free(cast(__w_list*, modes))
	__w_list_free(cast(__w_list*, sources))
	__w_list_free(cast(__w_list*, ops))
	__w_list_free(cast(__w_list*, hues))
	__w_list_free(cast(__w_list*, lights))
	__w_list_free(cast(__w_list*, touched))

# Native layered-layout gaps; flowchart nodeSpacing/rankSpacing override them.
int mm_style_lane_gap(mm_document* d):
	if (d.kind == MM_FLOW && (d.config_mask & 1)): return d.node_spacing * 2
	return 100

int mm_style_rank_gap(mm_document* d):
	if (d.kind == MM_FLOW && (d.config_mask & 2)): return d.rank_spacing + 90
	return 140

# Font size configuration: 8..72, optionally followed by px; -1 when invalid.
int mm_style_font_size_value(char* value):
	int size = mm_style_pixels(value, 0, strlen(value), 2)
	if (size < 8 || size > 72): return -1
	return size

# A CSS font-family list for fontFamily configuration: family names, quotes,
# commas and spaces, at most 128 bytes.
int mm_style_family_list(char* value):
	int length = strlen(value)
	if (length == 0 || length > 128): return 0
	for i in range(length):
		int c = value[i] & 255
		if (isalnum(c) == 0 && c != ' ' && c != ',' && c != '-' && c != '_' && c != '"' && c != '\''): return 0
	return 1

# Skip whitespace and /* comments */ in themeCSS text.
int mm_style_css_space(char* css, int at):
	while (css[at] != 0):
		if (css[at] == ' ' || css[at] == 9 || css[at] == 10 || css[at] == 13): at = at + 1
		else if (css[at] == '/' && css[at + 1] == '*'):
			int close = index_of(css + at + 2, c"*/")
			if (close < 0): return strlen(css)
			at = at + close + 4
		else: return at
	return at

# themeCSS subset: rules ".name[, .name...] { property: value; ... }" whose
# declarations use the classDef property set; each rule merges into the named
# class definitions (creating them), so `class`/`:::` can assign them.
# `!important` is accepted and ignored. Other selectors, at-rules and
# malformed text fail with a diagnostic.
void mm_style_theme_css(mm_document* d, char* css, int offset):
	char* message = c"themeCSS supports .class { property: value; } rules"
	int at = mm_style_css_space(css, 0)
	int rules = 0
	while (css[at] != 0 && d.error == 0):
		list[char*] names = new list[char*]
		while (d.error == 0):
			if (css[at] != '.'):
				mm_error(d, offset, message)
				break
			int start = at + 1
			at = start
			while (mm_id_char(css[at] & 255) || css[at] == '-'): at = at + 1
			char* name = str_copy_range(css, start, at)
			if (mm_style_name(name) == 0): mm_error(d, offset, message)
			names.push(name)
			at = mm_style_css_space(css, at)
			if (css[at] == ','):
				at = mm_style_css_space(css, at + 1)
				continue
			if (css[at] != '{'): mm_error(d, offset, message)
			break
		mm_style style
		mm_style_clear(&style)
		if (d.error == 0):
			at = at + 1
			int count = 0
			while (d.error == 0):
				at = mm_style_css_space(css, at)
				if (css[at] == '}'):
					at = at + 1
					break
				int colon = at
				while (css[colon] != 0 && css[colon] != ':' && css[colon] != ';' && css[colon] != '}'): colon = colon + 1
				int stop = colon
				while (css[stop] != 0 && css[stop] != ';' && css[stop] != '}'): stop = stop + 1
				if (css[colon] != ':' || css[stop] == 0):
					mm_error(d, offset, message)
					break
				char* key = mm_style_trim(css, at, colon)
				int end = stop
				char* raw = mm_style_trim(css, colon + 1, end)
				int important = index_of(raw, c"!important")
				if (important >= 0): raw[important] = 0
				char* value = mm_style_trim(raw, 0, strlen(raw))
				mm_style_property(d, &style, key, value, offset)
				free(key)
				free(raw)
				free(value)
				count = count + 1
				if (count > 16): mm_error(d, offset, c"style property limit exceeded")
				at = stop
				if (css[at] == ';'): at = at + 1
		if (d.error == 0):
			for char* name in names:
				mm_style_class* definition = mm_style_find(d, name)
				if (definition == 0):
					if (d.style_definitions.length >= 128):
						mm_error(d, offset, c"style class limit exceeded")
						break
					definition = new mm_style_class()
					definition.name = strclone(name)
					d.style_definitions.push(definition)
				mm_style_merge(&definition.style, &style)
		for char* name in names: free(name)
		__w_list_free(cast(__w_list*, names))
		rules = rules + 1
		if (rules > 64): mm_error(d, offset, c"themeCSS rule limit exceeded")
		at = mm_style_css_space(css, at)

# Font and CSS configuration keys owned by the styling layer: fontFamily,
# fontSize, themeCSS and themeVariables.fontFamily / fontSize. key is the
# path below "config."; returns 1 when the key was handled (or diagnosed).
int mm_style_config_key(mm_document* d, char* key, char* value, int map, int offset):
	int family = strcmp(key, c"fontFamily") == 0 || strcmp(key, c"themeVariables.fontFamily") == 0
	int size = strcmp(key, c"fontSize") == 0 || strcmp(key, c"themeVariables.fontSize") == 0
	int css = strcmp(key, c"themeCSS") == 0
	if (family == 0 && size == 0 && css == 0): return 0
	if (map):
		mm_error(d, offset, c"configuration value must be a scalar")
		return 1
	if (family):
		if (mm_style_family_list(value) == 0): mm_error(d, offset, c"fontFamily takes a CSS font-family list of names, quotes, commas and spaces")
		else:
			if (d.font_family != 0): free(d.font_family)
			d.font_family = strclone(value)
	else if (size):
		int px = mm_style_font_size_value(value)
		if (px < 0): mm_error(d, offset, c"fontSize must be 8 to 72 (px)")
		else: d.font_size = px
	else: mm_style_theme_css(d, value, offset)
	return 1

# Move configuration-owned styling from the envelope document that read the
# frontmatter/directives into the parsed diagram: fontFamily/fontSize and the
# themeCSS classes, which sit beneath the diagram's own classDef statements.
void mm_style_adopt(mm_document* d, mm_document* envelope):
	if (d.font_family != 0): free(d.font_family)
	d.font_family = envelope.font_family
	envelope.font_family = 0
	d.font_size = envelope.font_size
	for mm_style_class* css in envelope.style_definitions:
		mm_style style = css.style
		if (style.mask & MM_STYLE_FAMILY): style.family = mm_style_font(d, envelope.style_fonts[style.family - 1], 0)
		mm_style_class* own = mm_style_find(d, css.name)
		if (own == 0):
			if (d.style_definitions.length >= 128):
				mm_error(d, 0, c"style class limit exceeded")
				return
			own = new mm_style_class()
			own.name = strclone(css.name)
			own.style = style
			d.style_definitions.push(own)
		else:
			mm_style_merge(&style, &own.style)
			own.style = style
