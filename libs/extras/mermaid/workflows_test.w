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
	list[char*] bad = list[char*]{c"swimlane-beta\na --> b", c"swimlane-beta\nsubgraph A\na\nend\nsubgraph B\na\nend", c"swimlane-beta\nsubgraph A\na", c"swimlane-beta\nsubgraph A\nsubgraph B\nend\nend", c"eventmodeling\ntf 1 unknown A", c"eventmodeling\ntf 01 ui A\ntf 1 ui B", c"eventmodeling\ntf 1 ui A ->> 2", c"eventmodeling\ntf 1 evt A [[Data]]", c"eventmodeling\nrf a evt A"}
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
	asserts(c"lane dimensions bounded by content", s.width > 800000 && s.width < 900000 && s.height < 1000)
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
