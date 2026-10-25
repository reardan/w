# Native outline, cause/effect and decision-framework models.
import libs.extras.mermaid.graph_families

char* mm_line_text(mm_parser* p):
	mm_space(p)
	int start = p.pos
	while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13): p.pos = p.pos + 1
	int end = p.pos
	while (end > start && p.doc.source[end - 1] == 32): end = end - 1
	return str_copy_range(p.doc.source, start, end)

# Box-drawing bytes from `tree` output: 1 = vertical, 2 = branch/corner, 3 = horizontal.
int mm_tree_glyph(mm_parser* p):
	if (mm_peek(p) != 0xE2 || p.pos + 2 >= p.doc.length || (p.doc.source[p.pos + 1] & 255) != 0x94): return 0
	int last = p.doc.source[p.pos + 2] & 255
	if (last == 0x82): return 1
	if (last == 0x9C || last == 0x94): return 2
	if (last == 0x80): return 3
	return 0

# Consume a `tree` command prefix (`│   ├── `, NBSP-padded or not). The branch
# glyph's column plus four becomes the line's indentation, matching the
# indentation `tree` uses for the next level. Returns -1 for a bare `│` line.
int mm_tree_prefix(mm_parser* p, int indent):
	int column = indent
	while (p.doc.error == 0):
		int glyph = mm_tree_glyph(p)
		if (glyph == 2):
			int result = column + 4
			p.pos = p.pos + 3
			while (mm_tree_glyph(p) == 3): p.pos = p.pos + 3
			if (mm_peek(p) == 0xC2 && p.pos + 1 < p.doc.length && (p.doc.source[p.pos + 1] & 255) == 0xA0): p.pos = p.pos + 2
			return result
		if (glyph == 1): p.pos = p.pos + 3
		else if (mm_peek(p) == 0xC2 && p.pos + 1 < p.doc.length && (p.doc.source[p.pos + 1] & 255) == 0xA0): p.pos = p.pos + 2
		else if (mm_peek(p) == 32): p.pos = p.pos + 1
		else if (mm_peek(p) == 9):
			p.pos = p.pos + 1
			column = column + 3
		else if (mm_peek(p) == 0 || mm_peek(p) == 10 || mm_peek(p) == 13): return -1
		else: mm_error(p.doc, p.pos, c"tree command prefix requires a branch marker")
		column = column + 1
	return -1

# Comma-joined class names from "name name ..." at text[at]; diagnoses bad names.
char* mm_tree_classes(mm_parser* p, char* text, int at):
	string_builder* joined = string_new()
	int length = strlen(text)
	while (at < length):
		while (at < length && (text[at] == 32 || text[at] == 9)): at = at + 1
		int start = at
		while (at < length && text[at] != 32 && text[at] != 9): at = at + 1
		if (at == start): break
		char* name = str_copy_range(text, start, at)
		if (mm_style_name(name) == 0): mm_error(p.doc, p.pos, c"invalid TreeView class name")
		if (joined.length + strlen(name) > 4096): mm_error(p.doc, p.pos, c"node class assignment limit exceeded")
		if (joined.length != 0): string_append_char(joined, ',')
		string_append(joined, name)
		free(name)
	if (joined.length == 0): mm_error(p.doc, p.pos, c"expected TreeView class names")
	char* result = strclone(joined.data)
	string_free(joined)
	return result

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
			if (mm_peek(p) == '{'): mm_skip_directive(p)
			char* comment = mm_line_text(p)
			free(comment)
			continue
		if (mm_metadata(p)):
			# Only consume horizontal whitespace here. The next loop iteration
			# counts the next physical line's indentation before assigning parents.
			mm_space(p)
			if (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13): mm_error(p.doc, p.pos, c"expected end of accessibility metadata line")
			continue
		if (p.doc.kind == MM_TREEVIEW && mm_tree_glyph(p) != 0):
			indent = mm_tree_prefix(p, indent)
			if (indent < 0): continue
		int depth = 0
		while (depth < indents.length && indent > indents[depth]): depth = depth + 1
		if (depth < indents.length && indents[depth] != indent): mm_error(p.doc, p.pos, c"inconsistent outline indentation")
		if (depth >= 64): mm_error(p.doc, p.pos, c"outline nesting limit exceeded")
		char* text = mm_line_text(p)
		char* description = strclone(c"")
		char* classes = 0
		if (p.doc.kind == MM_TREEVIEW):
			int marker = index_of(text, c"##")
			if (marker >= 0):
				free(description)
				description = mm_style_trim(text, marker + 2, strlen(text))
				if (description[0] == 0): mm_error(p.doc, p.pos, c"empty TreeView description")
				char* label = mm_style_trim(text, 0, marker)
				free(text)
				text = label
			if (index_of(text, c"icon(") >= 0): mm_error(p.doc, p.pos, c"TreeView icons are not yet supported")
			# `:::name` (space separated, after the label) assigns CSS classes.
			int styled = index_of(text, c":::")
			if (styled >= 0):
				classes = mm_tree_classes(p, text, styled + 3)
				char* label = mm_style_trim(text, 0, styled)
				free(text)
				text = label
		else if (index_of(text, c":::") >= 0 || index_of(text, c" ##") >= 0 || index_of(text, c"icon(") >= 0 || index_of(text, c"├") >= 0 || index_of(text, c"└") >= 0 || index_of(text, c"│") >= 0): mm_error(p.doc, p.pos, c"outline annotations and tree command prefixes are not yet supported")
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
			free(description)
			if (classes != 0): free(classes)
			break
		mm_node* n = p.doc.nodes[index]
		free(n.label)
		n.label = text
		free(n.annotation)
		n.annotation = description
		if (classes != 0):
			free(n.style_classes)
			n.style_classes = classes
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
		if (mm_metadata(p)):
			mm_separators(p)
			continue
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
	while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13 && mm_peek(p) != '[' && mm_peek(p) != '{'):
		if (p.pos + 1 < p.doc.length && p.doc.source[p.pos] == '-' && (p.doc.source[p.pos + 1] == '>' || p.doc.source[p.pos + 1] == '-')): break
		p.pos = p.pos + 1
	int end = p.pos
	while (end > start && p.doc.source[end - 1] == 32): end = end - 1
	if (start == end): mm_error(p.doc, p.pos, c"expected component name")
	return str_copy_range(p.doc.source, start, end)

