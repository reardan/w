# Requirement and indentation-based families, referenced against Mermaid 12.2.0.
import libs.extras.mermaid.uml

int mm_in_words(char* value, char* options):
	string_builder* needle = string_from(c"|")
	string_append(needle, value)
	string_append_char(needle, '|')
	int found = index_of(options, needle.data) >= 0
	string_free(needle)
	return found

# mm_in_words with ASCII case folded, for case-insensitive lexers
# (requirementDiagram); options must be lowercase.
int mm_in_words_folded(char* value, char* options):
	char* folded = strclone(value)
	int i = 0
	while (folded[i] != 0):
		folded[i] = tolower(folded[i])
		i = i + 1
	int found = mm_in_words(folded, options)
	free(folded)
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
		if (mm_metadata(p) || mm_style_statement(p)):
			mm_separators(p)
			continue
		# `direction TB|BT|LR|RL` (upstream lexes it anywhere on its line).
		if (mm_style_keyword(p, c"direction")):
			if (mm_direction(p) && strcmp(p.doc.direction, c"TD") == 0):
				free(p.doc.direction)
				p.doc.direction = strclone(c"TB")
			if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported requirement syntax")
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
			# `name:::class` assigns classDef classes, as upstream setClass does.
			if (mm_match(p, c":::")): mm_style_inline(p, n)
			mm_space(p)
			if (mm_match(p, c"{") == 0): mm_error(p.doc, p.pos, c"expected requirement property block")
			mm_separators(p)
			list[char*] keys = new list[char*]
			while (mm_peek(p) != '}' && p.doc.error == 0):
				char* key = mm_identifier(p)
				int element = strcmp(word, c"element") == 0
				# Keywords are case-insensitive upstream (`docRef`, `verifyMethod`).
				if ((element && mm_in_words_folded(key, c"|type|docref|") == 0) || (element == 0 && mm_in_words_folded(key, c"|id|text|risk|verifymethod|") == 0)): mm_error(p.doc, p.pos, c"unsupported requirement property")
				char* folded_key = strclone(key)
				for i in range(strlen(folded_key)): folded_key[i] = tolower(folded_key[i])
				for char* prior in keys:
					if (strcmp(prior, folded_key) == 0): mm_error(p.doc, p.pos, c"duplicate requirement property")
				keys.push(folded_key)
				mm_space(p)
				if (mm_match(p, c":") == 0): mm_error(p.doc, p.pos, c"expected property colon")
				char* value = mm_property_value(p)
				if (strcmp(folded_key, c"risk") == 0 && mm_in_words_folded(value, c"|low|medium|high|") == 0): mm_error(p.doc, p.pos, c"expected risk low, medium or high")
				if (strcmp(folded_key, c"verifymethod") == 0 && mm_in_words_folded(value, c"|analysis|inspection|test|demonstration|") == 0): mm_error(p.doc, p.pos, c"invalid verification method")
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
			# A standalone `name:::class` statement assigns classes.
			if (from >= 0 && mm_match(p, c":::")):
				mm_style_inline(p, p.doc.nodes[from])
				free(word)
				if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported requirement syntax")
				mm_separators(p)
				continue
			mm_space(p)
			int reverse = mm_match(p, c"<-")
			if (reverse == 0 && mm_match(p, c"-") == 0): mm_error(p.doc, p.pos, c"expected requirement relationship")
			char* relation = mm_identifier(p)
			for i in range(strlen(relation)): relation[i] = tolower(relation[i])
			if (mm_in_words_folded(relation, c"|contains|copies|derives|satisfies|verifies|refines|traces|") == 0): mm_error(p.doc, p.pos, c"unknown requirement relationship")
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
		if (mm_in_words(key, c"|assigned|ticket|priority|label|") == 0): mm_error(p.doc, p.pos, c"unsupported Kanban metadata key")
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
		# `label` replaces the bracket title, as upstream kanbanDb does.
		if (strcmp(key, c"label") == 0):
			free(n.label)
			n.label = strclone(value)
		else: mm_graph_member(p, n, key, value)
		free(key)
		free(value)
		mm_space(p)
		if (mm_match(p, c",") == 0): break
		mm_space(p)
	for char* key in keys: free(key)
	__w_list_free(cast(__w_list*, keys))
	if (mm_match(p, c"}") == 0): mm_error(p.doc, p.pos, c"expected metadata closing brace")

