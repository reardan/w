# Owned, bounded CSS Syntax subset. See syntax.md and docs/projects/css.md.
import lib.lib
import lib.str
import lib.hex
import lib.utf8
import structures.string


struct css_limits:
	int source_bytes
	int tokens
	int nodes
	int depth
	int diagnostics


struct css_token:
	char* kind
	char* value
	int value_length
	int start
	int end
	int match


struct css_diagnostic:
	char* message
	int start
	int end


# Token ranges and byte spans are half-open. Node values remain tokens;
# property names and at-keywords are decoded in name. Children own nodes.
struct css_node:
	char* kind
	char* name
	int start
	int end
	int first
	int last
	int important
	list[css_node*] children


struct css_document:
	char* source
	int length
	css_limits* limits
	list[css_token*] tokens
	list[css_node*] nodes
	list[css_diagnostic*] diagnostics
	int node_count
	int failed


css_limits* css_default_limits():
	return new css_limits(1048576, 131072, 65536, 128, 256)


void css_error(css_document* d, char* message, int start, int end):
	if (d.diagnostics.length < d.limits.diagnostics):
		d.diagnostics.push(new css_diagnostic(strclone(message), start, end))


int css_space(int c):
	return c == ' ' || c == 9 || c == 10 || c == 13 || c == 12


int css_digit(int c):
	return c >= '0' && c <= '9'


int css_name_start(int c):
	return c == '_' || c >= 128 || c == 0 || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')


int css_name_char(int c):
	return css_name_start(c) || css_digit(c) || c == '-'


int css_at(css_document* d, int pos):
	if (pos < 0 || pos >= d.length): return -1
	return d.source[pos] & 255


int css_escape_start(css_document* d, int pos):
	int c = css_at(d, pos + 1)
	return css_at(d, pos) == '\\' && c != 10 && c != 13 && c != 12


int css_ident_start(css_document* d, int pos):
	int c = css_at(d, pos)
	if (css_name_start(c) || css_escape_start(d, pos)): return 1
	if (c != '-'): return 0
	c = css_at(d, pos + 1)
	return css_name_start(c) || c == '-' || css_escape_start(d, pos + 1)


void css_append_codepoint(string_builder* out, int cp):
	if (cp == 0 || cp > 1114111 || (cp >= 55296 && cp <= 57343)): cp = 65533
	char* buffer = cast(char*, malloc(4))
	int n = utf8_encode(buffer, cp)
	string_append_bytes(out, buffer, n)
	free(buffer)


# Consumes the backslash and up to six hex digits, including one trailing
# whitespace codepoint. CRLF is one whitespace codepoint.
int css_escape(css_document* d, int pos, string_builder* out):
	pos = pos + 1
	int c = css_at(d, pos)
	int h = hex_decode_char(c)
	if (h >= 0):
		int cp = 0
		int count = 0
		while (h >= 0 && count < 6):
			cp = cp * 16 + h
			pos = pos + 1
			count = count + 1
			h = hex_decode_char(css_at(d, pos))
		css_append_codepoint(out, cp)
		if (css_space(css_at(d, pos))):
			if (css_at(d, pos) == 13 && css_at(d, pos + 1) == 10): pos = pos + 1
			pos = pos + 1
		return pos
	if (c < 0):
		css_error(d, c"EOF in escape", pos - 1, pos)
		css_append_codepoint(out, 65533)
		return pos
	if (c == 0): css_append_codepoint(out, 65533)
	else: string_append_char(out, c)
	return pos + 1


int css_name(css_document* d, int pos, string_builder* out):
	while (pos < d.length):
		int c = css_at(d, pos)
		if (css_name_char(c)):
			if (c == 0): css_append_codepoint(out, 65533)
			else: string_append_char(out, c)
			pos = pos + 1
		else if (css_escape_start(d, pos)): pos = css_escape(d, pos, out)
		else: break
	return pos


css_token* css_emit(css_document* d, char* kind, string_builder* out, int start, int end):
	if (d.tokens.length >= d.limits.tokens):
		css_error(d, c"token limit", start, end)
		d.failed = 1
		string_free(out)
		return 0
	css_token* t = new css_token(strclone(kind), out.data, out.length, start, end, -1)
	free(out)
	d.tokens.push(t)
	return t


