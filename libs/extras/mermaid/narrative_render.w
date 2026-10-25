# Lifelines, chronological event columns, scored journeys and a calendar axis.
import libs.extras.mermaid.narrative
import libs.extras.mermaid.scene
import libs.extras.mermaid.style_render
import libs.extras.mermaid.text

# A label at (x,y): plain text, or the shared rich layout (Markdown strings,
# `<br>`) when it has markup. Returns the height drawn.
int mm_n_rich_text(mm_scene* s, int x, int y, char* label):
	if (mm_text_rich(label)): return mm_label(s, x, y, label, 0, 0)
	mm_text(s, x, y, label)
	return 18

# Rendered height of a label in px.
int mm_n_text_height(char* label):
	if (mm_text_rich(label) == 0): return 18
	mm_text_block* b = mm_text_layout(label, 0)
	int height = b.height
	mm_text_block_free(b)
	return height
import libs.extras.mermaid.interaction

# A ZenUML `//` comment above its message or fragment, with Markdown emphasis.
void mm_n_zen_comment_draw(mm_scene* s, mm_narrative_event* event, int x, int y):
	if (event.detail[0] == 0): return
	string_builder* markdown = string_from(c"`")
	string_append(markdown, event.detail)
	string_append_char(markdown, '`')
	mm_text_block* block = mm_text_layout(markdown.data, 0)
	mm_text_draw(s, block, x, y - block.height, 0)
	mm_text_block_free(block)
	string_free(markdown)

# Sequence participant object symbols (shape 2-7), drawn above the label like
# the actor figure: boundary, control, entity, database; collections and queue
# draw their outline around the label instead.
void mm_n_participant_symbol(mm_scene* s, mm_node* node, mm_bounds* bounds, int x, int shift):
	int shape = node.shape
	int top = 58 + shift
	if (shape == 2):
		mm_line(s, x - 22, top + 2, x - 22, top + 34, 0)
		mm_line(s, x - 22, top + 18, x - 10, top + 18, 0)
		mm_draw(s, MM_CIRCLE, x - 10, top + 2, x + 22, top + 34, 0, c"")
	else if (shape == 3):
		mm_draw(s, MM_CIRCLE, x - 16, top + 2, x + 16, top + 34, 0, c"")
		mm_line(s, x - 2, top + 2, x + 6, top - 4, 0)
		mm_line(s, x - 2, top + 2, x + 6, top + 8, 0)
	else if (shape == 4):
		mm_draw(s, MM_CIRCLE, x - 16, top, x + 16, top + 32, 0, c"")
		mm_line(s, x - 18, top + 36, x + 18, top + 36, 0)
	else if (shape == 5):
		mm_draw(s, MM_BOX, x - 18, top + 6, x + 18, top + 36, 0, c"")
		mm_primitive* body = s.items[s.items.length - 1]
		body.style.mask = MM_STYLE_STROKE
		body.style.stroke = -1
		mm_line(s, x - 18, top + 6, x - 18, top + 36, 0)
		mm_line(s, x + 18, top + 6, x + 18, top + 36, 0)
		mm_ellipse(s, x, top + 6, 18, 6)
		mm_ellipse(s, x, top + 36, 18, 6)
	if (shape >= 2 && shape <= 5):
		mm_text(s, x - strlen(node.label) * 4, 101 + shift, node.label)
		return
	if (shape == 6):
		mm_draw(s, MM_BOX, bounds.x + 6, bounds.y - 6, bounds.x + bounds.w + 6, bounds.y + bounds.h - 6, 0, c"")
		mm_draw(s, MM_BOX, bounds.x, bounds.y, bounds.x + bounds.w, bounds.y + bounds.h, 0, c"")
	else:
		int r = 10
		mm_draw(s, MM_BOX, bounds.x + r, bounds.y, bounds.x + bounds.w - r, bounds.y + bounds.h, 0, c"")
		mm_primitive* body = s.items[s.items.length - 1]
		body.style.mask = MM_STYLE_STROKE
		body.style.stroke = -1
		mm_line(s, bounds.x + r, bounds.y, bounds.x + bounds.w - r, bounds.y, 0)
		mm_line(s, bounds.x + r, bounds.y + bounds.h, bounds.x + bounds.w - r, bounds.y + bounds.h, 0)
		mm_ellipse(s, bounds.x + r, bounds.y + bounds.h / 2, r, bounds.h / 2)
		mm_ellipse(s, bounds.x + bounds.w - r, bounds.y + bounds.h / 2, r, bounds.h / 2)
	mm_text(s, x - strlen(node.label) * 4, 83 + shift, node.label)

# Participant `link`/`links` menus, listed in a box under the lifeline. Each
# entry is an SVG link when its URL scheme is safe (mm_link_safe).
void mm_n_link_menu(mm_scene* s, mm_node* node, mm_bounds* bounds, int y):
	if (node.metadata.length == 0): return
	int width = bounds.w
	for mm_property* link in node.metadata:
		int needed = strlen(link.key) * 8 + 24
		if (needed > width): width = needed
	int x = bounds.x + bounds.w / 2 - width / 2
	mm_draw(s, MM_BOX, x, y, x + width, y + 8 + node.metadata.length * 22, 0, c"")
	for i in range(node.metadata.length):
		mm_property* link = node.metadata[i]
		mm_text(s, x + 12, y + 6 + i * 22, link.key)
		mm_primitive* entry = s.items[s.items.length - 1]
		if (mm_link_safe(link.value)): entry.href = strclone(link.value)
		entry.tooltip = strclone(link.value)

