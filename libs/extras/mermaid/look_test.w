# wbuild: x64
# Redux drop-shadow filters, upstream theme font families and the
# deterministic hand-drawn look (issue #818).
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render
import libs.extras.mermaid.serialize
import libs.extras.mermaid.serialize_equal

mm_document* look_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"look source parses", d.error == 0)
	return d

char* look_svg(char* source):
	mm_document* d = look_parse(source)
	mm_scene* scene = mm_render(d)
	asserts(c"look scene", scene != 0)
	char* svg = mm_svg(scene)
	mm_scene_free(scene)
	char* written = mm_write(d)
	assert_strings_equal(d.source, written)
	free(written)
	mm_document_free(d)
	return svg

char* look_themed(char* config):
	string_builder* source = string_from(c"---\nconfig:\n")
	string_append(source, config)
	string_append(source, c"---\nflowchart LR\nA[Start] --> B((Stop))\n")
	char* svg = look_svg(source.data)
	string_free(source)
	return svg

void test_redux_themes_use_their_own_filter():
	char* svg = look_themed(c"  theme: redux\n  look: neo\n")
	asserts(c"redux filter offset", index_of(svg, c"<feDropShadow dx=\"4\" dy=\"4\" stdDeviation=\"0\" flood-color=\"#000000\" flood-opacity=\"0.06\"/>") >= 0)
	asserts(c"redux nodes use the filter", index_of(svg, c"filter=\"url(#mermaid-drop-shadow)\"") >= 0)
	free(svg)
	char* dark = look_themed(c"  theme: redux-dark-color\n  look: neo\n")
	asserts(c"dark redux shadow is white", index_of(dark, c"<feDropShadow dx=\"4\" dy=\"4\" stdDeviation=\"0\" flood-color=\"#ffffff\" flood-opacity=\"0.06\"/>") >= 0)
	free(dark)
	# neo keeps its CSS drop-shadow(0 1px 2px rgba(0, 0, 0, 0.25)).
	char* neo = look_themed(c"  theme: neo\n  look: neo\n")
	asserts(c"neo shadow unchanged", index_of(neo, c"<feDropShadow dx=\"0\" dy=\"1\" stdDeviation=\"2\" flood-color=\"#000000\" flood-opacity=\"0.25\"/>") >= 0)
	free(neo)
	mm_document* d = look_parse(c"---\nconfig:\n  theme: redux-dark\n  look: neo\n---\nflowchart LR\nA\n")
	mm_scene* scene = mm_render(d)
	assert_equal(4, scene.shadow_dx)
	assert_equal(4, scene.shadow_dy)
	assert_equal(0, scene.shadow_blur)
	assert_equal(0xffffff, scene.shadow_color)
	assert_equal(6, scene.shadow_alpha)
	mm_scene_free(scene)
	mm_document_free(d)

void test_theme_font_families():
	char* classic = look_themed(c"  theme: forest\n")
	asserts(c"classic theme family", index_of(classic, c"font-family=\"&quot;trebuchet ms&quot;, verdana, arial, sans-serif\"") >= 0)
	free(classic)
	char* neo = look_themed(c"  theme: neo-dark\n")
	asserts(c"neo theme family", index_of(neo, c"font-family=\"arial, sans-serif\"") >= 0)
	free(neo)
	char* redux = look_themed(c"  theme: redux-color\n")
	asserts(c"redux theme family", index_of(redux, c"font-family=\"&quot;Recursive Variable&quot;, arial, sans-serif\"") >= 0)
	free(redux)
	# fontFamily configuration wins over the theme's.
	char* own = look_themed(c"  theme: redux\n  fontFamily: Inter, sans-serif\n")
	asserts(c"configured family", index_of(own, c"font-family=\"Inter, sans-serif\"") >= 0)
	asserts(c"theme family not used", index_of(own, c"Recursive") < 0)
	free(own)
	# Unconfigured documents keep the native face.
	char* plain = look_svg(c"flowchart LR\nA --> B\n")
	asserts(c"native face", index_of(plain, c"font-family=\"Liberation Sans, Arial, Helvetica, sans-serif\"") >= 0)
	free(plain)
	# Metrics stay those of the bundled Arial-compatible face.
	mm_document* themed = look_parse(c"---\nconfig:\n  theme: default\n---\nflowchart LR\nA[Same width]\n")
	mm_document* bare = look_parse(c"flowchart LR\nA[Same width]\n")
	mm_scene* a = mm_render(themed)
	mm_scene* b = mm_render(bare)
	assert_equal(b.nodes[0].w, a.nodes[0].w)
	mm_scene_free(a)
	mm_scene_free(b)
	mm_document_free(themed)
	mm_document_free(bare)

void test_hand_drawn_look_parses_and_round_trips():
	mm_document* d = look_parse(c"---\nconfig:\n  look: handDrawn\n  handDrawnSeed: 42\n---\nflowchart LR\nA --> B\n")
	assert_equal(2, d.look)
	assert_equal(42, mm_config_number(d, c"handDrawnSeed", 0))
	char* canonical = mm_serialize(d)
	asserts(c"hand-drawn canonical form", canonical != 0 && index_of(canonical, c"look: \"handDrawn\"") >= 0 && index_of(canonical, c"handDrawnSeed: \"42\"") >= 0)
	mm_document* again = look_parse(canonical)
	char* diff = mm_document_diff(d, again)
	if (diff != 0): println2(diff)
	asserts(c"hand-drawn round trip", diff == 0)
	mm_document_free(again)
	free(canonical)
	mm_document_free(d)
	char* negative = c"---\nconfig:\n  handDrawnSeed: -1\n---\nflowchart LR\nA\n"
	mm_document* bad = mm_parse(negative, strlen(negative))
	asserts(c"negative seed rejected", bad.error != 0)
	mm_document_free(bad)

