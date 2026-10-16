# Responsibility lanes and event-model timeframes keep their own semantics.
import libs.extras.mermaid.frameworks

int mm_workflow_node(mm_parser* p, int lane):
	char* id = mm_identifier(p)
	int index = mm_add_node(p.doc, id, p.pos)
	free(id)
	if (index < 0): return -1
	mm_node* n = p.doc.nodes[index]
	if (lane >= 0):
		if (n.declared && n.parent != lane): mm_error(p.doc, p.pos, c"step already belongs to another swimlane")
		n.parent = lane
		n.declared = 1
	mm_space(p)
	int close = 0
	int doubled = 0
	int stadium = 0
	if (mm_match(p, c"[")): close = ']'
	else if (mm_match(p, c"((")):
		close = ')'
		doubled = 1
		n.shape = 2
	else if (mm_match(p, c"([")):
		close = ']'
		stadium = 1
		n.shape = 1
	else if (mm_match(p, c"(")):
		close = ')'
		n.shape = 1
	else if (mm_match(p, c"{")):
		close = '}'
		n.shape = 3
	if (close):
		free(n.label)
		n.label = mm_until(p, close)
		if ((doubled || stadium) && mm_match(p, c")") == 0): mm_error(p.doc, p.pos, c"expected closing shape parenthesis")
	return index

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

void mm_swimlane_body(mm_parser* p):
	int scope = -1
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_metadata(p)):
			mm_separators(p)
			continue
		if (mm_keyword(p, c"subgraph")):
			if (scope >= 0): mm_error(p.doc, p.pos, c"nested swimlanes are not yet supported")
			int index = mm_workflow_node(p, -1)
			if (index < 0): return
			mm_node* n = p.doc.nodes[index]
			if (n.declared): mm_error(p.doc, p.pos, c"duplicate swimlane identifier")
			n.group = 1
			n.declared = 1
			scope = index
		else if (mm_keyword(p, c"end")):
			if (scope < 0): mm_error(p.doc, p.pos, c"unexpected swimlane end")
			scope = -1
		else:
			int from = mm_workflow_node(p, scope)
			while (mm_end(p) == 0 && p.doc.error == 0):
				int arrow = mm_match(p, c"-->")
				int dashed = 0
				if (arrow == 0 && mm_match(p, c"-.->")):
					dashed = 1
					arrow = 1
				else if (arrow == 0 && mm_match(p, c"---") == 0): mm_error(p.doc, p.pos, c"expected swimlane relationship")
				mm_space(p)
				char* label = strclone(c"")
				if (mm_match(p, c"|")):
					free(label)
					label = mm_until(p, '|')
				int to = mm_workflow_node(p, scope)
				if (p.doc.error == 0): mm_workflow_edge(p, from, to, label, dashed, arrow)
				free(label)
				from = to
		if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported swimlane syntax")
		mm_separators(p)
	if (scope >= 0): mm_error(p.doc, p.pos, c"unterminated swimlane")
	for mm_node* n in p.doc.nodes:
		if (n.group == 0 && n.parent < 0): mm_error(p.doc, p.pos, c"step must be declared inside a swimlane")
	for mm_edge* e in p.doc.edges:
		mm_node* a = p.doc.nodes[e.from_node]
		mm_node* b = p.doc.nodes[e.to_node]
		if (a.group || b.group): mm_error(p.doc, p.pos, c"edges must connect steps, not swimlane containers")

# Timeframes have stable numeric identifiers but preserve declaration order.
char* mm_frame_id(mm_parser* p):
	mm_space(p)
	int start = p.pos
	while (isdigit(mm_peek(p))): p.pos = p.pos + 1
	if (p.pos == start): mm_error(p.doc, p.pos, c"expected numeric timeframe identifier")
	while (start + 1 < p.pos && p.doc.source[start] == '0'): start = start + 1
	return str_copy_range(p.doc.source, start, p.pos)

char* mm_event_entity(mm_parser* p):
	mm_space(p)
	int start = p.pos
	while (mm_id_char(mm_peek(p)) || mm_peek(p) == '.'): p.pos = p.pos + 1
	if (p.pos == start): mm_error(p.doc, p.pos, c"expected event entity identifier")
	return str_copy_range(p.doc.source, start, p.pos)

void mm_event_body(mm_parser* p):
	int previous = -1
	int ordinal = 0
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_metadata(p)):
			mm_separators(p)
			continue
		char* command = mm_identifier(p)
		int reset = mm_in_words(command, c"|rf|resetframe|")
		if (reset == 0 && mm_in_words(command, c"|tf|timeframe|") == 0): mm_error(p.doc, p.pos, c"expected timeframe or resetframe")
		free(command)
		char* id = mm_frame_id(p)
		int index = mm_add_node(p.doc, id, p.pos)
		free(id)
		if (index < 0): return
		mm_node* n = p.doc.nodes[index]
		if (n.declared): mm_error(p.doc, p.pos, c"duplicate timeframe identifier")
		n.declared = 1
		n.value_x = ordinal
		ordinal = ordinal + 1
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
			free(group.label)
			group.label = strclone(lane_name.data)
			n.parent = lane
		string_free(lane_id)
		string_free(lane_name)
		if (reset == 0 && previous >= 0): mm_workflow_edge(p, previous, index, c"", 0, 1)
		previous = index
		mm_space(p)
		if (mm_match(p, c"{")):
			int start = p.pos
			while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != '}'): p.pos = p.pos + 1
			char* data = str_copy_range(p.doc.source, start, p.pos)
			if (mm_match(p, c"}") == 0): mm_error(p.doc, p.pos, c"expected inline data closing brace")
			mm_graph_member(p, n, c"data", data)
			free(data)
		mm_space(p)
		while (mm_match(p, c"->>") && p.doc.error == 0):
			char* target = mm_frame_id(p)
			int from = mm_add_node(p.doc, target, p.pos)
			free(target)
			if (p.doc.error == 0): mm_workflow_edge(p, from, index, c"", 0, 1)
			mm_space(p)
		if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported event data or timeframe syntax")
		mm_separators(p)
	for mm_node* n in p.doc.nodes:
		if (n.declared == 0): mm_error(p.doc, p.pos, c"relation references undeclared timeframe")
