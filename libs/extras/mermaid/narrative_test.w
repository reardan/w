# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* narrative_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"narrative parses", d.error == 0)
	return d

void narrative_export(mm_document* d, char* expected):
	mm_scene* scene = mm_render(d)
	asserts(c"native scene exists", scene != 0)
	char* svg = mm_svg(scene)
	asserts(c"expected label in SVG", index_of(svg, expected) >= 0)
	char* repeated = mm_svg(scene)
	assert_strings_equal(svg, repeated)
	char* source = mm_write(d)
	assert_strings_equal(d.source, source)
	free(source)
	free(repeated)
	free(svg)
	mm_scene_free(scene)

void test_narrative_sequence_messages_notes_and_fragments():
	mm_document* d = narrative_parse(c"sequenceDiagram\nautonumber\nactor A as Alice\nparticipant B as Backend\nloop retry\nA->>+B: request\nNote over A,B: checking\nalt success\nB-->>-A: result\nelse failure\nB-xA: failed\nend\nend\n")
	assert_equal(MM_SEQUENCE, d.kind)
	assert_equal(2, d.nodes.length)
	mm_node* actor = d.nodes[0]
	assert_equal(1, actor.shape)
	assert_strings_equal(c"Alice", actor.label)
	assert_equal(11, d.narrative.length)
	mm_narrative_event* loop = d.narrative[0]
	assert_equal(10, loop.end)
	mm_narrative_event* message = d.narrative[1]
	assert_equal(0, message.from_node)
	assert_equal(1, message.to_node)
	narrative_export(d, c"1. request")
	mm_document_free(d)

void test_narrative_sequence_arrow_matrix_and_self_message():
	list[char*] arrows = list[char*]{c"->", c"-->", c"->>", c"-->>", c"-x", c"--x", c"-)", c"--)", c"<<->>", c"<<-->>"}
	for char* arrow in arrows:
		string_builder* source = string_from(c"sequenceDiagram\na")
		string_append(source, arrow)
		string_append(source, c"x: hello\nx->>x: self\n")
		mm_document* d = narrative_parse(source.data)
		assert_equal(2, d.nodes.length)
		mm_narrative_event* event = d.narrative[0]
		assert_equal(index_of(arrow, c"--") >= 0, event.dashed)
		narrative_export(d, c"self")
		mm_document_free(d)
		string_free(source)
	__w_list_free(cast(__w_list*, arrows))

void test_narrative_journey_scores_and_actors():
	mm_document* d = narrative_parse(c"journey\ntitle Morning\nsection Home\nWake up: 1: Me\nCoffee: 5: Me, Cat\nsection Work\nCommute: 3: Me\n")
	assert_equal(MM_JOURNEY, d.kind)
	assert_equal(3, d.narrative.length)
	assert_equal(2, d.nodes.length)
	mm_narrative_event* task = d.narrative[1]
	assert_equal(5, task.value)
	assert_strings_equal(c"Me, Cat", task.detail)
	assert_strings_equal(c"Home", task.section)
	mm_scene* scene = mm_render(d)
	int circles = 0
	int low_y = 0
	int high_y = 0
	for mm_primitive* item in scene.items:
		if (item.kind == MM_CIRCLE):
			if (circles == 0): low_y = item.y
			if (circles == 1): high_y = item.y
			circles = circles + 1
	assert_equal(3, circles)
	asserts(c"high scores appear higher", high_y < low_y)
	mm_scene_free(scene)
	narrative_export(d, c"Morning")
	mm_document_free(d)

void test_narrative_timeline_continuations_and_sections():
	mm_document* d = narrative_parse(c"timeline\ntitle Language history\nsection Early\n1970 : C : Unix\n : Portable systems\n1980 : C++\nsection Modern\n2026 : W\n")
	assert_equal(MM_TIMELINE, d.kind)
	assert_equal(8, d.narrative.length)
	mm_scene* scene = mm_render(d)
	assert_equal(3, scene.nodes.length)
	mm_bounds* first = scene.nodes[0]
	mm_bounds* second = scene.nodes[1]
	asserts(c"periods are ordered horizontally", second.x > first.x + first.w)
	mm_scene_free(scene)
	narrative_export(d, c"Portable systems")
	mm_document_free(d)

