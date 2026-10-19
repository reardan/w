# wbuild: x64
# wbuild: step="bin/etree_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import structures.string
import libs.standard.formats.xml.etree


xml_element* parse_ok(char* text):
	char* err = 0
	xml_element* root = xml_fromstring_error(text, &err)
	if (root == 0):
		assert_strings_equal(c"(no error)", err)
	return root


# parse -> serialize must give want.
void expect_serialized(char* text, char* want):
	xml_element* root = parse_ok(text)
	char* got = xml_tostring(root)
	assert_strings_equal(want, got)
	free(got)
	xml_element_free(root)


int trees_equal(xml_element* a, xml_element* b):
	if (xml_streq(a.tag, b.tag) == 0): return 0
	if ((a.text == 0) != (b.text == 0)): return 0
	if ((a.text != 0) && (xml_streq(a.text, b.text) == 0)): return 0
	if ((a.tail == 0) != (b.tail == 0)): return 0
	if ((a.tail != 0) && (xml_streq(a.tail, b.tail) == 0)): return 0
	if (a.attrib.length != b.attrib.length): return 0
	int i = 0
	while (i < a.attrib.length):
		if (xml_streq(a.attrib[i].name, b.attrib[i].name) == 0): return 0
		if (xml_streq(a.attrib[i].value, b.attrib[i].value) == 0): return 0
		i = i + 1
	if (a.children.length != b.children.length): return 0
	i = 0
	while (i < a.children.length):
		if (trees_equal(a.children[i], b.children[i]) == 0): return 0
		i = i + 1
	return 1


# parse -> serialize -> parse gives the same tree, and serializing is a
# fixpoint after the first pass.
void expect_round_trip(char* text):
	xml_element* first = parse_ok(text)
	char* once = xml_tostring(first)
	xml_element* second = parse_ok(once)
	assert1(trees_equal(first, second))
	char* twice = xml_tostring(second)
	assert_strings_equal(once, twice)
	free(once)
	free(twice)
	xml_element_free(first)
	xml_element_free(second)


void test_parse_structure():
	xml_element* root = parse_ok(c"<root a=\"1\" b='2'>head<x>inner</x>mid<y/>end</root>")
	assert_strings_equal(c"root", root.tag)
	assert_equal(2, root.attrib.length)
	assert_strings_equal(c"a", root.attrib[0].name)
	assert_strings_equal(c"b", root.attrib[1].name)
	assert_strings_equal(c"2", xml_get(root, c"b"))
	assert_equal(0, cast(int, xml_get(root, c"c")))
	assert_strings_equal(c"head", root.text)
	assert_equal(0, cast(int, root.tail))
	assert_equal(2, xml_element_len(root))
	xml_element* x = root.children[0]
	assert_strings_equal(c"x", x.tag)
	assert_strings_equal(c"inner", x.text)
	assert_strings_equal(c"mid", x.tail)
	xml_element* y = root.children[1]
	assert_equal(0, cast(int, y.text))
	assert_strings_equal(c"end", y.tail)
	xml_element_free(root)


void test_parse_text_merging():
	# CDATA merges into text; comments and PIs are dropped.
	xml_element* root = parse_ok(c"<?xml version='1.0'?><!DOCTYPE a><!--c--><a>x<![CDATA[<y>]]><!-- c -->z&amp;<?p?>w<b/>t<!--c-->u</a><!--after-->")
	assert_strings_equal(c"x<y>z&w", root.text)
	assert_strings_equal(c"tu", root.children[0].tail)
	xml_element_free(root)
	root = parse_ok(c"<a>\n  <b/>\n</a>")
	assert_strings_equal(c"\n  ", root.text)
	assert_strings_equal(c"\n", root.children[0].tail)
	xml_element_free(root)


void test_parse_namespaces():
	xml_element* root = parse_ok(c"<r xmlns='urn:d' xmlns:p='urn:p' p:a='1' b='2'><p:c/><e xmlns=''/></r>")
	assert_strings_equal(c"{urn:d}r", root.tag)
	assert_equal(2, root.attrib.length)
	assert_strings_equal(c"{urn:p}a", root.attrib[0].name)
	assert_strings_equal(c"b", root.attrib[1].name)
	assert_strings_equal(c"{urn:p}c", root.children[0].tag)
	assert_strings_equal(c"e", root.children[1].tag)
	xml_element_free(root)


