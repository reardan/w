# Native ordered Mermaid grammars. Unsupported syntax is diagnosed, never ignored.
import libs.extras.mermaid.parse_common
import libs.extras.mermaid.style

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
const int MM_N_CREATE = 11
const int MM_N_DESTROY = 12

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

int mm_n_declare(mm_parser* p, char* text, int actor):
	int split = index_of(text, c" as ")
	char* id
	if (split >= 0): id = mm_n_part(text, 0, split)
	else: id = mm_n_trim(text)
	int index = mm_n_actor(p, id)
	free(id)
	if (index < 0): return -1
	mm_node* node = p.doc.nodes[index]
	node.shape = actor
	if (split >= 0):
		free(node.label)
		node.label = mm_n_part(text, split + 4, strlen(text))
		if (node.label[0] == 0): mm_error(p.doc, p.pos, c"empty participant alias")
	return index

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

void mm_n_lifecycle(mm_parser* p, char* text, int create):
	int actor = -1
	if (create):
		int count = p.doc.nodes.length
		if (mm_n_prefix(text, c"participant ")): mm_n_declare(p, text + 12, 0)
		else if (mm_n_prefix(text, c"actor ")): mm_n_declare(p, text + 6, 1)
		else: mm_error(p.doc, p.pos, c"create requires participant or actor declaration")
		if (p.doc.nodes.length != count + 1): mm_error(p.doc, p.pos, c"created participant must not already exist")
		else: actor = count
	else:
		char* id = mm_n_trim(text)
		for i in range(p.doc.nodes.length):
			mm_node* node = p.doc.nodes[i]
			if (strcmp(node.id, id) == 0): actor = i
		free(id)
		if (actor < 0): mm_error(p.doc, p.pos, c"destroy requires an existing participant")
	if (p.doc.error != 0): return
	int kind = MM_N_DESTROY
	if (create): kind = MM_N_CREATE
	mm_narrative_event* event = mm_n_event(p, kind, c"", c"")
	if (event != 0): event.from_node = actor

void mm_n_validate_lifetimes(mm_parser* p):
	list[int] destroyed = new list[int]
	for i in range(p.doc.nodes.length): destroyed.push(0)
	mm_narrative_event* pending = 0
	for i in range(p.doc.narrative.length):
		mm_narrative_event* event = p.doc.narrative[i]
		if (pending != 0):
			if (event.kind != MM_N_MESSAGE):
				mm_error(p.doc, p.pos, c"participant create/destroy must be followed by its message")
				break
			int actor = pending.from_node
			if (pending.kind == MM_N_CREATE):
				if (event.to_node != actor || event.from_node == actor): mm_error(p.doc, p.pos, c"creation message must target the new participant")
			else:
				if (event.to_node != actor && event.from_node != actor): mm_error(p.doc, p.pos, c"destruction message must involve the destroyed participant")
			pending.end = i
		if (event.from_node >= 0 && destroyed[event.from_node] && event.kind != MM_N_DEACTIVATE): mm_error(p.doc, p.pos, c"participant used after destruction")
		if (event.to_node >= 0 && destroyed[event.to_node]): mm_error(p.doc, p.pos, c"participant used after destruction")
		if (pending != 0):
			if (pending.kind == MM_N_DESTROY): destroyed[pending.from_node] = 1
			pending = 0
		if (event.kind == MM_N_CREATE || event.kind == MM_N_DESTROY): pending = event
		if (p.doc.error != 0): break
	if (pending != 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"participant create/destroy requires a following message")
	__w_list_free(cast(__w_list*, destroyed))

void mm_n_autonumber(mm_parser* p, char* text, list[int] numbering):
	if (strcmp(text, c"autonumber off") == 0):
		numbering[0] = 0
		return
	if (strcmp(text, c"autonumber") == 0):
		p.doc.narrative_numbered = 1
		numbering[0] = 1
		return
	char* tail = mm_n_trim(text + 10)
	int start = 1
	int step = 1
	if (tail[0] != 0):
		int at = 0
		while (tail[at] != 0 && tail[at] != 32 && tail[at] != 9): at = at + 1
		char* first = mm_n_part(tail, 0, at)
		start = mm_n_number(first, 1000000)
		free(first)
		char* rest = mm_n_trim(tail + at)
		if (rest[0] != 0): step = mm_n_number(rest, 1000000)
		free(rest)
	free(tail)
	if (start < 0 || step <= 0): mm_error(p.doc, p.pos, c"autonumber requires a nonnegative start and positive increment")
	numbering[0] = 1
	numbering[1] = start
	numbering[2] = step
	p.doc.narrative_numbered = 1

# `box [color] [label]` groups the participants declared before its `end`.
# The first word is a fill only when it parses as a supported CSS color.
void mm_n_box(mm_parser* p, char* text, list[int] blocks):
	if (blocks.length != 0):
		mm_error(p.doc, p.pos, c"sequence boxes must be top-level")
		return
	if (p.doc.boxes.length >= MM_MAX_ITEMS):
		mm_error(p.doc, p.pos, c"sequence box limit exceeded")
		return
	char* rest = mm_n_trim(text + 3)
	int split = index_of(rest, c" ")
	if (mm_n_prefix(rest, c"rgb")): split = index_of(rest, c")") + 1
	if (split <= 0): split = strlen(rest)
	char* word = mm_n_part(rest, 0, split)
	int color = -1
	char* label
	if (word[0] != 0 && mm_style_css_color(word) != -2):
		color = mm_style_css_color(word)
		label = mm_n_part(rest, split, strlen(rest))
	else: label = strclone(rest)
	mm_narrative_event* box = new mm_narrative_event()
	box.label = label
	box.detail = strclone(c"")
	box.section = strclone(c"")
	box.value = color
	box.from_node = -1
	box.to_node = -1
	p.doc.boxes.push(box)
	blocks.push(-1)
	free(word)
	free(rest)

