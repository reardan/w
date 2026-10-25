# UML use case diagrams (`usecase-beta`): actors and their variants, oval and
# rectangular use cases, one-level system boundaries, typed metadata,
# stereotypes, notes, JSON tables, rich labels, explicit edge IDs and the
# association, include/extend and generalization operators.
#
# Node shapes: 10 actor, 11 ellipse use case, 0 rectangular use case,
# 14 note, 15 JSON table; boundaries are groups. Semantic metadata (type,
# icon, business, stereotype) lives in mm_node.metadata.
import libs.extras.mermaid.architecture
import libs.extras.mermaid.style
import libs.extras.mermaid.style_render
import libs.extras.mermaid.text
import lib.utf8

const int MM_UC_ACTOR = 10
const int MM_UC_ELLIPSE = 11
const int MM_UC_NOTE = 14
const int MM_UC_JSON = 15
# Association endpoint markers beyond MM_ARROW / MM_TRIANGLE.
const int MM_UC_CIRCLE = 8
const int MM_UC_CROSS = 9
const int MM_UC_JSON_ROWS = 512

# Deferred `class` assignments to explicit edge IDs, resolved once every
# classDef has been read.
struct mm_uc_context:
	list[int] edges
	list[char*] classes
	int notes

char* mm_uc_get(mm_node* n, char* key):
	for mm_property* property in n.metadata:
		if (strcmp(property.key, key) == 0): return property.value
	return 0

void mm_uc_set(mm_node* n, char* key, char* value):
	for mm_property* property in n.metadata:
		if (strcmp(property.key, key) == 0):
			free(property.value)
			property.value = strclone(value)
			return
	n.metadata.push(new mm_property(strclone(key), strclone(value)))

int mm_uc_true(mm_node* n, char* key):
	char* value = mm_uc_get(n, key)
	return value != 0 && strcmp(value, c"true") == 0

# Mermaid entity codes: #quot; #amp; #lt; #gt; #apos; #nbsp; and #NNN;.
char* mm_uc_entities(char* text):
	string_builder* out = string_new()
	int i = 0
	while (text[i] != 0):
		int done = 0
		if (text[i] == '#'):
			int j = i + 1
			while (j < i + 10 && text[j] != 0 && text[j] != ';' && (isalnum(text[j]) != 0)): j = j + 1
			if (text[j] == ';' && j > i + 1):
				char* name = str_copy_range(text, i + 1, j)
				int code = -1
				if (strcmp(name, c"quot") == 0): code = '"'
				else if (strcmp(name, c"amp") == 0): code = '&'
				else if (strcmp(name, c"lt") == 0): code = '<'
				else if (strcmp(name, c"gt") == 0): code = '>'
				else if (strcmp(name, c"apos") == 0): code = 39
				else if (strcmp(name, c"nbsp") == 0): code = 160
				else if (isdigit(name[0])):
					code = 0
					for k in range(strlen(name)):
						if (isdigit(name[k]) == 0 || code > 1114111): code = -1
						if (code >= 0): code = code * 10 + name[k] - '0'
					if (code > 1114111 || code < 1 || (code >= 0xd800 && code <= 0xdfff)): code = -1
				free(name)
				if (code > 0):
					char* bytes = cast(char*, malloc(8))
					int length = utf8_encode(bytes, code)
					string_append_bytes(out, bytes, length)
					free(bytes)
					i = j + 1
					done = 1
		if (done == 0):
			string_append_char(out, text[i])
			i = i + 1
	char* result = strclone(out.data)
	string_free(out)
	return result

char* mm_uc_label(mm_parser* p, int close):
	char* raw = mm_until(p, close)
	char* label = mm_uc_entities(raw)
	free(raw)
	return label

# Deterministic identifier of a quoted declaration: non-word bytes become _.
char* mm_uc_quoted_id(char* text):
	char* id = strclone(text)
	for i in range(strlen(id)):
		int c = id[i] & 255
		if (isalnum(c) == 0 && c != '_'): id[i] = '_'
	return id

# `@{ key: value, ... }` typed metadata. Values are bare words or strings.
void mm_uc_metadata(mm_parser* p, mm_node* n):
	mm_separators(p)
	int count = 0
	while (p.doc.error == 0):
		mm_separators(p)
		if (mm_match(p, c"}")): return
		if (mm_peek(p) == 0):
			mm_error(p.doc, p.pos, c"unterminated use-case metadata")
			return
		if (count >= 16):
			mm_error(p.doc, p.pos, c"use-case metadata limit exceeded")
			return
		char* key = mm_identifier(p)
		mm_space(p)
		if (mm_match(p, c":") == 0): mm_error(p.doc, p.pos, c"expected use-case metadata colon")
		mm_space(p)
		char* value
		if (mm_peek(p) == '"'): value = mm_quoted(p)
		else:
			int start = p.pos
			while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != ',' && mm_peek(p) != '}'): p.pos = p.pos + 1
			value = mm_style_trim(p.doc.source, start, p.pos)
		if (p.doc.error == 0 && n != 0): mm_uc_set(n, key, value)
		free(key)
		free(value)
		count = count + 1
		mm_space(p)
		mm_match(p, c",")

# Edge metadata statement: animate: true|false, animation: fast|slow.
# Animated edges are kept as e.arrow (1 slow, 2 default, 3 fast).
void mm_uc_edge_metadata(mm_parser* p, mm_edge* e):
	mm_node* scratch = new mm_node()
	scratch.metadata = new list[mm_property*]
	mm_uc_metadata(p, scratch)
	for mm_property* property in scratch.metadata:
		if (strcmp(property.key, c"animate") == 0):
			if (strcmp(property.value, c"true") == 0): e.arrow = 2
			else if (strcmp(property.value, c"false") == 0): e.arrow = 0
			else: mm_error(p.doc, p.pos, c"animate must be true or false")
		else if (strcmp(property.key, c"animation") == 0):
			if (strcmp(property.value, c"fast") == 0): e.arrow = 3
			else if (strcmp(property.value, c"slow") == 0): e.arrow = 1
			else: mm_error(p.doc, p.pos, c"animation must be fast or slow")
		else: mm_error(p.doc, p.pos, c"unsupported edge metadata; supported: animate, animation")
		free(property.key)
		free(property.value)
		free(property)
	__w_list_free(cast(__w_list*, scratch.metadata))
	free(scratch)

