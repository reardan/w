# Canonical class and state diagram source (requirement diagrams live in
# serialize_requirement.w). Statements are replayed in model order: one
# creator per node (declaration, member line, bare state, composite or
# namespace block) at its node index, and every relationship / transition in
# edge order, merged so nodes are created in the same order. Nodes no
# statement can create on its own -- start/end pseudo-states, lollipop
# interfaces and classes only named by relationships -- are created by their
# first relationship, written in the node's own scope. Composite states,
# concurrent regions and namespaces are indented blocks that are never
# reopened; notes, styles and interactions follow at the top level.
import libs.extras.mermaid.serialize_requirement

struct mm_su_writer:
	mm_serializer* out
	mm_document* d
	# Open scopes, innermost last (-1 is the diagram itself).
	list[int] stack
	# Per node: 1 once its block was opened, 2 once closed.
	list[int] blocks
	# Per node: the edge that creates it, or -1 when a statement does.
	list[int] creator

int mm_su_is_region(mm_node* n):
	return starts_with(n.id, c"@region:")

int mm_su_is_interface(mm_node* n):
	return starts_with(n.id, c"@interface:")

# The scope a start/end pseudo-state was written in, or -2 for other nodes.
int mm_su_pseudo_scope(mm_node* n):
	int scope = 0
	if (mm_serialize_pseudo(n.id, &scope) == 0): return -2
	return scope

# A UML identifier: bare when mm_su_id reads it back whole, else backticks.
void mm_su_ref_id(mm_serializer* out, char* id):
	int bare = id[0] != 0
	int length = strlen(id)
	for i in range(length):
		int c = id[i] & 255
		if (mm_id_char(c)): continue
		if ((c == '-' || c == '.') && i + 1 < length && id[i + 1] != c && i > 0): continue
		bare = 0
	if (bare && mm_in_words(id, c"|style|classDef|cssClass|click|note|link|callback|accTitle|accDescr|end|class|state|namespace|direction|")): bare = 0
	if (bare):
		mm_out(out, id)
		return
	if (index_of(id, c"`") >= 0 || index_of(id, c"\n") >= 0 || id[0] == 0): out.failed = 1
	mm_out_char(out, '`')
	mm_out(out, id)
	mm_out_char(out, '`')

# `Id~T~` when the class label is the generic form of its identifier.
int mm_su_generic_label(mm_node* n):
	int length = strlen(n.id)
	int total = strlen(n.label)
	return total > length + 2 && starts_with(n.label, n.id) && n.label[length] == '<' && n.label[total - 1] == '>'

void mm_su_generic_suffix(mm_serializer* out, mm_node* n):
	char* label = n.label
	for i in range(strlen(n.id), strlen(label)):
		int c = label[i]
		if (c == '<' || c == '>'): mm_out_char(out, '~')
		else if (c == ',' && label[i + 1] == 32): mm_out_char(out, ',')
		else if (c == 32 && i > 0 && label[i - 1] == ','): continue
		else: mm_out_char(out, c)

# A node reference: [*] for pseudo-states, the source name for interfaces.
void mm_su_ref(mm_su_writer* w, int index, int creating):
	mm_node* n = w.d.nodes[index]
	if (mm_su_pseudo_scope(n) != -2):
		mm_out(w.out, c"[*]")
		return
	if (mm_su_is_interface(n)):
		mm_su_ref_id(w.out, n.label)
		return
	mm_su_ref_id(w.out, n.id)
	if (creating && w.d.kind == MM_CLASS && mm_su_generic_label(n)): mm_su_generic_suffix(w.out, n)

# Text that mm_su_text reads back unchanged.
void mm_su_text_out(mm_serializer* out, char* text):
	if (text[0] == 0 || text[0] == 32 || text[0] == 9 || index_of(text, c"%%") >= 0): out.failed = 1
	int length = strlen(text)
	if ((text[length - 1] & 255) <= 32): out.failed = 1
	mm_out_plain(out, text, c"{};")

int mm_su_depth(mm_su_writer* w):
	int depth = 0
	for int scope in w.stack:
		if (scope >= 0 && mm_su_is_region(w.d.nodes[scope]) == 0): depth = depth + 1
	return depth

void mm_su_line(mm_su_writer* w):
	w.out.depth = mm_su_depth(w)
	mm_out_indent(w.out)

int mm_su_top(mm_su_writer* w):
	return w.stack[w.stack.length - 1]

