/*
XML 1.0 pull tokenizer (stdlib parity P3.4a; Python reference:
Lib/xml/ + Modules/pyexpat.c).

	xml_reader* r = xml_reader_new(text)
	int ev = xml_next(r)
	while ((ev != XML_EOF) && (ev != XML_ERROR)):
		if (ev == XML_START): ... r.name, r.local, r.ns_uri, r.attrs
		ev = xml_next(r)
	if (ev == XML_ERROR): print(r.error)
	xml_reader_free(r)

Events (the int xml_next returns, also kept in r.event):
- XML_DECL: the `<?xml version=... ?>` declaration (only legal as the
  very first bytes, after an optional UTF-8 BOM). r.version,
  r.encoding, r.standalone hold its pseudo-attributes ("" if absent).
- XML_DOCTYPE: `<!DOCTYPE name ...>`; r.name is the root name and
  r.text the raw rest of the declaration. The declaration is skipped,
  not interpreted: the internal subset is tolerated (its quoted strings,
  comments and PIs are stepped over so a `>` inside them does not end
  it) but nothing in it is processed, so entity declarations are
  ignored and a reference to one in the body is an "undefined entity"
  error. There is no DTD validation and no external entity or DTD is
  ever fetched: the reader is XXE-safe and immune to entity-expansion
  ("billion laughs") attacks by construction.
- XML_START: a start tag. r.name is the qualified name as written,
  r.prefix / r.local its parts and r.ns_uri the resolved namespace URI
  ("" for none). r.attrs lists xml_attr* in document order, each with
  the same four name fields plus its decoded value. xmlns / xmlns:p
  declarations stay in r.attrs with ns_uri xml_namespace_xmlns(). r.empty is 1
  for `<a/>`, which is followed by a matching XML_END event.
- XML_END: an end tag (or the implicit end of an empty element), with
  the same name fields as its start.
- XML_TEXT: character data between markup, entity and character
  references decoded, line ends normalized to \n. Whitespace inside the
  root element is reported; whitespace outside it is skipped.
- XML_CDATA: the contents of one `<![CDATA[...]]>` section (r.text).
- XML_COMMENT: r.text is the comment body.
- XML_PI: a processing instruction; r.target and r.text (the data,
  leading whitespace dropped).
- XML_EOF: the end of a well-formed document (sticky).
- XML_ERROR: a well-formedness error (sticky). r.error is a message in
  Python ParseError style ("mismatched tag: line 3, column 2"), with
  r.error_line (1-based) and r.error_col (0-based byte offset in the
  line, like expat) set as well.

Every event string is owned by the reader and stays valid only until
the next xml_next / xml_reader_free; copy what you keep. The input text
is borrowed and must outlive the reader; it is read as UTF-8 regardless
of the declared encoding label (invalid UTF-8 is an error), and an
embedded NUL ends it.

Checked well-formedness rules: element nesting and matching end tags,
exactly one root element (no text or second element after it), names,
attribute syntax (either quote style, whitespace between attributes,
no duplicates, no `<` in values), the five predefined entities
(amp lt gt quot apos -- HTML entities are not accepted) and decimal /
hex character references to legal XML characters, `--` inside
comments, `]]>` in character data, CDATA only inside the root, the
reserved `xml` PI target, legal XML characters throughout, and
Namespaces in XML 1.0 (bound prefixes, no undeclaring a prefix, the
reserved xml / xmlns prefixes, no duplicate expanded attribute names).
Attribute values are normalized as the spec says for CDATA attributes:
a literal tab, newline or carriage return becomes a space, while the
same character written as a character reference is kept. Nesting
deeper than r.max_depth (default 1000) is an error.
*/
import lib.lib
import structures.string


const int XML_EOF = 0
const int XML_START = 1
const int XML_END = 2
const int XML_TEXT = 3
const int XML_CDATA = 4
const int XML_COMMENT = 5
const int XML_PI = 6
const int XML_DECL = 7
const int XML_DOCTYPE = 8
const int XML_ERROR = 9


struct xml_attr:
	char* name
	char* prefix
	char* local
	char* ns_uri
	char* value


struct xml_ns_binding:
	char* prefix
	char* uri


struct xml_reader:
	char* input
	int pos
	int start
	int event
	int event_pos
	char* name
	char* prefix
	char* local
	char* ns_uri
	char* text
	char* target
	char* version
	char* encoding
	char* standalone
	list[xml_attr*] attrs
	int empty
	int pending_end
	list[char*] open_tags
	list[xml_ns_binding*] ns_stack
	list[int] ns_marks
	int seen_root
	int root_done
	int seen_doctype
	int max_depth
	int validated
	char* error
	int error_line
	int error_col


