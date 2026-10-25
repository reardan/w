# Canonical flowchart, ER and agentflow source. Scopes are written as
# indented subgraph/flow blocks; within a scope, plain nodes come first, then
# child blocks and edges in edge order (a block sits where its first edge
# was), so edge indices and linkStyle numbers survive. When that order would
# create nodes in a different order, a leading line of bare identifiers fixes
# the model's node order first.
import libs.extras.mermaid.serialize_common

void mm_serialize_repeat(mm_serializer* out, int c, int count):
	for i in range(count): string_append_char(out.text, c)

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
	else if (n.shape == MM_FLOW_CYLINDER):
		open = c"[("
		close = c")]"
	else if (n.shape == MM_FLOW_DOUBLE_CIRCLE):
		open = c"((("
		close = c")))"
	else if (n.shape == MM_FLOW_ODD): open = c">"
	else if (n.shape != 0): out.failed = 1
	string_append(out.text, open)
	mm_serialize_flow_label(out, n.label)
	string_append(out.text, close)

# Every `@{ ... }` pair in source order; the label pair carries the current label.
void mm_serialize_flow_metadata(mm_serializer* out, mm_node* n):
	mm_serialize_id(out, n.id)
	string_append(out.text, c"@{ ")
	int first = 1
	for mm_property* property in n.metadata:
		if (n.group && strcmp(property.key, c"label") == 0): continue
		if (first == 0): string_append(out.text, c", ")
		first = 0
		string_append(out.text, property.key)
		string_append(out.text, c": ")
		if (strcmp(property.key, c"label") == 0): mm_serialize_flow_label(out, n.label)
		else: mm_serialize_quote(out, property.value)
	string_append(out.text, c" }")

# The link token for a flowchart edge: start marker, stroke and length, end marker.
void mm_serialize_flow_link(mm_serializer* out, mm_edge* edge):
	if (edge.extra_rank < 0 || edge.extra_rank > 16 || edge.stroke < 0 || edge.stroke > 2): out.failed = 1
	if (edge.id != 0):
		if (mm_serialize_is_id(edge.id) == 0): out.failed = 1
		string_append(out.text, edge.id)
		string_append_char(out.text, '@')
	if (edge.stroke == 2):
		if (edge.left_marker != 0 || edge.right_marker != 0 || edge.arrow != 0 || edge.dashed != 0): out.failed = 1
		mm_serialize_repeat(out, '~', edge.extra_rank + 3)
		return
	if (edge.left_marker == MM_ARROW): string_append_char(out.text, '<')
	else if (edge.left_marker == MM_FLOW_CIRCLE): string_append_char(out.text, 'o')
	else if (edge.left_marker == MM_FLOW_CROSS): string_append_char(out.text, 'x')
	else if (edge.left_marker != 0): out.failed = 1
	int end = 0
	if (edge.arrow): end = '>'
	if (edge.right_marker == MM_FLOW_CIRCLE): end = 'o'
	else if (edge.right_marker == MM_FLOW_CROSS): end = 'x'
	else if (edge.right_marker != 0): out.failed = 1
	if (edge.arrow && edge.right_marker != 0): out.failed = 1
	if (edge.dashed):
		if (edge.stroke != 0): out.failed = 1
		string_append_char(out.text, '-')
		mm_serialize_repeat(out, '.', edge.extra_rank + 1)
		string_append_char(out.text, '-')
	else:
		int c = '-'
		if (edge.stroke == 1): c = '='
		if (end != 0): mm_serialize_repeat(out, c, edge.extra_rank + 2)
		else: mm_serialize_repeat(out, c, edge.extra_rank + 3)
	if (end != 0): string_append_char(out.text, end)

