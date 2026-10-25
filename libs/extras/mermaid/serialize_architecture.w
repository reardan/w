# Canonical architecture source: every group, service and junction in node
# order (a parent first named by `in` is created right after its child),
# then the edges, then the alignment directives.
import libs.extras.mermaid.serialize_common

void mm_serialize_arch_port(mm_serializer* out, int port):
	int side = port & 7
	if (port < 0 || port > 15 || side < 1 || side > 4):
		out.failed = 1
		return
	char* sides = c"LRTB"
	mm_out_char(out, sides[side - 1])

# Text read by mm_until(close) inside an architecture declaration.
void mm_serialize_arch_text(mm_serializer* out, char* text, char* close):
	if (index_of(text, c"\"") < 0 && text[0] != '`'):
		mm_serialize_quote(out, text)
		return
	int length = strlen(text)
	if (length == 0 || text[0] == '"' || text[0] <= 32 || text[length - 1] <= 32): out.failed = 1
	mm_out_plain(out, text, close)

void mm_serialize_architecture_body(mm_serializer* out, mm_document* d, int variant):
	if (d.notes.length != 0 || d.narrative.length != 0 || d.data != 0 || d.railroad != 0 || strcmp(d.direction, c"TB") != 0): out.failed = 1
	mm_out(out, c"architecture-beta\n")
	out.depth = 1
	mm_serialize_accessibility(out, d)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.declared == 0 || n.style.mask != 0 || n.style_classes[0] != 0 || n.members.length != 0 || n.metadata.length != 0): out.failed = 1
		if (n.parent >= 0 && n.parent > i + 1): out.failed = 1
		mm_out_indent(out)
		if (n.shape == 13):
			if (n.group || n.annotation[0] != 0 || strcmp(n.label, n.id) != 0): out.failed = 1
			mm_out(out, c"junction ")
		else if (n.shape == 12):
			if (n.group): mm_out(out, c"group ")
			else: mm_out(out, c"service ")
		else: out.failed = 1
		mm_serialize_id(out, n.id)
		if (n.annotation[0] != 0):
			mm_out_char(out, '(')
			mm_serialize_arch_text(out, n.annotation, c")")
			mm_out_char(out, ')')
		if (strcmp(n.label, n.id) != 0):
			mm_out_char(out, '[')
			if (n.label[0] == 0): mm_out(out, c"\"\"")
			else: mm_serialize_arch_text(out, n.label, c"]")
			mm_out_char(out, ']')
		if (n.parent >= 0):
			mm_out(out, c" in ")
			mm_serialize_id(out, d.nodes[n.parent].id)
		mm_out_line(out)
	for mm_edge* e in d.edges:
		if (e.from_node < 0 || e.to_node < 0 || e.from_node >= d.nodes.length || e.to_node >= d.nodes.length || e.label[0] != 0 || e.style.mask != 0):
			out.failed = 1
			continue
		mm_out_indent(out)
		mm_serialize_id(out, d.nodes[e.from_node].id)
		if (e.from_port & 8): mm_out(out, c"{group}")
		mm_out_char(out, ':')
		mm_serialize_arch_port(out, e.from_port)
		mm_out_char(out, 32)
		if (e.left_marker): mm_out_char(out, '<')
		mm_out(out, c"--")
		if (e.right_marker): mm_out_char(out, '>')
		mm_out_char(out, 32)
		mm_serialize_arch_port(out, e.to_port)
		mm_out_char(out, ':')
		mm_serialize_id(out, d.nodes[e.to_node].id)
		if (e.to_port & 8): mm_out(out, c"{group}")
		mm_out_line(out)
	if (d.arch_align != 0):
		list[int] align = d.arch_align
		int at = 0
		while (at + 1 < align.length):
			int count = align[at + 1]
			mm_out_indent(out)
			if (align[at] == 0): mm_out(out, c"align row")
			else: mm_out(out, c"align column")
			for k in range(count):
				int member = align[at + 2 + k]
				if (member < 0 || member >= d.nodes.length):
					out.failed = 1
					continue
				mm_out_char(out, 32)
				mm_serialize_id(out, d.nodes[member].id)
			mm_out_line(out)
			at = at + 2 + count
	out.depth = 0
