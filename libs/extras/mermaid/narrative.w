# Native ordered Mermaid grammars. Unsupported syntax is diagnosed, never ignored.
import libs.extras.mermaid.parse_common

const int MM_N_MESSAGE = 1
const int MM_N_NOTE = 2
const int MM_N_BLOCK = 3
const int MM_N_BRANCH = 4
const int MM_N_END = 5
const int MM_N_ACTIVATE = 6
const int MM_N_DEACTIVATE = 7
const int MM_N_TASK = 8
const int MM_N_PERIOD = 9
const int MM_N_EVENT = 10

char* mm_n_trim(char* text):
	int a = 0
	int b = strlen(text)
	while (a < b && (text[a] == 32 || text[a] == 9 || text[a] == 13)): a = a + 1
	while (b > a && (text[b - 1] == 32 || text[b - 1] == 9 || text[b - 1] == 13)): b = b - 1
	return str_copy_range(text, a, b)

char* mm_n_line(mm_parser* p):
	int start = p.pos
	while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != ';'): p.pos = p.pos + 1
	char* raw = str_copy_range(p.doc.source, start, p.pos)
	char* result = mm_n_trim(raw)
	free(raw)
	return result

char* mm_n_part(char* text, int start, int end):
	char* raw = str_copy_range(text, start, end)
	char* result = mm_n_trim(raw)
	free(raw)
	return result

int mm_n_prefix(char* text, char* prefix):
	int n = strlen(prefix)
	if (strlen(text) < n): return 0
	for i in range(n):
		if (text[i] != prefix[i]): return 0
	return 1

int mm_n_number(char* text, int max_value):
	if (text[0] == 0): return -1
	int value = 0
	int i = 0
	while (text[i] != 0):
		if (text[i] < '0' || text[i] > '9'): return -1
		int digit = text[i] - '0'
		if (value > (max_value - digit) / 10): return -1
		value = value * 10 + digit
		if (value > max_value): return -1
		i = i + 1
	return value

int mm_n_actor(mm_parser* p, char* name):
	int n = strlen(name)
	if (n == 0):
		mm_error(p.doc, p.pos, c"expected participant identifier")
		return -1
	for i in range(n):
		if (mm_id_char(name[i] & 255) == 0):
			mm_error(p.doc, p.pos, c"unsupported participant identifier")
			return -1
	return mm_add_node(p.doc, name, p.pos)

mm_narrative_event* mm_n_event(mm_parser* p, int kind, char* label, char* section):
	if (p.doc.narrative.length >= MM_MAX_ITEMS):
		mm_error(p.doc, p.pos, c"narrative event limit exceeded")
		return 0
	mm_narrative_event* event = new mm_narrative_event()
	event.kind = kind
	event.from_node = -1
	event.to_node = -1
	event.label = strclone(label)
	event.detail = strclone(c"")
	event.section = strclone(section)
	event.end = -1
	p.doc.narrative.push(event)
	return event

void mm_n_declare(mm_parser* p, char* text, int actor):
	int split = index_of(text, c" as ")
	char* id
	if (split >= 0): id = mm_n_part(text, 0, split)
	else: id = mm_n_trim(text)
	int index = mm_n_actor(p, id)
	free(id)
	if (index < 0): return
	mm_node* node = p.doc.nodes[index]
	node.shape = actor
	if (split >= 0):
		free(node.label)
		node.label = mm_n_part(text, split + 4, strlen(text))
		if (node.label[0] == 0): mm_error(p.doc, p.pos, c"empty participant alias")

void mm_n_activation(mm_parser* p, int actor, int active):
	if (actor < 0): return
	int balance = 0
	for mm_narrative_event* event in p.doc.narrative:
		if (event.from_node == actor && event.kind == MM_N_ACTIVATE): balance = balance + 1
		if (event.from_node == actor && event.kind == MM_N_DEACTIVATE): balance = balance - 1
	if (active == 0 && balance == 0):
		mm_error(p.doc, p.pos, c"cannot deactivate an inactive participant")
		return
	int kind = MM_N_DEACTIVATE
	if (active): kind = MM_N_ACTIVATE
	mm_narrative_event* event = mm_n_event(p, kind, c"", c"")
	if (event != 0): event.from_node = actor

