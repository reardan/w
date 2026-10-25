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

# Sequence entity codes (`#9829;`, `#infin;`) end in a semicolon that is not a separator.
int mm_n_entity_semicolon(mm_parser* p):
	if (p.doc.kind != MM_SEQUENCE || mm_peek(p) != ';'): return 0
	int at = p.pos - 1
	int digits = 0
	int letters = 0
	while (at >= 0 && digits + letters < 12 && isalnum(p.doc.source[at] & 255)):
		if (isdigit(p.doc.source[at] & 255)): digits = digits + 1
		else: letters = letters + 1
		at = at - 1
	if (at < 0 || p.doc.source[at] != '#' || digits + letters == 0): return 0
	return digits == 0 || letters == 0

char* mm_n_line(mm_parser* p):
	int start = p.pos
	while (mm_peek(p) != 0 && mm_peek(p) != 10 && (mm_peek(p) != ';' || mm_n_entity_semicolon(p))): p.pos = p.pos + 1
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

# Named entity codes accepted in sequence text; -1 when unknown.
int mm_n_entity_named(char* name):
	if (strcmp(name, c"amp") == 0): return 38
	if (strcmp(name, c"lt") == 0): return 60
	if (strcmp(name, c"gt") == 0): return 62
	if (strcmp(name, c"quot") == 0): return 34
	if (strcmp(name, c"apos") == 0): return 39
	if (strcmp(name, c"nbsp") == 0): return 160
	if (strcmp(name, c"copy") == 0): return 169
	if (strcmp(name, c"reg") == 0): return 174
	if (strcmp(name, c"deg") == 0): return 176
	if (strcmp(name, c"plusmn") == 0): return 177
	if (strcmp(name, c"micro") == 0): return 181
	if (strcmp(name, c"middot") == 0): return 183
	if (strcmp(name, c"times") == 0): return 215
	if (strcmp(name, c"divide") == 0): return 247
	if (strcmp(name, c"ndash") == 0): return 8211
	if (strcmp(name, c"mdash") == 0): return 8212
	if (strcmp(name, c"hellip") == 0): return 8230
	if (strcmp(name, c"euro") == 0): return 8364
	if (strcmp(name, c"larr") == 0): return 8592
	if (strcmp(name, c"uarr") == 0): return 8593
	if (strcmp(name, c"rarr") == 0): return 8594
	if (strcmp(name, c"darr") == 0): return 8595
	if (strcmp(name, c"harr") == 0): return 8596
	if (strcmp(name, c"infin") == 0): return 8734
	if (strcmp(name, c"ne") == 0): return 8800
	if (strcmp(name, c"le") == 0): return 8804
	if (strcmp(name, c"ge") == 0): return 8805
	if (strcmp(name, c"hearts") == 0): return 9829
	return -1

# Owned copy of sequence text with `#NNN;` and named `#name;` codes decoded to
# UTF-8. Unknown names, control characters and invalid code points stay literal.
char* mm_n_entities(char* text):
	string_builder* out = string_new()
	int i = 0
	while (text[i] != 0):
		if (text[i] == '#'):
			int j = i + 1
			int numeric = isdigit(text[j] & 255)
			while (j - i <= 12 && text[j] != 0 && ((numeric && isdigit(text[j] & 255)) || (numeric == 0 && isalpha(text[j] & 255)))): j = j + 1
			if (text[j] == ';' && j > i + 1):
				int code = -1
				if (numeric):
					code = 0
					for k in range(i + 1, j):
						if (code < 1114112): code = code * 10 + text[k] - '0'
				else:
					char* name = str_copy_range(text, i + 1, j)
					code = mm_n_entity_named(name)
					free(name)
				if (code >= 32 && code < 1114112 && (code < 55296 || code > 57343) && code != 127):
					char[8] bytes
					int length = utf8_encode(&bytes[0], code)
					string_append_bytes(out, &bytes[0], length)
					i = j + 1
					continue
		string_append_char(out, text[i])
		i = i + 1
	char* result = out.data
	free(out)
	return result

char* mm_n_text(mm_parser* p, char* text):
	if (p.doc.kind == MM_SEQUENCE): return mm_n_entities(text)
	return strclone(text)

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

char* mm_n_json_string(char* text, list[int] cursor);

# Participant object types of `participant X@{ "type": ... }`, as node shapes; -1 when unknown.
int mm_n_participant_type(char* name):
	if (strcmp(name, c"participant") == 0): return 0
	if (strcmp(name, c"actor") == 0): return 1
	if (strcmp(name, c"boundary") == 0): return 2
	if (strcmp(name, c"control") == 0): return 3
	if (strcmp(name, c"entity") == 0): return 4
	if (strcmp(name, c"database") == 0): return 5
	if (strcmp(name, c"collections") == 0): return 6
	if (strcmp(name, c"queue") == 0): return 7
	return -1

# Index just past the `}` closing the object that starts at text[start] == '{', or -1.
int mm_n_object_end(char* text, int start):
	int quoted = 0
	int i = start
	while (text[i] != 0):
		if (quoted && text[i] == 92 && text[i + 1] != 0): i = i + 1
		else if (text[i] == '"'): quoted = 1 - quoted
		else if (quoted == 0 && text[i] == '}'): return i + 1
		i = i + 1
	return -1

# Calls back for each `"key": "value"` pair of a flat JSON object of strings.
# Returns 0 for anything else; pairs before the error have been delivered.
int mm_n_object_pairs(mm_parser* p, char* body, mm_node* node, int kind):
	list[int] cursor = list[int]{1}
	int valid = body[0] == '{'
	int done = 0
	while (body[cursor[0]] == ' ' || body[cursor[0]] == 9): cursor[0] = cursor[0] + 1
	if (valid && body[cursor[0]] == '}'): done = 1
	while (valid && done == 0 && p.doc.error == 0):
		char* key = mm_n_json_string(body, cursor)
		if (key == 0):
			valid = 0
			continue
		while (body[cursor[0]] == ' ' || body[cursor[0]] == 9): cursor[0] = cursor[0] + 1
		char* value = 0
		if (body[cursor[0]] == ':'):
			cursor[0] = cursor[0] + 1
			value = mm_n_json_string(body, cursor)
		if (value == 0): valid = 0
		else if (kind == 0):
			if (strcmp(key, c"type") == 0):
				int shape = mm_n_participant_type(value)
				if (shape < 0): mm_error(p.doc, p.pos, c"unsupported participant type; supported: participant, actor, boundary, control, entity, database, collections, queue")
				else: node.shape = shape
			else if (strcmp(key, c"alias") == 0):
				free(node.label)
				node.label = mm_n_entities(value)
				if (node.label[0] == 0): mm_error(p.doc, p.pos, c"empty participant alias")
			else: mm_error(p.doc, p.pos, c"unsupported participant object key; supported: type, alias")
		else:
			if (node.members.length >= 64 || p.doc.attribute_count >= 4096): mm_error(p.doc, p.pos, c"participant property limit exceeded")
			else:
				string_builder* text = string_from(key)
				string_append(text, c": ")
				string_append(text, value)
				mm_member* member = new mm_member()
				member.text = strclone(text.data)
				string_free(text)
				node.members.push(member)
				p.doc.attribute_count = p.doc.attribute_count + 1
		free(key)
		if (value != 0): free(value)
		while (body[cursor[0]] == ' ' || body[cursor[0]] == 9): cursor[0] = cursor[0] + 1
		if (body[cursor[0]] == ','): cursor[0] = cursor[0] + 1
		else if (body[cursor[0]] == '}'): done = 1
		else: valid = 0
	if (valid && done && body[cursor[0] + 1] != 0): valid = 0
	__w_list_free(cast(__w_list*, cursor))
	return valid

