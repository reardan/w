# Canonical workflow source. Swimlanes reuse the flowchart scope writer
# (lanes and clusters as subgraphs, steps, links and styles). Event models
# write their timeframes in declaration order (`rf` where the implicit link
# from the previous frame is missing, `->>` for the other incoming links),
# then entities, data blocks, notes and given/when/then specifications in
# their original order; lanes are derived from the frames and not written.
import libs.extras.mermaid.serialize_flow

void mm_serialize_swimlane_body(mm_serializer* out, mm_document* d):
	if (d.notes.length != 0 || d.narrative.length != 0 || d.data != 0 || d.railroad != 0 || d.edge_style.mask != 0): out.failed = 1
	mm_out(out, c"swimlane-beta ")
	mm_out(out, d.direction)
	mm_out_line(out)
	mm_serialize_accessibility(out, d)
	mm_serialize_class_defs(out, d)
	mm_serialize_scope_items(out, d, -1, 0, 0)
	if (out.nodes != d.nodes.length || out.edges != d.edges.length): out.failed = 1

# Event-model identifiers: id characters and dots.
void mm_serialize_event_entity(mm_serializer* out, char* text):
	if (text[0] == 0): out.failed = 1
	for i in range(strlen(text)):
		int c = text[i] & 255
		if (mm_id_char(c) == 0 && c != '.'): out.failed = 1
	mm_out(out, text)

# A `{` block body: raw lines, none starting with `}`, ending in a newline.
void mm_serialize_event_block(mm_serializer* out, char* body):
	int length = strlen(body)
	if (length > 0 && body[length - 1] != 10): out.failed = 1
	if (body[0] == '}'): out.failed = 1
	if (index_of(body, c"\n}") >= 0 && index_of(body, c"\n}") < length - 1): out.failed = 1
	mm_out(out, c" {\n")
	mm_out(out, body)
	mm_out(out, c"}\n")

# Lines of a data block that become timeframe members.
int mm_serialize_event_lines(char* body):
	int count = 0
	int content = 0
	for i in range(strlen(body) + 1):
		if (body[i] == 0 || body[i] == 10):
			if (content): count = count + 1
			content = 0
		else if ((body[i] & 255) > 32): content = 1
	return count

mm_note* mm_serialize_event_data_note(mm_document* d, char* name):
	mm_note* block = 0
	for mm_note* note in d.notes:
		if (note.side == MM_EM_DATA && index_of(note.text, name) == 0 && note.text[strlen(name)] == 10): block = note
	return block

void mm_serialize_event_frame(mm_serializer* out, mm_document* d, int index, int previous, int* edge):
	mm_node* n = d.nodes[index]
	int reset = 1
	if (edge[0] < d.edges.length && previous >= 0):
		mm_edge* e = d.edges[edge[0]]
		if (e.to_node == index && e.from_node == previous):
			reset = 0
			edge[0] = edge[0] + 1
	if (reset): mm_out(out, c"rf ")
	else: mm_out(out, c"tf ")
	mm_out(out, n.id)
	mm_out_char(out, 32)
	if (mm_in_words(n.annotation, c"|ui|pcr|processor|cmd|command|rmo|readmodel|evt|event|") == 0): out.failed = 1
	mm_out(out, n.annotation)
	mm_out_char(out, 32)
	mm_serialize_event_entity(out, n.label)
	while (edge[0] < d.edges.length && d.edges[edge[0]].to_node == index):
		mm_edge* e = d.edges[edge[0]]
		if (e.from_node < 0 || e.from_node >= d.nodes.length): out.failed = 1
		else:
			mm_out(out, c" ->> ")
			mm_out(out, d.nodes[e.from_node].id)
		edge[0] = edge[0] + 1
	char* reference = 0
	char* type = 0
	for i in range(n.metadata.length):
		mm_property* property = n.metadata[i]
		if (strcmp(property.key, c"dataReference") == 0 && i == 0): reference = property.value
		else if (strcmp(property.key, c"dataType") == 0 && type == 0): type = property.value
		else: out.failed = 1
	int block_lines = 0
	if (reference != 0):
		mm_out(out, c" [[")
		if (mm_serialize_is_id(reference) == 0): out.failed = 1
		mm_out(out, reference)
		mm_out(out, c"]]")
		mm_note* block = mm_serialize_event_data_note(d, reference)
		if (block == 0): out.failed = 1
		else:
			int type_start = strlen(reference) + 1
			int type_end = type_start
			while (block.text[type_end] != 0 && block.text[type_end] != 10): type_end = type_end + 1
			if (block.text[type_end] == 0): out.failed = 1
			else:
				block_lines = mm_serialize_event_lines(block.text + type_end + 1)
				# The block's own type is applied when no explicit type is given.
				if (type != 0 && type_end > type_start && strlen(type) == type_end - type_start && index_of(block.text + type_start, type) == 0): type = 0
	if (type != 0):
		mm_out(out, c" `")
		if (mm_in_words(type, c"|json|jsobj|figma|salt|uri|md|html|text|") == 0): out.failed = 1
		mm_out(out, type)
		mm_out_char(out, '`')
	int inline_count = n.members.length - block_lines
	if (inline_count < 0 || inline_count > 1): out.failed = 1
	else if (inline_count == 1):
		char* text = n.members[0].text
		mm_out(out, c" { ")
		mm_out_plain(out, text, 0)
		if (text[0] == 0): out.failed = 1
		mm_out(out, c" }")
	mm_out_line(out)