mm_edge* mm_uc_find_edge(mm_document* d, char* id):
	for mm_edge* e in d.edges:
		if (e.id != 0 && strcmp(e.id, id) == 0): return e
	return 0

# Optional `<<stereotype>>` and `:::classes` suffixes, in that order.
void mm_uc_suffixes(mm_parser* p, mm_node* n):
	mm_space(p)
	if (mm_match(p, c"<<")):
		int start = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_match(p, c">>") == 0): p.pos = p.pos + 1
		if (p.doc.source[p.pos - 1] != '>' || p.pos - 2 <= start): mm_error(p.doc, start, c"expected nonempty <<stereotype>>")
		else:
			char* text = mm_style_trim(p.doc.source, start, p.pos - 2)
			mm_uc_set(n, c"stereotype", text)
			free(text)
		mm_space(p)
	if (mm_match(p, c":::")): mm_style_inline(p, n)

# Endpoint or declaration: id or "quoted label", optional (label)/[label],
# then (for declarations) @{metadata}, <<stereotype>> and :::classes.
int mm_usecase_node(mm_parser* p, int parent, int declare):
	mm_space(p)
	int index = -1
	char* quoted = 0
	if (mm_peek(p) == '"'):
		quoted = mm_quoted(p)
		char* id = mm_uc_quoted_id(quoted)
		index = mm_add_node(p.doc, id, p.pos)
		free(id)
	else: index = mm_system_node(p)
	if (index < 0):
		if (quoted != 0): free(quoted)
		return -1
	mm_node* n = p.doc.nodes[index]
	if (n.declared == 0 && n.group == 0 && n.shape != MM_UC_ACTOR):
		n.shape = MM_UC_ELLIPSE
		n.parent = parent
	if (declare):
		if (n.declared && n.parent != parent): mm_error(p.doc, p.pos, c"use case already belongs to another boundary")
		n.parent = parent
		n.declared = 1
	if (quoted != 0):
		free(n.label)
		n.label = mm_uc_entities(quoted)
		free(quoted)
	int close = 0
	if (mm_match(p, c"(")): close = ')'
	else if (mm_match(p, c"[")):
		close = ']'
		n.shape = 0
	if (close):
		free(n.label)
		n.label = mm_uc_label(p, close)
	return index

void mm_uc_declaration_suffixes(mm_parser* p, mm_node* n):
	if (mm_match(p, c"@{")): mm_uc_metadata(p, n)
	mm_uc_suffixes(p, n)

int mm_uc_dashes(mm_parser* p):
	int n = 0
	while (p.pos + n < p.doc.length && p.doc.source[p.pos + n] == '-'): n = n + 1
	return n

int mm_uc_marker_char(mm_parser* p, int at):
	if (at >= p.doc.length): return 0
	int c = p.doc.source[at] & 255
	if (c != 'o' && c != 'x'): return 0
	if (at + 1 < p.doc.length && mm_id_char(p.doc.source[at + 1] & 255)): return 0
	return c

# Parses one relationship operator into e; 0 when none is present.
int mm_uc_operator(mm_parser* p, mm_edge* e):
	int start = p.pos
	if (mm_match(p, c"..>")):
		e.dashed = 1
		e.right_marker = MM_ARROW
		mm_space(p)
		if (mm_match(p, c":") == 0): mm_error(p.doc, p.pos, c"expected include or extend relationship colon")
		free(e.label)
		e.label = mm_identifier(p)
		if (mm_in_words(e.label, c"|include|extend|") == 0): mm_error(p.doc, p.pos, c"expected include or extend")
		return 1
	int lead = mm_peek(p)
	if ((lead == 'o' || lead == 'x') && p.pos + 2 < p.doc.length && p.doc.source[p.pos + 1] == '-' && p.doc.source[p.pos + 2] == '-'):
		p.pos = p.pos + 1
		if (mm_uc_dashes(p) != 2):
			mm_error(p.doc, start, c"circle and cross associations have a fixed length")
			return 1
		p.pos = p.pos + 2
		e.left_marker = MM_UC_CIRCLE
		if (lead == 'x'): e.left_marker = MM_UC_CROSS
		return 1
	if (lead == '<'):
		p.pos = p.pos + 1
		int n = mm_uc_dashes(p)
		if (n < 2):
			p.pos = start
			return 0
		p.pos = p.pos + n
		e.left_marker = MM_ARROW
		e.min_length = n - 1
		return 1
	if (lead != '-'): return 0
	int n = mm_uc_dashes(p)
	if (n < 2): return 0
	p.pos = p.pos + n
	if (mm_match(p, c"|>")):
		if (n != 2): mm_error(p.doc, start, c"generalization has a fixed length")
		e.right_marker = MM_TRIANGLE
		return 1
	if (mm_match(p, c">")):
		e.right_marker = MM_ARROW
		e.min_length = n - 1
		return 1
	int marker = mm_uc_marker_char(p, p.pos)
	if (marker):
		if (n != 2): mm_error(p.doc, start, c"circle and cross associations have a fixed length")
		p.pos = p.pos + 1
		e.right_marker = MM_UC_CIRCLE
		if (marker == 'x'): e.right_marker = MM_UC_CROSS
		return 1
	# Markerless, or `-- label -->` with the label between two dash runs.
	int save = p.pos
	mm_space(p)
	char* label = 0
	if (mm_peek(p) == '"'):
		char* raw = mm_quoted(p)
		label = mm_uc_entities(raw)
		free(raw)
		mm_space(p)
		if (mm_uc_dashes(p) < 2):
			mm_error(p.doc, p.pos, c"expected association after its label")
			free(label)
			return 1
	else:
		int scan = p.pos
		int found = -1
		while (scan + 1 < p.doc.length && p.doc.source[scan] != 10 && found < 0):
			if (p.doc.source[scan] == '-' && p.doc.source[scan + 1] == '-'): found = scan
			scan = scan + 1
		if (found < 0):
			p.pos = save
			e.min_length = n - 1
			return 1
		label = mm_style_trim(p.doc.source, p.pos, found)
		char* decoded = mm_uc_entities(label)
		free(label)
		label = decoded
		p.pos = found
	if (n != 2): mm_error(p.doc, start, c"put the extra dashes of a labelled association after its label")
	if (label[0] == 0): mm_error(p.doc, start, c"expected association label")
	free(e.label)
	e.label = label
	int m = mm_uc_dashes(p)
	p.pos = p.pos + m
	e.min_length = m - 1
	if (mm_match(p, c">")): e.right_marker = MM_ARROW
	return 1