void mm_n_message(mm_parser* p, char* text, int zen):
	int colon = index_of(text, c":")
	if (colon < 0):
		mm_error(p.doc, p.pos, c"message requires a colon and label")
		return
	int at = 0
	while (mm_id_char(text[at] & 255)): at = at + 1
	char* left = mm_n_part(text, 0, at)
	while (text[at] == 32 || text[at] == 9): at = at + 1
	char* arrow = strclone(c"")
	list[char*] arrows = list[char*]{c"<<-->>", c"<<->>", c"-->>", c"->>", c"-->", c"--x", c"--)", c"->", c"-x", c"-)"}
	for char* candidate in arrows:
		if (mm_n_prefix(text + at, candidate)):
			free(arrow)
			arrow = strclone(candidate)
			at = at + strlen(candidate)
			break
	__w_list_free(cast(__w_list*, arrows))
	int type = -1
	int dashed = 0
	if (strcmp(arrow, c"->") == 0 || strcmp(arrow, c"-->") == 0): type = 0
	if (strcmp(arrow, c"->>") == 0 || strcmp(arrow, c"-->>") == 0): type = 1
	if (strcmp(arrow, c"-x") == 0 || strcmp(arrow, c"--x") == 0): type = 2
	if (strcmp(arrow, c"-)") == 0 || strcmp(arrow, c"--)") == 0): type = 3
	if (strcmp(arrow, c"<<->>") == 0 || strcmp(arrow, c"<<-->>") == 0): type = 4
	if (index_of(arrow, c"--") >= 0): dashed = 1
	if (zen && strcmp(arrow, c"->") == 0): type = 3
	if (zen && strcmp(arrow, c"->") != 0): type = -1
	free(arrow)
	int activate = 0
	if (text[at] == '+'):
		activate = 1
		at = at + 1
	else if (text[at] == '-'):
		activate = -1
		at = at + 1
	char* right = mm_n_part(text, at, colon)
	int from = mm_n_actor(p, left)
	int to = mm_n_actor(p, right)
	free(left)
	free(right)
	if (type < 0): mm_error(p.doc, p.pos, c"unsupported sequence message arrow")
	if (p.doc.error != 0): return
	char* label = mm_n_part(text, colon + 1, strlen(text))
	mm_narrative_event* event = mm_n_event(p, MM_N_MESSAGE, label, c"")
	free(label)
	if (event == 0): return
	event.from_node = from
	event.to_node = to
	event.arrow = type
	event.dashed = dashed
	if (activate == 1): mm_n_activation(p, to, 1)
	if (activate == -1): mm_n_activation(p, from, 0)

void mm_n_note(mm_parser* p, char* text):
	int colon = index_of(text, c":")
	if (colon < 0):
		mm_error(p.doc, p.pos, c"note requires a colon and text")
		return
	int start = 0
	int side = 0
	if (mm_n_prefix(text, c"over ")): start = 5
	else if (mm_n_prefix(text, c"left of ")):
		start = 8
		side = -1
	else if (mm_n_prefix(text, c"right of ")):
		start = 9
		side = 1
	else:
		mm_error(p.doc, p.pos, c"expected note over, left of or right of")
		return
	char* actors = mm_n_part(text, start, colon)
	int comma = index_of(actors, c",")
	char* left = mm_n_part(actors, 0, strlen(actors))
	char* right = strclone(left)
	if (comma >= 0):
		free(left)
		free(right)
		left = mm_n_part(actors, 0, comma)
		right = mm_n_part(actors, comma + 1, strlen(actors))
	if (side != 0 && comma >= 0): mm_error(p.doc, p.pos, c"side notes take one participant")
	int from = mm_n_actor(p, left)
	int to = mm_n_actor(p, right)
	free(left)
	free(right)
	free(actors)
	char* label = mm_n_part(text, colon + 1, strlen(text))
	mm_narrative_event* event = mm_n_event(p, MM_N_NOTE, label, c"")
	free(label)
	if (event == 0): return
	event.from_node = from
	event.to_node = to
	event.value = side