# `participant ID[@{ "type": ..., "alias": ... }] [as Alias]`; an `as` alias wins.
int mm_n_declare(mm_parser* p, char* text, int actor):
	int object = -1
	if (p.doc.kind == MM_SEQUENCE): object = index_of(text, c"@{")
	int object_end = -1
	if (object >= 0):
		object_end = mm_n_object_end(text, object + 1)
		if (object_end < 0):
			mm_error(p.doc, p.pos, c"unterminated participant object")
			return -1
	int search = 0
	if (object_end >= 0): search = object_end
	int split = index_of(text + search, c" as ")
	if (split >= 0): split = split + search
	char* id
	if (object >= 0): id = mm_n_part(text, 0, object)
	else if (split >= 0): id = mm_n_part(text, 0, split)
	else: id = mm_n_trim(text)
	int index = mm_n_actor(p, id)
	free(id)
	if (index < 0): return -1
	mm_node* node = p.doc.nodes[index]
	node.shape = actor
	if (object >= 0):
		char* rest = mm_n_part(text, object_end, strlen(text))
		if (rest[0] != 0 && mm_n_prefix(rest, c"as ") == 0): mm_error(p.doc, p.pos, c"expected as or end of participant declaration")
		free(rest)
		char* body = str_copy_range(text, object + 1, object_end)
		if (p.doc.error == 0 && mm_n_object_pairs(p, body, node, 0) == 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"participant object requires a JSON object of strings")
		free(body)
	if (split >= 0):
		free(node.label)
		char* alias = mm_n_part(text, split + 4, strlen(text))
		node.label = mm_n_text(p, alias)
		free(alias)
		if (node.label[0] == 0): mm_error(p.doc, p.pos, c"empty participant alias")
	return index

# `properties A: {"key": "value"}` and `details A: text` are kept as participant
# members ("key: value"; details as "details: text"). Upstream resolves details
# from a DOM element and fetches property icons; neither happens natively.
void mm_n_properties(mm_parser* p, char* text, int details):
	int colon = index_of(text, c":")
	if (colon < 0):
		mm_error(p.doc, p.pos, c"participant properties require a colon")
		return
	char* id = mm_n_part(text, 0, colon)
	int index = mm_find_node(p.doc, id)
	free(id)
	if (index < 0):
		mm_error(p.doc, p.pos, c"properties require an existing participant")
		return
	mm_node* node = p.doc.nodes[index]
	char* body = mm_n_trim(text + colon + 1)
	if (details):
		if (body[0] == 0): mm_error(p.doc, p.pos, c"participant details require text")
		else if (node.members.length >= 64 || p.doc.attribute_count >= 4096): mm_error(p.doc, p.pos, c"participant property limit exceeded")
		else:
			string_builder* line = string_from(c"details: ")
			string_append(line, body)
			mm_member* member = new mm_member()
			member.text = strclone(line.data)
			member.method = 1
			string_free(line)
			node.members.push(member)
			p.doc.attribute_count = p.doc.attribute_count + 1
	else if (mm_n_object_pairs(p, body, node, 1) == 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"participant properties require a JSON object of strings")
	free(body)

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

# Sequence message arrow kinds: 0 none, 1 arrowhead, 2 cross, 3 open (async),
# 4 bidirectional, then the half-arrows: 5 top / 6 bottom solid half and
# 7 top / 8 bottom stick half at the receiver, 9..12 the same four drawn
# reversed at the sender. Each kind has a solid and a dotted spelling.
const int MM_N_ARROW_KINDS = 13

char* mm_n_arrow_token(int kind, int dashed):
	if (kind == 0 && dashed): return c"-->"
	if (kind == 0): return c"->"
	if (kind == 1 && dashed): return c"-->>"
	if (kind == 1): return c"->>"
	if (kind == 2 && dashed): return c"--x"
	if (kind == 2): return c"-x"
	if (kind == 3 && dashed): return c"--)"
	if (kind == 3): return c"-)"
	if (kind == 4 && dashed): return c"<<-->>"
	if (kind == 4): return c"<<->>"
	if (kind == 5 && dashed): return c"--|\\"
	if (kind == 5): return c"-|\\"
	if (kind == 6 && dashed): return c"--|/"
	if (kind == 6): return c"-|/"
	if (kind == 7 && dashed): return c"--\\\\"
	if (kind == 7): return c"-\\\\"
	if (kind == 8 && dashed): return c"--//"
	if (kind == 8): return c"-//"
	if (kind == 9 && dashed): return c"/|--"
	if (kind == 9): return c"/|-"
	if (kind == 10 && dashed): return c"\\|--"
	if (kind == 10): return c"\\|-"
	if (kind == 11 && dashed): return c"//--"
	if (kind == 11): return c"//-"
	if (kind == 12 && dashed): return c"\\\\--"
	return c"\\\\-"

