# wbuild: x64
import lib.testing
import libs.extras.css.css


css_document* css_test_sheet(char* source):
	return css_parse_stylesheet_n(source, strlen(source), 0)


void test_css_tokens():
	char* source = c"/*x*/ .\\66 oo { width: -1.5e2px; height: 25%; content: \"a\\000042 c\" }"
	css_document* d = css_test_sheet(source)
	assert_equal(0, d.failed)
	assert_equal(0, d.diagnostics.length)
	assert_equal(1, d.nodes.length)
	css_node* rule = d.nodes[0]
	assert_strings_equal(c"qualified-rule", rule.kind)
	assert_equal(4, rule.children.length)
	css_node* selector = rule.children[0]
	assert_strings_equal(c"selector", selector.kind)
	assert_strings_equal(c"foo", d.tokens[selector.first + 1].value)
	css_node* width = rule.children[1]
	assert_strings_equal(c"width", width.name)
	assert_equal(0, width.important)
	assert_strings_equal(c"dimension", d.tokens[width.first].kind)
	assert_strings_equal(c"-1.5e2px", d.tokens[width.first].value)
	css_node* height = rule.children[2]
	assert_strings_equal(c"percentage", d.tokens[height.first].kind)
	css_node* content = rule.children[3]
	assert_strings_equal(c"string", d.tokens[content.first].kind)
	assert_strings_equal(c"aBc", d.tokens[content.first].value)
	assert_equal(0, d.tokens[0].start)
	assert_equal(5, d.tokens[0].end)
	assert_equal(strlen(source), rule.end)
	css_document_free(d)


void test_css_recovery():
	css_document* d = css_test_sheet(c"a { bad; color: red ! ImPoRtAnT; 12: x; width: calc(2px + (3px)); broken ]: x; height: 5px } b { display:block }")
	assert_equal(0, d.failed)
	assert_equal(2, d.nodes.length)
	assert_equal(4, d.nodes[0].children.length)
	assert_equal(4, d.diagnostics.length)
	css_node* color = d.nodes[0].children[1]
	assert_strings_equal(c"color", color.name)
	assert_equal(1, color.important)
	assert_equal(1, color.last - color.first)
	assert_strings_equal(c"red", d.tokens[color.first].value)
	assert_strings_equal(c"width", d.nodes[0].children[2].name)
	assert_strings_equal(c"height", d.nodes[0].children[3].name)
	assert_strings_equal(c"display", d.nodes[1].children[1].name)
	css_document_free(d)
	d = css_test_sheet(c"bad; a { x: ]; color: blue; broken: \"oops\n; width: 2px } b {x:y}")
	assert_equal(2, d.nodes.length)
	assert_equal(3, d.nodes[0].children.length)
	assert_strings_equal(c"color", d.nodes[0].children[1].name)
	assert_strings_equal(c"width", d.nodes[0].children[2].name)
	css_document_free(d)


void test_css_nested():
	css_document* d = css_test_sheet(c"@import url(\"a.css\"); @media screen { a:hover, [x=\"a,b\"] > :is(p,q) { --data: { a:b; c:d }; color:red } } @unknown x { a { b } } @font-face { src: url(x) }")
	assert_equal(0, d.diagnostics.length)
	assert_equal(4, d.nodes.length)
	assert_strings_equal(c"import", d.nodes[0].name)
	css_node* media = d.nodes[1]
	assert_strings_equal(c"media", media.name)
	assert_equal(1, media.children.length)
	css_node* rule = media.children[0]
	assert_equal(4, rule.children.length)
	assert_strings_equal(c"selector", rule.children[1].kind)
	assert_strings_equal(c"--data", rule.children[2].name)
	css_token* opener = d.tokens[rule.children[2].first]
	asserts(c"balanced custom-property block", opener.match > rule.children[2].first)
	assert_strings_equal(c"block", d.nodes[2].children[0].kind)
	assert_strings_equal(c"src", d.nodes[3].children[0].name)
	css_document_free(d)