# Edge ID immediately before an operator: `id@-->`; returns owned id or 0.
char* mm_uc_edge_id(mm_parser* p):
	int start = p.pos
	while (mm_id_char(mm_peek(p))): p.pos = p.pos + 1
	if (p.pos > start && mm_peek(p) == '@' && p.pos + 1 < p.doc.length && p.doc.source[p.pos + 1] != '{'):
		char* id = str_copy_range(p.doc.source, start, p.pos)
		p.pos = p.pos + 1
		return id
	p.pos = start
	return 0

void mm_uc_relationship(mm_parser* p, int from, int scope):
	mm_space(p)
	mm_edge* e = new mm_edge()
	e.from_node = from
	e.label = strclone(c"")
	e.left_label = strclone(c"")
	e.right_label = strclone(c"")
	e.scope = -1
	e.id = mm_uc_edge_id(p)
	if (mm_uc_operator(p, e) == 0):
		if (e.id != 0): mm_error(p.doc, p.pos, c"expected relationship operator after edge ID")
		else: mm_error(p.doc, p.pos, c"unsupported use-case syntax")
	if (scope >= 0): mm_error(p.doc, p.pos, c"relationships belong outside system boundaries")
	if (p.doc.edges.length >= MM_MAX_ITEMS): mm_error(p.doc, p.pos, c"use-case edge limit exceeded")
	if (p.doc.error == 0): e.to_node = mm_usecase_node(p, -1, 0)
	if (p.doc.error != 0 || e.to_node < 0):
		if (e.id != 0): free(e.id)
		free(e.label)
		free(e.left_label)
		free(e.right_label)
		free(e)
		return
	p.doc.edges.push(e)

# Strict JSON object tables, flattened into path/value rows.
struct mm_json_value:
	int kind
	char* text
	list[char*] keys
	list[int] items

void mm_json_ws(mm_parser* p):
	while (mm_peek(p) == 32 || mm_peek(p) == 9 || mm_peek(p) == 10 || mm_peek(p) == 13): p.pos = p.pos + 1

int mm_json_hex(mm_parser* p):
	int value = 0
	for i in range(4):
		int digit = mm_style_hex(mm_peek(p))
		if (digit < 0):
			mm_error(p.doc, p.pos, c"invalid JSON \\u escape")
			return 0
		value = value * 16 + digit
		p.pos = p.pos + 1
	return value

char* mm_json_string(mm_parser* p):
	string_builder* out = string_new()
	p.pos = p.pos + 1
	while (p.doc.error == 0):
		int c = mm_peek(p)
		if (c == 0 || c == 10):
			mm_error(p.doc, p.pos, c"unterminated JSON string")
			break
		if (c < 32):
			mm_error(p.doc, p.pos, c"control character in JSON string")
			break
		p.pos = p.pos + 1
		if (c == '"'): break
		if (c != '\\'):
			string_append_char(out, c)
			continue
		int escape = mm_peek(p)
		p.pos = p.pos + 1
		if (escape == '"' || escape == '\\' || escape == '/'): string_append_char(out, escape)
		else if (escape == 'b'): string_append_char(out, 8)
		else if (escape == 'f'): string_append_char(out, 12)
		else if (escape == 'n'): string_append_char(out, 10)
		else if (escape == 'r'): string_append_char(out, 13)
		else if (escape == 't'): string_append_char(out, 9)
		else if (escape == 'u'):
			int code = mm_json_hex(p)
			if (code >= 0xd800 && code <= 0xdbff && mm_match(p, c"\\u")):
				int low = mm_json_hex(p)
				if (low >= 0xdc00 && low <= 0xdfff): code = 0x10000 + (code - 0xd800) * 1024 + (low - 0xdc00)
				else: code = 0xfffd
			else if (code >= 0xd800 && code <= 0xdfff): code = 0xfffd
			char* bytes = cast(char*, malloc(8))
			int length = utf8_encode(bytes, code)
			string_append_bytes(out, bytes, length)
			free(bytes)
		else: mm_error(p.doc, p.pos - 1, c"invalid JSON escape")
	char* result = strclone(out.data)
	string_free(out)
	return result

int mm_json_digits(mm_parser* p):
	int start = p.pos
	while (isdigit(mm_peek(p))): p.pos = p.pos + 1
	return p.pos - start

void mm_json_number(mm_parser* p):
	int start = p.pos
	mm_match(p, c"-")
	if (mm_match(p, c"0") == 0 && mm_json_digits(p) == 0): mm_error(p.doc, start, c"invalid JSON value")
	if (mm_match(p, c".") && mm_json_digits(p) == 0): mm_error(p.doc, start, c"invalid JSON number")
	if (mm_match(p, c"e") || mm_match(p, c"E")):
		if (mm_match(p, c"+") == 0): mm_match(p, c"-")
		if (mm_json_digits(p) == 0): mm_error(p.doc, start, c"invalid JSON number")

