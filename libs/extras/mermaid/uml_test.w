# wbuild: x64
import lib.testing
import libs.extras.mermaid.io
import libs.extras.mermaid.render

mm_document* uml_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"UML parses", d.error == 0)
	return d

int uml_count(mm_scene* s, int kind):
	int count = 0
	for mm_primitive* p in s.items:
		if (p.kind == kind): count = count + 1
	return count

void test_uml_class_members_and_compartments():
	char* source = c"classDiagram\nclass Item[\"Line item\"] {\n<<service>>\n+save() bool\n-int id\n#String name\n}\nItem : +load() Item\n"
	mm_document* d = uml_parse(source)
	assert_equal(MM_CLASS, d.kind)
	mm_node* n = d.nodes[0]
	assert_strings_equal(c"Line item", n.label)
	assert_strings_equal(c"service", n.annotation)
	assert_equal(4, n.members.length)
	mm_member* m = n.members[0]
	assert_equal(1, m.method)
	m = n.members[1]
	assert_equal(0, m.method)
	mm_scene* s = mm_render(d)
	int field_y = 0
	int method_y = 0
	for mm_primitive* p in s.items:
		if (strcmp(p.text, c"-int id") == 0): field_y = p.y
		if (strcmp(p.text, c"+save() bool") == 0): method_y = p.y
	asserts(c"attributes precede methods regardless of source order", field_y > 0 && field_y < method_y)
	char* roundtrip = mm_write(d)
	assert_strings_equal(source, roundtrip)
	free(roundtrip)
	mm_document_free(d)
	char* svg = mm_svg(s)
	asserts(c"scene owns annotation text", index_of(svg, c"&lt;&lt;service&gt;&gt;") >= 0)
	asserts(c"scene owns members", index_of(svg, c"+load() Item") >= 0)
	free(svg)
	mm_scene_free(s)

void test_uml_relationship_endpoint_matrix():
	list[char*] lefts = list[char*]{c"", c"<", c"<|", c"*", c"o"}
	list[char*] rights = list[char*]{c"", c">", c"|>", c"*", c"o"}
	for dashed in range(2):
		for left in range(5):
			for right in range(5):
				string_builder* text = string_from(c"classDiagram\nA \"1\" ")
				string_append(text, lefts[left])
				if (dashed): string_append(text, c"..")
				else: string_append(text, c"--")
				string_append(text, rights[right])
				string_append(text, c" \"0..*\" B : relation\n")
				mm_document* d = uml_parse(text.data)
				mm_edge* e = d.edges[0]
				assert_equal(left, e.left_marker)
				assert_equal(right, e.right_marker)
				assert_equal(dashed, e.dashed)
				assert_strings_equal(c"1", e.left_label)
				assert_strings_equal(c"0..*", e.right_label)
				assert_strings_equal(c"relation", e.label)
				mm_scene* s = mm_render(d)
				int polygons = 0
				if (left >= 2): polygons = polygons + 1
				if (right >= 2): polygons = polygons + 1
				assert_equal(polygons, uml_count(s, MM_POLYGON))
				char* svg = mm_svg(s)
				asserts(c"multiplicity exported", index_of(svg, c"0..*") >= 0)
				free(svg)
				mm_scene_free(s)
				mm_document_free(d)
				string_free(text)
	__w_list_free(cast(__w_list*, lefts))
	__w_list_free(cast(__w_list*, rights))

void uml_assert_containment(mm_document* d, mm_scene* s):
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent < 0): continue
		mm_bounds* outer = s.nodes[n.parent]
		mm_bounds* inner = s.nodes[i]
		asserts(c"child within group horizontally", inner.x > outer.x && inner.x + inner.w < outer.x + outer.w)
		asserts(c"child below group title and within group", inner.y > outer.y + 40 && inner.y + inner.h < outer.y + outer.h)

void test_uml_namespace_layout_and_cross_namespace_relations():
	mm_document* d = uml_parse(c"classDiagram\nA --> B\nnamespace Outer {\nnamespace Inner {\nclass A {\n+run()\n}\n}\n}\nnamespace Other {\nclass B\n}\n")
	mm_node* a = d.nodes[mm_find_node(d, c"A")]
	mm_node* b = d.nodes[mm_find_node(d, c"B")]
	asserts(c"namespace ownership follows declaration", a.parent != b.parent && a.parent >= 0 && b.parent >= 0)
	mm_scene* s = mm_render(d)
	uml_assert_containment(d, s)
	mm_bounds* outer = s.nodes[mm_find_node(d, c"Outer")]
	mm_bounds* other = s.nodes[mm_find_node(d, c"Other")]
	asserts(c"cross-namespace edges order containing groups", other.y > outer.y + outer.h)
	char* first = mm_svg(s)
	mm_scene_free(s)
	s = mm_render(d)
	char* second = mm_svg(s)
	assert_strings_equal(first, second)
	free(first)
	free(second)
	mm_scene_free(s)
	mm_document_free(d)