void mm_n_box_member(mm_parser* p, char* text, int actor):
	int before = p.doc.nodes.length
	mm_n_declare(p, text, actor)
	if (p.doc.error != 0): return
	if (p.doc.nodes.length != before + 1):
		mm_error(p.doc, p.pos, c"box participants must be declared first inside their box")
		return
	mm_narrative_event* box = p.doc.boxes[p.doc.boxes.length - 1]
	if (box.from_node < 0): box.from_node = before
	box.to_node = before

void mm_n_rect(mm_parser* p, char* text, list[int] blocks):
	char* value = mm_n_trim(text + 5)
	int color = mm_style_css_color(value)
	free(value)
	if (color == -2):
		mm_error(p.doc, p.pos, c"rect requires a supported color such as rgb(r, g, b)")
		return
	if (blocks.length >= 32):
		mm_error(p.doc, p.pos, c"sequence nesting limit exceeded")
		return
	int index = p.doc.narrative.length
	mm_narrative_event* event = mm_n_event(p, MM_N_BLOCK, text, c"")
	if (event == 0): return
	free(event.detail)
	event.detail = strclone(c"rect")
	event.value = color
	blocks.push(index)

void mm_n_add_link(mm_parser* p, mm_node* node, char* label, char* url):
	if (label[0] == 0 || url[0] == 0):
		mm_error(p.doc, p.pos, c"participant link requires a label and URL")
		return
	if (node.metadata.length >= 64):
		mm_error(p.doc, p.pos, c"participant link limit exceeded")
		return
	mm_property* property = new mm_property()
	property.key = strclone(label)
	property.value = strclone(url)
	node.metadata.push(property)

# Reads one JSON string at cursor[0]; handles \" and \\ escapes. Returns 0 on error.
char* mm_n_json_string(char* text, list[int] cursor):
	int at = cursor[0]
	while (text[at] == ' ' || text[at] == 9): at = at + 1
	if (text[at] != '"'): return 0
	at = at + 1
	string_builder* out = string_new()
	while (text[at] != 0 && text[at] != '"'):
		if (text[at] == 92 && (text[at + 1] == '"' || text[at + 1] == 92 || text[at + 1] == '/')): at = at + 1
		string_append_char(out, text[at])
		at = at + 1
	if (text[at] != '"'):
		string_free(out)
		return 0
	cursor[0] = at + 1
	char* result = out.data
	free(out)
	return result

# `link A: Label @ url` and `links A: {"Label": "url", ...}` participant menus.
void mm_n_link(mm_parser* p, char* text, int many):
	int colon = index_of(text, c":")
	if (colon < 0):
		mm_error(p.doc, p.pos, c"participant link requires a colon")
		return
	char* id = mm_n_part(text, 0, colon)
	int index = mm_find_node(p.doc, id)
	free(id)
	if (index < 0):
		mm_error(p.doc, p.pos, c"link requires an existing participant")
		return
	mm_node* node = p.doc.nodes[index]
	char* body = mm_n_trim(text + colon + 1)
	if (many == 0):
		int at = index_of(body, c"@")
		if (at < 0): mm_error(p.doc, p.pos, c"participant link requires a label and URL")
		else:
			char* label = mm_n_part(body, 0, at)
			char* url = mm_n_part(body, at + 1, strlen(body))
			mm_n_add_link(p, node, label, url)
			free(label)
			free(url)
		free(body)
		return
	list[int] cursor = list[int]{1}
	int valid = body[0] == '{'
	int done = 0
	while (valid && done == 0 && p.doc.error == 0):
		char* label = mm_n_json_string(body, cursor)
		if (label == 0):
			valid = 0
			continue
		while (body[cursor[0]] == ' ' || body[cursor[0]] == 9): cursor[0] = cursor[0] + 1
		char* url = 0
		if (body[cursor[0]] == ':'):
			cursor[0] = cursor[0] + 1
			url = mm_n_json_string(body, cursor)
		if (url == 0): valid = 0
		else: mm_n_add_link(p, node, label, url)
		free(label)
		free(url)
		while (body[cursor[0]] == ' ' || body[cursor[0]] == 9): cursor[0] = cursor[0] + 1
		if (body[cursor[0]] == ','): cursor[0] = cursor[0] + 1
		else if (body[cursor[0]] == '}'): done = 1
		else: valid = 0
	if (valid && done && body[cursor[0]] == '}' && body[cursor[0] + 1] != 0): valid = 0
	if (valid == 0): mm_error(p.doc, p.pos, c"participant links require a JSON object of strings")
	__w_list_free(cast(__w_list*, cursor))
	free(body)

void mm_n_sequence(mm_parser* p, char* text, list[int] blocks, list[int] numbering):
	int in_box = blocks.length > 0 && blocks[blocks.length - 1] < 0
	if (in_box && strcmp(text, c"end") != 0 && mm_n_prefix(text, c"participant ") == 0 && mm_n_prefix(text, c"actor ") == 0):
		mm_error(p.doc, p.pos, c"sequence boxes may contain only participant or actor declarations")
		return
	if (in_box && strcmp(text, c"end") == 0):
		blocks.pop()
		mm_narrative_event* box = p.doc.boxes[p.doc.boxes.length - 1]
		if (box.from_node < 0): mm_error(p.doc, p.pos, c"empty sequence box")
		return
	if (in_box && mm_n_prefix(text, c"participant ")): mm_n_box_member(p, text + 12, 0)
	else if (in_box): mm_n_box_member(p, text + 6, 1)
	else if (strcmp(text, c"box") == 0 || mm_n_prefix(text, c"box ")): mm_n_box(p, text, blocks)
	else if (mm_n_prefix(text, c"rect ")): mm_n_rect(p, text, blocks)
	else if (mm_n_prefix(text, c"participant ")): mm_n_declare(p, text + 12, 0)
	else if (mm_n_prefix(text, c"link ")): mm_n_link(p, text + 5, 0)
	else if (mm_n_prefix(text, c"links ")): mm_n_link(p, text + 6, 1)
	else if (mm_n_prefix(text, c"actor ")): mm_n_declare(p, text + 6, 1)
	else if (mm_n_prefix(text, c"create ")): mm_n_lifecycle(p, text + 7, 1)
	else if (mm_n_prefix(text, c"destroy ")): mm_n_lifecycle(p, text + 8, 0)
	else if (strcmp(text, c"autonumber") == 0 || mm_n_prefix(text, c"autonumber ")): mm_n_autonumber(p, text, numbering)
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

