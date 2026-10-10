# wbuild: x64
import lib.testing
import libs.extras.html.html

void html_test_tree(html_node* n, string_builder* out):
	while (n != 0):
		if (n.kind == HTML_DOCUMENT):
			html_test_tree(n.first_child, out)
		else if (n.kind == HTML_START):
			string_append_char(out, '(')
			string_append(out, n.name)
			html_test_tree(n.first_child, out)
			string_append_char(out, ')')
		else if (n.kind == HTML_TEXT):
			string_append_char(out, '[')
			string_append_bytes(out, n.text, n.text_length)
			string_append_char(out, ']')
		else if (n.kind == HTML_COMMENT):
			string_append(out, c"<!--")
			string_append_bytes(out, n.text, n.text_length)
			string_append(out, c"-->")
		n = n.next_sibling

void html_fixture(char* source, char* expected):
	html_document* doc = html_parse(source, strlen(source))
	assert_equal(0, doc.failed)
	string_builder* out = string_new()
	html_test_tree(doc.root, out)
	assert_strings_equal(expected, out.data)
	string_free(out)
	html_document_free(doc)

void test_html_trees():
	html_fixture(c"", c"(html(head)(body))")
	html_fixture(c"<p>one<p>two", c"(html(head)(body(p[one])(p[two])))")
	html_fixture(c"<ul><li>one<li>two</ul>", c"(html(head)(body(ul(li[one])(li[two]))))")
	html_fixture(c"<dl><dt>a<dd>b<dt>c", c"(html(head)(body(dl(dt[a])(dd[b])(dt[c]))))")
	html_fixture(c"<p>a<div>b</div>c", c"(html(head)(body(p[a])(div[b])[c]))")
	html_fixture(c"<div><b>x</div>y</b>", c"(html(head)(body(div(b[x]))[y]))")
	html_fixture(c"<div/>a<br>b<img src=x>c", c"(html(head)(body(div[a](br)[b](img)[c])))")
	html_fixture(c"<html><head><title>A &amp; B</title></head><body>x</body></html>", c"(html(head(title[A & B]))(body[x]))")
	html_fixture(c"<title>A<b>&lt;</title><p>x", c"(html(head(title[A<b><]))(body(p[x])))")
	html_fixture(c"<style>a>b{content:'&amp;'}</style><script>if (x < 3) x='&amp;';</script><p>x", c"(html(head(style[a>b{content:'&amp;'}])(script[if (x < 3) x='&amp;';]))(body(p[x])))")
	html_fixture(c"<textarea>x</textareax>&amp;</textarea>", c"(html(head)(body(textarea[x</textareax>&])))")
	html_fixture(c"<!--x--><p>a<!--unfinished", c"(html(head)(body<!--x-->(p[a]<!--unfinished-->)))")
	html_fixture(c"<table><tr><td>a<td>b<tr><th>c", c"(html(head)(body(table(tr(td[a])(td[b]))(tr(th[c])))))")
	html_fixture(c"<ul><li>a<ul><li>b<li>c</ul><li>d", c"(html(head)(body(ul(li[a](ul(li[b])(li[c])))(li[d]))))")
	html_fixture(c"<p a='unterminated", c"(html(head)(body(p)))")
	html_fixture(c"x < y </!>", c"(html(head)(body[x ][< y ][</!>]))")

void test_html_tokens():
	char* source = c"<DiV ID='x&amp;y' id=z disabled data-k=12>text</DIV>"
	html_tokenizer* t = html_tokenizer_new(source, strlen(source), 0)
	html_token* token = html_tokenizer_next(t)
	assert_equal(HTML_START, token.kind)
	assert_equal(0, token.start)
	assert_equal(42, token.end)
	assert_strings_equal(c"div", token.name)
	html_attribute* a = token.attributes
	assert_strings_equal(c"id", a.name)
	assert_strings_equal(c"x&y", a.value)
	assert_equal(3, a.value_length)
	assert_equal(5, a.start)
	assert_equal(17, a.end)
	assert_strings_equal(c"disabled", a.next.name)
	assert_strings_equal(c"", a.next.value)
	assert_strings_equal(c"12", a.next.next.value)
	assert_equal(0, cast(int, a.next.next.next))
	asserts(c"duplicate attribute diagnostic", t.diagnostics != 0)
	html_token_free(token)
	token = html_tokenizer_next(t)
	assert_equal(HTML_TEXT, token.kind)
	assert_strings_equal(c"text", token.text)
	assert_equal(4, token.text_length)
	html_token_free(token)
	token = html_tokenizer_next(t)
	assert_equal(HTML_END, token.kind)
	assert_strings_equal(c"div", token.name)
	html_tokenizer_free(t)
	# Tokens own all fields independently from the tokenizer/source.
	assert_strings_equal(c"div", token.name)
	html_token_free(token)

