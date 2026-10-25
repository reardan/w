# wbuild: x64
# Issue #820: Gantt timezones, calendar units, dateFormat/axisFormat tokens,
# vert markers, tickInterval/weekday, compact mode; journey faces and
# avatars; timeline TD layout and multicolour sections.
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* gaps_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0):
		println2(source)
		println2(d.error)
	asserts(c"gap source parses", d.error == 0)
	return d

# Renders, exports SVG and checks the lossless write path.
char* gaps_svg(mm_document* d):
	mm_scene* scene = mm_render(d)
	asserts(c"gap scene exists", scene != 0)
	char* svg = mm_svg(scene)
	mm_scene_free(scene)
	char* written = mm_write(d)
	assert_strings_equal(d.source, written)
	free(written)
	return svg

void gaps_error(char* source, char* message):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error == 0): println2(source)
	asserts(c"gap diagnostic reported", d.error != 0)
	if (d.error != 0 && strcmp(d.error, message) != 0): assert_strings_equal(message, d.error)
	asserts(c"diagnosed source suppresses preview", mm_render(d) == 0)
	mm_document_free(d)

void gaps_prefixes(char* source):
	for length in range(strlen(source) + 1):
		mm_document* d = mm_parse(source, length)
		mm_scene* scene = mm_render(d)
		if (d.error != 0): asserts(c"prefix error suppresses scene", scene == 0)
		if (scene != 0):
			char* svg = mm_svg(scene)
			free(svg)
		mm_scene_free(scene)
		mm_document_free(d)

mm_narrative_event* gaps_task(mm_document* d, int index):
	return d.narrative[index]

char* gaps_label(mm_document* d, int value):
	return mm_n_axis_label(d.gantt, value)

void gaps_label_is(mm_document* d, int value, char* expected):
	char* label = gaps_label(d, value)
	assert_strings_equal(expected, label)
	free(label)

void test_gantt_timezone_offsets_normalize_to_utc():
	mm_document* d = gaps_parse(c"gantt\ndateFormat YYYY-MM-DDTHH:mmZ\naxisFormat %H:%M %Z\nA: a, 2024-01-01T10:00+02:00, 1h\nB: b, 2024-01-01T10:00Z, 1h\nC: c, 2024-01-01T10:00-0130, 30m\n")
	int base = mm_n_date(c"2024-01-01") * 1440
	assert_equal(1, d.gantt.minutes)
	assert_equal(base + 480, gaps_task(d, 0).start)
	assert_equal(base + 600, gaps_task(d, 1).start)
	assert_equal(base + 690, gaps_task(d, 2).start)
	gaps_label_is(d, base + 480, c"08:00 +0000")
	char* svg = gaps_svg(d)
	asserts(c"UTC axis labels exported", index_of(svg, c"+0000") >= 0)
	free(svg)
	mm_document_free(d)
	gaps_error(c"gantt\ndateFormat YYYY-MM-DDTHH:mmZ\nA: a, 2024-01-01T10:00+25:00, 1h", c"Gantt requires a dateFormat start or after dependencies")

void test_gantt_month_year_and_fractional_durations():
	mm_document* d = gaps_parse(c"gantt\nA: a, 2024-01-31, 1M\nB: b, 2024-01-01, 1y\nC: c, 2023-02-28, 0.5y\nD: d, after a, 2w\n")
	assert_equal(mm_n_date(c"2024-02-29"), gaps_task(d, 0).end)
	assert_equal(mm_n_date(c"2025-01-01"), gaps_task(d, 1).end)
	assert_equal(mm_n_date(c"2023-08-28"), gaps_task(d, 2).end)
	assert_equal(mm_n_date(c"2024-03-14"), gaps_task(d, 3).end)
	char* svg = gaps_svg(d)
	free(svg)
	mm_document_free(d)
	# Sub-day durations switch a day chart to minutes; labels keep the day default.
	d = gaps_parse(c"gantt\nA: a, 2024-01-01, 20h\nB: b, after a, 1.5d\nC: c, after b, 90s\nD: d, after c, 1500ms\n")
	int base = mm_n_date(c"2024-01-01") * 1440
	assert_equal(1, d.gantt.minutes)
	assert_equal(1, d.gantt.promoted)
	assert_equal(base + 1200, gaps_task(d, 0).end)
	assert_equal(base + 1200 + 2160, gaps_task(d, 1).end)
	assert_equal(base + 3360 + 2, gaps_task(d, 2).end)
	assert_equal(base + 3362 + 1, gaps_task(d, 3).end)
	gaps_label_is(d, base + 1200, c"2024-01-01")
	svg = gaps_svg(d)
	asserts(c"promoted chart keeps ISO day labels", index_of(svg, c">2024-01-01<") >= 0)
	free(svg)
	mm_document_free(d)
	gaps_error(c"gantt\nA: 2024-01-01, 1.5M", c"Gantt requires end date, until task or positive duration")
	gaps_error(c"gantt\nA: 2024-01-01, 0d", c"Gantt requires end date, until task or positive duration")

