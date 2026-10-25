# wbuild: x64
# Gantt calendars, ZenUML creation/annotations/try, sequence links and timeline line breaks.
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* followup_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"followup source parses", d.error == 0)
	return d

char* followup_svg(mm_document* d):
	mm_scene* scene = mm_render(d)
	asserts(c"followup scene exists", scene != 0)
	char* svg = mm_svg(scene)
	mm_scene_free(scene)
	char* written = mm_write(d)
	assert_strings_equal(d.source, written)
	free(written)
	return svg

void followup_expect_error(char* source, char* message):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error == 0): println2(source)
	asserts(c"followup diagnostic reported", d.error != 0)
	if (d.error != 0 && strcmp(d.error, message) != 0):
		println2(d.error)
		assert_strings_equal(message, d.error)
	asserts(c"diagnosed source suppresses preview", mm_render(d) == 0)
	char* written = mm_write(d)
	assert_strings_equal(source, written)
	free(written)
	mm_document_free(d)

# Every prefix must parse or diagnose without crashing, and errors suppress the scene.
void followup_prefixes(char* source):
	for length in range(strlen(source) + 1):
		mm_document* d = mm_parse(source, length)
		mm_scene* scene = mm_render(d)
		if (d.error != 0): asserts(c"prefix error suppresses scene", scene == 0)
		mm_document_free(d)
		if (scene != 0):
			char* svg = mm_svg(scene)
			free(svg)
		mm_scene_free(scene)

mm_narrative_event* followup_task(mm_document* d, int index):
	return d.narrative[index]

int followup_count_painted(mm_scene* scene, int kind, int color):
	int count = 0
	for mm_primitive* item in scene.items:
		if (item.kind == kind && (item.style.mask & 2) != 0 && item.style.stroke == color): count = count + 1
	return count

void test_gantt_excludes_weekends_dates_and_includes():
	# 2024-01-05 is a Friday: two working days are Friday and Monday.
	mm_document* d = followup_parse(c"gantt\ndateFormat YYYY-MM-DD\nexcludes weekends\nA: a, 2024-01-05, 2d\nB: b, after a, 1d\nFixed: 2024-01-05, 2024-01-08\n")
	mm_narrative_event* a = followup_task(d, 0)
	mm_narrative_event* b = followup_task(d, 1)
	mm_narrative_event* fixed = followup_task(d, 2)
	assert_equal(mm_n_date(c"2024-01-09"), a.end)
	assert_equal(a.end, b.start)
	assert_equal(mm_n_date(c"2024-01-10"), b.end)
	assert_equal(mm_n_date(c"2024-01-08"), fixed.end)
	mm_scene* scene = mm_render(d)
	int shaded = 0
	for mm_primitive* item in scene.items:
		if (item.kind == MM_BOX && (item.style.mask & 1) != 0 && item.style.fill == 0xe2e8f0): shaded = shaded + 1
	assert_equal(1, shaded)
	mm_scene_free(scene)
	mm_document_free(d)
	d = followup_parse(c"gantt\nexcludes 2024-01-08, 2024-01-08\nA: 2024-01-07, 2d\n")
	a = followup_task(d, 0)
	assert_equal(mm_n_date(c"2024-01-10"), a.end)
	assert_equal(1, d.gantt.excluded.length)
	mm_document_free(d)
	d = followup_parse(c"gantt\nexcludes weekends\nincludes 2024-01-06\nA: 2024-01-05, 2d\n")
	a = followup_task(d, 0)
	assert_equal(mm_n_date(c"2024-01-07"), a.end)
	mm_document_free(d)
	d = followup_parse(c"gantt\nweekend friday\nexcludes Weekends\nA: 2024-01-04, 2d\n")
	a = followup_task(d, 0)
	assert_equal(mm_n_date(c"2024-01-08"), a.end)
	mm_document_free(d)
	d = followup_parse(c"gantt\nexcludes monday\nA: 2024-01-07, 2d\nLong: 2024-01-01, 10w\n")
	a = followup_task(d, 0)
	assert_equal(mm_n_date(c"2024-01-10"), a.end)
	mm_narrative_event* long_task = followup_task(d, 1)
	assert_equal(mm_n_date(c"2024-01-01") + 82, long_task.end)
	mm_document_free(d)
	followup_expect_error(c"gantt\nexcludes sunday monday tuesday wednesday thursday friday saturday\nA: 2024-01-01, 1d", c"Gantt end precedes start or exceeds supported calendar")
	followup_expect_error(c"gantt\nexcludes holidays\nA: 2024-01-01, 1d", c"unsupported Gantt excludes/includes value")
	followup_expect_error(c"gantt\nincludes weekends\nA: 2024-01-01, 1d", c"unsupported Gantt excludes/includes value")
	followup_expect_error(c"gantt\nweekend sunday\nA: 2024-01-01, 1d", c"Gantt weekend must be friday or saturday")

