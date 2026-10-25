# Responsibility lanes and event-model timeframes keep their own semantics.
import libs.extras.mermaid.frameworks
import libs.extras.mermaid.agentflow

# Swimlane nesting depth bound (lanes plus nested clusters).
const int MM_SWIM_MAX_DEPTH = 32

# Top-level lane holding a step or cluster, or -1.
int mm_swim_lane(mm_document* d, int index):
	int lane = -1
	int guard = 0
	while (index >= 0 && guard <= d.nodes.length):
		mm_node* n = d.nodes[index]
		if (n.group): lane = index
		index = n.parent
		guard = guard + 1
	return lane

int mm_swim_within(mm_document* d, int index, int ancestor):
	int guard = 0
	while (index >= 0 && guard <= d.nodes.length):
		if (index == ancestor): return 1
		mm_node* n = d.nodes[index]
		index = n.parent
		guard = guard + 1
	return 0

# Label text up to the closing delimiter; quoted labels may hold delimiters.
char* mm_swim_label(mm_parser* p, char* close, char* alternate):
	mm_space(p)
	char* text
	if (mm_peek(p) == '"'):
		text = mm_quoted(p)
		mm_space(p)
	else:
		int start = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10):
			int save = p.pos
			if (mm_match(p, close) || (alternate != 0 && mm_match(p, alternate))):
				p.pos = save
				break
			p.pos = p.pos + 1
		int end = p.pos
		while (end > start && (p.doc.source[end - 1] & 255) <= 32): end = end - 1
		text = str_copy_range(p.doc.source, start, end)
	if (mm_match(p, close) == 0 && (alternate == 0 || mm_match(p, alternate) == 0)): mm_error(p.doc, p.pos, c"expected closing shape delimiter")
	return text

# Flowchart node shape syntax (the swimlane node forms).
void mm_swim_shape(mm_parser* p, mm_node* n):
	char* label = 0
	if (mm_match(p, c"(((")):
		label = mm_swim_label(p, c")))", 0)
		n.shape = MM_SHAPE_DOUBLE_CIRCLE
	else if (mm_match(p, c"((")):
		label = mm_swim_label(p, c"))", 0)
		n.shape = MM_SHAPE_CIRCLE
	else if (mm_match(p, c"([")):
		label = mm_swim_label(p, c"])", 0)
		n.shape = MM_SHAPE_STADIUM
	else if (mm_match(p, c"[(")):
		label = mm_swim_label(p, c")]", 0)
		n.shape = MM_SHAPE_CYLINDER
	else if (mm_match(p, c"[[")):
		label = mm_swim_label(p, c"]]", 0)
		n.shape = MM_SHAPE_FRAMED
	else if (mm_match(p, c"[/") || mm_match(p, c"[\\")):
		int opening = p.doc.source[p.pos - 1]
		label = mm_swim_label(p, c"/]", c"\\]")
		int ending = p.doc.source[p.pos - 2]
		n.shape = MM_SHAPE_LEAN_RIGHT
		if (opening == '/' && ending == '\\'): n.shape = MM_SHAPE_TRAP_BOTTOM
		if (opening == '\\' && ending == '\\'): n.shape = MM_SHAPE_LEAN_LEFT
		if (opening == '\\' && ending == '/'): n.shape = MM_SHAPE_TRAP_TOP
	else if (mm_match(p, c"[")):
		label = mm_swim_label(p, c"]", 0)
		n.shape = MM_SHAPE_RECT
	else if (mm_match(p, c"(")):
		label = mm_swim_label(p, c")", 0)
		n.shape = MM_SHAPE_ROUNDED
	else if (mm_match(p, c"{{")):
		label = mm_swim_label(p, c"}}", 0)
		n.shape = MM_SHAPE_HEXAGON
	else if (mm_match(p, c"{")):
		label = mm_swim_label(p, c"}", 0)
		n.shape = MM_SHAPE_DIAMOND
	else if (mm_peek(p) == '>' && p.pos + 1 < p.doc.length && p.doc.source[p.pos + 1] != '>'):
		p.pos = p.pos + 1
		label = mm_swim_label(p, c"]", 0)
		n.shape = MM_SHAPE_ODD
	if (label != 0):
		free(n.label)
		n.label = label

