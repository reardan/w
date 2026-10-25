# Class and state syntax, referenced against Mermaid 12.2.0.
import libs.extras.mermaid.parse_common
import libs.extras.mermaid.style
import libs.extras.mermaid.interaction

int mm_keyword(mm_parser* p, char* word):
	int save = p.pos
	if (mm_match(p, word) == 0): return 0
	int c = mm_peek(p)
	if (mm_id_char(c) || c == '-'):
		p.pos = save
		return 0
	return 1

# Owned, trimmed statement text. Braces delimit blocks, not literal labels.
char* mm_uml_text(mm_parser* p):
	mm_space(p)
	int start = p.pos
	while (mm_end(p) == 0 && mm_peek(p) != '}' && mm_peek(p) != '{'): p.pos = p.pos + 1
	int end = p.pos
	while (end > start && (p.doc.source[end - 1] & 255) <= 32): end = end - 1
	if (start == end): mm_error(p.doc, start, c"expected nonempty text")
	return str_copy_range(p.doc.source, start, end)

char* mm_uml_id(mm_parser* p):
	mm_space(p)
	int start = p.pos
	if (mm_match(p, c"`")):
		start = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != '`'): p.pos = p.pos + 1
		char* quoted = str_copy_range(p.doc.source, start, p.pos)
		if (mm_match(p, c"`") == 0 || quoted[0] == 0): mm_error(p.doc, start, c"expected nonempty backtick identifier")
		return quoted
	while (mm_id_char(mm_peek(p)) || mm_peek(p) == '-' || mm_peek(p) == '.'):
		if ((mm_peek(p) == '-' || mm_peek(p) == '.') && p.pos + 1 < p.doc.length && p.doc.source[p.pos + 1] == mm_peek(p)): break
		p.pos = p.pos + 1
	char* id = str_copy_range(p.doc.source, start, p.pos)
	if (p.pos == start): mm_error(p.doc, start, c"expected class or state identifier")
	if (strcmp(id, c"style") == 0 || strcmp(id, c"classDef") == 0 || strcmp(id, c"cssClass") == 0 || strcmp(id, c"click") == 0 || strcmp(id, c"note") == 0 || strcmp(id, c"link") == 0 || strcmp(id, c"callback") == 0 || strcmp(id, c"accTitle") == 0 || strcmp(id, c"accDescr") == 0 || strcmp(id, c"end") == 0):
		mm_error(p.doc, start, c"unsupported UML statement")
	return id

void mm_uml_generic(mm_parser* p, string_builder* label, int depth):
	if (depth > 32):
		mm_error(p.doc, p.pos, c"generic nesting limit exceeded")
		return
	if (mm_match(p, c"~") == 0): return
	string_append_char(label, '<')
	int count = 0
	while (p.doc.error == 0):
		mm_space(p)
		char* type = mm_uml_id(p)
		string_append(label, type)
		free(type)
		# A tilde followed by a type starts another nested parameter.
		if (mm_peek(p) == '~' && p.pos + 1 < p.doc.length):
			int next = p.doc.source[p.pos + 1] & 255
			if (mm_id_char(next) || next == '`'): mm_uml_generic(p, label, depth + 1)
		mm_space(p)
		count = count + 1
		if (count > 32): mm_error(p.doc, p.pos, c"generic parameter limit exceeded")
		if (mm_match(p, c",") == 0): break
		string_append(label, c", ")
	if (mm_match(p, c"~") == 0): mm_error(p.doc, p.pos, c"expected generic closing ~")
	string_append_char(label, '>')