void mm_su_pop(mm_su_writer* w):
	int top = mm_su_top(w)
	w.stack.pop()
	w.blocks[top] = 2
	if (mm_su_is_region(w.d.nodes[top]) == 0):
		mm_su_line(w)
		mm_out(w.out, c"}\n")

# The scope that contains index's statements: a first region's members are
# written before its separator, in the composite itself.
int mm_su_home(mm_su_writer* w, int parent):
	if (parent < 0): return -1
	mm_node* p = w.d.nodes[parent]
	if (mm_su_is_region(p) == 0): return parent
	int composite = p.parent
	for i in range(w.d.nodes.length):
		mm_node* n = w.d.nodes[i]
		if (n.parent == composite && mm_su_is_region(n)):
			if (i == parent): return composite
			return parent
	return parent

int mm_su_is_ancestor(mm_document* d, int ancestor, int scope):
	int guard = 0
	while (scope >= 0 && guard <= d.nodes.length):
		if (scope == ancestor): return 1
		scope = d.nodes[scope].parent
		guard = guard + 1
	return ancestor == -1

void mm_su_open(mm_su_writer* w, int scope);

# Close blocks until scope is open, opening composite/namespace blocks on
# the way; a region is only entered through its separator.
void mm_su_enter(mm_su_writer* w, int scope):
	while (w.stack.length > 1 && mm_su_is_ancestor(w.d, mm_su_top(w), scope) == 0): mm_su_pop(w)
	if (mm_su_top(w) == scope): return
	if (scope < 0):
		w.out.failed = 1
		return
	mm_node* n = w.d.nodes[scope]
	if (mm_su_is_region(n) || w.blocks[scope] != 0):
		w.out.failed = 1
		return
	mm_su_enter(w, mm_su_home(w, n.parent))
	mm_su_open(w, scope)

# Namespace or composite-state header, then push it.
void mm_su_open(mm_su_writer* w, int scope):
	mm_node* n = w.d.nodes[scope]
	mm_serializer* out = w.out
	mm_su_line(w)
	if (w.d.kind == MM_CLASS):
		mm_out(out, c"namespace ")
		char* name = n.id
		if (n.parent >= 0):
			mm_node* outer = w.d.nodes[n.parent]
			int skip = strlen(outer.id) + 1
			if (starts_with(n.id, outer.id) == 0 || n.id[skip - 1] != '.'): out.failed = 1
			else: name = n.id + skip
		if (index_of(name, c".") >= 0): out.failed = 1
		mm_su_ref_id(out, name)
		if (strcmp(n.label, name) != 0):
			mm_out(out, c"[")
			mm_serialize_quote(out, n.label)
			mm_out(out, c"]")
		mm_out(out, c" {\n")
	else:
		mm_out(out, c"state ")
		if (strcmp(n.label, n.id) != 0):
			mm_serialize_quote(out, n.label)
			mm_out(out, c" as ")
		mm_su_ref_id(out, n.id)
		if (n.annotation[0] != 0 || n.declared == 0): out.failed = 1
		mm_out(out, c" {\n")
	w.blocks[scope] = 1
	w.stack.push(scope)
	if (n.direction[0] != 0):
		mm_su_line(w)
		mm_out(out, c"direction ")
		mm_out(out, n.direction)
		mm_out_line(out)

# The separator that creates region index (the first one also creates the
# second region and moves the composite's earlier members into region one).
void mm_su_region(mm_su_writer* w, int index):
	mm_document* d = w.d
	mm_node* region = d.nodes[index]
	int composite = region.parent
	int ordinal = 0
	int previous = -1
	for i in range(index):
		mm_node* n = d.nodes[i]
		if (n.parent == composite && mm_su_is_region(n)):
			ordinal = ordinal + 1
			previous = i
	if (ordinal == 1): return
	if (region.direction[0] != 0 && ordinal == 0): w.out.failed = 1
	if (ordinal == 0): mm_su_enter(w, composite)
	else:
		mm_su_enter(w, previous)
		if (mm_su_top(w) != previous):
			w.out.failed = 1
			return
		mm_su_pop(w)
	if (mm_su_top(w) != composite):
		w.out.failed = 1
		return
	mm_su_line(w)
	mm_out(w.out, c"--\n")
	int next = index
	if (ordinal == 0):
		next = index + 1
		w.blocks[index] = 2
	if (next >= d.nodes.length || d.nodes[next].parent != composite || mm_su_is_region(d.nodes[next]) == 0):
		w.out.failed = 1
		return
	w.blocks[next] = 1
	w.stack.push(next)
	mm_node* current = d.nodes[next]
	if (current.direction[0] != 0):
		mm_su_line(w)
		mm_out(w.out, c"direction ")
		mm_out(w.out, current.direction)
		mm_out_line(w.out)

