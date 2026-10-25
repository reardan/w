# Canonical GitGraph source: the model is replayed as commands. Branches and
# commits are written in creation order; a checkout precedes every commit on
# another branch and every branch created from another branch's head. Merge
# commits name a branch whose head is their second parent, cherry-picks the
# commit they copy.
import libs.extras.mermaid.serialize_common

# A branch name in a command: bare when mm_uml_id reads it whole.
void mm_serialize_git_name(mm_serializer* out, char* name):
	int bare = name[0] != 0
	int length = strlen(name)
	for i in range(length):
		int c = name[i] & 255
		if (mm_id_char(c)): continue
		if ((c == '-' || c == '.') && i > 0 && i + 1 < length && name[i + 1] != c): continue
		bare = 0
	if (bare): mm_out(out, name)
	else: mm_serialize_quote(out, name)

# The edges into a commit in order (first parent, merged parent).
int mm_serialize_git_parent(mm_document* d, int index, int which):
	int seen = 0
	for mm_edge* e in d.edges:
		if (e.to_node != index): continue
		if (seen == which): return e.from_node
		seen = seen + 1
	return -1

int mm_serialize_git_parents(mm_document* d, int index):
	int count = 0
	for mm_edge* e in d.edges:
		if (e.to_node == index): count = count + 1
	return count

# Switch to branch when it is not current.
void mm_serialize_git_checkout(mm_serializer* out, mm_document* d, int* current, int branch):
	if (*current == branch): return
	mm_out(out, c"  checkout ")
	mm_serialize_git_name(out, d.nodes[branch].label)
	mm_out_line(out)
	*current = branch

# The id a commit command names: none for a generated id (`commit-N`, or
# `commit-N-M` when a custom id took `commit-N`), the original id for a
# commit whose id a later commit rebound (stored as `<id>~<n>`).
char* mm_serialize_git_written_id(mm_node* n, int ordinal):
	string_builder* generated = string_from(c"commit-")
	string_append_int(generated, ordinal)
	int implicit = strcmp(n.id, generated.data) == 0
	string_append_char(generated, '-')
	if (starts_with(n.id, generated.data)): implicit = 1
	string_free(generated)
	if (implicit): return 0
	int length = strlen(n.label)
	if (strcmp(n.label, n.id) != 0 && length > 0 && starts_with(n.id, n.label) && n.id[length] == '~'): return n.label
	return n.id

# 1 when a commit's label is the one its command implies.
int mm_serialize_git_label_ok(mm_node* n, int ordinal):
	if (strcmp(n.label, n.id) == 0): return 1
	char* written = mm_serialize_git_written_id(n, ordinal)
	return written != 0 && written == n.label

void mm_serialize_git_properties(mm_serializer* out, mm_node* n, int ordinal, int merge):
	char* written = mm_serialize_git_written_id(n, ordinal)
	if (written != 0):
		mm_out(out, c" id: ")
		mm_serialize_quote(out, written)
	for mm_property* property in n.metadata:
		if (merge || strcmp(property.key, c"msg") != 0 || property.value[0] == 0 || n.metadata.length != 1): out.failed = 1
		else:
			mm_out(out, c" msg: ")
			mm_serialize_quote(out, property.value)
	if (n.annotation[0] != 0):
		mm_out(out, c" tag: ")
		mm_serialize_quote(out, n.annotation)
	int natural = 0
	if (merge): natural = 3
	if (n.shape != natural):
		if (n.shape == 0): mm_out(out, c" type: NORMAL")
		else if (n.shape == 1): mm_out(out, c" type: REVERSE")
		else if (n.shape == 2): mm_out(out, c" type: HIGHLIGHT")
		else: out.failed = 1

void mm_serialize_gitgraph_body(mm_serializer* out, mm_document* d, int variant):
	if (d.notes.length != 0 || d.narrative.length != 0 || d.data != 0 || d.railroad != 0 || d.style_definitions.length != 0): out.failed = 1
	mm_out(out, c"gitGraph")
	if (strcmp(d.direction, c"LR") != 0):
		mm_out_char(out, 32)
		mm_out(out, d.direction)
		mm_out_char(out, ':')
	mm_out_line(out)
	out.depth = 1
	mm_serialize_accessibility(out, d)
	out.depth = 0
	list[int] heads = new list[int]
	for i in range(d.nodes.length): heads.push(-1)
	int current = 0
	int ordinal = 0
	if (d.nodes.length == 0 || d.nodes[0].group == 0): out.failed = 1
	for i in range(d.nodes.length):
		if (out.failed): break
		mm_node* n = d.nodes[i]
		if (n.style.mask != 0 || n.style_classes[0] != 0 || n.members.length != 0): out.failed = 1
		if (n.group):
			if (starts_with(n.id, c"@branch:") == 0 || strcmp(n.id + 8, n.label) != 0): out.failed = 1
			if (i == 0): continue
			# The head this branch started from: its first commit's first parent.
			int start = n.value_x
			for k in range(i + 1, d.nodes.length):
				mm_node* commit = d.nodes[k]
				if (commit.group == 0 && commit.parent == i):
					start = mm_serialize_git_parent(d, k, 0)
					break
			int from = -1
			if (heads[current] == start): from = current
			for b in range(i):
				if (from < 0 && d.nodes[b].group && heads[b] == start): from = b
			if (from < 0):
				out.failed = 1
				break
			mm_serialize_git_checkout(out, d, &current, from)
			mm_out(out, c"  branch ")
			mm_serialize_git_name(out, n.label)
			if (n.declared != 0):
				mm_out(out, c" order: ")
				mm_out_int(out, n.declared - 1)
			mm_out_line(out)
			current = i
			continue
		if (n.parent < 0 || n.parent >= i || d.nodes[n.parent].group == 0 || n.value_x != ordinal):
			out.failed = 1
			break
		mm_serialize_git_checkout(out, d, &current, n.parent)
		int parents = mm_serialize_git_parents(d, i)
		if (n.shape == 4):
			char* original = n.label
			int source = mm_find_node(d, original)
			if (source < 0 || n.metadata.length != 1):
				out.failed = 1
				break
			string_builder* generated = string_from(c"cherry-pick-")
			string_append_int(generated, ordinal)
			if (strcmp(n.id, generated.data) != 0): out.failed = 1
			string_free(generated)
			mm_out(out, c"  cherry-pick id: ")
			mm_serialize_quote(out, original)
			if (mm_serialize_git_parents(d, source) > 1):
				mm_out(out, c" parent: ")
				mm_serialize_quote(out, d.nodes[mm_serialize_git_parent(d, source, 0)].id)
			if (n.annotation[0] != 0):
				mm_out(out, c" tag: ")
				mm_serialize_quote(out, n.annotation)
			mm_out_line(out)
		else if (parents == 2):
			int merged = mm_serialize_git_parent(d, i, 1)
			int other = -1
			for b in range(i):
				if (other < 0 && b != current && d.nodes[b].group && heads[b] == merged): other = b
			if (other < 0):
				out.failed = 1
				break
			mm_out(out, c"  merge ")
			mm_serialize_git_name(out, d.nodes[other].label)
			mm_serialize_git_properties(out, n, ordinal, 1)
			mm_out_line(out)
		else:
			if (mm_serialize_git_label_ok(n, ordinal) == 0): out.failed = 1
			mm_out(out, c"  commit")
			mm_serialize_git_properties(out, n, ordinal, 0)
			mm_out_line(out)
		heads[n.parent] = i
		ordinal = ordinal + 1
	__w_list_free(cast(__w_list*, heads))
