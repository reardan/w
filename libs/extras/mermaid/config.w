# Bounded Mermaid configuration from YAML frontmatter and %%{init: ...}%% /
# %%{initialize: ...}%% directives anywhere in the diagram. Every source
# becomes flat dotted-path entries ("config.themeVariables.primaryColor",
# list items as "config.timeline.sectionFills.0"), validated and applied by
# one pass; a later source overrides an earlier one key by key.
import libs.extras.mermaid.model
import libs.extras.mermaid.style

const int MM_CONFIG_MAX_ENTRIES = 512
const int MM_CONFIG_MAX_DEPTH = 8
const int MM_CONFIG_MAX_ANCHORS = 64

struct mm_config_entry:
	char* path
	char* value
	# 0 scalar, 1 mapping, 2 sequence.
	int map
	int offset
	int origin
	# Entries copied by a YAML merge key (<<): the merge's id and the merged
	# key's path. An explicit key or an earlier merge of that key wins.
	int weak
	char* weak_root

# A YAML anchor names the entries [first, last) rooted at path.
struct mm_config_anchor:
	char* name
	char* path
	int first
	int last

# One physical frontmatter line: content [start, end) after indentation,
# trailing blanks trimmed. Compact sequence items move start/indent forward.
struct mm_yaml_line:
	int begin
	int start
	int end
	int indent

struct mm_config_reader:
	mm_document* doc
	list[mm_config_entry*] entries
	list[mm_config_anchor*] anchors
	list[mm_yaml_line*] lines
	int line
	int origin
	int pos
	int end
	# 1 while reading YAML flow collections (comments, aliases, plain scalars).
	int yaml
	int merges

int mm_config_line_end(mm_document* d, int start, int limit):
	int end = start
	while (end < limit && d.source[end] != 10): end = end + 1
	return end

char* mm_config_trim(mm_document* d, int start, int end):
	while (start < end && (d.source[start] == 32 || d.source[start] == 9 || d.source[start] == 13)): start = start + 1
	while (end > start && (d.source[end - 1] == 32 || d.source[end - 1] == 9 || d.source[end - 1] == 13)): end = end - 1
	return str_copy_range(d.source, start, end)

# prefix.key, or key at the root.
char* mm_config_join(char* prefix, char* key):
	string_builder* s = string_from(prefix)
	if (prefix[0] != 0): string_append_char(s, '.')
	string_append(s, key)
	char* result = s.data
	free(s)
	return result

char* mm_config_index_path(char* prefix, int index):
	string_builder* s = string_from(prefix)
	string_append_char(s, '.')
	string_append_int(s, index)
	char* result = s.data
	free(s)
	return result

# Takes ownership of value.
mm_config_entry* mm_config_add(mm_config_reader* r, char* path, char* value, int map, int offset):
	int depth = 1
	for i in range(strlen(path)):
		if (path[i] == '.'): depth = depth + 1
	if (r.entries.length >= MM_CONFIG_MAX_ENTRIES): mm_error(r.doc, offset, c"configuration entry limit exceeded")
	else if (depth > MM_CONFIG_MAX_DEPTH): mm_error(r.doc, offset, c"configuration nesting too deep")
	if (r.doc.error != 0):
		free(value)
		return 0
	mm_config_entry* e = new mm_config_entry()
	e.path = strclone(path)
	e.value = value
	e.map = map
	e.offset = offset
	e.origin = r.origin
	r.entries.push(e)
	return e

int mm_config_hex_digit(int c):
	if (c >= '0' && c <= '9'): return c - '0'
	if (c >= 'a' && c <= 'f'): return c - 'a' + 10
	if (c >= 'A' && c <= 'F'): return c - 'A' + 10
	return -1

void mm_config_utf8(string_builder* out, int c):
	if (c < 128): string_append_char(out, c)
	else if (c < 2048):
		string_append_char(out, 192 | (c >> 6))
		string_append_char(out, 128 | (c & 63))
	else if (c < 65536):
		string_append_char(out, 224 | (c >> 12))
		string_append_char(out, 128 | ((c >> 6) & 63))
		string_append_char(out, 128 | (c & 63))
	else:
		string_append_char(out, 240 | (c >> 18))
		string_append_char(out, 128 | ((c >> 12) & 63))
		string_append_char(out, 128 | ((c >> 6) & 63))
		string_append_char(out, 128 | (c & 63))

# Quoted string at source[at] (the quote) ending on the same line before
# limit. Double quotes take JSON/YAML escapes (\" \\ \/ \n \t \r \b \f \0 \'
# \xHH \uHHHH \UHHHHHHHH); single quotes take '' for a quote. *next receives
# the index after the closing quote; unterminated reports message.
char* mm_config_quoted(mm_document* d, int at, int limit, int* next, char* unterminated):
	int quote = d.source[at]
	string_builder* out = string_new()
	int i = at + 1
	int closed = 0
	while (i < limit && d.source[i] != 10 && d.error == 0):
		int c = d.source[i] & 255
		if (c == quote):
			if (quote == '\'' && i + 1 < limit && d.source[i + 1] == '\''):
				string_append_char(out, '\'')
				i = i + 2
				continue
			closed = 1
			break
		if (c == '\\' && quote == '"'):
			if (i + 1 >= limit):
				i = i + 1
				break
			int e = d.source[i + 1]
			int digits = 0
			if (e == 'n'): string_append_char(out, 10)
			else if (e == 't'): string_append_char(out, 9)
			else if (e == 'r'): string_append_char(out, 13)
			else if (e == 'b' || e == 'f' || e == '0'): mm_error(d, i, c"control characters are not allowed in configuration strings")
			else if (e == '"' || e == '\\' || e == '/' || e == '\''): string_append_char(out, e)
			else if (e == 'x'): digits = 2
			else if (e == 'u'): digits = 4
			else if (e == 'U'): digits = 8
			else: mm_error(d, i, c"unsupported escape in configuration string")
			i = i + 2
			if (digits):
				int code = 0
				for k in range(digits):
					int h = -1
					if (i < limit): h = mm_config_hex_digit(d.source[i])
					if (h < 0):
						mm_error(d, i, c"invalid unicode escape in configuration string")
						break
					if (code < 16777216): code = code * 16 + h
					i = i + 1
				if (d.error == 0 && ((code < 32 && code != 9 && code != 10) || (code >= 55296 && code < 57344) || code > 1114111)): mm_error(d, i, c"invalid unicode escape in configuration string")
				if (d.error == 0): mm_config_utf8(out, code)
			continue
		string_append_char(out, c)
		i = i + 1
	if (closed == 0 && d.error == 0): mm_error(d, at, unterminated)
	*next = i + 1
	char* result = out.data
	free(out)
	return result

# A block scalar is a frontmatter value, so its plain-line forms never reach here.
char* mm_config_plain(mm_document* d, int start, int end):
	char* value = mm_config_trim(d, start, end)
	int length = strlen(value)
	for i in range(length):
		if (value[i] == '#' && (i == 0 || value[i - 1] == 32 || value[i - 1] == 9)):
			int stop = i
			while (stop > 0 && (value[stop - 1] == 32 || value[stop - 1] == 9)): stop = stop - 1
			value[stop] = 0
			break
	return value

