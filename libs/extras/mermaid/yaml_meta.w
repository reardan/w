# `@{ ... }` metadata blocks: the YAML subset upstream loads with js-yaml's
# JSON schema. Single-line bodies are flow mappings; multi-line bodies are
# block mappings with nested mappings, block/flow sequences, flow mappings,
# quoted and block (| >) scalars and comments. Plain scalars resolve to null,
# booleans, integers and floats exactly as in the JSON schema; everything
# else is a string. Each top-level key becomes an mm_property whose value is
# the scalar text, or canonical JSON for a mapping or sequence. Prototype-
# shaped keys (__proto__, constructor, prototype) are dropped at every level.
import libs.extras.mermaid.parse_common

const int MM_YAML_MAX_DEPTH = 32

struct mm_yaml:
	char* text
	int length
	int pos
	int base
	mm_document* doc
	int depth
	# Unescaped text and type of the most recently parsed value.
	char* scalar
	int type

void mm_yaml_fail(mm_yaml* y, int at, char* message):
	if (at > y.length): at = y.length
	mm_error(y.doc, y.base + at, message)

int mm_yaml_peek(mm_yaml* y):
	if (y.pos >= y.length): return 0
	return y.text[y.pos] & 255

int mm_yaml_at(mm_yaml* y, int at):
	if (at < 0 || at >= y.length): return 0
	return y.text[at] & 255

void mm_yaml_inline_space(mm_yaml* y):
	while (mm_yaml_peek(y) == 32 || mm_yaml_peek(y) == 9 || mm_yaml_peek(y) == 13): y.pos = y.pos + 1

# Spaces, newlines and comments inside flow collections.
void mm_yaml_flow_space(mm_yaml* y):
	while (y.doc.error == 0):
		int c = mm_yaml_peek(y)
		if (c == 32 || c == 9 || c == 13 || c == 10): y.pos = y.pos + 1
		else if (c == '#' && (y.pos == 0 || mm_yaml_at(y, y.pos - 1) <= 32)):
			while (mm_yaml_peek(y) != 0 && mm_yaml_peek(y) != 10): y.pos = y.pos + 1
		else: return

void mm_yaml_set(mm_yaml* y, char* text, int type):
	if (y.scalar != 0): free(y.scalar)
	y.scalar = text
	y.type = type

void mm_yaml_json_string(string_builder* out, char* text):
	string_append_char(out, '"')
	int i = 0
	while (text[i] != 0):
		int c = text[i] & 255
		if (c == '"' || c == '\\'):
			string_append_char(out, '\\')
			string_append_char(out, c)
		else if (c == 10): string_append(out, c"\\n")
		else if (c == 13): string_append(out, c"\\r")
		else if (c == 9): string_append(out, c"\\t")
		else if (c < 32):
			string_append(out, c"\\u00")
			string_append_char(out, '0' + c / 16)
			int low = c % 16
			if (low < 10): string_append_char(out, '0' + low)
			else: string_append_char(out, 'a' + low - 10)
		else: string_append_char(out, c)
		i = i + 1
	string_append_char(out, '"')

int mm_yaml_digits(char* text, int i):
	int start = i
	while (isdigit(text[i] & 255)): i = i + 1
	return i - start

# JSON-schema resolution of a plain scalar.
int mm_yaml_classify(char* text):
	if (strcmp(text, c"null") == 0 || text[0] == 0): return MM_VALUE_NULL
	if (strcmp(text, c"true") == 0 || strcmp(text, c"false") == 0): return MM_VALUE_BOOL
	int i = 0
	if (text[i] == '-'): i = i + 1
	int whole = mm_yaml_digits(text, i)
	if (whole == 0 || (whole > 1 && text[i] == '0')): return MM_VALUE_STRING
	i = i + whole
	if (text[i] == 0): return MM_VALUE_INT
	if (text[i] == '.'):
		i = i + 1
		i = i + mm_yaml_digits(text, i)
	if (text[i] == 'e' || text[i] == 'E'):
		i = i + 1
		if (text[i] == '+' || text[i] == '-'): i = i + 1
		int exponent = mm_yaml_digits(text, i)
		if (exponent == 0): return MM_VALUE_STRING
		i = i + exponent
	if (text[i] == 0): return MM_VALUE_FLOAT
	return MM_VALUE_STRING

void mm_yaml_emit_scalar(mm_yaml* y, string_builder* out):
	if (y.type == MM_VALUE_STRING): mm_yaml_json_string(out, y.scalar)
	else: string_append(out, y.scalar)