int mm_uml_node(mm_parser* p, int scope, int final):
	mm_space(p)
	int offset = p.pos
	char* id
	int special = 0
	if (p.doc.kind == MM_STATE && mm_match(p, c"[*]")):
		string_builder* key = string_from(c"@start:")
		if (final):
			string_free(key)
			key = string_from(c"@end:")
		string_append_int(key, scope)
		id = strclone(key.data)
		string_free(key)
		special = 4 + final
	else: id = mm_uml_id(p)
	int found = mm_find_node(p.doc, id)
	int index = mm_add_node(p.doc, id, offset)
	free(id)
	if (index < 0 || p.doc.error != 0): return -1
	mm_node* n = p.doc.nodes[index]
	if (found < 0):
		n.parent = scope
		if (p.doc.kind == MM_STATE): n.shape = 1
	if (p.doc.kind == MM_CLASS && mm_peek(p) == '~'):
		string_builder* label = string_from(n.id)
		mm_uml_generic(p, label, 0)
		free(n.label)
		n.label = strclone(label.data)
		string_free(label)
	if (special):
		n.shape = special
		free(n.label)
		n.label = strclone(c"")
	return index

char* mm_annotation(mm_parser* p):
	int start = p.pos
	while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != '>'): p.pos = p.pos + 1
	char* result = str_copy_range(p.doc.source, start, p.pos)
	if (mm_match(p, c">>") == 0 || result[0] == 0): mm_error(p.doc, start, c"expected nonempty annotation followed by >>")
	return result

void mm_class_member(mm_parser* p, int index):
	mm_node* n = p.doc.nodes[index]
	if (n.members.length >= MM_MAX_ITEMS || p.doc.attribute_count >= 4096):
		mm_error(p.doc, p.pos, c"member limit exceeded")
		return
	mm_space(p)
	if (mm_match(p, c"<<")):
		if (n.annotation[0] != 0): mm_error(p.doc, p.pos, c"duplicate class annotation")
		free(n.annotation)
		n.annotation = mm_annotation(p)
		return
	mm_member* m = new mm_member()
	m.text = mm_uml_text(p)
	m.method = index_of(m.text, c"(") >= 0
	n.members.push(m)
	p.doc.attribute_count = p.doc.attribute_count + 1

void mm_class_body(mm_parser* p, int index):
	mm_separators(p)
	while (p.doc.error == 0 && mm_peek(p) != '}'):
		if (mm_peek(p) == 0):
			mm_error(p.doc, p.pos, c"unterminated class body")
			return
		mm_class_member(p, index)
		if (mm_end(p) == 0 && mm_peek(p) != '}'): mm_error(p.doc, p.pos, c"expected end of class member")
		mm_separators(p)
	if (mm_peek(p) == '}'): p.pos = p.pos + 1

mm_edge* mm_uml_edge(mm_parser* p, int left, int scope):
	if (p.doc.edges.length >= MM_MAX_ITEMS):
		mm_error(p.doc, p.pos, c"edge limit exceeded")
		return 0
	mm_edge* e = new mm_edge()
	e.from_node = left
	e.scope = scope
	e.label = strclone(c"")
	e.left_label = strclone(c"")
	e.right_label = strclone(c"")
	p.doc.edges.push(e)
	return e

int mm_uml_interface(mm_parser* p, int index, mm_edge* current):
	if (index < 0): return index
	mm_node* original = p.doc.nodes[index]
	int used = original.declared || original.group || original.members.length != 0 || original.shape == 28
	for mm_edge* edge in p.doc.edges:
		if (edge != current && (edge.from_node == index || edge.to_node == index)): used = 1
	string_builder* key = string_from(c"@interface:")
	if (used): string_append_int(key, p.doc.nodes.length)
	else: string_append_int(key, index)
	if (used):
		index = mm_add_node(p.doc, key.data, p.pos)
		if (index >= 0):
			mm_node* node = p.doc.nodes[index]
			free(node.label)
			node.label = strclone(original.label)
			node.parent = original.parent
	else:
		free(original.id)
		original.id = strclone(key.data)
	string_free(key)
	if (index >= 0):
		mm_node* node = p.doc.nodes[index]
		node.shape = 28
	return index