# YAML scalar on one line: quoted (with escapes) or plain, with an optional
# trailing # comment. *quoted reports whether quotes were present.
char* mm_config_scalar(mm_document* d, int start, int end, int* quoted):
	while (start < end && (d.source[start] == 32 || d.source[start] == 9)): start = start + 1
	*quoted = 0
	if (start < end && (d.source[start] == '"' || d.source[start] == '\'')):
		int next = 0
		char* inner = mm_config_quoted(d, start, end, &next, c"unterminated quoted configuration value")
		int rest = next
		while (rest < end && (d.source[rest] == 32 || d.source[rest] == 9)): rest = rest + 1
		if (d.error == 0 && rest < end && (d.source[rest] != '#' || rest == next)): mm_error(d, rest, c"unexpected text after quoted configuration value")
		*quoted = 1
		return inner
	if (start < end && (d.source[start] == '!' || d.source[start] == '%' || d.source[start] == '@' || d.source[start] == '`')): mm_error(d, start, c"unsupported YAML value in frontmatter")
	return mm_config_plain(d, start, end)

void mm_config_space(mm_config_reader* r):
	while (r.pos < r.end):
		int c = r.doc.source[r.pos]
		if (r.yaml && c == '#'):
			while (r.pos < r.end && r.doc.source[r.pos] != 10): r.pos = r.pos + 1
			continue
		if (c != 32 && c != 9 && c != 13 && c != 10): return
		r.pos = r.pos + 1

int mm_config_peek(mm_config_reader* r):
	if (r.pos < r.end): return r.doc.source[r.pos]
	return 0

# A quoted string or a bare token. Bare keys end at ':'; bare values end at
# ',', '}', ']' or the line end (and a ' #' comment in YAML).
char* mm_config_token(mm_config_reader* r, int key):
	char* source = r.doc.source
	int c = mm_config_peek(r)
	if (c == '"' || c == '\''):
		int next = 0
		char* text = mm_config_quoted(r.doc, r.pos, r.end, &next, c"unterminated configuration string")
		r.pos = next
		return text
	int start = r.pos
	while (r.pos < r.end):
		int k = source[r.pos]
		if (k == ',' || k == '}' || k == ']' || k == '{' || k == '[' || k == 10 || k == 13): break
		if (key && k == ':'): break
		if (r.yaml && k == '#' && r.pos > start && (source[r.pos - 1] == 32 || source[r.pos - 1] == 9)): break
		r.pos = r.pos + 1
	int end = r.pos
	while (end > start && (source[end - 1] == 32 || source[end - 1] == 9)): end = end - 1
	if (end == start): mm_error(r.doc, start, c"expected configuration key or value")
	return str_copy_range(source, start, end)

int mm_config_name_char(int c):
	return isalnum(c) || c == '_' || c == '-'

# Anchor or alias name after '&' / '*' at source[r.pos].
char* mm_config_name(mm_document* d, int at, int end, int* next):
	int i = at + 1
	while (i < end && mm_config_name_char(d.source[i])): i = i + 1
	if (i == at + 1): mm_error(d, at, c"expected YAML anchor or alias name")
	*next = i
	return str_copy_range(d.source, at + 1, i)

# Rebase an anchored path below a new root.
char* mm_config_rebase(char* path, char* old_root, char* new_root):
	string_builder* s = string_from(new_root)
	string_append(s, path + strlen(old_root))
	char* result = s.data
	free(s)
	return result

void mm_config_anchor_add(mm_config_reader* r, char* name, char* path, int first, int offset):
	if (r.anchors.length >= MM_CONFIG_MAX_ANCHORS):
		mm_error(r.doc, offset, c"too many YAML anchors")
		return
	mm_config_anchor* a = new mm_config_anchor()
	a.name = strclone(name)
	a.path = strclone(path)
	a.first = first
	a.last = r.entries.length
	r.anchors.push(a)

# *name: copy the anchored entries below path. A merge (<<) copies only the
# anchored mapping's members, as weak entries. Expansion is bounded by the
# entry limit, so nested aliases cannot grow exponentially.
void mm_config_alias(mm_config_reader* r, char* path, char* name, int offset, int merge):
	mm_config_anchor* anchor = 0
	for mm_config_anchor* a in r.anchors:
		if (strcmp(a.name, name) == 0): anchor = a
	if (anchor == 0):
		mm_error(r.doc, offset, c"unknown YAML alias")
		return
	int first = anchor.first
	int last = anchor.last
	if (merge):
		mm_config_entry* root = r.entries[first]
		if (root.map != 1):
			mm_error(r.doc, offset, c"merge key requires a mapping alias")
			return
		first = first + 1
		r.merges = r.merges + 1
	for i in range(first, last):
		if (r.doc.error != 0): return
		mm_config_entry* source = r.entries[i]
		char* rebased = mm_config_rebase(source.path, anchor.path, path)
		mm_config_entry* copy = mm_config_add(r, rebased, strclone(source.value), source.map, offset)
		free(rebased)
		if (copy == 0): return
		if (merge):
			copy.weak = r.merges
			int stop = strlen(anchor.path) + 1
			while (source.path[stop] != 0 && source.path[stop] != '.'): stop = stop + 1
			char* member = str_copy_range(source.path, 0, stop)
			copy.weak_root = mm_config_rebase(member, anchor.path, path)
			free(member)
		else if (source.weak):
			copy.weak = source.weak
			copy.weak_root = mm_config_rebase(source.weak_root, anchor.path, path)


void mm_config_object(mm_config_reader* r, char* path);
void mm_config_array(mm_config_reader* r, char* path);

# One flow value at r.pos below path.
void mm_config_flow(mm_config_reader* r, char* path, int offset):
	int c = mm_config_peek(r)
	if (r.yaml && c == '&'):
		int next = 0
		char* name = mm_config_name(r.doc, r.pos, r.end, &next)
		r.pos = next
		mm_config_space(r)
		int first = r.entries.length
		if (r.doc.error == 0): mm_config_flow(r, path, offset)
		if (r.doc.error == 0): mm_config_anchor_add(r, name, path, first, offset)
		free(name)
		return
	if (r.yaml && c == '*'):
		int next = 0
		char* name = mm_config_name(r.doc, r.pos, r.end, &next)
		r.pos = next
		if (r.doc.error == 0): mm_config_alias(r, path, name, offset, 0)
		free(name)
		return
	if (c == '{'):
		if (mm_config_add(r, path, strclone(c""), 1, offset) != 0): mm_config_object(r, path)
	else if (c == '['):
		if (mm_config_add(r, path, strclone(c""), 2, offset) != 0): mm_config_array(r, path)
	else: mm_config_add(r, path, mm_config_token(r, 0), 0, offset)

