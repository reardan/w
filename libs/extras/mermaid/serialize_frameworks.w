# Canonical Cynefin and Wardley map source.
import libs.extras.mermaid.serialize_common

# Thousandths in [0, 1000] as the shortest decimal ("0", "0.25", "1").
void mm_serialize_unit(mm_serializer* out, int value):
	if (value < 0 || value > 1000):
		out.failed = 1
		return
	if (value == 1000):
		mm_out(out, c"1")
		return
	if (value == 0):
		mm_out(out, c"0")
		return
	mm_out(out, c"0.")
	mm_out_char(out, '0' + value / 100)
	if (value % 100):
		mm_out_char(out, '0' + value / 10 % 10)
		if (value % 10): mm_out_char(out, '0' + value % 10)

void mm_serialize_cynefin(mm_serializer* out, mm_document* d):
	mm_out(out, c"cynefin-beta\n")
	mm_serialize_accessibility(out, d)
	list[char*] names = list[char*]{c"complex", c"complicated", c"chaotic", c"clear", c"confusion"}
	if (d.nodes.length != 5): out.failed = 1
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (i >= 5 || strcmp(n.id, names[i]) != 0 || strcmp(n.label, n.id) != 0 || n.shape != 0 || n.parent != -1 || n.metadata.length != 0 || n.style.mask != 0):
			out.failed = 1
			continue
		if (n.members.length == 0): continue
		mm_out(out, n.id)
		mm_out_line(out)
		for mm_member* m in n.members:
			if (starts_with(m.text, c"item: ") == 0):
				out.failed = 1
				continue
			mm_out(out, c"  ")
			mm_serialize_quote(out, m.text + 6)
			mm_out_line(out)
	__w_list_free(cast(__w_list*, names))
	for mm_edge* e in d.edges:
		if (e.from_node < 0 || e.to_node < 0 || e.from_node >= d.nodes.length || e.to_node >= d.nodes.length || e.arrow != 1 || e.dashed):
			out.failed = 1
			continue
		mm_out(out, d.nodes[e.from_node].id)
		mm_out(out, c" --> ")
		mm_out(out, d.nodes[e.to_node].id)
		if (e.label[0] != 0):
			mm_out(out, c" : ")
			mm_serialize_quote(out, e.label)
		mm_out_line(out)

int mm_serialize_wardley_keyword(char* name):
	list[char*] words = list[char*]{c"title", c"evolution", c"evolve", c"note", c"pipeline", c"size", c"annotations", c"annotation", c"accelerator", c"deaccelerator", c"anchor", c"component", c"accTitle", c"accDescr"}
	int found = 0
	for char* word in words:
		int length = strlen(word)
		if (starts_with(name, word) && mm_id_char(name[length] & 255) == 0 && name[length] != '-'): found = 1
	__w_list_free(cast(__w_list*, words))
	return found

# A component name as mm_wardley_name reads it back.
void mm_serialize_wardley_name(mm_serializer* out, char* name):
	int length = strlen(name)
	int quote = length == 0 || name[0] == '"' || name[0] == 32 || name[length - 1] == 32 || mm_serialize_wardley_keyword(name) || index_of(name, c"%%") >= 0
	for i in range(length):
		int c = name[i]
		int next = name[i + 1]
		if (c == '[' || c == '{' || c == ';' || c == '>' || c == 9 || c == 13): quote = 1
		if (c == '-' && (next == '>' || next == '-' || next == '.')): quote = 1
		if (c == '+' && (next == '>' || next == '<' || next == '\'')): quote = 1
	if (quote): mm_serialize_quote(out, name)
	else: mm_out_plain(out, name, 0)

char* mm_serialize_wardley_get(mm_node* n, char* key):
	for mm_property* property in n.metadata:
		if (strcmp(property.key, key) == 0): return property.value
	return 0

# `label [dx, dy]`, `inertia` and `(strategy)` in metadata order; the
# pipeline and evolve entries are statements of their own and follow.
void mm_serialize_wardley_modifiers(mm_serializer* out, mm_node* n):
	int statements = 0
	for mm_property* property in n.metadata:
		if (strcmp(property.key, c"pipeline") == 0 || strcmp(property.key, c"evolve") == 0):
			statements = 1
			continue
		if (statements): out.failed = 1
		if (strcmp(property.key, c"label") == 0):
			int split = index_of(property.value, c" ")
			if (split <= 0):
				out.failed = 1
				continue
			mm_out(out, c" label [")
			char* x = str_copy_range(property.value, 0, split)
			mm_out(out, x)
			free(x)
			mm_out(out, c", ")
			mm_out(out, property.value + split + 1)
			mm_out(out, c"]")
		else if (strcmp(property.key, c"inertia") == 0): mm_out(out, c" inertia")
		else if (strcmp(property.key, c"strategy") == 0):
			mm_out(out, c" (")
			mm_out(out, property.value)
			mm_out(out, c")")
		else: out.failed = 1