void test_gantt_moment_tokens():
	list[char*] sources = list[char*]{c"gantt\ndateFormat DD MMM YYYY\nA: a, 05 Jan 2024, 1d\n", c"gantt\ndateFormat Do MMMM YYYY\nA: a, 5th January 2024, 1d\n", c"gantt\ndateFormat YY-M-D\nA: a, 24-1-5, 1d\n", c"gantt\ndateFormat DDDD YYYY\nA: a, 005 2024, 1d\n", c"gantt\ndateFormat [Day] D MMMM YYYY\nA: a, Day 5 january 2024, 1d\n", c"gantt\ndateFormat ddd DD/MM/YYYY\nA: a, Fri 05/01/2024, 1d\n"}
	for char* source in sources:
		mm_document* d = gaps_parse(source)
		assert_equal(mm_n_date(c"2024-01-05"), gaps_task(d, 0).start)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))
	# Date-less formats anchor at 1970-01-01; 12-hour clocks read AM/PM.
	mm_document* d = gaps_parse(c"gantt\ndateFormat h:mm A\nA: a, 1:05 PM, 10m\nB: b, 12:30 am, 5m\n")
	assert_equal(13 * 60 + 5, gaps_task(d, 0).start)
	assert_equal(30, gaps_task(d, 1).start)
	mm_document_free(d)
	d = gaps_parse(c"gantt\ndateFormat Q YYYY\nA: a, 3 2024, 1d\n")
	assert_equal(mm_n_date(c"2024-07-01"), gaps_task(d, 0).start)
	mm_document_free(d)
	# Unix seconds and milliseconds select second units.
	d = gaps_parse(c"gantt\ndateFormat X\naxisFormat %s\nA: a, 0, 71\nB: b, 1704067200, 1704067260\n")
	assert_equal(2, d.gantt.minutes)
	assert_equal(71, gaps_task(d, 0).end)
	assert_equal(1704067200, gaps_task(d, 1).start)
	gaps_label_is(d, 1704067200, c"1704067200")
	char* svg = gaps_svg(d)
	free(svg)
	mm_document_free(d)
	d = gaps_parse(c"gantt\ndateFormat x\nA: a, 1704067200500, 2s\n")
	assert_equal(1704067200, gaps_task(d, 0).start)
	assert_equal(1704067202, gaps_task(d, 0).end)
	mm_document_free(d)
	d = gaps_parse(c"gantt\ndateFormat YYYY-MM-DD HH:mm:ss\nA: a, 2024-01-01 00:00:30, 45s\n")
	assert_equal(mm_n_date(c"2024-01-01") * 86400 + 30, gaps_task(d, 0).start)
	assert_equal(mm_n_date(c"2024-01-01") * 86400 + 75, gaps_task(d, 0).end)
	mm_document_free(d)
	gaps_error(c"gantt\ndateFormat YYYY-MM-DD gggg", c"unsupported Gantt dateFormat")
	gaps_error(c"gantt\ndateFormat YYYY [unterminated", c"unsupported Gantt dateFormat")
	gaps_error(c"gantt\ndateFormat X\nA: a, 99999999999, 1s", c"Gantt requires a dateFormat start or after dependencies")
	gaps_error(c"gantt\ndateFormat YYYY-MM-DD HH:mm:ss\nA: a, 2038-01-01 00:00:00, 1s", c"Gantt requires a dateFormat start or after dependencies")