# JSON-ish object at r.pos ('{'): quoted or bare keys, nested values, trailing commas.
void mm_config_object(mm_config_reader* r, char* path):
	r.pos = r.pos + 1
	mm_config_space(r)
	if (mm_config_peek(r) == '}'):
		r.pos = r.pos + 1
		return
	while (r.doc.error == 0):
		mm_config_space(r)
		int at = r.pos
		char* key = mm_config_token(r, 1)
		mm_config_space(r)
		if (r.doc.error == 0 && index_of(key, c".") >= 0): mm_error(r.doc, at, c"invalid configuration key")
		if (r.doc.error == 0 && mm_config_peek(r) != ':'): mm_error(r.doc, r.pos, c"configuration key requires colon")
		if (r.doc.error != 0):
			free(key)
			return
		r.pos = r.pos + 1
		mm_config_space(r)
		char* child = mm_config_join(path, key)
		free(key)
		mm_config_flow(r, child, at)
		free(child)
		if (r.doc.error != 0): return
		mm_config_space(r)
		int c = mm_config_peek(r)
		if (c == ','):
			r.pos = r.pos + 1
			mm_config_space(r)
			if (mm_config_peek(r) == '}'):
				r.pos = r.pos + 1
				return
		else if (c == '}'):
			r.pos = r.pos + 1
			return
		else:
			mm_error(r.doc, r.pos, c"expected , or } in configuration")
			return

# Flow sequence at r.pos ('['): items become path.0, path.1, ...
void mm_config_array(mm_config_reader* r, char* path):
	r.pos = r.pos + 1
	mm_config_space(r)
	if (mm_config_peek(r) == ']'):
		r.pos = r.pos + 1
		return
	int index = 0
	while (r.doc.error == 0):
		mm_config_space(r)
		char* child = mm_config_index_path(path, index)
		mm_config_flow(r, child, r.pos)
		free(child)
		index = index + 1
		if (r.doc.error != 0): return
		mm_config_space(r)
		int c = mm_config_peek(r)
		if (c == ','):
			r.pos = r.pos + 1
			mm_config_space(r)
			if (mm_config_peek(r) == ']'):
				r.pos = r.pos + 1
				return
		else if (c == ']'):
			r.pos = r.pos + 1
			return
		else:
			mm_error(r.doc, r.pos, c"expected , or ] in configuration")
			return

# ---- YAML block structure ----

# Next line with content (not blank, not a comment), or -1.
int mm_yaml_next(mm_config_reader* r):
	while (r.line < r.lines.length):
		mm_yaml_line* l = r.lines[r.line]
		if (l.start < l.end && r.doc.source[l.start] != '#'): return r.line
		r.line = r.line + 1
	return -1

int mm_yaml_item(mm_config_reader* r, mm_yaml_line* l):
	return r.doc.source[l.start] == '-' && (l.start + 1 == l.end || r.doc.source[l.start + 1] == 32)

# Index of a block mapping colon ("key: value" / "key:") in [start, end), else -1.
int mm_yaml_colon(mm_config_reader* r, int start, int end):
	char* s = r.doc.source
	int i = start
	if (s[start] == '"' || s[start] == '\''):
		int quote = s[start]
		i = start + 1
		while (i < end):
			if (quote == '"' && s[i] == '\\'):
				i = i + 2
				continue
			if (s[i] == quote):
				if (quote == '\'' && i + 1 < end && s[i + 1] == '\''):
					i = i + 2
					continue
				break
			i = i + 1
		if (i >= end): return -1
		i = i + 1
		while (i < end && s[i] == 32): i = i + 1
		if (i < end && s[i] == ':' && (i + 1 == end || s[i + 1] == 32 || s[i + 1] == 9)): return i
		return -1
	if (s[start] == '{' || s[start] == '['): return -1
	while (i < end):
		if (s[i] == '#' && i > start && (s[i - 1] == 32 || s[i - 1] == 9)): return -1
		if (s[i] == ':' && (i + 1 == end || s[i + 1] == 32 || s[i + 1] == 9)): return i
		i = i + 1
	return -1

char* mm_yaml_key(mm_config_reader* r, int start, int colon, int offset):
	mm_document* d = r.doc
	char* key
	if (d.source[start] == '"' || d.source[start] == '\''):
		int next = 0
		key = mm_config_quoted(d, start, colon, &next, c"invalid frontmatter key")
	else:
		key = mm_config_trim(d, start, colon)
		int first = key[0]
		if (first == '&' || first == '*' || first == '!' || first == '?' || first == '|' || first == '>' || first == '%' || first == '@' || first == '`'): mm_error(d, offset, c"invalid frontmatter key")
	int valid = key[0] != 0
	for i in range(strlen(key)):
		if (key[i] == '.' || ((key[i] & 255) < 32)): valid = 0
	if (valid == 0): mm_error(d, offset, c"invalid frontmatter key")
	return key


void mm_yaml_block(mm_config_reader* r, char* path, int indent);

# |, |-, |+, >, >-, >+ with an optional indentation digit, on the lines after
# the header that are indented beyond the parent.
void mm_yaml_block_scalar(mm_config_reader* r, char* path, int indent, int at, int end, int offset):
	mm_document* d = r.doc
	int folded = d.source[at] == '>'
	int chomp = 0
	int explicit = 0
	int i = at + 1
	while (i < end && d.source[i] != 32 && d.source[i] != 9):
		int c = d.source[i]
		if ((c == '-' || c == '+') && chomp == 0):
			chomp = 1
			if (c == '+'): chomp = 2
		else if (c >= '1' && c <= '9' && explicit == 0): explicit = c - '0'
		else:
			mm_error(d, offset, c"invalid YAML block scalar header")
			return
		i = i + 1
	while (i < end && (d.source[i] == 32 || d.source[i] == 9)): i = i + 1
	if (i < end && d.source[i] != '#'):
		mm_error(d, offset, c"invalid YAML block scalar header")
		return
	int content = 0
	if (explicit): content = indent + explicit
	int first = r.line
	int last = r.line
	while (last < r.lines.length):
		mm_yaml_line* l = r.lines[last]
		if (l.start == l.end):
			last = last + 1
			continue
		if (l.indent <= indent): break
		if (content == 0): content = l.indent
		if (l.indent < content): break
		last = last + 1
	# Trailing blank lines belong to the scalar only for keep chomping.
	int stop = last
	while (stop > first):
		mm_yaml_line* l = r.lines[stop - 1]
		if (l.start != l.end): break
		stop = stop - 1
	string_builder* out = string_new()
	int previous = -1
	for k in range(first, stop):
		mm_yaml_line* l = r.lines[k]
		int from = l.begin + content
		if (from > l.end): from = l.end
		int empty = from >= l.end
		int more = empty == 0 && (d.source[from] == 32 || d.source[from] == 9)
		if (k > first):
			if (folded && previous == 1 && empty == 0 && more == 0): string_append_char(out, 32)
			else if (folded && previous == 1 && empty): string_append(out, c"")
			else: string_append_char(out, 10)
		string_append_bytes(out, d.source + from, l.end - from)
		previous = 2
		if (empty == 0 && more == 0): previous = 1
		if (empty): previous = 0
	if (stop > first && chomp != 1): string_append_char(out, 10)
	if (chomp == 2):
		for k in range(stop, last): string_append_char(out, 10)
	r.line = last
	char* text = out.data
	free(out)
	mm_config_add(r, path, text, 0, offset)

