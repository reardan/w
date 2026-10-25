# wbuild: x64
# Sequence participant objects, properties/details, central connections,
# entity codes and link menus; ZenUML @return/@Starter, annotator symbols and
# comments (Mermaid 12.2.0).
import lib.testing
import libs.extras.mermaid.io
import libs.extras.mermaid.render

mm_document* seq_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"diagram parses", d.error == 0)
	return d

char* seq_svg(mm_document* d):
	mm_scene* s = mm_render(d)
	asserts(c"diagram renders", s != 0 && s.items.length > 0)
	char* svg = mm_svg(s)
	mm_scene_free(s)
	return svg

void seq_reject(char* source, char* message):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error == 0 || index_of(d.error, message) < 0):
		println2(source)
		if (d.error != 0): println2(d.error)
	asserts(c"diagnostic names the problem", d.error != 0 && index_of(d.error, message) >= 0)
	char* text = mm_write(d)
	assert_strings_equal(source, text)
	free(text)
	mm_document_free(d)

void test_sequence_participant_object_types():
	list[char*] types = list[char*]{c"participant", c"actor", c"boundary", c"control", c"entity", c"database", c"collections", c"queue"}
	for i in range(types.length):
		string_builder* source = string_from(c"sequenceDiagram\n    participant A@{ \"type\" : \"")
		string_append(source, types[i])
		string_append(source, c"\" }\n    participant B\n    A->>B: hi\n")
		mm_document* d = seq_parse(source.data)
		mm_node* a = d.nodes[0]
		assert_equal(i, a.shape)
		assert_strings_equal(c"A", a.id)
		mm_scene* s = mm_render(d)
		int labels = 0
		for mm_primitive* p in s.items:
			if (p.kind == MM_TEXT && strcmp(p.text, c"A") == 0): labels = labels + 1
		assert_equal(1, labels)
		mm_scene_free(s)
		mm_document_free(d)
		string_free(source)
	__w_list_free(cast(__w_list*, types))
	mm_document* d = seq_parse(c"sequenceDiagram\nparticipant API@{ \"type\": \"boundary\", \"alias\": \"Internal\" } as External\nactor DB@{ \"type\": \"database\" } as User DB\nparticipant Q@{ \"type\": \"queue\", \"alias\": \"Jobs\" }\nAPI->>DB: q\n")
	assert_strings_equal(c"External", d.nodes[0].label)
	assert_equal(5, d.nodes[1].shape)
	assert_strings_equal(c"User DB", d.nodes[1].label)
	assert_strings_equal(c"Jobs", d.nodes[2].label)
	mm_document_free(d)
	seq_reject(c"sequenceDiagram\nparticipant A@{ \"type\": \"cloud\" }\n", c"unsupported participant type")
	seq_reject(c"sequenceDiagram\nparticipant A@{ \"color\": \"red\" }\n", c"unsupported participant object key")
	seq_reject(c"sequenceDiagram\nparticipant A@{ \"type\": \"queue\"\n", c"unterminated participant object")
	seq_reject(c"sequenceDiagram\nparticipant A@{ type: queue }\n", c"JSON object of strings")
	seq_reject(c"sequenceDiagram\nparticipant A@{ \"type\": \"queue\" } junk\n", c"expected as or end of participant declaration")

void test_sequence_properties_and_details():
	mm_document* d = seq_parse(c"sequenceDiagram\nparticipant A\nproperties A: {\"class\": \"internal\", \"icon\": \"https://example.com/i.png\"}\ndetails A: actorDetails\nA->>A: self\n")
	mm_node* a = d.nodes[0]
	assert_equal(3, a.members.length)
	mm_member* m = a.members[0]
	assert_strings_equal(c"class: internal", m.text)
	m = a.members[2]
	assert_strings_equal(c"details: actorDetails", m.text)
	assert_equal(1, m.method)
	char* svg = seq_svg(d)
	asserts(c"property icons are never fetched", index_of(svg, c"i.png") < 0)
	free(svg)
	mm_document_free(d)
	seq_reject(c"sequenceDiagram\nproperties Z: {\"a\": \"b\"}\n", c"properties require an existing participant")
	seq_reject(c"sequenceDiagram\nparticipant A\nproperties A: [1]\n", c"participant properties require a JSON object of strings")
	seq_reject(c"sequenceDiagram\nparticipant A\ndetails A:\n", c"participant details require text")

void test_sequence_central_connections():
	mm_document* d = seq_parse(c"sequenceDiagram\nparticipant Alice\nparticipant John\nAlice->>()John: Hello John\nAlice()->>John: How are you?\nJohn()->>()Alice: Great!\n")
	assert_equal(2, d.nodes.length)
	mm_narrative_event* e = d.narrative[0]
	assert_equal(2, e.central)
	e = d.narrative[1]
	assert_equal(1, e.central)
	e = d.narrative[2]
	assert_equal(3, e.central)
	mm_scene* s = mm_render(d)
	int circles = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_CIRCLE): circles = circles + 1
	assert_equal(4, circles)
	mm_scene_free(s)
	mm_document_free(d)