# Wardley component modifiers are owned key/value properties on the node:
# strategy (build/buy/outsource), inertia, label "dx dy", evolve (thousandths)
# and pipeline "low high" (thousandths; empty until resolved from children).
char* mm_wardley_get(mm_node* n, char* key):
	for mm_property* property in n.metadata:
		if (strcmp(property.key, key) == 0): return property.value
	return 0

void mm_wardley_set(mm_parser* p, mm_node* n, char* key, char* value):
	if (mm_wardley_get(n, key) != 0):
		mm_error(p.doc, p.pos, c"duplicate Wardley component modifier")
		return
	n.metadata.push(new mm_property(strclone(key), strclone(value), MM_VALUE_STRING))

void mm_wardley_coordinates(mm_parser* p, mm_node* n):
	mm_space(p)
	if (mm_match(p, c"[") == 0): mm_error(p.doc, p.pos, c"expected visibility and evolution coordinates")
	n.value_y = mm_unit_value(p)
	mm_space(p)
	if (mm_match(p, c",") == 0): mm_error(p.doc, p.pos, c"expected coordinate comma")
	n.value_x = mm_unit_value(p)
	mm_space(p)
	if (mm_match(p, c"]") == 0): mm_error(p.doc, p.pos, c"expected coordinate closing bracket")

int mm_wardley_offset(mm_parser* p):
	mm_space(p)
	int negative = mm_match(p, c"-")
	int value = 0
	int digits = 0
	while (isdigit(mm_peek(p))):
		if (value <= 9999): value = value * 10 + mm_peek(p) - '0'
		p.pos = p.pos + 1
		digits = digits + 1
	if (digits == 0 || value > 999): mm_error(p.doc, p.pos, c"label offset must be an integer from -999 to 999")
	if (negative): value = 0 - value
	return value

void mm_wardley_modifiers(mm_parser* p, mm_node* n):
	while (mm_end(p) == 0 && mm_peek(p) != '{' && p.doc.error == 0):
		if (mm_keyword(p, c"label")):
			mm_space(p)
			if (mm_match(p, c"[") == 0): mm_error(p.doc, p.pos, c"expected label offset bracket")
			string_builder* offset = string_new()
			string_append_int(offset, mm_wardley_offset(p))
			mm_space(p)
			if (mm_match(p, c",") == 0): mm_error(p.doc, p.pos, c"expected coordinate comma")
			string_append_char(offset, ' ')
			string_append_int(offset, mm_wardley_offset(p))
			mm_space(p)
			if (mm_match(p, c"]") == 0): mm_error(p.doc, p.pos, c"expected coordinate closing bracket")
			mm_wardley_set(p, n, c"label", offset.data)
			string_free(offset)
		else if (mm_keyword(p, c"inertia")): mm_wardley_set(p, n, c"inertia", c"1")
		else if (mm_match(p, c"(")):
			int at = p.pos
			char* word = mm_identifier(p)
			mm_space(p)
			if (mm_match(p, c")") == 0): mm_error(p.doc, p.pos, c"expected decorator closing parenthesis")
			if (mm_in_words(word, c"|build|buy|outsource|")): mm_wardley_set(p, n, c"strategy", word)
			else if (strcmp(word, c"inertia") == 0): mm_wardley_set(p, n, c"inertia", c"1")
			else: mm_error(p.doc, at, c"unsupported Wardley decorator; supported: build, buy, outsource, inertia")
			free(word)
		else: return
		mm_space(p)