# The value after "key:" or "- " on the current line, [at, end); the line
# itself is consumed. Nested blocks must be indented beyond indent, except a
# mapping value's sequence, which may sit at the key's indentation.
void mm_yaml_value(mm_config_reader* r, char* path, int indent, int at, int end, int offset, int compact):
	mm_document* d = r.doc
	while (at < end && (d.source[at] == 32 || d.source[at] == 9)): at = at + 1
	char* anchor = 0
	if (at < end && d.source[at] == '&'):
		int next = 0
		anchor = mm_config_name(d, at, end, &next)
		at = next
		if (at < end && d.source[at] != 32 && d.source[at] != 9): mm_error(d, at, c"expected YAML anchor or alias name")
		while (at < end && (d.source[at] == 32 || d.source[at] == 9)): at = at + 1
	int first = r.entries.length
	if (d.error != 0):
		free(anchor)
		return
	if (at < end && d.source[at] == '!'): mm_error(d, at, c"YAML tags are not supported")
	else if (at == end || d.source[at] == '#'):
		int next = mm_yaml_next(r)
		int nested = 0
		if (next >= 0):
			mm_yaml_line* l = r.lines[next]
			nested = l.indent > indent || (compact && l.indent == indent && mm_yaml_item(r, l))
			if (nested): mm_yaml_block(r, path, l.indent)
		if (nested == 0): mm_config_add(r, path, strclone(c""), 1, offset)
	else if (d.source[at] == '*'):
		int next = 0
		char* name = mm_config_name(d, at, end, &next)
		while (next < end && (d.source[next] == 32 || d.source[next] == 9)): next = next + 1
		if (d.error == 0 && next < end && d.source[next] != '#'): mm_error(d, next, c"unexpected text after YAML alias")
		if (d.error == 0): mm_config_alias(r, path, name, offset, 0)
		free(name)
	else if (d.source[at] == '|' || d.source[at] == '>'): mm_yaml_block_scalar(r, path, indent, at, end, offset)
	else if (d.source[at] == '{' || d.source[at] == '['):
		mm_yaml_line* last = r.lines[r.lines.length - 1]
		r.pos = at
		r.end = last.end
		r.yaml = 1
		mm_config_flow(r, path, offset)
		r.yaml = 0
		# A flow collection may continue over lines; resume after its last line.
		int stop = mm_config_line_end(d, r.pos, d.source_end)
		while (d.error == 0 && r.pos < stop && (d.source[r.pos] == 32 || d.source[r.pos] == 9 || d.source[r.pos] == 13)): r.pos = r.pos + 1
		if (d.error == 0 && r.pos < stop && d.source[r.pos] != '#'): mm_error(d, r.pos, c"unexpected text after frontmatter mapping")
		while (r.line < r.lines.length):
			mm_yaml_line* l = r.lines[r.line]
			if (l.begin > r.pos): break
			r.line = r.line + 1
	else:
		int quoted = 0
		mm_config_add(r, path, mm_config_scalar(d, at, end, &quoted), 0, offset)
	if (anchor != 0):
		if (d.error == 0): mm_config_anchor_add(r, anchor, path, first, offset)
		free(anchor)

# `<<: *a` or `<<: [*a, *b]` merges anchored mappings into path.
void mm_yaml_merge(mm_config_reader* r, char* path, int at, int end, int offset):
	mm_document* d = r.doc
	while (at < end && d.source[at] == 32): at = at + 1
	int list = at < end && d.source[at] == '['
	if (list): at = at + 1
	while (d.error == 0):
		while (at < end && d.source[at] == 32): at = at + 1
		if (at >= end || d.source[at] != '*'):
			mm_error(d, offset, c"merge key requires an alias")
			return
		int next = 0
		char* name = mm_config_name(d, at, end, &next)
		if (d.error == 0): mm_config_alias(r, path, name, offset, 1)
		free(name)
		at = next
		while (at < end && d.source[at] == 32): at = at + 1
		if (list == 0 || at >= end || d.source[at] != ','): break
		at = at + 1
	if (list):
		if (at < end && d.source[at] == ']'): at = at + 1
		else: mm_error(d, offset, c"merge key requires an alias")
	while (at < end && d.source[at] == 32): at = at + 1
	if (d.error == 0 && at < end && d.source[at] != '#'): mm_error(d, at, c"unexpected text after YAML alias")

void mm_yaml_mapping(mm_config_reader* r, char* path, int indent):
	mm_document* d = r.doc
	if (path[0] != 0):
		mm_yaml_line* opening = r.lines[r.line]
		if (mm_config_add(r, path, strclone(c""), 1, opening.begin) == 0): return
	while (d.error == 0):
		int next = mm_yaml_next(r)
		if (next < 0): return
		mm_yaml_line* l = r.lines[next]
		if (l.indent < indent): return
		if (l.indent > indent):
			mm_error(d, l.begin, c"inconsistent frontmatter indentation")
			return
		if (mm_yaml_item(r, l)):
			if (path[0] == 0): mm_error(d, l.begin, c"frontmatter must be a mapping")
			return
		int colon = mm_yaml_colon(r, l.start, l.end)
		if (colon < 0):
			mm_error(d, l.begin, c"frontmatter entry requires key: value")
			return
		char* key = mm_yaml_key(r, l.start, colon, l.begin)
		r.line = next + 1
		if (d.error == 0):
			if (strcmp(key, c"<<") == 0): mm_yaml_merge(r, path, colon + 1, l.end, l.begin)
			else:
				char* child = mm_config_join(path, key)
				mm_yaml_value(r, child, indent, colon + 1, l.end, l.begin, 1)
				free(child)
		free(key)

void mm_yaml_sequence(mm_config_reader* r, char* path, int indent):
	mm_document* d = r.doc
	mm_yaml_line* opening = r.lines[r.line]
	if (mm_config_add(r, path, strclone(c""), 2, opening.begin) == 0): return
	int index = 0
	while (d.error == 0):
		int next = mm_yaml_next(r)
		if (next < 0): return
		mm_yaml_line* l = r.lines[next]
		if (l.indent < indent): return
		if (l.indent > indent):
			mm_error(d, l.begin, c"inconsistent frontmatter indentation")
			return
		if (mm_yaml_item(r, l) == 0): return
		char* child = mm_config_index_path(path, index)
		int content = l.start + 1
		while (content < l.end && d.source[content] == 32): content = content + 1
		int nested = 0
		if (content < l.end && d.source[content] != '#'):
			nested = mm_yaml_colon(r, content, l.end) >= 0 || (d.source[content] == '-' && (content + 1 == l.end || d.source[content + 1] == 32))
		if (nested):
			# A compact mapping or sequence starts on the item's own line.
			l.start = content
			l.indent = content - l.begin
			mm_yaml_block(r, child, l.indent)
		else:
			r.line = next + 1
			mm_yaml_value(r, child, indent, content, l.end, l.begin, 0)
		free(child)
		index = index + 1