void mm_n_arrow(mm_scene* s, int x, int y, int direction, int kind):
	if (kind == 0): return
	if (kind == 2):
		mm_line(s, x - 5, y - 5, x + 5, y + 5, 0)
		mm_line(s, x - 5, y + 5, x + 5, y - 5, 0)
	else:
		mm_line(s, x - direction * 10, y - 6, x, y, 0)
		mm_line(s, x - direction * 10, y + 6, x, y, 0)
		if (kind == 1 || kind == 4): mm_line(s, x - direction * 10, y - 6, x - direction * 10, y + 6, 0)

char* mm_n_label(mm_narrative_event* event, int number):
	string_builder* out = string_new()
	if (number >= 0):
		string_append_int(out, number)
		string_append(out, c". ")
	string_append(out, event.label)
	char* result = out.data
	free(out)
	return result

# Message and note text: one line, or wrapped lines when sequence.wrap (or
# the global wrap) is configured.
# Rich labels (Markdown strings, `<br>`) use the shared layout either way.
void mm_n_message_text(mm_scene* s, int x, int y, char* label, int wrap):
	if (wrap <= 0 && mm_text_rich(label) == 0):
		mm_text(s, x, y, label)
		return
	if (wrap < 0): wrap = 0
	mm_text_block* b = mm_text_layout(label, wrap)
	mm_text_draw(s, b, x, y - (mm_text_lines(b) - 1) * MM_TEXT_PITCH, 0)
	mm_text_block_free(b)

int mm_n_text_width(char* label, int wrap):
	if (wrap <= 0 && mm_text_rich(label) == 0): return strlen(label) * 8
	if (wrap < 0): wrap = 0
	mm_text_block* b = mm_text_layout(label, wrap)
	int width = b.width
	mm_text_block_free(b)
	return width

# A participant box or actor figure with its label; top is the box's top.
void mm_n_actor_box(mm_document* d, mm_scene* s, mm_node* node, mm_bounds* bounds, int top):
	int x = bounds.x + bounds.w / 2
	int shift = top - 65
	if (node.shape >= 2 && node.shape <= 7 && (d.kind == MM_SEQUENCE || d.kind == MM_ZENUML)):
		mm_bounds* at = new mm_bounds()
		at.x = bounds.x
		at.y = top
		at.w = bounds.w
		at.h = bounds.h
		mm_n_participant_symbol(s, node, at, x, shift)
		free(at)
		return
	if (node.shape == 1):
		mm_draw(s, MM_CIRCLE, x - 9, 58 + shift, x + 9, 76 + shift, 0, c"")
		mm_line(s, x, 76 + shift, x, 98 + shift, 0)
		mm_line(s, x - 16, 84 + shift, x + 16, 84 + shift, 0)
		mm_line(s, x, 98 + shift, x - 12, 110 + shift, 0)
		mm_line(s, x, 98 + shift, x + 12, 110 + shift, 0)
		mm_text(s, x - strlen(node.label) * 4, 115 + shift, node.label)
		return
	mm_draw(s, MM_BOX, bounds.x, top, bounds.x + bounds.w, top + bounds.h, 0, c"")
	int middle = top + bounds.h / 2
	if (node.annotation[0] != 0):
		# ZenUML participant kinds (@Database, @Boundary, ...) as a stereotype line.
		string_builder* stereotype = string_from(c"<<")
		string_append(stereotype, node.annotation)
		string_append(stereotype, c">>")
		mm_text(s, x - stereotype.length * 4, middle - 22, stereotype.data)
		string_free(stereotype)
		mm_text(s, x - strlen(node.label) * 4, middle - 2, node.label)
	else: mm_text(s, x - strlen(node.label) * 4, middle - 9, node.label)

# Message label: optional sequence number, then the text.
char* mm_n_message_label(mm_narrative_event* event, int ordinal, int numbered):
	int shown = -1
	if (event.start): shown = event.value
	else if (numbered): shown = ordinal
	return mm_n_label(event, shown)

# Event rows sit 70px apart from y=170; a wrapped multi-line message label
# pushes its own and every later row down. rows has one entry past the end.
list[int] mm_n_rows(mm_document* d, int wrap, int numbered):
	list[int] rows = new list[int]
	int extra = 0
	int ordinal = 0
	for i in range(d.narrative.length):
		mm_narrative_event* event = d.narrative[i]
		if (event.kind == MM_N_MESSAGE):
			ordinal = ordinal + 1
			if (wrap > 0):
				char* label = mm_n_message_label(event, ordinal, numbered)
				mm_text_block* b = mm_text_layout(label, wrap)
				extra = extra + (mm_text_lines(b) - 1) * MM_TEXT_PITCH
				mm_text_block_free(b)
				free(label)
		rows.push(170 + i * 70 + extra)
	rows.push(170 + d.narrative.length * 70 + extra)
	return rows

