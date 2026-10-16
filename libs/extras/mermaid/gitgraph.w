# Branch heads and immutable commit ancestry, not generic flowchart nodes.
import libs.extras.mermaid.frameworks
import libs.extras.mermaid.framework_render

int mm_git_branch(mm_parser* p, char* name, int create, int head, int lane):
	if (name[0] == 0):
		mm_error(p.doc, p.pos, c"expected nonempty branch name")
		return -1
	string_builder* id = string_from(c"@branch:")
	string_append(id, name)
	int index = mm_find_node(p.doc, id.data)
	if (create):
		if (index >= 0): mm_error(p.doc, p.pos, c"duplicate branch")
		else:
			index = mm_add_node(p.doc, id.data, p.pos)
			if (index >= 0):
				mm_node* n = p.doc.nodes[index]
				n.group = 1
				n.value_x = head
				n.value_y = lane
				free(n.label)
				n.label = strclone(name)
	else if (index < 0): mm_error(p.doc, p.pos, c"unknown branch")
	string_free(id)
	return index

void mm_git_parent(mm_parser* p, int parent, int child):
	if (parent < 0): return
	if (p.doc.edges.length >= MM_MAX_ITEMS):
		mm_error(p.doc, p.pos, c"commit ancestry limit exceeded")
		return
	mm_edge* e = new mm_edge()
	e.from_node = parent
	e.to_node = child
	e.label = strclone(c"")
	p.doc.edges.push(e)

void mm_git_cherry(mm_parser* p, int current, int ordinal):
	char* original = strclone(c"")
	char* parent = strclone(c"")
	char* tag = strclone(c"")
	int seen = 0
	while (mm_end(p) == 0 && p.doc.error == 0):
		char* key = mm_identifier(p)
		mm_space(p)
		if (mm_match(p, c":") == 0): mm_error(p.doc, p.pos, c"expected cherry-pick property colon")
		mm_space(p)
		if (mm_peek(p) != '"'): mm_error(p.doc, p.pos, c"cherry-pick values must be quoted")
		char* value = mm_quoted(p)
		int bit = 0
		if (strcmp(key, c"id") == 0):
			bit = 1
			free(original)
			original = strclone(value)
		else if (strcmp(key, c"parent") == 0):
			bit = 2
			free(parent)
			parent = strclone(value)
		else if (strcmp(key, c"tag") == 0):
			bit = 4
			free(tag)
			tag = strclone(value)
		else: mm_error(p.doc, p.pos, c"unsupported cherry-pick property")
		if (seen & bit): mm_error(p.doc, p.pos, c"duplicate cherry-pick property")
		seen = seen | bit
		free(value)
		free(key)
	int source = mm_find_node(p.doc, original)
	mm_node* branch = p.doc.nodes[current]
	if (source < 0 || original[0] == 0): mm_error(p.doc, p.pos, c"cherry-pick requires an existing commit id")
	else:
		mm_node* origin = p.doc.nodes[source]
		if (origin.group || origin.parent == current): mm_error(p.doc, p.pos, c"cherry-pick requires a commit from another branch")
		int parents = 0
		int valid_parent = 0
		for mm_edge* e in p.doc.edges:
			if (e.to_node == source):
				parents = parents + 1
				mm_node* ancestor = p.doc.nodes[e.from_node]
				if (strcmp(ancestor.id, parent) == 0): valid_parent = 1
		if (parents > 1 && parent[0] == 0): mm_error(p.doc, p.pos, c"cherry-pick of merge requires a parent id")
		if (parent[0] != 0 && valid_parent == 0): mm_error(p.doc, p.pos, c"cherry-pick parent must be an immediate parent")
	if (branch.value_x < 0): mm_error(p.doc, p.pos, c"cherry-pick requires a current branch commit")
	if (p.doc.error == 0):
		string_builder* id = string_from(c"cherry-pick-")
		string_append_int(id, ordinal)
		if (mm_find_node(p.doc, id.data) >= 0): mm_error(p.doc, p.pos, c"generated cherry-pick id conflicts with existing commit")
		int index = -1
		if (p.doc.error == 0): index = mm_add_node(p.doc, id.data, p.pos)
		string_free(id)
		if (index >= 0):
			mm_node* n = p.doc.nodes[index]
			n.parent = current
			n.value_x = ordinal
			n.shape = 4
			free(n.label)
			n.label = strclone(original)
			free(n.annotation)
			n.annotation = strclone(tag)
			mm_property* metadata = new mm_property()
			metadata.key = strclone(c"cherry-pick")
			metadata.value = strclone(original)
			n.metadata.push(metadata)
			mm_git_parent(p, branch.value_x, index)
			branch.value_x = index
	free(original)
	free(parent)
	free(tag)