void test_uml_state_transitions_and_special_states():
	mm_document* d = uml_parse(c"stateDiagram-v2\ndirection LR\n[*] --> A\nstate \"Working\" as A\nstate C <<choice>>\nstate F <<fork>>\nstate J <<join>>\nA --> C : ready\nC --> F\nF --> B\nB --> J\nJ --> [*]\nA --> A : retry\n")
	assert_equal(MM_STATE, d.kind)
	assert_equal(7, d.edges.length)
	mm_node* initial = d.nodes[0]
	mm_node* final = d.nodes[mm_find_node(d, c"@end:-1")]
	assert_equal(4, initial.shape)
	assert_equal(5, final.shape)
	mm_node* n = d.nodes[mm_find_node(d, c"A")]
	assert_strings_equal(c"Working", n.label)
	mm_scene* s = mm_render(d)
	assert_equal(3, uml_count(s, MM_CIRCLE))
	mm_bounds* fork = s.nodes[mm_find_node(d, c"F")]
	asserts(c"LR fork is vertical bar", fork.h > fork.w)
	char* svg = mm_svg(s)
	asserts(c"transition label rendered", index_of(svg, c"ready") >= 0)
	asserts(c"choice identifier not displayed", index_of(svg, c">C</text>") < 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_uml_composite_states_scoped_initial_final_and_direction():
	mm_document* d = uml_parse(c"stateDiagram\ndirection LR\n[*] --> Active\nstate Active {\ndirection TB\n[*] --> A\nstate A {\n[*] --> B\nB --> [*]\n}\nA --> C\nC --> [*]\n}\nActive --> Done\nDone --> [*]\n")
	mm_scene* s = mm_render(d)
	uml_assert_containment(d, s)
	int starts = 0
	int ends = 0
	for mm_node* n in d.nodes:
		if (n.shape == 4): starts = starts + 1
		if (n.shape == 5): ends = ends + 1
	assert_equal(3, starts)
	assert_equal(3, ends)
	mm_bounds* a = s.nodes[mm_find_node(d, c"A")]
	mm_bounds* c = s.nodes[mm_find_node(d, c"C")]
	mm_bounds* active = s.nodes[mm_find_node(d, c"Active")]
	mm_bounds* done = s.nodes[mm_find_node(d, c"Done")]
	asserts(c"local direction vertical", c.y > a.y + a.h)
	asserts(c"outer direction preserved", done.x > active.x + active.w)
	mm_scene_free(s)
	mm_document_free(d)

void test_uml_edit_roundtrip_and_failed_parse():
	char* source = c"%% comment\r\nclassDiagram\r\nclass Record {\r\n+save()\r\n}\r\n"
	mm_document* d = uml_parse(source)
	int start = index_of(source, c"save")
	mm_document* changed = mm_edit(d, start, start + 4, c"persist", 7)
	asserts(c"edited class parses", changed.error == 0)
	assert_strings_equal(source, d.source)
	mm_node* n = changed.nodes[0]
	mm_member* m = n.members[0]
	assert_strings_equal(c"+persist()", m.text)
	mm_document_free(changed)
	changed = mm_edit(d, d.length, d.length, c"namespace Broken {", 18)
	asserts(c"incomplete edit keeps source but prevents rendering", changed.error != 0 && mm_render(changed) == 0)
	mm_document_free(changed)
	mm_document_free(d)

void test_uml_unsupported_and_malformed_syntax():
	list[char*] cases = list[char*]{c"classDiagram\nclass A {", c"classDiagram\nnamespace N {\nclass A", c"classDiagram\nA ()-- B", c"classDiagram\nclass A~T~", c"classDiagram\nclass A:::red", c"classDiagram\nstyle A fill:red", c"classDiagram\nclass A {\n<<>>\n}", c"classDiagram\nclass A {\n<<service\n}", c"classDiagram\nA == B", c"classDiagram\nnamespace A {\nnamespace A {\n}\n}", c"stateDiagram-v2\nstate A {\nB --> C", c"stateDiagram-v2\nstate A {\nB --> C\n}\nB --> D", c"stateDiagram-v2\nstate A <<unknown>>", c"stateDiagram-v2\nA -.-> B", c"stateDiagram-v2\n[*]", c"stateDiagram-v2\nstate A {\n--\n}", c"stateDiagram-v2\n}", c"stateDiagram-v2\nstate \"label\" A"}
	for char* source in cases:
		mm_document* d = mm_parse(source, strlen(source))
		asserts(c"unsupported UML diagnosed", d.error != 0)
		asserts(c"no partial preview", mm_render(d) == 0)
		char* saved = mm_write(d)
		assert_strings_equal(source, saved)
		free(saved)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, cases))

void test_uml_group_nesting_and_member_limits():
	string_builder* text = string_from(c"stateDiagram-v2\n")
	for i in range(34):
		string_append(text, c"state S")
		string_append_int(text, i)
		string_append(text, c" {\n")
	for i in range(34): string_append(text, c"}\n")
	mm_document* d = mm_parse(text.data, text.length)
	asserts(c"deep groups rejected", d.error != 0)
	asserts(c"specific depth error", index_of(d.error, c"nesting limit") >= 0)
	mm_document_free(d)
	string_free(text)
	text = string_from(c"classDiagram\nclass A {\n")
	for i in range(MM_MAX_ITEMS + 1): string_append(text, c"+field\n")
	string_append(text, c"}\n")
	d = mm_parse(text.data, text.length)
	asserts(c"member limit enforced", d.error != 0)
	mm_document_free(d)
	string_free(text)


void test_uml_truncated_source_and_boundary_edits():
	list[char*] sources = list[char*]{c"classDiagram\nnamespace N {\nclass A[\"Label\"] {\n<<service>>\n+get() String\n}\nA \"1\" *--|> \"many\" B : uses\n}\n", c"stateDiagram-v2\nstate \"Outer state\" as Outer\nstate Outer {\n[*] --> A\nstate A <<choice>>\nA --> [*] : done\n}\n"}
	for char* source in sources:
		for length in range(strlen(source) + 1):
			mm_document* d = mm_parse(source, length)
			assert_equal(length, d.length)
			mm_scene* s = mm_render(d)
			if (d.error != 0):
				asserts(c"truncation errors suppress preview", s == 0)
				asserts(c"diagnostic offset inside source", d.error_offset >= 0 && d.error_offset <= d.length)
			else: asserts(c"valid prefixes render", s != 0)
			mm_scene_free(s)
			mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))