void mm_class_relation(mm_parser* p, int left, int scope):
	mm_edge* e = mm_uml_edge(p, left, scope)
	if (e == 0): return
	mm_space(p)
	if (mm_peek(p) == '"'):
		free(e.left_label)
		e.left_label = mm_quoted(p)
		mm_space(p)
	if (mm_match(p, c"()")): e.left_marker = MM_LOLLIPOP
	else if (mm_match(p, c"<|")): e.left_marker = MM_TRIANGLE
	else if (mm_match(p, c"<")): e.left_marker = MM_ARROW
	else if (mm_match(p, c"*")): e.left_marker = MM_COMPOSITION
	else if (mm_match(p, c"o")): e.left_marker = MM_AGGREGATION
	if (mm_match(p, c"..")): e.dashed = 1
	else if (mm_match(p, c"--") == 0): mm_error(p.doc, p.pos, c"expected class relationship -- or ..")
	if (mm_match(p, c"()")): e.right_marker = MM_LOLLIPOP
	else if (mm_match(p, c"|>")): e.right_marker = MM_TRIANGLE
	else if (mm_match(p, c">")): e.right_marker = MM_ARROW
	else if (mm_match(p, c"*")): e.right_marker = MM_COMPOSITION
	else if (mm_match(p, c"o")): e.right_marker = MM_AGGREGATION
	mm_space(p)
	if (mm_peek(p) == '"'):
		free(e.right_label)
		e.right_label = mm_quoted(p)
	e.to_node = mm_uml_node(p, scope, 0)
	if (e.left_marker == MM_LOLLIPOP): e.from_node = mm_uml_interface(p, e.from_node, e)
	if (e.right_marker == MM_LOLLIPOP): e.to_node = mm_uml_interface(p, e.to_node, e)
	if (e.to_node >= 0):
		mm_node* target = p.doc.nodes[e.to_node]
		if (target.group): mm_error(p.doc, p.pos, c"namespace cannot be used as a class")
	mm_space(p)
	if (mm_match(p, c":")):
		free(e.label)
		e.label = mm_uml_text(p)

void mm_uml_body(mm_parser* p, int scope, int depth);

void mm_group_body(mm_parser* p, int index, int depth):
	mm_node* n = p.doc.nodes[index]
	if (n.group || n.members.length != 0 || n.shape > 1):
		mm_error(p.doc, p.pos, c"duplicate or conflicting group definition")
		return
	if (depth >= 32):
		mm_error(p.doc, p.pos, c"group nesting limit exceeded")
		return
	n.group = 1
	mm_uml_body(p, index, depth + 1)

