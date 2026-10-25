# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

void test_workflow_swimlane_rank_and_responsibility():
	list[char*] directions = list[char*]{c"TB", c"TD", c"BT", c"LR", c"RL"}
	for char* direction in directions:
		string_builder* text = string_from(c"swimlane-beta ")
		string_append(text, direction)
		string_append(text, c"\nsubgraph Sales[Sales team]\na([Request])\nc{Done?}\nend\nsubgraph Engineering\nb[Implement]\nend\na --> b --> c\nc -->|Retry| a\n")
		mm_document* d = mm_parse(text.data, text.length)
		asserts(c"swimlane parses", d.error == 0)
		assert_equal(3, d.edges.length)
		mm_scene* s = mm_render(d)
		mm_bounds* lane = s.nodes[0]
		mm_bounds* a = s.nodes[1]
		mm_bounds* b = s.nodes[4]
		asserts(c"step inside responsibility lane", a.x > lane.x && a.x + a.w < lane.x + lane.w && a.y > lane.y && a.y + a.h < lane.y + lane.h)
		asserts(c"handoff uses separate lane", a.x != b.x || a.y != b.y)
		mm_scene_free(s)
		mm_document_free(d)
		string_free(text)
	__w_list_free(cast(__w_list*, directions))

void test_workflow_event_frames_namespaces_and_explicit_inputs():
	char* text = c"eventmodeling\ntf 01 ui CartUI\ntimeframe 02 command AddItem { description: string }\ntf 03 evt Cart.ItemAdded\nrf 04 event External.StockChanged\ntf 05 readmodel Cart.Items ->> 03\n"
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"event modeling parses", d.error == 0)
	int frames = 0
	int lanes = 0
	for mm_node* n in d.nodes:
		if (n.group): lanes = lanes + 1
		else: frames = frames + 1
	assert_equal(5, frames)
	assert_equal(5, lanes)
	assert_equal(4, d.edges.length)
	int second = mm_find_node(d, c"2")
	mm_node* frame = d.nodes[second]
	assert_equal(1, frame.members.length)
	int fourth = mm_find_node(d, c"4")
	int fifth = mm_find_node(d, c"5")
	int incoming_reset = 0
	for mm_edge* e in d.edges:
		if (e.to_node == fourth): incoming_reset = incoming_reset + 1
	assert_equal(0, incoming_reset)
	mm_scene* s = mm_render(d)
	mm_bounds* first_box = s.nodes[0]
	mm_bounds* last_box = s.nodes[fifth]
	asserts(c"timeframe order drives timeline", last_box.x > first_box.x)
	char* svg = mm_svg(s)
	asserts(c"inline data visible", index_of(svg, c"description: string") >= 0)
	asserts(c"namespace lane visible", index_of(svg, c"External / Events") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_workflow_invalid_and_truncated_inputs():
	list[char*] bad = list[char*]{c"swimlane-beta\na --> b", c"swimlane-beta\nsubgraph A\na\nend\nsubgraph B\na\nend", c"swimlane-beta\nsubgraph A\na", c"swimlane-beta\nsubgraph A\nsubgraph A\na\nend\nend", c"swimlane-beta\nsubgraph A\na@{shape: nope}\nend", c"swimlane-beta\nsubgraph A\na <--- b\nend", c"eventmodeling\ntf 1 unknown A", c"eventmodeling\ntf 01 ui A\ntf 1 ui B", c"eventmodeling\ntf 1 ui A ->> 2", c"eventmodeling\ntf 1 evt A [[Data]]", c"eventmodeling\nrf a evt A"}
	for char* text in bad:
		mm_document* d = mm_parse(text, strlen(text))
		asserts(c"invalid workflow rejected", d.error != 0)
		asserts(c"invalid workflow no preview", mm_render(d) == 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))
	list[char*] samples = list[char*]{c"swimlane-beta LR\nsubgraph G[Group]\na((Start))\nb{End?}\nend\na -->|Next| b\n", c"eventmodeling\ntf 01 ui A\ntf 02 cmd B { name: string }\nrf 03 evt E ->> 02\n"}
	for char* text in samples:
		for length in range(strlen(text) + 1):
			mm_document* d = mm_parse(text, length)
			mm_scene* s = mm_render(d)
			asserts(c"prefix parse/render consistent", (d.error == 0 && s != 0) || (d.error != 0 && s == 0))
			mm_scene_free(s)
			mm_document_free(d)
	__w_list_free(cast(__w_list*, samples))

