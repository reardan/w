# Canonical use case source. Declarations, boundaries, JSON tables, notes
# and relationships are merged so that reparsing creates nodes and edges in
# model order: an undeclared use case is written (with its label and
# shape) at every relationship that names it, a declared one is declared
# where its index falls. Edge animation, styles and classes follow.
import libs.extras.mermaid.serialize_common

# Text read through mm_uc_entities: `"` and `#` are written as entities.
void mm_serialize_uc_text(mm_serializer* out, char* text):
	int length = strlen(text)
	int markdown = length >= 2 && text[0] == '`' && text[length - 1] == '`'
	mm_out_char(out, '"')
	for i in range(length):
		int c = text[i] & 255
		if (c == '"'): mm_out(out, c"#quot;")
		else if (c == '#'): mm_out(out, c"#35;")
		else if (c == 10 && markdown): mm_out_char(out, c)
		else if (c == 10 || c == 13):
			out.failed = 1
			mm_out_char(out, 32)
		else: mm_out_char(out, c)
	mm_out_char(out, '"')

# A node mention: id plus (label) / [label] when they differ from a bare id.
void mm_serialize_uc_mention(mm_serializer* out, mm_node* n, int full):
	if (mm_serialize_is_id(n.id) == 0 || strcmp(n.id, c"end") == 0):
		out.failed = 1
		return
	mm_out(out, n.id)
	if (full == 0): return
	if (n.shape == 0):
		mm_out_char(out, '[')
		mm_serialize_uc_text(out, n.label)
		mm_out_char(out, ']')
	else if (strcmp(n.label, n.id) != 0 || full == 2):
		mm_out_char(out, '(')
		mm_serialize_uc_text(out, n.label)
		mm_out_char(out, ')')

void mm_serialize_uc_metadata(mm_serializer* out, mm_node* n):
	if (n.metadata.length == 0): return
	mm_out(out, c"@{ ")
	for i in range(n.metadata.length):
		mm_property* property = n.metadata[i]
		if (i > 0): mm_out(out, c", ")
		if (mm_serialize_is_id(property.key) == 0): out.failed = 1
		mm_out(out, property.key)
		mm_out(out, c": ")
		mm_serialize_quote(out, property.value)
	mm_out(out, c" }")

# JSON text for a string or literal row value.
void mm_serialize_uc_json_string(mm_serializer* out, char* text):
	mm_out_char(out, '"')
	char* digits = c"0123456789abcdef"
	for i in range(strlen(text)):
		int c = text[i] & 255
		if (c == '"' || c == 92):
			mm_out_char(out, 92)
			mm_out_char(out, c)
		else if (c == 10): mm_out(out, c"\\n")
		else if (c == 13): mm_out(out, c"\\r")
		else if (c == 9): mm_out(out, c"\\t")
		else if (c < 32):
			mm_out(out, c"\\u00")
			mm_out_char(out, digits[c >> 4])
			mm_out_char(out, digits[c & 15])
		else: mm_out_char(out, c)
	mm_out_char(out, '"')

int mm_serialize_uc_json_literal(char* text):
	if (strcmp(text, c"true") == 0 || strcmp(text, c"false") == 0 || strcmp(text, c"null") == 0 || strcmp(text, c"{}") == 0 || strcmp(text, c"[]") == 0): return 1
	int i = 0
	if (text[i] == '-'): i = i + 1
	if (isdigit(text[i]) == 0): return 0
	if (text[i] == '0' && isdigit(text[i + 1])): return 0
	while (isdigit(text[i])): i = i + 1
	if (text[i] == '.'):
		i = i + 1
		if (isdigit(text[i]) == 0): return 0
		while (isdigit(text[i])): i = i + 1
	if (text[i] == 'e' || text[i] == 'E'):
		i = i + 1
		if (text[i] == '+' || text[i] == '-'): i = i + 1
		if (isdigit(text[i]) == 0): return 0
		while (isdigit(text[i])): i = i + 1
	return text[i] == 0

# Length of the next path segment after prefix: `.key`, `key` (at the
# root) or `[i]`.
int mm_serialize_uc_segment(char* path, int at):
	int i = at
	if (path[i] == '['):
		while (path[i] != 0 && path[i] != ']'): i = i + 1
		if (path[i] == ']'): i = i + 1
		return i - at
	if (path[i] == '.'): i = i + 1
	while (path[i] != 0 && path[i] != '.' && path[i] != '['): i = i + 1
	return i - at

