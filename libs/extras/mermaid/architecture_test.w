# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* arch_parse(char* text):
	mm_document* d = mm_parse(text, strlen(text))
	if (d.error != 0):
		print(d.error)
		print(c"\n")
	asserts(c"architecture sample parses", d.error == 0)
	return d

int arch_center_x(mm_scene* s, int index):
	mm_bounds* b = s.nodes[index]
	return b.x + b.w / 2

void test_architecture_port_pairs_place_relative_positions():
	list[char*] edges = list[char*]{c"a:R -- L:b", c"a:L -- R:b", c"a:T -- B:b", c"a:B -- T:b", c"a:T -- L:b", c"a:R -- T:b"}
	# Expected sign of b relative to a on each axis.
	list[int] xs = list[int]{1, -1, 0, 0, 1, 1}
	list[int] ys = list[int]{0, 0, -1, 1, -1, 1}
	for i in range(edges.length):
		string_builder* text = string_from(c"architecture-beta\nservice a(server)[A]\nservice b(disk)[B]\n")
		string_append(text, edges[i])
		string_append_char(text, 10)
		mm_document* d = arch_parse(text.data)
		mm_scene* s = mm_render(d)
		mm_bounds* a = s.nodes[0]
		mm_bounds* b = s.nodes[1]
		int dx = b.x - a.x
		int dy = b.y - a.y
		if (xs[i] == 0): assert_equal(0, dx)
		if (xs[i] > 0): asserts(c"b right of a", dx > 0)
		if (xs[i] < 0): asserts(c"b left of a", dx < 0)
		if (ys[i] == 0): assert_equal(0, dy)
		if (ys[i] > 0): asserts(c"b below a", dy > 0)
		if (ys[i] < 0): asserts(c"b above a", dy < 0)
		mm_scene_free(s)
		mm_document_free(d)
		string_free(text)
	__w_list_free(cast(__w_list*, edges))
	__w_list_free(cast(__w_list*, xs))
	__w_list_free(cast(__w_list*, ys))

void test_architecture_align_row_and_column():
	mm_document* d = arch_parse(c"architecture-beta\ngroup api(cloud)[API]\nservice db1(database)[DB1] in api\nservice db2(database)[DB2] in api\nservice db3(database)[DB3] in api\nservice mcp(server)[MCP] in api\ndb1:R --> L:mcp\ndb2:R --> L:mcp\ndb3:R --> L:mcp\nalign column db1 db2 db3\n")
	list[int] align = d.arch_align
	assert_equal(5, align.length)
	assert_equal(1, align[0])
	assert_equal(3, align[1])
	mm_scene* s = mm_render(d)
	mm_bounds* db1 = s.nodes[1]
	mm_bounds* db2 = s.nodes[2]
	mm_bounds* db3 = s.nodes[3]
	mm_bounds* mcp = s.nodes[4]
	asserts(c"column shares x", db1.x == db2.x && db2.x == db3.x)
	asserts(c"column keeps order", db1.y < db2.y && db2.y < db3.y)
	asserts(c"downstream to the right", mcp.x > db1.x)
	mm_scene_free(s)
	mm_document_free(d)
	d = arch_parse(c"architecture-beta\nservice src1(server)[Source 1]\nservice src2(server)[Source 2]\nservice src3(server)[Source 3]\nservice proc(server)[Processor]\nsrc1:B --> T:proc\nsrc2:B --> T:proc\nsrc3:B --> T:proc\nalign row src3 src1 src2\n")
	s = mm_render(d)
	mm_bounds* a = s.nodes[0]
	mm_bounds* b = s.nodes[1]
	mm_bounds* c = s.nodes[2]
	mm_bounds* p = s.nodes[3]
	asserts(c"row shares y", a.y == b.y && b.y == c.y)
	asserts(c"row follows declared order", c.x < a.x && a.x < b.x)
	asserts(c"processor below", p.y > a.y)
	mm_scene_free(s)
	mm_document_free(d)

