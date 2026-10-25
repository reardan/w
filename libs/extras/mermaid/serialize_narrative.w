# Canonical narrative source: sequence, journey, timeline, Gantt and ZenUML.
# Events are written in order, one statement per line. Sequence participants
# are declared where their index falls (boxes up front), numbering is
# restated only where the model's numbers change course, and text is
# entity-encoded where a raw `;` or `#code;` would be read differently.
# Gantt tasks carry their resolved start and end as dates in the chart's own
# dateFormat; ZenUML calls are rebuilt from the derived activations, replies
# and fragment ends.
import libs.extras.mermaid.serialize_common

# A line the narrative reader would take for something other than text.
int mm_sn_line_unsafe(mm_document* d, char* text):
	if (text[0] == 0 || (text[0] & 255) <= 32): return 1
	int length = strlen(text)
	if ((text[length - 1] & 255) <= 32): return 1
	if (mm_n_prefix(text, c"title ") || mm_n_prefix(text, c"%%")): return 1
	if (d.kind != MM_SEQUENCE && d.kind != MM_ZENUML && mm_n_prefix(text, c"section ")): return 1
	if ((mm_n_prefix(text, c"accTitle") || mm_n_prefix(text, c"accDescr")) && mm_id_char(text[8] & 255) == 0): return 1
	return 0

# Raw statement text: one line, no separator.
void mm_sn_raw(mm_serializer* out, mm_document* d, char* text):
	if (index_of(text, c";") >= 0 && d.kind != MM_SEQUENCE): out.failed = 1
	if (d.kind == MM_SEQUENCE):
		# Only entity semicolons survive mm_n_line.
		for i in range(strlen(text)):
			if (text[i] != ';'): continue
			int at = i - 1
			int digits = 0
			int letters = 0
			while (at >= 0 && digits + letters < 12 && isalnum(text[at] & 255)):
				if (isdigit(text[at] & 255)): digits = digits + 1
				else: letters = letters + 1
				at = at - 1
			if (at < 0 || text[at] != '#' || digits + letters == 0 || (digits != 0 && letters != 0)): out.failed = 1
	mm_out_plain(out, text, 0)

# 1 when text[at] starts a `#code;` that mm_n_entities decodes.
int mm_sn_entity_at(char* text, int at):
	int j = at + 1
	int numeric = isdigit(text[j] & 255)
	while (j - at <= 12 && text[j] != 0 && ((numeric && isdigit(text[j] & 255)) || (numeric == 0 && isalpha(text[j] & 255)))): j = j + 1
	return text[j] == ';' && j > at + 1

# Sequence text read through mm_n_entities, trimmed.
void mm_sn_text(mm_serializer* out, mm_document* d, char* text):
	int length = strlen(text)
	if (length > 0 && ((text[0] & 255) <= 32 || (text[length - 1] & 255) <= 32)): out.failed = 1
	if (d.kind != MM_SEQUENCE):
		mm_sn_raw(out, d, text)
		return
	for i in range(length):
		int c = text[i] & 255
		if (c == ';'): mm_out(out, c"#59;")
		else if (c == '#' && mm_sn_entity_at(text, i)): mm_out(out, c"#35;")
		else if (c == 10 || c == 13):
			out.failed = 1
			mm_out_char(out, 32)
		else: mm_out_char(out, c)

# ---- Sequence ----

struct mm_sn_writer:
	mm_serializer* out
	mm_document* d
	int created
	int on
	int counter
	int step
	int numbered

void mm_sn_json(mm_serializer* out, char* text):
	mm_out_char(out, '"')
	for i in range(strlen(text)):
		int c = text[i] & 255
		if (c == '"' || c == 92): mm_out_char(out, 92)
		if (c == 10 || c == 13): out.failed = 1
		mm_out_char(out, c)
	mm_out_char(out, '"')

