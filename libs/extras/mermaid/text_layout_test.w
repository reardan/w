# wbuild: x64
# Shared multi-line label layout: breaks, markdown emphasis, wrapping,
# metrics, node/edge sizing and SVG export across the graph families.
import lib.testing
import libs.extras.mermaid.io
import libs.extras.mermaid.render
import libs.extras.mermaid.serialize
import graphics.ui.font

mm_document* text_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"label source parses", d.error == 0)
	return d

# The run on line `line` whose text is `text`, or 0.
mm_text_run* text_run(mm_text_block* b, int line, char* text):
	for mm_text_run* r in b.runs:
		if (r.line == line && strcmp(r.text, text) == 0): return r
	return 0

mm_primitive* text_item(mm_scene* s, char* text):
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && strcmp(p.text, text) == 0): return p
	return 0

void test_metrics_follow_native_advances():
	# H e l l o at Liberation Sans 16px: 12 + 9 + 4 + 4 + 9.
	assert_equal(38, mm_text_width(c"Hello", 0))
	assert_equal(38, mm_text_width(c"Hello", MM_TEXT_ITALIC))
	asserts(c"bold is wider", mm_text_width(c"Hello", MM_TEXT_BOLD) > 38)
	asserts(c"narrow letters measure narrow", mm_text_width(c"iiii", 0) < mm_text_width(c"MMMM", 0))
	# UTF-8 is measured per code point, not per byte; wide CJK takes an em.
	assert_equal(9, mm_text_width(c"\xc3\xa9", 0))
	assert_equal(16, mm_text_width(c"\xe4\xb8\xad", 0))
	assert_equal(0, mm_text_width(c"", 0))
	# Truncated sequences never read past the terminator.
	asserts(c"truncated UTF-8 bounded", mm_text_width(c"a\xe4", 0) > 0)

# The table must equal the native preview's own glyph advances, glyph by
# glyph, for every printable ASCII character in each face it can draw.
void test_metrics_match_native_font():
	int regular = ui_font_strike(UI_FACE_REGULAR, MM_TEXT_SIZE)
	int bold = ui_font_strike(UI_FACE_BOLD, MM_TEXT_SIZE)
	int italic = ui_font_strike(UI_FACE_ITALIC, MM_TEXT_SIZE)
	int both = ui_font_strike(UI_FACE_BOLD_ITALIC, MM_TEXT_SIZE)
	assert_equal(regular, ui_font_strike_from_scale(2))
	assert_equal(MM_TEXT_ASCENT, ui_font_strike_ascent(regular))
	for c in range(32, 127):
		assert_equal(ui_font_glyph(regular, c).advance, mm_text_codepoint_width(c, 0))
		assert_equal(ui_font_glyph(italic, c).advance, mm_text_codepoint_width(c, MM_TEXT_ITALIC))
		assert_equal(ui_font_glyph(bold, c).advance, mm_text_codepoint_width(c, MM_TEXT_BOLD))
		assert_equal(ui_font_glyph(both, c).advance, mm_text_codepoint_width(c, MM_TEXT_BOLD | MM_TEXT_ITALIC))
	# Kerning only tightens native runs, so layout never under-reserves.
	char* sample = c"AVAWAY To Tea, Wave."
	asserts(c"layout width covers native run", mm_text_width(sample, 0) >= ui_text_width_strike(sample, regular))

void test_break_tags_split_lines():
	mm_text_block* b = mm_text_layout(c"one<br>two<BR/>three<br />four<br  />five", 0)
	assert_equal(5, mm_text_lines(b))
	asserts(c"first line", text_run(b, 0, c"one") != 0)
	asserts(c"case-insensitive break", text_run(b, 2, c"three") != 0)
	asserts(c"spaced self-closing break", text_run(b, 4, c"five") != 0)
	assert_equal(5 * MM_TEXT_PITCH - (MM_TEXT_PITCH - MM_TEXT_LINE), b.height)
	assert_equal(mm_text_width(c"three", 0), b.width)
	mm_text_block_free(b)
	# Not a break: other tags and an unclosed `<br` stay literal.
	b = mm_text_layout(c"a <b> c <br", 0)
	assert_equal(1, mm_text_lines(b))
	asserts(c"literal tags kept", text_run(b, 0, c"a <b> c <br") != 0)
	mm_text_block_free(b)
	# Plain labels keep a single line box for an empty label.
	b = mm_text_layout(c"", 0)
	assert_equal(1, mm_text_lines(b))
	assert_equal(MM_TEXT_LINE, b.height)
	mm_text_block_free(b)