int mm_yaml_hex(int c):
	if (c >= '0' && c <= '9'): return c - '0'
	if (c >= 'a' && c <= 'f'): return c - 'a' + 10
	if (c >= 'A' && c <= 'F'): return c - 'A' + 10
	return -1

void mm_yaml_utf8(string_builder* out, int code):
	if (code < 128): string_append_char(out, code)
	else if (code < 2048):
		string_append_char(out, 192 + code / 64)
		string_append_char(out, 128 + code % 64)
	else:
		string_append_char(out, 224 + code / 4096)
		string_append_char(out, 128 + code / 64 % 64)
		string_append_char(out, 128 + code % 64)

void mm_yaml_quoted(mm_yaml* y):
	int quote = mm_yaml_peek(y)
	int start = y.pos
	y.pos = y.pos + 1
	string_builder* text = string_new()
	while (y.doc.error == 0):
		int c = mm_yaml_peek(y)
		if (c == 0):
			mm_yaml_fail(y, start, c"unterminated quoted metadata value")
			break
		y.pos = y.pos + 1
		if (c == quote):
			if (quote == 39 && mm_yaml_peek(y) == 39):
				string_append_char(text, 39)
				y.pos = y.pos + 1
				continue
			break
		if (c == 10):
			# Line folding: a single break becomes a space.
			while (text.length > 0 && text.data[text.length - 1] == 32):
				text.length = text.length - 1
				text.data[text.length] = 0
			while (mm_yaml_peek(y) == 32 || mm_yaml_peek(y) == 9): y.pos = y.pos + 1
			if (mm_yaml_peek(y) == 10): string_append_char(text, 10)
			else: string_append_char(text, 32)
			continue
		if (quote == '"' && c == '\\'):
			int e = mm_yaml_peek(y)
			y.pos = y.pos + 1
			if (e == 'n'): string_append_char(text, 10)
			else if (e == 't'): string_append_char(text, 9)
			else if (e == 'r'): string_append_char(text, 13)
			else if (e == '0'): string_append_char(text, 32)
			else if (e == '"' || e == '\\' || e == '/' || e == 32): string_append_char(text, e)
			else if (e == 'u' || e == 'x'):
				int count = 4
				if (e == 'x'): count = 2
				int code = 0
				for i in range(count):
					int digit = mm_yaml_hex(mm_yaml_peek(y))
					if (digit < 0):
						mm_yaml_fail(y, y.pos, c"invalid metadata escape")
						break
					code = code * 16 + digit
					y.pos = y.pos + 1
				if (code == 0): code = 32
				mm_yaml_utf8(text, code)
			else: mm_yaml_fail(y, y.pos - 1, c"invalid metadata escape")
			continue
		string_append_char(text, c)
	mm_yaml_set(y, strclone(text.data), MM_VALUE_STRING)
	string_free(text)

# Plain scalar: flow context stops at , ] } and every context at ` #` or a newline.
void mm_yaml_plain(mm_yaml* y, int flow):
	int start = y.pos
	while (1):
		int c = mm_yaml_peek(y)
		if (c == 0 || c == 10): break
		if (flow && (c == ',' || c == ']' || c == '}')): break
		if (c == '#' && y.pos > start && mm_yaml_at(y, y.pos - 1) <= 32): break
		y.pos = y.pos + 1
	int end = y.pos
	while (end > start && mm_yaml_at(y, end - 1) <= 32): end = end - 1
	# Multi-line bodies tolerate the single-line form's trailing commas.
	if (flow == 0 && end > start && mm_yaml_at(y, end - 1) == ','):
		end = end - 1
		while (end > start && mm_yaml_at(y, end - 1) <= 32): end = end - 1
	char* text = str_copy_range(y.text, start, end)
	mm_yaml_set(y, text, mm_yaml_classify(text))

int mm_yaml_reserved(char* key):
	return strcmp(key, c"__proto__") == 0 || strcmp(key, c"constructor") == 0 || strcmp(key, c"prototype") == 0