void mm_class_statement(mm_parser* p, int scope, int depth):
	if (mm_keyword(p, c"namespace")):
		char* path = mm_uml_id(p)
		int parent = scope
		int start = 0
		int nesting = depth
		for i in range(strlen(path) + 1):
			if (path[i] != '.' && path[i] != 0): continue
			if (i == start): mm_error(p.doc, p.pos, c"empty namespace path segment")
			char* part = str_copy_range(path, start, i)
			string_builder* key = string_new()
			if (parent >= 0):
				mm_node* outer = p.doc.nodes[parent]
				string_append(key, outer.id)
				string_append_char(key, '.')
			string_append(key, part)
			int existing = mm_find_node(p.doc, key.data)
			int index = mm_add_node(p.doc, key.data, p.pos)
			string_free(key)
			if (index >= 0):
				mm_node* node = p.doc.nodes[index]
				if (node.declared && node.group == 0): mm_error(p.doc, p.pos, c"namespace conflicts with a class")
				node.parent = parent
				node.group = 1
				node.declared = 1
				if (existing < 0):
					free(node.label)
					node.label = strclone(part)
				parent = index
			free(part)
			start = i + 1
			nesting = nesting + 1
			if (nesting > 32): mm_error(p.doc, p.pos, c"group nesting limit exceeded")
		free(path)
		mm_space(p)
		if (mm_match(p, c"[")):
			char* label = mm_until(p, ']')
			if (parent >= 0):
				mm_node* node = p.doc.nodes[parent]
				free(node.label)
				node.label = strclone(label)
			free(label)
			mm_space(p)
		if (p.doc.error != 0): return
		if (mm_match(p, c"{")): mm_uml_body(p, parent, nesting)
		else: mm_error(p.doc, p.pos, c"expected namespace body")
		return
	if (mm_match(p, c"<<")):
		char* annotation = mm_annotation(p)
		int index = mm_uml_node(p, scope, 0)
		if (index >= 0):
			mm_node* n = p.doc.nodes[index]
			if (n.group): mm_error(p.doc, p.pos, c"namespace cannot have a class annotation")
			if (n.annotation[0] != 0): mm_error(p.doc, p.pos, c"duplicate class annotation")
			free(n.annotation)
			n.annotation = strclone(annotation)
		free(annotation)
		return
	int declaration = mm_keyword(p, c"class")
	int index = mm_uml_node(p, scope, 0)
	if (index < 0): return
	mm_node* n = p.doc.nodes[index]
	if (n.group):
		mm_error(p.doc, p.pos, c"namespace cannot be used as a class")
		return
	mm_space(p)
	if (declaration):
		if (n.declared && n.parent != scope): mm_error(p.doc, p.pos, c"class already declared in another namespace")
		n.parent = scope
		n.declared = 1
		if (mm_match(p, c"[")):
			free(n.label)
			n.label = mm_until(p, ']')
			mm_space(p)
		if (mm_match(p, c"<<")):
			if (n.annotation[0] != 0): mm_error(p.doc, p.pos, c"duplicate class annotation")
			free(n.annotation)
			n.annotation = mm_annotation(p)
			mm_space(p)
		if (mm_match(p, c":::")): mm_style_inline(p, n)
		mm_space(p)
		if (mm_match(p, c"{")): mm_class_body(p, index)
	else if (mm_match(p, c":::")): mm_style_inline(p, n)
	else if (mm_match(p, c":")): mm_class_member(p, index)
	else: mm_class_relation(p, index, scope)

# `State:::class`; upstream does not style start or end states either.
void mm_state_class(mm_parser* p, mm_node* n):
	if (n.shape >= 4 && n.shape != 6):
		mm_error(p.doc, p.pos, c"start and end states cannot be styled")
		return
	mm_style_inline(p, n)

