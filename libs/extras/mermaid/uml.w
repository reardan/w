# Class and state syntax, referenced against Mermaid 12.2.0.
import libs.extras.mermaid.parse_common

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
	while (mm_id_char(mm_peek(p)) || mm_peek(p) == '-'):
		if (mm_peek(p) == '-' && p.pos + 1 < p.doc.length && p.doc.source[p.pos + 1] == '-'): break
		p.pos = p.pos + 1
	char* id = str_copy_range(p.doc.source, start, p.pos)
	if (p.pos == start): mm_error(p.doc, start, c"expected class or state identifier")
	if (strcmp(id, c"style") == 0 || strcmp(id, c"classDef") == 0 || strcmp(id, c"cssClass") == 0 || strcmp(id, c"click") == 0 || strcmp(id, c"note") == 0 || strcmp(id, c"link") == 0 || strcmp(id, c"callback") == 0 || strcmp(id, c"accTitle") == 0 || strcmp(id, c"accDescr") == 0 || strcmp(id, c"end") == 0):
		mm_error(p.doc, start, c"unsupported UML statement")
	return id

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
	else if (p.doc.kind == MM_STATE && n.parent != scope): mm_error(p.doc, offset, c"node belongs to another group; cross-scope references are not supported")
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

void mm_class_relation(mm_parser* p, int left, int scope):
	mm_edge* e = mm_uml_edge(p, left, scope)
	if (e == 0): return
	mm_space(p)
	if (mm_peek(p) == '"'):
		free(e.left_label)
		e.left_label = mm_quoted(p)
		mm_space(p)
	if (mm_match(p, c"<|")): e.left_marker = MM_TRIANGLE
	else if (mm_match(p, c"<")): e.left_marker = MM_ARROW
	else if (mm_match(p, c"*")): e.left_marker = MM_COMPOSITION
	else if (mm_match(p, c"o")): e.left_marker = MM_AGGREGATION
	if (mm_match(p, c"..")): e.dashed = 1
	else if (mm_match(p, c"--") == 0): mm_error(p.doc, p.pos, c"expected class relationship -- or ..")
	if (mm_match(p, c"|>")): e.right_marker = MM_TRIANGLE
	else if (mm_match(p, c">")): e.right_marker = MM_ARROW
	else if (mm_match(p, c"*")): e.right_marker = MM_COMPOSITION
	else if (mm_match(p, c"o")): e.right_marker = MM_AGGREGATION
	mm_space(p)
	if (mm_peek(p) == '"'):
		free(e.right_label)
		e.right_label = mm_quoted(p)
	e.to_node = mm_uml_node(p, scope, 0)
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
		int index = mm_uml_node(p, scope, 0)
		mm_space(p)
		if (index < 0): return
		mm_node* n = p.doc.nodes[index]
		if (n.declared): mm_error(p.doc, p.pos, c"duplicate namespace or conflicting class")
		n.parent = scope
		n.declared = 1
		if (mm_match(p, c"{")): mm_group_body(p, index, depth)
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
		if (mm_match(p, c"{")): mm_class_body(p, index)
	else if (mm_match(p, c":::")): mm_error(p.doc, p.pos, c"class styling is not supported")
	else if (mm_match(p, c":")): mm_class_member(p, index)
	else: mm_class_relation(p, index, scope)

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
		if (mm_match(p, c"{")): mm_group_body(p, index, depth)
		return
	if (mm_match(p, c":::")):
		mm_error(p.doc, p.pos, c"state styling is not supported")
		return
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
	if (mm_match(p, c":")):
		free(e.label)
		e.label = mm_uml_text(p)

void mm_uml_body(mm_parser* p, int scope, int depth):
	mm_separators(p)
	while (p.doc.error == 0 && mm_peek(p) != 0):
		if (mm_match(p, c"}")):
			if (scope < 0): mm_error(p.doc, p.pos - 1, c"unexpected closing group brace")
			return
		int start = p.pos
		if (mm_keyword(p, c"direction")):
			if (scope < 0): mm_direction(p)
			else:
				char* outer = p.doc.direction
				p.doc.direction = strclone(outer)
				mm_direction(p)
				mm_node* n = p.doc.nodes[scope]
				free(n.direction)
				n.direction = p.doc.direction
				p.doc.direction = outer
		else if (p.doc.kind == MM_CLASS): mm_class_statement(p, scope, depth)
		else: mm_state_statement(p, scope, depth)
		if (mm_end(p) == 0 && mm_peek(p) != '}'): mm_error(p.doc, p.pos, c"unsupported UML syntax or missing statement separator")
		mm_separators(p)
		if (p.pos == start): mm_error(p.doc, start, c"expected UML statement")
	if (scope >= 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"unterminated group")