int mm_n_month_length(int year, int month):
	if (month == 4 || month == 6 || month == 9 || month == 11): return 30
	if (month == 2): return 28 + mm_n_leap(year)
	return 31

# Days since 1970-01-01, or -1 for an invalid Gregorian date.
int mm_n_days(int year, int month, int day):
	if (year < 1970 || year > 9999 || month < 1 || month > 12 || day < 1): return -1
	if (day > mm_n_month_length(year, month)): return -1
	int days = 0
	for y in range(1970, year): days = days + 365 + mm_n_leap(y)
	for m in range(1, month): days = days + mm_n_month_length(year, m)
	return days + day - 1

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
	if (year < 0 || month < 0 || day < 0): return -1
	return mm_n_days(year, month, day)

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

mm_gantt_settings* mm_n_gantt_settings(mm_document* d):
	if (d.gantt == 0):
		mm_gantt_settings* g = new mm_gantt_settings()
		g.date_format = strclone(c"YYYY-MM-DD")
		g.axis_format = strclone(c"")
		g.weekend_start = 6
		g.excluded = new list[int]
		g.included = new list[int]
		g.today = -1
		d.gantt = g
	return d.gantt

# Minute-unit charts end at 4000-12-31 so every moment fits a 32-bit int.
const int MM_N_MINUTE_YEAR_LIMIT = 4000

int mm_n_unit_limit(mm_gantt_settings* g):
	if (g.minutes): return (mm_n_days(MM_N_MINUTE_YEAR_LIMIT, 12, 31) + 1) * 1440
	return mm_n_days(9999, 12, 31)

int mm_n_format_token(char* format):
	if (mm_n_prefix(format, c"YYYY")): return 4
	if (mm_n_prefix(format, c"MM") || mm_n_prefix(format, c"DD") || mm_n_prefix(format, c"HH") || mm_n_prefix(format, c"mm")): return 2
	return 0

int mm_n_format_slot(int c):
	if (c == 'M'): return 1
	if (c == 'D'): return 2
	if (c == 'H'): return 3
	if (c == 'm'): return 4
	return 0

# Returns 0 for a date format, 1 for a minute format, -1 when unsupported.
int mm_n_format_kind(char* format):
	list[int] counts = list[int]{0, 0, 0, 0, 0}
	int i = 0
	int valid = 1
	while (format[i] != 0):
		int width = mm_n_format_token(format + i)
		if (width == 0):
			if (isalnum(format[i])): valid = 0
			i = i + 1
			continue
		int slot = mm_n_format_slot(format[i])
		counts[slot] = counts[slot] + 1
		i = i + width
	int result = counts[3]
	if (valid == 0 || counts[0] != 1 || counts[1] != 1 || counts[2] != 1 || counts[3] > 1 || counts[3] != counts[4]): result = -1
	__w_list_free(cast(__w_list*, counts))
	return result

# Parses text with the active dateFormat into chart units, or returns -1.
int mm_n_moment(mm_gantt_settings* g, char* text):
	char* format = g.date_format
	list[int] parts = list[int]{0, 0, 0, 0, 0}
	int i = 0
	int j = 0
	int valid = 1
	while (format[i] != 0 && valid):
		int width = mm_n_format_token(format + i)
		if (width == 0):
			if (text[j] != format[i]): valid = 0
			i = i + 1
			j = j + 1
			continue
		int value = 0
		for k in range(width):
			if (valid && (text[j + k] < '0' || text[j + k] > '9')): valid = 0
			if (valid): value = value * 10 + text[j + k] - '0'
		parts[mm_n_format_slot(format[i])] = value
		i = i + width
		j = j + width
	if (valid && text[j] != 0): valid = 0
	int result = -1
	if (valid && parts[3] <= 23 && parts[4] <= 59): result = mm_n_days(parts[0], parts[1], parts[2])
	if (result >= 0 && g.minutes):
		if (parts[0] > MM_N_MINUTE_YEAR_LIMIT): result = -1
		else: result = result * 1440 + parts[3] * 60 + parts[4]
	__w_list_free(cast(__w_list*, parts))
	return result

# Day/week durations in either mode; hour/minute units need a time format.
int mm_n_span(mm_gantt_settings* g, char* text):
	int length = strlen(text)
	if (length < 2): return -1
	int unit = text[length - 1]
	int per = 0
	int day = 1
	if (g.minutes): day = 1440
	if (unit == 'd'): per = day
	if (unit == 'w'): per = day * 7
	if (g.minutes && unit == 'h'): per = 60
	if (g.minutes && unit == 'm'): per = 1
	if (per == 0): return -1
	int maximum = 365000
	if (g.minutes): maximum = 3660 * 1440
	char* number = str_copy_range(text, 0, length - 1)
	int result = mm_n_number(number, maximum / per)
	free(number)
	if (result <= 0): return -1
	return result * per

int mm_n_sorted_has(list[int] values, int value):
	int low = 0
	int high = values.length
	while (low < high):
		int middle = low + (high - low) / 2
		if (values[middle] == value): return 1
		if (values[middle] < value): low = middle + 1
		else: high = middle
	return 0

