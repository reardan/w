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
	if (d.kind == MM_MINDMAP): return
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
const int MM_THEME_COUNT = 42
const int MM_THEME_UNSET = -2

const int MM_THEME_ROOT = 0
const int MM_THEME_COPY = 1
const int MM_THEME_ADJUST = 2
const int MM_THEME_BORDER = 3
const int MM_THEME_CONTRAST = 4
const int MM_THEME_INVERT = 5
const int MM_THEME_EDGE = 6

# Fixed categorical colors: the native series palette for every theme.
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
	int result = -1
	for i in range(names.length):
		if (strcmp(name, names[i]) == 0): result = i
	__w_list_free(cast(__w_list*, names))
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

# Theme identifier for a theme name, or 0. neo/redux names are native approximations.
int mm_style_theme_id(char* name):
	list[char*] names = list[char*]{c"default", c"base", c"dark", c"forest", c"neutral", c"neo", c"neo-dark", c"redux", c"redux-dark", c"redux-color", c"redux-dark-color"}
	int result = 0
	for i in range(names.length):
		if (strcmp(name, names[i]) == 0): result = i + 1
	__w_list_free(cast(__w_list*, names))
	return result

# Resolve every theme variable. user holds MM_THEME_COUNT explicit values
# (MM_THEME_UNSET when absent); dark is -1 for the theme's own mode. A variable
# keeps the theme's native value unless it, or a variable it derives from, was
# set explicitly; then it is derived the way Mermaid's theme-base derives it.
void mm_style_theme_resolve(mm_document* d, int theme, list[int] user, int dark):
	if (theme == 0): theme = 1
	d.theme = theme
	list[int] fills = list[int]{0xf8fafc, 0xfff4dd, 0x1f2937, 0xdcfce7, 0xf5f5f5, 0xffffff, 0x1f2023, 0xffffff, 0x18181b, 0xeef2ff, 0x1e1b4b}
	list[int] strokes = list[int]{0x334155, 0x937044, 0x94a3b8, 0x166534, 0x525252, 0x4b5563, 0x9ca3af, 0x111111, 0xf4f4f5, 0x4f46e5, 0xa5b4fc}
	list[int] texts = list[int]{0x0f172a, 0x333333, 0xf8fafc, 0x14532d, 0x171717, 0x111827, 0xf3f4f6, 0x111111, 0xf4f4f5, 0x1e1b4b, 0xeef2ff}
	list[int] backgrounds = list[int]{0xffffff, 0xffffff, 0x0f172a, 0xffffff, 0xffffff, 0xffffff, 0x111214, 0xffffff, 0x09090b, 0xffffff, 0x0b0a1f}
	list[int] modes = list[int]{0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 1}
	list[int] sources = list[int]{-1, -1, 1, 1, 1, 4, 4, 1, 7, 7, 0, 3, 1, 2, 7, 8, 11, 4, 1, 4, 7, 1, 4, 7, 1, 1, 1, 1, 1, 1, 1, 4, 7, 1, 1, 1, 1, 1, 1, 1, 1, 1}
	list[int] ops = list[int]{0, 0, 3, 4, 2, 3, 5, 2, 3, 5, 5, 1, 1, 1, 1, 1, 1, 6, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2}
	list[int] hues = list[int]{0, 0, 0, 0, -120, 0, 0, 180, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 60, -60, 120, 60, -60, 120, 0, 0, 0, 30, 60, 90, 120, 150, 210, 270, 300, 330}
	list[int] lights = list[int]{0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -10, -10, -10, -10, -10, 0, -20, -20, -10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	list[int] native = new list[int]
	for i in range(MM_THEME_COUNT): native.push(MM_THEME_UNSET)
	int fill = fills[theme - 1]
	int stroke = strokes[theme - 1]
	int text = texts[theme - 1]
	native[MM_THEME_BACKGROUND] = backgrounds[theme - 1]
	native[MM_THEME_PRIMARY] = fill
	native[MM_THEME_PRIMARY_BORDER] = stroke
	native[MM_THEME_PRIMARY_TEXT] = text
	native[MM_THEME_LINE] = stroke
	native[MM_THEME_TEXT] = text
	native[MM_THEME_CLUSTER_BKG] = fill
	native[MM_THEME_CLUSTER_BORDER] = stroke
	native[MM_THEME_EDGE_LABEL_BKG] = -1
	for i in range(12):
		native[MM_THEME_PIE + i] = mm_style_series_color(i)
		native[MM_THEME_SCALE + i] = mm_style_series_color(i)
	if (dark < 0): dark = modes[theme - 1]
	list[int] values = new list[int]
	list[int] touched = new list[int]
	for v in range(MM_THEME_COUNT):
		int value = MM_THEME_UNSET
		if (user != 0): value = user[v]
		int changed = value != MM_THEME_UNSET
		if (changed == 0):
			int source = sources[v]
			if (source >= 0 && touched[source]): changed = 1
			if (changed == 0 && native[v] != MM_THEME_UNSET): value = native[v]
			else: value = mm_theme_derive(ops[v], values[source], hues[v], lights[v], dark)
		values.push(value)
		touched.push(changed)
	d.palette.mask = 15
	d.palette.fill = values[MM_THEME_MAIN_BKG]
	d.palette.stroke = values[MM_THEME_NODE_BORDER]
	d.palette.text = values[MM_THEME_PRIMARY_TEXT]
	d.palette.width = 2
	d.palette_line = values[MM_THEME_LINE]
	d.palette_label = values[MM_THEME_TEXT]
	d.background = values[MM_THEME_BACKGROUND]
	if (d.theme_values != 0): __w_list_free(cast(__w_list*, d.theme_values))
	d.theme_values = values
	__w_list_free(cast(__w_list*, fills))
	__w_list_free(cast(__w_list*, strokes))
	__w_list_free(cast(__w_list*, texts))
	__w_list_free(cast(__w_list*, backgrounds))
	__w_list_free(cast(__w_list*, modes))
	__w_list_free(cast(__w_list*, sources))
	__w_list_free(cast(__w_list*, ops))
	__w_list_free(cast(__w_list*, hues))
	__w_list_free(cast(__w_list*, lights))
	__w_list_free(cast(__w_list*, native))
	__w_list_free(cast(__w_list*, touched))

# Native layered-layout gaps; flowchart nodeSpacing/rankSpacing override them.
int mm_style_lane_gap(mm_document* d):
	if (d.kind == MM_FLOW && (d.config_mask & 1)): return d.node_spacing * 2
	return 100

int mm_style_rank_gap(mm_document* d):
	if (d.kind == MM_FLOW && (d.config_mask & 2)): return d.rank_spacing + 90
	return 140