void test_gantt_axis_format_directives():
	mm_document* d = gaps_parse(c"gantt\ndateFormat YYYY-MM-DD HH:mm\nA: 2024-01-05 13:05, 1h\n")
	int value = mm_n_date(c"2024-01-05") * 1440 + 13 * 60 + 5
	free(d.gantt.axis_format)
	d.gantt.axis_format = strclone(c"%-d/%-m %_H|%S %L %w %u q%q W%U/%W V%V %G")
	gaps_label_is(d, value, c"5/1 13|00 000 5 5 q1 W00/01 V01 2024")
	free(d.gantt.axis_format)
	d.gantt.axis_format = strclone(c"%c|%x|%X|%s")
	gaps_label_is(d, value, c"1/5/2024, 1:05:00 PM|1/5/2024|1:05:00 PM|1704459900")
	mm_document_free(d)
	# ISO weeks: 2021-01-03 is in week 53 of 2020, 2024-12-30 in week 1 of 2025.
	d = gaps_parse(c"gantt\naxisFormat %V %G\nA: 2024-01-01, 1d\n")
	gaps_label_is(d, mm_n_date(c"2021-01-03"), c"53 2020")
	gaps_label_is(d, mm_n_date(c"2024-12-30"), c"01 2025")
	mm_document_free(d)
	gaps_error(c"gantt\naxisFormat %K\nA: 2024-01-01, 1d", c"unsupported Gantt axisFormat")

void test_gantt_until_multiple_and_inclusive_end_dates():
	mm_document* d = gaps_parse(c"gantt\napple :a, 2017-07-20, 1w\nbanana :crit, b, 2017-07-23, 1d\ncherry :active, c, after b a, 1d\nkiwi :d, 2017-07-20, until b c\n")
	assert_equal(mm_n_date(c"2017-07-23"), gaps_task(d, 3).end)
	assert_equal(mm_n_date(c"2017-07-27"), gaps_task(d, 2).start)
	mm_document_free(d)
	d = gaps_parse(c"gantt\ninclusiveEndDates\nA: a, 2024-01-01, 2024-01-03\nB: after a, 1d\n")
	assert_equal(mm_n_date(c"2024-01-04"), gaps_task(d, 0).end)
	assert_equal(mm_n_date(c"2024-01-05"), gaps_task(d, 1).end)
	mm_document_free(d)
	gaps_error(c"gantt\nA: a, 2024-01-01, 1d\ninclusiveEndDates", c"Gantt inclusiveEndDates must precede tasks")
	gaps_error(c"gantt\nA: a, 2024-01-01, until ", c"Gantt requires end date, until task or positive duration")

void test_gantt_vert_markers_take_no_row():
	mm_document* d = gaps_parse(c"gantt\ndateFormat HH:mm\naxisFormat %H:%M\nInitial vert : vert, v1, 17:30, 2m\nTask A : 3m\nTask B : 8m\nFinal vert : vert, v2, 17:58, 4m\n")
	assert_equal(16, gaps_task(d, 0).value)
	assert_equal(17 * 60 + 32, gaps_task(d, 1).start)
	mm_scene* scene = mm_render(d)
	assert_equal(4, scene.nodes.length)
	mm_bounds* marker = scene.nodes[0]
	mm_bounds* first = scene.nodes[1]
	mm_bounds* second = scene.nodes[2]
	assert_equal(0, marker.w)
	asserts(c"tasks keep consecutive rows", second.y == first.y + 85)
	int purple = 0
	for mm_primitive* item in scene.items:
		if (item.kind == MM_LINE && (item.style.mask & 2) != 0 && item.style.stroke == 0x7c3aed): purple = purple + 1
	assert_equal(2, purple)
	mm_scene_free(scene)
	char* svg = gaps_svg(d)
	asserts(c"vert marker exported", index_of(svg, c"#7c3aed") >= 0 && index_of(svg, c"Final vert") >= 0)
	free(svg)
	mm_document_free(d)