# Node reference with optional shape, `@{ shape: ..., label: ... }` and `:::class`.
int mm_swim_node(mm_parser* p, int scope):
	int offset = p.pos
	char* id = mm_identifier(p)
	if (strcmp(id, c"end") == 0 || strcmp(id, c"subgraph") == 0): mm_error(p.doc, offset, c"unexpected swimlane keyword")
	int index = mm_add_node(p.doc, id, offset)
	free(id)
	if (index < 0 || p.doc.error != 0): return -1
	mm_node* n = p.doc.nodes[index]
	if (n.group): mm_error(p.doc, offset, c"edges must connect steps, not swimlane containers")
	if (scope >= 0):
		if (n.parent < 0): n.parent = scope
		else if (n.parent != scope):
			if (mm_swim_lane(p.doc, n.parent) != mm_swim_lane(p.doc, scope)): mm_error(p.doc, offset, c"step already belongs to another swimlane")
			# Flowchart semantics: a node named inside a nested cluster moves into it.
			else if (mm_swim_within(p.doc, scope, n.parent)): n.parent = scope
	n.declared = 1
	mm_swim_shape(p, n)
	list[mm_property*] props = mm_agent_block(p)
	if (props != 0):
		if (p.doc.error == 0): mm_agent_merge(p, n.metadata, props)
		for mm_property* property in props:
			if (p.doc.error != 0): break
			if (strcmp(property.key, c"shape") == 0):
				int shape = mm_shape_lookup(property.value)
				if (property.type != MM_VALUE_STRING || shape < 0): mm_error(p.doc, offset, c"unsupported swimlane node shape")
				else: n.shape = shape
			else if (strcmp(property.key, c"label") == 0 && property.type != MM_VALUE_NULL):
				free(n.label)
				n.label = strclone(property.value)
		mm_properties_free(props)
	if (mm_match(p, c":::")): mm_style_inline(p, n)
	return index

# Flowchart link operators: --> --- -.-> -.- ==> === with longer variants,
# x / o heads, a leading < for both ends, and inline `-- text -->` labels.
int mm_swim_link(mm_parser* p, mm_edge* e):
	int start = p.pos
	e.left_marker = mm_match(p, c"<")
	int c = mm_peek(p)
	if (c != '-' && c != '='):
		p.pos = start
		return 0
	int thick = c == '='
	int run = 0
	while (mm_peek(p) == c):
		p.pos = p.pos + 1
		run = run + 1
	if (c == '-' && mm_peek(p) == '.'):
		e.dashed = 1
		while (mm_peek(p) == '.'): p.pos = p.pos + 1
		if (mm_peek(p) == '-'):
			while (mm_peek(p) == '-'): p.pos = p.pos + 1
			run = 3
		else:
			# `-. text .->`: inline label on a dotted link.
			mm_space(p)
			int label_start = p.pos
			while (mm_end(p) == 0 && mm_match(p, c".-") == 0): p.pos = p.pos + 1
			int label_end = p.pos - 2
			if (label_end < label_start):
				mm_error(p.doc, p.pos, c"expected .-> after inline link label")
				return 1
			while (label_end > label_start && (p.doc.source[label_end - 1] & 255) <= 32): label_end = label_end - 1
			free(e.label)
			e.label = str_copy_range(p.doc.source, label_start, label_end)
			while (mm_peek(p) == '-'): p.pos = p.pos + 1
			run = 3
	int head = mm_peek(p)
	if (head == '>'): e.arrow = 1
	else if ((head == 'x' || head == 'o') && (p.pos + 1 >= p.doc.length || mm_id_char(p.doc.source[p.pos + 1] & 255) == 0)):
		if (head == 'x'): e.right_marker = 6
		else: e.right_marker = 8
	else if (run == 2 && e.dashed == 0):
		# `-- text -->` / `== text ==>`: the label runs to the closing operator.
		mm_space(p)
		int label_start = p.pos
		char* closer = c"--"
		if (thick): closer = c"=="
		while (mm_end(p) == 0):
			int at = p.pos
			if (mm_match(p, closer)):
				p.pos = at
				break
			p.pos = p.pos + 1
		int label_end = p.pos
		while (label_end > label_start && (p.doc.source[label_end - 1] & 255) <= 32): label_end = label_end - 1
		if (mm_end(p)):
			mm_error(p.doc, p.pos, c"expected closing link operator after inline label")
			return 1
		free(e.label)
		e.label = str_copy_range(p.doc.source, label_start, label_end)
		while (mm_peek(p) == c): p.pos = p.pos + 1
		head = mm_peek(p)
		if (head == '>'): e.arrow = 1
		else if (head == 'x'): e.right_marker = 6
		else if (head == 'o'): e.right_marker = 8
		else: head = 0
	else: head = 0
	if (head != 0): p.pos = p.pos + 1
	else if (run < 3):
		mm_error(p.doc, p.pos, c"expected swimlane relationship")
		return 1
	if (e.left_marker && head == 0): mm_error(p.doc, start, c"bidirectional link requires an arrowhead")
	if (thick):
		e.style.mask = e.style.mask | MM_STYLE_WIDTH
		e.style.width = 4
	return 1

