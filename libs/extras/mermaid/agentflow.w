# Agentflow's semantic roles and YAML metadata; no connector is executed.
import libs.extras.mermaid.graph_families
import libs.extras.mermaid.yaml_meta
import libs.extras.mermaid.shape_catalog

# Agentflow shape vocabulary (upstream diagrams/agentflow/shapes.ts): the six
# domain aliases, the canonical names the spec allows, and everything else
# (removed or unsupported shapes) coerced to the default rounded rectangle,
# which upstream reports as a non-blocking diagnostic.
int mm_agent_shape_code(char* value):
	if (mm_in_words(value, c"|tool|subroutine|subprocess|subproc|framed-rectangle|")): return 17
	if (mm_in_words(value, c"|input|lean-right|")): return 18
	if (mm_in_words(value, c"|decision|diamond|")): return 3
	if (mm_in_words(value, c"|refdoc|lin-doc|lined-document|")): return 19
	if (mm_in_words(value, c"|action|hexagon|hex|")): return 20
	if (strcmp(value, c"collapsedGroup") == 0): return MM_SHAPE_COLLAPSED
	return MM_SHAPE_ROUNDED

# The derived vertex kind of a resolved shape.
char* mm_agent_kind(int shape):
	if (shape == 17): return c"tool"
	if (shape == 18): return c"input"
	if (shape == 3): return c"decision"
	if (shape == 19): return c"refdoc"
	if (shape == 20): return c"action"
	return c"task"

void mm_agent_set_role(mm_node* n, char* role):
	free(n.role)
	n.role = strclone(role)

void mm_agent_shape(mm_parser* p, mm_node* n, char* value):
	if (n.group):
		if (strcmp(value, c"collapsedGroup") != 0): mm_error(p.doc, p.pos, c"agentflow container shape overrides are not supported")
		return
	n.shape = mm_agent_shape_code(value)
	if (strcmp(n.role, c"connector") != 0): mm_agent_set_role(n, mm_agent_kind(n.shape))

mm_property* mm_agent_get(list[mm_property*] metadata, char* key):
	if (metadata == 0): return 0
	for mm_property* property in metadata:
		if (strcmp(property.key, key) == 0): return property
	return 0

# Merges parsed properties into an element's metadata (repeated keys update).
void mm_agent_merge(mm_parser* p, list[mm_property*] target, list[mm_property*] props):
	for mm_property* property in props:
		mm_property* existing = mm_agent_get(target, property.key)
		if (existing != 0):
			free(existing.value)
			existing.value = strclone(property.value)
			existing.type = property.type
		else if (target.length >= 64): mm_error(p.doc, p.pos, c"agentflow metadata limit exceeded (64 per node)")
		else: target.push(new mm_property(strclone(property.key), strclone(property.value), property.type))

# Reads an `@{ ... }` block at p.pos (after optional spaces) into owned
# properties; returns 0 when there is no block.
list[mm_property*] mm_agent_block(mm_parser* p):
	mm_space(p)
	if (mm_match(p, c"@{") == 0): return 0
	int close = mm_ymeta_close(p.doc, p.pos)
	if (close < 0):
		mm_error(p.doc, p.pos, c"unterminated metadata block")
		return 0
	list[mm_property*] props = mm_ymeta_parse(p.doc, p.pos, close)
	p.pos = close + 1
	return props

int mm_agent_curve(char* value):
	if (mm_in_words(value, c"|linear|")): return MM_CURVE_LINEAR
	if (mm_in_words(value, c"|step|stepBefore|stepAfter|")): return MM_CURVE_STEP
	if (mm_in_words(value, c"|basis|bumpX|bumpY|cardinal|catmullRom|monotoneX|monotoneY|natural|rounded|")): return MM_CURVE_BASIS
	return 0