void test_gantt_tick_interval_weekday_and_compact():
	mm_document* d = gaps_parse(c"gantt\ntickInterval 1week\nweekday monday\nA: 2024-01-03, 20d\n")
	assert_equal(1, d.gantt.tick_count)
	assert_equal(6, d.gantt.tick_unit)
	assert_equal(1, d.gantt.week_start)
	char* svg = gaps_svg(d)
	asserts(c"week ticks start on Mondays", index_of(svg, c">2024-01-08<") >= 0 && index_of(svg, c">2024-01-15<") >= 0 && index_of(svg, c">2024-01-22<") >= 0 && index_of(svg, c">2024-01-03<") < 0)
	free(svg)
	mm_document_free(d)
	d = gaps_parse(c"gantt\ntickInterval 1month\nA: 2024-01-03, 80d\n")
	svg = gaps_svg(d)
	asserts(c"month ticks on the first", index_of(svg, c">2024-02-01<") >= 0 && index_of(svg, c">2024-03-01<") >= 0)
	free(svg)
	mm_document_free(d)
	# Unknown intervals are accepted and ignored, as upstream.
	d = gaps_parse(c"gantt\ntickInterval 1decade\nA: 2024-01-03, 2d\n")
	assert_equal(0, d.gantt.tick_unit)
	mm_document_free(d)
	gaps_error(c"gantt\nweekday funday\nA: 2024-01-01, 1d", c"Gantt weekday must name a day of the week")
	# Compact display mode from top-level frontmatter packs non-overlapping tasks.
	char* source = c"---\ndisplayMode: compact\n---\ngantt\nsection S\nA: a1, 2014-01-01, 30d\nB: a2, 2014-01-20, 25d\nC: a3, 2014-02-10, 20d\n"
	d = gaps_parse(source)
	mm_scene* scene = mm_render(d)
	mm_bounds* a = scene.nodes[0]
	mm_bounds* b = scene.nodes[1]
	mm_bounds* c = scene.nodes[2]
	asserts(c"overlapping task takes a second row", b.y > a.y)
	asserts(c"later task reuses the first row", c.y == a.y)
	mm_scene_free(scene)
	mm_document_free(d)
	# The same through config.gantt, plus a configured tick interval.
	d = gaps_parse(c"---\nconfig:\n  gantt:\n    displayMode: compact\n    tickInterval: 1week\n    weekday: monday\n---\ngantt\nA: a1, 2024-01-01, 5d\nB: a2, 2024-01-10, 5d\n")
	scene = mm_render(d)
	a = scene.nodes[0]
	b = scene.nodes[1]
	assert_equal(a.y, b.y)
	mm_scene_free(scene)
	svg = gaps_svg(d)
	asserts(c"configured weekly ticks", index_of(svg, c">2024-01-08<") >= 0)
	free(svg)
	mm_document_free(d)
	gaps_error(c"---\ndisplayMode: wide\n---\ngantt\nA: 2024-01-01, 1d\n", c"gantt displayMode must be compact or empty")
	gaps_error(c"---\nconfig:\n  gantt:\n    barColour: red\n---\ngantt\nA: 2024-01-01, 1d\n", c"unsupported gantt setting")
	# A chart of directives alone still renders its axis.
	d = gaps_parse(c"gantt\n  tickInterval 1week\n  weekday monday\n")
	svg = gaps_svg(d)
	asserts(c"empty chart has a baseline", index_of(svg, c"<line") >= 0)
	free(svg)
	mm_document_free(d)

void test_gantt_gap_prefixes():
	gaps_prefixes(c"gantt\ndateFormat YYYY-MM-DDTHH:mmZ\naxisFormat %H:%M %Z\ntickInterval 2hour\nA: a, 2024-01-01T10:00+02:00, 1h\nM : vert, 2024-01-01T11:00Z, 1m\nB: after a, 1M\n")

int gaps_count_circles(mm_scene* scene, int width):
	int count = 0
	for mm_primitive* item in scene.items:
		if (item.kind == MM_CIRCLE && item.x2 - item.x == width): count = count + 1
	return count

int gaps_line_from(mm_scene* scene, int x, int y):
	int count = 0
	for mm_primitive* item in scene.items:
		if (item.kind == MM_LINE && item.x == x && item.y == y): count = count + 1
	return count