# The namespace names reserved by Namespaces in XML 1.0.
char* xml_namespace_xml():
	return c"http://www.w3.org/XML/1998/namespace"


char* xml_namespace_xmlns():
	return c"http://www.w3.org/2000/xmlns/"


int xml_streq(char* a, char* b):
	return strcmp(a, b) == 0


char* xml_strndup(char* s, int n):
	char* out = cast(char*, malloc(n + 1))
	int i = 0
	while (i < n):
		out[i] = s[i]
		i = i + 1
	out[n] = 0
	return out


char* xml_builder_take(string_builder* sb):
	char* data = sb.data
	free(sb)
	return data


void xml_free_string(char* s):
	if (s != 0): free(s)


void xml_attr_free(xml_attr* a):
	xml_free_string(a.name)
	xml_free_string(a.prefix)
	xml_free_string(a.local)
	xml_free_string(a.ns_uri)
	xml_free_string(a.value)
	free(a)


# Legal XML 1.0 Char production.
int xml_is_char(int cp):
	if ((cp == 9) || (cp == 10) || (cp == 13)): return 1
	if ((cp >= 32) && (cp <= 0xd7ff)): return 1
	if ((cp >= 0xe000) && (cp <= 0xfffd)): return 1
	if ((cp >= 0x10000) && (cp <= 0x10ffff)): return 1
	return 0


int xml_is_name_start(int cp):
	if (((cp >= 'a') && (cp <= 'z')) || ((cp >= 'A') && (cp <= 'Z'))): return 1
	if ((cp == '_') || (cp == ':')): return 1
	if (cp < 0xc0): return 0
	if ((cp == 0xd7) || (cp == 0xf7)): return 0
	if (cp <= 0x2ff): return 1
	if ((cp >= 0x370) && (cp <= 0x1fff) && (cp != 0x37e)): return 1
	if ((cp == 0x200c) || (cp == 0x200d)): return 1
	if ((cp >= 0x2070) && (cp <= 0x218f)): return 1
	if ((cp >= 0x2c00) && (cp <= 0x2fef)): return 1
	if ((cp >= 0x3001) && (cp <= 0xd7ff)): return 1
	if ((cp >= 0xf900) && (cp <= 0xfdcf)): return 1
	if ((cp >= 0xfdf0) && (cp <= 0xfffd)): return 1
	if ((cp >= 0x10000) && (cp <= 0xeffff)): return 1
	return 0


int xml_is_name_char(int cp):
	if (xml_is_name_start(cp)): return 1
	if ((cp == '-') || (cp == '.') || ((cp >= '0') && (cp <= '9'))): return 1
	if (cp == 0xb7): return 1
	if ((cp >= 0x300) && (cp <= 0x36f)): return 1
	if ((cp >= 0x203f) && (cp <= 0x2040)): return 1
	return 0


int xml_is_space(int c):
	return (c == ' ') || (c == '\n') || (c == '\r') || (c == '\t')


# Decode the (already validated) UTF-8 character at s[0]; returns its
# length and stores the code point. A NUL decodes as length 1, cp 0.
int xml_decode(char* s, int* cp):
	int n = utf8_scan(s, 4, cp)
	if (n == 0):
		*cp = s[0] & 255
		return 1
	return n


# Length in bytes of the XML Name starting at s, or 0 when none does.
int xml_name_length(char* s):
	int cp = 0
	int n = xml_decode(s, &cp)
	if (xml_is_name_start(cp) == 0): return 0
	int len = n
	while (s[len] != 0):
		n = xml_decode(&s[len], &cp)
		if (xml_is_name_char(cp) == 0): return len
		len = len + n
	return len


# 1-based line and 0-based byte column of input[pos]; a CR, LF or
# CRLF each end one line.
void xml_line_col(char* input, int pos, int* line, int* col):
	int l = 1
	int line_start = 0
	int i = 0
	while ((i < pos) && (input[i] != 0)):
		int c = input[i]
		if (c == '\n'):
			l = l + 1
			line_start = i + 1
		else if (c == '\r'):
			if (input[i + 1] != '\n'):
				l = l + 1
				line_start = i + 1
		i = i + 1
	*line = l
	*col = pos - line_start


# Record a sticky error at byte offset pos. Always returns 0 so
# scanners can `return xml_fail(...)`.
int xml_fail(xml_reader* r, char* reason, int pos):
	if (r.error != 0): return 0
	int line = 0
	int col = 0
	xml_line_col(r.input, pos, &line, &col)
	r.error_line = line
	r.error_col = col
	string_builder* sb = string_new()
	string_append(sb, reason)
	string_append(sb, c": line ")
	string_append_int(sb, line)
	string_append(sb, c", column ")
	string_append_int(sb, col)
	r.error = xml_builder_take(sb)
	r.event = XML_ERROR
	return 0