void mm_n_sorted_insert(list[int] values, int value):
	if (mm_n_sorted_has(values, value)): return
	values.push(value)
	int i = values.length - 1
	while (i > 0 && values[i - 1] > value):
		values[i] = values[i - 1]
		i = i - 1
	values[i] = value

# 1970-01-01 was a Thursday; bit 0 of the mask is Sunday.
int mm_n_weekday_off(mm_gantt_settings* g, int day):
	return (g.weekday_mask >> ((day + 4) % 7)) & 1

int mm_n_excluded_day(mm_gantt_settings* g, int day):
	if (mm_n_sorted_has(g.included, day)): return 0
	return mm_n_weekday_off(g, day) || mm_n_sorted_has(g.excluded, day)

# Working days in [a, b): whole weeks by arithmetic, exceptions by list scan.
int mm_n_working_days(mm_gantt_settings* g, int a, int b):
	if (b <= a): return 0
	int working_week = 0
	for weekday in range(7):
		if (((g.weekday_mask >> weekday) & 1) == 0): working_week = working_week + 1
	int weeks = (b - a) / 7
	int count = weeks * working_week
	for day in range(a + weeks * 7, b):
		if (mm_n_weekday_off(g, day) == 0): count = count + 1
	for int day in g.excluded:
		if (day >= a && day < b && mm_n_weekday_off(g, day) == 0 && mm_n_sorted_has(g.included, day) == 0): count = count - 1
	for int day in g.included:
		if (day >= a && day < b && mm_n_weekday_off(g, day)): count = count + 1
	return count

int mm_n_working_units(mm_gantt_settings* g, int a, int b):
	if (b <= a): return 0
	if (g.minutes == 0): return mm_n_working_days(g, a, b)
	int first = a / 1440
	int last = b / 1440
	if (first == last):
		if (mm_n_excluded_day(g, first)): return 0
		return b - a
	int total = mm_n_working_days(g, first + 1, last) * 1440
	if (mm_n_excluded_day(g, first) == 0): total = total + (first + 1) * 1440 - a
	if (b > last * 1440 && mm_n_excluded_day(g, last) == 0): total = total + b - last * 1440
	return total

# Duration-based ends skip excluded days; returns past the limit when none fit.
int mm_n_finish(mm_gantt_settings* g, int start, int duration):
	if (duration == 0 || (g.weekday_mask == 0 && g.excluded.length == 0)): return start + duration
	int limit = mm_n_unit_limit(g) + 1
	if (start + duration > limit || mm_n_working_units(g, start, limit) < duration): return limit
	int low = start + duration
	int high = limit
	while (low < high):
		int middle = low + (high - low) / 2
		if (mm_n_working_units(g, start, middle) >= duration): high = middle
		else: low = middle + 1
	return low

int mm_n_same_word(char* a, char* b):
	if (strlen(a) != strlen(b)): return 0
	int i = 0
	while (a[i] != 0):
		if (tolower(a[i]) != tolower(b[i])): return 0
		i = i + 1
	return 1

int mm_n_day_value(mm_gantt_settings* g, char* text):
	int day = mm_n_moment(g, text)
	if (day >= 0 && g.minutes): return day / 1440
	if (day < 0): day = mm_n_date(text)
	return day

# `excludes`/`includes` items are separated by spaces or commas, as upstream.
void mm_n_gantt_days(mm_parser* p, mm_gantt_settings* g, char* text, int include):
	list[char*] names = list[char*]{c"sunday", c"monday", c"tuesday", c"wednesday", c"thursday", c"friday", c"saturday"}
	int length = strlen(text)
	int start = 0
	int items = 0
	for i in range(length + 1):
		if (i < length && text[i] != ' ' && text[i] != ',' && text[i] != 9): continue
		if (i > start):
			char* item = str_copy_range(text, start, i)
			int known = 0
			if (include == 0 && mm_n_same_word(item, c"weekends")):
				g.weekends = 1
				known = 1
			for weekday in range(7):
				if (include == 0 && mm_n_same_word(item, names[weekday])):
					g.weekday_mask = g.weekday_mask | (1 << weekday)
					known = 1
			if (known == 0):
				int day = mm_n_day_value(g, item)
				list[int] target = g.excluded
				if (include): target = g.included
				if (day < 0): mm_error(p.doc, p.pos, c"unsupported Gantt excludes/includes value")
				else if (target.length >= MM_MAX_ITEMS): mm_error(p.doc, p.pos, c"Gantt excluded date limit exceeded")
				else: mm_n_sorted_insert(target, day)
			free(item)
			items = items + 1
		start = i + 1
		if (p.doc.error != 0): break
	if (items == 0): mm_error(p.doc, p.pos, c"unsupported Gantt excludes/includes value")
	__w_list_free(cast(__w_list*, names))

# Supported strftime tokens for axis labels.
int mm_n_axis_valid(char* format):
	char* tokens = c"YymdebBaAHIMpj%"
	int i = 0
	while (format[i] != 0):
		if (format[i] == '%'):
			int known = 0
			int k = 0
			while (tokens[k] != 0):
				if (format[i + 1] == tokens[k]): known = 1
				k = k + 1
			if (known == 0): return 0
			i = i + 1
		i = i + 1
	return 1

# `click ID href "url"` keeps the target on the task's node metadata.
void mm_n_gantt_click(mm_parser* p, char* text):
	int at = 0
	while (text[at] != 0 && text[at] != ' ' && text[at] != 9): at = at + 1
	char* id = str_copy_range(text, 0, at)
	char* rest = mm_n_trim(text + at)
	if (mm_n_prefix(rest, c"call ") || mm_n_prefix(rest, c"call(")): mm_error(p.doc, p.pos, c"Gantt click callbacks are not supported natively")
	else if (mm_n_prefix(rest, c"href ") == 0): mm_error(p.doc, p.pos, c"Gantt click requires href and a quoted URL")
	else:
		char* url = mm_n_trim(rest + 5)
		int length = strlen(url)
		if (length < 3 || url[0] != '"' || url[length - 1] != '"' || index_of(url + 1, c"\"") != length - 2): mm_error(p.doc, p.pos, c"Gantt click requires href and a quoted URL")
		else:
			int node = mm_n_actor(p, id)
			if (node >= 0):
				mm_node* target = p.doc.nodes[node]
				mm_property* property = 0
				for mm_property* existing in target.metadata:
					if (strcmp(existing.key, c"href") == 0): property = existing
				if (property == 0):
					property = new mm_property()
					property.key = strclone(c"href")
					property.value = strclone(c"")
					target.metadata.push(property)
				free(property.value)
				property.value = str_copy_range(url, 1, length - 1)
		free(url)
	free(rest)
	free(id)