void mm_state_statement(mm_parser* p, int scope, int depth):
	int declaration = mm_keyword(p, c"state")
	char* label = 0
	mm_space(p)
	if (declaration && mm_peek(p) == '"'):
		label = mm_quoted(p)
		mm_space(p)
		if (mm_keyword(p, c"as") == 0): mm_error(p.doc, p.pos, c"expected as after state description")
	int index = mm_uml_node(p, scope, 0)
	if (index < 0):
		free(label)
		return
	mm_node* n = p.doc.nodes[index]
	if (label != 0):
		free(n.label)
		n.label = label
	mm_space(p)
	if (declaration):
		if (n.declared && n.parent != scope): mm_error(p.doc, p.pos, c"state declared in another composite")
		int ancestor = scope
		while (ancestor >= 0):
			if (ancestor == index):
				mm_error(p.doc, p.pos, c"state cannot contain itself")
				break
			mm_node* outer = p.doc.nodes[ancestor]
			ancestor = outer.parent
		if (p.doc.error != 0): return
		n.parent = scope
		n.declared = 1
		if (n.shape >= 4): mm_error(p.doc, p.pos, c"cannot declare a start or end state")
		if (mm_match(p, c"<<")):
			char* annotation = mm_annotation(p)
			if (n.group): mm_error(p.doc, p.pos, c"composite state cannot be a choice, fork or join")
			if (strcmp(annotation, c"choice") == 0): n.shape = 3
			else if (strcmp(annotation, c"fork") == 0 || strcmp(annotation, c"join") == 0): n.shape = 6
			else: mm_error(p.doc, p.pos, c"unsupported state annotation")
			free(n.annotation)
			n.annotation = annotation
			mm_space(p)
		if (mm_match(p, c":::")):
			mm_state_class(p, n)
			mm_space(p)
		if (mm_match(p, c"{")): mm_group_body(p, index, depth)
		return
	if (mm_match(p, c":::")):
		mm_state_class(p, n)
		mm_space(p)
		if (mm_end(p) || mm_peek(p) == '}'): return
	if (mm_match(p, c":")):
		if (n.shape != 1): mm_error(p.doc, p.pos, c"special state cannot have a description")
		free(n.label)
		n.label = mm_uml_text(p)
		return
	if (mm_end(p) || mm_peek(p) == '}'):
		if (n.shape == 4): mm_error(p.doc, p.pos, c"start state requires a transition")
		return
	mm_edge* e = mm_uml_edge(p, index, scope)
	if (e == 0): return
	e.arrow = 1
	if (mm_match(p, c"-->") == 0): mm_error(p.doc, p.pos, c"expected state transition -->")
	e.to_node = mm_uml_node(p, scope, 1)
	mm_space(p)
	if (e.to_node >= 0 && mm_match(p, c":::")):
		mm_state_class(p, p.doc.nodes[e.to_node])
		mm_space(p)
	if (mm_match(p, c":")):
		free(e.label)
		e.label = mm_uml_text(p)

void mm_uml_note(mm_parser* p, int scope):
	if (p.doc.notes.length >= MM_MAX_ITEMS):
		mm_error(p.doc, p.pos, c"UML note limit exceeded")
		return
	mm_note* note = new mm_note()
	note.node = -1
	note.side = 1
	note.text = strclone(c"")
	p.doc.notes.push(note)
	mm_space(p)
	if (p.doc.kind == MM_CLASS):
		if (mm_keyword(p, c"for")): note.node = mm_uml_node(p, scope, 0)
		mm_space(p)
		if (mm_peek(p) != '"'):
			mm_error(p.doc, p.pos, c"class note requires quoted text")
			return
		free(note.text)
		note.text = mm_quoted(p)
		return
	if (mm_keyword(p, c"left")): note.side = -1
	else if (mm_keyword(p, c"right") == 0): mm_error(p.doc, p.pos, c"state note requires left or right")
	mm_space(p)
	if (mm_keyword(p, c"of") == 0): mm_error(p.doc, p.pos, c"state note requires of participant")
	note.node = mm_uml_node(p, scope, 0)
	mm_space(p)
	if (mm_match(p, c":")):
		free(note.text)
		note.text = mm_uml_text(p)
		return
	if (mm_end(p) == 0):
		mm_error(p.doc, p.pos, c"expected state note text or newline")
		return
	string_builder* text = string_new()
	int closed = 0
	while (mm_peek(p) != 0):
		if (mm_peek(p) == 10 || mm_peek(p) == 13): p.pos = p.pos + 1
		mm_space(p)
		int start = p.pos
		if (mm_keyword(p, c"end")):
			mm_space(p)
			if (mm_keyword(p, c"note")):
				closed = 1
				break
			p.pos = start
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13):
			string_append_char(text, mm_peek(p))
			p.pos = p.pos + 1
		if (text.length != 0): string_append_char(text, 10)
	if (closed == 0): mm_error(p.doc, p.pos, c"unterminated state note")
	free(note.text)
	note.text = strclone(text.data)
	string_free(text)

void mm_uml_edge_scopes(mm_document* d):
	for mm_edge* edge in d.edges:
		if (edge.from_node < 0 || edge.to_node < 0): continue
		mm_node* from = d.nodes[edge.from_node]
		mm_node* to = d.nodes[edge.to_node]
		int scope = from.parent
		while (scope >= 0):
			int other = to.parent
			while (other >= 0 && other != scope):
				mm_node* parent = d.nodes[other]
				other = parent.parent
			if (other == scope): break
			mm_node* parent = d.nodes[scope]
			scope = parent.parent
		edge.scope = scope

