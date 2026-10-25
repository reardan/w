# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* config_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"configuration parses", d.error == 0)
	char* saved = mm_write(d)
	assert_strings_equal(source, saved)
	free(saved)
	return d

void config_reject(char* source, char* message):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error == 0 || strcmp(d.error, message) != 0):
		println2(source)
		if (d.error != 0): println2(d.error)
	asserts(c"configuration diagnosed", d.error != 0)
	if (d.error != 0): assert_strings_equal(message, d.error)
	asserts(c"no preview after configuration error", mm_render(d) == 0)
	char* saved = mm_write(d)
	assert_strings_equal(source, saved)
	free(saved)
	mm_document_free(d)

void test_mermaid_theme_derivation_from_primary_color():
	assert_equal(0xa32929, mm_theme_adjust(0xff0000, 0, -40, -10))
	assert_equal(0x0000ff, mm_theme_adjust(0xff0000, -120, 0, 0))
	assert_equal(0x1affff, mm_theme_adjust(0xff0000, 180, 0, 5))
	assert_equal(0x336699, mm_theme_adjust(0x336699, 0, 0, 0))
	mm_document* d = config_parse(c"---\nconfig:\n  theme: base\n  themeVariables:\n    primaryColor: '#ff0000'\n---\nflowchart TB\nsubgraph G\nA -->|go| B\nend\n")
	list[int] v = d.theme_values
	assert_equal(0xff0000, v[MM_THEME_PRIMARY])
	assert_equal(0xa32929, v[MM_THEME_PRIMARY_BORDER])
	assert_equal(0xeeeeee, v[MM_THEME_PRIMARY_TEXT])
	assert_equal(0x0000ff, v[MM_THEME_SECONDARY])
	assert_equal(0x1affff, v[MM_THEME_TERTIARY])
	assert_equal(0x1affff, v[MM_THEME_CLUSTER_BKG])
	assert_equal(0x0000ff, v[MM_THEME_EDGE_LABEL_BKG])
	assert_equal(0xff0000, v[MM_THEME_PIE])
	assert_equal(0x0000ff, v[MM_THEME_PIE + 1])
	assert_equal(0x1affff, v[MM_THEME_PIE + 2])
	assert_equal(0xff0000, v[MM_THEME_SCALE])
	# Untouched roots keep the upstream base palette.
	assert_equal(0xf4f4f4, v[MM_THEME_BACKGROUND])
	assert_equal(0x0b0b0b, v[MM_THEME_LINE])
	mm_scene* s = mm_render(d)
	int nodes = 0
	int clusters = 0
	int label_boxes = 0
	for i in range(s.items.length):
		mm_primitive* p = s.items[i]
		if (p.kind == MM_BOX && p.role == MM_ROLE_NODE):
			assert_equal(0xff0000, mm_paint_fill(p))
			assert_equal(0xa32929, mm_paint_stroke(p))
			nodes = nodes + 1
		if (p.kind == MM_BOX && p.role == MM_ROLE_CLUSTER):
			assert_equal(0x1affff, mm_paint_fill(p))
			clusters = clusters + 1
		if (p.role == MM_ROLE_LABEL_BOX):
			assert_equal(0x0000ff, mm_paint_fill(p))
			assert_equal(-1, mm_paint_stroke(p))
			mm_primitive* label = s.items[i + 1]
			assert_strings_equal(c"go", label.text)
			label_boxes = label_boxes + 1
	assert_equal(2, nodes)
	assert_equal(1, clusters)
	assert_equal(1, label_boxes)
	mm_scene_free(s)
	mm_document_free(d)

