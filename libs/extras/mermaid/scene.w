# Deterministic native layout and a backend-independent display list.
# No DOM, JavaScript, external layout engine or graphics context required.
import libs.extras.mermaid.model
import lib.fmath

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

void mm_draw(mm_scene* s, int kind, int x, int y, int x2, int y2, int dashed, char* text):
	mm_primitive* p = new mm_primitive(kind, x, y, x2, y2, dashed, strclone(text), 0)
	s.items.push(p)
	if (kind == MM_TEXT): x2 = x + strlen(text) * 8
	if (kind == MM_TEXT): y2 = y + 16
	if (x2 + 40 > s.width): s.width = x2 + 40
	if (y2 + 40 > s.height): s.height = y2 + 40
	if (x + 40 > s.width): s.width = x + 40
	if (y + 40 > s.height): s.height = y + 40

void mm_line(mm_scene* s, int x, int y, int x2, int y2, int dashed):
	mm_draw(s, MM_LINE, x, y, x2, y2, dashed, c"")

void mm_text(mm_scene* s, int x, int y, char* text):
	mm_draw(s, MM_TEXT, x, y, 0, 0, 0, text)

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
		free(p)
	for mm_bounds* b in s.nodes: free(b)
	__w_list_free(cast(__w_list*, s.items))
	__w_list_free(cast(__w_list*, s.nodes))
	free(s.accessibility_title)
	free(s.accessibility_description)
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
	string_append(out, c"</desc>\n<g stroke=\"#334155\" stroke-width=\"2\" fill=\"none\">\n")
	for mm_primitive* p in scene.items:
		if (p.kind == MM_LINE):
			string_append(out, c"<line")
			mm_svg_number(out, c"x1", p.x)
			mm_svg_number(out, c"y1", p.y)
			mm_svg_number(out, c"x2", p.x2)
			mm_svg_number(out, c"y2", p.y2)
			if (p.dashed): string_append(out, c" stroke-dasharray=\"6 4\"")
			string_append(out, c"/>\n")
		else if (p.kind == MM_BOX):
			if (p.dashed == 2): string_append(out, c"<rect fill=\"#334155\"")
			else: string_append(out, c"<rect fill=\"#f8fafc\"")
			mm_svg_number(out, c"x", p.x)
			mm_svg_number(out, c"y", p.y)
			mm_svg_number(out, c"width", p.x2 - p.x)
			mm_svg_number(out, c"height", p.y2 - p.y)
			if (p.dashed == 1): mm_svg_number(out, c"rx", 12)
			string_append(out, c"/>\n")
		else if (p.kind == MM_CIRCLE):
			if (p.dashed): string_append(out, c"<circle fill=\"#334155\"")
			else: string_append(out, c"<circle fill=\"white\"")
			mm_svg_number(out, c"cx", (p.x + p.x2) / 2)
			mm_svg_number(out, c"cy", (p.y + p.y2) / 2)
			mm_svg_number(out, c"r", (p.x2 - p.x) / 2)
			string_append(out, c"/>\n")
		else if (p.kind == MM_POLYGON):
			if (p.dashed): string_append(out, c"<polygon fill=\"#334155\" points=\"")
			else: string_append(out, c"<polygon fill=\"white\" points=\"")
			for i in range(p.points.length):
				string_append_int(out, p.points[i])
				if (i % 2 == 0): string_append_char(out, ',')
				else: string_append_char(out, ' ')
			string_append(out, c"\"/>\n")
		else:
			string_append(out, c"<text stroke=\"none\" fill=\"#0f172a\" font-family=\"monospace\" font-size=\"13\"")
			mm_svg_number(out, c"x", p.x)
			mm_svg_number(out, c"y", p.y + 13)
			string_append_char(out, '>')
			mm_xml(out, p.text)
			string_append(out, c"</text>\n")
	string_append(out, c"</g></svg>\n")
	char* result = out.data
	free(out)
	return result
