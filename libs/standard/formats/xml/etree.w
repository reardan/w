/*
ElementTree subset (stdlib parity P3.4b; Python reference:
Lib/xml/etree/ElementTree.py and ElementPath.py).

	char* err = 0
	xml_element* root = xml_fromstring_error(text, &err)
	if (root == 0): print(err)  # "mismatched tag: line 3, column 2"
	for xml_element* item in ... xml_findall(root, c".//item[@id]") ...
	char* out = xml_tostring(root)
	xml_element_free(root)

Elements carry Python's fields: tag, attrib (an ordered list of
xml_attrib name/value pairs), text and tail (0 when absent, like None)
and children. Namespaced names use Clark notation, "{uri}local", as
Python does; xmlns declarations are consumed by the parser and do not
appear in attrib. Comments, processing instructions, the XML
declaration and DOCTYPE are dropped (the default TreeBuilder behavior).
Parsing is the XXE-safe pull tokenizer in tokenizer.w: no DTD
processing, no external entities, only the five predefined entities.

Ownership: an element owns its strings, attributes and children, and
xml_element_free releases the whole subtree. Lookup results (xml_find,
xml_get, xml_findtext, the members of the lists xml_findall / xml_iter /
xml_itertext return) are borrowed from the tree; the returned lists
themselves belong to the caller (free them with .free()). xml_tostring,
xml_text_content, xml_escape_text and xml_escape_attr return owned
strings.

Paths (xml_find / xml_findall / xml_findtext), relative to the element:
- `tag`, `{uri}tag`, `*`, `{*}tag` (any or no namespace), `{}tag`
  (no namespace), `{uri}*`, `{}*`
- `a/b` children of children; `.` the element itself; `//` selects all
  descendants (`.//tag`, `a//b`)
- predicates: `[@attr]`, `[@attr='v']`, `[@attr!='v']`, `[tag]`,
  `[tag='text']`, `[.='text']` (text compares the full text content),
  `[n]` (1-based position among same-tag siblings), `[last()]`,
  `[last()-n]`; either quote style
An invalid path (absolute, `..`, bad predicate, empty step) matches
nothing.

Serialization (xml_tostring) mirrors ElementTree.tostring with
encoding="unicode": `<tag />` for an element with neither text nor
children, text escaping & < >, attribute escaping & < > " and \n \r \t
as character references (so a parse -> serialize -> parse round trip
is exact), namespace prefixes ns0, ns1, ... (or Python's well-known
ones: xml, html, rdf, wsdl, xs, xsi, dc) declared on the top element,
and the top element's tail included.
*/
import lib.lib
import structures.string
import libs.standard.formats.xml.tokenizer


struct xml_attrib:
	char* name
	char* value


struct xml_element:
	char* tag
	list[xml_attrib*] attrib
	char* text
	char* tail
	list[xml_element*] children


void xml_element_free(xml_element* e);
char* xml_text_content(xml_element* e);


xml_element* xml_element_new(char* tag):
	xml_element* e = new xml_element()
	e.tag = strclone(tag)
	e.attrib = new list[xml_attrib*]
	e.text = 0
	e.tail = 0
	e.children = new list[xml_element*]
	return e


void xml_element_free(xml_element* e):
	if (e == 0): return
	free(e.tag)
	for xml_attrib* a in e.attrib:
		free(a.name)
		free(a.value)
		free(a)
	e.attrib.free()
	xml_free_string(e.text)
	xml_free_string(e.tail)
	for xml_element* child in e.children: xml_element_free(child)
	e.children.free()
	free(e)


# Append child (the parent takes ownership).
void xml_element_append(xml_element* parent, xml_element* child):
	parent.children.push(child)


# New child element appended to parent (Python SubElement).
xml_element* xml_subelement(xml_element* parent, char* tag):
	xml_element* e = xml_element_new(tag)
	xml_element_append(parent, e)
	return e


# Detach child from parent and hand it back to the caller; 0 when it is
# not a direct child.
xml_element* xml_element_remove(xml_element* parent, xml_element* child):
	int i = 0
	while (i < parent.children.length):
		if (parent.children[i] == child):
			parent.children.remove(i)
			return child
		i = i + 1
	return 0