int css_number_start(css_document* d, int pos):
	int c = css_at(d, pos)
	if (c == '+' || c == '-'): pos = pos + 1
	if (css_digit(css_at(d, pos))): return 1
	return css_at(d, pos) == '.' && css_digit(css_at(d, pos + 1))


int css_number_end(css_document* d, int pos):
	if (css_at(d, pos) == '+' || css_at(d, pos) == '-'): pos = pos + 1
	while (css_digit(css_at(d, pos))): pos = pos + 1
	if (css_at(d, pos) == '.' && css_digit(css_at(d, pos + 1))):
		pos = pos + 1
		while (css_digit(css_at(d, pos))): pos = pos + 1
	int exp = pos
	if (css_at(d, exp) == 'e' || css_at(d, exp) == 'E'):
		exp = exp + 1
		if (css_at(d, exp) == '+' || css_at(d, exp) == '-'): exp = exp + 1
		if (css_digit(css_at(d, exp))):
			pos = exp + 1
			while (css_digit(css_at(d, pos))): pos = pos + 1
	return pos


int css_kind(css_token* t, char* kind):
	return strcmp(t.kind, kind) == 0


int css_delim(css_token* t, int c):
	return css_kind(t, c"delim") && t.value_length == 1 && t.value[0] == c


int css_ascii_equal(char* a, char* b):
	int i = 0
	while (a[i] != 0 && b[i] != 0):
		int c = a[i] & 255
		if (c >= 'A' && c <= 'Z'): c = c + 32
		if (c != b[i]): return 0
		i = i + 1
	return a[i] == b[i]


# Consume an unquoted URL after its opening parenthesis. Its punctuation is
# data, not component delimiters; malformed URLs recover at the next unescaped
# ')' (or EOF), so internal semicolons cannot become declarations.
int css_url(css_document* d, int pos, int start, string_builder* out, int* bad):
	while (css_space(css_at(d, pos))): pos = pos + 1
	while (pos < d.length):
		int c = css_at(d, pos)
		if (c == ')'): return pos + 1
		if (css_space(c)):
			while (css_space(css_at(d, pos))): pos = pos + 1
			if (css_at(d, pos) == ')'): return pos + 1
			if (pos == d.length): break
			*bad = 1
		else if (c == '"' || c == 39 || c == '(' || (c >= 1 && c <= 8) || c == 11 || (c >= 14 && c <= 31) || c == 127): *bad = 1
		else if (c == '\\'):
			if (css_escape_start(d, pos)): pos = css_escape(d, pos, out)
			else: *bad = 1
		else:
			if (c == 0): css_append_codepoint(out, 65533)
			else: string_append_char(out, c)
			pos = pos + 1
		if (*bad):
			while (pos < d.length && css_at(d, pos) != ')'):
				if (css_escape_start(d, pos)): pos = css_escape(d, pos, out)
				else: pos = pos + 1
			if (pos < d.length): pos = pos + 1
			out.length = 0
			out.data[0] = 0
			css_error(d, c"invalid unquoted URL", start, pos)
			return pos
	css_error(d, c"EOF in URL", start, pos)
	return pos


