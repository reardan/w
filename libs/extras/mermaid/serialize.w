# Canonical serialization of the flowchart/ER model. Unlike mm_write this
# deliberately replaces formatting/comments and emits one standalone diagram.
# Null means an invalid or unsupported model; no approximate output is returned.
import libs.extras.mermaid.parser

struct mm_serializer:
	string_builder* text
	int failed
	int nodes
	int edges
	list[int] edge_order

void mm_serialize_quote(mm_serializer* out, char* text):
	if (text == 0):
		out.failed = 1
		return
	string_append_char(out.text, '"')
	for i in range(strlen(text)):
		int c = text[i] & 255
		if (c == '"' || c < 32): out.failed = 1
		string_append_char(out.text, c)
	string_append_char(out.text, '"')

void mm_serialize_color(mm_serializer* out, int color):
	if (color == -1):
		string_append(out.text, c"none")
		return
	if (color < 0 || color > 16777215): out.failed = 1
	string_append_char(out.text, '#')
	char* digits = c"0123456789abcdef"
	for i in range(6): string_append_char(out.text, digits[(color >> ((5 - i) * 4)) & 15])

void mm_serialize_style(mm_serializer* out, mm_style* style):
	if (style.mask < 1 || style.mask > 15): out.failed = 1
	int comma = 0
	if (style.mask & MM_STYLE_FILL):
		string_append(out.text, c"fill:")
		mm_serialize_color(out, style.fill)
		comma = 1
	if (style.mask & MM_STYLE_STROKE):
		if (comma): string_append_char(out.text, ',')
		string_append(out.text, c"stroke:")
		mm_serialize_color(out, style.stroke)
		comma = 1
	if (style.mask & MM_STYLE_TEXT):
		if (comma): string_append_char(out.text, ',')
		string_append(out.text, c"color:")
		mm_serialize_color(out, style.text)
		comma = 1
	if (style.mask & MM_STYLE_WIDTH):
		if (comma): string_append_char(out.text, ',')
		string_append(out.text, c"stroke-width:")
		if (style.width < 1 || style.width > 16): out.failed = 1
		string_append_int(out.text, style.width)
	string_append_char(out.text, 10)

void mm_serialize_node_style(mm_serializer* out, mm_node* n):
	if (n.style.mask != 0):
		string_append(out.text, c"style ")
		string_append(out.text, n.id)
		string_append_char(out.text, 32)
		mm_serialize_style(out, &n.style)
	if (n.style_classes[0] != 0):
		string_append(out.text, c"class ")
		string_append(out.text, n.id)
		string_append_char(out.text, 32)
		string_append(out.text, n.style_classes)
		string_append_char(out.text, 10)

void mm_serialize_shape(mm_serializer* out, mm_node* n):
	char* open = c"["
	char* close = c"]"
	if (n.shape == 1):
		open = c"("
		close = c")"
	else if (n.shape == 2):
		open = c"(("
		close = c"))"
	else if (n.shape == 3):
		open = c"{"
		close = c"}"
	else if (n.shape == 21):
		open = c"(["
		close = c"])"
	else if (n.shape == 22):
		open = c"[["
		close = c"]]"
	else if (n.shape == 23):
		open = c"{{"
		close = c"}}"
	else if (n.shape >= 24 && n.shape <= 27):
		open = c"[/"
		close = c"/]"
		if (n.shape == 25 || n.shape == 27): open = c"[\\"
		if (n.shape == 25 || n.shape == 26): close = c"\\]"
	else if (n.shape != 0): out.failed = 1
	string_append(out.text, open)
	mm_serialize_quote(out, n.label)
	string_append(out.text, close)

