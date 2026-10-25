# Lifelines, chronological event columns, scored journeys and a calendar axis.
import libs.extras.mermaid.narrative
import libs.extras.mermaid.scene

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

void mm_n_lifelines(mm_document* d, mm_scene* s):
	int count = d.nodes.length
	int bottom = 180 + d.narrative.length * 70
	for mm_node* node in d.nodes:
		int width = strlen(node.label) * 8 + 60
		int stereotype_width = strlen(node.annotation) * 8 + 92
		if (node.annotation[0] != 0 && stereotype_width > width): width = stereotype_width
		if (width < 200): width = 200
		s.nodes.push(new mm_bounds(0, 65, width, 55, 0))
	# Charge each message's width to one lane, not every lane. A single long
	# label with 1024 participants therefore cannot overflow 32-bit geometry.
	for mm_narrative_event* event in d.narrative:
		if (event.from_node >= 0):
			mm_bounds* bounds = s.nodes[event.from_node]
			int needed = strlen(event.label) * 8 + 80
			if (needed > bounds.w): bounds.w = needed
	int right = 60
	for mm_bounds* bounds in s.nodes:
		bounds.x = right + 20
		right = right + bounds.w
		bounds.w = bounds.w - 40
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
			int y = 145 + i * 70
			mm_draw(s, MM_BOX, x, y, right + 15 - depth * 8, 175 + event.end * 70, 0, c"")
			# rect highlights are filled, borderless backgrounds rather than labelled fragments.
			if (strcmp(event.detail, c"rect") == 0):
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
			if (event.kind == MM_N_CREATE): bounds.y = 155 + j * 70
			if (event.kind == MM_N_DESTROY):
				end_y = 170 + event.end * 70
				dies = 1
		int shift = bounds.y - 65
		if (node.shape == 1):
			mm_draw(s, MM_CIRCLE, x - 9, 58 + shift, x + 9, 76 + shift, 0, c"")
			mm_line(s, x, 76 + shift, x, 98 + shift, 0)
			mm_line(s, x - 16, 84 + shift, x + 16, 84 + shift, 0)
			mm_line(s, x, 98 + shift, x - 12, 110 + shift, 0)
			mm_line(s, x, 98 + shift, x + 12, 110 + shift, 0)
			mm_text(s, x - strlen(node.label) * 4, 115 + shift, node.label)
		else:
			mm_draw(s, MM_BOX, bounds.x, bounds.y, bounds.x + bounds.w, bounds.y + bounds.h, 0, c"")
			if (node.annotation[0] != 0):
				# ZenUML participant kinds (@Database, @Boundary, ...) as a stereotype line.
				string_builder* stereotype = string_from(c"<<")
				string_append(stereotype, node.annotation)
				string_append(stereotype, c">>")
				mm_text(s, x - stereotype.length * 4, 70 + shift, stereotype.data)
				string_free(stereotype)
				mm_text(s, x - strlen(node.label) * 4, 90 + shift, node.label)
			else: mm_text(s, x - strlen(node.label) * 4, 83 + shift, node.label)
		mm_line(s, x, 140 + shift, x, end_y, 1)
		if (dies):
			mm_line(s, x - 9, end_y - 9, x + 9, end_y + 9, 0)
			mm_line(s, x - 9, end_y + 9, x + 9, end_y - 9, 0)
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
					if (170 + k * 70 < activation_end): activation_end = 170 + k * 70
					break
			int ax = x - 6 + depth * 5
			mm_draw(s, MM_BOX, ax, 170 + j * 70, ax + 12, activation_end, 0, c"")
			depth = depth + 1

	for i in range(d.narrative.length):
		mm_narrative_event* event = d.narrative[i]
		int y = 170 + i * 70
		int x = 0
		int to = 0
		if (event.from_node >= 0):
			mm_bounds* bounds = s.nodes[event.from_node]
			x = bounds.x + bounds.w / 2
		if (event.to_node >= 0):
			mm_bounds* bounds = s.nodes[event.to_node]
			to = bounds.x + bounds.w / 2
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
			int shown = -1
			if (event.start): shown = event.value
			char* label = mm_n_label(event, shown)
			if (x == to): mm_text(s, x + 8, y - 23, label)
			else:
				int label_x = (x + to) / 2 - strlen(label) * 4
				if (label_x < 10): label_x = 10
				mm_text(s, label_x, y - 23, label)
			free(label)
		else if (event.kind == MM_N_NOTE):
			int w = strlen(event.label) * 8 + 24
			int nx = (x + to) / 2 - w / 2
			if (event.value < 0): nx = x - w - 15
			if (event.value > 0): nx = x + 15
			if (nx < 10): nx = 10
			mm_draw(s, MM_BOX, nx, y - 20, nx + w, y + 20, 0, c"")
			mm_text(s, nx + 12, y - 8, event.label)
		else if (event.kind == MM_N_BLOCK && strcmp(event.detail, c"rect") != 0): mm_text(s, 45, y - 17, event.label)
		else if (event.kind == MM_N_BRANCH):
			mm_line(s, 35, y - 20, right + 10, y - 20, 1)
			mm_text(s, 45, y - 12, event.label)