void mm_yaml_block(mm_config_reader* r, char* path, int indent):
	int next = mm_yaml_next(r)
	if (next < 0): return
	mm_yaml_line* l = r.lines[next]
	if (mm_yaml_item(r, l)): mm_yaml_sequence(r, path, indent)
	else: mm_yaml_mapping(r, path, indent)

void mm_config_frontmatter(mm_config_reader* r):
	mm_document* d = r.doc
	int pos = d.source_start
	int end = mm_config_line_end(d, pos, d.source_end)
	char* line = mm_config_trim(d, pos, end)
	int present = strcmp(line, c"---") == 0
	free(line)
	if (present == 0): return
	pos = end + 1
	int closed = 0
	while (pos < d.source_end && d.error == 0):
		end = mm_config_line_end(d, pos, d.source_end)
		line = mm_config_trim(d, pos, end)
		int fence = strcmp(line, c"---") == 0
		free(line)
		if (fence):
			closed = 1
			d.source_start = end
			if (end < d.source_end): d.source_start = end + 1
			break
		mm_yaml_line* l = new mm_yaml_line()
		l.begin = pos
		int at = pos
		while (at < end && d.source[at] == 32): at = at + 1
		if (at < end && d.source[at] == 9): mm_error(d, at, c"frontmatter indentation must use spaces")
		int stop = end
		while (stop > at && (d.source[stop - 1] == 32 || d.source[stop - 1] == 9 || d.source[stop - 1] == 13)): stop = stop - 1
		l.start = at
		l.end = stop
		l.indent = at - pos
		r.lines.push(l)
		pos = end + 1
	if (d.error == 0 && closed == 0): mm_error(d, d.source_start, c"unterminated frontmatter")
	if (d.error != 0): return
	int first = mm_yaml_next(r)
	if (first < 0): return
	mm_yaml_line* opening = r.lines[first]
	mm_yaml_mapping(r, c"", opening.indent)
	if (d.error == 0):
		int rest = mm_yaml_next(r)
		if (rest >= 0):
			mm_yaml_line* l = r.lines[rest]
			mm_error(d, l.begin, c"inconsistent frontmatter indentation")

# One %%{...}%% directive at source[at]. init/initialize carry an object;
# wrap sets `wrap: true`; other directive names are skipped. Returns the
# index after the closing }%%.
int mm_config_directive(mm_config_reader* r, int at):
	mm_document* d = r.doc
	r.origin = r.origin + 1
	r.pos = at + 3
	r.end = d.source_end
	r.yaml = 0
	mm_config_space(r)
	int start = r.pos
	while (r.pos < r.end && mm_config_name_char(d.source[r.pos])): r.pos = r.pos + 1
	char* kind = str_copy_range(d.source, start, r.pos)
	mm_config_space(r)
	if (strcmp(kind, c"init") == 0 || strcmp(kind, c"initialize") == 0):
		if (d.error == 0 && mm_config_peek(r) != ':'): mm_error(d, r.pos, c"Mermaid directive requires colon")
		r.pos = r.pos + 1
		mm_config_space(r)
		if (d.error == 0 && mm_config_peek(r) != '{'): mm_error(d, r.pos, c"init directive requires an object")
		if (d.error == 0): mm_config_flow(r, c"config", at)
		mm_config_space(r)
	else if (strcmp(kind, c"wrap") == 0): mm_config_add(r, c"config.wrap", strclone(c"true"), 0, at)
	else:
		# Unknown directives are ignored, as upstream ignores them.
		while (r.pos + 2 < r.end && (d.source[r.pos] != '}' || d.source[r.pos + 1] != '%' || d.source[r.pos + 2] != '%')): r.pos = r.pos + 1
	free(kind)
	if (d.error == 0 && (r.pos + 2 >= r.end || d.source[r.pos] != '}' || d.source[r.pos + 1] != '%' || d.source[r.pos + 2] != '%')): mm_error(d, at, c"unterminated Mermaid directive")
	if (d.error != 0): return r.end
	r.pos = r.pos + 3
	int end = mm_config_line_end(d, r.pos, d.source_end)
	for i in range(r.pos, end):
		if (d.source[i] != 32 && d.source[i] != 9 && d.source[i] != 13):
			mm_error(d, i, c"unexpected text after Mermaid directive")
			return r.end
	return r.pos

# Directives before the diagram header (after any frontmatter) are consumed
# from the body; later directives anywhere in the body are read in order and
# skipped by the diagram parsers as comments.
void mm_config_directives(mm_config_reader* r):
	mm_document* d = r.doc
	int pos = d.source_start
	int consumed = -1
	while (pos < d.source_end && d.error == 0):
		int end = mm_config_line_end(d, pos, d.source_end)
		int at = pos
		while (at < end && (d.source[at] == 32 || d.source[at] == 9 || d.source[at] == 13)): at = at + 1
		if (at == end):
			pos = end + 1
			continue
		if (at + 1 >= end || d.source[at] != '%' || d.source[at + 1] != '%'): break
		if (at + 2 >= end || d.source[at + 2] != '{'):
			pos = end + 1
			continue
		int after = mm_config_directive(r, at)
		if (d.error != 0): return
		pos = mm_config_line_end(d, after, d.source_end) + 1
		consumed = pos
	if (consumed > d.source_end): consumed = d.source_end
	if (consumed >= 0): d.source_start = consumed
	pos = d.source_start
	while (pos + 2 < d.source_end && d.error == 0):
		if (d.source[pos] == '%' && d.source[pos + 1] == '%' && d.source[pos + 2] == '{'): pos = mm_config_directive(r, pos)
		else: pos = pos + 1

char* mm_config_duplicate(char* path):
	if (strcmp(path, c"title") == 0): return c"duplicate frontmatter title"
	if (strcmp(path, c"config") == 0): return c"duplicate frontmatter config"
	if (strcmp(path, c"config.theme") == 0): return c"duplicate theme setting"
	if (strcmp(path, c"config.layout") == 0): return c"duplicate layout setting"
	if (strcmp(path, c"config.packet") == 0): return c"duplicate packet configuration"
	if (strcmp(path, c"config.packet.bitsPerRow") == 0): return c"duplicate bitsPerRow"
	if (strcmp(path, c"config.packet.bitOrder") == 0): return c"duplicate bitOrder"
	if (strcmp(path, c"config.themeVariables") == 0): return c"duplicate themeVariables setting"
	if (strcmp(path, c"config.kanban") == 0): return c"duplicate kanban configuration"
	if (strcmp(path, c"config.kanban.ticketBaseUrl") == 0): return c"duplicate ticketBaseUrl"
	return c"duplicate configuration key"