void mm_n_message(mm_parser* p, char* text, int zen):
	int colon = index_of(text, c":")
	if (colon < 0):
		mm_error(p.doc, p.pos, c"message requires a colon and label")
		return
	int at = 0
	while (mm_id_char(text[at] & 255)): at = at + 1
	char* left = mm_n_part(text, 0, at)
	while (text[at] == 32 || text[at] == 9): at = at + 1
	int central = 0
	if (zen == 0 && text[at] == '(' && text[at + 1] == ')'):
		central = 1
		at = at + 2
	int type = -1
	int dashed = 0
	int best = 0
	for kind in range(MM_N_ARROW_KINDS):
		for dots in range(2):
			char* candidate = mm_n_arrow_token(kind, dots)
			int length = strlen(candidate)
			if (length > best && mm_n_prefix(text + at, candidate)):
				best = length
				type = kind
				dashed = dots
	at = at + best
	# ZenUML async messages use `->` (an open arrow); other arrows are rejected.
	if (zen):
		if (type == 0 && dashed == 0): type = 3
		else: type = -1
	int activate = 0
	if (text[at] == '+'):
		activate = 1
		at = at + 1
	else if (text[at] == '-'):
		activate = -1
		at = at + 1
	while (text[at] == 32 || text[at] == 9): at = at + 1
	if (zen == 0 && text[at] == '(' && text[at + 1] == ')'):
		central = central | 2
		at = at + 2
	char* right = mm_n_part(text, at, colon)
	int from = mm_n_actor(p, left)
	int to = mm_n_actor(p, right)
	free(left)
	free(right)
	if (type < 0): mm_error(p.doc, p.pos, c"unsupported sequence message arrow")
	if (p.doc.error != 0): return
	char* part = mm_n_part(text, colon + 1, strlen(text))
	char* label = mm_n_text(p, part)
	free(part)
	mm_narrative_event* event = mm_n_event(p, MM_N_MESSAGE, label, c"")
	free(label)
	if (event == 0): return
	event.from_node = from
	event.to_node = to
	event.arrow = type
	event.dashed = dashed
	event.central = central
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
	char* part = mm_n_part(text, colon + 1, strlen(text))
	char* label = mm_n_text(p, part)
	free(part)
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
	else if (mm_n_prefix(text, c"properties ")): mm_n_properties(p, text + 11, 0)
	else if (mm_n_prefix(text, c"details ")): mm_n_properties(p, text + 8, 1)
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

# `timeline LR` (default) or `timeline TD` after the header keyword.
void mm_n_timeline_header(mm_parser* p):
	mm_space(p)
	char* word = mm_identifier(p)
	if (strcmp(word, c"LR") == 0 || strcmp(word, c"TD") == 0): mm_config_set(p.doc, c"timeline.direction", word)
	else: mm_error(p.doc, p.pos, c"timeline direction must be LR or TD")
	free(word)

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

# Minute-unit charts end at 4000-12-31 and second-unit charts at 2037-12-31,
# so every moment fits a 32-bit int.
const int MM_N_MINUTE_YEAR_LIMIT = 4000
const int MM_N_SECOND_YEAR_LIMIT = 2037

# Chart units per day: days, minutes or seconds.
int mm_n_per_day(mm_gantt_settings* g):
	if (g.minutes == 1): return 1440
	if (g.minutes == 2): return 86400
	return 1

# Seconds per chart unit.
int mm_n_unit_seconds(mm_gantt_settings* g):
	if (g.minutes == 1): return 60
	if (g.minutes == 2): return 1
	return 86400

int mm_n_year_limit(mm_gantt_settings* g):
	if (g.minutes == 1): return MM_N_MINUTE_YEAR_LIMIT
	if (g.minutes == 2): return MM_N_SECOND_YEAR_LIMIT
	return 9999

int mm_n_unit_limit(mm_gantt_settings* g):
	if (g.minutes == 0): return mm_n_days(9999, 12, 31)
	return (mm_n_days(mm_n_year_limit(g), 12, 31) + 1) * mm_n_per_day(g)

# Civil date of a day number: [year, month, day, day of year (1-based)].
list[int] mm_n_civil(int days):
	int year = 1970
	while (days >= 365 + mm_n_leap(year)):
		days = days - 365 - mm_n_leap(year)
		year = year + 1
	int ordinal = days + 1
	int month = 1
	while (month < 12 && days >= mm_n_month_length(year, month)):
		days = days - mm_n_month_length(year, month)
		month = month + 1
	return list[int]{year, month, days + 1, ordinal}

# Calendar month arithmetic as dayjs `add(n, 'M')`: the day clamps to the
# target month's length. Returns past the unit limit when out of range.
int mm_n_add_months(mm_gantt_settings* g, int value, int months):
	int per = mm_n_per_day(g)
	int limit = mm_n_unit_limit(g) + 1
	int day = value / per
	int rest = value % per
	list[int] civil = mm_n_civil(day)
	int total = civil[0] * 12 + civil[1] - 1 + months
	int year = total / 12
	int month = total % 12 + 1
	int date = civil[2]
	__w_list_free(cast(__w_list*, civil))
	if (year > mm_n_year_limit(g)): return limit
	if (date > mm_n_month_length(year, month)): date = mm_n_month_length(year, month)
	int result = mm_n_days(year, month, date)
	if (result < 0): return limit
	return result * per + rest

# moment.js/dayjs dateFormat tokens: the token width at format, 0 for a
# literal byte, -1 for an unsupported token. `Do` and `[...]` are handled
# by the callers.
int mm_n_format_token(char* format):
	int c = format[0]
	int run = 1
	while (format[run] == c && run < 4): run = run + 1
	if (c == 'Y'):
		if (run >= 4): return 4
		if (run >= 2): return 2
		return -1
	if (c == 'M' || c == 'D' || c == 'd'):
		if (c == 'D' && run == 1 && format[1] == 'o'): return 2
		return run
	if (c == 'S'):
		if (run > 3): return 3
		return run
	if (c == 'H' || c == 'h' || c == 'k' || c == 'm' || c == 's' || c == 'Z'):
		if (run > 2): return 2
		return run
	if (c == 'A' || c == 'a' || c == 'X' || c == 'x' || c == 'Q'): return 1
	# Week-based and era tokens are not supported; other letters (such as
	# the `T` of ISO 8601) are literals, as in moment.js.
	if (c == 'w' || c == 'W' || c == 'g' || c == 'G' || c == 'E' || c == 'e' || c == 'N' || c == 'n'): return -1
	return 0

# Returns 0 for a date format, 1 for a minute format, 2 for a second format,
# -1 when unsupported. Date-less formats anchor at 1970-01-01.
int mm_n_format_kind(char* format):
	list[int] counts = list[int]{0, 0, 0, 0, 0}
	int i = 0
	int valid = 1
	int kind = 0
	int tokens = 0
	while (format[i] != 0 && valid):
		if (format[i] == '['):
			int close = index_of(format + i, c"]")
			if (close < 0): valid = 0
			else: i = i + close + 1
			continue
		int width = mm_n_format_token(format + i)
		if (width < 0): valid = 0
		if (width <= 0):
			i = i + 1
			continue
		int c = format[i]
		tokens = tokens + 1
		if (c == 'Y'): counts[0] = counts[0] + 1
		if (c == 'M' || c == 'Q'): counts[1] = counts[1] + 1
		if (c == 'D'): counts[2] = counts[2] + 1
		if ((c == 'H' || c == 'h' || c == 'k' || c == 'm' || c == 'A' || c == 'a' || c == 'Z') && kind < 1): kind = 1
		if (c == 's' || c == 'S' || c == 'X' || c == 'x'): kind = 2
		if (c == 'X' || c == 'x'): counts[3] = counts[3] + 1
		i = i + width
	if (valid == 0 || tokens == 0 || counts[0] > 1 || counts[1] > 1 || counts[2] > 1 || counts[3] > 1): kind = -1
	__w_list_free(cast(__w_list*, counts))
	return kind