# Mapping key: quoted, or plain up to a `:` followed by a space, a line end
# or (in flow context) a flow indicator.
char* mm_yaml_key(mm_yaml* y, int flow):
	int c = mm_yaml_peek(y)
	if (c == '"' || c == 39):
		mm_yaml_quoted(y)
		char* quoted = y.scalar
		y.scalar = 0
		mm_yaml_inline_space(y)
		if (mm_yaml_peek(y) != ':'): mm_yaml_fail(y, y.pos, c"expected colon after metadata key")
		else: y.pos = y.pos + 1
		return quoted
	int start = y.pos
	while (1):
		c = mm_yaml_peek(y)
		if (c == 0 || c == 10): break
		if (c == ':'):
			int next = mm_yaml_at(y, y.pos + 1)
			if (next == 0 || next <= 32 || (flow && (next == ',' || next == '}' || next == ']'))): break
		if (flow && (c == ',' || c == '}' || c == ']')): break
		y.pos = y.pos + 1
	int end = y.pos
	while (end > start && mm_yaml_at(y, end - 1) <= 32): end = end - 1
	if (end == start): mm_yaml_fail(y, start, c"expected metadata key")
	if (mm_yaml_peek(y) != ':'): mm_yaml_fail(y, y.pos, c"expected colon after metadata key")
	else: y.pos = y.pos + 1
	return str_copy_range(y.text, start, end)

void mm_yaml_flow_value(mm_yaml* y, string_builder* out);
void mm_yaml_property(mm_yaml* y, list[mm_property*] props, char* key, char* json);

void mm_yaml_flow_entries(mm_yaml* y, string_builder* out, int close, list[mm_property*] props):
	int first = 1
	while (y.doc.error == 0):
		mm_yaml_flow_space(y)
		int c = mm_yaml_peek(y)
		if (c == close && close != 0):
			y.pos = y.pos + 1
			return
		if (c == 0):
			if (close != 0): mm_yaml_fail(y, y.pos, c"unterminated metadata collection")
			return
		if (close == ']'):
			if (first == 0): string_append_char(out, ',')
			mm_yaml_flow_value(y, out)
			first = 0
		else:
			char* key = mm_yaml_key(y, 1)
			mm_yaml_flow_space(y)
			string_builder* value = string_new()
			c = mm_yaml_peek(y)
			if (c == ',' || c == '}' || c == 0):
				mm_yaml_set(y, strclone(c"null"), MM_VALUE_NULL)
				string_append(value, c"null")
			else: mm_yaml_flow_value(y, value)
			if (y.doc.error == 0 && mm_yaml_reserved(key) == 0):
				if (first == 0): string_append_char(out, ',')
				mm_yaml_json_string(out, key)
				string_append_char(out, ':')
				string_append(out, value.data)
				first = 0
				if (props != 0): mm_yaml_property(y, props, key, value.data)
			string_free(value)
			free(key)
		mm_yaml_flow_space(y)
		c = mm_yaml_peek(y)
		if (c == ','):
			y.pos = y.pos + 1
			continue
		if (c != close || close == 0):
			if (c != 0 || close != 0): mm_yaml_fail(y, y.pos, c"expected comma or end of metadata collection")
			return

void mm_yaml_flow_value(mm_yaml* y, string_builder* out):
	mm_yaml_flow_space(y)
	int c = mm_yaml_peek(y)
	if (c == '[' || c == '{'):
		if (y.depth >= MM_YAML_MAX_DEPTH):
			mm_yaml_fail(y, y.pos, c"metadata nesting limit exceeded")
			return
		y.depth = y.depth + 1
		y.pos = y.pos + 1
		string_builder* nested = string_new()
		int close = '}'
		if (c == '['): close = ']'
		mm_yaml_flow_entries(y, nested, close, 0)
		y.depth = y.depth - 1
		if (c == '['): string_append_char(out, '[')
		else: string_append_char(out, '{')
		string_append(out, nested.data)
		if (c == '['): string_append_char(out, ']')
		else: string_append_char(out, '}')
		int type = MM_VALUE_MAP
		if (c == '['): type = MM_VALUE_LIST
		mm_yaml_set(y, strclone(nested.data), type)
		string_free(nested)
		return
	if (c == '"' || c == 39): mm_yaml_quoted(y)
	else: mm_yaml_plain(y, 1)
	mm_yaml_emit_scalar(y, out)

# Pushes or replaces a top-level property (keys are unique; last one wins).
void mm_yaml_property(mm_yaml* y, list[mm_property*] props, char* key, char* json):
	char* value = json
	if (y.type != MM_VALUE_MAP && y.type != MM_VALUE_LIST): value = y.scalar
	for mm_property* property in props:
		if (strcmp(property.key, key) == 0):
			free(property.value)
			property.value = strclone(value)
			property.type = y.type
			return
	if (props.length >= 64):
		mm_yaml_fail(y, y.pos, c"metadata limit exceeded (64 keys per element)")
		return
	props.push(new mm_property(strclone(key), strclone(value), y.type))