void test_css_eof_and_length():
	css_document* d = css_test_sheet(c"a { color:red")
	assert_equal(1, d.diagnostics.length)
	assert_equal(1, d.nodes.length)
	assert_strings_equal(c"color", d.nodes[0].children[1].name)
	assert_equal(13, d.nodes[0].end)
	css_document_free(d)
	char* source = c"x:y;ignored:z"
	d = css_parse_declarations_n(source, 3, 0)
	assert_equal(1, d.nodes.length)
	assert_equal(3, d.length)
	css_document_free(d)
	char* raw = cast(char*, malloc(5))
	raw[0] = '"'
	raw[1] = 0
	raw[2] = 'x'
	raw[3] = '"'
	raw[4] = '!'
	d = css_tokenize_n(raw, 4, 0)
	free(raw)
	assert_equal(1, d.tokens.length)
	assert_equal(4, d.tokens[0].value_length)
	assert_equal(239, d.tokens[0].value[0] & 255)
	assert_equal('x', d.tokens[0].value[3])
	css_document_free(d)
	d = css_tokenize_n(c"/*", 2, 0)
	assert_equal(1, d.diagnostics.length)
	css_document_free(d)
	d = css_tokenize_n(c"\"x", 2, 0)
	assert_equal(1, d.diagnostics.length)
	assert_strings_equal(c"string", d.tokens[0].kind)
	css_document_free(d)
	d = css_parse_stylesheet_n(0, 0, 0)
	assert_equal(0, d.failed)
	assert_equal(0, d.nodes.length)
	css_document_free(d)


void test_css_selectors():
	char* source = c"a > .x, :is(a,b), [x~=\"hello\"] + #id"
	css_document* d = css_parse_selectors_n(source, strlen(source), 0)
	assert_equal(0, d.diagnostics.length)
	assert_equal(3, d.nodes.length)
	assert_equal(0, d.nodes[0].start)
	assert_equal(6, d.nodes[0].end)
	assert_strings_equal(c"hash", d.tokens[d.nodes[2].last - 1].kind)
	assert_strings_equal(c"id", d.tokens[d.nodes[2].last - 1].value)
	css_document_free(d)
	d = css_parse_selectors_n(c"a,,b,", 5, 0)
	assert_equal(2, d.nodes.length)
	assert_equal(2, d.diagnostics.length)
	css_document_free(d)


void test_css_limits():
	css_limits* limits = css_default_limits()
	limits.source_bytes = 2
	css_document* d = css_parse_stylesheet_n(c"a{}", 3, limits)
	assert_equal(1, d.failed)
	assert_equal(0, d.tokens.length)
	css_document_free(d)
	limits.source_bytes = 100
	limits.tokens = 2
	d = css_parse_stylesheet_n(c"a{}", 3, limits)
	assert_equal(1, d.failed)
	assert_equal(2, d.tokens.length)
	assert_equal(0, d.nodes.length)
	css_document_free(d)
	limits.tokens = 100
	limits.depth = 1
	d = css_parse_stylesheet_n(c"a{x:(1)}", 8, limits)
	assert_equal(1, d.failed)
	css_document_free(d)
	limits.depth = 10
	limits.nodes = 1
	d = css_parse_stylesheet_n(c"a{x:y}", 6, limits)
	assert_equal(1, d.failed)
	assert_equal(1, d.nodes.length)
	css_document_free(d)
	limits.nodes = 100
	limits.diagnostics = 1
	d = css_parse_declarations_n(c"bad;bad;bad", 11, limits)
	assert_equal(1, d.diagnostics.length)
	assert_equal(0, d.nodes.length)
	css_document_free(d)
	free(limits)


void test_css_deterministic():
	char* source = c"@media (width > 1px) { .\\61 { color: red; bad; --x: [a;b] } }"
	css_document* a = css_test_sheet(source)
	css_document* b = css_test_sheet(source)
	assert_equal(a.tokens.length, b.tokens.length)
	assert_equal(a.diagnostics.length, b.diagnostics.length)
	assert_equal(a.node_count, b.node_count)
	for i in range(a.tokens.length):
		assert_strings_equal(a.tokens[i].kind, b.tokens[i].kind)
		assert_strings_equal(a.tokens[i].value, b.tokens[i].value)
		assert_equal(a.tokens[i].start, b.tokens[i].start)
		assert_equal(a.tokens[i].end, b.tokens[i].end)
		assert_equal(a.tokens[i].match, b.tokens[i].match)
	css_document_free(a)
	css_document_free(b)