# 1 when the first length bytes of a and b are equal.
int mm_serialize_uc_prefix(char* a, char* b, int length):
	for i in range(length):
		if (a[i] != b[i] || a[i] == 0): return 0
	return 1

# Rows [low, high) all extend the path prefix of length at.
void mm_serialize_uc_json(mm_serializer* out, mm_node* n, int low, int high, int at, int depth):
	if (depth > 32 || low >= high):
		out.failed = 1
		return
	mm_attribute* first = n.attributes[low]
	if (first.type_name[at] == 0):
		if (high - low != 1): out.failed = 1
		if (mm_serialize_uc_json_literal(first.name)): mm_out(out, first.name)
		else: mm_serialize_uc_json_string(out, first.name)
		return
	int array = first.type_name[at] == '['
	if (array): mm_out_char(out, '[')
	else: mm_out_char(out, '{')
	int index = 0
	int i = low
	while (i < high):
		char* path = n.attributes[i].type_name
		int length = mm_serialize_uc_segment(path, at)
		int j = i + 1
		while (j < high && mm_serialize_uc_prefix(n.attributes[j].type_name + at, path + at, length) && mm_serialize_uc_segment(n.attributes[j].type_name, at) == length): j = j + 1
		if (index > 0): mm_out(out, c", ")
		if (array):
			string_builder* expected = string_from(c"[")
			string_append_int(expected, index)
			string_append_char(expected, ']')
			if (length != expected.length || mm_serialize_uc_prefix(path + at, expected.data, length) == 0): out.failed = 1
			string_free(expected)
		else:
			int start = at
			if (path[start] == '.'): start = start + 1
			else if (at != 0): out.failed = 1
			char* key = str_copy_range(path, start, at + length)
			mm_serialize_uc_json_string(out, key)
			free(key)
			mm_out(out, c": ")
		mm_serialize_uc_json(out, n, i, j, at + length, depth + 1)
		index = index + 1
		i = j
	if (array): mm_out_char(out, ']')
	else: mm_out_char(out, '}')

struct mm_uc_writer:
	mm_serializer* out
	mm_document* d
	list[int] created
	int boundary_done

int mm_serialize_uc_note_edge(mm_document* d, int index):
	for i in range(d.edges.length):
		if (d.edges[i].from_node == index && d.nodes[index].shape == MM_UC_NOTE): return i
	return -1

int mm_serialize_uc_is_note(mm_document* d, int index):
	mm_node* n = d.nodes[index]
	return n.shape == MM_UC_NOTE && n.group == 0 && starts_with(n.id, c"note@")

void mm_serialize_uc_create(mm_uc_writer* w, int index):
	if (index >= 0 && index < w.created.length): w.created[index] = 1

# Nodes an edge statement would create, in order; 1 when they are exactly
# the next nodes from next.
int mm_serialize_uc_edge_fits(mm_uc_writer* w, int e, int next):
	mm_edge* edge = w.d.edges[e]
	int expect = next
	list[int] order = new list[int]
	if (mm_serialize_uc_is_note(w.d, edge.from_node)):
		order.push(edge.to_node)
		order.push(edge.from_node)
	else:
		order.push(edge.from_node)
		order.push(edge.to_node)
	int fits = 1
	int seen = -1
	for int index in order:
		if (index < 0 || index >= w.created.length):
			fits = 0
			continue
		if (w.created[index] || index == seen): continue
		while (expect < w.created.length && w.created[expect]): expect = expect + 1
		if (index != expect): fits = 0
		seen = index
		expect = expect + 1
	__w_list_free(cast(__w_list*, order))
	return fits

void mm_serialize_uc_endpoint(mm_uc_writer* w, int index):
	mm_node* n = w.d.nodes[index]
	int full = n.declared == 0
	if (full && (n.parent != -1 || n.group || n.shape == MM_UC_ACTOR || n.shape == MM_UC_NOTE || n.shape == MM_UC_JSON)): w.out.failed = 1
	mm_serialize_uc_mention(w.out, n, full)
	mm_serialize_uc_create(w, index)

