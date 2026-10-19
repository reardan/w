# Bounded HTML tokenizer and initial document tree builder. See docs/projects/html.md.
import lib.lib
import lib.str
import lib.utf8
import structures.string
import libs.extras.html.entities

const int HTML_EOF = 0
const int HTML_START = 1
const int HTML_END = 2
const int HTML_TEXT = 3
const int HTML_COMMENT = 4
const int HTML_DOCTYPE = 5
const int HTML_DOCUMENT = 6
const int HTML_PROCESSING_INSTRUCTION = 7
const int HTML_FRAGMENT = 11

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
	int plaintext
	int fragment_raw
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

# A lookup compares only the supplied bytes, without allocating a temporary name.
char* html_entity_lookup(char* name, int length):
	int lo = 0
	int hi = HTML_ENTITY_COUNT
	while (lo < hi):
		int mid = lo + (hi - lo) / 2
		char* entry = html_entity_entry(mid)
		int i = 0
		while ((i < length) && (entry[i] != 0) && (entry[i] == name[i])): i = i + 1
		int comparison = 0 - (entry[i] & 255)
		if (i < length): comparison = (name[i] & 255) - (entry[i] & 255)
		if (comparison < 0): hi = mid
		else if (comparison > 0): lo = mid + 1
		else: return entry + length + 1
	return 0

int html_alnum(int c):
	return html_alpha(c) || ((c >= '0') && (c <= '9'))

# HTML's numeric-reference repair table; the five unmapped C1 controls survive.
int html_reference_control(int cp):
	if ((cp < 128) || (cp > 159)): return cp
	char* mapped = c"\xac\x20\x81\x00\x1a\x20\x92\x01\x1e\x20\x26\x20\x20\x20\x21\x20\xc6\x02\x30\x20\x60\x01\x39\x20\x52\x01\x8d\x00\x7d\x01\x8f\x00\x90\x00\x18\x20\x19\x20\x1c\x20\x1d\x20\x22\x20\x13\x20\x14\x20\xdc\x02\x22\x21\x61\x01\x3a\x20\x53\x01\x9d\x00\x7e\x01\x78\x01"
	int offset = (cp - 128) * 2
	return (mapped[offset] & 255) | ((mapped[offset + 1] & 255) << 8)

# Append a reference, returning the first unconsumed byte, or start on no match.
# No rescan of decoded output: &amp;lt; becomes &lt;, never '<'.
int html_reference(html_tokenizer* t, int start, int end, int attribute, string_builder* out):
	int pos = start + 1
	if (pos >= end): return start
	if (t.source[pos] == '#'):
		pos = pos + 1
		int base = 10
		if ((pos < end) && (html_lower(t.source[pos]) == 'x')):
			base = 16
			pos = pos + 1
		int digits = pos
		int cp = 0
		while (pos < end):
			int digit = html_lower(t.source[pos] & 255)
			if ((digit >= '0') && (digit <= '9')): digit = digit - '0'
			else if ((digit >= 'a') && (digit <= 'f')): digit = digit - 'a' + 10
			else: break
			if (digit >= base): break
			# Saturate above Unicode's maximum before another multiply can overflow.
			if (cp <= 1114111): cp = cp * base + digit
			pos = pos + 1
		if (pos == digits):
			html_report(t, start, pos, c"absence of digits in numeric character reference")
			return start
		if ((pos < end) && (t.source[pos] == ';')): pos = pos + 1
		else: html_report(t, start, pos, c"missing semicolon after character reference")
		if ((cp == 0) || (cp > 1114111) || ((cp >= 55296) && (cp <= 57343))):
			html_report(t, start, pos, c"invalid numeric character reference")
			cp = 65533
		else if (((cp >= 64976) && (cp <= 65007)) || ((cp & 65535) >= 65534)):
			html_report(t, start, pos, c"noncharacter character reference")
		else if ((cp == 13) || ((cp < 32) && !html_space(cp)) || ((cp >= 127) && (cp <= 159))):
			html_report(t, start, pos, c"control character reference")
			cp = html_reference_control(cp)
		char[4] encoded
		int count = utf8_encode(encoded, cp)
		string_append_bytes(out, encoded, count)
		return pos
	if (!html_alnum(t.source[pos] & 255)): return start
	# Bound lookup work by the longest spelling, even for adversarial long names.
	while ((pos < end) && (pos - start - 1 < HTML_ENTITY_MAX_NAME) && html_alnum(t.source[pos] & 255)): pos = pos + 1
	if ((pos < end) && (pos - start - 1 < HTML_ENTITY_MAX_NAME) && (t.source[pos] == ';')): pos = pos + 1
	int candidate = pos
	while (candidate > start + 1):
		char* value = html_entity_lookup(t.source + start + 1, candidate - start - 1)
		if (value != 0):
			if (t.source[candidate - 1] != ';'):
				if (attribute && (candidate < end) && ((t.source[candidate] == '=') || html_alnum(t.source[candidate] & 255))): return start
				html_report(t, start, candidate, c"missing semicolon after character reference")
			string_append(out, value)
			return candidate
		candidate = candidate - 1
	# An unknown alphanumeric name ending in ';' is a recoverable parse error.
	# This scan and the literal copy each visit the run once, keeping work linear.
	pos = start + 1
	while ((pos < end) && html_alnum(t.source[pos] & 255)): pos = pos + 1
	if ((pos < end) && (t.source[pos] == ';')): html_report(t, start, pos + 1, c"unknown named character reference")
	return start