# Reads up to `most` (at least `least`) digits at text[*at]; -1 when absent.
int mm_n_read_digits(char* text, int* at, int least, int most):
	int value = 0
	int count = 0
	while (count < most && text[*at + count] >= '0' && text[*at + count] <= '9'):
		value = value * 10 + text[*at + count] - '0'
		count = count + 1
	if (count < least): return -1
	*at = *at + count
	return value

# English month or weekday name (prefix of `length` letters, or the full
# name when length is 0) at text[*at]; returns the 1-based index or -1.
int mm_n_read_name(char* text, int* at, list[char*] names, int length):
	int end = *at
	while (isalpha(text[end])): end = end + 1
	int size = end - *at
	for k in range(names.length):
		char* name = names[k]
		int full = strlen(name)
		int ok = (length == 0 && size == full) || (length > 0 && size == length) || (length < 0 && size >= 2 && size <= full)
		for j in range(size):
			if (ok && (j >= full || tolower(text[*at + j]) != tolower(name[j]))): ok = 0
		if (ok):
			*at = end
			return k + 1
	return -1

# Unix seconds (X, optional fraction) or milliseconds (x) at text[*at];
# -1 when absent or beyond 2^31 seconds.
int mm_n_read_unix(char* text, int* at, int milliseconds):
	int value = 0
	int count = 0
	int dropped = 0
	while (text[*at] >= '0' && text[*at] <= '9'):
		int digit = text[*at] - '0'
		int keep = 1
		if (milliseconds):
			# The last three digits are the sub-second part.
			int remaining = 0
			while (text[*at + 1 + remaining] >= '0' && text[*at + 1 + remaining] <= '9'): remaining = remaining + 1
			if (remaining < 3): keep = 0
		if (keep):
			if (value > (2147483647 - digit) / 10): return -1
			value = value * 10 + digit
		else: dropped = dropped + 1
		count = count + 1
		*at = *at + 1
	if (count == 0): return -1
	if (milliseconds == 0 && text[*at] == '.'):
		*at = *at + 1
		if (mm_n_read_digits(text, at, 1, 9) < 0): return -1
	return value

# Parses text with the active dateFormat into chart units (UTC; an explicit
# Z/ZZ offset is converted to UTC), or returns -1.
int mm_n_moment(mm_gantt_settings* g, char* text):
	char* format = g.date_format
	list[char*] months = list[char*]{c"january", c"february", c"march", c"april", c"may", c"june", c"july", c"august", c"september", c"october", c"november", c"december"}
	list[char*] weekdays = list[char*]{c"sunday", c"monday", c"tuesday", c"wednesday", c"thursday", c"friday", c"saturday"}
	# year, month, day, day of year, hour, minute, second, pm, quarter, offset minutes, unix, twelve-hour, k-hour
	list[int] parts = list[int]{1970, -1, -1, -1, 0, 0, 0, -1, -1, 0, -1, 0, 0}
	int i = 0
	int j = 0
	int valid = 1
	while (format[i] != 0 && valid):
		if (format[i] == '['):
			int close = i + index_of(format + i, c"]")
			for k in range(i + 1, close):
				if (valid && text[j] != format[k]): valid = 0
				if (valid): j = j + 1
			i = close + 1
			continue
		int width = mm_n_format_token(format + i)
		if (width <= 0):
			if (text[j] != format[i]): valid = 0
			i = i + 1
			j = j + 1
			continue
		int c = format[i]
		int value = 0
		if (c == 'Y'):
			value = mm_n_read_digits(text, &j, width, width)
			if (width == 2 && value >= 0):
				if (value > 68): value = value + 1900
				else: value = value + 2000
			parts[0] = value
		else if (c == 'M' && width >= 3):
			int length = 3
			if (width == 4): length = 0
			value = mm_n_read_name(text, &j, months, length)
			parts[1] = value
		else if (c == 'M'):
			value = mm_n_read_digits(text, &j, width, 2)
			parts[1] = value
		else if (c == 'D' && format[i + 1] == 'o'):
			value = mm_n_read_digits(text, &j, 1, 2)
			if (value >= 0 && isalpha(text[j]) && isalpha(text[j + 1])): j = j + 2
			parts[2] = value
		else if (c == 'D' && width >= 3):
			int least = 1
			if (width == 4): least = 3
			value = mm_n_read_digits(text, &j, least, 3)
			parts[3] = value
		else if (c == 'D'):
			value = mm_n_read_digits(text, &j, width, 2)
			parts[2] = value
		else if (c == 'd'):
			if (width == 1): value = mm_n_read_digits(text, &j, 1, 1)
			else: value = mm_n_read_name(text, &j, weekdays, -1)
		else if (c == 'H' || c == 'h' || c == 'k'):
			value = mm_n_read_digits(text, &j, width, 2)
			parts[4] = value
			if (c == 'h'): parts[11] = 1
			if (c == 'k'): parts[12] = 1
		else if (c == 'm'):
			value = mm_n_read_digits(text, &j, width, 2)
			parts[5] = value
		else if (c == 's'):
			value = mm_n_read_digits(text, &j, width, 2)
			parts[6] = value
		else if (c == 'S'): value = mm_n_read_digits(text, &j, width, width)
		else if (c == 'A' || c == 'a'):
			value = -1
			if ((text[j] == 'A' || text[j] == 'a') && (text[j + 1] == 'M' || text[j + 1] == 'm')): value = 0
			if ((text[j] == 'P' || text[j] == 'p') && (text[j + 1] == 'M' || text[j + 1] == 'm')): value = 1
			if (value >= 0): j = j + 2
			parts[7] = value
		else if (c == 'Q'):
			value = mm_n_read_digits(text, &j, 1, 1)
			if (value < 1 || value > 4): value = -1
			parts[8] = value
		else if (c == 'X' || c == 'x'):
			value = mm_n_read_unix(text, &j, c == 'x')
			parts[10] = value
		else if (c == 'Z'):
			value = -1
			if (text[j] == 'Z'):
				value = 0
				j = j + 1
				parts[9] = 0
			else if (text[j] == '+' || text[j] == '-'):
				int sign = 1
				if (text[j] == '-'): sign = -1
				j = j + 1
				int hours = mm_n_read_digits(text, &j, 2, 2)
				if (text[j] == ':'): j = j + 1
				int minutes = mm_n_read_digits(text, &j, 2, 2)
				if (hours >= 0 && minutes >= 0 && hours <= 14 && minutes <= 59):
					value = 0
					parts[9] = sign * (hours * 60 + minutes)
		if (value < 0): valid = 0
		i = i + width
	if (valid && text[j] != 0): valid = 0
	int result = -1
	int per = mm_n_per_day(g)
	if (valid && parts[10] >= 0):
		# Unix timestamps are UTC seconds since the epoch.
		result = parts[10] / mm_n_unit_seconds(g)
	else if (valid):
		int year = parts[0]
		int month = parts[1]
		if (month < 0 && parts[8] > 0): month = (parts[8] - 1) * 3 + 1
		if (month < 0): month = 1
		int day = parts[2]
		if (day < 0): day = 1
		int hour = parts[4]
		if (parts[11] || parts[7] >= 0):
			if (hour < 1 || hour > 12): hour = 99
			else: hour = hour % 12 + 12 * (parts[7] == 1)
		if (parts[12] && hour == 24): hour = 0
		if (hour <= 23 && parts[5] <= 59 && parts[6] <= 59 && year <= mm_n_year_limit(g)):
			if (parts[3] >= 0):
				if (parts[3] >= 1 && parts[3] <= 365 + mm_n_leap(year) && year >= 1970): result = mm_n_days(year, 1, 1) + parts[3] - 1
			else: result = mm_n_days(year, month, day)
		if (result >= 0 && g.minutes == 1): result = result * 1440 + hour * 60 + parts[5] - parts[9]
		if (result >= 0 && g.minutes == 2): result = result * 86400 + hour * 3600 + parts[5] * 60 + parts[6] - parts[9] * 60
	if (result < 0 || result > mm_n_unit_limit(g)): result = -1
	__w_list_free(cast(__w_list*, parts))
	__w_list_free(cast(__w_list*, months))
	__w_list_free(cast(__w_list*, weekdays))
	return result