void mm_sn_declaration(mm_sn_writer* w, int index):
	mm_serializer* out = w.out
	mm_document* d = w.d
	mm_node* n = d.nodes[index]
	if (mm_serialize_is_id(n.id) == 0): out.failed = 1
	list[char*] types = list[char*]{c"participant", c"actor", c"boundary", c"control", c"entity", c"database", c"collections", c"queue"}
	if (n.shape == 1): mm_out(out, c"actor ")
	else: mm_out(out, c"participant ")
	mm_out(out, n.id)
	if (n.shape >= 2 && n.shape <= 7):
		mm_out(out, c"@{ \"type\": \"")
		mm_out(out, types[n.shape])
		mm_out(out, c"\" }")
	else if (n.shape != 0 && n.shape != 1): out.failed = 1
	__w_list_free(cast(__w_list*, types))
	if (strcmp(n.label, n.id) != 0):
		if (n.label[0] == 0 || index_of(n.label, c"@{") >= 0): out.failed = 1
		mm_out(out, c" as ")
		mm_sn_text(out, d, n.label)
	mm_out_line(out)

# links / properties / details of a declared participant.
void mm_sn_extras(mm_sn_writer* w, int index):
	mm_serializer* out = w.out
	mm_node* n = w.d.nodes[index]
	if (n.metadata.length != 0):
		mm_out(out, c"links ")
		mm_out(out, n.id)
		mm_out(out, c": {")
		for i in range(n.metadata.length):
			if (i > 0): mm_out(out, c", ")
			mm_sn_json(out, n.metadata[i].key)
			mm_out(out, c": ")
			mm_sn_json(out, n.metadata[i].value)
		mm_out(out, c"}\n")
	int i = 0
	while (i < n.members.length):
		mm_member* m = n.members[i]
		if (m.method):
			if (starts_with(m.text, c"details: ") == 0): out.failed = 1
			mm_out(out, c"details ")
			mm_out(out, n.id)
			mm_out(out, c": ")
			char* body = m.text + 9
			if (body[0] == 0 || (body[0] & 255) <= 32 || (body[strlen(body) - 1] & 255) <= 32): out.failed = 1
			mm_sn_raw(out, w.d, body)
			mm_out_line(out)
			i = i + 1
			continue
		mm_out(out, c"properties ")
		mm_out(out, n.id)
		mm_out(out, c": {")
		int first = 1
		while (i < n.members.length && n.members[i].method == 0):
			char* text = n.members[i].text
			int colon = index_of(text, c": ")
			if (colon < 0):
				out.failed = 1
				break
			if (first == 0): mm_out(out, c", ")
			first = 0
			char* key = str_copy_range(text, 0, colon)
			mm_sn_json(out, key)
			free(key)
			mm_out(out, c": ")
			mm_sn_json(out, text + colon + 2)
			i = i + 1
		mm_out(out, c"}\n")

int mm_sn_box_of(mm_document* d, int index):
	for i in range(d.boxes.length):
		mm_narrative_event* box = d.boxes[i]
		if (index >= box.from_node && index <= box.to_node): return i
	return -1

# Declares node index (the next one) with its box when it opens one.
void mm_sn_declare(mm_sn_writer* w, int index, int top):
	mm_serializer* out = w.out
	mm_document* d = w.d
	if (index != w.created):
		out.failed = 1
		return
	int b = mm_sn_box_of(d, index)
	if (b < 0):
		mm_sn_declaration(w, index)
		w.created = w.created + 1
		mm_sn_extras(w, index)
		return
	mm_narrative_event* box = d.boxes[b]
	if (top == 0 || box.from_node != index):
		out.failed = 1
		return
	mm_out(out, c"box")
	if (box.value != -1):
		if (box.value < 0): out.failed = 1
		mm_out_char(out, 32)
		mm_serialize_color(out, box.value)
	else if (box.label[0] != 0):
		int split = index_of(box.label, c" ")
		if (split < 0): split = strlen(box.label)
		char* word = str_copy_range(box.label, 0, split)
		if (mm_style_css_color(word) != -2 || mm_n_prefix(box.label, c"rgb")): out.failed = 1
		free(word)
	if (box.label[0] != 0):
		mm_out_char(out, 32)
		mm_sn_raw(out, d, box.label)
	mm_out_line(out)
	for k in range(box.from_node, box.to_node + 1):
		mm_out(out, c"  ")
		mm_sn_declaration(w, k)
	mm_out(out, c"end\n")
	w.created = box.to_node + 1
	for k in range(box.from_node, box.to_node + 1): mm_sn_extras(w, k)