# The agentflow edge operators: -->, --x, -.->, -.- and ---.
void mm_serialize_agent_link(mm_serializer* out, mm_edge* edge):
	if (edge.id != 0):
		if (mm_serialize_is_id(edge.id) == 0): out.failed = 1
		string_append(out.text, edge.id)
		string_append_char(out.text, '@')
	if (edge.left_marker != 0 || edge.stroke != 0 || edge.extra_rank != 0): out.failed = 1
	if (edge.right_marker == 6):
		if (edge.arrow || edge.dashed): out.failed = 1
		string_append(out.text, c"--x")
	else if (edge.right_marker != 0): out.failed = 1
	else if (edge.dashed && edge.arrow): string_append(out.text, c"-.->")
	else if (edge.dashed): string_append(out.text, c"-.-")
	else if (edge.arrow == 1): string_append(out.text, c"-->")
	else if (edge.arrow == 0): string_append(out.text, c"---")
	else: out.failed = 1

# One edge statement (no indentation), plus its linkStyle line.
void mm_serialize_edge(mm_serializer* out, mm_document* d, mm_edge* edge):
	if (edge.from_node < 0 || edge.from_node >= d.nodes.length || edge.to_node < 0 || edge.to_node >= d.nodes.length):
		out.failed = 1
		return
	if (edge.from_port != 0 || edge.to_port != 0): out.failed = 1
	if (d.kind == MM_ER && (edge.left_marker != 0 || edge.right_marker != 0 || edge.id != 0 || edge.stroke != 0 || edge.extra_rank != 0)): out.failed = 1
	mm_serialize_id(out, d.nodes[edge.from_node].id)
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
		if (d.kind == MM_AGENT): mm_serialize_agent_link(out, edge)
		else: mm_serialize_flow_link(out, edge)
		if (edge.label[0] != 0):
			string_append_char(out.text, '|')
			mm_serialize_flow_label(out, edge.label)
			string_append_char(out.text, '|')
	string_append_char(out.text, 32)
	mm_serialize_id(out, d.nodes[edge.to_node].id)
	if (d.kind == MM_ER):
		string_append(out.text, c" : ")
		mm_serialize_quote(out, edge.label)
	string_append_char(out.text, 10)
	if (edge.style.mask != 0):
		string_append(out.text, c"linkStyle ")
		string_append_int(out.text, out.edges)
		string_append_char(out.text, 32)
		mm_serialize_style(out, d, &edge.style)
	out.edges = out.edges + 1

# Agentflow `@{ ... }` values: strings JSON-quoted, other scalars plain,
# mappings and sequences as their canonical JSON (a YAML flow collection).
void mm_serialize_agent_value(mm_serializer* out, mm_property* property):
	if (property.type == MM_VALUE_STRING): mm_serialize_yaml_string(out, property.value)
	else:
		if (index_of(property.value, c"\n") >= 0): out.failed = 1
		mm_out(out, property.value)

void mm_serialize_agent_metadata(mm_serializer* out, list[mm_property*] metadata):
	if (metadata == 0 || metadata.length == 0): return
	mm_out(out, c"@{ ")
	for i in range(metadata.length):
		mm_property* property = metadata[i]
		if (i > 0): mm_out(out, c", ")
		if (mm_serialize_is_id(property.key)): mm_out(out, property.key)
		else: mm_serialize_yaml_string(out, property.key)
		mm_out(out, c": ")
		mm_serialize_agent_value(out, property)
	mm_out(out, c" }")

int mm_serialize_agent_has(mm_node* n, char* key):
	for mm_property* property in n.metadata:
		if (strcmp(property.key, key) == 0): return 1
	return 0

