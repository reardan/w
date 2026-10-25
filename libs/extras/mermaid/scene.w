# Deterministic native layout and a backend-independent display list.
# No DOM, JavaScript, external layout engine or graphics context required.
import libs.extras.mermaid.model
import lib.fmath
import libs.extras.mermaid.text_metrics

const int MM_LINE = 1
const int MM_BOX = 2
const int MM_TEXT = 3
const int MM_CIRCLE = 4
const int MM_POLYGON = 5

struct mm_primitive:
	int kind
	int x
	int y
	int x2
	int y2
	int dashed
	char* text
	list[int] points
	mm_style style
	int node_style
	# MM_TEXT_BOLD / MM_TEXT_ITALIC flags of a text run.
	int text_style
	# Optional owned hyperlink for SVG text; native renderers ignore it.
	char* href
	# Theme role (MM_ROLE_* in style_render.w) and categorical series index.
	int role
	int series
	# Label font size in px (0 = MM_TEXT_SIZE) and an owned font-family (0 = scene default).
	int font_size
	char* font
	# Look effects: bit 1 drop shadow, bit 2 gradient stroke (neo look).
	int effects
	# Lightness offset for tinted series fills (treemap depth palettes).
	int tint
	# Style mask bits set by the document's own styles (classes, style, :::);
	# theme role paint never overrides them.
	int user_mask

struct mm_bounds:
	int x
	int y
	int w
	int h
	int rank

struct mm_scene:
	list[mm_primitive*] items
	list[mm_bounds*] nodes
	int width
	int height
	char* accessibility_title
	char* accessibility_description
	int has_title
	int has_background
	int background
	# Owned default SVG font-family from fontFamily configuration (0 = native face).
	char* font_family
	# Neo look: drop-shadow offset/blur in px, color, alpha (hundredths), gradient stops.
	int has_effects
	int shadow_dx
	int shadow_dy
	int shadow_blur
	int shadow_color
	int shadow_alpha
	int gradient_start
	int gradient_stop

void mm_draw(mm_scene* s, int kind, int x, int y, int x2, int y2, int dashed, char* text):
	mm_primitive* p = new mm_primitive()
	p.kind = kind
	p.x = x
	p.y = y
	p.x2 = x2
	p.y2 = y2
	p.dashed = dashed
	p.text = strclone(text)
	if (kind == MM_TEXT && mm_text_size() != MM_TEXT_SIZE): p.font_size = mm_text_size()
	s.items.push(p)
	if (kind == MM_TEXT): x2 = x + mm_text_width(text, 0)
	if (kind == MM_TEXT): y2 = y + MM_TEXT_LINE
	if (x2 + 40 > s.width): s.width = x2 + 40
	if (y2 + 40 > s.height): s.height = y2 + 40
	if (x + 40 > s.width): s.width = x + 40
	if (y + 40 > s.height): s.height = y + 40

void mm_line(mm_scene* s, int x, int y, int x2, int y2, int dashed):
	mm_draw(s, MM_LINE, x, y, x2, y2, dashed, c"")

void mm_text(mm_scene* s, int x, int y, char* text):
	mm_draw(s, MM_TEXT, x, y, 0, 0, 0, text)

# One styled run of text; its extent counts the styled (wider bold) advances.
void mm_text_styled(mm_scene* s, int x, int y, char* text, int style):
	mm_draw(s, MM_TEXT, x, y, 0, 0, 0, text)
	mm_primitive* p = s.items[s.items.length - 1]
	p.text_style = style
	int x2 = x + mm_text_width(text, style)
	if (x2 + 40 > s.width): s.width = x2 + 40

void mm_ellipse(mm_scene* s, int x, int y, int rx, int ry):
	int px = x + rx
	int py = y
	for i in range(1, 33):
		float angle = cast(float, i) * 6.2831853 / 32.0
		int nx = x + cast(int, fcos(angle) * cast(float, rx))
		int ny = y + cast(int, fsin(angle) * cast(float, ry))
		mm_line(s, px, py, nx, ny, 0)
		px = nx
		py = ny