int mm_yaml_line_start(mm_yaml* y, int at):
	while (at > 0 && mm_yaml_at(y, at - 1) != 10): at = at - 1
	return at

int mm_yaml_indent(mm_yaml* y, int at):
	int column = 0
	while (mm_yaml_at(y, at) == 32 || mm_yaml_at(y, at) == 9):
		if (mm_yaml_at(y, at) == 9): column = column + 4
		else: column = column + 1
		at = at + 1
	return column

int mm_yaml_content(mm_yaml* y, int at):
	while (mm_yaml_at(y, at) == 32 || mm_yaml_at(y, at) == 9 || mm_yaml_at(y, at) == 13): at = at + 1
	return at

# Moves to the start of the next line holding content other than a comment.
void mm_yaml_next_line(mm_yaml* y):
	while (y.pos < y.length):
		int content = mm_yaml_content(y, y.pos)
		int c = mm_yaml_at(y, content)
		if (c != 10 && c != 0 && c != '#'): return
		while (mm_yaml_peek(y) != 0 && mm_yaml_peek(y) != 10): y.pos = y.pos + 1
		if (mm_yaml_peek(y) == 10): y.pos = y.pos + 1

# Rest of the line after a value: spaces, an optional trailing comma and a comment.
void mm_yaml_line_end(mm_yaml* y):
	mm_yaml_inline_space(y)
	if (mm_yaml_peek(y) == ','):
		y.pos = y.pos + 1
		mm_yaml_inline_space(y)
	if (mm_yaml_peek(y) == '#'):
		while (mm_yaml_peek(y) != 0 && mm_yaml_peek(y) != 10): y.pos = y.pos + 1
	if (mm_yaml_peek(y) == 10): y.pos = y.pos + 1
	else if (mm_yaml_peek(y) != 0): mm_yaml_fail(y, y.pos, c"unexpected text after metadata value")

# `|` literal or `>` folded block scalar, with optional - / + chomping.
void mm_yaml_block_scalar(mm_yaml* y, int indent):
	int folded = mm_yaml_peek(y) == '>'
	y.pos = y.pos + 1
	int chomp = 0
	if (mm_yaml_peek(y) == '-'): chomp = -1
	if (mm_yaml_peek(y) == '+'): chomp = 1
	if (chomp != 0): y.pos = y.pos + 1
	mm_yaml_line_end(y)
	string_builder* text = string_new()
	int content_indent = -1
	int pending = 0
	int any = 0
	while (y.pos < y.length && y.doc.error == 0):
		int content = mm_yaml_content(y, y.pos)
		int c = mm_yaml_at(y, content)
		if (c == 10 || c == 0):
			pending = pending + 1
			y.pos = content
			if (c == 10): y.pos = y.pos + 1
			continue
		int column = mm_yaml_indent(y, y.pos)
		if (content_indent < 0):
			if (column <= indent): break
			content_indent = column
		if (column < content_indent): break
		if (any && folded && pending == 0): string_append_char(text, 32)
		else if (any && folded == 0): string_append_char(text, 10)
		for i in range(pending): string_append_char(text, 10)
		pending = 0
		# Indentation beyond the content indent is content.
		int skip = 0
		int at = y.pos
		while (skip < content_indent && (mm_yaml_at(y, at) == 32 || mm_yaml_at(y, at) == 9)):
			if (mm_yaml_at(y, at) == 9): skip = skip + 4
			else: skip = skip + 1
			at = at + 1
		int end = at
		while (mm_yaml_at(y, end) != 0 && mm_yaml_at(y, end) != 10): end = end + 1
		int stop = end
		while (stop > at && mm_yaml_at(y, stop - 1) == 13): stop = stop - 1
		string_append_bytes(text, y.text + at, stop - at)
		any = 1
		y.pos = end
		if (mm_yaml_peek(y) == 10): y.pos = y.pos + 1
	if (any && chomp != -1): string_append_char(text, 10)
	if (chomp == 1):
		for i in range(pending): string_append_char(text, 10)
	mm_yaml_set(y, strclone(text.data), MM_VALUE_STRING)
	string_free(text)