void test_gantt_date_formats_and_minute_units():
	list[char*] sources = list[char*]{c"gantt\ndateFormat DD-MM-YYYY\nA: a, 05-01-2024, 2d\n", c"gantt\ndateFormat YYYY/MM/DD\nA: a, 2024/01/05, 2d\n", c"gantt\ndateFormat MM.DD.YYYY\nA: a, 01.05.2024, 2d\n"}
	for char* source in sources:
		mm_document* d = followup_parse(source)
		mm_narrative_event* a = followup_task(d, 0)
		assert_equal(mm_n_date(c"2024-01-05"), a.start)
		assert_equal(mm_n_date(c"2024-01-07"), a.end)
		char* svg = followup_svg(d)
		asserts(c"default axis labels stay ISO", index_of(svg, c">2024-01-05<") >= 0)
		free(svg)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))
	mm_document* d = followup_parse(c"gantt\ndateFormat YYYY-MM-DD HH:mm\naxisFormat %H:%M\nA: a, 2024-01-01 09:00, 90m\nB: b, after a, 2h\nC: c, after b, 1d\nD: 2024-01-02 08:00, 2024-01-02 12:30\n")
	int base = mm_n_date(c"2024-01-01") * 1440
	mm_narrative_event* a = followup_task(d, 0)
	mm_narrative_event* b = followup_task(d, 1)
	mm_narrative_event* c = followup_task(d, 2)
	mm_narrative_event* last = followup_task(d, 3)
	assert_equal(base + 540, a.start)
	assert_equal(base + 630, a.end)
	assert_equal(base + 750, b.end)
	assert_equal(base + 750 + 1440, c.end)
	assert_equal(base + 1440 + 750, last.end)
	mm_scene* scene = mm_render(d)
	mm_bounds* first = scene.nodes[0]
	mm_bounds* second = scene.nodes[1]
	assert_equal(first.x + first.w, second.x)
	asserts(c"minute charts use a bounded width", scene.width < 1600)
	mm_scene_free(scene)
	char* svg = followup_svg(d)
	asserts(c"hour ticks align to the clock", index_of(svg, c">12:00<") >= 0)
	free(svg)
	mm_document_free(d)
	# Minute charts skip excluded days too: Friday 16:00 plus 10h ends Monday 02:00.
	d = followup_parse(c"gantt\ndateFormat YYYY-MM-DD HH:mm\nexcludes weekends\nA: 2024-01-05 16:00, 10h\n")
	a = followup_task(d, 0)
	assert_equal(mm_n_date(c"2024-01-08") * 1440 + 120, a.end)
	mm_document_free(d)
	followup_expect_error(c"gantt\ndateFormat DD/MMM/YYYY", c"unsupported Gantt dateFormat")
	followup_expect_error(c"gantt\ndateFormat YYYY-MM-DD HH", c"unsupported Gantt dateFormat")
	followup_expect_error(c"gantt\nA: 2024-01-01, 1d\ndateFormat DD-MM-YYYY", c"Gantt dateFormat must precede tasks and dates")
	followup_expect_error(c"gantt\nA: 2024-01-01, 3h", c"Gantt requires end date, until task or positive duration")
	followup_expect_error(c"gantt\ndateFormat DD-MM-YYYY\nA: a, 2024-01-01, 1d", c"Gantt requires a dateFormat start or after dependencies")
	followup_expect_error(c"gantt\ndateFormat DD-MM-YYYY\nA: a, 05-01-2024, 2024-01-06", c"Gantt requires end date, until task or positive duration")
	followup_expect_error(c"gantt\ndateFormat YYYY-MM-DD HH:mm\nA: a, 2024-01-01 24:00, 1h", c"Gantt requires a dateFormat start or after dependencies")
	followup_expect_error(c"gantt\ndateFormat YYYY-MM-DD HH:mm\nA: a, 4001-01-01 10:00, 1h", c"Gantt requires a dateFormat start or after dependencies")

