# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

void test_blocks_grid_spans_space_and_composites():
	char* source = c"block-beta\ncolumns 3\na[First] b[Wide]:2\nspace c\nblock:group\ncolumns 1\nx y\nend\na --> c\n"
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"block grid parses", d.error == 0)
	assert_equal(8, d.nodes.length)
	mm_scene* s = mm_render(d)
	mm_bounds* a = s.nodes[1]
	mm_bounds* b = s.nodes[2]
	mm_bounds* c = s.nodes[4]
	mm_bounds* group = s.nodes[5]
	mm_bounds* x = s.nodes[6]
	mm_bounds* y = s.nodes[7]
	asserts(c"span consumes two columns", b.w > a.w * 2 && b.y == a.y)
	asserts(c"space advances grid column", c.y > a.y && c.x > a.x)
	asserts(c"nested layout contained", x.x > group.x && y.y + y.h < group.y + group.h)
	asserts(c"nested columns respected", y.y > x.y)
	char* saved = mm_write(d)
	assert_strings_equal(source, saved)
	free(saved)
	mm_scene_free(s)
	mm_document_free(d)

void test_blocks_invalid_and_truncated_grids():
	list[char*] bad = list[char*]{c"block\ncolumns 0", c"block\ncolumns 65", c"block\ncolumns 2\na:3", c"block\nblock:g\na", c"block\nend", c"block\na{diamond}", c"block\ncolumns 1\ncolumns 2"}
	for char* text in bad:
		mm_document* d = mm_parse(text, strlen(text))
		asserts(c"invalid grid rejected", d.error != 0)
		asserts(c"invalid grid no preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))
	char* text = c"block\ncolumns 2\na[\"First\"] b:1\nblock:g\nx\nend\na --> g\n"
	for length in range(strlen(text) + 1):
		mm_document* d = mm_parse(text, length)
		mm_scene* s = mm_render(d)
		asserts(c"prefix parse/render consistent", (d.error == 0 && s != 0) || (d.error != 0 && s == 0))
		mm_scene_free(s)
		mm_document_free(d)

void test_blocks_large_label_dimensions_stay_bounded():
	string_builder* source = string_from(c"block\ncolumns 64\na[\"")
	for i in range(100000): string_append_char(source, 'X')
	string_append(source, c"\"]\n")
	for i in range(100):
		string_append(source, c"n")
		string_append_int(source, i)
		string_append_char(source, ' ')
	mm_document* d = mm_parse(source.data, source.length)
	asserts(c"large bounded grid parses", d.error == 0)
	mm_scene* s = mm_render(d)
	asserts(c"one long label does not multiply across columns", s.width > 800000 && s.width < 1000000)
	asserts(c"grid height bounded", s.height > 0 && s.height < 1000)
	mm_scene_free(s)
	mm_document_free(d)
	string_free(source)