# Returns 1 when the line was a Gantt configuration directive.
int mm_n_gantt_directive(mm_parser* p, char* text):
	mm_gantt_settings* g = mm_n_gantt_settings(p.doc)
	if (mm_n_prefix(text, c"dateFormat ")):
		char* format = mm_n_trim(text + 11)
		int kind = mm_n_format_kind(format)
		if (kind < 0): mm_error(p.doc, p.pos, c"unsupported Gantt dateFormat")
		else if (p.doc.narrative.length != 0 || g.excluded.length != 0 || g.included.length != 0 || g.today >= 0): mm_error(p.doc, p.pos, c"Gantt dateFormat must precede tasks and dates")
		else:
			free(g.date_format)
			g.date_format = strclone(format)
			g.minutes = kind
		free(format)
	else if (mm_n_prefix(text, c"axisFormat ")):
		char* format = mm_n_trim(text + 11)
		if (format[0] == 0 || mm_n_axis_valid(format) == 0): mm_error(p.doc, p.pos, c"unsupported Gantt axisFormat")
		else:
			free(g.axis_format)
			g.axis_format = strclone(format)
		free(format)
	else if (mm_n_prefix(text, c"excludes ")): mm_n_gantt_days(p, g, text + 9, 0)
	else if (mm_n_prefix(text, c"includes ")): mm_n_gantt_days(p, g, text + 9, 1)
	else if (mm_n_prefix(text, c"weekend ")):
		char* day = mm_n_trim(text + 8)
		if (mm_n_same_word(day, c"friday")): g.weekend_start = 5
		else if (mm_n_same_word(day, c"saturday")): g.weekend_start = 6
		else: mm_error(p.doc, p.pos, c"Gantt weekend must be friday or saturday")
		free(day)
	else if (mm_n_prefix(text, c"todayMarker ")):
		# Never the wall clock: only a fixed date draws a marker; styles stay in source.
		char* value = mm_n_trim(text + 12)
		g.today = -1
		if (strcmp(value, c"off") != 0):
			g.today = mm_n_moment(g, value)
			if (g.today < 0 && g.minutes == 0): g.today = mm_n_date(value)
		free(value)
	else if (mm_n_prefix(text, c"click ")): mm_n_gantt_click(p, text + 6)
	else: return 0
	return 1

void mm_n_gantt_finish_settings(mm_parser* p):
	mm_gantt_settings* g = mm_n_gantt_settings(p.doc)
	if (g.weekends): g.weekday_mask = g.weekday_mask | (1 << g.weekend_start) | (1 << ((g.weekend_start + 1) % 7))
	for mm_node* node in p.doc.nodes:
		if (node.metadata.length == 0): continue
		int found = 0
		for mm_narrative_event* task in p.doc.narrative:
			if (strcmp(task.detail, node.id) == 0): found = 1
		if (found == 0): mm_error(p.doc, p.pos, c"Gantt click references unknown task")

# Temporary scheduling records live only during parsing; events retain resolved dates.
struct mm_n_schedule:
	mm_narrative_event* task
	char* dependencies
	char* until
	list[int] dependency_indices
	int until_index
	int previous
	int duration
	int offset

int mm_n_dependency_index(mm_parser* p, char* id, int offset):
	for i in range(p.doc.narrative.length):
		mm_narrative_event* task = p.doc.narrative[i]
		if (task.detail[0] != 0 && strcmp(task.detail, id) == 0): return i
	mm_error(p.doc, offset, c"unknown Gantt dependency")
	return -1

# Resolve names once, so reverse dependency chains do not repeatedly scan IDs.
void mm_n_schedule_indices(mm_parser* p, list[mm_n_schedule*] schedules):
	for mm_n_schedule* item in schedules:
		int at = 0
		while (item.dependencies[at] != 0):
			while (item.dependencies[at] == 32 || item.dependencies[at] == 9): at = at + 1
			int start = at
			while (item.dependencies[at] != 0 && item.dependencies[at] != 32 && item.dependencies[at] != 9): at = at + 1
			if (at == start): break
			char* id = str_copy_range(item.dependencies, start, at)
			int index = mm_n_dependency_index(p, id, item.offset)
			free(id)
			if (index >= 0): item.dependency_indices.push(index)
		if (item.until[0] != 0): item.until_index = mm_n_dependency_index(p, item.until, item.offset)