void test_workflow_large_label_layout_bound():
	string_builder* source = string_from(c"swimlane-beta LR\nsubgraph G\na[\"")
	for i in range(100000): string_append_char(source, 'X')
	string_append(source, c"\"]\nend\nsubgraph H\nb[Small]\nend\na --> b\n")
	mm_document* d = mm_parse(source.data, source.length)
	asserts(c"large lane label parses", d.error == 0)
	mm_scene* s = mm_render(d)
	# Text extents use the 11px advance of X (text_metrics.w).
	asserts(c"lane dimensions bounded by content", s.width > 800000 && s.width < 1200000 && s.height < 1000)
	mm_scene_free(s)
	mm_document_free(d)
	string_free(source)

void test_workflow_cycle_does_not_pull_downstream_step_before_loop():
	char* text = c"swimlane-beta LR\nsubgraph Customer\nrequest\nreceive\nend\nsubgraph Engineering\nwork\ncheck\nend\nrequest --> work --> check\ncheck --> receive\ncheck --> work\n"
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"looping process parses", d.error == 0)
	mm_scene* s = mm_render(d)
	int check_index = mm_find_node(d, c"check")
	int receive_index = mm_find_node(d, c"receive")
	mm_bounds* check = s.nodes[check_index]
	mm_bounds* receive = s.nodes[receive_index]
	asserts(c"downstream step placed after process loop", receive.rank > check.rank && receive.x > check.x)
	mm_scene_free(s)
	mm_document_free(d)

int workflow_inside(mm_bounds* inner, mm_bounds* outer):
	return inner.x > outer.x && inner.y > outer.y && inner.x + inner.w < outer.x + outer.w && inner.y + inner.h < outer.y + outer.h