xml_reader* xml_reader_new(char* text):
	xml_reader* r = new xml_reader()
	r.input = text
	r.pos = 0
	r.start = 0
	# A UTF-8 byte order mark is skipped.
	if (((text[0] & 255) == 0xef) && ((text[1] & 255) == 0xbb) && ((text[2] & 255) == 0xbf)):
		r.pos = 3
		r.start = 3
	r.event = -1
	r.event_pos = 0
	r.name = 0
	r.prefix = 0
	r.local = 0
	r.ns_uri = 0
	r.text = 0
	r.target = 0
	r.version = 0
	r.encoding = 0
	r.standalone = 0
	r.attrs = new list[xml_attr*]
	r.empty = 0
	r.pending_end = 0
	r.open_tags = new list[char*]
	r.ns_stack = new list[xml_ns_binding*]
	r.ns_marks = new list[int]
	r.seen_root = 0
	r.root_done = 0
	r.seen_doctype = 0
	r.max_depth = 1000
	r.validated = 0
	r.error = 0
	r.error_line = 0
	r.error_col = 0
	return r


void xml_clear_event(xml_reader* r):
	xml_free_string(r.name)
	xml_free_string(r.prefix)
	xml_free_string(r.local)
	xml_free_string(r.ns_uri)
	xml_free_string(r.text)
	xml_free_string(r.target)
	xml_free_string(r.version)
	xml_free_string(r.encoding)
	xml_free_string(r.standalone)
	r.name = 0
	r.prefix = 0
	r.local = 0
	r.ns_uri = 0
	r.text = 0
	r.target = 0
	r.version = 0
	r.encoding = 0
	r.standalone = 0
	for xml_attr* a in r.attrs: xml_attr_free(a)
	r.attrs.clear()
	r.empty = 0


void xml_pop_bindings(xml_reader* r, int mark):
	while (r.ns_stack.length > mark):
		xml_ns_binding* b = r.ns_stack.pop()
		free(b.prefix)
		free(b.uri)
		free(b)


void xml_reader_free(xml_reader* r):
	if (r == 0): return
	xml_clear_event(r)
	r.attrs.free()
	for char* t in r.open_tags: free(t)
	r.open_tags.free()
	xml_pop_bindings(r, 0)
	r.ns_stack.free()
	r.ns_marks.free()
	xml_free_string(r.error)
	free(r)


# Value of the attribute with qualified name qname on the current start
# event, or 0.
char* xml_reader_attr(xml_reader* r, char* qname):
	for xml_attr* a in r.attrs:
		if (xml_streq(a.name, qname)): return a.value
	return 0


# Value of the attribute with namespace uri ("" for none) and local
# name on the current start event, or 0.
char* xml_reader_attr_ns(xml_reader* r, char* uri, char* local):
	for xml_attr* a in r.attrs:
		if (xml_streq(a.ns_uri, uri) && xml_streq(a.local, local)): return a.value
	return 0


# Every character of the document must be legal UTF-8 and an XML Char.
int xml_validate_chars(xml_reader* r):
	int i = r.start
	int cp = 0
	while (r.input[i] != 0):
		int n = utf8_scan(&r.input[i], 4, &cp)
		if (n == 0): return xml_fail(r, c"not well-formed (invalid UTF-8)", i)
		if (xml_is_char(cp) == 0): return xml_fail(r, c"not well-formed (invalid token)", i)
		i = i + n
	return 1


int xml_starts(xml_reader* r, char* word):
	int i = 0
	while (word[i] != 0):
		if (r.input[r.pos + i] != word[i]): return 0
		i = i + 1
	return 1


int xml_skip_space(xml_reader* r):
	int n = 0
	while (xml_is_space(r.input[r.pos])):
		r.pos = r.pos + 1
		n = n + 1
	return n


void xml_append_utf8(string_builder* out, int cp):
	if (cp < 0x80): string_append_char(out, cp)
	else if (cp < 0x800):
		string_append_char(out, 0xc0 | (cp >> 6))
		string_append_char(out, 0x80 | (cp & 63))
	else if (cp < 0x10000):
		string_append_char(out, 0xe0 | (cp >> 12))
		string_append_char(out, 0x80 | ((cp >> 6) & 63))
		string_append_char(out, 0x80 | (cp & 63))
	else:
		string_append_char(out, 0xf0 | (cp >> 18))
		string_append_char(out, 0x80 | ((cp >> 12) & 63))
		string_append_char(out, 0x80 | ((cp >> 6) & 63))
		string_append_char(out, 0x80 | (cp & 63))


