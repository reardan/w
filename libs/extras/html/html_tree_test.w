# wbuild: name=html_tree_test
# wbuild: target=html_tree_test tag=tests dep=build
# wbuild: step="bin/wv2 x64 --strict libs/extras/html/html_tree_test.w -o bin/html_tree_test"
# wbuild: step="bin/html_tree_test" expect_stdout="html_tree_test: OK"
# wbuild: step="bin/html_tree_test memory" expect_stdout="html_tree_test: OK"
import lib.assert
import libs.extras.html.html

void tree_dump(html_node* node, string_builder* out):
	while (node != 0):
		if (node.kind == HTML_START):
			string_append_char(out, '(')
			string_append(out, node.name)
			tree_dump(node.first_child, out)
			string_append_char(out, ')')
		else if (node.kind == HTML_TEXT):
			string_append_char(out, '[')
			string_append_bytes(out, node.text, node.text_length)
			string_append_char(out, ']')
		node = node.next_sibling

void tree_links(html_node* parent):
	html_node* node = parent.first_child
	html_node* last = 0
	while (node != 0):
		assert1(node.parent == parent)
		assert_equal(parent.depth + 1, node.depth)
		tree_links(node)
		last = node
		node = node.next_sibling
	assert1(last == parent.last_child)

void tree_case(char* source, char* expected):
	html_document* doc = html_parse(source, strlen(source))
	assert_equal(0, doc.failed)
	tree_links(doc.root)
	string_builder* out = string_new()
	tree_dump(doc.root.first_child, out)
	if (strcmp(expected, out.data) != 0):
		println(source)
		println(out.data)
	assert_equal(0, strcmp(expected, out.data))
	string_free(out)
	html_document_free(doc)

void tree_scope_tests():
	tree_case(c"<p>a<address>b<search>c", c"(html(head)(body(p[a])(address[b](search[c]))))")
	tree_case(c"<p>a<button><div>b</div></button>c", c"(html(head)(body(p[a](button(div[b]))[c])))")
	tree_case(c"<p>a<object><div>b</div></object>c", c"(html(head)(body(p[a](object(div[b]))[c])))")
	tree_case(c"<foo>1<p>2</foo>3", c"(html(head)(body(foo[1](p[23]))))")
	tree_case(c"<foo>1<dd>2</foo>3", c"(html(head)(body(foo[1](dd[23]))))")
	tree_case(c"<foo><span>x</foo>y", c"(html(head)(body(foo(span[x]))[y]))")
	tree_case(c"<div>a<button></div>b</button>c", c"(html(head)(body(div[a](button))[bc]))")
	tree_case(c"<div>a<object></div>b</object>c", c"(html(head)(body(div[a](object[b])[c])))")
	tree_case(c"a</p>b", c"(html(head)(body[a](p)[b]))")
	tree_case(c"<p>a<button></p>b", c"(html(head)(body(p[a](button(p)[b]))))")
	tree_case(c"<ul><li>a<div>b<li>c", c"(html(head)(body(ul(li[a](div[b]))(li[c]))))")
	tree_case(c"<ul><li>a<button><li>b", c"(html(head)(body(ul(li[a](button(li[b]))))))")
	tree_case(c"<ul><li>a<ul></li>b", c"(html(head)(body(ul(li[a](ul[b])))))")
	tree_case(c"<dl><dd>a<address>b<dt>c", c"(html(head)(body(dl(dd[a](address[b]))(dt[c]))))")
	# Foreign/table insertion and formatting reconstruction remain independent
	# mandatory slices; these cases cover HTML scope only.

void tree_doctype_ownership():
	char* source = strclone(c"<!doctype html><p a='b'>x")
	html_document* doc = html_parse(source, strlen(source))
	free(source)
	assert_equal(0, doc.failed)
	tree_links(doc.root)
	html_node* declaration = doc.root.first_child
	assert_equal(HTML_DOCTYPE, declaration.kind)
	assert_equal(0, declaration.start)
	assert_equal(15, declaration.end)
	assert_equal(0, strcmp(c" html", declaration.text))
	assert1(declaration.next_sibling == doc.root.last_child)
	assert_equal(0, strcmp(c"html", declaration.next_sibling.name))
	html_document_free(doc)
	doc = html_parse(c"<!doctype html><!doctype bad><p>x", 33)
	assert_equal(HTML_DOCTYPE, doc.root.first_child.kind)
	assert_equal(HTML_START, doc.root.first_child.next_sibling.kind)
	assert1(doc.root.first_child.next_sibling.next_sibling == 0)
	html_document_free(doc)
	doc = html_parse(c"<title>x</title><!doctype bad><p>x", 34)
	assert_equal(HTML_START, doc.root.first_child.kind)
	assert1(doc.root.first_child.next_sibling == 0)
	html_document_free(doc)
	doc = html_parse_fragment(c"<!doctype html><p>x", 18, c"html", 1)
	assert_equal(0, doc.failed)
	assert_equal(HTML_FRAGMENT, doc.root.kind)
	assert_equal(0, strcmp(c"head", doc.root.first_child.name))
	assert_equal(0, strcmp(c"body", doc.root.last_child.name))
	tree_links(doc.root)
	html_document_free(doc)

void tree_limits():
	for cap in range(0, 8):
		for depth in range(0, 6):
			html_limits limits = html_default_limits()
			limits.nodes = cap
			limits.depth = depth
			html_document* fragment = html_parse_fragment_with_limits(c"<!doctype html><p>x", 18, c"html", 1, &limits)
			if (cap < 4 || depth < 3):
				assert_equal(1, fragment.failed)
				assert1(fragment.root == 0)
			if (fragment.root != 0): tree_links(fragment.root)
			html_document_free(fragment)
	char* source = c"<!doctype html><p>a<button></p>b</button><ul><li><div>x<li>y"
	for size in range(strlen(source) + 1):
		for cap in range(4, 18):
			html_limits limits = html_default_limits()
			limits.nodes = cap
			html_document* doc = html_parse_with_limits(source, size, &limits)
			assert1(doc.node_count <= cap)
			if (doc.root != 0): tree_links(doc.root)
			html_node* node = doc.allocations
			while (node != 0):
				assert1(node.start >= 0 && node.start <= size)
				assert1(node.end >= node.start && node.end <= size)
				node = node.allocation_next
			html_document_free(doc)

int main(int argc, char** argv):
	if (argc > 1): malloc_force_debug_mode()
	tree_scope_tests()
	tree_doctype_ownership()
	tree_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"html_tree_test: OK")
	return 0