int mm_json_value_parse(mm_parser* p, list[mm_json_value*] pool, int depth):
	mm_json_ws(p)
	if (depth > 32 || pool.length >= MM_UC_JSON_ROWS * 4):
		mm_error(p.doc, p.pos, c"JSON table nesting or size limit exceeded")
		return -1
	mm_json_value* v = new mm_json_value()
	v.keys = new list[char*]
	v.items = new list[int]
	int index = pool.length
	pool.push(v)
	int start = p.pos
	int c = mm_peek(p)
	if (c == '{' || c == '['):
		v.kind = 0
		int close = '}'
		if (c == '['):
			v.kind = 1
			close = ']'
		p.pos = p.pos + 1
		mm_json_ws(p)
		if (mm_peek(p) == close):
			p.pos = p.pos + 1
			return index
		while (p.doc.error == 0):
			mm_json_ws(p)
			char* key = 0
			if (v.kind == 0):
				if (mm_peek(p) != '"'):
					mm_error(p.doc, p.pos, c"expected JSON property name")
					break
				key = mm_json_string(p)
				mm_json_ws(p)
				if (mm_match(p, c":") == 0): mm_error(p.doc, p.pos, c"expected JSON colon")
			int child = mm_json_value_parse(p, pool, depth + 1)
			if (p.doc.error != 0):
				if (key != 0): free(key)
				break
			int replaced = 0
			if (key != 0):
				# A repeated property keeps its first position; the last value wins.
				for i in range(v.keys.length):
					if (replaced == 0 && strcmp(v.keys[i], key) == 0):
						v.items[i] = child
						replaced = 1
				if (replaced): free(key)
				else: v.keys.push(key)
			if (replaced == 0): v.items.push(child)
			mm_json_ws(p)
			if (mm_match(p, c",")): continue
			if (mm_peek(p) == close):
				p.pos = p.pos + 1
				break
			mm_error(p.doc, p.pos, c"expected JSON comma or closing bracket")
		return index
	if (c == '"'):
		v.kind = 2
		v.text = mm_json_string(p)
		return index
	v.kind = 3
	if (mm_match(p, c"true") == 0 && mm_match(p, c"false") == 0 && mm_match(p, c"null") == 0): mm_json_number(p)
	v.text = str_copy_range(p.doc.source, start, p.pos)
	return index

void mm_json_row(mm_parser* p, mm_node* n, char* path, char* value):
	if (n.attributes.length >= MM_UC_JSON_ROWS || p.doc.attribute_count >= 4096):
		mm_error(p.doc, p.pos, c"JSON table row limit exceeded")
		return
	mm_attribute* a = new mm_attribute()
	a.type_name = strclone(path)
	a.name = strclone(value)
	a.keys = strclone(c"")
	a.comment = strclone(c"")
	n.attributes.push(a)
	p.doc.attribute_count = p.doc.attribute_count + 1

void mm_json_flatten(mm_parser* p, mm_node* n, list[mm_json_value*] pool, int index, char* path):
	mm_json_value* v = pool[index]
	if (p.doc.error != 0): return
	if (v.kind >= 2):
		mm_json_row(p, n, path, v.text)
		return
	if (v.items.length == 0):
		if (v.kind == 0): mm_json_row(p, n, path, c"{}")
		else: mm_json_row(p, n, path, c"[]")
		return
	for i in range(v.items.length):
		string_builder* child = string_from(path)
		if (v.kind == 0):
			if (child.length != 0): string_append_char(child, '.')
			string_append(child, v.keys[i])
		else:
			string_append_char(child, '[')
			string_append_int(child, i)
			string_append_char(child, ']')
		mm_json_flatten(p, n, pool, v.items[i], child.data)
		string_free(child)

void mm_uc_json(mm_parser* p):
	int index = mm_system_node(p)
	if (index < 0): return
	mm_node* n = p.doc.nodes[index]
	if (n.declared): mm_error(p.doc, p.pos, c"duplicate use-case identifier")
	n.declared = 1
	n.shape = MM_UC_JSON
	n.parent = -1
	if (mm_match(p, c"@") == 0 || mm_peek(p) != '{'):
		mm_error(p.doc, p.pos, c"expected json ID@{ object }")
		return
	list[mm_json_value*] pool = new list[mm_json_value*]
	int root = mm_json_value_parse(p, pool, 0)
	if (p.doc.error == 0 && pool[root].kind != 0): mm_error(p.doc, p.pos, c"JSON table root must be an object")
	if (p.doc.error == 0): mm_json_flatten(p, n, pool, root, c"")
	for mm_json_value* v in pool:
		if (v.text != 0): free(v.text)
		for char* key in v.keys: free(key)
		__w_list_free(cast(__w_list*, v.keys))
		__w_list_free(cast(__w_list*, v.items))
		free(v)
	__w_list_free(cast(__w_list*, pool))
	mm_space(p)
	if (mm_match(p, c":::")): mm_style_inline(p, n)