int xml_hex_digit(int c):
	if ((c >= '0') && (c <= '9')): return c - '0'
	if ((c >= 'a') && (c <= 'f')): return c - 'a' + 10
	if ((c >= 'A') && (c <= 'F')): return c - 'A' + 10
	return -1


# Decode the reference at r.pos (on the '&') into out and step past it.
int xml_parse_reference(xml_reader* r, string_builder* out):
	int at = r.pos
	char* s = r.input
	int i = at + 1
	if (s[i] == '#'):
		i = i + 1
		int base = 10
		if (s[i] == 'x'):
			base = 16
			i = i + 1
		int value = 0
		int digits = 0
		while 1:
			int d = xml_hex_digit(s[i])
			if ((d < 0) || (d >= base)): break
			# Saturate past the Unicode range instead of overflowing.
			if (value <= 0x10ffff): value = value * base + d
			digits = digits + 1
			i = i + 1
		if ((digits == 0) || (s[i] != ';')): return xml_fail(r, c"not well-formed (invalid token)", at)
		if (xml_is_char(value) == 0): return xml_fail(r, c"reference to invalid character number", at)
		xml_append_utf8(out, value)
		r.pos = i + 1
		return 1
	int n = xml_name_length(&s[i])
	if (n == 0): return xml_fail(r, c"not well-formed (invalid token)", at)
	if (s[i + n] != ';'): return xml_fail(r, c"not well-formed (invalid token)", at)
	char* name = xml_strndup(&s[i], n)
	int c = 0
	if (xml_streq(name, c"amp")): c = '&'
	else if (xml_streq(name, c"lt")): c = '<'
	else if (xml_streq(name, c"gt")): c = '>'
	else if (xml_streq(name, c"quot")): c = '"'
	else if (xml_streq(name, c"apos")): c = '\''
	free(name)
	if (c == 0): return xml_fail(r, c"undefined entity", at)
	string_append_char(out, c)
	r.pos = i + n + 1
	return 1


# Character data up to the next '<' (or the end), decoded into r.text.
int xml_scan_text(xml_reader* r):
	string_builder* out = string_new()
	char* s = r.input
	while ((s[r.pos] != 0) && (s[r.pos] != '<')):
		int c = s[r.pos]
		if (c == '&'):
			if (xml_parse_reference(r, out) == 0):
				string_free(out)
				return 0
		else if (c == '\r'):
			string_append_char(out, '\n')
			r.pos = r.pos + 1
			if (s[r.pos] == '\n'): r.pos = r.pos + 1
		else:
			if ((c == ']') && (s[r.pos + 1] == ']') && (s[r.pos + 2] == '>')):
				string_free(out)
				return xml_fail(r, c"not well-formed (invalid token)", r.pos)
			string_append_char(out, c)
			r.pos = r.pos + 1
	r.text = xml_builder_take(out)
	return 1


# Quoted attribute value at r.pos, decoded and normalized.
char* xml_scan_attr_value(xml_reader* r):
	char* s = r.input
	int quote = s[r.pos]
	if ((quote != '"') && (quote != '\'')):
		xml_fail(r, c"not well-formed (invalid token)", r.pos)
		return 0
	r.pos = r.pos + 1
	string_builder* out = string_new()
	while (s[r.pos] != quote):
		int c = s[r.pos]
		if (c == 0):
			string_free(out)
			xml_fail(r, c"unclosed token", r.pos)
			return 0
		if (c == '<'):
			string_free(out)
			xml_fail(r, c"not well-formed (invalid token)", r.pos)
			return 0
		if (c == '&'):
			if (xml_parse_reference(r, out) == 0):
				string_free(out)
				return 0
		else if (c == '\r'):
			string_append_char(out, ' ')
			r.pos = r.pos + 1
			if (s[r.pos] == '\n'): r.pos = r.pos + 1
		else if ((c == '\n') || (c == '\t')):
			string_append_char(out, ' ')
			r.pos = r.pos + 1
		else:
			string_append_char(out, c)
			r.pos = r.pos + 1
	r.pos = r.pos + 1
	return xml_builder_take(out)


# The namespace URI bound to prefix ("" = default namespace) in scope,
# or 0 when it is unbound. The default namespace starts out as "".
char* xml_lookup_ns(xml_reader* r, char* prefix):
	int i = r.ns_stack.length - 1
	while (i >= 0):
		xml_ns_binding* b = r.ns_stack[i]
		if (xml_streq(b.prefix, prefix)): return b.uri
		i = i - 1
	if (xml_streq(prefix, c"xml")): return xml_namespace_xml()
	if (prefix[0] == 0): return c""
	return 0