void test_gantt_axis_format_tokens():
	mm_document* d = followup_parse(c"gantt\naxisFormat %d %b\nA: 2024-01-05, 2d\n")
	char* svg = followup_svg(d)
	asserts(c"custom axis format applied", index_of(svg, c">05 Jan<") >= 0)
	free(svg)
	free(d.gantt.axis_format)
	d.gantt.axis_format = strclone(c"%A %e %B %Y (%y) day %j %I%p %%")
	char* label = mm_n_axis_label(d.gantt, mm_n_date(c"2024-02-09"))
	assert_strings_equal(c"Friday  9 February 2024 (24) day 040 12AM %", label)
	free(label)
	mm_document_free(d)
	d = followup_parse(c"gantt\ndateFormat YYYY-MM-DD HH:mm\naxisFormat %a %I:%M %p\nA: 2024-01-05 13:05, 1h\n")
	label = mm_n_axis_label(d.gantt, mm_n_date(c"2024-01-05") * 1440 + 13 * 60 + 5)
	assert_strings_equal(c"Fri 01:05 PM", label)
	free(label)
	mm_document_free(d)
	followup_expect_error(c"gantt\naxisFormat %Q\nA: 2024-01-01, 1d", c"unsupported Gantt axisFormat")
	followup_expect_error(c"gantt\naxisFormat %\nA: 2024-01-01, 1d", c"unsupported Gantt axisFormat")

void test_gantt_today_marker_is_fixed_only():
	list[char*] sources = list[char*]{c"gantt\ntodayMarker 2024-01-06\nA: 2024-01-05, 3d\n", c"gantt\ntodayMarker off\nA: 2024-01-05, 3d\n", c"gantt\ntodayMarker stroke-width:5px,stroke:#0f0\nA: 2024-01-05, 3d\n", c"gantt\ntodayMarker 2030-01-01\nA: 2024-01-05, 3d\n"}
	for i in range(sources.length):
		mm_document* d = followup_parse(sources[i])
		mm_scene* scene = mm_render(d)
		int expected = 0
		if (i == 0): expected = 1
		assert_equal(expected, followup_count_painted(scene, MM_LINE, 0xdc2626))
		if (i == 0):
			mm_bounds* bar = scene.nodes[0]
			for mm_primitive* item in scene.items:
				if (item.kind == MM_LINE && item.style.stroke == 0xdc2626 && (item.style.mask & 2) != 0): assert_equal(bar.x + bar.w / 3, item.x)
		mm_scene_free(scene)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))

void test_gantt_click_links_are_kept():
	mm_document* d = followup_parse(c"gantt\nclick a href \"https://example.com/a?x=1\"\nA: a, 2024-01-01, 1d\nB: b, after a, 1d\nclick b href \"https://example.com/b\"\nclick b href \"https://example.com/c\"\n")
	mm_node* node = d.nodes[mm_find_node(d, c"a")]
	assert_equal(1, node.metadata.length)
	mm_property* link = node.metadata[0]
	assert_strings_equal(c"href", link.key)
	assert_strings_equal(c"https://example.com/a?x=1", link.value)
	node = d.nodes[mm_find_node(d, c"b")]
	assert_equal(1, node.metadata.length)
	link = node.metadata[0]
	assert_strings_equal(c"https://example.com/c", link.value)
	char* svg = followup_svg(d)
	free(svg)
	mm_document_free(d)
	followup_expect_error(c"gantt\nA: a, 2024-01-01, 1d\nclick a call notify()", c"Gantt click callbacks are not supported natively")
	followup_expect_error(c"gantt\nA: a, 2024-01-01, 1d\nclick a href https://x", c"Gantt click requires href and a quoted URL")
	followup_expect_error(c"gantt\nA: a, 2024-01-01, 1d\nclick a", c"Gantt click requires href and a quoted URL")
	followup_expect_error(c"gantt\nA: a, 2024-01-01, 1d\nclick missing href \"u\"", c"Gantt click references unknown task")

