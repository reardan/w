# wbuild: x64
# wbuild: step="bin/tokenizer_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import structures.string
import libs.standard.formats.xml.tokenizer


# Render every event of text as a compact trace, or "ERR <message>".
char* trace(char* text):
	xml_reader* r = xml_reader_new(text)
	string_builder* out = string_new()
	int ev = xml_next(r)
	while ((ev != XML_EOF) && (ev != XML_ERROR)):
		if (out.length > 0): string_append_char(out, '|')
		if (ev == XML_START):
			string_append_char(out, '<')
			string_append(out, r.name)
			for xml_attr* a in r.attrs:
				string_append_char(out, ' ')
				string_append(out, a.name)
				string_append(out, c"=\"")
				string_append(out, a.value)
				string_append_char(out, '"')
			if (r.empty): string_append_char(out, '/')
			string_append_char(out, '>')
		else if (ev == XML_END):
			string_append(out, c"</")
			string_append(out, r.name)
			string_append_char(out, '>')
		else if (ev == XML_TEXT):
			string_append(out, c"T:")
			string_append(out, r.text)
		else if (ev == XML_CDATA):
			string_append(out, c"C:")
			string_append(out, r.text)
		else if (ev == XML_COMMENT):
			string_append(out, c"#:")
			string_append(out, r.text)
		else if (ev == XML_PI):
			string_append(out, c"?")
			string_append(out, r.target)
			string_append_char(out, ':')
			string_append(out, r.text)
		else if (ev == XML_DECL):
			string_append(out, c"D:")
			string_append(out, r.version)
			string_append_char(out, ',')
			string_append(out, r.encoding)
			string_append_char(out, ',')
			string_append(out, r.standalone)
		else if (ev == XML_DOCTYPE):
			string_append(out, c"!")
			string_append(out, r.name)
			string_append_char(out, ':')
			string_append(out, r.text)
		ev = xml_next(r)
	if (ev == XML_ERROR):
		string_clear(out)
		string_append(out, c"ERR ")
		string_append(out, r.error)
	# Events stay sticky after the end.
	assert_equal(ev, xml_next(r))
	xml_reader_free(r)
	char* data = out.data
	free(out)
	return data


void expect_trace(char* text, char* want):
	char* got = trace(text)
	assert_strings_equal(want, got)
	free(got)


# Not well-formed: the error message must contain reason.
void expect_error(char* text, char* reason):
	char* got = trace(text)
	assert_contains(got, c"ERR ")
	assert_contains(got, reason)
	free(got)


void test_elements_and_text():
	expect_trace(c"<a>hi</a>", c"<a>|T:hi|</a>")
	expect_trace(c"<a><b/><c>x</c></a>", c"<a>|<b/>|</b>|<c>|T:x|</c>|</a>")
	expect_trace(c"<a/>", c"<a/>|</a>")
	expect_trace(c"<a >\n <b\t/>\n</a >", c"<a>|T:\n |<b/>|</b>|T:\n|</a>")
	expect_trace(c"<ns:a-b.c_d xmlns:ns='u'/>", c"<ns:a-b.c_d xmlns:ns=\"u\"/>|</ns:a-b.c_d>")
	# Whitespace and comments around the root are fine.
	expect_trace(c"\n  <a/>\n\n", c"<a/>|</a>")


void test_attributes():
	expect_trace(c"<a x=\"1\" y='2' z = \"it's\" w='say \"hi\"'/>", c"<a x=\"1\" y=\"2\" z=\"it's\" w=\"say \"hi\"\"/>|</a>")
	expect_trace(c"<a x=\"&lt;&amp;&gt;&quot;&apos;\"/>", c"<a x=\"<&>\"'\"/>|</a>")
	# Literal whitespace normalizes to spaces; references survive.
	expect_trace(c"<a x=\"1\n2\t3\r\n4\" y=\"&#10;&#9;&#13;\"/>", c"<a x=\"1 2 3 4\" y=\"\n\t\r\"/>|</a>")
	expect_trace(c"<a x=''/>", c"<a x=\"\"/>|</a>")
	xml_reader* r = xml_reader_new(c"<a x='1' p:y='2' xmlns:p='urn:p'/>")
	assert_equal(XML_START, xml_next(r))
	assert_strings_equal(c"1", xml_reader_attr(r, c"x"))
	assert_strings_equal(c"2", xml_reader_attr(r, c"p:y"))
	assert_strings_equal(c"2", xml_reader_attr_ns(r, c"urn:p", c"y"))
	assert_equal(0, cast(int, xml_reader_attr(r, c"y")))
	assert_equal(0, cast(int, xml_reader_attr_ns(r, c"", c"y")))
	xml_reader_free(r)