# "low high" thousandths (a range or coordinates) as `[low, high]`.
void mm_serialize_wardley_pair(mm_serializer* out, char* value):
	int split = index_of(value, c" ")
	if (split <= 0):
		out.failed = 1
		return
	mm_out(out, c"[")
	mm_serialize_unit(out, atoi(value))
	mm_out(out, c", ")
	mm_serialize_unit(out, atoi(value + split + 1))
	mm_out(out, c"]")

void mm_serialize_wardley_coordinates(mm_serializer* out, mm_node* n):
	mm_out(out, c" [")
	mm_serialize_unit(out, n.value_y)
	mm_out(out, c", ")
	mm_serialize_unit(out, n.value_x)
	mm_out(out, c"]")

void mm_serialize_wardley_stage(mm_serializer* out, char* text):
	if (index_of(text, c"->") >= 0 || index_of(text, c"/") >= 0 || index_of(text, c"@") >= 0 || index_of(text, c"\n") >= 0): out.failed = 1
	int length = strlen(text)
	if (length == 0 || text[0] == 32 || text[length - 1] == 32): out.failed = 1
	if (text[0] == '"' && text[length - 1] == '"'):
		mm_out_char(out, '"')
		mm_out(out, text)
		mm_out_char(out, '"')
	else: mm_out(out, text)

void mm_serialize_wardley_evolution(mm_serializer* out, mm_document* d):
	int count = 0
	for mm_note* note in d.notes:
		if (note.node == -1): count = count + 1
		else if (note.node != -2): out.failed = 1
	char* boundaries = mm_config_value(d, c"wardley.boundaries")
	if (count == 0):
		if (boundaries != 0): out.failed = 1
		return
	list[char*] bounds = 0
	if (boundaries != 0):
		bounds = split(boundaries, ' ')
		if (bounds.length != count): out.failed = 1
	mm_out(out, c"evolution ")
	for i in range(count):
		if (i > 0): mm_out(out, c" -> ")
		char* name = 0
		char* second = 0
		for mm_note* note in d.notes:
			if (note.side != i): continue
			if (note.node == -1): name = note.text
			else: second = note.text
		if (name == 0):
			out.failed = 1
			continue
		mm_serialize_wardley_stage(out, name)
		if (bounds != 0 && i < bounds.length):
			mm_out_char(out, '@')
			mm_serialize_unit(out, atoi(bounds[i]))
		if (second != 0):
			mm_out(out, c" / ")
			mm_serialize_wardley_stage(out, second)
	mm_out_line(out)
	# Stage notes must be in the order the axis writes them.
	int at = 0
	for i in range(count):
		for mm_note* note in d.notes:
			if (note.side != i): continue
			if (at >= d.notes.length || d.notes[at] != note): out.failed = 1
			at = at + 1
	if (bounds != 0):
		for char* part in bounds: free(part)
		__w_list_free(cast(__w_list*, bounds))

void mm_serialize_wardley_pipeline(mm_serializer* out, mm_document* d, int index):
	mm_node* n = d.nodes[index]
	char* range = mm_serialize_wardley_get(n, c"pipeline")
	mm_out(out, c"pipeline ")
	mm_serialize_wardley_name(out, n.id)
	mm_out_char(out, 32)
	mm_serialize_wardley_pair(out, range)
	int children = 0
	for mm_node* child in d.nodes:
		if (child.parent == index): children = children + 1
	if (children == 0):
		mm_out_line(out)
		return
	mm_out(out, c" {\n")
	for mm_node* child in d.nodes:
		if (child.parent != index): continue
		if (child.shape != 2 || child.value_y != n.value_y || strcmp(child.label, child.id) != 0): out.failed = 1
		mm_out(out, c"  component ")
		mm_serialize_wardley_name(out, child.id)
		mm_out(out, c" [")
		mm_serialize_unit(out, child.value_x)
		mm_out(out, c"]")
		mm_serialize_wardley_modifiers(out, child)
		mm_out_line(out)
	mm_out(out, c"}\n")