# Split qname into owned prefix/local ("" prefix when unprefixed).
# Returns 0 when it is not a valid QName (empty part or extra colon).
int xml_split_qname(char* qname, char** prefix, char** local):
	int colon = -1
	int i = 0
	while (qname[i] != 0):
		if (qname[i] == ':'):
			if (colon >= 0): return 0
			colon = i
		i = i + 1
	if (colon < 0):
		*prefix = strclone(c"")
		*local = strclone(qname)
		return 1
	if ((colon == 0) || (qname[colon + 1] == 0)): return 0
	*prefix = xml_strndup(qname, colon)
	*local = strclone(&qname[colon + 1])
	return 1


# Fill r.prefix/local/ns_uri for element name r.name.
int xml_resolve_element(xml_reader* r, int at):
	char* prefix = 0
	char* local = 0
	if (xml_split_qname(r.name, &prefix, &local) == 0): return xml_fail(r, c"not well-formed (invalid qualified name)", at)
	r.prefix = prefix
	r.local = local
	if (xml_streq(prefix, c"xmlns")): return xml_fail(r, c"reserved prefix (xmlns) must not be used as an element prefix", at)
	char* uri = xml_lookup_ns(r, prefix)
	if (uri == 0): return xml_fail(r, c"unbound prefix", at)
	r.ns_uri = strclone(uri)
	return 1


void xml_push_binding(xml_reader* r, char* prefix, char* uri):
	xml_ns_binding* b = new xml_ns_binding()
	b.prefix = strclone(prefix)
	b.uri = strclone(uri)
	r.ns_stack.push(b)


# Namespace declarations and name resolution for the start tag just
# read (bindings were marked by the caller).
int xml_process_namespaces(xml_reader* r, int at):
	for xml_attr* a in r.attrs:
		if (xml_split_qname(a.name, &a.prefix, &a.local) == 0): return xml_fail(r, c"not well-formed (invalid qualified name)", at)
		int is_default = xml_streq(a.name, c"xmlns")
		int is_prefixed = xml_streq(a.prefix, c"xmlns")
		if (is_default || is_prefixed):
			char* declared = c""
			if (is_prefixed): declared = a.local
			if (xml_streq(declared, c"xmlns")):
				return xml_fail(r, c"reserved prefix (xmlns) must not be declared or undeclared", at)
			if (xml_streq(declared, c"xml")):
				if (xml_streq(a.value, xml_namespace_xml()) == 0):
					return xml_fail(r, c"reserved prefix (xml) must not be undeclared or bound to another namespace name", at)
			else if (xml_streq(a.value, xml_namespace_xml()) || xml_streq(a.value, xml_namespace_xmlns())):
				return xml_fail(r, c"prefix must not be bound to one of the reserved namespace names", at)
			if (is_prefixed && (a.value[0] == 0)): return xml_fail(r, c"must not undeclare prefix", at)
			xml_push_binding(r, declared, a.value)
	for xml_attr* b in r.attrs:
		if (xml_streq(b.name, c"xmlns") || xml_streq(b.prefix, c"xmlns")):
			b.ns_uri = strclone(xml_namespace_xmlns())
		else if (b.prefix[0] == 0):
			b.ns_uri = strclone(c"")
		else:
			char* uri = xml_lookup_ns(r, b.prefix)
			if (uri == 0): return xml_fail(r, c"unbound prefix", at)
			b.ns_uri = strclone(uri)
	# Two attributes with the same expanded name.
	int i = 0
	while (i < r.attrs.length):
		xml_attr* x = r.attrs[i]
		if (x.ns_uri[0] != 0):
			int j = 0
			while (j < i):
				xml_attr* y = r.attrs[j]
				if (xml_streq(x.ns_uri, y.ns_uri) && xml_streq(x.local, y.local)): return xml_fail(r, c"duplicate attribute", at)
				j = j + 1
		i = i + 1
	return xml_resolve_element(r, at)


