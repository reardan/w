# wbuild: name=html_after_body_test
# wbuild: target=html_after_body_test tag=tests dep=build
# wbuild: step="bin/wv2 x64 --strict libs/extras/html/html_after_body_test.w -o bin/html_after_body_test"
# wbuild: step="bin/html_after_body_test" expect_stdout="html_after_body_test: OK"
# wbuild: step="bin/html_after_body_test memory" expect_stdout="html_after_body_test: OK"
import lib.assert
import libs.extras.html.html

void after_body_dump(html_node* node, string_builder* out):
	while (node != 0):
		if (node.kind == HTML_START):
			string_append_char(out, '(')
			string_append(out, node.name)
			after_body_dump(node.first_child, out)
			string_append_char(out, ')')
		else if (node.kind == HTML_TEXT || node.kind == HTML_COMMENT):
			if (node.kind == HTML_COMMENT): string_append_char(out, '!')
			string_append_char(out, '[')
			string_append_bytes(out, node.text, node.text_length)
			string_append_char(out, ']')
		node = node.next_sibling

void after_body_links(html_node* parent):
	html_node* node = parent.first_child
	html_node* last = 0
	while (node != 0):
		assert1(node.parent == parent)
		assert_equal(parent.depth + 1, node.depth)
		after_body_links(node)
		last = node
		node = node.next_sibling
	assert1(last == parent.last_child)

void after_body_case(char* source, int fragment, char* expected):
	char* owned = strclone(source)
	html_document* doc = 0
	if (fragment): doc = html_parse_fragment(owned, strlen(owned), c"html", 0)
	else: doc = html_parse(owned, strlen(owned))
	free(owned)
	assert_equal(0, doc.failed)
	after_body_links(doc.root)
	string_builder* out = string_new()
	after_body_dump(doc.root.first_child, out)
	if (strcmp(expected, out.data) != 0):
		println(source)
		println(out.data)
	assert_equal(0, strcmp(expected, out.data))
	string_free(out)
	html_document_free(doc)

int main(int argc, char** argv):
	if (argc > 1): malloc_force_debug_mode()
	after_body_case(c"<body>a</body><!--b-->", 0, c"(html(head)(body[a])![b])")
	after_body_case(c"<body>a</body><!--b--></html><!--c-->", 0, c"(html(head)(body[a])![b])![c]")
	after_body_case(c"<body>a</html><!--c-->", 0, c"(html(head)(body[a]))![c]")
	after_body_case(c"<div>a</body> b<!--c-->", 0, c"(html(head)(body(div[a b]![c])))")
	after_body_case(c"<div>a</body> \n<!--c-->", 0, c"(html(head)(body(div[a \n]))![c])")
	after_body_case(c"<div>a</html> \n<!--c-->", 0, c"(html(head)(body(div[a \n])))![c]")
	after_body_case(c"<div>a</html><!--c-->b<!--d-->", 0, c"(html(head)(body(div[ab]![d])))![c]")
	after_body_case(c"a</body><html><!--b--></html><!--c-->", 0, c"(html(head)(body[a])![b])![c]")
	after_body_case(c"a</body><!doctype html><!--b--></html><!doctype html><!--c-->", 0, c"(html(head)(body[a])![b])![c]")
	after_body_case(c"<object>a</body><!--b--></object>c", 0, c"(html(head)(body(object[a]![b])[c]))")
	after_body_case(c"<table>a</html><!--b-->", 0, c"(html(head)(body(table[a]![b])))")
	after_body_case(c"</html><!--abc-->", 1, c"(head)(body)![abc]")
	after_body_case(c"<body>a</body><!--b--></html><!--c-->", 1, c"(head)(body[a])![b]![c]")
	after_body_case(c"<div>a</html><!--b-->c<!--d-->", 1, c"(head)(body(div[ac]![d]))![b]")
	after_body_case(c"<head></html><meta><p>", 0, c"(html(head)(body(meta)(p)))")
	after_body_case(c"<div>a</body><body>b", 0, c"(html(head)(body(div[ab])))")
	# Attribute union preserves existing values and validates the cap before
	# transferring token ownership; duplicate body tags do not pop open nodes.
	char* attribute_source = c"<html a=old></html><html a=new b=added c=third>"
	html_document* attrs = html_parse(attribute_source, strlen(attribute_source))
	html_node* element = attrs.root.first_child
	assert_equal(0, strcmp(c"old", html_attribute_find(element.attributes, c"a").value))
	assert_equal(0, strcmp(c"added", html_attribute_find(element.attributes, c"b").value))
	assert_equal(0, strcmp(c"a", element.attributes.name))
	assert_equal(0, strcmp(c"b", element.attributes.next.name))
	assert_equal(0, strcmp(c"c", element.attributes.next.next.name))
	assert1(element.attributes.next.next.next == 0)
	after_body_links(attrs.root)
	html_document_free(attrs)
	html_limits limited = html_default_limits()
	limited.attributes = 1
	attribute_source = c"<html a=old></html><html b=added>"
	attrs = html_parse_with_limits(attribute_source, strlen(attribute_source), &limited)
	assert_equal(1, attrs.failed)
	element = attrs.root.first_child
	assert1(html_attribute_find(element.attributes, c"b") == 0)
	assert_equal(0, strcmp(c"old", html_attribute_find(element.attributes, c"a").value))
	html_document_free(attrs)
	# Every source prefix and allocation/depth refusal keeps a destructible tree.
	char* source = c"<!doctype html><body><div>a</body><!--b--></html><!--c-->x"
	for end in range(strlen(source) + 1):
		html_document* doc = html_parse(source, end)
		assert_equal(0, doc.failed)
		after_body_links(doc.root)
		html_document_free(doc)
	for fragment in range(2):
		for cap in range(12):
			html_limits limits = html_default_limits()
			limits.nodes = cap
			html_document* doc = 0
			if (fragment): doc = html_parse_fragment_with_limits(source, strlen(source), c"html", 0, &limits)
			else: doc = html_parse_with_limits(source, strlen(source), &limits)
			if (doc.root != 0): after_body_links(doc.root)
			html_document_free(doc)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"html_after_body_test: OK")
	return 0