void mm_sn_need(mm_sn_writer* w, int index, int top):
	if (index < 0 || index >= w.d.nodes.length):
		w.out.failed = 1
		return
	if (index < w.created): return
	mm_sn_declare(w, index, top)

# Restates autonumbering before message event index when the model's
# number or on/off state differs from the running state.
void mm_sn_number(mm_sn_writer* w, int index):
	mm_serializer* out = w.out
	mm_document* d = w.d
	mm_narrative_event* e = d.narrative[index]
	if (e.value != w.counter):
		int step = w.step
		for k in range(index + 1, d.narrative.length):
			mm_narrative_event* next = d.narrative[k]
			if (next.kind != MM_N_MESSAGE): continue
			if (next.value > e.value): step = next.value - e.value
			break
		if (e.value < 0 || step <= 0): out.failed = 1
		mm_out(out, c"autonumber ")
		mm_out_int(out, e.value)
		if (step != 1):
			mm_out_char(out, 32)
			mm_out_int(out, step)
		mm_out_line(out)
		w.numbered = 1
		w.on = 1
		w.counter = e.value
		w.step = step
	if (e.start != w.on):
		if (e.start):
			mm_out(out, c"autonumber\n")
			w.numbered = 1
		else: mm_out(out, c"autonumber off\n")
		w.on = e.start
	w.counter = w.counter + w.step