# Spot values from upstream mermaid@12.2.0 theme-*.js, in mm_style_theme_id order.
void test_mermaid_upstream_theme_palettes():
	list[char*] themes = list[char*]{c"default", c"base", c"dark", c"forest", c"neutral", c"neo", c"neo-dark", c"redux", c"redux-dark", c"redux-color", c"redux-dark-color"}
	list[int] fills = list[int]{0xececff, 0xfff4dd, 0x1f2020, 0xcde498, 0xeeeeee, 0xffffff, 0x2a2020, 0xffffff, 0x111113, 0xffffff, 0x111113}
	list[int] borders = list[int]{0x9370db, 0xeeddbb, 0xcccccc, 0x13540c, 0x999999, 0x000000, 0xcccccc, 0x28253d, 0xffffff, 0x28253d, 0xffffff}
	list[int] clusters = list[int]{0xffffde, 0xf6f9ff, 0x474949, 0xcdffb2, 0xfcfcfc, 0xffffff, 0x201f1f, 0xf9f9fb, 0x1e1a2e, 0xf9f9fb, 0x1e1a2e}
	list[int] labels = list[int]{0xededed, 0xf4ddff, 0x585858, 0xe8e8e8, 0xffffff, 0xcccccc, 0x474949, 0xcccccc, 0x474949, 0xcccccc, 0x474949}
	list[int] pies = list[int]{0xececff, 0xfff4dd, 0x0b0000, 0xcde498, 0xf4f4f4, 0xececfe, 0x1f2020, 0xececfe, 0x1f2020, 0xf4a8ff, 0xf4a8ff}
	list[int] scales = list[int]{0x8686ff, 0xffcb5d, 0x1f2020, 0xb9d970, 0x555555, 0x7373f8, 0x000000, 0xbfbfbf, 0x000000, 0xf4a8ff, 0xf4a8ff}
	list[int] notes = list[int]{0xfff5ad, 0xfff5ad, 0x474949, 0xfff5ad, 0x666666, 0xfff5ad, 0xfff5ad, 0xfff5ad, 0xfef9c3, 0xfff5ad, 0xfef9c3}
	for i in range(themes.length):
		string_builder* source = string_from(c"---\nconfig:\n  theme: ")
		string_append(source, themes[i])
		string_append(source, c"\n---\nflowchart TB\nsubgraph G\nA -->|go| B\nend\n")
		mm_document* d = config_parse(source.data)
		list[int] v = d.theme_values
		assert_equal(fills[i], d.palette.fill)
		assert_equal(borders[i], d.palette.stroke)
		assert_equal(clusters[i], v[MM_THEME_CLUSTER_BKG])
		assert_equal(labels[i], v[MM_THEME_EDGE_LABEL_BKG])
		assert_equal(pies[i], v[MM_THEME_PIE])
		assert_equal(scales[i], v[MM_THEME_SCALE])
		assert_equal(notes[i], v[MM_THEME_NOTE_BKG])
		# The neo and redux themes default to upstream's 14px label font.
		if (i >= 5): assert_equal(14, d.font_size)
		else: assert_equal(0, d.font_size)
		mm_scene* s = mm_render(d)
		int boxes = 0
		for mm_primitive* p in s.items:
			if (p.role == MM_ROLE_LABEL_BOX): boxes = boxes + 1
		assert_equal(1, boxes)
		mm_scene_free(s)
		mm_document_free(d)
		string_free(source)
	__w_list_free(cast(__w_list*, themes))
	__w_list_free(cast(__w_list*, fills))
	__w_list_free(cast(__w_list*, borders))
	__w_list_free(cast(__w_list*, clusters))
	__w_list_free(cast(__w_list*, labels))
	__w_list_free(cast(__w_list*, pies))
	__w_list_free(cast(__w_list*, scales))
	__w_list_free(cast(__w_list*, notes))

