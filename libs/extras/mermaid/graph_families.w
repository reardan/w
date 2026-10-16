# Requirement and indentation-based families, referenced against Mermaid 12.2.0.
import libs.extras.mermaid.uml

int mm_in_words(char* value, char* options):
	string_builder* needle = string_from(c"|")
	string_append(needle, value)
	string_append_char(needle, '|')
	int found = index_of(options, needle.data) >= 0
	string_free(needle)
	return found

void mm_graph_member(mm_parser* p, mm_node* n, char* key, char* value):
	if (p.doc.attribute_count >= 4096):
		mm_error(p.doc, p.pos, c"property limit exceeded")
		return
	string_builder* text = string_from(key)
	string_append(text, c": ")
	string_append(text, value)
	mm_member* m = new mm_member()
	m.text = strclone(text.data)
	n.members.push(m)
	p.doc.attribute_count = p.doc.attribute_count + 1
	string_free(text)

char* mm_property_value(mm_parser* p):
	mm_space(p)
	if (mm_peek(p) == '"'): return mm_quoted(p)
	return mm_uml_text(p)

void mm_requirement_body(mm_parser* p):
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_metadata(p)):
			mm_separators(p)
			continue
		char* word = mm_identifier(p)
		if (mm_in_words(word, c"|requirement|functionalRequirement|interfaceRequirement|performanceRequirement|physicalRequirement|designConstraint|element|")):
			char* id = mm_identifier(p)
			int index = mm_add_node(p.doc, id, p.pos)
			free(id)
			if (index < 0):
				free(word)
				return
			mm_node* n = p.doc.nodes[index]
			if (n.declared): mm_error(p.doc, p.pos, c"duplicate requirement or element")
			n.declared = 1
			free(n.annotation)
			n.annotation = strclone(word)
			mm_space(p)
			if (mm_match(p, c"{") == 0): mm_error(p.doc, p.pos, c"expected requirement property block")
			mm_separators(p)
			list[char*] keys = new list[char*]
			while (mm_peek(p) != '}' && p.doc.error == 0):
				char* key = mm_identifier(p)
				int element = strcmp(word, c"element") == 0
				if ((element && mm_in_words(key, c"|type|docref|") == 0) || (element == 0 && mm_in_words(key, c"|id|text|risk|verifymethod|") == 0)): mm_error(p.doc, p.pos, c"unsupported requirement property")
				for char* prior in keys:
					if (strcmp(prior, key) == 0): mm_error(p.doc, p.pos, c"duplicate requirement property")
				keys.push(strclone(key))
				mm_space(p)
				if (mm_match(p, c":") == 0): mm_error(p.doc, p.pos, c"expected property colon")
				char* value = mm_property_value(p)
				if (strcmp(key, c"risk") == 0 && mm_in_words(value, c"|low|medium|high|Low|Medium|High|") == 0): mm_error(p.doc, p.pos, c"expected risk low, medium or high")
				if (strcmp(key, c"verifymethod") == 0 && mm_in_words(value, c"|analysis|inspection|test|demonstration|Analysis|Inspection|Test|Demonstration|") == 0): mm_error(p.doc, p.pos, c"invalid verification method")
				mm_graph_member(p, n, key, value)
				free(key)
				free(value)
				if (mm_end(p) == 0 && mm_peek(p) != '}'): mm_error(p.doc, p.pos, c"expected property separator")
				mm_separators(p)
			for char* key in keys: free(key)
			__w_list_free(cast(__w_list*, keys))
			if (mm_match(p, c"}") == 0): mm_error(p.doc, p.pos, c"unterminated requirement block")
		else:
			int from = mm_add_node(p.doc, word, p.pos)
			mm_space(p)
			int reverse = mm_match(p, c"<-")
			if (reverse == 0 && mm_match(p, c"-") == 0): mm_error(p.doc, p.pos, c"expected requirement relationship")
			char* relation = mm_identifier(p)
			if (mm_in_words(relation, c"|contains|copies|derives|satisfies|verifies|refines|traces|") == 0): mm_error(p.doc, p.pos, c"unknown requirement relationship")
			mm_space(p)
			if ((reverse && mm_match(p, c"-") == 0) || (reverse == 0 && mm_match(p, c"->") == 0)): mm_error(p.doc, p.pos, c"expected relationship arrow")
			char* id = mm_identifier(p)
			int to = mm_add_node(p.doc, id, p.pos)
			free(id)
			if (p.doc.edges.length >= MM_MAX_ITEMS): mm_error(p.doc, p.pos, c"edge limit exceeded")
			if (p.doc.error == 0):
				mm_edge* e = new mm_edge()
				e.from_node = from
				e.to_node = to
				if (reverse):
					e.from_node = to
					e.to_node = from
				e.scope = -1
				e.label = strclone(relation)
				e.left_label = strclone(c"")
				e.right_label = strclone(c"")
				e.right_marker = MM_ARROW
				e.dashed = 1
				if (strcmp(relation, c"contains") == 0):
					e.dashed = 0
					e.right_marker = 0
					e.left_marker = 5
				p.doc.edges.push(e)
			free(relation)
		free(word)
		if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported requirement syntax")
		mm_separators(p)
	for mm_node* n in p.doc.nodes:
		if (n.declared == 0): mm_error(p.doc, p.pos, c"relationship references undeclared requirement or element")

