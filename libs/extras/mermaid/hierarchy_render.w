# Dedicated column and tree layouts; parent means ancestry, never a cluster box.
import libs.extras.mermaid.scene
import libs.extras.mermaid.icons
import libs.extras.mermaid.style_render
import libs.extras.mermaid.text
import lib.fmath

# Mindmap section colours: by branch (the root's child each node descends
# from, as upstream's default) or by depth with `mindmap.colorBy: depth`.
# Themes repaint them from cScale0..11 (MM_ROLE_TINT with this series). -1
# leaves the root plain.
int mm_mindmap_series(mm_document* d, int index, int by_depth):
	int depth = 0
	int branch = index
	mm_node* n = d.nodes[index]
	while (n.parent >= 0):
		depth = depth + 1
		mm_node* parent = d.nodes[n.parent]
		if (parent.parent >= 0): branch = n.parent
		n = parent
	if (depth == 0): return -1
	if (by_depth): return depth - 1
	int order = 0
	for i in range(branch):
		mm_node* sibling = d.nodes[i]
		mm_node* root_child = d.nodes[branch]
		if (sibling.parent == root_child.parent): order = order + 1
	return order

void mm_mindmap_paint(mm_scene* s, int start, int series):
	if (series < 0): return
	list[int] colors = list[int]{0xdbeafe, 0xfee2e2, 0xdcfce7, 0xf3e8ff, 0xffedd5, 0xcffafe, 0xfce7f3, 0xecfccb, 0xe0e7ff, 0xccfbf1, 0xfef9c3, 0xede9fe}
	for i in range(start, s.items.length):
		mm_primitive* p = s.items[i]
		if (p.kind == MM_TEXT || p.kind == MM_LINE): continue
		p.style.mask = p.style.mask | 1
		p.style.fill = colors[series % 12]
	__w_list_free(cast(__w_list*, colors))