void test_mermaid_theme_variables_with_any_theme_and_dark_mode():
	mm_document* d = config_parse(c"---\nconfig:\n  theme: dark\n  themeVariables:\n    primaryColor: '#336699'\n    clusterBkg: navy\n    titleColor: '#fa0'\n    edgeLabelBackground: '#222'\n---\nflowchart TB\n")
	list[int] v = d.theme_values
	assert_equal(3, d.theme)
	assert_equal(0x336699, d.palette.fill)
	assert_equal(mm_theme_adjust(0x336699, 0, -40, 10), d.palette.stroke)
	assert_equal(0x000080, v[MM_THEME_CLUSTER_BKG])
	assert_equal(0xffaa00, v[MM_THEME_TITLE])
	assert_equal(0x222222, v[MM_THEME_EDGE_LABEL_BKG])
	assert_equal(0x333333, d.background)
	mm_document_free(d)
	d = config_parse(c"---\nconfig:\n  themeVariables:\n    darkMode: true\n    primaryColor: '#336699'\n    secondaryColor: '#808080'\n---\nflowchart TB\n")
	assert_equal(1, d.theme)
	assert_equal(mm_theme_adjust(0x336699, 0, -40, 10), d.palette.stroke)
	assert_equal(mm_theme_adjust(0x808080, 0, 0, -30), d.theme_values[MM_THEME_EDGE_LABEL_BKG])
	mm_document_free(d)
	d = config_parse(c"---\nconfig:\n  theme: base\n  themeVariables:\n    textColor: '#123456'\n    nodeBorder: '#010203'\n    mainBkg: '#fefefe'\n---\nflowchart LR\nA\n")
	assert_equal(0x123456, d.palette_label)
	assert_equal(0x123456, d.theme_values[MM_THEME_TITLE])
	assert_equal(0x010203, d.palette.stroke)
	assert_equal(0xfefefe, d.palette.fill)
	assert_equal(0xcfdbf3, d.theme_values[MM_THEME_CLUSTER_BORDER])
	mm_document_free(d)

void test_mermaid_title_and_series_palettes():
	mm_document* d = config_parse(c"---\ntitle: Flow\nconfig:\n  themeVariables:\n    titleColor: '#0a0b0c'\n---\nflowchart LR\nA\n")
	mm_scene* s = mm_render(d)
	int titles = 0
	for mm_primitive* p in s.items:
		if (p.role == MM_ROLE_TITLE):
			assert_strings_equal(c"Flow", p.text)
			assert_equal(0x0a0b0c, mm_paint_fill(p))
			titles = titles + 1
	assert_equal(1, titles)
	mm_scene_free(s)
	mm_document_free(d)
	d = config_parse(c"---\nconfig:\n  theme: forest\n  themeVariables:\n    pie1: '#010101'\n    pie2: '#020202'\n---\npie\n\"A\": 2\n\"B\": 1\n\"C\": 1\n")
	s = mm_render(d)
	int sectors = 0
	for mm_primitive* p in s.items:
		if (p.kind != MM_POLYGON): continue
		if (sectors == 0): assert_equal(0x010101, mm_paint_fill(p))
		if (sectors == 1): assert_equal(0x020202, mm_paint_fill(p))
		if (sectors == 2): assert_equal(0xe1efc0, mm_paint_fill(p))
		sectors = sectors + 1
	assert_equal(3, sectors)
	mm_scene_free(s)
	mm_document_free(d)
	d = config_parse(c"%%{init: {\"themeVariables\": {\"cScale0\": \"#0000aa\", \"cScale1\": \"#00aa00\"}}}%%\nradar-beta\naxis a, b, c\ncurve one{1,2,3}, two{3,2,1}\n")
	s = mm_render(d)
	int blue = 0
	int green = 0
	for mm_primitive* p in s.items:
		if (p.role != MM_ROLE_SERIES): continue
		if (mm_paint_stroke(p) == 0x0000aa): blue = blue + 1
		if (mm_paint_stroke(p) == 0x00aa00): green = green + 1
		asserts(c"series uses cScale", mm_paint_stroke(p) == 0x0000aa || mm_paint_stroke(p) == 0x00aa00)
	asserts(c"first curve painted", blue > 0)
	asserts(c"second curve painted", green > 0)
	mm_scene_free(s)
	mm_document_free(d)