int xml_element_len(xml_element* e):
	return e.children.length


# Attribute value, or 0 when absent (borrowed).
char* xml_get(xml_element* e, char* name):
	for xml_attrib* a in e.attrib:
		if (xml_streq(a.name, name)): return a.value
	return 0


# Set an attribute (copied), keeping its position when it exists.
void xml_set(xml_element* e, char* name, char* value):
	for xml_attrib* a in e.attrib:
		if (xml_streq(a.name, name)):
			free(a.value)
			a.value = strclone(value)
			return
	xml_attrib* n = new xml_attrib()
	n.name = strclone(name)
	n.value = strclone(value)
	e.attrib.push(n)


# Replace text (copied; 0 clears it).
void xml_set_text(xml_element* e, char* text):
	xml_free_string(e.text)
	e.text = 0
	if (text != 0): e.text = strclone(text)


void xml_set_tail(xml_element* e, char* tail):
	xml_free_string(e.tail)
	e.tail = 0
	if (tail != 0): e.tail = strclone(tail)


# ---- parsing ----


void xml_append_to(char** slot, char* more):
	if (*slot == 0):
		*slot = strclone(more)
		return
	char* joined = strjoin(*slot, more)
	free(*slot)
	*slot = joined


# "{uri}local", or local alone when uri is "".
char* xml_clark(char* uri, char* local):
	if (uri[0] == 0): return strclone(local)
	string_builder* sb = string_new()
	string_append_char(sb, '{')
	string_append(sb, uri)
	string_append_char(sb, '}')
	string_append(sb, local)
	return xml_builder_take(sb)


# Parse a document; returns its root element, or 0 with *error set to an
# owned message ("reason: line L, column C") when error is not 0.
xml_element* xml_fromstring_error(char* text, char** error):
	if (error != 0): *error = 0
	xml_reader* r = xml_reader_new(text)
	xml_element* root = 0
	xml_element* last = 0
	list[xml_element*] stack = new list[xml_element*]
	int ev = xml_next(r)
	while ((ev != XML_EOF) && (ev != XML_ERROR)):
		if (ev == XML_START):
			char* tag = xml_clark(r.ns_uri, r.local)
			xml_element* e = xml_element_new(tag)
			free(tag)
			for xml_attr* a in r.attrs:
				if (xml_streq(a.ns_uri, xml_namespace_xmlns()) == 0):
					char* name = xml_clark(a.ns_uri, a.local)
					xml_set(e, name, a.value)
					free(name)
			if (stack.length == 0): root = e
			else: xml_element_append(stack[-1], e)
			stack.push(e)
			last = 0
		else if (ev == XML_END):
			last = stack.pop()
		else if ((ev == XML_TEXT) || (ev == XML_CDATA)):
			if (last != 0): xml_append_to(&last.tail, r.text)
			else:
				xml_element* parent = stack[-1]
				xml_append_to(&parent.text, r.text)
		ev = xml_next(r)
	stack.free()
	if (ev == XML_ERROR):
		if (error != 0): *error = strclone(r.error)
		xml_element_free(root)
		root = 0
	xml_reader_free(r)
	return root


# Parse a document; 0 when it is not well-formed.
xml_element* xml_fromstring(char* text):
	return xml_fromstring_error(text, 0)


# ---- iteration ----


# Local part of a Clark name.
char* xml_tag_local(char* tag):
	if (tag[0] != '{'): return tag
	int i = 1
	while ((tag[i] != 0) && (tag[i] != '}')): i = i + 1
	if (tag[i] == 0): return tag
	return &tag[i + 1]


# Does tag match pattern: "*", "{*}local", "{}local", "{uri}*", "{}*"
# or an exact name.
int xml_tag_matches(char* pattern, char* tag):
	if (xml_streq(pattern, c"*")): return 1
	if ((pattern[0] == '{') && (pattern[1] == '*') && (pattern[2] == '}')):
		char* want = &pattern[3]
		if (xml_streq(want, c"*")): return 1
		return xml_streq(want, xml_tag_local(tag))
	if ((pattern[0] == '{') && (pattern[1] == '}')):
		if (tag[0] == '{'): return 0
		if (xml_streq(&pattern[2], c"*")): return 1
		return xml_streq(&pattern[2], tag)
	int n = strlen(pattern)
	if ((pattern[0] == '{') && (n >= 2) && (pattern[n - 1] == '*') && (pattern[n - 2] == '}')):
		int i = 0
		while (i < n - 1):
			if (tag[i] != pattern[i]): return 0
			i = i + 1
		return 1
	return xml_streq(pattern, tag)