void test_parse_errors():
	char* err = 0
	assert_equal(0, cast(int, xml_fromstring_error(c"<a><b></a>", &err)))
	assert_strings_equal(c"mismatched tag: line 1, column 6", err)
	free(err)
	assert_equal(0, cast(int, xml_fromstring_error(c"<a/><b/>", &err)))
	assert_strings_equal(c"junk after document element: line 1, column 4", err)
	free(err)
	assert_equal(0, cast(int, xml_fromstring_error(c"<a>\n<b>", &err)))
	assert_strings_equal(c"no element found: line 2, column 3", err)
	free(err)
	assert_equal(0, cast(int, xml_fromstring(c"<a>&nbsp;</a>")))
	assert_equal(0, cast(int, xml_fromstring(c"")))


void test_build_and_mutate():
	xml_element* root = xml_element_new(c"root")
	xml_set(root, c"z", c"1")
	xml_set(root, c"a", c"2")
	xml_set(root, c"z", c"3")
	xml_element* child = xml_subelement(root, c"child")
	xml_set_text(child, c"hi")
	xml_set_tail(child, c"\n")
	xml_element* gone = xml_subelement(root, c"gone")
	char* out = xml_tostring(root)
	assert_strings_equal(c"<root z=\"3\" a=\"2\"><child>hi</child>\n<gone /></root>", out)
	free(out)
	assert_equal(cast(int, gone), cast(int, xml_element_remove(root, gone)))
	assert_equal(0, cast(int, xml_element_remove(root, gone)))
	xml_element_free(gone)
	xml_set_text(child, 0)
	xml_set_tail(child, 0)
	out = xml_tostring(root)
	assert_strings_equal(c"<root z=\"3\" a=\"2\"><child /></root>", out)
	free(out)
	xml_element_free(root)


void test_serialize_escaping():
	xml_element* root = xml_element_new(c"a")
	xml_set(root, c"v", c"<&>\"' \n\r\t")
	xml_set_text(root, c"<&>\"'\n")
	char* out = xml_tostring(root)
	assert_strings_equal(c"<a v=\"&lt;&amp;&gt;&quot;' &#10;&#13;&#09;\">&lt;&amp;&gt;\"'\n</a>", out)
	free(out)
	xml_element_free(root)
	char* t = xml_escape_text(c"a<b>&c\"")
	assert_strings_equal(c"a&lt;b&gt;&amp;c\"", t)
	free(t)
	t = xml_escape_attr(c"a<b>&c\"\t")
	assert_strings_equal(c"a&lt;b&gt;&amp;c&quot;&#09;", t)
	free(t)
	# A value written with character references survives a round trip.
	expect_serialized(c"<a v='x&#10;y&#9;z'>1 &lt; 2</a>", c"<a v=\"x&#10;y&#09;z\">1 &lt; 2</a>")
	expect_serialized(c"<a v='x\ny'/>", c"<a v=\"x y\" />")
	expect_serialized(c"<a>é&#x1F600;</a>", c"<a>é\U0001f600</a>")


void test_serialize_namespaces():
	expect_serialized(c"<r xmlns='urn:a'><c/></r>", c"<ns0:r xmlns:ns0=\"urn:a\"><ns0:c /></ns0:r>")
	expect_serialized(c"<r xmlns:p='urn:p' xmlns:q='urn:q'><q:c p:x='1'/><p:d/></r>", c"<r xmlns:ns0=\"urn:q\" xmlns:ns1=\"urn:p\"><ns0:c ns1:x=\"1\" /><ns1:d /></r>")
	expect_serialized(c"<a xml:lang='en'/>", c"<a xml:lang=\"en\" />")
	expect_serialized(c"<h:p xmlns:h='http://www.w3.org/1999/xhtml' xmlns:z='urn:z'><z:b/></h:p>", c"<html:p xmlns:html=\"http://www.w3.org/1999/xhtml\" xmlns:ns1=\"urn:z\"><ns1:b /></html:p>")
	xml_element* root = xml_element_new(c"{urn:x}root")
	xml_subelement(root, c"plain")
	char* out = xml_tostring(root)
	assert_strings_equal(c"<ns0:root xmlns:ns0=\"urn:x\"><plain /></ns0:root>", out)
	free(out)
	xml_element_free(root)


