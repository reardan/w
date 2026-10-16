# Native outline, cause/effect and decision-framework models.
import libs.extras.mermaid.graph_families

char* mm_line_text(mm_parser* p):
	mm_space(p)
	int start = p.pos
	while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13): p.pos = p.pos + 1
	int end = p.pos
	while (end > start && p.doc.source[end - 1] == 32): end = end - 1
	return str_copy_range(p.doc.source, start, end)

void mm_outline_body(mm_parser* p):
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
		if (mm_peek(p) == 13 || mm_peek(p) == 10): continue
		if (mm_match(p, c"%%")):
			if (mm_peek(p) == '{'): mm_error(p.doc, p.pos, c"configuration directive unsupported")
			char* comment = mm_line_text(p)
			free(comment)
			continue
		int depth = 0
		while (depth < indents.length && indent > indents[depth]): depth = depth + 1
		if (depth < indents.length && indents[depth] != indent): mm_error(p.doc, p.pos, c"inconsistent outline indentation")
		if (depth >= 64): mm_error(p.doc, p.pos, c"outline nesting limit exceeded")
		char* text = mm_line_text(p)
		if (index_of(text, c":::") >= 0 || index_of(text, c"icon(") >= 0 || index_of(text, c"├") >= 0 || index_of(text, c"└") >= 0 || index_of(text, c"│") >= 0): mm_error(p.doc, p.pos, c"outline annotations and tree command prefixes are not yet supported")
		if (text[0] == '"'):
			int size = strlen(text)
			if (size < 2 || text[size - 1] != '"'): mm_error(p.doc, p.pos, c"unterminated outline label")
			else:
				char* label = str_copy_range(text, 1, size - 1)
				free(text)
				text = label
		string_builder* id = string_from(c"@outline:")
		string_append_int(id, p.doc.nodes.length)
		int index = mm_add_node(p.doc, id.data, p.pos)
		string_free(id)
		if (index < 0):
			free(text)
			break
		mm_node* n = p.doc.nodes[index]
		free(n.label)
		n.label = text
		if (text[0] == 0): mm_error(p.doc, p.pos, c"empty outline label")
		if (depth > 0): n.parent = parents[depth - 1]
		if (depth == indents.length):
			indents.push(indent)
			parents.push(index)
		else:
			while (indents.length > depth + 1): indents.pop()
			while (parents.length > depth + 1): parents.pop()
			parents[depth] = index
		if (p.doc.kind == MM_ISHIKAWA && index == 0): indents[0] = -1
	__w_list_free(cast(__w_list*, indents))
	__w_list_free(cast(__w_list*, parents))
	if (p.doc.nodes.length == 0): mm_error(p.doc, p.pos, c"expected outline content")

void mm_cynefin_body(mm_parser* p):
	list[char*] names = list[char*]{c"complex", c"complicated", c"chaotic", c"clear", c"confusion"}
	for char* name in names: mm_add_node(p.doc, name, p.pos)
	__w_list_free(cast(__w_list*, names))
	int domain = -1
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_peek(p) == '"'):
			char* text = mm_quoted(p)
			if (domain < 0): mm_error(p.doc, p.pos, c"Cynefin item needs a domain")
			else:
				mm_node* n = p.doc.nodes[domain]
				mm_graph_member(p, n, c"item", text)
			free(text)
		else:
			char* word = mm_identifier(p)
			if (strcmp(word, c"title") == 0):
				free(p.doc.title)
				p.doc.title = mm_line_text(p)
			else:
				int from = mm_find_node(p.doc, word)
				if (from < 0): mm_error(p.doc, p.pos, c"unknown Cynefin domain")
				mm_space(p)
				if (mm_match(p, c"-->")):
					char* target = mm_identifier(p)
					int to = mm_find_node(p.doc, target)
					free(target)
					if (to < 0): mm_error(p.doc, p.pos, c"unknown transition domain")
					mm_space(p)
					char* label = strclone(c"")
					if (mm_match(p, c":")):
						mm_space(p)
						free(label)
						if (mm_peek(p) != '"'): mm_error(p.doc, p.pos, c"transition label must be quoted")
						label = mm_quoted(p)
					if (p.doc.edges.length >= MM_MAX_ITEMS): mm_error(p.doc, p.pos, c"transition limit exceeded")
					if (p.doc.error == 0):
						mm_edge* e = new mm_edge()
						e.from_node = from
						e.to_node = to
						e.label = strclone(label)
						e.arrow = 1
						p.doc.edges.push(e)
					free(label)
				else: domain = from
			free(word)
		if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported Cynefin syntax")
		mm_separators(p)