int mm_yaml_column(mm_yaml* y, int at):
	int start = mm_yaml_line_start(y, at)
	int column = mm_yaml_indent(y, start)
	int content = mm_yaml_content(y, start)
	if (at < content): return column
	return column + at - content

void mm_yaml_block_map(mm_yaml* y, string_builder* out, int indent, int inline_first, list[mm_property*] props);
void mm_yaml_block_list(mm_yaml* y, string_builder* out, int indent, int inline_first);
int mm_yaml_entry_here(mm_yaml* y);

# A value after `key:` or `- ` on a line whose entries sit at column `indent`.
void mm_yaml_item(mm_yaml* y, string_builder* out, int indent):
	mm_yaml_inline_space(y)
	int c = mm_yaml_peek(y)
	if (c == 0 || c == 10 || c == '#'):
		mm_yaml_line_end(y)
		int save = y.pos
		mm_yaml_next_line(y)
		if (y.pos < y.length):
			int column = mm_yaml_indent(y, y.pos)
			int content = mm_yaml_content(y, y.pos)
			int dash = mm_yaml_at(y, content) == '-' && mm_yaml_at(y, content + 1) <= 32
			if (column > indent || (column == indent && dash)):
				if (dash): mm_yaml_block_list(y, out, column, 0)
				else: mm_yaml_block_map(y, out, column, 0, 0)
				return
		y.pos = save
		mm_yaml_set(y, strclone(c"null"), MM_VALUE_NULL)
		string_append(out, c"null")
		return
	if (c == '|' || c == '>'):
		mm_yaml_block_scalar(y, indent)
		mm_yaml_emit_scalar(y, out)
		return
	if (c == '-' && mm_yaml_at(y, y.pos + 1) <= 32):
		mm_yaml_block_list(y, out, mm_yaml_column(y, y.pos), 1)
		return
	if (mm_yaml_entry_here(y)):
		mm_yaml_block_map(y, out, mm_yaml_column(y, y.pos), 1, 0)
		return
	mm_yaml_flow_value(y, out)
	mm_yaml_line_end(y)

# True when the rest of the line is a `key:` mapping entry.
int mm_yaml_entry_here(mm_yaml* y):
	int at = y.pos
	int c = mm_yaml_at(y, at)
	if (c == '"' || c == 39):
		at = at + 1
		while (mm_yaml_at(y, at) != 0 && mm_yaml_at(y, at) != 10 && mm_yaml_at(y, at) != c): at = at + 1
		at = at + 1
		while (mm_yaml_at(y, at) == 32 || mm_yaml_at(y, at) == 9): at = at + 1
		return mm_yaml_at(y, at) == ':'
	if (c == '[' || c == '{' || c == '-' || c == '|' || c == '>' || c == '#'): return 0
	while (mm_yaml_at(y, at) != 0 && mm_yaml_at(y, at) != 10):
		if (mm_yaml_at(y, at) == ':' && mm_yaml_at(y, at + 1) <= 32): return 1
		if (mm_yaml_at(y, at) == '#' && mm_yaml_at(y, at - 1) <= 32): return 0
		at = at + 1
	return 0

# Entries of a block mapping at column `indent`. With inline_first the first
# key starts at y.pos in the middle of a line (`- key: value` or `@{ key:`).
void mm_yaml_block_map(mm_yaml* y, string_builder* out, int indent, int inline_first, list[mm_property*] props):
	if (y.depth >= MM_YAML_MAX_DEPTH):
		mm_yaml_fail(y, y.pos, c"metadata nesting limit exceeded")
		return
	y.depth = y.depth + 1
	string_builder* entries = string_new()
	int first = 1
	int here = inline_first
	while (y.doc.error == 0):
		if (here == 0):
			mm_yaml_next_line(y)
			if (y.pos >= y.length): break
			int column = mm_yaml_indent(y, y.pos)
			if (column < indent): break
			int content = mm_yaml_content(y, y.pos)
			if (column > indent):
				mm_yaml_fail(y, content, c"inconsistent metadata indentation")
				break
			if (mm_yaml_at(y, content) == '-' && mm_yaml_at(y, content + 1) <= 32): break
			y.pos = content
		here = 0
		char* key = mm_yaml_key(y, 0)
		string_builder* value = string_new()
		if (y.doc.error == 0): mm_yaml_item(y, value, indent)
		if (y.doc.error == 0 && mm_yaml_reserved(key) == 0):
			if (first == 0): string_append_char(entries, ',')
			mm_yaml_json_string(entries, key)
			string_append_char(entries, ':')
			string_append(entries, value.data)
			first = 0
			if (props != 0): mm_yaml_property(y, props, key, value.data)
		string_free(value)
		free(key)
	y.depth = y.depth - 1
	string_append_char(out, '{')
	string_append(out, entries.data)
	string_append_char(out, '}')
	mm_yaml_set(y, strclone(entries.data), MM_VALUE_MAP)
	string_free(entries)

