# wbuild: x64
import lib.testing
import libs.extras.mermaid.io
import libs.extras.mermaid.render

mm_document* mm_test_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"parse succeeds", d.error == 0)
	return d

void test_mermaid_er_attributes_and_alias():
	mm_document* d = mm_test_parse(c"erDiagram\nCUSTOMER[\"Customer records\"] {\n int id PK, FK \"Key\"\n string[] names UK\n}\nCUSTOMER ||..o{ ORDER : \"places orders\"\n")
	assert_equal(MM_ER, d.kind)
	assert_equal(2, d.nodes.length)
	mm_node* n = d.nodes[0]
	assert_strings_equal(c"Customer records", n.label)
	assert_equal(2, n.attributes.length)
	mm_attribute* a = n.attributes[0]
	assert_strings_equal(c"PK, FK", a.keys)
	assert_strings_equal(c"Key", a.comment)
	mm_edge* e = d.edges[0]
	assert_equal(1, e.left_card)
	assert_equal(2, e.right_card)
	assert_equal(1, e.dashed)
	assert_strings_equal(c"places orders", e.label)
	mm_document_free(d)

void test_mermaid_every_cardinality_pair():
	char* lefts = c"|o||}o}|"
	char* rights = c"o|||o{|{"
	for l in range(4):
		for r in range(4):
			string_builder* s = string_from(c"erDiagram\nA ")
			string_append_bytes(s, lefts + l * 2, 2)
			string_append(s, c"--")
			string_append_bytes(s, rights + r * 2, 2)
			string_append(s, c" B : relation\n")
			mm_document* d = mm_test_parse(s.data)
			mm_edge* e = d.edges[0]
			assert_equal(l, e.left_card)
			assert_equal(r, e.right_card)
			mm_scene* scene = mm_render(d)
			asserts(c"ER markers rendered", scene.items.length > 10)
			mm_scene_free(scene)
			mm_document_free(d)
			string_free(s)

void test_mermaid_flow_chain_shapes_and_labels():
	mm_document* d = mm_test_parse(c"graph LR; A[\"Start\"] -->|\"go\"| B{Ready} -.-> C((End)); B --> D(Wait)\n")
	assert_equal(4, d.nodes.length)
	assert_equal(3, d.edges.length)
	mm_node* b = d.nodes[1]
	mm_node* c = d.nodes[2]
	assert_equal(3, b.shape)
	assert_equal(2, c.shape)
	mm_edge* e = d.edges[0]
	assert_strings_equal(c"go", e.label)
	mm_document_free(d)

void test_mermaid_lossless_write_and_immutable_edit():
	char* source = c"%% untouched\r\nerDiagram\r\n A ||--o{ B : has\r\n"
	mm_document* d = mm_test_parse(source)
	char* copy = mm_write(d)
	assert_strings_equal(source, copy)
	free(copy)
	int at = index_of(source, c"has")
	mm_document* changed = mm_edit(d, at, at + 3, c"owns", 4)
	asserts(c"edited document valid", changed != 0 && changed.error == 0)
	assert_strings_equal(source, d.source)
	mm_edge* e = changed.edges[0]
	assert_strings_equal(c"owns", e.label)
	assert_equal(0, cast(int, mm_edit(d, -1, 0, c"", 0)))
	assert_equal(0, cast(int, mm_edit(d, 5, 4, c"", 0)))
	mm_document_free(changed)
	mm_document_free(d)

void test_mermaid_invalid_and_unsupported():
	list[char*] cases = list[char*]{c"unknownDiagram\nA->>B: hello", c"erDiagram\nA {\nint id", c"erDiagram\nA ||--o{ B", c"erDiagram\nA ||--o{ B :", c"erDiagram\nA |!--o{ B : bad", c"flowchart ZZ\nA", c"flowchart LR\nA[broken", c"flowchart LR\nsubgraph X\nA", c"flowchart LR\nA =-> B", c"erDiagram\nA {\nint id PK,\n}"}
	for char* source in cases:
		mm_document* d = mm_parse(source, strlen(source))
		asserts(c"invalid input diagnosed", d.error != 0)
		assert_equal(0, cast(int, mm_render(d)))
		asserts(c"diagnostic has line and column", d.error_line > 0 && d.error_column > 0)
		char* preserved = mm_write(d)
		assert_strings_equal(source, preserved)
		free(preserved)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, cases))