void mm_uc_note(mm_parser* p, mm_uc_context* ctx):
	mm_space(p)
	if (mm_keyword(p, c"for") == 0):
		mm_error(p.doc, p.pos, c"expected note for TARGET")
		return
	int target = mm_usecase_node(p, -1, 0)
	if (target < 0): return
	mm_space(p)
	char* label
	if (mm_peek(p) == '"'):
		char* raw = mm_quoted(p)
		label = mm_uc_entities(raw)
		free(raw)
	else:
		char* raw = mm_line_text(p)
		label = mm_uc_entities(raw)
		free(raw)
	if (label[0] == 0): mm_error(p.doc, p.pos, c"expected note text")
	string_builder* id = string_from(c"note@")
	string_append_int(id, ctx.notes)
	ctx.notes = ctx.notes + 1
	int index = mm_add_node(p.doc, id.data, p.pos)
	string_free(id)
	if (p.doc.edges.length >= MM_MAX_ITEMS): mm_error(p.doc, p.pos, c"use-case edge limit exceeded")
	if (index < 0 || p.doc.error != 0):
		free(label)
		return
	mm_node* n = p.doc.nodes[index]
	n.shape = MM_UC_NOTE
	n.declared = 1
	free(n.label)
	n.label = label
	mm_edge* e = new mm_edge()
	e.from_node = index
	e.to_node = target
	e.dashed = 1
	e.label = strclone(c"")
	e.left_label = strclone(c"")
	e.right_label = strclone(c"")
	e.scope = -1
	p.doc.edges.push(e)

# style / class statements may target explicit edge IDs as well as nodes.
int mm_uc_style(mm_parser* p, mm_uc_context* ctx):
	int start = p.pos
	int kind = 0
	if (mm_style_keyword(p, c"style")): kind = 1
	else if (mm_style_keyword(p, c"class")): kind = 2
	if (kind == 0): return mm_style_statement(p)
	int targets_start = p.pos
	while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 32 && mm_peek(p) != 9): p.pos = p.pos + 1
	char* targets = str_copy_range(p.doc.source, targets_start, p.pos)
	int edge_target = 0
	int begin = 0
	for i in range(strlen(targets) + 1):
		if (targets[i] == 0 || targets[i] == ','):
			char* name = mm_style_trim(targets, begin, i)
			if (mm_uc_find_edge(p.doc, name) != 0): edge_target = 1
			free(name)
			begin = i + 1
	if (edge_target == 0):
		free(targets)
		p.pos = start
		return mm_style_statement(p)
	mm_space(p)
	mm_style style
	style.mask = 0
	char* classes = 0
	if (kind == 1): style = mm_style_parse(p)
	else:
		int class_start = p.pos
		while (mm_end(p) == 0): p.pos = p.pos + 1
		classes = mm_style_trim(p.doc.source, class_start, p.pos)
		if (classes[0] == 0): mm_error(p.doc, p.pos, c"expected style class names")
	begin = 0
	for i in range(strlen(targets) + 1):
		if (p.doc.error != 0): break
		if (targets[i] == 0 || targets[i] == ','):
			char* name = mm_style_trim(targets, begin, i)
			begin = i + 1
			mm_edge* e = mm_uc_find_edge(p.doc, name)
			if (e != 0):
				if (kind == 1): mm_style_merge(&e.style, &style)
				else:
					int at = 0
					for j in range(p.doc.edges.length):
						if (p.doc.edges[j] == e): at = j
					if (ctx.edges.length >= MM_MAX_ITEMS): mm_error(p.doc, p.pos, c"edge class assignment limit exceeded")
					else:
						ctx.edges.push(at)
						ctx.classes.push(strclone(classes))
			else:
				int index = mm_add_node(p.doc, name, p.pos)
				if (index >= 0):
					mm_node* n = p.doc.nodes[index]
					if (kind == 1): mm_style_merge(&n.style, &style)
					else: mm_style_assign(p, n, classes)
			free(name)
	free(targets)
	if (classes != 0): free(classes)
	return 1

# Class styles on edges, then each edge's direct style over them.
void mm_uc_resolve_edge_classes(mm_parser* p, mm_uc_context* ctx):
	for i in range(ctx.edges.length):
		mm_edge* e = p.doc.edges[ctx.edges[i]]
		mm_style resolved
		resolved.mask = 0
		resolved.fill = 0
		resolved.stroke = 0
		resolved.text = 0
		resolved.width = 0
		char* classes = ctx.classes[i]
		int begin = 0
		for j in range(strlen(classes) + 1):
			if (classes[j] == 0 || classes[j] == ','):
				char* name = mm_style_trim(classes, begin, j)
				mm_style_class* definition = mm_style_find(p.doc, name)
				if (definition != 0): mm_style_merge(&resolved, &definition.style)
				free(name)
				begin = j + 1
		mm_style_merge(&resolved, &e.style)
		e.style = resolved

void mm_uc_validate_metadata(mm_parser* p, mm_node* n):
	int actor = n.shape == MM_UC_ACTOR && n.group == 0
	for mm_property* property in n.metadata:
		char* key = property.key
		char* value = property.value
		if (strcmp(key, c"stereotype") == 0):
			if (n.group || n.shape == MM_UC_JSON || n.shape == MM_UC_NOTE): mm_error(p.doc, p.pos, c"stereotypes apply to actors and use cases")
		else if (strcmp(key, c"business") == 0):
			if (mm_in_words(value, c"|true|false|") == 0): mm_error(p.doc, p.pos, c"business must be true or false")
			if (n.group || n.shape == MM_UC_JSON || n.shape == MM_UC_NOTE): mm_error(p.doc, p.pos, c"business applies to actors and use cases")
			else if (strcmp(value, c"true") == 0 && n.shape == 0): mm_error(p.doc, p.pos, c"rectangular use cases cannot be business elements")
		else if (strcmp(key, c"type") == 0 && n.group):
			if (mm_in_words(value, c"|rect|package|") == 0): mm_error(p.doc, p.pos, c"boundary type must be rect or package")
		else if (strcmp(key, c"type") == 0 && actor):
			if (mm_in_words(value, c"|normal|hollow|awesome|") == 0): mm_error(p.doc, p.pos, c"actor type must be normal, hollow or awesome")
		else if (strcmp(key, c"icon") == 0 && actor):
			if (value[0] == 0): mm_error(p.doc, p.pos, c"expected actor icon name")
		else if (actor): mm_error(p.doc, p.pos, c"actor metadata accepts only type, icon and business")
		else: mm_error(p.doc, p.pos, c"unsupported use-case metadata key")
	if (actor):
		char* type = mm_uc_get(n, c"type")
		int plain = type == 0 || strcmp(type, c"normal") == 0
		if (mm_uc_get(n, c"icon") != 0 && (plain == 0 || mm_uc_true(n, c"business"))): mm_error(p.doc, p.pos, c"an actor icon cannot be combined with a type or business")
		if (type != 0 && strcmp(type, c"awesome") == 0 && mm_uc_true(n, c"business")): mm_error(p.doc, p.pos, c"awesome actors cannot be business elements")