void mm_agent_apply_edge(mm_parser* p, mm_edge* e, list[mm_property*] props):
	if (e.metadata == 0): e.metadata = new list[mm_property*]
	mm_agent_merge(p, e.metadata, props)
	mm_property* curve = mm_agent_get(props, c"curve")
	if (curve != 0):
		e.curve = mm_agent_curve(curve.value)
		if (e.curve == 0): mm_error(p.doc, p.pos, c"unsupported agentflow edge curve")
	mm_property* animation = mm_agent_get(props, c"animation")
	if (animation != 0 && mm_in_words(animation.value, c"|fast|slow|") == 0): mm_error(p.doc, p.pos, c"agentflow edge animation must be fast or slow")
	mm_property* animate = mm_agent_get(props, c"animate")
	if (animate != 0 && animate.type != MM_VALUE_BOOL): mm_error(p.doc, p.pos, c"agentflow edge animate must be true or false")

void mm_agent_metadata(mm_parser* p, mm_node* n):
	list[mm_property*] props = mm_agent_block(p)
	if (props == 0): return
	if (p.doc.error == 0): mm_agent_merge(p, n.metadata, props)
	for mm_property* property in props:
		if (p.doc.error != 0): break
		char* key = property.key
		char* value = property.value
		if (strcmp(key, c"shape") == 0):
			if (property.type != MM_VALUE_STRING): mm_error(p.doc, p.pos, c"agentflow shape must be a name")
			else: mm_agent_shape(p, n, value)
		else if (strcmp(key, c"label") == 0):
			if (property.type == MM_VALUE_MAP || property.type == MM_VALUE_LIST): mm_error(p.doc, p.pos, c"agentflow label must be text")
			else if (property.type != MM_VALUE_NULL):
				free(n.label)
				n.label = strclone(value)
		else if (strcmp(key, c"labelType") == 0 && mm_in_words(value, c"|text|string|markdown|") == 0): mm_error(p.doc, p.pos, c"agentflow labelType must be text, string or markdown")
		else if (strcmp(key, c"view") == 0 && mm_in_words(value, c"|collapsed|expanded|") == 0): mm_error(p.doc, p.pos, c"agentflow view must be collapsed or expanded")
		else if (strcmp(key, c"algorithm") == 0 && property.type != MM_VALUE_STRING): mm_error(p.doc, p.pos, c"agentflow algorithm must be a name")
	mm_properties_free(props)

# `a e1@--> b`: an edge id written before the operator.
void mm_agent_edge_id(mm_parser* p, mm_edge* e):
	int start = p.pos
	while (mm_id_char(mm_peek(p))): p.pos = p.pos + 1
	if (p.pos == start || mm_peek(p) != '@' || p.pos + 1 >= p.doc.length || (p.doc.source[p.pos + 1] != '-' && p.doc.source[p.pos + 1] != '=')):
		p.pos = start
		return
	char* id = str_copy_range(p.doc.source, start, p.pos)
	p.pos = p.pos + 1
	for mm_edge* other in p.doc.edges:
		if (other.id != 0 && strcmp(other.id, id) == 0): mm_error(p.doc, start, c"duplicate agentflow edge id")
	if (mm_find_node(p.doc, id) >= 0): mm_error(p.doc, start, c"agentflow edge id names a node")
	e.id = id

# `e1@{ curve: linear }` names an edge declared earlier. Returns 1 when consumed.
int mm_agent_edge_metadata(mm_parser* p):
	int start = p.pos
	while (mm_id_char(mm_peek(p))): p.pos = p.pos + 1
	if (p.pos == start || mm_peek(p) != '@' || p.pos + 1 >= p.doc.length || p.doc.source[p.pos + 1] != '{'):
		p.pos = start
		return 0
	char* id = str_copy_range(p.doc.source, start, p.pos)
	mm_edge* edge = 0
	for mm_edge* e in p.doc.edges:
		if (e.id != 0 && strcmp(e.id, id) == 0): edge = e
	free(id)
	if (edge == 0):
		p.pos = start
		return 0
	list[mm_property*] props = mm_agent_block(p)
	if (props != 0):
		if (p.doc.error == 0): mm_agent_apply_edge(p, edge, props)
		mm_properties_free(props)
	return 1

int mm_agent_collapsed(mm_document* d, int index):
	mm_node* n = d.nodes[index]
	if (n.group == 0): return 0
	mm_property* view = mm_agent_get(n.metadata, c"view")
	return view != 0 && strcmp(view.value, c"collapsed") == 0