# entities: -1 preserves PI data NUL, 0 normalizes only, 1 text/RCDATA, 2 attributes.
char* html_decode(html_tokenizer* t, int start, int end, int entities, int* length):
	string_builder* out = string_new()
	int i = start
	while (i < end):
		int c = t.source[i] & 255
		if (c == 0 && entities >= 0):
			html_report(t, i, i + 1, c"NUL replaced")
			string_append(out, c"\xef\xbf\xbd")
			i = i + 1
		else if (c == 13):
			string_append_char(out, 10)
			i = i + 1
			if ((i < end) && (t.source[i] == 10)): i = i + 1
		else if (entities > 0 && (c == '&')):
			int after = html_reference(t, i, end, entities == 2, out)
			if (after > i): i = after
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
	# Fragment tokenization has no last emitted start tag at initialization.
	if (t.fragment_raw): return 0
	if (!html_match(t, at, c"</")): return 0
	if (!html_match(t, at + 2, t.raw_name)): return 0
	int after = at + 2 + strlen(t.raw_name)
	if (after >= t.length): return 0
	int c = t.source[after]
	return html_space(c) || (c == '>') || (c == '/')

# Script text follows HTML's escaped/double-escaped states, independently of
# JavaScript strings/comments. Scan one complete text token, preserving bytes
# for the common normalization/decoding path below.
void html_script_text(html_tokenizer* t):
	int escaped = 0
	int dashes = 0
	int start = t.position
	while (t.position < t.length):
		int pos = t.position
		int c = t.source[pos]
		if ((escaped < 2) && html_raw_end(t, pos)): return
		if ((escaped == 0) && html_match(t, pos, c"<!--")):
			escaped = 1
			dashes = 2
			t.position = pos + 4
			continue
		if (escaped != 0):
			# In double escape, a matching end spelling only leaves that mode;
			# it does not close the script. Consume its delimiter as text too.
			int after = 0
			if ((escaped == 1) && html_match(t, pos, c"<script")): after = pos + 7
			if ((escaped == 2) && html_match(t, pos, c"</script")): after = pos + 8
			if ((after != 0) && (after < t.length)):
				int delimiter = t.source[after]
				if (html_space(delimiter) || (delimiter == '/') || (delimiter == '>')):
					escaped = 3 - escaped
					dashes = 0
					t.position = after + 1
					continue
			if ((c == '>') && (dashes == 2)): escaped = 0
			if (c == '-'):
				if (dashes < 2): dashes = dashes + 1
			else: dashes = 0
		t.position = pos + 1
	if (escaped != 0): html_report(t, start, t.position, c"EOF in escaped script text")

int html_is_raw(char* name):
	return (strcmp(name, c"script") == 0) || (strcmp(name, c"style") == 0) || (strcmp(name, c"xmp") == 0) || (strcmp(name, c"iframe") == 0) || (strcmp(name, c"noembed") == 0) || (strcmp(name, c"noframes") == 0)

int html_is_rcdata(char* name):
	return (strcmp(name, c"title") == 0) || (strcmp(name, c"textarea") == 0)

html_attribute* html_attribute_find(html_attribute* a, char* name):
	while (a != 0):
		if (strcmp(a.name, name) == 0): return a
		a = a.next
	return 0

# HTML snapshot 1ea5faab processing-instruction states. The scanner retains
# source bytes for bogus-comment fallback and never expands character references.
void html_processing_instruction(html_tokenizer* t, html_token* token):
	int start = t.position
	int pos = start + 2
	int target_start = pos
	int valid = 1
	if (pos < t.length && !html_alpha(t.source[pos] & 255) && t.source[pos] != '_'): valid = 0
	while (valid && pos < t.length):
		int c = t.source[pos] & 255
		if (html_space(c) || c == '?' || c == '>'): break
		if (!html_alnum(c) && c != '-' && c != '_'):
			valid = 0
			break
		pos = pos + 1
	if (valid && pos == t.length):
		html_report(t, start, pos, c"EOF in processing instruction")
		t.position = pos
		return
	if (valid):
		char* lower = html_slice(t.source, target_start, pos, 1)
		if (strcmp(lower, c"xml") == 0 || strcmp(lower, c"xml-stylesheet") == 0): valid = 0
		free(lower)
	if (!valid):
		html_report(t, start, pos, c"invalid or disallowed processing instruction target")
		while (pos < t.length && t.source[pos] != '>'): pos = pos + 1
		token.kind = HTML_COMMENT
		token.text = html_decode(t, start + 1, pos, 0, &token.text_length)
		if (pos < t.length): pos = pos + 1
		t.position = pos
		return
	int target_end = pos
	while (pos < t.length && html_space(t.source[pos])): pos = pos + 1
	int data_start = pos
	while (pos < t.length && t.source[pos] != '>'): pos = pos + 1
	if (pos == t.length):
		html_report(t, start, pos, c"EOF in processing instruction")
		t.position = pos
		return
	int data_end = pos
	if (data_end > data_start && t.source[data_end - 1] == '?'): data_end = data_end - 1
	token.kind = HTML_PROCESSING_INSTRUCTION
	token.name = html_slice(t.source, target_start, target_end, 0)
	token.text = html_decode(t, data_start, data_end, -1, &token.text_length)
	t.position = pos + 1

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
	if (t.plaintext):
		t.position = t.length
		token.kind = HTML_TEXT
		token.text = html_decode(t, start, t.position, 0, &token.text_length)
		token.end = t.position
		return token
	if (t.raw_name != 0):
		if (html_raw_end(t, start)):
			free(t.raw_name)
			t.raw_name = 0
		else:
			if (strcmp(t.raw_name, c"script") == 0): html_script_text(t)
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
	else if (html_match(t, start, c"<?")):
		html_processing_instruction(t, token)
	else if (html_match(t, start, c"<!")):
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
					a.value = html_decode(t, value_start, value_end, 2, &a.value_length)
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
			if (!closing && (strcmp(token.name, c"plaintext") == 0)): t.plaintext = 1
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
	return (strcmp(name, c"area") == 0) || (strcmp(name, c"base") == 0) || (strcmp(name, c"br") == 0) || (strcmp(name, c"col") == 0) || (strcmp(name, c"embed") == 0) || (strcmp(name, c"hr") == 0) || (strcmp(name, c"img") == 0) || (strcmp(name, c"input") == 0) || (strcmp(name, c"link") == 0) || (strcmp(name, c"meta") == 0) || (strcmp(name, c"param") == 0) || (strcmp(name, c"source") == 0) || (strcmp(name, c"track") == 0) || (strcmp(name, c"wbr") == 0) || (strcmp(name, c"keygen") == 0)