void mm_serialize_uc_operator(mm_serializer* out, mm_edge* e):
	int dashes = e.min_length + 1
	if (e.dashed):
		if (e.right_marker != MM_ARROW || e.left_marker != 0 || e.min_length != 0 || mm_in_words(e.label, c"|include|extend|") == 0): out.failed = 1
		mm_out(out, c"..>: ")
		mm_out(out, e.label)
		return
	if (e.left_marker == MM_UC_CIRCLE || e.left_marker == MM_UC_CROSS):
		if (e.right_marker != 0 || e.min_length != 0 || e.label[0] != 0): out.failed = 1
		if (e.left_marker == MM_UC_CIRCLE): mm_out(out, c"o--")
		else: mm_out(out, c"x--")
		return
	if (e.left_marker == MM_ARROW):
		if (e.right_marker != 0 || e.label[0] != 0 || dashes < 2): out.failed = 1
		mm_out_char(out, '<')
		for i in range(dashes): mm_out_char(out, '-')
		return
	if (e.left_marker != 0): out.failed = 1
	if (e.right_marker == MM_TRIANGLE || e.right_marker == MM_UC_CIRCLE || e.right_marker == MM_UC_CROSS):
		if (e.min_length != 0 || e.label[0] != 0): out.failed = 1
		if (e.right_marker == MM_TRIANGLE): mm_out(out, c"--|>")
		else if (e.right_marker == MM_UC_CIRCLE): mm_out(out, c"--o")
		else: mm_out(out, c"--x")
		return
	if (e.right_marker != 0 && e.right_marker != MM_ARROW): out.failed = 1
	if (dashes < 2): out.failed = 1
	if (e.label[0] != 0):
		mm_out(out, c"-- ")
		mm_serialize_uc_text(out, e.label)
		mm_out_char(out, 32)
	for i in range(dashes): mm_out_char(out, '-')
	if (e.right_marker == MM_ARROW): mm_out_char(out, '>')

void mm_serialize_uc_edge(mm_uc_writer* w, int index):
	mm_serializer* out = w.out
	mm_document* d = w.d
	mm_edge* e = d.edges[index]
	if (e.from_node < 0 || e.to_node < 0 || e.from_node >= d.nodes.length || e.to_node >= d.nodes.length || e.scope != -1):
		out.failed = 1
		return
	if (mm_serialize_uc_is_note(d, e.from_node)):
		mm_node* note = d.nodes[e.from_node]
		if (e.dashed != 1 || e.left_marker != 0 || e.right_marker != 0 || e.label[0] != 0 || e.id != 0 || e.min_length != 0 || e.arrow != 0 || e.style.mask != 0): out.failed = 1
		mm_out(out, c"note for ")
		mm_serialize_uc_endpoint(w, e.to_node)
		mm_out_char(out, 32)
		mm_serialize_uc_text(out, note.label)
		mm_out_line(out)
		mm_serialize_uc_create(w, e.from_node)
		return
	mm_serialize_uc_endpoint(w, e.from_node)
	mm_out_char(out, 32)
	if (e.id != 0):
		if (mm_serialize_is_id(e.id) == 0): out.failed = 1
		mm_out(out, e.id)
		mm_out_char(out, '@')
	mm_serialize_uc_operator(out, e)
	mm_out_char(out, 32)
	mm_serialize_uc_endpoint(w, e.to_node)
	mm_out_line(out)

# The declaration statement of node index (no indentation).
void mm_serialize_uc_declare(mm_uc_writer* w, int index):
	mm_serializer* out = w.out
	mm_node* n = w.d.nodes[index]
	if (n.declared == 0 || (n.attributes.length != 0 && n.shape != MM_UC_JSON)): out.failed = 1
	mm_out_indent(out)
	if (n.shape == MM_UC_JSON):
		if (n.metadata.length != 0 || n.parent != -1 || strcmp(n.label, n.id) != 0 || n.attributes.length == 0): out.failed = 1
		mm_out(out, c"json ")
		mm_serialize_uc_mention(out, n, 0)
		mm_out_char(out, '@')
		if (n.attributes.length == 1 && n.attributes[0].type_name[0] == 0):
			if (strcmp(n.attributes[0].name, c"{}") != 0): out.failed = 1
			mm_out(out, c"{}")
		else: mm_serialize_uc_json(out, n, 0, n.attributes.length, 0, 0)
	else:
		if (n.shape == MM_UC_ACTOR):
			mm_out(out, c"actor ")
			if (strcmp(n.label, n.id) != 0):
				mm_out(out, n.id)
				mm_out_char(out, '(')
				mm_serialize_uc_text(out, n.label)
				mm_out_char(out, ')')
			else: mm_serialize_uc_mention(out, n, 0)
		else:
			if (n.shape != 0 && n.shape != MM_UC_ELLIPSE): out.failed = 1
			# `ID@{` alone would be a metadata statement, not a declaration.
			if (n.metadata.length != 0): mm_serialize_uc_mention(out, n, 2)
			else: mm_serialize_uc_mention(out, n, 1)
		mm_serialize_uc_metadata(out, n)
	mm_out_line(out)
	mm_serialize_uc_create(w, index)