void mm_kanban_metadata(mm_parser* p, mm_node* n):
	if (mm_match(p, c"@{") == 0): return
	list[char*] keys = new list[char*]
	while (mm_peek(p) != '}' && p.doc.error == 0):
		char* key = mm_identifier(p)
		if (mm_in_words(key, c"|assigned|ticket|priority|") == 0): mm_error(p.doc, p.pos, c"unsupported Kanban metadata key")
		for char* prior in keys:
			if (strcmp(prior, key) == 0): mm_error(p.doc, p.pos, c"duplicate Kanban metadata key")
		keys.push(strclone(key))
		mm_space(p)
		if (mm_match(p, c":") == 0): mm_error(p.doc, p.pos, c"expected metadata colon")
		mm_space(p)
		int quote = 0
		if (mm_peek(p) == '\'' || mm_peek(p) == '"'):
			quote = mm_peek(p)
			p.pos = p.pos + 1
		int start = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && ((quote && mm_peek(p) != quote) || (quote == 0 && mm_peek(p) != ',' && mm_peek(p) != '}'))): p.pos = p.pos + 1
		int end = p.pos
		while (end > start && p.doc.source[end - 1] == 32): end = end - 1
		char* value = str_copy_range(p.doc.source, start, end)
		if (quote):
			if (mm_peek(p) != quote): mm_error(p.doc, p.pos, c"unterminated metadata string")
			else: p.pos = p.pos + 1
		if (value[0] == 0): mm_error(p.doc, p.pos, c"expected metadata value")
		if (strcmp(key, c"priority") == 0 && mm_in_words(value, c"|Very High|High|Low|Very Low|") == 0): mm_error(p.doc, p.pos, c"invalid Kanban priority")
		mm_graph_member(p, n, key, value)
		free(key)
		free(value)
		mm_space(p)
		if (mm_match(p, c",") == 0): break
		mm_space(p)
	for char* key in keys: free(key)
	__w_list_free(cast(__w_list*, keys))
	if (mm_match(p, c"}") == 0): mm_error(p.doc, p.pos, c"expected metadata closing brace")