void xml_iter_into(xml_element* e, char* tag, list[xml_element*] out):
	if ((tag == 0) || xml_tag_matches(tag, e.tag)): out.push(e)
	for xml_element* child in e.children: xml_iter_into(child, tag, out)


# The element and all its descendants in document order whose tag
# matches tag (0 or "*" for all).
list[xml_element*] xml_iter(xml_element* e, char* tag):
	list[xml_element*] out = new list[xml_element*]
	xml_iter_into(e, tag, out)
	return out


void xml_itertext_into(xml_element* e, list[char*] out):
	if (e.text != 0): out.push(e.text)
	for xml_element* child in e.children:
		xml_itertext_into(child, out)
		if (child.tail != 0): out.push(child.tail)


# The text pieces of e's subtree in document order (borrowed).
list[char*] xml_itertext(xml_element* e):
	list[char*] out = new list[char*]
	xml_itertext_into(e, out)
	return out


# All the text of e's subtree joined (owned).
char* xml_text_content(xml_element* e):
	string_builder* sb = string_new()
	list[char*] parts = xml_itertext(e)
	for char* part in parts: string_append(sb, part)
	parts.free()
	return xml_builder_take(sb)


# ---- paths ----


struct xml_path:
	char* text
	int pos
	int ok


# Read one name token: either "*", or a run that may start with a
# "{...}" namespace part and continues up to '/', '[' or the end.
char* xml_path_name(xml_path* p):
	int begin = p.pos
	char* s = p.text
	if (s[p.pos] == '{'):
		while ((s[p.pos] != 0) && (s[p.pos] != '}')): p.pos = p.pos + 1
		if (s[p.pos] == 0):
			p.ok = 0
			return 0
		p.pos = p.pos + 1
	while ((s[p.pos] != 0) && (s[p.pos] != '/') && (s[p.pos] != '[') && (s[p.pos] != ']') && (s[p.pos] != '=') && (s[p.pos] != '!') && (s[p.pos] != '\'') && (s[p.pos] != '"') && (s[p.pos] != '@')):
		p.pos = p.pos + 1
	if (p.pos == begin):
		p.ok = 0
		return 0
	return xml_strndup(&s[begin], p.pos - begin)


char* xml_path_quoted(xml_path* p):
	char* s = p.text
	int quote = s[p.pos]
	if ((quote != '\'') && (quote != '"')):
		p.ok = 0
		return 0
	int begin = p.pos + 1
	int i = begin
	while ((s[i] != 0) && (s[i] != quote)): i = i + 1
	if (s[i] == 0):
		p.ok = 0
		return 0
	p.pos = i + 1
	return xml_strndup(&s[begin], i - begin)


int xml_child_text_matches(xml_element* e, char* tag, char* value):
	for xml_element* child in e.children:
		if (xml_tag_matches(tag, child.tag)):
			if (value == 0): return 1
			char* t = xml_text_content(child)
			int same = xml_streq(t, value)
			free(t)
			if (same): return 1
	return 0


# 1-based position of e among parent's children with e's tag, and the
# count of such children.
int xml_sibling_position(xml_element* parent, xml_element* e, int* count):
	int n = 0
	int at = 0
	for xml_element* child in parent.children:
		if (xml_streq(child.tag, e.tag)):
			n = n + 1
			if (child == e): at = n
	*count = n
	return at


int xml_parse_int(char* s, int* out):
	int i = 0
	int v = 0
	if (s[0] == 0): return 0
	while (s[i] != 0):
		if ((s[i] < '0') || (s[i] > '9') || (i > 6)): return 0
		v = v * 10 + (s[i] - '0')
		i = i + 1
	*out = v
	return 1