void mm_sn_sequence(mm_serializer* out, mm_document* d):
	mm_out(out, c"sequenceDiagram\n")
	mm_serialize_accessibility(out, d)
	mm_sn_writer w
	w.out = out
	w.d = d
	w.created = 0
	w.on = 0
	w.counter = 1
	w.step = 1
	w.numbered = 0
	# Participants up to the first created one are declared first.
	int first_created = d.nodes.length
	for mm_narrative_event* e in d.narrative:
		if (e.kind == MM_N_CREATE && e.from_node < first_created): first_created = e.from_node
	while (w.created < first_created && out.failed == 0): mm_sn_declare(&w, w.created, 1)
	int depth = 0
	for i in range(d.narrative.length):
		if (out.failed): break
		mm_narrative_event* e = d.narrative[i]
		int k = e.kind
		if (k == MM_N_MESSAGE):
			mm_sn_need(&w, e.from_node, depth == 0)
			mm_sn_need(&w, e.to_node, depth == 0)
			mm_sn_number(&w, i)
			list[char*] solid = list[char*]{c"->", c"->>", c"-x", c"-)", c"<<->>"}
			list[char*] dashed = list[char*]{c"-->", c"-->>", c"--x", c"--)", c"<<-->>"}
			if (e.arrow < 0 || e.arrow > 4 || e.dashed < 0 || e.dashed > 1 || e.central < 0 || e.central > 3 || e.detail[0] != 0): out.failed = 1
			else:
				mm_out(out, d.nodes[e.from_node].id)
				if (e.central & 1): mm_out(out, c"()")
				if (e.dashed): mm_out(out, dashed[e.arrow])
				else: mm_out(out, solid[e.arrow])
				if (e.central & 2): mm_out(out, c"()")
				mm_out(out, d.nodes[e.to_node].id)
				mm_out(out, c": ")
				mm_sn_text(out, d, e.label)
				mm_out_line(out)
			__w_list_free(cast(__w_list*, solid))
			__w_list_free(cast(__w_list*, dashed))
		else if (k == MM_N_NOTE):
			mm_sn_need(&w, e.from_node, depth == 0)
			mm_sn_need(&w, e.to_node, depth == 0)
			if (out.failed): break
			mm_out(out, c"Note ")
			if (e.value == -1): mm_out(out, c"left of ")
			else if (e.value == 1): mm_out(out, c"right of ")
			else if (e.value == 0): mm_out(out, c"over ")
			else: out.failed = 1
			mm_out(out, d.nodes[e.from_node].id)
			if (e.to_node != e.from_node):
				if (e.value != 0): out.failed = 1
				mm_out_char(out, ',')
				mm_out(out, d.nodes[e.to_node].id)
			mm_out(out, c": ")
			mm_sn_text(out, d, e.label)
			mm_out_line(out)
		else if (k == MM_N_BLOCK):
			if (mm_n_prefix(e.label, c"rect ")):
				if (strcmp(e.detail, c"rect") != 0): out.failed = 1
			else if (e.detail[0] != 0): out.failed = 1
			mm_sn_raw(out, d, e.label)
			mm_out_line(out)
			depth = depth + 1
		else if (k == MM_N_BRANCH):
			mm_sn_raw(out, d, e.label)
			mm_out_line(out)
		else if (k == MM_N_END):
			mm_out(out, c"end\n")
			depth = depth - 1
		else if (k == MM_N_ACTIVATE || k == MM_N_DEACTIVATE):
			mm_sn_need(&w, e.from_node, depth == 0)
			if (out.failed): break
			if (k == MM_N_ACTIVATE): mm_out(out, c"activate ")
			else: mm_out(out, c"deactivate ")
			mm_out(out, d.nodes[e.from_node].id)
			mm_out_line(out)
		else if (k == MM_N_CREATE):
			if (e.from_node != w.created || mm_sn_box_of(d, e.from_node) >= 0):
				out.failed = 1
				break
			mm_out(out, c"create ")
			mm_sn_declaration(&w, e.from_node)
			w.created = w.created + 1
			mm_sn_extras(&w, e.from_node)
		else if (k == MM_N_DESTROY):
			if (e.from_node < 0 || e.from_node >= w.created):
				out.failed = 1
				break
			mm_out(out, c"destroy ")
			mm_out(out, d.nodes[e.from_node].id)
			mm_out_line(out)
		else: out.failed = 1
	while (w.created < d.nodes.length && out.failed == 0): mm_sn_declare(&w, w.created, 1)
	if (d.narrative_numbered && w.numbered == 0):
		mm_out(out, c"autonumber\n")
		w.numbered = 1
	if (w.numbered != d.narrative_numbered): out.failed = 1

# ---- Journey and timeline ----

void mm_sn_section(mm_serializer* out, mm_document* d, char** current, char* section):
	if (strcmp(current[0], section) == 0): return
	if (section[0] == 0): out.failed = 1
	mm_out(out, c"section ")
	mm_sn_raw(out, d, section)
	mm_out_line(out)
	current[0] = section

void mm_sn_journey(mm_serializer* out, mm_document* d):
	mm_out(out, c"journey\n")
	mm_serialize_accessibility(out, d)
	char* section = c""
	for mm_narrative_event* e in d.narrative:
		if (e.kind != MM_N_TASK || e.value < 1 || e.value > 5):
			out.failed = 1
			continue
		mm_sn_section(out, d, &section, e.section)
		if (index_of(e.label, c":") >= 0 || mm_sn_line_unsafe(d, e.label)): out.failed = 1
		mm_sn_raw(out, d, e.label)
		mm_out(out, c": ")
		mm_out_int(out, e.value)
		if (e.detail[0] != 0):
			mm_out(out, c": ")
			mm_sn_raw(out, d, e.detail)
		mm_out_line(out)

