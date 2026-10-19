# wbuild: x64
# wbuild: target=html_fragment_upstream_test tag=tests dep=build
# wbuild: step="bin/wv2 --strict libs/extras/html/fragment_fixture.w -o bin/html_fragment_fixture"
# wbuild: step="python3 libs/extras/html/fragment_upstream.py bin/html_fragment_fixture"
# wbuild: step="python3 libs/extras/html/fragment_report_test.py"
import lib.testing
import libs.extras.html.html

void html_fragment_text(char* context, char* source, char* expected, int scripting):
	html_document* doc = html_parse_fragment(source, strlen(source), context, scripting)
	assert_equal(0, doc.failed)
	assert_equal(HTML_FRAGMENT, doc.root.kind)
	assert_equal(0, cast(int, doc.root.parent))
	html_node* text = doc.root.first_child
	asserts(c"text child", text != 0 && text.kind == HTML_TEXT)
	assert_strings_equal(expected, text.text)
	assert_equal(strlen(expected), text.text_length)
	assert_equal(0, cast(int, text.next_sibling))
	asserts(c"fragment parent", text.parent == doc.root)
	html_document_free(doc)

void test_fragment_text_contexts():
	html_fragment_text(c"title", c"</title><b>&amp;", c"</title><b>&", 1)
	html_fragment_text(c"textarea", c"\nA\r\nB&notit;", c"\nA\nB¬it;", 1)
	html_fragment_text(c"style", c"</style><b>&amp;", c"</style><b>&amp;", 1)
	html_fragment_text(c"xmp", c"</xmp><b>&amp;", c"</xmp><b>&amp;", 1)
	html_fragment_text(c"iframe", c"</iframe>&amp;", c"</iframe>&amp;", 1)
	html_fragment_text(c"noembed", c"</noembed>&amp;", c"</noembed>&amp;", 1)
	html_fragment_text(c"noframes", c"</noframes>&amp;", c"</noframes>&amp;", 1)
	html_fragment_text(c"script", c"<!--<script></script>--></script><b>&amp;", c"<!--<script></script>--></script><b>&amp;", 1)
	html_fragment_text(c"plaintext", c"</plaintext>\r\n&amp;<b>", c"</plaintext>\n&amp;<b>", 1)
	html_fragment_text(c"noscript", c"</noscript><b>&amp;", c"</noscript><b>&amp;", 1)
	html_fragment_text(c"div", c"a < b </!>&amp;", c"a < b </!>&", 1)

void test_fragment_tree_foundation():
	char* source = c"<body><p>a<p>b<ul><li>c<li>d</ul><!--e--></body>"
	html_document* doc = html_parse_fragment(source, strlen(source), c"div", 1)
	assert_equal(0, doc.failed)
	html_node* first = doc.root.first_child
	assert_strings_equal(c"p", first.name)
	assert_strings_equal(c"a", first.first_child.text)
	assert_strings_equal(c"p", first.next_sibling.name)
	assert_strings_equal(c"ul", first.next_sibling.next_sibling.name)
	assert_equal(2, first.next_sibling.next_sibling.first_child.depth)
	html_document_free(doc)
	doc = html_parse_fragment(c"<b>&amp;</b>", 12, c"noscript", 0)
	assert_equal(0, doc.failed)
	assert_strings_equal(c"b", doc.root.first_child.name)
	assert_strings_equal(c"&", doc.root.first_child.first_child.text)
	html_document_free(doc)
	char* plain = c"<plaintext>x</plaintext><b>&amp;"
	doc = html_parse(plain, strlen(plain))
	assert_equal(0, doc.failed)
	html_node* body = doc.root.first_child.first_child.next_sibling
	assert_strings_equal(c"x</plaintext><b>&amp;", body.first_child.first_child.text)
	html_document_free(doc)

void test_fragment_html_context():
	char* source = c"<!doctype html><title>heading</title><p>body"
	html_document* doc = html_parse_fragment(source, strlen(source), c"html", 1)
	assert_equal(0, doc.failed)
	assert_equal(HTML_FRAGMENT, doc.root.kind)
	html_node* head = doc.root.first_child
	html_node* body = head.next_sibling
	assert_strings_equal(c"head", head.name)
	assert_strings_equal(c"body", body.name)
	asserts(c"html context ownership", head.parent == doc.root && body.parent == doc.root)
	assert_equal(1, head.depth)
	assert_equal(1, body.depth)
	assert_equal(0, cast(int, body.next_sibling))
	assert_strings_equal(c"heading", head.first_child.first_child.text)
	assert_strings_equal(c"body", body.first_child.first_child.text)
	html_document_free(doc)
	doc = html_parse_fragment(c"", 0, c"html", 1)
	assert_equal(0, doc.failed)
	assert_strings_equal(c"head", doc.root.first_child.name)
	assert_strings_equal(c"body", doc.root.last_child.name)
	html_document_free(doc)
	doc = html_parse_fragment(0, -1, c"html", 1)
	assert_equal(1, doc.failed)
	html_document_free(doc)

void test_fragment_ownership_and_limits():
	char* source = strclone(c"A&amp;B")
	char* context = strclone(c"title")
	html_document* doc = html_parse_fragment(source, strlen(source), context, 1)
	source[0] = 'Z'
	free(source)
	free(context)
	assert_strings_equal(c"A&B", doc.root.first_child.text)
	assert_strings_equal(c"A&amp;B", doc.source)
	html_document_free(doc)
	char* input = cast(char*, malloc(3))
	input[0] = 'a'
	input[1] = 0
	input[2] = 'b'
	doc = html_parse_fragment(input, 3, c"plaintext", 1)
	free(input)
	assert_strings_equal(c"a�b", doc.root.first_child.text)
	assert_equal(5, doc.root.first_child.text_length)
	html_document_free(doc)
	doc = html_parse_fragment(c"<tr>", 4, c"table", 1)
	assert_equal(1, doc.failed)
	asserts(c"unsupported context diagnostic", doc.diagnostics != 0)
	assert_equal(0, cast(int, doc.root))
	html_document_free(doc)
	doc = html_parse_fragment(c"", 0, 0, 1)
	assert_equal(1, doc.failed)
	html_document_free(doc)
	html_limits limits = html_default_limits()
	limits.tokens = 1
	doc = html_parse_fragment_with_limits(c"<b>x", 4, c"div", 1, &limits)
	assert_equal(1, doc.failed)
	html_document_free(doc)
	limits = html_default_limits()
	limits.nodes = 4
	doc = html_parse_fragment_with_limits(c"<b><i><u><em>", 13, c"div", 1, &limits)
	assert_equal(1, doc.failed)
	assert_equal(4, doc.node_count)
	html_document_free(doc)
	limits = html_default_limits()
	limits.depth = 3
	doc = html_parse_fragment_with_limits(c"<b><i>x", 7, c"div", 1, &limits)
	assert_equal(1, doc.failed)
	html_document_free(doc)
	for length in range(24):
		doc = html_parse_fragment(c"<!--<script>x</script>-->", length, c"script", 1)
		assert_equal(0, doc.failed)
		html_document_free(doc)