# `a & b` node groups joined by links, each group fully connected to the next.
void mm_swim_statement(mm_parser* p, int scope):
	list[int] left = new list[int]
	list[int] right = new list[int]
	left.push(mm_swim_node(p, scope))
	mm_space(p)
	while (mm_match(p, c"&") && p.doc.error == 0):
		left.push(mm_swim_node(p, scope))
		mm_space(p)
	while (mm_end(p) == 0 && p.doc.error == 0):
		mm_edge* link = new mm_edge()
		link.label = strclone(c"")
		if (mm_swim_link(p, link) == 0): mm_error(p.doc, p.pos, c"expected swimlane relationship")
		mm_space(p)
		if (p.doc.error == 0 && mm_match(p, c"|")):
			free(link.label)
			link.label = mm_until(p, '|')
		while (right.length > 0): right.pop()
		if (p.doc.error == 0):
			right.push(mm_swim_node(p, scope))
			mm_space(p)
			while (mm_match(p, c"&") && p.doc.error == 0):
				right.push(mm_swim_node(p, scope))
				mm_space(p)
		for int from in left:
			for int to in right:
				if (p.doc.error != 0): break
				if (from < 0 || to < 0): continue
				if (p.doc.edges.length >= MM_MAX_ITEMS):
					mm_error(p.doc, p.pos, c"workflow edge limit exceeded")
					break
				mm_edge* e = new mm_edge()
				e.from_node = from
				e.to_node = to
				e.label = strclone(link.label)
				e.dashed = link.dashed
				e.arrow = link.arrow
				e.left_marker = link.left_marker
				e.right_marker = link.right_marker
				e.style = link.style
				e.scope = scope
				p.doc.edges.push(e)
		free(link.label)
		free(link)
		while (left.length > 0): left.pop()
		for int index in right: left.push(index)
	__w_list_free(cast(__w_list*, left))
	__w_list_free(cast(__w_list*, right))

void mm_workflow_edge(mm_parser* p, int from, int to, char* label, int dashed, int arrow):
	if (p.doc.edges.length >= MM_MAX_ITEMS):
		mm_error(p.doc, p.pos, c"workflow edge limit exceeded")
		return
	if (from < 0 || to < 0): return
	mm_edge* e = new mm_edge()
	e.from_node = from
	e.to_node = to
	e.label = strclone(label)
	e.dashed = dashed
	e.arrow = arrow
	p.doc.edges.push(e)

# `subgraph id[Label]`, `subgraph id [Label]`, `subgraph "Label"` or a bare
# title: top-level subgraphs are lanes, nested ones clusters inside a lane.
int mm_swim_subgraph(mm_parser* p, int scope, int depth):
	mm_space(p)
	int offset = p.pos
	char* id = 0
	char* label = 0
	if (mm_peek(p) == '"'):
		label = mm_quoted(p)
		id = strclone(label)
	else:
		id = mm_identifier(p)
		mm_space(p)
		if (mm_match(p, c"[")): label = mm_swim_label(p, c"]", 0)
		else if (mm_end(p) == 0):
			while (mm_end(p) == 0): p.pos = p.pos + 1
			int end = p.pos
			while (end > offset && (p.doc.source[end - 1] & 255) <= 32): end = end - 1
			free(id)
			id = str_copy_range(p.doc.source, offset, end)
		else: label = strclone(id)
	if (label == 0): label = strclone(id)
	int index = mm_add_node(p.doc, id, offset)
	free(id)
	if (index < 0):
		free(label)
		return -1
	mm_node* n = p.doc.nodes[index]
	if (n.declared || n.group): mm_error(p.doc, offset, c"duplicate swimlane identifier")
	if (depth >= MM_SWIM_MAX_DEPTH): mm_error(p.doc, offset, c"swimlane nesting limit exceeded")
	n.group = 1
	n.declared = 1
	n.parent = scope
	free(n.label)
	n.label = label
	return index