void mm_n_sequence(mm_parser* p, char* text, list[int] blocks):
	if (mm_n_prefix(text, c"participant ")): mm_n_declare(p, text + 12, 0)
	else if (mm_n_prefix(text, c"actor ")): mm_n_declare(p, text + 6, 1)
	else if (strcmp(text, c"autonumber") == 0): p.doc.narrative_numbered = 1
	else if (mm_n_prefix(text, c"activate ") || mm_n_prefix(text, c"deactivate ")):
		int active = mm_n_prefix(text, c"activate ")
		int start = 11
		if (active): start = 9
		char* id = mm_n_trim(text + start)
		mm_n_activation(p, mm_n_actor(p, id), active)
		free(id)
	else if (mm_n_prefix(text, c"Note ") || mm_n_prefix(text, c"note ")): mm_n_note(p, text + 5)
	else if (strcmp(text, c"end") == 0):
		if (blocks.length == 0): mm_error(p.doc, p.pos, c"unmatched sequence end")
		else:
			int index = blocks.pop()
			mm_narrative_event* begin = p.doc.narrative[index]
			begin.end = p.doc.narrative.length
			mm_n_event(p, MM_N_END, c"", c"")
	else if ((strcmp(text, c"else") == 0 || mm_n_prefix(text, c"else ")) || mm_n_prefix(text, c"and ") || mm_n_prefix(text, c"option ")):
		if (blocks.length == 0): mm_error(p.doc, p.pos, c"branch outside sequence fragment")
		else:
			mm_narrative_event* begin = p.doc.narrative[blocks[blocks.length - 1]]
			int valid = ((strcmp(text, c"else") == 0 || mm_n_prefix(text, c"else ")) && mm_n_prefix(begin.label, c"alt ")) || (mm_n_prefix(text, c"and ") && mm_n_prefix(begin.label, c"par ")) || (mm_n_prefix(text, c"option ") && mm_n_prefix(begin.label, c"critical "))
			if (valid == 0): mm_error(p.doc, p.pos, c"branch does not match sequence fragment")
			mm_n_event(p, MM_N_BRANCH, text, c"")
	else if (mm_n_prefix(text, c"loop ") || mm_n_prefix(text, c"alt ") || mm_n_prefix(text, c"opt ") || mm_n_prefix(text, c"par ") || mm_n_prefix(text, c"critical ") || mm_n_prefix(text, c"break ")):
		if (blocks.length >= 32): mm_error(p.doc, p.pos, c"sequence nesting limit exceeded")
		else:
			int index = p.doc.narrative.length
			if (mm_n_event(p, MM_N_BLOCK, text, c"") != 0): blocks.push(index)
	else: mm_n_message(p, text, 0)

void mm_n_journey(mm_parser* p, char* text, char* section):
	int colon = index_of(text, c":")
	if (colon < 1):
		mm_error(p.doc, p.pos, c"journey task requires label : score : actors")
		return
	char* label = mm_n_part(text, 0, colon)
	char* tail = mm_n_trim(text + colon + 1)
	int next = index_of(tail, c":")
	char* score = mm_n_part(tail, 0, strlen(tail))
	if (next >= 0):
		free(score)
		score = mm_n_part(tail, 0, next)
	int value = mm_n_number(score, 5)
	if (value < 1): mm_error(p.doc, p.pos, c"journey score must be an integer from 1 to 5")
	mm_narrative_event* event = mm_n_event(p, MM_N_TASK, label, section)
	if (event != 0):
		event.value = value
		if (next >= 0):
			free(event.detail)
			event.detail = mm_n_trim(tail + next + 1)
			int start = 0
			int length = strlen(event.detail)
			for i in range(length + 1):
				if (i == length || event.detail[i] == ','):
					char* name = mm_n_part(event.detail, start, i)
					if (name[0] == 0): mm_error(p.doc, p.pos, c"empty journey actor")
					else: mm_add_node(p.doc, name, p.pos)
					free(name)
					start = i + 1
					if (p.doc.error != 0): break
	free(label)
	free(tail)
	free(score)