void mm_su_class_members(mm_su_writer* w, mm_node* n, int braces):
	mm_serializer* out = w.out
	for mm_member* m in n.members:
		if (starts_with(m.text, c"<<")): out.failed = 1
		if (m.method != (index_of(m.text, c"(") >= 0)): out.failed = 1
		mm_su_line(w)
		if (braces): mm_out(out, c"  ")
		else:
			mm_su_ref_id(out, n.id)
			mm_out(out, c" : ")
		mm_su_text_out(out, m.text)
		mm_out_line(out)

# The statement that creates node index in its own scope.
void mm_su_create(mm_su_writer* w, int index):
	mm_document* d = w.d
	mm_node* n = d.nodes[index]
	mm_serializer* out = w.out
	if (mm_su_is_region(n)):
		mm_su_region(w, index)
		return
	if (n.group):
		mm_su_enter(w, index)
		return
	mm_su_enter(w, mm_su_home(w, n.parent))
	if (d.kind == MM_CLASS):
		if (n.declared):
			mm_su_line(w)
			mm_out(out, c"class ")
			mm_su_ref_id(out, n.id)
			if (mm_su_generic_label(n)): mm_su_generic_suffix(out, n)
			else if (strcmp(n.label, n.id) != 0):
				mm_out(out, c"[")
				mm_serialize_quote(out, n.label)
				mm_out(out, c"]")
			if (n.annotation[0] != 0):
				mm_out(out, c" <<")
				mm_out_plain(out, n.annotation, c">")
				mm_out(out, c">>")
			if (n.members.length != 0):
				mm_out(out, c" {\n")
				mm_su_class_members(w, n, 1)
				mm_su_line(w)
				mm_out(out, c"}")
			mm_out_line(out)
			return
		if (mm_su_generic_label(n) == 0 && strcmp(n.label, n.id) != 0): out.failed = 1
		if (n.annotation[0] != 0):
			mm_su_line(w)
			mm_out(out, c"<<")
			mm_out_plain(out, n.annotation, c">")
			mm_out(out, c">> ")
			mm_su_ref(w, index, 1)
			mm_out_line(out)
		else if (n.members.length != 0):
			mm_su_line(w)
			mm_su_ref(w, index, 1)
			mm_out(out, c" : ")
			mm_su_text_out(out, n.members[0].text)
			mm_out_line(out)
			for i in range(1, n.members.length):
				mm_member* m = n.members[i]
				mm_su_line(w)
				mm_su_ref_id(out, n.id)
				mm_out(out, c" : ")
				mm_su_text_out(out, m.text)
				mm_out_line(out)
			return
		else if (n.style_classes[0] == 0): out.failed = 1
		if (n.annotation[0] != 0 && n.members.length != 0): mm_su_class_members(w, n, 0)
		return
	# State: declarations keep their description and annotation.
	mm_su_line(w)
	if (n.declared):
		mm_out(out, c"state ")
		if (strcmp(n.label, n.id) != 0 && n.shape == 1):
			mm_serialize_quote(out, n.label)
			mm_out(out, c" as ")
		mm_su_ref_id(out, n.id)
		if (n.annotation[0] != 0):
			mm_out(out, c" <<")
			mm_out(out, n.annotation)
			mm_out(out, c">>")
		mm_out_line(out)
		return
	if (n.shape != 1 || n.annotation[0] != 0): out.failed = 1
	mm_su_ref_id(out, n.id)
	if (strcmp(n.label, n.id) != 0):
		mm_out(out, c" : ")
		mm_su_text_out(out, n.label)
	mm_out_line(out)

# Nodes only a relationship can create: pseudo-states, interfaces and
# (class diagrams) undeclared classes without members or annotations.
int mm_su_edge_made(mm_document* d, mm_node* n):
	if (mm_su_pseudo_scope(n) != -2 || mm_su_is_interface(n)): return 1
	if (d.kind != MM_CLASS || n.group || n.declared): return 0
	return n.annotation[0] == 0 && n.members.length == 0