# Decimal normalized coordinates represented in thousandths, no libc/locale.
int mm_unit_value(mm_parser* p):
	mm_space(p)
	int whole = mm_peek(p) - '0'
	if (whole != 0 && whole != 1):
		mm_error(p.doc, p.pos, c"expected coordinate between zero and one")
		return 0
	p.pos = p.pos + 1
	int value = whole * 1000
	if (mm_match(p, c".")):
		int scale = 100
		int digits = 0
		while (isdigit(mm_peek(p))):
			int digit = mm_peek(p) - '0'
			if (whole == 1 && digit != 0): mm_error(p.doc, p.pos, c"coordinate exceeds one")
			value = value + digit * scale
			scale = scale / 10
			digits = digits + 1
			p.pos = p.pos + 1
		if (digits == 0): mm_error(p.doc, p.pos, c"expected decimal digits")
	if (isdigit(mm_peek(p))): mm_error(p.doc, p.pos, c"coordinate exceeds one")
	return value

char* mm_wardley_name(mm_parser* p):
	mm_space(p)
	if (mm_peek(p) == '"'): return mm_quoted(p)
	int start = p.pos
	while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13 && mm_peek(p) != '['):
		if (p.pos + 1 < p.doc.length && p.doc.source[p.pos] == '-' && (p.doc.source[p.pos + 1] == '>' || p.doc.source[p.pos + 1] == '-')): break
		p.pos = p.pos + 1
	int end = p.pos
	while (end > start && p.doc.source[end - 1] == 32): end = end - 1
	if (start == end): mm_error(p.doc, p.pos, c"expected component name")
	return str_copy_range(p.doc.source, start, end)

void mm_wardley_body(mm_parser* p):
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_keyword(p, c"title")):
			free(p.doc.title)
			p.doc.title = mm_line_text(p)
		else:
			int anchor = mm_keyword(p, c"anchor")
			int component = anchor || mm_keyword(p, c"component")
			if (component):
				char* name = mm_wardley_name(p)
				int index = mm_add_node(p.doc, name, p.pos)
				free(name)
				if (index < 0): return
				mm_node* n = p.doc.nodes[index]
				if (n.declared): mm_error(p.doc, p.pos, c"duplicate Wardley component")
				n.declared = 1
				n.shape = anchor
				mm_space(p)
				if (mm_match(p, c"[") == 0): mm_error(p.doc, p.pos, c"expected visibility and evolution coordinates")
				n.value_y = mm_unit_value(p)
				mm_space(p)
				if (mm_match(p, c",") == 0): mm_error(p.doc, p.pos, c"expected coordinate comma")
				n.value_x = mm_unit_value(p)
				mm_space(p)
				if (mm_match(p, c"]") == 0): mm_error(p.doc, p.pos, c"expected coordinate closing bracket")
			else:
				char* name = mm_wardley_name(p)
				int from = mm_add_node(p.doc, name, p.pos)
				free(name)
				mm_space(p)
				if (mm_match(p, c"-->") == 0 && mm_match(p, c"->") == 0): mm_error(p.doc, p.pos, c"expected Wardley dependency arrow")
				name = mm_wardley_name(p)
				int to = mm_add_node(p.doc, name, p.pos)
				free(name)
				if (p.doc.edges.length >= MM_MAX_ITEMS): mm_error(p.doc, p.pos, c"dependency limit exceeded")
				if (p.doc.error == 0):
					mm_edge* e = new mm_edge()
					e.from_node = from
					e.to_node = to
					e.label = strclone(c"")
					p.doc.edges.push(e)
		if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported Wardley decorator, flow or syntax")
		mm_separators(p)
	for mm_node* n in p.doc.nodes:
		if (n.declared == 0): mm_error(p.doc, p.pos, c"dependency references undeclared component")