# The inline bracket that resolves to the node's shape without a shape key.
void mm_serialize_agent_node(mm_serializer* out, mm_node* n):
	mm_serialize_id(out, n.id)
	int labelled = 0
	for mm_property* property in n.metadata:
		if (strcmp(property.key, c"label") == 0 && property.type != MM_VALUE_NULL): labelled = 1
	char* open = c"["
	char* close = c"]"
	if (mm_serialize_agent_has(n, c"shape") == 0):
		if (n.shape == 17):
			open = c"[["
			close = c"]]"
		else if (n.shape == 20):
			open = c"{{"
			close = c"}}"
		else if (n.shape == 3):
			open = c"{"
			close = c"}"
		else if (n.shape != MM_SHAPE_ROUNDED): out.failed = 1
	if (labelled == 0 || strcmp(n.label, n.id) != 0):
		mm_out(out, open)
		mm_serialize_flow_label(out, n.label)
		mm_out(out, close)
	mm_serialize_agent_metadata(out, n.metadata)

# Minimum edge index in the subtree of group index, or -1 when it has none.
int mm_serialize_first_edge(mm_document* d, int index, int depth):
	if (depth > 32): return -1
	int best = -1
	for i in range(d.edges.length):
		if (d.edges[i].scope == index):
			best = i
			break
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != index || n.group == 0 || n.global_node): continue
		int inner = mm_serialize_first_edge(d, i, depth + 1)
		if (inner >= 0 && (best < 0 || inner < best)): best = inner
	return best

void mm_serialize_er_attributes(mm_serializer* out, mm_node* n):
	mm_out_indent(out)
	mm_serialize_id(out, n.id)
	string_append(out.text, c" {\n")
	out.depth = out.depth + 1
	for mm_attribute* a in n.attributes:
		mm_out_indent(out)
		mm_out_plain(out, a.type_name, c" \t;}\"")
		string_append_char(out.text, 32)
		mm_out_plain(out, a.name, c" \t;}\"")
		if (a.keys[0] != 0):
			string_append_char(out.text, 32)
			string_append(out.text, a.keys)
		if (a.comment[0] != 0):
			string_append_char(out.text, 32)
			mm_serialize_quote(out, a.comment)
		string_append_char(out.text, 10)
	out.depth = out.depth - 1
	mm_out_indent(out)
	string_append(out.text, c"}\n")

void mm_serialize_flow_node(mm_serializer* out, mm_document* d, int i, int depth);

# A subgraph header label written as raw text (`subgraph "Quoted id" rest`):
# the parser keeps the whole header text as the label when no `[` follows
# the identifier, quotes included.
int mm_serialize_flow_raw_header(mm_node* n):
	char* label = n.label
	if (index_of(label, c"\"") < 0 || index_of(label, c"\n") >= 0 || index_of(label, c"%%") >= 0 || index_of(label, c";") >= 0): return 0
	string_builder* quoted = string_from(c"\"")
	string_append(quoted, n.id)
	string_append_char(quoted, '"')
	int after = -1
	if (starts_with(label, quoted.data)): after = quoted.length
	else if (mm_serialize_is_id(n.id) && starts_with(label, n.id) && mm_id_char(label[strlen(n.id)] & 255) == 0): after = strlen(n.id)
	string_free(quoted)
	if (after < 0): return 0
	while (label[after] == 32 || label[after] == 9): after = after + 1
	return label[after] != '['