void css_scan(css_document* d):
	list[int] stack = new list[int]
	int pos = 0
	while (pos < d.length && d.failed == 0):
		int start = pos
		int c = css_at(d, pos)
		string_builder* out = string_new()
		char* kind = c"delim"
		if (css_space(c)):
			kind = c"space"
			while (css_space(css_at(d, pos))): pos = pos + 1
			string_append_char(out, ' ')
		else if (c == '/' && css_at(d, pos + 1) == '*'):
			kind = c"comment"
			pos = pos + 2
			while (pos < d.length && !(css_at(d, pos) == '*' && css_at(d, pos + 1) == '/')): pos = pos + 1
			if (pos == d.length): css_error(d, c"unterminated comment", start, pos)
			else: pos = pos + 2
		else if (c == '"' || c == 39):
			kind = c"string"
			pos = pos + 1
			int closed = 0
			while (pos < d.length):
				int ch = css_at(d, pos)
				if (ch == c):
					pos = pos + 1
					closed = 1
					break
				if (ch == 10 || ch == 13 || ch == 12):
					kind = c"bad-string"
					break
				if (ch == '\\'):
					int next = css_at(d, pos + 1)
					if (next < 0): pos = pos + 1
					else if (next == 10 || next == 13 || next == 12):
						pos = pos + 2
						if (next == 13 && css_at(d, pos) == 10): pos = pos + 1
					else: pos = css_escape(d, pos, out)
				else:
					if (ch == 0): css_append_codepoint(out, 65533)
					else: string_append_char(out, ch)
					pos = pos + 1
			if (closed == 0): css_error(d, c"unterminated string", start, pos)
		else if (css_number_start(d, pos)):
			kind = c"number"
			pos = css_number_end(d, pos)
			string_append_bytes(out, d.source + start, pos - start)
			if (css_ident_start(d, pos)):
				kind = c"dimension"
				pos = css_name(d, pos, out)
			else if (css_at(d, pos) == '%'):
				kind = c"percentage"
				string_append_char(out, '%')
				pos = pos + 1
		else if (css_ident_start(d, pos)):
			kind = c"ident"
			pos = css_name(d, pos, out)
			if (css_ascii_equal(out.data, c"url") && css_at(d, pos) == '('):
				int content = pos + 1
				while (css_space(css_at(d, content))): content = content + 1
				# Quoted URLs retain the existing ident + balanced components API.
				if (css_at(d, content) != '"' && css_at(d, content) != 39):
					kind = c"url"
					string_free(out)
					out = string_new()
					int bad = 0
					pos = css_url(d, pos + 1, start, out, &bad)
					if (bad): kind = c"bad-url"
		else if ((c == '@' && css_ident_start(d, pos + 1)) || (c == '#' && (css_name_char(css_at(d, pos + 1)) || css_escape_start(d, pos + 1)))):
			if (c == '@'): kind = c"at-keyword"
			else: kind = c"hash"
			pos = css_name(d, pos + 1, out)
		else:
			string_append_char(out, c)
			pos = pos + 1
		css_token* t = css_emit(d, kind, out, start, pos)
		if (t == 0): break
		if (css_delim(t, '(') || css_delim(t, '[') || css_delim(t, '{')):
			if (stack.length >= d.limits.depth):
				css_error(d, c"nesting limit", start, pos)
				d.failed = 1
			else: stack.push(d.tokens.length - 1)
		else if (css_delim(t, ')') || css_delim(t, ']') || css_delim(t, '}')):
			int opening = -1
			if (stack.length > 0): opening = stack[stack.length - 1]
			int expected = 0
			if (c == ')'): expected = '('
			if (c == ']'): expected = '['
			if (c == '}'): expected = '{'
			if (opening >= 0 && css_delim(d.tokens[opening], expected)):
				t.match = opening
				d.tokens[opening].match = d.tokens.length - 1
				stack.pop()
			else: css_error(d, c"unmatched closing delimiter", start, pos)
	for i in range(stack.length):
		css_token* t = d.tokens[stack[i]]
		css_error(d, c"unclosed block", t.start, d.length)
	__w_list_free(cast(__w_list*, stack))


# limits is borrowed; the document keeps a copy. All source/token/node/
# diagnostic storage is document-owned, including on errors.
css_document* css_tokenize_n(char* source, int length, css_limits* limits):
	css_document* d = new css_document()
	d.limits = css_default_limits()
	if (limits != 0):
		d.limits.source_bytes = limits.source_bytes
		d.limits.tokens = limits.tokens
		d.limits.nodes = limits.nodes
		d.limits.depth = limits.depth
		d.limits.diagnostics = limits.diagnostics
	d.tokens = new list[css_token*]
	d.nodes = new list[css_node*]
	d.diagnostics = new list[css_diagnostic*]
	if (length < 0 || (source == 0 && length != 0) || d.limits.source_bytes < 0 || length > 16777216 || length > d.limits.source_bytes || d.limits.tokens < 1 || d.limits.nodes < 1 || d.limits.depth < 1 || d.limits.depth > 256 || d.limits.diagnostics < 1):
		d.failed = 1
		css_error(d, c"invalid input or resource limit", 0, 0)
		d.source = strclone(c"")
		return d
	d.length = length
	d.source = cast(char*, malloc(length + 1))
	for i in range(length): d.source[i] = source[i]
	d.source[length] = 0
	css_scan(d)
	return d