void mm_n_lifelines(mm_document* d, mm_scene* s):
	int count = d.nodes.length
	# sequence.* configuration; the defaults reproduce the unconfigured layout.
	int gap = mm_config_number(d, c"sequence.actorMargin", 40)
	int box_width = mm_config_number(d, c"sequence.width", 160)
	int box_height = mm_config_number(d, c"sequence.height", 55)
	int bar = mm_config_number(d, c"sequence.activationWidth", 12)
	char* align = mm_config_value(d, c"sequence.messageAlign")
	int numbered = mm_config_flag(d, c"sequence.showSequenceNumbers", 0)
	int wrap = 0
	if (mm_config_flag(d, c"sequence.wrap", mm_config_flag(d, c"wrap", 0))): wrap = box_width + gap
	list[int] rows = mm_n_rows(d, wrap, numbered)
	int bottom = rows[d.narrative.length] + 10
	for mm_node* node in d.nodes:
		int width = strlen(node.label) * 8 + 20 + gap
		int stereotype_width = strlen(node.annotation) * 8 + 52 + gap
		if (node.annotation[0] != 0 && stereotype_width > width): width = stereotype_width
		if (width < box_width + gap): width = box_width + gap
		s.nodes.push(new mm_bounds(0, 65, width, box_height, 0, 0))
	# Charge each message's width to one lane, not every lane. A single long
	# label with 1024 participants therefore cannot overflow 32-bit geometry.
	for mm_narrative_event* event in d.narrative:
		if (event.from_node >= 0):
			mm_bounds* bounds = s.nodes[event.from_node]
			int needed = mm_n_text_width(event.label, wrap) + 40 + gap
			if (needed > bounds.w): bounds.w = needed
	int right = mm_config_number(d, c"sequence.diagramMarginX", 80) - gap / 2
	for mm_bounds* bounds in s.nodes:
		bounds.x = right + gap / 2
		right = right + bounds.w
		bounds.w = bounds.w - gap
	# Participant boxes span their contiguous lanes behind every other primitive.
	for mm_narrative_event* box in d.boxes:
		mm_bounds* first = s.nodes[box.from_node]
		mm_bounds* last = s.nodes[box.to_node]
		# The top stays below an optional diagram title at y=20..36.
		mm_draw(s, MM_BOX, first.x - 15, 40, last.x + last.w + 15, bottom + 20, 0, c"")
		mm_primitive* outline = s.items[s.items.length - 1]
		outline.style.mask = MM_STYLE_FILL
		outline.style.fill = box.value
		if (box.label[0] != 0): mm_text(s, (first.x + last.x + last.w) / 2 - strlen(box.label) * 4, 44, box.label)
	# Fragment outlines precede lifelines and events so opaque primitives never hide them.
	for i in range(d.narrative.length):
		mm_narrative_event* event = d.narrative[i]
		if (event.kind == MM_N_BLOCK):
			int depth = 0
			for j in range(i):
				mm_narrative_event* outer = d.narrative[j]
				if (outer.kind == MM_N_BLOCK && outer.end > i): depth = depth + 1
			int x = 30 + depth * 8
			int y = rows[i] - 25
			mm_draw(s, MM_BOX, x, y, right + 15 - depth * 8, rows[event.end] + 5, 0, c"")
			# rect highlights are filled, borderless backgrounds rather than labelled fragments.
			if (d.kind == MM_SEQUENCE && strcmp(event.detail, c"rect") == 0):
				mm_primitive* highlight = s.items[s.items.length - 1]
				highlight.style.mask = MM_STYLE_FILL | MM_STYLE_STROKE
				highlight.style.fill = event.value
				highlight.style.stroke = event.value
	for i in range(count):
		mm_node* node = d.nodes[i]
		mm_bounds* bounds = s.nodes[i]
		int x = bounds.x + bounds.w / 2
		int end_y = bottom
		int dies = 0
		for j in range(d.narrative.length):
			mm_narrative_event* event = d.narrative[j]
			if (event.from_node != i): continue
			if (event.kind == MM_N_CREATE): bounds.y = rows[j] - 15
			if (event.kind == MM_N_DESTROY):
				end_y = rows[event.end]
				dies = 1
		int shift = bounds.y - 65
		int actor_start = s.items.length
		mm_n_actor_box(d, s, node, bounds, bounds.y)
		mm_style_role(s, actor_start, MM_ROLE_ACTOR, i)
		int line_start = s.items.length
		mm_line(s, x, 140 + shift, x, end_y, 1)
		mm_style_role(s, line_start, MM_ROLE_ACTOR_LINE, i)
		if (d.kind == MM_SEQUENCE): mm_n_link_menu(s, node, bounds, end_y + 32)
		if (dies):
			mm_line(s, x - 9, end_y - 9, x + 9, end_y + 9, 0)
			mm_line(s, x - 9, end_y + 9, x + 9, end_y - 9, 0)
		# sequence.mirrorActors repeats each surviving participant below its lifeline.
		else if (mm_config_flag(d, c"sequence.mirrorActors", 0)): mm_n_actor_box(d, s, node, bounds, end_y + 10)
		# Draw outer activation bars first, so nested bars remain visible.
		int depth = 0
		for j in range(d.narrative.length):
			mm_narrative_event* event = d.narrative[j]
			if (event.from_node != i): continue
			if (event.kind == MM_N_DEACTIVATE): depth = depth - 1
			if (event.kind != MM_N_ACTIVATE): continue
			int balance = 1
			int activation_end = end_y
			for k in range(j + 1, d.narrative.length):
				mm_narrative_event* later = d.narrative[k]
				if (later.from_node != i): continue
				if (later.kind == MM_N_ACTIVATE): balance = balance + 1
				if (later.kind == MM_N_DEACTIVATE): balance = balance - 1
				if (balance == 0):
					if (rows[k] < activation_end): activation_end = rows[k]
					break
			int ax = x - bar / 2 + depth * 5
			mm_draw(s, MM_BOX, ax, rows[j], ax + bar, activation_end, 0, c"")
			depth = depth + 1

	int ordinal = 0
	for i in range(d.narrative.length):
		mm_narrative_event* event = d.narrative[i]
		int y = rows[i]
		int x = 0
		int to = 0
		if (event.from_node >= 0):
			mm_bounds* bounds = s.nodes[event.from_node]
			x = bounds.x + bounds.w / 2
		if (event.to_node >= 0):
			mm_bounds* bounds = s.nodes[event.to_node]
			to = bounds.x + bounds.w / 2
		int event_start = s.items.length
		if (event.kind == MM_N_MESSAGE):
			int direction = 1
			if (to < x): direction = -1
			if (x == to):
				mm_line(s, x, y, x + 45, y, event.dashed)
				mm_line(s, x + 45, y, x + 45, y + 25, event.dashed)
				mm_line(s, x + 45, y + 25, x, y + 25, event.dashed)
				mm_n_arrow(s, x, y + 25, -1, event.arrow)
			else:
				mm_line(s, x, y, to, y, event.dashed)
				mm_n_arrow(s, to, y, direction, event.arrow)
				if (event.arrow == 4): mm_n_arrow(s, x, y, 0 - direction, event.arrow)
				# Central connections mark the lifeline point with a small circle.
				if (event.central & 1): mm_draw(s, MM_CIRCLE, x + direction * 2 - 5, y - 5, x + direction * 2 + 5, y + 5, 0, c"")
				if (event.central & 2): mm_draw(s, MM_CIRCLE, to - direction * 14 - 5, y - 5, to - direction * 14 + 5, y + 5, 0, c"")
			ordinal = ordinal + 1
			char* label = mm_n_message_label(event, ordinal, numbered)
			if (x == to): mm_n_message_text(s, x + 8, y - 23, label, wrap)
			else:
				int label_width = mm_n_text_width(label, wrap)
				int label_x = (x + to) / 2 - label_width / 2
				int low = x
				int high = to
				if (high < low):
					low = to
					high = x
				if (align != 0 && strcmp(align, c"left") == 0): label_x = low + 10
				if (align != 0 && strcmp(align, c"right") == 0): label_x = high - label_width - 10
				if (label_x < 10): label_x = 10
				mm_n_message_text(s, label_x, y - 23, label, wrap)
			if (d.kind == MM_ZENUML):
				int comment_x = (x + to) / 2 - strlen(label) * 4
				if (x == to): comment_x = x + 8
				if (comment_x < 10): comment_x = 10
				mm_n_zen_comment_draw(s, event, comment_x, y - 25)
			free(label)
			mm_style_role(s, event_start, MM_ROLE_SIGNAL, 0)
		else if (event.kind == MM_N_NOTE):
			int w = mm_n_text_width(event.label, 0) + 24
			int extra = mm_n_text_height(event.label) - 18
			int nx = (x + to) / 2 - w / 2
			if (event.value < 0): nx = x - w - 15
			if (event.value > 0): nx = x + 15
			if (nx < 10): nx = 10
			mm_draw(s, MM_BOX, nx, y - 20 - extra / 2, nx + w, y + 20 + extra - extra / 2, 0, c"")
			mm_n_rich_text(s, nx + 12, y - 8 - extra / 2, event.label)
			mm_style_role(s, event_start, MM_ROLE_NOTE, 0)
		else if (event.kind == MM_N_BLOCK && (d.kind != MM_SEQUENCE || strcmp(event.detail, c"rect") != 0)):
			mm_text(s, 45, y - 17, event.label)
			if (d.kind == MM_ZENUML): mm_n_zen_comment_draw(s, event, 45, y - 19)
		else if (event.kind == MM_N_BRANCH):
			mm_line(s, 35, y - 20, right + 10, y - 20, 1)
			mm_text(s, 45, y - 12, event.label)
	__w_list_free(cast(__w_list*, rows))