void test_gantt_followup_prefixes_and_bounds():
	followup_prefixes(c"gantt\ndateFormat YYYY-MM-DD HH:mm\naxisFormat %H:%M\nexcludes weekends 2024-01-10\nincludes 2024-01-13\ntodayMarker 2024-01-09 10:00\nA: a, 2024-01-08 09:00, 30h\nclick a href \"https://example.com\"\nB: after a, 2d\n")
	# A long chain over a calendar with many exclusions stays fast and bounded.
	string_builder* text = string_from(c"gantt\nexcludes weekends")
	for i in range(1, 29):
		string_append(text, c" 2024-02-")
		if (i < 10): string_append_char(text, '0')
		string_append_int(text, i)
	string_append(text, c"\nT0: t0, 2024-01-01, 300d\n")
	for i in range(1, 300):
		string_append(text, c"T: t")
		string_append_int(text, i)
		string_append(text, c", after t")
		string_append_int(text, i - 1)
		string_append(text, c", 300d\n")
	mm_document* d = followup_parse(text.data)
	mm_narrative_event* last = d.narrative[299]
	asserts(c"long excluded chain resolves", last.end > last.start)
	mm_scene* scene = mm_render(d)
	asserts(c"long chain renders", scene != 0)
	mm_scene_free(scene)
	mm_document_free(d)
	string_free(text)

void test_zenuml_creation_assignment_annotations_and_try():
	mm_document* d = followup_parse(c"zenuml\n@Database Repo\n@Boundary Api as Gateway\n@Actor User\nApi.handle() {\nrepo = new Repo(config)\nOrder result = Repo.save(order)\ntry {\nRepo.flush()\n} catch(error) {\nreturn failed\n} finally {\nApi->Repo: close\n}\n}\n")
	mm_node* repo = d.nodes[mm_find_node(d, c"Repo")]
	mm_node* api = d.nodes[mm_find_node(d, c"Api")]
	mm_node* user = d.nodes[mm_find_node(d, c"User")]
	assert_strings_equal(c"Database", repo.annotation)
	assert_strings_equal(c"Boundary", api.annotation)
	assert_strings_equal(c"Gateway", api.label)
	assert_equal(1, user.shape)
	assert_strings_equal(c"", user.annotation)
	int api_index = mm_find_node(d, c"Api")
	int repo_index = mm_find_node(d, c"Repo")
	# handle, activate, create, new, save, reply, try, flush, catch, return, finally, close, end, deactivate
	assert_equal(14, d.narrative.length)
	mm_narrative_event* created = d.narrative[2]
	assert_equal(MM_N_CREATE, created.kind)
	assert_equal(repo_index, created.from_node)
	assert_equal(3, created.end)
	mm_narrative_event* creation = d.narrative[3]
	assert_strings_equal(c"new Repo(config)", creation.label)
	assert_equal(api_index, creation.from_node)
	assert_equal(repo_index, creation.to_node)
	mm_narrative_event* reply = d.narrative[5]
	assert_strings_equal(c"result", reply.label)
	assert_equal(repo_index, reply.from_node)
	assert_equal(api_index, reply.to_node)
	assert_equal(1, reply.dashed)
	mm_narrative_event* attempt = d.narrative[6]
	assert_equal(MM_N_BLOCK, attempt.kind)
	assert_equal(12, attempt.end)
	mm_narrative_event* branch = d.narrative[8]
	assert_equal(MM_N_BRANCH, branch.kind)
	assert_strings_equal(c"catch(error)", branch.label)
	branch = d.narrative[10]
	assert_strings_equal(c"finally", branch.label)
	char* svg = followup_svg(d)
	asserts(c"Database annotator draws its symbol", repo.shape == 5 && api.shape == 2)
	asserts(c"creation label shown", index_of(svg, c"new Repo(config)") >= 0)
	free(svg)
	mm_scene* scene = mm_render(d)
	mm_bounds* api_box = scene.nodes[api_index]
	mm_bounds* repo_box = scene.nodes[repo_index]
	asserts(c"created participant header starts at its creation", repo_box.y > api_box.y)
	mm_scene_free(scene)
	mm_document_free(d)