# After parsing: resolve inline bracket shapes through the agentflow
# vocabulary and give every node its derived kind.
void mm_agent_finish(mm_parser* p):
	for mm_node* n in p.doc.nodes:
		if (n.group):
			if (n.role[0] == 0): mm_agent_set_role(n, c"flow")
			continue
		if (mm_agent_get(n.metadata, c"shape") == 0):
			if (n.shape == 22): n.shape = 17
			else if (n.shape == 23): n.shape = 20
			else if (n.shape != 3): n.shape = MM_SHAPE_ROUNDED
			if (n.role[0] == 0): mm_agent_set_role(n, mm_agent_kind(n.shape))
		else if (n.role[0] == 0): mm_agent_set_role(n, mm_agent_kind(n.shape))

# Outermost collapsed container holding index (itself excluded), or -1.
int mm_agent_hidden_by(mm_document* d, int index):
	int found = -1
	mm_node* n = d.nodes[index]
	int at = n.parent
	int guard = 0
	while (at >= 0 && guard <= d.nodes.length):
		if (mm_agent_collapsed(d, at)): found = at
		mm_node* parent = d.nodes[at]
		at = parent.parent
		guard = guard + 1
	return found

int mm_agent_has_collapsed(mm_document* d):
	if (d.kind != MM_AGENT): return 0
	for i in range(d.nodes.length):
		if (mm_agent_collapsed(d, i) && mm_agent_hidden_by(d, i) < 0): return 1
	return 0

# The presentation view of a diagram with collapsed containers: their
# descendants are dropped, each collapsed container becomes one summary node
# (collapsedGroup) and edges crossing its boundary end on it; edges whose two
# distinct endpoints fold into the same container disappear. slots receives,
# for every original node, its index in the view (hidden nodes map to their
# collapsed container).
mm_document* mm_agent_project(mm_document* d, list[int] slots):
	mm_document* view = mm_document_new()
	view.kind = d.kind
	free(view.direction)
	view.direction = strclone(d.direction)
	view.layout_algorithm = d.layout_algorithm
	view.theme = d.theme
	view.palette = d.palette
	view.edge_style = d.edge_style
	for i in range(d.nodes.length): slots.push(-1)
	for i in range(d.nodes.length):
		if (mm_agent_hidden_by(d, i) >= 0): continue
		mm_node* n = d.nodes[i]
		int index = mm_add_node(view, n.id, 0)
		if (index < 0): break
		mm_node* copy = view.nodes[index]
		free(copy.label)
		copy.label = strclone(n.label)
		free(copy.role)
		copy.role = strclone(n.role)
		free(copy.direction)
		copy.direction = strclone(n.direction)
		free(copy.style_classes)
		copy.style_classes = strclone(n.style_classes)
		copy.style = n.style
		copy.shape = n.shape
		copy.group = n.group
		copy.global_node = n.global_node
		if (mm_agent_collapsed(d, i)):
			copy.group = 0
			copy.shape = MM_SHAPE_COLLAPSED
		slots[i] = index
	for i in range(d.nodes.length):
		int at = mm_agent_hidden_by(d, i)
		if (at >= 0): slots[i] = slots[at]
		else if (slots[i] >= 0):
			mm_node* n = d.nodes[i]
			mm_node* copy = view.nodes[slots[i]]
			if (n.parent >= 0): copy.parent = slots[n.parent]
	for mm_edge* e in d.edges:
		int from = slots[e.from_node]
		int to = slots[e.to_node]
		if (from < 0 || to < 0): continue
		if (from == to && e.from_node != e.to_node): continue
		mm_edge* copy = new mm_edge()
		copy.from_node = from
		copy.to_node = to
		copy.label = strclone(e.label)
		if (e.left_label != 0): copy.left_label = strclone(e.left_label)
		if (e.right_label != 0): copy.right_label = strclone(e.right_label)
		copy.dashed = e.dashed
		copy.arrow = e.arrow
		copy.right_marker = e.right_marker
		copy.curve = e.curve
		copy.style = e.style
		copy.scope = -1
		if (e.scope >= 0 && slots[e.scope] >= 0):
			mm_node* scope = view.nodes[slots[e.scope]]
			if (scope.group): copy.scope = slots[e.scope]
		view.edges.push(copy)
	return view
