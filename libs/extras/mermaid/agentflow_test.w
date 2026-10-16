# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* agent_parse(char* text):
	mm_document* d = mm_parse(text, strlen(text))
	if (d.error != 0): println2(d.error)
	asserts(c"agentflow parses", d.error == 0)
	return d

void test_agentflow_roles_metadata_and_edges():
	char* text = c"agentflow-beta LR\nA[Start]@{shape: task, owner: W}\nB@{shape: tool, label: Execute}\nC@{shape: input}\nD@{shape: decision}\nE@{shape: refdoc}\nF@{shape: action}\nA -- ready --> B --> C\nC -.- E\nD --x F\n"
	mm_document* d = agent_parse(text)
	assert_equal(MM_AGENT, d.kind)
	assert_equal(6, d.nodes.length)
	assert_equal(4, d.edges.length)
	mm_node* tool = d.nodes[1]
	assert_strings_equal(c"Execute", tool.label)
	assert_strings_equal(c"tool", tool.role)
	assert_equal(17, tool.shape)
	mm_edge* edge = d.edges[0]
	assert_strings_equal(c"ready", edge.label)
	edge = d.edges[2]
	assert_equal(1, edge.dashed)
	edge = d.edges[3]
	assert_equal(6, edge.right_marker)
	mm_scene* s = mm_render(d)
	int polygons = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_POLYGON): polygons = polygons + 1
	assert_equal(3, polygons)
	char* saved = mm_write(d)
	assert_strings_equal(text, saved)
	free(saved)
	mm_document_free(d)
	char* svg = mm_svg(s)
	asserts(c"scene owns source labels", index_of(svg, c"Execute") >= 0)
	free(svg)
	mm_scene_free(s)

void test_agentflow_global_nested_flows_and_connectors():
	mm_document* d = agent_parse(c"agentflow-beta\nglobal\nShared[Memory]\nend\nflow Outer[Pipeline]\ndirection LR\nA --> Shared\nflow Inner@{label: Nested}\nB --> Shared\nend\nend\nconnector API[External]@{provider: example, url: https://example.invalid}\n")
	int shared = mm_find_node(d, c"Shared")
	mm_node* n = d.nodes[shared]
	assert_equal(-1, n.parent)
	assert_equal(1, n.global_node)
	n = d.nodes[mm_find_node(d, c"Inner")]
	assert_strings_equal(c"Nested", n.label)
	assert_equal(mm_find_node(d, c"Outer"), n.parent)
	n = d.nodes[mm_find_node(d, c"API")]
	assert_strings_equal(c"connector", n.role)
	assert_equal(2, n.metadata.length)
	mm_scene* s = mm_render(d)
	for i in range(d.nodes.length):
		n = d.nodes[i]
		if (n.parent < 0): continue
		mm_bounds* b = s.nodes[i]
		mm_bounds* parent = s.nodes[n.parent]
		asserts(c"flow contains owned nodes", b.x > parent.x && b.y > parent.y && b.x + b.w < parent.x + parent.w && b.y + b.h < parent.y + parent.h)
	mm_scene_free(s)
	mm_document_free(d)