void mm_n_resolve_gantt(mm_parser* p, list[mm_n_schedule*] schedules):
	# Resolve starts and ends independently: an until edge needs only a start.
	mm_n_schedule_indices(p, schedules)
	if (p.doc.error != 0): return
	mm_gantt_settings* g = mm_n_gantt_settings(p.doc)
	int last_day = mm_n_unit_limit(g)
	for pass in range(schedules.length * 2 + 1):
		int changed = 0
		int unresolved = 0
		for mm_n_schedule* item in schedules:
			mm_narrative_event* task = item.task
			if (task.start < 0):
				int begin = -1
				if (item.previous >= 0):
					mm_narrative_event* previous = p.doc.narrative[item.previous]
					begin = previous.end
				else:
					int ready = 1
					for int index in item.dependency_indices:
						mm_narrative_event* dependency = p.doc.narrative[index]
						int end = dependency.end
						if (end < 0): ready = 0
						if (end > begin): begin = end
					if (ready == 0): begin = -1
				if (begin >= 0):
					task.start = begin
					changed = 1
			if (task.end < 0):
				int finish = -1
				if (item.until_index >= 0):
					mm_narrative_event* dependency = p.doc.narrative[item.until_index]
					finish = dependency.start
				else if (task.start >= 0): finish = mm_n_finish(g, task.start, item.duration)
				if (finish >= 0):
					task.end = finish
					changed = 1
			if (task.start < 0 || task.end < 0): unresolved = unresolved + 1
			else if (task.end < task.start || task.end > last_day):
				mm_error(p.doc, item.offset, c"Gantt end precedes start or exceeds supported calendar")
		if (p.doc.error != 0 || unresolved == 0): return
		if (changed == 0):
			mm_error(p.doc, p.pos, c"cyclic Gantt dependencies")
			return

void mm_n_gantt(mm_parser* p, char* text, char* section, list[mm_n_schedule*] schedules):
	mm_gantt_settings* g = mm_n_gantt_settings(p.doc)
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
	if (at < fields.length && mm_n_moment(g, fields[at]) < 0 && mm_n_span(g, fields[at]) < 0 && mm_n_prefix(fields[at], c"after ") == 0 && mm_n_prefix(fields[at], c"until ") == 0 && strcmp(fields[at], c"0d") != 0):
		free(id)
		id = strclone(fields[at])
		if (mm_n_actor(p, id) >= 0):
			for mm_narrative_event* previous in p.doc.narrative:
				if (strcmp(previous.detail, id) == 0): mm_error(p.doc, p.pos, c"duplicate Gantt task id")
		at = at + 1
	int begin = -1
	char* dependencies = strclone(c"")
	int previous = -1
	if (fields.length - at >= 2):
		begin = mm_n_moment(g, fields[at])
		if (begin < 0 && mm_n_prefix(fields[at], c"after ")):
			free(dependencies)
			dependencies = mm_n_trim(fields[at] + 6)
			if (dependencies[0] == 0): mm_error(p.doc, p.pos, c"Gantt after requires task identifiers")
		else if (begin < 0): mm_error(p.doc, p.pos, c"Gantt requires a dateFormat start or after dependencies")
		at = at + 1
	else:
		previous = p.doc.narrative.length - 1
		if (previous < 0): mm_error(p.doc, p.pos, c"first Gantt task requires an explicit start or dependencies")
	int finish = -1
	int duration = -1
	char* until = strclone(c"")
	if (at < fields.length):
		finish = mm_n_moment(g, fields[at])
		if (finish < 0):
			duration = mm_n_span(g, fields[at])
			if ((status & 8) != 0 && strcmp(fields[at], c"0d") == 0): duration = 0
			if (mm_n_prefix(fields[at], c"until ")):
				free(until)
				until = mm_n_trim(fields[at] + 6)
		at = at + 1
	if ((finish < 0 && duration < 0 && until[0] == 0) || at != fields.length): mm_error(p.doc, p.pos, c"Gantt requires end date, until task or positive duration")
	if (p.doc.error == 0):
		mm_narrative_event* event = mm_n_event(p, MM_N_TASK, label, section)
		if (event != 0):
			event.start = begin
			event.end = finish
			event.value = status
			free(event.detail)
			event.detail = strclone(id)
			mm_n_schedule* schedule = new mm_n_schedule()
			schedule.task = event
			schedule.dependencies = strclone(dependencies)
			schedule.until = strclone(until)
			schedule.dependency_indices = new list[int]
			schedule.until_index = -1
			schedule.previous = previous
			schedule.duration = duration
			schedule.offset = p.pos
			schedules.push(schedule)
	free(dependencies)
	free(until)
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

# The innermost enclosing participant that is executing a call, or External.
int mm_n_zen_sender(mm_parser* p, list[int] callers):
	int sender = -1
	for int actor in callers:
		if (actor >= 0): sender = actor
	if (sender < 0):
		sender = mm_n_actor(p, c"__external")
		if (sender >= 0):
			mm_node* external = p.doc.nodes[sender]
			free(external.label)
			external.label = strclone(c"External")
	return sender

void mm_n_zen_reply(mm_parser* p, int from, int to, char* label):
	mm_narrative_event* event = mm_n_event(p, MM_N_MESSAGE, label, c"")
	if (event != 0):
		event.from_node = from
		event.to_node = to
		event.dashed = 1
		event.arrow = 1

# Opens a synchronous body: the receiver activates until the matching brace.
void mm_n_zen_open(mm_parser* p, int index, int receiver, char* reply, list[int] blocks, list[int] callers, list[char*] replies):
	blocks.push(index)
	callers.push(receiver)
	replies.push(strclone(reply))
	if (receiver >= 0): mm_n_activation(p, receiver, 1)

# Returns the `=` of `[Type] name = rhs`, or -1 when the statement is no assignment.
int mm_n_zen_assignment(char* text):
	int i = 0
	while (text[i] != 0 && text[i] != '(' && text[i] != '"' && text[i] != '.'):
		if (text[i] == '=' && text[i + 1] != '=' && i > 0):
			int words = 0
			int j = 0
			while (j < i):
				while (j < i && (text[j] == ' ' || text[j] == 9)): j = j + 1
				if (j >= i): break
				if (mm_id_char(text[j] & 255) == 0): return -1
				while (j < i && mm_id_char(text[j] & 255)): j = j + 1
				words = words + 1
			if (words == 1 || words == 2): return i
			return -1
		i = i + 1
	return -1