# Upstream journey actor colours, assigned in first-mention order.
int mm_n_actor_color(int index):
	list[int] colors = list[int]{0x8fbc8f, 0x7cfc00, 0x00ffff, 0x20b2aa, 0xb0e0e6, 0xffffe0}
	int color = colors[index % colors.length]
	__w_list_free(cast(__w_list*, colors))
	return color

void mm_n_fill(mm_scene* s, int fill, int stroke):
	mm_primitive* item = s.items[s.items.length - 1]
	item.style.mask = item.style.mask | 3
	item.style.fill = fill
	item.style.stroke = stroke

# Score face as upstream: smile above 3, sad below 3, neutral mouth at 3.
void mm_n_face(mm_scene* s, int cx, int cy, int score):
	mm_draw(s, MM_CIRCLE, cx - 15, cy - 15, cx + 15, cy + 15, 0, c"")
	mm_n_fill(s, 0xfff8dc, 0x999999)
	mm_draw(s, MM_CIRCLE, cx - 7, cy - 7, cx - 3, cy - 3, 0, c"")
	mm_n_fill(s, 0x666666, 0x666666)
	mm_draw(s, MM_CIRCLE, cx + 3, cy - 7, cx + 7, cy - 3, 0, c"")
	mm_n_fill(s, 0x666666, 0x666666)
	if (score == 3):
		mm_line(s, cx - 7, cy + 6, cx + 7, cy + 6, 0)
		return
	int px = cx - 7
	int py = 0
	for k in range(8):
		int dx = k * 2 - 7
		int curve = (49 - dx * dx) / 10
		int y = cy + 3 + curve
		if (score < 3): y = cy + 9 - curve
		if (k > 0): mm_line(s, px, py, cx + dx, y, 0)
		px = cx + dx
		py = y

void mm_n_journey_scene(mm_document* d, mm_scene* s):
	int x = 110
	int previous_x = -1
	int previous_y = 0
	char* section = c""
	for i in range(d.narrative.length):
		mm_narrative_event* event = d.narrative[i]
		int w = strlen(event.label) * 8 + 40
		int actors_width = strlen(event.detail) * 8 + 30
		if (actors_width > w): w = actors_width
		if (w < 180): w = 180
		if (strcmp(event.section, section) != 0):
			mm_text(s, x, 60, event.section)
			section = event.section
		mm_draw(s, MM_BOX, x, 100, x + w - 20, 150, 1, c"")
		mm_text(s, x + 10, 117, event.label)
		mm_text(s, x + 10, 365, event.detail)
		# Actor avatars: one coloured dot per listed actor along the task's top edge.
		int dot = x + 10
		int start = 0
		int length = strlen(event.detail)
		for k in range(length + 1):
			if (k < length && event.detail[k] != ','): continue
			char* name = mm_n_part(event.detail, start, k)
			int actor = mm_find_node(d, name)
			free(name)
			start = k + 1
			if (actor < 0 || dot > x + w - 34): continue
			mm_draw(s, MM_CIRCLE, dot, 93, dot + 14, 107, 0, c"")
			mm_n_fill(s, mm_n_actor_color(actor), 0x333333)
			dot = dot + 18
		int cx = x + (w - 20) / 2
		int y = 345 - event.value * 34
		mm_line(s, cx, 155, cx, 350, 1)
		if (previous_x >= 0): mm_line(s, previous_x, previous_y, cx, y, 0)
		mm_n_face(s, cx, y, event.value)
		s.nodes.push(new mm_bounds(x, 100, w - 20, 50, 0))
		previous_x = cx
		previous_y = y
		x = x + w + 20
	for score in range(1, 6):
		char[2] number
		number[0] = cast(char, '0' + score)
		number[1] = 0
		mm_text(s, 55, 338 - score * 34, number)
	mm_text(s, 30, 145, c"Score")
	# Actor legend below the chart, in first-mention order.
	for k in range(d.nodes.length):
		mm_node* actor = d.nodes[k]
		int ly = 400 + k * 24
		mm_draw(s, MM_CIRCLE, 30, ly, 44, ly + 14, 0, c"")
		mm_n_fill(s, mm_n_actor_color(k), 0x333333)
		mm_text(s, 52, ly - 1, actor.label)

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

