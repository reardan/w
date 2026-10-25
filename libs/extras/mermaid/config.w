# Bounded Mermaid configuration from YAML-ish frontmatter and leading
# %%{init: ...}%% / %%{initialize: ...}%% directives. Both sources become flat
# dotted-path entries ("config.themeVariables.primaryColor"), validated and
# applied by one pass; a later source overrides an earlier one key by key.
import libs.extras.mermaid.model
import libs.extras.mermaid.style

const int MM_CONFIG_MAX_ENTRIES = 256
const int MM_CONFIG_MAX_DEPTH = 4

struct mm_config_entry:
	char* path
	char* value
	int map
	int offset
	int origin

struct mm_config_reader:
	mm_document* doc
	list[mm_config_entry*] entries
	int origin
	int pos
	int end

int mm_config_line_end(mm_document* d, int start, int limit):
	int end = start
	while (end < limit && d.source[end] != 10): end = end + 1
	return end

char* mm_config_trim(mm_document* d, int start, int end):
	while (start < end && (d.source[start] == 32 || d.source[start] == 9 || d.source[start] == 13)): start = start + 1
	while (end > start && (d.source[end - 1] == 32 || d.source[end - 1] == 9 || d.source[end - 1] == 13)): end = end - 1
	return str_copy_range(d.source, start, end)

char* mm_config_join(char* prefix, char* key):
	string_builder* s = string_from(prefix)
	string_append(s, key)
	char* result = s.data
	free(s)
	return result

# Takes ownership of value.
void mm_config_add(mm_config_reader* r, char* path, char* value, int map, int offset):
	int depth = 1
	for i in range(strlen(path)):
		if (path[i] == '.'): depth = depth + 1
	if (r.entries.length >= MM_CONFIG_MAX_ENTRIES): mm_error(r.doc, offset, c"configuration entry limit exceeded")
	else if (depth > MM_CONFIG_MAX_DEPTH): mm_error(r.doc, offset, c"configuration nesting too deep")
	if (r.doc.error != 0):
		free(value)
		return
	mm_config_entry* e = new mm_config_entry()
	e.path = strclone(path)
	e.value = value
	e.map = map
	e.offset = offset
	e.origin = r.origin
	r.entries.push(e)

char* mm_source_title(mm_document* d, int start, int end):
	char* value = mm_config_trim(d, start, end)
	int length = strlen(value)
	if (length > 0 && (value[0] == '"' || value[0] == '\'')):
		int quote = value[0]
		if (length < 2 || value[length - 1] != quote): mm_error(d, start, c"unterminated frontmatter title")
		else:
			for i in range(1, length - 1):
				if (value[i] == '\\' || value[i] == quote): mm_error(d, start + i, c"escaped YAML title values are not yet supported")
			char* inner = str_copy_range(value, 1, length - 1)
			free(value)
			value = inner
	else:
		if (length > 0 && (value[0] == '|' || value[0] == '>' || value[0] == '{' || value[0] == '[' || value[0] == '&' || value[0] == '*')): mm_error(d, start, c"frontmatter title must be a scalar string")
		for i in range(length):
			if (value[i] == '#' && (i == 0 || value[i - 1] == 32)):
				int stop = i
				while (stop > 0 && value[stop - 1] == 32): stop = stop - 1
				value[stop] = 0
				break
	return value

# YAML scalar: 'single' or "double" quoted (no escapes) or plain, with an
# optional trailing # comment. *quoted reports whether quotes were present.
char* mm_config_scalar(mm_document* d, int start, int end, int* quoted):
	char* value = mm_config_trim(d, start, end)
	*quoted = 0
	int length = strlen(value)
	while (start < end && (d.source[start] == 32 || d.source[start] == 9)): start = start + 1
	if (length > 0 && (value[0] == '"' || value[0] == '\'')):
		int quote = value[0]
		int close = 1
		while (close < length && value[close] != quote):
			if (value[close] == '\\' && quote == '"'): mm_error(d, start + close, c"escaped configuration strings are not supported")
			close = close + 1
		if (close >= length): mm_error(d, start, c"unterminated quoted configuration value")
		else:
			int rest = close + 1
			while (rest < length && value[rest] == 32): rest = rest + 1
			if (rest < length && (value[rest] != '#' || rest == close + 1)): mm_error(d, start + rest, c"unexpected text after quoted configuration value")
		*quoted = 1
		char* inner = str_copy_range(value, 1, close)
		free(value)
		return inner
	if (length > 0 && (value[0] == '|' || value[0] == '>' || value[0] == '[' || value[0] == '&' || value[0] == '*' || value[0] == '!')): mm_error(d, start, c"unsupported YAML value in frontmatter")
	for i in range(length):
		if (value[i] == '#' && (i == 0 || value[i - 1] == 32 || value[i - 1] == 9)):
			int stop = i
			while (stop > 0 && (value[stop - 1] == 32 || value[stop - 1] == 9)): stop = stop - 1
			value[stop] = 0
			break
	return value