# Physical indentation remains meaningful; do not use mm_separators here.
void mm_hierarchy_body(mm_parser* p):
	list[int] indents = new list[int]
	list[int] parents = new list[int]
	while (p.pos < p.doc.length && p.doc.error == 0):
		if (mm_peek(p) == 13): p.pos = p.pos + 1
		if (mm_peek(p) == 10): p.pos = p.pos + 1
		int indent = 0
		while (mm_peek(p) == 32 || mm_peek(p) == 9):
			if (mm_peek(p) == 9): indent = indent + 4
			else: indent = indent + 1
			p.pos = p.pos + 1
		if (mm_peek(p) == 0): break
		if (mm_peek(p) == 10 || mm_peek(p) == 13): continue
		if (mm_match(p, c"%%")):
			if (mm_peek(p) == '{'): mm_error(p.doc, p.pos, c"configuration directives are unsupported")
			while (mm_peek(p) != 0 && mm_peek(p) != 10): p.pos = p.pos + 1
			continue
		int depth = 0
		while (depth < indents.length && indent > indents[depth]): depth = depth + 1
		if (depth < indents.length && indent != indents[depth]): mm_error(p.doc, p.pos, c"indentation must match a previous level")
		if (depth >= 64): mm_error(p.doc, p.pos, c"hierarchy nesting limit exceeded")
		if (p.doc.kind == MM_KANBAN && depth > 1): mm_error(p.doc, p.pos, c"Kanban cards cannot contain nested cards")
		if (p.doc.kind == MM_MINDMAP && p.doc.nodes.length > 0 && depth == 0): mm_error(p.doc, p.pos, c"mindmap requires one root")
		int start = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13 && mm_peek(p) != '[' && mm_peek(p) != '(' && mm_peek(p) != ')' && mm_peek(p) != '{' && mm_peek(p) != '@' && mm_peek(p) != ':'): p.pos = p.pos + 1
		int end = p.pos
		while (end > start && p.doc.source[end - 1] == 32): end = end - 1
		char* raw = str_copy_range(p.doc.source, start, end)
		string_builder* generated = string_from(c"@hierarchy:")
		string_append_int(generated, p.doc.nodes.length)
		char* id = generated.data
		if (raw[0] != 0 && mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13): id = raw
		if (mm_find_node(p.doc, id) >= 0): mm_error(p.doc, start, c"duplicate hierarchy node identifier")
		int index = mm_add_node(p.doc, id, start)
		string_free(generated)
		if (index < 0):
			free(raw)
			break
		mm_node* n = p.doc.nodes[index]
		free(n.label)
		n.label = raw
		if (depth > 0): n.parent = parents[depth - 1]
		if (depth == indents.length):
			indents.push(indent)
			parents.push(index)
		else:
			while (indents.length > depth + 1): indents.pop()
			while (parents.length > depth + 1): parents.pop()
			parents[depth] = index
		int close = 0
		int doubled = 0
		if (mm_match(p, c"[")): close = ']'
		else if (p.doc.kind == MM_MINDMAP && mm_match(p, c"((")):
			close = ')'
			doubled = 1
			n.shape = 2
		else if (p.doc.kind == MM_MINDMAP && mm_match(p, c"(")):
			close = ')'
			n.shape = 1
		if (close):
			free(n.label)
			n.label = mm_until(p, close)
			if (doubled && mm_match(p, c")") == 0): mm_error(p.doc, p.pos, c"expected circle closing parenthesis")
		if (n.label[0] == 0): mm_error(p.doc, start, c"empty hierarchy label")
		mm_space(p)
		if (p.doc.kind == MM_KANBAN):
			if (depth == 0 && mm_peek(p) == '@'): mm_error(p.doc, p.pos, c"metadata is supported on cards only")
			mm_kanban_metadata(p, n)
		mm_space(p)
		if (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13): mm_error(p.doc, p.pos, c"unsupported hierarchy shape, annotation or syntax")
	__w_list_free(cast(__w_list*, indents))
	__w_list_free(cast(__w_list*, parents))
	if (p.doc.nodes.length == 0): mm_error(p.doc, p.pos, c"expected hierarchy nodes")