# Duration `<number><unit>` with units ms, s, m, h, d, w, M and y and an
# optional decimal fraction. Returns the unit index (0 ms ... 7 y) and the
# value in thousandths through *milli, or -1 when the text is no duration.
int mm_n_span_parse(char* text, int* milli):
	int length = strlen(text)
	int unit = -1
	int suffix = 1
	if (length >= 3 && text[length - 2] == 'm' && text[length - 1] == 's'):
		unit = 0
		suffix = 2
	else if (length >= 2):
		int c = text[length - 1]
		if (c == 's'): unit = 1
		if (c == 'm'): unit = 2
		if (c == 'h'): unit = 3
		if (c == 'd'): unit = 4
		if (c == 'w'): unit = 5
		if (c == 'M'): unit = 6
		if (c == 'y'): unit = 7
	if (unit < 0): return -1
	int whole = 0
	int fraction = 0
	int scale = 100
	int digits = 0
	int dot = 0
	for i in range(length - suffix):
		int c = text[i]
		if (c == '.' && dot == 0): dot = 1
		else if (c >= '0' && c <= '9'):
			if (dot == 0):
				if (whole > 2000000): return -1
				whole = whole * 10 + c - '0'
			else:
				fraction = fraction + (c - '0') * scale
				scale = scale / 10
			digits = digits + 1
		else: return -1
	if (digits == 0 || whole > 2000000): return -1
	*milli = whole * 1000 + fraction
	return unit

# Seconds per duration unit below months (ms is handled by the caller).
int mm_n_span_unit_seconds(int unit):
	if (unit == 1): return 1
	if (unit == 2): return 60
	if (unit == 3): return 3600
	if (unit == 4): return 86400
	return 604800

# Non-calendar duration in units of `unit_seconds`, rounded up; -1 when it
# is no such duration or too long. *exact reports whether no rounding happened.
int mm_n_span_units(char* text, int unit_seconds, int* exact):
	int milli = 0
	int unit = mm_n_span_parse(text, &milli)
	*exact = 1
	if (unit < 0 || unit > 5): return -1
	int whole = milli / 1000
	int fraction = milli % 1000
	int maximum = 3660 * (86400 / unit_seconds)
	if (unit_seconds == 86400): maximum = 365000
	if (unit == 0):
		# Milliseconds round up to whole seconds first.
		int seconds = whole / 1000
		if (whole % 1000 != 0 || fraction != 0): seconds = seconds + 1
		if (whole % 1000 != 0 || fraction != 0): *exact = 0
		int result = seconds / unit_seconds
		if (seconds % unit_seconds != 0):
			result = result + 1
			*exact = 0
		return result
	int per = mm_n_span_unit_seconds(unit)
	if (per % unit_seconds == 0):
		int factor = per / unit_seconds
		if (whole > maximum / factor): return -1
		int part = fraction * factor
		int result = whole * factor + part / 1000
		if (part % 1000 != 0):
			result = result + 1
			*exact = 0
		if (result > maximum): return -1
		return result
	# A unit smaller than the chart unit: count seconds, then round up.
	if (whole > 2000000000 / per): return -1
	int seconds = whole * per + fraction * per / 1000
	if ((fraction * per) % 1000 != 0):
		seconds = seconds + 1
		*exact = 0
	int result = seconds / unit_seconds
	if (seconds % unit_seconds != 0):
		result = result + 1
		*exact = 0
	if (result > maximum): return -1
	return result

# Calendar months of an `M`/`y` duration (whole months only), else -1.
int mm_n_span_months(char* text):
	int milli = 0
	int unit = mm_n_span_parse(text, &milli)
	if (unit == 6 && milli % 1000 == 0 && milli <= 120000000): return milli / 1000
	if (unit == 7 && (milli * 12) % 1000 == 0 && milli <= 10000000): return milli * 12 / 1000
	return -1

# Any duration the task grammar accepts (used to tell IDs from durations).
int mm_n_is_span(char* text):
	int milli = 0
	return mm_n_span_parse(text, &milli) >= 0

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
	int per = mm_n_per_day(g)
	int first = a / per
	int last = b / per
	if (first == last):
		if (mm_n_excluded_day(g, first)): return 0
		return b - a
	# Whole working days, counted in days first so seconds charts cannot overflow.
	int days = mm_n_working_days(g, first + 1, last)
	if (days > 2147483647 / per): return 2147483647
	int total = days * per
	if (mm_n_excluded_day(g, first) == 0): total = total + (first + 1) * per - a
	if (b > last * per && mm_n_excluded_day(g, last) == 0): total = total + b - last * per
	return total

# Duration-based ends skip excluded days; returns past the limit when none fit.
int mm_n_finish(mm_gantt_settings* g, int start, int duration):
	int limit = mm_n_unit_limit(g) + 1
	if (duration > limit - start): return limit
	if (duration == 0 || (g.weekday_mask == 0 && g.excluded.length == 0)): return start + duration
	if (mm_n_working_units(g, start, limit) < duration): return limit
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
	if (day >= 0 && g.minutes): return day / mm_n_per_day(g)
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

# d3-time-format directives accepted for axis labels (all of d3's), with
# the optional `-`, `_` and `0` padding modifiers.
int mm_n_axis_valid(char* format):
	char* tokens = c"aAbBcdefgGHIjLmMpqQsSuUVwWxXyYZ%"
	int i = 0
	while (format[i] != 0):
		if (format[i] == '%'):
			if (format[i + 1] == '-' || format[i + 1] == '_' || format[i + 1] == '0'): i = i + 1
			int known = 0
			int k = 0
			while (tokens[k] != 0):
				if (format[i + 1] == tokens[k]): known = 1
				k = k + 1
			if (known == 0): return 0
			i = i + 1
		i = i + 1
	return 1

