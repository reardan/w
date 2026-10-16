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
	if (number > 0):
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
	for i in range(count):
		mm_node* node = d.nodes[i]
		mm_bounds* bounds = s.nodes[i]
		int x = bounds.x + bounds.w / 2
		if (node.shape == 1):
			mm_draw(s, MM_CIRCLE, x - 9, 58, x + 9, 76, 0, c"")
			mm_line(s, x, 76, x, 98, 0)
			mm_line(s, x - 16, 84, x + 16, 84, 0)
			mm_line(s, x, 98, x - 12, 110, 0)
			mm_line(s, x, 98, x + 12, 110, 0)
			mm_text(s, x - strlen(node.label) * 4, 115, node.label)
		else:
			mm_draw(s, MM_BOX, bounds.x, bounds.y, bounds.x + bounds.w, bounds.y + bounds.h, 0, c"")
			mm_text(s, x - strlen(node.label) * 4, 83, node.label)
		mm_line(s, x, 140, x, bottom, 1)
		# Draw outer activation bars first, so nested bars remain visible.
		int depth = 0
		for j in range(d.narrative.length):
			mm_narrative_event* event = d.narrative[j]
			if (event.from_node != i): continue
			if (event.kind == MM_N_DEACTIVATE): depth = depth - 1
			if (event.kind != MM_N_ACTIVATE): continue
			int balance = 1
			int end_y = bottom
			for k in range(j + 1, d.narrative.length):
				mm_narrative_event* later = d.narrative[k]
				if (later.from_node != i): continue
				if (later.kind == MM_N_ACTIVATE): balance = balance + 1
				if (later.kind == MM_N_DEACTIVATE): balance = balance - 1
				if (balance == 0):
					end_y = 170 + k * 70
					break
			int ax = x - 6 + depth * 5
			mm_draw(s, MM_BOX, ax, 170 + j * 70, ax + 12, end_y, 0, c"")
			depth = depth + 1

	int number = 0
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
			number = number + 1
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
			int shown = 0
			if (d.narrative_numbered): shown = number
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
		else if (event.kind == MM_N_BLOCK): mm_text(s, 45, y - 17, event.label)
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

void mm_n_timeline_scene(mm_document* d, mm_scene* s):
	int x = 60
	int index = 0
	char* section = c""
	while (index < d.narrative.length):
		mm_narrative_event* period = d.narrative[index]
		int next = index + 1
		int width = strlen(period.label) * 8 + 40
		while (next < d.narrative.length):
			mm_narrative_event* event = d.narrative[next]
			if (event.kind == MM_N_PERIOD): break
			int needed = strlen(event.label) * 8 + 40
			if (needed > width): width = needed
			next = next + 1
		if (width < 170): width = 170
		if (strcmp(period.section, section) != 0):
			mm_text(s, x, 60, period.section)
			section = period.section
		mm_draw(s, MM_BOX, x, 100, x + width, 145, 1, c"")
		mm_text(s, x + 15, 115, period.label)
		int cx = x + width / 2
		mm_line(s, x - 15, 180, x + width + 35, 180, 0)
		mm_draw(s, MM_CIRCLE, cx - 5, 175, cx + 5, 185, 1, c"")
		mm_line(s, cx, 145, cx, 180, 0)
		s.nodes.push(new mm_bounds(x, 100, width, 45, 0))
		int y = 220
		for i in range(index + 1, next):
			mm_narrative_event* event = d.narrative[i]
			mm_line(s, cx, y - 40, cx, y, 0)
			mm_draw(s, MM_BOX, x, y, x + width, y + 45, 0, c"")
			mm_text(s, x + 15, y + 15, event.label)
			y = y + 80
		x = x + width + 50
		index = next

char* mm_n_date_text(int days):
	int year = 1970
	while (days >= 365 + mm_n_leap(year)):
		days = days - 365 - mm_n_leap(year)
		year = year + 1
	int month = 1
	while (month <= 12):
		int length = 31
		if (month == 4 || month == 6 || month == 9 || month == 11): length = 30
		if (month == 2): length = 28 + mm_n_leap(year)
		if (days < length): break
		days = days - length
		month = month + 1
	string_builder* out = string_new()
	string_append_int(out, year)
	string_append_char(out, '-')
	if (month < 10): string_append_char(out, '0')
	string_append_int(out, month)
	string_append_char(out, '-')
	if (days + 1 < 10): string_append_char(out, '0')
	string_append_int(out, days + 1)
	char* result = out.data
	free(out)
	return result

void mm_n_gantt_scene(mm_document* d, mm_scene* s):
	if (d.narrative.length == 0): return
	int earliest = 4000000
	int latest = 0
	int left = 180
	for mm_narrative_event* task in d.narrative:
		if (task.start < earliest): earliest = task.start
		if (task.end > latest): latest = task.end
		int needed = strlen(task.label) * 8 + 90
		if (needed > left): left = needed
	int span = latest - earliest
	if (span < 1): span = 1
	int unit = 800 / span
	if (unit > 40): unit = 40
	if (unit < 1): unit = 1
	int width = span * unit
	int tick = (span + 7) / 8
	int minimum_tick = (120 + unit - 1) / unit
	if (tick < minimum_tick): tick = minimum_tick
	int height = d.narrative.length * 85 + 160
	int day = 0
	while (day <= span):
		int x = left + day * unit
		mm_line(s, x, 95, x, height, 1)
		char* date = mm_n_date_text(earliest + day)
		mm_text(s, x, 70, date)
		free(date)
		day = day + tick
	char* section = c""
	for i in range(d.narrative.length):
		mm_narrative_event* task = d.narrative[i]
		int y = 135 + i * 85
		if (strcmp(task.section, section) != 0):
			mm_text(s, 30, y - 30, task.section)
			section = task.section
		mm_text(s, 30, y + 9, task.label)
		int x = left + (task.start - earliest) * unit
		int w = (task.end - task.start) * unit
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
		s.nodes.push(new mm_bounds(x, y, w, 30, 0))
	mm_line(s, left, 100, left + width, 100, 0)

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