void mm_n_journey_scene(mm_document* d, mm_scene* s):
	int x = 110
	int previous_x = -1
	int previous_y = 0
	char* section = c""
	for i in range(d.narrative.length):
		mm_narrative_event* event = d.narrative[i]
		int w = mm_n_text_width(event.label, 0) + 40
		int actors_width = strlen(event.detail) * 8 + 30
		if (actors_width > w): w = actors_width
		if (w < 180): w = 180
		if (strcmp(event.section, section) != 0):
			mm_text(s, x, 60, event.section)
			section = event.section
		mm_draw(s, MM_BOX, x, 100, x + w - 20, 150, 1, c"")
		mm_n_rich_text(s, x + 10, 117 - (mm_n_text_height(event.label) - 18) / 2, event.label)
		mm_text(s, x + 10, 365, event.detail)
		int cx = x + (w - 20) / 2
		int y = 345 - event.value * 34
		mm_line(s, cx, 155, cx, 350, 1)
		if (previous_x >= 0): mm_line(s, previous_x, previous_y, cx, y, 0)
		mm_draw(s, MM_CIRCLE, cx - 14, y - 14, cx + 14, y + 14, 0, c"")
		char[2] number
		number[0] = cast(char, '0' + event.value)
		number[1] = 0
		mm_text(s, cx - 4, y - 7, number)
		s.nodes.push(new mm_bounds(x, 100, w - 20, 50, 0, 0))
		previous_x = cx
		previous_y = y
		x = x + w + 20
	for score in range(1, 6):
		char[2] number
		number[0] = cast(char, '0' + score)
		number[1] = 0
		mm_text(s, 55, 338 - score * 34, number)
	mm_text(s, 30, 145, c"Score")

# Length of a `<br>`, `<br/>` or `<br />` tag (any case) at text[i], else 0.
int mm_n_break_tag(char* text, int i):
	if (text[i] != '<' || tolower(text[i + 1]) != 'b' || tolower(text[i + 2]) != 'r'): return 0
	int at = i + 3
	while (text[at] == ' '): at = at + 1
	if (text[at] == '/'): at = at + 1
	if (text[at] != '>'): return 0
	return at + 1 - i