int css_trivia(css_token* t):
	return css_kind(t, c"space") || css_kind(t, c"comment")


int css_skip(css_document* d, int first, int last):
	while (first < last && css_trivia(d.tokens[first])): first = first + 1
	return first


int css_trim(css_document* d, int first, int last):
	while (last > first && css_trivia(d.tokens[last - 1])): last = last - 1
	return last


css_node* css_make_node(css_document* d, char* kind, char* name, int first, int last):
	if (d.node_count >= d.limits.nodes):
		css_error(d, c"node limit", 0, d.length)
		d.failed = 1
		return 0
	css_node* n = new css_node()
	n.kind = strclone(kind)
	n.name = strclone(name)
	n.first = first
	n.last = last
	n.start = d.length
	n.end = d.length
	if (first < d.tokens.length): n.start = d.tokens[first].start
	if (last > first): n.end = d.tokens[last - 1].end
	else: n.end = n.start
	n.children = new list[css_node*]
	d.node_count = d.node_count + 1
	return n


# Skip a balanced component; EOF implicitly closes an unmatched opener.
int css_next_component(css_document* d, int pos, int last):
	css_token* t = d.tokens[pos]
	if (css_delim(t, '(') || css_delim(t, '[') || css_delim(t, '{')):
		if (t.match < 0 || t.match >= last): return last
		return t.match + 1
	return pos + 1


void css_declarations(css_document* d, list[css_node*] output, int first, int last):
	int pos = first
	while (pos < last && d.failed == 0):
		pos = css_skip(d, pos, last)
		if (pos >= last): break
		if (css_delim(d.tokens[pos], ';')):
			pos = pos + 1
			continue
		int start = pos
		int end = pos
		while (end < last && !css_delim(d.tokens[end], ';')): end = css_next_component(d, end, last)
		pos = end + 1
		int colon = css_skip(d, start + 1, end)
		if (!css_kind(d.tokens[start], c"ident") || colon >= end || !css_delim(d.tokens[colon], ':')):
			css_error(d, c"expected property and colon", d.tokens[start].start, d.tokens[end - 1].end)
			continue
		int value_first = css_skip(d, colon + 1, end)
		int value_last = css_trim(d, value_first, end)
		int important = 0
		if (value_last > value_first && css_kind(d.tokens[value_last - 1], c"ident") && css_ascii_equal(d.tokens[value_last - 1].value, c"important")):
			int bang = css_trim(d, value_first, value_last - 1) - 1
			if (bang >= value_first && css_delim(d.tokens[bang], '!')):
				important = 1
				value_last = css_trim(d, value_first, bang)
		int valid = 1
		for i in range(value_first, value_last):
			css_token* t = d.tokens[i]
			if (css_kind(t, c"bad-string") || css_kind(t, c"bad-url")): valid = 0
			if ((css_delim(t, ')') || css_delim(t, ']') || css_delim(t, '}')) && t.match < 0): valid = 0
		if (valid == 0):
			css_error(d, c"invalid declaration value", d.tokens[start].start, d.tokens[end - 1].end)
			continue
		css_node* n = css_make_node(d, c"declaration", d.tokens[start].value, value_first, value_last)
		if (n == 0): break
		n.start = d.tokens[start].start
		n.end = d.tokens[end - 1].end
		n.important = important
		output.push(n)


# Selector groups retain component tokens, including combinators,
# attribute blocks and functional pseudos. Matching is the caller's job.
void css_selectors(css_document* d, list[css_node*] output, int first, int last):
	int pos = first
	while (pos <= last && d.failed == 0):
		int start = css_skip(d, pos, last)
		int end = start
		while (end < last && !css_delim(d.tokens[end], ',')): end = css_next_component(d, end, last)
		int trimmed = css_trim(d, start, end)
		if (start == trimmed):
			int offset = d.length
			if (start < d.tokens.length): offset = d.tokens[start].start
			css_error(d, c"empty selector", offset, offset)
		else:
			css_node* n = css_make_node(d, c"selector", c"", start, trimmed)
			if (n != 0): output.push(n)
		if (end == last): break
		pos = end + 1