void test_journey_faces_and_actor_avatars():
	mm_document* d = gaps_parse(c"journey\ntitle Day\nsection Morning\nWake: 1: Me, Cat\nCoffee: 5: Me\nCommute: 3: Me, Cat, Dog\n")
	mm_scene* scene = mm_render(d)
	assert_equal(3, gaps_count_circles(scene, 30))
	# Two eyes per face.
	assert_equal(6, gaps_count_circles(scene, 4))
	# Six task avatars plus a three-actor legend.
	assert_equal(9, gaps_count_circles(scene, 14))
	# Mouths: a frown's ends sit low (score 1), a smile's ends sit high
	# (score 5) and the neutral face (score 3) has one straight mouth.
	list[int] centres = new list[int]
	for i in range(3):
		mm_bounds* b = scene.nodes[i]
		centres.push(b.x + b.w / 2)
	assert_equal(1, gaps_line_from(scene, centres[0] - 7, 311 + 9))
	assert_equal(1, gaps_line_from(scene, centres[1] - 7, 175 + 3))
	assert_equal(1, gaps_line_from(scene, centres[2] - 7, 243 + 6))
	__w_list_free(cast(__w_list*, centres))
	char* svg = mm_svg(scene)
	asserts(c"actor colours exported", index_of(svg, c"#8fbc8f") >= 0 && index_of(svg, c"#7cfc00") >= 0 && index_of(svg, c"#00ffff") >= 0)
	asserts(c"legend names exported", index_of(svg, c">Dog<") >= 0)
	free(svg)
	mm_scene_free(scene)
	svg = gaps_svg(d)
	free(svg)
	mm_document_free(d)

void test_timeline_td_layout_and_multicolor():
	char* source = c"timeline TD\ntitle History\nsection 2023 Q1 <br> Release\n  Bullet 1 : sub-point 1a : sub-point 1b\n  Bullet 2 : sub-point 2a\nsection 2023 Q2\n  Bullet 3 : sub-point 3a\n"
	mm_document* d = gaps_parse(source)
	assert_strings_equal(c"TD", mm_setting(d, c"timeline.direction"))
	mm_scene* scene = mm_render(d)
	assert_equal(3, scene.nodes.length)
	mm_bounds* first = scene.nodes[0]
	mm_bounds* second = scene.nodes[1]
	mm_bounds* third = scene.nodes[2]
	asserts(c"TD periods stack vertically", second.y > first.y + first.h && second.x == first.x && third.y > second.y)
	# Sections colour their periods and events: section 0, then section 1.
	int section_zero = 0
	int section_one = 0
	for mm_primitive* item in scene.items:
		if (item.role == 5 && item.series == 0): section_zero = section_zero + 1
		if (item.role == 5 && item.series == 1): section_one = section_one + 1
	assert_equal(5, section_zero)
	assert_equal(2, section_one)
	mm_scene_free(scene)
	char* svg = gaps_svg(d)
	asserts(c"multicolour fill exported", index_of(svg, c"#dbeafe") >= 0 && index_of(svg, c"#fee2e2") >= 0)
	free(svg)
	mm_document_free(d)
	# Without sections every period gets its own colour; LR stays the default.
	d = gaps_parse(c"timeline LR\n2002 : LinkedIn\n2004 : Facebook : Google\n")
	scene = mm_render(d)
	first = scene.nodes[0]
	second = scene.nodes[1]
	asserts(c"LR periods run horizontally", second.x > first.x + first.w)
	int colored = 0
	for mm_primitive* item in scene.items:
		if (item.role == 5 && item.series == 1): colored = colored + 1
	assert_equal(3, colored)
	mm_scene_free(scene)
	mm_document_free(d)
	d = gaps_parse(c"---\nconfig:\n  timeline:\n    disableMulticolor: true\n---\ntimeline\n2002 : LinkedIn\n2004 : Facebook\n")
	scene = mm_render(d)
	int series = 0
	for mm_primitive* item in scene.items:
		if (item.role == 5): series = series + 1
	assert_equal(0, series)
	mm_scene_free(scene)
	mm_document_free(d)
	gaps_error(c"timeline XY\n2002 : A", c"timeline direction must be LR or TD")
	gaps_error(c"---\nconfig:\n  timeline:\n    disableMulticolor: maybe\n---\ntimeline\n2002 : A\n", c"configuration value must be true or false")
	gaps_prefixes(source)