html_node* html_add_node(html_document* doc, html_tokenizer* t, html_node* parent, html_token* token):
	# Character tokens append to the existing adjacent text node in either
	# document or fragment mode. This performs no new node allocation.
	if (parent != 0 && token.kind == HTML_TEXT && parent.last_child != 0 && parent.last_child.kind == HTML_TEXT):
		html_node* previous = parent.last_child
		int size = __w_size_add(previous.text_length, token.text_length)
		previous.text = cast(char*, __w_realloc(previous.text, previous.text_length + 1, __w_size_add(size, 1)))
		for i in range(token.text_length): previous.text[previous.text_length + i] = token.text[i]
		previous.text[size] = 0
		previous.text_length = size
		previous.end = token.end
		return previous
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

# Insert a newly allocated leaf before an already-owned child. Allocation and
# depth admission still use the shared bounded insertion path.
html_node* html_insert_before(html_document* doc, html_tokenizer* t, html_node* parent, html_node* reference, html_token* token):
	if (reference == 0): return html_add_node(doc, t, parent, token)
	html_node* previous = 0
	html_node* scan = parent.first_child
	while (scan != reference && scan != 0):
		previous = scan
		scan = scan.next_sibling
	if (scan == 0):
		html_stop(t, token.start, c"missing insertion reference")
		return 0
	html_node* last = parent.last_child
	html_node* node = html_add_node(doc, t, parent, token)
	if (node == 0): return 0
	last.next_sibling = 0
	parent.last_child = last
	node.next_sibling = reference
	if (previous != 0): previous.next_sibling = node
	else: parent.first_child = node
	return node

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

int html_block(char* name):
	return (strcmp(name, c"address") == 0) || (strcmp(name, c"article") == 0) || (strcmp(name, c"aside") == 0) || (strcmp(name, c"blockquote") == 0) || (strcmp(name, c"center") == 0) || (strcmp(name, c"details") == 0) || (strcmp(name, c"dialog") == 0) || (strcmp(name, c"dir") == 0) || (strcmp(name, c"div") == 0) || (strcmp(name, c"dl") == 0) || (strcmp(name, c"fieldset") == 0) || (strcmp(name, c"figcaption") == 0) || (strcmp(name, c"figure") == 0) || (strcmp(name, c"footer") == 0) || (strcmp(name, c"header") == 0) || (strcmp(name, c"hgroup") == 0) || (strcmp(name, c"main") == 0) || (strcmp(name, c"menu") == 0) || (strcmp(name, c"nav") == 0) || (strcmp(name, c"ol") == 0) || (strcmp(name, c"p") == 0) || (strcmp(name, c"search") == 0) || (strcmp(name, c"section") == 0) || (strcmp(name, c"summary") == 0) || (strcmp(name, c"ul") == 0)

int html_closes_p(char* name):
	return (strcmp(name, c"address") == 0) || (strcmp(name, c"article") == 0) || (strcmp(name, c"aside") == 0) || (strcmp(name, c"blockquote") == 0) || (strcmp(name, c"center") == 0) || (strcmp(name, c"details") == 0) || (strcmp(name, c"dialog") == 0) || (strcmp(name, c"dir") == 0) || (strcmp(name, c"div") == 0) || (strcmp(name, c"dl") == 0) || (strcmp(name, c"fieldset") == 0) || (strcmp(name, c"figcaption") == 0) || (strcmp(name, c"figure") == 0) || (strcmp(name, c"footer") == 0) || (strcmp(name, c"header") == 0) || (strcmp(name, c"hgroup") == 0) || (strcmp(name, c"main") == 0) || (strcmp(name, c"menu") == 0) || (strcmp(name, c"nav") == 0) || (strcmp(name, c"ol") == 0) || (strcmp(name, c"p") == 0) || (strcmp(name, c"search") == 0) || (strcmp(name, c"section") == 0) || (strcmp(name, c"summary") == 0) || (strcmp(name, c"ul") == 0) || (strcmp(name, c"pre") == 0) || (strcmp(name, c"listing") == 0) || (strcmp(name, c"hr") == 0) || (strcmp(name, c"h1") == 0) || (strcmp(name, c"h2") == 0) || (strcmp(name, c"h3") == 0) || (strcmp(name, c"h4") == 0) || (strcmp(name, c"h5") == 0) || (strcmp(name, c"h6") == 0) || (strcmp(name, c"table") == 0) || (strcmp(name, c"form") == 0) || (strcmp(name, c"li") == 0) || (strcmp(name, c"dt") == 0) || (strcmp(name, c"dd") == 0)