# Light per-period (or per-section, when sections exist) colours as
# upstream's multicolour default; themes repaint them from cScale0..11.
void mm_n_timeline_paint(mm_scene* s, int series):
	if (series < 0): return
	list[int] colors = list[int]{0xdbeafe, 0xfee2e2, 0xdcfce7, 0xf3e8ff, 0xffedd5, 0xcffafe, 0xfce7f3, 0xecfccb, 0xe0e7ff, 0xccfbf1, 0xfef9c3, 0xede9fe}
	mm_primitive* item = s.items[s.items.length - 1]
	item.style.mask = item.style.mask | 1
	item.style.fill = colors[series % 12]
	item.role = 5
	item.series = series
	__w_list_free(cast(__w_list*, colors))

# Series of each period: its section's index when sections exist, else its
# own index; -1 for every period with `disableMulticolor`.
list[int] mm_n_timeline_series(mm_document* d):
	list[int] series = new list[int]
	char* setting = mm_setting(d, c"timeline.disableMulticolor")
	int plain = setting != 0 && strcmp(setting, c"true") == 0
	int sections = 0
	for mm_narrative_event* event in d.narrative:
		if (event.section[0] != 0): sections = 1
	int period = -1
	int section_index = -1
	char* section = 0
	for mm_narrative_event* event in d.narrative:
		if (event.kind == MM_N_PERIOD):
			period = period + 1
			if (section == 0 || strcmp(section, event.section) != 0):
				section_index = section_index + 1
				section = event.section
		int value = period
		if (sections): value = section_index
		if (plain): value = -1
		series.push(value)
	return series

void mm_n_timeline_vertical(mm_document* d, mm_scene* s, list[int] series):
	int period_width = 170
	for mm_narrative_event* event in d.narrative:
		if (event.kind != MM_N_PERIOD): continue
		list[char*] lines = mm_n_label_lines(event.label)
		int needed = mm_n_lines_width(lines) * 8 + 40
		if (needed > period_width): period_width = needed
		mm_n_lines_free(lines)
	int axis = 60 + period_width + 40
	int y = 90
	int top = y
	int index = 0
	char* section = c""
	while (index < d.narrative.length):
		mm_narrative_event* period = d.narrative[index]
		if (strcmp(period.section, section) != 0):
			mm_text(s, 60, y, period.section)
			section = period.section
			y = y + 30
		list[char*] period_lines = mm_n_label_lines(period.label)
		int height = 45 + (period_lines.length - 1) * 18
		int next = index + 1
		while (next < d.narrative.length):
			mm_narrative_event* event = d.narrative[next]
			if (event.kind == MM_N_PERIOD): break
			list[char*] lines = mm_n_label_lines(event.label)
			int needed = 45 + (lines.length - 1) * 18
			if (needed > height): height = needed
			mm_n_lines_free(lines)
			next = next + 1
		mm_draw(s, MM_BOX, 60, y, 60 + period_width, y + height, 1, c"")
		mm_n_timeline_paint(s, series[index])
		mm_n_lines_draw(s, 75, y + 15, period_lines)
		mm_n_lines_free(period_lines)
		int cy = y + height / 2
		mm_line(s, 60 + period_width, cy, axis, cy, 0)
		mm_draw(s, MM_CIRCLE, axis - 5, cy - 5, axis + 5, cy + 5, 1, c"")
		s.nodes.push(new mm_bounds(60, y, period_width, height, 0))
		int x = axis + 40
		for i in range(index + 1, next):
			mm_narrative_event* event = d.narrative[i]
			list[char*] lines = mm_n_label_lines(event.label)
			int width = mm_n_lines_width(lines) * 8 + 40
			if (width < 120): width = 120
			mm_line(s, x - 40, cy, x, cy, 0)
			mm_draw(s, MM_BOX, x, y, x + width, y + height, 0, c"")
			mm_n_timeline_paint(s, series[i])
			mm_n_lines_draw(s, x + 15, y + 15, lines)
			mm_n_lines_free(lines)
			x = x + width + 35
		y = y + height + 35
		index = next
	mm_line(s, axis, top - 15, axis, y, 0)

