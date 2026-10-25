# Canonical indentation-based families: mindmap and Kanban (one line per
# node, two spaces per level, shapes, icons, classes and card metadata) and
# the TreeView / Ishikawa outlines (labels, descriptions, icons, classes).
import libs.extras.mermaid.serialize_common

int mm_serialize_tree_depth(mm_document* d, int index):
	int depth = 0
	int at = d.nodes[index].parent
	while (at >= 0 && depth <= d.nodes.length):
		depth = depth + 1
		at = d.nodes[at].parent
	return depth

void mm_serialize_tree_indent(mm_serializer* out, int depth):
	for i in range(depth): mm_out(out, c"  ")

# Text that a line-oriented parser would misread at the start of a line.
int mm_serialize_line_lead_unsafe(char* text):
	if (text[0] == 0 || text[0] == 32 || text[0] == 9 || text[0] == '"' || text[0] == ':' || starts_with(text, c"%%")): return 1
	if ((starts_with(text, c"accTitle") || starts_with(text, c"accDescr")) && mm_id_char(text[8] & 255) == 0): return 1
	int length = strlen(text)
	return (text[length - 1] & 255) <= 32

int mm_serialize_hierarchy_generated(mm_node* n):
	return starts_with(n.id, c"@hierarchy:")

# Kanban card metadata values in the quote they do not contain.
void mm_serialize_kanban_value(mm_serializer* out, char* value):
	int quote = '\''
	if (index_of(value, c"'") >= 0): quote = '"'
	if (index_of(value, c"\"") >= 0 && quote == '"'): out.failed = 1
	int length = strlen(value)
	if (length == 0 || value[length - 1] == 32): out.failed = 1
	mm_out_char(out, quote)
	mm_out_plain(out, value, 0)
	mm_out_char(out, quote)

void mm_serialize_mindmap_node(mm_serializer* out, mm_document* d, int index):
	mm_node* n = d.nodes[index]
	int generated = mm_serialize_hierarchy_generated(n)
	int depth = mm_serialize_tree_depth(d, index)
	if (d.kind == MM_KANBAN && depth > 1): out.failed = 1
	mm_serialize_tree_indent(out, depth)
	char* id = n.id
	char* written = 0
	if (d.kind == MM_KANBAN):
		for mm_property* property in n.metadata:
			if (strcmp(property.key, c"id") == 0): written = property.value
		if (written != 0 && generated == 0): out.failed = 1
		if (written != 0): id = written
	char* open = c"["
	char* close = c"]"
	if (n.shape == 1):
		open = c"("
		close = c")"
	else if (n.shape == 2):
		open = c"(("
		close = c"))"
	else if (n.shape == 3):
		open = c")"
		close = c"("
	else if (n.shape == 4):
		open = c"))"
		close = c"(("
	else if (n.shape == 5):
		open = c"{{"
		close = c"}}"
	else if (n.shape != 0): out.failed = 1
	if (d.kind == MM_KANBAN && n.shape != 0): out.failed = 1
	int bare = generated && written == 0 && n.shape == 0 && mm_serialize_line_lead_unsafe(n.label) == 0
	for i in range(strlen(n.label)):
		int c = n.label[i]
		if (c == '[' || c == '(' || c == ')' || c == '{' || c == '@' || c == ':'): bare = 0
	if (bare): mm_out_plain(out, n.label, 0)
	else:
		if (generated == 0 || written != 0):
			if (mm_serialize_line_lead_unsafe(id)): out.failed = 1
			for i in range(strlen(id)):
				int c = id[i]
				if (c == '[' || c == '(' || c == ')' || c == '{' || c == '@' || c == ':'): out.failed = 1
			mm_out_plain(out, id, 0)
		mm_out(out, open)
		mm_serialize_flow_label(out, n.label)
		mm_out(out, close)
	if (d.kind == MM_KANBAN && n.members.length != 0):
		mm_out(out, c"@{ ")
		for i in range(n.members.length):
			char* text = n.members[i].text
			int colon = index_of(text, c": ")
			if (colon <= 0):
				out.failed = 1
				continue
			if (i > 0): mm_out(out, c", ")
			char* key = str_copy_range(text, 0, colon)
			mm_out(out, key)
			mm_out(out, c": ")
			mm_serialize_kanban_value(out, text + colon + 2)
			free(key)
		mm_out(out, c" }")
	if (d.kind == MM_KANBAN && n.members.length == 0 && n.annotation[0] != 0): out.failed = 1
	if (d.kind == MM_MINDMAP && n.style_classes[0] != 0):
		char* classes = replace(n.style_classes, c",", c" ")
		mm_out(out, c" :::")
		mm_out(out, classes)
		free(classes)
	mm_out_line(out)
	if (d.kind == MM_MINDMAP && n.annotation[0] != 0):
		mm_serialize_tree_indent(out, depth + 1)
		mm_out(out, c"::icon(")
		mm_out_plain(out, n.annotation, c")")
		mm_out(out, c")\n")
	if (d.kind == MM_KANBAN && n.style_classes[0] != 0): out.failed = 1

