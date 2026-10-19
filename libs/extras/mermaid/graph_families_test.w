# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* graph_family_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"graph family parses", d.error == 0)
	return d

void test_graph_requirement_properties_and_relationships():
	char* source = c"requirementDiagram\nrequirement R {\nid: 1\ntext: Correct results\nrisk: high\nverifymethod: test\n}\nelement E {\ntype: simulation\ndocref: report\n}\nE - satisfies -> R\nR <- verifies - E\nR - contains -> E\n"
	mm_document* d = graph_family_parse(source)
	assert_equal(MM_REQUIREMENT, d.kind)
	assert_equal(2, d.nodes.length)
	assert_equal(3, d.edges.length)
	mm_node* n = d.nodes[0]
	assert_equal(4, n.members.length)
	mm_edge* reverse = d.edges[1]
	assert_equal(1, reverse.from_node)
	assert_equal(0, reverse.to_node)
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"requirement text rendered", index_of(svg, c"Correct results") >= 0)
	asserts(c"relationship rendered", index_of(svg, c"satisfies") >= 0)
	char* saved = mm_write(d)
	assert_strings_equal(source, saved)
	free(saved)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_graph_mindmap_ancestry_and_tree_layout():
	mm_document* d = graph_family_parse(c"mindmap\n  root((Ideas))\n    A[First]\n      detail\n    B(Second)\n      detail\n")
	assert_equal(5, d.nodes.length)
	mm_node* n = d.nodes[4]
	assert_equal(3, n.parent)
	mm_scene* s = mm_render(d)
	mm_bounds* root = s.nodes[0]
	mm_bounds* a = s.nodes[1]
	mm_bounds* b = s.nodes[3]
	mm_bounds* leaf = s.nodes[4]
	asserts(c"children advance depth", a.x > root.x + root.w && leaf.x > b.x + b.w)
	asserts(c"sibling subtrees do not overlap", b.y >= a.y + a.h)
	mm_document_free(d)
	char* svg = mm_svg(s)
	asserts(c"scene owns labels", index_of(svg, c"Ideas") >= 0)
	free(svg)
	mm_scene_free(s)

