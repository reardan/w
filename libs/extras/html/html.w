# Bounded HTML tokenizer and initial document tree builder. See docs/projects/html.md.
import lib.lib
import lib.str
import lib.utf8
import structures.string

const int HTML_EOF = 0
const int HTML_START = 1
const int HTML_END = 2
const int HTML_TEXT = 3
const int HTML_COMMENT = 4
const int HTML_DOCTYPE = 5
const int HTML_DOCUMENT = 6

struct html_limits:
	int input_bytes
	int tokens
	int nodes
	int depth
	int attributes
	int diagnostics

struct html_diagnostic:
	int start
	int end
	char* message
	html_diagnostic* next

struct html_attribute:
	char* name
	char* value
	int value_length
	int start
	int end
	html_attribute* next

struct html_token:
	int kind
	int start
	int end
	char* name
	char* text
	int text_length
	int self_closing
	html_attribute* attributes

struct html_tokenizer:
	char* source
	int length
	int position
	int count
	int failed
	int diagnostic_count
	char* raw_name
	int rcdata
	html_limits limits
	html_diagnostic* diagnostics
	html_diagnostic* last_diagnostic

struct html_node:
	int kind
	int start
	int end
	int implied
	int depth
	char* name
	char* text
	int text_length
	html_attribute* attributes
	html_node* parent
	html_node* first_child
	html_node* last_child
	html_node* next_sibling
	html_node* allocation_next

struct html_document:
	char* source
	int source_length
	int failed
	int node_count
	html_node* root
	html_node* allocations
	html_diagnostic* diagnostics

html_limits html_default_limits():
	html_limits v
	v.input_bytes = 8388608
	v.tokens = 100000
	v.nodes = 100000
	v.depth = 256
	v.attributes = 256
	v.diagnostics = 256
	return v

int html_space(int c):
	return (c == 32) || (c == 9) || (c == 10) || (c == 12) || (c == 13)

int html_lower(int c):
	if ((c >= 'A') && (c <= 'Z')): return c + 32
	return c

int html_alpha(int c):
	c = html_lower(c)
	return (c >= 'a') && (c <= 'z')

char* html_slice(char* source, int start, int end, int lower):
	char* out = cast(char*, __w_alloc(__w_size_add(end - start, 1)))
	int i = start
	while (i < end):
		int c = source[i] & 255
		if (lower): c = html_lower(c)
		out[i - start] = c
		i = i + 1
	out[end - start] = 0
	return out

int html_match(html_tokenizer* t, int at, char* value):
	int n = strlen(value)
	if ((at < 0) || (at > t.length) || (n > t.length - at)): return 0
	int i = 0
	while (i < n):
		if (html_lower(t.source[at + i] & 255) != value[i]): return 0
		i = i + 1
	return 1

void html_report(html_tokenizer* t, int start, int end, char* message):
	if (t.diagnostic_count >= t.limits.diagnostics): return
	html_diagnostic* d = new html_diagnostic()
	d.start = start
	d.end = end
	d.message = strclone(message)
	if (t.last_diagnostic != 0): t.last_diagnostic.next = d
	else: t.diagnostics = d
	t.last_diagnostic = d
	t.diagnostic_count = t.diagnostic_count + 1

void html_stop(html_tokenizer* t, int start, char* message):
	t.failed = 1
	html_report(t, start, t.position, message)

void html_diagnostics_free(html_diagnostic* d):
	while (d != 0):
		html_diagnostic* next = d.next
		free(d.message)
		free(d)
		d = next

void html_attributes_free(html_attribute* a):
	while (a != 0):
		html_attribute* next = a.next
		free(a.name)
		free(a.value)
		free(a)
		a = next

void html_token_free(html_token* token):
	if (token == 0): return
	free(token.name)
	free(token.text)
	html_attributes_free(token.attributes)
	free(token)

html_tokenizer* html_tokenizer_new(char* data, int length, html_limits* limits):
	html_tokenizer* t = new html_tokenizer()
	t.limits = html_default_limits()
	if (limits != 0): t.limits = *limits
	if ((length < 0) || ((data == 0) && (length > 0)) || (length > t.limits.input_bytes) || (t.limits.tokens < 1) || (t.limits.nodes < 4) || (t.limits.depth < 3) || (t.limits.attributes < 0) || (t.limits.diagnostics < 0)):
		html_stop(t, 0, c"invalid input or resource limit")
		return t
	t.source = html_slice(data, 0, length, 0)
	t.length = length
	return t