int xml_scan_start_tag(xml_reader* r):
	int at = r.pos
	char* s = r.input
	r.pos = r.pos + 1
	int n = xml_name_length(&s[r.pos])
	if (n == 0): return xml_fail(r, c"not well-formed (invalid token)", r.pos)
	if (r.root_done): return xml_fail(r, c"junk after document element", at)
	r.name = xml_strndup(&s[r.pos], n)
	r.pos = r.pos + n
	while 1:
		int spaced = xml_skip_space(r)
		int c = s[r.pos]
		if (c == '>'):
			r.pos = r.pos + 1
			break
		if ((c == '/') && (s[r.pos + 1] == '>')):
			r.pos = r.pos + 2
			r.empty = 1
			break
		if (c == 0): return xml_fail(r, c"unclosed token", r.pos)
		int name_len = xml_name_length(&s[r.pos])
		if ((spaced == 0) || (name_len == 0)): return xml_fail(r, c"not well-formed (invalid token)", r.pos)
		int attr_at = r.pos
		char* attr_name = xml_strndup(&s[r.pos], name_len)
		r.pos = r.pos + name_len
		xml_skip_space(r)
		if (s[r.pos] != '='):
			free(attr_name)
			return xml_fail(r, c"not well-formed (invalid token)", r.pos)
		r.pos = r.pos + 1
		xml_skip_space(r)
		char* value = xml_scan_attr_value(r)
		if (value == 0):
			free(attr_name)
			return 0
		if (xml_reader_attr(r, attr_name) != 0):
			free(attr_name)
			free(value)
			return xml_fail(r, c"duplicate attribute", attr_at)
		xml_attr* a = new xml_attr()
		a.name = attr_name
		a.prefix = 0
		a.local = 0
		a.ns_uri = 0
		a.value = value
		r.attrs.push(a)
	if (r.open_tags.length >= r.max_depth): return xml_fail(r, c"nesting too deep", at)
	r.ns_marks.push(r.ns_stack.length)
	r.open_tags.push(strclone(r.name))
	r.seen_root = 1
	if (xml_process_namespaces(r, at) == 0): return 0
	if (r.empty): r.pending_end = 1
	r.event = XML_START
	return 1


# Report the end of the innermost open element and close it.
int xml_emit_end(xml_reader* r, int at):
	r.name = strclone(r.open_tags[-1])
	if (xml_resolve_element(r, at) == 0): return 0
	xml_pop_bindings(r, r.ns_marks.pop())
	free(r.open_tags.pop())
	if (r.open_tags.length == 0): r.root_done = 1
	r.event = XML_END
	return 1


int xml_scan_end_tag(xml_reader* r):
	int at = r.pos
	char* s = r.input
	r.pos = r.pos + 2
	int n = xml_name_length(&s[r.pos])
	if (n == 0): return xml_fail(r, c"not well-formed (invalid token)", r.pos)
	if (r.open_tags.length == 0):
		if (r.root_done): return xml_fail(r, c"junk after document element", at)
		return xml_fail(r, c"not well-formed (invalid token)", at)
	char* top = r.open_tags[-1]
	int matches = (strlen(top) == n)
	if (matches):
		int i = 0
		while (i < n):
			if (top[i] != s[r.pos + i]): matches = 0
			i = i + 1
	if (matches == 0): return xml_fail(r, c"mismatched tag", at)
	r.pos = r.pos + n
	xml_skip_space(r)
	if (s[r.pos] != '>'):
		if (s[r.pos] == 0): return xml_fail(r, c"unclosed token", r.pos)
		return xml_fail(r, c"not well-formed (invalid token)", r.pos)
	r.pos = r.pos + 1
	return xml_emit_end(r, at)


int xml_scan_comment(xml_reader* r):
	int at = r.pos
	char* s = r.input
	r.pos = r.pos + 4
	int body = r.pos
	while 1:
		if (s[r.pos] == 0): return xml_fail(r, c"unclosed token", at)
		if ((s[r.pos] == '-') && (s[r.pos + 1] == '-')):
			if (s[r.pos + 2] != '>'): return xml_fail(r, c"not well-formed (invalid token)", r.pos)
			break
		r.pos = r.pos + 1
	string_builder* out = string_new()
	int i = body
	while (i < r.pos):
		if (s[i] == '\r'):
			string_append_char(out, '\n')
			if (s[i + 1] == '\n'): i = i + 1
		else: string_append_char(out, s[i])
		i = i + 1
	r.text = xml_builder_take(out)
	r.pos = r.pos + 3
	r.event = XML_COMMENT
	return 1


int xml_scan_cdata(xml_reader* r):
	int at = r.pos
	char* s = r.input
	if (r.open_tags.length == 0): return xml_fail(r, c"not well-formed (invalid token)", at)
	r.pos = r.pos + 9
	string_builder* out = string_new()
	while 1:
		int c = s[r.pos]
		if (c == 0):
			string_free(out)
			return xml_fail(r, c"unclosed CDATA section", at)
		if ((c == ']') && (s[r.pos + 1] == ']') && (s[r.pos + 2] == '>')): break
		if (c == '\r'):
			string_append_char(out, '\n')
			if (s[r.pos + 1] == '\n'): r.pos = r.pos + 1
		else: string_append_char(out, c)
		r.pos = r.pos + 1
	r.pos = r.pos + 3
	r.text = xml_builder_take(out)
	r.event = XML_CDATA
	return 1