# Decimal integer in [low, high], or -1.
int mm_config_int(char* value, int low, int high):
	int length = strlen(value)
	if (length == 0 || length > 4): return -1
	int result = 0
	for i in range(length):
		if (value[i] < '0' || value[i] > '9'): return -1
		result = result * 10 + value[i] - '0'
	if (result < low || result > high): return -1
	return result

int mm_config_scalar_entry(mm_document* d, mm_config_entry* e):
	if (e.map): mm_error(d, e.offset, c"configuration value must be a scalar")
	return e.map == 0

# ---- Per-family keys ----

# Supported keys below `config.` and their value kinds:
#   b boolean; i LOW HIGH integer; m LOW HIGH decimal in thousandths;
#   e A|B|C enumeration; c color; s N string of at most N bytes;
#   d duration (1day, 2week, ...); k sankey linkColor (enumeration or color);
#   L list of colors; M mapping of colors.
char* mm_config_specs():
	return c"wrap b\nsequence.mirrorActors b\nsequence.actorMargin i 0 1000\nsequence.width i 20 2000\nsequence.height i 20 75\nsequence.messageAlign e left|center|right\nsequence.showSequenceNumbers b\nsequence.wrap b\nsequence.activationWidth i 1 200\nsequence.diagramMarginX i 0 1000\ngantt.barHeight i 4 200\ngantt.barGap i 0 200\ngantt.topAxis b\ngantt.tickInterval d\ngantt.displayMode e compact|\ngantt.axisFormat s 64\ngantt.weekday e monday|tuesday|wednesday|thursday|friday|saturday|sunday\ngantt.leftPadding i 0 1000\nxyChart.width i 100 5000\nxyChart.height i 100 5000\nxyChart.chartOrientation e vertical|horizontal\nxyChart.showDataLabel b\nxyChart.showTitle b\nxyChart.showLegend b\nxyChart.xAxis.showLabel b\nxyChart.xAxis.showTitle b\nxyChart.xAxis.showAxisLine b\nxyChart.yAxis.showLabel b\nxyChart.yAxis.showTitle b\nxyChart.yAxis.showTick b\nxyChart.yAxis.showAxisLine b\nsankey.showValues b\nsankey.nodeAlignment e left|right|center|justify\nsankey.linkColor k\nsankey.prefix s 32\nsankey.suffix s 32\nsankey.nodeWidth i 1 200\nsankey.nodePadding i 0 500\nsankey.width i 100 5000\nsankey.height i 100 5000\nsankey.nodeColors M\nradar.width i 100 5000\nradar.height i 100 5000\nradar.marginTop i 0 1000\nradar.marginRight i 0 1000\nradar.marginBottom i 0 1000\nradar.marginLeft i 0 1000\nradar.axisScaleFactor m 0 10000\nradar.axisLabelFactor m 0 10000\nradar.curveTension m 0 1000\ntimeline.disableMulticolor b\ntimeline.width i 20 2000\ntimeline.sectionFills L\ngitGraph.showBranches b\ngitGraph.showCommitLabel b\ngitGraph.mainBranchName s 64\ngitGraph.mainBranchOrder i 0 1000000\ngitGraph.parallelCommits b\nrailroad.showMarkers b\nrailroad.horizontalSeparation i 0 200\nrailroad.verticalSeparation i 0 200\nrailroad.strokeWidth i 1 16\nrailroad.terminalFill c\nrailroad.terminalStroke c\nrailroad.nonTerminalFill c\nrailroad.nonTerminalStroke c\nrailroad.lineColor c\nrequirement.rect_min_width i 0 2000\nrequirement.rect_min_height i 0 2000\nc4.c4ShapeInRow i 1 100\nc4.c4BoundaryInRow i 1 100\n"

# The spec of key (owned), or null when the key is not supported.
char* mm_config_spec(char* key):
	char* table = mm_config_specs()
	int length = strlen(key)
	int at = 0
	while (table[at] != 0):
		int line = at
		while (table[at] != 0 && table[at] != 10): at = at + 1
		int match = 1
		for i in range(length):
			if (line + i >= at || table[line + i] != key[i]):
				match = 0
				break
		if (match && line + length < at && table[line + length] == 32): return str_copy_range(table, line + length + 1, at)
		if (table[at] == 10): at = at + 1
	return 0

int mm_in_words_config(char* key, char* words):
	string_builder* s = string_from(c"|")
	string_append(s, key)
	string_append_char(s, '|')
	int found = index_of(words, s.data) >= 0
	string_free(s)
	return found

# Family sections whose configuration must be a mapping.
int mm_config_section(char* key):
	return mm_in_words_config(key, c"|packet|themeVariables|flowchart|kanban|sequence|gantt|xyChart|sankey|radar|timeline|gitGraph|railroad|requirement|c4|xyChart.xAxis|xyChart.yAxis|sankey.nodeColors|")

# Decimal number (optional sign and up to three fraction digits), else 0.
int mm_config_decimal(char* value, int integer):
	int at = 0
	if (value[0] == '-' || value[0] == '+'): at = 1
	int digits = 0
	while (value[at] >= '0' && value[at] <= '9'):
		at = at + 1
		digits = digits + 1
	if (digits == 0 || digits > 9): return 0
	if (value[at] == '.'):
		at = at + 1
		int fraction = 0
		while (value[at] >= '0' && value[at] <= '9'):
			at = at + 1
			fraction = fraction + 1
		if (fraction == 0 || (integer && fraction > 0 && mm_config_parse_milli(value) % 1000 != 0)): return 0
	return value[at] == 0

char* mm_config_milli_text(int value):
	string_builder* s = string_new()
	if (value < 0):
		string_append_char(s, '-')
		value = 0 - value
	string_append_int(s, value / 1000)
	int fraction = value % 1000
	if (fraction):
		string_append_char(s, '.')
		string_append_char(s, '0' + fraction / 100)
		if (fraction % 100): string_append_char(s, '0' + fraction / 10 % 10)
		if (fraction % 10): string_append_char(s, '0' + fraction % 10)
	char* result = s.data
	free(s)
	return result

# Gantt tickInterval: a positive count and a unit, e.g. 1day, 2week, 6hour.
int mm_config_duration(char* value):
	int at = 0
	int count = 0
	while (value[at] >= '0' && value[at] <= '9'):
		if (count < 100000): count = count * 10 + value[at] - '0'
		at = at + 1
	if (at == 0 || count < 1 || count > 10000): return 0
	char* unit = value + at
	return strcmp(unit, c"millisecond") == 0 || strcmp(unit, c"second") == 0 || strcmp(unit, c"minute") == 0 || strcmp(unit, c"hour") == 0 || strcmp(unit, c"day") == 0 || strcmp(unit, c"week") == 0 || strcmp(unit, c"month") == 0