void mm_swimlane_body(mm_parser* p):
	list[int] scopes = new list[int]
	while (mm_peek(p) != 0 && p.doc.error == 0):
		int scope = -1
		if (scopes.length > 0): scope = scopes[scopes.length - 1]
		if (mm_metadata(p)):
			mm_separators(p)
			continue
		if (mm_style_statement(p)): mm_space(p)
		else if (mm_keyword(p, c"subgraph")):
			int index = mm_swim_subgraph(p, scope, scopes.length)
			if (index < 0): break
			scopes.push(index)
		else if (mm_keyword(p, c"end")):
			if (scopes.length == 0): mm_error(p.doc, p.pos, c"unexpected swimlane end")
			else: scopes.pop()
		else if (mm_keyword(p, c"direction")):
			if (scope < 0): mm_direction(p)
			else:
				char* outer = p.doc.direction
				p.doc.direction = strclone(outer)
				mm_direction(p)
				mm_node* n = p.doc.nodes[scope]
				free(n.direction)
				n.direction = p.doc.direction
				p.doc.direction = outer
		else: mm_swim_statement(p, scope)
		if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported swimlane syntax")
		mm_separators(p)
	if (scopes.length > 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"unterminated swimlane")
	__w_list_free(cast(__w_list*, scopes))
	for mm_node* n in p.doc.nodes:
		if (n.group == 0 && n.parent < 0): mm_error(p.doc, p.pos, c"step must be declared inside a swimlane")

# Event modeling (upstream EventModeling grammar, @mermaid-js/parser 2.x).
# Document notes carry the parts that are not timeline frames:
const int MM_EM_ENTITY = 10
const int MM_EM_DATA = 11
const int MM_EM_NOTE = 12
const int MM_EM_GWT = 13

# Timeframes have stable numeric identifiers but preserve declaration order.
char* mm_frame_id(mm_parser* p):
	mm_space(p)
	int start = p.pos
	while (isdigit(mm_peek(p))): p.pos = p.pos + 1
	if (p.pos == start): mm_error(p.doc, p.pos, c"expected numeric timeframe identifier")
	if (p.pos - start > 3): mm_error(p.doc, start, c"timeframe identifiers have at most three digits")
	while (start + 1 < p.pos && p.doc.source[start] == '0'): start = start + 1
	return str_copy_range(p.doc.source, start, p.pos)

char* mm_event_entity(mm_parser* p):
	mm_space(p)
	int start = p.pos
	while (mm_id_char(mm_peek(p)) || mm_peek(p) == '.'): p.pos = p.pos + 1
	if (p.pos == start): mm_error(p.doc, p.pos, c"expected event entity identifier")
	return str_copy_range(p.doc.source, start, p.pos)

# Event-model separators: newlines and %% comments plus /* */ and // comments.
void mm_event_separators(mm_parser* p):
	while (p.doc.error == 0):
		mm_separators(p)
		if (mm_match(p, c"/*")):
			int start = p.pos
			while (mm_peek(p) != 0 && mm_match(p, c"*/") == 0): p.pos = p.pos + 1
			if (p.pos >= p.doc.length && (p.pos - start < 2 || p.doc.source[p.pos - 1] != '/' || p.doc.source[p.pos - 2] != '*')): mm_error(p.doc, start, c"unterminated event model comment")
		else if (mm_match(p, c"//")):
			while (mm_peek(p) != 0 && mm_peek(p) != 10): p.pos = p.pos + 1
		else: return

