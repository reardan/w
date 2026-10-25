# Lifelines, chronological event columns, scored journeys and a calendar axis.
import libs.extras.mermaid.narrative
import libs.extras.mermaid.scene
import libs.extras.mermaid.style_render
import libs.extras.mermaid.text

# A label at (x,y): plain text, or the shared rich layout (Markdown strings,
# `<br>`) when it has markup. Returns the height drawn.
int mm_n_text(mm_scene* s, int x, int y, char* label):
	if (mm_text_rich(label)): return mm_label(s, x, y, label, 0, 0)
	mm_text(s, x, y, label)
	return 18

# Rendered width and height of a label in px.
int mm_n_text_width(char* label):
	if (mm_text_rich(label) == 0): return strlen(label) * 8
	mm_text_block* b = mm_text_layout(label, 0)
	int width = b.width
	mm_text_block_free(b)
	return width

int mm_n_text_height(char* label):
	if (mm_text_rich(label) == 0): return 18
	mm_text_block* b = mm_text_layout(label, 0)
	int height = b.height
	mm_text_block_free(b)
	return height

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
		int actor_start = s.items.length
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
		mm_style_role(s, actor_start, MM_ROLE_ACTOR, i)
		int line_start = s.items.length
		mm_line(s, x, 140 + shift, x, end_y, 1)
		mm_style_role(s, line_start, MM_ROLE_ACTOR_LINE, i)
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
			int shown = -1
			if (event.start): shown = event.value
			char* label = mm_n_label(event, shown)
			# Rich labels (Markdown strings, <br>) keep their numbering as a prefix run.
			int rich = shown < 0 && mm_text_rich(event.label)
			int lift = 0
			if (rich): lift = mm_n_text_height(event.label) - 18
			if (x == to):
				if (rich): mm_n_text(s, x + 8, y - 23 - lift, event.label)
				else: mm_text(s, x + 8, y - 23, label)
			else:
				int label_width = strlen(label) * 8
				if (rich): label_width = mm_n_text_width(event.label)
				int label_x = (x + to) / 2 - label_width / 2
				if (label_x < 10): label_x = 10
				if (rich): mm_n_text(s, label_x, y - 23 - lift, event.label)
				else: mm_text(s, label_x, y - 23, label)
			free(label)
			mm_style_role(s, event_start, MM_ROLE_SIGNAL, 0)
		else if (event.kind == MM_N_NOTE):
			int w = mm_n_text_width(event.label) + 24
			int extra = mm_n_text_height(event.label) - 18
			int nx = (x + to) / 2 - w / 2
			if (event.value < 0): nx = x - w - 15
			if (event.value > 0): nx = x + 15
			if (nx < 10): nx = 10
			mm_draw(s, MM_BOX, nx, y - 20 - extra / 2, nx + w, y + 20 + extra - extra / 2, 0, c"")
			mm_n_text(s, nx + 12, y - 8 - extra / 2, event.label)
			mm_style_role(s, event_start, MM_ROLE_NOTE, 0)
		else if (event.kind == MM_N_BLOCK && strcmp(event.detail, c"rect") != 0): mm_text(s, 45, y - 17, event.label)
		else if (event.kind == MM_N_BRANCH):
			mm_line(s, 35, y - 20, right + 10, y - 20, 1)
			mm_text(s, 45, y - 12, event.label)

void mm_n_journey_scene(mm_document* d, mm_scene* s):
	int x = 110
	int previous_x = -1
	int previous_y = 0
	char* section = c""
	for i in range(d.narrative.length):
		mm_narrative_event* event = d.narrative[i]
		int w = mm_n_text_width(event.label) + 40
		int actors_width = strlen(event.detail) * 8 + 30
		if (actors_width > w): w = actors_width
		if (w < 180): w = 180
		if (strcmp(event.section, section) != 0):
			mm_text(s, x, 60, event.section)
			section = event.section
		mm_draw(s, MM_BOX, x, 100, x + w - 20, 150, 1, c"")
		mm_n_text(s, x + 10, 117 - (mm_n_text_height(event.label) - 18) / 2, event.label)
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
		mm_n_timeline_text(s, x + 15, 115, period.label, period_lines)
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
			mm_n_timeline_text(s, x + 15, y + 15, event.label, lines)
			mm_n_lines_free(lines)
			y = y + height + 35
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

void mm_n_gantt_scene(mm_document* d, mm_scene* s):
	if (d.narrative.length == 0): return
	mm_gantt_settings* g = mm_n_gantt_settings(d)
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
	int height = d.narrative.length * 85 + 160
	mm_n_gantt_shading(g, axis, s, latest, height)
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
		int x = mm_n_axis_x(axis, value)
		mm_line(s, x, 95, x, height, 1)
		mm_style_role(s, s.items.length - 1, MM_ROLE_GRID, 0)
		char* date = mm_n_axis_label(g, value)
		mm_text(s, x, 70, date)
		free(date)
		if (value > latest - tick): break
		value = value + tick
	char* section = c""
	for i in range(d.narrative.length):
		mm_narrative_event* task = d.narrative[i]
		int y = 135 + i * 85
		if (strcmp(task.section, section) != 0):
			mm_text(s, 30, y - 30, task.section)
			section = task.section
		mm_text(s, 30, y + 9, task.label)
		int x = mm_n_axis_x(axis, task.start)
		int w = mm_n_axis_x(axis, task.end) - x
		int task_start = s.items.length
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
		int role = MM_ROLE_TASK
		if ((task.value & 2) != 0): role = MM_ROLE_TASK_ACTIVE
		if ((task.value & 1) != 0): role = MM_ROLE_TASK_DONE
		if ((task.value & 4) != 0): role = MM_ROLE_TASK_CRIT
		mm_style_role(s, task_start, role, i)
		s.nodes.push(new mm_bounds(x, y, w, 30, 0))
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