# A sequence of `- item` lines at column `indent`.
void mm_yaml_block_list(mm_yaml* y, string_builder* out, int indent, int inline_first):
	if (y.depth >= MM_YAML_MAX_DEPTH):
		mm_yaml_fail(y, y.pos, c"metadata nesting limit exceeded")
		return
	y.depth = y.depth + 1
	string_builder* items = string_new()
	int first = 1
	int here = inline_first
	while (y.doc.error == 0):
		if (here == 0):
			mm_yaml_next_line(y)
			if (y.pos >= y.length): break
			int column = mm_yaml_indent(y, y.pos)
			int content = mm_yaml_content(y, y.pos)
			if (column != indent || mm_yaml_at(y, content) != '-' || mm_yaml_at(y, content + 1) > 32): break
			y.pos = content
		here = 0
		y.pos = y.pos + 1
		mm_yaml_inline_space(y)
		if (first == 0): string_append_char(items, ',')
		first = 0
		mm_yaml_item(y, items, indent)
	y.depth = y.depth - 1
	string_append_char(out, '[')
	string_append(out, items.data)
	string_append_char(out, ']')
	mm_yaml_set(y, strclone(items.data), MM_VALUE_LIST)
	string_free(items)

# Parses source[start, end) (the text between `@{` and its closing brace) into
# top-level properties; errors go to the document at their source offset.
list[mm_property*] mm_yaml_parse(mm_document* d, int start, int end):
	list[mm_property*] props = new list[mm_property*]
	mm_yaml y
	y.text = str_copy_range(d.source, start, end)
	y.length = end - start
	y.pos = 0
	y.base = start
	y.doc = d
	y.depth = 0
	y.scalar = 0
	y.type = 0
	string_builder* out = string_new()
	if (index_of(y.text, c"\n") < 0): mm_yaml_flow_entries(&y, out, 0, props)
	else:
		mm_yaml_inline_space(&y)
		int inline_first = mm_yaml_peek(&y) != 10 && mm_yaml_peek(&y) != '#' && mm_yaml_peek(&y) != 0
		int key_pos = y.pos
		int indent = 0
		if (inline_first):
			while (mm_yaml_peek(&y) != 0 && mm_yaml_peek(&y) != 10): y.pos = y.pos + 1
			mm_yaml_next_line(&y)
			if (y.pos < y.length): indent = mm_yaml_indent(&y, y.pos)
			y.pos = key_pos
		else:
			mm_yaml_next_line(&y)
			if (y.pos < y.length): indent = mm_yaml_indent(&y, y.pos)
		if (y.pos < y.length): mm_yaml_block_map(&y, out, indent, inline_first, props)
		mm_yaml_next_line(&y)
		if (d.error == 0 && y.pos < y.length): mm_yaml_fail(&y, y.pos, c"inconsistent metadata indentation")
	string_free(out)
	if (y.scalar != 0): free(y.scalar)
	free(y.text)
	return props

# Offset of the brace closing an `@{` block whose body starts at `start`:
# braces and brackets nest, quoted text and comments are skipped. -1 if none.
int mm_yaml_close(mm_document* d, int start):
	int depth = 0
	int at = start
	while (at < d.length):
		int c = d.source[at] & 255
		if (c == '"' || c == 39):
			at = at + 1
			while (at < d.length && (d.source[at] & 255) != c):
				if (c == '"' && d.source[at] == '\\'): at = at + 1
				at = at + 1
		else if (c == '#' && (at == start || (d.source[at - 1] & 255) <= 32)):
			while (at < d.length && d.source[at] != 10): at = at + 1
			continue
		else if (c == '{' || c == '['): depth = depth + 1
		else if (c == ']'): depth = depth - 1
		else if (c == '}'):
			if (depth == 0): return at
			depth = depth - 1
		at = at + 1
	return -1

void mm_properties_free(list[mm_property*] props):
	for mm_property* property in props:
		free(property.key)
		free(property.value)
		free(property)
	__w_list_free(cast(__w_list*, props))