# Mindmap classes name external CSS; there is no classDef in this family, so
# the names are retained in the owned model without a native style lookup.
void mm_mindmap_classes(mm_parser* p, mm_node* n):
	string_builder* joined = string_from(n.style_classes)
	while (p.doc.error == 0):
		mm_space(p)
		int start = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13 && mm_peek(p) != 32 && mm_peek(p) != 9): p.pos = p.pos + 1
		if (p.pos == start): break
		char* name = str_copy_range(p.doc.source, start, p.pos)
		if (mm_style_name(name) == 0): mm_error(p.doc, start, c"invalid mindmap class name")
		if (joined.length + strlen(name) > 4096): mm_error(p.doc, start, c"node class assignment limit exceeded")
		if (joined.length != 0): string_append_char(joined, ',')
		string_append(joined, name)
		free(name)
	if (joined.length == strlen(n.style_classes)): mm_error(p.doc, p.pos, c"expected mindmap class names")
	free(n.style_classes)
	n.style_classes = strclone(joined.data)
	string_free(joined)

# A decoration line applies `::icon(name)` or `:::classes` to the previous node.
void mm_mindmap_decoration(mm_parser* p):
	int start = p.pos
	if (p.doc.nodes.length == 0):
		mm_error(p.doc, start, c"mindmap decoration requires a preceding node")
		return
	mm_node* n = p.doc.nodes[p.doc.nodes.length - 1]
	if (mm_match(p, c"::icon(")):
		if (n.annotation[0] != 0): mm_error(p.doc, start, c"duplicate mindmap icon")
		int open = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != ')'): p.pos = p.pos + 1
		char* name = mm_style_trim(p.doc.source, open, p.pos)
		if (mm_match(p, c")") == 0 || name[0] == 0): mm_error(p.doc, open, c"expected nonempty mindmap icon name")
		free(n.annotation)
		n.annotation = name
	else if (mm_match(p, c":::")): mm_mindmap_classes(p, n)
	else: mm_error(p.doc, start, c"unsupported mindmap decoration")
	mm_space(p)
	if (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13): mm_error(p.doc, p.pos, c"expected end of mindmap decoration line")