# Unspecified orders precede specified orders; equal values retain source order.
int mm_git_lane(mm_document* d, mm_node* branch):
	int lane = 0
	for mm_node* other in d.nodes:
		if (other.group == 0 || other == branch): continue
		if (other.declared < branch.declared || (other.declared == branch.declared && other.value_y < branch.value_y)): lane = lane + 1
	return lane

void mm_git_body(mm_parser* p):
	int current = mm_git_branch(p, c"main", 1, -1, 0)
	int lane = 1
	int ordinal = 0
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_metadata(p)):
			mm_separators(p)
			continue
		char* command = mm_uml_id(p)
		if (strcmp(command, c"cherry-pick") == 0):
			mm_git_cherry(p, current, ordinal)
			ordinal = ordinal + 1
		else if (strcmp(command, c"branch") == 0 || strcmp(command, c"checkout") == 0 || strcmp(command, c"switch") == 0):
			char* name
			mm_space(p)
			if (mm_peek(p) == '"'): name = mm_quoted(p)
			else: name = mm_uml_id(p)
			mm_node* prior = p.doc.nodes[current]
			int create = strcmp(command, c"branch") == 0
			int next = mm_git_branch(p, name, create, prior.value_x, lane)
			if (create): lane = lane + 1
			if (next >= 0): current = next
			mm_space(p)
			if (create && mm_keyword(p, c"order")):
				mm_space(p)
				if (mm_match(p, c":") == 0): mm_error(p.doc, p.pos, c"expected branch order colon")
				char* value = mm_identifier(p)
				int order = 0
				if (value[0] == 0): mm_error(p.doc, p.pos, c"branch order must be 0..1000000")
				for i in range(strlen(value)):
					if (value[i] < '0' || value[i] > '9' || order > 100000):
						mm_error(p.doc, p.pos, c"branch order must be 0..1000000")
						break
					order = order * 10 + value[i] - '0'
				if (order > 1000000): mm_error(p.doc, p.pos, c"branch order must be 0..1000000")
				if (next >= 0):
					mm_node* branch = p.doc.nodes[next]
					branch.declared = order + 1
				free(value)
			free(name)
		else if (strcmp(command, c"commit") == 0 || strcmp(command, c"merge") == 0):
			int other = -1
			int merge = strcmp(command, c"merge") == 0
			if (merge):
				mm_space(p)
				char* name
				if (mm_peek(p) == '"'): name = mm_quoted(p)
				else: name = mm_uml_id(p)
				other = mm_git_branch(p, name, 0, 0, 0)
				free(name)
				if (other == current): mm_error(p.doc, p.pos, c"cannot merge branch into itself")
			string_builder* generated = string_from(c"commit-")
			string_append_int(generated, ordinal)
			char* id = strclone(generated.data)
			string_free(generated)
			char* tag = strclone(c"")
			int shape = merge * 3
			list[char*] keys = new list[char*]
			while (mm_end(p) == 0 && p.doc.error == 0):
				char* key = mm_identifier(p)
				for char* prior in keys:
					if (strcmp(prior, key) == 0): mm_error(p.doc, p.pos, c"duplicate commit property")
				keys.push(strclone(key))
				mm_space(p)
				if (mm_match(p, c":") == 0): mm_error(p.doc, p.pos, c"expected commit property colon")
				mm_space(p)
				char* value
				if (mm_peek(p) == '"'): value = mm_quoted(p)
				else: value = mm_identifier(p)
				if (strcmp(key, c"id") == 0):
					free(id)
					id = strclone(value)
				else if (strcmp(key, c"tag") == 0):
					free(tag)
					tag = strclone(value)
				else if (strcmp(key, c"type") == 0):
					if (strcmp(value, c"NORMAL") == 0): shape = 0
					else if (strcmp(value, c"REVERSE") == 0): shape = 1
					else if (strcmp(value, c"HIGHLIGHT") == 0): shape = 2
					else: mm_error(p.doc, p.pos, c"unknown commit type")
				else: mm_error(p.doc, p.pos, c"unsupported commit property")
				free(key)
				free(value)
			for char* key in keys: free(key)
			__w_list_free(cast(__w_list*, keys))
			if (id[0] == 0 || mm_find_node(p.doc, id) >= 0): mm_error(p.doc, p.pos, c"empty or duplicate commit id")
			int index = mm_add_node(p.doc, id, p.pos)
			free(id)
			if (index >= 0 && p.doc.error == 0):
				mm_node* n = p.doc.nodes[index]
				mm_node* branch = p.doc.nodes[current]
				n.parent = current
				n.value_x = ordinal
				n.shape = shape
				free(n.annotation)
				n.annotation = strclone(tag)
				mm_git_parent(p, branch.value_x, index)
				if (merge && other >= 0):
					mm_node* merged = p.doc.nodes[other]
					if (merged.value_x < 0 || branch.value_x < 0): mm_error(p.doc, p.pos, c"merge requires commits on both branches")
					else if (merged.value_x == branch.value_x): mm_error(p.doc, p.pos, c"branches have the same head")
					else: mm_git_parent(p, merged.value_x, index)
				branch.value_x = index
				ordinal = ordinal + 1
			free(tag)
		else: mm_error(p.doc, p.pos, c"unsupported GitGraph command")
		free(command)
		if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported GitGraph syntax")
		mm_separators(p)