void css_rules(css_document* d, list[css_node*] output, int first, int last, int depth):
	if (depth > d.limits.depth):
		css_error(d, c"rule nesting limit", 0, d.length)
		d.failed = 1
		return
	int pos = first
	while (pos < last && d.failed == 0):
		pos = css_skip(d, pos, last)
		if (pos >= last): break
		if (css_delim(d.tokens[pos], '}') || css_delim(d.tokens[pos], ';')):
			pos = pos + 1
			continue
		int start = pos
		int at_rule = css_kind(d.tokens[start], c"at-keyword")
		while (pos < last && !css_delim(d.tokens[pos], '{') && !css_delim(d.tokens[pos], ';') && !css_delim(d.tokens[pos], '}')): pos = css_next_component(d, pos, last)
		int has_block = pos < last && css_delim(d.tokens[pos], '{')
		if (at_rule == 0 && has_block == 0):
			css_error(d, c"qualified rule requires block", d.tokens[start].start, d.tokens[pos - 1].end)
			pos = pos + 1
			continue
		char* kind = c"qualified-rule"
		char* name = c""
		if (at_rule):
			kind = c"at-rule"
			name = d.tokens[start].value
		css_node* n = css_make_node(d, kind, name, start + at_rule, pos)
		if (n == 0): break
		n.start = d.tokens[start].start
		output.push(n)
		if (has_block):
			int close = d.tokens[pos].match
			if (close < 0 || close > last): close = last
			if (at_rule == 0):
				css_selectors(d, n.children, start, pos)
				css_declarations(d, n.children, pos + 1, close)
			else if (css_ascii_equal(name, c"media") || css_ascii_equal(name, c"supports") || css_ascii_equal(name, c"layer") || css_ascii_equal(name, c"container") || css_ascii_equal(name, c"keyframes")):
				css_rules(d, n.children, pos + 1, close, depth + 1)
			else if (css_ascii_equal(name, c"font-face") || css_ascii_equal(name, c"page")):
				css_declarations(d, n.children, pos + 1, close)
			else:
				css_node* body = css_make_node(d, c"block", c"", pos + 1, close)
				if (body != 0): n.children.push(body)
			if (close < last): n.end = d.tokens[close].end
			else: n.end = d.length
			pos = close + 1
		else:
			if (pos < last): n.end = d.tokens[pos].end
			pos = pos + 1


css_document* css_parse_stylesheet_n(char* source, int length, css_limits* limits):
	css_document* d = css_tokenize_n(source, length, limits)
	if (d.failed == 0): css_rules(d, d.nodes, 0, d.tokens.length, 0)
	return d


css_document* css_parse_declarations_n(char* source, int length, css_limits* limits):
	css_document* d = css_tokenize_n(source, length, limits)
	if (d.failed == 0): css_declarations(d, d.nodes, 0, d.tokens.length)
	return d


css_document* css_parse_selectors_n(char* source, int length, css_limits* limits):
	css_document* d = css_tokenize_n(source, length, limits)
	if (d.failed == 0): css_selectors(d, d.nodes, 0, d.tokens.length)
	return d


void css_node_free(css_node* n):
	for i in range(n.children.length): css_node_free(n.children[i])
	__w_list_free(cast(__w_list*, n.children))
	free(n.kind)
	free(n.name)
	free(n)


void css_document_free(css_document* d):
	if (d == 0): return
	for i in range(d.nodes.length): css_node_free(d.nodes[i])
	for i in range(d.tokens.length):
		css_token* t = d.tokens[i]
		free(t.kind)
		free(t.value)
		free(t)
	for i in range(d.diagnostics.length):
		css_diagnostic* e = d.diagnostics[i]
		free(e.message)
		free(e)
	__w_list_free(cast(__w_list*, d.nodes))
	__w_list_free(cast(__w_list*, d.tokens))
	__w_list_free(cast(__w_list*, d.diagnostics))
	free(d.limits)
	free(d.source)
	free(d)