void mm_config_space(mm_config_reader* r):
	while (r.pos < r.end):
		int c = r.doc.source[r.pos]
		if (c != 32 && c != 9 && c != 13 && c != 10): return
		r.pos = r.pos + 1

int mm_config_peek(mm_config_reader* r):
	if (r.pos < r.end): return r.doc.source[r.pos]
	return 0

# A quoted string or a bare token (identifier, number, boolean, #hex).
char* mm_config_token(mm_config_reader* r):
	char* source = r.doc.source
	int c = mm_config_peek(r)
	if (c == '"' || c == '\''):
		int start = r.pos + 1
		int at = start
		while (at < r.end && source[at] != c && source[at] != 10):
			if (source[at] == '\\'):
				mm_error(r.doc, at, c"escaped configuration strings are not supported")
				return strclone(c"")
			at = at + 1
		if (at >= r.end || source[at] != c):
			mm_error(r.doc, r.pos, c"unterminated configuration string")
			return strclone(c"")
		r.pos = at + 1
		return str_copy_range(source, start, at)
	int start = r.pos
	while (r.pos < r.end):
		int k = source[r.pos]
		if (isalnum(k) == 0 && k != '_' && k != '-' && k != '.' && k != '#' && k != '+'): break
		r.pos = r.pos + 1
	if (r.pos == start): mm_error(r.doc, start, c"expected configuration key or value")
	return str_copy_range(source, start, r.pos)

# JSON-ish object at r.pos ('{'): quoted or bare keys, scalar or object values.
void mm_config_object(mm_config_reader* r, char* prefix):
	r.pos = r.pos + 1
	mm_config_space(r)
	if (mm_config_peek(r) == '}'):
		r.pos = r.pos + 1
		return
	while (r.doc.error == 0):
		mm_config_space(r)
		int at = r.pos
		char* key = mm_config_token(r)
		mm_config_space(r)
		if (r.doc.error == 0 && mm_config_peek(r) != ':'): mm_error(r.doc, r.pos, c"configuration key requires colon")
		if (r.doc.error != 0):
			free(key)
			return
		r.pos = r.pos + 1
		mm_config_space(r)
		char* path = mm_config_join(prefix, key)
		free(key)
		if (mm_config_peek(r) == '{'):
			mm_config_add(r, path, strclone(c""), 1, at)
			char* child = mm_config_join(path, c".")
			if (r.doc.error == 0): mm_config_object(r, child)
			free(child)
		else if (mm_config_peek(r) == '['): mm_error(r.doc, r.pos, c"configuration arrays are not supported")
		else: mm_config_add(r, path, mm_config_token(r), 0, at)
		free(path)
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

int mm_config_key_char(int c):
	return isalnum(c) || c == '_' || c == '-'