# Endpoint marker oriented outward from the entity into the relationship.
void mm_marker(mm_scene* s, int x, int y, int dx, int dy, int card):
	int px = 0 - dy
	int py = dx
	if (card >= 2):
		mm_line(s, x + px * 7, y + py * 7, x + dx * 12, y + dy * 12, 0)
		mm_line(s, x - px * 7, y - py * 7, x + dx * 12, y + dy * 12, 0)
	else: mm_line(s, x + dx * 6 + px * 7, y + dy * 6 + py * 7, x + dx * 6 - px * 7, y + dy * 6 - py * 7, 0)
	int cx = x + dx * 20
	int cy = y + dy * 20
	if (card == 0 || card == 2): mm_draw(s, MM_CIRCLE, cx - 4, cy - 4, cx + 4, cy + 4, 0, c"")
	else: mm_line(s, cx + px * 7, cy + py * 7, cx - px * 7, cy - py * 7, 0)

void mm_scene_free(mm_scene* s):
	if (s == 0): return
	for mm_primitive* p in s.items:
		if (p.points != 0): __w_list_free(cast(__w_list*, p.points))
		free(p.text)
		if (p.href != 0): free(p.href)
		if (p.font != 0): free(p.font)
		free(p)
	for mm_bounds* b in s.nodes: free(b)
	__w_list_free(cast(__w_list*, s.items))
	__w_list_free(cast(__w_list*, s.nodes))
	free(s.accessibility_title)
	free(s.accessibility_description)
	if (s.font_family != 0): free(s.font_family)
	free(s)

void mm_xml(string_builder* out, char* text):
	int i = 0
	while (text[i] != 0):
		int c = text[i]
		if (c == '&'): string_append(out, c"&amp;")
		else if (c == '<'): string_append(out, c"&lt;")
		else if (c == '>'): string_append(out, c"&gt;")
		else if (c == '"'): string_append(out, c"&quot;")
		else: string_append_char(out, c)
		i = i + 1

void mm_svg_number(string_builder* out, char* name, int value):
	string_append_char(out, ' ')
	string_append(out, name)
	string_append(out, c"=\"")
	string_append_int(out, value)
	string_append_char(out, '"')

int mm_paint_stroke(mm_primitive* p):
	if (p.style.mask & 2): return p.style.stroke
	return 0x334155

int mm_paint_width(mm_primitive* p):
	if (p.style.mask & 8): return p.style.width
	return 2

int mm_paint_fill(mm_primitive* p):
	if (p.kind == MM_TEXT):
		if (p.style.mask & 4): return p.style.text
		return 0x0f172a
	if (p.kind == MM_LINE): return -1
	if ((p.kind == MM_BOX && p.dashed == 2) || ((p.kind == MM_CIRCLE || p.kind == MM_POLYGON) && p.dashed)): return mm_paint_stroke(p)
	if (p.style.mask & 1): return p.style.fill
	if (p.kind == MM_BOX): return 0xf8fafc
	return 0xffffff

void mm_svg_color(string_builder* out, char* name, int color):
	string_append_char(out, ' ')
	string_append(out, name)
	string_append(out, c"=\"")
	if (color < 0): string_append(out, c"none")
	else:
		string_append_char(out, '#')
		char* digits = c"0123456789abcdef"
		for i in range(6): string_append_char(out, digits[(color >> ((5 - i) * 4)) & 15])
	string_append_char(out, '"')

# Text flags after font-weight / font-style styles override the run's own.
int mm_text_flags(mm_primitive* p):
	int flags = p.text_style
	if (p.style.mask & 64): flags = flags - (flags & MM_TEXT_BOLD) + (p.style.font & MM_TEXT_BOLD)
	if (p.style.mask & 128): flags = flags - (flags & MM_TEXT_ITALIC) + (p.style.font & MM_TEXT_ITALIC)
	return flags