void mm_n_timeline(mm_parser* p, char* text, char* section):
	int colon = index_of(text, c":")
	int end = strlen(text)
	if (colon >= 0): end = colon
	char* label = mm_n_part(text, 0, end)
	if (label[0] != 0): mm_n_event(p, MM_N_PERIOD, label, section)
	else if (p.doc.narrative.length == 0): mm_error(p.doc, p.pos, c"timeline event needs a preceding period")
	free(label)
	if (colon < 0): return
	int start = colon + 1
	int length = strlen(text)
	for i in range(start, length + 1):
		if (i == length || text[i] == ':'):
			char* event_text = mm_n_part(text, start, i)
			if (event_text[0] == 0): mm_error(p.doc, p.pos, c"empty timeline event")
			else: mm_n_event(p, MM_N_EVENT, event_text, section)
			free(event_text)
			start = i + 1
			if (p.doc.error != 0): break

int mm_n_leap(int year):
	return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)

int mm_n_date(char* text):
	if (strlen(text) != 10 || text[4] != '-' || text[7] != '-'): return -1
	char* year_text = str_copy_range(text, 0, 4)
	char* month_text = str_copy_range(text, 5, 7)
	char* day_text = str_copy_range(text, 8, 10)
	int year = mm_n_number(year_text, 9999)
	int month = mm_n_number(month_text, 12)
	int day = mm_n_number(day_text, 31)
	free(year_text)
	free(month_text)
	free(day_text)
	if (year < 1970 || month < 1 || day < 1): return -1
	int days = 0
	for y in range(1970, year): days = days + 365 + mm_n_leap(y)
	for m in range(1, month + 1):
		int length = 31
		if (m == 4 || m == 6 || m == 9 || m == 11): length = 30
		if (m == 2): length = 28 + mm_n_leap(year)
		if (m == month):
			if (day > length): return -1
		else: days = days + length
	return days + day - 1

int mm_n_duration(char* text):
	int length = strlen(text)
	if (length < 2): return -1
	int multiplier = 1
	if (text[length - 1] == 'w'): multiplier = 7
	else if (text[length - 1] != 'd'): return -1
	char* number = str_copy_range(text, 0, length - 1)
	int result = mm_n_number(number, 365000 / multiplier)
	free(number)
	if (result <= 0): return -1
	return result * multiplier

void mm_n_gantt(mm_parser* p, char* text, char* section):
	int colon = index_of(text, c":")
	if (colon < 1):
		mm_error(p.doc, p.pos, c"unsupported Gantt directive or missing task colon")
		return
	char* label = mm_n_part(text, 0, colon)
	list[char*] fields = new list[char*]
	int start = colon + 1
	int length = strlen(text)
	for i in range(start, length + 1):
		if (i == length || text[i] == ','):
			if (fields.length >= 16):
				mm_error(p.doc, p.pos, c"Gantt task field limit exceeded")
				break
			fields.push(mm_n_part(text, start, i))
			start = i + 1
	int at = 0
	int status = 0
	while (at < fields.length):
		char* field = fields[at]
		if (strcmp(field, c"done") == 0): status = status | 1
		else if (strcmp(field, c"active") == 0): status = status | 2
		else if (strcmp(field, c"crit") == 0): status = status | 4
		else if (strcmp(field, c"milestone") == 0): status = status | 8
		else: break
		at = at + 1
	char* id = strclone(c"")
	if (at < fields.length && mm_n_date(fields[at]) < 0 && mm_n_duration(fields[at]) < 0 && mm_n_prefix(fields[at], c"after ") == 0):
		free(id)
		id = strclone(fields[at])
		if (mm_n_actor(p, id) >= 0):
			for mm_narrative_event* previous in p.doc.narrative:
				if (strcmp(previous.detail, id) == 0): mm_error(p.doc, p.pos, c"duplicate Gantt task id")
		at = at + 1
	int begin = -1
	int finish = -1
	if (at < fields.length):
		if (fields.length - at == 1 && p.doc.narrative.length > 0):
			# A sole date/duration denotes the end of a sequential task.
			mm_narrative_event* previous = p.doc.narrative[p.doc.narrative.length - 1]
			begin = previous.end
		else:
			begin = mm_n_date(fields[at])
			if (begin >= 0): at = at + 1
			else if (mm_n_prefix(fields[at], c"after ")):
				char* dependency = fields[at] + 6
				for mm_narrative_event* previous in p.doc.narrative:
					if (previous.detail[0] != 0 && strcmp(previous.detail, dependency) == 0): begin = previous.end
				if (begin < 0): mm_error(p.doc, p.pos, c"Gantt dependency must name an earlier task")
				at = at + 1
			else if (p.doc.narrative.length > 0):
				mm_narrative_event* previous = p.doc.narrative[p.doc.narrative.length - 1]
				begin = previous.end

	if (at < fields.length):
		finish = mm_n_date(fields[at])
		if (finish < 0):
			int duration = mm_n_duration(fields[at])
			if (duration > 0 && begin >= 0): finish = begin + duration
			if ((status & 8) != 0 && strcmp(fields[at], c"0d") == 0): finish = begin
		at = at + 1
	if (begin < 0 || finish < begin || at != fields.length): mm_error(p.doc, p.pos, c"Gantt requires YYYY-MM-DD start (or earlier dependency) and end date or positive d/w duration")
	if (p.doc.error == 0):
		mm_narrative_event* event = mm_n_event(p, MM_N_TASK, label, section)
		if (event != 0):
			event.start = begin
			event.end = finish
			event.value = status
			free(event.detail)
			event.detail = strclone(id)
	free(id)
	free(label)
	for char* field in fields: free(field)
	__w_list_free(cast(__w_list*, fields))

