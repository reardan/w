# Canonical block diagram source: every block, space and composite in its
# grid order (composites as indented `block ... end`), then the links, then
# styles. Blocks are declared before any link names them, so links never
# change a block's shape, label or span.
import libs.extras.mermaid.serialize_common

void mm_serialize_block_shape(mm_serializer* out, mm_node* n):
	char* open = 0
	char* close = 0
	int s = n.shape
	if (s == 0):
		open = c"["
		close = c"]"
	else if (s == 1):
		open = c"("
		close = c")"
	else if (s == 2):
		open = c"(("
		close = c"))"
	else if (s == 3):
		open = c"{"
		close = c"}"
	else if (s == 21):
		open = c"(["
		close = c"])"
	else if (s == 22):
		open = c"[["
		close = c"]]"
	else if (s == 23):
		open = c"{{"
		close = c"}}"
	else if (s >= 24 && s <= 27):
		open = c"[/"
		close = c"/]"
		if (s == 25 || s == 27): open = c"[\\"
		if (s == 25 || s == 26): close = c"\\]"
	else if (s == 40):
		open = c"[("
		close = c")]"
	else if (s == 41):
		open = c">"
		close = c"]"
	else if (s == 42):
		open = c"((("
		close = c")))"
	else if (s == 43):
		open = c"<["
		close = c"]>"
	else:
		out.failed = 1
		return
	if (s == 0 && strcmp(n.label, n.id) == 0): return
	mm_out(out, open)
	mm_serialize_flow_label(out, n.label)
	mm_out(out, close)
	if (s == 43):
		mm_out_char(out, '(')
		mm_out(out, n.direction)
		mm_out_char(out, ')')
	else if (n.direction[0] != 0): out.failed = 1

void mm_serialize_block_scope(mm_serializer* out, mm_document* d, int scope, int depth):
	if (depth > 32):
		out.failed = 1
		return
	mm_node* group = d.nodes[scope]
	if (group.value_x != 0):
		mm_out_indent(out)
		mm_out(out, c"columns ")
		mm_out_int(out, group.value_x)
		mm_out_line(out)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != scope): continue
		if ((n.declared == 0 && n.shape != -1) || n.members.length != 0 || n.metadata.length != 0): out.failed = 1
		mm_out_indent(out)
		if (n.group):
			mm_out(out, c"block")
			string_builder* generated = string_from(c"@block:")
			string_append_int(generated, i)
			if (strcmp(n.id, generated.data) != 0):
				mm_out_char(out, ':')
				if (mm_serialize_is_id(n.id) == 0): out.failed = 1
				mm_out(out, n.id)
			string_free(generated)
			if (n.label[0] != 0 || n.shape != 0 || n.direction[0] != 0): out.failed = 1
			mm_out_line(out)
			out.depth = out.depth + 1
			mm_serialize_block_scope(out, d, i, depth + 1)
			out.depth = out.depth - 1
			mm_out_indent(out)
			mm_out(out, c"end\n")
			continue
		if (n.shape == -1):
			string_builder* generated = string_from(c"@space:")
			string_append_int(generated, i)
			if (strcmp(n.id, generated.data) != 0 || n.label[0] != 0): out.failed = 1
			string_free(generated)
			mm_out(out, c"space")
			if (n.value_x != 1):
				mm_out_char(out, ':')
				mm_out_int(out, n.value_x)
			mm_out_line(out)
			continue
		mm_serialize_id(out, n.id)
		mm_serialize_block_shape(out, n)
		if (n.style_classes[0] != 0):
			mm_out(out, c":::")
			if (index_of(n.style_classes, c",") >= 0): out.failed = 1
			mm_out(out, n.style_classes)
		if (n.value_x != 1):
			mm_out(out, c":")
			mm_out_int(out, n.value_x)
		mm_out_line(out)

void mm_serialize_blocks_body(mm_serializer* out, mm_document* d, int variant):
	if (d.notes.length != 0 || d.narrative.length != 0 || d.data != 0 || d.railroad != 0 || strcmp(d.direction, c"TB") != 0): out.failed = 1
	if (d.nodes.length == 0 || strcmp(d.nodes[0].id, c"@block:root") != 0): out.failed = 1
	mm_out(out, c"block-beta\n")
	out.depth = 1
	mm_serialize_accessibility(out, d)
	mm_serialize_class_defs(out, d)
	if (out.failed == 0): mm_serialize_block_scope(out, d, 0, 0)
	list[char*] lines = list[char*]{c"---", c"-.-", c"==="}
	list[char*] arrows = list[char*]{c"-->", c"-.->", c"==>"}
	for mm_edge* e in d.edges:
		if (e.from_node <= 0 || e.to_node <= 0 || e.from_node >= d.nodes.length || e.to_node >= d.nodes.length || e.dashed < 0 || e.dashed > 2 || e.arrow < 0 || e.arrow > 1):
			out.failed = 1
			continue
		mm_out_indent(out)
		mm_serialize_id(out, d.nodes[e.from_node].id)
		mm_out_char(out, 32)
		if (e.arrow): mm_out(out, arrows[e.dashed])
		else: mm_out(out, lines[e.dashed])
		if (e.label[0] != 0):
			mm_out_char(out, '|')
			mm_serialize_flow_label(out, e.label)
			mm_out_char(out, '|')
		mm_out_char(out, 32)
		mm_serialize_id(out, d.nodes[e.to_node].id)
		mm_out_line(out)
	__w_list_free(cast(__w_list*, lines))
	__w_list_free(cast(__w_list*, arrows))
	for i in range(1, d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.style.mask == 0): continue
		mm_out_indent(out)
		mm_out(out, c"style ")
		if (mm_style_name(n.id) == 0): out.failed = 1
		mm_out(out, n.id)
		mm_out_char(out, 32)
		mm_serialize_style(out, d, &n.style)
	out.depth = 0
