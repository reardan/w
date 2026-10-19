# Native bridge for unchanged html5lib tree fixtures. The caller compares output.
import libs.extras.html.html

void html_fixture_output(html_node* node, int depth):
	while (node != 0):
		print(c"| ")
		for i in range(depth): print(c"  ")
		if (node.kind == HTML_TEXT):
			print(c"\"")
			print(node.text)
			println(c"\"")
		else if (node.kind == HTML_START):
			print(c"<")
			print(node.name)
			println(c">")
			html_fixture_output(node.first_child, depth + 1)
		node = node.next_sibling

int main(int argc, char** argv):
	if (argc != 3): return 2
	html_document* doc = html_parse_fragment(argv[2], strlen(argv[2]), argv[1], 1)
	if (doc.failed):
		html_document_free(doc)
		return 3
	html_fixture_output(doc.root.first_child, 0)
	html_document_free(doc)
	return 0