int mm_n_method(char* text):
	int i = 0
	while (mm_id_char(text[i] & 255)): i = i + 1
	if (i == 0): return 0
	if (text[i] == 0): return 1
	if (text[i] != '('): return 0
	int depth = 0
	int quote = 0
	while (text[i] != 0):
		int c = text[i]
		if (quote != 0):
			if (c == quote): quote = 0
		else if (c == '"' || c == 39): quote = c
		else if (c == '('): depth = depth + 1
		else if (c == ')'):
			depth = depth - 1
			if (depth == 0): return text[i + 1] == 0
		i = i + 1
	return 0

# ZenUML sync calls are nested by braces and reuse the native lifeline model.
void mm_n_zen(mm_parser* p, char* text, list[int] blocks, list[int] callers):
	if (mm_n_prefix(text, c"//")): return
	if (mm_n_prefix(text, c"} else")):
		if (blocks.length == 0): mm_error(p.doc, p.pos, c"ZenUML else outside conditional")
		else:
			mm_narrative_event* begin = p.doc.narrative[blocks[blocks.length - 1]]
			if (begin.kind != MM_N_BLOCK || mm_n_prefix(begin.label, c"if") == 0 || text[strlen(text) - 1] != '{'): mm_error(p.doc, p.pos, c"ZenUML else requires an open conditional and brace")
			else:
				char* label = mm_n_part(text, 2, strlen(text) - 1)
				mm_n_event(p, MM_N_BRANCH, label, c"")
				free(label)
		return
	if (strcmp(text, c"}") == 0):
		if (blocks.length == 0): mm_error(p.doc, p.pos, c"unmatched ZenUML closing brace")
		else:
			int index = blocks.pop()
			mm_narrative_event* begin = p.doc.narrative[index]
			begin.end = p.doc.narrative.length
			int actor = callers.pop()
			if (actor >= 0): mm_n_activation(p, actor, 0)
			else: mm_n_event(p, MM_N_END, c"", c"")
		return
	if (mm_n_prefix(text, c"@Actor ")):
		mm_n_declare(p, text + 7, 1)
		return
	if (mm_n_prefix(text, c"return ")):
		int actor = -1
		int caller = -1
		for i in range(blocks.length):
			mm_narrative_event* begin = p.doc.narrative[blocks[i]]
			if (begin.kind == MM_N_MESSAGE):
				actor = begin.to_node
				caller = begin.from_node
		if (actor < 0 || caller < 0): mm_error(p.doc, p.pos, c"ZenUML return requires a nested synchronous call")
		else:
			mm_narrative_event* event = mm_n_event(p, MM_N_MESSAGE, text + 7, c"")
			if (event != 0):
				event.from_node = actor
				event.to_node = caller
				event.dashed = 1
				event.arrow = 1
		return
	int length = strlen(text)
	int nested = length > 0 && text[length - 1] == '{'
	if (nested && blocks.length >= 32):
		mm_error(p.doc, p.pos, c"ZenUML nesting limit exceeded")
		return
	if (mm_n_prefix(text, c"if(") || mm_n_prefix(text, c"if (") || mm_n_prefix(text, c"while(") || mm_n_prefix(text, c"while (") || mm_n_prefix(text, c"for(") || mm_n_prefix(text, c"for (") || mm_n_prefix(text, c"loop ") || strcmp(text, c"opt {") == 0 || strcmp(text, c"par {") == 0):
		if (nested == 0): mm_error(p.doc, p.pos, c"ZenUML fragment requires opening brace")
		else:
			char* label = mm_n_part(text, 0, length - 1)
			int index = p.doc.narrative.length
			if (mm_n_event(p, MM_N_BLOCK, label, c"") != 0):
				blocks.push(index)
				callers.push(-1)
			free(label)
		return
	if (index_of(text, c"->") >= 0 && index_of(text, c":") >= 0):
		mm_n_message(p, text, 1)
		return
	int dot = index_of(text, c".")
	if (dot < 0):
		mm_n_declare(p, text, 0)
		return
	int target_start = 0
	int explicit_sender = index_of(text, c"->")
	int sender = -1
	for int actor in callers:
		if (actor >= 0): sender = actor
	if (explicit_sender >= 0 && explicit_sender < dot):
		char* from = mm_n_part(text, 0, explicit_sender)
		sender = mm_n_actor(p, from)
		free(from)
		target_start = explicit_sender + 2
	if (sender < 0):
		sender = mm_n_actor(p, c"__external")
		if (sender >= 0):
			mm_node* external = p.doc.nodes[sender]
			free(external.label)
			external.label = strclone(c"External")
	char* target = mm_n_part(text, target_start, dot)
	int receiver = mm_n_actor(p, target)
	free(target)
	char* label = mm_n_part(text, dot + 1, length - nested)
	if (mm_n_method(label) == 0): mm_error(p.doc, p.pos, c"expected a ZenUML method name and optional balanced arguments")
	int index = p.doc.narrative.length
	mm_narrative_event* event = mm_n_event(p, MM_N_MESSAGE, label, c"")
	free(label)
	if (event != 0):
		event.from_node = sender
		event.to_node = receiver
		event.arrow = 1
		if (nested):
			blocks.push(index)
			callers.push(receiver)
			mm_n_activation(p, receiver, 1)