int html_special(char* name):
	return (strcmp(name, c"address") == 0) || (strcmp(name, c"applet") == 0) || (strcmp(name, c"area") == 0) || (strcmp(name, c"article") == 0) || (strcmp(name, c"aside") == 0) || (strcmp(name, c"base") == 0) || (strcmp(name, c"basefont") == 0) || (strcmp(name, c"bgsound") == 0) || (strcmp(name, c"blockquote") == 0) || (strcmp(name, c"body") == 0) || (strcmp(name, c"br") == 0) || (strcmp(name, c"button") == 0) || (strcmp(name, c"caption") == 0) || (strcmp(name, c"center") == 0) || (strcmp(name, c"col") == 0) || (strcmp(name, c"colgroup") == 0) || (strcmp(name, c"dd") == 0) || (strcmp(name, c"details") == 0) || (strcmp(name, c"dialog") == 0) || (strcmp(name, c"dir") == 0) || (strcmp(name, c"div") == 0) || (strcmp(name, c"dl") == 0) || (strcmp(name, c"dt") == 0) || (strcmp(name, c"embed") == 0) || (strcmp(name, c"fieldset") == 0) || (strcmp(name, c"figcaption") == 0) || (strcmp(name, c"figure") == 0) || (strcmp(name, c"footer") == 0) || (strcmp(name, c"form") == 0) || (strcmp(name, c"frame") == 0) || (strcmp(name, c"frameset") == 0) || (strcmp(name, c"h1") == 0) || (strcmp(name, c"h2") == 0) || (strcmp(name, c"h3") == 0) || (strcmp(name, c"h4") == 0) || (strcmp(name, c"h5") == 0) || (strcmp(name, c"h6") == 0) || (strcmp(name, c"head") == 0) || (strcmp(name, c"header") == 0) || (strcmp(name, c"hgroup") == 0) || (strcmp(name, c"hr") == 0) || (strcmp(name, c"html") == 0) || (strcmp(name, c"iframe") == 0) || (strcmp(name, c"img") == 0) || (strcmp(name, c"input") == 0) || (strcmp(name, c"keygen") == 0) || (strcmp(name, c"li") == 0) || (strcmp(name, c"link") == 0) || (strcmp(name, c"listing") == 0) || (strcmp(name, c"main") == 0) || (strcmp(name, c"marquee") == 0) || (strcmp(name, c"menu") == 0) || (strcmp(name, c"meta") == 0) || (strcmp(name, c"nav") == 0) || (strcmp(name, c"noembed") == 0) || (strcmp(name, c"noframes") == 0) || (strcmp(name, c"noscript") == 0) || (strcmp(name, c"object") == 0) || (strcmp(name, c"ol") == 0) || (strcmp(name, c"p") == 0) || (strcmp(name, c"param") == 0) || (strcmp(name, c"plaintext") == 0) || (strcmp(name, c"pre") == 0) || (strcmp(name, c"script") == 0) || (strcmp(name, c"search") == 0) || (strcmp(name, c"section") == 0) || (strcmp(name, c"select") == 0) || (strcmp(name, c"source") == 0) || (strcmp(name, c"style") == 0) || (strcmp(name, c"summary") == 0) || (strcmp(name, c"table") == 0) || (strcmp(name, c"tbody") == 0) || (strcmp(name, c"td") == 0) || (strcmp(name, c"template") == 0) || (strcmp(name, c"textarea") == 0) || (strcmp(name, c"tfoot") == 0) || (strcmp(name, c"th") == 0) || (strcmp(name, c"thead") == 0) || (strcmp(name, c"title") == 0) || (strcmp(name, c"tr") == 0) || (strcmp(name, c"track") == 0) || (strcmp(name, c"ul") == 0) || (strcmp(name, c"wbr") == 0) || (strcmp(name, c"xmp") == 0)

# The document/fragment root is the stack boundary; scope never crosses it.
# Namespace-specific scope boundaries remain part of the foreign-content slice.
html_node* html_in_scope(html_node* current, char* name, int button, int list_item):
	while (current != 0 && current.kind == HTML_START):
		if (strcmp(current.name, name) == 0): return current
		char* tag = current.name
		if ((strcmp(tag, c"applet") == 0) || (strcmp(tag, c"caption") == 0) || (strcmp(tag, c"html") == 0) || (strcmp(tag, c"table") == 0) || (strcmp(tag, c"td") == 0) || (strcmp(tag, c"th") == 0) || (strcmp(tag, c"marquee") == 0) || (strcmp(tag, c"object") == 0) || (strcmp(tag, c"template") == 0)): return 0
		if (button && strcmp(tag, c"button") == 0): return 0
		if (list_item && ((strcmp(tag, c"ol") == 0) || (strcmp(tag, c"ul") == 0))): return 0
		current = current.parent
	return 0

html_node* html_end_match(html_node* current, char* name):
	if (strcmp(name, c"p") == 0): return html_in_scope(current, name, 1, 0)
	if (strcmp(name, c"li") == 0): return html_in_scope(current, name, 0, 1)
	if (html_block(name) || (strcmp(name, c"applet") == 0) || (strcmp(name, c"marquee") == 0) || (strcmp(name, c"object") == 0) || (strcmp(name, c"select") == 0) || (strcmp(name, c"pre") == 0) || (strcmp(name, c"listing") == 0) || (strcmp(name, c"button") == 0) || (strcmp(name, c"dd") == 0) || (strcmp(name, c"dt") == 0)): return html_in_scope(current, name, 0, 0)
	# Existing head/body and table recovery retain their dedicated paths.
	if ((strcmp(name, c"html") == 0) || (strcmp(name, c"head") == 0) || (strcmp(name, c"body") == 0) || (strcmp(name, c"table") == 0) || (strcmp(name, c"tr") == 0) || (strcmp(name, c"td") == 0) || (strcmp(name, c"th") == 0)): return html_ancestor(current, name)
	while (current != 0 && current.kind == HTML_START):
		if (strcmp(current.name, name) == 0): return current
		if (html_special(current.name)): return 0
		current = current.parent
	return 0