# Timeline labels keep `<br>` in the model and break into display lines here.
list[char*] mm_n_label_lines(char* text):
	list[char*] lines = new list[char*]
	int start = 0
	int i = 0
	while (text[i] != 0):
		int tag = mm_n_break_tag(text, i)
		if (tag > 0):
			lines.push(mm_n_part(text, start, i))
			i = i + tag
			start = i
		else: i = i + 1
	lines.push(mm_n_part(text, start, i))
	return lines

int mm_n_lines_width(list[char*] lines):
	int width = 0
	for char* line in lines:
		if (strlen(line) > width): width = strlen(line)
	return width

void mm_n_lines_free(list[char*] lines):
	for char* line in lines: free(line)
	__w_list_free(cast(__w_list*, lines))

void mm_n_lines_draw(mm_scene* s, int x, int y, list[char*] lines):
	for i in range(lines.length): mm_text(s, x, y + i * 18, lines[i])

# Timeline labels: `<br>` lines as before, Markdown strings via the rich layout.
void mm_n_timeline_text(mm_scene* s, int x, int y, char* label, list[char*] lines):
	if (mm_text_is_markdown(label)): mm_label(s, x, y, label, 0, 0)
	else: mm_n_lines_draw(s, x, y, lines)

void mm_n_timeline_scene(mm_document* d, mm_scene* s):
	# Every period header shares the tallest header's height, so the axis stays straight.
	int header_lines = 1
	for mm_narrative_event* event in d.narrative:
		if (event.kind != MM_N_PERIOD): continue
		list[char*] lines = mm_n_label_lines(event.label)
		if (lines.length > header_lines): header_lines = lines.length
		mm_n_lines_free(lines)
	int extra = (header_lines - 1) * 18
	int axis = 180 + extra
	int x = 60
	int index = 0
	char* section = c""
	# Upstream colors each section (or each period without sections) unless
	# timeline.disableMulticolor is set; natively the boxes stay in the theme
	# palette unless disableMulticolor: false or sectionFills is configured.
	int fills = mm_config_count(d, c"timeline.sectionFills")
	int multicolor = fills > 0 || mm_config_flag(d, c"timeline.disableMulticolor", 1) == 0
	int min_width = mm_config_number(d, c"timeline.width", 170)
	int color_index = -1
	while (index < d.narrative.length):
		mm_narrative_event* period = d.narrative[index]
		int period_start = s.items.length
		if (period.section[0] == 0 || strcmp(period.section, section) != 0 || color_index < 0): color_index = color_index + 1
		list[char*] period_lines = mm_n_label_lines(period.label)
		int next = index + 1
		int width = mm_n_lines_width(period_lines) * 8 + 40
		while (next < d.narrative.length):
			mm_narrative_event* event = d.narrative[next]
			if (event.kind == MM_N_PERIOD): break
			list[char*] lines = mm_n_label_lines(event.label)
			int needed = mm_n_lines_width(lines) * 8 + 40
			mm_n_lines_free(lines)
			if (needed > width): width = needed
			next = next + 1
		if (width < min_width): width = min_width
		if (strcmp(period.section, section) != 0):
			mm_text(s, x, 60, period.section)
			section = period.section
		mm_draw(s, MM_BOX, x, 100, x + width, 145 + extra, 1, c"")
		mm_n_timeline_text(s, x + 15, 115, period.label, period_lines)
		mm_n_lines_free(period_lines)
		int cx = x + width / 2
		mm_line(s, x - 15, axis, x + width + 35, axis, 0)
		mm_draw(s, MM_CIRCLE, cx - 5, axis - 5, cx + 5, axis + 5, 1, c"")
		mm_line(s, cx, 145 + extra, cx, axis, 0)
		s.nodes.push(new mm_bounds(x, 100, width, 45 + extra, 0, 0))
		int y = axis + 40
		for i in range(index + 1, next):
			mm_narrative_event* event = d.narrative[i]
			list[char*] lines = mm_n_label_lines(event.label)
			int height = 45 + (lines.length - 1) * 18
			mm_line(s, cx, y - 40, cx, y, 0)
			mm_draw(s, MM_BOX, x, y, x + width, y + height, 0, c"")
			mm_n_timeline_text(s, x + 15, y + 15, event.label, lines)
			mm_n_lines_free(lines)
			y = y + height + 35
		if (multicolor):
			int fill = mm_style_series_color(color_index)
			if (fills > 0): fill = mm_style_color(mm_config_item(d, c"timeline.sectionFills", color_index % fills))
			for k in range(period_start, s.items.length):
				mm_primitive* box = s.items[k]
				if (box.kind != MM_BOX): continue
				box.style.mask = box.style.mask | MM_STYLE_FILL
				box.style.fill = fill
		x = x + width + 50
		index = next

void mm_n_two_digits(string_builder* out, int value, int pad):
	if (value < 10 && pad != 0): string_append_char(out, pad)
	string_append_int(out, value)