void test_graph_kanban_columns_cards_and_metadata():
	mm_document* d = graph_family_parse(c"kanban\nTodo\n  c[Implement]@{ assigned: 'W team', ticket: W-42, priority: 'High' }\nDone\n  [Test]\n")
	assert_equal(4, d.nodes.length)
	mm_node* card = d.nodes[1]
	assert_equal(0, card.parent)
	assert_equal(3, card.members.length)
	mm_scene* s = mm_render(d)
	mm_bounds* a = s.nodes[0]
	mm_bounds* b = s.nodes[2]
	mm_bounds* c = s.nodes[1]
	asserts(c"columns side by side", b.x > a.x + a.w)
	asserts(c"card inside column", c.x > a.x && c.x + c.w < a.x + a.w && c.y > a.y + 60 && c.y + c.h < a.y + a.h)
	char* svg = mm_svg(s)
	asserts(c"metadata rendered", index_of(svg, c"W-42") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_graph_kanban_ticket_links_and_flattened_nesting():
	char* source = c"---\nconfig:\n  theme: default\n  kanban:\n    ticketBaseUrl: 'https://tracker.example/browse/#TICKET#?view=1'\n---\nkanban\nTodo\n  a[Implement]@{ ticket: W-42 }\n    b[Nested]@{ ticket: 'A B&C' }\n      c[Deeper]\n  d[Plain]@{ assigned: me }\nDone\n"
	mm_document* d = graph_family_parse(source)
	assert_strings_equal(c"https://tracker.example/browse/#TICKET#?view=1", d.ticket_base_url)
	assert_equal(6, d.nodes.length)
	for i in range(1, 5):
		mm_node* card = d.nodes[i]
		assert_equal(0, card.parent)
	mm_node* done = d.nodes[5]
	assert_equal(-1, done.parent)
	mm_scene* s = mm_render(d)
	mm_bounds* column = s.nodes[0]
	mm_bounds* first = s.nodes[1]
	mm_bounds* nested = s.nodes[2]
	asserts(c"nested card flattened into its column", nested.x == first.x && nested.y > first.y + first.h && nested.y + nested.h < column.y + column.h)
	char* svg = mm_svg(s)
	asserts(c"ticket linked", index_of(svg, c"<a href=\"https://tracker.example/browse/W-42?view=1\"><text") >= 0)
	asserts(c"ticket encoded and escaped", index_of(svg, c"<a href=\"https://tracker.example/browse/A%20B%26C?view=1\">") >= 0)
	asserts(c"link closed", index_of(svg, c"ticket: W-42</text></a>") >= 0)
	asserts(c"assigned metadata is not a link", index_of(svg, c"<a href=\"https://tracker.example/browse/me") < 0)
	free(svg)
	char* saved = mm_write(d)
	assert_strings_equal(source, saved)
	free(saved)
	mm_scene_free(s)
	mm_document_free(d)
	d = graph_family_parse(c"kanban\nTodo\n  a[Implement]@{ ticket: W-42 }\n")
	assert_equal(0, cast(int, d.ticket_base_url))
	s = mm_render(d)
	svg = mm_svg(s)
	asserts(c"no base URL, no link", index_of(svg, c"<a ") < 0 && index_of(svg, c"ticket: W-42") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
	list[char*] bad = list[char*]{c"---\nconfig:\n  kanban:\n    ticketBaseUrl: 'javascript:alert(1)'\n---\nkanban\nA\n", c"---\nconfig:\n  kanban:\n    sectionWidth: 200\n---\nkanban\nA\n", c"---\nconfig:\n  kanban:\n    ticketBaseUrl: 'https://a/#TICKET#'\n    ticketBaseUrl: 'https://b/#TICKET#'\n---\nkanban\nA\n", c"---\nconfig:\n  kanban:\n  kanban:\n---\nkanban\nA\n", c"---\nconfig:\n  kanban:\n    ticketBaseUrl\n---\nkanban\nA\n", c"---\nconfig:\n  packet:\n    bitsPerRow: 16\n  theme: default\n    ticketBaseUrl: 'https://a/'\n---\nkanban\nA\n"}
	list[char*] messages = list[char*]{c"ticketBaseUrl must be an http or https URL", c"unsupported kanban setting; supported: ticketBaseUrl", c"duplicate ticketBaseUrl", c"duplicate kanban configuration", c"kanban setting requires colon", c"unsupported frontmatter field or indentation"}
	for i in range(bad.length):
		mm_document* invalid = mm_parse(bad[i], strlen(bad[i]))
		assert_strings_equal(messages[i], invalid.error)
		asserts(c"invalid kanban configuration has no preview", mm_render(invalid) == 0)
		mm_document_free(invalid)
	__w_list_free(cast(__w_list*, bad))
	__w_list_free(cast(__w_list*, messages))
	for size in range(strlen(source) + 1):
		mm_document* prefix = mm_parse(source, size)
		mm_scene* scene = mm_render(prefix)
		asserts(c"kanban prefix parse and render agree", (prefix.error == 0 && scene != 0) || (prefix.error != 0 && scene == 0))
		mm_scene_free(scene)
		mm_document_free(prefix)

void test_graph_family_rejections_and_truncations():
	list[char*] bad = list[char*]{c"mindmap\nA\nB", c"mindmap\nA\n  B\n C", c"mindmap\nA\n  ::icon(fa)", c"kanban\nA\n    B\n  C",c"kanban\nA\n  b[B]@{priority:'urgent'}", c"requirementDiagram\nrequirement R {\nrisk: unknown\n}", c"requirementDiagram\nA - verifies -> B", c"requirementDiagram\nelement E {\nid: 1\n}", c"requirementDiagram\nrequirement R {\nid: 1\nid: 2\n}"}
	for char* text in bad:
		mm_document* d = mm_parse(text, strlen(text))
		asserts(c"invalid syntax rejected", d.error != 0)
		asserts(c"no misleading partial preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))
	list[char*] sources = list[char*]{c"mindmap\nroot((Root))\n  child[Text]\n", c"kanban\nTodo\n  task[Text]@{priority: 'High'}\n", c"requirementDiagram\nrequirement R {\nid: 1\nrisk: low\n}\nR - traces -> R\n"}
	for char* text in sources:
		for size in range(strlen(text) + 1):
			mm_document* d = mm_parse(text, size)
			mm_scene* s = mm_render(d)
			asserts(c"error or render", (d.error != 0 && s == 0) || (d.error == 0 && s != 0))
			mm_scene_free(s)
			mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))

void test_graph_accessible_metadata_and_title_once():
	char* text = c"---\ntitle: Components\n---\narchitecture-beta\naccTitle: Accessible architecture\nservice A(server)[Worker]\n"
	mm_document* d = graph_family_parse(text)
	mm_scene* s = mm_render(d)
	int titles = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && strcmp(p.text, c"Components") == 0): titles = titles + 1
	assert_equal(1, titles)
	char* svg = mm_svg(s)
	asserts(c"accessible title exported", index_of(svg, c"Accessible architecture") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_graph_family_source_mutations_preserve_failure_contract():
	list[char*] sources = list[char*]{c"requirementDiagram\nrequirement R {\nid: 1\n}\n", c"mindmap\nRoot\n  Child\n", c"kanban\nTodo\n  Task\n", c"treeView-beta\nRoot/\n  file.w\n", c"ishikawa-beta\nProblem\nCause\n  Detail\n", c"cynefin-beta\ncomplex\n\"Item\"\n", c"wardley-beta\ncomponent A [0.5,0.5]\n", c"gitGraph\ncommit\nbranch work\ncommit\n", c"block\ncolumns 2\na b\n", c"architecture-beta\nservice a(server)[A]\n", c"usecase-beta\nactor A\nB(Work)\nA --> B\n", c"C4Context\nPerson(a,A)\nSystem(b,B)\nRel(a,b,Uses)\n", c"swimlane-beta\nsubgraph G\na\nend\n", c"eventmodeling\ntf 01 ui A\ntf 02 cmd B\n"}
	char* changes = c"#{}[]():;<>\"'\t\n-@012"
	for char* source in sources:
		mm_document* original = mm_parse(source, strlen(source))
		asserts(c"mutation base parses", original.error == 0)
		for i in range(48):
			int start = i * 7 % (original.length + 1)
			int end = start
			if (i % 2 && end < original.length): end = end + 1
			mm_document* d = mm_edit(original, start, end, changes + i % strlen(changes), 1)
			asserts(c"valid byte edits own a document", d != 0)
			mm_scene* s = mm_render(d)
			if (d.error != 0):
				asserts(c"mutated failures suppress preview", s == 0)
				asserts(c"mutated diagnostics bounded", d.error_offset >= 0 && d.error_offset <= d.length)
			else:
				asserts(c"valid mutations render nonempty viewboxes", s != 0 && s.width > 0 && s.height > 0)
				for mm_node* n in d.nodes: asserts(c"parent indices valid", n.parent >= -1 && n.parent < d.nodes.length)
			mm_scene_free(s)
			mm_document_free(d)
		mm_document_free(original)
	__w_list_free(cast(__w_list*, sources))

void test_graph_hierarchy_accessibility_preserves_indentation():
	list[char*] headers = list[char*]{c"mindmap", c"kanban"}
	for char* header in headers:
		string_builder* source = string_from(c"---\ntitle: Hierarchy title\n---\n")
		string_append(source, header)
		string_append(source, c"\r\naccTitle: Accessible hierarchy\r\nRoot\r\n  Child\r\naccDescr {\r\n  Detailed hierarchy\r\n}\r\n  Sibling\r\n")
		mm_document* d = graph_family_parse(source.data)
		assert_equal(3, d.nodes.length)
		mm_node* sibling = d.nodes[2]
		assert_equal(0, sibling.parent)
		assert_strings_equal(c"Accessible hierarchy", d.accessibility_title)
		assert_strings_equal(c"\n  Detailed hierarchy", d.accessibility_description)
		mm_scene* scene = mm_render(d)
		char* svg = mm_svg(scene)
		asserts(c"hierarchy accessibility exported", index_of(svg, c"<title id=\"mermaid-title\">Accessible hierarchy</title>") >= 0)
		int titles = 0
		for mm_primitive* item in scene.items:
			if (strcmp(item.text, c"Hierarchy title") == 0): titles = titles + 1
		assert_equal(1, titles)
		free(svg)
		mm_scene_free(scene)
		mm_document_free(d)
		string_free(source)
	__w_list_free(cast(__w_list*, headers))
	char* invalid = c"mindmap\naccDescr {text} child\nRoot\n"
	mm_document* bad = mm_parse(invalid, strlen(invalid))
	asserts(c"inline metadata trailing content rejected", bad.error != 0)
	mm_document_free(bad)