# `new Name(args)` creates a participant at its first use.
void mm_n_zen_new(mm_parser* p, char* text, int nested, list[int] blocks, list[int] callers, list[char*] replies):
	int length = strlen(text) - nested
	char* call = mm_n_part(text, 4, length)
	int open = index_of(call, c"(")
	if (open <= 0 || mm_n_method(call) == 0):
		mm_error(p.doc, p.pos, c"ZenUML new requires a participant and balanced arguments")
		free(call)
		return
	char* name = mm_n_part(call, 0, open)
	int existing = mm_find_node(p.doc, name)
	int sender = mm_n_zen_sender(p, callers)
	int receiver = mm_n_actor(p, name)
	free(name)
	if (receiver < 0 || sender < 0):
		free(call)
		return
	int used = 0
	if (existing >= 0):
		for mm_narrative_event* event in p.doc.narrative:
			if (event.from_node == receiver || event.to_node == receiver): used = 1
	mm_narrative_event* created = 0
	if (used == 0 && receiver != sender):
		created = mm_n_event(p, MM_N_CREATE, c"", c"")
		if (created != 0): created.from_node = receiver
	char* label = mm_n_part(text, 0, length)
	int index = p.doc.narrative.length
	mm_narrative_event* event = mm_n_event(p, MM_N_MESSAGE, label, c"")
	free(label)
	free(call)
	if (event == 0): return
	if (created != 0): created.end = index
	event.from_node = sender
	event.to_node = receiver
	event.arrow = 1
	event.dashed = 1
	if (nested): mm_n_zen_open(p, index, receiver, c"", blocks, callers, replies)

# ZenUML sync calls are nested by braces and reuse the native lifeline model.
void mm_n_zen(mm_parser* p, char* text, list[int] blocks, list[int] callers, list[char*] replies):
	if (mm_n_prefix(text, c"//")): return
	int is_else = mm_n_prefix(text, c"} else")
	if (is_else || mm_n_prefix(text, c"} catch") || mm_n_prefix(text, c"} finally")):
		if (blocks.length == 0):
			if (is_else): mm_error(p.doc, p.pos, c"ZenUML else outside conditional")
			else: mm_error(p.doc, p.pos, c"ZenUML catch/finally requires an open try and brace")
		else:
			mm_narrative_event* begin = p.doc.narrative[blocks[blocks.length - 1]]
			char* opener = c"try"
			if (is_else): opener = c"if"
			if (begin.kind != MM_N_BLOCK || mm_n_prefix(begin.label, opener) == 0 || text[strlen(text) - 1] != '{'):
				if (is_else): mm_error(p.doc, p.pos, c"ZenUML else requires an open conditional and brace")
				else: mm_error(p.doc, p.pos, c"ZenUML catch/finally requires an open try and brace")
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
			int actor = callers.pop()
			char* reply = replies.pop()
			if (reply[0] != 0): mm_n_zen_reply(p, begin.to_node, begin.from_node, reply)
			free(reply)
			begin.end = p.doc.narrative.length
			if (actor >= 0): mm_n_activation(p, actor, 0)
			else: mm_n_event(p, MM_N_END, c"", c"")
		return
	if (text[0] == '@'):
		int at = 1
		while (mm_id_char(text[at] & 255)): at = at + 1
		if (at == 1 || (text[at] != ' ' && text[at] != 9) || mm_id_char(text[1] & 255) == 0 || (text[1] >= '0' && text[1] <= '9')):
			mm_error(p.doc, p.pos, c"unsupported ZenUML annotation")
			return
		char* annotation = str_copy_range(text, 1, at)
		int actor = strcmp(annotation, c"Actor") == 0
		int index = mm_n_declare(p, text + at + 1, actor)
		if (index >= 0 && actor == 0):
			mm_node* node = p.doc.nodes[index]
			free(node.annotation)
			node.annotation = strclone(annotation)
		free(annotation)
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
		else: mm_n_zen_reply(p, actor, caller, text + 7)
		return
	int length = strlen(text)
	int nested = length > 0 && text[length - 1] == '{'
	if (nested && blocks.length >= 32):
		mm_error(p.doc, p.pos, c"ZenUML nesting limit exceeded")
		return
	if (mm_n_prefix(text, c"if(") || mm_n_prefix(text, c"if (") || mm_n_prefix(text, c"while(") || mm_n_prefix(text, c"while (") || mm_n_prefix(text, c"for(") || mm_n_prefix(text, c"for (") || mm_n_prefix(text, c"loop ") || strcmp(text, c"opt {") == 0 || strcmp(text, c"par {") == 0 || strcmp(text, c"try {") == 0):
		if (nested == 0): mm_error(p.doc, p.pos, c"ZenUML fragment requires opening brace")
		else:
			char* label = mm_n_part(text, 0, length - 1)
			int index = p.doc.narrative.length
			if (mm_n_event(p, MM_N_BLOCK, label, c"") != 0):
				blocks.push(index)
				callers.push(-1)
				replies.push(strclone(c""))
			free(label)
		return
	if (index_of(text, c"->") >= 0 && index_of(text, c":") >= 0):
		mm_n_message(p, text, 1)
		return
	char* reply = strclone(c"")
	int assign = mm_n_zen_assignment(text)
	if (assign >= 0):
		# The reply carries the assigned name; a declared type is dropped.
		char* left = mm_n_part(text, 0, assign)
		int name = strlen(left)
		while (name > 0 && mm_id_char(left[name - 1] & 255)): name = name - 1
		free(reply)
		reply = strclone(left + name)
		free(left)
		text = text + assign + 1
		while (text[0] == ' ' || text[0] == 9): text = text + 1
		length = strlen(text)
		if (length == 0): mm_error(p.doc, p.pos, c"ZenUML assignment requires a call")
	if (p.doc.error == 0 && mm_n_prefix(text, c"new ")):
		mm_n_zen_new(p, text, nested, blocks, callers, replies)
		free(reply)
		return
	int dot = index_of(text, c".")
	if (dot < 0 && p.doc.error == 0):
		if (reply[0] != 0): mm_error(p.doc, p.pos, c"ZenUML assignment requires a call")
		else: mm_n_declare(p, text, 0)
	if (dot < 0 || p.doc.error != 0):
		free(reply)
		return
	int target_start = 0
	int explicit_sender = index_of(text, c"->")
	int sender = -1
	if (explicit_sender >= 0 && explicit_sender < dot):
		char* from = mm_n_part(text, 0, explicit_sender)
		sender = mm_n_actor(p, from)
		free(from)
		target_start = explicit_sender + 2
	if (sender < 0): sender = mm_n_zen_sender(p, callers)
	char* target = mm_n_part(text, target_start, dot)
	int receiver = mm_n_actor(p, target)
	free(target)
	char* label = mm_n_part(text, dot + 1, length - nested)
	if (mm_n_method(label) == 0): mm_error(p.doc, p.pos, c"expected a ZenUML method name and optional balanced arguments")
	int index = p.doc.narrative.length
	mm_narrative_event* event = mm_n_event(p, MM_N_MESSAGE, label, c"")
	free(label)
	if (event != 0 && p.doc.error == 0):
		event.from_node = sender
		event.to_node = receiver
		event.arrow = 1
		if (nested): mm_n_zen_open(p, index, receiver, reply, blocks, callers, replies)
		else if (reply[0] != 0): mm_n_zen_reply(p, receiver, sender, reply)
	free(reply)