# strftime-style axis labels for a day or minute moment (tokens validated by the parser).
void mm_n_format_moment(string_builder* out, int value, int minutes, char* format):
	int days = value
	int clock = 0
	if (minutes):
		days = value / 1440
		clock = value % 1440
	int weekday = (days + 4) % 7
	int year = 1970
	while (days >= 365 + mm_n_leap(year)):
		days = days - 365 - mm_n_leap(year)
		year = year + 1
	int ordinal = days + 1
	int month = 1
	while (month < 12 && days >= mm_n_month_length(year, month)):
		days = days - mm_n_month_length(year, month)
		month = month + 1
	int day = days + 1
	list[char*] months = list[char*]{c"January", c"February", c"March", c"April", c"May", c"June", c"July", c"August", c"September", c"October", c"November", c"December"}
	list[char*] weekdays = list[char*]{c"Sunday", c"Monday", c"Tuesday", c"Wednesday", c"Thursday", c"Friday", c"Saturday"}
	int i = 0
	while (format[i] != 0):
		int c = format[i]
		if (c != '%' || format[i + 1] == 0):
			string_append_char(out, c)
			i = i + 1
			continue
		int token = format[i + 1]
		int hour = clock / 60
		if (token == 'Y'): string_append_int(out, year)
		else if (token == 'y'): mm_n_two_digits(out, year % 100, '0')
		else if (token == 'm'): mm_n_two_digits(out, month, '0')
		else if (token == 'd'): mm_n_two_digits(out, day, '0')
		else if (token == 'e'): mm_n_two_digits(out, day, ' ')
		else if (token == 'B'): string_append(out, months[month - 1])
		else if (token == 'b'): string_append_bytes(out, months[month - 1], 3)
		else if (token == 'A'): string_append(out, weekdays[weekday])
		else if (token == 'a'): string_append_bytes(out, weekdays[weekday], 3)
		else if (token == 'H'): mm_n_two_digits(out, hour, '0')
		else if (token == 'I'):
			int twelve = hour % 12
			if (twelve == 0): twelve = 12
			mm_n_two_digits(out, twelve, '0')
		else if (token == 'M'): mm_n_two_digits(out, clock % 60, '0')
		else if (token == 'p'):
			if (hour < 12): string_append(out, c"AM")
			else: string_append(out, c"PM")
		else if (token == 'j'):
			if (ordinal < 100): string_append_char(out, '0')
			mm_n_two_digits(out, ordinal, '0')
		else: string_append_char(out, token)
		i = i + 2
	__w_list_free(cast(__w_list*, months))
	__w_list_free(cast(__w_list*, weekdays))

char* mm_n_date_text(int days):
	string_builder* out = string_new()
	mm_n_format_moment(out, days, 0, c"%Y-%m-%d")
	char* result = out.data
	free(out)
	return result

char* mm_n_axis_label(mm_gantt_settings* g, int value):
	char* format = g.axis_format
	if (format[0] == 0 && g.minutes): format = c"%Y-%m-%d %H:%M"
	if (format[0] == 0): format = c"%Y-%m-%d"
	string_builder* out = string_new()
	mm_n_format_moment(out, value, g.minutes, format)
	char* result = out.data
	free(out)
	return result

# The axisFormat statement wins over gantt.axisFormat, as upstream.
char* mm_n_gantt_label(mm_document* d, mm_gantt_settings* g, int value):
	char* configured = mm_config_value(d, c"gantt.axisFormat")
	if (g.axis_format[0] != 0 || configured == 0): return mm_n_axis_label(g, value)
	string_builder* out = string_new()
	mm_n_format_moment(out, value, g.minutes, configured)
	char* result = out.data
	free(out)
	return result

# Day charts keep whole pixels per day; minute charts scale to 800 pixels.
struct mm_n_axis:
	int left
	int earliest
	int span
	int unit
	int minutes

int mm_n_axis_x(mm_n_axis* axis, int value):
	if (axis.minutes == 0): return axis.left + (value - axis.earliest) * axis.unit
	return axis.left + cast(int, cast(float, value - axis.earliest) * 800.0 / cast(float, axis.span))

void mm_n_paint(mm_scene* s, int fill, int stroke):
	mm_primitive* item = s.items[s.items.length - 1]
	item.style.mask = 2
	item.style.stroke = stroke
	if (fill >= 0):
		item.style.mask = 3
		item.style.fill = fill
	item.style.mask = item.style.mask | 8
	item.style.width = 2

void mm_n_gantt_shading(mm_gantt_settings* g, mm_n_axis* axis, mm_scene* s, int latest, int height):
	if (g.weekday_mask == 0 && g.excluded.length == 0): return
	int per = 1
	if (axis.minutes): per = 1440
	int first = axis.earliest / per
	int last = (latest + per - 1) / per
	# Shading is a reading aid; very long calendars skip it rather than emit thousands of boxes.
	if (last - first > 1000): return
	int day = first
	while (day < last):
		if (mm_n_excluded_day(g, day) == 0):
			day = day + 1
			continue
		int run = day
		while (run < last && mm_n_excluded_day(g, run)): run = run + 1
		int a = day * per
		int b = run * per
		if (a < axis.earliest): a = axis.earliest
		if (b > latest): b = latest
		mm_draw(s, MM_BOX, mm_n_axis_x(axis, a), 100, mm_n_axis_x(axis, b), height, 0, c"")
		mm_n_paint(s, 0xe2e8f0, 0xe2e8f0)
		mm_style_role(s, s.items.length - 1, MM_ROLE_EXCLUDE, 0)
		day = run

# Year and month of a day count (days since 1970-01-01).
void mm_n_civil(int days, int* year, int* month):
	int y = 1970
	while (days >= 365 + mm_n_leap(y)):
		days = days - 365 - mm_n_leap(y)
		y = y + 1
	int m = 1
	while (days >= mm_n_month_length(y, m)):
		days = days - mm_n_month_length(y, m)
		m = m + 1
	*year = y
	*month = m