void mm_config_store(mm_document* d, char* key, char* value):
	if (d.config == 0): d.config = new list[mm_property*]
	for mm_property* property in d.config:
		if (strcmp(property.key, key) == 0):
			free(property.value)
			property.value = strclone(value)
			return
	mm_property* property = new mm_property()
	property.key = strclone(key)
	property.value = strclone(value)
	d.config.push(property)

# A later list or color mapping replaces an earlier one as a whole.
void mm_config_clear_children(mm_document* d, char* key):
	if (d.config == 0): return
	string_builder* prefix = string_from(key)
	string_append_char(prefix, '.')
	list[mm_property*] kept = new list[mm_property*]
	for mm_property* property in d.config:
		if (index_of(property.key, prefix.data) == 0):
			free(property.key)
			free(property.value)
			free(property)
		else: kept.push(property)
	__w_list_free(cast(__w_list*, d.config))
	d.config = kept
	string_free(prefix)

void mm_config_ignore(mm_document* d, mm_config_entry* e):
	if (e.map): return
	if (d.config_ignored == 0): d.config_ignored = new list[char*]
	for char* path in d.config_ignored:
		if (strcmp(path, e.path) == 0): return
	d.config_ignored.push(strclone(e.path))

void mm_config_invalid(mm_document* d, mm_config_entry* e, char* key, char* text):
	string_builder* message = string_from(key)
	string_append(message, text)
	mm_error(d, e.offset, message.data)
	string_free(message)

# Validate one value of a table kind and store it normalized.
void mm_config_typed(mm_document* d, mm_config_entry* e, char* key, char* spec):
	char* value = e.value
	int kind = spec[0]
	if (kind == 'L' || kind == 'M'):
		if (kind == 'L' && e.map != 2): mm_config_invalid(d, e, key, c" must be a list of colors")
		else if (kind == 'M' && e.map != 1): mm_config_invalid(d, e, key, c" must be a mapping of colors")
		else: mm_config_clear_children(d, key)
		return
	if (mm_config_scalar_entry(d, e) == 0): return
	if (kind == 'b'):
		if (strcmp(value, c"true") == 0 || strcmp(value, c"True") == 0 || strcmp(value, c"TRUE") == 0): mm_config_store(d, key, c"true")
		else if (strcmp(value, c"false") == 0 || strcmp(value, c"False") == 0 || strcmp(value, c"FALSE") == 0): mm_config_store(d, key, c"false")
		else: mm_config_invalid(d, e, key, c" must be true or false")
	else if (kind == 'i' || kind == 'm'):
		list[char*] parts = split(spec, ' ')
		int low = atoi(parts[1])
		int high = atoi(parts[2])
		for char* part in parts: free(part)
		__w_list_free(cast(__w_list*, parts))
		int ok = mm_config_decimal(value, kind == 'i')
		int number = 0
		if (ok):
			number = mm_config_parse_milli(value)
			if (kind == 'i'): number = number / 1000
			ok = number >= low && number <= high
		if (ok): mm_config_store(d, key, value)
		else:
			string_builder* message = string_new()
			if (kind == 'i'):
				string_append(message, c" must be an integer from ")
				string_append_int(message, low)
				string_append(message, c" to ")
				string_append_int(message, high)
			else:
				char* a = mm_config_milli_text(low)
				char* b = mm_config_milli_text(high)
				string_append(message, c" must be a number from ")
				string_append(message, a)
				string_append(message, c" to ")
				string_append(message, b)
				free(a)
				free(b)
			mm_config_invalid(d, e, key, message.data)
			string_free(message)
	else if (kind == 'e'):
		string_builder* words = string_from(c"|")
		string_append(words, spec + 2)
		string_append_char(words, '|')
		if (mm_in_words_config(value, words.data)): mm_config_store(d, key, value)
		else:
			string_builder* message = string_from(c" must be one of: ")
			char* options = replace(spec + 2, c"|", c", ")
			string_append(message, options)
			free(options)
			mm_config_invalid(d, e, key, message.data)
			string_free(message)
		string_free(words)
	else if (kind == 'c'):
		if (mm_style_color(value) >= 0): mm_config_store(d, key, value)
		else: mm_config_invalid(d, e, key, c" requires #RGB, #RRGGBB or a supported color name")
	else if (kind == 'k'):
		if (mm_in_words_config(value, c"|source|target|gradient|") || mm_style_color(value) >= 0): mm_config_store(d, key, value)
		else: mm_config_invalid(d, e, key, c" must be source, target, gradient or a color")
	else if (kind == 's'):
		if (strlen(value) <= atoi(spec + 2)): mm_config_store(d, key, value)
		else: mm_config_invalid(d, e, key, c" is too long")
	else if (kind == 'd'):
		if (mm_config_duration(value)): mm_config_store(d, key, value)
		else: mm_config_invalid(d, e, key, c" must be a count and unit such as 1day, 2week or 6hour")

# Members of supported lists and color mappings: key is "parent.member".
int mm_config_member(mm_document* d, mm_config_entry* e, char* key):
	int dot = rindex_of(key, c".")
	if (dot <= 0): return 0
	char* parent = str_copy_range(key, 0, dot)
	char* spec = mm_config_spec(parent)
	free(parent)
	if (spec == 0): return 0
	int kind = spec[0]
	free(spec)
	if (kind != 'L' && kind != 'M'): return 0
	if (mm_config_scalar_entry(d, e)):
		if (mm_style_color(e.value) >= 0): mm_config_store(d, key, e.value)
		else: mm_config_invalid(d, e, key, c" requires #RGB, #RRGGBB or a supported color name")
	return 1