void test_zenuml_nested_assignment_reply_and_inline_bodies():
	mm_document* d = followup_parse(c"zenuml\nA.m() { B.n(); C.o() }\nx = A.p() { return y }\nif(ok) { A.go() } else { B.go() }\nD.q() {}\n")
	list[int] kinds = list[int]{MM_N_MESSAGE, MM_N_ACTIVATE, MM_N_MESSAGE, MM_N_MESSAGE, MM_N_DEACTIVATE, MM_N_MESSAGE, MM_N_ACTIVATE, MM_N_MESSAGE, MM_N_MESSAGE, MM_N_DEACTIVATE, MM_N_BLOCK, MM_N_MESSAGE, MM_N_BRANCH, MM_N_MESSAGE, MM_N_END, MM_N_MESSAGE, MM_N_ACTIVATE, MM_N_DEACTIVATE}
	assert_equal(kinds.length, d.narrative.length)
	for i in range(kinds.length):
		mm_narrative_event* event = d.narrative[i]
		assert_equal(kinds[i], event.kind)
	__w_list_free(cast(__w_list*, kinds))
	int a = mm_find_node(d, c"A")
	mm_narrative_event* inner = d.narrative[2]
	assert_equal(a, inner.from_node)
	mm_narrative_event* returned = d.narrative[7]
	assert_strings_equal(c"y", returned.label)
	mm_narrative_event* assigned = d.narrative[8]
	assert_strings_equal(c"x", assigned.label)
	assert_equal(a, assigned.from_node)
	assert_strings_equal(c"__external", d.nodes[assigned.to_node].id)
	char* svg = followup_svg(d)
	free(svg)
	mm_document_free(d)
	# Braces inside quoted arguments and async labels remain text.
	d = followup_parse(c"zenuml\nA.m(\"{\") {\nA->B: map {x}\n}\n")
	assert_equal(4, d.narrative.length)
	mm_narrative_event* label = d.narrative[2]
	assert_strings_equal(c"map {x}", label.label)
	mm_document_free(d)
	followup_expect_error(c"zenuml\n} catch(e) {", c"ZenUML catch/finally requires an open try and brace")
	followup_expect_error(c"zenuml\nif(x) {\n} catch(e) {\n}", c"ZenUML catch/finally requires an open try and brace")
	followup_expect_error(c"zenuml\n@ Foo", c"unsupported ZenUML annotation")
	followup_expect_error(c"zenuml\n@Database", c"unsupported ZenUML annotation")
	followup_expect_error(c"zenuml\nx = 5", c"ZenUML assignment requires a call")
	followup_expect_error(c"zenuml\nx = new A(b", c"ZenUML new requires a participant and balanced arguments")
	followup_expect_error(c"zenuml\nnew A(", c"ZenUML new requires a participant and balanced arguments")
	followup_prefixes(c"zenuml\n@Database Repo\nApi.handle() {\nrepo = new Repo(config) { Repo.init() }\nOrder result = Repo.save(order)\ntry { Repo.flush() } catch(e) { return failed } finally { Api->Repo: close }\n}\n")