void mm_uc_validate(mm_parser* p, mm_uc_context* ctx):
	mm_uc_resolve_edge_classes(p, ctx)
	for mm_node* n in p.doc.nodes:
		if (p.doc.error == 0): mm_uc_validate_metadata(p, n)
	for i in range(p.doc.edges.length):
		mm_edge* e = p.doc.edges[i]
		if (e.id != 0):
			if (mm_find_node(p.doc, e.id) >= 0): mm_error(p.doc, p.pos, c"edge ID is already used by a node")
			for j in range(i):
				mm_edge* other = p.doc.edges[j]
				if (other.id != 0 && strcmp(other.id, e.id) == 0): mm_error(p.doc, p.pos, c"duplicate edge ID")
		mm_node* a = p.doc.nodes[e.from_node]
		mm_node* b = p.doc.nodes[e.to_node]
		if (a.shape == MM_UC_NOTE && a.group == 0):
			if (b.group || b.shape == MM_UC_JSON || b.shape == MM_UC_NOTE): mm_error(p.doc, p.pos, c"notes attach to one actor or use case")
			continue
		if (a.group || b.group): mm_error(p.doc, p.pos, c"relationships cannot target boundaries")
		if (b.shape == MM_UC_NOTE): mm_error(p.doc, p.pos, c"relationships cannot target notes")
		int json = a.shape == MM_UC_JSON || b.shape == MM_UC_JSON
		int plain = e.dashed == 0 && e.right_marker != MM_TRIANGLE && e.left_marker < MM_UC_CIRCLE && e.right_marker < MM_UC_CIRCLE
		if (json && plain == 0): mm_error(p.doc, p.pos, c"JSON nodes accept only point, reversed-point and markerless associations")
		if (e.dashed && (a.shape == MM_UC_ACTOR || b.shape == MM_UC_ACTOR)): mm_error(p.doc, p.pos, c"include and extend require use-case endpoints")
		if (e.right_marker == MM_TRIANGLE && (a.shape == MM_UC_ACTOR) != (b.shape == MM_UC_ACTOR)): mm_error(p.doc, p.pos, c"generalization needs endpoints of the same kind")

void mm_usecase_statements(mm_parser* p, int scope, mm_uc_context* ctx):
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (scope < 0 && mm_metadata(p)):
			mm_separators(p)
			continue
		if (scope < 0 && mm_uc_style(p, ctx)):
			if (mm_end(p) == 0 || mm_peek(p) == ';'): mm_error(p.doc, p.pos, c"unsupported use-case syntax")
			mm_separators(p)
			continue
		if (mm_keyword(p, c"end")):
			if (scope < 0): mm_error(p.doc, p.pos, c"unexpected boundary end")
			return
		int statement = p.pos
		if (mm_keyword(p, c"direction")):
			if (scope >= 0): mm_error(p.doc, p.pos, c"direction belongs outside boundaries")
			mm_direction(p)
		else if (mm_keyword(p, c"systemBoundary")):
			if (scope >= 0): mm_error(p.doc, p.pos, c"nested use-case boundaries are unsupported")
			int index = mm_usecase_node(p, -1, 1)
			if (index < 0): return
			mm_node* n = p.doc.nodes[index]
			if (n.group): mm_error(p.doc, p.pos, c"duplicate system boundary")
			n.group = 1
			mm_uc_declaration_suffixes(p, n)
			if (mm_end(p) == 0 || mm_peek(p) == ';'): mm_error(p.doc, p.pos, c"unsupported use-case syntax")
			mm_separators(p)
			if (p.doc.error == 0): mm_usecase_statements(p, index, ctx)
		else if (mm_keyword(p, c"actor")):
			int index = mm_usecase_node(p, scope, 1)
			if (index < 0): return
			mm_node* n = p.doc.nodes[index]
			n.shape = MM_UC_ACTOR
			mm_uc_declaration_suffixes(p, n)
		else if (scope < 0 && mm_keyword(p, c"json")): mm_uc_json(p)
		else if (scope < 0 && mm_keyword(p, c"note")): mm_uc_note(p, ctx)
		else:
			# Metadata statement `id@{ ... }` for an edge or an existing node.
			char* edge_id = 0
			int save = p.pos
			while (mm_id_char(mm_peek(p))): p.pos = p.pos + 1
			if (p.pos > save && mm_match(p, c"@{")):
				edge_id = str_copy_range(p.doc.source, save, p.pos - 2)
				if (scope >= 0): mm_error(p.doc, save, c"metadata statements belong outside system boundaries")
				mm_edge* e = mm_uc_find_edge(p.doc, edge_id)
				if (e != 0): mm_uc_edge_metadata(p, e)
				else:
					int index = mm_add_node(p.doc, edge_id, save)
					if (index >= 0):
						mm_node* n = p.doc.nodes[index]
						if (n.declared == 0 && n.group == 0 && n.shape != MM_UC_ACTOR): n.shape = MM_UC_ELLIPSE
						mm_uc_metadata(p, n)
				free(edge_id)
			else:
				p.pos = save
				int from = mm_usecase_node(p, scope, 0)
				if (from < 0): return
				mm_node* n = p.doc.nodes[from]
				int decorated = 0
				if (mm_peek(p) == '@' && p.pos + 1 < p.doc.length && p.doc.source[p.pos + 1] == '{'): decorated = 1
				int before = p.pos
				mm_space(p)
				if (mm_peek(p) == '<' && p.pos + 1 < p.doc.length && p.doc.source[p.pos + 1] == '<'): decorated = 1
				if (mm_peek(p) == ':' && mm_match(p, c":::")):
					p.pos = p.pos - 3
					decorated = 1
				p.pos = before
				if (decorated):
					if (n.declared && n.parent != scope): mm_error(p.doc, p.pos, c"use case already belongs to another boundary")
					n.declared = 1
					n.parent = scope
					mm_uc_declaration_suffixes(p, n)
				else if (mm_end(p) == 0): mm_uc_relationship(p, from, scope)
				else:
					if (n.declared && n.parent != scope): mm_error(p.doc, p.pos, c"use case already belongs to another boundary")
					n.declared = 1
					n.parent = scope
		if (p.pos == statement && p.doc.error == 0): mm_error(p.doc, p.pos, c"unsupported use-case syntax")
		if (mm_end(p) == 0 || mm_peek(p) == ';'): mm_error(p.doc, p.pos, c"unsupported use-case syntax")
		mm_separators(p)
	if (scope >= 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"unterminated system boundary")

