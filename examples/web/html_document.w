# An external consumer needs only W's import root and the HTML library.
# Compile: bin/wv2 examples/web/html_document.w -o bin/html_document
import libs.extras.html.html

int main():
	char* input = c"<title>Demo</title><p>Hello &amp; welcome<p>Second paragraph"
	html_document* document = html_parse(input, strlen(input))
	if (document.failed):
		html_document_free(document)
		return 1
	html_node* body = document.root.first_child.first_child.next_sibling
	html_node* element = body.first_child
	while (element != 0):
		if (element.name != 0):
			print(element.name)
			print(c"\n")
		element = element.next_sibling
	html_document_free(document)
	return 0