void mm_n_timeline_scene(mm_document* d, mm_scene* s):
	list[int] series = mm_n_timeline_series(d)
	char* direction = mm_setting(d, c"timeline.direction")
	if (direction != 0 && strcmp(direction, c"TD") == 0):
		mm_n_timeline_vertical(d, s, series)
		__w_list_free(cast(__w_list*, series))
		return
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
	while (index < d.narrative.length):
		mm_narrative_event* period = d.narrative[index]
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
		if (width < 170): width = 170
		if (strcmp(period.section, section) != 0):
			mm_text(s, x, 60, period.section)
			section = period.section
		mm_draw(s, MM_BOX, x, 100, x + width, 145 + extra, 1, c"")
		mm_n_timeline_paint(s, series[index])
		mm_n_lines_draw(s, x + 15, 115, period_lines)
		mm_n_lines_free(period_lines)
		int cx = x + width / 2
		mm_line(s, x - 15, axis, x + width + 35, axis, 0)
		mm_draw(s, MM_CIRCLE, cx - 5, axis - 5, cx + 5, axis + 5, 1, c"")
		mm_line(s, cx, 145 + extra, cx, axis, 0)
		s.nodes.push(new mm_bounds(x, 100, width, 45 + extra, 0))
		int y = axis + 40
		for i in range(index + 1, next):
			mm_narrative_event* event = d.narrative[i]
			list[char*] lines = mm_n_label_lines(event.label)
			int height = 45 + (lines.length - 1) * 18
			mm_line(s, cx, y - 40, cx, y, 0)
			mm_draw(s, MM_BOX, x, y, x + width, y + height, 0, c"")
			mm_n_timeline_paint(s, series[i])
			mm_n_lines_draw(s, x + 15, y + 15, lines)
			mm_n_lines_free(lines)
			y = y + height + 35
		x = x + width + 50
		index = next
	__w_list_free(cast(__w_list*, series))

void mm_n_two_digits(string_builder* out, int value, int pad):
	if (value < 10 && pad != 0): string_append_char(out, pad)
	string_append_int(out, value)

void mm_n_padded(string_builder* out, int value, int width, int pad):
	int digits = 1
	int limit = 10
	while (value >= limit && digits < 9):
		digits = digits + 1
		limit = limit * 10
	if (pad != 0):
		for i in range(width - digits): string_append_char(out, pad)
	string_append_int(out, value)

# Appends days * 86400 * scale + extra in decimal without 32-bit overflow
# (base-10000 limbs; scale and extra stay below 100000).
void mm_n_append_wide(string_builder* out, int days, int seconds, int scale, int extra):
	list[int] limbs = list[int]{days % 10000, days / 10000 % 10000, days / 100000000}
	list[int] factors = list[int]{86400, scale}
	for int factor in factors:
		int carry = 0
		for k in range(limbs.length):
			int value = limbs[k] * factor + carry
			limbs[k] = value % 10000
			carry = value / 10000
		while (carry > 0):
			limbs.push(carry % 10000)
			carry = carry / 10000
		if (factor == 86400):
			int add = seconds
			int at = 0
			while (add > 0):
				if (at == limbs.length): limbs.push(0)
				int value = limbs[at] + add
				limbs[at] = value % 10000
				add = value / 10000
				at = at + 1
	int add = extra
	int at = 0
	while (add > 0):
		if (at == limbs.length): limbs.push(0)
		int value = limbs[at] + add
		limbs[at] = value % 10000
		add = value / 10000
		at = at + 1
	int top = limbs.length - 1
	while (top > 0 && limbs[top] == 0): top = top - 1
	string_append_int(out, limbs[top])
	int k = top - 1
	while (k >= 0):
		mm_n_padded(out, limbs[k], 4, '0')
		k = k - 1
	__w_list_free(cast(__w_list*, limbs))
	__w_list_free(cast(__w_list*, factors))