# Moments of the configured gantt.tickInterval ("2week", "6hour", "1month")
# from earliest to latest, at most 1000; null when none is configured.
list[int] mm_n_gantt_ticks(mm_document* d, mm_gantt_settings* g, int earliest, int latest):
	char* interval = mm_config_value(d, c"gantt.tickInterval")
	if (interval == 0): return 0
	int count = 0
	int at = 0
	while (interval[at] >= '0' && interval[at] <= '9'):
		count = count * 10 + interval[at] - '0'
		at = at + 1
	char* unit = interval + at
	list[int] ticks = new list[int]
	int per_day = 1
	if (g.minutes): per_day = 1440
	if (strcmp(unit, c"month") == 0):
		int year = 0
		int month = 0
		mm_n_civil(earliest / per_day, &year, &month)
		int value = mm_n_days(year, month, 1) * per_day
		while (ticks.length < 1000 && year <= 9999):
			if (value >= earliest && value <= latest): ticks.push(value)
			if (value > latest): break
			month = month + count
			while (month > 12):
				month = month - 12
				year = year + 1
			if (year > 9999): break
			value = mm_n_days(year, month, 1) * per_day
		return ticks
	# Interval length in chart units: days, or minutes for charts with a time of day.
	int minutes = count
	if (strcmp(unit, c"hour") == 0): minutes = count * 60
	else if (strcmp(unit, c"day") == 0): minutes = count * 1440
	else if (strcmp(unit, c"week") == 0): minutes = count * 10080
	else if (strcmp(unit, c"second") == 0 || strcmp(unit, c"millisecond") == 0): minutes = 1
	int step = minutes
	if (g.minutes == 0): step = (minutes + 1439) / 1440
	if (step < 1): step = 1
	# Keep at most 1000 ticks; a finer interval coarsens deterministically.
	if ((latest - earliest) / step > 999): step = (latest - earliest) / 999 + 1
	int first = earliest
	if (strcmp(unit, c"week") == 0):
		# Weekly ticks start on gantt.weekday (default sunday); 1970-01-01 was a Thursday.
		char* weekday = mm_config_value(d, c"gantt.weekday")
		int target = 0
		list[char*] names = list[char*]{c"sunday", c"monday", c"tuesday", c"wednesday", c"thursday", c"friday", c"saturday"}
		for i in range(7):
			if (weekday != 0 && strcmp(weekday, names[i]) == 0): target = i
		__w_list_free(cast(__w_list*, names))
		int day = (earliest + per_day - 1) / per_day
		while ((day + 4) % 7 != target): day = day + 1
		first = day * per_day
	else if (g.minutes): first = (earliest + step - 1) / step * step
	int value = first
	while (value <= latest && ticks.length < 1000):
		ticks.push(value)
		value = value + step
	return ticks