void test_mermaid_init_directives():
	list[char*] sources = list[char*]{c"%%{init: {\"theme\": \"dark\", \"themeVariables\": {\"primaryColor\": \"#00ff00\"}}}%%\nflowchart LR\nA --> B\n", c"%%{initialize: { 'theme': 'dark', 'themeVariables': { 'primaryColor': '#0f0', } } }%%\nflowchart LR\nA --> B\n", c"%% leading comment\n\n%%{\n  init: {\n    theme: dark,\n    themeVariables: {primaryColor: '#00ff00'}\n  }\n}%%\nflowchart LR\nA --> B\n", c"---\nconfig:\n  theme: forest\n  themeVariables:\n    primaryColor: '#00ff00'\n---\n%%{init: {\"theme\": \"dark\"}}%%\nflowchart LR\nA --> B\n", c"```mermaid\n%%{init: {'theme': 'dark'}}%%\n%%{init: {'themeVariables': {'primaryColor': '#00ff00'}}}%%\nflowchart LR\nA --> B\n```\n"}
	for char* source in sources:
		mm_document* d = config_parse(source)
		assert_equal(3, d.theme)
		assert_equal(0x00ff00, d.palette.fill)
		assert_equal(0x333333, d.background)
		assert_equal(2, d.nodes.length)
		mm_scene* s = mm_render(d)
		asserts(c"directive renders", s != 0)
		mm_scene_free(s)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))
	# Body diagnostics keep original-document line numbers after a directive.
	char* bad = c"%%{init: {'theme': 'dark'}}%%\nflowchart LR\nA --> B\nstyle A fill:#ggg\n"
	mm_document* d = mm_parse(bad, strlen(bad))
	asserts(c"body error after directive", d.error != 0)
	assert_equal(4, d.error_line)
	mm_document_free(d)

void test_mermaid_relaxed_frontmatter():
	list[char*] sources = list[char*]{c"---\n# leading comment\nconfig:   # section comment\n    theme: \"dark\"   # trailing comment\n    themeVariables:\n        primaryColor: '#00ff00'\n\n        lineColor: \"#ff0000\"\n---\nflowchart LR\nA --> B\n", c"---\nconfig:\n theme: dark\n themeVariables: {primaryColor: '#00ff00', lineColor: \"#f00\"}\n---\nflowchart LR\nA --> B\n", c"---\nconfig: {theme: dark, themeVariables: {primaryColor: '#00ff00', lineColor: red}}\n---\nflowchart LR\nA --> B\n", c"---\n'config':\n  \"theme\": dark\n  themeVariables:\n      primaryColor: '#00ff00'\n      lineColor: '#ff0000'\n---\nflowchart LR\nA --> B\n"}
	for char* source in sources:
		mm_document* d = config_parse(source)
		assert_equal(3, d.theme)
		assert_equal(0x00ff00, d.palette.fill)
		assert_equal(0xff0000, d.palette_line)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))
	# The documented example.
	mm_document* d = config_parse(c"---\nconfig:\n  theme: base          # comments are allowed\n  themeVariables:\n    primaryColor: '#e0f2fe'\n    lineColor: \"#64748b\"\n  flowchart: {curve: basis, nodeSpacing: 40}\n---\n%%{init: {\"themeVariables\": {\"edgeLabelBackground\": \"#ffffff\"}}}%%\nflowchart LR\nA -->|label| B\n")
	assert_equal(2, d.theme)
	assert_equal(0xe0f2fe, d.palette.fill)
	assert_equal(0x64748b, d.palette_line)
	assert_equal(0xffffff, d.theme_values[MM_THEME_EDGE_LABEL_BKG])
	assert_equal(2, d.edge_curve)
	assert_equal(40, d.node_spacing)
	mm_document_free(d)

int config_gap(char* source, int vertical):
	mm_document* d = config_parse(source)
	mm_scene* s = mm_render(d)
	mm_bounds* a = s.nodes[0]
	mm_bounds* b = s.nodes[1]
	mm_bounds* c = s.nodes[2]
	int result = c.x - (b.x + b.w)
	if (vertical): result = b.y - (a.y + a.h)
	mm_scene_free(s)
	mm_document_free(d)
	return result

