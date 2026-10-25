# wbuild: tool=tools/wmermaid.w
import tools.host_tools
import lib.str
import libs.standard.formats.xml.etree
import libs.standard.fs.glob

process_result* mc_run(list[char*] args, int ok = 1):
	list[char*] command = ht_argv(c"bin/wmermaid")
	for char* arg in args: command.push(arg)
	process_result* result = ht_run(command, 0, 0, 20000)
	if ((result.status == 0) != ok):
		print2(result.stderr_text)
		ht_require(0, c"unexpected Mermaid CLI status")
	return result

xml_element* mc_svg(char* path):
	xml_element* root = xml_fromstring(ht_read(path).data)
	ht_require(root != 0 && strcmp(root.tag, c"{http://www.w3.org/2000/svg}svg") == 0, c"invalid SVG document")
	return root

int main():
	char* root = ht_temp()
	char* source = path_join(root, c"source.mmd")
	char* copy = path_join(root, c"copy.mmd")
	char* svg = path_join(root, c"diagram.svg")
	char* replacement = path_join(root, c"replacement.txt")
	char* original = c"%% retained\r\nerDiagram\r\nA ||--o{ B : owns\r\n"
	ht_write(source, original, strlen(original))
	mc_run(ht_argv(c"check", source))
	ht_require(strcmp(mc_run(ht_argv(c"read", source)).stdout_text, original) == 0, c"read changed original bytes")
	mc_run(ht_argv(c"write", source, copy))
	ht_equal_file(copy, original)
	mc_run(ht_argv(c"svg", source, svg))
	ht_require(contains(xml_text_content(mc_svg(svg)), c"owns"), c"SVG lost relationship label")
	int at = index_of(original, c"owns")
	ht_write(replacement, c"contains", 8)
	mc_run(ht_argv(c"edit", source, itoa(at), itoa(at + 4), replacement, copy))
	ht_equal_file(copy, replace(original, c"owns", c"contains"))
	ht_equal_file(source, original)
	mc_run(ht_argv(c"edit", source, c"1oops", itoa(at), replacement, copy), 0)
	mc_run(ht_argv(c"edit", source, c"999999", c"999999", replacement, copy), 0)
	mc_run(ht_argv(c"write", source, path_join(root, c"missing/output.mmd")), 0)
	ht_equal_file(source, original)
	mc_run(ht_argv(c"write", source, source))
	ht_equal_file(source, original)
	char* invalid = c"unknownDiagram\nA->>B: hello\n"
	ht_write(source, invalid, strlen(invalid))
	ht_require(contains(mc_run(ht_argv(c"check", source), 0).stderr_text, c"unsupported diagram type"), c"missing unsupported diagram diagnostic")
	mc_run(ht_argv(c"write", source, copy))
	ht_equal_file(copy, invalid)
	char* before = ht_read(svg).data
	mc_run(ht_argv(c"svg", source, svg), 0)
	ht_equal_file(svg, before)
	ht_write(source, c"erDiagram\nA\x00B", 13)
	mc_run(ht_argv(c"check", source), 0)
	process_result* read_back = mc_run(ht_argv(c"read", source))
	ht_require(bytes_equal(read_back.stdout_text, read_back.stdout_length, c"erDiagram\nA\x00B", 13), c"binary read lost embedded NUL")
	mc_run(ht_argv(c"check", path_join(root, c"missing.mmd")), 0)
	mc_run(ht_argv(c"nonsense", source), 0)
	char* markdown = c"# Many diagrams\r\n```mermaid\r\nflowchart LR\r\nA[First]\r\n```\r\nBetween\n~~~mermaid\nflowchart TD\nB[Second]\n~~~\nAfter\n"
	ht_write(source, markdown, strlen(markdown))
	mc_run(ht_argv(c"check", source))
	mc_run(ht_argv(c"check", source, c"--diagram", c"1"))
	mc_run(ht_argv(c"svg", source, svg, c"--diagram", c"1"))
	char* text = xml_text_content(mc_svg(svg))
	ht_require(contains(text, c"Second") && !contains(text, c"First"), c"SVG rendered the wrong diagram")
	for char* bad in split(c"2 -1 oops"): mc_run(ht_argv(c"check", source, c"--diagram", bad), 0)
	ht_require(strcmp(mc_run(ht_argv(c"read", source, c"--diagram", c"1")).stdout_text, markdown) == 0, c"selected diagram read lost Markdown")
	ht_write(replacement, c"Edited", 6)
	at = index_of(markdown, c"Second")
	mc_run(ht_argv(c"edit", source, itoa(at), itoa(at + 6), replacement, copy, c"--diagram", c"1"))
	ht_equal_file(copy, replace(markdown, c"Second", c"Edited"))
	mc_run(ht_argv(c"canonical", copy, source, c"--diagram", c"1"))
	text = ht_read(source).data
	ht_require(contains(text, c"Edited") && !contains(text, c"First"), c"canonical selection regression")
	mc_run(ht_argv(c"check", source))
	mc_run(ht_argv(c"canonical", source, copy))
	ht_equal_file(copy, text)
	# format: stdout or -o, --check reports non-canonical input, selection.
	ht_require(strcmp(mc_run(ht_argv(c"format", copy)).stdout_text, text) == 0, c"format stdout differs from canonical")
	mc_run(ht_argv(c"format", c"--check", copy))
	char* loose = c"pie\n\"A\": 1\n"
	ht_write(source, loose, strlen(loose))
	ht_require(contains(mc_run(ht_argv(c"format", c"--check", source), 0).stderr_text, c"not canonically formatted"), c"format --check accepted non-canonical input")
	ht_equal_file(source, loose)
	mc_run(ht_argv(c"format", source, c"-o", copy))
	mc_run(ht_argv(c"format", c"--check", copy))
	char* formatted = ht_read(copy).data
	ht_require(starts_with(formatted, c"pie") && contains(formatted, c"\"A\": 1"), c"format lost pie data")
	ht_require(strcmp(mc_run(ht_argv(c"format", copy)).stdout_text, formatted) == 0, c"format is not idempotent")
	mc_run(ht_argv(c"format", c"--check", path_join(root, c"missing.mmd")), 0)
	mc_run(ht_argv(c"format", source, c"-x", copy), 0)
	mc_run(ht_argv(c"format", c"--check", source, c"-o", copy), 0)
	ht_write(source, markdown, strlen(markdown))
	ht_require(contains(mc_run(ht_argv(c"format", source, c"--diagram", c"1")).stdout_text, c"Second"), c"format selection regression")
	mc_run(ht_argv(c"format", c"--check", source, c"--diagram", c"1"), 0)
	# A parse error has no canonical form; the output file is left alone.
	ht_write(source, c"pie\n\"A\": oops\n", 14)
	before = ht_read(copy).data
	mc_run(ht_argv(c"canonical", source, copy), 0)
	mc_run(ht_argv(c"format", source, c"-o", copy), 0)
	ht_equal_file(copy, before)
	char* deep = path_join(path_join(root, strjoin(c"long-directory-", ht_repeat('x', 100))), strjoin(c"nested-", ht_repeat('y', 80)))
	ht_mkdir(deep)
	char* long_source = path_join(deep, c"diagram.mmd")
	ht_write(long_source, markdown, strlen(markdown))
	mc_run(ht_argv(c"check", long_source, c"--diagram", c"1"))
	mc_run(ht_argv(c"write", long_source, path_join(deep, c"copy.mmd")))
	ht_equal_file(path_join(deep, c"copy.mmd"), markdown)
	for char* example in glob_glob(c"examples/mermaid/*"):
		if (!ends_with(example, c".mmd") && !ends_with(example, c".md")): continue
		mc_run(ht_argv(c"check", example))
		char* raw = ht_read(example).data
		ht_require(strcmp(mc_run(ht_argv(c"read", example)).stdout_text, raw) == 0, c"example read changed bytes")
		mc_run(ht_argv(c"write", example, copy))
		ht_equal_file(copy, raw)
		mc_run(ht_argv(c"svg", example, svg))
		mc_svg(svg)
		if (!ends_with(example, c".mmd") || starts_with(raw, c"---")): continue
		char* title = c"All-family integration"
		char* titled = strjoin(c"---\ntitle: All-family integration\nconfig:\n  theme: dark\n---\n", raw)
		ht_write(source, titled, strlen(titled))
		mc_run(ht_argv(c"check", source))
		mc_run(ht_argv(c"svg", source, svg))
		xml_element* tree = mc_svg(svg)
		int count = 0
		for xml_element* item in xml_findall(tree, c".//{http://www.w3.org/2000/svg}text"):
			if (item.text != 0 && strcmp(item.text, title) == 0): count = count + 1
		ht_require(count == 1, c"frontmatter title missing or repeated")
		xml_element* rect = xml_find(tree, c"{http://www.w3.org/2000/svg}rect")
		ht_require(rect != 0 && strcmp(xml_get(rect, c"fill"), c"#333333") == 0, c"frontmatter theme not applied")
		ht_write(replacement, c"Edited family title", 19)
		at = index_of(titled, title)
		mc_run(ht_argv(c"edit", source, itoa(at), itoa(at + strlen(title)), replacement, copy))
		mc_run(ht_argv(c"check", copy))
		ht_require(ends_with(ht_read(copy).data, raw), c"editing frontmatter changed diagram bytes")
	ht_cleanup()
	println(c"Mermaid CLI integration passed")
	return 0