void mm_serialize_edge(mm_serializer* out, mm_document* d, mm_edge* edge):
	if (edge.from_node < 0 || edge.from_node >= d.nodes.length || edge.to_node < 0 || edge.to_node >= d.nodes.length):
		out.failed = 1
		return
	if (edge.from_port != 0 || edge.to_port != 0 || edge.left_marker != 0 || edge.right_marker != 0): out.failed = 1
	mm_serialize_quote(out, d.nodes[edge.from_node].id)
	string_append_char(out.text, 32)
	if (d.kind == MM_ER):
		list[char*] left = list[char*]{c"|o", c"||", c"}o", c"}|"}
		list[char*] right = list[char*]{c"o|", c"||", c"o{", c"|{"}
		if (edge.left_card < 0 || edge.left_card > 3 || edge.right_card < 0 || edge.right_card > 3): out.failed = 1
		else:
			string_append(out.text, left[edge.left_card])
			if (edge.dashed): string_append(out.text, c"..")
			else: string_append(out.text, c"--")
			string_append(out.text, right[edge.right_card])
		__w_list_free(cast(__w_list*, left))
		__w_list_free(cast(__w_list*, right))
	else:
		if (edge.dashed):
			if (edge.arrow == 0): out.failed = 1
			string_append(out.text, c"-.->")
		else if (edge.arrow): string_append(out.text, c"-->")
		else: string_append(out.text, c"---")
		if (edge.label[0] != 0):
			string_append_char(out.text, '|')
			mm_serialize_quote(out, edge.label)
			string_append_char(out.text, '|')
	string_append_char(out.text, 32)
	mm_serialize_quote(out, d.nodes[edge.to_node].id)
	if (d.kind == MM_ER):
		string_append(out.text, c" : ")
		mm_serialize_quote(out, edge.label)
	string_append_char(out.text, 10)
	if (edge.style.mask != 0):
		string_append(out.text, c"linkStyle ")
		string_append_int(out.text, out.edges)
		string_append_char(out.text, 32)
		mm_serialize_style(out, &edge.style)
	out.edges = out.edges + 1

void mm_serialize_scope(mm_serializer* out, mm_document* d, int scope, int depth):
	if (depth > 32):
		out.failed = 1
		return
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != scope): continue
		out.nodes = out.nodes + 1
		if (n.annotation[0] != 0 || n.members.length != 0 || n.metadata.length != 0 || n.global_node || n.role[0] != 0): out.failed = 1
		if (n.group && n.attributes.length > 0): out.failed = 1
		if (n.group): string_append(out.text, c"subgraph ")
		mm_serialize_quote(out, n.id)
		mm_serialize_shape(out, n)
		string_append_char(out.text, 10)
		if (n.group):
			if (n.direction[0] != 0):
				string_append(out.text, c"direction ")
				string_append(out.text, n.direction)
				string_append_char(out.text, 10)
			mm_serialize_scope(out, d, i, depth + 1)
			string_append(out.text, c"end\n")
		else if (n.attributes.length > 0):
			if (d.kind != MM_ER): out.failed = 1
			mm_serialize_quote(out, n.id)
			string_append(out.text, c" {\n")
			for mm_attribute* a in n.attributes:
				string_append(out.text, a.type_name)
				string_append_char(out.text, 32)
				string_append(out.text, a.name)
				if (a.keys[0] != 0):
					string_append_char(out.text, 32)
					string_append(out.text, a.keys)
				if (a.comment[0] != 0):
					string_append_char(out.text, 32)
					mm_serialize_quote(out, a.comment)
				string_append_char(out.text, 10)
			string_append(out.text, c"}\n")
		mm_serialize_node_style(out, n)
	for i in range(d.edges.length):
		mm_edge* edge = d.edges[i]
		if (edge.scope == scope):
			out.edge_order.push(i)
			mm_serialize_edge(out, d, edge)

# Compare the semantics we promise to serialize, not just syntactic validity.
# This also rejects tokens mutated into statement injections by model callers.
int mm_serialize_text_equal(char* a, char* b):
	if (a == 0): a = c""
	if (b == 0): b = c""
	return strcmp(a, b) == 0

int mm_serialize_style_equal(mm_style* a, mm_style* b):
	if (a.mask != b.mask): return 0
	if ((a.mask & MM_STYLE_FILL) && a.fill != b.fill): return 0
	if ((a.mask & MM_STYLE_STROKE) && a.stroke != b.stroke): return 0
	if ((a.mask & MM_STYLE_TEXT) && a.text != b.text): return 0
	if ((a.mask & MM_STYLE_WIDTH) && a.width != b.width): return 0
	return 1