void test_workflow_swimlane_nested_lanes_shapes_and_links():
	char* text = c"swimlane-beta LR\nsubgraph ops [Operations]\nintake([Receive request])\nsubgraph triage [Triage desk]\nclassify{Known issue?}\nlog[(Ticket store)]\nend\nreply>Reply sent]\nend\nsubgraph eng [Engineering]\nsubgraph squad [Platform squad]\nfix[[Patch service]]\ndeploy{{Deploy}}\nhold(((Hold)))\nend\nverify@{ shape: docs, label: \"Release notes\" }\nend\nintake ==> classify\nclassify -->|Yes| reply\nclassify -- needs code --> fix\nclassify -.-> log\nfix --> deploy --> verify\nverify --o reply\ndeploy --x fix\nhold & fix <--> deploy\nclassDef hot fill:#fee2e2,stroke:#dc2626;\nclass deploy hot\nlinkStyle 0 stroke:#2563eb\n"
	mm_document* d = mm_parse(text, strlen(text))
	if (d.error != 0): println2(d.error)
	asserts(c"nested swimlane parses", d.error == 0)
	int ops = mm_find_node(d, c"ops")
	int triage = mm_find_node(d, c"triage")
	int squad = mm_find_node(d, c"squad")
	int eng = mm_find_node(d, c"eng")
	mm_node* n = d.nodes[triage]
	assert_equal(ops, n.parent)
	assert_strings_equal(c"Triage desk", n.label)
	n = d.nodes[squad]
	assert_equal(eng, n.parent)
	n = d.nodes[mm_find_node(d, c"classify")]
	assert_equal(triage, n.parent)
	assert_equal(3, n.shape)
	n = d.nodes[mm_find_node(d, c"intake")]
	assert_equal(MM_SHAPE_STADIUM, n.shape)
	n = d.nodes[mm_find_node(d, c"log")]
	assert_equal(MM_SHAPE_CYLINDER, n.shape)
	n = d.nodes[mm_find_node(d, c"reply")]
	assert_equal(MM_SHAPE_ODD, n.shape)
	n = d.nodes[mm_find_node(d, c"fix")]
	assert_equal(squad, n.parent)
	assert_equal(MM_SHAPE_FRAMED, n.shape)
	n = d.nodes[mm_find_node(d, c"deploy")]
	assert_equal(MM_SHAPE_HEXAGON, n.shape)
	n = d.nodes[mm_find_node(d, c"hold")]
	assert_equal(MM_SHAPE_DOUBLE_CIRCLE, n.shape)
	n = d.nodes[mm_find_node(d, c"verify")]
	assert_equal(MM_SHAPE_DOCUMENTS, n.shape)
	assert_strings_equal(c"Release notes", n.label)
	assert_equal(eng, n.parent)
	assert_equal(10, d.edges.length)
	mm_edge* e = d.edges[0]
	assert_equal(4, e.style.width)
	e = d.edges[2]
	assert_strings_equal(c"needs code", e.label)
	e = d.edges[3]
	assert_equal(1, e.dashed)
	e = d.edges[6]
	assert_equal(8, e.right_marker)
	e = d.edges[7]
	assert_equal(6, e.right_marker)
	e = d.edges[9]
	assert_equal(1, e.left_marker)
	char* saved = mm_write(d)
	assert_strings_equal(text, saved)
	free(saved)
	mm_scene* s = mm_render(d)
	asserts(c"inner lane inside outer lane", workflow_inside(s.nodes[triage], s.nodes[ops]))
	asserts(c"step inside nested lane", workflow_inside(s.nodes[mm_find_node(d, c"classify")], s.nodes[triage]))
	asserts(c"nested lane inside engineering", workflow_inside(s.nodes[squad], s.nodes[eng]))
	asserts(c"lane-level step outside nested lane", workflow_inside(s.nodes[mm_find_node(d, c"verify")], s.nodes[squad]) == 0)
	int polygons = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_POLYGON): polygons = polygons + 1
	asserts(c"catalogue shapes drawn as outlines", polygons >= 4)
	char* svg = mm_svg(s)
	asserts(c"nested lane title exported", index_of(svg, c">Platform squad<") >= 0)
	asserts(c"classDef fill exported", index_of(svg, c"#fee2e2") >= 0)
	asserts(c"linkStyle exported", index_of(svg, c"#2563eb") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
	# Nesting depth is bounded.
	string_builder* deep = string_from(c"swimlane-beta\n")
	for i in range(40):
		string_append(deep, c"subgraph L")
		string_append_int(deep, i)
		string_append_char(deep, 10)
	string_append(deep, c"a\n")
	for i in range(40): string_append(deep, c"end\n")
	d = mm_parse(deep.data, deep.length)
	asserts(c"swimlane nesting bounded", d.error != 0)
	mm_document_free(d)
	string_free(deep)

int workflow_side_count(mm_document* d, int side):
	int count = 0
	for mm_note* note in d.notes:
		if (note.side == side): count = count + 1
	return count

void test_workflow_event_data_blocks_and_annotations():
	char* text = c"eventmodeling\ntitle Cart\n/* block\ncomment */\n// line comment\nentity Cart.Item\ntf 01 ui CartUI\ntf 02 cmd AddItem [[AddItem01]]\ntf 03 evt ItemAdded [[ItemAdded]] `json`\ntf 004 rmo Cart.Items `jsobj` { items: [{ id: 1 }], total: { amount: 2 } }\nrf 05 evt Reset \"quoted payload\"\n\ndata AddItem01 `json` {\n  description: 'john'\n  nested:\n    price: 20.4\n}\n\ndata ItemAdded {\n  description: string\n}\nnote 02 {\n  Validates stock\n}\ngwt 03 given evt ItemAdded when cmd AddItem then evt ItemAdded\n"
	mm_document* d = mm_parse(text, strlen(text))
	if (d.error != 0): println2(d.error)
	asserts(c"event data blocks parse", d.error == 0)
	assert_strings_equal(c"Cart", d.title)
	mm_node* n = d.nodes[mm_find_node(d, c"2")]
	assert_equal(3, n.members.length)
	mm_member* m = n.members[2]
	assert_strings_equal(c"price: 20.4", m.text)
	mm_property* reference = mm_agent_get(n.metadata, c"dataReference")
	assert_strings_equal(c"AddItem01", reference.value)
	mm_property* type = mm_agent_get(n.metadata, c"dataType")
	assert_strings_equal(c"json", type.value)
	n = d.nodes[mm_find_node(d, c"3")]
	type = mm_agent_get(n.metadata, c"dataType")
	assert_strings_equal(c"json", type.value)
	assert_equal(1, n.members.length)
	n = d.nodes[mm_find_node(d, c"4")]
	m = n.members[0]
	assert_strings_equal(c"items: [{ id: 1 }], total: { amount: 2 }", m.text)
	n = d.nodes[mm_find_node(d, c"5")]
	m = n.members[0]
	assert_strings_equal(c"quoted payload", m.text)
	assert_equal(1, workflow_side_count(d, MM_EM_ENTITY))
	assert_equal(2, workflow_side_count(d, MM_EM_DATA))
	assert_equal(1, workflow_side_count(d, MM_EM_NOTE))
	assert_equal(1, workflow_side_count(d, MM_EM_GWT))
	char* saved = mm_write(d)
	assert_strings_equal(text, saved)
	free(saved)
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"typed heading exported", index_of(svg, c">cmd [json]<") >= 0)
	asserts(c"external data exported", index_of(svg, c"price: 20.4") >= 0)
	asserts(c"note exported", index_of(svg, c"Validates stock") >= 0)
	asserts(c"gwt exported", index_of(svg, c"given:") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
	for length in range(strlen(text) + 1):
		d = mm_parse(text, length)
		s = mm_render(d)
		asserts(c"event prefix parse/render consistent", (d.error == 0 && s != 0) || (d.error != 0 && s == 0))
		mm_scene_free(s)
		mm_document_free(d)
	list[char*] bad = list[char*]{c"eventmodeling\ntf 0001 ui A", c"eventmodeling\ndata X {\na", c"eventmodeling\ndata X `xml` {\na\n}", c"eventmodeling\ndata X { a }", c"eventmodeling\ndata X {\na\n}\ndata X {\nb\n}", c"eventmodeling\nnote 09 {\nx\n}", c"eventmodeling\ntf 01 ui A\ngwt 01 given evt A", c"eventmodeling\ntf 01 ui A\ngwt 01 when cmd B then evt C", c"eventmodeling\n/* open", c"eventmodeling\ntf 01 ui A { open"}
	for char* source in bad:
		d = mm_parse(source, strlen(source))
		asserts(c"invalid event model rejected", d.error != 0)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, bad))