int mm_n_iso_weeks_in(int year):
	int p = (year + year / 4 - year / 100 + year / 400) % 7
	int q = (year - 1 + (year - 1) / 4 - (year - 1) / 100 + (year - 1) / 400) % 7
	if (p == 4 || q == 3): return 53
	return 52

# ISO 8601 week [week, year] of a civil date (weekday 0 = Sunday).
list[int] mm_n_iso_week(int year, int ordinal, int weekday):
	int iso_day = (weekday + 6) % 7 + 1
	int week = (ordinal - iso_day + 10) / 7
	int iso_year = year
	if (week < 1):
		iso_year = year - 1
		week = mm_n_iso_weeks_in(iso_year)
	else if (week > mm_n_iso_weeks_in(year)):
		iso_year = year + 1
		week = 1
	return list[int]{week, iso_year}

# d3-time-format axis labels (UTC; directives validated by the parser) for a
# moment in `minutes` units: 0 days, 1 minutes, 2 seconds.
void mm_n_format_moment(string_builder* out, int value, int minutes, char* format):
	int days = value
	int clock = 0
	if (minutes == 1):
		days = value / 1440
		clock = value % 1440 * 60
	if (minutes == 2):
		days = value / 86400
		clock = value % 86400
	int weekday = (days + 4) % 7
	list[int] civil = mm_n_civil(days)
	int year = civil[0]
	int month = civil[1]
	int day = civil[2]
	int ordinal = civil[3]
	__w_list_free(cast(__w_list*, civil))
	list[char*] months = list[char*]{c"January", c"February", c"March", c"April", c"May", c"June", c"July", c"August", c"September", c"October", c"November", c"December"}
	list[char*] weekdays = list[char*]{c"Sunday", c"Monday", c"Tuesday", c"Wednesday", c"Thursday", c"Friday", c"Saturday"}
	int hour = clock / 3600
	int minute = clock / 60 % 60
	int second = clock % 60
	int twelve = hour % 12
	if (twelve == 0): twelve = 12
	int i = 0
	while (format[i] != 0):
		int c = format[i]
		if (c != '%' || format[i + 1] == 0):
			string_append_char(out, c)
			i = i + 1
			continue
		int pad = -1
		int modifier = format[i + 1]
		if (modifier == '-' || modifier == '_' || modifier == '0'):
			pad = 0
			if (modifier == '_'): pad = ' '
			if (modifier == '0'): pad = '0'
			i = i + 1
		int token = format[i + 1]
		int zero = '0'
		if (pad >= 0): zero = pad
		if (token == 'Y'): string_append_int(out, year)
		else if (token == 'y'): mm_n_two_digits(out, year % 100, zero)
		else if (token == 'm'): mm_n_two_digits(out, month, zero)
		else if (token == 'd'): mm_n_two_digits(out, day, zero)
		else if (token == 'e'):
			if (pad < 0): zero = ' '
			mm_n_two_digits(out, day, zero)
		else if (token == 'B'): string_append(out, months[month - 1])
		else if (token == 'b'): string_append_bytes(out, months[month - 1], 3)
		else if (token == 'A'): string_append(out, weekdays[weekday])
		else if (token == 'a'): string_append_bytes(out, weekdays[weekday], 3)
		else if (token == 'H'): mm_n_two_digits(out, hour, zero)
		else if (token == 'I'): mm_n_two_digits(out, twelve, zero)
		else if (token == 'M'): mm_n_two_digits(out, minute, zero)
		else if (token == 'S'): mm_n_two_digits(out, second, zero)
		else if (token == 'L'): string_append(out, c"000")
		else if (token == 'f'): string_append(out, c"000000")
		else if (token == 'p'):
			if (hour < 12): string_append(out, c"AM")
			else: string_append(out, c"PM")
		else if (token == 'j'):
			if (pad < 0): zero = '0'
			mm_n_padded(out, ordinal, 3, zero)
		else if (token == 'q'): string_append_int(out, (month - 1) / 3 + 1)
		else if (token == 's'): mm_n_append_wide(out, days, clock, 1, 0)
		else if (token == 'Q'): mm_n_append_wide(out, days, clock, 1000, 0)
		else if (token == 'w'): string_append_int(out, weekday)
		else if (token == 'u'): string_append_int(out, (weekday + 6) % 7 + 1)
		else if (token == 'U'): mm_n_two_digits(out, (ordinal - 1 + 7 - weekday) / 7, zero)
		else if (token == 'W'): mm_n_two_digits(out, (ordinal - 1 + 7 - (weekday + 6) % 7) / 7, zero)
		else if (token == 'V' || token == 'G' || token == 'g'):
			list[int] iso = mm_n_iso_week(year, ordinal, weekday)
			if (token == 'V'): mm_n_two_digits(out, iso[0], zero)
			else if (token == 'G'): string_append_int(out, iso[1])
			else: mm_n_two_digits(out, iso[1] % 100, zero)
			__w_list_free(cast(__w_list*, iso))
		else if (token == 'Z'): string_append(out, c"+0000")
		else if (token == 'x' || token == 'c'):
			string_append_int(out, month)
			string_append_char(out, '/')
			string_append_int(out, day)
			string_append_char(out, '/')
			string_append_int(out, year)
			if (token == 'c'): string_append(out, c", ")
		else if (token != 'X'): string_append_char(out, token)
		if (token == 'X' || token == 'c'):
			string_append_int(out, twelve)
			string_append_char(out, ':')
			mm_n_two_digits(out, minute, '0')
			string_append_char(out, ':')
			mm_n_two_digits(out, second, '0')
			if (hour < 12): string_append(out, c" AM")
			else: string_append(out, c" PM")
		i = i + 2
	__w_list_free(cast(__w_list*, months))
	__w_list_free(cast(__w_list*, weekdays))

