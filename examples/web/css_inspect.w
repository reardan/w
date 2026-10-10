# Standalone consumer: bin/wv2 examples/web/css_inspect.w -o bin/css_inspect
import libs.extras.css.css


int main():
	char* source = c"article > .title { color: #123; margin: 2px !important }"
	css_document* sheet = css_parse_stylesheet_n(source, strlen(source), 0)
	int failed = sheet.failed || sheet.diagnostics.length != 0
	if (failed == 0):
		for i in range(sheet.nodes.length):
			css_node* rule = sheet.nodes[i]
			for j in range(rule.children.length):
				css_node* child = rule.children[j]
				if (strcmp(child.kind, c"declaration") == 0): println(child.name)
	css_document_free(sheet)
	return failed
