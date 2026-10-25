# wbuild: x64
# Class diagram interaction statements and member display (Mermaid 12.2.0).
import lib.testing
import libs.extras.mermaid.io
import libs.extras.mermaid.render

mm_document* class_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"class diagram parses", d.error == 0)
	return d

void member_shows(char* text, char* expected, int classifier):
	int found = -1
	char* shown = mm_class_member_display(text, &found)
	assert_strings_equal(expected, shown)
	assert_equal(classifier, found)
	free(shown)

void test_class_member_display_rules():
	member_shows(c"+String owner", c"+String owner", 0)
	member_shows(c"-List~int~ ids", c"-List<int> ids", 0)
	member_shows(c"#Map~String, List~int~~ index", c"#Map<String, List<int>> index", 0)
	member_shows(c"~int count$", c"~int count", MM_MEMBER_STATIC)
	member_shows(c"+deposit(amount) bool", c"+deposit(amount) : bool", 0)
	member_shows(c"+getIds(List~int~ seed) List~int~", c"+getIds(List<int> seed) : List<int>", 0)
	member_shows(c"someAbstractMethod()*", c"someAbstractMethod()", MM_MEMBER_ABSTRACT)
	member_shows(c"someStaticMethod()$ int", c"someStaticMethod() : int", MM_MEMBER_STATIC)
	member_shows(c"+isMammal()", c"+isMammal()", 0)
	member_shows(c"broken(List~int", c"broken(List<int", 0)

void test_class_members_render_classifiers():
	mm_document* d = class_parse(c"classDiagram\nclass Duck {\n+String beakColor$\n+swim()*\n+quack(List~int~ times) List~int~\n}\n")
	mm_scene* s = mm_render(d)
	int italic = 0
	int underline = 0
	int shown = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && strcmp(p.text, c"+swim()") == 0 && (p.text_style & MM_TEXT_ITALIC)): italic = 1
		if (p.kind == MM_TEXT && strcmp(p.text, c"+quack(List<int> times) : List<int>") == 0): shown = 1
		if (p.kind == MM_LINE && p.y == p.y2 && p.x2 - p.x < 200 && p.x2 - p.x > 40): underline = underline + 1
	asserts(c"abstract member italic", italic)
	asserts(c"return type shown after the parameters", shown)
	asserts(c"static member underlined", underline >= 1)
	char* svg = mm_svg(s)
	asserts(c"italic exported", index_of(svg, c"font-style=\"italic\"") > 0)
	free(svg)
	mm_scene_free(s)
	char* text = mm_write(d)
	asserts(c"source text unchanged", index_of(text, c"+String beakColor$") > 0)
	free(text)
	mm_document_free(d)

void test_class_link_click_and_callback():
	mm_document* d = class_parse(c"classDiagram\nclass Shape\nlink Shape \"https://www.github.com\" \"This is a tooltip for a link\"\nclass Shape2\nclick Shape2 href \"https://example.com\" \"Tip\" _blank\nclass Shape3\ncallback Shape3 \"callbackFunction\" \"Callback tooltip\"\nclass Shape4\nclick Shape4 call callbackFunction() \"Tooltip\"\n")
	mm_node* a = d.nodes[mm_find_node(d, c"Shape")]
	mm_node* b = d.nodes[mm_find_node(d, c"Shape2")]
	mm_node* c = d.nodes[mm_find_node(d, c"Shape3")]
	mm_node* e = d.nodes[mm_find_node(d, c"Shape4")]
	assert_strings_equal(c"https://www.github.com", a.link)
	assert_strings_equal(c"This is a tooltip for a link", a.tooltip)
	assert_strings_equal(c"_blank", b.link_target)
	assert_strings_equal(c"callbackFunction", c.callback)
	assert_strings_equal(c"callbackFunction()", e.callback)
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"class link exported", index_of(svg, c"<a href=\"https://www.github.com\"><title>This is a tooltip for a link</title>") > 0)
	asserts(c"class callback tooltip only", index_of(svg, c"<g><title>Callback tooltip</title>") > 0)
	asserts(c"callback names are never exported", index_of(svg, c"callbackFunction") < 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
	list[char*] bad = list[char*]{c"classDiagram\nclass A\nlink B \"https://x.org\"\n", c"classDiagram\nclass A\nlink A https\n", c"classDiagram\nclass A\ncallback A \"f\" \"tip\" _blank\n"}
	for char* source in bad:
		d = mm_parse(source, strlen(source))
		asserts(c"invalid interaction rejected", d.error != 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))