# Apply one "[...]" predicate (p.pos just past '[') to elems, whose
# parents are in parents; keeps the survivors in place.
void xml_path_predicate(xml_path* p, list[xml_element*] elems, list[xml_element*] parents):
	char* s = p.text
	int kind = 0
	char* name = 0
	char* value = 0
	int negate = 0
	int index = 0
	int from_last = -1
	if (s[p.pos] == '@'):
		kind = 1
		p.pos = p.pos + 1
		name = xml_path_name(p)
	else if ((s[p.pos] == '.') && (s[p.pos + 1] == '=')):
		kind = 3
		p.pos = p.pos + 1
	else if ((s[p.pos] >= '0') && (s[p.pos] <= '9')):
		kind = 4
		name = xml_path_name(p)
		if ((name != 0) && (xml_parse_int(name, &index) == 0)): p.ok = 0
		if (index < 1): p.ok = 0
	else if (starts_with(&s[p.pos], c"last()")):
		kind = 4
		p.pos = p.pos + 6
		from_last = 0
		if (s[p.pos] == '-'):
			p.pos = p.pos + 1
			char* digits = xml_path_name(p)
			if ((digits == 0) || (xml_parse_int(digits, &from_last) == 0)): p.ok = 0
			xml_free_string(digits)
	else:
		kind = 2
		name = xml_path_name(p)
	if (p.ok && (kind != 4)):
		if ((s[p.pos] == '!') && (s[p.pos + 1] == '=') && (kind == 1)):
			negate = 1
			p.pos = p.pos + 2
			value = xml_path_quoted(p)
		else if (s[p.pos] == '='):
			p.pos = p.pos + 1
			value = xml_path_quoted(p)
		else if (kind == 3): p.ok = 0
	if (p.ok && (s[p.pos] != ']')): p.ok = 0
	p.pos = p.pos + 1
	if (p.ok == 0):
		xml_free_string(name)
		xml_free_string(value)
		return
	int i = 0
	int keep = 0
	while (i < elems.length):
		xml_element* e = elems[i]
		xml_element* parent = parents[i]
		int ok = 0
		if (kind == 1):
			char* got = xml_get(e, name)
			if (value == 0): ok = got != 0
			else if (negate): ok = (got != 0) && (xml_streq(got, value) == 0)
			else: ok = (got != 0) && xml_streq(got, value)
		else if (kind == 2): ok = xml_child_text_matches(e, name, value)
		else if (kind == 3):
			char* t = xml_text_content(e)
			ok = xml_streq(t, value)
			free(t)
		else if (parent != 0):
			int count = 0
			int at = xml_sibling_position(parent, e, &count)
			if (from_last >= 0): ok = at == count - from_last
			else: ok = at == index
		if (ok):
			elems[keep] = e
			parents[keep] = parent
			keep = keep + 1
		i = i + 1
	while (elems.length > keep):
		elems.pop()
		parents.pop()
	xml_free_string(name)
	xml_free_string(value)


void xml_collect_descendants(xml_element* e, char* tag, list[xml_element*] out, list[xml_element*] parents):
	for xml_element* child in e.children:
		if (xml_tag_matches(tag, child.tag)):
			out.push(child)
			parents.push(e)
		xml_collect_descendants(child, tag, out, parents)