void test_mermaid_input_limits_and_nul():
	mm_document* d = mm_parse(0, 1)
	asserts(c"null input rejected", d.error != 0)
	mm_document_free(d)
	d = mm_parse(c"x", MM_MAX_SOURCE + 1)
	asserts(c"oversize input rejected before read", d.error != 0)
	mm_document_free(d)
	char[12] data
	for i in range(12): data[i] = 0
	d = mm_parse(&data[0], 12)
	asserts(c"NUL rejected", d.error != 0)
	mm_document_free(d)

void test_mermaid_svg_escaping_and_determinism():
	mm_document* d = mm_test_parse(c"flowchart TB\nA[\"<script>& safe\"] --> B\nB --> A\nB --> B\n")
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"XML escaped", contains(svg, c"&lt;script&gt;&amp; safe"))
	asserts(c"no active content", contains(svg, c"<script>") == 0)
	mm_scene* other = mm_render(d)
	char* again = mm_svg(other)
	assert_strings_equal(svg, again)
	asserts(c"nonempty dimensions", s.width > 200 && s.height > 200)
	free(svg)
	free(again)
	mm_scene_free(s)
	mm_scene_free(other)
	mm_document_free(d)

void test_mermaid_direction_layout():
	list[char*] dirs = list[char*]{c"TB", c"BT", c"LR", c"RL"}
	for char* dir in dirs:
		string_builder* text = string_from(c"flowchart ")
		string_append(text, dir)
		string_append(text, c"\nA --> B\n")
		mm_document* d = mm_test_parse(text.data)
		mm_scene* s = mm_render(d)
		mm_bounds* a = s.nodes[0]
		mm_bounds* b = s.nodes[1]
		if (strcmp(dir, c"TB") == 0): asserts(c"TB", a.y < b.y)
		if (strcmp(dir, c"BT") == 0): asserts(c"BT", a.y > b.y)
		if (strcmp(dir, c"LR") == 0): asserts(c"LR", a.x < b.x)
		if (strcmp(dir, c"RL") == 0): asserts(c"RL", a.x > b.x)
		mm_scene_free(s)
		mm_document_free(d)
		string_free(text)
	__w_list_free(cast(__w_list*, dirs))

void test_mermaid_file_roundtrip():
	mm_document* d = mm_test_parse(c"erDiagram\nA ||--o{ B : owns\n")
	io_result result
	char* path = c"bin/mermaid_roundtrip_x86.mmd"
	if (__word_size__ == 8): path = c"bin/mermaid_roundtrip_x64.mmd"
	assert_equal(IO_OK, mm_save(d, path, &result))
	mm_document* read = mm_read(path)
	asserts(c"read saved document", read != 0 && read.error == 0)
	assert_strings_equal(d.source, read.source)
	mm_document_free(d)
	mm_document_free(read)
	assert_equal(0, cast(int, mm_read(c"bin/mermaid_missing/no.mmd")))

void test_mermaid_utf8_edit_boundary():
	mm_document* d = mm_test_parse(c"erDiagram\n\"客户\"\n")
	int start = index_of(d.source, c"客户")
	assert_equal(0, cast(int, mm_edit(d, start + 1, start + 1, c"X", 1)))
	mm_document* e = mm_edit(d, start, start + 6, c"Client", 6)
	asserts(c"whole codepoints editable", e != 0 && e.error == 0)
	mm_document_free(e)
	mm_document_free(d)