mm_scene* mm_git_render(mm_document* d):
	mm_scene* s = mm_framework_scene(d)
	int vertical = strcmp(d.direction, c"LR") != 0
	int reverse = strcmp(d.direction, c"BT") == 0
	int time = 200
	int label_width = 120
	for mm_node* n in d.nodes:
		if (n.group && strlen(n.label) * 8 + 40 > label_width): label_width = strlen(n.label) * 8 + 40
	list[int] lane_sizes = new list[int]
	for mm_node* n in d.nodes:
		if (n.group): lane_sizes.push(130)
	for mm_node* n in d.nodes:
		mm_node* branch = n
		if (n.group == 0): branch = d.nodes[n.parent]
		int lane = mm_git_lane(d, branch)
		int width = strlen(n.label) * 8 + 60
		if (strlen(n.annotation) * 8 + 60 > width): width = strlen(n.annotation) * 8 + 60
		if (width > lane_sizes[lane]): lane_sizes[lane] = width
	if (vertical): label_width = 100
	time = label_width + 60
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		mm_bounds* b = s.nodes[i]
		mm_node* branch = n
		if (n.group == 0): branch = d.nodes[n.parent]
		int lane = mm_git_lane(d, branch)
		int offset = 80
		for j in range(lane):
			if (vertical): offset = offset + lane_sizes[j]
			else: offset = offset + 130
		b.y = offset
		if (n.group):
			b.x = 40
		else:
			b.x = time
			int width = strlen(n.label) * 8 + 60
			if (strlen(n.annotation) * 8 + 60 > width): width = strlen(n.annotation) * 8 + 60
			if (width < 100): width = 100
			time = time + width
	__w_list_free(cast(__w_list*, lane_sizes))
	if (vertical):
		for mm_bounds* b in s.nodes:
			int x = b.x
			b.x = b.y
			b.y = x
			if (reverse): b.y = time + 40 - x
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.group == 0): continue
		mm_bounds* b = s.nodes[i]
		mm_text(s, b.x, b.y - 8, n.label)
		if (vertical):
			if (reverse): mm_line(s, b.x, 40, b.x, time + 40 - label_width, 1)
			else: mm_line(s, b.x, label_width, b.x, time, 1)
		else: mm_line(s, label_width, b.y, time, b.y, 1)
	for mm_edge* e in d.edges:
		mm_bounds* a = s.nodes[e.from_node]
		mm_bounds* b = s.nodes[e.to_node]
		mm_line(s, a.x, a.y, b.x, b.y, 0)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.group): continue
		mm_bounds* b = s.nodes[i]
		if (n.shape == 2): mm_draw(s, MM_BOX, b.x - 12, b.y - 12, b.x + 12, b.y + 12, 0, c"")
		else: mm_draw(s, MM_CIRCLE, b.x - 9, b.y - 9, b.x + 9, b.y + 9, n.shape == 3, c"")
		if (n.shape == 4):
			mm_draw(s, MM_CIRCLE, b.x + 1, b.y - 9, b.x + 19, b.y + 9, 0, c"")
			mm_line(s, b.x, b.y - 9, b.x + 10, b.y - 20, 0)
			mm_line(s, b.x + 10, b.y - 9, b.x + 10, b.y - 20, 0)
		if (n.shape == 1):
			mm_line(s, b.x - 6, b.y - 6, b.x + 6, b.y + 6, 0)
			mm_line(s, b.x + 6, b.y - 6, b.x - 6, b.y + 6, 0)
		if (n.shape == 3): mm_draw(s, MM_CIRCLE, b.x - 4, b.y - 4, b.x + 4, b.y + 4, 0, c"")
		mm_text(s, b.x - 12, b.y + 20, n.label)
		if (n.annotation[0] != 0): mm_text(s, b.x - 12, b.y - 36, n.annotation)
	return s
