# Canonical C4 source (all five headers): element and boundary calls in
# node order with their properties as named arguments, boundaries as
# `{ ... }` blocks, then the relationships, element and relationship style
# updates and the layout configuration.
import libs.extras.mermaid.serialize_common

# A C4 argument value: always quoted.
void mm_serialize_c4_value(mm_serializer* out, char* value):
	mm_serialize_quote(out, value)

void mm_serialize_c4_color(mm_serializer* out, char* name, int color):
	mm_out(out, c", $")
	mm_out(out, name)
	mm_out(out, c"=\"")
	mm_serialize_color(out, color)
	mm_out_char(out, '"')

# 1 when key is one of the function's own parameters after alias and label.
int mm_serialize_c4_own(char* function, char* key):
	char* signature = mm_c4_signature(function)
	if (signature == 0): return 0
	return mm_c4_param(signature, key) >= 2

void mm_serialize_c4_scope(mm_serializer* out, mm_document* d, int scope, int* next, int depth):
	if (depth > 32):
		out.failed = 1
		return
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != scope): continue
		# Declarations must come out in node order.
		if (i != next[0]): out.failed = 1
		next[0] = i + 1
		char* signature = mm_c4_signature(n.annotation)
		int group = mm_in_words(n.annotation, c"|Boundary|Enterprise_Boundary|System_Boundary|Container_Boundary|Deployment_Node|Node|Node_L|Node_R|")
		if (signature == 0 || mm_c4_param(signature, c"alias") != 0 || n.declared == 0 || n.group != group || n.label[0] == 0 || n.id[0] == 0):
			out.failed = 1
			continue
		if (n.members.length != 0 || n.attributes.length != 0 || n.style_classes[0] != 0): out.failed = 1
		mm_out_indent(out)
		mm_out(out, n.annotation)
		mm_out_char(out, '(')
		mm_serialize_c4_value(out, n.id)
		mm_out(out, c", ")
		mm_serialize_c4_value(out, n.label)
		for mm_property* property in n.metadata:
			if (mm_c4_param(signature, property.key) < 2): continue
			mm_out(out, c", $")
			mm_out(out, property.key)
			mm_out_char(out, '=')
			mm_serialize_c4_value(out, property.value)
		mm_out_char(out, ')')
		if (group):
			mm_out(out, c" {\n")
			out.depth = out.depth + 1
			mm_serialize_c4_scope(out, d, i, next, depth + 1)
			out.depth = out.depth - 1
			mm_out_indent(out)
			mm_out_char(out, '}')
		mm_out_line(out)