void test_serialize_subtree_tail():
	xml_element* root = parse_ok(c"<a><b>1</b>tail<c/></a>")
	char* out = xml_tostring(root.children[0])
	assert_strings_equal(c"<b>1</b>tail", out)
	free(out)
	xml_element_free(root)


char* doc_text():
	return c"<lib xmlns:m='urn:meta'><book id='1' lang='en'><title>One</title><m:year>2001</m:year></book><book id='2'><title>Two</title><note><title>Inner</title></note></book><shelf><book id='3' lang='fr'><title>Trois</title></book></shelf></lib>"


# The ids of path's matches joined with commas ("-" for elements
# without one).
char* ids(xml_element* root, char* path):
	list[xml_element*] found = xml_findall(root, path)
	string_builder* sb = string_new()
	for xml_element* e in found:
		if (sb.length > 0): string_append_char(sb, ',')
		char* id = xml_get(e, c"id")
		if (id == 0): string_append(sb, xml_tag_local(e.tag))
		else: string_append(sb, id)
	found.free()
	char* data = sb.data
	free(sb)
	return data


void expect_ids(xml_element* root, char* path, char* want):
	char* got = ids(root, path)
	assert_strings_equal(want, got)
	free(got)


void test_find_paths():
	xml_element* root = parse_ok(doc_text())
	expect_ids(root, c"book", c"1,2")
	expect_ids(root, c"./book", c"1,2")
	expect_ids(root, c"*", c"1,2,shelf")
	expect_ids(root, c".//book", c"1,2,3")
	expect_ids(root, c"shelf/book", c"3")
	expect_ids(root, c"*/book", c"3")
	expect_ids(root, c"book/title", c"title,title")
	expect_ids(root, c".//title", c"title,title,title,title")
	expect_ids(root, c"book//title", c"title,title,title")
	expect_ids(root, c".", c"lib")
	expect_ids(root, c"book[@lang]", c"1")
	expect_ids(root, c".//book[@lang='fr']", c"3")
	expect_ids(root, c".//book[@lang=\"en\"]", c"1")
	expect_ids(root, c".//book[@lang!='en']", c"3")
	expect_ids(root, c"book[note]", c"2")
	expect_ids(root, c"book[title='Two']", c"2")
	expect_ids(root, c".//title[.='Inner']", c"title")
	expect_ids(root, c"book[1]", c"1")
	expect_ids(root, c"book[2]", c"2")
	expect_ids(root, c"book[last()]", c"2")
	expect_ids(root, c"book[last()-1]", c"1")
	expect_ids(root, c".//book[1]", c"1,3")
	expect_ids(root, c"book[@id][2]", c"2")
	expect_ids(root, c"book/{urn:meta}year", c"year")
	expect_ids(root, c"book/{*}year", c"year")
	expect_ids(root, c"book/{urn:meta}*", c"year")
	expect_ids(root, c"book/{}*", c"title,title,note")
	expect_ids(root, c"book/{}title", c"title,title")
	expect_ids(root, c".//missing", c"")
	expect_ids(root, c"book/year", c"")
	# Duplicates from overlapping descendant steps are dropped.
	expect_ids(root, c".//*//title", c"title,title,title,title")
	# Invalid paths match nothing.
	expect_ids(root, c"/lib", c"")
	expect_ids(root, c"", c"")
	expect_ids(root, c"book/", c"")
	expect_ids(root, c"..", c"")
	expect_ids(root, c"book[@lang", c"")
	expect_ids(root, c"book[0]", c"")
	expect_ids(root, c"book[@lang=en]", c"")
	expect_ids(root, c"{urn:meta", c"")
	xml_element* first = xml_find(root, c"book")
	assert_strings_equal(c"1", xml_get(first, c"id"))
	assert_equal(0, cast(int, xml_find(root, c"nope")))
	assert_strings_equal(c"One", xml_findtext(root, c"book/title", c"dflt"))
	assert_strings_equal(c"2001", xml_findtext(root, c"book/{urn:meta}year", 0))
	assert_strings_equal(c"dflt", xml_findtext(root, c"nope", c"dflt"))
	assert_strings_equal(c"", xml_findtext(root, c"shelf", c"dflt"))
	xml_element_free(root)


