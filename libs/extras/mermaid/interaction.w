# Interaction statements shared by flowcharts and class diagrams, against
# Mermaid 12.2.0: `click ID callback|call fn(args)|href "url"|"url" ["tooltip"] [target]`
# and the class-only `link ID "url"` / `callback ID "fn"` spellings. Callbacks
# are kept as text and never executed; links become SVG anchors only for safe
# schemes (see mm_link_safe).
import libs.extras.mermaid.parse_common
import libs.extras.mermaid.style

const int MM_MAX_LINK = 2048

# Relative references, fragments and http(s)/mailto URLs; never script or data URLs.
int mm_link_safe(char* url):
	if (url == 0 || url[0] == 0): return 0
	int i = 0
	while (url[i] != 0):
		int c = url[i] & 255
		if (c <= 32 || c == '"' || c == '<' || c == '>' || c == '\\' || c == '`'): return 0
		i = i + 1
	int colon = index_of(url, c":")
	if (colon < 0): return 1
	int slash = index_of(url, c"/")
	int query = index_of(url, c"?")
	int hash = index_of(url, c"#")
	if ((slash >= 0 && slash < colon) || (query >= 0 && query < colon) || (hash >= 0 && hash < colon)): return 1
	return index_of(url, c"http://") == 0 || index_of(url, c"https://") == 0 || index_of(url, c"mailto:") == 0

void mm_interaction_set(char** field, char* value):
	if (field[0] != 0): free(field[0])
	field[0] = value

# Optional quoted tooltip followed by an optional link target.
void mm_interaction_tail(mm_parser* p, mm_node* n, int allow_target):
	mm_space(p)
	if (mm_peek(p) == '"'):
		char* tooltip = mm_quoted(p)
		mm_interaction_set(&n.tooltip, tooltip)
		mm_space(p)
	if (mm_end(p)): return
	int start = p.pos
	while (mm_end(p) == 0 && mm_peek(p) != 32 && mm_peek(p) != 9): p.pos = p.pos + 1
	char* target = str_copy_range(p.doc.source, start, p.pos)
	int valid = strcmp(target, c"_self") == 0 || strcmp(target, c"_blank") == 0 || strcmp(target, c"_parent") == 0 || strcmp(target, c"_top") == 0
	if (allow_target == 0 || valid == 0):
		free(target)
		mm_error(p.doc, start, c"expected link target _self, _blank, _parent or _top")
		return
	mm_interaction_set(&n.link_target, target)

char* mm_interaction_url(mm_parser* p):
	mm_space(p)
	if (mm_peek(p) != '"'):
		mm_error(p.doc, p.pos, c"expected quoted link URL")
		return strclone(c"")
	char* url = mm_quoted(p)
	if (strlen(url) > MM_MAX_LINK): mm_error(p.doc, p.pos, c"link URL limit exceeded")
	return url

# `call name(args)`: the callback text runs to the matching parenthesis.
char* mm_interaction_call(mm_parser* p):
	mm_space(p)
	int start = p.pos
	while (mm_id_char(mm_peek(p)) || mm_peek(p) == '.' || mm_peek(p) == '$'): p.pos = p.pos + 1
	if (p.pos == start): mm_error(p.doc, start, c"expected callback name")
	mm_space(p)
	if (mm_peek(p) == '('):
		int depth = 0
		int quoted = 0
		while (mm_peek(p) != 0 && mm_peek(p) != 10):
			int c = mm_peek(p)
			p.pos = p.pos + 1
			if (c == '"'): quoted = 1 - quoted
			else if (quoted == 0 && c == '('): depth = depth + 1
			else if (quoted == 0 && c == ')'):
				depth = depth - 1
				if (depth == 0): break
		if (depth != 0): mm_error(p.doc, start, c"unbalanced callback arguments")
	char* text = mm_style_trim(p.doc.source, start, p.pos)
	if (strlen(text) > MM_MAX_LINK): mm_error(p.doc, start, c"callback limit exceeded")
	return text

# After the `click`/`link`/`callback` keyword. kind 0 click, 1 link, 2 callback.
int mm_interaction_node(mm_parser* p):
	int at = p.pos
	char* id = mm_identifier(p)
	if (p.doc.error != 0):
		free(id)
		return -1
	int index = mm_find_node(p.doc, id)
	free(id)
	if (index < 0): mm_error(p.doc, at, c"interaction requires a declared node")
	return index

void mm_interaction_statement(mm_parser* p, int kind):
	int index = mm_interaction_node(p)
	if (index < 0): return
	mm_node* n = p.doc.nodes[index]
	mm_space(p)
	if (kind == 1):
		mm_interaction_set(&n.link, mm_interaction_url(p))
		mm_interaction_tail(p, n, 1)
		return
	if (kind == 2):
		if (mm_peek(p) == '"'): mm_interaction_set(&n.callback, mm_quoted(p))
		else: mm_interaction_set(&n.callback, mm_interaction_call(p))
		mm_interaction_tail(p, n, 0)
		return
	if (mm_style_keyword(p, c"href")):
		mm_interaction_set(&n.link, mm_interaction_url(p))
		mm_interaction_tail(p, n, 1)
	else if (mm_peek(p) == '"'):
		mm_interaction_set(&n.link, mm_interaction_url(p))
		mm_interaction_tail(p, n, 1)
	else:
		mm_style_keyword(p, c"call")
		mm_interaction_set(&n.callback, mm_interaction_call(p))
		mm_interaction_tail(p, n, 0)