void mm_n_gantt_scene(mm_document* d, mm_scene* s):
	if (d.narrative.length == 0): return
	mm_gantt_settings* g = mm_n_gantt_settings(d)
	int earliest = 2147483647
	int latest = 0
	int left = mm_config_number(d, c"gantt.leftPadding", 180)
	int compact = 0
	char* mode = mm_config_value(d, c"gantt.displayMode")
	if (mode != 0 && strcmp(mode, c"compact") == 0): compact = 1
	for mm_narrative_event* task in d.narrative:
		if (task.start < earliest): earliest = task.start
		if (task.end > latest): latest = task.end
		int needed = strlen(task.label) * 8 + 90
		if (compact): needed = strlen(task.section) * 8 + 90
		if (needed > left): left = needed
	# Rows: one per task, or packed per section in compact mode. Configured
	# barHeight/barGap replace the native 30px bars on an 85px pitch and
	# reserve a header gap before each section.
	int bar = 30
	int pitch = 85
	int header = 0
	if (mm_config_has(d, c"gantt.barHeight") || mm_config_has(d, c"gantt.barGap")):
		bar = mm_config_number(d, c"gantt.barHeight", 20)
		pitch = bar + mm_config_number(d, c"gantt.barGap", 4)
		if (pitch < MM_TEXT_PITCH): pitch = MM_TEXT_PITCH
		header = 34
	list[int] rows = new list[int]
	list[int] row_ends = new list[int]
	list[int] row_y = new list[int]
	char* section = c""
	int y = 135
	int section_rows = 0
	for i in range(d.narrative.length):
		mm_narrative_event* task = d.narrative[i]
		if (strcmp(task.section, section) != 0 || i == 0):
			if (i > 0 || header): y = y + header
			if (i > 0 && compact): y = y + section_rows * pitch
			__w_list_free(cast(__w_list*, row_ends))
			row_ends = new list[int]
			section = task.section
			section_rows = 0
		int row = row_ends.length
		if (compact):
			for k in range(row_ends.length):
				if (row == row_ends.length && row_ends[k] <= task.start): row = k
		if (row == row_ends.length): row_ends.push(task.end)
		else: row_ends[row] = task.end
		if (row_ends.length > section_rows): section_rows = row_ends.length
		if (compact): row_y.push(y + row * pitch)
		else:
			row_y.push(y)
			y = y + pitch
		rows.push(row)
	if (compact): y = y + section_rows * pitch
	__w_list_free(cast(__w_list*, row_ends))
	int span = latest - earliest
	if (span < 1): span = 1
	mm_n_axis* axis = new mm_n_axis()
	axis.left = left
	axis.earliest = earliest
	axis.span = span
	axis.minutes = g.minutes
	int unit = 800 / span
	if (unit > 40): unit = 40
	if (unit < 1): unit = 1
	axis.unit = unit
	int width = span * unit
	if (g.minutes): width = 800
	char* sample = mm_n_gantt_label(d, g, earliest)
	int label_width = strlen(sample) * 8 + 24
	free(sample)
	if (label_width < 120): label_width = 120
	int height = y - pitch + bar + 80
	if (pitch == 85 && header == 0): height = d.narrative.length * 85 + 160
	mm_n_gantt_shading(g, axis, s, latest, height)
	# Axis labels sit above the chart natively; gantt.topAxis: true adds the
	# bottom axis upstream draws by default, and false keeps only that one.
	int top_labels = 1
	int bottom_labels = 0
	if (mm_config_has(d, c"gantt.topAxis")):
		bottom_labels = 1
		top_labels = mm_config_flag(d, c"gantt.topAxis", 0)
	list[int] ticks = mm_n_gantt_ticks(d, g, earliest, latest)
	if (ticks == 0):
		ticks = new list[int]
		int tick = 0
		int first_tick = earliest
		if (g.minutes == 0):
			tick = (span + 7) / 8
			int minimum_tick = (label_width + unit - 1) / unit
			if (tick < minimum_tick): tick = minimum_tick
		else:
			list[int] steps = list[int]{1, 5, 10, 15, 30, 60, 120, 180, 360, 720, 1440, 2880, 10080, 20160, 43200, 129600, 525600}
			for int step in steps:
				if (tick == 0 && cast(float, step) * 800.0 / cast(float, span) >= cast(float, label_width)): tick = step
			__w_list_free(cast(__w_list*, steps))
			if (tick == 0): tick = span
			first_tick = (earliest + tick - 1) / tick * tick
		int value = first_tick
		while (value <= latest):
			ticks.push(value)
			if (value > latest - tick): break
			value = value + tick
	for int value in ticks:
		int x = mm_n_axis_x(axis, value)
		mm_line(s, x, 95, x, height, 1)
		mm_style_role(s, s.items.length - 1, MM_ROLE_GRID, 0)
		char* date = mm_n_gantt_label(d, g, value)
		if (top_labels): mm_text(s, x, 70, date)
		if (bottom_labels): mm_text(s, x, height + 8, date)
		free(date)
	__w_list_free(cast(__w_list*, ticks))
	section = c""
	for i in range(d.narrative.length):
		mm_narrative_event* task = d.narrative[i]
		y = row_y[i]
		if (strcmp(task.section, section) != 0):
			if (compact): mm_text(s, 30, y + bar / 2 - 6, task.section)
			else: mm_text(s, 30, y - 30, task.section)
			section = task.section
		int x = mm_n_axis_x(axis, task.start)
		int w = mm_n_axis_x(axis, task.end) - x
		int middle = y + bar / 2
		if (compact): mm_text(s, x + 4, middle - 6, task.label)
		else: mm_text(s, 30, middle - 6, task.label)
		int task_start = s.items.length
		if ((task.value & 8) != 0):
			x = x + w / 2
			int half = 12
			if (bar / 2 < half): half = bar / 2
			mm_line(s, x, middle - half, x + half, middle, 0)
			mm_line(s, x + half, middle, x, middle + half, 0)
			mm_line(s, x, middle + half, x - half, middle, 0)
			mm_line(s, x - half, middle, x, middle - half, 0)
		else:
			if (w < 2): w = 2
			mm_draw(s, MM_BOX, x, y, x + w, y + bar, 0, c"")
			if ((task.value & 4) != 0 && w > 5 && bar > 6): mm_draw(s, MM_BOX, x + 2, y + 3, x + w - 2, y + bar - 3, 0, c"")
			if ((task.value & 1) != 0): mm_line(s, x, middle, x + w, middle, 0)
			if ((task.value & 2) != 0): mm_text(s, x + w + 8, middle - 8, c"active")
		int role = MM_ROLE_TASK
		if ((task.value & 2) != 0): role = MM_ROLE_TASK_ACTIVE
		if ((task.value & 1) != 0): role = MM_ROLE_TASK_DONE
		if ((task.value & 4) != 0): role = MM_ROLE_TASK_CRIT
		mm_style_role(s, task_start, role, i)
		s.nodes.push(new mm_bounds(x, y, w, bar, 0, 0))
	__w_list_free(cast(__w_list*, rows))
	__w_list_free(cast(__w_list*, row_y))
	mm_line(s, left, 100, left + width, 100, 0)
	if (g.today >= earliest && g.today <= latest):
		int x = mm_n_axis_x(axis, g.today)
		mm_line(s, x, 95, x, height, 0)
		mm_n_paint(s, -1, 0xdc2626)
		mm_style_role(s, s.items.length - 1, MM_ROLE_TODAY, 0)
	free(axis)

mm_scene* mm_narrative_render(mm_document* d):
	mm_scene* scene = new mm_scene()
	scene.items = new list[mm_primitive*]
	scene.nodes = new list[mm_bounds*]
	scene.width = 240
	scene.height = 160
	if (d.title[0] != 0):
		mm_text(scene, 30, 20, d.title)
		scene.has_title = 1
	if (d.kind == MM_SEQUENCE || d.kind == MM_ZENUML): mm_n_lifelines(d, scene)
	else if (d.kind == MM_JOURNEY): mm_n_journey_scene(d, scene)
	else if (d.kind == MM_TIMELINE): mm_n_timeline_scene(d, scene)
	else if (d.kind == MM_GANTT): mm_n_gantt_scene(d, scene)
	return scene