# Evaluate path from e; the matches in document order (list owned by
# the caller, elements borrowed). Empty for an invalid path.
list[xml_element*] xml_findall(xml_element* e, char* path):
	xml_path* p = new xml_path()
	p.text = path
	p.pos = 0
	p.ok = 1
	list[xml_element*] cur = new list[xml_element*]
	list[xml_element*] cur_parents = new list[xml_element*]
	cur.push(e)
	cur_parents.push(0)
	char* s = path
	int first = 1
	if ((s[0] == 0) || (s[0] == '/')): p.ok = 0
	while (p.ok && (s[p.pos] != 0)):
		int descend = 0
		if (first == 0):
			if (s[p.pos] != '/'):
				p.ok = 0
				break
			p.pos = p.pos + 1
			if (s[p.pos] == '/'):
				descend = 1
				p.pos = p.pos + 1
		first = 0
		list[xml_element*] next = new list[xml_element*]
		list[xml_element*] next_parents = new list[xml_element*]
		if ((s[p.pos] == '.') && (s[p.pos + 1] == '.')): p.ok = 0
		else if ((s[p.pos] == '.') && descend):
			# "//." : every descendant, plus the context itself.
			p.pos = p.pos + 1
			int i = 0
			while (i < cur.length):
				next.push(cur[i])
				next_parents.push(cur_parents[i])
				xml_collect_descendants(cur[i], c"*", next, next_parents)
				i = i + 1
		else if (s[p.pos] == '.'):
			p.pos = p.pos + 1
			int j = 0
			while (j < cur.length):
				next.push(cur[j])
				next_parents.push(cur_parents[j])
				j = j + 1
		else:
			char* tag = xml_path_name(p)
			if (tag != 0):
				for xml_element* ctx in cur:
					if (descend): xml_collect_descendants(ctx, tag, next, next_parents)
					else:
						for xml_element* child in ctx.children:
							if (xml_tag_matches(tag, child.tag)):
								next.push(child)
								next_parents.push(ctx)
				free(tag)
		while (p.ok && (s[p.pos] == '[')):
			p.pos = p.pos + 1
			xml_path_predicate(p, next, next_parents)
		cur.free()
		cur_parents.free()
		cur = next
		cur_parents = next_parents
		# A descendant step from overlapping contexts can repeat
		# elements; keep the first occurrence.
		if (descend && (cur.length > 1)):
			set[int] seen = new set[int]
			int k = 0
			int kept = 0
			while (k < cur.length):
				int key = cast(int, cur[k])
				if ((key in seen) == 0):
					seen.add(key)
					cur[kept] = cur[k]
					cur_parents[kept] = cur_parents[k]
					kept = kept + 1
				k = k + 1
			while (cur.length > kept):
				cur.pop()
				cur_parents.pop()
			seen.free()
	if ((first == 0) && (s[p.pos - 1] == '/')): p.ok = 0
	cur_parents.free()
	if (p.ok == 0): cur.clear()
	free(p)
	return cur


# First match of path, or 0 (borrowed).
xml_element* xml_find(xml_element* e, char* path):
	list[xml_element*] all = xml_findall(e, path)
	xml_element* found = 0
	if (all.length > 0): found = all[0]
	all.free()
	return found


# Text of the first match ("" when it has none), or default_value when
# nothing matches (borrowed).
char* xml_findtext(xml_element* e, char* path, char* default_value):
	xml_element* found = xml_find(e, path)
	if (found == 0): return default_value
	if (found.text == 0): return c""
	return found.text


# ---- serialization ----


void xml_append_escaped_text(string_builder* sb, char* s):
	int i = 0
	while (s[i] != 0):
		int c = s[i]
		if (c == '&'): string_append(sb, c"&amp;")
		else if (c == '<'): string_append(sb, c"&lt;")
		else if (c == '>'): string_append(sb, c"&gt;")
		else: string_append_char(sb, c)
		i = i + 1


void xml_append_escaped_attr(string_builder* sb, char* s):
	int i = 0
	while (s[i] != 0):
		int c = s[i]
		if (c == '&'): string_append(sb, c"&amp;")
		else if (c == '<'): string_append(sb, c"&lt;")
		else if (c == '>'): string_append(sb, c"&gt;")
		else if (c == '"'): string_append(sb, c"&quot;")
		else if (c == '\n'): string_append(sb, c"&#10;")
		else if (c == '\r'): string_append(sb, c"&#13;")
		else if (c == '\t'): string_append(sb, c"&#09;")
		else: string_append_char(sb, c)
		i = i + 1


# Escape character data: & < > (owned result).
char* xml_escape_text(char* s):
	string_builder* sb = string_new()
	xml_append_escaped_text(sb, s)
	return xml_builder_take(sb)


# Escape an attribute value for double quotes: & < > " and \n \r \t as
# character references (owned result).
char* xml_escape_attr(char* s):
	string_builder* sb = string_new()
	xml_append_escaped_attr(sb, s)
	return xml_builder_take(sb)