# `tickInterval <n><unit>` as upstream's /^([1-9][0-9]*)(millisecond|second|
# minute|hour|day|week|month)$/; other text is accepted and ignored, as upstream.
void mm_n_tick_interval(mm_gantt_settings* g, char* text):
	list[char*] units = list[char*]{c"millisecond", c"second", c"minute", c"hour", c"day", c"week", c"month"}
	int digits = 0
	while (isdigit(text[digits])): digits = digits + 1
	g.tick_count = 0
	g.tick_unit = 0
	if (digits > 0 && digits <= 6 && text[0] != '0'):
		for k in range(units.length):
			if (strcmp(text + digits, units[k]) == 0):
				char* number = str_copy_range(text, 0, digits)
				g.tick_count = atoi(number)
				g.tick_unit = k + 1
				free(number)
	__w_list_free(cast(__w_list*, units))

# Weekday name (case-insensitive) to 0 = Sunday ... 6, or -1.
int mm_n_weekday_index(char* text):
	list[char*] names = list[char*]{c"sunday", c"monday", c"tuesday", c"wednesday", c"thursday", c"friday", c"saturday"}
	int result = -1
	for k in range(7):
		if (mm_n_same_word(text, names[k])): result = k
	__w_list_free(cast(__w_list*, names))
	return result

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
	else if (mm_n_prefix(text, c"tickInterval ")):
		char* value = mm_n_trim(text + 13)
		mm_n_tick_interval(g, value)
		free(value)
	else if (mm_n_prefix(text, c"weekday ")):
		char* value = mm_n_trim(text + 8)
		int day = mm_n_weekday_index(value)
		if (day < 0): mm_error(p.doc, p.pos, c"Gantt weekday must name a day of the week")
		else: g.week_start = day
		free(value)
	else if (strcmp(text, c"inclusiveEndDates") == 0):
		if (p.doc.narrative.length != 0): mm_error(p.doc, p.pos, c"Gantt inclusiveEndDates must precede tasks")
		g.inclusive = 1
	else if (strcmp(text, c"topAxis") == 0): g.top_axis = 1
	else: return 0
	return 1

void mm_n_gantt_finish_settings(mm_parser* p):
	mm_gantt_settings* g = mm_n_gantt_settings(p.doc)
	char* configured = mm_config_value(p.doc, c"gantt.axisFormat")
	if (configured != 0 && (configured[0] == 0 || mm_n_axis_valid(configured) == 0)): mm_error(p.doc, 0, c"unsupported Gantt axisFormat")
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
	list[int] until_indices
	int previous
	int duration
	int offset
	# Calendar months of an M/y duration (duration is then unused).
	int months
	# The duration is in minutes although the chart was still in days.
	int minute_duration

int mm_n_dependency_index(mm_parser* p, char* id, int offset):
	for i in range(p.doc.narrative.length):
		mm_narrative_event* task = p.doc.narrative[i]
		if (task.detail[0] != 0 && strcmp(task.detail, id) == 0): return i
	mm_error(p.doc, offset, c"unknown Gantt dependency")
	return -1

void mm_n_id_indices(mm_parser* p, char* ids, list[int] indices, int offset):
	int at = 0
	while (ids[at] != 0):
		while (ids[at] == 32 || ids[at] == 9): at = at + 1
		int start = at
		while (ids[at] != 0 && ids[at] != 32 && ids[at] != 9): at = at + 1
		if (at == start): break
		char* id = str_copy_range(ids, start, at)
		int index = mm_n_dependency_index(p, id, offset)
		free(id)
		if (index >= 0): indices.push(index)

# Resolve names once, so reverse dependency chains do not repeatedly scan IDs.
# `until a b` ends at the earliest start of the listed tasks, as upstream.
void mm_n_schedule_indices(mm_parser* p, list[mm_n_schedule*] schedules):
	for mm_n_schedule* item in schedules:
		mm_n_id_indices(p, item.dependencies, item.dependency_indices, item.offset)
		mm_n_id_indices(p, item.until, item.until_indices, item.offset)

# A sub-day duration in a day-unit chart switches the chart to minutes:
# resolved moments and day durations scale by 1440; excluded days stay days.
void mm_n_promote_gantt(mm_parser* p, list[mm_n_schedule*] schedules):
	mm_gantt_settings* g = mm_n_gantt_settings(p.doc)
	int promote = 0
	for mm_n_schedule* item in schedules:
		if (item.minute_duration): promote = 1
	if (promote == 0 || g.minutes != 0): return
	for mm_n_schedule* item in schedules:
		mm_narrative_event* task = item.task
		if (task.start > mm_n_days(MM_N_MINUTE_YEAR_LIMIT, 12, 31) || task.end > mm_n_days(MM_N_MINUTE_YEAR_LIMIT, 12, 31) + 1):
			mm_error(p.doc, item.offset, c"Gantt end precedes start or exceeds supported calendar")
			return
		if (task.start >= 0): task.start = task.start * 1440
		if (task.end >= 0): task.end = task.end * 1440
		if (item.minute_duration == 0 && item.duration > 0): item.duration = item.duration * 1440
	if (g.today >= 0 && g.today <= mm_n_days(MM_N_MINUTE_YEAR_LIMIT, 12, 31)): g.today = g.today * 1440
	else: g.today = -1
	g.minutes = 1
	g.promoted = 1