void mm_usecase_body(mm_parser* p, int scope):
	mm_uc_context* ctx = new mm_uc_context()
	ctx.edges = new list[int]
	ctx.classes = new list[char*]
	mm_usecase_statements(p, scope, ctx)
	if (p.doc.error == 0): mm_uc_validate(p, ctx)
	for char* classes in ctx.classes: free(classes)
	__w_list_free(cast(__w_list*, ctx.edges))
	__w_list_free(cast(__w_list*, ctx.classes))
	free(ctx)

# ---- Rendering ----

char* mm_uc_stereotype_text(mm_node* n):
	char* value = mm_uc_get(n, c"stereotype")
	if (value == 0): return 0
	string_builder* text = string_from(c"\xc2\xab")
	string_append(text, value)
	string_append(text, c"\xc2\xbb")
	char* result = strclone(text.data)
	string_free(text)
	return result

# Adjusts generic measured bounds for use-case shapes.
void mm_uc_measure(mm_document* d, mm_node* n, mm_bounds* b):
	if (n.group): return
	if (mm_uc_get(n, c"stereotype") != 0): b.h = b.h + MM_TEXT_PITCH
	if (n.shape == MM_UC_NOTE):
		mm_text_block* t = mm_text_layout(n.label, MM_TEXT_WRAP)
		b.w = t.width + 40
		if (b.w < 120): b.w = 120
		b.h = t.height + 28
		mm_text_block_free(t)
	if (n.shape == MM_UC_JSON):
		int keys = 0
		int values = 0
		for mm_attribute* a in n.attributes:
			int kw = mm_text_width(a.type_name, 0)
			int vw = mm_text_width(a.name, 0)
			if (kw > keys): keys = kw
			if (vw > values): values = vw
		b.w = keys + values + 48
		int title = mm_text_width(n.id, MM_TEXT_BOLD) + 32
		if (title > b.w): b.w = title
		if (b.w < 120): b.w = 120
		b.h = 36 + n.attributes.length * 26

void mm_uc_paint(mm_scene* s, int start, int fill, int stroke):
	for i in range(start, s.items.length):
		mm_primitive* p = s.items[i]
		if (p.kind == MM_TEXT): continue
		if (fill != -2):
			p.style.fill = fill
			p.style.mask = p.style.mask | MM_STYLE_FILL
		p.style.stroke = stroke
		p.style.mask = p.style.mask | MM_STYLE_STROKE

void mm_uc_actor(mm_scene* s, mm_node* n, mm_bounds* b):
	int x = b.x + b.w / 2
	int y = b.y + 14
	char* type = mm_uc_get(n, c"type")
	char* icon = mm_uc_get(n, c"icon")
	if (icon != 0):
		mm_arch_glyph_draw(s, mm_arch_glyph(icon), x, b.y + 36)
		return
	if (type != 0 && strcmp(type, c"awesome") == 0):
		mm_draw(s, MM_CIRCLE, x - 12, y - 12, x + 12, y + 12, 1, c"")
		mm_draw(s, MM_POLYGON, x - 26, y + 16, x + 26, y + 60, 1, c"")
		mm_primitive* body = s.items[s.items.length - 1]
		body.points = list[int]{x - 26, y + 60, x - 26, y + 32, x - 14, y + 18, x + 14, y + 18, x + 26, y + 32, x + 26, y + 60}
		return
	if (type != 0 && strcmp(type, c"hollow") == 0):
		mm_draw(s, MM_CIRCLE, x - 10, y - 10, x + 10, y + 10, 0, c"")
		mm_draw(s, MM_POLYGON, x - 22, y + 12, x + 22, y + 64, 0, c"")
		mm_primitive* body = s.items[s.items.length - 1]
		body.points = list[int]{x - 6, y + 12, x + 6, y + 12, x + 22, y + 24, x + 18, y + 30, x + 7, y + 24, x + 7, y + 40, x + 16, y + 64, x + 9, y + 64, x, y + 46, x - 9, y + 64, x - 16, y + 64, x - 7, y + 40, x - 7, y + 24, x - 18, y + 30, x - 22, y + 24}
	else:
		mm_draw(s, MM_CIRCLE, x - 10, y - 10, x + 10, y + 10, 0, c"")
		mm_line(s, x, y + 10, x, y + 44, 0)
		mm_line(s, x - 20, y + 22, x + 20, y + 22, 0)
		mm_line(s, x, y + 44, x - 18, y + 64, 0)
		mm_line(s, x, y + 44, x + 18, y + 64, 0)
	# UML business actor: a slash across the lower left of the head.
	if (mm_uc_true(n, c"business")): mm_line(s, x - 12, y + 2, x - 2, y + 12, 0)