void test_markdown_emphasis_runs():
	mm_text_block* b = mm_text_layout(c"`plain **bold** and *it* or _also_ snake_case_name`", 0)
	assert_equal(1, mm_text_lines(b))
	mm_text_run* bold = text_run(b, 0, c"bold")
	asserts(c"bold run", bold != 0 && bold.style == MM_TEXT_BOLD)
	mm_text_run* it = text_run(b, 0, c"it")
	asserts(c"star italic run", it != 0 && it.style == MM_TEXT_ITALIC)
	mm_text_run* also = text_run(b, 0, c"also")
	asserts(c"underscore italic run", also != 0 && also.style == MM_TEXT_ITALIC)
	asserts(c"intraword underscores literal", text_run(b, 0, c"snake_case_name") != 0)
	mm_text_run* plain = text_run(b, 0, c"plain")
	asserts(c"plain prefix", plain != 0 && plain.x == 0 && plain.style == 0)
	int space = mm_text_width(c" ", 0)
	assert_equal(mm_text_width(c"plain", 0) + space, bold.x)
	asserts(c"runs advance left to right", it.x > bold.x + bold.width && also.x > it.x)
	mm_text_block_free(b)
	# Bold italic nesting and unclosed markers.
	b = mm_text_layout(c"`**bold *both***` **open", 0)
	asserts(c"plain label keeps markdown literal", mm_text_lines(b) == 1 && b.runs.length == 1)
	mm_text_block_free(b)
	b = mm_text_layout(c"`**bold *both***`", 0)
	mm_text_run* both = text_run(b, 0, c"both")
	asserts(c"nested bold italic", both != 0 && both.style == (MM_TEXT_BOLD | MM_TEXT_ITALIC))
	mm_text_block_free(b)
	b = mm_text_layout(c"`***all***`", 0)
	mm_text_run* all = text_run(b, 0, c"all")
	asserts(c"triple marker bold italic", b.runs.length == 1 && all != 0 && all.style == (MM_TEXT_BOLD | MM_TEXT_ITALIC))
	mm_text_block_free(b)
	b = mm_text_layout(c"`2 * 3 and **open`", 0)
	asserts(c"unclosed markers literal", b.runs.length == 1 && text_run(b, 0, c"2 * 3 and **open") != 0)
	mm_text_block_free(b)

void test_markdown_newlines_and_whitespace():
	mm_text_block* b = mm_text_layout(c"`first   line\n  second<br>third`", 0)
	assert_equal(3, mm_text_lines(b))
	asserts(c"spaces collapse", text_run(b, 0, c"first line") != 0)
	asserts(c"leading indent dropped", text_run(b, 1, c"second") != 0)
	asserts(c"br inside markdown", text_run(b, 2, c"third") != 0)
	mm_text_block_free(b)
	# A plain label's newline is just whitespace (plain labels cannot hold one
	# from the parser, but generated models might).
	b = mm_text_layout(c"a\nb", 0)
	assert_equal(1, mm_text_lines(b))
	mm_text_block_free(b)