void mm_serialize_c4_body(mm_serializer* out, mm_document* d, int variant):
	if (d.notes.length != 0 || d.narrative.length != 0 || d.data != 0 || d.railroad != 0 || strcmp(d.direction, c"TB") != 0 || d.style_definitions.length != 0): out.failed = 1
	list[char*] headers = list[char*]{c"C4Context", c"C4Container", c"C4Component", c"C4Dynamic", c"C4Deployment"}
	if (d.graph_variant < 0 || d.graph_variant > 4): out.failed = 1
	else: mm_out(out, headers[d.graph_variant])
	__w_list_free(cast(__w_list*, headers))
	mm_out_line(out)
	out.depth = 1
	mm_serialize_accessibility(out, d)
	int next = 0
	mm_serialize_c4_scope(out, d, -1, &next, 0)
	if (next != d.nodes.length): out.failed = 1
	for i in range(d.edges.length):
		mm_edge* e = d.edges[i]
		if (e.from_node < 0 || e.to_node < 0 || e.from_node >= d.nodes.length || e.to_node >= d.nodes.length || e.right_marker != MM_ARROW || (e.left_marker != 0 && e.left_marker != MM_ARROW)):
			out.failed = 1
			continue
		char* label = e.label
		if (d.graph_variant == 3):
			string_builder* prefix = string_new()
			string_append_int(prefix, i + 1)
			string_append(prefix, c": ")
			if (starts_with(label, prefix.data) == 0): out.failed = 1
			else: label = label + prefix.length
			string_free(prefix)
		if (label[0] == 0): out.failed = 1
		mm_out_indent(out)
		if (e.left_marker): mm_out(out, c"BiRel")
		else: mm_out(out, c"Rel")
		if (e.from_port == 3 && e.to_port == 4): mm_out(out, c"_U")
		else if (e.from_port == 4 && e.to_port == 3): mm_out(out, c"_D")
		else if (e.from_port == 1 && e.to_port == 2): mm_out(out, c"_L")
		else if (e.from_port == 2 && e.to_port == 1): mm_out(out, c"_R")
		else if (e.from_port != 0 || e.to_port != 0): out.failed = 1
		mm_out_char(out, '(')
		mm_serialize_c4_value(out, d.nodes[e.from_node].id)
		mm_out(out, c", ")
		mm_serialize_c4_value(out, d.nodes[e.to_node].id)
		mm_out(out, c", ")
		mm_serialize_c4_value(out, label)
		mm_out(out, c")\n")
	for mm_node* n in d.nodes:
		char* techn = 0
		for mm_property* property in n.metadata:
			if (mm_serialize_c4_own(n.annotation, property.key) == 0):
				if (strcmp(property.key, c"techn") != 0): out.failed = 1
				techn = property.value
		if ((n.style.mask | MM_STYLE_FILL | MM_STYLE_TEXT | MM_STYLE_STROKE) != (MM_STYLE_FILL | MM_STYLE_TEXT | MM_STYLE_STROKE)): out.failed = 1
		if (n.style.mask == 0 && techn == 0): continue
		mm_out_indent(out)
		mm_out(out, c"UpdateElementStyle(")
		mm_serialize_c4_value(out, n.id)
		if (n.style.mask & MM_STYLE_FILL): mm_serialize_c4_color(out, c"bgColor", n.style.fill)
		if (n.style.mask & MM_STYLE_TEXT): mm_serialize_c4_color(out, c"fontColor", n.style.text)
		if (n.style.mask & MM_STYLE_STROKE): mm_serialize_c4_color(out, c"borderColor", n.style.stroke)
		if (techn != 0):
			mm_out(out, c", $techn=")
			mm_serialize_c4_value(out, techn)
		mm_out(out, c")\n")
	for mm_edge* e in d.edges:
		if ((e.style.mask | MM_STYLE_TEXT | MM_STYLE_STROKE) != (MM_STYLE_TEXT | MM_STYLE_STROKE)): out.failed = 1
		if (e.style.mask == 0 && e.label_dx == 0 && e.label_dy == 0): continue
		if (e.from_node < 0 || e.to_node < 0 || e.from_node >= d.nodes.length || e.to_node >= d.nodes.length): continue
		mm_out_indent(out)
		mm_out(out, c"UpdateRelStyle(")
		mm_serialize_c4_value(out, d.nodes[e.from_node].id)
		mm_out(out, c", ")
		mm_serialize_c4_value(out, d.nodes[e.to_node].id)
		if (e.style.mask & MM_STYLE_TEXT): mm_serialize_c4_color(out, c"textColor", e.style.text)
		if (e.style.mask & MM_STYLE_STROKE): mm_serialize_c4_color(out, c"lineColor", e.style.stroke)
		if (e.label_dx != 0):
			mm_out(out, c", $offsetX=\"")
			mm_out_int(out, e.label_dx)
			mm_out_char(out, '"')
		if (e.label_dy != 0):
			mm_out(out, c", $offsetY=\"")
			mm_out_int(out, e.label_dy)
			mm_out_char(out, '"')
		mm_out(out, c")\n")
	if (d.c4_shape_in_row != 0 || d.c4_boundary_in_row != 0):
		mm_out_indent(out)
		mm_out(out, c"UpdateLayoutConfig(")
		if (d.c4_shape_in_row != 0):
			mm_out(out, c"$c4ShapeInRow=\"")
			mm_out_int(out, d.c4_shape_in_row)
			mm_out_char(out, '"')
		if (d.c4_boundary_in_row != 0):
			if (d.c4_shape_in_row != 0): mm_out(out, c", ")
			mm_out(out, c"$c4BoundaryInRow=\"")
			mm_out_int(out, d.c4_boundary_in_row)
			mm_out_char(out, '"')
		mm_out(out, c")\n")
	out.depth = 0