# Close through target; implied closes end at the next token's start.
html_node* html_close(html_node* current, html_node* target, int end):
	html_node* after = target.parent
	while (current != after):
		current.end = end
		current = current.parent
	return after

html_node* html_optional_close(html_node* current, char* name, int end):
	html_node* n = current
	while ((n != 0) && (n.kind == HTML_START)):
		int match = strcmp(n.name, name) == 0
		if (((strcmp(name, c"dt") == 0) || (strcmp(name, c"dd") == 0)) && ((strcmp(n.name, c"dt") == 0) || (strcmp(n.name, c"dd") == 0))): match = 1
		if (((strcmp(name, c"td") == 0) || (strcmp(name, c"th") == 0)) && ((strcmp(n.name, c"td") == 0) || (strcmp(n.name, c"th") == 0))): match = 1
		if (match): return html_close(current, n, end)
		int item = (strcmp(name, c"li") == 0) || (strcmp(name, c"dt") == 0) || (strcmp(name, c"dd") == 0)
		if (item && html_special(n.name) && (strcmp(n.name, c"address") != 0) && (strcmp(n.name, c"div") != 0) && (strcmp(n.name, c"p") != 0)): break
		# Do not cross a nested list or table when closing optional items.
		if ((strcmp(n.name, c"ul") == 0) || (strcmp(n.name, c"ol") == 0) || (strcmp(n.name, c"table") == 0) || (strcmp(n.name, c"select") == 0) || (strcmp(n.name, c"dl") == 0)): break
		n = n.parent
	return current

# HTML snapshot 1ea5faab: select uses in-body rules, not an obsolete
# in-select mode. Fragment context is tested explicitly where specified; it
# does not pretend the detached context element is on the open-element stack.
html_node* html_generate_implied(html_node* current, int except_optgroup, int end):
	while (current != 0 && current.kind == HTML_START):
		char* name = current.name
		int implied = (strcmp(name, c"dd") == 0) || (strcmp(name, c"dt") == 0) || (strcmp(name, c"li") == 0) || (strcmp(name, c"option") == 0) || (strcmp(name, c"p") == 0) || (strcmp(name, c"rb") == 0) || (strcmp(name, c"rp") == 0) || (strcmp(name, c"rt") == 0) || (strcmp(name, c"rtc") == 0)
		if (!except_optgroup && strcmp(name, c"optgroup") == 0): implied = 1
		if (!implied): break
		current.end = end
		current = current.parent
	return current

html_node* html_select_start(html_tokenizer* t, html_node* current, html_token* token, int fragment_select, int* ignored):
	char* name = token.name
	int is_select = strcmp(name, c"select") == 0
	int is_input = strcmp(name, c"input") == 0
	if (fragment_select && (is_select || is_input)):
		html_report(t, token.start, token.end, c"select or input start ignored in select fragment")
		*ignored = 1
		return current
	html_node* select = html_in_scope(current, c"select", 0, 0)
	if ((is_select || is_input) && select != 0):
		html_report(t, token.start, token.end, c"select closed by select or input start")
		if (is_select): *ignored = 1
		return html_close(current, select, token.start)
	int option = strcmp(name, c"option") == 0
	int optgroup = strcmp(name, c"optgroup") == 0
	int rule = option || optgroup || (strcmp(name, c"hr") == 0)
	if (rule && select != 0):
		current = html_generate_implied(current, option, token.start)
		if (html_in_scope(current, c"option", 0, 0) != 0 || (!option && html_in_scope(current, c"optgroup", 0, 0) != 0)):
			html_report(t, token.start, token.end, c"option or optgroup remains in scope")
	else if ((option || optgroup) && current.kind == HTML_START && strcmp(current.name, c"option") == 0):
		current = html_close(current, current, token.start)
	return current

# Repeated HTML/body start tags add missing attributes without replacing old
# values. Transfer token-owned attributes only after the bounded union fits.
void html_merge_document_attributes(html_tokenizer* t, html_node* node, html_token* token):
	int count = 0
	html_attribute* tail = 0
	html_attribute* attr = node.attributes
	while (attr != 0):
		count = count + 1
		tail = attr
		attr = attr.next
	attr = token.attributes
	while (attr != 0):
		if (html_attribute_find(node.attributes, attr.name) == 0): count = count + 1
		attr = attr.next
	if (count > t.limits.attributes):
		html_stop(t, token.start, c"document attribute limit exceeded")
		return
	attr = token.attributes
	token.attributes = 0
	while (attr != 0):
		html_attribute* next = attr.next
		attr.next = 0
		if (html_attribute_find(node.attributes, attr.name) != 0): html_attributes_free(attr)
		else:
			if (tail != 0): tail.next = attr
			else: node.attributes = attr
			tail = attr
		attr = next