void test_mermaid_shared_child_layout_and_comments():
	mm_document* d = mm_test_parse(c"erDiagram\nA ||--o{ B : owns\nB ||--|{ C : contains\nD ||..o{ C : describes\nLONE %% comment\n")
	mm_scene* s = mm_render(d)
	for mm_edge* e in d.edges:
		mm_bounds* a = s.nodes[e.from_node]
		mm_bounds* b = s.nodes[e.to_node]
		asserts(c"all DAG edges advance ranks", a.rank < b.rank)
	mm_scene_free(s)
	mm_document_free(d)

void test_mermaid_unicode_and_bom():
	mm_document* d = mm_test_parse(c"﻿erDiagram\n客户 ||--o{ 订单 : 拥有\n客户 {\n string 名称\n}\n")
	mm_node* n = d.nodes[0]
	assert_strings_equal(c"客户", n.id)
	mm_attribute* a = n.attributes[0]
	assert_strings_equal(c"名称", a.name)
	mm_edge* e = d.edges[0]
	assert_strings_equal(c"拥有", e.label)
	mm_document_free(d)

void test_mermaid_item_limits():
	string_builder* s = string_from(c"erDiagram\n")
	for i in range(MM_MAX_ITEMS + 1):
		string_append(s, c"ENTITY_")
		string_append_int(s, i)
		string_append_char(s, 10)
	mm_document* d = mm_parse(s.data, s.length)
	assert_strings_equal(c"node limit exceeded", d.error)
	mm_document_free(d)
	string_free(s)
	s = string_from(c"flowchart TB\n")
	for i in range(MM_MAX_ITEMS + 1): string_append(s, c"A --> B\n")
	d = mm_parse(s.data, s.length)
	assert_strings_equal(c"edge limit exceeded", d.error)
	mm_document_free(d)
	string_free(s)

void test_mermaid_rejects_configuration_and_other_shapes():
	list[char*] cases = list[char*]{c"%%{init: {\"look\": \"handDrawn\"}}%%\nflowchart TB\nA", c"flowchart TB\nA[{database}]", c"erDiagram\nA {\n9bad id\n}"}
	for char* source in cases:
		mm_document* d = mm_parse(source, strlen(source))
		asserts(c"unsupported semantics rejected", d.error != 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, cases))

void test_mermaid_long_label_does_not_multiply_canvas_size():
	string_builder* source = string_from(c"flowchart LR\nA[\"")
	for i in range(300000): string_append_char(source, 'X')
	string_append(source, c"\"]\n")
	for i in range(1, 1024):
		if (i == 1): string_append(source, c"A")
		else:
			string_append(source, c"N")
			string_append_int(source, i - 1)
		string_append(source, c" --> N")
		string_append_int(source, i)
		string_append_char(source, 10)
	mm_document* d = mm_test_parse(source.data)
	mm_scene* scene = mm_render(d)
	# 11px per X (text_metrics.w); one unbroken word never wraps.
	asserts(c"canvas width bounded by total source size", scene.width > 2400000 && scene.width < 4000000)
	asserts(c"canvas height bounded by total row sizes", scene.height > 0 && scene.height < 200000)
	mm_scene_free(scene)
	mm_document_free(d)
	string_free(source)

void test_mermaid_relationship_label_stays_between_entities():
	mm_document* d = mm_test_parse(c"erDiagram\ndirection LR\nA ||--|{ B : contains\n")
	mm_scene* scene = mm_render(d)
	mm_bounds* a = scene.nodes[0]
	mm_bounds* b = scene.nodes[1]
	int found = 0
	for mm_primitive* p in scene.items:
		if (p.kind == MM_TEXT && strcmp(p.text, c"contains") == 0):
			found = 1
			asserts(c"label clears source box", p.x >= a.x + a.w)
			asserts(c"label clears target box", p.x + strlen(p.text) * 8 <= b.x)
	assert_equal(1, found)
	mm_scene_free(scene)
	mm_document_free(d)
