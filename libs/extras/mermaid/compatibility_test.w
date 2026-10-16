# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

void test_mermaid_nested_flow_subgraphs_and_local_direction():
	char* source = c"flowchart LR\nOutside --> A\nsubgraph Outer[Outer label]\ndirection TB\nA --> B\nsubgraph Inner\nB --> C\nend\nend\nC --> Done\n"
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"nested subgraphs parse", d.error == 0)
	mm_node* outer = d.nodes[mm_find_node(d, c"Outer")]
	mm_node* inner = d.nodes[mm_find_node(d, c"Inner")]
	assert_equal(1, outer.group)
	assert_strings_equal(c"Outer label", outer.label)
	assert_equal(mm_find_node(d, c"Outer"), inner.parent)
	mm_scene* s = mm_render(d)
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (n.parent < 0): continue
		mm_bounds* b = s.nodes[i]
		mm_bounds* parent = s.nodes[n.parent]
		asserts(c"group contains child", b.x > parent.x && b.y > parent.y && b.x + b.w < parent.x + parent.w && b.y + b.h < parent.y + parent.h)
	char* copy = mm_write(d)
	assert_strings_equal(source, copy)
	free(copy)
	mm_scene_free(s)
	mm_document_free(d)

void test_mermaid_er_textual_cardinality_aliases():
	list[char*] aliases = list[char*]{c"one or zero", c"zero or one", c"one or more", c"one or many", c"many(1)", c"1+", c"zero or more", c"zero or many", c"many(0)", c"0+", c"only one", c"1"}
	list[int] cards = list[int]{0, 0, 3, 3, 3, 3, 2, 2, 2, 2, 1, 1}
	for i in range(aliases.length):
		for j in range(aliases.length):
			string_builder* text = string_from(c"erDiagram\nA ")
			string_append(text, aliases[i])
			if (j % 2): string_append(text, c" optionally to ")
			else: string_append(text, c" to ")
			string_append(text, aliases[j])
			string_append(text, c" B : relation\n")
			mm_document* d = mm_parse(text.data, text.length)
			asserts(c"textual cardinality parses", d.error == 0)
			mm_edge* edge = d.edges[0]
			assert_equal(cards[i], edge.left_card)
			assert_equal(cards[j], edge.right_card)
			assert_equal(j % 2, edge.dashed)
			mm_document_free(d)
			string_free(text)
	__w_list_free(cast(__w_list*, aliases))
	__w_list_free(cast(__w_list*, cards))

void test_mermaid_er_subgraph_and_malformed_groups():
	char* source = c"erDiagram\nsubgraph Domain[Business]\nA {\nint id PK\n}\nA only one to zero or more B : owns\nend\n"
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"ER groups parse", d.error == 0)
	mm_scene* s = mm_render(d)
	asserts(c"ER grouped layout renders", s != 0)
	mm_scene_free(s)
	mm_document_free(d)
	list[char*] invalid = list[char*]{c"flowchart LR\nend", c"flowchart LR\nsubgraph A\nB", c"flowchart LR\nsubgraph A\nsubgraph A\nend\nend", c"erDiagram\nA only oneish to 1 B : bad", c"erDiagram\nA 1 optionally to many(5) B : bad"}
	for char* input in invalid:
		d = mm_parse(input, strlen(input))
		asserts(c"invalid group or cardinality rejected", d.error != 0)
		asserts(c"no partial preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, invalid))

void test_mermaid_markdown_frontmatter_and_accessibility_roundtrip():
	char* source = c"# Schema\r\n\r\n```mermaid\r\n---\r\ntitle: \"Business & orders\"\r\n---\r\nerDiagram\r\naccTitle: Order schema\r\naccDescr {\r\nA < B & safe\r\n}\r\nA ||--o{ B : owns\r\n```\r\nUnchanged prose\r\n"
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"Markdown envelope parses", d.error == 0)
	assert_strings_equal(c"Business & orders", d.title)
	assert_strings_equal(c"Order schema", d.accessibility_title)
	asserts(c"description preserved", index_of(d.accessibility_description, c"A < B & safe") >= 0)
	char* saved = mm_write(d)
	assert_strings_equal(source, saved)
	free(saved)
	mm_scene* scene = mm_render(d)
	mm_document_free(d)
	char* svg = mm_svg(scene)
	asserts(c"accessible title serialized", index_of(svg, c"<title id=\"mermaid-title\">Order schema</title>") >= 0)
	asserts(c"description escaped", index_of(svg, c"A &lt; B &amp; safe") >= 0)
	asserts(c"visible document title", index_of(svg, c">Business &amp; orders</text>") >= 0)
	free(svg)
	mm_scene_free(scene)

void test_mermaid_envelope_original_diagnostics_and_edits():
	char* source = c"Intro\n~~~mermaid\nflowchart LR\nA -->\n~~~\nFooter\n"
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"missing endpoint diagnosed", d.error != 0)
	assert_equal(4, d.error_line)
	assert_equal(6, d.error_column)
	int at = index_of(source, c"-->\n") + 3
	mm_document* fixed = mm_edit(d, at, at, c" B", 2)
	asserts(c"edit reparses embedded diagram", fixed != 0 && fixed.error == 0)
	asserts(c"prose retained", index_of(fixed.source, c"Footer") >= 0)
	mm_document_free(d)
	mm_document_free(fixed)
	list[char*] invalid = list[char*]{c"```mermaid\nflowchart LR\nA", c"```mermaid\nflowchart LR\nA\n```\n```mermaid\nflowchart LR\nB\n```", c"---\ntitle: x\nflowchart LR\nA", c"---\nconfig: {}\n---\nflowchart LR\nA", c"---\ntitle: |\n---\nflowchart LR\nA", c"flowchart LR\naccDescr { never closed"}
	for char* input in invalid:
		d = mm_parse(input, strlen(input))
		asserts(c"malformed envelope rejected", d.error != 0)
		asserts(c"malformed envelope suppresses render", mm_render(d) == 0)
		char* preserved = mm_write(d)
		assert_strings_equal(input, preserved)
		free(preserved)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, invalid))

void test_mermaid_fences_ignore_other_languages_and_allow_long_delimiters():
	char* source = c"```text\n```mermaid\n```\n\n````mermaid\nflowchart LR\nA --> B\n````\n"
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"ignore nested apparent Mermaid fence inside other-language block", d.error == 0)
	assert_equal(2, d.nodes.length)
	mm_document_free(d)