int mm_paint_font_size(mm_primitive* p):
	if (p.style.mask & 256): return p.style.font_size
	if (p.font_size > 0): return p.font_size
	return MM_TEXT_SIZE

# Box corner radius: rx/ry style, else the shape's own rounding.
int mm_paint_radius(mm_primitive* p):
	if (p.style.mask & 1024): return p.style.radius
	if (p.kind == MM_BOX && p.dashed == 1): return 12
	if (p.kind == MM_BOX && p.dashed == 3): return (p.y2 - p.y) / 2
	return 0

# Hundredths as a CSS number: 50 -> 0.5, 100 -> 1.
void mm_svg_fraction(string_builder* out, char* name, int value):
	string_append_char(out, ' ')
	string_append(out, name)
	string_append(out, c"=\"")
	if (value >= 100): string_append_char(out, '1')
	else:
		string_append(out, c"0.")
		string_append_char(out, '0' + value / 10)
		if (value % 10): string_append_char(out, '0' + value % 10)
	string_append_char(out, '"')

# stroke-dasharray style, else the primitive's own dashed line pattern.
void mm_svg_dash(string_builder* out, mm_primitive* p):
	if (p.style.mask & 16):
		if (p.style.dash > 0):
			string_append(out, c" stroke-dasharray=\"")
			string_append_int(out, p.style.dash)
			string_append_char(out, ' ')
			string_append_int(out, p.style.gap)
			string_append_char(out, '"')
	else if (p.kind == MM_LINE && p.dashed): string_append(out, c" stroke-dasharray=\"6 4\"")

void mm_svg_paint(string_builder* out, mm_primitive* p):
	mm_svg_color(out, c"fill", mm_paint_fill(p))
	int stroke = mm_paint_stroke(p)
	if (p.kind == MM_TEXT): stroke = -1
	if ((p.effects & 2) && p.kind != MM_TEXT && stroke >= 0): string_append(out, c" stroke=\"url(#mermaid-gradient)\"")
	else: mm_svg_color(out, c"stroke", stroke)
	mm_svg_number(out, c"stroke-width", mm_paint_width(p))
	if (p.kind != MM_TEXT && p.kind != MM_LINE): mm_svg_dash(out, p)
	if (p.style.mask & 32): mm_svg_fraction(out, c"opacity", p.style.opacity)
	if ((p.style.mask & 2048) && p.kind != MM_TEXT && p.kind != MM_LINE): mm_svg_fraction(out, c"fill-opacity", p.style.fill_opacity)
	if (p.effects & 1): string_append(out, c" filter=\"url(#mermaid-drop-shadow)\"")

void mm_svg_defs(string_builder* out, mm_scene* scene):
	if (scene.has_effects == 0): return
	string_append(out, c"<defs><filter id=\"mermaid-drop-shadow\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"140%\"><feDropShadow")
	mm_svg_number(out, c"dx", scene.shadow_dx)
	mm_svg_number(out, c"dy", scene.shadow_dy)
	mm_svg_number(out, c"stdDeviation", scene.shadow_blur)
	mm_svg_color(out, c"flood-color", scene.shadow_color)
	mm_svg_fraction(out, c"flood-opacity", scene.shadow_alpha)
	string_append(out, c"/></filter><linearGradient id=\"mermaid-gradient\" x1=\"0%\" y1=\"0%\" x2=\"100%\" y2=\"0%\"><stop offset=\"0%\"")
	mm_svg_color(out, c"stop-color", scene.gradient_start)
	string_append(out, c"/><stop offset=\"100%\"")
	mm_svg_color(out, c"stop-color", scene.gradient_stop)
	string_append(out, c"/></linearGradient></defs>\n")