# Splits inline brace bodies (`A.m() { B.n() }`) into the line-oriented
# statements above. Braces inside quotes, arguments or async labels stay text.
void mm_n_zen_line(mm_parser* p, char* text, list[int] blocks, list[int] callers, list[char*] replies):
	if (mm_n_prefix(text, c"//")): return
	int length = strlen(text)
	int start = 0
	int depth = 0
	int quote = 0
	int i = 0
	while (i < length && p.doc.error == 0):
		int c = text[i]
		if (quote != 0):
			if (c == quote): quote = 0
		else if (c == '"' || c == 39): quote = c
		else if (c == '('): depth = depth + 1
		else if (c == ')' && depth > 0): depth = depth - 1
		else if (c == ':' && depth == 0):
			# An async message label runs to the end of the line.
			i = length
			continue
		else if (c == '{' && depth == 0):
			char* head = mm_n_part(text, start, i + 1)
			mm_n_zen(p, head, blocks, callers, replies)
			free(head)
			start = i + 1
		else if (c == '}' && depth == 0):
			char* head = mm_n_part(text, start, i)
			if (head[0] != 0): mm_n_zen(p, head, blocks, callers, replies)
			free(head)
			char* rest = mm_n_trim(text + i + 1)
			int joins = mm_n_prefix(rest, c"else") || mm_n_prefix(rest, c"catch") || mm_n_prefix(rest, c"finally")
			free(rest)
			if (joins): start = i
			else:
				if (p.doc.error == 0): mm_n_zen(p, c"}", blocks, callers, replies)
				start = i + 1
		i = i + 1
	if (p.doc.error != 0): return
	char* tail = mm_n_part(text, start, length)
	if (tail[0] != 0): mm_n_zen(p, tail, blocks, callers, replies)
	free(tail)

void mm_narrative_body(mm_parser* p):
	char* section = strclone(c"")
	list[int] blocks = new list[int]
	list[int] callers = new list[int]
	list[char*] replies = new list[char*]
	list[mm_n_schedule*] schedules = new list[mm_n_schedule*]
	list[int] numbering = list[int]{0, 1, 1}
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_metadata(p)):
			mm_separators(p)
			continue
		char* text = mm_n_line(p)
		if (mm_n_prefix(text, c"title ")):
			free(p.doc.title)
			p.doc.title = mm_n_trim(text + 6)
		else if (mm_n_prefix(text, c"section ") && p.doc.kind != MM_SEQUENCE && p.doc.kind != MM_ZENUML):
			free(section)
			section = mm_n_trim(text + 8)
			if (section[0] == 0): mm_error(p.doc, p.pos, c"section requires a title")
		else if (p.doc.kind == MM_SEQUENCE):
			int first = p.doc.narrative.length
			mm_n_sequence(p, text, blocks, numbering)
			for i in range(first, p.doc.narrative.length):
				mm_narrative_event* event = p.doc.narrative[i]
				if (event.kind == MM_N_MESSAGE):
					event.start = numbering[0]
					event.value = numbering[1]
					numbering[1] = numbering[1] + numbering[2]
		else if (p.doc.kind == MM_JOURNEY): mm_n_journey(p, text, section)
		else if (p.doc.kind == MM_TIMELINE): mm_n_timeline(p, text, section)
		else if (p.doc.kind == MM_ZENUML): mm_n_zen_line(p, text, blocks, callers, replies)
		else if (p.doc.kind == MM_GANTT):
			if (mm_n_gantt_directive(p, text) == 0): mm_n_gantt(p, text, section, schedules)
		free(text)
		mm_separators(p)
	if (blocks.length != 0): mm_error(p.doc, p.pos, c"unterminated narrative fragment or synchronous call")
	if (p.doc.error == 0 && p.doc.kind == MM_SEQUENCE): mm_n_validate_lifetimes(p)
	if (p.doc.error == 0 && p.doc.kind == MM_GANTT): mm_n_gantt_finish_settings(p)
	if (p.doc.error == 0 && p.doc.kind == MM_GANTT): mm_n_resolve_gantt(p, schedules)
	for mm_n_schedule* item in schedules:
		free(item.dependencies)
		free(item.until)
		__w_list_free(cast(__w_list*, item.dependency_indices))
		free(item)
	__w_list_free(cast(__w_list*, schedules))
	__w_list_free(cast(__w_list*, numbering))
	free(section)
	__w_list_free(cast(__w_list*, blocks))
	__w_list_free(cast(__w_list*, callers))
	for char* reply in replies: free(reply)
	__w_list_free(cast(__w_list*, replies))
