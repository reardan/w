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
	list[char*] bad = list[char*]{c"agentflow\nA", c"agentflow-beta\nA@{shape: 5}", c"agentflow-beta\nA@{label: [1,2]}", c"agentflow-beta\nflow A@{view: hidden}\nend", c"agentflow-beta\nflow A@{shape: hexagon}\nend", c"agentflow-beta\nA@{algorithm: {x: 1}}", c"agentflow-beta\nA@{labelType: html}", c"agentflow-beta\nglobal\nA", c"agentflow-beta\nA@{value: [1,2}", c"agentflow-beta\nA@{value: \"open}", c"agentflow-beta\nend", c"agentflow-beta\nA e1@--> B\nB e1@--> C", c"agentflow-beta\nA A@--> B", c"agentflow-beta\nA e1@--> B\ne1@{curve: zigzag}", c"agentflow-beta\nA e1@--> B\ne1@{animation: medium}", c"agentflow-beta\nA e1@--> B\ne1@{animate: yes}"}
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
		string_append(text, c": value")
	string_append(text, c",key0: updated}\n")
	d = agent_parse(text.data)
	n = d.nodes[0]
	assert_equal(64, n.metadata.length)
	property = n.metadata[0]
	assert_strings_equal(c"updated", property.value)
	mm_document_free(d)
	string_append(text, c"A@{extra: overflow}\n")
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

mm_property* agent_property(mm_node* n, char* key):
	for mm_property* property in n.metadata:
		if (strcmp(property.key, key) == 0): return property
	return 0

void test_agentflow_yaml_metadata_values():
	char* text = c"agentflow-beta\nA@{\n  owner: team\n  retries: 3\n  ratio: 0.5\n  enabled: true\n  note: null\n  tags: [a, \"b c\", 2]\n  config:\n    model: small\n    __proto__: bad\n    limits: {tokens: 10, constructor: bad}\n  steps:\n    - one\n    - name: two\n      tool: grep\n  prompt: |\n    line one\n    line two\n  folded: >-\n    joined\n    text\n  # comment\n  quoted: 'it''s'\n}\nB@{ escaped: \"tab\\tend\", empty: [], list: [x, [y]] }\n"
	mm_document* d = agent_parse(text)
	mm_node* n = d.nodes[0]
	assert_equal(11, n.metadata.length)
	mm_property* p = agent_property(n, c"owner")
	assert_strings_equal(c"team", p.value)
	assert_equal(MM_VALUE_STRING, p.type)
	p = agent_property(n, c"retries")
	assert_equal(MM_VALUE_INT, p.type)
	p = agent_property(n, c"ratio")
	assert_equal(MM_VALUE_FLOAT, p.type)
	p = agent_property(n, c"enabled")
	assert_equal(MM_VALUE_BOOL, p.type)
	p = agent_property(n, c"note")
	assert_equal(MM_VALUE_NULL, p.type)
	p = agent_property(n, c"tags")
	assert_equal(MM_VALUE_LIST, p.type)
	assert_strings_equal(c"[\"a\",\"b c\",2]", p.value)
	p = agent_property(n, c"config")
	assert_equal(MM_VALUE_MAP, p.type)
	assert_strings_equal(c"{\"model\":\"small\",\"limits\":{\"tokens\":10}}", p.value)
	p = agent_property(n, c"steps")
	assert_strings_equal(c"[\"one\",{\"name\":\"two\",\"tool\":\"grep\"}]", p.value)
	p = agent_property(n, c"prompt")
	assert_strings_equal(c"line one\nline two\n", p.value)
	p = agent_property(n, c"folded")
	assert_strings_equal(c"joined text", p.value)
	p = agent_property(n, c"quoted")
	assert_strings_equal(c"it's", p.value)
	n = d.nodes[1]
	p = agent_property(n, c"escaped")
	assert_strings_equal(c"tab\tend", p.value)
	p = agent_property(n, c"empty")
	assert_strings_equal(c"[]", p.value)
	p = agent_property(n, c"list")
	assert_strings_equal(c"[\"x\",[\"y\"]]", p.value)
	char* saved = mm_write(d)
	assert_strings_equal(text, saved)
	free(saved)
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"yaml node exported", index_of(svg, c"<svg") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
	# Nesting is bounded.
	string_builder* deep = string_from(c"agentflow-beta\nA@{v: ")
	for i in range(40): string_append_char(deep, '[')
	for i in range(40): string_append_char(deep, ']')
	string_append(deep, c"}\n")
	d = mm_parse(deep.data, deep.length)
	asserts(c"yaml nesting bounded", d.error != 0)
	mm_document_free(d)
	string_free(deep)