html_document* html_parse_document_inner(char* data, int length, html_limits* limits, int fragment, int scripting):
	html_document* doc = new html_document()
	html_tokenizer* t = html_tokenizer_new(data, length, limits)
	if (!t.failed):
		doc.root = html_implied(doc, t, 0, c"#document", HTML_DOCUMENT)
		html_node* html = html_implied(doc, t, doc.root, c"html", HTML_START)
		html_node* head = html_implied(doc, t, html, c"head", HTML_START)
		html_node* body = html_implied(doc, t, html, c"body", HTML_START)
		html_node* current = body
		int body_started = 0
		# Placement phases for leaf nodes: before HTML/head, in head, after head, body.
		int document_phase = fragment
		# 0 retains the existing before/in-body foundation; 1 after body,
		# 2 after after body. Neither closing tag pops open elements.
		int after_body = 0
		html_node* head_noscript = 0
		int declaration_allowed = 1
		while (!t.failed):
			html_token* token = html_tokenizer_next(t)
			if ((token.kind == HTML_EOF) || t.failed):
				html_token_free(token)
				break
			if (head_noscript != 0 && current == head_noscript):
				if (token.kind == HTML_END && strcmp(token.name, c"noscript") == 0):
					current = html_close(current, head_noscript, token.end)
					current.end = token.end
					head_noscript = 0
					html_token_free(token)
					continue
				int ignore = token.kind == HTML_DOCTYPE
				if (token.kind == HTML_END && strcmp(token.name, c"br") != 0): ignore = 1
				if (token.kind == HTML_START && (strcmp(token.name, c"head") == 0 || strcmp(token.name, c"noscript") == 0)): ignore = 1
				if (ignore):
					html_report(t, token.start, token.end, c"token ignored in head noscript")
					html_token_free(token)
					continue
				int allowed = token.kind == HTML_COMMENT || token.kind == HTML_PROCESSING_INSTRUCTION
				if (token.kind == HTML_START):
					allowed = strcmp(token.name, c"html") == 0 || strcmp(token.name, c"basefont") == 0 || strcmp(token.name, c"bgsound") == 0 || strcmp(token.name, c"link") == 0 || strcmp(token.name, c"meta") == 0 || strcmp(token.name, c"noframes") == 0 || strcmp(token.name, c"style") == 0
				if (token.kind == HTML_TEXT):
					int prefix = 0
					while (prefix < token.text_length && html_space(token.text[prefix])): prefix = prefix + 1
					allowed = prefix == token.text_length
					if (prefix > 0 && !allowed):
						# Both decoded runs retain their enclosing lexical token span.
						html_token* space = new html_token()
						space.kind = HTML_TEXT
						space.start = token.start
						space.end = token.end
						space.text = html_slice(token.text, 0, prefix, 0)
						space.text_length = prefix
						html_add_node(doc, t, current, space)
						html_token_free(space)
						if (t.failed):
							html_token_free(token)
							break
						char* remainder = html_slice(token.text, prefix, token.text_length, 0)
						free(token.text)
						token.text = remainder
						token.text_length = token.text_length - prefix
				if (!allowed):
					html_report(t, token.start, token.end, c"token reprocessed after head noscript")
					current = html_close(current, head_noscript, token.start)
					head_noscript = 0
			if (scripting >= 0 && token.kind == HTML_END && strcmp(token.name, c"br") == 0):
				# The in-body end-br rule reprocesses an attribute-free start tag.
				html_report(t, token.start, token.end, c"br end tag treated as start")
				token.kind = HTML_START
				html_attributes_free(token.attributes)
				token.attributes = 0
			if (after_body):
				if (token.kind == HTML_COMMENT || token.kind == HTML_PROCESSING_INSTRUCTION):
					html_node* parent = html
					if (after_body == 2): parent = doc.root
					html_add_node(doc, t, parent, token)
					html_token_free(token)
					continue
				if (token.kind == HTML_DOCTYPE):
					html_report(t, token.start, token.end, c"doctype after body ignored")
					html_token_free(token)
					continue
				if (after_body == 1 && token.kind == HTML_END && strcmp(token.name, c"html") == 0):
					if (fragment): html_report(t, token.start, token.end, c"html end ignored after fragment body")
					else: after_body = 2
					html_token_free(token)
					continue
				int in_body = token.kind == HTML_START && strcmp(token.name, c"html") == 0
				if (token.kind == HTML_TEXT):
					int i = 0
					while (i < token.text_length && html_space(token.text[i])): i = i + 1
					in_body = i == token.text_length
				if (!in_body):
					html_report(t, token.start, token.end, c"token after body reprocessed in body")
					after_body = 0
			if (token.kind == HTML_PROCESSING_INSTRUCTION):
				html_node* inserted = 0
				if (document_phase == 0): inserted = html_insert_before(doc, t, doc.root, html, token)
				else if (document_phase == 1): inserted = html_insert_before(doc, t, html, head, token)
				else if (document_phase == 3): inserted = html_insert_before(doc, t, html, body, token)
				else: inserted = html_add_node(doc, t, current, token)
				while (inserted != 0):
					inserted.end = t.position
					inserted = inserted.parent
				html_token_free(token)
				continue
			if (token.kind == HTML_START):
				declaration_allowed = 0
				html_node* special = 0
				if (strcmp(token.name, c"html") == 0): special = html
				if ((strcmp(token.name, c"head") == 0) && !body_started): special = head
				if (strcmp(token.name, c"body") == 0): special = body
				if (special != 0):
					if (!special.implied):
						html_report(t, token.start, token.end, c"duplicate document element")
						if (special == html || special == body): html_merge_document_attributes(t, special, token)
					else:
						special.implied = 0
						special.start = token.start
						special.end = token.end
						special.attributes = token.attributes
						token.attributes = 0
					if (special == html && document_phase == 0): document_phase = 1
					if (special == head):
						current = head
						document_phase = 2
					if (special == body):
						document_phase = 4
						if (!body_started): current = body
						body_started = 1
				else:
					int metadata = (strcmp(token.name, c"title") == 0) || (strcmp(token.name, c"meta") == 0) || (strcmp(token.name, c"link") == 0) || (strcmp(token.name, c"base") == 0) || (strcmp(token.name, c"style") == 0) || (strcmp(token.name, c"script") == 0)
					if (scripting >= 0):
						if (strcmp(token.name, c"basefont") == 0 || strcmp(token.name, c"bgsound") == 0 || strcmp(token.name, c"noframes") == 0): metadata = 1
						if (strcmp(token.name, c"noscript") == 0 && document_phase < 3): metadata = 1
					if (!body_started && metadata && ((current == body) || (current == head))):
						current = head
						if (document_phase < 3): document_phase = 2
					else if ((current == head) || (current == body)):
						current = body
						body_started = 1
						document_phase = 4
					int ignored = 0
					current = html_select_start(t, current, token, 0, &ignored)
					if (ignored):
						html_token_free(token)
						continue
					if (html_closes_p(token.name)):
						html_node* p = html_in_scope(current, c"p", 1, 0)
						if (p != 0): current = html_close(current, p, token.start)
					if ((strcmp(token.name, c"li") == 0) || (strcmp(token.name, c"dt") == 0) || (strcmp(token.name, c"dd") == 0) || (strcmp(token.name, c"tr") == 0) || (strcmp(token.name, c"td") == 0) || (strcmp(token.name, c"th") == 0)):
						current = html_optional_close(current, token.name, token.start)
					int is_void = html_void(token.name)
					if (scripting >= 0 && (strcmp(token.name, c"basefont") == 0 || strcmp(token.name, c"bgsound") == 0)): is_void = 1
					if (token.self_closing && !is_void): html_report(t, token.start, token.end, c"self-closing flag ignored on HTML element")
					html_node* n = html_add_node(doc, t, current, token)
					if ((n != 0) && !is_void):
						current = n
						if (scripting >= 0 && strcmp(n.name, c"noscript") == 0):
							if (scripting):
								t.raw_name = strclone(c"noscript")
								t.rcdata = 0
							else if (n.parent == head): head_noscript = n
			else if (token.kind == HTML_END):
				declaration_allowed = 0
				if (strcmp(token.name, c"body") == 0 || strcmp(token.name, c"html") == 0):
					# In-head reprocesses body/html end tags after implicitly closing
					# head, then the implied body enters the ordinary scope rules.
					if (current == head): current = body
					if (html_in_scope(current, c"body", 0, 0) == 0): html_report(t, token.start, token.end, c"body end outside scope ignored")
					else:
						body_started = 1
						document_phase = 4
						after_body = 1
						if (strcmp(token.name, c"html") == 0 && !fragment): after_body = 2
					html_token_free(token)
					continue
				html_node* match = html_end_match(current, token.name)
				if (match == 0 && strcmp(token.name, c"p") == 0):
					html_report(t, token.start, token.end, c"missing paragraph synthesized for end tag")
					match = html_implied(doc, t, current, c"p", HTML_START)
					if (match != 0):
						match.start = token.start
						current = match
				if ((match == 0) || html_void(token.name)):
					html_report(t, token.start, token.end, c"unmatched end tag ignored")
				else if (match.depth <= 2):
					current = html_close(current, match, token.end)
					current = body
					if (match != head): body_started = 1
					else: document_phase = 3
				else:
					if (match != current): html_report(t, token.start, token.end, c"misnested end tag closes ancestors")
					current = html_close(current, match, token.end)
			else:
				if ((token.kind == HTML_TEXT) && ((current == head) || (current == body))):
					int i = 0
					while ((i < token.text_length) && html_space(token.text[i])): i = i + 1
					if (i < token.text_length):
						declaration_allowed = 0
						current = body
						body_started = 1
						document_phase = 4
				if (token.kind == HTML_DOCTYPE):
					if (declaration_allowed):
						declaration_allowed = 0
						html_insert_before(doc, t, doc.root, html, token)
					else: html_report(t, token.start, token.end, c"doctype outside initial mode ignored")
				else: html_add_node(doc, t, current, token)
			html_token_free(token)
			html_node* n = current
			while (n != 0):
				n.end = t.position
				n = n.parent
		# Synthetic document containers cover the entire supplied input.
		if (doc.root != 0): doc.root.end = length
		if (html != 0): html.end = length
		if (body != 0): body.end = length
	doc.failed = t.failed
	doc.source = t.source
	doc.source_length = t.length
	doc.diagnostics = t.diagnostics
	t.source = 0
	t.diagnostics = 0
	html_tokenizer_free(t)
	return doc