void mm_sn_timeline(mm_serializer* out, mm_document* d):
	mm_out(out, c"timeline")
	char* direction = mm_config_value(d, c"timeline.direction")
	if (direction != 0):
		mm_out_char(out, 32)
		mm_out(out, direction)
	mm_out_line(out)
	mm_serialize_accessibility(out, d)
	char* section = c""
	int open = 0
	for mm_narrative_event* e in d.narrative:
		if (index_of(e.label, c":") >= 0 || e.label[0] == 0 || (e.label[0] & 255) <= 32 || (e.label[strlen(e.label) - 1] & 255) <= 32): out.failed = 1
		if (e.kind == MM_N_PERIOD):
			if (open): mm_out_line(out)
			mm_sn_section(out, d, &section, e.section)
			if (mm_sn_line_unsafe(d, e.label)): out.failed = 1
			mm_sn_raw(out, d, e.label)
			open = 1
		else if (e.kind == MM_N_EVENT):
			if (strcmp(section, e.section) != 0):
				if (open): mm_out_line(out)
				open = 0
				mm_sn_section(out, d, &section, e.section)
			if (open == 0): mm_out(out, c"  : ")
			else: mm_out(out, c" : ")
			mm_sn_raw(out, d, e.label)
			open = 1
		else: out.failed = 1
	if (open): mm_out_line(out)

# ---- Gantt ----

void mm_sn_digits(string_builder* s, int value, int width):
	string_builder* digits = string_new()
	string_append_int(digits, value)
	for i in range(width - digits.length): string_append_char(s, '0')
	string_append(s, digits.data)
	string_free(digits)

# A chart moment in the dateFormat, or null when the format cannot say it.
char* mm_sn_moment(mm_gantt_settings* g, int value):
	if (value < 0): return 0
	char* format = g.date_format
	int per = mm_n_per_day(g)
	int day = value / per
	int rest = value % per
	int hour = 0
	int minute = 0
	int second = 0
	if (g.minutes == 1):
		hour = rest / 60
		minute = rest % 60
	else if (g.minutes == 2):
		hour = rest / 3600
		minute = rest / 60 % 60
		second = rest % 60
	list[int] civil = mm_n_civil(day)
	int year = civil[0]
	int month = civil[1]
	int date = civil[2]
	int ordinal = civil[3]
	__w_list_free(cast(__w_list*, civil))
	list[char*] months = list[char*]{c"January", c"February", c"March", c"April", c"May", c"June", c"July", c"August", c"September", c"October", c"November", c"December"}
	list[char*] weekdays = list[char*]{c"Sunday", c"Monday", c"Tuesday", c"Wednesday", c"Thursday", c"Friday", c"Saturday"}
	int weekday = (day + 4) % 7
	int pm = 0
	for i in range(strlen(format)):
		if (format[i] == 'A' || format[i] == 'a'): pm = 1
	string_builder* s = string_new()
	int ok = 1
	int i = 0
	while (format[i] != 0 && ok):
		if (format[i] == '['):
			int close = i + index_of(format + i, c"]")
			for k in range(i + 1, close): string_append_char(s, format[k])
			i = close + 1
			continue
		int width = mm_n_format_token(format + i)
		if (width <= 0):
			string_append_char(s, format[i])
			i = i + 1
			continue
		int c = format[i]
		if (c == 'Y'):
			if (width == 4): mm_sn_digits(s, year, 4)
			else:
				if (year < 1969 || year > 2068): ok = 0
				mm_sn_digits(s, year % 100, 2)
		else if (c == 'M' && width >= 3):
			char* name = months[month - 1]
			if (width == 3): string_append_bytes(s, name, 3)
			else: string_append(s, name)
		else if (c == 'M'): mm_sn_digits(s, month, width)
		else if (c == 'D' && format[i + 1] == 'o'):
			string_append_int(s, date)
			if (date % 10 == 1 && date != 11): string_append(s, c"st")
			else if (date % 10 == 2 && date != 12): string_append(s, c"nd")
			else if (date % 10 == 3 && date != 13): string_append(s, c"rd")
			else: string_append(s, c"th")
		else if (c == 'D' && width >= 3): mm_sn_digits(s, ordinal, width - 1)
		else if (c == 'D'): mm_sn_digits(s, date, width)
		else if (c == 'd'):
			if (width == 1): string_append_int(s, weekday)
			else if (width == 4): string_append(s, weekdays[weekday])
			else: string_append_bytes(s, weekdays[weekday], 3)
		else if (c == 'H'): mm_sn_digits(s, hour, width)
		else if (c == 'h'):
			int twelve = hour % 12
			if (twelve == 0): twelve = 12
			if (pm == 0 && hour >= 12): ok = 0
			mm_sn_digits(s, twelve, width)
		else if (c == 'k'):
			int k24 = hour
			if (k24 == 0): k24 = 24
			mm_sn_digits(s, k24, width)
		else if (c == 'm'): mm_sn_digits(s, minute, width)
		else if (c == 's'): mm_sn_digits(s, second, width)
		else if (c == 'S'):
			for k in range(width): string_append_char(s, '0')
		else if (c == 'A' || c == 'a'):
			if (hour >= 12): string_append(s, c"PM")
			else: string_append(s, c"AM")
		else if (c == 'Q'): string_append_int(s, (month - 1) / 3 + 1)
		else if (c == 'X' || c == 'x'):
			int seconds = value * mm_n_unit_seconds(g)
			if (value > 2147483647 / mm_n_unit_seconds(g)): ok = 0
			string_append_int(s, seconds)
			if (c == 'x'): string_append(s, c"000")
		else if (c == 'Z'): string_append_char(s, 'Z')
		else: ok = 0
		i = i + width
	__w_list_free(cast(__w_list*, months))
	__w_list_free(cast(__w_list*, weekdays))
	char* result = strclone(s.data)
	string_free(s)
	if (ok == 0 || mm_n_moment(g, result) != value):
		free(result)
		return 0
	return result