char* mm_n_date_text(int days):
	string_builder* out = string_new()
	mm_n_format_moment(out, days, 0, c"%Y-%m-%d")
	char* result = out.data
	free(out)
	return result

# Labels are UTC; a chart promoted to minutes by sub-day durations keeps
# upstream's `%Y-%m-%d` default.
char* mm_n_axis_label(mm_gantt_settings* g, int value):
	char* format = g.axis_format
	if (format[0] == 0 && g.minutes == 1 && g.promoted == 0): format = c"%Y-%m-%d %H:%M"
	if (format[0] == 0 && g.minutes == 2): format = c"%Y-%m-%d %H:%M:%S"
	if (format[0] == 0): format = c"%Y-%m-%d"
	string_builder* out = string_new()
	mm_n_format_moment(out, value, g.minutes, format)
	char* result = out.data
	free(out)
	return result

# Day charts keep whole pixels per day; minute and second charts scale to 800 pixels.
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
	int per = mm_n_per_day(g)
	int first = axis.earliest / per
	int last = (latest / per) + (latest % per != 0)
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
		day = run

# Chart units of an explicit tickInterval (unit 1 ms ... 6 week), at least one.
int mm_n_tick_units(mm_gantt_settings* g):
	int unit_seconds = mm_n_unit_seconds(g)
	list[int] seconds = list[int]{0, 1, 60, 3600, 86400, 604800}
	int count = g.tick_count
	int result = 1
	if (g.tick_unit == 1):
		int whole = (count + 999) / 1000
		result = (whole + unit_seconds - 1) / unit_seconds
	else:
		int per = seconds[g.tick_unit - 1]
		if (per >= unit_seconds && count <= 2000000000 / (per / unit_seconds)): result = count * (per / unit_seconds)
		else if (per < unit_seconds && count <= 2000000000 / per): result = (count * per + unit_seconds - 1) / unit_seconds
		else: result = 2000000000
	__w_list_free(cast(__w_list*, seconds))
	if (result < 1): result = 1
	return result