html_document* html_parse_with_limits(char* data, int length, html_limits* limits):
	return html_parse_document_inner(data, length, limits, 0, -1)

# Existing generic callers retain their legacy noscript interpretation. Browser
# hosts and conformance bridges explicitly select disabled(0) or enabled(1).
html_document* html_parse_with_scripting_limits(char* data, int length, int scripting, html_limits* limits):
	return html_parse_document_inner(data, length, limits, 0, scripting != 0)

html_document* html_parse_with_scripting(char* data, int length, int scripting):
	return html_parse_with_scripting_limits(data, length, scripting, 0)

html_document* html_parse(char* data, int length):
	return html_parse_with_limits(data, length, 0)

# Fragment contexts are HTML local names. Context and source are copied; no
# borrowed context node survives this call. Full table/select/template/foreign
# insertion modes remain explicit failures instead of returning a wrong tree.
int html_fragment_context_supported(char* context):
	if (context == 0): return 0
	return (strcmp(context, c"html") == 0) || (strcmp(context, c"div") == 0) || (strcmp(context, c"body") == 0) || (strcmp(context, c"head") == 0) || html_is_raw(context) || html_is_rcdata(context) || (strcmp(context, c"plaintext") == 0) || (strcmp(context, c"noscript") == 0) || (strcmp(context, c"select") == 0)