void test_hand_drawn_svg_is_rough_and_deterministic():
	char* source = c"---\nconfig:\n  look: handDrawn\n  handDrawnSeed: 3\n---\nflowchart LR\nA[Start] --> B((Stop))\nB -.-> C{Ok?}\n"
	char* first = look_svg(source)
	char* second = look_svg(source)
	assert_strings_equal(first, second)
	asserts(c"rough strokes are paths", index_of(first, c"<path fill=\"none\"") >= 0)
	asserts(c"hachure fill strokes", index_of(first, c"stroke-width=\"1.5\" stroke-linecap=\"round\" d=\"M") >= 0)
	asserts(c"no crisp node rects", index_of(first, c"<rect x=") < 0)
	asserts(c"no crisp edge lines", index_of(first, c"<line") < 0)
	asserts(c"dashed edges stay dashed", index_of(first, c"stroke-dasharray=\"6 4\" d=\"M") >= 0)
	asserts(c"labels stay text", index_of(first, c">Start</text>") >= 0)
	char* other = look_svg(c"---\nconfig:\n  look: handDrawn\n  handDrawnSeed: 4\n---\nflowchart LR\nA[Start] --> B((Stop))\nB -.-> C{Ok?}\n")
	asserts(c"another seed draws differently", strcmp(first, other) != 0)
	free(other)
	char* classic = look_svg(c"flowchart LR\nA[Start] --> B((Stop))\n")
	asserts(c"classic look unchanged", index_of(classic, c"<path") < 0 && index_of(classic, c"<rect") >= 0)
	free(classic)
	free(first)
	free(second)

void test_rough_strokes_double_and_stay_near_the_shape():
	mm_rough* r = mm_rough_new(mm_rough_seed(0, 5))
	mm_rough_shape(r, 1, 10, 20, 210, 20, 0, 0, 0)
	# A line is drawn twice, each pass one flattened cubic.
	assert_equal(2 * (1 + (MM_ROUGH_STEPS + 1) * 2), r.strokes.length)
	int at = 0
	while (at < r.strokes.length):
		int count = r.strokes[at]
		for i in range(count):
			int x = r.strokes[at + 1 + i * 2]
			int y = r.strokes[at + 2 + i * 2]
			asserts(c"stroke near the line", x >= 70 && x <= 2130 && y >= 160 && y <= 240)
		at = at + 1 + count * 2
	mm_rough_free(r)
	# Same seed, same strokes; box fills hatch inside the box.
	mm_rough* a = mm_rough_new(9)
	mm_rough* b = mm_rough_new(9)
	mm_rough_shape(a, 2, 0, 0, 100, 40, 0, 0, 1)
	mm_rough_shape(b, 2, 0, 0, 100, 40, 0, 0, 1)
	assert_equal(a.strokes.length, b.strokes.length)
	for i in range(a.strokes.length): assert_equal(a.strokes[i], b.strokes[i])
	asserts(c"box hachure", a.fills.length > 40)
	# Four edges, two passes each.
	int runs = 0
	at = 0
	while (at < a.strokes.length):
		runs = runs + 1
		at = at + 1 + a.strokes[at] * 2
	assert_equal(8, runs)
	at = 0
	while (at < a.fills.length):
		int count = a.fills[at]
		for i in range(count):
			int x = a.fills[at + 1 + i * 2]
			int y = a.fills[at + 2 + i * 2]
			asserts(c"hachure inside the box", x >= -20 && x <= 1020 && y >= -20 && y <= 420)
		at = at + 1 + count * 2
	mm_rough_free(a)
	mm_rough_free(b)
	# Huge shapes keep the hachure bounded.
	mm_rough* big = mm_rough_new(1)
	mm_rough_shape(big, 2, 0, 0, 100000, 100000, 0, 0, 1)
	asserts(c"bounded hachure", big.fills.length <= MM_ROUGH_MAX_LINES * 2 * (1 + (MM_ROUGH_STEPS + 1) * 2))
	mm_rough_free(big)

void test_hand_drawn_reaches_every_family():
	list[char*] sources = list[char*]{c"sequenceDiagram\nA->>B: hi\n", c"classDiagram\nclass A\nA <|-- B\n", c"pie\n\"A\": 1\n\"B\": 2\n", c"stateDiagram-v2\n[*] --> S\nS --> [*]\n", c"erDiagram\nA ||--o{ B : has\n"}
	for char* body in sources:
		string_builder* source = string_from(c"---\nconfig:\n  look: handDrawn\n---\n")
		string_append(source, body)
		char* svg = look_svg(source.data)
		asserts(c"family drawn by hand", index_of(svg, c"<path fill=\"none\"") >= 0)
		free(svg)
		string_free(source)
	__w_list_free(cast(__w_list*, sources))