void html_tokenizer_free(html_tokenizer* t):
	if (t == 0): return
	free(t.source)
	free(t.raw_name)
	html_diagnostics_free(t.diagnostics)
	free(t)

# Decode the documented named subset and semicolon-terminated numeric references.
# Unknown names remain literal; numeric invalid scalar values become U+FFFD.
char* html_decode(html_tokenizer* t, int start, int end, int entities, int* length):
	string_builder* out = string_new()
	int i = start
	while (i < end):
		int c = t.source[i] & 255
		if (c == 0):
			html_report(t, i, i + 1, c"NUL replaced")
			string_append(out, c"\xef\xbf\xbd")
			i = i + 1
		else if (c == 13):
			string_append_char(out, 10)
			i = i + 1
			if ((i < end) && (t.source[i] == 10)): i = i + 1
		else if (entities && (c == '&')):
			int stop = i + 1
			while ((stop < end) && (t.source[stop] != ';') && !html_space(t.source[stop]) && (t.source[stop] != '&') && (t.source[stop] != '<')): stop = stop + 1
			int cp = -1
			if ((stop < end) && (t.source[stop] == ';')):
				char* name = html_slice(t.source, i + 1, stop, 0)
				if (strcmp(name, c"amp") == 0): cp = 38
				else if (strcmp(name, c"lt") == 0): cp = 60
				else if (strcmp(name, c"gt") == 0): cp = 62
				else if (strcmp(name, c"quot") == 0): cp = 34
				else if (strcmp(name, c"apos") == 0): cp = 39
				else if (strcmp(name, c"nbsp") == 0): cp = 160
				else if (name[0] == '#'):
					int p = i + 2
					int base = 10
					if ((p < stop) && (html_lower(t.source[p]) == 'x')):
						base = 16
						p = p + 1
					int valid = p < stop
					cp = 0
					while (p < stop):
						int digit = html_lower(t.source[p])
						if ((digit >= '0') && (digit <= '9')): digit = digit - '0'
						else if ((digit >= 'a') && (digit <= 'f')): digit = digit - 'a' + 10
						else: digit = 99
						if (digit >= base): valid = 0
						if (cp <= 1114111): cp = cp * base + digit
						p = p + 1
					if (!valid): cp = -1
					else if ((cp == 0) || (cp > 1114111) || ((cp >= 55296) && (cp <= 57343))):
						cp = 65533
						html_report(t, i, stop + 1, c"invalid numeric character reference")
				free(name)
			if (cp >= 0):
				char[4] encoded
				int count = utf8_encode(encoded, cp)
				string_append_bytes(out, encoded, count)
				i = stop + 1
			else:
				string_append_char(out, c)
				i = i + 1
		else:
			string_append_char(out, c)
			i = i + 1
	*length = out.length
	char* result = html_slice(out.data, 0, out.length, 0)
	string_free(out)
	return result

char* html_name(html_tokenizer* t, int start, int end):
	int length = 0
	char* name = html_decode(t, start, end, 0, &length)
	int i = 0
	while (i < length):
		name[i] = html_lower(name[i] & 255)
		i = i + 1
	return name

int html_raw_end(html_tokenizer* t, int at):
	if (!html_match(t, at, c"</")): return 0
	if (!html_match(t, at + 2, t.raw_name)): return 0
	int after = at + 2 + strlen(t.raw_name)
	if (after >= t.length): return 0
	int c = t.source[after]
	return html_space(c) || (c == '>') || (c == '/')

int html_is_raw(char* name):
	return (strcmp(name, c"script") == 0) || (strcmp(name, c"style") == 0) || (strcmp(name, c"xmp") == 0) || (strcmp(name, c"iframe") == 0) || (strcmp(name, c"noembed") == 0) || (strcmp(name, c"noframes") == 0)

int html_is_rcdata(char* name):
	return (strcmp(name, c"title") == 0) || (strcmp(name, c"textarea") == 0)

html_attribute* html_attribute_find(html_attribute* a, char* name):
	while (a != 0):
		if (strcmp(a.name, name) == 0): return a
		a = a.next
	return 0