void mm_uc_note_draw(mm_scene* s, mm_node* n, mm_bounds* b):
	int start = s.items.length
	mm_draw(s, MM_POLYGON, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
	mm_primitive* sheet = s.items[s.items.length - 1]
	sheet.points = list[int]{b.x, b.y, b.x + b.w - 12, b.y, b.x + b.w, b.y + 12, b.x + b.w, b.y + b.h, b.x, b.y + b.h}
	mm_line(s, b.x + b.w - 12, b.y, b.x + b.w - 12, b.y + 12, 0)
	mm_line(s, b.x + b.w - 12, b.y + 12, b.x + b.w, b.y + 12, 0)
	mm_uc_paint(s, start, 0xfff5ad, 0xaaaa33)
	mm_label(s, b.x + 20, b.y + 14, n.label, MM_TEXT_WRAP, 0)

void mm_uc_json_draw(mm_scene* s, mm_node* n, mm_bounds* b):
	mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
	mm_text_styled(s, b.x + 16, b.y + 9, n.id, MM_TEXT_BOLD)
	int keys = 0
	for mm_attribute* a in n.attributes:
		int kw = mm_text_width(a.type_name, 0)
		if (kw > keys): keys = kw
	int divider = b.x + keys + 24
	for j in range(n.attributes.length):
		mm_attribute* a = n.attributes[j]
		int y = b.y + 36 + j * 26
		mm_line(s, b.x, y, b.x + b.w, y, 0)
		mm_text(s, b.x + 12, y + 5, a.type_name)
		mm_text(s, divider + 12, y + 5, a.name)
	if (n.attributes.length != 0): mm_line(s, divider, b.y + 36, divider, b.y + b.h, 0)

int mm_uc_rotating(mm_node* n):
	return n.group == 0 && (n.shape == MM_UC_ACTOR || n.shape == MM_UC_ELLIPSE || n.shape == 0)

# colorScheme rotate: actors first, then use cases, each in declaration order.
int mm_uc_series(mm_document* d, mm_node* n):
	int actors = 0
	int before = 0
	int seen = 0
	for mm_node* other in d.nodes:
		if (other == n): seen = 1
		if (mm_uc_rotating(other) == 0): continue
		int actor = other.shape == MM_UC_ACTOR
		if (actor): actors = actors + 1
		if (seen == 0 && actor == (n.shape == MM_UC_ACTOR)): before = before + 1
	if (n.shape == MM_UC_ACTOR): return before
	return actors + before

# Draws one actor, use case, note or JSON table; returns 0 for other nodes.
int mm_uc_node_draw(mm_document* d, mm_scene* s, mm_node* n, mm_bounds* b):
	if (n.group): return 0
	int start = s.items.length
	char* stereotype = mm_uc_stereotype_text(n)
	int label_y = b.y + 90
	if (n.shape == MM_UC_ACTOR):
		mm_uc_actor(s, n, b)
		if (stereotype != 0):
			mm_label(s, b.x + b.w / 2, label_y, stereotype, 0, 1)
			label_y = label_y + MM_TEXT_PITCH
		mm_label(s, b.x + b.w / 2, label_y, n.label, MM_TEXT_WRAP, 1)
	else if (n.shape == MM_UC_NOTE): mm_uc_note_draw(s, n, b)
	else if (n.shape == MM_UC_JSON): mm_uc_json_draw(s, n, b)
	else:
		if (n.shape == MM_UC_ELLIPSE):
			mm_draw(s, MM_POLYGON, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
			mm_primitive* oval = s.items[s.items.length - 1]
			oval.points = new list[int]
			for i in range(48):
				float angle = cast(float, i) * 6.2831853 / 48.0
				oval.points.push(b.x + b.w / 2 + cast(int, fcos(angle) * cast(float, b.w) / 2.0))
				oval.points.push(b.y + b.h / 2 + cast(int, fsin(angle) * cast(float, b.h) / 2.0))
			if (mm_uc_true(n, c"business")): mm_line(s, b.x + b.w * 3 / 4, b.y + b.h - 4, b.x + b.w * 7 / 8, b.y + b.h / 2, 0)
		else: mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
		mm_text_block* title = mm_text_layout(n.label, MM_TEXT_WRAP)
		int height = title.height
		if (stereotype != 0): height = height + MM_TEXT_PITCH
		int y = b.y + (b.h - height) / 2
		if (stereotype != 0):
			mm_label(s, b.x + b.w / 2, y, stereotype, 0, 1)
			y = y + MM_TEXT_PITCH
		mm_text_draw(s, title, b.x + b.w / 2, y, 1)
		mm_text_block_free(title)
	if (stereotype != 0): free(stereotype)
	mm_style_node(d, s, n, start)
	if (d.usecase_rotate && n.style.mask == 0 && n.style_classes[0] == 0 && mm_uc_rotating(n)):
		int series = mm_uc_series(d, n)
		for i in range(start, s.items.length):
			mm_primitive* p = s.items[i]
			if (p.kind != MM_TEXT):
				p.role = MM_ROLE_SERIES
				p.series = series
	return 1

int mm_uc_package(mm_node* n):
	char* type = mm_uc_get(n, c"type")
	return type != 0 && strcmp(type, c"package") == 0

# Package boundaries carry their title in a tab; returns 0 for rect boundaries.
int mm_uc_boundary_draw(mm_document* d, mm_scene* s, mm_node* n, mm_bounds* b):
	if (mm_uc_package(n) == 0): return 0
	int start = s.items.length
	mm_draw(s, MM_BOX, b.x, b.y, b.x + b.w, b.y + b.h, 0, c"")
	mm_text_block* title = mm_text_layout(n.label, 0)
	mm_draw(s, MM_BOX, b.x, b.y, b.x + title.width + 32, b.y + title.height + 20, 0, c"")
	mm_text_draw(s, title, b.x + 16, b.y + 10, 0)
	mm_text_block_free(title)
	mm_style_node(d, s, n, start)
	return 1
