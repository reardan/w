# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* style_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"style parses", d.error == 0)
	return d

void test_mermaid_style_properties_and_fillable_shapes():
	mm_document* d = style_parse(c"flowchart LR\nA[Box] --> B{Diamond} --> C((Circle))\nstyle A,B,C fill:#abc,stroke:red,color:#012,stroke-width:4px\n")
	mm_scene* s = mm_render(d)
	int shapes = 0
	int texts = 0
	for mm_primitive* p in s.items:
		if (p.node_style && p.kind != MM_TEXT):
			assert_equal(0xaabbcc, mm_paint_fill(p))
			assert_equal(0xff0000, mm_paint_stroke(p))
			assert_equal(4, mm_paint_width(p))
			shapes = shapes + 1
		if (p.node_style && p.kind == MM_TEXT):
			assert_equal(0x001122, mm_paint_fill(p))
			texts = texts + 1
	assert_equal(3, shapes)
	assert_equal(3, texts)
	char* svg = mm_svg(s)
	asserts(c"SVG fill", index_of(svg, c"fill=\"#aabbcc\"") >= 0)
	asserts(c"SVG stroke", index_of(svg, c"stroke=\"#ff0000\"") >= 0)
	asserts(c"SVG width", index_of(svg, c"stroke-width=\"4\"") >= 0)
	asserts(c"filled diamond", index_of(svg, c"<polygon") >= 0)
	asserts(c"filled circle", index_of(svg, c"<circle") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_mermaid_classes_forward_default_and_precedence():
	mm_document* d = style_parse(c"flowchart LR\nA:::hot --> B\nclass B hot\nclassDef default fill:white,stroke:black,color:black\nclassDef hot fill:red,color:white\nstyle A fill:blue\nclassDef hot stroke:green\n")
	mm_scene* s = mm_render(d)
	int boxes = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_BOX && p.node_style):
			if (boxes == 0): assert_equal(0x0000ff, mm_paint_fill(p))
			else: assert_equal(0xff0000, mm_paint_fill(p))
			assert_equal(0x008000, mm_paint_stroke(p))
			boxes = boxes + 1
	assert_equal(2, boxes)
	mm_scene_free(s)
	char* source = mm_write(d)
	assert_strings_equal(d.source, source)
	free(source)
	mm_document_free(d)

void test_mermaid_style_er_uml_and_groups():
	list[char*] inputs = list[char*]{c"erDiagram\nUSER ||--o{ ORDER : owns\nclassDef entity fill:#fed,color:#123\nclass USER,ORDER entity\n", c"classDiagram\nclass A:::entity {\n+field\n}\nclass B\ncssClass \"A,B\" entity\nclassDef entity fill:#fed,color:#123\n", c"stateDiagram-v2\nA --> B\nclassDef entity fill:#fed,color:#123\nclass A,B entity\n", c"flowchart TB\nsubgraph Group\nA --> B\nend\nclassDef entity fill:#fed,color:#123\nclass Group entity\n"}
	for char* input in inputs:
		mm_document* d = style_parse(input)
		mm_scene* s = mm_render(d)
		char* svg = mm_svg(s)
		asserts(c"family style exported", index_of(svg, c"fill=\"#ffeedd\"") >= 0)
		asserts(c"family text exported", index_of(svg, c"fill=\"#112233\"") >= 0)
		free(svg)
		mm_scene_free(s)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, inputs))