void test_sequence_participant_links():
	mm_document* d = followup_parse(c"sequenceDiagram\nparticipant A as Alice\nparticipant B\nlink A: Dashboard @ https://example.com/a\nlinks A: {\"Wiki\": \"https://wiki.example/a\", \"Say \\\"hi\\\"\" : \"mailto:a@example.com\"}\nlinks B: {\"Only\": \"https://b\"}\nA->>B: hi\n")
	mm_node* alice = d.nodes[0]
	assert_equal(3, alice.metadata.length)
	mm_property* link = alice.metadata[0]
	assert_strings_equal(c"Dashboard", link.key)
	assert_strings_equal(c"https://example.com/a", link.value)
	link = alice.metadata[1]
	assert_strings_equal(c"Wiki", link.key)
	link = alice.metadata[2]
	assert_strings_equal(c"Say \"hi\"", link.key)
	assert_strings_equal(c"mailto:a@example.com", link.value)
	mm_node* bob = d.nodes[1]
	assert_equal(1, bob.metadata.length)
	assert_equal(1, d.narrative.length)
	char* svg = followup_svg(d)
	free(svg)
	mm_document_free(d)
	followup_expect_error(c"sequenceDiagram\nlink A: Dash @ https://x", c"link requires an existing participant")
	followup_expect_error(c"sequenceDiagram\nparticipant A\nlink A: Dash https://x", c"participant link requires a label and URL")
	followup_expect_error(c"sequenceDiagram\nparticipant A\nlink A: @ https://x", c"participant link requires a label and URL")
	followup_expect_error(c"sequenceDiagram\nparticipant A\nlink A Dash @ x", c"participant link requires a colon")
	followup_expect_error(c"sequenceDiagram\nparticipant A\nlinks A: {\"Wiki\" \"https://x\"}", c"participant links require a JSON object of strings")
	followup_expect_error(c"sequenceDiagram\nparticipant A\nlinks A: {\"Wiki\": \"https://x\"", c"participant links require a JSON object of strings")
	followup_expect_error(c"sequenceDiagram\nparticipant A\nlinks A: {}", c"participant links require a JSON object of strings")
	followup_expect_error(c"sequenceDiagram\nparticipant A\nlinks A: {\"a\": \"b\"} extra", c"participant links require a JSON object of strings")
	string_builder* many = string_from(c"sequenceDiagram\nparticipant A\n")
	for i in range(65): string_append(many, c"link A: L @ u\n")
	mm_document* limited = mm_parse(many.data, many.length)
	assert_strings_equal(c"participant link limit exceeded", limited.error)
	mm_document_free(limited)
	string_free(many)
	followup_prefixes(c"sequenceDiagram\nparticipant A\nlinks A: {\"Wiki\": \"https://x\", \"B\": \"y\"}\nlink A: Dash @ https://z\nA->>A: hi\n")

void test_timeline_line_breaks():
	mm_document* d = followup_parse(c"timeline\n2024 : First line<br>second line : Other<BR/>x<br />y\n2025<br/>Q1 : Done\n")
	mm_narrative_event* event = d.narrative[1]
	assert_strings_equal(c"First line<br>second line", event.label)
	char* svg = followup_svg(d)
	asserts(c"first line shown", index_of(svg, c">First line</text>") >= 0)
	asserts(c"second line shown", index_of(svg, c">second line</text>") >= 0)
	asserts(c"period line shown", index_of(svg, c">Q1</text>") >= 0)
	asserts(c"no literal break tags", index_of(svg, c"&lt;br") < 0)
	free(svg)
	mm_scene* scene = mm_render(d)
	mm_bounds* first = scene.nodes[0]
	mm_bounds* second = scene.nodes[1]
	assert_equal(first.h, second.h)
	assert_equal(63, first.h)
	int tall = 0
	for mm_primitive* item in scene.items:
		if (item.kind == MM_BOX && item.dashed == 0 && item.y2 - item.y == 81): tall = tall + 1
	assert_equal(1, tall)
	mm_scene_free(scene)
	mm_document_free(d)
	followup_prefixes(c"timeline\n2024 : a<br>b<br/>c : d<BR />e\n")