void test_narrative_gantt_calendar_and_dependencies():
	mm_document* d = narrative_parse(c"gantt\ntitle Release\ndateFormat YYYY-MM-DD\nsection Build\nCompile :done, build, 2024-02-28, 2d\nVerify :active, crit, check, after build, 1w\nShip :milestone, ship, after check, 0d\n")
	assert_equal(MM_GANTT, d.kind)
	assert_equal(3, d.narrative.length)
	mm_narrative_event* build = d.narrative[0]
	mm_narrative_event* check = d.narrative[1]
	mm_narrative_event* ship = d.narrative[2]
	assert_equal(mm_n_date(c"2024-03-01"), build.end)
	assert_equal(build.end, check.start)
	assert_equal(7, check.end - check.start)
	assert_equal(6, check.value)
	assert_equal(check.end, ship.start)
	assert_equal(ship.start, ship.end)
	narrative_export(d, c"Release")
	mm_scene* scene = mm_render(d)
	mm_bounds* a = scene.nodes[0]
	mm_bounds* b = scene.nodes[1]
	assert_equal(a.x + a.w, b.x)
	mm_scene_free(scene)
	mm_document_free(d)

void test_narrative_gantt_dates_validate_and_roundtrip():
	assert_equal(-1, mm_n_date(c"2023-02-29"))
	assert_equal(-1, mm_n_date(c"2024-04-31"))
	assert_equal(-1, mm_n_date(c"2024-00-12"))
	assert_equal(-1, mm_n_date(c"2024-13-01"))
	assert_equal(-1, mm_n_date(c"2024-01-00"))
	assert_equal(-1, mm_n_date(c"1969-12-31"))
	list[char*] dates = list[char*]{c"1970-01-01", c"2000-02-29", c"2100-03-01", c"9999-12-31"}
	for char* date in dates:
		char* result = mm_n_date_text(mm_n_date(date))
		assert_strings_equal(date, result)
		free(result)
	__w_list_free(cast(__w_list*, dates))

void test_narrative_zenuml_nested_calls_and_returns():
	mm_document* d = narrative_parse(c"zenuml\ntitle Calls\n@Actor Client\nService as Backend\nClient->Service: request\nService.handle() {\nRepository.load() {\nreturn item\n}\nwhile(retry) {\nService->Client: update\n}\n}\n")
	assert_equal(MM_ZENUML, d.kind)
	assert_equal(4, d.nodes.length)
	mm_narrative_event* nested = d.narrative[3]
	assert_equal(MM_N_MESSAGE, nested.kind)
	mm_node* sender = d.nodes[nested.from_node]
	mm_node* receiver = d.nodes[nested.to_node]
	assert_strings_equal(c"Service", sender.id)
	assert_strings_equal(c"Repository", receiver.id)
	narrative_export(d, c"load()")
	mm_document_free(d)

void test_narrative_unsupported_and_malformed_diagnostics():
	list[char*] sources = list[char*]{c"sequenceDiagram\nend", c"sequenceDiagram\nactivate A\ndeactivate B", c"sequenceDiagram\nalt x\nA->>B: hi", c"sequenceDiagram\nbox blue\nparticipant A\nend", c"sequenceDiagram\nloop x\nelse y\nend", c"journey\nTask: 6: Me", c"journey\nTask: 0: Me", c"journey\nTask: 3: Me,", c"timeline\n: orphan", c"gantt\ndateFormat DD/MM/YYYY", c"gantt\nA: 2023-02-29, 1d", c"gantt\nA: after missing, 1d", c"gantt\nA: 2024-01-01, 999999999999999999d", c"gantt\nA: a,2024-01-01,1d\nB: a,after a,1d", c"zenuml\nA.call() {", c"zenuml\n}", c"zenuml\nnew A", c"zenuml\nreturn x"}
	for char* source in sources:
		mm_document* d = mm_parse(source, strlen(source))
		asserts(c"unsupported construct diagnosed", d.error != 0)
		asserts(c"invalid scene suppressed", mm_render(d) == 0)
		char* output = mm_write(d)
		assert_strings_equal(source, output)
		free(output)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))