# One "key: value" frontmatter line at its validated indentation. Returns the
# child prefix when the line opens a nested block mapping, otherwise 0.
char* mm_config_yaml_line(mm_config_reader* r, int line, int at, int end, char* prefix):
	mm_document* d = r.doc
	if (d.source[at] == '-' && (at + 1 == end || d.source[at + 1] == 32)):
		mm_error(d, line, c"frontmatter lists are not supported")
		return 0
	int colon = at
	int quote = 0
	if (d.source[at] == '"' || d.source[at] == '\''): quote = d.source[at]
	if (quote):
		colon = at + 1
		while (colon < end && d.source[colon] != quote): colon = colon + 1
	while (colon < end && d.source[colon] != ':'): colon = colon + 1
	if (colon >= end):
		mm_error(d, line, c"frontmatter entry requires key: value")
		return 0
	char* key = mm_config_trim(d, at, colon)
	int length = strlen(key)
	if (quote && length >= 2 && key[length - 1] == quote):
		char* inner = str_copy_range(key, 1, length - 1)
		free(key)
		key = inner
		length = strlen(key)
	int valid = length > 0
	for i in range(length):
		if (mm_config_key_char(key[i] & 255) == 0): valid = 0
	if (valid == 0):
		free(key)
		mm_error(d, line, c"invalid frontmatter key")
		return 0
	char* path = mm_config_join(prefix, key)
	free(key)
	char* child = 0
	int start = colon + 1
	while (start < end && (d.source[start] == 32 || d.source[start] == 9)): start = start + 1
	if (strcmp(path, c"title") == 0): mm_config_add(r, path, mm_source_title(d, colon + 1, end), 0, line)
	else if (start < end && d.source[start] == '{'):
		mm_config_add(r, path, strclone(c""), 1, line)
		r.pos = start
		r.end = end
		char* nested = mm_config_join(path, c".")
		if (d.error == 0): mm_config_object(r, nested)
		free(nested)
		mm_config_space(r)
		if (d.error == 0 && r.pos < end && d.source[r.pos] != '#'): mm_error(d, r.pos, c"unexpected text after frontmatter mapping")
	else:
		int quoted = 0
		char* value = mm_config_scalar(d, colon + 1, end, &quoted)
		if (value[0] == 0 && quoted == 0):
			mm_config_add(r, path, value, 1, line)
			child = mm_config_join(path, c".")
		else: mm_config_add(r, path, value, 0, line)
	free(path)
	return child

void mm_config_free_stack(list[int] indents, list[char*] prefixes):
	for char* prefix in prefixes: free(prefix)
	__w_list_free(cast(__w_list*, indents))
	__w_list_free(cast(__w_list*, prefixes))

# Block mappings at any consistent space indentation, # comments, quoted and
# plain scalars, and inline {flow} mappings.
void mm_config_frontmatter(mm_config_reader* r):
	mm_document* d = r.doc
	int pos = d.source_start
	int end = mm_config_line_end(d, pos, d.source_end)
	char* line = mm_config_trim(d, pos, end)
	int present = strcmp(line, c"---") == 0
	free(line)
	if (present == 0): return
	pos = end + 1
	list[int] indents = new list[int]
	list[char*] prefixes = new list[char*]
	indents.push(0)
	prefixes.push(strclone(c""))
	char* pending = 0
	while (pos < d.source_end && d.error == 0):
		end = mm_config_line_end(d, pos, d.source_end)
		line = mm_config_trim(d, pos, end)
		if (strcmp(line, c"---") == 0):
			free(line)
			free(pending)
			mm_config_free_stack(indents, prefixes)
			d.source_start = end
			if (end < d.source_end): d.source_start = end + 1
			return
		if (line[0] != 0 && line[0] != '#'):
			int at = pos
			while (at < end && d.source[at] == 32): at = at + 1
			int indent = at - pos
			if (d.source[at] == 9): mm_error(d, at, c"frontmatter indentation must use spaces")
			if (pending != 0):
				if (indent > indents[indents.length - 1]):
					indents.push(indent)
					prefixes.push(pending)
				else: free(pending)
				pending = 0
			while (indents.length > 1 && indent < indents[indents.length - 1]):
				indents.pop()
				free(prefixes.pop())
			if (indent != indents[indents.length - 1]): mm_error(d, pos, c"inconsistent frontmatter indentation")
			if (d.error == 0): pending = mm_config_yaml_line(r, pos, at, end, prefixes[prefixes.length - 1])
		free(line)
		pos = end + 1
	free(pending)
	mm_config_free_stack(indents, prefixes)
	if (d.error == 0): mm_error(d, d.source_start, c"unterminated frontmatter")