char* mm_svg(mm_scene* scene):
	if (scene == 0): return 0
	string_builder* out = string_from(c"<svg xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" aria-labelledby=\"mermaid-title mermaid-description\" viewBox=\"0 0 ")
	string_append_int(out, scene.width)
	string_append_char(out, ' ')
	string_append_int(out, scene.height)
	string_append(out, c"\"><title id=\"mermaid-title\">")
	if (scene.accessibility_title != 0 && scene.accessibility_title[0] != 0): mm_xml(out, scene.accessibility_title)
	else: string_append(out, c"Mermaid diagram")
	string_append(out, c"</title><desc id=\"mermaid-description\">")
	if (scene.accessibility_description != 0): mm_xml(out, scene.accessibility_description)
	string_append(out, c"</desc>\n")
	mm_svg_defs(out, scene)
	if (scene.has_background):
		string_append(out, c"<rect width=\"100%\" height=\"100%\"")
		mm_svg_color(out, c"fill", scene.background)
		string_append(out, c"/>\n")
	string_append(out, c"<g>\n")
	for mm_primitive* p in scene.items:
		if (p.kind == MM_LINE):
			string_append(out, c"<line")
			mm_svg_paint(out, p)
			mm_svg_number(out, c"x1", p.x)
			mm_svg_number(out, c"y1", p.y)
			mm_svg_number(out, c"x2", p.x2)
			mm_svg_number(out, c"y2", p.y2)
			mm_svg_dash(out, p)
			string_append(out, c"/>\n")
		else if (p.kind == MM_BOX):
			string_append(out, c"<rect")
			mm_svg_paint(out, p)
			mm_svg_number(out, c"x", p.x)
			mm_svg_number(out, c"y", p.y)
			mm_svg_number(out, c"width", p.x2 - p.x)
			mm_svg_number(out, c"height", p.y2 - p.y)
			int radius = mm_paint_radius(p)
			if (radius > 0): mm_svg_number(out, c"rx", radius)
			string_append(out, c"/>\n")
		else if (p.kind == MM_CIRCLE):
			string_append(out, c"<circle")
			mm_svg_paint(out, p)
			mm_svg_number(out, c"cx", (p.x + p.x2) / 2)
			mm_svg_number(out, c"cy", (p.y + p.y2) / 2)
			mm_svg_number(out, c"r", (p.x2 - p.x) / 2)
			string_append(out, c"/>\n")
		else if (p.kind == MM_POLYGON):
			string_append(out, c"<polygon")
			mm_svg_paint(out, p)
			string_append(out, c" points=\"")
			for i in range(p.points.length):
				string_append_int(out, p.points[i])
				if (i % 2 == 0): string_append_char(out, ',')
				else: string_append_char(out, ' ')
			string_append(out, c"\"/>\n")
		else:
			if (p.href != 0):
				string_append(out, c"<a href=\"")
				mm_xml(out, p.href)
				string_append(out, c"\">")
			string_append(out, c"<text font-family=\"")
			if (p.font != 0): mm_xml(out, p.font)
			else if (scene.font_family != 0): mm_xml(out, scene.font_family)
			else: string_append(out, c"Liberation Sans, Arial, Helvetica, sans-serif")
			string_append_char(out, '"')
			int size = mm_paint_font_size(p)
			mm_svg_number(out, c"font-size", size)
			int flags = mm_text_flags(p)
			if (flags & MM_TEXT_BOLD): string_append(out, c" font-weight=\"bold\"")
			if (flags & MM_TEXT_ITALIC): string_append(out, c" font-style=\"italic\"")
			mm_svg_paint(out, p)
			mm_svg_number(out, c"x", p.x)
			mm_svg_number(out, c"y", p.y + (MM_TEXT_ASCENT * size + MM_TEXT_SIZE - 1) / MM_TEXT_SIZE)
			string_append_char(out, '>')
			mm_xml(out, p.text)
			string_append(out, c"</text>")
			if (p.href != 0): string_append(out, c"</a>")
			string_append_char(out, 10)
	string_append(out, c"</g></svg>\n")
	char* result = out.data
	free(out)
	return result