void test_workflow_shape_catalogue():
	list[char*] names = list[char*]{c"cyl", c"dbl-circ", c"doc", c"lin-doc", c"docs", c"st-rect", c"notch-rect", c"lin-rect", c"sm-circ", c"fr-circ", c"fork", c"hourglass", c"brace", c"brace-r", c"braces", c"bolt", c"delay", c"h-cyl", c"lin-cyl", c"curv-trap", c"div-rect", c"tri", c"win-pane", c"f-circ", c"notch-pent", c"flip-tri", c"sl-rect", c"bow-rect", c"cross-circ", c"tag-doc", c"tag-rect", c"flag", c"odd", c"text", c"cloud", c"bang", c"folder", c"datastore", c"console", c"browser", c"person", c"bucket", c"database", c"stadium", c"hex", c"rounded", c"rect", c"circle", c"diamond", c"lean-r", c"trap-b"}
	string_builder* text = string_from(c"swimlane-beta TB\nsubgraph L [Catalogue]\n")
	for i in range(names.length):
		asserts(c"shape name known", mm_shape_lookup(names[i]) >= 0)
		string_append(text, c"n")
		string_append_int(text, i)
		string_append(text, c"@{ shape: ")
		string_append(text, names[i])
		string_append(text, c", label: \"")
		string_append(text, names[i])
		string_append(text, c"\" }\n")
	string_append(text, c"end\n")
	asserts(c"unknown shape name", mm_shape_lookup(c"no-such-shape") < 0)
	mm_document* d = mm_parse(text.data, text.length)
	if (d.error != 0): println2(d.error)
	asserts(c"catalogue parses", d.error == 0)
	for i in range(names.length):
		mm_node* n = d.nodes[i + 1]
		assert_equal(mm_shape_lookup(names[i]), n.shape)
	mm_scene* s = mm_render(d)
	for i in range(names.length):
		mm_bounds* b = s.nodes[i + 1]
		asserts(c"catalogue shape has extent", b.w > 0 && b.h > 0)
		asserts(c"catalogue shape inside lane", workflow_inside(b, s.nodes[0]))
	char* svg = mm_svg(s)
	asserts(c"catalogue exported", index_of(svg, c">datastore<") >= 0 && index_of(svg, c"<polygon") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
	string_free(text)
	__w_list_free(cast(__w_list*, names))

# Link segments (axis-aligned lines longer than any marker stroke) that
# enter a step box's interior; the stress fixtures use plain rectangles,
# whose outlines are boxes, so every such line is a link segment.
int workflow_link_hits(mm_document* d, mm_scene* s):
	int hits = 0
	for mm_primitive* p in s.items:
		if (p.kind != MM_LINE || (p.x != p.x2 && p.y != p.y2)): continue
		int x0 = p.x
		int x1 = p.x2
		if (x1 < x0):
			x0 = p.x2
			x1 = p.x
		int y0 = p.y
		int y1 = p.y2
		if (y1 < y0):
			y0 = p.y2
			y1 = p.y
		if (x1 - x0 + y1 - y0 < 16): continue
		for i in range(d.nodes.length):
			mm_node* n = d.nodes[i]
			if (n.group): continue
			mm_bounds* b = s.nodes[i]
			if (x0 < b.x + b.w - 2 && x1 > b.x + 2 && y0 < b.y + b.h - 2 && y1 > b.y + 2): hits = hits + 1
	return hits

int workflow_is_label(list[char*] labels, char* text):
	for char* label in labels:
		if (strcmp(label, text) == 0): return 1
	return 0

# Labels that overlap a step box or another label.
int workflow_label_hits(mm_document* d, mm_scene* s, list[char*] labels):
	int hits = 0
	for i in range(s.items.length):
		mm_primitive* p = s.items[i]
		if (p.kind != MM_TEXT || workflow_is_label(labels, p.text) == 0): continue
		int x1 = p.x + mm_text_width(p.text, 0)
		int y1 = p.y + MM_TEXT_LINE
		for k in range(d.nodes.length):
			mm_node* n = d.nodes[k]
			mm_bounds* b = s.nodes[k]
			if (n.group == 0 && p.x < b.x + b.w && x1 > b.x && p.y < b.y + b.h && y1 > b.y): hits = hits + 1
		for j in range(i + 1, s.items.length):
			mm_primitive* q = s.items[j]
			if (q.kind != MM_TEXT || workflow_is_label(labels, q.text) == 0): continue
			if (p.x < q.x + mm_text_width(q.text, 0) && x1 > q.x && p.y < q.y + MM_TEXT_LINE && y1 > q.y): hits = hits + 1
	return hits

void test_workflow_cross_lane_routing_avoids_steps():
	# Rank-skipping, backward and cross-lane handoffs over three lanes: the
	# former midpoint elbows ran through a2/a3 and b1; routed links use the
	# inter-column channels and clear tracks, in every direction.
	char* body = c"\nsubgraph A\na1\na2\na3\nend\nsubgraph B\nb1\nb2\nend\nsubgraph C\nc1\nend\na1 --> a2 --> a3 --> c1\na1 -->|first| b1 --> b2\na1 -->|skip| c1\nb2 -->|back| a1\nc1 -->|handoff| b1\na2 -->|across| b2\n"
	list[char*] directions = list[char*]{c"LR", c"TB", c"RL", c"BT"}
	list[char*] labels = list[char*]{c"first", c"skip", c"back", c"handoff", c"across"}
	for char* direction in directions:
		string_builder* text = string_from(c"swimlane-beta ")
		string_append(text, direction)
		string_append(text, body)
		mm_document* d = mm_parse(text.data, text.length)
		asserts(c"routing fixture parses", d.error == 0)
		mm_scene* s = mm_render(d)
		assert_equal(0, workflow_link_hits(d, s))
		assert_equal(0, workflow_label_hits(d, s, labels))
		char* first = mm_svg(s)
		mm_scene* again = mm_render(d)
		char* second = mm_svg(again)
		assert_strings_equal(first, second)
		free(first)
		free(second)
		mm_scene_free(again)
		mm_scene_free(s)
		mm_document_free(d)
		string_free(text)
	__w_list_free(cast(__w_list*, directions))
	__w_list_free(cast(__w_list*, labels))