# One pseudo-attribute of the XML declaration: name="value". Returns
# the owned value, or 0 when the next thing is not that name.
char* xml_decl_attr(xml_reader* r, char* name):
	int save = r.pos
	int spaced = xml_skip_space(r)
	if ((spaced == 0) || (xml_starts(r, name) == 0)):
		r.pos = save
		return 0
	r.pos = r.pos + strlen(name)
	xml_skip_space(r)
	if (r.input[r.pos] != '='):
		r.pos = save
		return 0
	r.pos = r.pos + 1
	xml_skip_space(r)
	int quote = r.input[r.pos]
	if ((quote != '"') && (quote != '\'')):
		r.pos = save
		return 0
	int begin = r.pos + 1
	int i = begin
	while ((r.input[i] != quote) && (r.input[i] != 0) && (r.input[i] != '?')): i = i + 1
	if (r.input[i] != quote):
		r.pos = save
		return 0
	r.pos = i + 1
	return xml_strndup(&r.input[begin], i - begin)


int xml_decl_version_ok(char* v):
	if ((v[0] != '1') || (v[1] != '.') || (v[2] == 0)): return 0
	int i = 2
	while (v[i] != 0):
		if ((v[i] < '0') || (v[i] > '9')): return 0
		i = i + 1
	return 1


int xml_decl_encoding_ok(char* e):
	int c = e[0]
	int letter = ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z'))
	if (letter == 0): return 0
	int i = 1
	while (e[i] != 0):
		c = e[i]
		int ok = ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || ((c >= '0') && (c <= '9'))
		if ((ok == 0) && (c != '.') && (c != '_') && (c != '-')): return 0
		i = i + 1
	return 1


int xml_scan_decl(xml_reader* r, int at):
	r.pos = at + 5
	r.version = xml_decl_attr(r, c"version")
	if ((r.version == 0) || (xml_decl_version_ok(r.version) == 0)): return xml_fail(r, c"XML declaration not well-formed", at)
	r.encoding = xml_decl_attr(r, c"encoding")
	if (r.encoding == 0): r.encoding = strclone(c"")
	else if (xml_decl_encoding_ok(r.encoding) == 0): return xml_fail(r, c"XML declaration not well-formed", at)
	r.standalone = xml_decl_attr(r, c"standalone")
	if (r.standalone == 0): r.standalone = strclone(c"")
	else if ((xml_streq(r.standalone, c"yes") || xml_streq(r.standalone, c"no")) == 0):
		return xml_fail(r, c"XML declaration not well-formed", at)
	xml_skip_space(r)
	if (xml_starts(r, c"?>") == 0): return xml_fail(r, c"XML declaration not well-formed", at)
	r.pos = r.pos + 2
	r.event = XML_DECL
	return 1


int xml_scan_pi(xml_reader* r):
	int at = r.pos
	char* s = r.input
	r.pos = r.pos + 2
	int n = xml_name_length(&s[r.pos])
	if (n == 0): return xml_fail(r, c"not well-formed (invalid token)", r.pos)
	char* target = xml_strndup(&s[r.pos], n)
	int lower_xml = 0
	if (n == 3):
		lower_xml = ((s[r.pos] | 32) == 'x') && ((s[r.pos + 1] | 32) == 'm') && ((s[r.pos + 2] | 32) == 'l')
	if (lower_xml):
		int exact = xml_streq(target, c"xml")
		free(target)
		if (exact && (at == r.start)): return xml_scan_decl(r, at)
		if (exact): return xml_fail(r, c"XML or text declaration not at start of entity", at)
		return xml_fail(r, c"reserved processing instruction target", at)
	r.target = target
	r.pos = r.pos + n
	if (xml_starts(r, c"?>")):
		r.pos = r.pos + 2
		r.text = strclone(c"")
		r.event = XML_PI
		return 1
	if (xml_skip_space(r) == 0): return xml_fail(r, c"not well-formed (invalid token)", r.pos)
	int body = r.pos
	while (xml_starts(r, c"?>") == 0):
		if (s[r.pos] == 0): return xml_fail(r, c"unclosed token", at)
		r.pos = r.pos + 1
	string_builder* out = string_new()
	int i = body
	while (i < r.pos):
		if (s[i] == '\r'):
			string_append_char(out, '\n')
			if (s[i + 1] == '\n'): i = i + 1
		else: string_append_char(out, s[i])
		i = i + 1
	r.text = xml_builder_take(out)
	r.pos = r.pos + 2
	r.event = XML_PI
	return 1