void mm_su_edge(mm_su_writer* w, int e):
	mm_document* d = w.d
	mm_edge* edge = d.edges[e]
	mm_serializer* out = w.out
	if (edge.from_node < 0 || edge.to_node < 0 || edge.from_node >= d.nodes.length || edge.to_node >= d.nodes.length):
		out.failed = 1
		return
	# The scope [*] and newly named classes belong to.
	int home = -3
	list[int] ends = list[int]{edge.from_node, edge.to_node}
	for int end in ends:
		mm_node* n = d.nodes[end]
		int scope = mm_su_pseudo_scope(n)
		int pseudo = scope != -2
		if (scope == -2 && w.creator[end] == e): scope = n.parent
		if (scope == -2): continue
		if (pseudo == 0): scope = mm_su_home(w, scope)
		if (home != -3 && home != scope): out.failed = 1
		home = scope
	__w_list_free(cast(__w_list*, ends))
	if (home != -3):
		mm_su_enter(w, home)
		if (mm_su_top(w) != home): out.failed = 1
	mm_su_line(w)
	if (d.kind == MM_STATE):
		if (edge.arrow != 1 || edge.dashed || edge.left_marker || edge.right_marker || edge.left_label[0] != 0 || edge.right_label[0] != 0): out.failed = 1
		mm_su_ref(w, edge.from_node, w.creator[edge.from_node] == e)
		mm_out(out, c" --> ")
		mm_su_ref(w, edge.to_node, w.creator[edge.to_node] == e)
	else:
		if (edge.arrow): out.failed = 1
		mm_su_ref(w, edge.from_node, w.creator[edge.from_node] == e)
		mm_out_char(out, 32)
		if (edge.left_label[0] != 0):
			mm_serialize_quote(out, edge.left_label)
			mm_out_char(out, 32)
		list[char*] lefts = list[char*]{c"", c"<", c"<|", c"*", c"o", c"", c"", c"()"}
		list[char*] rights = list[char*]{c"", c">", c"|>", c"*", c"o", c"", c"", c"()"}
		if (edge.left_marker < 0 || edge.left_marker > 7 || edge.right_marker < 0 || edge.right_marker > 7 || lefts[edge.left_marker][0] == 0 && edge.left_marker != 0 || rights[edge.right_marker][0] == 0 && edge.right_marker != 0): out.failed = 1
		else:
			mm_out(out, lefts[edge.left_marker])
			if (edge.dashed): mm_out(out, c"..")
			else: mm_out(out, c"--")
			mm_out(out, rights[edge.right_marker])
		__w_list_free(cast(__w_list*, lefts))
		__w_list_free(cast(__w_list*, rights))
		mm_out_char(out, 32)
		if (edge.right_label[0] != 0):
			mm_serialize_quote(out, edge.right_label)
			mm_out_char(out, 32)
		mm_su_ref(w, edge.to_node, w.creator[edge.to_node] == e)
	if (edge.label[0] != 0):
		mm_out(out, c" : ")
		mm_su_text_out(out, edge.label)
	mm_out_line(out)

void mm_su_note(mm_su_writer* w, mm_note* note):
	mm_serializer* out = w.out
	mm_document* d = w.d
	if (d.kind == MM_CLASS):
		mm_out(out, c"note ")
		if (note.node >= 0):
			mm_out(out, c"for ")
			mm_su_ref(w, note.node, 0)
			mm_out_char(out, 32)
		else if (note.node != -1): out.failed = 1
		if (note.side != 1): out.failed = 1
		mm_serialize_quote(out, note.text)
		mm_out_line(out)
		return
	if (note.node < 0 || note.node >= d.nodes.length):
		out.failed = 1
		return
	mm_node* n = d.nodes[note.node]
	int scope = mm_su_pseudo_scope(n)
	if (scope != -2 && (scope != -1 || starts_with(n.id, c"@start:") == 0)): out.failed = 1
	mm_out(out, c"note ")
	if (note.side == -1): mm_out(out, c"left of ")
	else if (note.side == 1): mm_out(out, c"right of ")
	else: out.failed = 1
	mm_su_ref(w, note.node, 0)
	char* text = note.text
	int single = text[0] != 0 && index_of(text, c"\n") < 0 && index_of(text, c"{") < 0 && index_of(text, c"}") < 0 && index_of(text, c";") < 0 && index_of(text, c"%%") < 0 && text[0] > 32 && text[strlen(text) - 1] > 32
	if (single):
		mm_out(out, c" : ")
		mm_out(out, text)
		mm_out_line(out)
		return
	mm_out_line(out)
	int length = strlen(text)
	if (length > 0 && text[length - 1] != 10): out.failed = 1
	int start = 0
	for i in range(length):
		if (text[i] != 10): continue
		char* line = str_copy_range(text, start, i)
		if (line[0] == 32 || line[0] == 9): out.failed = 1
		if (starts_with(line, c"end")): out.failed = 1
		mm_out(out, c"  ")
		mm_out(out, line)
		mm_out_line(out)
		free(line)
		start = i + 1
	mm_out(out, c"end note\n")