# Python's ElementTree _namespace_map defaults.
char* xml_known_prefix(char* uri):
	if (xml_streq(uri, xml_namespace_xml())): return c"xml"
	if (xml_streq(uri, c"http://www.w3.org/1999/xhtml")): return c"html"
	if (xml_streq(uri, c"http://www.w3.org/1999/02/22-rdf-syntax-ns#")): return c"rdf"
	if (xml_streq(uri, c"http://schemas.xmlsoap.org/wsdl/")): return c"wsdl"
	if (xml_streq(uri, c"http://www.w3.org/2001/XMLSchema")): return c"xs"
	if (xml_streq(uri, c"http://www.w3.org/2001/XMLSchema-instance")): return c"xsi"
	if (xml_streq(uri, c"http://purl.org/dc/elements/1.1/")): return c"dc"
	return 0


# uri -> prefix for every namespace used under e, in first-use order
# (the map clones its keys; the prefixes are owned by the caller).
void xml_collect_namespace(map[char*, char*] ns, char* name):
	if (name[0] != '{'): return
	int i = 1
	while ((name[i] != 0) && (name[i] != '}')): i = i + 1
	if (name[i] == 0): return
	char* uri = xml_strndup(&name[1], i - 1)
	if ((uri in ns) || xml_streq(uri, xml_namespace_xml())):
		free(uri)
		return
	char* prefix = xml_known_prefix(uri)
	if (prefix != 0): prefix = strclone(prefix)
	else:
		string_builder* sb = string_new()
		string_append(sb, c"ns")
		string_append_int(sb, ns.length)
		prefix = xml_builder_take(sb)
	ns[uri] = prefix
	free(uri)


void xml_collect_namespaces(map[char*, char*] ns, xml_element* e):
	xml_collect_namespace(ns, e.tag)
	for xml_attrib* a in e.attrib: xml_collect_namespace(ns, a.name)
	for xml_element* child in e.children: xml_collect_namespaces(ns, child)


void xml_append_qname(string_builder* sb, map[char*, char*] ns, char* name):
	if (name[0] != '{'):
		string_append(sb, name)
		return
	char* local = xml_tag_local(name)
	if (local == name):
		string_append(sb, name)
		return
	int uri_len = cast(int, local) - cast(int, name) - 2
	char* uri = xml_strndup(&name[1], uri_len)
	char* prefix = c"xml"
	if (xml_streq(uri, xml_namespace_xml()) == 0): prefix = ns[uri]
	free(uri)
	string_append(sb, prefix)
	string_append_char(sb, ':')
	string_append(sb, local)


void xml_serialize(string_builder* sb, map[char*, char*] ns, xml_element* e, int top):
	string_append_char(sb, '<')
	xml_append_qname(sb, ns, e.tag)
	if (top):
		# Declarations sorted by prefix, as Python writes them.
		list[char*] uris = ns.keys()
		int i = 1
		while (i < uris.length):
			char* key = uris[i]
			int j = i - 1
			while ((j >= 0) && (strcmp(ns[uris[j]], ns[key]) > 0)):
				uris[j + 1] = uris[j]
				j = j - 1
			uris[j + 1] = key
			i = i + 1
		for char* uri in uris:
			string_append(sb, c" xmlns:")
			string_append(sb, ns[uri])
			string_append(sb, c"=\"")
			xml_append_escaped_attr(sb, uri)
			string_append_char(sb, '"')
		uris.free()
	for xml_attrib* a in e.attrib:
		string_append_char(sb, ' ')
		xml_append_qname(sb, ns, a.name)
		string_append(sb, c"=\"")
		xml_append_escaped_attr(sb, a.value)
		string_append_char(sb, '"')
	if ((e.text != 0) || (e.children.length > 0)):
		string_append_char(sb, '>')
		if (e.text != 0): xml_append_escaped_text(sb, e.text)
		for xml_element* child in e.children: xml_serialize(sb, ns, child, 0)
		string_append(sb, c"</")
		xml_append_qname(sb, ns, e.tag)
		string_append_char(sb, '>')
	else: string_append(sb, c" />")
	if (e.tail != 0): xml_append_escaped_text(sb, e.tail)


# Serialize e and its subtree (owned result); see the header.
char* xml_tostring(xml_element* e):
	map[char*, char*] ns = new map[char*, char*]
	xml_collect_namespaces(ns, e)
	string_builder* sb = string_new()
	xml_serialize(sb, ns, e, 1)
	for char* uri, char* prefix in ns: free(prefix)
	ns.free()
	return xml_builder_take(sb)