void test_attribute_errors():
	expect_error(c"<a x='1' x='2'/>", c"duplicate attribute: line 1, column 9")
	expect_error(c"<a x='<'/>", c"not well-formed (invalid token): line 1, column 6")
	expect_error(c"<a x=1/>", c"invalid token")
	expect_error(c"<a x='1'y='2'/>", c"invalid token")
	expect_error(c"<a x/>", c"invalid token")
	expect_error(c"<a x='1\"/>", c"unclosed token")
	expect_error(c"<a x='&foo;'/>", c"undefined entity")
	expect_error(c"<a x='a&b'/>", c"invalid token")


void test_references():
	expect_trace(c"<a>&lt;&gt;&amp;&quot;&apos;</a>", c"<a>|T:<>&\"'|</a>")
	expect_trace(c"<a>&#65;&#x42;&#x63;&#0000067;</a>", c"<a>|T:ABcC|</a>")
	expect_trace(c"<a>&#233;&#x20AC;&#x1F600;</a>", c"<a>|T:\u00e9\u20ac\U0001f600|</a>")
	expect_trace(c"<a>&#38;lt;</a>", c"<a>|T:&lt;|</a>")
	expect_error(c"<a>&#0;</a>", c"reference to invalid character number: line 1, column 3")
	expect_error(c"<a>&#xD800;</a>", c"reference to invalid character number")
	expect_error(c"<a>&#xFFFE;</a>", c"reference to invalid character number")
	expect_error(c"<a>&#x110000;</a>", c"reference to invalid character number")
	expect_error(c"<a>&#99999999999999999999;</a>", c"reference to invalid character number")
	expect_error(c"<a>&#8;</a>", c"reference to invalid character number")
	expect_error(c"<a>&#x;</a>", c"invalid token")
	expect_error(c"<a>&#12a;</a>", c"invalid token")
	expect_error(c"<a>&#X41;</a>", c"invalid token")
	expect_error(c"<a>&lt</a>", c"invalid token")
	expect_error(c"<a>& </a>", c"invalid token")
	# HTML entities are not XML.
	expect_error(c"<a>&nbsp;</a>", c"undefined entity: line 1, column 3")
	expect_error(c"<a>&copy;</a>", c"undefined entity")


void test_cdata_comments_pis():
	expect_trace(c"<a><![CDATA[<x>&amp;]]]></a>", c"<a>|C:<x>&amp;]|</a>")
	expect_trace(c"<a><![CDATA[]]></a>", c"<a>|C:|</a>")
	expect_trace(c"<!-- top --><a><!--in-side--></a><!---->", c"#: top |<a>|#:in-side|</a>|#:")
	expect_trace(c"<?go fast now ?><a><?empty?></a>", c"?go:fast now |<a>|?empty:|</a>")
	expect_error(c"<a><!-- a -- b --></a>", c"invalid token): line 1, column 10")
	expect_error(c"<a><!-- a ---></a>", c"invalid token")
	expect_error(c"<a><!-- a </a>", c"unclosed token")
	expect_error(c"<![CDATA[x]]><a/>", c"invalid token): line 1, column 0")
	expect_error(c"<a><![CDATA[x</a>", c"unclosed CDATA section")
	expect_error(c"<a>x]]>y</a>", c"invalid token): line 1, column 4")
	expect_error(c"<a><?xml version='1.0'?></a>", c"XML or text declaration not at start of entity")
	expect_error(c"<a><?XmL x?></a>", c"reserved processing instruction target")
	expect_error(c"<a><?pi x</a>", c"unclosed token")
	expect_error(c"<a><?pi=x?></a>", c"invalid token")
	expect_error(c"<a><!ELEMENT a></a>", c"invalid token")


void test_declaration():
	expect_trace(c"<?xml version=\"1.0\"?><a/>", c"D:1.0,,|<a/>|</a>")
	expect_trace(c"<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>\n<a/>", c"D:1.0,UTF-8,yes|<a/>|</a>")
	expect_trace(c"\xef\xbb\xbf<?xml version='1.1'?><a/>", c"D:1.1,,|<a/>|</a>")
	expect_error(c"<?xml?><a/>", c"XML declaration not well-formed")
	expect_error(c"<?xml encoding='utf-8'?><a/>", c"XML declaration not well-formed")
	expect_error(c"<?xml version='1.0' standalone='maybe'?><a/>", c"XML declaration not well-formed")
	expect_error(c"<?xml version='1.0' standalone='yes' encoding='utf-8'?><a/>", c"XML declaration not well-formed")
	expect_error(c"<?xml version='2.0'?><a/>", c"XML declaration not well-formed")
	expect_error(c"<?xml version='1.0' encoding='8bit'?><a/>", c"XML declaration not well-formed")
	expect_error(c" <?xml version='1.0'?><a/>", c"not at start of entity: line 1, column 1")