void test_iteration():
	xml_element* root = parse_ok(doc_text())
	list[xml_element*] all = xml_iter(root, 0)
	assert_equal(11, all.length)
	assert_equal(cast(int, root), cast(int, all[0]))
	all.free()
	list[xml_element*] books = xml_iter(root, c"book")
	assert_equal(3, books.length)
	assert_strings_equal(c"3", xml_get(books[2], c"id"))
	books.free()
	list[xml_element*] years = xml_iter(root, c"{*}year")
	assert_equal(1, years.length)
	years.free()
	xml_element_free(root)
	root = parse_ok(c"<a>1<b>2<c>3</c>4</b>5<d/>6</a>")
	list[char*] parts = xml_itertext(root)
	assert_equal(6, parts.length)
	assert_strings_equal(c"4", parts[3])
	parts.free()
	char* all_text = xml_text_content(root)
	assert_strings_equal(c"123456", all_text)
	free(all_text)
	xml_element_free(root)


void test_round_trip():
	expect_round_trip(doc_text())
	expect_round_trip(c"<a/>")
	expect_round_trip(c"<a>\n\t<b x='1 &amp; 2' y=\"'q'\">t&lt;&gt;</b>\n</a>")
	expect_round_trip(c"<a v='&#10;&#13;&#9;&lt;&quot;'><![CDATA[x < y && ]]]]><![CDATA[>]]></a>")
	expect_round_trip(c"<r xmlns='urn:d' xmlns:p='urn:p'><p:c p:a='1' xml:lang='en'><d xmlns=''/></p:c></r>")
	expect_round_trip(c"<?xml version='1.0' encoding='utf-8'?>\n<!DOCTYPE doc [<!ENTITY e 'x'>]>\n<doc>é三&#x1F600;<e/>tail</doc>\n")
	expect_round_trip(c"<a>\r\nline\rline</a>")


# W3C-conformance-style cases written inline: documents every
# conforming processor must accept.
void test_conformance_well_formed():
	list[char*] docs = new list[char*]
	docs.push(c"<doc></doc>")
	docs.push(c"<doc/>")
	docs.push(c"<doc ></doc >")
	docs.push(c"<doc\n/>")
	docs.push(c"<doc a1=\"v1\"></doc>")
	docs.push(c"<doc a1 = \"v1\"></doc>")
	docs.push(c"<doc a1='v1' a2=\"v2\"/>")
	docs.push(c"<doc a1=\"&quot;&apos;\"/>")
	docs.push(c"<doc>&#32;&#x20;&#xA0;</doc>")
	docs.push(c"<doc><![CDATA[<foo>]]></doc>")
	docs.push(c"<doc><![CDATA[<&]]></doc>")
	docs.push(c"<doc><!-- a comment ->--></doc>")
	docs.push(c"<doc><?pi some data ? > <??></doc>")
	docs.push(c"<doc><?pi?></doc>")
	docs.push(c"<doc>]]</doc>")
	docs.push(c"<doc>]</doc>")
	docs.push(c"<doc>></doc>")
	docs.push(c"<doc><_doc/><A.-_/></doc>")
	docs.push(c"<?xml version=\"1.0\"?>\n<doc/>")
	docs.push(c"<?xml version='1.0' encoding=\"UTF-8\"?><doc/>")
	docs.push(c"<?xml version = '1.0' standalone = 'no' ?><doc/>")
	docs.push(c"<!DOCTYPE doc [\n<!ELEMENT doc (#PCDATA)>\n<!ATTLIST doc a CDATA #IMPLIED>\n]>\n<doc a='1'/>")
	docs.push(c"<!DOCTYPE doc PUBLIC \"-//W3C//DTD X//EN\" 'x.dtd'><doc/>")
	docs.push(c"<doc>\t\n\r </doc>\n\n")
	docs.push(c"<!--a--><?pi?><doc/><!--b--><?pi?> ")
	docs.push(c"<doc xmlns:a='urn:a'><a:e a:x='1' x='2'/></doc>")
	docs.push(c"<doc xmlns='urn:a'><e xmlns='urn:b'/></doc>")
	for char* doc in docs:
		xml_element* root = xml_fromstring(doc)
		if (root == 0): assert_strings_equal(c"well-formed", doc)
		xml_element_free(root)
	docs.free()