html_token* html_tokenizer_next(html_tokenizer* t):
	html_token* token = new html_token()
	token.start = t.position
	token.end = t.position
	if (t.failed || (t.position >= t.length)): return token
	if (t.count >= t.limits.tokens):
		html_stop(t, t.position, c"token limit exceeded")
		return token
	t.count = t.count + 1
	int start = t.position
	if (t.raw_name != 0):
		if (html_raw_end(t, start)):
			free(t.raw_name)
			t.raw_name = 0
		else:
			while ((t.position < t.length) && !html_raw_end(t, t.position)): t.position = t.position + 1
			token.kind = HTML_TEXT
			token.text = html_decode(t, start, t.position, t.rcdata, &token.text_length)
			token.end = t.position
			return token
	if (html_match(t, start, c"<!--")):
		t.position = start + 4
		int content = t.position
		while ((t.position < t.length) && !html_match(t, t.position, c"-->")): t.position = t.position + 1
		token.kind = HTML_COMMENT
		token.text = html_decode(t, content, t.position, 0, &token.text_length)
		if (t.position < t.length): t.position = t.position + 3
		else: html_report(t, start, t.position, c"EOF in comment")
	else if (html_match(t, start, c"<!") || html_match(t, start, c"<?")):
		token.kind = HTML_COMMENT
		int content = start + 2
		if (html_match(t, start, c"<!doctype") && ((start + 9 == t.length) || html_space(t.source[start + 9]) || (t.source[start + 9] == '>'))):
			token.kind = HTML_DOCTYPE
			content = start + 9
		else: html_report(t, start, content, c"bogus comment")
		t.position = content
		while ((t.position < t.length) && (t.source[t.position] != '>')): t.position = t.position + 1
		token.text = html_decode(t, content, t.position, 0, &token.text_length)
		if (t.position < t.length): t.position = t.position + 1
		else: html_report(t, start, t.position, c"EOF in declaration")
	else:
		int name_start = start + 1
		int closing = 0
		if (html_match(t, start, c"</")):
			name_start = start + 2
			closing = 1
		if ((t.source[start] == '<') && (name_start < t.length) && html_alpha(t.source[name_start])):
			token.kind = HTML_START
			if (closing): token.kind = HTML_END
			t.position = name_start
			while ((t.position < t.length) && !html_space(t.source[t.position]) && (t.source[t.position] != '/') && (t.source[t.position] != '>')): t.position = t.position + 1
			token.name = html_name(t, name_start, t.position)
			int attributes = 0
			html_attribute* tail = 0
			while ((t.position < t.length) && (t.source[t.position] != '>') && !t.failed):
				while ((t.position < t.length) && html_space(t.source[t.position])): t.position = t.position + 1
				if ((t.position >= t.length) || (t.source[t.position] == '>')): break
				if (t.source[t.position] == '/'):
					t.position = t.position + 1
					if ((t.position < t.length) && (t.source[t.position] == '>')): token.self_closing = 1
					else: html_report(t, t.position - 1, t.position, c"unexpected slash")
					continue
				int attr_start = t.position
				if (attributes >= t.limits.attributes):
					html_stop(t, attr_start, c"attribute limit exceeded")
					break
				attributes = attributes + 1
				# An initial '=' is retained as a malformed attribute name, making progress.
				t.position = t.position + 1
				while ((t.position < t.length) && !html_space(t.source[t.position]) && (t.source[t.position] != '=') && (t.source[t.position] != '>') && (t.source[t.position] != '/')): t.position = t.position + 1
				html_attribute* a = new html_attribute()
				a.start = attr_start
				a.name = html_name(t, attr_start, t.position)
				while ((t.position < t.length) && html_space(t.source[t.position])): t.position = t.position + 1
				int value_start = t.position
				int value_end = t.position
				if ((t.position < t.length) && (t.source[t.position] == '=')):
					t.position = t.position + 1
					while ((t.position < t.length) && html_space(t.source[t.position])): t.position = t.position + 1
					int quote = 0
					if ((t.position < t.length) && ((t.source[t.position] == 34) || (t.source[t.position] == 39))):
						quote = t.source[t.position]
						t.position = t.position + 1
					value_start = t.position
					while (t.position < t.length):
						int c = t.source[t.position]
						if ((quote != 0) && (c == quote)): break
						if ((quote == 0) && (html_space(c) || (c == '>'))): break
						t.position = t.position + 1
					value_end = t.position
					if ((quote != 0) && (t.position < t.length)): t.position = t.position + 1
					a.value = html_decode(t, value_start, value_end, 1, &a.value_length)
				else: a.value = strclone(c"")
				a.end = t.position
				if (html_attribute_find(token.attributes, a.name) != 0):
					html_report(t, a.start, a.end, c"duplicate attribute ignored")
					html_attributes_free(a)
				else:
					if (tail != 0): tail.next = a
					else: token.attributes = a
					tail = a
			if ((t.position < t.length) && (t.source[t.position] == '>')): t.position = t.position + 1
			else: html_report(t, start, t.position, c"EOF in tag")
			if (!closing && (html_is_raw(token.name) || html_is_rcdata(token.name))):
				t.raw_name = strclone(token.name)
				t.rcdata = html_is_rcdata(token.name)
		else:
			t.position = start + 1
			while ((t.position < t.length) && (t.source[t.position] != '<')): t.position = t.position + 1
			token.kind = HTML_TEXT
			token.text = html_decode(t, start, t.position, 1, &token.text_length)
	token.end = t.position
	return token