# State start/end pseudo-states are identified as "@start:<scope index>". Returns
# the prefix length (and the scope through *scope) or 0 for any other identifier.
int mm_serialize_pseudo(char* id, int* scope):
	int length = 0
	if (starts_with(id, c"@start:")): length = 7
	else if (starts_with(id, c"@end:")): length = 5
	if (length == 0): return 0
	int at = length
	int sign = 1
	if (id[at] == '-'):
		sign = -1
		at = at + 1
	int value = 0
	if (id[at] == 0): return 0
	while (id[at] >= '0' && id[at] <= '9' && value < MM_MAX_ITEMS):
		value = value * 10 + id[at] - '0'
		at = at + 1
	if (id[at] != 0): return 0
	*scope = sign * value
	return length

# Node references compare by identity. A pseudo-state's identity is its kind
# plus its composite's identity, since edits may shift the composite's index.
int mm_serialize_reference_equal(mm_document* a, int ai, mm_document* b, int bi):
	if (ai == -1 || bi == -1): return ai == bi
	if (ai < 0 || ai >= a.nodes.length || bi < 0 || bi >= b.nodes.length): return 0
	int a_scope = 0
	int b_scope = 0
	int a_prefix = mm_serialize_pseudo(a.nodes[ai].id, &a_scope)
	int b_prefix = mm_serialize_pseudo(b.nodes[bi].id, &b_scope)
	if (a_prefix != 0 && a_prefix == b_prefix && a_scope >= 0 && b_scope >= 0 && a_scope < ai && b_scope < bi): return mm_serialize_reference_equal(a, a_scope, b, b_scope)
	return mm_serialize_text_equal(a.nodes[ai].id, b.nodes[bi].id)

# The node of b with the same identity as a.nodes[index], or -1.
int mm_serialize_find_equal(mm_document* a, int index, mm_document* b):
	int scope = 0
	int prefix = mm_serialize_pseudo(a.nodes[index].id, &scope)
	if (prefix == 0 || scope < 0 || scope >= index): return mm_find_node(b, a.nodes[index].id)
	int other = mm_serialize_find_equal(a, scope, b)
	if (other < 0): return -1
	string_builder* key = string_new()
	string_append_bytes(key, a.nodes[index].id, prefix)
	string_append_int(key, other)
	int found = mm_find_node(b, key.data)
	string_free(key)
	return found

int mm_serialize_node_equal(mm_node* a, mm_node* b):
	if (mm_serialize_text_equal(a.label, b.label) == 0 || a.shape != b.shape || a.group != b.group): return 0
	if (mm_serialize_text_equal(a.direction, b.direction) == 0 || mm_serialize_text_equal(a.style_classes, b.style_classes) == 0): return 0
	if (mm_serialize_style_equal(&a.style, &b.style) == 0): return 0
	if (a.attributes.length != b.attributes.length): return 0
	for i in range(a.attributes.length):
		mm_attribute* left = a.attributes[i]
		mm_attribute* right = b.attributes[i]
		if (mm_serialize_text_equal(left.type_name, right.type_name) == 0 || mm_serialize_text_equal(left.name, right.name) == 0): return 0
		if (mm_serialize_text_equal(left.keys, right.keys) == 0 || mm_serialize_text_equal(left.comment, right.comment) == 0): return 0
	# Family-specific model state must not silently disappear.
	if (a.value_x != b.value_x || a.value_y != b.value_y || a.declared != b.declared || a.global_node != b.global_node): return 0
	if (mm_serialize_text_equal(a.annotation, b.annotation) == 0 || mm_serialize_text_equal(a.role, b.role) == 0): return 0
	if (a.members.length != b.members.length || a.metadata.length != b.metadata.length): return 0
	return 1

int mm_serialize_edge_equal(mm_document* a, mm_edge* left, mm_document* b, mm_edge* right):
	if (mm_serialize_reference_equal(a, left.from_node, b, right.from_node) == 0 || mm_serialize_reference_equal(a, left.to_node, b, right.to_node) == 0): return 0
	if (mm_serialize_reference_equal(a, left.scope, b, right.scope) == 0): return 0
	if (mm_serialize_text_equal(left.label, right.label) == 0 || mm_serialize_text_equal(left.left_label, right.left_label) == 0 || mm_serialize_text_equal(left.right_label, right.right_label) == 0): return 0
	if (left.dashed != right.dashed || left.arrow != right.arrow || left.left_card != right.left_card || left.right_card != right.right_card): return 0
	if (left.from_port != right.from_port || left.to_port != right.to_port || left.left_marker != right.left_marker || left.right_marker != right.right_marker): return 0
	return mm_serialize_style_equal(&left.style, &right.style)