void test_mermaid_theme_palettes_and_variables():
	list[char*] themes = list[char*]{c"default", c"base", c"dark", c"forest", c"neutral"}
	for char* theme in themes:
		string_builder* source = string_from(c"---\nconfig:\n  theme: ")
		string_append(source, theme)
		string_append(source, c"\n---\nflowchart LR\nA --> B\n")
		mm_document* d = style_parse(source.data)
		mm_scene* s = mm_render(d)
		assert_equal(1, s.has_background)
		if (strcmp(theme, c"dark") == 0): assert_equal(0x0f172a, s.background)
		char* svg = mm_svg(s)
		asserts(c"palette background exported", index_of(svg, c"width=\"100%\"") >= 0)
		free(svg)
		mm_scene_free(s)
		mm_document_free(d)
		string_free(source)
	__w_list_free(cast(__w_list*, themes))
	mm_document* d = style_parse(c"---\nconfig:\n  themeVariables:\n    primaryColor: '#123456'\n    primaryTextColor: '#ffffff'\n    primaryBorderColor: '#abcdef'\n    lineColor: '#f00'\n    textColor: '#0f0'\n    background: '#000000'\n  theme: base\n---\nflowchart LR\nA -->|edge| B\n")
	mm_scene* s = mm_render(d)
	assert_equal(0, s.background)
	for mm_primitive* p in s.items:
		if (p.kind == MM_BOX): assert_equal(0x123456, mm_paint_fill(p))
		if (p.node_style): assert_equal(0xabcdef, mm_paint_stroke(p))
		if (p.kind == MM_LINE && p.node_style == 0): assert_equal(0xff0000, mm_paint_stroke(p))
		if (strcmp(p.text, c"edge") == 0): assert_equal(0x00ff00, mm_paint_fill(p))
	mm_scene_free(s)
	mm_document_free(d)

void test_mermaid_style_invalid_values_and_unsupported_properties():
	list[char*] inputs = list[char*]{c"flowchart LR\nA:::missing", c"flowchart LR\nstyle A fill:#ggg", c"flowchart LR\nstyle A fill:url(bad)", c"flowchart LR\nstyle A stroke-width:17px", c"flowchart LR\nstyle A stroke-width:0", c"flowchart LR\nstyle A font-size:12px", c"flowchart LR\nclassDef bad, fill:red", c"flowchart LR\nstyle A fill:red,", c"---\nconfig:\n  theme: missing\n---\nflowchart LR\nA", c"---\nconfig:\n  theme: dark\n  themeVariables:\n    primaryColor: '#fff'\n---\nflowchart LR\nA", c"---\nconfig:\n  theme: base\n  themeVariables:\n    primaryColor: red\n---\nflowchart LR\nA", c"---\nconfig:\n  theme: base\n  themeVariables:\n    fontSize: 12\n---\nflowchart LR\nA"}
	for char* input in inputs:
		mm_document* d = mm_parse(input, strlen(input))
		asserts(c"unsupported style diagnosed", d.error != 0)
		asserts(c"no partial preview", mm_render(d) == 0)
		char* source = mm_write(d)
		assert_strings_equal(input, source)
		free(source)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, inputs))

void test_mermaid_style_transparency_and_scene_ownership():
	mm_document* d = style_parse(c"flowchart LR\nA[Transparent]\nstyle A fill:none,stroke:#000,color:transparent\n")
	mm_scene* s = mm_render(d)
	mm_document_free(d)
	for mm_primitive* p in s.items:
		assert_equal(-1, mm_paint_fill(p))
		assert_equal(0, mm_paint_stroke(p))
	char* svg = mm_svg(s)
	asserts(c"none exported", index_of(svg, c"fill=\"none\"") >= 0)
	free(svg)
	mm_scene_free(s)

void test_mermaid_style_bounds_and_truncated_sources():
	string_builder* text = string_from(c"flowchart LR\nA:::red-->B\nclassDef red fill:red\n")
	mm_document* d = style_parse(text.data)
	mm_document_free(d)
	for i in range(128):
		string_append(text, c"classDef c")
		string_append_int(text, i)
		string_append(text, c" fill:red\n")
	d = mm_parse(text.data, text.length)
	asserts(c"class limit diagnosed", d.error != 0)
	mm_document_free(d)
	string_free(text)
	char* source = c"---\nconfig:\n  theme: base\n  themeVariables:\n    primaryColor: '#f00'\n---\nflowchart LR\nA:::red-->B\nclassDef red fill:#abc,stroke-width:3px\n"
	for length in range(strlen(source) + 1):
		d = mm_parse(source, length)
		mm_scene* scene = mm_render(d)
		if (d.error != 0): asserts(c"prefix errors suppress rendering", scene == 0)
		mm_scene_free(scene)
		mm_document_free(d)