void mm_serialize_wardley(mm_serializer* out, mm_document* d):
	mm_out(out, c"wardley-beta\n")
	mm_serialize_accessibility(out, d)
	char* size = mm_config_value(d, c"wardley.size")
	if (size != 0):
		int split = index_of(size, c" ")
		if (split <= 0): out.failed = 1
		else:
			mm_out(out, c"size [")
			char* width = str_copy_range(size, 0, split)
			mm_out(out, width)
			free(width)
			mm_out(out, c", ")
			mm_out(out, size + split + 1)
			mm_out(out, c"]\n")
	mm_serialize_wardley_evolution(out, d)
	char* box = mm_config_value(d, c"wardley.annotations")
	if (box != 0):
		mm_out(out, c"annotations ")
		mm_serialize_wardley_pair(out, box)
		mm_out_line(out)
	list[int] done = new list[int]
	for i in range(d.nodes.length): done.push(0)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.declared == 0 || n.group || n.style.mask != 0 || n.members.length != 0): out.failed = 1
		if (n.shape == 0 || n.shape == 1):
			if (n.parent != -1 || strcmp(n.label, n.id) != 0): out.failed = 1
			if (n.shape == 1): mm_out(out, c"anchor ")
			else: mm_out(out, c"component ")
			mm_serialize_wardley_name(out, n.id)
			mm_serialize_wardley_coordinates(out, n)
			mm_serialize_wardley_modifiers(out, n)
			mm_out_line(out)
			if (mm_serialize_wardley_get(n, c"pipeline") != 0):
				int children = 0
				int next = -1
				for k in range(i + 1, d.nodes.length):
					if (d.nodes[k].parent == i):
						children = children + 1
						if (next >= 0 && k != next): out.failed = 1
						next = k + 1
				if (children == 0): mm_serialize_wardley_pipeline(out, d, i)
		else if (n.shape == 2):
			if (n.parent < 0 || n.parent >= i):
				out.failed = 1
				continue
			if (done[n.parent] == 0):
				done[n.parent] = 1
				mm_serialize_wardley_pipeline(out, d, n.parent)
		else if (n.shape == 3):
			if (starts_with(n.id, c"\nnote:") == 0 || n.metadata.length != 0): out.failed = 1
			mm_out(out, c"note ")
			mm_serialize_quote(out, n.label)
			mm_serialize_wardley_coordinates(out, n)
			mm_out_line(out)
		else if (n.shape == 4):
			if (starts_with(n.id, c"\nannotation:") == 0 || n.metadata.length != 0): out.failed = 1
			mm_out(out, c"annotation ")
			mm_out(out, n.annotation)
			mm_out(out, c",")
			mm_serialize_wardley_coordinates(out, n)
			mm_out_char(out, 32)
			mm_serialize_quote(out, n.label)
			mm_out_line(out)
		else if (n.shape == 5 || n.shape == 6):
			if (starts_with(n.id, c"\nforce:") == 0 || n.metadata.length != 0): out.failed = 1
			if (n.shape == 5): mm_out(out, c"accelerator ")
			else: mm_out(out, c"deaccelerator ")
			mm_serialize_wardley_name(out, n.label)
			mm_serialize_wardley_coordinates(out, n)
			mm_out_line(out)
		else: out.failed = 1
	__w_list_free(cast(__w_list*, done))
	for mm_edge* e in d.edges:
		if (e.from_node < 0 || e.to_node < 0 || e.from_node >= d.nodes.length || e.to_node >= d.nodes.length):
			out.failed = 1
			continue
		mm_serialize_wardley_name(out, d.nodes[e.from_node].id)
		int flow = e.scope == 1
		if (e.scope != (e.arrow != 0) || e.arrow < 0 || e.arrow > 3): out.failed = 1
		int labelled = flow && e.label[0] != 0 && index_of(e.label, c"'") < 0 && index_of(e.label, c"\n") < 0
		if (labelled):
			mm_out(out, c" +'")
			mm_out(out, e.label)
			mm_out(out, c"'")
			if (e.arrow == 3): mm_out(out, c"<>")
			else if (e.arrow == 1): mm_out(out, c">")
			else: mm_out(out, c"<")
			if (e.dashed): out.failed = 1
			mm_out_char(out, 32)
		else if (flow):
			if (e.arrow == 3): mm_out(out, c" +<>")
			else if (e.arrow == 1): mm_out(out, c" +>")
			else: mm_out(out, c" +<")
			if (e.dashed): mm_out(out, c" -.->")
			mm_out_char(out, 32)
		else if (e.dashed): mm_out(out, c" -.-> ")
		else: mm_out(out, c" -> ")
		mm_serialize_wardley_name(out, d.nodes[e.to_node].id)
		if (e.label[0] != 0 && labelled == 0):
			mm_out(out, c"; ")
			mm_out_plain(out, e.label, 0)
		mm_out_line(out)
	for mm_node* n in d.nodes:
		char* evolve = mm_serialize_wardley_get(n, c"evolve")
		if (evolve == 0): continue
		mm_out(out, c"evolve ")
		if (n.id[0] == '"' || n.id[0] == 32): mm_serialize_quote(out, n.id)
		else: mm_out(out, n.id)
		mm_out_char(out, 32)
		mm_serialize_unit(out, atoi(evolve))
		mm_out_line(out)

void mm_serialize_frameworks_body(mm_serializer* out, mm_document* d, int variant):
	if (d.narrative.length != 0 || d.data != 0 || d.railroad != 0 || d.style_definitions.length != 0 || strcmp(d.direction, c"TB") != 0): out.failed = 1
	if (d.kind == MM_CYNEFIN):
		if (d.notes.length != 0): out.failed = 1
		mm_serialize_cynefin(out, d)
	else: mm_serialize_wardley(out, d)