void test_narrative_prefixes_edits_and_scene_ownership():
	list[char*] sources = list[char*]{c"sequenceDiagram\nA->>B: hi\n", c"journey\nWalk: 4: Me\n", c"timeline\n2026: W\n", c"gantt\nBuild: 2024-01-01, 3d\n", c"zenuml\nA.call() {\nB.go()\n}\n"}
	for char* source in sources:
		for length in range(strlen(source) + 1):
			mm_document* d = mm_parse(source, length)
			mm_scene* scene = mm_render(d)
			if (d.error != 0): asserts(c"prefix errors suppress scene", scene == 0)
			mm_document_free(d)
			if (scene != 0):
				char* svg = mm_svg(scene)
				asserts(c"scene survives document", svg != 0)
				free(svg)
			mm_scene_free(scene)
		mm_document* d = narrative_parse(source)
		mm_document* edited = mm_edit(d, 0, 0, c"%% comment\n", 11)
		asserts(c"comment edit remains valid", edited != 0 && edited.error == 0)
		mm_document_free(edited)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))

void test_narrative_zenuml_explicit_sender_and_alternatives():
	mm_document* d = narrative_parse(c"zenuml\n@Actor Client\nClient->Service.checkout() {\nif(ok) {\nService->Client: accepted\n} else {\nService->Client: rejected\n}\nreturn result\n}\n")
	assert_equal(2, d.nodes.length)
	mm_narrative_event* event = d.narrative[0]
	mm_node* sender = d.nodes[event.from_node]
	assert_strings_equal(c"Client", sender.id)
	narrative_export(d, c"else")
	mm_document_free(d)

void test_narrative_limits_and_long_label_geometry():
	string_builder* text = string_from(c"sequenceDiagram\nA->>B: ")
	for i in range(300000): string_append_char(text, 'x')
	string_append_char(text, 10)
	for i in range(1022):
		string_append(text, c"participant actor")
		string_append_int(text, i)
		string_append_char(text, 10)
	mm_document* d = narrative_parse(text.data)
	mm_scene* scene = mm_render(d)
	asserts(c"bounded layout despite long label and many participants", scene.width > 2000000 && scene.width < 4000000)
	mm_scene_free(scene)
	mm_document_free(d)
	string_append(text, c"participant overflow\n")
	d = mm_parse(text.data, text.length)
	asserts(c"participant limit enforced", d.error != 0)
	mm_document_free(d)
	string_free(text)
	text = string_from(c"timeline\n")
	for i in range(1025): string_append(text, c"Period\n")
	d = mm_parse(text.data, text.length)
	asserts(c"event limit enforced", d.error != 0)
	mm_document_free(d)
	string_free(text)

void test_narrative_gantt_sequential_end_date_and_milestone_midpoint():
	mm_document* d = narrative_parse(c"gantt\nA: 2024-01-01, 2d\nB: 2024-01-07\nMiddle: milestone, 2024-01-01, 4d\n")
	mm_narrative_event* first = d.narrative[0]
	mm_narrative_event* next = d.narrative[1]
	assert_equal(first.end, next.start)
	assert_equal(mm_n_date(c"2024-01-07"), next.end)
	mm_scene* scene = mm_render(d)
	mm_bounds* bar = scene.nodes[0]
	mm_bounds* point = scene.nodes[2]
	assert_equal(bar.x + bar.w, point.x)
	mm_scene_free(scene)
	mm_document_free(d)