void mm_serialize_uc_boundary(mm_uc_writer* w, int group):
	mm_serializer* out = w.out
	mm_document* d = w.d
	mm_node* g = d.nodes[group]
	if (g.parent != -1 || g.declared == 0 || (g.shape != 0 && g.shape != MM_UC_ELLIPSE)): out.failed = 1
	mm_out(out, c"systemBoundary ")
	mm_serialize_uc_mention(out, g, 1)
	mm_serialize_uc_metadata(out, g)
	mm_out_line(out)
	mm_serialize_uc_create(w, group)
	out.depth = 1
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != group): continue
		if (n.group || n.shape == MM_UC_NOTE || n.shape == MM_UC_JSON): out.failed = 1
		mm_serialize_uc_declare(w, i)
	out.depth = 0
	mm_out(out, c"end\n")

void mm_serialize_usecase_body(mm_serializer* out, mm_document* d, int variant):
	if (d.notes.length != 0 || d.narrative.length != 0 || d.data != 0 || d.railroad != 0 || d.edge_style.mask != 0): out.failed = 1
	mm_out(out, c"usecase-beta\n")
	mm_out(out, c"direction ")
	mm_out(out, d.direction)
	mm_out_line(out)
	mm_serialize_accessibility(out, d)
	mm_serialize_class_defs(out, d)
	mm_uc_writer w
	w.out = out
	w.d = d
	w.created = new list[int]
	for i in range(d.nodes.length): w.created.push(0)
	int next = 0
	int edge = 0
	int guard = 0
	list[int] declared = new list[int]
	for i in range(d.nodes.length): declared.push(0)
	while ((next < d.nodes.length || edge < d.edges.length) && out.failed == 0 && guard <= d.nodes.length + d.edges.length + 2):
		guard = guard + 1
		while (next < d.nodes.length && w.created[next]): next = next + 1
		# Declarations create their node where its index falls; relationships
		# create the nodes no declaration names.
		if (next < d.nodes.length):
			mm_node* n = d.nodes[next]
			if (n.group):
				mm_serialize_uc_boundary(&w, next)
				declared[next] = 1
				for i in range(d.nodes.length):
					if (d.nodes[i].parent == next): declared[i] = 1
				continue
			if (n.declared && n.parent == -1 && mm_serialize_uc_is_note(d, next) == 0):
				mm_serialize_uc_declare(&w, next)
				declared[next] = 1
				continue
		if (edge < d.edges.length && mm_serialize_uc_edge_fits(&w, edge, next)):
			mm_serialize_uc_edge(&w, edge)
			edge = edge + 1
			continue
		out.failed = 1
	while (next < d.nodes.length && w.created[next]): next = next + 1
	if (next < d.nodes.length || edge < d.edges.length): out.failed = 1
	# Declared nodes a relationship created first.
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (declared[i] || n.declared == 0 || mm_serialize_uc_is_note(d, i)): continue
		if (n.parent != -1): out.failed = 1
		mm_serialize_uc_declare(&w, i)
	__w_list_free(cast(__w_list*, declared))
	__w_list_free(cast(__w_list*, w.created))
	# Metadata of nodes never declared, edge animation, then styles.
	for mm_node* n in d.nodes:
		if (n.declared || n.metadata.length == 0): continue
		mm_serialize_uc_mention(out, n, 0)
		mm_serialize_uc_metadata(out, n)
		mm_out_line(out)
	for mm_edge* e in d.edges:
		if (e.arrow == 0): continue
		if (e.id == 0 || e.arrow < 0 || e.arrow > 3):
			out.failed = 1
			continue
		mm_out(out, e.id)
		if (e.arrow == 2): mm_out(out, c"@{ animate: true }\n")
		else if (e.arrow == 1): mm_out(out, c"@{ animation: slow }\n")
		else: mm_out(out, c"@{ animation: fast }\n")
	for mm_node* n in d.nodes: mm_serialize_node_style(out, d, n)
	for mm_edge* e in d.edges:
		if (e.style.mask == 0): continue
		if (e.id == 0):
			out.failed = 1
			continue
		mm_out(out, c"style ")
		mm_out(out, e.id)
		mm_out_char(out, 32)
		mm_serialize_style(out, d, &e.style)