int mm_wardley_declare(mm_parser* p, int shape):
	char* name = mm_wardley_name(p)
	int index = mm_add_node(p.doc, name, p.pos)
	free(name)
	if (index < 0): return -1
	mm_node* n = p.doc.nodes[index]
	if (n.declared): mm_error(p.doc, p.pos, c"duplicate Wardley component")
	n.declared = 1
	n.shape = shape
	return index

# `evolution A -> B -> C -> D` replaces the four default stage labels. The
# labels live in document notes (node -1, side = stage index).
void mm_wardley_stages(mm_parser* p):
	if (p.doc.notes.length != 0): mm_error(p.doc, p.pos, c"duplicate Wardley evolution axis")
	char* text = mm_line_text(p)
	int start = 0
	int count = 0
	int length = strlen(text)
	for i in range(length + 1):
		if (i == length || (text[i] == '-' && text[i + 1] == '>')):
			char* label = mm_style_trim(text, start, i)
			if (label[0] == 0): mm_error(p.doc, p.pos, c"empty Wardley evolution stage")
			if (count < 4 && p.doc.error == 0):
				mm_note* note = new mm_note()
				note.node = -1
				note.side = count
				note.text = label
				p.doc.notes.push(note)
			else: free(label)
			count = count + 1
			start = i + 2
	if (count != 4): mm_error(p.doc, p.pos, c"Wardley evolution axis requires four stages")
	free(text)

void mm_wardley_evolve(mm_parser* p):
	mm_space(p)
	char* name
	if (mm_peek(p) == '"'): name = mm_quoted(p)
	else:
		int start = p.pos
		int end = start
		while (end < p.doc.length && p.doc.source[end] != 10 && p.doc.source[end] != 13): end = end + 1
		while (end > start && (p.doc.source[end - 1] == 32 || p.doc.source[end - 1] == 9)): end = end - 1
		int split = end
		while (split > start && p.doc.source[split - 1] != 32 && p.doc.source[split - 1] != 9): split = split - 1
		name = mm_style_trim(p.doc.source, start, split)
		p.pos = split
	if (name[0] == 0): mm_error(p.doc, p.pos, c"expected component name")
	if (index_of(name, c"->") >= 0): mm_error(p.doc, p.pos, c"Wardley evolve renaming is not yet supported")
	int value = mm_unit_value(p)
	int index = mm_add_node(p.doc, name, p.pos)
	free(name)
	if (index < 0 || p.doc.error != 0): return
	string_builder* text = string_new()
	string_append_int(text, value)
	mm_wardley_set(p, p.doc.nodes[index], c"evolve", text.data)
	string_free(text)

void mm_wardley_note(mm_parser* p):
	mm_space(p)
	char* text
	if (mm_peek(p) == '"'): text = mm_quoted(p)
	else:
		int start = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 13 && mm_peek(p) != '['): p.pos = p.pos + 1
		text = mm_style_trim(p.doc.source, start, p.pos)
	if (text[0] == 0): mm_error(p.doc, p.pos, c"empty Wardley note")
	# A newline never occurs in a parsed name, so notes cannot be referenced.
	string_builder* id = string_from(c"\nnote:")
	string_append_int(id, p.doc.nodes.length)
	int index = mm_add_node(p.doc, id.data, p.pos)
	string_free(id)
	if (index < 0):
		free(text)
		return
	mm_node* n = p.doc.nodes[index]
	n.declared = 1
	n.shape = 3
	free(n.label)
	n.label = text
	mm_wardley_coordinates(p, n)