# Documents every conforming processor must reject, each with the
# reason its error must report.
void test_conformance_not_well_formed():
	list[char*] docs = new list[char*]
	docs.push(c"<doc><.doc></.doc></doc>")
	docs.push(c"invalid token")
	docs.push(c"<doc><123/></doc>")
	docs.push(c"invalid token")
	docs.push(c"<doc a1='v1' a1='v2'/>")
	docs.push(c"duplicate attribute")
	docs.push(c"<doc a1=v1/>")
	docs.push(c"invalid token")
	docs.push(c"<doc a1='<'/>")
	docs.push(c"invalid token")
	docs.push(c"<doc a1='&'/>")
	docs.push(c"invalid token")
	docs.push(c"<doc>&</doc>")
	docs.push(c"invalid token")
	docs.push(c"<doc>&foo;</doc>")
	docs.push(c"undefined entity")
	docs.push(c"<doc>&#xFFFF;</doc>")
	docs.push(c"invalid character number")
	docs.push(c"<doc>&#1114112;</doc>")
	docs.push(c"invalid character number")
	docs.push(c"<doc><!-- -- --></doc>")
	docs.push(c"invalid token")
	docs.push(c"<doc><!-- ---></doc>")
	docs.push(c"invalid token")
	docs.push(c"<doc>]]></doc>")
	docs.push(c"invalid token")
	docs.push(c"<doc><![CDATA[ x ]]</doc>")
	docs.push(c"unclosed CDATA")
	docs.push(c"<doc><![cdata[x]]></doc>")
	docs.push(c"invalid token")
	docs.push(c"<doc></dop>")
	docs.push(c"mismatched tag")
	docs.push(c"<doc><a></doc></a>")
	docs.push(c"mismatched tag")
	docs.push(c"<doc>")
	docs.push(c"no element found")
	docs.push(c"<doc/><doc/>")
	docs.push(c"junk after document element")
	docs.push(c"<doc/>text")
	docs.push(c"junk after document element")
	docs.push(c"text<doc/>")
	docs.push(c"syntax error")
	docs.push(c"<doc/><![CDATA[x]]>")
	docs.push(c"invalid token")
	docs.push(c"\n<?xml version='1.0'?><doc/>")
	docs.push(c"not at start of entity")
	docs.push(c"<?xml version='1.0' encoding='utf-8' version='1.0'?><doc/>")
	docs.push(c"XML declaration not well-formed")
	docs.push(c"<?XML version='1.0'?><doc/>")
	docs.push(c"reserved processing instruction target")
	docs.push(c"<doc/><!DOCTYPE doc>")
	docs.push(c"invalid token")
	docs.push(c"<doc>\x0c</doc>")
	docs.push(c"invalid token")
	docs.push(c"<doc>\xc0\x80</doc>")
	docs.push(c"invalid UTF-8")
	docs.push(c"<p:doc/>")
	docs.push(c"unbound prefix")
	docs.push(c"<doc xmlns:a='urn:x' xmlns:b='urn:x' a:x='1' b:x='2'/>")
	docs.push(c"duplicate attribute")
	int i = 0
	while (i < docs.length):
		char* err = 0
		xml_element* root = xml_fromstring_error(docs[i], &err)
		if (root != 0):
			assert_strings_equal(c"not well-formed", docs[i])
			xml_element_free(root)
		else:
			assert_contains(err, docs[i + 1])
			assert_contains(err, c": line ")
			free(err)
		i = i + 2
	docs.free()