# Physical indentation remains meaningful; do not use mm_separators here.
void mm_hierarchy_body(mm_parser* p):
	list[int] indents = new list[int]
	list[int] parents = new list[int]
	# Mindmap: per-node indentation and depth for upstream's parent rule.
	list[int] levels = new list[int]
	list[int] depths = new list[int]
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
			if (mm_peek(p) == '{'): mm_skip_directive(p)
			while (mm_peek(p) != 0 && mm_peek(p) != 10): p.pos = p.pos + 1
			continue
		if (p.doc.kind == MM_MINDMAP && mm_peek(p) == ':'):
			mm_mindmap_decoration(p)
			continue
		if (mm_metadata(p)):
			# Only consume horizontal whitespace here. The next loop iteration
			# counts the next physical line's indentation before assigning parents.
			mm_space(p)
			if (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13): mm_error(p.doc, p.pos, c"expected end of accessibility metadata line")
			continue
		int depth = 0
		while (depth < indents.length && indent > indents[depth]): depth = depth + 1
		# Upstream mindmapDb.getParent: the parent is the nearest earlier node
		# indented less than this line, so in-between indentation is accepted.
		int mind_parent = -1
		if (p.doc.kind == MM_MINDMAP):
			int j = levels.length - 1
			while (j >= 0 && levels[j] >= indent): j = j - 1
			mind_parent = j
			depth = 0
			if (j >= 0): depth = depths[j] + 1
		else if (depth < indents.length && indent != indents[depth]): mm_error(p.doc, p.pos, c"indentation must match a previous level")
		if (depth >= 64): mm_error(p.doc, p.pos, c"hierarchy nesting limit exceeded")
		if (p.doc.kind == MM_MINDMAP && p.doc.nodes.length > 0 && mind_parent < 0): mm_error(p.doc, p.pos, c"mindmap requires one root")
		int start = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13 && mm_peek(p) != '[' && mm_peek(p) != '(' && mm_peek(p) != ')' && mm_peek(p) != '{' && mm_peek(p) != '@' && mm_peek(p) != ':'): p.pos = p.pos + 1
		int end = p.pos
		while (end > start && p.doc.source[end - 1] == 32): end = end - 1
		char* raw = str_copy_range(p.doc.source, start, end)
		string_builder* generated = string_from(c"@hierarchy:")
		string_append_int(generated, p.doc.nodes.length)
		char* id = generated.data
		if (raw[0] != 0 && mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13): id = raw
		# Upstream Kanban keeps every item even when an ID repeats (its own
		# docs example reuses id3): the repeat gets a generated internal ID and
		# keeps the written one as its "id" property.
		int repeated = p.doc.kind == MM_KANBAN && id == raw && mm_find_node(p.doc, id) >= 0
		if (repeated): id = generated.data
		else if (mm_find_node(p.doc, id) >= 0): mm_error(p.doc, start, c"duplicate hierarchy node identifier")
		int index = mm_add_node(p.doc, id, start)
		string_free(generated)
		if (index < 0):
			free(raw)
			break
		mm_node* n = p.doc.nodes[index]
		if (repeated): n.metadata.push(new mm_property(strclone(c"id"), strclone(raw), MM_VALUE_STRING))
		free(n.label)
		n.label = raw
		if (depth > 0): n.parent = parents[depth - 1]
		if (p.doc.kind == MM_MINDMAP):
			n.parent = mind_parent
			levels.push(indent)
			depths.push(depth)
		# Upstream Kanban (kanbanDb getSection) attaches every deeper item to
		# the enclosing column: indented cards are siblings, not subcards.
		if (p.doc.kind == MM_KANBAN && depth > 1): n.parent = parents[0]
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
		else if (p.doc.kind == MM_MINDMAP && mm_match(p, c"))")):
			close = '('
			doubled = 1
			n.shape = 4
		else if (p.doc.kind == MM_MINDMAP && mm_match(p, c")")):
			close = '('
			n.shape = 3
		else if (p.doc.kind == MM_MINDMAP && mm_match(p, c"{{")):
			close = '}'
			doubled = 1
			n.shape = 5
		if (close):
			free(n.label)
			n.label = mm_until(p, close)
			if (doubled && mm_peek(p) != close): mm_error(p.doc, p.pos, c"expected doubled closing shape delimiter")
			else if (doubled): p.pos = p.pos + 1
		if (n.label[0] == 0): mm_error(p.doc, start, c"empty hierarchy label")
		mm_space(p)
		if (p.doc.kind == MM_KANBAN): mm_kanban_metadata(p, n)
		mm_space(p)
		if (p.doc.kind == MM_MINDMAP && mm_match(p, c":::")): mm_mindmap_classes(p, n)
		if (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13): mm_error(p.doc, p.pos, c"unsupported hierarchy shape, annotation or syntax")
	__w_list_free(cast(__w_list*, indents))
	__w_list_free(cast(__w_list*, parents))
	__w_list_free(cast(__w_list*, levels))
	__w_list_free(cast(__w_list*, depths))
	if (p.doc.nodes.length == 0): mm_error(p.doc, p.pos, c"expected hierarchy nodes")