# A day of an excludes/includes list: the dateFormat when it reads back, else ISO.
char* mm_sn_day(mm_gantt_settings* g, int day):
	char* text = mm_sn_moment(g, day * mm_n_per_day(g))
	if (text != 0 && mm_n_day_value(g, text) == day): return text
	if (text != 0): free(text)
	list[int] civil = mm_n_civil(day)
	string_builder* s = string_new()
	mm_sn_digits(s, civil[0], 4)
	string_append_char(s, '-')
	mm_sn_digits(s, civil[1], 2)
	string_append_char(s, '-')
	mm_sn_digits(s, civil[2], 2)
	__w_list_free(cast(__w_list*, civil))
	char* iso = strclone(s.data)
	string_free(s)
	if (mm_n_day_value(g, iso) != day):
		free(iso)
		return 0
	return iso

void mm_sn_moment_out(mm_serializer* out, mm_gantt_settings* g, int value):
	char* text = mm_sn_moment(g, value)
	if (text == 0 || index_of(text, c",") >= 0 || index_of(text, c";") >= 0):
		out.failed = 1
		if (text != 0): free(text)
		return
	mm_out(out, text)
	free(text)

void mm_sn_days(mm_serializer* out, mm_gantt_settings* g, list[int] days):
	for int day in days:
		char* text = mm_sn_day(g, day)
		if (text == 0):
			out.failed = 1
			continue
		mm_out_char(out, 32)
		mm_out(out, text)
		free(text)

int mm_sn_gantt_label_unsafe(char* label):
	list[char*] words = list[char*]{c"dateFormat ", c"axisFormat ", c"excludes ", c"includes ", c"weekend ", c"todayMarker ", c"click ", c"tickInterval ", c"weekday "}
	int bad = strcmp(label, c"inclusiveEndDates") == 0 || strcmp(label, c"topAxis") == 0
	for char* word in words:
		if (mm_n_prefix(label, word)): bad = 1
	__w_list_free(cast(__w_list*, words))
	return bad