void test_agentflow_shape_inventory_and_coercion():
	mm_document* d = agent_parse(c"agentflow-beta\nA@{shape: subroutine}\nB@{shape: lean-right}\nC@{shape: diamond}\nD@{shape: lin-doc}\nE@{shape: hex}\nF@{shape: roundedRect}\nG@{shape: cyl}\nH[[Sub]]\nI{{Act}}\nJ{Choice}\nK(Round)\nflow P@{shape: collapsedGroup, algorithm: elk.layered}\nQ\nend\n")
	list[int] shapes = list[int]{17, 18, 3, 19, 20, 1, 1, 17, 20, 3, 1}
	list[char*] roles = list[char*]{c"tool", c"input", c"decision", c"refdoc", c"action", c"task", c"task", c"tool", c"action", c"decision", c"task"}
	for i in range(shapes.length):
		mm_node* n = d.nodes[i]
		assert_equal(shapes[i], n.shape)
		assert_strings_equal(roles[i], n.role)
	__w_list_free(cast(__w_list*, shapes))
	__w_list_free(cast(__w_list*, roles))
	mm_node* flow = d.nodes[mm_find_node(d, c"P")]
	assert_strings_equal(c"flow", flow.role)
	mm_property* algorithm = agent_property(flow, c"algorithm")
	assert_strings_equal(c"elk.layered", algorithm.value)
	mm_scene* s = mm_render(d)
	asserts(c"inventory renders", s != 0)
	char* svg = mm_svg(s)
	asserts(c"inventory exported", index_of(svg, c">Choice<") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

int agent_diagonal_edges(mm_scene* s):
	int count = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_LINE && p.x != p.x2 && p.y != p.y2 && p.x2 - p.x != 12 && p.x - p.x2 != 12): count = count + 1
	return count

void test_agentflow_edge_ids_metadata_and_curves():
	char* text = c"agentflow-beta LR\nA e1@--> B\nA e2@-.-> C\nA --> D\ne1@{animate: true, animation: fast, curve: step}\ne2@{ curve: linear }\n"
	mm_document* d = agent_parse(text)
	assert_equal(3, d.edges.length)
	mm_edge* e = d.edges[0]
	assert_strings_equal(c"e1", e.id)
	assert_equal(MM_CURVE_STEP, e.curve)
	assert_equal(3, e.metadata.length)
	mm_property* animate = e.metadata[0]
	assert_equal(MM_VALUE_BOOL, animate.type)
	e = d.edges[1]
	assert_equal(1, e.dashed)
	assert_equal(MM_CURVE_LINEAR, e.curve)
	e = d.edges[2]
	assert_equal(0, e.curve)
	char* saved = mm_write(d)
	assert_strings_equal(text, saved)
	free(saved)
	mm_scene* s = mm_render(d)
	int linear = agent_diagonal_edges(s)
	mm_scene_free(s)
	mm_document_free(d)
	d = agent_parse(c"agentflow-beta LR\nA e1@--> B\nA e2@-.-> C\nA --> D\ne1@{curve: step}\ne2@{curve: step}\n")
	s = mm_render(d)
	int step = agent_diagonal_edges(s)
	mm_scene_free(s)
	mm_document_free(d)
	d = agent_parse(c"agentflow-beta LR\nA e1@--> B\nA e2@-.-> C\nA --> D\ne1@{curve: basis}\ne2@{curve: monotoneX}\n")
	e = d.edges[1]
	assert_equal(MM_CURVE_BASIS, e.curve)
	s = mm_render(d)
	int basis = agent_diagonal_edges(s)
	char* svg = mm_svg(s)
	asserts(c"curved edges exported", index_of(svg, c"<line") >= 0 || index_of(svg, c"<path") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
	asserts(c"linear curve draws a diagonal leg", linear > step)
	asserts(c"basis curve draws a smooth bend", basis > linear)

void test_agentflow_collapsed_flows():
	char* text = c"agentflow-beta LR\nflow P[Pipeline]@{view: collapsed}\nA[Alpha] --> B[Beta]\nflow Inner\nX[Hidden]\nend\nend\nC[Gamma] --> A\nB --> D[Delta]\nA --> X\n"
	mm_document* d = agent_parse(text)
	asserts(c"collapsed view detected", mm_agent_has_collapsed(d))
	list[int] slots = new list[int]
	mm_document* view = mm_agent_project(d, slots)
	# P (summary), C, D remain; A, B, Inner, X fold into P.
	assert_equal(3, view.nodes.length)
	mm_node* summary = view.nodes[slots[mm_find_node(d, c"P")]]
	assert_equal(MM_SHAPE_COLLAPSED, summary.shape)
	assert_equal(slots[mm_find_node(d, c"P")], slots[mm_find_node(d, c"X")])
	# C --> A and B --> D cross the boundary; A --> B and A --> X are internal.
	assert_equal(2, view.edges.length)
	__w_list_free(cast(__w_list*, slots))
	mm_document_free(view)
	mm_scene* s = mm_render(d)
	assert_equal(d.nodes.length, s.nodes.length)
	mm_bounds* outer = s.nodes[mm_find_node(d, c"P")]
	mm_bounds* inner = s.nodes[mm_find_node(d, c"A")]
	assert_equal(outer.x, inner.x)
	assert_equal(outer.y, inner.y)
	char* svg = mm_svg(s)
	asserts(c"collapsed summary exported", index_of(svg, c">Pipeline<") >= 0)
	asserts(c"hidden members omitted", index_of(svg, c">Alpha<") < 0 && index_of(svg, c">Hidden<") < 0)
	asserts(c"outside nodes kept", index_of(svg, c">Gamma<") >= 0 && index_of(svg, c">Delta<") >= 0)
	free(svg)
	mm_scene_free(s)
	char* saved = mm_write(d)
	assert_strings_equal(text, saved)
	free(saved)
	mm_document_free(d)
	# Expanded is the default and keeps every member.
	d = agent_parse(c"agentflow-beta\nflow P@{view: expanded}\nA\nend\n")
	asserts(c"expanded view not projected", mm_agent_has_collapsed(d) == 0)
	mm_document_free(d)