void test_wrapping_rule():
	char* label = c"`The quick brown fox jumps over the lazy dog and keeps running far away`"
	mm_text_block* b = mm_text_layout(label, MM_TEXT_WRAP)
	asserts(c"long label wraps", mm_text_lines(b) >= 2)
	for int width in b.line_widths: asserts(c"line fits wrap width", width <= MM_TEXT_WRAP)
	asserts(c"block fits", b.width <= MM_TEXT_WRAP)
	mm_text_block_free(b)
	b = mm_text_layout(label, 0)
	assert_equal(1, mm_text_lines(b))
	mm_text_block_free(b)
	# Greedy: the next word moves down only when it would overflow.
	b = mm_text_layout(c"aaaa bbbb", mm_text_width(c"aaaa bbbb", 0))
	assert_equal(1, mm_text_lines(b))
	mm_text_block_free(b)
	b = mm_text_layout(c"aaaa bbbb", mm_text_width(c"aaaa bbbb", 0) - 1)
	assert_equal(2, mm_text_lines(b))
	asserts(c"wrapped word starts its line", text_run(b, 1, c"bbbb").x == 0)
	mm_text_block_free(b)
	# Words longer than the limit stay whole on their own line.
	b = mm_text_layout(c"x Supercalifragilisticexpialidocious_and_then_some_more y", 100)
	assert_equal(3, mm_text_lines(b))
	asserts(c"long word kept", b.width > 100)
	mm_text_block_free(b)
	# Styled words wrap as units: a bold run continues on the next line.
	b = mm_text_layout(c"`**alpha beta gamma**`", mm_text_width(c"alpha beta", MM_TEXT_BOLD))
	assert_equal(2, mm_text_lines(b))
	mm_text_run* gamma = text_run(b, 1, c"gamma")
	asserts(c"style survives wrap", gamma != 0 && gamma.style == MM_TEXT_BOLD)
	mm_text_block_free(b)

void test_flowchart_nodes_grow_and_svg_styles():
	char* source = c"flowchart TD\nA[\"`**Bold** title\nsecond *line*`\"] --> B[Short]\nB --> C[This label is long enough that it must wrap onto more lines]\nC --> D[\"x &lt; y & <br>z\"]\n"
	mm_document* d = text_parse(source)
	mm_node* a = d.nodes[0]
	asserts(c"markdown label keeps newline", index_of(a.label, c"title\nsecond") >= 0)
	mm_scene* s = mm_render(d)
	mm_bounds* ba = s.nodes[0]
	mm_bounds* bb = s.nodes[1]
	mm_bounds* bc = s.nodes[2]
	assert_equal(60, bb.h)
	assert_equal(60 + MM_TEXT_PITCH, ba.h)
	asserts(c"wrapped node taller", bc.h > 60)
	asserts(c"wrapped node bounded", bc.w <= MM_TEXT_WRAP + 40)
	mm_primitive* bold = text_item(s, c"Bold")
	mm_primitive* second = text_item(s, c"second")
	mm_primitive* line = text_item(s, c"line")
	asserts(c"styled runs drawn", bold != 0 && second != 0 && line != 0)
	assert_equal(MM_TEXT_BOLD, bold.text_style)
	assert_equal(MM_TEXT_ITALIC, line.text_style)
	assert_equal(MM_TEXT_PITCH, second.y - bold.y)
	asserts(c"title inside node", bold.y >= ba.y && second.y + MM_TEXT_LINE <= ba.y + ba.h)
	mm_primitive* brief = text_item(s, c"Short")
	assert_equal(bb.x + (bb.w - mm_text_width(c"Short", 0)) / 2, brief.x)
	char* svg = mm_svg(s)
	asserts(c"bold svg run", index_of(svg, c"font-weight=\"bold\"") >= 0)
	asserts(c"italic svg run", index_of(svg, c"font-style=\"italic\"") >= 0 && index_of(svg, c">line</text>") >= 0)
	asserts(c"plain run unchanged", index_of(svg, c">Short</text>") >= 0)
	asserts(c"label escaped", index_of(svg, c">x &amp;lt; y &amp;</text>") >= 0 && index_of(svg, c">z</text>") >= 0)
	asserts(c"break tag consumed", index_of(svg, c"&lt;br") < 0)
	asserts(c"no raw markers", index_of(svg, c"**") < 0 && index_of(svg, c"`") < 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_edge_labels_wrap_and_widen_ranks():
	char* plain = c"flowchart LR\nA --> B\n"
	char* labelled = c"flowchart LR\nA -->|a rather long edge label that needs several lines| B\n"
	mm_document* d = text_parse(plain)
	mm_scene* s = mm_render(d)
	int gap = s.nodes[1].x - s.nodes[0].x - s.nodes[0].w
	mm_scene_free(s)
	mm_document_free(d)
	d = text_parse(labelled)
	s = mm_render(d)
	int wide = s.nodes[1].x - s.nodes[0].x - s.nodes[0].w
	asserts(c"label widens rank gap", wide > gap)
	int lines = 0
	int top = 100000
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && strlen(p.text) > 1):
			lines = lines + 1
			asserts(c"edge label between nodes", p.x >= s.nodes[0].x + s.nodes[0].w && p.x + mm_text_width(p.text, 0) <= s.nodes[1].x)
			if (p.y < top): top = p.y
	asserts(c"edge label wrapped", lines >= 2)
	asserts(c"edge label above connector", top + MM_TEXT_LINE <= s.nodes[1].y + s.nodes[1].h / 2)
	mm_scene_free(s)
	mm_document_free(d)
	d = text_parse(c"flowchart TD\nA -->|\"`one\ntwo`\"| B\n")
	s = mm_render(d)
	mm_primitive* one = text_item(s, c"one")
	mm_primitive* two = text_item(s, c"two")
	asserts(c"multi-line vertical edge label", one != 0 && two != 0 && two.y - one.y == MM_TEXT_PITCH)
	mm_scene_free(s)
	mm_document_free(d)