char* mm_serialize_outline_icon(mm_node* n):
	for mm_property* property in n.metadata:
		if (strcmp(property.key, c"icon") == 0): return property.value
	return 0

void mm_serialize_outline_node(mm_serializer* out, mm_document* d, int index):
	mm_node* n = d.nodes[index]
	mm_serialize_tree_indent(out, mm_serialize_tree_depth(d, index))
	char* label = n.label
	int tree = d.kind == MM_TREEVIEW
	# A label is quoted when its own text would be read as something else.
	int quoted = mm_serialize_line_lead_unsafe(label) || (label[0] & 255) == 0xE2
	if (index_of(label, c"##") >= 0 || index_of(label, c":::") >= 0 || index_of(label, c"icon(") >= 0): quoted = 1
	if (quoted && (index_of(label, c"##") >= 0 || index_of(label, c":::") >= 0 || index_of(label, c"icon(") >= 0)): out.failed = 1
	if (tree == 0 && (index_of(label, c"├") >= 0 || index_of(label, c"└") >= 0 || index_of(label, c"│") >= 0)): out.failed = 1
	if (quoted): mm_out_char(out, '"')
	mm_out_plain(out, label, 0)
	if (quoted): mm_out_char(out, '"')
	char* icon = mm_serialize_outline_icon(n)
	if ((icon != 0 || n.style_classes[0] != 0 || n.annotation[0] != 0) && tree == 0): out.failed = 1
	if (n.metadata.length > 1 || (n.metadata.length == 1 && icon == 0)): out.failed = 1
	if (n.style_classes[0] != 0):
		char* classes = replace(n.style_classes, c",", c" ")
		mm_out(out, c" :::")
		mm_out(out, classes)
		free(classes)
	if (icon != 0):
		mm_out(out, c" icon(")
		if (icon[0] == 0): mm_out(out, c"none")
		else: mm_out(out, icon)
		mm_out(out, c")")
	if (n.annotation[0] != 0):
		mm_out(out, c" ## ")
		mm_out_plain(out, n.annotation, 0)
	mm_out_line(out)

void mm_serialize_hierarchy_body(mm_serializer* out, mm_document* d, int variant):
	if (d.edges.length != 0 || d.notes.length != 0 || d.narrative.length != 0 || d.data != 0 || d.railroad != 0 || strcmp(d.direction, c"TB") != 0): out.failed = 1
	if (d.kind == MM_MINDMAP): mm_out(out, c"mindmap\n")
	else if (d.kind == MM_KANBAN): mm_out(out, c"kanban\n")
	else if (d.kind == MM_TREEVIEW): mm_out(out, c"treeView-beta\n")
	else: mm_out(out, c"ishikawa-beta\n")
	mm_serialize_accessibility(out, d)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent >= i || n.group || n.style.mask != 0 || n.attributes.length != 0): out.failed = 1
		if (d.kind == MM_MINDMAP || d.kind == MM_KANBAN): mm_serialize_mindmap_node(out, d, i)
		else:
			if (n.members.length != 0 || starts_with(n.id, c"@outline:") == 0): out.failed = 1
			mm_serialize_outline_node(out, d, i)
