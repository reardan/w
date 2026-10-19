# wbuild: target=html_after_body_fixture tag=tests dep=build
# wbuild: step="bin/wv2 x64 --strict libs/extras/html/fragment_fixture.w -o bin/html_after_body_fixture"
# wbuild: step="bin/html_after_body_fixture div 616263 1 --hex" expect_stdout="abc"
# wbuild: step="bin/html_after_body_fixture div f 1 --hex" expect_status=2
# wbuild: step="bin/html_after_body_fixture div 6g 1 --hex" expect_status=2
# wbuild: target=html_select_upstream_test tag=tests dep=build
# wbuild: step="bin/wv2 x64 --strict libs/extras/html/fragment_fixture.w -o bin/html_select_fixture"
# wbuild: step="python3 libs/extras/html/fragment_upstream.py bin/html_select_fixture --profile modern-select --gate select-context --report bin/html-select-upstream.json"
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
		else if (node.kind == HTML_DOCTYPE):
			print(c"<!DOCTYPE ")
			int start = 0
			while (start < node.text_length && html_space(node.text[start])): start = start + 1
			int end = node.text_length
			while (end > start && html_space(node.text[end - 1])): end = end - 1
			char* declaration = html_slice(node.text, start, end, 1)
			print(declaration)
			free(declaration)
			println(c">")
		else if (node.kind == HTML_COMMENT):
			print(c"<!-- ")
			print(node.text)
			println(c" -->")
		else if (node.kind == HTML_START):
			print(c"<")
			print(node.name)
			println(c">")
			# Attribute ordering is bytewise for this ASCII-name fixture profile.
			html_attribute* previous = 0
			while (1):
				html_attribute* next = 0
				html_attribute* candidate = node.attributes
				while (candidate != 0):
					if ((previous == 0 || strcmp(candidate.name, previous.name) > 0) && (next == 0 || strcmp(candidate.name, next.name) < 0)): next = candidate
					candidate = candidate.next
				if (next == 0): break
				print(c"| ")
				for i in range(depth + 1): print(c"  ")
				print(next.name)
				print(c"=\"")
				print(next.value)
				println(c"\"")
				previous = next
			html_fixture_output(node.first_child, depth + 1)
		node = node.next_sibling

int html_fixture_hex_digit(int c):
	if (c >= '0' && c <= '9'): return c - '0'
	if (c >= 'a' && c <= 'f'): return c - 'a' + 10
	return -1

int main(int argc, char** argv):
	if (argc != 3 && argc != 4 && argc != 5): return 2
	char* source = argv[2]
	int length = strlen(source)
	int encoded = argc == 5
	if (encoded):
		if (strcmp(argv[4], c"--hex") != 0 || length % 2 != 0): return 2
		length = length / 2
		source = cast(char*, malloc(length + 1))
		for i in range(length):
			int high = html_fixture_hex_digit(argv[2][i * 2])
			int low = html_fixture_hex_digit(argv[2][i * 2 + 1])
			if (high < 0 || low < 0):
				free(source)
				return 2
			source[i] = cast(char, high * 16 + low)
		source[length] = 0
	int scripting = 1
	if (argc >= 4): scripting = strcmp(argv[3], c"0") != 0
	html_document* doc = 0
	if (strcmp(argv[1], c"#document") == 0): doc = html_parse(source, length)
	else:
		if (!html_fragment_context_supported(argv[1])):
			if (encoded): free(source)
			return 4
		doc = html_parse_fragment(source, length, argv[1], scripting)
	if (encoded): free(source)
	if (doc.failed):
		html_document_free(doc)
		return 3
	html_fixture_output(doc.root.first_child, 0)
	html_document_free(doc)
	return 0