# `pipeline Name [low, high]`, optionally followed (on the same or the next
# line) by a `{ component Child [evolution] ... }` block of sub-components.
void mm_wardley_pipeline(mm_parser* p):
	char* name = mm_wardley_name(p)
	int index = mm_add_node(p.doc, name, p.pos)
	free(name)
	if (index < 0): return
	mm_space(p)
	string_builder* range = string_new()
	if (mm_match(p, c"[")):
		int low = mm_unit_value(p)
		mm_space(p)
		if (mm_match(p, c",") == 0): mm_error(p.doc, p.pos, c"expected coordinate comma")
		int high = mm_unit_value(p)
		mm_space(p)
		if (mm_match(p, c"]") == 0): mm_error(p.doc, p.pos, c"expected coordinate closing bracket")
		if (high <= low): mm_error(p.doc, p.pos, c"Wardley pipeline range must increase")
		string_append_int(range, low)
		string_append_char(range, ' ')
		string_append_int(range, high)
	mm_wardley_set(p, p.doc.nodes[index], c"pipeline", range.data)
	int explicit = range.length != 0
	string_free(range)
	if (p.doc.error != 0): return
	int save = p.pos
	if (mm_end(p)): mm_separators(p)
	if (mm_match(p, c"{") == 0):
		p.pos = save
		if (explicit == 0): mm_error(p.doc, p.pos, c"Wardley pipeline requires a range or a component block")
		return
	int children = 0
	mm_separators(p)
	while (mm_peek(p) != '}' && p.doc.error == 0):
		if (mm_peek(p) == 0):
			mm_error(p.doc, p.pos, c"unterminated Wardley pipeline block")
			return
		if (mm_keyword(p, c"component") == 0):
			mm_error(p.doc, p.pos, c"expected pipeline component")
			return
		int child = mm_wardley_declare(p, 2)
		if (child < 0): return
		mm_node* n = p.doc.nodes[child]
		n.parent = index
		mm_space(p)
		if (mm_match(p, c"[") == 0): mm_error(p.doc, p.pos, c"expected pipeline component evolution")
		n.value_x = mm_unit_value(p)
		mm_space(p)
		if (mm_match(p, c"]") == 0): mm_error(p.doc, p.pos, c"expected coordinate closing bracket")
		mm_wardley_modifiers(p, n)
		if (mm_end(p) == 0 && mm_peek(p) != '}'): mm_error(p.doc, p.pos, c"unsupported Wardley decorator, flow or syntax")
		children = children + 1
		mm_separators(p)
	if (children == 0): mm_error(p.doc, p.pos, c"Wardley pipeline block requires components")
	mm_match(p, c"}")

# Pipelines resolve after all declarations so components may be declared later.
void mm_wardley_resolve(mm_parser* p):
	for i in range(p.doc.nodes.length):
		mm_node* n = p.doc.nodes[i]
		mm_property* pipeline = 0
		for mm_property* property in n.metadata:
			if (strcmp(property.key, c"pipeline") == 0): pipeline = property
		if (pipeline == 0): continue
		if (n.shape != 0 && n.shape != 1):
			mm_error(p.doc, p.pos, c"Wardley pipelines must belong to a top-level component")
			return
		int low = 1001
		int high = -1
		for mm_node* child in p.doc.nodes:
			if (child.parent != i): continue
			child.value_y = n.value_y
			if (child.value_x < low): low = child.value_x
			if (child.value_x > high): high = child.value_x
		if (pipeline.value[0] == 0):
			string_builder* range = string_new()
			string_append_int(range, low)
			string_append_char(range, ' ')
			string_append_int(range, high)
			free(pipeline.value)
			pipeline.value = strclone(range.data)
			string_free(range)
		else:
			int split = index_of(pipeline.value, c" ")
			if (high >= 0 && (low < atoi(pipeline.value) || high > atoi(pipeline.value + split + 1))): mm_error(p.doc, p.pos, c"Wardley pipeline component outside pipeline range")

void mm_wardley_body(mm_parser* p):
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_metadata(p)):
			mm_separators(p)
			continue
		if (mm_keyword(p, c"title")):
			free(p.doc.title)
			p.doc.title = mm_line_text(p)
		else if (mm_keyword(p, c"evolution")): mm_wardley_stages(p)
		else if (mm_keyword(p, c"evolve")): mm_wardley_evolve(p)
		else if (mm_keyword(p, c"note")): mm_wardley_note(p)
		else if (mm_keyword(p, c"pipeline")): mm_wardley_pipeline(p)
		else:
			int anchor = mm_keyword(p, c"anchor")
			int component = anchor || mm_keyword(p, c"component")
			if (component):
				int index = mm_wardley_declare(p, anchor)
				if (index < 0): return
				mm_node* n = p.doc.nodes[index]
				mm_wardley_coordinates(p, n)
				mm_wardley_modifiers(p, n)
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
	if (p.doc.error == 0): mm_wardley_resolve(p)