void mm_serialize_scope_items(mm_serializer* out, mm_document* d, int scope, int depth, int globals):
	if (depth > 32):
		out.failed = 1
		return
	# Plain nodes first, then child blocks and edges by edge order.
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != scope || n.group || n.global_node != globals): continue
		mm_serialize_flow_node(out, d, i, depth)
	list[int] blocks = new list[int]
	list[int] keys = new list[int]
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent != scope || n.group == 0 || n.global_node != globals): continue
		blocks.push(i)
		keys.push(mm_serialize_first_edge(d, i, 0))
	int next_block = 0
	# Blocks without edges keep node order ahead of the scope's edges.
	while (next_block < blocks.length && keys[next_block] < 0):
		mm_serialize_flow_node(out, d, blocks[next_block], depth)
		next_block = next_block + 1
	list[int] pending = new list[int]
	for k in range(next_block, blocks.length): pending.push(k)
	if (globals == 0):
		for e in range(d.edges.length):
			mm_edge* edge = d.edges[e]
			if (edge.scope != scope): continue
			int emitted = 1
			while (emitted):
				emitted = 0
				int best = -1
				for k in pending:
					if (k >= 0 && keys[k] >= 0 && keys[k] < e && (best < 0 || keys[k] < keys[best])): best = k
				if (best >= 0):
					mm_serialize_flow_node(out, d, blocks[best], depth)
					for slot in range(pending.length):
						if (pending[slot] == best): pending[slot] = -1
					emitted = 1
			out.edge_order.push(e)
			mm_out_indent(out)
			mm_serialize_edge(out, d, edge)
	# Remaining blocks in their first-edge order.
	int emitted = 1
	while (emitted):
		emitted = 0
		int best = -1
		for k in pending:
			if (k >= 0 && (best < 0 || keys[k] < keys[best])): best = k
		if (best >= 0):
			mm_serialize_flow_node(out, d, blocks[best], depth)
			for slot in range(pending.length):
				if (pending[slot] == best): pending[slot] = -1
			emitted = 1
	__w_list_free(cast(__w_list*, pending))
	__w_list_free(cast(__w_list*, blocks))
	__w_list_free(cast(__w_list*, keys))

void mm_serialize_flow_node(mm_serializer* out, mm_document* d, int i, int depth):
	mm_node* n = d.nodes[i]
	out.nodes = out.nodes + 1
	int agent = d.kind == MM_AGENT
	if (n.annotation[0] != 0 || n.members.length != 0): out.failed = 1
	if (agent == 0 && (n.global_node || n.role[0] != 0)): out.failed = 1
	if (n.metadata.length != 0 && d.kind == MM_ER): out.failed = 1
	if (n.group && n.attributes.length > 0): out.failed = 1
	mm_out_indent(out)
	if (agent):
		if (n.group):
			if (strcmp(n.role, c"flow") != 0): out.failed = 1
			mm_out(out, c"flow ")
			mm_serialize_id(out, n.id)
			mm_out(out, c"[")
			mm_serialize_flow_label(out, n.label)
			mm_out(out, c"]")
			mm_serialize_agent_metadata(out, n.metadata)
		else:
			if (strcmp(n.role, c"connector") == 0): mm_out(out, c"connector ")
			mm_serialize_agent_node(out, n)
	else:
		if (n.group): string_append(out.text, c"subgraph ")
		if (n.group && mm_serialize_flow_raw_header(n)): mm_out(out, n.label)
		else if (n.group == 0 && n.metadata.length != 0): mm_serialize_flow_metadata(out, n)
		else:
			mm_serialize_id(out, n.id)
			if (n.group || d.kind != MM_ER || n.shape != 0 || strcmp(n.label, n.id) != 0): mm_serialize_shape(out, n)
	string_append_char(out.text, 10)
	if (n.group):
		out.depth = out.depth + 1
		if (n.direction[0] != 0):
			mm_out_indent(out)
			string_append(out.text, c"direction ")
			string_append(out.text, n.direction)
			string_append_char(out.text, 10)
		mm_serialize_scope_items(out, d, i, depth + 1, 0)
		out.depth = out.depth - 1
		mm_out_indent(out)
		string_append(out.text, c"end\n")
		if (agent == 0 && n.metadata.length != 0):
			mm_out_indent(out)
			mm_serialize_flow_metadata(out, n)
			string_append_char(out.text, 10)
	else if (n.attributes.length > 0):
		if (d.kind != MM_ER): out.failed = 1
		mm_serialize_er_attributes(out, n)
	mm_serialize_node_style(out, d, n)