# Tick moments for a valid `tickInterval` (and `weekday` for week ticks),
# or null when there is none or it would draw more than 200 ticks.
list[int] mm_n_explicit_ticks(mm_gantt_settings* g, int earliest, int latest):
	if (g.tick_unit == 0): return 0
	list[int] ticks = new list[int]
	int per = mm_n_per_day(g)
	if (g.tick_unit == 7):
		list[int] civil = mm_n_civil(earliest / per)
		int value = mm_n_days(civil[0], civil[1], 1) * per
		__w_list_free(cast(__w_list*, civil))
		if (value < earliest): value = mm_n_add_months(g, value, 1)
		while (value <= latest && ticks.length <= 200):
			ticks.push(value)
			value = mm_n_add_months(g, value, g.tick_count)
	else:
		int step = mm_n_tick_units(g)
		int value = earliest
		if (g.tick_unit == 6):
			int day = earliest / per + (earliest % per != 0)
			day = day + (g.week_start - (day + 4) % 7 + 7) % 7
			value = day * per
		else if (step > 1 && earliest % step != 0 && earliest <= 2147483647 - step): value = (earliest / step + 1) * step
		while (value <= latest && ticks.length <= 200):
			ticks.push(value)
			if (value > latest - step): break
			value = value + step
	if (ticks.length > 200 || ticks.length == 0):
		__w_list_free(cast(__w_list*, ticks))
		return 0
	return ticks

# Automatic ticks: about eight per day chart, label-width steps otherwise.
list[int] mm_n_auto_ticks(mm_gantt_settings* g, mm_n_axis* axis, int latest, int label_width):
	list[int] ticks = new list[int]
	int span = axis.span
	int tick = 0
	int first_tick = axis.earliest
	if (g.minutes == 0):
		tick = (span + 7) / 8
		int minimum_tick = (label_width + axis.unit - 1) / axis.unit
		if (tick < minimum_tick): tick = minimum_tick
	else:
		list[int] steps = list[int]{1, 5, 10, 15, 30, 60, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800, 604800, 1209600, 2592000, 7776000, 31536000}
		int unit_seconds = mm_n_unit_seconds(g)
		for int seconds in steps:
			int step = seconds / unit_seconds
			if (tick == 0 && seconds % unit_seconds == 0 && cast(float, step) * 800.0 / cast(float, span) >= cast(float, label_width)): tick = step
		__w_list_free(cast(__w_list*, steps))
		if (tick == 0): tick = span
		first_tick = (axis.earliest + tick - 1) / tick * tick
	int value = first_tick
	while (value <= latest):
		ticks.push(value)
		if (value > latest - tick): break
		value = value + tick
	return ticks

int mm_n_gantt_compact(mm_document* d, mm_gantt_settings* g):
	if (g.compact): return 1
	char* mode = mm_setting(d, c"gantt.displayMode")
	return mode != 0 && strcmp(mode, c"compact") == 0

# Row of every task (-1 for `vert` markers, which take no row). Compact mode
# places each task of a section in its first row that ends before it starts.
list[int] mm_n_gantt_rows(mm_document* d, int compact):
	list[int] rows = new list[int]
	list[int] ends = new list[int]
	int base = 0
	char* section = c""
	for mm_narrative_event* task in d.narrative:
		if ((task.value & 16) != 0):
			rows.push(-1)
			continue
		if (compact == 0):
			rows.push(base)
			base = base + 1
			continue
		if (strcmp(task.section, section) != 0):
			base = base + ends.length
			while (ends.length > 0): ends.pop()
			section = task.section
		int row = -1
		for k in range(ends.length):
			if (row < 0 && ends[k] <= task.start):
				row = k
				ends[k] = task.end
		if (row < 0):
			row = ends.length
			ends.push(task.end)
		rows.push(base + row)
	__w_list_free(cast(__w_list*, ends))
	return rows