# Optional `` `json` `` data type tag before inline data or a data block.
char* mm_event_data_type(mm_parser* p):
	mm_space(p)
	if (mm_match(p, c"`") == 0): return 0
	char* type = mm_identifier(p)
	if (mm_in_words(type, c"|json|jsobj|figma|salt|uri|md|html|text|") == 0): mm_error(p.doc, p.pos, c"unsupported event data type; supported: json, jsobj, figma, salt, uri, md, html, text")
	if (mm_match(p, c"`") == 0): mm_error(p.doc, p.pos, c"expected closing backtick after data type")
	return type

void mm_event_line(mm_parser* p, mm_node* n, char* text, int start, int end):
	while (start < end && (text[start] & 255) <= 32): start = start + 1
	while (end > start && (text[end - 1] & 255) <= 32): end = end - 1
	if (n.members.length >= 256 || p.doc.attribute_count >= 4096):
		mm_error(p.doc, p.pos, c"event data line limit exceeded")
		return
	mm_member* m = new mm_member()
	m.text = str_copy_range(text, start, end)
	n.members.push(m)
	p.doc.attribute_count = p.doc.attribute_count + 1

# Multi-line `{` ... `}` block: `{` ends its line and `}` starts a line.
# Returns the body between them, or 0 when the next token is not a block.
char* mm_event_block(mm_parser* p):
	int save = p.pos
	mm_space(p)
	if (mm_match(p, c"{") == 0):
		p.pos = save
		return 0
	mm_space(p)
	if (mm_peek(p) != 10):
		p.pos = save
		return 0
	p.pos = p.pos + 1
	int start = p.pos
	while (mm_peek(p) != 0):
		int line = p.pos
		while (mm_peek(p) == 32 || mm_peek(p) == 9): p.pos = p.pos + 1
		if (mm_peek(p) == '}' && p.pos == line):
			char* body = str_copy_range(p.doc.source, start, line)
			p.pos = p.pos + 1
			return body
		while (mm_peek(p) != 0 && mm_peek(p) != 10): p.pos = p.pos + 1
		if (mm_peek(p) == 10): p.pos = p.pos + 1
	mm_error(p.doc, start, c"unterminated event data block")
	return strclone(c"")

# Each data line keeps its indentation relative to the block's least indented line.
void mm_event_block_lines(mm_parser* p, mm_node* n, char* body):
	int length = strlen(body)
	int start = 0
	for i in range(length + 1):
		if (i == length || body[i] == 10):
			int end = i
			if (end > start && body[end - 1] == 13): end = end - 1
			int content = start
			while (content < end && (body[content] & 255) <= 32): content = content + 1
			if (content < end): mm_event_line(p, n, body, start, end)
			start = i + 1

void mm_event_set(mm_parser* p, mm_node* n, char* key, char* value):
	list[mm_property*] props = new list[mm_property*]
	props.push(new mm_property(strclone(key), strclone(value), MM_VALUE_STRING))
	mm_agent_merge(p, n.metadata, props)
	mm_properties_free(props)

void mm_event_note(mm_parser* p, int node, int side, char* text):
	if (p.doc.notes.length >= MM_MAX_ITEMS):
		mm_error(p.doc, p.pos, c"event model annotation limit exceeded")
		free(text)
		return
	mm_note* note = new mm_note()
	note.node = node
	note.side = side
	note.text = text
	p.doc.notes.push(note)

# `data Name `type` { ... }`: note text is "Name\ntype\nbody".
void mm_event_data(mm_parser* p):
	char* name = mm_identifier(p)
	char* type = mm_event_data_type(p)
	char* body = mm_event_block(p)
	if (body == 0):
		mm_error(p.doc, p.pos, c"expected multi-line data block")
		body = strclone(c"")
	for mm_note* note in p.doc.notes:
		if (note.side == MM_EM_DATA && index_of(note.text, name) == 0 && note.text[strlen(name)] == 10): mm_error(p.doc, p.pos, c"duplicate event data block")
	string_builder* text = string_from(name)
	string_append_char(text, 10)
	if (type != 0): string_append(text, type)
	string_append_char(text, 10)
	string_append(text, body)
	mm_event_note(p, -1, MM_EM_DATA, strclone(text.data))
	string_free(text)
	free(name)
	if (type != 0): free(type)
	free(body)

int mm_event_frame_ref(mm_parser* p):
	char* id = mm_frame_id(p)
	int index = mm_find_node(p.doc, id)
	free(id)
	if (index < 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"annotation references undeclared timeframe")
	return index

