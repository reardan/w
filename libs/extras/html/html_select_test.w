# wbuild: name=html_select_test
# wbuild: target=html_select_test tag=tests dep=build
# wbuild: step="bin/wv2 x64 --strict libs/extras/html/html_select_test.w -o bin/html_select_test"
# wbuild: step="bin/html_select_test" expect_stdout="html_select_test: OK"
# wbuild: step="bin/html_select_test memory" expect_stdout="html_select_test: OK"
import lib.assert
import libs.extras.html.html

void select_dump(html_node* node, string_builder* out):
	while (node != 0):
		if (node.kind == HTML_START):
			string_append_char(out, '(')
			string_append(out, node.name)
			select_dump(node.first_child, out)
			string_append_char(out, ')')
		else if (node.kind == HTML_TEXT):
			string_append_char(out, '[')
			string_append_bytes(out, node.text, node.text_length)
			string_append_char(out, ']')
		node = node.next_sibling

void select_check_links(html_node* parent):
	html_node* node = parent.first_child
	html_node* last = 0
	while (node != 0):
		assert1(node.parent == parent)
		assert_equal(parent.depth + 1, node.depth)
		select_check_links(node)
		last = node
		node = node.next_sibling
	assert1(last == parent.last_child)

void select_case(char* source, char* expected, int fragment):
	html_document* doc = 0
	if (fragment): doc = html_parse_fragment(source, strlen(source), c"select", 1)
	else: doc = html_parse(source, strlen(source))
	assert_equal(0, doc.failed)
	select_check_links(doc.root)
	string_builder* out = string_new()
	select_dump(doc.root.first_child, out)
	if (strcmp(expected, out.data) != 0):
		println(source)
		println(out.data)
	assert_equal(0, strcmp(expected, out.data))
	string_free(out)
	html_document_free(doc)

void select_semantics():
	# Frozen HTML in-body rules, not historical in-select token filtering.
	select_case(c"<select><div>x</div><button>b</button><datalist><option>o</datalist></select>", c"(html(head)(body(select(div[x])(button[b])(datalist(option[o])))))", 0)
	select_case(c"<select><button>b</select><p>x", c"(html(head)(body(select(button[b]))(p[x])))", 0)
	select_case(c"<select><button><select><div>x</div></button></select>", c"(html(head)(body(select(button))(div[x])))", 0)
	select_case(c"<select><button><div><select>x", c"(html(head)(body(select(button(div)))[x]))", 0)
	select_case(c"<select><div><input>x", c"(html(head)(body(select(div))(input)[x]))", 0)
	select_case(c"<select><option>a<input>b", c"(html(head)(body(select(option[a]))(input)[b]))", 0)
	select_case(c"<select><textarea><option></textarea><option>x", c"(html(head)(body(select(textarea[<option>])(option[x]))))", 0)
	select_case(c"<select><option>a<hr><option>b", c"(html(head)(body(select(option[a])(hr)(option[b]))))", 0)
	select_case(c"<select><optgroup><option>a<optgroup><option>b", c"(html(head)(body(select(optgroup(option[a]))(optgroup(option[b])))))", 0)
	select_case(c"<select><optgroup><option>a<option>b", c"(html(head)(body(select(optgroup(option[a])(option[b])))))", 0)
	select_case(c"<select><option><div><option>x", c"(html(head)(body(select(option(div(option[x]))))))", 0)
	# Object is a scope barrier: nested selects remain inside that subtree.
	select_case(c"<select><object><select><option>x", c"(html(head)(body(select(object(select(option[x]))))))", 0)
	select_case(c"<select><object><select><option>x</object><option>y", c"(html(head)(body(select(object(select(option[x])))(option[y]))))", 0)
	select_case(c"</select><option>", c"(option)", 1)
	select_case(c"<input><option>", c"(option)", 1)
	select_case(c"<keygen><option>", c"(keygen)(option)", 1)
	select_case(c"<textarea><option>", c"(textarea[<option>])", 1)
	select_case(c"<select><select><option>x</select></select>", c"(option[x])", 1)
	select_case(c"<div><input><select><option>x</select></div>", c"(div(option[x]))", 1)
	select_case(c"<option>a<option>b<optgroup><option>c", c"(option[a])(option[b])(optgroup(option[c]))", 1)
	# The context is not on the open-element stack: these fragment rules differ
	# from document select rules, exactly as specified by has-select-in-scope.
	select_case(c"<option>a<hr>b", c"(option[a](hr)[b])", 1)
	select_case(c"<optgroup><option>a<optgroup><option>b", c"(optgroup(option[a])(optgroup(option[b])))", 1)
	select_case(c"<option><div><option>x", c"(option(div(option[x])))", 1)

void select_limits():
	char* source = c"<select><div><input><option>a<optgroup><option>b</select><textarea><option>"
	for size in range(strlen(source) + 1):
		for cap in range(4, 16):
			html_limits limits = html_default_limits()
			limits.nodes = cap
			html_document* doc = html_parse_fragment_with_limits(source, size, c"select", 1, &limits)
			assert1(doc.node_count <= cap)
			if (doc.root != 0): select_check_links(doc.root)
			html_node* node = doc.allocations
			while (node != 0):
				assert1(node.start >= 0 && node.start <= size)
				assert1(node.end >= node.start && node.end <= size)
				node = node.allocation_next
			html_document_free(doc)
	char* owned = strclone(c"<input><option a=b>x")
	html_document* doc = html_parse_fragment(owned, strlen(owned), c"select", 0)
	free(owned)
	assert_equal(0, doc.failed)
	assert_equal(0, strcmp(c"option", doc.root.first_child.name))
	assert_equal(0, strcmp(c"a", doc.root.first_child.attributes.name))
	assert_equal(0, strcmp(c"b", doc.root.first_child.attributes.value))
	assert_equal(0, strcmp(c"x", doc.root.first_child.first_child.text))
	html_document_free(doc)

int main(int argc, char** argv):
	if (argc > 1): malloc_force_debug_mode()
	select_semantics()
	select_limits()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"html_select_test: OK")
	return 0