void test_er_class_state_titles():
	mm_document* d = text_parse(c"erDiagram\nCUSTOMER[\"Customer<br>account\"] {\nstring id\n}\n")
	mm_scene* s = mm_render(d)
	mm_bounds* b = s.nodes[0]
	assert_equal(40 + MM_TEXT_PITCH + 26, b.h)
	mm_primitive* row = text_item(s, c"string  id")
	mm_primitive* second = text_item(s, c"account")
	asserts(c"attributes below two-line title", row != 0 && second != 0 && row.y > second.y + MM_TEXT_LINE)
	mm_scene_free(s)
	mm_document_free(d)
	d = text_parse(c"classDiagram\nclass Item[\"Line<br>item with a long name that does not wrap\"] {\n-int id\n}\n")
	s = mm_render(d)
	b = s.nodes[0]
	mm_primitive* title = text_item(s, c"item with a long name that does not wrap")
	row = text_item(s, c"-int id")
	asserts(c"class title is not wrapped", title != 0 && b.w >= mm_text_width(title.text, 0) + 40)
	asserts(c"members below title", row.y > title.y + MM_TEXT_LINE)
	mm_scene_free(s)
	mm_document_free(d)
	d = text_parse(c"stateDiagram-v2\nstate \"`Waiting for\n**approval**`\" as W\n[*] --> W\n")
	s = mm_render(d)
	mm_primitive* approval = text_item(s, c"approval")
	asserts(c"state description multi-line", approval != 0 && approval.text_style == MM_TEXT_BOLD && text_item(s, c"Waiting for") != 0)
	mm_scene_free(s)
	mm_document_free(d)

void test_subgraph_title_lines_push_children_down():
	mm_document* d = text_parse(c"flowchart TD\nsubgraph G[\"Group<br>title\"]\nA\nend\n")
	mm_scene* s = mm_render(d)
	mm_bounds* group = s.nodes[0]
	mm_bounds* child = s.nodes[1]
	mm_primitive* title = text_item(s, c"title")
	asserts(c"child below two-line header", title != 0 && child.y > title.y + MM_TEXT_LINE)
	asserts(c"child inside group", child.y + child.h < group.y + group.h)
	mm_scene_free(s)
	mm_document_free(d)

void test_source_stays_lossless():
	char* source = c"flowchart LR\nA[\"`multi\nline`\"] -->|x<br>y| B\n"
	mm_document* d = text_parse(source)
	assert_equal(0, strcmp(d.source, source))
	asserts(c"label keeps break tag", strcmp(d.edges[0].label, c"x<br>y") == 0)
	# Canonical serialization cannot quote a raw newline and refuses.
	char* text = mm_serialize(d)
	asserts(c"newline label not serialized approximately", text == 0)
	mm_document_free(d)
	# An unterminated markdown string falls back to the one-line rule.
	char* open = c"flowchart LR\nA[\"`open]\nB\n"
	d = mm_parse(open, strlen(open))
	asserts(c"unterminated markdown rejected", d.error != 0)
	mm_document_free(d)
	char* ticks = c"flowchart LR\nA[\"`a\"] --> B[\"`b\"]\n"
	d = mm_parse(ticks, strlen(ticks))
	asserts(c"backtick-only labels parse on one line", d.error == 0 && strcmp(d.nodes[0].label, c"`a") == 0)
	mm_document_free(d)
