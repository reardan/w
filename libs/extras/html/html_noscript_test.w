# wbuild: name=html_noscript_test
# wbuild: target=html_noscript_test tag=tests dep=build
# wbuild: step="bin/wv2 x64 --strict libs/extras/html/html_noscript_test.w -o bin/html_noscript_test"
# wbuild: step="bin/html_noscript_test" expect_stdout="html_noscript_test: OK"
# wbuild: step="bin/html_noscript_test memory" expect_stdout="html_noscript_test: OK"
import lib.assert
import libs.extras.html.html

void noscript_links(html_node* parent, int length):
	html_node* node = parent.first_child
	html_node* last = 0
	while (node != 0):
		assert1(node.parent == parent)
		assert_equal(parent.depth + 1, node.depth)
		assert1(node.start >= 0 && node.start <= node.end && node.end <= length)
		noscript_links(node, length)
		last = node
		node = node.next_sibling
	assert1(parent.last_child == last)

void noscript_modes():
	char* input = c"<head><noscript><meta a='b'>&amp;<?inside?></noscript></head><body><noscript><b>x</b></noscript>"
	char* owned = strclone(input)
	html_document* doc = html_parse_with_scripting(owned, strlen(owned), 1)
	free(owned)
	assert_equal(0, doc.failed)
	html_node* head = doc.root.first_child.first_child
	html_node* body = head.next_sibling
	assert_equal(0, strcmp(c"noscript", head.first_child.name))
	assert_equal(0, strcmp(c"<meta a='b'>&amp;<?inside?>", head.first_child.first_child.text))
	assert_equal(0, strcmp(c"<b>x</b>", body.first_child.first_child.text))
	noscript_links(doc.root, strlen(input))
	html_document_free(doc)
	input = c"<head><noscript><html a=b><head><noscript></p><!doctype html><basefont><bgsound><link><meta><style>a<b</style><noframes>x<y</noframes><?inside?> &#32;x</noscript>"
	doc = html_parse_with_scripting(input, strlen(input), 0)
	assert_equal(0, doc.failed)
	head = doc.root.first_child.first_child
	body = head.next_sibling
	assert_equal(0, strcmp(c"b", doc.root.first_child.attributes.value))
	html_node* ns = head.first_child
	html_node* n = ns.first_child
	assert_equal(0, strcmp(c"basefont", n.name))
	assert1(n.first_child == 0)
	n = n.next_sibling
	assert_equal(0, strcmp(c"bgsound", n.name))
	assert1(n.first_child == 0)
	n = n.next_sibling.next_sibling.next_sibling
	assert_equal(0, strcmp(c"style", n.name))
	assert_equal(0, strcmp(c"a<b", n.first_child.text))
	n = n.next_sibling
	assert_equal(0, strcmp(c"noframes", n.name))
	assert_equal(0, strcmp(c"x<y", n.first_child.text))
	assert_equal(HTML_PROCESSING_INSTRUCTION, n.next_sibling.kind)
	assert_equal(0, strcmp(c"  ", ns.last_child.text))
	assert_equal(0, strcmp(c"x", body.first_child.text))
	noscript_links(doc.root, strlen(input))
	html_document_free(doc)
	# The generic API retains its prior noscript tree interpretation.
	input = c"<head><noscript><b>x</b></noscript>"
	doc = html_parse(input, strlen(input))
	head = doc.root.first_child.first_child
	body = head.next_sibling
	assert1(head.first_child == 0)
	assert_equal(0, strcmp(c"noscript", body.first_child.name))
	assert_equal(0, strcmp(c"b", body.first_child.first_child.name))
	html_document_free(doc)

void noscript_fragments_and_limits():
	char* input = c"<noscript><?inside?><b>x</b></noscript><p>tail"
	for mode in range(2):
		html_document* doc = html_parse_fragment(input, strlen(input), c"div", mode)
		assert_equal(0, doc.failed)
		html_node* ns = doc.root.first_child
		assert_equal(0, strcmp(c"noscript", ns.name))
		if (mode): assert_equal(0, strcmp(c"<?inside?><b>x</b>", ns.first_child.text))
		else: assert_equal(HTML_PROCESSING_INSTRUCTION, ns.first_child.kind)
		assert_equal(0, strcmp(c"p", ns.next_sibling.name))
		noscript_links(doc.root, strlen(input))
		html_document_free(doc)
	input = c"<head><noscript> &#32;x</noscript><body><noscript><?pi?><b>x</b></noscript>"
	for mode in range(2):
		for length in range(strlen(input) + 1):
			html_document* doc = html_parse_with_scripting(input, length, mode)
			assert_equal(0, doc.failed)
			noscript_links(doc.root, length)
			html_document_free(doc)
		for quota in range(12):
			html_limits limits = html_default_limits()
			limits.nodes = quota
			html_document* doc = html_parse_with_scripting_limits(input, strlen(input), mode, &limits)
			if (quota < 6): assert_equal(1, doc.failed)
			if (doc.root != 0): noscript_links(doc.root, strlen(input))
			html_document_free(doc)
		for depth in range(6):
			html_limits limits = html_default_limits()
			limits.depth = depth
			html_document* doc = html_parse_with_scripting_limits(input, strlen(input), mode, &limits)
			if (depth < 3): assert_equal(1, doc.failed)
			if (doc.root != 0): noscript_links(doc.root, strlen(input))
			html_document_free(doc)

int main(int argc, char** argv):
	if (argc > 1): malloc_force_debug_mode()
	noscript_modes()
	noscript_fragments_and_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"html_noscript_test: OK")
	return 0