void test_doctype():
	expect_trace(c"<!DOCTYPE a><a/>", c"!a:|<a/>|</a>")
	expect_trace(c"<!DOCTYPE a SYSTEM \"x>y.dtd\"><a/>", c"!a:SYSTEM \"x>y.dtd\"|<a/>|</a>")
	expect_trace(c"<?xml version='1.0'?>\n<!DOCTYPE a [\n<!ENTITY e 'v>'>\n<!-- ] > -->\n<?p ]>?>\n]>\n<a/>", c"D:1.0,,|!a:[\n<!ENTITY e 'v>'>\n<!-- ] > -->\n<?p ]>?>\n]|<a/>|</a>")
	# Entity declarations are ignored, so XXE and expansion bombs are
	# impossible: the reference is simply undefined.
	expect_error(c"<!DOCTYPE a [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]><a>&xxe;</a>", c"undefined entity")
	expect_error(c"<!DOCTYPE a [<!ENTITY a 'x'><!ENTITY b '&a;&a;'>]><a>&b;</a>", c"undefined entity")
	expect_error(c"<a/><!DOCTYPE a>", c"invalid token")
	expect_error(c"<!DOCTYPE a><!DOCTYPE a><a/>", c"invalid token")
	expect_error(c"<!DOCTYPE a [ <a/>", c"unclosed token")
	expect_error(c"<!DOCTYPE>", c"invalid token")


void test_line_ends():
	expect_trace(c"<a>1\r\n2\r3\n4</a>", c"<a>|T:1\n2\n3\n4|</a>")
	expect_trace(c"<a><![CDATA[1\r\n2]]><!--3\r4--><?p 5\r\n6?></a>", c"<a>|C:1\n2|#:3\n4|?p:5\n6|</a>")


void test_structure_errors():
	expect_error(c"", c"no element found: line 1, column 0")
	expect_error(c"  \n ", c"no element found: line 2, column 1")
	expect_error(c"<!-- only -->", c"no element found")
	expect_error(c"<a><b></a>", c"mismatched tag: line 1, column 6")
	expect_error(c"<a>\n  <b>\n  </c>\n</a>", c"mismatched tag: line 3, column 2")
	expect_error(c"<a><b></b>", c"no element found: line 1, column 10")
	expect_error(c"<a>", c"no element found")
	expect_error(c"<a></a><b/>", c"junk after document element: line 1, column 7")
	expect_error(c"<a></a>x", c"junk after document element: line 1, column 7")
	expect_error(c"<a></a></a>", c"junk after document element")
	expect_error(c"<a></a>&amp;", c"junk after document element")
	expect_error(c"x<a/>", c"syntax error: line 1, column 0")
	expect_error(c"</a>", c"invalid token")
	expect_error(c"<a></a", c"unclosed token")
	expect_error(c"<a", c"unclosed token")
	expect_error(c"<1a/>", c"invalid token")
	expect_error(c"< a/>", c"invalid token")
	expect_error(c"<a></ a>", c"invalid token")
	expect_error(c"<a></a b>", c"invalid token")
	expect_error(c"<a>\x01</a>", c"invalid token): line 1, column 3")
	expect_error(c"<a>\xff</a>", c"invalid UTF-8")
	expect_error(c"<a>\xed\xa0\x80</a>", c"invalid UTF-8")
	expect_error(c"<a>\xef\xbf\xbe</a>", c"invalid token")
	# Valid non-ASCII names and text.
	expect_trace(c"<\u00e9l\u00e8ve \u00e2ge='\u4e09'>\u00fc</\u00e9l\u00e8ve>", c"<\u00e9l\u00e8ve \u00e2ge=\"\u4e09\">|T:\u00fc|</\u00e9l\u00e8ve>")
	expect_error(c"<a\u00d7b/>", c"invalid token")


void test_depth_limit():
	xml_reader* r = xml_reader_new(c"<a><a><a><a/></a></a></a>")
	r.max_depth = 3
	assert_equal(XML_START, xml_next(r))
	assert_equal(XML_START, xml_next(r))
	assert_equal(XML_START, xml_next(r))
	assert_equal(XML_ERROR, xml_next(r))
	assert_contains(r.error, c"nesting too deep")
	xml_reader_free(r)