void mm_sn_gantt(mm_serializer* out, mm_document* d):
	mm_gantt_settings* g = d.gantt
	mm_out(out, c"gantt\n")
	mm_serialize_accessibility(out, d)
	if (g == 0):
		if (d.narrative.length != 0): out.failed = 1
		return
	list[char*] names = list[char*]{c"sunday", c"monday", c"tuesday", c"wednesday", c"thursday", c"friday", c"saturday"}
	list[char*] units = list[char*]{c"millisecond", c"second", c"minute", c"hour", c"day", c"week", c"month"}
	if (strcmp(g.date_format, c"YYYY-MM-DD") != 0):
		mm_out(out, c"dateFormat ")
		mm_sn_raw(out, d, g.date_format)
		mm_out_line(out)
	if (g.minutes != mm_n_format_kind(g.date_format) && g.promoted == 0): out.failed = 1
	if (g.inclusive): mm_out(out, c"inclusiveEndDates\n")
	if (g.axis_format[0] != 0):
		mm_out(out, c"axisFormat ")
		mm_sn_raw(out, d, g.axis_format)
		mm_out_line(out)
	if (g.weekend_start == 5): mm_out(out, c"weekend friday\n")
	else if (g.weekend_start != 6): out.failed = 1
	int weekend_bits = 0
	if (g.weekends): weekend_bits = (1 << g.weekend_start) | (1 << ((g.weekend_start + 1) % 7))
	int explicit_days = g.weekday_mask & (127 - weekend_bits)
	if (g.weekday_mask < 0 || g.weekday_mask > 127 || (g.weekday_mask & weekend_bits) != weekend_bits): out.failed = 1
	if (g.weekends || explicit_days != 0 || g.excluded.length != 0):
		mm_out(out, c"excludes")
		if (g.weekends): mm_out(out, c" weekends")
		for k in range(7):
			if ((explicit_days >> k) & 1):
				mm_out_char(out, 32)
				mm_out(out, names[k])
		# Day numbers are kept in days even in minute charts.
		mm_sn_days(out, g, g.excluded)
		mm_out_line(out)
	if (g.included.length != 0):
		mm_out(out, c"includes")
		mm_sn_days(out, g, g.included)
		mm_out_line(out)
	if (g.today >= 0):
		mm_out(out, c"todayMarker ")
		char* text = mm_sn_moment(g, g.today)
		if (text == 0 && g.minutes == 0): text = mm_sn_day(g, g.today)
		if (text == 0): out.failed = 1
		else:
			mm_out(out, text)
			free(text)
		mm_out_line(out)
	if (g.tick_count != 0):
		if (g.tick_unit < 1 || g.tick_unit > 7): out.failed = 1
		else:
			mm_out(out, c"tickInterval ")
			mm_out_int(out, g.tick_count)
			mm_out(out, units[g.tick_unit - 1])
			mm_out_line(out)
	if (g.week_start != 0):
		if (g.week_start < 0 || g.week_start > 6): out.failed = 1
		else:
			mm_out(out, c"weekday ")
			mm_out(out, names[g.week_start])
			mm_out_line(out)
	if (g.top_axis): mm_out(out, c"topAxis\n")
	__w_list_free(cast(__w_list*, names))
	__w_list_free(cast(__w_list*, units))
	# A promoted chart reads its tasks in days; one sub-day duration promotes it.
	int per = mm_n_per_day(g)
	char* section = c""
	list[char*] statuses = list[char*]{c"done", c"active", c"crit", c"milestone", c"vert"}
	int promoted_written = 0
	mm_narrative_event* previous = 0
	for mm_narrative_event* e in d.narrative:
		if (e.kind != MM_N_TASK || e.value < 0 || e.value > 31 || e.start < 0 || e.end < e.start):
			out.failed = 1
			continue
		mm_sn_section(out, d, &section, e.section)
		if (index_of(e.label, c":") >= 0 || mm_sn_line_unsafe(d, e.label) || mm_sn_gantt_label_unsafe(e.label)): out.failed = 1
		mm_sn_raw(out, d, e.label)
		mm_out(out, c" :")
		int comma = 0
		for k in range(5):
			if ((e.value >> k) & 1):
				if (comma): mm_out_char(out, ',')
				mm_out_char(out, 32)
				mm_out(out, statuses[k])
				comma = 1
		if (e.detail[0] != 0):
			if (comma): mm_out_char(out, ',')
			if (mm_serialize_is_id(e.detail) == 0 || mm_n_is_span(e.detail) || mm_n_moment(g, e.detail) >= 0): out.failed = 1
			mm_out_char(out, 32)
			mm_out(out, e.detail)
			comma = 1
		if (comma): mm_out_char(out, ',')
		mm_out_char(out, 32)
		# A task starting where the previous one ends names only its end,
		# which also says a start the dateFormat cannot.
		int follows = 0
		if (previous != 0 && previous.end == e.start):
			char* probe = mm_sn_moment(g, e.start)
			follows = g.promoted || probe == 0
			if (probe != 0): free(probe)
		if (g.promoted):
			mm_gantt_settings day_chart
			day_chart.date_format = g.date_format
			day_chart.minutes = 0
			if (follows == 0):
				if (e.start % 1440 != 0): out.failed = 1
				mm_sn_moment_out(out, &day_chart, e.start / 1440)
				mm_out(out, c", ")
			if (e.end % 1440 == 0):
				int finish = e.end / 1440
				if (g.inclusive): finish = finish - 1
				mm_sn_moment_out(out, &day_chart, finish)
			else:
				int duration = mm_n_working_units(g, e.start, e.end)
				if (mm_n_finish(g, e.start, duration) != e.end): out.failed = 1
				mm_out_int(out, duration)
				mm_out_char(out, 'm')
				promoted_written = 1
		else:
			if (follows == 0):
				mm_sn_moment_out(out, g, e.start)
				mm_out(out, c", ")
			int finish = e.end
			if (g.inclusive): finish = finish - per
			mm_sn_moment_out(out, g, finish)
		previous = e
		mm_out_line(out)
	if (g.promoted && promoted_written == 0): out.failed = 1
	__w_list_free(cast(__w_list*, statuses))
	for mm_node* n in d.nodes:
		if (n.metadata.length == 0): continue
		mm_property* href = n.metadata[0]
		if (n.metadata.length != 1 || strcmp(href.key, c"href") != 0 || index_of(href.value, c"\"") >= 0): out.failed = 1
		mm_out(out, c"click ")
		mm_out(out, n.id)
		mm_out(out, c" href \"")
		mm_sn_raw(out, d, href.value)
		mm_out(out, c"\"\n")

# ---- ZenUML ----

void mm_sn_zenuml(mm_serializer* out, mm_document* d):
	out.failed = 1

void mm_serialize_narrative_body(mm_serializer* out, mm_document* d, int variant):
	if (d.edges.length != 0 || d.notes.length != 0 || d.data != 0 || d.railroad != 0 || d.style_definitions.length != 0 || strcmp(d.direction, c"TB") != 0): out.failed = 1
	if (d.kind != MM_SEQUENCE && d.boxes.length != 0): out.failed = 1
	if (d.kind == MM_SEQUENCE): mm_sn_sequence(out, d)
	else if (d.kind == MM_JOURNEY): mm_sn_journey(out, d)
	else if (d.kind == MM_TIMELINE): mm_sn_timeline(out, d)
	else if (d.kind == MM_GANTT): mm_sn_gantt(out, d)
	else: mm_sn_zenuml(out, d)