void mm_serialize_event_body(mm_serializer* out, mm_document* d):
	if (d.narrative.length != 0 || d.data != 0 || d.railroad != 0 || d.style_definitions.length != 0 || strcmp(d.direction, c"TB") != 0): out.failed = 1
	mm_out(out, c"eventmodeling\n")
	mm_serialize_accessibility(out, d)
	int previous = -1
	int edge = 0
	int ordinal = 0
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.style.mask != 0 || n.style_classes[0] != 0 || n.declared == 0): out.failed = 1
		if (n.group):
			if (starts_with(n.id, c"@lane:") == 0): out.failed = 1
			continue
		if (n.value_x != ordinal): out.failed = 1
		ordinal = ordinal + 1
		mm_serialize_event_frame(out, d, i, previous, &edge)
		previous = i
	if (edge != d.edges.length): out.failed = 1
	for mm_note* note in d.notes:
		if (note.side == MM_EM_ENTITY):
			mm_out(out, c"entity ")
			mm_serialize_event_entity(out, note.text)
			mm_out_line(out)
		else if (note.side == MM_EM_DATA):
			int name_end = index_of(note.text, c"\n")
			if (name_end <= 0):
				out.failed = 1
				continue
			char* name = str_copy_range(note.text, 0, name_end)
			int type_end = name_end + 1
			while (note.text[type_end] != 0 && note.text[type_end] != 10): type_end = type_end + 1
			mm_out(out, c"data ")
			mm_serialize_id(out, name)
			free(name)
			if (note.text[type_end] == 0):
				out.failed = 1
				continue
			if (type_end > name_end + 1):
				mm_out(out, c" `")
				for k in range(name_end + 1, type_end): mm_out_char(out, note.text[k])
				mm_out_char(out, '`')
			mm_serialize_event_block(out, note.text + type_end + 1)
		else if (note.side == MM_EM_NOTE || note.side == MM_EM_GWT):
			if (note.node < 0 || note.node >= d.nodes.length || d.nodes[note.node].group):
				out.failed = 1
				continue
			if (note.side == MM_EM_NOTE):
				mm_out(out, c"note ")
				mm_out(out, d.nodes[note.node].id)
				mm_serialize_event_block(out, note.text)
				continue
			mm_out(out, c"gwt ")
			mm_out(out, d.nodes[note.node].id)
			# "given: evt A\nthen: evt B" -> "given evt A then evt B".
			for k in range(strlen(note.text)):
				int c = note.text[k]
				if (c == 10): mm_out_char(out, 32)
				else if (c != ':'): mm_out_char(out, c)
			if (index_of(note.text, c"::") >= 0): out.failed = 1
			mm_out_line(out)
		else: out.failed = 1

void mm_serialize_workflows_body(mm_serializer* out, mm_document* d, int variant):
	if (d.kind == MM_SWIMLANE): mm_serialize_swimlane_body(out, d)
	else: mm_serialize_event_body(out, d)