# Step over a quoted literal at r.pos; 0 at end of input.
int xml_skip_quoted(xml_reader* r):
	int quote = r.input[r.pos]
	r.pos = r.pos + 1
	while (r.input[r.pos] != quote):
		if (r.input[r.pos] == 0): return 0
		r.pos = r.pos + 1
	r.pos = r.pos + 1
	return 1


# Skip the internal subset from just after '[' to just after ']'.
int xml_skip_internal_subset(xml_reader* r, int at):
	char* s = r.input
	while (s[r.pos] != ']'):
		int c = s[r.pos]
		if (c == 0): return xml_fail(r, c"unclosed token", at)
		if ((c == '"') || (c == '\'')):
			if (xml_skip_quoted(r) == 0): return xml_fail(r, c"unclosed token", at)
		else if (xml_starts(r, c"<!--")):
			r.pos = r.pos + 4
			while (xml_starts(r, c"-->") == 0):
				if (s[r.pos] == 0): return xml_fail(r, c"unclosed token", at)
				r.pos = r.pos + 1
			r.pos = r.pos + 3
		else if (xml_starts(r, c"<?")):
			while (xml_starts(r, c"?>") == 0):
				if (s[r.pos] == 0): return xml_fail(r, c"unclosed token", at)
				r.pos = r.pos + 1
			r.pos = r.pos + 2
		else: r.pos = r.pos + 1
	r.pos = r.pos + 1
	return 1


int xml_scan_doctype(xml_reader* r):
	int at = r.pos
	char* s = r.input
	if (r.seen_root || r.seen_doctype): return xml_fail(r, c"not well-formed (invalid token)", at)
	r.pos = r.pos + 9
	if (xml_skip_space(r) == 0): return xml_fail(r, c"not well-formed (invalid token)", r.pos)
	int n = xml_name_length(&s[r.pos])
	if (n == 0): return xml_fail(r, c"not well-formed (invalid token)", r.pos)
	r.name = xml_strndup(&s[r.pos], n)
	r.pos = r.pos + n
	xml_skip_space(r)
	int body = r.pos
	while (s[r.pos] != '>'):
		int c = s[r.pos]
		if (c == 0): return xml_fail(r, c"unclosed token", at)
		if ((c == '"') || (c == '\'')):
			if (xml_skip_quoted(r) == 0): return xml_fail(r, c"unclosed token", at)
		else if (c == '['):
			r.pos = r.pos + 1
			if (xml_skip_internal_subset(r, at) == 0): return 0
		else: r.pos = r.pos + 1
	int end = r.pos
	while ((end > body) && xml_is_space(s[end - 1])): end = end - 1
	r.text = xml_strndup(&s[body], end - body)
	r.pos = r.pos + 1
	r.seen_doctype = 1
	r.event = XML_DOCTYPE
	return 1


# Advance to the next event; see the header for the event kinds.
int xml_next(xml_reader* r):
	if ((r.event == XML_ERROR) || (r.event == XML_EOF)): return r.event
	xml_clear_event(r)
	if (r.validated == 0):
		r.validated = 1
		if (xml_validate_chars(r) == 0): return XML_ERROR
	if (r.pending_end):
		r.pending_end = 0
		r.event_pos = r.pos
		if (xml_emit_end(r, r.pos) == 0): return XML_ERROR
		return r.event
	char* s = r.input
	while 1:
		r.event_pos = r.pos
		int c = s[r.pos]
		int ok = 1
		if (c == 0):
			if (r.seen_root == 0): xml_fail(r, c"no element found", r.pos)
			else if (r.open_tags.length > 0): xml_fail(r, c"no element found", r.pos)
			else: r.event = XML_EOF
			return r.event
		if (c != '<'):
			if (r.open_tags.length > 0):
				ok = xml_scan_text(r)
				r.event = XML_TEXT
			else:
				xml_skip_space(r)
				if ((s[r.pos] != 0) && (s[r.pos] != '<')):
					if (r.root_done): xml_fail(r, c"junk after document element", r.pos)
					else: xml_fail(r, c"syntax error", r.pos)
					return XML_ERROR
				continue
		else if (s[r.pos + 1] == '/'): ok = xml_scan_end_tag(r)
		else if (s[r.pos + 1] == '?'): ok = xml_scan_pi(r)
		else if (xml_starts(r, c"<!--")): ok = xml_scan_comment(r)
		else if (xml_starts(r, c"<![CDATA[")): ok = xml_scan_cdata(r)
		else if (xml_starts(r, c"<!DOCTYPE")): ok = xml_scan_doctype(r)
		else if (s[r.pos + 1] == '!'): ok = xml_fail(r, c"not well-formed (invalid token)", r.pos)
		else: ok = xml_scan_start_tag(r)
		if (ok == 0):
			r.event = XML_ERROR
			return XML_ERROR
		return r.event