int mm_state_is_region(mm_node* n):
	return index_of(n.id, c"@region:") == 0

int mm_state_region_new(mm_parser* p, int scope):
	string_builder* key = string_from(c"@region:")
	string_append_int(key, p.doc.nodes.length)
	int region = mm_add_node(p.doc, key.data, p.pos)
	string_free(key)
	if (region < 0): return -1
	mm_node* n = p.doc.nodes[region]
	free(n.label)
	n.label = strclone(c"")
	n.parent = scope
	n.group = 1
	n.declared = 1
	n.shape = 1
	return region

# Concurrent state regions are anonymous groups inside their composite. The
# first separator moves the statements seen so far into region zero.
int mm_state_region(mm_parser* p, int scope, int current):
	int count = 0
	for mm_node* node in p.doc.nodes:
		if (node.parent == current): count = count + 1
	if (count == 0):
		mm_error(p.doc, p.pos, c"empty concurrent state region")
		return current
	if (current == scope):
		int first = mm_state_region_new(p, scope)
		if (first < 0): return current
		for i in range(first):
			mm_node* node = p.doc.nodes[i]
			if (node.parent == scope): node.parent = first
	int region = mm_state_region_new(p, scope)
	if (region < 0): return current
	return region

void mm_uml_body(mm_parser* p, int scope, int depth):
	mm_separators(p)
	int current = scope
	while (p.doc.error == 0 && mm_peek(p) != 0):
		if (mm_match(p, c"}")):
			if (scope < 0): mm_error(p.doc, p.pos - 1, c"unexpected closing group brace")
			else if (current != scope):
				int count = 0
				for mm_node* node in p.doc.nodes:
					if (node.parent == current): count = count + 1
				if (count == 0): mm_error(p.doc, p.pos - 1, c"empty concurrent state region")
			return
		int start = p.pos
		if (mm_metadata(p)): mm_space(p)
		else if (mm_style_statement(p)): mm_space(p)
		else if (p.doc.kind == MM_STATE && mm_peek(p) == '-' && p.pos + 1 < p.doc.length && p.doc.source[p.pos + 1] == '-'):
			p.pos = p.pos + 2
			if (scope < 0): mm_error(p.doc, start, c"concurrent region separator outside composite state")
			else: current = mm_state_region(p, scope, current)
		else if (mm_keyword(p, c"note")): mm_uml_note(p, current)
		else if (mm_keyword(p, c"direction")):
			if (current < 0): mm_direction(p)
			else:
				char* outer = p.doc.direction
				p.doc.direction = strclone(outer)
				mm_direction(p)
				mm_node* n = p.doc.nodes[current]
				free(n.direction)
				n.direction = p.doc.direction
				p.doc.direction = outer
		else if (p.doc.kind == MM_CLASS && mm_style_keyword(p, c"click")): mm_interaction_statement(p, 0)
		else if (p.doc.kind == MM_CLASS && mm_style_keyword(p, c"link")): mm_interaction_statement(p, 1)
		else if (p.doc.kind == MM_CLASS && mm_style_keyword(p, c"callback")): mm_interaction_statement(p, 2)
		else if (p.doc.kind == MM_CLASS): mm_class_statement(p, current, depth)
		else: mm_state_statement(p, current, depth)
		if (mm_end(p) == 0 && mm_peek(p) != '}'): mm_error(p.doc, p.pos, c"unsupported UML syntax or missing statement separator")
		mm_separators(p)
		if (p.pos == start): mm_error(p.doc, start, c"expected UML statement")
	if (scope >= 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"unterminated group")
	if (scope < 0 && p.doc.error == 0): mm_uml_edge_scopes(p.doc)