# Directives before the diagram header, after any frontmatter, possibly
# spanning lines and interleaved with %% comments and blank lines.
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
		r.origin = r.origin + 1
		r.pos = at + 3
		r.end = d.source_end
		mm_config_space(r)
		char* kind = mm_config_token(r)
		if (d.error == 0 && strcmp(kind, c"init") != 0 && strcmp(kind, c"initialize") != 0): mm_error(d, at, c"unsupported Mermaid directive; supported: init, initialize")
		free(kind)
		mm_config_space(r)
		if (d.error == 0 && mm_config_peek(r) != ':'): mm_error(d, r.pos, c"Mermaid directive requires colon")
		r.pos = r.pos + 1
		mm_config_space(r)
		if (d.error == 0 && mm_config_peek(r) != '{'): mm_error(d, r.pos, c"init directive requires an object")
		if (d.error == 0): mm_config_object(r, c"config.")
		mm_config_space(r)
		if (d.error == 0 && (r.pos + 2 >= r.end || d.source[r.pos] != '}' || d.source[r.pos + 1] != '%' || d.source[r.pos + 2] != '%')): mm_error(d, at, c"unterminated Mermaid directive")
		if (d.error != 0): return
		r.pos = r.pos + 3
		end = mm_config_line_end(d, r.pos, d.source_end)
		for i in range(r.pos, end):
			if (d.source[i] != 32 && d.source[i] != 9 && d.source[i] != 13):
				mm_error(d, i, c"unexpected text after Mermaid directive")
				return
		pos = end + 1
		consumed = pos
	if (consumed > d.source_end): consumed = d.source_end
	if (consumed >= 0): d.source_start = consumed

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

# key is the path below "config.".
void mm_config_key(mm_document* d, mm_config_entry* e, char* key, list[int] user, int* theme, int* dark):
	char* value = e.value
	if (mm_style_config_key(d, key, value, e.map, e.offset)): return
	if (strcmp(key, c"packet") == 0 ||strcmp(key, c"themeVariables") == 0 || strcmp(key, c"flowchart") == 0 || strcmp(key, c"kanban") == 0):
		if (e.map == 0): mm_error(d, e.offset, c"configuration section must be a mapping")
	else if (strcmp(key, c"theme") == 0):
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
	else if (index_of(key, c"packet.") == 0): mm_error(d, e.offset, c"unsupported packet setting")
	else if (strcmp(key, c"kanban.ticketBaseUrl") == 0):
		if (mm_config_scalar_entry(d, e)):
			if (index_of(value, c"https://") != 0 && index_of(value, c"http://") != 0): mm_error(d, e.offset, c"ticketBaseUrl must be an http or https URL")
			else:
				if (d.ticket_base_url != 0): free(d.ticket_base_url)
				d.ticket_base_url = strclone(value)
	else if (index_of(key, c"kanban.") == 0): mm_error(d, e.offset, c"unsupported kanban setting; supported: ticketBaseUrl")
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
	else if (index_of(key, c"flowchart.") == 0): mm_error(d, e.offset, c"unsupported flowchart setting; supported: nodeSpacing, rankSpacing, curve")
	else: mm_error(d, e.offset, c"unsupported configuration key")

void mm_config_apply(mm_config_reader* r):
	mm_document* d = r.doc
	int present = 0
	int theme = 0
	int dark = -1
	list[int] user = new list[int]
	for i in range(MM_THEME_COUNT): user.push(MM_THEME_UNSET)
	for i in range(r.entries.length):
		if (d.error != 0): break
		mm_config_entry* e = r.entries[i]
		for j in range(i):
			mm_config_entry* other = r.entries[j]
			if (other.origin == e.origin && strcmp(other.path, e.path) == 0): mm_error(d, e.offset, mm_config_duplicate(e.path))
		if (d.error != 0): break
		if (strcmp(e.path, c"title") == 0 && e.origin == 0):
			free(d.title)
			d.title = strclone(e.value)
		else if (strcmp(e.path, c"config") == 0):
			present = 1
			if (e.map == 0): mm_error(d, e.offset, c"configuration section must be a mapping")
		else if (index_of(e.path, c"config.") == 0):
			present = 1
			mm_config_key(d, e, e.path + 7, user, &theme, &dark)
		else: mm_error(d, e.offset, c"unsupported frontmatter field")
	if (d.error == 0 && present): mm_style_theme_resolve(d, theme, user, dark)
	__w_list_free(cast(__w_list*, user))

# Read frontmatter, then leading directives, then validate and apply both.
void mm_config_read(mm_document* d):
	mm_config_reader r
	r.doc = d
	r.entries = new list[mm_config_entry*]
	r.origin = 0
	r.pos = 0
	r.end = 0
	mm_config_frontmatter(&r)
	if (d.error == 0): mm_config_directives(&r)
	if (d.error == 0): mm_config_apply(&r)
	for mm_config_entry* e in r.entries:
		free(e.path)
		free(e.value)
		free(e)
	__w_list_free(cast(__w_list*, r.entries))