void test_architecture_alignment_across_groups():
	mm_document* d = arch_parse(c"architecture-beta\ngroup storage(database)[Storage]\nservice one(database)[One] in storage\nservice two(database)[Two] in storage\ngroup output(disk)[Output]\nservice brief(disk)[Brief] in output\nservice analyst(server)[Analyst] in output\ntwo:B --> T:brief\nbrief:R --> L:analyst\nalign row one two\nalign row brief analyst\nalign column two brief\n")
	mm_scene* s = mm_render(d)
	assert_equal(arch_center_x(s, 2), arch_center_x(s, 4))
	mm_bounds* storage = s.nodes[0]
	mm_bounds* output = s.nodes[3]
	asserts(c"groups stacked", output.y > storage.y + storage.h)
	char* svg = mm_svg(s)
	asserts(c"straight spine", index_of(svg, c"<line") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_architecture_group_edge_modifiers():
	mm_document* d = arch_parse(c"architecture-beta\ngroup groupOne(cloud)[One]\ngroup groupTwo(cloud)[Two]\nservice server[Server] in groupOne\nservice subnet[Subnet] in groupTwo\nserver{group}:B --> T:subnet{group}\n")
	mm_edge* e = d.edges[0]
	assert_equal(4 | MM_ARCH_GROUP, e.from_port)
	assert_equal(3 | MM_ARCH_GROUP, e.to_port)
	mm_scene* s = mm_render(d)
	mm_bounds* one = s.nodes[0]
	mm_bounds* two = s.nodes[1]
	asserts(c"target group below", two.y > one.y + one.h)
	int found = 0
	for mm_primitive* item in s.items:
		if (item.kind == MM_LINE && item.y == one.y + one.h && item.x == arch_center_x(s, 2)): found = 1
	asserts(c"edge leaves the group border beside the service", found)
	mm_scene_free(s)
	mm_document_free(d)

void test_architecture_icon_packs_and_fallbacks():
	mm_document* d = arch_parse(c"architecture-beta\ngroup api(logos:aws-lambda)[API]\nservice db(logos:aws-aurora)[Database] in api\nservice odd(fa:mystery-thing)[Odd] in api\ndb:L -- R:odd\n")
	mm_node* db = d.nodes[1]
	assert_strings_equal(c"logos:aws-aurora", db.annotation)
	assert_strings_equal(c"database", mm_arch_glyph(db.annotation))
	assert_strings_equal(c"", mm_arch_glyph(c"fa:mystery-thing"))
	assert_strings_equal(c"server", mm_arch_glyph(c"logos:aws-ec2"))
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"unknown icon tile", index_of(svg, c">?</text>") >= 0)
	asserts(c"group icon name", index_of(svg, c"[logos:aws-lambda]") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_architecture_invalid_extensions():
	list[char*] bad = list[char*]{c"architecture-beta\nservice a(bad icon)[A]", c"architecture-beta\nservice a(:x)[A]", c"architecture-beta\nservice a(pack:)[A]", c"architecture-beta\nservice a\nservice b\na{group}:R -- L:b", c"architecture-beta\ngroup g\njunction j in g\nservice b\nj{group}:R -- L:b", c"architecture-beta\nservice a\nalign row a", c"architecture-beta\nservice a\nalign row a b", c"architecture-beta\ngroup g\nservice a\nalign row a g", c"architecture-beta\nservice a\nservice b\nalign row a a b", c"architecture-beta\nservice a\nservice b\nalign diagonal a b", c"architecture-beta\nservice a\nservice b\na{grp}:R -- L:b"}
	for char* text in bad:
		mm_document* d = mm_parse(text, strlen(text))
		asserts(c"invalid architecture rejected", d.error != 0)
		asserts(c"invalid architecture no preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))

void test_architecture_extension_prefixes_are_safe():
	char* text = c"architecture-beta\ngroup g(logos:aws-s3)[G]\nservice a(server)[A] in g\nservice b(disk)[B]\njunction j\na{group}:R --> L:j\nj:R -- L:b\nalign row j b\n"
	for length in range(strlen(text) + 1):
		mm_document* d = mm_parse(text, length)
		mm_scene* s = mm_render(d)
		asserts(c"prefix parse/render consistent", (d.error == 0 && s != 0) || (d.error != 0 && s == 0))
		mm_scene_free(s)
		mm_document_free(d)