void mm_su_interactions(mm_serializer* out, mm_document* d):
	for mm_node* n in d.nodes:
		if (n.link == 0 && n.callback == 0):
			if (n.tooltip != 0 || n.link_target != 0): out.failed = 1
			continue
		if (d.kind != MM_CLASS || (n.link != 0 && n.callback != 0)):
			out.failed = 1
			continue
		if (n.link != 0):
			mm_out(out, c"link ")
			mm_su_ref_id(out, n.id)
			mm_out_char(out, 32)
			mm_serialize_quote(out, n.link)
		else:
			mm_out(out, c"callback ")
			mm_su_ref_id(out, n.id)
			mm_out_char(out, 32)
			mm_serialize_quote(out, n.callback)
			if (n.link_target != 0): out.failed = 1
		if (n.tooltip != 0):
			mm_out_char(out, 32)
			mm_serialize_quote(out, n.tooltip)
		if (n.link_target != 0):
			mm_out_char(out, 32)
			mm_out(out, n.link_target)
		mm_out_line(out)

void mm_su_class_state_body(mm_serializer* out, mm_document* d):
	if (d.narrative.length != 0 || d.data != 0 || d.railroad != 0 || d.graph_variant != 0): out.failed = 1
	if (d.kind == MM_CLASS): mm_out(out, c"classDiagram\n")
	else: mm_out(out, c"stateDiagram-v2\n")
	if (strcmp(d.direction, c"TB") != 0):
		mm_out(out, c"direction ")
		mm_out(out, d.direction)
		mm_out_line(out)
	mm_serialize_accessibility(out, d)
	mm_serialize_class_defs(out, d)
	mm_su_writer w
	w.out = out
	w.d = d
	w.stack = new list[int]
	w.stack.push(-1)
	w.blocks = new list[int]
	w.creator = new list[int]
	for i in range(d.nodes.length):
		w.blocks.push(0)
		w.creator.push(-1)
	# The first relationship naming each edge-created node creates it.
	for e in range(d.edges.length):
		mm_edge* edge = d.edges[e]
		list[int] ends = list[int]{edge.from_node, edge.to_node}
		for int end in ends:
			if (end >= 0 && end < d.nodes.length && w.creator[end] < 0 && mm_su_edge_made(d, d.nodes[end])): w.creator[end] = e
		__w_list_free(cast(__w_list*, ends))
		# A plain state first named by a transition as its newest endpoint is
		# created by that transition (`[*] --> Idle`, `Idle --> Busy`).
		int newest = edge.from_node
		if (edge.to_node > newest): newest = edge.to_node
		if (d.kind == MM_STATE && newest >= 0 && newest < d.nodes.length && w.creator[newest] < 0):
			mm_node* made = d.nodes[newest]
			int first = 1
			for k in range(e):
				if (d.edges[k].from_node == newest || d.edges[k].to_node == newest): first = 0
			int scope = mm_su_home(&w, made.parent)
			int other = edge.from_node + edge.to_node - newest
			if (other >= 0 && other < d.nodes.length && w.creator[other] == e):
				int pseudo = mm_su_pseudo_scope(d.nodes[other])
				if (pseudo != scope): first = 0
			if (first && made.declared == 0 && made.group == 0 && made.shape == 1 && strcmp(made.label, made.id) == 0 && mm_su_pseudo_scope(made) == -2): w.creator[newest] = e
	# Merge node creators (key index, 0) with edges in order (key: the node
	# they create, or after their newest endpoint).
	list[int] major = new list[int]
	list[int] minor = new list[int]
	for e in range(d.edges.length):
		mm_edge* edge = d.edges[e]
		int key = edge.from_node
		if (edge.to_node > key): key = edge.to_node
		int second = 1
		for i in range(d.nodes.length):
			if (w.creator[i] == e):
				key = i
				second = -1
				break
		if (major.length > 0):
			int last = major[major.length - 1]
			int last_minor = minor[minor.length - 1]
			if (key < last || (key == last && second < last_minor)):
				key = last
				second = last_minor
		major.push(key)
		minor.push(second)
	# Items in emission order: node creators (kind 0) and edges (kind 1).
	list[int] kinds = new list[int]
	list[int] items = new list[int]
	int next_edge = 0
	for i in range(d.nodes.length + 1):
		while (next_edge < d.edges.length && (i == d.nodes.length || major[next_edge] < i || (major[next_edge] == i && minor[next_edge] < 0))):
			kinds.push(1)
			items.push(next_edge)
			next_edge = next_edge + 1
		if (i == d.nodes.length): break
		if (w.creator[i] >= 0):
			if (w.creator[i] >= next_edge): out.failed = 1
			continue
		kinds.push(0)
		items.push(i)
	# A composite state is created where it is first needed: by its block
	# when its contents follow, by a transition naming it, or by a bare line.
	int pending = -1
	for k in range(items.length + 1):
		if (pending >= 0):
			int needs_block = 0
			int named = 0
			if (k < items.length):
				int target = -3
				if (kinds[k] == 1):
					mm_edge* edge = d.edges[items[k]]
					named = edge.from_node == pending || edge.to_node == pending
					for i in range(d.nodes.length):
						if (w.creator[i] == items[k]):
							mm_node* made = d.nodes[i]
							target = mm_su_pseudo_scope(made)
							if (target == -2): target = made.parent
				else: target = d.nodes[items[k]].parent
				needs_block = target >= 0 && mm_su_is_ancestor(d, pending, target)
			else:
				needs_block = 1
				for mm_node* child in d.nodes:
					if (child.parent == pending): needs_block = 0
			if (needs_block): mm_su_enter(&w, pending)
			else:
				mm_su_enter(&w, mm_su_home(&w, d.nodes[pending].parent))
				if (named == 0):
					mm_su_line(&w)
					mm_su_ref_id(out, d.nodes[pending].id)
					mm_out_line(out)
			pending = -1
		if (k == items.length): break
		if (kinds[k] == 1):
			mm_su_edge(&w, items[k])
			continue
		int i = items[k]
		mm_node* n = d.nodes[i]
		if (d.kind == MM_STATE && n.group && mm_su_is_region(n) == 0):
			pending = i
			continue
		if (mm_su_edge_made(d, n) && mm_su_pseudo_scope(n) == -2 && mm_su_is_interface(n) == 0 && n.style_classes[0] != 0):
			# An undeclared class created by its class assignment.
			mm_su_enter(&w, mm_su_home(&w, n.parent))
			mm_su_line(&w)
			mm_su_ref(&w, i, 1)
			mm_out(out, c":::")
			mm_out(out, n.style_classes)
			mm_out_line(out)
		else if (mm_su_edge_made(d, n)): out.failed = 1
		else: mm_su_create(&w, i)
	__w_list_free(cast(__w_list*, kinds))
	__w_list_free(cast(__w_list*, items))
	while (w.stack.length > 1): mm_su_pop(&w)
	out.depth = 0
	for mm_note* note in d.notes: mm_su_note(&w, note)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (d.kind == MM_CLASS && n.style_classes[0] != 0 && w.creator[i] < 0 && mm_su_edge_made(d, n)):
			if (n.style.mask != 0):
				mm_out(out, c"style ")
				mm_out(out, n.id)
				mm_out_char(out, 32)
				mm_serialize_style(out, d, &n.style)
			continue
		if (d.kind == MM_CLASS && n.style_classes[0] != 0):
			if (n.style.mask != 0):
				mm_out(out, c"style ")
				mm_out(out, n.id)
				mm_out_char(out, 32)
				mm_serialize_style(out, d, &n.style)
			mm_out(out, c"cssClass ")
			mm_serialize_quote(out, n.id)
			mm_out_char(out, 32)
			mm_out_plain(out, n.style_classes, c";")
			mm_out_line(out)
			continue
		mm_serialize_node_style(out, d, n)
	mm_su_interactions(out, d)
	__w_list_free(cast(__w_list*, major))
	__w_list_free(cast(__w_list*, minor))
	__w_list_free(cast(__w_list*, w.stack))
	__w_list_free(cast(__w_list*, w.blocks))
	__w_list_free(cast(__w_list*, w.creator))

void mm_serialize_uml_body(mm_serializer* out, mm_document* d, int variant):
	if (d.kind == MM_REQUIREMENT): mm_serialize_requirement_body(out, d)
	else: mm_su_class_state_body(out, d)