html_document* html_parse_fragment_with_limits(char* data, int length, char* context, int scripting, html_limits* limits):
	# HTML context starts before head; reuse the existing document insertion
	# recovery, then return the synthetic HTML element's children. The parser's
	# other insertion-mode limitations still apply to this bounded foundation.
	if (context != 0 && strcmp(context, c"html") == 0):
		html_document* parsed = html_parse_document_inner(data, length, limits, 1, scripting != 0)
		if (parsed.root != 0):
			html_node* html = parsed.root.first_child
			while (html != 0 && (html.kind != HTML_START || strcmp(html.name, c"html") != 0)): html = html.next_sibling
			if (html == 0):
				parsed.failed = 1
				return parsed
			html_node* discarded = parsed.root.first_child
			while (discarded != html):
				discarded.parent = 0
				discarded = discarded.next_sibling
			discarded = html.next_sibling
			while (discarded != 0):
				discarded.parent = 0
				discarded = discarded.next_sibling
			parsed.root.kind = HTML_FRAGMENT
			free(parsed.root.name)
			parsed.root.name = strclone(c"#document-fragment")
			parsed.root.first_child = html.first_child
			parsed.root.last_child = html.last_child
			html_node* child = html.first_child
			while (child != 0):
				child.parent = parsed.root
				child = child.next_sibling
			html.first_child = 0
			html.last_child = 0
			html.next_sibling = 0
			html.parent = 0
			html_node* node = parsed.allocations
			while (node != 0):
				if (node.depth > 0): node.depth = node.depth - 1
				node = node.allocation_next
		return parsed
	html_document* doc = new html_document()
	html_tokenizer* t = html_tokenizer_new(data, length, limits)
	if (!html_fragment_context_supported(context)): html_stop(t, 0, c"unsupported HTML fragment context")
	if (!t.failed):
		doc.root = html_implied(doc, t, 0, c"#document-fragment", HTML_FRAGMENT)
		if (strcmp(context, c"plaintext") == 0): t.plaintext = 1
		if (html_is_raw(context) || html_is_rcdata(context) || (scripting && (strcmp(context, c"noscript") == 0))):
			t.raw_name = strclone(context)
			t.rcdata = html_is_rcdata(context)
			t.fragment_raw = 1
		html_node* current = doc.root
		while (!t.failed):
			html_token* token = html_tokenizer_next(t)
			if ((token.kind == HTML_EOF) || t.failed):
				html_token_free(token)
				break
			if (token.kind == HTML_START):
				int ignored = (strcmp(token.name, c"html") == 0) || (strcmp(token.name, c"head") == 0) || (strcmp(token.name, c"body") == 0) || (strcmp(token.name, c"frameset") == 0)
				current = html_select_start(t, current, token, strcmp(context, c"select") == 0, &ignored)
				if (ignored): html_report(t, token.start, token.end, c"document tag ignored in fragment")
				else:
					if (html_closes_p(token.name)):
						html_node* p = html_in_scope(current, c"p", 1, 0)
						if (p != 0): current = html_close(current, p, token.start)
					if ((strcmp(token.name, c"li") == 0) || (strcmp(token.name, c"dt") == 0) || (strcmp(token.name, c"dd") == 0)):
						current = html_optional_close(current, token.name, token.start)
					int is_void = html_void(token.name)
					if (token.self_closing && !is_void): html_report(t, token.start, token.end, c"self-closing flag ignored on HTML element")
					html_node* n = html_add_node(doc, t, current, token)
					if ((n != 0) && !is_void):
						current = n
						if (scripting && strcmp(n.name, c"noscript") == 0):
							t.raw_name = strclone(c"noscript")
							t.rcdata = 0
			else if (token.kind == HTML_END):
				html_node* match = html_end_match(current, token.name)
				if (match == 0 && strcmp(token.name, c"p") == 0):
					html_report(t, token.start, token.end, c"missing paragraph synthesized for end tag")
					match = html_implied(doc, t, current, c"p", HTML_START)
					if (match != 0):
						match.start = token.start
						current = match
				if ((match == 0) || (match == doc.root) || html_void(token.name)): html_report(t, token.start, token.end, c"unmatched fragment end tag ignored")
				else: current = html_close(current, match, token.end)
			else if (token.kind == HTML_DOCTYPE): html_report(t, token.start, token.end, c"doctype ignored in fragment")
			else:
				# Tree construction coalesces adjacent character tokens.
				html_node* previous = current.last_child
				if ((token.kind == HTML_TEXT) && (previous != 0) && (previous.kind == HTML_TEXT)):
					int size = __w_size_add(previous.text_length, token.text_length)
					previous.text = cast(char*, __w_realloc(previous.text, previous.text_length + 1, __w_size_add(size, 1)))
					for i in range(token.text_length): previous.text[previous.text_length + i] = token.text[i]
					previous.text[size] = 0
					previous.text_length = size
					previous.end = token.end
				else: html_add_node(doc, t, current, token)
			html_token_free(token)
			html_node* n = current
			while (n != 0):
				n.end = t.position
				n = n.parent
		doc.root.end = length
	doc.failed = t.failed
	doc.source = t.source
	doc.source_length = t.length
	doc.diagnostics = t.diagnostics
	t.source = 0
	t.diagnostics = 0
	html_tokenizer_free(t)
	return doc

html_document* html_parse_fragment(char* data, int length, char* context, int scripting):
	return html_parse_fragment_with_limits(data, length, context, scripting, 0)

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