# Mindmap cloud (3) and bang (4) outlines are 48-point polygons: lobes bulge
# outward for clouds and alternate as spikes for bangs. Hexagon is shape 5.
void mm_mindmap_outline(mm_scene* s, mm_node* n, mm_bounds* b):
	mm_draw(s, MM_POLYGON, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
	mm_primitive* polygon = s.items[s.items.length - 1]
	if (n.shape == 5):
		int inset = b.h / 2
		if (inset > b.w / 4): inset = b.w / 4
		polygon.points = list[int]{b.x + inset, b.y, b.x + b.w - inset, b.y, b.x + b.w, b.y + b.h / 2, b.x + b.w - inset, b.y + b.h, b.x + inset, b.y + b.h, b.x, b.y + b.h / 2}
		return
	polygon.points = new list[int]
	for i in range(48):
		float angle = cast(float, i) * 6.2831853 / 48.0
		float scale = 1.0
		if (n.shape == 3):
			float lobe = fsin(angle * 8.0)
			if (lobe < 0.0): lobe = 0.0 - lobe
			scale = 0.86 + 0.14 * lobe
		else if (i % 2 == 1): scale = 0.72
		polygon.points.push(b.x + b.w / 2 + cast(int, fcos(angle) * scale * cast(float, b.w) / 2.0))
		polygon.points.push(b.y + b.h / 2 + cast(int, fsin(angle) * scale * cast(float, b.h) / 2.0))

# Upstream replaces the first `#TICKET#` in kanban.ticketBaseUrl with the
# card's ticket; the ticket is percent-encoded so it cannot alter the URL.
char* mm_kanban_ticket_url(char* base, char* ticket):
	string_builder* url = string_new()
	int marker = index_of(base, c"#TICKET#")
	if (marker < 0): string_append(url, base)
	else:
		string_append_bytes(url, base, marker)
		char* digits = c"0123456789ABCDEF"
		for i in range(strlen(ticket)):
			int c = ticket[i] & 255
			if (isalnum(c) || c == '-' || c == '.' || c == '_' || c == '~'): string_append_char(url, c)
			else:
				string_append_char(url, '%')
				string_append_char(url, digits[c >> 4])
				string_append_char(url, digits[c & 15])
		string_append(url, base + marker + 8)
	char* result = strclone(url.data)
	string_free(url)
	return result

mm_scene* mm_hierarchy_render(mm_document* d):
	mm_scene* s = new mm_scene()
	s.items = new list[mm_primitive*]
	s.nodes = new list[mm_bounds*]
	list[int] heights = new list[int]
	# Labels wrap at mindmap.maxNodeWidth / kanban.sectionWidth (upstream
	# default 200px each) and the box grows by the extra lines (issue #817).
	int wrap = mm_config_number(d, c"mindmap.maxNodeWidth", 200)
	if (d.kind == MM_KANBAN): wrap = mm_config_number(d, c"kanban.sectionWidth", 200)
	if (wrap < 40): wrap = 40
	list[mm_text_block*] blocks = new list[mm_text_block*]
	for mm_node* n in d.nodes:
		mm_bounds* b = new mm_bounds()
		mm_text_block* block = mm_text_layout(n.label, wrap)
		blocks.push(block)
		b.w = block.width + 40
		if (b.w < 160): b.w = 160
		b.h = 60 + n.members.length * 24 + block.height - mm_text_line_height()
		for mm_member* m in n.members:
			if (mm_text_width(m.text, 0) + 40 > b.w): b.w = mm_text_width(m.text, 0) + 40
		if (n.shape == 2): b.h = b.w
		if (n.annotation[0] != 0): b.h = b.h + 24
		# Clouds and bangs lose their corners, so reserve room for the label.
		if (d.kind == MM_MINDMAP && (n.shape == 3 || n.shape == 4)):
			b.w = b.w + 40
			b.h = b.h + 30
		s.nodes.push(b)
		heights.push(b.h + 40)
	if (d.kind == MM_KANBAN):
		int x = 40
		for i in range(d.nodes.length):
			mm_node* column = d.nodes[i]
			if (column.parent >= 0): continue
			mm_bounds* box = s.nodes[i]
			box.x = x
			box.y = 40
			# Column metadata lines sit under the title, above the header rule.
			int y = 120 + column.members.length * 24 + blocks[i].height - mm_text_line_height()
			for j in range(d.nodes.length):
				mm_node* card = d.nodes[j]
				if (card.parent != i): continue
				mm_bounds* b = s.nodes[j]
				b.x = x + 16
				b.y = y
				y = y + b.h + 20
				if (b.w + 32 > box.w): box.w = b.w + 32
			box.h = y - 20
			if (box.h < 120): box.h = 120
			x = x + box.w + 40
	else:
		# Reserve subtree height bottom-up, then place children in source order.
		for reverse in range(d.nodes.length):
			int i = d.nodes.length - reverse - 1
			int sum = 0
			for j in range(i + 1, d.nodes.length):
				mm_node* n = d.nodes[j]
				if (n.parent == i): sum = sum + heights[j]
			if (sum > heights[i]): heights[i] = sum
		for i in range(d.nodes.length):
			mm_node* n = d.nodes[i]
			mm_bounds* b = s.nodes[i]
			b.x = 40
			int top = 40
			if (n.parent >= 0):
				mm_bounds* parent = s.nodes[n.parent]
				b.x = parent.x + parent.w + 100
				top = parent.rank
				for j in range(i):
					mm_node* sibling = d.nodes[j]
					if (sibling.parent == n.parent): top = top + heights[j]
			b.rank = top
			b.y = top + (heights[i] - b.h) / 2
		for i in range(d.nodes.length):
			mm_node* n = d.nodes[i]
			if (n.parent < 0): continue
			mm_bounds* a = s.nodes[n.parent]
			mm_bounds* b = s.nodes[i]
			mm_line(s, a.x + a.w, a.y + a.h / 2, b.x, b.y + b.h / 2, 0)
	char* color_by = mm_config_value(d, c"mindmap.colorBy")
	int by_depth = color_by != 0 && strcmp(color_by, c"depth") == 0
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		int style_start = s.items.length
		int shape = MM_BOX
		if (n.shape == 2): shape = MM_CIRCLE
		int outline = s.items.length
		if (d.kind == MM_MINDMAP && n.shape >= 3): mm_mindmap_outline(s, n, b)
		else: mm_draw(s, shape, b.x, b.y, b.x + b.w, b.y + b.h, n.shape == 1, c"")
		if (d.kind == MM_MINDMAP): mm_mindmap_paint(s, outline, mm_mindmap_series(d, i, by_depth))
		int y = b.y + 20
		int x = b.x + 20
		# Mindmap outlines are centred shapes, so centre the label block in them.
		if (d.kind == MM_MINDMAP):
			int content = blocks[i].height
			if (n.annotation[0] != 0): content = content + 24
			y = b.y + (b.h - content) / 2
			x = b.x + b.w / 2
		# Icon fonts are not bundled: the icon is a native pictogram (icons.w)
		# centred above the label, as upstream places the icon.
		if (n.annotation[0] != 0):
			int badge = x + 10
			if (d.kind == MM_MINDMAP): badge = b.x + b.w / 2
			mm_icon_draw(s, n.annotation, badge, y + 8, 0x374151)
			y = y + 24
		int rule = b.y + 60 + n.members.length * 24 + blocks[i].height - mm_text_line_height()
		if (d.kind == MM_KANBAN && n.parent < 0): mm_line(s, b.x, rule, b.x + b.w, rule, 0)
		mm_text_draw(s, blocks[i], x, y, d.kind == MM_MINDMAP)
		y = y + 24 + blocks[i].height - mm_text_line_height()
		for mm_member* m in n.members:
			mm_text(s, b.x + 20, y, m.text)
			if (d.kind == MM_KANBAN && d.ticket_base_url != 0 && index_of(m.text, c"ticket: ") == 0):
				mm_primitive* link = s.items[s.items.length - 1]
				link.href = mm_kanban_ticket_url(d.ticket_base_url, m.text + 8)
			y = y + 24
		if (d.kind == MM_MINDMAP && n.parent >= 0): mm_style_role(s, style_start, MM_ROLE_TINT, mm_mindmap_series(d, i, by_depth))
		if (d.kind == MM_MINDMAP && (n.style_classes[0] != 0 || n.style.mask != 0)): mm_style_node(d, s, n, style_start)
	__w_list_free(cast(__w_list*, heights))
	for mm_text_block* block in blocks: mm_text_block_free(block)
	__w_list_free(cast(__w_list*, blocks))
	return s