void test_sequence_entity_codes():
	mm_document* d = seq_parse(c"sequenceDiagram\nA->>B: I #9829; you!\nB->>A: I #9829; you #infin; times #59; more #bogus; #0;\nNote over A: #quot;quoted#quot;\n")
	assert_equal(3, d.narrative.length)
	mm_narrative_event* e = d.narrative[0]
	assert_strings_equal(c"I \xe2\x99\xa5 you!", e.label)
	e = d.narrative[1]
	assert_strings_equal(c"I \xe2\x99\xa5 you \xe2\x88\x9e times ; more #bogus; #0;", e.label)
	e = d.narrative[2]
	assert_strings_equal(c"\"quoted\"", e.label)
	char* text = mm_write(d)
	asserts(c"source keeps entity codes", index_of(text, c"#9829;") > 0)
	free(text)
	mm_document_free(d)
	# A plain semicolon still separates statements.
	d = seq_parse(c"sequenceDiagram\nA->>B: one; B->>A: two\n")
	assert_equal(2, d.narrative.length)
	mm_document_free(d)

void test_sequence_link_menus_render_as_svg_links():
	mm_document* d = seq_parse(c"sequenceDiagram\nparticipant Alice\nparticipant John\nlink Alice: Dashboard @ https://dashboard.contoso.com/alice\nlinks John: {\"Wiki\": \"https://wiki.contoso.com/john\", \"Bad\": \"javascript:alert(1)\"}\nAlice->>John: Hello\n")
	char* svg = seq_svg(d)
	asserts(c"menu entry linked", index_of(svg, c"<a href=\"https://dashboard.contoso.com/alice\"><title>https://dashboard.contoso.com/alice</title>") > 0)
	asserts(c"second participant menu", index_of(svg, c"<a href=\"https://wiki.contoso.com/john\">") > 0)
	asserts(c"unsafe menu URL is not a link", index_of(svg, c"href=\"javascript:") < 0)
	asserts(c"unsafe entry still listed", index_of(svg, c">Bad</text>") > 0)
	free(svg)
	mm_document_free(d)

void test_zenuml_return_starter_symbols_and_comments():
	mm_document* d = seq_parse(c"zenuml\n@Starter(Client)\n@Database Repo\n@Control Svc\n// participant comments are dropped\n@Queue Jobs\nnew A1\nnew A2(with, parameters)\n// **Load** the order\nSvc.load() {\nRepo.get()\n// reply early\n@return\nSvc->Client: done\n}\n")
	int client = mm_find_node(d, c"Client")
	int svc = mm_find_node(d, c"Svc")
	assert_equal(-1, mm_find_node(d, c"__external"))
	assert_equal(5, d.nodes[mm_find_node(d, c"Repo")].shape)
	assert_equal(3, d.nodes[svc].shape)
	assert_equal(7, d.nodes[mm_find_node(d, c"Jobs")].shape)
	mm_narrative_event* created = 0
	mm_narrative_event* load = 0
	mm_narrative_event* done = 0
	for mm_narrative_event* e in d.narrative:
		if (e.kind == MM_N_MESSAGE && strcmp(e.label, c"new A1") == 0): created = e
		if (e.kind == MM_N_MESSAGE && strcmp(e.label, c"load()") == 0): load = e
		if (e.kind == MM_N_MESSAGE && strcmp(e.label, c"done") == 0): done = e
	asserts(c"new without arguments", created != 0 && created.from_node == client)
	asserts(c"starter sends top-level calls", load != 0 && load.from_node == client)
	assert_strings_equal(c"**Load** the order", load.detail)
	asserts(c"@return makes a dashed reply", done != 0 && done.dashed == 1)
	assert_strings_equal(c"reply early", done.detail)
	for mm_narrative_event* e in d.narrative:
		asserts(c"declaration comment dropped", index_of(e.detail, c"participant comments") < 0)
	mm_scene* s = mm_render(d)
	int bold = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && strcmp(p.text, c"Load") == 0 && (p.text_style & MM_TEXT_BOLD)): bold = 1
	asserts(c"comment Markdown rendered", bold)
	mm_scene_free(s)
	mm_document_free(d)
	seq_reject(c"zenuml\n@return\nA.b()\n", c"ZenUML @return must precede an async message")
	seq_reject(c"zenuml\nA->B: x\n@reply\n", c"ZenUML @return must precede an async message")
	seq_reject(c"zenuml\n@Starter()\n", c"ZenUML @Starter takes one participant")
	seq_reject(c"zenuml\n@Starter(A)\n@Starter(B)\n", c"ZenUML @Starter takes one participant")