void mm_n_resolve_gantt(mm_parser* p, list[mm_n_schedule*] schedules):
	# Resolve starts and ends independently: an until edge needs only a start.
	mm_n_schedule_indices(p, schedules)
	if (p.doc.error == 0): mm_n_promote_gantt(p, schedules)
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
				if (item.until_indices.length > 0):
					for int index in item.until_indices:
						mm_narrative_event* dependency = p.doc.narrative[index]
						if (dependency.start < 0):
							finish = -2
						else if (finish != -2 && (finish < 0 || dependency.start < finish)): finish = dependency.start
					if (finish == -2): finish = -1
				else if (task.start >= 0 && item.months > 0):
					int calendar = mm_n_add_months(g, task.start, item.months)
					finish = mm_n_finish(g, task.start, calendar - task.start)
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
		else if (strcmp(field, c"vert") == 0): status = status | 16
		else: break
		at = at + 1
	char* id = strclone(c"")
	if (at < fields.length && mm_n_moment(g, fields[at]) < 0 && mm_n_is_span(fields[at]) == 0 && mm_n_prefix(fields[at], c"after ") == 0 && mm_n_prefix(fields[at], c"until ") == 0):
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
	int months = 0
	int minute_duration = 0
	char* until = strclone(c"")
	if (at < fields.length):
		finish = mm_n_moment(g, fields[at])
		if (finish >= 0 && g.inclusive):
			finish = finish + mm_n_per_day(g)
			if (finish > mm_n_unit_limit(g)): finish = -1
		if (finish < 0):
			int exact = 1
			duration = mm_n_span_units(fields[at], mm_n_unit_seconds(g), &exact)
			if (duration > 0 && exact == 0 && g.minutes == 0):
				# Sub-day durations in a day chart: keep minutes and promote at resolve.
				duration = mm_n_span_units(fields[at], 60, &exact)
				minute_duration = 1
			if (duration == 0 && (status & 24) == 0): duration = -1
			if (duration < 0):
				months = mm_n_span_months(fields[at])
				if (months > 0): duration = 0
				else: months = 0
			if (mm_n_prefix(fields[at], c"until ")):
				free(until)
				until = mm_n_trim(fields[at] + 6)
				if (until[0] == 0): mm_error(p.doc, p.pos, c"Gantt until requires task identifiers")
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
			schedule.until_indices = new list[int]
			schedule.previous = previous
			schedule.duration = duration
			schedule.months = months
			schedule.minute_duration = minute_duration
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

# Per-parse ZenUML state, reset by mm_narrative_body: the `@Starter(Name)`
# participant (-1 = External), a pending `@return`/`@reply` annotator, and the
# `//` comment lines waiting for the next message or fragment.
int mm_n_zen_starter
int mm_n_zen_return
string_builder* mm_n_zen_comment

# The innermost enclosing participant that is executing a call, else the
# `@Starter` participant, else External.
int mm_n_zen_sender(mm_parser* p, list[int] callers):
	int sender = -1
	for int actor in callers:
		if (actor >= 0): sender = actor
	if (sender < 0 && mm_n_zen_starter >= 0): sender = mm_n_zen_starter
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
	# `new A1` creates without arguments.
	if (open < 0 && mm_n_method(call)): open = strlen(call)
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

# ZenUML cloud annotators from zenuml.md's annotator chart (AWS, Azure and
# Google Cloud), as "name caption color" rows. Natively each draws as a tile in
# its provider's category colour with a short caption; the vendor artwork
# itself is not reproduced.
char* mm_n_zen_icons():
	return c"cloudwatch CW e7157b|cloudfront CF 8c4fff|cognito Cog dd344c|dynamodb DDB 4d72f3|ebs EBS 7aa116|ec2 EC2 ed7100|ecs ECS ed7100|efs EFS 7aa116|elasticache EC 4d72f3|elasticbeantalk EB ed7100|elasticfilesystem EFS 7aa116|glacier Gla 7aa116|iam IAM dd344c|kinesis Kin 8c4fff|lambda Fn ed7100|lightsail LS ed7100|rds RDS 4d72f3|redshift RS 8c4fff|s3 S3 7aa116|sns SNS e7157b|sqs SQS e7157b|sagemaker SM 01a88d|vpc VPC 8c4fff|azureactivedirectory AAD 0078d4|azurebackup Bak 0078d4|azurecdn CDN 0078d4|azuredatafactory ADF 0078d4|azuredevops ADO 0078d4|azurefunction AF 0078d4|azuresql SQL 0078d4|cosmosdb CDB 0078d4|logicapps LA 0078d4|virtualmachine VM 0078d4|bigtable BT 4285f4|bigquery BQ 4285f4|cloudcdn CDN 4285f4|clouddns DNS 4285f4|cloudinterconnect IC 4285f4|cloudloadbalancing LB 4285f4|cloudsql SQL 4285f4|cloudstorage GCS 4285f4|datalab DL 4285f4|dataproc DP 4285f4|googleiam IAM 4285f4|googlesecurity Sec 4285f4|googlevpc VPC 4285f4|pubsub PS 4285f4|securityscanner SS 4285f4|stackdriver SD 4285f4|visionapi VAI 4285f4"

# The owned caption of a ZenUML cloud annotator (case-insensitive) and its
# tile colour in *color, or 0 when kind is no cloud annotator.
char* mm_n_zen_icon(char* kind, int* color):
	char* table = mm_n_zen_icons()
	int length = strlen(kind)
	int at = 0
	while (table[at] != 0):
		int same = 1
		for i in range(length):
			if (same && tolower(kind[i]) != table[at + i]): same = 0
		if (same && table[at + length] == ' '):
			int start = at + length + 1
			int stop = start
			while (table[stop] != ' '): stop = stop + 1
			int value = 0
			for i in range(6): value = value * 16 + mm_style_hex(table[stop + 1 + i])
			*color = value
			return str_copy_range(table, start, stop)
		while (table[at] != 0 && table[at] != '|'): at = at + 1
		if (table[at] == '|'): at = at + 1
	return 0