void test_namespaces():
	xml_reader* r = xml_reader_new(c"<root xmlns='urn:d' xmlns:p='urn:p'><p:x p:a='1' b='2'/><y xmlns=''/><p:z xmlns:p='urn:q'/><xml:w xml:lang='en'/></root>")
	assert_equal(XML_START, xml_next(r))
	assert_strings_equal(c"root", r.name)
	assert_strings_equal(c"", r.prefix)
	assert_strings_equal(c"root", r.local)
	assert_strings_equal(c"urn:d", r.ns_uri)
	assert_equal(2, r.attrs.length)
	assert_strings_equal(xml_namespace_xmlns(), r.attrs[0].ns_uri)
	assert_strings_equal(c"xmlns", r.attrs[0].local)
	assert_strings_equal(c"p", r.attrs[1].local)
	assert_equal(XML_START, xml_next(r))
	assert_strings_equal(c"p:x", r.name)
	assert_strings_equal(c"p", r.prefix)
	assert_strings_equal(c"x", r.local)
	assert_strings_equal(c"urn:p", r.ns_uri)
	assert_strings_equal(c"urn:p", r.attrs[0].ns_uri)
	assert_strings_equal(c"a", r.attrs[0].local)
	# Unprefixed attributes are in no namespace, even with a default one.
	assert_strings_equal(c"", r.attrs[1].ns_uri)
	assert_equal(XML_END, xml_next(r))
	assert_strings_equal(c"urn:p", r.ns_uri)
	assert_strings_equal(c"x", r.local)
	assert_equal(XML_START, xml_next(r))
	assert_strings_equal(c"", r.ns_uri)
	assert_equal(XML_END, xml_next(r))
	assert_strings_equal(c"", r.ns_uri)
	assert_equal(XML_START, xml_next(r))
	assert_strings_equal(c"urn:q", r.ns_uri)
	assert_equal(XML_END, xml_next(r))
	assert_strings_equal(c"urn:q", r.ns_uri)
	assert_equal(XML_START, xml_next(r))
	assert_strings_equal(xml_namespace_xml(), r.ns_uri)
	assert_strings_equal(xml_namespace_xml(), r.attrs[0].ns_uri)
	assert_equal(XML_END, xml_next(r))
	# Back in root's scope: the inner rebinding of p is gone.
	assert_equal(XML_END, xml_next(r))
	assert_strings_equal(c"urn:d", r.ns_uri)
	assert_equal(XML_EOF, xml_next(r))
	xml_reader_free(r)


void test_namespace_errors():
	expect_error(c"<p:a/>", c"unbound prefix: line 1, column 0")
	expect_error(c"<a p:x='1'/>", c"unbound prefix")
	expect_error(c"<a><p:b xmlns:p='u'/><p:c/></a>", c"unbound prefix: line 1, column 21")
	expect_error(c"<a xmlns:p='u' xmlns:q='u' p:x='1' q:x='2'/>", c"duplicate attribute")
	expect_error(c"<a xmlns:p=''/>", c"must not undeclare prefix")
	expect_error(c"<a xmlns:xmlns='u'/>", c"reserved prefix (xmlns)")
	expect_error(c"<xmlns:a/>", c"reserved prefix (xmlns)")
	expect_error(c"<a xmlns:xml='u'/>", c"reserved prefix (xml)")
	expect_error(c"<a xmlns:p='http://www.w3.org/XML/1998/namespace'/>", c"reserved namespace names")
	expect_error(c"<a xmlns='http://www.w3.org/2000/xmlns/'/>", c"reserved namespace names")
	expect_error(c"<a:b:c xmlns:a='u'/>", c"invalid qualified name")
	expect_error(c"<:a/>", c"invalid qualified name")
	expect_error(c"<a: xmlns:a='u'/>", c"invalid qualified name")
	# Binding xml to its own namespace is allowed.
	expect_trace(c"<a xmlns:xml='http://www.w3.org/XML/1998/namespace'/>", c"<a xmlns:xml=\"http://www.w3.org/XML/1998/namespace\"/>|</a>")


void test_line_col():
	int line = 0
	int col = 0
	xml_line_col(c"ab\ncd\r\nef\rg", 9, &line, &col)
	assert_equal(3, line)
	assert_equal(2, col)
	xml_line_col(c"ab\ncd\r\nef\rg", 11, &line, &col)
	assert_equal(4, line)
	assert_equal(1, col)


void test_event_positions():
	xml_reader* r = xml_reader_new(c"<a>\n <b/>x</a>")
	assert_equal(XML_START, xml_next(r))
	assert_equal(0, r.event_pos)
	assert_equal(XML_TEXT, xml_next(r))
	assert_equal(3, r.event_pos)
	assert_equal(XML_START, xml_next(r))
	assert_equal(5, r.event_pos)
	xml_reader_free(r)