# `gwt 01 given evt A when cmd B then evt C`: a specification on one frame.
void mm_event_gwt(mm_parser* p):
	int frame = mm_event_frame_ref(p)
	string_builder* text = string_new()
	int phase = 0
	int counts = 0
	while (p.doc.error == 0):
		mm_event_separators(p)
		mm_space(p)
		int save = p.pos
		char* word = 0
		if (mm_id_char(mm_peek(p))): word = mm_identifier(p)
		int keyword = word != 0 && mm_in_words(word, c"|given|when|then|")
		if (keyword):
			int next = 1
			if (strcmp(word, c"when") == 0): next = 2
			if (strcmp(word, c"then") == 0): next = 3
			if (next <= phase || (next == 1 && phase != 0) || (next > 1 && phase == 0) || (phase > 0 && counts == 0)): mm_error(p.doc, save, c"gwt requires given, optional when, then, each with statements")
			phase = next
			counts = 0
			if (text.length > 0): string_append_char(text, 10)
			string_append(text, word)
			string_append_char(text, ':')
			free(word)
			continue
		if (word == 0 || phase == 0 || mm_in_words(word, c"|rmo|readmodel|ui|cmd|command|evt|event|pcr|processor|") == 0):
			if (word != 0): free(word)
			p.pos = save
			break
		char* entity = mm_identifier(p)
		string_append_char(text, 32)
		string_append(text, word)
		string_append_char(text, 32)
		string_append(text, entity)
		free(word)
		free(entity)
		counts = counts + 1
	if (phase != 3 || counts == 0): mm_error(p.doc, p.pos, c"gwt requires given, optional when, then, each with statements")
	if (p.doc.error == 0): mm_event_note(p, frame, MM_EM_GWT, strclone(text.data))
	string_free(text)

# Lane ordering group of an entity type: automation, command/read model, events.
int mm_event_lane_group(char* type):
	if (mm_in_words(type, c"|ui|pcr|processor|")): return 0
	if (mm_in_words(type, c"|cmd|command|rmo|readmodel|")): return 1
	return 2

void mm_event_frame(mm_parser* p, int reset, int* ordinal, int* previous):
	char* id = mm_frame_id(p)
	int index = mm_add_node(p.doc, id, p.pos)
	free(id)
	if (index < 0): return
	mm_node* n = p.doc.nodes[index]
	if (n.declared): mm_error(p.doc, p.pos, c"duplicate timeframe identifier")
	n.declared = 1
	n.value_x = *ordinal
	*ordinal = *ordinal + 1
	char* type = mm_identifier(p)
	char* lane_type = c""
	if (mm_in_words(type, c"|ui|pcr|processor|")): lane_type = c"UI / Automation"
	else if (mm_in_words(type, c"|cmd|command|rmo|readmodel|")): lane_type = c"Command / Read model"
	else if (mm_in_words(type, c"|evt|event|")): lane_type = c"Events"
	else: mm_error(p.doc, p.pos, c"unknown event entity type")
	free(n.annotation)
	n.annotation = type
	free(n.label)
	n.label = mm_event_entity(p)
	string_builder* lane_name = string_new()
	int dot = index_of(n.label, c".")
	if (dot >= 0):
		string_append_bytes(lane_name, n.label, dot)
		string_append(lane_name, c" / ")
	string_append(lane_name, lane_type)
	string_builder* lane_id = string_from(c"@lane:")
	string_append(lane_id, lane_name.data)
	int lane = mm_add_node(p.doc, lane_id.data, p.pos)
	if (lane >= 0):
		mm_node* group = p.doc.nodes[lane]
		group.group = 1
		group.declared = 1
		group.value_y = mm_event_lane_group(type)
		free(group.label)
		group.label = strclone(lane_name.data)
		n.parent = lane
	string_free(lane_id)
	string_free(lane_name)
	if (reset == 0 && *previous >= 0): mm_workflow_edge(p, *previous, index, c"", 0, 1)
	*previous = index
	mm_space(p)
	while (mm_match(p, c"->>") && p.doc.error == 0):
		char* target = mm_frame_id(p)
		int from = mm_add_node(p.doc, target, p.pos)
		free(target)
		if (p.doc.error == 0): mm_workflow_edge(p, from, index, c"", 0, 1)
		mm_space(p)
	if (mm_match(p, c"[[")):
		char* reference = mm_identifier(p)
		if (mm_match(p, c"]]") == 0): mm_error(p.doc, p.pos, c"expected ]] after data reference")
		if (p.doc.error == 0): mm_event_set(p, n, c"dataReference", reference)
		free(reference)
		mm_space(p)
	char* data_type = mm_event_data_type(p)
	if (data_type != 0):
		if (p.doc.error == 0): mm_event_set(p, n, c"dataType", data_type)
		free(data_type)
	mm_space(p)
	int quote = mm_peek(p)
	if (quote == '{' || quote == '"' || quote == 39):
		# Inline data runs to the last closing delimiter on the line (nested payloads).
		int start = p.pos + 1
		int line_end = start
		while (line_end < p.doc.length && p.doc.source[line_end] != 10): line_end = line_end + 1
		int close = '}'
		if (quote != '{'): close = quote
		int end = line_end
		while (end > start && (p.doc.source[end - 1] & 255) != close): end = end - 1
		if (end <= start): mm_error(p.doc, p.pos, c"expected inline data closing brace")
		else:
			mm_event_line(p, n, p.doc.source, start, end - 1)
			p.pos = end
	mm_space(p)
	while (mm_match(p, c"->>") && p.doc.error == 0):
		char* target = mm_frame_id(p)
		int from = mm_add_node(p.doc, target, p.pos)
		free(target)
		if (p.doc.error == 0): mm_workflow_edge(p, from, index, c"", 0, 1)
		mm_space(p)