void test_mermaid_flowchart_spacing_and_curves():
	char* body = c"flowchart TB\nA --> B\nA --> C\n"
	string_builder* plain = string_from(c"---\nconfig:\n  theme: default\n---\n")
	string_append(plain, body)
	int lane = config_gap(plain.data, 0)
	int rank = config_gap(plain.data, 1)
	assert_equal(100, lane)
	assert_equal(140, rank)
	assert_equal(lane, config_gap(c"---\nconfig:\n  flowchart:\n    nodeSpacing: 50\n    rankSpacing: 50\n---\nflowchart TB\nA --> B\nA --> C\n", 0))
	assert_equal(rank, config_gap(c"---\nconfig:\n  flowchart:\n    nodeSpacing: 50\n    rankSpacing: 50\n---\nflowchart TB\nA --> B\nA --> C\n", 1))
	assert_equal(20, config_gap(c"%%{init: {'flowchart': {'nodeSpacing': 10, 'rankSpacing': 200}}}%%\nflowchart TB\nA --> B\nA --> C\n", 0))
	assert_equal(290, config_gap(c"%%{init: {'flowchart': {'nodeSpacing': 10, 'rankSpacing': 200}}}%%\nflowchart TB\nA --> B\nA --> C\n", 1))
	# Flowchart-only settings leave other graph families unchanged.
	assert_equal(140, config_gap(c"%%{init: {'flowchart': {'rankSpacing': 200}}}%%\nstateDiagram-v2\nA --> B\nA --> C\n", 1))
	string_free(plain)
	list[char*] curves = list[char*]{c"step", c"linear", c"basis"}
	list[int] diagonal = new list[int]
	list[int] segments = new list[int]
	for char* curve in curves:
		string_builder* source = string_from(c"---\nconfig:\n  flowchart:\n    curve: ")
		string_append(source, curve)
		string_append(source, c"\n---\nflowchart LR\nA --> B\nA --> C\n")
		mm_document* d = config_parse(source.data)
		mm_scene* s = mm_render(d)
		int slanted = 0
		int lines = 0
		for mm_primitive* p in s.items:
			if (p.kind != MM_LINE || p.role != MM_ROLE_EDGE): continue
			lines = lines + 1
			if (p.x != p.x2 && p.y != p.y2): slanted = slanted + 1
		diagonal.push(slanted)
		segments.push(lines)
		mm_scene_free(s)
		mm_document_free(d)
		string_free(source)
	asserts(c"step routes are axis aligned except arrowheads", diagonal[0] == 4)
	asserts(c"linear routes add a diagonal leg", diagonal[1] > diagonal[0])
	asserts(c"basis routes are sampled curves", segments[2] > segments[1] + 10)
	__w_list_free(cast(__w_list*, curves))
	__w_list_free(cast(__w_list*, diagonal))
	__w_list_free(cast(__w_list*, segments))
	mm_document* d = config_parse(c"---\nconfig:\n  look: neo\n  theme: redux\n---\nflowchart LR\nA --> B\n")
	assert_equal(1, d.look)
	assert_equal(8, d.theme)
	mm_document_free(d)