void mm_serialize_flow_edge_metadata(mm_serializer* out, mm_document* d):
	for mm_edge* edge in d.edges:
		if (d.kind == MM_AGENT):
			if (edge.metadata == 0 || edge.metadata.length == 0): continue
			if (edge.id == 0):
				out.failed = 1
				continue
			mm_out(out, edge.id)
			mm_serialize_agent_metadata(out, edge.metadata)
			mm_out_line(out)
			continue
		if (edge.animate == 0 && edge.curve == 0): continue
		if (edge.id == 0 || edge.animate < 0 || edge.animate > 3 || edge.curve < 0 || edge.curve > 3):
			out.failed = 1
			continue
		string_append(out.text, edge.id)
		string_append(out.text, c"@{ ")
		if (edge.animate == 1): string_append(out.text, c"animate: true")
		else if (edge.animate == 2): string_append(out.text, c"animation: fast")
		else if (edge.animate == 3): string_append(out.text, c"animation: slow")
		if (edge.animate != 0 && edge.curve != 0): string_append(out.text, c", ")
		if (edge.curve == 1): string_append(out.text, c"curve: step")
		else if (edge.curve == 2): string_append(out.text, c"curve: linear")
		else if (edge.curve == 3): string_append(out.text, c"curve: basis")
		string_append(out.text, c" }\n")

void mm_serialize_flow_clicks(mm_serializer* out, mm_document* d):
	for mm_node* n in d.nodes:
		if (n.link == 0 && n.callback == 0):
			if (n.tooltip != 0 || n.link_target != 0): out.failed = 1
			continue
		if (d.kind != MM_FLOW || (n.link != 0 && n.callback != 0)):
			out.failed = 1
			continue
		string_append(out.text, c"click ")
		mm_serialize_id(out, n.id)
		if (n.link != 0):
			string_append(out.text, c" href ")
			mm_serialize_quote(out, n.link)
		else:
			string_append(out.text, c" call ")
			mm_out_plain(out, n.callback, 0)
		if (n.tooltip != 0):
			string_append_char(out.text, 32)
			mm_serialize_quote(out, n.tooltip)
		if (n.link_target != 0):
			if (n.link == 0): out.failed = 1
			string_append_char(out.text, 32)
			string_append(out.text, n.link_target)
		string_append_char(out.text, 10)

# prelude: first write every node identifier in node order.
void mm_serialize_flow_body(mm_serializer* out, mm_document* d, int prelude):
	if (d.notes.length != 0 || d.narrative.length != 0 || d.data != 0 || d.railroad != 0 || d.graph_variant != 0): out.failed = 1
	if (d.kind == MM_FLOW):
		mm_out(out, c"flowchart ")
		mm_out(out, d.direction)
		mm_out_line(out)
	else if (d.kind == MM_AGENT):
		mm_out(out, c"agentflow-beta ")
		mm_out(out, d.direction)
		mm_out_line(out)
	else:
		mm_out(out, c"erDiagram\n")
		if (strcmp(d.direction, c"TB") != 0):
			mm_out(out, c"direction ")
			mm_out(out, d.direction)
			mm_out_line(out)
	mm_serialize_accessibility(out, d)
	mm_serialize_class_defs(out, d)
	if (d.edge_style.mask != 0):
		string_append(out.text, c"linkStyle default ")
		mm_serialize_style(out, d, &d.edge_style)
	if (prelude):
		for mm_node* n in d.nodes:
			mm_serialize_id(out, n.id)
			mm_out_line(out)
	if (d.kind == MM_AGENT):
		int globals = 0
		for mm_node* n in d.nodes:
			if (n.global_node): globals = 1
		if (globals):
			mm_out(out, c"global\n")
			out.depth = 1
			mm_serialize_scope_items(out, d, -1, 0, 1)
			out.depth = 0
			mm_out(out, c"end\n")
	mm_serialize_scope_items(out, d, -1, 0, 0)
	mm_serialize_flow_edge_metadata(out, d)
	mm_serialize_flow_clicks(out, d)
	if (out.nodes != d.nodes.length || out.edges != d.edges.length): out.failed = 1