int html_void(char* name):
	return (strcmp(name, c"area") == 0) || (strcmp(name, c"base") == 0) || (strcmp(name, c"br") == 0) || (strcmp(name, c"col") == 0) || (strcmp(name, c"embed") == 0) || (strcmp(name, c"hr") == 0) || (strcmp(name, c"img") == 0) || (strcmp(name, c"input") == 0) || (strcmp(name, c"link") == 0) || (strcmp(name, c"meta") == 0) || (strcmp(name, c"param") == 0) || (strcmp(name, c"source") == 0) || (strcmp(name, c"track") == 0) || (strcmp(name, c"wbr") == 0)

html_node* html_add_node(html_document* doc, html_tokenizer* t, html_node* parent, html_token* token):
	int depth = 0
	if (parent != 0): depth = parent.depth + 1
	if ((doc.node_count >= t.limits.nodes) || (depth >= t.limits.depth)):
		html_stop(t, token.start, c"tree node or depth limit exceeded")
		return 0
	html_node* n = new html_node()
	n.kind = token.kind
	n.start = token.start
	n.end = token.end
	n.name = token.name
	n.text = token.text
	n.text_length = token.text_length
	n.attributes = token.attributes
	token.name = 0
	token.text = 0
	token.attributes = 0
	n.parent = parent
	n.depth = depth
	n.allocation_next = doc.allocations
	doc.allocations = n
	doc.node_count = doc.node_count + 1
	if (parent != 0):
		if (parent.last_child != 0): parent.last_child.next_sibling = n
		else: parent.first_child = n
		parent.last_child = n
	return n

html_node* html_implied(html_document* doc, html_tokenizer* t, html_node* parent, char* name, int kind):
	html_token* token = new html_token()
	token.kind = kind
	token.name = strclone(name)
	html_node* node = html_add_node(doc, t, parent, token)
	if (node != 0): node.implied = 1
	html_token_free(token)
	return node

html_node* html_ancestor(html_node* n, char* name):
	while (n != 0):
		if ((n.name != 0) && (strcmp(n.name, name) == 0)): return n
		n = n.parent
	return 0

int html_closes_p(char* name):
	return (strcmp(name, c"p") == 0) || (strcmp(name, c"div") == 0) || (strcmp(name, c"section") == 0) || (strcmp(name, c"article") == 0) || (strcmp(name, c"ul") == 0) || (strcmp(name, c"ol") == 0) || (strcmp(name, c"dl") == 0) || (strcmp(name, c"table") == 0) || (strcmp(name, c"blockquote") == 0) || (strcmp(name, c"pre") == 0) || (strcmp(name, c"hr") == 0) || (strcmp(name, c"h1") == 0) || (strcmp(name, c"h2") == 0) || (strcmp(name, c"h3") == 0) || (strcmp(name, c"h4") == 0) || (strcmp(name, c"h5") == 0) || (strcmp(name, c"h6") == 0)

# Close through target; implied closes end at the next token's start.
html_node* html_close(html_node* current, html_node* target, int end):
	html_node* after = target.parent
	while (current != after):
		current.end = end
		current = current.parent
	return after

html_node* html_optional_close(html_node* current, char* name, int end):
	html_node* n = current
	while ((n != 0) && (n.depth > 2)):
		int match = strcmp(n.name, name) == 0
		if (((strcmp(name, c"dt") == 0) || (strcmp(name, c"dd") == 0)) && ((strcmp(n.name, c"dt") == 0) || (strcmp(n.name, c"dd") == 0))): match = 1
		if (((strcmp(name, c"td") == 0) || (strcmp(name, c"th") == 0)) && ((strcmp(n.name, c"td") == 0) || (strcmp(n.name, c"th") == 0))): match = 1
		if (match): return html_close(current, n, end)
		# Do not cross a nested list or table when closing optional items.
		if ((strcmp(n.name, c"ul") == 0) || (strcmp(n.name, c"ol") == 0) || (strcmp(n.name, c"table") == 0) || (strcmp(n.name, c"select") == 0) || (strcmp(n.name, c"dl") == 0)): break
		n = n.parent
	return current

