# Canonical requirement diagram source: every requirement and element block
# in node order (declaration order is the node order, since relationships
# may only name declared items), then the relationships, then styles.
import libs.extras.mermaid.serialize_common

# A property value as mm_property_value reads it: quoted when it would not
# survive as plain statement text.
void mm_serialize_requirement_value(mm_serializer* out, char* value):
	int length = strlen(value)
	int plain = length > 0 && value[0] != '"' && value[0] > 32 && value[length - 1] > 32 && index_of(value, c"%%") < 0
	for i in range(length):
		int c = value[i] & 255
		if (c == '{' || c == '}' || c == ';' || c == 10): plain = 0
	if (plain): mm_out(out, value)
	else: mm_serialize_quote(out, value)

void mm_serialize_requirement_body(mm_serializer* out, mm_document* d):
	if (d.notes.length != 0 || d.narrative.length != 0 || d.data != 0 || d.railroad != 0 || strcmp(d.direction, c"TB") != 0): out.failed = 1
	mm_out(out, c"requirementDiagram\n")
	out.depth = 1
	mm_serialize_accessibility(out, d)
	mm_serialize_class_defs(out, d)
	for mm_node* n in d.nodes:
		if (n.declared == 0 || n.group || n.parent != -1 || n.attributes.length != 0): out.failed = 1
		if (strcmp(n.label, n.id) != 0): out.failed = 1
		mm_out_indent(out)
		mm_out(out, n.annotation)
		mm_out_char(out, 32)
		mm_serialize_id(out, n.id)
		mm_out(out, c" {\n")
		out.depth = 2
		for mm_member* m in n.members:
			int colon = index_of(m.text, c": ")
			if (colon <= 0):
				out.failed = 1
				continue
			char* key = str_copy_range(m.text, 0, colon)
			mm_out_indent(out)
			mm_out(out, key)
			mm_out(out, c": ")
			mm_serialize_requirement_value(out, m.text + colon + 2)
			mm_out_line(out)
			free(key)
		out.depth = 1
		mm_out_indent(out)
		mm_out(out, c"}\n")
	for mm_edge* e in d.edges:
		if (e.from_node < 0 || e.to_node < 0 || e.from_node >= d.nodes.length || e.to_node >= d.nodes.length):
			out.failed = 1
			continue
		mm_out_indent(out)
		mm_serialize_id(out, d.nodes[e.from_node].id)
		mm_out(out, c" - ")
		mm_out(out, e.label)
		mm_out(out, c" -> ")
		mm_serialize_id(out, d.nodes[e.to_node].id)
		mm_out_line(out)
	for mm_node* n in d.nodes: mm_serialize_node_style(out, d, n)
	out.depth = 0