void test_agentflow_edit_metadata_and_original_source():
	char* text = c"```mermaid\n---\ntitle: Agent pipeline\n---\nagentflow-beta\naccTitle: Tools & tasks\nA@{label: Before, owner: One, owner: Two}\n```\n"
	mm_document* d = agent_parse(text)
	mm_node* n = d.nodes[0]
	assert_equal(2, n.metadata.length)
	mm_property* owner = n.metadata[1]
	assert_strings_equal(c"Two", owner.value)
	int offset = index_of(text, c"Before")
	mm_document* edited = mm_edit(d, offset, offset + 6, c"After", 5)
	asserts(c"source edit reparses", edited != 0 && edited.error == 0)
	n = edited.nodes[0]
	assert_strings_equal(c"After", n.label)
	mm_scene* s = mm_render(edited)
	char* svg = mm_svg(s)
	asserts(c"metadata escaped", index_of(svg, c"Tools &amp; tasks") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(edited)
	mm_document_free(d)

void test_agentflow_rejections_and_truncations():
	list[char*] bad = list[char*]{c"agentflow\nA", c"agentflow-beta\nA@{shape: unknown}", c"agentflow-beta\nA@{value: [1,2]}", c"agentflow-beta\nflow A@{view: collapsed}\nend", c"agentflow-beta\nglobal\nA", c"agentflow-beta\nA@{label: }", c"agentflow-beta\nend"}
	for char* text in bad:
		mm_document* d = mm_parse(text, strlen(text))
		asserts(c"unsupported or malformed input rejected", d.error != 0)
		asserts(c"no partial preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))
	char* text = c"agentflow-beta\nflow P\nA@{shape: tool, label: Work}\nA --x B\nend\n"
	for size in range(strlen(text) + 1):
		mm_document* d = mm_parse(text, size)
		mm_scene* s = mm_render(d)
		asserts(c"each prefix either diagnoses or renders", (d.error != 0 && s == 0) || (d.error == 0 && s != 0))
		mm_scene_free(s)
		mm_document_free(d)

void test_agentflow_metadata_limits_and_reserved_keys():
	mm_document* d = agent_parse(c"agentflow-beta\nA@{__proto__: bad, constructor: bad, prototype: bad, owner: kept}\n")
	mm_node* n = d.nodes[0]
	assert_equal(1, n.metadata.length)
	mm_property* property = n.metadata[0]
	assert_strings_equal(c"owner", property.key)
	mm_document_free(d)
	string_builder* text = string_from(c"agentflow-beta\nA@{")
	for i in range(64):
		if (i != 0): string_append_char(text, ',')
		string_append(text, c"key")
		string_append_int(text, i)
		string_append(text, c":value")
	string_append(text, c",key0:updated}\n")
	d = agent_parse(text.data)
	n = d.nodes[0]
	assert_equal(64, n.metadata.length)
	property = n.metadata[0]
	assert_strings_equal(c"updated", property.value)
	mm_document_free(d)
	string_append(text, c"A@{extra:overflow}\n")
	d = mm_parse(text.data, text.length)
	asserts(c"metadata entry limit", d.error != 0)
	mm_document_free(d)
	string_free(text)
	text = string_from(c"agentflow-beta\n")
	for i in range(34): string_append(text, c"global\n")
	string_append(text, c"A\n")
	for i in range(34): string_append(text, c"end\n")
	d = mm_parse(text.data, text.length)
	asserts(c"global nesting bounded", d.error != 0)
	mm_document_free(d)
	string_free(text)

void test_agentflow_global_flow_ownership_and_failure_marker():
	mm_document* d = agent_parse(c"agentflow-beta LR\nglobal\nflow Shared\nA --> B\nend\nend\nflow Local\nC --x Shared\nend\n")
	mm_node* shared = d.nodes[mm_find_node(d, c"Shared")]
	mm_node* child = d.nodes[mm_find_node(d, c"A")]
	assert_equal(-1, shared.parent)
	assert_equal(1, shared.global_node)
	assert_equal(mm_find_node(d, c"Shared"), child.parent)
	assert_equal(0, child.global_node)
	mm_scene* s = mm_render(d)
	mm_scene_free(s)
	mm_document_free(d)
	d = agent_parse(c"agentflow-beta LR\nA --x B\n")
	s = mm_render(d)
	mm_bounds* target = s.nodes[1]
	int crosses = 0
	for mm_primitive* p in s.items:
		if (p.kind != MM_LINE || p.x2 - p.x != 12): continue
		if (p.y2 - p.y == 12 || p.y - p.y2 == 12):
			asserts(c"failure cross is outside target fill", p.x2 < target.x)
			crosses = crosses + 1
	assert_equal(2, crosses)
	mm_scene_free(s)
	mm_document_free(d)