char* mm_serialize(mm_document* d):
	if (d == 0 || d.error != 0 || (d.kind != MM_FLOW && d.kind != MM_ER)): return 0
	if (d.notes.length != 0 || d.narrative.length != 0 || d.data != 0 || d.railroad != 0 || d.graph_variant != 0): return 0
	# Theme serialization is not yet canonical: do not silently discard it.
	if (d.theme != 0 || d.palette.mask != 0 || d.layout_algorithm != 0): return 0
	mm_serializer out
	out.text = string_new()
	out.failed = 0
	out.nodes = 0
	out.edges = 0
	out.edge_order = new list[int]
	if (d.title[0] != 0):
		string_append(out.text, c"---\ntitle: ")
		mm_serialize_quote(&out, d.title)
		string_append(out.text, c"\n---\n")
	if (d.kind == MM_FLOW):
		string_append(out.text, c"flowchart ")
		string_append(out.text, d.direction)
		string_append_char(out.text, 10)
	else:
		string_append(out.text, c"erDiagram\ndirection ")
		string_append(out.text, d.direction)
		string_append_char(out.text, 10)
	if (d.accessibility_title[0] != 0):
		string_append(out.text, c"accTitle: ")
		string_append(out.text, d.accessibility_title)
		string_append_char(out.text, 10)
	if (d.accessibility_description[0] != 0):
		string_append(out.text, c"accDescr {")
		string_append(out.text, d.accessibility_description)
		string_append(out.text, c"}\n")
	for mm_style_class* definition in d.style_definitions:
		string_append(out.text, c"classDef ")
		string_append(out.text, definition.name)
		string_append_char(out.text, 32)
		mm_serialize_style(&out, &definition.style)
	if (d.edge_style.mask != 0):
		string_append(out.text, c"linkStyle default ")
		mm_serialize_style(&out, &d.edge_style)
	mm_serialize_scope(&out, d, -1, 0)
	if (out.nodes != d.nodes.length || out.edges != d.edges.length || out.text.length > MM_MAX_SOURCE): out.failed = 1
	mm_document* check = mm_parse(out.text.data, out.text.length)
	if (check.error != 0 || check.nodes.length != d.nodes.length || check.edges.length != d.edges.length): out.failed = 1
	# Source order may change when scopes are normalized; identities and semantic
	# edge order are mapped explicitly, including per-edge linkStyle indices.
	for mm_node* n in d.nodes:
		int index = mm_find_node(check, n.id)
		if (index < 0): out.failed = 1
		else:
			mm_node* other = check.nodes[index]
			if (mm_serialize_node_equal(n, other) == 0): out.failed = 1
			if (mm_serialize_reference_equal(d, n.parent, check, other.parent) == 0): out.failed = 1
	if (out.edge_order.length != check.edges.length): out.failed = 1
	else:
		for i in range(check.edges.length):
			if (mm_serialize_edge_equal(d, d.edges[out.edge_order[i]], check, check.edges[i]) == 0): out.failed = 1
	if (d.style_definitions.length != check.style_definitions.length): out.failed = 1
	else:
		for i in range(d.style_definitions.length):
			mm_style_class* left = d.style_definitions[i]
			mm_style_class* right = check.style_definitions[i]
			if (mm_serialize_text_equal(left.name, right.name) == 0 || mm_serialize_style_equal(&left.style, &right.style) == 0): out.failed = 1
	if (d.kind != check.kind || mm_serialize_text_equal(d.direction, check.direction) == 0 || mm_serialize_style_equal(&d.edge_style, &check.edge_style) == 0): out.failed = 1
	if (strcmp(d.title, check.title) != 0 || strcmp(d.accessibility_title, check.accessibility_title) != 0 || strcmp(d.accessibility_description, check.accessibility_description) != 0): out.failed = 1
	__w_list_free(cast(__w_list*, out.edge_order))
	mm_document_free(check)
	if (out.failed):
		string_free(out.text)
		return 0
	char* result = out.text.data
	free(out.text)
	return result