void test_mermaid_configuration_diagnostics():
	config_reject(c"%%{init: {'theme': 'dark'}\nflowchart LR\nA\n", c"unterminated Mermaid directive")
	config_reject(c"%%{init: {'theme': 'dark'}}%% extra\nflowchart LR\nA\n", c"unexpected text after Mermaid directive")
	config_reject(c"%%{init {'theme': 'dark'}}%%\nflowchart LR\nA\n", c"Mermaid directive requires colon")
	config_reject(c"%%{init: 'dark'}%%\nflowchart LR\nA\n", c"init directive requires an object")
	config_reject(c"%%{init: {'theme' 'dark'}}%%\nflowchart LR\nA\n", c"configuration key requires colon")
	config_reject(c"%%{init: {'theme': 'dark' 'look': 'neo'}}%%\nflowchart LR\nA\n", c"expected , or } in configuration")
	config_reject(c"%%{init: {'theme': 'dark}}%%\nflowchart LR\nA\n", c"unterminated configuration string")
	config_reject(c"%%{init: {'theme': 'dark', 'theme': 'forest'}}%%\nflowchart LR\nA\n", c"duplicate theme setting")
	config_reject(c"%%{init: {'fontFamily': 'serif;x'}}%%\nflowchart LR\nA\n", c"fontFamily takes a CSS font-family list of names, quotes, commas and spaces")
	config_reject(c"%%{init: {'a': {'b': {'c': {'d': {'e': {'f': {'g': {'h': 1}}}}}}}}}%%\nflowchart LR\nA\n", c"configuration nesting too deep")
	config_reject(c"%%{init: {'look': 'handDrawn'}}%%\nflowchart LR\nA\n", c"unsupported look; supported: classic, neo")
	config_reject(c"%%{init: {'flowchart': {'curve': 'cardinal'}}}%%\nflowchart LR\nA\n", c"unsupported flowchart curve; supported: basis, linear, step, stepBefore, stepAfter")
	config_reject(c"%%{init: {'flowchart': {'nodeSpacing': 501}}}%%\nflowchart LR\nA\n", c"flowchart spacing must be an integer from 0 to 500")
	config_reject(c"%%{init: {'flowchart': 5}}%%\nflowchart LR\nA\n", c"configuration section must be a mapping")
	config_reject(c"%%{init: {'theme': {'name': 'dark'}}}%%\nflowchart LR\nA\n", c"configuration value must be a scalar")
	config_reject(c"%%{init: {'themeVariables': {'darkMode': 'yes'}}}%%\nflowchart LR\nA\n", c"darkMode must be true or false")
	# Out-of-range series variables are unknown variables: ignored and recorded.
	mm_document* unknown = config_parse(c"%%{init: {'themeVariables': {'pie13': '#fff', 'cScale12': '#fff'}}}%%\nflowchart LR\nA\n")
	asserts(c"unknown theme variables are ignored", unknown.config_ignored != 0 && unknown.config_ignored.length == 2)
	mm_document_free(unknown)
	config_reject(c"%%{init: {'themeVariables': {'primaryColor': 'none'}}}%%\nflowchart LR\nA\n", c"theme variables require #RGB, #RRGGBB or a supported color name")
	config_reject(c"%%{init: {'theme': 'sepia'}}%%\nflowchart LR\nA\n", c"unsupported theme; supported: default, base, dark, forest, neutral, neo, neo-dark, redux, redux-dark, redux-color, redux-dark-color")
	config_reject(c"---\nconfig:\n    theme: dark\n  layout: force\n---\nflowchart LR\nA\n", c"inconsistent frontmatter indentation")
	config_reject(c"---\nconfig:\n\ttheme: dark\n---\nflowchart LR\nA\n", c"frontmatter indentation must use spaces")
	config_reject(c"---\nconfig:\n  - theme\n---\nflowchart LR\nA\n", c"configuration section must be a mapping")
	config_reject(c"---\nconfig:\n  theme\n---\nflowchart LR\nA\n", c"frontmatter entry requires key: value")
	config_reject(c"---\nconfig:\n  theme: 'dark\n---\nflowchart LR\nA\n", c"unterminated quoted configuration value")
	config_reject(c"---\nconfig:\n  theme: 'dark'x\n---\nflowchart LR\nA\n", c"unexpected text after quoted configuration value")
	config_reject(c"---\nconfig:\n  theme: @dark\n---\nflowchart LR\nA\n", c"unsupported YAML value in frontmatter")
	config_reject(c"---\nconfig:\n  themeVariables: {primaryColor: '#fff'} x\n---\nflowchart LR\nA\n", c"unexpected text after frontmatter mapping")
	config_reject(c"---\nconfig: dark\n---\nflowchart LR\nA\n", c"configuration section must be a mapping")
	config_reject(c"---\nconfig:\n  theme: dark\n  theme: forest\n---\nflowchart LR\nA\n", c"duplicate theme setting")

void test_mermaid_configuration_bounds_and_prefixes():
	string_builder* text = string_from(c"%%{init: {'elk': {")
	for i in range(600):
		if (i): string_append(text, c", ")
		string_append(text, c"'k")
		string_append_int(text, i)
		string_append(text, c"': 1")
	string_append(text, c"}}}%%\nflowchart LR\nA\n")
	mm_document* d = mm_parse(text.data, text.length)
	assert_strings_equal(c"configuration entry limit exceeded", d.error)
	mm_document_free(d)
	string_free(text)
	char* source = c"---\nconfig:\n    theme: dark\n    flowchart: {curve: basis, nodeSpacing: 20}\n---\n%%{init: {'themeVariables': {'primaryColor': '#0f0'}}}%%\nflowchart LR\nA-->|x|B\n"
	for length in range(strlen(source) + 1):
		d = mm_parse(source, length)
		mm_scene* scene = mm_render(d)
		if (d.error != 0): asserts(c"prefix errors suppress rendering", scene == 0)
		mm_scene_free(scene)
		mm_document_free(d)