html_document* html_parse_with_limits(char* data, int length, html_limits* limits):
	html_document* doc = new html_document()
	html_tokenizer* t = html_tokenizer_new(data, length, limits)
	if (!t.failed):
		doc.root = html_implied(doc, t, 0, c"#document", HTML_DOCUMENT)
		html_node* html = html_implied(doc, t, doc.root, c"html", HTML_START)
		html_node* head = html_implied(doc, t, html, c"head", HTML_START)
		html_node* body = html_implied(doc, t, html, c"body", HTML_START)
		html_node* current = body
		int body_started = 0
		while (!t.failed):
			html_token* token = html_tokenizer_next(t)
			if ((token.kind == HTML_EOF) || t.failed):
				html_token_free(token)
				break
			if (token.kind == HTML_START):
				html_node* special = 0
				if (strcmp(token.name, c"html") == 0): special = html
				if ((strcmp(token.name, c"head") == 0) && !body_started): special = head
				if (strcmp(token.name, c"body") == 0): special = body
				if (special != 0):
					if (!special.implied): html_report(t, token.start, token.end, c"duplicate document element ignored")
					else:
						special.implied = 0
						special.start = token.start
						special.end = token.end
						special.attributes = token.attributes
						token.attributes = 0
					if (special == head): current = head
					if (special == body):
						current = body
						body_started = 1
				else:
					int metadata = (strcmp(token.name, c"title") == 0) || (strcmp(token.name, c"meta") == 0) || (strcmp(token.name, c"link") == 0) || (strcmp(token.name, c"base") == 0) || (strcmp(token.name, c"style") == 0) || (strcmp(token.name, c"script") == 0)
					if (!body_started && metadata && ((current == body) || (current == head))): current = head
					else if ((current == head) || (current == body)):
						current = body
						body_started = 1
					if (html_closes_p(token.name)):
						html_node* p = html_ancestor(current, c"p")
						if (p != 0): current = html_close(current, p, token.start)
					if ((strcmp(token.name, c"li") == 0) || (strcmp(token.name, c"dt") == 0) || (strcmp(token.name, c"dd") == 0) || (strcmp(token.name, c"option") == 0) || (strcmp(token.name, c"tr") == 0) || (strcmp(token.name, c"td") == 0) || (strcmp(token.name, c"th") == 0)):
						current = html_optional_close(current, token.name, token.start)
					int is_void = html_void(token.name)
					if (token.self_closing && !is_void): html_report(t, token.start, token.end, c"self-closing flag ignored on HTML element")
					html_node* n = html_add_node(doc, t, current, token)
					if ((n != 0) && !is_void): current = n
			else if (token.kind == HTML_END):
				html_node* match = html_ancestor(current, token.name)
				if ((match == 0) || html_void(token.name)):
					html_report(t, token.start, token.end, c"unmatched end tag ignored")
				else if (match.depth <= 2):
					current = html_close(current, match, token.end)
					current = body
					if (match != head): body_started = 1
				else:
					if (match != current): html_report(t, token.start, token.end, c"misnested end tag closes ancestors")
					current = html_close(current, match, token.end)
			else:
				if ((token.kind == HTML_TEXT) && ((current == head) || (current == body))):
					int i = 0
					while ((i < token.text_length) && html_space(token.text[i])): i = i + 1
					if (i < token.text_length):
						current = body
						body_started = 1
				if (token.kind == HTML_DOCTYPE): html_add_node(doc, t, doc.root, token)
				else: html_add_node(doc, t, current, token)
			html_token_free(token)
			html_node* n = current
			while (n != 0):
				n.end = t.position
				n = n.parent
		# Synthetic document containers cover the entire supplied input.
		doc.root.end = length
		html.end = length
		body.end = length
	doc.failed = t.failed
	doc.source = t.source
	doc.source_length = t.length
	doc.diagnostics = t.diagnostics
	t.source = 0
	t.diagnostics = 0
	html_tokenizer_free(t)
	return doc

html_document* html_parse(char* data, int length):
	return html_parse_with_limits(data, length, 0)

void html_document_free(html_document* doc):
	if (doc == 0): return
	html_node* n = doc.allocations
	while (n != 0):
		html_node* next = n.allocation_next
		free(n.name)
		free(n.text)
		html_attributes_free(n.attributes)
		free(n)
		n = next
	html_diagnostics_free(doc.diagnostics)
	free(doc.source)
	free(doc)