# A ZenUML participant declaration after its optional `@Annotation`:
# `[<<Stereotype>>] name [width] [as Label] [#color]` (the ZenUML grammar's
# participant rule). The stereotype is kept in node.role, the width in
# node.value_x and the colour as the node's fill.
void mm_n_zen_participant(mm_parser* p, char* annotation, char* text):
	char* rest = mm_n_trim(text)
	char* stereotype = 0
	int color = -3
	int width = 0
	if (mm_n_prefix(rest, c"<<")):
		int close = index_of(rest, c">>")
		if (close >= 0): stereotype = mm_n_part(rest, 2, close)
		if (close < 0 || stereotype[0] == 0 || mm_n_method(stereotype) == 0 || index_of(stereotype, c"(") >= 0):
			mm_error(p.doc, p.pos, c"ZenUML stereotype requires <<Name>>")
			if (stereotype != 0): free(stereotype)
			free(rest)
			return
		char* after = mm_n_trim(rest + close + 2)
		free(rest)
		rest = after
	int length = strlen(rest)
	int hash = length - 1
	while (hash > 0 && rest[hash] != '#' && rest[hash] != ' ' && rest[hash] != 9): hash = hash - 1
	if (hash > 0 && rest[hash] == '#' && (rest[hash - 1] == ' ' || rest[hash - 1] == 9)):
		color = mm_style_color(rest + hash)
		if (color < 0):
			mm_error(p.doc, p.pos, c"ZenUML participant colour must be #rgb or #rrggbb")
			if (stereotype != 0): free(stereotype)
			free(rest)
			return
		rest[hash] = 0
		char* before = mm_n_trim(rest)
		free(rest)
		rest = before
	# A width follows the name: `name 200 [as Label]`.
	int word = 0
	while (rest[word] != 0 && rest[word] != ' ' && rest[word] != 9): word = word + 1
	int digits = word
	while (rest[digits] == ' ' || rest[digits] == 9): digits = digits + 1
	int number = digits
	while (rest[number] >= '0' && rest[number] <= '9'): number = number + 1
	if (number > digits && (rest[number] == 0 || rest[number] == ' ' || rest[number] == 9)):
		if (number - digits > 4): width = 10000
		else:
			for i in range(digits, number): width = width * 10 + rest[i] - '0'
		if (width < 1 || width > 2000):
			mm_error(p.doc, p.pos, c"ZenUML participant width must be 1 to 2000")
			if (stereotype != 0): free(stereotype)
			free(rest)
			return
		string_builder* without = string_new()
		for i in range(word): string_append_char(without, rest[i])
		string_append(without, rest + number)
		free(rest)
		rest = without.data
		free(without)
	int actor = 0
	if (annotation != 0):
		char* lower = strclone(annotation)
		for i in range(strlen(lower)): lower[i] = tolower(lower[i])
		actor = strcmp(lower, c"actor") == 0
		free(lower)
	int index = mm_n_declare(p, rest, actor)
	free(rest)
	if (index < 0 || p.doc.error != 0):
		if (stereotype != 0): free(stereotype)
		return
	mm_node* node = p.doc.nodes[index]
	if (stereotype != 0):
		free(node.role)
		node.role = stereotype
	if (width > 0): node.value_x = width
	if (color >= 0):
		node.style.mask = node.style.mask | MM_STYLE_FILL
		node.style.fill = color
	if (annotation == 0 || actor): return
	free(node.annotation)
	node.annotation = strclone(annotation)
	# Annotators with a UML symbol draw it, cloud annotators an icon tile;
	# others keep the stereotype line.
	char* lower = strclone(annotation)
	for i in range(strlen(lower)): lower[i] = tolower(lower[i])
	int tile = 0
	char* caption = mm_n_zen_icon(lower, &tile)
	if (strcmp(lower, c"boundary") == 0): node.shape = 2
	else if (strcmp(lower, c"control") == 0): node.shape = 3
	else if (strcmp(lower, c"entity") == 0): node.shape = 4
	else if (strcmp(lower, c"database") == 0): node.shape = 5
	else if (strcmp(lower, c"collections") == 0 || strcmp(lower, c"collection") == 0): node.shape = 6
	else if (strcmp(lower, c"queue") == 0): node.shape = 7
	else if (caption != 0): node.shape = 8
	if (caption != 0): free(caption)
	free(lower)

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
	if (strcmp(text, c"@return") == 0 || strcmp(text, c"@reply") == 0):
		mm_n_zen_return = 1
		return
	if (mm_n_prefix(text, c"@Starter(")):
		int length = strlen(text)
		char* name = 0
		if (text[length - 1] == ')'): name = mm_n_part(text, 9, length - 1)
		if (name == 0 || name[0] == 0 || mm_n_zen_starter >= 0): mm_error(p.doc, p.pos, c"ZenUML @Starter takes one participant, once")
		else: mm_n_zen_starter = mm_n_actor(p, name)
		if (name != 0): free(name)
		return
	if (mm_n_zen_return && (index_of(text, c"->") < 0 || index_of(text, c":") < 0)):
		mm_error(p.doc, p.pos, c"ZenUML @return must precede an async message")
		return
	if (text[0] == '@'):
		int at = 1
		while (mm_id_char(text[at] & 255)): at = at + 1
		if (at == 1 || (text[at] != ' ' && text[at] != 9) || mm_id_char(text[1] & 255) == 0 || (text[1] >= '0' && text[1] <= '9')):
			mm_error(p.doc, p.pos, c"unsupported ZenUML annotation")
			return
		char* annotation = str_copy_range(text, 1, at)
		mm_n_zen_participant(p, annotation, text + at + 1)
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
		int first = p.doc.narrative.length
		mm_n_message(p, text, 1)
		if (mm_n_zen_return && p.doc.narrative.length > first):
			# `@return` turns the async message into a dashed reply.
			mm_narrative_event* reply = p.doc.narrative[first]
			reply.dashed = 1
			reply.arrow = 1
		mm_n_zen_return = 0
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
		else: mm_n_zen_participant(p, 0, text)
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
	if (mm_n_prefix(text, c"//")):
		# Comments render above the next message or fragment (Markdown emphasis kept).
		char* comment = mm_n_trim(text + 2)
		if (mm_n_zen_comment.length + strlen(comment) > 4096): mm_error(p.doc, p.pos, c"ZenUML comment limit exceeded")
		else if (comment[0] != 0):
			if (mm_n_zen_comment.length != 0): string_append_char(mm_n_zen_comment, 10)
			string_append(mm_n_zen_comment, comment)
		free(comment)
		return
	int first = p.doc.narrative.length
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
	if (mm_n_zen_comment.length == 0): return
	if (p.doc.narrative.length == first && (strcmp(text, c"@return") == 0 || strcmp(text, c"@reply") == 0)): return
	# Comments elsewhere (on declarations, closing braces) are dropped, as upstream.
	for i in range(first, p.doc.narrative.length):
		mm_narrative_event* event = p.doc.narrative[i]
		if (event.kind == MM_N_MESSAGE || event.kind == MM_N_BLOCK):
			free(event.detail)
			event.detail = strclone(mm_n_zen_comment.data)
			break
	string_free(mm_n_zen_comment)
	mm_n_zen_comment = string_new()

void mm_narrative_body(mm_parser* p):
	char* section = strclone(c"")
	list[int] blocks = new list[int]
	list[int] callers = new list[int]
	list[char*] replies = new list[char*]
	list[mm_n_schedule*] schedules = new list[mm_n_schedule*]
	list[int] numbering = list[int]{0, 1, 1}
	mm_n_zen_starter = -1
	mm_n_zen_return = 0
	mm_n_zen_comment = string_new()
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
	if (p.doc.error == 0 && mm_n_zen_return): mm_error(p.doc, p.pos, c"ZenUML @return must precede an async message")
	string_free(mm_n_zen_comment)
	mm_n_zen_comment = 0
	if (p.doc.error == 0 && p.doc.kind == MM_SEQUENCE): mm_n_validate_lifetimes(p)
	if (p.doc.error == 0 && p.doc.kind == MM_GANTT): mm_n_gantt_finish_settings(p)
	if (p.doc.error == 0 && p.doc.kind == MM_GANTT): mm_n_resolve_gantt(p, schedules)
	for mm_n_schedule* item in schedules:
		free(item.dependencies)
		free(item.until)
		__w_list_free(cast(__w_list*, item.dependency_indices))
		__w_list_free(cast(__w_list*, item.until_indices))
		free(item)
	__w_list_free(cast(__w_list*, schedules))
	__w_list_free(cast(__w_list*, numbering))
	free(section)
	__w_list_free(cast(__w_list*, blocks))
	__w_list_free(cast(__w_list*, callers))
	for char* reply in replies: free(reply)
	__w_list_free(cast(__w_list*, replies))