# key is the path below "config.". Returns 1 for the theme, look, layout,
# flowchart, packet and kanban keys, which select a resolved theme palette;
# per-family keys and ignored keys leave the unconfigured palette alone.
int mm_config_key(mm_document* d, mm_config_entry* e, char* key, list[int] user, int* theme, int* dark):
	char* value = e.value
	char* spec = mm_config_spec(key)
	if (spec != 0):
		mm_config_typed(d, e, key, spec)
		free(spec)
		return 0
	if (mm_config_member(d, e, key)): return 0
	if (mm_config_section(key)):
		if (e.map == 0): mm_error(d, e.offset, c"configuration section must be a mapping")
		return mm_in_words_config(key, c"|packet|themeVariables|flowchart|kanban|")
	if (strcmp(key, c"theme") == 0):
		if (mm_config_scalar_entry(d, e)):
			*theme = mm_style_theme_id(value)
			if (*theme == 0): mm_error(d, e.offset, c"unsupported theme; supported: default, base, dark, forest, neutral, neo, neo-dark, redux, redux-dark, redux-color, redux-dark-color")
	else if (strcmp(key, c"look") == 0):
		if (mm_config_scalar_entry(d, e)):
			if (strcmp(value, c"neo") == 0): d.look = 1
			else if (strcmp(value, c"classic") == 0): d.look = 0
			else: mm_error(d, e.offset, c"unsupported look; supported: classic, neo")
	else if (strcmp(key, c"layout") == 0):
		if (mm_config_scalar_entry(d, e)):
			if (strcmp(value, c"force") == 0): d.layout_algorithm = 1
			else if (strcmp(value, c"dagre") == 0): d.layout_algorithm = 0
			else: mm_error(d, e.offset, c"supported native layouts: dagre, force")
	else if (strcmp(key, c"packet.bitsPerRow") == 0):
		if (mm_config_scalar_entry(d, e)):
			int bits = mm_config_int(value, 1, 128)
			if (bits < 0): mm_error(d, e.offset, c"bitsPerRow must be 1..128")
			else: d.packet_bits = bits
	else if (strcmp(key, c"packet.bitOrder") == 0):
		if (mm_config_scalar_entry(d, e)):
			if (strcmp(value, c"descending") == 0): d.packet_msb = 1
			else if (strcmp(value, c"ascending") == 0): d.packet_msb = 0
			else: mm_error(d, e.offset, c"bitOrder must be ascending or descending")
	else if (strcmp(key, c"kanban.ticketBaseUrl") == 0):
		if (mm_config_scalar_entry(d, e)):
			if (index_of(value, c"https://") != 0 && index_of(value, c"http://") != 0): mm_error(d, e.offset, c"ticketBaseUrl must be an http or https URL")
			else:
				if (d.ticket_base_url != 0): free(d.ticket_base_url)
				d.ticket_base_url = strclone(value)
	else if (strcmp(key, c"themeVariables.darkMode") == 0):
		if (mm_config_scalar_entry(d, e)):
			if (strcmp(value, c"true") == 0): *dark = 1
			else if (strcmp(value, c"false") == 0): *dark = 0
			else: mm_error(d, e.offset, c"darkMode must be true or false")
	else if (index_of(key, c"themeVariables.") == 0):
		int index = mm_theme_variable(key + 15)
		if (index < 0): mm_error(d, e.offset, c"unsupported theme variable")
		else if (mm_config_scalar_entry(d, e)):
			int color = mm_style_color(value)
			if (color < 0): mm_error(d, e.offset, c"theme variables require #RGB, #RRGGBB or a supported color name")
			else: user[index] = color
	else if (strcmp(key, c"flowchart.nodeSpacing") == 0 || strcmp(key, c"flowchart.rankSpacing") == 0):
		if (mm_config_scalar_entry(d, e)):
			int spacing = mm_config_int(value, 0, 500)
			if (spacing < 0): mm_error(d, e.offset, c"flowchart spacing must be an integer from 0 to 500")
			else if (strcmp(key, c"flowchart.nodeSpacing") == 0):
				d.node_spacing = spacing
				d.config_mask = d.config_mask | 1
			else:
				d.rank_spacing = spacing
				d.config_mask = d.config_mask | 2
	else if (strcmp(key, c"flowchart.curve") == 0):
		if (mm_config_scalar_entry(d, e)):
			if (strcmp(value, c"linear") == 0): d.edge_curve = 1
			else if (strcmp(value, c"basis") == 0): d.edge_curve = 2
			else if (strcmp(value, c"step") == 0 || strcmp(value, c"stepBefore") == 0 || strcmp(value, c"stepAfter") == 0): d.edge_curve = 0
			else: mm_error(d, e.offset, c"unsupported flowchart curve; supported: basis, linear, step, stepBefore, stepAfter")
	else:
		mm_config_ignore(d, e)
		return 0
	return 1

# An entry copied by a merge key yields to an explicit key and to an earlier merge.
int mm_config_shadowed(mm_config_reader* r, int index):
	mm_config_entry* e = r.entries[index]
	if (e.weak == 0): return 0
	for i in range(r.entries.length):
		mm_config_entry* other = r.entries[i]
		if (i == index || other.origin != e.origin): continue
		if (other.weak == 0 && strcmp(other.path, e.weak_root) == 0): return 1
		if (i < index && other.weak != 0 && other.weak != e.weak && strcmp(other.weak_root, e.weak_root) == 0): return 1
	return 0

void mm_config_apply(mm_config_reader* r):
	mm_document* d = r.doc
	int present = 0
	int theme = 0
	int dark = -1
	mm_config_entry* display = 0
	list[int] user = new list[int]
	for i in range(MM_THEME_COUNT): user.push(MM_THEME_UNSET)
	for i in range(r.entries.length):
		if (d.error != 0): break
		mm_config_entry* e = r.entries[i]
		if (mm_config_shadowed(r, i)): continue
		for j in range(i):
			mm_config_entry* other = r.entries[j]
			if (other.origin == e.origin && other.weak == 0 && e.weak == 0 && strcmp(other.path, e.path) == 0): mm_error(d, e.offset, mm_config_duplicate(e.path))
		if (d.error != 0): break
		if (strcmp(e.path, c"title") == 0 && e.origin == 0):
			if (e.map): mm_error(d, e.offset, c"frontmatter title must be a scalar string")
			else:
				free(d.title)
				d.title = strclone(e.value)
		else if (strcmp(e.path, c"displayMode") == 0 && e.origin == 0): display = e
		else if (strcmp(e.path, c"config") == 0):
			if (e.map != 1): mm_error(d, e.offset, c"configuration section must be a mapping")
		else if (index_of(e.path, c"config.") == 0):
			if (mm_config_key(d, e, e.path + 7, user, &theme, &dark)): present = 1
		else: mm_config_ignore(d, e)
	# Frontmatter `displayMode` (upstream's gantt shorthand) overrides config.gantt.displayMode.
	if (d.error == 0 && display != 0):
		if (display.map || (strcmp(display.value, c"compact") != 0 && display.value[0] != 0)): mm_error(d, display.offset, c"displayMode must be compact or empty")
		else: mm_config_store(d, c"gantt.displayMode", display.value)
	if (d.error == 0 && present): mm_style_theme_resolve(d, theme, user, dark)
	__w_list_free(cast(__w_list*, user))

# Read frontmatter, then directives, then validate and apply them all.
void mm_config_read(mm_document* d):
	mm_config_reader r
	r.doc = d
	r.entries = new list[mm_config_entry*]
	r.anchors = new list[mm_config_anchor*]
	r.lines = new list[mm_yaml_line*]
	r.line = 0
	r.origin = 0
	r.pos = 0
	r.end = 0
	r.yaml = 0
	r.merges = 0
	mm_config_frontmatter(&r)
	if (d.error == 0): mm_config_directives(&r)
	if (d.error == 0): mm_config_apply(&r)
	for mm_config_entry* e in r.entries:
		free(e.path)
		free(e.value)
		if (e.weak_root != 0): free(e.weak_root)
		free(e)
	__w_list_free(cast(__w_list*, r.entries))
	for mm_config_anchor* a in r.anchors:
		free(a.name)
		free(a.path)
		free(a)
	__w_list_free(cast(__w_list*, r.anchors))
	for mm_yaml_line* l in r.lines: free(l)
	__w_list_free(cast(__w_list*, r.lines))