void mm_event_body(mm_parser* p):
	int previous = -1
	int ordinal = 0
	mm_event_separators(p)
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_metadata(p)):
			mm_event_separators(p)
			continue
		char* command = mm_identifier(p)
		if (strcmp(command, c"title") == 0):
			free(p.doc.title)
			p.doc.title = mm_line_text(p)
		else if (strcmp(command, c"entity") == 0): mm_event_note(p, -1, MM_EM_ENTITY, mm_event_entity(p))
		else if (strcmp(command, c"data") == 0): mm_event_data(p)
		else if (strcmp(command, c"note") == 0):
			int frame = mm_event_frame_ref(p)
			char* type = mm_event_data_type(p)
			if (type != 0): free(type)
			char* body = mm_event_block(p)
			if (body == 0):
				mm_error(p.doc, p.pos, c"expected multi-line note block")
				body = strclone(c"")
			mm_event_note(p, frame, MM_EM_NOTE, body)
		else if (strcmp(command, c"gwt") == 0): mm_event_gwt(p)
		else:
			int reset = mm_in_words(command, c"|rf|resetframe|")
			if (reset == 0 && mm_in_words(command, c"|tf|timeframe|") == 0): mm_error(p.doc, p.pos, c"expected timeframe, resetframe, data, note, gwt or entity")
			else: mm_event_frame(p, reset, &ordinal, &previous)
		free(command)
		if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported event data or timeframe syntax")
		mm_event_separators(p)
	for mm_node* n in p.doc.nodes:
		if (n.declared == 0): mm_error(p.doc, p.pos, c"relation references undeclared timeframe")
	# Data references resolve after all blocks are declared (forward references).
	for mm_node* n in p.doc.nodes:
		if (p.doc.error != 0): break
		mm_property* reference = mm_agent_get(n.metadata, c"dataReference")
		if (reference == 0): continue
		mm_note* block = 0
		for mm_note* note in p.doc.notes:
			if (note.side == MM_EM_DATA && index_of(note.text, reference.value) == 0 && note.text[strlen(reference.value)] == 10): block = note
		if (block == 0):
			mm_error(p.doc, p.pos, c"timeframe references an undeclared data block")
			break
		int type_start = strlen(reference.value) + 1
		int type_end = type_start
		while (block.text[type_end] != 10): type_end = type_end + 1
		if (type_end > type_start && mm_agent_get(n.metadata, c"dataType") == 0):
			char* type = str_copy_range(block.text, type_start, type_end)
			mm_event_set(p, n, c"dataType", type)
			free(type)
		mm_event_block_lines(p, n, block.text + type_end + 1)