void mm_n_gantt_scene(mm_document* d, mm_scene* s):
	mm_gantt_settings* g = mm_n_gantt_settings(d)
	if (d.narrative.length == 0):
		# An empty chart still shows its time axis baseline.
		mm_line(s, 180, 100, 980, 100, 0)
		return
	int saved_tick_count = g.tick_count
	int saved_tick_unit = g.tick_unit
	int saved_week = g.week_start
	char* configured = mm_setting(d, c"gantt.tickInterval")
	if (g.tick_unit == 0 && configured != 0): mm_n_tick_interval(g, configured)
	configured = mm_setting(d, c"gantt.weekday")
	if (configured != 0 && g.week_start == 0 && mm_n_weekday_index(configured) >= 0): g.week_start = mm_n_weekday_index(configured)
	char* saved_axis = g.axis_format
	configured = mm_setting(d, c"gantt.axisFormat")
	if (saved_axis[0] == 0 && configured != 0 && mm_n_axis_valid(configured)): g.axis_format = configured
	int earliest = 2147483647
	int latest = 0
	int left = 180
	for mm_narrative_event* task in d.narrative:
		if (task.start < earliest): earliest = task.start
		if (task.end > latest): latest = task.end
		int needed = strlen(task.label) * 8 + 90
		if (needed > left): left = needed
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
	char* sample = mm_n_axis_label(g, earliest)
	int label_width = strlen(sample) * 8 + 24
	free(sample)
	if (label_width < 120): label_width = 120
	int compact = mm_n_gantt_compact(d, g)
	list[int] rows = mm_n_gantt_rows(d, compact)
	int row_count = 0
	for int row in rows:
		if (row + 1 > row_count): row_count = row + 1
	int height = row_count * 85 + 160
	mm_n_gantt_shading(g, axis, s, latest, height)
	list[int] ticks = mm_n_explicit_ticks(g, earliest, latest)
	if (ticks == 0): ticks = mm_n_auto_ticks(g, axis, latest, label_width)
	for int value in ticks:
		int x = mm_n_axis_x(axis, value)
		mm_line(s, x, 95, x, height, 1)
		char* date = mm_n_axis_label(g, value)
		mm_text(s, x, 70, date)
		if (g.top_axis): mm_text(s, x, height + 8, date)
		free(date)
	__w_list_free(cast(__w_list*, ticks))
	char* section = c""
	for i in range(d.narrative.length):
		mm_narrative_event* task = d.narrative[i]
		int row = rows[i]
		int x = mm_n_axis_x(axis, task.start)
		if (row < 0):
			# `vert` markers are full-height reference lines without a row.
			mm_line(s, x, 95, x, height, 0)
			mm_n_paint(s, -1, 0x7c3aed)
			mm_text(s, x + 6, height - 24, task.label)
			s.nodes.push(new mm_bounds(x, 95, 0, height - 95, 0))
			continue
		int y = 135 + row * 85
		if (strcmp(task.section, section) != 0):
			mm_text(s, 30, y - 30, task.section)
			section = task.section
		int w = mm_n_axis_x(axis, task.end) - x
		if ((task.value & 8) != 0):
			x = x + w / 2
			mm_line(s, x, y + 3, x + 12, y + 15, 0)
			mm_line(s, x + 12, y + 15, x, y + 27, 0)
			mm_line(s, x, y + 27, x - 12, y + 15, 0)
			mm_line(s, x - 12, y + 15, x, y + 3, 0)
		else:
			if (w < 2): w = 2
			mm_draw(s, MM_BOX, x, y, x + w, y + 30, 0, c"")
			if ((task.value & 4) != 0 && w > 5): mm_draw(s, MM_BOX, x + 2, y + 3, x + w - 2, y + 27, 0, c"")
			if ((task.value & 1) != 0): mm_line(s, x, y + 15, x + w, y + 15, 0)
			if ((task.value & 2) != 0): mm_text(s, x + w + 8, y + 7, c"active")
		# Compact rows hold several tasks, so their labels sit on the bars.
		if (compact == 0): mm_text(s, 30, y + 9, task.label)
		else if ((task.value & 8) != 0): mm_text(s, x + 18, y + 9, task.label)
		else: mm_text(s, x + 4, y + 9, task.label)
		s.nodes.push(new mm_bounds(x, y, w, 30, 0))
	__w_list_free(cast(__w_list*, rows))
	mm_line(s, left, 100, left + width, 100, 0)
	if (g.today >= earliest && g.today <= latest):
		int x = mm_n_axis_x(axis, g.today)
		mm_line(s, x, 95, x, height, 0)
		mm_n_paint(s, -1, 0xdc2626)
	g.tick_count = saved_tick_count
	g.tick_unit = saved_tick_unit
	g.week_start = saved_week
	g.axis_format = saved_axis
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