void test_html_script_states():
	# An escaped script start enters double escape: its first end spelling is
	# text, while the second closes the element. Names are ASCII insensitive.
	html_fixture(c"<script><!--<ScRiPt>x</sCrIpT>--></script><p>after", c"(html(head(script[<!--<ScRiPt>x</sCrIpT>-->]))(body(p[after])))")
	html_fixture(c"<script><!--<script>x</script>y</script><p>after", c"(html(head(script[<!--<script>x</script>y]))(body(p[after])))")
	html_fixture(c"<script><!--x</script><p>after", c"(html(head(script[<!--x]))(body(p[after])))")
	# A non-delimited name is not a double escape, and --> exits either mode.
	html_fixture(c"<script><!--<scriptx>x</script><p>after", c"(html(head(script[<!--<scriptx>x]))(body(p[after])))")
	html_fixture(c"<script><!--<script>--></script><p>after", c"(html(head(script[<!--<script>-->]))(body(p[after])))")
	html_fixture(c"<script><!--><script></script><p>after", c"(html(head(script[<!--><script>]))(body(p[after])))")
	html_fixture(c"<script><!--<script/ >x</script/ >y</script><p>after", c"(html(head(script[<!--<script/ >x</script/ >y]))(body(p[after])))")
	# JS quoting never protects an end delimiter; entities remain literal.
	html_fixture(c"<script>'&amp;</script><p>after", c"(html(head(script['&amp;]))(body(p[after])))")
	html_document* doc = html_parse(c"<script><!--<script>", 20)
	assert_equal(0, doc.failed)
	asserts(c"escaped EOF is diagnosed", doc.diagnostics != 0)
	assert_strings_equal(c"EOF in escaped script text", doc.diagnostics.message)
	html_document_free(doc)
	# Every explicit-length prefix can stop in an escape transition. Text and
	# diagnostics remain within the supplied bytes, including repeated EOF.
	char* source = c"<script><!--<script\n>\r\n&x;</script>--></script><p>after"
	for length in range(strlen(source) + 1):
		html_tokenizer* t = html_tokenizer_new(source, length, 0)
		while (1):
			html_token* token = html_tokenizer_next(t)
			int done = token.kind == HTML_EOF
			asserts(c"script span", token.start >= 0 && token.end >= token.start && token.end <= length)
			html_token_free(token)
			if (done): break
		html_token* eof = html_tokenizer_next(t)
		assert_equal(HTML_EOF, eof.kind)
		html_token_free(eof)
		assert_equal(0, t.failed)
		html_tokenizer_free(t)

void test_html_entities_and_bytes():
	html_fixture(c"&lt;&gt;&amp;&quot;&apos;&nbsp;&#65;&#x1f600; &unknown; &#xD800; &#0;", c"(html(head)(body[<>&\"'\xc2\xa0A\xf0\x9f\x98\x80 &unknown; \xef\xbf\xbd \xef\xbf\xbd]))")
	char[5] source
	source[0] = 'a'
	source[1] = 0
	source[2] = 'b'
	source[3] = 13
	source[4] = 10
	html_document* doc = html_parse(source, 5)
	source[0] = 'z'
	assert_equal('a', doc.source[0])
	assert_equal(0, doc.source[1])
	assert_equal(5, doc.source_length)
	html_node* text = doc.root.first_child.first_child.next_sibling.first_child
	assert_equal(6, text.text_length)
	assert_strings_equal(c"a\xef\xbf\xbdb\n", text.text)
	assert_equal(0, text.start)
	assert_equal(5, text.end)
	html_document_free(doc)
	# Length, never a sentinel, is the end of input.
	doc = html_parse(c"<p>xTRAILING", 4)
	text = doc.root.first_child.first_child.next_sibling.first_child.first_child
	assert_strings_equal(c"x", text.text)
	assert_equal(4, text.end)
	html_document_free(doc)

void test_html_limits():
	html_limits limits = html_default_limits()
	limits.input_bytes = 3
	html_document* doc = html_parse_with_limits(c"1234", 4, &limits)
	assert_equal(1, doc.failed)
	assert_equal(0, cast(int, doc.root))
	html_document_free(doc)
	limits = html_default_limits()
	limits.nodes = 4
	doc = html_parse_with_limits(c"x", 1, &limits)
	assert_equal(1, doc.failed)
	assert_equal(4, doc.node_count)
	html_document_free(doc)
	limits = html_default_limits()
	limits.depth = 4
	doc = html_parse_with_limits(c"<div><b>x", 9, &limits)
	assert_equal(1, doc.failed)
	html_document_free(doc)
	limits = html_default_limits()
	limits.tokens = 1
	doc = html_parse_with_limits(c"<p>x", 4, &limits)
	assert_equal(1, doc.failed)
	html_document_free(doc)
	limits = html_default_limits()
	limits.attributes = 1
	doc = html_parse_with_limits(c"<p a b>", 7, &limits)
	assert_equal(1, doc.failed)
	html_document_free(doc)
	limits = html_default_limits()
	limits.diagnostics = 1
	doc = html_parse_with_limits(c"</a></b></c>", 12, &limits)
	assert_equal(0, doc.failed)
	asserts(c"one diagnostic", doc.diagnostics != 0)
	assert_equal(0, cast(int, doc.diagnostics.next))
	html_document_free(doc)
	doc = html_parse(0, -1)
	assert_equal(1, doc.failed)
	html_document_free(doc)
	limits.diagnostics = 0
	doc = html_parse_with_limits(c"</a>", 4, &limits)
	assert_equal(0, cast(int, doc.diagnostics))
	html_document_free(doc)

void test_html_eof_and_spans():
	char* source = c"<!doctype html><title>a&amp;</title><p a='x' b=z><!--x--><script>x</script>"
	int size = strlen(source)
	int length = 0
	while (length <= size):
		html_document* doc = html_parse(source, length)
		assert_equal(0, doc.failed)
		html_node* n = doc.allocations
		while (n != 0):
			asserts(c"valid start", (n.start >= 0) && (n.start <= length))
			asserts(c"valid end", (n.end >= n.start) && (n.end <= length))
			n = n.allocation_next
		html_document_free(doc)
		length = length + 1
	html_document* doc = html_parse(c"<p>a<p>b", 8)
	html_node* p = doc.root.first_child.first_child.next_sibling.first_child
	assert_equal(0, p.start)
	assert_equal(4, p.end)
	assert_equal(4, p.next_sibling.start)
	assert_equal(8, p.next_sibling.end)
	html_document_free(doc)