void mm_narrative_body(mm_parser* p):
	char* section = strclone(c"")
	list[int] blocks = new list[int]
	list[int] callers = new list[int]
	while (mm_peek(p) != 0 && p.doc.error == 0):
		char* text = mm_n_line(p)
		if (mm_n_prefix(text, c"title ")):
			free(p.doc.title)
			p.doc.title = mm_n_trim(text + 6)
		else if (mm_n_prefix(text, c"section ") && p.doc.kind != MM_SEQUENCE && p.doc.kind != MM_ZENUML):
			free(section)
			section = mm_n_trim(text + 8)
			if (section[0] == 0): mm_error(p.doc, p.pos, c"section requires a title")
		else if (p.doc.kind == MM_SEQUENCE): mm_n_sequence(p, text, blocks)
		else if (p.doc.kind == MM_JOURNEY): mm_n_journey(p, text, section)
		else if (p.doc.kind == MM_TIMELINE): mm_n_timeline(p, text, section)
		else if (p.doc.kind == MM_ZENUML): mm_n_zen(p, text, blocks, callers)
		else if (p.doc.kind == MM_GANTT):
			if (mm_n_prefix(text, c"dateFormat ")):
				char* format = mm_n_trim(text + 11)
				if (strcmp(format, c"YYYY-MM-DD") != 0): mm_error(p.doc, p.pos, c"native Gantt currently requires dateFormat YYYY-MM-DD")
				free(format)
			else: mm_n_gantt(p, text, section)
		free(text)
		mm_separators(p)
	if (blocks.length != 0): mm_error(p.doc, p.pos, c"unterminated narrative fragment or synchronous call")
	free(section)
	__w_list_free(cast(__w_list*, blocks))
	__w_list_free(cast(__w_list*, callers))
