# wbuild: name=html_processing_instruction_test
# wbuild: target=html_processing_instruction_test tag=tests dep=build
# wbuild: step="bin/wv2 x64 --strict libs/extras/html/html_processing_instruction_test.w -o bin/html_processing_instruction_test"
# wbuild: step="bin/html_processing_instruction_test" expect_stdout="html_processing_instruction_test: OK"
# wbuild: step="bin/html_processing_instruction_test memory" expect_stdout="html_processing_instruction_test: OK"
import lib.assert
import libs.extras.html.html

void pi_token(char* input, int kind, char* target, char* data):
	char* owned = strclone(input)
	html_tokenizer* tokenizer = html_tokenizer_new(owned, strlen(owned), 0)
	free(owned)
	html_token* token = html_tokenizer_next(tokenizer)
	assert_equal(kind, token.kind)
	assert_equal(strlen(input), token.end)
	html_tokenizer_free(tokenizer)
	if (target != 0): assert_equal(0, strcmp(target, token.name))
	if (data != 0):
		assert_equal(strlen(data), token.text_length)
		assert_equal(0, strcmp(data, token.text))
	html_token_free(token)

void pi_links(html_node* parent):
	html_node* last = 0
	html_node* node = parent.first_child
	while (node != 0):
		assert1(node.parent == parent)
		assert_equal(parent.depth + 1, node.depth)
		pi_links(node)
		last = node
		node = node.next_sibling
	assert1(parent.last_child == last)

void pi_placement():
	char* input = strclone(c"<?first?><!doctype html><?second?><html><?third?><head><?fourth?></head><?fifth?><body><?sixth?></body><?seventh?></html><?eighth?>")
	html_document* doc = html_parse(input, strlen(input))
	free(input)
	assert_equal(0, doc.failed)
	pi_links(doc.root)
	html_node* first = doc.root.first_child
	assert_equal(HTML_PROCESSING_INSTRUCTION, first.kind)
	assert_equal(0, strcmp(c"first", first.name))
	assert_equal(HTML_DOCTYPE, first.next_sibling.kind)
	assert_equal(0, strcmp(c"second", first.next_sibling.next_sibling.name))
	html_node* html = first.next_sibling.next_sibling.next_sibling
	assert_equal(0, strcmp(c"html", html.name))
	assert_equal(0, strcmp(c"eighth", html.next_sibling.name))
	assert1(doc.root.last_child == html.next_sibling)
	html_node* third = html.first_child
	assert_equal(0, strcmp(c"third", third.name))
	html_node* head = third.next_sibling
	assert_equal(0, strcmp(c"head", head.name))
	assert_equal(0, strcmp(c"fourth", head.first_child.name))
	assert_equal(0, strcmp(c"fifth", head.next_sibling.name))
	html_node* body = head.next_sibling.next_sibling
	assert_equal(0, strcmp(c"body", body.name))
	assert_equal(0, strcmp(c"sixth", body.first_child.name))
	assert_equal(0, strcmp(c"seventh", body.next_sibling.name))
	html_document_free(doc)
	input = c"<div><?span?>"
	doc = html_parse(input, strlen(input))
	body = doc.root.first_child.last_child
	assert_equal(strlen(input), body.first_child.end)
	assert_equal(strlen(input), body.first_child.first_child.end)
	html_document_free(doc)
	# A body end tag must establish body placement before ordinary recovery.
	input = c"</body></p><?data?>"
	doc = html_parse(input, strlen(input))
	body = doc.root.first_child.last_child
	assert_equal(0, strcmp(c"data", body.last_child.name))
	pi_links(doc.root)
	html_document_free(doc)
	input = c"<?before?><body><?inside?></body><?after?></html><?last?>"
	doc = html_parse_fragment(input, strlen(input), c"html", 0)
	assert_equal(HTML_PROCESSING_INSTRUCTION, doc.root.first_child.kind)
	assert_equal(0, strcmp(c"before", doc.root.first_child.name))
	assert_equal(0, strcmp(c"last", doc.root.last_child.name))
	pi_links(doc.root)
	html_document_free(doc)

void pi_raw_and_limits():
	char* source = c"<script><?pi></script><style><?pi></style><body><textarea><?pi></textarea><title><?pi></title><!--<?pi>-->"
	html_document* doc = html_parse(source, strlen(source))
	html_node* node = doc.allocations
	while (node != 0):
		assert1(node.kind != HTML_PROCESSING_INSTRUCTION)
		node = node.allocation_next
	pi_links(doc.root)
	html_document_free(doc)
	# PI data preserves literal NUL; character references stay literal and CRLF
	# normalizes once. The explicit length must outlive source/token storage.
	char* binary = c"<?T a\x00b\r\n&amp;?>"
	doc = html_parse_fragment(binary, 16, c"div", 0)
	node = doc.root.first_child
	assert_equal(HTML_PROCESSING_INSTRUCTION, node.kind)
	assert_equal(9, node.text_length)
	assert_equal('a', node.text[0])
	assert_equal(0, node.text[1])
	assert_equal('b', node.text[2])
	assert_equal(10, node.text[3])
	assert_equal('&', node.text[4])
	html_document_free(doc)
	source = c"<?start?><html><?before?><head><?in?></head><?after?><body><?data?></body><?end?></html><?last?>"
	for length in range(strlen(source) + 1):
		for cap in range(4, 14):
			html_limits limits = html_default_limits()
			limits.nodes = cap
			doc = html_parse_with_limits(source, length, &limits)
			assert1(doc.node_count <= cap)
			if (doc.root != 0): pi_links(doc.root)
			html_document_free(doc)

int main(int argc, char** argv):
	if (argc > 1): malloc_force_debug_mode()
	pi_token(c"<?Target>", HTML_PROCESSING_INSTRUCTION, c"Target", c"")
	pi_token(c"<?_x-2 a &amp; ?>", HTML_PROCESSING_INSTRUCTION, c"_x-2", c"a &amp; ")
	pi_token(c"<?x?data>", HTML_PROCESSING_INSTRUCTION, c"x", c"?data")
	pi_token(c"<?x??>", HTML_PROCESSING_INSTRUCTION, c"x", c"?")
	pi_token(c"<?x   \r\n\tdata?>", HTML_PROCESSING_INSTRUCTION, c"x", c"data")
	pi_token(c"<?xmlfoo>", HTML_PROCESSING_INSTRUCTION, c"xmlfoo", c"")
	pi_token(c"<?XmL>", HTML_COMMENT, 0, c"?XmL")
	pi_token(c"<?XML-stylesheet a?>", HTML_COMMENT, 0, c"?XML-stylesheet a?")
	pi_token(c"<?a.b data>", HTML_COMMENT, 0, c"?a.b data")
	pi_token(c"<?9bad>", HTML_COMMENT, 0, c"?9bad")
	pi_token(c"<?>", HTML_COMMENT, 0, c"?")
	pi_token(c"<?", HTML_EOF, 0, 0)
	pi_token(c"<?target", HTML_EOF, 0, 0)
	pi_token(c"<?target data?", HTML_EOF, 0, 0)
	pi_token(c"<?xml", HTML_EOF, 0, 0)
	pi_token(c"<?xml ", HTML_COMMENT, 0, c"?xml ")
	pi_token(c"<? ", HTML_COMMENT, 0, c"? ")
	pi_placement()
	pi_raw_and_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"html_processing_instruction_test: OK")
	return 0
